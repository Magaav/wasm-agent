//! An operation owns execution, output, cancellation and settlement. A job is an automation rule,
//! not a process. See docs/OPERATIONS.md. No model, Lua state, HTTP or UI is needed to supervise it.
mod process;
use process::Process;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs::{self, File},
    io::{self, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, Condvar,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const CLEANUP_MS: u64 = 1000;
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
        }
    }
}
struct Entry {
    cancel: AtomicBool,
    state: Mutex<Value>,
    settled: Condvar,
    started: Instant,
    deadline: Duration,
}
#[derive(Clone)]
pub struct Manager {
    root: PathBuf,
    entries: Arc<Mutex<HashMap<String, Arc<Entry>>>>,
}
fn error(message: impl ToString) -> io::Error {
    io::Error::other(message.to_string())
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
        }
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
        let state = json!({"operation_id":id,"owner":spec.owner,"state":"accepted","settled":false,"timeout_ms":spec.timeout.as_millis() as u64,"cleanup_budget_ms":CLEANUP_MS,"containment":Process::containment(),"stdout_path":dir.join("stdout").to_string_lossy(),"stderr_path":dir.join("stderr").to_string_lossy(),"output_bytes":0});
        let entry = Arc::new(Entry {
            cancel: AtomicBool::new(false),
            state: Mutex::new(state),
            settled: Condvar::new(),
            started: Instant::now(),
            deadline: spec.timeout,
        });
        entries.insert(id.clone(), entry.clone());
        drop(entries);
        let result = std::thread::Builder::new()
            .name("operation".into())
            .spawn(move || {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    // Persist admission before any external effect, but never hold the control
                    // registry/state mutex across filesystem I/O.
                    fs::create_dir_all(&dir)?;
                    let accepted = entry.state.lock().unwrap().clone();
                    atomic_json(&dir.join("state.json"), &accepted)?;
                    if entry.cancel.load(Ordering::Acquire) {
                        return Err(error("cancelled"));
                    }
                    if entry.started.elapsed() >= spec.timeout {
                        return Err(error("deadline_exceeded"));
                    }
                    execute(&spec, &dir, &entry)
                }));
                let failure = match outcome {
                    Ok(Ok(())) => None,
                    Ok(Err(e)) => Some(e.to_string()),
                    Err(_) => Some("operation_supervisor_panicked".into()),
                };
                if let Some(reason) = failure {
                    let mut s = entry.state.lock().unwrap_or_else(|e| e.into_inner());
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
                    s["elapsed_ms"] = json!(entry.started.elapsed().as_millis() as u64);
                    let record = s.clone();
                    drop(s);
                    entry.settled.notify_all();
                    let _ = atomic_json(&dir.join("state.json"), &record);
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
            }
            state["overdue"] = json!(
                !state["settled"].as_bool().unwrap_or(false)
                    && elapsed > entry.deadline + Duration::from_millis(CLEANUP_MS)
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
        Ok(
            json!({"operation_id":id,"stream":stream,"offset":offset,"next_offset":offset+n as u64,"content":String::from_utf8_lossy(&data),"available_bytes":file.metadata()?.len()}),
        )
    }
    pub fn wait(&self, id: &str, budget: Duration) -> io::Result<Value> {
        validate_id(id)?;
        let entry = self.entries.lock().map_err(error)?.get(id).cloned();
        if let Some(entry) = entry {
            let state = entry.state.lock().map_err(error)?;
            let (state, _) = entry.settled.wait_timeout_while(state, budget, |s| s["settled"] != true).map_err(error)?;
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
fn execute(spec: &Spec, dir: &Path, entry: &Entry) -> io::Result<()> {
    let mut files = [
        File::create(dir.join("stdout"))?,
        File::create(dir.join("stderr"))?,
    ];
    let mut process = Process::spawn(spec)?;
    entry.state.lock().unwrap()["state"] = json!("running");
    let mut views = [Vec::new(), Vec::new()];
    let mut eof = [false, false];
    let mut bytes = 0usize;
    let mut code = None;
    let mut reason = None;
    let mut cleanup = None;
    let mut stopped = None;
    let mut parent_exit = None;
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
                        eof[index] = true;
                        break;
                    }
                    Ok(Some(n)) => {
                        let keep = n.min(spec.output_limit.saturating_sub(bytes));
                        files[index].write_all(&buffer[..keep])?;
                        tail(&mut views[index], &buffer[..keep]);
                        bytes += keep;
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
            }
        }
        if stopped.is_none() {
            if entry.cancel.load(Ordering::Acquire) {
                reason.get_or_insert("cancelled".into());
            }
            if entry.started.elapsed() >= spec.timeout {
                reason.get_or_insert("deadline_exceeded".into());
            }
            // Launchers (notably Git's bin/bash.exe) may signal before their real shell finishes
            // closing stdio. One shared 50ms drain allowance, inside the absolute deadline, not per pipe.
            let descendants = code.is_some() && process.descendants()?;
            let exited = code.is_some()
                && ((!descendants && eof.iter().all(|v| *v))
                    || parent_exit.unwrap().elapsed() >= Duration::from_millis(50));
            if exited || reason.is_some() {
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
        {
            let mut state = entry.state.lock().unwrap();
            state["output_bytes"] = json!(bytes);
            state["process_exit_code"] = json!(code);
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
    for file in &mut files {
        file.sync_all()?;
    }
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
    state["cleanup"] = json!(cleanup.unwrap_or("unknown"));
    state["stdout"] = json!(String::from_utf8_lossy(&views[0]));
    state["stderr"] = json!(String::from_utf8_lossy(&views[1]));
    state["output_truncated"] = json!(bytes > views.iter().map(Vec::len).sum());
    state["elapsed_ms"] = json!(entry.started.elapsed().as_millis() as u64);
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
