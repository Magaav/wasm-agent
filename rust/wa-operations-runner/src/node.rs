//! The seam between the runner and the process that embeds it.
//!
//! The runner owns children, budgets and output cursors. It does NOT own the node's run/cancel state, its
//! tool-progress rows, its subagent context or its disk cap: those belong to whichever process embedded it.
//! Every one of them is asked here, through one trait, so the embedding process is a parameter rather than a
//! compile-time dependency - which is what lets the same runner live inside `wa` today and in its own program
//! (`ready-operations-slice-2.md`, stage B) without a line of the runner's logic changing.
//!
//! `DEFAULTS` is what a process that installed nothing gets: the pure answers (the clock, the shell from the
//! environment) and no-ops for the host facts (no run to cancel, no progress row to publish). It exists so the
//! crate is testable on its own; a node installs its own facts at startup, and the report names the one place
//! that can be missed.

use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, OnceLock};

/// Sockets a child request is blocked on (the host's subagent task context carries one).
pub type SocketSlot = Arc<Mutex<Vec<(u64, std::net::TcpStream)>>>;

/// Whether a shell is a session's own run or a child task.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Provenance {
    Orchestrator,
    Child,
}

impl Provenance {
    pub fn as_str(self) -> &'static str {
        match self {
            Provenance::Orchestrator => "orchestrator",
            Provenance::Child => "child",
        }
    }
}

/// The task context a host installs around a child's turn (see `wa-capabilities::subagents`).
pub struct TaskContext {
    pub cancel: Arc<AtomicBool>,
    pub deadline: Option<std::time::Instant>,
    pub sockets: SocketSlot,
    pub owner: String,
    pub provenance: Provenance,
}

/// The facts the runner asks of the process that embeds it.
pub trait NodeFacts: Send + Sync {
    fn shell_config(&self) -> &'static (String, String);
    fn node_thread_id(&self) -> usize;
    fn in_turn(&self) -> bool;
    fn run_cancel_requested(&self) -> bool;
    fn serve_run_cancel_requested(&self) -> bool;
    fn set_run_cancel_probe(&self, probe: fn() -> bool);
    fn install_relay_context(&self, cancel: Option<Arc<AtomicBool>>, deadline_ms: Option<u64>, owner: String);
    fn beat(&self);
    fn progress_tick(&self, id: &str, tool: &str, started_at: f64, stdout_path: &str, stderr_path: &str, owner: &str) -> Option<Value>;
    fn progress_finish(&self, id: &str);
    /// The node's live view of a running tool (the terminal's own row), separate from the durable file.
    fn publish_progress(&self, owner: &str, facts: &serde_json::Value);
    fn finish_progress(&self, owner: &str);
    fn now_epoch(&self) -> f64;
    fn current_owner(&self) -> Option<String>;
    fn current_provenance(&self) -> Option<&'static str>;
    fn enter_task(&self, context: TaskContext);
    fn leave_task(&self);
    fn disk_guard_cached(&self, root: &Path, trigger: &str) -> Result<Value, String>;
    fn disk_build_island(&self, tree: &Path) -> Option<PathBuf>;
    fn forward(&self, action: &str, args: &Value) -> Option<Result<Value, String>>;
    // Pure helpers the runner asks for rather than re-implementing: a path's digest, a file's magic, a
    // program on PATH, the clock. A separate program supplies its own copies (they read the same disk and
    // the same environment), which is what stage B does.
    fn file_digest(&self, path: &str) -> Result<String, String>;
    fn file_magic_value(&self, path: &str) -> Value;
    fn which_on_path(&self, name: &str) -> Option<String>;
    fn epoch_millis(&self) -> u64;
    fn cli_interrupt_millis(&self) -> u64;
}

/// What a process that installed nothing gets: the pure answers, and no-ops for the host facts.
pub struct Defaults;

impl NodeFacts for Defaults {
    fn shell_config(&self) -> &'static (String, String) {
        static SHELL: OnceLock<(String, String)> = OnceLock::new();
        SHELL.get_or_init(|| match std::env::var("WASM_AGENT_SHELL") {
            Ok(explicit) if !explicit.is_empty() => (explicit, "-c".to_string()),
            _ if cfg!(windows) => ("bash".to_string(), "-c".to_string()),
            _ => ("/bin/bash".to_string(), "-c".to_string()),
        })
    }
    fn node_thread_id(&self) -> usize { 0 }
    fn in_turn(&self) -> bool { std::env::var("WASM_AGENT_IN_TURN").ok().as_deref() == Some("1") }
    fn run_cancel_requested(&self) -> bool { false }
    fn serve_run_cancel_requested(&self) -> bool { false }
    fn set_run_cancel_probe(&self, _probe: fn() -> bool) {}
    fn install_relay_context(&self, _cancel: Option<Arc<AtomicBool>>, _deadline_ms: Option<u64>, _owner: String) {}
    fn beat(&self) {}
    fn progress_tick(&self, _id: &str, _tool: &str, _started_at: f64, _stdout: &str, _stderr: &str, _owner: &str) -> Option<Value> { None }
    fn progress_finish(&self, _id: &str) {}
    fn publish_progress(&self, _owner: &str, _facts: &serde_json::Value) {}
    fn finish_progress(&self, _owner: &str) {}
    fn now_epoch(&self) -> f64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_secs_f64())
            .unwrap_or(0.0)
    }
    fn current_owner(&self) -> Option<String> { None }
    fn current_provenance(&self) -> Option<&'static str> { None }
    fn enter_task(&self, _context: TaskContext) {}
    fn leave_task(&self) {}
    fn disk_guard_cached(&self, _root: &Path, _trigger: &str) -> Result<Value, String> { Ok(Value::Null) }
    fn disk_build_island(&self, _tree: &Path) -> Option<PathBuf> { None }
    fn forward(&self, _action: &str, _args: &Value) -> Option<Result<Value, String>> { None }
    fn file_digest(&self, path: &str) -> Result<String, String> {
        let bytes = std::fs::read(path).map_err(|error| error.to_string())?;
        Ok(crate::operations::sha256_hex(&bytes))
    }
    fn file_magic_value(&self, _path: &str) -> Value { Value::Null }
    fn which_on_path(&self, _name: &str) -> Option<String> { None }
    fn epoch_millis(&self) -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_millis() as u64)
            .unwrap_or(0)
    }
    fn cli_interrupt_millis(&self) -> u64 { 0 }
}

static NODE: OnceLock<&'static dyn NodeFacts> = OnceLock::new();

/// Install the embedding process's facts. The FIRST install wins; a second one is ignored (a process has one
/// set of facts, and silently swapping them mid-flight would make an operation's answers move under it).
pub fn install(facts: &'static dyn NodeFacts) -> bool {
    NODE.set(facts).is_ok()
}

fn node() -> &'static dyn NodeFacts {
    static DEFAULTS: Defaults = Defaults;
    NODE.get().copied().unwrap_or(&DEFAULTS)
}

// ---- the wrappers the runner calls -------------------------------------------------------------
pub fn shell_config() -> &'static (String, String) { node().shell_config() }
pub fn node_thread_id() -> usize { node().node_thread_id() }
pub fn in_turn() -> bool { node().in_turn() }
pub fn run_cancel_requested() -> bool { node().run_cancel_requested() }
pub fn serve_run_cancel_requested() -> bool { node().serve_run_cancel_requested() }
pub fn set_run_cancel_probe(probe: fn() -> bool) { node().set_run_cancel_probe(probe) }
pub fn install_relay_context(cancel: Option<Arc<AtomicBool>>, deadline_ms: Option<u64>, owner: String) {
    node().install_relay_context(cancel, deadline_ms, owner)
}
pub fn beat() { node().beat() }
pub fn progress_tick(id: &str, tool: &str, started_at: f64, stdout_path: &str, stderr_path: &str, owner: &str) -> Option<Value> {
    node().progress_tick(id, tool, started_at, stdout_path, stderr_path, owner)
}
pub fn progress_finish(id: &str) { node().progress_finish(id) }
pub fn publish_progress(owner: &str, facts: &serde_json::Value) { node().publish_progress(owner, facts) }
pub fn finish_progress(owner: &str) { node().finish_progress(owner) }
pub fn now_epoch() -> f64 { node().now_epoch() }
pub fn current_owner() -> Option<String> { node().current_owner() }
pub fn current_provenance() -> Option<&'static str> { node().current_provenance() }
pub fn enter_task(context: TaskContext) { node().enter_task(context) }
pub fn leave_task() { node().leave_task() }
pub fn disk_guard_cached(root: &Path, trigger: &str) -> Result<Value, String> { node().disk_guard_cached(root, trigger) }
pub fn disk_build_island(tree: &Path) -> Option<PathBuf> { node().disk_build_island(tree) }
pub fn forward(action: &str, args: &Value) -> Option<Result<Value, String>> { node().forward(action, args) }
pub fn file_digest(path: &str) -> Result<String, String> { node().file_digest(path) }
pub fn file_magic_value(path: &str) -> Value { node().file_magic_value(path) }
pub fn which_on_path(name: &str) -> Option<String> { node().which_on_path(name) }
pub fn epoch_millis() -> u64 { node().epoch_millis() }
pub fn cli_interrupt_millis() -> u64 { node().cli_interrupt_millis() }
