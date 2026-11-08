//! The gateway: one call, from the caller's request to a provider's stream and an account of it.
//!
//! The order below is the whole policy, and it is the same for `chat`, `embed` and `explain`:
//!
//! 1. **shape** — a malformed request is `invalid` before anything else happens;
//! 2. **label** — [`crate::route::plan_chat`] removes every provider whose `allowed_labels` do not cover
//!    the request; if that empties the route, the call is refused `label_not_allowed`, in the caller's
//!    vocabulary, with the reason that names the provider and the labels it does allow;
//! 3. **budget** — a drained node or session budget refuses before a byte leaves;
//! 4. **breaker** — a provider whose breaker is open is skipped (its reason recorded), and a half-open
//!    breaker admits exactly one trial call;
//! 5. **attempt** — the adapter builds the provider's call; the transport sends it; the body is scanned
//!    as SSE and each payload becomes an [`Event`];
//! 6. **fallback** — 429, 5xx, 401/403, timeout and transport failures are retryable: the breaker
//!    records the failure, the jittered backoff runs (the provider's `Retry-After` wins, up to the cap)
//!    and the next candidate is tried. A 4xx that is the request's own fault is not retried, and neither
//!    is a stream that broke after items were delivered: the reader has already seen that text.
//! 7. **accounting** — the usage the provider reported is charged to the ledger and recorded per
//!    session/model/class, cost included, and the `finish` event carries the route that served.
//!
//! Nothing here is silent: every exit is a typed value the caller can print, and the route that served a
//! call is in the `finish` event rather than in a log line the caller has to correlate.

use crate::accounting::{Accounted, Accounting};
use crate::adapter::{adapter_for, SseScanner, StreamItem};
use crate::backoff::retry_delay_ms;
use crate::breaker::{Breakers, Verdict};
use crate::budget::Ledger;
use crate::policy::{Policy, ProviderKind, ProviderSpec};
use crate::route::{plan_chat, plan_embed, Plan};
use crate::transport::{Chunk, EdgeRequest, Transport, TransportError};
use crate::types::{
    ChatRequest, EmbedRequest, Event, Fault, Finish, FinishReason, Label, ModelRef, Refusal, Route, TaskClass,
    ToolCall, Usage,
};

/// Time, injected: the breaker's cooldown and the latency numbers are the caller's clock.
pub trait Clock {
    fn now_ms(&self) -> u64;
}

/// The node's clock.
#[derive(Clone, Copy, Debug, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&self) -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_millis() as u64)
            .unwrap_or(0)
    }
}

/// A clock a test sets.
#[derive(Clone, Copy, Debug, Default)]
pub struct FixedClock(pub u64);

impl Clock for FixedClock {
    fn now_ms(&self) -> u64 {
        self.0
    }
}

/// The wait between a failed attempt and the next candidate.
///
/// The seam computes the delay either way and names it in the next route's reason; *whether* the caller
/// waits is the runtime's business. [`ImmediateWaiter`] records the delays and continues (the native
/// tests, and the guest, whose HTTP budget covers the wait); [`SleepWaiter`] really sleeps, for a caller
/// that wants the pacing inside the call.
pub trait Waiter {
    fn wait_ms(&mut self, ms: u64);
}

#[derive(Clone, Debug, Default)]
pub struct ImmediateWaiter {
    pub waited: Vec<u64>,
}

impl Waiter for ImmediateWaiter {
    fn wait_ms(&mut self, ms: u64) {
        self.waited.push(ms);
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct SleepWaiter;

impl Waiter for SleepWaiter {
    fn wait_ms(&mut self, ms: u64) {
        if ms > 0 {
            std::thread::sleep(std::time::Duration::from_millis(ms));
        }
    }
}

/// A failed call, in the two shapes the caller must tell apart.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CallError {
    /// A decision: the request was not sent, or not sent anywhere it could go.
    Refused(Refusal),
    /// A provider or transport broke (possibly mid-stream).
    Failed(Fault),
}

impl CallError {
    /// The name the loop logs and may show the model.
    pub fn code(&self) -> String {
        match self {
            CallError::Refused(refusal) => refusal.as_str().to_string(),
            CallError::Failed(fault) => fault.as_str().to_string(),
        }
    }

    /// A one-line reason, no message text.
    pub fn reason(&self) -> String {
        match self {
            CallError::Refused(refusal) => refusal.reason(),
            CallError::Failed(fault) => fault.detail().to_string(),
        }
    }
}

impl From<Refusal> for CallError {
    fn from(refusal: Refusal) -> Self {
        CallError::Refused(refusal)
    }
}

impl From<Fault> for CallError {
    fn from(fault: Fault) -> Self {
        CallError::Failed(fault)
    }
}

/// What a served call produced besides its stream.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Outcome {
    pub finish: Finish,
    pub text: String,
    pub tool_calls: Vec<ToolCall>,
    pub usage: Usage,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub model: ModelRef,
    pub kind: ProviderKind,
    pub usable: bool,
    pub reason: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Explain {
    pub class: TaskClass,
    pub label: Label,
    pub candidates: Vec<Candidate>,
    pub chosen: Option<ModelRef>,
    pub refusal: Option<Refusal>,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RouteLine {
    pub class: TaskClass,
    pub candidates: Vec<Candidate>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Embeddings {
    pub route: Route,
    pub vectors: Vec<Vec<f32>>,
    pub usage: Usage,
}

/// A call in flight: the plan, the attempt, the accounting.
pub struct Gateway<T: Transport> {
    policy: Policy,
    transport: T,
    clock: Box<dyn Clock>,
    waiter: Box<dyn Waiter>,
    breakers: Breakers,
    ledger: Ledger,
    accounting: Accounting,
    seed: u64,
}

impl<T: Transport> Gateway<T> {
    pub fn new(policy: Policy, transport: T) -> Gateway<T> {
        let mut breakers = Breakers::default();
        for (id, spec) in &policy.providers {
            breakers.configure(id, spec.breaker.clone());
        }
        let ledger = Ledger::new(policy.budgets.clone());
        Gateway {
            policy,
            transport,
            clock: Box::new(SystemClock),
            waiter: Box::new(ImmediateWaiter::default()),
            breakers,
            ledger,
            accounting: Accounting::default(),
            seed: 0x5DEE_CE66,
        }
    }

    pub fn with_clock(mut self, clock: impl Clock + 'static) -> Self {
        self.clock = Box::new(clock);
        self
    }

    pub fn with_waiter(mut self, waiter: impl Waiter + 'static) -> Self {
        self.waiter = Box::new(waiter);
        self
    }

    pub fn policy(&self) -> &Policy {
        &self.policy
    }

    pub fn transport(&self) -> &T {
        &self.transport
    }

    pub fn transport_mut(&mut self) -> &mut T {
        &mut self.transport
    }

    pub fn breakers(&self) -> &Breakers {
        &self.breakers
    }

    pub fn ledger(&self) -> &Ledger {
        &self.ledger
    }

    pub fn accounting(&self) -> &Accounting {
        &self.accounting
    }

    pub fn reset_accounting(&mut self) {
        self.accounting.reset();
    }

    /// Restore a breaker count persisted by a previous instance (the component's kv).
    pub fn restore_failures(&mut self, provider: &str, failures: u32) {
        let now = self.clock.now_ms();
        self.breakers.restore(provider, failures, now);
    }

    /// Install a new `models` section (the core's live reload). A malformed policy is refused and the
    /// previous one stays in force: a reload that could leave the node with no route is not a reload.
    pub fn configure(&mut self, policy_json: &str) -> Result<u32, Refusal> {
        let policy = Policy::parse(policy_json).map_err(Refusal::Invalid)?;
        for (id, spec) in &policy.providers {
            self.breakers.configure(id, spec.breaker.clone());
        }
        self.ledger.configure(policy.budgets.clone());
        let generation = policy.generation;
        self.policy = policy;
        Ok(generation)
    }

    /// The dry run: what `chat` would do, and why.
    pub fn explain(&mut self, request: &ChatRequest) -> Result<Explain, CallError> {
        request.validate().map_err(Refusal::Invalid)?;
        let now = self.clock.now_ms();
        let plan = plan_chat(&self.policy, request.class, request.label, request.model.as_ref(), &self.breakers, now);
        Ok(Explain {
            class: plan.class,
            label: plan.label,
            candidates: candidates(&plan),
            chosen: plan.usable().first().cloned(),
            refusal: plan.refusal.clone(),
            text: render(&plan, &self.policy),
        })
    }

    /// Every class's route at one label, for `wa models list`.
    pub fn routes(&mut self, label: Label) -> Vec<RouteLine> {
        let now = self.clock.now_ms();
        let mut out = Vec::new();
        for class in TaskClass::ALL {
            let plan = plan_chat(&self.policy, class, label, None, &self.breakers, now);
            out.push(RouteLine { class, candidates: candidates(&plan) });
        }
        out
    }

    /// Serve one turn, emitting each item as it arrives.
    pub fn chat(&mut self, request: &ChatRequest, on_event: impl FnMut(Event)) -> Result<Outcome, CallError> {
        let candidates = self.precheck(request)?;
        self.serve(request, candidates, on_event)
    }

    /// The decisions that come before any byte leaves — shape, label, budget, route — as one call.
    ///
    /// `chat` runs it and then serves; a component that must answer "can this be served at all?" before
    /// it starts a stream runs it alone. It is a *prediction*: `chat` is still the authority, because a
    /// budget can drain between the two calls.
    pub fn precheck(&mut self, request: &ChatRequest) -> Result<Vec<ModelRef>, CallError> {
        request.validate().map_err(Refusal::Invalid)?;
        let now = self.clock.now_ms();
        self.ledger.rollover(now);
        let plan = plan_chat(&self.policy, request.class, request.label, request.model.as_ref(), &self.breakers, now);
        if let Some(refusal) = plan.refusal.clone() {
            // A breaker is a temporary state, not a decision: a route emptied *only* because every
            // provider is cooling down is a failure the caller may retry, and saying `no_route` would
            // tell the loop to change its model instead of waiting.
            let all_cooling = match &refusal {
                Refusal::NoRoute(no_route) => {
                    !no_route.skipped.is_empty() && no_route.skipped.iter().all(|skip| skip.reason.contains("circuit_open"))
                }
                _ => false,
            };
            if all_cooling {
                return Err(CallError::Failed(Fault::Retryable { status: None, detail: refusal.reason() }));
            }
            return Err(CallError::Refused(refusal));
        }
        self.ledger
            .check(&request.session, request.estimated_input_tokens)
            .map_err(Refusal::BudgetExceeded)?;
        let max_attempts = self.policy.defaults.max_attempts.max(1) as usize;
        Ok(plan.usable().into_iter().take(max_attempts).collect())
    }

    fn serve(
        &mut self,
        request: &ChatRequest,
        candidates: Vec<ModelRef>,
        mut on_event: impl FnMut(Event),
    ) -> Result<Outcome, CallError> {
        let started = self.clock.now_ms();
        let mut last: Option<Fault> = None;
        let mut fallback_from: Option<ModelRef> = None;
        let mut attempt_index = 0usize;
        for model in &candidates {
            let Some(spec) = self.policy.provider(&model.provider).cloned() else { continue };
            let now = self.clock.now_ms();
            if let Err(reason) = self.breakers.admit(&spec.id, now) {
                last = Some(Fault::Retryable { status: None, detail: reason });
                continue;
            }
            attempt_index += 1;
            let mut adapter = adapter_for(spec.kind);
            // No request clone: the adapter takes the model it is serving alongside the request, so the
            // message list (the largest thing in a long session) is built once and read only.
            let edge = match adapter.build(&spec, request, &model.model) {
                Ok(edge) => edge,
                Err(refusal) => {
                    self.breakers.record(&spec.id, Verdict::CallerFailure, now);
                    if refusal.as_str() == "invalid" {
                        return Err(CallError::Refused(refusal));
                    }
                    last = Some(Fault::Shape(refusal.reason()));
                    continue;
                }
            };
            let after = last.as_ref().map(|fault| fault.detail().to_string());
            let route = Route {
                provider: spec.id.clone(),
                model: model.model.clone(),
                kind: spec.kind,
                host: spec.hosts.first().cloned().unwrap_or_default(),
                class: request.class,
                label: request.label,
                attempt: attempt_index as u32,
                fallback_from: fallback_from.clone(),
                reason: match after {
                    Some(detail) => format!("route#{} after {detail}", attempt_index),
                    None => format!("route#{}", attempt_index),
                },
            };
            match self.attempt(edge, &mut *adapter, &route, &mut on_event) {
                Ok(mut outcome) => {
                    let latency_ms = self.clock.now_ms().saturating_sub(started);
                    outcome.finish.latency_ms = latency_ms;
                    outcome.finish.attempts = attempt_index as u32;
                    let finish = outcome.finish.clone();
                    self.breakers.record(&spec.id, Verdict::Success, self.clock.now_ms());
                    self.ledger.charge(&request.session, finish.usage.spent());
                    self.accounting.record(Accounted {
                        session: request.session.clone(),
                        provider: spec.id.clone(),
                        model: model.model.clone(),
                        class: request.class,
                        label: request.label,
                        usage: finish.usage,
                        cost_micros: spec.rates.cost_micros(finish.usage),
                        cache_hit: finish.cache_hit,
                        latency_ms,
                    });
                    on_event(Event::Finish(finish));
                    return Ok(outcome);
                }
                Err(fault) => {
                    let now = self.clock.now_ms();
                    match &fault {
                        Fault::Retryable { .. } => {
                            self.breakers.record(&spec.id, Verdict::ProviderFailure(fault.detail()), now);
                        }
                        Fault::Status { .. } | Fault::Shape(_) => {
                            self.breakers.record(&spec.id, Verdict::CallerFailure, now);
                        }
                        Fault::StreamCut { .. } => {
                            // The provider served and then broke: not a caller fault, and not a retry.
                            self.breakers.record(&spec.id, Verdict::ProviderFailure(fault.detail()), now);
                            return Err(CallError::Failed(fault));
                        }
                    }
                    if !fault.retryable() {
                        return Err(CallError::Failed(fault));
                    }
                    if attempt_index < candidates.len() {
                        let delay = retry_delay_ms(
                            attempt_index as u32,
                            self.policy.defaults.backoff_ms,
                            self.policy.defaults.backoff_max_ms,
                            retry_after_hint(&fault),
                            self.next_seed(),
                        );
                        self.waiter.wait_ms(delay);
                    }
                    fallback_from = Some(model.clone());
                    last = Some(fault);
                }
            }
        }
        Err(CallError::Failed(last.unwrap_or(Fault::Retryable {
            status: None,
            detail: "no candidate could serve the request".into(),
        })))
    }

    /// One attempt: send, scan, emit. Returns the served outcome or the classified fault.
    fn attempt(
        &mut self,
        edge: EdgeRequest,
        adapter: &mut dyn crate::adapter::Adapter,
        route: &Route,
        on_event: &mut impl FnMut(Event),
    ) -> Result<Outcome, Fault> {
        let response = match self.transport.send(edge) {
            Ok(response) => response,
            Err(error) => return Err(retryable_transport(&error)),
        };
        if response.status != 200 {
            // The server's own hint rides in the detail, exactly as `lua/core/provider.lua` spells it, so a
            // `Retry-After` survives the seam instead of being dropped by it.
            let mut detail = format!("provider_http_{}: {}", response.status, first_line(&response.bytes()));
            if let Some(hint) = response.retry_after_ms {
                detail.push_str(&format!(" [retry_after_ms={hint}]"));
            }
            if retryable_status(response.status) {
                return Err(Fault::Retryable { status: Some(response.status), detail });
            }
            return Err(Fault::Status { status: response.status, detail });
        }
        let mut scanner = SseScanner::default();
        let mut usage = Usage::default();
        let mut text = String::new();
        let mut tool_calls = Vec::new();
        let mut reason: Option<FinishReason> = None;
        let mut emitted = false;
        let mut fault: Option<Fault> = None;
        let mut cut: Option<TransportError> = None;
        for chunk in &response.chunks {
            match chunk {
                Chunk::Bytes(bytes) => {
                    for payload in scanner.feed(bytes) {
                        fault = fault.or(self.absorb(
                            adapter.on_data(&payload),
                            &mut usage,
                            &mut text,
                            &mut tool_calls,
                            &mut reason,
                            &mut emitted,
                            on_event,
                        ));
                    }
                }
                Chunk::Fail(error) => {
                    cut = Some(error.clone());
                    break;
                }
            }
        }
        if let Some(payload) = scanner.flush() {
            fault = fault.or(self.absorb(
                adapter.on_data(&payload),
                &mut usage,
                &mut text,
                &mut tool_calls,
                &mut reason,
                &mut emitted,
                on_event,
            ));
        }
        fault = fault.or(self.absorb(adapter.finish(), &mut usage, &mut text, &mut tool_calls, &mut reason, &mut emitted, on_event));
        if let Some(error) = cut {
            // A reader that saw text has a problem to be told about, not a turn to be silently repeated.
            return Err(if emitted {
                Fault::StreamCut { detail: error.detail(), emitted: true }
            } else {
                retryable_transport(&error)
            });
        }
        if let Some(fault) = fault {
            return Err(if emitted {
                Fault::StreamCut { detail: fault.detail().to_string(), emitted: true }
            } else {
                fault
            });
        }
        if !scanner.saw_any() && !emitted {
            return Err(Fault::Shape("provider_200_with_no_events: the body carried no SSE event".into()));
        }
        let Some(reason) = reason else {
            return Err(Fault::Shape("provider_stream_without_finish: the stream ended with no finish".into()));
        };
        if reason == FinishReason::Error && !emitted {
            // An adapter that never recognized a single frame reports `error`; an answer that carried
            // nothing is a shape failure, not a successful empty reply.
            return Err(Fault::Shape("provider_stream_without_finish: the body carried no recognized event".into()));
        }
        Ok(Outcome {
            finish: Finish {
                reason,
                route: route.clone(),
                usage,
                attempts: route.attempt,
                latency_ms: 0,
                cache_hit: Finish::cache_hit(usage),
            },
            text,
            tool_calls,
            usage,
        })
    }

    /// Consume one adapter batch, emitting the caller's events and keeping the aggregates. Returns the
    /// first provider error the batch reported, if any.
    #[allow(clippy::too_many_arguments)]
    fn absorb(
        &mut self,
        items: Vec<StreamItem>,
        usage: &mut Usage,
        text: &mut String,
        tool_calls: &mut Vec<ToolCall>,
        reason: &mut Option<FinishReason>,
        emitted: &mut bool,
        on_event: &mut impl FnMut(Event),
    ) -> Option<Fault> {
        let mut fault = None;
        for item in items {
            match item {
                StreamItem::Delta(delta) => {
                    *emitted = true;
                    text.push_str(&delta);
                    on_event(Event::Delta(delta));
                }
                StreamItem::ReasoningDelta(delta) => {
                    *emitted = true;
                    on_event(Event::ReasoningDelta(delta));
                }
                StreamItem::ToolCallStart { .. } | StreamItem::ToolCallArgs { .. } => {}
                StreamItem::ToolCall(call) => {
                    *emitted = true;
                    tool_calls.push(call.clone());
                    on_event(Event::ToolCall(call));
                }
                StreamItem::Usage(total) => {
                    // The adapter reports its running total, not a delta: replacing (not adding) is what
                    // keeps a provider that repeats usage in every frame from being counted twice.
                    *usage = total;
                    on_event(Event::Usage(total));
                }
                StreamItem::Finish(finish) => *reason = Some(finish),
                StreamItem::Fault(detail) => {
                    fault = Some(Fault::Retryable { status: None, detail: format!("provider_error_event: {detail}") });
                }
            }
        }
        fault
    }

    /// Embed `texts` (OpenAI-compatible endpoints; a provider without an embedding route refuses).
    pub fn embed(&mut self, request: &EmbedRequest) -> Result<Embeddings, CallError> {
        if request.texts.is_empty() {
            return Err(CallError::Refused(Refusal::Invalid("embed: texts is empty".into())));
        }
        let now = self.clock.now_ms();
        self.ledger.rollover(now);
        let candidates = plan_embed(
            &self.policy,
            request.class,
            request.label,
            request.model.as_ref(),
            &self.breakers,
            now,
        )
        .map_err(CallError::Refused)?;
        let mut last: Option<Fault> = None;
        let mut attempt_index = 0usize;
        for model in &candidates {
            let Some(spec) = self.policy.provider(&model.provider).cloned() else { continue };
            let now = self.clock.now_ms();
            if let Err(reason) = self.breakers.admit(&spec.id, now) {
                last = Some(Fault::Retryable { status: None, detail: reason });
                continue;
            }
            attempt_index += 1;
            let Some(edge) = embed_request(&spec, model, request) else {
                last = Some(Fault::Shape(format!(
                    "embeddings_not_supported: {} ({}) has no embedding endpoint",
                    spec.id,
                    spec.kind.as_str()
                )));
                continue;
            };
            let route = Route {
                provider: spec.id.clone(),
                model: model.model.clone(),
                kind: spec.kind,
                host: spec.hosts.first().cloned().unwrap_or_default(),
                class: request.class,
                label: request.label,
                attempt: attempt_index as u32,
                fallback_from: None,
                reason: format!("embed#{}", attempt_index),
            };
            match self.transport.send(edge) {
                Ok(response) if response.status == 200 => {
                    let body = response.bytes();
                    let parsed = parse_embeddings(&body);
                    let Some((vectors, usage)) = parsed else {
                        return Err(CallError::Failed(Fault::Shape(
                            "provider_embeddings_shape: the answer carried no vectors".into(),
                        )));
                    };
                    let latency_ms = self.clock.now_ms().saturating_sub(now);
                    self.breakers.record(&spec.id, Verdict::Success, self.clock.now_ms());
                    self.ledger.charge(&request.session, usage.spent());
                    self.accounting.record(Accounted {
                        session: request.session.clone(),
                        provider: spec.id.clone(),
                        model: model.model.clone(),
                        class: request.class,
                        label: request.label,
                        usage,
                        cost_micros: spec.rates.cost_micros(usage),
                        cache_hit: false,
                        latency_ms,
                    });
                    return Ok(Embeddings { route, vectors, usage });
                }
                Ok(response) => {
                    let detail = format!("provider_http_{}: {}", response.status, first_line(&response.bytes()));
                    if retryable_status(response.status) {
                        self.breakers.record(&spec.id, Verdict::ProviderFailure(&detail), self.clock.now_ms());
                        last = Some(Fault::Retryable { status: Some(response.status), detail });
                    } else {
                        self.breakers.record(&spec.id, Verdict::CallerFailure, self.clock.now_ms());
                        return Err(CallError::Failed(Fault::Status { status: response.status, detail }));
                    }
                }
                Err(error) => {
                    self.breakers.record(&spec.id, Verdict::ProviderFailure(error.as_str()), self.clock.now_ms());
                    last = Some(retryable_transport(&error));
                }
            }
        }
        Err(CallError::Failed(last.unwrap_or(Fault::Retryable {
            status: None,
            detail: "no embedding candidate could serve the request".into(),
        })))
    }

    fn next_seed(&mut self) -> u64 {
        self.seed = self.seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.seed
    }
}

fn candidates(plan: &Plan) -> Vec<Candidate> {
    plan.choices
        .iter()
        .map(|choice| Candidate {
            model: choice.model.clone(),
            kind: choice.kind,
            usable: choice.usable,
            reason: choice.reason.clone(),
        })
        .collect()
}

fn retryable_status(status: u16) -> bool {
    matches!(status, 401 | 403 | 408 | 429) || (500..600).contains(&status)
}

fn retryable_transport(error: &TransportError) -> Fault {
    Fault::Retryable { status: None, detail: error.detail() }
}

/// The provider's `Retry-After`, when the transport carried it into the fault's detail.
fn retry_after_hint(fault: &Fault) -> Option<u64> {
    let detail = fault.detail();
    let rest = detail.split("retry_after_ms=").nth(1)?;
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse::<u64>().ok()
}

fn first_line(body: &[u8]) -> String {
    let text = String::from_utf8_lossy(body);
    let line = text.lines().next().unwrap_or("").trim();
    let mut out: String = line.chars().take(200).collect();
    if line.chars().count() > 200 {
        out.push('…');
    }
    out
}

/// The embedding call for the two families that have one.
fn embed_request(spec: &ProviderSpec, model: &ModelRef, request: &EmbedRequest) -> Option<EdgeRequest> {
    let (path, body) = match spec.kind {
        ProviderKind::OpenAi => (
            "embeddings".to_string(),
            serde_json::json!({"model": model.model, "input": request.texts}),
        ),
        ProviderKind::Gemini => (
            format!("models/{}:batchEmbedContents", model.model),
            serde_json::json!({
                "requests": request
                    .texts
                    .iter()
                    .map(|text| serde_json::json!({
                        "model": format!("models/{}", model.model),
                        "content": {"parts": [{"text": text}]},
                    }))
                    .collect::<Vec<_>>(),
            }),
        ),
        // Anthropic publishes no embedding endpoint; the route is refused rather than guessed.
        ProviderKind::Anthropic => return None,
    };
    let base = spec.base_url.trim_end_matches('/');
    let base = if spec.kind == ProviderKind::Gemini && !base.ends_with("/v1beta") && !base.ends_with("/v1") {
        format!("{base}/v1beta")
    } else {
        base.to_string()
    };
    Some(EdgeRequest {
        method: "POST".into(),
        url: format!("{base}/{path}"),
        headers: vec![("content-type".into(), "application/json".into())],
        body: serde_json::to_vec(&body).ok()?,
        credential: spec.credential.clone(),
    })
}

fn parse_embeddings(body: &[u8]) -> Option<(Vec<Vec<f32>>, Usage)> {
    let payload: serde_json::Value = serde_json::from_slice(body).ok()?;
    let mut vectors = Vec::new();
    if let Some(data) = payload.get("data").and_then(|data| data.as_array()) {
        for entry in data {
            let vector = entry.get("embedding")?.as_array()?;
            vectors.push(vector.iter().map(|value| value.as_f64().unwrap_or(0.0) as f32).collect());
        }
    } else if let Some(list) = payload.get("embeddings").and_then(|list| list.as_array()) {
        for entry in list {
            let vector = entry.get("values")?.as_array()?;
            vectors.push(vector.iter().map(|value| value.as_f64().unwrap_or(0.0) as f32).collect());
        }
    }
    if vectors.is_empty() {
        return None;
    }
    let usage = payload
        .get("usage")
        .or_else(|| payload.get("usageMetadata"))
        .map(|usage| Usage {
            input_tokens: usage
                .get("prompt_tokens")
                .or_else(|| usage.get("promptTokenCount"))
                .and_then(|value| value.as_u64())
                .unwrap_or(0),
            ..Usage::default()
        })
        .unwrap_or_default();
    Some((vectors, usage))
}

/// The `wa models explain` rendering: one line per candidate, then the decision.
pub fn render(plan: &Plan, policy: &Policy) -> String {
    let mut out = format!("class {} label {}\n", plan.class.as_str(), plan.label.as_str());
    for choice in &plan.choices {
        let labels = policy
            .provider(&choice.model.provider)
            .map(|spec| spec.labels_text())
            .unwrap_or_else(|| "-".into());
        out.push_str(&format!(
            "  {} {} ({}, allows {}) — {}\n",
            if choice.usable { "✓" } else { "✗" },
            choice.model.as_string(),
            choice.kind.as_str(),
            labels,
            choice.reason
        ));
    }
    match (&plan.refusal, plan.usable().first()) {
        (Some(refusal), _) => out.push_str(&format!("refused: {}\n", refusal.reason())),
        (None, Some(model)) => out.push_str(&format!("would call {}\n", model.as_string())),
        (None, None) => out.push_str("would call nothing\n"),
    }
    out
}
