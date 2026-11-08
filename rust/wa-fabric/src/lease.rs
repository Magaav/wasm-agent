//! The lease, which is `wa-queue`'s lease: the fabric routes work onto a queue, it does not invent a
//! second notion of "who owns this job".
//!
//! An accepted offer means "I will take it", never "it is mine": the worker then takes the job from
//! the queue, and from that instant the lease — heartbeat, expiry, requeue — is exactly what
//! `docs/QUEUE.md` already guarantees. Three consequences, and they are the reason this module is
//! thin:
//!
//! * **A killed node costs one lease.** Its heartbeats stop, `Queue::take`'s own recovery (or the
//!   producer's `sweep`) puts the job back to `Ready`, and the next worker — another peer or this
//!   node — takes it. Nothing has to be announced, and no lease table has to be trusted.
//! * **Exactly once.** The queue refuses a settle from a worker that no longer holds the lease
//!   (`done_by` → `LeaseLost`), so a node that wakes up after being declared dead cannot post a
//!   second result.
//! * **No payload in the fabric.** The queue holds the bytes; the offer, the accept and the admin
//!   view only ever carry the job id.
//!
//! One queue per job kind (`fabric.stt`, `fabric.ocr`, …) so a queue's concurrency limit and freshness
//! rule can differ per kind, and a job kind is pluggable without touching this file.

use wa_queue::{JobId, JobState, Queue, QueueError, TakeOutcome};

use crate::presence::NodeId;

/// The prefix of every queue the fabric places work on. A node's own queues (`stt.requests`, …) are
/// untouched: the fabric queue is the one it routes, and a kind maps to one queue.
pub const QUEUE_PREFIX: &str = "fabric.";

/// The queue name for a job kind. The kind is already a capability word (lower-case, bounded), so the
/// result always satisfies the queue's name rule.
pub fn queue_name(kind: &str) -> String {
    let kind: String = kind
        .trim()
        .to_ascii_lowercase()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        .take(48)
        .collect();
    format!("{QUEUE_PREFIX}{}", if kind.is_empty() { "job" } else { &kind })
}

/// The lease's worker identity: the node plus the instance generation, so a node that restarts is a
/// new worker (its old lease is nobody's) and two node-threads of one node are two identities. The
/// separator is `:`, the one the queue's worker-name alphabet allows.
pub fn worker_id(node: &NodeId, generation: u64) -> String {
    let raw = format!("{}:{}", node.as_str(), generation);
    raw.chars().take(100).collect()
}

/// A lease this node holds: the queue it is on, the job, and who holds it. Every operation names the
/// lease, so a stale handle cannot settle a job that has moved on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FabricLease {
    pub job: JobId,
    pub queue: String,
    pub worker: String,
    pub node: NodeId,
    pub lease_ms: i64,
    pub taken_at_ms: i64,
    /// When the lease lapses unless it is extended. From the queue's clock, so it is the queue's
    /// number and not an estimate.
    pub until_ms: i64,
}

/// Why a lease operation did not happen. `Lost` is the interesting one: the job is not ours any more,
/// so the caller must stop working on it rather than retry the settle.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LeaseError {
    /// The caller no longer holds this job's lease (expired, or taken by another worker).
    Lost,
    /// Nothing was due, or the queue was at its in-flight limit.
    NothingDue,
    /// The queue refused the operation; the reason is the queue's own word.
    Queue(String),
}

impl LeaseError {
    pub fn as_str(&self) -> &str {
        match self {
            LeaseError::Lost => "lease_lost",
            LeaseError::NothingDue => "nothing_due",
            LeaseError::Queue(word) => word,
        }
    }
}

impl From<QueueError> for LeaseError {
    fn from(error: QueueError) -> LeaseError {
        match error {
            QueueError::LeaseLost | QueueError::NotFound => LeaseError::Lost,
            other => LeaseError::Queue(other.to_string()),
        }
    }
}

impl FabricLease {
    /// Take the next due job of `queue` for `node`, or `None` when there is nothing to do. `lease_ms`
    /// is how long this node claims the job for before its heartbeats have to renew it.
    pub fn take(
        queue: &Queue,
        queue_name: &str,
        node: &NodeId,
        generation: u64,
        lease_ms: i64,
        now_ms: i64,
    ) -> Result<Option<FabricLease>, LeaseError> {
        let worker = worker_id(node, generation);
        match queue.take(queue_name, &worker, Some(lease_ms))? {
            TakeOutcome::Job(job) => Ok(Some(FabricLease {
                job: job.id,
                queue: queue_name.to_string(),
                worker,
                node: node.clone(),
                lease_ms,
                taken_at_ms: now_ms,
                until_ms: job.lease_until.unwrap_or(now_ms.saturating_add(lease_ms)),
            })),
            TakeOutcome::AtLimit { .. } | TakeOutcome::Empty => Ok(None),
        }
    }

    /// Extend the lease and return its new expiry. `Lost` means: stop, the job is somebody else's.
    pub fn heartbeat(&mut self, queue: &Queue) -> Result<i64, LeaseError> {
        let until = queue.heartbeat(self.job, &self.worker, Some(self.lease_ms))?;
        self.until_ms = until;
        Ok(until)
    }

    /// Append one progress chunk (a segment, a partial index): the queue's own progress log, which is
    /// what an admin reads to tell "running" from "stuck".
    pub fn progress(&self, queue: &Queue, chunk: &[u8]) -> Result<u64, LeaseError> {
        Ok(queue.progress(self.job, chunk)?)
    }

    /// Settle the job with its result. Fenced: a lease that lapsed and was taken by another worker
    /// makes this `Lost`, so the second result is never written.
    pub fn done(&self, queue: &Queue, result: &[u8]) -> Result<(), LeaseError> {
        queue.done_by(self.job, &self.worker, result).map(|_| ()).map_err(LeaseError::from)
    }

    /// Give the job up: retry with the queue's backoff, or dead-letter it once its attempts are spent.
    pub fn fail(&self, queue: &Queue, reason: &str) -> Result<wa_queue::FailOutcome, LeaseError> {
        queue.fail_by(self.job, &self.worker, reason).map_err(LeaseError::from)
    }

    /// Is this lease still ours, right now? Asked before starting work that cannot be undone.
    pub fn still_held(&self, queue: &Queue) -> bool {
        queue.job(self.job).ok().flatten().is_some_and(|job| {
            job.state == JobState::Leased && job.lease_worker.as_deref() == Some(self.worker.as_str())
        })
    }
}

/// One outstanding lease, for the admin view: a job id, who holds it and when it lapses. Never a
/// payload, never a result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LeaseView {
    pub job: u64,
    pub queue: String,
    pub worker: String,
    pub until_ms: i64,
    /// How long until it lapses (negative once it already has, before recovery runs).
    pub expires_in_ms: i64,
    pub attempts: u32,
    pub lease_expiries: u32,
}

/// The leases one queue is carrying right now, and how many of its jobs have ever lost one. The
/// numbers come from the job records, so they cannot drift from the truth (`Queue::list`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Outstanding {
    pub leases: Vec<LeaseView>,
    pub expired_in_waiting: u64,
}

impl Outstanding {
    /// Read up to `limit` leases of `queue_name`. A read failure is reported as empty with
    /// `expired_in_waiting` untouched: the admin view says "unknown", it never invents a lease.
    pub fn read(queue: &Queue, queue_name: &str, now_ms: i64, limit: usize) -> Outstanding {
        let Ok(jobs) = queue.list(queue_name, Some(JobState::Leased), limit.clamp(1, 256)) else {
            return Outstanding::default();
        };
        let mut leases = Vec::with_capacity(jobs.len());
        let mut expired = 0u64;
        for job in jobs {
            let until = job.lease_until.unwrap_or(now_ms);
            if until <= now_ms {
                expired += 1;
            }
            leases.push(LeaseView {
                job: job.id.0,
                queue: job.queue.clone(),
                worker: job.lease_worker.clone().unwrap_or_default(),
                until_ms: until,
                expires_in_ms: until.saturating_sub(now_ms),
                attempts: job.attempts,
                lease_expiries: job.lease_expiries,
            });
        }
        Outstanding { leases, expired_in_waiting: expired }
    }

    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "outstanding": self.leases.iter().map(|lease| serde_json::json!({
                "job": lease.job,
                "queue": lease.queue,
                "worker": lease.worker,
                "until_ms": lease.until_ms,
                "expires_in_ms": lease.expires_in_ms,
                "attempts": lease.attempts,
                "lease_expiries": lease.lease_expiries,
            })).collect::<Vec<_>>(),
            "expired_in_waiting": self.expired_in_waiting,
        })
    }
}
