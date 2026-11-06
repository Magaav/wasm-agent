//! The node half of queue phase 2 for speech: `rust/wa-stt-remote` wired to a real node.
//!
//! `docs/QUEUE.md` ("Phase 2") names four pieces the library does not own: the host route a remote
//! worker calls, the node side of the `stt_worker` role, the component, and the gate entry. This
//! module is the first two, in the node's own process:
//!
//! * **The producer.** One `stt.requests` queue (`wa_queue::Queue` over this node's kv, namespace
//!   `stt`, sub-prefix `q/`) plus the audio behind its fetch handles (`a/`), the
//!   [`Producer`](wa_stt_remote::producer::Producer) from the library, and the library's own
//!   `LocalWorker` running on a thread that *is* this node's warm recognizer (`service_stt`). A
//!   component's `wa:kernel/speech` request is enqueued (`service_stt::submit`) and settled by
//!   whichever worker wins the lease.
//! * **The relay handler.** [`call`] takes one signed node call from Lua
//!   (`lua/core/server.lua#node_capability`, capability `stt`) — already signature-checked by the
//!   peer verifier — and performs the library's admission (target, caller is one of the owner's
//!   nodes, timestamp, `rid` replay) before it touches the queue. The op bodies and refusals are the
//!   library's; the dispatch below is the same one `wa_stt_remote::sim::Relay` performs in the
//!   simulation, because the simulation is not compiled into the node.
//! * **The worker role.** A thread runs the library's blocking [`RemoteWorker::poll_once`]; its
//!   transport *tunnels* each signed call out to the node's Lua (`host.stt_pending` /
//!   `host.stt_deliver`) where `lua/core/nodes.lua` signs it. That keeps the node key in the one
//!   place that holds it, and keeps the decision logic in the library instead of a second Lua
//!   implementation of freshness, leases and segments.
//!
//! What this module deliberately does not do: decide freshness or leases (the queue and the
//! library's `Decoder` do), log message text (counters are ids and durations only,
//! `docs/QUEUE.md`), or own a key (the tunnel never sees one).

use std::collections::{BTreeMap, VecDeque};
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::Duration;

use serde_json::{json, Value};
use wa_queue::{Clock, JobId, JobState, Queue, SystemClock, TakeOutcome};
use wa_stt_remote::metrics::{Metrics, Who};
use wa_stt_remote::policy::{Latency, Preference, RemoteHealth};
use wa_stt_remote::producer::{Arrival, AudioStore, EnqueueFailure, LocalWorker, Producer, SttPolicy, QUEUE};
use wa_stt_remote::protocol::{
    Admission, AudioBody, Envelope, Op, Refusal, Reply, SettleBody, TakeBody, TakeReply, TransportSignature,
};
use wa_stt_remote::request::{self, AudioSource, Mime, SttRequest};
use wa_stt_remote::worker::{Outcome, Recognizer, RecognizerError, RemoteWorker, Segment, Transcript, Transport, WireError};

use crate::service_components::service_stt;
use crate::state_host::sub_namespace;

/// The queue name, from the library: one name, on the producing node only.
pub const STT_QUEUE: &str = QUEUE;

/// Is this process a configured producer (the node booted `lua/core/stt.lua` with `producer`)? A
/// node that is not keeps the direct warm-worker path (`service_stt::submit`), so a worker-only node
/// never enqueues a job nobody there can decode.
pub fn producing() -> bool {
    let runtime = node();
    let state = runtime.lock();
    state.started && state.config.produce
}

/// Test seam: one local poll (the library's `LocalWorker` over this runtime) and the component-slot
/// mirror, which is exactly what the local thread does around `poll_once`. The recognizer is the
/// library's `sim::FakeRecognizer`, so no model and no thread are involved.
#[cfg(test)]
pub(crate) fn local_poll_for_test(runtime: &Arc<Runtime>, recognizer: &mut dyn Recognizer) -> Outcome {
    let queue = runtime.queue();
    let audio = runtime.audio();
    let worker = LocalWorker { queue: &queue, audio: &audio, node: "producer".into(), lease_ms: 60_000, heartbeat_every_ms: 15_000 };
    let mut latency = Latency::new();
    let mut metrics = Metrics::new();
    let outcome = worker.poll_once(&Preference::default(), None, &mut latency, recognizer, &SystemClock, &mut metrics);
    if let Some(job) = outcome.job() {
        mirror(runtime, &queue, job);
    }
    outcome
}

/// How often the idle local worker re-checks an empty queue when nothing wakes it.
const IDLE_POLL: Duration = Duration::from_millis(250);

/// How long one tunnelled call may wait for the Lua pump to answer it. The relay holds ~20 s per
/// attempt, so this is the same budget `nodes.lua` gives one attempt; a pump that does not run (a
/// node that stopped) must end the call, not hang the worker thread.
const TUNNEL_TIMEOUT: Duration = Duration::from_secs(25);

/// How long a remote worker counts as attached after its last call. The policy's own sample lifetime
/// (`Preference::sample_ttl_ms`) is about latency; this is about presence.
const REMOTE_PRESENCE_MS: i64 = 90_000;

/// How many settled jobs the admin view keeps for "who did what" (ids and counts only).
const RECENT_KEPT: usize = 32;

/// The knobs the node's Lua hands over on boot (`lua/core/stt.lua`). Every field has a default, and
/// an absent field keeps it: a config nobody wrote must not silently become zero.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    /// This node's own id (the `to` of every envelope it admits).
    pub me: String,
    /// The owner's own node ids — the only callers a producing node admits.
    pub owner_nodes: Vec<String>,
    /// Enqueue and run the fallback worker (the WhatsApp node).
    pub produce: bool,
    /// Long-poll the producer and decode (the `stt_worker` node).
    pub work: bool,
    /// The producer's node id, for the envelopes this node sends. Empty = the worker does not poll.
    pub producer_id: String,
    /// The producer as a person writes it (name or id); used by the Lua pump's `nodes.find`.
    pub producer_name: String,
    pub lease_ms: i64,
    pub heartbeat_every_ms: i64,
    pub wait_ms: i64,
    pub fallback_after_ms: i64,
    pub sample_ttl_ms: i64,
    pub fresh_ms: i64,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            me: String::new(),
            owner_nodes: Vec::new(),
            produce: true,
            work: false,
            producer_id: String::new(),
            producer_name: String::new(),
            lease_ms: 60_000,
            heartbeat_every_ms: 15_000,
            wait_ms: 0,
            fallback_after_ms: 3_000,
            sample_ttl_ms: 10 * 60 * 1000,
            fresh_ms: wa_stt_remote::producer::DEFAULT_FRESH_MS,
        }
    }
}

impl Config {
    /// Read the node's own config document. `producer`/`worker` are booleans and the selector is
    /// `producer_name`, so "is this node the producer" and "which node is it" cannot be confused.
    fn from_json(value: &Value) -> Config {
        let default = Config::default();
        let number = |key: &str, fallback: i64| value.get(key).and_then(Value::as_i64).filter(|n| *n > 0).unwrap_or(fallback);
        let text = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or("").chars().take(128).collect::<String>();
        Config {
            me: text("me"),
            owner_nodes: value
                .get("owner_nodes")
                .and_then(Value::as_array)
                .map(|nodes| nodes.iter().filter_map(Value::as_str).filter(|id| !id.is_empty()).map(|id| id.chars().take(128).collect()).collect())
                .unwrap_or_default(),
            produce: value.get("producer").and_then(Value::as_bool).unwrap_or(default.produce),
            work: value.get("worker").and_then(Value::as_bool).unwrap_or(default.work),
            producer_id: text("producer_id"),
            producer_name: text("producer_name"),
            lease_ms: number("lease_ms", default.lease_ms),
            heartbeat_every_ms: number("heartbeat_every_ms", default.heartbeat_every_ms),
            wait_ms: value.get("wait_ms").and_then(Value::as_i64).filter(|n| *n >= 0).unwrap_or(default.wait_ms),
            fallback_after_ms: number("fallback_after_ms", default.fallback_after_ms),
            sample_ttl_ms: number("sample_ttl_ms", default.sample_ttl_ms),
            fresh_ms: number("fresh_ms", default.fresh_ms),
        }
    }
}

/// One attached worker, as the operator view names it: ids and counts, never a payload.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WorkerStat {
    pub last_seen_ms: i64,
    pub takes: u64,
    pub done: u64,
    pub failed: u64,
    pub ms_total: u64,
}

impl WorkerStat {
    fn average_ms(&self) -> Option<u64> {
        (self.done > 0).then(|| self.ms_total / self.done)
    }
}

/// One settled job, kept for the view (`by` is what the queue record cannot say).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Settled {
    pub job: u64,
    pub by: String,
    pub outcome: String,
    pub took_ms: i64,
}

/// A component waiting for one job: its slot (the `wa:kernel/speech` surface) and how many progress
/// entries have been copied into it already.
struct Waiter {
    slot: service_stt::JobSlot,
    seen: usize,
}

#[derive(Default)]
struct Tunnel {
    /// Calls the worker thread wants the node to sign and send: `(id, envelope json)`.
    pending: VecDeque<(u64, String)>,
    /// The reply channel of every call the node has taken but not answered yet.
    waiting: BTreeMap<u64, mpsc::Sender<String>>,
    /// Ids are allocated here, so two calls cannot share one `rid`.
    issued: u64,
}

struct State {
    config: Config,
    started: bool,
    admission: Option<Admission>,
    preference: Preference,
    policy: SttPolicy,
    /// Remote decodes settled on this node's queue (the handler's counters).
    metrics: Metrics,
    /// This node's own decodes (published by the local worker thread after each poll).
    local_metrics: Metrics,
    /// Decodes this node performed for *another* node's queue (published by the worker thread).
    worker_metrics: Metrics,
    /// When the queue's stale sweep last ran (it is a scan, not a per-tick job).
    last_sweep: Option<std::time::Instant>,
    local_latency: Latency,
    remote: RemoteHealth,
    workers: BTreeMap<String, WorkerStat>,
    waiters: BTreeMap<u64, Waiter>,
    recent: VecDeque<Settled>,
    last_remote_call_ms: i64,
    last_error: Option<String>,
}

/// The process's one runtime: this node's `stt.requests` queue, its audio, and the two threads.
pub struct Runtime {
    queue_ns: Arc<dyn wa_queue::Kv + Send + Sync>,
    audio_ns: Arc<dyn wa_queue::Kv + Send + Sync>,
    state: Mutex<State>,
    wake: (Mutex<u64>, Condvar),
    tunnel: Mutex<Tunnel>,
}

impl Runtime {
    pub fn new(queue_ns: Arc<dyn wa_queue::Kv + Send + Sync>, audio_ns: Arc<dyn wa_queue::Kv + Send + Sync>) -> Arc<Runtime> {
        Arc::new(Runtime {
            queue_ns,
            audio_ns,
            state: Mutex::new(State {
                config: Config::default(),
                started: false,
                admission: None,
                preference: Preference::default(),
                policy: SttPolicy::default(),
                metrics: Metrics::new(),
                local_metrics: Metrics::new(),
                worker_metrics: Metrics::new(),
                last_sweep: None,
                local_latency: Latency::new(),
                remote: RemoteHealth::offline(),
                workers: BTreeMap::new(),
                waiters: BTreeMap::new(),
                recent: VecDeque::new(),
                last_remote_call_ms: 0,
                last_error: None,
            }),
            wake: (Mutex::new(0), Condvar::new()),
            tunnel: Mutex::new(Tunnel::default()),
        })
    }

    /// A queue handle over this node's queue namespace. Cheap and stateless by design: the library
    /// keeps nothing in memory, so a restart is a new `Queue` over the same bytes.
    pub fn queue(&self) -> Queue {
        let kv: Arc<dyn wa_queue::Kv> = Arc::new(SyncKv(self.queue_ns.clone()));
        Queue::new(kv, Arc::new(SystemClock), wa_queue::Policy::default())
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn audio(&self) -> KvAudio {
        KvAudio { ns: self.audio_ns.clone() }
    }

    fn notify_local(&self) {
        let mut generation = self.wake.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        *generation = generation.wrapping_add(1);
        self.wake.1.notify_all();
    }

    /// Wait for a submit (or a bounded interval), so a single-node deployment does not pay a poll
    /// interval on the first segment of every voice note.
    fn wait_for_work(&self, timeout: Duration) {
        let generation = self.wake.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let value = *generation;
        let _ = self.wake.1.wait_timeout_while(generation, timeout, |current| *current == value);
    }
}

/// `wa_queue::Kv` is not declared `Send + Sync` (the library never needs it); the node's store is,
/// so this adapter is how a `Send + Sync` namespace becomes a queue store without an `unsafe`.
struct SyncKv(Arc<dyn wa_queue::Kv + Send + Sync>);

impl wa_queue::Kv for SyncKv {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, wa_queue::KvError> {
        self.0.get(key)
    }
    fn put(&self, key: &[u8], value: &[u8]) -> Result<(), wa_queue::KvError> {
        self.0.put(key, value)
    }
    fn del(&self, key: &[u8]) -> Result<(), wa_queue::KvError> {
        self.0.del(key)
    }
    fn scan_prefix(&self, prefix: &[u8]) -> Result<wa_queue::Entries, wa_queue::KvError> {
        self.0.scan_prefix(prefix)
    }
}

/// The audio behind a fetch handle: the producer's own kv namespace (`a/`), never a path the owner
/// did not grant.
struct KvAudio {
    ns: Arc<dyn wa_queue::Kv + Send + Sync>,
}

impl AudioStore for KvAudio {
    fn put(&self, handle: &str, bytes: &[u8]) -> Result<(), String> {
        self.ns.put(handle.as_bytes(), bytes).map_err(|error| error.0)
    }

    fn get(&self, handle: &str) -> Result<Option<Vec<u8>>, String> {
        self.ns.get(handle.as_bytes()).map_err(|error| error.0)
    }

    fn del(&self, handle: &str) -> Result<(), String> {
        self.ns.del(handle.as_bytes()).map_err(|error| error.0)
    }
}

/// The node's runtime, built once: the queue under `<components>/stt.state/kv.sqlite` `q/` and the
/// audio under `a/`, which is the same kv file and therefore the same durability and the same owner.
pub fn node() -> &'static Arc<Runtime> {
    static NODE: OnceLock<Arc<Runtime>> = OnceLock::new();
    NODE.get_or_init(|| {
        let dir = wa_host_support::paths::component_dir();
        Runtime::new(Arc::new(sub_namespace(&dir, "stt", "q/")), Arc::new(sub_namespace(&dir, "stt", "a/")))
    })
}

// ---- configuration ------------------------------------------------------------------------------

/// `host.stt_admin` action `configure`: read the node's role and knobs and (re)start the threads.
/// Called on boot and on a hot reload (`lua/core/stt.lua`). The answer names what is now running.
pub fn configure(request: &Value) -> Value {
    configure_on(node(), request)
}

fn configure_on(runtime: &Arc<Runtime>, request: &Value) -> Value {
    let config = Config::from_json(request);
    let enabled = config.produce || config.work;
    let start = {
        let mut state = runtime.lock();
        state.config = config.clone();
        state.admission = Some(Admission::new(config.me.clone(), config.owner_nodes.clone()));
        state.preference = Preference::from_settings(Some(config.fallback_after_ms), Some(config.sample_ttl_ms));
        state.policy = SttPolicy { fresh_ms: config.fresh_ms, ..SttPolicy::default() };
        let first = !state.started && enabled;
        if first {
            state.started = true;
        }
        first
    };
    if start {
        let for_local = runtime.clone();
        let _ = std::thread::Builder::new().name("wa-stt-local".into()).spawn(move || local_loop(for_local));
        let for_remote = runtime.clone();
        let _ = std::thread::Builder::new().name("wa-stt-remote".into()).spawn(move || remote_loop(for_remote));
    }
    if enabled {
        runtime.notify_local();
    }
    json!({
        "ok": true,
        "enabled": enabled,
        "producer": config.produce,
        "worker": config.work,
        "producer_id": config.producer_id,
        "producer_name": config.producer_name,
        "owners": config.owner_nodes.len(),
        "threads": if start { "started" } else { "already-running" },
    })
}

// ---- the producing side: enqueue ---------------------------------------------------------------

/// Why a submission did not become a job. `Stale` is a refusal on purpose: a note past its window is
/// never decoded (by anyone), so the caller turns it into the own-chat `audio_expired` alert.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnqueueProblem {
    Stale { fresh_until_ms: i64 },
    /// The queue (or the audio store) is not usable in this process; the caller may decode locally.
    Unavailable(String),
}

/// What one submission needs besides the bytes. The kernel's `wa:kernel/speech` call carries only
/// audio/mime/language, so those fields are synthesized there; a caller that knows the chat and the
/// send time (`host.stt_submit`) passes them and gets the real freshness window.
pub struct Submission {
    pub audio: Vec<u8>,
    pub mime: Mime,
    pub language: String,
    pub account: String,
    pub generation: u64,
    pub chat: String,
    pub msg: String,
    pub sent_at_ms: Option<i64>,
    pub declared_seconds: Option<u32>,
}

impl Submission {
    /// A note from a caller that knows nothing but the bytes (`wa:kernel/speech`): the ids are this
    /// node's ("kernel"), and the freshness window starts now — the earliest instant the node can
    /// honestly date it (`docs/WHATSAPP-TRANSCRIPTION.md`: the window belongs to the send time, so a
    /// caller that has it uses `host.stt_submit` instead).
    pub fn from_audio(audio: Vec<u8>, mime: Mime, language: &str) -> Submission {
        let stamp = SystemClock.now_ms();
        Submission {
            audio,
            mime,
            language: language.to_string(),
            account: "kernel".into(),
            generation: 0,
            chat: "kernel".into(),
            msg: format!("{stamp}-{}", next_id()),
            sent_at_ms: None,
            declared_seconds: None,
        }
    }

    pub fn from_json(value: &Value) -> Option<Submission> {
        let audio = request::base64_decode(value.get("audio_b64").and_then(Value::as_str)?)?;
        let mime = Mime::parse(value.get("mime").and_then(Value::as_str).unwrap_or("audio/ogg"))?;
        let text = |key: &str, fallback: &str| {
            value.get(key).and_then(Value::as_str).filter(|text| !text.is_empty()).unwrap_or(fallback).chars().take(request::MAX_ID_CHARS).collect::<String>()
        };
        Some(Submission {
            audio,
            mime,
            language: text("language", "pt"),
            account: text("account", "kernel"),
            generation: value.get("generation").and_then(Value::as_u64).unwrap_or(0),
            chat: text("chat", "kernel"),
            msg: text("msg", &format!("note-{}", next_id())),
            sent_at_ms: value.get("sent_at_ms").and_then(Value::as_i64),
            declared_seconds: value.get("declared_seconds").and_then(Value::as_u64).map(|seconds| seconds as u32),
        })
    }
}

/// Enqueue one note on this node's `stt.requests`, and (when a slot is given) keep that slot up to
/// date as workers progress and settle it.
pub(crate) fn enqueue(submission: Submission, waiter: Option<service_stt::JobSlot>) -> Result<u64, EnqueueProblem> {
    enqueue_on(node(), submission, waiter)
}

fn enqueue_on(runtime: &Arc<Runtime>, submission: Submission, waiter: Option<service_stt::JobSlot>) -> Result<u64, EnqueueProblem> {
    let policy = runtime.lock().policy.clone();
    let clock = SystemClock;
    let now_ms = clock.now_ms();
    let queue = runtime.queue();
    let audio_store = runtime.audio();
    let producer = Producer::new(&queue, &audio_store, policy, &clock);
    let arrival = Arrival {
        audio: submission.audio,
        mime: submission.mime,
        language: submission.language,
        account: submission.account,
        generation: submission.generation,
        chat: submission.chat,
        msg: submission.msg,
        sent_at_ms: submission.sent_at_ms.unwrap_or(now_ms),
        declared_seconds: submission.declared_seconds,
    };
    let handle = format!("{}-{}-{}", std::process::id(), now_ms, next_id());
    let mut scratch = Metrics::new();
    let outcome = match producer.enqueue(&arrival, &handle, &mut scratch) {
        Ok(outcome) => outcome,
        Err(EnqueueFailure::Stale { fresh_until_ms }) => return Err(EnqueueProblem::Stale { fresh_until_ms }),
        Err(error) => {
            let reason = error.to_string();
            runtime.lock().last_error = Some(format!("enqueue:{reason}"));
            return Err(EnqueueProblem::Unavailable(reason));
        }
    };
    let job = outcome.id.0;
    {
        let mut state = runtime.lock();
        state.metrics.enqueued += u64::from(!outcome.dedupe_hit);
        if let Some(slot) = waiter {
            state.waiters.insert(job, Waiter { slot, seen: 0 });
        }
    }
    runtime.notify_local();
    Ok(job)
}

/// `host.stt_submit`: an operator/test surface that submits audio with the real ids and send time.
/// The component path reaches the same function through `service_stt::submit`.
pub fn submit(request: &Value) -> Value {
    submit_on(node(), request)
}

fn submit_on(runtime: &Arc<Runtime>, request: &Value) -> Value {
    let Some(submission) = Submission::from_json(request) else {
        return json!({"refused": "malformed:request"});
    };
    match enqueue_on(runtime, submission, None) {
        Ok(job) => json!({"ok": {"job": job}}),
        Err(EnqueueProblem::Stale { fresh_until_ms }) => json!({"refused": format!("stale:{fresh_until_ms}")}),
        Err(EnqueueProblem::Unavailable(reason)) => json!({"error": format!("queue_unavailable:{reason}")}),
    }
}

// ---- the producing side: the relay handler ------------------------------------------------------

/// `host.stt_call`: one admitted call from a peer. `caller` is the node id the *transport* verified
/// (`wa_node_call`), so it cannot disagree with the envelope's `from`.
pub fn call(envelope_json: &str, caller: &str) -> String {
    call_on(node(), envelope_json, caller)
}

pub fn call_on(runtime: &Arc<Runtime>, envelope_json: &str, caller: &str) -> String {
    let reply = match handle(runtime, envelope_json, caller) {
        Ok(reply) => reply,
        Err(refusal) => {
            runtime.lock().metrics.record_refusal(&refusal);
            Reply::Refused(refusal)
        }
    };
    String::from_utf8_lossy(&reply.encode()).to_string()
}

fn handle(runtime: &Arc<Runtime>, envelope_json: &str, caller: &str) -> Result<Reply, Refusal> {
    let envelope = Envelope::decode(envelope_json.as_bytes())?;
    if envelope.from != caller {
        return Err(Refusal::UnknownCaller);
    }
    let now = SystemClock.now_ms();
    {
        let mut state = runtime.lock();
        let Some(mut admission) = state.admission.clone() else {
            return Err(Refusal::Failed("stt_not_configured"));
        };
        // The outer call was signature-checked by `wa_node_call` (`server.lua` `verify_peer`) over
        // the body that carries this envelope, so the inner check is not a second verification of
        // the same bytes: target, caller, timestamp and replay are what must still be checked here,
        // on the envelope's own fields.
        admission.admits(
            &envelope,
            TransportSignature { ts_ms: envelope.ts_ms, body_sha256_hex: "", signature: "" },
            now,
            1024,
            &|_, _, _| true,
        )?;
        state.admission = Some(admission);
    }
    execute(runtime, &envelope, now)
}

fn execute(runtime: &Arc<Runtime>, envelope: &Envelope, now: i64) -> Result<Reply, Refusal> {
    let queue = runtime.queue();
    match envelope.op {
        Op::Take => {
            let body = TakeBody::from_json(&envelope.body)?;
            // One queue on this node; a worker naming another one is asking for something that is
            // not here (`docs/QUEUE.md` item 6: scope by queue, not only by namespace).
            if body.queue != QUEUE {
                return Err(Refusal::NotFound);
            }
            // The long poll is bounded by the relay, not by this node: the worker's own poll
            // interval decides how often it asks (`lua/core/stt.lua`), so this always answers now.
            let _ = body.wait_ms;
            {
                // An admitted `take` is presence whether or not there is work: a worker polling an
                // empty queue is attached, and the local fallback should hold its grace for it.
                let mut state = runtime.lock();
                let first = !state.workers.contains_key(&body.worker);
                let worker = state.workers.entry(body.worker.clone()).or_default();
                worker.last_seen_ms = now;
                worker.takes += 1;
                state.last_remote_call_ms = now;
                state.remote.online = true;
                if first {
                    // One line per worker, not per poll: "a remote worker is now taking from this
                    // queue" is the fact an operator looking at the log wants.
                    eprintln!("[stt] worker attached: {}", body.worker);
                }
            }
            match queue.take(&body.queue, &body.worker, body.lease_ms) {
                Ok(TakeOutcome::Job(job)) => {
                    let request = SttRequest::decode(&job.payload).map_err(|_| Refusal::Malformed("payload"))?;
                    Ok(Reply::Ok(
                        TakeReply::Taken {
                            job: job.id.0,
                            lease_until_ms: job.lease_until.unwrap_or(now),
                            attempts: job.attempts,
                            request,
                        }
                        .to_json(),
                    ))
                }
                Ok(TakeOutcome::AtLimit { leased, .. }) => Ok(Reply::Ok(TakeReply::Busy(leased as u32).to_json())),
                Ok(TakeOutcome::Empty) => Ok(Reply::Ok(TakeReply::Empty.to_json())),
                Err(error) => Err(refusal_of(error)),
            }
        }
        Op::Audio => {
            let body = AudioBody::from_json(&envelope.body)?;
            let (policy, now_ms) = {
                let state = runtime.lock();
                (state.policy.clone(), now)
            };
            let audio = runtime.audio();
            let producer = Producer::new(&queue, &audio, policy, &SystemClock);
            let bytes = producer.serve_audio(body.job, &body.worker, &body.handle, now_ms)?;
            runtime.lock().metrics.bytes_moved += bytes.len() as u64;
            Ok(Reply::Ok(json!({ "b64": request::base64_encode(&bytes) })))
        }
        Op::Heartbeat => {
            let body = SettleBody::from_json(&envelope.body, &["extend_ms"])?;
            let extend = body.payload.get("extend_ms").and_then(Value::as_i64);
            match queue.heartbeat(JobId(body.job), &body.worker, extend) {
                Ok(until) => Ok(Reply::Ok(json!({ "lease_until_ms": until }))),
                Err(error) => Err(refusal_of(error)),
            }
        }
        Op::Progress => {
            let body = SettleBody::from_json(&envelope.body, &["segment"])?;
            let segment = body.payload.get("segment").and_then(Segment::from_json).ok_or(Refusal::Malformed("segment"))?;
            match queue.progress(JobId(body.job), &segment.to_json().to_string().into_bytes()) {
                Ok(seq) => {
                    runtime.lock().metrics.segments += 1;
                    mirror(runtime, &queue, body.job);
                    Ok(Reply::Ok(json!({ "seq": seq })))
                }
                Err(error) => Err(refusal_of(error)),
            }
        }
        Op::Done => {
            let body = SettleBody::from_json(&envelope.body, &["transcript"])?;
            let transcript = body.payload.get("transcript").and_then(Transcript::from_json).ok_or(Refusal::Malformed("transcript"))?;
            let result = transcript.to_json().to_string().into_bytes();
            match queue.done_by(JobId(body.job), &body.worker, &result) {
                Ok(_) => {
                    {
                        let mut state = runtime.lock();
                        state.metrics.record_decode(Who::Remote, transcript.elapsed_ms as i64);
                        let worker = state.workers.entry(body.worker.clone()).or_default();
                        worker.done += 1;
                        worker.last_seen_ms = now;
                        worker.ms_total += transcript.elapsed_ms;
                        state.last_remote_call_ms = now;
                        state.remote.online = true;
                        state.remote.latency.record(now, transcript.elapsed_ms as i64);
                        note_settled(&mut state, body.job, "remote", "done", transcript.elapsed_ms as i64);
                    }
                    discard(runtime, &queue, body.job);
                    mirror(runtime, &queue, body.job);
                    Ok(Reply::Ok(json!({ "settled": true })))
                }
                Err(error) => Err(refusal_of(error)),
            }
        }
        Op::Fail => {
            let body = SettleBody::from_json(&envelope.body, &["reason"])?;
            let reason = body.payload.get("reason").and_then(Value::as_str).unwrap_or("worker_failed");
            match queue.fail_by(JobId(body.job), &body.worker, reason) {
                Ok(outcome) => {
                    {
                        let mut state = runtime.lock();
                        let worker = state.workers.entry(body.worker.clone()).or_default();
                        worker.failed += 1;
                        worker.last_seen_ms = now;
                        state.last_remote_call_ms = now;
                        state.remote.online = true;
                        note_settled(&mut state, body.job, "remote", "failed", 0);
                    }
                    mirror(runtime, &queue, body.job);
                    Ok(Reply::Ok(json!({ "dead": outcome.dead, "attempts": outcome.attempts })))
                }
                Err(error) => Err(refusal_of(error)),
            }
        }
    }
}

/// Delete a settled job's audio. Best effort by design: `purge_audio` on every tick covers a call
/// that never arrived, and the queue record is the truth either way.
fn discard(runtime: &Arc<Runtime>, queue: &Queue, job: u64) {
    let Ok(Some(record)) = queue.job(JobId(job)) else { return };
    let Ok(request) = SttRequest::decode(&record.payload) else { return };
    if let AudioSource::Fetch(handle) = &request.audio {
        if runtime.audio().del(&handle.handle).is_ok() {
            runtime.lock().metrics.bytes_deleted += handle.bytes;
        }
    }
}

fn note_settled(state: &mut State, job: u64, by: &str, outcome: &str, took_ms: i64) {
    state.recent.push_back(Settled { job, by: by.to_string(), outcome: outcome.to_string(), took_ms });
    while state.recent.len() > RECENT_KEPT {
        state.recent.pop_front();
    }
}

fn refusal_of(error: wa_queue::QueueError) -> Refusal {
    match error {
        wa_queue::QueueError::LeaseLost => Refusal::LeaseLost,
        wa_queue::QueueError::NotFound => Refusal::NotFound,
        wa_queue::QueueError::TooLarge(_) | wa_queue::QueueError::ProgressFull => Refusal::TooLarge,
        wa_queue::QueueError::Invalid(_) => Refusal::Malformed("worker_or_lease"),
        _ => Refusal::Failed("queue_store"),
    }
}

// ---- the component's view of a job --------------------------------------------------------------

/// Copy a job's progress entries and terminal state into the waiting component slot. The queue keeps
/// the truth (it is what a remote worker wrote), so a local decode and a remote one update the slot
/// the same way, and a restarted component starts from the same entries.
fn mirror(runtime: &Arc<Runtime>, queue: &Queue, job: u64) {
    let Ok(Some(record)) = queue.job(JobId(job)) else { return };
    let entries = queue.progress_since(JobId(job), 0, 512).unwrap_or_default();
    let mut state = runtime.lock();
    let Some(waiter) = state.waiters.get_mut(&job) else { return };
    {
        let mut slot = waiter.slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if entries.len() > waiter.seen {
            for entry in &entries[waiter.seen..] {
                let parsed = serde_json::from_slice::<Value>(&entry.bytes).ok().and_then(|value| Segment::from_json(&value));
                if let Some(segment) = parsed {
                    if segment.has_text() {
                        slot.push_segment(segment.text, Some(segment.end_ms));
                    }
                }
            }
            waiter.seen = entries.len();
        }
        if record.state.is_terminal() {
            match record.state {
                JobState::Done => {
                    let transcript = record
                        .result
                        .as_deref()
                        .and_then(|bytes| serde_json::from_slice::<Value>(bytes).ok())
                        .and_then(|value| Transcript::from_json(&value));
                    match transcript {
                        Some(transcript) => slot.finish(service_stt::JobState::Done { text: transcript.text, elapsed_ms: transcript.elapsed_ms }),
                        // A result that cannot be read is a failure the caller must see, never a
                        // silent success with the partial segments taken as the transcript.
                        None => slot.finish(service_stt::JobState::Failed("result_unreadable".into())),
                    }
                }
                JobState::Expired => slot.finish(service_stt::JobState::Failed("stale_job".into())),
                _ => slot.finish(service_stt::JobState::Failed(record.last_error.clone().unwrap_or_else(|| "failed".into()))),
            }
        }
    }
    if record.state.is_terminal() {
        state.waiters.remove(&job);
    }
}

// ---- the node's own worker (the fallback) -------------------------------------------------------

/// A `Recognizer` over the node's warm worker (`service_stt`): the hub is a thread and the job is a
/// slot, so this adapter submits and waits, reporting every non-empty segment as it appears. The
/// library's `Decoder` owns the freshness checks, the heartbeat cadence and the settle; this only
/// translates.
struct WarmRecognizer {
    emitted: usize,
    last_end_ms: u64,
}

impl WarmRecognizer {
    fn new() -> WarmRecognizer {
        WarmRecognizer { emitted: 0, last_end_ms: 0 }
    }
}

impl Recognizer for WarmRecognizer {
    fn recognize(
        &mut self,
        audio: &[u8],
        mime: Mime,
        language: &str,
        on_segment: &mut dyn FnMut(Segment),
    ) -> Result<Transcript, RecognizerError> {
        self.emitted = 0;
        self.last_end_ms = 0;
        let slot = service_stt::decode_direct(audio.to_vec(), mime.as_str(), language)
            .map_err(|error| RecognizerError::Environment(format!("stt:{error}")))?;
        loop {
            let (state, segments, duration_ms) = {
                let job = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                (job.state.clone(), job.segments.clone(), job.duration_ms)
            };
            let newest = segments.len();
            for text in &segments[self.emitted.min(newest)..] {
                let end = duration_ms.max(self.last_end_ms);
                on_segment(Segment::new(self.last_end_ms, end, text.clone()));
                self.last_end_ms = end;
            }
            self.emitted = newest;
            match state {
                service_stt::JobState::Queued => std::thread::sleep(Duration::from_millis(50)),
                service_stt::JobState::Done { text, elapsed_ms } => {
                    return Ok(Transcript { text, language: language.to_string(), segments: newest as u32, elapsed_ms });
                }
                service_stt::JobState::Failed(reason) => return Err(classify(&reason)),
            }
        }
    }
}

/// The hub's failure words are the connector's; the queue's retry tiers read three classes
/// (`docs/WHATSAPP-TRANSCRIPTION.md`, "Retries and fallbacks").
fn classify(reason: &str) -> RecognizerError {
    if reason.starts_with("stt_python_missing")
        || reason.starts_with("stt_worker_missing")
        || reason.starts_with("stt_models_missing")
        || reason.starts_with("stt_worker_not_configured")
    {
        RecognizerError::Environment(reason.to_string())
    } else if reason == "audio_too_large" {
        RecognizerError::Permanent(reason.to_string())
    } else {
        RecognizerError::Decode(reason.to_string())
    }
}

/// The producing node's fallback worker, one thread: the library's local poll (which applies the
/// `Preference` grace) over the node's queue, decoding with the node's warm recognizer.
fn local_loop(runtime: Arc<Runtime>) {
    let mut recognizer = WarmRecognizer::new();
    let mut latency = Latency::new();
    let mut metrics = Metrics::new();
    let clock = SystemClock;
    let mut last_outcome = String::new();
    loop {
        let (config, preference, remote) = {
            let mut state = runtime.lock();
            if !state.config.produce {
                drop(state);
                runtime.wait_for_work(IDLE_POLL);
                continue;
            }
            let now = clock.now_ms();
            // Presence, not latency: a worker that has not called for this long is not attached,
            // and waiting for it would be waiting on a missing node.
            state.remote.online = state.last_remote_call_ms > 0 && now.saturating_sub(state.last_remote_call_ms) <= REMOTE_PRESENCE_MS;
            (state.config.clone(), state.preference.clone(), state.remote.clone())
        };
        let queue = runtime.queue();
        let audio = runtime.audio();
        let worker = LocalWorker {
            queue: &queue,
            audio: &audio,
            node: config.me.clone(),
            lease_ms: config.lease_ms,
            heartbeat_every_ms: config.heartbeat_every_ms,
        };
        let outcome = worker.poll_once(&preference, Some(&remote), &mut latency, &mut recognizer, &clock, &mut metrics);
        let purged = Producer::new(&queue, &audio, SttPolicy::default(), &clock).purge_audio(clock.now_ms());
        let decoded = match &outcome {
            Outcome::Decoded { job, took_ms, .. } => Some((*job, *took_ms)),
            _ => None,
        };
        let failed = match &outcome {
            Outcome::Failed { job, reason, .. } => Some((*job, reason.clone())),
            _ => None,
        };
        let stale = match &outcome {
            Outcome::Stale { job } => Some(*job),
            _ => None,
        };
        {
            let mut state = runtime.lock();
            state.local_metrics = metrics.clone();
            state.local_latency = latency.clone();
            if purged > 0 {
                state.metrics.bytes_deleted += purged as u64;
            }
            if let Some((job, took_ms)) = decoded {
                note_settled(&mut state, job, "local", "done", took_ms);
            }
            if let Some((job, reason)) = &failed {
                state.last_error = Some(reason.clone());
                note_settled(&mut state, *job, "local", "failed", 0);
            }
            if let Outcome::Unreachable { reason } = &outcome {
                state.last_error = Some(format!("queue:{reason}"));
            }
        }
        for job in [decoded.map(|(job, _)| job), failed.map(|(job, _)| job), stale].into_iter().flatten() {
            mirror(&runtime, &queue, job);
        }
        if let Some(word) = outcome_word(&outcome) {
            if word != last_outcome {
                eprintln!("[stt] local: {word}");
                last_outcome = word;
            }
        }
        match outcome {
            Outcome::Decoded { .. } | Outcome::Stale { .. } | Outcome::Failed { .. } => {}
            _ => runtime.wait_for_work(IDLE_POLL),
        }
    }
}

// ---- the worker role ----------------------------------------------------------------------------

/// The worker node's transport: it does not sign or POST, it *tunnels* the library's envelope to the
/// node's Lua (`host.stt_pending`/`host.stt_deliver`), where `nodes.lua` signs it with the node key
/// and calls the producer. Blocking is fine: this runs on the worker thread, and the Lua pump is the
/// only part that touches the interpreter.
struct TunnelTransport {
    runtime: Arc<Runtime>,
    from: String,
    to: String,
    /// The last wire failure this transport logged, so a relay that is down is one line, not one per
    /// poll (the reason is a fixed word: a refusal or a transport fact, never a payload).
    last_failure: String,
}

impl TunnelTransport {
    fn call(&mut self, op: Op, body: Value) -> Result<Value, WireError> {
        let now = SystemClock.now_ms();
        let rid = format!("{}-{}-{}", std::process::id(), now, next_id());
        let envelope = Envelope::new(op, self.from.clone(), self.to.clone(), now, rid, body);
        let text = String::from_utf8_lossy(&envelope.encode()).to_string();
        let (tx, rx) = mpsc::channel();
        let id = {
            let mut tunnel = self.runtime.tunnel.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            tunnel.issued += 1;
            let id = tunnel.issued;
            tunnel.waiting.insert(id, tx);
            tunnel.pending.push_back((id, text));
            id
        };
        match rx.recv_timeout(TUNNEL_TIMEOUT) {
            Ok(reply) => {
                let parsed = parse_reply(&reply);
                if let Err(error) = &parsed {
                    let word = format!("{}:{}", op.as_str(), error.reason());
                    if word != self.last_failure {
                        eprintln!("[stt] wire failed: {word}");
                        self.last_failure = word;
                    }
                }
                parsed
            }
            Err(_) => {
                let word = format!("{}:pump_timeout", op.as_str());
                if word != self.last_failure {
                    eprintln!("[stt] wire failed: {word}");
                    self.last_failure = word;
                }
                let mut tunnel = self.runtime.tunnel.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                tunnel.waiting.remove(&id);
                Err(WireError::Unreachable("stt_pump_timeout".into()))
            }
        }
    }
}

fn parse_reply(text: &str) -> Result<Value, WireError> {
    let value: Value = serde_json::from_str(text).map_err(|_| WireError::Unreachable("stt_reply_unreadable".into()))?;
    if let Some(error) = value.get("error").and_then(Value::as_str) {
        // The node layer's own refusal (a signature, a role, a route): keep its allow-listed code
        // beside the reason, never the body - the answer may be unsigned at this point.
        let reason = value.get("reason").and_then(Value::as_str).filter(|reason| !reason.is_empty());
        return Err(WireError::Unreachable(match reason {
            Some(reason) => format!("{error}:{reason}"),
            None => error.to_string(),
        }));
    }
    match Reply::decode(text.as_bytes()) {
        Ok(Reply::Ok(value)) => Ok(value),
        Ok(Reply::Refused(refusal)) => Err(WireError::Refused(refusal)),
        Err(_) => Err(WireError::Unreachable("stt_reply_unreadable".into())),
    }
}

impl Transport for TunnelTransport {
    fn take(&mut self, body: &TakeBody) -> Result<TakeReply, WireError> {
        let value = self.call(Op::Take, body.to_json())?;
        TakeReply::from_json(&value).map_err(WireError::Refused)
    }

    fn fetch_audio(&mut self, job: u64, worker: &str, handle: &str) -> Result<Vec<u8>, WireError> {
        let value = self.call(Op::Audio, json!({ "job": job, "worker": worker, "handle": handle }))?;
        let encoded = value.get("b64").and_then(Value::as_str).ok_or(WireError::Refused(Refusal::Malformed("audio")))?;
        request::base64_decode(encoded).ok_or(WireError::Refused(Refusal::Malformed("audio")))
    }

    fn heartbeat(&mut self, job: u64, worker: &str, extend_ms: i64) -> Result<i64, WireError> {
        let value = self.call(Op::Heartbeat, json!({ "job": job, "worker": worker, "extend_ms": extend_ms }))?;
        value.get("lease_until_ms").and_then(Value::as_i64).ok_or(WireError::Refused(Refusal::Malformed("beat_reply")))
    }

    fn progress(&mut self, job: u64, worker: &str, segment: &Segment) -> Result<(), WireError> {
        self.call(Op::Progress, json!({ "job": job, "worker": worker, "segment": segment.to_json() })).map(|_| ())
    }

    fn done(&mut self, job: u64, worker: &str, transcript: &Transcript) -> Result<(), WireError> {
        self.call(Op::Done, json!({ "job": job, "worker": worker, "transcript": transcript.to_json() })).map(|_| ())
    }

    fn fail(&mut self, job: u64, worker: &str, reason: &str) -> Result<(), WireError> {
        self.call(Op::Fail, json!({ "job": job, "worker": worker, "reason": wa_stt_remote::protocol::sanitize(reason) })).map(|_| ())
    }

    fn discard_audio(&mut self, job: u64, worker: &str, handle: &str) {
        // The producing node deletes the blob when it settles the job, and its own tick covers a
        // call lost here. Nothing to send from this side.
        let _ = (job, worker, handle);
    }
}

/// The worker node's thread: the library's `RemoteWorker::poll_once` until the node stops. `Empty`
/// is the normal answer between notes, so it waits a short interval instead of spinning.
fn remote_loop(runtime: Arc<Runtime>) {
    let mut recognizer = WarmRecognizer::new();
    let mut metrics = Metrics::new();
    let clock = SystemClock;
    let mut idle_reason = String::new();
    let mut last_outcome = String::new();
    loop {
        let (config, provisioned) = {
            let state = runtime.lock();
            (state.config.clone(), service_stt::provisioned())
        };
        if !config.work || config.producer_id.is_empty() || !provisioned {
            // Say once why the worker is not polling: a role with no producer, or no recognizer, is
            // an idle node - not a node that is decoding and hiding it.
            let reason = format!("work={} producer={} recognizer={}", config.work, if config.producer_id.is_empty() { "-" } else { &config.producer_id }, provisioned);
            if reason != idle_reason {
                eprintln!("[stt] worker idle: {reason}");
                idle_reason = reason;
            }
            std::thread::sleep(IDLE_POLL);
            continue;
        }
        idle_reason.clear();
        let worker = RemoteWorker {
            queue: QUEUE.to_string(),
            worker: format!("stt:{}", config.me),
            lease_ms: config.lease_ms,
            wait_ms: config.wait_ms,
            heartbeat_every_ms: config.heartbeat_every_ms,
        };
        let mut transport = TunnelTransport { runtime: runtime.clone(), from: config.me.clone(), to: config.producer_id.clone(), last_failure: String::new() };
        let outcome = worker.poll_once(&mut transport, &mut recognizer, &clock, &mut metrics);
        {
            let mut state = runtime.lock();
            state.worker_metrics = metrics.clone();
            if let Outcome::Unreachable { reason } = &outcome {
                state.last_error = Some(format!("relay:{reason}"));
            }
            if let Some(trace) = outcome.trace(Who::Remote) {
                note_settled(&mut state, trace.job, "worker", trace.outcome, trace.took_ms);
            }
        }
        match outcome {
            Outcome::Empty | Outcome::Busy(_) | Outcome::Deferred { .. } => std::thread::sleep(IDLE_POLL),
            other => {
                let word = format!("{other:?}");
                if word != last_outcome {
                    eprintln!("[stt] worker: {word}");
                    last_outcome = word;
                }
            }
        }
    }
}

// ---- the pump the node's Lua drains -------------------------------------------------------------

/// `host.stt_pending`: the next call the worker thread wants signed and sent, as
/// `{"id": n, "envelope": "<json>"}`, or `null` when there is nothing to do.
pub fn pending() -> Value {
    let mut tunnel = node().tunnel.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    match tunnel.pending.pop_front() {
        Some((id, envelope)) => json!({"id": id, "envelope": envelope}),
        None => Value::Null,
    }
}

/// `host.stt_deliver`: hand the node's answer back to the waiting worker thread and return the next
/// pending call, so the Lua pump drains a whole settle sequence in one tick.
pub fn deliver(id: u64, reply: &str) -> Value {
    let runtime = node();
    let next = {
        let mut tunnel = runtime.tunnel.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(sender) = tunnel.waiting.remove(&id) {
            let _ = sender.send(reply.to_string());
        }
        tunnel.pending.pop_front()
    };
    match next {
        Some((id, envelope)) => json!({"id": id, "envelope": envelope}),
        None => Value::Null,
    }
}

// ---- the operator view -------------------------------------------------------------------------

/// `host.stt_admin`: `configure`, `status`, `job`, `sweep` and `submit`. The answers carry ids,
/// states, counters and durations; never a transcript, an audio byte or a reason that could hold
/// text (the queue sanitizes its own and this only forwards a bounded word).
pub fn admin(request: &Value) -> Value {
    admin_on(node(), request)
}

pub fn admin_on(runtime: &Arc<Runtime>, request: &Value) -> Value {
    let action = request.get("action").and_then(Value::as_str).unwrap_or("status");
    match action {
        "configure" => configure_on(runtime, request),
        "submit" => submit_on(runtime, request),
        "sweep" => {
            let queue = runtime.queue();
            let now = SystemClock.now_ms();
            let expired = queue.expire_stale_at(now).map(|outcome| outcome.expired.len()).unwrap_or(0);
            let recovered = queue.sweep().map(|outcome| outcome.leases_recovered).unwrap_or(0);
            let purged = Producer::new(&queue, &runtime.audio(), SttPolicy::default(), &SystemClock).purge_audio(now);
            json!({"ok": {"expired": expired, "leases_recovered": recovered, "audio_purged": purged}})
        }
        "job" => job_view_on(runtime, request),
        // The node's own tick reads these every second: they are what tells it a peer was refused
        // because `Admission` had not learned it yet (`lua/core/stt.lua`), without scanning the queue.
        "counters" => {
            let state = runtime.lock();
            json!({"ok": {
                "refused_unknown": state.metrics.refused_unknown_caller,
                "refused_replayed": state.metrics.refused_replayed,
                "refused_stale": state.metrics.refused_stale_call,
                "refused_signature": state.metrics.refused_bad_signature,
                "enqueued": state.metrics.enqueued + state.local_metrics.enqueued,
            }})
        }
        _ => status_on(runtime),
    }
}

fn job_view_on(runtime: &Arc<Runtime>, request: &Value) -> Value {
    let Some(job) = request.get("job").and_then(Value::as_u64) else {
        return json!({"refused": "malformed:job"});
    };
    let queue = runtime.queue();
    match queue.job(JobId(job)) {
        Ok(Some(record)) => {
            let request = SttRequest::decode(&record.payload).ok();
            let entries = queue.progress_since(JobId(job), 0, 512).unwrap_or_default();
            let mut last_end = 0;
            for entry in &entries {
                if let Ok(value) = serde_json::from_slice::<Value>(&entry.bytes) {
                    if let Some(segment) = Segment::from_json(&value) {
                        last_end = last_end.max(segment.end_ms);
                    }
                }
            }
            let result = record
                .result
                .as_deref()
                .and_then(|bytes| serde_json::from_slice::<Value>(bytes).ok())
                .and_then(|value| Transcript::from_json(&value));
            json!({"ok": {
                "job": job,
                "state": record.state.as_str(),
                "attempts": record.attempts,
                "lease_expiries": record.lease_expiries,
                "queue": record.queue,
                "fresh_until_ms": record.fresh_until,
                "lease_worker": record.lease_worker,
                "segments_seen": entries.len(),
                "audio_ms": last_end,
                "audio_bytes": request.as_ref().map(|request| request.audio.bytes()),
                "audio": request.as_ref().map(|request| if request.audio.is_inline() { "inline" } else { "fetch" }),
                "chars": result.as_ref().map(|transcript| transcript.text.chars().count()),
                "elapsed_ms": result.as_ref().map(|transcript| transcript.elapsed_ms),
                "last_error": record.last_error.as_deref().map(wa_stt_remote::protocol::sanitize),
            }})
        }
        Ok(None) => json!({"refused": "not_found"}),
        Err(error) => json!({"error": format!("queue:{error}")}),
    }
}

fn status_on(runtime: &Arc<Runtime>) -> Value {
    let clock = SystemClock;
    let now = clock.now_ms();
    let queue = runtime.queue();
    let stats = queue.stats(QUEUE).ok();
    let state = runtime.lock();
    let config = state.config.clone();
    let workers: Vec<Value> = state
        .workers
        .iter()
        .map(|(worker, stat)| {
            json!({
                "worker": worker,
                "last_seen_ms": stat.last_seen_ms,
                "ago_ms": now.saturating_sub(stat.last_seen_ms),
                "takes": stat.takes,
                "done": stat.done,
                "failed": stat.failed,
                "avg_ms": stat.average_ms(),
            })
        })
        .collect();
    let jobs: Vec<Value> = queue
        .list(QUEUE, None, 8)
        .unwrap_or_default()
        .iter()
        .map(|job| {
            json!({
                "job": job.id.0, "state": job.state.as_str(), "attempts": job.attempts,
                "lease_worker": job.lease_worker, "progress_entries": job.progress_entries,
            })
        })
        .collect();
    json!({"ok": {
        "enabled": config.produce || config.work,
        "producer": config.produce,
        "worker": config.work,
        "producer_id": config.producer_id,
        "producer_name": config.producer_name,
        "me": config.me,
        "owners": config.owner_nodes.len(),
        "queue": stats.map(|stats| json!({
            "ready": stats.ready,
            "retrying": stats.retrying,
            "leased": stats.leased,
            "done": stats.done,
            "dead": stats.dead,
            "expired": stats.expired,
            "oldest_ready_age_ms": stats.oldest_ready_age_ms,
        })),
        "remote": {
            "online": state.remote.online,
            "decoded": state.metrics.remote_decoded,
            "avg_ms": state.metrics.average_ms(Who::Remote),
            "last_ms": state.remote.latency.last_ms(),
            "estimate_ms": state.remote.latency.recent(now, state.preference.sample_ttl_ms, state.preference.min_samples),
        },
        "worker_decodes": {
            // This node decoded for another node's queue (the `stt_worker` role).
            "decoded": state.worker_metrics.remote_decoded,
            "avg_ms": state.worker_metrics.average_ms(Who::Remote),
        },
        "local": {
            "decoded": state.local_metrics.local_decoded + state.metrics.local_decoded,
            "avg_ms": state.local_metrics.average_ms(Who::Local).or_else(|| state.metrics.average_ms(Who::Local)),
            "estimate_ms": state.local_latency.recent(now, state.preference.sample_ttl_ms, state.preference.min_samples),
        },
        "counters": {
            "enqueued": state.metrics.enqueued + state.local_metrics.enqueued,
            "stale": state.metrics.stale_dropped + state.local_metrics.stale_dropped,
            "waited": state.local_metrics.waited_for_remote,
            "fallback": state.local_metrics.fallback_taken,
            "immediate": state.local_metrics.local_immediate,
            "lost_mid_job": state.local_metrics.remote_lost_mid_job + state.metrics.remote_lost_mid_job,
            "segments": state.metrics.segments,
            "bytes_moved": state.metrics.bytes_moved,
            "bytes_deleted": state.metrics.bytes_deleted,
        },
        "workers": workers,
        "recent": state.recent.iter().map(|settled| json!({
            "job": settled.job, "by": settled.by, "outcome": settled.outcome, "took_ms": settled.took_ms,
        })).collect::<Vec<_>>(),
        "jobs": jobs,
        "last_error": state.last_error,
    }})
}

/// The one log line worth writing: the library's counters, ids and durations only.
pub fn metrics_line() -> String {
    let state = node().lock();
    format!("{} local[{}]", state.metrics.line(), state.local_metrics.line())
}

/// The periodic upkeep the node's housekeeping loop asks for (`lua/core/stt.lua#tick`): the queue's
/// own stale sweep (the safety net is `take`, so this only makes an expiry *visible* sooner) and the
/// audio purge. Idempotent, counts only.
pub fn tick() -> Value {
    tick_on(node())
}

pub fn tick_on(runtime: &Arc<Runtime>) -> Value {
    let due = {
        let mut state = runtime.lock();
        if !state.config.produce && !state.config.work {
            return Value::Null;
        }
        let due = state.last_sweep.is_none_or(|at| at.elapsed() >= Duration::from_secs(15));
        if due {
            state.last_sweep = Some(std::time::Instant::now());
        }
        due
    };
    if !due {
        return Value::Null;
    }
    let queue = runtime.queue();
    let now = SystemClock.now_ms();
    let expired = queue.expire_stale_at(now).map(|outcome| outcome.expired.len()).unwrap_or(0);
    let purged = Producer::new(&queue, &runtime.audio(), SttPolicy::default(), &SystemClock).purge_audio(now);
    if expired > 0 || purged > 0 {
        json!({"ok": {"expired": expired, "audio_purged": purged}})
    } else {
        Value::Null
    }
}

/// Test-only: install a config without starting the node threads (which decode through the real
/// recognizer). The threads are exercised end to end by `scripts/test-stt-two-nodes.sh`; the state
/// machine below is what a unit test can drive deterministically.
#[cfg(test)]
pub(crate) fn set_config_for_test(runtime: &Arc<Runtime>, config: Config) {
    let mut state = runtime.lock();
    state.admission = Some(Admission::new(config.me.clone(), config.owner_nodes.clone()));
    state.policy = SttPolicy { fresh_ms: config.fresh_ms, ..SttPolicy::default() };
    state.preference = Preference::from_settings(Some(config.fallback_after_ms), Some(config.sample_ttl_ms));
    state.config = config;
}

/// The outcome word and its numbers, for the node's own log: ids, counts and durations only.
fn outcome_word(outcome: &Outcome) -> Option<String> {
    Some(match outcome {
        Outcome::Deferred { .. } => "deferred (a preferred remote has the first claim)".into(),
        Outcome::Decoded { job, by, took_ms, segments, .. } => format!("done job={job} by={} took_ms={took_ms} segments={segments}", by.as_str()),
        Outcome::Empty => return None,
        Outcome::Busy(leased) => format!("busy leased={leased}"),
        Outcome::Stale { job } => format!("stale job={job}"),
        Outcome::Lost { job } => format!("lease_lost job={job}"),
        Outcome::Failed { job, retryable, .. } => format!("failed job={job} retryable={retryable}"),
        Outcome::Refused { reason } => format!("refused {reason}"),
        Outcome::Unreachable { reason } => format!("unreachable {reason}"),
    })
}

thread_local! {
    /// A per-thread monotonic counter for envelope `rid`s and audio handles. Unique per call, never
    /// reused, and not a random id: nothing here needs to be unguessable (the signature is what
    /// authenticates a call), so a counter keeps the wire readable in a test.
    static NEXT: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

fn next_id() -> u64 {
    NEXT.with(|next| {
        next.set(next.get().wrapping_add(1));
        next.get()
    })
}

#[cfg(test)]
mod tests;
