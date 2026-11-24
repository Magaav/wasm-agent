//! A SPAWNED INSTALLER ALWAYS ENDS IN A VERDICT, judged from the three files it leaves (23/11, G blocker).
//!
//! MEASURED: `ffd2a0a5`'s installer was spawned at 1795475320, refused the install
//! (`deploy: refused(component_proof_failed)`), wrote none of the protocol files, and the lane retired its directory
//! as unobservable - `installed.txt` still named `4425f670` and the box said `0 waiting` forty minutes later.

use super::*;
use installer_outcome::{verdict_of, Outcome};

const TARGET: &str = "ffd2a0a5dd92cf0133f35f3c02de28355867bf58";
const OLD: &str = "4425f670b48eae9449625702aa2ddfe7f1151ba9";
const REASON: &str = "land-quick deploy-hold-never-fails-our-load (ffd2a0a5)";

const MAIN: &str = "345e51be8f0a4b9c1d2e3f405162738495a6b7c8";
const STALE: &str = "74d48431a1b2c3d4e5f60718293a4b5c6d7e8f90";

/// A test's own sentinel home and install directory, both restored when it ends - the two stores `verdict(id)`
/// reads. Never the machine's own (the real box is `$HOME/.wasm-agent/sentinel`): a verdict judged against the
/// node's own records would be a claim about the machine, not about this code.
struct Fixture {
    dir: PathBuf,
    install: PathBuf,
    restore: Vec<(&'static str, Option<std::ffi::OsString>)>,
}

impl Fixture {
    fn new(label: &str) -> Fixture {
        let dir = std::env::temp_dir().join(format!("wa-installer-outcome-{}-{label}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let install = dir.join("install");
        std::fs::create_dir_all(&install).expect("fixture install directory");
        std::fs::create_dir_all(dir.join(".wasm-agent").join("sentinel").join("done")).expect("fixture box");
        let node = std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".wasm-agent").join("sentinel"));
        assert_ne!(Some(dir.join(".wasm-agent").join("sentinel")), node,
            "the fixture store must never be the node's own sentinel directory");
        let mut fixture = Fixture { dir, install, restore: Vec::new() };
        fixture.set("WASM_AGENT_HOME", fixture.dir.display().to_string());
        fixture.set("WA_INSTALL_DIR", fixture.install.display().to_string());
        fixture
    }

    fn set(&mut self, key: &'static str, value: String) {
        if !self.restore.iter().any(|(saved, _)| *saved == key) {
            self.restore.push((key, std::env::var_os(key)));
        }
        std::env::set_var(key, value);
    }

    fn state(&self) -> PathBuf {
        self.dir.join(".wasm-agent").join("sentinel")
    }

    /// The request in the lane `verdict` reads it from: `done/<id>.json`, as the sentinel writes it.
    fn done(&self, id: &str, request: Value) {
        let record = json!({"at": 1795475320u64, "ok": true, "phase": "spawned", "request": request});
        std::fs::write(self.state().join("done").join(format!("{id}.json")), record.to_string())
            .expect("fixture done record");
    }

    /// The installer's own log, at the path the verdict reads (`sentinel.log`).
    fn log(&self, text: &str) {
        std::fs::write(self.state().join("sentinel.log"), text).expect("fixture installer log");
    }

    /// `installed.txt` as the installer writes it (`commit=`), so the verdict reads the product's own file
    /// through the product's own reader (`deploy_outcome::installed_commit`).
    fn installed(&self, commit: &str) {
        std::fs::write(self.install.join("installed.txt"), format!("commit={commit}\nbranch=main\n"))
            .expect("fixture installed.txt");
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

fn log(body: &str) -> String {
    format!(
        "--- deploy unit wa-deploy-1795474000-42 at 1795474000 script /x/deploy.sh reason another landing\ndeploy: installed\n{body}"
    )
}

/// The refusal this mission measured, word for word from `sentinel/deploy.out`.
fn refused() -> String {
    log(&format!(
        "--- deploy unit wa-deploy-1795475320-1196761 at 1795475320 script /x/deploy.sh reason {REASON}\ndeploy: building\ndeploy: refused(component_proof_failed): the candidate binary did not answer a graph call through the staged component; nothing installed\n"
    ))
}

/// 1. Installed: the install record names the commit the request asked for - whatever the log says about earlier runs.
#[test]
fn an_install_that_reached_the_record_is_installed() {
    assert_eq!(verdict_of(TARGET, TARGET, &refused(), REASON), Outcome::Installed);
    assert_eq!(verdict_of(TARGET, "ffd2a0a5dd92", &log(""), REASON), Outcome::Installed,
        "an abbreviated record commit still names it");
}

/// 2. THE MEASURED CASE: the record still names the old commit and the installer's own block ends in a refusal.
#[test]
fn a_refused_installer_is_a_failure_with_its_own_sentence() {
    match verdict_of(TARGET, OLD, &refused(), REASON) {
        Outcome::Uninstalled(why) => {
            assert!(why.contains("refused(component_proof_failed)"), "the installer's own words: {why}");
            assert!(why.contains("nothing installed"), "including that nothing was installed: {why}");
        }
        other => panic!("a refused install is not {other:?}"),
    }
}

/// 3. Still running: a block with no terminal line yet is NOT a verdict - nothing is claimed about it.
#[test]
fn an_installer_with_no_terminal_line_is_still_running() {
    let running = log(&format!(
        "--- deploy unit wa-deploy-1795475320-1196761 at 1795475320 script /x/deploy.sh reason {REASON}\ndeploy: building\ndeploy: compiled 255 + 39 crate(s)\n"
    ));
    assert_eq!(verdict_of(TARGET, OLD, &running, REASON), Outcome::Running);
}

/// 4. The blocks are told apart by the REASON the request carries, not by position: the `installed` of an earlier
/// landing never answers for this one.
#[test]
fn an_earlier_installers_success_is_not_this_requests() {
    let only_other = "--- deploy unit wa-deploy-1-1 at 1 script /x/deploy.sh reason another landing\ndeploy: installed\n";
    match verdict_of(TARGET, OLD, only_other, REASON) {
        Outcome::Uninstalled(why) => assert!(why.contains("no installer block"), "{why}"),
        other => panic!("an absent block is not a success: {other:?}"),
    }
}

/// 5. A request with no target commit has no verdict at all: unknown is not yes.
#[test]
fn a_request_without_a_commit_claims_nothing() {
    assert_eq!(verdict_of("", OLD, &refused(), REASON), Outcome::Running);
}


/// 7. THE VERDICT IS JUDGED BY WHAT WAS DEMANDED (24/11). A protocol request carries two commits:
/// `expected_sha` - what it demanded, which `deploy.sh` revalidates and installs and nothing else - and
/// `target_commit`, what a deploy would have installed when the request was WRITTEN, which is advisory. On
/// `work` the second was a `host` bundle's main SEVEN DAYS BEHIND, while the installer built and installed
/// origin/main: a request that installed exactly what it demanded was judged against a commit it never
/// mentioned, and with a rotated log it failed. There is no log here at all - the record is the only evidence.
#[test]
fn an_expected_sha_outranks_the_recorded_target() {
    let fixture = Fixture::new("expected-first");
    let id = "1795475320000000000-4242-00000000000000000000";
    fixture.done(id, json!({"verb": "deploy", "id": id, "queued_at": 1795475320u64,
        "expected_sha": MAIN, "target_commit": STALE, "reason": REASON}));
    fixture.installed(MAIN);
    assert_eq!(installer_outcome::verdict(id), Some(Outcome::Installed),
        "the install record names what was demanded: this request installed");

    // ... and the same request is NOT satisfied by a record naming the advisory target instead: the record is
    // evidence only for the commit the request demanded.
    fixture.installed(STALE);
    match installer_outcome::verdict(id) {
        Some(Outcome::Uninstalled(why)) => assert!(why.contains("no installer block"), "said plainly: {why}"),
        other => panic!("a record naming another commit is not this request's install: {other:?}"),
    }
}

/// 8. THE SAME COMMIT AT TWO LENGTHS. A request's commit and the install record's are written by different
/// programs and may differ in length - a deploy records the short form, a request can carry either - so the
/// shorter names the comparison, in BOTH directions. Measured shape of the old comparison
/// (\`target.starts_with(installed)\`): a 12-character request against a 40-character record was "not
/// installed", which would fail a request for the commit it installed.
#[test]
fn a_record_and_a_request_naming_the_same_commit_at_different_lengths_are_installed() {
    let fixture = Fixture::new("lengths");
    let id = "1795475320000000000-4242-00000000000000000003";
    fixture.done(id, json!({"verb": "deploy", "id": id, "queued_at": 1795475320u64,
        "target_commit": &MAIN[..12], "reason": REASON}));
    fixture.installed(MAIN);
    assert_eq!(installer_outcome::verdict(id), Some(Outcome::Installed),
        "a short request and a full record name the same commit");
    fixture.installed(&MAIN[..12]);
    assert_eq!(installer_outcome::verdict(id), Some(Outcome::Installed),
        "and a short record against a full request does too");
}

/// 9. A RECORD THAT NAMES THE ADVISORY TARGET IS NOT A SUCCESS WHEN ANOTHER COMMIT WAS DEMANDED. Read through
/// the store (`verdict(id)`), which is where the two commits are told apart: the record names the target that
/// was recorded at request time, and the request demanded a different commit - so nothing was installed for
/// it. Without this the recorded target could MASK a wrong install: the record would match the advisory
/// commit and the verdict would say "installed" for a commit the request never asked for.
#[test]
fn a_record_naming_the_advisory_is_not_the_demanded_install() {
    let fixture = Fixture::new("advisory-masks");
    let id = "1795475320000000000-4242-00000000000000000002";
    fixture.done(id, json!({"verb": "deploy", "id": id, "queued_at": 1795475320u64,
        "expected_sha": MAIN, "target_commit": STALE, "reason": REASON}));
    fixture.installed(STALE);
    fixture.log(&refused());
    match installer_outcome::verdict(id) {
        Some(Outcome::Uninstalled(why)) => {
            assert!(why.contains("refused(component_proof_failed)"), "the installer's own words: {why}");
            assert!(!why.contains("installed: "), "not a success: {why}");
        }
        other => panic!("a record naming the advisory target is not the demanded install: {other:?}"),
    }
}

/// 6. `fail_unobserved` ends the request where the operator and the landing both read it: `failed/` with the
/// reason, one queue record, and ONE re-queue - and it does that once, not on every tick.
#[test]
fn a_spawned_installer_that_ended_without_a_verdict_fails_and_requeues_once() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|error| error.into_inner());
    let home = std::env::temp_dir().join(format!("wa-installer-outcome-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(home.join("sentinel/done")).unwrap();
    let previous = std::env::var_os("WASM_AGENT_HOME");
    std::env::set_var("WASM_AGENT_HOME", &home);

    let id = "1795474711497868497-2091036-00000000000000000000";
    let request = json!({"verb": "deploy", "id": id, "queued_at": 1795474711u64, "target_commit": TARGET,
        "reason": REASON});
    wa_operation::atomic_json(&sentinel_dir().join("done").join(format!("{id}.json")),
        &json!({"at": 1795475320u64, "ok": true, "phase": "spawned", "detail": "deploy started detached",
            "request": request})).unwrap();

    let why = "deploy: refused(component_proof_failed): the candidate binary did not answer a graph call; nothing installed";
    assert!(installer_outcome::fail_unobserved(id, why).unwrap(), "the first pass fails the request");
    let failed: Value = serde_json::from_slice(&std::fs::read(
        sentinel_dir().join("failed").join(format!("{id}.json"))).unwrap()).unwrap();
    assert_eq!(failed["phase"], json!("unobserved"), "the record says which phase ended it: {failed}");
    let detail = failed["detail"].as_str().unwrap_or("");
    assert!(detail.contains("nothing was installed"), "{detail}");
    assert!(detail.contains("re-queued automatically once"), "the promise, as everywhere else: {detail}");
    assert!(sentinel_dir().join("requeue").join(format!("{id}.json")).exists(),
        "and the request is parked for the next quiet moment");
    assert!(!installer_outcome::fail_unobserved(id, why).unwrap(),
        "a second pass does nothing: the record is the fact, and it is written once");

    match previous {
        Some(value) => std::env::set_var("WASM_AGENT_HOME", value),
        None => std::env::remove_var("WASM_AGENT_HOME"),
    }
    let _ = std::fs::remove_dir_all(&home);
}
