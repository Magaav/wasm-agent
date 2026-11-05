//! `wa --core-component <agent-core.wasm> <script.lua> [args...]` — the Lua core running inside a
//! wasm component, with the full `host.*` surface (docs/KERNEL.md, "A2.1").
//!
//! The guest (rust/components/agent-core) is wa-host's own Lua 5.4 compiled to wasm32-wasip2. It
//! reaches the node through ONE import, `wa:kernel/host.call(name, args)`. The kernel answers by
//! calling the capability's existing C function on a native Lua state booted exactly like every
//! other interpreter (`capabilities::register`, its own SQLite connection, the same `EMBEDDED`), so
//! nothing is reimplemented for the guest and the registry in `capabilities.rs` stays the one list.
//!
//! What cannot cross in v1 is refused with `unsupported_in_component_v1:<name>`: a capability that
//! calls back into Lua ([`UNSUPPORTED`], and any call whose argument is a function or a table —
//! the guest refuses those itself) and the live console reader/editor family.
use crate::lua::{
    lua_getfield, lua_getglobal, lua_gettop, lua_pcallk, lua_pushboolean, lua_pushinteger, lua_pushlstring,
    lua_pushnil, lua_pushnumber, lua_settop, lua_toboolean, lua_tointegerx, lua_tolstring, lua_tonumberx,
    lua_type, Lua, LuaState, LUA_MULTRET, LUA_OK, LUA_TBOOLEAN, LUA_TNIL, LUA_TNUMBER, LUA_TSTRING,
};
use std::ffi::{c_char, c_int};
use std::time::Instant;
use wasmtime::component::{Component, HasSelf, Linker, ResourceTable};
use wasmtime::{Config, Engine, Store};
use wasmtime_wasi::{DirPerms, FilePerms, WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    world: "core-component",
    path: "../../wit/kernel",
});

use wa::kernel::host::Value;

extern "C" {
    fn lua_isinteger(l: *mut LuaState, idx: c_int) -> c_int;
    fn lua_gettable(l: *mut LuaState, idx: c_int) -> c_int;
}

/// Capabilities v1 refuses by name. `http_sse` takes a Lua line callback (argument 5) that would
/// have to run in the guest; the rest drive the live console (the off-thread line reader, the
/// editor row, the panel, the status ticker), which belongs to the interactive CLI and is carved
/// out separately (A2.3). `http_stream` is NOT here: it takes four strings and returns JSON, so it
/// crosses as is.
pub const UNSUPPORTED: &[&str] = &[
    "http_sse",
    "input_start",
    "input_editor",
    "input_commands",
    "input_held",
    "input_take",
    "input_stop",
    "input_idle",
    "editor_status",
    "editor_footer",
    "panel",
    "ticker",
];

/// The native interpreter that answers the guest's calls. A raw `lua_State` is not `Send`; this
/// one is created, used and dropped on the thread that runs the component (wasmtime's sync API
/// never moves the store across threads), which is what the `Send` bound on `WasiView` needs.
struct Native(Lua);
unsafe impl Send for Native {}

struct State {
    wasi: WasiCtx,
    table: ResourceTable,
    native: Native,
    calls: u64,
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

fn push_bytes(l: *mut LuaState, bytes: &[u8]) {
    unsafe { lua_pushlstring(l, bytes.as_ptr() as *const c_char, bytes.len()) };
}

impl State {
    /// `host.<name>(args...)` on the native state, every return value converted back.
    fn dispatch(&mut self, name: &str, args: Vec<Value>) -> Result<Vec<Value>, String> {
        let l = self.native.0.l;
        let cname = crate::lua::cstr(name);
        unsafe {
            let base = lua_gettop(l);
            lua_getglobal(l, crate::lua::cstr("host").as_ptr());
            lua_getfield(l, -1, cname.as_ptr());
            crate::lua::lua_remove(l, -2);
            for arg in &args {
                match arg {
                    Value::Nil => lua_pushnil(l),
                    Value::Boolean(b) => lua_pushboolean(l, *b as c_int),
                    Value::Integer(i) => lua_pushinteger(l, *i),
                    Value::Number(n) => lua_pushnumber(l, *n),
                    Value::Bytes(bytes) => push_bytes(l, bytes),
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
            let mut out = Vec::with_capacity((top - base) as usize);
            for idx in base + 1..=top {
                out.push(match lua_type(l, idx) {
                    LUA_TNIL => Value::Nil,
                    LUA_TBOOLEAN => Value::Boolean(lua_toboolean(l, idx) != 0),
                    LUA_TNUMBER if lua_isinteger(l, idx) != 0 => Value::Integer(lua_tointegerx(l, idx, std::ptr::null_mut())),
                    LUA_TNUMBER => Value::Number(lua_tonumberx(l, idx, std::ptr::null_mut())),
                    LUA_TSTRING => Value::Bytes(bytes_at(l, idx).unwrap_or_default()),
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
            lua_getglobal(l, crate::lua::cstr("EMBEDDED").as_ptr());
            push_bytes(l, path);
            lua_gettable(l, -2);
            let value = if lua_type(l, -1) == LUA_TSTRING { bytes_at(l, -1).map(Value::Bytes) } else { None };
            lua_settop(l, base);
            vec![value.unwrap_or(Value::Nil)]
        }
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
            _ if UNSUPPORTED.contains(&name.as_str()) => Err(format!("unsupported_in_component_v1:{name}")),
            _ if !crate::capabilities::REGISTRY.iter().any(|c| c.name == name) => Err(format!("unknown_capability:{name}")),
            _ => self.dispatch(&name, args),
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
    let mut options = wasmtime_wasi::p2::bindings::sync::LinkOptions::default();
    options.cli_exit_with_code(true);
    wasmtime_wasi::p2::add_to_linker_with_options_sync(&mut linker, &options)?;
    CoreComponent::add_to_linker::<State, HasSelf<State>>(&mut linker, |state| state)?;

    // Standard WASI for what the Lua standard library itself touches (print, io.write, os.time,
    // os.getenv, io.open on relative paths); everything else goes through `host.*`.
    let mut wasi = WasiCtxBuilder::new();
    wasi.inherit_stdio().inherit_env();
    wasi.preopened_dir(".", ".", DirPerms::all(), FilePerms::all())?;
    let state = State { wasi: wasi.build(), table: ResourceTable::new(), native: Native(native), calls: 0 };
    let mut store = Store::new(&engine, state);
    let instantiate_started = Instant::now();
    let core = CoreComponent::instantiate(&mut store, &component, &linker)?;
    let instantiated = ms(instantiate_started);
    let run_started = Instant::now();
    let outcome = core.call_run(&mut store, script, script_args);
    let ran = ms(run_started);
    if timing {
        eprintln!(
            "core_component_timing: load={loaded:.1}ms ({source}) instantiate={instantiated:.2}ms run={ran:.1}ms host_calls={}",
            store.data().calls
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
