//! The OPTIMIZATION CHECK for the model gateway: what a call costs *through* the seam, measured against
//! the same request built directly, plus the process's peak RSS.
//!
//! Run: `bash scripts/bench-model-gateway.sh` (which calls `cargo run -p wa-model-gateway --release
//! --example gateway-overhead`). It prints p50/p95 in microseconds per call and the peak RSS, so the
//! numbers are a measurement rather than a claim:
//!
//! * `body` — an adapter serializes one provider body from a prepared request;
//! * `decide` — the seam's decisions only: shape, session label, breaker, budget, route;
//! * `parse` — build the body and parse a whole SSE stream into items (the protocol work the loop pays
//!   today as well);
//! * `gateway` — the whole seam: decide, build, send (a zero-latency transport), scan, assemble, charge,
//!   account.
//!
//! The delta is what the seam *adds* to a call. It is a local measurement of local work: the provider's
//! own latency is not in it (there is no network here), which is exactly what an added-latency number
//! should isolate.

use std::time::Instant;

use wa_model_gateway::adapter::adapter_for;
use wa_model_gateway::gateway::{Gateway, Outcome};
use wa_model_gateway::policy::Policy;
use wa_model_gateway::transport::{Chunk, EdgeRequest, EdgeResponse, Reply, Transport, TransportError};
use wa_model_gateway::types::{
    ChatRequest, Event, Label, Message, Role, TaskClass, ToolDef,
};

const POLICY: &str = r#"{
  "providers": [
    {"id": "deepseek", "kind": "openai", "base_url": "https://api.deepseek.com/v1",
     "credential": {"secret": "DEEPSEEK_API_KEY", "header": "authorization", "scheme": "bearer"},
     "allowed_labels": ["public", "internal"], "models": ["deepseek-v4.1-flash"],
     "rates": {"input_per_mtok": 300, "output_per_mtok": 1200}},
    {"id": "anthropic", "kind": "anthropic", "base_url": "https://api.anthropic.com",
     "allowed_labels": ["public", "internal", "client"], "models": ["claude-sonnet-4-5"]}
  ],
  "routes": {"plan": ["deepseek/deepseek-v4.1-flash", "anthropic/claude-sonnet-4-5"],
             "default": ["deepseek/deepseek-v4.1-flash"]},
  "budgets": {"session_tokens": 1000000000},
  "defaults": {"timeout_ms": 60000, "max_attempts": 3, "backoff_ms": 100, "backoff_max_ms": 8000}
}"#;

/// A transport that answers in the same instant with a small, complete SSE turn: the gateway's own work is
/// what is being measured, so the provider must not contribute any wall time.
struct InstantTransport {
    body: Vec<u8>,
    status: u16,
}

impl Transport for InstantTransport {
    fn send(&mut self, _request: EdgeRequest) -> Result<EdgeResponse, TransportError> {
        Ok(EdgeResponse {
            status: self.status,
            retry_after_ms: None,
            chunks: vec![Chunk::Bytes(self.body.clone())],
        })
    }
}

fn openai_body(tokens: usize) -> Vec<u8> {
    let mut frames = Vec::new();
    frames.push(r#"{"choices":[{"delta":{"role":"assistant","content":""}}]}"#.to_string());
    for _ in 0..tokens {
        frames.push(r#"{"choices":[{"delta":{"content":"tok "}}]}"#.to_string());
    }
    frames.push(r#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#.to_string());
    frames.push(r#"{"choices":[],"usage":{"prompt_tokens":8000,"completion_tokens":256,"prompt_cache_hit_tokens":7500}}"#.to_string());
    let refs: Vec<&str> = frames.iter().map(|frame| frame.as_str()).collect();
    wa_model_gateway::transport::sse(&refs)
}

fn request() -> ChatRequest {
    let mut system = Message::text(Role::System, "You are a careful agent; read before you write.");
    system.cache_breakpoint = true;
    let mut request = ChatRequest::new("bench-session", TaskClass::Default, Label::Internal, vec![
        system,
        Message::text(Role::User, "why is the sky blue"),
    ]);
    request.max_output_tokens = 512;
    request.estimated_input_tokens = Some(2400);
    request.tools = vec![ToolDef {
        name: "read".into(),
        description: "read a file".into(),
        schema_json: r#"{"type":"object","properties":{"path":{"type":"string"}}}"#.into(),
    }];
    request
}

fn percentile(sorted: &[u128], fraction: f64) -> u128 {
    if sorted.is_empty() {
        return 0;
    }
    let index = ((sorted.len() as f64 - 1.0) * fraction).round() as usize;
    sorted[index]
}

fn report(label: &str, mut samples: Vec<u128>) {
    samples.sort_unstable();
    println!(
        "{label:>10}: p50 {:>7} us   p95 {:>7} us   p99 {:>7} us   (n={})",
        percentile(&samples, 0.50),
        percentile(&samples, 0.95),
        percentile(&samples, 0.99),
        samples.len()
    );
}

/// Peak RSS in KiB, where the OS tells us. On Windows the number is not available from a portable
/// probe; the line says so rather than printing a zero that would read as a measurement.
fn peak_rss_kib() -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("VmHWM:") {
            return rest.split_whitespace().next().and_then(|value| value.parse().ok());
        }
    }
    None
}

fn main() {
    let policy = Policy::parse(POLICY).expect("policy");
    let request = request();
    let body = openai_body(64);
    let spec = policy.provider("deepseek").expect("deepseek").clone();

    // Warm up: the first call in a process pays for allocation and page faults, and every later call is
    // what the operator's node will actually pay.
    for _ in 0..200 {
        let mut gateway = Gateway::new(policy.clone(), InstantTransport { body: body.clone(), status: 200 });
        let _ = gateway.chat(&request, |_| {});
    }

    let rounds = 5_000;
    let mut direct = Vec::with_capacity(rounds);
    let mut decision = Vec::with_capacity(rounds);
    let mut parsed = Vec::with_capacity(rounds);
    let mut gateway_samples = Vec::with_capacity(rounds);
    let mut gateway = Gateway::new(policy.clone(), InstantTransport { body: body.clone(), status: 200 });
    let mut request_with_model = request.clone();
    request_with_model.model = Some(wa_model_gateway::types::ModelRef::parse("deepseek/deepseek-v4.1-flash").expect("ref"));

    for _ in 0..rounds {
        let started = Instant::now();
        let _ = adapter_for(spec.kind).build(&spec, &request_with_model, "deepseek-v4.1-flash").expect("builds");
        direct.push(started.elapsed().as_micros());

        // The decisions alone: shape, label, breaker, budget, route. No body, no transport.
        let started = Instant::now();
        gateway.precheck(&request).expect("plan");
        decision.push(started.elapsed().as_micros());

        // The provider protocol alone: build the body and parse the whole SSE stream, which the loop pays
        // today as well (its own stream reader does the same work).
        let started = Instant::now();
        let edge = adapter_for(spec.kind).build(&spec, &request, "deepseek-v4.1-flash").expect("builds");
        let mut scanner = wa_model_gateway::adapter::SseScanner::default();
        let mut adapter = adapter_for(spec.kind);
        let mut items = 0usize;
        for payload in scanner.feed(&edge.body) {
            items += adapter.on_data(&payload).len();
        }
        items += adapter.finish().len();
        assert!(items > 0);
        parsed.push(started.elapsed().as_micros());

        let started = Instant::now();
        let outcome: Result<Outcome, _> = gateway.chat(&request, |_event: Event| {});
        outcome.expect("the instant transport always serves");
        let whole = started.elapsed().as_micros();
        gateway_samples.push(whole);
    }

    // A call that the provider refuses immediately: decide, send, classify. No stream parsing at all.
    let mut failing = Gateway::new(policy.clone(), InstantTransport { body: b"{\"error\":\"bad\"}".to_vec(), status: 400 });
    let mut failure_path = Vec::with_capacity(rounds);
    for _ in 0..rounds {
        let started = Instant::now();
        let _ = failing.chat(&request, |_event: Event| {});
        failure_path.push(started.elapsed().as_micros());
    }
    report("refused", failure_path);

    // The same call with a tiny stream (one delta, one finish, one usage): if this is as slow as the big
    // body, the cost is per call and not per event.
    let mut tiny_gateway = Gateway::new(
        policy.clone(),
        InstantTransport { body: wa_model_gateway::transport::sse(&[
            r#"{"choices":[{"delta":{"content":"hi"}}]}"#,
            r#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            r#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":1}}"#,
        ]), status: 200 },
    );
    let mut tiny = Vec::with_capacity(rounds);
    for _ in 0..rounds {
        let started = Instant::now();
        let _ = tiny_gateway.chat(&request, |_event: Event| {});
        tiny.push(started.elapsed().as_micros());
    }
    report("tiny", tiny);

    // Where the whole call's time goes, on the first and the last hundred calls: a number that grows with
    // the call count is a leak in the seam, not a cost of it.
    let first: Vec<u128> = gateway_samples.iter().take(100).copied().collect();
    let last: Vec<u128> = gateway_samples.iter().rev().take(100).copied().collect();
    report("first100", first);
    report("last100", last);
    let rss = peak_rss_kib();
    println!("model gateway: added latency per call (localhost transport, scripted SSE body of {} bytes)", body.len());
    report("body", direct);
    report("decide", decision);
    report("parse", parsed);
    report("gateway", gateway_samples);
    match rss {
        Some(kib) => println!("      RSS: {:>7} KiB peak (VmHWM)", kib),
        None => println!("      RSS: n/a on this platform (no /proc/self/status VmHWM)"),
    }
    let planning_only = gateway.routes(Label::Internal).len();
    println!("  accounting: {} records kept, {} route lines", gateway.accounting().len(), planning_only);
    // Keep a typed reference here so a change that widens the seam's output cannot silently pass the bench.
    let _shape: Option<Reply> = None;
}
