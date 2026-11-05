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

use crate::lua::{arg_string, lua_pushlstring, LuaState};
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

struct Config {
    root: PathBuf,
    db: PathBuf,
}

static CONFIG: OnceLock<Config> = OnceLock::new();

#[cfg(test)]
#[path = "graph_tests.rs"]
mod tests;

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

#[derive(Default)]
struct State {
    queued: bool,
    active: bool,
    dirty: bool,
    watched: bool,
    watch_error: Option<String>,
    failure: Option<String>,
}

struct Entry {
    root: PathBuf,
    db: PathBuf,
    calls: Mutex<()>,
    state: Mutex<State>,
}

struct Scheduler {
    entries: Mutex<BTreeMap<(PathBuf, PathBuf), Arc<Entry>>>,
    ready: Mutex<VecDeque<Arc<Entry>>>,
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
        if state.queued || state.active {return;}
        state.queued = true;
        drop(state);
        self.ready.lock().unwrap().push_back(entry.clone());
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
            let entry = {
                let mut ready = self.ready.lock().unwrap();
                while ready.is_empty() {ready = self.wake.wait(ready).unwrap();}
                ready.pop_front().unwrap()
            };
            // A bounded quiet window coalesces bursts without waiting forever for a busy writer.
            std::thread::sleep(Duration::from_millis(75));
            {let mut state = entry.state.lock().unwrap(); state.queued = false; state.active = true; state.dirty = false;}
            let outcome = call(&entry, "index", json!({}), Instant::now() + Duration::from_secs(120));
            let error = outcome.get("error").and_then(Value::as_str).map(str::to_string);
            if let Some(error) = &error {eprintln!("graph_index_failed root={} error={error}", entry.root.display());}
            let mut state = entry.state.lock().unwrap();
            state.active = false;
            state.failure = error;
            let again = state.dirty;
            drop(state);
            if again {self.enqueue(&entry);}
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
    let lock = match std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(dir.join(format!(".{file}.lock"))) {
        Ok(file) => file,
        Err(error) => return json!({"error": format!("graph_db_unavailable: {error}")}),
    };
    if let Err(error) = lock.lock() {return json!({"error": format!("graph_db_lock_failed: {error}")});}
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
    let answer = crate::components::mcp(&request);
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
}

fn wait_deadline(options: &Value) -> Instant {
    Instant::now() + Duration::from_millis(options.get("wait_ms").and_then(Value::as_u64).unwrap_or(60_000).clamp(1, 120_000))
}

/// One read capability: resolve locations, register the root, run the tool.
fn run(options: Value, tool: &str, extra: &[(&str, Value)]) -> Value {
    let outcome = (|| -> Result<Value, String> {
        let (root, db) = locations(&options, CONFIG.get())?;
        let entry = scheduler().entry(&root, &db)?;
        let deadline = if tool == "index" {Instant::now() + Duration::from_secs(120)} else {wait_deadline(&options)};
        let mut arguments = if options.is_object() {options.clone()} else {json!({})};
        for (key, value) in extra {arguments[*key] = value.clone();}
        let mut answer = call(&entry, tool, arguments, deadline);
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
