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

/// host.platform() -> { os, arch, shell, pathSeparator }
///
/// So the agent can be told which dialect it is running in. Its `bash` tool is
/// `sh -c` on Linux and `cmd /C` on Windows, and without this the model guesses
/// POSIX: it runs `pwd`, `ls` and `grep`, gets "not recognized as an internal or
/// external command", and burns its tool budget on retries.
pub extern "C" fn platform(l: *mut LuaState) -> c_int {
    let entries: [(&str, String); 4] = [
        ("os", std::env::consts::OS.to_string()),
        ("arch", std::env::consts::ARCH.to_string()),
        (
            "shell",
            if cfg!(target_os = "windows") { "cmd /C".to_string() } else { "sh -c".to_string() },
        ),
        ("pathSeparator", std::path::MAIN_SEPARATOR.to_string()),
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

/// An agent that returns error responses instead of raising, so provider
/// 4xx bodies reach the caller (and the logs).
fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .http_status_as_error(false)
        .build()
        .into()
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
/// Uniqueness here is load-bearing: turns, memories, sessions and journal rows
/// are all keyed by it. The previous implementation read
/// /proc/sys/kernel/random/uuid and fell back to the *process id* everywhere
/// else, which is one value per process - so off Linux the second write in any
/// session died with `UNIQUE constraint failed: turns.id`.
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
pub extern "C" fn write_file(l: *mut LuaState) -> c_int {
    let path = arg_string(l, 1).unwrap_or_default();
    let text = arg_string(l, 2).unwrap_or_default();
    if let Some(parent) = std::path::Path::new(&path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let ok = std::fs::write(&path, text).is_ok();
    unsafe { crate::lua::lua_pushboolean(l, ok as c_int) };
    1
}

/// host.exec(command, cwd?) -> {code, stdout, stderr} | {error}
pub extern "C" fn exec(l: *mut LuaState) -> c_int {
    let command = arg_string(l, 1).unwrap_or_default();
    let cwd = arg_string(l, 2).unwrap_or_default();
    let outcome = (|| -> Result<Value, String> {
        let mut process = if cfg!(target_os = "windows") {
            let mut command_line = std::process::Command::new("cmd");
            command_line.arg("/C").arg(&command);
            command_line
        } else {
            let mut shell = std::process::Command::new("sh");
            shell.arg("-c").arg(&command);
            shell
        };
        if !cwd.is_empty() {
            process.current_dir(&cwd);
        }
        let output = process.output().map_err(|error| error.to_string())?;
        Ok(json!({
            "code": output.status.code().unwrap_or(-1),
            "stdout": String::from_utf8_lossy(&output.stdout),
            "stderr": String::from_utf8_lossy(&output.stderr),
        }))
    })();
    push_json(l, &outcome.unwrap_or_else(|error| json!({"error": error})));
    1
}

/// host.client(action, args_json) -> result from the client machine | {error}
pub extern "C" fn client(l: *mut LuaState) -> c_int {
    let host = host_of(l);
    let action = arg_string(l, 1).unwrap_or_default();
    let args: Value = serde_json::from_str(&arg_string(l, 2).unwrap_or_else(|| "{}".into()))
        .unwrap_or_else(|_| json!({}));
    let result = host.client.call(&action, args);
    push_json(l, &result);
    1
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

/// host.http_stream(method, url, headers_json, body) -> aggregated completion.
///
/// Reads an OpenAI-compatible SSE stream, forwards each content delta to the UI
/// (server-sent event `delta`), and returns `{status, content, tool_calls,
/// usage}` so the caller can continue the tool loop.
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
    if method != "POST" {
        return Err("method_not_supported".into());
    }
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
    let mut tool_calls: Vec<Value> = Vec::new();
    let mut usage: Option<Value> = None;
    for line in reader.lines() {
        let line = line.map_err(|error| error.to_string())?;
        let Some(data) = line.trim().strip_prefix("data:") else { continue };
        let data = data.trim();
        if data.is_empty() {
            continue;
        }
        if data == "[DONE]" {
            break;
        }
        let chunk: Value = match serde_json::from_str(data) {
            Ok(value) => value,
            Err(_) => continue,
        };
        if let Some(text) = chunk["choices"][0]["delta"]["content"].as_str() {
            if !text.is_empty() {
                content.push_str(text);
                crate::serve::write_event(&json!({"type": "delta", "text": text}).to_string());
            }
        }
        if let Some(calls) = chunk["choices"][0]["delta"]["tool_calls"].as_array() {
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
    Ok(json!({"status": status, "content": content, "tool_calls": tool_calls, "usage": usage}))
}

/// host.now() -> seconds since epoch
pub extern "C" fn now(l: *mut LuaState) -> c_int {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    unsafe { crate::lua::lua_pushnumber(l, seconds) };
    1
}
