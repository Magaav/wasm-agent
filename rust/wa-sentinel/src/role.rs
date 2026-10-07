//! Who owns the watcher's role - the supervisor a deploy must not fight, and the one a kill switch must ask.
//!
//! The defect this module exists for. `deploy.sh` swaps the sentinel binary and then asks for a watcher
//! (`wa-sentinel restart`, or `wa-sentinel start` when none was watching). Where nothing outside owns the
//! role - a logon task on Windows, a `nohup` on Linux - a new detached watcher is the only thing that can
//! hold it, and that is what this code did. Where systemd owns the process, it was wrong, and it was
//! observed: the deploy started a *second* watcher beside the unit's own, the unit's watcher could not
//! take the runner lock (`jobs::lock`), exited, and `Restart=always` started it again - the unit flapped
//! (`activating`, `MainPID 0`, `NRestarts 20`) while two watchers fought over one drop-box. Stopping was
//! no better: the watcher exits on the stop file, and `Restart=always` starts it again, so under a unit
//! the stop file is a flap generator rather than a stop.
//!
//! The rule, from here on: a unit is started, stopped and restarted by its *manager*, and a deploy that
//! finds itself under one asks the manager. The process that replaces a supervisor is not the process
//! that should own its lifecycle.
//!
//! **Whose identity decides it.** The question is "who owns the running watcher's lifecycle", and it was
//! being answered from the wrong process: [`owner_of`] read *the caller's* control group, so
//! `wa-sentinel stop` typed at an operator's shell sat in a session scope, read [`Owner::Ourselves`],
//! wrote the stop file, and `Restart=always` restarted the watcher five seconds later - while
//! `docs/SENTINEL.md` advertised that command as the kill switch. The same answer made a shell's
//! `restart` spawn a second watcher beside the unit's own. So the facts come from the watcher instead:
//!
//!   1. a **stated** fact (`WA_SENTINEL_SUPERVISOR`, in the unit's environment, from a launcher, or handed
//!      down by a deploy) - an operator's word beats inference, in both directions (`none` = nobody);
//!   2. the **running watcher's** own control group, read from `/proc/<pid>/cgroup` for the pid in the
//!      sentinel's own pid file, and used only when that pid provably still runs this binary - so a shell
//!      outside the unit reads the unit, and a recycled pid cannot point the decision at somebody else's
//!      service;
//!   3. what the watcher **recorded** about itself when it took the role (`<config>/sentinel/supervisor`,
//!      written by the watcher, see `record_owner`) - the same fact, for the window in which a unit's
//!      watcher is dead and `Restart=always` has not started it again yet, and for an unprivileged shell
//!      that cannot read a root-owned `/proc/<pid>/exe`;
//!   4. **this process's** own control group - used only to *name* a unit in a refusal, never to adopt one.
//!
//! The unit's **name is never matched against anything**. `wa-supervisor.service` is not this watcher's
//! supervisor unless it is the unit that owns the sentinel process, and the sentinel's own unit is found
//! under whatever name it was installed as: the old `unit.contains("sentinel")` test failed in both
//! directions at once - it adopted any unit whose name happened to contain that word, and it missed a
//! renamed sentinel unit, reporting [`Owner::Unrecognised`] and letting a deploy fall back into the
//! control group it was about to restart. The `.service` suffix is structure (a unit is not a scope), not
//! a name test.
//!
//! A watcher inside somebody else's unit is reported ([`Owner::Unrecognised`]) rather than adopted,
//! because restarting the wrong unit is worse than admitting we do not know - and [`step`] then refuses
//! instead of spawning a competitor inside a control group this did not choose.

use anyhow::{bail, Context, Result};
use std::path::Path;

/// Who owns the running watcher's lifecycle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Owner {
    /// Nothing outside this process owns it: a detached watcher is the right thing to start, and the stop
    /// file is a real stop because nothing will start the watcher again.
    Ourselves,
    /// A systemd unit owns the running watcher. `user` selects the user manager.
    Systemd { unit: String, user: bool },
    /// Windows SCM owns this exact named service; no console fallback.
    WindowsService { name: String },
    /// We are inside a unit, but one this cannot show owns the watcher: report it, change nothing.
    Unrecognised { unit: String },
}

/// The facts the decision is made from, gathered by the caller (`super::identity`) so the rule itself is a
/// pure function that can be tested without systemd and without a live Linux node.
///
/// Every field is about *the watcher*, except the last, which exists only so an unidentified unit can be
/// named to the operator. Deciding from the caller's own control group is the defect described in the
/// module header.
pub(crate) struct Identity {
    /// `WA_SENTINEL_SUPERVISOR`: a stated fact, from the unit, the launcher, or a deploy's hand-off.
    pub(crate) declared: Option<String>,
    /// The control group of the running watcher (`/proc/<pid>/cgroup`).
    pub(crate) watcher: Option<String>,
    /// What the watcher wrote down about itself when it took the role. It survives the watcher's death,
    /// which is the window `Restart=always` keeps a unit's role in.
    pub(crate) recorded: Option<String>,
    /// This process's own control group. Never used to adopt a unit - only to name one in a refusal.
    pub(crate) caller: Option<String>,
}

/// The owner of the running watcher's lifecycle.
pub(crate) fn owner_of(identity: &Identity) -> Owner {
    // A stated fact, first. The unit's own environment, a launcher, or a deploy that was told which unit
    // to restart: all of them know something this process cannot see.
    if let Some(owner) = identity.declared.as_deref().and_then(stated_owner) {
        return owner;
    }
    // The watcher's own control group: the identity of the process whose lifecycle is in question. A
    // watcher that is alive and in no unit is an answer too, and it beats a stale record.
    if let Some(cgroup) = identity.watcher.as_deref() {
        return match unit_in(cgroup) {
            Some((unit, user)) => Owner::Systemd { unit, user },
            None => Owner::Ourselves,
        };
    }
    // The watcher is gone, or its cgroup could not be read: its own recorded word is the next-best fact,
    // and it is the one that survives the five seconds `RestartSec=5` takes to bring a unit back.
    if let Some(owner) = identity.recorded.as_deref().and_then(stated_owner) {
        return owner;
    }
    // Nothing about the watcher is known. Our own control group may only *name* a unit for the operator:
    // adopting it would hand an unknown unit's lifecycle to a verb that was asked about a watcher.
    if let Some((unit, _)) = identity.caller.as_deref().and_then(unit_in) {
        return Owner::Unrecognised { unit };
    }
    Owner::Ourselves
}

/// `WA_SENTINEL_SUPERVISOR`'s syntax, and the recorded file's: `none`, `user:<unit>`, or a unit name.
///
/// An empty value is *not* a statement (it is what a wrapper that exports an unset variable leaves
/// behind), so it falls through to the next fact rather than silently claiming nobody owns the watcher.
fn stated_owner(text: &str) -> Option<Owner> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    if text.eq_ignore_ascii_case("none") || text.eq_ignore_ascii_case("self") {
        // An operator's word beats inference: a watcher started by hand on a machine that runs systemd is
        // inside no unit, and a `start` there must still get a detached watcher.
        return Some(Owner::Ourselves);
    }
    if let Some(name) = text.strip_prefix("windows:") {
        return Some(if !name.is_empty() && name.len() <= 80
            && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
            Owner::WindowsService {name:name.to_string()}
        } else {Owner::Unrecognised {unit:text.to_string()}});
    }
    let (name, user) = match text.strip_prefix("user:") {
        Some(rest) => (rest, true),
        None => (text, false),
    };
    Some(Owner::Systemd { unit: unit_name(name), user })
}

/// The unit named by a control-group text, if there is one: v2 `0::/system.slice/wa-sentinel.service`,
/// v1 `1:name=systemd:/system.slice/wa-sentinel.service`, and a user unit
/// `0::/user.slice/user-1000.slice/user@1000.service/app.slice/wa-sentinel.service`. A session scope
/// (`.../session-3.scope`) names no unit.
///
/// The unit is *found*, never matched: the name is not compared with anything, so a sentinel installed
/// under another name is not missed and a unit that merely sounds supervisory is not adopted.
fn unit_in(cgroup: &str) -> Option<(String, bool)> {
    for line in cgroup.lines() {
        let path = match line.split(':').nth(2) {
            Some(path) => path.trim(),
            None => continue,
        };
        let unit = match path.rsplit('/').find(|component| component.ends_with(".service")) {
            Some(unit) => unit,
            None => continue,
        };
        let user = path.contains("/user.slice/") || path.contains("user@");
        return Some((unit.to_string(), user));
    }
    None
}

fn unit_name(name: &str) -> String {
    if name.ends_with(".service") {
        name.to_string()
    } else {
        format!("{name}.service")
    }
}

/// The lifecycle verb a caller asked for.
///
/// `Start` and `Restart` differ in what they do when *nobody* outside owns the watcher (a start may find
/// one already watching); against a manager both are a `restart`, which is also what replaces the running
/// image - a `start` on an already-running unit is a no-op, and the image that keeps running after the
/// binary has been replaced is the *old* one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Lifecycle {
    Start,
    Stop,
    Restart,
}

/// What a lifecycle verb does about the owner: a decision, not an action, so the rule that was wrong is
/// testable without systemd. The exec half is [`run_command`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Step {
    /// The manager owns this watcher: run exactly this command and do nothing else. A stop file would be a
    /// flap generator under `Restart=always`, and a spawned watcher would be a competitor.
    Manager { command: Vec<String>, unit: String, user: bool },
    /// Nothing outside owns the watcher: the caller may stop it or replace it directly.
    Direct,
    WindowsService { name: String, verb: String },
    /// Inside a unit that cannot be shown to own the watcher: name it, change nothing, and never spawn a
    /// competitor inside a control group this process did not choose.
    Refuse { unit: String },
}

pub(crate) fn step(owner: &Owner, lifecycle: Lifecycle) -> Step {
    match owner {
        Owner::Systemd { unit, user } => Step::Manager {
            command: match lifecycle {
                Lifecycle::Stop => stop_command(unit, *user),
                Lifecycle::Start | Lifecycle::Restart => restart_command(unit, *user),
            },
            unit: unit.clone(),
            user: *user,
        },
        Owner::WindowsService { name } => Step::WindowsService {name:name.clone(),verb:match lifecycle {
            Lifecycle::Start => "start", Lifecycle::Stop => "stop", Lifecycle::Restart => "restart"
        }.to_string()},
        Owner::Unrecognised { unit } => Step::Refuse { unit: unit.clone() },
        Owner::Ourselves => Step::Direct,
    }
}

/// Where a deploy may be started, decided from who owns the watcher.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Placement {
    /// As a transient unit of its own, started by the manager and told which unit to restart. A deploy that
    /// is a child of the watcher it replaces is signalled with that watcher's whole control group, mid-swap,
    /// before it has recorded its own result.
    OwnUnit { unit: String, user: bool },
    /// Nothing outside owns the watcher: a detached child is safe - and on Windows it is the only shape.
    Detached,
    /// Inside a unit that cannot be shown to own the watcher: refuse, naming it. The fallback this replaces
    /// started the deploy *inside* that unit's control group, and its `restart` then restarted the unit it
    /// was running in: the swap killed the thing performing it.
    Refuse { unit: String },
}

pub(crate) fn placement(owner: &Owner) -> Placement {
    match owner {
        Owner::Systemd { unit, user } => Placement::OwnUnit { unit: unit.clone(), user: *user },
        Owner::Unrecognised { unit } => Placement::Refuse { unit: unit.clone() },
        Owner::WindowsService { .. } | Owner::Ourselves => Placement::Detached,
    }
}

/// The owner as text, in the syntax [`stated_owner`] reads, so the words a watcher writes down decide the
/// same thing when they are read back. `None` for a unit that cannot be claimed: a record saying `none`
/// there would be a claim that nothing owns a watcher which is demonstrably inside something.
pub(crate) fn describe(owner: &Owner) -> Option<String> {
    match owner {
        Owner::Systemd { unit, user } => Some(if *user { format!("user:{unit}") } else { unit.clone() }),
        Owner::WindowsService { name } => Some(format!("windows:{name}")),
        Owner::Ourselves => Some("none".to_string()),
        Owner::Unrecognised { .. } => None,
    }
}

/// `systemctl`, or `systemctl --user` for a user manager.
fn manager(user: bool) -> Vec<String> {
    let mut command = vec!["systemctl".to_string()];
    if user {
        command.push("--user".to_string());
    }
    command
}

/// Run a command whose failure is the operator's answer, and return its output.
pub(crate) fn run_command(command: &[String]) -> Result<String> {
    let output = std::process::Command::new(&command[0])
        .args(&command[1..])
        .output()
        .with_context(|| {
            format!(
                "run {}: this watcher is owned by a supervisor, so its lifecycle is the supervisor's",
                command.join(" ")
            )
        })?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let text = text.trim();
    if !output.status.success() {
        bail!(
            "{} failed ({}): {text}. If no supervisor owns this watcher any more, say so: \
             WA_SENTINEL_SUPERVISOR=none",
            command.join(" "),
            output.status
        );
    }
    Ok(text.to_string())
}

/// The command that brings the unit up on the installed image.
///
/// `restart`, never `start`: a start on an already-running unit is a no-op, and the image that keeps
/// running after a binary has been replaced is the *old* one - the same trap the Windows branch already
/// documents ("replacing an executable file does not replace the already-running process").
pub(crate) fn restart_command(unit: &str, user: bool) -> Vec<String> {
    let mut command = manager(user);
    command.push("restart".to_string());
    command.push(unit.to_string());
    command
}

/// The command that stops the unit. A manual stop is the one thing `Restart=always` honours: the unit
/// goes inactive and stays there, which is the difference between stopping a supervisor and flapping it.
pub(crate) fn stop_command(unit: &str, user: bool) -> Vec<String> {
    let mut command = manager(user);
    command.push("stop".to_string());
    command.push(unit.to_string());
    command
}

/// A name for one deploy's transient unit. Unique per attempt, because it is what an operator asks for
/// the exit status by (`systemctl status <name>`), and because two deploys must not be one unit.
///
/// The name deliberately does **not** contain `sentinel`: a deploy's own transient unit must never be
/// mistaken for the watcher's. Which unit a deploy should restart is not something it can infer from its
/// cgroup once it runs in a unit of its own - that fact is handed down in its environment instead
/// (`WA_SENTINEL_SUPERVISOR`, see [`deploy_unit_command`]) - and under the rule in the module header the
/// deploy never has to: its own cgroup is not consulted at all.
pub(crate) fn deploy_unit_name(at: u64, pid: u32) -> String {
    format!("wa-deploy-{at}-{pid}")
}

/// The `systemd-run` argument vector that starts the deploy script as a unit of its own.
///
/// This is the Linux spelling of Windows' `DETACHED_PROCESS`, and it is not a detail: a deploy that is a
/// child of the watcher it replaces is killed with that watcher's control group when it restarts the
/// unit at the end - before it has recorded its own result or woken the session that asked for it. A
/// transient unit is started by the *manager*, from outside that group, so it outlives the swap.
///
/// Three properties are load-bearing and are asserted in the tests rather than trusted:
///   * `--slice=<system|user>.slice` - a transient unit left in the caller's slice is in the caller's
///     control group, which is exactly what this is trying to leave;
///   * `--no-block` - `deploy` returns when the script has been started, never when it finishes;
///   * the deploy's own environment, passed explicitly, because a transient unit gets the *manager's*
///     environment and not ours (a watcher whose PATH had no `~/.cargo/bin` is already one of the two
///     failures that cost an afternoon).
///
/// The unit is deliberately not collected (`--collect` would remove it): once the script is gone,
/// `systemctl status <name>` is where its exit status still lives. That is the answer to "did it run, or
/// did it die immediately", and a few inert units are a small price for it (`systemctl reset-failed`
/// clears them).
///
/// `--user` + `--slice=user.slice`, checked against a real user manager (the node, systemd 255, from the
/// session that owns the user manager): `systemctl --user show user.slice -p LoadState` says `loaded` - an
/// implicit slice under the user manager's `-.slice`, with `FragmentPath=` empty and `ActiveState=inactive`
/// - while `app.slice` is the one already `active`, next to `session.slice`. So the name resolves, and a unit
/// placed in it is outside the caller's unit cgroup, which is the property this flag exists for; `app.slice`
/// would be the conventional spelling and the difference is naming. Either way the failure that matters is
/// not silent: a `systemd-run` that refuses is reported, never worked around by starting the deploy inside
/// the watcher's control group (see [`placement`]).
pub(crate) fn deploy_unit_command(
    name: &str,
    capture: &Path,
    interpreter: &str,
    args: &[String],
    user: bool,
    supervisor: &str,
) -> Vec<String> {
    let mut command = vec!["systemd-run".to_string()];
    if user {
        command.push("--user".to_string());
    }
    command.push(format!("--unit={name}"));
    command.push(format!("--slice={}", if user { "user.slice" } else { "system.slice" }));
    command.push("--no-block".to_string());
    // The capture, from the other side of the manager: the same file the deploy's words are read from.
    command.push(format!("--property=StandardOutput=append:{}", capture.display()));
    command.push(format!("--property=StandardError=append:{}", capture.display()));
    if let Ok(cwd) = std::env::current_dir() {
        command.push(format!("--working-directory={}", cwd.display()));
    }
    command.extend(deploy_environment());
    // Which unit the deploy must ask to restart, handed down because the deploy can no longer work it out:
    // it runs in a unit of its own now, so its cgroup names *that* rather than the watcher's. Without this
    // the deploy would fall back to spawning a competitor watcher - the flapping unit this change exists
    // to stop, arrived at from a new direction.
    command.push(format!("--setenv=WA_SENTINEL_SUPERVISOR={supervisor}"));
    command.push("--".to_string());
    command.push(interpreter.to_string());
    command.extend(args.iter().cloned());
    command
}

/// The environment the deploy needs, as `--setenv=` arguments.
fn deploy_environment() -> Vec<String> {
    let mut passed: Vec<String> = Vec::new();
    for (key, value) in std::env::vars() {
        let keep = matches!(key.as_str(), "PATH" | "HOME" | "USER" | "LOGNAME" | "TMPDIR")
            || key.starts_with("WA_")
            || key.starts_with("WASM_AGENT_");
        // A newline in a value cannot be represented on this command line, and a value nobody can pass
        // is better reported by its absence than mangled into the next argument.
        if keep && !value.contains('\n') && !value.contains('\r') {
            passed.push(format!("--setenv={key}={value}"));
        }
    }
    passed
}

/// Start the deploy script as a transient unit of its own and return the unit's name.
///
/// The caller names the unit so that the capture's header can be written *before* the deploy says anything:
/// a capture whose first line is the deploy's output and whose attribution follows is a file nobody can
/// read in order.
pub(crate) fn start_deploy_unit(
    name: &str,
    capture: &Path,
    interpreter: &str,
    args: &[String],
    user: bool,
    supervisor: &str,
) -> Result<String> {
    let command = deploy_unit_command(name, capture, interpreter, args, user, supervisor);
    // Non-blocking by design, so this only proves the manager accepted the unit; the capture file is the
    // evidence of what the script then did, and `systemctl status <name>` of how it ended.
    run_command(&command).with_context(|| format!("start {name} with systemd-run"))?;
    Ok(name.to_string())
}
