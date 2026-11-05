//! `wa-queue` — one durable queue for every stream of work a component hands to a worker.
//!
//! The same shape is needed by the WhatsApp channel (audio to transcribe, transcripts to post),
//! OCR, and agent sub-tasks: *enqueue a job, let a worker lease it, never run work that has gone
//! stale, retry with backoff, dead-letter what keeps failing, and tell the operator once — not once
//! per item — when something did not finish in time.* Today each of those re-implements it; this
//! crate is the one implementation.
//!
//! Properties, and how they are kept:
//!
//! - **Durable.** All state lives in a [`Kv`]: job records (`j\0<id>`), an ordered ready/leased
//!   index (`i\0<queue>\0<state><priority><id>`), dedupe keys (`d\0<queue>\0<key>`), append-only
//!   progress entries (`p\0<id>\0<seq>`) and alert records (`a\0<id>\0<kind>`). There is no
//!   in-process state at all, so a restart is a new [`Queue`] over the same bytes.
//! - **Fresh-only.** A job past `fresh_until` is dropped *without running* and recorded (state
//!   [`JobState::Expired`] plus an alert). [`Queue::take`] enforces this by itself, so a sweeper
//!   that never ran cannot cause old work to be executed; [`Queue::expire_stale`] is the bulk sweep,
//!   not the safety net.
//! - **Leased.** [`Queue::take`] hands out a visibility lease; [`Queue::heartbeat`] extends it;
//!   [`Queue::done`] and [`Queue::fail`] settle it. A lease that stops being extended while the
//!   process is gone expires on a later call and the job becomes takeable again — no lease table
//!   survives a crash by being trusted.
//! - **Deterministic.** Every deadline comes from an injected [`Clock`]. No random jitter, no
//!   `Instant::now()`: the same operations at the same times produce the same state.
//! - **Bounded.** Priority order, FIFO within a priority, a per-queue concurrency limit and a
//!   per-queue readiness cap; alerts are rate limited, batched and expire.
//!
//! Deliberate non-goals: no wasmtime, no threads, no I/O, no cross-process locking. It is a library
//! over [`Kv`]; the host owns the namespace, and one writer per namespace is assumed (the kernel's
//! `kv` grant is per component, which is exactly one writer).
//!
//! ```no_run
//! use std::sync::Arc;
//! use wa_queue::{Clock, EnqueueRequest, Kv, MemoryKv, Policy, Queue, SystemClock, TakeOutcome};
//!
//! let kv = Arc::new(MemoryKv::new());
//! let clock = Arc::new(SystemClock);
//! let queue = Queue::new(kv, clock, Policy::default());
//! let enqueued = queue.enqueue(EnqueueRequest::new("stt", b"audio".to_vec()))?;
//! if let TakeOutcome::Job(job) = queue.take("stt", "worker-1", None)? {
//!     queue.heartbeat(job.id, "worker-1", None)?;
//!     queue.done(job.id, b"transcript")?;
//! }
//! # Ok::<(), wa_queue::QueueError>(())
//! ```
//!
//! Design and the WhatsApp mapping: `docs/QUEUE.md`. The WIT draft: `wit/queue/queue.wit`.

mod clock;
mod codec;
mod kv;
mod queue;

#[cfg(test)]
mod tests;

pub use clock::{Clock, FixedClock, SystemClock};
pub use kv::{Entries, Kv, KvError, MemoryKv, Prefixed};
pub use queue::Queue;

use std::{collections::BTreeMap, fmt};

/// Anything the queue can refuse. A refusal says what was wrong, never what the payload said.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QueueError {
    /// Storage failed. Never swallowed: a failed write is not a queued job.
    Kv(String),
    /// The request is not a job the queue can represent (bad queue name, oversized payload, …).
    Invalid(String),
    /// No such job id.
    NotFound,
    /// The caller does not hold this job's lease any more (expired, or settled by another worker).
    LeaseLost,
    /// A settle or progress write would exceed the configured bound.
    TooLarge(String),
    /// The job already has the maximum number of progress entries.
    ProgressFull,
    /// The queue is at its readiness cap; the producer must back off.
    Full {
        queue: String,
        ready: usize,
        limit: usize,
    },
    /// A stored record could not be decoded. Reported, never guessed at.
    Corrupt(String),
}

impl fmt::Display for QueueError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            QueueError::Kv(why) => write!(f, "kv failure: {why}"),
            QueueError::Invalid(why) => write!(f, "invalid request: {why}"),
            QueueError::NotFound => write!(f, "job not found"),
            QueueError::LeaseLost => write!(f, "lease lost"),
            QueueError::TooLarge(why) => write!(f, "too large: {why}"),
            QueueError::ProgressFull => write!(f, "progress limit reached"),
            QueueError::Full {
                queue,
                ready,
                limit,
            } => {
                write!(f, "queue {queue} is full ({ready}/{limit} ready)")
            }
            QueueError::Corrupt(why) => write!(f, "corrupt record: {why}"),
        }
    }
}

impl std::error::Error for QueueError {}

impl From<KvError> for QueueError {
    fn from(error: KvError) -> Self {
        QueueError::Kv(error.0)
    }
}

pub type Result<T> = std::result::Result<T, QueueError>;

/// A job id: monotonic, allocated from the namespace's counter, never reused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct JobId(pub u64);

impl fmt::Display for JobId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "job-{}", self.0)
    }
}

/// Where a job is. `Ready` includes a retry waiting for its backoff (`not_before`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobState {
    Ready,
    Leased,
    Done,
    Dead,
    Expired,
}

impl JobState {
    pub fn as_str(self) -> &'static str {
        match self {
            JobState::Ready => "ready",
            JobState::Leased => "leased",
            JobState::Done => "done",
            JobState::Dead => "dead",
            JobState::Expired => "expired",
        }
    }

    pub fn is_terminal(self) -> bool {
        matches!(self, JobState::Done | JobState::Dead | JobState::Expired)
    }
}

/// A job as the queue stores it. The payload is opaque bytes: the queue never looks inside.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Job {
    pub id: JobId,
    pub queue: String,
    pub payload: Vec<u8>,
    /// Higher runs first. FIFO inside one priority.
    pub priority: u32,
    /// Earliest instant the job may be taken (retry backoff or an explicit delay).
    pub not_before: i64,
    /// Last instant this job is worth running at all; `None` = no freshness bound.
    pub fresh_until: Option<i64>,
    /// When the operator should be told this job has not finished.
    pub deadline: Option<i64>,
    pub max_attempts: u32,
    pub attempts: u32,
    /// How often a lease was lost (crash, worker gone). Separate from `attempts` so a node restart
    /// does not spend the retry budget of jobs that never actually failed.
    pub lease_expiries: u32,
    pub dedupe_key: Option<String>,
    pub state: JobState,
    pub lease_worker: Option<String>,
    pub lease_until: Option<i64>,
    /// Last failure reason, sanitized (single line, truncated). Never a payload.
    pub last_error: Option<String>,
    /// The settled result, if [`Queue::done`] was given one.
    pub result: Option<Vec<u8>>,
    pub progress_entries: u32,
    pub progress_bytes: u64,
    pub created_at: i64,
    pub updated_at: i64,
}

impl Job {
    /// True while the job is out with a worker.
    pub fn is_leased(&self) -> bool {
        self.state == JobState::Leased
    }
}

/// One enqueue. Everything but `queue`/`payload` has a policy default.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnqueueRequest {
    pub queue: String,
    pub payload: Vec<u8>,
    /// Default 0.
    pub priority: u32,
    /// Absolute earliest take time; combined with `Policy::default_fresh_ms` it is never later than
    /// `fresh_until` (a job that may not start before it expires is enqueued already stale — that
    /// is refused rather than stored to be dropped).
    pub not_before: Option<i64>,
    /// Freshness window from now. `None` uses `Policy::default_fresh_ms`.
    pub fresh_for_ms: Option<i64>,
    /// `None` uses `Policy::max_attempts`.
    pub max_attempts: Option<u32>,
    /// Producer-side idempotency key, unique inside the queue. `None` = no dedupe.
    pub dedupe_key: Option<String>,
    /// Window from now after which a still-unfinished job raises a timeout alert. `None` uses
    /// `Policy::default_deadline_ms`.
    pub deadline_in_ms: Option<i64>,
}

impl EnqueueRequest {
    pub fn new(queue: impl Into<String>, payload: impl Into<Vec<u8>>) -> Self {
        Self {
            queue: queue.into(),
            payload: payload.into(),
            priority: 0,
            not_before: None,
            fresh_for_ms: None,
            max_attempts: None,
            dedupe_key: None,
            deadline_in_ms: None,
        }
    }

    pub fn priority(mut self, priority: u32) -> Self {
        self.priority = priority;
        self
    }

    pub fn not_before(mut self, at_ms: i64) -> Self {
        self.not_before = Some(at_ms);
        self
    }

    pub fn fresh_for(mut self, ms: i64) -> Self {
        self.fresh_for_ms = Some(ms);
        self
    }

    pub fn max_attempts(mut self, attempts: u32) -> Self {
        self.max_attempts = Some(attempts);
        self
    }

    pub fn dedupe(mut self, key: impl Into<String>) -> Self {
        self.dedupe_key = Some(key.into());
        self
    }

    pub fn deadline_in(mut self, ms: i64) -> Self {
        self.deadline_in_ms = Some(ms);
        self
    }
}

/// What an enqueue did. `dedupe_hit` means the key already named a live job and nothing was added.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EnqueueOutcome {
    pub id: JobId,
    pub dedupe_hit: bool,
}

/// What [`Queue::take`] found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TakeOutcome {
    Job(Box<Job>),
    /// The queue's concurrency limit is reached; the caller should try later.
    AtLimit {
        leased: usize,
        limit: usize,
    },
    /// Nothing due. A job with a future `not_before` does not hide a due one behind it.
    Empty,
}

impl TakeOutcome {
    pub fn job(self) -> Option<Job> {
        match self {
            TakeOutcome::Job(job) => Some(*job),
            _ => None,
        }
    }
}

/// What [`Queue::fail`] decided.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FailOutcome {
    pub state: JobState,
    pub attempts: u32,
    /// Set when the job went back to `Ready` after a backoff.
    pub not_before: Option<i64>,
    pub dead: bool,
}

/// One append-only progress chunk (`seq` starts at 0 for the first chunk).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProgressEntry {
    pub seq: u64,
    pub bytes: Vec<u8>,
}

/// Bulk result of [`Queue::expire_stale`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExpireOutcome {
    pub expired: Vec<JobId>,
}

/// What one [`Queue::sweep`] did. A sweep is safe to call as often as the host likes.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SweepOutcome {
    /// Leases that expired and went back to `Ready`.
    pub leases_recovered: usize,
    /// Jobs dropped by the freshness rule (never run).
    pub expired: usize,
    /// Jobs that got their first timeout alert in this sweep.
    pub timed_out: usize,
    /// Terminal records retired by retention.
    pub reaped: usize,
}

impl SweepOutcome {
    pub fn did_something(&self) -> bool {
        self.leases_recovered + self.expired + self.timed_out + self.reaped > 0
    }
}

/// Why an alert exists. Never carries a payload, only a queue, an id and a reason.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlertKind {
    /// Dropped past `fresh_until` without ever running.
    Expired,
    /// Not finished by its deadline.
    TimedOut,
    /// Dead-lettered after its attempts were spent.
    Dead,
}

impl AlertKind {
    pub fn as_str(self) -> &'static str {
        match self {
            AlertKind::Expired => "expired",
            AlertKind::TimedOut => "timed_out",
            AlertKind::Dead => "dead",
        }
    }

    pub(crate) fn code(self) -> u8 {
        match self {
            AlertKind::Expired => b'e',
            AlertKind::TimedOut => b't',
            AlertKind::Dead => b'f',
        }
    }

    pub(crate) fn from_code(code: u8) -> Result<Self> {
        match code {
            b'e' => Ok(AlertKind::Expired),
            b't' => Ok(AlertKind::TimedOut),
            b'f' => Ok(AlertKind::Dead),
            other => Err(QueueError::Corrupt(format!("bad alert kind {other}"))),
        }
    }
}

/// Delivery state of one alert record.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlertState {
    /// Waiting for the next batch.
    Ready,
    /// Handed to the operator by [`Queue::next_alerts`].
    Sent,
    /// Older than the alert policy allows; dropped, and counted once.
    Dropped,
}

impl AlertState {
    pub fn as_str(self) -> &'static str {
        match self {
            AlertState::Ready => "ready",
            AlertState::Sent => "sent",
            AlertState::Dropped => "dropped",
        }
    }
}

/// One recorded alert.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Alert {
    pub seq: u64,
    pub job: JobId,
    pub queue: String,
    pub kind: AlertKind,
    pub reason: String,
    pub at: i64,
    pub state: AlertState,
}

/// A rate-limited batch of alerts, ready to be formatted into one message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlertBatch {
    pub items: Vec<Alert>,
    /// Ready alerts that did not fit in this batch (kept for the next one, never discarded).
    pub overflow: usize,
    /// Alerts dropped in this call because they were older than `AlertPolicy::max_age_ms`.
    pub dropped: usize,
}

/// Counters for one queue, computed from the job records (no separate counter can drift).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct QueueStats {
    pub ready: usize,
    /// Ready but still inside a backoff window.
    pub retrying: usize,
    pub leased: usize,
    pub done: usize,
    pub dead: usize,
    pub expired: usize,
    /// Age of the oldest ready job, 0 when there is none.
    pub oldest_ready_age_ms: i64,
    pub progress_bytes: u64,
}

impl QueueStats {
    pub fn active(&self) -> usize {
        self.ready + self.leased
    }
}

/// What [`Queue::repair`] corrected. The job records are the truth; index and dedupe entries are
/// derived, and a crash between two writes can leave them out of step.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RepairOutcome {
    pub index_added: usize,
    pub index_removed: usize,
    pub dedupe_added: usize,
    pub dedupe_removed: usize,
}

impl RepairOutcome {
    pub fn changed(&self) -> usize {
        self.index_added + self.index_removed + self.dedupe_added + self.dedupe_removed
    }
}

/// Exponential retry: `base * 2^(attempts-1)`, capped. Deterministic (no jitter) because the clock
/// is injected and a test must be able to say exactly when the next attempt is due.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RetryPolicy {
    pub base_ms: i64,
    pub max_ms: i64,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            base_ms: 5_000,
            max_ms: 3_600_000,
        }
    }
}

impl RetryPolicy {
    /// Delay after the `failures`-th failure (1-based). `0` failures = no delay.
    pub fn delay_ms(&self, failures: u32) -> i64 {
        if failures == 0 {
            return 0;
        }
        let mut delay = self.base_ms.max(0);
        for _ in 1..failures {
            if delay >= self.max_ms {
                break;
            }
            delay = delay.saturating_mul(2);
        }
        delay.min(self.max_ms)
    }
}

/// Alert delivery policy, mirroring the WhatsApp log: one batched message at most every
/// `min_gap_ms`, at most `batch_max` items in it, and an alert nobody could deliver for
/// `max_age_ms` is dropped (and counted).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AlertPolicy {
    pub min_gap_ms: i64,
    pub batch_max: usize,
    pub max_age_ms: i64,
}

impl Default for AlertPolicy {
    fn default() -> Self {
        Self {
            min_gap_ms: 60_000,
            batch_max: 12,
            max_age_ms: 6 * 3_600_000,
        }
    }
}

/// Everything tunable. `Policy::default()` is a generic queue with no freshness or timeout bound:
/// both are per-job or per-host decisions, never a library guess.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Policy {
    /// Default visibility lease.
    pub lease_ms: i64,
    /// Upper bound a heartbeat may extend a lease to (`now + lease_extend_ms_max`).
    pub max_lease_ms: i64,
    pub retry: RetryPolicy,
    pub max_attempts: u32,
    /// Lease losses are counted apart from attempts, but a job that crashes its worker forever must
    /// still stop: after `max_lease_losses` losses it is dead-lettered with reason `lease_lost`.
    pub max_lease_losses: u32,
    /// Default per-queue in-flight limit.
    pub concurrency: usize,
    /// Per-queue overrides of `concurrency`.
    pub queue_limits: BTreeMap<String, usize>,
    /// Freshness applied when a request names none. `None` = jobs never go stale.
    pub default_fresh_ms: Option<i64>,
    /// Timeout window applied when a request names none. `None` = no timeout alerts.
    pub default_deadline_ms: Option<i64>,
    pub alerts: AlertPolicy,
    pub max_payload_bytes: usize,
    pub max_result_bytes: usize,
    pub max_progress_entries: u32,
    pub max_progress_bytes: u64,
    /// Readiness cap per queue (backpressure, not a crash).
    pub max_ready: usize,
    pub done_retention_ms: i64,
    pub dead_retention_ms: i64,
    pub expired_retention_ms: i64,
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            lease_ms: 60_000,
            max_lease_ms: 3_600_000,
            retry: RetryPolicy::default(),
            max_attempts: 5,
            max_lease_losses: 3,
            concurrency: 4,
            queue_limits: BTreeMap::new(),
            default_fresh_ms: None,
            default_deadline_ms: None,
            alerts: AlertPolicy::default(),
            max_payload_bytes: 1024 * 1024,
            max_result_bytes: 64 * 1024,
            max_progress_entries: 1024,
            max_progress_bytes: 1024 * 1024,
            max_ready: 4096,
            done_retention_ms: 3_600_000,
            dead_retention_ms: 7 * 24 * 3_600_000,
            expired_retention_ms: 24 * 3_600_000,
        }
    }
}

impl Policy {
    pub fn with_fresh_ms(mut self, ms: i64) -> Self {
        self.default_fresh_ms = Some(ms);
        self
    }

    pub fn with_deadline_ms(mut self, ms: i64) -> Self {
        self.default_deadline_ms = Some(ms);
        self
    }

    pub fn with_concurrency(mut self, queue: impl Into<String>, limit: usize) -> Self {
        self.queue_limits.insert(queue.into(), limit);
        self
    }

    pub fn limit_for(&self, queue: &str) -> usize {
        self.queue_limits
            .get(queue)
            .copied()
            .unwrap_or(self.concurrency)
            .max(1)
    }
}

/// How [`Queue::requeue`] revives a dead-lettered job. Freshness is kept by default, because the
/// rule "never run work that has gone stale" must not be bypassed by an admin action: refreshing it
/// is an explicit decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RequeueOptions {
    pub refresh_fresh: bool,
    pub max_attempts: Option<u32>,
    pub attempts_reset: bool,
}

impl Default for RequeueOptions {
    fn default() -> Self {
        Self {
            refresh_fresh: false,
            max_attempts: None,
            attempts_reset: true,
        }
    }
}

impl RequeueOptions {
    pub fn refreshing_fresh() -> Self {
        Self {
            refresh_fresh: true,
            ..Self::default()
        }
    }
}
