//! The facts the runner's own tests install (`host_tests.rs`).
//!
//! They are the SAME answers the production supervisor gives (`wa-operations-supervisor/src/facts.rs`): the pure
//! file questions from `crate::files`, the disk cap from `wa-disk`, the progress stores, and its own cancel flags.
//! A test can flip the flags it needs; it cannot make the runner believe something the real process would not.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::cell::RefCell;
use std::sync::{Arc, OnceLock};
use crate::node::{NodeFacts, TaskContext};

pub struct TestFacts;

// THREAD-LOCAL, because cargo runs these tests in parallel in one process and the facts are per-RUN in
// production (the node scopes them to the thread that is running the call). A process-global here let one
// test's cancel flag cancel another test's child - measured: two tests failed that way.
thread_local! {
    static CANCELLED: std::cell::Cell<bool> = std::cell::Cell::new(false);
    static RELAY: RefCell<Option<Arc<AtomicBool>>> = RefCell::new(None);
    static PROBE: RefCell<Option<fn() -> bool>> = RefCell::new(None);
    static TASK: RefCell<Option<(String, &'static str)>> = RefCell::new(None);
}

pub fn install() {
    static ONCE: OnceLock<bool> = OnceLock::new();
    ONCE.get_or_init(|| crate::node::install(&TestFacts));
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|e| e.as_millis() as u64).unwrap_or(0)
}

impl NodeFacts for TestFacts {
    fn shell_config(&self) -> &'static (String, String) {
        static SHELL: OnceLock<(String, String)> = OnceLock::new();
        SHELL.get_or_init(|| match std::env::var("WASM_AGENT_SHELL") {
            Ok(explicit) if !explicit.is_empty() => (explicit, "-c".to_string()),
            _ => ("/bin/bash".to_string(), "-c".to_string()),
        })
    }
    fn node_thread_id(&self) -> usize { 0 }
    fn in_turn(&self) -> bool { std::env::var("WASM_AGENT_IN_TURN").ok().as_deref() == Some("1") }
    fn run_cancel_requested(&self) -> bool {
        CANCELLED.with(|flag| flag.get())
            || PROBE.with(|probe| probe.borrow().map(|check| check()).unwrap_or(false))
    }
    fn serve_run_cancel_requested(&self) -> bool {
        RELAY.with(|held| held.borrow().as_ref().map(|flag| flag.load(Ordering::Acquire)).unwrap_or(false))
    }
    fn set_run_cancel_probe(&self, probe: fn() -> bool) { PROBE.with(|held| *held.borrow_mut() = Some(probe)); }
    fn install_relay_context(&self, cancel: Option<Arc<AtomicBool>>, _deadline_ms: Option<u64>, _owner: String) {
        RELAY.with(|held| *held.borrow_mut() = cancel);
    }
    fn beat(&self) {}
    fn progress_tick(&self, id: &str, tool: &str, started_at: f64, stdout: &str, stderr: &str, owner: &str) -> Option<Value> {
        crate::tool_progress::tick(id, tool, started_at, stdout, stderr, owner)
    }
    fn progress_finish(&self, id: &str) { crate::tool_progress::finish(id) }
    fn publish_progress(&self, owner: &str, facts: &Value) {
        if let Some(path) = wa_tool_progress::progress_path(owner) {
            if let Some(parent) = path.parent() { let _ = std::fs::create_dir_all(parent); }
            let temporary = path.with_extension("json.tmp");
            if std::fs::write(&temporary, facts.to_string().as_bytes()).is_ok() { let _ = std::fs::rename(&temporary, &path); }
        }
    }
    fn finish_progress(&self, owner: &str) {
        if let Some(path) = wa_tool_progress::progress_path(owner) { let _ = std::fs::remove_file(path); }
    }
    fn now_epoch(&self) -> f64 { now_ms() as f64 / 1000.0 }
    fn current_owner(&self) -> Option<String> { TASK.with(|held| held.borrow().as_ref().map(|(owner, _)| owner.clone())) }
    fn current_provenance(&self) -> Option<&'static str> { TASK.with(|held| held.borrow().as_ref().map(|(_, prov)| *prov)) }
    fn enter_task(&self, context: TaskContext) {
        TASK.with(|held| *held.borrow_mut() = Some((context.owner, context.provenance.as_str())));
    }
    fn leave_task(&self) { TASK.with(|held| *held.borrow_mut() = None); }
    fn disk_guard_cached(&self, root: &Path, trigger: &str) -> Result<Value, String> { wa_disk::guard_cached(root, trigger) }
    fn disk_build_island(&self, tree: &Path) -> Option<PathBuf> { wa_disk::build_island(tree) }
    fn forward(&self, _action: &str, _args: &Value) -> Option<Result<Value, String>> { None }
    fn file_digest(&self, path: &str) -> Result<String, String> { crate::files::file_digest(path) }
    fn file_magic_value(&self, path: &str) -> Value { crate::files::file_magic_value(path) }
    fn which_on_path(&self, name: &str) -> Option<String> { crate::files::which_on_path(name) }
    fn epoch_millis(&self) -> u64 { now_ms() }
    fn cli_interrupt_millis(&self) -> u64 { 0 }
}

/// A test that needs an operation to look cancelled can say so; nothing else can.
pub fn set_cancelled(value: bool) { CANCELLED.with(|flag| flag.set(value)); }
#[allow(dead_code)]
pub fn cancelled_value() -> Value { json!(CANCELLED.with(|flag| flag.get())) }
