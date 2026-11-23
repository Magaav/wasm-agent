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
/// How many per-root stores are kept beside the configured database, and how many bytes they may hold.
/// See `retain_stores`: one store per root is unbounded without these two numbers.
const STORE_LIMIT: usize = 8;
const STORE_BYTES: u64 = 2 * 1024 * 1024 * 1024;
/// The line journal every `graph_db_*` record is appended to, under the node's home. See `journal_line`.
const JOURNAL_FILE: &str = "graph.log";
/// The sidecar beside a store naming the root that built it. See `attribute_store`.
const SOURCE_ROOT: &str = "source_root";
const JOURNAL_BYTES: u64 = 1024 * 1024;
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
    let store = per_root_store(&config.db, &root);
    retain_stores(&store, STORE_LIMIT, STORE_BYTES);
    Ok((root, db_dir(&store).join(DB_FILE)))
}

/// THE STORE OF ONE ROOT, and of no other (graph-one-store-per-root, measured 23/11).
///
/// WHY. `wa serve` runs with the node's runtime worktree as its cwd, every mission worker with its own
/// mission directory, and a file write in either answered with a hint that indexed INTO THE SAME
/// `~/.wasm-agent/graph.db`. Two roots then took turns re-parsing ~600 files each: the flock serialises
/// them, so it was a fight rather than a tear - each switch re-admitted the other root's tree, the indexer
/// committed for hours, and the long write is what a kill, a pause or a deploy met (41 quarantines in a
/// day, docs/missions/reports/graph-index-tear-cause.md). The store's `graph_meta` recorded the GUEST
/// mount point (`root=/graph/root`, measured 23/11 on the live store), so no store could say whose it was.
///
/// The key is the SHA-256 of the REAL root as the kernel resolved it (canonicalised, case-folded where the
/// platform is), so it is stable across boots and between a root and its symlinked spelling, and two
/// different roots never meet. `roots` is the directory beside the configured database; the configured
/// path itself is left alone, so the legacy shared store is neither read nor written by this code.
fn per_root_store(configured: &Path, root: &Path) -> PathBuf {
    let identity = |path: &Path| {
        let text = path.to_string_lossy().into_owned();
        if cfg!(windows) {text.to_lowercase()} else {text}
    };
    let digest = ring::digest::digest(&ring::digest::SHA256, identity(root).as_bytes());
    let key: String = digest.as_ref().iter().map(|byte| format!("{byte:02x}")).collect();
    configured.with_extension("roots").join(format!("{key}.db"))
}

/// Keep at most `limit` per-root stores and `bytes` of them, deleting only what nothing can be reading
/// and nothing is evidence of.
///
/// THE BOUND EXISTS BECAUSE ONE STORE PER ROOT IS UNBOUNDED OTHERWISE: every mission worktree would keep
/// a ~180 MB index for ever. Eviction is therefore: never the store that was just asked for, never a store
/// whose kernel lock is held (a call or an index is inside it), never a store that still carries a
/// `graph.db.malformed-*` copy (that copy is the evidence of a quarantine, see QUARANTINE_KEEP), and never
/// anything but this directory's own `*.db.d`. The newest stores by store mtime win; every deletion
/// prints one `graph_db_store_evicted` line so it can be counted.
fn retain_stores(store: &Path, limit: usize, bytes: u64) {
    let Some(dir) = store.parent() else {return;};
    let mut stores: Vec<(PathBuf, std::time::SystemTime, u64)> = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {return;};
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.ends_with(".db.d") || !entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false) {continue;}
        let db = entry.path().join(DB_FILE);
        if !db.is_file() {continue;}
        let at = db.metadata().and_then(|meta| meta.modified()).unwrap_or(std::time::UNIX_EPOCH);
        stores.push((entry.path(), at, dir_bytes(&entry.path())));
    }
    if stores.len() <= limit && stores.iter().map(|(_, _, size)| *size).sum::<u64>() <= bytes {return;}
    stores.sort_by(|a, b| b.1.cmp(&a.1));
    let wanted = db_dir(store);
    let mut kept = 0usize;
    let mut used = 0u64;
    for (path, _, size) in stores {
        let fits = kept < limit && used.saturating_add(size) <= bytes;
        if fits || path == wanted {kept += 1; used = used.saturating_add(size); continue;}
        // Evidence stays: a quarantine copy beside this store is why the store is worth keeping.
        let evidenced = std::fs::read_dir(&path).map(|entries| entries.flatten()
            .any(|item| item.file_name().to_string_lossy().contains(".malformed-"))).unwrap_or(true);
        if evidenced {kept += 1; used = used.saturating_add(size); continue;}
        let Some(name) = path.file_name().map(|name| name.to_string_lossy().trim_end_matches(".d").to_string()) else {continue;};
        match lock_store(&path, DB_FILE, Some(Instant::now())) {
            Ok(None) => {kept += 1; used = used.saturating_add(size);} // in use: never evicted
            Ok(Some(handle)) => {
                let removed = std::fs::remove_dir_all(&path);
                let _ = handle.unlock();
                if removed.is_ok() {journal_line(&format!("graph_db_store_evicted store={name} bytes={size} stores_limit={limit} bytes_limit={bytes}"));}
            }
            Err(error) => journal_line(&format!("graph_db_store_evict_unavailable store={name} error={error}")),
        }
    }
}

/// Bytes one store directory holds, quarantine copies included.
fn dir_bytes(dir: &Path) -> u64 {
    std::fs::read_dir(dir).map(|entries| entries.flatten()
        .filter_map(|item| item.metadata().ok())
        .filter(|meta| meta.is_file())
        .map(|meta| meta.len()).sum()).unwrap_or(0)
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
/// How many quarantine copies of ONE store are kept.
///
/// WHY THREE AND NOT ONE. `quarantine_database` used to delete every earlier `graph.db.malformed-*` of
/// the same store before renaming the new one, so the copy that explains a quarantine was destroyed by
/// the next quarantine. Measured twice on this node: the evidence file `graph.db.malformed-
/// 20261122T144358Z` the mission brief named was gone 71 s after it was made, and so was
/// `graph.db.malformed-20261123T000626Z` (docs/missions/reports/graph-quarantine-at-install.md). Three
/// copies are one quarantine, the one before it and the one before that: enough to tell a single crash
/// from a loop, which is the question a quarantine asks.
const QUARANTINE_KEEP: usize = 3;
/// The ceiling on the copies kept for one store, in bytes. The store measured 22/11 is 183 MB, so three
/// copies (549 MB) fit; a bigger store is capped instead of filling the disk.
const QUARANTINE_KEEP_BYTES: u64 = 1024 * 1024 * 1024;
/// The error cap `PRAGMA integrity_check` is read with. SQLite stops at 100 complaints by default, and a
/// truncated list cannot answer "is EVERY complaint about an index?" - the allow-list in `index_only` is
/// only sound over the whole list. Measured on the store quarantined at 22/11 22:56: the default cap left
/// 100 lines, and lifting it left 150, every one of them an index entry.
const INTEGRITY_ERRORS: i64 = 100_000;
/// Index repairs tried inside one failing streak. A store the component keeps calling malformed while
/// `integrity_check` calls it healthy must not be re-repaired forever: past this the verdict is the one
/// that was always taken - quarantine and rebuild.
const REPAIR_LIMIT: u32 = 3;

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
    /// Why this root runs without an OS watch - too large to register, the watcher is off, or the
    /// platform refused. `None` on a watched root.
    watch_skipped: Option<String>,
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
    /// Index repairs tried in this streak, bounded by `REPAIR_LIMIT`.
    repairs: u32,
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

/// Directories a boot-time OS watch may cover.
///
/// WHY THIS EXISTS. `notify`'s recursive registration adds one inotify watch per directory, and it
/// does so SYNCHRONOUSLY on the thread that asks. `Scheduler::entry` therefore walked the whole
/// working directory before `wa serve` could bind its listener: measured on `openclaw` (21/11), a
/// cwd of 713k directories under `/local` held `/health` for 60-150 s, with the process's directory
/// fds deep inside the tree and its log stopped just after `[serve] core = native` and
/// `[client] client-tools bridge`. The same measurement on `avell` with a synthetic 220,201-directory
/// cwd: 220,201 inotify watches, and 257 ms with `WA_GRAPH_WATCH=0` against 1,494 ms without it.
///
/// The OS watch is a hint, not the source of truth - every graph call admits content itself - so a
/// root past this budget is left unwatched and says so, instead of paying that walk at boot.
const WATCH_DIR_BUDGET: usize = 20_000;
/// The count itself is a walk, so it is bounded twice: by `WATCH_DIR_BUDGET` directories and by this
/// deadline. A slow or network filesystem then costs a bounded scan, never an open-ended one. Both
/// bounds run on the watch thread, off the caller's.
const WATCH_SCAN_BUDGET: Duration = Duration::from_secs(5);

/// The directory budget, with the operator's override. `WA_GRAPH_WATCH_DIRS=0` registers no OS watch.
fn watch_dir_budget() -> usize {
    std::env::var("WA_GRAPH_WATCH_DIRS").ok().and_then(|text| text.trim().parse::<usize>().ok()).unwrap_or(WATCH_DIR_BUDGET)
}

/// How many directories a recursive watch of `root` would cover, or `None` when that is past
/// `budget` (or the scan outran `WATCH_SCAN_BUDGET`).
///
/// Every directory counts, excluded ones too: `watcher.watch(root, Recursive)` registers them all,
/// and only the *events* are filtered later (`ignored`). A count that skipped them would understate
/// exactly the cost this bounds. Symlinked directories are not followed - neither does notify - so a
/// symlink loop cannot spend the budget.
fn watchable_directories(root: &Path, budget: usize) -> Option<usize> {
    let started = Instant::now();
    let mut count = 1usize; // the root itself
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        if count > budget || started.elapsed() > WATCH_SCAN_BUDGET {return None;}
        let Ok(listing) = std::fs::read_dir(&dir) else {continue;};
        for item in listing.flatten() {
            if !item.file_type().map(|kind| kind.is_dir()).unwrap_or(false) {continue;}
            count += 1;
            if count > budget {return None;}
            stack.push(item.path());
        }
    }
    Some(count)
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
        // Bounded, and it has to happen here: `entry()` runs on whatever thread asked for the graph,
        // and for `wa serve` that is boot, before its listener exists. See `WATCH_DIR_BUDGET` - the
        // registration is bounded so this thread never pays an unbounded walk.
        self.register_watch(&entry, shared_root);
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
        state.repairs = 0;
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
        let dir = entry.db.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."));
        let file = entry.db.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_else(|| DB_FILE.to_string());
        let disk = if corrupt {Some(disk_answer(&dir, floor))} else {None};
        let low = matches!(disk, Some(DiskAnswer::Low(_)));
        let over_budget = corrupt && recent >= REBUILD_LIMIT;
        let quarantine = corrupt && !low && !over_budget && state.corruptions < QUARANTINE_LIMIT && entry.db.exists();
        // A repair is only attempted where a quarantine would be: the store is broken, there is room to
        // fix it, and the copy budget is not spent. It writes nothing when the answer is not index-only.
        let repair = quarantine && state.repairs < REPAIR_LIMIT;
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

        // 3. INDEX-ONLY DAMAGE IS REPAIRED, NOT REBUILT (measured 22/11, and it is not the first class):
        //    the store quarantined at 22:56 was reported by `PRAGMA integrity_check(100000)` with 150
        //    complaints, every one of them an index entry (149 `row N missing from index`, one
        //    `wrong # of entries in index`), no table or page fault at all, and `REINDEX` took it to
        //    `ok` in 0.746 s with all 115,947 nodes, 337,621 edges and 2,605 files still there. Today's
        //    answer was to copy 183 MB aside and re-parse the whole tree. The repair runs under the
        //    store's own lock, and quarantining is what still happens when the verdict is anything the
        //    allow-list does not name.
        if repair {
            let mut state = entry.state.lock().unwrap();
            state.repairs = state.repairs.saturating_add(1);
            drop(state);
            match repair_indexes(&dir, &file) {
                Repair::Repaired {complaints} => {
                    let line = format!("graph_db_repaired root={} file={file} complaints={complaints} next=reindex", entry.root.display());
                    let mut state = entry.state.lock().unwrap();
                    state.attempts = 0;
                    state.stopped = false;
                    state.retry_at = None;
                    state.reported = Some(line.clone());
                    drop(state);
                    eprintln!("{line}");
                    self.enqueue(&entry);
                    return;
                }
                // NOT DAMAGE AND NOT A REPAIR: the component answered `database disk image is malformed`
                // and `PRAGMA integrity_check` answers `ok` about the same file. Nothing was reindexed,
                // so the line may not say anything was - `graph_db_repaired complaints=0 next=reindex`
                // reported an event that never happened for exactly the pair of verdicts this node still
                // cannot explain (measured 23/11 03:44 local: `graph.db.malformed-20261123T064420Z`
                // reads `integrity_check: ok` natively, with all 133,959 nodes, and the component had
                // called it malformed). It is its own event and `next=retry` is what happens: the store
                // is kept as it is and the component's answer is retried, bounded by `REPAIR_LIMIT` a
                // streak before the verdict that was always taken - a quarantine and a rebuild.
                Repair::Healthy => {
                    let line = store_healthy_line(&entry.root, &file);
                    let mut state = entry.state.lock().unwrap();
                    state.attempts = 0;
                    state.stopped = false;
                    state.retry_at = None;
                    state.reported = Some(line.clone());
                    drop(state);
                    eprintln!("{line}");
                    self.enqueue(&entry);
                    return;
                }
                // Not index-only, or the rebuild of the indexes did not settle it: fall through to the
                // quarantine, whose line carries the verdict measured on the store itself.
                Repair::StillDamaged {verdict} => {journal_line(&format!("graph_db_repair_refused root={} file={file} verdict={}", entry.root.display(), one_line(&verdict, 160)));}
                Repair::Unavailable {reason} => {journal_line(&format!("graph_db_repair_unavailable root={} file={file} reason={}", entry.root.display(), one_line(&reason, 160)));}
            }
        }

        if quarantine {
            let seconds = now;
            match quarantine_database(entry, &utc_stamp(seconds)) {
                Ok(quarantined) if !quarantined.moved.is_empty() => {
                    let moved = quarantined.moved;
                    let integrity = quarantined.integrity;
                    let kept = quarantined.kept;
                    let mut state = entry.state.lock().unwrap();
                    state.corruptions = state.corruptions.saturating_add(1);
                    state.quarantined.extend(moved.iter().cloned());
                    // One copy is now on the disk and one rebuild is about to be attempted: count it
                    // against the 24 h budget before the attempt, so a rebuild that never returns still
                    // costs its copy. A success clears the budget in `recovered`.
                    state.rebuilds.push(now);
                    // The rebuild is the fix: a fresh database, attempted at once, is not a retry of
                    // the broken one. `rebuilds` bounds a disk that keeps producing garbage.
                    state.attempts = 0;
                    // The store about to exist is a NEW one: the repairs spent on the old generation are
                    // not its budget, and a rebuild that is later damaged by index entries is repaired
                    // like any other. The copies stay bounded by `corruptions` and `rebuilds`.
                    state.repairs = 0;
                    state.stopped = false;
                    state.retry_at = None;
                    state.reported = Some(error.clone());
                    drop(state);
                    let disk_note = match disk {Some(DiskAnswer::Enough(free)) => format!(" free_bytes={free} floor_bytes={floor}"), Some(DiskAnswer::Unmeasurable) => " free_bytes=unknown".to_string(), _ => String::new()};
                    // One line, with the reason AND the verdict the store itself gave: `reason` is what
                    // the component answered, `integrity` is what `PRAGMA integrity_check` said about the
                    // copy that was kept, and `kept` is how many of this store's copies survive.
                    eprintln!("{}", quarantine_line(&entry.root, &moved, &error, &integrity, kept, &disk_note));
                    self.enqueue(&entry);
                    return;
                }
                // NOTHING WAS MOVED, AND THE REASON IS THE STORE'S OWN: `integrity_check` calls it ok,
                // so there is no damage to keep and nothing may be renamed aside. The component's error
                // is what gets named, and automatic retry stops here: a healthy store may only be
                // re-asked so many times (REPAIR_LIMIT), and a loop that re-asks for ever is the CPU this
                // mission exists to stop. `graph index force=true` is the deliberate retry.
                Ok(quarantined) if quarantined.integrity == "ok" => {
                    let line = quarantine_refused_line(&entry.root, &quarantined.integrity, &error);
                    let mut state = entry.state.lock().unwrap();
                    state.stopped = true;
                    state.retry_at = None;
                    let report = report_needed(state.reported.as_deref(), &line);
                    if report {state.reported = Some(line.clone());}
                    drop(state);
                    if report {journal_line(&line);}
                    return;
                }
                Ok(_) => {}
                Err(error) => journal_line(&format!("graph_db_quarantine_failed root={} error={error}", entry.root.display())),
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
        state.repairs = 0;
        state.reported = None;
        let now = epoch_seconds();
        rebuilds_in_window(&mut state.rebuilds, now);
        if state.rebuilds.len() >= REBUILD_LIMIT {state.rebuilds.remove(0);}
        let queued = state.dirty && !state.queued && !state.active;
        if queued {state.queued = true;}
        drop(state);
        if queued {self.ready.lock().unwrap().push_back((None, entry.clone()));self.wake.notify_one();}
    }

    /// Register the OS watcher for this entry, or name why it runs unwatched.
    ///
    /// SYNCHRONOUS BY DESIGN, and bounded. Registering asynchronously made the answer a race: the parity
    /// test (scripts/test-graph-watch.lua) reads watch_registered straight after a query and requires a
    /// real OS registration, and a status read must be able to say what is true now. What must never
    /// happen is walking an UNBOUNDED tree here - so the directory count is taken first, bounded by
    /// WATCH_DIR_BUDGET directories and WATCH_SCAN_BUDGET, and a root past it is left unwatched with a
    /// named reason instead of being walked whole.
    ///
    /// shared_root is "another entry already watches this root": it is covered, and the tree is not
    /// walked for it a second time.
    fn register_watch(&self, entry: &Entry, shared_root: bool) {
        let budget = watch_dir_budget();
        let within = shared_root || (budget != 0 && watchable_directories(&entry.root, budget).is_some());
        // The watcher lock is taken and released before the state lock: the eviction path in entry takes
        // the entry list and then the watcher, and two lock orders on the same pair is how a scheduler
        // deadlocks.
        let registered = if !within {
            Err(if budget == 0 {format!("watch_budget_zero")} else {format!("root_too_large_more_than_{budget}_directories")})
        } else {
            match self.watcher.lock().unwrap().as_mut() {
                Some(watcher) => {use notify::Watcher as _; watcher.watch(&entry.root, notify::RecursiveMode::Recursive).map_err(|error| error.to_string())}
                None => Err("no_os_watcher".to_string()),
            }
        };
        let mut state = entry.state.lock().unwrap();
        match registered {
            Ok(()) => {state.watched = true; state.watch_error = None; state.watch_skipped = None;}
            Err(reason) => {
                state.watched = false;
                // A SKIP is a decision (a budget, or no watcher asked for) and a FAILURE is the platform
                // refusing. They are named apart, and neither may read as "watched".
                if !within || reason == "no_os_watcher" {
                    state.watch_skipped = Some(reason.clone());
                    state.watch_error = None;
                    eprintln!("graph_watch_skipped root={} reason={reason}; edit hints and per-call content admission keep answers exact", entry.root.display());
                } else {
                    state.watch_skipped = None;
                    state.watch_error = Some(reason.clone());
                    eprintln!("graph_watch_register_failed root={} error={reason}; content admission remains authoritative", entry.root.display());
                }
            }
        }
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
        if removed.is_ok() {journal_line(&format!("graph_db_stale_lock_removed file={file}"));}
    }
    // A COMPONENT RUN KILLED MID-COMMIT LEAVES A HOT JOURNAL, AND THAT IS NOT DAMAGE (measured
    // 22/11). In `delete` journal mode - which is what the guest's SQLite runs in, whatever
    // `wa_sqlite::tune` asks for - a commit is a page overwrite before a journal delete, so a kill
    // between the two leaves a database half the new revision and half the old one. Only the journal
    // can put it back: a read-only opener cannot roll it back, and the component's admission
    // pre-flight IS read-only, so the guest answered `database disk image is malformed` for a store
    // one rollback away from perfect. The scheduler answers that verdict with a quarantine - the
    // whole index moved aside and rebuilt (three times in 16 minutes across the install of 8862b600,
    // `graph_db_quarantined ... reason=graph_index_failed:_database_disk_image_is_malformed`, and on
    // the copy kept from 23/11T000626Z a rollback restored it to `integrity_check: ok` with every one
    // of its 101,422 nodes still there). The lock above proves no component call is running - the
    // guest exists only inside one - so the rollback is ours to perform and nobody's to race: one
    // read-write open, one schema read, and the store is the last committed revision again, with no
    // copy taken and nothing rebuilt.
    if let Some(bytes) = hot_journal(&dir, &file) {
        match roll_back_hot_journal(&dir, &file) {
            Ok(outcome) => journal_line(&format!("graph_db_journal_resolved root={} file={file} journal_bytes={bytes} outcome={}",
                entry.root.display(), outcome.name())),
            Err(error) => journal_line(&format!("graph_db_journal_unresolved root={} file={file} journal_bytes={bytes} error={}",
                entry.root.display(), error.replace(char::is_whitespace, "_"))),
        }
    }
    // WHOSE STORE IS THIS (graph-one-store-per-root item 2)? Two roots sharing one file is what tore
    // this index for a day. The path is now keyed by the root, and the store also says whose it is; a
    // store that says another root, or cannot say, is neither read nor written, and the refusal is
    // named with the fix. Under the lock, because this is where a store first becomes this root's.
    if let Err(refusal) = attribute_store(&dir, &file, &entry.root.to_string_lossy()) {
        let _ = lock.unlock();
        drop(calls);
        return json!({"error": refusal, "next": "This store is not this root's, so no answer was taken from it. Call the graph without an explicit db so this root gets its own store, or pin a store of your own with db; a derived index you do not want may be removed."});
    }
    // Tests drive the scheduling policy with a failing component; the component itself needs the built
    // wasm binary, which a unit test does not have. The hook sits HERE, after the lock and the journal,
    // because that is the order the real call has: a test that asks what the component is handed has to
    // be handed it at the same point, or it measures an order the node does not use.
    #[cfg(test)]
    if let Some(replacement) = TEST_CALL.lock().unwrap_or_else(|error| error.into_inner()).as_ref() {
        return replacement(&entry.root, tool);
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

/// The store's rollback journal, in bytes, when a killed writer left one behind.
///
/// A zero-length journal is SQLite's own "nothing to roll back" and is left to SQLite; a store with
/// no journal beside it has nothing to recover, so every verdict the scheduler makes today stands -
/// this is the whole of the condition, a hot journal and only that.
fn hot_journal(dir: &Path, file: &str) -> Option<u64> {
    let meta = dir.join(format!("{file}-journal")).metadata().ok()?;
    (meta.is_file() && meta.len() > 0).then_some(meta.len())
}

/// What happened to a journal that was beside the store.
#[derive(Debug, PartialEq, Eq)]
enum Pending {
    /// SQLite spent the journal and the store read: it rolled the pre-images back (or discarded a file
    /// it does not recognise as a journal at all - a killed writer writes SQLite's own header, so the
    /// first is the case that matters). The store is readable and nothing is pending.
    RolledBack,
    /// SQLite read the store and left the journal where it was: not a journal to roll back - a writer
    /// killed between its last journaled page and the commit's record count leaves exactly this. The
    /// store was readable, so there is nothing to recover and nothing to quarantine.
    NotPending,
}

impl Pending {
    fn name(&self) -> &'static str {
        match self {
            Pending::RolledBack => "rolled_back",
            Pending::NotPending => "not_pending",
        }
    }
}

/// Roll a hot journal back, under the store's lock: a read-write open that cannot create the
/// database, and one read of the schema - which is the step SQLite performs the rollback in. Nothing
/// is copied and nothing is rebuilt, and the caller's store is the last committed revision when this
/// returns Ok.
///
/// The distinction between a rollback and an inert journal is reported, not guessed: SQLite spends the
/// journal (deletes or truncates it) exactly when it rolled it back.
fn roll_back_hot_journal(dir: &Path, file: &str) -> Result<Pending, String> {
    let path = dir.join(file);
    let connection = rusqlite::Connection::open_with_flags(&path, rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE)
        .map_err(|error| error.to_string())?;
    // The node's one contention policy without the journal-mode half: a rollback that meets another
    // writer waits its turn instead of answering `database is locked`.
    let _ = wa_sqlite::tune_wait(&connection);
    connection.query_row("SELECT COUNT(*) FROM sqlite_master", [], |row| row.get::<_, i64>(0))
        .map_err(|error| error.to_string())?;
    drop(connection);
    // The rollback is only done when the journal is spent: a journal still on the disk means the
    // store is still rollback-pending, and the line must not claim otherwise.
    match hot_journal(dir, file) {
        None => Ok(Pending::RolledBack),
        Some(_) => Ok(Pending::NotPending),
    }
}

/// Append one `graph_db_*` line to the node's own log, and print it too.
///
/// WHY A FILE AND NOT ONLY STDERR. A `wa serve` under systemd has its stderr in the user journal, but a
/// mission worker's stderr goes to whoever started it, so the lines that matter most - a quarantine, a
/// repair, a refused rebuild - were countable only for one process per node. Measured 23/11: 23
/// `graph_db_` lines reached `journalctl --user` in a day while the store was quarantined 41 times.
/// One append-only file under the node's home makes the count the same for every process.
///
/// Bounded by rotation (`JOURNAL_BYTES`, one older copy), and a log that cannot be written never breaks
/// the caller: the line was already printed.
fn journal_line(line: &str) {
    eprintln!("{line}");
    let home = wa_host_support::paths::resolve_home();
    append_journal(&Path::new(&home).join(".wasm-agent").join(JOURNAL_FILE), line);
}

/// Append one line to `path`, rotating it to `<name>.1` once it holds `JOURNAL_BYTES`.
///
/// Split from `journal_line` so a test can hold the file's own rules (append, one rotation, a bounded
/// size) against a fixture path, without moving the process's HOME where every other test would see it.
fn append_journal(path: &Path, line: &str) {
    if let Some(dir) = path.parent() {if std::fs::create_dir_all(dir).is_err() {return;}}
    let size = path.metadata().map(|meta| meta.len()).unwrap_or(0);
    if size >= JOURNAL_BYTES {
        let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_else(|| JOURNAL_FILE.to_string());
        let _ = std::fs::rename(path, path.with_file_name(format!("{name}.1")));
    }
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        use std::io::Write as _;
        let _ = writeln!(file, "{line}");
    }
}

/// The root a store was built for, from the sidecar the kernel keeps beside it.
///
/// `graph_meta.root` cannot answer it: the component walked `/graph/root`, so that is what it recorded
/// (measured 23/11 on the live store: `root|/graph/root`), and a store therefore could not tell whose it
/// was - which is how a healthy 133,959-node store came to be quarantined from another root's tree. The
/// component now also records `source_root` INSIDE the store (so a copied store still says whose it is),
/// and the kernel keeps the same fact beside it: one small file, read on every call, no SQLite open.
fn recorded_root(dir: &Path) -> Option<String> {
    std::fs::read_to_string(dir.join(SOURCE_ROOT)).ok().map(|text| text.trim().to_string()).filter(|text| !text.is_empty())
}

/// May this root use the store in `dir`? Claim it when this call is the one creating it, and refuse by
/// name when it belongs to another root - or when an existing store cannot say whose it is.
///
/// UNKNOWN IS NOT YES. A store that predates the sidecar (or one whose sidecar was removed) could be
/// another tree's index, and answering from it is the wrong-caller noise this mission exists to stop. It
/// is never written and never read: the refusal names the store and the fix, which is to remove a
/// derived index or to pin one deliberately with `db`.
///
/// So the three answers are: `Ok(true)` - there was no store, this root has now claimed the name;
/// `Ok(false)` - the store says it is this root's; `Err(named)` - it says another root's, or it cannot
/// say. The claim is written only when no store file exists, never over one.
fn attribute_store(dir: &Path, file: &str, asked: &str) -> Result<bool, String> {
    match recorded_root(dir) {
        Some(recorded) if recorded != asked => Err(format!(
            "graph_store_root_mismatch: recorded={recorded} asked={asked} store={}", dir.display())),
        Some(_) => Ok(false),
        None if dir.join(file).exists() => Err(format!(
            "graph_store_unattributed: store={} records no source_root, so it may be another root's index", dir.display())),
        None => {
            std::fs::write(dir.join(SOURCE_ROOT), format!("{asked}
"))
                .map_err(|error| format!("graph_store_unattributable: {error}"))?;
            Ok(true)
        }
    }
}

/// A text safe for a one-line log record: no whitespace, and bounded.
fn one_line(text: &str, limit: usize) -> String {
    let flat: String = text.chars().map(|c| if c.is_whitespace() {'_'} else {c}).collect();
    if flat.chars().count() <= limit {return flat;}
    let mut cut: String = flat.chars().take(limit).collect();
    cut.push('~');
    cut
}

/// The store named so that SQLite will not write to it: `immutable=1` means no journal, no `-shm` and no
/// repair, which matters because this is asked BESIDE a store that is still the live one.
///
/// WHY NOT PLAIN READ-ONLY. A read-only connection to a store with a `-wal` beside it CREATED a `-shm`
/// file when this was measured: `a_malformed_database_is_moved_aside_with_a_timestamp_and_never_deleted`
/// moved three files where the store had two. A diagnosis must not leave anything behind.
fn immutable_uri(store: &Path) -> String {
    let text = store.to_string_lossy().replace('%', "%25").replace('?', "%3f").replace('#', "%23");
    format!("file:{text}?immutable=1")
}

/// Every complaint `PRAGMA integrity_check` makes about `store`, read-only: `["ok"]` for a store that
/// passes, otherwise the complaints in SQLite's own order, up to `INTEGRITY_ERRORS`.
///
/// READ-ONLY, SO IT IS DIAGNOSIS AND NEVER REPAIR. A store with a hot journal cannot be rolled back by a
/// read-only opener, so a rollback-pending store reads here as the damage it is not - which is why `call`
/// resolves the journal first, and why this answer chooses the repair below only together with a
/// `REINDEX` that has to pass the same check afterwards.
fn integrity_complaints(store: &Path) -> Result<Vec<String>, String> {
    let connection = rusqlite::Connection::open_with_flags(immutable_uri(store),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI)
        .map_err(|error| error.to_string())?;
    let mut statement = connection.prepare(&format!("PRAGMA integrity_check({INTEGRITY_ERRORS})"))
        .map_err(|error| error.to_string())?;
    let mut rows = statement.query([]).map_err(|error| error.to_string())?;
    let mut complaints = Vec::new();
    while let Some(row) = rows.next().map_err(|error| error.to_string())? {
        let text: String = row.get(0).map_err(|error| error.to_string())?;
        if text == "ok" {return Ok(vec![text]);}
        complaints.push(text);
    }
    if complaints.is_empty() {return Err("integrity_check answered nothing".to_string());}
    Ok(complaints)
}

/// Is this complaint one that rebuilding the indexes repairs: the index disagrees with its table?
///
/// AN ALLOW-LIST OF THE TWO SHAPES MEASURED, not a block-list. Measured on the store quarantined on
/// 22/11 at 22:56 (`graph.db.malformed-20261123T015417Z`, 182,599,680 B, copied out and read only): 150
/// complaints, 149 `row <n> missing from index <name>` and one `wrong # of entries in index <name>`, no
/// table, page or freelist fault at all. Everything else - `*** in database main ***`, `Freelist: ...`,
/// `Tree N page M: ...`, `database disk image is malformed`, `file is not a database`, an empty index
/// name - is NOT repaired: the repair path must refuse what it cannot guarantee, and a table whose pages
/// are torn needs the rollback journal or a rebuild, never a REINDEX.
fn index_only(complaint: &str) -> bool {
    if let Some(rest) = complaint.strip_prefix("row ") {
        let Some((number, tail)) = rest.split_once(' ') else {return false;};
        let named = tail.strip_prefix("missing from index ").map(|name| !name.trim().is_empty()).unwrap_or(false);
        return named && !number.is_empty() && number.bytes().all(|byte| byte.is_ascii_digit());
    }
    complaint.strip_prefix("wrong # of entries in index ").map(|name| !name.trim().is_empty()).unwrap_or(false)
}

/// What an attempt to repair a store by rebuilding its indexes did.
#[derive(Debug, PartialEq, Eq)]
enum Repair {
    /// Every complaint was an index entry, and after `REINDEX` the store passes `integrity_check`.
    Repaired {complaints: usize},
    /// The store passes `integrity_check` already: the component's verdict is not the store's, so the
    /// index is not thrown away - nothing is copied, nothing is reindexed and nothing is rebuilt. The
    /// verdict that gets retried is the component's own answer, and it carries no complaint count
    /// because no complaint was found (see `store_healthy_line`).
    Healthy,
    /// Not index-only, or the rebuild did not settle it. The verdict is why, and it is what the
    /// quarantine line must carry.
    StillDamaged {verdict: String},
    /// The attempt could not be made at all (no lock, no store, an unreadable file).
    Unavailable {reason: String},
}

/// Repair a store whose only complaints are index entries, by rebuilding the indexes (`REINDEX`).
///
/// The store's cross-process lock is held for the whole attempt - the read, the write and the re-check -
/// so no component call and no snapshot can meet a half-rebuilt index. Nothing is deleted and nothing is
/// copied: `REINDEX` derives every index from the table it indexes, which is the definition of an index.
fn repair_indexes(dir: &Path, file: &str) -> Repair {
    let lock = match lock_store(dir, file, None) {
        Ok(Some(handle)) => handle,
        Ok(None) => return Repair::Unavailable {reason: "the store's lock was not released before the repair".to_string()},
        Err(error) => return Repair::Unavailable {reason: error.to_string()},
    };
    let answer = repair_under_lock(dir, file);
    let _ = lock.unlock();
    answer
}

fn repair_under_lock(dir: &Path, file: &str) -> Repair {
    let db = dir.join(file);
    if !db.exists() {return Repair::Unavailable {reason: format!("no store at {}", db.display())};}
    let complaints = match integrity_complaints(&db) {
        Ok(complaints) => complaints,
        // SQLite refused to run the check at all (a torn page it cannot walk, a file it cannot read).
        // That IS the verdict about the store, and it is never an index-only one, so the repair is not
        // attempted and the quarantine is - exactly what happened before this path existed.
        Err(verdict) => return Repair::StillDamaged {verdict},
    };
    if complaints.len() == 1 && complaints[0] == "ok" {return Repair::Healthy;}
    // UNKNOWN IS NOT YES. A list SQLite truncated at `INTEGRITY_ERRORS` cannot say that every complaint is
    // an index entry, so it is neither repaired nor reported as repaired.
    if complaints.len() as i64 >= INTEGRITY_ERRORS {
        return Repair::StillDamaged {verdict: format!("integrity_check_truncated_at_{INTEGRITY_ERRORS}")};
    }
    if let Some(other) = complaints.iter().find(|complaint| !index_only(complaint)) {
        return Repair::StillDamaged {verdict: other.clone()};
    }
    // Read-write and CANNOT CREATE: a repair of a store that vanished is not a repair of a new store.
    let connection = match rusqlite::Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE) {
        Ok(connection) => connection,
        Err(error) => return Repair::StillDamaged {verdict: format!("reindex_unavailable: {error}")},
    };
    let _ = wa_sqlite::tune_wait(&connection);
    if let Err(error) = connection.execute_batch("REINDEX") {
        return Repair::StillDamaged {verdict: format!("reindex_failed: {error}")};
    }
    drop(connection);
    let complaints = complaints.len();
    match integrity_complaints(&db) {
        Ok(after) if after.len() == 1 && after[0] == "ok" => Repair::Repaired {complaints},
        Ok(after) => Repair::StillDamaged {verdict: after.into_iter().next().unwrap_or_else(|| "unknown".to_string())},
        Err(reason) => Repair::StillDamaged {verdict: format!("integrity_after_reindex_unmeasurable: {reason}")},
    }
}

/// What a quarantine left on the disk.
#[derive(Debug)]
struct Quarantined {
    /// The files moved aside, this quarantine's own copies.
    moved: Vec<PathBuf>,
    /// The verdict `PRAGMA integrity_check` gave the store while it was still the store.
    integrity: String,
    /// How many of this store's copies survive the retention rule, this one included.
    kept: usize,
}

/// Move a malformed database - and SQLite's own siblings - aside under a timestamped name. It is
/// derived state but still state: renamed, never deleted while it is evidence (see `retain_quarantine`
/// for the bound). The rename runs under the same cross-process lock every graph call takes, so another
/// node process sharing this database cannot keep writing into a file that is being moved.
fn quarantine_database(entry: &Arc<Entry>, stamp: &str) -> std::io::Result<Quarantined> {
    let dir = entry.db.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."));
    let file = entry.db.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_else(|| DB_FILE.to_string());
    let lock = match lock_store(&dir, &file, None)? {
        Some(handle) => handle,
        None => return Err(std::io::Error::other("the store's lock was not released")),
    };
    // The verdict is taken BEFORE the rename, because afterwards the store is a copy with a timestamp in
    // its name and the question belongs to the store that was there.
    let integrity = match integrity_complaints(&dir.join(&file)) {
        Ok(complaints) => complaints.into_iter().next().unwrap_or_else(|| "unknown".to_string()),
        // SQLite's own refusal is the verdict: it names the damage even when it cannot list it.
        Err(verdict) => verdict,
    };
    // A STORE THAT integrity_check CALLS OK IS NEVER QUARANTINED (graph-one-store-per-root item 3).
    // Measured 23/11 06:44Z: a healthy store of 133,959 nodes was renamed aside with integrity=ok,
    // because the component's "database disk image is malformed" outlived REPAIR_LIMIT retries. The
    // copy is taken for one reason - to keep the damage - and there is no damage to keep, so nothing
    // is copied: the empty `moved` is what tells the caller to report the component's own error.
    if integrity == "ok" {
        let _ = lock.unlock();
        return Ok(Quarantined {moved: Vec::new(), integrity, kept: 0});
    }
    let mut moved = Vec::new();
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let source = dir.join(format!("{file}{suffix}"));
        if !source.exists() {continue;}
        let target = dir.join(format!("{file}.malformed-{stamp}{suffix}"));
        if std::fs::rename(&source, &target).is_ok() {moved.push(target);}
    }
    let kept = retain_quarantine(&dir, &file, QUARANTINE_KEEP, QUARANTINE_KEEP_BYTES);
    let _ = lock.unlock();
    Ok(Quarantined {moved, integrity, kept})
}

/// Keep the newest `keep` copies of ONE store, their total at most `budget` bytes, deleting only this
/// store's own `<db>.malformed-*` names and only the oldest groups. Returns how many groups survive.
///
/// GROUPS, NOT FILES. A quarantine moves the database and its `-journal`/`-wal`/`-shm` siblings under one
/// stamp, and one stamp is one evidence set: deleting the database of a group and keeping its journal
/// would leave a copy that cannot be read at all. The stamp sorts as text (`YYYYMMDDTHHMMSSZ`), so the
/// newest group is the greatest name and no mtime is trusted - a copy is not re-dated when it is read.
///
/// WHY A BOUND AT ALL. Keeping everything fills the disk: 77 copies (~4 GB) in `graph.db.d/` on node
/// `work` between 10/11 and 13/11, 30 more on `openclaw`. Keeping ONE destroys the evidence for the
/// quarantine before it, measured twice on 22/11. Three is the count that holds a streak; 1 GB is more
/// than three copies of the 183 MB store this was measured on, and less than a disk.
fn retain_quarantine(dir: &Path, file: &str, keep: usize, budget: u64) -> usize {
    let prefix = format!("{file}.malformed-");
    let mut groups: std::collections::BTreeMap<String, Vec<(PathBuf, u64)>> = std::collections::BTreeMap::new();
    let Ok(entries) = std::fs::read_dir(dir) else {return 0;};
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(rest) = name.strip_prefix(&prefix) else {continue;};
        let (stamp, suffix) = match rest.split_once('-') {Some((stamp, suffix)) => (stamp, format!("-{suffix}")), None => (rest, String::new())};
        if stamp.is_empty() || !matches!(suffix.as_str(), "" | "-wal" | "-shm" | "-journal") {continue;}
        if !entry.file_type().map(|kind| kind.is_file()).unwrap_or(false) {continue;}
        let size = entry.metadata().map(|meta| meta.len()).unwrap_or(0);
        groups.entry(stamp.to_string()).or_default().push((entry.path(), size));
    }
    let mut kept = 0usize;
    let mut bytes = 0u64;
    for (index, files) in groups.values().rev().enumerate() {
        let size: u64 = files.iter().map(|(_, size)| *size).sum();
        // The newest group is always kept, even alone: a store bigger than the budget must still leave
        // the copy that explains the quarantine it caused.
        let fits = index == 0 || (kept < keep && bytes.saturating_add(size) <= budget);
        if !fits {
            for (path, _) in files {let _ = std::fs::remove_file(path);}
            continue;
        }
        kept += 1;
        bytes = bytes.saturating_add(size);
    }
    kept
}

/// The one line a quarantine prints. A function because it is what an operator reads in the journal, and
/// because a test can hold its fields to account without starting a node.
/// The one verdict that is neither damage nor a repair: the component called the store malformed and
/// `PRAGMA integrity_check` calls it healthy.
///
/// It has its own name because the repair line was false for it - nothing was reindexed - and because this
/// pair of verdicts about one file is the disagreement this node has not explained yet: on the copy
/// `~/.wasm-agent/graph.db.d/graph.db.malformed-20261123T064420Z` (quarantined 23/11 03:44 local, read
/// only, 182,968,320 B) `PRAGMA integrity_check(200)` answers `ok` with 133,959 nodes, 380,380 edges and
/// 2,694 files, while the component had answered `database disk image is malformed` for the same store.
/// `next=retry` is what the scheduler does with it: the store is kept as it is and the component's answer
/// is asked again.
fn store_healthy_line(root: &Path, file: &str) -> String {
    format!("graph_db_store_healthy root={} file={file} next=retry", root.display())
}

fn quarantine_refused_line(root: &Path, integrity: &str, component_error: &str) -> String {
    format!("graph_db_quarantine_refused root={} integrity={integrity} component_error={} kept=0 next=stop use=graph_index_force",
        root.display(), one_line(component_error, 160))
}

fn quarantine_line(root: &Path, moved: &[PathBuf], reason: &str, integrity: &str, kept: usize, disk_note: &str) -> String {
    let names: Vec<String> = moved.iter().map(|path| path.display().to_string()).collect();
    format!("graph_db_quarantined root={} moved={} reason={} integrity={} kept={kept} next=rebuild{disk_note}",
        root.display(), names.join(","), one_line(reason, 120), one_line(integrity, 180))
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
    let complaints = integrity_complaints(store).map_err(|error| snapshot_failure(&error))?;
    Ok(complaints.into_iter().next().unwrap_or_else(|| "unknown".to_string()))
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
    value["watch_skipped"] = json!(state.watch_skipped);
    value["failure"] = json!(state.failure);
    value["index_attempts"] = json!(state.attempts);
    value["retry_exhausted"] = json!(state.stopped);
    value["retry_in_ms"] = json!(state.retry_at.map(|at| at.saturating_duration_since(Instant::now()).as_millis() as u64));
    value["quarantined"] = json!(state.quarantined);
}

fn wait_deadline(options: &Value) -> Instant {
    Instant::now() + Duration::from_millis(options.get("wait_ms").and_then(Value::as_u64).unwrap_or(60_000).clamp(1, 120_000))
}

/// IS THE GRAPH SWITCHED ON AT ALL? Off by default on every node from G (docs/GRAPH.md, 23/11). The
/// switch is the `graph` row of the one feature resolver - `WA_GRAPH_COMPONENT=1`, or `"graph": true` in
/// the `features` section of `policy.json` - so the tool's catalogue line, this store and the answer a
/// caller gets cannot disagree about whether this node has a graph.
fn enabled() -> bool {
    // The same seam the component call has (`TEST_CALL`): a unit test drives the gate with an answer it
    // sets rather than with the process environment, which is shared by every test in the binary. It does
    // not exist in a release build.
    #[cfg(test)]
    if let Some(value) = *TEST_SWITCH.lock().unwrap_or_else(|error| error.into_inner()) {
        return value;
    }
    wa_features::enabled("graph")
}

#[cfg(test)]
pub(crate) static TEST_SWITCH: std::sync::Mutex<Option<bool>> = std::sync::Mutex::new(None);

/// The one answer a dormant graph gives: named, with the switch that turns it on, and `effect: none`. A
/// caller that reached a graph capability by another road than the tool (a pinned older Lua tree, a
/// plugin, a test) is told why it got nothing, instead of being handed an index nobody asked to build.
fn dormant() -> Option<Value> {
    if enabled() {return None;}
    Some(json!({
        "error": "graph_dormant",
        "effect": "none",
        "next": "The code graph is OFF by default on this node (docs/GRAPH.md). Read with read/grep, or switch it on: WA_GRAPH_COMPONENT=1, or \"graph\": true in the features section of policy.json.",
    }))
}

/// One read capability: resolve locations, register the root, run the tool.
fn run(options: Value, tool: &str, extra: &[(&str, Value)]) -> Value {
    let outcome = (|| -> Result<Value, String> {
        if let Some(refusal) = dormant() {return Ok(refusal);}
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

pub extern "C-unwind" fn graph_notify(l: *mut LuaState) -> std::ffi::c_int {
    reply(l, notify(json_arg(l, 1), CONFIG.get()))
}

/// A write hint asks NOTHING TO BE INDEXED (graph-one-store-per-root item 0).
///
/// WHY THIS IS NOT AN ENQUEUE ANY MORE. `write`, `edit` and every native write called this, and this
/// created a scheduler entry, registered a RECURSIVE OS watch on the root and queued an index - so the
/// indexer ran for every process that wrote one file, without anyone ever calling the `graph` tool.
/// Measured in this node's ledger over 18/11 09:28Z - 23/11 08:02Z (368,218 events, ~104,000 tool calls
/// from every session and worker): ZERO `graph` calls and zero patch-audit events, and 41 quarantines in
/// a day with 688 MB in `graph.db.d`. What starts the indexer is therefore the WRITE, not the reader.
///
/// Nothing is lost by dropping it: every graph call admits content itself (capture → compare → index the
/// changes as a new revision), so an answer is never older than the bytes on disk at the start of the
/// call. A hint only ever made that admission cheaper, and it cost a full index of the tree instead.
/// The answer keeps its shape and names why nothing was queued, so a caller is told, never left to guess.
fn notify(options: Value, config: Option<&Config>) -> Value {
    let outcome = (|| -> Result<Value, String> {
        if let Some(refusal) = dormant() {return Ok(refusal);}
        let root = if let Some(path) = opt_str(&options, "path") {
            if !indexable(&path) {return Ok(json!({"ok":true,"queued":false,"reason":"not_indexable_source"}));}
            let (root, _) = locations(&options, config)?;
            let target = PathBuf::from(path).canonicalize().map_err(|e| format!("graph_edit_path_unavailable:{e}"))?;
            let relative = match target.strip_prefix(&root) {Ok(path) => path, Err(_) => return Ok(json!({"ok":true,"queued":false,"reason":"outside_indexed_root"}))};
            if excluded(relative) {return Ok(json!({"ok":true,"queued":false,"reason":"excluded_source_directory"}));}
            root
        } else {
            locations(&options, config)?.0
        };
        Ok(json!({"ok":true,"queued":false,"reason":"on_demand","root":root.to_string_lossy(),
            "next":"nothing was indexed; a graph call admits content itself"}))
    })();
    outcome.unwrap_or_else(|error| json!({"error": error}))
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
        if let Some(refusal) = dormant() {return Ok(refusal);}
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
        if let Some(refusal) = dormant() {return Ok(refusal);}
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
    // A DORMANT NODE WATCHES NOTHING (docs/GRAPH.md): no scheduler entry, no recursive OS watch, no
    // index, no store. This is the line that keeps `wa serve` from paying for a feature nobody asked for.
    if !enabled() {return;}
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
