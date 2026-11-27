//! The supervisor's own endpoint: one route, the same envelope the node already speaks.
//!
//! Slice 1 established the wire (`POST /control`, a token in a 0600 rendezvous file, an `{ok,value|error}`
//! envelope). This is the same shape with one table of verbs (`facts::call`), because the node will ask this
//! process for more than the control verbs: the foreground path (`bash`), its health view, and one owned child.
//! The node SPAWNS this program, so no operator step is added to a node that has never named one.

use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

const MAX_CONNECTIONS: usize = 32;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const READ_TIMEOUT: Duration = Duration::from_secs(300);

fn token() -> Result<String, String> {
    use ring::rand::{SecureRandom, SystemRandom};
    let mut bytes = [0u8; 32];
    SystemRandom::new().fill(&mut bytes).map_err(|_| "operations_supervisor_token_unavailable".to_string())?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn write_rendezvous(path: &Path, value: &Value) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).map_err(|error| format!("operations_supervisor_root: {}: {error}", parent.display()))?;
        }
    }
    let temp = path.with_extension("json.tmp");
    std::fs::write(&temp, value.to_string()).map_err(|error| format!("operations_supervisor_rendezvous: {}: {error}", temp.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&temp, path).map_err(|error| format!("operations_supervisor_rendezvous: {}: {error}", path.display()))
}

/// Serve until the listener ends. Blocks.
pub fn serve(rendezvous: PathBuf, port: u16) -> Result<(), String> {
    // The ledger is opened (and its boot taken) before the socket accepts: a supervisor that cannot write the
    // state root must refuse at startup, not at the first `start`.
    let boot = wa_operations_runner::operations::manager()
        .identity()
        .map_err(|error| format!("operations_supervisor_ledger: {error}"))?["owner_boot"]
        .clone();
    let address = std::env::var("WASM_AGENT_BIND").ok().filter(|value| !value.is_empty()).unwrap_or_else(|| "127.0.0.1".to_string());
    let listener = TcpListener::bind((address.as_str(), port))
        .map_err(|error| format!("operations_supervisor_bind: {address}:{port}: {error}"))?;
    let local = listener.local_addr().map_err(|error| format!("operations_supervisor_bind: {error}"))?;
    let token = token()?;
    write_rendezvous(
        &rendezvous,
        &json!({"schema": 1, "address": local.ip().to_string(), "port": local.port(), "token": token,
                "pid": std::process::id(), "owner_boot": boot}),
    )?;
    eprintln!("[operations-supervisor] listening on {}:{} pid {} rendezvous {}", local.ip(), local.port(), std::process::id(), rendezvous.display());
    let live = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        if live.fetch_add(1, std::sync::atomic::Ordering::SeqCst) >= MAX_CONNECTIONS {
            live.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            let mut refused = stream;
            let _ = reply(&mut refused, 503, &json!({"schema": 1, "ok": false, "error": "operations_supervisor_too_many_connections"}));
            continue;
        }
        let token = token.clone();
        let live = live.clone();
        std::thread::spawn(move || {
            let mut stream = stream;
            let _ = handle(&mut stream, &token);
            live.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
        });
    }
    Ok(())
}

fn handle(stream: &mut TcpStream, token: &str) -> Result<(), String> {
    let (head, body) = request_parts(stream)?;
    let mut lines = head.lines();
    let request_line = lines.next().unwrap_or("");
    let mut words = request_line.split(' ');
    let method = words.next().unwrap_or("");
    let route = words.next().unwrap_or("");
    let mut supplied = String::new();
    for line in lines {
        let Some((name, value)) = line.split_once(':') else { continue };
        if name.trim().eq_ignore_ascii_case("x-wa-operations-token") {
            supplied = value.trim().to_string();
        }
    }
    if method != "POST" { return reply(stream, 405, &json!({"ok": false, "error": "operations_supervisor_post_only"})); }
    if route != "/call" && route != "/control" { return reply(stream, 404, &json!({"ok": false, "error": "operations_supervisor_unknown_route"})); }
    if ring::constant_time::verify_slices_are_equal(supplied.as_bytes(), token.as_bytes()).is_err() {
        return reply(stream, 403, &json!({"ok": false, "error": "operations_supervisor_token_required"}));
    }
    let request: Value = match serde_json::from_slice(&body) {
        Ok(request) => request,
        Err(error) => return reply(stream, 400, &json!({"ok": false, "error": format!("operations_supervisor_request_unreadable: {error}")})),
    };
    // Slice 1's shape (action/args) and this table's shape (verb/args) are the same request; the old route keeps
    // working so a node built from slice 1 can talk to this program unchanged.
    let verb = request["verb"].as_str().or_else(|| request["action"].as_str()).unwrap_or("").to_string();
    let args = if request.get("verb").is_some() { request.get("args").cloned().unwrap_or(Value::Null) }
               else { json!({"action": request["action"].clone(), "args": request.get("args").cloned().unwrap_or(Value::Null)}) };
    let answer = crate::facts::call(&verb, &args);
    let envelope = match answer {
        Ok(value) => json!({"schema": 1, "ok": true, "value": value}),
        Err(error) => json!({"schema": 1, "ok": false, "error": error}),
    };
    reply(stream, 200, &envelope)
}

fn reply(stream: &mut TcpStream, status: u16, body: &Value) -> Result<(), String> {
    let text = body.to_string();
    let head = format!("HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n", text.len());
    stream.write_all(head.as_bytes()).and_then(|_| stream.write_all(text.as_bytes())).and_then(|_| stream.flush()).map_err(|error| error.to_string())
}

fn request_parts(stream: &mut TcpStream) -> Result<(String, Vec<u8>), String> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        if let Some(index) = buffer.windows(4).position(|window| window == b"\r\n\r\n") { break index; }
        if buffer.len() > 16 * 1024 { return Err("operations_supervisor_head_too_long".into()); }
        let read = stream.read(&mut chunk).map_err(|error| error.to_string())?;
        if read == 0 { return Err("operations_supervisor_no_request".into()); }
        buffer.extend_from_slice(&chunk[..read]);
    };
    let head = String::from_utf8_lossy(&buffer[..head_end]).to_string();
    let length = head.lines().filter_map(|line| line.split_once(':'))
        .find(|(name, _)| name.trim().eq_ignore_ascii_case("content-length"))
        .and_then(|(_, value)| value.trim().parse::<usize>().ok()).unwrap_or(0);
    let mut body = buffer[head_end + 4..].to_vec();
    while body.len() < length {
        let read = stream.read(&mut chunk).map_err(|error| error.to_string())?;
        if read == 0 { break; }
        body.extend_from_slice(&chunk[..read]);
    }
    Ok((head, body))
}

/// Kept for the node's client: the timeout a caller should allow a blocking verb (a `foreground` call can run to
/// its own budget), so a reader that gave up early never reports a running operation as unreachable.
pub const CLIENT_READ_TIMEOUT: Duration = READ_TIMEOUT;
#[allow(dead_code)]
const _CONNECT: Duration = CONNECT_TIMEOUT;
