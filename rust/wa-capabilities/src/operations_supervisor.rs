//! Slice 1 of "the process runner is its own program" (`ready-operations-own-program.md`).
//!
//! The supervisor is this same binary in a second mode (`wa operations-supervisor`). It hosts the
//! operations surface (`operations::control`) over a loopback socket, so a supervised child's process
//! group belongs to a process the node's interpreter is not in: restarting the node does not take the
//! children with it, and cancelling one is a request to the process that holds it.
//!
//! THE SWITCH, and its default: `WASM_AGENT_OPERATIONS_SUPERVISOR` names the rendezvous file a supervisor
//! wrote (`{"schema":1,"address":..,"port":..,"token":..,"pid":..,"owner_boot":..}`). Unset - what every
//! node runs today - means in-process, and no function here is on the path at all. When the switch DOES
//! name a supervisor that cannot answer, the answer is a NAMED refusal, never a quiet fall-back to a
//! second copy of the work in another process.
//!
//! What still lives in the node (named here, not claimed): `foreground` (`bash`, `host.exec`), `health()`
//! and the node-wide listing read the node's own manager, so in supervisor mode they do not see the
//! children the supervisor holds. Slice 2 (`ready-operations-own-program.md` §2.1) moves `operations.rs`
//! into the supervisor's own crate and gives those one owner.

use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// The switch. The value is the path of the supervisor's rendezvous file; unset means in-process.
pub const SWITCH: &str = "WASM_AGENT_OPERATIONS_SUPERVISOR";
/// A supervisor answers one request per connection on its own thread; this is how many peers may be in
/// flight before one is told `too_many_connections` instead of the process running out of threads.
const MAX_CONNECTIONS: usize = 32;
const HEAD_LIMIT: usize = 16 * 1024;
const BODY_LIMIT: usize = 8 * 1024 * 1024;
const ANSWER_LIMIT: u64 = 32 * 1024 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// `await` blocks for up to `CONTROL_MAX_SECONDS` (60 s) inside `wa-operation`; a reader that gave up
/// sooner than the verb's own bound would report a settled operation as unreachable.
const READ_TIMEOUT: Duration = Duration::from_secs(300);
static SERVING: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone)]
struct Target {
    address: String,
    port: u16,
    token: String,
}

/// The switch's value as a path, or `None` for the in-process default.
///
/// `0`, `off` and `in-process` are read as "off" rather than as a file name that cannot be read: a policy
/// that turns the feature off must not leave every operation refused as `unavailable`.
pub fn switch_path() -> Option<PathBuf> {
    switch_from(std::env::var(SWITCH).ok().as_deref())
}

/// The switch's rule, split out so it is a pure function this module can test without mutating the
/// process environment (a test that sets SWITCH would race every other test in the binary that asks
/// `control` what to do).
fn switch_from(value: Option<&str>) -> Option<PathBuf> {
    let value = value?.trim();
    if value.is_empty() || value == "0" || value == "off" || value == "in-process" {
        return None;
    }
    Some(PathBuf::from(value))
}

fn random_token() -> Result<String, String> {
    use ring::rand::{SecureRandom, SystemRandom};
    let mut bytes = [0u8; 32];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| "operations_supervisor_token_unavailable".to_string())?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn write_rendezvous(path: &Path, value: &Value) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("operations_supervisor_root: {}: {error}", parent.display()))?;
        }
    }
    let temp = path.with_extension("json.tmp");
    std::fs::write(&temp, value.to_string())
        .map_err(|error| format!("operations_supervisor_rendezvous: {}: {error}", temp.display()))?;
    // The token in this file is the authority to start a process on this node: 0600, and replaced by
    // rename so a reader never sees half of it.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&temp, path)
        .map_err(|error| format!("operations_supervisor_rendezvous: {}: {error}", path.display()))
}

fn read_rendezvous(path: &Path) -> Result<Target, String> {
    let raw = std::fs::read_to_string(path)
        .map_err(|error| format!("read {}: {error}", path.display()))?;
    let value: Value =
        serde_json::from_str(&raw).map_err(|error| format!("parse {}: {error}", path.display()))?;
    if value["schema"].as_u64() != Some(1) {
        return Err(format!("{}: schema is {}", path.display(), value["schema"]));
    }
    let address = value["address"]
        .as_str()
        .filter(|address| !address.is_empty())
        .ok_or_else(|| format!("{}: address is missing", path.display()))?
        .to_string();
    let port = value["port"]
        .as_u64()
        .and_then(|port| u16::try_from(port).ok())
        .ok_or_else(|| format!("{}: port is missing", path.display()))?;
    let token = value["token"]
        .as_str()
        .filter(|token| !token.is_empty())
        .ok_or_else(|| format!("{}: token is missing", path.display()))?
        .to_string();
    Ok(Target { address, port, token })
}

fn envelope(result: Result<Value, String>) -> Value {
    match result {
        Ok(value) => json!({"schema": 1, "ok": true, "value": value}),
        Err(error) => json!({"schema": 1, "ok": false, "error": error}),
    }
}

/// Serve until the listener ends. Blocks.
pub fn serve(rendezvous: PathBuf, port: u16) -> Result<(), String> {
    // ONE SUPERVISOR PER MACHINE, checked before the bind: two supervisors are two owners of the same
    // ledger, and a second one would answer a `status` for an id it never started. A stale file (a
    // supervisor that was killed) is overwritten only when the address it names does not answer.
    if let Ok(existing) = read_rendezvous(&rendezvous) {
        if call(&existing, "identity", &json!({})).is_ok() {
            return Err(format!(
                "operations_supervisor_already_running: {} answers at {}:{}",
                rendezvous.display(),
                existing.address,
                existing.port
            ));
        }
    }
    let address = crate::serve::bind_address();
    let listener = TcpListener::bind((address.as_str(), port))
        .map_err(|error| format!("operations_supervisor_bind: {address}:{port}: {error}"))?;
    let local = listener
        .local_addr()
        .map_err(|error| format!("operations_supervisor_bind: {error}"))?;
    // The ledger is opened (and its boot id taken) BEFORE the socket accepts, so a supervisor that cannot
    // write the node's own state root refuses at startup instead of at the first `start`.
    let boot = crate::operations::manager()
        .identity()
        .map_err(|error| format!("operations_supervisor_ledger: {error}"))?["owner_boot"]
        .clone();
    let token = random_token()?;
    write_rendezvous(
        &rendezvous,
        &json!({
            "schema": 1,
            "address": local.ip().to_string(),
            "port": local.port(),
            "token": token,
            "pid": std::process::id(),
            "owner_boot": boot,
        }),
    )?;
    eprintln!(
        "[operations-supervisor] listening on {}:{} pid {} rendezvous {}",
        local.ip(),
        local.port(),
        std::process::id(),
        rendezvous.display()
    );
    // From here on this process IS the supervisor: a forwarded verb must run here, not travel back out.
    SERVING.store(true, Ordering::SeqCst);
    accept(listener, token);
    Ok(())
}

fn accept(listener: TcpListener, token: String) {
    let live = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        if live.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
            live.fetch_sub(1, Ordering::SeqCst);
            let mut refused = stream;
            let _ = reply(&mut refused, 503, &json!({"schema": 1, "ok": false, "error": "operations_supervisor_too_many_connections"}));
            continue;
        }
        let token = token.clone();
        let live = live.clone();
        std::thread::spawn(move || {
            let mut stream = stream;
            let _ = handle(&mut stream, &token);
            live.fetch_sub(1, Ordering::SeqCst);
        });
    }
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
    if method != "POST" {
        return reply(stream, 405, &json!({"schema": 1, "ok": false, "error": "operations_supervisor_post_only"}));
    }
    if route != "/control" {
        return reply(stream, 404, &json!({"schema": 1, "ok": false, "error": "operations_supervisor_unknown_route"}));
    }
    // The token is the authority to start a process on this node. Checked before the verb is read, so a
    // caller without it learns nothing about which verbs exist or what they would have answered.
    if ring::constant_time::verify_slices_are_equal(supplied.as_bytes(), token.as_bytes()).is_err() {
        return reply(stream, 403, &json!({"schema": 1, "ok": false, "error": "operations_supervisor_token_required"}));
    }
    let request: Value = match serde_json::from_slice(&body) {
        Ok(request) => request,
        Err(error) => {
            return reply(
                stream,
                400,
                &json!({"schema": 1, "ok": false, "error": format!("operations_supervisor_request_unreadable: {error}")}),
            );
        }
    };
    let action = request["action"].as_str().unwrap_or("").to_string();
    let args = request.get("args").cloned().unwrap_or(Value::Null);
    let answer = crate::operations::control(&action, &args, crate::host::shell_config());
    reply(stream, 200, &envelope(answer))
}

fn reply(stream: &mut TcpStream, status: u16, body: &Value) -> Result<(), String> {
    let text = body.to_string();
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
        text.len(),
        reason = if status == 200 { "OK" } else { "Refused" }
    );
    stream
        .write_all(head.as_bytes())
        .and_then(|_| stream.write_all(text.as_bytes()))
        .and_then(|_| stream.flush())
        .map_err(|error| error.to_string())
}

fn request_parts(stream: &mut TcpStream) -> Result<(String, Vec<u8>), String> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        if let Some(index) = buffer.windows(4).position(|window| window == b"\r\n\r\n") {
            break index;
        }
        if buffer.len() > HEAD_LIMIT {
            return Err("operations_supervisor_head_too_long".into());
        }
        let read = stream.read(&mut chunk).map_err(|error| error.to_string())?;
        if read == 0 {
            return Err("operations_supervisor_no_request".into());
        }
        buffer.extend_from_slice(&chunk[..read]);
    };
    let head = String::from_utf8_lossy(&buffer[..head_end]).to_string();
    let length = head
        .lines()
        .filter_map(|line| line.split_once(':'))
        .find(|(name, _)| name.trim().eq_ignore_ascii_case("content-length"))
        .and_then(|(_, value)| value.trim().parse::<usize>().ok())
        .unwrap_or(0);
    if length > BODY_LIMIT {
        return Err("operations_supervisor_body_too_large".into());
    }
    let mut body = buffer[head_end + 4..].to_vec();
    while body.len() < length {
        let read = stream.read(&mut chunk).map_err(|error| error.to_string())?;
        if read == 0 {
            break;
        }
        body.extend_from_slice(&chunk[..read]);
    }
    Ok((head, body))
}

/// The host side: answer `action` through the supervisor when the switch names one.
///
/// `None` means "no supervisor is configured": the caller keeps its own path, byte for byte. `Some` is the
/// answer, including the named refusal when the supervisor cannot be reached.
pub fn forward(action: &str, args: &Value) -> Option<Result<Value, String>> {
    if SERVING.load(Ordering::SeqCst) {
        return None;
    }
    let path = switch_path()?;
    Some(forward_to(&path, action, args))
}

/// Answer `action` through the supervisor whose rendezvous is `path`.
pub fn forward_to(path: &Path, action: &str, args: &Value) -> Result<Value, String> {
    let target = read_rendezvous(path)
        .map_err(|error| format!("operations_supervisor_unavailable: {error}"))?;
    call(&target, action, args).map_err(|error| {
        format!(
            "operations_supervisor_unreachable: {}:{}: {error}",
            target.address, target.port
        )
    })
}

fn call(target: &Target, action: &str, args: &Value) -> Result<Value, String> {
    let body = json!({"schema": 1, "action": action, "args": args}).to_string();
    let answer = post(target, &body)?;
    let envelope: Value = serde_json::from_str(&answer).map_err(|error| {
        let head: String = answer.chars().take(200).collect();
        format!("answer_unreadable: {error}: {head}")
    })?;
    if envelope["ok"].as_bool() == Some(true) {
        return Ok(envelope["value"].clone());
    }
    Err(envelope["error"]
        .as_str()
        .unwrap_or("operations_supervisor_refused")
        .to_string())
}

fn post(target: &Target, body: &str) -> Result<String, String> {
    let address: std::net::SocketAddr = format!("{}:{}", target.address, target.port)
        .parse()
        .map_err(|error| format!("address {}: {error}", target.address))?;
    let mut stream =
        TcpStream::connect_timeout(&address, CONNECT_TIMEOUT).map_err(|error| error.to_string())?;
    stream
        .set_read_timeout(Some(READ_TIMEOUT))
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(Some(CONNECT_TIMEOUT))
        .map_err(|error| error.to_string())?;
    let request = format!(
        "POST /control HTTP/1.1\r\nhost: {}\r\nx-wa-operations-token: {}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
        target.address,
        target.token,
        body.len(),
        body
    );
    stream
        .write_all(request.as_bytes())
        .and_then(|_| stream.flush())
        .map_err(|error| error.to_string())?;
    let mut answer = Vec::new();
    // `connection: close` means end-of-stream IS the end of the answer; the cap keeps a misbehaving peer
    // from growing this buffer without bound.
    let _ = (&mut stream).take(ANSWER_LIMIT).read_to_end(&mut answer);
    let text = String::from_utf8_lossy(&answer).to_string();
    let split = text.find("\r\n\r\n").ok_or_else(|| "no_answer".to_string())?;
    let status_ok = text.starts_with("HTTP/1.1 200");
    let body = text[split + 4..].to_string();
    if !status_ok {
        // A refusal with a body still carries its reason; one without is answered by the status line.
        if let Ok(envelope) = serde_json::from_str::<Value>(&body) {
            if let Some(error) = envelope["error"].as_str() {
                return Err(error.to_string());
            }
        }
        return Err(text.lines().next().unwrap_or("refused").to_string());
    }
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A real listener on a real loopback port, answering with a known token. Nothing here writes the
    /// node's ledger: every verb used below is refused before the manager is asked anything.
    fn started() -> Target {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind");
        let local = listener.local_addr().expect("local address");
        let token = "0123456789abcdef0123456789abcdef".to_string();
        let held = token.clone();
        std::thread::spawn(move || accept(listener, held));
        Target { address: local.ip().to_string(), port: local.port(), token }
    }

    #[test]
    fn a_refusal_crosses_the_socket_as_the_same_named_error() {
        let target = started();
        let direct = crate::operations::control("start", &json!({}), crate::host::shell_config());
        let wired = call(&target, "start", &json!({})).expect_err("a start with no command is refused");
        let direct = direct.expect_err("a start with no command is refused, in-process too");
        assert_eq!(wired, direct, "the wire must not rename or reshape a refusal");
        assert_eq!(wired, "command_required");
    }

    #[test]
    fn an_unknown_verb_answers_the_same_named_error_across_the_wire() {
        let target = started();
        let direct = crate::operations::control("walk", &json!({}), crate::host::shell_config())
            .expect_err("an unknown verb is refused");
        let wired = call(&target, "walk", &json!({})).expect_err("an unknown verb is refused");
        assert_eq!(wired, direct);
    }

    #[test]
    fn a_wrong_token_is_refused_before_the_verb_is_read() {
        let target = started();
        let wrong = Target { token: "not-the-token".into(), ..target };
        let error = call(&wrong, "start", &json!({"command": "true"})).expect_err("refused");
        assert_eq!(error, "operations_supervisor_token_required");
    }

    #[test]
    fn a_rendezvous_file_round_trips_and_a_missing_one_is_a_named_refusal() {
        let dir = std::env::temp_dir().join(format!("wa-operations-supervisor-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let path = dir.join("rendezvous.json");
        write_rendezvous(&path, &json!({"schema": 1, "address": "127.0.0.1", "port": 8791, "token": "ab", "pid": 1})).expect("write");
        let target = read_rendezvous(&path).expect("read");
        assert_eq!((target.address.as_str(), target.port, target.token.as_str()), ("127.0.0.1", 8791, "ab"));
        // The default is in-process: an unset switch is not a supervisor.
        let missing = dir.join("nothing-here.json");
        let error = forward_to(&missing, "identity", &json!({})).expect_err("refused");
        assert!(error.starts_with("operations_supervisor_unavailable"), "{error}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_switch_reads_off_as_in_process() {
        for value in [None, Some(""), Some("  "), Some("0"), Some("off"), Some("in-process")] {
            assert_eq!(switch_from(value), None, "{value:?} must mean in-process");
        }
        assert_eq!(switch_from(Some(" /tmp/rendezvous.json ")), Some(PathBuf::from("/tmp/rendezvous.json")));
    }
}
