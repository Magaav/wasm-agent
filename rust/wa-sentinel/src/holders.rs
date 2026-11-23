//! WHO keeps this node busy, for how long, and whether the deploy may pass over them.
//!
//! MEASURED twice on the laptop this was written for (22/11, `~/.wasm-agent/sentinel/sentinel.log`): a deploy
//! request for `8082b42e` was held with `the node is busy: a run, a subagent or an operation is in flight` from
//! 10:01:24Z and ran at 10:31:48Z - thirty minutes - and it ran only after the operator parked four sessions by
//! hand and stopped one `wa chat --once`. `wa-sentinel status` said only `held: node busy`: it could not name a
//! single session, so the operator had to find them by hand, and nothing bounded the wait.
//!
//! This module is the two answers that were missing, and nothing that performs anything:
//!
//!   * [`holders_from`] - the sessions (and the things that are not sessions) that keep the node from being idle,
//!     read from the ONE `/health` snapshot `status` already holds, with how long each has been busy;
//!   * [`bound_verdict`] - whether the request may proceed after its bound anyway, which it may only when every
//!     holder is a session that has itself recorded that it PAUSED for this deploy (lua/core/deploy_pause.lua
//!     writes `<data>/deploy-paused/<session>.json` at the moment it pauses). A holder that is still working, a
//!     subagent, a queued turn, or a run whose session the snapshot does not name is never passed over: unknown
//!     is not yes, and stopping a node under a working turn is the failure the whole pause exists to avoid.

use serde_json::Value;

/// One thing that keeps the node from being idle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Holder {
    /// The conversation it writes, as `/health` names it. Empty when the snapshot names none - an operation or
    /// a subagent run is work the node reports without a session, and an OLDER node reports its queue that way
    /// too (the count-only shape `/health` answered before 23/11).
    pub session: String,
    /// What it is doing (`POST /chat`, `admitted, not started`, `N subagents running`, ...).
    pub label: String,
    /// How long it has been busy (or queued), in milliseconds, when the snapshot says.
    pub ms: u64,
    /// The node admitted this turn and has not started it. Not the same thing as a turn that is working, and
    /// not the same thing as one that paused: nothing has run, so no pause record can exist for it (`/health`
    /// names these under `queue_sessions`, one entry per admitted run).
    pub queued: bool,
}

impl Holder {
    fn new(session: impl Into<String>, label: impl Into<String>, ms: u64) -> Holder {
        Holder { session: session.into(), label: label.into(), ms, queued: false }
    }

    pub(crate) fn admitted(session: impl Into<String>, label: impl Into<String>, ms: u64) -> Holder {
        Holder { session: session.into(), label: label.into(), ms, queued: true }
    }
}

fn field_u64(entry: &Value, key: &str) -> u64 {
    entry.get(key).and_then(Value::as_u64).unwrap_or(0)
}

fn field_str(entry: &Value, key: &str) -> String {
    entry.get(key).and_then(Value::as_str).unwrap_or("").to_string()
}

/// The sessions that keep this node busy, and for how long.
///
/// Reads `node_threads` (the current name) and `workers` (the name an older node answers), plus `current` - the
/// in-flight run as the aggregate view reports it - and the things that are not sessions: a non-empty `queue`
/// (turns admitted and not started) and running or queued subagents. Every one of those is work: the question
/// this answers is "is the node idle", not "is a chat running".
///
/// A node whose `/health` does not answer is not a node with no holders: the caller holds on `None` activity
/// already, so this returns what it can and never invents an idle node.
pub(crate) fn holders_from(health: &Value) -> Vec<Holder> {
    let mut holders: Vec<Holder> = Vec::new();
    let threads = health
        .get("node_threads")
        .and_then(Value::as_array)
        .or_else(|| health.get("workers").and_then(Value::as_array));
    if let Some(threads) = threads {
        for entry in threads {
            // `label` is what a node-thread is doing; a thread with none is idle and is not a holder, whatever
            // its age says (the age is the life of the thread, not of a run).
            if entry.get("label").map(|label| label.is_null()).unwrap_or(true) {
                continue;
            }
            holders.push(Holder::new(
                field_str(entry, "session"),
                field_str(entry, "label"),
                field_u64(entry, "busy_ms"),
            ));
        }
    }
    if let Some(current) = health.get("current") {
        if current.is_object() {
            let label = field_str(current, "label");
            let session = field_str(current, "session");
            // The aggregate view repeats the run the thread array already named; one line per holder.
            let known = holders.iter().any(|holder| holder.label == label && holder.session == session);
            if !known && !label.is_empty() {
                holders.push(Holder::new(session, label, field_u64(current, "ms")));
            }
        }
    }
    // WHICH conversations are queued, not only how many (23/11). MEASURED: a deploy for e9a42d20 was held for
    // 25 minutes behind `10 turn(s) admitted and not started` - a holder with no session, so nothing could ask
    // whether it had paused and the bound could never be satisfied. `/health` now names them under
    // `queue_sessions` (`rust/wa-capabilities/src/serve.rs`, `pending_admitted`); a NODE THAT DOES NOT is still
    // read correctly, as the single unnamed holder it can prove.
    let queue = field_u64(health, "queue");
    let mut named = 0u64;
    if let Some(entries) = health.get("queue_sessions").and_then(|sessions| sessions.get("entries")).and_then(Value::as_array) {
        for entry in entries {
            let session = field_str(entry, "session");
            // An entry with no session is counted below, in the holder that says so, rather than invented.
            if session.is_empty() { continue; }
            named += 1;
            let label = match field_str(entry, "kind").as_str() {
                "completion" => "child completion, admitted, not started",
                _ => "admitted, not started",
            };
            holders.push(Holder::admitted(session, label, field_u64(entry, "waited_ms")));
        }
    }
    let unnamed = queue.saturating_sub(named);
    if unnamed > 0 {
        holders.push(Holder::new("", format!("{unnamed} turn(s) admitted and not started"), 0));
    }
    if let Some(subagents) = health.get("subagents").and_then(Value::as_object) {
        let running = subagents.get("running").and_then(Value::as_u64).unwrap_or(0);
        let queued = subagents.get("queued").and_then(Value::as_u64).unwrap_or(0);
        if running > 0 || queued > 0 {
            holders.push(Holder::new("", format!("{running} subagent(s) running, {queued} queued"), 0));
        }
    }
    holders
}

/// The session id as an operator reads and types it: eight characters, the way `wa sessions` and every refusal
/// in this tree print one. `""` stays `""`, so a holder without a session says so instead of looking truncated.
fn short(session: &str) -> String {
    session.chars().take(8).collect()
}

/// How long, in the coarsest unit that still says something - the same shape `age` uses for a request.
fn duration(ms: u64) -> String {
    let seconds = ms / 1000;
    if ms == 0 {
        "for an unrecorded time".to_string()
    } else if seconds < 60 {
        format!("{seconds}s")
    } else if seconds < 3600 {
        format!("{}m", seconds / 60)
    } else {
        format!("{}h", seconds / 3600)
    }
}

/// One line per holder for `wa-sentinel status`: which session, what it is doing and for how long, and - when the
/// caller can say - whether that session has paused for the waiting deploy.
///
/// `paused(session)` answers "did this session record that it paused for THIS request" (the caller owns the
/// request's own time, so a record left by an earlier deploy cannot answer for this one).
pub(crate) fn holder_lines<F>(holders: &[Holder], paused: F) -> Vec<String>
where
    F: Fn(&str) -> bool,
{
    holders
        .iter()
        .map(|holder| {
            let who = if holder.session.is_empty() {
                "(no session named)".to_string()
            } else {
                format!("session {}", short(&holder.session))
            };
            let state = if holder.session.is_empty() {
                ""
            } else if holder.queued {
                // "working" would be a lie about a turn that has not run a single step.
                "  not started yet"
            } else if paused(&holder.session) {
                "  paused for the deploy"
            } else {
                "  working"
            };
            format!("  busy     {who}  {} {}{state}", holder.label, duration(holder.ms))
        })
        .collect()
}

/// Whether a held request may proceed even though the node says it is busy.
///
/// `Ok` when every holder is a session that has recorded a pause for this request; `Err(reason)` otherwise,
/// naming the first holder that blocks it, because "still held" has to be actionable. The bound is a wall on
/// waiting, never a licence to kill a turn: a holder that is working is reported, not overridden.
pub(crate) fn bound_verdict<F>(waited_seconds: u64, bound_seconds: u64, holders: &[Holder], paused: F) -> Result<(), String>
where
    F: Fn(&str) -> bool,
{
    if waited_seconds < bound_seconds {
        return Err(format!("the hold bound is {bound_seconds}s and {waited_seconds}s have passed"));
    }
    if holders.is_empty() {
        // The node reported busy and named nothing: the bound is the only fact there is, and passing over a
        // busy node that will not say why is exactly the guess this sentinel exists not to make.
        return Err("the node reports itself busy and names no holder, so nothing proves a turn paused".to_string());
    }
    for holder in holders {
        if holder.session.is_empty() {
            return Err(format!("the holder `{}` names no session, so this request has no proof it paused", holder.label));
        }
        // A TURN THAT HAS NOT STARTED IS NOT ONE THAT PAUSED. A pause record is written by a running turn at a
        // step boundary (lua/core/deploy_pause.lua), so a queued turn can never have one for this request - and
        // passing over it would start work under an install. It is reported, by name, and the request waits.
        if holder.queued {
            return Err(format!("session {} has a turn admitted and not started ({})", short(&holder.session), holder.label));
        }
        if !paused(&holder.session) {
            return Err(format!("session {} is still working ({})", short(&holder.session), holder.label));
        }
    }
    Ok(())
}
