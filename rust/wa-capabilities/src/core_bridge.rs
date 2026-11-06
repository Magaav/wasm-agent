//! `core = "component"` — `serve`, its node threads, its control/placement interpreters and the
//! subagent runtime answering from the agent-core instance pool (docs/KERNEL.md, "A2.4", "A2.5").
//!
//! A2.1–A2.3 put the Lua core inside a wasm component, gave it streams and pooled it. A2.4 made the
//! serving side of the node use that pool; A2.5 gave the guest a long-lived entry point. The serve loop
//! keeps its threads, its admission, its scheduler and its sockets, and the one thing it asks of an
//! interpreter — `call_string(name, args...)` — is answered either by the native `Lua` it always used
//! or by a work item `call` on a pooled instance.
//!
//! # What crosses, and in which direction
//!
//! The guest exports `call(name, args) -> result<string, string>` (wit/kernel/host.wit, world
//! `core-component`): call the global `name` with `args` **on the instance's own `lua_State`**, which
//! the first call boots (`lua/core/server.lua`, plus `lua/core/subagents.lua` the first time an item
//! needs it) and every later call reuses. So a node thread pays the Lua core's module bodies and
//! `memory.setup()` once, not once per request, and the core's own `local agent` and in-Lua tables
//! survive between items exactly as they do in the native interpreter (A2.5).
//!
//! The old shape — a dispatch script run per call through `run(entry, args)` that wrote its answer to
//! `<home>/.wasm-agent/core-bridge/<pid>-<n>.reply` — is gone with it: nothing about a call touches the
//! filesystem, and a call answers in the same `Result<String, String>` the native `Lua::call_string`
//! returns (a Lua error keeps its own text).
//!
//! The direction of every `host.*` call is unchanged from A2.1: the guest asks the kernel, the kernel
//! calls the capability's existing C function on the instance's own native interpreter, on the
//! caller's thread. That last part is why `serve` works here at all: the run's socket sink, its
//! cancel flag and its run id are installed on the node thread for the work item before it calls in
//! (they travel with the item), so a `host.stream` from inside the guest reaches the same SSE client a
//! native run would. The guest holds none of that state — a long-lived `lua_State` that carried a run
//! id would hand one request's context to the next.
//!
//! # State
//!
//! One `lua_State` per lease, for the life of the lease: a node thread leases once and keeps it, the
//! control and placement interpreters lease once each, a subagent turn leases per turn (as a native
//! subagent turn builds an interpreter). The pool resets the guest's core when a lease goes back
//! (`CoreInstance::reset`), so a slot handed to a fresh node thread boots a fresh core instead of
//! inheriting the previous one's `local agent` or its pending `/bind` confirmation table.

use crate::core_component::{CoreComponentPool, CoreInstance, CorePoolConfig, NativeFactory, PoolStats};
use serde_json::Value as Json;
use std::cell::RefCell;
use std::path::Path;
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
/// before the first request (default one: the first turn should not pay an instantiation).
///
/// `WASM_AGENT_CORE_POOL_RESERVE_MB` is what one instance reserves in linear memory, and therefore
/// what the pooling allocator takes from the process (`limits.memories` slots of it, see
/// [`CorePoolConfig::reservation_bytes`]). 64 MiB by default: a guest that holds 1-3 MiB gets the
/// headroom for a Lua-heavy turn, and a node sized for 16 node threads (23 instances, 31 memory
/// slots) reserves ~2 GiB of *address space* instead of A2.4's 2.5 GiB - and the number is a knob
/// instead of the allocator's 256 MiB default, which grew with neither the instance count nor what a
/// guest measures.
///
/// `WASM_AGENT_CORE_RUN_DEADLINE_MS` is the guest-CPU budget of one work item (default 60 s, `0` =
/// none). It counts instructions, not wall time: a turn waiting on the model is not charged for it,
/// and a run whose Lua never returns fails that run and recycles its instance.
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
    let reserve = std::env::var("WASM_AGENT_CORE_POOL_RESERVE_MB")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .map(|mib| mib << 20)
        .unwrap_or(crate::core_component::DEFAULT_RESERVE_PER_INSTANCE);
    let deadline = std::env::var("WASM_AGENT_CORE_RUN_DEADLINE_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .map(std::time::Duration::from_millis)
        .unwrap_or(crate::core_component::DEFAULT_RUN_DEADLINE);
    CorePoolConfig::pooled(max_instances, warm, reserve).with_run_deadline(deadline)
}

/// One bridge: the pool every component-core interpreter leases from, and the counters `/health`
/// reports.
///
/// One per process, leaked, like `serve`'s own pool: a lease borrows the pool for its whole life, and
/// the node's pool lives exactly as long as the node does.
pub struct CoreBridge {
    pool: CoreComponentPool,
    calls: AtomicU64,
    /// Work items that paid the guest's boot (the first item on an instance): the count that says the
    /// long-lived core is really long-lived. A per-request boot makes this equal `calls`.
    boots: AtomicU64,
    failures: AtomicU64,
    /// Milliseconds spent inside guest work items, summed: the per-turn cost of the core itself, which
    /// is what a comparison against the native interpreter has to separate from model latency.
    run_ms: AtomicU64,
    opened_ms: u128,
}

impl CoreBridge {
    /// Open the bridge: compile `wasm` once on a pooling engine and warm `config.warm` instances.
    pub fn open(factory: NativeFactory, wasm: &Path, config: CorePoolConfig) -> wasmtime::Result<&'static CoreBridge> {
        let started = Instant::now();
        let pool = CoreComponentPool::from_path(factory, wasm, config)?;
        let bridge = Box::new(CoreBridge {
            pool,
            calls: AtomicU64::new(0),
            boots: AtomicU64::new(0),
            failures: AtomicU64::new(0),
            run_ms: AtomicU64::new(0),
            opened_ms: started.elapsed().as_millis(),
        });
        Ok(Box::leak(bridge))
    }

    /// The same as [`CoreBridge::open`], named for the callers that used to need a scratch directory:
    /// a call writes nothing to disk since A2.5, so a test needs no redirect to keep an operator's
    /// home untouched.
    pub fn open_at(factory: NativeFactory, wasm: &Path, config: CorePoolConfig) -> wasmtime::Result<&'static CoreBridge> {
        CoreBridge::open(factory, wasm, config)
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

    /// Work items that booted the guest's Lua core (the first item on each instance, and the first on
    /// each lease after a reset). Fewer than `calls` is the whole point of A2.5.
    pub fn boots(&self) -> u64 {
        self.boots.load(Ordering::Relaxed)
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

    /// What the pool is sized for: instances, what each reserves, and what the pooling allocator
    /// therefore takes from the process. `/health` reports it, so a node's wasm footprint is a number
    /// an operator can see instead of an allocator default.
    pub fn reservation_bytes(&self) -> usize {
        self.pool.config().reservation_bytes()
    }

    /// One work item's guest-CPU budget (`0` = none).
    pub fn run_deadline(&self) -> std::time::Duration {
        self.pool.config().run_deadline
    }
}

/// One leased agent-core instance, seen as the interpreter a node thread calls into.
pub struct ComponentCore {
    bridge: &'static CoreBridge,
    instance: RefCell<CoreInstance<'static>>,
}

impl ComponentCore {
    /// The bridge call: run `name(args...)` as one work item of the guest's long-lived core and answer
    /// what the Lua function answered.
    ///
    /// The error texts are the ones a caller already handles — a Lua error's own message for a failed
    /// call, and `core_bridge_*` names for the bridge's own failures, which are reported and never
    /// silently turned into an empty answer. A run that reached its guest-CPU deadline says so by name
    /// (`core_bridge_run_deadline`) and has already cost its instance, not the node thread.
    pub fn call_string(&self, name: &str, args: &[&str]) -> Result<String, String> {
        let mut instance = self.instance.borrow_mut();
        let argv: Vec<String> = args.iter().map(|arg| arg.to_string()).collect();
        self.bridge.calls.fetch_add(1, Ordering::Relaxed);
        let report = match instance.call_entry(name, &argv) {
            Ok(report) => report,
            Err(error) => {
                self.bridge.failures.fetch_add(1, Ordering::Relaxed);
                let reason = if crate::core_component::is_run_deadline(&error) {
                    format!("core_bridge_run_deadline: {name} was interrupted after {} ms of guest time", self.bridge.run_deadline().as_millis())
                } else {
                    format!("core_bridge_run_failed: {error:#}")
                };
                // A trap retired the instance (it cannot run another item), so this lease takes a
                // replacement now: the failure belongs to the item that caused it, not to every later
                // request on this node thread. A pool with nothing to hand out leaves the lease empty,
                // and the next call says so by name instead of trapping again.
                if let Ok(fresh) = self.bridge.pool.acquire() {
                    *instance = fresh;
                }
                return Err(reason);
            }
        };
        self.bridge.run_ms.fetch_add(report.run_ms.round() as u64, Ordering::Relaxed);
        if report.runs_on_instance == 1 {
            self.bridge.boots.fetch_add(1, Ordering::Relaxed);
        }
        if report.answer.is_err() {
            self.bridge.failures.fetch_add(1, Ordering::Relaxed);
        }
        report.answer
    }

    /// Close a transaction the failed call may have left open on this instance's own connection — the
    /// component-core form of `host::rollback_if_open(&lua)`.
    pub fn rollback(&self) {
        let instance = self.instance.borrow();
        if let Some(lua) = instance.native() {
            crate::host::rollback_if_open(lua);
        }
    }

    /// The work items this instance has answered (`0` before its first).
    pub fn runs(&self) -> u64 {
        self.instance.borrow().runs()
    }
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
    /// state (a Lua error unwinds to the interpreter's own stack, as natively) but not on its
    /// instance's connection.
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
    use std::path::PathBuf;
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
        let home = scratch_home("core-bridge-test");
        let factory = slot_factory(home);
        let config = CorePoolConfig { max_instances: 1, warm: 1, ..CorePoolConfig::default() };
        let bridge = CoreBridge::open_at(factory, &wasm, config).expect("open the bridge");
        let core = Core::Component(bridge.lease().expect("lease an instance"));
        assert_eq!(core.mode(), CoreMode::Component);
        // `wa_me` is defined by lua/core/server.lua, which the guest's first call boots.
        let answer = core.call_string("wa_me", &[""]).expect("wa_me answers inside the guest");
        let value: Json = serde_json::from_str(&answer).expect("the answer is the JSON a native call answers");
        assert!(value.get("user").is_some(), "{answer}");
        // A name that is not a function is refused in the native words, and a Lua error keeps its own.
        assert_eq!(core.call_string("absent", &[]).expect_err("absent"), "absent is not a function");
        assert!(bridge.calls() >= 2, "the bridge counts every call");
        assert_eq!(bridge.stats().leased, 1);
        assert_eq!(bridge.stats().created, 1, "one lease, one instance");
    }

    /// The whole point of A2.5: the guest keeps **one** `lua_State` for the life of a lease, so what an
    /// item sets is still there for the next one - where A2.4 rebuilt the core per request. The probe is
    /// a module the factory publishes in `EMBEDDED`, so `dofile` runs it inside the guest's own state:
    /// `1` on a fresh interpreter, `2` on the same one.
    #[test]
    fn a_lease_keeps_one_lua_state_across_work_items() {
        let _heavy = heavy();
        let Some(wasm) = agent_core_wasm() else { return };
        let home = scratch_home("core-bridge-loop");
        let factory = probe_factory(home);
        let bridge = CoreBridge::open_at(factory, &wasm, CorePoolConfig { max_instances: 1, ..CorePoolConfig::default() })
            .expect("open the bridge");
        let core = bridge.lease().expect("lease");
        assert_eq!(core.call_string("dofile", &[PROBE_MODULE]).expect("first item"), "1");
        assert_eq!(core.call_string("dofile", &[PROBE_MODULE]).expect("second item"), "2", "the state must persist");
        assert_eq!(core.call_string("dofile", &[PROBE_MODULE]).expect("third item"), "3");
        assert_eq!(core.runs(), 3, "three work items on one instance");
        assert_eq!(bridge.stats().created, 1, "and still one instance");
    }

    /// A lease that changes hands gets a fresh core: the pool resets the guest's `lua_State` on release,
    /// so a slot handed to a new node thread cannot inherit the previous one's `local agent`, its
    /// `package.loaded` or its pending `/bind` table.
    #[test]
    fn a_released_lease_hands_out_a_fresh_core() {
        let _heavy = heavy();
        let Some(wasm) = agent_core_wasm() else { return };
        let home = scratch_home("core-bridge-reset");
        let factory = probe_factory(home);
        let bridge = CoreBridge::open_at(factory, &wasm, CorePoolConfig { max_instances: 1, ..CorePoolConfig::default() })
            .expect("open the bridge");
        {
            let core = bridge.lease().expect("lease");
            assert_eq!(core.call_string("dofile", &[PROBE_MODULE]).expect("item"), "1");
            assert_eq!(core.call_string("dofile", &[PROBE_MODULE]).expect("item"), "2");
        }
        let second = bridge.lease().expect("the same slot, a new lease");
        assert_eq!(second.call_string("dofile", &[PROBE_MODULE]).expect("item"), "1", "a new lease must not inherit the old state");
        // The run counter is the *instance's*, and the instance was reused: what a new lease gets is a
        // fresh Lua state on the same slot, which is exactly the difference from a new instance.
        assert_eq!(second.runs(), 3);
        assert_eq!(bridge.stats().created, 1, "one slot served both leases");
    }

    /// A guest that never returns costs one item, not the node thread: the item reaches its guest-CPU
    /// deadline, fails by name, and its instance is recycled instead of being handed on wedged.
    #[test]
    fn a_wedged_guest_hits_its_deadline_and_the_instance_is_recycled() {
        let _heavy = heavy();
        let Some(wasm) = agent_core_wasm() else { return };
        let home = scratch_home("core-bridge-deadline");
        let factory = probe_factory(home);
        // The budget counts guest *instructions*, and booting the Lua core inside the guest is a few
        // hundred milliseconds of them (A2.4 measured ~680 ms per call with the core rebuilt): the
        // deadline has to be above the boot and well below "never".
        let config = CorePoolConfig { max_instances: 1, ..CorePoolConfig::default() }
            .with_run_deadline(std::time::Duration::from_millis(2_000));
        let bridge = CoreBridge::open_at(factory, &wasm, config).expect("open the bridge");
        let core = bridge.lease().expect("lease");
        let started = Instant::now();
        let error = core.call_string("dofile", &[SPIN_MODULE]).expect_err("a guest that never returns must not answer");
        assert!(error.starts_with("core_bridge_run_deadline"), "{error}");
        assert!(started.elapsed() >= std::time::Duration::from_millis(1_500), "the deadline must be honoured, not skipped: {:?}", started.elapsed());
        assert!(started.elapsed() < std::time::Duration::from_secs(20), "the deadline is honoured in seconds, not never");
        assert_eq!(bridge.stats().deadlines, 1, "the pool counts the deadline it enforced");
        // The trap retired the instance; the same lease is still usable and gets a fresh one.
        assert_eq!(core.call_string("dofile", &[PROBE_MODULE]).expect("a fresh instance answers"), "1");
        assert_eq!(bridge.stats().created, 1, "the wedged instance was dropped and replaced");
    }

    /// The guest's own Lua error reaches the caller with its own text: a node thread's error path must
    /// not turn a raise into an empty success.
    #[test]
    fn a_guest_error_keeps_the_script_own_message() {
        let _heavy = heavy();
        let Some(wasm) = agent_core_wasm() else { return };
        let home = scratch_home("core-bridge-error");
        let factory = slot_factory(home);
        let bridge = CoreBridge::open_at(factory, &wasm, CorePoolConfig { max_instances: 1, ..CorePoolConfig::default() })
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

    /// A scratch home under the harness's target dir (never the operator's).
    fn scratch_home(name: &str) -> String {
        let base = std::env::var("CARGO_TARGET_DIR").unwrap_or_else(|_| std::env::temp_dir().to_string_lossy().into_owned());
        let home = format!("{base}/{name}-home");
        let _ = std::fs::create_dir_all(&home);
        home
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
                let key = path.strip_prefix(root).unwrap().to_string_lossy().replace(char::from(92u8), "/");
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

    /// The probe modules the persistence and deadline tests `dofile` inside the guest: a counter that
    /// only a *reused* `lua_State` can advance, and a loop that never returns.
    const PROBE_MODULE: &str = "a25/probe.lua";
    const SPIN_MODULE: &str = "a25/spin.lua";
    const PROBE_SOURCE: &str = "A25_PROBE = (A25_PROBE or 0) + 1
return tostring(A25_PROBE)";
    const SPIN_SOURCE: &str = "while true do end";

    /// The slot factory plus those two modules in `EMBEDDED`, which is how a module reaches `dofile`
    /// inside the guest without a file on disk.
    fn probe_factory(home: String) -> NativeFactory {
        let mut embedded = lua_tree();
        embedded.push((PROBE_MODULE.to_string(), PROBE_SOURCE.to_string()));
        embedded.push((SPIN_MODULE.to_string(), SPIN_SOURCE.to_string()));
        Arc::new(move || {
            let embedded: Vec<(&str, &str)> = embedded.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
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


