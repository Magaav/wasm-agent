//! Who owns the watcher's lifecycle, and where a deploy may therefore run: the rule, and how to falsify it.
//!
//! The defect these tests exist for: *the decision was keyed on the wrong process*. `owner()` read the
//! control group of **whoever ran the verb**, so `wa-sentinel stop` typed at an operator's shell read
//! `Ourselves`, wrote the stop file, and `Restart=always` restarted the watcher five seconds later - while
//! `docs/SENTINEL.md` advertised that command as the kill switch. The same answer made a shell's `restart`
//! spawn a *second* watcher beside the unit's own, and made a deploy that could not identify its supervisor
//! fall back to being a child of the watcher it was about to restart, which killed it mid-swap.
//!
//! What is proved, and how each claim is falsified (each falsification was run by hand, with its FAIL line in
//! the commit message - a test that cannot fail proves nothing):
//!
//!   1. **[`a_shell_outside_the_unit_still_reaches_the_manager`]** a caller outside the unit, with a
//!      unit-owned watcher: `stop` and `restart` reach the manager and no watcher is spawned. Falsified by
//!      letting this process's own control group decide (`owner_of` reads `identity.caller` first): the test
//!      fails on `Direct`, which is the answer that made the kill switch a five-second restart.
//!   2. **[`a_deploy_is_never_placed_inside_the_group_it_must_restart`]** an unrecognised unit is never the
//!      self-killing fallback: the deploy is refused, and so is a lifecycle verb. Falsified by mapping
//!      `Unrecognised` to `Detached`/`Direct`: the test fails with `Detached`, the shape that kills the
//!      deploy mid-swap.
//!   3. **[`the_unit_is_matched_by_what_it_is_and_not_by_its_name`]** the unit is matched by what it is:
//!      `wa-supervisor.service` is not adopted for sounding supervisory, and a sentinel installed as
//!      `watch-the-node.service` is not missed. Falsified by requiring `unit.contains("sentinel")` before
//!      adopting a unit - the rule that was there: the renamed unit drops to `Unrecognised`, which is where
//!      the deploy fallback started.
//!   4. **[`the_recorded_identity_decides_after_the_watcher_died`]** the watcher's own record decides in the
//!      window `RestartSec=5` leaves, when there is no live pid to read. Falsified by dropping the recorded
//!      fact: the test fails on `Ourselves` for a unit-owned watcher.
//!   5. **[`a_deploy_under_a_supervisor_is_refused_rather_than_become_our_child`]** run for real on this
//!      host: with a supervisor stated, and no `systemd-run` to start a unit of its own, the deploy is
//!      refused with a reason in the capture and the script never runs. Falsified by restoring the
//!      fall-through to the detached child, which is what the capture used to say.
//!   6. **[`the_watcher_pid_is_believed_by_name_and_verb_not_by_path`]** the watcher's pid is believed
//!      while it is still a *watching sentinel*, by the kernel's name for the program and its verb - never
//!      by a path. Falsified by making the name test unconditional (the recycled-pid case fails) and by
//!      dropping the verb test (another `wa-sentinel` verb reusing the number fails).
//!
//! NOT VERIFIED HERE, and it cannot be: no `systemctl` or `systemd-run` invocation can be executed on this
//! host (Windows has no unit manager at all). The commands are asserted as data - `systemctl stop <unit>`
//! and no `watch` anywhere in what a deploy is started with. What *was* checked on a real Linux node
//! (`openclaw.ohana`, read-only, systemd 255, sentinel unit-owned at `/system.slice/wa-sentinel.service`)
//! is recorded in the commit message; item 6 is what that check changed - the node installs the same build
//! at two paths, so a path comparison refused the truth there.

use super::*;

/// A test's own state directory and the environment it needs, both restored when the test ends.
///
/// `WASM_AGENT_HOME` is how the sentinel finds its state - the pid file, the record, the capture - so
/// pointing it at a fixture is what makes these tests read the files *they* wrote.
struct Fixture {
    dir: PathBuf,
    restore: Vec<(&'static str, Option<std::ffi::OsString>)>,
}

impl Fixture {
    fn new(label: &str) -> Fixture {
        let dir = std::env::temp_dir().join(format!("wa-role-{}-{label}", std::process::id()));
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

/// A session scope: what an operator's shell is in, and what the decision used to be made from.
const SHELL: &str = "0::/user.slice/user-1000.slice/session-3.scope";

fn stated(text: &str) -> role::Identity {
    role::Identity { declared: Some(text.to_string()), watcher: None, recorded: None, caller: None }
}

fn watching(cgroup: &str) -> role::Identity {
    role::Identity { declared: None, watcher: Some(cgroup.to_string()), recorded: None, caller: None }
}

/// 1. The operator's shell and the unit's watcher: "who owns the running watcher's lifecycle" is answered
/// from the watcher, so the documented kill switch asks the manager and `restart` cannot start a competitor.
#[test]
fn a_shell_outside_the_unit_still_reaches_the_manager() {
    use role::{Lifecycle, Owner, Step};
    let owner = role::owner_of(&role::Identity {
        declared: None,
        watcher: Some("0::/system.slice/wa-sentinel.service".to_string()),
        recorded: None,
        caller: Some(SHELL.to_string()),
    });
    assert_eq!(
        owner,
        Owner::Systemd { unit: "wa-sentinel.service".into(), user: false },
        "the running watcher's own control group is the fact, and the shell's is not"
    );
    assert_eq!(
        role::step(&owner, Lifecycle::Stop),
        Step::Manager {
            command: vec!["systemctl".to_string(), "stop".to_string(), "wa-sentinel.service".to_string()],
            unit: "wa-sentinel.service".into(),
            user: false,
        },
        "the kill switch must ask the manager: under `Restart=always` a stop file is a restart five seconds \
         later, not a stop"
    );
    match role::step(&owner, Lifecycle::Restart) {
        Step::Manager { command, .. } => {
            assert_eq!(
                command,
                vec!["systemctl".to_string(), "restart".to_string(), "wa-sentinel.service".to_string()]
            );
            assert!(
                !command.iter().any(|argument| argument == "watch"),
                "a restart from a shell must not spawn a competitor watcher: {command:?}"
            );
        }
        other => panic!("a restart from a shell must go to the manager, never start a second watcher: {other:?}"),
    }
    // And a shell is not a supervisor on its own: with no watcher to ask about, nothing outside owns the role.
    assert_eq!(
        role::owner_of(&role::Identity { declared: None, watcher: None, recorded: None, caller: Some(SHELL.to_string()) }),
        Owner::Ourselves,
        "the caller's session scope must never be read as a supervisor"
    );
    // A user unit needs the user manager, and a supervisor stated for one is read the same way.
    assert_eq!(role::step(&Owner::Systemd { unit: "wa-sentinel.service".into(), user: true }, Lifecycle::Stop),
        Step::Manager {
            command: vec![
                "systemctl".to_string(),
                "--user".to_string(),
                "stop".to_string(),
                "wa-sentinel.service".to_string(),
            ],
            unit: "wa-sentinel.service".into(),
            user: true,
        });
}

/// A `start` against a unit is a *restart* of the installed image: a start on a running unit is a no-op, and
/// the image that keeps running after a binary has been replaced is the old one.
#[test]
fn a_start_against_a_unit_restarts_the_installed_image() {
    let owner = role::Owner::Systemd { unit: "wa-sentinel.service".into(), user: false };
    assert_eq!(role::step(&owner, role::Lifecycle::Start), role::step(&owner, role::Lifecycle::Restart));
    match role::step(&owner, role::Lifecycle::Start) {
        role::Step::Manager { command, .. } => {
            assert_eq!(command[1], "restart", "a `start` on a running unit leaves the old image running: {command:?}")
        }
        other => panic!("a start under a unit must go to the manager: {other:?}"),
    }
}

/// 3. The unit is matched by what it is, never by a substring of its name.
#[test]
fn the_unit_is_matched_by_what_it_is_and_not_by_its_name() {
    use role::Owner;
    // A unit that merely sounds supervisory is not adopted. It is inside *this process*, and being inside a
    // unit is not by itself evidence about the watcher - which is exactly why it may only be reported.
    assert_eq!(
        role::owner_of(&role::Identity {
            declared: None,
            watcher: None,
            recorded: None,
            caller: Some("0::/system.slice/wa-supervisor.service".to_string()),
        }),
        Owner::Unrecognised { unit: "wa-supervisor.service".into() },
        "a unit whose name sounds supervisory is reported, never adopted"
    );
    // The same unit *is* the supervisor when it is the unit the sentinel process is in: the name is not
    // consulted in either direction.
    assert_eq!(
        role::owner_of(&watching("0::/system.slice/wa-supervisor.service")),
        Owner::Systemd { unit: "wa-supervisor.service".into(), user: false }
    );
    // A sentinel installed under a name with no `sentinel` in it must not be missed. This is the case the old
    // `unit.contains("sentinel")` test dropped into `Unrecognised`, and from there into the deploy fallback.
    assert_eq!(
        role::owner_of(&watching("0::/system.slice/watch-the-node.service")),
        Owner::Systemd { unit: "watch-the-node.service".into(), user: false }
    );
    // cgroup v1 and v2 spellings of the same fact, and a user unit.
    assert_eq!(
        role::owner_of(&watching("1:name=systemd:/system.slice/watch-the-node.service\n")),
        Owner::Systemd { unit: "watch-the-node.service".into(), user: false }
    );
    assert_eq!(
        role::owner_of(&watching(
            "0::/user.slice/user-1000.slice/user@1000.service/app.slice/watch-the-node.service"
        )),
        Owner::Systemd { unit: "watch-the-node.service".into(), user: true },
        "a user unit needs the user manager"
    );
    // A watcher started by hand - alive, and in nobody's unit - owns its own lifecycle, and so is a machine
    // with no `/proc` at all (Windows).
    assert_eq!(role::owner_of(&watching(SHELL)), Owner::Ourselves);
    assert_eq!(role::owner_of(&watching("")), Owner::Ourselves);
}

/// 4. The window `RestartSec=5` leaves: the unit's watcher is dead and systemd has not started it again, so
/// a `stop` has nothing to read out of `/proc` and only the watcher's own record to go on.
#[test]
fn the_recorded_identity_decides_after_the_watcher_died() {
    use role::{Lifecycle, Owner, Step};
    let owner = role::owner_of(&role::Identity {
        declared: None,
        watcher: None,
        recorded: Some("watch-the-node.service\n".to_string()),
        caller: Some(SHELL.to_string()),
    });
    assert_eq!(owner, Owner::Systemd { unit: "watch-the-node.service".into(), user: false });
    assert!(
        matches!(role::step(&owner, Lifecycle::Stop), Step::Manager { .. }),
        "a stop in that window must still reach the manager"
    );
    // A live watcher that is in no unit beats a stale record: the record is a fallback, not a claim.
    assert_eq!(
        role::owner_of(&role::Identity {
            declared: None,
            watcher: Some(SHELL.to_string()),
            recorded: Some("wa-sentinel.service".to_string()),
            caller: None,
        }),
        Owner::Ourselves
    );
    // A record that says nobody owns it, and the round trip through the words a watcher writes down: what
    // `describe` writes, `owner_of` must read back as the same owner.
    assert_eq!(
        role::owner_of(&role::Identity { declared: None, watcher: None, recorded: Some("none".to_string()), caller: None }),
        Owner::Ourselves
    );
    assert_eq!(role::describe(&Owner::Ourselves).as_deref(), Some("none"));
    assert_eq!(
        role::describe(&Owner::Systemd { unit: "watch-the-node.service".into(), user: true }).as_deref(),
        Some("user:watch-the-node.service")
    );
    assert_eq!(
        role::describe(&Owner::Unrecognised { unit: "wa-supervisor.service".into() }),
        None,
        "a unit that cannot be claimed must not be recorded as if it owned the watcher"
    );
    for owner in [
        Owner::Ourselves,
        Owner::WindowsService { name: "wasm-agent-sentinel".into() },
        Owner::Systemd { unit: "wa-sentinel.service".into(), user: false },
        Owner::Systemd { unit: "wa-sentinel.service".into(), user: true },
    ] {
        let text = role::describe(&owner).expect("an owner that can be written down");
        assert_eq!(
            role::owner_of(&stated(&text)),
            owner,
            "the words a watcher records must decide the same owner when they are read back: {text}"
        );
    }
}

#[test]
fn windows_service_identity_routes_only_to_scm_and_never_console_fallback() {
    use role::{Lifecycle, Owner, Placement, Step};
    let owner=role::owner_of(&stated("windows:renamed-sentinel"));
    assert_eq!(owner,Owner::WindowsService {name:"renamed-sentinel".into()});
    for (lifecycle,verb) in [(Lifecycle::Start,"start"),(Lifecycle::Stop,"stop"),(Lifecycle::Restart,"restart")] {
        assert_eq!(role::step(&owner,lifecycle),Step::WindowsService {name:"renamed-sentinel".into(),verb:verb.into()});
    }
    assert_eq!(role::placement(&owner),Placement::Detached);
    assert_eq!(role::describe(&owner).as_deref(),Some("windows:renamed-sentinel"));
    for value in ["windows:","windows:bad name","windows:../other"] {
        assert!(matches!(role::owner_of(&stated(value)),Owner::Unrecognised {..}));
    }
}

/// A stated fact beats inference in both directions, and an empty value is not a statement.
#[test]
fn a_stated_supervisor_beats_inference_in_both_directions() {
    use role::Owner;
    let in_unit = Some("0::/system.slice/wa-sentinel.service".to_string());
    // The operator's word: a watcher started by hand on a machine that runs systemd is inside no unit.
    assert_eq!(
        role::owner_of(&role::Identity {
            declared: Some("none".to_string()),
            watcher: in_unit.clone(),
            recorded: None,
            caller: None,
        }),
        Owner::Ourselves
    );
    // A launcher's or a deploy's hand-off, in the syntax the unit and the record both use.
    assert_eq!(
        role::owner_of(&stated("watch-the-node")),
        Owner::Systemd { unit: "watch-the-node.service".into(), user: false }
    );
    assert_eq!(
        role::owner_of(&stated("user:watch-the-node")),
        Owner::Systemd { unit: "watch-the-node.service".into(), user: true }
    );
    // An empty value is what a wrapper that exports an unset variable leaves behind, so it is not a statement:
    // the watcher's own control group still decides. (It used to be read as "nobody owns it".)
    assert_eq!(
        role::owner_of(&role::Identity {
            declared: Some(String::new()),
            watcher: in_unit.clone(),
            recorded: None,
            caller: None,
        }),
        Owner::Systemd { unit: "wa-sentinel.service".into(), user: false }
    );
    assert_eq!(
        role::owner_of(&role::Identity { declared: Some("   ".to_string()), watcher: None, recorded: None, caller: None }),
        Owner::Ourselves,
        "nothing stated and nothing known is still nobody"
    );
}

/// 2. No deploy may end up inside the control group it must restart - and the fallback that did that is
/// `Detached` for an owner that names a unit.
#[test]
fn a_deploy_is_never_placed_inside_the_group_it_must_restart() {
    use role::{Owner, Placement};
    // Under a supervisor the deploy is its own transient unit, started by the manager from outside the group
    // the restart will signal, and told which unit to restart.
    assert_eq!(
        role::placement(&Owner::Systemd { unit: "watch-the-node.service".into(), user: false }),
        Placement::OwnUnit { unit: "watch-the-node.service".into(), user: false }
    );
    assert_eq!(
        role::placement(&Owner::Systemd { unit: "watch-the-node.service".into(), user: true }),
        Placement::OwnUnit { unit: "watch-the-node.service".into(), user: true }
    );
    // Inside a unit this cannot claim: refuse, naming it. `Detached` here is the shape that kills the deploy
    // mid-swap, because the restart it performs signals the whole group it is running in.
    assert_eq!(
        role::placement(&Owner::Unrecognised { unit: "wa-supervisor.service".into() }),
        Placement::Refuse { unit: "wa-supervisor.service".into() }
    );
    // Nobody outside owns the watcher - a `nohup`, or any Windows machine: a detached child is safe there.
    assert_eq!(role::placement(&Owner::Ourselves), Placement::Detached);
    // The property, stated once for every owner that names a unit.
    for owner in [
        Owner::Systemd { unit: "wa-sentinel.service".into(), user: false },
        Owner::Systemd { unit: "wa-sentinel.service".into(), user: true },
        Owner::Systemd { unit: "watch-the-node.service".into(), user: false },
        Owner::Unrecognised { unit: "wa-supervisor.service".into() },
    ] {
        assert!(
            !matches!(role::placement(&owner), Placement::Detached),
            "a deploy must never be a child of the watcher a unit owns: {owner:?}"
        );
    }
}

/// 5. The same property end to end, on this host: with a supervisor stated and no `systemd-run` to start a
/// unit of its own, the deploy is refused - with the reason in the capture - and the script never runs as a
/// child of the watcher. This is the branch that used to fall through and be killed mid-swap.
#[test]
fn a_deploy_under_a_supervisor_is_refused_rather_than_become_our_child() {
    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new("deploy-supervisor");
    let marker = fixture.dir.join("ran.txt");
    let stub = fixture.dir.join("deploy-stub.sh");
    std::fs::write(&stub, format!("#!/bin/sh\nprintf 'ran\\n' > '{}'\n", marker.display()))
        .expect("stub deploy");
    std::env::set_var("WA_SENTINEL_SUPERVISOR", "watch-the-node.service");
    let capture = deploy_capture_path();
    let outcome = verb_deploy_script(&stub, "", "", "role fixture", &capture);
    std::env::remove_var("WA_SENTINEL_SUPERVISOR");

    let error = outcome
        .expect_err("a deploy under a supervisor must not be started as a child of the watcher")
        .to_string();
    assert!(error.contains("watch-the-node.service"), "the refusal must name the unit: {error}");
    assert!(
        error.contains("mid-swap") && error.contains("nothing was started"),
        "the refusal must say what would have gone wrong and that nothing ran: {error}"
    );
    let capture_text = std::fs::read_to_string(&capture).unwrap_or_default();
    assert!(
        capture_text.contains("--- refused:"),
        "the reason an operator reads belongs in the capture: {capture_text}"
    );
    assert!(
        !capture_text.contains("as a child of this watcher"),
        "the self-killing fallback must be gone: {capture_text}"
    );
    assert!(!marker.exists(), "the script must not have run at all");
}

/// 6. The watcher's pid is believed only while it is still a watching sentinel: the program's *name* and
/// verb, never its path. The node is why the path is wrong - it installs the same build at
/// `/usr/local/bin/wa-sentinel` (what the unit starts) and `~/.local/bin/wa-sentinel` (what `$PATH` puts
/// first, and what `deploy.sh` replaces) - and the recycled-pid case is why the name and verb are needed.
#[test]
fn the_watcher_pid_is_believed_by_name_and_verb_not_by_path() {
    let argv = |command: &str| command.as_bytes().to_vec();
    // Two copies of one build: the watcher started as `/usr/local/bin/wa-sentinel watch`, and the CLI
    // answering from the copy `$PATH` names first.
    assert!(is_watching("wa-sentinel", &argv("/usr/local/bin/wa-sentinel\0watch\0"), "wa-sentinel"));
    assert!(is_watching(
        "wa-sentinel",
        &argv("/home/ubuntu/.local/bin/wa-sentinel\0watch\0"),
        "wa-sentinel"
    ));
    // A named instance's watcher, whose argv carries the instance first.
    assert!(is_watching(
        "wa-sentinel",
        &argv("/opt/wa-sentinel\0--instance\0guest\0watch\0"),
        "wa-sentinel"
    ));
    // A recycled number in somebody else's service, and a recycled number taken by another sentinel verb.
    assert!(!is_watching("systemd", &argv("/usr/lib/systemd/systemd\0--system\0"), "wa-sentinel"));
    // The case that isolates the *name* half: another program that happens to be watching something (a
    // `cargo watch` in a checkout is the ordinary way that happens on this node) is not this watcher, however
    // sentinel-like its argument list looks.
    assert!(!is_watching(
        "cargo",
        &argv("/home/ubuntu/.cargo/bin/cargo\0watch\0-x\0test\0"),
        "wa-sentinel"
    ));
    assert!(!is_watching(
        "wa-sentinel",
        &argv("/usr/local/bin/wa-sentinel\0restart\0"),
        "wa-sentinel"
    ));
    assert!(!is_watching("wa-sentinel", &argv("/usr/local/bin/wa-sentinel\0once\0"), "wa-sentinel"));
    // No `/proc` at all (Windows): the empty reads are not a watcher.
    assert!(!is_watching("", &[], "wa-sentinel"));
    // The kernel truncates `comm` to 15 characters, so a binary with a longer name is compared against the
    // same 15: the comm of `wa-sentinel-node-extra` is `wa-sentinel-nod`.
    assert!(is_watching(
        "wa-sentinel-nod",
        &argv("whatever\0watch\0"),
        "wa-sentinel-node-extra"
    ));
}

/// The watcher's own record, written where a later `stop` reads it - and read back as the same owner. On a
/// host with no unit manager that is the honest `none`, and on the node it is the unit.
#[test]
fn the_watcher_records_its_own_owner_where_a_later_stop_reads_it() {
    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let fixture = Fixture::new("record");
    record_owner();
    let recorded = std::fs::read_to_string(fixture.state().join("supervisor"))
        .expect("the record is written where `identity()` reads it");
    assert_eq!(
        recorded.trim(),
        role::describe(&owner()).expect("the owner this host has"),
        "what is written down must be what this watcher believes"
    );
    assert_eq!(
        role::owner_of(&role::Identity {
            declared: None,
            watcher: None,
            recorded: Some(recorded),
            caller: None,
        }),
        owner(),
        "a later stop, with the watcher gone, must reach the same answer"
    );
}

/// What a deploy is started with, when it does get its own unit: the manager starts it, outside the caller's
/// slice, non-blocking, with the capture and the environment it needs - and with no `watch` in sight.
#[test]
fn a_deploys_unit_leaves_the_control_group_and_is_told_what_to_restart() {
    let capture = std::env::temp_dir().join("wa-deploy.out");
    let args = vec!["--reason".to_string(), "fixture".to_string()];
    let command = role::deploy_unit_command("wa-deploy-1-2", &capture, "sh", &args, false, "watch-the-node.service");
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
        "the deploy needs the watcher's PATH: a unit that had no cargo on PATH is one of the failures this \
         exists for: {command:?}"
    );
    assert!(
        command.contains(&"--setenv=WA_SENTINEL_SUPERVISOR=watch-the-node.service".to_string()),
        "the deploy runs in a unit of its own, so which unit it must restart has to be handed down - \
         otherwise it cannot tell, and would spawn a competitor: {command:?}"
    );
    assert!(!command.contains(&"watch".to_string()), "no competitor watcher: {command:?}");
    let tail = command.iter().position(|item| item == "--").expect("the command is separated from its args");
    assert_eq!(&command[tail + 1..], &["sh", "--reason", "fixture"], "{command:?}");
    // The deploy's own transient unit is not named for the watcher - and under the rule in `role` it never has
    // to be recognised by name either, because a deploy's own cgroup is not consulted.
    assert!(
        !role::deploy_unit_name(1790712000, 4242).contains("sentinel"),
        "the deploy's unit must not look like the watcher's"
    );
}
