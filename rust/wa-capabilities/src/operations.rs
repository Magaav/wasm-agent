//! The node's side of the operations runner: a wire client (`ready-operations-slice-2.md`, stage B).
//!
//! The runner moved to its own program (`wa-operations-supervisor`). What is left here is the seam the rest of
//! the node already called - `control`, `foreground`, `health`, `health_scope_for`, `elsewhere_count`,
//! `observe_owned_child` - with the same names and the same JSON, answered by that program over the loopback
//! wire slice 1 built, behind a token in a 0600 rendezvous file.
//!
//! **The node starts it.** A node that never names a supervisor still gets one: the first call spawns
//! `wa-operations-supervisor` (beside this binary, else on PATH) with a rendezvous under the agent home, waits
//! for it to announce, and then answers the call exactly as the in-process runner used to. There is no
//! in-process fallback left to fall back TO - the code is gone from this binary - so a supervisor that cannot
//! be reached is a NAMED refusal, never a quiet second copy of the work.

use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::Duration;

/// The switch. A node may name a supervisor it started itself (`--rendezvous <file>`); unset means this node
/// spawns one on first use.
/// The supervisor writes this file under the node home and the node reads it: a FILE, never an environment
/// variable (Fable: no env override in product code, ever). `wa-operations-supervisor` defaults its
/// `--rendezvous` to the same path, so the two sides meet without an operator flag.
pub const RENDEZVOUS: &str = "operations-supervisor.json";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// A `foreground` call runs to its own budget (up to 24 h for a build), so the reader must outlast it: the
/// verb's bound is enforced in the supervisor, and a client timeout here would report a running command as
/// unreachable.
const READ_TIMEOUT: Duration = Duration::from_secs(86_400);
const SPAWN_WAIT: Duration = Duration::from_secs(15);

#[derive(Debug, Clone)]
struct Target {
    address: String,
    port: u16,
    token: String,
}

fn environ(name: &str) -> String { std::env::var(name).unwrap_or_default() }

fn home() -> PathBuf {
    PathBuf::from(if environ("HOME").is_empty() { ".".into() } else { environ("HOME") })
}

/// The rendezvous this node uses: the one it was told about, else the one its own supervisor writes.
fn rendezvous_path() -> PathBuf {
    // The file the program writes; absent means the node keeps the work in process (the caller finds out by
    // the same path it always did - it cannot connect). No environment variable decides this.
    home().join(".wasm-agent").join(RENDEZVOUS)
}

fn explicitly_off() -> bool {
    // Nothing in the environment can ask for in-process any more: the file's presence is the only signal, and
    // a caller that cannot reach the program behaves as it always did.
    false
}

fn read_rendezvous(path: &std::path::Path) -> Result<Target, String> {
    let raw = std::fs::read_to_string(path).map_err(|error| format!("read {}: {error}", path.display()))?;
    let value: Value = serde_json::from_str(&raw).map_err(|error| format!("parse {}: {error}", path.display()))?;
    if value["schema"].as_u64() != Some(1) {
        return Err(format!("{}: schema is {}", path.display(), value["schema"]));
    }
    Ok(Target {
        address: value["address"].as_str().unwrap_or_default().to_string(),
        port: value["port"].as_u64().and_then(|port| u16::try_from(port).ok()).unwrap_or(0),
        token: value["token"].as_str().unwrap_or_default().to_string(),
    })
}

/// Where the supervisor program is: beside this binary first (a release ships them together), else PATH.
fn program() -> Option<PathBuf> {
    let name = if cfg!(windows) { "wa-operations-supervisor.exe" } else { "wa-operations-supervisor" };
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let beside = dir.join(name);
            if beside.is_file() { return Some(beside); }
        }
    }
    let path = std::env::var("PATH").ok()?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() { return Some(candidate); }
    }
    None
}

/// Start the supervisor if the rendezvous does not already answer, and answer its target.
fn target() -> Result<Target, String> {
    let path = rendezvous_path();
    if let Ok(existing) = read_rendezvous(&path) {
        if post(&existing, "beat_age", &json!({})).is_ok() {
            return Ok(existing);
        }
        // A stale file: the supervisor it named is gone. Fall through and start a fresh one.
    }
    if explicitly_off() {
        return Err(format!(
            "operations_supervisor_off: the supervisor is disabled and the runner is not in this binary any more ({})",
            path.display()
        ));
    }
    let program = program().ok_or_else(|| "operations_supervisor_missing: wa-operations-supervisor is neither beside this binary nor on PATH".to_string())?;
    if let Some(parent) = path.parent() { let _ = std::fs::create_dir_all(parent); }
    let _ = std::fs::remove_file(&path);
    let mut command = std::process::Command::new(&program);
    // A free port every time: a supervisor started by an earlier node may still be alive (it owns the children
    // that outlived it), and a fixed default would make the new one fail to bind and exit silently.
    command.arg("--port").arg("0");
    command.arg("--rendezvous").arg(&path);
    // Nothing to scrub any more: there is no environment variable, so the child cannot think it is a client
    // of itself. Its rendezvous is the `--rendezvous` argument above, which is the same file both sides read.
    command.stdin(std::process::Stdio::null());
    let log = std::fs::OpenOptions::new().create(true).append(true).open(home().join(".wasm-agent/operations-supervisor.log"));
    match log {
        Ok(file) => {
            let copy = file.try_clone().map_err(|error| error.to_string())?;
            command.stdout(std::process::Stdio::from(file));
            command.stderr(std::process::Stdio::from(copy));
        }
        Err(_) => { command.stdout(std::process::Stdio::null()); command.stderr(std::process::Stdio::null()); }
    }
    command.spawn().map_err(|error| format!("operations_supervisor_spawn: {}: {error}", program.display()))?;
    let deadline = std::time::Instant::now() + SPAWN_WAIT;
    loop {
        if let Ok(started) = read_rendezvous(&path) {
            if post(&started, "beat_age", &json!({})).is_ok() { return Ok(started); }
        }
        if std::time::Instant::now() > deadline {
            return Err(format!("operations_supervisor_unavailable: {} did not announce within {}s", path.display(), SPAWN_WAIT.as_secs()));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn cached_target() -> Result<&'static Target, String> {
    static TARGET: OnceLock<Result<Target, String>> = OnceLock::new();
    match TARGET.get_or_init(target) {
        Ok(target) => Ok(target),
        Err(error) => Err(error.clone()),
    }
}

fn post(target: &Target, verb: &str, args: &Value) -> Result<Value, String> {
    let address: std::net::SocketAddr = format!("{}:{}", target.address, target.port)
        .parse()
        .map_err(|error| format!("address {}: {error}", target.address))?;
    let mut stream = TcpStream::connect_timeout(&address, CONNECT_TIMEOUT).map_err(|error| error.to_string())?;
    stream.set_read_timeout(Some(READ_TIMEOUT)).map_err(|error| error.to_string())?;
    stream.set_write_timeout(Some(CONNECT_TIMEOUT)).map_err(|error| error.to_string())?;
    let body = json!({"schema": 1, "verb": verb, "args": args}).to_string();
    let request = format!(
        "POST /call HTTP/1.1\r\nhost: {}\r\nx-wa-operations-token: {}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
        target.address, target.token, body.len(), body
    );
    stream.write_all(request.as_bytes()).and_then(|_| stream.flush()).map_err(|error| error.to_string())?;
    let mut answer = Vec::new();
    let _ = (&mut stream).take(64 * 1024 * 1024).read_to_end(&mut answer);
    let split = answer.windows(4).position(|window| window == b"\r\n\r\n").ok_or_else(|| "operations_supervisor_no_answer".to_string())?;
    let envelope: Value = serde_json::from_slice(&answer[split + 4..])
        .map_err(|error| format!("operations_supervisor_answer_unreadable: {error}"))?;
    if envelope["ok"].as_bool() == Some(true) {
        return Ok(envelope["value"].clone());
    }
    Err(envelope["error"].as_str().unwrap_or("operations_supervisor_refused").to_string())
}

/// One verb, through the node's supervisor.
pub fn call(verb: &str, args: &Value) -> Result<Value, String> {
    let target = cached_target()?;
    post(target, verb, args)
}

// ---- the surface the node already called, with the same names and the same JSON ------------------------
pub fn control(action: &str, args: &Value, _shell: &(String, String)) -> Result<Value, String> {
    call("control", &json!({"action": action, "args": args}))
}

pub fn foreground(
    program: &str,
    flag: &str,
    command: &str,
    cwd: &str,
    seconds: u64,
    context: &Value,
    stdin: Option<&str>,
) -> Result<Value, String> {
    call("foreground", &json!({"program": program, "flag": flag, "command": command, "cwd": cwd,
                              "seconds": seconds, "context": context, "stdin": stdin}))
}

pub fn health() -> Value {
    call("health", &json!({})).unwrap_or_else(|error| json!([{"error": error}]))
}

pub fn health_scope(session: &str) -> Value { health_scope_for(session, true, "") }

pub fn health_scope_for(session: &str, node_wide: bool, owner: &str) -> Value {
    call("health_scope", &json!({"session": session, "node_wide": node_wide, "owner": owner}))
        .unwrap_or_else(|error| json!({"error": error}))
}

pub fn elsewhere_count(session: &str) -> usize {
    call("elsewhere_count", &json!({"session": session}))
        .ok()
        .and_then(|value| value.as_u64())
        .unwrap_or(0) as usize
}

/// A claimed resource's process, observed by the process that owns it.
pub fn observe_owned_child(id: &str, pid: u32, owner: &str) -> Result<Value, String> {
    call("owned_child", &json!({"id": id, "pid": pid, "owner": owner}))
}

/// The supervisor's own heartbeat, for `/health`'s stall view.
pub fn beat_age_ms() -> Option<u64> {
    call("beat_age", &json!({})).ok().and_then(|value| value["beat_age_ms"].as_u64())
}
