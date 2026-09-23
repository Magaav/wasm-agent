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
//!   request upgrade  --binary PATH [--session ID --prompt TEXT] [--reason TEXT]
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

// The `spell` verb: executing a declared plan while the node cannot execute it. A module rather
// than more functions here, because it is a different kind of thing - the verbs in this file act on
// the node, and this one carries out a sequence the *agent* wrote, under a whitelist.
mod spell;
mod jobs;
mod cdp;
mod instance;

// Stopping and starting a node through the Win32 API instead of through a spawned shell. The safety
// rule it must preserve - act on a pid the OS gave us, never on an image name - lives in the caller,
// and is what `SENTINEL.md` requires; see the module header for why the mechanism cannot weaken it.
#[cfg(windows)]
mod winproc;

// ---------------------------------------------------------------- paths

pub(crate) fn home() -> PathBuf {
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

pub(crate) fn sentinel_dir() -> PathBuf {
    let dir = config_dir().join("sentinel");
    // `claimed` too: a request is renamed into it before it is performed, and a missing directory
    // would make that rename fail - which, after the claim-before-work change, would mean no request
    // was ever processed at all. It is created here with the others so it cannot be forgotten.
    for sub in ["requests", "done", "failed", "claimed"] {
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
pub(crate) fn node_port() -> u16 {
    std::env::var("WASM_AGENT_PORT").ok().and_then(|v| v.parse().ok()).unwrap_or(8799)
}

pub(crate) fn client_port() -> u16 {
    std::env::var("WASM_AGENT_CLIENT_PORT").ok().and_then(|v| v.parse().ok()).unwrap_or(8800)
}

/// Where the installed binary lives. Not derived from the config directory: the install and the state
/// are in different places, and guessing wrong made `restart` report "nothing installed at
/// C:\Users\Victor\wasm-agent\wa.exe" - a path that never existed.
pub(crate) fn installed_binary() -> PathBuf {
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

pub(crate) fn now_epoch() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Append one line per action, with its reason. Nothing here happens silently: an action whose reason
/// is not written down is an action nobody can review.
pub(crate) fn audit(verb: &str, detail: &str, reason: &str) {
    use std::io::Write;
    let line = format!("{}\t{}\t{}\t{}\n", now_epoch(), verb, detail.replace('\n', " "), reason.replace('\n', " "));
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(log_path()) {
        let _ = file.write_all(line.as_bytes());
    }
}

pub(crate) fn say(message: &str) {
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
        .timeout_global(Some(Duration::from_secs(2)))
        .build()
        .into()
}

pub(crate) fn health() -> Option<Value> {
    let url = format!("http://127.0.0.1:{}/health", node_port());
    let response = health_agent().get(&url).call().ok()?;
    let text = response.into_body().read_to_string().ok()?;
    serde_json::from_str(&text).ok()
}

fn node_is_up() -> bool {
    health().is_some()
}

pub(crate) fn node_is_idle() -> bool {
    node_activity() == Some(true)
}

/// What `/health` says about whether a node can be interrupted, as a three-state answer.
///
/// `Some(true)` is a *positive* proof of idle: every signal the runtime offers says no work is in
/// flight. `Some(false)` is busy. `None` is "cannot tell" — the node is down, or the body is
/// missing a field this contract requires. Graceful maintenance treats `None` as busy and holds the
/// request, because stopping a node whose state is unknown is how a supervisor turns a slow run
/// into lost work. Starting a *down* node is still allowed: there is nothing to interrupt.
pub(crate) fn node_activity() -> Option<bool> {
    activity_of(&health()?)
}

/// The classification, split from the HTTP fetch so it can be tested against a literal body.
///
/// Fail-closed: every required field must be present and well-formed, and the new subagent summary
/// must have the exact shape the runtime promised. Anything else is `None` (ambiguous), which
/// graceful maintenance treats as busy. Scalars and arrays for `subagents` are rejected: the
/// contract is one object, not "whatever looks like a count".
pub(crate) fn activity_of(value: &Value) -> Option<bool> {
    if !value.get("ok").and_then(Value::as_bool)? {
        return Some(false); // stalled
    }
    // These are required by the health contract. The old code defaulted `current`/`queue` to idle,
    // which is how a supervisor stops a node whose state it cannot actually see.
    let current = value.get("current")?;
    let queue = value.get("queue")?.as_u64()?;
    let overdue = value.get("operation_overdue")?.as_bool()?;
    if !current.is_null() {
        return Some(false);
    }
    if queue > 0 {
        return Some(false);
    }
    if overdue {
        return Some(false);
    }
    // `workers` must be present, and each child must be an object with a string state. A malformed
    // child is ambiguous, not alive.
    let workers = value.get("workers")?.as_array()?;
    for worker in workers {
        let state = worker.as_object()?.get("state")?.as_str()?;
        if state != "alive" {
            return Some(false);
        }
    }
    // `execution_schema` is the runtime declaring which execution summary it reports. Schema 1
    // requires `subagents`; a legacy body may omit both. Any *other* schema is one this sentinel
    // does not know how to read, so it is ambiguous rather than idle. A present `subagents` field
    // must always have the strict shape, whatever the schema.
    let execution_schema = match value.get("execution_schema") {
        None => None,
        Some(Value::Number(number)) => Some(number.as_u64()?),
        Some(_) => return None,
    };
    if execution_schema.is_some_and(|schema| schema != 1) {
        return None; // an unknown execution schema cannot be read as idle
    }
    // Active operations are real side effects, not queued model work: a background command can
    // outlive the run that launched it, and `operation_overdue` only flags the tardy ones. So the
    // array itself is what says "busy". Schema 1 requires it; a legacy body may omit it.
    let operations = value.get("operations");
    if execution_schema == Some(1) && operations.is_none() {
        return None;
    }
    if let Some(operations) = operations {
        if !operations.is_null() {
            for entry in operations.as_array()? {
                let object = entry.as_object()?;
                // `operations::health()` filters to unsettled entries and omits `settled`, so an
                // absent marker means "not settled" (busy), not "malformed". A present one must be
                // a bool.
                let settled = match object.get("settled") {
                    None => false,
                    Some(value) => value.as_bool()?,
                };
                let state = object.get("state")?.as_str()?;
                if let Some(overdue) = object.get("overdue") {
                    if overdue.as_bool()? {
                        return Some(false);
                    }
                }
                if !settled {
                    return Some(false);
                }
                if let Some(cleanup) = object.get("cleanup") {
                    if cleanup.as_str()? == "unknown" {
                        return Some(false);
                    }
                }
                if !matches!(state, "done" | "cancelled" | "failed" | "exited" | "completed" | "ok") {
                    return None; // a settled state this sentinel does not know is ambiguous
                }
            }
        }
    }
    let subagents = value.get("subagents");
    if execution_schema == Some(1) && subagents.is_none() {
        return None; // schema 1 promises the field; its absence is ambiguous
    }
    if let Some(subagents) = subagents {
        if !subagents.is_null() {
            let object = subagents.as_object()?;
            let queued = object.get("queued")?.as_u64()?;
            let running = object.get("running")?.as_u64()?;
            let active = object.get("active")?.as_u64()?;
            if active != queued + running {
                return None; // a contradictory summary is ambiguous, never idle
            }
            if active > 0 {
                return Some(false);
            }
        }
    }
    // Optional legacy run reservations: any pending reservation or busy entry is work.
    if let Some(runs) = value.get("runs") {
        if !runs.is_null() {
            for entry in runs.as_array()? {
                let object = entry.as_object()?;
                if object.get("pending").and_then(Value::as_u64).unwrap_or(0) > 0 {
                    return Some(false);
                }
                if let Some(state) = object.get("state").and_then(Value::as_str) {
                    if matches!(state, "accepted" | "running" | "active" | "queued" | "pending" | "busy") {
                        return Some(false);
                    }
                }
            }
        }
    }
    Some(true)
}

/// Whether a verb that replaces the node may proceed now. A busy node holds the request; a down
/// node is startable (nothing to interrupt); a node that answers but cannot prove its state holds.
pub(crate) fn safe_to_start_maintenance() -> bool {
    match node_activity() {
        Some(idle) => idle,
        None => !node_is_up(),
    }
}

/// The pid listening on a port. By *port*, never by image name: another `wa` on the machine may be
/// somebody's session, and killing every process that shares a name is how that session dies.
pub(crate) fn pid_on_port(port: u16) -> Option<u32> {
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

/// The node id a listener on `port` announces. `/sync/head` is unauthenticated and carries the
/// identity, so this is the one probe that distinguishes "our node" from "some program on our
/// port". It is best-effort: a wedged node may not answer, which is why `recover` does not require
/// it (the pid, creation time and image are still proved).
fn node_id_on_port(port: u16) -> Option<String> {
    let url = format!("http://127.0.0.1:{port}/sync/head");
    let response = health_agent().get(&url).call().ok()?;
    let text = response.into_body().read_to_string().ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    value.get("node_id").and_then(Value::as_str).map(str::to_string)
}

/// Prove that the pid listening on `port` is the node this sentinel started for the selected
/// instance, and return it. This is the guard `SENTINEL.md` requires: a port is not an identity.
///
/// A valid record proves pid, process creation time (a recycled pid has a different one), image,
/// home, binary and — when `probe_identity` — the live announced node id. A **missing** record is
/// the legacy case (a node started by `upgrade.sh`, which writes only `serve.pid`); it is adopted
/// only for a graceful stop and only with positive proof. A record that exists but is corrupt is an
/// error, never a fallback to the weaker path.
fn verify_target(port: u16, probe_identity: bool) -> Result<u32> {
    let listener = pid_on_port(port)
        .with_context(|| format!("nothing is listening on the node's port {port}"))?;
    let selected = instance::selected().unwrap_or_else(|_| instance::default_instance());
    let expected_home = PathBuf::from(&selected.home);
    let expected_binary = installed_binary();
    match instance::read_record() {
        Ok(Some(record)) => {
            if record.pid != listener {
                // A gate deploy (`deploy.sh` -> `upgrade.sh`) restarts the node outside the
                // sentinel and writes only `serve.pid`, so the record still names the previous
                // pid. Refusing here made `request restart` permanently dead after the first
                // deploy - measured: "record pid 2280" against a live 12236. If `serve.pid` names
                // this listener and the live node proves its identity, adopt the new pid and
                // rewrite the record; a stranger still fails the proof and is refused exactly as
                // before (a stale record with no matching `serve.pid` cannot be adopted).
                if !probe_identity {
                    bail!(
                        "refusing to stop pid {listener} on port {port}: it is not the node this sentinel started (record pid {})",
                        record.pid
                    );
                }
                return adopt_legacy(port, listener, &expected_home, &expected_binary);
            }
            if !instance::same_path(Path::new(&record.home), &expected_home) {
                bail!(
                    "refusing to stop pid {listener}: the record's home {} is not this instance's home {}",
                    record.home,
                    expected_home.display()
                );
            }
            if !instance::same_path(Path::new(&record.binary), &expected_binary) {
                bail!(
                    "refusing to stop pid {listener}: the record's binary {} is not the installed node {}",
                    record.binary,
                    expected_binary.display()
                );
            }
            match instance::process_start(listener) {
                Some(start) if start == record.process_start => {}
                Some(_) => bail!("refusing to stop pid {listener}: its creation time does not match the lifecycle record (the pid was reused)"),
                None => bail!("refusing to stop pid {listener}: cannot read its creation time to prove it is ours"),
            }
            match instance::process_image(listener) {
                Some(image) if instance::same_path(&image, Path::new(&record.binary)) => {}
                Some(image) => bail!(
                    "refusing to stop pid {listener}: image {} is not the recorded node {}",
                    image.display(),
                    record.binary
                ),
                None => bail!("refusing to stop pid {listener}: cannot read its image to prove it is ours"),
            }
            if probe_identity {
                let announced = node_id_on_port(port);
                if announced.as_deref() != Some(record.node_id.as_str()) {
                    bail!(
                        "refusing to stop pid {listener}: the node on port {port} announces {:?}, not the recorded node_id {}",
                        announced,
                        record.node_id
                    );
                }
            }
            Ok(listener)
        }
        Ok(None) => {
            if !probe_identity {
                bail!(
                    "refusing to recover pid {listener} on port {port}: no lifecycle record, so its home and identity cannot be proven; legacy recovery is refused"
                );
            }
            adopt_legacy(port, listener, &expected_home, &expected_binary)
        }
        Err(error) => bail!(
            "refusing to stop pid {listener} on port {port}: the lifecycle record is unreadable or corrupt ({error}); refusing to fall back to serve.pid"
        ),
    }
}

/// Adopt a node started outside the sentinel (only `serve.pid` exists) — but only with positive
/// proof, and only for a graceful stop. The proof is: `serve.pid` names this listener, the image is
/// the installed node, the process creation marker is readable, the home's own key derives the
/// expected node id, and the live node announces exactly that id. The record is written **before**
/// the stop, so the creation marker is saved while the process is still alive.
fn adopt_legacy(port: u16, listener: u32, home: &Path, install: &Path) -> Result<u32> {
    let serve_pid = install
        .parent()
        .and_then(|dir| std::fs::read_to_string(dir.join("serve.pid")).ok())
        .and_then(|text| text.trim().parse::<u32>().ok());
    match serve_pid {
        Some(pid) if pid == listener => {}
        Some(pid) => bail!("refusing to adopt pid {listener} on port {port}: serve.pid records {pid}"),
        None => bail!("refusing to adopt pid {listener} on port {port}: no lifecycle record and no serve.pid, so it cannot be proven to be this node"),
    }
    match instance::process_image(listener) {
        Some(image) if instance::same_path(&image, install) => {}
        Some(image) => bail!(
            "refusing to adopt pid {listener}: image {} is not the installed node {}",
            image.display(),
            install.display()
        ),
        None => bail!("refusing to adopt pid {listener}: cannot read its image to prove it is the installed node"),
    }
    let process_start = instance::process_start(listener)
        .with_context(|| format!("refusing to adopt pid {listener}: cannot read its creation time"))?;
    let expected = instance::expected_node_id_from_home(home).with_context(|| {
        format!(
            "refusing to adopt pid {listener}: cannot derive the expected node id from {}",
            home.display()
        )
    })?;
    let announced = node_id_on_port(port).with_context(|| {
        format!("refusing to adopt pid {listener}: the node on port {port} did not answer /sync/head")
    })?;
    if announced != expected {
        bail!(
            "refusing to adopt pid {listener}: the node announces {announced}, but this home's key derives {expected}"
        );
    }
    let record = instance::Lifecycle {
        schema: 1,
        pid: listener,
        node_id: expected,
        home: home.display().to_string(),
        binary: install.display().to_string(),
        binary_sha256: instance::sha256_file(install).unwrap_or_default(),
        started_at: now_epoch(),
        process_start,
    };
    instance::write_record(&record)?;
    audit("legacy-adopted", &format!("pid {listener}"), "serve.pid plus live identity proof");
    Ok(listener)
}

/// Kill a pid the sentinel just started, for the failure path where no verifiable record could be
/// written. Best-effort: the caller is already returning an error.
fn stop_child(pid: u32) -> Result<()> {
    if cfg!(windows) {
        #[cfg(windows)]
        winproc::kill_pid(pid)?;
    } else {
        std::process::Command::new("kill").arg(pid.to_string()).output()?;
    }
    Ok(())
}

/// Stop the verified listener. `probe_identity` is true for graceful maintenance (the node answers
/// `/health`, so it can answer `/sync/head`) and false for `recover`, whose whole point is a node
/// that may be too wedged to answer. Even then the pid, creation time and image are proved.
pub(crate) fn stop_node_verified(reason: &str, probe_identity: bool) -> Result<()> {
    let port = node_port();
    let pid = verify_target(port, probe_identity)?;
    say(&format!("stopping node pid {pid} (by pid and identity, never by image name)"));
    if cfg!(windows) {
        // Win32 directly, rather than `taskkill`: a spawned helper costs ~138ms and, worse, is a
        // second program that could be absent or shadowed. The pid was just read from the OS.
        #[cfg(windows)]
        winproc::kill_pid(pid).context("stop the node")?;
    } else {
        std::process::Command::new("kill").arg(pid.to_string()).output()?;
    }
    for _ in 0..40 {
        // A freed port is not a dead process. The node may have released the listener and still be
        // flushing its turn's final message; starting the replacement (or delivering a wake) in that
        // window is what let two writers interleave one transcript. Wait for the pid itself to be gone.
        if pid_on_port(port).is_none() && !pid_alive(pid) {
            audit("stop", &format!("pid {pid}"), reason);
            instance::clear_record();
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    bail!("pid {pid} is still listening on {port} or still alive")
}

fn start_node(binary: &Path, reason: &str) -> Result<()> {
    let ui = ui_dir();
    let port = node_port();
    let cport = client_port();
    // A port already held is a collision, not a start. Refuse loudly instead of spawning a node
    // that fails to bind and then reads as "healthy" on the other instance's port.
    if let Some(holder) = pid_on_port(port) {
        bail!("port {port} is already held by pid {holder}; refusing to start a second node on it");
    }
    let selected = instance::selected().unwrap_or_else(|_| instance::default_instance());
    // A named guest is launched with an explicit environment so it cannot inherit the operator's
    // provider keys. The ambient/default instance keeps the historical inheritance, so a single-node
    // machine sees no behaviour change; its isolation boundary is the named instance.
    let named = std::env::var("WASM_AGENT_INSTANCE")
        .map(|value| !value.trim().is_empty())
        .unwrap_or(false);
    let sanitize = named && selected.is_guest();
    say(&format!("starting {} on port {port}", binary.display()));
    let args = vec![
        "serve".to_string(),
        "--port".to_string(), port.to_string(),
        "--client-port".to_string(), cport.to_string(),
        "--ui".to_string(), ui.display().to_string(),
    ];
    // CreateProcessW with DETACHED_PROCESS, rather than `powershell Start-Process`. Measured:
    // the shell hop costs ~243ms of the ~310ms it takes to see the node healthy, while the
    // node's own boot is ~49ms. This is the last place a shell was in the hot path. A guest gets
    // an explicit environment; a master inherits (the historical behaviour) with the instance
    // variables already set on us.
    #[cfg(windows)]
    let child_pid = {
        let env = if sanitize { Some(instance::guest_env(&selected)) } else { None };
        winproc::start_detached_with_env(binary, &args, env.as_deref()).context("start the node")?
    };
    #[cfg(not(windows))]
    let child_pid = {
        let mut command = std::process::Command::new(binary);
        command
            .args(&args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        if sanitize {
            command.env_clear();
            command.envs(instance::guest_env(&selected));
        }
        command.spawn().context("spawn node")?.id()
    };
    say(&format!("started pid {child_pid}"));
    // Record what was started, so a later stop can prove it is the same process rather than trusting
    // the port. `serve.pid` stays for the install tooling that reads it; the record is the proof.
    let node_id = match instance::node_id_for(binary, &home(), sanitize) {
        Ok(node_id) => node_id,
        Err(error) => {
            audit("identity-failed", &binary.display().to_string(), &error.to_string());
            String::new()
        }
    };
    // The creation marker must be read while the child is alive. Retry briefly, and if it cannot be
    // read, stop the child rather than leave a running node the sentinel can never prove it owns.
    let mut process_start = instance::process_start(child_pid);
    for _ in 0..20 {
        if process_start.map(|value| value != 0).unwrap_or(false) {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
        process_start = instance::process_start(child_pid);
    }
    let process_start = match process_start {
        Some(value) if value != 0 => value,
        _ => {
            let _ = stop_child(child_pid);
            bail!("started pid {child_pid} but could not read its creation time; stopped it rather than run an unverifiable node");
        }
    };
    let record = instance::Lifecycle {
        schema: 1,
        pid: child_pid,
        node_id,
        home: home().display().to_string(),
        binary: binary.display().to_string(),
        binary_sha256: instance::sha256_file(binary).unwrap_or_default(),
        started_at: now_epoch(),
        process_start,
    };
    if let Err(error) = instance::write_record(&record) {
        // A node with no record cannot be proven later. Stop it rather than run it unverifiable.
        let _ = stop_child(child_pid);
        bail!("started pid {child_pid} but could not record its lifecycle ({error}); stopped it");
    }
    // The install records the serving pid in `serve.pid`: upgrade.sh writes it, and the sentinel did not.
    // So a `request restart`/`request recover` left the recorded pid naming a process that was gone, and
    // the deploy gate reads exactly that as "two nodes, one port" (it refused the next deploy), while
    // `wa ui`'s stop instruction pointed at a dead pid. Record the pid the OS just gave us.
    if let Some(dir) = binary.parent() {
        if let Err(error) = std::fs::write(dir.join("serve.pid"), format!("{child_pid}\n")) {
            audit("serve-pid-failed", &dir.display().to_string(), &error.to_string());
        }
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
fn consume_wake(mut reader: impl std::io::BufRead) -> Result<u32> {
    let mut events=0; let mut total=0; let mut failure=None;
    loop {
        let mut line=Vec::new();
        let mut bounded=std::io::Read::take(&mut reader,1_048_577);
        let count=std::io::BufRead::read_until(&mut bounded,b'\n',&mut line)
            .map_err(|e|anyhow::anyhow!("wake outcome unknown: stream read failed: {e}"))?;
        if count==0 {bail!("wake outcome unknown: stream ended without done; do not replay automatically")}
        total+=count;
        if count>1_048_576 || total>8*1024*1024 {bail!("wake outcome unknown: stream_limit_exceeded; do not replay automatically")}
        if !line.starts_with(b"data: ") {continue;}
        events+=1;
        if let Ok(value)=serde_json::from_slice::<Value>(&line[6..]) {
            match value["type"].as_str() {
                Some("error")=>failure=Some(value["error"].as_str().unwrap_or("run failed").to_string()),
                Some("done")=>{if let Some(error)=failure {bail!("the turn failed: {error}")}return Ok(events);},
                _=>{},
            }
        }
    }
}

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
        // Refusing is the wrong shape for a budget. A wake that is refused for budget has had no side
        // effect at all - nothing happened - so the honest answer is "not yet": the caller puts it back in
        // the queue and it runs when the allowance rolls. Marked `wake-budget:` so callers can tell this
        // apart from a real failure, and audited as `wake-deferred` rather than `wake-refused`.
        audit("wake-deferred", session, &format!("{reason} (budget {budget}/hour used)"));
        bail!("wake-budget: {used}/{budget} in the last hour - deferred, not dropped");
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
    let body = json!({ "text": prompt, "thread": session }).to_string();
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
        .timeout_recv_body(Some(Duration::from_secs(600)))
        .timeout_global(Some(Duration::from_secs(3600)))
        .build()
        .into();
    let mut last = String::new();
    for attempt in 1..=1 {
        // Say it started before it runs, not only when it finishes. A wake takes minutes, and a reader
        // inside that very turn looks for its own record - the agent did, and correctly reported "the
        // wake is not recorded as performed" because the completion line had not been written yet.
        {
            // Serialize reservations across workers and sentinel processes; failed attempts cost budget too.
            let reservation=std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(sentinel_dir().join("wake-budget.lock"))?;
            reservation.lock()?;
            if wakes_last_hour()>=budget {bail!("wake-budget: reached before submission - deferred, not dropped")}
            use std::io::Write;
            let mut log=std::fs::OpenOptions::new().create(true).append(true).open(log_path())?;
            writeln!(log,"{}\twake-start\t{}\t{}",now_epoch(),session.replace(['\n','\r','\t']," "),reason.replace(['\n','\r','\t']," "))?;
            log.sync_all()?;
        }
        match agent
            .post(&url)
            .header("Content-Type", "application/json")
            .header("Accept", "text/event-stream")
            .header("X-WA-Session", &std::env::var("WA_SENTINEL_AUTH_SESSION").unwrap_or_default())
            // This POST starts a run, but it is automation, not an operator's foreground request:
            // the run-isolation contract demotes it to the background lane so a wake cannot starve
            // the human's own work. See docs/OPERATIONS.md.
            .header("X-WA-Run-Class", "background")
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
                let events = consume_wake(std::io::BufReader::new(response.into_body().into_reader()))?;
                audit("wake", session, &format!("{reason} ({events} events, done=true)"));
                return Ok(format!("{events} events, done=true"));
            }
            Err(error) => {
                last = error.to_string();
                std::thread::sleep(Duration::from_millis(500 * attempt));
            }
        }
    }
    audit("wake-failed", session, &format!("{reason} ({last})"));
    bail!("wake outcome unknown after submission: {last}; not automatically replayed")
}

fn wakes_last_hour() -> u32 {
    let Ok(text) = std::fs::read_to_string(log_path()) else { return 0 };
    let cutoff = now_epoch().saturating_sub(3600);
    text.lines()
        .filter(|line| {
            let mut fields = line.split('\t');
            let at: u64 = fields.next().and_then(|v| v.parse().ok()).unwrap_or(0);
            at >= cutoff && fields.next() == Some("wake-start")
        })
        .count() as u32
}

pub(crate) fn verb_restart(reason: &str) -> Result<String> {
    let binary = installed_binary();
    if !binary.exists() {
        bail!("nothing installed at {}", binary.display());
    }
    // Graceful maintenance must not block the watcher. process_requests leaves it queued while busy,
    // and an ambiguous health body (a node that answers but cannot prove its state) holds too.
    if !safe_to_start_maintenance() {
        bail!("node busy or its state cannot be proven: graceful restart deferred; request recover to interrupt a failed node");
    }
    if node_is_up() {
        stop_node_verified(reason, true)?;
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
    let raw = path.display().to_string();
    // canonicalize on Windows returns a verbatim path; Git Bash cannot consume that prefix.
    let text = raw.strip_prefix(r"\\?\").unwrap_or(&raw).replace('\\', "/");
    let bytes = text.as_bytes();
    if bytes.len() > 2 && bytes[1] == b':' && bytes[2] == b'/' {
        let drive = (bytes[0] as char).to_ascii_lowercase();
        return format!("/{drive}{}", &text[2..]);
    }
    text
}

pub(crate) fn verb_upgrade(binary: &str, reason: &str) -> Result<String> {
    if binary.is_empty() {
        bail!("upgrade needs --binary");
    }
    let script = resolve_upgrade_script()?;
    let (interpreter, script_arg) = shell_for(&script);
    let output = std::process::Command::new(&interpreter)
        // The path is passed to the interpreter as its first argument. Git Bash does not accept a
        // `C:/...` path there, and WSL's bash cannot see `/c/...` at all, so both the interpreter
        // *and* the path form have to agree (`shell_for`).
        .arg(&script_arg)
        .arg(shell_for_binary(binary))
        .env("WA_UPGRADE_VIA", "sentinel")
        .env("WA_UPGRADE_REASON", reason)
        // The script locates the repo from its own path (`dirname $0/..`), so the working
        // directory does not matter to it. This used to pin cwd to the sentinel's own, which was
        // the install directory - a directory with no `scripts/` in it, which is exactly why the
        // relative default could never be found from a detached watcher.
        .current_dir(std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
        .output()
        .context("run the upgrade script")?;
    let log = sentinel_dir().join("upgrade.log");
    let mut record = format!("{}\t{}\t{}\n", now_epoch(), binary, reason);
    record.push_str(&String::from_utf8_lossy(&output.stdout));
    record.push_str(&String::from_utf8_lossy(&output.stderr));
    record.push('\n');
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&log) {
        let _ = file.write_all(record.as_bytes());
    }
    if output.status.success() {
        audit("upgrade", binary, reason);
        Ok(format!("upgraded; install record refreshed; transcript at {}", log.display()))
    } else {
        audit("upgrade-failed", binary, reason);
        bail!("the upgrade script failed (exit {}); inspect {} and the live node before assuming rollback", output.status, log.display())
    }
}

/// Install everything that needs installing - the node, the UI **and the sentinel** - which is the one
/// thing `upgrade` cannot do, because `upgrade.sh` never copies a sentinel.
///
/// Detached, on purpose, and this is the opposite of how every other verb works. Every other verb is a
/// supervised child whose output is evidence; this one has to outlive its parent, because the parent
/// *is* what is being replaced: a child of ours would be stopped with the watcher, mid-swap, and the
/// only way to replace a running image on Windows is to be a different process while it happens. The
/// evidence is not lost by that - `deploy.sh` proves the new node on a scratch port before it goes near
/// the live one, records `installed.txt` and `deploy.log`, and rolls back on its own - and the completion
/// signal is the continuation wake, which the *new* watcher performs.
pub(crate) fn verb_deploy(session: &str, prompt: &str, reason: &str) -> Result<String> {
    let script = resolve_deploy_script()?;
    let (interpreter, script_arg) = shell_for(&script);
    let mut args = vec![script_arg, "--reason".to_string(), reason.to_string()];
    if !session.is_empty() {
        args.push("--session".to_string());
        args.push(session.to_string());
    }
    if !prompt.is_empty() {
        args.push("--prompt".to_string());
        args.push(prompt.to_string());
    }
    #[cfg(windows)]
    let pid = winproc::start_detached(Path::new(&interpreter), &args)
        .context("start the deploy script detached")?;
    // POSIX: spawn without waiting and without inheriting our stdio. There is no DETACHED_PROCESS to ask
    // for, so the process outlives us by virtue of not being waited on - which is all this needs, because
    // the deploy restarts the watcher itself.
    #[cfg(not(windows))]
    let pid = {
        use std::process::Stdio;
        std::process::Command::new(&interpreter)
            .args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .context("start the deploy script detached")?
            .id()
    };
    audit("deploy", &script.display().to_string(), reason);
    let continuation = if session.is_empty() {
        "no continuation was requested (no --session)".to_string()
    } else {
        format!("{session} will be woken when it finishes")
    };
    Ok(format!(
        "deploy started detached (pid {pid}) from {}; it waits for idle, installs the node, the UI and the sentinel, and {continuation}",
        script.display()
    ))
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
///   1. the explicit override (`WA_UPGRADE_SCRIPT`, `WA_SENTINEL_DEPLOY`).
///   2. `scripts/<file>` beside the *installed binary* (the upgrade target's directory) - this
///      is where an install that ships the script puts it.
///   3. `scripts/<file>` under the current directory, for a watcher started from a checkout.
fn resolve_script(file: &str, override_env: &str) -> Result<PathBuf> {
    if let Ok(explicit) = std::env::var(override_env) {
        if Path::new(&explicit).exists() {
            return Ok(PathBuf::from(explicit));
        }
        bail!("{override_env} points at {explicit}, which does not exist");
    }
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(me) = std::env::current_exe() {
        if let Some(dir) = me.parent() {
            candidates.push(dir.join("scripts").join(file));
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        candidates.push(cwd.join("scripts").join(file));
        // One level up, because a watcher is often started from a subdirectory of the checkout.
        if let Some(up) = cwd.parent() {
            candidates.push(up.join("scripts").join(file));
        }
    }
    for candidate in &candidates {
        if candidate.exists() {
            return Ok(candidate.clone());
        }
    }
    bail!(
        "no {file} found (looked at {}; set {override_env} to the full path)",
        candidates
            .iter()
            .map(|c| c.display().to_string())
            .collect::<Vec<_>>()
            .join(", ")
    )
}

fn resolve_upgrade_script() -> Result<PathBuf> {
    resolve_script("upgrade.sh", "WA_UPGRADE_SCRIPT")
}

/// The deploy script, which is a different job from the upgrade script: `upgrade.sh` installs the node
/// and the UI, while only `deploy.sh` installs a **sentinel**. That distinction is the whole reason the
/// `deploy` verb exists - without it, a sentinel fix could only be installed by a human at a shell.
fn resolve_deploy_script() -> Result<PathBuf> {
    resolve_script("deploy.sh", "WA_SENTINEL_DEPLOY")
}

/// Verbs that change what the node is running. One at a time: two of these interleaved would fight over
/// the same binary and the same pid file.
fn is_management_verb(verb: &str) -> bool {
    matches!(verb, "restart" | "recover" | "upgrade" | "spell" | "deploy")
}

/// Verbs that stop or replace the node, which therefore must not start while a turn is running: the run
/// they would interrupt belongs to the session that asked for them. This is not a nicety - a deploy
/// launched inside a turn waits for the idle that only its own parent can produce, and `run`'s 302s
/// child deadline turns that deadlock into a kill. Kept as a named predicate so the next verb that
/// stops the node has somewhere to be right, and `tests` below fail if it is forgotten.
fn waits_for_idle(verb: &str) -> bool {
    matches!(verb, "restart" | "upgrade" | "spell" | "deploy")
}

fn approved_script(script: &str) -> Result<PathBuf> {
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
    Ok(path)
}

fn verb_run(script: &str, reason: &str) -> Result<String> {
    let path=approved_script(script)?;
    let (program,argument)=shell_for(&path);
    let manager=wa_operation::Manager::new(sentinel_dir().join("operations"));
    let mut spec=wa_operation::Spec::command(program,vec![argument]);spec.owner="sentinel:run".into();
    let id=manager.start(spec)?;
    let state=manager.wait(&id,Duration::from_secs(302))?;
    audit("run",&path.display().to_string(),reason);
    if state["ok"]==true {Ok(format!("operation {id} completed"))} else {let _=manager.cancel(&id);bail!("operation {id}: {}",state["error"])}
}

fn verb_recover(reason:&str)->Result<String> {
    let binary=installed_binary();if !binary.is_file() {bail!("installed binary missing")}
    // Recovery asks the OS, never the interpreter and never image names. It is an explicit
    // interruption, so it does not wait for idle - but it still proves the listener is ours, and
    // does not require the identity probe a wedged node may be unable to answer.
    if pid_on_port(node_port()).is_some() {stop_node_verified(reason,false)?;}
    start_node(&binary,reason)?;
    if !wait_up(60) {bail!("recovery started node but health was not confirmed")}
    Ok("node recovered; interrupted effects must be reconciled".into())
}

fn perform(request: &Value) -> Result<String> {
    let verb = request.get("verb").and_then(Value::as_str).unwrap_or("");
    let reason = request.get("reason").and_then(Value::as_str).unwrap_or("(no reason given)");
    match verb {
        "restart" => verb_restart(reason),
        "recover" => verb_recover(reason),
        "upgrade" => {
            let session = request.get("session").and_then(Value::as_str).unwrap_or("");
            let prompt = request.get("prompt").and_then(Value::as_str).unwrap_or("");
            if session.is_empty() != prompt.is_empty() {
                bail!("upgrade continuation requires both --session and --prompt");
            }
            let detail = verb_upgrade(request.get("binary").and_then(Value::as_str).unwrap_or(""), reason)?;
            if session.is_empty() {
                Ok(detail)
            } else {
                let wake=verb_wake(session,prompt,reason)?;
                Ok(format!("{detail}; continuation {wake}"))
            }
        },
        "wake" => {
            let session = request.get("session").and_then(Value::as_str).unwrap_or("");
            let prompt = request.get("prompt").and_then(Value::as_str).unwrap_or("");
            // process_requests owns this worker until completion; even `once` cannot lose a spawned wake.
            verb_wake(session,prompt,reason)
        }
        // The change a plain `upgrade` cannot make: only `deploy.sh` installs a *sentinel*, and this is
        // how a run asks for one without a human at a shell. Spawned **detached**, because the process
        // being replaced is the one that would otherwise be its parent - a child of ours would be
        // stopped together with the watcher mid-swap. The idle wait has already happened by the time this
        // runs (`waits_for_idle`), so the script's budget is spent installing rather than waiting.
        "deploy" => {
            let session = request.get("session").and_then(Value::as_str).unwrap_or("");
            let prompt = request.get("prompt").and_then(Value::as_str).unwrap_or("");
            if session.is_empty() != prompt.is_empty() {
                bail!("deploy continuation requires both --session and --prompt");
            }
            verb_deploy(session, prompt, reason)
        }
        "run" => verb_run(request.get("script").and_then(Value::as_str).unwrap_or(""), reason),
        // A plan the agent exported. Validated against a whitelist before a single step runs, and
        // settled by this process's own /health check - the assertion the node cannot make about
        // itself while it is the thing being replaced.
        "spell" => {
            let file = request.get("file").and_then(Value::as_str).unwrap_or("");
            match spell::verb_spell(file, reason) {
                Ok(outcome) => Ok(outcome),
                Err(error) => Err(error),
            }
        }
        other => bail!("unknown verb {other:?}"),
    }
}

// ---------------------------------------------------------------- the drop-box

static REQUEST_ACTIVE: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
static MAINTENANCE_ACTIVE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn finish_request(claim: &Path, request: &Value) {
    let outcome=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||perform(request)));
    let (folder,ok,detail)=match outcome {
        Ok(Ok(detail))=>("done",true,detail),
        Ok(Err(error))=>("failed",false,error.to_string()),
        Err(_)=>("failed",false,"request worker panicked; outcome unknown".into()),
    };
    // A wake deferred for budget is neither a failure nor a completion: the request goes back to the queue
    // and is retried when the allowance rolls over. Before this, the budget turned a deploy's continuation
    // into a `failed` record - so the run that asked for the deploy was never woken and nobody was told.
    if !ok && detail.starts_with("wake-budget") {
        let back = sentinel_dir().join("requests").join(claim.file_name().unwrap_or_default());
        if std::fs::rename(claim, &back).is_ok() {
            audit("wake-deferred", &back.display().to_string(), &detail);
            return;
        }
    }
    let record=json!({"request":request,"ok":ok,"detail":detail,"at":now_epoch()});
    let target=sentinel_dir().join(folder).join(claim.file_name().unwrap_or_default());
    match wa_operation::atomic_json(&target,&record) {
        Ok(())=>{let _=std::fs::remove_file(claim);},
        Err(error)=>audit("request-record-failed",&claim.display().to_string(),&error.to_string()),
    }
    say(&format!("{}: {detail}",if ok {"ok"}else{"failed"}));
}

fn process_requests(background: bool) -> Result<u32> {
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
        use std::sync::atomic::Ordering;
        let preview:Value=std::fs::read(&path).ok().and_then(|b|serde_json::from_slice(&b).ok()).unwrap_or(Value::Null);
        let capacity=if preview["verb"]=="recover" {5}else{4};
        if background && REQUEST_ACTIVE.load(Ordering::Acquire)>=capacity {continue;}
        let management=is_management_verb(preview["verb"].as_str().unwrap_or(""));
        if management && MAINTENANCE_ACTIVE.load(Ordering::Acquire) {continue;}
        // Maintenance stays queued; observing it never monopolizes the recovery/control loop.
        if waits_for_idle(preview["verb"].as_str().unwrap_or("")) && !safe_to_start_maintenance() {continue;}
        // Claim before working, not after. This used to read the request, do the work, and only then
        // remove the file - so a second runner (the watcher and a stray `once`, which is exactly what
        // happened) could pick up the same file while the first was still inside it, and run the
        // upgrade twice. Two `upgrade` lines appeared in the log for one request, and only the
        // request record showed it had been performed once. The rename is the claim: it is atomic, so
        // whichever runner calls it first owns the file, and the other sees it gone.
        let claim = sentinel_dir().join("claimed").join(path.file_name().unwrap_or_default());
        if std::fs::rename(&path, &claim).is_err() {
            // Someone else got it, or it vanished. Either way it is not this runner's to perform.
            continue;
        }
        let text = std::fs::read_to_string(&claim).unwrap_or_default();
        let request: Value = match serde_json::from_str(&text) {
            Ok(value) => value,
            Err(error) => {
                audit("bad-request", &claim.display().to_string(), &error.to_string());
                let _ = std::fs::rename(&claim, sentinel_dir().join("failed").join(claim.file_name().unwrap_or_default()));
                continue;
            }
        };
        if background {
            REQUEST_ACTIVE.fetch_add(1,Ordering::AcqRel);
            if management {MAINTENANCE_ACTIVE.store(true,Ordering::Release);}
            std::thread::spawn(move|| {
                finish_request(&claim,&request);
                if management {MAINTENANCE_ACTIVE.store(false,Ordering::Release);}
                REQUEST_ACTIVE.fetch_sub(1,Ordering::AcqRel);
            });
        } else {finish_request(&claim,&request);}
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
    wa_operation::atomic_json(&path,&Value::Object(fields))
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
    let stamp=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos();
    let path=sentinel_dir().join("requests").join(format!("{stamp}-trigger.json"));
    if let Err(error)=wa_operation::atomic_json(&path,&request) {audit("trigger-error",event,&error.to_string());}
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
    let _runner_lock=jobs::lock()?;
    jobs::store().recover(now_epoch() as i64).map_err(|e|anyhow::anyhow!(e.to_string()))?;
    let mut automations=jobs::Runner::new();
    let _ = std::fs::remove_file(stop_path());
    std::fs::write(pid_path(), std::process::id().to_string())?;
    audit("watch", &format!("pid {}", std::process::id()), "sentinel started");
    // Record what this watcher was told, durably, so the *next* start reads it instead of guessing. The
    // launcher carries the reservation in the environment and a deploy's `restart` inherits it, but a
    // hand-run `start` inherits a shell that never had it - and a watcher whose inference lane is
    // idle-gated looks healthy while a job's child sits in the queue. Writing it here is what makes the
    // value a property of the installation rather than of the process that happened to start it.
    {
        let (reserved, source) = jobs::reserved_child_capacity();
        let path = sentinel_dir().join(jobs::RESERVATION_FILE);
        let recorded = std::fs::read_to_string(&path).map(|text| text.trim().to_string()).unwrap_or_default();
        if source == "env" && recorded != reserved.to_string() {
            match std::fs::write(&path, format!("{reserved}\n")) {
                Ok(()) => say(&format!("reserved child capacity {reserved} recorded in {}", path.display())),
                Err(error) => say(&format!("could not record the reserved child capacity in {}: {error}", path.display())),
            }
        }
    }
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
        if let Err(error) = process_requests(true) {
            audit("box-error", "requests", &error.to_string());
        }
        check_triggers(&mut triggers);
        if let Err(error)=automations.tick() {audit("jobs-error","tick",&error.to_string());}
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
        std::thread::sleep(Duration::from_millis(200));
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
    // The reservation is a property of the installation, not of whoever asked for this watcher: a
    // deploy's `restart` and a hand-run `start` both spawn the watcher as *their* child, so a value that
    // lived only in the launcher's environment vanished on every upgrade and the inference lane went
    // silently idle-gated (jobs::reserved_child_capacity reads the durable file for exactly this).
    // Handing the resolved number on explicitly also makes the child's own environment honest, which is
    // what an operator checking the lane wants to see - "the launcher set it" is not a fact a child can
    // check.
    let (reserved, source) = jobs::reserved_child_capacity();
    if cfg!(windows) {
        std::process::Command::new("powershell")
            .env("WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY", reserved.to_string())
            .args([
                "-NoProfile", "-Command",
                &format!("Start-Process -FilePath '{}' -ArgumentList @('watch') -WindowStyle Hidden", me.display()),
            ])
            .status()?;
    } else {
        std::process::Command::new(&me)
            .arg("watch")
            .env("WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY", reserved.to_string())
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()?;
    }
    say(&format!("started the sentinel (reserved child capacity {reserved}, from {source})"));
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
    // The one setting whose absence is invisible until a job's child sits in the queue: say it out loud,
    // with where it came from, so "queued while a turn runs" has an answer here instead of a story.
    let (reserved, source) = jobs::reserved_child_capacity();
    say(&format!("jobs:      reserved child capacity {reserved} ({source}); inference lane {}",
        if reserved > 0 { "open to job children" } else { "idle-gated - a job's child waits for an idle node" }));
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

  request restart  [--reason TEXT]     (graceful; queued while busy)
  request recover  [--reason TEXT]     (explicit interruption; never waits for idle)
  job list | history | put <file.json> | enable <id> | disable <id>
  job emit <topic> <stable-event-id> <payload.json>
  request upgrade  --binary PATH [--session ID --prompt TEXT] [--reason TEXT]
  request wake     --session ID --prompt TEXT [--reason TEXT]
  request run      --script PATH [--reason TEXT]
  request spell    --file PATH [--reason TEXT]
  instance add <name> --port N --client-port N [--role master|guest] [--master ID]
                     [--home PATH] [--install-dir PATH] [--binary PATH] [--ui PATH]
                     [--share KEY=VALUE]...
  instance list | show <name> | remove <name> [--purge]
  instance start <name> | stop <name> | status <name>
  --instance <name>   run any verb against a named instance
  once | watch | status | start | restart | stop | help

A node cannot restart itself: the turn doing the restarting runs on the node it is
stopping, so the stop is the last command it ever executes. It asks instead -
`request` writes a file, and the sentinel, outside, performs it. The file survives
the writer, which is the whole point.

One machine can host several nodes: each instance has its own home, key, database,
ports and supervisor records. `--instance NAME` selects one; with no name the
ambient/default node is used exactly as before. A guest instance names the remote
master it is bound to and is launched with an explicit environment, so it never
inherits the operator's secrets.

Waking the model is the only verb that costs money, so it is the only one that is
budgeted (WA_SENTINEL_WAKE_BUDGET per hour, 6 by default). `run` is disabled unless
WA_SENTINEL_SCRIPTS names the directories it may execute from."#;

fn main() -> Result<()> {
    // The registry and the operator's own paths live under the ambient environment. Capture them
    // before any instance selection overwrites `WASM_AGENT_HOME`/`WA_INSTALL_DIR`, and pin them so
    // every later resolution sees the operator's paths rather than the selected instance's.
    let base = instance::base_home();
    std::env::set_var("WA_INSTANCE_BASE_HOME", &base);
    let operator_install = crate::installed_binary()
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    std::env::set_var("WA_INSTANCE_OPERATOR_INSTALL", &operator_install);

    // `--instance NAME` may appear anywhere; it selects a named instance for the whole invocation.
    // With no flag, behaviour is exactly as before (the ambient/default instance).
    let mut selected: Option<String> = None;
    let mut args: Vec<String> = Vec::new();
    let mut index = 0;
    let raw: Vec<String> = std::env::args().skip(1).collect();
    while index < raw.len() {
        if raw[index] == "--instance" {
            selected = raw.get(index + 1).cloned();
            index += 2;
            continue;
        }
        if let Some(value) = raw[index].strip_prefix("--instance=") {
            selected = Some(value.to_string());
            index += 1;
            continue;
        }
        args.push(raw[index].clone());
        index += 1;
    }
    if let Some(name) = selected {
        match instance::resolve(&name) {
            Ok(found) => instance::apply_env(&found),
            Err(error) => {
                eprintln!("  sentinel: {error:#}");
                std::process::exit(1);
            }
        }
    }
    let verb = args.first().map(String::as_str).unwrap_or("status");
    let rest = if args.len() > 1 { &args[1..] } else { &[] };
    let outcome = match verb {
        "request" => request(rest),
        "job" => jobs::cli(rest),
        "instance" => instance::cli(rest),
        "recover" => verb_recover(rest.first().map(String::as_str).unwrap_or("explicit operator recovery")).map(|s|say(&s)),
        "watch" => watch(),
        "once" => {let _lock=jobs::lock()?;process_requests(false).map(|n| say(&format!("{n} request(s) handled")))},
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

#[cfg(test)]
mod self_update_tests {
    use super::*;

    #[test]
    fn wake_requires_a_real_terminal_event_and_bounds_capture() {
        assert!(consume_wake(&b"data: {\"type\":\"tool\",\"nested\":{\"type\":\"done\"}}\n\n"[..]).unwrap_err().to_string().contains("unknown"));
        assert_eq!(consume_wake(&b"data: { \"type\" : \"done\" }\n\n"[..]).unwrap(),1);
        assert!(consume_wake(&b"data: {\"type\":\"error\",\"error\":\"fixture\"}\n\ndata: {\"type\":\"done\"}\n\n"[..]).is_err());
        let flood=vec![b'x';1_048_577];
        assert!(consume_wake(&flood[..]).unwrap_err().to_string().contains("stream_limit_exceeded"));
    }

    #[test]
    fn continuation_requires_both_fields_before_any_upgrade() {
        for request in [
            json!({"verb":"upgrade","binary":"not-a-binary","session":"thread"}),
            json!({"verb":"upgrade","binary":"not-a-binary","prompt":"continue"}),
            // The deploy path has the same rule: half a continuation is a wake nobody can receive.
            json!({"verb":"deploy","session":"thread"}),
            json!({"verb":"deploy","prompt":"continue"}),
        ] {
            let error = perform(&request).unwrap_err().to_string();
            assert!(error.contains("requires both --session and --prompt"), "{error}");
        }
    }

    /// The rule that a verb which stops the node waits for idle, asserted as a table so the next verb
    /// that replaces the node has to be added here on purpose. Its absence is what killed a deploy: the
    /// `run` verb does not wait, and its 302s child deadline expires while the deploy waits for the turn
    /// that asked for it to end.
    #[test]
    fn verbs_that_replace_the_node_wait_for_idle_and_are_serialised() {
        for verb in ["restart", "upgrade", "spell", "deploy"] {
            assert!(waits_for_idle(verb), "{verb} must wait for idle");
            assert!(is_management_verb(verb), "{verb} must not run beside another maintenance verb");
        }
        for verb in ["wake", "run"] {
            assert!(!waits_for_idle(verb), "{verb} must not wait for idle");
        }
    }

    /// A deploy request reaches a script and returns without blocking: the script is detached, because
    /// the process it replaces is the one that would have been its parent.
    #[test]
    fn a_deploy_request_spawns_the_script_and_returns() {
        let dir = std::env::temp_dir().join(format!("wa-deploy-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        let marker = dir.join("ran.txt");
        let script = dir.join("deploy-stub.sh");
        std::fs::write(
            &script,
            format!("#!/bin/sh\nprintf '%s\\n' \"$*\" > '{}'\n", marker.display()),
        )
        .expect("stub");
        // `WA_SENTINEL_DEPLOY` is the same override an operator uses when the script lives elsewhere.
        std::env::set_var("WA_SENTINEL_DEPLOY", &script);
        let detail = verb_deploy("thread-1", "continue", "fixture").expect("deploy accepted");
        assert!(detail.contains("detached"), "{detail}");
        assert!(detail.contains("thread-1"), "the continuation must be named: {detail}");
        // The child is detached, so it is *not* awaited - that is the property under test. Give it a
        // moment and read what it wrote.
        let mut wrote = None;
        for _ in 0..40 {
            if let Ok(text) = std::fs::read_to_string(&marker) {
                wrote = Some(text);
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        let written = wrote.unwrap_or_else(|| "(the stub never ran)".to_string());
        assert!(written.contains("--session thread-1"), "the session must reach the script: {written}");
        assert!(written.contains("--prompt continue"), "the prompt must reach the script: {written}");
        assert!(written.contains("--reason fixture"), "the reason must reach the script: {written}");
        std::env::remove_var("WA_SENTINEL_DEPLOY");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The idle contract. A node is idle only on positive proof; a body that omits a required
    /// field is ambiguous (`None`), and a busy worker, a queued admission or a running subagent is
    /// busy. These are the cases that decide whether a restart interrupts real work.
    #[test]
    fn idle_requires_positive_proof_and_unknown_health_is_not_idle() {
        // Legacy body: no execution_schema/subagents, but every required field present.
        let legacy_idle = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}]});
        assert_eq!(activity_of(&legacy_idle), Some(true));

        let busy_run = json!({"ok": true, "current": {"label": "POST /chat"}, "queue": 0,
            "operation_overdue": false, "workers": [{"id": 0, "state": "busy"}]});
        assert_eq!(activity_of(&busy_run), Some(false));

        let queued = json!({"ok": true, "current": null, "queue": 3, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}]});
        assert_eq!(activity_of(&queued), Some(false));

        let overdue = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": true,
            "workers": [{"id": 0, "state": "alive"}]});
        assert_eq!(activity_of(&overdue), Some(false));

        let stalled = json!({"ok": false, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "stalled"}]});
        assert_eq!(activity_of(&stalled), Some(false));

        // Schema 1: the strict subagent summary, `active == queued + running`, and the operations array.
        let schema_idle = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}], "execution_schema": 1, "operations": [],
            "subagents": {"queued": 0, "running": 0, "active": 0}});
        assert_eq!(activity_of(&schema_idle), Some(true));
        let subagent_running = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}], "execution_schema": 1, "operations": [],
            "subagents": {"queued": 1, "running": 1, "active": 2}});
        assert_eq!(activity_of(&subagent_running), Some(false));

        // An unsettled operation is real work even when it is not overdue: a background command can
        // outlive the run that launched it.
        let active_operation = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}],
            "operations": [{"state": "running", "settled": false, "overdue": false}]});
        assert_eq!(activity_of(&active_operation), Some(false));
        // The live health array omits `settled`; an entry with no marker is unsettled, so busy.
        let live_operation = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}],
            "operations": [{"state": "running", "overdue": false, "elapsed_ms": 12}]});
        assert_eq!(activity_of(&live_operation), Some(false));
        let settled_operation = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}],
            "operations": [{"state": "done", "settled": true, "cleanup": "terminated", "overdue": false}]});
        assert_eq!(activity_of(&settled_operation), Some(true));
        let cleanup_unknown = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}],
            "operations": [{"state": "failed", "settled": true, "cleanup": "unknown"}]});
        assert_eq!(activity_of(&cleanup_unknown), Some(false));
        let malformed_operation = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}],
            "operations": [{"settled": false}]});
        assert_eq!(activity_of(&malformed_operation), None);
        let unknown_settled_state = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}],
            "operations": [{"state": "mystery", "settled": true}]});
        assert_eq!(activity_of(&unknown_settled_state), None);

        // A present subagent field with any other shape is ambiguous, never idle.
        for malformed in [
            json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
                "workers": [{"id": 0, "state": "alive"}], "subagents": [{"state": "running"}]}),
            json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
                "workers": [{"id": 0, "state": "alive"}], "subagents": 1}),
            json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
                "workers": [{"id": 0, "state": "alive"}], "subagents": {"queued": 0, "running": 0}}),
            json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
                "workers": [{"id": 0, "state": "alive"}], "subagents": {"queued": 0, "running": 0, "active": 5}}),
            json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
                "workers": [{"id": 0, "state": "alive"}], "subagents": "busy"}),
        ] {
            assert_eq!(activity_of(&malformed), None, "{malformed}");
        }

        // Schema 1 promises the field; its absence is ambiguous.
        let schema_missing = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}], "execution_schema": 1, "operations": []});
        assert_eq!(activity_of(&schema_missing), None);

        // An unknown execution schema cannot be read as idle.
        let unknown_schema = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}], "execution_schema": 2});
        assert_eq!(activity_of(&unknown_schema), None);

        // Missing required fields are ambiguous, not idle: the old defaults were the bug.
        let no_workers = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false});
        assert_eq!(activity_of(&no_workers), None);
        let no_queue = json!({"ok": true, "current": null, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}]});
        assert_eq!(activity_of(&no_queue), None);
        let no_current = json!({"ok": true, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}]});
        assert_eq!(activity_of(&no_current), None);
        let bad_worker = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0}]});
        assert_eq!(activity_of(&bad_worker), None);

        // Legacy run reservations.
        let pending = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}], "runs": [{"pending": 1}]});
        assert_eq!(activity_of(&pending), Some(false));
        let running = json!({"ok": true, "current": null, "queue": 0, "operation_overdue": false,
            "workers": [{"id": 0, "state": "alive"}], "runs": [{"state": "running"}]});
        assert_eq!(activity_of(&running), Some(false));

        // A body with no `ok` at all is ambiguous too.
        assert_eq!(activity_of(&json!({"current": null})), None);
    }

    /// Path comparison is how the recorded image is matched to the running one; it must be case-
    /// and separator-insensitive, and must ignore the Windows verbatim prefix.
    #[test]
    fn recorded_and_running_paths_compare_as_files() {
        assert!(instance::same_path(
            Path::new(r"C:\Users\Victor\wasm-agent\wa.exe"),
            Path::new(r"\\?\C:/Users/Victor/wasm-agent/WA.EXE")
        ));
        assert!(!instance::same_path(
            Path::new(r"C:\a\wa.exe"),
            Path::new(r"C:\b\wa.exe")
        ));
    }
}
