//! Two nodes in one process: the producing node (its queue, its audio store, its local worker) and the
//! owner's strong node (a `stt_worker` role), joined by a [`Relay`] that speaks the real wire.
//!
//! The relay is not a mock of the queue: every call builds a `protocol::Envelope`, signs it the way a
//! node does (`<op>|<node_id>|<ts>|<sha256(body)>`), the producer's `Admission` checks it, and only
//! then is the queue touched. What the simulation replaces is the *transport* (a relay POST) and the
//! *recognizer* (a warm faster-whisper), and it can make both fail on demand — which is how "the
//! remote dies mid-job" is a test and not a story.
//!
//! Determinism: one `wa_queue::FixedClock` per node, moved by hand; every hop costs `latency_ms` on
//! the caller's clock, so a remote call is measurably later than a local one and no test sleeps.

use std::collections::BTreeSet;
use std::sync::Arc;

use wa_queue::{Clock, FixedClock, MemoryKv, Queue, TakeOutcome};

use crate::metrics::{Metrics, Who};
use crate::policy::Latency;
use crate::producer::{LocalWorker, MemoryAudioStore, Producer, SttPolicy};
use crate::protocol::{
    Admission, AudioBody, Envelope, Op, Refusal, Reply, SettleBody, TakeBody, TakeReply, TransportSignature,
};
use crate::request::{self, Mime, SttRequest};
use crate::worker::{Recognizer, RecognizerError, RemoteWorker, Segment, Transcript, Transport, WireError};

/// The producing node: the queue, the audio store, the grants an arriving call is checked against, and
/// the counters. It is the node whose clock decides freshness and leases.
pub struct SimNode {
    pub id: String,
    pub queue: Queue,
    pub audio: MemoryAudioStore,
    pub clock: Arc<FixedClock>,
    pub admission: Admission,
    pub metrics: Metrics,
    pub policy: SttPolicy,
}

impl SimNode {
    /// Build the producing node, with `owner_nodes` as the only node ids allowed to call it.
    pub fn producer(id: &str, now_ms: i64, owner_nodes: &[&str]) -> SimNode {
        let clock = Arc::new(FixedClock::new(now_ms));
        SimNode {
            id: id.to_string(),
            queue: Queue::new(Arc::new(MemoryKv::new()), clock.clone(), wa_queue::Policy::default()),
            audio: MemoryAudioStore::new(),
            clock,
            admission: Admission::new(id, owner_nodes.iter().map(|node| node.to_string()).collect::<BTreeSet<_>>()),
            metrics: Metrics::new(),
            policy: SttPolicy::default(),
        }
    }

    pub fn now_ms(&self) -> i64 {
        self.clock.now_ms()
    }

    /// Advance this node's clock (the other node's does not move: the nodes are independent).
    pub fn advance(&self, ms: i64) -> i64 {
        self.clock.advance(ms)
    }

    pub fn producer_api(&self) -> Producer<'_> {
        Producer::new(&self.queue, &self.audio, self.policy.clone(), self.clock.as_ref())
    }

    pub fn local_worker(&self) -> LocalWorker<'_> {
        LocalWorker { queue: &self.queue, audio: &self.audio, node: self.id.clone(), lease_ms: 60_000, heartbeat_every_ms: 15_000 }
    }
}

/// A worker node's view of itself: its id, its clock, its measured latencies and its counters.
pub struct SimWorker {
    pub id: String,
    pub clock: Arc<FixedClock>,
    pub latency: Latency,
    pub metrics: Metrics,
}

impl SimWorker {
    pub fn new(id: &str, now_ms: i64) -> SimWorker {
        SimWorker { id: id.to_string(), clock: Arc::new(FixedClock::new(now_ms)), latency: Latency::new(), metrics: Metrics::new() }
    }

    /// This node as a remote worker: the identity is `stt:<node>`, so two workers of one node are two
    /// lease holders and a lease belongs to exactly one of them.
    pub fn remote_worker(&self) -> RemoteWorker {
        RemoteWorker::new(format!("stt:{}", self.id))
    }
}

/// The signed transport between the two nodes. It answers like the relay: a call it cannot deliver is
/// `Unreachable`, a call the producer refuses is `Refused`.
///
/// Failure injection, all of it honest about *where* it happens:
/// * [`Relay::die_after`] — the link works for `n` more calls and then stops answering for good (the
///   remote node vanished mid-job);
/// * [`Relay::drop_next`] — the next `n` calls are lost (a relay hiccup);
/// * [`Relay::attached`] — whether the worker node is polling at all.
pub struct Relay {
    pub from: String,
    pub producer: SimNode,
    /// The caller's clock. A hop advances it: a remote call costs the round trip, a local one does not.
    pub hop_clock: Arc<FixedClock>,
    pub latency_ms: i64,
    /// Audio bytes this link carried.
    pub bytes: u64,
    /// Calls attempted (answered, refused or lost).
    pub calls: u64,
    budget: Option<u64>,
    drop_next: u64,
    attached: bool,
}

impl Relay {
    pub fn new(from: &str, producer: SimNode, hop_clock: Arc<FixedClock>) -> Relay {
        Relay {
            from: from.to_string(),
            producer,
            hop_clock,
            latency_ms: 40,
            bytes: 0,
            calls: 0,
            budget: None,
            drop_next: 0,
            attached: true,
        }
    }

    pub fn with_latency_ms(mut self, latency_ms: i64) -> Relay {
        self.latency_ms = latency_ms;
        self
    }

    /// The node disappears after `calls` more calls.
    pub fn die_after(mut self, calls: u64) -> Relay {
        self.budget = Some(calls);
        self
    }

    /// The next `calls` calls are lost.
    pub fn drop_next(mut self, calls: u64) -> Relay {
        self.drop_next = calls;
        self
    }

    /// Attach or detach the worker node (a node that is not polling cannot be reached).
    pub fn attached(&mut self, attached: bool) {
        self.attached = attached;
    }

    /// One signed call: envelope, signature, admission, then the queue.
    fn call(&mut self, op: Op, body: serde_json::Value) -> Result<serde_json::Value, WireError> {
        self.calls += 1;
        self.hop_clock.advance(self.latency_ms);
        if !self.attached {
            return Err(WireError::Unreachable("node_not_attached".into()));
        }
        if self.drop_next > 0 {
            self.drop_next -= 1;
            return Err(WireError::Unreachable("relay_dropped".into()));
        }
        if let Some(budget) = self.budget.as_mut() {
            if *budget == 0 {
                return Err(WireError::Unreachable("node_gone".into()));
            }
            *budget -= 1;
        }
        let now = self.hop_clock.now_ms();
        let envelope = Envelope::new(op, self.from.clone(), self.producer.id.clone(), now, format!("rid-{}-{now}", self.calls), body);
        let wire = envelope.encode();
        let digest = digest_of(&wire);
        let signature = format!("sig:{}", envelope.signature_message(&digest));
        let verify = |message: &str, from: &str, given: &str| !from.is_empty() && given == format!("sig:{message}");
        let admitted = self.producer.admission.admits(
            &envelope,
            TransportSignature { ts_ms: envelope.ts_ms, body_sha256_hex: &digest, signature: &signature },
            now,
            1024,
            &verify,
        );
        if let Err(refusal) = admitted {
            self.producer.metrics.record_refusal(&refusal);
            return Err(WireError::Refused(refusal));
        }
        match self.execute(&envelope) {
            Reply::Ok(value) => Ok(value),
            Reply::Refused(refusal) => {
                self.producer.metrics.record_refusal(&refusal);
                Err(WireError::Refused(refusal))
            }
        }
    }

    /// What the producing node does with an admitted call: the queue, and the audio behind the handle.
    fn execute(&mut self, envelope: &Envelope) -> Reply {
        let now = self.producer.clock.now_ms();
        match envelope.op {
            Op::Take => {
                let Ok(body) = TakeBody::from_json(&envelope.body) else {
                    return Reply::Refused(Refusal::Malformed("take_body"));
                };
                match self.producer.queue.take(&body.queue, &body.worker, body.lease_ms) {
                    Ok(TakeOutcome::Job(job)) => {
                        let Ok(request) = SttRequest::decode(&job.payload) else {
                            return Reply::Refused(Refusal::Malformed("payload"));
                        };
                        let reply = TakeReply::Taken {
                            job: job.id.0,
                            lease_until_ms: job.lease_until.unwrap_or(now),
                            attempts: job.attempts,
                            request,
                        };
                        Reply::Ok(reply.to_json())
                    }
                    Ok(TakeOutcome::AtLimit { leased, .. }) => Reply::Ok(TakeReply::Busy(leased as u32).to_json()),
                    Ok(TakeOutcome::Empty) => Reply::Ok(TakeReply::Empty.to_json()),
                    Err(_) => Reply::Refused(Refusal::Failed("queue_store")),
                }
            }
            Op::Audio => {
                let Ok(body) = AudioBody::from_json(&envelope.body) else {
                    return Reply::Refused(Refusal::Malformed("audio_body"));
                };
                let producer = Producer::new(&self.producer.queue, &self.producer.audio, self.producer.policy.clone(), self.producer.clock.as_ref());
                match producer.serve_audio(body.job, &body.worker, &body.handle, now) {
                    Ok(bytes) => Reply::Ok(serde_json::json!({"b64": request::base64_encode(&bytes)})),
                    Err(refusal) => Reply::Refused(refusal),
                }
            }
            Op::Heartbeat => {
                let Ok(body) = SettleBody::from_json(&envelope.body, &["extend_ms"]) else {
                    return Reply::Refused(Refusal::Malformed("beat_body"));
                };
                let extend = body.payload.get("extend_ms").and_then(serde_json::Value::as_i64);
                match self.producer.queue.heartbeat(wa_queue::JobId(body.job), &body.worker, extend) {
                    Ok(until) => Reply::Ok(serde_json::json!({"lease_until_ms": until})),
                    Err(error) => Reply::Refused(refusal_of(error)),
                }
            }
            Op::Progress => {
                let Ok(body) = SettleBody::from_json(&envelope.body, &["segment"]) else {
                    return Reply::Refused(Refusal::Malformed("seg_body"));
                };
                let chunk = body.payload.get("segment").cloned().unwrap_or(serde_json::Value::Null).to_string().into_bytes();
                match self.producer.queue.progress(wa_queue::JobId(body.job), &chunk) {
                    Ok(seq) => Reply::Ok(serde_json::json!({"seq": seq})),
                    Err(error) => Reply::Refused(refusal_of(error)),
                }
            }
            Op::Done => {
                let Ok(body) = SettleBody::from_json(&envelope.body, &["transcript"]) else {
                    return Reply::Refused(Refusal::Malformed("done_body"));
                };
                let Some(transcript) = body.payload.get("transcript").and_then(Transcript::from_json) else {
                    return Reply::Refused(Refusal::Malformed("transcript"));
                };
                let result = transcript.to_json().to_string().into_bytes();
                match self.producer.queue.done_by(wa_queue::JobId(body.job), &body.worker, &result) {
                    Ok(_) => {
                        // The remote measured its own decode; that measurement is what the preference
                        // policy compares with this node's, so it is recorded where the producer is.
                        self.producer.metrics.record_decode(Who::Remote, transcript.elapsed_ms as i64);
                        Reply::Ok(serde_json::json!({"settled": true}))
                    }
                    Err(error) => Reply::Refused(refusal_of(error)),
                }
            }
            Op::Fail => {
                let Ok(body) = SettleBody::from_json(&envelope.body, &["reason"]) else {
                    return Reply::Refused(Refusal::Malformed("fail_body"));
                };
                let reason = body.payload.get("reason").and_then(serde_json::Value::as_str).unwrap_or("worker_failed");
                match self.producer.queue.fail_by(wa_queue::JobId(body.job), &body.worker, reason) {
                    Ok(outcome) => Reply::Ok(serde_json::json!({"dead": outcome.dead, "attempts": outcome.attempts})),
                    Err(error) => Reply::Refused(refusal_of(error)),
                }
            }
        }
    }
}

impl Transport for Relay {
    fn take(&mut self, body: &TakeBody) -> Result<TakeReply, WireError> {
        let value = self.call(Op::Take, body.to_json())?;
        TakeReply::from_json(&value).map_err(WireError::Refused)
    }

    fn fetch_audio(&mut self, job: u64, worker: &str, handle: &str) -> Result<Vec<u8>, WireError> {
        let value = self.call(Op::Audio, serde_json::json!({"job": job, "worker": worker, "handle": handle}))?;
        let encoded = value.get("b64").and_then(serde_json::Value::as_str).ok_or(WireError::Refused(Refusal::Malformed("audio")))?;
        let bytes = request::base64_decode(encoded).ok_or(WireError::Refused(Refusal::Malformed("audio")))?;
        self.bytes += bytes.len() as u64;
        Ok(bytes)
    }

    fn heartbeat(&mut self, job: u64, worker: &str, extend_ms: i64) -> Result<i64, WireError> {
        let value = self.call(Op::Heartbeat, serde_json::json!({"job": job, "worker": worker, "extend_ms": extend_ms}))?;
        value.get("lease_until_ms").and_then(serde_json::Value::as_i64).ok_or(WireError::Refused(Refusal::Malformed("beat_reply")))
    }

    fn progress(&mut self, job: u64, worker: &str, segment: &Segment) -> Result<(), WireError> {
        self.call(Op::Progress, serde_json::json!({"job": job, "worker": worker, "segment": segment.to_json()})).map(|_| ())
    }

    fn done(&mut self, job: u64, worker: &str, transcript: &Transcript) -> Result<(), WireError> {
        self.call(Op::Done, serde_json::json!({"job": job, "worker": worker, "transcript": transcript.to_json()})).map(|_| ())
    }

    fn fail(&mut self, job: u64, worker: &str, reason: &str) -> Result<(), WireError> {
        self.call(Op::Fail, serde_json::json!({"job": job, "worker": worker, "reason": crate::protocol::sanitize(reason)})).map(|_| ())
    }

    fn discard_audio(&mut self, job: u64, worker: &str, handle: &str) {
        // Best effort and outside the lease: the producing node's sweeper deletes the blob anyway
        // (`Producer::purge_audio`), so a lost call here costs a tick, not the privacy rule.
        let _ = worker;
        let producer = Producer::new(&self.producer.queue, &self.producer.audio, self.producer.policy.clone(), self.producer.clock.as_ref());
        producer.discard_audio(job, handle);
    }
}

/// The transport digest. A plain FNV-1a: what the tests prove is the *binding* (the signature covers
/// the op, the caller, the timestamp and the body digest), not the digest function; a node uses
/// `host.sha256` over the same bytes (`protocol::Envelope::signature_message`).
fn digest_of(body: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in body {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100_0000_01b3);
    }
    format!("{hash:016x}")
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

/// A recognizer a test drives: how long one segment "takes", what it says, and whether it fails. No
/// model, no process, no sleep — the clock is moved by the worker's own callbacks, so timings are exact.
pub struct FakeRecognizer {
    /// Milliseconds of decode per segment.
    pub step_ms: i64,
    pub segments: Vec<&'static str>,
    pub failure: Option<RecognizerError>,
    /// Decodes that actually ran (the assertion for "the stale job was never decoded").
    pub ran: u32,
    pub audio_seen: u64,
}

impl FakeRecognizer {
    pub fn new(step_ms: i64, segments: Vec<&'static str>) -> FakeRecognizer {
        FakeRecognizer { step_ms, segments, failure: None, ran: 0, audio_seen: 0 }
    }

    pub fn failing(step_ms: i64, failure: RecognizerError) -> FakeRecognizer {
        FakeRecognizer { step_ms, segments: Vec::new(), failure: Some(failure), ran: 0, audio_seen: 0 }
    }

    /// A recognizer that advances a clock while it works — the shape the real worker has: the decode
    /// takes wall time, and the lease has to be extended inside it.
    pub fn ticking(step_ms: i64, segments: Vec<&'static str>, clock: Arc<FixedClock>) -> TickingRecognizer {
        TickingRecognizer { inner: FakeRecognizer::new(step_ms, segments), clock }
    }
}

impl Recognizer for FakeRecognizer {
    fn recognize(
        &mut self,
        audio: &[u8],
        _mime: Mime,
        language: &str,
        on_segment: &mut dyn FnMut(Segment),
    ) -> Result<Transcript, RecognizerError> {
        self.ran += 1;
        self.audio_seen += audio.len() as u64;
        let mut at = 0u64;
        for text in &self.segments {
            at += self.step_ms.max(0) as u64;
            on_segment(Segment::new(at.saturating_sub(self.step_ms.max(0) as u64), at, *text));
        }
        if let Some(failure) = &self.failure {
            return Err(failure.clone());
        }
        Ok(Transcript { text: self.segments.join(" "), language: language.to_string(), segments: self.segments.len() as u32, elapsed_ms: at })
    }
}

/// A [`Recognizer`] that moves a clock as it decodes, so heartbeat and lease arithmetic is exercised.
pub struct TickingRecognizer {
    inner: FakeRecognizer,
    clock: Arc<FixedClock>,
}

impl TickingRecognizer {
    pub fn ran(&self) -> u32 {
        self.inner.ran
    }

    pub fn audio_seen(&self) -> u64 {
        self.inner.audio_seen
    }
}

impl Recognizer for TickingRecognizer {
    fn recognize(
        &mut self,
        audio: &[u8],
        mime: Mime,
        language: &str,
        on_segment: &mut dyn FnMut(Segment),
    ) -> Result<Transcript, RecognizerError> {
        self.inner.ran += 1;
        self.inner.audio_seen += audio.len() as u64;
        let mut at = 0u64;
        let mut texts = Vec::new();
        for text in &self.inner.segments {
            self.clock.advance(self.inner.step_ms.max(0));
            at += self.inner.step_ms.max(0) as u64;
            texts.push(text.to_string());
            on_segment(Segment::new(at.saturating_sub(self.inner.step_ms.max(0) as u64), at, *text));
        }
        if let Some(failure) = &self.inner.failure {
            return Err(failure.clone());
        }
        let _ = mime;
        Ok(Transcript { text: texts.join(" "), language: language.to_string(), segments: texts.len() as u32, elapsed_ms: at })
    }
}
