//! Tiny local web UI: serves the chat window and forwards messages to Lua.
//!
//! Deliberately single-threaded: the Lua state is not thread-safe, so requests
//! are handled one at a time on the main thread. `ui/` files are read fresh on
//! every request, and `/version` changes when they do, so the browser can hot
//! reload while the UI is being edited.
use crate::lua::Lua;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::Mutex;

/// The one open SSE client (the server is single-threaded, so one is enough).
static CLIENT: Mutex<Option<TcpStream>> = Mutex::new(None);

/// Push one event to the streaming client, if any. Called from Lua via host.stream.
pub fn write_event(payload: &str) {
    if let Ok(mut guard) = CLIENT.lock() {
        if let Some(socket) = guard.as_mut() {
            let _ = socket.write_all(format!("data: {payload}\n\n").as_bytes());
            let _ = socket.flush();
        }
    }
}

pub fn run(lua: &Lua, port: u16, ui: PathBuf) {
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("[serve] bind 127.0.0.1:{port} failed: {error}");
            return;
        }
    };
    eprintln!("[serve] wasm-agent UI at http://127.0.0.1:{port}  (ui: {})", ui.display());
    for stream in listener.incoming() {
        if let Ok(mut stream) = stream {
            let _ = handle(lua, &ui, &mut stream);
        }
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

fn handle(lua: &Lua, ui: &std::path::Path, stream: &mut TcpStream) -> std::io::Result<()> {
    let mut data = Vec::new();
    let mut chunk = [0u8; 16384];
    let (method, path, body) = loop {
        let read = stream.read(&mut chunk)?;
        if read == 0 {
            return Ok(());
        }
        data.extend_from_slice(&chunk[..read]);
        if let Some(end) = find(&data, b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&data[..end]).to_string();
            let mut lines = head.lines();
            let mut request = lines.next().unwrap_or("").split_whitespace();
            let method = request.next().unwrap_or("").to_string();
            let path = request.next().unwrap_or("/").to_string();
            let length = lines
                .filter_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .map(|value| value.trim().parse::<usize>().unwrap_or(0))
                })
                .next()
                .unwrap_or(0);
            if data.len() >= end + 4 + length {
                break (method, path, data[end + 4..end + 4 + length].to_vec());
            }
        }
        if data.len() > 2_000_000 {
            return Ok(());
        }
    };

    if path == "/version" {
        let version = ui_version(ui);
        return respond(stream, 200, "application/json", format!("{{\"version\":\"{version}\"}}").as_bytes());
    }
    if path == "/health" {
        return respond(stream, 200, "application/json", b"{\"ok\":true}");
    }
    if path == "/models" {
        let settings = lua.call_string("wa_model", &[]).unwrap_or_else(|_| "{}".into());
        return respond(stream, 200, "application/json", settings.as_bytes());
    }
    if path == "/model" && method == "POST" {
        let name = String::from_utf8_lossy(&body).trim().to_string();
        let payload = lua
            .call_string("wa_set_model", &[name.as_str()])
            .unwrap_or_else(|error| format!("{{\"error\":{}}}", json_escape(&error)));
        return respond(stream, 200, "application/json", payload.as_bytes());
    }
    if path == "/chat" && method == "POST" {
        let text = String::from_utf8_lossy(&body).to_string();
        let header_text = String::from_utf8_lossy(&data).to_ascii_lowercase();
        if header_text.contains("text/event-stream") || path.contains("stream=1") {
            // Server-sent events: the whole turn streams back on this response.
            stream.write_all(
                b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\
                  Connection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n",
            )?;
            stream.flush()?;
            if let Ok(clone) = stream.try_clone() {
                if let Ok(mut guard) = CLIENT.lock() {
                    *guard = Some(clone);
                }
            }
            if let Err(error) = lua.call_string("wa_reply_stream", &[text.as_str()]) {
                write_event(&format!("{{\"type\":\"error\",\"error\":{}}}", json_escape(&error)));
            }
            write_event("{\"type\":\"done\"}");
            if let Ok(mut guard) = CLIENT.lock() {
                *guard = None;
            }
            return Ok(());
        }
        let reply = lua
            .call_string("wa_reply", &[text.as_str()])
            .unwrap_or_else(|error| format!("{{\"error\":{}}}", json_escape(&error)));
        return respond(stream, 200, "application/json", reply.as_bytes());
    }

    let relative = if path == "/" || path.is_empty() { "index.html".to_string() } else { path.trim_start_matches('/').to_string() };
    if relative.contains("..") {
        return respond(stream, 400, "text/plain", b"bad path");
    }
    match std::fs::read(ui.join(&relative)) {
        Ok(bytes) => respond(stream, 200, content_type(&relative), &bytes),
        Err(_) => respond(stream, 404, "text/plain; charset=utf-8", b"not found"),
    }
}

fn respond(stream: &mut TcpStream, status: u16, content_type: &str, body: &[u8]) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        _ => "OK",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\n\
         Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(body)?;
    stream.flush()
}

fn content_type(path: &str) -> &'static str {
    match path.rsplit('.').next().unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "wasm" => "application/wasm",
        "svg" => "image/svg+xml",
        _ => "application/octet-stream",
    }
}

fn ui_version(ui: &std::path::Path) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    let mut entries: Vec<_> = std::fs::read_dir(ui)
        .map(|dir| dir.flatten().map(|entry| entry.path()).collect())
        .unwrap_or_default();
    entries.sort();
    for path in entries {
        if let Ok(metadata) = path.metadata() {
            if metadata.is_file() {
                path.to_string_lossy().hash(&mut hasher);
                metadata.len().hash(&mut hasher);
                metadata
                    .modified()
                    .ok()
                    .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|duration| duration.as_millis())
                    .hash(&mut hasher);
            }
        }
    }
    format!("{:x}", hasher.finish())
}

fn json_escape(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "\"error\"".into())
}
