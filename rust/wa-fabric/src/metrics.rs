//! What the fabric measured: counters, the placement latency distribution, and a bounded ring of
//! recent placements with the score that decided them.
//!
//! Two rules, both from `AGENTS.md`:
//!
//! * **No payload, ever.** A record names a job id, a kind, a node, a score and an outcome word. The
//!   bytes and the result never enter this module, so the admin view cannot leak a transcript.
//! * **A measurement is reported, never invented.** The latency distribution is the last
//!   [`FabricMetrics::latency_samples`] *measured* round trips; with none, `p50`/`p95` are `null` and
//!   the view says `samples: 0` instead of printing a zero that looks like a measurement.
//!
//! The per-node estimate is an EWMA of accepted offers' round trips, used by placement as one term of
//! the score: a peer that answers slowly loses to one that answers quickly, once there is evidence.

use std::collections::{BTreeMap, VecDeque};

use crate::offer::Offer;
use crate::placement::{Decision, Latency, LocalReason, Plan, Request};

/// Enough measurements for an estimate to mean something: one is a cold start.
pub const DEFAULT_MIN_SAMPLES: u32 = 2;

/// A measurement older than this is not evidence about "now" (a peer that was fast before a reboot,
/// a network change or a thermal throttle is not assumed fast).
pub const DEFAULT_SAMPLE_TTL_MS: i64 = 10 * 60 * 1_000;

/// How many recent round trips the percentile calculation keeps.
pub const DEFAULT_LATENCY_SAMPLES: usize = 256;

/// How many recent placements the admin view keeps, newest first.
pub const DEFAULT_RECENT: usize = 32;

/// The weight a new measurement gets: one outlier must not decide the next placement.
const ALPHA: f64 = 0.3;

/// One node's observed placement round trip.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct NodeLatency {
    pub last_ms: i64,
    pub ewma_ms: f64,
    pub samples: u32,
    pub updated_at_ms: i64,
}

impl NodeLatency {
    pub fn record(&mut self, at_ms: i64, took_ms: i64) {
        let took = took_ms.max(0);
        self.ewma_ms = if self.samples == 0 { took as f64 } else { ALPHA * took as f64 + (1.0 - ALPHA) * self.ewma_ms };
        self.last_ms = took;
        self.samples = self.samples.saturating_add(1);
        self.updated_at_ms = at_ms;
    }

    pub fn estimate_ms(&self) -> i64 {
        self.ewma_ms.max(0.0) as i64
    }

    pub fn recent(&self, now_ms: i64, ttl_ms: i64, min_samples: u32) -> Option<i64> {
        if self.samples < min_samples.max(1) || now_ms.saturating_sub(self.updated_at_ms) > ttl_ms.max(0) {
            return None;
        }
        Some(self.estimate_ms())
    }
}

/// How a placement ended. Every word is stable: a counter key and a log word.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordOutcome {
    /// The offer was sent; the answer has not arrived yet.
    Offered,
    /// The peer said yes, after `rtt_ms`.
    Accepted { rtt_ms: i64 },
    /// The peer said no (or could not be reached).
    Refused,
    /// The window elapsed with no answer.
    Timeout,
    /// The job ran here.
    Local,
}

impl RecordOutcome {
    pub fn as_str(self) -> &'static str {
        match self {
            RecordOutcome::Offered => "offered",
            RecordOutcome::Accepted { .. } => "accepted",
            RecordOutcome::Refused => "refused",
            RecordOutcome::Timeout => "timeout",
            RecordOutcome::Local => "local",
        }
    }
}

/// One placement, kept for the operator: what was asked, who won, the score that decided it and how
/// it ended. Bounded (the oldest record is dropped first).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlacementRecord {
    pub at_ms: i64,
    pub job: u64,
    pub kind: String,
    pub node: Option<String>,
    pub score_ms: Option<i64>,
    pub parts: Vec<(String, i64)>,
    pub outcome: RecordOutcome,
    /// Why the local path ran it, or the peer's word for a refusal.
    pub because: Option<String>,
    /// The one word that says why a peer was not eligible, for the nodes that were not.
    pub excluded: Vec<(String, &'static str)>,
}

impl PlacementRecord {
    pub fn to_json(&self) -> serde_json::Value {
        let mut parts = serde_json::Map::new();
        for (what, ms) in &self.parts {
            parts.insert(what.clone(), serde_json::json!(ms));
        }
        serde_json::json!({
            "at_ms": self.at_ms,
            "job": self.job,
            "kind": self.kind,
            "node": self.node,
            "score_ms": self.score_ms,
            "score_parts": parts,
            "outcome": self.outcome.as_str(),
            "rtt_ms": match self.outcome { RecordOutcome::Accepted { rtt_ms } => Some(rtt_ms), _ => None },
            "because": self.because,
            "excluded": self.excluded.iter().map(|(node, why)| serde_json::json!({"node": node, "why": why})).collect::<Vec<_>>(),
        })
    }
}

/// The fabric's counters and measurements. Cheap to clone-free-share: the host owns one behind a lock.
#[derive(Clone, Debug)]
pub struct FabricMetrics {
    /// Jobs the fabric was asked to place.
    pub placements: u64,
    /// Offers sent (a refusal with a fall-through is more than one offer for one placement).
    pub offers: u64,
    pub accepts: u64,
    /// Refusals by the peer's word (`busy`, `incapable`, …).
    pub refuses: BTreeMap<String, u64>,
    pub timeouts: u64,
    /// Offers that got no answer at all (relay refused, node gone).
    pub unreachable: u64,
    /// Jobs a peer accepted.
    pub placed: u64,
    /// Jobs that ran locally, and why.
    pub local: u64,
    pub fallbacks: BTreeMap<String, u64>,
    /// Leases settled by the holder, and settles refused because the lease had moved on.
    pub settled: u64,
    pub lost_settles: u64,
    /// Leases that lapsed and had to be recovered (the queue's own count, mirrored here).
    pub lease_expiries: u64,
    /// Round trips of accepted offers, newest last, bounded.
    pub latency_samples: usize,
    latencies: VecDeque<i64>,
    pub min_samples: u32,
    pub sample_ttl_ms: i64,
    per_node: BTreeMap<String, NodeLatency>,
    pub recent_max: usize,
    recent: VecDeque<PlacementRecord>,
}

impl Default for FabricMetrics {
    fn default() -> FabricMetrics {
        FabricMetrics {
            placements: 0,
            offers: 0,
            accepts: 0,
            refuses: BTreeMap::new(),
            timeouts: 0,
            unreachable: 0,
            placed: 0,
            local: 0,
            fallbacks: BTreeMap::new(),
            settled: 0,
            lost_settles: 0,
            lease_expiries: 0,
            latency_samples: DEFAULT_LATENCY_SAMPLES,
            latencies: VecDeque::new(),
            min_samples: DEFAULT_MIN_SAMPLES,
            sample_ttl_ms: DEFAULT_SAMPLE_TTL_MS,
            per_node: BTreeMap::new(),
            recent_max: DEFAULT_RECENT,
            recent: VecDeque::new(),
        }
    }
}

impl FabricMetrics {
    pub fn new() -> FabricMetrics {
        FabricMetrics::default()
    }

    /// Record a decision: one placement, either an offer (the record stays `Offered` until the answer
    /// arrives) or the local path.
    pub fn decided(&mut self, at_ms: i64, request: &Request, decision: &Decision) {
        self.placements += 1;
        // `offers` is counted by `offer_sent`, once per offer actually sent: a placement that falls
        // through to a second candidate is two offers, and a local placement is none.
        let (node, score_ms, parts) = match &decision.plan {
            Plan::Offer { to, .. } => {
                let winner = decision.candidates.iter().find(|candidate| &candidate.node == to);
                let score = winner.map(|candidate| candidate.score.clone());
                (
                    Some(to.as_str().to_string()),
                    score.as_ref().map(|score| score.total_ms),
                    score.map(|score| score.parts.iter().map(|p| (p.what.to_string(), p.ms)).collect()).unwrap_or_default(),
                )
            }
            Plan::Local { because } => {
                self.local += 1;
                crate::bump(&mut self.fallbacks, because.as_str());
                (None, None, Vec::new())
            }
        };
        let record = PlacementRecord {
            at_ms,
            job: request.job,
            kind: request.kind.clone(),
            node,
            score_ms,
            parts,
            outcome: if decision.plan.is_local() { RecordOutcome::Local } else { RecordOutcome::Offered },
            because: match &decision.plan {
                Plan::Local { because } => Some(because.as_str().to_string()),
                Plan::Offer { .. } => None,
            },
            excluded: decision.excluded.iter().map(|excluded| (excluded.node.as_str().to_string(), excluded.why)).collect(),
        };
        self.push(record);
    }

    /// The peer said yes: count it, remember the round trip (one measurement of the placement's cost
    /// and one term of the next placement's score).
    pub fn accepted(&mut self, at_ms: i64, job: u64, node: &str, rtt_ms: i64) {
        self.accepts += 1;
        self.placed += 1;
        let rtt = rtt_ms.max(0);
        self.latencies.push_back(rtt);
        while self.latencies.len() > self.latency_samples.max(1) {
            self.latencies.pop_front();
        }
        self.per_node.entry(node.to_string()).or_default().record(at_ms, rtt);
        self.update(job, RecordOutcome::Accepted { rtt_ms: rtt }, None);
    }

    /// The peer said no, with its word.
    pub fn refused(&mut self, job: u64, reason: &str) {
        crate::bump(&mut self.refuses, reason);
        self.update(job, RecordOutcome::Refused, Some(reason.to_string()));
    }

    /// The window elapsed with no answer.
    pub fn timed_out(&mut self, job: u64) {
        self.timeouts += 1;
        self.update(job, RecordOutcome::Timeout, None);
    }

    /// No answer at all: the relay refused or the node is gone. Counted apart from a refusal.
    pub fn unreachable(&mut self, job: u64, reason: &str) {
        self.unreachable += 1;
        crate::bump(&mut self.refuses, "unreachable");
        self.update(job, RecordOutcome::Refused, Some(reason.to_string()));
    }

    /// The job ran here after an offer (a fallback), or without one.
    pub fn local_fallback(&mut self, job: u64, because: LocalReason) {
        self.local += 1;
        crate::bump(&mut self.fallbacks, because.as_str());
        self.update(job, RecordOutcome::Local, Some(because.as_str().to_string()));
    }

    pub fn settled(&mut self) {
        self.settled += 1;
    }

    /// A settle refused because the lease had moved on: the fence working, and worth counting.
    pub fn settle_lost(&mut self) {
        self.lost_settles += 1;
    }

    /// A lease lapsed (recovered by the queue): the job is takeable again.
    pub fn lease_expired(&mut self) {
        self.lease_expiries += 1;
    }

    /// The last `n` placements, newest first.
    pub fn recent(&self, n: usize) -> impl Iterator<Item = &PlacementRecord> {
        self.recent.iter().rev().take(n)
    }

    /// (p50, p95, samples) over the measured round trips, nearest-rank. `None` with no samples: an
    /// empty distribution is reported as absent, never as zero.
    pub fn percentiles(&self) -> (Option<i64>, Option<i64>, usize) {
        if self.latencies.is_empty() {
            return (None, None, 0);
        }
        let mut sorted: Vec<i64> = self.latencies.iter().copied().collect();
        sorted.sort_unstable();
        let rank = |percent: usize| -> i64 {
            let index = ((sorted.len() * percent).div_ceil(100)).clamp(1, sorted.len()) - 1;
            sorted[index]
        };
        (Some(rank(50)), Some(rank(95)), sorted.len())
    }

    /// The per-node estimates, for the admin view.
    pub fn node_latency(&self, now_ms: i64) -> Vec<(String, i64, u32)> {
        self.per_node
            .iter()
            .map(|(node, latency)| (node.clone(), latency.recent(now_ms, self.sample_ttl_ms, 1).unwrap_or(latency.last_ms), latency.samples))
            .collect()
    }

    /// The counters, as the admin view prints them.
    pub fn to_json(&self) -> serde_json::Value {
        let (p50, p95, samples) = self.percentiles();
        serde_json::json!({
            "placements": self.placements,
            "offers": self.offers,
            "accepts": self.accepts,
            "placed": self.placed,
            "local": self.local,
            "timeouts": self.timeouts,
            "unreachable": self.unreachable,
            "refuses": self.refuses,
            "fallbacks": self.fallbacks,
            "settled": self.settled,
            "lost_settles": self.lost_settles,
            "lease_expiries": self.lease_expiries,
            "latency": {"p50_ms": p50, "p95_ms": p95, "samples": samples},
        })
    }

    /// One offer leaving: the count, so the admin view can tell "one offer per placement" from a
    /// fall-through storm.
    pub fn offer_sent(&mut self, _offer: &Offer) {
        self.offers += 1;
    }

    fn update(&mut self, job: u64, outcome: RecordOutcome, because: Option<String>) {
        if let Some(record) = self.recent.iter_mut().rev().find(|record| record.job == job) {
            record.outcome = outcome;
            if because.is_some() {
                record.because = because;
            }
        }
    }

    fn push(&mut self, record: PlacementRecord) {
        self.recent.push_back(record);
        while self.recent.len() > self.recent_max.max(1) {
            self.recent.pop_front();
        }
    }
}

impl Latency for FabricMetrics {
    fn estimate_ms(&self, node: &str, now_ms: i64) -> Option<i64> {
        self.per_node.get(node)?.recent(now_ms, self.sample_ttl_ms, self.min_samples)
    }
}
