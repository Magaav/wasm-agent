//! One worker, local or remote: take a job, download the audio, decode it, stream segments, settle.
//!
//! The two workers differ only in *where the queue is*: the local one calls the queue in this process
//! (the component's kv), the remote one calls it over the relay through [`Transport`]. Everything
//! after "I hold a job" — the freshness checks, the heartbeat cadence, the segment progress, the
//! final settle and the deletion of the audio — is one implementation ([`Decoder`]) so a remote and a
//! local decode cannot drift apart in what they decide about a stale job or a lost lease.
//!
//! Timing comes from an injected `wa_queue::Clock`: no `Instant::now()` anywhere, so the tests move
//! time by hand and get exact millisecond numbers.

use std::fmt;

use wa_queue::Clock;

use crate::metrics::{JobTrace, Metrics, Who};
use crate::protocol::{sanitize, Refusal, TakeBody, TakeReply};
use crate::request::{AudioSource, Mime, SttRequest};

/// One recognized segment: the text the worker streamed back and the audio offsets it covers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Segment {
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
}

impl Segment {
    pub fn new(start_ms: u64, end_ms: u64, text: impl Into<String>) -> Segment {
        Segment { start_ms, end_ms, text: text.into() }
    }

    /// Does this segment carry anything? A blank window (the recognizer's punctuation and silence
    /// passes) is not a first segment and is not streamed.
    pub fn has_text(&self) -> bool {
        !self.text.trim().is_empty()
    }

    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({"start_ms": self.start_ms, "end_ms": self.end_ms, "text": self.text})
    }

    pub fn from_json(value: &serde_json::Value) -> Option<Segment> {
        Some(Segment {
            start_ms: value.get("start_ms")?.as_u64()?,
            end_ms: value.get("end_ms")?.as_u64()?,
            text: value.get("text")?.as_str()?.to_string(),
        })
    }
}

/// The whole transcript, as the queue's result. It carries the text because the producer has to post
/// it; nothing in this crate logs it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Transcript {
    pub text: String,
    pub language: String,
    pub segments: u32,
    /// Wall time the recognizer itself spent.
    pub elapsed_ms: u64,
}

impl Transcript {
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "text": self.text,
            "language": self.language,
            "segments": self.segments,
            "elapsed_ms": self.elapsed_ms,
        })
    }

    pub fn from_json(value: &serde_json::Value) -> Option<Transcript> {
        Some(Transcript {
            text: value.get("text")?.as_str()?.to_string(),
            language: value.get("language")?.as_str().unwrap_or("").to_string(),
            segments: value.get("segments").and_then(serde_json::Value::as_u64).unwrap_or(0) as u32,
            elapsed_ms: value.get("elapsed_ms").and_then(serde_json::Value::as_u64).unwrap_or(0),
        })
    }
}

/// A decode that did not produce a transcript, classified the way the connector classifies a failed
/// note (`docs/WHATSAPP-TRANSCRIPTION.md`, "Retries and fallbacks"): a permanent condition is never
/// retried, an environment problem is the node's and retried slowly, a decode failure walks tiers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecognizerError {
    /// No speech, unsupported view-once, too large: retrying cannot help.
    Permanent(String),
    /// Missing model cache, missing interpreter, media gone.
    Environment(String),
    /// Stall, budget, worker crash or protocol.
    Decode(String),
}

impl RecognizerError {
    /// The one-line reason that goes on the wire and into the queue's `last_error`. Every kind is
    /// prefixed so a reader (and the retry tiers) can tell them apart without guessing at prose.
    pub fn reason(&self) -> String {
        match self {
            RecognizerError::Permanent(what) => sanitize(&format!("unsupported:{what}")),
            RecognizerError::Environment(what) => sanitize(&format!("environment:{what}")),
            RecognizerError::Decode(what) => sanitize(&format!("decode:{what}")),
        }
    }

    /// Should the job be retried at all? A permanent failure is dead on arrival.
    pub fn retryable(&self) -> bool {
        !matches!(self, RecognizerError::Permanent(_))
    }
}

/// The recognizer the worker runs: the warm faster-whisper on a `stt_worker` node, or the kernel's
/// `wa:kernel/speech` service on the producing node. Nothing here spawns a process.
pub trait Recognizer {
    /// Decode `audio`, calling `on_segment` for every non-empty segment as it is recognized (that is
    /// what makes progress streaming possible). The callback is called from the decoding thread; it
    /// must not block for long.
    fn recognize(
        &mut self,
        audio: &[u8],
        mime: Mime,
        language: &str,
        on_segment: &mut dyn FnMut(Segment),
    ) -> Result<Transcript, RecognizerError>;
}

/// What went wrong on the wire. `Refused` is an answer the producer gave; `Unreachable` is the relay
/// or the node not answering at all — the difference decides whether a job is dropped or its lease
/// is allowed to lapse.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WireError {
    /// No answer: the node is gone, the relay refused, the call timed out.
    Unreachable(String),
    /// The producer answered, with a refusal.
    Refused(Refusal),
}

impl WireError {
    pub fn reason(&self) -> String {
        match self {
            WireError::Unreachable(reason) => sanitize(&format!("unreachable:{reason}")),
            WireError::Refused(refusal) => refusal.as_str(),
        }
    }

    /// A failed call that proves the caller no longer owns the job.
    pub fn lease_lost(&self) -> bool {
        matches!(self, WireError::Refused(Refusal::LeaseLost | Refusal::NotFound | Refusal::StaleJob))
    }
}

impl From<Refusal> for WireError {
    fn from(refusal: Refusal) -> WireError {
        WireError::Refused(refusal)
    }
}

impl fmt::Display for WireError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.reason())
    }
}

/// Where a worker settles a job. The remote worker implements it over the relay, the local one over
/// the queue; [`Decoder`] only ever sees this.
pub trait JobSink {
    fn heartbeat(&mut self, job: u64, worker: &str) -> Result<i64, WireError>;
    fn progress(&mut self, job: u64, worker: &str, segment: &Segment) -> Result<(), WireError>;
    fn done(&mut self, job: u64, worker: &str, transcript: &Transcript) -> Result<(), WireError>;
    fn fail(&mut self, job: u64, worker: &str, reason: &str) -> Result<(), WireError>;
    /// The producer deletes the audio for `job` (and revokes its fetch handle). Best effort by
    /// design: a failed delete is reported by the producer's own sweep, never silently "fine".
    fn discard_audio(&mut self, job: u64, handle: Option<&str>);
}

/// The local worker's sink: the queue in this process, no relay.
pub struct LocalSink<'a> {
    pub queue: &'a wa_queue::Queue,
    pub lease_ms: i64,
}

impl JobSink for LocalSink<'_> {
    fn heartbeat(&mut self, job: u64, worker: &str) -> Result<i64, WireError> {
        self.queue.heartbeat(wa_queue::JobId(job), worker, Some(self.lease_ms)).map_err(queue_error)
    }

    fn progress(&mut self, job: u64, _worker: &str, segment: &Segment) -> Result<(), WireError> {
        let chunk = segment.to_json().to_string().into_bytes();
        // `progress` does not name the worker: the library appends to the leased job, and a lease
        // that lapsed is refused by the settle that follows.
        self.queue.progress(wa_queue::JobId(job), &chunk).map(|_| ()).map_err(queue_error)
    }

    fn done(&mut self, job: u64, worker: &str, transcript: &Transcript) -> Result<(), WireError> {
        self.queue
            .done_by(wa_queue::JobId(job), worker, &transcript.to_json().to_string().into_bytes())
            .map(|_| ())
            .map_err(queue_error)
    }

    fn fail(&mut self, job: u64, worker: &str, reason: &str) -> Result<(), WireError> {
        self.queue.fail_by(wa_queue::JobId(job), worker, reason).map(|_| ()).map_err(queue_error)
    }

    fn discard_audio(&mut self, _job: u64, _handle: Option<&str>) {
        // The producing node owns the bytes; the local worker's caller does that with the same
        // `AudioStore` it wrote them to (`Producer::discard_audio`).
    }
}

/// A queue error in the worker's vocabulary.
pub fn queue_error(error: wa_queue::QueueError) -> WireError {
    match error {
        wa_queue::QueueError::LeaseLost => WireError::Refused(Refusal::LeaseLost),
        wa_queue::QueueError::NotFound => WireError::Refused(Refusal::NotFound),
        wa_queue::QueueError::Invalid(_) => WireError::Refused(Refusal::Failed("invalid")),
        wa_queue::QueueError::TooLarge(_) | wa_queue::QueueError::ProgressFull => WireError::Refused(Refusal::TooLarge),
        wa_queue::QueueError::Kv(_) | wa_queue::QueueError::Corrupt(_) => WireError::Unreachable("queue_store".into()),
        other => WireError::Unreachable(format!("queue:{other}")),
    }
}

/// A remote worker: the queue is on another node, reached through [`Transport`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteWorker {
    /// The queue name (`stt.requests`).
    pub queue: String,
    /// This worker's identity on the producer: `stt@<node id>` and the pid/instance, so two workers
    /// of one node are two identities and a lease belongs to exactly one of them.
    pub worker: String,
    /// How long a lease is taken for, and how often it is extended while decoding.
    pub lease_ms: i64,
    /// How long one `take` may hold the relay call open.
    pub wait_ms: i64,
    /// Extend the lease at most this often while segments stream in.
    pub heartbeat_every_ms: i64,
}

impl RemoteWorker {
    pub fn new(worker: impl Into<String>) -> RemoteWorker {
        RemoteWorker {
            queue: crate::producer::QUEUE.to_string(),
            worker: worker.into(),
            lease_ms: 60_000,
            wait_ms: crate::protocol::MAX_WAIT_MS,
            heartbeat_every_ms: 15_000,
        }
    }

    pub fn decoder(&self) -> Decoder {
        Decoder { worker: self.worker.clone(), lease_ms: self.lease_ms, heartbeat_every_ms: self.heartbeat_every_ms, by: Who::Remote }
    }

    /// One long poll: ask for a job and, when there is one, do it. `Outcome::Empty` is the normal
    /// "nothing to do" answer, not a failure.
    pub fn poll_once<T: Transport, R: Recognizer>(
        &self,
        transport: &mut T,
        recognizer: &mut R,
        clock: &dyn Clock,
        metrics: &mut Metrics,
    ) -> Outcome {
        let body = TakeBody::new(&self.queue, &self.worker, Some(self.lease_ms), self.wait_ms);
        let reply = match transport.take(&body) {
            Ok(reply) => reply,
            Err(WireError::Unreachable(reason)) => return Outcome::Unreachable { reason },
            Err(WireError::Refused(refusal)) => {
                metrics.record_refusal(&refusal);
                return Outcome::Refused { reason: refusal.as_str() };
            }
        };
        let (job, request) = match reply {
            TakeReply::Empty => return Outcome::Empty,
            TakeReply::Busy(leased) => return Outcome::Busy(leased),
            TakeReply::Taken { job, request, .. } => (job, request),
        };
        let mut sink = TransportSink { transport, worker: self.worker.clone(), lease_ms: self.lease_ms };
        let audio = match fetch(sink.transport, &self.worker, job, &request, clock.now_ms(), metrics) {
            Ok(audio) => audio,
            Err(outcome) => return outcome,
        };
        self.decoder().decode(&mut sink, recognizer, job, &request, audio, clock, metrics)
    }
}

/// The remote worker's sink: every settle is one signed call.
struct TransportSink<'a, T: Transport> {
    transport: &'a mut T,
    worker: String,
    lease_ms: i64,
}

impl<T: Transport> JobSink for TransportSink<'_, T> {
    fn heartbeat(&mut self, job: u64, worker: &str) -> Result<i64, WireError> {
        self.transport.heartbeat(job, worker, self.lease_ms)
    }

    fn progress(&mut self, job: u64, worker: &str, segment: &Segment) -> Result<(), WireError> {
        self.transport.progress(job, worker, segment)
    }

    fn done(&mut self, job: u64, worker: &str, transcript: &Transcript) -> Result<(), WireError> {
        self.transport.done(job, worker, transcript)
    }

    fn fail(&mut self, job: u64, worker: &str, reason: &str) -> Result<(), WireError> {
        self.transport.fail(job, worker, reason)
    }

    fn discard_audio(&mut self, job: u64, handle: Option<&str>) {
        if let Some(handle) = handle {
            self.transport.discard_audio(job, &self.worker, handle);
        }
    }
}

/// Fetch the audio for a job that was just leased, or explain why it is not worth having.
fn fetch<T: Transport>(
    transport: &mut T,
    worker: &str,
    job: u64,
    request: &SttRequest,
    now_ms: i64,
    metrics: &mut Metrics,
) -> Result<Vec<u8>, Outcome> {
    match &request.audio {
        AudioSource::Inline(bytes, _) => {
            // The bytes were in the take reply: they crossed the relay once, and they are counted.
            metrics.bytes_moved += bytes.len() as u64;
            Ok(bytes.clone())
        }
        AudioSource::Fetch(handle) => {
            if handle.is_expired(now_ms) {
                // The producer already considers this audio gone; nothing to fetch and nothing to
                // post. Told, not silently dropped.
                let _ = transport.fail(job, worker, "audio handle expired");
                metrics.stale_dropped += 1;
                return Err(Outcome::Stale { job });
            }
            match transport.fetch_audio(job, worker, &handle.handle) {
                Ok(bytes) => {
                    if bytes.len() as u64 != handle.bytes {
                        // A short or long body is a protocol failure, not a transcript: refuse to
                        // decode bytes whose length the producer did not promise.
                        let reason = "audio size mismatch".to_string();
                        let _ = transport.fail(job, worker, &reason);
                        return Err(Outcome::Failed { job, reason, retryable: true });
                    }
                    metrics.bytes_moved += bytes.len() as u64;
                    Ok(bytes)
                }
                Err(WireError::Refused(refusal)) => {
                    if matches!(refusal, Refusal::NotFound | Refusal::StaleJob) {
                        metrics.stale_dropped += 1;
                        Err(Outcome::Stale { job })
                    } else {
                        Err(Outcome::Failed { job, reason: refusal.as_str(), retryable: true })
                    }
                }
                Err(WireError::Unreachable(_)) => {
                    metrics.remote_lost_mid_job += 1;
                    Err(Outcome::Lost { job })
                }
            }
        }
    }
}

/// What one poll did. The variants are the words a log line and a test use.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Nothing to do at this instant.
    Empty,
    /// The queue is at its concurrency limit.
    Busy(u32),
    Decoded { job: u64, by: Who, took_ms: i64, segments: u32, bytes: u64 },
    /// Dropped for freshness: never decoded, never posted.
    Stale { job: u64 },
    /// The local worker held back: a preferred remote has the first claim until `until_ms`.
    Deferred { until_ms: i64 },
    /// The lease was lost (or the call failed) mid-job; the job will be taken again.
    Lost { job: u64 },
    Failed { job: u64, reason: String, retryable: bool },
    /// The producer refused the call before any job was handed out.
    Refused { reason: String },
    /// The producer could not be reached at all.
    Unreachable { reason: String },
}

impl Outcome {
    /// The fixed word the job log line uses.
    pub fn word(&self) -> &'static str {
        match self {
            Outcome::Empty => "empty",
            Outcome::Busy(_) => "busy",
            Outcome::Decoded { .. } => "done",
            Outcome::Stale { .. } => "stale",
            Outcome::Deferred { .. } => "deferred",
            Outcome::Lost { .. } => "lease_lost",
            Outcome::Failed { .. } => "failed",
            Outcome::Refused { .. } => "refused",
            Outcome::Unreachable { .. } => "unreachable",
        }
    }

    pub fn job(&self) -> Option<u64> {
        match self {
            Outcome::Decoded { job, .. }
            | Outcome::Stale { job }
            | Outcome::Lost { job }
            | Outcome::Failed { job, .. } => Some(*job),
            _ => None,
        }
    }

    /// The job line for the service log, when this outcome belongs to a job. `by` is the worker that
    /// produced the outcome: the variant alone cannot say whether a `stale` came from the local
    /// worker or a remote one.
    pub fn trace(&self, by: Who) -> Option<JobTrace> {
        match self {
            Outcome::Decoded { job, took_ms, segments, bytes, .. } => {
                Some(JobTrace { job: *job, by, outcome: "done", took_ms: *took_ms, segments: *segments, bytes: *bytes })
            }
            Outcome::Stale { job } => Some(JobTrace { job: *job, by, outcome: "stale", took_ms: 0, segments: 0, bytes: 0 }),
            Outcome::Lost { job } => Some(JobTrace { job: *job, by, outcome: "lease_lost", took_ms: 0, segments: 0, bytes: 0 }),
            Outcome::Failed { job, .. } => Some(JobTrace { job: *job, by, outcome: "failed", took_ms: 0, segments: 0, bytes: 0 }),
            _ => None,
        }
    }
}

/// The half both workers share: from "I hold this job" to "settled, refused, stale or lost".
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Decoder {
    pub worker: String,
    pub lease_ms: i64,
    pub heartbeat_every_ms: i64,
    pub by: Who,
}

impl Decoder {
    // Eight parameters, all of them a decision this function makes: the sink, the recognizer, the
    // job, its request, its audio, the clock that times it, and the counters. Bundling them into a
    // struct would move the same list to the caller without removing one.
    #[allow(clippy::too_many_arguments)]
    pub fn decode<S: JobSink, R: Recognizer + ?Sized>(
        &self,
        sink: &mut S,
        recognizer: &mut R,
        job: u64,
        request: &SttRequest,
        audio: Vec<u8>,
        clock: &dyn Clock,
        metrics: &mut Metrics,
    ) -> Outcome {
        let mut audio = audio;
        let bytes = audio.len() as u64;
        let started = clock.now_ms();
        let mime = request.audio.mime();

        // Freshness, first check: a job that was already stale when it was handed out is never
        // decoded. The queue's own `take` normally drops these; this is the belt for a job that went
        // stale between the producer's `take` and this worker's clock.
        if !request.is_fresh(started) {
            erase(&mut audio);
            let _ = sink.fail(job, &self.worker, "fresh_until passed before decode");
            metrics.stale_dropped += 1;
            return Outcome::Stale { job };
        }

        let mut segments = 0u32;
        let mut last_beat = started;
        let mut beat_until = started + self.lease_ms;
        let mut lost: Option<WireError> = None;
        let outcome = {
            let mut on_segment = |segment: Segment| {
                if !segment.has_text() || lost.is_some() {
                    return;
                }
                let now = clock.now_ms();
                // A lease is the only thing standing between this worker and a second decode of the
                // same audio, so it is extended before the segment is published, not after.
                if now >= beat_until || now - last_beat >= self.heartbeat_every_ms {
                    match sink.heartbeat(job, &self.worker) {
                        Ok(until) => {
                            last_beat = now;
                            beat_until = until;
                        }
                        Err(error) => {
                            lost = Some(error);
                            return;
                        }
                    }
                }
                if let Err(error) = sink.progress(job, &self.worker, &segment) {
                    lost = Some(error);
                    return;
                }
                segments += 1;
                metrics.segments += 1;
            };
            recognizer.recognize(&audio, mime, &request.language, &mut on_segment)
        };

        if lost.is_some() {
            // The decode is not interruptible (the recognizer owns the worker pipe), so it is
            // allowed to finish and its result is thrown away. The job is not settled: the lease
            // lapses on the producer and the next worker — the local one — takes it.
            erase(&mut audio);
            metrics.remote_lost_mid_job += u64::from(self.by == Who::Remote);
            return Outcome::Lost { job };
        }

        let finished = clock.now_ms();
        let took_ms = (finished - started).max(0);
        let transcript = match outcome {
            Ok(transcript) => transcript,
            Err(error) => {
                erase(&mut audio);
                let reason = error.reason();
                let retryable = error.retryable();
                // One settle, with the class in the reason (`unsupported:` / `environment:` /
                // `decode:`): a permanent condition and a decode failure take the same road back to
                // the queue, and only the producer's retry policy reads the difference. Nothing is
                // posted either way.
                let _ = sink.fail(job, &self.worker, &reason);
                return Outcome::Failed { job, reason, retryable };
            }
        };

        // Freshness, second check: a transcript finished after the window is dropped, not posted
        // late (`docs/WHATSAPP-TRANSCRIPTION.md`, "Fresh-only transcripts").
        if !request.is_fresh(finished) {
            erase(&mut audio);
            let _ = sink.fail(job, &self.worker, "fresh_until passed before the result");
            metrics.stale_dropped += 1;
            return Outcome::Stale { job };
        }

        match sink.done(job, &self.worker, &transcript) {
            Ok(()) => {
                erase(&mut audio);
                let handle = match &request.audio {
                    AudioSource::Fetch(handle) => Some(handle.handle.clone()),
                    AudioSource::Inline(..) => None,
                };
                sink.discard_audio(job, handle.as_deref());
                metrics.bytes_deleted += bytes;
                metrics.record_decode(self.by, took_ms);
                Outcome::Decoded { job, by: self.by, took_ms, segments, bytes }
            }
            Err(WireError::Refused(Refusal::LeaseLost)) => {
                // Another worker settled it first (a lease that lapsed under a slow decode). Nothing
                // to post and nothing to recover: the job is already somebody's result.
                erase(&mut audio);
                metrics.remote_lost_mid_job += u64::from(self.by == Who::Remote);
                Outcome::Lost { job }
            }
            Err(WireError::Unreachable(_)) => {
                erase(&mut audio);
                metrics.remote_lost_mid_job += u64::from(self.by == Who::Remote);
                Outcome::Lost { job }
            }
            Err(WireError::Refused(refusal)) => {
                erase(&mut audio);
                Outcome::Failed { job, reason: refusal.as_str(), retryable: refusal == Refusal::LeaseLost }
            }
        }
    }
}

/// Best-effort erasure of the audio buffer before it is dropped. Not a cryptographic guarantee (a
/// copy may exist in the allocation that held it, or in the recognizer), but the buffer this worker
/// owns does not keep the owner's audio around after the job is settled.
fn erase(audio: &mut Vec<u8>) {
    audio.iter_mut().for_each(|byte| *byte = 0);
    audio.clear();
}

/// The relay as the worker sees it: five operations. Every method is one signed call to the
/// producing node (`protocol::Envelope`); a `Transport` implementation supplies the signing and the
/// POST (`lua/core/nodes.lua#request` on the node, `sim::Relay` in the tests).
pub trait Transport {
    fn take(&mut self, body: &TakeBody) -> Result<TakeReply, WireError>;
    fn fetch_audio(&mut self, job: u64, worker: &str, handle: &str) -> Result<Vec<u8>, WireError>;
    fn heartbeat(&mut self, job: u64, worker: &str, extend_ms: i64) -> Result<i64, WireError>;
    fn progress(&mut self, job: u64, worker: &str, segment: &Segment) -> Result<(), WireError>;
    fn done(&mut self, job: u64, worker: &str, transcript: &Transcript) -> Result<(), WireError>;
    fn fail(&mut self, job: u64, worker: &str, reason: &str) -> Result<(), WireError>;
    fn discard_audio(&mut self, job: u64, worker: &str, handle: &str);
}
