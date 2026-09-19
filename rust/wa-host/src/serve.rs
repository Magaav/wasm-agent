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

/// When a UI page last asked this node for anything.
///
/// The page polls `/version` once a second for as long as it is alive - it is the one loop that always runs,
/// because it is also the reload path. So the age of this timestamp answers a question nothing else could:
/// **is the window still rendering?**
///
/// That question is the difference between "the window is fine" and the failure that cost an afternoon: a
/// shell whose event loop had panicked kept answering IPC (`delivered=true`) while its page was gone, so
/// every command was accepted and nothing happened. `/health` looked healthy throughout, because a node
/// cannot see a window's event loop - but it can see that nobody is asking it for the version any more.
/// A reader that has a connected window *and* a stale page age has a zombie, not a window.
static UI_SEEN_MS: AtomicU64 = AtomicU64::new(0);

/// The last thing the UI page said about its own failure, and when.
///
/// A page that cannot run cannot tell anyone it cannot run - which is how a window sat looking alive with a
/// dead page behind it while every command was accepted and ignored. So the page reports its own errors here
/// (the inline reporter in index.html runs before anything else), and this is what makes that visible: a node
/// that can say "the UI reported this at 12:04" is a node whose window can be diagnosed without a log dive.
static UI_ERROR: Mutex<Option<(String, u64)>> = Mutex::new(None);

/// How many interpreters a node runs, and how it decides.
///
/// Worker 0 is the turn worker and always exists: it owns every route that changes something - turns,
/// writes, sync, node calls - so "one writer per session" and per-session order hold by construction
/// rather than by locking.
///
/// The read workers are **hot-swappable**. There is no fixed pool to configure: a read worker is spawned at
/// the moment a read would otherwise wait behind a busy worker 0, and it retires itself once it has been
/// idle long enough. An idle node therefore runs exactly one interpreter and costs exactly what it did
/// before any of this existed; a node under load grows to meet the load and shrinks back. That also settles
/// the question a fixed pool raises and cannot answer - how many is right - by not answering it in advance.
///
/// `WASM_AGENT_WORKERS` is how many read workers to keep *warm* (default 0: spawn on demand),
/// `WASM_AGENT_WORKERS_MAX` is the ceiling (default 4), and `WASM_AGENT_WORKERS_IDLE_SECONDS` is how long an
/// idle read worker waits before retiring (default 60).
///
/// The read-route list is a **routing hint, not a source of truth**: a path that is not in it goes to
/// worker 0, which is why a missing entry is a performance question and never a correctness one.
struct Pool {
    /// One slot per possible worker, index 0 first. `None` means that worker is not running. Slots rather
    /// than a list, because a worker retires itself and a list would renumber everyone under it.
    slots: Mutex<Vec<Option<std::sync::mpsc::SyncSender<(TcpStream, Request)>>>>,
    /// Builds a fresh interpreter. It lives here as a boxed closure because the boot sequence belongs to
    /// main.rs - a second copy of it in the pool is how the two would drift.
    factory: Box<dyn Fn() -> Lua + Send + Sync>,
    ui: PathBuf,
    queue_depth: usize,
    /// Counters, so growing and shrinking is observable rather than something you infer from latency.
    spawned: AtomicUsize,
    retired: AtomicUsize,
    next: AtomicUsize,
}

static POOL: OnceLock<Pool> = OnceLock::new();
static WORKER_BEATS: OnceLock<Vec<AtomicU64>> = OnceLock::new();
static WORKER_BUSY: OnceLock<Vec<Mutex<Option<(String, u64)>>>> = OnceLock::new();
/// Which session each worker is currently running, if any.
///
/// This is what makes concurrent *turns* safe. A turn is routed by session: the same session always goes to
/// the worker already running it, so its turns stay ordered and "one writer per session" holds by routing
/// rather than by a lock. A session nobody is running goes to an idle worker - which is the whole point, two
/// conversations at once - and only a session with nowhere to go waits.
static WORKER_SESSION: OnceLock<Vec<Mutex<Option<String>>>> = OnceLock::new();

fn env_usize(name: &str, fallback: usize) -> usize {
    std::env::var(name).ok().and_then(|value| value.parse().ok()).unwrap_or(fallback)
}

fn warm_read_workers() -> usize {
    env_usize("WASM_AGENT_WORKERS", 0)
}

fn max_workers() -> usize {
    env_usize("WASM_AGENT_WORKERS_MAX", 4).clamp(1, 16)
}

fn read_idle_seconds() -> u64 {
    env_usize("WASM_AGENT_WORKERS_IDLE_SECONDS", 60) as u64
}

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
            | "/memories" | "/status" | "/spells" | "/sync" | "/toolchain" | "/turns" | "/observability/events"
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
        Some(slot) => {
            let beat = slot.load(Ordering::Relaxed);
            // Never beaten: the worker has just been created, which is not the same as having gone quiet. A
            // worker that was spawned a moment ago must not be refused as if it had been silent for a
            // minute - which is exactly what happened the first time the pool grew, because "no beat" read
            // as "as old as the process". Each worker beats at the top of its own loop, so this lasts
            // microseconds and the detector keeps its teeth for a worker that *stops* reporting.
            if beat == u64::MAX {
                0
            } else {
                now.saturating_sub(beat)
            }
        }
        None => now.saturating_sub(BEAT_MS.load(Ordering::Relaxed)),
    }
}

fn live_worker_ids() -> Vec<usize> {
    match POOL.get().and_then(|pool| pool.slots.lock().ok().map(|slots| {
        slots
            .iter()
            .enumerate()
            .filter(|(_, slot)| slot.is_some())
            .map(|(index, _)| index)
            .collect::<Vec<usize>>()
    })) {
        Some(ids) if !ids.is_empty() => ids,
        _ => vec![0],
    }
}

fn worker_count() -> usize {
    match POOL.get() {
        Some(pool) => pool
            .slots
            .lock()
            .map(|slots| slots.iter().filter(|slot| slot.is_some()).count())
            .unwrap_or(1)
            .max(1),
        None => 1,
    }
}

/// The label a worker is currently busy with, if any. This is how the dispatcher asks "is the turn worker
/// idle?" without holding the interpreter or guessing from a timestamp.
fn worker_busy_label(index: usize) -> Option<String> {
    WORKER_BUSY
        .get()
        .and_then(|slots| slots.get(index))
        .and_then(|slot| slot.lock().ok().and_then(|guard| guard.clone()))
        .map(|(label, _)| label)
}

/// Start one more read worker, and return its index. Called while holding the slots lock.
///
/// The interpreter is built *before* the lock is taken in spirit but inside it in practice, which is why
/// the caller must not be a hot path: this happens once per growth, not once per request.
fn spawn_worker(slots: &mut Vec<Option<std::sync::mpsc::SyncSender<(TcpStream, Request)>>>) -> Option<usize> {
    let pool = POOL.get()?;
    let index = slots.iter().position(|slot| slot.is_none()).unwrap_or(slots.len());
    if index >= max_workers() + 1 {
        return None;
    }
    let state = (pool.factory)();
    let (sender, receiver) = std::sync::mpsc::sync_channel::<(TcpStream, Request)>(pool.queue_depth);
    if index == slots.len() {
        slots.push(Some(sender));
    } else {
        slots[index] = Some(sender);
    }
    let worker_ui = pool.ui.clone();
    pool.spawned.fetch_add(1, Ordering::Relaxed);
    std::thread::spawn(move || {
        WORKER_ID.with(|cell| cell.set(index));
        worker_loop(state, index, receiver, worker_ui);
    });
    Some(index)
}

/// Is the turn worker free to take a request right now?
///
/// Idle means *both*: nothing in its hands, and it has reported progress recently. A worker that is not
/// beating is not idle, whatever its label says - which is the case that matters, because a wedged turn
/// worker must not be handed more work, and a read must not be told the node is fine when it is not.
fn turn_worker_is_idle() -> bool {
    if worker_busy_label(0).is_some() {
        return false;
    }
    match WORKER_BEATS.get().and_then(|beats| beats.get(0)) {
        // Never beaten: the process has just started, which is not the same as busy.
        Some(slot) if slot.load(Ordering::Relaxed) == u64::MAX => true,
        _ => worker_age_ms(0) < 1000,
    }
}

/// A turn: the one route that is routed by session rather than pinned to worker 0.
fn is_turn_route(request: &Request) -> bool {
    request.method == "POST" && split_path(&request.path).0 == "/chat"
}

/// The worker already running this session, if any. That worker is where the next turn for it belongs, so
/// the session keeps one writer and its turns keep their order.
fn worker_running_session(session: &str) -> Option<usize> {
    if session.is_empty() {
        return None;
    }
    let slots = WORKER_SESSION.get()?;
    for (index, slot) in slots.iter().enumerate() {
        let held = slot.lock().ok().and_then(|guard| guard.clone());
        if held.as_deref() == Some(session) {
            return Some(index);
        }
    }
    None
}

/// The first worker doing nothing at all, for a session nobody is running.
///
/// Takes the slots lock itself, so it must be called *before* the caller takes it: `std::sync::Mutex` is not
/// reentrant, and the first version of this called it while already holding that lock.
fn idle_worker() -> Option<usize> {
    let beats = WORKER_BEATS.get()?;
    let slots = POOL.get()?.slots.lock().ok()?;
    for (index, slot) in slots.iter().enumerate() {
        if slot.is_none() || worker_busy_label(index).is_some() {
            continue;
        }
        let beaten = beats.get(index).map(|b| b.load(Ordering::Relaxed) != u64::MAX).unwrap_or(false);
        if beaten && worker_age_ms(index) < 1000 {
            return Some(index);
        }
    }
    None
}

/// Which worker a request goes to, growing the pool if that is what it takes.
fn choose_worker(request: &Request) -> usize {
    let Some(pool) = POOL.get() else { return 0 };
    // A turn first, because it is the one route with a rule of its own: routed by session, so two different
    // conversations run at once and one conversation never does.
    if is_turn_route(request) {
        if let Some(index) = worker_running_session(&request.session) {
            return index;
        }
        if let Some(index) = idle_worker() {
            return index;
        }
        if let Ok(mut slots) = pool.slots.lock() {
            if let Some(index) = spawn_worker(&mut slots) {
                return index;
            }
        }
        // Nowhere to go: the turn waits behind worker 0, which is what a node with one interpreter always did.
        return 0;
    }
    let read = is_read_route(request);
    // Nothing to gain while the turn worker is idle - for a read as much as for a write. This is the rule
    // that keeps an idle node at exactly one interpreter, and it is also why a read does not spawn a worker
    // that would then sit there doing nothing: the pool appears only when a request would otherwise wait.
    if turn_worker_is_idle() {
        return 0;
    }
    let Ok(mut slots) = pool.slots.lock() else { return 0 };
    // Only reads may go to a read worker. A write goes to worker 0 even when read workers exist, because
    // that is the whole reason one writer per session holds without a lock - and the first version of this
    // returned a read worker for a write, which the test caught by getting a 200 where it expected the
    // stalled worker's 503.
    if !read {
        return 0;
    }
    let live: Vec<usize> = (1..slots.len()).filter(|index| slots[*index].is_some()).collect();
    if !live.is_empty() {
        let start = pool.next.fetch_add(1, Ordering::Relaxed);
        return live[start % live.len()];
    }
    // A read, the turn worker is busy, and there is no read worker: this is the moment the pool earns its
    // keep. Everything else waits, which is what a node with one interpreter has always done.
    if let Some(index) = spawn_worker(&mut slots) {
        return index;
    }
    0
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
        let owner = worker_id();
        std::thread::spawn(move || {
            // Thread-local state does not inherit across spawn. Without this a
            // request on worker 1 beats worker 0, hiding a real stall and inventing another.
            WORKER_ID.with(|cell| cell.set(owner));
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
    // The aggregate answers one question: *can this node do work?* Work happens on worker 0 - turns and
    // every route that changes something - so the aggregate is worker 0's age, and a wedged turn worker is
    // still reported as the node being stalled even while a read worker answers reads. Which lane is wedged
    // is a per-worker question, answered by the array below.
    let age_ms = worker_age_ms(0);
    let stalled = age_ms >= stall_seconds() * 1000;
    let state = if stalled { "stalled" } else if age_ms < 1000 { "alive" } else { "busy" };
    let mut current = IN_FLIGHT.lock().ok().and_then(|slot| {
        slot.as_ref().map(|(label, started)| {
            serde_json::json!({ "label": label, "ms": now_ms().saturating_sub(*started) })
        })
    });
    // Per-worker detail, so "which one is busy, and with what" is answerable without reading a log. The
    // aggregate fields above are kept exactly as they were: the window and the sentinel read them, and a
    // new field must not move an old one.
    let mut workers = Vec::new();
    if let Some(pool) = POOL.get() {
        if let Ok(slots) = pool.slots.lock() {
            for (index, slot) in slots.iter().enumerate() {
                if slot.is_none() {
                    continue;
                }
                let age = worker_age_ms(index);
                let busy = WORKER_BUSY
                    .get()
                    .and_then(|slots| slots.get(index))
                    .and_then(|slot| slot.lock().ok().and_then(|guard| guard.clone()));
                let turn = busy.as_ref().is_some_and(|(label, _)| label.starts_with("POST /chat"));
                if current.is_none() && turn {
                    if let Some((label, started)) = &busy {
                        current = Some(serde_json::json!({"label":label,"ms":now_ms().saturating_sub(*started),"worker_id":index}));
                    }
                }
                workers.push(serde_json::json!({
                    "id": index,
                    "role": if index == 0 || turn { "turns" } else { "reads" },
                    "session": WORKER_SESSION.get().and_then(|slots| slots.get(index)).and_then(|slot| slot.lock().ok().and_then(|guard| guard.clone())),
                    "state": if age >= stall_seconds() * 1000 { "stalled" } else if age < 1000 { "alive" } else { "busy" },
                    "age_ms": age,
                    "busy_ms": busy.as_ref().map(|(_, started)| now_ms().saturating_sub(*started)),
                    "label": busy.as_ref().map(|(label, _)| label.clone()),
                }));
            }
        }
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
        "workers_spawned": POOL.get().map(|pool| pool.spawned.load(Ordering::Relaxed)).unwrap_or(0),
        "workers_retired": POOL.get().map(|pool| pool.retired.load(Ordering::Relaxed)).unwrap_or(0),
        // Milliseconds since a UI page last polled. `null` means no page has ever asked - a node that has
        // never been opened, which is not the same as one whose window has died.
        "ui_error": UI_ERROR.lock().ok().and_then(|slot| slot.as_ref().map(|(text, _)| text.clone())),
        "ui_error_age_ms": UI_ERROR.lock().ok().and_then(|slot| slot.as_ref().map(|(_, at)| now_ms().saturating_sub(*at))),
        "ui_page_age_ms": match UI_SEEN_MS.load(Ordering::Relaxed) {
            0 => serde_json::Value::Null,
            seen => serde_json::json!(now_ms().saturating_sub(seen)),
        },
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

pub fn run(first: Lua, factory: Box<dyn Fn() -> Lua + Send + Sync>, port: u16, ui: PathBuf) {
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("[serve] bind 127.0.0.1:{port} failed: {error}");
            return;
        }
    };
    let ceiling = max_workers();
    let warm = warm_read_workers().min(ceiling);
    let queue_depth = env_usize("WASM_AGENT_QUEUE_DEPTH", 256);
    // Sized to the ceiling once, so a worker's liveness slot never has to be created later: the arrays are
    // indexed by worker id, and a slot whose sender is None is simply not running.
    // u64::MAX, not 0, for "never beaten": a worker beats at the top of its own loop, which can happen
    // inside the first millisecond of the process, so 0 would be ambiguous between "never" and "at time 0".
    let _ = WORKER_BEATS.set((0..=ceiling).map(|_| AtomicU64::new(u64::MAX)).collect());
    let _ = WORKER_BUSY.set((0..=ceiling).map(|_| Mutex::new(None)).collect());
    let _ = WORKER_SESSION.set((0..=ceiling).map(|_| Mutex::new(None)).collect());
    let _ = POOL.set(Pool {
        slots: Mutex::new(Vec::new()),
        factory,
        ui: ui.clone(),
        queue_depth,
        spawned: AtomicUsize::new(0),
        retired: AtomicUsize::new(0),
        next: AtomicUsize::new(0),
    });
    let pool = POOL.get().expect("pool");

    // Worker 0, always: the turn worker. It is the state main.rs already booted, so a node that never
    // grows a read worker boots exactly one interpreter, as it always did.
    let (sender, receiver) = std::sync::mpsc::sync_channel::<(TcpStream, Request)>(queue_depth);
    if let Ok(mut slots) = pool.slots.lock() {
        slots.push(Some(sender));
    }
    let worker_ui = ui.clone();
    std::thread::spawn(move || {
        WORKER_ID.with(|cell| cell.set(0));
        worker_loop(first, 0, receiver, worker_ui);
    });
    // Read workers only if asked for: the point of the pool is to appear when a read would otherwise wait,
    // so the default is to have none until that happens.
    for _ in 0..warm {
        if let Ok(mut slots) = pool.slots.lock() {
            spawn_worker(&mut slots);
        }
    }
    eprintln!(
        "[serve] one turn worker{} (reads: {warm} warm, up to {ceiling}, spawned on demand)",
        if warm == 0 { String::new() } else { format!(" + {warm} read worker(s)") }
    );
    // A node whose ui directory has no index.html serves 404 for every UI route and looks healthy doing
    // it - the failure that made a window show "not found" for an afternoon. It says so at startup instead,
    // once, where whoever started it will see it.
    if !ui.join("index.html").exists() {
        eprintln!(
            "[serve] WARNING: no index.html in {} - this node cannot serve its UI and will answer 404 for /
[serve] (on Windows a POSIX path here is the usual cause: pass a Windows path)",
            ui.display()
        );
    }
    eprintln!("[serve] wasm-agent UI at http://127.0.0.1:{port}  (ui: {})", ui.display());

    if let Ok(relay_url) = std::env::var("WASM_AGENT_RELAY") {
        if !relay_url.is_empty() {
            crate::relay_client::spawn(relay_url);
        }
    }

    // Each worker owns an interpreter and reads its own queue, so requests still run one at a time *per
    // interpreter* - what changed is that a running turn no longer stops the node answering anything at all.
    // `/health`, `/version` and the UI files were already answered on the accept thread; the reads that need
    // Lua (sessions, models, nodes) now have an interpreter of their own, created when they need one.
    //
    // Bounded on purpose: an unbounded queue turns a busy node into an unbounded number of open sockets,
    // and the accept thread can then only fail it loudly.

    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        let request = match read_request(&mut stream) {
            Ok(Some(request)) => request,
            _ => continue,
        };
        // The page's own heartbeat, recorded where every request passes - including the ones the accept
        // thread answers itself, because `/version` is one of those and it is exactly the request that says
        // the page is alive.
        if split_path(&request.path).0 == "/version" {
            UI_SEEN_MS.store(now_ms(), Ordering::Relaxed);
        }
        if let Some((status, content_type, body)) = static_reply(&ui, &request) {
            let _ = respond(&mut stream, status, content_type, &body);
            continue;
        }
        // Which interpreter this request needs - and if that is a read arriving while the turn worker is
        // busy, this is the call that grows the pool. Anything that changes something goes to worker 0,
        // which is what keeps one writer per session true by construction.
        let target = choose_worker(&request);
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
            // Exit only when *every* worker that is running is stalled: a wedged lane must not take the
            // healthy ones with it, and with a single interpreter this is exactly the old behaviour.
            let all_stalled = live_worker_ids()
                .iter()
                .all(|index| worker_age_ms(*index) >= stall_exit_seconds() * 1000);
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
        // A worker can retire between being chosen and being sent to, so the send is attempted against the
        // slot's current sender and falls back to worker 0. `try_send` hands the request back on failure,
        // which is what makes the retry possible rather than a lost request.
        let mut attempt = 0;
        let mut target = target;
        let mut pending = Some((stream, request));
        loop {
            let sender = POOL
                .get()
                .and_then(|pool| pool.slots.lock().ok().and_then(|slots| slots.get(target).cloned().flatten()));
            let (mut stream, request) = match pending.take() {
                Some(pair) => pair,
                None => break,
            };
            let sender = match sender {
                Some(sender) => sender,
                None => {
                    // The worker is gone (retired). Worker 0 always exists, so it is the honest fallback.
                    if target != 0 && attempt < 2 {
                        attempt += 1;
                        target = 0;
                        pending = Some((stream, request));
                        continue;
                    }
                    QUEUED.fetch_sub(1, Ordering::Relaxed);
                    let body = b"{\"error\":\"node_busy\",\"hint\":\"the node is answering other requests; retry shortly\"}";
                    let _ = respond(&mut stream, 503, "application/json", body);
                    break;
                }
            };
            match sender.try_send((stream, request)) {
                Ok(()) => break,
                Err(std::sync::mpsc::TrySendError::Full((mut stream, _request))) => {
                    QUEUED.fetch_sub(1, Ordering::Relaxed);
                    // A bounded queue: refusing loudly beats an unbounded backlog that every client waits in.
                    let body = b"{\"error\":\"node_busy\",\"hint\":\"the node is answering other requests; retry shortly\"}";
                    let _ = respond(&mut stream, 503, "application/json", body);
                    break;
                }
                Err(std::sync::mpsc::TrySendError::Disconnected(pair)) => {
                    // Retired while this request was on its way. Try worker 0 once, then refuse.
                    if target != 0 && attempt < 2 {
                        attempt += 1;
                        target = 0;
                        pending = Some(pair);
                        continue;
                    }
                    QUEUED.fetch_sub(1, Ordering::Relaxed);
                    let (mut stream, _request) = pair;
                    let body = b"{\"error\":\"node_busy\",\"hint\":\"the node is answering other requests; retry shortly\"}";
                    let _ = respond(&mut stream, 503, "application/json", body);
                    break;
                }
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
    let mut idle_since = std::time::Instant::now();
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
                // Which session this worker holds, so a second turn in the same session finds it and queues
                // behind it instead of starting a second writer on the same conversation.
                if let Some(slots) = WORKER_SESSION.get() {
                    if let Some(slot) = slots.get(index) {
                        if let Ok(mut guard) = slot.lock() {
                            *guard = if request.session.is_empty() { None } else { Some(request.session.clone()) };
                        }
                    }
                }
                let _ = handle(&lua, &agent_ui, &mut stream, &request);
                if let Some(slots) = WORKER_SESSION.get() {
                    if let Some(slot) = slots.get(index) {
                        if let Ok(mut guard) = slot.lock() {
                            *guard = None;
                        }
                    }
                }
                end_work();
                beat();
                idle_since = std::time::Instant::now();
                continue;
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
        }
        if index != 0 {
            // A read worker retires itself once it has been idle long enough and the pool is above the warm
            // minimum. Two things make that safe: it clears its own slot *before* returning, so the
            // dispatcher stops choosing it, and a request already on its way to a retired worker is not
            // lost - `try_send` reports Disconnected and the accept thread retries on worker 0.
            if idle_since.elapsed().as_secs() >= read_idle_seconds() && worker_count() > warm_read_workers() + 1 {
                if let Some(pool) = POOL.get() {
                    if let Ok(mut slots) = pool.slots.lock() {
                        if slots.get(index).is_some() {
                            slots[index] = None;
                            pool.retired.fetch_add(1, Ordering::Relaxed);
                            eprintln!("[serve] read worker {index} retired after {}s idle", idle_since.elapsed().as_secs());
                        }
                    }
                }
                return;
            }
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
    if route == "/log" {
        // Best effort by design: the page is already in trouble when it calls this, and a reporter that can
        // fail loudly is worse than one that quietly records. The node log gets it too, so it is visible
        // while it is happening and not only afterwards.
        let text = String::from_utf8_lossy(&request.body).chars().take(2000).collect::<String>();
        if !text.trim().is_empty() {
            eprintln!("[ui] page reported: {text}");
            if let Ok(mut slot) = UI_ERROR.lock() {
                *slot = Some((text, now_ms()));
            }
        }
        return Some((200, "application/json", b"{\"ok\":true}".to_vec()));
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
        "/models" => (200, "application/json", call("wa_model", &[node.as_str(), session, &query_value(&query,"session_id")]).into_bytes()),
        "/observability/events" => (200,"application/json",call("wa_observability_events",&[&query_value(&query,"id"),&query_value(&query,"cursor"),&query_value(&query,"since"),session,node.as_str()]).into_bytes()),
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
        "/spell" if method == "POST" => (200, "application/json", call("wa_spell_run", &[body.trim(), session]).into_bytes()),
        "/provider" if method == "POST" => (200, "application/json", call("wa_set_provider", &[body.trim(), node.as_str(), session]).into_bytes()),
        "/model" if method == "POST" => (200, "application/json", call("wa_set_model", &[body.trim(), node.as_str(), session]).into_bytes()),
        "/reasoning" if method == "POST" => (200,"application/json",call("wa_set_reasoning",&[body.trim(),node.as_str(),session]).into_bytes()),
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
