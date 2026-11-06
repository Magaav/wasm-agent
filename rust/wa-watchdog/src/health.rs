//! The health probe: one HTTP/1.1 GET to `/health` over a loopback socket, and the honest answer to "did
//! it answer, and did it say it is well".
//!
//! A whole HTTP client crate was not worth it. What the watchdog needs is a GET on 127.0.0.1, no TLS, no
//! redirects, a hard timeout, and no reuse: the kernel closes the connection after a response and a
//! watchdog that keeps a socket open across a kernel swap would be holding a handle to a process it
//! replaced. Chunked transfer is decoded; anything else non-`Content-Length` is read to EOF, which is what
//! `Connection: close` promises.
//!
//! Readiness is deliberately strict and named: [`Probe::ready`] requires a 200 AND a top-level `"ok":true`.
//! A node that answers but says `ok:false` (a stalled run thread, a refused journal write) is *answering*
//! and *not ready*, and those two facts are different questions - the docs and the swap both need to be
//! able to tell them apart.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::{Duration, Instant};

use crate::json;

/// The body cap. `/health` is a few kilobytes; a peer that streams megabytes is not the kernel and must
/// not be able to make the watchdog allocate without bound.
const MAX_BODY: usize = 1024 * 1024;

#[derive(Debug, Clone, Default)]
pub struct Probe {
    /// A response arrived (a socket that accepts and says nothing is `answered: false`).
    pub answered: bool,
    /// The HTTP status code, when a status line could be read.
    pub status: u16,
    /// The response body as text (lossy UTF-8: a probe must never fail on bytes).
    pub body: String,
    /// `/health`'s top-level `ok`, when it is a boolean.
    pub ok: Option<bool>,
    /// `/health`'s top-level `state` (`alive`/`busy`/`stalled`/`idle`/`upgrading`), when present.
    pub state: Option<String>,
    /// Why this probe did not get an answer, in one line. Never message text: this is a socket error, a
    /// timeout, or a malformed status line.
    pub detail: Option<String>,
}

impl Probe {
    /// Something answered with a 200. Says nothing about health.
    pub fn answers(&self) -> bool {
        self.answered && self.status == 200
    }

    /// The one question the supervisor asks before it declares a kernel up: does it answer, and does its
    /// own report say `ok: true`.
    pub fn ready(&self) -> bool {
        self.answers() && self.ok == Some(true)
    }

    /// A one-line reason, for a log line or a swap refusal. Contains no body text.
    pub fn why_not(&self) -> String {
        if let Some(detail) = &self.detail {
            return detail.clone();
        }
        if !self.answered {
            return "no answer".to_string();
        }
        if self.status != 200 {
            return format!("status {}", self.status);
        }
        match self.ok {
            Some(true) => "ready".to_string(),
            Some(false) => format!("ok:false (state {})", self.state.clone().unwrap_or_else(|| "unknown".into())),
            None => "no top-level \"ok\" in /health".to_string(),
        }
    }
}

/// GET `/health` on `127.0.0.1:port`. `timeout` bounds the connect and each read, so the whole call is
/// bounded by a small multiple of it.
pub fn probe(port: u16, timeout: Duration) -> Probe {
    let deadline = Instant::now() + timeout;
    let address = match ("127.0.0.1", port).to_socket_addrs().ok().and_then(|mut addrs| addrs.next()) {
        Some(address) => address,
        None => {
            return Probe {
                detail: Some(format!("no address for 127.0.0.1:{port}")),
                ..Default::default()
            }
        }
    };
    let mut stream = match TcpStream::connect_timeout(&address, timeout) {
        Ok(stream) => stream,
        Err(error) => {
            return Probe { detail: Some(format!("connect: {}", short(&error))), ..Default::default() };
        }
    };
    let remaining = || deadline.saturating_duration_since(Instant::now()).max(Duration::from_millis(1));
    let _ = stream.set_read_timeout(Some(remaining()));
    let _ = stream.set_write_timeout(Some(remaining()));
    let request =
        format!("GET /health HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAccept: application/json\r\nConnection: close\r\n\r\n");
    if let Err(error) = stream.write_all(request.as_bytes()) {
        return Probe { detail: Some(format!("write: {}", short(&error))), ..Default::default() };
    }
    let mut raw = Vec::new();
    let mut buf = [0u8; 8192];
    loop {
        let _ = stream.set_read_timeout(Some(remaining()));
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(read) => {
                raw.extend_from_slice(&buf[..read]);
                if raw.len() > MAX_BODY + 8192 {
                    break;
                }
                // Keep the whole response (head and body): `parse_response` needs the status line. This only
                // asks "has the body promised by Content-Length arrived yet", so the socket is not read past
                // the end of a keep-alive response.
                if complete_body(&raw).is_some() {
                    break;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => {
                if raw.is_empty() {
                    return Probe { detail: Some(format!("read: {}", short(&error))), ..Default::default() };
                }
                // A partial response that a short timeout cut off is still an answer: parse what arrived
                // rather than reporting the peer as silent.
                break;
            }
        }
    }
    parse_response(&raw)
}

fn short(error: &std::io::Error) -> String {
    // `Display` for an OS error carries the OS message; keep it on one line and bounded.
    let text = error.to_string().replace(['\r', '\n'], " ");
    text.chars().take(120).collect()
}

/// The body of a response whose `Content-Length` is fully buffered, or `None` while more bytes are needed.
fn complete_body(raw: &[u8]) -> Option<Vec<u8>> {
    let (header_end, body_start) = header_bounds(raw)?;
    let headers = String::from_utf8_lossy(&raw[..header_end]).to_string();
    let length = header_value(&headers, "content-length")?.parse::<usize>().ok()?;
    if raw.len() >= body_start + length {
        Some(raw[body_start..body_start + length].to_vec())
    } else {
        None
    }
}

/// `(index of the end of the headers, index of the first body byte)`.
fn header_bounds(raw: &[u8]) -> Option<(usize, usize)> {
    if let Some(index) = raw.windows(4).position(|window| window == b"\r\n\r\n") {
        return Some((index, index + 4));
    }
    raw.windows(2).position(|window| window == b"\n\n").map(|index| (index, index + 2))
}

fn header_value(headers: &str, name: &str) -> Option<String> {
    for line in headers.lines().skip(1) {
        let (key, value) = line.split_once(':')?;
        if key.trim().eq_ignore_ascii_case(name) {
            return Some(value.trim().to_string());
        }
    }
    None
}

fn parse_response(raw: &[u8]) -> Probe {
    let (header_end, body_start) = match header_bounds(raw) {
        Some(bounds) => bounds,
        None => {
            return Probe { detail: Some("no header terminator".to_string()), ..Default::default() }
        }
    };
    let headers = String::from_utf8_lossy(&raw[..header_end]).to_string();
    let status = headers
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse::<u16>().ok());
    let status = match status {
        Some(status) => status,
        None => return Probe { detail: Some("no status line".to_string()), ..Default::default() },
    };
    let body_bytes = &raw[body_start..];
    let body = if header_value(&headers, "transfer-encoding").is_some_and(|value| value.to_ascii_lowercase().contains("chunked")) {
        decode_chunked(body_bytes)
    } else {
        body_bytes.to_vec()
    };
    let body = String::from_utf8_lossy(&body).to_string();
    Probe {
        answered: true,
        status,
        ok: json::field_bool(&body, "ok"),
        state: json::field_str(&body, "state"),
        body,
        detail: None,
    }
}

/// A minimal chunked decoder. Returns what it could decode: a truncated tail (a timeout mid-stream) is not
/// a reason to call a healthy node silent.
fn decode_chunked(raw: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut index = 0usize;
    while let Some(offset) = raw[index..].windows(2).position(|window| window == b"\r\n") {
        let line_end = index + offset;
        let size_text = String::from_utf8_lossy(&raw[index..line_end]).to_string();
        let size_text = size_text.split(';').next().unwrap_or("").trim().to_string();
        let size = match usize::from_str_radix(&size_text, 16) {
            Ok(size) => size,
            Err(_) => break,
        };
        index = line_end + 2;
        if size == 0 {
            break;
        }
        let end = std::cmp::min(index + size, raw.len());
        out.extend_from_slice(&raw[index..end]);
        index = end;
        // The chunk is followed by CRLF; a truncated tail simply ends the decode.
        let crlf = raw.get(index) == Some(&b'\r') && raw.get(index + 1) == Some(&b'\n');
        let bare_lf = raw.get(index) == Some(&b'\n');
        if crlf {
            index += 2;
        } else if bare_lf {
            index += 1;
        } else {
            break;
        }
        if index >= raw.len() {
            break;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    /// A one-shot HTTP server on a port of its own. Returns the port.
    fn server(response: &'static [u8]) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind a probe test port");
        let port = listener.local_addr().expect("local addr").port();
        thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let _ = stream.write_all(response);
            }
        });
        port
    }

    #[test]
    fn a_ready_node_is_ready() {
        let port = server(
            b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{\"ok\":true,\"state\":\"idle\"}",
        );
        // The length above is deliberately the real one for that body.
        let probe = probe(port, Duration::from_millis(1500));
        assert!(probe.answers(), "answered: {probe:?}");
        assert_eq!(probe.ok, Some(true));
        assert_eq!(probe.state.as_deref(), Some("idle"));
        assert!(probe.ready());
    }

    #[test]
    fn a_node_that_answers_ok_false_is_answering_and_not_ready() {
        let body = "{\"ok\":false,\"state\":\"stalled\"}";
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
        let leaked: &'static [u8] = Box::leak(response.into_bytes().into_boxed_slice());
        let probe = probe(server(leaked), Duration::from_millis(1500));
        assert!(probe.answers());
        assert!(!probe.ready());
        assert_eq!(probe.why_not(), "ok:false (state stalled)");
    }

    #[test]
    fn a_body_without_content_length_is_read_to_eof() {
        let leaked: &'static [u8] = b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{\"ok\":true}";
        let probe = probe(server(leaked), Duration::from_millis(1500));
        assert!(probe.ready(), "{probe:?}");
    }

    #[test]
    fn a_chunked_body_is_decoded() {
        // {"ok":true} split into two chunks.
        let leaked: &'static [u8] =
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n8\r\n{\"ok\":tr\r\n3\r\nue}\r\n0\r\n\r\n";
        let probe = probe(server(leaked), Duration::from_millis(1500));
        assert!(probe.ready(), "{probe:?}");
        assert_eq!(probe.body, "{\"ok\":true}");
    }

    #[test]
    fn a_refused_port_is_not_answered() {
        // Bind and drop: the port is (almost certainly) free, so nothing listens on it.
        let port = {
            let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
            listener.local_addr().expect("addr").port()
        };
        let probe = probe(port, Duration::from_millis(200));
        assert!(!probe.answered);
        assert!(!probe.ready());
        assert!(!probe.why_not().contains("ready"), "the refusal names a cause: {}", probe.why_not());
    }

    #[test]
    fn a_socket_that_says_nothing_is_bounded_by_the_timeout() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("addr").port();
        // Accept the connection and never answer.
        thread::spawn(move || {
            let _held = listener.accept();
            thread::sleep(Duration::from_millis(1500));
        });
        let started = Instant::now();
        let probe = probe(port, Duration::from_millis(300));
        assert!(!probe.answered);
        assert!(started.elapsed() < Duration::from_millis(1200), "probe returned in {:?}", started.elapsed());
    }
}

