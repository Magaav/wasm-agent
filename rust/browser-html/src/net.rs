//! The parts of `open` that are not a system call: the allow-list, the request bytes, and the response split.
//!
//! Mission `agent-browser-from-scratch`, stage 1. `open` itself needs a socket (`wasi:sockets`, which the host does
//! grant - `rust/wa-kernel-runtime/src/components.rs:440`), and a socket cannot be judged by a unit test. Everything
//! AROUND the socket can: which hosts a caller may reach, the exact bytes a request is, and how a response is split
//! into status, headers and body. Those are the parts where a browser is blamed when it goes wrong, so they are here,
//! pure and tested, and the component only supplies the connection.

/// Is `host` reachable under this allow-list?
///
/// The rule is exact-or-subdomain, never a suffix match on a string: `evil-example.com` must NOT pass an allow-list
/// entry of `example.com`, and `example.com.evil.net` must not either. A port in the entry or the host is compared
/// with the port, so `example.com:8443` does not silently mean every port.
pub fn allowed(host: &str, port: u16, allow: &[&str]) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    if host.is_empty() || allow.is_empty() {
        return false;
    }
    for entry in allow {
        let entry = entry.trim().to_ascii_lowercase();
        let (want_host, want_port) = match entry.rsplit_once(':') {
            Some((h, p)) => match p.parse::<u16>() {
                Ok(p) => (h.to_string(), Some(p)),
                Err(_) => (entry.clone(), None),
            },
            None => (entry.clone(), None),
        };
        if let Some(want_port) = want_port {
            if want_port != port {
                continue;
            }
        }
        if host == want_host || host.ends_with(&format!(".{want_host}")) {
            return true;
        }
    }
    false
}

/// The bytes of a GET request. No header a caller did not ask for, and `Host` always carries the port when it is
/// not the scheme default, because a server that vhosts on a port will otherwise answer for the wrong site.
pub fn get_request(host: &str, port: u16, path: &str, cookie: Option<&str>) -> Vec<u8> {
    let default = port == 80;
    let host_header = if default { host.to_string() } else { format!("{host}:{port}") };
    let mut out = format!(
        "GET {path} HTTP/1.1\r\nHost: {host_header}\r\nUser-Agent: wa-browser/0.1\r\nAccept: text/html,application/xhtml+xml\r\nAccept-Encoding: identity\r\nConnection: close\r\n"
    );
    if let Some(cookie) = cookie {
        out.push_str(&format!("Cookie: {cookie}\r\n"));
    }
    out.push_str("\r\n");
    out.into_bytes()
}

/// A response, split into the three things a caller acts on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// Why a response could not be split. Named, like every other refusal here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    NoStatusLine,
    MalformedStatus(String),
    /// A chunked body is not decoded yet; saying so is better than answering half a page.
    ChunkedBodyUnsupported,
}

/// Split raw response bytes into status, headers and body.
pub fn parse_response(raw: &[u8]) -> Result<Response, Refusal> {
    let split = raw.windows(4).position(|w| w == b"\r\n\r\n").ok_or(Refusal::NoStatusLine)?;
    let head = String::from_utf8_lossy(&raw[..split]).to_string();
    let body = raw[split + 4..].to_vec();
    let mut lines = head.split("\r\n");
    let status_line = lines.next().ok_or(Refusal::NoStatusLine)?;
    let mut parts = status_line.split_whitespace();
    let _version = parts.next();
    let status = parts
        .next()
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or_else(|| Refusal::MalformedStatus(status_line.to_string()))?;
    let mut headers = Vec::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            headers.push((name.trim().to_ascii_lowercase(), value.trim().to_string()));
        }
    }
    if headers.iter().any(|(n, v)| n == "transfer-encoding" && v.eq_ignore_ascii_case("chunked")) {
        return Err(Refusal::ChunkedBodyUnsupported);
    }
    Ok(Response { status, headers, body })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_allow_list_is_exact_or_subdomain_and_never_a_suffix() {
        let allow = ["example.com"];
        assert!(allowed("example.com", 80, &allow));
        assert!(allowed("app.example.com", 80, &allow));
        assert!(!allowed("evil-example.com", 80, &allow), "a suffix match would let this through");
        assert!(!allowed("example.com.evil.net", 80, &allow));
        assert!(!allowed("example.com", 80, &[]), "an empty list allows nothing");
    }

    #[test]
    fn an_allow_list_entry_with_a_port_pins_the_port() {
        let allow = ["example.com:8443"];
        assert!(allowed("example.com", 8443, &allow));
        assert!(!allowed("example.com", 80, &allow));
    }

    #[test]
    fn the_request_names_the_port_and_carries_the_jar() {
        let plain = String::from_utf8(get_request("example.com", 80, "/a", None)).unwrap();
        assert!(plain.starts_with("GET /a HTTP/1.1\r\n"), "{plain}");
        assert!(plain.contains("Host: example.com\r\n"), "{plain}");
        assert!(!plain.contains("Cookie:"), "no cookie, no header");
        let odd = String::from_utf8(get_request("127.0.0.1", 8080, "/b", Some("sid=1"))).unwrap();
        assert!(odd.contains("Host: 127.0.0.1:8080\r\n"), "{odd}");
        assert!(odd.contains("Cookie: sid=1\r\n"), "{odd}");
    }

    #[test]
    fn a_response_splits_into_status_headers_and_body() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nSet-Cookie: sid=abc; Path=/\r\n\r\n<h1>oi</h1>";
        let r = parse_response(raw).unwrap();
        assert_eq!(r.status, 200);
        assert_eq!(r.body, b"<h1>oi</h1>");
        assert!(r.headers.iter().any(|(n, v)| n == "set-cookie" && v.starts_with("sid=abc")));
    }

    #[test]
    fn a_chunked_body_is_refused_by_name_rather_than_half_read() {
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
        assert_eq!(parse_response(raw), Err(Refusal::ChunkedBodyUnsupported));
    }
}
