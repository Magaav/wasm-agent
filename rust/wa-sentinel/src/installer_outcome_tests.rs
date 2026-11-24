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
