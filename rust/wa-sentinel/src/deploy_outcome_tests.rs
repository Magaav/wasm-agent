//! The guarantee, forced four ways: success, failure, silence, and exactly one notice per deploy.
//!
//! The defect these tests exist for (measured 2026-11-10, session `b5a92f25`): a deploy the sentinel handled
//! for a session reported nothing back when the installer died, when the node was replaced, or when the
//! request happened to carry no session - and nothing noticed the silence. The session sat idle for 1h45m.
//!
//! What is asserted here, with no node, no installer and no model:
//!
//!   1. **success** - the wait on the installer's exit settles the ledger, and the session gets one notice
//!      naming the install and the commit `installed.txt` names;
//!   2. **failure** - the installer's own `result.json` beats a bare exit status, and its refusal reason is
//!      carried into the notice;
//!   3. **silent** - an installer that vanished without a word is reported by the watchdog after the
//!      timeout, with the deploy id, the last step, the installer's pid and whether it is still alive, and the
//!      installed commit; a deploy that is *still* being installed is not reported, and one the sentinel is
//!      still holding in its box is not reported either;
//!   4. **exactly one** - every outcome settles once, the second settler and every later sweep are no-ops,
//!      and a deploy whose notice is already in the box adopts it instead of queueing a second.
//!
//! Falsification (run by hand, and reported with its FAIL line - a test that cannot fail proves nothing):
//!   * delete the `deploy_outcome::settle_from_exit` call in `watch_deploy_exit` - the success and failure
//!     cases fall through to the watchdog and `each_outcome_produces_exactly_one_notice` fails on the
//!     `success:` line;
//!   * make `sweep` skip the deadline (`if now < due { continue }` -> `continue`) - the silent case fails on
//!     "the watchdog must report a deploy whose installer vanished".

use super::*;
use std::ffi::OsString;

/// A test's own state and install directories, both restored when the test ends.
///
/// `WASM_AGENT_HOME` is where the sentinel keeps its box, its queue and now its deploy ledger;
/// `WA_INSTALL_DIR` is where `installed.txt` and `deploy-result.json` are read from. Both must point at the
/// fixture or these tests would read the machine's real deploy.
struct Fixture {
    dir: PathBuf,
    install: PathBuf,
    restore: Vec<(&'static str, Option<OsString>)>,
}

impl Fixture {
    fn new(label: &str) -> Fixture {
        let dir = std::env::temp_dir().join(format!("wa-deploy-outcome-{}-{label}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let install = dir.join("install");
        std::fs::create_dir_all(&install).expect("fixture install directory");
        for sub in ["requests", "claimed", "done", "failed", "deploy-outcome"] {
            std::fs::create_dir_all(dir.join(".wasm-agent").join("sentinel").join(sub))
                .expect("fixture sentinel directory");
        }
        let mut fixture = Fixture { dir, install, restore: Vec::new() };
        fixture.set("WASM_AGENT_HOME", fixture.dir.display().to_string());
        fixture.set("WA_INSTALL_DIR", fixture.install.display().to_string());
        fixture.unset("WA_SENTINEL_DEPLOY_TIMEOUT");
        fixture.set("WASM_AGENT_PROVENANCE", "operator".to_string());
        fixture
    }

    fn set(&mut self, key: &'static str, value: String) {
        if !self.restore.iter().any(|(saved, _)| *saved == key) {
            self.restore.push((key, std::env::var_os(key)));
        }
        std::env::set_var(key, value);
    }

    fn unset(&mut self, key: &'static str) {
        if !self.restore.iter().any(|(saved, _)| *saved == key) {
            self.restore.push((key, std::env::var_os(key)));
        }
        std::env::remove_var(key);
    }

    fn state(&self) -> PathBuf {
        self.dir.join(".wasm-agent").join("sentinel")
    }

    fn record(&self, id: &str) -> PathBuf {
        self.state().join("deploy-outcome").join(format!("{id}.json"))
    }

    /// `installed.txt` as the installer writes it, so a notice can be checked against a real record.
    fn installed(&self, commit: &str) {
        std::fs::write(self.install.join("installed.txt"), format!("commit={commit}\nbranch=main\n"))
            .expect("fixture installed.txt");
    }

    fn result(&self, id: &str, ok: bool, detail: &str) {
        let dir = self.state().join("deploy-protocol").join(id);
        std::fs::create_dir_all(&dir).expect("fixture result directory");
        std::fs::write(
            dir.join("result.json"),
            serde_json::json!({"ok": ok, "commit": "af72e969", "detail": detail, "request_id": id}).to_string(),
        )
        .expect("fixture deploy result");
    }

    /// Every notice in the box, in a stable order.
    fn notices(&self) -> Vec<Value> {
        let dir = self.state().join("requests");
        let mut found: Vec<Value> = std::fs::read_dir(&dir)
            .map(|entries| {
                entries
                    .flatten()
                    .filter(|entry| entry.file_name().to_string_lossy().starts_with("deploy-return-"))
                    .filter_map(|entry| std::fs::read(entry.path()).ok())
                    .filter_map(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
                    .collect()
            })
            .unwrap_or_default();
        found.sort_by(|a, b| a["prompt"].as_str().cmp(&b["prompt"].as_str()));
        found
    }

    /// Age the ledger the way a real deploy would: the installer started long enough ago to be due.
    fn rewind(&self, id: &str, seconds: u64) {
        let path = self.record(id);
        let mut record: Value = serde_json::from_slice(&std::fs::read(&path).expect("record exists"))
            .expect("record is json");
        let now = now_epoch();
        record["started_at"] = json!(now.saturating_sub(seconds));
        record["requested_at"] = json!(now.saturating_sub(seconds));
        wa_operation::atomic_json(&path, &record).expect("rewound record");
    }

    /// Age a record whose installer never started: requested long ago, `started_at` still absent.
    fn rewind_unstarted(&self, id: &str, seconds: u64) {
        let path = self.record(id);
        let mut record: Value = serde_json::from_slice(&std::fs::read(&path).expect("record exists"))
            .expect("record is json");
        record["requested_at"] = json!(now_epoch().saturating_sub(seconds));
        record["started_at"] = Value::Null;
        wa_operation::atomic_json(&path, &record).expect("rewound record");
    }

    /// Open an ledger record exactly as `request deploy --session … --prompt …` does.
    fn open(&self, id: &str, session: &str, prompt: &str) {
        deploy_outcome::open(
            id,
            &serde_json::json!({"verb": "deploy", "id": id, "session": session, "prompt": prompt,
                "reason": "fixture", "queued_at": now_epoch()}),
        )
        .expect("the deploy ledger opens");
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        for (key, value) in self.restore.drain(..) {
            match value {
                Some(value) => std::env::set_var(key, value),
                None => std::env::remove_var(key),
            }
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn dead_pid() -> u32 {
    // A pid no process can hold: past every platform's maximum. Asserted, not assumed - if it ever *is* alive
    // the test says so instead of quietly passing on the wrong branch.
    let pid = u32::MAX - 1;
    assert!(!pid_alive(pid), "the fixture's `dead` pid {pid} is alive; this machine reuses pids oddly");
    pid
}

const SESSION: &str = "b5a92f25-76e8-4ad5-84b3-bdd3d6a0fc15";

/// All three outcomes, each forced, each producing **exactly one** notice that says what happened.
#[test]
fn each_outcome_produces_exactly_one_notice() {
    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new("outcomes");
    fixture.installed("af72e969");

    // 1. success: the sentinel's wait on the installer saw it exit 0, and the installer recorded its result.
    let success = "1794305337796210000-5540-00000000000000000000";
    fixture.open(success, SESSION, "verify whatsapp_search returns served_by=openclaw");
    deploy_outcome::started(success, Some(std::process::id()));
    fixture.result(success, true, "installed af72e969; watcher 3684");
    deploy_outcome::settle_from_exit(success, true);

    // 2. failure: the installer refused and said why; the exit status is non-zero as well.
    let failure = "1794305647073540900-7132-00000000000000000000";
    fixture.open(failure, SESSION, "retry the install");
    deploy_outcome::started(failure, Some(std::process::id()));
    fixture.result(failure, false, "refused(no_space): not enough room for the binary; nothing installed");
    deploy_outcome::settle_from_exit(failure, false);

    // 3. silence: the installer vanished, recorded nothing, and the timeout has passed.
    let silent = "1794309999999999999-1000-00000000000000000000";
    fixture.open(silent, SESSION, "check it landed");
    deploy_outcome::started(silent, Some(dead_pid()));
    fixture.rewind(silent, deploy_outcome::timeout_secs() + 5);
    let reported = deploy_outcome::sweep(now_epoch());

    let notices = fixture.notices();
    assert_eq!(reported, 1, "the watchdog must settle exactly the one due deploy, got {reported}");
    assert_eq!(notices.len(), 3, "one notice per deploy: {notices:#?}");

    let by_prompt = |needle: &str| -> &Value {
        notices
            .iter()
            .find(|notice| notice["prompt"].as_str().unwrap_or("").contains(needle))
            .unwrap_or_else(|| panic!("no notice mentions {needle:?}: {notices:#?}"))
    };
    let success_notice = by_prompt("Deploy 1794305337796210000-5540");
    let prompt = success_notice["prompt"].as_str().unwrap();
    assert!(prompt.contains("finished"), "a success notice says so: {prompt}");
    assert!(prompt.contains("installed af72e969; watcher 3684"), "the installer's own words: {prompt}");
    assert!(prompt.contains("installed.txt now names af72e969"), "the recorded commit: {prompt}");
    assert!(prompt.contains("verify whatsapp_search returns served_by=openclaw"),
        "the caller's own continuation is carried, not dropped: {prompt}");
    assert_eq!(success_notice["session"], json!(SESSION), "it is addressed to the session that asked");

    let failure_notice = by_prompt("Deploy 1794305647073540900-7132");
    let prompt = failure_notice["prompt"].as_str().unwrap();
    assert!(prompt.contains("FAILED"), "a failure notice says so: {prompt}");
    assert!(prompt.contains("refused(no_space)"), "with the reason the installer gave: {prompt}");
    assert!(prompt.contains("Nothing in this report establishes what is installed"),
        "and claims nothing about the install: {prompt}");

    let silent_notice = by_prompt("Deploy 1794309999999999999-1000");
    let prompt = silent_notice["prompt"].as_str().unwrap();
    assert!(prompt.contains("SILENT"), "a timeout notice says so: {prompt}");
    assert!(prompt.contains("within 900s"), "and names the timeout it waited, N=900s: {prompt}");
    assert!(prompt.contains(&format!("pid {} (gone)", dead_pid())), "the installer, and that it is gone: {prompt}");
    assert!(prompt.contains("installed.txt names af72e969"), "what is installed now: {prompt}");
    assert!(prompt.contains("no second notice will come for it"),
        "and that this is the one report this deploy gets: {prompt}");
}

/// Exactly once: a second settler, and every later sweep, add nothing - including the watchdog racing the
/// installer's own exit.
#[test]
fn a_settled_deploy_is_never_reported_twice() {
    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new("exactly-once");
    fixture.installed("090858da");
    let id = "1794321057000000000-3684-00000000000000000000";
    fixture.open(id, SESSION, "check it");
    deploy_outcome::started(id, Some(dead_pid()));
    fixture.result(id, false, "the installer was killed mid-swap");

    deploy_outcome::settle_from_exit(id, false);
    assert_eq!(fixture.notices().len(), 1, "the installer's exit reports it once");
    assert!(!deploy_outcome::settle(id, "silent", "a second opinion").expect("settling is idempotent"),
        "a settled deploy is not settled again");
    fixture.rewind(id, deploy_outcome::timeout_secs() + 60);
    assert_eq!(deploy_outcome::sweep(now_epoch()), 0, "the watchdog has nothing left to say");
    assert_eq!(fixture.notices().len(), 1, "one notice per deploy, whatever the order of the races");
}

/// A deploy nobody can report - the old watcher died, the request left the box, the installer is gone - is
/// still reported, because the report is read off the disk and not out of a process's memory.
#[test]
fn a_replaced_watcher_reports_from_disk_alone() {
    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new("replaced-watcher");
    fixture.installed("67e9448f");
    let id = "1794303580192636000-12160-00000000000000000000";
    // Written exactly as the request door writes it, then nothing else touches it: no started_at, because the
    // watcher that would have recorded the installer died, and no request in the box, because it was claimed.
    fixture.open(id, SESSION, "verify the install");
    fixture.rewind(id, deploy_outcome::timeout_secs() + 1);
    queue::observe(&json!({"verb": "deploy", "reason": "fixture", "queued_at": now_epoch()}), id,
        "running", "deploying", "running deploy.sh detached");

    assert_eq!(deploy_outcome::sweep(now_epoch()), 1, "a deploy with nobody left to report it is reported");
    let notices = fixture.notices();
    assert_eq!(notices.len(), 1, "{notices:#?}");
    let prompt = notices[0]["prompt"].as_str().unwrap();
    assert!(prompt.contains(id), "the notice names the deploy: {prompt}");
    assert!(prompt.contains("running deploy.sh detached"), "and the last step the queue saw: {prompt}");
    assert!(prompt.contains("installed.txt names 67e9448f"), "and what is installed: {prompt}");
}

/// The installer wrote its verdict and then the watcher that spawned it was replaced. The file is the outcome -
/// not a timeout - and its detail is what the session reads.
#[test]
fn the_installers_result_survives_the_watcher_that_spawned_it() {
    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new("result-after-restart");
    fixture.installed("af72e969");
    let id = "1794305337796210000-5540-00000000000000000001";
    fixture.open(id, SESSION, "");
    fixture.rewind(id, deploy_outcome::timeout_secs() + 30);
    fixture.result(id, false, "the node did not answer /health after the swap; rolled back");

    assert_eq!(deploy_outcome::sweep(now_epoch()), 1, "the result file settles it");
    let notices = fixture.notices();
    assert_eq!(notices.len(), 1);
    let prompt = notices[0]["prompt"].as_str().unwrap();
    assert!(prompt.contains("FAILED"), "the installer's verdict, not a timeout: {prompt}");
    assert!(prompt.contains("rolled back"), "with the installer's own reason: {prompt}");
    assert!(!prompt.contains("SILENT"), "a recorded failure is not silence: {prompt}");
}

/// A deploy that is still installing is not silent, and neither is one the sentinel is still holding in its box
/// (a deploy waits for an idle node - the measured 06:39 deploy waited for its own author's turn to end).
#[test]
fn a_live_install_and_a_held_request_are_not_reported_as_silent() {
    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new("not-yet");

    // Started just now, installer alive: nothing to say yet.
    let running = "1794310000000000000-1-0000000000000000000001";
    fixture.open(running, SESSION, "");
    deploy_outcome::started(running, Some(std::process::id()));
    assert_eq!(deploy_outcome::sweep(now_epoch()), 0, "an installer that is still working is not silent");

    // Never started, but still in the box: the sentinel is holding it, and says so in `status`.
    let held = "1794310000000000000-2-0000000000000000000002";
    fixture.open(held, SESSION, "");
    fixture.rewind_unstarted(held, deploy_outcome::timeout_secs() * 4);
    std::fs::write(fixture.state().join("requests").join(format!("{held}.json")),
        json!({"verb": "deploy", "session": SESSION, "queued_at": now_epoch()}).to_string())
        .expect("held request");
    assert_eq!(deploy_outcome::sweep(now_epoch()), 0, "a held deploy is not a silent one");

    // Once it leaves the box without an installer ever being recorded, the same deploy is due.
    std::fs::remove_file(fixture.state().join("requests").join(format!("{held}.json"))).expect("claim it");
    assert_eq!(deploy_outcome::sweep(now_epoch()), 1, "a request that vanished with no installer is reported");
    assert_eq!(fixture.notices().len(), 1, "and only the one that was due");
}

/// End to end through the sentinel's own code: `verb_deploy_script` spawns the installer, records the pid in
/// the ledger, waits for it, and settles the session from the result file the installer wrote - nothing here
/// calls `settle` by hand. This is the wiring the falsification at the top of the file breaks.
#[test]
fn the_sentinel_spawns_waits_and_reports_a_deploy_end_to_end() {
    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new("end-to-end");
    fixture.installed("e30805cf");
    // A stub installer that answers exactly as deploy.sh does: it records its verdict against the request id it
    // was given, then exits 0. What is asserted is that the *sentinel* turns that into one notice.
    let stub = fixture.dir.join("ok-deploy.sh");
    std::fs::write(
        &stub,
        r#"#!/bin/sh
id=''
while [ $# -gt 0 ]; do case "$1" in --request-id) id="$2"; shift 2 ;; *) shift ;; esac; done
printf '{"ok":true,"commit":"e30805cf","detail":"installed e30805cf; watcher 4242","request_id":"%s"}' "$id" > "$WA_INSTALL_DIR/deploy-result.json"
exit 0
"#,
    )
    .expect("stub deploy");
    let id = "1794321057000000000-3684-0000000000000000009000";
    fixture.open(id, SESSION, "verify the install landed");

    let capture = deploy_capture_path();
    verb_deploy_script(&stub, id, SESSION, "verify the install landed", "end-to-end fixture", &capture)
        .expect("the deploy is accepted");

    // The pid is recorded before the wait, so a notice can say whether the installer is still alive.
    let record = deploy_outcome::read(id).expect("the ledger record exists");
    assert_eq!(record["state"], json!("pending"), "pending while the installer runs: {record}");
    assert!(record["installer_pid"].as_u64().is_some_and(|pid| pid > 0),
        "the installer pid is recorded: {record}");

    // The exit wait is a thread, so the assertion waits for its effect instead of assuming a schedule.
    let mut notices = Vec::new();
    for _ in 0..100 {
        notices = fixture.notices();
        if !notices.is_empty() {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(notices.len(), 1, "the exit wait settles the deploy exactly once: {notices:#?}");
    let prompt = notices[0]["prompt"].as_str().unwrap();
    assert!(prompt.contains("finished"), "the installer exited 0 and said so: {prompt}");
    assert!(prompt.contains("installed e30805cf; watcher 4242"), "with the installer's own words: {prompt}");
    let record = deploy_outcome::read(id).expect("the ledger record exists");
    assert_eq!(record["state"], json!("settled"), "and the ledger says so: {record}");
    assert_eq!(record["outcome"], json!("success"), "{record}");
}

/// The measured 07:09 deploy: written with no `--session`, so there was no address for a notice. It must not
/// open a ledger record (there is nowhere to report), must still be written as a request - the work is real even
/// when nobody asked to hear about it - and the door must say so instead of promising a wake that cannot come.
#[test]
fn a_deploy_with_no_session_opens_no_record_and_says_so() {
    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new("no-session");
    request(&["deploy".into(), "--reason".into(), "fixture: no session".into()])
        .expect("a deploy with no session is still a request");
    assert_eq!(std::fs::read_dir(fixture.state().join("requests")).expect("box").count(), 1,
        "the deploy itself is requested");
    assert_eq!(std::fs::read_dir(fixture.state().join("deploy-outcome")).map(|entries| entries.count()).unwrap_or(0), 0,
        "no ledger record: a deploy with no session has no address to report into");

    // With a session, the same door opens exactly one record, and that record names the session.
    request(&["deploy".into(), "--session".into(), SESSION.into(), "--prompt".into(), "go".into(),
        "--reason".into(), "fixture: with session".into()]).expect("a deploy with a session is requested");
    let records: Vec<Value> = std::fs::read_dir(fixture.state().join("deploy-outcome")).expect("ledger")
        .flatten()
        .filter_map(|entry| std::fs::read(entry.path()).ok())
        .filter_map(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .collect();
    assert_eq!(records.len(), 1, "one record for the one deploy that named a session: {records:#?}");
    assert_eq!(records[0]["session"], json!(SESSION), "the record carries the address: {records:#?}");
    assert_eq!(records[0]["state"], json!("pending"), "and starts pending, before the installer exists");
}

/// The link the live proof broke on (2026-11-10 12:38): a legacy deploy's request file carried **no id**, so
/// `perform` handed the installer nothing to attribute its result to, `installer_pid` was never recorded, and
/// the session's report fell through to the 900s watchdog instead of carrying the installer's own verdict.
/// The request and its ledger record must name the same deploy.
#[test]
fn a_deploy_request_names_itself_so_the_installer_can_report() {
    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new("request-id");
    request(&["deploy".into(), "--session".into(), SESSION.into(), "--prompt".into(), "go".into(),
        "--reason".into(), "fixture: request id".into()]).expect("the deploy is requested");

    let read_all = |dir: PathBuf| -> Vec<Value> {
        std::fs::read_dir(dir).expect("directory")
            .flatten()
            .filter_map(|entry| std::fs::read(entry.path()).ok())
            .filter_map(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .collect()
    };
    let records = read_all(fixture.state().join("deploy-outcome"));
    let requests = read_all(fixture.state().join("requests"));
    assert_eq!(records.len(), 1, "{records:#?}");
    assert_eq!(requests.len(), 1, "{requests:#?}");
    let record_id = records[0]["id"].as_str().expect("the record names its deploy");
    assert_eq!(requests[0]["id"], json!(record_id),
        "the request must carry the same id the ledger uses - that string is what `perform` passes as \
         --request-id, and without it nothing can attribute the installer's result to this deploy: {:#?}",
        requests[0]);
    assert_eq!(requests[0]["verb"], json!("deploy"));
}

/// The door the 07:14 retry used: an installer through `run`. Refused before any file exists, naming the door
/// that does report.
#[test]
fn an_installer_cannot_be_run_through_the_run_door() {
    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new("installer-run");
    let error = request(&["run".into(), "--script".into(), "scripts/deploy.sh".into(),
        "--reason".into(), "fixture".into()]).unwrap_err().to_string();
    assert!(error.contains("installer_run_refused"), "{error}");
    assert!(error.contains("request deploy --session"), "it names the door that reports: {error}");
    assert_eq!(std::fs::read_dir(fixture.state().join("requests")).expect("box").count(), 0,
        "a refused request writes nothing");
    assert!(installer_script("scripts/deploy.sh"), "deploy.sh is the installer");
    assert!(installer_script("upgrade.sh"), "upgrade.sh is the installer");
    assert!(!installer_script("scripts/deploy-rendezvous.sh"),
        "a component installer run from outside a turn is not the node installer");
}
