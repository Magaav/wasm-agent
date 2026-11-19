//! Host capabilities exposed to Lua: sqlite, sha256, uuid, time, log, files.
//!
//! These are the only things the Lua agent cannot do by itself. Everything the
//! agent *decides* lives in Lua; everything it *needs from the platform* lives
//! here, so the same Lua can later run as a WASM component with these imports.
use wa_host_support::lua::{arg_integer, arg_string, lua_pushlstring, lua_touserdata, upvalue_index, LuaState};
// The one answer shape shared with the kernel entry points (`components`, `service`, `state`), which
// moved to `wa-host-support` with `lua.rs`: they answer through it and may not import this crate.
use wa_host_support::json::push_json;
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
pub extern "C-unwind" fn db_ready(l: *mut LuaState) -> c_int {
    unsafe { wa_host_support::lua::lua_pushboolean(l, DB_READY.load(std::sync::atomic::Ordering::SeqCst) as c_int) };
    1
}

/// host.mark_db_ready() -> nil: record that the schema migration has run.
pub extern "C-unwind" fn mark_db_ready(l: *mut LuaState) -> c_int {
    DB_READY.store(true, std::sync::atomic::Ordering::SeqCst);
    // One explicit nil, never zero results: `select('#', host.mark_db_ready())`
    // must be 1, or a caller that passes the result around gets nothing.
    unsafe { wa_host_support::lua::lua_pushnil(l) };
    1
}

    /// Rust-side setter: the environment overrides a host-side test installs. No Lua value.
pub fn set_env_overrides(values: HashMap<String, String>) {
    let _ = ENV_OVERRIDES.set(values);
}

/// The value of `name` as the host resolves it: what it resolved itself first, then the real process
/// environment - the same order `host.getenv` uses, in one place so a Rust-side reader cannot
/// disagree with what a guest sees. `host.paths()` and the plugin directory read it (a23fix): a boot
/// that publishes a node's home through the override map (`boot_native_state`) must not have to
/// rewrite the process environment for those two to resolve it.
pub(crate) fn resolved_env(name: &str) -> Option<String> {
    ENV_OVERRIDES
        .get()
        .and_then(|map| map.get(name).cloned())
        .or_else(|| std::env::var(name).ok())
}

/// host.getenv(name) -> string | nil
///
/// Env access as a capability, like the rest of `host.*`: it checks what the
/// host resolved first and falls back to the real process environment.
pub extern "C-unwind" fn getenv(l: *mut LuaState) -> c_int {
    let name = arg_string(l, 1).unwrap_or_default();
    match resolved_env(&name) {
        Some(value) => {
            unsafe { lua_pushlstring(l, value.as_ptr() as *const c_char, value.len()) };
            1
        }
        // Push an explicit nil. Returning *zero* values instead would expand to
        // nothing when used as a function argument, so `tonumber(host.getenv(X))`
        // would become `tonumber()` and fail with "bad argument #1".
        None => {
            unsafe { wa_host_support::lua::lua_pushnil(l) };
            1
        }
    }
}

/// host.executable_on_path(name) -> absolute path, or nil.
///
/// The file the kernel will actually START for a bare program name (node), resolved against the PATH a
/// spawned child inherits - never against the PATH host.getenv answers, which is the config's first. An
/// approval has to name the interpreter the launch spawns, and a digest that named one node while the
/// child ran another named no file at all (round 7). A name with a separator is not a name to resolve,
/// and a name that is not there is nil rather than a guess.
#[no_mangle]
pub extern "C-unwind" fn executable_on_path(l: *mut LuaState) -> c_int {
    let name = arg_string(l, 1).unwrap_or_default();
    let name = if cfg!(windows) && !name.ends_with(".exe") { format!("{name}.exe") } else { name };
    let resolved = if name.is_empty() || name.contains('/') || name.contains('\\') {
        None
    } else {
        which_on_path(&name)
    };
    match resolved {
        Some(path) => {
            unsafe { lua_pushlstring(l, path.as_ptr() as *const c_char, path.len()) };
            1
        }
        None => {
            unsafe { wa_host_support::lua::lua_pushnil(l) };
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
pub extern "C-unwind" fn paths(l: *mut LuaState) -> c_int {
    let home = resolved_env("HOME").unwrap_or_else(|| ".".into());
    let base = format!("{home}/.wasm-agent");
    let entries: [(&str, String); 5] = [
        ("home", home),
        ("config", base.clone()),
        ("data", base.clone()),
        ("cache", format!("{base}/cache")),
        ("temp", std::env::temp_dir().to_string_lossy().to_string()),
    ];
    unsafe {
        wa_host_support::lua::lua_createtable(l, 0, entries.len() as c_int);
        for (key, value) in entries {
            lua_pushlstring(l, value.as_ptr() as *const c_char, value.len());
            let name = std::ffi::CString::new(key).unwrap();
            wa_host_support::lua::lua_setfield(l, -2, name.as_ptr());
        }
    }
    1
}

/// Resolve an existing path through symlinks/junctions; missing paths return nil.
pub extern "C-unwind" fn canonical_path(l: *mut LuaState) -> c_int {
    let path=arg_string(l,1).and_then(|value|std::fs::canonicalize(value).ok());
    if let Some(path)=path {
        let value=path.to_string_lossy().replace('\\',"/");
        unsafe {lua_pushlstring(l,value.as_ptr() as *const c_char,value.len());}
    } else { unsafe {wa_host_support::lua::lua_pushnil(l);} }
    1
}

/// A bare name resolved through the PROCESS environment's PATH - the one a spawned child inherits, and
/// the one the kernel uses to start a program (operations.rs, the `program` branch of `start`).
///
/// host.executable_on_path below is the same answer from Lua, and it is not the same as
/// host.getenv("PATH"): that reads the host's config overrides first (resolved_env), so a node whose
/// config sets a PATH named one interpreter while the child ran another (round 7).
pub(crate) fn which_on_path(name: &str) -> Option<String> {
    let path = std::env::var("PATH").ok()?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().to_string());
        }
    }
    None
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
pub(crate) fn shell_config() -> &'static (String, String) {
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
                // Use the real MSYS interpreter, not Git's bin launcher. The
                // launcher recursively respawns wrappers and console hosts.
                r"C:\Program Files\Git\usr\bin\bash.exe".to_string(),
                r"C:\Program Files (x86)\Git\usr\bin\bash.exe".to_string(),
                r"C:\Program Files\Git\bin\bash.exe".to_string(),
                r"C:\Program Files (x86)\Git\bin\bash.exe".to_string(),
            ];
            for name in ["bash.exe", "sh.exe"] {
                if let Some(found) = which_on_path(name) {
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
        if let Some(found) = which_on_path("bash") {
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
pub extern "C-unwind" fn platform(l: *mut LuaState) -> c_int {
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
        wa_host_support::lua::lua_createtable(l, 0, entries.len() as c_int);
        for (key, value) in entries {
            lua_pushlstring(l, value.as_ptr() as *const c_char, value.len());
            let name = std::ffi::CString::new(key).unwrap();
            wa_host_support::lua::lua_setfield(l, -2, name.as_ptr());
        }
    }
    1
}

    /// Returns JSON text of `{ok, matches, count, …}`; A string the caller decodes (`lua/vendor/json.lua`), never a Lua table.
/// host.grep(pattern, path, opts?) -> [{ file, line, text }]
///
/// Implemented here rather than by shelling out to `grep`, which does not exist
/// on Windows - the tool used to fail with "'grep' is not recognized" on a
/// Windows node. Plain substring matching, optionally case-insensitive: enough
/// for finding code, and it behaves identically on every platform.
pub extern "C-unwind" fn grep(l: *mut LuaState) -> c_int {
    let pattern = arg_string(l, 1).unwrap_or_default();
    let path = arg_string(l, 2).unwrap_or_else(|| ".".to_string());
    let options = arg_string(l, 3).unwrap_or_default();
    let options: Value = serde_json::from_str(&options).unwrap_or(Value::Null);
    push_json(l, &crate::file_search::search(&pattern, &path, &options));
    1
}

/// host.list_dir(path) -> JSON text of `{path, entries: [{name, kind, size, modified}]}`, or
/// `{path, error}` when the directory cannot be read.
///
/// **One string, not a table.** `#value` is its byte length and `ipairs(value)` yields nothing, so a
/// caller must decode it before reading `entries`; a directory that does not exist yet answers an
/// error object rather than an empty list (measured 12/11: a scan that forgot this silently found no
/// handles and was indistinguishable from "nothing pending").
///
/// The `ls` tool used to shell out to `ls -la`, which does not exist on Windows:
/// its description claimed to be portable while the implementation was not, and
/// a self-evolution run found that before I did.
pub extern "C-unwind" fn list_dir(l: *mut LuaState) -> c_int {
    let path = arg_string(l, 1).unwrap_or_else(|| ".".to_string());
    let mut entries: Vec<Value> = Vec::new();
    match std::fs::read_dir(&path) {
        Ok(reader) => {
            for entry in reader {
                let entry = match entry {
                    Ok(entry) => entry,
                    Err(error) => {
                        push_json(l, &json!({ "error": error.to_string(), "path": path }));
                        return 1;
                    }
                };
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

fn build_config(url: &str, read: u64) -> Result<ureq::config::Config, String> {
    let (_, _, respond) = http_timeouts();
    build_config_with(url, read, respond)
}

/// The same shape, with the response deadline named by the caller.
///
/// A provider call is where a deadline earns its keep: a gateway that accepts the connection and
/// then says nothing used to hold the run for the global response timeout, three times over, before
/// anything was reported (measured 10/11: 12 minutes, session a073ee85). `first_response_seconds`
/// lets that call bound itself in tens of seconds and name the outcome (`provider_stalled`).
fn build_config_with(url: &str, read: u64, respond: u64) -> Result<ureq::config::Config, String> {
    let (connect, _, _) = http_timeouts();
    // Whose certificates are trusted is the machine's answer, not this call's - for a request that
    // can consult an anchor at all. wa-tls reads SSL_CERT_FILE / SSL_CERT_DIR the way OpenSSL does; a
    // bundle named there that cannot be read is a refusal with that bundle in the message, never a
    // quiet fall back to Mozilla's roots. A plain http:// request never hands anything to TLS, so a
    // broken bundle must not refuse it (review r1, item 7): the room a loopback provider, a local
    // relay or an http MCP server needs.
    let mut builder = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_connect(Some(std::time::Duration::from_secs(connect)))
        .timeout_recv_response(Some(std::time::Duration::from_secs(respond)))
        .timeout_recv_body(Some(std::time::Duration::from_secs(read)));
    if wa_tls::is_tls(url) {
        builder = builder.tls_config(wa_tls::tls_config().map_err(|error| error.to_string())?);
    }
    Ok(builder.build())
}

fn agent(url: &str) -> Result<ureq::Agent, String> {
    // One static per case, and this is not tidiness: an agent built for a plain URL carries no
    // anchors, and reusing it for a TLS call would silently ignore the machine's bundle. An agent
    // built for a TLS URL is the only one a handshake may use.
    static TLS_AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    static PLAIN_AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    let cache = if wa_tls::is_tls(url) { &TLS_AGENT } else { &PLAIN_AGENT };
    if let Some(agent) = cache.get() {
        return Ok(agent.clone());
    }
    let (_, read, _) = http_timeouts();
    let agent: ureq::Agent = build_config(url, read)?.into();
    // Only an agent that was built is remembered: an environment that cannot answer about trust is
    // re-read on the next call instead of being cached as a failure for the life of the process.
    Ok(cache.get_or_init(|| agent).clone())
}

/// The agent to use for one provider call.
///
/// A child runs under a deadline the runtime owns, and that deadline has to
/// affect the network read rather than only being checked between model calls.
/// When this thread is a child, its provider call uses the shutdown-aware
/// transport (`http_transport`): the socket is registered with the task, so a
/// cancel from another thread wakes a silent read immediately, and the body
/// budget still bounds a provider that never speaks at all.
fn agent_for_call(url: &str) -> Result<ureq::Agent, String> {
    if !crate::subagents::in_task() {
        return agent(url);
    }
    let (_, read, _) = http_timeouts();
    let body = match crate::subagents::remaining_budget() {
        Some(remaining) => remaining.as_secs().clamp(1, read.max(1)),
        None => read,
    };
    Ok(crate::http_transport::agent(build_config(url, body)?))
}

/// The agent for one provider stream, with the caller's own deadline on the wait for a response
/// and on the silence between body reads. A child still runs under its shutdown-aware transport.
fn agent_for_stream(url: &str, first_response_seconds: u64) -> Result<ureq::Agent, String> {
    let (_, read, respond) = http_timeouts();
    let read = read.min(first_response_seconds.max(1));
    let respond = respond.min(first_response_seconds.max(1));
    if !crate::subagents::in_task() {
        return Ok(build_config_with(url, read, respond)?.into());
    }
    let body = match crate::subagents::remaining_budget() {
        Some(remaining) => remaining.as_secs().clamp(1, read.max(1)),
        None => read,
    };
    Ok(crate::http_transport::agent(build_config_with(url, body, respond)?))
}

/// Unified cancellation for the Lua loop: true when the current run or the
/// current child has been asked to stop.
///
/// The run half is a probe the serve layer registers (`set_run_cancel_probe`),
/// so host.rs does not depend on serve's internals; the child half is the task's
/// own flag. One name means a caller cannot check the wrong one.
static RUN_CANCEL_PROBE: OnceLock<fn() -> bool> = OnceLock::new();

    /// Rust-side setter: the probe the operation loops ask whether this run was cancelled.
pub fn set_run_cancel_probe(probe: fn() -> bool) {
    let _ = RUN_CANCEL_PROBE.set(probe);
}

/// Ctrl+C on an empty line in `wa chat`: the terminal-side half of cancellation (there is no serve
/// layer to register a probe in the CLI). Cleared when the next line is submitted.
static CLI_INTERRUPT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn cli_interrupted() -> bool {
    CLI_INTERRUPT.load(std::sync::atomic::Ordering::SeqCst)
}

    /// Rust-side read of the same cancellation the Lua `host.run_cancelled` answers: a boolean.
pub(crate) fn run_cancel_requested() -> bool {
    RUN_CANCEL_PROBE.get().map(|probe| probe()).unwrap_or(false) || cli_interrupted() || crate::subagents::cancel_requested()
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.run_cancelled() -> JSON text of {cancelled, run_cancel, subagent_cancel}
///
/// `cancelled` is true while either source is set. A foreground run's scoped
/// cancellation is the run half; a supervised child's is the subagent half.
pub extern "C-unwind" fn run_cancelled(l: *mut LuaState) -> c_int {
    let run_cancel = RUN_CANCEL_PROBE.get().map(|probe| probe()).unwrap_or(false) || cli_interrupted();
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

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.sql_exec(sql, params_json) -> {ok, changes} | {error}
///
/// A statement error is RETURNED, never forced into a rollback: SQLite lets the
/// caller recover inside its transaction (catch the error, compensate, commit or
/// roll back explicitly). Forcing a rollback here would silently end the
/// transaction, and a Lua caller that caught the error and wrote again would then
/// autocommit the later write, breaking atomicity. A transaction is closed only at
/// an uncaught callback error (`host::rollback_if_open`) or when the interpreter's
/// connection drops.
///
/// A busy/locked refusal is the one error retried here, and the retry is the
/// statement's, never a unit's (see `under_policy`).
pub extern "C-unwind" fn sql_exec(l: *mut LuaState) -> c_int {
    let host = host_of(l);
    let sql = arg_string(l, 1).unwrap_or_default();
    let params_json = arg_string(l, 2).unwrap_or_else(|| "[]".into());
    let values: Vec<Value> = serde_json::from_str(&params_json).unwrap_or_default();
    let action = action_of(&sql);
    let outcome = (|| -> Result<Value, String> {
        let conn = host.db.lock().map_err(|e| e.to_string())?;
        under_policy(&conn, &action, || {
            if values.is_empty() {
                conn.execute_batch(&sql)?;
                Ok(json!({"ok": true, "changes": conn.changes()}))
            } else {
                let owned = params(&values);
                let changes = conn.execute(&sql, params_from_iter(owned.iter().map(|p| p.as_ref())))?;
                Ok(json!({"ok": true, "changes": changes}))
            }
        })
    })();
    push_json(l, &outcome.unwrap_or_else(|error| json!({"error": error})));
    1
}

/// A short, single-line name for a statement, so a contention failure says what it was doing
/// (`BEGIN IMMEDIATE`, `INSERT INTO messages(...)`) without pasting a whole statement into a log.
fn action_of(sql: &str) -> String {
    let collapsed = sql.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut out: String = collapsed.chars().take(60).collect();
    if collapsed.chars().count() > 60 {
        out.push('\u{2026}');
    }
    if out.is_empty() {
        out.push_str("statement");
    }
    out
}

/// Run one statement under the node's contention policy (rust/wa-sqlite).
///
/// The rules, and why they are these rules:
///
/// * Only `SQLITE_BUSY`/`SQLITE_LOCKED` is retried. Any other error is returned at once - a missing
///   table or a constraint violation must never be attempted twice.
/// * A refused statement applied nothing, so running *this statement* again cannot double-apply an
///   effect. That is why the retry lives here and not around a transaction: a unit is not re-run,
///   because a Lua closure may have done work outside SQLite by the time it failed.
/// * The exception SQLite itself creates is a write conflict inside a transaction
///   (`SQLITE_BUSY_SNAPSHOT`): it ROLLS THE TRANSACTION BACK. Retrying the statement then would run
///   it in autocommit and commit alone what the caller meant to be one unit, so that case is
///   detected (`is_autocommit` before/after) and reported as a failure to retry *the unit*.
/// * Total patience is bounded (`WASM_AGENT_SQLITE_RETRY_MS`) and the failure is named
///   (`database_busy: ... (retryable)`), so a caller can decide to retry instead of dying.
fn under_policy<T>(
    conn: &Connection,
    action: &str,
    mut run: impl FnMut() -> rusqlite::Result<T>,
) -> Result<T, String> {
    let started = std::time::Instant::now();
    let inside_transaction = !conn.is_autocommit();
    let attempts_max = wa_sqlite::attempts_max();
    let deadline = started + std::time::Duration::from_millis(wa_sqlite::retry_ms());
    let mut attempt = 0u32;
    loop {
        attempt += 1;
        match run() {
            Ok(value) => {
                let slow = wa_sqlite::slow_ms();
                let spent = started.elapsed();
                if slow > 0 && spent.as_millis() as u64 >= slow {
                    eprintln!(
                        "[sql] {action}: {}ms{} (WASM_AGENT_SQLITE_SLOW_MS={slow})",
                        spent.as_millis(),
                        if inside_transaction { " inside a transaction" } else { "" }
                    );
                }
                return Ok(value);
            }
            Err(error) => {
                if !wa_sqlite::is_busy(&error) {
                    return Err(error.to_string());
                }
                if inside_transaction && conn.is_autocommit() {
                    return Err(format!(
                        "{}: {action} hit a write conflict and SQLite rolled the transaction back; \
                         re-running this one statement would commit it alone (retry the whole unit): {error}",
                        wa_sqlite::BUSY_NAME
                    ));
                }
                if attempt >= attempts_max || std::time::Instant::now() >= deadline {
                    return Err(wa_sqlite::failure(action, &error.to_string(), attempt, started.elapsed()));
                }
                wa_sqlite::backoff(attempt);
            }
        }
    }
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.sql_query(sql, params_json) -> [ {column: value}, ... ] | {error}
///
/// A read takes no write lock, so the only contention it meets is a schema/journal transition; it is
/// retried under the same policy as a write (`under_policy`), which is what makes a `status` call
/// answer while another lane is committing.
pub extern "C-unwind" fn sql_query(l: *mut LuaState) -> c_int {
    let host = host_of(l);
    let sql = arg_string(l, 1).unwrap_or_default();
    let params_json = arg_string(l, 2).unwrap_or_else(|| "[]".into());
    let values: Vec<Value> = serde_json::from_str(&params_json).unwrap_or_default();
    let action = action_of(&sql);
    let outcome = (|| -> Result<Value, String> {
        let conn = host.db.lock().map_err(|e| e.to_string())?;
        under_policy(&conn, &action, || {
            let mut statement = conn.prepare(&sql)?;
            let names: Vec<String> = statement.column_names().iter().map(|s| s.to_string()).collect();
            let owned = params(&values);
            let mut rows = statement.query(params_from_iter(owned.iter().map(|p| p.as_ref())))?;
            let mut out = Vec::new();
            while let Some(row) = rows.next()? {
                let mut object = serde_json::Map::new();
                for (index, name) in names.iter().enumerate() {
                    let value = match row.get_ref(index)? {
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
        })
    })();
    push_json(l, &outcome.unwrap_or_else(|error| json!({"error": error})));
    1
}

/// host.sha256(text) -> hex
pub extern "C-unwind" fn sha256(l: *mut LuaState) -> c_int {
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
/// Roll back a transaction this interpreter left open after a Lua call failed.
///
/// Moved out of `Lua::rollback_if_open` when `lua.rs` left this crate: the interpreter wrapper lives
/// in `wa-host-support` and cannot name `Host`, so the body stays with the connection it knows about
/// and the wrapper exposes the value the host attached with `Lua::own`.
pub fn rollback_if_open(lua: &wa_host_support::lua::Lua) {
    let Some(owned) = lua.owned() else { return };
    let Some(host) = owned.downcast_ref::<Host>() else { return };
    if let Ok(connection) = host.db.lock() {
        if !connection.is_autocommit() {
            let _ = connection.execute_batch("ROLLBACK");
        }
    }
}

    /// Rust-side twin of `host.uuid`: a fresh UUID string, never a constant.
pub(crate) fn new_uuid() -> String {
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

    /// host.uuid() -> a fresh UUID as a Lua string. Not JSON: one string, no structure.
pub extern "C-unwind" fn uuid(l: *mut LuaState) -> c_int {
    let value = new_uuid();
    unsafe { lua_pushlstring(l, value.as_ptr() as *const c_char, value.len()) };
    1
}

/// `host.read_file(path) -> string | nil, reason`
///
/// The second answer says why there is no text, by name, because a bare nil cannot tell a reader
/// which of four different things happened (measured 10/11: an 8 MB file answered nil, so "too
/// large", "missing", "binary" and "the OS refused" were the same answer). A limit exists so one
/// file cannot dwarf an interpreter's memory, and it is *named* rather than silently applied:
/// `read_file_too_large:<bytes>><limit>` carries both numbers. `WASM_AGENT_READ_FILE_MAX_BYTES`
/// changes the limit; a caller that only reads the first value keeps working exactly as before.
const READ_FILE_MAX_BYTES_DEFAULT: u64 = 8 * 1024 * 1024;

fn read_file_max_bytes() -> u64 {
    std::env::var("WASM_AGENT_READ_FILE_MAX_BYTES").ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(READ_FILE_MAX_BYTES_DEFAULT)
}

/// The decision `read_file` makes, split out so the named answers can be tested without a Lua state:
/// the file's text, or the reason there is none (`read_file_missing`, `read_file_unreadable`,
/// `read_file_is_a_directory`, `read_file_too_large:<bytes>><limit>`, `read_file_not_text:<bytes>`).
fn read_text_file(path: &str, limit: u64) -> Result<String, String> {
    let metadata = std::fs::metadata(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            format!("read_file_missing:{path}")
        } else {
            format!("read_file_unreadable:{error}")
        }
    })?;
    if metadata.is_dir() { return Err(format!("read_file_is_a_directory:{path}")); }
    if metadata.len() > limit {
        return Err(format!("read_file_too_large:{}>{}", metadata.len(), limit));
    }
    std::fs::read_to_string(path).map_err(|_| format!("read_file_not_text:{} bytes", metadata.len()))
}

    /// host.read_file(path) -> the file's text as a Lua string, or `nil, reason` (two values).
    /// Not JSON: the bytes are the answer, and the reason names why there are none.
pub extern "C-unwind" fn read_file(l: *mut LuaState) -> c_int {
    let path = arg_string(l, 1).unwrap_or_default();
    match read_text_file(&path, read_file_max_bytes()) {
        Ok(text) => {
            unsafe { lua_pushlstring(l, text.as_ptr() as *const c_char, text.len()) };
            1
        }
        // Two values: nil, and the reason by name. A caller that reads one value sees exactly what
        // it saw before; a caller that wants to know can ask (file_tools.lua's `read` does).
        Err(reason) => {
            unsafe { wa_host_support::lua::lua_pushnil(l) };
            unsafe { lua_pushlstring(l, reason.as_ptr() as *const c_char, reason.len()) };
            2
        }
    }
}

/// host.isatty(stream) -> boolean: is "stdout" (default), "stderr" or "stdin" a terminal?
/// Not named `isatty` in Rust: with #[no_mangle] that replaced libc's own isatty process-wide, and the
/// first caller (the test harness) crashed.
#[no_mangle]
    /// host.stream_is_terminal(which?) -> a Lua boolean: is stdin/stderr/stdout a console.
    /// Not JSON: one boolean.
pub extern "C-unwind" fn stream_is_terminal(l: *mut LuaState) -> c_int {
    use std::io::IsTerminal;
    let answer = match arg_string(l, 1).as_deref() {
        Some("stdin") => std::io::stdin().is_terminal(),
        Some("stderr") => std::io::stderr().is_terminal(),
        _ => std::io::stdout().is_terminal(),
    };
    unsafe { wa_host_support::lua::lua_pushboolean(l, answer as c_int) };
    1
}

/// host.path_kind(path) -> "file" | "dir" | "missing" | "other". `read_file` answers nil both for a
/// missing file and for one it cannot read as text, and a caller about to overwrite needs to know which.
#[no_mangle]
    /// host.path_kind(path) -> a Lua string: `"file"`, `"dir"`, `"missing"` or `"other"`.
    /// Not JSON: a `read_file` answers nil for both "missing" and "unreadable", so this is how a
pub extern "C-unwind" fn path_kind(l: *mut LuaState) -> c_int {
    let kind = match arg_string(l, 1).map(|path| std::fs::metadata(path)) {
        Some(Ok(meta)) if meta.is_file() => "file",
        Some(Ok(meta)) if meta.is_dir() => "dir",
        Some(Ok(_)) => "other",
        _ => "missing",
    };
    unsafe { lua_pushlstring(l, kind.as_ptr() as *const c_char, kind.len()) };
    1
}

/// host.path_facts(path) -> JSON: what a path IS on disk, including the identity a permission decision
/// needs - the realpath (symlinks resolved), the kind, and on unix the owner and the mode bits.
///
/// Why a capability rather than a shelled-out stat: the vault approval decides whether a program is the
/// PLATFORM's (replaced by a package manager, never by the agent) or the connector's own code, and that
/// answer is "root-owned and not group/other-writable" (this round; docs/VAULT.md). A path prefix alone
/// called /usr/local/bin the platform's on a machine where that directory belongs to the user, and the
/// interpreter under it received the vault values unhashed. A stat run through a shell would differ per
/// platform and be spoofable through PATH; this reads the metadata the kernel reports.
///
/// Not a Lua table, like every other JSON-answering capability here: a caller decodes it with
/// lua/vendor/json.lua. A path that does not exist answers {"kind":"missing", ...} - an answer, not nil -
/// so a caller cannot mistake "cannot see it" for "it is fine".
#[no_mangle]
    /// host.path_facts(path) -> one JSON string: {path: realpath, kind, size, unix, uid?, gid?, mode?}
pub extern "C-unwind" fn path_facts(l: *mut LuaState) -> c_int {
    let path = arg_string(l, 1).unwrap_or_default();
    push_json(l, &path_facts_value(&path));
    1
}

pub(crate) fn path_facts_value(path: &str) -> serde_json::Value {
    let real = std::fs::canonicalize(path).ok().map(|value| value.to_string_lossy().replace('\\', "/"));
    match std::fs::metadata(path) {
        Ok(metadata) => {
            let mut value = json!({
                "path": real.unwrap_or_else(|| path.replace('\\', "/")),
                "kind": if metadata.is_file() { "file" } else if metadata.is_dir() { "dir" } else { "other" },
                "size": metadata.len(),
                "unix": cfg!(unix),
            });
            #[cfg(unix)]
            {
                use std::os::unix::fs::MetadataExt;
                value["uid"] = json!(metadata.uid());
                value["gid"] = json!(metadata.gid());
                value["mode"] = json!(metadata.mode() & 0o7777);
            }
            value
        }
        Err(error) => json!({"path": path, "kind": "missing", "unix": cfg!(unix),
            "error": format!("{:?}", error.kind())}),
    }
}

#[no_mangle]
/// host.file_magic(path) -> one JSON string: {path, magic, size?, error?}.
///
/// A JSON string the caller decodes with lua/vendor/json.lua, never a Lua table to index directly.
/// A file's KIND from its leading bytes, which no name can fake: `elf`, `macho`, `pe`, `script` (a
/// shebang), `text`, `binary`, `empty`, `missing` or `unreadable`.
///
/// Why this is a capability and not a read: `host.read_file` answers UTF-8 text and refuses everything
/// else, so Lua could not look at a binary's leading bytes at all - and the vault approval (round 8) has
/// to answer "is this program really the native node it is named after, or a shell script wearing that
/// name?". A NAME is not a program: a copy of python called `node`, or a `#!/bin/sh` wrapper called
/// `bash`, is exactly what a list of names cannot refuse. Only the first bytes are read, so a
/// hundred-megabyte interpreter costs four bytes here.
pub extern "C-unwind" fn file_magic(l: *mut LuaState) -> c_int {
    let path = arg_string(l, 1).unwrap_or_default();
    push_json(l, &file_magic_value(&path));
    1
}

pub(crate) fn file_magic_value(path: &str) -> serde_json::Value {
    use std::io::Read;
    let metadata = match std::fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) => return json!({"path": path, "magic": "missing",
            "error": format!("{:?}", error.kind())}),
    };
    if metadata.is_dir() { return json!({"path": path, "magic": "unreadable", "size": metadata.len()}); }
    if metadata.len() == 0 { return json!({"path": path, "magic": "empty", "size": 0}); }
    // Round 9: a bounded HEAD, not four bytes. A PE's magic is not at its start - it is at the offset
    // e_lfanew names - so four bytes cannot tell an MZ-only file from a real PE, and that difference is
    // exactly what the allow-list needs. Still never the whole file: a hundred-megabyte interpreter costs
    // these MAGIC_HEAD_BYTES and no more.
    let mut head = Vec::with_capacity(MAGIC_HEAD_BYTES.min(metadata.len() as usize));
    match std::fs::File::open(path) {
        Ok(file) => match file.take(MAGIC_HEAD_BYTES as u64).read_to_end(&mut head) {
            Ok(_) => {}
            Err(error) => return json!({"path": path, "magic": "unreadable",
                "error": format!("{:?}", error.kind())}),
        },
        Err(error) => return json!({"path": path, "magic": "unreadable",
            "error": format!("{:?}", error.kind())}),
    };
    let magic = classify_magic(&head);
    json!({"path": path, "magic": magic, "size": metadata.len()})
}

/// How many leading bytes the kind is decided from: a bounded head, never the whole file. Large enough
/// for a PE's e_lfanew (typically 0x80-0x100) and for a universal binary's arch table.
pub(crate) const MAGIC_HEAD_BYTES: usize = 4096;

/// The most architectures a universal (fat) Mach-O header may name. It is also what separates 0xcafebabe
/// the FAT BINARY from 0xcafebabe the JAVA CLASS: a class file follows it with minor+MAJOR version, and no
/// Java class has a major below 45, while a fat header names one to a few architectures.
const FAT_MAX_ARCH: u32 = 15;

/// This HOST's own executable format: the only one a "native binary" may be. An ELF on macOS is a foreign
/// binary, and foreign is not native - the allow-list admits what this node can actually run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HostFormat { Elf, MachO, Pe, Unknown }

pub(crate) fn host_format() -> HostFormat {
    if cfg!(target_os = "linux") || cfg!(target_os = "android") { HostFormat::Elf }
    else if cfg!(target_os = "macos") || cfg!(target_os = "ios") { HostFormat::MachO }
    else if cfg!(target_os = "windows") { HostFormat::Pe }
    // A host this build was not written for: no format is native there (unknown is not yes).
    else { HostFormat::Unknown }
}

fn native_if(is_host: bool, family: &'static str) -> &'static str {
    if is_host { family } else { "foreign" }
}

/// The host's own kind of each leading-byte shape: `elf`, `macho`, `pe` only for THIS host's format, and
/// `foreign` for another platform's executable. Also `script` (a shebang), `text`, `binary`, `empty`,
/// `missing` or `unreadable`.
pub(crate) fn classify_magic(head: &[u8]) -> &'static str {
    classify_magic_on(head, host_format())
}

/// The classifier with the HOST named, so every case is testable on any machine: an ELF is `elf` on
/// Linux and `foreign` on macOS or Windows, and the same holds for the other two.
pub(crate) fn classify_magic_on(head: &[u8], host: HostFormat) -> &'static str {
    if head.starts_with(b"\x7fELF") { return native_if(host == HostFormat::Elf, "elf"); }
    if head.len() >= 4 {
        let magic = u32::from_be_bytes([head[0], head[1], head[2], head[3]]);
        match magic {
            // The thin Mach-O headers: 32/64-bit, each in both byte orders.
            0xfeed_face | 0xfeed_facf | 0xcefa_edfe | 0xcffa_edfe => {
                return native_if(host == HostFormat::MachO, "macho");
            }
            // The universal (fat) header, big-endian and its byte-swapped twin. Its count is what tells it
            // apart from a Java class, which starts with the same four bytes.
            0xcafe_babe => {
                return match fat_arch_count(head, false) {
                    Some(_) => native_if(host == HostFormat::MachO, "macho"),
                    None => "binary",
                };
            }
            0xbeba_feca => {
                return match fat_arch_count(head, true) {
                    Some(_) => native_if(host == HostFormat::MachO, "macho"),
                    None => "binary",
                };
            }
            _ => {}
        }
    }
    // PE: "MZ" alone is not an executable - the COFF header starts at e_lfanew (offset 0x3c) and begins
    // with "PE\0\0". A file whose e_lfanew is out of range, or does not point at "PE\0\0", is a DOS stub
    // or a decoy, never a native binary.
    if head.starts_with(b"MZ") {
        return if pe_header_at(head).is_some() { native_if(host == HostFormat::Pe, "pe") } else { "binary" };
    }
    if head.starts_with(b"#!") { return "script"; }
    if head.iter().all(|byte| *byte == 0x09 || *byte == 0x0a || *byte == 0x0d || (0x20..0x7f).contains(byte)) {
        return "text";
    }
    "binary"
}

/// The architecture count of a universal header, or None when the header is not one: a count of 0 or more
/// than FAT_MAX_ARCH, or a table that does not fit in the bytes read, is not a fat binary (and a Java
/// class, whose next four bytes are a version, is never read as one).
fn fat_arch_count(head: &[u8], little_endian: bool) -> Option<u32> {
    if head.len() < 8 { return None; }
    let raw = [head[4], head[5], head[6], head[7]];
    let count = if little_endian { u32::from_le_bytes(raw) } else { u32::from_be_bytes(raw) };
    if count == 0 || count > FAT_MAX_ARCH { return None; }
    // Each entry is 20 bytes: a header whose table is not even present is not a universal binary.
    if head.len() < 8 + 20 * count as usize { return None; }
    Some(count)
}

/// The offset a PE's COFF header is at, when these bytes really hold one.
fn pe_header_at(head: &[u8]) -> Option<usize> {
    if head.len() < 0x40 { return None; }
    let offset = u32::from_le_bytes([head[0x3c], head[0x3d], head[0x3e], head[0x3f]]) as usize;
    if offset < 0x40 || offset + 4 > head.len() { return None; }
    if &head[offset..offset + 4] != b"PE\0\0" { return None; }
    Some(offset)
}

/// host.file_sha256(path) -> hex, or nil plus a named reason.
///
/// host.sha256 hashes a STRING this interpreter already holds, and host.read_file is bounded (a
/// connector's interpreter is a hundred-megabyte binary that must never pass through Lua): hashing a file
/// by path, in fixed-size chunks, is what lets an approval name the interpreter's bytes. The bound is on
/// the file's size before a byte is read, so a huge or growing file is a refusal rather than an allocation.
#[no_mangle]
    /// host.file_sha256(path) -> the sha256 of a file's bytes as hex, nil+reason when it cannot be read
pub extern "C-unwind" fn file_sha256(l: *mut LuaState) -> c_int {
    let path = arg_string(l, 1).unwrap_or_default();
    match file_digest(&path) {
        Ok(hex) => {
            unsafe { lua_pushlstring(l, hex.as_ptr() as *const c_char, hex.len()) };
            1
        }
        Err(reason) => {
            unsafe { wa_host_support::lua::lua_pushnil(l) };
            unsafe { lua_pushlstring(l, reason.as_ptr() as *const c_char, reason.len()) };
            2
        }
    }
}

/// A file's sha256, read in chunks; bounded by FILE_DIGEST_MAX_BYTES.
pub(crate) const FILE_DIGEST_MAX_BYTES: u64 = 512 * 1024 * 1024;

pub(crate) fn file_digest(path: &str) -> Result<String, String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).map_err(|error| format!("unreadable: {error}"))?;
    if let Ok(metadata) = file.metadata() {
        if metadata.len() > FILE_DIGEST_MAX_BYTES {
            return Err(format!("too_large: {} bytes", metadata.len()));
        }
    }
    let mut context = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buffer = vec![0u8; 256 * 1024];
    loop {
        match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => context.update(&buffer[..read]),
            Err(error) => return Err(format!("unreadable: {error}")),
        }
    }
    Ok(context.finish().as_ref().iter().map(|byte| format!("{byte:02x}")).collect())
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

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.read_image_base64(path, max_bytes) -> JSON
///
/// Probe by magic bytes and read a supported image with a hard allocation bound.
/// `not_image` is an ordinary answer: Lua then uses the UTF-8 text reader. The
/// base64 is transport across the Lua/WIT seam; it is not a model-facing result.
pub extern "C-unwind" fn read_image_base64(l: *mut LuaState) -> c_int {
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
/// Files that hold a credential: created owner-only, never readable in between (a later chmod left a
/// window). Anything else keeps the umask default, so a script or web asset the agent writes is not
/// silently made private.
fn secret_file(name: &str) -> bool {
    // `*.key` includes the `/vault` keys (lua/core/keys.lua): one secret per file, owner-only.
    matches!(name, "credentials.json" | "auth.json" | "env" | "vault.env") || name.ends_with(".key")
}

fn write_atomic(path: &str, text: &str) -> bool {
    use std::io::Write;
    // Write through a symlink, not over it: renaming onto the link replaced it with a regular file and
    // silently detached a linked dotfile from its real location.
    let resolved = std::fs::canonicalize(path).ok().filter(|real| real.is_file());
    let target_buf = resolved.unwrap_or_else(|| std::path::PathBuf::from(path));
    let target = target_buf.as_path();
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
    let private = secret_file(&name);
    #[cfg(unix)] let prior_permissions=std::fs::metadata(target).ok().map(|m|m.permissions());
    let written = (|| -> std::io::Result<()> {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::{OpenOptionsExt,PermissionsExt};
            if private {options.mode(0o600);}
            else if let Some(p)=&prior_permissions {options.mode(p.mode());}
        }
        #[cfg(not(unix))]
        let _ = private;
        let mut file = options.open(&temporary)?;
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
        let mode=if private {0o600} else {metadata.permissions().mode()};
        if std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(mode)).is_err() {
            let _=std::fs::remove_file(&temporary);return false;
        }
    }
    match std::fs::rename(&temporary, target) {
        Ok(()) => {
            // The rename is durable only once the directory entry is: fsync the directory too.
            #[cfg(unix)]
            if let Ok(dir) = std::fs::File::open(&directory) {
                let _ = dir.sync_all();
            }
            true
        }
        Err(error) => {
            eprintln!("[write] atomic replacement refused for {} ({error}); original retained",target.display());
            let _ = std::fs::remove_file(&temporary);
            false
        }
    }
}

#[cfg(test)]
mod atomic_write_tests {
    #[test]
    fn replacement_preserves_bytes_and_refuses_invalid_target() {
        let root=std::env::temp_dir().join(format!("wa-atomic-{}",super::new_uuid()));
        std::fs::create_dir_all(&root).unwrap();
        let path=root.join("file");
        assert!(super::write_atomic(&path.display().to_string(),"original"));
        assert!(super::write_atomic(&path.display().to_string(),"new\0tail"));
        assert_eq!(std::fs::read(&path).unwrap(),b"new\0tail");
        assert!(!super::write_atomic(&root.display().to_string(),"must not truncate"));
        assert_eq!(std::fs::read(&path).unwrap(),b"new\0tail");
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            let secret=root.join("credentials.json");std::fs::write(&secret,"old").unwrap();
            std::fs::set_permissions(&secret,std::fs::Permissions::from_mode(0o644)).unwrap();
            assert!(super::write_atomic(&secret.display().to_string(),"new"));
            assert_eq!(std::fs::metadata(secret).unwrap().permissions().mode()&0o777,0o600);
        }
        std::fs::remove_dir_all(root).unwrap();
    }
}

    /// host.write_file(path, text) -> a Lua boolean (written atomically).
    /// Not JSON: one true/false, and the graph index is told about the write.
pub extern "C-unwind" fn write_file(l: *mut LuaState) -> c_int {
    let path = arg_string(l, 1).unwrap_or_default();
    let text = arg_string(l, 2).unwrap_or_default();
    let ok = write_atomic(&path, &text);
    if ok {crate::graph::native_write(&path);}
    unsafe { wa_host_support::lua::lua_pushboolean(l, ok as c_int) };
    1
}

/// The node-wide default deadline for a `bash`/`shell` call. `/health` reports this same number;
/// `effective_exec_timeout_seconds` applies call overrides and child budgets before execution.
pub(crate) fn exec_timeout_seconds() -> u64 {
    std::env::var("WASM_AGENT_EXEC_TIMEOUT_SECONDS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(300u64)
}

/// Resolve the exact foreground shell timeout used by both the tool trace and `host.exec`.
fn effective_exec_timeout_seconds(requested_seconds: Option<u64>) -> Result<u64, String> {
    let mut seconds = match requested_seconds {
        Some(value) if (1..=86_400).contains(&value) => value,
        Some(_) => return Err("invalid_timeout_seconds".into()),
        None => exec_timeout_seconds(),
    };
    if let Some(remaining) = crate::subagents::remaining_budget() {
        seconds = seconds.min(remaining.as_secs().max(1));
    }
    Ok(seconds)
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
    let seconds = effective_exec_timeout_seconds(requested_seconds)?;
    crate::operations::foreground(program, flag, command, cwd, seconds, &Value::Null)
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.operation(action, args_json) -> operation receipt/state/output | {error}
pub extern "C-unwind" fn operation(l: *mut LuaState) -> c_int {
    let action = arg_string(l, 1).unwrap_or_default();
    let args = arg_string(l, 2).unwrap_or_else(|| "{}".into());
    let result = serde_json::from_str(&args).map_err(|e|e.to_string())
        .and_then(|args|crate::operations::control(&action, &args, shell_config()));
    push_json(l, &result.unwrap_or_else(|error|json!({"ok":false,"error":error})));
    1
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.jobs(action, args_json): local automation management, never execution.
pub extern "C-unwind" fn jobs(l: *mut LuaState) -> c_int {
    let action=arg_string(l,1).unwrap_or_else(||"list".into());
    let args:Value=serde_json::from_str(&arg_string(l,2).unwrap_or_else(||"{}".into())).unwrap_or(Value::Null);
    let root=std::path::PathBuf::from(std::env::var("HOME").unwrap_or_else(|_|".".into())).join(".wasm-agent/sentinel/jobs.db");
    let store=wa_jobs::Store::new(root);
    let result=match action.as_str() {
        "list"=>store.list().map(|jobs|json!({"jobs":jobs})),
        "history"=>store.history(),
        "enable"=>store.enable(args["id"].as_str().unwrap_or(""),true),
        "disable"=>store.enable(args["id"].as_str().unwrap_or(""),false),
        // The numbers a job carries, moved from the surface that shows them. The store decides what a
        // control may be and what an edit costs; this route only names the job and the values.
        "controls"=>store.set_controls(args["id"].as_str().unwrap_or(""),&args["controls"]),
        _=>Err("unknown_job_action".into()),
    };
    push_json(l,&result.unwrap_or_else(|e|json!({"error":e.to_string()})));1
}

/// Not exposed as a model tool or HTTP route.
/// Internal scheduler enqueue; answers JSON text of the scheduler's receipt, never a Lua table.
pub extern "C-unwind" fn enqueue_completion(l: *mut LuaState) -> c_int {
    let body=arg_string(l,1).unwrap_or_default();
    push_json(l,&crate::serve::enqueue_completion(&body));
    1
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.subagent(action, args_json): the local subagent runtime.
///
/// Agent policy lives in Lua (`lua/core/subagents.lua`): which profile, which
/// tools, which prompt, which budgets, and how a caller's owner is derived. This
/// host function only owns the durable record, the OS thread, the capacity and
/// the cancellation flag, so a Lua interpreter is never the thing that keeps a
/// child alive. Owner scoping is enforced here as well as in Lua: a caller can
/// only read or cancel a task it owns.
pub extern "C-unwind" fn subagent(l: *mut LuaState) -> c_int {
    let action = arg_string(l, 1).unwrap_or_default();
    let args: Value = serde_json::from_str(&arg_string(l, 2).unwrap_or_else(|| "{}".into()))
        .unwrap_or(Value::Null);
    push_json(l, &crate::subagents::control(&action, &args).unwrap_or_else(|error| json!({"ok": false, "error": error})));
    1
}

    /// Answers JSON text; A string the caller decodes (`lua/vendor/json.lua`), never a Lua table.
/// Atomic named-resource claims. Resource choice and authorization stay in Lua.
pub extern "C-unwind" fn binding_state(l:*mut LuaState)->c_int {
    let action=arg_string(l,1).unwrap_or_default();
    let args=arg_string(l,2).and_then(|s|serde_json::from_str::<Value>(&s).ok()).unwrap_or(Value::Null);
    push_json(l,&wa_rendezvous::binding_runtime::state(&action,&args).unwrap_or_else(|error|json!({"ok":false,"error":error})));1
}
/// `main.rs`, never by a script.
/// **One string, not a table.** `serve` is refused here: the node's own claim at startup is made in
///
/// host.binding_transport(action) -> JSON text of the binding transport's answer (`{ok, …}` or `{ok:false, error}`).
pub extern "C-unwind" fn binding_transport(l:*mut LuaState)->c_int {
    let action=arg_string(l,1).unwrap_or_default();
    // `serve` is the node's own claim at startup (main.rs), never a script's.
    if action=="serve"{push_json(l,&json!({"ok":false,"error":"binding_transport_action_invalid"}));return 1;}
    push_json(l,&wa_rendezvous::binding_runtime::transport(&action).unwrap_or_else(|error|json!({"ok":false,"error":error})));1
}

/// **One string, not a table.** Resource choice and authorization stay in Lua.
///
/// host.resource(action, args_json) -> JSON text of the resource action's answer (`{ok, …}` or `{ok:false, error}`).
pub extern "C-unwind" fn resource(l: *mut LuaState) -> c_int {
    let action=arg_string(l,1).unwrap_or_default();
    let args=arg_string(l,2).and_then(|raw|serde_json::from_str::<Value>(&raw).ok()).unwrap_or(Value::Null);
    push_json(l,&crate::resources::control(&action,&args).unwrap_or_else(|error|json!({"ok":false,"error":error})));
    1
}

/// effective exec timeout.
/// supervised operation runtime (`docs/OPERATIONS.md`); this call waits for it, bounded by the
/// **One string, not a table**: every use decodes it. The command goes through the path guard and the
///
/// (`{code, ok, stdout, stderr, operation_id, timing, …}`, or `{error}`).
/// host.exec(command, cwd, timeout_seconds?, context_json?) -> JSON text of the command result
pub extern "C-unwind" fn exec(l: *mut LuaState) -> c_int {
    let command = arg_string(l, 1).unwrap_or_default();
    let cwd = arg_string(l, 2).unwrap_or_default();
    let requested = arg_integer(l, 3).and_then(|value| u64::try_from(value).ok());
    let (program, flag) = shell_config();
    let context = arg_string(l, 4).and_then(|raw| serde_json::from_str::<Value>(&raw).ok()).unwrap_or(Value::Null);
    let outcome = effective_exec_timeout_seconds(requested).and_then(|seconds|
        crate::operations::foreground(program, flag, &command, &cwd, seconds, &context));
    push_json(l, &outcome.unwrap_or_else(|error| json!({"error": error})));
    1
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.client(action, args_json) -> result from the client machine | {error}
///
/// The failure path is deliberately verbose, because it is the only part of this
/// interface an agent reads *while confused*. It used to say "start the desktop
/// client with `wa ui`" for every case, which was wrong for the one that actually
/// happens (a wedged bridge, with the window perfectly healthy) and would have
/// put a second window on the same bridge.
pub extern "C-unwind" fn client(l: *mut LuaState) -> c_int {
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
            // Nothing was handed to the client, so there is no uncertain effect to
            // inspect. Lua reads this to keep the run's effect claims usable: without
            // it, one call against a closed window branded the run as uncertain and
            // took the client away from it for the rest of the run.
            map.insert("effect".into(), json!("none"));
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

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.client_status() -> JSON text of {connected, last_seen_secs, queued}
pub extern "C-unwind" fn client_status(l: *mut LuaState) -> c_int {
    let host = host_of(l);
    push_json(l, &host.client.status());
    1
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.node_identity() -> JSON text of {node_id, public_key}
pub extern "C-unwind" fn node_identity(l: *mut LuaState) -> c_int {
    match wa_rendezvous::node::Identity::load() {
        Ok(identity) => push_json(
            l,
            &json!({"node_id": identity.node_id, "public_key": identity.public_key}),
        ),
        Err(error) => push_json(l, &json!({"error": error})),
    }
    1
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.sign(text) -> JSON text of {signature}
pub extern "C-unwind" fn sign(l: *mut LuaState) -> c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    match wa_rendezvous::node::Identity::load() {
        Ok(identity) => push_json(l, &json!({"signature": identity.sign(&text)})),
        Err(error) => push_json(l, &json!({"error": error})),
    }
    1
}

/// host.verify(public_key, text, signature) -> boolean
pub extern "C-unwind" fn verify(l: *mut LuaState) -> c_int {
    let public_key = arg_string(l, 1).unwrap_or_default();
    let text = arg_string(l, 2).unwrap_or_default();
    let signature = arg_string(l, 3).unwrap_or_default();
    let ok = wa_rendezvous::node::verify(&public_key, &text, &signature);
    unsafe { wa_host_support::lua::lua_pushboolean(l, ok as c_int) };
    1
}

/// host.sleep(milliseconds) — used between deterministic spell steps.
pub extern "C-unwind" fn sleep(l: *mut LuaState) -> c_int {
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

    /// host.log(message) -> no value. Writes one redacted line to the node's log.
pub extern "C-unwind" fn log(l: *mut LuaState) -> c_int {
    if let Some(message) = arg_string(l, 1) {
        eprintln!("[lua] {}", redact(&message));
    }
    0
}

/// host.stream(json) -> push one server-sent event to the connected UI.
pub extern "C-unwind" fn stream(l: *mut LuaState) -> c_int {
    if let Some(payload) = arg_string(l, 1) {
        crate::serve::write_event(&payload);
    }
    0
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.plugins() -> JSON `[{name, description, parameters}, ...]`
pub extern "C-unwind" fn plugins(l: *mut LuaState) -> c_int {
    let host = host_of(l);
    let list = host
        .plugins
        .lock()
        .map(|registry| registry.describe_all())
        .unwrap_or_else(|_| json!([]));
    push_json(l, &list);
    1
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.invoke(name, arguments_json) -> plugin JSON result | {error}
pub extern "C-unwind" fn invoke(l: *mut LuaState) -> c_int {
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

/// The provider's own backoff instruction, in milliseconds.
///
/// `retry-after-ms` wins over `retry-after` (seconds). An HTTP-date form is deliberately not parsed:
/// no provider we use has sent one, and guessing a clock offset is worse than returning `None`.
/// A missing header returns `None`; the caller decides its own cap.
fn retry_after_ms(headers: &ureq::http::HeaderMap) -> Option<u64> {
    if let Some(value) = headers.get("retry-after-ms").and_then(|value| value.to_str().ok()) {
        if let Ok(ms) = value.trim().parse::<u64>() {
            return Some(ms);
        }
    }
    let value = headers.get("retry-after")?.to_str().ok()?.trim();
    value.parse::<u64>().ok().map(|seconds| seconds.saturating_mul(1000))
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.http(method, url, headers_json, body) -> {status, body} | {error}
pub extern "C-unwind" fn http(l: *mut LuaState) -> c_int {
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
                let mut request = agent_for_call(&url)?.get(&url);
                for (key, value) in &headers {
                    request = request.header(key, value);
                }
                request.call().map_err(|e| e.to_string())?
            }
            "POST" => {
                let mut request = agent_for_call(&url)?.post(&url);
                for (key, value) in &headers {
                    request = request.header(key, value);
                }
                request.send(body.as_bytes()).map_err(|e| e.to_string())?
            }
            other => return Err(format!("method_not_supported:{other}")),
        };
        let status = response.status().as_u16();
        let retry_after = retry_after_ms(response.headers());
        let text = response.into_body().read_to_string().map_err(|e| e.to_string())?;
        let mut value = json!({"status": status, "body": text});
        if let Some(ms) = retry_after {
            value["retry_after_ms"] = json!(ms);
        }
        Ok(value)
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
    /// host.beat() -> no value. Marks the calling interpreter alive for the supervisor.
pub extern "C-unwind" fn beat(_l: *mut LuaState) -> c_int {
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
    /// The row to draw on, 1-based from the top of the window, when the caller keeps a frame and
    /// the status line owns a row of its own. `None` means "the row the cursor is on", which is
    /// what a caller with no frame has - and the row the reader may be typing on.
    row: Option<u16>,
    width: Option<usize>,
    /// When the current step began, for `{s}`; the run's start (`started`) when absent.
    step_started: Option<f64>,
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

/// The step clock (`{s}`), the twin of `cli_view.step_clock`: whole seconds, then minutes.
fn ticker_step(seconds: f64) -> String {
    let value = if seconds.is_finite() && seconds > 0.0 { seconds.floor() as u64 } else { 0 };
    if value < 60 { format!("{value}s") } else { format!("{}m{:02}s", value / 60, value % 60) }
}

/// The run clock (`{T}`), the twin of `cli_view.run_clock`: `m:ss`, `h:mm:ss` past an hour.
fn ticker_clock(seconds: f64) -> String {
    let value = if seconds.is_finite() && seconds > 0.0 { seconds.floor() as u64 } else { 0 };
    if value < 3600 { format!("{}:{:02}", value / 60, value % 60) }
    else { format!("{}:{:02}:{:02}", value / 3600, (value % 3600) / 60, value % 60) }
}

/// One frame of the animated line: `{m}` becomes the next mark, `{t}` the clock.
fn ticker_render(spec: &TickerSpec, ticks: usize) -> String {
    let mark = if spec.marks.is_empty() {
        ""
    } else {
        spec.marks[(spec.frame.wrapping_add(ticks)) % spec.marks.len()].as_str()
    };
    let now = ticker_seconds();
    let clock = ticker_duration(now - spec.started);
    let text = spec.line.replace("{m}", mark).replace("{t}", &clock)
        .replace("{s}", &ticker_step(now - spec.step_started.unwrap_or(spec.started)))
        .replace("{T}", &ticker_clock(now - spec.started));
    let width = spec.width.map(|width| console_size().map(|(cols, _)| width.min(cols as usize)).unwrap_or(width));
    match width {
        Some(width) if visible_width(&text) > width => {
            // A changing clock must not wrap the footer. Strip colour before
            // clipping rather than cutting an escape sequence on a narrow screen.
            let mut plain = String::new();
            let mut chars = text.chars().peekable();
            while let Some(ch) = chars.next() {
                if ch == '\u{1b}' && chars.peek() == Some(&'[') {
                    for ch in chars.by_ref().skip(1) { if ('@'..='~').contains(&ch) { break; } }
                } else { plain.push(ch); }
            }
            plain.chars().take(width.saturating_sub(1)).collect::<String>() + "\u{2026}"
        }
        _ => text,
    }
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
/// The cursor is saved and restored around the frame (CSI `s` / `u`), because the cursor is also
/// where the reader's next keystroke lands. A terminal that ignores those leaves the cursor at the
/// end of the frame: that garbles the display of a line typed during a run and loses nothing - the
/// line is read from the reader thread, never from the screen. `cli_view.status_draw` obeys the same
/// rule on the Lua side, because the view writes this line too.
fn ticker_frame(text: &str, drawn: usize, row: Option<u16>) -> (String, usize) {
    let cols = visible_width(text);
    let mut drawn = drawn;
    let mut frame = String::new();
    // With a row of its own the line is not sharing the reader's cursor row, so it needs no commit
    // and the cursor goes to that row instead of to the column the frame started in.
    let row = row.filter(|row| *row > 0);
    if row.is_none() && drawn > 0 && cols > drawn {
        frame.push_str("\r\n");
        drawn = 0;
    }
    frame.push_str("\u{1b}[?25l\u{1b}[s");
    match row {
        Some(row) => frame.push_str(&format!("\u{1b}[{row};1H")),
        None => frame.push('\r'),
    }
    frame.push_str(text);
    for _ in cols..drawn {
        frame.push(' ');
    }
    // A row of its own is the status line's alone: erase what a wider frame (an emoji counts one
    // character here and draws two cells) may have left at its end.
    if row.is_some() { frame.push_str("\u{1b}[K"); }
    frame.push_str("\u{1b}[u\u{1b}[?25h");
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
                let (text, spec_row) = {
                    let guard = spec.lock().unwrap_or_else(|error| error.into_inner());
                    (ticker_render(&guard, ticks), guard.row)
                };
                // Resizing a ConPTY resets its margins. Reclaim the editor and
                // footer while Lua is blocked, before drawing on the new last row.
                let spec_row = refresh_editor_size().map(|rows| rows as u16).or(spec_row);
                let (frame, cols) = ticker_frame(&text, drawn, spec_row);
                drawn = cols;
                if panel_open() || !status_visible() { ticks = ticks.wrapping_add(1); std::thread::sleep(std::time::Duration::from_millis(TICKER_INTERVAL_MS)); continue; }
                // Never erase to the end of the row: the reader's own typing starts one column
                // after this line ends, and erasing from the cursor to the right takes it with it.
                // Flushed every time: this text has no newline to flush it.
                let _ = write_at_editor(&frame);
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
/// `row` (1-based from the top of the window) names the row to draw on, for a caller that keeps a
/// frame: a view with a scroll region for its output, a status row, and the reader's input row below
/// it. The ticker places the cursor on that row for each frame and hands it back, so the terminal's
/// cursor can stay on the row the reader types on. Without `row` the line is drawn at the cursor,
/// which is that same row - and then the line is bounded to the columns it drew, because the reader
/// is typing there.
///
/// No argument, or `nil`, stops it: the ticker stops drawing and leaves the line as the
/// caller's to erase, which is what the view does before it prints anything else. Returns
/// `true` while a ticker is running, and `nil` when none is (no argument, a spec that does
/// not parse, or `WASM_AGENT_CLI_TICKER=off`).
pub extern "C-unwind" fn ticker(l: *mut LuaState) -> c_int {
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
        unsafe { wa_host_support::lua::lua_pushboolean(l, 1) };
    } else {
        unsafe { wa_host_support::lua::lua_pushnil(l) };
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
    // A row is 1-based and positive; anything else is "no row", not row zero.
    let row = value.get("row").and_then(Value::as_u64).filter(|row| *row > 0).map(|row| row as u16);
    let width = value.get("width").and_then(Value::as_u64).filter(|width| *width > 0).map(|width| width as usize);
    let step_started = value.get("step_started").and_then(Value::as_f64);
    Some(TickerSpec { line, marks, started, frame, row, width, step_started })
}

#[cfg(test)]
mod ticker_tests {
    use super::*;

    fn spec(line: &str, frame: usize) -> TickerSpec {
        TickerSpec { line: line.to_string(), marks: vec!["one ".to_string(), "two ".to_string()], started: ticker_seconds(), frame, row: None, width: None, step_started: None }
    }

    fn rowed(line: &str, row: u16) -> TickerSpec {
        TickerSpec { line: line.to_string(), marks: vec!["one ".to_string()], started: ticker_seconds(), frame: 0, row: Some(row), width: None, step_started: None }
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
    fn a_clock_cannot_wrap_the_footer() {
        let mut spec = spec("\u{1b}[33mThinking\u{1b}[0m {t} many statistics", 0);
        spec.width = Some(12);
        let text = ticker_render(&spec, 0);
        assert_eq!(visible_width(&text), 12);
        assert!(!text.contains('\u{1b}'));
        assert!(text.ends_with('\u{2026}'));
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
        let (frame, cols) = ticker_frame("  {m}Thinking - {t}", 0, None);
        assert!(!frame.contains("\u{1b}[2K"), "erase-to-end-of-line is gone: {frame:?}");
        assert!(frame.starts_with("\u{1b}[?25l\u{1b}[s\r"), "the cursor is saved before the write: {frame:?}");
        assert!(frame.ends_with("\u{1b}[u\u{1b}[?25h"), "and restored after it: {frame:?}");
        assert_eq!(cols, visible_width("  {m}Thinking - {t}"));

        // A shorter line pads the columns it drew, so no tail of the last frame is left behind.
        let (shorter, cols) = ticker_frame("  short", 12, None);
        assert!(shorter.contains("  short     "), "a shorter line is padded: {shorter:?}");
        assert_eq!(cols, 12, "and the high-water mark stands, so the pad is not drawn again");

        // A longer line commits the row instead of writing over columns that may hold the
        // reader's text.
        let (longer, cols) = ticker_frame("  a longer line than before", 12, None);
        assert!(longer.starts_with("\r\n"), "growth starts a fresh row: {longer:?}");
        assert_eq!(cols, visible_width("  a longer line than before"));

        // The first frame has nothing to commit: it starts on the row the cursor is already on.
        let (first, _) = ticker_frame("  {m}", 0, None);
        assert!(!first.starts_with("\r\n"), "the first frame does not add a line: {first:?}");
    }

    /// With a row of its own the line is not sharing the reader's row, so it neither commits nor
    /// returns to the column it started in: it is placed, drawn, and the cursor goes back to
    /// wherever the reader left it.
    #[test]
    fn a_rowed_frame_is_placed_instead_of_returned_to() {
        let (frame, cols) = ticker_frame("  {m}Thinking", 0, Some(23));
        assert!(frame.starts_with("\u{1b}[?25l\u{1b}[s\u{1b}[23;1H"), "the row is placed, not the cursor: {frame:?}");
        assert!(frame.ends_with("\u{1b}[u\u{1b}[?25h"), "and the reader's cursor comes back: {frame:?}");
        assert!(!frame.starts_with("\r\n"), "a rowed frame has nothing to commit: {frame:?}");
        assert!(!frame.contains("\u{1b}[2K"), "and erases nothing: {frame:?}");
        assert_eq!(cols, visible_width("  {m}Thinking"));

        // Growing across a rowed frame must not commit a line either: it is not the reader's row.
        let (grown, cols) = ticker_frame("  a longer status line", 4, Some(23));
        assert!(!grown.contains("\r\n"), "no commit on growth: {grown:?}");
        assert!(grown.contains("  a longer status line"), "the line is drawn whole: {grown:?}");
        assert_eq!(cols, visible_width("  a longer status line"));

        // A spec carries the row through: `row` is 1-based, and zero is not a row.
        let parsed = parse_ticker_spec("{\"line\":\"x\",\"row\":23}").expect("parses");
        assert_eq!(parsed.row, Some(23));
        assert_eq!(parse_ticker_spec("{\"line\":\"x\"}").expect("parses").row, None);
        assert_eq!(parse_ticker_spec("{\"line\":\"x\",\"row\":0}").expect("parses").row, None);
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

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.http_stream(method, url, headers_json, body) -> aggregated completion.
///
/// Reads an OpenAI-compatible SSE stream, forwards each content delta to the UI
/// (server-sent event `delta`), and returns `{status, content, reasoning,
/// finish_reason, tool_calls, usage}` so the caller can continue the tool loop.
/// Reasoning is kept apart from content: it is the model's thinking, not its
/// answer, and conflating the two is how an unanswered run looks answered.
///
/// Tool calls stream as provisional `decision` events too, in the same shape the subscription path
/// publishes (`lua/core/subscription_wire.lua`): announced when the model starts writing a call, its
/// arguments a bounded preview, completed exactly once when the call is finished. Without them the
/// window only showed a tool call after it had already executed. See `emit_decision` above for the
/// per-field contract.
/// Call the Lua global `wa_stream_event(payload)` from inside a host function.
///
/// Same thread and same state as the caller, the way `wa_mesh_admit` is called; the global is absent on
/// a build whose view predates this, and an absent global is a no-op rather than an error: a node whose
/// Lua does not define it must still stream to its own sink.
unsafe fn call_lua_stream_event(l: *mut LuaState, payload: &str) {
    use wa_host_support::lua::{cstr, lua_getglobal, lua_gettop, lua_pcallk, lua_pushlstring, lua_settop, LUA_OK};
    if l.is_null() || payload.is_empty() {
        return;
    }
    let base = lua_gettop(l);
    lua_getglobal(l, cstr("wa_stream_event").as_ptr());
    lua_pushlstring(l, payload.as_ptr() as *const std::os::raw::c_char, payload.len());
    if lua_pcallk(l, 1, 0, 0, 0, std::ptr::null_mut()) != LUA_OK {
        // A view that cannot read the payload must not break the model call.
    }
    lua_settop(l, base);
}

/// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table:
/// `{status, content, commentary, tool_calls, termination, chunks, ...}` for a stream that ended, or
/// `{error}` for one that could not be read. Same arguments as `host.http`, plus an optional fifth
/// argument `{"first_response_seconds": N}` that gives this call its own deadline.
pub extern "C-unwind" fn http_stream(l: *mut LuaState) -> c_int {
    let method = arg_string(l, 1).unwrap_or_else(|| "POST".into()).to_uppercase();
    let url = arg_string(l, 2).unwrap_or_default();
    let headers_json = arg_string(l, 3).unwrap_or_else(|| "{}".into());
    let body = arg_string(l, 4).unwrap_or_default();
    let headers = parse_headers(&headers_json);
    // An optional fifth argument names this call's own deadline: `{"first_response_seconds": N}`.
    // Absent (the default for every other caller) keeps the process-wide timeouts exactly as they
    // were, so a long streaming answer is never capped by a provider's choice to bound itself.
    let first = arg_string(l, 5).and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .and_then(|options| options.get("first_response_seconds").and_then(|value| value.as_u64()))
        .filter(|seconds| (1..=3600).contains(seconds))
        .unwrap_or(0);
    // A CLI run has no SSE sink, so the deltas this call emits would be dropped. Hand them to the
    // interpreter instead: `wa_stream_event` (lua/core/cli_view.lua) turns each one into the event the
    // view already knows how to print. Same thread, same state, guarded against re-entry.
    let forwarder: std::rc::Rc<dyn Fn(&str)> = std::rc::Rc::new(move |payload: &str| {
        unsafe { call_lua_stream_event(l, payload) }
    });
    let _forwarding = crate::serve::forward_events_to(forwarder);
    let outcome = stream_completion(&method, &url, &headers, &body, first);
    match outcome {
        Ok(value) => push_json(l, &value),
        Err(error) => push_json(l, &json!({"error": error})),
    }
    1
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.http_sse(method, url, headers_json, body, on_line) -> {status, lines, termination}
///
/// POSTs to an endpoint that answers `text/event-stream` and hands **each response line** to the
/// Lua callback `on_line(text)` as it arrives, so a caller can parse a provider's own SSE dialect
/// while it streams. The framing stays Lua's on purpose: `host.http_stream` below reads *one*
/// dialect (OpenAI-compatible `data: {...}` chunks with a `choices[0].delta` body) and turns it
/// into UI events, and a second provider whose event names and completion semantics differ cannot
/// be expressed as that dialect without flattening it. A line reader is the capability; the
/// protocol is the caller's.
///
/// - **A line at a time, never the whole body.** The callback runs while the socket is open and
///   the response is still being read, so a live provider stream reaches the UI as it arrives
///   instead of after it ends. Nothing is buffered here.
/// - **`on_line` is a function, and a Lua error in it stops the read.** The error crosses back as
///   `{error, termination:"line_callback_failed"}` after the socket is dropped; a caller that
///   raises `run_cancelled` or its own deadline from the callback therefore ends the read at that
///   line rather than at the end of the stream.
/// - **An explicit `false` from the callback ends the read successfully.** The protocol owner
///   can stop at its terminal frame instead of waiting for socket EOF after a completed response.
///   A missing return value retains the original read-to-EOF behavior.
/// - **A non-200 is not a stream.** The status and a bounded body come back exactly as
///   `host.http` reports them, so an auth or quota refusal is visible rather than an empty stream
///   that looks like a provider with nothing to say.
/// - **Cancellation is checked per line**, and the request uses the same shutdown-aware transport
///   as `host.http`/`host.http_stream`, so a cancelled child stops reading at the next chunk.
///   `termination` says how the read ended: `eof`, `cancelled`, `http_error`, `request_failed`,
///   `read_failed`, `line_callback_failed`, `callback_stopped`. EOF is *not* an error here: whether a stream that
///   ended with no terminal event is a failure is a question only the protocol's owner can answer
///   (its event mapping is what knows which event completes a response).
/// - Returns `nil` for nothing: the callback is required, and a call without one is refused, not
///   read into nothing.
pub extern "C-unwind" fn http_sse(l: *mut LuaState) -> c_int {
    let method = arg_string(l, 1).unwrap_or_else(|| "POST".into()).to_uppercase();
    let url = arg_string(l, 2).unwrap_or_default();
    let headers_json = arg_string(l, 3).unwrap_or_else(|| "{}".into());
    let body = arg_string(l, 4).unwrap_or_default();
    let seconds = if unsafe { wa_host_support::lua::lua_type(l, 6) } <= wa_host_support::lua::LUA_TNIL {
        3600
    } else { arg_integer(l, 6).unwrap_or(0) };
    if !(1..=86400).contains(&seconds) {
        push_json(l, &json!({"error": "invalid_sse_timeout: expected 1..86400 seconds"}));
        return 1;
    }
    let headers = parse_headers(&headers_json);
    if unsafe { wa_host_support::lua::lua_type(l, 5) } == wa_host_support::lua::LUA_TNIL {
        push_json(l, &json!({"error": "http_sse_requires_on_line"}));
        return 1;
    }
    if method != "POST" {
        push_json(l, &json!({"error": "method_not_supported"}));
        return 1;
    }
    if run_cancel_requested() {
        crate::subagents::clear_active_socket();
        push_json(l, &json!({"error": "run_cancelled", "termination": "cancelled"}));
        return 1;
    }
    let _heartbeat = crate::serve::Heartbeat::start();
    let (_, read, _) = http_timeouts();
    let total = std::time::Duration::from_secs(seconds as u64);
    let total = crate::subagents::remaining_budget().map(|remaining| total.min(remaining)).unwrap_or(total);
    let config = match build_config(&url, read) {
        Ok(config) => config,
        // No answer about trust, so no request: the shape every other refusal here takes.
        Err(error) => {
            crate::subagents::clear_active_socket();
            push_json(l, &json!({"error": error, "termination": "request_failed"}));
            return 1;
        }
    };
    let (stream_agent, stream_control) = crate::http_transport::stream_agent(
        config, std::time::Duration::from_secs(read), total);
    let mut request = stream_agent.post(&url);
    for (key, value) in &headers {
        request = request.header(key, value);
    }
    let response = match request.send(body.as_bytes()) {
        Ok(response) => response,
        Err(error) => {
            crate::subagents::clear_active_socket();
            push_json(l, &json!({"error": error.to_string(), "termination": "request_failed"}));
            return 1;
        }
    };
    let status = response.status().as_u16();
    stream_control.received_headers();
    if status != 200 {
        let retry_after = retry_after_ms(response.headers());
        let text = response.into_body().read_to_string().unwrap_or_default();
        crate::subagents::clear_active_socket();
        let head: String = text.chars().take(2048).collect();
        let mut value = json!({"status": status, "body": head, "termination": "http_error"});
        if let Some(ms) = retry_after {
            value["retry_after_ms"] = json!(ms);
        }
        push_json(l, &value);
        return 1;
    }
    let reader = std::io::BufReader::new(response.into_body().into_reader());
    let outcome = read_sse_lines(reader, |line| call_lua_string(l, 5, line));
    crate::subagents::clear_active_socket();
    let value = match outcome {
        Ok((lines, termination)) => json!({"status": status, "lines": lines, "termination": termination}),
        Err(failure) => json!({"error": failure.message, "termination": failure.termination,
            "status": status, "lines": failure.lines}),
    };
    push_json(l, &value);
    1
}

/// How an SSE read ended, and how much of it arrived.
#[derive(Debug)]
struct SseFailure {
    message: String,
    termination: &'static str,
    lines: u64,
}

/// Read a response one line at a time, handing each line to `on_line` as it arrives.
///
/// Split out from `http_sse` so the two properties that matter can be tested without a socket: the
/// lines arrive **in order and unmodified**, and any failure - a cancel, a read error, or a Lua
/// error raised by the callback - stops the read at that line instead of at the end of the body.
/// A residual line at EOF is handed over like any other (a stream whose last frame has no trailing
/// newline is a real ending), and a read that leaves the body empty is not an error here: whether
/// an empty stream is a failure is the protocol owner's question.
fn read_sse_lines<R, F>(reader: R, mut on_line: F) -> Result<(u64, &'static str), SseFailure>
where
    R: std::io::BufRead,
    F: FnMut(&str) -> Result<bool, String>,
{
    let mut lines = 0u64;
    for line in reader.lines() {
        if run_cancel_requested() {
            return Err(SseFailure { message: "run_cancelled".into(), termination: "cancelled", lines });
        }
        let line = match line {
            Ok(line) => line,
            Err(error) => {
                return Err(SseFailure { message: error.to_string(), termination: "read_failed", lines })
            }
        };
        lines += 1;
        match on_line(&line) {
            Ok(false) => return Ok((lines, "callback_stopped")),
            Ok(true) => {},
            Err(failure) => return Err(SseFailure {
                message: failure, termination: "line_callback_failed", lines,
            }),
        }
    }
    Ok((lines, "eof"))
}

/// Call a Lua line callback, continuing unless it returns the boolean `false`.
///
/// The one place a host capability calls back into the interpreter, so it is small and total: the
/// callee is anchored in the *caller's* frame (it is an argument of the C function that is
/// running), the stack is restored on both paths, and a Lua error becomes `Err(text)` instead of
/// unwinding through the C boundary. The text is redacted and bounded: it crosses into a provider
/// error path where a token must never appear.
fn call_lua_string(l: *mut LuaState, index: c_int, payload: &str) -> Result<bool, String> {
    use wa_host_support::lua::{lua_gettop, lua_pcallk, lua_settop, lua_tolstring, lua_toboolean,
        lua_type, LUA_OK, LUA_TBOOLEAN};
    unsafe {
        let base = lua_gettop(l);
        wa_host_support::lua::lua_pushvalue(l, index);
        lua_pushlstring(l, payload.as_ptr() as *const c_char, payload.len());
        let status = lua_pcallk(l, 1, 1, 0, 0, std::ptr::null_mut());
        if status == LUA_OK {
            let keep_reading = lua_type(l, -1) != LUA_TBOOLEAN || lua_toboolean(l, -1) != 0;
            lua_settop(l, base);
            return Ok(keep_reading);
        }
        let mut len = 0usize;
        let pointer = lua_tolstring(l, -1, &mut len);
        let message = if pointer.is_null() {
            "lua error".to_string()
        } else {
            String::from_utf8_lossy(std::slice::from_raw_parts(pointer as *const u8, len)).into_owned()
        };
        lua_settop(l, base);
        Err(redact(&message).chars().take(512).collect())
    }
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// host.relay(url, headers_json, body) -> {status}
///
/// POSTs to a peer and forwards every SSE `data:` line straight to our UI
/// client, so a remote node's reply streams here unchanged.
pub extern "C-unwind" fn relay(l: *mut LuaState) -> c_int {
    let url = arg_string(l, 1).unwrap_or_default();
    let headers_json = arg_string(l, 2).unwrap_or_else(|| "{}".into());
    let body = arg_string(l, 3).unwrap_or_default();
    let headers = parse_headers(&headers_json);
    let outcome = (|| -> Result<Value, String> {
        let mut request = agent(&url)?.post(&url);
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

/// The decision preview cap the UI reads, in code points - not bytes, because the count is shown
/// next to text a reader sees and a UTF-8 byte count overcounts every non-ASCII character.
///
/// Kept equal to `subscription_wire.lua`'s `M.DECISION_PREVIEW_CHARS`: the subscription wire is the
/// reference for how a tool decision reaches the window, and the ordinary OpenAI-compatible path
/// must bound what it shows the same way. Otherwise one huge argument would flood the stream, the
/// run's event log and the panel, while the same call through the subscription showed a preview.
const DECISION_PREVIEW_CHARS: usize = 256;

/// Appended to a preview that hit the cap; byte-for-byte the subscription wire's note.
const DECISION_TRUNCATION_NOTE: &str = "\u{2026} [preview only; complete arguments in result]";

/// One tool call's provisional `decision` telemetry, assembled while its arguments stream.
///
/// This is the ordinary path's half of the `decision` event contract the subscription wire already
/// owns (`tool_delta` and `publish_decision` in `lua/core/subscription_wire.lua`): announce once
/// when the first argument fragment arrives, publish again only when the call is re-identified (a
/// later id gives the row the key the `tool` event promotes) or when the preview newly truncates,
/// and complete exactly once when the call is finished. The window's `decision` row therefore
/// behaves the same on both paths - forming, named, then selected - and no second trace format,
/// renderer or UI-only cache is introduced.
#[derive(Default)]
struct ToolDecision {
    id: String,
    name: String,
    preview: String,
    truncated: bool,
    truncation_announced: bool,
    announced: bool,
    announced_id: String,
    announced_name: String,
    completed: bool,
}

impl ToolDecision {
    /// The key the window's `decision` row and the later `tool` event meet on. The subscription
    /// wire never publishes an empty id (it falls back to `wire-<index>`), and neither does this: a
    /// row keyed by `""` could never be found again when the real id arrives.
    fn display_id(&self, index: usize) -> String {
        if self.id.is_empty() { format!("openai-{index}") } else { self.id.clone() }
    }

    /// Give one argument fragment to the bounded preview, exactly as `tool_delta` does.
    fn absorb(&mut self, fragment: &str) {
        let room = DECISION_PREVIEW_CHARS.saturating_sub(self.preview.chars().count());
        self.preview.push_str(&preview_head(fragment, room));
        if fragment.chars().count() > room {
            self.truncated = true;
        }
    }

    /// The update to publish after this delta, or None. Mirrors `publish_decision`'s rule: the
    /// first announcement is provisional, and afterwards only a changed call id or a newly crossed
    /// preview cap publishes again (re-emitting the whole prefix on every token is quadratic).
    fn publish_update(&mut self, index: usize) -> Option<(String, Option<String>)> {
        let display_id = self.display_id(index);
        if !self.announced {
            if self.preview.is_empty() {
                return None;
            }
            self.announced = true;
            self.announced_id = display_id.clone();
            self.announced_name = self.name.clone();
            self.truncation_announced = self.truncated;
            return Some((display_id, None));
        }
        if self.announced_id != display_id {
            let previous = Some(self.announced_id.clone());
            self.announced_id = display_id.clone();
            self.announced_name = self.name.clone();
            return Some((display_id, previous));
        }
        if self.truncated && !self.truncation_announced {
            self.truncation_announced = true;
            return Some((display_id, None));
        }
        if !self.name.is_empty() && self.name != self.announced_name {
            // The name is the row's label, and a provider that streams arguments before the name
            // would otherwise leave the row reading "tool". One update per name, bounded.
            self.announced_name = self.name.clone();
            return Some((display_id, None));
        }
        None
    }
}

/// The first `count` code points of `text`.
fn preview_head(text: &str, count: usize) -> String {
    text.chars().take(count).collect()
}

/// Emit one `decision` event in the exact shape the subscription wire publishes: `type`, `call_id`,
/// `name`, `arguments_text`, `complete`, and the optional `previous_call_id` / `arguments_truncated`.
fn emit_decision(decision: &ToolDecision, display_id: &str, complete: bool, previous_id: Option<&str>) {
    let mut arguments_text = decision.preview.clone();
    if decision.truncated {
        arguments_text.push_str(DECISION_TRUNCATION_NOTE);
    }
    let mut event = serde_json::Map::new();
    event.insert("type".into(), json!("decision"));
    event.insert("call_id".into(), json!(display_id));
    event.insert("name".into(), json!(decision.name));
    event.insert("arguments_text".into(), json!(arguments_text));
    event.insert("complete".into(), json!(complete));
    if let Some(previous) = previous_id {
        if previous != display_id {
            event.insert("previous_call_id".into(), json!(previous));
        }
    }
    if decision.truncated {
        event.insert("arguments_truncated".into(), json!(true));
    }
    crate::serve::write_event(&Value::Object(event).to_string());
}

/// Complete every tool call that was seen, once, after a stream that actually finished.
///
/// Not called for a truncated stream (EOF with neither `[DONE]` nor a finish reason) or for a
/// cancelled or failed read: those arguments are still partial, and marking them complete would
/// claim an execution the tool loop refuses. The subscription wire marks a call complete at its own
/// `item done`; this is the ordinary dialect's equivalent, and it runs at most once per call.
fn complete_decisions(decisions: &mut [ToolDecision], tool_calls: &[Value]) {
    for (index, decision) in decisions.iter_mut().enumerate() {
        if decision.completed {
            continue;
        }
        let final_text = tool_calls
            .get(index)
            .and_then(|call| call["function"]["arguments"].as_str())
            .unwrap_or("");
        // The subscription wire shows the parsed arguments re-encoded, not the raw wire text. An
        // argument string that cannot be parsed is shown as it arrived instead of failing the read:
        // what an unparseable call means is the tool loop's decision, not the reader's.
        let (encoded, truncated) = match serde_json::from_str::<Value>(final_text) {
            Ok(value) => {
                let encoded = value.to_string();
                let truncated = encoded.chars().count() > DECISION_PREVIEW_CHARS;
                (encoded, truncated)
            }
            Err(_) => {
                let text = if final_text.is_empty() { "{}".to_string() } else { final_text.to_string() };
                let truncated = text.chars().count() > DECISION_PREVIEW_CHARS;
                (text, truncated)
            }
        };
        let display_id = decision.display_id(index);
        let previous = if decision.announced && decision.announced_id != display_id {
            Some(decision.announced_id.clone())
        } else {
            None
        };
        decision.preview = preview_head(&encoded, DECISION_PREVIEW_CHARS);
        decision.truncated = truncated;
        decision.completed = true;
        emit_decision(decision, &display_id, true, previous.as_deref());
    }
}

/// What a streamed `function.name` becomes when another delta carries the field. A name arrives once
/// (so a repeat must not double it) but a provider may split it (so a fragment must not replace it):
///
///  - empty, or already the same text, or a repeat of what this name already ends with or starts
///    with -> unchanged;
///  - the whole name so far plus more (`ba` then `sh`) -> the name grows to `bash`;
///  - a later delta carrying the whole name (`ba` then `bash`) -> the whole name wins;
///  - anything else -> appended, because a name that grew wrong is still visible to the tool loop
///    (and to the repair net) instead of being silently dropped.
fn merge_name(accumulated: &str, incoming: &str) -> String {
    if incoming.is_empty() { return accumulated.to_string(); }
    if accumulated.is_empty() { return incoming.to_string(); }
    if accumulated == incoming { return accumulated.to_string(); }
    if accumulated.ends_with(incoming) { return accumulated.to_string(); }
    if accumulated.starts_with(incoming) { return accumulated.to_string(); }
    if incoming.starts_with(accumulated) { return incoming.to_string(); }
    format!("{accumulated}{incoming}")
}

/// One tool call, assembled from every delta that carries it.
///
/// An OpenAI-compatible stream splits a tool call across deltas: the `id` and the `function.name`
/// arrive on the first one (measured on opencode-go/DeepSeek, 14/11: `{"index":0,"id":"call_...",
/// "function":{"name":"bash","arguments":""}}` and then argument fragments only), and a provider
/// may repeat a field it already sent. Two rules keep that from losing what arrived:
///
///  - **A name or an id that arrived is kept.** It is written only when it carries text, so a later
///    delta that repeats the field as an empty string cannot clear it. Before this rule the second
///    delta `{"index":0,"function":{"name":"","arguments":"{..."}}` overwrote the name the first
///    delta delivered, and the call reached the tool loop nameless (`tool_call_name_missing`, node
///    session 400c7145 on 13/11, 14 calls in a row; session 50f2c555 on 11/11).
///  - **A call is identified by `index` when the delta carries one, and by `id` when it does not.**
///    A provider that sends `id` without `index` on a parallel call used to have that call's
///    fragments appended to call 0 - its name and its arguments landing in another call's slot.
#[derive(Default)]
struct ToolCallAssembly {
    calls: Vec<Value>,
    decisions: Vec<ToolDecision>,
    by_id: HashMap<String, usize>,
    last: Option<usize>,
}

impl ToolCallAssembly {
    fn new() -> Self { Self::default() }

    fn slot(&mut self, index: usize) {
        while self.calls.len() <= index {
            self.calls.push(json!({"id": "", "type": "function", "function": {"name": "", "arguments": ""}}));
        }
        while self.decisions.len() <= index {
            self.decisions.push(ToolDecision::default());
        }
    }

    /// The call this delta belongs to: its own `index`, else the call its `id` already opened, else
    /// the last call this stream touched (argument fragments that carry neither).
    fn index_of(&mut self, call: &Value) -> usize {
        let id = call["id"].as_str().unwrap_or("");
        let index = match call["index"].as_u64() {
            Some(index) => {
                let index = index as usize;
                if !id.is_empty() {
                    self.by_id.insert(id.to_string(), index);
                }
                index
            }
            None if !id.is_empty() => match self.by_id.get(id) {
                Some(index) => *index,
                None => {
                    let index = self.calls.len();
                    self.by_id.insert(id.to_string(), index);
                    index
                }
            },
            None => self.last.unwrap_or(0),
        };
        self.last = Some(index);
        self.slot(index);
        index
    }

    /// One delta's tool call: its id, its name and its argument fragment. The fragment is returned so
    /// the caller can feed and publish the provisional decision exactly as before.
    fn absorb(&mut self, call: &Value) -> (usize, Option<String>) {
        let index = self.index_of(call);
        if let Some(id) = call["id"].as_str() {
            if !id.is_empty() {
                self.calls[index]["id"] = json!(id);
                self.decisions[index].id = id.to_string();
            }
        }
        if let Some(name) = call["function"]["name"].as_str() {
            if !name.is_empty() {
                let merged = merge_name(
                    self.calls[index]["function"]["name"].as_str().unwrap_or(""), name);
                self.calls[index]["function"]["name"] = json!(merged);
                self.decisions[index].name = merged;
            }
        }
        match call["function"]["arguments"].as_str() {
            Some(arguments) if !arguments.is_empty() => {
                let previous = self.calls[index]["function"]["arguments"].as_str().unwrap_or("").to_string();
                self.calls[index]["function"]["arguments"] = json!(format!("{previous}{arguments}"));
                (index, Some(arguments.to_string()))
            }
            _ => (index, None),
        }
    }
}

/// Is this send() error a STALL, and therefore safe to replay?
///
/// A stall is one fact (18/11 round 2, finding 5): the request was written and no byte of the response
/// - not even its status line - arrived before the per-call deadline. ureq names that case exactly,
/// and nothing else does, so a refused connection, a TLS failure, an unresolvable host and a connect
/// timeout keep their own names and are never replayed as stalls (a connect that timed out never sent
/// the request; it belongs to the patient connection bucket, lua/core/provider.lua).
///
/// The marker is added ONLY for that case. It used to be added to every send() error, which turned
/// every transport failure into provider_stalled and made the failure layer's name a lie.
fn stall_marker(error: &ureq::Error, first_response_seconds: u64) -> Option<String> {
    if first_response_seconds == 0 { return None; }
    match error {
        ureq::Error::Timeout(ureq::Timeout::RecvResponse) => Some(format!(
            " (provider_stalled: no response within {first_response_seconds}s)")),
        _ => None,
    }
}

fn stream_completion(method: &str, url: &str, headers: &[(String, String)], body: &str, first_response_seconds: u64) -> Result<Value, String> {
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
    let agent = if first_response_seconds > 0 { agent_for_stream(url, first_response_seconds)? } else { agent_for_call(url)? };
    let mut request = agent.post(url);
    for (key, value) in headers {
        request = request.header(key, value);
    }
    let response = request.send(body.as_bytes()).map_err(|error| {
        // Keep the transport's own words - the retry predicates and the failure layer match on them -
        // and add the stall marker only where it is true (stall_marker above).
        match stall_marker(&error, first_response_seconds) {
            Some(marker) => format!("{error}{marker}"),
            None => error.to_string(),
        }
    })?;
    let status = response.status().as_u16();
    if status != 200 {
        let retry_after = retry_after_ms(response.headers());
        let text = response.into_body().read_to_string().unwrap_or_default();
        let mut value = json!({"status": status, "content": "", "tool_calls": [], "body": text});
        if let Some(ms) = retry_after {
            value["retry_after_ms"] = json!(ms);
        }
        return Ok(value);
    }
    let reader = std::io::BufReader::new(response.into_body().into_reader());
    let mut content = String::new();
    let mut commentary = String::new();
    let mut active_phase = String::new();
    let mut final_phase = String::new();
    // Reasoning models stream their thinking in a sibling field, and endpoints
    // spell it differently. pi reads all three and takes the first non-empty one,
    // which is also what we do - the field is not an answer, but a run that spends
    // its whole budget here answers nothing, and that has to be visible.
    let mut reasoning = String::new();
    let mut finish_reason: Option<String> = None;
    let mut assembly = ToolCallAssembly::new();
    // One provisional decision per tool-call index, assembled from the same deltas that build
    // `tool_calls`. Empty for a text-only answer, which is exactly why a text-only answer emits no
    // `decision` event: nothing here is invented for a call the model did not ask for.
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
        let phase = delta["phase"].as_str().or_else(|| chunk["choices"][0]["phase"].as_str());
        if let Some(phase) = phase {
            active_phase = if matches!(phase, "commentary" | "final_answer") { phase } else { "" }.to_string();
        }
        if let Some(text) = chunk["choices"][0]["delta"]["content"].as_str() {
            if !text.is_empty() {
                if active_phase == "commentary" {
                    commentary.push_str(text);
                    mark_delta("commentary", elapsed_ms);
                    crate::serve::write_event(
                        &json!({"type": "commentary_delta", "text": text}).to_string(),
                    );
                } else {
                    content.push_str(text);
                    if active_phase == "final_answer" { final_phase = active_phase.clone(); }
                    mark_delta("answer", elapsed_ms);
                    crate::serve::write_event(&json!({"type": "delta", "text": text}).to_string());
                }
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
                let (index, fragment) = assembly.absorb(call);
                let decision = &mut assembly.decisions[index];
                if let Some(fragment) = fragment {
                    decision.absorb(&fragment);
                }
                if let Some((display_id, previous)) = decision.publish_update(index) {
                    emit_decision(decision, &display_id, false, previous.as_deref());
                }
            }
        }
        if chunk["usage"].is_object() {
            usage = Some(chunk["usage"].clone());
        }
    }
    // A finished stream completes each call it formed; a truncated one (no finish reason and no
    // `[DONE]`) leaves its decisions forming, because those arguments are partial and the tool loop
    // will not execute them. A cancelled or failed read returns above, so it never gets here.
    if finish_reason.is_some() || saw_done {
        complete_decisions(&mut assembly.decisions, &assembly.calls);
    }
    let tool_calls: Vec<Value> = assembly.calls.clone();
    Ok(json!({"status": status, "content": content, "commentary": commentary,
        "final_phase": final_phase, "reasoning": reasoning,
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

#[cfg(test)]
mod sse_line_tests {
    use super::*;

    /// The recorded stream the subscription wire is parsed from - one frame per line of the real
    /// wire bytes, kept in the repository so `lua/core/subscription_wire.lua` is tested against
    /// what the endpoint actually sent. The Rust side is tested against the same bytes because the
    /// line boundaries it hands over are half of that contract: if this reader re-frames or drops a
    /// line, the Lua parser is being tested on a stream that never existed.
    fn recorded(name: &str) -> String {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/subscription")
            .join(name);
        std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("recorded fixture {} is unreadable: {error}", path.display()))
    }

    fn collect(body: &str) -> (Vec<String>, u64) {
        let mut seen: Vec<String> = Vec::new();
        let (lines, termination) = read_sse_lines(std::io::Cursor::new(body), |line| {
            seen.push(line.to_string());
            Ok(true)
        })
        .expect("a body with no failing callback reads to EOF");
        assert_eq!(termination, "eof");
        (seen, lines)
    }

    #[test]
    fn the_recorded_stream_is_handed_over_line_for_line() {
        let body = recorded("codex-responses-sse.txt");
        let (seen, lines) = collect(&body);
        assert_eq!(seen, body.lines().map(str::to_string).collect::<Vec<String>>());
        assert_eq!(lines as usize, seen.len(), "the count is the lines handed over");
        assert!(seen.iter().any(|line| line.contains("response.completed")));
        // This endpoint does not end with the `data: [DONE]` sentinel: `response.completed` is the
        // last frame and the stream ends at EOF. Measured, and pinned here because a reader that
        // waits for a sentinel would read a finished stream as a truncated one.
        assert!(!seen.iter().any(|line| line.trim() == "data: [DONE]"));
        assert_eq!(seen.last().map(String::as_str), Some(""), "the body ends on the frame's blank line");
        assert_eq!(seen[seen.len() - 3], "event: response.completed",
            "and the last frame carries the terminal event");
        assert!(seen[seen.len() - 2].starts_with("data: "),
            "whose payload is the next line, handed over as it was received");
    }

    /// A truncated stream is handed over as the lines that arrived, and the terminal event is
    /// simply absent. Deciding that this is a failure belongs to the protocol's owner (Lua), which
    /// is why the reader reports how it ended rather than judging it.
    #[test]
    fn a_truncated_stream_ends_where_it_ended() {
        let body = recorded("codex-responses-sse.txt");
        let terminal = body.lines().position(|line| line.contains("response.completed"))
            .expect("the recorded fixture has a terminal event");
        let truncated = body.lines().take(terminal).collect::<Vec<&str>>().join("\n");
        let (seen, lines) = collect(&truncated);
        assert_eq!(lines as usize, seen.len());
        assert!(seen.len() < body.lines().count());
        assert!(!seen.iter().any(|line| line.contains("response.completed")));
    }

    #[test]
    fn a_failing_callback_stops_the_read_at_that_line() {
        let body = recorded("codex-responses-sse.txt");
        let mut handed = 0u64;
        let failure = read_sse_lines(std::io::Cursor::new(&body), |_line| {
            handed += 1;
            if handed == 3 { Err("run_cancelled".to_string()) } else { Ok(true) }
        })
        .expect_err("a callback that fails must end the read");
        assert_eq!(failure.termination, "line_callback_failed");
        assert_eq!(failure.lines, 3);
        assert_eq!(failure.message, "run_cancelled");
        assert_eq!(handed, 3, "no line after the failure is read");
    }

    /// EOF terminates the residual line: a stream that ends without a trailing newline still
    /// delivers its last bytes rather than swallowing them as an incomplete read.
    #[test]
    fn a_residual_line_at_eof_is_still_a_line() {
        let (seen, lines) = collect("event: x\ndata: {\"a\":1}");
        assert_eq!(lines, 2);
        assert_eq!(seen, vec!["event: x".to_string(), "data: {\"a\":1}".to_string()]);
        // An empty body is an empty read, not a failure: a provider that answers with no body at
        // all is a fact to report, not an error to invent here.
        assert_eq!(collect("").1, 0);
    }

    #[test]
    fn a_protocol_stop_does_not_read_the_failed_socket_tail() {
        struct FailedTail(std::io::Cursor<Vec<u8>>);
        impl std::io::Read for FailedTail {
            fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
                let n = self.0.read(buf)?;
                if n == 0 { Err(std::io::Error::new(std::io::ErrorKind::ConnectionReset,
                    "Peer disconnected")) } else { Ok(n) }
            }
        }
        impl std::io::BufRead for FailedTail {
            fn fill_buf(&mut self) -> std::io::Result<&[u8]> {
                if self.0.position() as usize == self.0.get_ref().len() {
                    return Err(std::io::Error::new(std::io::ErrorKind::ConnectionReset,
                        "Peer disconnected"));
                }
                self.0.fill_buf()
            }
            fn consume(&mut self, n: usize) { self.0.consume(n); }
        }
        let body = b"data: terminal\n\n".to_vec();
        let stopped = read_sse_lines(FailedTail(std::io::Cursor::new(body.clone())),
            |line| Ok(!line.is_empty())).expect("stop before reading socket teardown");
        assert_eq!(stopped, (2, "callback_stopped"));
        let failed = read_sse_lines(FailedTail(std::io::Cursor::new(body)), |_| Ok(true))
            .expect_err("the old EOF-dependent path must reproduce the disconnect");
        assert_eq!(failed.termination, "read_failed");
        assert_eq!(failed.lines, 2);
    }
}

/// host.now() -> seconds since epoch
pub extern "C-unwind" fn monotonic_ms(l: *mut LuaState) -> c_int {
    static START: OnceLock<std::time::Instant> = OnceLock::new();
    let ms = START.get_or_init(std::time::Instant::now).elapsed().as_secs_f64() * 1000.0;
    unsafe { wa_host_support::lua::lua_pushnumber(l, ms) };
    1
}

/// **One string, not a table.** Read-only facts about the running binary; it changes nothing.
///
/// build_wave_generation, process_id, boot_id, os, arch, binary_path}`.
/// The build's own name for these bytes, set once at boot by the binary that compiles it in
/// (`wa-host`'s `build_info::label`) and read from here by the interpreter and by `/health`.
///
/// WHY A COPY RATHER THAN A DEPENDENCY: only the binary has the compiled-in identity, and this crate
/// cannot see `wa-host` (it depends on `wa-capabilities`, not the other way round). Making it a
/// dependency to read one string would invert the layering for a fact that is known before the
/// interpreter starts. So the binary states it once, at the top of `main` - before any path, event
/// or `--version` can be asked - and every reader in this process reads this copy. An empty slot
/// means nobody set it (a library test binary, a component host): the reader then says
/// `unknown build` rather than inventing a version, which is the rule the whole identity follows.
static BUILD_LABEL: std::sync::OnceLock<String> = std::sync::OnceLock::new();
/// The full commit and the tree's dirtiness, beside the label: a pin is recorded against a full id, and
/// the label is deliberately short. Same first-writer-wins rule.
static BUILD_COMMIT: std::sync::OnceLock<String> = std::sync::OnceLock::new();
static BUILD_DIRTY: std::sync::OnceLock<String> = std::sync::OnceLock::new();

/// State the whole identity once: the label the box and --version print,
/// the full commit a pin is compared against, and whether the tree was dirty when it was built.
pub fn set_build_identity(label: &str, commit: &str, dirty: &str) {
    let _ = BUILD_LABEL.set(label.to_string());
    let _ = BUILD_COMMIT.set(commit.to_string());
    let _ = BUILD_DIRTY.set(dirty.to_string());
}

/// The name for these bytes: what set_build_identity recorded, or "unknown build" when nothing did.
pub fn build_label() -> &'static str {
    BUILD_LABEL.get().map(String::as_str).filter(|label| !label.is_empty()).unwrap_or("unknown build")
}

/// host.build_identity() -> JSON text of `{label, commit, dirty, known}` for the running binary.
///
/// One JSON string the caller decodes with lua/vendor/json.lua; it is a string, not a table.
/// One reader for every surface that names the build: the welcome box, `wa --version` and the update
/// banner's installed side all go through `lua/core/build_identity.lua`, which reads this. The commit
/// is the full id (the short form is the label's job) so a pin can be compared against it.
pub extern "C-unwind" fn build_identity(l: *mut LuaState) -> c_int {
    let commit = BUILD_COMMIT.get().map(String::as_str).unwrap_or("");
    let dirty = BUILD_DIRTY.get().map(String::as_str).unwrap_or("unknown");
    push_json(l, &json!({
        "label": build_label(),
        "known": build_label() != "unknown build",
        "commit": if commit.is_empty() { "unknown" } else { commit },
        "dirty": dirty,
    }));
    1
}

/// host.runtime_info() -> JSON text of `{version, binary_sha256, build_source_commit, build_source_tree,
/// build_source_dirty, build_wave_generation, process_id, boot_id, os, arch, binary_path, run_origin} - one JSON
/// string the caller decodes with lua/vendor/json.lua, never a Lua table.
///
/// `build_source_dirty` is the value the binary was BUILT with, not a fresh look at the tree (item 4 of the
/// node-ops round): a binary built from a work tree that had uncommitted changes embeds code this checkout
/// does not have, so the same commit is not the same bytes. lua/core/build_status.lua reads it and answers
/// `edited`; without it a dirty build at the tree HEAD was graded `fresh`, which is the lie the item names.
pub extern "C-unwind" fn runtime_info(l: *mut LuaState) -> c_int {
    static IDENTITY: OnceLock<Value> = OnceLock::new();
    let identity = IDENTITY.get_or_init(|| {
        let digest = std::env::current_exe().ok().and_then(|path| std::fs::read(path).ok())
            .map(|bytes| ring::digest::digest(&ring::digest::SHA256, &bytes).as_ref()
                .iter().map(|b| format!("{b:02x}")).collect::<String>());
        json!({"version": env!("CARGO_PKG_VERSION"), "binary_sha256": digest,
            "build_source_commit":option_env!("WA_BUILD_SOURCE_COMMIT").unwrap_or(""),"build_source_tree":option_env!("WA_BUILD_SOURCE_TREE").unwrap_or(""),
            "build_source_dirty":BUILD_DIRTY.get().map(String::as_str).unwrap_or("unknown"),
            "build_wave_generation":option_env!("WA_BUILD_WAVE_GENERATION").unwrap_or(""),
            "process_id": std::process::id(), "boot_id": new_uuid(), "os": std::env::consts::OS,
            "arch": std::env::consts::ARCH})
    });
    let mut value=identity.clone();
    value["binary_path"]=json!(std::env::current_exe().ok());
    value["run_origin"]=json!(crate::serve::current_run_origin());
    push_json(l, &value);
    1
}

    /// Returns JSON text of the sample; A string the caller decodes (`lua/vendor/json.lua`), never a Lua table.
/// host.system_resources() -> a fresh CPU, memory and workspace-filesystem sample.
pub extern "C-unwind" fn system_resources(l: *mut LuaState) -> c_int {
    push_json(l, &wa_host_support::system_resources::sample());
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

/// **One string, not a table** when it answers at all: a caller decodes it before reading `columns`.
///
/// host.terminal_size() -> JSON text of `{columns, rows}`, or `nil` when there is no console.
pub extern "C-unwind" fn terminal_size(l: *mut LuaState) -> c_int {
    match console_size() {
        Some((columns, rows)) => push_json(l, &json!({"columns": columns, "rows": rows})),
        None => unsafe { wa_host_support::lua::lua_pushnil(l) },
    }
    1
}

/// Serialize terminal writes with the editor and the ticker. The Lua view uses this
/// only for its real stdout; captured/plain views keep their own writers.
pub extern "C-unwind" fn terminal_write(l: *mut LuaState) -> c_int {
    let ok = arg_string(l, 1).is_some_and(|text| write_at_editor(&text).is_ok());
    unsafe { wa_host_support::lua::lua_pushboolean(l, if ok { 1 } else { 0 }) };
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
    /// Lines Lua took from `lines` but holds for later (`input_held`): still queued on screen.
    held: Vec<String>,
    eof: bool,
    stop: bool,
    running: bool,
    raw: Option<wa_term::terminal_editor::RawMode>,
    editor: Option<wa_term::terminal_editor::Editor>,
    /// An open panel (`host.panel`): it owns the keys and the bottom of the screen until closed.
    panel: Option<wa_term::terminal_editor::Panel>,
    /// The output region's last row as this process last set it; 0 = the view's own layout.
    region: usize,
    /// The chat as blocks (wa_term::transcript), drawn into the output region by this process.
    transcript: wa_term::transcript::Transcript,
    /// When the debounced FULL repaint after a resize is due (item G): a resize sets it to now + the
    /// debounce, and a later call that finds it passed clears the screen and the scrollback and draws
    /// the whole transcript again at the new width. Cleared once done.
    repaint_after: Option<std::time::Instant>,
    /// While the transcript has focus (Up on an empty draft), its key decoder.
    nav: Option<wa_term::transcript::NavDecoder>,
    /// A mouse report split across two reads: its start, waiting for the rest (wa_term::selection).
    mouse_pending: Vec<u8>,
    /// The chat text being selected with the mouse; Ctrl+C copies it (OSC 52).
    selection: Option<Selection>,
    /// A mouse drag that began in the input box: the draft index it started at (the editor selects to it).
    box_drag: Option<usize>,
    /// Images pasted with Ctrl+V this session, by the number in their `[Image #n]` token: (mime, base64).
    pasted_images: Vec<(String, String)>,
    /// The image tokens this host itself put into the draft in progress, and the ones that survived
    /// into the line submitted last. `host.input_image` answers only for the second list: a
    /// `[Image #n]` typed by hand, or left over from an earlier draft, attaches nothing.
    draft_images: Vec<usize>,
    submitted_images: Vec<usize>,
    /// `host.transcript_hold(true)`: writes are kept, not drawn, until the hold ends (a replay).
    transcript_held: bool,
    /// The long tool call's line as this process last drew it (`wa_term::tool_progress`, the host's own
    /// ticker). It lives in that call's **block** in the transcript, never on the
    /// session-status-content row (Victor, 2026-11-10); kept so an unchanged phrase is not redrawn.
    tool_progress: String,
    /// The `/status` panel as Lua last described it (`host.status_snapshot`), shown by this thread when
    /// `/status` is submitted during a run - Lua is blocked in the model call then and cannot open it.
    status_snapshot: Option<Value>,
    /// The open panel is that one: this thread owns it and closes it itself, no Lua call waits on it.
    host_panel: bool,
    /// The open panel is a **published balloon** (`host.local_view`): its answers walk the stack Lua
    /// captured (`rust/wa-cli-views`), and an option with `run` queues that line for the interpreter.
    balloon: bool,
}

/// A mouse selection over the chat area: where the drag started and where it is, in screen cells, the
/// plain rows on screen when it started (the view is frozen while it lasts, so they stay true), and
/// whether the view was following the bottom - it goes back to following when the selection ends.
struct Selection { anchor: (usize, usize), head: (usize, usize), rows: Vec<String>, following: bool }

fn clear_selection(state: &mut ConsoleInput) {
    if let Some(selection) = state.selection.take() {
        if selection.following { state.transcript.sync(); }
        state.transcript.dirty = true;
    }
}

/// One mouse report from the terminal. Ignored while a panel is open (it owns the screen's bottom).
fn handle_mouse(state: &mut ConsoleInput, event: wa_term::selection::Mouse) {
    use wa_term::keymap::{self, Gesture, Pose};
    use wa_term::selection::Mouse;
    if state.panel.is_some() { return; }
    let Some(editor) = state.editor.as_ref().filter(|editor| editor.row > 0) else { return };
    let (width, rows) = (editor.width, output_rows(None, editor));
    // Which gestures a pointer event means, and in which order they are tried, is the table's answer
    // (wa_term::keymap, the Mouse surface) - the same table /keybindings prints. A press a link
    // claims is a link copy because the table lists LinkCopy before the transcript's selection.
    match event {
        Mouse::WheelUp | Mouse::WheelDown => {
            let up = matches!(event, Mouse::WheelUp);
            for gesture in keymap::gestures(Pose::Wheel) {
                if let Gesture::Wheel = gesture {
                    clear_selection(state);
                    state.transcript.page(if up { 3 } else { -3 });
                    return;
                }
            }
        }
        Mouse::Press(row, col) => {
            clear_selection(state);
            let over_transcript = row <= rows && state.nav.is_none();
            for gesture in keymap::gestures(Pose::Press) {
                match gesture {
                    // The scrollbar's own gesture, before the selection's: a press in the bar's column
                    // (the screen's last one, while the bar is drawn there) jumps the view there and
                    // grabs the thumb, and a press anywhere else is still a selection.
                    Gesture::BarJump => { if state.transcript.bar_press(row, col, width) { return; } }
                    // A press in the input box places the cursor; a drag from there selects
                    // (operator 17/11).
                    Gesture::DraftPress => {
                        if row > rows && state.nav.is_none() {
                            let hit = state.editor.as_mut().and_then(|input| {
                                let index = input.index_at(row, col)?;
                                input.click(index);
                                Some(index)
                            });
                            if let Some(index) = hit {
                                state.box_drag = Some(index);
                                let frame = layout_frame(state);
                                let _ = wa_term::terminal_editor::write(&frame);
                            }
                            return;
                        }
                    }
                    // An expandable line (a folded code-mode result): the press opens or folds it.
                    Gesture::ExpandToggle => {
                        if !over_transcript { return; }
                        if state.transcript.expand_at(row) {
                            let frame = layout_frame(state);
                            let _ = wa_term::terminal_editor::write(&frame);
                            return;
                        }
                    }
                    // A link under the pointer: copied (operator 17/11 - "copy it to the clipboard").
                    Gesture::LinkCopy => {
                        if !over_transcript { return; }
                        if !state.transcript.bar_active() {
                            let shown = state.transcript.view(width, rows);
                            if let Some(url) = shown.get(row.saturating_sub(1))
                                .and_then(|line| wa_term::links::at(&wa_term::selection::plain(line), col))
                            {
                                let _ = wa_term::terminal_editor::write(&wa_term::selection::osc52(&url));
                                let count = url.chars().count();
                                if let Some(editor) = state.editor.as_mut() {
                                    editor.notice = format!("Copied link ({count} character{})", if count == 1 { "" } else { "s" });
                                }
                                let frame = layout_frame(state);
                                let _ = wa_term::terminal_editor::write(&frame);
                                return;
                            }
                        }
                    }
                    // The copy icon of a fenced block (#114): the transcript knows which cell it drew
                    // the affordance on, so a press there is a copy and a press anywhere else is a
                    // selection - one gesture, one meaning, no mode to learn.
                    Gesture::BlockCopy => {
                        if !over_transcript { return; }
                        if let Some(text) = state.transcript.copy_at(row, col) {
                            let _ = wa_term::terminal_editor::write(&wa_term::selection::osc52(&text));
                            let count = text.chars().count();
                            if let Some(editor) = state.editor.as_mut() {
                                editor.notice = format!("Copied {count} character{}", if count == 1 { "" } else { "s" });
                            }
                            let frame = layout_frame(state);
                            let _ = wa_term::terminal_editor::write(&frame);
                            return;
                        }
                    }
                    Gesture::TranscriptSelection => {
                        if !over_transcript { return; }
                        let following = state.transcript.following();
                        state.transcript.page(0); // freeze: what is selected must not scroll away under the pointer
                        let shown: Vec<String> = state.transcript.view(width, rows).iter().map(|r| wa_term::selection::plain(r)).collect();
                        state.selection = Some(Selection { anchor: (row, col), head: (row, col), rows: shown, following });
                        state.transcript.dirty = true;
                        return;
                    }
                    _ => {}
                }
            }
        }
        // Motion with no button down (SGR 35, which 1003 reports): the pointer is on the bar or it is
        // not. Only that flip sets dirty, so a moving pointer costs no frame.
        Mouse::Motion(row, col) => {
            for gesture in keymap::gestures(Pose::Motion) {
                if let Gesture::Hover = gesture {
                    state.transcript.bar_hover(row, col, width);
                    let expand = row <= rows && state.transcript.expand_hover(row);
                    let copy = row <= rows && state.transcript.copy_hover(row, col);
                    if expand || copy {
                        let frame = layout_frame(state);
                        let _ = wa_term::terminal_editor::write(&frame);
                    }
                    return;
                }
            }
        }
        Mouse::Drag(row, col) | Mouse::Release(row, col) => {
            // The draft's own drag comes first (it began in the box), then the bar's thumb; anything
            // else is the transcript's selection, which is the gesture that always applies.
            for gesture in keymap::gestures(if matches!(event, Mouse::Release(..)) { Pose::Release } else { Pose::Drag }) {
                match gesture {
                    Gesture::SelectDrag if state.box_drag.is_some() => {
                        let anchor = state.box_drag.unwrap_or(0);
                        if let Some(input) = state.editor.as_mut() {
                            if let Some(index) = input.index_at(row, col) { input.select(anchor, index); }
                        }
                        // (the editor borrow ends here; the frame below reads the whole state)
                        if matches!(event, Mouse::Release(..)) { state.box_drag = None; }
                        let frame = layout_frame(state);
                        let _ = wa_term::terminal_editor::write(&frame);
                        return;
                    }
                    // A drag that began on the bar scrolls it, and the button coming up lets the thumb go.
                    Gesture::BarJump => {
                        if matches!(event, Mouse::Release(..)) {
                            if state.transcript.bar_release() { return; }
                        } else if state.transcript.bar_drag(row) {
                            return;
                        }
                    }
                    _ => {}
                }
            }
            let Some(selection) = state.selection.as_mut() else { return; };
            selection.head = (row.clamp(1, selection.rows.len().max(1)), col);
            if matches!(event, Mouse::Release(..)) && selection.head == selection.anchor { clear_selection(state); return; }
            // Copy on release (29/10): Omarchy's Super+C sends Ctrl+Insert to a terminal, and foot keeps
            // that chord to copy *its own* selection - empty while wa owns the mouse - so Super+C never
            // reached wa. The selection is on the clipboard the moment the button comes up; Super+C then
            // finds it there, and Ctrl+C still copies and clears as before.
            if matches!(event, Mouse::Release(..)) {
                let text = wa_term::selection::text(&selection.rows, selection.anchor, selection.head);
                let _ = wa_term::terminal_editor::write(&wa_term::selection::osc52(&text));
                let count = text.chars().count();
                if let Some(editor) = state.editor.as_mut() {
                    editor.notice = format!("Copied {count} character{}", if count == 1 { "" } else { "s" });
                }
            }
            state.transcript.dirty = true;
        }
        Mouse::Other => {}
    }
}

/// Ctrl+C with a selection: copy it to the terminal's clipboard and say so in the footer.
fn copy_selection(state: &mut ConsoleInput) -> bool {
    let Some(selection) = state.selection.as_ref() else { return false };
    let text = wa_term::selection::text(&selection.rows, selection.anchor, selection.head);
    let _ = wa_term::terminal_editor::write(&wa_term::selection::osc52(&text));
    let count = text.chars().count();
    clear_selection(state);
    if let Some(editor) = state.editor.as_mut() {
        editor.notice = format!("Copied {count} character{}", if count == 1 { "" } else { "s" });
    }
    true
}

static CONSOLE_INPUT: OnceLock<(Mutex<ConsoleInput>, std::sync::Condvar)> = OnceLock::new();

fn console_input() -> &'static (Mutex<ConsoleInput>, std::sync::Condvar) {
    CONSOLE_INPUT.get_or_init(|| {
        let mut state = ConsoleInput::default();
        // The inline transcript's scrollbar obeys the same knob as the fullscreen console's
        // (`WA_TUI_SCROLLBAR`, docs/TERMINAL.md, #115): one setting, one meaning, in both layouts.
        if let Some(bar) = std::env::var("WA_TUI_SCROLLBAR").ok()
            .and_then(|value| wa_term::scroll::settings::Scrollbar::parse(&value))
        {
            state.transcript.scrollbar = bar;
        }
        (Mutex::new(state), std::sync::Condvar::new())
    })
}

/// A saved cursor can move when ConPTY scrolls output. Finish every view/ticker
/// write at the editor's actual draft cursor, under the same input/output locks.
///
/// The view names rows it does not own by token - `{O}` the output region's last row, `{S}` the status
/// row - because the slash menu and panels move them while Lua is blocked; they are filled in here,
/// under the input lock, so a write can never land on a row that has just become the box.
fn write_at_editor(text: &str) -> std::io::Result<()> {
    let state = console_input().0.lock().unwrap_or_else(|e| e.into_inner());
    match state.editor.as_ref().filter(|editor| editor.row > 0) {
        Some(editor) => {
            if (state.panel.is_some() || !editor.status) && text.contains("{S}") { return Ok(()); }
            let text = if text.contains("\x1b[{") {
                text.replace("{O}", &current_region(&state, editor).to_string())
                    .replace("{S}", &editor.status_row().to_string())
            } else { text.to_string() };
            if state.panel.is_some() { return wa_term::terminal_editor::write(&text); }
            wa_term::terminal_editor::write(&format!("\x1b[?25l{}{}\x1b[?25h",
                text.replace("\x1b[?25h", ""), editor.cursor_frame()))
        }
        None => wa_term::terminal_editor::write(text),
    }
}

fn current_region(state: &ConsoleInput, editor: &wa_term::terminal_editor::Editor) -> usize {
    if state.region == 0 { editor.row.saturating_sub(6) } else { state.region }
}

/// The rows the chat occupies on screen now (`1..=` this): the terminal minus the bottom - the
/// input box with its status, menu and footer rows, or an open panel.
fn output_rows(panel: Option<&wa_term::terminal_editor::Panel>, editor: &wa_term::terminal_editor::Editor) -> usize {
    match panel {
        Some(panel) => (editor.row + 1).saturating_sub(panel.height().max(7)),
        None => editor.out_bottom(),
    }
}

/// How far one PageUp/PageDown moves the chat: a third of the rows it occupies at the key press.
fn page_rows(state: &ConsoleInput) -> isize {
    let area = state.editor.as_ref().filter(|editor| editor.row > 0).map(|editor| output_rows(state.panel.as_ref(), editor));
    // No framed screen (cannot happen while keys page; kept total): the old ten-row step.
    wa_term::transcript::page_step(area.unwrap_or(30))
}

/// The rows the bottom of the screen needs now, applied, and that bottom drawn: the box (with the
/// slash menu or the footer under it), or an open panel. Growing scrolls the output up first - a
/// newline at the old region's last row - so nothing already written is drawn over; shrinking blanks
/// the rows it hands back to the output.
fn layout_frame(state: &mut ConsoleInput) -> String {
    let Some(editor) = state.editor.as_ref().filter(|editor| editor.row > 0) else { return String::new() };
    let rows = editor.row + 1;
    let want = output_rows(state.panel.as_ref(), editor);
    let have = current_region(state, editor);
    let width = editor.width;
    let mut frame = String::from("\x1b[?25l");
    if want >= 1 && want != have {
        frame.push_str(&format!("\x1b[1;{want}r"));
        for row in want + 1..=rows { frame.push_str(&format!("\x1b[{row};1H\x1b[2K")); }
        state.transcript.dirty = true;
    }
    if state.transcript.dirty && want >= 1 {
        frame.push_str(&state.transcript.render(width, want));
        if let Some(selection) = state.selection.as_ref() {
            frame.push_str(&wa_term::selection::overlay(&selection.rows, selection.anchor, selection.head));
        }
        state.transcript.dirty = false;
    }
    let Some(editor) = state.editor.as_ref() else { return frame };
    let frame = frame + &match state.panel.as_ref() { Some(panel) => panel.render(), None => editor.render() };
    state.region = want.max(1);
    frame
}

fn status_visible() -> bool {
    console_input().0.lock().map(|state| state.editor.as_ref().map(|e| e.row == 0 || e.status).unwrap_or(true)).unwrap_or(true)
}

fn panel_open() -> bool {
    console_input().0.lock().map(|state| state.panel.is_some()).unwrap_or(false)
}

/// Keep the raw editor's rows attached to the current viewport while Lua is
/// blocked. All redraws take the input lock before the shared output lock.
fn refresh_editor_size() -> Option<usize> {
    let (columns, rows) = console_size()?;
    if rows < EDITOR_MIN_ROWS { return None; }
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    if state.editor.as_ref()?.row == 0 { return None; }
    resize_console(&mut state, columns as usize, rows as usize);
    refresh_build(&mut state);
    refresh_tool_progress(&mut state);
    Some(state.editor.as_ref()?.status_row())
}

/// The rebuild row (wa_term::build_status) as it reads now; redrawn only when its text changed - a
/// row coming or going moves the status line and the chat's last row, which `layout_frame` applies.
fn refresh_build(state: &mut ConsoleInput) {
    let Some(editor) = state.editor.as_mut() else { return };
    let build = wa_term::build_status::current(editor.width);
    if build == editor.build { return; }
    editor.build = build;
    let frame = layout_frame(state);
    let _ = wa_term::terminal_editor::write(&frame);
}

/// A long tool call's line (`wa_term::tool_progress`, docs/TOOL-PROGRESS.md) as it reads now, drawn
/// **inside that call's own block** in the transcript - never on the session-status-content row, which
/// belongs to the update notice and its loader (Victor, 2026-11-10). Redrawn only when its text
/// changed, for the same reason `refresh_build` is.
///
/// The facts are published by whoever is waiting on the operation - `operations::foreground` for the
/// `bash` tool, `operations::control("await")` for `operation start` - because this ticker is awake
/// while Lua is blocked in that wait, and a wait loop is the only place that owns the operation's
/// output tail. This only renders: one stat a quarter second, a read when the file moved.
fn refresh_tool_progress(state: &mut ConsoleInput) {
    if state.editor.as_ref().is_none_or(|editor| editor.row == 0) { return }
    let width = state.editor.as_ref().map(|editor| editor.width).unwrap_or(0);
    // The row is this session's own, or the dim aggregate of the others: never another session's
    // tool name and never a line of its output (session isolation, finding 1).
    let session = crate::subagents::current_owner().unwrap_or_default();
    // The count is the operation manager's (item 3 round 4): the row says "ops", and wa-term can only
    // count files. One other session holding four unsettled operations is four.
    let mut row = wa_term::tool_progress::current(width, &session, crate::operations::elsewhere_count(&session));
    // Never inside a code-mode block: its call rows already say ⏳/✓/✗ in place, and this row coming and going
    // under the block moved everything above it up and down (operator 17/11, measured in the TUI).
    if state.transcript.blocks.last().is_some_and(|block| block.code) { row = String::new(); }
    if row == state.tool_progress { return; }
    state.tool_progress = row;
    let text = if state.tool_progress.is_empty() { None } else { Some(state.tool_progress.as_str()) };
    state.transcript.live(text);
    let frame = layout_frame(state);
    let _ = wa_term::terminal_editor::write(&frame);
}

/// The framed layout, bottom up (the twin of `cli_view.screen_rows` with an editor):
/// footer on the last row, the input box's bottom border above it, `height` draft rows and the
/// top border above that, then the status line, and the output region above everything.
const EDITOR_MIN_ROWS: i32 = 10;

fn resize_console(state: &mut ConsoleInput, columns: usize, rows: usize) {
    let Some(editor) = state.editor.as_mut() else { return };
    if editor.row == rows - 1 && editor.width == columns { return; }
    let old_rows = editor.row + 1;
    // Item G: a resize is answered by ONE repaint from state, 150 ms after the last event of the
    // burst (dragging a window edge arrives as dozens of resizes). Until then the rows keep their
    // own paints, which is what holds the picture together in the interval.
    state.repaint_after = Some(std::time::Instant::now() + std::time::Duration::from_millis(150));
    let mut frame = String::from("\x1b[?25l");
    for row in (state.region + 1).max(1)..=old_rows.min(rows) { frame.push_str(&format!("\x1b[{row};1H\x1b[2K")); }
    editor.row = rows - 1;
    editor.width = columns;
    if let Some(panel) = state.panel.as_mut() { panel.width = columns; panel.rows = rows; }
    state.transcript.dirty = true;
    let want = output_rows(state.panel.as_ref(), editor);
    frame.push_str(&format!("\x1b[1;{}r", want.max(1)));
    state.region = want.max(1);
    frame.push_str(&layout_frame(state));
    let _ = wa_term::terminal_editor::write(&frame);
}

/// The debounced full repaint after a resize (item G): once the burst has been quiet for the
/// debounce, the screen AND the scrollback are cleared and the whole transcript is drawn again from
/// the block state this process owns, at the width the terminal has now.
///
/// From STATE and not from the bytes already printed: a printed row cannot be reflowed (the terminal
/// owns those characters), so the only way an old bubble or code block comes back correctly sized in
/// both directions is to draw it again. The draw is the same layout_frame a frame uses, which wraps
/// only what is on screen - the cost is one screenful, not one session.
/// Whether a debounced repaint is due at `now`: PURE, so the debounce is a decision a test can make
/// without a terminal and without waiting a tenth of a second for it.
fn repaint_is_due(due: Option<std::time::Instant>, now: std::time::Instant) -> bool {
    due.is_some_and(|at| now >= at)
}

/// The bytes a debounced repaint starts with: hide the cursor, clear the screen (2J) and the
/// SCROLLBACK (3J), home the cursor.
const REPAINT_CLEAR: &str = "\x1b[?25l\x1b[2J\x1b[3J\x1b[H";

fn repaint_if_due() {
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    let Some(due) = state.repaint_after else { return };
    if !repaint_is_due(Some(due), std::time::Instant::now()) { return }
    state.repaint_after = None;
    if state.editor.as_ref().is_none_or(|editor| editor.row == 0) { return }
    let mut frame = String::from(REPAINT_CLEAR);
    state.transcript.dirty = true;
    let rest = layout_frame(&mut state);
    frame.push_str(&rest);
    let _ = wa_term::terminal_editor::write(&frame);
}

#[cfg(test)]
mod repaint_tests {
    use super::*;

    /// Item G: the debounce itself - NOT due at the moment of the resize nor 149 ms later, due at
    /// 150 ms and after. A drag of the window edge arrives as dozens of resizes and must paint once.
    #[test]
    fn the_repaint_is_due_only_after_the_debounce() {
        let now = std::time::Instant::now();
        let due = now + std::time::Duration::from_millis(150);
        assert!(!repaint_is_due(Some(due), now), "not due at the moment of the resize");
        assert!(!repaint_is_due(Some(due), now + std::time::Duration::from_millis(149)));
        assert!(repaint_is_due(Some(due), now + std::time::Duration::from_millis(150)));
        assert!(repaint_is_due(Some(due), now + std::time::Duration::from_secs(2)));
    }

    /// Nothing scheduled is nothing to repaint: an idle chat does not clear its own screen.
    #[test]
    fn an_idle_chat_is_never_due() {
        assert!(!repaint_is_due(None, std::time::Instant::now()));
    }

    /// The clear covers what a resize leaves behind: the screen, AND the scrollback.
    #[test]
    fn the_repaint_clears_the_screen_and_the_scrollback() {
        assert!(REPAINT_CLEAR.contains("\x1b[2J"), "the screen is cleared");
        assert!(REPAINT_CLEAR.contains("\x1b[3J"), "and the scrollback with it");
        assert!(REPAINT_CLEAR.ends_with("\x1b[H"), "and the cursor goes home");
    }
}

/// One read of what the terminal sent - a keystroke, or a whole escape sequence or paste at once.
/// Unbuffered on Unix, so "nothing follows this Esc" can be asked of the terminal itself.
#[cfg(unix)]
fn read_chunk(_handle: &mut std::io::StdinLock<'_>, buffer: &mut [u8]) -> std::io::Result<usize> {
    let n = unsafe { libc::read(0, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
    if n < 0 { Err(std::io::Error::last_os_error()) } else { Ok(n as usize) }
}
#[cfg(not(unix))]
fn read_chunk(handle: &mut std::io::StdinLock<'_>, buffer: &mut [u8]) -> std::io::Result<usize> {
    use std::io::Read;
    handle.read(&mut buffer[..1])
}
/// Whether another byte arrives within `ms`: an Esc with nothing after it is the Esc key. Where this
/// cannot be asked (Windows), Esc pressed twice does the same.
#[cfg(unix)]
fn byte_ready(ms: i32) -> bool {
    let mut fd = libc::pollfd { fd: 0, events: libc::POLLIN, revents: 0 };
    unsafe { libc::poll(&mut fd, 1, ms) > 0 }
}
#[cfg(not(unix))]
fn byte_ready(_ms: i32) -> bool { true }

/// Read lines forever, waking anyone waiting each time one lands.
///
/// One reader per process: a second would split the reader's typing between two queues and
/// neither caller would see the whole of it. The stdin lock is taken once, for the same reason.
fn console_reader() {
    use std::io::BufRead;
    let stdin = std::io::stdin();
    let mut handle = stdin.lock();
    let mut line = String::new();
    let editor = console_input().0.lock().unwrap_or_else(|e| e.into_inner()).editor.is_some();
    loop {
        if editor {
            // No key yet: a resize (a maximised window, a split) still redraws now, not at the next
            // key. While a run is live the ticker does the same; this covers an idle chat.
            #[cfg(unix)]
            while !byte_ready(150) {
                let (lock, wake) = console_input();
                let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
                if state.stop { state.running = false; wake.notify_all(); return; }
                drop(state);
                let _ = refresh_editor_size();
                repaint_if_due();
            }
            let mut chunk = [0u8; 512];
            let read = read_chunk(&mut handle, &mut chunk);
            let (lock, wake) = console_input();
            let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
            if state.stop { state.running = false; wake.notify_all(); return; }
            match read {
                Ok(0) | Err(_) => { state.eof = true; state.running = false; wake.notify_all(); return; }
                Ok(n) => {
                    if state.editor.as_ref().is_some_and(|input| input.row > 0) {
                        if let Some((columns, rows)) = console_size().filter(|(_, rows)| *rows >= EDITOR_MIN_ROWS) {
                            resize_console(&mut state, columns as usize, rows as usize);
                        }
                    }
                    // Mouse reports (wa_term::selection) are taken out first; the rest is keys, as before.
                    let mut data = std::mem::take(&mut state.mouse_pending);
                    data.extend_from_slice(&chunk[..n]);
                    let (keys, mice, pending) = wa_term::selection::take(&data);
                    state.mouse_pending = pending;
                    for event in mice { handle_mouse(&mut state, event); }
                    for &byte in &keys {
                        if let Some(panel) = state.panel.as_mut() { panel.feed(byte); continue; }
                        // Ctrl+O pins a block expanded, so the code-mode block that follows cannot
                        // collapse it (and the same key lets it go). It is the transcript's key: the
                        // draft has no row for it, so it is taken here before the editor. Which byte
                        // that is, is the keymap's answer (Console surface), not this loop's.
                        if wa_term::keymap::console_byte(byte) == Some(wa_term::keymap::HostAct::Pin)
                            && state.selection.is_none() && state.transcript.pin_toggle().is_some() {
                            let frame = layout_frame(&mut state);
                            let _ = wa_term::terminal_editor::write(&frame);
                            continue;
                        }
                        // Ctrl+C with a selection copies it; any other key ends the selection first.
                        if state.selection.is_some() {
                            if wa_term::keymap::console_byte(byte) == Some(wa_term::keymap::HostAct::CopySelection)
                                && copy_selection(&mut state) { continue; }
                            clear_selection(&mut state);
                        }
                        if let Some(nav) = state.nav.as_mut() {
                            use wa_term::transcript::NavKey;
                            let key = nav.feed(byte);
                            match &key {
                                NavKey::None => {}
                                NavKey::Up => { state.transcript.focus_prev(); }
                                NavKey::Down => { if !state.transcript.focus_next() { state.transcript.sync(); state.nav = None; } }
                                NavKey::Right => state.transcript.set_expanded(true),
                                NavKey::Left => state.transcript.set_expanded(false),
                                NavKey::Pin => { state.transcript.pin_toggle(); }
                                NavKey::PageUp | NavKey::PageDown => {
                                    let page = page_rows(&state);
                                    state.transcript.page(if matches!(key, NavKey::PageUp) { page } else { -page });
                                }
                                NavKey::Exit | NavKey::Bottom => { state.transcript.sync(); state.nav = None; }
                                NavKey::Other(bytes) => {
                                    // Typing goes back to the draft (synced to the bottom), keystroke included.
                                    state.transcript.sync(); state.nav = None;
                                    if let Some(input) = state.editor.as_mut() { for &b in bytes.iter() { let _ = input.feed(b); } }
                                }
                            }
                            continue;
                        }
                        let Some(input) = state.editor.as_mut() else { break };
                        match input.feed(byte) {
                            wa_term::terminal_editor::Action::Nav => {
                                // Navigating freezes the view where it is; output keeps arriving below.
                                if state.transcript.topics().is_empty() { continue; }
                                state.transcript.hold();
                                state.transcript.focus_prev();
                                state.nav = Some(Default::default());
                            }
                            wa_term::terminal_editor::Action::Bottom => state.transcript.sync(),
                            action @ (wa_term::terminal_editor::Action::PageUp | wa_term::terminal_editor::Action::PageDown) => {
                                let page = page_rows(&state);
                                let up = action == wa_term::terminal_editor::Action::PageUp;
                                state.transcript.page(if up { page } else { -page });
                            }
                            wa_term::terminal_editor::Action::Submit(text) => {
                                // `/status` while a run is in flight: shown now, over the box, from the
                                // last snapshot - never queued behind the run, never interrupting it.
                                let running = state.editor.as_ref().is_some_and(|e| e.status);
                                if running && text.trim() == "/status" {
                                    let dims = state.editor.as_ref().map(|e| (e.width, e.row + 1));
                                    if let (Some(spec), Some((width, rows))) = (state.status_snapshot.clone(), dims) {
                                        state.panel = Some(wa_term::terminal_editor::Panel::from_spec(&spec, width, rows));
                                        state.host_panel = true;
                                        continue;
                                    }
                                }
                                // Every OTHER read-only command with a published balloon (`/mcp`, `/help`,
                                // `/nodes`): drawn from the snapshot now, over the box, and NOT queued
                                // behind the run. The store refuses a line between runs on purpose - the
                                // REPL's own arm can read afresh, and this cannot.
                                if running {
                                    let route = wa_cli_views::route(&text, true, wa_cli_views::now_seconds());
                                    if let wa_cli_views::Route::Local(spec) = route {
                                        let dims = state.editor.as_ref().map(|e| (e.width, e.row + 1));
                                        if let Some((width, rows)) = dims {
                                            state.panel = Some(wa_term::terminal_editor::Panel::from_spec(&spec, width, rows));
                                            state.host_panel = true;
                                            state.balloon = true;
                                            continue;
                                        }
                                    }
                                }
                                // An ordinary line: a balloon the reader was in is them changing their
                                // mind, and the line goes to the interpreter exactly as before.
                                if state.balloon {
                                    wa_cli_views::dismiss();
                                    state.balloon = false;
                                    state.host_panel = false;
                                    state.panel = None;
                                }
                                CLI_INTERRUPT.store(false, std::sync::atomic::Ordering::SeqCst);
                                state.transcript.to_bottom();
                                // The image tokens this draft carries, and only those: the next
                                // draft starts with none, so `[Image #1]` typed into it is text.
                                state.submitted_images = submitted_tokens(&state.draft_images, &text);
                                state.draft_images.clear();
                                state.lines.push(text);
                                sync_queued(&mut state);
                            }
                            wa_term::terminal_editor::Action::Eof => { state.eof = true; state.running = false; break; }
                            // The editor put its own notice (`Interrupting…`) in the footer's place; the
                            // frame below draws it. The draft is never touched by Ctrl+C.
                            wa_term::terminal_editor::Action::Interrupt => CLI_INTERRUPT.store(true, std::sync::atomic::Ordering::SeqCst),
                            // The draft's selection to the clipboard (Ctrl+C / Ctrl+Insert with text selected):
                            // OSC 52, the same write the transcript's copy icon makes.
                            wa_term::terminal_editor::Action::Copy(text) => {
                                let _ = wa_term::terminal_editor::write(&wa_term::selection::osc52(&text));
                                let count = text.chars().count();
                                if let Some(editor) = state.editor.as_mut() {
                                    editor.notice = format!("Copied {count} character{}", if count == 1 { "" } else { "s" });
                                }
                            }
                            // A dropped (or pasted) path to an image file, and Ctrl+V on a
                            // clipboard image: the same attachment inserted the same way. One
                            // function decides the token number, keeps the bytes and records that
                            // this draft carries it; the two arms differ only in what they replace.
                            wa_term::terminal_editor::Action::Pasted(from) => {
                                let span = state.editor.as_ref().map(|e| (e.slice(from, e.cursor()), e.cursor()));
                                if let Some((text, to)) = span {
                                    if let Some((mime, bytes)) = dropped_image(&text) {
                                        let (token, kb) = attach_image(&mut state, &mime, bytes);
                                        if let Some(editor) = state.editor.as_mut() {
                                            editor.replace_range(from, to, &token);
                                            editor.notice = format!("{token} attached ({kb} KB)");
                                        }
                                    }
                                }
                            }
                            wa_term::terminal_editor::Action::PasteImage => {
                                let note = match read_clipboard_image() {
                                    Ok((mime, bytes)) => {
                                        let (token, kb) = attach_image(&mut state, &mime, bytes);
                                        if let Some(editor) = state.editor.as_mut() { editor.insert_text(&token); }
                                        format!("{token} attached ({kb} KB)")
                                    }
                                    Err(reason) => reason,
                                };
                                if let Some(editor) = state.editor.as_mut() { editor.notice = note; }
                            }
                            wa_term::terminal_editor::Action::None => {}
                        }
                    }
                    // A lone Esc: the terminal sent nothing after it.
                    // Never inside a paste: `docker exec` and slow links split a paste anywhere, and an Esc
                    // that is really the start of its end marker would leave the draft stuck in paste mode.
                    let pasting = state.panel.as_ref().map(|panel| panel.pasting())
                        .or_else(|| state.editor.as_ref().map(|input| input.pasting())).unwrap_or(false);
                    let escape = wa_term::keymap::console_escape();
                    if !state.eof && escape.is_some() && keys.last().copied() == escape && !pasting && !byte_ready(120) {
                        if let Some(panel) = state.panel.as_mut() { panel.escape(); }
                        else if let Some(nav) = state.nav.as_mut() {
                            if nav.lone_escape() { state.transcript.sync(); state.nav = None; }
                        }
                        else if let Some(input) = state.editor.as_mut() {
                            // Esc closes the slash menu first; with nothing to close and a run in flight
                            // (the status row is up) it interrupts the run, as Ctrl+C does.
                            // Bash mode is left the same way, never interrupting the run.
                            let menu_open = input.menu_rows() > 0 || input.bash;
                            input.escape();
                            if !menu_open && input.status {
                                CLI_INTERRUPT.store(true, std::sync::atomic::Ordering::SeqCst);
                                input.notice = "Interrupting\u{2026}".into();
                            }
                        }
                    }
                    // An answer to a panel this thread owns. `/status` closes on it; a published
                    // balloon walks its stack - draw the next page, go back, close, or queue the
                    // chosen action for the interpreter's next turn.
                    if state.host_panel && state.panel.as_ref().map_or(true, |panel| panel.result.is_some()) {
                        let answer = state.panel.as_mut().and_then(|panel| panel.result.take());
                        let dims = state.editor.as_ref().map(|e| (e.width, e.row + 1));
                        let mut closed = true;
                        if state.balloon {
                            match answer {
                                Some(answer) => match wa_cli_views::answer(&answer, wa_cli_views::now_seconds()) {
                                    wa_cli_views::Answer::Draw(spec) => {
                                        if let Some((width, rows)) = dims {
                                            state.panel = Some(wa_term::terminal_editor::Panel::from_spec(&spec, width, rows));
                                            closed = false;
                                        }
                                    }
                                    wa_cli_views::Answer::Close => {}
                                    // In the queue a typed line goes to, so the REPL runs it once the
                                    // turn is over - which is what the balloon's hint says it will do.
                                    wa_cli_views::Answer::Queue(line) => {
                                        state.lines.push(line);
                                        sync_queued(&mut state);
                                    }
                                },
                                // The panel went away with no answer (the editor was lost): forget
                                // the stack rather than leaving half of it on screen.
                                None => wa_cli_views::dismiss(),
                            }
                        }
                        if closed {
                            state.panel = None;
                            state.host_panel = false;
                            state.balloon = false;
                            state.transcript.dirty = true;
                        }
                    }
                    let frame = layout_frame(&mut state);
                    if !frame.is_empty() { let _ = wa_term::terminal_editor::write(&frame); }
                    wake.notify_all();
                    if state.eof { return; }
                }
            }
            continue;
        }
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

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// `host.input_start()` -> `{started:true}`, or `nil` if the reader cannot be asked.
///
/// Idempotent: a caller that starts twice gets one reader and one `true`, so nothing has to
/// remember whether it already did.
pub extern "C-unwind" fn input_start(l: *mut LuaState) -> c_int {
    let (lock, _) = console_input();
    match lock.lock() {
        Ok(mut state) => {
            if state.running {
                push_json(l, &json!({"started": true, "editor": state.editor.is_some()}));
                return 1;
            }
            state.raw = if arg_integer(l, 1) == Some(1) && console_size().is_some()
                && std::env::var("WASM_AGENT_CLI_EDITOR").unwrap_or_default() != "off" {
                wa_term::terminal_editor::try_raw()
            } else { None };
            state.editor = state.raw.as_ref().map(|_| wa_term::terminal_editor::Editor::default());
            state.running = true;
            state.stop = false;
        }
        Err(_) => {
            unsafe { wa_host_support::lua::lua_pushnil(l) };
            return 1;
        }
    }
    std::thread::spawn(console_reader);
    let editor = lock.lock().unwrap_or_else(|e| e.into_inner()).editor.is_some();
    push_json(l, &json!({"started": true, "editor": editor}));
    1
}

/// Configure and draw the live editor's input row after the view sets its scroll region.
/// No reader thread is started here: it must already be the *one* input_start reader.
pub extern "C-unwind" fn input_editor(l: *mut LuaState) -> c_int {
    let row = arg_integer(l, 1).unwrap_or(0).max(0) as usize;
    let width = arg_integer(l, 2).unwrap_or(0).max(0) as usize;
    let height = arg_integer(l, 3).unwrap_or(1).clamp(1, 3) as usize;
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    let ok = if let Some(editor) = state.editor.as_mut() {
        editor.row = row;
        editor.width = width;
        editor.height = height;
        let frame = layout_frame(&mut state);
        wa_term::terminal_editor::write(&format!("\x1b[?2004h{}{frame}", wa_term::selection::ENABLE)).is_ok()
    } else { false };
    unsafe { wa_host_support::lua::lua_pushboolean(l, if ok { 1 } else { 0 }) };
    1
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// `host.panel(spec_json)` -> `{action, index?|text?}`; `host.panel()` closes it.
///
/// Opens (or replaces) the panel and blocks until the reader confirms (`select` with a 1-based
/// `index`, `submit` with `text`), presses Esc (`cancel`), or `timeout_ms` passes (`timeout`). The
/// panel stays on screen after an answer, so a flow of several panels does not flicker back to the
/// box between them; closing hands the bottom of the screen back to the box. `unsupported` when
/// there is no raw editor (a pipe, `WASM_AGENT_CLI_EDITOR=off`).
pub extern "C-unwind" fn panel(l: *mut LuaState) -> c_int {
    let spec = arg_string(l, 1).and_then(|text| serde_json::from_str::<Value>(&text).ok()).filter(|v| v.is_object());
    let (lock, wake) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    let Some((width, rows)) = state.editor.as_ref().filter(|editor| editor.row > 0).map(|e| (e.width, e.row + 1)) else {
        drop(state);
        push_json(l, &json!({"action": "unsupported"}));
        return 1;
    };
    let Some(spec) = spec else {
        state.host_panel = false;
        if state.panel.take().is_some() {
            let frame = layout_frame(&mut state);
            let _ = wa_term::terminal_editor::write(&frame);
        }
        drop(state);
        push_json(l, &json!({"action": "closed"}));
        return 1;
    };
    let deadline = spec.get("timeout_ms").and_then(|v| v.as_u64())
        .map(|ms| std::time::Instant::now() + std::time::Duration::from_millis(ms));
    state.panel = Some(wa_term::terminal_editor::Panel::from_spec(&spec, width, rows));
    state.host_panel = false;
    let frame = layout_frame(&mut state);
    let _ = wa_term::terminal_editor::write(&frame);
    let answer = loop {
        if let Some(result) = state.panel.as_mut().and_then(|panel| panel.result.take()) { break result; }
        if state.eof || state.stop || state.panel.is_none() { break json!({"action": "cancel"}); }
        match deadline {
            Some(at) => {
                let left = at.saturating_duration_since(std::time::Instant::now());
                if left.is_zero() { break json!({"action": "timeout"}); }
                state = match wake.wait_timeout(state, left) { Ok((s, _)) => s, Err(p) => p.into_inner().0 };
            }
            None => { state = match wake.wait(state) { Ok(s) => s, Err(p) => p.into_inner() }; }
        }
    };
    drop(state);
    push_json(l, &answer);
    1
}

/// `host.editor_footer(text[, right])`: the hint row under the input (plain text, drawn dim) and,
/// right-aligned on the same row, `right` - the model in use. `right` omitted keeps the last one.
pub extern "C-unwind" fn editor_footer(l: *mut LuaState) -> c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    let right = arg_string(l, 2);
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    let ok = if let Some(editor) = state.editor.as_mut() {
        editor.footer = text;
        if let Some(right) = right { editor.footer_right = right; }
        if editor.row > 0 && state.panel.is_none() {
            let frame = layout_frame(&mut state);
            wa_term::terminal_editor::write(&frame).is_ok()
        } else { true }
    } else { false };
    unsafe { wa_host_support::lua::lua_pushboolean(l, if ok { 1 } else { 0 }) };
    1
}

/// `host.editor_wakes(text)`: the self-wake fact (`⏰ 2 wakes · next 14:05`) on its own row directly above
/// the session status bar, or "" to take the row away again when nothing is scheduled. It used to be
/// appended to the status bar's own text, where it squeezed the numbers (Victor, 13/11).
///
/// Redraws only when the fact changed: this is called from the footer path, which runs on every event of a
/// run, and a frame per call would be a frame per token.
pub extern "C-unwind" fn editor_wakes(l: *mut LuaState) -> c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    let changed = state.editor.as_mut().map(|editor| {
        let changed = editor.wakes != text;
        editor.wakes = text;
        changed
    }).unwrap_or(false);
    let ok = if changed {
        let frame = layout_frame(&mut state);
        frame.is_empty() || wa_term::terminal_editor::write(&frame).is_ok()
    } else { true };
    unsafe { wa_host_support::lua::lua_pushboolean(l, if ok { 1 } else { 0 }) };
    1
}

/// `host.editor_notice(text)`: the standing update notice on the editor's own row between the box and the
/// footer, or "" to take the row away. ONE drawer (14/11): the notice used to be painted by the Lua view at
/// a row it reserved itself while the editor, never told, put the box's bottom border on that same row -
/// each frame repainted the border and the next notice write covered it again, a blink over the divider.
/// Redraws only when the text changed, like `editor_wakes`.
pub extern "C-unwind" fn editor_notice(l: *mut LuaState) -> c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    let changed = state.editor.as_mut().map(|editor| {
        let changed = editor.session_notice != text;
        editor.session_notice = text;
        changed
    }).unwrap_or(false);
    let ok = if changed {
        let frame = layout_frame(&mut state);
        frame.is_empty() || wa_term::terminal_editor::write(&frame).is_ok()
    } else { true };
    unsafe { wa_host_support::lua::lua_pushboolean(l, if ok { 1 } else { 0 }) };
    1
}

/// `host.transcript_write(text)`: append to the chat's current block (the host draws it).
pub extern "C-unwind" fn transcript_write(l: *mut LuaState) -> c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    state.transcript.write(&text);
    let ok = if state.editor.as_ref().is_some_and(|e| e.row > 0) && state.panel.is_none() && !state.transcript_held {
        let frame = layout_frame(&mut state);
        wa_term::terminal_editor::write(&frame).is_ok()
    } else { true };
    unsafe { wa_host_support::lua::lua_pushboolean(l, if ok { 1 } else { 0 }) };
    1
}

/// `host.status_snapshot(spec_json)`: the panel `/status` shows if it is submitted while a run is in
/// flight (`{title, lines}`, as `host.panel` takes it). Replaced on every call; never opened here.
pub extern "C-unwind" fn status_snapshot(l: *mut LuaState) -> c_int {
    let spec = arg_string(l, 1).and_then(|text| serde_json::from_str::<Value>(&text).ok()).filter(|v| v.is_object());
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    state.status_snapshot = spec;
    unsafe { wa_host_support::lua::lua_pushboolean(l, 1) };
    1
}

/// `host.local_view(command, spec_json)`: a read-only `/` command's whole balloon, filed so the reader
/// thread can draw it while a run is in flight (`lua/core/local_views.lua`, `lua/core/balloon.lua`).
///
/// The interpreter publishes at the moments it is running - a turn's start and each model-round
/// boundary - and the reader's Enter is answered from that snapshot, never by waiting for the side that
/// is blocked in the model call. The spec is checked before it is filed (`rust/wa-cli-views`): a view
/// that could hurt the thread drawing it is refused, and the refusal is the answer.
///
/// Answers one JSON text string, never a Lua table: `{ok:true, command, views, captured_at}` or
/// `{ok:false, error, detail}` - the caller decodes it with `lua/vendor/json.lua`.
pub extern "C-unwind" fn local_view(l: *mut LuaState) -> c_int {
    let command = arg_string(l, 1).unwrap_or_default();
    let spec = arg_string(l, 2).unwrap_or_default();
    let answer = wa_cli_views::publish(&command, &spec);
    push_json(l, &answer);
    1
}

/// `host.transcript_hold(on)`: while on, `transcript_write` keeps what it is given without drawing it;
/// turning it off draws the result once. A resumed session's replay is thousands of writes, and a
/// frame per write is thousands of full redraws for a picture nobody sees until the last one.
pub extern "C-unwind" fn transcript_hold(l: *mut LuaState) -> c_int {
    let on = unsafe { wa_host_support::lua::lua_toboolean(l, 1) } != 0;
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    let was = std::mem::replace(&mut state.transcript_held, on);
    if was && !on && state.editor.as_ref().is_some_and(|e| e.row > 0) && state.panel.is_none() {
        state.transcript.dirty = true;
        let frame = layout_frame(&mut state);
        let _ = wa_term::terminal_editor::write(&frame);
    }
    unsafe { wa_host_support::lua::lua_pushboolean(l, 1) };
    1
}

/// `host.transcript_block(topic, code)`: start a new block; `topic` = collapsible (thinking, a tool
/// call). `code` = a code-mode block: drawn expanded while it is the running one and folded to its
/// summary when the next one starts (`host.transcript_fold`).
pub extern "C-unwind" fn transcript_block(l: *mut LuaState) -> c_int {
    let topic = unsafe { wa_host_support::lua::lua_toboolean(l, 1) } != 0;
    let code = unsafe { wa_host_support::lua::lua_toboolean(l, 2) } != 0;
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    if code { state.transcript.code_block(); } else { state.transcript.block(topic); }
    unsafe { wa_host_support::lua::lua_pushboolean(l, 1) };
    1
}

/// `host.transcript_fold(summary)`: collapse the newest code-mode block to ONE row - the summary the
/// view built for it (`⏺ Code · bash ×3 ✓ · 1.2s → "a,b,c"`) - because a newer code-mode block has
/// taken the screen. A block the reader pinned with Ctrl+O is not collapsed. Returns whether it
/// folded.
pub extern "C-unwind" fn transcript_fold(l: *mut LuaState) -> c_int {
    let summary = arg_string(l, 1).unwrap_or_default();
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    let ok = state.transcript.fold_code(&summary);
    if ok && state.editor.as_ref().is_some_and(|e| e.row > 0) && state.panel.is_none() && !state.transcript_held {
        let frame = layout_frame(&mut state);
        let _ = wa_term::terminal_editor::write(&frame);
    }
    unsafe { wa_host_support::lua::lua_pushboolean(l, if ok { 1 } else { 0 }) };
    1
}

/// `host.transcript_rewrite(offset, text)`: replace a committed line of the current block, counted
/// from its end (`-1` = the last row). A code-mode block draws one row per inner call as the call
/// starts, and this is what flips that row's `⏳` to `✓` when it settles - in place, without drawing
/// the block again. Returns false when there is no such row.
pub extern "C-unwind" fn transcript_rewrite(l: *mut LuaState) -> c_int {
    let offset = unsafe { wa_host_support::lua::lua_tointegerx(l, 1, std::ptr::null_mut()) } as isize;
    let text = arg_string(l, 2).unwrap_or_default();
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    let ok = state.transcript.rewrite(offset, &text);
    if ok && state.editor.as_ref().is_some_and(|e| e.row > 0) && state.panel.is_none() && !state.transcript_held {
        let frame = layout_frame(&mut state);
        let _ = wa_term::terminal_editor::write(&frame);
    }
    unsafe { wa_host_support::lua::lua_pushboolean(l, if ok { 1 } else { 0 }) };
    1
}

/// `host.transcript_live(text)`: the running tool call's line, INSIDE that call's own block - the
/// heading is the block's first row, this is the row under it, rewritten in place. Empty text (or no
/// text at all) takes it away. The host's ticker keeps it current while Lua is blocked
/// (`refresh_tool_progress`); a view that has no host transcript has no live row and this is a no-op.
///
/// It never touches the session-status-content row: that one is the update notice's (Victor,
/// 2026-11-10).
pub extern "C-unwind" fn transcript_live(l: *mut LuaState) -> c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    if text.trim().is_empty() { state.transcript.live(None) } else { state.transcript.live(Some(&text)) }
    let ok = if state.editor.as_ref().is_some_and(|e| e.row > 0) && state.panel.is_none() && !state.transcript_held {
        let frame = layout_frame(&mut state);
        wa_term::terminal_editor::write(&frame).is_ok()
    } else { true };
    unsafe { wa_host_support::lua::lua_pushboolean(l, if ok { 1 } else { 0 }) };
    1
}

/// `host.transcript_copy(markers_json)`: the lines of the NEXT `transcript_write` that can be copied
/// (#114) - `[{"at": <line of that write>, "text": "<the block's content>"}]`. The transcript draws
/// the affordance in front of each of them and answers a click on it with that content (OSC 52),
/// which is how a fenced block in the chat reaches the reader's clipboard without a selection.
pub extern "C-unwind" fn transcript_copy(l: *mut LuaState) -> c_int {
    let markers: Vec<(usize, String)> = arg_string(l, 1)
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|value| value.as_array().cloned())
        .unwrap_or_default()
        .iter()
        .filter_map(|item| {
            let at = item.get("at")?.as_u64()? as usize;
            let text = item.get("text")?.as_str()?.to_string();
            Some((at, text))
        })
        .collect();
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    state.transcript.copyable(&markers);
    unsafe { wa_host_support::lua::lua_pushboolean(l, if markers.is_empty() { 0 } else { 1 }) };
    1
}

/// `host.transcript_expand(markers_json)`: lines of the NEXT `transcript_write` that expand on a click
/// - `[{"at": <line of that write>, "text": "<the full text, one row per \n>"}]`. A code-mode result is
/// written as one row ending `… +N chars`; the reader hovers it (it brightens) and clicks it to see it all
/// (operator 17/11).
pub extern "C-unwind" fn transcript_expand(l: *mut LuaState) -> c_int {
    let markers: Vec<(usize, String)> = arg_string(l, 1)
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|value| value.as_array().cloned())
        .unwrap_or_default()
        .iter()
        .filter_map(|item| Some((item.get("at")?.as_u64()? as usize, item.get("text")?.as_str()?.to_string())))
        .collect();
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    state.transcript.expandable(&markers);
    unsafe { wa_host_support::lua::lua_pushboolean(l, if markers.is_empty() { 0 } else { 1 }) };
    1
}

/// What this process can see of the system clipboard: the switch that turns reading off, and which
/// of the two display servers is reachable.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
struct ClipboardHost {
    off: bool,
    wayland: bool,
    x11: bool,
}

impl ClipboardHost {
    fn from_env() -> Self {
        ClipboardHost {
            off: std::env::var("WA_CLIPBOARD").map(|value| value == "off").unwrap_or(false),
            wayland: std::env::var_os("WAYLAND_DISPLAY").is_some(),
            x11: std::env::var_os("DISPLAY").is_some(),
        }
    }
}

/// The image types asked of a clipboard, in preference order, and the size a paste may be. Both are
/// data rather than literals inside the reader so the rules can be tested without a clipboard.
const CLIPBOARD_TYPES: [&str; 4] = ["image/png", "image/jpeg", "image/webp", "image/gif"];
const CLIPBOARD_MAX: usize = 20 * 1024 * 1024;

/// The first type this node understands from a clipboard's own type list.
fn pick_clipboard_type(listed: &[u8]) -> Option<&'static str> {
    let text = String::from_utf8_lossy(listed);
    CLIPBOARD_TYPES.iter().copied().find(|kind| text.lines().any(|line| line.trim() == *kind))
}

/// The reader, given the host it sees and the way it runs a clipboard tool: `wl-paste --list-types`
/// then `wl-paste --type <type>` on Wayland, `xclip ... -t TARGETS` then `-t <type> -o` on X11. The
/// one-line notice the footer shows is the error.
fn read_clipboard_image_with(host: ClipboardHost, run: impl Fn(&str, &[&str]) -> Option<Vec<u8>>)
    -> Result<(String, Vec<u8>), String> {
    if host.off {
        return Err("clipboard reading is off here (WA_CLIPBOARD=off)".into());
    }
    let mut tried = false;
    if host.wayland {
        if let Some(listed) = run("wl-paste", &["--list-types"]) {
            tried = true;
            if let Some(kind) = pick_clipboard_type(&listed) {
                if let Some(bytes) = run("wl-paste", &["--no-newline", "--type", kind]) {
                    if bytes.len() > CLIPBOARD_MAX { return Err("the clipboard image is over 20 MB".into()); }
                    if !bytes.is_empty() { return clipboard_image(bytes); }
                }
            }
        }
    }
    if host.x11 {
        if let Some(listed) = run("xclip", &["-selection", "clipboard", "-t", "TARGETS", "-o"]) {
            tried = true;
            if let Some(kind) = pick_clipboard_type(&listed) {
                if let Some(bytes) = run("xclip", &["-selection", "clipboard", "-t", kind, "-o"]) {
                    if bytes.len() > CLIPBOARD_MAX { return Err("the clipboard image is over 20 MB".into()); }
                    if !bytes.is_empty() { return clipboard_image(bytes); }
                }
            }
        }
    }
    Err(if tried { "no image on the clipboard".into() }
        else { "no clipboard here: wl-paste (Wayland) or xclip (X11) is needed, on the machine wa chat runs on".into() })
}

/// A clipboard payload as an attachment: the BYTES say which image it is, and a payload that is not
/// one of them is refused instead of being attached under a name it does not match.
fn clipboard_image(bytes: Vec<u8>) -> Result<(String, Vec<u8>), String> {
    match sniff_image(&bytes) {
        Some(mime) => Ok((mime.to_string(), bytes)),
        None => Err("the clipboard says it holds an image, but its bytes are not a PNG, JPEG, WebP or GIF".into()),
    }
}

/// An image from the system clipboard, read where this process runs - the way pi and Claude Code do
/// it. Err is the one-line notice the footer shows.
fn read_clipboard_image() -> Result<(String, Vec<u8>), String> {
    read_clipboard_image_with(ClipboardHost::from_env(), |program, args| {
        let out = std::process::Command::new(program).args(args)
            .stdin(std::process::Stdio::null()).stderr(std::process::Stdio::null()).output().ok()?;
        out.status.success().then_some(out.stdout)
    })
}

/// The image types this node attaches, decided by the payload's own first bytes and never by a file
/// name: a path is text a terminal, a file manager or a page hands us, while the bytes are the image.
pub fn sniff_image(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") { return Some("image/png"); }
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) { return Some("image/jpeg"); }
    if bytes.len() > 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP" { return Some("image/webp"); }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") { return Some("image/gif"); }
    None
}

/// The largest image this node keeps for a message: it holds the bytes and the provider bills for
/// them, so a huge drop is refused rather than sent.
const IMAGE_MAX_BYTES: u64 = 20 * 1024 * 1024;

/// The one directory a dropped image may come from when it is not inside the session's own folders:
/// `WA_IMAGE_DROP_DIR` when the operator names one, else `<state>/attachments` (`docs/ONEROOT.md` - one
/// root everything an agent creates lives under, so one `wa clean` covers it). It is the explicit place
/// to drop a screenshot the agent should attach.
fn image_drop_dir_with(configured: Option<&str>) -> std::path::PathBuf {
    match configured.map(str::trim).filter(|value| !value.is_empty()) {
        Some(dir) => std::path::PathBuf::from(dir),
        None => wa_host_support::paths::state_root().join("attachments"),
    }
}

fn image_drop_dir() -> std::path::PathBuf {
    image_drop_dir_with(std::env::var("WA_IMAGE_DROP_DIR").ok().as_deref())
}

/// The directories an attached image may come from: the SESSION's own folders and one explicit drop
/// directory. It used to be all of HOME plus the temporary directory, which is every file the user owns
/// and every scratch file on the machine - a dropped path was a way to read any of them into a message
/// (review, 18/11). What a session actually needs is where it was started (the tree it works in, and a
/// screenshot of it), the node's own state root (scratch and tool-results), and the drop directory.
///
/// A symlink is still followed before the question is asked - that is the point of resolving first,
/// since a link is exactly how a path that looks local reads a private file.
fn image_roots() -> Vec<std::path::PathBuf> {
    image_roots_in(std::env::current_dir().ok(), std::path::PathBuf::from(wa_host_support::paths::resolve_home()))
}

/// The same list with the session's directory and the home injected, so the question can be asked about
/// a directory a test chose. The process's working directory is the session's own folder - UNLESS it is
/// the user's home, which is the review's point: a session started in HOME is the session with every
/// private file one path away, so the exclusion is about the DIRECTORY and not about how it was named
/// (round 5, LOW). What such a session still gets is the node's state root and the drop directory.
fn image_roots_in(cwd: Option<std::path::PathBuf>, home: std::path::PathBuf) -> Vec<std::path::PathBuf> {
    let resolve = |path: std::path::PathBuf| std::fs::canonicalize(&path).unwrap_or(path);
    let mut roots: Vec<std::path::PathBuf> = Vec::new();
    let mut add = |root: std::path::PathBuf| {
        let resolved = resolve(root);
        if !roots.contains(&resolved) { roots.push(resolved); }
    };
    let home = resolve(home);
    if let Some(cwd) = cwd {
        let cwd = resolve(cwd);
        if cwd != home { add(cwd); }
    }
    add(wa_host_support::paths::state_root());
    add(image_drop_dir());
    roots
}

/// The path an attachment may read, or None, inside `roots`. Symlinks are resolved first (so a link
/// out of an allowed directory is refused by where it LANDS, not by where it appears to be).
fn attachment_path_in(path: &std::path::Path, roots: &[std::path::PathBuf]) -> Option<std::path::PathBuf> {
    let resolved = std::fs::canonicalize(path).ok()?;
    if roots.iter().any(|root| resolved.starts_with(root)) { Some(resolved) } else { None }
}

fn attachment_path(path: &std::path::Path) -> Option<std::path::PathBuf> {
    attachment_path_in(path, &image_roots())
}

/// A pasted (or dropped) single path to an image file: its mime and bytes, or None. Quotes,
/// `file://` and `%20` are what terminals and file managers wrap a dropped path in.
///
/// Three refusals beyond "is it a file": the path must resolve inside an allowed directory
/// ([attachment_path]); the size must be bounded ([IMAGE_MAX_BYTES]); and the BYTES must be a PNG,
/// JPEG, WebP or GIF ([sniff_image]). The last one is what the extension used to stand for, and an
/// extension is only a name.
fn dropped_image(text: &str) -> Option<(String, Vec<u8>)> {
    dropped_image_in(text, &image_roots())
}

/// The same, with the allowed directories injected: the tests need a directory they created, and the
/// launch path needs the real list. One reader, one set of refusals.
fn dropped_image_in(text: &str, roots: &[std::path::PathBuf]) -> Option<(String, Vec<u8>)> {
    let mut path = text.trim().trim_matches(|c| c == '\'' || c == '"').to_string();
    if path.contains('\n') || path.is_empty() { return None; }
    if let Some(rest) = path.strip_prefix("file://") { path = rest.replace("%20", " "); }
    let resolved = attachment_path_in(std::path::Path::new(&path), roots)?;
    let meta = std::fs::metadata(&resolved).ok()?;
    if !meta.is_file() || meta.len() == 0 || meta.len() > IMAGE_MAX_BYTES { return None; }
    let bytes = std::fs::read(&resolved).ok()?;
    let mime = sniff_image(&bytes)?;
    Some((mime.to_string(), bytes))
}

/// Keep one image for this session and answer the token that names it plus the size said in KB. The
/// only place a token is minted, so a dropped path and a Ctrl+V paste cannot number or record their
/// image differently.
fn attach_image(state: &mut ConsoleInput, mime: &str, bytes: Vec<u8>) -> (String, usize) {
    let kb = bytes.len() / 1024;
    state.pasted_images.push((mime.to_string(), base64::engine::general_purpose::STANDARD.encode(&bytes)));
    let number = state.pasted_images.len();
    state.draft_images.push(number);
    (format!("[Image #{number}]"), kb)
}

/// The tokens of `inserted` that the submitted line still carries: an image the reader deleted from
/// the draft is not sent, and an `[Image #n]` the reader typed is not in `inserted` at all.
fn submitted_tokens(inserted: &[usize], text: &str) -> Vec<usize> {
    inserted.iter().copied().filter(|number| text.contains(&format!("[Image #{number}]"))).collect()
}

/// `host.transcript_copy_first(text)`: the current block's first line becomes copyable with `text` (a code-mode
/// block's script, known when its call settles).
pub extern "C-unwind" fn transcript_copy_first(l: *mut LuaState) -> c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    let ok = !text.is_empty() && state.transcript.copy_first(&text);
    unsafe { wa_host_support::lua::lua_pushboolean(l, if ok { 1 } else { 0 }) };
    1
}

/// `host.link_span(text)`: the first bare URL in `text` as "start,stop", 1-based byte offsets
/// inclusive (Lua string positions), or nil. This is THE URL detector (`wa_term::links`): the renderer
/// (`lua/core/markdown.lua`) underlines what this answers, and a click copies what a lookup in the same
/// function answers, so the two can no longer disagree about where a link ends. Two numbers in one
/// string rather than a table: the only caller slices the line with them.
pub extern "C-unwind" fn link_span(l: *mut LuaState) -> c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    match wa_term::links::first_bytes(&text) {
        Some((start, end)) => {
            let answer = format!("{},{}", start + 1, end);
            unsafe { lua_pushlstring(l, answer.as_ptr() as *const c_char, answer.len()) };
        }
        None => unsafe { wa_host_support::lua::lua_pushnil(l) },
    }
    1
}

/// `host.keybindings()`: every special key the console handles, as JSON - one row per binding,
/// `{surface, title, group, key, does}`, in the order `/keybindings` prints them. The rows come from
/// `wa_term::keymap`, which is the table the editor, the slash menu, the transcript's blocks, a
/// panel, the pointer and this reader thread all dispatch on, and the fullscreen console's rows come
/// from the settings it obeys (`WA_TUI_KEYS`) - so the list a reader is shown is generated from the
/// behaviour, never written beside it.
pub extern "C-unwind" fn keybindings(l: *mut LuaState) -> c_int {
    let answer = wa_term::keymap::json();
    unsafe { lua_pushlstring(l, answer.as_ptr() as *const c_char, answer.len()) };
    1
}

/// `host.input_image(n)`: the image the line just submitted carried as `[Image #n]`,
/// `{"mime","data"}` (base64), or nil. The gate is the draft that inserted it: a token typed by hand,
/// or one left over from an earlier message, names no image and answers nil.
pub extern "C-unwind" fn input_image(l: *mut LuaState) -> c_int {
    let n = arg_integer(l, 1).unwrap_or(0);
    let (lock, _) = console_input();
    let state = lock.lock().unwrap_or_else(|e| e.into_inner());
    if n >= 1 && state.submitted_images.contains(&(n as usize)) {
        if let Some((mime, data)) = state.pasted_images.get((n - 1) as usize) {
            let value = serde_json::json!({ "mime": mime, "data": data }).to_string();
            unsafe { lua_pushlstring(l, value.as_ptr() as *const c_char, value.len()) };
            return 1;
        }
    }
    unsafe { wa_host_support::lua::lua_pushnil(l) };
    1
}

/// `host.transcript_head(text)`: replace the first line of the current block. A tool call prints its
/// heading when it **starts** (so the block its progress belongs to exists while the call runs) and
/// rewrites that same row when the result lands, which is where its dot says how the call went.
pub extern "C-unwind" fn transcript_head(l: *mut LuaState) -> c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    let ok = state.transcript.head(&text);
    if ok && state.editor.as_ref().is_some_and(|e| e.row > 0) && state.panel.is_none() && !state.transcript_held {
        let frame = layout_frame(&mut state);
        let _ = wa_term::terminal_editor::write(&frame);
    }
    unsafe { wa_host_support::lua::lua_pushboolean(l, if ok { 1 } else { 0 }) };
    1
}

/// `host.editor_status(on)`: whether the status line row exists. It is there only while a run is in
/// flight, so between runs the chat sits directly on the input.
pub extern "C-unwind" fn editor_status(l: *mut LuaState) -> c_int {
    let on = unsafe { wa_host_support::lua::lua_toboolean(l, 1) } != 0;
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    let ok = if let Some(editor) = state.editor.as_mut() {
        if editor.status != on {
            editor.status = on;
            editor.notice.clear();
            if editor.row > 0 && state.panel.is_none() {
                let frame = layout_frame(&mut state);
                let _ = wa_term::terminal_editor::write(&frame);
            }
        }
        true
    } else { false };
    unsafe { wa_host_support::lua::lua_pushboolean(l, if ok { 1 } else { 0 }) };
    1
}

/// `host.input_commands(json)`: what the slash menu offers, `[{name, args, hint}]`.
pub extern "C-unwind" fn input_commands(l: *mut LuaState) -> c_int {
    let list: Vec<wa_term::terminal_editor::Command> = arg_string(l, 1)
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|value| value.as_array().cloned()).unwrap_or_default().iter()
        .filter_map(|item| Some(wa_term::terminal_editor::Command {
            name: item.get("name")?.as_str()?.to_string(),
            args: item.get("args").and_then(|v| v.as_bool()).unwrap_or(false),
            hint: item.get("hint").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        })).collect();
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    let ok = if let Some(editor) = state.editor.as_mut() { editor.commands = list; true } else { false };
    unsafe { wa_host_support::lua::lua_pushboolean(l, if ok { 1 } else { 0 }) };
    1
}

/// What the editor lists above the status line as queued: the lines Lua took but holds (a slash
/// command waits for the run's end; `input_held`), then the lines not taken yet. True if it changed.
fn sync_queued(state: &mut ConsoleInput) -> bool {
    let queued: Vec<String> = state.held.iter().chain(state.lines.iter()).cloned().collect();
    match state.editor.as_mut() {
        Some(editor) if editor.queued != queued => { editor.queued = queued; true }
        _ => false,
    }
}

/// Redraw the bottom of the screen (and the chat, when its region moved) outside a keystroke.
fn redraw_bottom(state: &mut ConsoleInput) {
    if state.editor.as_ref().is_some_and(|e| e.row > 0) && state.panel.is_none() {
        let frame = layout_frame(state);
        if !frame.is_empty() { let _ = wa_term::terminal_editor::write(&frame); }
    }
}

/// `host.input_held(json)`: the lines Lua took from the queue but has not used yet (`[text]`), so
/// the editor keeps listing them as queued. `[]` once they are used.
pub extern "C-unwind" fn input_held(l: *mut LuaState) -> c_int {
    let held: Vec<String> = arg_string(l, 1)
        .and_then(|text| serde_json::from_str::<Vec<String>>(&text).ok()).unwrap_or_default();
    let (lock, _) = console_input();
    let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
    state.held = held;
    if sync_queued(&mut state) { redraw_bottom(&mut state); }
    unsafe { wa_host_support::lua::lua_pushboolean(l, if state.editor.is_some() { 1 } else { 0 }) };
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

    /// Returns JSON text of the array of typed lines; A string the caller decodes (`lua/vendor/json.lua`), never a Lua table.
/// `host.input_take(timeout_ms)` -> `{lines, eof, running}`.
///
/// Waits up to `timeout_ms` for at least one line, and answers immediately with whatever is
/// already buffered - which is what makes a line typed during a run arrive the moment the run
/// ends, with no polling and no lost keystrokes. `timeout_ms` of 0 means "take what is there
/// now", for a caller draining a queue. An empty answer is an array and not a missing value:
/// "nothing typed yet" is not "no console".
pub extern "C-unwind" fn input_take(l: *mut LuaState) -> c_int {
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
    if !lines.is_empty() && sync_queued(&mut state) { redraw_bottom(&mut state); }
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
pub fn restore_input() {
    let (lock, wake) = console_input();
    if let Ok(mut state) = lock.lock() {
        state.stop = true;
        if state.editor.is_some() { let _ = wa_term::terminal_editor::write(&format!("\x1b[?2004l{}", wa_term::selection::DISABLE)); }
        state.selection = None;
        state.mouse_pending.clear();
        state.editor = None;
        state.panel = None;
        state.region = 0;
        state.transcript = Default::default();
        state.nav = None;
        state.raw = None; // Drop restores the original console mode and input codepage.
        wake.notify_all();
    }
}

    /// Answers JSON text; A string the caller decodes (`lua/vendor/json.lua`), never a Lua table.
/// `host.input_idle()` -> `{idle, draft_empty, panel, queued, selection}`: whether the CLI can restart
/// now without throwing away anything the reader is doing.
pub extern "C-unwind" fn input_idle(l: *mut LuaState) -> c_int {
    let (lock, _) = console_input();
    let state = lock.lock().unwrap_or_else(|e| e.into_inner());
    let draft_empty = state.editor.as_ref().map(|e| e.draft_empty()).unwrap_or(true);
    let queued = state.lines.len() + state.held.len();
    let panel = state.panel.is_some();
    let selection = state.selection.is_some();
    push_json(l, &json!({"idle": draft_empty && !panel && queued == 0 && !selection,
        "draft_empty": draft_empty, "panel": panel, "queued": queued, "selection": selection}));
    1
}

/// The binary this process runs, as found on disk at the first ask: `(path, inode, mtime, len)`.
static BINARY_AT_START: OnceLock<Option<(std::path::PathBuf, u64, Option<std::time::SystemTime>, u64)>> = OnceLock::new();

/// This process's own binary, by its path (a replaced file shows as `<path> (deleted)` on Linux).
fn binary_path() -> Option<(std::path::PathBuf, bool)> {
    let path = std::env::current_exe().ok()?;
    let text = path.to_string_lossy().to_string();
    match text.strip_suffix(" (deleted)") { Some(clean) => Some((clean.into(), true)), None => Some((path, false)) }
}

fn binary_identity(path: &std::path::Path) -> (u64, Option<std::time::SystemTime>, u64) {
    let meta = std::fs::metadata(path).ok();
    #[cfg(unix)] let inode = { use std::os::unix::fs::MetadataExt; meta.as_ref().map(|m| m.ino()).unwrap_or(0) };
    #[cfg(not(unix))] let inode = 0u64;
    (inode, meta.as_ref().and_then(|m| m.modified().ok()), meta.map(|m| m.len()).unwrap_or(0))
}

    /// Answers JSON text; A string the caller decodes (`lua/vendor/json.lua`), never a Lua table.
/// `host.binary_changed()` -> `{changed, path, reason?}`. The first call records what is on disk; a
/// later one says whether the file at that path is another binary now (an install replaced it: a new
/// inode, or the running file shows as deleted, or the same file was rewritten). The CLI asks this
/// between runs to restart itself into the build a deploy installed (lua/core/cli_restart.lua).
pub extern "C-unwind" fn binary_changed(l: *mut LuaState) -> c_int {
    let start = BINARY_AT_START.get_or_init(|| binary_path().map(|(path, _)| {
        let (inode, mtime, len) = binary_identity(&path);
        (path, inode, mtime, len)
    }));
    let Some((path, inode, mtime, len)) = start.as_ref() else {
        push_json(l, &json!({"changed": false, "error": "binary_path_unknown"}));
        return 1;
    };
    let deleted = binary_path().map(|(_, deleted)| deleted).unwrap_or(false);
    let (now_inode, now_mtime, now_len) = binary_identity(path);
    let reason = if !path.exists() { None }
        else if deleted { Some("the running binary was replaced") }
        else if now_inode != *inode { Some("a new binary was installed at this path") }
        else if now_mtime != *mtime || now_len != *len { Some("the binary was rewritten") }
        else { None };
    push_json(l, &json!({"changed": reason.is_some(), "path": path.to_string_lossy(), "reason": reason}));
    1
}

    /// Answers JSON text (one string the caller decodes with `lua/vendor/json.lua`), never a Lua table.
/// `host.cli_reexec(args_json, env_json)`: give the terminal back (raw mode, scroll region, mouse,
/// paste mode - everything `input_stop` restores) and replace this process with the wa binary at
/// this process's own path, run with `args` and these extra environment values. Only returns on
/// failure: `{error}`. `WA_REEXEC_BINARY` names another binary (tests).
pub extern "C-unwind" fn cli_reexec(l: *mut LuaState) -> c_int {
    let args: Vec<String> = arg_string(l, 1).and_then(|raw| serde_json::from_str(&raw).ok()).unwrap_or_default();
    let env: serde_json::Map<String, Value> = arg_string(l, 2).and_then(|raw| serde_json::from_str(&raw).ok()).unwrap_or_default();
    let binary = std::env::var("WA_REEXEC_BINARY").ok().filter(|b| !b.is_empty()).map(std::path::PathBuf::from)
        .or_else(|| binary_path().map(|(path, _)| path));
    let Some(binary) = binary.filter(|path| path.exists()) else {
        push_json(l, &json!({"error": "binary_not_found"}));
        return 1;
    };
    restore_input();
    let mut command = std::process::Command::new(&binary);
    // The same database this process resolved (main.rs exports it), or a `wa --db x` session would
    // come back looking for its thread in the default ledger.
    if let Ok(db) = std::env::var("WASM_AGENT_DB") { if !db.is_empty() { command.arg("--db").arg(db); } }
    command.args(&args);
    for (key, value) in env { command.env(key, value.as_str().map(str::to_string).unwrap_or_else(|| value.to_string())); }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let error = command.exec(); // returns only on failure
        push_json(l, &json!({"error": format!("exec_failed: {error}"), "binary": binary.to_string_lossy()}));
        return 1;
    }
    #[cfg(not(unix))]
    {
        // No exec on Windows: run the new process in this console and leave with its status.
        match command.status() {
            Ok(status) => std::process::exit(status.code().unwrap_or(0)),
            Err(error) => { push_json(l, &json!({"error": format!("spawn_failed: {error}")})); return 1; }
        }
    }
}

/// **One string, not a table.** Restores the terminal the CLI's line reader took over.
///
/// host.input_stop() -> JSON text of `{stopped: true}`.
pub extern "C-unwind" fn input_stop(l: *mut LuaState) -> c_int {
    restore_input();
    push_json(l, &json!({"stopped": true}));
    1
}

#[cfg(test)]
mod terminal_tests {
    use super::usable_size;
    use serde_json::json;

    /// A line sent during a run is listed above the status line until Lua takes it; a line Lua
    /// holds for after the run (`input_held`) stays listed; taking it hands the rows back to the chat.
    #[test]
    fn a_steer_is_listed_until_it_is_taken() {
        let mut state = super::ConsoleInput::default();
        let mut editor = wa_term::terminal_editor::Editor::default();
        editor.row = 39; editor.width = 80; editor.height = 3; editor.status = true;
        state.editor = Some(editor);
        let bottom = state.editor.as_ref().unwrap().out_bottom();
        state.lines.push("use the new requirement".into());
        assert!(super::sync_queued(&mut state));
        assert!(!super::sync_queued(&mut state), "nothing new: no redraw");
        assert_eq!(state.editor.as_ref().unwrap().out_bottom(), bottom - 1, "one row above the status line");
        state.lines.clear();
        state.held = vec!["/model".into()];
        assert!(super::sync_queued(&mut state));
        assert_eq!(state.editor.as_ref().unwrap().queued, vec!["/model".to_string()], "a held command stays listed");
        state.held.clear();
        assert!(super::sync_queued(&mut state));
        assert_eq!(state.editor.as_ref().unwrap().out_bottom(), bottom, "used: the row goes back to the chat");
    }

    /// PageUp/PageDown move a third of the rows the chat occupies at the key press - the terminal
    /// minus the input box, status and footer - so a taller draft or a run's status row pages less.
    #[test]
    fn a_page_is_a_third_of_the_chat_rows_on_screen() {
        let mut state = super::ConsoleInput::default();
        let mut editor = wa_term::terminal_editor::Editor::default();
        editor.row = 39; editor.width = 80; editor.height = 3;
        state.editor = Some(editor);
        let area = state.editor.as_ref().unwrap().out_bottom();
        assert_eq!(area, 36, "a 40-row terminal: footer, box borders and one draft row below the chat");
        assert_eq!(super::page_rows(&state), 12);
        state.editor.as_mut().unwrap().status = true;
        assert_eq!(super::page_rows(&state), 11, "a run's status row is not chat: 35 rows, a third is 11");
        state.editor.as_mut().unwrap().row = 9;
        let small = state.editor.as_ref().unwrap().out_bottom();
        assert!(small < 6, "a 10-row terminal leaves under six chat rows: {small}");
        assert_eq!(super::page_rows(&state), 1, "and a page there is still one row, never zero");
    }

    /// The scrollbar's mouse (operator, 13/11 ~06:50). A press in the bar's column scrolls the chat
    /// and starts no selection; a press in the text is still a selection; motion only thickens the
    /// thumb while the pointer is on the bar; and an open panel - the balloon, the slash menu, a
    /// `/status` - keeps the mouse to itself, as it did before the bar existed.
    #[test]
    fn a_press_on_the_bar_scrolls_it_and_starts_no_selection() {
        use wa_term::selection::Mouse;
        let mut state = super::ConsoleInput::default();
        let mut editor = wa_term::terminal_editor::Editor::default();
        editor.row = 39; editor.width = 80; editor.height = 3;
        state.editor = Some(editor);
        for n in 0..400 { state.transcript.write(&format!("line {n}\n")); }
        let _ = super::layout_frame(&mut state); // one frame: the transcript knows its bar
        let rows = super::output_rows(None, state.editor.as_ref().unwrap());
        assert!(rows > 10, "forty rows of terminal, a chat of {rows}");
        assert!(state.transcript.bar().is_some_and(|bar| bar.scrolling()), "a long chat draws a bar to scroll");
        // A press on the bar's column (the screen's last one), three rows down.
        super::handle_mouse(&mut state, Mouse::Press(3, 80));
        assert!(state.selection.is_none(), "a click on the bar is not a text selection");
        assert!(!state.transcript.following(), "and it moved the view away from the bottom");
        // The button up, then the pointer: on the bar (thick), off it (thin).
        super::handle_mouse(&mut state, Mouse::Release(3, 80));
        super::handle_mouse(&mut state, Mouse::Motion(5, 80));
        assert!(state.transcript.bar_active(), "the pointer is on the bar");
        super::handle_mouse(&mut state, Mouse::Motion(5, 40));
        assert!(!state.transcript.bar_active(), "and it left: the thumb is thin again");
        // The chat's text is still selected with the mouse, exactly as before.
        super::handle_mouse(&mut state, Mouse::Press(5, 10));
        assert!(state.selection.is_some(), "text is still selected with the mouse");
        // An open panel owns the screen's bottom, and its mouse.
        state.selection = None;
        state.panel = Some(wa_term::terminal_editor::Panel::from_spec(&json!({"title": "balloon"}), 80, rows));
        super::handle_mouse(&mut state, Mouse::Press(3, 80));
        super::handle_mouse(&mut state, Mouse::Motion(5, 80));
        assert!(state.selection.is_none() && !state.transcript.bar_active(), "the open panel kept the mouse");
    }

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
pub extern "C-unwind" fn now(l: *mut LuaState) -> c_int {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    unsafe { wa_host_support::lua::lua_pushnumber(l, seconds) };
    1
}

/// `host.exec_timeout(requested_seconds?)` -> the deadline a `bash`/`shell` call is given, in seconds.
///
/// With no argument, this returns the configured default, limited by any active child budget.
/// With an override, it applies the same validation and child budget as `host.exec`, so a trace can
/// show the actual deadline. Out-of-range integer overrides return `nil`; `host.exec` reports the
/// corresponding error when called.
pub extern "C-unwind" fn exec_timeout(l: *mut LuaState) -> c_int {
    let requested = match arg_integer(l, 1) {
        Some(value) => match u64::try_from(value) {
            Ok(value) => Some(value),
            Err(_) => {
                unsafe { wa_host_support::lua::lua_pushnil(l) };
                return 1;
            }
        },
        None => None,
    };
    match effective_exec_timeout_seconds(requested) {
        Ok(seconds) => unsafe { wa_host_support::lua::lua_pushnumber(l, seconds as f64) },
        Err(_) => unsafe { wa_host_support::lua::lua_pushnil(l) },
    }
    1
}

/// The ordinary OpenAI-compatible path's share of the `decision` contract: what the window is shown
/// while a tool call is still being written (and what it must never be shown). The subscription
/// wire's own half lives in `scripts/test-subscription-wire.lua`; both read the *same* expectation
/// fixture, `tests/fixtures/decision-events/parity.json`, so the two dialects are pinned to one
/// reader-visible sequence instead of two descriptions of it.
#[cfg(test)]
mod decision_stream_tests {
    use super::*;
    use std::io::{Read, Write};

    /// A one-shot loopback SSE endpoint, so the reader is exercised against real HTTP framing
    /// rather than a string. Kept beside these tests rather than shared, because the existing
    /// `stream_tests` helper is private to that module and moving it would touch tests this
    /// change has no business rewriting.
    fn decision_fixture(body: &str) -> (Value, String) {
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
        let result = std::cell::RefCell::new(Value::Null);
        // The events the reader emits are captured in this call's own sink, which is why the
        // assertion below sees them and an outer sink would not.
        let events = crate::serve::capture_events(|| {
            *result.borrow_mut() = stream_completion("POST", &format!("http://{address}/fixture"), &[], "{}", 0).unwrap();
        });
        server.join().unwrap();
        (result.into_inner(), events)
    }

    fn decisions(events: &str) -> Vec<Value> {
        events.lines().filter_map(|line| line.strip_prefix("data: "))
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .filter(|event| event["type"] == "decision").collect()
    }

    /// The reader-visible meaning of one decision, with the dialect-specific call id left out:
    /// the subscription ids carry `call_id|item_id` and the ordinary ones carry the provider's
    /// call id, which is a genuine provider difference and not a semantic one.
    fn semantics(event: &Value) -> Value {
        json!({
            "complete": event["complete"],
            "name": event["name"],
            "arguments_text": event["arguments_text"],
            "arguments_truncated": event.get("arguments_truncated").cloned().unwrap_or(Value::Bool(false)),
        })
    }

    const TRUNCATION_NOTE: &str = "\u{2026} [preview only; complete arguments in result]";

    #[test]
    fn ordinary_stream_announces_then_completes_one_tool_call() {
        let (result, events) = decision_fixture(concat!(
            "data: {\"id\":\"resp-1\",\"choices\":[{\"delta\":{\"role\":\"assistant\",\"tool_calls\":[{\"index\":0,\"id\":\"call_abc\",\"type\":\"function\",\"function\":{\"name\":\"get_time\",\"arguments\":\"\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"zone\\\"\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\":\\\"UTC\\\"}\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
            "data: [DONE]\n\n"));
        assert_eq!(result["tool_calls"][0]["id"], "call_abc");
        assert_eq!(result["tool_calls"][0]["function"]["name"], "get_time");
        assert_eq!(result["tool_calls"][0]["function"]["arguments"], "{\"zone\":\"UTC\"}");
        let seen = decisions(&events);
        assert_eq!(seen.len(), 2, "one forming and one complete decision: {events}");
        assert_eq!(seen[0]["complete"], false);
        assert_eq!(seen[0]["call_id"], "call_abc");
        assert_eq!(seen[0]["name"], "get_time");
        assert_eq!(seen[0]["arguments_text"], "{\"zone\"");
        assert_eq!(seen[1]["complete"], true);
        assert_eq!(seen[1]["call_id"], "call_abc");
        assert_eq!(seen[1]["arguments_text"], "{\"zone\":\"UTC\"}");
        assert!(seen[0].get("arguments_truncated").is_none() && seen[1].get("arguments_truncated").is_none());
        assert!(seen[1].get("previous_call_id").is_none(), "one stable id needs no re-identification");
    }

    #[test]
    fn text_only_answer_emits_no_decision() {
        let (result, events) = decision_fixture(concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"just words\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n"));
        assert_eq!(result["content"], "just words");
        assert!(decisions(&events).is_empty(), "a text answer asks for no tool: {events}");
    }

    /// The reader side of the prelude rule in `lua/core/agent.lua`: a step that writes prose *and*
    /// asks for a tool must report both, and must report `finish_reason: tool_calls` - the one
    /// provider signal the rule is allowed to read. A reader that dropped either would leave the
    /// rule unable to fire, and the prose outside the run topic again.
    #[test]
    fn a_step_that_writes_text_and_calls_a_tool_reports_both() {
        let (result, _events) = decision_fixture(concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"Let me check the ledger.\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_p\",\"function\":{\"name\":\"read\",\"arguments\":\"{}\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
            "data: [DONE]\n\n"));
        assert_eq!(result["content"], "Let me check the ledger.");
        assert_eq!(result["finish_reason"], "tool_calls");
        assert_eq!(result["stream_complete"], true);
        assert_eq!(result["tool_calls"][0]["function"]["name"], "read");
    }

    /// The other half of the same pair: the same prose, no tool call, `stop`. The verdict comes
    /// from the completion reason and nothing else, so this step stays an answer.
    #[test]
    fn prose_without_a_tool_call_reports_stop_and_no_calls() {
        let (result, _events) = decision_fixture(concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"Let me check the ledger.\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n"));
        assert_eq!(result["content"], "Let me check the ledger.");
        assert_eq!(result["finish_reason"], "stop");
        assert!(result["tool_calls"].as_array().unwrap().is_empty());
    }

    /// The case the rule must refuse: a stream cut right after a tool call reports no reason at
    /// all. "No reason" is not a decision, so this step's prose stays answer text - which is the
    /// stated failure mode of the rule, and this is the fixture that pins it.
    #[test]
    fn a_stream_cut_after_a_tool_call_reports_no_finish_reason() {
        let (result, _events) = decision_fixture(concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"Checking.\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_cut\",\"function\":{\"name\":\"read\",\"arguments\":\"{\"}}]}}]}\n\n"));
        assert!(result["finish_reason"].is_null(), "a cut stream sends no reason: {result}");
        assert_eq!(result["saw_finish_reason"], false);
        assert_eq!(result["stream_complete"], false);
        assert_eq!(result["content"], "Checking.");
    }

    /// A reasoning-only step that then calls a tool has no answer text at all: there is nothing
    /// for the rule to move, and the thinking stays in its own channel.
    #[test]
    fn a_reasoning_only_step_that_calls_a_tool_has_no_answer_text() {
        let (result, _events) = decision_fixture(concat!(
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"weighing it\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_r\",\"function\":{\"name\":\"read\",\"arguments\":\"{}\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
            "data: [DONE]\n\n"));
        assert_eq!(result["content"], "");
        assert_eq!(result["reasoning"], "weighing it");
        assert_eq!(result["finish_reason"], "tool_calls");
    }

    #[test]
    fn decision_preview_is_bounded_and_truncation_is_flagged() {
        let filler = "X".repeat(300);
        let first = format!("{{\"a\":\"{}", "X".repeat(280));
        let second = format!("{}\"}}", "X".repeat(20));
        let body = format!(concat!(
            "data: {{\"choices\":[{{\"delta\":{{\"tool_calls\":[{{\"index\":0,\"id\":\"call_big\",\"function\":{{\"name\":\"blob\",\"arguments\":{}}}}}]}}}}]}}\n\n",
            "data: {{\"choices\":[{{\"delta\":{{\"tool_calls\":[{{\"index\":0,\"function\":{{\"arguments\":{}}}}}]}}}}]}}\n\n",
            "data: {{\"choices\":[{{\"delta\":{{}},\"finish_reason\":\"tool_calls\"}}]}}\n\n",
            "data: [DONE]\n\n"),
            json!(first), json!(second));
        let (result, events) = decision_fixture(&body);
        assert_eq!(result["tool_calls"][0]["function"]["arguments"].as_str().unwrap(),
            format!("{{\"a\":\"{filler}\"}}"));
        let seen = decisions(&events);
        assert_eq!(seen.len(), 2, "forming then complete: {events}");
        let bounded = format!("{{\"a\":\"{}", "X".repeat(250));
        for (index, event) in seen.iter().enumerate() {
            assert_eq!(event["arguments_text"], format!("{bounded}{TRUNCATION_NOTE}"),
                "event {index} must be the capped preview plus the marker");
            assert_eq!(event["arguments_truncated"], true, "event {index} must say it truncated");
        }
    }

    #[test]
    fn interrupted_stream_leaves_the_decision_forming() {
        // Arguments are still partial at EOF with no finish reason: completing them would claim
        // an execution the tool loop refuses.
        let (result, events) = decision_fixture(
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_cut\",\"function\":{\"name\":\"f\",\"arguments\":\"{\\\"p\\\":1\"}}]}}]}\n\n");
        assert_eq!(result["stream_complete"], false);
        let seen = decisions(&events);
        assert_eq!(seen.len(), 1, "only the forming announcement: {events}");
        assert_eq!(seen[0]["complete"], false);
        assert_eq!(seen[0]["call_id"], "call_cut");
    }

    #[test]
    fn two_calls_in_one_message_complete_in_index_order() {
        let (_, events) = decision_fixture(concat!(
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c0\",\"function\":{\"name\":\"a\",\"arguments\":\"{\\\"x\\\":1}\"}},{\"index\":1,\"id\":\"c1\",\"function\":{\"name\":\"b\",\"arguments\":\"{\\\"y\\\":2}\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
            "data: [DONE]\n\n"));
        let seen = decisions(&events);
        let ids: Vec<&str> = seen.iter().map(|event| event["call_id"].as_str().unwrap()).collect();
        assert_eq!(ids, vec!["c0", "c1", "c0", "c1"]);
        assert_eq!(seen[0]["complete"], false);
        assert_eq!(seen[1]["complete"], false);
        assert_eq!(seen[2]["complete"], true);
        assert_eq!(seen[3]["complete"], true);
        assert_eq!(seen[2]["arguments_text"], "{\"x\":1}");
        assert_eq!(seen[3]["arguments_text"], "{\"y\":2}");
    }

    #[test]
    fn interleaved_deltas_publish_one_forming_event_per_call() {
        let (_, events) = decision_fixture(concat!(
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c0\",\"function\":{\"name\":\"a\",\"arguments\":\"{\\\"x\\\"\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"c1\",\"function\":{\"name\":\"b\",\"arguments\":\"{\\\"y\\\"\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\":1}\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"arguments\":\":2}\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
            "data: [DONE]\n\n"));
        let seen = decisions(&events);
        let forming: Vec<&str> = seen.iter().filter(|event| event["complete"] == false)
            .map(|event| event["call_id"].as_str().unwrap()).collect();
        assert_eq!(forming, vec!["c0", "c1"], "exactly one forming event per call: {events}");
        let completed: Vec<&str> = seen.iter().filter(|event| event["complete"] == true)
            .map(|event| event["call_id"].as_str().unwrap()).collect();
        assert_eq!(completed, vec!["c0", "c1"]);
        let final_text: Vec<&Value> = seen.iter().filter(|event| event["complete"] == true)
            .map(|event| &event["arguments_text"]).collect();
        assert_eq!(final_text, vec![&json!("{\"x\":1}"), &json!("{\"y\":2}")]);
    }

    #[test]
    fn a_late_id_reidentifies_the_row_instead_of_leaving_a_second_one() {
        // The window keys its decision row by call id, and the `tool` event promotes that same key.
        // An id that arrives a chunk late must move the row, or the first one is stranded.
        let (_, events) = decision_fixture(concat!(
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_late\",\"function\":{\"arguments\":\"\\\"k\\\":1}\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
            "data: [DONE]\n\n"));
        let seen = decisions(&events);
        assert_eq!(seen.len(), 3, "forming, re-identified, complete: {events}");
        assert_eq!(seen[0]["call_id"], "openai-0", "the placeholder key is never empty");
        assert_eq!(seen[1]["call_id"], "call_late");
        assert_eq!(seen[1]["previous_call_id"], "openai-0");
        assert_eq!(seen[1]["complete"], false);
        assert_eq!(seen[2]["call_id"], "call_late");
        assert_eq!(seen[2]["complete"], true);
        assert!(seen[2].get("previous_call_id").is_none(),
            "the final id is the same one already published");
    }

    /// The parity fixture: one tool call, written once in the ordinary dialect's SSE chunks and
    /// once as subscription events, with the reader-visible sequence both must produce. This test
    /// runs the ordinary side; `scripts/test-decision-parity.lua` runs the subscription side
    /// against the same file, so a change to either path that breaks the shared meaning fails one
    /// of them rather than passing each on its own prose.
    #[test]
    fn ordinary_stream_matches_the_shared_decision_parity_fixture() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/decision-events/parity.json");
        let fixture: Value = serde_json::from_str(&std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("decision parity fixture {} is unreadable: {error}", path.display())))
            .expect("decision parity fixture must be JSON");
        // The cap and the marker are pinned here as well as in the Lua half, so the two constants
        // cannot drift apart while both suites stay green.
        assert_eq!(fixture["bounded_preview_chars"].as_u64(), Some(DECISION_PREVIEW_CHARS as u64));
        assert_eq!(fixture["truncation_marker"].as_str(), Some(DECISION_TRUNCATION_NOTE));
        let body: String = fixture["ordinary_sse"].as_array().unwrap().iter()
            .map(|line| line.as_str().unwrap().to_string()).collect();
        let (_, events) = decision_fixture(&body);
        let produced: Vec<Value> = decisions(&events).iter().map(semantics).collect();
        let expected: Vec<Value> = fixture["expected_reader_semantics"].as_array().unwrap()
            .iter().map(semantics).collect();
        assert_eq!(produced, expected, "ordinary path reader-visible decisions drifted: {events}");
        assert!(decisions(&events).iter().all(|event| event["call_id"].as_str().is_some_and(|id| !id.is_empty())));
    }
}

#[cfg(test)]
mod stream_tests {
    use super::*;
    use std::io::{Read, Write};

    fn fixture_with_events(body: &str) -> (Value, String) {
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
        let result = std::cell::RefCell::new(Value::Null);
        let events = crate::serve::capture_events(|| {
            *result.borrow_mut() = stream_completion("POST", &format!("http://{address}/fixture"), &[], "{}", 0).unwrap();
        });
        server.join().unwrap();
        (result.into_inner(), events)
    }

    fn fixture(body: &str) -> Value {
        fixture_with_events(body).0
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
        // Observe the fixture's own sink: an outer sink cannot see events captured by it.
        let (result, events) = fixture_with_events(concat!(
                "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}\n\n",
                "data: {\"choices\":[{\"delta\":{\"content\":\"answer\"},\"finish_reason\":\"stop\"}]}\n\n",
                "data: [DONE]\n\n"));
        assert_eq!(result["reasoning"], "thinking");
        assert!(events.contains("\"type\":\"reasoning\""), "no reasoning event in: {events}");
        assert!(events.contains("\"text\":\"thinking\""), "the event must carry the delta: {events}");
        assert!(events.contains("\"chars\":8"), "the event must still carry the count: {events}");
    }

    #[test]
    fn commentary_deltas_stream_as_their_own_phase_without_a_duplicate_result_event() {
        let (result, events) = fixture_with_events(concat!(
            "data: {\"choices\":[{\"delta\":{\"phase\":\"commentary\",\"content\":\"Thinking \"}}]}\n\n",
            "data: {\"choices\":[{\"phase\":\"commentary\",\"delta\":{\"content\":\"through it.\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"phase\":\"final_answer\",\"content\":\"The answer.\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n"));
        let parsed: Vec<Value> = events.lines().filter_map(|line| line.strip_prefix("data: "))
            .map(|line| serde_json::from_str(line).unwrap()).collect();
        let commentary: Vec<&str> = parsed.iter().filter(|event| event["type"] == "commentary_delta")
            .map(|event| event["text"].as_str().unwrap()).collect();
        assert_eq!(commentary.concat(), "Thinking through it.");
        assert_eq!(result["commentary"], "Thinking through it.");
        assert_eq!(result["content"], "The answer.");
        assert_eq!(result["final_phase"], "final_answer");
        assert_eq!(parsed.iter().filter(|event| event["type"] == "commentary_delta").count(), 2);
        assert_eq!(parsed.iter().filter(|event| event["type"] == "commentary").count(), 0,
            "the host streams chunks only; the agent closes the saved block by id");
        let answers: Vec<&str> = parsed.iter().filter(|event| event["type"] == "delta")
            .map(|event| event["text"].as_str().unwrap()).collect();
        assert_eq!(answers.concat(), "The answer.");
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

    /// A bounded host call must not look like a wedged node-thread.
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
        // Use the host's resolved shell. Bare `bash` may resolve to the Windows WSL shim,
        // while production uses Git Bash's native absolute executable when available.
        let (program, flag) = shell_config();
        let command = if cfg!(windows) && flag == "/C" {
            "ping -n 7 127.0.0.1 >NUL && echo heartbeat-done"
        } else {
            "sleep 6; printf 'heartbeat-done\\n'"
        };
        let result = run_bounded(program, flag, command, "", None);
        let elapsed = started.elapsed();
        let worst = sampler.join().unwrap();
        assert!(result.is_ok(), "the command should run: {result:?}");
        let output = result.unwrap();
        assert_eq!(output["process_exit_code"], 0, "the resolved shell must actually succeed: {output}");
        assert_eq!(output["settled"], true, "the measured command must settle: {output}");
        assert_eq!(output["stdout"].as_str().unwrap_or("").trim(), "heartbeat-done", "the command must reach its final marker: {output}");
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

    #[test]
    fn shell_child_carries_the_provenance_the_host_knows() {
        // The commit guard decides by role (`.githooks/pre-commit`, after a child could reach `main`
        // by exporting `WASM_AGENT_ALLOW_MAIN=1`), so the role has to reach the shell the agent runs
        // git in. Measured, not read off the code: what the child process actually receives, for a
        // session's own run, for a subagent task, and for a thread that is neither.
        let (program, flag) = shell_config();
        let see = |provenance: Option<crate::subagents::Provenance>| {
            match provenance {
                Some(provenance) => crate::subagents::enter_task(crate::subagents::TaskContext {
                    cancel: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
                    deadline: None,
                    sockets: std::sync::Arc::new(std::sync::Mutex::new(Vec::new())),
                    owner: "run:provenance-test".into(),
                    provenance,
                }),
                None => crate::subagents::leave_task(),
            }
            let result = run_bounded(program, flag, "env | grep '^WASM_AGENT_PROVENANCE='", "", None);
            crate::subagents::leave_task();
            let output = result.expect("shell child should run");
            output["stdout"].as_str().unwrap_or_default().to_string()
        };
        use crate::subagents::Provenance;
        assert_eq!(
            see(Some(Provenance::Orchestrator)),
            "WASM_AGENT_PROVENANCE=orchestrator\n",
            "a run of a session must reach the shell as `orchestrator`, which is what the guard allows \
             to commit on main"
        );
        assert_eq!(
            see(Some(Provenance::Child)),
            "WASM_AGENT_PROVENANCE=child\n",
            "a bounded child task must reach the shell as `child`, which the guard refuses even when it \
             exports WASM_AGENT_ALLOW_MAIN"
        );
        // A thread with no task context must be told too, with an explicit empty value: the marker is
        // inherited (`wa-operation` adds env without `env_clear`), so if this case pushed nothing, a
        // shell started by a host that had inherited `orchestrator` would hand that authority on and
        // the guard would read it as a run of a session. Empty is the human path in the hook.
        assert_eq!(
            see(None),
            "WASM_AGENT_PROVENANCE=\n",
            "a thread with no task context must get an empty marker, not silence from the environment"
        );
    }
}

#[cfg(test)]
mod retry_after_tests {
    use super::retry_after_ms;

    #[test]
    fn reads_the_providers_own_backoff_instruction() {
        let mut headers = ureq::http::HeaderMap::new();
        assert_eq!(retry_after_ms(&headers), None, "a provider that says nothing has no hint");
        headers.insert("retry-after", "3".parse().unwrap());
        assert_eq!(retry_after_ms(&headers), Some(3000), "seconds become milliseconds");
        headers.insert("retry-after-ms", "250".parse().unwrap());
        assert_eq!(retry_after_ms(&headers), Some(250), "the millisecond form wins");
        headers.insert("retry-after", "Wed, 21 Oct 2015 07:28:00 GMT".parse().unwrap());
        headers.remove("retry-after-ms");
        assert_eq!(retry_after_ms(&headers), None, "an HTTP-date is ignored, not guessed");
    }
}

/// `host.read_file` answers a *named* reason, not a bare nil (measured 10/11: an 8 MB file answered
/// nil, so "too large", "missing", "binary" and "the OS refused" were indistinguishable, and the
/// size cap itself was never named). These pin each name and the numbers it carries.
#[cfg(test)]
mod read_file_answers {
    use super::*;

    fn scratch() -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!("wa-read-file-{}", crate::host::new_uuid()));
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn a_missing_file_is_named() {
        let root = scratch();
        let missing = root.join("absent.txt");
        let why = read_text_file(missing.to_str().unwrap(), 1024).unwrap_err();
        assert!(why.starts_with("read_file_missing:"), "{why}");
        assert!(why.contains("absent.txt"), "the name carries the path: {why}");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_directory_is_named_not_reported_as_missing() {
        let root = scratch();
        let why = read_text_file(root.to_str().unwrap(), 1024).unwrap_err();
        assert!(why.starts_with("read_file_is_a_directory:"), "{why}");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_file_over_the_limit_is_named_with_both_numbers() {
        let root = scratch();
        let path = root.join("big.txt");
        std::fs::write(&path, "0123456789").unwrap();
        let why = read_text_file(path.to_str().unwrap(), 4).unwrap_err();
        assert_eq!(why, "read_file_too_large:10>4");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_file_that_is_not_text_is_named_with_its_size() {
        let root = scratch();
        let path = root.join("binary.dat");
        std::fs::write(&path, [0xffu8, 0xfe, 0x00, 0x01]).unwrap();
        let why = read_text_file(path.to_str().unwrap(), 1024).unwrap_err();
        assert_eq!(why, "read_file_not_text:4 bytes");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn text_within_the_limit_is_returned_unchanged() {
        let root = scratch();
        let path = root.join("ok.txt");
        std::fs::write(&path, "hello\nwörld\n").unwrap();
        assert_eq!(read_text_file(path.to_str().unwrap(), 1024).unwrap(), "hello\nwörld\n");
        // Exactly at the limit is allowed: the limit is a ceiling, not a margin. (The text is 13
        // bytes: `ö` is two of them, which is why the limit is a byte count and the reason says so.)
        assert_eq!(read_text_file(path.to_str().unwrap(), 13).unwrap(), "hello\nwörld\n");
        assert_eq!(read_text_file(path.to_str().unwrap(), 12).unwrap_err(), "read_file_too_large:13>12");
        std::fs::remove_dir_all(root).unwrap();
    }
}

/// How a streamed tool call is assembled, tested against the bytes the endpoint actually sent.
///
/// Two of these fixtures are recorded from opencode-go/DeepSeek on 14/11 (the node's own model,
/// `deepseek-v4.1-flash`): one two-call turn, and the fourteen-tool request of the "send a beautiful
/// message to Laura" session whose calls arrived nameless. The other three are the same wire shape
/// written out for the endings that turn was not recorded with - a name split across deltas, a later
/// delta repeating the name as an empty string, and parallel calls keyed by `id` alone.
#[cfg(test)]
mod tool_call_assembly_tests {
    use super::*;

    fn recorded(name: &str) -> String {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/provider")
            .join(name);
        std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("recorded fixture {} is unreadable: {error}", path.display()))
    }

    /// Feed one stream through the assembly the way `stream_completion` does: every chunk's tool
    /// calls, in order, and nothing invented in between.
    fn assemble(body: &str) -> Vec<Value> {
        let mut assembly = ToolCallAssembly::new();
        for line in body.lines() {
            let Some(data) = line.trim().strip_prefix("data:") else { continue };
            let data = data.trim();
            if data.is_empty() || data == "[DONE]" { continue }
            let chunk: Value = serde_json::from_str(data)
                .unwrap_or_else(|error| panic!("a recorded chunk is JSON: {error}"));
            if let Some(calls) = chunk["choices"][0]["delta"]["tool_calls"].as_array() {
                for call in calls { assembly.absorb(call); }
            }
        }
        assembly.calls
    }

    fn names(calls: &[Value]) -> Vec<String> {
        calls.iter().map(|call| call["function"]["name"].as_str().unwrap_or("").to_string()).collect()
    }

    fn arguments(calls: &[Value]) -> Vec<String> {
        calls.iter().map(|call| call["function"]["arguments"].as_str().unwrap_or("").to_string()).collect()
    }

    #[test]
    fn the_recorded_two_call_turn_keeps_both_names_and_ids() {
        let calls = assemble(&recorded("opencode-go-parallel-two-calls.sse"));
        assert_eq!(names(&calls), vec!["bash".to_string(), "read".to_string()]);
        assert_eq!(calls[0]["id"], json!("call_6de8d3baf10f444aa7090556"));
        assert_eq!(calls[1]["id"], json!("call_8ec90b68a4744759a68bf395"));
        assert_eq!(arguments(&calls),
            vec!["{\"command\":\"echo ok\"}".to_string(), "{\"path\":\"/etc/hostname\"}".to_string()]);
    }

    /// The session whose calls reached the tool loop nameless: its own wire names both calls.
    #[test]
    fn the_recorded_fourteen_tool_turn_keeps_its_names() {
        let calls = assemble(&recorded("opencode-go-fourteen-tools-laura.sse"));
        assert_eq!(names(&calls), vec!["recall".to_string(), "tool_search".to_string()]);
        assert_eq!(arguments(&calls),
            vec!["{\"query\":\"Laura\"}".to_string(), "{\"query\":\"send message contact\"}".to_string()]);
    }

    #[test]
    fn a_name_split_across_deltas_is_assembled_not_replaced() {
        let calls = assemble(&recorded("name-split-across-deltas.sse"));
        assert_eq!(names(&calls), vec!["codemode".to_string()]);
        assert_eq!(arguments(&calls), vec!["{\"code\":\"return 1\"}".to_string()]);
    }

    /// The loss this file was fixed for: a later delta repeating the field as "" used to overwrite
    /// the name the first delta delivered.
    #[test]
    fn a_later_delta_repeating_an_empty_name_does_not_clear_it() {
        let calls = assemble(&recorded("name-empty-in-later-deltas.sse"));
        assert_eq!(names(&calls), vec!["codemode".to_string()]);
        assert_eq!(arguments(&calls), vec!["{\"code\":\"return 1\"}".to_string()]);
        assert_eq!(calls[0]["id"], json!("call_empty_0001"));
    }

    #[test]
    fn parallel_calls_keyed_only_by_id_stay_separate_calls() {
        let calls = assemble(&recorded("two-calls-keyed-by-id-only.sse"));
        assert_eq!(names(&calls), vec!["bash".to_string(), "read".to_string()]);
        assert_eq!(arguments(&calls),
            vec!["{\"command\":\"echo ok\"}".to_string(), "{\"path\":\"/etc/hostname\"}".to_string()]);
        assert_eq!(calls[0]["id"], json!("call_idkey_a"));
        assert_eq!(calls[1]["id"], json!("call_idkey_b"));
    }

    /// 18/11 round 2, finding 5: only a RecvResponse timeout is a stall.
    #[test]
    fn only_a_response_header_timeout_is_a_stall() {
        let stall = ureq::Error::Timeout(ureq::Timeout::RecvResponse);
        assert_eq!(stall_marker(&stall, 90).as_deref(),
            Some(" (provider_stalled: no response within 90s)"),
            "no response headers before the deadline is the one stall, and it is safe to replay");
        // Every other transport failure keeps its own name and is never replayed as a stall.
        let others = [
            ureq::Error::Timeout(ureq::Timeout::Connect),
            ureq::Error::Timeout(ureq::Timeout::SendRequest),
            ureq::Error::Timeout(ureq::Timeout::RecvBody),
            ureq::Error::Timeout(ureq::Timeout::Global),
            ureq::Error::HostNotFound,
            ureq::Error::ConnectionFailed,
            ureq::Error::Io(std::io::Error::new(std::io::ErrorKind::ConnectionReset, "connection reset")),
        ];
        for error in others {
            assert_eq!(stall_marker(&error, 90), None, "not a stall: {error}");
        }
        // The operator's off switch (0 = no per-call deadline) marks nothing at all.
        assert_eq!(stall_marker(&stall, 0), None, "no deadline, no stall");
    }

    #[test]
    fn a_name_that_arrived_is_never_lost_whatever_the_later_deltas_say() {
        assert_eq!(merge_name("", "bash"), "bash");
        assert_eq!(merge_name("bash", ""), "bash");
        assert_eq!(merge_name("bash", "bash"), "bash", "a repeated name is not doubled");
        assert_eq!(merge_name("ba", "sh"), "bash", "a split name grows");
        assert_eq!(merge_name("bash", "sh"), "bash", "an overlapping repeat does not double the tail");
        assert_eq!(merge_name("ba", "bash"), "bash", "a later delta carrying the whole name wins");
        assert_eq!(merge_name("bash", "ba"), "bash", "a repeat from the start changes nothing");
        assert_eq!(merge_name("bash", "rea"), "bashrea", "a different fragment is kept, not dropped");
        assert_eq!(merge_name("bash", "tool"), "bashtool", "an unexpected fragment is kept, not dropped");
    }
}

#[cfg(test)]
mod image_and_token_tests {
    use super::*;

    /// A tiny but real PNG header: the bytes a sniff reads, not a whole image.
    const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR";
    const JPEG: &[u8] = &[0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10];
    const GIF: &[u8] = b"GIF89a\x01\x00\x01\x00";
    const WEBP: &[u8] = b"RIFF\x24\x00\x00\x00WEBPVP8 ";

    #[test]
    fn the_bytes_decide_the_type_and_a_name_does_not() {
        assert_eq!(sniff_image(PNG), Some("image/png"));
        assert_eq!(sniff_image(JPEG), Some("image/jpeg"));
        assert_eq!(sniff_image(GIF), Some("image/gif"));
        assert_eq!(sniff_image(WEBP), Some("image/webp"));
        assert_eq!(sniff_image(b"#!/bin/sh\necho not an image\n"), None);
        assert_eq!(sniff_image(b"RIFF"), None, "a truncated RIFF is not a WebP");
        assert_eq!(sniff_image(b""), None);
    }

    /// A directory this test owns, used as the ONLY allowed root: the real list is the node's own, and a
    /// test that wrote into it would be a test that polluted the machine it ran on.
    fn scratch_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("wa-attach-{}-{tag}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }
    fn scratch(dir: &std::path::Path, name: &str, bytes: &[u8]) -> std::path::PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, bytes).expect("scratch file");
        path
    }
    fn allowed(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
        vec![std::fs::canonicalize(dir).expect("a real directory")]
    }

    #[test]
    fn a_dropped_path_is_read_when_it_is_an_image_in_an_allowed_directory() {
        let dir = scratch_dir("read");
        let path = scratch(&dir, "shot.png", PNG);
        let roots = allowed(&dir);
        let (mime, bytes) = dropped_image_in(&path.to_string_lossy(), &roots).expect("an attached image");
        assert_eq!(mime, "image/png");
        assert_eq!(bytes, PNG);
        let quoted = format!("'{}'", path.to_string_lossy());
        assert!(dropped_image_in(&quoted, &roots).is_some(), "a shell-quoted path is the same path");
        let uri = format!("file://{}", path.to_string_lossy());
        assert!(dropped_image_in(&uri, &roots).is_some(), "so is a file:// URI");
    }

    #[test]
    fn a_file_whose_bytes_are_not_an_image_is_refused_whatever_it_is_called() {
        let dir = scratch_dir("lie");
        let path = scratch(&dir, "lie.png", b"#!/bin/sh\nrm -rf /\n");
        assert!(dropped_image_in(&path.to_string_lossy(), &allowed(&dir)).is_none(),
            "the extension is not evidence");
    }

    #[test]
    fn an_empty_or_absent_path_is_refused() {
        let roots: Vec<std::path::PathBuf> = Vec::new();
        assert!(dropped_image_in("", &roots).is_none());
        assert!(dropped_image_in("two\nlines", &roots).is_none());
        assert!(dropped_image_in("/nonexistent/wasm-agent/shot.png", &roots).is_none());
    }

    // The review's LOW (18/11): the roots were all of HOME plus the machine's temp dir, so a dropped
    // path was a way to read any of them into a message. They are now the session's folders and one
    // explicit, configurable drop directory.
    // Round 5's LOW: when the process's directory IS the user's home, the cwd root handed all of HOME
    // back - the same list, under another name.
    #[test]
    fn a_session_started_in_home_does_not_get_home_back_through_its_own_directory() {
        let home = scratch_dir("home");
        let canonical = std::fs::canonicalize(&home).unwrap_or(home.clone());
        let roots = super::image_roots_in(Some(home.clone()), home.clone());
        assert!(!roots.iter().any(|root| root == &canonical), "HOME is not an image root: {roots:?}");
        assert_eq!(roots, super::image_roots_in(Some(home.clone()), home.clone()), "and it is stable");
        // A directory of the session's own is still allowed, which is what the root is for.
        let work = scratch_dir("work");
        let work_roots = super::image_roots_in(Some(work.clone()), home.clone());
        let work = std::fs::canonicalize(&work).unwrap_or(work);
        assert!(work_roots.iter().any(|root| root == &work), "the session's own folder: {work_roots:?}");
    }

    #[test]
    fn the_allowed_directories_are_the_sessions_folders_and_one_drop_dir() {
        let canonical = |path: std::path::PathBuf| std::fs::canonicalize(&path).unwrap_or(path);
        let roots = image_roots();
        let cwd = canonical(std::env::current_dir().expect("a working directory"));
        let state = canonical(wa_host_support::paths::state_root());
        let home = canonical(std::path::PathBuf::from(wa_host_support::paths::resolve_home()));
        let temp = canonical(std::env::temp_dir());
        assert!(roots.iter().any(|root| root == &cwd), "the session's own folder is allowed: {roots:?}");
        assert!(roots.iter().any(|root| root == &state), "the node's state root is allowed: {roots:?}");
        assert!(roots.iter().any(|root| root == &canonical(image_drop_dir())), "the drop dir is allowed");
        assert!(!roots.iter().any(|root| root == &home) || home == cwd || home == state,
            "all of HOME is not an image root any more: {roots:?}");
        assert!(!roots.iter().any(|root| root == &temp) || temp == cwd || temp.starts_with(&state),
            "nor is the machine's temp directory: {roots:?}");
    }

    #[test]
    fn the_drop_directory_is_configurable_and_defaults_under_the_state_root() {
        assert_eq!(image_drop_dir_with(Some("/srv/wa-drop")), std::path::PathBuf::from("/srv/wa-drop"));
        assert_eq!(image_drop_dir_with(Some("   ")), wa_host_support::paths::state_root().join("attachments"),
            "a blank setting is no setting");
        assert_eq!(image_drop_dir_with(None), wa_host_support::paths::state_root().join("attachments"));
        // Whatever it is configured to, it is an allowed root on its own: that is what it is for.
        let dir = scratch_dir("drop");
        let path = scratch(&dir, "dropped.png", PNG);
        assert!(dropped_image_in(&path.to_string_lossy(), &allowed(&dir)).is_some());
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_that_lands_outside_the_allowed_directories_is_refused() {
        let dir = scratch_dir("link");
        let secret = scratch(&dir, "outside.png", PNG);
        let roots = allowed(&dir);
        let link = dir.join("link.png");
        std::os::unix::fs::symlink("/etc/hostname", &link).expect("symlink");
        assert!(dropped_image_in(&link.to_string_lossy(), &roots).is_none(),
            "a link out of the allowed directories is refused by where it lands");
        std::fs::remove_file(&link).expect("remove the link");
        std::os::unix::fs::symlink(&secret, &link).expect("symlink");
        assert!(dropped_image_in(&link.to_string_lossy(), &roots).is_some(),
            "a link that lands inside them is the image it points at");
        let _ = std::fs::remove_file(&link);
    }

    #[test]
    fn the_clipboard_reader_says_why_it_cannot_read_instead_of_pretending() {
        let off = ClipboardHost { off: true, wayland: true, x11: true };
        assert_eq!(read_clipboard_image_with(off, |_, _| Some(PNG.to_vec())).unwrap_err(),
            "clipboard reading is off here (WA_CLIPBOARD=off)");
        let none = ClipboardHost::default();
        assert!(read_clipboard_image_with(none, |_, _| Some(PNG.to_vec())).unwrap_err()
            .contains("no clipboard here"));
        let wayland = ClipboardHost { off: false, wayland: true, x11: false };
        let (mime, bytes) = read_clipboard_image_with(wayland, |program, args| {
            assert_eq!(program, "wl-paste");
            if args.contains(&"--list-types") { Some(b"text/plain\nimage/png\n".to_vec()) } else { Some(PNG.to_vec()) }
        }).expect("a clipboard image");
        assert_eq!(mime, "image/png");
        assert_eq!(bytes, PNG);
    }

    #[test]
    fn a_clipboard_that_announces_an_image_it_does_not_hold_is_refused() {
        let wayland = ClipboardHost { off: false, wayland: true, x11: false };
        let refused = read_clipboard_image_with(wayland, |_, args| {
            if args.contains(&"--list-types") { Some(b"image/png\n".to_vec()) } else { Some(b"not an image".to_vec()) }
        });
        assert!(refused.unwrap_err().contains("not a PNG, JPEG, WebP or GIF"));
    }

    #[test]
    fn a_clipboard_type_the_node_does_not_understand_is_not_read() {
        assert_eq!(pick_clipboard_type(b"text/html\nimage/svg+xml\n"), None);
        assert_eq!(pick_clipboard_type(b"image/svg+xml\nimage/gif\n"), Some("image/gif"));
    }

    #[test]
    fn only_the_tokens_this_draft_inserted_survive_into_the_message() {
        // Two images pasted, the first deleted from the draft, a third token typed by hand.
        assert_eq!(submitted_tokens(&[1, 2], "look [Image #2] and [Image #3]"), vec![2]);
        assert_eq!(submitted_tokens(&[], "typed [Image #1] by hand"), Vec::<usize>::new());
        assert_eq!(submitted_tokens(&[1], "[Image #1]"), vec![1]);
        assert_eq!(submitted_tokens(&[1], "[Image #10] is not [Image #1]"), vec![1]);
    }

    #[test]
    fn the_attachment_mints_one_token_number_and_records_it_for_this_draft() {
        let mut state = ConsoleInput::default();
        let (token, kb) = attach_image(&mut state, "image/png", vec![0u8; 4096]);
        assert_eq!(token, "[Image #1]");
        assert_eq!(kb, 4);
        let (token, _) = attach_image(&mut state, "image/gif", GIF.to_vec());
        assert_eq!(token, "[Image #2]");
        assert_eq!(state.draft_images, vec![1, 2]);
        assert_eq!(state.pasted_images.len(), 2);
        assert_eq!(state.pasted_images[1].0, "image/gif");
    }
}

/// Round 8: the allow-list is decided by these bytes, so the four-byte classifier is the foundation it
/// stands on - a copy of python called "node" is refused because THIS says "elf" about the real node and
/// "script" about the shell wrapper. It had no unit test of its own (found 18/11).
#[cfg(test)]
mod classify_magic_tests {
    use super::{classify_magic, classify_magic_on, file_magic_value, HostFormat};

    /// A PE stub whose e_lfanew points at a real "PE\0\0" header.
    fn pe() -> Vec<u8> {
        let offset = 0x80usize;
        let mut bytes = vec![0u8; offset + 4];
        bytes[..2].copy_from_slice(b"MZ");
        bytes[0x3c..0x40].copy_from_slice(&(offset as u32).to_le_bytes());
        bytes[offset..offset + 4].copy_from_slice(b"PE\0\0");
        bytes
    }

    /// A universal (fat) Mach-O header naming `count` architectures.
    fn fat(magic: [u8; 4], count: u32) -> Vec<u8> {
        let mut bytes = vec![0u8; 8 + 20 * count as usize];
        bytes[..4].copy_from_slice(&magic);
        if magic == [0xbe, 0xba, 0xfe, 0xca] {
            bytes[4..8].copy_from_slice(&count.to_le_bytes());
        } else {
            bytes[4..8].copy_from_slice(&count.to_be_bytes());
        }
        bytes
    }

    /// Item 2 of round 9: a native binary is THIS HOST's executable format and nothing else. The same
    /// leading bytes are a native binary on one platform and a foreign file on another, and the allow-list
    /// admits only what this node can run.
    #[test]
    fn only_the_hosts_own_executable_format_is_native() {
        let elf = b"\x7fELF\x02\x01\x01\x00".to_vec();
        let macho = vec![0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01];
        let win = pe();
        for (bytes, name) in [(&elf, "elf"), (&macho, "macho"), (&win, "pe")] {
            for host in [HostFormat::Elf, HostFormat::MachO, HostFormat::Pe] {
                let expected = match host {
                    HostFormat::Elf if name == "elf" => "elf",
                    HostFormat::MachO if name == "macho" => "macho",
                    HostFormat::Pe if name == "pe" => "pe",
                    _ => "foreign",
                };
                assert_eq!(classify_magic_on(bytes, host), expected, "{name} on {host:?}");
            }
            // A host this build was not written for has no native format at all: unknown is not yes.
            assert_eq!(classify_magic_on(bytes, HostFormat::Unknown), "foreign", "{name} elsewhere");
        }
        // And the plain entry point answers for THIS host, so a Linux node running the suite sees its own.
        assert_eq!(classify_magic(&elf), "elf");
        assert_eq!(classify_magic(&macho), "foreign");
    }

    /// Item 2: "MZ" alone is not a PE. The COFF header lives at e_lfanew and begins with "PE\0\0"; a DOS
    /// stub, a decoy, or a pointer past the head is a binary, never a native binary.
    #[test]
    fn a_dos_stub_without_a_pe_header_is_not_a_native_binary() {
        let real = pe();
        assert_eq!(classify_magic_on(&real, HostFormat::Pe), "pe");
        // Just "MZ": no room for e_lfanew at all.
        assert_eq!(classify_magic_on(b"MZ\x90\x00", HostFormat::Pe), "binary");
        // "MZ" and a zero e_lfanew: the header would sit inside the DOS header itself.
        let mut zero = vec![0u8; 0x80];
        zero[..2].copy_from_slice(b"MZ");
        assert_eq!(classify_magic_on(&zero, HostFormat::Pe), "binary");
        // e_lfanew that points at something other than "PE\0\0", and one that points past the head.
        let mut stub = real.clone();
        stub[0x80..0x84].copy_from_slice(b"NE\0\0");
        assert_eq!(classify_magic_on(&stub, HostFormat::Pe), "binary");
        let mut past = real.clone();
        past[0x3c..0x40].copy_from_slice(&(0xffff_ffffu32).to_le_bytes());
        assert_eq!(classify_magic_on(&past, HostFormat::Pe), "binary");
    }

    /// Item 2: 0xcafebabe is the universal Mach-O header AND the Java class magic. The architecture count
    /// tells them apart: a Java class has a major version (>= 45), never one architecture.
    #[test]
    fn a_java_class_is_not_a_universal_macho() {
        // A real Java class header: cafebabe, minor 0, major 52 (Java 8).
        let class = vec![0xca, 0xfe, 0xba, 0xbe, 0x00, 0x00, 0x00, 0x34];
        assert_eq!(classify_magic_on(&class, HostFormat::MachO), "binary");
        assert_eq!(classify_magic_on(&class, HostFormat::Elf), "binary");
        // A universal binary naming two architectures is one - on macOS.
        let universal = fat([0xca, 0xfe, 0xba, 0xbe], 2);
        assert_eq!(classify_magic_on(&universal, HostFormat::MachO), "macho");
        assert_eq!(classify_magic_on(&universal, HostFormat::Elf), "foreign");
        // Its byte-swapped twin too, and a count of zero or too many is neither.
        assert_eq!(classify_magic_on(&fat([0xbe, 0xba, 0xfe, 0xca], 1), HostFormat::MachO), "macho");
        assert_eq!(classify_magic_on(&fat([0xca, 0xfe, 0xba, 0xbe], 0), HostFormat::MachO), "binary");
        assert_eq!(classify_magic_on(&fat([0xca, 0xfe, 0xba, 0xbe], 16), HostFormat::MachO), "binary");
        // A count whose architecture table is not present is not a universal binary either.
        let mut truncated = fat([0xca, 0xfe, 0xba, 0xbe], 2);
        truncated.truncate(8);
        assert_eq!(classify_magic_on(&truncated, HostFormat::MachO), "binary");
    }

    /// A scratch directory of this test's own: the Rust suite runs in parallel and a shared path would let
    /// one test's fixture answer another's question.
    fn scratch(name: &str, body: &[u8]) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("wa-file-magic-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        let path = dir.join(name);
        std::fs::write(&path, body).expect("a fixture");
        path
    }

    #[test]
    fn the_three_executable_families_are_read_from_their_own_bytes() {
        // Each family is asserted ON ITS OWN HOST, because a format is native only there (round 9).
        assert_eq!(classify_magic_on(b"\x7fELF\x02\x01\x01\x00", HostFormat::Elf), "elf");
        // Mach-O: its 32/64-bit headers in both byte orders, and the universal header with a real table.
        for header in [[0xfeu8, 0xed, 0xfa, 0xce], [0xfe, 0xed, 0xfa, 0xcf], [0xce, 0xfa, 0xed, 0xfe],
                       [0xcf, 0xfa, 0xed, 0xfe]] {
            assert_eq!(classify_magic_on(&header, HostFormat::MachO), "macho", "{header:?}");
        }
        for magic in [[0xcau8, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca]] {
            assert_eq!(classify_magic_on(&fat(magic, 1), HostFormat::MachO), "macho", "{magic:?}");
        }
        assert_eq!(classify_magic_on(&pe(), HostFormat::Pe), "pe");
    }

    #[test]
    fn a_shebang_is_the_shape_this_exists_to_catch() {
        // A file NAMED node that is really a shell script running something else.
        assert_eq!(classify_magic(b"#!/bin/sh\n"), "script");
        assert_eq!(classify_magic(b"#!/usr/bin/env python3\n"), "script");
        assert_eq!(classify_magic(b"export const run = 1;\n"), "text");
        // Not ASCII: not text, and not a family the allow-list admits.
        assert_eq!(classify_magic(&[0x00, 0xff, 0x10, 0x80]), "binary");
    }

    #[test]
    fn a_path_is_answered_by_what_is_there_now() {
        let elf = scratch("elf", b"\x7fELF\x02\x01\x01\x00");
        assert_eq!(file_magic_value(&elf.to_string_lossy())["magic"], classify_magic(b"\x7fELF\x02\x01\x01\x00"),
            "the path answer is this host's answer for its bytes");
        let script = scratch("node", b"#!/bin/sh\nexit 0\n");
        assert_eq!(file_magic_value(&script.to_string_lossy())["magic"], "script");
        let empty = scratch("empty", b"");
        assert_eq!(file_magic_value(&empty.to_string_lossy())["magic"], "empty");
        // A directory and a path that is not there are each named, never guessed as executable.
        let dir = elf.parent().expect("a parent");
        assert_eq!(file_magic_value(&dir.to_string_lossy())["magic"], "unreadable");
        assert_eq!(file_magic_value("/nonexistent/wa-file-magic/nope")["magic"], "missing");
    }
}

/// The provider path's anchors, measured at the handshake.
///
/// `host.http`, `host.http_sse` and the streaming completion all build their agent here
/// (`build_config_with` -> `agent_for_call`/`agent_for_stream`, and the same config through the
/// shutdown-aware transport in `http_transport`), so these tests drive those functions themselves
/// rather than restating their settings. The server is a real rustls handshake against a private CA
/// (`wa_tls::scratch`), which is the situation 19/11 hit: a sandbox whose CA is only in its own
/// bundle, and a provider call that cannot reach it.
#[cfg(test)]
mod tls_anchor_tests {
    use super::*;
    use wa_tls::scratch::{self, Env, Server};

    /// The two agents a provider call can get: the plain one and, for a child, the shutdown-aware
    /// transport. Both are built from the same config, and both must answer the same way.
    fn agents(url: &str) -> Vec<ureq::Agent> {
        vec![
            agent_for_stream(url, 5).expect("the anchors this environment names"),
            crate::http_transport::agent(build_config(url, 10).expect("the anchors this environment names")),
        ]
    }

    #[test]
    fn a_provider_call_refuses_a_private_ca_that_no_bundle_names() {
        let _env = Env::clear();
        let server = Server::start();
        for agent in agents(&server.url("/v1/messages")) {
            let error = agent
                .get(&server.url("/v1/messages"))
                .call()
                .expect_err("a private CA is not in the compiled-in bundle");
            // Measured on ureq 3.4: the refusal arrives as an io error of kind InvalidData carrying
            // rustls's InvalidCertificate(UnknownIssuer) - the certificate step, not a timeout.
            match &error {
                ureq::Error::Io(io) => assert!(
                    format!("{io:?}").contains("InvalidCertificate") || io.kind() == std::io::ErrorKind::InvalidData,
                    "the refusal must be the certificate step: {io:?}"
                ),
                other => panic!("a refused handshake is ureq's io error carrying the TLS refusal, got {other:?}"),
            }
        }
    }

    /// A broken bundle names a source wa cannot read, and a plain http:// request never consults one:
    /// it must still go through (review r1, item 7). Before this, the refusal happened when the agent
    /// was built, and took the loopback provider, the local relay and an http MCP server with it.
    #[test]
    fn a_broken_bundle_does_not_refuse_a_plain_http_request() {
        let _env = Env::set_text(wa_tls::CERT_FILE, "/nonexistent/wa-capabilities/typo.pem");
        let server = scratch::Server::start_plain();
        let mut response = agent_for_stream(&server.url("/v1/messages"), 5)
            .expect("a plain request needs no anchors")
            .get(&server.url("/v1/messages"))
            .call()
            .expect("the plain server answers");
        assert_eq!(response.status().as_u16(), 200);
        assert_eq!(response.body_mut().read_to_string().unwrap(), "ok");
    }

    #[test]
    fn a_provider_call_reaches_a_private_ca_named_by_ssl_cert_file() {
        let _env = Env::set(&[(wa_tls::CERT_FILE, &scratch::cert_file())]);
        let server = Server::start();
        for agent in agents(&server.url("/v1/messages")) {
            let mut response = agent
                .get(&server.url("/v1/messages"))
                .call()
                .unwrap_or_else(|error| panic!("the CA named by SSL_CERT_FILE should be trusted: {error}"));
            assert_eq!(response.status().as_u16(), 200);
            assert_eq!(response.body_mut().read_to_string().unwrap(), "ok");
        }
    }

    #[test]
    fn a_broken_bundle_refuses_the_call_with_the_bundle_in_the_message() {
        let _env = Env::set_text(wa_tls::CERT_FILE, "/nonexistent/wa-capabilities/typo.pem");
        let error = agent_for_stream("https://example.invalid/", 5)
            .expect_err("a named source that cannot be read is not a fall back");
        assert!(error.contains("SSL_CERT_FILE"), "{error}");
        assert!(error.contains("typo.pem"), "{error}");
        // The same refusal from the config every capability builds its agent from, not only from the
        // one function a test happened to call. agent() itself is deliberately not asserted on: it
        // remembers the one agent it built, so in a test process another test may have built it
        // already, and the anchors it was built with are the ones wa-tls gave at that moment.
        assert!(build_config("https://example.invalid/", 10).is_err());
        assert!(build_config_with("https://example.invalid/", 10, 5).is_err());
        assert!(agent_for_stream("https://example.invalid/", 5).is_err());
    }
}
