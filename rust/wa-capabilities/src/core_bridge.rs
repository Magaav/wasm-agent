//! `core = "component"` — `serve`, its node threads, its control/placement interpreters and the
//! subagent runtime answering from the agent-core instance pool (docs/KERNEL.md, "A2.4").
//!
//! A2.1–A2.3 put the Lua core inside a wasm component, gave it streams and pooled it. Nothing in the
//! binary used the pool. This module is the seam that lets the *serving* side of the node use it
//! without reimplementing anything: the serve loop keeps its threads, its admission, its scheduler and
//! its sockets, and the one thing it asks of an interpreter — `call_string(name, args...)` — is
//! answered either by the native `Lua` it always used or by a guest run on a pooled instance.
//!
//! # What crosses, and in which direction
//!
//! The guest exports `run(entry, args) -> result<_, string>` (wit/kernel/host.wit, world
//! `core-component`), so a call cannot *return* a value: the export's `ok` payload is unit. The
//! dispatch script below therefore boots the same two entry modules the binary's interpreter factory
//! boots (`lua/core/server.lua`, and `lua/core/subagents.lua` for the calls that need it), calls the named global with the same
//! arguments, and writes its answer — `status\npayload` — through `host.write_file` to a scratch path
//! the kernel chose. The kernel reads that file, deletes it, and hands the payload back to the caller.
//! It is one small file per call under `<home>/.wasm-agent/core-bridge/`, outside any watched tree.
//!
//! The direction of every `host.*` call is unchanged from A2.1: the guest asks the kernel, the kernel
//! calls the capability's existing C function on the instance's own native interpreter, on the
//! caller's thread. That last part is why `serve` works here at all: the run's socket sink, its
//! cancel flag and its run id live in thread-locals of the thread that calls `run_script`, so a
//! `host.stream` from inside the guest reaches the same SSE client a native run would.
//!
//! # State
//!
//! Each guest run gets a fresh `lua_State` (A2.3: the instance snapshot covers the kernel's immutable
//! boot answers, never the script's globals). A node thread therefore rebuilds the Lua core per
//! request instead of keeping it, and conversation state comes from the database exactly as it does
//! for a fresh `wa run`. What that costs and what it does not preserve is measured and listed in
//! docs/KERNEL.md ("A2.4") — in short: `local agent` and the in-Lua caches are rebuilt per request,
//! and the pending `/bind` confirmation table does not survive between requests.

use crate::core_component::{CoreComponentPool, CoreInstance, CorePoolConfig, NativeFactory, PoolStats, Script};
use serde_json::Value as Json;
use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;
use wa_host_support::lua::Lua;

/// Which Lua core answers a request: the native interpreter this binary has always used, or the
/// agent-core component on a pooled wasm instance.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CoreMode {
    Native,
    Component,
}

impl CoreMode {
    pub fn as_str(self) -> &'static str {
        match self {
            CoreMode::Native => "native",
            CoreMode::Component => "component",
        }
    }

    /// `"component"` / `"native"`, case- and whitespace-insensitive. Anything else is `None` so the
    /// caller can refuse it by name instead of quietly serving the default.
    pub fn parse(text: &str) -> Option<CoreMode> {
        match text.trim().to_ascii_lowercase().as_str() {
            "native" => Some(CoreMode::Native),
            "component" => Some(CoreMode::Component),
            _ => None,
        }
    }

    /// The switch, in the order a node configures anything else: the `--core` flag, then the
    /// `WASM_AGENT_CORE` setting (which `~/.wasm-agent/env` also supplies), then a `core` key in
    /// `<home>/.wasm-agent/config.json`, then native.
    ///
    /// The second element says *where* the answer came from, so `serve` can print it at startup: a
    /// node that believes it is running the component core and is not is the failure this exists to
    /// make impossible. An unknown value is an error, never the default.
    pub fn resolve(flag: Option<&str>) -> Result<(CoreMode, String), String> {
        if let Some(value) = flag {
            let mode = CoreMode::parse(value)
                .ok_or_else(|| format!("core_mode_invalid: --core {value} (expected component or native)"))?;
            return Ok((mode, "--core".to_string()));
        }
        if let Some(value) = crate::host::resolved_env("WASM_AGENT_CORE").filter(|value| !value.trim().is_empty()) {
            let mode = CoreMode::parse(&value)
                .ok_or_else(|| format!("core_mode_invalid: WASM_AGENT_CORE={value} (expected component or native)"))?;
            return Ok((mode, "WASM_AGENT_CORE".to_string()));
        }
        if let Some(value) = config_file_core() {
            let mode = CoreMode::parse(&value)
                .ok_or_else(|| format!("core_mode_invalid: config.json core={value} (expected component or native)"))?;
            return Ok((mode, "config.json".to_string()));
        }
        Ok((CoreMode::Native, "default".to_string()))
    }
}

/// `<home>/.wasm-agent/config.json`'s `core` value, when the file has one.
fn config_file_core() -> Option<String> {
    let home = crate::host::resolved_env("HOME")?;
    let text = std::fs::read_to_string(Path::new(&home).join(".wasm-agent/config.json")).ok()?;
    let value: Json = serde_json::from_str(&text).ok()?;
    value.get("core").and_then(Json::as_str).map(str::to_string)
}

/// The pool a node sizes for itself: one instance per node-thread slot, one per concurrent subagent,
/// one for the control interpreter, one for the placement tick, and one spare - so a full node (every
/// node thread busy, every subagent running, admission resolving) still leases instead of waiting.
///
/// `WASM_AGENT_CORE_POOL_MAX` overrides the count and `WASM_AGENT_CORE_POOL_WARM` how many exist
/// before the first request (default one: the first turn should not pay an instantiation). The
/// pooling allocator's reservation is raised to match, because a `max_instances` above it is refused
/// at construction and that must not be an operator's problem.
pub fn node_pool_config(slots: usize, subagents: usize) -> CorePoolConfig {
    let wanted = slots.saturating_add(subagents).saturating_add(3).max(1);
    let max_instances = std::env::var("WASM_AGENT_CORE_POOL_MAX")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(wanted)
        .max(1);
    let warm = std::env::var("WASM_AGENT_CORE_POOL_WARM")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(1)
        .min(max_instances);
    let mut limits = wa_kernel_runtime::components::PoolLimits::default();
    limits.component_instances = limits.component_instances.max(max_instances as u32);
    CorePoolConfig { limits, max_instances, warm, ..CorePoolConfig::default() }
}

/// The dispatch script every bridge call runs inside the guest.
///
/// It is deliberately tiny and does nothing the native interpreter does not: load the same two entry
/// modules the interpreter factory loads, resolve the named global, call it with the arguments the
/// kernel passed as the guest's own `args` global, and write `status\npayload` to the last argument.
/// A `pcall` around the call is what turns a Lua error into the `Err` half of `call_string`, exactly
/// as `Lua::call_string` does natively.
const DISPATCH: &str = r#"
local reply = args[#args]
local function answer(status, text)
  host.write_file(reply, status .. '\n' .. tostring(text or ''))
end
if type(wa_me) ~= 'function' then
  local ok, problem = pcall(dofile, 'lua/core/server.lua')
  if not ok then answer('boot', problem) return end
end
local name = args[1]
local target = _G[name]
-- The second entry module is loaded only by a call that needs it (the placement tick and a subagent
-- turn): every run boots a fresh interpreter, so the half of the boot a read does not use is a cost
-- this script does not have to pay. A name neither module defines is still `missing`.
if type(target) ~= 'function' then
  local ok, problem = pcall(dofile, 'lua/core/subagents.lua')
  if not ok then answer('boot', problem) return end
  target = _G[name]
end
if type(target) ~= 'function' then answer('missing', tostring(name)) return end
local call = {}
for i = 2, #args - 1 do call[#call + 1] = args[i] end
local ok, value = pcall(target, table.unpack(call, 1, #call))
if not ok then answer('error', value) return end
if value == nil then answer('ok', '') else answer('ok', tostring(value)) end
"#;

/// The chunk name the guest reports for the dispatch script, so a message from inside it names it.
const DISPATCH_NAME: &str = "core-bridge-call";

/// One bridge: the pool every component-core interpreter leases from, the scratch directory replies
/// travel through, and the counters `/health` reports.
///
/// One per process, leaked, like `serve`'s own pool: a lease borrows the pool for its whole life, and
/// the node's pool lives exactly as long as the node does.
pub struct CoreBridge {
    pool: CoreComponentPool,
    scratch: PathBuf,
    seq: AtomicU64,
    calls: AtomicU64,
    failures: AtomicU64,
    /// Milliseconds spent inside guest runs, summed: the per-turn cost of the core itself, which is
    /// what a comparison against the native interpreter has to separate from model latency.
    run_ms: AtomicU64,
    opened_ms: u128,
}

impl CoreBridge {
    /// Open the bridge: compile `wasm` once on a pooling engine and warm `config.warm` instances.
    ///
    /// The reply scratch directory is the node's own (`<home>/.wasm-agent/core-bridge`); a caller
    /// outside the node (the tests) names one with [`CoreBridge::open_at`] instead, so nothing under
    /// an operator's home is touched by a test run.
    pub fn open(factory: NativeFactory, wasm: &Path, config: CorePoolConfig) -> wasmtime::Result<&'static CoreBridge> {
        let scratch = Path::new(&crate::host::resolved_env("HOME").unwrap_or_else(|| ".".into()))
            .join(".wasm-agent/core-bridge");
        CoreBridge::open_at(factory, wasm, config, &scratch)
    }

    /// The same, with the reply scratch directory named explicitly.
    pub fn open_at(factory: NativeFactory, wasm: &Path, config: CorePoolConfig, scratch: &Path) -> wasmtime::Result<&'static CoreBridge> {
        let started = Instant::now();
        let pool = CoreComponentPool::from_path(factory, wasm, config)?;
        let scratch = scratch.to_path_buf();
        std::fs::create_dir_all(&scratch)
            .map_err(|e| wasmtime::Error::msg(format!("core_bridge_scratch: {}: {e}", scratch.display())))?;
        let bridge = Box::new(CoreBridge {
            pool,
            scratch,
            seq: AtomicU64::new(0),
            calls: AtomicU64::new(0),
            failures: AtomicU64::new(0),
            run_ms: AtomicU64::new(0),
            opened_ms: started.elapsed().as_millis(),
        });
        Ok(Box::leak(bridge))
    }

    /// Lease one instance for a caller that will keep it (a node thread, the control interpreter, the
    /// placement tick). A lease holds its store, so one instance serves one caller at a time.
    pub fn lease(&'static self) -> Result<ComponentCore, String> {
        let instance = self.pool.acquire().map_err(|error| format!("core_bridge_pool: {error:#}"))?;
        Ok(ComponentCore { bridge: self, instance: RefCell::new(instance) })
    }

    pub fn stats(&self) -> PoolStats {
        self.pool.stats()
    }

    pub fn calls(&self) -> u64 {
        self.calls.load(Ordering::Relaxed)
    }

    pub fn failures(&self) -> u64 {
        self.failures.load(Ordering::Relaxed)
    }

    pub fn run_ms(&self) -> u64 {
        self.run_ms.load(Ordering::Relaxed)
    }

    /// How long opening the bridge took (compile + warm instances), for the startup line.
    pub fn opened_ms(&self) -> u128 {
        self.opened_ms
    }

    pub fn compiled_from(&self) -> &'static str {
        self.pool.compiled_from()
    }

    fn reply_path(&self) -> PathBuf {
        let serial = self.seq.fetch_add(1, Ordering::Relaxed);
        self.scratch.join(format!("{}-{serial}.reply", std::process::id()))
    }
}

/// One leased agent-core instance, seen as the interpreter a node thread calls into.
pub struct ComponentCore {
    bridge: &'static CoreBridge,
    instance: RefCell<CoreInstance<'static>>,
}

impl ComponentCore {
    /// The bridge call: run `name(args...)` inside the guest and answer what the Lua function answered.
    ///
    /// The error texts are the ones a caller already handles — a Lua error's own message for a failed
    /// call, and `core_bridge_*` names for the bridge's own failures, which are reported and never
    /// silently turned into an empty answer.
    pub fn call_string(&self, name: &str, args: &[&str]) -> Result<String, String> {
        let mut instance = self.instance.borrow_mut();
        let reply = self.bridge.reply_path();
        // A stale file from a previous run of this pid would be read as this call's answer.
        let _ = std::fs::remove_file(&reply);
        let mut argv: Vec<String> = Vec::with_capacity(args.len() + 2);
        argv.push(name.to_string());
        argv.extend(args.iter().map(|arg| arg.to_string()));
        argv.push(reply.display().to_string());
        self.bridge.calls.fetch_add(1, Ordering::Relaxed);
        let started = Instant::now();
        let outcome = instance.run_script_outcome(Script::source(DISPATCH_NAME, DISPATCH), &argv);
        let (report, _error) = match outcome {
            Ok(value) => value,
            Err(error) => {
                self.bridge.failures.fetch_add(1, Ordering::Relaxed);
                return Err(format!("core_bridge_run_failed: {error:#}"));
            }
        };
        self.bridge.run_ms.fetch_add(report.run_ms.round() as u64, Ordering::Relaxed);
        let _ = started;
        let text = match std::fs::read(&reply) {
            Ok(bytes) => bytes,
            Err(error) => {
                self.bridge.failures.fetch_add(1, Ordering::Relaxed);
                return Err(match error.kind() {
                    std::io::ErrorKind::NotFound => match error_hint(&report) {
                        Some(message) => format!("core_bridge_call_failed: {message}"),
                        None => format!("core_bridge_no_reply: {name} wrote no answer"),
                    },
                    _ => format!("core_bridge_no_reply: {name}: {error}"),
                });
            }
        };
        let _ = std::fs::remove_file(&reply);
        let text = String::from_utf8_lossy(&text).into_owned();
        let (status, payload) = text.split_once('\n').unwrap_or((text.trim(), ""));
        match status {
            "ok" => Ok(payload.to_string()),
            "error" => {
                self.bridge.failures.fetch_add(1, Ordering::Relaxed);
                Err(payload.to_string())
            }
            "missing" => {
                self.bridge.failures.fetch_add(1, Ordering::Relaxed);
                Err(format!("{payload} is not a function"))
            }
            "boot" => {
                self.bridge.failures.fetch_add(1, Ordering::Relaxed);
                Err(format!("core_bridge_boot_failed: {payload}"))
            }
            other => {
                self.bridge.failures.fetch_add(1, Ordering::Relaxed);
                Err(format!("core_bridge_bad_reply: {other}"))
            }
        }
    }

    /// Close a transaction the failed call may have left open on this instance's own connection — the
    /// component-core form of `host::rollback_if_open(&lua)`.
    pub fn rollback(&self) {
        let instance = self.instance.borrow();
        if let Some(lua) = instance.native() {
            crate::host::rollback_if_open(lua);
        }
    }

    /// The runs this instance has answered (`0` before its first, `> 1` once the snapshot is warm).
    pub fn runs(&self) -> u64 {
        self.instance.borrow().runs()
    }
}

/// The run failed before it could write an answer: the guest's own message is the useful one.
fn error_hint(report: &crate::core_component::RunReport) -> Option<String> {
    if report.code == 0 {
        return None;
    }
    Some(format!("the guest run exited with code {}", report.code))
}

/// The interpreter a node thread, the control interpreter or a subagent calls into. Everything the
/// serving layer asks of a Lua state is `call_string`, so this is where the switch lives.
pub enum Core {
    Native(Lua),
    Component(ComponentCore),
}

impl Core {
    pub fn mode(&self) -> CoreMode {
        match self {
            Core::Native(_) => CoreMode::Native,
            Core::Component(_) => CoreMode::Component,
        }
    }

    pub fn call_string(&self, name: &str, args: &[&str]) -> Result<String, String> {
        match self {
            Core::Native(lua) => lua.call_string(name, args),
            Core::Component(core) => core.call_string(name, args),
        }
    }

    /// Close a transaction a failed call may have left open. A no-op on the component side's guest
    /// state (it is discarded per run) but not on its instance's connection.
    pub fn rollback(&self) {
        match self {
            Core::Native(lua) => crate::host::rollback_if_open(lua),
            Core::Component(core) => core.rollback(),
        }
    }

    /// Runs this interpreter has answered (native: always the live state, so `1`).
    pub fn runs(&self) -> u64 {
        match self {
            Core::Native(_) => 1,
            Core::Component(core) => core.runs(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core_component::boot_native_state;
    use std::sync::Arc;

    /// The switch: both words, either case, and a value nobody knows refused by name rather than
    /// served as the default.
    #[test]
    fn the_core_switch_names_its_two_modes_and_refuses_the_rest() {
        assert_eq!(CoreMode::parse("native"), Some(CoreMode::Native));
        assert_eq!(CoreMode::parse(" Component "), Some(CoreMode::Component));
        assert_eq!(CoreMode::parse("wasm"), None);
        let (mode, source) = CoreMode::resolve(Some("component")).expect("the flag is honoured");
        assert_eq!(mode, CoreMode::Component);
        assert_eq!(source, "--core");
        let error = CoreMode::resolve(Some("wasm")).expect_err("an unknown mode is refused");
        assert!(error.starts_with("core_mode_invalid: --core wasm"), "{error}");
        // With nothing configured the node keeps the interpreter it always had.
        if crate::host::resolved_env("WASM_AGENT_CORE").is_none() {
            assert_eq!(CoreMode::resolve(None).expect("the default resolves").0, CoreMode::Native);
        }
    }

    /// A native `Core` is the interpreter it wraps: the same call, the same answer, the same error.
    #[test]
    fn the_native_core_is_the_interpreter_it_wraps() {
        let lua = Lua::new();
        lua.do_string("function echo(a, b) return a .. ':' .. b end", "echo").expect("define echo");
        let core = Core::Native(lua);
        assert_eq!(core.mode(), CoreMode::Native);
        assert_eq!(core.call_string("echo", &["one", "two"]).expect("call"), "one:two");
        assert_eq!(core.call_string("absent", &[]).expect_err("absent"), "absent is not a function");
        core.rollback();
    }

    /// The component side of the switch, against the real guest: `wa_me` boots the Lua core inside
    /// wasm, reads the node's user table and answers the JSON a native call answers. Without the
    /// guest built the test says it skipped.
    #[test]
    fn the_component_core_answers_a_call_from_inside_the_guest() {
        let _heavy = heavy();
        let Some(wasm) = agent_core_wasm() else { return };
        let (home, scratch) = scratch_home("core-bridge-test");
        let factory = slot_factory(home);
        let config = CorePoolConfig { max_instances: 1, warm: 1, ..CorePoolConfig::default() };
        let bridge = CoreBridge::open_at(factory, &wasm, config, &scratch).expect("open the bridge");
        let core = Core::Component(bridge.lease().expect("lease an instance"));
        assert_eq!(core.mode(), CoreMode::Component);
        // `wa_me` is defined by lua/core/server.lua, which the dispatch script boots inside the guest.
        let answer = core.call_string("wa_me", &[""]).expect("wa_me answers inside the guest");
        let value: Json = serde_json::from_str(&answer).expect("the answer is the JSON a native call answers");
        assert!(value.get("user").is_some(), "{answer}");
        // A name that is not a function is refused in the native words, and a Lua error keeps its own.
        assert_eq!(core.call_string("absent", &[]).expect_err("absent"), "absent is not a function");
        assert!(bridge.calls() >= 2, "the bridge counts every call");
        assert_eq!(bridge.stats().leased, 1);
        assert_eq!(bridge.stats().created, 1, "one lease, one instance");
    }

    /// The guest's own Lua error reaches the caller with its own text: a node thread's error path must
    /// not turn a raise into an empty success.
    #[test]
    fn a_guest_error_keeps_the_script_own_message() {
        let _heavy = heavy();
        let Some(wasm) = agent_core_wasm() else { return };
        let (home, scratch) = scratch_home("core-bridge-error");
        let factory = slot_factory(home);
        let bridge = CoreBridge::open_at(factory, &wasm, CorePoolConfig { max_instances: 1, ..CorePoolConfig::default() }, &scratch)
            .expect("open the bridge");
        let core = bridge.lease().expect("lease");
        // `dofile` is a real global in the guest and raises on a module nobody ships: a raise inside the
        // call must arrive as the caller's error with the script's own text, not as an empty answer and
        // not as a bridge failure.
        let error = core.call_string("dofile", &["lua/core/absent-module.lua"]).expect_err("a raise is an error");
        assert!(error.contains("embedded module missing"), "the error text is the script's own: {error}");
        assert!(!error.starts_with("core_bridge_"), "a script error is not a bridge failure: {error}");
        assert_eq!(bridge.failures(), 1);
    }

    /// A scratch home and reply directory under the harness's target dir (never the operator's).
    fn scratch_home(name: &str) -> (String, PathBuf) {
        let base = std::env::var("CARGO_TARGET_DIR").unwrap_or_else(|_| std::env::temp_dir().to_string_lossy().into_owned());
        let home = format!("{base}/{name}-home");
        let scratch = PathBuf::from(format!("{base}/{name}-replies"));
        let _ = std::fs::create_dir_all(&home);
        let _ = std::fs::create_dir_all(&scratch);
        (home, scratch)
    }

    /// The shipping Lua tree as `EMBEDDED` sees it: every file under `lua/`, keyed the way `dofile`
    /// asks for it. `boot_native_state` is given this instead of the binary's compiled-in table so the
    /// test runs the checkout's Lua (the same files the gate runs).
    fn lua_tree() -> Vec<(String, String)> {
        fn walk(dir: &Path, root: &Path, out: &mut Vec<(String, String)>) {
            let Ok(entries) = std::fs::read_dir(dir) else { return };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    walk(&path, root, out);
                } else if path.extension().is_some_and(|ext| ext == "lua" || ext == "sql") {
                    let key = path.strip_prefix(root).expect("under the root").to_string_lossy().replace('\\', "/");
                    let source = std::fs::read_to_string(&path).expect("read a Lua module");
                    out.push((key, source));
                }
            }
        }
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let mut out = Vec::new();
        walk(&root.join("lua"), &root, &mut out);
        assert!(!out.is_empty(), "the checkout's lua/ tree must be readable");
        out
    }

    /// A slot's native interpreter, booted the way the binary boots it: the registry, its own
    /// connection, the checkout's `EMBEDDED` tree.
    fn slot_factory(home: String) -> NativeFactory {
        let embedded = lua_tree();
        Arc::new(move || {
            let embedded: Vec<(&str, &str)> = embedded.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
            // A file database, not `:memory:`: the pool's shared-cache URI is keyed by the process id,
            // so two pools in one test binary would otherwise share one schema and lock each other.
            let db = format!("{home}/memory.db");
            boot_native_state(&home, &db, &[], &embedded).expect("boot the native state for a slot")
        })
    }

    /// A pool is the heaviest thing this test binary builds (a pooling engine, a guest instance, a
    /// native interpreter), and `http_transport`'s streaming tests assert wall-clock budgets in the
    /// same process. One at a time, like `core_component`'s pool tests (a23fix).
    static HEAVY: std::sync::Mutex<()> = std::sync::Mutex::new(());
    fn heavy() -> std::sync::MutexGuard<'static, ()> {
        HEAVY.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn agent_core_wasm() -> Option<PathBuf> {
        let path = std::env::var("WA_AGENT_CORE_WASM").ok().map(PathBuf::from).unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../components/agent-core/target/wasm32-wasip2/release/agent_core.wasm")
        });
        if path.is_file() {
            return Some(path);
        }
        eprintln!(
            "SKIP: agent-core is not built at {} - run `bash scripts/build-agent-core.sh` (needs wasi-sdk) or set WA_AGENT_CORE_WASM",
            path.display()
        );
        None
    }
}
