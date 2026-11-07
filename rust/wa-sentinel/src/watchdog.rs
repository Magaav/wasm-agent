//! The sentinel addressing the watchdog instead of the node (docs/KERNEL.md, row 6; docs/SENTINEL.md,
//! "The watchdog, and what it takes over").
//!
//! Two supervisors cannot both own the node's pid. When `wa-watchdog` is the one that starts, restarts
//! and swaps the kernel, the sentinel must not kill or spawn a node behind its back: it would take a
//! kernel the watchdog immediately starts again (the measured flap in KERNEL.md), and a deploy would
//! "verify" a pid the watchdog had already replaced. So the three verbs that change what is running
//! (`start`, `stop`, `restart`, plus `recover`, which is an interrupting restart) are *delegated*:
//!
//! | verb | what the watchdog is asked | why not the node |
//! | --- | --- | --- |
//! | restart | `swap <current binary> --sha256 <its pin>` | the supervisor holds the pid, so it can stop the old kernel, start the new one on the same ports, prove it on `/health`, and put the old one back if it never answers - all without a second process guessing |
//! | recover | the same swap | an interrupting restart with a health gate is exactly a swap of the same bytes, and the rollback is free because the "new" binary is the one already on disk |
//! | start (autostart) | `run` detached | the supervisor starts the kernel; the sentinel only starts the supervisor |
//! | stop | `stop` | the stop file is the supervisor's to read: killing the kernel pid from here is the two-owners bug again |
//!
//! What the sentinel keeps is everything below the decision: the verbs, the request queue and its
//! evidence, the idle gate, the install record, the Windows service/task identity. It loses only the
//! kill-and-start.
//!
//! **The switch.** `WA_WATCHDOG=1` - the same flag `scripts/upgrade.sh` reads - turns delegation on.
//! With it on and no watchdog to talk to, every delegated verb **refuses** (it never falls back to the
//! sentinel's own kill-and-start: with `WA_WATCHDOG=1` the operator has said one program owns the pid,
//! and a silent fallback would put two back). With it off, nothing here is consulted and the sentinel
//! behaves exactly as it did before, which is why the flag defaults off.

use anyhow::{bail, Context, Result};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// How long a delegated swap waits for the supervisor's verdict. The watchdog's own health window plus
/// the rollback's start, with slack; `WA_WATCHDOG_WAIT_MS` overrides it (the same knob `upgrade.sh`
/// passes through).
pub(crate) fn wait_ms() -> u64 {
    std::env::var("WA_WATCHDOG_WAIT_MS")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(60_000)
}

/// `WA_WATCHDOG=1` (anything but empty/`0`/`false`) is the switch. A pure function so the tests do not
/// have to mutate the process environment to check the refusal that half-set configurations produce.
pub(crate) fn enabled_in(value: Option<&str>) -> bool {
    match value.map(str::trim) {
        None => false,
        Some(text) => !(text.is_empty() || text == "0" || text.eq_ignore_ascii_case("false") || text.eq_ignore_ascii_case("off")),
    }
}

pub(crate) fn enabled() -> bool {
    enabled_in(std::env::var("WA_WATCHDOG").ok().as_deref())
}

/// The watchdog's state directory: `WA_WATCHDOG_HOME`, else `<config>/watchdog` - the same default the
/// watchdog itself resolves from the node home (`wa-watchdog --home`'s documented default).
pub(crate) fn home_dir() -> PathBuf {
    if let Ok(value) = std::env::var("WA_WATCHDOG_HOME") {
        if !value.trim().is_empty() {
            return PathBuf::from(value.trim());
        }
    }
    crate::config_dir().join("watchdog")
}

/// The watchdog program: `WA_WATCHDOG_BIN`, else beside the installed `wa` (a deploy installs the two
/// together), else the same names on `PATH`. `None` is a refusal the caller must report, not a guess.
pub(crate) fn binary_at(installed: &Path) -> Option<PathBuf> {
    if let Ok(value) = std::env::var("WA_WATCHDOG_BIN") {
        let text = value.trim();
        if !text.is_empty() {
            let path = PathBuf::from(text);
            return path.is_file().then_some(path);
        }
    }
    let name = if cfg!(windows) { "wa-watchdog.exe" } else { "wa-watchdog" };
    let sibling = installed.parent().map(|dir| dir.join(name));
    if let Some(path) = sibling.as_ref() {
        if path.is_file() {
            return Some(path.clone());
        }
    }
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths).map(|dir| dir.join(name)).find(|candidate| candidate.is_file())
    })
}

/// What the supervisor last wrote down, as far as this needs it: the state it is in and the kernel it
/// holds. A missing or half-written `status.json` is `None` - never a guessed state.
pub(crate) fn status_of(dir: &Path) -> Option<Value> {
    let text = std::fs::read_to_string(dir.join("status.json")).ok()?;
    serde_json::from_str::<Value>(&text).ok()
}

/// Whether a supervisor holds this node, and what it says about itself.
///
/// The test is the pid it wrote and the state it wrote, not a port and not an image name: a
/// `supervisor.pid` whose process is gone is a dead supervisor (the node it started may even still be
/// running, and adopting it is the sentinel's job, not a reason to call it owned).
pub(crate) fn ownership(dir: &Path, alive: impl Fn(u32) -> bool) -> Ownership {
    let recorded = std::fs::read_to_string(dir.join("supervisor.pid"))
        .ok()
        .and_then(|text| text.trim().parse::<u32>().ok());
    let status = status_of(dir);
    let state = status
        .as_ref()
        .and_then(|value| value.get("state"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let kernel_pid = status
        .as_ref()
        .and_then(|value| value.get("kernel_pid"))
        .and_then(Value::as_u64)
        .map(|pid| pid as u32)
        .filter(|pid| *pid > 0);
    let live = recorded.filter(|pid| alive(*pid));
    Ownership { dir: dir.to_path_buf(), supervisor: live, state, kernel_pid }
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Ownership {
    pub dir: PathBuf,
    /// The supervisor's pid, when the process it recorded is still alive.
    pub supervisor: Option<u32>,
    /// `status.json`'s `state` (`stopped`, `starting`, `healthy`, `backoff`, `swapping`).
    pub state: Option<String>,
    pub kernel_pid: Option<u32>,
}

impl Ownership {
    /// The supervisor is alive and is not on its way out: it is the thing to ask.
    pub fn owns(&self) -> bool {
        self.supervisor.is_some() && self.state.as_deref() != Some("stopped")
    }

    /// One line for the audit record and the verb's answer. No path of the node's data, no message text.
    pub fn describe(&self) -> String {
        match (self.supervisor, self.state.as_deref()) {
            (Some(pid), Some(state)) => format!("pid {pid} ({state})"),
            (Some(pid), None) => format!("pid {pid} (no state recorded)"),
            (None, Some(state)) => format!("no live supervisor (last state {state})"),
            (None, None) => "no supervisor".to_string(),
        }
    }
}

/// The verbs whose effect changes what the node is running. The decision table below is a function of
/// one of these, the switch, and what the supervisor says - never of an environment read at the call site.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Verb {
    Start,
    Stop,
    /// `restart` and `recover` are the same delegation: a health-gated replacement of the running kernel
    /// with the installed bytes (`recover` is the interrupting form of it).
    Restart,
}

/// The decision a verb makes about delegation. Pure, so every branch is reachable in a test without a
/// watchdog, a node or a process table.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Plan {
    /// `WA_WATCHDOG` is off: the sentinel owns the pid and behaves as it always did.
    NotDelegated,
    /// A supervisor is alive and holds the pid: ask it (`swap`, `stop`).
    Delegate { dir: PathBuf },
    /// The switch says a watchdog owns this node and none is running. For a start or a restart that is a
    /// fact about *what to do* rather than an error: start the supervisor and let it start (the recorded)
    /// kernel, health-gated. That is also how a machine comes back after a delegated `stop`.
    StartSupervisor { dir: PathBuf },
    /// `WA_WATCHDOG` says the watchdog owns the pid, the watchdog is gone, and the verb cannot be carried
    /// out without taking the pid back. Refused, never silently done by the sentinel.
    Refuse { detail: String },
}

/// Whether this verb should be delegated, given the switch and what the supervisor says.
pub(crate) fn plan(verb: Verb, enabled: bool, ownership: &Ownership) -> Plan {
    if !enabled {
        return Plan::NotDelegated;
    }
    if ownership.owns() {
        return Plan::Delegate { dir: ownership.dir.clone() };
    }
    match verb {
        Verb::Start | Verb::Restart => Plan::StartSupervisor { dir: ownership.dir.clone() },
        Verb::Stop => Plan::Refuse {
            detail: format!(
                "WA_WATCHDOG is set but no watchdog supervises this node ({} in {}); nothing owns the pid to stop it through - start it with `wa-watchdog run`, or unset WA_WATCHDOG and stop the node directly",
                ownership.describe(),
                ownership.dir.display()
            ),
        },
    }
}

/// The command line one delegated request becomes. `action` is `swap`, `stop` or `run`; `args` is the
/// kernel's argument line for a swap (`{port}` and friends are resolved by the watchdog at launch, so
/// they are passed exactly as recorded).
pub(crate) fn command(binary: &Path, dir: &Path, action: &str, kernel: Option<(&Path, &str, &[String])>, wait_ms: u64) -> Vec<String> {
    let mut args = vec![action.to_string(), "--home".to_string(), dir.display().to_string()];
    if let Some((kernel_path, pin, kernel_args)) = kernel {
        args.push(kernel_path.display().to_string());
        args.push("--sha256".to_string());
        args.push(pin.to_string());
        for argument in kernel_args {
            args.push("--arg".to_string());
            args.push(argument.clone());
        }
        args.push("--wait-ms".to_string());
        args.push(wait_ms.to_string());
    }
    let _ = binary;
    args
}

/// The verdict of a delegated swap, as the verb reports it.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Swapped {
    pub ok: bool,
    pub rolled_back: bool,
    pub active: String,
    pub detail: String,
}

/// The supervisor's own record of the last swap (`status.json`'s `last_swap`). `None` when it has not
/// swapped anything yet, or the file is half-written: a missing record is "nothing to say", never a
/// guessed verdict.
pub(crate) fn last_swap(dir: &Path) -> Option<Swapped> {
    let value = status_of(dir)?;
    let swap = value.get("last_swap")?;
    if swap.is_null() {
        return None;
    }
    Some(Swapped {
        ok: swap.get("ok").and_then(Value::as_bool).unwrap_or(false),
        rolled_back: swap.get("rolled_back").and_then(Value::as_bool).unwrap_or(false),
        active: swap.get("active").and_then(Value::as_str).unwrap_or("").to_string(),
        detail: swap.get("detail").and_then(Value::as_str).unwrap_or("").to_string(),
    })
}

/// What one delegated request answered: the exit code the watchdog's CLI documents (`0` settled, `1`
/// refused or rolled back, `3` queued - the request is on disk and will be answered on a later pass),
/// and the last line it wrote, which is the reason when there is one.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Invoked {
    pub code: i32,
    pub said: String,
}

/// Run one delegated request. Never shell: the watchdog is a program with flags, and every argument here
/// was built by `command`.
fn invoke(binary: &Path, args: &[String]) -> Result<Invoked> {
    let output = std::process::Command::new(binary)
        .args(args)
        .stdin(std::process::Stdio::null())
        .output()
        .with_context(|| format!("run {} {}", binary.display(), args.join(" ")))?;
    let last_line = |text: &str| -> String {
        text.lines().rev().map(str::trim).find(|line| !line.is_empty()).unwrap_or("").chars().take(300).collect()
    };
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let said = match (last_line(&stderr), last_line(&stdout)) {
        (err, _) if !err.is_empty() => err,
        (_, out) => out,
    };
    Ok(Invoked { code: output.status.code().unwrap_or(-1), said })
}

/// A delegated **restart**: the same bytes, swapped through the supervisor's handoff, health-gated, with
/// the previous binary kept for a rollback. Returns the sentence the verb reports, or the reason it did
/// not settle - a rollback is a failure of the restart, said as one.
pub(crate) fn restart(binary: &Path, dir: &Path, wait: u64) -> Result<String> {
    // The pin is the bytes' own digest: this crate hashes the file it is about to ask for, so a restart
    // cannot switch to bytes nobody verified (the same rule `upgrade.sh`'s pin applies to a download).
    let pin = sha256_file(binary)?;
    let command = find(binary)?;
    // The kernel's argument line is the supervisor's recorded one (`--arg` absent keeps it), so a node
    // started with `--ui`/`--client-port` keeps them across a restart.
    let no_args: &[String] = &[];
    let argv = command_line(&command, dir, "swap", Some((binary, pin.as_str(), no_args)), wait);
    let answer = invoke(&command, &argv)?;
    match answer.code {
        0 => {
            let verdict = last_swap(dir);
            Ok(match verdict {
                Some(verdict) if !verdict.detail.is_empty() => {
                    format!("the node is back (watchdog swap: {})", verdict.detail)
                }
                _ => "the node is back (watchdog swap settled)".to_string(),
            })
        }
        3 => Ok(format!(
            "the watchdog queued the restart ({}); it applies on its next pass",
            if answer.said.is_empty() { "no reason given".to_string() } else { answer.said }
        )),
        _ => {
            // Refused or rolled back. The supervisor's own words are the reason; a rollback means the node
            // is still serving the previous kernel, which is the fact the caller must not report as success.
            let verdict = last_swap(dir);
            let still = verdict
                .as_ref()
                .filter(|verdict| verdict.rolled_back)
                .map(|verdict| format!(" (still serving {})", verdict.active))
                .unwrap_or_default();
            bail!("the watchdog did not settle the restart{still}: {}", if answer.said.is_empty() { "no reason given" } else { answer.said.as_str() })
        }
    }
}

/// The sha256 of a file, lowercase hex - the pin a swap is verified against. The sentinel already carries
/// `ring` (it hashes installs), so this is the same digest `wa-watchdog verify` computes.
pub(crate) fn sha256_file(path: &Path) -> Result<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).with_context(|| format!("open {} to hash it", path.display()))?;
    let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).with_context(|| format!("read {} to hash it", path.display()))?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(digest.finish().as_ref().iter().map(|byte| format!("{byte:02x}")).collect())
}

/// Resolve the program, or refuse with the reason (a `WA_WATCHDOG_BIN` that names nothing is a
/// misconfiguration, not something to work around).
fn find(installed: &Path) -> Result<PathBuf> {
    binary_at(installed).ok_or_else(|| {
        anyhow::anyhow!(
            "wa-watchdog was not found (WA_WATCHDOG_BIN, beside {}, or PATH) while WA_WATCHDOG is set",
            installed.display()
        )
    })
}

fn command_line(binary: &Path, dir: &Path, action: &str, kernel: Option<(&Path, &str, &[String])>, wait_ms: u64) -> Vec<String> {
    command(binary, dir, action, kernel, wait_ms)
}

/// A delegated **stop**: the supervisor stops its kernel and exits. The verb waits for the kernel pid it
/// recorded to be gone, so a later `start` cannot race the process it is replacing (`stop_node_verified`
/// waits for the same fact, for the same reason).
pub(crate) fn stop(dir: &Path, alive: impl Fn(u32) -> bool) -> Result<String> {
    let ownership = ownership(dir, &alive);
    let installed = crate::installed_binary();
    let command = find(&installed)?;
    let answer = invoke(&command, &command_line(&command, dir, "stop", None, 0))?;
    if answer.code != 0 {
        bail!("the watchdog refused the stop: {}", answer.said);
    }
    if let Some(pid) = ownership.kernel_pid {
        for _ in 0..80 {
            if !alive(pid) {
                return Ok(format!("the watchdog stopped its kernel (pid {pid})"));
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        bail!("the watchdog was asked to stop but its kernel (pid {pid}) is still alive");
    }
    Ok("the watchdog was asked to stop; it held no kernel".to_string())
}

/// A delegated **start**: the supervisor is started (the kernel is its), and the verb waits for `/health`
/// so "start" keeps meaning "the node answers", not "a process was spawned".
pub(crate) fn start_supervisor(dir: &Path, health: impl Fn() -> bool, wait: Duration) -> Result<String> {
    let installed = crate::installed_binary();
    let command = find(&installed)?;
    let argv = command_line(&command, dir, "run", None, 0);
    let pid = spawn_detached(&command, &argv)?;
    let deadline = Instant::now() + wait;
    while Instant::now() < deadline {
        if health() {
            return Ok(format!("the watchdog (pid {pid}) started the node and it answers /health"));
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    bail!("the watchdog (pid {pid}) did not bring the node up within {}s", wait.as_secs())
}

#[cfg(windows)]
fn spawn_detached(binary: &Path, args: &[String]) -> Result<u32> {
    crate::winproc::start_detached_with_env(binary, args, None)
}

#[cfg(not(windows))]
fn spawn_detached(binary: &Path, args: &[String]) -> Result<u32> {
    let child = std::process::Command::new(binary)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .with_context(|| format!("start {} {}", binary.display(), args.join(" ")))?;
    Ok(child.id())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(tag: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("wa-sentinel-watchdog-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("temp dir");
        path
    }

    fn recorded(tag: &str, supervisor: Option<u32>, state: Option<&str>, kernel: Option<u32>) -> Ownership {
        Ownership {
            dir: dir(tag),
            supervisor,
            state: state.map(str::to_string),
            kernel_pid: kernel,
        }
    }

    #[test]
    fn the_switch_is_one_environment_value_and_its_absence_is_off() {
        assert!(enabled_in(Some("1")));
        assert!(enabled_in(Some("true")));
        assert!(enabled_in(Some(" yes ")));
        for off in [None, Some(""), Some("0"), Some("false"), Some("OFF")] {
            assert!(!enabled_in(off), "{off:?} must mean the sentinel keeps the pid");
        }
    }

    #[test]
    fn with_the_flag_off_the_sentinel_owns_the_pid_whatever_the_watchdog_says() {
        let owned = recorded("off-owned", Some(41), Some("healthy"), Some(42));
        for verb in [Verb::Start, Verb::Stop, Verb::Restart] {
            assert_eq!(plan(verb, false, &owned), Plan::NotDelegated);
            assert_eq!(plan(verb, false, &recorded("off-none", None, None, None)), Plan::NotDelegated);
        }
    }

    #[test]
    fn with_the_flag_on_and_a_live_supervisor_every_verb_is_delegated() {
        let owned = recorded("on-owned", Some(41), Some("healthy"), Some(42));
        for verb in [Verb::Start, Verb::Stop, Verb::Restart] {
            assert_eq!(plan(verb, true, &owned), Plan::Delegate { dir: owned.dir.clone() });
        }
        // A supervisor that is mid-swap or in backoff still owns the pid: it is asked, not bypassed.
        assert!(matches!(plan(Verb::Restart, true, &recorded("on-swapping", Some(41), Some("swapping"), None)), Plan::Delegate { .. }));
        assert!(matches!(plan(Verb::Restart, true, &recorded("on-backoff", Some(41), Some("backoff"), None)), Plan::Delegate { .. }));
    }

    #[test]
    fn with_the_flag_on_and_no_supervisor_a_start_starts_it_and_a_stop_refuses() {
        // A start (or a restart, which is the same effect) is carried out *by* starting the supervisor: the
        // recorded kernel comes up health-gated, and this is also how a machine returns after a delegated stop.
        let gone = recorded("on-gone", None, Some("healthy"), Some(42));
        assert_eq!(plan(Verb::Start, true, &gone), Plan::StartSupervisor { dir: gone.dir.clone() });
        assert_eq!(plan(Verb::Restart, true, &gone), Plan::StartSupervisor { dir: gone.dir.clone() });
        // A stop cannot be carried out without taking the pid back, so it is refused with the remedy in it.
        match plan(Verb::Stop, true, &gone) {
            Plan::Refuse { detail } => {
                assert!(detail.contains("no watchdog supervises this node"), "{detail}");
                assert!(detail.contains("wa-watchdog run"), "the refusal names the remedy: {detail}");
                assert!(!detail.contains("memory.db"), "a refusal never names the node's data");
            }
            other => panic!("expected a refusal, got {other:?}"),
        }
        // A supervisor pid that is recorded but dead is not ownership, and neither is a stopped one.
        assert!(matches!(plan(Verb::Stop, true, &recorded("on-dead", None, None, None)), Plan::Refuse { .. }));
        assert!(matches!(plan(Verb::Stop, true, &recorded("on-stopped", Some(41), Some("stopped"), None)), Plan::Refuse { .. }));
    }

    #[test]
    fn ownership_is_read_from_the_files_the_supervisor_wrote() {
        let home = dir("ownership");
        assert!(!ownership(&home, |_| true).owns(), "nothing written: not owned");
        std::fs::write(home.join("supervisor.pid"), "4242\n").unwrap();
        std::fs::write(home.join("status.json"), r#"{"state":"healthy","kernel_pid":4243}"#).unwrap();
        let live = ownership(&home, |pid| pid == 4242);
        assert!(live.owns());
        assert_eq!(live.kernel_pid, Some(4243));
        assert_eq!(live.describe(), "pid 4242 (healthy)");
        // The pid is checked against the process table; a recorded pid that is gone owns nothing.
        assert!(!ownership(&home, |_| false).owns());
        // A half-written status file is no state at all, not a guessed one.
        std::fs::write(home.join("status.json"), "{\"state\":").unwrap();
        assert_eq!(ownership(&home, |_| true).state, None);
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn a_swap_command_carries_the_pin_the_arguments_as_written_and_the_home() {
        let args = vec!["serve".to_string(), "--port".to_string(), "{port}".to_string()];
        let argv = command(
            Path::new("/opt/wa/wa-watchdog"),
            Path::new("/home/op/.wasm-agent/watchdog"),
            "swap",
            Some((Path::new("/opt/wa/bin/wa"), &"ab".repeat(32), &args)),
            30_000,
        );
        assert_eq!(argv[0], "swap");
        assert!(argv.windows(2).any(|pair| pair == ["--home", "/home/op/.wasm-agent/watchdog"]));
        assert!(argv.windows(2).any(|pair| pair == ["--sha256", &"ab".repeat(32)]));
        // `{port}` survives: the supervisor resolves it at launch, which is what lets one recorded line
        // start the service instance and the proof instance.
        assert!(argv.windows(2).any(|pair| pair == ["--arg", "{port}"]), "{argv:?}");
        assert!(argv.windows(2).any(|pair| pair == ["--wait-ms", "30000"]));
        // A stop/run carries no kernel at all: the supervisor knows what it is running.
        let stop = command(Path::new("wd"), Path::new("/h"), "stop", None, 0);
        assert_eq!(stop, vec!["stop", "--home", "/h"]);
    }

    #[test]
    fn the_supervisors_record_of_the_last_swap_is_read_and_a_missing_one_is_not_a_verdict() {
        let home = dir("last-swap");
        assert_eq!(last_swap(&home), None, "nothing has been swapped yet");
        std::fs::write(home.join("status.json"), r#"{"state":"healthy","last_swap":null}"#).unwrap();
        assert_eq!(last_swap(&home), None);
        std::fs::write(
            home.join("status.json"),
            r#"{"state":"healthy","last_swap":{"id":"swap-1","ok":false,"rolled_back":true,"previous":"/old/wa","active":"/old/wa","detail":"the new kernel exited","at_ms":9}}"#,
        )
        .unwrap();
        let seen = last_swap(&home).expect("a verdict");
        assert!(!seen.ok && seen.rolled_back);
        assert_eq!(seen.active, "/old/wa");
        assert_eq!(seen.detail, "the new kernel exited");
        // A half-written file is no verdict at all: the verb then reports the CLI's own words rather than a
        // record it guessed at.
        std::fs::write(home.join("status.json"), "{\"state\":").unwrap();
        assert_eq!(last_swap(&home), None);
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn the_pin_a_restart_asks_for_is_the_digest_of_the_bytes_it_names() {
        let home = dir("pin");
        let binary = home.join("wa");
        std::fs::write(&binary, b"kernel bytes").unwrap();
        let pin = sha256_file(&binary).expect("hash");
        assert_eq!(pin.len(), 64);
        assert!(pin.chars().all(|ch| ch.is_ascii_hexdigit() && !ch.is_ascii_uppercase()));
        // A different file is a different pin: the refusal that matters is the one on the bytes.
        let other = home.join("wa2");
        std::fs::write(&other, b"other bytes").unwrap();
        assert_ne!(sha256_file(&other).unwrap(), pin);
        assert!(sha256_file(&home.join("absent")).is_err());
        let _ = std::fs::remove_dir_all(home);
    }
}
