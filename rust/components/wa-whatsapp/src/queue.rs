//! The audio queue: the one place that decides what is transcribed, when, on which lane, and what
//! is given up.
//!
//! Interface (kept small on purpose, so a shared durable queue component - `wa:queue` on WASI 0.3,
//! kv-backed, returning future/stream, with remote STT workers through the relay - can replace it
//! mechanically): `enqueue`, `take_main`, `take_express`, `done`, `fail`, `expire_stale`,
//! `snapshot`, `restore`. Freshness, retry and the timeout alert are policies handed in (`Policy`),
//! not decisions spread through the pipeline; what the queue gives up comes back as `Notice`s that
//! the caller turns into own-chat alerts.
//!
//! Two lanes, as in the Go connector (`connectors/whatsapp/audio_queue.go`, `audioLane`): the main
//! lane takes anything in conversation order; the express lane exists only so a short voice note is
//! not stuck behind a long one - it runs only while the main lane is decoding a long (or
//! unknown-length) note and takes only audio declared at most [`EXPRESS_MAX_SECONDS`].
//!
//! Durability: `snapshot`/`restore` move the queue through the component's kv namespace, so a
//! restart neither forgets queued work nor re-posts a note whose send outcome is unknown (an item
//! that was in flight at the snapshot comes back as an `interrupted_by_restart` notice, never as
//! work: the Go connector's rule is that an unknown send is never retried).
//!
//! Pure logic, no host calls: unit-tested natively (`cargo test`, see `tests/` in the crate).
use std::collections::VecDeque;

/// An express-lane note is declared at most this long (Go: `expressSeconds`).
pub const EXPRESS_MAX_SECONDS: u32 = 90;
/// Most items one snapshot carries, so a stuck queue cannot grow the kv entry without bound.
pub const SNAPSHOT_MAX: usize = 64;
/// Bumped when the snapshot shape changes; an older/newer snapshot is ignored, not guessed.
pub const SNAPSHOT_VERSION: u64 = 1;

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

/// Which lane a decode runs on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Lane {
    Main,
    Express,
}

#[derive(Debug)]
pub struct Item<T> {
    pub key: String,
    pub sent_ms: i64,
    /// The sender-declared length; only routes work to a lane (0 = unknown, treated as long).
    pub seconds: u32,
    pub attempts: u32,
    next_ms: i64,
    pub payload: T,
}

impl<T> Item<T> {
    /// Is this a short note (express-lane candidate)? Unknown length is not: an unknown note is
    /// assumed long, exactly as the Go connector does.
    pub fn short(&self) -> bool {
        self.seconds > 0 && self.seconds <= EXPRESS_MAX_SECONDS
    }
}

/// Something the queue gave up on; the caller logs it and queues an own-chat alert.
#[derive(Clone, Debug, PartialEq)]
pub struct Notice {
    pub key: String,
    pub sent_ms: i64,
    /// `audio_expired` (not picked up in the window), `failed` (retries exhausted / permanent) or
    /// `interrupted_by_restart` (in flight when the component stopped: never re-posted).
    pub kind: &'static str,
    pub reason: String,
}

/// Payloads that survive a restart: a queue item writes itself as JSON and reads itself back.
/// A payload that cannot be read back is dropped, never guessed.
pub trait Persist: Sized {
    fn save(&self) -> serde_json::Value;
    fn load(value: &serde_json::Value) -> Option<Self>;
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Restored {
    /// Items that came back and will be transcribed.
    pub queued: usize,
    /// Items in flight at the snapshot: reported as interruptions, not requeued.
    pub interrupted: usize,
    /// Items whose payload could not be read back (dropped, counted).
    pub dropped: usize,
}

struct Flight {
    key: String,
    sent_ms: i64,
    lane: Lane,
}

pub struct AudioQueue<T> {
    policy: Policy,
    items: VecDeque<Item<T>>,
    flights: Vec<Flight>,
    /// The main lane is decoding a long (or unknown-length) note: the express lane may run.
    main_long: bool,
}

impl<T: Persist> AudioQueue<T> {
    pub fn new(policy: Policy) -> Self {
        AudioQueue { policy, items: VecDeque::new(), flights: Vec::new(), main_long: false }
    }

    pub fn policy(&self) -> Policy {
        self.policy
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    pub fn inflight(&self) -> usize {
        self.flights.len()
    }

    /// Queue an item (conversation order: FIFO). A key already queued or in flight is ignored.
    pub fn enqueue(&mut self, key: String, sent_ms: i64, seconds: u32, payload: T) -> bool {
        if self.flights.iter().any(|f| f.key == key) || self.items.iter().any(|i| i.key == key) {
            return false;
        }
        self.items.push_back(Item { key, sent_ms, seconds, attempts: 0, next_ms: 0, payload });
        true
    }

    /// Forget a queued item: its source was proven revoked/edited, so it is never transcribed. An
    /// item already in flight is left alone (the fence stops it before it posts).
    pub fn drop_key(&mut self, key: &str) -> bool {
        match self.items.iter().position(|i| i.key == key) {
            Some(at) => {
                self.items.remove(at);
                true
            }
            None => false,
        }
    }

    /// The next item due at `now` for the main lane, if any. Stale items are not handed out:
    /// `expire_stale` reports them. One main decode at a time.
    pub fn take_main(&mut self, now: i64) -> Option<Item<T>> {
        if self.flights.iter().any(|f| f.lane == Lane::Main) {
            return None;
        }
        let cut = now - self.policy.fresh_ms;
        let at = self.items.iter().position(|i| i.next_ms <= now && i.sent_ms >= cut)?;
        let item = self.items.remove(at)?;
        self.main_long = !item.short();
        self.flights.push(Flight { key: item.key.clone(), sent_ms: item.sent_ms, lane: Lane::Main });
        Some(item)
    }

    /// The next short note for the express lane, if any. Only while the main lane is decoding a
    /// long note (that is the whole point: two decodes share the CPU only then), and one at a time.
    pub fn take_express(&mut self, now: i64) -> Option<Item<T>> {
        if !self.main_long || self.flights.iter().any(|f| f.lane == Lane::Express) {
            return None;
        }
        let cut = now - self.policy.fresh_ms;
        let at = self.items.iter().position(|i| i.next_ms <= now && i.sent_ms >= cut && i.short())?;
        let item = self.items.remove(at)?;
        self.flights.push(Flight { key: item.key.clone(), sent_ms: item.sent_ms, lane: Lane::Express });
        Some(item)
    }

    /// The in-flight item finished (posted, held, or deliberately skipped).
    pub fn done(&mut self, key: &str) {
        if let Some(at) = self.flights.iter().position(|f| f.key == key) {
            let flight = self.flights.remove(at);
            if flight.lane == Lane::Main {
                self.main_long = false;
            }
        }
    }

    /// The in-flight item failed. A retryable failure goes back with backoff until `max_attempts`;
    /// a permanent one, or the last attempt, is final and comes back as a `failed` notice.
    pub fn fail(&mut self, mut item: Item<T>, now: i64, reason: &str, retryable: bool) -> Option<Notice> {
        self.done(&item.key);
        item.attempts += 1;
        if retryable && item.attempts < self.policy.max_attempts {
            let backoff = self.policy.retry_base_ms.saturating_mul(1 << (item.attempts - 1).min(16)).min(self.policy.retry_cap_ms);
            item.next_ms = now + backoff;
            self.items.push_back(item);
            return None;
        }
        Some(Notice { key: item.key, sent_ms: item.sent_ms, kind: "failed", reason: reason.to_string() })
    }

    /// Drop every queued item older than the fresh window; an item in flight is never cut off
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

    /// Everything the queue holds, as JSON: the queued items and the ones in flight (so a restart
    /// can report them). The newest [`SNAPSHOT_MAX`] items are kept.
    pub fn snapshot(&self, now: i64) -> serde_json::Value {
        let mut items: Vec<&Item<T>> = self.items.iter().collect();
        if items.len() > SNAPSHOT_MAX {
            items.drain(..items.len() - SNAPSHOT_MAX);
        }
        let queued: Vec<serde_json::Value> = items
            .iter()
            .map(|i| {
                serde_json::json!({
                    "key": i.key,
                    "sent_ms": i.sent_ms,
                    "seconds": i.seconds,
                    "attempts": i.attempts,
                    "next_ms": i.next_ms,
                    "payload": i.payload.save(),
                })
            })
            .collect();
        // An in-flight item carries only what the interruption notice needs: the payload is not
        // re-read, because the work is not repeated.
        let inflight: Vec<serde_json::Value> = self
            .flights
            .iter()
            .map(|f| serde_json::json!({"key": f.key, "sent_ms": f.sent_ms, "lane": if f.lane == Lane::Main {"main"} else {"express"}}))
            .collect();
        serde_json::json!({"version": SNAPSHOT_VERSION, "at_ms": now, "queued": queued, "inflight": inflight})
    }

    /// Read a snapshot back. Queued items return in order; the ones that were in flight come back
    /// as `interrupted_by_restart` notices (their send outcome is unknown, so they are never
    /// re-transcribed or re-posted); a payload that cannot be read is dropped and counted.
    pub fn restore(&mut self, snapshot: &serde_json::Value) -> (Restored, Vec<Notice>) {
        let mut report = Restored::default();
        let mut notices = Vec::new();
        if snapshot["version"].as_u64() != Some(SNAPSHOT_VERSION) {
            return (report, notices);
        }
        for entry in snapshot["inflight"].as_array().map(|a| a.as_slice()).unwrap_or_default() {
            let Some(key) = entry["key"].as_str() else { continue };
            report.interrupted += 1;
            notices.push(Notice {
                key: key.to_string(),
                sent_ms: entry["sent_ms"].as_i64().unwrap_or(0),
                kind: "interrupted_by_restart",
                reason: "unknown_send_after_restart".into(),
            });
        }
        for entry in snapshot["queued"].as_array().map(|a| a.as_slice()).unwrap_or_default() {
            let key = entry["key"].as_str().unwrap_or("");
            let sent_ms = entry["sent_ms"].as_i64().unwrap_or(0);
            match T::load(&entry["payload"]) {
                Some(payload) if !key.is_empty() => {
                    if self.enqueue(key.to_string(), sent_ms, entry["seconds"].as_u64().unwrap_or(0) as u32, payload) {
                        // A retried item keeps its backoff and attempt count across the restart.
                        let attempts = entry["attempts"].as_u64().unwrap_or(0) as u32;
                        let next_ms = entry["next_ms"].as_i64().unwrap_or(0);
                        if let Some(item) = self.items.back_mut() {
                            item.attempts = attempts;
                            item.next_ms = next_ms;
                        }
                        report.queued += 1;
                    }
                }
                _ => report.dropped += 1,
            }
        }
        (report, notices)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A payload good enough to test the queue: the chat/id plus a marker.
    #[derive(Debug, PartialEq)]
    struct Job {
        id: String,
        label: String,
    }

    impl Persist for Job {
        fn save(&self) -> serde_json::Value {
            serde_json::json!({"id": self.id, "label": self.label})
        }
        fn load(v: &serde_json::Value) -> Option<Self> {
            Some(Job { id: v["id"].as_str()?.to_string(), label: v["label"].as_str().unwrap_or("").to_string() })
        }
    }

    fn job(id: &str) -> Job {
        Job { id: id.into(), label: format!("l-{id}") }
    }

    fn q() -> AudioQueue<Job> {
        AudioQueue::new(Policy::default())
    }

    #[test]
    fn fifo_one_in_flight_and_dedup() {
        let mut q = q();
        assert!(q.enqueue("a".into(), 1_000, 10, job("a")));
        assert!(q.enqueue("b".into(), 2_000, 10, job("b")));
        assert!(!q.enqueue("a".into(), 1_000, 10, job("a")));
        let a = q.take_main(3_000).unwrap();
        assert_eq!(a.key, "a");
        assert!(q.take_main(3_000).is_none(), "one main decode at a time");
        assert!(q.take_express(3_000).is_none(), "the main lane took a short note: no express");
        assert!(!q.enqueue("a".into(), 1_000, 10, job("a")), "in flight is a duplicate too");
        q.done("a");
        assert_eq!(q.take_main(3_000).unwrap().key, "b");
    }

    #[test]
    fn stale_items_expire_and_are_never_handed_out() {
        let mut q = q();
        q.enqueue("old".into(), 0, 5, job("old"));
        q.enqueue("new".into(), 400_000, 5, job("new"));
        assert_eq!(q.take_main(400_001).unwrap().key, "new");
        let expired = q.expire_stale(400_001);
        assert_eq!(expired, vec![Notice { key: "old".into(), sent_ms: 0, kind: "audio_expired", reason: "stale_over_5m".into() }]);
        assert_eq!(q.len(), 0);
    }

    #[test]
    fn in_flight_is_never_cut_off() {
        let mut q = q();
        q.enqueue("a".into(), 0, 600, job("a"));
        let a = q.take_main(1).unwrap();
        assert!(q.expire_stale(10_000_000).is_empty());
        q.done(&a.key);
    }

    #[test]
    fn retry_backoff_then_final_failure() {
        let mut q = q();
        q.enqueue("a".into(), 0, 5, job("a"));
        let a = q.take_main(0).unwrap();
        assert!(q.fail(a, 0, "download", true).is_none());
        assert!(q.take_main(9_999).is_none(), "backing off 10 s");
        let a = q.take_main(10_000).unwrap();
        assert_eq!(a.attempts, 1);
        assert!(q.fail(a, 10_000, "download", true).is_none());
        assert!(q.take_main(29_999).is_none(), "backoff doubled to 20 s");
        let a = q.take_main(30_000).unwrap();
        let notice = q.fail(a, 30_000, "download", true).unwrap();
        assert_eq!((notice.kind, notice.reason.as_str()), ("failed", "download"));
    }

    #[test]
    fn permanent_failure_is_final_at_once() {
        let mut q = q();
        q.enqueue("a".into(), 0, 5, job("a"));
        let a = q.take_main(0).unwrap();
        assert_eq!(q.fail(a, 0, "no_speech_detected", false).unwrap().kind, "failed");
        assert_eq!(q.len(), 0);
    }

    #[test]
    fn retried_item_still_expires() {
        let mut q = q();
        q.enqueue("a".into(), 0, 5, job("a"));
        let a = q.take_main(0).unwrap();
        q.fail(a, 0, "download", true);
        let expired = q.expire_stale(300_001);
        assert_eq!(expired[0].reason, "stale_over_5m (after retry)");
    }

    // ---- the express lane -------------------------------------------------------------------

    #[test]
    fn express_lane_waits_for_a_long_main_decode_and_takes_only_short_notes() {
        let mut q = q();
        q.enqueue("short".into(), 0, 30, job("short"));
        q.enqueue("long".into(), 0, 300, job("long"));
        assert!(q.take_express(0).is_none(), "main lane is idle: nothing to get out of the way of");
        // The main lane picks the first note in conversation order: the short one, so it is not
        // long. A main lane that took a long note opens the express lane.
        let first = q.take_main(0).unwrap();
        assert_eq!(first.key, "short");
        assert!(q.take_express(0).is_none(), "short main decode does not open the express lane");
        q.done("short");
        let long = q.take_main(0).unwrap();
        assert_eq!(long.key, "long");
        assert!(q.take_express(0).is_none(), "no short note left");
        q.enqueue("short2".into(), 0, 45, job("short2"));
        assert_eq!(q.take_express(0).unwrap().key, "short2");
        assert!(q.take_express(0).is_none(), "one express decode at a time");
        q.enqueue("long2".into(), 0, 600, job("long2"));
        assert!(q.take_main(0).is_none(), "the main lane is still decoding the long note");
        q.done("long");
        assert!(q.take_express(0).is_none(), "the express lane closes when the long main decode ends");
        assert_eq!(q.take_main(0).unwrap().key, "long2", "long notes are main-lane work");
        q.done("long2");
        q.done("short2");
        assert_eq!(q.inflight(), 0);
    }

    #[test]
    fn express_never_takes_a_long_or_unknown_length_note() {
        let mut q = q();
        q.enqueue("long".into(), 0, 300, job("long"));
        q.enqueue("unknown".into(), 0, 0, job("unknown"));
        let long = q.take_main(0).unwrap();
        assert!(q.take_express(0).is_none(), "300 s and unknown length are both main-lane work");
        q.done(&long.key);
        let unknown = q.take_main(0).unwrap();
        q.enqueue("edge".into(), 0, EXPRESS_MAX_SECONDS, job("edge"));
        assert_eq!(q.take_express(0).unwrap().key, "edge", "exactly the limit is short");
        q.done(&unknown.key);
        q.done("edge");
    }

    #[test]
    fn a_proven_fence_drops_queued_work_but_not_work_in_flight() {
        let mut q = q();
        q.enqueue("c\u{0}m1".into(), 1_000, 10, job("m1"));
        q.enqueue("c\u{0}m2".into(), 2_000, 10, job("m2"));
        assert!(q.drop_key("c\u{0}m1"));
        assert!(!q.drop_key("c\u{0}m9"), "unknown keys are not dropped");
        let item = q.take_main(3_000).unwrap();
        assert_eq!(item.key, "c\u{0}m2");
        assert!(!q.drop_key("c\u{0}m2"), "in flight is not silently dropped");
        q.done(&item.key);
    }

    // ---- durability -------------------------------------------------------------------------

    #[test]
    fn snapshot_and_restore_keep_queued_work_in_order() {
        let mut q = q();
        q.enqueue("a".into(), 1_000, 10, job("a"));
        q.enqueue("b".into(), 2_000, 300, job("b"));
        let snap = q.snapshot(2_500);
        let mut fresh = AudioQueue::<Job>::new(Policy::default());
        let (report, notices) = fresh.restore(&snap);
        assert_eq!(report, Restored { queued: 2, interrupted: 0, dropped: 0 });
        assert!(notices.is_empty());
        assert_eq!(fresh.len(), 2);
        assert_eq!(fresh.take_main(3_000).unwrap().payload, job("a"));
        fresh.done("a");
        assert_eq!(fresh.take_main(3_000).unwrap().payload, job("b"));
    }

    #[test]
    fn a_restart_reports_in_flight_work_instead_of_reposting_it() {
        let mut q = q();
        q.enqueue("posted-maybe".into(), 1_000, 300, job("posted-maybe"));
        let item = q.take_main(1_000).unwrap();
        let snap = q.snapshot(1_100);
        assert_eq!(snap["inflight"].as_array().unwrap().len(), 1);
        let mut fresh = AudioQueue::<Job>::new(Policy::default());
        let (report, notices) = fresh.restore(&snap);
        assert_eq!(report, Restored { queued: 0, interrupted: 1, dropped: 0 });
        assert_eq!(notices[0].key, item.key);
        assert_eq!(notices[0].kind, "interrupted_by_restart");
        assert!(fresh.take_main(1_200).is_none(), "never re-transcribed or re-posted");
    }

    #[test]
    fn restore_drops_unreadable_payloads_and_foreign_versions() {
        let mut q = q();
        q.enqueue("a".into(), 1_000, 10, job("a"));
        let mut snap = q.snapshot(1_000);
        snap["queued"][0]["payload"] = serde_json::json!({"nonsense": true});
        snap["queued"].as_array_mut().unwrap().push(serde_json::json!({"key": "b", "sent_ms": 1, "payload": {"id": "b"}}));
        let mut fresh = AudioQueue::<Job>::new(Policy::default());
        let (report, _) = fresh.restore(&snap);
        assert_eq!((report.queued, report.dropped), (1, 1));
        let mut older = AudioQueue::<Job>::new(Policy::default());
        let (report, notices) = older.restore(&serde_json::json!({"version": SNAPSHOT_VERSION + 1, "queued": [{"key": "a", "payload": {"id": "a"}}]}));
        assert_eq!(report, Restored::default());
        assert!(notices.is_empty() && older.is_empty());
    }

    #[test]
    fn a_retried_item_keeps_its_backoff_across_a_restart() {
        let mut q = q();
        q.enqueue("a".into(), 0, 10, job("a"));
        let a = q.take_main(0).unwrap();
        q.fail(a, 0, "download", true);
        let snap = q.snapshot(1);
        let mut fresh = AudioQueue::<Job>::new(Policy::default());
        fresh.restore(&snap);
        assert!(fresh.take_main(9_999).is_none(), "backoff survives the restart");
        let again = fresh.take_main(10_000).unwrap();
        assert_eq!(again.attempts, 1);
    }

    #[test]
    fn a_snapshot_is_bounded() {
        let mut q = q();
        for i in 0..SNAPSHOT_MAX + 10 {
            q.enqueue(format!("k{i}"), i as i64 + 1, 5, job("x"));
        }
        let snap = q.snapshot(1_000);
        assert_eq!(snap["queued"].as_array().unwrap().len(), SNAPSHOT_MAX);
        assert_eq!(snap["queued"][0]["key"], format!("k{}", 10), "the newest survive");
    }
}
