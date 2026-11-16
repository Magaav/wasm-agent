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
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_connect(Some(connect_timeout))
            .timeout_recv_response(Some(io_timeout))
            .timeout_recv_body(Some(io_timeout))
            .build()
            .into();
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
