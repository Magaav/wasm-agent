//! Tiny local web UI plus the node's inbound surface.
//!
//! Two threads, with one job each. The accept thread answers everything that needs
//! no interpreter - `/health`, `/version`, and the UI files - and forwards the rest
//! to the agent thread, which owns the Lua state and runs requests one at a time
//! (the interpreter is not thread-safe, so that serialisation is required, not a
//! choice).
//!
//! The split exists because a single thread made the node deaf to its own UI while
//! a run was running: `POST /chat` holds its connection for a whole run, so the
//! window's fetches queued behind a model call, Chromium gave up, and the user saw
//! "TypeError: Failed to fetch" from a node that was local and alive. Reloading
//! could not help either - the reload needed the same busy thread.
//!
//! Two things feed the agent thread: sockets, and - when attached to a relay -
//! requests the relay hands us (`relay_client`). Both end up in `dispatch`, so a
//! node behaves identically whether it is reached directly or through the relay.
use crate::lua::Lua;
use std::cell::RefCell;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

mod scheduler;
mod journal;

/// Milliseconds since the process started, written by anything that is making
/// progress: every event the node-thread emits, and every run or tool boundary the Lua loop
/// reports through host.beat.
///
/// This is the only way to tell a slow run from a wedged node. A wedged node answers
/// /health perfectly (that reply needs no interpreter) and holds its listening socket,
/// so from outside it looks idle rather than stuck. If this stops moving, the
/// interpreter is not running anything, and that is a fact worth reporting.
static BEAT_MS: AtomicU64 = AtomicU64::new(0);
static STARTED: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
/// Rate-limits the "the node-thread is stalled" line so a wedged node cannot fill a log.
static STALL_LOGGED_MS: AtomicU64 = AtomicU64::new(0);

/// What the node-thread is doing right now, as (label, started_ms). A stall is only
/// diagnosable if it says *what* it is stuck on: a local run, a relayed peer request, or
/// housekeeping are three different bugs with one symptom.
static IN_FLIGHT: Mutex<Option<(String, u64)>> = Mutex::new(None);
/// Requests waiting for the node-thread. Housekeeping waits until this is zero.
static QUEUED: AtomicUsize = AtomicUsize::new(0);
// A non-run request reserves its destination before enqueue. Busy labels alone
// leave a gap between selection and dequeue, admitting a burst behind one read.
static READ_RESERVED: OnceLock<Vec<AtomicBool>> = OnceLock::new();
fn read_reservations() -> &'static Vec<AtomicBool> {
    READ_RESERVED.get_or_init(|| (0..=max_node_threads()).map(|_| AtomicBool::new(false)).collect())
}
fn release_read_destination(index: usize) {
    if let Some(slot) = read_reservations().get(index) { slot.store(false, Ordering::Release); }
}
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

/// Replay window for an active run after its browser connection goes away. Events through the latest
/// transcript checkpoint are already recoverable from the session ledger, so only the unsaved tail is
/// retained here. This is process memory and is discarded as soon as the run settles.
const RUN_EVENT_REPLAY_BYTES: usize = 4 * 1024 * 1024;
static RUN_EVENTS: OnceLock<Mutex<std::collections::HashMap<u64, RunEventLog>>> = OnceLock::new();

#[derive(Default)]
struct RunEventLog {
    next_seq: u64,
    checkpoint_seq: u64,
    checkpoint_message_seq: u64,
    events: Vec<(u64, serde_json::Value)>,
    bytes: usize,
    overflow: bool,
}

fn run_events() -> &'static Mutex<std::collections::HashMap<u64, RunEventLog>> {
    RUN_EVENTS.get_or_init(|| Mutex::new(std::collections::HashMap::new()))
}

fn begin_run_events(run_id: u64) {
    if let Ok(mut logs) = run_events().lock() {
        logs.insert(run_id, RunEventLog::default());
    }
}

fn finish_run_events(run_id: u64) {
    if let Ok(mut logs) = run_events().lock() {
        logs.remove(&run_id);
    }
}

fn record_run_event(run_id: u64, payload: &str) {
    if let Some(scheduler) = scheduler::global() {
        if scheduler.record_event(run_id,payload).is_err() { return; }
    }
    let Ok(event) = serde_json::from_str::<serde_json::Value>(payload) else { return };
    let Ok(mut logs) = run_events().lock() else { return };
    let Some(log) = logs.get_mut(&run_id) else { return };
    log.next_seq = log.next_seq.saturating_add(1);
    let seq = log.next_seq;
    if event.get("type").and_then(|value| value.as_str()) == Some("checkpoint") {
        log.checkpoint_seq = seq;
        log.checkpoint_message_seq = event.get("seq").and_then(|value| value.as_u64()).unwrap_or(0);
        log.events.clear();
        log.bytes = 0;
        log.overflow = false;
        return;
    }
    if log.overflow { return; }
    let bytes = payload.len();
    if log.bytes.saturating_add(bytes) > RUN_EVENT_REPLAY_BYTES {
        log.events.clear();
        log.bytes = 0;
        log.overflow = true;
        return;
    }
    log.bytes += bytes;
    log.events.push((seq, event));
}

/// How many interpreters a node runs, and how it decides.
///
/// Node-thread 0 is the run node-thread and always exists: it owns every route that changes something - runs,
/// writes, sync, node calls - so "one writer per session" and per-session order hold by construction
/// rather than by locking.
///
/// The read node-threads are **hot-swappable**. There is no fixed pool to configure: a read node-thread is spawned at
/// the moment a read would otherwise wait behind a busy node-thread 0, and it retires itself once it has been
/// idle long enough. An idle node therefore runs exactly one interpreter and costs exactly what it did
/// before any of this existed; a node under load grows to meet the load and shrinks back. That also settles
/// the question a fixed pool raises and cannot answer - how many is right - by not answering it in advance.
///
/// `WASM_AGENT_WORKERS` is how many read node-threads to keep *warm* (default 0: spawn on demand),
/// `WASM_AGENT_WORKERS_MAX` is the ceiling (default 4), and `WASM_AGENT_WORKERS_IDLE_SECONDS` is how long an
/// idle read node-thread waits before retiring (default 60).
///
/// The env var *names* keep the older `WORKER` spelling on purpose: they are the operator's names in
/// `~/.wasm-agent/env`, so renaming one is an operator change and not a code change (see the report).
///
/// The read-route list is a **routing hint, not a source of truth**: a path that is not in it goes to
/// node-thread 0, which is why a missing entry is a performance question and never a correctness one.
struct Pool {
    /// One slot per possible node-thread, index 0 first. `None` means that node-thread is not running. Slots rather
    /// than a list, because a node-thread retires itself and a list would renumber everyone under it.
    slots: Mutex<Vec<Option<std::sync::mpsc::SyncSender<Work>>>>,
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
static NODE_THREAD_BEATS: OnceLock<Vec<AtomicU64>> = OnceLock::new();
static NODE_THREAD_BUSY: OnceLock<Vec<Mutex<Option<(String, u64)>>>> = OnceLock::new();
/// Which session each node-thread is currently running, if any.
///
/// This is what makes concurrent *runs* safe. A run is routed by session: the same session always goes to
/// the node-thread already running it, so its runs stay ordered and "one writer per session" holds by routing
/// rather than by a lock. A session nobody is running goes to an idle node-thread - which is the whole point, two
/// conversations at once - and only a session with nowhere to go waits.
static NODE_THREAD_SESSION: OnceLock<Vec<Mutex<Option<String>>>> = OnceLock::new();
/// The admission id of the run each node-thread is executing right now, if any. `/health` reports it so a
/// run is identifiable by id and not only by the conversation it writes.
static NODE_THREAD_RUN: OnceLock<Vec<Mutex<Option<u64>>>> = OnceLock::new();

/// A deploy launched by a tool in a live run cannot wait for that same run
/// to go idle. This is a boolean, not the x-wa-session credential.
pub(crate) fn in_turn() -> bool {
    IN_RUN.with(|flag| flag.get())
}

#[cfg(test)]
pub(crate) fn test_mark_turn(value: bool) {
    IN_RUN.with(|flag| flag.set(value));
}

fn env_usize(name: &str, fallback: usize) -> usize {
    std::env::var(name).ok().and_then(|value| value.parse().ok()).unwrap_or(fallback)
}

fn warm_read_node_threads() -> usize {
    env_usize("WASM_AGENT_WORKERS", 0)
}

fn max_node_threads() -> usize {
    env_usize("WASM_AGENT_WORKERS_MAX", 4).clamp(1, 16)
}

fn read_idle_seconds() -> u64 {
    env_usize("WASM_AGENT_WORKERS_IDLE_SECONDS", 60) as u64
}

/// How many node-thread slots are reserved for interactive runs. A background run may not use a node-thread
/// with an index below this, so a burst of wakes cannot take the capacity a person's next run needs.
/// Two, not one: the operator requires two concurrent chats even while background work saturates the
/// rest, and node-thread 0 alone cannot both run a chat and absorb a slow mutation.
fn interactive_reserve() -> usize {
    env_usize("WASM_AGENT_INTERACTIVE_RESERVE", 2).clamp(1, 8)
}

/// How many node-thread slots are reserved for the control lane (reads, engine control, `/subagents`).
/// They sit at the *top* of the node-thread index range, above the run lanes, so control work can never
/// occupy an interactive or background run slot and a long `/subagents await` cannot hold a run
/// node-thread. Two by default: one control slot may be blocked in an await while cancel/status/health
/// stay answerable on the other (and `/runs` and `/health` do not use a node-thread at all).
fn control_node_threads() -> usize {
    env_usize("WASM_AGENT_CONTROL_WORKERS", 2).clamp(1, 8)
}

/// The first node-thread index the control lane owns. Run lanes are `0..run_capacity`, control is
/// `run_capacity..=max_node_threads`.
fn control_floor() -> usize {
    run_capacity()
}

/// How many node-threads may serve runs (interactive + background). The control reserve is taken off the
/// top of the index range so the two capacities are independent rather than merely differently
/// prioritised.
fn run_capacity() -> usize {
    (max_node_threads() + 1).saturating_sub(control_node_threads()).max(1)
}

/// Is this a route served by the independent control lane rather than a run or a plain read?
/// `/subagents` is the one that can block for seconds, so it must never use node-thread 0.
fn is_control_route(request: &Request) -> bool {
    let path = split_path(&request.path).0;
    path == "/subagents" || (request.method == "POST" && matches!(path.as_str(), "/provider" | "/model" | "/reasoning"))
}

/// The admission deadline, including queue residence and resolver wait. It never holds the listener.
fn admission_timeout_ms() -> u64 {
    env_usize("WASM_AGENT_ADMISSION_TIMEOUT_MS", 8000) as u64
}

thread_local! {
    /// Which node-thread this thread is. `beat()` is called from inside Lua and had no way to say *which*
    /// interpreter had made progress, so per-node-thread liveness was impossible until this existed.
    static NODE_THREAD_ID: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static CURRENT_RUN_ID: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
    static IN_RUN: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// The cancel flag of the run this thread is executing right now. The runtime's provider reader
    /// and agent loop poll `run_cancel_requested()`, so a cancel request reaches a model call on the
    /// same thread that is blocked in it, without a global lookup and without reaching another run.
    static CURRENT_RUN_CANCEL: RefCell<Option<Arc<AtomicBool>>> = const { RefCell::new(None) };
}

/// Has the owner of the run on this thread requested cancellation?
///
/// This is the serve-side half of cancellation: the runtime node-thread polls it in the provider reader
/// and the agent loop, combined with its own `subagents::cancel_requested()`. It is deliberately
/// per-run: the flag belongs to one admitted run, so cancelling a running run does not also cancel
/// the run queued behind it. A `false` here means "not requested", never "not cancelled" - a run is
/// reported cancelled only after it settles.
pub fn run_cancel_requested() -> bool {
    CURRENT_RUN_CANCEL.with(|cell| {
        cell.borrow().as_ref().map(|flag| flag.load(Ordering::SeqCst)).unwrap_or(false)
    })
}

/// Install (or clear) the current-run cancel flag for this node-thread thread.
fn set_current_run_cancel(flag: Option<Arc<AtomicBool>>) {
    CURRENT_RUN_CANCEL.with(|cell| {
        *cell.borrow_mut() = flag;
    });
}

/// Install (or clear) the whole current-run IO context for this node-thread thread: the run's cancel
/// flag and its own socket slot. The transport registers the socket it connects on into this slot,
/// so a cancel on the accept thread can `shutdown` it and wake a silent provider read at once. The
/// slot belongs to one admitted run, so a later cancel can never close the next queued run's socket.
fn set_current_run_io(
    cancel: Option<Arc<AtomicBool>>,
    sockets: Option<crate::subagents::SocketSlot>,
    owner: String,
) {
    set_current_run_cancel(cancel.clone());
    match cancel {
        Some(cancel) => crate::subagents::enter_task(crate::subagents::TaskContext {
            cancel,
            deadline: None,
            sockets: sockets.unwrap_or_else(|| Arc::new(Mutex::new(Vec::new()))),
            owner,
            // This thread is serving a run of a session - the class of process that owns the
            // integration decision, and the one `.githooks/pre-commit` lets move `main`.
            provenance: crate::subagents::Provenance::Orchestrator,
        }),
        None => crate::subagents::leave_task(),
    }
}

pub(crate) fn node_thread_id() -> usize {
    NODE_THREAD_ID.with(|cell| cell.get())
}

/// Is this a route that only reads, and may therefore be served by a read node-thread instead of node-thread
/// 0? A GET always is; the controls named below are POSTs answered by runtimes that hold no agent
/// state. The rest of the method space is a write and stays pinned to node-thread 0.
fn is_read_route(request: &Request) -> bool {
    // These controls use independent synchronized runtimes, never agent state. A blocked run must
    // not queue its own cancellation or the operator's disable behind itself.
    if matches!(split_path(&request.path).0.as_str(), "/jobs" | "/operations" | "/operation") {return true;}
    // A GET is a read, by default. This was an allow-list, and that was backwards: a route nobody
    // remembered to add fell through to node-thread 0 and queued behind whatever run held it. It cost
    // several incidents - `/sync/head`, `/tools`, and `/efficiency` - and each looked like the node
    // being wedged: with a run in flight, `/health` answered in 2ms while `GET /tools` returned no
    // bytes within 6s, the page's fetches filled the browser's connection pool, its own heartbeat
    // could not get through, and the window reloaded it in a loop. A rule that cannot rot is the
    // HTTP one: a GET does not change state, so node-thread 0's one-writer guarantee does not apply to it
    // and a read node-thread may always answer. A new read route is correct without anyone adding it here.
    request.method == "GET"
}

/// Milliseconds since a particular node-thread last reported progress. A node-thread that has never beaten is as
/// old as the process, which is not a stall - the same rule the aggregate age uses.
fn node_thread_age_ms(index: usize) -> u64 {
    let started = match STARTED.get() {
        Some(started) => started,
        None => return 0,
    };
    let now = started.elapsed().as_millis() as u64;
    match NODE_THREAD_BEATS.get().and_then(|beats| beats.get(index)) {
        Some(slot) => {
            let beat = slot.load(Ordering::Relaxed);
            // Never beaten: the node-thread has just been created, which is not the same as having gone quiet. A
            // node-thread that was spawned a moment ago must not be refused as if it had been silent for a
            // minute - which is exactly what happened the first time the pool grew, because "no beat" read
            // as "as old as the process". Each node-thread beats at the top of its own loop, so this lasts
            // microseconds and the detector keeps its teeth for a node-thread that *stops* reporting.
            if beat == u64::MAX {
                0
            } else {
                now.saturating_sub(beat)
            }
        }
        None => now.saturating_sub(BEAT_MS.load(Ordering::Relaxed)),
    }
}

/// Has this node-thread gone quiet long enough that handing it work is a lie?
///
/// A wedged node-thread is not idle. Routing a fresh read to one is how a healthy node answered
/// `503 node_thread_stalled` for a plain `/sessions` - the request inherited a stall that belonged to the
/// dead node-thread the slot used to hold. Selection must treat a stalled slot as unavailable, so a request
/// lands on a live node-thread or grows a new one instead of inheriting someone else's stall.
fn node_thread_is_wedged(index: usize) -> bool {
    node_thread_age_ms(index) >= stall_seconds() * 1000
}

fn live_node_thread_ids() -> Vec<usize> {
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

fn node_thread_count() -> usize {
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

/// The label a node-thread is currently busy with, if any. This is how the dispatcher asks "is the run node-thread
/// idle?" without holding the interpreter or guessing from a timestamp.
fn node_thread_busy_label(index: usize) -> Option<String> {
    NODE_THREAD_BUSY
        .get()
        .and_then(|slots| slots.get(index))
        .and_then(|slot| slot.lock().ok().and_then(|guard| guard.clone()))
        .map(|(label, _)| label)
}

/// The conversation a node-thread holds, if any. `/health` reports it, and the window uses it to
/// scope an in-flight run to its own conversation instead of assuming any chat run is its own.
fn node_thread_session(index: usize) -> Option<String> {
    NODE_THREAD_SESSION
        .get()
        .and_then(|slots| slots.get(index))
        .and_then(|slot| slot.lock().ok().and_then(|guard| guard.clone()))
}

/// The admission id a node-thread is running, if any.
fn node_thread_run_id(index: usize) -> Option<u64> {
    NODE_THREAD_RUN
        .get()
        .and_then(|slots| slots.get(index))
        .and_then(|slot| slot.lock().ok().and_then(|guard| *guard))
}

/// Start one more read node-thread, and return its index. Called while holding the slots lock.
///
/// The interpreter is built *before* the lock is taken in spirit but inside it in practice, which is why
/// the caller must not be a hot path: this happens once per growth, not once per request.
fn spawn_node_thread(slots: &mut Vec<Option<std::sync::mpsc::SyncSender<Work>>>, min_index: usize, max_index: usize) -> Option<usize> {
    let pool = POOL.get()?;
    // `min_index`/`max_index` keep a spawned node-thread inside its lane. Background work starts at the
    // interactive reserve, and run node-threads stop below the control floor; gaps are `None`, which is
    // exactly what an unused slot is.
    let index = (min_index..slots.len().min(max_index + 1))
        .find(|index| slots[*index].is_none())
        .unwrap_or_else(|| slots.len().max(min_index));
    if index > max_index {
        return None;
    }
    let state = (pool.factory)();
    let (sender, receiver) = std::sync::mpsc::sync_channel::<Work>(pool.queue_depth);
    while slots.len() <= index {
        slots.push(None);
    }
    // A retired node-thread's last beat, label and conversation survive in these slots, keyed by index. A
    // replacement is spawned into the *same* index (the first empty slot), so without this reset it
    // inherits the dead node-thread's age: the dispatcher reads a `stalled_ms` from before the new node-thread
    // existed and answers `503 node_thread_stalled` for a node-thread that has simply not had time to beat yet.
    // Reset every per-index fact before publishing the new sender, so nothing can observe the new node-thread
    // through the old one's state.
    if let Some(beats) = NODE_THREAD_BEATS.get() {
        if let Some(slot) = beats.get(index) { slot.store(u64::MAX, Ordering::Relaxed); }
    }
    if let Some(busy) = NODE_THREAD_BUSY.get() {
        if let Some(slot) = busy.get(index) { if let Ok(mut guard) = slot.lock() { *guard = None; } }
    }
    if let Some(sessions) = NODE_THREAD_SESSION.get() {
        if let Some(slot) = sessions.get(index) { if let Ok(mut guard) = slot.lock() { *guard = None; } }
    }
    if let Some(runs) = NODE_THREAD_RUN.get() {
        if let Some(slot) = runs.get(index) { if let Ok(mut guard) = slot.lock() { *guard = None; } }
    }
    slots[index] = Some(sender);
    let node_thread_ui = pool.ui.clone();
    pool.spawned.fetch_add(1, Ordering::Relaxed);
    std::thread::spawn(move || {
        NODE_THREAD_ID.with(|cell| cell.set(index));
        node_thread_loop(state, index, receiver, node_thread_ui);
    });
    Some(index)
}

/// Is the run node-thread free to take a request right now?
///
/// Idle means *both*: nothing in its hands, and it has reported progress recently. A node-thread that is not
/// beating is not idle, whatever its label says - which is the case that matters, because a wedged run
/// node-thread must not be handed more work, and a read must not be told the node is fine when it is not.
fn turn_node_thread_is_idle() -> bool {
    if node_thread_busy_label(0).is_some() {
        return false;
    }
    match NODE_THREAD_BEATS.get().and_then(|beats| beats.get(0)) {
        // Never beaten: the process has just started, which is not the same as busy.
        Some(slot) if slot.load(Ordering::Relaxed) == u64::MAX => true,
        _ => node_thread_age_ms(0) < 1000,
    }
}

/// A run: the routes that execute a model turn and therefore go through admission. `/chat` is a local
/// run; `/node/chat` is a peer run and shares the same admission rather than bypassing it.
fn is_run_route(request: &Request) -> bool {
    request.method == "POST" && matches!(split_path(&request.path).0.as_str(), "/chat" | "/node/chat")
}

/// Choose a node-thread for a run. `class` picks the lane and `claimed` are node-threads already reserved by
/// another admitted run, so a node-thread reserved for a run that has not started is not offered twice.
///
/// Node-thread 0 and node-thread 1 are the interactive reserve (see `interactive_reserve`): a background run may
/// not use either, so a burst of wakes cannot take the capacity a person's next run needs. Interactive
/// prefers node-thread 0 when it is free, so an idle node stays at one interpreter, and spreads across the
/// others round-robin so parallel sessions are not always pinned to the same node-thread.
fn pick_run_node_thread(class: scheduler::RunClass, claimed: &std::collections::HashSet<usize>) -> Option<usize> {
    let pool = POOL.get()?;
    let background = class == scheduler::RunClass::Background;
    // Background work may not occupy the interactive reserve: node-thread indices below `floor` are kept
    // for runs a person is waiting on, whatever the background backlog looks like.
    let floor = if background { interactive_reserve() } else { 0 };
    // Run lanes stop below the control floor: the control reserve is independent, not merely a
    // different priority, so a run is never admitted to a node-thread the control lane owns.
    let ceiling = run_capacity().saturating_sub(1);
    let beats = NODE_THREAD_BEATS.get()?;
    let mut idle: Vec<usize> = live_node_thread_ids()
        .into_iter()
        .filter(|index| *index >= floor && *index <= ceiling && !claimed.contains(index) && node_thread_busy_label(*index).is_none() && !node_thread_is_wedged(*index))
        .filter(|index| {
            // A node-thread that has not beaten is as idle as one that never existed; a node-thread that has gone
            // quiet is not idle, whatever its label says.
            beats.get(*index).map(|slot| slot.load(Ordering::Relaxed) != u64::MAX).unwrap_or(false)
                && node_thread_age_ms(*index) < 1000
        })
        .collect();
    idle.sort_unstable();
    if !background && idle.first() == Some(&0) {
        return Some(0);
    }
    if !idle.is_empty() {
        let start = pool.next.fetch_add(1, Ordering::Relaxed);
        return Some(idle[start % idle.len()]);
    }
    // No idle node-thread: grow the pool if the ceiling allows. `spawn_node_thread` never reuses node-thread 0 (it is
    // always running), so a spawned node-thread is always outside the interactive reserve.
    if let Ok(mut slots) = pool.slots.lock() {
        if let Some(index) = spawn_node_thread(&mut slots, floor, run_capacity().saturating_sub(1)) {
            if index >= floor {
                return Some(index);
            }
        }
    }
    // Saturated. Interactive waits on node-thread 0's bounded queue; background waits on a background
    // node-thread's bounded queue. Either send may still be refused when that queue is full - which is the
    // bound, because refusing loudly beats an unbounded backlog every client waits in.
    if background {
        let candidates: Vec<usize> = live_node_thread_ids()
            .into_iter()
            .filter(|index| *index >= floor && *index <= ceiling && !node_thread_is_wedged(*index))
            .collect();
        if candidates.is_empty() {
            return None;
        }
        let start = pool.next.fetch_add(1, Ordering::Relaxed);
        Some(candidates[start % candidates.len()])
    } else {
        Some(0)
    }
}

/// Which node-thread a non-run request goes to, growing the pool if that is what it takes. Runs are admitted
/// by the scheduler (`pick_run_node_thread`), never here, so this has no run branch to keep in sync.
fn choose_node_thread(request: &Request) -> Option<usize> {
    if !is_read_route(request) && !is_control_route(request) { return Some(0); }
    let pool = POOL.get()?;
    let mut slots = pool.slots.lock().ok()?;
    // Reads/control never enter run capacity, including when the pool is full.
    // Reserve before enqueue; a busy or already reserved slot is overload, not
    // a reason to leave a transcript socket parked behind unrelated work.
    let start = pool.next.fetch_add(1, Ordering::Relaxed);
    let count = max_node_threads() + 1 - control_floor();
    for offset in 0..count {
        let index = control_floor() + (start + offset) % count;
        if slots.get(index).and_then(|slot| slot.as_ref()).is_some() && node_thread_busy_label(index).is_none()
            && !node_thread_is_wedged(index)
            && read_reservations()[index].compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_ok() {
            return Some(index);
        }
    }
    if let Some(index) = spawn_node_thread(&mut slots, control_floor(), max_node_threads()) {
        if read_reservations()[index].compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_ok() {
            return Some(index);
        }
    }
    None
}

fn now_ms() -> u64 {
    STARTED.get_or_init(std::time::Instant::now).elapsed().as_millis() as u64
}

fn begin_work(label: String) {
    // Only node-thread 0 sets `IN_FLIGHT`. That field is what the window reads to decide whether a *run* is
    // running - so a read being served on another interpreter must not make the UI think a run is in
    // flight, which would disable the composer for a status request.
    let index = node_thread_id();
    if index == 0 {
        if let Ok(mut slot) = IN_FLIGHT.lock() {
            *slot = Some((label.clone(), now_ms()));
        }
    }
    if let Some(slots) = NODE_THREAD_BUSY.get() {
        if let Some(slot) = slots.get(index) {
            if let Ok(mut guard) = slot.lock() {
                *guard = Some((label, now_ms()));
            }
        }
    }
}

fn end_work() {
    let index = node_thread_id();
    if index == 0 {
        if let Ok(mut slot) = IN_FLIGHT.lock() {
            *slot = None;
        }
    }
    if let Some(slots) = NODE_THREAD_BUSY.get() {
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
    // The aggregate is the *newest* beat of any node-thread: the node is alive if any interpreter is making
    // progress. Which node-thread is quiet is a per-node-thread question, answered in the health body.
    BEAT_MS.store(now, Ordering::Relaxed);
    if let Some(beats) = NODE_THREAD_BEATS.get() {
        if let Some(slot) = beats.get(node_thread_id()) {
            slot.store(now, Ordering::Relaxed);
        }
    }
}

/// Proof of life for the duration of a host call that is known to be in progress and
/// known to be bounded.
///
/// The stall detector exists to catch a node-thread that has stopped making progress: an
/// unbounded Lua loop, a provider that accepted the connection and went quiet. A long
/// `exec` is not that - it has a deadline and is killed when the deadline passes - but it
/// beat nothing while it ran, so a node *working correctly* reported `ok:false`,
/// `worker:stalled`, and every reader believed it. The window was the worst of them: its
/// own reads queue behind the run, so `/me` and `/models` timed out and it told the user
/// the node was offline, while the node was running their command. Past the exit threshold
/// the node then killed itself in the middle of that command.
///
/// So: while waiting on something with a deadline, say so. The detector keeps its teeth
/// for the case it was built for - a node-thread stuck with no deadline in sight still stops
/// beating, and still exits.
pub struct Heartbeat {
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

impl Heartbeat {
    pub fn start() -> Self {
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = stop.clone();
        let owner = node_thread_id();
        std::thread::spawn(move || {
            // Thread-local state does not inherit across spawn. Without this a
            // request on node-thread 1 beats node-thread 0, hiding a real stall and inventing another.
            NODE_THREAD_ID.with(|cell| cell.set(owner));
            while !flag.load(Ordering::Relaxed) {
                beat();
                // Once a second, not once every few: `node-thread` reads "alive" only while the age is
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

/// How long a request may sit behind a node-thread that has shown no progress before it is
/// told so instead of waiting. Long enough that a slow run is not mistaken for a
/// wedge; short enough that a client is not left holding an open socket for minutes.
fn stall_seconds() -> u64 {
    env_seconds("WASM_AGENT_WORKER_STALL_SECONDS", 120)
}

/// Past this, the node stops being a node: exit so the service manager restarts it. A
/// stalled run is already lost - the provider connection is not coming back - and a
/// fresh process beats a wedged one that answers /health.
fn stall_exit_seconds() -> u64 {
    env_seconds("WASM_AGENT_WORKER_STALL_EXIT_SECONDS", 900)
}

/// The honest health body. `ok` is false when the interpreter has stopped reporting,
/// which is the one thing this endpoint is uniquely placed to say.
fn health_body() -> Vec<u8> {
    // The aggregate answers one question: *can this node do work?* Work happens on node-thread 0 - runs and
    // every route that changes something - so the aggregate is node-thread 0's age, and a wedged run node-thread is
    // still reported as the node being stalled even while a read node-thread answers reads. Which lane is wedged
    // is a per-node-thread question, answered by the array below.
    let operations = crate::operations::health();
    let operation_overdue = operations.as_array().is_some_and(|items|items.iter().any(|s|s["overdue"]==true));
    let age_ms = live_node_thread_ids().into_iter().map(node_thread_age_ms).max().unwrap_or(0);
    let stalled = age_ms >= stall_seconds() * 1000 || operation_overdue;
    let state = if stalled { "stalled" } else if age_ms < 1000 { "alive" } else { "busy" };
    let mut current = IN_FLIGHT.lock().ok().and_then(|slot| {
        slot.as_ref().map(|(label, started)| {
            // `session` is the conversation this run is writing, so a window can tell whether
            // the in-flight run is *its* run or another conversation's. Without it the page had
            // only "some chat run is active" and disabled its own composer for someone else's run.
            serde_json::json!({
                "label": label,
                "ms": now_ms().saturating_sub(*started),
                "session": node_thread_session(0),
                "run_id": node_thread_run_id(0),
                "run_key": node_thread_run_id(0).map(|id|id.to_string()),
            })
        })
    });
    // Per-node-thread detail, so "which one is busy, and with what" is answerable without reading a log. The
    // aggregate fields above are kept exactly as they were: the window and the sentinel read them, and a
    // new field must not move an old one.
    let mut node_threads = Vec::new();
    if let Some(pool) = POOL.get() {
        if let Ok(slots) = pool.slots.lock() {
            for (index, slot) in slots.iter().enumerate() {
                if slot.is_none() {
                    continue;
                }
                let age = node_thread_age_ms(index);
                let busy = NODE_THREAD_BUSY
                    .get()
                    .and_then(|slots| slots.get(index))
                    .and_then(|slot| slot.lock().ok().and_then(|guard| guard.clone()));
                let run = busy.as_ref().is_some_and(|(label, _)| label.starts_with("POST /chat"));
                if current.is_none() && run {
                    if let Some((label, started)) = &busy {
                        current = Some(serde_json::json!({"label":label,"ms":now_ms().saturating_sub(*started),"node_thread_id":index,"session":node_thread_session(index),"run_id":node_thread_run_id(index),"run_key":node_thread_run_id(index).map(|id|id.to_string())}));
                    }
                }
                node_threads.push(serde_json::json!({
                    "id": index,
                    "role": if index < control_floor() { "runs" } else { "reads" },
                    "session": node_thread_session(index),
                    "run_id": node_thread_run_id(index),
                    "run_key": node_thread_run_id(index).map(|id|id.to_string()),
                    "state": if age >= stall_seconds() * 1000 { "stalled" } else if age < 1000 { "alive" } else { "busy" },
                    "age_ms": age,
                    "busy_ms": busy.as_ref().map(|(_, started)| now_ms().saturating_sub(*started)),
                    "label": busy.as_ref().map(|(label, _)| label.clone()),
                }));
            }
        }
    }
    // Local subagent runtime. Computed here rather than inside the macro so the strict counts are a
    // plain value. Never contains a prompt or a credential.
    let subagent_health = crate::subagents::health();
    let subagent_queued = subagent_health.get("queued").and_then(|value| value.as_u64()).unwrap_or(0);
    let subagent_running = subagent_health.get("running").and_then(|value| value.as_u64()).unwrap_or(0);
    // `active == queued + running`, from the runtime's own counts; a runtime that only names
    // `active_count` is still read correctly.
    let subagent_active = subagent_health
        .get("active")
        .and_then(|value| value.as_u64())
        .or_else(|| subagent_health.get("active_count").and_then(|value| value.as_u64()))
        .unwrap_or(subagent_queued + subagent_running);
    let subagent_counts = serde_json::json!({
        "queued": subagent_queued,
        "running": subagent_running,
        "active": subagent_active,
    });
    // Built with serde_json rather than a hand-escaped format string: the escaping
    // is exactly the kind of thing that silently produces invalid JSON, and this is
    // the one endpoint that must never be the thing that lies.
    serde_json::json!({
        // Versioned execution surface: a client that sees schema 1 may rely on the fields below
        // (`subagents`, `runs`, `run_ids`, `current`, `queue`, `node_threads`) existing. A client that does
        // not see it must fall back to the legacy fields explicitly.
        "execution_schema": 1,
        "ok": !stalled,
        // The node's aggregate execution state (alive/busy/stalled) - not a thread and not a subagent.
        // It keeps its old name because `scripts/upgrade.sh` reads it as the progress signal while
        // waiting for an idle node, and that script also has to read *older* nodes: renaming the key is
        // a coordinated change, not this one (see the report).
        "worker": state,
        "stalled_ms": age_ms,
        "queue": QUEUED.load(Ordering::Relaxed),
        // The bound a `bash`/`shell` call is given, so a client can show an in-flight tool's age
        // against its deadline (`bash · 42s of 300s`) without waiting for the tool event to carry it.
        // Same number `host.exec_timeout()` reports, from the one place the host enforces it.
        "exec_timeout_seconds": crate::host::exec_timeout_seconds(),
        "operations": operations,
        "operation_overdue": operation_overdue,
        "current": current,
        "node_threads_count": node_thread_count(),
        "node_threads": node_threads.clone(),
        // `workers` is the pre-rename spelling of `node_threads`, kept for the one consumer this rename
        // cannot reach: the installed supervisor. `rust/wa-sentinel`'s `activity_of` requires `workers`
        // and reads an absent or malformed one as *ambiguous*, which its graceful maintenance treats as
        // busy - so a `wa-sentinel.exe` built before this change would never see the node as idle again.
        // The key can go once the sentinel reads `node_threads`.
        "workers": node_threads,
        // Admission state: every conversation currently owned, the node-thread holding it, its lane and how
        // many runs are pending behind it. This is what makes "one writer per conversation" and the
        // lane bounds observable from outside the process rather than only from a log.
        "runs": scheduler::global().map(|scheduler| {
            scheduler.snapshot().into_iter().map(|(conversation, node_thread, class, pending)| {
                serde_json::json!({
                    "conversation": conversation,
                    "node_thread": node_thread,
                    "class": if class == scheduler::RunClass::Background { "background" } else { "interactive" },
                    "pending": pending,
                })
            }).collect::<Vec<_>>()
        }),
        "run_limits": scheduler::global().map(|scheduler| {
            let config = scheduler.config();
            serde_json::json!({
                "session_queue_depth": config.session_queue_depth,
                "background_max": config.background_max,
                "background_backlog": config.background_backlog,
                "interactive_reserve": interactive_reserve(),
                "control_node_threads": control_node_threads(),
            })
        }),
        // The admitted run ids, by conversation and state, so a client can show and poll a run it is
        // cancelling without guessing. No prompts and no credentials.
        "run_ids": scheduler::global().map(|scheduler| {
            scheduler.run_ids().into_iter().map(|(conversation, run_id, state)| {
                serde_json::json!({"conversation": conversation, "run_id": run_id, "run_key": run_id.to_string(), "state": state.as_str()})
            }).collect::<Vec<_>>()
        }),
        // Local subagent runtime. `subagents` is the strict, versioned shape `{queued,running,active}`
        // with `active == queued + running`; `subagents_detail` carries the runtime's own view. Neither
        // contains a prompt or a credential.
        "subagents": subagent_counts,
        "subagents_detail": subagent_health,
        "node_threads_spawned": POOL.get().map(|pool| pool.spawned.load(Ordering::Relaxed)).unwrap_or(0),
        "node_threads_retired": POOL.get().map(|pool| pool.retired.load(Ordering::Relaxed)).unwrap_or(0),
        // Milliseconds since a UI page last polled. `null` means no page has ever asked - a node that has
        // never been opened, which is not the same as one whose window has died.
        "ui_error": UI_ERROR.lock().ok().and_then(|slot| slot.as_ref().map(|(text, _)| text.clone())),
        "ui_error_age_ms": UI_ERROR.lock().ok().and_then(|slot| slot.as_ref().map(|(_, at)| now_ms().saturating_sub(*at))),
        "ui_page_age_ms": match UI_SEEN_MS.load(Ordering::Relaxed) {
            0 => serde_json::Value::Null,
            seen => serde_json::json!(now_ms().saturating_sub(seen)),
        },
        // The client-tools bridge and the desktop client behind it. Information, not liveness: `ok`
        // above must not turn false because a window is closed, and the sentinel reads `ok`. It is
        // here because this endpoint is the one thing every caller already looks at, and
        // "the controls are wedged" is otherwise indistinguishable from "nothing is polling".
        "client": crate::client_bridge::global_status(),
    })
    .to_string()
    .into_bytes()
}

/// Where one run's events go. It is created when the run starts and dropped when it
/// ends, and it belongs to the *run*, never to the process.
///
/// This used to be two process-wide statics (`CLIENT`, `EVENT_SINK`) because there was
/// one interpreter and therefore one run at a time. Once runs were routed by session,
/// two node-threads could stream at once and the last one to set `CLIENT` silently owned both
/// streams: the other run's events were written into a socket that belonged to a different
/// conversation, or to nobody. A sink that lives with the run cannot be shared by mistake.
enum Sink {
    /// A live SSE socket for the run that owns it.
    Socket { stream: TcpStream, run_id: u64 },
    /// A buffer, for a run relayed to a peer that cannot hold a live connection.
    Buffer(Rc<RefCell<String>>),
}

thread_local! {
    /// The sink of the run this node-thread thread is executing right now. `host.stream` runs
    /// on the node-thread's own thread, so a thread-local resolves the run without a global
    /// lookup and cannot resolve to a different run's sink.
    static ACTIVE_SINK: RefCell<Option<Sink>> = const { RefCell::new(None) };
}

/// Installs a sink for the current run and restores the previous one on drop. A guard,
/// not a set/clear pair, so an early return or a Lua error cannot leave a run's sink
/// installed for the next request on that node-thread.
struct SinkGuard {
    previous: Option<Sink>,
}

impl SinkGuard {
    fn set(sink: Sink) -> Self {
        let previous = ACTIVE_SINK.with(|cell| cell.borrow_mut().replace(sink));
        Self { previous }
    }
}

impl Drop for SinkGuard {
    fn drop(&mut self) {
        let previous = self.previous.take();
        ACTIVE_SINK.with(|cell| {
            *cell.borrow_mut() = previous;
        });
    }
}

/// Push one event to the streaming sink of the run on this thread, if it has one.
/// Called from Lua via host.stream.
///
/// Every event is also proof of life: a streaming run emits deltas continuously, so a
/// stalled provider read shows up here as silence long before anyone notices a hang.
///
/// With no sink there is no event. A non-streaming run (the CLI's `/chat`) has no
/// client, and a run whose node-thread is between requests has no client either - and that is
/// the point: there is deliberately no process-wide fallback to leak into.
pub fn write_event(payload: &str) {
    if crate::subagents::capture_event(payload) { return; }
    beat();
    CURRENT_RUN_ID.with(|id| { if id.get() != 0 { record_run_event(id.get(),payload); } });
    ACTIVE_SINK.with(|cell| {
        let mut slot = cell.borrow_mut();
        match slot.as_mut() {
            Some(Sink::Buffer(buffer)) => {
                let mut buffer = buffer.borrow_mut();
                buffer.push_str("data: ");
                buffer.push_str(payload);
                buffer.push_str("\n\n");
            }
            Some(Sink::Socket { stream, run_id: _ }) => {
                let _ = stream.write_all(format!("data: {payload}\n\n").as_bytes());
                let _ = stream.flush();
            }
            None => {}
        }
    });
}

/// Run `f` collecting any events it emits, and return them as an SSE body. Used for a run
/// relayed to a peer: the events are captured in a buffer local to this call and cannot
/// reach a live socket belonging to another run.
pub(crate) fn capture_events<F: FnOnce()>(f: F) -> String {
    let buffer = Rc::new(RefCell::new(String::new()));
    let _guard = SinkGuard::set(Sink::Buffer(buffer.clone()));
    f();
    let collected = buffer.borrow().clone();
    collected
}

type Reply = (u16, &'static str, Vec<u8>);

fn ok_json(body: String) -> Reply {
    (200, "application/json", body.into_bytes())
}

/// Resolve the authenticated identity and the conversation for a run, in Lua, before any node-thread is
/// reserved. Returns the conversation on success, or `(status, error, hint)` to refuse at the boundary.
///
/// This is the one place authority is decided for a run: the credential is a DB-backed token and a
/// named thread belongs to its author, so only Lua can answer it. Doing it here means an invalid
/// nonempty credential never reaches a node-thread as the default user, and a foreign thread is refused
/// before a slot is taken.
/// A pre-admission resolution request. The admission dispatcher waits with a deadline while the
/// accept thread continues serving unrelated requests.
struct ResolveRequest {
    function: &'static str,
    args: Vec<String>,
    deadline: std::time::Instant,
    reply: std::sync::mpsc::SyncSender<Result<serde_json::Value, (u16, String, String)>>,
}

/// Resolve on the resolver thread: call the Lua resolver and shape the reply. No model call is ever
/// made here; the functions are `users.resolve`/`memory.session`/`host.verify` and nothing else.
fn resolve_sync(
    control: &Lua,
    function: &str,
    args: &[String],
) -> Result<serde_json::Value, (u16, String, String)> {
    let refs: Vec<&str> = args.iter().map(String::as_str).collect();
    let raw = control
        .call_string(function, &refs)
        .map_err(|error| (500, "resolve_failed".to_string(), error))?;
    let value: serde_json::Value = serde_json::from_str(&raw).map_err(|_| {
        (500, "resolve_failed".to_string(), "the resolver returned invalid JSON".to_string())
    })?;
    if let Some(error) = value.get("error").and_then(|error| error.as_str()) {
        let status = match error {
            "invalid_session" | "unknown_user" | "bad_signature" | "stale_request" => 401,
            "forbidden_thread" | "unknown_caller" | "forbidden_role" | "replayed_request" => 403,
            _ => 400,
        };
        return Err((status, error.to_string(), "the request was refused before admission".to_string()));
    }
    Ok(value)
}

/// Ask the resolver within the remaining admission deadline, including earlier queue residence.
fn resolve_with(
    tx: &std::sync::mpsc::SyncSender<ResolveRequest>,
    function: &'static str,
    args: Vec<String>,
    deadline: std::time::Instant,
) -> Result<serde_json::Value, (u16, String, String)> {
    let remaining = deadline.saturating_duration_since(std::time::Instant::now());
    if remaining.is_zero() { return Err(admission_timeout()); }
    let (reply_tx, reply_rx) = std::sync::mpsc::sync_channel(1);
    tx.try_send(ResolveRequest { function, args, deadline, reply: reply_tx }).map_err(|_| {
        (503, "admission_busy".to_string(), "the admission resolver is busy; retry shortly".to_string())
    })?;
    match reply_rx.recv_timeout(remaining) {
        Ok(result) if std::time::Instant::now() < deadline => result,
        _ => Err(admission_timeout()),
    }
}

fn admission_timeout() -> (u16, String, String) {
    (503, "admission_timeout".into(), "the admission deadline expired; retry shortly".into())
}

/// The `(conversation, owner)` for a run, resolved before it is admitted.
fn resolve_admission(
    tx: &std::sync::mpsc::SyncSender<ResolveRequest>,
    request: &Request,
    deadline: std::time::Instant,
) -> Result<(String, String), (u16, String, String)> {
    let (_, query) = split_path(&request.path);
    let from_query = query_value(&query, "node");
    let node = if !from_query.is_empty() { from_query } else { header_of(&request.node_headers, "x-wa-node") };
    let body = String::from_utf8_lossy(&request.body).to_string();
    let value = resolve_with(tx, "wa_admission", vec![request.session.clone(), node, body], deadline)?;
    let conversation = value.get("conversation").and_then(|value| value.as_str()).unwrap_or_default().to_string();
    let owner = value
        .get("user")
        .and_then(|user| user.get("id"))
        .and_then(|id| id.as_str())
        .unwrap_or_default()
        .to_string();
    Ok((conversation, owner))
}

/// The authenticated user id for a control route that is owner-scoped but not admitted as a run.
fn resolve_identity(
    tx: &std::sync::mpsc::SyncSender<ResolveRequest>,
    session: &str,
    deadline: std::time::Instant,
) -> Result<String, (u16, String, String)> {
    let value = resolve_with(tx, "wa_identity", vec![session.to_string()], deadline)?;
    Ok(value
        .get("user")
        .and_then(|user| user.get("id"))
        .and_then(|id| id.as_str())
        .unwrap_or_default()
        .to_string())
}

/// Verify a peer's signature before admission, so the scheduler keys the conversation by the verified
/// author and not by a header the caller supplied. The run half then uses `wa_node_chat_verified`, which
/// does not re-verify - a second check of the same signed request is refused as a replay.
fn resolve_peer(
    tx: &std::sync::mpsc::SyncSender<ResolveRequest>,
    headers: &[(String, String)],
    body: &str,
    deadline: std::time::Instant,
) -> Result<(String, String, String), (u16, String, String)> {
    let value = resolve_with(
        tx,
        "wa_verify_peer",
        vec![
            header_of(headers, "x-wa-node"),
            header_of(headers, "x-wa-pub"),
            header_of(headers, "x-wa-ts"),
            header_of(headers, "x-wa-sig"),
            body.to_string(),
        ],
        deadline,
    )?;
    let node_id = value.get("node_id").and_then(|value| value.as_str()).unwrap_or_default().to_string();
    let role = value.get("role").and_then(|value| value.as_str()).unwrap_or("master").to_string();
    let name = value.get("name").and_then(|value| value.as_str()).unwrap_or_default().to_string();
    Ok((node_id, role, name))
}

/// The conversation a directly-arriving peer run belongs to. A peer is authenticated by its signature,
/// verified before admission, so the key uses the verified node id (or a thread the peer named) and
/// never the raw header. It is always background.
fn peer_conversation(request: &Request, verified_node_id: &str) -> String {
    if let Some(thread) = serde_json::from_slice::<serde_json::Value>(&request.body)
        .ok()
        .and_then(|value| value.get("thread").and_then(|thread| thread.as_str()).map(str::to_string))
        .filter(|thread| !thread.is_empty())
    {
        return thread;
    }
    if verified_node_id.is_empty() { String::new() } else { format!("peer:{verified_node_id}") }
}

/// `POST /runs`: owner-scoped status and cancellation for a foreground conversation.
///
/// Answered on the admission dispatcher from the scheduler's own state, so it never queues behind
/// the run it is trying to cancel. Identity resolution shares the admission deadline and queue.
/// The response never claims a run stopped: `cancel` sets a request and
/// reports the state it was in, and the caller polls `status` until the run settles as `cancelled`
/// or `completed`.
// Exact wire identity: canonical positive decimal strings, or legacy JS-safe integers.
// Durable SQLite journal IDs are signed 64-bit; reject unsupported values before dispatch.
fn parse_run_id(value: Option<&serde_json::Value>) -> Result<Option<u64>, &'static str> {
    let Some(value) = value else { return Ok(None) };
    let id = if let Some(text) = value.as_str() {
        if text.is_empty() || text.starts_with('0') || !text.bytes().all(|b| b.is_ascii_digit()) {
            return Err("invalid_run_id");
        }
        text.parse::<u64>().map_err(|_| "run_id_out_of_range")?
    } else {
        let id = value.as_u64().ok_or("invalid_run_id")?;
        if id > 9_007_199_254_740_991 { return Err("unsafe_numeric_run_id"); }
        id
    };
    if id == 0 || id > i64::MAX as u64 { return Err("run_id_out_of_range"); }
    Ok(Some(id))
}

fn handle_runs(request: &Request, resolve_tx: &std::sync::mpsc::SyncSender<ResolveRequest>, deadline: std::time::Instant) -> Reply {
    let owner = match resolve_identity(resolve_tx, &request.session, deadline) {
        Ok(owner) => owner,
        Err((status, error, hint)) => {
            let body = format!("{{\"error\":\"{error}\",\"hint\":\"{hint}\"}}");
            return (status, "application/json", body.into_bytes());
        }
    };
    let parsed: serde_json::Value = serde_json::from_slice(&request.body).unwrap_or(serde_json::Value::Null);
    let action = parsed.get("action").and_then(|action| action.as_str()).unwrap_or("status");
    let conversation = parsed
        .get("thread")
        .and_then(|value| value.as_str())
        .or_else(|| parsed.get("conversation").and_then(|value| value.as_str()))
        .unwrap_or_default()
        .to_string();
    if conversation.is_empty() {
        return (400, "application/json", b"{\"error\":\"conversation_required\"}".to_vec());
    }
    let run_id = match parse_run_id(parsed.get("run_id")) {
        Ok(id) => id,
        Err(error) => return (400,"application/json",serde_json::json!({"error":error}).to_string().into_bytes()),
    };
    let Some(scheduler) = scheduler::global() else {
        return (503, "application/json", b"{\"error\":\"admission_unavailable\"}".to_vec());
    };
    match action {
        "status" => {
            let memory_runs: Vec<serde_json::Value> = scheduler
                .runs_for(&owner, &conversation)
                .into_iter()
                .map(|view| {
                    serde_json::json!({
                        "run_id": view.run_id,
                        "run_key": view.run_id.to_string(),
                        "state": view.state.as_str(),
                        "cancel_requested": view.cancel_requested,
                    })
                })
                .collect();
            let runs = match scheduler.durable_views(&owner,&conversation) {
                Ok(Some(runs)) => runs, Ok(None) => memory_runs,
                Err(error) => return (503,"application/json",serde_json::json!({"error":error}).to_string().into_bytes()),
            };
            let cancelled = runs.iter().any(|run| run["cancel_requested"] == serde_json::json!(true));
            let body = serde_json::json!({
                "ok": true,
                "conversation": conversation,
                "runs": runs,
                "cancelled": cancelled,
            })
            .to_string();
            (200, "application/json", body.into_bytes())
        }
        "inspect" => match run_id {
            Some(id) => match scheduler.inspect(&owner,&conversation,id) {
                Ok(Some(detail)) => (200,"application/json",detail.to_string().into_bytes()),
                Ok(None) => (404,"application/json",b"{\"error\":\"run_not_found\"}".to_vec()),
                Err(error) => (503,"application/json",serde_json::json!({"error":error}).to_string().into_bytes()),
            },
            None => (400,"application/json",b"{\"error\":\"run_id_required\"}".to_vec()),
        },
        "cancel" => match scheduler.cancel_run(&owner, &conversation, run_id) {
            scheduler::CancelOutcome::Requested { run_id, state } => {
                let body = serde_json::json!({
                    "ok": true,
                    "run_id": run_id,
                    "run_key": run_id.to_string(),
                    "cancel_requested": true,
                    "state": state.as_str(),
                })
                .to_string();
                (200, "application/json", body.into_bytes())
            }
            scheduler::CancelOutcome::NotFound => (404, "application/json", b"{\"error\":\"run_not_found\"}".to_vec()),
            scheduler::CancelOutcome::Forbidden => (403, "application/json", b"{\"error\":\"forbidden\"}".to_vec()),
        },
        other => {
            let body = format!("{{\"error\":\"unknown_action\",\"action\":{}}}", json_escape(other));
            (400, "application/json", body.into_bytes())
        }
    }
}

/// Return the active run's uncommitted stream tail to its owner. Durable transcript rows are marked
/// with checkpoints in the event log, so a reconnect can repaint the ledger through that point and
/// then apply only events that have not reached the ledger yet.
fn handle_run_events(request: &Request, resolve_tx: &std::sync::mpsc::SyncSender<ResolveRequest>, deadline: std::time::Instant) -> Reply {
    let parsed: serde_json::Value = serde_json::from_slice(&request.body).unwrap_or(serde_json::Value::Null);
    let conversation = parsed.get("thread").and_then(|value| value.as_str()).unwrap_or_default();
    let run_id = match parse_run_id(parsed.get("run_id")) {
        Ok(id) => id,
        Err(error) => return (400,"application/json",serde_json::json!({"error":error}).to_string().into_bytes()),
    };
    let Some(run_id) = run_id else {
        return (400, "application/json", b"{\"error\":\"run_id_required\"}".to_vec());
    };
    if conversation.is_empty() {
        return (400, "application/json", b"{\"error\":\"conversation_required\"}".to_vec());
    }
    let owner = match resolve_identity(resolve_tx, &request.session, deadline) {
        Ok(owner) => owner,
        Err((status, error, hint)) => {
            return (status, "application/json", serde_json::json!({"error": error, "hint": hint}).to_string().into_bytes());
        }
    };
    let Some(scheduler) = scheduler::global() else {
        return (503, "application/json", b"{\"error\":\"admission_unavailable\"}".to_vec());
    };
    let after = parsed.get("after").and_then(|value| value.as_u64()).unwrap_or(0);
    let archive=parsed.get("archive").and_then(|value|value.as_bool()).unwrap_or(false);
    match scheduler.replay(&owner, conversation, run_id, after, archive) {
        Ok(Some(replay)) => return (200,"application/json",replay.to_string().into_bytes()),
        Err(error) => return (503,"application/json",serde_json::json!({"error":error}).to_string().into_bytes()),
        Ok(None) => {},
    }
    if archive {
        return (404,"application/json",b"{\"error\":\"run_archive_unavailable\"}".to_vec());
    }
    if !scheduler.runs_for(&owner, conversation).iter().any(|run| run.run_id == run_id) {
        return (404, "application/json", b"{\"error\":\"run_not_found\"}".to_vec());
    }
    let after = parsed.get("after").and_then(|value| value.as_u64()).unwrap_or(0);
    let Ok(logs) = run_events().lock() else {
        return (503, "application/json", b"{\"error\":\"run_event_lock_unavailable\"}".to_vec());
    };
    let Some(log) = logs.get(&run_id) else {
        return (404, "application/json", b"{\"error\":\"run_stream_unavailable\"}".to_vec());
    };
    let events: Vec<serde_json::Value> = log.events.iter()
        .filter(|(seq, _)| *seq > after.max(log.checkpoint_seq))
        .map(|(seq, event)| serde_json::json!({"seq": seq, "event": event}))
        .collect();
    let body = serde_json::json!({
        "ok": true,
        "run_id": run_id,
        "run_key": run_id.to_string(),
        "checkpoint_seq": log.checkpoint_seq,
        "checkpoint_message_seq": log.checkpoint_message_seq,
        "next_seq": log.next_seq,
        "overflow": log.overflow,
        "events": events,
    }).to_string();
    (200, "application/json", body.into_bytes())
}

/// Bound the HTTP `await` of a subagent control call. A caller may ask to wait minutes; the HTTP
/// route holds a control slot, and a slot held for minutes is a slot `cancel` and `start` cannot
/// use. The tool-level await may be longer because it runs inside a run, not on the control lane.
fn cap_subagent_await(body: &str) -> String {
    let Ok(mut value) = serde_json::from_str::<serde_json::Value>(body) else { return body.to_string() };
    if value.get("action").and_then(|action| action.as_str()) != Some("await") {
        return body.to_string();
    }
    let cap = env_usize("WASM_AGENT_SUBAGENT_AWAIT_MS", 10_000) as u64;
    let requested = value
        .get("wait_ms")
        .and_then(|value| value.as_u64())
        .or_else(|| value.get("timeout_ms").and_then(|value| value.as_u64()))
        .unwrap_or(cap);
    if requested <= cap {
        return body.to_string();
    }
    value["wait_ms"] = serde_json::json!(cap);
    if value.get("timeout_ms").is_some() {
        value["timeout_ms"] = serde_json::json!(cap);
    }
    value.to_string()
}

/// Call the runtime's global `wa_subagents(body, session)`. An invalid nonempty credential is a `401`
/// at the boundary; the owner is derived from the authenticated session, never from the body.
fn subagent_reply(lua: &Lua, body: &str, session: &str) -> Reply {
    let capped = cap_subagent_await(body);
    match lua.call_string("wa_subagents", &[capped.as_str(), session]) {
        Ok(text) => (200, "application/json", text.into_bytes()),
        Err(error) => {
            // Close a transaction the failed call may have left open.
            lua.rollback_if_open();
            let (status, code) = if error.contains("invalid_session") || error.contains("unknown_user") {
                (401, "invalid_session")
            } else {
                (500, "subagent_error")
            };
            let body = format!("{{\"error\":\"{code}\",\"hint\":{}}}", json_escape(&error));
            (status, "application/json", body.into_bytes())
        }
    }
}

pub fn run(first: Lua, factory: Box<dyn Fn() -> Lua + Send + Sync>, port: u16, ui: PathBuf) {
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("[serve] bind 127.0.0.1:{port} failed: {error}");
            return;
        }
    };
    let ceiling = max_node_threads();
    let warm = warm_read_node_threads().min(ceiling);
    let queue_depth = env_usize("WASM_AGENT_QUEUE_DEPTH", 256);
    // The control interpreter, owned by the resolver thread. Admission resolves the credential and
    // the conversation in Lua *before* a node-thread is reserved. The admission dispatcher bounds its
    // wait without holding the accept thread. This interpreter never runs a model.
    let control = factory();
    let (resolve_tx, resolve_rx) = std::sync::mpsc::sync_channel::<ResolveRequest>(4);
    std::thread::spawn(move || {
        while let Ok(request) = resolve_rx.recv() {
            let result = if std::time::Instant::now() >= request.deadline {
                Err(admission_timeout())
            } else {
                resolve_sync(&control, request.function, &request.args)
            };
            let _ = request.reply.send(result);
        }
    });
    // One bounded admission dispatcher preserves HTTP admission order without tying the listener
    // to resolver latency. Queue residence and resolver wait share the same deadline; expired jobs
    // are refused before calling Lua or acquiring scheduler ownership. No thread is spawned per socket.
    let admission_depth = env_usize("WASM_AGENT_ADMISSION_QUEUE_DEPTH", 4).clamp(1, 256);
    let (admission_tx, admission_rx) = std::sync::mpsc::sync_channel::<(TcpStream, Request, std::time::Instant)>(admission_depth);
    let admission_resolver = resolve_tx.clone();
    std::thread::Builder::new().name("wa-admission".into()).spawn(move || {
        while let Ok((mut stream, request, deadline)) = admission_rx.recv() {
            if std::time::Instant::now() >= deadline {
                let _ = respond(&mut stream, 503, "application/json", b"{\"error\":\"admission_timeout\"}");
                continue;
            }
            dispatch_http(stream, request, &admission_resolver, deadline);
        }
    }).expect("admission dispatcher");
    // Admission bounds. `background_max` is how many background conversations may run at once and
    // `background_backlog` how many more may wait; together they keep a wake storm from growing
    // without limit. `session_queue_depth` bounds one conversation's own backlog so a single
    // conversation cannot fill a node-thread's queue and starve another. The interactive reserve is
    // `WASM_AGENT_INTERACTIVE_RESERVE` node-threads (default two), and background runs never use one.
    if let Err(error) = scheduler::install(scheduler::Config {
        session_queue_depth: env_usize("WASM_AGENT_SESSION_QUEUE_DEPTH", 4).max(1),
        // The interactive reserve is subtracted from the run capacity, so background work is bounded
        // to the node-threads the reserve does not own.
        background_max: env_usize("WASM_AGENT_BACKGROUND_MAX", (ceiling + 1).saturating_sub(interactive_reserve())).max(1),
        background_backlog: env_usize("WASM_AGENT_BACKGROUND_BACKLOG", 8),
    }) {
        eprintln!("[serve] run journal initialization failed: {error}");
        std::process::exit(1);
    }
    // Register the run half of unified cancellation with the host, so the provider reader and the
    // agent loop observe a run's own flag as well as a child's. One name (`host::run_cancel_requested`)
    // combines both, and a caller cannot check the wrong one.
    crate::host::set_run_cancel_probe(crate::serve::run_cancel_requested);
    // Lifetime only: ordering, eligibility and recovery policy stay in Lua.
    // Start after the run journal's process lease, never from a browser poll.
    let placement = factory();
    std::thread::Builder::new().name("wa-placement".into()).spawn(move || loop {
        if let Err(error) = placement.call_string("wa_orchestrator_tick", &[]) {
            eprintln!("[placement] {error}");
        }
        std::thread::sleep(std::time::Duration::from_secs(2));
    }).expect("placement node-thread");
    // Sized to the ceiling once, so a node-thread's liveness slot never has to be created later: the arrays are
    // indexed by node-thread id, and a slot whose sender is None is simply not running.
    // u64::MAX, not 0, for "never beaten": a node-thread beats at the top of its own loop, which can happen
    // inside the first millisecond of the process, so 0 would be ambiguous between "never" and "at time 0".
    let _ = NODE_THREAD_BEATS.set((0..=ceiling).map(|_| AtomicU64::new(u64::MAX)).collect());
    let _ = NODE_THREAD_BUSY.set((0..=ceiling).map(|_| Mutex::new(None)).collect());
    let _ = NODE_THREAD_SESSION.set((0..=ceiling).map(|_| Mutex::new(None)).collect());
    let _ = NODE_THREAD_RUN.set((0..=ceiling).map(|_| Mutex::new(None)).collect());
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

    // Node-thread 0, always: the run node-thread. It is the state main.rs already booted, so a node that never
    // grows a read node-thread boots exactly one interpreter, as it always did.
    let (sender, receiver) = std::sync::mpsc::sync_channel::<Work>(queue_depth);
    if let Ok(mut slots) = pool.slots.lock() {
        slots.push(Some(sender));
    }
    let node_thread_ui = ui.clone();
    std::thread::spawn(move || {
        NODE_THREAD_ID.with(|cell| cell.set(0));
        node_thread_loop(first, 0, receiver, node_thread_ui);
    });
    // Read node-threads only if asked for: the point of the pool is to appear when a read would otherwise wait,
    // so the default is to have none until that happens.
    for _ in 0..warm {
        if let Ok(mut slots) = pool.slots.lock() {
            spawn_node_thread(&mut slots, 1, run_capacity().saturating_sub(1));
        }
    }
    eprintln!(
        "[serve] one run node-thread{} (reads: {warm} warm, up to {ceiling}, spawned on demand)",
        if warm == 0 { String::new() } else { format!(" + {warm} read node-thread(s)") }
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

    // Each node-thread owns an interpreter and reads its own queue, so requests still run one at a time *per
    // interpreter* - what changed is that a running run no longer stops the node answering anything at all.
    // `/health`, `/version` and the UI files were already answered on the accept thread; the reads that need
    // Lua (sessions, models, nodes) now have an interpreter of their own, created when they need one.
    //
    // Bounded on purpose: an unbounded queue runs a busy node into an unbounded number of open sockets,
    // and the accept thread can then only fail it loudly.

    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(10)));
        let request = match read_request(&mut stream) {
            Ok(Some(request)) => request,
            _ => continue,
        };
        let port = stream.local_addr().map(|a| a.port()).unwrap_or(0);
        if let Err(reason) = admit_origin(&request, port) {
            eprintln!("[serve] refused {} {}: {reason}", request.method, split_path(&request.path).0);
            let _ = respond(&mut stream, 403, "application/json", b"{\"error\":\"foreign_origin\"}");
            continue;
        }
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
        // Only resolver-dependent requests enter this bounded FIFO. The accept thread keeps
        // serving unrelated reads and static replies while authentication waits on Lua/SQLite.
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(admission_timeout_ms());
        if is_run_route(&request) || (request.method == "POST"
            && matches!(split_path(&request.path).0.as_str(), "/runs" | "/run-events")) {
            match admission_tx.try_send((stream, request, deadline)) {
                Ok(()) => {},
                Err(std::sync::mpsc::TrySendError::Full((mut stream, _, _)))
                | Err(std::sync::mpsc::TrySendError::Disconnected((mut stream, _, _))) => {
                    let _ = respond(&mut stream, 503, "application/json",
                        b"{\"error\":\"admission_busy\",\"hint\":\"the admission queue is full or unavailable; retry shortly\"}");
                }
            }
        } else {
            dispatch_http(stream, request, &resolve_tx, deadline);
        }
    }
}

/// Dispatch one parsed request. Resolver waits happen only on the admission thread; ordinary reads
/// call this directly. The scheduler still authenticates before claiming, journaling or executing.
fn dispatch_http(
    mut stream: TcpStream,
    mut request: Request,
    resolve_tx: &std::sync::mpsc::SyncSender<ResolveRequest>,
    deadline: std::time::Instant,
) {
    // `POST /runs` is answered here, without a node-thread: cancellation and status must stay prompt
    // even while every control slot is awaiting a subagent, and the run's state and cancel flag
    // live in the scheduler, not in an interpreter. Only identity resolution touches Lua, and it
    // is bounded by the resolver thread.
    if split_path(&request.path).0 == "/runs" && request.method == "POST" {
        let (status, content_type, body) = handle_runs(&request, resolve_tx, deadline);
        let _ = respond(&mut stream, status, content_type, &body);
        return;
    }
    if split_path(&request.path).0 == "/run-events" && request.method == "POST" {
        let (status, content_type, body) = handle_run_events(&request, resolve_tx, deadline);
        let _ = respond(&mut stream, status, content_type, &body);
        return;
    }
    // Admission. A run goes through the scheduler, which owns its conversation from admission
    // through completion and picks its lane; everything else keeps the old routing. The scheduler
    // decides *and reserves* in one step, so two back-to-back admissions for one conversation
    // cannot both be handed a fresh node-thread - the hole that let a conversation be written twice.
    let is_run = is_run_route(&request);
    let target = if is_run {
        if split_path(&request.path).0 == "/node/chat" {
            // A peer run is authenticated by its signature, verified ONCE here, before admission,
            // so the conversation and owner come from the verified author and not from a header
            // the caller supplied. The run half uses `wa_node_chat_verified` and does not re-check.
            let body = String::from_utf8_lossy(&request.body).to_string();
            match resolve_peer(resolve_tx, &request.node_headers, &body, deadline) {
                Ok((node_id, role, name)) => {
                    request.routing_session = peer_conversation(&request, &node_id);
                    request.run_class = scheduler::RunClass::Background;
                    request.owner = node_id.clone();
                    request.peer_verified = Some((node_id, role, name));
                }
                Err((status, error, hint)) => {
                    let body = format!("{{\"error\":\"{error}\",\"hint\":\"{hint}\"}}");
                    let _ = respond(&mut stream, status, "application/json", body.as_bytes());
                    return;
                }
            }
        } else {
            match resolve_admission(resolve_tx, &request, deadline) {
                Ok((conversation, owner)) => {
                    request.routing_session = conversation;
                    request.owner = owner;
                }
                Err((status, error, hint)) => {
                    let body = format!("{{\"error\":\"{error}\",\"hint\":\"{hint}\"}}");
                    let _ = respond(&mut stream, status, "application/json", body.as_bytes());
                    return;
                }
            }
        }
        match scheduler::admit(&request.routing_session, &request.owner, request.run_class, pick_run_node_thread) {
            scheduler::Decision::Run { run_id, node_thread, cancel, sockets }
            | scheduler::Decision::Behind { run_id, node_thread, cancel, sockets } => {
                if let Some(scheduler) = scheduler::global() {
                    if scheduler.record_request(run_id,&String::from_utf8_lossy(&request.body)).is_err() {
                        scheduler.complete_run(run_id);
                        let _ = respond(&mut stream,503,"application/json",b"{\"error\":\"run_journal_unavailable\"}");
                        return;
                    }
                }
                request.run_id = run_id;
                request.run_cancel = Some(cancel);
                request.run_sockets = Some(sockets);
                node_thread
            }
            scheduler::Decision::Refused(refusal) => {
                let (code, hint) = refusal.as_error();
                let body = format!("{{\"error\":\"{code}\",\"hint\":\"{hint}\"}}");
                let _ = respond(&mut stream, 503, "application/json", body.as_bytes());
                return;
            }
        }
    } else {
        match choose_node_thread(&request) {
            Some(index) => index,
            None => {
                let _ = respond(&mut stream, 503, "application/json", b"{\"error\":\"read_capacity_busy\",\"hint\":\"read/control capacity is occupied; retry with backoff\"}");
                return;
            }
        }
    };
    let independent = !is_run && (is_read_route(&request) || is_control_route(&request));
    let age_ms = node_thread_age_ms(target);
    if age_ms >= stall_seconds() * 1000 {
        // The node-thread this request needs has not reported progress for longer than any healthy
        // operation takes. Saying so is the whole point: the alternative was an open socket, no bytes,
        // and a client that waits forever.
        let now = STARTED.get().map(|s| s.elapsed().as_millis() as u64).unwrap_or(0);
        let last = STALL_LOGGED_MS.load(Ordering::Relaxed);
        if now.saturating_sub(last) > 30_000 {
            STALL_LOGGED_MS.store(now, Ordering::Relaxed);
            eprintln!(
                "[serve] node-thread {target} has not reported progress for {}s - replying 503",
                age_ms / 1000
            );
        }
        // Exit only when *every* node-thread that is running is stalled: a wedged lane must not take the
        // healthy ones with it, and with a single interpreter this is exactly the old behaviour.
        let all_stalled = live_node_thread_ids()
            .iter()
            .all(|index| node_thread_age_ms(*index) >= stall_exit_seconds() * 1000);
        if stall_exit_seconds() > 0 && all_stalled {
            eprintln!(
                "[serve] every node-thread has been stalled for {}s: exiting so the service manager can restart the node",
                stall_exit_seconds()
            );
            std::process::exit(3);
        }
        if is_run {
            // The admission is already claimed; the run is not going to start, so give the
            // conversation's place back before refusing.
            scheduler::complete_run(request.run_id);
        }
        if independent { release_read_destination(target); }
        let body = format!(
            "{{\"error\":\"node_thread_stalled\",\"node_thread\":{target},\"stalled_ms\":{age_ms},\"hint\":\"the interpreter has not reported progress; see the node log, and restart it if the run is lost\"}}"
        );
        let _ = respond(&mut stream, 503, "application/json", body.as_bytes());
        return;
    }
    QUEUED.fetch_add(1, Ordering::Relaxed);
    // A node-thread can retire between selection and delivery. Independent
    // requests reselect within reserved capacity, then refuse boundedly.
    let mut attempt = 0;
    let mut target = target;
    let admitted_run_id = request.run_id;
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
                if is_run {
                    // The conversation's owner retired between admission and delivery. Release
                    // the place rather than hand the run to a node-thread that does not own it.
                    scheduler::complete_run(admitted_run_id);
                    QUEUED.fetch_sub(1, Ordering::Relaxed);
                    let body = b"{\"error\":\"node_busy\",\"hint\":\"the node-thread retired before the run could start; retry shortly\"}";
                    let _ = respond(&mut stream, 503, "application/json", body);
                    break;
                }
                // Retirement never grants a read permission to queue on a run slot.
                if independent { release_read_destination(target); }
                if independent && attempt < 2 {
                    attempt += 1;
                    if let Some(index) = choose_node_thread(&request) {
                        target = index;
                        pending = Some((stream, request));
                        continue;
                    }
                }
                QUEUED.fetch_sub(1, Ordering::Relaxed);
                let body = b"{\"error\":\"node_busy\",\"hint\":\"the node is answering other requests; retry shortly\"}";
                let _ = respond(&mut stream, 503, "application/json", body);
                break;
            }
        };
        match sender.try_send(Work::Http(stream, request)) {
            Ok(()) => break,
            Err(std::sync::mpsc::TrySendError::Full(work)) => {
                let (mut stream, _request) = unwrap_http(work);
                if independent { release_read_destination(target); }
                if is_run {
                    scheduler::complete_run(admitted_run_id);
                }
                QUEUED.fetch_sub(1, Ordering::Relaxed);
                // A bounded queue: refusing loudly beats an unbounded backlog that every client waits in.
                let body = b"{\"error\":\"node_busy\",\"hint\":\"the node is answering other requests; retry shortly\"}";
                let _ = respond(&mut stream, 503, "application/json", body);
                break;
            }
            Err(std::sync::mpsc::TrySendError::Disconnected(work)) => {
                let pair = unwrap_http(work);
                if is_run {
                    scheduler::complete_run(admitted_run_id);
                    QUEUED.fetch_sub(1, Ordering::Relaxed);
                    let (mut stream, _request) = pair;
                    let body = b"{\"error\":\"node_busy\",\"hint\":\"the node-thread retired before the run could start; retry shortly\"}";
                    let _ = respond(&mut stream, 503, "application/json", body);
                    break;
                }
                // Retry only independent capacity; no fallback behind a long run.
                if independent { release_read_destination(target); }
                if independent && attempt < 2 {
                    attempt += 1;
                    if let Some(index) = choose_node_thread(&pair.1) {
                        target = index;
                        pending = Some(pair);
                        continue;
                    }
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

/// Recover the HTTP request from a work item a `try_send` handed back. The accept loop only ever sends
/// HTTP work, so a relay item here would be a bug rather than a case to answer.
fn unwrap_http(work: Work) -> (TcpStream, Request) {
    match work {
        Work::Http(stream, request) => (stream, request),
        Work::Relay(_) | Work::Completion { .. } => unreachable!("the accept loop only sends HTTP work"),
    }
}

/// One interpreter's loop. Node-thread 0 also does the housekeeping - relayed work and the sync tick - because
/// that work is a conversation with a peer and belongs where the runs are; a read node-thread does nothing but
/// answer reads.
fn node_thread_loop(
    lua: Lua,
    index: usize,
    receiver: std::sync::mpsc::Receiver<Work>,
    agent_ui: PathBuf,
) {
    let mut next_sync = std::time::Instant::now() + std::time::Duration::from_secs(5);
    // A deterministic wedge, for the regression test: the hook stalls node-thread 0 on its first request, which
    // is exactly the shape that was found in the wild. Only node-thread 0, or a node with read node-threads would
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
            Ok(Work::Completion { body, run_id, cancel, sockets }) => {
                QUEUED.fetch_sub(1, Ordering::Relaxed);
                begin_work("child completion".into());
                let args: serde_json::Value=serde_json::from_str(&body).unwrap_or_default();
                if let Some(slot)=NODE_THREAD_SESSION.get().and_then(|slots|slots.get(index)) {
                    if let Ok(mut value)=slot.lock() {*value=args["session_id"].as_str().map(str::to_string);}
                }
                if let Some(slot)=NODE_THREAD_RUN.get().and_then(|slots|slots.get(index)) {
                    if let Ok(mut value)=slot.lock() {*value=Some(run_id);}
                }
                IN_RUN.with(|flag| flag.set(true));
                CURRENT_RUN_ID.with(|id| id.set(run_id));
                set_current_run_io(Some(cancel), Some(sockets), format!("run:{run_id}"));
                scheduler::mark_running(run_id);
                begin_run_events(run_id);
                let mut request: serde_json::Value=serde_json::from_str(&body).unwrap_or_default();
                request["cancelled"]=serde_json::json!(run_cancel_requested());
                if let Err(error) = lua.call_string("wa_completion_run", &[&request.to_string()]) {
                    write_event(&serde_json::json!({"type":"error","error":error}).to_string());
                }
                finish_run_events(run_id);
                CURRENT_RUN_ID.with(|id| id.set(0));
                set_current_run_io(None,None,String::new());
                IN_RUN.with(|flag| flag.set(false));
                scheduler::complete_run(run_id);
                if let Some(slot)=NODE_THREAD_SESSION.get().and_then(|slots|slots.get(index)) {
                    if let Ok(mut value)=slot.lock() {*value=None;}
                }
                if let Some(slot)=NODE_THREAD_RUN.get().and_then(|slots|slots.get(index)) {
                    if let Ok(mut value)=slot.lock() {*value=None;}
                }
                end_work();beat();idle_since=std::time::Instant::now();
                continue;
            }
            Ok(Work::Http(mut stream, request)) => {
                if test_stall && !stalled_once {
                    stalled_once = true;
                    eprintln!("[serve] test hook: stalling node-thread 0 on purpose");
                    std::thread::sleep(std::time::Duration::from_secs(3600));
                }
                QUEUED.fetch_sub(1, Ordering::Relaxed);
                LAST_SERVED_MS.store(now_ms(), Ordering::Relaxed);
                begin_work(format!("{} {}", request.method, request.path));
                if is_read_route(&request) || is_control_route(&request) { release_read_destination(index); }
                // Which session this node-thread holds, so a second run in the same session finds it and queues
                // behind it instead of starting a second writer on the same conversation.
                if let Some(slots) = NODE_THREAD_SESSION.get() {
                    if let Some(slot) = slots.get(index) {
                        if let Ok(mut guard) = slot.lock() {
                            // Only a run holds a conversation. A read or a write does not, and reporting
                            // one would make a read node-thread look like a run node-thread in `/health`.
                            *guard = if is_run_route(&request) && !request.routing_session.is_empty() {
                                Some(request.routing_session.clone())
                            } else {
                                None
                            };
                        }
                    }
                }
                if let Some(slots) = NODE_THREAD_RUN.get() {
                    if let Some(slot) = slots.get(index) {
                        if let Ok(mut guard) = slot.lock() {
                            *guard = if is_run_route(&request) { Some(request.run_id) } else { None };
                        }
                    }
                }
                IN_RUN.with(|flag| flag.set(is_run_route(&request)));
                if is_run_route(&request) {
                    // Install this run's own cancel flag and socket slot, and mark it running, so a
                    // cancel request reaches the provider reader on this thread and can wake a silent
                    // read, while the lifecycle is observable.
                    set_current_run_io(request.run_cancel.clone(), request.run_sockets.clone(), format!("run:{}", request.run_id));
                    CURRENT_RUN_ID.with(|id|id.set(request.run_id));
                    scheduler::mark_running(request.run_id);
                }
                let replay_run = is_run_route(&request) && request.accept_sse;
                if replay_run && !run_cancel_requested() {
                    begin_run_events(request.run_id);
                }
                if is_run_route(&request) && run_cancel_requested() {
                    // Cancelled while queued: settle its own stream exactly once and never execute.
                    let _ = settle_cancelled_run(&mut stream, &request);
                } else {
                    let _ = handle(&lua, &agent_ui, &mut stream, &request);
                }
                if replay_run {
                    finish_run_events(request.run_id);
                }
                if is_run_route(&request) {
                    CURRENT_RUN_ID.with(|id|id.set(0));
                    set_current_run_io(None, None, String::new());
                }
                IN_RUN.with(|flag| flag.set(false));
                // The run is over, so release its conversation. This happens for the queued runs too:
                // the owner is held until the last one behind it completes, so the next admission can
                // land anywhere once the backlog is empty. A run whose cancel flag was set settles as
                // `cancelled`, not `completed` - the state is only reported after it actually stopped.
                if is_run_route(&request) {
                    scheduler::complete_run(request.run_id);
                }
                if let Some(slots) = NODE_THREAD_SESSION.get() {
                    if let Some(slot) = slots.get(index) {
                        if let Ok(mut guard) = slot.lock() {
                            *guard = None;
                        }
                    }
                }
                if let Some(slots) = NODE_THREAD_RUN.get() {
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
            Ok(Work::Relay(relay)) => {
                // A peer run that admission routed here. It owns its conversation for exactly as long
                // as it runs, like any other run, and releases it the same way.
                LAST_SERVED_MS.store(now_ms(), Ordering::Relaxed);
                begin_work(format!("relay {} {}", relay.job.method, relay.job.path));
                set_current_run_io(Some(relay.cancel.clone()), Some(relay.sockets.clone()), format!("run:{}", relay.run_id));
                CURRENT_RUN_ID.with(|id|id.set(relay.run_id));
                scheduler::mark_running(relay.run_id);
                let (status, body) = if run_cancel_requested() { (503, "{\"error\":\"run_cancelled\"}".to_string()) }
                    else { process_relay_job(&lua, &agent_ui, &relay.job, relay.verified.as_ref()) };
                CURRENT_RUN_ID.with(|id|id.set(0));
                set_current_run_io(None, None, String::new());
                scheduler::complete_run(relay.run_id);
                end_work();
                beat();
                let _ = relay.job.reply.send((status, body));
                idle_since = std::time::Instant::now();
                continue;
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
        }
        if index != 0 {
            // A read node-thread retires itself once it has been idle long enough and the pool is above the warm
            // minimum. Two things make that safe: it clears its own slot *before* returning, so the
            // dispatcher stops choosing it, and a request already on its way to a retired node-thread is not
            // lost - `try_send` reports Disconnected and the accept thread reselects read capacity.
            if idle_since.elapsed().as_secs() >= read_idle_seconds() && node_thread_count() > warm_read_node_threads() + 1 {
                if let Some(pool) = POOL.get() {
                    if let Ok(mut slots) = pool.slots.lock() {
                        if slots.get(index).is_some() {
                            slots[index] = None;
                            pool.retired.fetch_add(1, Ordering::Relaxed);
                            eprintln!("[serve] read node-thread {index} retired after {}s idle", idle_since.elapsed().as_secs());
                        }
                    }
                }
                return;
            }
            continue;
        }
        // Relayed peer work goes through the same admission as a direct request. A peer run must not
        // bypass the scheduler by arriving on node-thread 0's housekeeping path; `/node/chat` is a run and is
        // forced into the background lane, while the other relay routes are control calls and stay here.
        for job in crate::relay_client::take_jobs() {
            let route = split_path(&job.path).0;
            if !(job.method == "POST" && route == "/node/chat") {
                begin_work(format!("relay {} {}", job.method, job.path));
                let (status, body) = process_relay_job(&lua, &agent_ui, &job, None);
                end_work();
                beat();
                let _ = job.reply.send((status, body));
                continue;
            }
            // Verify the peer's signature ONCE here, before admission, so the conversation is keyed by
            // the verified author and the run half never re-verifies (a replay).
            let verified = match verify_peer_sync(&lua, &job.headers, &job.body) {
                Ok(triple) => triple,
                Err(error) => {
                    let _ = job.reply.send((403, format!("{{\"error\":{}}}", json_escape(&error))));
                    continue;
                }
            };
            let conversation = relay_conversation(&job, &verified.0);
            let owner = verified.0.clone();
            match scheduler::admit(&conversation, &owner, scheduler::RunClass::Background, pick_run_node_thread) {
                scheduler::Decision::Run { run_id, node_thread, cancel, sockets }
                | scheduler::Decision::Behind { run_id, node_thread, cancel, sockets } => {
                    if let Some(scheduler) = scheduler::global() {
                        if scheduler.record_request(run_id,&job.body).is_err() {
                            scheduler.complete_run(run_id);
                            let _ = job.reply.send((503,"{\"error\":\"run_journal_unavailable\"}".into()));
                            continue;
                        }
                    }
                    let sender = POOL
                        .get()
                        .and_then(|pool| pool.slots.lock().ok().and_then(|slots| slots.get(node_thread).cloned().flatten()));
                    match sender {
                        Some(sender) => match sender.try_send(Work::Relay(RelayWork { job, run_id, cancel, sockets, verified: Some(verified) })) {
                            Ok(()) => {}
                            Err(std::sync::mpsc::TrySendError::Full(Work::Relay(relay)))
                            | Err(std::sync::mpsc::TrySendError::Disconnected(Work::Relay(relay))) => {
                                scheduler::complete_run(relay.run_id);
                                let _ = relay.job.reply.send((503, "{\"error\":\"node_busy\",\"hint\":\"the relay run could not be delivered; the peer may retry\"}".into()));
                            }
                            Err(_) => {
                                scheduler::complete_run(run_id);
                            }
                        },
                        None => {
                            scheduler::complete_run(run_id);
                            let _ = job.reply.send((503, "{\"error\":\"node_busy\",\"hint\":\"the relay run could not be delivered; the peer may retry\"}".into()));
                        }
                    }
                }
                scheduler::Decision::Refused(refusal) => {
                    let (code, _) = refusal.as_error();
                    let _ = job.reply.send((503, format!("{{\"error\":\"{code}\"}}")));
                }
            }
        }
        // Housekeeping last, and only when nobody is waiting and the node has been quiet: the sync tick
        // talks to a peer over the network, and on node-thread 0 that means this interpreter stops answering
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


/// The conversation a relayed peer run belongs to. A `/node/chat` body may name a `thread`; without one
/// the peer's node id is the key, so two calls from one peer serialise instead of racing on one
/// transcript. The peer is already authenticated by its signature before this is called.
fn relay_conversation(job: &crate::relay_client::RelayJob, verified_node_id: &str) -> String {
    if let Some(thread) = serde_json::from_str::<serde_json::Value>(&job.body)
        .ok()
        .and_then(|value| value.get("thread").and_then(|thread| thread.as_str()).map(str::to_string))
        .filter(|thread| !thread.is_empty())
    {
        return thread;
    }
    if verified_node_id.is_empty() {
        String::new()
    } else {
        format!("peer:{verified_node_id}")
    }
}

/// Verify a peer's signature on the node-thread that owns the relay housekeeping path. The result is the
/// verified author, carried to whichever node-thread runs the job so the run never re-verifies.
fn verify_peer_sync(
    lua: &Lua,
    headers: &[(String, String)],
    body: &str,
) -> Result<(String, String, String), String> {
    let raw = lua.call_string(
        "wa_verify_peer",
        &[
            &header_of(headers, "x-wa-node"),
            &header_of(headers, "x-wa-pub"),
            &header_of(headers, "x-wa-ts"),
            &header_of(headers, "x-wa-sig"),
            body,
        ],
    )?;
    let value: serde_json::Value = serde_json::from_str(&raw).map_err(|error| error.to_string())?;
    if let Some(error) = value.get("error").and_then(|error| error.as_str()) {
        return Err(error.to_string());
    }
    Ok((
        value.get("node_id").and_then(|value| value.as_str()).unwrap_or_default().to_string(),
        value.get("role").and_then(|value| value.as_str()).unwrap_or("master").to_string(),
        value.get("name").and_then(|value| value.as_str()).unwrap_or_default().to_string(),
    ))
}

/// Process a request that arrived over the relay. Streaming routes are captured
/// rather than written to a socket, so the peer gets the events and can replay
/// them locally.
fn process_relay_job(
    lua: &Lua,
    ui: &std::path::Path,
    job: &crate::relay_client::RelayJob,
    verified: Option<&(String, String, String)>,
) -> (u16, String) {
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
    // The relay is untrusted transport, never a tunnel into unauthenticated local UI APIs.
    if job.method != "POST" || !matches!(route.as_str(), "/node/call" | "/node/chat" | "/sync/push") {
        return (403, "{\"error\":\"relay_route_forbidden\"}".into());
    }
    let session = header_of(&job.headers, "x-wa-session");

    if route == "/node/chat" && job.method == "POST" {
        let text = job.body.clone();
        let events = capture_events(|| {
            // A relayed peer run whose signature was verified before admission uses the verified-author
            // entry point and does not re-verify; a second check of the same signed request is a replay.
            let result = match verified {
                Some((node_id, role, name)) => lua.call_string(
                    "wa_node_chat_verified",
                    &[node_id.as_str(), role.as_str(), name.as_str(), text.as_str()],
                ),
                None => {
                    let from = header_of(&job.headers, "x-wa-node");
                    let public_key = header_of(&job.headers, "x-wa-pub");
                    let ts = header_of(&job.headers, "x-wa-ts");
                    let signature = header_of(&job.headers, "x-wa-sig");
                    lua.call_string(
                        "wa_node_chat",
                        &[from.as_str(), public_key.as_str(), ts.as_str(), signature.as_str(), text.as_str()],
                    )
                }
            };
            if let Err(error) = result {
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
                lua.rollback_if_open();
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

/// Routes a peer reaches across the network. Each one carries its own node signature, verified by Lua
/// before anything runs, so the caller's Host is whatever address the peer dialled, never ours.
fn is_signed_peer_route(route: &str) -> bool {
    matches!(route, "/node/call" | "/node/chat" | "/sync/push" | "/sync/head")
}

/// Only this machine's own pages and local tools may talk to the node. A browser marks every request
/// from another site (`Sec-Fetch-Site: cross-site`, a foreign `Origin`), and a DNS-rebinding page still
/// sends its own name as `Host`, so all three are checked on every route that can read or act.
/// Static UI files only need the Host check (rebinding), so a link from elsewhere still opens the UI.
/// `WASM_AGENT_ALLOWED_HOSTS` (comma list of `host:port`) admits a trusted proxy or tunnel name.
fn admit_origin(request: &Request, port: u16) -> Result<(), &'static str> {
    let route = split_path(&request.path).0;
    if is_signed_peer_route(&route) {
        return Ok(());
    }
    let host = header_of(&request.node_headers, "host").to_ascii_lowercase();
    let allowed = std::env::var("WASM_AGENT_ALLOWED_HOSTS").unwrap_or_default().to_ascii_lowercase();
    let local_host = host == format!("127.0.0.1:{port}")
        || host == format!("localhost:{port}")
        || host == format!("[::1]:{port}")
        || allowed.split(',').map(str::trim).any(|name| !name.is_empty() && name == host);
    if !local_host {
        return Err("host");
    }
    if request.method == "GET" && static_route(&route) {
        return Ok(());
    }
    if header_of(&request.node_headers, "sec-fetch-site") == "cross-site" {
        return Err("cross_site");
    }
    let origin = header_of(&request.node_headers, "origin").to_ascii_lowercase();
    if !origin.is_empty() && origin != format!("http://{host}") && origin != format!("https://{host}") {
        return Err("origin");
    }
    Ok(())
}

/// A file the UI ships (anything with an extension, or the index) - not an API route.
fn static_route(route: &str) -> bool {
    route == "/" || route.is_empty() || route.rsplit('/').next().is_some_and(|last| last.contains('.'))
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
    /// The conversation this run writes, resolved before admission. The body's `thread` is the
    /// conversation; `x-wa-session` is a credential and is never used as one. When the body names no
    /// thread the resolver returns the session `agent_for` would resume, so the scheduler owns the real
    /// id rather than an empty key.
    routing_session: String,
    /// The lane this run belongs to. Set from `X-WA-Run-Class`, which can only demote: see
    /// `scheduler::RunClass::from_header`. A non-run request's class is never consulted.
    run_class: scheduler::RunClass,
    /// The admission id assigned when this request is admitted as a run (0 for anything else).
    /// It is the run's identity in `/health` and in the node log, so "which run is on which
    /// node-thread" is answerable without reading a conversation.
    run_id: u64,
    /// The authenticated owner of this run, resolved before admission. `/runs cancel` is scoped by
    /// it, so one user can never cancel another's run.
    owner: String,
    /// This run's own cancel flag. Installed as the node-thread's current-run context so the runtime's
    /// provider reader can observe a cancellation request on the thread blocked in the model call.
    run_cancel: Option<Arc<AtomicBool>>,
    /// A peer run's verified author `(node_id, role, name)`. Set only when the signature was verified
    /// at admission; the run uses `wa_node_chat_verified` and never re-verifies (which would be a
    /// replay). The conversation and owner come from this, never from the raw `x-wa-node` header.
    peer_verified: Option<(String, String, String)>,
    /// This run's own socket slot, held from admission through settlement so a cancel on the accept
    /// thread can wake this run's silent provider read without touching the next queued run's.
    run_sockets: Option<crate::subagents::SocketSlot>,
    node_headers: Vec<(String, String)>,
    body: Vec<u8>,
    accept_sse: bool,
}

/// Internal bounded enqueue. Lua owns eligibility and the durable outbox;
/// scheduler owns same-session serialization and cancellation. No loopback HTTP.
pub(crate) fn enqueue_completion(body: &str) -> serde_json::Value {
    let args: serde_json::Value = match serde_json::from_str(body) {
        Ok(args) => args, Err(_) => return serde_json::json!({"error":"invalid_completion", "not_started":true}),
    };
    let session=args["session_id"].as_str().unwrap_or_default();
    let owner=args["owner"].as_str().unwrap_or_default();
    if session.is_empty() || owner.is_empty() || POOL.get().is_none() {
        return serde_json::json!({"error":"completion_runtime_unavailable","not_started":true});
    }
    match scheduler::admit(session,owner,scheduler::RunClass::Background,pick_run_node_thread) {
        scheduler::Decision::Run {run_id,node_thread,cancel,sockets}
        | scheduler::Decision::Behind {run_id,node_thread,cancel,sockets} => {
            let recorded=scheduler::global().is_some_and(|s| s.record_request(run_id,body).is_ok());
            if !recorded {scheduler::complete_run(run_id);return serde_json::json!({"error":"run_journal_unavailable","not_started":true});}
            let sender=POOL.get().and_then(|pool| pool.slots.lock().ok().and_then(|slots| slots.get(node_thread).cloned().flatten()));
            QUEUED.fetch_add(1,Ordering::Relaxed);
            if sender.is_some_and(|s| s.try_send(Work::Completion {body:body.to_string(),run_id,cancel,sockets}).is_ok()) {
                serde_json::json!({"accepted":true,"run_id":run_id,"run_key":run_id.to_string()})
            } else {
                QUEUED.fetch_sub(1,Ordering::Relaxed);scheduler::complete_run(run_id);
                serde_json::json!({"error":"completion_queue_full","not_started":true})
            }
        }
        scheduler::Decision::Refused(reason) => serde_json::json!({"error":reason.as_error().0,"not_started":true}),
    }
}

/// One unit of work a node-thread can be handed. HTTP requests and relayed peer requests travel the same
/// queue and the same admission, so a peer run can no longer bypass the scheduler by arriving on
/// node-thread 0's housekeeping path.
enum Work {
    Completion { body: String, run_id: u64, cancel: Arc<AtomicBool>, sockets: crate::subagents::SocketSlot },
    Http(TcpStream, Request),
    Relay(RelayWork),
}

/// A relayed run admitted on the accept-thread side of the relay: the job, its admission id, and its
/// own cancel flag, so it settles exactly like a local run. `verified` is the peer author verified
/// before admission, so the run half never re-verifies.
struct RelayWork {
    job: crate::relay_client::RelayJob,
    run_id: u64,
    cancel: Arc<AtomicBool>,
    sockets: crate::subagents::SocketSlot,
    verified: Option<(String, String, String)>,
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
            let mut run_class = scheduler::RunClass::Interactive;
            let mut node_headers: Vec<(String, String)> = Vec::new();
            for line in lines {
                let lower = line.to_ascii_lowercase();
                if let Some(value) = lower.strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap_or(0);
                } else if let Some(value) = lower.strip_prefix("x-wa-session:") {
                    session = value.trim().to_string();
                } else if let Some(value) = lower.strip_prefix("x-wa-run-class:") {
                    // One-way marker: `background` demotes, everything else (including `interactive`)
                    // keeps the default. No header value can grant the interactive reserve.
                    run_class = scheduler::RunClass::from_header(value);
                } else if lower.starts_with("accept:") && lower.contains("text/event-stream") {
                    accept_sse = true;
                } else if let Some((key, value)) = lower.split_once(':') {
                    if key.trim().starts_with("x-wa-") || matches!(key.trim(), "host" | "origin" | "sec-fetch-site") {
                        node_headers.push((key.trim().to_string(), value.trim().to_string()));
                    }
                }
            }
            if length > 4_000_000 || end > 65536 { return Ok(None); }
            if data.len() >= end + 4 + length {
                let body = data[end + 4..end + 4 + length].to_vec();
                return Ok(Some(Request {
                    method,
                    path,
                    session,
                    // Filled in by admission, from the Lua resolver: the conversation is the body's
                    // `thread` (or the session an unnamed run resumes), never the credential.
                    routing_session: String::new(),
                    run_class,
                    run_id: 0,
                    owner: String::new(),
                    run_cancel: None,
                    peer_verified: None,
                    run_sockets: None,
                    node_headers,
                    body,
                    accept_sse,
                }));
            }
        }
        if data.len() > 4_000_000 {
            return Ok(None);
        }
    }
}

/// The UI file a request names, or `None` if the name could leave the UI directory. Every component
/// must be a plain name: no `..`, and no root or prefix, because on Windows `ui.join("C:/Users/..")` or a
/// `\\server\share` path *replaces* the base instead of extending it. A file that exists must also
/// resolve inside the UI directory, so a link inside it cannot point elsewhere.
fn ui_file(ui: &std::path::Path, relative: &str) -> Option<std::path::PathBuf> {
    use std::path::Component;
    let candidate = std::path::Path::new(relative);
    if relative.contains("..") || relative.contains('\\') || relative.contains(':')
        || !candidate.components().all(|part| matches!(part, Component::Normal(_)))
    {
        return None;
    }
    let file = ui.join(candidate);
    match (file.canonicalize(), ui.canonicalize()) {
        (Ok(real), Ok(root)) if !real.starts_with(&root) => None,
        _ => Some(file),
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
    let Some(file) = ui_file(ui, &relative) else {
        return Some((400, "text/plain", b"bad path".to_vec()));
    };
    // A route the UI does not have could still be an API route (they are all
    // handled by `dispatch`), so absence is not a 404 here - it means "ask the
    // agent thread". That keeps the route table in exactly one place.
    match std::fs::read(&file) {
        Ok(bytes) => Some((200, content_type(&relative), bytes)),
        Err(_) => None,
    }
}

fn version_body(ui: &std::path::Path) -> String {
    format!("{{\"version\":\"{}\"}}", ui_version(ui))
}

/// Settle a run that was cancelled while it was queued: it must produce exactly one terminal event
/// on its own stream and never execute. This is deliberately separate from the streaming handler so
/// a cancelled run cannot be mistaken for one that ran and answered.
fn settle_cancelled_run(stream: &mut TcpStream, request: &Request) -> std::io::Result<()> {
    let route = split_path(&request.path).0;
    if request.accept_sse || route == "/node/chat" {
        stream.write_all(
            b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\
              Connection: close\r\n\r\n",
        )?;
        stream.write_all(b"data: {\"type\":\"error\",\"error\":\"run_cancelled\"}\n\n")?;
        stream.write_all(b"data: {\"type\":\"done\"}\n\n")?;
        stream.flush()
    } else {
        respond(stream, 200, "application/json", b"{\"error\":\"run_cancelled\"}")
    }
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
                  Connection: close\r\n\r\n",
            )?;
            stream.flush()?;
            // The sink belongs to this run for exactly as long as the call below runs.
            // `try_clone` gives the run its own handle; if it fails the run still executes
            // and simply has no stream, rather than writing into another run's socket.
            let _sink = stream.try_clone().ok().map(|clone| SinkGuard::set(Sink::Socket {
                stream: clone,
                run_id: request.run_id,
            }));
            let node = header_of(&node_headers, "x-wa-node");
            if let Err(error) = lua.call_string("wa_reply_stream", &[text.as_str(), session, node.as_str()]) {
                lua.rollback_if_open();
                write_event(&format!("{{\"type\":\"error\",\"error\":{}}}", json_escape(&error)));
            }
            write_event("{\"type\":\"done\"}");
            return Ok(());
        }
    }
    if route == "/node/chat" && method == "POST" {
        let text = String::from_utf8_lossy(&body).to_string();
        stream.write_all(
            b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\
              Connection: close\r\n\r\n",
        )?;
        stream.flush()?;
        let _sink = stream.try_clone().ok().map(|clone| SinkGuard::set(Sink::Socket {
            stream: clone,
            run_id: request.run_id,
        }));
        // A peer run whose signature was verified at admission uses the verified-author entry point
        // and does not re-verify (a second check of the same signed request is a replay). A direct
        // call that skipped admission still verifies here.
        let result = match &request.peer_verified {
            Some((node_id, role, name)) => lua.call_string(
                "wa_node_chat_verified",
                &[node_id.as_str(), role.as_str(), name.as_str(), text.as_str()],
            ),
            None => {
                let from = header_of(&node_headers, "x-wa-node");
                let public_key = header_of(&node_headers, "x-wa-pub");
                let ts = header_of(&node_headers, "x-wa-ts");
                let signature = header_of(&node_headers, "x-wa-sig");
                lua.call_string(
                    "wa_node_chat",
                    &[from.as_str(), public_key.as_str(), ts.as_str(), signature.as_str(), text.as_str()],
                )
            }
        };
        if let Err(error) = result {
            write_event(&format!("{{\"type\":\"error\",\"error\":{}}}", json_escape(&error)));
        }
        write_event("{\"type\":\"done\"}");
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
        match lua.call_string(name, args) {
            Ok(value) => value,
            Err(error) => {
                // A Lua error can abandon a BEGIN on this interpreter's connection;
                // close it before answering, or the write lock outlives the request.
                lua.rollback_if_open();
                format!("{{\"error\":{}}}", json_escape(&error))
            }
        }
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
        "/model-configuration-preview" => (200, "application/json", call("wa_model_configuration_preview", &[session]).into_bytes()),
        "/envelope" => (200, "application/json", call("wa_envelope", &[session]).into_bytes()), // legacy alias
        "/tools" => (200, "application/json", call("wa_tools", &[session]).into_bytes()),
        "/jobs" if method == "GET" => (200,"application/json",call("wa_jobs", &["{}",session]).into_bytes()),
        "/jobs" if method == "POST" => (200,"application/json",call("wa_jobs", &[body,session]).into_bytes()),
        "/operations" if method == "GET" => (200,"application/json",call("wa_operation", &["{}",session]).into_bytes()),
        "/operation" if method == "POST" => (200,"application/json",call("wa_operation", &[body,session]).into_bytes()),
        // Local subagents. This is a control call, never a run admission: `start` launches a native
        // background child, so the route itself must not occupy an interactive or background run slot.
        // The HTTP `await` is bounded so one control slot cannot be held indefinitely.
        "/subagents" if method == "POST" => subagent_reply(lua, body, session),
        "/subagents" if method == "GET" => subagent_reply(lua, "{}", session),
        "/skills" => (200, "application/json", call("wa_skills", &[session]).into_bytes()),
        "/nodes" => (200, "application/json", call("wa_nodes", &[session]).into_bytes()),
        "/node/name" if method == "POST" => (200, "application/json", call("wa_set_node_name", &[body, session]).into_bytes()),
        "/sessions" => (200, "application/json", call("wa_sessions", &[session]).into_bytes()),
        "/session" => (200, "application/json", call("wa_session", &[query_value(&query, "id").as_str(), session]).into_bytes()),
        "/session/owner" if method == "GET" => (200, "application/json", call("wa_session_owner", &[query_value(&query, "id").as_str(), session]).into_bytes()),
        // The window's `/efficiency_report`: the same deterministic report the CLI prints, read for one
        // session. No model call, so it is a plain read route. This line was dropped by a merge that
        // applied cleanly and recorded its branch as a parent while bringing none of its content - the
        // gate stayed green because nothing asserted the route. `scripts/test-serve-concurrency.sh`
        // now fetches it while node-thread 0 is wedged, which catches both a missing handler (404) and a
        // handler that is not a read.
        "/efficiency" => (200, "application/json", call("wa_efficiency", &[query_value(&query, "session_id").as_str(), session]).into_bytes()),
        "/session/fork" if method == "POST" => (200, "application/json", call("wa_session_fork", &[body, session]).into_bytes()),
        "/session/mode" if method == "POST" => (200, "application/json", call("wa_session_mode", &[body, session]).into_bytes()),
        "/session/worktree" if method == "POST" => (200, "application/json", call("wa_session_worktree", &[body, session]).into_bytes()),
        "/session/fixture" => (200, "application/json", call("wa_session_fixture", &[query_value(&query, "id").as_str(), session]).into_bytes()),
        // A run's changed files: "can it be undone?" and "do it", one route so the answer
        // the toggle shows and the handler's behaviour cannot disagree.
        "/diff" if method == "POST" => (200, "application/json", call("wa_diff", &[body.trim(), session]).into_bytes()),
        "/client" if method == "POST" => (200, "application/json", call("wa_client", &[body, session, node.as_str()]).into_bytes()),
        "/frame" if method == "POST" => (200, "application/json", call("wa_frame", &[body.trim(), session, node.as_str()]).into_bytes()),
        "/spells" => (200, "application/json", call("wa_spells", &[session]).into_bytes()),
        // Export a spell as a portable plan for the sentinel. A separate route from /spell because
        // it writes nothing to the node's behaviour and reads nothing about a run - it produces a
        // file for *another process*, and the two must not be confusable.
        "/spell/export" if method == "POST" => (200, "application/json", call("wa_spell_export", &[body.trim(), session]).into_bytes()),
        "/update" if method == "POST" => (200, "application/json", call("wa_update", &[body.trim(), session]).into_bytes()),
        "/spell" if method == "POST" => (200, "application/json", call("wa_spell_run", &[body.trim(), session]).into_bytes()),
        "/provider" if method == "POST" => (200, "application/json", call("wa_set_provider", &[body.trim(), node.as_str(), session]).into_bytes()),
        "/model" if method == "POST" => (200, "application/json", call("wa_set_model", &[body.trim(), node.as_str(), session]).into_bytes()),
        "/reasoning" if method == "POST" => (200,"application/json",call("wa_set_reasoning",&[body.trim(),node.as_str(),session]).into_bytes()),
        "/chat" if method == "POST" => (200, "application/json", call("wa_reply", &[body, session, node.as_str()]).into_bytes()),
        // The module system: `/modules/` is its own page and `/modules/index.json` the listing beside
        // it, and a module's own files are under `/modules/<id>/<path>`. The id and the relative path
        // are split here because that is the shape the route takes, and *what may be reached* stays in
        // Lua: an id that is not a module directory is refused 404, the files of a module nobody
        // enabled are refused 403, and a path that tries to leave the directory is refused 400.
        //
        // The page is served at the *root* of that space because a module is its sibling - its
        // `entry_url` is relative to the page - so `/modules` redirects to `/modules/`. Served as a
        // page at both, the slashless one would resolve every panel one level outside the tree, and
        // the failure would look like a broken module rather than a missing slash.
        "/modules" => (301, "text/plain; charset=utf-8", b"/modules/".to_vec()),
        "/modules/" | "/modules/index.html" => module_reply(lua, "", "index.html", session),
        "/modules/index.json" => module_reply(lua, "", "index.json", session),
        route if route.starts_with("/modules/") => {
            let rest = &route["/modules/".len()..];
            match rest.split_once('/') {
                Some((id, relative)) => module_reply(lua, id, relative, session),
                // `/modules/<id>` is the module's own entry point, as an empty path is in the route.
                None => module_reply(lua, rest, "", session),
            }
        }
        _ => {
            if route == "/chat" || route == "/node/chat" {
                return None; // streaming
            }
            let relative = if route == "/" || route.is_empty() {
                "index.html".to_string()
            } else {
                route.trim_start_matches('/').to_string()
            };
            let Some(file) = ui_file(ui, &relative) else {
                return Some((400, "text/plain", b"bad path".to_vec()));
            };
            return match std::fs::read(&file) {
                Ok(bytes) => Some((200, content_type(&relative), bytes)),
                Err(_) => Some((404, "text/plain; charset=utf-8", b"not found".to_vec())),
            };
        }
    };
    Some(reply)
}

/// One module-system request, in the route's positional shape: `wa_modules(op, id, path, session)`.
///
/// The route answers a `{status, content_type, body}` envelope, and the status is *kept*: whether an
/// unasked module is refused (403) or an unknown one is missing (404) is the module system's
/// decision, and re-deciding it here is how a route and the page that reads it come to disagree - the
/// page renders what it is told and the tests assert the route, so both have to answer the same
/// question. An envelope that cannot be read is a 500, never a silent empty 200: an empty listing is
/// a normal state of a node, so an unreadable answer that looked like one would hide a broken route.
fn module_reply(lua: &Lua, id: &str, relative: &str, session: &str) -> Reply {
    let answer = match lua.call_string("wa_modules", &["file", id, relative, session]) {
        Ok(answer) => answer,
        Err(error) => {
            // As above: a Lua error can abandon a BEGIN on this interpreter's connection.
            lua.rollback_if_open();
            return (500, "application/json; charset=utf-8",
                format!("{{\"error\":{}}}", json_escape(&error)).into_bytes());
        }
    };
    let Ok(envelope) = serde_json::from_str::<serde_json::Value>(&answer) else {
        return (500, "application/json; charset=utf-8",
            b"{\"error\":\"module_route_did_not_answer_an_envelope\"}".to_vec());
    };
    let status = envelope.get("status").and_then(serde_json::Value::as_u64).unwrap_or(500) as u16;
    let body = envelope.get("body").and_then(serde_json::Value::as_str).unwrap_or("");
    let from_route = envelope.get("content_type").and_then(serde_json::Value::as_str).unwrap_or("");
    (status, module_content_type(from_route), body.as_bytes().to_vec())
}

/// The type of what a module serves: named by the route, mapped onto the `&'static str` a reply
/// carries. The vocabulary is the module system's (a module may hold css, svg or markdown); a type
/// this node does not know is served as bytes rather than guessed at, which is the same answer the
/// route gives for a file with no extension.
fn module_content_type(from_route: &str) -> &'static str {
    match from_route {
        "text/html; charset=utf-8" => "text/html; charset=utf-8",
        "text/css; charset=utf-8" => "text/css; charset=utf-8",
        "text/javascript; charset=utf-8" => "text/javascript; charset=utf-8",
        "application/json; charset=utf-8" => "application/json; charset=utf-8",
        "text/markdown; charset=utf-8" => "text/markdown; charset=utf-8",
        "image/svg+xml" => "image/svg+xml",
        "text/plain; charset=utf-8" => "text/plain; charset=utf-8",
        _ => "application/octet-stream",
    }
}

fn respond(stream: &mut TcpStream, status: u16, content_type: &str, body: &[u8]) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        204 => "No Content",
        301 => "Moved Permanently",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        _ => "OK",
    };
    // A redirect carries where to go and no content: the body *is* the target. Every other status is
    // unchanged, so this costs the existing responses nothing.
    let (location, length) = if status == 301 {
        (format!("Location: {}\r\n", String::from_utf8_lossy(body)), 0)
    } else {
        (String::new(), body.len())
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\n{location}Content-Type: {content_type}\r\nContent-Length: {length}\r\n\
         Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
    );
    stream.write_all(head.as_bytes())?;
    if status != 301 {
        stream.write_all(body)?;
    }
    stream.flush()
}

fn content_type(path: &str) -> &'static str {
    match path.rsplit('.').next().unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "webmanifest" => "application/manifest+json; charset=utf-8",
        "wasm" => "application/wasm",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod content_type_tests {
    use super::content_type;

    #[test]
    fn pwa_assets_have_browser_types() {
        assert_eq!(content_type("manifest.webmanifest"), "application/manifest+json; charset=utf-8");
        assert_eq!(content_type("icon-192.png"), "image/png");
    }
}

/// A content hash of the UI, not a timestamp.
///
/// This used to hash each file's mtime, so an install that rewrote *identical* files changed the version:
/// `upgrade.sh` copies every asset with `cp -f`, and every open page reloads on a version change. When that
/// reload landed in the same deploy's node restart, the webview navigated into a dead port and stuck on an
/// error page with no JavaScript - no heartbeat, no error report, a window that looked crashed but whose
/// process was alive. The version must change when the bytes change, and only then.
fn ui_version(ui: &std::path::Path) -> String {
    use std::hash::{Hash, Hasher};
    let mut entries: Vec<_> = std::fs::read_dir(ui)
        .map(|dir| dir.flatten().map(|entry| entry.path()).collect())
        .unwrap_or_default();
    entries.sort();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    for path in entries {
        let Ok(metadata) = path.metadata() else { continue };
        if !metadata.is_file() {
            continue;
        }
        path.to_string_lossy().hash(&mut hasher);
        content_hash(&path, &metadata).hash(&mut hasher);
    }
    format!("{:x}", hasher.finish())
}

/// One file's content hash, cached by `(mtime, size)`. The version poll runs once a second per window, so
/// the bytes are read only when the file actually changed - which is exactly when the stamp moves.
fn content_hash(path: &std::path::Path, metadata: &std::fs::Metadata) -> u64 {
    use std::hash::{Hash, Hasher};
    type Stamp = (u64, u64);
    static CACHE: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<std::path::PathBuf, (Stamp, u64)>>> =
        std::sync::OnceLock::new();
    let stamp: Stamp = (
        metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|duration| duration.as_nanos() as u64)
            .unwrap_or(0),
        metadata.len(),
    );
    let cache = CACHE.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()));
    if let Ok(guard) = cache.lock() {
        if let Some((cached, hash)) = guard.get(path) {
            if *cached == stamp {
                return *hash;
            }
        }
    }
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    match std::fs::read(path) {
        Ok(bytes) => bytes.hash(&mut hasher),
        Err(_) => 0u8.hash(&mut hasher),
    }
    let hash = hasher.finish();
    if let Ok(mut guard) = cache.lock() {
        guard.insert(path.to_path_buf(), (stamp, hash));
    }
    hash
}

fn json_escape(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "\"error\"".into())
}

#[cfg(test)]
mod ui_version_tests {
    use super::ui_version;

    /// The regression: a deploy rewrites the UI with `cp -f` on every install, even when the bytes are
    /// unchanged. Hashing the mtime made that a new version, which forced every open page to reload - into
    /// the same deploy's node restart, where it stuck on an error page.
    #[test]
    fn the_version_tracks_content_not_timestamps() {
        let dir = std::env::temp_dir().join(format!("wa-ui-version-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp ui dir");
        let asset = dir.join("index.html");
        std::fs::write(&asset, b"<html>one</html>").expect("write");
        let first = ui_version(&dir);
        // Same bytes, newer mtime: the version must not move.
        std::thread::sleep(std::time::Duration::from_millis(30));
        std::fs::write(&asset, b"<html>one</html>").expect("rewrite");
        assert_eq!(ui_version(&dir), first, "identical content must keep the version");
        // Different bytes of the *same length* must still move it.
        std::thread::sleep(std::time::Duration::from_millis(30));
        std::fs::write(&asset, b"<html>two</html>").expect("change");
        assert_ne!(ui_version(&dir), first, "changed content must change the version");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod module_route_tests {
    use super::module_content_type;

    /// The route names the type of what it serves and the reply carries a `&'static str`, so every
    /// type the route can name has to survive the mapping. Miss one and a module that serves markdown
    /// arrives as a download, with nothing failing anywhere.
    #[test]
    fn the_routes_own_types_survive_the_mapping() {
        for (from_route, expected) in [
            ("text/html; charset=utf-8", "text/html; charset=utf-8"),
            ("text/css; charset=utf-8", "text/css; charset=utf-8"),
            ("text/javascript; charset=utf-8", "text/javascript; charset=utf-8"),
            ("application/json; charset=utf-8", "application/json; charset=utf-8"),
            ("text/markdown; charset=utf-8", "text/markdown; charset=utf-8"),
            ("image/svg+xml", "image/svg+xml"),
            ("text/plain; charset=utf-8", "text/plain; charset=utf-8"),
        ] {
            assert_eq!(module_content_type(from_route), expected, "{from_route}");
        }
    }

    /// A type this node does not know is served as bytes, not as something that sniffs as safe - and
    /// an empty one is the same case, because the envelope may be missing the field entirely.
    #[test]
    fn an_unknown_type_is_bytes() {
        assert_eq!(module_content_type("application/x-shockwave-flash"), "application/octet-stream");
        assert_eq!(module_content_type(""), "application/octet-stream");
    }
}

#[cfg(test)]
mod read_route_tests {
    use super::{is_read_route, Request};

    fn request(method: &str, path: &str) -> Request {
        Request {
            method: method.into(),
            path: path.into(),
            session: String::new(),
            routing_session: String::new(),
            run_class: super::scheduler::RunClass::Interactive,
            run_id: 0,
            owner: String::new(),
            run_cancel: None,
            peer_verified: None,
            run_sockets: None,
            node_headers: Vec::new(),
            body: Vec::new(),
            accept_sse: false,
        }
    }

    /// The regression that cost two incidents: a read route not on the hand-maintained list was
    /// pinned to node-thread 0, and queued behind a run. A GET must be a read without anyone remembering.
    #[test]
    fn a_get_is_a_read_without_being_listed() {
        assert!(is_read_route(&request("GET", "/a-route-invented-after-this-test")));
        assert!(is_read_route(&request("GET", "/tools")));
        assert!(is_read_route(&request("GET", "/sync/head")));
        assert!(!is_read_route(&request("POST", "/a-write")));
        assert!(!is_read_route(&request("DELETE", "/a-delete")));
    }

    /// The controls answered by independent runtimes are reads too. They are POSTs, so the method
    /// rule alone would pin them to node-thread 0 - where a run could block its own cancellation.
    #[test]
    fn a_control_post_is_a_read() {
        assert!(is_read_route(&request("POST", "/operation")));
        assert!(is_read_route(&request("POST", "/operations")));
        assert!(is_read_route(&request("POST", "/jobs")));
    }
}

#[cfg(test)]
mod peer_conversation_tests {
    use super::{peer_conversation, Request};

    fn request(body: &[u8], headers: Vec<(String, String)>) -> Request {
        Request {
            method: "POST".into(),
            path: "/node/chat".into(),
            session: String::new(),
            routing_session: String::new(),
            run_class: super::scheduler::RunClass::Background,
            run_id: 0,
            owner: String::new(),
            run_cancel: None,
            peer_verified: None,
            run_sockets: None,
            node_headers: headers,
            body: body.to_vec(),
            accept_sse: true,
        }
    }

    /// A peer run's conversation is the thread it named, else the *verified* peer's node id. It is
    /// never the raw header and never the local credential, and two calls from one peer must serialise
    /// rather than race on one transcript.
    #[test]
    fn a_peer_run_is_keyed_by_its_thread_or_its_verified_peer_id() {
        let with_thread = request(br#"{"text":"hi","thread":"peer-thread"}"#, vec![("x-wa-node".into(), "attacker-supplied".into())]);
        assert_eq!(peer_conversation(&with_thread, "node-1"), "peer-thread");
        // No thread: the verified node id wins, not the header the caller wrote.
        let without_thread = request(br#"{"text":"hi"}"#, vec![("x-wa-node".into(), "attacker-supplied".into())]);
        assert_eq!(peer_conversation(&without_thread, "node-1"), "peer:node-1");
        let anonymous = request(b"plain text", vec![]);
        assert_eq!(peer_conversation(&anonymous, ""), "");
    }
}

#[cfg(test)]
mod origin_tests {
    use super::{admit_origin, scheduler, Request};

    fn request(method: &str, path: &str, headers: &[(&str, &str)]) -> Request {
        Request {
            method: method.into(),
            path: path.into(),
            session: String::new(),
            routing_session: String::new(),
            run_class: scheduler::RunClass::Interactive,
            run_id: 0,
            owner: String::new(),
            run_cancel: None,
            peer_verified: None,
            run_sockets: None,
            node_headers: headers.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            body: Vec::new(),
            accept_sse: false,
        }
    }

    /// The attack this closes: a page on any site POSTs a command to the local node with a
    /// `text/plain` body (no preflight), or rebinds its own name to 127.0.0.1.
    #[test]
    fn a_foreign_page_cannot_reach_an_api_route() {
        let cross = request("POST", "/shell", &[("host", "127.0.0.1:8799"), ("origin", "https://evil.example"), ("sec-fetch-site", "cross-site")]);
        assert!(admit_origin(&cross, 8799).is_err());
        let no_fetch_meta = request("POST", "/chat", &[("host", "127.0.0.1:8799"), ("origin", "https://evil.example")]);
        assert!(admit_origin(&no_fetch_meta, 8799).is_err());
        let rebound = request("GET", "/sessions", &[("host", "evil.example:8799")]);
        assert!(admit_origin(&rebound, 8799).is_err());
        let rebound_static = request("GET", "/app.js", &[("host", "evil.example:8799")]);
        assert!(admit_origin(&rebound_static, 8799).is_err());
    }

    #[test]
    fn the_own_page_local_tools_and_signed_peers_still_pass() {
        let page = request("POST", "/chat", &[("host", "127.0.0.1:8799"), ("origin", "http://127.0.0.1:8799"), ("sec-fetch-site", "same-origin")]);
        assert!(admit_origin(&page, 8799).is_ok());
        let curl = request("GET", "/health", &[("host", "localhost:8799")]);
        assert!(admit_origin(&curl, 8799).is_ok());
        let link = request("GET", "/", &[("host", "127.0.0.1:8799"), ("sec-fetch-site", "cross-site")]);
        assert!(admit_origin(&link, 8799).is_ok());
        let peer = request("POST", "/node/call", &[("host", "10.0.0.5:8799")]);
        assert!(admit_origin(&peer, 8799).is_ok());
    }
}

#[cfg(test)]
mod ui_file_tests {
    use super::ui_file;

    /// On Windows `Path::join` with an absolute or prefixed path replaces the base, so a request for
    /// `/C:/Users/x/.wasm-agent/env` used to read that file. Each form is refused on every platform.
    #[test]
    fn a_request_cannot_name_a_file_outside_the_ui() {
        let ui = std::env::temp_dir();
        for bad in ["../etc/passwd", "a/../../b", "C:/Users/x/.wasm-agent/env", "\\\\server\\share\\x", "/etc/passwd", "sub\\..\\x"] {
            assert!(ui_file(&ui, bad).is_none(), "{bad} must be refused");
        }
        assert!(ui_file(&ui, "index.html").is_some());
        assert!(ui_file(&ui, "icons/icon-192.png").is_some());
    }
}
