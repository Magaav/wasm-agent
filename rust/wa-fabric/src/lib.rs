//! `wa-fabric` — route heavy work to the best live node, near-instantly, with a local fallback.
//!
//! Machines come and go (the 2-core cloud node powers off, the 16-thread desktop is asleep), so the
//! fabric routes by **state, never by a static rule**: every node publishes a small heartbeat, every
//! node keeps a live view with a TTL, and a node with a job asks the *best* candidate right now for a
//! one-round-trip accept. When nobody answers inside a short window — or when this node is itself the
//! best candidate — the job runs here. The local path is always available, so the fabric can be slow,
//! wrong or absent without ever blocking work (`docs/FABRIC.md`).
//!
//! Four pieces, each one module:
//!
//! | module | what it owns |
//! | --- | --- |
//! | [`presence`] | the heartbeat record, the capability set, and the view with a TTL (stale after 3 missed beats) |
//! | [`placement`] | the score and the ranked candidate list: eligible, capable, least loaded, data locality for big payloads, self included |
//! | [`offer`] | the OFFER/ACCEPT/REFUSE records, the strict wire codec, and the one-window state machine with the local fallback |
//! | [`lease`] | the lease, as `wa-queue`'s lease: heartbeat progress, expiry → requeue, a late settle is refused |
//! | [`metrics`] | counters, the placement latency distribution (p50/p95) and the bounded recent-placements ring the admin view reads |
//! | [`admin`] | `services {"action":"fabric"}`: the live view, recent placements and why, fallbacks, lease expiries |
//! | [`sim`] | the 3-node harness the tests drive: real queues, real leases, one process, a clock that moves by hand |
//!
//! What this crate deliberately does **not** do: no wasmtime, no threads, no sockets, no clock of its
//! own. Time is a `wa_queue::Clock` the caller injects (so a test says exactly when a lease lapsed),
//! the transport is the node's existing signed call (so the fabric adds no new port), and the job
//! payload never crosses this crate — the offer names a job id, and the queue holds the bytes.
//!
//! ```no_run
//! use std::sync::Arc;
//! use wa_fabric::{placement, presence, Config, Heartbeat, Load};
//! use wa_queue::{FixedClock, MemoryKv, Policy, Queue};
//!
//! let cfg = Config::default();
//! let now = 1_000;
//! let mut view = presence::PresenceView::new(&cfg);
//! view.observe(Heartbeat::new("big", ["stt"], Load::new(0, 4, 30), "0.1.0", now), now);
//! let request = placement::Request::new("stt", 0, 12_000);
//! let decision = placement::choose(&view, &request, "small", now, &cfg, &());
//! // `decision.plan` is an offer to `big` (it is idle and this node is not) or `Local`.
//! # let _ = (decision, MemoryKv::new(), FixedClock::new(now), Policy::default());
//! ```
//!
//! Design and the operator contract: `docs/FABRIC.md`. The typed records the components see:
//! `wit/fabric/fabric.wit`. The lease rule this crate reuses: `docs/QUEUE.md`.

pub mod admin;
pub mod lease;
pub mod metrics;
pub mod offer;
pub mod placement;
pub mod presence;
pub mod sim;
mod wire;

#[cfg(test)]
mod tests;

pub use admin::view;
pub use lease::{queue_name, FabricLease, LeaseView, Outstanding};
pub use metrics::{FabricMetrics, NodeLatency, PlacementRecord, RecordOutcome};
pub use offer::{Accept, Offer, Refuse, Reply, Router, Step, DEFAULT_OFFER_WINDOW_MS};
pub use placement::{Candidate, Decision, Latency, Part, Plan, Request, Score};
pub use presence::{
    Capabilities, Capability, Heartbeat, Load, NodeId, PresenceView, Sample, DEFAULT_HEARTBEAT_MS,
    STALE_AFTER_BEATS,
};

use std::collections::BTreeMap;

/// The fabric's knobs, in one place so the host, the admin view and a test all read the same values.
///
/// Every value has a documented default and is overridable from the node's environment
/// ([`Config::from_env`]); an unreadable value keeps the default, because a knob nobody set must not
/// silently become zero (`docs/FABRIC.md`, "Knobs").
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    /// `false` = the fabric does nothing: every job runs locally, exactly as before the fabric
    /// existed. The off path is the same code path as "all peers gone", not a second implementation.
    pub enabled: bool,
    /// How often a node publishes its heartbeat. The brief is 2–5 s; 3 s is the middle.
    pub heartbeat_ms: i64,
    /// A peer is stale after this many missed beats (`STALE_AFTER_BEATS` × `heartbeat_ms`).
    pub stale_after_beats: u32,
    /// How long an offer waits for an accept before the local path takes the job.
    pub offer_window_ms: i64,
    /// The score's weights and the eligibility gates.
    pub knobs: placement::Knobs,
}

impl Default for Config {
    fn default() -> Config {
        Config {
            enabled: true,
            heartbeat_ms: DEFAULT_HEARTBEAT_MS,
            stale_after_beats: STALE_AFTER_BEATS,
            offer_window_ms: DEFAULT_OFFER_WINDOW_MS,
            knobs: placement::Knobs::default(),
        }
    }
}

/// The environment keys this crate reads. Named here so a test asserts the names, and so an operator
/// finds them from the code (`docs/FABRIC.md`).
pub const ENV_ENABLED: &str = "WASM_AGENT_FABRIC";
pub const ENV_HEARTBEAT_MS: &str = "WASM_AGENT_FABRIC_HEARTBEAT_MS";
pub const ENV_OFFER_MS: &str = "WASM_AGENT_FABRIC_OFFER_MS";
pub const ENV_TRANSFER_BYTES_PER_MS: &str = "WASM_AGENT_FABRIC_TRANSFER_BYTES_PER_MS";

impl Config {
    /// The default with the operator's overrides applied. `read` is the environment (or a test's
    /// table): a value that is present but unreadable is reported, never silently defaulted.
    pub fn from_settings(
        enabled: Option<&str>,
        heartbeat_ms: Option<i64>,
        offer_ms: Option<i64>,
        transfer_bytes_per_ms: Option<u64>,
    ) -> Config {
        let default = Config::default();
        Config {
            // Only an explicit "0"/"false"/"off" disables it: an unknown word must not turn routing
            // off by accident, but it must also not be treated as consent - so it stays the default
            // (on) and the caller logs the unreadable value.
            enabled: match enabled.map(|text| text.trim().to_ascii_lowercase()) {
                Some(text) if matches!(text.as_str(), "0" | "false" | "off" | "no") => false,
                Some(text) if matches!(text.as_str(), "1" | "true" | "on" | "yes") => true,
                _ => default.enabled,
            },
            heartbeat_ms: heartbeat_ms
                .filter(|ms| *ms >= 500 && *ms <= 60_000)
                .unwrap_or(default.heartbeat_ms),
            offer_window_ms: offer_ms
                .filter(|ms| *ms >= 1 && *ms <= 10_000)
                .unwrap_or(default.offer_window_ms),
            stale_after_beats: default.stale_after_beats,
            knobs: placement::Knobs {
                transfer_bytes_per_ms: transfer_bytes_per_ms
                    .filter(|rate| *rate > 0)
                    .unwrap_or(default.knobs.transfer_bytes_per_ms),
                ..default.knobs
            },
        }
    }

    /// [`Config::from_settings`] over the process environment. `was_set` reports the keys that were
    /// present, so a caller can log an unreadable one instead of pretending it was read.
    pub fn from_env() -> (Config, Vec<&'static str>) {
        let mut set = Vec::new();
        let enabled = std::env::var(ENV_ENABLED).ok().inspect(|_| set.push(ENV_ENABLED));
        let heartbeat = number(ENV_HEARTBEAT_MS, &mut set);
        let offer = number(ENV_OFFER_MS, &mut set);
        let transfer = number(ENV_TRANSFER_BYTES_PER_MS, &mut set).map(|value| value.max(1) as u64);
        (Config::from_settings(enabled.as_deref(), heartbeat, offer, transfer), set)
    }
}

fn number(key: &'static str, set: &mut Vec<&'static str>) -> Option<i64> {
    let raw = std::env::var(key).ok()?;
    set.push(key);
    raw.trim().parse::<i64>().ok()
}

/// Every kind of job the fabric can place, as a capability word. The list is **open**: a component
/// that advertises `"ocr"` and a job that requires `"ocr"` match without this crate learning what
/// OCR is, which is what makes a new job kind pluggable (`docs/FABRIC.md`, "Job kinds").
pub const JOB_KINDS: &[&str] = &["stt", "ocr", "embed", "index", "build"];

/// The capability a job kind requires by default: the kind's own name. A caller may ask for more
/// (`Request::needs`), never for less than the kind.
pub fn capability_for(kind: &str) -> Capability {
    Capability::new(kind)
}

/// A short, stable name for a placement decision, for logs and the admin view. Never a payload.
pub fn reason_word(reason: &placement::LocalReason) -> &'static str {
    reason.as_str()
}

/// Group counters by a word, the shape the admin view prints.
pub(crate) fn bump(counts: &mut BTreeMap<String, u64>, word: &str) {
    *counts.entry(word.to_string()).or_insert(0) += 1;
}
