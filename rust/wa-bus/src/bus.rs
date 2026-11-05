//! The bus itself: subscriptions, delivery, retention, revocation.
//!
//! One `Bus` is one node-local fan-out point. Publishers hand it an event; it copies it into the
//! bounded buffer of every matching subscription. There is exactly one mutex for the whole bus and a
//! condvar for the `Block` overflow policy, so ordering is FIFO per subscriber and the code stays
//! small enough to reason about — the queue (durable, one consumer) is elsewhere; this is the
//! many-consumer side and has no claim on an event.
//!
//! Three invariants the tests hold down:
//! 1. **Order** — events in a subscriber's buffer are in publish order per topic, and a subscriber
//!    never sees an older event after a newer one.
//! 2. **No silent loss** — an event is either delivered, or dropped and counted (`dropped`), or
//!    refused and reported (`PublishOutcome::blocked`). Nothing disappears quietly.
//! 3. **Revocation is exact** — dropping a `Subscription` or `revoke_owner` removes the buffer at
//!    once, so a stopped component cannot be handed one more event.

use crate::access::{Access, NamespaceAcl};
use crate::event::{now_ms, Event, EventId};
use crate::kv::{self, Kv};
use crate::topic::{Pattern, Topic, TopicError};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fmt;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// A subscription's identity inside one bus.
pub type SubscriptionId = u64;

/// Buffer length a subscription gets when it does not ask for one.
pub const DEFAULT_CAPACITY: usize = 64;
/// Retained events for a durable topic when `enable_durable` is not given a number.
pub const DEFAULT_RETAIN: usize = 32;

/// What happens when a subscriber's buffer is full.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverflowPolicy {
    /// Drop the oldest queued event and keep the new one (default). Good for a "latest state" or
    /// logging subscriber: it loses history, never the present. Counted in `dropped`.
    DropOldest,
    /// Refuse the new event for this subscriber and keep what is queued. Good for a subscriber that
    /// processes in batches and would rather be complete on an old snapshot than skip within it.
    DropNewest,
    /// Never drop for this subscriber: the publisher waits for space (or is told `blocked` when it
    /// will not wait). Good for a critical subscriber (`index`, `audit`). A producer that cannot wait
    /// sees the event in `PublishOutcome::blocked` and can retry: no silent loss either way.
    Block,
}

impl OverflowPolicy {
    pub fn as_str(self) -> &'static str {
        match self {
            OverflowPolicy::DropOldest => "drop_oldest",
            OverflowPolicy::DropNewest => "drop_newest",
            OverflowPolicy::Block => "block",
        }
    }
}

impl fmt::Display for OverflowPolicy {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// How a subscription wants to be fed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SubscribeOptions {
    pub capacity: usize,
    pub policy: OverflowPolicy,
}

impl Default for SubscribeOptions {
    fn default() -> Self {
        SubscribeOptions { capacity: DEFAULT_CAPACITY, policy: OverflowPolicy::DropOldest }
    }
}

impl SubscribeOptions {
    pub fn new() -> SubscribeOptions {
        SubscribeOptions::default()
    }

    pub fn with_capacity(mut self, capacity: usize) -> SubscribeOptions {
        self.capacity = capacity;
        self
    }

    pub fn with_policy(mut self, policy: OverflowPolicy) -> SubscribeOptions {
        self.policy = policy;
        self
    }
}

/// Why a bus call was refused. A refusal is an error the caller sees, not a log line: publish and
/// subscribe either happen or say why they did not.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BusError {
    /// The topic or pattern is not valid.
    Topic(TopicError),
    /// The access policy said no.
    Denied { component: String, action: &'static str, subject: String },
    /// The durable store failed (the message is the store's, and never contains a payload).
    Store(String),
    /// Catch-up was asked for on a topic that has no retention configured.
    ReplayNotDurable(String),
    /// Catch-up was asked for on a wildcard; retention is per topic.
    ReplayNeedsExactTopic(String),
    /// Bad subscription options (a buffer must hold at least one event).
    BadOptions(&'static str),
}

impl fmt::Display for BusError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BusError::Topic(e) => write!(f, "invalid topic: {e}"),
            BusError::Denied { component, action, subject } => {
                write!(f, "bus_{action}_denied:{component}:{subject}")
            }
            BusError::Store(why) => write!(f, "bus_store_failed:{why}"),
            BusError::ReplayNotDurable(t) => write!(f, "bus_replay_not_durable:{t}"),
            BusError::ReplayNeedsExactTopic(p) => write!(f, "bus_replay_needs_exact_topic:{p}"),
            BusError::BadOptions(why) => write!(f, "bus_bad_options:{why}"),
        }
    }
}

impl std::error::Error for BusError {}

impl From<TopicError> for BusError {
    fn from(e: TopicError) -> BusError {
        BusError::Topic(e)
    }
}

/// What one publish did. Rocksolid for the caller: `matched` is how many subscriptions the topic hit,
/// `delivered` how many copies went in, `dropped` how many events an overflow policy discarded, and
/// `blocked` the subscriptions that refused it (empty unless a `Block` buffer was full).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PublishOutcome {
    pub id: EventId,
    pub matched: usize,
    pub delivered: usize,
    pub dropped: usize,
    pub blocked: Vec<SubscriptionId>,
}

impl PublishOutcome {
    /// True when no subscriber refused the event. Dropped copies are still a `false` for a producer
    /// that cares about loss: check `dropped` too.
    pub fn accepted_by_all(&self) -> bool {
        self.blocked.is_empty()
    }

    /// True when every matching subscriber got the event (nothing blocked, nothing dropped).
    pub fn complete(&self) -> bool {
        self.blocked.is_empty() && self.dropped == 0
    }
}

/// One subscription as the bus sees it. For `status`/logs, not for delivery.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubscriptionInfo {
    pub id: SubscriptionId,
    pub owner: String,
    pub pattern: String,
    pub policy: OverflowPolicy,
    pub queued: usize,
    pub capacity: usize,
    pub dropped: u64,
    pub blocked: u64,
}

struct Sub {
    owner: String,
    pattern: Pattern,
    queue: VecDeque<Event>,
    capacity: usize,
    policy: OverflowPolicy,
    dropped: u64,
    blocked: u64,
    replayed: usize,
}

struct Durable {
    retain: usize,
    kv: Arc<dyn Kv>,
}

struct Inner {
    next_id: u64,
    next_sub: u64,
    subs: BTreeMap<SubscriptionId, Sub>,
    access: Arc<dyn Access>,
    durable: BTreeMap<String, Durable>,
}

struct Shared {
    state: Mutex<Inner>,
    space: Condvar,
}

/// A node-local event bus. Cloning shares the same bus (it is an `Arc` inside).
#[derive(Clone)]
pub struct Bus {
    shared: Arc<Shared>,
}

impl Default for Bus {
    fn default() -> Bus {
        Bus::new()
    }
}

impl fmt::Debug for Bus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let inner = self.lock();
        f.debug_struct("Bus")
            .field("subscriptions", &inner.subs.len())
            .field("durable_topics", &inner.durable.len())
            .finish()
    }
}

impl Bus {
    /// A bus with the default policy: own namespace only, no grants, no durable topics.
    pub fn new() -> Bus {
        Bus::with_access(Arc::new(NamespaceAcl::new()))
    }

    /// A bus with a host-supplied access policy.
    pub fn with_access(access: Arc<dyn Access>) -> Bus {
        Bus {
            shared: Arc::new(Shared {
                state: Mutex::new(Inner {
                    next_id: 1,
                    next_sub: 1,
                    subs: BTreeMap::new(),
                    access,
                    durable: BTreeMap::new(),
                }),
                space: Condvar::new(),
            }),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.shared.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Replace the access policy (a node that loads grants later, or adds a manifest).
    pub fn set_access(&self, access: Arc<dyn Access>) {
        self.lock().access = access;
    }

    // ---- publish -----------------------------------------------------------------------------------

    /// Publish without waiting. A full `Block` subscriber is reported, not waited for.
    pub fn publish(&self, event: Event) -> Result<PublishOutcome, BusError> {
        self.deliver(event, None)
    }

    /// Publish, waiting up to `timeout` for a `Block` subscriber to make room. If the deadline passes
    /// the event is **not** silently dropped for that subscriber: it comes back in
    /// `PublishOutcome::blocked` and the producer decides (retry, log, or drop it itself).
    pub fn publish_blocking(
        &self,
        event: Event,
        timeout: Duration,
    ) -> Result<PublishOutcome, BusError> {
        self.deliver(event, Some(timeout))
    }

    fn deliver(&self, mut event: Event, wait: Option<Duration>) -> Result<PublishOutcome, BusError> {
        // The policy is called with the lock released, so a host ACL may take its own locks.
        let access = { self.lock().access.clone() };
        if !access.may_publish(&event.source, &event.topic) {
            return Err(BusError::Denied {
                component: event.source.clone(),
                action: "publish",
                subject: event.topic.as_str().to_string(),
            });
        }
        let deadline = wait.map(|w| Instant::now() + w);
        let mut guard = self.lock();

        if event.id.is_assigned() {
            // A caller that sets its own id (a replayer, a durable writer) never collides with the
            // ids this bus hands out: the counter moves past it.
            guard.next_id = guard.next_id.max(event.id.0.saturating_add(1));
        } else {
            event.id = EventId(guard.next_id);
            guard.next_id += 1;
        }
        if event.ts_ms == 0 {
            event.ts_ms = now_ms();
        }

        // Durable append + trim happen under the lock so a reader never sees a half-trimmed log and
        // two publishers cannot delete each other's newest record. Retention is a small kv; a host
        // that needs an fsync per event wants a queue, not a bus (docs/BUS.md).
        if let Some(d) = guard.durable.get(event.topic.as_str()) {
            let kv = d.kv.clone();
            let retain = d.retain;
            let key = kv::retention_key(&event.topic, event.ts_ms, event.id);
            kv.put(&key, &event.encode()).map_err(|e| BusError::Store(e.to_string()))?;
            let prefix = kv::retention_prefix(&event.topic);
            let mut rows = kv.scan_prefix(&prefix, 0).map_err(|e| BusError::Store(e.to_string()))?;
            let mut drop_n = rows.len().saturating_sub(retain);
            for (old, _) in rows.drain(..) {
                if drop_n == 0 {
                    break;
                }
                drop_n -= 1;
                kv.del(&old).map_err(|e| BusError::Store(e.to_string()))?;
            }
        }

        let targets: Vec<SubscriptionId> = guard
            .subs
            .iter()
            .filter(|(_, s)| s.pattern.matches(&event.topic))
            .map(|(id, _)| *id)
            .collect();
        let mut outcome = PublishOutcome { id: event.id, matched: targets.len(), ..Default::default() };
        let mut counted: BTreeSet<SubscriptionId> = BTreeSet::new();
        let mut pending = targets;

        loop {
            let mut waiting = Vec::new();
            for id in pending.drain(..) {
                // A subscription revoked between matching and delivery is simply gone: it is not
                // recreated, and it is not reported as blocked.
                let Some(sub) = guard.subs.get_mut(&id) else { continue };
                if sub.queue.len() < sub.capacity {
                    sub.queue.push_back(event.clone());
                    outcome.delivered += 1;
                    continue;
                }
                match sub.policy {
                    OverflowPolicy::DropOldest => {
                        sub.queue.pop_front();
                        sub.dropped += 1;
                        sub.queue.push_back(event.clone());
                        outcome.delivered += 1;
                        outcome.dropped += 1;
                    }
                    OverflowPolicy::DropNewest => {
                        sub.dropped += 1;
                        outcome.dropped += 1;
                    }
                    OverflowPolicy::Block => {
                        if counted.insert(id) {
                            sub.blocked += 1;
                        }
                        waiting.push(id);
                    }
                }
            }
            if waiting.is_empty() {
                return Ok(outcome);
            }
            let Some(deadline) = deadline else {
                outcome.blocked = waiting;
                return Ok(outcome);
            };
            let now = Instant::now();
            if now >= deadline {
                outcome.blocked = waiting;
                return Ok(outcome);
            }
            let remaining = deadline - now;
            let (g, _timeout) = self
                .shared
                .space
                .wait_timeout(guard, remaining)
                .unwrap_or_else(|e| e.into_inner());
            guard = g;
            pending = waiting;
        }
    }

    // ---- subscribe ---------------------------------------------------------------------------------

    /// Subscribe to a pattern (`"a.b"`, `"a.*"`, `"*"`) as `owner`. The handle *is* the subscription:
    /// dropping it unsubscribes, exactly as the kernel's revocable registrations require.
    pub fn subscribe(
        &self,
        owner: &str,
        pattern: &str,
        options: SubscribeOptions,
    ) -> Result<Subscription, BusError> {
        self.subscribe_with(owner, Pattern::parse(pattern)?, options, None)
    }

    /// Subscribe from an already-validated pattern.
    pub fn subscribe_pattern(
        &self,
        owner: &str,
        pattern: Pattern,
        options: SubscribeOptions,
    ) -> Result<Subscription, BusError> {
        self.subscribe_with(owner, pattern, options, None)
    }

    /// Subscribe to one durable topic and preload up to `limit` retained events (oldest first) into
    /// the new buffer, so a consumer that starts late is not blind. The buffer is filled to at most
    /// `options.capacity` events, keeping the newest ones: drain it before relying on live delivery.
    ///
    /// Catch-up is at-least-once over the retention window. Dedupe with `Event::id` if the same
    /// events may also have been seen before a restart.
    pub fn subscribe_replaying(
        &self,
        owner: &str,
        topic: &str,
        options: SubscribeOptions,
        limit: usize,
    ) -> Result<Subscription, BusError> {
        let topic = Topic::parse(topic)?;
        self.subscribe_with(owner, Pattern::Exact(topic), options, Some(limit))
    }

    pub(crate) fn subscribe_with(
        &self,
        owner: &str,
        pattern: Pattern,
        options: SubscribeOptions,
        replay: Option<usize>,
    ) -> Result<Subscription, BusError> {
        if options.capacity == 0 {
            return Err(BusError::BadOptions("capacity must be at least 1"));
        }
        let access = { self.lock().access.clone() };
        if !access.may_subscribe(owner, &pattern) {
            return Err(BusError::Denied {
                component: owner.to_string(),
                action: "subscribe",
                subject: pattern.as_written(),
            });
        }
        let mut guard = self.lock();

        let mut queue = VecDeque::new();
        let mut replayed = 0usize;
        if let Some(limit) = replay {
            let Pattern::Exact(topic) = &pattern else {
                return Err(BusError::ReplayNeedsExactTopic(pattern.as_written()));
            };
            let Some(d) = guard.durable.get(topic.as_str()) else {
                return Err(BusError::ReplayNotDurable(topic.as_str().to_string()));
            };
            let rows = d
                .kv
                .scan_prefix(&kv::retention_prefix(topic), 0)
                .map_err(|e| BusError::Store(e.to_string()))?;
            let mut events = Vec::with_capacity(rows.len());
            for (key, value) in rows {
                let event = Event::decode(&value).map_err(|e| {
                    BusError::Store(format!(
                        "retained record {} unreadable: {e}",
                        String::from_utf8_lossy(&key)
                    ))
                })?;
                events.push(event);
            }
            let keep = events.len().min(limit).min(options.capacity);
            for event in events.drain(events.len() - keep..) {
                queue.push_back(event);
            }
            replayed = keep;
        }

        let id = guard.next_sub;
        guard.next_sub += 1;
        let pattern_for_handle = pattern.clone();
        guard.subs.insert(
            id,
            Sub {
                owner: owner.to_string(),
                pattern,
                queue,
                capacity: options.capacity,
                policy: options.policy,
                dropped: 0,
                blocked: 0,
                replayed,
            },
        );
        Ok(Subscription {
            shared: self.shared.clone(),
            id,
            owner: owner.to_string(),
            pattern: pattern_for_handle,
        })
    }

    // ---- retention ---------------------------------------------------------------------------------

    /// Keep the last `retain` events of `topic` in `kv`. Default for every topic is no retention.
    pub fn enable_durable(
        &self,
        topic: &str,
        retain: usize,
        kv: Arc<dyn Kv>,
    ) -> Result<(), BusError> {
        if retain == 0 {
            return Err(BusError::BadOptions("retain must be at least 1"));
        }
        let topic = Topic::parse(topic)?;
        self.lock()
            .durable
            .insert(topic.as_str().to_string(), Durable { retain, kv });
        Ok(())
    }

    /// Stop retaining a topic. Already-stored events stay until the next publish past `retain`
    /// (or the host deletes them); this only stops the bus writing.
    pub fn disable_durable(&self, topic: &str) {
        self.lock().durable.remove(topic);
    }

    /// The durable topics and their retention, for `status`.
    pub fn durable_topics(&self) -> Vec<(String, usize)> {
        self.lock()
            .durable
            .iter()
            .map(|(t, d)| (t.clone(), d.retain))
            .collect()
    }

    /// The retained events of one topic, oldest first.
    pub fn retained(&self, topic: &str, limit: usize) -> Result<Vec<Event>, BusError> {
        let topic = Topic::parse(topic)?;
        let guard = self.lock();
        let Some(d) = guard.durable.get(topic.as_str()) else {
            return Err(BusError::ReplayNotDurable(topic.as_str().to_string()));
        };
        let rows = d
            .kv
            .scan_prefix(&kv::retention_prefix(&topic), 0)
            .map_err(|e| BusError::Store(e.to_string()))?;
        let mut out = Vec::with_capacity(rows.len());
        for (key, value) in rows {
            out.push(Event::decode(&value).map_err(|e| {
                BusError::Store(format!(
                    "retained record {} unreadable: {e}",
                    String::from_utf8_lossy(&key)
                ))
            })?);
        }
        if limit != 0 && out.len() > limit {
            out.drain(..out.len() - limit);
        }
        Ok(out)
    }

    // ---- revocation --------------------------------------------------------------------------------

    /// Close every subscription owned by `owner` (a component stopped, or was replaced). Returns how
    /// many handles were revoked.
    pub fn revoke_owner(&self, owner: &str) -> usize {
        let mut guard = self.lock();
        let ids: Vec<SubscriptionId> = guard
            .subs
            .iter()
            .filter(|(_, s)| s.owner == owner)
            .map(|(id, _)| *id)
            .collect();
        for id in &ids {
            guard.subs.remove(id);
        }
        if !ids.is_empty() {
            self.shared.space.notify_all();
        }
        ids.len()
    }

    /// Close every subscription (node shutdown). Returns how many were revoked.
    pub fn revoke_all(&self) -> usize {
        let mut guard = self.lock();
        let n = guard.subs.len();
        guard.subs.clear();
        if n != 0 {
            self.shared.space.notify_all();
        }
        n
    }

    /// One row per live subscription, for `status`.
    pub fn subscriptions(&self) -> Vec<SubscriptionInfo> {
        let guard = self.lock();
        guard
            .subs
            .iter()
            .map(|(id, s)| SubscriptionInfo {
                id: *id,
                owner: s.owner.clone(),
                pattern: s.pattern.as_written(),
                policy: s.policy,
                queued: s.queue.len(),
                capacity: s.capacity,
                dropped: s.dropped,
                blocked: s.blocked,
            })
            .collect()
    }

    pub fn subscriber_count(&self) -> usize {
        self.lock().subs.len()
    }
}

/// A live subscription. Drop it (or call [`Subscription::close`]) to unsubscribe.
pub struct Subscription {
    shared: Arc<Shared>,
    id: SubscriptionId,
    owner: String,
    pattern: Pattern,
}

impl fmt::Debug for Subscription {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Subscription")
            .field("id", &self.id)
            .field("owner", &self.owner)
            .field("pattern", &self.pattern.as_written())
            .finish()
    }
}

impl Subscription {
    pub fn id(&self) -> SubscriptionId {
        self.id
    }

    pub fn owner(&self) -> &str {
        &self.owner
    }

    pub fn pattern(&self) -> &Pattern {
        &self.pattern
    }

    /// The next queued event, or `None` when the buffer is empty or the subscription was revoked.
    pub fn recv(&self) -> Option<Event> {
        let mut guard = self.lock();
        let (out, freed) = match guard.subs.get_mut(&self.id) {
            Some(sub) => {
                let was_full = sub.queue.len() >= sub.capacity;
                (sub.queue.pop_front(), was_full)
            }
            None => (None, false),
        };
        drop(guard);
        if freed {
            self.shared.space.notify_all();
        }
        out
    }

    /// Up to `max` events, oldest first. `max == 0` means everything queued.
    pub fn drain(&self, max: usize) -> Vec<Event> {
        let mut guard = self.lock();
        let (out, freed) = match guard.subs.get_mut(&self.id) {
            Some(sub) => {
                let was_full = sub.queue.len() >= sub.capacity;
                let take = if max == 0 { sub.queue.len() } else { max.min(sub.queue.len()) };
                let free: usize = take;
                let out: Vec<Event> = sub.queue.drain(..take).collect();
                (out, was_full && free > 0)
            }
            None => (Vec::new(), false),
        };
        drop(guard);
        if freed {
            self.shared.space.notify_all();
        }
        out
    }

    pub fn is_closed(&self) -> bool {
        !self.lock().subs.contains_key(&self.id)
    }

    /// Unsubscribe now. Returns true if this handle was still live.
    pub fn close(&self) -> bool {
        let mut guard = self.lock();
        let removed = guard.subs.remove(&self.id).is_some();
        drop(guard);
        if removed {
            self.shared.space.notify_all();
        }
        removed
    }

    pub fn queued(&self) -> usize {
        self.lock().subs.get(&self.id).map(|s| s.queue.len()).unwrap_or(0)
    }

    pub fn capacity(&self) -> usize {
        self.lock().subs.get(&self.id).map(|s| s.capacity).unwrap_or(0)
    }

    pub fn policy(&self) -> Option<OverflowPolicy> {
        self.lock().subs.get(&self.id).map(|s| s.policy)
    }

    /// Events this subscription lost to its overflow policy since it was created.
    pub fn dropped(&self) -> u64 {
        self.lock().subs.get(&self.id).map(|s| s.dropped).unwrap_or(0)
    }

    /// Publishes this subscription refused because its buffer was full (`Block` policy).
    pub fn blocked(&self) -> u64 {
        self.lock().subs.get(&self.id).map(|s| s.blocked).unwrap_or(0)
    }

    /// Retained events preloaded by `subscribe_replaying`.
    pub fn replayed(&self) -> usize {
        self.lock().subs.get(&self.id).map(|s| s.replayed).unwrap_or(0)
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.shared.state.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Drop for Subscription {
    fn drop(&mut self) {
        // Dropping the handle is the unsubscribe: no separate "cancel" call to forget.
        self.close();
    }
}
