//! The seam's own tests, driven through [`crate::gateway::Gateway`] with a mock transport: the label gate,
//! the fallback chain, the breaker, the budget, the cache-prefix parity, the accounting.
//!
//! Every assertion about "the request went here" is an assertion about the bytes the mock received, not
//! about the seam's opinion of itself: that is the difference between a label rule that exists and a label
//! rule that is enforced.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use crate::breaker::Phase;
use crate::gateway::{CallError, Clock, FixedClock, Gateway, Waiter};
use crate::policy::Policy;
use crate::route::plan_chat;
use crate::transport::{Chunk, EdgeResponse, EdgeRequest, MockTransport, Reply, TransportError};
use crate::types::{
    ChatRequest, EmbedRequest, Event, Fault, FinishReason, Label, Message, ModelRef, Part, Refusal, Role,
    TaskClass, ToolDef,
};

const POLICY: &str = r#"{
  "generation": 3,
  "providers": [
    {"id": "deepseek", "kind": "openai", "base_url": "https://api.deepseek.com/v1",
     "credential": {"secret": "DEEPSEEK_API_KEY", "header": "authorization", "scheme": "bearer"},
     "allowed_labels": ["public", "internal"],
     "models": ["deepseek-v4.1-flash", "deepseek-embed"],
     "rates": {"input_per_mtok": 1000000, "output_per_mtok": 2000000},
     "breaker": {"failures": 2, "cooldown_ms": 1000}},
    {"id": "anthropic", "kind": "anthropic", "base_url": "https://api.anthropic.com",
     "credential": {"secret": "ANTHROPIC_API_KEY", "header": "x-api-key", "scheme": "raw"},
     "allowed_labels": ["public", "internal", "client"],
     "models": ["claude-sonnet-4-5"],
     "breaker": {"failures": 2, "cooldown_ms": 1000},
     "rates": {"input_per_mtok": 3000000, "output_per_mtok": 15000000}}
  ],
  "routes": {"plan": ["deepseek/deepseek-v4.1-flash", "anthropic/claude-sonnet-4-5"],
             "code": ["deepseek/deepseek-v4.1-flash"],
             "default": ["deepseek/deepseek-v4.1-flash"]},
  "embeddings": {"default": ["deepseek/deepseek-embed"]},
  "budgets": {},
  "defaults": {"timeout_ms": 60000, "max_attempts": 3, "backoff_ms": 100, "backoff_max_ms": 8000}
}"#;

/// A clock a test can move, so a cooldown is a number and not a sleep.
#[derive(Clone, Default)]
struct ManualClock(Arc<AtomicU64>);

impl ManualClock {
    fn at(ms: u64) -> ManualClock {
        ManualClock(Arc::new(AtomicU64::new(ms)))
    }

    fn advance(&self, ms: u64) {
        self.0.fetch_add(ms, Ordering::SeqCst);
    }
}

impl Clock for ManualClock {
    fn now_ms(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

/// The waits a call asked for, shared with the test that owns the gateway.
#[derive(Clone, Default)]
struct RecordingWaiter(Arc<std::sync::Mutex<Vec<u64>>>);

impl Waiter for RecordingWaiter {
    fn wait_ms(&mut self, ms: u64) {
        self.0.lock().expect("waits").push(ms);
    }
}

fn policy() -> Policy {
    Policy::parse(POLICY).expect("the fixture policy parses")
}

fn served(script: Vec<Reply>) -> Gateway<MockTransport> {
    Gateway::new(policy(), MockTransport::new(script)).with_clock(FixedClock(0))
}

fn request(class: TaskClass, label: Label, text: &str) -> ChatRequest {
    let mut system = Message::text(Role::System, "You are a careful agent.");
    system.cache_breakpoint = true;
    ChatRequest::new(
        "session-1",
        class,
        label,
        vec![system, Message::text(Role::User, text)],
    )
}

/// One OpenAI-compatible turn, framed the way the real edge frames it: the JSON is split across chunks so
/// a partial object is parsed once, whole.
fn openai_stream(text: &str, output_tokens: u64) -> Vec<String> {
    let frames = [
        r#"{"choices":[{"delta":{"role":"assistant","content":""}}]}"#.to_string(),
        format!(r#"{{"choices":[{{"delta":{{"content":"{text}"}}}}]}}"#),
        r#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#.to_string(),
        format!(
            r#"{{"choices":[],"usage":{{"prompt_tokens":40,"completion_tokens":{output_tokens},"prompt_cache_hit_tokens":30}}}}"#
        ),
    ];
    let mut chunks = Vec::new();
    let mut buffer = String::new();
    for frame in frames {
        buffer.push_str("data: ");
        buffer.push_str(&frame);
        buffer.push_str("\n\n");
    }
    // Split mid-frame on purpose: half the events arrive in the first read.
    let bytes = buffer.into_bytes();
    let split = bytes.len() / 2;
    chunks.push(String::from_utf8_lossy(&bytes[..split]).to_string());
    chunks.push(String::from_utf8_lossy(&bytes[split..]).to_string());
    chunks
}

/// Wrap data payloads in SSE framing (`data: …` + a blank line), the way a provider does.
fn framed(payloads: &[String]) -> Reply {
    let refs: Vec<&str> = payloads.iter().map(|payload| payload.as_str()).collect();
    Reply::sse(vec![String::from_utf8_lossy(&crate::transport::sse(&refs)).to_string()])
}

fn openai_reply(text: &str, output_tokens: u64) -> Reply {
    Reply::sse(openai_stream(text, output_tokens))
}

fn anthropic_reply(text: &str, output_tokens: u64) -> Reply {
    Reply::sse(vec![
        format!(
            "data: {}\n\n",
            r#"{"type":"message_start","message":{"usage":{"input_tokens":40,"cache_read_input_tokens":900}}}"#
        ),
        format!(
            "data: {}\n\n",
            format!(r#"{{"type":"content_block_delta","index":0,"delta":{{"type":"text_delta","text":"{text}"}}}}"#)
        ),
        format!(
            "data: {}\n\n",
            format!(r#"{{"type":"message_delta","delta":{{"stop_reason":"end_turn"}},"usage":{{"output_tokens":{output_tokens}}}}}"#)
        ),
        format!("data: {}\n\n", r#"{"type":"message_stop"}"#),
    ])
}

fn finish_of(events: &[Event]) -> FinishReason {
    events
        .iter()
        .rev()
        .find_map(|event| match event {
            Event::Finish(finish) => Some(finish.reason),
            _ => None,
        })
        .expect("a finish event")
}

// ----------------------------------------------------------------------------------------- the label

#[test]
fn a_client_request_never_reaches_a_provider_that_does_not_allow_it() {
    // The route names deepseek first: a client-labelled request must not even try it.
    let mut gateway = served(vec![anthropic_reply("client answer", 3)]);
    let mut events = Vec::new();
    let outcome = gateway
        .chat(&request(TaskClass::Plan, Label::Client, "a client's message"), |event| events.push(event))
        .expect("anthropic may serve a client request");

    let hosts: Vec<String> = gateway.transport().hosts();
    assert_eq!(hosts, vec!["api.anthropic.com"], "deepseek is not allowed to see client data");
    assert!(!gateway.transport().requests().iter().any(|request| request.url.contains("deepseek")));
    assert_eq!(outcome.finish.route.provider, "anthropic");
    assert_eq!(finish_of(&events), FinishReason::Stop);

    // Now a class whose only provider is deepseek: the call is refused, and nothing is sent.
    let mut gateway = served(vec![openai_reply("must not happen", 1)]);
    let error = gateway
        .chat(&request(TaskClass::Code, Label::Client, "client code"), |_| {})
        .expect_err("deepseek may not see client data");
    assert!(gateway.transport().requests().is_empty(), "no bytes left the node");
    match error {
        CallError::Refused(Refusal::LabelNotAllowed(refusal)) => {
            assert_eq!(refusal.provider, "deepseek");
            assert_eq!(refusal.label, Label::Client);
            assert_eq!(refusal.allowed, vec![Label::Public, Label::Internal]);
            assert!(refusal.reason.contains("allows public,internal"), "{}", refusal.reason);
            // The refusal a `client` turn gets must say what to do about it (08/11): the default
            // provider carries the operator's data and never a client's, so the operator names one that
            // may. `docs/MODEL-GATEWAY.md`, "Allowed labels".
            assert!(
                refusal.reason.contains("configure a provider allowed for client data"),
                "the client refusal is actionable: {}",
                refusal.reason
            );
            assert_eq!(refusal.reason.split(':').next(), Some("label_not_allowed"));
        }
        other => panic!("expected label_not_allowed, got {other:?}"),
    }
}

#[test]
fn internal_data_may_reach_a_provider_that_allows_it_and_the_reason_says_where() {
    let mut gateway = served(vec![openai_reply("ok", 2)]);
    let outcome = gateway
        .chat(&request(TaskClass::Default, Label::Internal, "internal note"), |_| {})
        .expect("deepseek allows internal");
    assert_eq!(outcome.finish.route.provider, "deepseek");
    assert_eq!(outcome.finish.route.reason, "route#1");
    assert_eq!(outcome.usage.cache_read_tokens, 30, "the mock reported a cache read");
    assert!(outcome.finish.cache_hit);
}

// ------------------------------------------------------------------------------------- the fallback

#[test]
fn a_429_falls_back_to_the_next_candidate_with_backoff_and_jitter() {
    let waiter_probe = RecordingWaiter::default();
    let waiter = waiter_probe.clone();
    let mut gateway = Gateway::new(policy(), MockTransport::new(vec![
        Reply::rate_limited(250),
        anthropic_reply("served by the fallback", 5),
    ]))
    .with_clock(FixedClock(0))
    .with_waiter(waiter);

    let mut events = Vec::new();
    let outcome = gateway
        .chat(&request(TaskClass::Plan, Label::Internal, "hello"), |event| events.push(event))
        .expect("the second candidate serves");

    assert_eq!(gateway.transport().hosts(), vec!["api.deepseek.com", "api.anthropic.com"]);
    assert_eq!(outcome.finish.attempts, 2);
    assert_eq!(outcome.finish.route.attempt, 2);
    assert_eq!(
        outcome.finish.route.fallback_from,
        Some(ModelRef::parse("deepseek/deepseek-v4.1-flash").expect("ref"))
    );
    assert!(outcome.finish.route.reason.starts_with("route#2 after provider_http_429"), "{}", outcome.finish.route.reason);
    let waited = waiter_probe.0.lock().expect("waits").clone();
    assert_eq!(waited.len(), 1, "one backoff between the two attempts");
    assert_eq!(waited[0], 250, "the provider's Retry-After is honoured over the computed 400 ms");
    assert_eq!(outcome.finish.route.provider, "anthropic");
}

#[test]
fn a_timeout_falls_back_and_a_caller_error_does_not() {
    // A timeout is retryable: the next candidate serves.
    let mut gateway = served(vec![Reply::timeout(), openai_reply("ok", 1)]);
    let policy_text = POLICY.replace(
        r#""plan": ["deepseek/deepseek-v4.1-flash", "anthropic/claude-sonnet-4-5"]"#,
        r#""plan": ["anthropic/claude-sonnet-4-5", "deepseek/deepseek-v4.1-flash"]"#,
    );
    gateway.configure(&policy_text).expect("reload");
    let outcome = gateway
        .chat(&request(TaskClass::Plan, Label::Internal, "hi"), |_| {})
        .expect("the fallback serves after a timeout");
    assert_eq!(outcome.finish.attempts, 2);
    assert_eq!(outcome.finish.route.provider, "deepseek");

    // A 400 is the request's own fault: no second provider is asked.
    let mut gateway = served(vec![Reply::status(400, "{\"error\":\"bad request\"}"), openai_reply("never", 1)]);
    let error = gateway
        .chat(&request(TaskClass::Default, Label::Internal, "hi"), |_| {})
        .expect_err("a 400 is not retried");
    assert_eq!(gateway.transport().requests().len(), 1);
    match error {
        CallError::Failed(Fault::Status { status, detail }) => {
            assert_eq!(status, 400);
            assert!(detail.contains("provider_http_400"), "{detail}");
        }
        other => panic!("expected a status fault, got {other:?}"),
    }
}

#[test]
fn a_stream_that_breaks_after_text_is_a_cut_and_never_a_retry() {
    let mut gateway = served(vec![Reply::Answer(EdgeResponse::cut(
        openai_stream("Hello", 3).into_iter().map(|chunk| chunk.into_bytes()).collect(),
        TransportError::Broken("connection reset".into()),
    ))]);
    let mut emitted = 0usize;
    let error = gateway
        .chat(&request(TaskClass::Default, Label::Internal, "hi"), |event| {
            if matches!(event, Event::Delta(_)) {
                emitted += 1;
            }
        })
        .expect_err("a cut stream is a failure");
    assert!(emitted > 0);
    assert_eq!(gateway.transport().requests().len(), 1, "the reader already saw text: no second call");
    match error {
        CallError::Failed(Fault::StreamCut { emitted, detail }) => {
            assert!(emitted);
            assert!(detail.contains("transport_broken"), "{detail}");
        }
        other => panic!("expected a stream cut, got {other:?}"),
    }
}

#[test]
fn a_stream_that_breaks_before_any_event_falls_back() {
    let mut gateway = served(vec![
        Reply::Answer(EdgeResponse::cut(vec![b"data: {\"choices\":".to_vec()], TransportError::Timeout)),
        anthropic_reply("served", 2),
    ]);
    let outcome = gateway
        .chat(&request(TaskClass::Plan, Label::Internal, "hi"), |_| {})
        .expect("nothing was shown to a reader, so the next candidate serves");
    assert_eq!(outcome.text, "served");
    assert_eq!(outcome.finish.attempts, 2);
}

#[test]
fn a_200_with_no_sse_event_is_a_shape_failure_not_an_empty_answer() {
    let mut gateway = served(vec![Reply::status(200, "<html>proxy error</html>")]);
    let error = gateway
        .chat(&request(TaskClass::Default, Label::Internal, "hi"), |_| {})
        .expect_err("an unusable body is a failure");
    assert!(matches!(error, CallError::Failed(Fault::Shape(_))));
}

// -------------------------------------------------------------------------------------- the breaker

#[test]
fn the_breaker_opens_after_the_threshold_and_a_trial_closes_it() {
    let clock = ManualClock::at(10_000);
    let mut gateway = Gateway::new(policy(), MockTransport::new(vec![
        Reply::status(503, "down"),
        Reply::status(503, "down"),
        // The third call is refused locally: no scripted reply is consumed.
        openai_reply("recovered", 2),
    ]))
    .with_clock(clock.clone());

    // failures: 2 in the policy fixture. Two turns on `code` (deepseek only) both fail.
    let first = gateway.chat(&request(TaskClass::Code, Label::Internal, "a"), |_| {});
    assert!(first.is_err());
    let second = gateway.chat(&request(TaskClass::Code, Label::Internal, "b"), |_| {});
    assert!(second.is_err());
    assert_eq!(gateway.transport().requests().len(), 2, "both attempts reached the provider");
    assert_eq!(gateway.breakers().phase("deepseek", 10_000), Phase::Open { until_ms: 11_000 });

    // While open, the provider is not called at all, and the reason names the cooldown.
    let error = gateway
        .chat(&request(TaskClass::Code, Label::Internal, "c"), |_| {})
        .expect_err("open breaker");
    assert_eq!(gateway.transport().requests().len(), 2, "no third call");
    match error {
        CallError::Failed(Fault::Retryable { detail, .. }) => assert!(detail.contains("circuit_open"), "{detail}"),
        other => panic!("expected circuit_open, got {other:?}"),
    }

    // After the cooldown exactly one trial is admitted; a success closes the breaker.
    clock.advance(1_000);
    let outcome = gateway
        .chat(&request(TaskClass::Code, Label::Internal, "d"), |_| {})
        .expect("the trial serves");
    assert_eq!(outcome.text, "recovered");
    assert_eq!(gateway.breakers().phase("deepseek", clock.now_ms()), Phase::Closed);
    assert_eq!(gateway.transport().requests().len(), 3);
}

// --------------------------------------------------------------------------------------- the budget

#[test]
fn a_drained_budget_refuses_before_the_provider_is_called() {
    let text = POLICY.replace(r#""budgets": {}"#, r#""budgets": {"session_tokens": 100}"#);
    let mut gateway = Gateway::new(Policy::parse(&text).expect("policy"), MockTransport::new(vec![
        openai_reply("ok", 80),
        openai_reply("must not happen", 1),
    ]))
    .with_clock(FixedClock(0));

    let mut request = request(TaskClass::Default, Label::Internal, "hi");
    request.estimated_input_tokens = Some(50);
    gateway.chat(&request, |_| {}).expect("fits");
    // The call used 40 + 80 tokens, so the session is over its 100-token budget.
    assert_eq!(gateway.ledger().session_spent("session-1"), 120);
    let error = gateway
        .chat(&request, |_| {})
        .expect_err("the budget is drained");
    assert_eq!(gateway.transport().requests().len(), 1, "the second call was not sent");
    match error {
        CallError::Refused(Refusal::BudgetExceeded(refusal)) => {
            assert_eq!(refusal.scope, "session:session-1");
            assert_eq!(refusal.spent, 120);
            assert_eq!(refusal.limit, 100);
            assert!(refusal.reason.starts_with("budget_exceeded"), "{}", refusal.reason);
        }
        other => panic!("expected budget_exceeded, got {other:?}"),
    }
}

// --------------------------------------------------------------------------- the prompt-cache parity

#[test]
fn the_body_a_gateway_call_sends_is_byte_identical_to_a_direct_adapter_call() {
    let mut gateway = served(vec![openai_reply("ok", 1)]);
    let mut request = request(TaskClass::Code, Label::Internal, "turn one");
    request.tools = vec![ToolDef {
        name: "read".into(),
        description: "read a file".into(),
        schema_json: r#"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#.into(),
    }];
    request.temperature = Some(0.0);
    gateway.chat(&request, |_| {}).expect("served");
    let through_gateway = gateway.transport().requests()[0].clone();

    let spec = policy().provider("deepseek").expect("deepseek").clone();
    let mut direct_request = request.clone();
    direct_request.model = Some(ModelRef::parse("deepseek/deepseek-v4.1-flash").expect("ref"));
    let direct: EdgeRequest = crate::adapter::adapter_for(spec.kind)
        .build(&spec, &direct_request, "deepseek-v4.1-flash")
        .expect("direct build");

    assert_eq!(through_gateway.body, direct.body, "the gateway must not edit the wire body");
    assert_eq!(through_gateway.url, direct.url);
    assert_eq!(through_gateway.headers, direct.headers);
    // The messages are in the caller's order, tools included, and the cache breakpoint is where the
    // caller put it (OpenAI-compatible endpoints have no request-side breakpoint field, and none is invented).
    let body = through_gateway.body_json();
    assert_eq!(body["messages"][0]["role"], "system");
    assert_eq!(body["messages"][1]["role"], "user");
    assert_eq!(body["tools"][0]["function"]["name"], "read");
}

#[test]
fn two_identical_turns_send_identical_prefix_bytes() {
    // The reason the gateway exists at all: a second turn in the same session must reuse the prefix. This
    // is the check `scripts/test-prompt-cache.lua` makes of the loop, made here of the seam: no clock, no
    // session id and no counter may leak into the body, and appending a turn may not move the prefix.
    let mut request = request(TaskClass::Default, Label::Internal, "turn one");
    let first_prefix = request.prefix();

    let mut first = served(vec![openai_reply("one", 1)]);
    first.chat(&request, |_| {}).expect("served");
    let first_body = first.transport().requests()[0].body.clone();

    // The same request, a different instance, a different wall clock: the same bytes.
    let mut second = Gateway::new(policy(), MockTransport::new(vec![openai_reply("one", 1), openai_reply("two", 1)]))
        .with_clock(ManualClock::at(1_700_000_000_000));
    second.chat(&request, |_| {}).expect("served");
    assert_eq!(first_body, second.transport().requests()[0].body, "identical requests send identical bytes");

    request.messages.push(Message::text(Role::Assistant, "one"));
    request.messages.push(Message::text(Role::User, "turn two"));
    assert_eq!(request.prefix(), first_prefix, "appending a turn never moves the prefix");
    let appended = request.clone();
    second.chat(&appended, |_| {}).expect("served");
    let grown = second.transport().requests()[1].body.clone();
    assert_ne!(grown, first_body, "a new turn does add bytes, after the prefix");
    let before = second.transport().requests()[0].body_json();
    let after = second.transport().requests()[1].body_json();
    assert_eq!(after["messages"][0], before["messages"][0], "the system prefix is unchanged");
    assert_eq!(after["messages"][1], before["messages"][1], "the first user turn is unchanged");
    assert_eq!(after["messages"].as_array().expect("messages").len(), 4, "the turn was appended");
}

// ------------------------------------------------------------------------------------ the accounting

#[test]
fn accounting_separates_session_model_and_class_and_prices_each_call() {
    let mut gateway = Gateway::new(policy(), MockTransport::new(vec![
        openai_reply("a", 10),
        anthropic_reply("b", 20),
    ]))
    .with_clock(FixedClock(0));
    let mut client = request(TaskClass::Plan, Label::Client, "client turn");
    client.model = Some(ModelRef::parse("anthropic/claude-sonnet-4-5").expect("ref"));
    gateway.chat(&request(TaskClass::Default, Label::Internal, "internal turn"), |_| {}).expect("deepseek");
    gateway.chat(&client, |_| {}).expect("anthropic");

    let entries = gateway.accounting().entries();
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].provider, "deepseek");
    assert_eq!(entries[0].label, Label::Internal);
    // 40 prompt tokens at 1000/mtok + 10 output at 2000/mtok = 40 + 20 micro-units.
    assert_eq!(entries[0].cost_micros, 60);
    assert_eq!(entries[1].provider, "anthropic");
    assert_eq!(entries[1].label, Label::Client);
    let totals = gateway.accounting().total_for("session-1", "claude-sonnet-4-5", TaskClass::Plan).expect("totals");
    assert_eq!(totals.calls, 1);
    assert_eq!(totals.usage.output_tokens, 20);
    assert_eq!(totals.cache_hits, 1, "anthropic's cache read was reported");
    // No record carries message text: the struct has no field for it, and this is the assertion that the
    // rule survives a change to the struct (a new `text` field would not break a compile here).
    let debug = format!("{:?}", entries);
    assert!(!debug.contains("internal turn") && !debug.contains("client turn"), "{debug}");
}

// ---------------------------------------------------------------------------------------- explain

#[test]
fn explain_answers_the_decision_without_sending_anything() {
    let mut gateway = served(vec![]);
    let explain = gateway
        .explain(&request(TaskClass::Code, Label::Client, "client code"))
        .expect("explain is a dry run");
    assert!(gateway.transport().requests().is_empty(), "explain sends nothing");
    assert!(explain.chosen.is_none());
    assert!(matches!(explain.refusal, Some(Refusal::LabelNotAllowed(_))));
    assert!(explain.text.contains("class code label client"), "{}", explain.text);
    assert!(
        explain.text.contains("deepseek/deepseek-v4.1-flash (openai, allows public,internal)"),
        "{}",
        explain.text
    );
    assert!(explain.text.contains("refused: label_not_allowed"), "{}", explain.text);

    let explain = gateway
        .explain(&request(TaskClass::Plan, Label::Internal, "hello"))
        .expect("explain");
    assert_eq!(explain.text.lines().count(), 4, "a header, two candidates and the decision: {}", explain.text);
    assert_eq!(explain.chosen, Some(ModelRef::parse("deepseek/deepseek-v4.1-flash").expect("ref")));
    assert!(explain.text.ends_with("would call deepseek/deepseek-v4.1-flash\n"), "{}", explain.text);
}

#[test]
fn routes_lists_every_class_at_one_label() {
    let mut gateway = served(vec![]);
    let lines = gateway.routes(Label::Client);
    assert_eq!(lines.len(), TaskClass::ALL.len());
    for line in &lines {
        assert_eq!(line.candidates.len(), if line.class == TaskClass::Plan { 2 } else { 1 });
        // At `client`, deepseek is never usable and anthropic always is.
        for candidate in &line.candidates {
            assert_eq!(candidate.usable, candidate.model.provider == "anthropic", "{candidate:?}");
        }
    }
}

// ---------------------------------------------------------------------------------------- reload

#[test]
fn a_reload_installs_the_new_routes_and_a_bad_one_keeps_the_old_policy() {
    let mut gateway = served(vec![openai_reply("ok", 1)]);
    let reloaded = POLICY
        .replace(r#""generation": 3"#, r#""generation": 9"#)
        .replace(
            r#""default": ["deepseek/deepseek-v4.1-flash"]"#,
            r#""default": ["anthropic/claude-sonnet-4-5"]"#,
        );
    assert_eq!(gateway.configure(&reloaded).expect("reload"), 9);
    let plan = plan_chat(gateway.policy(), TaskClass::Default, Label::Internal, None, gateway.breakers(), 0);
    assert_eq!(plan.usable()[0].provider, "anthropic");

    let error = gateway.configure(r#"{"providers": [], "routes": {"default": ["nobody/m"]}}"#).unwrap_err();
    assert_eq!(error.as_str(), "invalid");
    assert_eq!(gateway.policy().generation, 9, "the previous policy is still in force");
}

// ----------------------------------------------------------------------------------------- embed

#[test]
fn embeddings_route_like_chat_and_refuse_a_provider_that_has_none() {
    let mut gateway = served(vec![Reply::status(
        200,
        r#"{"data":[{"embedding":[0.1,0.2]},{"embedding":[0.3,0.4]}],"usage":{"prompt_tokens":6}}"#,
    )]);
    let embed = EmbedRequest {
        session: "session-1".into(),
        class: TaskClass::Default,
        model: None,
        label: Label::Internal,
        texts: vec!["a".into(), "b".into()],
        timeout_ms: None,
    };
    let answer = gateway.embed(&embed).expect("served");
    assert_eq!(answer.vectors, vec![vec![0.1f32, 0.2], vec![0.3, 0.4]]);
    assert_eq!(answer.usage.input_tokens, 6);
    assert_eq!(answer.route.provider, "deepseek");
    assert_eq!(gateway.transport().requests()[0].url, "https://api.deepseek.com/v1/embeddings");

    // Anthropic has no embedding endpoint: the route is refused, not guessed.
    let mut anthropic_only = POLICY.to_string();
    anthropic_only = anthropic_only.replace(
        r#""embeddings": {"default": ["deepseek/deepseek-embed"]}"#,
        r#""embeddings": {"default": ["anthropic/claude-sonnet-4-5"]}"#,
    );
    let mut gateway = Gateway::new(
        Policy::parse(&anthropic_only).expect("policy"),
        MockTransport::new(vec![openai_reply("never", 1)]),
    )
    .with_clock(FixedClock(0));
    let error = gateway.embed(&embed).expect_err("anthropic cannot embed");
    assert!(matches!(error, CallError::Failed(Fault::Shape(ref detail)) if detail.contains("embeddings_not_supported")));
    assert!(gateway.transport().requests().is_empty());

    // A client label on an embedding route obeys the same gate as a chat call.
    let mut gateway = served(vec![]);
    let mut client_embed = embed;
    client_embed.label = Label::Client;
    let error = gateway.embed(&client_embed).expect_err("deepseek may not embed client data");
    assert!(matches!(error, CallError::Refused(Refusal::LabelNotAllowed(_))));
    assert!(gateway.transport().requests().is_empty());
}

// ------------------------------------------------------------------------------------ ids and shapes

#[test]
fn every_attempt_is_classified_even_when_the_body_is_garbage() {
    // A 200 whose body is a JSON document that is not an SSE frame: no event, so it is a shape fault
    // naming the reason, never an empty answer.
    let mut gateway = served(vec![Reply::status(200, "{\"choices\":[]}")]);
    let error = gateway.chat(&request(TaskClass::Default, Label::Internal, "hi"), |_| {}).expect_err("no events");
    assert!(matches!(error, CallError::Failed(Fault::Shape(ref detail)) if detail.contains("no SSE event")));

    // A tool call whose arguments never became JSON is a fault the caller can see.
    let frames = vec![
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"read\",\"arguments\":\"{oops\"}}]}}]}"
            .to_string(),
    ];
    let mut gateway = served(vec![framed(&frames)]);
    let error = gateway.chat(&request(TaskClass::Default, Label::Internal, "hi"), |_| {}).expect_err("bad args");
    assert!(matches!(error, CallError::Failed(_)), "{error:?}");
    assert!(error.reason().contains("not JSON"), "{}", error.reason());
}

#[test]
fn a_tool_call_reaches_the_caller_assembled_and_counted_in_the_finish() {
    let frames = vec![
        r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read","arguments":""}}]}}]}"#.to_string(),
        r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":\"a.txt\"}"}}]}}]}"#.to_string(),
        r#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#.to_string(),
    ];
    let mut gateway = served(vec![framed(&frames)]);
    let mut calls = Vec::new();
    let outcome = gateway
        .chat(&request(TaskClass::Default, Label::Internal, "hi"), |event| {
            if let Event::ToolCall(call) = event {
                calls.push(call);
            }
        })
        .expect("served");
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].name, "read");
    assert_eq!(calls[0].arguments_json, "{\"path\":\"a.txt\"}");
    assert_eq!(outcome.tool_calls, calls);
    assert_eq!(outcome.finish.reason, FinishReason::ToolCalls);
}

#[test]
fn the_seam_never_holds_a_credential_value() {
    // The credential is a reference; the request carries the reference and the kernel resolves it.
    let mut gateway = served(vec![openai_reply("ok", 1)]);
    gateway.chat(&request(TaskClass::Default, Label::Internal, "hi"), |_| {}).expect("served");
    let sent = &gateway.transport().requests()[0];
    let credential = sent.credential.clone().expect("a reference");
    assert_eq!(credential.secret, "DEEPSEEK_API_KEY");
    assert_eq!(credential.header, "authorization");
    let headers = format!("{:?}", sent.headers);
    assert!(!headers.to_lowercase().contains("authorization"), "no value, no placeholder header: {headers}");
    assert!(!String::from_utf8_lossy(&sent.body).contains("DEEPSEEK_API_KEY"));
}

#[test]
fn a_request_part_is_carried_through_unchanged() {
    let mut request = request(TaskClass::Vision, Label::Internal, "look");
    request.messages.push(Message {
        role: Role::User,
        parts: vec![Part::Image { mime: "image/png".into(), bytes: vec![1, 2, 3] }],
        tool_calls: Vec::new(),
        tool_call_id: None,
        name: None,
        cache_breakpoint: false,
    });
    let mut gateway = served(vec![openai_reply("seen", 1)]);
    gateway.chat(&request, |_| {}).expect("served");
    let body = gateway.transport().requests()[0].body_json();
    let image = &body["messages"][2]["content"][1]["image_url"]["url"];
    assert_eq!(image, "data:image/png;base64,AQID");
}

#[test]
fn chunks_of_a_response_are_scanned_in_order_across_reads() {
    // One hand-built cut response whose single chunk ends mid-frame: the scanner keeps the tail.
    let mut gateway = served(vec![Reply::Answer(EdgeResponse {
        status: 200,
        retry_after_ms: None,
        chunks: vec![
            Chunk::Bytes(b"data: {\"choices\":[{\"delta\":{\"content\":\"Hel".to_vec()),
            Chunk::Bytes(b"lo\"}}]}\n\ndata: [DONE]\n\n".to_vec()),
        ],
    })]);
    let mut text = String::new();
    gateway
        .chat(&request(TaskClass::Default, Label::Internal, "hi"), |event| {
            if let Event::Delta(delta) = event {
                text.push_str(&delta);
            }
        })
        .expect("served");
    assert_eq!(text, "Hello");
}

#[test]
fn usage_replaces_rather_than_accumulates_across_frames() {
    // A provider that repeats its running usage in several frames must not be counted twice.
    let frames = vec![
        r#"{"choices":[{"delta":{"content":"a"}}],"usage":{"prompt_tokens":10,"completion_tokens":1}}"#.to_string(),
        r#"{"choices":[{"delta":{"content":"b"}}],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#.to_string(),
        r#"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":3}}"#.to_string(),
    ];
    let mut gateway = served(vec![framed(&frames)]);
    let outcome = gateway
        .chat(&request(TaskClass::Default, Label::Internal, "hi"), |_| {})
        .expect("served");
    assert_eq!(outcome.usage.input_tokens, 10);
    assert_eq!(outcome.usage.output_tokens, 3);
    assert_eq!(gateway.ledger().session_spent("session-1"), 13);
}
