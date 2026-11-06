//! The wire: one signed node call per queue operation, and the checks a producing node makes before
//! it answers one.
//!
//! The transport is the one that already exists (`docs/RENDEZVOUS.md`, "Relay"): a relayed call is
//! `POST /relay/send` with a body, and the caller signs `<action>|<node_id>|<ts>|<sha256(body)>` with
//! its node key (`lua/core/nodes.lua#sign_action`). This module does not invent a transport: an
//! [`Envelope`] *is* that body, its `op` *is* the action word, and [`Admission`] is the check the
//! producing node makes on arrival — target, caller, freshness, signature, replay — before it hands
//! anything to the queue.
//!
//! Two properties matter more than the encoding:
//!
//! * **Only the owner's own nodes may ask.** The caller must be in the producer's node list; a
//!   relay call from a stranger is refused before the body is parsed, so audio never crosses to a
//!   node the owner did not put there.
//! * **A call is admitted once.** The `rid` is the relay's own idempotency id; a second envelope with
//!   the same id is `replayed_request`, which is what stops a captured `done` from settling a second
//!   job or posting a transcript twice.

use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};

use crate::request::SttRequest;

/// The protocol generation, in the envelope and in the refusal words. A bump is a new contract.
pub const PROTOCOL_VERSION: u64 = 1;

/// How far from "now" a call's timestamp may be. The clock is the producer's; a node with a wrong
/// clock is refused a call, not given a lease it cannot keep.
pub const DEFAULT_SKEW_MS: i64 = 60_000;

/// How many answered `rid`s are remembered. Bounded, so a flood of signed calls cannot grow the
/// node's memory; the oldest entry is forgotten first, and forgetting only widens the window in
/// which a replay could be attempted inside the skew window.
pub const MAX_REPLAY_ENTRIES: usize = 4096;

/// The longest a failure reason may be, one line. The queue sanitizes its own too
/// (`docs/QUEUE.md`, "Alerts"); this is the same rule before it crosses the wire.
pub const MAX_REASON_CHARS: usize = 200;

/// What a caller is asking the producing node to do. The word is the transport's action, so a
/// `done` is signed as `done|<node_id>|<ts>|<sha256(body)>` on the wire.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    /// Long-poll for one job.
    Take,
    /// Fetch the bytes behind a `fresh` request's handle.
    Audio,
    /// Extend a lease (always a duration, never an absolute instant: the producer's clock decides).
    Heartbeat,
    /// One recognized segment, as progress.
    Progress,
    /// The whole transcript, as the result.
    Done,
    /// Give the job up: retry with backoff, or dead-letter.
    Fail,
}

impl Op {
    pub fn as_str(self) -> &'static str {
        match self {
            Op::Take => "take",
            Op::Audio => "audio",
            Op::Heartbeat => "beat",
            Op::Progress => "seg",
            Op::Done => "done",
            Op::Fail => "fail",
        }
    }

    pub fn parse(text: &str) -> Option<Op> {
        match text {
            "take" => Some(Op::Take),
            "audio" => Some(Op::Audio),
            "beat" => Some(Op::Heartbeat),
            "seg" => Some(Op::Progress),
            "done" => Some(Op::Done),
            "fail" => Some(Op::Fail),
            _ => None,
        }
    }
}

/// One call body. `from`/`to` are node ids; `ts_ms` is the caller's clock and `rid` the relay's
/// idempotency id (one id for the whole operation, so a retried fetch re-collects the same answer).
#[derive(Clone, Debug, PartialEq)]
pub struct Envelope {
    pub op: Op,
    pub from: String,
    pub to: String,
    pub ts_ms: i64,
    pub rid: String,
    pub body: Value,
}

impl Envelope {
    pub fn new(op: Op, from: impl Into<String>, to: impl Into<String>, ts_ms: i64, rid: impl Into<String>, body: Value) -> Envelope {
        Envelope { op, from: from.into(), to: to.into(), ts_ms, rid: rid.into(), body }
    }

    /// The body the relay carries. Strict: a field the protocol does not name is refused, so an
    /// envelope from a newer producer fails loudly instead of half-executing.
    pub fn encode(&self) -> Vec<u8> {
        json!({
            "v": PROTOCOL_VERSION,
            "op": self.op.as_str(),
            "from": self.from,
            "to": self.to,
            "ts_ms": self.ts_ms,
            "rid": self.rid,
            "body": self.body,
        })
        .to_string()
        .into_bytes()
    }

    pub fn decode(bytes: &[u8]) -> Result<Envelope, Refusal> {
        let text = std::str::from_utf8(bytes).map_err(|_| Refusal::Malformed("not_utf8"))?;
        let value: Value = serde_json::from_str(text).map_err(|_| Refusal::Malformed("not_json"))?;
        let object = value.as_object().ok_or(Refusal::Malformed("not_an_object"))?;
        for key in object.keys() {
            if !matches!(key.as_str(), "v" | "op" | "from" | "to" | "ts_ms" | "rid" | "body") {
                return Err(Refusal::Malformed("unknown_field"));
            }
        }
        let version = object.get("v").and_then(Value::as_u64).ok_or(Refusal::Malformed("v"))?;
        if version != PROTOCOL_VERSION {
            return Err(Refusal::Version(version));
        }
        let op = object.get("op").and_then(Value::as_str).and_then(Op::parse).ok_or(Refusal::Malformed("op"))?;
        let from = bounded(object, "from")?;
        let to = bounded(object, "to")?;
        let ts_ms = object.get("ts_ms").and_then(Value::as_i64).ok_or(Refusal::Malformed("ts_ms"))?;
        let rid = bounded(object, "rid")?;
        let body = object.get("body").cloned().filter(Value::is_object).ok_or(Refusal::Malformed("body"))?;
        Ok(Envelope { op, from, to, ts_ms, rid, body })
    }

    /// What the node signs for this call, given the body digest the transport computed
    /// (`host.sha256` over [`Envelope::encode`]): `<op>|<node_id>|<ts>|<sha256 hex>`.
    ///
    /// The digest is passed in rather than computed here because hashing already happens on the
    /// transport path, and a second implementation of it would be a second thing to get wrong.
    pub fn signature_message(&self, body_sha256_hex: &str) -> String {
        format!("{}|{}|{}|{}", self.op.as_str(), self.from, self.ts_ms, body_sha256_hex)
    }
}

/// The already-verified transport facts about one arriving call.
#[derive(Clone, Copy, Debug)]
pub struct TransportSignature<'a> {
    /// The `X-WA-Ts` the caller signed with.
    pub ts_ms: i64,
    /// `sha256` of the body, hex, as the caller signed it.
    pub body_sha256_hex: &'a str,
    /// `X-WA-Sig`.
    pub signature: &'a str,
}

/// The producing node's admission state: who may call, how much clock skew is tolerated, and which
/// `rid`s were already answered.
///
/// Not `Send`-by-design-free: a node owns one of these, behind its own lock, because the replay set
/// is the point.
#[derive(Debug, Clone)]
pub struct Admission {
    me: String,
    owner_nodes: BTreeSet<String>,
    skew_ms: i64,
    seen: BTreeMap<String, i64>,
}

impl Admission {
    /// `me` is this node's id; `owner_nodes` is the owner's own node ids (the registry list, not a
    /// name: a node's name is self-chosen and never matches).
    pub fn new(me: impl Into<String>, owner_nodes: impl IntoIterator<Item = String>) -> Admission {
        Admission { me: me.into(), owner_nodes: owner_nodes.into_iter().collect(), skew_ms: DEFAULT_SKEW_MS, seen: BTreeMap::new() }
    }

    pub fn with_skew_ms(mut self, skew_ms: i64) -> Admission {
        self.skew_ms = skew_ms.max(0);
        self
    }

    pub fn skew_ms(&self) -> i64 {
        self.skew_ms
    }

    /// May this node call at all? The same question as "is it one of the owner's nodes".
    pub fn allows(&self, node: &str) -> bool {
        self.owner_nodes.contains(node)
    }

    /// How many `rid`s are remembered (a test asserts the bound holds).
    pub fn remembered(&self) -> usize {
        self.seen.len()
    }

    /// Admit one call, or refuse it.
    ///
    /// `verify(message, from_node, signature)` is the node's own key check — the rendezvous-confirmed
    /// public key of `from`, as `serve.rs` does for every signed route. Order is deliberate: the
    /// cheap structural facts first, the signature before the replay set is touched, and the `rid`
    /// recorded only for a call that passed everything, so an attacker cannot fill the set with
    /// forged ids.
    pub fn admits(
        &mut self,
        envelope: &Envelope,
        transport: TransportSignature<'_>,
        now_ms: i64,
        budget: usize,
        verify: &dyn Fn(&str, &str, &str) -> bool,
    ) -> Result<(), Refusal> {
        if envelope.to != self.me {
            return Err(Refusal::WrongTarget);
        }
        if !self.allows(&envelope.from) {
            return Err(Refusal::UnknownCaller);
        }
        // The signed timestamp and the envelope's must agree: otherwise the signature covers an
        // instant the caller then rewrote, and a captured call could be made to look new.
        if transport.ts_ms != envelope.ts_ms {
            return Err(Refusal::BadSignature);
        }
        // Saturating, and compared as an unsigned distance: `ts_ms` arrives from the wire, and a
        // crafted `i64::MIN` must be a refusal, not an overflow panic in a debug build.
        let skew = now_ms.saturating_sub(envelope.ts_ms).unsigned_abs();
        if skew > self.skew_ms.unsigned_abs() {
            return Err(Refusal::Stale);
        }
        if !verify(&envelope.signature_message(transport.body_sha256_hex), &envelope.from, transport.signature) {
            return Err(Refusal::BadSignature);
        }
        if self.seen.contains_key(&envelope.rid) {
            return Err(Refusal::Replayed);
        }
        self.remember(envelope.rid.clone(), envelope.ts_ms, budget);
        Ok(())
    }

    fn remember(&mut self, rid: String, ts_ms: i64, budget: usize) {
        let budget = budget.clamp(1, MAX_REPLAY_ENTRIES);
        // Forget a call once its timestamp is older than the window in which it could still be
        // admitted, so the set stays proportional to traffic inside one skew window. `ts_ms` is
        // already known to be inside that window (`admits` checked before calling this).
        let horizon = ts_ms.saturating_sub(2 * self.skew_ms);
        self.seen.retain(|_, at| *at >= horizon);
        // Then make room by dropping the oldest *by timestamp*, not the smallest request id: an id is
        // opaque and sorting by it could forget the call that was just admitted.
        while self.seen.len() >= budget {
            let oldest = self.seen.iter().min_by_key(|(_, at)| **at).map(|(rid, _)| rid.clone());
            match oldest {
                Some(rid) => {
                    self.seen.remove(&rid);
                }
                None => break,
            }
        }
        self.seen.insert(rid, ts_ms);
    }
}

/// Why a call or an operation was refused. Every word is a fixed token: a refusal reply never echoes
/// the request, so it cannot carry text back to a caller that should not have it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// A protocol generation this node does not speak.
    Version(u64),
    /// `to` is not this node.
    WrongTarget,
    /// The caller is not one of the owner's nodes.
    UnknownCaller,
    /// The call's timestamp is outside the skew window.
    Stale,
    /// The signature does not cover this call.
    BadSignature,
    /// This `rid` was already answered.
    Replayed,
    /// The envelope or a body field is not what the protocol says.
    Malformed(&'static str),
    /// The caller does not hold this job's lease (it expired, or another worker has it).
    LeaseLost,
    /// No such job / handle.
    NotFound,
    /// The job went stale: it is not decoded and its result is not posted.
    StaleJob,
    /// The audio is larger than the producer will move over the relay.
    TooLarge,
    /// The caller asked before it may (the local worker's grace has not elapsed).
    NotYet,
    /// The producing node's own store failed. Never reported as success.
    Failed(&'static str),
}

impl Refusal {
    /// The bounded word that goes on the wire and into a metric.
    pub fn as_str(&self) -> String {
        match self {
            Refusal::Version(version) => format!("version:{version}"),
            Refusal::WrongTarget => "wrong_target".into(),
            Refusal::UnknownCaller => "unknown_caller".into(),
            Refusal::Stale => "stale_request".into(),
            Refusal::BadSignature => "bad_signature".into(),
            Refusal::Replayed => "replayed_request".into(),
            Refusal::Malformed(what) => format!("malformed:{what}"),
            Refusal::LeaseLost => "lease_lost".into(),
            Refusal::NotFound => "not_found".into(),
            Refusal::StaleJob => "stale_job".into(),
            Refusal::TooLarge => "too_large".into(),
            Refusal::NotYet => "not_yet".into(),
            Refusal::Failed(what) => format!("failed:{what}"),
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.as_str())
    }
}

impl std::error::Error for Refusal {}

/// One answer. `Ok` carries the op's value; `Refused` the word.
#[derive(Clone, Debug, PartialEq)]
pub enum Reply {
    Ok(Value),
    Refused(Refusal),
}

impl Reply {
    pub fn ok(value: Value) -> Reply {
        Reply::Ok(value)
    }

    pub fn encode(&self) -> Vec<u8> {
        match self {
            Reply::Ok(value) => json!({"ok": value}).to_string().into_bytes(),
            Reply::Refused(refusal) => json!({"refused": refusal.as_str()}).to_string().into_bytes(),
        }
    }

    pub fn decode(bytes: &[u8]) -> Result<Reply, Refusal> {
        let text = std::str::from_utf8(bytes).map_err(|_| Refusal::Malformed("not_utf8"))?;
        let value: Value = serde_json::from_str(text).map_err(|_| Refusal::Malformed("not_json"))?;
        let object = value.as_object().ok_or(Refusal::Malformed("not_an_object"))?;
        if let Some(ok) = object.get("ok") {
            return Ok(Reply::Ok(ok.clone()));
        }
        let word = object.get("refused").and_then(Value::as_str).ok_or(Refusal::Malformed("reply"))?;
        Ok(Reply::Refused(refusal_from_word(word)))
    }
}

fn refusal_from_word(word: &str) -> Refusal {
    match word {
        "wrong_target" => Refusal::WrongTarget,
        "unknown_caller" => Refusal::UnknownCaller,
        "stale_request" => Refusal::Stale,
        "bad_signature" => Refusal::BadSignature,
        "replayed_request" => Refusal::Replayed,
        "lease_lost" => Refusal::LeaseLost,
        "not_found" => Refusal::NotFound,
        "stale_job" => Refusal::StaleJob,
        "too_large" => Refusal::TooLarge,
        "not_yet" => Refusal::NotYet,
        other => Refusal::Malformed(if other.starts_with("version:") { "version" } else { "refusal" }),
    }
}

/// One line, bounded, with control characters folded to spaces. Used for a failure reason, which the
/// queue stores and the operator log may print: never a transcript, never a payload.
pub fn sanitize(text: &str) -> String {
    let mut out: String = text.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    out = out.split_whitespace().collect::<Vec<_>>().join(" ");
    if out.chars().count() > MAX_REASON_CHARS {
        out = out.chars().take(MAX_REASON_CHARS).collect();
    }
    out
}

// ---- the op bodies ------------------------------------------------------------------------------

/// `take`: which queue, which worker identity, how long a lease, how long to wait for work.
///
/// The long poll is a *server-side* wait bounded by `wait_ms`; a producer that has nothing to hand
/// out answers `empty` at the end of it, which is the "ask later" answer of `wa:queue`, not an error.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TakeBody {
    pub queue: String,
    pub worker: String,
    pub lease_ms: Option<i64>,
    pub wait_ms: i64,
}

impl TakeBody {
    pub fn new(queue: &str, worker: &str, lease_ms: Option<i64>, wait_ms: i64) -> TakeBody {
        TakeBody { queue: queue.to_string(), worker: worker.to_string(), lease_ms, wait_ms }
    }

    pub fn to_json(&self) -> Value {
        json!({"queue": self.queue, "worker": self.worker, "lease_ms": self.lease_ms, "wait_ms": self.wait_ms})
    }

    pub fn from_json(body: &Value) -> Result<TakeBody, Refusal> {
        let object = object(body)?;
        Ok(TakeBody {
            queue: bounded(object, "queue")?,
            worker: bounded(object, "worker")?,
            lease_ms: optional_number(object, "lease_ms")?,
            wait_ms: optional_number(object, "wait_ms")?.unwrap_or(0).clamp(0, MAX_WAIT_MS),
        })
    }
}

/// The longest a `take` may hold the call open (the relay holds ~20 s per attempt; this stays under
/// it so the answer is the producer's, not the relay's timeout).
pub const MAX_WAIT_MS: i64 = 15_000;

/// What a `take` found. Mirrors `wa_queue::TakeOutcome`, plus the decoded request so the worker does
/// not have to re-parse the payload (and cannot disagree about it).
#[derive(Clone, Debug, PartialEq)]
pub enum TakeReply {
    Taken { job: u64, lease_until_ms: i64, attempts: u32, request: SttRequest },
    Empty,
    /// The queue is at its concurrency limit; the number is how many are leased.
    Busy(u32),
}

impl TakeReply {
    pub fn to_json(&self) -> Value {
        match self {
            TakeReply::Taken { job, lease_until_ms, attempts, request } => {
                let mut value = serde_json::from_slice::<Value>(&request.encode()).unwrap_or(Value::Null);
                if let Value::Object(ref mut object) = value {
                    object.insert("job".into(), json!(job));
                    object.insert("lease_until_ms".into(), json!(lease_until_ms));
                    object.insert("attempts".into(), json!(attempts));
                }
                json!({"taken": value})
            }
            TakeReply::Empty => json!({"state": "empty"}),
            TakeReply::Busy(leased) => json!({"state": "busy", "leased": leased}),
        }
    }

    pub fn from_json(value: &Value) -> Result<TakeReply, Refusal> {
        let object = object(value)?;
        if object.get("state").and_then(Value::as_str) == Some("empty") {
            return Ok(TakeReply::Empty);
        }
        if object.get("state").and_then(Value::as_str) == Some("busy") {
            let leased = object.get("leased").and_then(Value::as_u64).unwrap_or(0) as u32;
            return Ok(TakeReply::Busy(leased));
        }
        let taken = object.get("taken").and_then(Value::as_object).ok_or(Refusal::Malformed("take_reply"))?;
        let job = taken.get("job").and_then(Value::as_u64).ok_or(Refusal::Malformed("job"))?;
        let lease_until_ms = taken.get("lease_until_ms").and_then(Value::as_i64).ok_or(Refusal::Malformed("lease_until_ms"))?;
        let attempts = taken.get("attempts").and_then(Value::as_u64).unwrap_or(0) as u32;
        // The request is the payload as it was enqueued; `SttRequest::decode` ignores the three
        // envelope fields the reply added.
        let request = SttRequest::decode(&Value::Object(copy_without(taken, &["job", "lease_until_ms", "attempts"])).to_string().into_bytes())
            .map_err(|error| Refusal::Malformed(if error.reason().starts_with("version") { "request_version" } else { "request" }))?;
        Ok(TakeReply::Taken { job, lease_until_ms, attempts, request })
    }
}

/// `audio`: fetch the bytes behind a request's handle.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioBody {
    pub job: u64,
    pub worker: String,
    pub handle: String,
}

impl AudioBody {
    pub fn to_json(&self) -> Value {
        json!({"job": self.job, "worker": self.worker, "handle": self.handle})
    }

    pub fn from_json(body: &Value) -> Result<AudioBody, Refusal> {
        let object = object(body)?;
        Ok(AudioBody {
            job: object.get("job").and_then(Value::as_u64).ok_or(Refusal::Malformed("job"))?,
            worker: bounded(object, "worker")?,
            handle: bounded(object, "handle")?,
        })
    }
}

/// `beat` / `seg` / `done` / `fail`: the worker's identity plus what it is reporting.
#[derive(Clone, Debug, PartialEq)]
pub struct SettleBody {
    pub job: u64,
    pub worker: String,
    pub payload: Value,
}

impl SettleBody {
    pub fn to_json(&self) -> Value {
        let mut object = match self.payload.clone() {
            Value::Object(object) => object,
            _ => Map::new(),
        };
        object.insert("job".into(), json!(self.job));
        object.insert("worker".into(), json!(self.worker));
        Value::Object(object)
    }

    pub fn from_json(body: &Value, payload_keys: &[&str]) -> Result<SettleBody, Refusal> {
        let object = object(body)?;
        let job = object.get("job").and_then(Value::as_u64).ok_or(Refusal::Malformed("job"))?;
        let worker = bounded(object, "worker")?;
        let mut payload = Map::new();
        for key in payload_keys {
            if let Some(value) = object.get(*key) {
                payload.insert((*key).to_string(), value.clone());
            }
        }
        Ok(SettleBody { job, worker, payload: Value::Object(payload) })
    }
}

fn object(value: &Value) -> Result<&Map<String, Value>, Refusal> {
    value.as_object().ok_or(Refusal::Malformed("not_an_object"))
}

fn bounded(object: &Map<String, Value>, key: &str) -> Result<String, Refusal> {
    let value = object.get(key).and_then(Value::as_str).ok_or(Refusal::Malformed(match key {
        "queue" => "queue",
        "worker" => "worker",
        "from" => "from",
        "to" => "to",
        "rid" => "rid",
        _ => "field",
    }))?;
    if value.is_empty() || value.chars().count() > 128 {
        return Err(Refusal::Malformed("field"));
    }
    Ok(value.to_string())
}

fn optional_number(object: &Map<String, Value>, key: &str) -> Result<Option<i64>, Refusal> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value.as_i64().map(Some).ok_or(Refusal::Malformed("field")),
    }
}

fn copy_without(object: &Map<String, Value>, drop: &[&str]) -> Map<String, Value> {
    object.iter().filter(|(key, _)| !drop.iter().any(|name| name == key)).map(|(k, v)| (k.clone(), v.clone())).collect()
}
