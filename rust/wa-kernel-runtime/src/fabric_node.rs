//! The node half of the compute fabric: presence, the offer pump, and the lease.
//!
//! `rust/wa-fabric` is the rules (what a heartbeat is, how a candidate is scored, how long an offer
//! waits, what the lease means). This module is the node: it owns the live view, publishes this
//! node's heartbeat, places work through a [`Router`], and tunnels each wire call out to the node's
//! Lua (`host.fabric_pending` / `host.fabric_deliver`) where `lua/core/nodes.lua` signs it — the same
//! shape as the speech queue's pump (`stt_node.rs`), and for the same reason: the node's private key
//! lives in the interpreter's `host.sign` and nowhere else.
//!
//! Four things it deliberately does not do:
//!
//! * **It never blocks.** `submit` places a job synchronously when the answer is already in the view
//!   (self is cheapest, or no peer is live); when an offer has to go out, the call is queued for the
//!   pump and the job's window is resolved by `tick`. The node's loop never waits on a peer.
//! * **It never invents a lease.** The queue is `wa-queue` over an injected kv, so "first lease wins",
//!   heartbeat extension, expiry → requeue and the fenced settle are the queue's own rules; this module
//!   only names them (`take`, `beat`, `settle`, `fail`).
//! * **It never carries a payload in the fabric records.** An offer names a job id; the bytes stay in
//!   the queue. A heartbeat carries load and capabilities only.
//! * **It never trusts a sample as a reservation.** An arriving offer is answered from the load *now*
//!   ([`wa_fabric::offer::answer`]), so a peer whose heartbeat is a second old cannot make this node
//!   accept work it cannot take.
//!
//! Wiring status (2026-11-08): the module, the admin answer (`services {"action":"fabric"}`) and the
//! five capabilities (`host.fabric_*`) exist and are unit-tested here. The Lua glue (`server.lua`
//! `node_capability`, a `fabric.lua` tick calling `tick`/`pending`/`deliver`) and passing the node's
//! durable kv in as the queue are the remaining steps, listed in `REPORT.md`; until the kv is passed
//! in, the queue is in-process, which is correct for the lease's *rules* but not yet durable across a
//! restart.

use std::collections::BTreeMap;
use std::cell::RefCell;
use std::sync::Arc;

use serde_json::{json, Value};
use wa_fabric::lease::{queue_name, FabricLease, Outstanding};
use wa_fabric::metrics::FabricMetrics;
use wa_fabric::offer::{self, Accept, Offer, Reply, Router, Step};
use wa_fabric::placement::{self, Decision, LocalReason, Request};
use wa_fabric::presence::{Capabilities, Heartbeat, Load, NodeId, PresenceView};
use wa_fabric::admin::FabricView;
use wa_fabric::Config;
use wa_queue::{Clock, JobId, Kv, MemoryKv, Policy, Queue, SystemClock};

/// How many wire calls may wait for the pump. A bound, so a node whose Lua side stopped pumping
/// cannot grow the outbox without limit; the oldest call is dropped and counted.
pub const MAX_OUTBOX: usize = 64;

/// One call the node must sign and send: a heartbeat to one peer, or an offer to one peer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Call {
    pub id: u64,
    /// `beat` or `offer`: the action word the node signs.
    pub op: &'static str,
    pub to: String,
    /// The record, already encoded: the pump signs exactly these bytes.
    pub body: String,
}

impl Call {
    pub fn to_json(&self) -> Value {
        json!({"id": self.id, "op": self.op, "to": self.to, "body": self.body})
    }
}

/// What `tick` did: how many heartbeats it queued, and the jobs whose offer window elapsed (they run
/// here now).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Tick {
    pub beats: usize,
    pub dropped: usize,
    /// `(job, reason)`: the local fallbacks this tick decided.
    pub local: Vec<(u64, LocalReason)>,
}

/// Where one submission went.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Submission {
    pub job: JobId,
    /// The plan: an offer (the call is queued for the pump) or the local path.
    pub plan: wa_fabric::Plan,
    /// True when the caller should take the lease and run the job here, now.
    pub local: bool,
}

/// What an answered offer decided.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Resolution {
    /// The peer accepted: it will take the lease.
    Placed { node: String, rtt_ms: i64 },
    /// The next candidate was offered instead.
    Reoffered { to: String },
    /// Nobody took it inside the window: run it here.
    Local { because: LocalReason },
    /// The answer did not match the offer in flight (a duplicate, a replay, a previous attempt).
    Ignored,
}

/// The node's fabric: one view, one router, one set of fabric queues, one set of counters.
pub struct FabricNode {
    self_id: NodeId,
    config: Config,
    caps: Capabilities,
    /// CPU and memory pressure; the queue depth is read from the queues at beat time.
    load: Load,
    version: String,
    generation: u64,
    view: PresenceView,
    router: Router,
    metrics: FabricMetrics,
    queue: Queue,
    outbox: Vec<Call>,
    /// The job each queued offer call belongs to, so an answer is applied to the offer it answers and
    /// not to whichever offer happens to be in flight.
    in_flight: BTreeMap<u64, u64>,
    /// The leases this node holds, so `settle`/`fail` name the one that was taken.
    leases: BTreeMap<u64, FabricLease>,
    seq: u64,
    last_beat_ms: i64,
}

impl FabricNode {
    /// `self_id` must be a valid node id; `kv` and `clock` are the node's (the host passes its own
    /// durable kv and its clock; a test passes `MemoryKv` and a `FixedClock`).
    pub fn new(self_id: &str, config: Config, kv: Arc<dyn Kv>, clock: Arc<dyn Clock>) -> Option<FabricNode> {
        let id = NodeId::new(self_id)?;
        let policy = Policy::default().with_fresh_ms(600_000);
        Some(FabricNode {
            view: PresenceView::new(&config),
            router: Router::new(id.clone(), &config),
            metrics: FabricMetrics::new(),
            queue: Queue::new(kv, clock, policy),
            self_id: id,
            config,
            caps: Capabilities::default(),
            // A node that has not measured its own load yet must not look idle: half is a neutral
            // guess, and the first real sample replaces it.
            load: Load::new(0, 50, 50),
            version: env!("CARGO_PKG_VERSION").to_string(),
            generation: 1,
            outbox: Vec::new(),
            in_flight: BTreeMap::new(),
            leases: BTreeMap::new(),
            seq: 0,
            last_beat_ms: i64::MIN / 2,
        })
    }

    /// A node with an in-process queue: what the host uses until it passes its durable kv in.
    pub fn in_process(self_id: &str, config: Config) -> Option<FabricNode> {
        FabricNode::new(self_id, config, Arc::new(MemoryKv::new()), Arc::new(SystemClock))
    }

    pub fn self_id(&self) -> &str {
        self.self_id.as_str()
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn view(&self) -> &PresenceView {
        &self.view
    }

    pub fn metrics(&self) -> &FabricMetrics {
        &self.metrics
    }

    pub fn queue(&self) -> &Queue {
        &self.queue
    }

    /// What this node serves. Replacing the set is a hot change: the next heartbeat carries it.
    pub fn set_caps<I, S>(&mut self, caps: I)
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        self.caps = Capabilities::of(caps);
    }

    /// CPU and memory pressure as the node measured them. Percentages, clamped.
    pub fn set_load(&mut self, cpu_busy_pct: u8, mem_used_pct: u8) {
        self.load = Load::new(0, cpu_busy_pct, mem_used_pct);
    }

    /// This node's heartbeat right now: real queue depth, its own clock.
    pub fn heartbeat(&self, now_ms: i64) -> Heartbeat {
        let depth = self
            .queue
            .queues()
            .map(|names| {
                names
                    .iter()
                    .filter(|name| name.starts_with(wa_fabric::lease::QUEUE_PREFIX))
                    .filter_map(|name| self.queue.stats(name).ok())
                    .map(|stats| stats.active())
                    .sum::<usize>()
            })
            .unwrap_or(0) as u32;
        let caps: Vec<String> = self.caps.iter().map(|capability| capability.as_str().to_string()).collect();
        Heartbeat::new(
            self.self_id.as_str(),
            caps,
            Load::new(depth, self.load.cpu_busy_pct, self.load.mem_used_pct),
            self.version.clone(),
            now_ms,
        )
    }

    /// Publish this node's heartbeat: to its own view (self is a candidate only when it knows its own
    /// load) and, as one queued call per live peer, to the pump. Returns how many calls it queued.
    pub fn publish(&mut self, now_ms: i64) -> usize {
        let beat = self.heartbeat(now_ms);
        self.view.observe(beat.clone(), now_ms);
        self.last_beat_ms = now_ms;
        let peers: Vec<String> = self
            .view
            .live(now_ms)
            .into_iter()
            .map(|sample| sample.beat.node.as_str().to_string())
            .filter(|node| node != self.self_id.as_str())
            .collect();
        let queued = peers.len();
        for to in peers {
            self.enqueue("beat", &to, beat.encode());
        }
        queued
    }

    /// A peer's heartbeat arrived (through the pump's answer, or a call the peer made).
    pub fn observe(&mut self, beat: Heartbeat, now_ms: i64) -> wa_fabric::presence::Observe {
        if beat.node.as_str() == self.self_id.as_str() {
            return wa_fabric::presence::Observe::default();
        }
        self.view.observe(beat, now_ms)
    }

    /// Housekeeping: publish when due, forget what nobody has heard from, and resolve every offer
    /// whose window elapsed (those jobs run here now).
    pub fn tick(&mut self, now_ms: i64) -> Tick {
        let mut tick = Tick::default();
        if now_ms.saturating_sub(self.last_beat_ms) >= self.config.heartbeat_ms {
            tick.beats = self.publish(now_ms);
        }
        self.view.prune(now_ms);
        for (job, step) in self.router.tick(now_ms) {
            if let Step::Local { because } = step {
                if because == LocalReason::OfferWindowElapsed {
                    self.metrics.timed_out(job);
                }
                self.metrics.local_fallback(job, because);
                tick.local.push((job, because));
            }
        }
        tick
    }

    /// Enqueue one job on this node's fabric queue and place it.
    pub fn submit(&mut self, kind: &str, payload: Vec<u8>, now_ms: i64) -> Result<Submission, String> {
        let queue = queue_name(kind);
        let enqueued = self
            .queue
            .enqueue(wa_queue::EnqueueRequest::new(queue, payload.clone()))
            .map_err(|error| error.to_string())?;
        let request = Request::new(kind, enqueued.id.0, payload.len() as u64).affinity(self.self_id.as_str().to_string());
        let decision = placement::choose(&self.view, &request, self.self_id.as_str(), now_ms, &self.config, &self.metrics);
        self.metrics.decided(now_ms, &request, &decision);
        let step = self.router.place(decision.clone(), &request, now_ms);
        match step {
            Step::Offer(offer) => {
                self.metrics.offer_sent(&offer);
                let call = self.enqueue("offer", offer.to.as_str(), offer.encode());
                self.in_flight.insert(call, enqueued.id.0);
                Ok(Submission { job: enqueued.id, plan: decision.plan, local: false })
            }
            Step::Local { because } => {
                if decision.plan.is_local() {
                    self.metrics.local_fallback(enqueued.id.0, because);
                }
                Ok(Submission { job: enqueued.id, plan: decision.plan, local: true })
            }
            // A placement that is already answered inside `place` cannot happen: `place` only sends.
            Step::Placed { node, rtt_ms } => {
                self.metrics.accepted(now_ms, enqueued.id.0, node.as_str(), rtt_ms);
                Ok(Submission { job: enqueued.id, plan: decision.plan, local: false })
            }
        }
    }

    /// The answer to an offer this node sent: the peer's accept/refuse, or "unreachable".
    pub fn on_reply(&mut self, job: u64, reply: Reply, now_ms: i64) -> Resolution {
        let unreachable = matches!(reply, Reply::Unreachable(_));
        let refused = match &reply {
            Reply::Refuse(refuse) => Some(refuse.reason.clone()),
            Reply::Unreachable(reason) => Some(reason.clone()),
            Reply::Accept(_) => None,
        };
        let Some(step) = self.router.on_reply(job, reply, now_ms) else {
            return Resolution::Ignored;
        };
        // The peer's "no" is counted whoever ends up running the job.
        if let Some(reason) = refused {
            if unreachable {
                self.metrics.unreachable(job, &reason);
            } else {
                self.metrics.refused(job, &reason);
            }
        }
        match step {
            Step::Placed { node, rtt_ms } => {
                self.metrics.accepted(now_ms, job, node.as_str(), rtt_ms);
                Resolution::Placed { node: node.as_str().to_string(), rtt_ms }
            }
            Step::Offer(offer) => {
                self.metrics.offer_sent(&offer);
                let to = offer.to.as_str().to_string();
                let call = self.enqueue("offer", &to, offer.encode());
                self.in_flight.insert(call, job);
                Resolution::Reoffered { to }
            }
            Step::Local { because } => {
                self.metrics.local_fallback(job, because);
                Resolution::Local { because }
            }
        }
    }

    /// An offer arrived from a peer: answer it from the load **now**, never from the beat it scored.
    pub fn answer(&mut self, offer: &Offer, now_ms: i64) -> Value {
        let beat = self.heartbeat(now_ms);
        match offer::answer(offer, &beat.caps, &beat.load, self.self_id.as_str(), now_ms, &self.config) {
            Ok(accept) => accept.to_json(),
            Err(refuse) => refuse.to_json(),
        }
    }

    /// Take the lease for one job of `kind` (the local path, or a peer's accepted offer arriving over
    /// the wire). `None` means nothing is due.
    pub fn take(&mut self, kind: &str, lease_ms: i64, now_ms: i64) -> Result<Option<FabricLease>, String> {
        let queue = queue_name(kind);
        let lease = FabricLease::take(&self.queue, &queue, &self.self_id, self.generation, lease_ms, now_ms)
            .map_err(|error| error.as_str().to_string())?;
        if let Some(lease) = &lease {
            self.leases.insert(lease.job.0, lease.clone());
        }
        Ok(lease)
    }

    /// The lease this node holds for `job`, if it still holds it.
    pub fn lease(&self, job: u64) -> Option<&FabricLease> {
        self.leases.get(&job)
    }

    /// Extend a lease; `Lost` means the job is not ours any more.
    pub fn beat(&mut self, lease: &mut FabricLease) -> Result<i64, String> {
        lease.heartbeat(&self.queue).map_err(|error| error.as_str().to_string())
    }

    /// Settle a lease with its result. Fenced by the queue: a second settle is refused.
    pub fn settle(&mut self, lease: &FabricLease, result: &[u8]) -> Result<(), String> {
        match lease.done(&self.queue, result) {
            Ok(()) => {
                self.metrics.settled();
                Ok(())
            }
            Err(error) => {
                self.metrics.settle_lost();
                Err(error.as_str().to_string())
            }
        }
    }

    /// Give a job up: the queue decides between a backoff retry and the dead letter.
    pub fn fail(&mut self, lease: &FabricLease, reason: &str) -> Result<String, String> {
        lease.fail(&self.queue, reason).map(|outcome| outcome.state.as_str().to_string()).map_err(|error| error.as_str().to_string())
    }

    /// The next call the pump must sign and send, or `None`.
    pub fn next_call(&mut self) -> Option<Call> {
        if self.outbox.is_empty() {
            None
        } else {
            Some(self.outbox.remove(0))
        }
    }

    /// How many calls are waiting for the pump.
    pub fn queued(&self) -> usize {
        self.outbox.len()
    }

    /// The admin view (`services {"action":"fabric"}`).
    pub fn admin(&self, kind: &str, now_ms: i64) -> Value {
        let leases = Outstanding::read(&self.queue, &queue_name(kind), now_ms, 32);
        wa_fabric::view(&FabricView {
            self_id: self.self_id.as_str(),
            config: &self.config,
            presence: &self.view,
            metrics: &self.metrics,
            now_ms,
            leases: &[leases],
            in_flight_offers: self.router.in_flight(),
            recent: 16,
        })
    }

    /// The ranked candidates for one request, without placing it (an operator's "what if").
    pub fn rank(&self, request: &Request, now_ms: i64) -> Decision {
        placement::choose(&self.view, request, self.self_id.as_str(), now_ms, &self.config, &self.metrics)
    }

    /// The peers this node would ask right now, for the log line an operator reads first.
    pub fn live_peers(&self, now_ms: i64) -> Vec<String> {
        self.view
            .live(now_ms)
            .into_iter()
            .map(|sample| sample.beat.node.as_str().to_string())
            .filter(|node| node != self.self_id.as_str())
            .collect()
    }

    fn enqueue(&mut self, op: &'static str, to: &str, body: Vec<u8>) -> u64 {
        self.seq = self.seq.wrapping_add(1);
        let id = self.seq;
        let body = String::from_utf8_lossy(&body).to_string();
        if self.outbox.len() >= MAX_OUTBOX {
            // A node whose Lua side stopped pumping must not grow this without bound. The oldest call
            // is dropped, which costs one placement its offer (it falls back on the window instead).
            self.outbox.remove(0);
            self.metrics.unreachable(id, "outbox_full");
        }
        self.outbox.push(Call { id, op, to: to.to_string(), body });
        id
    }
}

// ---------------------------------------------------------------------------------------------------
// The process-wide node, reached from Lua. One node per process, like `stt_node`.
// ---------------------------------------------------------------------------------------------------

// One fabric per node-thread, not one per process: `wa-queue`'s `Kv` and `Clock` are deliberately not
// `Send` (the queue assumes one writer per namespace, which is one interpreter), and Lua calls arrive on
// that interpreter's own thread. A second node-thread therefore gets its own fabric, which is what the
// kernel's per-thread model already means (`docs/FABRIC.md`, "More than one node-thread").
thread_local! {
    static NODE: RefCell<Option<FabricNode>> = const { RefCell::new(None) };
}

/// `host.fabric_admin` action `configure`: build the node's fabric from the request
/// (`{self, caps, enabled, heartbeat_ms, offer_window_ms}`) and start publishing on the next tick.
pub fn configure(request: &Value) -> Value {
    let self_id = request.get("self").and_then(Value::as_str).unwrap_or_default();
    if self_id.is_empty() {
        return json!({"ok": false, "error": "fabric_self_required"});
    }
    let config = Config::from_settings(
        request.get("enabled").and_then(Value::as_str),
        request.get("heartbeat_ms").and_then(Value::as_i64),
        request.get("offer_window_ms").and_then(Value::as_i64),
        request.get("transfer_bytes_per_ms").and_then(Value::as_u64),
    );
    let Some(mut node) = FabricNode::in_process(self_id, config) else {
        return json!({"ok": false, "error": "fabric_self_invalid"});
    };
    if let Some(caps) = request.get("caps").and_then(Value::as_array) {
        node.set_caps(caps.iter().filter_map(Value::as_str));
    }
    let now = SystemClock.now_ms();
    node.publish(now);
    let answer = json!({
        "ok": true,
        "self": node.self_id(),
        "enabled": node.config().enabled,
        "heartbeat_ms": node.config().heartbeat_ms,
        "offer_window_ms": node.config().offer_window_ms,
        "caps": node.caps_json(),
        "queued": node.queued(),
    });
    NODE.with(|slot| *slot.borrow_mut() = Some(node));
    answer
}

/// `host.fabric_admin` action `status`: the live view, recent placements, fallbacks and leases.
pub fn admin(request: &Value) -> Value {
    let kind = request.get("kind").and_then(Value::as_str).unwrap_or("stt");
    let now = SystemClock.now_ms();
    NODE.with(|slot| match slot.borrow().as_ref() {
        Some(node) => node.admin(kind, now),
        None => json!({"ok": false, "error": "fabric_not_configured"}),
    })
}

/// `host.fabric_admin` action `tick`: housekeeping; returns what it queued and what fell back.
pub fn tick() -> Value {
    let now = SystemClock.now_ms();
    NODE.with(|slot| {
    let mut slot = slot.borrow_mut();
    let Some(node) = slot.as_mut() else { return json!({"ok": false, "error": "fabric_not_configured"}) };
    let tick = node.tick(now);
    json!({
        "ok": true,
        "beats": tick.beats,
        "local": tick.local.iter().map(|(job, reason)| json!({"job": job, "because": reason.as_str()})).collect::<Vec<_>>(),
        "queued": node.queued(),
    })
    })
}

/// `host.fabric_admin` action `submit`: enqueue a job of `kind` and place it.
pub fn submit(request: &Value) -> Value {
    let kind = request.get("kind").and_then(Value::as_str).unwrap_or_default();
    let Some(payload) = request.get("payload").and_then(Value::as_str) else {
        return json!({"ok": false, "error": "fabric_payload_required"});
    };
    let now = SystemClock.now_ms();
    NODE.with(|slot| {
    let mut slot = slot.borrow_mut();
    let Some(node) = slot.as_mut() else { return json!({"ok": false, "error": "fabric_not_configured"}) };
    match node.submit(kind, payload.as_bytes().to_vec(), now) {
        Ok(submission) => json!({
            "ok": true,
            "job": submission.job.0,
            "plan": submission.plan.to_json(),
            "local": submission.local,
            "queued": node.queued(),
        }),
        Err(error) => json!({"ok": false, "error": error}),
    }
    })
}

/// `host.fabric_admin` action `take`: lease the next due job of `kind` here.
pub fn take(request: &Value) -> Value {
    let kind = request.get("kind").and_then(Value::as_str).unwrap_or_default();
    let lease_ms = request.get("lease_ms").and_then(Value::as_i64).unwrap_or(5_000).clamp(1, 3_600_000);
    let now = SystemClock.now_ms();
    NODE.with(|slot| {
    let mut slot = slot.borrow_mut();
    let Some(node) = slot.as_mut() else { return json!({"ok": false, "error": "fabric_not_configured"}) };
    match node.take(kind, lease_ms, now) {
        Ok(Some(lease)) => json!({
            "ok": true,
            "job": lease.job.0,
            "queue": lease.queue,
            "worker": lease.worker,
            "until_ms": lease.until_ms,
        }),
        Ok(None) => json!({"ok": true, "job": null}),
        Err(error) => json!({"ok": false, "error": error}),
    }
    })
}

/// `host.fabric_admin` action `settle`: settle a leased job here.
pub fn settle(request: &Value) -> Value {
    let kind = request.get("kind").and_then(Value::as_str).unwrap_or_default();
    let Some(job) = request.get("job").and_then(Value::as_u64) else {
        return json!({"ok": false, "error": "fabric_job_required"});
    };
    let result = request.get("result").and_then(Value::as_str).unwrap_or_default();
    let now = SystemClock.now_ms();
    NODE.with(|slot| {
    let mut slot = slot.borrow_mut();
    let Some(node) = slot.as_mut() else { return json!({"ok": false, "error": "fabric_not_configured"}) };
    let Some(lease) = node.lease(job).cloned() else {
        return json!({"ok": false, "error": "lease_lost"});
    };
    let _ = (kind, now);
    match node.settle(&lease, result.as_bytes()) {
        Ok(()) => json!({"ok": true, "job": job}),
        Err(error) => json!({"ok": false, "error": error}),
    }
    })
}

/// `host.fabric_pending`: the next call the pump must sign and send, or `null`.
pub fn pending() -> Value {
    NODE.with(|slot| match slot.borrow_mut().as_mut().and_then(FabricNode::next_call) {
        Some(call) => call.to_json(),
        None => Value::Null,
    })
}

/// `host.fabric_deliver(id, reply_json)`: hand the peer's answer back, and return the next call.
///
/// `id` names the call the pump answered; the reply is the peer's `accept`/`refuse`/`beat` body, or
/// `{"unreachable": "reason"}` when the transport could not deliver it. The answer is
/// `{"resolved": …, "next": <call|null>}` so one tick can drain the whole sequence.
pub fn deliver(id: u64, reply: &str) -> Value {
    let now = SystemClock.now_ms();
    let parsed: Value = serde_json::from_str(reply).unwrap_or(Value::Null);
    NODE.with(|slot| {
    let mut slot = slot.borrow_mut();
    let Some(node) = slot.as_mut() else { return json!({"ok": false, "error": "fabric_not_configured"}) };
    let resolved = match reply_value(&parsed) {
        ReplyBody::Beat(beat) => {
            node.observe(beat, now);
            json!({"beat": true})
        }
        ReplyBody::Accept(accept) => match node.in_flight.remove(&id) {
            Some(job) => resolution_json(node.on_reply(job, Reply::Accept(accept), now)),
            None => json!({"ignored": "unknown_call"}),
        },
        ReplyBody::Refuse(refuse) => match node.in_flight.remove(&id) {
            Some(job) => resolution_json(node.on_reply(job, Reply::Refuse(refuse), now)),
            None => json!({"ignored": "unknown_call"}),
        },
        ReplyBody::Unreachable(reason) => match node.in_flight.remove(&id) {
            Some(job) => resolution_json(node.on_reply(job, Reply::Unreachable(reason), now)),
            None => json!({"ignored": "unknown_call"}),
        },
        ReplyBody::Unreadable => json!({"ignored": "unreadable"}),
    };
    let next = node.next_call().map(|call| call.to_json()).unwrap_or(Value::Null);
    json!({"ok": true, "resolved": resolved, "next": next})
    })
}

/// `host.fabric_call(envelope_json, caller)`: one signed call from a peer — its heartbeat or an offer.
/// The caller id is the one the transport verified, so a body cannot claim to be another node.
pub fn call(body: &str, caller: &str) -> Value {
    let now = SystemClock.now_ms();
    NODE.with(|slot| {
    let mut slot = slot.borrow_mut();
    let Some(node) = slot.as_mut() else { return json!({"refused": "fabric_not_configured"}) };
    if let Ok(beat) = Heartbeat::decode(body.as_bytes()) {
        if beat.node.as_str() != caller {
            return json!({"refused": "malformed:node"});
        }
        let observed = node.observe(beat, now);
        return json!({"ok": true, "beats": observed.beats});
    }
    match Offer::decode(body.as_bytes()) {
        Ok(offer) => {
            if offer.from.as_str() != caller {
                return json!({"refused": "malformed:sender"});
            }
            node.answer(&offer, now)
        }
        Err(refusal) => json!({"refused": refusal.as_str()}),
    }
    })
}

enum ReplyBody {
    Beat(Heartbeat),
    Accept(Accept),
    Refuse(offer::Refuse),
    Unreachable(String),
    Unreadable,
}

fn reply_value(value: &Value) -> ReplyBody {
    let text = value.to_string();
    if let Ok(beat) = Heartbeat::decode(text.as_bytes()) {
        return ReplyBody::Beat(beat);
    }
    if let Ok(accept) = Accept::decode(text.as_bytes()) {
        return ReplyBody::Accept(accept);
    }
    if let Ok(refuse) = offer::Refuse::decode(text.as_bytes()) {
        return ReplyBody::Refuse(refuse);
    }
    if let Some(reason) = value.get("unreachable").and_then(Value::as_str) {
        return ReplyBody::Unreachable(reason.to_string());
    }
    ReplyBody::Unreadable
}

fn resolution_json(resolution: Resolution) -> Value {
    match resolution {
        Resolution::Placed { node, rtt_ms } => json!({"placed": node, "rtt_ms": rtt_ms}),
        Resolution::Reoffered { to } => json!({"reoffered": to}),
        Resolution::Local { because } => json!({"local": because.as_str()}),
        Resolution::Ignored => json!({"ignored": "stale_offer"}),
    }
}

impl FabricNode {
    /// The capabilities this node advertises, as JSON (the `configure` answer).
    pub fn caps_json(&self) -> Value {
        self.caps.to_json()
    }
}

#[cfg(test)]
mod tests;
