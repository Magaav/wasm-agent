//! Client-tools bridge.
//!
//! The agent (Lua, on this host) can ask the *client* machine — the Windows
//! desktop running `wa-window` — to do things: screenshot, move/click the mouse,
//! type, press keys, run a shell, and drive a browser CDP session.
//!
//! The Lua server is single-threaded, so the bridge runs on its own TCP port:
//! the client long-polls for commands, executes them, and posts results back.
//! `host.client(...)` enqueues a command and blocks on a condvar until the
//! result arrives, without blocking the client-facing listener.
//!
//! Three things this file must never do again, each of which it did once:
//!
//! 1. **Serve one connection at a time on the accept loop.** A single peer that
//!    opened a socket and then said nothing blocked every later poll for as long
//!    as it stayed open: the listener stayed bound, `mark_poll` never ran, and
//!    the only symptom was `client_not_connected`, which blamed the window. The
//!    window was fine. Connections are now handled on their own threads, with a
//!    read timeout, so no peer can cost another peer anything.
//! 2. **Report three different worlds as one flag.** "No client is polling",
//!    "the client is mid-action", and "my own listener is not answering" are
//!    different failures with different remedies. All three are now reported,
//!    separately, and the remedies do not include restarting the window.
//! 3. **Throw away a late result.** A caller that gave up at 60s while the
//!    client was still launching a browser could never learn the outcome; the
//!    client's answer arrived and was overwritten. Results are kept by id now,
//!    and `host.client_result(id)` collects one even if the client is gone.
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// How long a poll is held open while waiting for a command. The client's read
/// timeout must exceed this; the "connected" window below must exceed it too,
/// or a healthy client would look dead between polls.
const POLL_WAIT: Duration = Duration::from_secs(20);
/// The caller's default patience. The client is told this same number and bounds
/// its own work by it, so a timeout means the work really has stopped rather
/// than that the caller stopped waiting.
const CALL_TIMEOUT_DEFAULT_MS: u64 = 75_000;
const CALL_TIMEOUT_MAX_MS: u64 = 300_000;
/// A poll is `connected` for this long after the last one. POLL_WAIT plus slack.
const CONNECTED_WINDOW: Duration = Duration::from_secs(45);
/// Reading a request head must not be able to hold a thread forever.
const HEAD_TIMEOUT: Duration = Duration::from_secs(10);
/// Requests are small; a peer that sends more than this is not a client.
const MAX_REQUEST: usize = 32 * 1024 * 1024;
/// Localhost-only, so this is a backstop rather than a policy.
const MAX_CONNECTIONS: usize = 32;
/// Late results worth keeping, so a caller that gave up can still collect.
const KEEP_RESULTS: usize = 8;

struct Inner {
    queue: VecDeque<Value>,
    /// `(id, at, value)` for results delivered, oldest first.
    results: VecDeque<(String, u64, Value)>,
    next_id: u64,
    last_poll: Option<Instant>,
    /// What the client volunteers on every poll: no round trip needed to ask.
    client_state: Option<(Value, Instant)>,
    /// The command currently in the client's hands.
    waited: Option<(String, String, Instant)>,
    connections: usize,
    self_probe_at: Option<Instant>,
    self_probe_ok: Option<bool>,
    self_probe_ms: Option<u64>,
    self_probe_failures: u64,
}

pub struct Bridge {
    inner: Mutex<Inner>,
    signal: Condvar,
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl Bridge {
    pub fn new() -> Self {
        Bridge {
            inner: Mutex::new(Inner {
                queue: VecDeque::new(),
                results: VecDeque::new(),
                next_id: 0,
                last_poll: None,
                client_state: None,
                waited: None,
                connections: 0,
                self_probe_at: None,
                self_probe_ok: None,
                self_probe_ms: None,
                self_probe_failures: 0,
            }),
            signal: Condvar::new(),
        }
    }

    /// Called from Lua: enqueue a command and block until the result arrives.
    /// `timeout_ms` is the caller's patience, and it travels with the command.
    pub fn call(&self, action: &str, args: Value, timeout_ms: u64) -> Value {
        let budget = timeout_ms.clamp(1_000, CALL_TIMEOUT_MAX_MS);
        let id = {
            let mut inner = self.inner.lock().unwrap();
            inner.next_id += 1;
            inner.next_id.to_string()
        };
        {
            let mut inner = self.inner.lock().unwrap();
            inner.queue.push_back(json!({
                "id": id,
                "action": action,
                "args": args,
                "budget_ms": budget,
            }));
        }
        self.signal.notify_all();

        let started = Instant::now();
        let deadline = started + Duration::from_millis(budget);
        let mut inner = self.inner.lock().unwrap();
        loop {
            if let Some(value) = take_result(&mut inner, &id) {
                inner.waited = None;
                return value;
            }
            let now = Instant::now();
            if now >= deadline {
                inner.waited = None;
                return json!({
                    "error": "client_timeout",
                    "id": id,
                    "waited_ms": started.elapsed().as_millis() as u64,
                    "observed": "the client did not answer within the budget it was given; \
                                 it bounds its own work by that same number, so the action has stopped",
                    "next": format!("collect the outcome anyway with client {{action:'result', id:'{id}'}} \
                                     (it is kept even if the client has gone), or raise timeout_ms"),
                });
            }
            let (guard, _) = self.signal.wait_timeout(inner, deadline - now).unwrap();
            inner = guard;
        }
    }

    fn take_command(&self) -> Option<Value> {
        let mut inner = self.inner.lock().unwrap();
        let command = inner.queue.pop_front()?;
        inner.waited = Some((
            command["id"].as_str().unwrap_or_default().to_string(),
            command["action"].as_str().unwrap_or_default().to_string(),
            Instant::now(),
        ));
        Some(command)
    }

    fn mark_poll(&self, state: Option<Value>) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.last_poll = Some(Instant::now());
            if let Some(state) = state {
                if !state.is_null() {
                    inner.client_state = Some((state, Instant::now()));
                }
            }
        }
    }

    /// Liveness, split into the three questions that actually differ:
    /// is the client polling, what is it doing, and is *this listener* answering.
    pub fn status(&self) -> Value {
        let inner = self.inner.lock().unwrap();
        let elapsed = inner.last_poll.map(|at| at.elapsed());
        let connected = elapsed.map(|age| age < CONNECTED_WINDOW).unwrap_or(false);
        let health = match inner.self_probe_ok {
            Some(true) => "ok",
            Some(false) if inner.self_probe_failures >= 3 => "wedged",
            Some(false) => "degraded",
            None => "unknown",
        };
        json!({
            "connected": connected,
            "last_seen_secs": elapsed.map(|age| age.as_secs()),
            "queued": inner.queue.len(),
            "bridge": {
                "port": port(),
                "health": health,
                "self_probe_ok": inner.self_probe_ok,
                "self_probe_age_ms": inner.self_probe_at.map(|at| at.elapsed().as_millis() as u64),
                "self_probe_ms": inner.self_probe_ms,
                "self_probe_failures": inner.self_probe_failures,
                "connections": inner.connections,
            },
            "client": inner.client_state.as_ref().map(|(state, at)| {
                let mut state = state.clone();
                if let Some(map) = state.as_object_mut() {
                    map.insert("age_ms".into(), json!(at.elapsed().as_millis() as u64));
                }
                state
            }),
            "busy": inner.waited.as_ref().map(|(id, action, at)| json!({
                "id": id, "action": action, "elapsed_ms": at.elapsed().as_millis() as u64,
            })),
            "results_kept": inner.results.len(),
        })
    }

    /// Deliver a result: kept by id so a caller that timed out can still ask.
    fn deliver(&self, id: String, result: Value) {
        let mut inner = self.inner.lock().unwrap();
        inner.results.retain(|(kept, _, _)| kept != &id);
        inner.results.push_back((id, now_ms(), result));
        while inner.results.len() > KEEP_RESULTS {
            inner.results.pop_front();
        }
        inner.waited = None;
        self.signal.notify_all();
    }

    /// The outcome of a command, by id — even one whose caller gave up.
    pub fn result(&self, id: &str) -> Value {
        let inner = self.inner.lock().unwrap();
        match inner.results.iter().find(|(kept, _, _)| kept == id) {
            Some((_, at, value)) => json!({
                "ok": true,
                "id": id,
                "age_ms": now_ms().saturating_sub(*at),
                "result": value,
            }),
            None => json!({
                "error": "result_not_kept",
                "id": id,
                "observed": format!("only the last {KEEP_RESULTS} results are kept, and this id is not one of them"),
                "next": "run the action again; if it is not idempotent, check its effect first",
            }),
        }
    }
}

fn take_result(inner: &mut Inner, id: &str) -> Option<Value> {
    inner.results.iter().find(|(kept, _, _)| kept == id).map(|(_, _, value)| value.clone())
}

// ---- globals: so /health can report the bridge without owning it --------------

static GLOBAL: OnceLock<Arc<Bridge>> = OnceLock::new();
static PORT: OnceLock<u16> = OnceLock::new();

fn port() -> Option<u16> {
    PORT.get().copied()
}

/// The bridge's status for a reader that does not hold it (`/health`).
/// `null` when this node runs no bridge at all (a `wa chat` process, for instance).
pub fn global_status() -> Value {
    match GLOBAL.get() {
        Some(bridge) => bridge.status(),
        None => Value::Null,
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
    let _ = GLOBAL.set(bridge.clone());
    let _ = PORT.set(port);
    spawn_self_probe(port, bridge.clone());
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
            let Ok(stream) = stream else { continue };
            // One thread per connection: a peer that stalls costs a thread, never
            // the accept loop and never another peer's poll.
            let bridge = bridge.clone();
            let admitted = {
                let mut inner = bridge.inner.lock().unwrap();
                inner.connections += 1;
                inner.connections <= MAX_CONNECTIONS
            };
            if !admitted {
                let mut stream = stream;
                let _ = respond(&mut stream, 503, "{\"error\":\"too_many_connections\"}");
                let mut inner = bridge.inner.lock().unwrap();
                inner.connections = inner.connections.saturating_sub(1);
                continue;
            }
            std::thread::spawn(move || {
                let mut stream = stream;
                let _ = handle(&bridge, &mut stream);
                if let Ok(mut inner) = bridge.inner.lock() {
                    inner.connections = inner.connections.saturating_sub(1);
                }
            });
        }
        eprintln!("[client] listener on {port} ended; rebinding");
        std::thread::sleep(std::time::Duration::from_secs(1));
    });
}

/// A listener that accepts and never answers is the failure this file exists to
/// make visible, so the bridge asks itself the same question a client would.
/// The probe never touches the queue and never counts as a poll.
fn spawn_self_probe(port: u16, bridge: Arc<Bridge>) {
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(5));
        let started = Instant::now();
        let ok = match TcpStream::connect(("127.0.0.1", port)) {
            Ok(mut stream) => {
                stream.set_read_timeout(Some(Duration::from_millis(800))).ok();
                stream.set_write_timeout(Some(Duration::from_millis(800))).ok();
                let request = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
                let sent = stream.write_all(request.as_bytes()).is_ok();
                let mut buffer = [0u8; 64];
                sent && stream.read(&mut buffer).map(|read| read > 0).unwrap_or(false)
            }
            Err(_) => false,
        };
        let ms = started.elapsed().as_millis() as u64;
        if let Ok(mut inner) = bridge.inner.lock() {
            inner.self_probe_at = Some(Instant::now());
            inner.self_probe_ok = Some(ok);
            inner.self_probe_ms = Some(ms);
            if ok {
                inner.self_probe_failures = 0;
            } else {
                inner.self_probe_failures += 1;
                if inner.self_probe_failures == 3 {
                    eprintln!("[client] the bridge did not answer its own probe 3 times: a connection is wedged");
                }
            }
        }
    });
}

fn handle(bridge: &Bridge, stream: &mut TcpStream) -> std::io::Result<()> {
    // A request head that never arrives must not hold this thread forever: the
    // connection is abandoned and the client reconnects on its next poll.
    stream.set_read_timeout(Some(HEAD_TIMEOUT))?;
    let mut data = Vec::new();
    let mut chunk = [0u8; 8192];
    let (method, path, body) = loop {
        let read = match stream.read(&mut chunk) {
            Ok(0) => return Ok(()),
            Ok(read) => read,
            Err(_) => return Ok(()), // timeout or reset: drop it, keep serving
        };
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
        if data.len() > MAX_REQUEST {
            return respond(stream, 413, "{\"error\":\"request_too_large\"}");
        }
    };

    if path == "/client/poll" {
        // v2 clients say what they are on every poll, so the answer to "what can
        // this client do, and what did it last do" costs no extra round trip.
        if method == "POST" {
            if let Ok(value) = serde_json::from_slice::<Value>(&body) {
                bridge.mark_poll(value.get("state").cloned());
            } else {
                bridge.mark_poll(None);
            }
        } else {
            // An older window polls with GET and volunteers nothing.
            bridge.mark_poll(None);
        }
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

/// The budget a caller gets when it does not say. Exposed so the tool schema and
/// this file cannot drift apart.
pub fn default_timeout_ms() -> u64 {
    CALL_TIMEOUT_DEFAULT_MS
}
