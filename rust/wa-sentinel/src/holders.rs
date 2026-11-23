//! WHO keeps this node busy, for how long, and whether the deploy may pass over them.
//!
//! MEASURED twice on the laptop this was written for (22/11, `~/.wasm-agent/sentinel/sentinel.log`): a deploy
//! request for `8082b42e` was held with `the node is busy: a run, a subagent or an operation is in flight` from
//! 10:01:24Z and ran at 10:31:48Z - thirty minutes - and it ran only after the operator parked four sessions by
//! hand and stopped one `wa chat --once`. `wa-sentinel status` said only `held: node busy`: it could not name a
//! single session, so the operator had to find them by hand, and nothing bounded the wait.
//!
//! This module is the answers that were missing, and nothing that performs anything:
//!
//!   * [`holders_from`] - the sessions (and the things that are not sessions) that keep the node from being idle,
//!     read from the ONE `/health` snapshot `status` already holds, with how long each has been busy;
//!   * [`bound_verdict`] - what the bound says about a request that has waited it: PROCEED when every holder is
//!     one the install cannot hurt, WAIT when a holder is one the request cannot be failed for, and FAIL by name
//!     only when every blocker is named.
//!
//! MEASURED (avell, 23/11 13:11Z-13:18Z and 14:37Z-15:20Z, the two bound failures this module now answers):
//!
//!   1. a worker (`run-block-images-reach-model`, session 40adee0f) was PAUSED by the node for the deploy, and
//!      the deploy then waited for that same session's queued child completion - a mutual wait, and the bound
//!      failed the request against it. A child completion of a session the node itself paused can only run
//!      after the install, so it is never something an install can hurt;
//!   2. with `WA_DEPLOY_HOLD_BOUND=0` the deploy waited 40 minutes behind three ADMITTED-AND-NOT-STARTED child
//!      completions whose sessions had already ended: the node starts no new turn while a request waits (the
//!      admission gate, `lua/core/server.lua`), so those completions were waiting for the very install that was
//!      waiting for them. Each waits on the other, with no bound. Withdrawing the request made them run within
//!      90s - which is what proves the shape;
//!   3. `7865a08e` failed at its bound with `the node reports itself busy and names no holder`, and `e9a42d20`
//!      with a holder that named no session. Neither is a fact a request can be failed for: the holder is
//!      unnamed, so nothing proves it is a turn that must run, and nothing proves it paused either.
//!
//! The rule that follows from (1) and (2): a CHILD COMPLETION never holds a deploy. It is a notification the
//! node owes a settled child, it starts after the install, and while a request waits the node refuses to start
//! it - so it is by construction waiting for the install and never for anything else.

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
    /// This admitted turn is a CHILD COMPLETION: the notification the node owes a session whose subagent or
    /// operation settled. It starts after an install, never before, so the install never waits on it (see the
    /// module note, measurement 2).
    pub completion: bool,
}

impl Holder {
    fn new(session: impl Into<String>, label: impl Into<String>, ms: u64) -> Holder {
        Holder { session: session.into(), label: label.into(), ms, queued: false, completion: false }
    }

    pub(crate) fn admitted(session: impl Into<String>, label: impl Into<String>, ms: u64) -> Holder {
        Holder { session: session.into(), label: label.into(), ms, queued: true, completion: false }
    }

    /// A child completion, admitted and not started. Its own constructor, because "admitted and not started"
    /// and "admitted, not started, and a completion" are the two answers the bound treats differently.
    pub(crate) fn completion(session: impl Into<String>, label: impl Into<String>, ms: u64) -> Holder {
        Holder { session: session.into(), label: label.into(), ms, queued: true, completion: true }
    }

    fn counted(label: impl Into<String>, completion: bool) -> Holder {
        Holder { session: String::new(), label: label.into(), ms: 0, queued: false, completion }
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
            // A RUN THIS SNAPSHOT NAMES ONLY BY SESSION IS STILL A HOLDER (23/11). MEASURED: the request for
            // 7865a08e failed at its bound with "the node reports itself busy and names no holder" while
            // `/health` answered a non-null `current` this reader threw away for having no label - it failed
            // against a holder it had itself refused to name. A run with no label is now called exactly that.
            if !known {
                let label = if label.is_empty() { "a run, with no label".to_string() } else { label };
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
    let mut listed = 0u64;
    let mut named = 0u64;
    let mut unnamed_completions = 0u64;
    let mut unnamed_other = 0u64;
    if let Some(entries) = health.get("queue_sessions").and_then(|sessions| sessions.get("entries")).and_then(Value::as_array) {
        for entry in entries {
            listed += 1;
            let session = field_str(entry, "session");
            let completion = field_str(entry, "kind") == "completion";
            // An entry with no session is counted below, in the holder that says so, rather than invented - but
            // WHICH kind it is decides whether it can hold the install, so it is not thrown away either.
            if session.is_empty() {
                if completion { unnamed_completions += 1 } else { unnamed_other += 1 }
                continue;
            }
            named += 1;
            let label = if completion { "child completion, admitted, not started" } else { "admitted, not started" };
            holders.push(if completion {
                Holder::completion(session, label, field_u64(entry, "waited_ms"))
            } else {
                Holder::admitted(session, label, field_u64(entry, "waited_ms"))
            });
        }
    }
    // A turn the node counted and did not list is a turn nothing can ask whether it paused. It is still counted,
    // exactly as before, and it holds the install until the node can name it - unless every entry the node did
    // list, and the whole remainder, is a child completion: then nothing here can be hurt by an install.
    let unnamed = queue.saturating_sub(named);
    let unlisted = queue.saturating_sub(listed);
    if unnamed > 0 {
        let completion_only = unnamed_other == 0 && unlisted == 0;
        holders.push(Holder::counted(format!("{unnamed} turn(s) admitted and not started"), completion_only));
    } else if unnamed_completions > 0 {
        // Named-count says nothing is unnamed but an entry had no session: believe the entry, not the count.
        holders.push(Holder::counted(
            format!("{unnamed_completions} turn(s) admitted and not started"),
            unnamed_other == 0 && unlisted == 0,
        ));
    }
    if let Some(subagents) = health.get("subagents").and_then(Value::as_object) {
        let running = subagents.get("running").and_then(Value::as_u64).unwrap_or(0);
        let queued = subagents.get("queued").and_then(Value::as_u64).unwrap_or(0);
        if running > 0 || queued > 0 {
            holders.push(Holder::new("", format!("{running} subagent(s) running, {queued} queued"), 0));
        }
    }
    // AN OVERDUE OPERATION IS WORK, AND IT NAMES NOBODY (23/11). `activity_of` calls the node busy on
    // `operation_overdue` alone; this reader pushed no holder for it, so `status` said "busy" and named
    // nobody, and a request past its bound failed against a report it could not read. Named here, as the thing
    // it is: work the node reports without a session.
    if health.get("operation_overdue").and_then(Value::as_bool) == Some(true) {
        holders.push(Holder::new("", "an operation is overdue", 0));
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
            } else if holder.completion {
                // Neither \"working\" nor \"paused\": it has not started, and it is the one kind of not-started
                // turn an install cannot hurt (module note, measurement 2).
                "  not started yet, and does not hold the deploy"
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

/// What the bound says about a request that has waited it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Verdict {
    /// Every holder is one the install cannot hurt: a session that paused for this request, or a child
    /// completion that starts after it. The request proceeds.
    Proceed,
    /// Nothing here is a blocker this request can be FAILED for: a holder that names no session, or a node that
    /// names no holder at all. The request keeps waiting, past its bound, and the line says so. Unknown is not
    /// yes - and it is not a failure either.
    Wait(String),
    /// Every blocker is NAMED (a session still working, or a named turn admitted and not started). The request
    /// fails by name, and the caller re-queues it once for the next quiet moment.
    Fail(String),
}

/// Whether a held request may proceed even though the node says it is busy.
///
/// `Proceed` when every holder is a session that has recorded a pause for this request, or a child completion.
/// `Fail(reason)` only when every blocker is named, naming the first one, because "still held" has to be
/// actionable. `Wait(reason)` when a holder is unnamed: nothing proves such a holder is a turn that must run,
/// and nothing proves it paused - so the request is never failed on it (23/11: a request failed at its bound
/// with "the node reports itself busy and names no holder").
///
/// The bound is a wall on waiting, never a licence to kill a turn: a holder that is working is reported, not
/// overridden.
pub(crate) fn bound_verdict<F>(waited_seconds: u64, bound_seconds: u64, holders: &[Holder], paused: F) -> Verdict
where
    F: Fn(&str) -> bool,
{
    if waited_seconds < bound_seconds {
        return Verdict::Wait(format!("the hold bound is {bound_seconds}s and {waited_seconds}s have passed"));
    }
    if holders.is_empty() {
        // The node reported busy and named nothing: the bound is not a licence to stop a node that will not say
        // why, and it is not something to fail a request for either.
        return Verdict::Wait("the node reports itself busy and names no holder".to_string());
    }
    let mut unnamed: Option<String> = None;
    let mut named: Option<String> = None;
    for holder in holders {
        // A CHILD COMPLETION NEVER HOLDS THE INSTALL (23/11, the module note): it starts after it.
        if holder.completion {
            continue;
        }
        if holder.session.is_empty() {
            unnamed.get_or_insert_with(|| format!(
                "the holder `{}` names no session, so nothing proves it paused", holder.label));
            continue;
        }
        // A TURN THAT HAS NOT STARTED IS NOT ONE THAT PAUSED. A pause record is written by a running turn at a
        // step boundary (lua/core/deploy_pause.lua), so a queued turn can never have one for this request - and
        // passing over it would start work under an install. It is reported, by name, and the request fails.
        if holder.queued {
            named.get_or_insert_with(|| format!(
                "session {} has a turn admitted and not started ({})", short(&holder.session), holder.label));
            continue;
        }
        if !paused(&holder.session) {
            named.get_or_insert_with(|| format!(
                "session {} is still working ({})", short(&holder.session), holder.label));
        }
    }
    if let Some(why) = unnamed {
        return Verdict::Wait(why);
    }
    match named {
        Some(why) => Verdict::Fail(why),
        None => Verdict::Proceed,
    }
}
