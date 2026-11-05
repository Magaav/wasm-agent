//! The audio queue: the one place that decides what is transcribed, when, and what is given up.
//!
//! Interface (kept small on purpose, so a shared durable queue component - `wa:queue` on WASI 0.3,
//! kv-backed, returning future/stream, with remote STT workers through the relay - can replace it
//! mechanically): `enqueue`, `take`, `done`, `fail`, `expire_stale`. Freshness, retry and the
//! timeout alert are policies handed in (`Policy`), not decisions spread through the pipeline; what
//! the queue gives up comes back as `Notice`s that the caller turns into own-chat alerts.
//!
//! Pure logic, no host calls: unit-tested natively (`cargo test --lib`).
use std::collections::VecDeque;

/// What the queue is told to enforce.
#[derive(Clone, Copy, Debug)]
pub struct Policy {
    /// An item not picked up within this many ms of being sent expires (never transcribed late).
    pub fresh_ms: i64,
    /// Retry backoff for a retryable failure: base, doubling, capped.
    pub retry_base_ms: i64,
    pub retry_cap_ms: i64,
    /// Attempts before a retryable failure becomes final.
    pub max_attempts: u32,
}

impl Default for Policy {
    fn default() -> Self {
        Policy { fresh_ms: 300_000, retry_base_ms: 10_000, retry_cap_ms: 60_000, max_attempts: 3 }
    }
}

#[derive(Debug)]
pub struct Item<T> {
    pub key: String,
    pub sent_ms: i64,
    pub attempts: u32,
    next_ms: i64,
    pub payload: T,
}

/// Something the queue gave up on; the caller logs it and queues an own-chat alert.
#[derive(Clone, Debug, PartialEq)]
pub struct Notice {
    pub key: String,
    pub sent_ms: i64,
    /// `audio_expired` (not picked up in the window) or `failed` (retries exhausted / permanent).
    pub kind: &'static str,
    pub reason: String,
}

pub struct AudioQueue<T> {
    policy: Policy,
    items: VecDeque<Item<T>>,
    inflight: Option<String>,
}

impl<T> AudioQueue<T> {
    pub fn new(policy: Policy) -> Self {
        AudioQueue { policy, items: VecDeque::new(), inflight: None }
    }

    pub fn policy(&self) -> Policy {
        self.policy
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    /// Queue an item (conversation order: FIFO). A key already queued or in flight is ignored.
    pub fn enqueue(&mut self, key: String, sent_ms: i64, payload: T) -> bool {
        if self.inflight.as_deref() == Some(key.as_str()) || self.items.iter().any(|i| i.key == key) {
            return false;
        }
        self.items.push_back(Item { key, sent_ms, attempts: 0, next_ms: 0, payload });
        true
    }

    /// The next item due at `now`, if any (one in flight at a time: one recognizer). Stale items
    /// are not handed out: `expire_stale` reports them.
    pub fn take(&mut self, now: i64) -> Option<Item<T>> {
        if self.inflight.is_some() {
            return None;
        }
        let cut = now - self.policy.fresh_ms;
        let at = self.items.iter().position(|i| i.next_ms <= now && i.sent_ms >= cut)?;
        let item = self.items.remove(at)?;
        self.inflight = Some(item.key.clone());
        Some(item)
    }

    /// The in-flight item finished (posted, held, or deliberately skipped).
    pub fn done(&mut self, key: &str) {
        if self.inflight.as_deref() == Some(key) {
            self.inflight = None;
        }
    }

    /// The in-flight item failed. A retryable failure goes back with backoff until `max_attempts`;
    /// a permanent one, or the last attempt, is final and comes back as a `failed` notice.
    pub fn fail(&mut self, mut item: Item<T>, now: i64, reason: &str, retryable: bool) -> Option<Notice> {
        self.done(&item.key);
        item.attempts += 1;
        if retryable && item.attempts < self.policy.max_attempts {
            let backoff = (self.policy.retry_base_ms << (item.attempts - 1).min(16)).min(self.policy.retry_cap_ms);
            item.next_ms = now + backoff;
            self.items.push_back(item);
            return None;
        }
        Some(Notice { key: item.key, sent_ms: item.sent_ms, kind: "failed", reason: reason.to_string() })
    }

    /// Drop every queued item older than the fresh window; the one in flight is never cut off
    /// (picked up in time = still fresh).
    pub fn expire_stale(&mut self, now: i64) -> Vec<Notice> {
        let cut = now - self.policy.fresh_ms;
        let mut out = Vec::new();
        self.items.retain(|i| {
            if i.sent_ms < cut {
                let reason = if i.attempts > 0 { "stale_over_5m (after retry)" } else { "stale_over_5m" };
                out.push(Notice { key: i.key.clone(), sent_ms: i.sent_ms, kind: "audio_expired", reason: reason.into() });
                false
            } else {
                true
            }
        });
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn q() -> AudioQueue<u8> {
        AudioQueue::new(Policy::default())
    }

    #[test]
    fn fifo_one_in_flight_and_dedup() {
        let mut q = q();
        assert!(q.enqueue("a".into(), 1_000, 1));
        assert!(q.enqueue("b".into(), 2_000, 2));
        assert!(!q.enqueue("a".into(), 1_000, 1));
        let a = q.take(3_000).unwrap();
        assert_eq!(a.key, "a");
        assert!(q.take(3_000).is_none(), "one at a time");
        assert!(!q.enqueue("a".into(), 1_000, 1), "in flight is a duplicate too");
        q.done("a");
        assert_eq!(q.take(3_000).unwrap().key, "b");
    }

    #[test]
    fn stale_items_expire_and_are_never_handed_out() {
        let mut q = q();
        q.enqueue("old".into(), 0, 0);
        q.enqueue("new".into(), 400_000, 0);
        assert_eq!(q.take(400_001).unwrap().key, "new");
        let expired = q.expire_stale(400_001);
        assert_eq!(expired, vec![Notice { key: "old".into(), sent_ms: 0, kind: "audio_expired", reason: "stale_over_5m".into() }]);
        assert_eq!(q.len(), 0);
    }

    #[test]
    fn in_flight_is_never_cut_off() {
        let mut q = q();
        q.enqueue("a".into(), 0, 0);
        let a = q.take(1).unwrap();
        assert!(q.expire_stale(10_000_000).is_empty());
        q.done(&a.key);
    }

    #[test]
    fn retry_backoff_then_final_failure() {
        let mut q = q();
        q.enqueue("a".into(), 0, 0);
        let a = q.take(0).unwrap();
        assert!(q.fail(a, 0, "download", true).is_none());
        assert!(q.take(9_999).is_none(), "backing off 10 s");
        let a = q.take(10_000).unwrap();
        assert_eq!(a.attempts, 1);
        assert!(q.fail(a, 10_000, "download", true).is_none());
        assert!(q.take(29_999).is_none(), "backoff doubled to 20 s");
        let a = q.take(30_000).unwrap();
        let notice = q.fail(a, 30_000, "download", true).unwrap();
        assert_eq!((notice.kind, notice.reason.as_str()), ("failed", "download"));
    }

    #[test]
    fn permanent_failure_is_final_at_once() {
        let mut q = q();
        q.enqueue("a".into(), 0, 0);
        let a = q.take(0).unwrap();
        assert_eq!(q.fail(a, 0, "no_speech_detected", false).unwrap().kind, "failed");
        assert_eq!(q.len(), 0);
    }

    #[test]
    fn retried_item_still_expires() {
        let mut q = q();
        q.enqueue("a".into(), 0, 0);
        let a = q.take(0).unwrap();
        q.fail(a, 0, "download", true);
        let expired = q.expire_stale(300_001);
        assert_eq!(expired[0].reason, "stale_over_5m (after retry)");
    }
}
