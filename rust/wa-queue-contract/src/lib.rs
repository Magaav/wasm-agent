//! The queue's contract: what a caller may ask, what it is told, and the words both use.
//!
//! This crate owns the vocabulary of a `wa:queue` call - the request and its policy defaults, the job
//! and its states, the errors and their spellings, the alert and stats shapes. It links nothing: no
//! wasmtime, no Kv, no clock, so it can be the single owner for the library (`wa-queue` re-exports
//! every name here), for the component that serves the same words to a guest, and for any consumer
//! that only needs to speak the vocabulary.
//!
//! What is NOT here, deliberately: the state machine. Transitions, leases, dedupe claims and the
//! journal live in `wa-queue`, which keeps its own rule that the queue needs only bytes in a Kv and a
//! clock.

use std::{collections::BTreeMap, fmt};

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
    /// True when the dedupe key is claimed only while the job is live: the claim is released the moment
    /// the job settles (done, dead, expired). A question that answers "the state now" uses this, so a
    /// settled answer is never handed to a later caller as though it were an answer to *his* question.
    pub dedupe_in_flight: bool,
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
    /// Release the dedupe claim when the job settles, instead of holding it until the record is reaped
    /// (Policy::done_retention_ms, an hour). In-flight-only is what a query wants: the claim stops a
    /// second scan while the first is running, and a settled answer is never replayed to a caller who
    /// asked later. A send keeps the long-lived claim, because a repeated send must not go out twice.
    pub dedupe_in_flight: bool,
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
            dedupe_in_flight: false,
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

    /// Claim the dedupe key only while this job is live (see Job::dedupe_in_flight).
    pub fn dedupe_in_flight(mut self) -> Self {
        self.dedupe_in_flight = true;
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

    pub fn code(self) -> u8 {
        match self {
            AlertKind::Expired => b'e',
            AlertKind::TimedOut => b't',
            AlertKind::Dead => b'f',
        }
    }

    pub fn from_code(code: u8) -> Result<Self> {
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
