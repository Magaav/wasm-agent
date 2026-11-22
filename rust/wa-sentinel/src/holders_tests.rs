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
        holders::Holder { session: "8082b42e-1111-2222".into(), label: "POST /chat".into(), ms: 134_000 },
        holders::Holder { session: "deadbeef-1111-2222".into(), label: "POST /chat".into(), ms: 9_000 },
        holders::Holder { session: "".into(), label: "2 subagent(s) running, 0 queued".into(), ms: 0 },
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
    let working = holders::Holder { session: "8082b42e-1111".into(), label: "POST /chat".into(), ms: 120_000 };
    let paused_one = holders::Holder { session: "aaaa1111-2222".into(), label: "POST /chat".into(), ms: 120_000 };
    let nameless = holders::Holder { session: "".into(), label: "2 subagent(s) running, 0 queued".into(), ms: 0 };

    // Before the bound: held, whatever the holders are doing.
    let early = holders::bound_verdict(10, 180, &[paused_one.clone()], |_| true);
    assert!(early.is_err(), "a bound not reached passes over nothing: {early:?}");

    // Everyone paused: the wait is about the node, not about the sessions.
    assert_eq!(holders::bound_verdict(200, 180, &[paused_one.clone()], |_| true), Ok(()));

    // One session still working: reported by name, never passed over.
    let refused = holders::bound_verdict(200, 180, &[paused_one.clone(), working], |session| session != "8082b42e-1111");
    assert_eq!(refused.unwrap_err(), "session 8082b42e is still working (POST /chat)",
        "the refusal names the holder that blocks it");

    // A holder with no session: nothing proves it paused, so nothing passes over it.
    let nameless_refusal = holders::bound_verdict(200, 180, &[nameless], |_| true);
    let nameless_why = nameless_refusal.as_ref().unwrap_err();
    assert!(nameless_why.contains("names no session"), "{nameless_refusal:?}");

    // The node says busy and names nobody: a guess, not a proof.
    let empty = holders::bound_verdict(200, 180, &[], |_| true);
    let empty_why = empty.as_ref().unwrap_err();
    assert!(empty_why.contains("names no holder"), "{empty:?}");
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
