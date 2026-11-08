//! Presence: what every node says about itself, and the view each node keeps of the others.
//!
//! A heartbeat is small on purpose — an identity, the capabilities this node can serve, three load
//! numbers, a version and the sender's clock. It is advisory: a sample says what was true a moment
//! ago and reserves nothing (`docs/FABRIC.md`, "A sample is not a reservation"). Placement reads it,
//! admission stays local.
//!
//! The view is **TTL, not gossip**: a peer is live while its last heartbeat is younger than
//! `stale_after_beats` × `heartbeat_ms` (3 beats, 9 s at the default 3 s cadence), so three lost
//! datagrams in a row — or a machine that powered off — remove it from placement without anybody
//! announcing a departure. Age is measured on the **receiver's** clock: a peer with a wrong clock can
//! only make itself look late, never fresh.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use serde_json::{json, Value};

use crate::wire;

/// How often a node publishes its heartbeat. The brief is 2–5 s; 3 s is the middle, and three missed
/// beats (9 s) is long enough to ride out one slow tick and short enough that a powered-off machine
/// stops attracting work quickly.
pub const DEFAULT_HEARTBEAT_MS: i64 = 3_000;

/// A peer is stale after this many missed beats. Three, because one missed beat is a stall and two is
/// a hiccup; by the third the machine is either gone or too busy to be a candidate.
pub const STALE_AFTER_BEATS: u32 = 3;

/// The longest node id the wire accepts, matching the queue's worker-name bound.
pub const MAX_NODE_ID: usize = 64;

/// The longest capability word, and how many one node may advertise.
pub const MAX_CAPABILITY: usize = 32;
pub const MAX_CAPABILITIES: usize = 32;

/// The longest version string, one line.
pub const MAX_VERSION: usize = 32;

/// A node identity, as the transport names it. Validated once, at the edge: an id is printed in logs,
/// used as a queue worker name and compared for equality, so a control character or a path separator
/// must never get in.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct NodeId(String);

impl NodeId {
    /// Accept `1..=MAX_NODE_ID` of `[A-Za-z0-9._:-]`. Everything else is refused by name, not
    /// mangled: a node whose id cannot be spelled in the fabric's alphabet cannot join it.
    pub fn new(id: impl Into<String>) -> Option<NodeId> {
        let id = id.into();
        if id.is_empty() || id.len() > MAX_NODE_ID {
            return None;
        }
        if !id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-')) {
            return None;
        }
        Some(NodeId(id))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_string(self) -> String {
        self.0
    }
}

impl fmt::Display for NodeId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// One thing a node can do: `stt`, `ocr`, `embed`, `index`, `build`, or a word this crate has never
/// heard of. The set is open so a new job kind needs no change here.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Capability(String);

impl Capability {
    /// Lower-case `[a-z0-9-]`, 1..=`MAX_CAPABILITY`. Upper case is folded rather than refused: a
    /// manifest is a person's typing, and `STT` and `stt` are the same capability.
    pub fn new(word: impl AsRef<str>) -> Capability {
        let folded = word.as_ref().trim().to_ascii_lowercase();
        let bounded: String = folded
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
            .take(MAX_CAPABILITY)
            .collect();
        Capability(bounded)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl fmt::Display for Capability {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// A node's capability set. Ordered, so two equal sets print identically and a test can compare them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Capabilities(BTreeSet<Capability>);

impl Capabilities {
    /// Build from anything iterable of words, dropping the ones that are not spellable.
    pub fn of<I, S>(words: I) -> Capabilities
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let mut set = BTreeSet::new();
        for word in words {
            let capability = Capability::new(word);
            if !capability.is_empty() && set.len() < MAX_CAPABILITIES {
                set.insert(capability);
            }
        }
        Capabilities(set)
    }

    pub fn contains(&self, capability: &Capability) -> bool {
        self.0.contains(capability)
    }

    /// Does this set cover every capability `needed` names?
    pub fn covers(&self, needed: &Capabilities) -> bool {
        needed.0.iter().all(|capability| self.0.contains(capability))
    }

    pub fn iter(&self) -> impl Iterator<Item = &Capability> {
        self.0.iter()
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn to_json(&self) -> Value {
        json!(self.0.iter().map(Capability::as_str).collect::<Vec<_>>())
    }

    /// Decode a bounded array of strings. An entry that is not a string is a refusal, so a peer
    /// cannot smuggle structure into the view.
    pub fn from_json(value: &Value) -> Option<Capabilities> {
        let array = value.as_array()?;
        if array.len() > MAX_CAPABILITIES {
            return None;
        }
        let mut words = Vec::with_capacity(array.len());
        for entry in array {
            let word = entry.as_str()?;
            if word.is_empty() || word.len() > MAX_CAPABILITY {
                return None;
            }
            words.push(word.to_string());
        }
        Some(Capabilities::of(words))
    }
}

/// The three numbers placement needs: how much work is already queued here, and how much headroom
/// the machine has. Percentages are clamped to 0..=100 so a broken peer cannot make itself look
/// infinitely idle (or infinitely loaded).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Load {
    /// Jobs ready or leased on this node's own queues right now.
    pub queue_depth: u32,
    /// CPU busy, percent.
    pub cpu_busy_pct: u8,
    /// Memory used, percent.
    pub mem_used_pct: u8,
}

impl Load {
    pub fn new(queue_depth: u32, cpu_busy_pct: u8, mem_used_pct: u8) -> Load {
        Load { queue_depth, cpu_busy_pct: cpu_busy_pct.min(100), mem_used_pct: mem_used_pct.min(100) }
    }

    pub fn to_json(&self) -> Value {
        json!({
            "queue_depth": self.queue_depth,
            "cpu_busy_pct": self.cpu_busy_pct,
            "mem_used_pct": self.mem_used_pct,
        })
    }

    pub fn from_json(value: &Value) -> Option<Load> {
        Some(Load::new(
            value.get("queue_depth")?.as_u64()? as u32,
            value.get("cpu_busy_pct")?.as_u64()? as u8,
            value.get("mem_used_pct")?.as_u64()? as u8,
        ))
    }
}

/// One heartbeat. `sent_at_ms` is the sender's clock and is carried for the log only: liveness is
/// decided by the receiver's clock, so a node with a wrong clock cannot buy itself work.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Heartbeat {
    pub node: NodeId,
    pub caps: Capabilities,
    pub load: Load,
    pub version: String,
    pub sent_at_ms: i64,
}

impl Heartbeat {
    pub fn new<I, S>(node: impl Into<String>, caps: I, load: Load, version: impl Into<String>, sent_at_ms: i64) -> Heartbeat
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        Heartbeat {
            node: NodeId::new(node.into()).unwrap_or_else(|| NodeId(String::new())),
            caps: Capabilities::of(caps),
            load,
            version: wire::one_line(&version.into(), MAX_VERSION),
            sent_at_ms,
        }
    }

    /// Is this heartbeat something the view can accept? A heartbeat whose id did not survive
    /// validation is refused at the edge rather than stored under an empty name.
    pub fn valid(&self) -> bool {
        !self.node.as_str().is_empty()
    }

    pub fn to_json(&self) -> Value {
        json!({
            "v": wire::VERSION,
            "node": self.node.as_str(),
            "caps": self.caps.to_json(),
            "load": self.load.to_json(),
            "version": self.version,
            "sent_at_ms": self.sent_at_ms,
        })
    }

    pub fn encode(&self) -> Vec<u8> {
        self.to_json().to_string().into_bytes()
    }

    pub fn decode(bytes: &[u8]) -> Result<Heartbeat, wire::Refusal> {
        let value = wire::object(bytes, &["v", "node", "caps", "load", "version", "sent_at_ms"])?;
        let node = wire::bounded(&value, "node", MAX_NODE_ID)?;
        let node = NodeId::new(node).ok_or(wire::Refusal::Malformed("node"))?;
        let caps = Capabilities::from_json(value.get("caps").ok_or(wire::Refusal::Malformed("caps"))?)
            .ok_or(wire::Refusal::Malformed("caps"))?;
        let load = Load::from_json(value.get("load").ok_or(wire::Refusal::Malformed("load"))?)
            .ok_or(wire::Refusal::Malformed("load"))?;
        let version = wire::bounded(&value, "version", MAX_VERSION)?;
        let sent_at_ms = value.get("sent_at_ms").and_then(Value::as_i64).ok_or(wire::Refusal::Malformed("sent_at_ms"))?;
        Ok(Heartbeat { node, caps, load, version: wire::one_line(&version, MAX_VERSION), sent_at_ms })
    }
}

/// What one `observe` changed. `resurrected` is the interesting one: a node that was stale and is
/// back is a node placement may use again on this very beat, and the caller logs it once.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Observe {
    pub new: bool,
    pub resurrected: bool,
    /// Beats received from this node since the view was created.
    pub beats: u32,
}

/// One peer, as the view holds it: the last heartbeat and when the *receiver* saw it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sample {
    pub beat: Heartbeat,
    pub received_at_ms: i64,
    pub beats: u32,
}

impl Sample {
    pub fn age_ms(&self, now_ms: i64) -> i64 {
        now_ms.saturating_sub(self.received_at_ms).max(0)
    }
}

/// The live view: last heartbeat per peer, with a TTL.
#[derive(Clone, Debug)]
pub struct PresenceView {
    heartbeat_ms: i64,
    stale_after_beats: u32,
    nodes: BTreeMap<String, Sample>,
    generation: u64,
}

impl PresenceView {
    pub fn new(config: &crate::Config) -> PresenceView {
        PresenceView::with_ttl(config.heartbeat_ms, config.stale_after_beats)
    }

    pub fn with_ttl(heartbeat_ms: i64, stale_after_beats: u32) -> PresenceView {
        PresenceView {
            heartbeat_ms: heartbeat_ms.max(1),
            stale_after_beats: stale_after_beats.max(1),
            nodes: BTreeMap::new(),
            generation: 0,
        }
    }

    pub fn heartbeat_ms(&self) -> i64 {
        self.heartbeat_ms
    }

    /// The TTL: three missed beats by default. This is the number the admin view prints, because
    /// "how long until a dead node stops being a candidate" is the one thing an operator asks.
    pub fn stale_after_ms(&self) -> i64 {
        self.heartbeat_ms.saturating_mul(self.stale_after_beats as i64)
    }

    /// A stale sample is kept this long before it is forgotten: long enough that a machine which
    /// reboots and comes back is the same entry (with a `resurrected` count), short enough that a
    /// fleet that changes all day cannot grow the map without bound.
    pub fn forget_after_ms(&self) -> i64 {
        self.stale_after_ms().saturating_mul(4)
    }

    /// Record one heartbeat seen at `now_ms`. A peer that was stale becomes live again immediately:
    /// the state is the last beat, never a decision made once.
    pub fn observe(&mut self, beat: Heartbeat, now_ms: i64) -> Observe {
        self.generation = self.generation.wrapping_add(1);
        let stale_after = self.stale_after_ms();
        let key = beat.node.as_str().to_string();
        match self.nodes.get_mut(&key) {
            Some(sample) => {
                let was_stale = sample.age_ms(now_ms) > stale_after;
                sample.beats = sample.beats.saturating_add(1);
                sample.beat = beat;
                sample.received_at_ms = now_ms;
                Observe { new: false, resurrected: was_stale, beats: sample.beats }
            }
            None => {
                self.nodes.insert(key, Sample { beat, received_at_ms: now_ms, beats: 1 });
                Observe { new: true, resurrected: false, beats: 1 }
            }
        }
    }

    pub fn sample(&self, node: &str) -> Option<&Sample> {
        self.nodes.get(node)
    }

    /// Is `node` live at `now_ms`? A node the view never saw is not live.
    pub fn is_live(&self, node: &str, now_ms: i64) -> bool {
        self.nodes.get(node).is_some_and(|sample| sample.age_ms(now_ms) <= self.stale_after_ms())
    }

    /// How many beats a peer has missed, for the admin view. 0 while it is keeping up.
    pub fn missed_beats(&self, node: &str, now_ms: i64) -> u32 {
        match self.nodes.get(node) {
            Some(sample) => (sample.age_ms(now_ms) / self.heartbeat_ms).max(0) as u32,
            None => u32::MAX,
        }
    }

    /// Every live peer, ordered by id (deterministic, so a test's tie-break is the real one).
    pub fn live(&self, now_ms: i64) -> Vec<&Sample> {
        self.nodes.values().filter(|sample| sample.age_ms(now_ms) <= self.stale_after_ms()).collect()
    }

    /// Every peer the view holds, live or stale, ordered by id.
    pub fn all(&self) -> impl Iterator<Item = &Sample> {
        self.nodes.values()
    }

    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }

    /// Bumped by every `observe` and every `prune` that removed something, so a caller can cache a
    /// derived ranking and still notice a change.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Forget samples nobody has heard from in `forget_after_ms`. Returns how many were dropped.
    pub fn prune(&mut self, now_ms: i64) -> usize {
        let forget = self.forget_after_ms();
        let before = self.nodes.len();
        self.nodes.retain(|_, sample| sample.age_ms(now_ms) <= forget);
        let dropped = before - self.nodes.len();
        if dropped > 0 {
            self.generation = self.generation.wrapping_add(1);
        }
        dropped
    }
}
