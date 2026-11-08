//! Placement: which node should run this job, and why.
//!
//! Two steps, in this order, and the order is the contract (`docs/FABRIC.md`, "Placement"):
//!
//! 1. **Eligibility** — live, covers the capabilities the job needs, and inside the safety gates
//!    (CPU, memory, queue depth, observed latency). A gate is not a preference: an overloaded node is
//!    never a candidate, however idle its neighbours are not.
//! 2. **Cost** — the cheapest eligible node wins, where cost is *waiting already queued here* plus
//!    *machine pressure* plus *the cost of moving the payload* minus *the locality bonus for a node
//!    that already holds it*. Cost is in milliseconds, so every part is a number an operator can read
//!    and disagree with, and the admin view prints the parts, not just the total.
//!
//! Self is a candidate like any other, with one deliberate exception: **on an exact tie self wins**,
//! because local execution costs zero round trips. That is what makes the fabric "as instantaneous as
//! possible" instead of "as distributed as possible": a peer has to be measurably better to be worth
//! an offer.
//!
//! Nothing here blocks, waits or calls out: [`choose`] is a pure function of the view, the request,
//! the clock and the knobs, so a test can state the exact score that decided a placement.

use crate::presence::{Capabilities, NodeId, PresenceView};
use crate::Config;

/// The cost of one job already queued ahead of this one: a queued job is roughly a second of waiting.
pub const DEFAULT_DEPTH_MS: i64 = 1_000;
/// The cost of one percent of busy CPU.
pub const DEFAULT_CPU_MS_PER_PCT: i64 = 10;
/// The cost of one percent of used memory.
pub const DEFAULT_MEM_MS_PER_PCT: i64 = 4;
/// The relay's conservative throughput, bytes per millisecond (20 MB/s). Only payloads at or above
/// `locality_bytes` are charged for the move, so a 4 kB job is never priced by a bandwidth guess.
pub const DEFAULT_TRANSFER_BYTES_PER_MS: u64 = 20_000;
/// A payload at least this big is worth moving *to* where the data already is, or paying to move.
pub const DEFAULT_LOCALITY_BYTES: u64 = 256 * 1024;
/// What it is worth to run where the bytes already are: five seconds of transfer and setup avoided.
pub const DEFAULT_LOCALITY_BONUS_MS: i64 = 5_000;

/// The score's weights and the eligibility gates. Defaults are the values `docs/FABRIC.md` names;
/// a knob is a knob so a fleet with a slow relay can say so instead of editing this file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Knobs {
    pub depth_ms: i64,
    pub cpu_ms_per_pct: i64,
    pub mem_ms_per_pct: i64,
    pub transfer_bytes_per_ms: u64,
    pub locality_bytes: u64,
    pub locality_bonus_ms: i64,
    /// Hard gates. Above these a node is not a candidate at all.
    pub max_cpu_busy_pct: u8,
    pub max_mem_used_pct: u8,
    pub max_queue_depth: u32,
    /// A node whose recent placement round trip is worse than this is not worth an offer.
    pub max_latency_ms: i64,
}

impl Default for Knobs {
    fn default() -> Knobs {
        Knobs {
            depth_ms: DEFAULT_DEPTH_MS,
            cpu_ms_per_pct: DEFAULT_CPU_MS_PER_PCT,
            mem_ms_per_pct: DEFAULT_MEM_MS_PER_PCT,
            transfer_bytes_per_ms: DEFAULT_TRANSFER_BYTES_PER_MS,
            locality_bytes: DEFAULT_LOCALITY_BYTES,
            locality_bonus_ms: DEFAULT_LOCALITY_BONUS_MS,
            max_cpu_busy_pct: 95,
            max_mem_used_pct: 95,
            max_queue_depth: 64,
            max_latency_ms: 2_000,
        }
    }
}

/// What a node knows about how long an offer to a peer has recently taken (an EWMA of accepted
/// offers' round trips). [`crate::FabricMetrics`] implements it; `()` means "no evidence".
pub trait Latency {
    /// How long an offer to `node` recently took, in milliseconds. `None` is "no evidence", which is
    /// different from "measured slow": no evidence adds no cost and never excludes a node.
    fn estimate_ms(&self, node: &str, now_ms: i64) -> Option<i64>;
}

impl Latency for () {
    fn estimate_ms(&self, _node: &str, _now_ms: i64) -> Option<i64> {
        None
    }
}

/// One unit of work to place. It names the job, never its payload: the bytes stay in the queue
/// (`docs/FABRIC.md`, "The payload never crosses the fabric").
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    /// The job kind (`stt`, `ocr`, `embed`, `index`, `build`, …): the capability a node must serve.
    pub kind: String,
    /// Everything the job needs. Always includes the kind itself.
    pub needs: Capabilities,
    pub payload_bytes: u64,
    /// The node that already holds the payload, when there is one: the locality candidate.
    pub affinity: Option<NodeId>,
    pub job: u64,
    pub lease_ms: i64,
}

impl Request {
    /// A request that needs exactly its kind's capability.
    pub fn new(kind: impl AsRef<str>, job: u64, payload_bytes: u64) -> Request {
        let kind = kind.as_ref().trim().to_ascii_lowercase();
        Request {
            needs: Capabilities::of([kind.as_str()]),
            kind,
            payload_bytes,
            affinity: None,
            job,
            lease_ms: 60_000,
        }
    }

    /// Require more than the kind: `embed` that also needs `index`, say.
    pub fn needs<I, S>(mut self, extra: I) -> Request
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let mut words: Vec<String> = self.needs.iter().map(|c| c.as_str().to_string()).collect();
        words.extend(extra.into_iter().map(|w| w.as_ref().to_string()));
        self.needs = Capabilities::of(words);
        self
    }

    pub fn affinity(mut self, node: impl Into<String>) -> Request {
        self.affinity = NodeId::new(node.into());
        self
    }

    pub fn lease_ms(mut self, lease_ms: i64) -> Request {
        self.lease_ms = lease_ms.max(1);
        self
    }
}

/// One term of the score, in milliseconds, named so the admin view can print "why".
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Part {
    pub what: &'static str,
    pub ms: i64,
}

/// A node's cost for one request: the total and its terms. Lower is better.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Score {
    pub total_ms: i64,
    pub parts: Vec<Part>,
}

impl Score {
    pub fn part(&self, what: &str) -> Option<i64> {
        self.parts.iter().find(|part| part.what == what).map(|part| part.ms)
    }

    /// The terms as `{"what": ms, …}`, the shape the admin view prints.
    pub fn to_json(&self) -> serde_json::Value {
        let mut map = serde_json::Map::new();
        for part in &self.parts {
            map.insert(part.what.to_string(), serde_json::json!(part.ms));
        }
        serde_json::json!({"total_ms": self.total_ms, "parts": map})
    }
}

/// One eligible node and its cost.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub node: NodeId,
    pub score: Score,
    pub is_self: bool,
}

/// A node that was not eligible, and the one word that says why. Kept for the admin view: "why did
/// it not go to the 16-thread box" is answered by `busy`, not by an absence.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Excluded {
    pub node: NodeId,
    pub why: &'static str,
}

/// Why the local path runs a job. Every word is stable: a log line and a counter key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LocalReason {
    /// The fabric is off (`WASM_AGENT_FABRIC=0`): behaviour is exactly the pre-fabric behaviour.
    Disabled,
    /// Self is the cheapest candidate (including "tied and local costs no round trip").
    SelfBest,
    /// No peer is live: nothing to ask, so do not wait at all.
    NoPeer,
    /// Peers are live but none serves the capabilities this job needs.
    NoCapablePeer,
    /// The offer window elapsed without an accept (the router's reason, not this module's).
    OfferWindowElapsed,
    /// Every candidate answered no: the job runs here because nobody would take it.
    AllRefused,
}

impl LocalReason {
    pub fn as_str(self) -> &'static str {
        match self {
            LocalReason::Disabled => "disabled",
            LocalReason::SelfBest => "self_best",
            LocalReason::NoPeer => "no_peer",
            LocalReason::NoCapablePeer => "no_capable_peer",
            LocalReason::OfferWindowElapsed => "offer_window_elapsed",
            LocalReason::AllRefused => "all_refused",
        }
    }
}

/// What to do with the job. `Offer` is one round trip; `Local` is the always-available path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Plan {
    Offer { to: NodeId, window_ms: i64 },
    Local { because: LocalReason },
}

impl Plan {
    pub fn node(&self) -> Option<&NodeId> {
        match self {
            Plan::Offer { to, .. } => Some(to),
            Plan::Local { .. } => None,
        }
    }

    pub fn is_local(&self) -> bool {
        matches!(self, Plan::Local { .. })
    }

    pub fn to_json(&self) -> serde_json::Value {
        match self {
            Plan::Offer { to, window_ms } => {
                serde_json::json!({"plan": "offer", "to": to.as_str(), "window_ms": window_ms})
            }
            Plan::Local { because } => serde_json::json!({"plan": "local", "because": because.as_str()}),
        }
    }
}

/// The full placement decision: the plan, the ranking it came from, the excluded nodes and this
/// node's own score. The ranking is kept (not just the winner) because the router falls through it
/// when the best candidate refuses.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Decision {
    pub plan: Plan,
    pub candidates: Vec<Candidate>,
    pub excluded: Vec<Excluded>,
    pub self_score: Option<Score>,
}

impl Decision {
    /// The candidates after the winner, best first: what the router offers next after a refusal.
    pub fn rest(&self) -> Vec<Candidate> {
        let mut rest = self.candidates.clone();
        if !rest.is_empty() {
            rest.remove(0);
        }
        rest
    }

    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "plan": self.plan.to_json(),
            "candidates": self.candidates.iter().map(|candidate| serde_json::json!({
                "node": candidate.node.as_str(),
                "self": candidate.is_self,
                "score": candidate.score.to_json(),
            })).collect::<Vec<_>>(),
            "excluded": self.excluded.iter().map(|excluded| serde_json::json!({
                "node": excluded.node.as_str(),
                "why": excluded.why,
            })).collect::<Vec<_>>(),
        })
    }
}

/// Choose a node for `request`. Pure: same view, same request, same clock, same answer.
pub fn choose(
    view: &PresenceView,
    request: &Request,
    self_id: &str,
    now_ms: i64,
    config: &Config,
    latency: &dyn Latency,
) -> Decision {
    let knobs = &config.knobs;
    if !config.enabled {
        return Decision {
            plan: Plan::Local { because: LocalReason::Disabled },
            candidates: Vec::new(),
            excluded: Vec::new(),
            self_score: None,
        };
    }

    let mut candidates = Vec::new();
    let mut excluded = Vec::new();
    let mut live_peers = 0usize;
    let mut self_score = None;

    // Self first, so the tie-break does not depend on map order, then the peers in id order. Self is
    // a candidate only when this node publishes its own heartbeat into its own view (the host does,
    // in the same tick it publishes to peers): a node that does not know its own load must not be
    // assumed idle.
    let mut names: Vec<String> = view.all().map(|sample| sample.beat.node.as_str().to_string()).collect();
    if !names.iter().any(|name| name == self_id) && !self_id.is_empty() {
        names.push(self_id.to_string());
    }
    names.sort();
    names.dedup();

    for name in names {
        let Some(node) = NodeId::new(name.clone()) else { continue };
        let is_self = node.as_str() == self_id;
        let Some(sample) = view.sample(node.as_str()) else {
            // Self, never observed: it is not a candidate, and it is not "excluded" either - there is
            // nothing to say about a node whose load this one does not know.
            continue;
        };
        let age_ms = sample.age_ms(now_ms);
        if !is_self && age_ms <= view.stale_after_ms() {
            live_peers += 1;
        }
        let why = if age_ms > view.stale_after_ms() {
            Some("stale")
        } else if !sample.beat.caps.covers(&request.needs) {
            Some("incapable")
        } else if sample.beat.load.cpu_busy_pct > knobs.max_cpu_busy_pct
            || sample.beat.load.mem_used_pct > knobs.max_mem_used_pct
            || sample.beat.load.queue_depth > knobs.max_queue_depth
        {
            Some("busy")
        } else if latency.estimate_ms(node.as_str(), now_ms).is_some_and(|ms| ms > knobs.max_latency_ms) {
            Some("slow")
        } else {
            None
        };
        if let Some(why) = why {
            excluded.push(Excluded { node, why });
            continue;
        }
        let score = score_of(&sample.beat.load, request, &node, is_self, latency, knobs, now_ms);
        if is_self {
            self_score = Some(score.clone());
        }
        candidates.push(Candidate { node, score, is_self });
    }

    // Cheapest first; on an exact tie self wins (zero round trips), then the node id, so the answer
    // is stable across processes and a test can assert it.
    candidates.sort_by(|a, b| {
        a.score
            .total_ms
            .cmp(&b.score.total_ms)
            .then(b.is_self.cmp(&a.is_self))
            .then_with(|| a.node.as_str().cmp(b.node.as_str()))
    });

    let plan = match candidates.first() {
        Some(best) if best.is_self => Plan::Local { because: LocalReason::SelfBest },
        Some(best) => Plan::Offer { to: best.node.clone(), window_ms: config.offer_window_ms },
        None => {
            let because = if live_peers == 0 { LocalReason::NoPeer } else { LocalReason::NoCapablePeer };
            Plan::Local { because }
        }
    };
    Decision { plan, candidates, excluded, self_score }
}

/// The cost of one node, in milliseconds.
fn score_of(
    load: &crate::presence::Load,
    request: &Request,
    node: &NodeId,
    is_self: bool,
    latency: &dyn Latency,
    knobs: &Knobs,
    now_ms: i64,
) -> Score {
    let mut parts = Vec::with_capacity(6);
    let depth = i64::from(load.queue_depth) * knobs.depth_ms;
    parts.push(Part { what: "queue_depth", ms: depth });
    let cpu = i64::from(load.cpu_busy_pct) * knobs.cpu_ms_per_pct;
    parts.push(Part { what: "cpu", ms: cpu });
    let mem = i64::from(load.mem_used_pct) * knobs.mem_ms_per_pct;
    parts.push(Part { what: "mem", ms: mem });
    if let Some(estimate) = latency.estimate_ms(node.as_str(), now_ms) {
        parts.push(Part { what: "latency", ms: estimate });
    }
    // Big payloads are priced by where the bytes are, small ones are not priced at all: a 4 kB job
    // costs nothing to move, and pretending otherwise would make the fabric prefer a slow local node.
    if request.payload_bytes >= knobs.locality_bytes {
        let holds_it = request.affinity.as_ref() == Some(node);
        if holds_it {
            parts.push(Part { what: "locality", ms: -knobs.locality_bonus_ms });
        } else if !is_self {
            let rate = knobs.transfer_bytes_per_ms.max(1);
            parts.push(Part { what: "transfer", ms: (request.payload_bytes / rate) as i64 });
        }
    }
    let total_ms = parts.iter().map(|part| part.ms).sum();
    Score { total_ms, parts }
}

/// The safety gates, as one predicate a caller can ask without a full placement ("may this node take
/// a job of this size right now?"). Used by the accepting side of an offer.
pub fn within_gates(load: &crate::presence::Load, knobs: &Knobs) -> bool {
    load.cpu_busy_pct <= knobs.max_cpu_busy_pct
        && load.mem_used_pct <= knobs.max_mem_used_pct
        && load.queue_depth <= knobs.max_queue_depth
}
