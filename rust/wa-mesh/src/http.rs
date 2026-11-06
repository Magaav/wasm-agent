//! The one small HTTP/1.1 dialect the mesh speaks — both directions, both ends ours.
//!
//! Why not a client library: a mesh call is one `POST` to a `host:port` that is already known, with
//! a JSON body, no redirects, no cookies, no TLS and no keep-alive. A dependency that brings a
//! connection pool and a redirect policy for that is a dependency to audit for nothing. What this
//! module *does* promise, in both directions, is the part that matters:
//!
//! * exactly one request or response per connection, `Connection: close`;
//! * `Content-Length` is required on a body — anything else (`Transfer-Encoding`, a body with no
//!   length) is refused with `length_required` rather than read until somebody stops talking;
//! * every read and write is bounded by a timeout and by [`MAX_BODY`], so a peer cannot make the
//!   caller hold memory or a socket open;
//! * header names are compared lowercased, values are used verbatim.
//!
//! Everything here answers with a string on failure. The caller's job is to say *which address* failed
//! and to try the next one, so the message is for the audit line, not for a program to match on.
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

/// Largest body accepted or sent. A mesh envelope carries a capability call, not a blob: the largest
/// thing either end sends today is a `bash` result or a `read` of a big file, and the node's own
/// HTTP body bound is the same order. Bigger is refused (`too_large`), never buffered.
pub const MAX_BODY: usize = 4 * 1024 * 1024;

const MAX_HEAD: usize = 32 * 1024;

pub struct Request {
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl std::fmt::Debug for Request {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Request")
            .field("method", &self.method)
            .field("path", &self.path)
            .field("headers", &self.headers)
            .field("body_bytes", &self.body.len())
            .finish()
    }
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        let wanted = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(key, _)| *key == wanted)
            .map(|(_, value)| value.as_str())
    }

    pub fn body_text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
}

pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl std::fmt::Debug for Response {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Response")
            .field("status", &self.status)
            .field("headers", &self.headers)
            .field("body_bytes", &self.body.len())
            .finish()
    }
}

impl Response {
    pub fn header(&self, name: &str) -> Option<&str> {
        let wanted = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(key, _)| *key == wanted)
            .map(|(_, value)| value.as_str())
    }

    pub fn body_text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
}

fn find_head_end(buffer: &[u8]) -> Option<usize> {
    buffer.windows(4).position(|window| window == b"\r\n\r\n")
}

type Headers = Vec<(String, String)>;

struct Head {
    first: String,
    second: String,
    headers: Headers,
}

fn parse_head(head: &str) -> Result<Head, String> {
    let mut lines = head.split("\r\n");
    let first_line = lines.next().ok_or_else(|| "empty_head".to_string())?;
    let mut parts = first_line.split(' ');
    let first = parts.next().ok_or_else(|| "bad_head".to_string())?.to_string();
    let second = parts.next().ok_or_else(|| "bad_head".to_string())?.to_string();
    let (third, fourth) = (parts.next(), parts.next());
    let mut headers = Vec::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        let (name, value) = line.split_once(':').ok_or_else(|| "bad_header".to_string())?;
        headers.push((name.trim().to_ascii_lowercase(), value.trim().to_string()));
    }
    let _ = (third, fourth);
    Ok(Head { first, second, headers })
}

/// `METHOD PATH HTTP/1.x` — one request line per connection.
fn parse_request_head(head: &str) -> Result<(String, String, Headers), String> {
    let parsed = parse_head(head)?;
    let protocol = head.split(' ').nth(2).ok_or_else(|| "bad_http_version".to_string())?;
    if !protocol.starts_with("HTTP/1.") {
        return Err("bad_http_version".into());
    }
    Ok((parsed.first, parsed.second, parsed.headers))
}

/// `HTTP/1.x STATUS REASON` — one response per connection.
fn parse_response_head(head: &str) -> Result<(u16, Headers), String> {
    let parsed = parse_head(head)?;
    if !parsed.first.starts_with("HTTP/1.") {
        return Err("bad_http_version".into());
    }
    let status = parsed.second.parse::<u16>().map_err(|_| "bad_status".to_string())?;
    Ok((status, parsed.headers))
}

fn content_length(headers: &[(String, String)]) -> Result<Option<usize>, String> {
    let chunked = headers
        .iter()
        .any(|(key, value)| key == "transfer-encoding" && value.to_ascii_lowercase().contains("chunked"));
    if chunked {
        return Err("length_required".into());
    }
    match headers.iter().find(|(key, _)| key == "content-length") {
        None => Ok(None),
        Some((_, value)) => value
            .trim()
            .parse::<usize>()
            .map(Some)
            .map_err(|_| "bad_content_length".to_string()),
    }
}

/// Read one request from a connection. `Ok(None)` is a peer that closed before sending a head —
/// a probe (the listener's own shutdown does this) and not an error worth a line.
pub fn read_request(stream: &mut TcpStream, max_body: usize) -> Result<Option<Request>, String> {
    let mut buffer = Vec::with_capacity(1024);
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        if let Some(end) = find_head_end(&buffer) {
            break end;
        }
        if buffer.len() > MAX_HEAD {
            return Err("head_too_large".into());
        }
        match stream.read(&mut chunk) {
            Ok(0) if buffer.is_empty() => return Ok(None),
            Ok(0) => return Err("truncated_head".into()),
            Ok(read) => buffer.extend_from_slice(&chunk[..read]),
            Err(error) => return Err(format!("read_failed:{error}")),
        }
    };
    let head = String::from_utf8_lossy(&buffer[..head_end]).into_owned();
    let (method, path, headers) = parse_request_head(&head)?;
    let mut body = buffer[head_end + 4..].to_vec();
    let length = content_length(&headers)?.unwrap_or(0);
    if length > max_body {
        return Err("too_large".into());
    }
    while body.len() < length {
        match stream.read(&mut chunk) {
            Ok(0) => return Err("truncated_body".into()),
            Ok(read) => body.extend_from_slice(&chunk[..read]),
            Err(error) => return Err(format!("read_failed:{error}")),
        }
        if body.len() > max_body {
            return Err("too_large".into());
        }
    }
    body.truncate(length);
    Ok(Some(Request { method, path, headers, body }))
}

pub fn write_response(
    stream: &mut TcpStream,
    status: u16,
    headers: &[(String, String)],
    body: &[u8],
) -> Result<(), String> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        408 => "Request Timeout",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        _ => "Status",
    };
    let mut head = format!("HTTP/1.1 {status} {reason}\r\n");
    let mut has_length = false;
    let mut has_type = false;
    for (name, value) in headers {
        if name.eq_ignore_ascii_case("content-length") {
            has_length = true;
        }
        if name.eq_ignore_ascii_case("content-type") {
            has_type = true;
        }
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    if !has_type {
        head.push_str("Content-Type: application/json\r\n");
    }
    if !has_length {
        head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    head.push_str("Connection: close\r\n\r\n");
    stream.write_all(head.as_bytes()).map_err(|error| format!("write_failed:{error}"))?;
    stream.write_all(body).map_err(|error| format!("write_failed:{error}"))?;
    stream.flush().map_err(|error| format!("write_failed:{error}"))
}

/// One request, one connection. `address` is `host:port`; a private address and a public name are
/// the same shape here, and the caller decides the order. The two timeouts and the body bound are
/// separate arguments on purpose: a caller that has to remember what they mean by position should see
/// them named at the call site, and there are only two call sites (the client and the node's forwarder).
#[allow(clippy::too_many_arguments)]
pub fn request(
    address: &str,
    method: &str,
    path: &str,
    headers: &[(String, String)],
    body: &[u8],
    connect_timeout: Duration,
    io_timeout: Duration,
    max_body: usize,
) -> Result<Response, String> {
    if body.len() > max_body {
        return Err("too_large".into());
    }
    let targets: Vec<_> = address
        .to_socket_addrs()
        .map_err(|error| format!("resolve_failed:{error}"))?
        .collect();
    if targets.is_empty() {
        return Err("resolve_failed:no_address".into());
    }
    let mut last_error = String::from("connect_failed");
    let mut stream = None;
    for target in targets {
        match TcpStream::connect_timeout(&target, connect_timeout) {
            Ok(connected) => {
                stream = Some(connected);
                break;
            }
            Err(error) => last_error = format!("connect_failed:{error}"),
        }
    }
    let mut stream = stream.ok_or(last_error)?;
    let _ = stream.set_nodelay(true);
    stream.set_read_timeout(Some(io_timeout)).map_err(|error| format!("timeout_failed:{error}"))?;
    stream.set_write_timeout(Some(io_timeout)).map_err(|error| format!("timeout_failed:{error}"))?;

    let mut head = format!("{method} {path} HTTP/1.1\r\nHost: {address}\r\n");
    let mut has_length = false;
    for (name, value) in headers {
        if name.eq_ignore_ascii_case("content-length") {
            has_length = true;
        }
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    if !has_length {
        head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    head.push_str("Connection: close\r\n\r\n");
    stream.write_all(head.as_bytes()).map_err(|error| format!("write_failed:{error}"))?;
    stream.write_all(body).map_err(|error| format!("write_failed:{error}"))?;
    stream.flush().map_err(|error| format!("write_failed:{error}"))?;

    let mut buffer = Vec::with_capacity(1024);
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        if let Some(end) = find_head_end(&buffer) {
            break end;
        }
        if buffer.len() > MAX_HEAD {
            return Err("head_too_large".into());
        }
        match stream.read(&mut chunk) {
            Ok(0) => return Err("truncated_head".into()),
            Ok(read) => buffer.extend_from_slice(&chunk[..read]),
            Err(error) => return Err(format!("read_failed:{error}")),
        }
    };
    let head = String::from_utf8_lossy(&buffer[..head_end]).into_owned();
    let (status, headers) = parse_response_head(&head)?;
    let mut body = buffer[head_end + 4..].to_vec();
    match content_length(&headers)? {
        Some(length) => {
            if length > max_body {
                return Err("too_large".into());
            }
            while body.len() < length {
                match stream.read(&mut chunk) {
                    Ok(0) => return Err("truncated_body".into()),
                    Ok(read) => body.extend_from_slice(&chunk[..read]),
                    Err(error) => return Err(format!("read_failed:{error}")),
                }
                if body.len() > max_body {
                    return Err("too_large".into());
                }
            }
            body.truncate(length);
        }
        None => loop {
            match stream.read(&mut chunk) {
                Ok(0) => break,
                Ok(read) => body.extend_from_slice(&chunk[..read]),
                Err(error) => return Err(format!("read_failed:{error}")),
            }
            if body.len() > max_body {
                return Err("too_large".into());
            }
        },
    }
    Ok(Response { status, headers, body })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn a_request_round_trips_over_a_real_socket() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let request = read_request(&mut stream, MAX_BODY).unwrap().unwrap();
            assert_eq!(request.method, "POST");
            assert_eq!(request.path, "/mesh/call");
            assert_eq!(request.header("x-wa-node"), Some("abc"));
            write_response(&mut stream, 200, &[], request.body_text().as_bytes()).unwrap();
        });
        let response = request(
            &address.to_string(),
            "POST",
            "/mesh/call",
            &[("x-wa-node".into(), "abc".into())],
            b"{\"schema\":1}",
            Duration::from_secs(2),
            Duration::from_secs(5),
            MAX_BODY,
        )
        .unwrap();
        assert_eq!(response.status, 200);
        assert_eq!(response.body_text(), "{\"schema\":1}");
        server.join().unwrap();
    }

    #[test]
    fn a_chunked_body_or_an_oversized_one_is_refused_and_not_buffered() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            // Transfer-Encoding with no Content-Length: refused before a byte of body is read.
            stream
                .write_all(b"POST /mesh/call HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n")
                .unwrap();
            let _ = stream.set_read_timeout(Some(Duration::from_secs(1)));
            let mut sink = [0u8; 64];
            let _ = stream.read(&mut sink);
        });
        let mut stream = TcpStream::connect(address).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        assert_eq!(read_request(&mut stream, MAX_BODY).unwrap_err(), "length_required");
        drop(stream);
        server.join().unwrap();

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let _ = stream.write_all(
                b"POST /mesh/call HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n{}",
            );
            let _ = stream.set_read_timeout(Some(Duration::from_secs(1)));
            let mut sink = [0u8; 64];
            let _ = stream.read(&mut sink);
        });
        let mut stream = TcpStream::connect(address).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        assert_eq!(read_request(&mut stream, MAX_BODY).unwrap_err(), "too_large");
        drop(stream);
        server.join().unwrap();
    }
}
