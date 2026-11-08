//! The producing node: enqueue a request, serve the audio to a worker that holds the lease, delete it
//! afterwards, and work the queue locally when the remote is not the better choice.
//!
//! This is the side that owns the audio and the freshness rule. A job is enqueued with the window the
//! note arrived with (`sent_at + fresh_ms`), so a worker that reads it late is told to drop it and the
//! queue's own `take` never hands it out; the bytes are written to the node's store behind a
//! short-lived handle, served only to the worker that currently holds the lease, and deleted when the
//! job is settled. Nothing here logs audio, and nothing keeps it after the job.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, Mutex};

use wa_queue::{Clock, EnqueueOutcome, JobId, JobState, Queue, QueueError, TakeOutcome};

use crate::metrics::Metrics;
use crate::policy::{Decision, Latency, LocalReason, Preference, RemoteHealth};
use crate::protocol::Refusal;
use crate::request::{AudioSource, FetchHandle, Mime, RequestError, SttRequest, INLINE_MAX_BYTES, MAX_AUDIO_BYTES};
use crate::worker::{queue_error, Decoder, JobSink, LocalSink, Outcome, Recognizer, Segment, Transcript, WireError};

/// The queue every worker in phase 2 consumes. One name, on the producing node only: a remote worker
/// reaches it through the relay, it never has a queue of its own.
pub const QUEUE: &str = "stt.requests";

/// The freshness window, from when the note was *sent* (the connector's `WA_WHATSAPP_FRESH_SECONDS`,
/// `docs/WHATSAPP-TRANSCRIPTION.md`): a transcript is worth posting only while the conversation is
/// live.
pub const DEFAULT_FRESH_MS: i64 = 300_000;

/// Decode attempts before the job is dead-lettered (the connector's `maxComputeFailures`).
pub const DEFAULT_MAX_ATTEMPTS: u32 = 6;

/// How long a fetch handle stays usable. Long enough for a slow download over the relay, short enough
/// that a handle found in an old log is worthless.
pub const DEFAULT_FETCH_TTL_MS: i64 = 120_000;

/// The live band: a note sent inside this window runs before the backlog
/// (`docs/WHATSAPP-TRANSCRIPTION.md`, "Queue order").
pub const LIVE_BAND_MS: i64 = 15 * 60 * 1000;

/// Where a job's audio lives between the enqueue and the decode.
///
/// One method per thing that happens to a blob: written, read once by the worker holding the lease,
/// deleted when the job is settled. The host wires it to the component's kv; a test uses
/// [`MemoryAudioStore`]. Nothing in this trait reads outside the store, so the audio never touches a
/// path the owner did not grant.
pub trait AudioStore {
    fn put(&self, handle: &str, bytes: &[u8]) -> Result<(), String>;
    fn get(&self, handle: &str) -> Result<Option<Vec<u8>>, String>;
    fn del(&self, handle: &str) -> Result<(), String>;
}

/// An in-memory [`AudioStore`]: the shape a kv namespace implements, and what the tests use.
#[derive(Clone, Default)]
pub struct MemoryAudioStore {
    inner: Arc<Mutex<BTreeMap<String, Vec<u8>>>>,
}

impl MemoryAudioStore {
    pub fn new() -> MemoryAudioStore {
        MemoryAudioStore::default()
    }

    /// How many blobs are held. For assertions about deletion, not for an operator.
    pub fn len(&self) -> usize {
        self.inner.lock().unwrap_or_else(|error| error.into_inner()).len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn contains(&self, handle: &str) -> bool {
        self.inner.lock().unwrap_or_else(|error| error.into_inner()).contains_key(handle)
    }
}

impl AudioStore for MemoryAudioStore {
    fn put(&self, handle: &str, bytes: &[u8]) -> Result<(), String> {
        self.inner.lock().unwrap_or_else(|error| error.into_inner()).insert(handle.to_string(), bytes.to_vec());
        Ok(())
    }

    fn get(&self, handle: &str) -> Result<Option<Vec<u8>>, String> {
        Ok(self.inner.lock().unwrap_or_else(|error| error.into_inner()).get(handle).cloned())
    }

    fn del(&self, handle: &str) -> Result<(), String> {
        self.inner.lock().unwrap_or_else(|error| error.into_inner()).remove(handle);
        Ok(())
    }
}

/// The producing node's knobs. `docs/QUEUE.md` names each of them; the values are the connector's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SttPolicy {
    pub fresh_ms: i64,
    pub max_attempts: u32,
    pub fetch_ttl_ms: i64,
    /// Above this, the audio is written to the store instead of the payload.
    pub inline_max: usize,
    /// Set an operator-visible timeout on a job that is still unfinished; `None` = no deadline.
    pub deadline_ms: Option<i64>,
}

impl Default for SttPolicy {
    fn default() -> Self {
        SttPolicy {
            fresh_ms: DEFAULT_FRESH_MS,
            max_attempts: DEFAULT_MAX_ATTEMPTS,
            fetch_ttl_ms: DEFAULT_FETCH_TTL_MS,
            inline_max: INLINE_MAX_BYTES,
            deadline_ms: None,
        }
    }
}

/// What the channel knows about one note when it arrives. No text, by construction.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Arrival {
    pub audio: Vec<u8>,
    pub mime: Mime,
    pub language: String,
    pub account: String,
    pub generation: u64,
    pub chat: String,
    pub msg: String,
    /// When the account says the note was sent (the freshness clock starts here, not at ingestion).
    pub sent_at_ms: i64,
    pub declared_seconds: Option<u32>,
}

/// Why an enqueue did not happen. Never a silent drop: the caller turns this into the own-chat alert
/// the connector already has (`audio_expired`, `unsupported`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnqueueFailure {
    /// Already past its window: stored, it could only be dropped, so it is not stored.
    Stale { fresh_until_ms: i64 },
    /// The request cannot be represented (an oversized blob, a bad id).
    Request(RequestError),
    /// The audio store refused the blob.
    Audio(String),
    /// The queue refused the job.
    Queue(QueueError),
}

impl fmt::Display for EnqueueFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EnqueueFailure::Stale { fresh_until_ms } => write!(formatter, "stale:{fresh_until_ms}"),
            EnqueueFailure::Request(error) => write!(formatter, "request:{}", error.reason()),
            EnqueueFailure::Audio(reason) => write!(formatter, "audio:{reason}"),
            EnqueueFailure::Queue(error) => write!(formatter, "queue:{error}"),
        }
    }
}

/// The producing node's half of phase 2.
pub struct Producer<'a> {
    pub queue: &'a Queue,
    pub audio: &'a dyn AudioStore,
    pub policy: SttPolicy,
    pub clock: &'a dyn Clock,
}

impl<'a> Producer<'a> {
    pub fn new(queue: &'a Queue, audio: &'a dyn AudioStore, policy: SttPolicy, clock: &'a dyn Clock) -> Producer<'a> {
        Producer { queue, audio, policy, clock }
    }

    /// The queue priority of a note, from its age: live band first, backlog second, anything that has
    /// already failed last (`docs/QUEUE.md` "priority 20 fresh and unattempted, 10 backlog, 0 after a
    /// failure"; the queue itself puts a retry behind its backoff).
    pub fn priority(&self, now_ms: i64, sent_at_ms: i64, attempts: u32) -> u32 {
        if attempts > 0 {
            return 0;
        }
        if now_ms.saturating_sub(sent_at_ms) <= LIVE_BAND_MS {
            20
        } else {
            10
        }
    }

    /// Enqueue one note. `handle` names the blob when it is too big for the payload — an opaque,
    /// per-job token the caller gets from its own id generator (`host.uuid` on a node).
    pub fn enqueue(&self, arrival: &Arrival, handle: &str, metrics: &mut Metrics) -> Result<EnqueueOutcome, EnqueueFailure> {
        let now_ms = self.clock.now_ms();
        let fresh_until_ms = arrival.sent_at_ms.saturating_add(self.policy.fresh_ms);
        if arrival.audio.is_empty() || arrival.audio.len() > MAX_AUDIO_BYTES {
            return Err(EnqueueFailure::Request(RequestError::TooLarge("audio")));
        }
        if fresh_until_ms <= now_ms {
            // Past the window on arrival: decoded, it could only be posted late. The queue would
            // store a job it is going to drop; the producer knows better and says so.
            metrics.stale_dropped += 1;
            return Err(EnqueueFailure::Stale { fresh_until_ms });
        }
        let audio = if arrival.audio.len() <= self.policy.inline_max {
            AudioSource::Inline(arrival.audio.clone(), arrival.mime)
        } else {
            if handle.is_empty() {
                return Err(EnqueueFailure::Audio("missing_handle".into()));
            }
            self.audio.put(handle, &arrival.audio).map_err(EnqueueFailure::Audio)?;
            AudioSource::Fetch(FetchHandle::new(handle, now_ms.saturating_add(self.policy.fetch_ttl_ms), arrival.audio.len() as u64, arrival.mime))
        };
        let request = SttRequest {
            audio,
            language: arrival.language.clone(),
            fresh_until_ms,
            chat: arrival.chat.clone(),
            msg: arrival.msg.clone(),
            account: arrival.account.clone(),
            generation: arrival.generation,
            declared_seconds: arrival.declared_seconds,
        };
        let payload = request.encode();
        let mut enqueue = wa_queue::EnqueueRequest::new(QUEUE, payload)
            .priority(self.priority(now_ms, arrival.sent_at_ms, 0))
            .fresh_for((fresh_until_ms - now_ms).max(1))
            .max_attempts(self.policy.max_attempts)
            .dedupe(request.dedupe_key());
        if let Some(deadline) = self.policy.deadline_ms {
            enqueue = enqueue.deadline_in(deadline);
        }
        match self.queue.enqueue(enqueue) {
            Ok(outcome) => {
                if outcome.dedupe_hit {
                    // The note is already queued under an older job (with its own handle): the blob
                    // this call just wrote belongs to no job, so it does not stay.
                    if let AudioSource::Fetch(handle) = &request.audio {
                        let _ = self.audio.del(&handle.handle);
                    }
                } else {
                    metrics.enqueued += 1;
                }
                Ok(outcome)
            }
            Err(error) => {
                // The job never existed, so its blob must not stay behind either.
                if let AudioSource::Fetch(handle) = &request.audio {
                    let _ = self.audio.del(&handle.handle);
                }
                Err(EnqueueFailure::Queue(error))
            }
        }
    }

    /// Hand the audio to a remote worker that currently holds this job's lease.
    ///
    /// Three things must hold, and the answer says which one did not: the job is leased **by that
    /// worker** (a worker whose lease lapsed cannot come back for the bytes), the job is still fresh
    /// (the transcript would be posted late), and the handle is the job's own and unexpired. Then the
    /// bytes are read once.
    pub fn serve_audio(&self, job: u64, worker: &str, handle: &str, now_ms: i64) -> Result<Vec<u8>, Refusal> {
        let record = self.queue.job(JobId(job)).map_err(|_| Refusal::Failed("queue_store"))?.ok_or(Refusal::NotFound)?;
        if record.state != JobState::Leased || record.lease_worker.as_deref() != Some(worker) {
            return Err(Refusal::LeaseLost);
        }
        if record.fresh_until.is_some_and(|until| now_ms >= until) {
            return Err(Refusal::StaleJob);
        }
        let request = SttRequest::decode(&record.payload).map_err(|_| Refusal::Malformed("payload"))?;
        let AudioSource::Fetch(named) = &request.audio else {
            return Err(Refusal::NotFound);
        };
        if named.handle != handle {
            return Err(Refusal::NotFound);
        }
        if named.is_expired(now_ms) {
            // The handle aged out: the audio is gone and the job is not worth decoding, which is a
            // different answer from "you named a blob that does not exist".
            return Err(Refusal::StaleJob);
        }
        self.audio.get(handle).map_err(|_| Refusal::Failed("audio_store"))?.ok_or(Refusal::NotFound)
    }

    /// Delete a job's audio. Called by the worker that settled it (the local one directly, the remote
    /// one over the relay), and idempotent: the sweeper may have got there first.
    pub fn discard_audio(&self, job: u64, handle: &str) -> bool {
        // Only the handle the job names may be deleted: a caller cannot name someone else's blob.
        let Ok(Some(record)) = self.queue.job(JobId(job)) else { return false };
        let Ok(request) = SttRequest::decode(&record.payload) else { return false };
        match &request.audio {
            AudioSource::Fetch(named) if named.handle == handle => self.audio.del(handle).is_ok(),
            _ => false,
        }
    }

    /// Drop audio nobody will decode any more: the job is terminal, or its handle expired, or the job
    /// is gone. A sweeper calls this on every tick; it returns how many blobs went.
    pub fn purge_audio(&self, now_ms: i64) -> usize {
        let Ok(jobs) = self.queue.list(QUEUE, None, 512) else { return 0 };
        let mut purged = 0;
        for record in jobs {
            let Ok(request) = SttRequest::decode(&record.payload) else { continue };
            let AudioSource::Fetch(handle) = &request.audio else { continue };
            let worthless = record.state.is_terminal()
                || handle.is_expired(now_ms)
                || record.fresh_until.is_some_and(|until| now_ms >= until && record.state != JobState::Leased);
            if worthless && self.audio.del(&handle.handle).is_ok() {
                purged += 1;
            }
        }
        purged
    }
}

/// This node's own worker: the fallback that also runs when no `stt_worker` node answers.
pub struct LocalWorker<'a> {
    pub queue: &'a Queue,
    pub audio: &'a dyn AudioStore,
    /// This node's id, so a lease holder is attributable (`local:<node>`).
    pub node: String,
    pub lease_ms: i64,
    pub heartbeat_every_ms: i64,
}

impl LocalWorker<'_> {
    fn worker(&self) -> String {
        format!("local:{}", self.node)
    }

    /// One poll: hold back for a preferred remote, otherwise take the next job and decode it.
    ///
    /// The grace is a decision *not to take*, so "first lease wins" is untouched: a remote that
    /// leases the job while this poll is waiting still owns it, and this poll finds nothing.
    pub fn poll_once(
        &self,
        preference: &Preference,
        remote: Option<&RemoteHealth>,
        latency: &mut Latency,
        recognizer: &mut dyn Recognizer,
        clock: &dyn Clock,
        metrics: &mut Metrics,
    ) -> Outcome {
        let now_ms = clock.now_ms();
        let stats = match self.queue.stats(QUEUE) {
            Ok(stats) => stats,
            Err(error) => return Outcome::Unreachable { reason: queue_error(error).reason() },
        };
        // The grace is about a job waiting to be chosen. A job that is not Ready is either out with
        // another worker or gone; when its lease has lapsed, `take` below recovers it and hands it
        // over, which is the wanted outcome and not a reason to hold back a second time.
        if stats.ready > 0 {
            let enqueued_at_ms = now_ms.saturating_sub(stats.oldest_ready_age_ms.max(0));
            match preference.decide(now_ms, enqueued_at_ms, remote, latency) {
                Decision::Remote { grace_until_ms, .. } => {
                    metrics.waited_for_remote += 1;
                    return Outcome::Deferred { until_ms: grace_until_ms };
                }
                Decision::Local { because } => match because {
                    LocalReason::GraceElapsed => metrics.fallback_taken += 1,
                    LocalReason::RemoteOffline | LocalReason::RemoteSlower | LocalReason::FabricLocal => {
                        metrics.local_immediate += 1
                    }
                },
            }
        }

        let worker = self.worker();
        let outcome = match self.queue.take(QUEUE, &worker, Some(self.lease_ms)) {
            Ok(TakeOutcome::Job(job)) => {
                let job = *job;
                if job.lease_expiries > 0 {
                    // The queue recovers a lapsed lease on this `take`; advancing the clock past it is
                    // the normal case here (a remote node vanished mid-job).
                    metrics.lease_recovered += 1;
                }
                self.work(job.id.0, &job.payload, recognizer, clock, metrics)
            }
            Ok(TakeOutcome::AtLimit { leased, .. }) => Outcome::Busy(leased as u32),
            Ok(TakeOutcome::Empty) => Outcome::Empty,
            Err(error) => Outcome::Unreachable { reason: queue_error(error).reason() },
        };
        if let Outcome::Decoded { took_ms, .. } = &outcome {
            latency.record(clock.now_ms(), *took_ms);
        }
        outcome
    }

    fn work(&self, job: u64, payload: &[u8], recognizer: &mut dyn Recognizer, clock: &dyn Clock, metrics: &mut Metrics) -> Outcome {
        let request = match SttRequest::decode(payload) {
            Ok(request) => request,
            Err(error) => {
                let mut sink = LocalSink { queue: self.queue, lease_ms: self.lease_ms };
                let reason = format!("payload:{}", error.reason());
                let _ = sink.fail(job, &self.worker(), &reason);
                return Outcome::Failed { job, reason, retryable: false };
            }
        };
        let audio = match &request.audio {
            AudioSource::Inline(bytes, _) => bytes.clone(),
            AudioSource::Fetch(handle) => match self.audio.get(&handle.handle) {
                Ok(Some(bytes)) => bytes,
                _ => {
                    let mut sink = LocalSink { queue: self.queue, lease_ms: self.lease_ms };
                    let _ = sink.fail(job, &self.worker(), "audio unavailable");
                    return Outcome::Failed { job, reason: "audio unavailable".into(), retryable: true };
                }
            },
        };
        let decoder = Decoder { worker: self.worker(), lease_ms: self.lease_ms, heartbeat_every_ms: self.heartbeat_every_ms, by: crate::metrics::Who::Local };
        let mut sink = LocalSink { queue: self.queue, lease_ms: self.lease_ms };
        decoder.decode(&mut sink, recognizer, job, &request, audio, clock, metrics)
    }
}

/// Settle a job through an [`AudioStore`]-backed sink: the local worker's progress/done/fail, with the
/// audio deleted by the same store the enqueue wrote to. Kept as a free function so a host that owns
/// the store does not have to re-implement the ordering.
pub fn settle_local(queue: &Queue, lease_ms: i64, job: u64, worker: &str, transcript: &Transcript) -> Result<(), WireError> {
    let mut sink = LocalSink { queue, lease_ms };
    sink.done(job, worker, transcript)
}

/// One progress entry as the producer reads it back: the typed segment record
/// (`docs/QUEUE.md`'s open question, settled for this queue because the consumer is a transcript).
pub fn read_progress(queue: &Queue, job: u64, after: u64, limit: usize) -> Vec<Segment> {
    queue
        .progress_since(JobId(job), after, limit)
        .map(|entries| {
            entries
                .into_iter()
                .filter_map(|entry| serde_json::from_slice::<serde_json::Value>(&entry.bytes).ok().and_then(|value| Segment::from_json(&value)))
                .collect()
        })
        .unwrap_or_default()
}
