//! What `wa-sentinel status` names, and what the bound may pass over - as literals, without a live node.
//!
//! The concern, in the words it was measured in (22/11, `~/.wasm-agent/sentinel/sentinel.log`): the deploy for
//! `8082b42e` was held with `the node is busy: a run, a subagent or an operation is in flight` from 10:01:24Z and
//! ran at 10:31:48Z - thirty minutes - and it ran only after the operator parked four sessions by hand. The status
//! line named no session and the wait had no bound.
//!
//! Falsification, each run by hand:
//!
//!   * make `holders_from` return an empty vector (the pre-22/11 behaviour: "held: node busy" and nobody named) -
//!     `who_holds_the_node_and_for_how_long` and `holder_lines_name_the_session_and_its_duration` fail;
//!   * make `bound_verdict` ignore `paused` (proceed whatever is running) - `the_bound_passes_over_paused_sessions_only`
//!     fails on the still-working holder it would have stopped the node under;
//!   * drop the `at >= since` test in `paused_since` (any old pause counts) -
//!     `a_pause_record_counts_only_for_the_request_it_was_written_for` fails.

use super::*;

fn health(body: &str) -> Value {
    serde_json::from_str(body).expect("a health literal")
}

/// 1. Two sessions working, one thread idle, one turn queued and a subagent: every one of them is work, and the
/// sessions are NAMED with how long they have been at it.
#[test]
fn who_holds_the_node_and_for_how_long() {
    let body = health(
        r#"{"ok":true,"queue":1,
             "node_threads":[
               {"id":0,"session":"8082b42e-1111-2222-3333-444455556666","label":"POST /chat","state":"busy","busy_ms":134000},
               {"id":2,"session":"deadbeef-1111-2222-3333-444455556666","label":"POST /chat","state":"busy","busy_ms":9000},
               {"id":5,"session":null,"label":null,"state":"busy","busy_ms":999999}],
             "current":{"label":"POST /chat","ms":134000,"session":"8082b42e-1111-2222-3333-444455556666"},
             "subagents":{"queued":1,"running":2,"active":3}}"#,
    );
    let holders = holders::holders_from(&body);
    let sessions: Vec<&str> = holders.iter().map(|holder| holder.session.as_str()).collect();
    assert_eq!(&sessions[..2],
        &["8082b42e-1111-2222-3333-444455556666", "deadbeef-1111-2222-3333-444455556666"],
        "both working sessions are named: {holders:?}");
    assert_eq!(holders[0].ms, 134_000, "and how long each has been busy: {holders:?}");
    assert!(
        holders.iter().any(|holder| holder.label == "1 turn(s) admitted and not started"),
        "a queued turn is work too: {holders:?}"
    );
    assert!(
        holders.iter().any(|holder| holder.label == "2 subagent(s) running, 1 queued"),
        "and so is a subagent: {holders:?}"
    );
    assert_eq!(holders.iter().filter(|holder| holder.label == "POST /chat").count(), 2,
        "the idle thread is not a holder, and `current` does not duplicate the thread array: {holders:?}");
}

/// 2. An idle node holds nothing, and a thread that is merely old is not work: `label` is what a node-thread is
/// DOING, and the age is the life of the thread.
#[test]
fn an_idle_thread_is_not_a_holder() {
    let body = health(
        r#"{"ok":true,"queue":0,"current":null,
             "node_threads":[{"id":0,"session":"aaaa","label":null,"state":"busy","busy_ms":600000}],
             "subagents":{"queued":0,"running":0,"active":0}}"#,
    );
    assert!(holders::holders_from(&body).is_empty(), "an idle thread is not a holder");
}

/// 3. The older key is read: this sentinel supervises nodes that predate `node_threads`, and a holder it cannot
/// see is a bound that would pass over a working turn.
#[test]
fn the_older_workers_key_is_read() {
    let body = health(
        r#"{"ok":true,"queue":0,"current":null,
             "workers":[{"id":1,"session":"cafebabe-0000","label":"POST /chat","state":"busy","busy_ms":61000}]}"#,
    );
    let holders = holders::holders_from(&body);
    assert_eq!(holders.len(), 1, "the legacy array is read: {holders:?}");
    assert_eq!(holders[0].session, "cafebabe-0000");
}

/// 4. `current` is a holder on its own when the thread array does not name it - the shape an older node answers.
#[test]
fn current_is_a_holder_once() {
    let body = health(
        r#"{"ok":true,"queue":0,"node_threads":[],
             "current":{"label":"POST /chat","ms":2000,"session":"11112222-3333"}}"#,
    );
    let holders = holders::holders_from(&body);
    assert_eq!(holders.len(), 1, "one holder: {holders:?}");
    assert_eq!(holders[0].session, "11112222-3333");
    assert_eq!(holders[0].ms, 2000);
}

/// 5. The lines an operator reads: the session as `wa sessions` prints it, what it is doing, how long, and whether
/// it has paused for the waiting deploy. A holder that names no session says so instead of looking truncated.
#[test]
fn holder_lines_name_the_session_and_its_duration() {
    let holders = vec![
        holders::Holder { session: "8082b42e-1111-2222".into(), label: "POST /chat".into(), ms: 134_000, queued: false, completion: false },
        holders::Holder { session: "deadbeef-1111-2222".into(), label: "POST /chat".into(), ms: 9_000, queued: false, completion: false },
        holders::Holder { session: "".into(), label: "2 subagent(s) running, 0 queued".into(), ms: 0, queued: false, completion: false },
    ];
    let lines = holders::holder_lines(&holders, |session| session.starts_with("8082b42e"));
    assert_eq!(lines.len(), 3, "one line per holder: {lines:?}");
    assert_eq!(lines[0], "  busy     session 8082b42e  POST /chat 2m  paused for the deploy", "{lines:?}");
    assert_eq!(lines[1], "  busy     session deadbeef  POST /chat 9s  working", "{lines:?}");
    assert!(lines[2].contains("(no session named)"), "a holder with no session says so: {}", lines[2]);
}

/// 6. The bound is a wall on WAITING, never a licence to kill a turn: it passes over holders that recorded a pause
/// for this request and over nothing else - not a working session, not a subagent, not a run with no session.
#[test]
fn the_bound_passes_over_paused_sessions_only() {
    let working = holders::Holder { session: "8082b42e-1111".into(), label: "POST /chat".into(), ms: 120_000, queued: false, completion: false };
    let paused_one = holders::Holder { session: "aaaa1111-2222".into(), label: "POST /chat".into(), ms: 120_000, queued: false, completion: false };
    let nameless = holders::Holder { session: "".into(), label: "2 subagent(s) running, 0 queued".into(), ms: 0, queued: false, completion: false };

    // Before the bound: held, whatever the holders are doing.
    let early = holders::bound_verdict(10, 180, &[paused_one.clone()], |_| true);
    assert!(matches!(early, holders::Verdict::Wait(_)), "a bound not reached passes over nothing: {early:?}");

    // Everyone paused: the wait is about the node, not about the sessions.
    assert_eq!(holders::bound_verdict(200, 180, &[paused_one.clone()], |_| true), holders::Verdict::Proceed);

    // One session still working, and the snapshot NAMES it: the failure names it too.
    let refused = holders::bound_verdict(200, 180, &[paused_one.clone(), working], |session| session != "8082b42e-1111");
    assert_eq!(refused, holders::Verdict::Fail("session 8082b42e is still working (POST /chat)".to_string()),
        "the refusal names the holder that blocks it");

    // A holder with no session: nothing proves it paused - and nothing there can be FAILED either (23/11).
    match holders::bound_verdict(200, 180, &[nameless], |_| true) {
        holders::Verdict::Wait(why) => assert!(why.contains("names no session"), "{why:?}"),
        other => panic!("an unnamed holder must not fail a request: {other:?}"),
    }

    // The node says busy and names nobody: a guess, not a proof, and not a failure.
    match holders::bound_verdict(200, 180, &[], |_| true) {
        holders::Verdict::Wait(why) => assert!(why.contains("names no holder"), "{why:?}"),
        other => panic!("a node that names nobody must not fail a request: {other:?}"),
    }
}

/// 7. A pause record says something about the request it was written for, and nothing about a later one. The record
/// is the file lua/core/deploy_pause.lua writes at the moment a session pauses.
#[test]
fn a_pause_record_counts_only_for_the_request_it_was_written_for() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|error| error.into_inner());
    let home = std::env::temp_dir().join(format!("wa-holders-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let previous = std::env::var_os("WASM_AGENT_HOME");
    std::env::set_var("WASM_AGENT_HOME", &home);

    std::fs::create_dir_all(paused_dir()).unwrap();
    let record = |since: u64| {
        serde_json::json!({"session": "8082b42e-1111", "since": since, "to": "b".repeat(40),
            "source": "request", "request": "1795341684727384607-2971842-00000000000000000000"}).to_string()
    };
    std::fs::write(paused_dir().join("8082b42e-1111.json"), record(2_000)).unwrap();

    assert_eq!(paused_since("8082b42e-1111", 1_000), Some(2_000), "a pause at or after the request counts");
    assert_eq!(paused_since("8082b42e-1111", 3_000), None,
        "a pause recorded before the request was queued says nothing about it");
    assert_eq!(paused_since("not-a-session", 1_000), None, "a session with no record has not paused");
    assert_eq!(paused_since("", 1_000), None, "and no session is not a session");
    std::fs::write(paused_dir().join("undated.json"), "{not json").unwrap();
    assert_eq!(paused_since("undated", 0), None, "an unreadable record is not a pause");

    match previous {
        Some(value) => std::env::set_var("WASM_AGENT_HOME", value),
        None => std::env::remove_var("WASM_AGENT_HOME"),
    }
    let _ = std::fs::remove_dir_all(&home);
}

/// 8. A request with no `queued_at` still has the time it was written: its name carries it. A wait nothing can
/// measure is a wait nothing can bound.
#[test]
fn a_request_takes_its_time_from_its_name_when_it_records_none() {
    let request = serde_json::json!({"verb": "deploy"});
    assert_eq!(
        request_queued_at(&request, "1700000000123456789-4242-00000000000000000000"),
        1_700_000_000,
        "the name is the queue time"
    );
    let dated = serde_json::json!({"verb": "deploy", "queued_at": 1_700_000_500u64});
    assert_eq!(request_queued_at(&dated, "1700000000123456789-4242-0"), 1_700_000_500, "the field wins when it is there");
    // Nothing to measure: "now" is the only answer, and it means "no wait yet", never "waited for ever".
    let now = request_queued_at(&request, "not-a-stamp");
    assert!(now > 1_700_000_000, "an undated request is not old: {now}");
}

/// 9. A queued turn is NAMED (23/11). MEASURED: the deploy for e9a42d20 was held for twenty-five minutes behind
/// `10 turn(s) admitted and not started` - a count, and a count cannot be asked whether it paused. `/health`
/// names the admitted-and-not-started runs under `queue_sessions`; this reads them, keeps the count for the ones
/// a node could not name, and never turns the two into a number that is neither.
#[test]
fn a_queued_turn_is_named_and_the_unnamed_ones_are_still_counted() {
    let body = health(
        r#"{"ok":true,"queue":2,
             "queue_sessions":{"count":2,"named":1,"truncated":false,"entries":[
               {"run_id":41,"session":"9b28c30d-1111-2222-3333-444455556666","node_thread":0,"kind":"run","waited_ms":45000},
               {"run_id":42,"session":"","node_thread":3,"kind":"completion","waited_ms":50}]},
             "node_threads":[],"current":null,
             "subagents":{"queued":0,"running":0,"active":0}}"#,
    );
    let holders = holders::holders_from(&body);
    let named = holders.iter().find(|holder| holder.session.starts_with("9b28c30d")).expect("the queued session is named");
    assert_eq!(named.label, "admitted, not started");
    assert_eq!(named.ms, 45_000, "and how long it has waited");
    assert!(named.queued, "and that nothing of it has run: {holders:?}");
    assert!(holders.iter().any(|holder| holder.label == "1 turn(s) admitted and not started" && !holder.queued),
        "the turn the node could not name is still counted: {holders:?}");
    let lines = holders::holder_lines(&holders, |_| false);
    assert!(lines.iter().any(|line| line.contains("session 9b28c30d  admitted, not started 45s  not started yet")),
        "the line says a queued turn has not started, not that it is working: {lines:?}");
}

/// 10. A turn that has not started is NOT a turn that paused: no pause record can exist for it (a pause is
/// written by a running turn at a step boundary), so the bound must never pass over one - even if a record with
/// that session's name is there.
#[test]
fn the_bound_never_passes_over_a_turn_that_has_not_started() {
    let queued = holders::Holder::admitted("9b28c30d-1111", "admitted, not started", 45_000);
    let refused = holders::bound_verdict(200, 180, &[queued.clone()], |_| true);
    let holders::Verdict::Fail(why) = &refused else { panic!("a named queued turn is a failure, not a wait: {refused:?}") };
    assert!(why.contains("admitted and not started"), "the refusal names the queued turn: {refused:?}");
    assert!(why.contains("session 9b28c30d"), "with the session as `wa sessions` prints it: {refused:?}");
}

/// 11. A request's NAME carries its queue time only when it is a stamp. MEASURED (23/11): this sentinel read
/// `100-deploy.json` as `100` epoch-nanoseconds - "queued for fifty-six years" - so the request was past every
/// bound the moment it arrived. That was invisible while the bound only picked an announcement; now that a
/// request past its bound without a provable pause FAILS, it would fail a request that had just been written.
#[test]
fn a_request_name_that_is_not_a_stamp_is_not_a_time() {
    assert_eq!(stamp_seconds("1700000000123456789-4242-00000000000000000000"), Some(1_700_000_000));
    assert_eq!(stamp_seconds("100-deploy"), None, "a sequence number is not an epoch-nanos stamp");
    assert_eq!(stamp_seconds("not-a-stamp"), None);
    assert_eq!(stamp_seconds(""), None);
    let fresh = request_queued_at(&serde_json::json!({"verb": "deploy"}), "100-deploy");
    assert!(fresh > 1_700_000_000, "a request with no measurable queue time is not fifty-six years old: {fresh}");
}

/// 12. A CHILD COMPLETION NEVER HOLDS THE INSTALL (23/11). MEASURED twice on avell, in both directions:
///
///   * 13:11Z, session 40adee0f: the node PAUSED the worker for the deploy and the deploy then waited for that
///     same session's queued child completion - a mutual wait, and the request failed at its bound;
///   * 14:37Z, three sessions (da212b83, 6bce1698, b7be279e): the completions were admitted and not started, the
///     node refused to start them while the request waited (its admission gate), and the deploy waited 40 minutes
///     for them. Withdrawing the request made them run within 90s.
///
/// So neither "paused" nor "not started" is the test for a completion: it starts after the install, and the
/// install never waits on it. Asserted from the SHAPE the node answers (`queue_sessions`, `kind: completion`),
/// not from a hand-built holder, so the reader and the rule are judged together.
#[test]
fn a_child_completion_never_holds_the_install() {
    let body = health(
        r#"{"ok":true,"queue":2,
             "queue_sessions":{"count":2,"named":2,"truncated":false,"entries":[
               {"run_id":41,"session":"da212b83-1111-2222-3333-444455556666","node_thread":0,"kind":"completion","waited_ms":1500000},
               {"run_id":42,"session":"6bce1698-1111-2222-3333-444455556666","node_thread":1,"kind":"completion","waited_ms":1500000}]},
             "node_threads":[],"current":null,
             "subagents":{"queued":0,"running":0,"active":0}}"#,
    );
    let holders = holders::holders_from(&body);
    assert_eq!(holders.len(), 2, "each completion is named: {holders:?}");
    assert!(holders.iter().all(|holder| holder.completion && holder.queued), "{holders:?}");
    // NOT ONE of them has a pause record, and the request still proceeds: the install cannot hurt a completion.
    assert_eq!(holders::bound_verdict(200, 180, &holders, |_| false), holders::Verdict::Proceed,
        "an admitted child completion never holds the install: {holders:?}");
    let lines = holders::holder_lines(&holders, |_| false);
    assert!(lines.iter().all(|line| line.contains("does not hold the deploy")), "{lines:?}");
    assert!(lines.iter().any(|line| line.contains("session da212b83  child completion, admitted, not started")),
        "the status says what the turn is: {lines:?}");
}

/// 13. A completion the node could not name does not hold the install either, and a NAMED turn does: the
/// difference is the kind the snapshot reports, not the count.
#[test]
fn a_named_turn_and_a_nameless_completion_are_read_differently() {
    let body = health(
        r#"{"ok":true,"queue":2,
             "queue_sessions":{"count":2,"named":1,"truncated":false,"entries":[
               {"run_id":41,"session":"9b28c30d-1111-2222-3333-444455556666","node_thread":0,"kind":"run","waited_ms":45000},
               {"run_id":42,"session":"","node_thread":3,"kind":"completion","waited_ms":50}]},
             "node_threads":[],"current":null,
             "subagents":{"queued":0,"running":0,"active":0}}"#,
    );
    let holders = holders::holders_from(&body);
    let counted = holders.iter().find(|holder| holder.label == "1 turn(s) admitted and not started")
        .expect("the turn the node could not name is still counted");
    assert!(counted.completion, "and the one it named as a completion is not a turn that must run: {counted:?}");
    // The named turn is the blocker, and it is named: that is a failure the operator can act on.
    let verdict = holders::bound_verdict(200, 180, &holders, |_| true);
    assert!(matches!(verdict, holders::Verdict::Fail(ref why) if why.contains("session 9b28c30d")), "{verdict:?}");

    // The same body with a turn the node could not name: unknown is not yes, and it is not a failure.
    let mut unnameable = body.clone();
    unnameable["queue_sessions"]["entries"][1]["kind"] = serde_json::json!("run");
    let holders = holders::holders_from(&unnameable);
    let verdict = holders::bound_verdict(200, 180, &holders, |_| true);
    match verdict {
        holders::Verdict::Wait(why) => assert!(why.contains("names no session"), "{why:?}"),
        other => panic!("a turn the node could not name must never fail a request: {other:?}"),
    }
}

/// 14. THE REPORTER NAMES WHAT IT KNOWS (23/11). MEASURED: the request for 7865a08e failed at its bound with
/// "the node reports itself busy and names no holder" - and `e9a42d20` sat 25 minutes behind a count-only queue.
/// Two shapes the reader used to throw away are holders: a `current` run the snapshot gives no label, and an
/// overdue operation (which `activity_of` counts as busy on its own).
#[test]
fn a_holder_the_reporter_knows_is_named() {
    let unlabelled = health(
        r#"{"ok":true,"queue":0,"node_threads":[],
             "current":{"label":"","ms":42000,"session":"8082b42e-1111-2222-3333-444455556666"},
             "subagents":{"queued":0,"running":0,"active":0}}"#,
    );
    let holders = holders::holders_from(&unlabelled);
    assert_eq!(holders.len(), 1, "a run named only by its session is still a run: {holders:?}");
    assert_eq!(holders[0].session, "8082b42e-1111-2222-3333-444455556666");
    assert_eq!(holders[0].label, "a run, with no label", "and it says it has no label instead of vanishing");

    let overdue = health(
        r#"{"ok":true,"queue":0,"operation_overdue":true,"node_threads":[],"current":null,
             "subagents":{"queued":0,"running":0,"active":0}}"#,
    );
    let holders = holders::holders_from(&overdue);
    assert!(holders.iter().any(|holder| holder.label == "an operation is overdue"),
        "an overdue operation is work the node reported and nobody named: {holders:?}");
    let lines = holders::holder_lines(&holders, |_| false);
    assert!(lines.iter().any(|line| line.contains("(no session named)  an operation is overdue")));
    match holders::bound_verdict(200, 180, &holders, |_| true) {
        holders::Verdict::Wait(why) => assert!(why.contains("an operation is overdue"), "{why:?}"),
        other => panic!("work with no session is never passed over and never failed: {other:?}"),
    }
}
