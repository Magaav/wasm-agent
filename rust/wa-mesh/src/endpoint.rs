//! One service URL, resolved into the `host:port` and path the mesh's own HTTP dialect dials.
//!
//! The operator writes a *service address* — `WASM_AGENT_RELAY`, or a binding's `state.service` — and
//! a service address is a URL: `https://rendezvous.example.com`, a scheme, no explicit port, often a
//! path prefix. The client underneath ([`crate::http`]) speaks `host:port`, so the two have to meet
//! somewhere, and this is the one place they do:
//!
//! * **scheme-default ports**: `https` → 443, `http` → 80, so a URL that names no port is still a
//!   destination (the 07/11 rollout failed on exactly this: `resolve_failed:invalid port value`,
//!   because `https://host` was handed to `to_socket_addrs` whole);
//! * **a path prefix** is kept and prefixed onto the request path (`https://host/relay` +
//!   `/relay/send` → `/relay/relay/send`), because a service behind a reverse proxy is reached at a
//!   prefix, not at the root;
//! * **an IPv6 literal** stays bracketed in `host:port` (`https://[2001:db8::1]` →
//!   `[2001:db8::1]:443`), which is the only shape `to_socket_addrs` and a `Host:` header accept;
//! * **a bare `host:port`** is accepted unchanged, which is what the tests and a loopback relay
//!   already write.
//!
//! What this deliberately does **not** do is TLS. A scheme is read for its default port and its shape
//! and for nothing else: `https` here means "dial 443 with the mesh's own plain-HTTP dialect". That is
//! right for a relay reached over a loopback tunnel and wrong for a public TLS endpoint — it will fail
//! the handshake and say so in the audit line — and it is written down in `docs/MESH.md` §"What is
//! open" rather than implied by a constant. Adding a TLS client is a change to [`crate::http`], not to
//! this parser.
//!
//! Nothing here is a general URL implementation: no userinfo, no query, no fragment, no relative
//! references. Each of those is refused by name (`url_query_unsupported`, …) instead of being dropped,
//! because a silently-dropped query string is a credential that stopped being sent with no line in a
//! log to say so.

/// The port a scheme means when the URL names none.
pub const DEFAULT_HTTP_PORT: u16 = 80;
/// See [`DEFAULT_HTTP_PORT`]. `https` is dialled by the plain-HTTP client; see the module note.
pub const DEFAULT_HTTPS_PORT: u16 = 443;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    /// `http` or `https`, lowercased. Absent in the URL means `http`.
    pub scheme: String,
    /// The host as written, without brackets: `example.com`, `127.0.0.1`, `::1`.
    pub host: String,
    /// The explicit port, or the scheme's default.
    pub port: u16,
    /// What [`crate::http`] is handed: `host:port`, with an IPv6 literal bracketed.
    pub address: String,
    /// The URL's path, without a trailing slash; empty when the URL names none.
    pub prefix: String,
    /// Whether the URL said `https`. Only ever used to explain a transport failure: there is no TLS.
    pub tls: bool,
}

impl Endpoint {
    /// The request path for one call: the URL's prefix, then the route.
    pub fn path(&self, route: &str) -> String {
        let route = if route.starts_with('/') { route.to_string() } else { format!("/{route}") };
        if self.prefix.is_empty() {
            route
        } else {
            format!("{}{}", self.prefix, route)
        }
    }
}

/// Parse a service address. Errors are lower-case snake with a `url_` prefix and no URL text in them,
/// so an audit line or a report can carry the reason without carrying the address.
pub fn parse_base(url: &str) -> Result<Endpoint, String> {
    let text = url.trim();
    if text.is_empty() {
        return Err("url_empty".into());
    }
    if text.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err("url_whitespace".into());
    }
    if text.contains('?') {
        return Err("url_query_unsupported".into());
    }
    if text.contains('#') {
        return Err("url_fragment_unsupported".into());
    }
    let (scheme, rest) = match text.split_once("://") {
        Some((scheme, rest)) => (Some(scheme.to_ascii_lowercase()), rest.to_string()),
        None => (None, text.to_string()),
    };
    if let Some(scheme) = &scheme {
        if scheme.is_empty()
            || !scheme.chars().all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.')
        {
            return Err("url_scheme_invalid".into());
        }
    }
    let rest = rest.trim_start_matches("//");
    let (authority, path) = match rest.split_once('/') {
        Some((authority, path)) => (authority, path),
        None => (rest, ""),
    };
    if authority.is_empty() {
        return Err("url_host_missing".into());
    }
    if authority.contains('@') {
        return Err("url_userinfo_unsupported".into());
    }
    let (host, port_text) = split_authority(authority)?;
    if host.is_empty() || host.len() > 253 {
        return Err("url_host_invalid".into());
    }
    let (default_port, tls) = match scheme.as_deref() {
        None | Some("http") => (DEFAULT_HTTP_PORT, false),
        Some("https") => (DEFAULT_HTTPS_PORT, true),
        Some(other) => return Err(format!("url_scheme_unsupported:{other}")),
    };
    let port = match port_text {
        None => default_port,
        Some(value) => match value.parse::<u16>() {
            Ok(0) | Err(_) => return Err("url_port_invalid".into()),
            Ok(port) => port,
        },
    };
    let bracketed = host.contains(':');
    let address = if bracketed { format!("[{host}]:{port}") } else { format!("{host}:{port}") };
    // `split_once('/')` gives the path without its leading slash; the prefix is the URL's path with one,
    // because that is what a request path is built from.
    let trimmed = path.trim_end_matches('/');
    let prefix = if trimmed.is_empty() { String::new() } else { format!("/{trimmed}") };
    Ok(Endpoint {
        scheme: scheme.unwrap_or_else(|| "http".into()),
        host,
        port,
        address,
        prefix,
        tls,
    })
}

/// `host`, `host:port`, `[v6]`, `[v6]:port`. An unbracketed authority with more than one colon is an
/// IPv6 literal written the sloppy way, and it is taken as the host with no port (RFC 3986 requires the
/// brackets the moment a port is named, and guessing which colon was the port is how a "port" of
/// `db8::1` gets read).
fn split_authority(authority: &str) -> Result<(String, Option<&str>), String> {
    if let Some(rest) = authority.strip_prefix('[') {
        let (host, after) = rest.split_once(']').ok_or_else(|| "url_host_invalid".to_string())?;
        if host.is_empty() {
            return Err("url_host_invalid".into());
        }
        return match after {
            "" => Ok((host.to_string(), None)),
            _ => match after.strip_prefix(':') {
                Some(port) => Ok((host.to_string(), Some(port))),
                None => Err("url_host_invalid".into()),
            },
        };
    }
    let colons = authority.matches(':').count();
    if colons == 0 {
        return Ok((authority.to_string(), None));
    }
    if colons == 1 {
        let (host, port) = authority.rsplit_once(':').ok_or_else(|| "url_host_invalid".to_string())?;
        return Ok((host.to_string(), Some(port)));
    }
    Ok((authority.to_string(), None))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_https_service_address_resolves_to_443_and_the_live_rollout_shape_parses() {
        // The 07/11 shape: scheme, host, no port, no path. `to_socket_addrs` was handed this whole
        // string and answered `invalid port value`.
        let endpoint = parse_base("https://rendezvous.example.com").expect("an https URL without a port");
        assert_eq!(endpoint.scheme, "https");
        assert_eq!(endpoint.host, "rendezvous.example.com");
        assert_eq!(endpoint.port, 443);
        assert_eq!(endpoint.address, "rendezvous.example.com:443");
        assert_eq!(endpoint.prefix, "");
        assert_eq!(endpoint.path("/relay/send"), "/relay/send");
        assert!(endpoint.tls);
    }

    #[test]
    fn http_defaults_to_80_and_an_explicit_port_wins() {
        let endpoint = parse_base("http://relay.example.net").expect("http URL");
        assert_eq!((endpoint.address.as_str(), endpoint.port), ("relay.example.net:80", 80));
        assert!(!endpoint.tls);
        let explicit = parse_base("https://relay.example.net:8443").expect("explicit port");
        assert_eq!(explicit.address, "relay.example.net:8443");
        assert_eq!(explicit.port, 8443);
        let http_explicit = parse_base("http://127.0.0.1:8890").expect("loopback");
        assert_eq!(http_explicit.address, "127.0.0.1:8890");
        // A default port written out is the same endpoint as one left off, and a trailing dot at the
        // root is not a prefix.
        let written = parse_base("https://rendezvous.example.com:443/").expect("explicit 443");
        assert_eq!(written.prefix, "");
        assert_eq!(written.address, "rendezvous.example.com:443");
    }

    #[test]
    fn a_path_prefix_is_kept_and_prefixed_onto_the_route() {
        let endpoint = parse_base("https://gateway.example.com/fleet/relay/").expect("a URL with a path");
        assert_eq!(endpoint.prefix, "/fleet/relay");
        assert_eq!(endpoint.address, "gateway.example.com:443");
        assert_eq!(endpoint.path("/relay/send"), "/fleet/relay/relay/send");
        assert_eq!(endpoint.path("relay/send"), "/fleet/relay/relay/send", "a route without its slash is the same route");
        // No prefix: the route is the path, unchanged.
        assert_eq!(parse_base("http://127.0.0.1:8890").unwrap().path("/relay/send"), "/relay/send");
    }

    #[test]
    fn an_ipv6_literal_stays_bracketed_for_the_socket_and_the_host_header() {
        let endpoint = parse_base("https://[2001:db8::1]").expect("a bare IPv6 literal");
        assert_eq!(endpoint.host, "2001:db8::1");
        assert_eq!(endpoint.address, "[2001:db8::1]:443");
        let loopback = parse_base("http://[::1]:8890/base").expect("IPv6 with a port and a path");
        assert_eq!(loopback.address, "[::1]:8890");
        assert_eq!(loopback.prefix, "/base");
        // The sloppy form (no brackets, no port) is a host, never a host with a port of `db8::1`.
        assert_eq!(parse_base("http://::1").unwrap().address, "[::1]:80");
        assert!(parse_base("https://[::1").is_err());
    }

    #[test]
    fn a_bare_host_port_is_unchanged_because_that_is_what_the_tests_and_a_loopback_relay_write() {
        let endpoint = parse_base("127.0.0.1:54321").expect("bare host:port");
        assert_eq!(endpoint.scheme, "http");
        assert_eq!(endpoint.address, "127.0.0.1:54321");
        assert_eq!(endpoint.path("/relay/send"), "/relay/send");
        assert!(!endpoint.tls);
        // A bare name with no port is an http service on 80.
        assert_eq!(parse_base("relay.example.net").unwrap().address, "relay.example.net:80");
        assert_eq!(parse_base("  https://rendezvous.example.com  ").unwrap().port, 443);
        // The scheme is read case-insensitively, the way an operator's own file might write it.
        assert_eq!(parse_base("HTTPS://rendezvous.example.com").unwrap().port, 443);
    }

    #[test]
    fn what_the_parser_cannot_carry_is_refused_by_name_instead_of_dropped() {
        for (url, code) in [
            ("", "url_empty"),
            ("   ", "url_empty"),
            ("ftp://relay.example.net", "url_scheme_unsupported:ftp"),
            ("https://user:pw@relay.example.net", "url_userinfo_unsupported"),
            ("https://relay.example.net/relay/send?token=secret", "url_query_unsupported"),
            ("https://relay.example.net/#frag", "url_fragment_unsupported"),
            ("https://relay.example.net:0", "url_port_invalid"),
            ("https://relay.example.net:99999", "url_port_invalid"),
            ("http://relay example.net", "url_whitespace"),
            ("https://", "url_host_missing"),
        ] {
            let error = parse_base(url).unwrap_err();
            assert_eq!(error, code, "for {url:?}");
            assert!(!error.contains("secret"), "an error never echoes the URL: {error}");
        }
    }
}
