//! `host.graph_*` — the code graph as a capability, served by the `graph` WASI component.
//!
//! Everything that parses, stores or answers lives in the component (rust/components/graph:
//! wa-graph's tree-sitter indexer, SQLite store and queries, built for wasm32-wasip2). The kernel
//! keeps only what a component cannot do by itself: choose the root and database, mount them
//! (root read-only at `/graph/root`, a private database directory read-write at `/graph/db`),
//! serialize calls per database (in-process mutex + cross-process file lock), and schedule
//! background refreshes from edit hints and the OS watcher. Each component call admits content
//! first (capture → compare → index changes as a new revision), so an answer is never older than
//! the bytes on disk when the call began; a hint only makes that admission cheap later.
//!
//! The Lua-facing surface (names, arguments, answer shapes) is unchanged.

use wa_host_support::lua::{arg_string, lua_pushlstring, LuaState};
use serde_json::{json, Value};
use std::collections::{BTreeMap, VecDeque};
use std::ffi::c_char;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

const COMPONENT: &str = "graph";
const GUEST_ROOT: &str = "/graph/root";
const GUEST_DB: &str = "/graph/db";
const DB_FILE: &str = "graph.db";
const ROOT_LIMIT: usize = 32;
/// How long a cold build may take. A first index of this repository (1,533 files, 57k definitions,
/// 168k edges) takes ~51 s in-process and ~578 s through the component (measured 05/11, docs/KERNEL.md
/// "C1 results"), so the 120 s cap this replaces refused the graph on exactly the trees it is for.
/// Read-only calls keep the caller's `wait_ms` (60 s by default): a read that would have to build a
/// cold graph is told to use read/grep while the background build finishes.
const INDEX_BUDGET: Duration = Duration::from_secs(900);

struct Config {
    root: PathBuf,
    db: PathBuf,
}

static CONFIG: OnceLock<Config> = OnceLock::new();

#[cfg(test)]
#[path = "graph_tests.rs"]
mod tests;

#[cfg(test)]
type TestCall = Box<dyn Fn(&Path, &str) -> Value + Send + Sync>;
/// A unit test cannot run the wasm component; it substitutes a deterministic answer so the
/// scheduling policy (backoff, quarantine, stop) is what the test measures.
#[cfg(test)]
static TEST_CALL: Mutex<Option<TestCall>> = Mutex::new(None);

/// Resolve the graph location once, at node startup. Root defaults to the runtime worktree (the
/// node's cwd), which is the source the agent is actually running from.
pub fn configure(root: PathBuf, db: PathBuf) {
    let _ = CONFIG.set(Config { root, db });
}

fn push_json(l: *mut LuaState, value: &Value) {
    let text = serde_json::to_string(value).unwrap_or_else(|_| "null".to_string());
    unsafe { lua_pushlstring(l, text.as_ptr() as *const c_char, text.len()) };
}

/// An optional options argument, passed as a JSON object string. Absent or malformed is `null`.
fn json_arg(l: *mut LuaState, index: std::ffi::c_int) -> Value {
    arg_string(l, index).and_then(|raw| serde_json::from_str(&raw).ok()).unwrap_or(Value::Null)
}

fn opt_str(options: &Value, key: &str) -> Option<String> {
    options.get(key).and_then(Value::as_str).map(str::to_string).filter(|s| !s.is_empty())
}

// Select root and DB together. Workspace caches are on-demand and a root never replaces another
// root's derived snapshot. An explicit `db` is used exactly (its directory is mounted for the
// component); the configured and derived ones live in a private `P.d/` directory.
fn locations(options: &Value, config: Option<&Config>) -> Result<(PathBuf, PathBuf), String> {
    let root = opt_str(options, "root").map(PathBuf::from)
        .or_else(|| config.map(|c| c.root.clone()))
        .ok_or_else(|| "graph_not_configured".to_string())?;
    let root = root.canonicalize().map_err(|e| format!("graph_root_unavailable: {e}"))?;
    if !root.is_dir() {return Err("graph_root_not_directory".into());}
    if let Some(db) = opt_str(options, "db") {return Ok((root, PathBuf::from(db)));}
    let config = config.ok_or_else(|| "graph_not_configured".to_string())?;
    let identity = |path: &Path| {
        let text = path.to_string_lossy().into_owned();
        if cfg!(windows) {text.to_lowercase()} else {text}
    };
    let same = config.root.canonicalize().ok().map(|p| identity(&p) == identity(&root)).unwrap_or(false);
    let db = if same {config.db.clone()} else {
        let digest = ring::digest::digest(&ring::digest::SHA256, identity(&root).as_bytes());
        let key: String = digest.as_ref().iter().map(|byte| format!("{byte:02x}")).collect();
        config.db.with_extension("roots").join(format!("{key}.db"))
    };
    Ok((root, db_dir(&db).join(DB_FILE)))
}

/// The component's private directory for a logical database path `P`: `P.d/`, holding `graph.db`.
/// Only this directory is mounted writable, never the directory around the ledger.
fn db_dir(db: &Path) -> PathBuf {
    let name = db.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "graph.db".into());
    db.with_file_name(format!("{name}.d"))
}

/// Source files the graph indexes (mirrors wa-graph's `extract::language_for`). Used only to drop
/// irrelevant edit hints; a hint that slips through costs one no-op admission, never correctness.
fn indexable(path: &str) -> bool {
    let path = path.replace('\\', "/");
    if path.rsplit('/').next() == Some("go.mod") {return true;}
    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    matches!(ext.as_str(), "go" | "rs" | "lua" | "sh" | "bash" | "ps1" | "psm1" | "md" | "markdown" | "js" | "mjs" | "cjs" | "jsx" | "ts" | "mts" | "cts" | "tsx")
}

/// Names the database owns inside its directory: the database, SQLite's rollback-journal siblings
/// (`-wal`, `-shm`, `-journal`) and its dot-file lock (`<db>.lock`), plus the kernel's own
/// cross-process lock (`.<db>.lock`). None of them is source. When the `db` option names a path
/// under the indexed root - `scripts/test-graph-freshness.lua` does exactly that - every index run
/// writes them inside the watched tree, and counting those writes as edits makes one refresh
/// schedule the next forever (measured 05/11: `dirty_hint`/`active` never settled, so `ready` never
/// came back).
fn database_artifact(name: &str, db_file: &str) -> bool {
    name == db_file
        || name == format!(".{db_file}.lock")
        || name == format!("{db_file}.lock")
        || matches!(name.strip_prefix(db_file), Some("-wal" | "-shm" | "-journal"))
}

fn excluded(relative: &Path) -> bool {
    relative.components().any(|part| matches!(part.as_os_str().to_str(), Some(".git" | "target" | "node_modules" | ".wa-graph" | "releases" | ".orca-worktree-trash" | "vendor" | ".cache")))
}

// ---- scheduling: one entry per (root, db), one background worker, one OS watcher ---------------

/// A failing index backs off instead of trying again at once. One attempt on a real tree costs
/// minutes, and a guest that traps costs the same every time, so the delay grows per consecutive
/// failure, is capped, and the streak stops. A broken root therefore costs a bounded amount of CPU
/// and then waits for an explicit `graph index force=true` (measured 10/11 on node `work`: a trapping
/// index re-ran with no delay at all and held one thread at ~90 % CPU while the CLI sat idle).
const RETRY_BASE: Duration = Duration::from_secs(2);
const RETRY_MAX: Duration = Duration::from_secs(300);
/// Consecutive failures after which automatic retry stops; the delays below sum to ~8 min.
const RETRY_LIMIT: u32 = 8;
/// A database is quarantined at most this many times in a row: a disk that keeps producing a
/// malformed database is reported, not rewritten in a loop.
const QUARANTINE_LIMIT: u32 = 3;
/// Free space below which a malformed database is NOT quarantined and NOT rebuilt.
///
/// WHY. A rebuild writes a whole index onto the same filesystem that is already full, and when the
/// write fails the store is malformed again - so each cycle leaves another `graph.db.malformed-*`
/// behind. Measured on `openclaw`, 11/11 05:45: ~20 quarantine copies (~2.5 GB) created between
/// 10/11 22:16 and 11/11 05:03, on a disk with 2.7 GB free of 96 GB - and disk-full froze this node
/// twice the same day. The deferral is therefore decided *before* the rename, because the rename is
/// what makes the copy. `WA_GRAPH_MIN_FREE_BYTES` overrides the floor; the state's
/// `min_free_bytes` overrides it for a test.
const REBUILD_FREE_FLOOR: u64 = 5 * 1024 * 1024 * 1024;
/// Failed rebuilds inside `REBUILD_WINDOW` after which automatic rebuild stops.
const REBUILD_LIMIT: usize = 3;
/// The window `REBUILD_LIMIT` counts over. "in 24 h" is the operator's rule: a store that has failed
/// to rebuild three times in a day is not going to be fixed by a fourth copy.
const REBUILD_WINDOW: Duration = Duration::from_secs(24 * 3600);

/// Delay before attempt `attempts + 1`: 2 s, 4 s, 8 s ... capped at `RETRY_MAX`.
fn retry_delay(attempts: u32) -> Duration {
    let shift = attempts.saturating_sub(1).min(8);
    (RETRY_BASE * (1u32 << shift)).min(RETRY_MAX)
}

/// Whether another automatic attempt is allowed after `attempts` consecutive failures.
fn retry_allowed(attempts: u32) -> bool {
    attempts < RETRY_LIMIT
}

/// Seconds since the Unix epoch; the clock the 24 h rebuild budget counts on.
fn epoch_seconds() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|elapsed| elapsed.as_secs()).unwrap_or(0)
}

/// The floor a rebuild needs, with the environment's override. Read at the moment of the decision, not
/// cached: an operator who lowers it to let one rebuild through does not restart the node to be heard.
fn rebuild_free_floor() -> u64 {
    std::env::var("WA_GRAPH_MIN_FREE_BYTES").ok().and_then(|text| text.trim().parse::<u64>().ok()).unwrap_or(REBUILD_FREE_FLOOR)
}

/// The free-space decision for one database directory.
///
/// `Measured(free)` below the floor is a deferral. `Unmeasurable` is NOT: a probe that cannot answer
/// must not permanently disable the one repair the indexer has, so the rebuild proceeds and the 24 h
/// budget (`REBUILD_LIMIT`) still bounds how many copies it can leave. The distinction is named in the
/// log line either way, because "the disk is fine" and "nobody looked" must not read the same.
enum DiskAnswer { Enough(u64), Low(u64), Unmeasurable }

fn disk_answer(dir: &Path, floor: u64) -> DiskAnswer {
    match wa_host_support::system_resources::free_space(dir) {
        Some((free, _total)) if free < floor => DiskAnswer::Low(free),
        Some((free, _total)) => DiskAnswer::Enough(free),
        None => DiskAnswer::Unmeasurable,
    }
}

/// Drop the rebuild timestamps that have left the window, and answer how many are inside it.
fn rebuilds_in_window(rebuilds: &mut Vec<u64>, now: u64) -> usize {
    let window = REBUILD_WINDOW.as_secs();
    rebuilds.retain(|at| now.saturating_sub(*at) < window);
    rebuilds.len()
}

/// One failing streak prints one line: only a new error text is worth another line.
fn report_needed(reported: Option<&str>, error: &str) -> bool {
    reported != Some(error)
}

/// The texts a corrupt database answers with. The guest reports SQLite's own message
/// (`database disk image is malformed`, `file is not a database` - measured 10/11 on node `work`)
/// and its own stable marker.
fn malformed(error: &str) -> bool {
    let error = error.to_ascii_lowercase();
    ["graph_db_malformed", "database disk image is malformed", "file is not a database"]
        .iter()
        .any(|marker| error.contains(marker))
}

/// `YYYYMMDDTHHMMSSZ` for `seconds` since the Unix epoch, with no date crate. Days-to-civil is
/// Howard Hinnant's algorithm.
fn utc_stamp(seconds: u64) -> String {
    let days = (seconds / 86_400) as i64;
    let rest = seconds % 86_400;
    let (hour, minute, second) = (rest / 3_600, (rest % 3_600) / 60, rest % 60);
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { yoe + era * 400 + 1 } else { yoe + era * 400 };
    format!("{year:04}{month:02}{day:02}T{hour:02}{minute:02}{second:02}Z")
}

#[derive(Default)]
struct State {
    queued: bool,
    active: bool,
    dirty: bool,
    watched: bool,
    watch_error: Option<String>,
    failure: Option<String>,
    /// Consecutive failed background attempts; reset by a success.
    attempts: u32,
    /// Earliest instant the next automatic attempt may start.
    retry_at: Option<Instant>,
    /// Automatic retry stopped after `RETRY_LIMIT` failures; an explicit index resumes it.
    stopped: bool,
    /// The last error text printed, so one failing streak prints one line, not one per attempt.
    reported: Option<String>,
    /// Where malformed databases were moved, newest last.
    quarantined: Vec<PathBuf>,
    /// Consecutive quarantines, bounding a disk that keeps corrupting.
    corruptions: u32,
    /// When the automatic rebuilds that did not succeed happened, epoch seconds, newest last. This is
    /// the 24 h budget: it survives a recovery (which clears it) and an `attempts` reset (a quarantine
    /// does that), because the copies a loop leaves behind are not about one streak.
    rebuilds: Vec<u64>,
    /// The free-space floor in bytes; 0 means `REBUILD_FREE_FLOOR` (or `WA_GRAPH_MIN_FREE_BYTES`). Set
    /// here so a test can force the low-disk path without filling the machine's disk.
    min_free_bytes: u64,
}

struct Entry {
    root: PathBuf,
    db: PathBuf,
    calls: Mutex<()>,
    state: Mutex<State>,
}

struct Scheduler {
    entries: Mutex<BTreeMap<(PathBuf, PathBuf), Arc<Entry>>>,
    ready: Mutex<VecDeque<(Option<Instant>, Arc<Entry>)>>,
    wake: Condvar,
    watcher: Mutex<Option<notify::RecommendedWatcher>>,
}

fn scheduler() -> &'static Arc<Scheduler> {
    static INSTANCE: OnceLock<Arc<Scheduler>> = OnceLock::new();
    INSTANCE.get_or_init(|| {
        let scheduler = Arc::new(Scheduler { entries: Mutex::new(BTreeMap::new()), ready: Mutex::new(VecDeque::new()), wake: Condvar::new(), watcher: Mutex::new(None) });
        if std::env::var("WA_GRAPH_WATCH").map_or(true, |value| value != "0") {
            let weak = Arc::downgrade(&scheduler);
            match notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                if let Some(scheduler) = weak.upgrade() {scheduler.event(event);}
            }) {
                Ok(watcher) => *scheduler.watcher.lock().unwrap() = Some(watcher),
                Err(error) => eprintln!("graph_watch_create_failed: {error}; content admission remains authoritative"),
            }
        }
        let worker = scheduler.clone();
        if let Err(error) = std::thread::Builder::new().name("wa-graph-schedule".into()).spawn(move || worker.run()) {
            eprintln!("graph_worker_spawn_failed: {error}; queries still admit content themselves");
        }
        scheduler
    })
}

impl Scheduler {
    fn entry(&self, root: &Path, db: &Path) -> Result<Arc<Entry>, String> {
        let db = if db.is_absolute() {db.to_path_buf()} else {std::env::current_dir().map_err(|e| e.to_string())?.join(db)};
        let key = (root.to_path_buf(), db.clone());
        let mut entries = self.entries.lock().map_err(|_| "graph_scheduler_poisoned")?;
        if let Some(entry) = entries.get(&key) {return Ok(entry.clone());}
        if entries.len() >= ROOT_LIMIT {
            let idle = entries.iter().find_map(|(key, entry)| {
                let state = entry.state.try_lock().ok()?;
                (Arc::strong_count(entry) == 1 && !state.queued && !state.active).then(|| key.clone())
            });
            match idle {
                Some(key) => {
                    let old = entries.remove(&key).unwrap();
                    if !entries.values().any(|other| other.root == old.root) {
                        use notify::Watcher as _;
                        if let Some(watcher) = self.watcher.lock().unwrap().as_mut() {let _ = watcher.unwatch(&old.root);}
                    }
                }
                None => return Err("graph_root_capacity: 32 active roots; finish existing work before admitting another".into()),
            }
        }
        let entry = Arc::new(Entry { root: root.to_path_buf(), db, calls: Mutex::new(()), state: Mutex::new(State::default()) });
        let shared_root = entries.values().any(|other| other.root == entry.root);
        entries.insert(key, entry.clone());
        drop(entries);
        if let Some(watcher) = self.watcher.lock().unwrap().as_mut() {
            use notify::Watcher as _;
            let result = if shared_root {Ok(())} else {watcher.watch(&entry.root, notify::RecursiveMode::Recursive)};
            let mut state = entry.state.lock().unwrap();
            state.watched = result.is_ok();
            state.watch_error = result.err().map(|error| error.to_string());
            if let Some(error) = &state.watch_error {eprintln!("graph_watch_register_failed root={} error={error}; content admission remains authoritative", entry.root.display());}
        }
        Ok(entry)
    }

    fn enqueue(&self, entry: &Arc<Entry>) {
        let mut state = entry.state.lock().unwrap();
        state.dirty = true;
        // A hint records that content may have changed, but a stopped streak stays stopped: an
        // edit event must never resurrect a failing index by itself, or the retry is unbounded.
        if state.queued || state.active || state.stopped {return;}
        state.queued = true;
        let due = state.retry_at;
        drop(state);
        self.ready.lock().unwrap().push_back((due, entry.clone()));
        self.wake.notify_one();
    }

    fn event(&self, event: notify::Result<notify::Event>) {
        if event.as_ref().map_or(false, ignored) {return;}
        let normalize = |path: &Path| {let text = path.to_string_lossy().replace('\\', "/").trim_start_matches("//?/").to_string(); if cfg!(windows) {text.to_lowercase()} else {text}};
        let entries: Vec<_> = self.entries.lock().unwrap().values().filter(|entry| {
            let db_file = entry.db.file_name().and_then(|name| name.to_str()).unwrap_or(DB_FILE).to_string();
            event.as_ref().map_or(true, |event| event.paths.is_empty() || event.paths.iter().any(|path| {
                // The database's own files are not source (see `database_artifact`).
                if path.file_name().and_then(|name| name.to_str()).map_or(false, |name| database_artifact(name, &db_file)) {return false;}
                let root = normalize(&entry.root);
                let path = normalize(path);
                path == root || path.starts_with(&(root + "/"))
            }))
        }).cloned().collect();
        for entry in entries {self.enqueue(&entry);}
    }

    fn notify_path(&self, path: &Path) {
        if !indexable(&path.to_string_lossy()) {return;}
        let Ok(path) = path.canonicalize() else {return};
        let entries: Vec<_> = self.entries.lock().unwrap().values()
            .filter(|entry| path.strip_prefix(&entry.root).map_or(false, |relative| !excluded(relative))).cloned().collect();
        for entry in entries {self.enqueue(&entry);}
    }

    fn run(&self) {
        loop {
            // Only an entry whose retry time has come is taken; the rest wait on the condvar until
            // the earliest one is due. This is what turns a failing index into a bounded delay
            // instead of a loop that re-runs it as soon as the previous attempt returns.
            let entry = {
                let mut ready = self.ready.lock().unwrap();
                loop {
                    let now = Instant::now();
                    if let Some(index) = ready.iter().position(|(due, _)| due.map_or(true, |due| due <= now)) {
                        break ready.remove(index).unwrap().1;
                    }
                    let wait = ready.iter().filter_map(|(due, _)| *due).map(|due| due.saturating_duration_since(now)).min();
                    ready = match wait {
                        Some(wait) => self.wake.wait_timeout(ready, wait).unwrap().0,
                        None => self.wake.wait(ready).unwrap(),
                    };
                }
            };
            // A bounded quiet window coalesces bursts without waiting forever for a busy writer.
            std::thread::sleep(Duration::from_millis(75));
            {let mut state = entry.state.lock().unwrap(); state.queued = false; state.active = true; state.dirty = false; state.retry_at = None;}
            let outcome = call(&entry, "index", json!({}), Instant::now() + INDEX_BUDGET);
            let error = outcome.get("error").and_then(Value::as_str).map(str::to_string);
            {entry.state.lock().unwrap().active = false;}
            match error {
                None => self.recovered(&entry),
                Some(error) => self.failed(&entry, error),
            }
        }
    }

    /// A success ends the streak, so the next failure starts again at the first delay - and it ends the
    /// 24 h rebuild budget, because a rebuild that worked is not one of the copies a loop leaves behind.
    fn recovered(&self, entry: &Arc<Entry>) {
        let mut state = entry.state.lock().unwrap();
        let attempts = std::mem::take(&mut state.attempts);
        state.stopped = false;
        state.retry_at = None;
        state.failure = None;
        state.reported = None;
        state.corruptions = 0;
        state.rebuilds.clear();
        drop(state);
        if attempts > 0 {eprintln!("graph_index_recovered root={} after_failures={attempts}", entry.root.display());}
    }

    /// One failure, one decision and at most one log line.
    ///
    /// A malformed database has two more gates before it is moved aside, and both exist because moving
    /// it aside IS the copy:
    ///
    ///   1. **the disk.** Below the floor there is no room for the rebuild, so the rebuild is deferred
    ///      and reported once as `graph_rebuild_deferred: low_disk` - the store is left where it is and
    ///      no new `graph.db.malformed-*` is created;
    ///   2. **the 24 h budget.** `REBUILD_LIMIT` failed rebuilds in `REBUILD_WINDOW` and automatic
    ///      rebuild stops outright (`graph_rebuild_stopped: failed_rebuilds`), which is the rule that
    ///      bounds a disk whose every rebuild goes malformed again.
    fn failed(&self, entry: &Arc<Entry>, error: String) {
        let mut state = entry.state.lock().unwrap();
        state.attempts = state.attempts.saturating_add(1);
        state.failure = Some(error.clone());
        let attempts = state.attempts;
        let corrupt = malformed(&error);
        let now = epoch_seconds();
        let recent = rebuilds_in_window(&mut state.rebuilds, now);
        let floor = if state.min_free_bytes > 0 {state.min_free_bytes} else {rebuild_free_floor()};
        let disk = if corrupt {
            let dir = entry.db.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."));
            Some(disk_answer(&dir, floor))
        } else {None};
        let low = matches!(disk, Some(DiskAnswer::Low(_)));
        let over_budget = corrupt && recent >= REBUILD_LIMIT;
        let quarantine = corrupt && !low && !over_budget && state.corruptions < QUARANTINE_LIMIT && entry.db.exists();
        drop(state);

        // 1. Low disk: neither rename nor rebuild. `stopped` is the honest state - nothing further will
        //    be tried automatically until an explicit index, and that is the point: the loop must stop
        //    spending the disk it does not have.
        if low {
            let free = match disk {Some(DiskAnswer::Low(free)) => free, _ => 0};
            let line = format!("graph_rebuild_deferred: low_disk root={} free_bytes={free} floor_bytes={floor}", entry.root.display());
            // The streak's identity is the root and the floor - not free_bytes, which moves by a few bytes
            // between two attempts whenever anything else writes, and made the same deferral print again.
            let key = format!("graph_rebuild_deferred: low_disk root={} floor_bytes={floor}", entry.root.display());
            let mut state = entry.state.lock().unwrap();
            state.stopped = true;
            state.retry_at = None;
            let report = report_needed(state.reported.as_deref(), &key);
            if report {state.reported = Some(key);}
            drop(state);
            if report {eprintln!("{line}");}
            return;
        }

        // 2. The budget is spent: stop, and say how many rebuilds failed inside the window.
        if over_budget {
            let line = format!("graph_rebuild_stopped: failed_rebuilds root={} rebuilds={recent} window_hours={} use=graph_index_force",
                entry.root.display(), REBUILD_WINDOW.as_secs() / 3600);
            let mut state = entry.state.lock().unwrap();
            state.stopped = true;
            state.retry_at = None;
            let report = report_needed(state.reported.as_deref(), &line);
            if report {state.reported = Some(line.clone());}
            drop(state);
            if report {eprintln!("{line}");}
            return;
        }

        if quarantine {
            let seconds = now;
            match quarantine_database(entry, &utc_stamp(seconds)) {
                Ok(moved) if !moved.is_empty() => {
                    let names: Vec<String> = moved.iter().map(|path| path.display().to_string()).collect();
                    let mut state = entry.state.lock().unwrap();
                    state.corruptions = state.corruptions.saturating_add(1);
                    state.quarantined.extend(moved);
                    // One copy is now on the disk and one rebuild is about to be attempted: count it
                    // against the 24 h budget before the attempt, so a rebuild that never returns still
                    // costs its copy. A success clears the budget in `recovered`.
                    state.rebuilds.push(now);
                    // The rebuild is the fix: a fresh database, attempted at once, is not a retry of
                    // the broken one. `rebuilds` bounds a disk that keeps producing garbage.
                    state.attempts = 0;
                    state.stopped = false;
                    state.retry_at = None;
                    state.reported = Some(error.clone());
                    drop(state);
                    let disk_note = match disk {Some(DiskAnswer::Enough(free)) => format!(" free_bytes={free} floor_bytes={floor}"), Some(DiskAnswer::Unmeasurable) => " free_bytes=unknown".to_string(), _ => String::new()};
                    // One line, with the reason: `moved` is one copy now, kept for evidence, and the
                    // reason is what a human needs to tell a torn read from a damaged b-tree.
                    eprintln!("graph_db_quarantined root={} moved={} reason={} next=rebuild{disk_note}",
                        entry.root.display(), names.join(","), error.replace(char::is_whitespace, "_"));
                    self.enqueue(&entry);
                    return;
                }
                Ok(_) => {}
                Err(error) => eprintln!("graph_db_quarantine_failed root={} error={error}", entry.root.display()),
            }
        }
        let retry = retry_allowed(attempts);
        let mut state = entry.state.lock().unwrap();
        state.stopped = !retry;
        state.retry_at = retry.then(|| Instant::now() + retry_delay(attempts));
        let report = report_needed(state.reported.as_deref(), &error);
        if report {state.reported = Some(error.clone());}
        let next = match state.retry_at {Some(at) => format!("retry_in_ms={}", at.saturating_duration_since(Instant::now()).as_millis()), None => "automatic_retry=stopped use=graph_index_force".to_string()};
        drop(state);
        if report {eprintln!("graph_index_failed root={} attempts={attempts} {next} error={error}", entry.root.display());}
        if retry {self.enqueue(&entry);}
    }

    /// An explicit index is a deliberate retry: clear the streak so the policy starts from the
    /// first delay again, and let queued hints run. The 24 h rebuild budget is not cleared - it is about
    /// copies on the disk, not about intent - but one entry is retired so the explicit retry it was asked
    /// for can happen exactly once. Three more copies still need three more explicit decisions.
    fn resume(&self, entry: &Arc<Entry>) {
        let mut state = entry.state.lock().unwrap();
        state.attempts = 0;
        state.stopped = false;
        state.retry_at = None;
        state.corruptions = 0;
        state.reported = None;
        let now = epoch_seconds();
        rebuilds_in_window(&mut state.rebuilds, now);
        if state.rebuilds.len() >= REBUILD_LIMIT {state.rebuilds.remove(0);}
        let queued = state.dirty && !state.queued && !state.active;
        if queued {state.queued = true;}
        drop(state);
        if queued {self.ready.lock().unwrap().push_back((None, entry.clone()));self.wake.notify_one();}
    }
}

/// Unsupported file events and our own DB/build writes cannot create a refresh loop.
fn ignored(event: &notify::Event) -> bool {
    if matches!(event.kind, notify::EventKind::Access(_)) {return true;}
    // Empty paths represent overflow/rescan hints and must reconcile every registered root.
    if event.paths.is_empty() {return false;}
    event.paths.iter().all(|path| {
        let text = path.to_string_lossy().replace('\\', "/");
        text.split('/').any(|part| matches!(part, ".git" | "target" | ".wa-graph" | "vendor" | ".cache" | "node_modules" | "releases" | ".orca-worktree-trash"))
            || (!path.is_dir() && !indexable(&text) && !matches!(event.kind,
                notify::EventKind::Remove(notify::event::RemoveKind::Folder)
                    | notify::EventKind::Modify(notify::event::ModifyKind::Name(_))
                    | notify::EventKind::Create(notify::event::CreateKind::Folder)))
    })
}

// ---- one component call -------------------------------------------------------------------------

/// Guest paths in an answer become the host paths they stand for.
fn host_paths(value: &mut Value, root: &str, db: &str) {
    match value {
        Value::String(text) => {
            for (guest, host) in [(GUEST_ROOT, root), (GUEST_DB, db)] {
                if let Some(rest) = text.strip_prefix(guest).filter(|rest| rest.is_empty() || rest.starts_with('/')) {
                    *text = format!("{host}{}", rest.replace('/', std::path::MAIN_SEPARATOR_STR));
                    break;
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(|item| host_paths(item, root, db)),
        Value::Object(map) => map.values_mut().for_each(|item| host_paths(item, root, db)),
        _ => {}
    }
}

/// Windows canonical paths carry the verbatim prefix (`\\?\C:\...`); the mount takes the plain
/// drive form. Answers still report the canonical root, as before.
fn mountable(path: &str) -> String {
    match path.strip_prefix(r"\\?\") {
        Some(rest) if !rest.starts_with("UNC\\") => rest.to_string(),
        _ => path.to_string(),
    }
}

/// Run one tool of the graph component for `entry`, holding the entry's call lock (and the
/// database directory's file lock, for other processes on the same node) until `deadline`.
fn call(entry: &Arc<Entry>, tool: &str, mut arguments: Value, deadline: Instant) -> Value {
    // Tests drive the scheduling policy with a failing component; the component itself needs the
    // built wasm binary, which a unit test does not have.
    #[cfg(test)]
    if let Some(replacement) = TEST_CALL.lock().unwrap_or_else(|error| error.into_inner()).as_ref() {
        return replacement(&entry.root, tool);
    }
    let calls = loop {
        match entry.calls.try_lock() {
            Ok(guard) => break guard,
            Err(std::sync::TryLockError::Poisoned(poisoned)) => break poisoned.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => {}
        }
        if Instant::now() >= deadline {return json!({"error":"graph_wait_timeout","next":"Use bounded read/grep now. Another graph call on this root is still running. No stale answer was returned."});}
        crate::serve::beat();
        std::thread::sleep(Duration::from_millis(10));
    };
    let dir = entry.db.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."));
    let file = entry.db.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| DB_FILE.into());
    if let Err(error) = std::fs::create_dir_all(&dir) {return json!({"error": format!("graph_db_unavailable: {error}")});}
    // The cross-process lock is a file beside the database, and its NAME is load-bearing: SQLite in
    // the component locks through its dot-file style, `%s.lock` beside the database (measured
    // 05/11: a pre-existing `<db>.lock` made every write answer `database is locked` for the whole
    // busy timeout). The kernel's file is therefore dot-prefixed, so it can never be mistaken for
    // the guest's own lock.
    let lock = match lock_store(&dir, &file, None) {
        Ok(Some(handle)) => handle,
        Ok(None) => return json!({"error": "graph_db_lock_failed: the store's lock was not released before the call"}),
        Err(error) => return json!({"error": format!("graph_db_unavailable: {error}")}),
    };
    // A component run killed mid-transaction (its deadline, or a node stop) leaves the guest's
    // dot-file lock behind, and every later write then answers `database is locked` for the whole
    // busy timeout - a permanently broken graph. This lock proves no graph call on this database is
    // running: every one of them, foreground and background, is behind it. A `<db>.lock` found here
    // therefore has no owner, so it is removed. Never the kernel's own `.<db>.lock`, which is this
    // handle.
    let stale = dir.join(format!("{file}.lock"));
    if stale.symlink_metadata().is_ok() {
        let removed = if stale.is_dir() {std::fs::remove_dir_all(&stale)} else {std::fs::remove_file(&stale)};
        if removed.is_ok() {eprintln!("graph_db_stale_lock_removed file={file}");}
    }
    let remaining = deadline.saturating_duration_since(Instant::now()).as_secs().max(1);
    if !arguments.is_object() {arguments = json!({});}
    let root_text = entry.root.to_string_lossy().into_owned();
    let dir_text = dir.to_string_lossy().into_owned();
    arguments["db_file"] = json!(file);
    arguments["_display_root"] = json!(root_text);
    arguments["_display_db"] = json!(entry.db.to_string_lossy());
    guest_changes(&mut arguments, &entry.root);
    let request = json!({
        "action": "call", "component": COMPONENT, "tool": tool, "arguments": arguments,
        "dirs": [{"host": mountable(&root_text), "guest": GUEST_ROOT, "write": false}, {"host": mountable(&dir_text), "guest": GUEST_DB, "write": true}],
        "env": {"WA_GRAPH_PARSE_TIMEOUT_MS": "WA_GRAPH_PARSE_TIMEOUT_MS"},
        "timeout_seconds": remaining,
    });
    let answer = wa_kernel_runtime::components::mcp(&request);
    let _ = lock.unlock();
    drop(calls);
    if answer["ok"] != json!(true) {
        let error = answer["error"].as_str().unwrap_or("graph_component_failed").to_string();
        return json!({"error": format!("graph_component_unavailable: {error}"), "component": answer,
            "next": "Use bounded read/grep now. The graph component did not answer. No stale answer was returned."});
    }
    let mut result = answer["result_json"].as_str()
        .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
        .map(|result| result["structuredContent"].clone())
        .unwrap_or_else(|| json!({"error":"graph_component_bad_answer"}));
    host_paths(&mut result, &root_text, &dir_text);
    result
}

/// The store's cross-process lock, opened (and created if needed) and never locked here.
///
/// Its NAME is load-bearing: SQLite in the component locks through its dot-file style,
/// `%s.lock` beside the database (measured 05/11: a pre-existing `<db>.lock` made every write
/// answer `database is locked` for the whole busy timeout), so the kernel's file is dot-prefixed and
/// can never be mistaken for the guest's own lock. Every opener of a graph store takes this file:
/// every component call (`call`), the quarantine rename (`quarantine_database`) and the pre-update
/// snapshot (`snapshot_store`, `host.graph_snapshot`). That is what makes the store single-writer.
fn store_lock_file(dir: &Path, file: &str) -> std::io::Result<std::fs::File> {
    std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(dir.join(format!(".{file}.lock")))
}

/// Hold the store's lock for as long as the returned handle lives.
///
/// `deadline` None waits until the lock is free (a call must not be dropped); `Some(deadline)` gives
/// up at the deadline and answers `Ok(None)`, which is how a background reader stays bounded instead
/// of parking behind a 900 s index.
fn lock_store(dir: &Path, file: &str, deadline: Option<Instant>) -> std::io::Result<Option<std::fs::File>> {
    let handle = store_lock_file(dir, file)?;
    let Some(deadline) = deadline else {
        // A call waits for as long as the call in front of it takes: that is what it did before this
        // helper existed, and a poll loop here would only add wake-ups to a 900 s index.
        handle.lock()?;
        return Ok(Some(handle));
    };
    loop {
        match handle.try_lock() {
            Ok(()) => return Ok(Some(handle)),
            Err(std::fs::TryLockError::WouldBlock) => {}
            Err(std::fs::TryLockError::Error(error)) => return Err(error),
        }
        if Instant::now() >= deadline {return Ok(None);}
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// Move a malformed database - and SQLite's own siblings - aside under a timestamped name. It is
/// derived state but still state: renamed, never deleted (skills/clean-disk rule 4). The rename runs
/// under the same cross-process lock every graph call takes, so another node process sharing this
/// database cannot keep writing into a file that is being moved.
///
/// ONE COPY PER STORE (13/11). Each detection used to leave its own copy, and a store that came back
/// malformed after every rebuild left one copy per cycle: 77 files (~4 GB) in `graph.db.d/` on node
/// `work` between 10/11 and 13/11, 30 more on `openclaw`. The copy that is about to be replaced is
/// therefore removed first, by name and only for THIS store's own siblings, so the directory holds
/// the newest quarantine and nothing else. `scripts/reclaim-disk.mjs` still reclaims a directory an
/// older binary filled, keeping its newest copy.
fn quarantine_database(entry: &Arc<Entry>, stamp: &str) -> std::io::Result<Vec<PathBuf>> {
    let dir = entry.db.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."));
    let file = entry.db.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_else(|| DB_FILE.to_string());
    let lock = match lock_store(&dir, &file, None)? {
        Some(handle) => handle,
        None => return Err(std::io::Error::other("the store's lock was not released")),
    };
    let prefix = format!("{file}.malformed-");
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.starts_with(&prefix) {continue;}
            let _ = std::fs::remove_file(entry.path());
        }
    }
    let mut moved = Vec::new();
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let source = dir.join(format!("{file}{suffix}"));
        if !source.exists() {continue;}
        let target = dir.join(format!("{file}.malformed-{stamp}{suffix}"));
        if std::fs::rename(&source, &target).is_ok() {moved.push(target);}
    }
    let _ = lock.unlock();
    Ok(moved)
}

/// A snapshot of one graph store, taken under the store's own lock.
#[derive(Debug)]
struct StoreSnapshot {
    source: PathBuf,
    copy: PathBuf,
    check: String,
    attempts: u32,
}

/// Snapshot `db` into `copy` (which must not exist) while holding the store's cross-process lock.
///
/// WHY THE LOCK AND NOT JUST THE ONLINE BACKUP API. The graph store has two openers with two
/// different locking realities, and that is the corruption this exists to stop (measured 13/11, and
/// reproduced on `wa-desktop` the same day: 3,653 `database disk image is malformed` reads and torn
/// copies in 70 s while a component indexed):
///
///  * the `graph` WASI component writes the store from inside wasmtime, where SQLite's OS layer has
///    no POSIX byte-range locks, so its pages are overwritten without excluding anybody. The journal
///    mode is `delete` there too, whatever `wa_sqlite::tune` asks for (`PRAGMA journal_mode=WAL`
///    cannot take effect in the guest), and in `delete` mode a commit IS a page overwrite;
///  * the kernel's native SQLite reads the same file for the pre-update backup. It takes real locks,
///    which the guest does not honour, so a `VACUUM INTO` or a hot-journal recovery ran against a
///    store that was being written.
///
/// The store was therefore never damaged - it passed `PRAGMA integrity_check` immediately after - but
/// whichever side lost the race reported `database disk image is malformed`. That verdict refused
/// `wa update` (`backup_failed: .../graph.db.d/graph.db: ...`) and, when the component saw it, moved
/// the store aside and rebuilt it: one `graph.db.malformed-*` per cycle, 77 of them on node `work`.
///
/// The lock every component call holds is the single writer, and the guest only exists inside such a
/// call, so holding it here means no guest is running: the read cannot tear. `wait` bounds the wait,
/// because an index may hold the lock for minutes and a backup that blocks a deploy is the other half
/// of the same bug - past the deadline the answer is `graph_store_busy`, which the backup reports and
/// steps over.
fn snapshot_store(db: &Path, copy: &Path, wait: Duration) -> Result<StoreSnapshot, String> {
    if db.as_os_str().is_empty() {return Err("graph_snapshot_failed: no store was named".into());}
    let dir = db.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."));
    let file = db.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_else(|| DB_FILE.to_string());
    if let Some(parent) = copy.parent() {std::fs::create_dir_all(parent)
        .map_err(|error| format!("graph_snapshot_failed: the destination directory {} cannot be created: {error}", parent.display()))?;}
    let deadline = Instant::now() + wait;
    let _guard = lock_store(&dir, &file, Some(deadline))
        .map_err(|error| format!("graph_snapshot_failed: the store's lock cannot be opened: {error}"))?
        .ok_or_else(|| format!("graph_store_busy: a graph call on {} still holds the store after {} ms", db.display(), wait.as_millis()))?;
    if !db.exists() {return Err(format!("graph_store_missing: {}", db.display()));}
    // A copy the failed attempt before this one left behind is emptied first: `VACUUM INTO` refuses a
    // destination that exists and is not empty ("output file already exists"), which is exactly the
    // refusal that blocked `wa update` on both peers on 11/11.
    if copy.exists() {let _ = std::fs::remove_file(copy);}
    // Read-write, not read-only: a guest killed mid-transaction leaves a hot journal, and recovering
    // it is a write. The store's lock is held, so no guest and no call exists to compete with it.
    let source = rusqlite::Connection::open_with_flags(db, rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE)
        .map_err(|error| snapshot_failure(&error.to_string()))?;
    source.busy_timeout(Duration::from_millis(wait.as_millis().min(5_000) as u64))
        .map_err(|error| snapshot_failure(&error.to_string()))?;
    let mut attempt = 0u32;
    loop {
        attempt += 1;
        // ONE READ THROUGH SQLITE, never a byte copy: `VACUUM INTO` writes every committed page of the
        // store - a rollback-journal commit included - into a new file, so what lands is a database.
        match source.execute("VACUUM INTO ?1", [copy.to_string_lossy().as_ref()]) {
            Ok(_) => break,
            Err(error) => {
                let text = error.to_string();
                if attempt >= 2 || !contended(&text) {return Err(snapshot_failure(&text));}
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
    // The copy must be a database before it can be a recovery source; a destination that a killed
    // attempt left empty fails here rather than passing as a snapshot.
    let check = copy_verdict(copy)?;
    if check != "ok" {return Err(format!("graph_snapshot_failed: the copy did not pass integrity_check: {check}"));}
    Ok(StoreSnapshot { source: db.to_path_buf(), copy: copy.to_path_buf(), check, attempts: attempt })
}

/// Why a snapshot could not be taken, in the three names the pre-update backup acts on.
fn snapshot_failure(text: &str) -> String {
    let lower = text.to_ascii_lowercase();
    if lower.contains("locked") || lower.contains("busy") {
        return format!("graph_store_busy: {text}");
    }
    if lower.contains("malformed") || lower.contains("not a database") || lower.contains("corrupt") {
        return format!("graph_store_damaged: {text}");
    }
    format!("graph_snapshot_failed: {text}")
}

/// Is this failure contention (worth one more read) rather than a verdict about the store?
fn contended(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("locked") || lower.contains("busy")
}

/// `PRAGMA integrity_check` on one store, read-only: `"ok"` or SQLite's first complaint.
fn copy_verdict(store: &Path) -> Result<String, String> {
    let connection = rusqlite::Connection::open_with_flags(store, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|error| snapshot_failure(&error.to_string()))?;
    let mut statement = connection.prepare("PRAGMA integrity_check")
        .map_err(|error| snapshot_failure(&error.to_string()))?;
    let mut rows = statement.query([]).map_err(|error| snapshot_failure(&error.to_string()))?;
    let mut first: Option<String> = None;
    while let Some(row) = rows.next().map_err(|error| snapshot_failure(&error.to_string()))? {
        let text: String = row.get(0).map_err(|error| snapshot_failure(&error.to_string()))?;
        if text == "ok" {return Ok(text);}
        if first.is_none() {first = Some(text);}
    }
    Ok(first.unwrap_or_else(|| "unknown".to_string()))
}

/// A changeset may name files by absolute host path (native changesets do); inside the component
/// the root is `/graph/root`. Paths outside the root stay as they are and are refused there.
fn guest_changes(arguments: &mut Value, root: &Path) {
    let Some(changes) = arguments.get_mut("changes").and_then(Value::as_array_mut) else {return};
    for change in changes {
        for key in ["path", "old_path"] {
            let Some(raw) = change.get(key).and_then(Value::as_str) else {continue};
            let path = Path::new(raw);
            if !path.is_absolute() {continue;}
            let path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
            if let Ok(relative) = path.strip_prefix(root) {
                change[key] = json!(format!("{GUEST_ROOT}/{}", relative.to_string_lossy().replace('\\', "/")));
            }
        }
    }
}

/// Overlay the kernel's scheduling state on a full status or snapshot object (not on the compact
/// `{required_revision, committed_revision, wait_ms}` a budgeted view already measured itself with).
fn overlay(entry: &Entry, value: &mut Value) {
    if value.get("workspace_revision").is_none() {return;}
    let state = entry.state.lock().unwrap();
    value["queued"] = json!(state.queued);
    value["active"] = json!(state.active);
    value["dirty_hint"] = json!(state.dirty);
    value["watch_registered"] = json!(state.watched);
    value["watch_error"] = json!(state.watch_error);
    value["failure"] = json!(state.failure);
    value["index_attempts"] = json!(state.attempts);
    value["retry_exhausted"] = json!(state.stopped);
    value["retry_in_ms"] = json!(state.retry_at.map(|at| at.saturating_duration_since(Instant::now()).as_millis() as u64));
    value["quarantined"] = json!(state.quarantined);
}

fn wait_deadline(options: &Value) -> Instant {
    Instant::now() + Duration::from_millis(options.get("wait_ms").and_then(Value::as_u64).unwrap_or(60_000).clamp(1, 120_000))
}

/// One read capability: resolve locations, register the root, run the tool.
fn run(options: Value, tool: &str, extra: &[(&str, Value)]) -> Value {
    let outcome = (|| -> Result<Value, String> {
        let (root, db) = locations(&options, CONFIG.get())?;
        let entry = scheduler().entry(&root, &db)?;
        let deadline = if tool == "index" {Instant::now() + INDEX_BUDGET} else {wait_deadline(&options)};
        let mut arguments = if options.is_object() {options.clone()} else {json!({})};
        for (key, value) in extra {arguments[*key] = value.clone();}
        // An explicit index is a deliberate retry: clear a stopped streak first so the attempt is
        // allowed, and end it on success.
        if tool == "index" {scheduler().resume(&entry);}
        let mut answer = call(&entry, tool, arguments, deadline);
        if tool == "index" && answer.get("error").is_none() {scheduler().recovered(&entry);}
        if let Some(snapshot) = answer.get_mut("graph_snapshot") {overlay(&entry, snapshot);}
        if answer.get("error").is_some() && answer.get("required_revision").is_some() {overlay(&entry, &mut answer);}
        Ok(answer)
    })();
    outcome.unwrap_or_else(|error| json!({ "error": error }))
}

fn reply(l: *mut LuaState, value: Value) -> std::ffi::c_int {
    push_json(l, &value);
    1
}

/// host.graph_index(opts_json?) -> {ok, indexed, unchanged, removed, nodes, edges, ...} | {error}
///
/// Build or refresh the graph. Incremental by content hash, so a repeat call with nothing changed
/// reparses nothing. `{ "root": "...", "force": true }` overrides the configured location.
pub extern "C-unwind" fn graph_index(l: *mut LuaState) -> std::ffi::c_int {
    let options = json_arg(l, 1);
    reply(l, run(options, "index", &[]))
}

/// host.graph_query(text, opts_json?) -> [ {kind,name,path,line,detail} ] | {error}
pub extern "C-unwind" fn graph_query(l: *mut LuaState) -> std::ffi::c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    reply(l, run(json_arg(l, 2), "query", &[("text", json!(text))]))
}

/// host.graph_search(text, opts_json?) -> ranked symbol selectors with confidence evidence.
pub extern "C-unwind" fn graph_search(l: *mut LuaState) -> std::ffi::c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    reply(l, run(json_arg(l, 2), "search", &[("text", json!(text))]))
}

/// host.graph_sources(opts_json) — one root, admission revision and pinned snapshot for every selector.
pub extern "C-unwind" fn graph_sources(l: *mut LuaState) -> std::ffi::c_int {
    reply(l, run(json_arg(l, 1), "sources", &[]))
}

/// A successful native write is a hint: refresh that root in the background.
pub(crate) fn native_write(path: &str) {
    scheduler().notify_path(Path::new(path));
}

pub extern "C-unwind" fn graph_notify(l: *mut LuaState) -> std::ffi::c_int {
    let options = json_arg(l, 1);
    let outcome = (|| -> Result<Value, String> {
        let (root, db) = if let Some(path) = opt_str(&options, "path") {
            if !indexable(&path) {return Ok(json!({"ok":true,"queued":false,"reason":"not_indexable_source"}));}
            let (root, db) = locations(&options, CONFIG.get())?;
            let target = PathBuf::from(path).canonicalize().map_err(|e| format!("graph_edit_path_unavailable:{e}"))?;
            let relative = match target.strip_prefix(&root) {Ok(path) => path, Err(_) => return Ok(json!({"ok":true,"queued":false,"reason":"outside_indexed_root"}))};
            if excluded(relative) {return Ok(json!({"ok":true,"queued":false,"reason":"excluded_source_directory"}));}
            (root, db)
        } else {
            locations(&options, CONFIG.get())?
        };
        let scheduler = scheduler();
        let entry = scheduler.entry(&root, &db)?;
        scheduler.enqueue(&entry);
        Ok(json!({"ok":true,"queued":true}))
    })();
    reply(l, outcome.unwrap_or_else(|error| json!({"error": error})))
}

/// host.graph_source(opts_json) -> an exact, bounded page of one indexed definition.
pub extern "C-unwind" fn graph_source(l: *mut LuaState) -> std::ffi::c_int {
    reply(l, run(json_arg(l, 1), "source", &[]))
}

/// host.graph_explain(name, opts_json?) -> [ {node, outgoing, incoming} ] | {error}
pub extern "C-unwind" fn graph_explain(l: *mut LuaState) -> std::ffi::c_int {
    let name = arg_string(l, 1).unwrap_or_default();
    reply(l, run(json_arg(l, 2), "explain", &[("name", json!(name))]))
}

/// host.graph_path(from, to, opts_json?) -> [ {kind,name,path,line,via} ] | null | {error}
pub extern "C-unwind" fn graph_path(l: *mut LuaState) -> std::ffi::c_int {
    let from = arg_string(l, 1).unwrap_or_default();
    let to = arg_string(l, 2).unwrap_or_default();
    reply(l, run(json_arg(l, 3), "path", &[("from", json!(from)), ("to", json!(to))]))
}

/// host.graph_caps(opts_json?) -> [ {capability, uses} ] | {error}
pub extern "C-unwind" fn graph_caps(l: *mut LuaState) -> std::ffi::c_int {
    reply(l, run(json_arg(l, 1), "caps", &[]))
}

/// host.graph_stats(opts_json?) -> {files,nodes,edges,resolved,unresolved,byKind} | {error}
pub extern "C-unwind" fn graph_stats(l: *mut LuaState) -> std::ffi::c_int {
    reply(l, run(json_arg(l, 1), "stats", &[]))
}

/// host.graph_overview(opts_json?) -> bounded architecture sections with exact totals.
pub extern "C-unwind" fn graph_overview(l: *mut LuaState) -> std::ffi::c_int {
    reply(l, run(json_arg(l, 1), "overview", &[]))
}

/// host.graph_impact(request_json) -> changed definitions and bounded transitive impact evidence.
pub extern "C-unwind" fn graph_impact(l: *mut LuaState) -> std::ffi::c_int {
    reply(l, run(json_arg(l, 1), "impact", &[]))
}

/// host.graph_status(opts_json?) -> {root, db, ready, ...} | {error}
///
/// `ready` is the component's own verdict: the committed snapshot holds every indexed file's
/// current bytes, compared byte for byte. It is not "no refresh is pending" - every call admits
/// content before it answers, so a queued warm-up cannot make an answer stale, and a freshly
/// written file is not ready until a call has admitted it. `queued`/`active`/`dirty_hint` report
/// that warm-up separately. Status verifies only; it never indexes.
pub extern "C-unwind" fn graph_status(l: *mut LuaState) -> std::ffi::c_int {
    let options = json_arg(l, 1);
    let outcome = (|| -> Result<Value, String> {
        let (root, db) = locations(&options, CONFIG.get())?;
        let entry = scheduler().entry(&root, &db)?;
        let mut status = call(&entry, "status", json!({}), wait_deadline(&options));
        status["workspace_revision"] = status.get("workspace_revision").cloned().unwrap_or(json!(0));
        if status.get("error").is_some() {return Ok(status);}
        let failure = entry.state.lock().unwrap().failure.clone();
        overlay(&entry, &mut status);
        status["ready"] = json!(status["verified"] == json!(true));
        status["failure"] = json!(failure);
        Ok(status)
    })();
    reply(l, outcome.unwrap_or_else(|error| json!({ "error": error })))
}

/// host.graph_patch_audit(request_json) -> review leads or an explicit error.
/// Like navigation, audit captures a required revision and reads one pinned committed snapshot.
pub extern "C-unwind" fn graph_patch_audit(l: *mut LuaState) -> std::ffi::c_int {
    reply(l, run(json_arg(l, 1), "patch_audit", &[]))
}

/// host.graph_snapshot(request_json) -> {ok, source, copy, check, attempts, pages} | {error}
///
/// `{"db": "<store>", "copy": "<new file>", "wait_ms": 15000}`. One consistent copy of a graph
/// store, taken under the store's own lock so the WASI component cannot be writing it (see
/// `snapshot_store`). `wait_ms` bounds how long the caller waits for a running index: a pre-update
/// backup must report a busy store and step over it, never block the deploy. This is the read the
/// pre-update backup uses; nothing else may snapshot a graph store.
pub extern "C-unwind" fn graph_snapshot(l: *mut LuaState) -> std::ffi::c_int {
    let request = json_arg(l, 1);
    let outcome = (|| -> Result<Value, String> {
        let db = opt_str(&request, "db").ok_or_else(|| "graph_snapshot_failed: db_names_no_store".to_string())?;
        let copy = opt_str(&request, "copy").ok_or_else(|| "graph_snapshot_failed: copy_names_no_destination".to_string())?;
        let wait = request.get("wait_ms").and_then(Value::as_u64).unwrap_or(15_000).clamp(1, 600_000);
        let snapshot = snapshot_store(Path::new(&db), Path::new(&copy), Duration::from_millis(wait))?;
        Ok(json!({"ok":true,"source":snapshot.source.to_string_lossy(),"copy":snapshot.copy.to_string_lossy(),
            "check":snapshot.check,"attempts":snapshot.attempts,"locked":"graph_store"}))
    })();
    reply(l, outcome.unwrap_or_else(|error| json!({"error": error})))
}

/// `wa serve` keeps the configured root refreshed for the life of the node; `WA_GRAPH_WATCH=0`
/// disables the OS watcher (hints and per-call admission still keep answers exact).
pub fn watch_configured() {
    if let Some(config) = CONFIG.get() {
        if let Ok(root) = config.root.canonicalize() {
            let scheduler = scheduler();
            match scheduler.entry(&root, &db_dir(&config.db).join(DB_FILE)) {
                Ok(entry) => scheduler.enqueue(&entry),
                Err(error) => eprintln!("graph_watch_unavailable: {error}"),
            }
        }
    }
}
