//! An operation owns execution, output, cancellation and settlement. A job is an automation rule,
//! not a process. See docs/OPERATIONS.md. No model, Lua state, HTTP or UI is needed to supervise it.
mod process;
mod redact;
use process::Process;
use redact::Redactor;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs::{self, File},
    io::{self, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Condvar, Mutex,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const CLEANUP_MS: u64 = 1000;
pub const COMMAND_OUTPUT_IDLE_MS: u64 = 100;
const VIEW_BYTES: usize = 24 * 1024;
const MAX_ACTIVE: usize = 8;
static SEQUENCE: AtomicU64 = AtomicU64::new(0);
#[derive(Clone)]
pub struct Spec {
    pub program: String,
    pub args: Vec<String>,
    pub cwd: String,
    pub env: Vec<(String, String)>,
    pub timeout: Duration,
    pub output_limit: usize,
    pub owner: String,
    /// When a foreground shell exits leaving live descendants, adopt them as a running
    /// operation instead of failing. Off by default: a deliberately started operation is
    /// already background, and only the `bash` tool wants this.
    pub promote_descendants: bool,
}
impl Spec {
    pub fn command(program: impl Into<String>, args: Vec<String>) -> Self {
        Self {
            program: program.into(),
            args,
            cwd: String::new(),
            env: vec![],
            timeout: Duration::from_secs(300),
            output_limit: 8 * 1024 * 1024,
            owner: String::new(),
            promote_descendants: false,
        }
    }
}
struct Entry {
    cancel: AtomicBool,
    state: Mutex<Value>,
    settled: Condvar,
    started: Instant,
    /// Milliseconds. Mutable because adopting a descendant tree extends the deadline,
    /// and `snapshot` must read it without taking the state lock.
    deadline_ms: AtomicU64,
}
#[derive(Clone)]
pub struct Manager {
    root: PathBuf,
    entries: Arc<Mutex<HashMap<String, Arc<Entry>>>>,
    /// The node's own secret values, redacted from every operation's output before it is
    /// written or returned. Empty unless a caller opts in with `with_env_secrets`.
    secrets: Arc<Vec<Vec<u8>>>,
}
fn error(message: impl ToString) -> io::Error {
    io::Error::other(message.to_string())
}
const TIMING_PHASES: [&str; 6] = [
    "setup_ms",
    "accepted_record_ms",
    "spawn_ms",
    "execution_ms",
    "drain_cleanup_ms",
    "output_sync_ms",
];
fn timing_payload() -> Value {
    json!({"schema_version":1,"clock":"monotonic","complete":false,
        "setup_ms":null,"accepted_record_ms":null,"spawn_ms":null,"execution_ms":null,
        "drain_cleanup_ms":null,"output_sync_ms":null,"measured_ms":0,"unattributed_ms":0,
        "total_ms":0,"final_state_record_excluded":true})
}
fn phase(entry: &Entry, name: &str, elapsed: Duration) {
    entry.state.lock().unwrap()["timing"][name] = json!(elapsed.as_millis() as u64);
}
fn finish_timing(state: &mut Value, total_ms: u64) {
    let measured = TIMING_PHASES
        .iter()
        .filter_map(|name| state["timing"][name].as_u64())
        .fold(0u64, u64::saturating_add);
    let complete = TIMING_PHASES
        .iter()
        .all(|name| state["timing"][name].as_u64().is_some())
        && measured <= total_ms;
    state["timing"]["complete"] = json!(complete);
    state["timing"]["measured_ms"] = json!(measured);
    state["timing"]["unattributed_ms"] = json!(total_ms.saturating_sub(measured));
    state["timing"]["total_ms"] = json!(total_ms);
}
pub fn atomic_json(path: &Path, value: &Value) -> io::Result<()> {
    let temporary = path.with_extension(format!(
        "{}.{}.tmp",
        std::process::id(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    file.write_all(serde_json::to_string(value)?.as_bytes())?;
    file.sync_all()?;
    drop(file);
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::{
            MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
        };
        let from: Vec<u16> = temporary.as_os_str().encode_wide().chain(Some(0)).collect();
        let to: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        if unsafe {
            MoveFileExW(
                from.as_ptr(),
                to.as_ptr(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        } == 0
        {
            let e = io::Error::last_os_error();
            let _ = fs::remove_file(temporary);
            return Err(e);
        }
    }
    #[cfg(not(windows))]
    {
        fs::rename(&temporary, path)?;
        File::open(path.parent().unwrap())?.sync_all()?;
    }
    Ok(())
}
impl Manager {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            entries: Arc::new(Mutex::new(HashMap::new())),
            secrets: Arc::new(Vec::new()),
        }
    }
    /// Redact the node's own secret values from every operation's output. The values come
    /// from the process environment, which the host resolved from the config file, so this
    /// sees the same names `lua/core/redact.lua` redacts at the transcript boundary.
    pub fn with_env_secrets(mut self) -> Self {
        self.secrets = Arc::new(redact::env_secrets());
        self
    }
    /// An explicit secret list, for tests and callers that resolve their own values.
    pub fn with_secrets(mut self, secrets: Vec<String>) -> Self {
        self.secrets = Arc::new(secrets.into_iter().map(String::into_bytes).collect());
        self
    }
    pub fn start(&self, spec: Spec) -> io::Result<String> {
        if spec.timeout.is_zero()
            || spec.timeout > Duration::from_secs(86400)
            || spec.output_limit == 0
            || spec.output_limit > 64 * 1024 * 1024
        {
            return Err(error("invalid_operation_budget"));
        }
        let mut entries = self.entries.lock().map_err(error)?;
        if entries
            .values()
            .filter(|v| {
                !v.state.lock().unwrap()["settled"]
                    .as_bool()
                    .unwrap_or(false)
            })
            .count()
            >= MAX_ACTIVE
        {
            return Err(error("operation_capacity"));
        }
        if entries.len() >= 128 {
            entries.retain(|_, v| {
                !v.state.lock().unwrap()["settled"]
                    .as_bool()
                    .unwrap_or(false)
            });
        }
        let id = format!(
            "op-{}-{}-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_micros(),
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        );
        let dir = self.root.join(&id);
        let state = json!({"operation_id":id,"owner":spec.owner,"state":"accepted","settled":false,"timeout_ms":spec.timeout.as_millis() as u64,"cleanup_budget_ms":CLEANUP_MS,"containment":Process::containment(),"stdout_path":dir.join("stdout").to_string_lossy(),"stderr_path":dir.join("stderr").to_string_lossy(),"output_bytes":0,"timing":timing_payload()});
        let entry = Arc::new(Entry {
            cancel: AtomicBool::new(false),
            state: Mutex::new(state),
            settled: Condvar::new(),
            started: Instant::now(),
            deadline_ms: AtomicU64::new(spec.timeout.as_millis() as u64),
        });
        entries.insert(id.clone(), entry.clone());
        drop(entries);
        let secrets = self.secrets.clone();
        let result = std::thread::Builder::new()
            .name("operation".into())
            .spawn(move || {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    // Persist admission before any external effect, but never hold the control
                    // registry/state mutex across filesystem I/O.
                    fs::create_dir_all(&dir)?;
                    let accepted = entry.state.lock().unwrap().clone();
                    let accepted_record_started = Instant::now();
                    atomic_json(&dir.join("state.json"), &accepted)?;
                    phase(
                        &entry,
                        "accepted_record_ms",
                        accepted_record_started.elapsed(),
                    );
                    if entry.cancel.load(Ordering::Acquire) {
                        return Err(error("cancelled"));
                    }
                    if entry.started.elapsed() >= spec.timeout {
                        return Err(error("deadline_exceeded"));
                    }
                    execute(&spec, &dir, &entry, &secrets)
                }));
                let failure = match outcome {
                    Ok(Ok(())) => None,
                    Ok(Err(e)) => Some(e.to_string()),
                    Err(_) => Some("operation_supervisor_panicked".into()),
                };
                if let Some(reason) = failure {
                    let mut s = entry
                        .state
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .clone();
                    s["state"] = json!(if reason == "cancelled" {
                        "cancelled"
                    } else {
                        "failed"
                    });
                    s["settled"] = json!(true);
                    s["ok"] = json!(false);
                    s["error"] = json!(reason);
                    s["cleanup"] = json!("unknown");
                    s["output_complete"] = json!(false);
                    let total_ms = entry.started.elapsed().as_millis() as u64;
                    s["elapsed_ms"] = json!(total_ms);
                    finish_timing(&mut s, total_ms);
                    if let Err(e) = atomic_json(&dir.join("state.json"), &s) {
                        s["persistence_error"] = json!(e.to_string());
                    }
                    *entry.state.lock().unwrap_or_else(|e| e.into_inner()) = s;
                    entry.settled.notify_all();
                }
            });
        if let Err(e) = result {
            self.entries.lock().unwrap().remove(&id);
            return Err(e);
        }
        Ok(id)
    }
    pub fn snapshot(&self, id: &str) -> io::Result<Value> {
        validate_id(id)?;
        if let Some(entry) = self.entries.lock().map_err(error)?.get(id).cloned() {
            let mut state = entry.state.lock().map_err(error)?.clone();
            let elapsed = entry.started.elapsed();
            if state["settled"] != true {
                state["elapsed_ms"] = json!(elapsed.as_millis() as u64);
                state["remaining_ms"] = json!(entry
                    .deadline_ms
                    .load(Ordering::Acquire)
                    .saturating_sub(elapsed.as_millis() as u64));
                state["shell_exited"] = json!(state["process_exit_code"].is_number());
                state["waiting_for"] = json!(if state["state"] == "draining" {
                    "output_and_cleanup"
                } else if state["promoted"] == true {
                    "descendants"
                } else {
                    "command"
                });
                if let Some(process_exit) = state["process_exit_elapsed_ms"].as_u64() {
                    let last = state["post_exit_last_output_elapsed_ms"]
                        .as_u64()
                        .unwrap_or(process_exit);
                    state["output_idle_ms"] =
                        json!((elapsed.as_millis() as u64).saturating_sub(last));
                }
            }
            state["overdue"] = json!(
                !state["settled"].as_bool().unwrap_or(false)
                    && elapsed
                        > Duration::from_millis(entry.deadline_ms.load(Ordering::Acquire))
                            + Duration::from_millis(CLEANUP_MS)
            );
            return Ok(state);
        }
        let mut state: Value =
            serde_json::from_slice(&fs::read(self.root.join(id).join("state.json"))?)?;
        if state["settled"] != true {
            state["state"] = json!("outcome_unknown");
            state["settled"] = json!(true);
            state["ok"] = json!(false);
            state["error"] =
                json!("operation_owner_not_attached; it may still be active elsewhere; reconcile effects, never replay blindly");
            state["cleanup"] = json!("unknown");
        }
        Ok(state)
    }
    pub fn list(&self) -> Value {
        let ids: Vec<String> = self.entries.lock().unwrap().keys().cloned().collect();
        json!(ids
            .iter()
            .filter_map(|id| self.snapshot(id).ok())
            .map(|mut state| {
                if let Some(fields) = state.as_object_mut() {
                    fields.remove("stdout");
                    fields.remove("stderr");
                }
                state
            })
            .collect::<Vec<_>>())
    }
    pub fn cancel(&self, id: &str) -> io::Result<Value> {
        validate_id(id)?;
        if let Some(entry) = self.entries.lock().map_err(error)?.get(id) {
            entry.cancel.store(true, Ordering::Release);
        }
        self.snapshot(id)
    }
    pub fn read(&self, id: &str, stream: &str, offset: u64, limit: usize) -> io::Result<Value> {
        validate_id(id)?;
        if stream != "stdout" && stream != "stderr" {
            return Err(error("invalid_operation_stream"));
        }
        let mut file = File::open(self.root.join(id).join(stream))?;
        file.seek(SeekFrom::Start(offset))?;
        let mut data = vec![0; limit.clamp(1, VIEW_BYTES)];
        let n = file.read(&mut data)?;
        data.truncate(n);
        let content = String::from_utf8_lossy(&data);
        let text_lossy = matches!(content, std::borrow::Cow::Owned(_));
        let mut page = json!({"operation_id":id,"stream":stream,"offset":offset,"next_offset":offset+n as u64,
            "content":content,"text_lossy":text_lossy,"available_bytes":file.metadata()?.len()});
        // Byte cursors can bisect UTF-8, and process output can be binary. Preserve
        // the compatible text view, but never present replacement characters as exact bytes.
        if text_lossy {
            use base64::Engine;
            page["content_base64"] = json!(base64::engine::general_purpose::STANDARD.encode(&data));
        }
        Ok(page)
    }
    pub fn wait(&self, id: &str, budget: Duration) -> io::Result<Value> {
        validate_id(id)?;
        let entry = self.entries.lock().map_err(error)?.get(id).cloned();
        if let Some(entry) = entry {
            let state = entry.state.lock().map_err(error)?;
            let (state, _) = entry
                .settled
                .wait_timeout_while(state, budget, |s| s["settled"] != true)
                .map_err(error)?;
            drop(state);
        }
        self.snapshot(id)
    }
}
fn validate_id(id: &str) -> io::Result<()> {
    if !id.starts_with("op-")
        || id.len() > 100
        || id.bytes().any(|c| !c.is_ascii_alphanumeric() && c != b'-')
    {
        Err(error("invalid_operation_id"))
    } else {
        Ok(())
    }
}
fn tail(buffer: &mut Vec<u8>, data: &[u8]) {
    buffer.extend_from_slice(data);
    if buffer.len() > VIEW_BYTES {
        buffer.drain(..buffer.len() - VIEW_BYTES);
    }
}
fn execute(spec: &Spec, dir: &Path, entry: &Entry, secrets: &[Vec<u8>]) -> io::Result<()> {
    let mut files = [
        File::create(dir.join("stdout"))?,
        File::create(dir.join("stderr"))?,
    ];
    // One redactor per stream: the carry buffer is per-stream state.
    let mut redactors = [Redactor::new(secrets), Redactor::new(secrets)];
    let accepted_record_ms = entry.state.lock().unwrap()["timing"]["accepted_record_ms"]
        .as_u64()
        .unwrap_or(0);
    let setup_total = entry.started.elapsed();
    phase(
        entry,
        "setup_ms",
        setup_total.saturating_sub(Duration::from_millis(accepted_record_ms)),
    );
    let spawn_started = Instant::now();
    let process_result = Process::spawn(spec);
    phase(entry, "spawn_ms", spawn_started.elapsed());
    let mut process = process_result?;
    let execution_started = Instant::now();
    entry.state.lock().unwrap()["state"] = json!("running");
    let mut views = [Vec::new(), Vec::new()];
    let mut eof = [false, false];
    let mut bytes = 0usize;
    let mut code = None;
    let mut reason = None;
    let mut cleanup = None;
    let mut stopped = None;
    let mut drain_started = None;
    let mut parent_exit = None;
    // Set once when a foreground shell's descendants are adopted rather than failed.
    let mut promoted = false;
    let mut execution_recorded = false;
    let mut buffer = [0u8; 8192];
    loop {
        // Bounded work per iteration: a noisy child cannot starve cancellation or its deadline.
        for index in 0..2 {
            for _ in 0..8 {
                if eof[index] {
                    break;
                }
                match process.read(index == 1, &mut buffer) {
                    Ok(Some(0)) => {
                        // End of stream: flush what was held back for a possible split secret.
                        let flushed = redactors[index].finish();
                        if !flushed.is_empty() {
                            files[index].write_all(&flushed)?;
                            tail(&mut views[index], &flushed);
                        }
                        eof[index] = true;
                        break;
                    }
                    Ok(Some(n)) => {
                        let keep = n.min(spec.output_limit.saturating_sub(bytes));
                        // Redact before the write: the file and the in-memory view hold no
                        // secret, and there is no raw window on disk at all.
                        let clean = redactors[index].push(&buffer[..keep]);
                        files[index].write_all(&clean)?;
                        tail(&mut views[index], &clean);
                        bytes += keep;
                        let output_at = entry.started.elapsed().as_millis() as u64;
                        let mut state = entry.state.lock().unwrap();
                        state["last_output_elapsed_ms"] = json!(output_at);
                        if code.is_some() {
                            state["post_exit_last_output_elapsed_ms"] = json!(output_at);
                        }
                        if keep < n {
                            reason.get_or_insert("output_limit_exceeded".to_string());
                            break;
                        }
                    }
                    Ok(None) => break,
                    Err(e) => {
                        reason.get_or_insert(format!("output_read_failed:{e}"));
                        eof[index] = true;
                        break;
                    }
                }
            }
        }
        if code.is_none() {
            code = process.code()?;
            if code.is_some() {
                parent_exit = Some(Instant::now());
                let mut state = entry.state.lock().unwrap();
                state["process_exit_elapsed_ms"] =
                    json!(entry.started.elapsed().as_millis() as u64);
            }
        }
        if stopped.is_none() {
            if entry.cancel.load(Ordering::Acquire) {
                reason.get_or_insert("cancelled".into());
            }
            if entry.started.elapsed()
                >= Duration::from_millis(entry.deadline_ms.load(Ordering::Acquire))
            {
                reason.get_or_insert("deadline_exceeded".into());
            }
            if code.is_some() && reason.is_none() {
                process.cleanup_auxiliaries()?;
            }
            // Launchers (notably Git's bin/bash.exe) may signal before their real shell finishes
            // closing stdio. One shared 50ms drain allowance, inside the absolute deadline, not per pipe.
            let descendants = code.is_some() && process.descendants()?;
            let exited = code.is_some()
                && ((!descendants && eof.iter().all(|v| *v))
                    || parent_exit.unwrap().elapsed() >= Duration::from_millis(50));
            if promoted && stopped.is_none() && reason.is_none() {
                // Do not restart the completion path on every supervisor poll. The command
                // has already exited; only output, descendants, cancellation and its original
                // deadline remain relevant.
                if eof.iter().all(|v| *v) && !process.descendants()? {
                    cleanup = Some("self_exited");
                    stopped = Some(Instant::now());
                    entry.state.lock().unwrap()["state"] = json!("draining");
                }
            } else if exited || reason.is_some() {
                if !execution_recorded {
                    phase(entry, "execution_ms", execution_started.elapsed());
                    execution_recorded = true;
                }
                if drain_started.is_none() {
                    drain_started = Some(Instant::now());
                }
                // A shell that exits leaving live descendants is normally a failure: the result
                // would no longer be the whole story of what the command did. When the caller
                // asked to promote instead, the descendants are *adopted* - the job object still
                // owns them, so they cannot outlive this node, and the operation stays running
                // under a longer deadline. The caller gets a receipt that names the process
                // instead of a result that hides it.
                if descendants && spec.promote_descendants && reason.is_none() {
                    if !promoted {
                        promoted = true;
                        let mut state = entry.state.lock().unwrap();
                        state["promoted"] = json!(true);
                        state["state"] = json!("running");
                        state["command_completed"] = json!(true);
                    }
                } else if promoted && reason.is_none() {
                    // The adopted tree ended on its own. Nothing was terminated, so do not
                    // report a cleanup that did not happen.
                    cleanup = Some("self_exited");
                    stopped = Some(Instant::now());
                    entry.state.lock().unwrap()["state"] = json!("draining");
                } else {
                    if descendants {
                        reason.get_or_insert("background_descendants: use an explicit operation and keep its shell waiting".into());
                    }
                    cleanup = Some(match process.terminate() {
                        Ok(()) => "terminated",
                        Err(e) => {
                            reason.get_or_insert(format!("cleanup_failed:{e}"));
                            "unknown"
                        }
                    });
                    stopped = Some(Instant::now());
                    entry.state.lock().unwrap()["state"] = json!("draining");
                }
            }
        }
        // An adopted tree settles when it is finally gone: every pipe closed and nothing
        // left in the job. Until then the operation is genuinely still running.
        if promoted && stopped.is_none() && eof.iter().all(|v| *v) && !process.descendants()? {
            break;
        }
        {
            let mut state = entry.state.lock().unwrap();
            state["output_bytes"] = json!(bytes);
            state["process_exit_code"] = json!(code);
            state["output_streams_closed"] = json!(eof.iter().all(|v| *v));
        }
        if let Some(at) = stopped {
            // Windows can observe its contained tree. POSIX groups only prove signal delivery;
            // zombies/escaped groups need stronger platform containment (see OPERATIONS.md).
            let tree_done = !cfg!(windows) || !process.descendants()?;
            if eof.iter().all(|v| *v) && code.is_some() && tree_done {
                break;
            }
            if at.elapsed() >= Duration::from_millis(CLEANUP_MS) {
                reason.get_or_insert("cleanup_incomplete".into());
                cleanup = Some("unknown");
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    // Flush whatever a stream still held back for a possible split secret. A stream that did
    // not reach EOF - cancelled, deadline, or the drain allowance - still gets its tail
    // written, and end of stream means no match can extend further. `finish` is idempotent,
    // so a stream already flushed at EOF contributes nothing here.
    for (index, redactor) in redactors.iter_mut().enumerate() {
        let flushed = redactor.finish();
        if !flushed.is_empty() {
            files[index].write_all(&flushed)?;
            tail(&mut views[index], &flushed);
            bytes += flushed.len();
        }
    }
    if let Some(started) = drain_started {
        phase(entry, "drain_cleanup_ms", started.elapsed());
    }
    let sync_started = Instant::now();
    for file in &mut files {
        file.sync_all()?;
    }
    phase(entry, "output_sync_ms", sync_started.elapsed());
    let complete = eof.iter().all(|v| *v)
        && !reason
            .as_ref()
            .is_some_and(|s| s.starts_with("output_") || s == "cleanup_incomplete");
    let ok = reason.is_none() && code == Some(0) && complete;
    let mut state = entry.state.lock().unwrap().clone();
    state["state"] = json!(if ok {
        "completed"
    } else if reason.as_deref() == Some("cancelled") {
        "cancelled"
    } else {
        "failed"
    });
    state["settled"] = json!(true);
    state["ok"] = json!(ok);
    state["error"] = json!(reason);
    state["code"] = json!(if ok {
        0
    } else {
        code.filter(|c| *c != 0).unwrap_or(-1)
    });
    state["process_exit_code"] = json!(code);
    state["output_complete"] = json!(complete);
    // An adopted tree ended on its own; nothing was terminated, and saying "unknown"
    // would read as a cleanup that did not happen.
    state["cleanup"] = json!(cleanup.unwrap_or(if promoted { "self_exited" } else { "unknown" }));
    state["promoted"] = json!(promoted);
    if !process.auxiliary_cleanup().is_empty() {
        state["auxiliary_cleanup"] = json!(process.auxiliary_cleanup());
        state["cleanup"] = json!("compiler_helpers_terminated");
    }
    state["stdout"] = json!(String::from_utf8_lossy(&views[0]));
    state["stderr"] = json!(String::from_utf8_lossy(&views[1]));
    state["output_truncated"] = json!(bytes > views.iter().map(Vec::len).sum());
    let total_ms = entry.started.elapsed().as_millis() as u64;
    state["elapsed_ms"] = json!(total_ms);
    finish_timing(&mut state, total_ms);
    if let Err(e) = atomic_json(&dir.join("state.json"), &state) {
        state["ok"] = json!(false);
        state["error"] = json!(format!("operation_record_failed:{e}"));
    }
    *entry.state.lock().unwrap() = state;
    entry.settled.notify_all();
    Ok(())
}

#[cfg(test)]
mod tests;
