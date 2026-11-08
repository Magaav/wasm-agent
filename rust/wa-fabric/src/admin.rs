//! The operator view: `services {"action":"fabric"}`.
//!
//! It answers four questions, in this order, because that is the order an operator asks them:
//!
//! 1. **Who is in the fabric right now** — every node the view holds, its capabilities, its load, how
//!    old its last beat is, and whether that makes it live or stale. A machine that powers off is
//!    visible as `live: false` with a growing `age_ms`, not as a mystery.
//! 2. **What was placed recently, and why** — the last placements with the winning node, the score's
//!    terms and the one word that excluded each node that was not eligible (`busy`, `incapable`,
//!    `stale`, `slow`). A placement nobody can explain is a bug report waiting to happen.
//! 3. **What fell back** — local runs by reason, and the offers that timed out or were refused, so
//!    "the 16-thread box was not used" has a cause.
//! 4. **What is leased** — the leases the fabric queues carry, when each lapses, and how many have
//!    already lapsed and are waiting for recovery.
//!
//! Nothing here carries a payload, a transcript, a result or a secret: job ids, kinds, node ids,
//! numbers and words.

use serde_json::{json, Value};

use crate::lease::Outstanding;
use crate::metrics::FabricMetrics;
use crate::presence::PresenceView;
use crate::Config;

/// Everything the admin view needs, borrowed so the caller keeps ownership of the live objects.
pub struct FabricView<'a> {
    pub self_id: &'a str,
    pub config: &'a Config,
    pub presence: &'a PresenceView,
    pub metrics: &'a FabricMetrics,
    pub now_ms: i64,
    /// One entry per fabric queue the caller read (`fabric.stt`, …).
    pub leases: &'a [Outstanding],
    /// Offers in flight right now (the router's own count).
    pub in_flight_offers: usize,
    /// How many recent placements to print.
    pub recent: usize,
}

/// The view as JSON. Deterministic field order is not promised, but every field is always present, so
/// a reader never has to tell "zero" from "missing".
pub fn view(view: &FabricView<'_>) -> Value {
    let nodes: Vec<Value> = view
        .presence
        .all()
        .map(|sample| {
            let age = sample.age_ms(view.now_ms);
            json!({
                "node": sample.beat.node.as_str(),
                "self": sample.beat.node.as_str() == view.self_id,
                "caps": sample.beat.caps.to_json(),
                "load": sample.beat.load.to_json(),
                "version": sample.beat.version,
                "age_ms": age,
                "missed_beats": view.presence.missed_beats(sample.beat.node.as_str(), view.now_ms),
                "live": age <= view.presence.stale_after_ms(),
                "beats": sample.beats,
            })
        })
        .collect();
    let live = nodes.iter().filter(|node| node["live"] == json!(true)).count();
    let recent: Vec<Value> = view.metrics.recent(view.recent.max(1)).map(|record| record.to_json()).collect();
    let leases: Vec<Value> = view.leases.iter().map(Outstanding::to_json).collect();
    let knobs = &view.config.knobs;
    json!({
        "ok": true,
        "enabled": view.config.enabled,
        "self": view.self_id,
        "now_ms": view.now_ms,
        "heartbeat_ms": view.presence.heartbeat_ms(),
        "stale_after_ms": view.presence.stale_after_ms(),
        "offer_window_ms": view.config.offer_window_ms,
        "in_flight_offers": view.in_flight_offers,
        "nodes": nodes,
        "live": live,
        "stale": nodes.len().saturating_sub(live),
        "recent": recent,
        "counters": view.metrics.to_json(),
        "latency_by_node": view.metrics.node_latency(view.now_ms).into_iter()
            .map(|(node, ms, samples)| json!({"node": node, "ms": ms, "samples": samples}))
            .collect::<Vec<_>>(),
        "leases": leases,
        "knobs": {
            "depth_ms": knobs.depth_ms,
            "cpu_ms_per_pct": knobs.cpu_ms_per_pct,
            "mem_ms_per_pct": knobs.mem_ms_per_pct,
            "transfer_bytes_per_ms": knobs.transfer_bytes_per_ms,
            "locality_bytes": knobs.locality_bytes,
            "locality_bonus_ms": knobs.locality_bonus_ms,
            "max_cpu_busy_pct": knobs.max_cpu_busy_pct,
            "max_mem_used_pct": knobs.max_mem_used_pct,
            "max_queue_depth": knobs.max_queue_depth,
            "max_latency_ms": knobs.max_latency_ms,
        },
    })
}
