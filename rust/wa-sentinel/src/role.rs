//! Who owns the watcher's role - the supervisor a deploy must not fight.
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
//! Detection is deliberately narrow, and it never guesses silently. Being *inside* a unit's control group
//! is the fact that matters - that unit's restart kills this process, and only its manager should own the
//! role - but the unit is accepted on its own evidence only when it is named for this process
//! (`*sentinel*`). A watcher inside somebody else's service is reported ([`Owner::Unrecognised`]) rather
//! than adopted, because restarting the wrong unit is worse than admitting we do not know.
//! `WA_SENTINEL_SUPERVISOR` states the fact when detection cannot see it: `none` for a watcher started by
//! hand on a machine that happens to run systemd, `user:<unit>` for a user unit, or the unit name.

use anyhow::{bail, Context, Result};
use std::path::Path;

/// Who owns the watcher's role.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Owner {
    /// Nothing outside this process owns it: a detached watcher is the right thing to start.
    Ourselves,
    /// A systemd unit owns the process. `user` selects the user manager.
    Systemd { unit: String, user: bool },
    /// We are inside a unit, but one this cannot honestly claim is ours: report it, change nothing.
    Unrecognised { unit: String },
}

/// What owns this process right now.
pub(crate) fn owner() -> Owner {
    let declared = std::env::var("WA_SENTINEL_SUPERVISOR").ok();
    // On Windows there is no `/proc` and no unit manager: the empty text means "nobody", which is the
    // truth there - the watcher is a logon task or a `Start-Process` child.
    let cgroup = std::fs::read_to_string("/proc/self/cgroup").unwrap_or_default();
    owner_of(declared.as_deref(), &cgroup)
}

/// The pure decision, so the shapes that decide a node's behaviour are testable without systemd and
/// without a Linux cgroup (see `deploy_visibility_tests`).
pub(crate) fn owner_of(declared: Option<&str>, cgroup: &str) -> Owner {
    if let Some(value) = declared {
        let value = value.trim();
        if value.is_empty() || value.eq_ignore_ascii_case("none") || value.eq_ignore_ascii_case("self") {
            // An operator's word beats inference: a watcher started by hand on a machine that runs
            // systemd is inside no unit, and a `start` there must still get a detached watcher.
            return Owner::Ourselves;
        }
        let (name, user) = match value.strip_prefix("user:") {
            Some(rest) => (rest, true),
            None => (value, false),
        };
        return Owner::Systemd { unit: unit_name(name), user };
    }
    for line in cgroup.lines() {
        // v2: `0::/system.slice/wa-sentinel.service`; v1: `1:name=systemd:/system.slice/wa-sentinel.service`.
        let path = match line.split(':').nth(2) {
            Some(path) => path.trim(),
            None => continue,
        };
        let unit = match path.rsplit('/').find(|component| component.ends_with(".service")) {
            Some(unit) => unit,
            None => continue,
        };
        let user = path.contains("/user.slice/") || path.contains("user@");
        if unit.contains("sentinel") {
            return Owner::Systemd { unit: unit.to_string(), user };
        }
        return Owner::Unrecognised { unit: unit.to_string() };
    }
    Owner::Ourselves
}

fn unit_name(name: &str) -> String {
    if name.ends_with(".service") {
        name.to_string()
    } else {
        format!("{name}.service")
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

fn run(command: &[String]) -> Result<String> {
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
        bail!("{} failed ({}): {text}", command.join(" "), output.status);
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

/// Ask the unit's manager to restart the unit, synchronously: when this returns, the unit is up.
pub(crate) fn restart_unit(unit: &str, user: bool) -> Result<String> {
    run(&restart_command(unit, user))?;
    Ok(format!("{unit} restarted by its manager (the manager owns this watcher)"))
}

/// Ask the unit's manager to stop the unit.
pub(crate) fn stop_unit(unit: &str, user: bool) -> Result<String> {
    run(&stop_command(unit, user))?;
    Ok(format!("{unit} stopped by its manager"))
}

/// A name for one deploy's transient unit. Unique per attempt, because it is what an operator asks for
/// the exit status by (`systemctl status <name>`), and because two deploys must not be one unit.
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
pub(crate) fn deploy_unit_command(
    name: &str,
    capture: &Path,
    interpreter: &str,
    args: &[String],
    user: bool,
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
) -> Result<String> {
    let command = deploy_unit_command(name, capture, interpreter, args, user);
    // Non-blocking by design, so this only proves the manager accepted the unit; the capture file is the
    // evidence of what the script then did, and `systemctl status <name>` of how it ended.
    run(&command).with_context(|| format!("start {name} with systemd-run"))?;
    Ok(name.to_string())
}
