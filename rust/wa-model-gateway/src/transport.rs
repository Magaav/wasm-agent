//! The provider transport seam, and the mock the tests speak through.
//!
//! The gateway never opens a socket: it hands an [`EdgeRequest`] to a [`Transport`] and reads an
//! [`EdgeResponse`] whose body arrives chunk by chunk, so a stream that breaks in the middle is a
//! value the seam can classify instead of an exception. In the node the transport is the component's
//! `wa:kernel/http@0.2.0` edge (the guest suspends between chunks); in the tests it is
//! [`MockTransport`], which records every request it received — that record is how "a `client` request
//! never reached this provider" is an assertion about bytes instead of a claim.

use std::collections::VecDeque;

use crate::policy::Credential;

/// One provider call as it leaves the seam.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EdgeRequest {
    pub method: String,
    pub url: String,
    /// Headers the adapter sets. No credential value is ever in here: `credential` is a reference the
    /// kernel resolves through `wa:kernel/credentials`.
    pub headers: Vec<(String, String)>,
    /// JSON at the provider edge: the model's own protocol.
    pub body: Vec<u8>,
    pub credential: Option<Credential>,
}

impl EdgeRequest {
    pub fn body_json(&self) -> serde_json::Value {
        serde_json::from_slice(&self.body).unwrap_or(serde_json::Value::Null)
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TransportError {
    /// The provider did not answer inside the budget.
    Timeout,
    /// The exchange never started (DNS, TLS, refused).
    Connect(String),
    /// The body stopped arriving.
    Broken(String),
}

impl TransportError {
    pub fn as_str(&self) -> &'static str {
        match self {
            TransportError::Timeout => "timeout",
            TransportError::Connect(_) => "connect",
            TransportError::Broken(_) => "broken",
        }
    }

    pub fn detail(&self) -> String {
        match self {
            TransportError::Timeout => "transport_timeout".into(),
            TransportError::Connect(detail) => format!("transport_connect: {detail}"),
            TransportError::Broken(detail) => format!("transport_broken: {detail}"),
        }
    }
}

/// One chunk of a response body, or the reason the body ended early.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Chunk {
    Bytes(Vec<u8>),
    Fail(TransportError),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EdgeResponse {
    pub status: u16,
    pub retry_after_ms: Option<u64>,
    pub chunks: Vec<Chunk>,
}

impl EdgeResponse {
    /// A non-2xx answer: the body is there for the log line's first words, never for the model.
    pub fn status(status: u16, body: impl Into<String>) -> EdgeResponse {
        EdgeResponse { status, retry_after_ms: None, chunks: vec![Chunk::Bytes(body.into().into_bytes())] }
    }

    /// A body cut short after the given chunks.
    pub fn cut(chunks: Vec<Vec<u8>>, error: TransportError) -> EdgeResponse {
        let mut out: Vec<Chunk> = chunks.into_iter().map(Chunk::Bytes).collect();
        out.push(Chunk::Fail(error));
        EdgeResponse { status: 200, retry_after_ms: None, chunks: out }
    }

    pub fn bytes(&self) -> Vec<u8> {
        let mut out = Vec::new();
        for chunk in &self.chunks {
            if let Chunk::Bytes(bytes) = chunk {
                out.extend_from_slice(bytes);
            }
        }
        out
    }
}

pub trait Transport {
    fn send(&mut self, request: EdgeRequest) -> Result<EdgeResponse, TransportError>;
}

/// A scripted transport: one recorded request list, one queued reply per call.
#[derive(Clone, Debug, Default)]
pub struct MockTransport {
    requests: Vec<EdgeRequest>,
    script: VecDeque<Reply>,
}

#[derive(Clone, Debug)]
pub enum Reply {
    Answer(EdgeResponse),
    Fail(TransportError),
}

impl Reply {
    pub fn sse(chunks: Vec<String>) -> Reply {
        Reply::Answer(EdgeResponse {
            status: 200,
            retry_after_ms: None,
            chunks: chunks.into_iter().map(|chunk| Chunk::Bytes(chunk.into_bytes())).collect(),
        })
    }

    pub fn status(code: u16, body: &str) -> Reply {
        Reply::Answer(EdgeResponse::status(code, body))
    }

    pub fn rate_limited(retry_after_ms: u64) -> Reply {
        Reply::Answer(EdgeResponse { status: 429, retry_after_ms: Some(retry_after_ms), chunks: vec![Chunk::Bytes(b"{\"error\":\"slow down\"}".to_vec())] })
    }

    pub fn timeout() -> Reply {
        Reply::Fail(TransportError::Timeout)
    }
}

impl MockTransport {
    pub fn new(script: Vec<Reply>) -> MockTransport {
        MockTransport { requests: Vec::new(), script: script.into() }
    }

    /// Every request the seam sent, in order: the record a label test asserts on.
    pub fn requests(&self) -> &[EdgeRequest] {
        &self.requests
    }

    pub fn hosts(&self) -> Vec<String> {
        self.requests
            .iter()
            .map(|request| {
                let rest = request.url.split_once("://").map(|(_, rest)| rest).unwrap_or(&request.url);
                rest.split('/').next().unwrap_or("").to_string()
            })
            .collect()
    }

    pub fn push(&mut self, reply: Reply) {
        self.script.push_back(reply);
    }
}

impl Transport for MockTransport {
    fn send(&mut self, request: EdgeRequest) -> Result<EdgeResponse, TransportError> {
        self.requests.push(request);
        match self.script.pop_front() {
            Some(Reply::Answer(response)) => Ok(response),
            Some(Reply::Fail(error)) => Err(error),
            None => Err(TransportError::Connect("mock: no scripted reply".into())),
        }
    }
}

/// Build an SSE body from data payloads (`data: <payload>` + a blank line), the way every provider
/// under test frames an event.
pub fn sse(payloads: &[&str]) -> Vec<u8> {
    let mut out = Vec::new();
    for payload in payloads {
        out.extend_from_slice(b"data: ");
        out.extend_from_slice(payload.as_bytes());
        out.extend_from_slice(b"\n\n");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mock_records_every_request_it_receives() {
        let mut transport = MockTransport::new(vec![Reply::sse(vec!["data: {}\n\n".to_string()])]);
        let request = EdgeRequest {
            method: "POST".into(),
            url: "https://api.deepseek.com/v1/chat/completions".into(),
            headers: vec![("content-type".into(), "application/json".into())],
            body: b"{}".to_vec(),
            credential: None,
        };
        let response = transport.send(request.clone()).expect("scripted");
        assert_eq!(response.status, 200);
        assert_eq!(transport.requests(), &[request]);
        assert_eq!(transport.hosts(), vec!["api.deepseek.com"]);
        // An unscripted call is a transport failure, not a silent success.
        let error = transport
            .send(EdgeRequest { method: "POST".into(), url: "https://x/y".into(), headers: vec![], body: vec![], credential: None })
            .unwrap_err();
        assert_eq!(error.as_str(), "connect");
        assert!(error.detail().contains("no scripted reply"));
    }

    #[test]
    fn sse_frames_a_payload_the_way_providers_do() {
        assert_eq!(sse(&["{}"]), b"data: {}\n\n".to_vec());
    }

    #[test]
    fn a_cut_response_keeps_its_chunks_and_its_error() {
        let response = EdgeResponse::cut(vec![b"data: a\n\n".to_vec()], TransportError::Broken("reset".into()));
        assert_eq!(response.bytes(), b"data: a\n\n".to_vec());
        assert!(matches!(response.chunks.last(), Some(Chunk::Fail(TransportError::Broken(_)))));
    }
}
