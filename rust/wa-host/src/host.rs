//! Host capabilities exposed to Lua: sqlite, sha256, uuid, time, log, files.
//!
//! These are the only things the Lua agent cannot do by itself. Everything the
//! agent *decides* lives in Lua; everything it *needs from the platform* lives
//! here, so the same Lua can later run as a WASM component with these imports.
use crate::lua::{arg_integer, arg_string, lua_pushlstring, lua_touserdata, upvalue_index, LuaState};
use crate::plugins::PluginRegistry;
use base64::Engine as _;
use ring::rand::{SecureRandom, SystemRandom};
use rusqlite::{params_from_iter, Connection};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::ffi::{c_char, c_int};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

pub struct Host {
    /// This interpreter's OWN SQLite connection, to the same WAL database. Two
    /// interpreters must not share one connection: a transaction one holds open
    /// would otherwise be visible to the other, and a rollback there could erase a
    /// peer's work. Each connection has its own busy timeout and rolls back on
    /// close, so a dropped interpreter cannot leave a transaction behind.
    pub db: Mutex<Connection>,
    /// Shared, because there is one plugin runtime per process.
    pub plugins: std::sync::Arc<Mutex<PluginRegistry>>,
    /// The client bridge is a process-wide resource, so it is shared too.
    pub client: std::sync::Arc<crate::client_bridge::Bridge>,
}

// Values the host resolved itself: the config file, the home directory, the
// database path. Lua reads them through `host.getenv` rather than `os.getenv`
// because on Windows Rust's `set_var` is invisible to the C runtime's
// `getenv` - the UCRT caches the environment at startup, so `os.getenv` kept
// returning what the process was launched with. The effect was silent: the
// entire config file was ignored and the agent ran with "no model configured".
static ENV_OVERRIDES: OnceLock<HashMap<String, String>> = OnceLock::new();

/// Set once the process has run the schema migration. Every interpreter opens its
/// own connection, so a second interpreter booting while another holds a write
/// transaction must NOT replay the DDL - it would block on the write lock and fail.
/// The first interpreter migrates; the rest assume the schema and use their own
/// connection. Process-wide because the database is.
static DB_READY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// host.db_ready() -> boolean: has this process already migrated the schema?
pub extern "C" fn db_ready(l: *mut LuaState) -> c_int {
    unsafe { crate::lua::lua_pushboolean(l, DB_READY.load(std::sync::atomic::Ordering::SeqCst) as c_int) };
    1
}

/// host.mark_db_ready() -> nil: record that the schema migration has run.
pub extern "C" fn mark_db_ready(l: *mut LuaState) -> c_int {
    DB_READY.store(true, std::sync::atomic::Ordering::SeqCst);
    // One explicit nil, never zero results: `select('#', host.mark_db_ready())`
    // must be 1, or a caller that passes the result around gets nothing.
    unsafe { crate::lua::lua_pushnil(l) };
    1
}

pub fn set_env_overrides(values: HashMap<String, String>) {
    let _ = ENV_OVERRIDES.set(values);
}

/// host.getenv(name) -> string | nil
///
/// Env access as a capability, like the rest of `host.*`: it checks what the
/// host resolved first and falls back to the real process environment.
pub extern "C" fn getenv(l: *mut LuaState) -> c_int {
    let name = arg_string(l, 1).unwrap_or_default();
    let value = ENV_OVERRIDES
        .get()
        .and_then(|map| map.get(&name).cloned())
        .or_else(|| std::env::var(&name).ok());
    match value {
        Some(value) => {
            unsafe { lua_pushlstring(l, value.as_ptr() as *const c_char, value.len()) };
            1
        }
        // Push an explicit nil. Returning *zero* values instead would expand to
        // nothing when used as a function argument, so `tonumber(host.getenv(X))`
        // would become `tonumber()` and fail with "bad argument #1".
        None => {
            unsafe { crate::lua::lua_pushnil(l) };
            1
        }
    }
}

/// host.paths() -> { home, config, data, cache, temp }
///
/// Platform-neutral directories, so the Lua core never has to know about
/// `$HOME`, `/tmp`, or drive letters - and so the same Lua can later run under
/// WASI, where these are exactly what the filesystem preopens provide.
///
/// A host function always returns a value: an absent string is `nil`, never
/// "no values", because zero results expand to nothing when used as an argument
/// (`tonumber(host.getenv(X))` became `tonumber()` and failed).
pub extern "C" fn paths(l: *mut LuaState) -> c_int {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    let base = format!("{home}/.wasm-agent");
    let entries: [(&str, String); 5] = [
        ("home", home),
        ("config", base.clone()),
        ("data", base.clone()),
        ("cache", format!("{base}/cache")),
        ("temp", std::env::temp_dir().to_string_lossy().to_string()),
    ];
    unsafe {
        crate::lua::lua_createtable(l, 0, entries.len() as c_int);
        for (key, value) in entries {
            lua_pushlstring(l, value.as_ptr() as *const c_char, value.len());
            let name = std::ffi::CString::new(key).unwrap();
            crate::lua::lua_setfield(l, -2, name.as_ptr());
        }
    }
    1
}

/// The shell `host.exec` runs commands with.
///
/// The model speaks POSIX: `ls`, `pwd`, `tail`, `grep`, single quotes, `$VAR`.
/// pi resolves this by requiring bash on Windows - Git Bash, Cygwin, MSYS2, WSL -
/// and refusing to start without it. We did the opposite, running `cmd /C`, so
/// every one of those came back "is not recognized as an internal or external
/// command" and the model, which cannot see the difference, tried variants of the
/// same idea until its budget was gone. That was mistaken for the model being bad
/// at tool calls; it was answering in the wrong language.
fn executable_on_path(name: &str) -> Option<String> {
    let path = std::env::var("PATH").ok()?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().to_string());
        }
    }
    None
}

fn shell_config() -> &'static (String, String) {
    static SHELL: OnceLock<(String, String)> = OnceLock::new();
    SHELL.get_or_init(|| {
        // An explicit choice wins: pi has `shellPath` for the same reason.
        if let Ok(explicit) = std::env::var("WASM_AGENT_SHELL") {
            if !explicit.is_empty() {
                return (explicit, "-c".to_string());
            }
        }
        if cfg!(target_os = "windows") {
            let mut candidates = vec![
                r"C:\Program Files\Git\bin\bash.exe".to_string(),
                r"C:\Program Files (x86)\Git\bin\bash.exe".to_string(),
                r"C:\Program Files\Git\usr\bin\bash.exe".to_string(),
            ];
            for name in ["bash.exe", "sh.exe"] {
                if let Some(found) = executable_on_path(name) {
                    candidates.push(found);
                }
            }
            for candidate in candidates {
                if std::path::Path::new(&candidate).is_file() {
                    return (candidate, "-c".to_string());
                }
            }
            return ("cmd".to_string(), "/C".to_string());
        }
        for name in ["/bin/bash", "/usr/bin/bash"] {
            if std::path::Path::new(name).is_file() {
                return (name.to_string(), "-c".to_string());
            }
        }
        if let Some(found) = executable_on_path("bash") {
            return (found, "-c".to_string());
        }
        ("sh".to_string(), "-c".to_string())
    })
}

/// host.platform() -> { os, arch, shell, pathSeparator, cwd }
///
/// So the agent can be told which dialect it is running in. Its `bash` tool is
/// `sh -c` on Linux and `cmd /C` on Windows, and without this the model guesses
/// POSIX: it runs `pwd`, `ls` and `grep`, gets "not recognized as an internal or
/// external command", and burns its tool budget on retries.
pub extern "C" fn platform(l: *mut LuaState) -> c_int {
    let entries: [(&str, String); 5] = [
        ("os", std::env::consts::OS.to_string()),
        ("arch", std::env::consts::ARCH.to_string()),
        (
            "shell",
            format!("{} {}", shell_config().0, shell_config().1),
        ),
        ("pathSeparator", std::path::MAIN_SEPARATOR.to_string()),
        // pi puts the working directory at the end of its system prompt, and an
        // agent in a worktree should never have to guess which checkout it is in.
        (
            "cwd",
            std::env::current_dir()
                .map(|p| p.to_string_lossy().replace('\\', "/"))
                .unwrap_or_else(|_| ".".to_string()),
        ),
    ];
    unsafe {
        crate::lua::lua_createtable(l, 0, entries.len() as c_int);
        for (key, value) in entries {
            lua_pushlstring(l, value.as_ptr() as *const c_char, value.len());
            let name = std::ffi::CString::new(key).unwrap();
            crate::lua::lua_setfield(l, -2, name.as_ptr());
        }
    }
    1
}

/// host.grep(pattern, path, opts?) -> [{ file, line, text }]
///
/// Implemented here rather than by shelling out to `grep`, which does not exist
/// on Windows - the tool used to fail with "'grep' is not recognized" on a
/// Windows node. Plain substring matching, optionally case-insensitive: enough
/// for finding code, and it behaves identically on every platform.
pub extern "C" fn grep(l: *mut LuaState) -> c_int {
    let pattern = arg_string(l, 1).unwrap_or_default();
    let path = arg_string(l, 2).unwrap_or_else(|| ".".to_string());
    let options = arg_string(l, 3).unwrap_or_default();
    let options: Value = serde_json::from_str(&options).unwrap_or(Value::Null);
    push_json(l, &crate::file_search::search(&pattern, &path, &options));
    1
}

/// host.list_dir(path) -> [{ name, kind, size, modified }]
///
/// The `ls` tool used to shell out to `ls -la`, which does not exist on Windows:
/// its description claimed to be portable while the implementation was not, and
/// a self-evolution run found that before I did.
pub extern "C" fn list_dir(l: *mut LuaState) -> c_int {
    let path = arg_string(l, 1).unwrap_or_else(|| ".".to_string());
    let mut entries: Vec<Value> = Vec::new();
    match std::fs::read_dir(&path) {
        Ok(reader) => {
            for entry in reader.flatten() {
                let metadata = entry.metadata().ok();
                let kind = match metadata.as_ref().map(|m| m.is_dir()) {
                    Some(true) => "dir",
                    Some(false) => "file",
                    None => "other",
                };
                entries.push(json!({
                    "name": entry.file_name().to_string_lossy(),
                    "kind": kind,
                    "size": metadata.as_ref().map(|m| m.len()).unwrap_or(0),
                    "modified": metadata
                        .as_ref()
                        .and_then(|m| m.modified().ok())
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map(|d| d.as_secs())
                        .unwrap_or(0),
                }));
            }
            entries.sort_by(|a, b| {
                let (ad, bd) = (a["kind"] == "dir", b["kind"] == "dir");
                bd.cmp(&ad).then_with(|| a["name"].as_str().cmp(&b["name"].as_str()))
            });
            push_json(l, &json!({ "path": path, "entries": entries }));
        }
        Err(error) => push_json(l, &json!({ "error": error.to_string(), "path": path })),
    }
    1
}

fn host_of<'a>(l: *mut LuaState) -> &'a Host {
    unsafe {
        let ptr = lua_touserdata(l, upvalue_index(1)) as *const Host;
        assert!(!ptr.is_null(), "host state missing");
        &*ptr
    }
}

fn push_json(l: *mut LuaState, value: &Value) {
    let text = serde_json::to_string(value).unwrap_or_else(|_| "null".to_string());
    unsafe { lua_pushlstring(l, text.as_ptr() as *const c_char, text.len()) };
}

/// An agent that returns error responses instead of raising, so provider 4xx bodies
/// reach the caller (and the logs).
///
/// The timeouts matter more than they look, and their absence is what wedged a node for
/// nine hours. With no read timeout, a provider that accepts the connection and then
/// stops talking blocks the one thread that owns the interpreter - forever. Every
/// endpoint that needs Lua hung with zero bytes while /health (answered on another
/// thread, without Lua) kept reporting ok, and an external run had to work out from the
/// WAL's last write what the node could have told it.
///
/// The read timeout is per read, not for the whole exchange, which is the point: a long
/// stream that keeps producing is fine, and one that goes quiet is not.
fn http_timeouts() -> (u64, u64, u64) {
    let connect = std::env::var("WASM_AGENT_HTTP_CONNECT_TIMEOUT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(10u64);
    let read = std::env::var("WASM_AGENT_HTTP_READ_TIMEOUT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(180u64);
    // ureq 3 names these for the phase they bound: waiting for the response headers,
    // and waiting for each read of the body. The second is what catches an SSE stream
    // that has gone quiet without capping a long one that is still talking.
    let respond = std::env::var("WASM_AGENT_HTTP_RESPONSE_TIMEOUT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(120u64);
    (connect, read, respond)
}

fn build_config(read: u64) -> ureq::config::Config {
    let (connect, _, respond) = http_timeouts();
    ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_connect(Some(std::time::Duration::from_secs(connect)))
        .timeout_recv_response(Some(std::time::Duration::from_secs(respond)))
        .timeout_recv_body(Some(std::time::Duration::from_secs(read)))
        .build()
}

fn agent() -> ureq::Agent {
    static HTTP_AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    HTTP_AGENT
        .get_or_init(|| {
            let (_, read, _) = http_timeouts();
            build_config(read).into()
        })
        .clone()
}

/// The agent to use for one provider call.
///
/// A child runs under a deadline the runtime owns, and that deadline has to
/// affect the network read rather than only being checked between model calls.
/// When this thread is a child, its provider call uses the shutdown-aware
/// transport (`http_transport`): the socket is registered with the task, so a
/// cancel from another thread wakes a silent read immediately, and the body
/// budget still bounds a provider that never speaks at all.
fn agent_for_call() -> ureq::Agent {
    if !crate::subagents::in_task() {
        return agent();
    }
    let (_, read, _) = http_timeouts();
    let body = match crate::subagents::remaining_budget() {
        Some(remaining) => remaining.as_secs().clamp(1, read.max(1)),
        None => read,
    };
    crate::http_transport::agent(build_config(body))
}

/// Unified cancellation for the Lua loop: true when the current run or the
/// current child has been asked to stop.
///
/// The run half is a probe the serve layer registers (`set_run_cancel_probe`),
/// so host.rs does not depend on serve's internals; the child half is the task's
/// own flag. One name means a caller cannot check the wrong one.
static RUN_CANCEL_PROBE: OnceLock<fn() -> bool> = OnceLock::new();

pub fn set_run_cancel_probe(probe: fn() -> bool) {
    let _ = RUN_CANCEL_PROBE.set(probe);
}

pub(crate) fn run_cancel_requested() -> bool {
    RUN_CANCEL_PROBE.get().map(|probe| probe()).unwrap_or(false) || crate::subagents::cancel_requested()
}

/// host.run_cancelled() -> {cancelled, run_cancel, subagent_cancel}
///
/// `cancelled` is true while either source is set. A foreground run's scoped
/// cancellation is the run half; a supervised child's is the subagent half.
pub extern "C" fn run_cancelled(l: *mut LuaState) -> c_int {
    let run_cancel = RUN_CANCEL_PROBE.get().map(|probe| probe()).unwrap_or(false);
    let subagent_cancel = crate::subagents::cancel_requested();
    push_json(
        l,
        &json!({
            "cancelled": run_cancel || subagent_cancel,
            "run_cancel": run_cancel,
            "subagent_cancel": subagent_cancel,
        }),
    );
    1
}

fn parse_headers(headers_json: &str) -> Vec<(String, String)> {
    serde_json::from_str::<serde_json::Map<String, Value>>(headers_json)
        .map(|map| {
            map.into_iter()
                .map(|(key, value)| (key, value.as_str().unwrap_or_default().to_string()))
                .collect()
        })
        .unwrap_or_default()
}

fn params(values: &[Value]) -> Vec<Box<dyn rusqlite::ToSql>> {
    values
        .iter()
        .map(|value| -> Box<dyn rusqlite::ToSql> {
            match value {
                Value::Null => Box::new(Option::<String>::None),
                Value::Bool(flag) => Box::new(*flag as i64),
                Value::Number(number) if number.is_i64() => Box::new(number.as_i64().unwrap_or(0)),
                Value::Number(number) => Box::new(number.as_f64().unwrap_or(0.0)),
                Value::String(text) => Box::new(text.clone()),
                other => Box::new(other.to_string()),
            }
        })
        .collect()
}

/// host.sql_exec(sql, params_json) -> {ok, changes} | {error}
///
/// A statement error is RETURNED, never forced into a rollback: SQLite lets the
/// caller recover inside its transaction (catch the error, compensate, commit or
/// roll back explicitly). Forcing a rollback here would silently end the
/// transaction, and a Lua caller that caught the error and wrote again would then
/// autocommit the later write, breaking atomicity. A transaction is closed only at
/// an uncaught callback error (`Lua::rollback_if_open`) or when the interpreter's
/// connection drops.
pub extern "C" fn sql_exec(l: *mut LuaState) -> c_int {
    let host = host_of(l);
    let sql = arg_string(l, 1).unwrap_or_default();
    let params_json = arg_string(l, 2).unwrap_or_else(|| "[]".into());
    let values: Vec<Value> = serde_json::from_str(&params_json).unwrap_or_default();
    let outcome = (|| -> Result<Value, String> {
        let conn = host.db.lock().map_err(|e| e.to_string())?;
        if values.is_empty() {
            conn.execute_batch(&sql).map_err(|e| e.to_string())?;
            Ok(json!({"ok": true, "changes": conn.changes()}))
        } else {
            let owned = params(&values);
            let changes = conn
                .execute(&sql, params_from_iter(owned.iter().map(|p| p.as_ref())))
                .map_err(|e| e.to_string())?;
            Ok(json!({"ok": true, "changes": changes}))
        }
    })();
    push_json(l, &outcome.unwrap_or_else(|error| json!({"error": error})));
    1
}

/// host.sql_query(sql, params_json) -> [ {column: value}, ... ] | {error}
pub extern "C" fn sql_query(l: *mut LuaState) -> c_int {
    let host = host_of(l);
    let sql = arg_string(l, 1).unwrap_or_default();
    let params_json = arg_string(l, 2).unwrap_or_else(|| "[]".into());
    let values: Vec<Value> = serde_json::from_str(&params_json).unwrap_or_default();
    let outcome = (|| -> Result<Value, String> {
        let conn = host.db.lock().map_err(|e| e.to_string())?;
        let mut statement = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let names: Vec<String> = statement.column_names().iter().map(|s| s.to_string()).collect();
        let owned = params(&values);
        let mut rows = statement
            .query(params_from_iter(owned.iter().map(|p| p.as_ref())))
            .map_err(|e| e.to_string())?;
        let mut out = Vec::new();
        while let Some(row) = rows.next().map_err(|e| e.to_string())? {
            let mut object = serde_json::Map::new();
            for (index, name) in names.iter().enumerate() {
                let value = match row.get_ref(index).map_err(|e| e.to_string())? {
                    rusqlite::types::ValueRef::Null => Value::Null,
                    rusqlite::types::ValueRef::Integer(n) => json!(n),
                    rusqlite::types::ValueRef::Real(f) => json!(f),
                    rusqlite::types::ValueRef::Text(t) => json!(String::from_utf8_lossy(t)),
                    rusqlite::types::ValueRef::Blob(b) => json!(format!("<{} bytes>", b.len())),
                };
                object.insert(name.clone(), value);
            }
            out.push(Value::Object(object));
        }
        Ok(Value::Array(out))
    })();
    push_json(l, &outcome.unwrap_or_else(|error| json!({"error": error})));
    1
}

/// host.sha256(text) -> hex
pub extern "C" fn sha256(l: *mut LuaState) -> c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    let digest = ring::digest::digest(&ring::digest::SHA256, text.as_bytes());
    let hex: String = digest.as_ref().iter().map(|byte| format!("{byte:02x}")).collect();
    unsafe { lua_pushlstring(l, hex.as_ptr() as *const c_char, hex.len()) };
    1
}

/// host.uuid() -> random uuid v4 string
/// A v4 UUID.
///
/// Uniqueness here is load-bearing: runs, memories, sessions and journal rows
/// are all keyed by it. The previous implementation read
/// /proc/sys/kernel/random/uuid and fell back to the *process id* everywhere
/// else, which is one value per process - so off Linux the second write in any
/// session died on a duplicate row id.
fn new_uuid() -> String {
    let mut bytes = [0u8; 16];
    let random = SystemRandom::new();
    if random.fill(&mut bytes).is_err() {
        // Should not happen, but never return a constant: mix in the clock and
        // a counter so consecutive calls still differ.
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        bytes[..8].copy_from_slice(&now.as_nanos().to_le_bytes());
        bytes[8..].copy_from_slice(&COUNTER.fetch_add(1, Ordering::Relaxed).to_le_bytes());
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

pub extern "C" fn uuid(l: *mut LuaState) -> c_int {
    let value = new_uuid();
    unsafe { lua_pushlstring(l, value.as_ptr() as *const c_char, value.len()) };
    1
}

/// host.read_file(path) -> string | nil
pub extern "C" fn read_file(l: *mut LuaState) -> c_int {
    match arg_string(l, 1).and_then(|path| std::fs::read_to_string(path).ok()) {
        Some(text) => {
            unsafe { lua_pushlstring(l, text.as_ptr() as *const c_char, text.len()) };
            1
        }
        None => {
            unsafe { crate::lua::lua_pushnil(l) };
            1
        }
    }
}

/// Identify the image formats the provider path accepts from their bytes, never
/// from an extension supplied by a file name.
fn supported_image_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]) {
        Some("image/png")
    } else if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some("image/gif")
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

fn read_image_value(path: &str, max_bytes: usize) -> Value {
    use std::io::{Read, Seek, SeekFrom};

    let mut file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return json!({"error": "not_found", "path": path});
        }
        Err(_) => return json!({"error": "read_failed", "path": path}),
    };
    let mut header = [0u8; 12];
    let header_len = match file.read(&mut header) {
        Ok(read) => read,
        Err(_) => return json!({"error": "read_failed", "path": path}),
    };
    let mime = match supported_image_mime(&header[..header_len]) {
        Some(mime) => mime,
        None => {
            if header[..header_len].starts_with(b"BM") {
                return json!({"error": "unsupported_image_type", "mime": "image/bmp", "path": path});
            }
            return json!({"error": "not_image", "path": path});
        }
    };
    let measured = file.metadata().ok().map(|metadata| metadata.len() as usize);
    if measured.is_some_and(|bytes| bytes > max_bytes) {
        return json!({"error": "image_too_large", "path": path, "bytes": measured, "max_bytes": max_bytes});
    }
    if file.seek(SeekFrom::Start(0)).is_err() {
        return json!({"error": "read_failed", "path": path});
    }
    // The metadata check is an early refusal, not the bound: a file can grow
    // between metadata and read. `take(max+1)` keeps that race bounded too.
    let mut bytes = Vec::with_capacity(measured.unwrap_or(0).min(max_bytes));
    if file.by_ref().take(max_bytes as u64 + 1).read_to_end(&mut bytes).is_err() {
        return json!({"error": "read_failed", "path": path});
    }
    if bytes.len() > max_bytes {
        return json!({"error": "image_too_large", "path": path,
            "bytes_at_least": bytes.len(), "max_bytes": max_bytes});
    }
    if supported_image_mime(&bytes) != Some(mime) {
        return json!({"error": "file_changed_during_read", "path": path});
    }
    json!({
        "path": path,
        "mime": mime,
        "bytes": bytes.len(),
        "base64": base64::engine::general_purpose::STANDARD.encode(bytes),
    })
}

/// host.read_image_base64(path, max_bytes) -> JSON
///
/// Probe by magic bytes and read a supported image with a hard allocation bound.
/// `not_image` is an ordinary answer: Lua then uses the UTF-8 text reader. The
/// base64 is transport across the Lua/WIT seam; it is not a model-facing result.
pub extern "C" fn read_image_base64(l: *mut LuaState) -> c_int {
    let path = arg_string(l, 1).unwrap_or_default();
    let maximum = arg_integer(l, 2).unwrap_or(4_000_000);
    let value = if path.is_empty() {
        json!({"error": "path_required"})
    } else if !(1..=64 * 1024 * 1024).contains(&maximum) {
        json!({"error": "invalid_image_limit", "max_bytes": maximum})
    } else {
        read_image_value(&path, maximum as usize)
    };
    push_json(l, &value);
    1
}

#[cfg(test)]
mod image_file_tests {
    use super::{read_image_value, supported_image_mime};
    use std::sync::atomic::{AtomicU64, Ordering};

    fn temporary(name: &str) -> std::path::PathBuf {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        std::env::temp_dir().join(format!(
            "wa-image-read-{}-{}-{name}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ))
    }

    #[test]
    fn supported_images_are_sniffed_from_bytes() {
        assert_eq!(
            supported_image_mime(b"\x89PNG\r\n\x1a\nrest"),
            Some("image/png")
        );
        assert_eq!(
            supported_image_mime(b"\xff\xd8\xffrest"),
            Some("image/jpeg")
        );
        assert_eq!(supported_image_mime(b"GIF89arest"), Some("image/gif"));
        assert_eq!(supported_image_mime(b"RIFF1234WEBPrest"), Some("image/webp"));
        assert_eq!(supported_image_mime(b"not an image"), None);
    }

    #[test]
    fn image_reads_are_bounded_and_base64_encoded() {
        let image = temporary("probe.bin");
        std::fs::write(&image, b"\x89PNG\r\n\x1a\n").unwrap();
        let read = read_image_value(image.to_str().unwrap(), 64);
        assert_eq!(read["mime"], "image/png");
        assert_eq!(read["bytes"], 8);
        assert_eq!(read["base64"], "iVBORw0KGgo=");

        let too_large = read_image_value(image.to_str().unwrap(), 7);
        assert_eq!(too_large["error"], "image_too_large");
        assert_eq!(too_large["max_bytes"], 7);
        let _ = std::fs::remove_file(image);
    }

    #[test]
    fn text_and_unsupported_images_are_explicit() {
        let text = temporary("text.txt");
        std::fs::write(&text, b"hello").unwrap();
        assert_eq!(
            read_image_value(text.to_str().unwrap(), 64)["error"],
            "not_image"
        );
        let _ = std::fs::remove_file(text);

        let bitmap = temporary("bitmap.dat");
        std::fs::write(&bitmap, b"BMnot-really-a-bitmap").unwrap();
        let refused = read_image_value(bitmap.to_str().unwrap(), 64);
        assert_eq!(refused["error"], "unsupported_image_type");
        assert_eq!(refused["mime"], "image/bmp");
        let _ = std::fs::remove_file(bitmap);
    }
}

/// host.write_file(path, text) -> boolean
/// Write a file so that a reader never sees a half-written one.
///
/// `fs::write` truncates and then streams. A crash, a kill, or a full disk between those two leaves the
/// file shorter than it was - and this is the write path behind `write`, `edit`, the undo of a recorded
/// change, and the content-addressed blob store, so the file it truncates may be the only copy of the
/// text an undo needs. The v8 implementation had `atomic_write` (temp, fsync, rename) for exactly this
/// reason; the new one wrote directly, which was a regression rather than a difference of taste.
///
/// Rename within one directory is atomic on both platforms. The temp name carries the pid and a counter
/// so two writers cannot collide, the bytes are fsynced before the rename so a power loss cannot leave
/// the new name pointing at empty content, and the temp file is removed on every failure path so a
/// failed write leaves no litter beside the user's file.
fn write_atomic(path: &str, text: &str) -> bool {
    use std::io::Write;
    let target = std::path::Path::new(path);
    if let Some(parent) = target.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let directory = match target.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.to_path_buf(),
        _ => std::path::PathBuf::from("."),
    };
    let name = target
        .file_name()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_else(|| "file".to_string());
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let unique = format!(
        ".{name}.wa-tmp-{}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    );
    let temporary = directory.join(unique);
    let written = (|| -> std::io::Result<()> {
        let mut file = std::fs::File::create(&temporary)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        Ok(())
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temporary);
        return false;
    }
    // A rename replaces the target but not its permissions, so carry them over. v8 did this too; on a
    // script the difference between 0755 and 0644 is whether it still runs.
    #[cfg(unix)]
    if let Ok(metadata) = std::fs::metadata(target) {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(metadata.permissions().mode()));
    }
    match std::fs::rename(&temporary, target) {
        Ok(()) => true,
        Err(_) => {
            // A rename can fail where a direct write would not: a target another process holds open on
            // Windows, a read-only file, a target that is not a plain file. Falling back keeps the
            // promise this function always made - a boolean, and the bytes where they were asked for -
            // rather than failing a write that used to succeed.
            let ok = std::fs::write(target, text).is_ok();
            let _ = std::fs::remove_file(&temporary);
            ok
        }
    }
}

pub extern "C" fn write_file(l: *mut LuaState) -> c_int {
    let path = arg_string(l, 1).unwrap_or_default();
    let text = arg_string(l, 2).unwrap_or_default();
    let ok = write_atomic(&path, &text);
    unsafe { crate::lua::lua_pushboolean(l, ok as c_int) };
    1
}

/// The deadline a `bash`/`shell` call is given, in seconds. Read here because this is where it is
/// enforced; `host.exec_timeout()` and `serve::health_body` both report this same number, so a
/// client can show the bound without duplicating the parse or drifting from what the host does.
pub(crate) fn exec_timeout_seconds() -> u64 {
    std::env::var("WASM_AGENT_EXEC_TIMEOUT_SECONDS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(300u64)
}

/// Compatibility facade over the supervised operation runtime. No pipes, reader threads or
/// independent heartbeat live here; the lifecycle is owned by wa-operation (docs/OPERATIONS.md).
fn run_bounded(
    program: &str,
    flag: &str,
    command: &str,
    cwd: &str,
    requested_seconds: Option<u64>,
) -> Result<Value, String> {
    // A child's shell call must not outlive the child: the operation timeout is the
    // smaller of the configured exec deadline and the child's remaining budget, and
    // a cancel stops the operation rather than leaving it running past settlement.
    // A caller may name its own budget (the `bash` tool's `timeout_seconds`), in the
    // same 1-86400 range `operation start` accepts; an out-of-range value is refused,
    // not clamped, so a caller never believes it got a bound it did not.
    let mut seconds = match requested_seconds {
        Some(value) if (1..=86_400).contains(&value) => value,
        Some(_) => return Err("invalid_timeout_seconds".into()),
        None => exec_timeout_seconds(),
    };
    if let Some(remaining) = crate::subagents::remaining_budget() {
        seconds = seconds.min(remaining.as_secs().max(1));
    }
    crate::operations::foreground(program, flag, command, cwd, seconds)
}

/// host.operation(action, args_json) -> operation receipt/state/output | {error}
pub extern "C" fn operation(l: *mut LuaState) -> c_int {
    let action = arg_string(l, 1).unwrap_or_default();
    let args = arg_string(l, 2).unwrap_or_else(|| "{}".into());
    let result = serde_json::from_str(&args).map_err(|e|e.to_string())
        .and_then(|args|crate::operations::control(&action, &args, shell_config()));
    push_json(l, &result.unwrap_or_else(|error|json!({"ok":false,"error":error})));
    1
}

/// host.jobs(action, args_json): local automation management, never execution.
pub extern "C" fn jobs(l: *mut LuaState) -> c_int {
    let action=arg_string(l,1).unwrap_or_else(||"list".into());
    let args:Value=serde_json::from_str(&arg_string(l,2).unwrap_or_else(||"{}".into())).unwrap_or(Value::Null);
    let root=std::path::PathBuf::from(std::env::var("HOME").unwrap_or_else(|_|".".into())).join(".wasm-agent/sentinel/jobs.db");
    let store=wa_jobs::Store::new(root);
    let result=match action.as_str() {
        "list"=>store.list().map(|jobs|json!({"jobs":jobs})),
        "history"=>store.history(),
        "enable"=>store.enable(args["id"].as_str().unwrap_or(""),true),
        "disable"=>store.enable(args["id"].as_str().unwrap_or(""),false),
        _=>Err("unknown_job_action".into()),
    };
    push_json(l,&result.unwrap_or_else(|e|json!({"error":e.to_string()})));1
}

/// host.subagent(action, args_json): the local subagent runtime.
///
/// Agent policy lives in Lua (`lua/core/subagents.lua`): which profile, which
/// tools, which prompt, which budgets, and how a caller's owner is derived. This
/// host function only owns the durable record, the OS thread, the capacity and
/// the cancellation flag, so a Lua interpreter is never the thing that keeps a
/// child alive. Owner scoping is enforced here as well as in Lua: a caller can
/// only read or cancel a task it owns.
pub extern "C" fn subagent(l: *mut LuaState) -> c_int {
    let action = arg_string(l, 1).unwrap_or_default();
    let args: Value = serde_json::from_str(&arg_string(l, 2).unwrap_or_else(|| "{}".into()))
        .unwrap_or(Value::Null);
    push_json(l, &crate::subagents::control(&action, &args).unwrap_or_else(|error| json!({"ok": false, "error": error})));
    1
}

pub extern "C" fn exec(l: *mut LuaState) -> c_int {
    let command = arg_string(l, 1).unwrap_or_default();
    let cwd = arg_string(l, 2).unwrap_or_default();
    let requested = arg_integer(l, 3).and_then(|value| u64::try_from(value).ok());
    let (program, flag) = shell_config();
    let outcome = run_bounded(program, flag, &command, &cwd, requested);
    push_json(l, &outcome.unwrap_or_else(|error| json!({"error": error})));
    1
}

/// host.client(action, args_json) -> result from the client machine | {error}
///
/// The failure path is deliberately verbose, because it is the only part of this
/// interface an agent reads *while confused*. It used to say "start the desktop
/// client with `wa ui`" for every case, which was wrong for the one that actually
/// happens (a wedged bridge, with the window perfectly healthy) and would have
/// put a second window on the same bridge.
pub extern "C" fn client(l: *mut LuaState) -> c_int {
    let host = host_of(l);
    let action = arg_string(l, 1).unwrap_or_default();
    let args: Value = serde_json::from_str(&arg_string(l, 2).unwrap_or_else(|| "{}".into()))
        .unwrap_or_else(|_| json!({}));
    let status = host.client.status();

    // `result` is answered from the bridge itself: the whole point of it is to
    // collect a command whose caller gave up, possibly after the client left.
    if action == "result" {
        let id = args["id"].as_str().unwrap_or_default();
        let mut value = host.client.result(id);
        if let Some(map) = value.as_object_mut() {
            map.insert("bridge".into(), status["bridge"].clone());
        }
        push_json(l, &value);
        return 1;
    }

    let connected = status.get("connected").and_then(Value::as_bool).unwrap_or(false);
    // A `status` call is how a caller learns what is wrong, so it is answered
    // even when nothing is attached - with the bridge's own view, which is the
    // half the client cannot see.
    if !connected {
        // The state fields are spread flat, not nested under `bridge`: an agent
        // reads `bridge.health`, and a payload whose shape differs from the one
        // `status` returns is a trap. (`bridge` is the probe's own state, which
        // is exactly what the reader expects to find there.)
        let mut payload = status.clone();
        if let Some(map) = payload.as_object_mut() {
            map.insert("ok".into(), json!(action == "status" && false));
            map.insert("error".into(), json!("client_not_connected"));
            map.insert("observed".into(), json!(diagnosis(&status)));
            map.insert("next".into(), json!(remedy(&status)));
        }
        push_json(l, &payload);
        return 1;
    }
    let timeout_ms = args["timeout_ms"].as_u64().unwrap_or_else(crate::client_bridge::default_timeout_ms);
    let result = host.client.call(&action, args, timeout_ms);
    // `status` is the one answer a caller may reasonably expect to be complete:
    // the client knows what it is doing, the node knows whether the channel works.
    // Merging here means one call answers both, whatever vintage the window is.
    if action == "status" {
        push_json(l, &status_payload(result, &status));
        return 1;
    }
    push_json(l, &result);
    1
}

/// The `status` answer: the client's own view, the node's view of the channel, and
/// - for a window that predates the action - a sentence instead of an error code.
///
/// Found by using it: with a connected client, `status` was forwarded and returned
/// only what the client said, so a *new* window's answer was missing `bridge.health`
/// and an *old* window's answer was `unknown_action:status`, which tells a reader
/// nothing about what to do next.
fn status_payload(client_reply: Value, status: &Value) -> Value {
    let mut payload = match client_reply["error"].as_str() {
        Some(error) if error.starts_with("unknown_action:") => json!({
            "ok": false,
            "error": "window_too_old",
            "observed": format!("the connected window answered '{error}': it predates the `status` action"),
            "next": "restart the desktop window to load the new client (this node is already new). \
                     Meanwhile the actions that window knows still work: screenshot, frame, click, move, type, key, shell, cdp",
        }),
        _ => client_reply,
    };
    if let Some(map) = payload.as_object_mut() {
        map.insert("connected".into(), status["connected"].clone());
        map.insert("busy".into(), status["busy"].clone());
        map.insert("queued".into(), status["queued"].clone());
        map.insert("bridge".into(), status["bridge"].clone());
    }
    payload
}

#[cfg(test)]
mod client_status_tests {
    use super::status_payload;
    use serde_json::json;

    fn bridge() -> serde_json::Value {
        json!({ "connected": true, "queued": 0, "busy": null,
                "bridge": { "port": 8800, "health": "ok", "self_probe_failures": 0 } })
    }

    #[test]
    fn a_new_window_s_answer_gains_the_node_s_view() {
        let reply = json!({ "ok": true, "chrome": { "running": true, "port": 2532 }, "pages": [] });
        let merged = status_payload(reply, &bridge());
        assert_eq!(merged["chrome"]["port"], 2532, "the client's answer must survive");
        assert_eq!(merged["bridge"]["health"], "ok", "the node's view must be added");
        assert_eq!(merged["connected"], true);
    }

    #[test]
    fn an_old_window_gets_a_sentence_instead_of_an_error_code() {
        let reply = json!({ "error": "unknown_action:status" });
        let merged = status_payload(reply, &bridge());
        assert_eq!(merged["error"], "window_too_old");
        assert!(merged["observed"].as_str().unwrap().contains("predates"));
        assert!(merged["next"].as_str().unwrap().contains("restart the desktop window"));
        // And it still carries what the node knows, which is the half that is new.
        assert_eq!(merged["bridge"]["port"], 8800);
    }
}

/// What is wrong, said as what was seen rather than as a guess.
fn diagnosis(status: &Value) -> String {
    let bridge = &status["bridge"];
    // No bridge at all is not "no client": it is a process that never had one
    // (`wa chat`, a script run). Saying "start the window" there sends the reader
    // looking for a window that was never in the picture.
    if bridge["port"].is_null() {
        return "this process runs no client-tools bridge, so it has no client to act on".to_string();
    }
    let health = bridge["health"].as_str().unwrap_or("unknown");
    match health {
        "wedged" => format!(
            "the client-tools bridge stopped answering its own probe ({} failures on 127.0.0.1:{}); \
             the desktop window is not the problem",
            bridge["self_probe_failures"], bridge["port"]
        ),
        "degraded" => format!(
            "the bridge missed its own probe {} time(s) on 127.0.0.1:{}",
            bridge["self_probe_failures"], bridge["port"]
        ),
        _ => match status["last_seen_secs"].as_u64() {
            Some(seconds) => format!("nothing has polled the bridge (127.0.0.1:{}) for {seconds}s", bridge["port"]),
            None => format!("nothing has ever polled the bridge (127.0.0.1:{})", bridge["port"]),
        },
    }
}

/// What to do about it — and the window is never to be restarted: it is a client,
/// it reconnects on its own, and two windows split one bridge's commands between
/// them.
fn remedy(status: &Value) -> String {
    let bridge = &status["bridge"];
    if bridge["port"].is_null() {
        return "the controls need a node that serves a window: `wa ui` (or `wa serve`) on the machine whose \
                desktop you want to act on. Use `bash` for work on the node itself."
            .to_string();
    }
    match bridge["health"].as_str().unwrap_or("unknown") {
        "wedged" | "degraded" => {
            "the bridge recovers by itself and the window must not be restarted; \
             the node answers again on its own. Use `bash` for work on the node meanwhile."
                .to_string()
        }
        _ => "the desktop window is closed or its executor stopped. Open it with `wa ui` \
              (never stop the node to do it), or use `bash` for work on the node instead."
            .to_string(),
    }
}

#[cfg(test)]
mod client_diagnosis_tests {
    use super::{diagnosis, remedy};
    use serde_json::json;

    /// Three worlds, three sentences. Collapsing them cost a run: a wedged bridge
    /// was reported as "start the desktop client", which was both wrong and a way
    /// to end up with two windows polling one bridge.
    #[test]
    fn each_state_is_diagnosed_as_itself() {
        // 1. No bridge in this process at all.
        let none = json!({ "connected": false, "last_seen_secs": null, "bridge": { "port": null, "health": "unknown" } });
        assert!(diagnosis(&none).contains("no client-tools bridge"), "{}", diagnosis(&none));
        assert!(remedy(&none).contains("wa ui"));

        // 2. A served node with a healthy bridge and nothing polling.
        let idle = json!({ "connected": false, "last_seen_secs": 12, "bridge": { "port": 8800, "health": "ok", "self_probe_failures": 0 } });
        assert!(diagnosis(&idle).contains("nothing has polled the bridge"), "{}", diagnosis(&idle));
        assert!(diagnosis(&idle).contains("8800"), "the port must be in the message");
        assert!(remedy(&idle).contains("wa ui"));

        // 3. A wedged bridge, with a window that is fine.
        let wedged = json!({ "connected": false, "last_seen_secs": 300, "bridge": { "port": 8801, "health": "wedged", "self_probe_failures": 3 } });
        assert!(diagnosis(&wedged).contains("not the problem"), "{}", diagnosis(&wedged));
        let fix = remedy(&wedged);
        assert!(fix.contains("must not be restarted"), "{fix}");
        assert!(!fix.contains("wa ui"), "a wedged bridge is not fixed by opening a window: {fix}");
    }
}

/// host.client_status() -> {connected, last_seen_secs, queued}
pub extern "C" fn client_status(l: *mut LuaState) -> c_int {
    let host = host_of(l);
    push_json(l, &host.client.status());
    1
}

/// host.node_identity() -> {node_id, public_key}
pub extern "C" fn node_identity(l: *mut LuaState) -> c_int {
    match crate::node::Identity::load() {
        Ok(identity) => push_json(
            l,
            &json!({"node_id": identity.node_id, "public_key": identity.public_key}),
        ),
        Err(error) => push_json(l, &json!({"error": error})),
    }
    1
}

/// host.sign(text) -> {signature}
pub extern "C" fn sign(l: *mut LuaState) -> c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    match crate::node::Identity::load() {
        Ok(identity) => push_json(l, &json!({"signature": identity.sign(&text)})),
        Err(error) => push_json(l, &json!({"error": error})),
    }
    1
}

/// host.verify(public_key, text, signature) -> boolean
pub extern "C" fn verify(l: *mut LuaState) -> c_int {
    let public_key = arg_string(l, 1).unwrap_or_default();
    let text = arg_string(l, 2).unwrap_or_default();
    let signature = arg_string(l, 3).unwrap_or_default();
    let ok = crate::node::verify(&public_key, &text, &signature);
    unsafe { crate::lua::lua_pushboolean(l, ok as c_int) };
    1
}

/// host.sleep(milliseconds) — used between deterministic spell steps.
pub extern "C" fn sleep(l: *mut LuaState) -> c_int {
    let millis = arg_string(l, 1)
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(0)
        .min(10_000);
    std::thread::sleep(std::time::Duration::from_millis(millis));
    0
}

/// host.log(message)
/// Mask credentials in a string on the way out of the host.
///
/// A Rust-side twin of `lua/core/redact.lua`, for the paths that never touch
/// Lua: host logging and process-level errors. Two implementations is one more
/// than ideal, but the alternative is a capability call from inside `log`,
/// which already runs with the Lua state locked.
pub fn redact(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for (index, word) in text.split(' ').enumerate() {
        if index > 0 {
            out.push(' ');
        }
        match word.split_once('=') {
            Some((name, value)) if is_secret_name(name) => {
                out.push_str(name);
                out.push('=');
                out.push_str(&mask(value));
            }
            _ => {
                if word.starts_with("sk-") && word.len() > 12 {
                    out.push_str(&mask(word));
                } else {
                    out.push_str(word);
                }
            }
        }
    }
    out
}

fn is_secret_name(name: &str) -> bool {
    let upper = name.to_ascii_uppercase().trim_matches('"').to_string();
    ["API_KEY", "APIKEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL"]
        .iter()
        .any(|needle| upper.contains(needle))
}

/// `sk-...7f2a`: enough to tell which key, not enough to use it.
fn mask(value: &str) -> String {
    let trimmed = value.trim_matches(|c| c == '"' || c == '\'' || c == ',' || c == '}');
    if trimmed.len() < 12 {
        return "<redacted>".to_string();
    }
    format!("{}...{}", &trimmed[..3], &trimmed[trimmed.len() - 4..])
}

pub extern "C" fn log(l: *mut LuaState) -> c_int {
    if let Some(message) = arg_string(l, 1) {
        eprintln!("[lua] {}", redact(&message));
    }
    0
}

/// host.stream(json) -> push one server-sent event to the connected UI.
pub extern "C" fn stream(l: *mut LuaState) -> c_int {
    if let Some(payload) = arg_string(l, 1) {
        crate::serve::write_event(&payload);
    }
    0
}

/// host.plugins() -> JSON `[{name, description, parameters}, ...]`
pub extern "C" fn plugins(l: *mut LuaState) -> c_int {
    let host = host_of(l);
    let list = host
        .plugins
        .lock()
        .map(|registry| registry.describe_all())
        .unwrap_or_else(|_| json!([]));
    push_json(l, &list);
    1
}

/// host.invoke(name, arguments_json) -> plugin JSON result | {error}
pub extern "C" fn invoke(l: *mut LuaState) -> c_int {
    let host = host_of(l);
    let name = arg_string(l, 1).unwrap_or_default();
    let arguments = arg_string(l, 2).unwrap_or_else(|| "{}".into());
    let outcome = host
        .plugins
        .lock()
        .map_err(|error| error.to_string())
        .and_then(|mut registry| registry.invoke(&name, &arguments).map_err(|error| error.to_string()));
    match outcome {
        Ok(text) => unsafe {
            lua_pushlstring(l, text.as_ptr() as *const c_char, text.len());
        },
        Err(error) => push_json(l, &json!({"error": error})),
    }
    1
}

/// host.http(method, url, headers_json, body) -> {status, body} | {error}
pub extern "C" fn http(l: *mut LuaState) -> c_int {
    let method = arg_string(l, 1).unwrap_or_else(|| "POST".into()).to_uppercase();
    let url = arg_string(l, 2).unwrap_or_default();
    let headers_json = arg_string(l, 3).unwrap_or_else(|| "{}".into());
    let body = arg_string(l, 4).unwrap_or_default();
    let headers = parse_headers(&headers_json);
    // Every request here carries a connect/response/read timeout, so it is bounded work.
    // A child's deadline narrows the read; a child that has been cancelled returns
    // before opening a connection at all.
    if run_cancel_requested() {
        push_json(l, &json!({"error": "run_cancelled"}));
        return 1;
    }
    let _heartbeat = crate::serve::Heartbeat::start();
    let outcome = (|| -> Result<Value, String> {
        let response = match method.as_str() {
            "GET" => {
                let mut request = agent_for_call().get(&url);
                for (key, value) in &headers {
                    request = request.header(key, value);
                }
                request.call().map_err(|e| e.to_string())?
            }
            "POST" => {
                let mut request = agent_for_call().post(&url);
                for (key, value) in &headers {
                    request = request.header(key, value);
                }
                request.send(body.as_bytes()).map_err(|e| e.to_string())?
            }
            other => return Err(format!("method_not_supported:{other}")),
        };
        let status = response.status().as_u16();
        let text = response.into_body().read_to_string().map_err(|e| e.to_string())?;
        Ok(json!({"status": status, "body": text}))
    })();
    push_json(l, &outcome.unwrap_or_else(|error| json!({"error": error})));
    crate::subagents::clear_active_socket();
    1
}

/// host.beat() -> nil. Proof of life from inside the Lua loop.
///
/// The accept thread answers /health without the interpreter, so without this a node
/// whose run loop is stuck cannot be distinguished from an idle one. The loop calls it
/// at each run and tool boundary; a long tool call or a stalled provider read is then
/// visible as silence rather than as health.
#[no_mangle]
pub extern "C" fn beat(_l: *mut LuaState) -> c_int {
    crate::serve::beat();
    0
}

// ---- the one line that keeps moving ----------------------------------------------

/// The line the CLI's ticker is drawing, and where its cycle is.
struct TickerSpec {
    line: String,
    marks: Vec<String>,
    started: f64,
    frame: usize,
}

struct Ticker {
    spec: std::sync::Arc<Mutex<TickerSpec>>,
    /// Set once, and every waiter is woken: the caller that stops the ticker is about to
    /// write on the same line, so it must not have to wait out a tick to do it.
    stop: std::sync::Arc<(Mutex<bool>, std::sync::Condvar)>,
    thread: std::thread::JoinHandle<()>,
}

/// One ticker per process: it draws on the process's own terminal, and the only caller is
/// the interactive CLI, which has exactly one status line. A second caller gets the first
/// one's line updated rather than a second writer.
static TICKER: Mutex<Option<Ticker>> = Mutex::new(None);

/// pi redraws its status line about this often; the clock moves in tenths, so anything
/// slower than this reads as a stutter rather than as motion.
const TICKER_INTERVAL_MS: u64 = 90;

fn ticker_seconds() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// The clock the ticker draws, and the twin of `cli_view.duration` in Lua.
///
/// Two implementations is one more than ideal - the same trade `redact` above makes - but
/// the alternative is worse: the elapsed time of a call that has not finished yet cannot be
/// computed by the side that is blocked, so this rule has to exist here or not at all.
/// Both sides pin the same three values (`59.9s`, `1m00s`, `2m05s`) in their own tests, so a
/// change to one that is not made to the other fails a test rather than a frame of video.
fn ticker_duration(seconds: f64) -> String {
    let value = if seconds.is_finite() && seconds > 0.0 { seconds } else { 0.0 };
    if value < 60.0 {
        format!("{:.1}s", value)
    } else {
        format!("{}m{:02}s", (value / 60.0).floor() as u64, (value % 60.0).floor() as u64)
    }
}

/// One frame of the animated line: `{m}` becomes the next mark, `{t}` the clock.
fn ticker_render(spec: &TickerSpec, ticks: usize) -> String {
    let mark = if spec.marks.is_empty() {
        ""
    } else {
        spec.marks[(spec.frame.wrapping_add(ticks)) % spec.marks.len()].as_str()
    };
    let clock = ticker_duration(ticker_seconds() - spec.started);
    spec.line.replace("{m}", mark).replace("{t}", &clock)
}

/// The columns a line occupies on screen: an escape sequence is an instruction, not characters.
///
/// The status line is padded to the width it last drew, so this has to count what a terminal shows -
/// `\u{1b}[33m` is five bytes and no columns. The count is characters rather than east-asian widths,
/// which is what `cli_view.columns` does on the Lua side: the two numbers are compared with each
/// other (the view pads its own frames, the ticker pads its own), so they have to agree with each
/// other and not to be exactly right.
fn visible_width(text: &str) -> usize {
    let mut cols = 0usize;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            cols += 1;
            continue;
        }
        match chars.peek() {
            // CSI: parameters, then a final byte in `0x40..=0x7e`.
            Some('[') => {
                for c in chars.by_ref().skip(1) {
                    if ('@'..='~').contains(&c) {
                        break;
                    }
                }
            }
            // OSC: runs to BEL (or ST, which the callers here do not emit).
            Some(']') => {
                for c in chars.by_ref().skip(1) {
                    if c == '\u{7}' {
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    cols
}

/// One in-place frame of the status line, bounded to the columns the previous frame drew.
///
/// The row this draws on is the row the reader types on: a run is exactly when they type, the
/// terminal echoes at the cursor, and the cursor sits at the end of this line. So the frame
/// rewrites the columns it drew (padding a shorter line with spaces instead of erasing to the end
/// of the row, which erases the message the reader is halfway through typing) and, when it needs
/// more room than it drew, commits the row with a newline and starts again below rather than writing
/// over columns that may hold their text.
///
/// The cursor is saved and restored around the frame (`ESC 7` / `ESC 8`), because the cursor is also
/// where the reader's next keystroke lands. A terminal that ignores those leaves the cursor at the
/// end of the frame: that garbles the display of a line typed during a run and loses nothing - the
/// line is read from the reader thread, never from the screen. `cli_view.status_draw` obeys the same
/// rule on the Lua side, because the view writes this line too.
fn ticker_frame(text: &str, drawn: usize) -> (String, usize) {
    let cols = visible_width(text);
    let mut drawn = drawn;
    let mut frame = String::new();
    if drawn > 0 && cols > drawn {
        frame.push_str("\r\n");
        drawn = 0;
    }
    frame.push_str("\u{1b}7\r");
    frame.push_str(text);
    for _ in cols..drawn {
        frame.push(' ');
    }
    frame.push_str("\u{1b}8");
    (frame, drawn.max(cols))
}

/// `WASM_AGENT_CLI_TICKER=off` leaves the caller's escape sequences alone and stops the
/// motion, which is what a capture that wants a byte-exact transcript needs.
fn ticker_enabled() -> bool {
    !matches!(
        std::env::var("WASM_AGENT_CLI_TICKER").unwrap_or_default().to_ascii_lowercase().as_str(),
        "off" | "0" | "false" | "no"
    )
}

/// Stop the ticker and wait for its last frame to land: the caller is about to write to the
/// same line, and two writers is how a status line turns into two half-lines.
fn stop_ticker() -> bool {
    let running = {
        let mut slot = TICKER.lock().unwrap_or_else(|error| error.into_inner());
        slot.take()
    };
    match running {
        None => false,
        Some(ticker) => {
            {
                let (flag, signal) = &*ticker.stop;
                *flag.lock().unwrap_or_else(|error| error.into_inner()) = true;
                signal.notify_all();
            }
            let _ = ticker.thread.join();
            true
        }
    }
}

fn start_ticker(spec: TickerSpec) -> bool {
    use std::io::Write;
    let mut slot = TICKER.lock().unwrap_or_else(|error| error.into_inner());
    if let Some(running) = slot.as_ref() {
        // Already ticking (the same run, a new phase): move the line rather than restart it.
        *running.spec.lock().unwrap_or_else(|error| error.into_inner()) = spec;
        return true;
    }
    let spec = std::sync::Arc::new(Mutex::new(spec));
    let stop = std::sync::Arc::new((Mutex::new(false), std::sync::Condvar::new()));
    let thread = {
        let spec = std::sync::Arc::clone(&spec);
        let stop = std::sync::Arc::clone(&stop);
        std::thread::spawn(move || {
            let (flag, signal) = &*stop;
            let mut ticks = 0usize;
            // How many columns the last frame drew. A frame may rewrite those and no others, so
            // this is the only state the motion needs - see `ticker_frame`.
            let mut drawn = 0usize;
            loop {
                let text = {
                    let guard = spec.lock().unwrap_or_else(|error| error.into_inner());
                    ticker_render(&guard, ticks)
                };
                let (frame, cols) = ticker_frame(&text, drawn);
                drawn = cols;
                // Never erase to the end of the row: the reader's own typing starts one column
                // after this line ends, and erasing from the cursor to the right takes it with it.
                // Flushed every time: this text has no newline to flush it.
                let mut out = std::io::stdout();
                let _ = write!(out, "{frame}");
                let _ = out.flush();
                ticks = ticks.wrapping_add(1);
                let guard = flag.lock().unwrap_or_else(|error| error.into_inner());
                if *guard {
                    break;
                }
                let (guard, _) = signal
                    .wait_timeout(guard, std::time::Duration::from_millis(TICKER_INTERVAL_MS))
                    .unwrap_or_else(|error| error.into_inner());
                if *guard {
                    break;
                }
            }
        })
    };
    *slot = Some(Ticker { spec, stop, thread });
    true
}

/// host.ticker(spec_json) -> true | nil
///
/// `wa chat` keeps one status line on screen for as long as a run is in flight, and until
/// this existed that line only moved when an event arrived. The reason is structural, not
/// cosmetic: the whole model call happens inside `host.http_stream`, so the interpreter is
/// blocked for its duration and nothing on the Lua side can repaint - a slow call showed a
/// frozen spinner frame and a clock that had stopped, which is exactly what a hung run looks
/// like. pi has no such problem because its UI is an event loop that redraws on a timer; the
/// equivalent here is a timer on the *host* side, which is what this is.
///
/// The contract leaves the line to Lua. `line` is the line to draw with exactly two tokens
/// left in it, and the host fills only those:
///
/// ```text
/// {m}  one of `marks` (a JSON array of strings), cycled once per tick
/// {t}  the seconds since `started`, in the shape `cli_view.duration` uses
/// ```
///
/// Every other character - the indent, the words, the separators, the round counter - is
/// the caller's text, so the line the host animates and the line the view prints for itself
/// cannot drift apart. `frame` is where the mark cycle continues from, so an event that
/// redraws the line does not make the spinner jump back to its first frame.
///
/// No argument, or `nil`, stops it: the ticker stops drawing and leaves the line as the
/// caller's to erase, which is what the view does before it prints anything else. Returns
/// `true` while a ticker is running, and `nil` when none is (no argument, a spec that does
/// not parse, or `WASM_AGENT_CLI_TICKER=off`).
pub extern "C" fn ticker(l: *mut LuaState) -> c_int {
    let running = match arg_string(l, 1).and_then(|text| parse_ticker_spec(&text)) {
        // No argument is a stop, not a no-op: the caller is about to draw on that line
        // itself, and a ticker still running would fight it for the cursor.
        None => {
            stop_ticker();
            false
        }
        Some(spec) => ticker_enabled() && start_ticker(spec),
    };
    if running {
        unsafe { crate::lua::lua_pushboolean(l, 1) };
    } else {
        unsafe { crate::lua::lua_pushnil(l) };
    }
    1
}

fn parse_ticker_spec(text: &str) -> Option<TickerSpec> {
    let value: Value = serde_json::from_str(text).ok()?;
    let line = value.get("line")?.as_str()?.to_string();
    let marks = value
        .get("marks")
        .and_then(|marks| marks.as_array())
        .map(|items| items.iter().filter_map(|item| item.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    let started = value.get("started").and_then(Value::as_f64).unwrap_or_else(ticker_seconds);
    let frame = value.get("frame").and_then(Value::as_u64).unwrap_or(0) as usize;
    Some(TickerSpec { line, marks, started, frame })
}

#[cfg(test)]
mod ticker_tests {
    use super::*;

    fn spec(line: &str, frame: usize) -> TickerSpec {
        TickerSpec { line: line.to_string(), marks: vec!["one ".to_string(), "two ".to_string()], started: ticker_seconds(), frame }
    }

    /// The same three values `scripts/test-cli-view.lua` pins for `cli_view.duration`:
    /// the rule may not change on one side only, so a change that forgets the other fails
    /// here rather than on a screen.
    #[test]
    fn the_clock_is_the_views_clock() {
        assert_eq!(ticker_duration(0.0), "0.0s");
        assert_eq!(ticker_duration(59.94), "59.9s");
        assert_eq!(ticker_duration(60.0), "1m00s");
        assert_eq!(ticker_duration(125.4), "2m05s");
        // A clock is not allowed to read backwards, whatever it is handed.
        assert_eq!(ticker_duration(-4.0), "0.0s");
        assert_eq!(ticker_duration(f64::NAN), "0.0s");
    }

    #[test]
    fn a_frame_fills_both_tokens_and_leaves_none() {
        let line = ticker_render(&spec("  {m}Thinking - {t}", 0), 0);
        assert!(line.starts_with("  one Thinking"), "the mark and the words are the caller's: {line}");
        assert!(!line.contains("{m}") && !line.contains("{t}"), "no token survives: {line}");
        // The cycle continues from `frame`: an event that redraws the line must not send the
        // spinner back to its first frame.
        let started_at = ticker_render(&spec("  {m}{t}", 1), 0);
        assert!(started_at.starts_with("  two "), "a frame offset is where the cycle starts: {started_at}");
        let cycled = ticker_render(&spec("  {m}{t}", 0), 2);
        assert!(cycled.starts_with("  one "), "ticks wrap around the marks: {cycled}");
    }

    #[test]
    fn a_spec_is_read_or_refused_never_guessed() {
        // Built rather than pasted: the marks are real braille in the source, so no escape
        // has to survive both Rust and JSON.
        let spec_json = format!(
            "{{\"line\":\"  {{m}}Thinking - {{t}}\",\"marks\":[\"{mark} \",\"{next} \"],\"started\":120.5,\"frame\":7}}",
            mark = '\u{280b}',
            next = '\u{2819}'
        );
        let parsed = parse_ticker_spec(&spec_json).expect("a well-formed spec parses");
        assert_eq!(parsed.marks.len(), 2);
        assert_eq!(parsed.marks[0], format!("{} ", '\u{280b}'));
        assert_eq!(parsed.started, 120.5);
        assert_eq!(parsed.frame, 7);
        // No line is no line to draw: refused, rather than drawn empty or drawn wrong.
        assert!(parse_ticker_spec("{\"marks\":[\"x \"]}").is_none());
        assert!(parse_ticker_spec("not json").is_none());
        // A missing `started` is "now": a line with no clock in it is still a line.
        assert!(parse_ticker_spec("{\"line\":\"{t}\"}").is_some());
    }

    /// The reader types on the row this frame is drawn on, so the frame is bounded twice: it may
    /// only write columns it drew, and it may only need more room by committing the row.
    #[test]
    fn a_frame_never_erases_and_never_takes_the_readers_columns() {
        // The defect this replaced: erase-to-end-of-line wipes the reader's half-typed message,
        // which sits one column after the line.
        let (frame, cols) = ticker_frame("  {m}Thinking - {t}", 0);
        assert!(!frame.contains("\u{1b}[2K"), "erase-to-end-of-line is gone: {frame:?}");
        assert!(frame.starts_with("\u{1b}7\r"), "the cursor is saved before the write: {frame:?}");
        assert!(frame.ends_with("\u{1b}8"), "and restored after it: {frame:?}");
        assert_eq!(cols, visible_width("  {m}Thinking - {t}"));

        // A shorter line pads the columns it drew, so no tail of the last frame is left behind.
        let (shorter, cols) = ticker_frame("  short", 12);
        assert!(shorter.contains("  short     "), "a shorter line is padded: {shorter:?}");
        assert_eq!(cols, 12, "and the high-water mark stands, so the pad is not drawn again");

        // A longer line commits the row instead of writing over columns that may hold the
        // reader's text.
        let (longer, cols) = ticker_frame("  a longer line than before", 12);
        assert!(longer.starts_with("\r\n"), "growth starts a fresh row: {longer:?}");
        assert_eq!(cols, visible_width("  a longer line than before"));

        // The first frame has nothing to commit: it starts on the row the cursor is already on.
        let (first, _) = ticker_frame("  {m}", 0);
        assert!(!first.starts_with("\r\n"), "the first frame does not add a line: {first:?}");
    }

    /// Colour is an instruction, not columns: the pad is measured against what a terminal shows.
    #[test]
    fn a_columns_count_is_what_the_terminal_shows() {
        assert_eq!(visible_width("abc"), 3);
        assert_eq!(visible_width("\u{1b}[33mabc\u{1b}[0m"), 3);
        assert_eq!(visible_width("\u{1b}]2;title\u{7}ab"), 2);
        assert_eq!(visible_width("\u{1b}[1;2H"), 0);
        // A multi-byte character is one column here, as it is in `cli_view.columns`.
        assert_eq!(visible_width("\u{280b}"), 1);
    }
}

/// host.http_stream(method, url, headers_json, body) -> aggregated completion.
///
/// Reads an OpenAI-compatible SSE stream, forwards each content delta to the UI
/// (server-sent event `delta`), and returns `{status, content, reasoning,
/// finish_reason, tool_calls, usage}` so the caller can continue the tool loop.
/// Reasoning is kept apart from content: it is the model's thinking, not its
/// answer, and conflating the two is how an unanswered run looks answered.
pub extern "C" fn http_stream(l: *mut LuaState) -> c_int {
    let method = arg_string(l, 1).unwrap_or_else(|| "POST".into()).to_uppercase();
    let url = arg_string(l, 2).unwrap_or_default();
    let headers_json = arg_string(l, 3).unwrap_or_else(|| "{}".into());
    let body = arg_string(l, 4).unwrap_or_default();
    let headers = parse_headers(&headers_json);
    let outcome = stream_completion(&method, &url, &headers, &body);
    match outcome {
        Ok(value) => push_json(l, &value),
        Err(error) => push_json(l, &json!({"error": error})),
    }
    1
}

/// host.relay(url, headers_json, body) -> {status}
///
/// POSTs to a peer and forwards every SSE `data:` line straight to our UI
/// client, so a remote node's reply streams here unchanged.
pub extern "C" fn relay(l: *mut LuaState) -> c_int {
    let url = arg_string(l, 1).unwrap_or_default();
    let headers_json = arg_string(l, 2).unwrap_or_else(|| "{}".into());
    let body = arg_string(l, 3).unwrap_or_default();
    let headers = parse_headers(&headers_json);
    let outcome = (|| -> Result<Value, String> {
        let mut request = agent().post(&url);
        for (key, value) in &headers {
            request = request.header(key, value);
        }
        let response = request.send(body.as_bytes()).map_err(|error| error.to_string())?;
        let status = response.status().as_u16();
        if status != 200 {
            let text = response.into_body().read_to_string().unwrap_or_default();
            return Ok(json!({"status": status, "body": text.chars().take(400).collect::<String>()}));
        }
        use std::io::BufRead;
        let reader = std::io::BufReader::new(response.into_body().into_reader());
        for line in reader.lines() {
            let line = line.map_err(|error| error.to_string())?;
            if let Some(data) = line.strip_prefix("data: ") {
                crate::serve::write_event(data);
            }
        }
        Ok(json!({"status": 200}))
    })();
    push_json(l, &outcome.unwrap_or_else(|error| json!({"error": error})));
    1
}

fn stream_completion(method: &str, url: &str, headers: &[(String, String)], body: &str) -> Result<Value, String> {
    use std::io::BufRead;
    let started = std::time::Instant::now();
    let mut ttft_ms: Option<u128> = None;
    let mut request_id: Option<String> = None;
    if method != "POST" {
        return Err("method_not_supported".into());
    }
    // Same reasoning as `run_bounded`: a provider read is bounded by the connect/response/read
    // timeouts on the agent, so a run waiting on a slow model is not a stalled node.
    let _heartbeat = crate::serve::Heartbeat::start();
    if run_cancel_requested() {
        crate::subagents::clear_active_socket();
        return Err("run_cancelled".into());
    }
    let mut request = agent_for_call().post(url);
    for (key, value) in headers {
        request = request.header(key, value);
    }
    let response = request.send(body.as_bytes()).map_err(|error| error.to_string())?;
    let status = response.status().as_u16();
    if status != 200 {
        let text = response.into_body().read_to_string().unwrap_or_default();
        return Ok(json!({"status": status, "content": "", "tool_calls": [], "body": text}));
    }
    let reader = std::io::BufReader::new(response.into_body().into_reader());
    let mut content = String::new();
    // Reasoning models stream their thinking in a sibling field, and endpoints
    // spell it differently. pi reads all three and takes the first non-empty one,
    // which is also what we do - the field is not an answer, but a run that spends
    // its whole budget here answers nothing, and that has to be visible.
    let mut reasoning = String::new();
    let mut finish_reason: Option<String> = None;
    let mut tool_calls: Vec<Value> = Vec::new();
    let mut usage: Option<Value> = None;
    // Stream-termination telemetry.
    //
    // `stream_complete: false` reduced every ending to "no finish_reason", which cannot distinguish a
    // provider that cut the stream from a reader that failed to parse the end - and those have different
    // fixes. These fields answer the question the failure raises: did it end with `[DONE]` or at EOF, did a
    // finish reason and a usage chunk arrive, how many events were unparseable, how many chunks arrived, and
    // was the stream still flowing or already silent at the end.
    //
    // Payload-free by design: counts, kinds and timings, never content. A read error still propagates as an
    // error (and carries its own text to the caller); this covers the endings that produce no error at all,
    // which is exactly the case that was invisible.
    let mut saw_done = false;
    let mut saw_finish_reason = false;
    let mut malformed_events = 0u64;
    let mut chunks = 0u64;
    let mut last_delta_kind = "";
    let mut last_delta_ms: Option<u64> = None;
    let mut max_gap_ms = 0u64;
    for line in reader.lines() {
        // A cancelled run or child stops reading its provider stream at the next
        // chunk; a silent provider is woken by the socket shutdown the cancel path
        // performs. The read is bounded by the child's remaining budget through
        // `agent_for_call`.
        if run_cancel_requested() {
            crate::subagents::clear_active_socket();
            return Err("run_cancelled".into());
        }
        let line = line.map_err(|error| error.to_string())?;
        let Some(data) = line.trim().strip_prefix("data:") else { continue };
        let data = data.trim();
        if data.is_empty() {
            continue;
        }
        if data == "[DONE]" {
            saw_done = true;
            break;
        }
        let chunk: Value = match serde_json::from_str(data) {
            Ok(value) => value,
            // Counted rather than skipped in silence: an unparseable event is a reader-side fact, and a
            // stream that ends "without a finish reason" because we dropped the chunk carrying it looks
            // exactly like a provider that cut the stream.
            Err(_) => { malformed_events += 1; continue },
        };
        chunks += 1;
        // When a delta arrives, and what kind it was: this is what says whether the stream was flowing or
        // already silent when it ended. A gap is only meaningful between deltas; the gap *after* the last one
        // is measured at the end, below.
        let mut mark_delta = |kind: &'static str, now_ms: u64| {
            if let Some(previous) = last_delta_ms {
                max_gap_ms = max_gap_ms.max(now_ms.saturating_sub(previous));
            }
            last_delta_ms = Some(now_ms);
            last_delta_kind = kind;
        };
        let elapsed_ms = started.elapsed().as_millis() as u64;
        if let Some(id) = chunk["id"].as_str() { request_id = Some(id.to_string()); }
        let delta = &chunk["choices"][0]["delta"];
        if ttft_ms.is_none() && (["content", "reasoning_content", "reasoning", "reasoning_text"]
            .iter().any(|field| delta[*field].as_str().is_some_and(|s| !s.is_empty()))
            || delta["tool_calls"].as_array().is_some_and(|a| !a.is_empty())) {
            ttft_ms = Some(started.elapsed().as_millis());
        }
        if let Some(text) = chunk["choices"][0]["delta"]["content"].as_str() {
            if !text.is_empty() {
                content.push_str(text);
                mark_delta("answer", elapsed_ms);
                crate::serve::write_event(&json!({"type": "delta", "text": text}).to_string());
            }
        }
        for field in ["reasoning_content", "reasoning", "reasoning_text"] {
            if let Some(text) = chunk["choices"][0]["delta"][field].as_str() {
                if !text.is_empty() {
                    reasoning.push_str(text);
                    mark_delta("reasoning", elapsed_ms);
                    // A long reasoning phase used to look like a hung run. The event carries
                    // the delta itself, not only its size: a reader can now see the thinking,
                    // and the count still drives the live "not hung" status line.
                    crate::serve::write_event(
                        &json!({"type": "reasoning", "chars": reasoning.chars().count(), "text": text})
                            .to_string(),
                    );
                }
                break;
            }
        }
        if let Some(reason) = chunk["choices"][0]["finish_reason"].as_str() {
            finish_reason = Some(reason.to_string());
            saw_finish_reason = true;
        }
        if let Some(calls) = chunk["choices"][0]["delta"]["tool_calls"].as_array() {
            if !calls.is_empty() {
                mark_delta("tool_calls", elapsed_ms);
            }
            for call in calls {
                let index = call["index"].as_u64().unwrap_or(0) as usize;
                while tool_calls.len() <= index {
                    tool_calls.push(json!({"id": "", "type": "function", "function": {"name": "", "arguments": ""}}));
                }
                if let Some(id) = call["id"].as_str() {
                    tool_calls[index]["id"] = json!(id);
                }
                if let Some(name) = call["function"]["name"].as_str() {
                    tool_calls[index]["function"]["name"] = json!(name);
                }
                if let Some(arguments) = call["function"]["arguments"].as_str() {
                    let previous = tool_calls[index]["function"]["arguments"].as_str().unwrap_or("").to_string();
                    tool_calls[index]["function"]["arguments"] = json!(format!("{previous}{arguments}"));
                }
            }
        }
        if chunk["usage"].is_object() {
            usage = Some(chunk["usage"].clone());
        }
    }
    Ok(json!({"status": status, "content": content, "reasoning": reasoning,
        "stream_complete": finish_reason.is_some(), "ttft_ms": ttft_ms, "request_id": request_id,
        "finish_reason": finish_reason, "tool_calls": tool_calls, "usage": usage,
        // Termination telemetry: how it ended, what arrived, and whether it was still talking.
        "termination": if saw_done { "done" } else { "eof" },
        "saw_done_sentinel": saw_done,
        "saw_finish_reason": saw_finish_reason,
        "saw_usage": usage.is_some(),
        "malformed_events": malformed_events,
        "chunks": chunks,
        "last_delta_kind": last_delta_kind,
        "max_gap_ms": max_gap_ms,
        "last_delta_to_end_ms": last_delta_ms.map(|ms| started.elapsed().as_millis() as u64 - ms),
        "ended_silent": last_delta_ms.map(|ms| started.elapsed().as_millis() as u64 - ms >= 10_000).unwrap_or(false),
    }))
}

/// host.now() -> seconds since epoch
pub extern "C" fn monotonic_ms(l: *mut LuaState) -> c_int {
    static START: OnceLock<std::time::Instant> = OnceLock::new();
    let ms = START.get_or_init(std::time::Instant::now).elapsed().as_secs_f64() * 1000.0;
    unsafe { crate::lua::lua_pushnumber(l, ms) };
    1
}

pub extern "C" fn runtime_info(l: *mut LuaState) -> c_int {
    static IDENTITY: OnceLock<Value> = OnceLock::new();
    let identity = IDENTITY.get_or_init(|| {
        let digest = std::env::current_exe().ok().and_then(|path| std::fs::read(path).ok())
            .map(|bytes| ring::digest::digest(&ring::digest::SHA256, &bytes).as_ref()
                .iter().map(|b| format!("{b:02x}")).collect::<String>());
        json!({"version": env!("CARGO_PKG_VERSION"), "binary_sha256": digest,
            "process_id": std::process::id(), "os": std::env::consts::OS,
            "arch": std::env::consts::ARCH})
    });
    push_json(l, identity);
    1
}

/// `host.terminal_size()` -> `{columns, rows}` for the console this process draws on, or `nil`.
///
/// The width a terminal *has* is not the width a child *knows*. `COLUMNS` is a shell variable on most
/// machines and is not exported to children, so a CLI that wraps to `COLUMNS or 80` renders in an
/// 80-column column inside a 120-column window and leaves the rest of the screen empty. That is a
/// measurement, not a guess: Orca's terminal reports `Columns: 120` while `COLUMNS` is empty in the
/// environment the CLI is launched with.
///
/// `nil` - never a zero - when there is no console or it will not answer: a pipe, a file, a captured
/// transcript, a CI log. A caller that cannot tell "unknown" from "80 wide" wraps to nothing, so the
/// difference is the whole contract.
#[cfg(windows)]
fn console_size() -> Option<(i32, i32)> {
    use std::ffi::c_void;
    #[repr(C)]
    #[derive(Default)]
    struct Coord {
        x: i16,
        y: i16,
    }
    #[repr(C)]
    #[derive(Default)]
    struct SmallRect {
        left: i16,
        top: i16,
        right: i16,
        bottom: i16,
    }
    #[repr(C)]
    #[derive(Default)]
    struct ScreenBufferInfo {
        size: Coord,
        cursor: Coord,
        attributes: u16,
        window: SmallRect,
        maximum: Coord,
    }
    extern "system" {
        fn GetStdHandle(kind: u32) -> *mut c_void;
        fn GetConsoleScreenBufferInfo(handle: *mut c_void, info: *mut ScreenBufferInfo) -> i32;
    }
    // STD_OUTPUT_HANDLE is -11 as a DWORD. Asking about *stdout* is deliberate: when stdout is a
    // file or a pipe (a transcript, a log) this fails and the caller is told `nil` rather than
    // being handed the size of whatever console happens to be attached.
    const STD_OUTPUT_HANDLE: u32 = 0xFFFF_FFF5;
    unsafe {
        let handle = GetStdHandle(STD_OUTPUT_HANDLE);
        if handle.is_null() {
            return None;
        }
        let mut info = ScreenBufferInfo::default();
        if GetConsoleScreenBufferInfo(handle, &mut info) == 0 {
            return None;
        }
        // The *window*, not the buffer: the buffer is usually wider (the scrollback) and taller,
        // and wrapping to it puts text off the right edge of what is on screen.
        usable_size(
            (info.window.right - info.window.left + 1) as i32,
            (info.window.bottom - info.window.top + 1) as i32,
        )
    }
}

#[cfg(unix)]
fn console_size() -> Option<(i32, i32)> {
    #[repr(C)]
    #[derive(Default)]
    struct WinSize {
        rows: u16,
        columns: u16,
        x_pixels: u16,
        y_pixels: u16,
    }
    #[cfg(target_os = "macos")]
    const TIOCGWINSZ: u64 = 0x4008_7468;
    #[cfg(not(target_os = "macos"))]
    const TIOCGWINSZ: u64 = 0x5413;
    extern "C" {
        fn ioctl(fd: c_int, request: u64, ...) -> c_int;
    }
    let mut size = WinSize::default();
    // fd 1 is stdout, for the same reason as the Windows branch above.
    let answered = unsafe { ioctl(1, TIOCGWINSZ, &mut size as *mut WinSize) } == 0;
    if !answered {
        return None;
    }
    usable_size(size.columns as i32, size.rows as i32)
}

#[cfg(not(any(windows, unix)))]
fn console_size() -> Option<(i32, i32)> {
    None
}

/// A console that answers zero is not a console that is zero wide. An uninitialized or detached
/// screen buffer reports all zeros, and a caller told `{columns: 0}` wraps every line to nothing -
/// the failure would be a blank screen, which is worse than the 80-column fallback it replaced.
fn usable_size(columns: i32, rows: i32) -> Option<(i32, i32)> {
    if columns <= 0 || rows <= 0 {
        return None;
    }
    Some((columns, rows))
}

pub extern "C" fn terminal_size(l: *mut LuaState) -> c_int {
    match console_size() {
        Some((columns, rows)) => push_json(l, &json!({"columns": columns, "rows": rows})),
        None => unsafe { crate::lua::lua_pushnil(l) },
    }
    1
}

// ---- input that arrives while the interpreter is blocked --------------------------------

/// What the reader has typed and nobody has read yet.
///
/// The CLI's input used to be `io.read("*l")` in the REPL, and that is a read that only ever
/// happens *between* turns: while a run was in flight nothing read stdin at all, so a reader
/// typing their next message typed into nothing. The terminal echoed the characters and the line
/// was then read - or not - by a REPL that was not looking, which is why "you cannot write to me
/// while I work" was true here and is not true of pi or codex.
///
/// So stdin gets a reader of its own, for the life of the process, and Lua takes what arrived when
/// Lua next runs. The console stays in the terminal's own mode: this puts nothing into raw mode
/// and echoes nothing itself, so line editing, the echo and Enter are still the terminal's, as
/// they are for a shell. What changes is who reads the line, and that a line typed during a run is
/// still there when the run ends.
#[derive(Default)]
struct ConsoleInput {
    lines: Vec<String>,
    eof: bool,
    stop: bool,
    running: bool,
}

static CONSOLE_INPUT: OnceLock<(Mutex<ConsoleInput>, std::sync::Condvar)> = OnceLock::new();

fn console_input() -> &'static (Mutex<ConsoleInput>, std::sync::Condvar) {
    CONSOLE_INPUT.get_or_init(|| (Mutex::new(ConsoleInput::default()), std::sync::Condvar::new()))
}

/// Read lines forever, waking anyone waiting each time one lands.
///
/// One reader per process: a second would split the reader's typing between two queues and
/// neither caller would see the whole of it. The stdin lock is taken once, for the same reason.
fn console_reader() {
    use std::io::BufRead;
    let stdin = std::io::stdin();
    let mut handle = stdin.lock();
    let mut line = String::new();
    loop {
        line.clear();
        let read = handle.read_line(&mut line);
        let (lock, wake) = console_input();
        let mut state = match lock.lock() {
            Ok(state) => state,
            Err(_) => return,
        };
        match read {
            // End of input - a closed pipe, a redirected file that ran out, or the reader
            // sending the terminal's own end-of-file. The REPL ends on it, exactly as it ended
            // when `io.read` answered `nil`.
            Ok(0) => {
                state.eof = true;
                state.running = false;
                wake.notify_all();
                return;
            }
            Ok(_) => {
                if state.stop {
                    state.running = false;
                    wake.notify_all();
                    return;
                }
                state.lines.push(line.trim_end_matches(['\n', '\r']).to_string());
                wake.notify_all();
            }
            // A read error is the end of input rather than a lost line: the reader cannot be
            // asked to type it again, and a REPL that keeps prompting for a stream it cannot
            // read is worse than one that stops.
            Err(_) => {
                state.eof = true;
                state.running = false;
                wake.notify_all();
                return;
            }
        }
    }
}

/// `host.input_start()` -> `{started:true}`, or `nil` if the reader cannot be asked.
///
/// Idempotent: a caller that starts twice gets one reader and one `true`, so nothing has to
/// remember whether it already did.
pub extern "C" fn input_start(l: *mut LuaState) -> c_int {
    let (lock, _) = console_input();
    match lock.lock() {
        Ok(mut state) => {
            if state.running {
                push_json(l, &json!({"started": true}));
                return 1;
            }
            state.running = true;
            state.stop = false;
        }
        Err(_) => {
            unsafe { crate::lua::lua_pushnil(l) };
            return 1;
        }
    }
    std::thread::spawn(console_reader);
    push_json(l, &json!({"started": true}));
    1
}

/// Wait for a line, the stop flag or the end of input, and hand the lock back.
///
/// A function rather than a loop in `input_take` because the wait consumes the guard and returns
/// it: keeping that in one place is what makes the poisoned-lock path one line instead of a
/// branch that a later `state` read could disagree with.
fn wait_for_input(
    wake: &'static std::sync::Condvar,
    mut state: std::sync::MutexGuard<'static, ConsoleInput>,
    deadline: std::time::Instant,
) -> std::sync::MutexGuard<'static, ConsoleInput> {
    while state.lines.is_empty() && !state.eof && !state.stop {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            break;
        }
        state = match wake.wait_timeout(state, left) {
            Ok((state, _)) => state,
            // A poisoned lock is still a lock, and the lines in it are what the reader typed.
            Err(poisoned) => poisoned.into_inner().0,
        };
    }
    state
}

/// `host.input_take(timeout_ms)` -> `{lines, eof, running}`.
///
/// Waits up to `timeout_ms` for at least one line, and answers immediately with whatever is
/// already buffered - which is what makes a line typed during a run arrive the moment the run
/// ends, with no polling and no lost keystrokes. `timeout_ms` of 0 means "take what is there
/// now", for a caller draining a queue. An empty answer is an array and not a missing value:
/// "nothing typed yet" is not "no console".
pub extern "C" fn input_take(l: *mut LuaState) -> c_int {
    let timeout_ms = arg_integer(l, 1).unwrap_or(0).max(0) as u64;
    let (lock, wake) = console_input();
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(timeout_ms);
    let state = match lock.lock() {
        Ok(state) => state,
        Err(poisoned) => poisoned.into_inner(),
    };
    let mut state = wait_for_input(wake, state, deadline);
    let lines: Vec<String> = state.lines.drain(..).collect();
    let (eof, running) = (state.eof, state.running);
    drop(state);
    push_json(l, &json!({"lines": lines, "eof": eof, "running": running}));
    1
}

/// `host.input_stop()` -> `{stopped:true}`.
///
/// The reader is told to stop and is not joined: it is blocked in a read that no portable call can
/// interrupt, and making the process exit wait for a reader to type one more line is a worse
/// answer than leaving one thread to die with the process it belongs to. A caller that stops and
/// starts again gets its lines, never a second reader.
pub extern "C" fn input_stop(l: *mut LuaState) -> c_int {
    let (lock, wake) = console_input();
    if let Ok(mut state) = lock.lock() {
        state.stop = true;
        wake.notify_all();
    }
    push_json(l, &json!({"stopped": true}));
    1
}

#[cfg(test)]
mod terminal_tests {
    use super::usable_size;

    /// The rule that keeps a detached console from blanking the screen, and the values a real
    /// terminal reports. Written as the three cases because the middle one is the whole point:
    /// `ioctl` and `GetConsoleScreenBufferInfo` both answer "succeeded, zero by zero" rather than
    /// failing when nothing is attached, and that answer must not become a width.
    #[test]
    fn a_zero_sized_console_is_not_a_width() {
        assert_eq!(usable_size(120, 40), Some((120, 40)));
        assert_eq!(usable_size(0, 0), None);
        assert_eq!(usable_size(-1, 40), None);
        assert_eq!(usable_size(120, 0), None);
    }
}

/// Wall clock is for correlating events, never calculating durations.
pub extern "C" fn now(l: *mut LuaState) -> c_int {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    unsafe { crate::lua::lua_pushnumber(l, seconds) };
    1
}

/// `host.exec_timeout()` -> the deadline a `bash`/`shell` call is given, in seconds.
///
/// Reported rather than duplicated. A run can spend 300 seconds inside one command and, until this
/// existed, nothing said so: the trace showed a line that had not come back yet, and the only signal
/// was the call being killed five minutes later - which reads as the agent being stuck rather than
/// as a deadline that was always there. The number lives here because this is where it is enforced;
/// anything showing it to a person reads it from here.
pub extern "C" fn exec_timeout(l: *mut LuaState) -> c_int {
    let seconds = exec_timeout_seconds();
    unsafe { crate::lua::lua_pushnumber(l, seconds as f64) };
    1
}

#[cfg(test)]
mod stream_tests {
    use super::*;
    use std::io::{Read, Write};

    fn fixture(body: &str) -> Value {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let body = body.to_owned();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket.set_read_timeout(Some(std::time::Duration::from_secs(5))).unwrap();
            let mut headers = Vec::new();
            while !headers.ends_with(b"\r\n\r\n") {
                let mut byte = [0u8]; socket.read_exact(&mut byte).unwrap(); headers.push(byte[0]);
                assert!(headers.len() < 16384);
            }
            let size = String::from_utf8_lossy(&headers).lines()
                .find_map(|line| line.to_ascii_lowercase().strip_prefix("content-length:")
                    .and_then(|n| n.trim().parse::<usize>().ok())).unwrap_or(0);
            let mut request = vec![0; size]; socket.read_exact(&mut request).unwrap();
            let response = format!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body);
            socket.write_all(response.as_bytes()).unwrap();
        });
        let result = stream_completion("POST", &format!("http://{address}/fixture"), &[], "{}").unwrap();
        server.join().unwrap();
        result
    }

    #[test]
    fn stream_records_usage_identity_and_first_delta_time() {
        let result = fixture(concat!(
            "data: {\"id\":\"fixture-id\",\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"answer\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":20}}\n\n",
            "data: [DONE]\n\n"));
        assert_eq!(result["stream_complete"], true);
        assert_eq!(result["request_id"], "fixture-id");
        assert_eq!(result["content"], "answer");
        assert_eq!(result["reasoning"], "thinking");
        assert_eq!(result["usage"]["prompt_tokens"], 100);
        assert!(result["ttft_ms"].is_number());
    }

    #[test]
    fn reasoning_deltas_carry_their_text_to_the_client() {
        // The count alone told the reader *how much* thinking happened but never what it was,
        // so a turn whose content was entirely reasoning rendered as a turn that only called
        // tools. The streamed event now carries the delta.
        let result = std::cell::RefCell::new(Value::Null);
        let events = crate::serve::capture_events(|| {
            *result.borrow_mut() = fixture(concat!(
                "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}\n\n",
                "data: {\"choices\":[{\"delta\":{\"content\":\"answer\"},\"finish_reason\":\"stop\"}]}\n\n",
                "data: [DONE]\n\n"));
        });
        assert_eq!(result.into_inner()["reasoning"], "thinking");
        assert!(events.contains("\"type\":\"reasoning\""), "no reasoning event in: {events}");
        assert!(events.contains("\"text\":\"thinking\""), "the event must carry the delta: {events}");
        assert!(events.contains("\"chars\":8"), "the event must still carry the count: {events}");
    }

    #[test]
    fn termination_telemetry_distinguishes_done_from_eof() {
        // The question the failure raises is which ending happened. [DONE] and EOF look identical from
        // stream_complete alone, and they have different fixes.
        let done = fixture(concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"a\"},\"finish_reason\":\"stop\"}]}

",
            "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10}}

",
            "data: [DONE]

"));
        assert_eq!(done["termination"], "done");
        assert_eq!(done["saw_done_sentinel"], true);
        assert_eq!(done["saw_finish_reason"], true);
        assert_eq!(done["saw_usage"], true);
        assert_eq!(done["last_delta_kind"], "answer");
        assert!(done["last_delta_to_end_ms"].is_number());

        let eof = fixture("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}

");
        assert_eq!(eof["termination"], "eof");
        assert_eq!(eof["saw_done_sentinel"], false);
        assert_eq!(eof["saw_finish_reason"], false);
        assert_eq!(eof["saw_usage"], false);
        assert_eq!(eof["ended_silent"], false);
    }

    #[test]
    fn a_finish_reason_only_in_a_choices_empty_chunk_is_recorded_as_missing() {
        // The discriminator between our parser and the response boundary. Providers commonly end with a
        // usage-only chunk whose choices array is empty; if the finish reason rides there, a COMPLETE stream
        // ends with saw_finish_reason false - which is indistinguishable from a cut unless these two flags
        // are recorded separately. This test pins that behaviour so the distinction cannot be lost again.
        let result = fixture(concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"answer\"}}]}

",
            "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10},\"finish_reason\":\"stop\"}

",
            "data: [DONE]

"));
        assert_eq!(result["saw_finish_reason"], false);
        assert_eq!(result["saw_usage"], true);
        assert_eq!(result["termination"], "done");
        assert_eq!(result["stream_complete"], false);
    }

    #[test]
    fn an_unparseable_event_is_counted_not_skipped_in_silence() {
        let result = fixture(concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}

",
            "data: {not json at all

",
            "data: [DONE]

"));
        assert_eq!(result["malformed_events"], 1);
        assert_eq!(result["chunks"], 1);
        assert_eq!(result["content"], "a");
    }

    #[test]
    fn eof_without_finish_is_not_success() {
        let result=fixture("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n");
        assert_eq!(result["stream_complete"], false);
        assert_eq!(result["content"], "partial");
        assert!(result["usage"].is_null());
    }
}

#[cfg(test)]
mod heartbeat_tests {
    use super::*;

    /// A bounded host call must not look like a wedged worker.
    ///
    /// This is the bug the user reported as "the node is offline": `ok` is `!stalled`, and `stalled`
    /// means no beat for WASM_AGENT_WORKER_STALL_SECONDS. A long `exec` beat nothing while it ran, so a
    /// node running a command reported `ok:false` - and the window, whose reads queue behind the run,
    /// told the reader it was offline. The stall threshold is dropped to 2s here so the test is about
    /// the mechanism rather than about waiting 120 of them.
    #[test]
    fn a_running_command_keeps_beating() {
        std::env::set_var("WASM_AGENT_WORKER_STALL_SECONDS", "2");
        std::env::set_var("WASM_AGENT_EXEC_TIMEOUT_SECONDS", "60");
        // Establish a baseline the way a working node would: one beat, then the command. Without this
        // the test passed even with the heartbeat removed, because `beat_age_ms` returns 0 when
        // nothing has ever beaten - the sampler measured nothing and agreed with everything.
        crate::serve::beat();
        // The claim is about the whole duration of the call, so it is sampled throughout.
        let sampler = std::thread::spawn(|| {
            let mut worst = 0u64;
            for _ in 0..14 {
                std::thread::sleep(std::time::Duration::from_millis(500));
                worst = worst.max(crate::serve::beat_age_ms());
            }
            worst
        });
        let started = std::time::Instant::now();
        let result = run_bounded("bash", "-c", "sleep 6", "", None);
        let elapsed = started.elapsed();
        let worst = sampler.join().unwrap();
        assert!(result.is_ok(), "the command should run: {result:?}");
        assert!(elapsed.as_secs() >= 5, "it should have waited for the command, took {elapsed:?}");
        // Without the heartbeat the age would climb past 2s within the first seconds and stay there.
        assert!(
            worst < 2000,
            "the beat age reached {worst}ms while a bounded command was running; \
             the node would have reported ok:false and the window would have called it offline"
        );
    }

    #[test]
    fn shell_child_inherits_only_the_turn_boolean() {
        crate::serve::test_mark_turn(true);
        let (program, flag) = shell_config();
        let result = run_bounded(program, flag, "env | grep '^WASM_AGENT_IN_TURN='", "", None);
        crate::serve::test_mark_turn(false);
        let output = result.expect("shell child should run");
        assert_eq!(output["stdout"], "WASM_AGENT_IN_TURN=1\n");
    }
}
