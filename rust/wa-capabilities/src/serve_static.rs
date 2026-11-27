//! The door's STATIC tier as its own program (`ready-serve-own-program.md`, move-list row 8).
//!
//! `serve.rs` is the node's inbound door: listener, admission, ~40 routes that call this process's
//! interpreter, the run worker, the scheduler and the SSE stream. One tier of it needs none of that -
//! the UI file bytes, which `static_reply` answers on the accept thread BEFORE admission. This module
//! is that tier: the two pure functions it is made of (`ui_file`, `content_type`) live here so the guard
//! travels with the bytes, and the program that serves them is `wa serve-static` (this binary in a second
//! mode).
//!
//! WHERE THE RENDEZVOUS COMES FROM, and what it is NOT: not an environment variable. The program writes a
//! fixed file under the node home - `<home>/.wasm-agent/serve-static.json` - and the host reads that
//! same file; nothing in product code is switched by the process environment. Absent, empty, `0` or `off`
//! leaves `static_reply` reading the files itself, byte for byte as before. When the file DOES name a
//! program that cannot answer, the door answers a NAMED refusal (503 + the reason): a node whose asset half
//! is unreachable must not look like a node that simply has no such file.
//!
//! What stays in the host, named and not claimed: `/health`, `/version`, `/log` (they answer from THIS
//! process's own state, so moving them would answer from the wrong process), every route that calls the
//! interpreter, admission, the run worker, the scheduler and the journal.

use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// The program-writable rendezvous under the node home. The program writes it, the host reads it, and no
/// process environment decides anything (Fable: no env override in product code, ever).
pub const RENDEZVOUS: &str = "serve-static.json";
const MAX_ANSWER: u64 = 64 * 1024 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const READ_TIMEOUT: Duration = Duration::from_secs(30);
static SERVING: AtomicBool = AtomicBool::new(false);

/// A path the UI directory may serve, or `None` when the request is not a plain relative path.
///
/// THE GUARD MOVED WITH THE BYTES (serve.rs had it): no `..`, no backslash, no colon, every component
/// `Normal`, and the real path must stay under the UI root. The program runs this same function, so a
/// traversal is refused by the same rule on both paths (proved by the row, not by inspection).
pub(crate) fn ui_file(root: &Path, relative: &str) -> Option<PathBuf> {
    use std::path::Component;
    let candidate = Path::new(relative);
    if relative.contains("..") || relative.contains('\\') || relative.contains(':')
        || !candidate.components().all(|part| matches!(part, Component::Normal(_)))
    {
        return None;
    }
    let file = root.join(candidate);
    match (file.canonicalize(), root.canonicalize()) {
        (Ok(real), Ok(known)) if !real.starts_with(&known) => None,
        _ => Some(file),
    }
}

/// What the bytes ARE, from the path the page asked for. Pure: the host and the program cannot disagree.
pub(crate) fn content_type(path: &str) -> &'static str {
    match path.rsplit('.').next().unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "webmanifest" => "application/manifest+json; charset=utf-8",
        "wasm" => "application/wasm",
        // wa's two faces are served from the ui dir (ui/fonts/), as the .ttf files the installer copies.
        // A font served as application/octet-stream still loads in most browsers, but the type is what
        // the page asked for and a wrong one is a silent cost (no font MIME handling, no cache
        // partitioning by type): the node says what the bytes are.
        "ttf" => "font/ttf",
        "woff2" => "font/woff2",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        _ => "application/octet-stream",
    }
}

/// Where both sides meet: `<home>/.wasm-agent/serve-static.rendezvous`, resolved by the product's own home
/// rule rather than by an environment variable.
pub fn rendezvous_path() -> PathBuf {
    PathBuf::from(wa_host_support::paths::resolve_home()).join(".wasm-agent").join(RENDEZVOUS)
}

/// The rendezvous as a path, or `None` for the in-process default: the FILE is the authority, and its own
/// text carries the rule (`0`, `off`, `in-process` or empty mean the host reads the files itself).
pub fn switch_path() -> Option<PathBuf> {
    let text = std::fs::read_to_string(rendezvous_path()).ok()?;
    switch_from(Some(text.as_str()))
}

/// That rule as a pure function (a test must not touch the filesystem).
fn switch_from(value: Option<&str>) -> Option<PathBuf> {
    let value = value?.trim();
    if value.is_empty() || value == "0" || value == "off" || value == "in-process" {
        return None;
    }
    Some(PathBuf::from(value))
}

fn token() -> Result<String, String> {
    use ring::rand::{SecureRandom, SystemRandom};
    let mut bytes = [0u8; 32];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| "serve_static_token_unavailable".to_string())?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn write_rendezvous(path: &Path, value: &Value) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("serve_static_root: {}: {error}", parent.display()))?;
        }
    }
    let temp = path.with_extension("json.tmp");
    std::fs::write(&temp, value.to_string())
        .map_err(|error| format!("serve_static_rendezvous: {}: {error}", temp.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&temp, path)
        .map_err(|error| format!("serve_static_rendezvous: {}: {error}", path.display()))
}

#[derive(Debug, Clone)]
struct Target {
    address: String,
    port: u16,
    token: String,
}

fn read_rendezvous(path: &Path) -> Result<Target, String> {
    let raw = std::fs::read_to_string(path)
        .map_err(|error| format!("read {}: {error}", path.display()))?;
    let value: Value =
        serde_json::from_str(&raw).map_err(|error| format!("parse {}: {error}", path.display()))?;
    if value["schema"].as_u64() != Some(1) {
        return Err(format!("{}: schema is {}", path.display(), value["schema"]));
    }
    Ok(Target {
        address: value["address"].as_str().unwrap_or_default().to_string(),
        port: value["port"].as_u64().and_then(|port| u16::try_from(port).ok()).unwrap_or(0),
        token: value["token"].as_str().unwrap_or_default().to_string(),
    })
}

/// Serve the UI directory until the listener ends. Blocks.
pub fn serve(root: PathBuf, port: u16, rendezvous: PathBuf) -> Result<(), String> {
    if !root.is_dir() {
        return Err(format!("serve_static_root_not_a_directory: {}", root.display()));
    }
    if let Ok(existing) = read_rendezvous(&rendezvous) {
        if probe(&existing).is_ok() {
            return Err(format!(
                "serve_static_already_running: {} answers at {}:{}",
                rendezvous.display(),
                existing.address,
                existing.port
            ));
        }
    }
    let address = crate::serve::bind_address();
    let listener = TcpListener::bind((address.as_str(), port))
        .map_err(|error| format!("serve_static_bind: {address}:{port}: {error}"))?;
    let local = listener.local_addr().map_err(|error| format!("serve_static_bind: {error}"))?;
    let token = token()?;
    write_rendezvous(
        &rendezvous,
        &json!({
            "schema": 1,
            "address": local.ip().to_string(),
            "port": local.port(),
            "token": token,
            "pid": std::process::id(),
            "root": root.to_string_lossy(),
        }),
    )?;
    eprintln!(
        "[serve-static] serving {} on {}:{} pid {} rendezvous {}",
        root.display(),
        local.ip(),
        local.port(),
        std::process::id(),
        rendezvous.display()
    );
    SERVING.store(true, Ordering::SeqCst);
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let token = token.clone();
        let root = root.clone();
        std::thread::spawn(move || {
            let mut stream = stream;
            let _ = handle(&mut stream, &root, &token);
        });
    }
    Ok(())
}

fn handle(stream: &mut TcpStream, root: &Path, token: &str) -> Result<(), String> {
    let (head, body) = request_parts(stream)?;
    let mut lines = head.lines();
    let request_line = lines.next().unwrap_or("");
    let mut words = request_line.split(' ');
    let method = words.next().unwrap_or("");
    let route = words.next().unwrap_or("");
    let mut supplied = String::new();
    for line in lines {
        let Some((name, value)) = line.split_once(':') else { continue };
        if name.trim().eq_ignore_ascii_case("x-wa-static-token") {
            supplied = value.trim().to_string();
        }
    }
    if method != "POST" || route != "/static" {
        return reply(stream, 404, &[], None);
    }
    if ring::constant_time::verify_slices_are_equal(supplied.as_bytes(), token.as_bytes()).is_err() {
        return reply_json(stream, 403, json!({"error": "serve_static_token_required"}));
    }
    let request: Value = match serde_json::from_slice(&body) {
        Ok(request) => request,
        Err(error) => return reply_json(stream, 400, json!({"error": format!("serve_static_request_unreadable: {error}")})),
    };
    let relative = request["path"].as_str().unwrap_or("");
    let Some(file) = ui_file(root, relative) else {
        // The same answer the host gives on the in-process path (`bad path`, text/plain).
        return reply(stream, 400, b"bad path", Some("text/plain"));
    };
    match std::fs::read(&file) {
        Ok(bytes) => reply(stream, 200, &bytes, Some(content_type(relative))),
        // NOT MINE: the host asks its agent thread, exactly as it does when the file is absent today.
        Err(_) => reply(stream, 404, b"", Some("x-wa-not-mine")),
    }
}

fn reply(stream: &mut TcpStream, status: u16, body: &[u8], content_type: Option<&str>) -> Result<(), String> {
    let head = format!(
        "HTTP/1.1 {status} X\r\ncontent-type: {}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
        content_type.unwrap_or("application/octet-stream"),
        body.len()
    );
    stream
        .write_all(head.as_bytes())
        .and_then(|_| stream.write_all(body))
        .and_then(|_| stream.flush())
        .map_err(|error| error.to_string())
}

fn reply_json(stream: &mut TcpStream, status: u16, body: Value) -> Result<(), String> {
    reply(stream, status, body.to_string().as_bytes(), Some("application/json"))
}

fn request_parts(stream: &mut TcpStream) -> Result<(String, Vec<u8>), String> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        if let Some(index) = buffer.windows(4).position(|window| window == b"\r\n\r\n") {
            break index;
        }
        if buffer.len() > 16 * 1024 {
            return Err("serve_static_head_too_long".into());
        }
        let read = stream.read(&mut chunk).map_err(|error| error.to_string())?;
        if read == 0 {
            return Err("serve_static_no_request".into());
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

/// The host side: the bytes of `relative`, when a static program is configured.
///
/// `None` means "no program is configured" and the caller keeps its own path, byte for byte. `Ok(None)`
/// means the program does not hold this path, so the caller falls through to its agent thread as today.
/// `Err` is a named refusal: the caller answers it rather than quietly reading the file itself.
pub fn fetch(relative: &str) -> Option<Result<Option<(u16, Vec<u8>)>, String>> {
    if SERVING.load(Ordering::SeqCst) {
        return None;
    }
    let path = switch_path()?;
    Some(fetch_from(&path, relative))
}

/// The bytes of `relative` from the program whose rendezvous is `path`.
pub fn fetch_from(path: &Path, relative: &str) -> Result<Option<(u16, Vec<u8>)>, String> {
    let target = read_rendezvous(path).map_err(|error| format!("serve_static_unavailable: {error}"))?;
    let body = json!({"schema": 1, "path": relative}).to_string();
    let (status, content_type, bytes) = post(&target, &body)
        .map_err(|error| format!("serve_static_unreachable: {}:{}: {error}", target.address, target.port))?;
    match status {
        // The program's own answer, carried through with its status: a refusal that arrived as 400 must
        // leave as 400, or the door would answer 200 with the word "bad path" inside.
        200 | 400 => Ok(Some((status, bytes))),
        // The one answer that is not an answer: the host's route table decides.
        404 if content_type == "x-wa-not-mine" => Ok(None),
        other => Err(format!("serve_static_answered_{other}")),
    }
}

fn probe(target: &Target) -> Result<(), String> {
    let body = json!({"schema": 1, "path": ""}).to_string();
    post(target, &body).map(|_| ())
}

fn post(target: &Target, body: &str) -> Result<(u16, String, Vec<u8>), String> {
    let address: std::net::SocketAddr = format!("{}:{}", target.address, target.port)
        .parse()
        .map_err(|error| format!("address {}: {error}", target.address))?;
    let mut stream = TcpStream::connect_timeout(&address, CONNECT_TIMEOUT).map_err(|error| error.to_string())?;
    stream.set_read_timeout(Some(READ_TIMEOUT)).map_err(|error| error.to_string())?;
    stream.set_write_timeout(Some(CONNECT_TIMEOUT)).map_err(|error| error.to_string())?;
    let request = format!(
        "POST /static HTTP/1.1\r\nhost: {}\r\nx-wa-static-token: {}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
        target.address,
        target.token,
        body.len(),
        body
    );
    stream.write_all(request.as_bytes()).and_then(|_| stream.flush()).map_err(|error| error.to_string())?;
    let mut answer = Vec::new();
    let _ = (&mut stream).take(MAX_ANSWER).read_to_end(&mut answer);
    let split = answer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .ok_or_else(|| "serve_static_no_answer".to_string())?;
    let head = String::from_utf8_lossy(&answer[..split]).to_string();
    let status = head
        .lines()
        .next()
        .and_then(|line| line.split(' ').nth(1))
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or_else(|| "serve_static_answer_unreadable".to_string())?;
    let content_type = head
        .lines()
        .filter_map(|line| line.split_once(':'))
        .find(|(name, _)| name.trim().eq_ignore_ascii_case("content-type"))
        .map(|(_, value)| value.trim().to_string())
        .unwrap_or_default();
    Ok((status, content_type, answer[split + 4..].to_vec()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("wa-serve-static-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("assets")).expect("scratch root");
        std::fs::write(dir.join("index.html"), b"<html>node</html>").expect("index");
        std::fs::write(dir.join("assets").join("app.css"), b"body{color:#fff}").expect("css");
        dir
    }

    fn started(root: PathBuf) -> Target {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind");
        let local = listener.local_addr().expect("local address");
        let token = "0123456789abcdef0123456789abcdef".to_string();
        let held = token.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { continue };
                let token = held.clone();
                let root = root.clone();
                std::thread::spawn(move || {
                    let mut stream = stream;
                    let _ = handle(&mut stream, &root, &token);
                });
            }
        });
        Target { address: local.ip().to_string(), port: local.port(), token }
    }

    #[test]
    fn the_guard_refuses_a_traversal_on_the_wire_as_it_does_in_process() {
        let root = scratch("guard");
        assert!(ui_file(&root, "index.html").is_some());
        for bad in ["../etc/passwd", "assets/../../etc/passwd", "..\\windows", "c:/x", "/etc/passwd"] {
            assert!(ui_file(&root, bad).is_none(), "{bad} must be refused");
        }
        let target = started(root.clone());
        let (status, content_type, bytes) = post(&target, &json!({"schema": 1, "path": "../etc/passwd"}).to_string())
            .expect("answer");
        assert_eq!(status, 400);
        assert_eq!(content_type, "text/plain");
        assert_eq!(bytes, b"bad path".to_vec());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_bytes_come_from_the_program_and_a_missing_path_is_not_mine() {
        let root = scratch("bytes");
        let target = started(root.clone());
        let (status, content_type, bytes) = post(&target, &json!({"schema": 1, "path": "assets/app.css"}).to_string())
            .expect("answer");
        assert_eq!(status, 200);
        assert_eq!(content_type, content_type_of("assets/app.css"));
        assert_eq!(bytes, b"body{color:#fff}".to_vec());
        let (status, content_type, _) = post(&target, &json!({"schema": 1, "path": "nope.js"}).to_string())
            .expect("answer");
        assert_eq!((status, content_type.as_str()), (404, "x-wa-not-mine"));
        let _ = std::fs::remove_dir_all(&root);
    }

    fn content_type_of(path: &str) -> String {
        content_type(path).to_string()
    }

    #[test]
    fn a_wrong_token_is_refused_before_any_file_is_read() {
        let root = scratch("token");
        let target = started(root.clone());
        let wrong = Target { token: "not-the-token".into(), ..target };
        let error = fetch_to(&wrong, "index.html").expect_err("refused");
        assert_eq!(error, "serve_static_answered_403");
        let _ = std::fs::remove_dir_all(&root);
    }

    fn fetch_to(target: &Target, relative: &str) -> Result<Option<(u16, Vec<u8>)>, String> {
        let (status, content_type, bytes) = post(target, &json!({"schema": 1, "path": relative}).to_string())?;
        Ok(match status {
            200 | 400 => Some((status, bytes)),
            404 if content_type == "x-wa-not-mine" => None,
            other => return Err(format!("serve_static_answered_{other}")),
        })
    }

    #[test]
    fn the_switch_reads_off_as_in_process() {
        for value in [None, Some(""), Some("off"), Some("in-process")] {
            assert_eq!(switch_from(value), None, "{value:?} must mean the host reads the files");
        }
        assert_eq!(switch_from(Some(" /tmp/s.json ")), Some(PathBuf::from("/tmp/s.json")));
    }
}
