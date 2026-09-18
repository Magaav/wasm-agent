//! Client-tools bridge.
//!
//! The agent (Lua, on this host) can ask the *client* machine — the Windows
//! desktop running `wa-window` — to do things: screenshot, move/click the mouse,
//! type, press keys, and drive a browser CDP session.
//!
//! The Lua server is single-threaded, so the bridge runs on its own TCP port:
//! the client long-polls for commands, executes them, and posts results back.
//! `host.client(...)` enqueues a command and blocks on a condvar until the
//! result arrives, without blocking the client-facing listener.
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const POLL_WAIT: Duration = Duration::from_secs(20);
const CALL_TIMEOUT: Duration = Duration::from_secs(60);

struct Inner {
    queue: VecDeque<Value>,
    result: Option<(String, Value)>,
    next_id: u64,
    last_poll: Option<Instant>,
}

pub struct Bridge {
    inner: Mutex<Inner>,
    signal: Condvar,
}

impl Bridge {
    pub fn new() -> Self {
        Bridge {
            inner: Mutex::new(Inner { queue: VecDeque::new(), result: None, next_id: 0, last_poll: None }),
            signal: Condvar::new(),
        }
    }

    /// Called from Lua: enqueue a command and block until the result arrives.
    pub fn call(&self, action: &str, args: Value) -> Value {
        let id = {
            let mut inner = self.inner.lock().unwrap();
            inner.next_id += 1;
            inner.next_id.to_string()
        };
        {
            let mut inner = self.inner.lock().unwrap();
            inner.queue.push_back(json!({"id": id, "action": action, "args": args}));
        }
        self.signal.notify_all();

        let deadline = Instant::now() + CALL_TIMEOUT;
        let mut inner = self.inner.lock().unwrap();
        loop {
            if let Some((result_id, value)) = inner.result.clone() {
                if result_id == id {
                    inner.result = None;
                    return value;
                }
            }
            let now = Instant::now();
            if now >= deadline {
                return json!({"error": "client_timeout", "hint": "is wa ui running?"});
            }
            let (guard, _) = self.signal.wait_timeout(inner, deadline - now).unwrap();
            inner = guard;
        }
    }

    fn take_command(&self) -> Option<Value> {
        self.inner.lock().unwrap().queue.pop_front()
    }

    fn mark_poll(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.last_poll = Some(Instant::now());
        }
    }

    /// Liveness of the bound client, for the nodes panel.
    pub fn status(&self) -> Value {
        let inner = self.inner.lock().unwrap();
        let elapsed = inner
            .last_poll
            .map(|at| at.elapsed().as_secs())
            .unwrap_or(u64::MAX);
        json!({
            "connected": elapsed < 30,
            "last_seen_secs": if elapsed == u64::MAX { Value::Null } else { json!(elapsed) },
            "queued": inner.queue.len()
        })
    }

    fn deliver(&self, id: String, result: Value) {
        let mut inner = self.inner.lock().unwrap();
        inner.result = Some((id, result));
        self.signal.notify_all();
    }
}

/// Spawn the listener the native client polls. Non-blocking to the caller.
///
/// The bind is retried rather than given up on, because giving up is silent and permanent: a
/// leftover node held 127.0.0.1:8800 once, this printed one line to a log nobody was reading, and
/// the process then ran for hours with no bridge at all - so every control action timed out and the
/// only symptom was an AbortError in a view. A port that is busy now is often free a second later,
/// and waiting costs nothing. The same loop rebinds if the listener ever ends, so a node cannot be
/// left without a bridge for the rest of its life.
///
/// What this does *not* do is pretend the first failure did not happen: it says so, every attempt.
pub fn serve(port: u16, bridge: Arc<Bridge>) {
    std::thread::spawn(move || loop {
        let listener = match TcpListener::bind(("127.0.0.1", port)) {
            Ok(listener) => listener,
            Err(error) => {
                eprintln!("[client] bind 127.0.0.1:{port} failed ({error}); retrying in 2s");
                std::thread::sleep(std::time::Duration::from_secs(2));
                continue;
            }
        };
        eprintln!("[client] client-tools bridge on http://127.0.0.1:{port}");
        for stream in listener.incoming() {
            if let Ok(mut stream) = stream {
                let _ = handle(&bridge, &mut stream);
            }
        }
        eprintln!("[client] listener on {port} ended; rebinding");
        std::thread::sleep(std::time::Duration::from_secs(1));
    });
}

fn handle(bridge: &Bridge, stream: &mut TcpStream) -> std::io::Result<()> {
    let mut data = Vec::new();
    let mut chunk = [0u8; 8192];
    let (method, path, body) = loop {
        let read = stream.read(&mut chunk)?;
        if read == 0 {
            return Ok(());
        }
        data.extend_from_slice(&chunk[..read]);
        if let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&data[..end]).to_string();
            let mut lines = head.lines();
            let mut request = lines.next().unwrap_or("").split_whitespace();
            let method = request.next().unwrap_or("").to_string();
            let path = request.next().unwrap_or("/").to_string();
            let mut length = 0usize;
            for line in lines {
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap_or(0);
                }
            }
            if data.len() >= end + 4 + length {
                break (method, path, data[end + 4..end + 4 + length].to_vec());
            }
        }
        // Frames come back as base64 images, so allow several MB.
        if data.len() > 24_000_000 {
            return Ok(());
        }
    };

    if path == "/client/poll" {
        bridge.mark_poll();
        let deadline = Instant::now() + POLL_WAIT;
        loop {
            if let Some(command) = bridge.take_command() {
                return respond(stream, 200, &command.to_string());
            }
            if Instant::now() >= deadline {
                return respond(stream, 200, "{}");
            }
            std::thread::sleep(Duration::from_millis(120));
        }
    }
    if path == "/client/result" && method == "POST" {
        if let Ok(value) = serde_json::from_slice::<Value>(&body) {
            let id = value["id"].as_str().unwrap_or_default().to_string();
            bridge.deliver(id, value["result"].clone());
        }
        return respond(stream, 200, "{\"ok\":true}");
    }
    respond(stream, 404, "{\"error\":\"not_found\"}")
}

fn respond(stream: &mut TcpStream, status: u16, body: &str) -> std::io::Result<()> {
    let head = format!(
        "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\
         Cache-Control: no-store\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(body.as_bytes())?;
    stream.flush()
}
