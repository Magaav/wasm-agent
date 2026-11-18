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
//!   5. a *runtime* problem (one that can clear) is never retired, however long it persists.
//!
//! Falsification, each run by hand:
//!
//!   * audit on every pass instead of on the rule - `a_missing_file_is_reported_once_however_many_ticks_go_by`
//!     fails with 50 lines where the log had one, which is the measured defect at a smaller scale;
//!   * retire on the first report instead of after the grace - `a_missing_file_is_reported_once_however_many_ticks_go_by`
//!     fails, because the directory is gone before the grace, which is how a slow intake would lose a live
//!     deploy;
//!   * retire a runtime problem too - `a_runtime_problem_is_never_retired` fails with a live deploy's
//!     directory in the retired lane and its report thrown away.

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
    assert_eq!(observation::verdict(None, "missing ack.json", 100, 300, true), observation::Verdict::Report);
    assert_eq!(
        observation::verdict(Some(("missing ack.json", 100)), "missing ack.json", 399, 300, true),
        observation::Verdict::Quiet,
        "the same problem inside the grace is not news"
    );
    assert_eq!(
        observation::verdict(Some(("missing ack.json", 100)), "missing ack.json", 400, 300, true),
        observation::Verdict::Retire,
        "a structural problem that never clears stops being observed"
    );
    assert_eq!(
        observation::verdict(Some(("parent_owner_unavailable", 100)), "parent_owner_unavailable", 100_000, 300, false),
        observation::Verdict::Quiet,
        "a runtime problem is retried, never retired: the retry is what would see it clear"
    );
    assert_eq!(
        observation::verdict(Some(("missing ack.json", 100)), "missing binding.json", 101, 300, true),
        observation::Verdict::Report,
        "a changed problem is a changed fact"
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
