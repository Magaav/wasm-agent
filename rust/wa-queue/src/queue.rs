//! The queue itself: every operation reads and writes only the [`Kv`], so a restart is a new
//! `Queue` over the same bytes.
//!
//! Layout (all keys are the host's namespaced keys; `id` is 8 bytes big-endian, `seq` likewise):
//!
//! | key | value | purpose |
//! | --- | --- | --- |
//! | `j/<id>` | job record | the truth: state, payload, attempts, lease, result |
//! | `i/<queue>/<R\|L><priority><id>` | empty | ordered ready/leased index (scan = priority desc, FIFO) |
//! | `d/<queue>/<dedupe key>` | `<id>` | producer idempotency claim |
//! | `p/<id>/<seq>` | chunk | append-only progress |
//! | `a/<id>/<kind>` | alert record | one alert per job and kind |
//! | `s/id`, `s/alert_seq`, `s/alert_last` | counter | id allocation, alert order, last batch time |
//!
//! Write order is chosen for crashes. `enqueue` claims the dedupe key first and the job record
//! before the index, so a crash can leave an index entry that [`Queue::take`] self-heals or a record
//! with no index entry that [`Queue::repair`] restores — never two jobs for one dedupe key. A crash
//! between the dedupe claim and the record write loses that one job; the producer's next enqueue
//! with the same key allocates a new id and proceeds (documented in `docs/QUEUE.md`).

use crate::codec::*;
use crate::*;
use std::sync::Arc;

const JOB: &[u8] = b"j/";
const INDEX: &[u8] = b"i/";
const DEDUPE: &[u8] = b"d/";
const PROGRESS: &[u8] = b"p/";
const ALERT: &[u8] = b"a/";
const SEQ_ID: &[u8] = b"s/id";
const SEQ_ALERT: &[u8] = b"s/alert_seq";
const ALERT_LAST: &[u8] = b"s/alert_last";

const STATE_READY: u8 = b'R';
const STATE_LEASED: u8 = b'L';

/// A durable queue over one [`Kv`] namespace, with an injected clock and an explicit [`Policy`].
pub struct Queue {
    kv: Arc<dyn Kv>,
    clock: Arc<dyn Clock>,
    policy: Policy,
}

impl Queue {
    pub fn new(kv: Arc<dyn Kv>, clock: Arc<dyn Clock>, policy: Policy) -> Self {
        Self { kv, clock, policy }
    }

    /// The policy this queue was built with (queue limits, retention, alert bounds).
    pub fn policy(&self) -> &Policy {
        &self.policy
    }

    // ---------------------------------------------------------------- producer side

    /// Store one job. Returns the existing id (and `dedupe_hit`) when `dedupe_key` already names a
    /// live job in this queue; the same key in another queue is a different job.
    pub fn enqueue(&self, request: EnqueueRequest) -> Result<EnqueueOutcome> {
        let now = self.now();
        self.validate_enqueue(&request)?;
        let max_attempts = request.max_attempts.unwrap_or(self.policy.max_attempts);
        let fresh_until = request
            .fresh_for_ms
            .or(self.policy.default_fresh_ms)
            .map(|ms| now.saturating_add(ms));
        let deadline = request
            .deadline_in_ms
            .or(self.policy.default_deadline_ms)
            .map(|ms| now.saturating_add(ms));
        let not_before = request.not_before.unwrap_or(now);
        if let Some(fresh) = fresh_until {
            if not_before >= fresh {
                // Stored, it would be dropped before it could ever be taken. Refuse loudly.
                return Err(QueueError::Invalid(
                    "not_before is at or after fresh_until".into(),
                ));
            }
        }
        if let Some(key) = &request.dedupe_key {
            let key = dedupe_key(&request.queue, key);
            if let Some(bytes) = self.kv.get(&key)? {
                if let Some(id) = id_from_bytes(&bytes) {
                    if self.load(id)?.is_some() {
                        return Ok(EnqueueOutcome {
                            id,
                            dedupe_hit: true,
                        });
                    }
                }
                // A claim whose record never landed (crash between the two writes): fall through
                // and overwrite it, so the key always names a real job or nothing.
            }
        }
        let ready = self.count_index(&request.queue, STATE_READY)?;
        if ready >= self.policy.max_ready {
            return Err(QueueError::Full {
                queue: request.queue.clone(),
                ready,
                limit: self.policy.max_ready,
            });
        }
        let id = JobId(self.next_counter(SEQ_ID)?);
        let job = Job {
            id,
            queue: request.queue,
            payload: request.payload,
            priority: request.priority,
            not_before,
            fresh_until,
            deadline,
            max_attempts,
            attempts: 0,
            lease_expiries: 0,
            dedupe_key: request.dedupe_key,
            state: JobState::Ready,
            lease_worker: None,
            lease_until: None,
            last_error: None,
            result: None,
            progress_entries: 0,
            progress_bytes: 0,
            created_at: now,
            updated_at: now,
        };
        // Claim the dedupe key first: at most one live job per key, even if we crash right after.
        if let Some(key) = &job.dedupe_key {
            self.kv
                .put(&dedupe_key(&job.queue, key), &id.0.to_be_bytes())?;
        }
        self.save(&job)?;
        self.put_index(&job)?;
        Ok(EnqueueOutcome {
            id,
            dedupe_hit: false,
        })
    }

    /// Append one progress chunk to a job (streamed segments, partial output). Append-only and
    /// readable incrementally with [`Queue::progress_since`].
    pub fn progress(&self, id: JobId, chunk: &[u8]) -> Result<u64> {
        let now = self.now();
        let mut job = self.job(id)?.ok_or(QueueError::NotFound)?;
        if job.progress_entries >= self.policy.max_progress_entries
            || job.progress_bytes.saturating_add(chunk.len() as u64)
                > self.policy.max_progress_bytes
        {
            return Err(QueueError::ProgressFull);
        }
        let seq = u64::from(job.progress_entries);
        let mut key = progress_prefix(id);
        key.extend_from_slice(&seq.to_be_bytes());
        self.kv.put(&key, chunk)?;
        job.progress_entries += 1;
        job.progress_bytes += chunk.len() as u64;
        job.updated_at = now;
        self.save(&job)?;
        Ok(seq)
    }

    /// Progress entries after `after` (exclusive), at most `limit`. `after = 0` starts at the first.
    pub fn progress_since(
        &self,
        id: JobId,
        after: u64,
        limit: usize,
    ) -> Result<Vec<ProgressEntry>> {
        let mut entries = Vec::new();
        for (key, value) in self.kv.scan_prefix(&progress_prefix(id))? {
            let Some(seq) = key.get(progress_prefix_len()..).and_then(seq_from_bytes) else {
                continue;
            };
            if seq < after || entries.len() >= limit {
                continue;
            }
            entries.push(ProgressEntry { seq, bytes: value });
        }
        entries.sort_by_key(|entry| entry.seq);
        Ok(entries)
    }

    // ---------------------------------------------------------------- worker side

    /// Lease the next due job in `queue`.
    ///
    /// Order: higher priority first, FIFO inside a priority. A job whose `not_before` is still in
    /// the future does not hide a due job behind it. Jobs past `fresh_until` are dropped here and
    /// recorded, so an old job can never be run just because the sweeper did not run.
    pub fn take(&self, queue: &str, worker: &str, lease_ms: Option<i64>) -> Result<TakeOutcome> {
        let now = self.now();
        if !valid_name(queue, 64) {
            return Err(QueueError::Invalid(format!("bad queue name {queue:?}")));
        }
        if !valid_name(worker, 100) {
            return Err(QueueError::Invalid("bad worker name".into()));
        }
        let lease_ms = lease_ms.unwrap_or(self.policy.lease_ms);
        if lease_ms <= 0 || lease_ms > self.policy.max_lease_ms {
            return Err(QueueError::Invalid(format!(
                "lease must be 1..={} ms",
                self.policy.max_lease_ms
            )));
        }
        self.recover_leases(queue, now)?;
        let limit = self.policy.limit_for(queue);
        let leased = self.count_index(queue, STATE_LEASED)?;
        if leased >= limit {
            return Ok(TakeOutcome::AtLimit { leased, limit });
        }
        for (key, _) in self.kv.scan_prefix(&index_prefix(queue, STATE_READY))? {
            let Some(id) = id_from_index_key(&key) else {
                self.kv.del(&key)?;
                continue;
            };
            let Some(mut job) = self.load(id)? else {
                // Orphan index entry (crash before the record landed, or after reap).
                self.kv.del(&key)?;
                continue;
            };
            if job.queue != queue || job.state != JobState::Ready {
                // Stale index entry: the record is the truth.
                self.kv.del(&key)?;
                continue;
            }
            if let Some(fresh) = job.fresh_until {
                if fresh <= now {
                    self.expire_at(&mut job, now, "fresh_until passed before it ran")?;
                    continue;
                }
            }
            if job.attempts >= job.max_attempts {
                self.dead_letter(&mut job, now, "attempts exhausted", false)?;
                continue;
            }
            if job.lease_expiries > self.policy.max_lease_losses {
                self.dead_letter(&mut job, now, "lease_lost", false)?;
                continue;
            }
            if job.not_before > now {
                continue;
            }
            job.state = JobState::Leased;
            job.lease_worker = Some(worker.to_string());
            job.lease_until = Some(now.saturating_add(lease_ms));
            job.updated_at = now;
            self.save(&job)?;
            self.kv.del(&key)?;
            self.put_index(&job)?;
            return Ok(TakeOutcome::Job(Box::new(job)));
        }
        Ok(TakeOutcome::Empty)
    }

    /// Extend a lease. Returns the new `lease_until`. `Err(LeaseLost)` when the caller no longer
    /// holds it (expired, settled, or taken by another worker after an expiry).
    pub fn heartbeat(&self, id: JobId, worker: &str, extend_ms: Option<i64>) -> Result<i64> {
        let now = self.now();
        let mut job = self.job(id)?.ok_or(QueueError::NotFound)?;
        if !self.holds_lease(&job, worker) {
            return Err(QueueError::LeaseLost);
        }
        let extend = extend_ms.unwrap_or(self.policy.lease_ms);
        if extend <= 0 || extend > self.policy.max_lease_ms {
            return Err(QueueError::Invalid(format!(
                "lease must be 1..={} ms",
                self.policy.max_lease_ms
            )));
        }
        let until = now.saturating_add(extend);
        job.lease_until = Some(until);
        job.updated_at = now;
        self.save(&job)?;
        Ok(until)
    }

    /// Settle a leased job with its result. At-least-once: a worker whose lease expired while it was
    /// finishing may still settle (its work happened); the other worker's settle then fails with
    /// `LeaseLost`. [`Queue::done_by`] refuses the stale one when the caller can name itself.
    pub fn done(&self, id: JobId, result: &[u8]) -> Result<Job> {
        self.settle(id, None, result)
    }

    /// Settle only if `worker` still holds the lease.
    pub fn done_by(&self, id: JobId, worker: &str, result: &[u8]) -> Result<Job> {
        self.settle(id, Some(worker), result)
    }

    /// Record a failure: retry with exponential backoff, or dead-letter once `max_attempts` is spent.
    ///
    /// Like [`Queue::done`], this accepts a lease that has technically lapsed but not yet been
    /// recovered. [`Queue::fail_by`] is the strict form for a caller that can name itself.
    pub fn fail(&self, id: JobId, reason: &str) -> Result<FailOutcome> {
        self.fail_inner(id, None, reason)
    }

    /// Record a failure only if `worker` still holds the lease.
    pub fn fail_by(&self, id: JobId, worker: &str, reason: &str) -> Result<FailOutcome> {
        self.fail_inner(id, Some(worker), reason)
    }

    fn fail_inner(&self, id: JobId, worker: Option<&str>, reason: &str) -> Result<FailOutcome> {
        let now = self.now();
        let mut job = self.job(id)?.ok_or(QueueError::NotFound)?;
        if job.state != JobState::Leased {
            return Err(QueueError::LeaseLost);
        }
        if let Some(worker) = worker {
            if !self.holds_lease(&job, worker) {
                return Err(QueueError::LeaseLost);
            }
        }
        job.attempts += 1;
        job.lease_worker = None;
        job.lease_until = None;
        job.last_error = Some(sanitize(reason));
        job.updated_at = now;
        self.kv.del(&index_key(&job, STATE_LEASED))?;
        if job.attempts >= job.max_attempts {
            // `last_error` already holds the worker's reason; keep it for the record and the alert.
            self.dead_letter(&mut job, now, "attempts exhausted", true)?;
            return Ok(FailOutcome {
                state: JobState::Dead,
                attempts: job.attempts,
                not_before: None,
                dead: true,
            });
        }
        let delay = self.policy.retry.delay_ms(job.attempts);
        job.state = JobState::Ready;
        job.not_before = now.saturating_add(delay);
        self.save(&job)?;
        self.put_index(&job)?;
        Ok(FailOutcome {
            state: JobState::Ready,
            attempts: job.attempts,
            not_before: Some(job.not_before),
            dead: false,
        })
    }

    /// Hand back every lease held by a worker whose id starts with `prefix`, without spending an
    /// attempt and without a retry delay.
    ///
    /// This is the *swap* case, not the crash case: the workers behind the prefix belong to an
    /// instance that is being replaced **on purpose** (a component hot-swap, a kernel swap), so their
    /// jobs did not fail - the instance that replaced them takes them on its next `take`, at once.
    /// Everything a lease could tell us about a crash is wrong here: [`Queue::take`]'s own recovery
    /// charges a `lease_expiries` per loss and backs the retry off, so a routine swap would burn the
    /// budget of jobs that never failed.
    ///
    /// The lease is *gone*, which is the fencing that matters: the retired worker's late
    /// [`Queue::done_by`] or [`Queue::fail_by`] is refused with `LeaseLost`, so a job handed over is
    /// never settled twice. Freshness is still honoured - a job whose `fresh_until` passed while it was
    /// leased is expired here rather than handed to the new instance, the same rule `take` applies.
    ///
    /// Returns how many leases were handed back. A prefix that matches nothing is `Ok(0)`, never an
    /// error: "the instance had nothing in flight" is the normal case.
    pub fn handover(&self, queue: &str, prefix: &str) -> Result<usize> {
        if !valid_name(queue, 64) {
            return Err(QueueError::Invalid(format!("bad queue name {queue:?}")));
        }
        if prefix.is_empty() {
            // An empty prefix would match every worker on the queue, including the instance that is
            // taking over. Refused rather than treated as "all".
            return Err(QueueError::Invalid("handover needs a worker prefix".into()));
        }
        let now = self.now();
        let mut handed = 0;
        for (key, _) in self.kv.scan_prefix(&index_prefix(queue, STATE_LEASED))? {
            let Some(id) = id_from_index_key(&key) else {
                self.kv.del(&key)?;
                continue;
            };
            let Some(mut job) = self.load(id)? else {
                self.kv.del(&key)?;
                continue;
            };
            if job.queue != queue || job.state != JobState::Leased {
                self.kv.del(&key)?;
                continue;
            }
            if !job.lease_worker.as_deref().is_some_and(|worker| worker.starts_with(prefix)) {
                continue;
            }
            self.kv.del(&key)?;
            job.lease_worker = None;
            job.lease_until = None;
            job.updated_at = now;
            if job.fresh_until.is_some_and(|fresh| fresh <= now) {
                self.expire_at(&mut job, now, "fresh_until passed while leased")?;
            } else {
                job.state = JobState::Ready;
                // Due now: a handover is not a failure, so there is nothing to back off from.
                job.not_before = now;
                self.save(&job)?;
                self.put_index(&job)?;
            }
            handed += 1;
        }
        Ok(handed)
    }

    // ---------------------------------------------------------------- freshness, sweeps, alerts

    /// Drop every *unleased* job whose `fresh_until` has passed, without running it. Each drop is
    /// recorded on the job and as one `expired` alert. A job a worker is holding right now is left
    /// alone (the transcript it is producing is still fresh); if its lease later expires, `take` and
    /// `recover_leases` apply the same rule.
    pub fn expire_stale(&self) -> Result<ExpireOutcome> {
        self.expire_stale_at(self.now())
    }

    /// The same sweep against an explicit instant (a host that already read its clock once for the
    /// whole tick, or a test that wants to say *when* without moving the injected clock).
    pub fn expire_stale_at(&self, now: i64) -> Result<ExpireOutcome> {
        let mut outcome = ExpireOutcome::default();
        for mut job in self.all_jobs()? {
            if job.state != JobState::Ready {
                continue;
            }
            if job.fresh_until.is_some_and(|fresh| fresh <= now) {
                self.expire_at(&mut job, now, "fresh_until passed before it ran")?;
                outcome.expired.push(job.id);
            }
        }
        Ok(outcome)
    }

    /// One maintenance pass: expired leases, stale jobs, timeout alerts, retention. Idempotent, so
    /// the host can run it on every tick.
    pub fn sweep(&self) -> Result<SweepOutcome> {
        let now = self.now();
        let mut outcome = SweepOutcome::default();
        for queue in self.queues()? {
            outcome.leases_recovered += self.recover_leases(&queue, now)?;
        }
        outcome.expired = self.expire_stale()?.expired.len();
        outcome.timed_out = self.timeout_alerts(now)?;
        outcome.reaped = self.reap()?;
        Ok(outcome)
    }

    /// The next alert batch, or `None` when there is nothing ready or the rate limit forbids sending
    /// yet. Items are marked sent; ready alerts beyond `batch_max` stay ready for the next batch and
    /// are reported as `overflow` (never silently dropped). Alerts older than `max_age_ms` are
    /// dropped and counted.
    pub fn next_alerts(&self) -> Result<Option<AlertBatch>> {
        let now = self.now();
        if let Some(bytes) = self.kv.get(ALERT_LAST)? {
            if let Some(last) = i64_from_bytes(&bytes) {
                if last > now.saturating_sub(self.policy.alerts.min_gap_ms) {
                    return Ok(None);
                }
            }
        }
        let mut ready = Vec::new();
        let mut dropped = 0usize;
        for (key, bytes) in self.kv.scan_prefix(ALERT)? {
            let mut alert = decode_alert(&key, &bytes)?;
            if alert.state != AlertState::Ready {
                continue;
            }
            if alert.at < now.saturating_sub(self.policy.alerts.max_age_ms) {
                alert.state = AlertState::Dropped;
                self.kv.put(&key, &encode_alert(&alert))?;
                dropped += 1;
                continue;
            }
            ready.push((key, alert));
        }
        if ready.is_empty() {
            return Ok(None);
        }
        ready.sort_by_key(|(_, alert)| (alert.at, alert.seq));
        let batch_max = self.policy.alerts.batch_max.max(1);
        let overflow = ready.len().saturating_sub(batch_max);
        let mut items = Vec::new();
        for (key, mut alert) in ready {
            if items.len() >= batch_max {
                break;
            }
            alert.state = AlertState::Sent;
            self.kv.put(&key, &encode_alert(&alert))?;
            items.push(alert);
        }
        self.kv.put(ALERT_LAST, &now.to_be_bytes())?;
        Ok(Some(AlertBatch {
            items,
            overflow,
            dropped,
        }))
    }

    // ---------------------------------------------------------------- admin

    /// One job, as stored.
    pub fn job(&self, id: JobId) -> Result<Option<Job>> {
        self.load(id)
    }

    /// Jobs of one queue, optionally filtered by state, oldest id first.
    pub fn list(&self, queue: &str, state: Option<JobState>, limit: usize) -> Result<Vec<Job>> {
        let mut jobs: Vec<Job> = self
            .all_jobs()?
            .into_iter()
            .filter(|job| job.queue == queue && state.is_none_or(|want| job.state == want))
            .collect();
        jobs.sort_by_key(|job| job.id);
        jobs.truncate(limit);
        Ok(jobs)
    }

    /// Dead-lettered jobs of one queue, oldest failure first.
    pub fn dead_letters(&self, queue: &str, limit: usize) -> Result<Vec<Job>> {
        let mut jobs: Vec<Job> = self
            .all_jobs()?
            .into_iter()
            .filter(|job| job.queue == queue && job.state == JobState::Dead)
            .collect();
        jobs.sort_by_key(|job| (job.updated_at, job.id));
        jobs.truncate(limit);
        Ok(jobs)
    }

    /// Alert records, oldest first (all states unless `state` is given).
    pub fn alerts(&self, state: Option<AlertState>, limit: usize) -> Result<Vec<Alert>> {
        let mut alerts = Vec::new();
        for (key, bytes) in self.kv.scan_prefix(ALERT)? {
            let alert = decode_alert(&key, &bytes)?;
            if state.is_none_or(|want| alert.state == want) {
                alerts.push(alert);
            }
        }
        alerts.sort_by_key(|alert| (alert.at, alert.seq));
        alerts.truncate(limit);
        Ok(alerts)
    }

    /// Counters for one queue.
    pub fn stats(&self, queue: &str) -> Result<QueueStats> {
        let now = self.now();
        let mut stats = QueueStats::default();
        let mut oldest_ready: Option<i64> = None;
        for job in self.all_jobs()? {
            if job.queue != queue {
                continue;
            }
            stats.progress_bytes += job.progress_bytes;
            match job.state {
                JobState::Ready => {
                    stats.ready += 1;
                    if job.not_before > now {
                        stats.retrying += 1;
                    }
                    oldest_ready =
                        Some(oldest_ready.map_or(job.created_at, |at| at.min(job.created_at)));
                }
                JobState::Leased => stats.leased += 1,
                JobState::Done => stats.done += 1,
                JobState::Dead => stats.dead += 1,
                JobState::Expired => stats.expired += 1,
            }
        }
        stats.oldest_ready_age_ms = oldest_ready.map_or(0, |at| (now - at).max(0));
        Ok(stats)
    }

    /// Queues that currently have any record.
    pub fn queues(&self) -> Result<Vec<String>> {
        let mut names: Vec<String> = self.all_jobs()?.into_iter().map(|job| job.queue).collect();
        names.sort();
        names.dedup();
        Ok(names)
    }

    /// Revive a dead-lettered job with the defaults: attempts reset, freshness kept.
    pub fn requeue(&self, id: JobId) -> Result<Job> {
        self.requeue_with(id, &RequeueOptions::default())
    }

    /// Revive a dead-lettered job. Freshness is only refreshed on request: the "never run stale
    /// work" rule is not something an admin call may bypass by accident.
    pub fn requeue_with(&self, id: JobId, options: &RequeueOptions) -> Result<Job> {
        let now = self.now();
        let mut job = self.job(id)?.ok_or(QueueError::NotFound)?;
        if job.state != JobState::Dead {
            return Err(QueueError::Invalid(format!(
                "only dead-lettered jobs can be requeued (job is {})",
                job.state.as_str()
            )));
        }
        if options.attempts_reset {
            job.attempts = 0;
            job.lease_expiries = 0;
        }
        if let Some(max) = options.max_attempts {
            job.max_attempts = max.max(1);
        }
        if options.refresh_fresh {
            job.fresh_until = self
                .policy
                .default_fresh_ms
                .map(|ms| now.saturating_add(ms));
        }
        job.state = JobState::Ready;
        job.not_before = now;
        job.lease_worker = None;
        job.lease_until = None;
        job.last_error = Some("requeued".into());
        job.updated_at = now;
        self.save(&job)?;
        self.kv.del(&index_key(&job, STATE_LEASED))?;
        self.put_index(&job)?;
        Ok(job)
    }

    /// Retire terminal records older than the retention policy, with their progress chunks and their
    /// dedupe claim. Alerts are kept (they are the operator's record) until the alert policy ages
    /// them out.
    pub fn reap(&self) -> Result<usize> {
        let now = self.now();
        let mut reaped = 0;
        for job in self.all_jobs()? {
            let retention = match job.state {
                JobState::Done => self.policy.done_retention_ms,
                JobState::Dead => self.policy.dead_retention_ms,
                JobState::Expired => self.policy.expired_retention_ms,
                _ => continue,
            };
            if now.saturating_sub(job.updated_at) < retention {
                continue;
            }
            for (key, _) in self.kv.scan_prefix(&progress_prefix(job.id))? {
                self.kv.del(&key)?;
            }
            if let Some(key) = &job.dedupe_key {
                let key = dedupe_key(&job.queue, key);
                // Only release the claim if it still names this job.
                if self.kv.get(&key)?.and_then(|bytes| id_from_bytes(&bytes)) == Some(job.id) {
                    self.kv.del(&key)?;
                }
            }
            self.kv.del(&index_key(&job, STATE_READY))?;
            self.kv.del(&index_key(&job, STATE_LEASED))?;
            self.kv.del(&job_key(job.id))?;
            reaped += 1;
        }
        Ok(reaped)
    }

    /// Make the derived keys (index, dedupe) agree with the job records, and drop orphans. The
    /// records are the truth; this is the recovery for a crash between two writes.
    pub fn repair(&self) -> Result<RepairOutcome> {
        let mut outcome = RepairOutcome::default();
        let mut index_wanted: Vec<(Vec<u8>, JobId)> = Vec::new();
        let mut dedupe_wanted: Vec<(Vec<u8>, JobId)> = Vec::new();
        for job in self.all_jobs()? {
            match job.state {
                JobState::Ready | JobState::Leased => {
                    let state = if job.state == JobState::Ready {
                        STATE_READY
                    } else {
                        STATE_LEASED
                    };
                    index_wanted.push((index_key(&job, state), job.id));
                }
                _ => {}
            }
            if let Some(key) = &job.dedupe_key {
                dedupe_wanted.push((dedupe_key(&job.queue, key), job.id));
            }
        }
        // Orphan index entries.
        for (key, _) in self.kv.scan_prefix(INDEX)? {
            let wanted = index_wanted.iter().any(|(want, _)| want == &key);
            if !wanted {
                self.kv.del(&key)?;
                outcome.index_removed += 1;
            }
        }
        for (key, _) in &index_wanted {
            if self.kv.get(key)?.is_none() {
                self.kv.put(key, &[])?;
                outcome.index_added += 1;
            }
        }
        // Dedupe claims that name a missing job, another job, or no longer match.
        for (key, value) in self.kv.scan_prefix(DEDUPE)? {
            let holder = id_from_bytes(&value);
            let wanted = dedupe_wanted
                .iter()
                .find(|(want, _)| want == &key)
                .map(|(_, id)| *id);
            if wanted.is_none() || wanted != holder {
                self.kv.del(&key)?;
                outcome.dedupe_removed += 1;
            }
        }
        for (key, id) in &dedupe_wanted {
            if id_from_bytes(&self.kv.get(key)?.unwrap_or_default()) != Some(*id) {
                self.kv.put(key, &id.0.to_be_bytes())?;
                outcome.dedupe_added += 1;
            }
        }
        Ok(outcome)
    }

    /// First timeout alert for every unfinished job past its deadline. One per job, ever: a second
    /// sweep does not repeat it.
    fn timeout_alerts(&self, now: i64) -> Result<usize> {
        let mut raised = 0;
        for job in self.all_jobs()? {
            if job.state.is_terminal() {
                continue;
            }
            let Some(deadline) = job.deadline else {
                continue;
            };
            if deadline > now {
                continue;
            }
            let reason = format!("not finished by deadline (state {})", job.state.as_str());
            if self.record_alert(&job, now, AlertKind::TimedOut, &reason)? {
                raised += 1;
            }
        }
        Ok(raised)
    }

    // ---------------------------------------------------------------- internals

    fn now(&self) -> i64 {
        self.clock.now_ms()
    }

    fn save(&self, job: &Job) -> Result<()> {
        self.kv.put(&job_key(job.id), &encode_job(job))?;
        Ok(())
    }

    fn load(&self, id: JobId) -> Result<Option<Job>> {
        match self.kv.get(&job_key(id))? {
            None => Ok(None),
            Some(bytes) => Ok(Some(decode_job(id, &bytes)?)),
        }
    }

    fn all_jobs(&self) -> Result<Vec<Job>> {
        let mut jobs = Vec::new();
        for (key, value) in self.kv.scan_prefix(JOB)? {
            let Some(id) = id_after(&key, JOB.len()) else {
                continue;
            };
            jobs.push(decode_job(id, &value)?);
        }
        jobs.sort_by_key(|job| job.id);
        Ok(jobs)
    }

    fn holds_lease(&self, job: &Job, worker: &str) -> bool {
        job.state == JobState::Leased && job.lease_worker.as_deref() == Some(worker)
    }

    fn settle(&self, id: JobId, worker: Option<&str>, result: &[u8]) -> Result<Job> {
        let now = self.now();
        let mut job = self.job(id)?.ok_or(QueueError::NotFound)?;
        if job.state != JobState::Leased {
            return Err(QueueError::LeaseLost);
        }
        if let Some(worker) = worker {
            if !self.holds_lease(&job, worker) {
                return Err(QueueError::LeaseLost);
            }
        }
        if result.len() > self.policy.max_result_bytes {
            return Err(QueueError::TooLarge(format!(
                "result is {} bytes, limit {}",
                result.len(),
                self.policy.max_result_bytes
            )));
        }
        job.state = JobState::Done;
        job.result = Some(result.to_vec());
        job.lease_worker = None;
        job.lease_until = None;
        job.last_error = None;
        job.updated_at = now;
        self.save(&job)?;
        self.kv.del(&index_key(&job, STATE_LEASED))?;
        Ok(job)
    }

    /// Drop a stale job: record it as expired and raise one alert. Never runs the payload.
    fn expire_at(&self, job: &mut Job, now: i64, reason: &str) -> Result<()> {
        self.kv.del(&index_key(job, STATE_READY))?;
        self.kv.del(&index_key(job, STATE_LEASED))?;
        job.state = JobState::Expired;
        job.lease_worker = None;
        job.lease_until = None;
        job.last_error = Some(sanitize(reason));
        job.updated_at = now;
        self.save(job)?;
        self.record_alert(job, now, AlertKind::Expired, reason)?;
        Ok(())
    }

    /// Dead-letter a job. `keep_error` leaves `last_error` (the worker's own reason) in place and
    /// re-uses it as the alert reason, so "attempts exhausted" never hides what actually failed.
    fn dead_letter(&self, job: &mut Job, now: i64, why: &str, keep_error: bool) -> Result<()> {
        self.kv.del(&index_key(job, STATE_READY))?;
        self.kv.del(&index_key(job, STATE_LEASED))?;
        if !keep_error {
            job.last_error = Some(sanitize(why));
        }
        job.state = JobState::Dead;
        job.lease_worker = None;
        job.lease_until = None;
        job.updated_at = now;
        self.save(job)?;
        let reason = job.last_error.clone().unwrap_or_else(|| sanitize(why));
        self.record_alert(job, now, AlertKind::Dead, &reason)?;
        Ok(())
    }

    /// Leases that have run out go back to `Ready` (a worker that is gone cannot hold a job). The
    /// first loss retries immediately — a restart is not the job's fault — later ones back off, and
    /// a job that keeps losing its lease is dead-lettered instead of looping forever.
    fn recover_leases(&self, queue: &str, now: i64) -> Result<usize> {
        let mut recovered = 0;
        for (key, _) in self.kv.scan_prefix(&index_prefix(queue, STATE_LEASED))? {
            let Some(id) = id_from_index_key(&key) else {
                self.kv.del(&key)?;
                continue;
            };
            let Some(mut job) = self.load(id)? else {
                self.kv.del(&key)?;
                continue;
            };
            if job.queue != queue || job.state != JobState::Leased {
                self.kv.del(&key)?;
                continue;
            }
            if job.lease_until.is_some_and(|until| until > now) {
                continue;
            }
            job.lease_expiries += 1;
            job.last_error = Some("lease expired (worker did not settle)".into());
            job.lease_worker = None;
            job.lease_until = None;
            job.updated_at = now;
            self.kv.del(&key)?;
            if job.fresh_until.is_some_and(|fresh| fresh <= now) {
                self.expire_at(&mut job, now, "fresh_until passed while leased")?;
            } else if job.lease_expiries > self.policy.max_lease_losses {
                self.dead_letter(&mut job, now, "lease_lost", false)?;
            } else if job.attempts >= job.max_attempts {
                self.dead_letter(&mut job, now, "attempts exhausted", false)?;
            } else {
                job.state = JobState::Ready;
                job.not_before = now.saturating_add(
                    self.policy
                        .retry
                        .delay_ms(job.lease_expiries.saturating_sub(1)),
                );
                self.save(&job)?;
                self.put_index(&job)?;
            }
            recovered += 1;
        }
        Ok(recovered)
    }

    fn record_alert(&self, job: &Job, now: i64, kind: AlertKind, reason: &str) -> Result<bool> {
        let key = alert_key(job.id, kind);
        if self.kv.get(&key)?.is_some() {
            return Ok(false);
        }
        let seq = self.next_counter(SEQ_ALERT)?;
        let alert = Alert {
            seq,
            job: job.id,
            queue: job.queue.clone(),
            kind,
            reason: sanitize(reason),
            at: now,
            state: AlertState::Ready,
        };
        self.kv.put(&key, &encode_alert(&alert))?;
        Ok(true)
    }

    fn put_index(&self, job: &Job) -> Result<()> {
        let state = match job.state {
            JobState::Ready => STATE_READY,
            JobState::Leased => STATE_LEASED,
            _ => return Ok(()),
        };
        self.kv.put(&index_key(job, state), &[])?;
        Ok(())
    }

    fn count_index(&self, queue: &str, state: u8) -> Result<usize> {
        Ok(self.kv.scan_prefix(&index_prefix(queue, state))?.len())
    }

    fn next_counter(&self, key: &[u8]) -> Result<u64> {
        let next = self
            .kv
            .get(key)?
            .and_then(|bytes| u64_from_bytes(&bytes))
            .unwrap_or(1);
        self.kv.put(key, &next.saturating_add(1).to_be_bytes())?;
        Ok(next)
    }

    fn validate_enqueue(&self, request: &EnqueueRequest) -> Result<()> {
        if !valid_name(&request.queue, 64) {
            return Err(QueueError::Invalid(format!(
                "bad queue name {:?}",
                request.queue
            )));
        }
        if request.payload.len() > self.policy.max_payload_bytes {
            return Err(QueueError::TooLarge(format!(
                "payload is {} bytes, limit {}",
                request.payload.len(),
                self.policy.max_payload_bytes
            )));
        }
        let max_attempts = request.max_attempts.unwrap_or(self.policy.max_attempts);
        if max_attempts == 0 {
            return Err(QueueError::Invalid(
                "max_attempts must be at least 1".into(),
            ));
        }
        if let Some(ms) = request.fresh_for_ms {
            if ms <= 0 {
                return Err(QueueError::Invalid("fresh_for_ms must be positive".into()));
            }
        }
        if let Some(ms) = request.deadline_in_ms {
            if ms <= 0 {
                return Err(QueueError::Invalid(
                    "deadline_in_ms must be positive".into(),
                ));
            }
        }
        if let Some(key) = &request.dedupe_key {
            if key.is_empty() || key.len() > 256 || key.chars().any(char::is_control) {
                return Err(QueueError::Invalid(
                    "dedupe_key must be 1..=256 bytes without control characters".into(),
                ));
            }
        }
        Ok(())
    }
}

// ------------------------------------------------------------------ keys

fn job_key(id: JobId) -> Vec<u8> {
    let mut key = JOB.to_vec();
    key.extend_from_slice(&id.0.to_be_bytes());
    key
}

fn index_prefix(queue: &str, state: u8) -> Vec<u8> {
    let mut key = INDEX.to_vec();
    key.extend_from_slice(queue.as_bytes());
    key.push(b'/');
    key.push(state);
    key
}

fn index_key(job: &Job, state: u8) -> Vec<u8> {
    let mut key = index_prefix(&job.queue, state);
    // Inverted priority: the scan returns descending priority. Id ascending: FIFO inside one.
    key.extend_from_slice(&(u32::MAX - job.priority).to_be_bytes());
    key.extend_from_slice(&job.id.0.to_be_bytes());
    key
}

fn dedupe_key(queue: &str, key: &str) -> Vec<u8> {
    let mut bytes = DEDUPE.to_vec();
    bytes.extend_from_slice(queue.as_bytes());
    bytes.push(b'/');
    bytes.extend_from_slice(key.as_bytes());
    bytes
}

fn progress_prefix(id: JobId) -> Vec<u8> {
    let mut key = PROGRESS.to_vec();
    key.extend_from_slice(&id.0.to_be_bytes());
    key.push(b'/');
    key
}

fn progress_prefix_len() -> usize {
    PROGRESS.len() + 8 + 1
}

fn alert_key(id: JobId, kind: AlertKind) -> Vec<u8> {
    let mut key = ALERT.to_vec();
    key.extend_from_slice(&id.0.to_be_bytes());
    key.push(b'/');
    key.push(kind.code());
    key
}

// ------------------------------------------------------------------ records

fn encode_job(job: &Job) -> Vec<u8> {
    let mut out = Vec::with_capacity(160 + job.payload.len());
    u64b(&mut out, job.id.0);
    strb(&mut out, &job.queue);
    bytesb(&mut out, &job.payload);
    u32b(&mut out, job.priority);
    i64b(&mut out, job.not_before);
    i64b(&mut out, job.created_at);
    i64b(&mut out, job.updated_at);
    opt_i64b(&mut out, job.fresh_until);
    opt_i64b(&mut out, job.deadline);
    u32b(&mut out, job.max_attempts);
    u32b(&mut out, job.attempts);
    u32b(&mut out, job.lease_expiries);
    opt_strb(&mut out, job.dedupe_key.as_deref());
    out.push(state_code(job.state));
    opt_strb(&mut out, job.lease_worker.as_deref());
    opt_i64b(&mut out, job.lease_until);
    opt_strb(&mut out, job.last_error.as_deref());
    opt_bytesb(&mut out, job.result.as_deref());
    u32b(&mut out, job.progress_entries);
    u64b(&mut out, job.progress_bytes);
    out
}

fn decode_job(id: JobId, bytes: &[u8]) -> Result<Job> {
    let mut r = Reader::new(bytes);
    let stored = r.job_id()?;
    if stored != id {
        return Err(QueueError::Corrupt(format!(
            "record at {id} claims to be {stored}"
        )));
    }
    let queue = r.string()?;
    let payload = r.bytes()?;
    let priority = r.u32()?;
    let not_before = r.i64()?;
    let created_at = r.i64()?;
    let updated_at = r.i64()?;
    let fresh_until = r.opt_i64()?;
    let deadline = r.opt_i64()?;
    let max_attempts = r.u32()?;
    let attempts = r.u32()?;
    let lease_expiries = r.u32()?;
    let dedupe_key = r.opt_string()?;
    let state = state_from(r.u8()?)?;
    let lease_worker = r.opt_string()?;
    let lease_until = r.opt_i64()?;
    let last_error = r.opt_string()?;
    let result = r.opt_bytes()?;
    let progress_entries = r.u32()?;
    let progress_bytes = r.u64()?;
    r.finished()?;
    Ok(Job {
        id,
        queue,
        payload,
        priority,
        not_before,
        fresh_until,
        deadline,
        max_attempts,
        attempts,
        lease_expiries,
        dedupe_key,
        state,
        lease_worker,
        lease_until,
        last_error,
        result,
        progress_entries,
        progress_bytes,
        created_at,
        updated_at,
    })
}

fn encode_alert(alert: &Alert) -> Vec<u8> {
    let mut out = Vec::new();
    u64b(&mut out, alert.seq);
    strb(&mut out, &alert.queue);
    out.push(alert.kind.code());
    strb(&mut out, &alert.reason);
    i64b(&mut out, alert.at);
    out.push(match alert.state {
        AlertState::Ready => 0,
        AlertState::Sent => 1,
        AlertState::Dropped => 2,
    });
    out
}

fn decode_alert(key: &[u8], bytes: &[u8]) -> Result<Alert> {
    let id = id_after(key, ALERT.len()).ok_or_else(|| QueueError::Corrupt("alert key".into()))?;
    let mut r = Reader::new(bytes);
    let seq = r.u64()?;
    let queue = r.string()?;
    let kind = AlertKind::from_code(r.u8()?)?;
    let reason = r.string()?;
    let at = r.i64()?;
    let state = match r.u8()? {
        0 => AlertState::Ready,
        1 => AlertState::Sent,
        2 => AlertState::Dropped,
        n => return Err(QueueError::Corrupt(format!("bad alert state {n}"))),
    };
    r.finished()?;
    Ok(Alert {
        seq,
        job: id,
        queue,
        kind,
        reason,
        at,
        state,
    })
}

// ------------------------------------------------------------------ bytes and names

fn id_from_index_key(key: &[u8]) -> Option<JobId> {
    id_at(key, key.len().checked_sub(8)?)
}

fn id_after(key: &[u8], offset: usize) -> Option<JobId> {
    id_at(key, offset)
}

fn id_at(key: &[u8], offset: usize) -> Option<JobId> {
    let bytes = key.get(offset..offset.checked_add(8)?)?;
    Some(JobId(u64::from_be_bytes(bytes.try_into().ok()?)))
}

fn id_from_bytes(bytes: &[u8]) -> Option<JobId> {
    u64_from_bytes(bytes).map(JobId)
}

fn u64_from_bytes(bytes: &[u8]) -> Option<u64> {
    if bytes.len() != 8 {
        return None;
    }
    Some(u64::from_be_bytes(bytes.try_into().ok()?))
}

fn i64_from_bytes(bytes: &[u8]) -> Option<i64> {
    if bytes.len() != 8 {
        return None;
    }
    Some(i64::from_be_bytes(bytes.try_into().ok()?))
}

fn seq_from_bytes(bytes: &[u8]) -> Option<u64> {
    u64_from_bytes(bytes)
}

/// Queue and worker names are idents: no `/`, no NUL, nothing that could forge a key boundary.
fn valid_name(name: &str, max: usize) -> bool {
    !name.is_empty()
        && name.len() <= max
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.' || b == b':')
}

/// A reason is for a log line: one line, bounded, no control characters. Never a payload.
fn sanitize(reason: &str) -> String {
    let cleaned: String = reason
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let trimmed = cleaned.trim();
    let mut out: String = trimmed.chars().take(200).collect();
    if trimmed.chars().count() > 200 {
        out.push('…');
    }
    out
}
