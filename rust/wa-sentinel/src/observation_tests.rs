//! The return-observation lane: one line per (id, problem), then the directory leaves the lane.
//!
//! The concern, measured on `work` (2026-11-18): `sentinel.log` held 523,067 `return-observation-problem`
//! lines for 75 request ids, every one of them `No such file or directory (os error 2)`, for seven days. Each
//! id's protocol directory was a finished deploy whose `intent.json`/`ack.json`/`binding.json` had never been
//! written; the observation could never succeed, and nothing ever stopped asking. The count is not the only
//! damage: a log that repeats one sentence a minute per id has no room for the line that matters.
//!
//! What is proved here, with a scratch home and no live node:
//!
//!   1. a directory that cannot be observed is reported **once**, by the files it is missing - not once per
//!      tick, and not as a bare io error;
//!   2. the same problem past the grace retires the directory: it leaves `deploy-protocol/` for
//!      `deploy-protocol-retired/` with one line saying where it went, and no later pass observes it again;
//!   3. a *changed* problem is new information and is reported; a problem that clears is forgotten;
//!   4. what was said survives a restart - a new watcher reads it and says nothing;
//!   5. a *runtime* problem (one that can clear) is never retired, however long it persists;
//!   6. a *held* protocol deploy - intent and ack written by intake, no binding because admit has not run - keeps
//!      its directory however long it is held, with one line at most (review of 18/11); and a withdrawal still
//!      owed its return event is not retired either;
//!   7. a retirement that *cannot* happen (the retired lane already holds that id) is said once, not once a tick.
//!
//! Falsification, each run by hand:
//!
//!   * audit on every pass instead of on the rule - `a_missing_file_is_reported_once_however_many_ticks_go_by`
//!     fails with 50 lines where the log had one, which is the measured defect at a smaller scale;
//!   * retire on the first report instead of after the grace - `a_missing_file_is_reported_once_however_many_ticks_go_by`
//!     fails, because the directory is gone before the grace, which is how a slow intake would lose a live
//!     deploy;
//!   * retire a runtime problem too - `a_runtime_problem_is_never_retired` fails with a live deploy's
//!     directory in the retired lane and its report thrown away;
//!   * decide "structural" from the missing files alone, without asking the queue - the rule this lane had
//!     before the review of 18/11 - `a_held_deploy_survives_the_grace_with_one_line` fails with a live deploy's
//!     directory retired and its evidence moved, and `a_withdrawn_deploy_is_not_retired_before_its_report` fails
//!     the same way one withdrawal later;
//!   * answer `Retire` again after a retirement failed - `a_retirement_that_cannot_happen_is_said_once` fails
//!     with twenty failed-retirement lines where the log had one, which is the measured defect one lane over.

use super::*;

struct Scratch {
    home: PathBuf,
}

impl Scratch {
    fn new(label: &str) -> Scratch {
        let home = std::env::temp_dir().join(format!("wa-sentinel-observation-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).expect("scratch home");
        std::env::set_var("WASM_AGENT_HOME", &home);
        Scratch { home }
    }

    /// A protocol directory that looks like the measured ones: a finished deploy's `result.json` and nothing
    /// intake writes.
    fn finished_deploy(&self, id: &str) {
        let dir = sentinel_dir().join("deploy-protocol").join(id);
        std::fs::create_dir_all(&dir).expect("protocol directory");
        std::fs::write(dir.join("result.json"), br#"{"ok":true,"commit":"2199eaff"}"#).expect("result");
    }

    /// A protocol request as `request deploy --expected-sha` writes it: the file in the queue, and the two files
    /// intake writes (`intent.json`, `ack.json`) - nothing else. This is a deploy held by a busy node, a protocol
    /// that is not ready, or a parent owner that cannot be read: `binding.json` is written at admit, and admit has
    /// not run.
    fn held_deploy(&self, id: &str) -> Value {
        let request = json!({
            "verb": "deploy", "id": id, "expected_sha": "a".repeat(40), "queued_at": now_epoch(),
            "session": "parent", "owner": "owner", "reason": "the fixture's reason",
        });
        let queued = sentinel_dir().join("requests").join(format!("{id}.json"));
        std::fs::create_dir_all(sentinel_dir().join("requests")).expect("requests lane");
        wa_operation::atomic_json(&queued, &request).expect("queue the request");
        deploy_protocol::intake(&request, id).expect("real intake writes intent.json and ack.json");
        request
    }

    fn dir(&self, id: &str) -> PathBuf {
        sentinel_dir().join("deploy-protocol").join(id)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        std::env::remove_var("WASM_AGENT_HOME");
        std::env::remove_var("WASM_SENTINEL_OBSERVE_GRACE");
        std::env::remove_var("WASM_AGENT_PORT");
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

const ID: &str = "1794381506848658618-2787635-00000000000000000000";

fn log_lines(kind: &str, id: &str) -> Vec<String> {
    std::fs::read_to_string(log_path()).unwrap_or_default()
        .lines()
        .filter(|line| line.split('\t').nth(1) == Some(kind) && line.split('\t').nth(2) == Some(id))
        .map(str::to_string)
        .collect()
}

/// 1. One line per (id, problem), naming the files it is missing, however many ticks go by.
#[test]
fn a_missing_file_is_reported_once_however_many_ticks_go_by() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new("once");
    scratch.finished_deploy(ID);

    let mut lane = observation::Observations::load();
    // Fifty ticks: ten seconds of a watcher that ticks five times a second, and the pass is what the watcher
    // ran on every one of them.
    for _ in 0..50 {
        lane.pass();
    }

    let lines = log_lines("return-observation-problem", ID);
    assert_eq!(lines.len(), 1, "one problem, one line - not one per tick: {lines:?}");
    assert!(
        lines[0].contains("missing binding.json, ack.json, intent.json"),
        "the line names what is missing instead of a bare io error: {}",
        lines[0]
    );
    // The directory is still there: the grace has not passed, so a slow intake is not thrown away.
    assert!(scratch.dir(ID).is_dir(), "nothing is retired inside the grace");
    assert!(log_lines("return-observation-retired", ID).is_empty());
}

/// 2. The same structural problem past the grace retires the directory, and it is never observed again.
#[test]
fn the_same_problem_past_the_grace_retires_the_directory() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new("retired");
    std::env::set_var("WASM_SENTINEL_OBSERVE_GRACE", "0");
    scratch.finished_deploy(ID);

    let mut lane = observation::Observations::load();
    lane.pass(); // reports it once
    lane.pass(); // past the grace: retires it
    lane.pass(); // nothing left to observe
    for _ in 0..20 {
        lane.pass();
    }

    assert!(!scratch.dir(ID).exists(), "the directory leaves the lane");
    let retired = sentinel_dir().join("deploy-protocol-retired").join(ID);
    assert!(retired.join("result.json").is_file(), "retired, not deleted: the evidence is still readable at {}", retired.display());
    assert_eq!(log_lines("return-observation-problem", ID).len(), 1, "the problem was said once");
    let retired_lines = log_lines("return-observation-retired", ID);
    assert_eq!(retired_lines.len(), 1, "one line says where it went: {retired_lines:?}");
    assert!(retired_lines[0].contains("no longer observed"), "{}", retired_lines[0]);
    assert!(retired_lines[0].contains("nothing was deleted"), "{}", retired_lines[0]);
}

/// 3. The rule itself: a changed problem is reported, an unchanged one is quiet or retired, and a runtime
/// problem is never retired.
#[test]
fn the_rule_is_one_line_per_id_and_problem() {
    let said = |problem: &str, first: u64| observation::Said::reported(problem, first);
    assert_eq!(observation::verdict(None, "missing ack.json", 100, 300, true), observation::Verdict::Report);
    assert_eq!(
        observation::verdict(Some(&said("missing ack.json", 100)), "missing ack.json", 399, 300, true),
        observation::Verdict::Quiet,
        "the same problem inside the grace is not news"
    );
    assert_eq!(
        observation::verdict(Some(&said("missing ack.json", 100)), "missing ack.json", 400, 300, true),
        observation::Verdict::Retire,
        "a structural problem that never clears stops being observed"
    );
    assert_eq!(
        observation::verdict(Some(&said("parent_owner_unavailable", 100)), "parent_owner_unavailable", 100_000, 300, false),
        observation::Verdict::Quiet,
        "a runtime problem is retried, never retired: the retry is what would see it clear"
    );
    assert_eq!(
        observation::verdict(Some(&said("missing ack.json", 100)), "missing binding.json", 101, 300, true),
        observation::Verdict::Report,
        "a changed problem is a changed fact"
    );
    // A retirement that already failed is settled: the retired lane holds that id, and asking again on every
    // tick is the defect this lane exists to remove, one lane over.
    let failed = observation::Said { problem: "missing ack.json".into(), first_seen: 100, retire_failed: true };
    assert_eq!(
        observation::verdict(Some(&failed), "missing ack.json", 100_000, 300, true),
        observation::Verdict::Quiet,
        "a retirement that could not happen is said once, not once per tick"
    );
    assert_eq!(
        observation::verdict(Some(&failed), "missing binding.json", 100_000, 300, true),
        observation::Verdict::Report,
        "a changed problem is a new fact, and its retirement is worth one new attempt"
    );
}

/// 4. A restarted watcher does not say it again: the record is on disk.
#[test]
fn a_restarted_watcher_does_not_say_it_again() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new("restart");
    scratch.finished_deploy(ID);

    observation::Observations::load().pass();
    // A new process, with its own empty memory: exactly what a watcher restart under `Restart=always` is.
    let mut restarted = observation::Observations::load();
    restarted.pass();
    restarted.pass();

    assert_eq!(log_lines("return-observation-problem", ID).len(), 1, "the line belongs to the problem, not to the process");
    // ...and a problem that clears is forgotten, so a later one is reported again.
    restarted.forget(ID);
    restarted.pass();
    assert_eq!(log_lines("return-observation-problem", ID).len(), 2, "a fresh problem after a clean observation is new information");
}

/// 5. A directory that is gone is forgotten, so a later request with the same id does not inherit its silence.
#[test]
fn a_directory_that_is_gone_is_forgotten() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new("gone");
    scratch.finished_deploy(ID);
    let mut lane = observation::Observations::load();
    lane.pass();
    assert_eq!(log_lines("return-observation-problem", ID).len(), 1);

    std::fs::remove_dir_all(scratch.dir(ID)).expect("remove the protocol directory");
    lane.pass();
    scratch.finished_deploy(ID);
    lane.pass();
    assert_eq!(
        log_lines("return-observation-problem", ID).len(),
        2,
        "a directory that came back is a directory to observe again, not one already reported"
    );
}

/// 6. A runtime problem is retried and never retired, however long it persists.
#[test]
fn a_runtime_problem_is_never_retired() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new("runtime");
    std::env::set_var("WASM_SENTINEL_OBSERVE_GRACE", "0");
    // A port nothing listens on: an observation that reaches the owner check must fail here, at once, and never
    // meet the node this machine really runs (the crate's rule for every test in it).
    std::env::set_var("WASM_AGENT_PORT", "1");
    // The files intake writes are present, so this is not a structural problem: the observation fails for a
    // reason that can clear (no node, no owner to confirm the binding).
    let dir = scratch.dir(ID);
    std::fs::create_dir_all(&dir).unwrap();
    for name in ["intent.json", "ack.json", "binding.json"] {
        std::fs::write(dir.join(name), b"{}").unwrap();
    }
    let mut lane = observation::Observations::load();
    lane.pass();
    lane.pass();
    lane.pass();
    assert!(dir.is_dir(), "a runtime failure keeps its directory: the retry is what would see it clear");
    let lines = log_lines("return-observation-problem", ID);
    assert!(!lines.is_empty(), "the first failure is still reported");
    assert!(log_lines("return-observation-retired", ID).is_empty(), "nothing was retired");
}

/// 6. A held protocol deploy - intent and ack from the real intake, no binding because admit has not run - keeps its
/// directory however long it is held, and says at most one line about it.
///
/// The defect (review of 18/11, item 7): binding.json is written at admit, intent.json and ack.json on every tick,
/// so a deploy held past the grace (a busy node, a protocol that is not ready, a parent whose owner cannot be read)
/// was judged structural - retired into deploy-protocol-retired/ with its evidence, recreated by the next intake
/// under the same id, and then retired into an occupied lane on every tick for ever. The rule now asks what is in
/// flight instead of which file is absent.
#[test]
fn a_held_deploy_survives_the_grace_with_one_line() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new("held");
    // No grace at all: the strongest form of the rule, and the one that would retire a healthy deploy.
    std::env::set_var("WASM_SENTINEL_OBSERVE_GRACE", "0");
    scratch.held_deploy(ID);

    let mut lane = observation::Observations::load();
    for _ in 0..50 {
        lane.pass();
    }

    assert!(scratch.dir(ID).is_dir(), "a held deploy keeps its directory however long it is held");
    assert!(!sentinel_dir().join("deploy-protocol-retired").join(ID).exists(), "and nothing was retired");
    let lines = log_lines("return-observation-problem", ID);
    assert_eq!(lines.len(), 1, "one line at most, for a deploy that is merely held: {lines:?}");
    assert!(lines[0].contains("missing binding.json"), "it names what is not written yet: {}", lines[0]);
    assert!(log_lines("return-observation-retired", ID).is_empty(), "a held deploy is never retired");
    assert!(log_lines("return-observation-retire-failed", ID).is_empty(), "and no retirement is attempted");
}

/// 7. A retirement that cannot happen is said once: the retired lane holds that id, the evidence in it is never
/// overwritten, and the rule must stop answering Retire instead of writing a line on every tick.
#[test]
fn a_retirement_that_cannot_happen_is_said_once() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new("retire-failed");
    std::env::set_var("WASM_SENTINEL_OBSERVE_GRACE", "0");
    scratch.finished_deploy(ID);
    // An earlier generation under this same request id was retired here, and its evidence is kept, not replaced.
    let retired = sentinel_dir().join("deploy-protocol-retired").join(ID);
    std::fs::create_dir_all(&retired).expect("the retired lane");
    std::fs::write(retired.join("result.json"), br#"{"ok":true,"commit":"2199eaff"}"#).expect("earlier evidence");

    let mut lane = observation::Observations::load();
    for _ in 0..20 {
        lane.pass();
    }

    let failed = log_lines("return-observation-retire-failed", ID);
    assert_eq!(failed.len(), 1, "one line, not one per tick: {failed:?}");
    assert!(failed[0].contains("no further retirement is attempted"), "{}", failed[0]);
    assert_eq!(
        std::fs::read(retired.join("result.json")).unwrap(),
        br#"{"ok":true,"commit":"2199eaff"}"#,
        "evidence in the retired lane is never overwritten"
    );
    assert!(scratch.dir(ID).is_dir(), "the directory stays in the lane, quietly");
    assert_eq!(log_lines("return-observation-problem", ID).len(), 1, "and the problem itself was said once");
}

/// 8. A withdrawal that still owes its report is not retired either: the binding admit never wrote is what the
/// observation that follows establishes, and retiring the directory would throw the session's one answer away.
#[test]
fn a_withdrawn_deploy_is_not_retired_before_its_report() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new("withdrawn");
    std::env::set_var("WASM_SENTINEL_OBSERVE_GRACE", "0");
    // A port nothing listens on: the owner lookup cannot be answered, so the report stays owed - the case in which
    // a retired directory would leave the asking session waiting for ever.
    std::env::set_var("WASM_AGENT_PORT", "1");
    scratch.held_deploy(ID);
    withdraw_request(ID, "no longer needed").expect("a queued protocol deploy can be withdrawn");
    let dir = scratch.dir(ID);
    assert!(!dir.join("binding.json").exists(), "the binding admit never wrote is still missing");

    let mut lane = observation::Observations::load();
    for _ in 0..20 {
        lane.pass();
    }

    assert!(dir.is_dir(), "a withdrawal that owes its report keeps its directory");
    assert!(log_lines("return-observation-retired", ID).is_empty(), "nothing is retired");
    let lines = log_lines("return-observation-problem", ID);
    assert_eq!(lines.len(), 1, "one line says why the report is waiting: {lines:?}");
    assert!(lines[0].contains("parent_owner_unavailable"), "and names what blocks it: {}", lines[0]);
}

/// 9. A deferral is not an observation. The engine keeps its own ten-second cadence (backing off after a failure)
/// and says nothing while a directory is deferred; the lane used to treat that silence as "observed cleanly" and
/// forget the problem, so the next real attempt reported it again - "one line per (id, problem)" at a term's length
/// instead of a tick's. Found while writing the tests above, and the same defect class as the per-tick line this
/// lane exists to remove.
#[test]
fn a_deferred_observation_does_not_forget_the_problem() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new("deferred");
    // A port nothing listens on: the observation fails every time it is really attempted, with the same text.
    std::env::set_var("WASM_AGENT_PORT", "1");
    scratch.held_deploy(ID);
    withdraw_request(ID, "no longer needed").expect("the queued protocol deploy is withdrawn");
    let dir = scratch.dir(ID);
    let mut lane = observation::Observations::load();
    lane.pass();
    assert_eq!(log_lines("return-observation-problem", ID).len(), 1, "the first real attempt is one line");
    lane.pass();
    // The engine's own backoff expires. The test moves the deadline instead of waiting the ten seconds for it.
    let poll: Value = serde_json::from_slice(&std::fs::read(dir.join("observation-poll.json")).unwrap()).unwrap();
    wa_operation::atomic_json(&dir.join("observation-poll.json"), &json!({"id": ID, "next_at": 0, "failures": poll["failures"]})).unwrap();
    lane.pass();
    let lines = log_lines("return-observation-problem", ID);
    assert_eq!(lines.len(), 1, "the same problem is one line however often it is observed: {lines:?}");
}
