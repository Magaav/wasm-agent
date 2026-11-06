//! Counters for what the remote half actually did, and the two log lines worth writing.
//!
//! Nothing here can carry message text: every field is a count, a duration or an id, and the lines
//! are built from `u64`s. That is the whole privacy rule of this feature — `docs/QUEUE.md`
//! ("what is deliberately not logged"). The test that plants a canary in a transcript and asserts it
//! cannot reach a line is `tests::metrics_never_carry_text`.

use std::fmt;

/// Who did a job. Two workers, one queue; the metrics are what tells them apart.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Who {
    /// A `stt_worker` node on the relay (the strong one).
    Remote,
    /// This node's own warm recognizer (the fallback).
    Local,
}

impl Who {
    pub fn as_str(self) -> &'static str {
        match self {
            Who::Remote => "remote",
            Who::Local => "local",
        }
    }
}

/// Everything the node needs to tell a person what happened without telling them what was said.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Metrics {
    /// Requests enqueued on `stt.requests`.
    pub enqueued: u64,
    /// Jobs decoded by a remote node / by this node.
    pub remote_decoded: u64,
    pub local_decoded: u64,
    /// Local worker held back because a remote was preferred and expected.
    pub waited_for_remote: u64,
    /// The grace expired and the local worker took the job itself.
    pub fallback_taken: u64,
    /// The remote was not online (or was measured slower), so the local worker took it at once.
    pub local_immediate: u64,
    /// Jobs dropped for freshness: never decoded, never posted.
    pub stale_dropped: u64,
    /// A remote worker's call failed mid-job, so it abandoned the lease.
    pub remote_lost_mid_job: u64,
    /// A lease was recovered (the queue's own `lease_expiries` count, summed).
    pub lease_recovered: u64,
    /// Segment progress entries streamed back by remote workers.
    pub segments: u64,
    /// Audio bytes that crossed the relay (inline payload bytes plus fetched bytes).
    pub bytes_moved: u64,
    /// Audio bytes dropped after the job settled (deleted, not retained).
    pub bytes_deleted: u64,
    /// Calls refused at admission, by reason.
    pub refused_unknown_caller: u64,
    pub refused_replayed: u64,
    pub refused_stale_call: u64,
    pub refused_bad_signature: u64,
    /// Results settled once (the queue refuses a second settle; this counts the firsts).
    pub results: u64,
    /// Summed decode milliseconds per side, so an average can be printed without a float.
    pub remote_ms_total: u64,
    pub local_ms_total: u64,
}

impl Metrics {
    pub fn new() -> Metrics {
        Metrics::default()
    }

    pub fn record_refusal(&mut self, refusal: &crate::protocol::Refusal) {
        use crate::protocol::Refusal as R;
        match refusal {
            R::UnknownCaller => self.refused_unknown_caller += 1,
            R::Replayed => self.refused_replayed += 1,
            R::Stale => self.refused_stale_call += 1,
            R::BadSignature => self.refused_bad_signature += 1,
            _ => {}
        }
    }

    pub fn record_decode(&mut self, who: Who, took_ms: i64) {
        match who {
            Who::Remote => {
                self.remote_decoded += 1;
                self.remote_ms_total += took_ms.max(0) as u64;
            }
            Who::Local => {
                self.local_decoded += 1;
                self.local_ms_total += took_ms.max(0) as u64;
            }
        }
        self.results += 1;
    }

    /// Average decode time for one side, or `None` when that side has not decoded anything (an
    /// average over zero jobs is not zero, it is unknown).
    pub fn average_ms(&self, who: Who) -> Option<u64> {
        let (total, count) = match who {
            Who::Remote => (self.remote_ms_total, self.remote_decoded),
            Who::Local => (self.local_ms_total, self.local_decoded),
        };
        (count > 0).then(|| total / count)
    }

    /// One line for the service log: counters only, no ids (they are on [`JobTrace`]).
    pub fn line(&self) -> String {
        format!(
            "stt-remote v=1 enqueued={} remote={} local={} waited={} fallback={} immediate={} stale={} lost={} recovered={} segments={} moved_bytes={} deleted_bytes={} refused_unknown={} refused_replay={} refused_stale={} refused_sig={} remote_avg_ms={} local_avg_ms={}",
            self.enqueued,
            self.remote_decoded,
            self.local_decoded,
            self.waited_for_remote,
            self.fallback_taken,
            self.local_immediate,
            self.stale_dropped,
            self.remote_lost_mid_job,
            self.lease_recovered,
            self.segments,
            self.bytes_moved,
            self.bytes_deleted,
            self.refused_unknown_caller,
            self.refused_replayed,
            self.refused_stale_call,
            self.refused_bad_signature,
            self.average_ms(Who::Remote).map(|ms| ms.to_string()).unwrap_or_else(|| "-".into()),
            self.average_ms(Who::Local).map(|ms| ms.to_string()).unwrap_or_else(|| "-".into()),
        )
    }
}

/// One job's line: the id, who decoded it, how long it took, how many segments, how many bytes. The
/// `wa-transcript` comparison log of the component keeps the same rule (`docs/WHATSAPP-TRANSCRIPTION.md`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JobTrace {
    pub job: u64,
    pub by: Who,
    /// `done`, `stale`, `lease_lost`, `failed` — a fixed word, never a message.
    pub outcome: &'static str,
    pub took_ms: i64,
    pub segments: u32,
    pub bytes: u64,
}

impl JobTrace {
    pub fn line(&self) -> String {
        format!(
            "stt-job v=1 job={} by={} outcome={} took_ms={} segments={} bytes={}",
            self.job,
            self.by.as_str(),
            self.outcome,
            self.took_ms,
            self.segments,
            self.bytes,
        )
    }
}

impl fmt::Display for Metrics {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.line())
    }
}
