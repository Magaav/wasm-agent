//! This process's facts, installed into the runner's seam (`ready-operations-slice-2.md`, stage A).
//!
//! The runner moved to its own crate. What it cannot own - this process's run/cancel state, its tool-progress
//! rows, its subagent context, its disk cap - is asked here, and this file is the one place that answers. In
//! stage B the same trait is implemented over the supervisor's wire instead of in-process; the runner does not
//! change.

use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, OnceLock};
use wa_operations_runner::node::{NodeFacts, Provenance, TaskContext};

pub struct HostFacts;

/// Install this process's facts once. Called at startup (and by anything that exercises the runner without
/// going through it - a test, a `wa serve` boot). Idempotent: the runner keeps the first set it was given.
pub fn install() { static ONCE: OnceLock<bool> = OnceLock::new(); ONCE.get_or_init(|| wa_operations_runner::node::install(&FACTS)); }

static FACTS: HostFacts = HostFacts;

impl NodeFacts for HostFacts {
    fn shell_config(&self) -> &'static (String, String) { crate::host::shell_config() }
    fn node_thread_id(&self) -> usize { crate::serve::node_thread_id() }
    fn in_turn(&self) -> bool { crate::serve::in_turn() }
    fn run_cancel_requested(&self) -> bool { crate::host::run_cancel_requested() }
    fn serve_run_cancel_requested(&self) -> bool { crate::serve::run_cancel_requested() }
    fn current_call_is_relayed(&self) -> bool { crate::serve::current_call_is_relayed() }
    fn set_run_cancel_probe(&self, probe: fn() -> bool) { crate::host::set_run_cancel_probe(probe) }
    fn install_relay_context(&self, cancel: Option<Arc<AtomicBool>>, deadline_ms: Option<u64>, owner: String) {
        crate::serve::install_relay_context(cancel, deadline_ms, owner)
    }
    fn beat(&self) { crate::serve::beat() }
    fn progress_tick(&self, id: &str, tool: &str, started_at: f64, stdout_path: &str, stderr_path: &str, owner: &str) -> Option<Value> {
        crate::tool_progress::tick(id, tool, started_at, stdout_path, stderr_path, owner)
    }
    fn progress_finish(&self, id: &str) { crate::tool_progress::finish(id) }
    fn publish_progress(&self, owner: &str, facts: &serde_json::Value) {
        let _ = wa_term::tool_progress::publish(owner, facts);
    }
    fn finish_progress(&self, owner: &str) { wa_term::tool_progress::finish(owner) }
    fn now_epoch(&self) -> f64 { crate::tool_progress::now_epoch() }
    fn current_owner(&self) -> Option<String> { crate::subagents::current_owner() }
    fn current_provenance(&self) -> Option<&'static str> { crate::subagents::current_provenance() }
    fn enter_task(&self, context: TaskContext) {
        crate::subagents::enter_task(crate::subagents::TaskContext {
            cancel: context.cancel,
            deadline: context.deadline,
            sockets: context.sockets,
            owner: context.owner,
            provenance: match context.provenance {
                Provenance::Orchestrator => crate::subagents::Provenance::Orchestrator,
                Provenance::Child => crate::subagents::Provenance::Child,
            },
        })
    }
    fn leave_task(&self) { crate::subagents::leave_task() }
    fn disk_guard_cached(&self, root: &Path, trigger: &str) -> Result<Value, String> {
        crate::disk::guard_cached(root, trigger)
    }
    fn disk_build_island(&self, tree: &Path) -> Option<PathBuf> { crate::disk::build_island(tree) }
    fn forward(&self, action: &str, args: &Value) -> Option<Result<Value, String>> {
        crate::operations_supervisor::forward(action, args)
    }
    fn file_digest(&self, path: &str) -> Result<String, String> { crate::host::file_digest(path) }
    fn file_magic_value(&self, path: &str) -> Value { crate::host::file_magic_value(path) }
    fn which_on_path(&self, name: &str) -> Option<String> { crate::host::which_on_path(name) }
    fn epoch_millis(&self) -> u64 { crate::host::epoch_millis() }
    fn cli_interrupt_millis(&self) -> u64 { crate::host::cli_interrupt_millis() }
}
