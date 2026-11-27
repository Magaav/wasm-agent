//! What this process can answer for itself.
//!
//! The runner asks its embedder for ~20 facts. In the node they come from the node's own modules; here they come
//! from the leaf crates both sides link (`wa-disk`, `wa-tool-progress`), from the process's own environment, and
//! from its own atomics - which is the point of the move: the supervisor does not need the node to start a child,
//! check a disk cap, or publish a progress row.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use wa_operations_runner::node::{NodeFacts, TaskContext};

pub struct SupervisorFacts;

static CANCEL: AtomicBool = AtomicBool::new(false);
static RELAY_CANCEL: Mutex<Option<Arc<AtomicBool>>> = Mutex::new(None);
static RELAY_DEADLINE: AtomicU64 = AtomicU64::new(0);
static RELAY_OWNER: Mutex<Option<String>> = Mutex::new(None);
static THREAD: AtomicUsize = AtomicUsize::new(0);
static BEAT_MS: AtomicU64 = AtomicU64::new(0);
static PROBE: Mutex<Option<fn() -> bool>> = Mutex::new(None);

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or(0)
}

impl NodeFacts for SupervisorFacts {
    fn shell_config(&self) -> &'static (String, String) {
        static SHELL: OnceLock<(String, String)> = OnceLock::new();
        SHELL.get_or_init(|| match std::env::var("WASM_AGENT_SHELL") {
            Ok(explicit) if !explicit.is_empty() => (explicit, "-c".to_string()),
            _ if cfg!(windows) => ("bash".to_string(), "-c".to_string()),
            _ => ("/bin/bash".to_string(), "-c".to_string()),
        })
    }
    fn node_thread_id(&self) -> usize { THREAD.load(Ordering::Acquire) }
    // The node's in-turn marker travels with the request; absent, this process is never "in a turn" itself.
    fn in_turn(&self) -> bool { std::env::var("WASM_AGENT_IN_TURN").ok().as_deref() == Some("1") }
    fn run_cancel_requested(&self) -> bool {
        CANCEL.load(Ordering::Acquire)
            || PROBE.lock().map(|probe| probe.map(|check| check()).unwrap_or(false)).unwrap_or(false)
    }
    fn serve_run_cancel_requested(&self) -> bool {
        RELAY_CANCEL.lock().ok().and_then(|held| held.as_ref().map(|flag| flag.load(Ordering::Acquire))).unwrap_or(false)
    }
    fn set_run_cancel_probe(&self, probe: fn() -> bool) {
        if let Ok(mut held) = PROBE.lock() { *held = Some(probe); }
    }
    fn install_relay_context(&self, cancel: Option<Arc<AtomicBool>>, deadline_ms: Option<u64>, owner: String) {
        if let Ok(mut held) = RELAY_CANCEL.lock() { *held = cancel; }
        RELAY_DEADLINE.store(deadline_ms.unwrap_or(0), Ordering::Release);
        if let Ok(mut held) = RELAY_OWNER.lock() { *held = Some(owner); }
    }
    fn beat(&self) { BEAT_MS.store(now_ms(), Ordering::Release); }
    fn progress_tick(&self, id: &str, tool: &str, started_at: f64, stdout_path: &str, stderr_path: &str, owner: &str) -> Option<Value> {
        wa_operations_runner::tool_progress::tick(id, tool, started_at, stdout_path, stderr_path, owner)
    }
    fn progress_finish(&self, id: &str) { wa_operations_runner::tool_progress::finish(id) }
    fn publish_progress(&self, owner: &str, facts: &Value) {
        // The same file the node's terminal reads (`wa_term::tool_progress::publish` writes exactly this), so a
        // row drawn here is the row drawn there.
        if let Some(path) = wa_tool_progress::progress_path(owner) {
            if let Some(parent) = path.parent() { let _ = std::fs::create_dir_all(parent); }
            let temporary = path.with_extension("json.tmp");
            if std::fs::write(&temporary, facts.to_string().as_bytes()).is_ok() {
                let _ = std::fs::rename(&temporary, &path);
            }
        }
    }
    fn finish_progress(&self, owner: &str) {
        if let Some(path) = wa_tool_progress::progress_path(owner) { let _ = std::fs::remove_file(path); }
    }
    fn now_epoch(&self) -> f64 { now_ms() as f64 / 1000.0 }
    // This process runs no subagent turn and owns no session scope: those travel in the request.
    fn current_owner(&self) -> Option<String> { RELAY_OWNER.lock().ok().and_then(|held| held.clone()) }
    fn current_provenance(&self) -> Option<&'static str> { None }
    fn enter_task(&self, _context: TaskContext) {}
    fn leave_task(&self) {}
    fn disk_guard_cached(&self, root: &Path, trigger: &str) -> Result<Value, String> {
        wa_disk::guard_cached(root, trigger)
    }
    fn disk_build_island(&self, tree: &Path) -> Option<PathBuf> { wa_disk::build_island(tree) }
    // No nested supervision: this IS the supervisor.
    fn forward(&self, _action: &str, _args: &Value) -> Option<Result<Value, String>> { None }
    fn file_digest(&self, path: &str) -> Result<String, String> { wa_files::file_digest(path) }
    fn file_magic_value(&self, path: &str) -> Value { wa_files::file_magic_value(path) }
    fn which_on_path(&self, name: &str) -> Option<String> { wa_files::which_on_path(name) }
    fn epoch_millis(&self) -> u64 { now_ms() }
    fn cli_interrupt_millis(&self) -> u64 { 0 }
}

/// The beat, for the node's `/health`: it asks the supervisor rather than reading its own clock.
pub fn beat_age_ms() -> u64 {
    let beat = BEAT_MS.load(Ordering::Acquire);
    if beat == 0 { 0 } else { now_ms().saturating_sub(beat) }
}

/// The verb table this process serves, in one place so the node's client and this server cannot drift.
pub fn call(verb: &str, args: &Value) -> Result<Value, String> {
    use wa_operations_runner::operations as runner;
    let shell = <SupervisorFacts as NodeFacts>::shell_config(&SupervisorFacts);
    match verb {
        "control" => runner::control(args["action"].as_str().unwrap_or(""), &args["args"], shell),
        "foreground" => {
            let program = args["program"].as_str().unwrap_or("");
            let flag = args["flag"].as_str().unwrap_or("-c");
            let command = args["command"].as_str().unwrap_or("");
            let cwd = args["cwd"].as_str().unwrap_or("");
            let seconds = args["seconds"].as_u64().unwrap_or(60);
            let context = args.get("context").cloned().unwrap_or(Value::Null);
            let stdin = args["stdin"].as_str();
            BEAT_MS.store(now_ms(), Ordering::Release);
            runner::foreground(program, flag, command, cwd, seconds, &context, stdin)
        }
        "health" => Ok(runner::health()),
        "health_scope" => Ok(runner::health_scope_for(
            args["session"].as_str().unwrap_or(""),
            args["node_wide"].as_bool().unwrap_or(false),
            args["owner"].as_str().unwrap_or(""),
        )),
        "elsewhere_count" => Ok(json!(runner::elsewhere_count(args["session"].as_str().unwrap_or("")))),
        "owned_child" => {
            let id = args["id"].as_str().unwrap_or("");
            let pid = args["pid"].as_u64().unwrap_or(0) as u32;
            let owner = args["owner"].as_str().unwrap_or("");
            runner::manager().observe_owned_child(id, pid, owner).map_err(|error| error.to_string())
        }
        "beat_age" => Ok(json!({"beat_age_ms": beat_age_ms()})),
        other => Err(format!("operations_supervisor_unknown_verb: {other}")),
    }
}
