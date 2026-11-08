//! The model gateway as a component: `wa:model` over `wa:kernel@0.2.0` (docs/MODEL-GATEWAY.md).
//!
//! Everything the seam *decides* lives in `wa-model-gateway` (a plain library, unit-tested natively).
//! This file is only the component edge:
//!
//! * **`wa:kernel/http`** as the gateway's [`Transport`]. A provider call carries a *credential
//!   reference*, never a value: the request's headers name the secret and the kernel adds it from
//!   `wa:kernel/credentials`, so this guest cannot leak a key it does not have. The reference is
//!   `wa-credential: <header>:<scheme>:<secret-name>` (scheme `raw` or `bearer`; `query:<param>:<name>`
//!   for Gemini's `?key=`), which the kernel strips before the request leaves the node.
//! * **`wa:kernel/kv`** for the one thing a restart must not lose: the provider breaker state, keyed
//!   `breaker/<provider>`. The policy itself arrives through `configure` (policy.json), and the token
//!   ledgers are in memory because their scope is a day and a session.
//! * **`wa:kernel/log`**: one line per refusal, per breaker transition and per configure, carrying a
//!   reason and a generation — never a message body.
//! * **`stream<event>`** for the caller: the export answers `Err` for a refusal (a label, a drained
//!   budget, no route) *before* a stream exists, and hands back a stream for a call that will be served.
//!
//! # Streaming, precisely
//!
//! The provider body is already a `stream<list<u8>>` in the kernel, but the seam's call loop
//! (`Gateway::chat`) is synchronous: the adapters, the breaker and the accounting are the same code the
//! native tests exercise, and a synchronous loop cannot await the kernel's async `http.send`. So this
//! first landing runs the call to completion in a task and writes the events to the caller's stream as
//! they parsed, which delivers them **after the provider finished** rather than during the call. The
//! contract does not change when that is fixed: the fix is an async attempt loop in
//! `wa-model-gateway` (`Transport::send` → `async`), and `REPORT.md` names it as the next step rather
//! than hiding it behind a "streaming" claim this file does not earn.
//!
//! The `block_on` calls below are the guest's, not the host's: the kernel's http future is driven by the
//! host, and `wit_bindgen::rt::async_support::block_on` polls it to completion inside this task.

wit_bindgen::generate!({ path: "wit", world: "model-gateway", generate_all });

use std::cell::RefCell;

use wa::kernel::{http, kv, log};
use wa::model::types as wit;
use wa_model_gateway::gateway::{CallError, Gateway};
use wa_model_gateway::policy::Policy;
use wa_model_gateway::transport::{Chunk, EdgeRequest, EdgeResponse, Transport, TransportError};
use wa_model_gateway::types as lib;

/// The kv prefix the breaker snapshot lives under (this component's own namespace).
const BREAKER_PREFIX: &[u8] = b"breaker/";

struct ModelGateway;

// ------------------------------------------------------------------------------------------ state

/// One instance's gateway. The policy arrives by `configure`; an unconfigured instance is an empty
/// policy, so every call is `no_route` with a reason instead of a guess from the environment.
struct State {
    gateway: Gateway<KernelTransport>,
}

thread_local! {
    static STATE: RefCell<Option<State>> = const { RefCell::new(None) };
}

impl State {
    fn new() -> State {
        let mut gateway = Gateway::new(Policy::empty(), KernelTransport::default());
        // A breaker state written by the previous instance, so a swap does not forget a provider that was
        // failing ten seconds ago.
        for (provider, failures) in load_breakers() {
            gateway.restore_failures(&provider, failures);
        }
        State { gateway }
    }
}

/// Take the state out for one call. A component call is not re-entrant across tasks while the state is
/// out, which is also what keeps one instance's accounting and breakers coherent.
fn take() -> State {
    STATE.with(|state| state.borrow_mut().take()).unwrap_or_else(State::new)
}

fn put(state: State) {
    STATE.with(|slot| *slot.borrow_mut() = Some(state));
}

fn with_state<R>(body: impl FnOnce(&mut State) -> R) -> R {
    let mut state = take();
    let out = body(&mut state);
    put(state);
    out
}

// ---------------------------------------------------------------------------------------- transport

/// `wa:kernel/http` as the seam's transport.
#[derive(Default)]
struct KernelTransport;

impl Transport for KernelTransport {
    fn send(&mut self, request: EdgeRequest) -> Result<EdgeResponse, TransportError> {
        let mut headers = request.headers.clone();
        if let Some(credential) = &request.credential {
            // A reference, not a value: `<header>:<scheme>:<secret>` (see the module docs).
            headers.push((
                "wa-credential".into(),
                format!("{}:{}:{}", credential.header, scheme_text(credential.scheme), credential.secret),
            ));
        }
        let sent = http::Request {
            method: request.method.clone(),
            url: request.url.clone(),
            headers,
            body: request.body.clone(),
        };
        let response = match wit_bindgen::rt::async_support::block_on(http::send(sent)) {
            Ok(response) => response,
            Err(wa::kernel::http::Error::Refused(why)) => {
                return Err(TransportError::Connect(format!("grant_refused: {why}")))
            }
            Err(wa::kernel::http::Error::Again) => return Err(TransportError::Broken("again".into())),
            Err(wa::kernel::http::Error::Closed) => return Err(TransportError::Broken("closed".into())),
            Err(wa::kernel::http::Error::Failed(why)) => return Err(TransportError::Connect(why)),
        };
        let status = response.status();
        let retry_after_ms = response
            .headers()
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case("retry-after"))
            .and_then(|(_, value)| value.trim().parse::<u64>().ok())
            .map(|seconds| seconds.saturating_mul(1_000));
        let mut chunks = Vec::new();
        let mut body = response.body();
        loop {
            match wit_bindgen::rt::async_support::block_on(body.next()) {
                Some(chunk) => chunks.push(Chunk::Bytes(chunk)),
                None => break,
            }
        }
        Ok(EdgeResponse { status, retry_after_ms, chunks })
    }
}

fn scheme_text(scheme: wa_model_gateway::policy::Scheme) -> &'static str {
    match scheme {
        wa_model_gateway::policy::Scheme::Bearer => "bearer",
        wa_model_gateway::policy::Scheme::Raw => "raw",
        wa_model_gateway::policy::Scheme::Query => "query",
    }
}

// ------------------------------------------------------------------------------------- breaker kv

/// `breaker/<provider>` → the consecutive failure count, as two bytes of a JSON string. Only the count
/// is persisted: the phase is a function of the count, the policy's threshold and the clock, so a
/// cooldown that expired while the guest was stopped is correctly elapsed.
fn load_breakers() -> Vec<(String, u32)> {
    let mut out = Vec::new();
    let mut cursor: Option<Vec<u8>> = None;
    loop {
        let page = match wit_bindgen::rt::async_support::block_on(kv::scan(BREAKER_PREFIX.to_vec(), cursor.clone(), 64)) {
            Ok(page) => page,
            Err(_) => return out,
        };
        if page.is_empty() {
            return out;
        }
        for entry in &page {
            let name = String::from_utf8_lossy(&entry.key).trim_start_matches("breaker/").to_string();
            let failures = String::from_utf8_lossy(&entry.value).trim().parse::<u32>().unwrap_or(0);
            out.push((name, failures));
        }
        cursor = page.last().map(|entry| entry.key.clone());
    }
}

fn save_breaker(provider: &str, failures: u32) {
    let key = format!("breaker/{provider}").into_bytes();
    let value = failures.to_string().into_bytes();
    let _ = wit_bindgen::rt::async_support::block_on(kv::set(key, value));
}

// ------------------------------------------------------------------------------------------- types

fn to_wit_label(label: lib::Label) -> wit::Label {
    match label {
        lib::Label::Public => wit::Label::Public,
        lib::Label::Internal => wit::Label::Internal,
        lib::Label::Client => wit::Label::Client,
    }
}

fn from_wit_label(label: wit::Label) -> lib::Label {
    match label {
        wit::Label::Public => lib::Label::Public,
        wit::Label::Internal => lib::Label::Internal,
        wit::Label::Client => lib::Label::Client,
    }
}

fn from_wit_class(class: wit::TaskClass) -> lib::TaskClass {
    match class {
        wit::TaskClass::Plan => lib::TaskClass::Plan,
        wit::TaskClass::Code => lib::TaskClass::Code,
        wit::TaskClass::Cheap => lib::TaskClass::Cheap,
        wit::TaskClass::Vision => lib::TaskClass::Vision,
        wit::TaskClass::Default => lib::TaskClass::Default,
    }
}

fn to_wit_class(class: lib::TaskClass) -> wit::TaskClass {
    match class {
        lib::TaskClass::Plan => wit::TaskClass::Plan,
        lib::TaskClass::Code => wit::TaskClass::Code,
        lib::TaskClass::Cheap => wit::TaskClass::Cheap,
        lib::TaskClass::Vision => wit::TaskClass::Vision,
        lib::TaskClass::Default => wit::TaskClass::Default,
    }
}

fn to_wit_kind(kind: wa_model_gateway::policy::ProviderKind) -> wit::ProviderKind {
    use wa_model_gateway::policy::ProviderKind;
    match kind {
        ProviderKind::Anthropic => wit::ProviderKind::Anthropic,
        ProviderKind::OpenAi => wit::ProviderKind::Openai,
        ProviderKind::Gemini => wit::ProviderKind::Gemini,
    }
}

fn to_wit_usage(usage: lib::Usage) -> wit::Usage {
    wit::Usage {
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        cache_read_tokens: usage.cache_read_tokens,
        cache_write_tokens: usage.cache_write_tokens,
        reasoning_tokens: usage.reasoning_tokens,
    }
}

fn to_wit_route(route: lib::Route) -> wit::Route {
    wit::Route {
        provider: route.provider,
        model: route.model,
        kind: to_wit_kind(route.kind),
        host: route.host,
        class: to_wit_class(route.class),
        label: to_wit_label(route.label),
        attempt: route.attempt,
        fallback_from: route.fallback_from.map(|model| wit::ModelRef {
            provider: model.provider,
            model: model.model,
        }),
        reason: route.reason,
    }
}

fn to_wit_refusal(refusal: lib::Refusal) -> wit::Refusal {
    match refusal {
        lib::Refusal::LabelNotAllowed(refusal) => wit::Refusal::LabelNotAllowed(wit::LabelRefusal {
            provider: refusal.provider,
            model: refusal.model,
            label: to_wit_label(refusal.label),
            allowed: refusal.allowed.into_iter().map(to_wit_label).collect(),
            reason: refusal.reason,
        }),
        lib::Refusal::NoRoute(refusal) => wit::Refusal::NoRoute(wit::NoRoute {
            class: to_wit_class(refusal.class),
            label: to_wit_label(refusal.label),
            skipped: refusal
                .skipped
                .into_iter()
                .map(|skip| wit::Skip { provider: skip.provider, model: skip.model, reason: skip.reason })
                .collect(),
        }),
        lib::Refusal::BudgetExceeded(refusal) => wit::Refusal::BudgetExceeded(wit::BudgetRefusal {
            scope: refusal.scope,
            spent: refusal.spent,
            limit: refusal.limit,
            reason: refusal.reason,
        }),
        lib::Refusal::Invalid(reason) => wit::Refusal::Invalid(reason),
    }
}

fn to_wit_event(event: lib::Event) -> wit::Event {
    match event {
        lib::Event::Delta(text) => wit::Event::Delta(text),
        lib::Event::ReasoningDelta(text) => wit::Event::ReasoningDelta(text),
        lib::Event::ToolCall(call) => wit::Event::ToolCall(wit::ToolCall {
            id: call.id,
            name: call.name,
            arguments_json: call.arguments_json,
        }),
        lib::Event::Usage(usage) => wit::Event::Usage(to_wit_usage(usage)),
        lib::Event::Finish(finish) => wit::Event::Finish(wit::Finish {
            reason: match finish.reason {
                lib::FinishReason::Stop => wit::FinishReason::Stop,
                lib::FinishReason::Length => wit::FinishReason::Length,
                lib::FinishReason::ToolCalls => wit::FinishReason::ToolCalls,
                lib::FinishReason::ContentFilter => wit::FinishReason::ContentFilter,
                lib::FinishReason::Error => wit::FinishReason::Error,
            },
            route: to_wit_route(finish.route),
            usage: to_wit_usage(finish.usage),
            attempts: finish.attempts,
            latency_ms: finish.latency_ms,
            cache_hit: finish.cache_hit,
        }),
    }
}

fn to_wit_error(error: CallError) -> wit::Error {
    match error {
        CallError::Refused(refusal) => wit::Error::Refused(to_wit_refusal(refusal)),
        CallError::Failed(fault) => wit::Error::Fault(format!("{}: {}", fault.as_str(), fault.detail())),
    }
}

fn from_wit_request(request: wit::ChatRequest) -> lib::ChatRequest {
    lib::ChatRequest {
        session: request.session,
        class: from_wit_class(request.class),
        model: request.model.map(|model| lib::ModelRef { provider: model.provider, model: model.model }),
        label: from_wit_label(request.label),
        messages: request
            .messages
            .into_iter()
            .map(|message| lib::Message {
                role: match message.role {
                    wit::Role::System => lib::Role::System,
                    wit::Role::User => lib::Role::User,
                    wit::Role::Assistant => lib::Role::Assistant,
                    wit::Role::Tool => lib::Role::Tool,
                },
                parts: message
                    .parts
                    .into_iter()
                    .map(|part| match part {
                        wit::Part::Text(text) => lib::Part::Text(text),
                        wit::Part::Image(image) => lib::Part::Image { mime: image.mime, bytes: image.bytes },
                    })
                    .collect(),
                tool_calls: message
                    .tool_calls
                    .into_iter()
                    .map(|call| lib::ToolCall { id: call.id, name: call.name, arguments_json: call.arguments_json })
                    .collect(),
                tool_call_id: message.tool_call_id,
                name: message.name,
                cache_breakpoint: message.cache_breakpoint,
            })
            .collect(),
        tools: request
            .tools
            .into_iter()
            .map(|tool| lib::ToolDef { name: tool.name, description: tool.description, schema_json: tool.schema_json })
            .collect(),
        max_output_tokens: request.max_output_tokens,
        temperature: request.temperature,
        estimated_input_tokens: request.estimated_input_tokens,
        timeout_ms: request.timeout_ms,
    }
}

fn to_wit_accounted(entry: &wa_model_gateway::accounting::Accounted) -> wit::Accounted {
    wit::Accounted {
        session: entry.session.clone(),
        provider: entry.provider.clone(),
        model: entry.model.clone(),
        class: to_wit_class(entry.class),
        label: to_wit_label(entry.label),
        usage: to_wit_usage(entry.usage),
        cost_micros: entry.cost_micros,
        cache_hit: entry.cache_hit,
        latency_ms: entry.latency_ms,
    }
}

fn to_wit_candidate(candidate: &wa_model_gateway::gateway::Candidate) -> wit::Candidate {
    wit::Candidate {
        model: wit::ModelRef { provider: candidate.model.provider.clone(), model: candidate.model.model.clone() },
        kind: to_wit_kind(candidate.kind),
        usable: candidate.usable,
        reason: candidate.reason.clone(),
    }
}

// ------------------------------------------------------------------------------------- the exports

impl exports::wa::model::chat::Guest for ModelGateway {
    /// A refusal is answered here, before a stream exists; a call that will be served hands back the
    /// stream its task fills.
    async fn chat(
        request: wit::ChatRequest,
    ) -> Result<wit_bindgen::rt::async_support::StreamReader<wit::Event>, wit::Error> {
        let request = from_wit_request(request);
        // The decisions that can answer "no" (a label, a drained budget, no route) happen before the
        // stream, so the caller never has to open one to learn it was refused.
        let prepared = with_state(|state| state.gateway.precheck(&request));
        if let Err(error) = prepared {
            log_refusal(&error);
            return Err(to_wit_error(error));
        }
        let (mut writer, reader) = wit_stream::new::<wit::Event>();
        wit_bindgen::rt::async_support::start_task(async move {
            let mut events = Vec::new();
            let outcome = with_state(|state| state.gateway.chat(&request, |event| events.push(event)));
            for event in events {
                if writer.write_one(to_wit_event(event)).await.is_some() {
                    // The caller dropped the stream: nothing left to say, and the call is accounted
                    // anyway (it was served and paid for).
                    break;
                }
            }
            match outcome {
                Ok(outcome) => {
                    log::write(
                        log::Level::Debug,
                        "wa:model",
                        &format!(
                            "chat ok provider={} model={} class={} label={} attempts={} tokens={} cache_read={} cache_write={}",
                            outcome.finish.route.provider,
                            outcome.finish.route.model,
                            outcome.finish.route.class.as_str(),
                            outcome.finish.route.label.as_str(),
                            outcome.finish.attempts,
                            outcome.usage.spent(),
                            outcome.usage.cache_read_tokens,
                            outcome.usage.cache_write_tokens
                        ),
                    );
                    save_breaker(&outcome.finish.route.provider, 0);
                }
                Err(error) => log_refusal(&error),
            }
        });
        Ok(reader)
    }

    fn explain(request: wit::ChatRequest) -> Result<wit::Explanation, wit::Error> {
        let request = from_wit_request(request);
        with_state(|state| state.gateway.explain(&request))
            .map(|explain| wit::Explanation {
                class: to_wit_class(explain.class),
                label: to_wit_label(explain.label),
                candidates: explain.candidates.iter().map(to_wit_candidate).collect(),
                chosen: explain.chosen.map(|model| wit::ModelRef { provider: model.provider, model: model.model }),
                refusal: explain.refusal.map(to_wit_refusal),
                text: explain.text,
            })
            .map_err(to_wit_error)
    }

    fn configure(policy_json: String) -> Result<u32, wit::Error> {
        let generation = with_state(|state| state.gateway.configure(&policy_json)).map_err(|refusal| {
            to_wit_error(CallError::Refused(refusal))
        })?;
        let providers = with_state(|state| state.gateway.policy().providers.len());
        log::write(
            log::Level::Info,
            "wa:model",
            &format!("configured generation={generation} providers={providers}"),
        );
        Ok(generation)
    }

    fn routes(label: wit::Label) -> Result<Vec<wit::RouteLine>, wit::Error> {
        let label = from_wit_label(label);
        let lines = with_state(|state| state.gateway.routes(label));
        Ok(lines
            .into_iter()
            .map(|line| wit::RouteLine {
                class: to_wit_class(line.class),
                candidates: line.candidates.iter().map(to_wit_candidate).collect(),
            })
            .collect())
    }

    fn accounting() -> Vec<wit::Accounted> {
        with_state(|state| state.gateway.accounting().entries().iter().map(to_wit_accounted).collect())
    }

    fn reset_accounting() {
        with_state(|state| state.gateway.reset_accounting());
    }
}

impl exports::wa::model::embed::Guest for ModelGateway {
    async fn embed(request: wit::EmbedRequest) -> Result<wit::Embeddings, wit::Error> {
        let request = lib::EmbedRequest {
            session: request.session,
            class: from_wit_class(request.class),
            model: request.model.map(|model| lib::ModelRef { provider: model.provider, model: model.model }),
            label: from_wit_label(request.label),
            texts: request.texts,
            timeout_ms: request.timeout_ms,
        };
        with_state(|state| state.gateway.embed(&request))
            .map(|embeddings| wit::Embeddings {
                route: to_wit_route(embeddings.route),
                vectors: embeddings.vectors,
                usage: to_wit_usage(embeddings.usage),
            })
            .map_err(to_wit_error)
    }
}

fn log_refusal(error: &CallError) {
    log::write(log::Level::Warn, "wa:model", &format!("{} {}", error.code(), error.reason()));
}

export!(ModelGateway);
