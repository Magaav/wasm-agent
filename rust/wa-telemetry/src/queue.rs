//! Queue job lifecycle, as a thin layer over the registry.
//!
//! A queue has five moments worth a number: enqueued, started (so the wait is known), done (the run
//! is known), failed and expired. This module owns no queue: the caller supplies an id and says what
//! happened. It exists so that every queue in the tree reports the same names instead of each one
//! inventing `job_wait_ms` and `queue_latency`.
//!
//! Tracking is bounded (`MAX_TRACKED`). Beyond it a job still counts as enqueued and expired/started,
//! but its wait/run latency is *unknown* and is counted as such — an unmeasured latency is never
//! reported as zero.
use crate::labels::sanitize;
use crate::metrics::Metrics;
use crate::trace::{Span, SpanStatus};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

/// Jobs tracked at once. A node with more work than this has a queue problem, not a metrics problem.
pub const MAX_TRACKED: usize = 1024;
/// Longest reason label kept. Reasons are a closed set at the call site; this is the guard.
pub const MAX_REASON_LEN: usize = 24;

#[derive(Clone, Debug)]
struct Tracked {
    enqueued_ms: u64,
    started_ms: Option<u64>,
}

#[derive(Debug, Default)]
struct Track {
    items: BTreeMap<u64, Tracked>,
}

/// One queue of one component. Clone it; the state is shared.
#[derive(Clone)]
pub struct QueueMetrics {
    metrics: Metrics,
    component: Arc<str>,
    queue: Arc<str>,
    tracked: Arc<Mutex<Track>>,
    untracked: Arc<Mutex<u64>>,
}

impl std::fmt::Debug for QueueMetrics {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("QueueMetrics")
            .field("component", &self.component)
            .field("queue", &self.queue)
            .field("depth", &self.depth())
            .finish()
    }
}

impl QueueMetrics {
    pub fn new(metrics: Metrics, component: &str, queue: &str) -> Self {
        Self {
            metrics,
            component: Arc::from(component),
            queue: Arc::from(queue),
            tracked: Arc::new(Mutex::new(Track::default())),
            untracked: Arc::new(Mutex::new(0)),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Track> {
        self.tracked.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn now_ms(&self) -> u64 {
        self.metrics.now_ms()
    }

    fn counter(&self, name: &str, job: &str, reason: Option<&str>) {
        let queue = self.queue.to_string();
        let mut labels: Vec<(&str, &str)> = vec![("queue", &queue), ("job", job)];
        let reason = reason.map(|r| sanitize(r, MAX_REASON_LEN));
        if let Some(reason) = &reason {
            labels.push(("reason", reason));
        }
        self.metrics.counter(&self.component, name).add_labeled(1, &labels);
    }

    fn histogram(&self, name: &str, job: &str, micros: u64, ok: bool) {
        let queue = self.queue.to_string();
        self.metrics
            .histogram(&self.component, name)
            .observe_labeled(micros, ok, &[("queue", &queue), ("job", job)]);
    }

    fn span(&self, op: &str, start_ms: u64, duration_us: u64, status: SpanStatus, reason: Option<&str>) {
        let queue = self.queue.clone();
        let mut span = Span::new(self.component.clone(), op, start_ms, duration_us, status)
            .attr("queue", &queue);
        if let Some(reason) = reason {
            span = span.attr("reason", &sanitize(reason, MAX_REASON_LEN));
        }
        self.metrics.record_span(span);
    }

    /// A job was accepted. Returns `false` when the tracking table is full (the job still counts;
    /// its latencies will be unknown).
    pub fn enqueued(&self, id: u64, job: &str) -> bool {
        self.counter("queue_enqueued_total", job, None);
        let now = self.now_ms();
        let tracked = {
            let mut track = self.lock();
            if track.items.len() >= MAX_TRACKED || track.items.contains_key(&id) {
                false
            } else {
                track.items.insert(
                    id,
                    Tracked {
                        enqueued_ms: now,
                        started_ms: None,
                    },
                );
                true
            }
        };
        if !tracked {
            let mut n = self.untracked.lock().unwrap_or_else(|e| e.into_inner());
            *n = n.saturating_add(1);
        }
        self.publish_depth();
        tracked
    }

    /// A job started running: its wait is now measurable.
    pub fn started(&self, id: u64, job: &str) {
        self.counter("queue_started_total", job, None);
        let now = self.now_ms();
        let waited = {
            let mut track = self.lock();
            match track.items.get_mut(&id) {
                Some(item) => {
                    item.started_ms = Some(now);
                    Some(now.saturating_sub(item.enqueued_ms))
                }
                None => None,
            }
        };
        match waited {
            Some(wait_us) => {
                let micros = wait_us.saturating_mul(1_000);
                self.histogram("queue_wait_micros", job, micros, true);
                self.span("queue_wait", now.saturating_sub(wait_us), micros, SpanStatus::Ok, None);
            }
            None => self.counter("queue_latency_unknown_total", job, Some("wait")),
        }
    }

    /// A job finished successfully.
    pub fn done(&self, id: u64, job: &str) {
        self.finish(id, job, "queue_done_total", SpanStatus::Ok, None);
    }

    /// A job finished with a failure. `reason` must be a small closed set, not a message.
    pub fn failed(&self, id: u64, job: &str, reason: &str) {
        self.finish(id, job, "queue_failed_total", SpanStatus::Error, Some(reason));
    }

    /// A job never ran because it went stale (freshness window, TTL).
    pub fn expired(&self, id: u64, job: &str, reason: &str) {
        self.counter("queue_expired_total", job, Some(reason));
        let now = self.now_ms();
        let age = {
            let mut track = self.lock();
            let entry = track.items.get(&id).map(|item| {
                let base = item.started_ms.unwrap_or(item.enqueued_ms);
                now.saturating_sub(base)
            });
            track.items.remove(&id);
            entry
        };
        match age {
            Some(age_ms) => {
                let micros = age_ms.saturating_mul(1_000);
                self.histogram("queue_expired_age_micros", job, micros, false);
                self.span(
                    "queue_expired",
                    now.saturating_sub(age_ms),
                    micros,
                    SpanStatus::Expired,
                    Some(reason),
                );
            }
            None => self.counter("queue_latency_unknown_total", job, Some("expiry")),
        }
        self.publish_depth();
    }

    fn finish(&self, id: u64, job: &str, counter: &str, status: SpanStatus, reason: Option<&str>) {
        self.counter(counter, job, reason);
        let now = self.now_ms();
        let (start, run) = {
            let mut track = self.lock();
            let found = track.items.get(&id).map(|item| {
                let started = item.started_ms.unwrap_or(item.enqueued_ms);
                (started, now.saturating_sub(started))
            });
            track.items.remove(&id);
            match found {
                Some((started, run_us)) => (Some(started), Some(run_us)),
                None => (None, None),
            }
        };
        match (start, run) {
            (Some(start), Some(run)) => {
                let ok = status == SpanStatus::Ok;
                let op = if ok { "queue_run" } else { "queue_failed" };
                let micros = run.saturating_mul(1_000);
                self.histogram("queue_run_micros", job, micros, ok);
                self.span(op, start, micros, status, reason);
            }
            _ => self.counter("queue_latency_unknown_total", job, Some("run")),
        }
        self.publish_depth();
    }

    /// Jobs currently tracked (enqueued or running).
    pub fn depth(&self) -> usize {
        self.lock().items.len()
    }

    /// Jobs whose latencies could not be tracked because the table was full.
    pub fn untracked(&self) -> u64 {
        *self.untracked.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn publish_depth(&self) {
        let depth = self.depth() as i64;
        let queue = self.queue.to_string();
        self.metrics
            .gauge(&self.component, "queue_pending")
            .set_labeled(depth, &[("queue", &queue)]);
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn tracking_is_bounded_and_counted() {
        let cfg = crate::config::Config::for_tests();
        let m = Metrics::new(cfg);
        let q = QueueMetrics::new(m, "wa-whatsapp", "audio");
        for id in 0..(MAX_TRACKED as u64 + 5) {
            q.enqueued(id, "transcribe");
        }
        assert_eq!(q.depth(), MAX_TRACKED);
        assert_eq!(q.untracked(), 5);
        assert!(!q.enqueued(MAX_TRACKED as u64, "transcribe"));
    }
}
