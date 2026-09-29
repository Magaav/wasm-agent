//! The two claims a deploy's visibility rests on, and how to falsify each.
//!
//! The concern, in the words it was reported in: *a requested deploy that dies immediately is
//! indistinguishable from one that ran, because the sentinel throws its output away - and a deferred deploy
//! says nothing at all.* Measured on the node: `verb_deploy`'s POSIX branch spawned the script with
//! `stdin/stdout/stderr` all `Stdio::null()` (the Windows branch inherits nothing either but the script's
//! own `deploy.log` is left behind, so only Linux was silent), three deploys became zombies within seconds
//! and left no output anywhere, and the idle gate `continue`d with no log line at all.
//!
//! What is proved here, without a live node:
//!
//!   1. a stub deploy that fails loudly leaves its message - the *refusal reason*, not just a return code -
//!      in the capture file the operator is told to read, plus how it ended;
//!   2. a busy node and a node whose state cannot be proven each produce a deferral line naming the verb and
//!      the reason, and dispatch nothing: the request stays in the box, is not a failure, and is not
//!      announced again on the next tick.
//!
//! Falsification, both run by hand and reported with their FAIL line (a test that cannot fail proves
//! nothing):
//!
//!   * fix 1: put `Stdio::null()` back on the POSIX spawn in `start_deploy_detached` (or hand the child a
//!     null stderr) - `a_failing_deploy_leaves_its_message_in_the_capture` fails on the missing message and
//!     prints the capture it did read;
//!   * fix 2: delete the `audit("maintenance-deferred", ...)` line in `announce_hold` (or the whole
//!     `announce_hold` call) - `a_busy_or_undecidable_node_is_announced_and_nothing_is_dispatched` fails on
//!     the missing deferral line.

use super::*;
use std::io::{Read, Write};
use std::net::TcpListener;

/// A test's own state directory and the environment it needs, both restored when the test ends.
///
/// `WASM_AGENT_HOME` is how the sentinel finds its state - the request box, the log, the capture - so
/// pointing it at a fixture is what makes these tests read the files *they* wrote instead of the machine's
/// real ones.
struct Fixture {
    dir: PathBuf,
    restore: Vec<(&'static str, Option<std::ffi::OsString>)>,
}

impl Fixture {
    fn new(label: &str) -> Fixture {
        let dir = std::env::temp_dir().join(format!("wa-deploy-visibility-{}-{label}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("fixture directory");
        let mut fixture = Fixture { dir, restore: Vec::new() };
        fixture.set("WASM_AGENT_HOME", fixture.dir.display().to_string());
        fixture
    }

    fn set(&mut self, key: &'static str, value: String) {
        if !self.restore.iter().any(|(saved, _)| *saved == key) {
            self.restore.push((key, std::env::var_os(key)));
        }
        std::env::set_var(key, value);
    }

    /// The sentinel's state directory for this fixture.
    fn state(&self) -> PathBuf {
        sentinel_dir()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        for (key, previous) in self.restore.drain(..) {
            match previous {
                Some(value) => std::env::set_var(key, value),
                None => std::env::remove_var(key),
            }
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Read the capture until it satisfies `ready`, then return what it holds. The deploy is detached, so the
/// file fills in on the child's schedule and not on ours; the bound is generous because a slow machine is
/// not a failed fix.
fn wait_for(path: &Path, ready: impl Fn(&str) -> bool) -> String {
    let mut last = String::new();
    for _ in 0..500 {
        last = std::fs::read_to_string(path).unwrap_or_default();
        if ready(&last) {
            return last;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    last
}

/// A node that answers `/health` with a chosen body, on a port of its own.
///
/// The classification under test is the real one (`node_activity` over HTTP), not a stand-in: the hold is
/// decided from what the node actually says, which is the whole point of the gate.
fn health_stub(body: &'static str) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind a stub health port");
    let port = listener.local_addr().expect("the stub's port").port();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(2)));
            // Read the request first, so the client sees a complete exchange rather than an early close.
            let mut buffer = [0u8; 4096];
            let _ = stream.read(&mut buffer);
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
        }
    });
    port
}

/// Fix 1. A deploy that dies immediately must leave its own words where an operator can read them.
#[test]
fn a_failing_deploy_leaves_its_message_in_the_capture() {
    // Alone with this process's environment: `WASM_AGENT_HOME` is global, and another test pointing it
    // elsewhere would send this capture to the wrong directory.
    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new("capture");
    let stub = fixture.dir.join("failing-deploy.sh");
    std::fs::write(
        &stub,
        "#!/bin/sh\necho 'deploy: refusing: this tree is not on origin/main' >&2\necho 'deploy: building'\nexit 3\n",
    )
    .expect("stub deploy");

    let capture = deploy_capture_path();
    assert!(capture.ends_with("deploy.out"), "the capture is in the sentinel's state: {}", capture.display());
    assert!(capture.starts_with(fixture.state()), "the capture is in the sentinel's state: {}", capture.display());

    let detail = verb_deploy_script(&stub, "", "", "capture fixture", &capture).expect("the deploy is accepted");
    assert!(detail.contains("detached"), "the deploy is detached: {detail}");
    assert!(
        detail.contains(&capture.display().to_string()),
        "the answer must name the file the operator reads: {detail}"
    );

    let text = wait_for(&capture, |text| text.contains("this tree is not on origin/main"));
    assert!(
        text.contains("this tree is not on origin/main"),
        "the deploy's refusal reason must survive in {}:\n{text}",
        capture.display()
    );
    assert!(text.contains("deploy: building"), "the deploy's stdout must survive too:\n{text}");
    assert!(text.contains("failing-deploy.sh"), "the capture must name the script that spoke:\n{text}");
    assert!(text.contains("capture fixture"), "the capture must name the reason it was asked for:\n{text}");

    // "Died immediately" and "ran" must not look the same, so the ending is in the file as well.
    let ended = wait_for(&capture, |text| text.contains("exited with"));
    assert!(ended.contains("exited with"), "the capture must say how the deploy ended:\n{ended}");
    // `ExitStatus`'s own spelling, which differs by platform ("exit status: 3" / "exit code: 3") and must not
    // be normalised away: a `0` here would be the lie this file exists to prevent.
    assert!(
        ended.contains("exit status: 3") || ended.contains("exit code: 3"),
        "the ending must be the real status (3):\n{ended}"
    );
}

/// Fix 2. A held request is visible while it waits, and nothing is dispatched behind its back.
#[test]
fn a_busy_or_undecidable_node_is_announced_and_nothing_is_dispatched() {
    // A node mid-run: `current` is set, so the gate must hold a deploy.
    const BUSY: &str = r#"{"ok":true,"current":{"label":"POST /chat"},"queue":0,"operation_overdue":false,"workers":[{"id":0,"state":"busy"}]}"#;
    // A node that answers but omits a field the contract requires: ambiguous, which is not idle.
    const UNDECIDABLE: &str = r#"{"ok":true,"queue":0}"#;

    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    for (label, body, why) in [
        ("busy", BUSY, "the node is busy"),
        ("undecidable", UNDECIDABLE, "cannot prove it is idle"),
    ] {
        let mut fixture = Fixture::new(label);
        fixture.set("WASM_AGENT_PORT", health_stub(body).to_string());
        // A stub deploy that leaves a trace if it is ever dispatched: "must not dispatch" needs something
        // to look at, not an opinion.
        let marker = fixture.dir.join("dispatched.txt");
        let stub = fixture.dir.join("deploy-stub.sh");
        std::fs::write(&stub, format!("#!/bin/sh\nprintf 'ran\\n' > '{}'\n", marker.display()))
            .expect("stub deploy");
        fixture.set("WA_SENTINEL_DEPLOY", stub.display().to_string());

        let request = fixture.state().join("requests").join("100-deploy.json");
        std::fs::write(&request, br#"{"verb":"deploy","reason":"the operator asked for it"}"#).expect("request");

        let mut held = Held::default();
        assert_eq!(
            process_requests(false, &mut held).expect("the box is readable"),
            0,
            "a held request is not handled ({label})"
        );
        assert!(request.exists(), "the request must stay in the box to be retried ({label})");
        assert!(!marker.exists(), "nothing may be dispatched while the node is {label}");
        assert!(
            !fixture.state().join("done").join("100-deploy.json").exists(),
            "a hold is not a completion ({label})"
        );
        assert!(
            !fixture.state().join("failed").join("100-deploy.json").exists(),
            "a hold must never become a failure ({label})"
        );

        let log = std::fs::read_to_string(fixture.state().join("sentinel.log")).unwrap_or_default();
        assert!(log.contains("maintenance-deferred"), "a held request must leave a deferral line:\n{log}");
        assert!(log.contains("deploy 100-deploy.json"), "the line must name the verb and the request:\n{log}");
        assert!(log.contains(why), "the line must say why ({label}): expected {why:?} in\n{log}");
        assert!(
            log.contains("the operator asked for it"),
            "the line must carry the reason the request itself gives:\n{log}"
        );

        // Announced once, not once per 200ms tick: the second pass adds nothing.
        process_requests(false, &mut held).expect("the box is readable");
        let again = std::fs::read_to_string(fixture.state().join("sentinel.log")).unwrap_or_default();
        assert_eq!(
            again.matches("maintenance-deferred").count(),
            1,
            "a request held for the same reason is announced once, not once per tick:\n{again}"
        );
    }
}

/// Fix 3, the half that can be proved without a live Linux node: who owns the role, and what a deploy asks
/// for instead of spawning a competitor.
#[test]
fn a_supervisor_is_recognised_from_the_control_group_and_never_guessed_at() {
    use role::Owner;
    let sentinel = Owner::Systemd { unit: "wa-sentinel.service".into(), user: false };
    // cgroup v2 and v1 spellings of the same fact.
    assert_eq!(role::owner_of(None, "0::/system.slice/wa-sentinel.service"), sentinel);
    assert_eq!(role::owner_of(None, "1:name=systemd:/system.slice/wa-sentinel.service\n"), sentinel);
    // A user unit, which needs the user manager.
    assert_eq!(
        role::owner_of(None, "0::/user.slice/user-1000.slice/user@1000.service/app.slice/wa-sentinel.service"),
        Owner::Systemd { unit: "wa-sentinel.service".into(), user: true }
    );
    // A unit that is not named for this process is reported, not adopted: restarting the wrong unit is
    // worse than admitting we do not know.
    assert_eq!(
        role::owner_of(None, "0::/system.slice/wa-serve.service"),
        Owner::Unrecognised { unit: "wa-serve.service".into() }
    );
    // A watcher started by hand, and a machine with no `/proc` at all (Windows): nobody owns the role, so a
    // detached watcher is still the right thing to start.
    assert_eq!(role::owner_of(None, "0::/user.slice/user-1000.slice/session-3.scope"), Owner::Ourselves);
    assert_eq!(role::owner_of(None, ""), Owner::Ourselves);
    // An operator's word beats inference, both ways.
    assert_eq!(role::owner_of(Some("none"), "0::/system.slice/wa-sentinel.service"), Owner::Ourselves);
    assert_eq!(
        role::owner_of(Some("wasm-supervisor"), ""),
        Owner::Systemd { unit: "wasm-supervisor.service".into(), user: false }
    );
    assert_eq!(
        role::owner_of(Some("user:wa-sentinel"), ""),
        Owner::Systemd { unit: "wa-sentinel.service".into(), user: true }
    );
}

/// "Restart *that*, not a competitor", as a command that can be read: the unit's manager, the unit by name,
/// and no second `wa-sentinel watch` anywhere in it.
#[test]
fn the_unit_manager_is_asked_and_no_competitor_is_started() {
    assert_eq!(
        role::restart_command("wa-sentinel.service", false),
        vec!["systemctl".to_string(), "restart".to_string(), "wa-sentinel.service".to_string()]
    );
    assert_eq!(
        role::stop_command("wa-sentinel.service", true),
        vec!["systemctl".to_string(), "--user".to_string(), "stop".to_string(), "wa-sentinel.service".to_string()]
    );

    // The deploy itself, started by the manager so it is not a child of the watcher it replaces.
    let capture = std::env::temp_dir().join("wa-deploy.out");
    let args = vec!["--reason".to_string(), "fixture".to_string()];
    let command = role::deploy_unit_command("wa-deploy-1-2", &capture, "sh", &args, false);
    assert_eq!(command[0], "systemd-run", "a transient unit is started by the manager: {command:?}");
    assert!(command.contains(&"--unit=wa-deploy-1-2".to_string()), "{command:?}");
    assert!(
        command.contains(&"--slice=system.slice".to_string()),
        "a transient unit left in the caller's slice is in the caller's control group: {command:?}"
    );
    assert!(
        command.contains(&"--no-block".to_string()),
        "`deploy` returns when the script is started, never when it finishes: {command:?}"
    );
    assert!(
        command.iter().any(|item| item.starts_with("--property=StandardError=append:")),
        "the capture must be the same file on the manager's side too: {command:?}"
    );
    assert!(
        command.iter().any(|item| item.starts_with("--setenv=PATH=")),
        "the deploy needs the watcher's PATH - a unit that had no cargo on PATH is one of the failures this \
         file exists for: {command:?}"
    );
    assert!(!command.contains(&"watch".to_string()), "no competitor watcher: {command:?}");
    let tail = command.iter().position(|item| item == "--").expect("the command is separated from its args");
    assert_eq!(&command[tail + 1..], &["sh", "--reason", "fixture"], "{command:?}");
}
