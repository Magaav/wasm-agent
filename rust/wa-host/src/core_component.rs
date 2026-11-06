//! `wa --core-component <agent-core.wasm> <script.lua> [args...]` — the Lua core running inside a
//! wasm component, with the full `host.*` surface (docs/KERNEL.md, "A2.1", "A2.2").
//!
//! The guest (rust/components/agent-core) is wa-host's own Lua 5.4 compiled to wasm32-wasip2. It
//! reaches the node through ONE import, `wa:kernel/host`. The kernel answers by calling the
//! capability's existing C function on a native Lua state booted exactly like every other
//! interpreter (`capabilities::register`, its own SQLite connection, the same `EMBEDDED`), so
//! nothing is reimplemented for the guest and the registry in `capabilities.rs` stays the one list.
//!
//! What crosses is a Lua scalar, a table (as JSON, [`push_arg`]) and — since A2.2 — a capability's
//! **stream form** ([`Session`]): `host.http_sse` needs a Lua callback the host cannot re-enter while
//! the guest is blocked in the call, so the kernel runs the unchanged native `http_sse` on a thread of
//! its own and hands the guest one line per `next`, waiting for what the guest decided about the line
//! before reading the next one. The guest's shim keeps the Lua-facing signature identical, so the
//! core's own code did not change.
//!
//! What still cannot cross is refused with `unsupported_in_component_v1:<name>` and, since A2.2, a
//! reason in parentheses: the interactive console *reader* ([`INPUT_REFUSED`]) — a `--core-component`
//! run has no CLI editor to read into — and a call whose argument is a function, or a table holding a
//! function, a non-string key, a non-finite number or a non-UTF-8 string (JSON cannot carry them).
//! The console's **output** capabilities (`ticker`, `panel`, `editor_status`, `editor_footer`) are
//! forwarded: with no CLI in front of the guest they answer exactly what they answer to a native
//! `wa run` of the same script (a `false`, a `nil`, `{"action":"unsupported"}`), which is the point —
//! same binary, same script, same output.
use wa_host_support::lua::{
    lua_createtable, lua_getfield, lua_getglobal, lua_gettop, lua_pcallk, lua_pushboolean, lua_pushinteger,
    lua_pushlstring, lua_pushnil, lua_pushnumber, lua_rawseti, lua_settop, lua_toboolean, lua_tointegerx,
    lua_tolstring, lua_tonumberx,
    lua_type, Lua, LuaState, LUA_MULTRET, LUA_OK, LUA_TBOOLEAN, LUA_TNIL, LUA_TNUMBER, LUA_TSTRING, LUA_TTABLE,
};
use serde_json::Value as Json;
use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_char, c_int};
use std::sync::mpsc::{Receiver, Sender, SyncSender};
use std::time::Instant;
use wasmtime::component::{Component, HasSelf, Linker, ResourceTable};
use wasmtime::{Config, Engine, Store};
use wasmtime_wasi::{FsPerms, WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    world: "core-component",
    path: "../../wit/kernel",
});

use wa::kernel::host::{Value, Verdict};

extern "C" {
    fn lua_isinteger(l: *mut LuaState, idx: c_int) -> c_int;
    fn lua_gettable(l: *mut LuaState, idx: c_int) -> c_int;
    /// Not in `wa_host_support::lua`'s list, and this module needs both: `rawset` to build a table whose keys
    /// are the JSON object's own strings (a C string key cannot carry a NUL), `checkstack` because a
    /// nested JSON value grows the stack as it is pushed.
    fn lua_rawset(l: *mut LuaState, idx: c_int);
    fn lua_checkstack(l: *mut LuaState, extra: c_int) -> c_int;
}

/// The console capabilities v2 still refuses, by name: the ones that *read* the user's input through
/// the CLI's off-thread line reader or repaint its editor row. A `--core-component` run is not a CLI
/// session - there is no editor, no panel owner and no reader to consume stdin in this process - so
/// starting one would steal the guest's own stdin rather than serve it. Their sibling *output*
/// capabilities (`ticker`, `panel`, `editor_status`, `editor_footer`) cross: they only draw, and with
/// no CLI in front of them they answer as they do to a native `wa run` (see the module docs).
pub const INPUT_REFUSED: &[&str] = &[
    "input_start",
    "input_editor",
    "input_commands",
    "input_held",
    "input_take",
    "input_stop",
    "input_idle",
];

/// The one capability with a stream form today. `http_sse` yields lines, so its answer arrives one
/// item at a time; everything else in the registry answers once and stays a single `call`.
pub const STREAM_HTTP_SSE: &str = "http_sse";

/// How many arguments the guest sends for `http_sse`: the four data arguments, the marker saying
/// whether the Lua caller passed a callback, and the timeout slot. The callback itself cannot cross,
/// so the marker is what keeps the native argument positions (and therefore every refusal's order
/// and text) intact.
const SSE_ARGS: usize = 6;

/// The native interpreter that answers the guest's calls. A raw `lua_State` is not `Send`; this
/// one is created, used and dropped on the thread that runs the component (wasmtime's sync API
/// never moves the store across threads), which is what the `Send` bound on `WasiView` needs.
struct Native(Lua);
unsafe impl Send for Native {}

/// One open stream: the line channel the host reader feeds, the verdict channel it waits on, and
/// the capability's own final answer. Nothing here is read ahead of the guest: the reader blocks in
/// its callback until the guest has taken a line and said what to do with it, which is exactly the
/// order a native Lua callback has (`host.rs` `read_sse_lines` + `call_lua_string`).
struct Session {
    lines: Receiver<Vec<u8>>,
    verdicts: Sender<Verdict>,
    result: Receiver<Vec<u8>>,
    thread: std::thread::JoinHandle<()>,
}

struct State {
    wasi: WasiCtx,
    table: ResourceTable,
    native: Native,
    calls: u64,
    streams: HashMap<u64, Session>,
    /// Handles are never reused, so a stale handle is an error instead of somebody else's stream.
    serial: u64,
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

unsafe fn bytes_at(l: *mut LuaState, idx: c_int) -> Option<Vec<u8>> {
    let mut len = 0usize;
    let pointer = lua_tolstring(l, idx, &mut len);
    if pointer.is_null() {
        None
    } else {
        Some(std::slice::from_raw_parts(pointer as *const u8, len).to_vec())
    }
}

/// A table of string keys to string values (what `paths` and `platform` return), else None.
unsafe fn string_map(l: *mut LuaState, idx: c_int) -> Option<Vec<(String, Vec<u8>)>> {
    let mut out = Vec::new();
    wa_host_support::lua::lua_pushnil(l);
    while wa_host_support::lua::lua_next(l, idx) != 0 {
        // lua_tolstring on a number key would convert it in place and break lua_next: check types first.
        if lua_type(l, -2) != LUA_TSTRING || lua_type(l, -1) != LUA_TSTRING {
            lua_settop(l, -3);
            return None;
        }
        let key = String::from_utf8_lossy(&bytes_at(l, -2).unwrap_or_default()).into_owned();
        out.push((key, bytes_at(l, -1).unwrap_or_default()));
        lua_settop(l, -2);
    }
    Some(out)
}

fn push_bytes(l: *mut LuaState, bytes: &[u8]) {
    unsafe { lua_pushlstring(l, bytes.as_ptr() as *const c_char, bytes.len()) };
}

/// One `value` on the native stack. `Value::Json` becomes a real Lua table, so a capability receives
/// the same shape a native caller passes it; the guest's half of this contract is in `glue.c`.
unsafe fn push_arg(l: *mut LuaState, arg: &Value) -> Result<(), String> {
    match arg {
        Value::Nil => lua_pushnil(l),
        Value::Boolean(b) => lua_pushboolean(l, *b as c_int),
        Value::Integer(i) => lua_pushinteger(l, *i),
        Value::Number(n) => lua_pushnumber(l, *n),
        Value::Bytes(bytes) => push_bytes(l, bytes),
        // results only: the guest never sends one back
        Value::StringMap(_) => lua_pushnil(l),
        Value::Json(bytes) => {
            let document: Json = serde_json::from_slice(bytes)
                .map_err(|error| format!("the table argument is not valid JSON: {error}"))?;
            push_json(l, &document, 0)?;
        }
    }
    Ok(())
}

/// Push a JSON document as the Lua value it stands for. `1` stays an integer and `1.0` a float,
/// because Lua 5.4 prints them differently and a capability that formats a number would show it.
unsafe fn push_json(l: *mut LuaState, value: &Json, depth: usize) -> Result<(), String> {
    // Two stack slots per level (a key and a value); the guest's encoder stops at 24, so this is a
    // guard against a hand-written module, not a reachable path of its own.
    if depth > 48 {
        return Err("the table argument nests deeper than 48 levels".to_string());
    }
    if lua_checkstack(l, 4) == 0 {
        return Err("the interpreter stack is full".to_string());
    }
    match value {
        Json::Null => lua_pushnil(l),
        Json::Bool(b) => lua_pushboolean(l, *b as c_int),
        Json::Number(number) => match number.as_i64() {
            Some(integer) => lua_pushinteger(l, integer),
            None => match number.as_f64() {
                Some(float) => lua_pushnumber(l, float),
                None => return Err("a number in the table argument is not representable".to_string()),
            },
        },
        Json::String(text) => push_bytes(l, text.as_bytes()),
        Json::Array(items) => {
            lua_createtable(l, items.len() as c_int, 0);
            for (index, item) in items.iter().enumerate() {
                push_json(l, item, depth + 1)?;
                lua_rawseti(l, -2, index as i64 + 1);
            }
        }
        Json::Object(map) => {
            lua_createtable(l, 0, map.len() as c_int);
            for (key, item) in map {
                push_bytes(l, key.as_bytes());
                push_json(l, item, depth + 1)?;
                lua_rawset(l, -3);
            }
        }
    }
    Ok(())
}

/// The answer a stream's reader sends when it cannot produce the capability's own one. It keeps the
/// shape of `http_sse`'s failures (`{error, termination}`) so a caller's error path is unchanged.
fn bridge_failure(reason: &str) -> Vec<u8> {
    format!("{{\"error\":{},\"termination\":\"bridge_failed\"}}", Json::String(reason.to_string())).into_bytes()
}

/// The line channel and the verdict channel of an SSE read: the two ends of the handoff between the
/// kernel's reader and the guest's pull.
type SseLink = (SyncSender<Vec<u8>>, Receiver<Verdict>);

thread_local! {
    /// The channel pair of the SSE read running on THIS thread. `http_sse` runs on a host thread of
    /// its own (see [`State::open`]), so the callback needs no upvalue and no shared state beyond
    /// these two channels: it hands one line over and blocks for the verdict on it.
    static SSE_LINK: RefCell<Option<SseLink>> = const { RefCell::new(None) };
}

/// The line callback the kernel gives the native `http_sse` while it runs for a guest: one line to
/// the guest, then the guest's verdict. `false` stops the read (`callback_stopped`), a raised error
/// is `line_callback_failed` — both produced by `host.rs`, unchanged, from this return value.
extern "C" fn sse_on_line(l: *mut LuaState) -> c_int {
    let line = unsafe { bytes_at(l, 1) }.unwrap_or_default();
    let verdict = SSE_LINK.with(|slot| {
        let held = slot.borrow();
        let Some((lines, verdicts)) = held.as_ref() else { return Verdict::Stop };
        // A rendezvous send: the reader cannot run ahead of the guest that decides about the line.
        if lines.send(line).is_err() {
            return Verdict::Stop;
        }
        verdicts.recv().unwrap_or(Verdict::Stop)
    });
    unsafe {
        match verdict {
            Verdict::Continue => {
                lua_pushboolean(l, 1);
                1
            }
            Verdict::Stop => {
                lua_pushboolean(l, 0);
                1
            }
            Verdict::Fail(message) => {
                // `lua_error` longjmps to the pcall `host.rs` set up around this callback. The
                // message is copied into the interpreter first so no Rust value is live across it.
                lua_pushlstring(l, message.as_ptr() as *const c_char, message.len());
                std::mem::forget(message);
                wa_host_support::lua::lua_error(l)
            }
        }
    }
}

/// The reader: the native `http_sse` itself, on a thread of its own, with the line callback above in
/// place of the guest's Lua function. Everything else - argument validation, the request, the
/// timeouts, cancellation, the budget, the termination names and the JSON answer - is the code
/// `wa run` uses, which is why the guest's answer is byte-identical to a native call's.
fn read_stream(args: Vec<Value>, lines: SyncSender<Vec<u8>>, verdicts: Receiver<Verdict>, result: Sender<Vec<u8>>) {
    SSE_LINK.with(|slot| *slot.borrow_mut() = Some((lines, verdicts)));
    let lua = Lua::new();
    unsafe {
        for (index, arg) in args.iter().enumerate() {
            // Argument 5 is the guest's callback, which cannot cross: the marker says one was passed
            // and the kernel's own callback takes its place. A nil callback stays nil, so `http_sse`
            // refuses it itself, in its own words and in its own order.
            if index == 4 && matches!(arg, Value::Boolean(true)) {
                wa_host_support::lua::lua_pushcclosure(lua.l, sse_on_line, 0);
            } else if let Err(error) = push_arg(lua.l, arg) {
                let _ = result.send(bridge_failure(&error));
                return;
            }
        }
        crate::host::http_sse(lua.l);
        let answer = bytes_at(lua.l, -1).unwrap_or_else(|| bridge_failure("http_sse returned no answer"));
        let _ = result.send(answer);
    }
}

impl State {
    /// `host.<name>(args...)` on the native state, every return value converted back.
    fn dispatch(&mut self, name: &str, args: Vec<Value>) -> Result<Vec<Value>, String> {
        let l = self.native.0.l;
        let cname = wa_host_support::lua::cstr(name);
        unsafe {
            let base = lua_gettop(l);
            lua_getglobal(l, wa_host_support::lua::cstr("host").as_ptr());
            lua_getfield(l, -1, cname.as_ptr());
            // `host` stays at base+1 under the call (lua_remove is a macro, not a symbol, in 5.4).
            for arg in &args {
                if let Err(reason) = push_arg(l, arg) {
                    lua_settop(l, base);
                    return Err(format!("unsupported_in_component_v1:{name} ({reason})"));
                }
            }
            if lua_pcallk(l, args.len() as c_int, LUA_MULTRET, 0, 0, std::ptr::null_mut()) != LUA_OK {
                let message = bytes_at(l, -1)
                    .map(|b| String::from_utf8_lossy(&b).into_owned())
                    .unwrap_or_else(|| "lua error".to_string());
                lua_settop(l, base);
                return Err(message);
            }
            let top = lua_gettop(l);
            let mut out = Vec::with_capacity((top - base - 1).max(0) as usize);
            for idx in base + 2..=top {
                out.push(match lua_type(l, idx) {
                    LUA_TNIL => Value::Nil,
                    LUA_TBOOLEAN => Value::Boolean(lua_toboolean(l, idx) != 0),
                    LUA_TNUMBER if lua_isinteger(l, idx) != 0 => Value::Integer(lua_tointegerx(l, idx, std::ptr::null_mut())),
                    LUA_TNUMBER => Value::Number(lua_tonumberx(l, idx, std::ptr::null_mut())),
                    LUA_TSTRING => Value::Bytes(bytes_at(l, idx).unwrap_or_default()),
                    LUA_TTABLE => match string_map(l, idx) {
                        Some(map) => Value::StringMap(map),
                        None => {
                            lua_settop(l, base);
                            return Err(format!("unsupported_in_component_v1:{name} (returned a table that is not a flat string map)"));
                        }
                    },
                    other => {
                        lua_settop(l, base);
                        return Err(format!("unsupported_in_component_v1:{name} (returned a value of Lua type {other})"));
                    }
                });
            }
            lua_settop(l, base);
            Ok(out)
        }
    }

    /// `EMBEDDED[path]` as the native interpreter has it: the installed lua-core tree, else compiled in.
    fn embedded(&mut self, path: &[u8]) -> Vec<Value> {
        let l = self.native.0.l;
        unsafe {
            let base = lua_gettop(l);
            lua_getglobal(l, wa_host_support::lua::cstr("EMBEDDED").as_ptr());
            push_bytes(l, path);
            lua_gettable(l, -2);
            let value = if lua_type(l, -1) == LUA_TSTRING { bytes_at(l, -1).map(Value::Bytes) } else { None };
            lua_settop(l, base);
            vec![value.unwrap_or(Value::Nil)]
        }
    }

    /// The stream form of `name`: start the native capability's reader and keep the channels that
    /// make it pullable. The handle is opaque to the guest and never reused.
    fn open(&mut self, name: String, args: Vec<Value>) -> Result<u64, String> {
        if name != STREAM_HTTP_SSE {
            return Err(format!("unsupported_stream_capability:{name}"));
        }
        if args.len() != SSE_ARGS {
            return Err(format!(
                "unsupported_in_component_v1:{name} (the bridge sends {SSE_ARGS} arguments, got {})",
                args.len()
            ));
        }
        let (lines, lines_rx) = std::sync::mpsc::sync_channel::<Vec<u8>>(0);
        let (verdicts, verdict_rx) = std::sync::mpsc::channel::<Verdict>();
        let (result, result_rx) = std::sync::mpsc::channel::<Vec<u8>>();
        let thread = std::thread::Builder::new()
            .name("wa-sse".to_string())
            .spawn(move || read_stream(args, lines, verdict_rx, result))
            .map_err(|error| format!("unsupported_in_component_v1:{name} (cannot start the reader: {error})"))?;
        self.serial += 1;
        let handle = self.serial;
        self.streams.insert(handle, Session { lines: lines_rx, verdicts, result: result_rx, thread });
        Ok(handle)
    }

    /// One item, after telling the reader what became of the previous one (`None` on the first
    /// call, where there is no previous one). `Ok(None)` means the reader has closed the stream;
    /// `close` carries the answer.
    fn next(&mut self, handle: u64, verdict: Option<Verdict>) -> Result<Option<Vec<u8>>, String> {
        let session = self
            .streams
            .get_mut(&handle)
            .ok_or_else(|| format!("unknown_stream:{handle} (no open stream, or it was already closed)"))?;
        // A send on a finished reader fails, and that is not an error: the line channel below says
        // whether there is another item.
        if let Some(verdict) = verdict {
            let _ = session.verdicts.send(verdict);
        }
        Ok(session.lines.recv().ok())
    }

    /// End the stream and take the capability's own answer. The verdict still matters here: it is the
    /// guest's word on the last line, and with a `stop` the reader ends the way a native callback
    /// returning `false` ends it.
    fn close(&mut self, handle: u64, verdict: Verdict) -> Result<Vec<Value>, String> {
        let session = self
            .streams
            .remove(&handle)
            .ok_or_else(|| format!("unknown_stream:{handle} (no open stream, or it was already closed)"))?;
        let Session { lines, verdicts, result, thread } = session;
        let _ = verdicts.send(verdict);
        // Dropping the line receiver is what wakes a reader blocked on a line nobody will take.
        drop(lines);
        let answer = result.recv().map_err(|_| format!("stream_failed:{handle} ended without an answer"))?;
        let _ = thread.join();
        Ok(vec![Value::Bytes(answer)])
    }
}

impl wa::kernel::host::Host for State {
    fn call(&mut self, name: String, args: Vec<Value>) -> Result<Vec<Value>, String> {
        self.calls += 1;
        let first = || match args.first() {
            Some(Value::Bytes(bytes)) => bytes.clone(),
            _ => Vec::new(),
        };
        match name.as_str() {
            // The guest's boot: which names `host.*` resolves, the shipping Lua modules, the script.
            "__names" => {
                let names: Vec<&str> = crate::capabilities::REGISTRY.iter().map(|c| c.name).collect();
                Ok(vec![Value::Bytes(names.join("\n").into_bytes())])
            }
            "__embedded" => Ok(self.embedded(&first())),
            "__script" => {
                let path = String::from_utf8_lossy(&first()).into_owned();
                std::fs::read(&path).map(|b| vec![Value::Bytes(b)]).map_err(|e| format!("read {path}: {e}"))
            }
            _ if INPUT_REFUSED.contains(&name.as_str()) => Err(format!(
                "unsupported_in_component_v1:{name} (the interactive console reader belongs to the CLI; a \
                 --core-component run has no editor to read into)"
            )),
            _ if !crate::capabilities::REGISTRY.iter().any(|c| c.name == name) => Err(format!("unknown_capability:{name}")),
            _ => self.dispatch(&name, args),
        }
    }

    fn open(&mut self, name: String, args: Vec<Value>) -> Result<u64, String> {
        self.calls += 1;
        self.open(name, args)
    }

    fn next(&mut self, handle: u64, verdict: Option<Verdict>) -> Result<Option<Vec<u8>>, String> {
        self.calls += 1;
        self.next(handle, verdict)
    }

    fn close(&mut self, handle: u64, verdict: Verdict) -> Result<Vec<Value>, String> {
        self.calls += 1;
        self.close(handle, verdict)
    }
}

impl wa::kernel::lifecycle::Host for State {
    fn stopping(&mut self) -> bool {
        false
    }
    fn report(&mut self, _state: wa::kernel::lifecycle::Health, _detail: Option<String>) {}
}

impl wa::kernel::log::Host for State {
    fn write(&mut self, _level: wa::kernel::log::Level, target: String, message: String) {
        eprintln!("[{target}] {message}");
    }
}

fn ms(since: Instant) -> f64 {
    since.elapsed().as_secs_f64() * 1000.0
}

/// Compiled code for `bytes`, from the cache when this engine has compiled them before.
/// The cache key is the module's sha256 plus the engine's compatibility hash, and the cache
/// directory is the node's own (`~/.wasm-agent/cache/core-component`), never a shared one.
fn load_component(engine: &Engine, bytes: &[u8]) -> wasmtime::Result<(Component, &'static str)> {
    use std::hash::{Hash, Hasher};
    let digest: String = ring::digest::digest(&ring::digest::SHA256, bytes).as_ref().iter().map(|b| format!("{b:02x}")).collect();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    engine.precompile_compatibility_hash().hash(&mut hasher);
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    let dir = std::path::PathBuf::from(home).join(".wasm-agent/cache/core-component");
    let path = dir.join(format!("{digest}-{:016x}.cwasm", hasher.finish()));
    if std::env::var("WA_CORE_CACHE").map(|v| v != "0").unwrap_or(true) && path.is_file() {
        // Safety: the file is one this binary wrote below, keyed by the module's hash and this
        // engine's compatibility hash, in the node's private directory.
        if let Ok(component) = unsafe { Component::deserialize_file(engine, &path) } {
            return Ok((component, "cache"));
        }
    }
    let component = Component::new(engine, bytes)?;
    if std::env::var("WA_CORE_CACHE").map(|v| v != "0").unwrap_or(true) {
        if let Ok(serialized) = component.serialize() {
            let _ = std::fs::create_dir_all(&dir);
            let tmp = path.with_extension("tmp");
            if std::fs::write(&tmp, serialized).is_ok() {
                let _ = std::fs::rename(&tmp, &path);
            }
        }
    }
    Ok((component, "compiled"))
}

/// Run the CLI form. Returns the process exit code.
pub fn run_cli(native: Lua, args: &[String]) -> i32 {
    let (Some(wasm), Some(script)) = (args.first(), args.get(1)) else {
        eprintln!("usage: wa --core-component <agent-core.wasm> <script.lua> [args...]");
        return 2;
    };
    match run(native, wasm, script, &args[2..]) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("core_component_failed: {error:#}");
            1
        }
    }
}

fn run(native: Lua, wasm: &str, script: &str, script_args: &[String]) -> wasmtime::Result<i32> {
    let timing = std::env::var("WA_CORE_TIMING").map(|v| v == "1").unwrap_or(false);
    let started = Instant::now();
    let mut config = Config::new();
    config.wasm_component_model(true);
    // The guest's setjmp/longjmp (Lua errors, pcall) is wasm exception handling.
    config.wasm_exceptions(true);
    let engine = Engine::new(&config)?;
    let bytes = std::fs::read(wasm).map_err(|e| wasmtime::Error::msg(format!("read {wasm}: {e}")))?;
    let (component, source) = load_component(&engine, &bytes)?;
    let loaded = ms(started);

    let mut linker: Linker<State> = Linker::new(&engine);
    // wasi:cli/exit `exit-with-code` is always linked since wasmtime 46 (no LinkOptions switch).
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker)?;
    CoreComponent::add_to_linker::<State, HasSelf<State>>(&mut linker, |state| state)?;

    // Standard WASI for what the Lua standard library itself touches (print, io.write, os.time,
    // os.getenv, io.open on relative paths); everything else goes through `host.*`.
    let mut wasi = WasiCtxBuilder::new();
    wasi.inherit_stdio().inherit_env();
    wasi.preopened_dir(".", ".", FsPerms::ReadWrite)?;
    let state = State {
        wasi: wasi.build(),
        table: ResourceTable::new(),
        native: Native(native),
        calls: 0,
        streams: HashMap::new(),
        serial: 0,
    };
    let mut store = Store::new(&engine, state);
    let instantiate_started = Instant::now();
    let core = CoreComponent::instantiate(&mut store, &component, &linker)?;
    let instantiated = ms(instantiate_started);
    let run_started = Instant::now();
    let outcome = core.call_run(&mut store, script, script_args);
    let ran = ms(run_started);
    if timing {
        eprintln!(
            "core_component_timing: load={loaded:.1}ms ({source}) instantiate={instantiated:.2}ms run={ran:.1}ms host_calls={} streams_open={}",
            store.data().calls,
            store.data().streams.len()
        );
    }
    match outcome {
        Ok(Ok(())) => Ok(0),
        Ok(Err(message)) => {
            eprintln!("lua error: {message}");
            Ok(1)
        }
        Err(error) => match error.downcast_ref::<wasmtime_wasi::I32Exit>() {
            Some(exit) => Ok(exit.0),
            None => Err(error),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wa::kernel::host::Host as _;

    /// The native interpreter a `--core-component` run boots: the same registry on a plain state,
    /// with no `Host` pointer (no test here needs an upvalue-bound capability).
    fn state() -> State {
        let lua = Lua::new();
        lua.push_table();
        crate::capabilities::register(&lua, std::ptr::null_mut());
        lua.set_global("host");
        State {
            wasi: WasiCtxBuilder::new().build(),
            table: ResourceTable::new(),
            native: Native(lua),
            calls: 0,
            streams: HashMap::new(),
            serial: 0,
        }
    }

    /// A table argument arrives as the table it was, not as a string: the same literals, nested, an
    /// array that is an array, `1` still an integer and `1.5` still a float.
    #[test]
    fn a_json_argument_becomes_the_table_it_stands_for() {
        let state = state();
        let l = state.native.0.l;
        let document = br#"{"n":1,"f":1.5,"s":"two words","b":true,"z":null,"list":[1,[2,{"deep":"x"}]]}"#;
        unsafe {
            let base = lua_gettop(l);
            push_arg(l, &Value::Json(document.to_vec())).expect("the document is this test's own JSON");
            assert_eq!(lua_gettop(l), base + 1);
            wa_host_support::lua::lua_setglobal(l, wa_host_support::lua::cstr("t").as_ptr());
            // Asserted from Lua, so what is checked is the interpreter's own view of the value.
            let check = "assert(type(t)=='table')
                assert(t.n==1); assert(t.f==1.5); assert(t.s=='two words'); assert(t.b==true)
                assert(t.z==nil); assert(#t.list==2)
                assert(t.list[1]==1); assert(t.list[2][1]==2); assert(t.list[2][2].deep=='x')";
            let source = wa_host_support::lua::cstr(check);
            let name = wa_host_support::lua::cstr("check");
            assert_eq!(
                wa_host_support::lua::luaL_loadbufferx(l, source.as_ptr(), check.len(), name.as_ptr(), std::ptr::null()),
                LUA_OK
            );
            let status = lua_pcallk(l, 0, 0, 0, 0, std::ptr::null_mut());
            let message = bytes_at(l, -1).map(|b| String::from_utf8_lossy(&b).into_owned());
            assert_eq!(status, LUA_OK, "{message:?}");
            lua_settop(l, base);
        }
    }

    /// The v1 refusal is gone: a table argument reaches the capability instead of stopping at the
    /// bridge. `sleep` ignores its argument and answers with no values, so what is observed is that
    /// the call completed instead of being refused.
    #[test]
    fn a_table_argument_crosses_the_bridge() {
        let mut state = state();
        for argument in [br#"{}"#.as_slice(), br#"[1,2,3]"#, br#"{"seconds":0}"#] {
            let answer = state.call("sleep".to_string(), vec![Value::Json(argument.to_vec())]);
            match answer {
                Ok(values) => assert!(values.is_empty(), "sleep answers no values"),
                Err(error) => panic!("a table argument must reach the capability, got {error}"),
            }
        }
    }

    /// A table JSON cannot carry is refused with a reason, not silently dropped.
    #[test]
    fn a_malformed_table_argument_is_refused_with_a_reason() {
        let mut state = state();
        let error = state
            .call("sleep".to_string(), vec![Value::Json(b"{not json".to_vec())])
            .expect_err("malformed JSON must not reach the capability");
        assert!(error.starts_with("unsupported_in_component_v1:sleep ("), "{error}");
    }

    /// The console's output capabilities answer through the bridge; the reader family says why not.
    #[test]
    fn console_output_crosses_and_the_reader_is_refused() {
        let mut state = state();
        // No CLI editor in this process: `editor_status` answers false and `ticker(nil)` stops and
        // answers nil - what the native interpreter answers to the same call.
        let answer = state.call("editor_status".to_string(), vec![Value::Boolean(true)]);
        assert!(matches!(answer, Ok(ref values) if matches!(values.as_slice(), [Value::Boolean(false)])));
        let answer = state.call("ticker".to_string(), vec![Value::Nil]);
        assert!(matches!(answer, Ok(ref values) if matches!(values.as_slice(), [Value::Nil])));
        let error = state.call("input_start".to_string(), Vec::new()).expect_err("the reader is refused");
        assert!(error.starts_with("unsupported_in_component_v1:input_start ("), "{error}");
        assert!(error.contains("interactive console reader"), "{error}");
    }

    /// A capability without a stream form is refused by name, and an unknown handle is an error
    /// rather than a silent success.
    #[test]
    fn streams_are_explicit_about_what_they_do_not_support() {
        let mut state = state();
        assert_eq!(state.open("sleep".to_string(), Vec::new()), Err("unsupported_stream_capability:sleep".to_string()));
        let unknown = "unknown_stream:7 (no open stream, or it was already closed)";
        assert_eq!(state.next(7, None).err().as_deref(), Some(unknown));
        assert_eq!(state.close(7, Verdict::Continue).err().as_deref(), Some(unknown));
    }
}
