//! Host capabilities exposed to Lua: sqlite, sha256, uuid, time, log, files.
//!
//! These are the only things the Lua agent cannot do by itself. Everything the
//! agent *decides* lives in Lua; everything it *needs from the platform* lives
//! here, so the same Lua can later run as a WASM component with these imports.
use crate::lua::{arg_string, lua_pushlstring, lua_touserdata, upvalue_index, LuaState};
use crate::plugins::PluginRegistry;
use ring::rand::{SecureRandom, SystemRandom};
use rusqlite::{params_from_iter, Connection};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::ffi::{c_char, c_int};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

pub struct Host {
    pub db: Mutex<Connection>,
    pub plugins: Mutex<PluginRegistry>,
    pub client: std::sync::Arc<crate::client_bridge::Bridge>,
}

// Values the host resolved itself: the config file, the home directory, the
// database path. Lua reads them through `host.getenv` rather than `os.getenv`
// because on Windows Rust's `set_var` is invisible to the C runtime's
// `getenv` - the UCRT caches the environment at startup, so `os.getenv` kept
// returning what the process was launched with. The effect was silent: the
// entire config file was ignored and the agent ran with "no model configured".
static ENV_OVERRIDES: OnceLock<HashMap<String, String>> = OnceLock::new();

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
    let ignore_case = options.get("ignore_case").and_then(Value::as_bool).unwrap_or(true);
    let limit = options.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize;

    let needle = if ignore_case { pattern.to_lowercase() } else { pattern.clone() };
    let mut matches: Vec<Value> = Vec::new();
    let mut stack = vec![(std::path::PathBuf::from(&path), 0usize)];
    // Skip the directories that only ever produce noise.
    const SKIP: [&str; 4] = [".git", "target", "node_modules", ".wasm-agent"];
    while let Some((current, depth)) = stack.pop() {
        if matches.len() >= limit || depth > 12 {
            break;
        }
        if current.is_dir() {
            let Ok(entries) = std::fs::read_dir(&current) else { continue };
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if SKIP.contains(&name.as_str()) {
                    continue;
                }
                stack.push((entry.path(), depth + 1));
            }
            continue;
        }
        let Ok(metadata) = current.metadata() else { continue };
        if metadata.len() > 4 * 1024 * 1024 {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&current) else { continue };
        for (index, line) in text.lines().enumerate() {
            let haystack = if ignore_case { line.to_lowercase() } else { line.to_string() };
            if haystack.contains(&needle) {
                matches.push(json!({
                    "file": current.to_string_lossy(),
                    "line": index + 1,
                    "text": line.chars().take(400).collect::<String>(),
                }));
                if matches.len() >= limit {
                    break;
                }
            }
        }
    }
    push_json(l, &json!({ "matches": matches, "count": matches.len() }));
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
fn agent() -> ureq::Agent {
    static HTTP_AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    HTTP_AGENT.get_or_init(|| {
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
    ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_connect(Some(std::time::Duration::from_secs(connect)))
        .timeout_recv_response(Some(std::time::Duration::from_secs(respond)))
        .timeout_recv_body(Some(std::time::Duration::from_secs(read)))
        .build()
        .into()
    }).clone()
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
fn run_bounded(program: &str, flag: &str, command: &str, cwd: &str) -> Result<Value, String> {
    crate::operations::foreground(program, flag, command, cwd, exec_timeout_seconds())
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

pub extern "C" fn exec(l: *mut LuaState) -> c_int {
    let command = arg_string(l, 1).unwrap_or_default();
    let cwd = arg_string(l, 2).unwrap_or_default();
    let (program, flag) = shell_config();
    let outcome = run_bounded(program, flag, &command, &cwd);
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
    let _heartbeat = crate::serve::Heartbeat::start();
    let outcome = (|| -> Result<Value, String> {
        let response = match method.as_str() {
            "GET" => {
                let mut request = agent().get(&url);
                for (key, value) in &headers {
                    request = request.header(key, value);
                }
                request.call().map_err(|e| e.to_string())?
            }
            "POST" => {
                let mut request = agent().post(&url);
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
    let mut request = agent().post(url);
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
                    // A long reasoning phase used to look like a hung run. The UI
                    // can now say how much thinking has happened.
                    crate::serve::write_event(
                        &json!({"type": "reasoning", "chars": reasoning.chars().count()}).to_string(),
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
        let result = run_bounded("bash", "-c", "sleep 6", "");
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
        let result = run_bounded(program, flag, "env | grep '^WASM_AGENT_IN_TURN='", "");
        crate::serve::test_mark_turn(false);
        let output = result.expect("shell child should run");
        assert_eq!(output["stdout"], "WASM_AGENT_IN_TURN=1\n");
    }
}
