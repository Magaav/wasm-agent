//! Local subagents: a durable, supervised child agent run.
//!
//! A *subagent* is a child task with its own fresh context, its own session and
//! bounded execution, owned by a parent run or job delivery (docs/EXECUTION.md).
//! It is not a job (an automation definition), not an operation (an external
//! process) and not a run in the parent's session.
//!
//! This module owns the parts a Lua interpreter must not: OS threads, lifetime,
//! cancellation flags, deadlines, capacity, durable records and the wait a
//! caller blocks on. **All agent policy lives in Lua** (`lua/core/subagents.lua`,
//! `lua/core/agent.lua`): which profile, which tools, which prompt, which budgets.
//! The seam is one call: a runner receives a durable receipt and must return the
//! child's terminal result as JSON.
//!
//! Nothing here calls a model or polls one. A waiter blocks on a native
//! condition variable; the child runs on its own pool, so a parent waiting for a
//! child never occupies the capacity that runs the child, and child work never
//! consumes a reserved interactive HTTP worker.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Runs one admitted child and returns its terminal result JSON.
///
/// Production builds this from the fresh-interpreter factory registered by
/// `main.rs`; tests supply a deterministic fake so the runtime's lifetime,
/// capacity, idempotency and recovery can be proved without a model.
pub type Runner = Arc<dyn Fn(&str) -> Result<Value, String> + Send + Sync>;

const DEFAULT_MAX_CONCURRENT: usize = 2;
const DEFAULT_QUEUE_DEPTH: usize = 6;

fn env_usize(name: &str, fallback: usize) -> usize {
    std::env::var(name).ok().and_then(|value| value.parse().ok()).unwrap_or(fallback)
}

fn now_secs() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// A per-boot identifier. A record left `running`/`accepted` by another boot is
/// `unknown`: it may have died, and this runtime has no way to observe it.
fn boot_id() -> &'static str {
    static BOOT: OnceLock<String> = OnceLock::new();
    BOOT.get_or_init(|| format!("{}-{}", std::process::id(), now_ms()))
}

fn subagent_root() -> PathBuf {
    if let Ok(explicit) = std::env::var("WASM_AGENT_SUBAGENT_ROOT") {
        if !explicit.is_empty() {
            return PathBuf::from(explicit);
        }
    }
    // The same resolved home the rest of the host uses: `WASM_AGENT_HOME` first,
    // then the native Windows variables, then HOME. Reading `HOME` alone missed
    // `WASM_AGENT_HOME`, so a candidate node's children landed in the operator's
    // real home - and a test could write it.
    PathBuf::from(crate::resolve_home()).join(".wasm-agent/subagents")
}

/// Sockets the current child request is blocked on, shared with the task so a
/// cancel from another thread can `shutdown` a silent provider read.
pub type SocketSlot = Arc<Mutex<Vec<std::net::TcpStream>>>;

/// Register the socket a provider request just connected on, so cancelling the
/// task can interrupt a read that is producing no chunks. The clone is stored in
/// the shared slot; `shutdown(Both)` on it wakes the blocked read immediately.
pub fn register_active_socket(stream: &std::net::TcpStream) {
    if let Ok(clone) = stream.try_clone() {
        CURRENT.with(|slot| {
            if let Some(context) = slot.borrow().as_ref() {
                if let Ok(mut sockets) = context.sockets.lock() {
                    sockets.push(clone);
                }
            } else {
                eprintln!("[dbg-sock] register with no task context");
            }
        });
    }
}

/// Forget the current request's sockets once it has finished, so a later cancel
/// does not shut down a pooled connection that is no longer this call's.
pub fn clear_active_socket() {
    CURRENT.with(|slot| {
        if let Some(context) = slot.borrow().as_ref() {
            if let Ok(mut sockets) = context.sockets.lock() {
                sockets.clear();
            }
        }
    });
}

/// Wake every socket this task is blocked on. Called on cancel from any thread.
pub fn shutdown_sockets(sockets: &SocketSlot) {
    if let Ok(sockets) = sockets.lock() {
        for stream in sockets.iter() {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
    }
}

/// What a running child thread may know about its own task: the cancel flag the
/// manager flips, the deadline the provider I/O must respect, and the sockets its
/// current provider request is blocked on.
///
/// These are thread-local because the interpreter that makes the provider call is
/// owned by exactly one child thread at a time. `host.http`/`host.http_stream`
/// read them, which is what makes cancellation and a deadline affect provider
/// I/O rather than only being noticed between model calls.
#[derive(Clone)]
pub struct TaskContext {
    pub cancel: Arc<AtomicBool>,
    pub deadline: Option<Instant>,
    pub sockets: SocketSlot,
    /// The child's session id, so an operation it starts is owned by the child
    /// session/run rather than by the interpreter's worker slot.
    pub owner: String,
}

thread_local! {
    static CURRENT: std::cell::RefCell<Option<TaskContext>> = const { std::cell::RefCell::new(None) };
}

pub fn enter_task(context: TaskContext) {
    CURRENT.with(|slot| *slot.borrow_mut() = Some(context));
}

pub fn leave_task() {
    CURRENT.with(|slot| *slot.borrow_mut() = None);
}

/// Is this thread running a child task? The http transport uses it to decide
/// whether a request needs the shutdown-aware socket.
pub fn in_task() -> bool {
    CURRENT.with(|slot| slot.borrow().is_some())
}

/// The child session an operation should be owned by, if this thread is a child.
pub fn current_owner() -> Option<String> {
    CURRENT.with(|slot| {
        slot.borrow().as_ref().and_then(|context| {
            if context.owner.is_empty() { None } else { Some(context.owner.clone()) }
        })
    })
}

/// Has the caller requested cancellation? Used by the provider reader and by the
/// Lua child when it asks `host.subagent("self")`.
pub fn cancel_requested() -> bool {
    CURRENT.with(|slot| slot.borrow().as_ref().map(|c| c.cancel.load(Ordering::SeqCst)).unwrap_or(false))
}

/// The remaining execution budget for provider I/O, if this thread runs a child.
pub fn remaining_budget() -> Option<Duration> {
    CURRENT.with(|slot| {
        slot.borrow().as_ref().and_then(|c| c.deadline).map(|deadline| deadline.saturating_duration_since(Instant::now()))
    })
}

/// A task as the runtime knows it. The public JSON form is `Task::view`.
struct Task {
    id: String,
    spec: Value,
    profile: String,
    session_id: String,
    owner_user: String,
    parent_session_id: String,
    parent_run_id: String,
    node_id: String,
    depth: u32,
    idempotency_key: String,
    state: String,
    settled: bool,
    result: Value,
    error: Option<String>,
    created_at: f64,
    started_at: Option<f64>,
    settled_at: Option<f64>,
    timeout_seconds: u64,
    cancel: Arc<AtomicBool>,
    sockets: SocketSlot,
    boot: String,
    pid: u32,
}

impl Task {
    fn view(&self, include_result: bool) -> Value {
        let mut value = json!({
            "subagent_id": self.id,
            "state": self.state,
            "settled": self.settled,
            "session_id": self.session_id,
            "profile": self.profile,
            "owner_user": self.owner_user,
            "parent_session_id": self.parent_session_id,
            "parent_run_id": self.parent_run_id,
            "node_id": self.node_id,
            "depth": self.depth,
            "created_at": self.created_at,
            "started_at": self.started_at,
            "settled_at": self.settled_at,
            "timeout_seconds": self.timeout_seconds,
        });
        if let Some(error) = &self.error {
            value["error"] = json!(error);
        }
        if include_result {
            value["result"] = self.result.clone();
        }
        value
    }
}

struct Inner {
    root: PathBuf,
    max_concurrent: usize,
    tasks: Mutex<HashMap<String, Task>>,
    idem: Mutex<HashMap<String, String>>,
    /// Set when a durable record could not be read or is inconsistent. New
    /// admission is refused while it is set, because a lost record also loses the
    /// idempotency key that prevents a replay.
    recovery_error: Mutex<Option<String>>,
    /// Notified whenever a task changes state, so `await` can wake.
    changed: Condvar,
    /// Bounded concurrency: at most `max_concurrent` children execute at once.
    running: Mutex<usize>,
    capacity: Condvar,
}

pub struct Manager {
    inner: Arc<Inner>,
    runner: OnceLock<Runner>,
    max_live: usize,
}

static MANAGER: OnceLock<Manager> = OnceLock::new();

fn manager() -> &'static Manager {
    MANAGER.get_or_init(|| {
        let max_concurrent = env_usize("WASM_AGENT_SUBAGENT_CONCURRENCY", DEFAULT_MAX_CONCURRENT).clamp(1, 16);
        let queue_depth = env_usize("WASM_AGENT_SUBAGENT_QUEUE_DEPTH", DEFAULT_QUEUE_DEPTH).clamp(1, 64);
        let manager = Manager::with_root(subagent_root(), max_concurrent, queue_depth);
        manager.recover();
        manager
    })
}

impl Manager {
    fn with_root(root: PathBuf, max_concurrent: usize, queue_depth: usize) -> Self {
        Manager {
            inner: Arc::new(Inner {
                root,
                max_concurrent,
                tasks: Mutex::new(HashMap::new()),
                idem: Mutex::new(HashMap::new()),
                recovery_error: Mutex::new(None),
                changed: Condvar::new(),
                running: Mutex::new(0),
                capacity: Condvar::new(),
            }),
            runner: OnceLock::new(),
            max_live: max_concurrent + queue_depth,
        }
    }

    fn set_recovery_error(&self, message: String) {
        if let Ok(mut slot) = self.inner.recovery_error.lock() {
            if slot.is_none() {
                *slot = Some(message);
            }
        }
    }

    /// Load records left by an earlier boot. Anything still `running`/`accepted`
    /// is `unknown`: not attached to this runtime, so it may have died and must
    /// not be silently replayed.
    ///
    /// A record that cannot be read is NOT skipped silently: skipping it would
    /// also lose the idempotency key it carries, so a repeat start could spawn a
    /// second child and replay an effect. The fault is recorded and admission is
    /// refused until it is resolved.
    fn recover(&self) {
        let entries = match std::fs::read_dir(&self.inner.root) {
            Ok(entries) => entries,
            // A node that has never run a child simply has no root yet.
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
            Err(error) => {
                self.set_recovery_error(format!("subagent_root_unreadable: {error}"));
                return;
            }
        };
        let boot = boot_id();
        let mut tasks = self.inner.tasks.lock().expect("subagents tasks");
        for entry in entries {
            let entry = match entry {
                Ok(entry) => entry,
                Err(error) => {
                    self.set_recovery_error(format!("subagent_root_entry_unreadable: {error}"));
                    continue;
                }
            };
            let directory = entry.path();
            if !directory.is_dir() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().to_string();
            let record = directory.join("record.json");
            let text = match std::fs::read_to_string(&record) {
                Ok(text) => text,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => {
                    self.set_recovery_error(format!("subagent_record_unreadable:{name}: {error}"));
                    continue;
                }
            };
            let value: Value = match serde_json::from_str(&text) {
                Ok(value) => value,
                Err(error) => {
                    self.set_recovery_error(format!("subagent_record_corrupt:{name}: {error}"));
                    continue;
                }
            };
            let id = value["id"].as_str().unwrap_or_default().to_string();
            if id.is_empty() || id != name {
                self.set_recovery_error(format!("subagent_record_id_mismatch:{name}"));
                continue;
            }
            let settled = value["settled"].as_bool().unwrap_or(false);
            let attached = value["boot"].as_str() == Some(boot);
            let mut state = value["state"].as_str().unwrap_or("unknown").to_string();
            if !settled && !attached {
                state = "unknown".to_string();
            }
            let task = Task {
                id: id.clone(),
                spec: value.get("spec").cloned().unwrap_or(Value::Null),
                profile: value["profile"].as_str().unwrap_or_default().to_string(),
                session_id: value["session_id"].as_str().unwrap_or_default().to_string(),
                owner_user: value["owner_user"].as_str().unwrap_or_default().to_string(),
                parent_session_id: value["parent_session_id"].as_str().unwrap_or_default().to_string(),
                parent_run_id: value["parent_run_id"].as_str().unwrap_or_default().to_string(),
                node_id: value["node_id"].as_str().unwrap_or_default().to_string(),
                depth: value["depth"].as_u64().unwrap_or(1) as u32,
                idempotency_key: value["idempotency_key"].as_str().unwrap_or_default().to_string(),
                state: state.clone(),
                settled: settled || state == "unknown",
                result: value["result"].clone(),
                error: value["error"].as_str().map(str::to_string),
                created_at: value["created_at"].as_f64().unwrap_or(0.0),
                started_at: value["started_at"].as_f64(),
                settled_at: value["settled_at"].as_f64(),
                timeout_seconds: value["timeout_seconds"].as_u64().unwrap_or(0),
                cancel: Arc::new(AtomicBool::new(true)),
                sockets: Arc::new(Mutex::new(Vec::new())),
                boot: value["boot"].as_str().unwrap_or_default().to_string(),
                pid: value["pid"].as_u64().unwrap_or(0) as u32,
            };
            if !task.idempotency_key.is_empty() {
                if let Ok(mut idem) = self.inner.idem.lock() {
                    idem.insert(format!("{}\u{1}{}", task.owner_user, task.idempotency_key), task.id.clone());
                }
            }
            tasks.insert(id, task);
        }
    }

    fn notify(&self) {
        self.inner.changed.notify_all();
    }

    fn live_count(tasks: &HashMap<String, Task>) -> usize {
        tasks.values().filter(|task| !task.settled).count()
    }

    fn start(&self, spec: &Value) -> Result<Value, String> {
        if self.runner.get().is_none() {
            return Err("subagent_runtime_unavailable".into());
        }
        let id = spec["id"].as_str().filter(|s| !s.is_empty()).ok_or("id_required")?;
        // The id names a directory under the runtime root. It is generated by Lua,
        // but validate it here too: a raw caller-supplied id must never escape the
        // root or traverse it, whatever the facade did.
        if id.len() > 128 || id.contains('/') || id.contains('\\') || id.contains("..") || id.starts_with('.') {
            return Err("invalid_id".into());
        }
        let owner = spec["owner_user"].as_str().unwrap_or_default().to_string();
        if owner.is_empty() {
            return Err("owner_user_required".into());
        }
        let idempotency = spec["idempotency_key"].as_str().unwrap_or_default().to_string();
        let timeout_seconds = spec["timeout_seconds"].as_u64().unwrap_or(0);
        // ONE admission lock covers the recovery fault, idempotency, capacity, the
        // durable record and the in-memory insert. Releasing it between the
        // idempotency check and the insert let two simultaneous starts with the
        // same key both create a child and both run inference.
        let mut tasks = self.inner.tasks.lock().map_err(|_| "subagent_state_poisoned".to_string())?;
        if let Ok(slot) = self.inner.recovery_error.lock() {
            if let Some(error) = slot.as_ref() {
                return Err(format!("recovery_error: {error}"));
            }
        }
        if !idempotency.is_empty() {
            let key = format!("{owner}\u{1}{idempotency}");
            let existing = self
                .inner
                .idem
                .lock()
                .map_err(|_| "subagent_state_poisoned".to_string())?
                .get(&key)
                .cloned();
            if let Some(existing_id) = existing {
                if let Some(task) = tasks.get(&existing_id) {
                    let mut view = task.view(true);
                    view["deduplicated"] = json!(true);
                    return Ok(view);
                }
            }
        }
        if tasks.contains_key(id) {
            return Err("subagent_id_exists".into());
        }
        if Self::live_count(&tasks) >= self.max_live {
            return Err("queue_full".into());
        }
        let queued = tasks.values().filter(|task| !task.settled && task.state == "accepted").count();
        let task = Task {
            id: id.to_string(),
            spec: spec.clone(),
            profile: spec["profile"].as_str().unwrap_or_default().to_string(),
            session_id: spec["session_id"].as_str().unwrap_or_default().to_string(),
            owner_user: owner.clone(),
            parent_session_id: spec["parent_session_id"].as_str().unwrap_or_default().to_string(),
            parent_run_id: spec["parent_run_id"].as_str().unwrap_or_default().to_string(),
            node_id: spec["node_id"].as_str().unwrap_or_default().to_string(),
            depth: spec["depth"].as_u64().unwrap_or(1) as u32,
            idempotency_key: idempotency.clone(),
            state: "accepted".to_string(),
            settled: false,
            result: Value::Null,
            error: None,
            created_at: now_secs(),
            started_at: None,
            settled_at: None,
            timeout_seconds,
            cancel: Arc::new(AtomicBool::new(false)),
            sockets: Arc::new(Mutex::new(Vec::new())),
            boot: boot_id().to_string(),
            pid: std::process::id(),
        };
        persist_task(&self.inner.root, &task).map_err(|error| format!("record_write_failed:{error}"))?;
        if !idempotency.is_empty() {
            if let Ok(mut idem) = self.inner.idem.lock() {
                idem.insert(format!("{owner}\u{1}{idempotency}"), id.to_string());
            }
        }
        let view = task.view(false);
        let cancel = task.cancel.clone();
        let sockets = task.sockets.clone();
        tasks.insert(id.to_string(), task);
        drop(tasks);
        self.notify();

        let inner = self.inner.clone();
        let runner = self.runner.get().cloned().ok_or("subagent_runtime_unavailable")?;
        let manager_id = id.to_string();
        std::thread::Builder::new()
            .name(format!("wa-subagent-{manager_id}"))
            .spawn(move || run_child(inner, runner, manager_id, cancel, sockets))
            .map_err(|error| {
                // The thread could not start: settle the record rather than leave
                // an accepted receipt that nothing will ever advance.
                let mut tasks = self.inner.tasks.lock().expect("subagents tasks");
                if let Some(task) = tasks.get_mut(id) {
                    task.state = "failed".into();
                    task.settled = true;
                    task.error = Some(format!("thread_spawn_failed: {error}"));
                    task.settled_at = Some(now_secs());
                    let snapshot = task.view(true);
                    drop(tasks);
                    if let Err(error) = persist_view(&self.inner.root, &snapshot) {
                        eprintln!("[subagents] could not record a spawn failure for {id}: {error}");
                    }
                }
                error.to_string()
            })?;
        let mut receipt = view;
        receipt["queue_position"] = json!(queued);
        receipt["settled"] = json!(false);
        receipt["note"] = json!("Launch receipt, not completion. Observe or await; do not start it again.");
        Ok(receipt)
    }

    fn find(&self, id: &str, owner: &str) -> Result<Value, String> {
        let tasks = self.inner.tasks.lock().map_err(|_| "subagent_state_poisoned".to_string())?;
        let task = tasks.get(id).ok_or("unknown_subagent")?;
        if owner != task.owner_user {
            return Err("forbidden_subagent".into());
        }
        Ok(task.view(true))
    }

    fn list(&self, owner: &str) -> Value {
        let tasks = self.inner.tasks.lock().expect("subagents tasks");
        let mut items: Vec<Value> = tasks
            .values()
            .filter(|task| task.owner_user == owner)
            .map(|task| task.view(false))
            .collect();
        items.sort_by(|a, b| {
            b["created_at"].as_f64().partial_cmp(&a["created_at"].as_f64()).unwrap_or(std::cmp::Ordering::Equal)
        });
        json!({ "subagents": items, "count": items.len() })
    }

    fn await_task(&self, id: &str, owner: &str, wait_ms: u64) -> Result<Value, String> {
        let started = Instant::now();
        let limit = Duration::from_millis(wait_ms.min(600_000));
        let mut tasks = self.inner.tasks.lock().map_err(|_| "subagent_state_poisoned".to_string())?;
        loop {
            let task = tasks.get(id).ok_or("unknown_subagent")?;
            if owner != task.owner_user {
                return Err("forbidden_subagent".into());
            }
            if task.settled {
                return Ok(task.view(true));
            }
            let elapsed = started.elapsed();
            if elapsed >= limit {
                let mut view = task.view(false);
                view["waited_ms"] = json!(elapsed.as_millis() as u64);
                view["note"] = json!("Still running. This is not failure and never permission to start it again.");
                return Ok(view);
            }
            let remaining = limit - elapsed;
            let (guard, _) = self
                .inner
                .changed
                .wait_timeout(tasks, remaining)
                .map_err(|_| "subagent_state_poisoned".to_string())?;
            tasks = guard;
        }
    }

    fn cancel(&self, id: &str, owner: &str) -> Result<Value, String> {
        let mut tasks = self.inner.tasks.lock().map_err(|_| "subagent_state_poisoned".to_string())?;
        let task = tasks.get_mut(id).ok_or("unknown_subagent")?;
        if owner != task.owner_user {
            return Err("forbidden_subagent".into());
        }
        if task.settled {
            return Ok(task.view(false));
        }
        task.cancel.store(true, Ordering::SeqCst);
        // Waking the capacity waiter lets a queued child observe its cancellation
        // and settle instead of running after the caller stopped caring. Shutting
        // the sockets wakes a provider read that is producing nothing.
        self.inner.capacity.notify_all();
        shutdown_sockets(&task.sockets);
        Ok(task.view(false))
    }

    /// One strict summary shape: `{queued, running, active}` where
    /// `active = queued + running`, plus the optional retained `settled` counts.
    /// A task whose cancellation was requested but whose execution has not
    /// stopped is still running (or still queued), so it stays inside `active`
    /// until it settles.
    fn summary(&self) -> Value {
        let tasks = self.inner.tasks.lock().expect("subagents tasks");
        let mut queued = 0u64;
        let mut running = 0u64;
        let mut settled = json!({"completed": 0u64, "failed": 0u64, "cancelled": 0u64, "unknown": 0u64});
        for task in tasks.values() {
            if !task.settled {
                if task.state == "accepted" {
                    queued += 1;
                } else {
                    running += 1;
                }
            } else if let Some(slot) = settled.get_mut(&task.state) {
                if let Some(count) = slot.as_u64() {
                    *slot = json!(count + 1);
                }
            }
        }
        json!({
            "queued": queued,
            "running": running,
            "active": queued + running,
            "settled": settled,
            // Visible fault: while this is set, new admission is refused because a
            // lost record also lost the idempotency key that prevents a replay.
            "recovery_error": self.inner.recovery_error.lock().ok().and_then(|slot| slot.clone()),
        })
    }

    fn resolve(&self, owner: &str, key: &str) -> Value {
        if key.is_empty() {
            return json!({ "found": false });
        }
        let lookup = format!("{owner}\u{1}{key}");
        // Same lock order as `start` (tasks then idem), so admission and lookup
        // cannot deadlock or disagree.
        let tasks = self.inner.tasks.lock().expect("subagents tasks");
        let id = self.inner.idem.lock().ok().and_then(|idem| idem.get(&lookup).cloned());
        match id {
            Some(id) => match tasks.get(&id) {
                Some(task) => {
                    let mut view = task.view(true);
                    view["found"] = json!(true);
                    view
                }
                None => json!({ "found": false }),
            },
            None => json!({ "found": false }),
        }
    }
}

fn persist_task(root: &Path, task: &Task) -> Result<(), String> {
    let directory = root.join(&task.id);
    std::fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
    let record = json!({
        "id": task.id,
        "spec": task.spec,
        "profile": task.profile,
        "session_id": task.session_id,
        "owner_user": task.owner_user,
        "parent_session_id": task.parent_session_id,
        "parent_run_id": task.parent_run_id,
        "node_id": task.node_id,
        "depth": task.depth,
        "idempotency_key": task.idempotency_key,
        "state": task.state,
        "settled": task.settled,
        "result": task.result,
        "error": task.error,
        "created_at": task.created_at,
        "started_at": task.started_at,
        "settled_at": task.settled_at,
        "timeout_seconds": task.timeout_seconds,
        "boot": task.boot,
        "pid": task.pid,
    });
    write_record(&directory, &record)
}

/// Persist a settled task from its own view, merged onto the durable record so
/// the resolved `spec` written at admission is preserved. A failure is returned
/// so the caller can surface it rather than lose the only durable evidence.
fn persist_view(root: &Path, view: &Value) -> Result<(), String> {
    let id = view["subagent_id"].as_str().unwrap_or_default();
    if id.is_empty() {
        return Ok(());
    }
    let directory = root.join(id);
    std::fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
    let path = directory.join("record.json");
    let mut record = std::fs::read_to_string(&path)
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}));
    if let (Some(target), Some(source)) = (record.as_object_mut(), view.as_object()) {
        for key in ["state", "settled", "result", "error", "settled_at", "started_at"] {
            if let Some(value) = source.get(key) {
                target.insert(key.to_string(), value.clone());
            }
        }
    } else {
        record = view.clone();
    }
    write_record(&directory, &record)
}

/// Write atomically, and return the error instead of swallowing it: a durable
/// record that silently did not persist is the one failure a supervisor must not
/// hide. On Windows `rename` may replace an existing file; where it cannot, the
/// checked error reaches the caller rather than being dropped.
fn write_record(directory: &Path, record: &Value) -> Result<(), String> {
    let path = directory.join("record.json");
    let temporary = directory.join(".record.json.tmp");
    // fsync before the rename: a promise of durability cannot rest on a write that
    // may still be in the page cache when the process dies.
    {
        use std::io::Write;
        let mut file = std::fs::File::create(&temporary).map_err(|error| error.to_string())?;
        file.write_all(record.to_string().as_bytes()).map_err(|error| error.to_string())?;
        file.sync_all().map_err(|error| error.to_string())?;
    }
    std::fs::rename(&temporary, &path).map_err(|error| {
        let _ = std::fs::remove_file(&temporary);
        error.to_string()
    })
}

/// The body of a child task's own thread. Capacity is acquired here, not in
/// `start`, so admission is a durable receipt and execution is bounded.
fn run_child(inner: Arc<Inner>, runner: Runner, id: String, cancel: Arc<AtomicBool>, sockets: SocketSlot) {
    // Acquire a bounded execution slot; a cancelled or settled task is skipped.
    if !acquire(&inner, &cancel) {
        settle_view(&inner, &id, "cancelled", Value::Null, Some("cancelled_before_start".into()));
        return;
    }
    {
        let mut tasks = inner.tasks.lock().expect("subagents tasks");
        if let Some(task) = tasks.get_mut(&id) {
            if task.settled {
                release(&inner);
                return;
            }
            task.state = "running".into();
            task.started_at = Some(now_secs());
        }
    }
    // The execution budget begins when execution does, not when the receipt was
    // admitted, so queueing does not secretly eat a child's timeout.
    let (timeout_seconds, owner) = {
        let tasks = inner.tasks.lock().expect("subagents tasks");
        match tasks.get(&id) {
            Some(task) => (task.timeout_seconds, format!("subagent:{}", task.session_id)),
            None => (0, String::new()),
        }
    };
    let deadline = if timeout_seconds > 0 { Some(Instant::now() + Duration::from_secs(timeout_seconds)) } else { None };
    enter_task(TaskContext { cancel: cancel.clone(), deadline, sockets, owner });
    let receipt = {
        let tasks = inner.tasks.lock().expect("subagents tasks");
        tasks.get(&id).map(|task| {
            let mut spec = task.spec.clone();
            if !spec.is_object() {
                spec = json!({});
            }
            spec["subagent_id"] = json!(task.id);
            spec["session_id"] = json!(task.session_id);
            spec["state"] = json!("running");
            spec
        })
    };
    let outcome = match receipt {
        Some(receipt) => runner(&receipt.to_string()),
        None => Err("unknown_subagent".into()),
    };
    leave_task();
    match outcome {
        Ok(value) => {
            let state = value["state"].as_str().unwrap_or("completed").to_string();
            let result = value.get("result").cloned().unwrap_or(Value::Null);
            let error = value["error"].as_str().map(str::to_string);
            settle_view(&inner, &id, &state, result, error);
        }
        Err(error) => settle_view(&inner, &id, "failed", Value::Null, Some(error)),
    }
    release(&inner);
}

fn acquire(inner: &Arc<Inner>, cancel: &Arc<AtomicBool>) -> bool {
    let max = inner.max_concurrent;
    let mut running = inner.running.lock().expect("subagent running");
    loop {
        if *running < max {
            *running += 1;
            return true;
        }
        if cancel.load(Ordering::SeqCst) {
            return false;
        }
        let (guard, _) = inner
            .capacity
            .wait_timeout(running, Duration::from_millis(50))
            .expect("subagent capacity");
        running = guard;
    }
}

fn release(inner: &Arc<Inner>) {
    let mut running = inner.running.lock().expect("subagent running");
    *running = running.saturating_sub(1);
    inner.capacity.notify_all();
}

fn settle_view(inner: &Arc<Inner>, id: &str, state: &str, result: Value, error: Option<String>) {
    let mut tasks = inner.tasks.lock().expect("subagents tasks");
    let Some(task) = tasks.get_mut(id) else { return };
    if task.settled {
        return;
    }
    let cancelled = task.cancel.load(Ordering::SeqCst);
    // A cancel request wins the terminal label: the child may have failed with a
    // provider error caused by the cancellation, and reporting that as `failed`
    // would blame the provider for a decision the caller made.
    task.state = if cancelled { "cancelled".to_string() } else { state.to_string() };
    task.settled = true;
    task.result = result;
    task.error = error;
    task.settled_at = Some(now_secs());
    let view = task.view(true);
    // A terminal record that cannot be written is not success. Say `unknown` with
    // a persistence error rather than let a caller read a settlement the disk does
    // not have; the log carries the cause.
    if let Err(error) = persist_view(&inner.root, &view) {
        eprintln!("[subagents] could not record settlement for {id}: {error}");
        task.state = "unknown".into();
        task.error = Some(format!("persistence_error: {error}"));
        task.result = Value::Null;
    }
    drop(tasks);
    inner.changed.notify_all();
}

/// Register the fresh-interpreter runner. Called once by `main.rs`; an
/// unregistered runtime refuses `start` rather than silently doing nothing.
pub fn set_factory(factory: Box<dyn Fn() -> crate::lua::Lua + Send + Sync>) {
    let factory = Arc::new(factory);
    let runner: Runner = Arc::new(move |receipt: &str| {
        let lua = factory();
        // The runner owns the thread-local context: the manager's cancel flag and
        // deadline must be visible to every provider call this interpreter makes.
        match lua.call_string("wa_subagent_run", &[receipt]) {
            Ok(text) => {
                let value: Value = serde_json::from_str(&text)
                    .map_err(|error| format!("subagent_result_not_json: {error}"))?;
                Ok(value)
            }
            Err(error) => Err(error),
        }
    });
    let _ = manager().runner.set(runner);
}

/// The host interface. `action` is one of the public verbs; `args` carries the
/// caller-derived owner, never an owner the model supplied.
pub fn control(action: &str, args: &Value) -> Result<Value, String> {
    let manager = manager();
    match action {
        "start" => manager.start(args),
        "status" | "result" => {
            let id = args["id"].as_str().unwrap_or_default();
            let owner = args["owner_user"].as_str().unwrap_or_default();
            manager.find(id, owner)
        }
        "list" => {
            let owner = args["owner_user"].as_str().unwrap_or_default();
            Ok(manager.list(owner))
        }
        "await" => {
            let id = args["id"].as_str().unwrap_or_default();
            let owner = args["owner_user"].as_str().unwrap_or_default();
            let wait = args["wait_ms"].as_u64().unwrap_or(60_000);
            manager.await_task(id, owner, wait)
        }
        "cancel" => {
            let id = args["id"].as_str().unwrap_or_default();
            let owner = args["owner_user"].as_str().unwrap_or_default();
            manager.cancel(id, owner)
        }
        "resolve" => {
            let owner = args["owner_user"].as_str().unwrap_or_default();
            let key = args["idempotency_key"].as_str().unwrap_or_default();
            Ok(manager.resolve(owner, key))
        }
        // The child asks whether it has been cancelled or has run out of time.
        "self" => {
            let cancel = cancel_requested();
            let expired = remaining_budget().map(|remaining| remaining.is_zero()).unwrap_or(false);
            Ok(json!({ "cancelled": cancel || expired, "cancel_requested": cancel, "deadline_exceeded": expired }))
        }
        _ => Err("unknown_subagent_action".into()),
    }
}

/// Public runtime summary for `/health`, without transcripts or prompts.
/// Public runtime summary for `/health`, with one strict shape so every reader
/// and every worker's summary agree: `{queued, running, active}`, where `active`
/// is `queued + running`. `settled` is the optional retained count.
pub fn health() -> Value {
    manager().summary()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    fn temp_root(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("wa-subagent-test-{tag}-{}", now_ms()));
        let _ = std::fs::remove_dir_all(&root);
        root
    }

    fn spec(id: &str, owner: &str, key: &str) -> Value {
        json!({
            "id": id,
            "owner_user": owner,
            "session_id": format!("sess-{id}"),
            "profile": "explore",
            "parent_session_id": "parent",
            "parent_run_id": "run",
            "depth": 1,
            "timeout_seconds": 30,
            "idempotency_key": key,
        })
    }

    #[test]
    fn receipt_is_durable_and_settles_with_the_runner_result() {
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        let started = Arc::new(AtomicUsize::new(0));
        let manager = Manager::with_root(temp_root("durable"), 2, 6);
        let _ = manager.runner.set({
            let gate = gate.clone();
            let started = started.clone();
            Arc::new(move |_receipt: &str| {
                started.fetch_add(1, Ordering::SeqCst);
                let (lock, cond) = &*gate;
                let mut open = lock.lock().unwrap();
                while !*open {
                    open = cond.wait(open).unwrap();
                }
                Ok(json!({"state": "completed", "result": {"reply": "child done"}}))
            })
        });
        let id = "durable-child";
        let receipt = manager.start(&spec(id, "alice", "")).expect("start");
        assert_eq!(receipt["state"], "accepted");
        assert_eq!(receipt["settled"], false);
        let deadline = Instant::now() + Duration::from_secs(5);
        while started.load(Ordering::SeqCst) == 0 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(manager.find(id, "alice").expect("status")["state"], "running");
        {
            let (lock, cond) = &*gate;
            *lock.lock().unwrap() = true;
            cond.notify_all();
        }
        let settled = manager.await_task(id, "alice", 5_000).expect("await");
        assert_eq!(settled["state"], "completed");
        assert_eq!(settled["result"]["reply"], "child done");
        let record = std::fs::read_to_string(manager.inner.root.join(format!("{id}/record.json"))).expect("record");
        assert!(record.contains("child done"));
        assert!(record.contains("\"state\":\"completed\""), "the durable record must advance to completed: {record}");
        assert!(record.contains("\"spec\""), "the durable record must keep the resolved spec for a restart");
    }

    #[test]
    fn idempotency_returns_the_existing_child_without_a_second_run() {
        let calls = Arc::new(AtomicUsize::new(0));
        let manager = Manager::with_root(temp_root("idem"), 2, 6);
        let _ = manager.runner.set({
            let calls = calls.clone();
            Arc::new(move |_receipt: &str| {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok(json!({"state": "completed", "result": {"reply": "once"}}))
            })
        });
        let first = manager.start(&spec("idem-child-1", "bob", "delivery-7")).expect("first");
        let second = manager.start(&spec("idem-child-2", "bob", "delivery-7")).expect("second");
        assert_eq!(second["deduplicated"], true);
        assert_eq!(second["subagent_id"], first["subagent_id"]);
        // Different owner with the same key is a different task, not a dedupe.
        let other = manager.start(&spec("idem-child-3", "carol", "delivery-7")).expect("other owner");
        assert_eq!(other["deduplicated"], Value::Null);
        // And `resolve` collects it without starting anything new.
        let resolved = manager.resolve("bob", "delivery-7");
        assert_eq!(resolved["subagent_id"], first["subagent_id"]);
    }

    #[test]
    fn owner_scoping_refuses_another_users_task() {
        let manager = Manager::with_root(temp_root("owner"), 2, 6);
        let _ = manager.runner.set(Arc::new(|_receipt: &str| Ok(json!({"state": "completed", "result": {}}))));
        manager.start(&spec("owner-child", "dave", "")).expect("start");
        assert_eq!(manager.find("owner-child", "erin").unwrap_err(), "forbidden_subagent");
        assert_eq!(manager.cancel("owner-child", "erin").unwrap_err(), "forbidden_subagent");
        assert_eq!(manager.await_task("owner-child", "erin", 10).unwrap_err(), "forbidden_subagent");
    }

    #[test]
    fn capacity_is_bounded_and_overflow_is_explicit() {
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        let manager = Manager::with_root(temp_root("capacity"), 1, 2);
        let _ = manager.runner.set({
            let gate = gate.clone();
            Arc::new(move |_receipt: &str| {
                let (lock, cond) = &*gate;
                let mut open = lock.lock().unwrap();
                while !*open {
                    open = cond.wait(open).unwrap();
                }
                Ok(json!({"state": "completed", "result": {}}))
            })
        });
        let mut admitted = 0;
        let mut overflow = false;
        for index in 0..(manager.max_live + 2) {
            match manager.start(&spec(&format!("cap-child-{index}"), "frank", "")) {
                Ok(_) => admitted += 1,
                Err(error) => {
                    assert_eq!(error, "queue_full");
                    overflow = true;
                    break;
                }
            }
        }
        assert!(overflow, "an over-capacity start must be refused, not lost");
        assert!(admitted <= manager.max_live);
        {
            let (lock, cond) = &*gate;
            *lock.lock().unwrap() = true;
            cond.notify_all();
        }
    }

    #[test]
    fn a_record_left_running_by_another_boot_reads_unknown() {
        let root = temp_root("unknown");
        let directory = root.join("stale-child");
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(
            directory.join("record.json"),
            json!({
                "id": "stale-child", "owner_user": "grace", "session_id": "s", "profile": "explore",
                "state": "running", "settled": false, "boot": "another-boot", "created_at": 1.0
            })
            .to_string(),
        )
        .unwrap();
        // Recovery must mark a record from a foreign boot unknown, not replay it.
        let manager = Manager::with_root(root, 2, 6);
        manager.recover();
        let view = manager.find("stale-child", "grace").expect("status");
        assert_eq!(view["state"], "unknown");
        assert_eq!(view["settled"], true);
    }

    #[test]
    fn a_cancel_wins_the_terminal_label() {
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        let manager = Manager::with_root(temp_root("cancel"), 2, 6);
        let _ = manager.runner.set({
            let gate = gate.clone();
            Arc::new(move |_receipt: &str| {
                let (lock, cond) = &*gate;
                let mut open = lock.lock().unwrap();
                while !*open {
                    open = cond.wait(open).unwrap();
                }
                // The child reports failure because its provider read was cancelled.
                Err("subagent_cancelled".into())
            })
        });
        manager.start(&spec("cancel-child", "heidi", "")).expect("start");
        let deadline = Instant::now() + Duration::from_secs(5);
        while manager.find("cancel-child", "heidi").unwrap()["state"] == "accepted" && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        let before = manager.cancel("cancel-child", "heidi").expect("cancel");
        assert_eq!(before["state"], "running");
        {
            let (lock, cond) = &*gate;
            *lock.lock().unwrap() = true;
            cond.notify_all();
        }
        let settled = manager.await_task("cancel-child", "heidi", 5_000).expect("await");
        assert_eq!(settled["state"], "cancelled");
    }

    #[test]
    fn a_record_write_failure_is_reported_not_swallowed() {
        // The durable record is the supervisor's evidence. A file where the task
        // directory must be makes `create_dir_all` fail, and the start must report
        // that rather than hand back a receipt for a child that is not durable.
        let root = temp_root("record-fail");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("blocked"), b"not a directory").unwrap();
        let manager = Manager::with_root(root, 2, 6);
        let _ = manager.runner.set(Arc::new(|_receipt: &str| Ok(json!({"state": "completed"}))));
        let error = manager.start(&spec("blocked", "ivy", "")).unwrap_err();
        assert!(error.starts_with("record_write_failed"), "got {error}");
    }

    #[test]
    fn a_record_rename_failure_is_reported_not_swallowed() {
        // A directory where record.json must be makes the atomic rename fail after
        // a successful temp write; the start must report it.
        let root = temp_root("rename-fail");
        std::fs::create_dir_all(root.join("rename-blocked/record.json")).unwrap();
        let manager = Manager::with_root(root, 2, 6);
        let _ = manager.runner.set(Arc::new(|_receipt: &str| Ok(json!({"state": "completed"}))));
        let error = manager.start(&spec("rename-blocked", "ivy", "")).unwrap_err();
        assert!(error.starts_with("record_write_failed"), "got {error}");
    }

    #[test]
    fn an_id_that_could_traverse_the_root_is_refused() {
        let manager = Manager::with_root(temp_root("id-guard"), 2, 6);
        let _ = manager.runner.set(Arc::new(|_receipt: &str| Ok(json!({"state": "completed"}))));
        assert_eq!(manager.start(&spec("../escape", "jane", "")).unwrap_err(), "invalid_id");
        assert_eq!(manager.start(&spec("a/b", "jane", "")).unwrap_err(), "invalid_id");
    }

    #[test]
    fn simultaneous_same_key_starts_create_one_child() {
        let calls = Arc::new(AtomicUsize::new(0));
        let manager = Arc::new(Manager::with_root(temp_root("race"), 4, 8));
        let _ = manager.runner.set({
            let calls = calls.clone();
            Arc::new(move |_receipt: &str| {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok(json!({"state": "completed", "result": {}}))
            })
        });
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let mut handles = Vec::new();
        for index in 0..2 {
            let manager = manager.clone();
            let barrier = barrier.clone();
            handles.push(std::thread::spawn(move || {
                barrier.wait();
                manager.start(&spec(&format!("race-{index}"), "mia", "same-key"))
            }));
        }
        let results: Vec<_> = handles.into_iter().map(|handle| handle.join().unwrap()).collect();
        let ids: std::collections::HashSet<String> = results
            .iter()
            .filter_map(|result| result.as_ref().ok().and_then(|value| value["subagent_id"].as_str().map(str::to_string)))
            .collect();
        assert_eq!(ids.len(), 1, "both starts must resolve to one child: {results:?}");
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(calls.load(Ordering::SeqCst), 1, "one child, one inference");
    }

    #[test]
    fn a_corrupt_record_blocks_admission_and_replay() {
        let root = temp_root("corrupt");
        let directory = root.join("corrupt-child");
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join("record.json"), b"{not json").unwrap();
        let manager = Manager::with_root(root, 2, 6);
        let calls = Arc::new(AtomicUsize::new(0));
        let _ = manager.runner.set({
            let calls = calls.clone();
            Arc::new(move |_receipt: &str| {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok(json!({"state": "completed"}))
            })
        });
        manager.recover();
        // The corrupt record may have carried the idempotency key, so new
        // admission is refused rather than risk a replay, and no inference runs.
        let error = manager.start(&spec("new-child", "nina", "key-x")).unwrap_err();
        assert!(error.starts_with("recovery_error"), "got {error}");
        assert_eq!(calls.load(Ordering::SeqCst), 0, "no inference while recovery is unresolved");
        assert!(manager.summary()["recovery_error"].is_string(), "health must show the fault");
    }

    #[test]
    fn health_shape_is_strict_and_a_cancelling_task_stays_active() {
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        let manager = Manager::with_root(temp_root("health"), 1, 2);
        let _ = manager.runner.set({
            let gate = gate.clone();
            Arc::new(move |_receipt: &str| {
                let (lock, cond) = &*gate;
                let mut open = lock.lock().unwrap();
                while !*open {
                    open = cond.wait(open).unwrap();
                }
                Ok(json!({"state": "completed", "result": {}}))
            })
        });
        manager.start(&spec("health-1", "kate", "")).expect("start");
        manager.start(&spec("health-2", "kate", "")).expect("queued start");
        let deadline = Instant::now() + Duration::from_secs(3);
        while manager.find("health-1", "kate").unwrap()["state"] != "running" && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        let before = manager.summary();
        assert_eq!(before["running"], 1);
        assert_eq!(before["queued"], 1);
        assert_eq!(before["active"], 2);
        // A requested cancellation is not a settlement: the task is active until
        // the execution actually stops.
        manager.cancel("health-1", "kate").expect("cancel");
        let during = manager.summary();
        assert_eq!(during["active"], 2, "a cancelling task is still active: {during}");
        {
            let (lock, cond) = &*gate;
            *lock.lock().unwrap() = true;
            cond.notify_all();
        }
        manager.await_task("health-1", "kate", 3_000).expect("await");
    }

    #[test]
    fn a_socket_shutdown_wakes_a_blocked_slot() {
        // The cancel path must reach a socket the task is blocked on; this proves
        // the shared slot is what `shutdown_sockets` empties, without a network.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("listener");
        let address = listener.local_addr().expect("addr");
        let mut client = std::net::TcpStream::connect(address).expect("connect");
        let slot: SocketSlot = Arc::new(Mutex::new(vec![client.try_clone().expect("clone")]));
        shutdown_sockets(&slot);
        use std::io::Read;
        let mut buffer = [0u8; 1];
        let result = client.read(&mut buffer);
        assert!(result.is_err() || result.unwrap() == 0, "a shut-down read must not block");
    }
}
