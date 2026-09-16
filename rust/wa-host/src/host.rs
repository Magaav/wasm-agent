//! Host capabilities exposed to Lua: sqlite, sha256, uuid, time, log, files.
//!
//! These are the only things the Lua agent cannot do by itself. Everything the
//! agent *decides* lives in Lua; everything it *needs from the platform* lives
//! here, so the same Lua can later run as a WASM component with these imports.
use crate::lua::{arg_string, lua_pushlstring, lua_touserdata, upvalue_index, LuaState};
use crate::plugins::PluginRegistry;
use rusqlite::{params_from_iter, Connection};
use serde_json::{json, Value};
use std::ffi::{c_char, c_int};
use std::sync::Mutex;

pub struct Host {
    pub db: Mutex<Connection>,
    pub plugins: Mutex<PluginRegistry>,
    pub client: std::sync::Arc<crate::client_bridge::Bridge>,
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
pub extern "C" fn uuid(l: *mut LuaState) -> c_int {
    let value = std::fs::read_to_string("/proc/sys/kernel/random/uuid")
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| format!("{:x}", std::process::id()));
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
pub extern "C" fn log(l: *mut LuaState) -> c_int {
    if let Some(message) = arg_string(l, 1) {
        eprintln!("[lua] {message}");
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
