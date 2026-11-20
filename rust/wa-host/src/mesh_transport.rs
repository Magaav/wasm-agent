//! The node's TLS transport for the mesh relay hop.
//!
//! `wa-mesh` keeps its plaintext client (the rendezvous binary uses the same crate and must not carry
//! a TLS stack), and the node injects this one: `ureq`, the stack `host.http` already uses, so there is
//! exactly one TLS implementation in the process and the mesh does not grow a second.
//!
//! Measured 16/11: pointing `WASM_AGENT_RELAY` at an `https` relay without this answered
//! `Connection reset by peer` in 16 ms — a cleartext write into a TLS port, indistinguishable from a
//! dead relay.

use std::io::Read;
use std::sync::Arc;
use std::time::Duration;

pub struct UreqTransport;

impl wa_mesh::http::Transport for UreqTransport {
    fn post(
        &self,
        url: &str,
        headers: &[(String, String)],
        body: &[u8],
        connect_timeout: Duration,
        io_timeout: Duration,
        max_body: usize,
    ) -> Result<wa_mesh::http::Response, String> {
        if body.len() > max_body {
            return Err("too_large".into());
        }
        // Certificate verification is ureq's default and is deliberately not configurable here: a
        // transport that can be told to skip verification is a transport that will be.
        //
        // Whose roots it verifies against is the machine's business, though: the relay may be a
        // node behind a private CA, and SSL_CERT_FILE / SSL_CERT_DIR is how that machine says so
        // (19/11: an https relay in a cloud sandbox was unreachable until a bridge was bolted on).
        // A bundle named there that cannot be read is this hop's refusal, not a quiet fall back.
        let mut builder = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_connect(Some(connect_timeout))
            .timeout_recv_response(Some(io_timeout))
            .timeout_recv_body(Some(io_timeout));
        // Only a TLS relay consults an anchor: a plain http:// hop must keep working when the
        // machine's bundle cannot be read (review r1, item 7).
        if wa_tls::is_tls(url) {
            builder = builder.tls_config(
                wa_tls::tls_config().map_err(|error| format!("tls_anchors_unavailable:{error}"))?,
            );
        }
        let agent: ureq::Agent = builder.build().into();
        let mut request = agent.post(url);
        for (name, value) in headers {
            request = request.header(name.as_str(), value.as_str());
        }
        let mut response = request
            .send(body)
            .map_err(|error| format!("tls_request_failed:{error}"))?;
        let status = response.status().as_u16();
        let mut out_headers: Vec<(String, String)> = Vec::new();
        for (name, value) in response.headers() {
            out_headers.push((
                name.as_str().to_string(),
                value.to_str().unwrap_or_default().to_string(),
            ));
        }
        let mut buffer: Vec<u8> = Vec::new();
        response
            .body_mut()
            .as_reader()
            .take(max_body as u64 + 1)
            .read_to_end(&mut buffer)
            .map_err(|error| format!("tls_body_failed:{error}"))?;
        if buffer.len() > max_body {
            return Err("too_large".into());
        }
        Ok(wa_mesh::http::Response {
            status,
            headers: out_headers,
            body: buffer,
        })
    }
}

/// The node's one TLS transport, ready to inject.
pub fn transport() -> Arc<dyn wa_mesh::http::Transport> {
    Arc::new(UreqTransport)
}

/// The relay hop's anchors, measured at the handshake.
///
/// `UreqTransport` is what the node injects into `wa-mesh` for the `https` relay hop, so these tests
/// call the trait method the mesh calls - `post` - against a real rustls server on a private CA.
#[cfg(test)]
mod tls_anchor_tests {
    use super::*;
    use std::time::Duration;
    use wa_mesh::http::Transport;
    use wa_tls::scratch::{self, Env, Server};

    fn post(url: &str) -> Result<wa_mesh::http::Response, String> {
        UreqTransport.post(url, &[("content-type".into(), "application/json".into())], b"{\"hello\":1}", Duration::from_secs(5), Duration::from_secs(10), 64 * 1024)
    }

    #[test]
    fn the_relay_hop_refuses_a_private_ca_that_no_bundle_names() {
        let _env = Env::clear();
        let server = Server::start();
        let error = post(&server.url("/relay/ask")).expect_err("a private CA is not in the compiled-in bundle");
        assert!(error.starts_with("tls_request_failed:"), "the hop names its own failure: {error}");
        assert!(!error.contains("timed out"), "a refused handshake is not a timeout: {error}");
    }

    #[test]
    fn the_relay_hop_reaches_a_private_ca_named_by_ssl_cert_file() {
        let _env = Env::set(&[(wa_tls::CERT_FILE, &scratch::cert_file())]);
        let server = Server::start();
        let response = post(&server.url("/relay/ask")).expect("the CA named by SSL_CERT_FILE");
        assert_eq!(response.status, 200);
        assert_eq!(response.body, b"ok");
    }

    #[test]
    fn the_relay_hop_reaches_a_private_ca_listed_in_ssl_cert_dir() {
        let dir = scratch::TempDir::new("relay-hop");
        dir.copy_fixture("ca.pem", "ca.pem");
        let _env = Env::set(&[(wa_tls::CERT_DIR, dir.path())]);
        let server = Server::start();
        let response = post(&server.url("/relay/ask")).expect("the CA in the directory SSL_CERT_DIR names");
        assert_eq!(response.status, 200);
    }

    /// A plain http:// hop consults no anchor: a bundle the machine cannot read must not stop the
    /// mesh talking to a cleartext relay (review r1, item 7).
    #[test]
    fn a_broken_bundle_does_not_refuse_a_plain_hop() {
        let _env = Env::set_text(wa_tls::CERT_FILE, "/nonexistent/wa-host/typo.pem");
        let server = Server::start_plain();
        let response = post(&server.url("/relay/ask")).expect("a plain hop needs no anchors");
        assert_eq!(response.status, 200);
        assert_eq!(response.body, b"ok");
    }

    #[test]
    fn a_broken_bundle_refuses_the_hop_with_the_bundle_in_the_message() {
        let _env = Env::set_text(wa_tls::CERT_FILE, "/nonexistent/wa-host/typo.pem");
        let server = Server::start();
        let error = post(&server.url("/relay/ask")).expect_err("a named source that cannot be read");
        assert!(error.starts_with("tls_anchors_unavailable:"), "{error}");
        assert!(error.contains("typo.pem"), "{error}");
    }
}
