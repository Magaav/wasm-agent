//! wa-sentinel — the process outside the node.
//!
//! Every failure that mattered had one shape: **the only process that could act was the one that
//! needed acting on.** A node cannot restart itself, because the turn doing the restarting runs on the
//! node it is stopping — the stop is the last command it ever executes. A dead node cannot say why it
//! died. And a node cannot be trusted to judge whether it should be woken: that spends money.
//!
//! So this is a small process that lives outside, watches, and acts on *declared* requests:
//!
//!   * it is the only thing that starts, stops or upgrades a node
//!   * it never holds a conversation, a model or the ledger — it executes a fixed verb list
//!   * every action is logged with its reason, and nothing happens silently
//!   * waking a model is budgeted, because that is the only thing here that costs money
//!
//! The interface is a **drop-box**: `<config>/sentinel/requests/*.json`. A file survives the death of
//! whoever wrote it, so an agent can ask for a restart and then die with the node — which is exactly
//! what happens — and the request still lands. No socket, no protocol, and it works when the node is
//! down, which is when you need it most.
//!
//! Verbs (a fixed list, never a shell — the thing that can restart your agent must not be something
//! your agent can talk into anything):
//!
//!   request restart  [--reason TEXT]
//!   request upgrade  --binary PATH [--reason TEXT]
//!   request wake     --session ID --prompt TEXT [--reason TEXT]
//!   request run      --script PATH [--reason TEXT]     (a script the operator installed)
//!   once | watch | status | start | stop | help
//!
//! `request` writes the file and returns; `watch` performs it. That split is the whole point: the
//! writer may die immediately afterwards.

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------- paths

fn home() -> PathBuf {
    if let Ok(value) = std::env::var("WASM_AGENT_HOME") {
        if !value.is_empty() {
            return PathBuf::from(value);
        }
    }
    if cfg!(windows) {
        if let Ok(value) = std::env::var("USERPROFILE") {
            if !value.is_empty() {
                return PathBuf::from(value);
            }
        }
    }
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
}

fn config_dir() -> PathBuf {
    let dir = home().join(".wasm-agent");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn sentinel_dir() -> PathBuf {
    let dir = config_dir().join("sentinel");
    for sub in ["requests", "done", "failed"] {
        let _ = std::fs::create_dir_all(dir.join(sub));
    }
    dir
}

fn log_path() -> PathBuf {
    sentinel_dir().join("sentinel.log")
}

fn pid_path() -> PathBuf {
    sentinel_dir().join("sentinel.pid")
}

fn stop_path() -> PathBuf {
    sentinel_dir().join("stop")
}

/// The node's port: what the operator set, else the default the installer uses.
fn node_port() -> u16 {
    std::env::var("WASM_AGENT_PORT").ok().and_then(|v| v.parse().ok()).unwrap_or(8799)
}

fn client_port() -> u16 {
    std::env::var("WASM_AGENT_CLIENT_PORT").ok().and_then(|v| v.parse().ok()).unwrap_or(8800)
}

/// Where the installed binary lives. Not derived from the config directory: the install and the state
/// are in different places, and guessing wrong made `restart` report "nothing installed at
/// C:\Users\Victor\wasm-agent\wa.exe" - a path that never existed.
fn installed_binary() -> PathBuf {
    if let Ok(value) = std::env::var("WA_INSTALL_DIR") {
        if !value.is_empty() {
            return PathBuf::from(value).join(if cfg!(windows) { "wa.exe" } else { "wa" });
        }
    }
    if cfg!(windows) {
        let base = std::env::var("LOCALAPPDATA").unwrap_or_else(|_| ".".into());
        return PathBuf::from(base).join("wasm-agent").join("wa.exe");
    }
    home().join(".local").join("bin").join("wa")
}

fn ui_dir() -> PathBuf {
    if let Ok(value) = std::env::var("WA_UI_DIR") {
        if !value.is_empty() {
            return PathBuf::from(value);
        }
    }
    installed_binary().parent().map(|p| p.join("ui")).unwrap_or_else(|| PathBuf::from("ui"))
}

// ---------------------------------------------------------------- logging

fn now_epoch() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Append one line per action, with its reason. Nothing here happens silently: an action whose reason
/// is not written down is an action nobody can review.
fn audit(verb: &str, detail: &str, reason: &str) {
    use std::io::Write;
    let line = format!("{}\t{}\t{}\t{}\n", now_epoch(), verb, detail.replace('\n', " "), reason.replace('\n', " "));
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(log_path()) {
        let _ = file.write_all(line.as_bytes());
    }
}

fn say(message: &str) {
    println!("  {message}");
}

// ---------------------------------------------------------------- the node

fn health_agent() -> ureq::Agent {
    // Bounded, like every other request in this project: a supervisor that can hang on the thing it is
    // supervising is not a supervisor.
    ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_connect(Some(Duration::from_secs(3)))
        .timeout_recv_response(Some(Duration::from_secs(5)))
        .timeout_recv_body(Some(Duration::from_secs(10)))
        .build()
        .into()
}

fn health() -> Option<Value> {
    let url = format!("http://127.0.0.1:{}/health", node_port());
    let response = health_agent().get(&url).call().ok()?;
    let text = response.into_body().read_to_string().ok()?;
    serde_json::from_str(&text).ok()
}

fn node_is_up() -> bool {
    health().is_some()
}

fn node_is_idle() -> bool {
    match health() {
        Some(value) => value.get("current").map(|c| c.is_null()).unwrap_or(true),
        None => true,
    }
}

/// The pid listening on a port. By *port*, never by image name: another `wa` on the machine may be
/// somebody's session, and killing every process that shares a name is how that session dies.
fn pid_on_port(port: u16) -> Option<u32> {
    if cfg!(windows) {
        let output = std::process::Command::new("netstat").args(["-ano", "-p", "TCP"]).output().ok()?;
        let text = String::from_utf8_lossy(&output.stdout);
        let needle = format!(":{port} ");
        for line in text.lines() {
            let fields: Vec<&str> = line.split_whitespace().collect();
            // Proto  Local            Foreign          State       PID
            if fields.len() >= 5 && fields[0].eq_ignore_ascii_case("TCP")
                && fields[1].ends_with(&needle.trim_end()) && fields[1].contains(&format!(":{port}"))
                && fields[3].eq_ignore_ascii_case("LISTENING")
            {
                if let Ok(pid) = fields[4].parse() {
                    return Some(pid);
                }
            }
        }
        return None;
    }
    let output = std::process::Command::new("ss").args(["-ltnp"]).output().ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    for line in text.lines() {
        if line.contains(&format!(":{port} ")) {
            if let Some(rest) = line.split("pid=").nth(1) {
                if let Some(pid) = rest.split(',').next().and_then(|p| p.parse().ok()) {
                    return Some(pid);
                }
            }
        }
    }
    None
}

fn stop_node(reason: &str) -> Result<()> {
    let pid = pid_on_port(node_port()).context("nothing is listening on the node's port")?;
    say(&format!("stopping node pid {pid} (by pid, never by image name)"));
    if cfg!(windows) {
        std::process::Command::new("taskkill").args(["/PID", &pid.to_string(), "/F"]).output()?;
    } else {
        std::process::Command::new("kill").arg(pid.to_string()).output()?;
    }
    for _ in 0..20 {
        if pid_on_port(node_port()).is_none() {
            audit("stop", &format!("pid {pid}"), reason);
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    bail!("pid {pid} is still listening on {}", node_port())
}

fn start_node(binary: &Path, reason: &str) -> Result<()> {
    let ui = ui_dir();
    let port = node_port().to_string();
    let cport = client_port().to_string();
    say(&format!("starting {} on port {port}", binary.display()));
    if cfg!(windows) {
        // Start-Process gives a process that outlives this one: the sentinel must be able to start a
        // node and then exit without taking the node with it.
        let status = std::process::Command::new("powershell")
            .args([
                "-NoProfile", "-Command",
                &format!(
                    "Start-Process -FilePath '{}' -ArgumentList @('serve','--port','{port}','--client-port','{cport}','--ui','{}') -WindowStyle Hidden",
                    binary.display(), ui.display()
                ),
            ])
            .status()?;
        if !status.success() {
            bail!("could not start the node (powershell exit {status})");
        }
    } else {
        std::process::Command::new(binary)
            .args(["serve", "--port", &port, "--client-port", &cport, "--ui"])
            .arg(&ui)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .context("spawn node")?;
    }
    audit("start", &binary.display().to_string(), reason);
    Ok(())
}

fn wait_up(seconds: u64) -> bool {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    while Instant::now() < deadline {
        if node_is_up() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    false
}

// ---------------------------------------------------------------- verbs

/// Wake the model: a turn, in a session, with a prompt. This is the only verb that costs money, so it
/// is the only one that is budgeted.
fn verb_wake(session: &str, prompt: &str, reason: &str) -> Result<String> {
    if session.is_empty() {
        bail!("wake needs --session");
    }
    if prompt.trim().is_empty() {
        bail!("wake needs --prompt");
    }
    let budget: u32 = std::env::var("WA_SENTINEL_WAKE_BUDGET")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(6);
    let used = wakes_last_hour();
    if used >= budget {
        audit("wake-refused", session, &format!("{reason} (budget {budget}/hour used)"));
        bail!("wake budget reached ({used}/{budget} in the last hour) - refusing, and saying so");
    }
    // Wait for the node to be listening. A wake is usually written *beside* a restart, and a node that
    // has just been started takes seconds to bind - so a wake that fires immediately loses the race and
    // does nothing. It happened on the first end-to-end run: the log said "the node did not accept the
    // wake" seven seconds after the restart, which is a supervisor failing at the one job it has.
    let deadline = Instant::now() + Duration::from_secs(120);
    while !node_is_up() {
        if Instant::now() >= deadline {
            audit("wake-failed", session, &format!("{reason} (the node never came up)"));
            bail!("the node is not answering after 120s - not waking it");
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    let url = format!("http://127.0.0.1:{}/chat", node_port());
    let body = json!({ "text": prompt }).to_string();
    // The streaming route, and a per-read timeout rather than a whole-request one.
    //
    // A wake runs a whole turn, which takes minutes, so the non-streaming route cannot answer inside any
    // sane timeout - the first version of this failed with "timeout: receive response" on a node that was
    // working perfectly, because it was waiting for a reply that would arrive when the turn ended. With
    // `Accept: text/event-stream` the node sends a delta as it goes, so silence for two minutes means
    // trouble and a long turn means traffic. Same reasoning as the node's own timeouts, and the same
    // shape as the UI's stream.
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_connect(Some(Duration::from_secs(3)))
        .timeout_recv_response(Some(Duration::from_secs(120)))
        .timeout_recv_body(Some(Duration::from_secs(120)))
        .build()
        .into();
    let mut last = String::new();
    for attempt in 1..=6 {
        // Say it started before it runs, not only when it finishes. A wake takes minutes, and a reader
        // inside that very turn looks for its own record - the agent did, and correctly reported "the
        // wake is not recorded as performed" because the completion line had not been written yet.
        audit("wake-start", session, reason);
        match agent
            .post(&url)
            .header("Content-Type", "application/json")
            .header("Accept", "text/event-stream")
            .header("X-WA-Session", session)
            .send(body.as_bytes())
        {
            Ok(response) => {
                let status = response.status().as_u16();
                if status != 200 {
                    let text = response.into_body().read_to_string().unwrap_or_default();
                    audit("wake-failed", session, &format!("{reason} (HTTP {status})"));
                    bail!("the node answered HTTP {status}: {}", text.chars().take(200).collect::<String>());
                }
                // Read to the end of the turn: `done` is the node saying it finished. Anything shorter is
                // reported, so a wake that half-happened is never recorded as a success.
                let reader = std::io::BufReader::new(response.into_body().into_reader());
                let mut events = 0u32;
                let mut saw_done = false;
                let mut failure: Option<String> = None;
                for line in std::io::BufRead::lines(reader) {
                    let Ok(line) = line else { break };
                    if !line.starts_with("data: ") {
                        continue;
                    }
                    events += 1;
                    let payload = &line[6..];
                    if payload.contains("\"type\":\"done\"") {
                        saw_done = true;
                        break;
                    }
                    if let Ok(value) = serde_json::from_str::<Value>(payload) {
                        if value.get("type").and_then(Value::as_str) == Some("error") {
                            failure = value.get("error").and_then(Value::as_str).map(str::to_string);
                        }
                    }
                }
                if let Some(error) = failure {
                    audit("wake-failed", session, &format!("{reason} (the turn failed: {error})"));
                    bail!("the turn failed: {error}");
                }
                audit("wake", session, &format!("{reason} ({events} events, done={saw_done})"));
                return Ok(format!("{events} events, done={saw_done}"));
            }
            Err(error) => {
                last = error.to_string();
                std::thread::sleep(Duration::from_millis(500 * attempt));
            }
        }
    }
    audit("wake-failed", session, &format!("{reason} ({last})"));
    bail!("the node did not accept the wake after 6 attempts: {last}")
}

fn wakes_last_hour() -> u32 {
    let Ok(text) = std::fs::read_to_string(log_path()) else { return 0 };
    let cutoff = now_epoch().saturating_sub(3600);
    text.lines()
        .filter(|line| {
            let mut fields = line.split('\t');
            let at: u64 = fields.next().and_then(|v| v.parse().ok()).unwrap_or(0);
            at >= cutoff && fields.next() == Some("wake")
        })
        .count() as u32
}

fn verb_restart(reason: &str) -> Result<String> {
    let binary = installed_binary();
    if !binary.exists() {
        bail!("nothing installed at {}", binary.display());
    }
    // Wait for the node to be idle before stopping it. It cannot save the turn that is running, but it
    // can refuse to be the reason one dies: a restart nobody needed to interrupt is a restart that
    // waited.
    let deadline = Instant::now() + Duration::from_secs(900);
    while !node_is_idle() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_secs(2));
    }
    if !node_is_idle() {
        bail!("the node is still running a turn after 900s - not restarting under it");
    }
    if node_is_up() {
        stop_node(reason)?;
    } else {
        say("the node was not running; starting it");
    }
    start_node(&binary, reason)?;
    if wait_up(60) {
        return Ok("the node is back".into());
    }
    bail!("the node did not come up within 60s - check the node log")
}

/// Upgrade by running the operator's script, which already proves the binary, waits for idle, swaps,
/// verifies and rolls back. Reimplementing that here would be a second implementation of the same
/// safety properties, and the second one is always the one that is wrong.
/// The interpreter to run a shell script with, and the script path in the form that interpreter
/// can open.
///
/// This is where the upgrade was actually broken, and it took three wrong theories to find:
///
///   * `Command::new("bash")` resolves through the *system* PATH. On this machine that is
///     `C:\Windows\System32\bash.exe` - **WSL's** bash - because Git Bash's directories are not on
///     the system PATH for a detached process. WSL sees a Linux filesystem, so the script's
///     `/c/Users/...` path does not exist there and bash exits 127 with "No such file or
///     directory" for a file that plainly exists. Every theory about the file (missing, unreadable,
///     CRLF, a `C:/` vs `/c/` form) was wrong; the interpreter was.
///   * A Git Bash *does* accept `/c/...` for the script, but not `C:/...` - hence the drive-form
///     conversion below, which must match whichever interpreter is chosen.
///
/// So: find a Git Bash by its own install location (the one place that is certain), pass it the
/// POSIX form of the script, and pass the *binary* in the Windows form the script's `[ -x ... ]`
/// test can actually stat. `sh` on Unix, unchanged.
fn shell_for(script: &Path) -> (String, String) {
    if !cfg!(windows) {
        return ("sh".into(), script.display().to_string());
    }
    for candidate in [
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files\Git\usr\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
    ] {
        if Path::new(candidate).exists() {
            return (candidate.to_string(), to_msys_path(script));
        }
    }
    // No Git Bash found: fall back to whatever `bash` is, with the Windows path form, and let the
    // error name the real problem rather than a missing file.
    ("bash".into(), script.display().to_string())
}

/// The binary argument, in the form the script's own `[ -x "$NEW" ]` test understands. That test
/// runs under the shell we just chose, so the same rule applies: a POSIX path for a MSYS bash.
fn shell_for_binary(binary: &str) -> String {
    if !cfg!(windows) {
        return binary.to_string();
    }
    if binary.len() > 2 && binary.as_bytes()[1] == b':' && binary.as_bytes()[2] == b'/' {
        return to_msys_path(Path::new(binary));
    }
    binary.to_string()
}

/// `C:/dir/file` -> `/c/dir/file`. Only the drive form needs it; anything else is passed through
/// unchanged rather than mangled into something worse.
fn to_msys_path(path: &Path) -> String {
    let text = path.display().to_string();
    let bytes = text.as_bytes();
    if bytes.len() > 2 && bytes[1] == b':' && bytes[2] == b'/' {
        let drive = (bytes[0] as char).to_ascii_lowercase();
        return format!("/{drive}{}", &text[2..]);
    }
    text
}

fn verb_upgrade(binary: &str, reason: &str) -> Result<String> {
    if binary.is_empty() {
        bail!("upgrade needs --binary");
    }
    let script = resolve_upgrade_script()?;
    let (interpreter, script_arg) = shell_for(&script);
    let status = std::process::Command::new(&interpreter)
        // The path is passed to the interpreter as its first argument. Git Bash does not accept a
        // `C:/...` path there, and WSL's bash cannot see `/c/...` at all, so both the interpreter
        // *and* the path form have to agree (`shell_for`).
        .arg(&script_arg)
        .arg(shell_for_binary(binary))
        // The script locates the repo from its own path (`dirname $0/..`), so the working
        // directory does not matter to it. This used to pin cwd to the sentinel's own, which was
        // the install directory - a directory with no `scripts/` in it, which is exactly why the
        // relative default could never be found from a detached watcher.
        .current_dir(std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
        .status()
        .context("run the upgrade script")?;
    audit("upgrade", binary, reason);
    if status.success() {
        Ok("upgraded".into())
    } else {
        bail!("the upgrade script failed (exit {status}) - it rolls back, so the node should be running the previous binary")
    }
}

/// Where `scripts/upgrade.sh` is.
///
/// The default used to be the bare relative path `scripts/upgrade.sh`, checked against the
/// sentinel's own working directory. The sentinel is *detached* - started by `Start-Process`, which
/// does not inherit the launcher's environment or its cwd - so its cwd is the install directory
/// (e.g. `%LOCALAPPDATA%\wasm-agent`), which contains no `scripts/`. The check therefore failed on
/// every upgrade, the audit line was still written, and the operator saw an "upgrade" entry with no
/// swap and no explanation. It happened twice before this was traced.
///
/// Resolution order, so an upgrade works from a detached watcher:
///   1. `WA_UPGRADE_SCRIPT`, the explicit override.
///   2. `scripts/upgrade.sh` beside the *installed binary* (the upgrade target's directory) - this
///      is where an install that ships the script puts it.
///   3. `scripts/upgrade.sh` under the current directory, for a watcher started from a checkout.
fn resolve_upgrade_script() -> Result<PathBuf> {
    if let Ok(explicit) = std::env::var("WA_UPGRADE_SCRIPT") {
        if Path::new(&explicit).exists() {
            return Ok(PathBuf::from(explicit));
        }
        bail!("WA_UPGRADE_SCRIPT points at {explicit}, which does not exist");
    }
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(me) = std::env::current_exe() {
        if let Some(dir) = me.parent() {
            candidates.push(dir.join("scripts").join("upgrade.sh"));
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        candidates.push(cwd.join("scripts").join("upgrade.sh"));
        // One level up, because a watcher is often started from a subdirectory of the checkout.
        if let Some(up) = cwd.parent() {
            candidates.push(up.join("scripts").join("upgrade.sh"));
        }
    }
    for candidate in &candidates {
        if candidate.exists() {
            return Ok(candidate.clone());
        }
    }
    bail!(
        "no upgrade script found (looked at {}; set WA_UPGRADE_SCRIPT to the full path)",
        candidates
            .iter()
            .map(|c| c.display().to_string())
            .collect::<Vec<_>>()
            .join(", ")
    )
}

fn verb_run(script: &str, reason: &str) -> Result<String> {
    if script.is_empty() {
        bail!("run needs --script");
    }
    let allowed = std::env::var("WA_SENTINEL_SCRIPTS").unwrap_or_default();
    if allowed.is_empty() {
        bail!("run is disabled: set WA_SENTINEL_SCRIPTS to the directories it may execute from");
    }
    let path = std::fs::canonicalize(script).context("resolve script")?;
    let permitted = allowed.split(';').any(|dir| {
        !dir.trim().is_empty() && path.starts_with(std::fs::canonicalize(dir.trim()).unwrap_or_else(|_| PathBuf::from(dir.trim())))
    });
    if !permitted {
        bail!("{} is not inside WA_SENTINEL_SCRIPTS", path.display());
    }
    let status = std::process::Command::new(if cfg!(windows) { "bash" } else { "sh" }).arg(&path).status()?;
    audit("run", &path.display().to_string(), reason);
    if status.success() { Ok("ran".into()) } else { bail!("script exited {status}") }
}

fn perform(request: &Value) -> Result<String> {
    let verb = request.get("verb").and_then(Value::as_str).unwrap_or("");
    let reason = request.get("reason").and_then(Value::as_str).unwrap_or("(no reason given)");
    match verb {
        "restart" => verb_restart(reason),
        "upgrade" => verb_upgrade(request.get("binary").and_then(Value::as_str).unwrap_or(""), reason),
        "wake" => {
            let session = request.get("session").and_then(Value::as_str).unwrap_or("");
            let prompt = request.get("prompt").and_then(Value::as_str).unwrap_or("");
            // A wake runs a whole turn, which takes minutes: it must not hold the watch loop. The
            // record says "spawned", not "ok" - at this point the outcome is genuinely unknown, and a
            // supervisor that reports success before it knows is the thing it exists to prevent.
            let (session, prompt, reason) = (session.to_string(), prompt.to_string(), reason.to_string());
            std::thread::spawn(move || match verb_wake(&session, &prompt, &reason) {
                Ok(_) => {}
                Err(error) => audit("wake-error", &session, &error.to_string()),
            });
            Ok("spawned".into())
        }
        "run" => verb_run(request.get("script").and_then(Value::as_str).unwrap_or(""), reason),
        other => bail!("unknown verb {other:?}"),
    }
}

// ---------------------------------------------------------------- the drop-box

fn process_requests() -> Result<u32> {
    let dir = sentinel_dir().join("requests");
    let mut handled = 0;
    let mut entries: Vec<PathBuf> = std::fs::read_dir(&dir)
        .with_context(|| format!("read {}", dir.display()))?
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|path| path.extension().map(|e| e == "json").unwrap_or(false))
        .collect();
    // Oldest first: a queue that runs backwards is a queue nobody can reason about.
    entries.sort();
    for path in entries {
        let text = std::fs::read_to_string(&path).unwrap_or_default();
        let request: Value = match serde_json::from_str(&text) {
            Ok(value) => value,
            Err(error) => {
                audit("bad-request", &path.display().to_string(), &error.to_string());
                let _ = std::fs::rename(&path, sentinel_dir().join("failed").join(path.file_name().unwrap_or_default()));
                continue;
            }
        };
        let outcome = perform(&request);
        let (folder, detail) = match &outcome {
            Ok(detail) => ("done", detail.clone()),
            Err(error) => ("failed", error.to_string()),
        };
        let record = json!({
            "request": request,
            // Not `ok`: for a spawned wake the outcome is genuinely unknown at this point, and a
            // supervisor that reports success before it knows is the thing it exists to prevent. The
            // log carries what happened, when it happens.
            "ok": if matches!(outcome.as_ref().map(|d| d.as_str()), Ok("spawned")) { Value::Null } else { json!(outcome.is_ok()) },
            "detail": detail,
            "at": now_epoch(),
        });
        let target = sentinel_dir().join(folder).join(path.file_name().unwrap_or_default());
        let _ = std::fs::write(&target, serde_json::to_string_pretty(&record).unwrap_or_default());
        let _ = std::fs::remove_file(&path);
        say(&format!("{}: {}", if outcome.is_ok() { "ok" } else { "failed" }, detail));
        handled += 1;
    }
    Ok(handled)
}

/// Write a request into the box. This is the agent's whole interface: it never stops the node itself,
/// it asks, and the request survives whatever happens to the writer next.
fn request(args: &[String]) -> Result<()> {
    let verb = args.first().cloned().unwrap_or_default();
    if verb.is_empty() || verb == "help" {
        print_help();
        return Ok(());
    }
    let mut fields = serde_json::Map::new();
    fields.insert("verb".into(), json!(verb));
    let mut index = 1;
    while index < args.len() {
        let key = args[index].trim_start_matches("--").to_string();
        let value = args.get(index + 1).cloned().unwrap_or_default();
        fields.insert(key, json!(value));
        index += 2;
    }
    let stamp = format!("{}-{}", now_epoch(), std::process::id());
    let path = sentinel_dir().join("requests").join(format!("{stamp}.json"));
    // Read the reason before the map is moved into the file: the audit line is written from the same
    // request, and a supervisor's log must not depend on the order of two statements.
    let reason = fields.get("reason").and_then(Value::as_str).unwrap_or("(no reason given)").to_string();
    std::fs::write(&path, serde_json::to_string_pretty(&Value::Object(fields))?)
        .with_context(|| format!("write {}", path.display()))?;
    audit("request", &verb, &reason);
    say(&format!("requested {verb}: {}", path.display()));
    say("the sentinel performs it - it is the only thing that stops or starts this node");
    Ok(())
}

// ---------------------------------------------------------------- triggers
//
// The other half of the idea: not only "restart this for me" but "wake me when this happens".
//
// A trigger is a rule in `<config>/sentinel/triggers.json`:
//
//   [
//     { "kind": "file",     "path": "C:/Users/me/Downloads", "pattern": ".png",
//       "session": "<id>", "prompt": "a new file appeared: {name}", "reason": "download watcher" },
//     { "kind": "health",   "when": "down", "verb": "restart", "reason": "the node fell over" },
//     { "kind": "schedule", "every_seconds": 21600, "session": "<id>",
//       "prompt": "summarise what happened in the ledger since the last check", "reason": "6h summary" }
//   ]
//
// The shapes are deliberately few and the verbs are the same fixed list as everywhere else: a trigger
// decides *when*, never *what*. `{name}`, `{path}` and `{event}` are substituted into the prompt, so the
// model is told what happened rather than asked to guess.
//
// Every firing goes through the same budget as a manual wake. An event storm must not be able to spend
// money quietly - that is the one thing here that costs anything.
#[derive(Default)]
struct TriggerState {
    seen: std::collections::HashSet<String>,
    fired: std::collections::HashMap<String, Instant>,
    node_was_up: bool,
    primed: bool,
}

fn triggers_path() -> PathBuf {
    sentinel_dir().join("triggers.json")
}

fn load_triggers() -> Vec<Value> {
    let Ok(text) = std::fs::read_to_string(triggers_path()) else { return Vec::new() };
    match serde_json::from_str::<Value>(&text) {
        Ok(Value::Array(list)) => list,
        Ok(_) => {
            audit("triggers-bad", &triggers_path().display().to_string(), "expected a JSON array");
            Vec::new()
        }
        Err(error) => {
            audit("triggers-bad", &triggers_path().display().to_string(), &error.to_string());
            Vec::new()
        }
    }
}

/// Fire a trigger: the same verbs as a request, so a trigger cannot do anything an operator could not.
fn fire(trigger: &Value, event: &str) {
    let mut request = trigger.clone();
    let object = request.as_object_mut().unwrap();
    object.remove("kind");
    object.remove("path");
    object.remove("pattern");
    object.remove("every_seconds");
    object.remove("when");
    object.insert("verb".into(), object.get("verb").cloned().unwrap_or(json!("wake")));
    let name = Path::new(event).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let substitute = |value: &str| {
        value.replace("{name}", &name).replace("{path}", event).replace("{event}", event)
    };
    for key in ["prompt", "reason"] {
        if let Some(text) = object.get(key).and_then(Value::as_str) {
            let replaced = substitute(text);
            object.insert(key.into(), json!(replaced));
        }
    }
    let reason = object.get("reason").and_then(Value::as_str).unwrap_or("a trigger fired").to_string();
    audit("trigger", &format!("{event}"), &reason);
    match perform(&request) {
        Ok(detail) => say(&format!("trigger: {detail}")),
        Err(error) => audit("trigger-error", event, &error.to_string()),
    }
}

fn check_triggers(state: &mut TriggerState) {
    let triggers = load_triggers();
    if triggers.is_empty() {
        return;
    }
    let up = node_is_up();
    // The first pass only records the state: a sentinel started while the node is down must not decide
    // that the node *just* went down, and a directory full of old files must not fire once per file.
    let first = !state.primed;
    state.primed = true;
    for (index, trigger) in triggers.iter().enumerate() {
        let kind = trigger.get("kind").and_then(Value::as_str).unwrap_or("");
        match kind {
            "file" => {
                let path = trigger.get("path").and_then(Value::as_str).unwrap_or("");
                if path.is_empty() {
                    continue;
                }
                let pattern = trigger.get("pattern").and_then(Value::as_str).unwrap_or("");
                let entries = match std::fs::read_dir(path) {
                    Ok(entries) => entries,
                    // Say it, loudly. A POSIX path handed to this Windows process watched nothing at all
                    // and the only symptom was a trigger that never fired - which looks exactly like a
                    // trigger that is working and simply has not matched yet.
                    Err(error) => {
                        audit("trigger-unreadable", path, &error.to_string());
                        continue;
                    }
                };
                for entry in entries.flatten() {
                    let file = entry.path();
                    if !file.is_file() {
                        continue;
                    }
                    let name = file.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                    if !pattern.is_empty() && !name.contains(pattern) {
                        continue;
                    }
                    let key = format!("{index}:{}", file.display());
                    if state.seen.contains(&key) {
                        continue;
                    }
                    state.seen.insert(key);
                    if first {
                        continue;
                    }
                    fire(trigger, &file.display().to_string());
                }
            }
            "health" => {
                let want = trigger.get("when").and_then(Value::as_str).unwrap_or("down");
                let matched = (want == "down" && !up && state.node_was_up) || (want == "up" && up && !state.node_was_up);
                if matched && !first {
                    fire(trigger, &format!("node {want}"));
                }
            }
            "schedule" => {
                let every = trigger.get("every_seconds").and_then(Value::as_u64).unwrap_or(3600);
                let due = state.fired.get(&index.to_string()).map(|at| at.elapsed().as_secs() >= every).unwrap_or(true);
                if due && !first {
                    state.fired.insert(index.to_string(), Instant::now());
                    fire(trigger, "schedule");
                } else if due {
                    state.fired.insert(index.to_string(), Instant::now());
                }
            }
            _ => {}
        }
    }
    state.node_was_up = up;
}

// ---------------------------------------------------------------- the loop

fn watch() -> Result<()> {
    let _ = std::fs::remove_file(stop_path());
    std::fs::write(pid_path(), std::process::id().to_string())?;
    audit("watch", &format!("pid {}", std::process::id()), "sentinel started");
    say(&format!("watching: node on port {}, requests in {}", node_port(), sentinel_dir().join("requests").display()));
    say(&format!("stop it with: wa-sentinel stop   (or create {})", stop_path().display()));
    let mut down_since: Option<Instant> = None;
    let mut announced = false;
    let mut triggers = TriggerState::default();
    if !load_triggers().is_empty() {
        say(&format!("triggers: {}", triggers_path().display()));
    }
    loop {
        if stop_path().exists() {
            audit("watch", "stop file", "sentinel stopping on request");
            say("stop file found - stopping");
            let _ = std::fs::remove_file(pid_path());
            return Ok(());
        }
        if let Err(error) = process_requests() {
            audit("box-error", "requests", &error.to_string());
        }
        check_triggers(&mut triggers);
        // Watching the node, not restarting it: an auto-restart that nobody asked for would fight the
        // operator every time they stop a node on purpose. The outage is reported; restarting is a
        // request.
        if node_is_up() {
            if down_since.take().is_some() {
                audit("node-up", &format!("port {}", node_port()), "the node is answering again");
                say("the node is answering again");
            }
            announced = false;
        } else {
            let since = *down_since.get_or_insert_with(Instant::now);
            if !announced && since.elapsed() > Duration::from_secs(10) {
                audit("node-down", &format!("port {}", node_port()), "no answer to /health");
                say("the node is not answering - request a restart with: wa-sentinel request restart");
                announced = true;
            }
        }
        std::thread::sleep(Duration::from_secs(2));
    }
}

fn start_self() -> Result<()> {
    if let Ok(text) = std::fs::read_to_string(pid_path()) {
        if let Ok(pid) = text.trim().parse::<u32>() {
            if pid_alive(pid) {
                say(&format!("already watching (pid {pid})"));
                return Ok(());
            }
        }
    }
    let me = std::env::current_exe().context("find my own binary")?;
    if cfg!(windows) {
        std::process::Command::new("powershell")
            .args([
                "-NoProfile", "-Command",
                &format!("Start-Process -FilePath '{}' -ArgumentList @('watch') -WindowStyle Hidden", me.display()),
            ])
            .status()?;
    } else {
        std::process::Command::new(&me)
            .arg("watch")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()?;
    }
    say("started the sentinel");
    Ok(())
}

fn stop_self() -> Result<()> {
    std::fs::write(stop_path(), format!("{}\n", now_epoch()))?;
    say("asked the sentinel to stop");
    Ok(())
}

fn restart_self() -> Result<()> {
    let old = std::fs::read_to_string(pid_path()).ok().and_then(|t| t.trim().parse::<u32>().ok());
    if let Some(pid) = old {
        if pid_alive(pid) {
            stop_self()?;
            for _ in 0..20 {
                if !pid_alive(pid) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(250));
            }
            if pid_alive(pid) {
                bail!("the watcher (pid {pid}) did not stop - not starting a second one");
            }
        }
    }
    let _ = std::fs::remove_file(stop_path());
    start_self()
}

fn pid_alive(pid: u32) -> bool {
    if cfg!(windows) {
        let output = std::process::Command::new("tasklist")
            .args(["/FI", &format!("PID eq {pid}"), "/NH"])
            .output();
        return output.map(|o| String::from_utf8_lossy(&o.stdout).contains(&pid.to_string())).unwrap_or(false);
    }
    Path::new(&format!("/proc/{pid}")).exists()
}

fn status() -> Result<()> {
    let health = health();
    say(&format!("node:      port {} {}", node_port(), match &health {
        Some(value) => format!("up  {}", value),
        None => "not answering".into(),
    }));
    say(&format!("sentinel:  {}", match std::fs::read_to_string(pid_path()).ok().and_then(|t| t.trim().parse::<u32>().ok()) {
        Some(pid) if pid_alive(pid) => format!("watching (pid {pid})"),
        _ => "not running".into(),
    }));
    let pending = std::fs::read_dir(sentinel_dir().join("requests")).map(|d| d.count()).unwrap_or(0);
    let done = std::fs::read_dir(sentinel_dir().join("done")).map(|d| d.count()).unwrap_or(0);
    let failed = std::fs::read_dir(sentinel_dir().join("failed")).map(|d| d.count()).unwrap_or(0);
    say(&format!("requests:  {pending} waiting, {done} done, {failed} failed"));
    say(&format!("wakes:     {}/{} this hour", wakes_last_hour(),
        std::env::var("WA_SENTINEL_WAKE_BUDGET").unwrap_or_else(|_| "6".into())));
    if let Ok(text) = std::fs::read_to_string(log_path()) {
        let lines: Vec<&str> = text.lines().collect();
        say("recent:");
        for line in lines.iter().rev().take(5).collect::<Vec<_>>().iter().rev() {
            let fields: Vec<&str> = line.split('\t').collect();
            if fields.len() >= 3 {
                let age = now_epoch().saturating_sub(fields[0].parse().unwrap_or(0));
                say(&format!("  {}s ago  {}  {}  ({})", age, fields[1], fields[2], fields.get(3).unwrap_or(&"")));
            }
        }
    }
    Ok(())
}

fn print_help() {
    println!("{}", HELP);
}

const HELP: &str = r#"wa-sentinel - the process outside the node.

  request restart  [--reason TEXT]
  request upgrade  --binary PATH [--reason TEXT]
  request wake     --session ID --prompt TEXT [--reason TEXT]
  request run      --script PATH [--reason TEXT]
  once | watch | status | start | restart | stop | help

A node cannot restart itself: the turn doing the restarting runs on the node it is
stopping, so the stop is the last command it ever executes. It asks instead -
`request` writes a file, and the sentinel, outside, performs it. The file survives
the writer, which is the whole point.

Waking the model is the only verb that costs money, so it is the only one that is
budgeted (WA_SENTINEL_WAKE_BUDGET per hour, 6 by default). `run` is disabled unless
WA_SENTINEL_SCRIPTS names the directories it may execute from."#;

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let verb = args.first().map(String::as_str).unwrap_or("status");
    let rest = if args.len() > 1 { &args[1..] } else { &[] };
    let outcome = match verb {
        "request" => request(rest),
        "watch" => watch(),
        "once" => process_requests().map(|n| say(&format!("{n} request(s) handled"))),
        "status" => status(),
        "start" => start_self(),
        // Replacing the binary does not change a running process: the watcher keeps executing the image
        // it started with, so a fixed sentinel needs its own restart. Found by replacing this binary and
        // watching the old behaviour come out of the log.
        "restart" => restart_self(),
        "stop" => stop_self(),
        "help" | "--help" | "-h" => { print_help(); Ok(()) }
        other => {
            print_help();
            bail!("unknown verb {other:?}")
        }
    };
    if let Err(error) = outcome {
        eprintln!("  sentinel: {error:#}");
        std::process::exit(1);
    }
    Ok(())
}
