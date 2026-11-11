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
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use wasmtime::component::{Component, HasSelf, Linker, ResourceTable};
use wasmtime::{Config, Engine, ResourceLimiter, Store};
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

/// The names the **kernel itself** answers, before the capability registry is consulted.
///
/// They are about the node, not about a capability: there is no native `host.*` C function to forward
/// them to, so unlike every other name in the bridge they cannot come from `capabilities::REGISTRY`.
/// They cross the same import with the same value shapes, and `__names` lists them so the guest's
/// `if host.local_tz then` reads the truth for this kernel.
///
/// * `local_tz` - the node's own time zone for an instant ([`State::local_tz`]). It is the one thing a
///   guest cannot work out for itself: wasi-libc has no zone database, so `os.date` in the component
///   is UTC while the node it serves is not.
pub const KERNEL_CALLS: &[&str] = &["local_tz"];

/// The chunk name the guest's own errors report for [`LOCAL_TZ_LUA`].
const LOCAL_TZ_NAME: &str = "local_tz";

/// The host's answer for `local_tz`: the node's zone as the **C runtime** reads it, through the same
/// `lua/core/platform.lua` function the native core calls (`runtime_clock`).
///
/// That identity is the whole design. Two implementations of "the local offset" would agree almost
/// always, and "almost" is what an agent quoting a log line cannot afford; one function on one C
/// runtime (`tzset`, `localtime`, DST rules included) makes the native and the guest answer the same
/// instant the same way by construction. The offset is therefore not in `wa-local-tz`: that crate
/// answers the zone's *name*, which the C runtime cannot portably name.
///
/// The interpreter caches the module in a global of its own (`__wa_runtime_clock`), so run N of a
/// pooled instance does not re-read the Lua tree to ask the clock. The result is a flat table of
/// strings: the shape the bridge carries (`Value::StringMap`), and one `status`-style line per field
/// in the guest's answer.
const LOCAL_TZ_LUA: &str = r#"
local runtime = __wa_runtime_clock
if not runtime then
  runtime = dofile('lua/core/platform.lua').runtime_clock
  __wa_runtime_clock = runtime
end
local fields = runtime(tonumber(...) or os.time())
local out = {
  utc_offset_minutes = tostring(fields.utc_offset_minutes),
  utc_offset = tostring(fields.utc_offset),
}
if fields.zone then out.zone = tostring(fields.zone) end
return out
"#;

/// The native interpreter that answers the guest's calls. A raw `lua_State` is not `Send`; this
/// one is created, used and dropped on the thread that runs the component (wasmtime's sync API
/// never moves the store across threads), which is what the `Send` bound on `WasiView` needs.
struct Native(Lua);
unsafe impl Send for Native {}

/// A pooled instance's memory cap and the bytes it currently holds, installed as the store's
/// `ResourceLimiter` - the one supported place a host is told a guest's memory sizes, and therefore
/// the only way to answer "memory per instance" with a measurement rather than a configured bound.
/// `wasmtime::StoreLimits` no longer reports bytes in wasmtime 50 (`memories()` counts memories).
#[derive(Default)]
struct MemoryLimits {
    /// Bytes across this instance's linear memories.
    bytes: usize,
    /// `0` = no cap (the one-shot CLI path, where no limiter is installed at all).
    cap: usize,
}

impl ResourceLimiter for MemoryLimits {
    fn memory_growing(&mut self, current: usize, desired: usize, _maximum: Option<usize>) -> wasmtime::Result<bool> {
        if self.cap != 0 && desired > self.cap {
            return Ok(false);
        }
        self.bytes = self.bytes.saturating_sub(current).saturating_add(desired);
        Ok(true)
    }

    /// Tables are not what the memory number is about, but the trait has no default for this one, so
    /// say what it means here: no bound (the pooling allocator already bounds the table slots).
    fn table_growing(&mut self, _current: usize, _desired: usize, _maximum: Option<usize>) -> wasmtime::Result<bool> {
        Ok(true)
    }
}

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
    /// Per-instance linear-memory accounting. Present on every state, but a limiter is installed on
    /// the store only by the pool ([`CoreComponentPool`]): a one-shot `--core-component` run keeps
    /// the unbounded behaviour it had, and only a pooled instance is capped and measurable.
    limits: MemoryLimits,
    /// When the current run started, and when its first `host.*` call arrived. The second is the
    /// "time to first Lua statement" the pool reports: the fixture that measures it makes a host
    /// call its first statement, so the number is observed rather than inferred from stdout.
    run_started: Option<Instant>,
    run_first_call_ms: Option<f64>,
    /// A pooled run's script, when the caller hands over the text instead of a path: `__script`
    /// answers it instead of reading the file (`--core-component` passes a path and leaves this
    /// `None`, which is the behaviour every existing run has).
    script: Option<(String, Vec<u8>)>,
    /// Module digests by path, revalidated by `(len, mtime)` so a boot that already holds a compiled
    /// chunk pays one `metadata` call instead of reading and hashing the module (`__digest`, A2.7).
    /// The embedded tree has no file behind it and cannot change inside a process, so its half is
    /// keyed by path alone.
    digests: HashMap<String, (u64, i64, String)>,
    embedded_digests: HashMap<String, String>,
    /// What this work item spent in the bridge, when `WA_CORE_CALL_PROFILE=1` (see [`ItemProfile`]).
    /// `None` on an ordinary node: one `is_some()` per call is the whole cost of the instrumentation.
    profile: Option<ItemProfile>,
}

// ---- what one work item spends in the bridge (`WA_CORE_CALL_PROFILE=1`) --------------------------
//
// The split this side can observe honestly: time inside `host.*` handlers (the node's own work, the
// same in both cores) and everything else, which is the guest running Lua plus the crossing itself.
// Per name, per item: how many calls, how many bytes crossed in each direction, and how much of the
// wall time a table argument cost to decode on this side (the guest encodes it; the guest's own
// encode cost shows up in the A/B of a script that only does that, `scripts/bench-core-bridge.sh`).
// A measurement must be takeable from an ordinary node, so this is off unless the variable is set and
// adds one `Option` check per crossing when it is off.
#[derive(Default)]
struct NameStat {
    calls: u64,
    arg_bytes: u64,
    result_bytes: u64,
    host_ns: u64,
}

#[derive(Default)]
struct ItemProfile {
    names: HashMap<String, NameStat>,
    calls: u64,
    arg_bytes: u64,
    result_bytes: u64,
    host_ns: u64,
    json_ns: u64,
    arm_ns: u64,
}

fn profile_enabled() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var("WA_CORE_CALL_PROFILE").map(|v| v == "1").unwrap_or(false))
}

fn item_profile() -> Option<ItemProfile> {
    profile_enabled().then(ItemProfile::default)
}

/// The bytes a value carries across the boundary, as one number: a string's or a table's JSON text
/// length, eight bytes for a number. This is what "bytes copied" counts.
fn value_bytes(value: &Value) -> u64 {
    match value {
        Value::Bytes(bytes) | Value::Json(bytes) => bytes.len() as u64,
        Value::Boolean(_) => 1,
        Value::Integer(_) | Value::Number(_) => 8,
        Value::StringMap(map) => map.iter().map(|(key, value)| (key.len() + value.len()) as u64).sum(),
        Value::Nil => 0,
    }
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
    /// Remember when this run's first `host.*` call arrived, once. A pooled instance measures
    /// "time to first Lua statement" this way: the measuring fixture's first statement *is* a host
    /// call, so the number is observed at the boundary rather than inferred from the guest's output.
    fn note_call(&mut self) {
        if self.run_first_call_ms.is_none() {
            if let Some(started) = self.run_started {
                self.run_first_call_ms = Some(ms(started));
            }
        }
    }

    /// End every stream this run left open. A pooled instance is handed to the next caller, so a
    /// reader thread the script abandoned must not outlive its turn: the verdict wakes it and the
    /// dropped line channel makes its next send fail, which is the same shutdown an error takes.
    fn abort_streams(&mut self) {
        for (_, session) in self.streams.drain() {
            let _ = session.verdicts.send(Verdict::Stop);
            drop(session.lines);
            // Not joined: the reader exits at its next line or read timeout (A2.2, "a stream the
            // script abandons is stopped when the handle is dropped, not joined").
            drop(session.thread);
        }
    }

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
                let json_timer = self.profile.as_ref().map(|_| Instant::now());
                if let Err(reason) = push_arg(l, arg) {
                    lua_settop(l, base);
                    return Err(format!("unsupported_in_component_v1:{name} ({reason})"));
                }
                if let (Some(timer), Some(profile)) = (json_timer, self.profile.as_mut()) {
                    profile.json_ns += timer.elapsed().as_nanos() as u64;
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
            let value = if lua_type(l, -1) == LUA_TSTRING { bytes_at(l, -1) } else { None };
            lua_settop(l, base);
            match value {
                // The digest travels with the source, in the same crossing: the guest's boot sets
                // `LOADED_SOURCES[path]` from it, and asking for it separately was the second half of
                // a chatty pair (see `__source`). Same bytes, same `host.sha256` answer - including
                // that capability's UTF-8 rule, hence the lossy conversion here too.
                Some(bytes) => {
                    let digest = digest_hex(String::from_utf8_lossy(&bytes).as_bytes());
                    vec![Value::Bytes(bytes), Value::Bytes(digest.into_bytes())]
                }
                None => vec![Value::Nil, Value::Nil],
            }
        }
    }

    /// `__source(path)`: a file's text and its SHA-256, read and hashed here so the guest asks once.
    ///
    /// The module boot does exactly this pair natively (`host.read_file` then `host.sha256`), and the
    /// bytes that cross are the file's, so the digest is the one `host.sha256` gives for the same text
    /// - including the UTF-8 rule: a file that is not text is `nil`, as `read_file` answers.
    fn source(&mut self, path: &[u8]) -> Vec<Value> {
        let path = String::from_utf8_lossy(path).into_owned();
        match std::fs::read_to_string(&path) {
            Ok(text) => vec![Value::Bytes(text.clone().into_bytes()), Value::Bytes(digest_hex(text.as_bytes()).into_bytes())],
            Err(_) => vec![Value::Nil, Value::Nil],
        }
    }

    /// `__digest(path)`: the SHA-256 of the text `__source` would hand over, **without the text**.
    ///
    /// A boot that already holds this module's compiled chunk (`glue.c`'s module cache, A2.7) has to
    /// find out whether the chunk still describes the file before it uses it, and the answer is 64
    /// bytes where the module's text is thousands: the copy was what a boot paid for, not the hash.
    /// The digest is of the same bytes `__source` answers, so a cached chunk keyed by it is stale
    /// exactly when `__source`'s own digest would have changed.
    ///
    /// Revalidated by `(len, mtime)`: a module re-read only when the file changed is one `metadata`
    /// call per module per boot, and a file whose bytes changed under an identical `(len, mtime)` is
    /// not a case a filesystem this node runs on produces.
    fn digest(&mut self, path: &[u8]) -> Vec<Value> {
        let path = String::from_utf8_lossy(path).into_owned();
        if let Some((len, mtime, digest)) = self.digests.get(&path) {
            if let Ok(meta) = std::fs::metadata(&path) {
                if meta.len() == *len && mtime_nanos(&meta) == *mtime {
                    return vec![Value::Bytes(digest.clone().into_bytes())];
                }
            }
        }
        // Not cached, or the file moved under it: read and hash the bytes `__source` would answer.
        match std::fs::read_to_string(&path) {
            Ok(text) => {
                let digest = digest_hex(text.as_bytes());
                if let Ok(meta) = std::fs::metadata(&path) {
                    self.digests.insert(path, (meta.len(), mtime_nanos(&meta), digest.clone()));
                }
                vec![Value::Bytes(digest.into_bytes())]
            }
            Err(_) => vec![Value::Nil],
        }
    }

    /// `__edigest(path)`: the same question for the shipping modules, answered from `EMBEDDED`.
    /// The tree is a boot constant of the process, so the digest is cached by path and never
    /// revalidated; the bytes are hashed the way `__embedded` hands them over (lossy UTF-8), which is
    /// what keeps a guest's chunk key equal to the digest the core reports.
    fn embedded_digest(&mut self, path: &[u8]) -> Vec<Value> {
        if let Some(digest) = self.embedded_digests.get(&String::from_utf8_lossy(path).into_owned()) {
            return vec![Value::Bytes(digest.clone().into_bytes())];
        }
        match self.embedded(path).into_iter().next() {
            Some(Value::Bytes(bytes)) => {
                let digest = digest_hex(String::from_utf8_lossy(&bytes).as_bytes());
                self.embedded_digests.insert(String::from_utf8_lossy(path).into_owned(), digest.clone());
                vec![Value::Bytes(digest.into_bytes())]
            }
            _ => vec![Value::Nil],
        }
    }

    /// `host.local_tz(epoch?)` - the node's own time zone for that instant, one of [`KERNEL_CALLS`].
    ///
    /// Two halves, and the split is the point:
    ///
    /// * the **offset** and the **abbreviation** are the C runtime's, read by running
    ///   `lua/core/platform.lua`'s `runtime_clock` in this instance's *native* interpreter - the same
    ///   function, the same `tzset` and the same DST rules the native core answers with, so a native
    ///   run and a guest run cannot disagree about an instant;
    /// * the **identifier** of the zone (`America/Sao_Paulo`, `E. South America Standard Time`) comes
    ///   from `wa-local-tz`, because the C runtime has no portable way to name its zone and the guest
    ///   can read neither `TZ` nor `/etc/localtime`.
    ///
    /// Answered per call, never cached: an offset read once and reused is exactly the stale answer a
    /// DST change produces. The conversation around it is `lua/core/platform.lua`; the guest gets a
    /// flat table of strings (`utc_offset_minutes`, `utc_offset`, `zone` when the platform names one,
    /// `zone_id` and `zone_source` when the OS names one, `epoch`), which is what `Value::StringMap`
    /// is for. A failure is an error and never a silent `+00:00`: that silence was the defect.
    fn local_tz(&mut self, args: &[Value]) -> Result<Vec<Value>, String> {
        let epoch = match args.first() {
            None | Some(Value::Nil) => now_epoch(),
            Some(Value::Integer(seconds)) => *seconds,
            Some(Value::Number(seconds)) if seconds.is_finite() => *seconds as i64,
            Some(Value::Bytes(bytes)) => String::from_utf8_lossy(bytes)
                .trim()
                .parse::<i64>()
                .map_err(|_| "local_tz_invalid_epoch: the epoch must be a whole number of seconds".to_string())?,
            Some(_) => return Err("local_tz_invalid_epoch: the epoch must be a whole number of seconds".to_string()),
        };
        let mut answer = self.runtime_clock(epoch)?;
        let zone = wa_local_tz::zone_id(crate::host::resolved_env("TZ").as_deref());
        if let Some(id) = zone.id {
            answer.push(("zone_id".to_string(), id.into_bytes()));
        }
        answer.push(("zone_source".to_string(), zone.source.as_bytes().to_vec()));
        answer.push(("epoch".to_string(), epoch.to_string().into_bytes()));
        Ok(vec![Value::StringMap(answer)])
    }

    /// The C runtime's answer for `epoch`, from the instance's native interpreter ([`LOCAL_TZ_LUA`]).
    fn runtime_clock(&mut self, epoch: i64) -> Result<Vec<(String, Vec<u8>)>, String> {
        let l = self.native.0.l;
        unsafe {
            let base = lua_gettop(l);
            let name = wa_host_support::lua::cstr(LOCAL_TZ_NAME);
            let loaded = wa_host_support::lua::luaL_loadbufferx(
                l,
                LOCAL_TZ_LUA.as_ptr() as *const c_char,
                LOCAL_TZ_LUA.len(),
                name.as_ptr(),
                std::ptr::null(),
            );
            if loaded != LUA_OK {
                let message = bytes_at(l, -1).map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_else(|| "lua error".to_string());
                lua_settop(l, base);
                return Err(format!("local_tz_failed: {message}"));
            }
            // The chunk reads its argument as `...`, the way a vararg chunk does.
            lua_pushinteger(l, epoch);
            if lua_pcallk(l, 1, 1, 0, 0, std::ptr::null_mut()) != LUA_OK {
                // A guest asking the clock must learn that the clock failed, with the interpreter's own
                // words: an empty or UTC-looking answer would be the same silent guess as before.
                let message = bytes_at(l, -1).map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_else(|| "lua error".to_string());
                lua_settop(l, base);
                return Err(format!("local_tz_failed: {message}"));
            }
            let answer = string_map(l, lua_gettop(l));
            lua_settop(l, base);
            answer.ok_or_else(|| "local_tz_failed: the runtime clock did not answer a flat table of strings".to_string())
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
        self.note_call();
        self.calls += 1;
        // The instrumentation is one `Option` check per crossing when it is off, and the item's own
        // profile when it is on (`WA_CORE_CALL_PROFILE=1`).
        let started = self.profile.is_some().then(Instant::now);
        let arg_bytes = if started.is_some() { args.iter().map(value_bytes).sum() } else { 0 };
        let answer = self.call_named(&name, args);
        if let Some(started) = started {
            let host_ns = started.elapsed().as_nanos() as u64;
            let result_bytes = answer.as_ref().map(|values| values.iter().map(value_bytes).sum()).unwrap_or(0);
            self.record_call(&name, arg_bytes, result_bytes, host_ns);
        }
        answer
    }

    fn open(&mut self, name: String, args: Vec<Value>) -> Result<u64, String> {
        self.note_call();
        self.calls += 1;
        let started = self.profile.is_some().then(Instant::now);
        let arg_bytes = if started.is_some() { args.iter().map(value_bytes).sum() } else { 0 };
        let label = format!("open:{name}");
        let answer = self.open(name, args);
        if let Some(started) = started {
            self.record_call(&label, arg_bytes, 0, started.elapsed().as_nanos() as u64);
        }
        answer
    }

    fn next(&mut self, handle: u64, verdict: Option<Verdict>) -> Result<Option<Vec<u8>>, String> {
        self.note_call();
        self.calls += 1;
        let started = self.profile.is_some().then(Instant::now);
        let answer = self.next(handle, verdict);
        if let Some(started) = started {
            let item_bytes = answer.as_ref().ok().and_then(|item| item.as_ref()).map(|item| item.len() as u64).unwrap_or(0);
            self.record_call("next", 0, item_bytes, started.elapsed().as_nanos() as u64);
        }
        answer
    }

    fn close(&mut self, handle: u64, verdict: Verdict) -> Result<Vec<Value>, String> {
        self.note_call();
        self.calls += 1;
        let started = self.profile.is_some().then(Instant::now);
        let answer = self.close(handle, verdict);
        if let Some(started) = started {
            let result_bytes = answer.as_ref().map(|values| values.iter().map(value_bytes).sum()).unwrap_or(0);
            self.record_call("close", 0, result_bytes, started.elapsed().as_nanos() as u64);
        }
        answer
    }
}

impl State {
    /// One crossing, accounted for when `WA_CORE_CALL_PROFILE=1` is set.
    fn record_call(&mut self, name: &str, arg_bytes: u64, result_bytes: u64, host_ns: u64) {
        let Some(profile) = self.profile.as_mut() else { return };
        profile.calls += 1;
        profile.arg_bytes += arg_bytes;
        profile.result_bytes += result_bytes;
        profile.host_ns += host_ns;
        let stat = profile.names.entry(name.to_string()).or_default();
        stat.calls += 1;
        stat.arg_bytes += arg_bytes;
        stat.result_bytes += result_bytes;
        stat.host_ns += host_ns;
    }

    /// Hand one item's profile to the log and start a fresh one. `guest_ms` is the item's wall time
    /// minus the time inside the handlers: the guest's Lua plus the crossings themselves.
    fn print_profile(&mut self, what: &str, run_ms: f64, runs: u64, booted: bool, first_ms: Option<f64>) {
        let Some(profile) = self.profile.take() else { return };
        let mut names: Vec<(&String, &NameStat)> = profile.names.iter().collect();
        names.sort_by(|a, b| b.1.host_ns.cmp(&a.1.host_ns).then(b.1.calls.cmp(&a.1.calls)));
        let host_ms = profile.host_ns as f64 / 1e6;
        eprintln!(
            "core_call_profile: {what} run_ms={run_ms:.2} host_ms={host_ms:.2} guest_ms={:.2} calls={} names={} arg_bytes={} result_bytes={} json_decode_ms={:.2} arm_ms={:.2} runs={runs} boot={booted} first_ms={}",
            (run_ms - host_ms).max(0.0),
            profile.calls,
            names.len(),
            profile.arg_bytes,
            profile.result_bytes,
            profile.json_ns as f64 / 1e6,
            profile.arm_ns as f64 / 1e6,
            first_ms.map(|ms| format!("{ms:.2}")).unwrap_or_else(|| "-".to_string()),
        );
        for (name, stat) in names {
            eprintln!(
                "core_call_profile:   {name} calls={} arg_bytes={} result_bytes={} host_ms={:.2}",
                stat.calls,
                stat.arg_bytes,
                stat.result_bytes,
                stat.host_ns as f64 / 1e6
            );
        }
        self.profile = item_profile();
    }

    /// `host.<name>(args...)`, answered (or refused) without the accounting wrapper above.
    fn call_named(&mut self, name: &str, args: Vec<Value>) -> Result<Vec<Value>, String> {
        let first = || match args.first() {
            Some(Value::Bytes(bytes)) => bytes.clone(),
            _ => Vec::new(),
        };
        match name {
            // The guest's boot: which names `host.*` resolves, the shipping Lua modules, the script.
            "__names" => {
                let mut names: Vec<&str> = crate::capabilities::REGISTRY.iter().map(|c| c.name).collect();
                // The kernel's own calls cross the same import but have no registry entry (see
                // `KERNEL_CALLS`); a guest resolves `host.<name>` from this list, so leaving them out
                // would make `host.local_tz` read as absent in a kernel that answers it.
                names.extend_from_slice(KERNEL_CALLS);
                Ok(vec![Value::Bytes(names.join("\n").into_bytes())])
            }
            "__embedded" => Ok(self.embedded(&first())),
            "__source" => Ok(self.source(&first())),
            // The module cache's cheap question (A2.7): `__source`/`__embedded` minus the text.
            "__digest" => Ok(self.digest(&first())),
            "__edigest" => Ok(self.embedded_digest(&first())),
            "__script" => {
                let path = String::from_utf8_lossy(&first()).into_owned();
                if let Some((name, bytes)) = &self.script {
                    if *name == path {
                        return Ok(vec![Value::Bytes(bytes.clone())]);
                    }
                }
                std::fs::read(&path).map(|b| vec![Value::Bytes(b)]).map_err(|e| format!("read {path}: {e}"))
            }
            // The node's own time zone, answered here rather than forwarded to a capability: there is
            // no native `host.*` function for it, and the guest cannot read the OS's zone config.
            "local_tz" => self.local_tz(&args),
            _ if INPUT_REFUSED.contains(&name) => Err(format!(
                "unsupported_in_component_v1:{name} (the interactive console reader belongs to the CLI; a \
                 --core-component run has no editor to read into)"
            )),
            _ if !crate::capabilities::REGISTRY.iter().any(|c| c.name == name) => Err(format!("unknown_capability:{name}")),
            _ => self.dispatch(name, args),
        }
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

/// A file's modification time in nanoseconds since the epoch, or `0` when the platform cannot say
/// (which makes [`State::digest`] re-hash that file instead of trusting the cache).
fn mtime_nanos(meta: &std::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|elapsed| elapsed.as_nanos() as i64)
        .unwrap_or(0)
}

/// SHA-256 of `bytes`, as the hex `host.sha256` answers with: the same `ring` digest and the same
/// lower-case formatting, so a digest taken here and one taken by the capability are comparable and
/// a module's `LOADED_SOURCES` entry does not depend on which side computed it.
fn digest_hex(bytes: &[u8]) -> String {
    ring::digest::digest(&ring::digest::SHA256, bytes).as_ref().iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The instant the host reads when a guest asks the clock without naming one. Only the *instant* comes
/// from here; its zone is the C runtime's answer, like every other `local_tz` field. A clock before the
/// epoch is not a state this node can be in, so the fallback is `0` rather than a panic in a turn.
fn now_epoch() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|elapsed| elapsed.as_secs() as i64).unwrap_or(0)
}

/// What a store's epoch-deadline callback returns, and therefore the text a deadline trap carries.
const DEADLINE_TRAP: &str = "core_run_deadline_exceeded";

/// Was this error the run's own deadline (`CorePoolConfig::run_deadline`) rather than a guest bug?
pub fn is_run_deadline(error: &wasmtime::Error) -> bool {
    format!("{error:#}").contains(DEADLINE_TRAP)
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

/// Boot the native interpreter one pool slot answers from, for callers outside the binary (the
/// tests and `rust/wa-core-pool-bench`): the capability registry on a fresh `Lua`, its own SQLite
/// connection to `db`, `args`, an empty `EMBEDDED` and the native bootstrap (`dofile`).
///
/// `wa-host`'s `boot_state` stays the shipping boot and is not this: it also carries the compiled-in
/// `EMBEDDED` tree and the process-wide plugin registry and client bridge, which belong to the
/// binary. With no `EMBEDDED` here, `dofile` resolves modules through `WASM_AGENT_LUA_ROOT` - the way
/// every gate run is configured - so a caller that needs the compiled-in tree runs under a root
/// instead (and the report says so).
pub fn boot_native_state(home: &str, db: &str, args: &[String], embedded: &[(&str, &str)]) -> wasmtime::Result<Lua> {
    use std::ffi::c_void;
    // `home` is the node's home as the binary resolved it (`wa_host_support::paths::resolve_home`), and
    // it is a parameter rather than a lookup so a test or a benchmark cannot accidentally inherit the
    // operator's: the boot publishes it, because `host.paths()`, the Lua core, the plugin directory and
    // `~/.wasm-agent/env` all derive from it. A slot that skipped this resolved `host.paths()` from the
    // *process's* HOME instead of the node's: measured, a pooled fixture wrote into the operator's real
    // `~/.wasm-agent` while the same script run natively wrote into the scratch home the harness had
    // set.
    //
    // It publishes through the capability layer's override map (`host::set_env_overrides`, which
    // `host.getenv` and now every Rust-side reader that resolves like it consults first) and **not**
    // through `std::env`. This function runs once per pool slot, inside whatever process called it, and
    // a process-wide `HOME`/`WASM_AGENT_DB` rewrite is visible to - and outlives - every other thread
    // there: in the `wa-capabilities` test binary it changed what 160 other tests and their subprocesses
    // saw, and `~/.wasm-agent/env` (model configuration, provider keys) was copied into the real
    // environment of a process that never asked for it. On Windows it was only half-true anyway: the
    // UCRT caches the environment at startup, so the C side (`os.getenv`, the `getenv` the Lua core
    // uses) kept the old value, which is exactly why `host.getenv` exists as a capability.
    let home = home.to_string();
    let mut resolved = std::collections::HashMap::new();
    resolved.insert("HOME".to_string(), home.clone());
    resolved.insert("WASM_AGENT_DB".to_string(), db.to_string());
    load_env_file(&home, &mut resolved);
    crate::host::set_env_overrides(resolved);
    let in_memory = db.is_empty() || db == ":memory:" || db == "file::memory:";
    let database = if in_memory {
        format!("file:wa-core-pool-{}?mode=memory&cache=shared", std::process::id())
    } else {
        db.to_string()
    };
    let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE
        | rusqlite::OpenFlags::SQLITE_OPEN_CREATE
        | rusqlite::OpenFlags::SQLITE_OPEN_URI;
    let connection = rusqlite::Connection::open_with_flags(&database, flags)
        .map_err(|e| wasmtime::Error::msg(format!("open_db {database}: {e}")))?;
    wa_sqlite::tune(&connection)
        .map_err(|e| wasmtime::Error::msg(format!("db_pragmas {database}: {e}")))?;
    let host: Box<crate::host::Host> = Box::new(crate::host::Host {
        db: Mutex::new(connection),
        plugins: Arc::new(Mutex::new(crate::plugins::PluginRegistry::load(&crate::plugins::plugin_dir()))),
        client: Arc::new(crate::client_bridge::Bridge::new()),
    });
    let host_ptr = (&*host) as *const crate::host::Host as *mut c_void;
    let mut lua = Lua::new();
    lua.push_table();
    crate::capabilities::register(&lua, host_ptr);
    lua.set_global("host");
    lua.push_table();
    for (index, arg) in args.iter().enumerate() {
        lua.push_string(arg);
        lua.raw_seti((index + 1) as c_int);
    }
    lua.set_global("args");
    lua.push_table();
    for (name, source) in embedded {
        lua.push_string(source);
        lua.set_field(-2, name);
    }
    lua.set_global("EMBEDDED");
    // The native bootstrap, byte for byte (`wa-host/src/main.rs`): a test run must resolve modules the
    // same way, root first and the embedded copy second.
    const BOOTSTRAP: &str = "LOADED_SOURCES = {}; function dofile(path) \
         local root = host.getenv('WASM_AGENT_LUA_ROOT'); \
         if root and root ~= '' then \
           local text = host.read_file(root .. '/' .. path); \
           if not text then error('lua_root_unreadable: ' .. root .. '/' .. path) end; \
           LOADED_SOURCES[path] = host.sha256(text); \
             return assert(load(text, '@' .. root .. '/' .. path))() \
         end; \
         local source = EMBEDDED[path]; \
         if not source then error('embedded module missing: ' .. tostring(path)) end; \
         LOADED_SOURCES[path] = host.sha256(source); \
         return assert(load(source, '@' .. path))() end";
    lua.do_string(BOOTSTRAP, "bootstrap").map_err(|e| wasmtime::Error::msg(format!("boot_state: {e}")))?;
    lua.own(host as Box<dyn std::any::Any + Send>);
    Ok(lua)
}

/// `~/.wasm-agent/env`, KEY=VALUE per line, without overriding the real environment - the same file
/// and the same rule as `load_env_file` in `wa-host/src/main.rs`, because a node's model configuration
/// lives there and a turn needs it whether the binary or a pool slot boots the interpreter.
///
/// The file is read *into* the capability override map instead of into `std::env` (a23fix): the rule
/// stays "a value the process already has wins", but what a pooled interpreter sees through
/// `host.getenv` is now the only thing this changes. The binary has its own boot (`main.rs`) and keeps
/// its own `set_var`: it is the one node in the process, and children it spawns must inherit that.
fn load_env_file(home: &str, resolved: &mut std::collections::HashMap<String, String>) {
    let Ok(text) = std::fs::read_to_string(format!("{home}/.wasm-agent/env")) else { return };
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((key, value)) = line.split_once('=') {
            let key = key.trim();
            let value = value.trim().trim_matches(|c| c == '"' || c == '\x27');
            if !key.is_empty() && std::env::var(key).is_err() {
                resolved.insert(key.to_string(), value.to_string());
            }
        }
    }
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
    let epoch_checks = std::env::var("WA_CORE_EPOCH").map(|value| value == "1").unwrap_or(false);
    let mut config = Config::new();
    config.wasm_component_model(true);
    // The guest's setjmp/longjmp (Lua errors, pcall) is wasm exception handling.
    config.wasm_exceptions(true);
    // `WA_CORE_EPOCH=1` compiles this run's guest with the epoch checks the *pooled* engine pays
    // (`core_pool::epoch_engine`), so what the pool's deadline costs the guest can be measured with
    // nothing else different between the two numbers (`scripts/bench-core-epoch.sh`). Off by
    // default: a one-shot run sets no deadline, and a check that can never fire is pure cost.
    if epoch_checks {
        config.epoch_interruption(true);
    }
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
        limits: MemoryLimits::default(),
        run_started: None,
        run_first_call_ms: None,
        script: None,
        digests: HashMap::new(),
        embedded_digests: HashMap::new(),
        profile: item_profile(),
    };
    let mut store = Store::new(&engine, state);
    if epoch_checks {
        // No deadline in a one-shot run: the "may run forever" the pool arms a store with (a store
        // whose deadline was never set is interrupted at its first instruction).
        store.set_epoch_deadline(u64::MAX);
    }
    let instantiate_started = Instant::now();
    let core = CoreComponent::instantiate(&mut store, &component, &linker)?;
    let instantiated = ms(instantiate_started);
    let run_started = Instant::now();
    let outcome = core.call_run(&mut store, script, script_args);
    let ran = ms(run_started);
    // One profile block per run when `WA_CORE_CALL_PROFILE=1`, in the shape a pooled item prints
    // (docs/KERNEL.md, "A2.6"). A one-shot run is the only way to see a *single* boot's crossings and
    // bytes from the CLI - and what `scripts/test-core-module-cache.sh` reads to prove the module
    // cache answered a load from the chunk instead of the text.
    {
        let first_ms = store.data().run_first_call_ms;
        store.data_mut().print_profile("run", ran, 1, true, first_ms);
    }
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

// ---- A2.3: the agent-core instance pool -------------------------------------------------------
//
// `--core-component` boots one interpreter for one script and exits, so every turn pays: compile
// (cached after the first), instantiate, the guest's Lua boot, and the reads the guest does for the
// registry's names and the shipping modules. `serve`, the subagent supervisor and the node threads
// each want to run many scripts, so this is the shape they need: a bounded pool of guest instances,
// each with its own native interpreter, `acquire -> run_script -> release`.
//
// Two decisions are worth stating because the obvious alternatives are wrong here.
//
// **One native interpreter per instance, not one shared behind host calls.** A pooled instance's
// native side is `Lua` + `Host`: a `lua_State` is single-threaded by construction (`Lua` is only
// `Send`), the upvalue-bound capabilities hold a raw pointer into that state's `Host`, and that
// `Host` owns the interpreter's own SQLite connection (a transaction one interpreter holds open must
// not be visible to, or rollback-able by, another - the crate split's note in `main.rs`). Sharing one
// state for every instance would mean a mutex around every `host.*` call, which is what a pool exists
// to avoid (batch-tools makes 29 079 of them), and one shared connection would put every instance's
// transactions in one transaction space. So: one interpreter and one connection per instance, bounded
// by `max_instances`, exactly like `serve` already gives each node-thread its own.
//
// **The snapshot is the immutable part of the guest's boot, not the live Lua state.** A live state
// cannot be cloned and cannot be re-used for a different script: globals, `package.loaded` and the
// stack are exactly the state a fresh `--core-component` run promises to discard, and a guest that
// kept them would leak one script's globals into the next. What *is* immutable for the life of an
// instance is what the guest asks the kernel once and would otherwise re-ask on every run: the
// capability registry's names, and the shipping Lua modules' sources (the native `EMBEDDED` table is
// built once at boot). Those are cached per instance in `glue.c` (see `snapshot_*` there), and a
// pooled run therefore re-reads neither. Measured below; what it does not cover is stated in
// `docs/KERNEL.md` ("A2.3").

/// The native interpreter a pool slot boots: `wa-host`'s own boot sequence - the capability registry
/// on a fresh `Lua`, its own SQLite connection and `EMBEDDED` - which is what `main.rs`'s `boot_state`
/// builds once per interpreter. The pool takes a factory rather than a `Lua` because every slot needs
/// its own (see the note above).
pub type NativeFactory = Arc<dyn Fn() -> Lua + Send + Sync>;

/// What a pool may create and what one instance may use.
#[derive(Clone, Copy, Debug)]
pub struct CorePoolConfig {
    /// Bounds of the pooling allocator: `max_instances` may not exceed `limits.component_instances`.
    pub limits: wa_kernel_runtime::components::PoolLimits,
    /// Instances the pool holds at once (idle + leased): one per concurrent caller.
    pub max_instances: usize,
    /// Instances created up front, so the first callers do not pay an instantiation each.
    pub warm: usize,
    /// How long `acquire` waits for a slot before answering `pool_exhausted`.
    pub acquire_timeout: Duration,
    /// Per-instance linear-memory cap (a `StoreLimits` limiter, so a guest cannot grow past it).
    pub memory_limit: usize,
    /// Guest-CPU budget of one work item (`call`) or one script run. The guest is interrupted when it
    /// reaches it, the item fails and its instance is recycled - a wedged guest costs one run, not a
    /// wedged node thread. `Duration::ZERO` means no deadline (what `--core-component` has).
    pub run_deadline: Duration,
}

/// The linear memory one pooled instance reserves when nothing says otherwise: a ceiling for one
/// memory slot of the pooling allocator (docs/KERNEL.md, "A2.5"). It is the knob that decides what a
/// node's wasm footprint costs, because the allocator reserves `limits.memories` slots of this size.
/// Measured guests hold 1-3 MiB (the report in docs/KERNEL.md has the run-by-run numbers); 64 MiB is
/// the headroom for a Lua-heavy turn, not a guess at the guest's size.
pub const DEFAULT_RESERVE_PER_INSTANCE: usize = 64 << 20;

/// What one work item may spend in the guest before the pool gives up on it.
///
/// Generous on purpose: the deadline counts guest instructions, and a turn spends most of its wall
/// time blocked inside a host call (the model), which the epoch does not count. A minute of Lua is a
/// broken run, not a slow one.
pub const DEFAULT_RUN_DEADLINE: Duration = Duration::from_secs(60);

impl Default for CorePoolConfig {
    fn default() -> Self {
        CorePoolConfig::pooled(8, 0, DEFAULT_RESERVE_PER_INSTANCE)
    }
}

impl CorePoolConfig {
    /// The pooling numbers for `max_instances` instances reserving `reserve_per_instance` bytes of
    /// linear memory each.
    ///
    /// `memories` is what the allocator reserves (`limits.memories * reserve` bytes of address space),
    /// so it is sized from the instance count instead of the fixed 40 slots a default of 8 instances
    /// leaves behind: a node with 16 node-threads gets `max_instances + 8` memory slots at this size,
    /// not 40 slots of 256 MiB. Every other bound keeps a spare over the instance count for the same
    /// reason `wa_kernel_runtime`'s default does - a bound that is too tight fails an acquire rather
    /// than a guest.
    pub fn pooled(max_instances: usize, warm: usize, reserve_per_instance: usize) -> Self {
        let instances = max_instances.max(1) as u32;
        let reserve = reserve_per_instance.max(16 << 20);
        let limits = wa_kernel_runtime::components::PoolLimits {
            component_instances: instances,
            core_instances: instances * 4 + 8,
            // One linear memory per component instance, plus the instantiation spares.
            memories: instances + 8,
            tables: instances + 8,
            stacks: instances * 4 + 8,
            gc_heaps: instances * 2 + 8,
            max_memory_bytes: reserve,
        };
        CorePoolConfig {
            limits,
            max_instances: max_instances.max(1),
            warm: warm.min(max_instances.max(1)),
            acquire_timeout: Duration::from_secs(5),
            memory_limit: reserve,
            run_deadline: DEFAULT_RUN_DEADLINE,
        }
    }

    /// The same pool with a different per-item guest-CPU budget (`Duration::ZERO` = none).
    pub fn with_run_deadline(mut self, budget: Duration) -> Self {
        self.run_deadline = budget;
        self
    }

    /// The same pool with a different linear-memory reserve per instance. The engine keeps the old
    /// reservation only if it was built before this call - a pool is built once, from its config.
    pub fn with_reserve_per_instance(mut self, bytes: usize) -> Self {
        self.limits.max_memory_bytes = bytes.max(16 << 20);
        self.memory_limit = self.limits.max_memory_bytes;
        self
    }

    /// Address space the pooling allocator reserves: every memory slot at its one-memory cap. This is
    /// what an operator's process pays (reserved, not resident) for a `core = "component"` node.
    pub fn reservation_bytes(&self) -> usize {
        self.limits.memories as usize * self.limits.max_memory_bytes
    }

    /// The reserve one instance gets (its largest linear memory).
    pub fn reserve_per_instance(&self) -> usize {
        self.limits.max_memory_bytes
    }

    /// Epoch ticks one work item may run for (`u64::MAX` = no deadline).
    pub fn deadline_ticks(&self) -> u64 {
        crate::core_pool::ticks_for(self.run_deadline)
    }
}

/// What the pool has done, in the terms a caller (and `/health`) asks about: how many instances
/// exist, how often a lease reused one, and how often it had to refuse.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PoolStats {
    pub created: usize,
    pub idle: usize,
    pub leased: usize,
    pub peak_leased: usize,
    pub acquisitions: u64,
    /// Acquisitions answered by an instance that had already run, i.e. by the snapshot.
    pub reuses: u64,
    pub exhausted: u64,
    pub runs: u64,
    /// Work items the guest's deadline interrupted (`0` unless a `run_deadline` is configured).
    pub deadlines: u64,
}

/// What a pooled run executes: the text itself (a turn from the supervisor, a fixture), or a file the
/// kernel reads exactly as `--core-component` reads it. The name is what the guest uses as the chunk
/// name, so a message from inside the script names the script.
pub enum Script<'a> {
    Source { name: &'a str, bytes: &'a [u8] },
    File(&'a str),
}

impl<'a> Script<'a> {
    /// A script that arrives as text, which is how `serve`, a subagent or a benchmark hands one over.
    pub fn source(name: &'a str, text: &'a str) -> Self {
        Script::Source { name, bytes: text.as_bytes() }
    }
}

/// One run's answer and what it cost.
#[derive(Clone, Copy, Debug)]
pub struct RunReport {
    /// The process exit code the same script would give: `0`, the script's error (`1`), or a
    /// `wasi:cli/exit` code.
    pub code: i32,
    pub host_calls: u64,
    pub streams_open: usize,
    /// Milliseconds from `run_script` to the run's first `host.*` call - the definition of "time to
    /// first Lua statement" here: the measuring fixture makes a host call its first statement.
    pub first_host_call_ms: Option<f64>,
    pub run_ms: f64,
    /// Linear memory the guest's instance holds after this run (`StoreLimits` accounting).
    pub memory_bytes: usize,
    /// Runs this instance has answered including this one: `1` is a fresh instance, `> 1` means the
    /// guest's boot was answered from the instance's snapshot.
    pub runs_on_instance: u64,
    /// This item booted the guest's Lua core (the first item after a lease was reset), i.e. it paid
    /// the module boot. A per-request boot makes this true for every item; a per-node-thread boot
    /// makes it true once per lease.
    pub booted: bool,
}

/// One work item's answer against an instance's **long-lived** core, and what it cost
/// (docs/KERNEL.md, "A2.5").
#[derive(Clone, Debug)]
pub struct CallReport {
    /// `Ok` is what the Lua function returned (`tostring`, empty for `nil`); `Err` is the script's own
    /// error text - the same words a native `call_string` answers with.
    pub answer: Result<String, String>,
    pub run_ms: f64,
    pub host_calls: u64,
    pub streams_open: usize,
    pub memory_bytes: usize,
    /// Items this instance has answered including this one.
    pub runs_on_instance: u64,
    /// This item booted the guest's Lua core, i.e. it paid the module boot (see [`RunReport::booted`]).
    pub booted: bool,
}

impl CallReport {
    fn exit_message(code: i32) -> String {
        format!("core_call_exited: the guest exited with code {code}")
    }
}

/// The guest's error text with its two structural cases turned back into the words a native call
/// answers: a name no module defines, and a core that could not boot (which the guest keeps and
/// repeats, so a broken module is never a silent empty answer).
fn guest_error(message: &str) -> String {
    if let Some(name) = message.strip_prefix("not-a-function:") {
        return format!("{name} is not a function");
    }
    if let Some(detail) = message.strip_prefix("boot:") {
        return format!("core_bridge_boot_failed: {detail}");
    }
    message.to_string()
}

struct Slot {
    store: Store<State>,
    core: CoreComponent,
    runs: u64,
    /// Has the guest's Lua core been booted since this instance last went back to the pool? A lease
    /// change resets the guest's `lua_State`, so the next item on the slot boots again - the number
    /// `/health` reports as `core.boots` counts *that*, and it is what says whether a node pays the
    /// module boot per request or per node thread (A2.7).
    booted: bool,
}

#[derive(Default)]
struct Pooled {
    idle: Vec<Slot>,
    created: usize,
    leased: usize,
    peak_leased: usize,
    acquisitions: u64,
    reuses: u64,
    exhausted: u64,
    runs: u64,
    deadlines: u64,
}

/// A bounded pool of agent-core instances over one compiled component and one pooling engine.
///
/// `acquire` hands out a lease; dropping the lease resets the instance (open streams ended, counters
/// cleared) and returns it to the pool. One instance serves one caller at a time, which is what makes
/// the `Send` this needs sound: nothing else touches a store while it is leased.
pub struct CoreComponentPool {
    engine: Engine,
    /// Advances this engine's epoch, which is what a store's deadline counts. Never read: it is held
    /// because dropping it is what stops the ticker thread. `None` on a pool with no deadline, whose
    /// engine has no epoch interruption and therefore no ticker to run (`build`).
    #[allow(dead_code)]
    ticker: Option<crate::core_pool::EpochTicker>,
    component: Component,
    compiled_from: &'static str,
    /// The linker touches no per-instance state, but it is behind a mutex because instantiating is
    /// the only moment several callers would otherwise share it at once (0.2 ms, on a pool miss).
    linker: Mutex<Linker<State>>,
    factory: NativeFactory,
    config: CorePoolConfig,
    inner: Mutex<Pooled>,
    ready: Condvar,
}

/// A leased instance. It cannot be cloned and it cannot outlive the pool; dropping it is `release`.
pub struct CoreInstance<'a> {
    pool: &'a CoreComponentPool,
    slot: Option<Slot>,
}

impl CoreComponentPool {
    /// Compile `wasm` once (through the node's own compiled-code cache) on a pooling engine.
    pub fn new(factory: NativeFactory, wasm: &[u8], config: CorePoolConfig) -> wasmtime::Result<Self> {
        Self::build(factory, wasm, config)
    }

    /// The same, reading the component from disk.
    pub fn from_path(factory: NativeFactory, wasm: &std::path::Path, config: CorePoolConfig) -> wasmtime::Result<Self> {
        let bytes = std::fs::read(wasm).map_err(|e| wasmtime::Error::msg(format!("read {}: {e}", wasm.display())))?;
        Self::build(factory, &bytes, config)
    }

    fn build(factory: NativeFactory, wasm: &[u8], mut config: CorePoolConfig) -> wasmtime::Result<Self> {
        if config.max_instances == 0 {
            return Err(wasmtime::Error::msg("pool_config_invalid: max_instances must be at least 1"));
        }
        if config.max_instances > config.limits.component_instances as usize {
            return Err(wasmtime::Error::msg(format!(
                "pool_config_invalid: max_instances {} exceeds the pooling allocator's {} component instances",
                config.max_instances, config.limits.component_instances
            )));
        }
        config.warm = config.warm.min(config.max_instances);
        // The deadline decides the engine, not the other way round (docs/KERNEL.md, "A2.5"):
        // `epoch_interruption` makes wasmtime compile an epoch check into every function entry and
        // loop back-edge, and this guest is one loop-heavy interpreter. Measured on a pure-Lua loop,
        // that tax is ~1.3x the guest's own time (`scripts/bench-core-epoch.sh`), i.e. larger than
        // running the interpreter in wasm at all. A pool configured with **no** deadline has nothing
        // to interrupt, so it takes the same pooling engine the kernel builds for callers with no run
        // budget - the deadline knob is then a cost a caller opts into, not one every turn pays.
        let (engine, ticker) = if config.run_deadline.is_zero() {
            let engine = wa_kernel_runtime::components::pooled_engine(&config.limits)
                .map_err(|e| wasmtime::Error::msg(format!("pool_engine_failed: {e:#}")))?;
            (engine, None)
        } else {
            let (engine, ticker) = crate::core_pool::epoch_engine(&config.limits)
                .map_err(|e| wasmtime::Error::msg(format!("pool_engine_failed: {e:#}")))?;
            (engine, Some(ticker))
        };
        let (component, compiled_from) = load_component(&engine, wasm)?;
        // The pool answers work items through the guest's long-lived entry points (docs/KERNEL.md,
        // "A2.5"). A component built before them exports `run` alone: refuse it here, naming the fix,
        // rather than failing on the first acquire with a wasmtime link error about `call`.
        let exports: Vec<String> = component.component_type().exports(&engine).map(|(name, _)| name.to_string()).collect();
        for required in ["call", "reset"] {
            if !exports.iter().any(|name| name == required) {
                return Err(wasmtime::Error::msg(format!(
                    "core_component_outdated: the agent-core component does not export {required} (it exports: {}); \
                     rebuild it with bash scripts/build-agent-core.sh",
                    exports.join(", ")
                )));
            }
        }
        let mut linker: Linker<State> = Linker::new(&engine);
        // wasi:cli/exit `exit-with-code` is always linked since wasmtime 46 (no LinkOptions switch).
        wasmtime_wasi::p2::add_to_linker_sync(&mut linker)?;
        CoreComponent::add_to_linker::<State, HasSelf<State>>(&mut linker, |state| state)?;
        let pool = CoreComponentPool {
            engine,
            ticker,
            component,
            compiled_from,
            linker: Mutex::new(linker),
            factory,
            config,
            inner: Mutex::new(Pooled::default()),
            ready: Condvar::new(),
        };
        let mut warm = Vec::with_capacity(config.warm);
        for _ in 0..config.warm {
            warm.push(pool.instantiate()?);
        }
        {
            let mut inner = pool.inner.lock().expect("pool lock");
            inner.created += warm.len();
            inner.idle.extend(warm);
        }
        Ok(pool)
    }

    /// One instance: its own native interpreter, its own store, the guest instantiated and not run.
    fn instantiate(&self) -> wasmtime::Result<Slot> {
        let mut store = Store::new(&self.engine, self.state());
        store.limiter(|state| &mut state.limits);
        // A work item that reaches its store's epoch delta is interrupted here. The message is the
        // pool's own, so a caller can tell "this guest is wedged" from any other trap.
        store.epoch_deadline_callback(|_| Err(wasmtime::Error::msg(DEADLINE_TRAP)));
        // Nothing runs before the first item arms its deadline; an unarmed store must not trap.
        store.set_epoch_deadline(u64::MAX);
        let started = Instant::now();
        let core = {
            let linker = self.linker.lock().expect("pool linker lock");
            CoreComponent::instantiate(&mut store, &self.component, &linker)?
        };
        let _ = started;
        Ok(Slot { store, core, runs: 0, booted: false })
    }

    /// Give the store its budget for the work item about to run. The deadline is relative to the
    /// epoch the ticker is at now, so this is called once per item, never once per instance.
    fn arm(&self, store: &mut Store<State>) {
        store.set_epoch_deadline(self.config.deadline_ticks());
    }

    /// The state a slot starts with: fresh WASI (stdio inherited, cwd preopened as `.`, as the
    /// one-shot run has it) and a native interpreter from the factory.
    fn state(&self) -> State {
        let mut wasi = WasiCtxBuilder::new();
        wasi.inherit_stdio().inherit_env();
        // A fresh component instance must not take the process down because its own directory is
        // gone; the one-shot run reports that failure, and a pool reports it once per instantiation.
        let _ = wasi.preopened_dir(".", ".", FsPerms::ReadWrite);
        State {
            wasi: wasi.build(),
            table: ResourceTable::new(),
            native: Native((self.factory)()),
            calls: 0,
            streams: HashMap::new(),
            serial: 0,
            limits: MemoryLimits { bytes: 0, cap: self.config.memory_limit },
            run_started: None,
            run_first_call_ms: None,
            script: None,
            digests: HashMap::new(),
            embedded_digests: HashMap::new(),
            profile: item_profile(),
        }
    }

    /// Lease an instance: an idle one (the snapshot is warm), a new one while the pool is below its
    /// bound, else wait up to the configured timeout and answer `pool_exhausted`.
    pub fn acquire(&self) -> wasmtime::Result<CoreInstance<'_>> {
        let deadline = Instant::now() + self.config.acquire_timeout;
        loop {
            let mut inner = self.inner.lock().expect("pool lock");
            if let Some(slot) = inner.idle.pop() {
                inner.leased += 1;
                inner.acquisitions += 1;
                inner.reuses += 1;
                inner.peak_leased = inner.peak_leased.max(inner.leased);
                drop(inner);
                return Ok(CoreInstance { pool: self, slot: Some(slot) });
            }
            if inner.created < self.config.max_instances {
                // Reserve the slot before building it, so two callers cannot both take the last one.
                inner.created += 1;
                inner.leased += 1;
                inner.acquisitions += 1;
                inner.peak_leased = inner.peak_leased.max(inner.leased);
                drop(inner);
                return match self.instantiate() {
                    Ok(slot) => Ok(CoreInstance { pool: self, slot: Some(slot) }),
                    Err(error) => {
                        let mut inner = self.inner.lock().expect("pool lock");
                        inner.created -= 1;
                        inner.leased -= 1;
                        Err(error)
                    }
                };
            }
            let now = Instant::now();
            if now >= deadline {
                inner.exhausted += 1;
                return Err(wasmtime::Error::msg(format!(
                    "pool_exhausted: {} instances are leased and none came back within {} ms",
                    inner.leased,
                    self.config.acquire_timeout.as_millis()
                )));
            }
            let (_guard, waited) = self.ready.wait_timeout(inner, deadline - now).expect("pool condvar");
            if waited.timed_out() {
                // Loop once more: the timeout may have fired exactly as a lease was returned.
                continue;
            }
        }
    }

    /// Lease an instance only if one is free right now; never waits and never creates.
    pub fn try_acquire(&self) -> Option<CoreInstance<'_>> {
        let mut inner = self.inner.lock().expect("pool lock");
        let slot = inner.idle.pop()?;
        inner.leased += 1;
        inner.acquisitions += 1;
        inner.reuses += 1;
        inner.peak_leased = inner.peak_leased.max(inner.leased);
        drop(inner);
        Some(CoreInstance { pool: self, slot: Some(slot) })
    }

    /// Create idle instances and block until the pool holds `n` of them (used to pre-fill a node's
    /// pool before it takes traffic, and by the measurements to separate instantiation from a run).
    pub fn warm(&self, n: usize) -> wasmtime::Result<usize> {
        let target = n.min(self.config.max_instances);
        let mut made = 0;
        loop {
            let reserve = {
                let inner = self.inner.lock().expect("pool lock");
                let held = inner.idle.len() + inner.leased;
                if held >= target {
                    return Ok(made);
                }
                inner.created < self.config.max_instances
            };
            if !reserve {
                return Ok(made);
            }
            {
                let mut inner = self.inner.lock().expect("pool lock");
                inner.created += 1;
            }
            match self.instantiate() {
                Ok(slot) => {
                    made += 1;
                    self.inner.lock().expect("pool lock").idle.push(slot);
                }
                Err(error) => {
                    self.inner.lock().expect("pool lock").created -= 1;
                    return Err(error);
                }
            }
        }
    }

    pub fn stats(&self) -> PoolStats {
        let inner = self.inner.lock().expect("pool lock");
        PoolStats {
            created: inner.created,
            idle: inner.idle.len(),
            leased: inner.leased,
            peak_leased: inner.peak_leased,
            acquisitions: inner.acquisitions,
            reuses: inner.reuses,
            exhausted: inner.exhausted,
            runs: inner.runs,
            deadlines: inner.deadlines,
        }
    }

    pub fn config(&self) -> CorePoolConfig {
        self.config
    }

    /// `"cache"` or `"compiled"`: where the compiled component came from (docs/KERNEL.md "A2.1").
    pub fn compiled_from(&self) -> &'static str {
        self.compiled_from
    }
}

impl CoreInstance<'_> {
    /// Run `script` on this instance, exactly as `--core-component` runs it (same guest, same
    /// bridge, same refusal texts), and report what it cost.
    pub fn run_script(&mut self, script: Script<'_>, args: &[String]) -> wasmtime::Result<RunReport> {
        let (report, error) = self.run_script_outcome(script, args)?;
        if let Some(message) = error {
            eprintln!("lua error: {message}");
        }
        Ok(report)
    }

    /// One work item against the instance's **long-lived** `lua_State` (docs/KERNEL.md, "A2.5"):
    /// call the global `name` with `args` and answer what it returned.
    ///
    /// The first call boots the Lua core; every later call on the same lease reuses it, which is what
    /// makes a node thread pay `lua/core/server.lua`'s module bodies once instead of once per request.
    /// The item gets the store's deadline before the guest runs, and a trap leaves the instance
    /// recycled rather than handed to the next caller.
    ///
    /// Errors:
    /// * `Ok(CallReport)` - the guest answered; `answer` is `Err` with the script's own message when
    ///   the item raised (a Lua error is an answer, not a trap),
    /// * `Err` - the store cannot serve another item (a trap, the deadline, or a `wasi:cli/exit`),
    ///   and the instance was retired.
    pub fn call_entry(&mut self, name: &str, args: &[String]) -> wasmtime::Result<CallReport> {
        let pool = self.pool;
        let started = Instant::now();
        let slot = self.slot.as_mut().ok_or_else(|| wasmtime::Error::msg("core_instance_released: this lease was already released"))?;
        {
            let data = slot.store.data_mut();
            data.calls = 0;
            data.run_first_call_ms = None;
            data.run_started = Some(started);
            // A run's script text is only for `run`; a work item is a call into the already-booted core.
            data.script = None;
            data.abort_streams();
        }
        slot.runs += 1;
        let booted = !slot.booted;
        slot.booted = true;
        let arm_started = slot.store.data().profile.is_some().then(Instant::now);
        pool.arm(&mut slot.store);
        if let Some(arm_started) = arm_started {
            let elapsed = arm_started.elapsed().as_nanos() as u64;
            if let Some(profile) = slot.store.data_mut().profile.as_mut() {
                profile.arm_ns += elapsed;
            }
        }
        let outcome = slot.core.call_call(&mut slot.store, name, args);
        let run_ms = ms(started);
        let data = slot.store.data();
        let report = CallReport {
            answer: Ok(String::new()),
            run_ms,
            host_calls: data.calls,
            streams_open: data.streams.len(),
            memory_bytes: data.limits.bytes,
            runs_on_instance: slot.runs,
            booted,
        };
        let first_ms = slot.store.data().run_first_call_ms;
        let runs = slot.runs;
        slot.store.data_mut().print_profile("call", run_ms, runs, booted, first_ms);
        {
            let mut inner = pool.inner.lock().expect("pool lock");
            inner.runs += 1;
        }
        match outcome {
            Ok(Ok(text)) => Ok(CallReport { answer: Ok(text), ..report }),
            Ok(Err(message)) => Ok(CallReport { answer: Err(guest_error(&message)), ..report }),
            Err(error) => match error.downcast_ref::<wasmtime_wasi::I32Exit>() {
                Some(exit) => Ok(CallReport {
                    answer: Err(CallReport::exit_message(exit.0)),
                    ..report
                }),
                None => {
                    if is_run_deadline(&error) {
                        pool.inner.lock().expect("pool lock").deadlines += 1;
                    }
                    self.retire();
                    Err(error)
                }
            },
        }
    }

    /// Drop the instance's long-lived Lua state, so the next `call` boots a fresh one. The pool calls
    /// this when a lease changes hands: a retired node thread's interpreter - its `local agent`, its
    /// pending `/bind` table, its `package.loaded` - must not reach whoever acquires the slot next.
    pub fn reset(&mut self) -> wasmtime::Result<()> {
        let Some(slot) = self.slot.as_mut() else { return Ok(()) };
        // The next item on this slot boots a fresh `lua_State`, which is a boot again even though the
        // instance is the same one (the compiled-module cache is what makes it cheap, not free).
        slot.booted = false;
        slot.core.call_reset(&mut slot.store)
    }

    /// The same run, with the guest's own failure text handed back instead of printed.
    ///
    /// `run_script` is the CLI and benchmark shape (a failed script says so on stderr and reports
    /// `code: 1`). A caller that answers a request needs the message itself - `serve` on the
    /// component core turns a raised Lua error into the `Err` half of `call_string` - and a caller
    /// whose guest *reports* through its exit status must not have every answer logged as a Lua
    /// error. A trap is still an `Err`: the store cannot serve another run.
    pub fn run_script_outcome(&mut self, script: Script<'_>, args: &[String]) -> wasmtime::Result<(RunReport, Option<String>)> {
        let pool = self.pool;
        let slot = self.slot.as_mut().ok_or_else(|| wasmtime::Error::msg("core_instance_released: this lease was already released"))?;
        let started = Instant::now();
        let (name, source) = match script {
            Script::Source { name, bytes } => (name.to_string(), Some(bytes.to_vec())),
            Script::File(path) => (path.to_string(), None),
        };
        {
            let data = slot.store.data_mut();
            // Reset per-run state: an instance serves many runs, and every one of them must look
            // like the fresh process a `--core-component` run is.
            data.calls = 0;
            data.run_first_call_ms = None;
            data.run_started = Some(started);
            data.script = source.map(|bytes| (name.clone(), bytes));
            data.abort_streams();
        }
        slot.runs += 1;
        let booted = !slot.booted;
        slot.booted = true;
        let arm_started = slot.store.data().profile.is_some().then(Instant::now);
        pool.arm(&mut slot.store);
        if let Some(arm_started) = arm_started {
            let elapsed = arm_started.elapsed().as_nanos() as u64;
            if let Some(profile) = slot.store.data_mut().profile.as_mut() {
                profile.arm_ns += elapsed;
            }
        }
        let outcome = slot.core.call_run(&mut slot.store, &name, args);
        let run_ms = ms(started);
        let data = slot.store.data();
        let report = RunReport {
            code: 0,
            host_calls: data.calls,
            streams_open: data.streams.len(),
            first_host_call_ms: data.run_first_call_ms,
            run_ms,
            memory_bytes: data.limits.bytes,
            runs_on_instance: slot.runs,
            booted,
        };
        let first_ms = slot.store.data().run_first_call_ms;
        let runs = slot.runs;
        slot.store.data_mut().print_profile("run", run_ms, runs, booted, first_ms);
        {
            let mut inner = pool.inner.lock().expect("pool lock");
            inner.runs += 1;
        }
        match outcome {
            Ok(Ok(())) => Ok((report, None)),
            Ok(Err(message)) => Ok((RunReport { code: 1, ..report }, Some(message))),
            Err(error) => match error.downcast_ref::<wasmtime_wasi::I32Exit>() {
                Some(exit) => Ok((RunReport { code: exit.0, ..report }, None)),
                // A trap leaves the store unusable, so the instance is dropped instead of being
                // handed to the next caller - and the pool's count of what it created stays true.
                None => {
                    if is_run_deadline(&error) {
                        pool.inner.lock().expect("pool lock").deadlines += 1;
                    }
                    self.retire();
                    Err(error)
                }
            },
        }
    }

    /// The native interpreter this instance answers its guest's `host.*` calls from.
    ///
    /// It is the interpreter that owns the instance's database connection, so a caller that has to
    /// close a transaction a failed call left open (`host::rollback_if_open`) asks for it here
    /// rather than opening a second connection to the same WAL file.
    pub fn native(&self) -> Option<&Lua> {
        self.slot.as_ref().map(|slot| &slot.store.data().native.0)
    }

    /// Drop a leased instance that cannot serve another run (a trapped store) and give its slot back:
    /// the next `acquire` builds a fresh instance instead of inheriting a broken one.
    fn retire(&mut self) {
        let Some(slot) = self.slot.take() else { return };
        drop(slot);
        let mut inner = self.pool.inner.lock().expect("pool lock");
        inner.created = inner.created.saturating_sub(1);
        inner.leased = inner.leased.saturating_sub(1);
        drop(inner);
        self.pool.ready.notify_one();
    }

    /// The runs this instance has answered: `0` before its first, `> 1` once the snapshot is warm.
    pub fn runs(&self) -> u64 {
        self.slot.as_ref().map(|slot| slot.runs).unwrap_or(0)
    }

    /// Give the instance back now (dropping the lease does the same thing).
    pub fn release(mut self) {
        self.return_to_pool();
    }

    /// End whatever the run left behind and put the slot back. Dropping the store would also work,
    /// but then the guest's boot snapshot would be paid again on the next acquire - the whole point
    /// of the pool.
    fn return_to_pool(&mut self) {
        let Some(mut slot) = self.slot.take() else { return };
        {
            let data = slot.store.data_mut();
            data.abort_streams();
            data.calls = 0;
            data.run_started = None;
            data.run_first_call_ms = None;
            data.script = None;
        }
        // The guest's long-lived core belongs to the lease, not to the instance (docs/KERNEL.md,
        // "A2.5"): whoever acquires this slot next gets a fresh `lua_State`, exactly as a newly spawned
        // node thread gets a fresh interpreter natively. A reset that fails leaves a Lua state nobody
        // can vouch for, so the slot is retired instead.
        slot.booted = false;
        let reset = slot.core.call_reset(&mut slot.store);
        let mut rejected = None;
        {
            let mut inner = self.pool.inner.lock().expect("pool lock");
            inner.leased = inner.leased.saturating_sub(1);
            if reset.is_ok() {
                inner.idle.push(slot);
            } else {
                inner.created = inner.created.saturating_sub(1);
                rejected = Some(slot);
            }
        }
        drop(rejected);
        self.pool.ready.notify_one();
    }
}

impl Drop for CoreInstance<'_> {
    fn drop(&mut self) {
        self.return_to_pool();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
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
            limits: MemoryLimits::default(),
            run_started: None,
            run_first_call_ms: None,
            script: None,
            digests: HashMap::new(),
            embedded_digests: HashMap::new(),
            profile: item_profile(),
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

    // ---- A2.3: the instance pool ---------------------------------------------------------------
    //
    // These run the real agent-core component, so they need it built (`bash scripts/build-agent-core.sh`,
    // which needs wasi-sdk). Without it each test says it skipped and returns - a skipped test is
    // reported as skipped, never as a pass.

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../benchmarks/agent-core-pool/fixtures");
    /// The module the measured fixture loads through `EMBEDDED`.
    const FIXTURE_MODULE: &str = include_str!("../../../benchmarks/agent-core-pool/fixtures/pool-fixture-module.lua");

    fn agent_core_wasm() -> Option<std::path::PathBuf> {
        let path = std::env::var("WA_AGENT_CORE_WASM").ok().map(std::path::PathBuf::from).unwrap_or_else(|| {
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../components/agent-core/target/wasm32-wasip2/release/agent_core.wasm")
        });
        if path.is_file() {
            return Some(path);
        }
        eprintln!(
            "SKIP: agent-core is not built at {} - run `bash scripts/build-agent-core.sh` (needs wasi-sdk) \
             or set WA_AGENT_CORE_WASM to the .wasm",
            path.display()
        );
        None
    }

    fn fixture(name: &str) -> String {
        let path = std::path::Path::new(FIXTURES).join(name);
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
    }

    /// A scratch home, not the operator's: the boot reads `~/.wasm-agent/env`, and a test must not
    /// read (or write) the node it happens to run on. `CARGO_TARGET_DIR` when the harness sets one,
    /// else the platform temp directory.
    ///
    /// Every one of these tests takes [`heavy`] first. A pool is the heaviest thing this test binary
    /// builds - a pooling engine (its slot reservation), a compile of a 388 kB guest the first time, up
    /// to eight native interpreters, and four wasm instances running at once - and `http_transport`'s
    /// streaming tests assert on 250 ms/500 ms wall-clock budgets in the *same process*. Seven pools
    /// live at once is what a loaded machine turns into those tests timing out (a23fix); one at a time
    /// is all these tests need to prove what they prove.
    static HEAVY: Mutex<()> = Mutex::new(());

    /// At most one pool is alive in the process at a time, so the pool's cost is spent once and the
    /// other tests in this binary keep their scheduling headroom. Poisoning is not a failure here: a
    /// panicking test has already failed, and the lock is only an isolation device.
    fn heavy() -> std::sync::MutexGuard<'static, ()> {
        HEAVY.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// The modules the clock tests (and the pool, once, for them) need inside a state: the checkout's
    /// `lua/core/platform.lua` and the JSON module it loads, keyed the way `dofile` asks for them. Read
    /// from the checkout, not embedded in the binary, so the files the gate runs are the files tested.
    fn clock_modules() -> Vec<(String, String)> {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        ["lua/core/platform.lua", "lua/vendor/json.lua"]
            .iter()
            .map(|name| {
                let path = root.join(name);
                let source = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
                ((*name).to_string(), source)
            })
            .collect()
    }

    /// The pool a test uses: the real component, a native interpreter per instance (the shipping
    /// boot's shape: registry + own connection + `EMBEDDED`), one slot unless a test says otherwise.
    fn pool(max_instances: usize, warm: usize, acquire_timeout: Duration) -> Option<CoreComponentPool> {
        let wasm = std::fs::read(agent_core_wasm()?).expect("read agent-core");
        // A scratch home, not the operator's: the boot reads `~/.wasm-agent/env`, and a test must not
        // read (or write) the node it happens to run on. `CARGO_TARGET_DIR` when the harness sets one,
        // else the platform temp directory.
        let home = std::env::var("CARGO_TARGET_DIR").unwrap_or_else(|_| std::env::temp_dir().to_string_lossy().into_owned());
        let home = format!("{home}/wa-core-pool-test-home");
        let _ = std::fs::create_dir_all(&home);
        let clock = clock_modules();
        let factory: NativeFactory = Arc::new(move || {
            let mut embedded: Vec<(&str, &str)> = vec![("bench/pool-fixture-module.lua", FIXTURE_MODULE)];
            embedded.extend(clock.iter().map(|(key, source)| (key.as_str(), source.as_str())));
            boot_native_state(&home, ":memory:", &[], &embedded).expect("boot the native state")
        });
        let config = CorePoolConfig { max_instances, warm, acquire_timeout, ..CorePoolConfig::default() };
        Some(CoreComponentPool::new(factory, &wasm, config).expect("the pool builds"))
    }

    /// `acquire -> run_script -> release` on a pooling engine: the run answers like the same script in
    /// a one-shot component, the report carries the run's cost, and the lease comes back to the pool.
    #[test]
    fn a_pooled_instance_runs_a_script_and_reports_what_it_cost() {
        let _heavy = heavy();
        let Some(pool) = pool(1, 0, Duration::from_secs(5)) else { return };
        let script = fixture("first-statement.lua");
        let mut lease = pool.acquire().expect("acquire an instance");
        let report = lease.run_script(Script::source("first-statement.lua", &script), &[]).expect("run the fixture");
        assert_eq!(report.code, 0, "the fixture must pass in a pooled instance");
        assert_eq!(report.runs_on_instance, 1, "a fresh instance's first run");
        assert!(report.host_calls > 0, "the fixture makes host calls");
        assert!(report.memory_bytes > 0, "the limiter must see the guest's memory");
        assert!(report.first_host_call_ms.is_some(), "the run's first host call is timed");
        assert_eq!(report.streams_open, 0);
        drop(lease);
        let stats = pool.stats();
        assert_eq!(stats.created, 1, "one instance was needed for one caller");
        assert_eq!(stats.idle, 1, "the lease went back to the pool");
        assert_eq!(stats.leased, 0);
        assert_eq!(stats.runs, 1);
    }

    /// The same lease can run twice, and the second run starts with a fresh interpreter: a global one
    /// run set must not be visible to the next. The instance (and its snapshot) is reused - the state
    /// is not.
    #[test]
    fn a_reused_instance_keeps_each_run_a_fresh_state() {
        let _heavy = heavy();
        let Some(pool) = pool(1, 0, Duration::from_secs(5)) else { return };
        let script = fixture("fresh-state.lua");
        let mut lease = pool.acquire().expect("acquire an instance");
        assert_eq!(lease.run_script(Script::source("fresh-state.lua", &script), &[]).expect("first run").code, 0);
        let second = lease.run_script(Script::source("fresh-state.lua", &script), &[]).expect("second run on the same instance");
        assert_eq!(second.code, 0, "a reused instance must not leak the previous run's globals");
        assert_eq!(second.runs_on_instance, 2, "the second run reuses the instance");
    }

    /// N callers at once: each gets its own instance (no store is ever touched by two callers), and the
    /// pool creates exactly N of them. The barrier holds every lease at once, so "peak leased" is the
    /// number of simultaneous callers and not a race the scheduler can shrink.
    #[test]
    fn parallel_acquires_each_get_their_own_instance() {
        const CALLERS: usize = 4;
        let _heavy = heavy();
        let Some(pool) = pool(CALLERS, 0, Duration::from_secs(20)) else { return };
        let script = fixture("parallel.lua");
        let script = &script;
        let barrier = std::sync::Barrier::new(CALLERS);
        let reports: Vec<RunReport> = std::thread::scope(|scope| {
            let handles: Vec<_> = (0..CALLERS)
                .map(|_| {
                    let pool = &pool;
                    let barrier = &barrier;
                    scope.spawn(move || {
                        let mut lease = pool.acquire().expect("acquire an instance");
                        // Every caller holds its lease here: the four leases must be four instances.
                        barrier.wait();
                        lease.run_script(Script::source("parallel.lua", script), &[]).expect("run the fixture")
                    })
                })
                .collect();
            handles.into_iter().map(|handle| handle.join().expect("caller thread")).collect()
        });
        assert!(reports.iter().all(|report| report.code == 0), "every concurrent run must pass");
        assert!(
            reports.iter().all(|report| report.runs_on_instance == 1),
            "a concurrent caller must get an instance no other caller has used: {:?}",
            reports.iter().map(|r| r.runs_on_instance).collect::<Vec<_>>()
        );
        let stats = pool.stats();
        assert_eq!(stats.created, CALLERS);
        assert_eq!(stats.peak_leased, CALLERS);
        assert_eq!(stats.leased, 0, "every lease was returned");
        assert_eq!(stats.idle, CALLERS);
        assert_eq!(stats.runs, CALLERS as u64);
    }

    /// A pool that is fully leased refuses with a reason after its timeout, and hands the released
    /// instance to the next caller - a refusal is not a lost slot.
    #[test]
    fn an_exhausted_pool_refuses_and_recovers() {
        let _heavy = heavy();
        let Some(pool) = pool(1, 0, Duration::from_millis(150)) else { return };
        let held = pool.acquire().expect("the only instance");
        let started = Instant::now();
        let error = match pool.acquire() {
            Ok(_) => panic!("a second caller must not get the leased instance"),
            Err(error) => error,
        };
        assert!(error.to_string().starts_with("pool_exhausted"), "{error}");
        assert!(started.elapsed() >= Duration::from_millis(140), "acquire must wait its timeout: {:?}", started.elapsed());
        assert_eq!(pool.stats().exhausted, 1);
        drop(held);
        let mut lease = pool.acquire().expect("the released instance must be handed out");
        assert_eq!(lease.runs(), 0);
        let script = fixture("fresh-state.lua");
        assert_eq!(lease.run_script(Script::source("fresh-state.lua", &script), &[]).expect("run").code, 0);
    }

    /// A pool cannot hold more instances than the pooling allocator reserves: the configuration is
    /// refused instead of failing on the ninth acquire, at run time, on a node that is serving.
    #[test]
    fn a_pool_larger_than_its_pooling_allocator_is_refused() {
        let factory: NativeFactory = Arc::new(|| Lua::new());
        let config = CorePoolConfig { max_instances: 9, ..CorePoolConfig::default() };
        let error = match CoreComponentPool::new(factory, b"", config) {
            Ok(_) => panic!("a pool above the allocator's bound must not build"),
            Err(error) => error,
        };
        assert!(error.to_string().starts_with("pool_config_invalid"), "{error}");
    }

    /// A warmed pool costs nothing to acquire from: `warm` creates the instances up front, so the first
    /// callers pay no instantiation - and a warm instance starts with no run behind it.
    #[test]
    fn a_warm_pool_hands_out_instances_without_creating_them() {
        let _heavy = heavy();
        let Some(pool) = pool(2, 2, Duration::from_secs(5)) else { return };
        let stats = pool.stats();
        assert_eq!(stats.created, 2);
        assert_eq!(stats.idle, 2);
        let mut lease = pool.acquire().expect("acquire");
        assert_eq!(lease.runs(), 0, "a warmed instance has not run anything");
        let script = fixture("fresh-state.lua");
        assert_eq!(lease.run_script(Script::source("fresh-state.lua", &script), &[]).expect("run").code, 0);
        assert_eq!(pool.stats().reuses, 1);
    }

    // ---- the node's own zone -------------------------------------------------------------------
    //
    // `host.local_tz` is a kernel call, not a capability: the guest's C runtime is wasi-libc, which
    // ships no zone database, so the offset has to come from the node. The tests below fix the two
    // properties that matter - the guest sees the call, and the same instant reads identically on
    // both cores - and the offset's *value* is the same C runtime function the native core calls, so
    // there is nothing to compare against a second implementation.

    /// The instant both cores are asked about: 2026-01-15T12:00:00Z, fixed so two runs compare equal.
    const CLOCK_EPOCH: i64 = 1_768_478_400;

    /// One line of the fields a caller reads, formatted identically on both sides so a diff is the
    /// answer. `zone` is `none` when the platform does not name it, which is a fact about the machine
    /// and not something either core may paper over.
    const CLOCK_TEXT: &str = "local platform = dofile('lua/core/platform.lua') \
        function clock_text(epoch) local c = platform.local_clock(tonumber(epoch)) \
        return table.concat({tostring(c.epoch), tostring(c.utc_offset_minutes), tostring(c.utc_offset), \
        tostring(c.zone or 'none'), tostring(c.weekday), tostring(c.local_iso), tostring(c.utc_iso)}, ' | ') end";

    /// The same line, computed inside the guest, compared with the native core's line, plus the two
    /// things only the host can tell the guest: the zone's identifier and where it was read from.
    const CLOCK_GUEST: &str = r#"
local platform = dofile('lua/core/platform.lua')
local epoch = tonumber(args[1])
local c = platform.local_clock(epoch)
local text = table.concat({tostring(c.epoch), tostring(c.utc_offset_minutes), tostring(c.utc_offset),
  tostring(c.zone or 'none'), tostring(c.weekday), tostring(c.local_iso), tostring(c.utc_iso)}, ' | ')
assert(text == args[2], 'the component core must read the same instant as the native one:\n  guest:  ' ..
  text .. '\n  native: ' .. tostring(args[2]))
assert(host.local_tz ~= nil, 'this kernel answers host.local_tz, so the guest must see it')
local tz = host.local_tz(epoch)
assert(tz.zone_source == args[3], 'the host must say where the zone came from: ' .. tostring(tz.zone_source))
assert(tostring(tz.zone_id or 'none') == args[4], 'the host zone id: ' .. tostring(tz.zone_id))
assert(c.zone_id == tz.zone_id and c.zone_source == tz.zone_source, 'the clock must carry the host zone')
-- Per call, not a boot snapshot: half a year later is a second question with its own answer (the same
-- answer in a zone without DST, a different one in a zone with it).
local later = host.local_tz(epoch + 26 * 7 * 24 * 3600)
assert(tonumber(later.utc_offset_minutes) ~= nil, 'the host must answer a second instant')
"#;

    /// The kernel's own call is listed for the guest, and a state that cannot answer it says so instead
    /// of answering UTC.
    #[test]
    fn the_node_zone_is_a_kernel_call_and_never_a_silent_utc() {
        let mut state = state();
        let names = match state.call("__names".to_string(), Vec::new()) {
            Ok(values) => match values.into_iter().next() {
                Some(Value::Bytes(bytes)) => String::from_utf8_lossy(&bytes).into_owned(),
                other => panic!("__names must answer bytes, got {other:?}"),
            },
            Err(error) => panic!("__names: {error}"),
        };
        for name in KERNEL_CALLS {
            assert!(names.lines().any(|line| line == *name), "{name} must be listed in __names: {names}");
        }
        // This fixture's interpreter has no `dofile` and no platform module. The call must fail with the
        // interpreter's own words: an empty answer or a `+00:00` here would be the defect itself.
        let error = state.call("local_tz".to_string(), vec![Value::Integer(CLOCK_EPOCH)]).expect_err("no module, no answer");
        assert!(error.starts_with("local_tz_failed: "), "{error}");
        // A caller that passes something that is not an instant is refused by name, not coerced to now.
        let error = state.call("local_tz".to_string(), vec![Value::Boolean(true)]).expect_err("a boolean is not an epoch");
        assert!(error.starts_with("local_tz_invalid_epoch"), "{error}");
    }

    /// `local_tz` on a real native interpreter: the fields, the shape the bridge carries, and the OS's
    /// own identifier beside the C runtime's offset.
    #[test]
    fn the_kernel_answers_the_node_zone_with_the_runtime_offset_and_the_os_name() {
        let _heavy = heavy();
        let home = std::env::var("CARGO_TARGET_DIR").unwrap_or_else(|_| std::env::temp_dir().to_string_lossy().into_owned());
        let home = format!("{home}/wa-local-tz-test-home");
        let _ = std::fs::create_dir_all(&home);
        let modules = clock_modules();
        let embedded: Vec<(&str, &str)> = modules.iter().map(|(key, source)| (key.as_str(), source.as_str())).collect();
        let native = match boot_native_state(&home, ":memory:", &[], &embedded) {
            Ok(lua) => lua,
            Err(error) => panic!("boot a native interpreter: {error}"),
        };
        let mut state = State {
            wasi: WasiCtxBuilder::new().build(),
            table: ResourceTable::new(),
            native: Native(native),
            calls: 0,
            streams: HashMap::new(),
            serial: 0,
            limits: MemoryLimits::default(),
            run_started: None,
            run_first_call_ms: None,
            script: None,
            digests: HashMap::new(),
            embedded_digests: HashMap::new(),
            profile: item_profile(),
        };
        let values = state.call("local_tz".to_string(), vec![Value::Integer(CLOCK_EPOCH)]).expect("the node zone answers");
        let map = match values.into_iter().next() {
            Some(Value::StringMap(map)) => map,
            other => panic!("local_tz must answer a string map, got {other:?}"),
        };
        let field = |name: &str| {
            map.iter().find(|(key, _)| key == name).map(|(_, value)| String::from_utf8_lossy(value).into_owned())
        };
        assert_eq!(field("epoch"), Some(CLOCK_EPOCH.to_string()), "the answer names the instant it describes");
        let minutes: i64 = field("utc_offset_minutes").expect("the offset in minutes").parse().expect("a whole number");
        let (sign, hours, mins) = if minutes < 0 { ("-", -minutes / 60, -minutes % 60) } else { ("+", minutes / 60, minutes % 60) };
        assert_eq!(field("utc_offset"), Some(format!("{sign}{hours:02}:{mins:02}")), "the offset text must be the minutes");
        // The identifier is the OS's, and it is this machine's: the crate reads it, the kernel answers it.
        let zone = wa_local_tz::zone_id(crate::host::resolved_env("TZ").as_deref());
        assert_eq!(field("zone_source"), Some(zone.source.to_string()));
        assert_eq!(field("zone_id"), zone.id);
        // The abbreviation, when this platform has one, is the C runtime's - a name and not an offset.
        if let Some(zone) = field("zone") {
            assert!(!zone.is_empty(), "an empty zone name is an absence, not a name");
        }
    }

    /// One instant, two cores, one answer: the native interpreter reads its own C runtime, the guest
    /// asks the kernel, and both lines must be equal field for field (docs/KERNEL.md, "the node's own
    /// zone").
    #[test]
    fn the_same_instant_reads_the_same_on_both_cores() {
        let _heavy = heavy();
        let Some(pool) = pool(1, 0, Duration::from_secs(5)) else { return };
        let home = std::env::var("CARGO_TARGET_DIR").unwrap_or_else(|_| std::env::temp_dir().to_string_lossy().into_owned());
        let home = format!("{home}/wa-local-tz-test-home");
        let _ = std::fs::create_dir_all(&home);
        let modules = clock_modules();
        let embedded: Vec<(&str, &str)> = modules.iter().map(|(key, source)| (key.as_str(), source.as_str())).collect();
        let native = match boot_native_state(&home, ":memory:", &[], &embedded) {
            Ok(lua) => lua,
            Err(error) => panic!("boot a native interpreter: {error}"),
        };
        native.do_string(CLOCK_TEXT, "clock-text").expect("define the text both sides print");
        let native_text = native.call_string("clock_text", &[&CLOCK_EPOCH.to_string()]).expect("the native core reads its clock");
        // The identifier and its source are what the *host* adds; the guest cannot read TZ, /etc/localtime
        // or the Windows key for itself, which is why the call exists at all.
        let zone = wa_local_tz::zone_id(crate::host::resolved_env("TZ").as_deref());
        let args = vec![
            CLOCK_EPOCH.to_string(),
            native_text.clone(),
            zone.source.to_string(),
            zone.id.clone().unwrap_or_else(|| "none".to_string()),
        ];
        let mut lease = pool.acquire().expect("acquire an instance");
        let (report, error) = lease.run_script_outcome(Script::source("local-tz.lua", CLOCK_GUEST), &args).expect("the guest runs");
        assert_eq!(error, None, "the guest's own message: {error:?}\nnative: {native_text}");
        assert_eq!(report.code, 0, "the guest and the native core must read the same instant; native: {native_text}");
        // The guest had to ask the kernel for the zone to answer at all, so this is the call and not a
        // fallback to the guest's own (UTC) `os.date`.
        assert!(report.host_calls > 0, "the guest must have asked the kernel");
    }

    /// `__digest` is a check on the file, not a memory of it: the same bytes answer the same digest
    /// (through the cache the table exists for), and a file rewritten under the same path answers a
    /// different one - which is what stops a boot from using a chunk compiled from the old text
    /// (`glue.c`'s module cache, docs/KERNEL.md "A2.7").
    #[test]
    fn the_module_digest_follows_the_file_it_describes() {
        fn answer(state: &mut State, path: &[u8]) -> Option<String> {
            match state.digest(path).as_slice() {
                [Value::Bytes(digest)] => Some(String::from_utf8_lossy(digest).into_owned()),
                _ => None,
            }
        }
        let mut state = state();
        let dir = std::env::var("CARGO_TARGET_DIR").unwrap_or_else(|_| std::env::temp_dir().to_string_lossy().into_owned());
        let dir = format!("{dir}/wa-core-digest-test-{}", std::process::id());
        std::fs::create_dir_all(&dir).expect("a scratch directory");
        let path = format!("{dir}/probe.lua");
        std::fs::write(&path, "return 'v1'
").expect("write the module");
        let first = answer(&mut state, path.as_bytes()).expect("a module that exists has a digest");
        assert_eq!(first, digest_hex(b"return 'v1'
"), "the digest is of the bytes `__source` answers");
        assert_eq!(answer(&mut state, path.as_bytes()), Some(first.clone()), "the same bytes answer the same digest");
        // Rewritten, and longer: `(len, mtime)` is what revalidates the entry, so a different length is
        // a different file whatever the clock's resolution does.
        std::fs::write(&path, "return 'v2, longer'
").expect("rewrite the module");
        let second = answer(&mut state, path.as_bytes()).expect("the rewritten module has a digest");
        assert_eq!(second, digest_hex(b"return 'v2, longer'
"));
        assert_ne!(first, second, "a changed module must not answer the digest of the text it replaced");
        // A path the kernel cannot read is an absence, not an error: the guest falls back to `__source`,
        // which answers nil for the same reason, so `dofile` reports the words it always did.
        assert_eq!(answer(&mut state, b"/wa-no-such-dir/probe.lua"), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
