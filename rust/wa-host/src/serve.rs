//! Tiny local web UI plus the node's inbound surface.
//!
//! Two threads, with one job each. The accept thread answers everything that needs
//! no interpreter - `/health`, `/version`, and the UI files - and forwards the rest
//! to the agent thread, which owns the Lua state and runs requests one at a time
//! (the interpreter is not thread-safe, so that serialisation is required, not a
//! choice).
//!
//! The split exists because a single thread made the node deaf to its own UI while
//! a turn was running: `POST /chat` holds its connection for a whole turn, so the
//! window's fetches queued behind a model call, Chromium gave up, and the user saw
//! "TypeError: Failed to fetch" from a node that was local and alive. Reloading
//! could not help either - the reload needed the same busy thread.
//!
//! Two things feed the agent thread: sockets, and - when attached to a relay -
//! requests the relay hands us (`relay_client`). Both end up in `dispatch`, so a
//! node behaves identically whether it is reached directly or through the relay.
use crate::lua::Lua;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};

/// Milliseconds since the process started, written by anything that is making
/// progress: every event the worker emits, and every turn or tool boundary the Lua loop
/// reports through host.beat.
///
/// This is the only way to tell a slow turn from a wedged node. A wedged node answers
/// /health perfectly (that reply needs no interpreter) and holds its listening socket,
/// so from outside it looks idle rather than stuck. If this stops moving, the
/// interpreter is not running anything, and that is a fact worth reporting.
static BEAT_MS: AtomicU64 = AtomicU64::new(0);
static STARTED: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
/// Rate-limits the "the worker is stalled" line so a wedged node cannot fill a log.
static STALL_LOGGED_MS: AtomicU64 = AtomicU64::new(0);

/// What the worker is doing right now, as (label, started_ms). A stall is only
/// diagnosable if it says *what* it is stuck on: a local turn, a relayed peer request, or
/// housekeeping are three different bugs with one symptom.
static IN_FLIGHT: Mutex<Option<(String, u64)>> = Mutex::new(None);
/// Requests waiting for the worker. Housekeeping waits until this is zero.
static QUEUED: AtomicUsize = AtomicUsize::new(0);
/// When the last request was taken off the queue, so the tick can wait for a quiet moment.
static LAST_SERVED_MS: AtomicU64 = AtomicU64::new(0);

/// Which read worker the next read goes to. Round-robin rather than "the idle one": reads are short, and a
/// counter has no lock and no stale idea about who is free.
static READ_ROTATE: AtomicUsize = AtomicUsize::new(0);

/// How many interpreters this node runs, and which one owns what.
///
/// One is the default and behaves exactly as before. With more, **worker 0 keeps every route that changes
/// something** - turns, writes, sync, node calls - and the extra workers serve reads. That split is the
/// whole point: the window's own reads (`/sessions`, `/session`, `/models`, `/nodes`) used to queue behind
/// a turn, so a node in the middle of a build looked like a node that had gone away, an undo check sat
/// pending for minutes, and the desktop client's polls piled up into the queue.
///
/// It is deliberately conservative: every turn stays on worker 0, so "one writer per session" and
/// per-session order hold by construction rather than by locking. Concurrent *turns* are the next step,
/// not this one. And the read-route list below is a **routing hint, not a source of truth**: a path that is
/// not in it simply goes to worker 0, which is exactly today's behaviour.
static WORKER_COUNT: AtomicUsize = AtomicUsize::new(1);
static WORKER_BEATS: OnceLock<Vec<AtomicU64>> = OnceLock::new();
static WORKER_BUSY: OnceLock<Vec<Mutex<Option<(String, u64)>>>> = OnceLock::new();

thread_local! {
    /// Which worker this thread is. `beat()` is called from inside Lua and had no way to say *which*
    /// interpreter had made progress, so per-worker liveness was impossible until this existed.
    static WORKER_ID: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

fn worker_id() -> usize {
    WORKER_ID.with(|cell| cell.get())
}

/// Routes that only read. A GET on one of these is served by a read worker when the node has one.
/// Not in this list means worker 0 - the safe default, and the reason a missing entry is a performance
/// question rather than a correctness one.
fn is_read_route(request: &Request) -> bool {
    if request.method != "GET" {
        return false;
    }
    let (route, _) = split_path(&request.path);
    matches!(
        route.as_str(),
        "/sessions" | "/session" | "/models" | "/me" | "/users" | "/nodes" | "/skills"
            | "/memories" | "/status" | "/spells" | "/sync" | "/toolchain" | "/turns"
    )
}

/// Milliseconds since a particular worker last reported progress. A worker that has never beaten is as
/// old as the process, which is not a stall - the same rule the aggregate age uses.
fn worker_age_ms(index: usize) -> u64 {
    let started = match STARTED.get() {
        Some(started) => started,
        None => return 0,
    };
    let now = started.elapsed().as_millis() as u64;
    match WORKER_BEATS.get().and_then(|beats| beats.get(index)) {
        Some(slot) => now.saturating_sub(slot.load(Ordering::Relaxed)),
        None => now.saturating_sub(BEAT_MS.load(Ordering::Relaxed)),
    }
}

fn worker_count() -> usize {
    WORKER_COUNT.load(Ordering::Relaxed).max(1)
}

fn now_ms() -> u64 {
    STARTED.get_or_init(std::time::Instant::now).elapsed().as_millis() as u64
}

fn begin_work(label: String) {
    // Only worker 0 sets `IN_FLIGHT`. That field is what the window reads to decide whether a *turn* is
    // running - so a read being served on another interpreter must not make the UI think a turn is in
    // flight, which would disable the composer for a status request.
    let index = worker_id();
    if index == 0 {
        if let Ok(mut slot) = IN_FLIGHT.lock() {
            *slot = Some((label.clone(), now_ms()));
        }
    }
    if let Some(slots) = WORKER_BUSY.get() {
        if let Some(slot) = slots.get(index) {
            if let Ok(mut guard) = slot.lock() {
                *guard = Some((label, now_ms()));
            }
        }
    }
}

fn end_work() {
    let index = worker_id();
    if index == 0 {
        if let Ok(mut slot) = IN_FLIGHT.lock() {
            *slot = None;
        }
    }
    if let Some(slots) = WORKER_BUSY.get() {
        if let Some(slot) = slots.get(index) {
            if let Ok(mut guard) = slot.lock() {
                *guard = None;
            }
        }
    }
}

pub fn beat() {
    let started = STARTED.get_or_init(std::time::Instant::now);
    let now = started.elapsed().as_millis() as u64;
    // The aggregate is the *newest* beat of any worker: the node is alive if any interpreter is making
    // progress. Which worker is quiet is a per-worker question, answered in the health body.
    BEAT_MS.store(now, Ordering::Relaxed);
    if let Some(beats) = WORKER_BEATS.get() {
        if let Some(slot) = beats.get(worker_id()) {
            slot.store(now, Ordering::Relaxed);
        }
    }
}

/// Proof of life for the duration of a host call that is known to be in progress and
/// known to be bounded.
///
/// The stall detector exists to catch a worker that has stopped making progress: an
/// unbounded Lua loop, a provider that accepted the connection and went quiet. A long
/// `exec` is not that - it has a deadline and is killed when the deadline passes - but it
/// beat nothing while it ran, so a node *working correctly* reported `ok:false`,
/// `worker:stalled`, and every reader believed it. The window was the worst of them: its
/// own reads queue behind the turn, so `/me` and `/models` timed out and it told the user
/// the node was offline, while the node was running their command. Past the exit threshold
/// the node then killed itself in the middle of that command.
///
/// So: while waiting on something with a deadline, say so. The detector keeps its teeth
/// for the case it was built for - a worker stuck with no deadline in sight still stops
/// beating, and still exits.
pub struct Heartbeat {
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

impl Heartbeat {
    pub fn start() -> Self {
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = stop.clone();
        std::thread::spawn(move || {
            while !flag.load(Ordering::Relaxed) {
                beat();
                // Once a second, not once every few: `worker` reads "alive" only while the age is
                // under a second, and a five-second tick made a running command look merely "busy"
                // - which the first version of this test caught by measuring a 4.5s age.
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        });
        beat();
        Self { stop }
    }
}

impl Drop for Heartbeat {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

/// How long since the last sign of progress, in milliseconds. A process that has not
/// beaten at all is "as old as the process", which is not a stall.
pub(crate) fn beat_age_ms() -> u64 {
    let started = match STARTED.get() {
        Some(started) => started,
        None => return 0,
    };
    let now = started.elapsed().as_millis() as u64;
    now.saturating_sub(BEAT_MS.load(Ordering::Relaxed))
}

fn env_seconds(name: &str, fallback: u64) -> u64 {
    std::env::var(name).ok().and_then(|value| value.parse().ok()).unwrap_or(fallback)
}

/// How long a request may sit behind a worker that has shown no progress before it is
/// told so instead of waiting. Long enough that a slow turn is not mistaken for a
/// wedge; short enough that a client is not left holding an open socket for minutes.
fn stall_seconds() -> u64 {
    env_seconds("WASM_AGENT_WORKER_STALL_SECONDS", 120)
}

/// Past this, the node stops being a node: exit so the service manager restarts it. A
/// stalled turn is already lost - the provider connection is not coming back - and a
/// fresh process beats a wedged one that answers /health.
fn stall_exit_seconds() -> u64 {
    env_seconds("WASM_AGENT_WORKER_STALL_EXIT_SECONDS", 900)
}

/// The honest health body. `ok` is false when the interpreter has stopped reporting,
/// which is the one thing this endpoint is uniquely placed to say.
fn health_body() -> Vec<u8> {
    let age_ms = beat_age_ms();
    let stalled = age_ms >= stall_seconds() * 1000;
    let state = if stalled { "stalled" } else if age_ms < 1000 { "alive" } else { "busy" };
    let current = IN_FLIGHT.lock().ok().and_then(|slot| {
        slot.as_ref().map(|(label, started)| {
            serde_json::json!({ "label": label, "ms": now_ms().saturating_sub(*started) })
        })
    });
    // Per-worker detail, so "which one is busy, and with what" is answerable without reading a log. The
    // aggregate fields above are kept exactly as they were: the window and the sentinel read them, and a
    // new field must not move an old one.
    let mut workers = Vec::new();
    for index in 0..worker_count() {
        let age = worker_age_ms(index);
        let busy = WORKER_BUSY
            .get()
            .and_then(|slots| slots.get(index))
            .and_then(|slot| slot.lock().ok().and_then(|guard| guard.clone()));
        workers.push(serde_json::json!({
            "id": index,
            "state": if age >= stall_seconds() * 1000 { "stalled" } else if age < 1000 { "alive" } else { "busy" },
            "age_ms": age,
            "busy_ms": busy.as_ref().map(|(_, started)| now_ms().saturating_sub(*started)),
            "label": busy.as_ref().map(|(label, _)| label.clone()),
        }));
    }
    // Built with serde_json rather than a hand-escaped format string: the escaping
    // is exactly the kind of thing that silently produces invalid JSON, and this is
    // the one endpoint that must never be the thing that lies.
    serde_json::json!({
        "ok": !stalled,
        "worker": state,
        "stalled_ms": age_ms,
        "queue": QUEUED.load(Ordering::Relaxed),
        "current": current,
        "workers_count": worker_count(),
        "workers": workers,
    })
    .to_string()
    .into_bytes()
}

/// The one open SSE client. Only the agent thread touches it, but it is a static
/// so that `host.stream` can reach it from inside Lua.
static CLIENT: Mutex<Option<TcpStream>> = Mutex::new(None);

/// When set, events are collected here instead of going to a socket: that is how
/// a streaming turn is relayed to a peer that cannot hold a live connection.
static EVENT_SINK: Mutex<Option<String>> = Mutex::new(None);

/// Push one event to the streaming client, if any. Called from Lua via host.stream.
///
/// Every event is also proof of life: a streaming turn emits deltas continuously, so a
/// stalled provider read shows up here as silence long before anyone notices a hang.
pub fn write_event(payload: &str) {
    beat();
    if let Ok(mut sink) = EVENT_SINK.lock() {
        if let Some(buffer) = sink.as_mut() {
            buffer.push_str("data: ");
            buffer.push_str(payload);
            buffer.push_str("\n\n");
            return;
        }
    }
    if let Ok(mut guard) = CLIENT.lock() {
        if let Some(socket) = guard.as_mut() {
            let _ = socket.write_all(format!("data: {payload}\n\n").as_bytes());
            let _ = socket.flush();
        }
    }
}

/// Run `f` collecting any events it emits, and return them as an SSE body.
fn capture_events<F: FnOnce()>(f: F) -> String {
    if let Ok(mut sink) = EVENT_SINK.lock() {
        *sink = Some(String::new());
    }
    f();
    match EVENT_SINK.lock() {
        Ok(mut sink) => sink.take().unwrap_or_default(),
        Err(_) => String::new(),
    }
}

type Reply = (u16, &'static str, Vec<u8>);

fn ok_json(body: String) -> Reply {
    (200, "application/json", body.into_bytes())
}

pub fn run(states: Vec<Lua>, port: u16, ui: PathBuf) {
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("[serve] bind 127.0.0.1:{port} failed: {error}");
            return;
        }
    };
    let workers = states.len().max(1);
    WORKER_COUNT.store(workers, Ordering::Relaxed);
    let _ = WORKER_BEATS.set((0..workers).map(|_| AtomicU64::new(0)).collect());
    let _ = WORKER_BUSY.set((0..workers).map(|_| Mutex::new(None)).collect());
    if workers > 1 {
        eprintln!("[serve] {workers} interpreters: worker 0 owns turns and writes, {} serve reads", workers - 1);
    }
    eprintln!("[serve] wasm-agent UI at http://127.0.0.1:{port}  (ui: {})", ui.display());

    if let Ok(relay_url) = std::env::var("WASM_AGENT_RELAY") {
        if !relay_url.is_empty() {
            crate::relay_client::spawn(relay_url);
        }
    }

    // Each worker owns an interpreter for the life of the process and reads its own queue, so requests
    // still run one at a time *per interpreter* - what changed is that a running turn no longer stops the
    // node answering anything at all. `/health`, `/version` and the UI files were already answered on the
    // accept thread; the reads that need Lua (sessions, models, nodes) now have a second interpreter to
    // run on.
    //
    // Bounded on purpose: an unbounded queue turns a busy node into an unbounded number of open sockets,
    // and the accept thread can then only fail it loudly.
    let queue_depth: usize = std::env::var("WASM_AGENT_QUEUE_DEPTH")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(256);
    let mut senders = Vec::with_capacity(workers);
    let mut receivers = Vec::with_capacity(workers);
    for _ in 0..workers {
        let (sender, receiver) = std::sync::mpsc::sync_channel::<(TcpStream, Request)>(queue_depth);
        senders.push(sender);
        receivers.push(receiver);
    }
    for (index, (state, receiver)) in states.into_iter().zip(receivers).enumerate() {
        let worker_ui = ui.clone();
        std::thread::spawn(move || {
            WORKER_ID.with(|cell| cell.set(index));
            worker_loop(state, index, receiver, worker_ui);
        });
    }

    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        let request = match read_request(&mut stream) {
            Ok(Some(request)) => request,
            _ => continue,
        };
        if let Some((status, content_type, body)) = static_reply(&ui, &request) {
            let _ = respond(&mut stream, status, content_type, &body);
            continue;
        }
        // A read goes to a read worker even when they are all busy: queueing a status request behind a
        // turn is the thing this exists to prevent. Anything that is not a known read - a turn, a write, a
        // node call - goes to worker 0, which is what keeps one writer per session true by construction.
        let target = if workers > 1 && is_read_route(&request) {
            1 + (READ_ROTATE.fetch_add(1, Ordering::Relaxed) % (workers - 1))
        } else {
            0
        };
        let age_ms = worker_age_ms(target);
        if age_ms >= stall_seconds() * 1000 {
            // The worker this request needs has not reported progress for longer than any healthy
            // operation takes. Saying so is the whole point: the alternative was an open socket, no bytes,
            // and a client that waits forever.
            let now = STARTED.get().map(|s| s.elapsed().as_millis() as u64).unwrap_or(0);
            let last = STALL_LOGGED_MS.load(Ordering::Relaxed);
            if now.saturating_sub(last) > 30_000 {
                STALL_LOGGED_MS.store(now, Ordering::Relaxed);
                eprintln!(
                    "[serve] worker {target} has not reported progress for {}s - replying 503",
                    age_ms / 1000
                );
            }
            // Exit only when *every* worker is stalled: a wedged lane must not take the healthy ones with
            // it, and with the default of one worker this is exactly the old behaviour.
            let all_stalled = (0..workers).all(|index| worker_age_ms(index) >= stall_exit_seconds() * 1000);
            if stall_exit_seconds() > 0 && all_stalled {
                eprintln!(
                    "[serve] every worker has been stalled for {}s: exiting so the service manager can restart the node",
                    stall_exit_seconds()
                );
                std::process::exit(3);
            }
            let body = format!(
                "{{\"error\":\"worker_stalled\",\"worker\":{target},\"stalled_ms\":{age_ms},\"hint\":\"the interpreter has not reported progress; see the node log, and restart it if the turn is lost\"}}"
            );
            let _ = respond(&mut stream, 503, "application/json", body.as_bytes());
            continue;
        }
        QUEUED.fetch_add(1, Ordering::Relaxed);
        match senders[target].try_send((stream, request)) {
            Ok(()) => {}
            Err(std::sync::mpsc::TrySendError::Full((mut stream, _request))) => {
                QUEUED.fetch_sub(1, Ordering::Relaxed);
                // A bounded queue: refusing loudly beats an unbounded backlog that every client waits in.
                let body = b"{\"error\":\"node_busy\",\"hint\":\"the node is answering other requests; retry shortly\"}";
                let _ = respond(&mut stream, 503, "application/json", body);
            }
            Err(std::sync::mpsc::TrySendError::Disconnected(_)) => {
                QUEUED.fetch_sub(1, Ordering::Relaxed);
                eprintln!("[serve] worker {target} is gone");
                return;
            }
        }
    }
}

/// One interpreter's loop. Worker 0 also does the housekeeping - relayed work and the sync tick - because
/// that work is a conversation with a peer and belongs where the turns are; a read worker does nothing but
/// answer reads.
fn worker_loop(
    lua: Lua,
    index: usize,
    receiver: std::sync::mpsc::Receiver<(TcpStream, Request)>,
    agent_ui: PathBuf,
) {
    let mut next_sync = std::time::Instant::now() + std::time::Duration::from_secs(5);
    // A deterministic wedge, for the regression test: the hook stalls worker 0 on its first request, which
    // is exactly the shape that was found in the wild. Only worker 0, or a node with read workers would
    // stall all of them and the test would be measuring itself.
    let test_stall = index == 0 && std::env::var("WASM_AGENT_TEST_STALL_WORKER").is_ok();
    let mut stalled_once = false;
    loop {
        beat();
        // Local requests first. Peer-relayed work is real work, but it is not the human's request, and
        // putting it in front of the queue is how a peer's slow call made the window say "connecting…".
        let local = receiver.recv_timeout(std::time::Duration::from_millis(100));
        match local {
            Ok((mut stream, request)) => {
                if test_stall && !stalled_once {
                    stalled_once = true;
                    eprintln!("[serve] test hook: stalling worker 0 on purpose");
                    std::thread::sleep(std::time::Duration::from_secs(3600));
                }
                QUEUED.fetch_sub(1, Ordering::Relaxed);
                LAST_SERVED_MS.store(now_ms(), Ordering::Relaxed);
                begin_work(format!("{} {}", request.method, request.path));
                let _ = handle(&lua, &agent_ui, &mut stream, &request);
                end_work();
                beat();
                continue;
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
        }
        if index != 0 {
            continue;
        }
        // Requests the relay handed to us (NAT'd peers, or peers relaying us).
        for job in crate::relay_client::take_jobs() {
            begin_work(format!("relay {} {}", job.method, job.path));
            let (status, body) = process_relay_job(&lua, &agent_ui, &job);
            end_work();
            beat();
            let _ = job.reply.send((status, body));
        }
        // Housekeeping last, and only when nobody is waiting and the node has been quiet: the sync tick
        // talks to a peer over the network, and on worker 0 that means this interpreter stops answering
        // while it does.
        let quiet = now_ms().saturating_sub(LAST_SERVED_MS.load(Ordering::Relaxed)) >= 2000;
        if std::time::Instant::now() >= next_sync && QUEUED.load(Ordering::Relaxed) == 0 && quiet {
            next_sync = std::time::Instant::now() + std::time::Duration::from_secs(20);
            begin_work("sync tick".to_string());
            if let Err(error) = lua.call_string("wa_sync_tick", &[]) {
                eprintln!("[sync] tick failed: {error}");
            }
            end_work();
            beat();
        }
    }
}


/// Process a request that arrived over the relay. Streaming routes are captured
/// rather than written to a socket, so the peer gets the events and can replay
/// them locally.
fn process_relay_job(lua: &Lua, ui: &std::path::Path, job: &crate::relay_client::RelayJob) -> (u16, String) {
    let ui = ui.to_path_buf();
    let job = crate::relay_client::RelayJob {
        id: job.id.clone(),
        method: job.method.clone(),
        path: job.path.clone(),
        headers: job.headers.clone(),
        body: job.body.clone(),
        reply: job.reply.clone(),
    };
    let (route, _query) = split_path(&job.path);
    let session = header_of(&job.headers, "x-wa-session");

    if route == "/node/chat" && job.method == "POST" {
        let from = header_of(&job.headers, "x-wa-node");
        let public_key = header_of(&job.headers, "x-wa-pub");
        let ts = header_of(&job.headers, "x-wa-ts");
        let signature = header_of(&job.headers, "x-wa-sig");
        let text = job.body.clone();
        let events = capture_events(|| {
            if let Err(error) = lua.call_string(
                "wa_node_chat",
                &[from.as_str(), public_key.as_str(), ts.as_str(), signature.as_str(), text.as_str()],
            ) {
                write_event(&format!("{{\"type\":\"error\",\"error\":{}}}", json_escape(&error)));
            }
            write_event("{\"type\":\"done\"}");
        });
        return (200, events);
    }
    if route == "/chat" && job.method == "POST" {
        let text = job.body.clone();
        let node = header_of(&job.headers, "x-wa-node");
        let events = capture_events(|| {
            if let Err(error) = lua.call_string("wa_reply_stream", &[text.as_str(), session.as_str(), node.as_str()]) {
                write_event(&format!("{{\"type\":\"error\",\"error\":{}}}", json_escape(&error)));
            }
            write_event("{\"type\":\"done\"}");
        });
        return (200, events);
    }

    let session = header_of(&job.headers, "x-wa-session");
    match dispatch(lua, &ui, &job.method, &job.path, &job.headers, &job.body, &session) {
        Some((status, _content_type, body)) => (status, String::from_utf8_lossy(&body).to_string()),
        None => (404, "{\"error\":\"not_found\"}".to_string()),
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

fn header_of(headers: &[(String, String)], name: &str) -> String {
    headers
        .iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.clone())
        .unwrap_or_default()
}

fn query_value(query: &str, key: &str) -> String {
    let prefix = format!("{key}=");
    query
        .split('&')
        .find_map(|pair| pair.strip_prefix(prefix.as_str()))
        .map(|value| value.to_string())
        .unwrap_or_default()
}

fn split_path(path: &str) -> (String, String) {
    match path.split_once('?') {
        Some((route, query)) => (route.to_string(), query.to_string()),
        None => (path.to_string(), String::new()),
    }
}

/// A parsed request, so the accept thread can decide whether answering it needs the
/// interpreter before handing it over.
struct Request {
    method: String,
    path: String,
    session: String,
    node_headers: Vec<(String, String)>,
    body: Vec<u8>,
    accept_sse: bool,
}

/// Read one request off the socket. `None` means the peer closed.
fn read_request(stream: &mut TcpStream) -> std::io::Result<Option<Request>> {
    let mut data = Vec::new();
    let mut chunk = [0u8; 16384];
    loop {
        let read = stream.read(&mut chunk)?;
        if read == 0 {
            return Ok(None);
        }
        data.extend_from_slice(&chunk[..read]);
        if let Some(end) = find(&data, b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&data[..end]).to_string();
            let mut lines = head.lines();
            let mut request = lines.next().unwrap_or("").split_whitespace();
            let method = request.next().unwrap_or("").to_string();
            let path = request.next().unwrap_or("/").to_string();
            let mut length = 0usize;
            let mut session = String::new();
            let mut accept_sse = false;
            let mut node_headers: Vec<(String, String)> = Vec::new();
            for line in lines {
                let lower = line.to_ascii_lowercase();
                if let Some(value) = lower.strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap_or(0);
                } else if let Some(value) = lower.strip_prefix("x-wa-session:") {
                    session = value.trim().to_string();
                } else if lower.starts_with("accept:") && lower.contains("text/event-stream") {
                    accept_sse = true;
                } else if let Some((key, value)) = lower.split_once(':') {
                    if key.trim().starts_with("x-wa-") {
                        node_headers.push((key.trim().to_string(), value.trim().to_string()));
                    }
                }
            }
            if data.len() >= end + 4 + length {
                return Ok(Some(Request {
                    method,
                    path,
                    session,
                    node_headers,
                    body: data[end + 4..end + 4 + length].to_vec(),
                    accept_sse,
                }));
            }
        }
        if data.len() > 4_000_000 {
            return Ok(None);
        }
    }
}

/// Answered on the accept thread, without the interpreter: the two facts a node is
/// asked for when it looks unwell, and the files the window needs to redraw itself.
/// Anything else - including an unknown route - goes to the agent thread.
fn static_reply(ui: &std::path::Path, request: &Request) -> Option<Reply> {
    let (route, _query) = split_path(&request.path);
    if route == "/health" {
        return Some((200, "application/json", health_body()));
    }
    if route == "/version" {
        return Some((200, "application/json", version_body(ui).into_bytes()));
    }
    let relative = if route == "/" || route.is_empty() {
        "index.html".to_string()
    } else {
        route.trim_start_matches('/').to_string()
    };
    if relative.contains("..") {
        return Some((400, "text/plain", b"bad path".to_vec()));
    }
    // A route the UI does not have could still be an API route (they are all
    // handled by `dispatch`), so absence is not a 404 here - it means "ask the
    // agent thread". That keeps the route table in exactly one place.
    match std::fs::read(ui.join(&relative)) {
        Ok(bytes) => Some((200, content_type(&relative), bytes)),
        Err(_) => None,
    }
}

fn version_body(ui: &std::path::Path) -> String {
    format!("{{\"version\":\"{}\"}}", ui_version(ui))
}

fn handle(lua: &Lua, ui: &std::path::Path, stream: &mut TcpStream, request: &Request) -> std::io::Result<()> {
    let method = request.method.as_str();
    let path = request.path.as_str();
    let session = request.session.as_str();
    let body = request.body.as_slice();
    let node_headers = request.node_headers.as_slice();
    let accept_sse = request.accept_sse;
    let (route, _query) = split_path(path);
    if route == "/chat" && method == "POST" {
        let text = String::from_utf8_lossy(&body).to_string();
        if accept_sse || route.contains("stream=1") {
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
            let node = header_of(&node_headers, "x-wa-node");
            if let Err(error) = lua.call_string("wa_reply_stream", &[text.as_str(), session, node.as_str()]) {
                write_event(&format!("{{\"type\":\"error\",\"error\":{}}}", json_escape(&error)));
            }
            write_event("{\"type\":\"done\"}");
            if let Ok(mut guard) = CLIENT.lock() {
                *guard = None;
            }
            return Ok(());
        }
    }
    if route == "/node/chat" && method == "POST" {
        let text = String::from_utf8_lossy(&body).to_string();
        let from = header_of(&node_headers, "x-wa-node");
        let public_key = header_of(&node_headers, "x-wa-pub");
        let ts = header_of(&node_headers, "x-wa-ts");
        let signature = header_of(&node_headers, "x-wa-sig");
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
        if let Err(error) = lua.call_string(
            "wa_node_chat",
            &[from.as_str(), public_key.as_str(), ts.as_str(), signature.as_str(), text.as_str()],
        ) {
            write_event(&format!("{{\"type\":\"error\",\"error\":{}}}", json_escape(&error)));
        }
        write_event("{\"type\":\"done\"}");
        if let Ok(mut guard) = CLIENT.lock() {
            *guard = None;
        }
        return Ok(());
    }

    match dispatch(lua, ui, &method, &path, &node_headers, &String::from_utf8_lossy(&body), &session) {
        Some((status, content_type, payload)) => respond(stream, status, content_type, &payload),
        None => respond(stream, 404, "text/plain; charset=utf-8", b"not found"),
    }
}

/// Every request/response endpoint. Streaming routes return `None` and are
/// handled by the caller (socket or relay capture).
fn dispatch(
    lua: &Lua,
    ui: &std::path::Path,
    method: &str,
    path: &str,
    node_headers: &[(String, String)],
    body: &str,
    session: &str,
) -> Option<Reply> {
    let (route, query) = split_path(path);
    // `session` is passed in: the socket parser consumes x-wa-session before the
    // x-wa-* collection, so reading it back out of node_headers yields nothing
    // and every request silently falls back to the default (master) user.
    let node_param = query_value(&query, "node");
    let node = if !node_param.is_empty() {
        node_param
    } else {
        header_of(node_headers, "x-wa-node")
    };
    let call = |name: &str, args: &[&str]| -> String {
        lua.call_string(name, args)
            .unwrap_or_else(|error| format!("{{\"error\":{}}}", json_escape(&error)))
    };

    let reply = match route.as_str() {
        "/version" => (200, "application/json", version_body(ui).into_bytes()),
        "/health" => (200, "application/json", health_body()),
        "/models" => (200, "application/json", call("wa_model", &[node.as_str(), session]).into_bytes()),
        "/me" => (200, "application/json", call("wa_me", &[session]).into_bytes()),
        "/users" => (200, "application/json", call("wa_users", &[]).into_bytes()),
        "/login" if method == "POST" => (200, "application/json", call("wa_login", &[body.trim(), session]).into_bytes()),
        "/logout" if method == "POST" => (200, "application/json", call("wa_logout", &[session]).into_bytes()),
        "/shell" if method == "POST" => (200, "application/json", call("wa_shell", &[body, session]).into_bytes()),
        "/sync/head" => (200, "application/json", call("wa_sync_head", &[]).into_bytes()),
        "/sync/push" if method == "POST" => (200, "application/json", call("wa_sync_apply", &[
            body,
            &header_of(node_headers, "x-wa-node"),
            &header_of(node_headers, "x-wa-pub"),
            &header_of(node_headers, "x-wa-ts"),
            &header_of(node_headers, "x-wa-sig"),
        ]).into_bytes()),
        "/sync/tick" if method == "POST" => (200, "application/json", call("wa_sync_tick", &[]).into_bytes()),
        "/sync" => (200, "application/json", call("wa_sync_status", &[]).into_bytes()),
        "/node/call" if method == "POST" => {
            let from = header_of(node_headers, "x-wa-node");
            let public_key = header_of(node_headers, "x-wa-pub");
            let ts = header_of(node_headers, "x-wa-ts");
            let signature = header_of(node_headers, "x-wa-sig");
            (200, "application/json", call("wa_node_call", &[body, &from, &public_key, &ts, &signature]).into_bytes())
        }
        "/envelope" => (200, "application/json", call("wa_envelope", &[session]).into_bytes()),
        "/tools" => (200, "application/json", call("wa_tools", &[session]).into_bytes()),
        "/skills" => (200, "application/json", call("wa_skills", &[session]).into_bytes()),
        "/nodes" => (200, "application/json", call("wa_nodes", &[session]).into_bytes()),
        "/node/name" if method == "POST" => (200, "application/json", call("wa_set_node_name", &[body, session]).into_bytes()),
        "/sessions" => (200, "application/json", call("wa_sessions", &[session]).into_bytes()),
        "/session" => (200, "application/json", call("wa_session", &[query_value(&query, "id").as_str(), session]).into_bytes()),
        "/session/mode" if method == "POST" => (200, "application/json", call("wa_session_mode", &[body, session]).into_bytes()),
        "/session/fixture" => (200, "application/json", call("wa_session_fixture", &[query_value(&query, "id").as_str(), session]).into_bytes()),
        // A turn's changed files: "can it be undone?" and "do it", one route so the answer
        // the toggle shows and the handler's behaviour cannot disagree.
        "/diff" if method == "POST" => (200, "application/json", call("wa_diff", &[body.trim(), session]).into_bytes()),
        "/client" if method == "POST" => (200, "application/json", call("wa_client", &[body, session]).into_bytes()),
        "/frame" if method == "POST" => (200, "application/json", call("wa_frame", &[body.trim(), session]).into_bytes()),
        "/spells" => (200, "application/json", call("wa_spells", &[session]).into_bytes()),
        // Export a spell as a portable plan for the sentinel. A separate route from /spell because
        // it writes nothing to the node's behaviour and reads nothing about a run - it produces a
        // file for *another process*, and the two must not be confusable.
        "/spell/export" if method == "POST" => (200, "application/json", call("wa_spell_export", &[body.trim(), session]).into_bytes()),
        "/spell" if method == "POST" => (200, "application/json", call("wa_spell_run", &[body.trim(), session]).into_bytes()),
        "/provider" if method == "POST" => (200, "application/json", call("wa_set_provider", &[body.trim(), node.as_str(), session]).into_bytes()),
        "/model" if method == "POST" => (200, "application/json", call("wa_set_model", &[body.trim(), node.as_str(), session]).into_bytes()),
        "/chat" if method == "POST" => (200, "application/json", call("wa_reply", &[body, session, node.as_str()]).into_bytes()),
        _ => {
            if route == "/chat" || route == "/node/chat" {
                return None; // streaming
            }
            let relative = if route == "/" || route.is_empty() {
                "index.html".to_string()
            } else {
                route.trim_start_matches('/').to_string()
            };
            if relative.contains("..") {
                return Some((400, "text/plain", b"bad path".to_vec()));
            }
            return match std::fs::read(ui.join(&relative)) {
                Ok(bytes) => Some((200, content_type(&relative), bytes)),
                Err(_) => Some((404, "text/plain; charset=utf-8", b"not found".to_vec())),
            };
        }
    };
    Some(reply)
}

fn respond(stream: &mut TcpStream, status: u16, content_type: &str, body: &[u8]) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        403 => "Forbidden",
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
