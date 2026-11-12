//! The code-mode seam, served: `wa:codemode` in a component, the QuickJS sandbox in the kernel.
//!
//! This is the host half of `docs/CORE-SPLIT.md`'s second extraction. It loads the installed `codemode`
//! component, keeps one instance alive per script (a script's loop state is the component's own
//! memory), and answers the one thing the component imports: `wa:kernel/quickjs`, which it serves by
//! calling the *existing* checksum-pinned sandbox (`crate::quickjs`, the `host.quickjs` capability) —
//! same asset pins, same fuel and epoch bounds, same owner check, same tool-callback protocol, same
//! event shapes. A component cannot host wasmtime, so the sandbox is imported rather than contained;
//! nothing about it is reimplemented here.
//!
//! `lua/core/codemode.lua` routes here when `WA_CODEMODE_COMPONENT=1`. The native path stays the
//! default and is byte for byte the code it always ran.
//!
//! Four rules this module is the place for:
//!
//! 1. **A script is one instance.** Unlike the self-loop seam (one stateless call per operation), code
//!    mode is a loop: `open` → `advance` … → `finish`. The instance is kept in a thread-local map keyed
//!    by the session the loop names, and dropped by `finish`, so a script's state is as durable as the
//!    script. Each call re-arms an epoch deadline, so a wedged step cannot wedge the node.
//! 2. **The loop dispatches; the component decides.** No tool is run here. A `call` step goes back to
//!    Lua, which re-checks authority, validates the arguments against the live schema, dispatches,
//!    retains the original and answers. This module never sees a tool's effect.
//! 3. **A failure is not a refusal.** A step that traps or exceeds its deadline answers `ok: false` with
//!    a reason; the router may fall back to the native path only while no step has been handed out. Once
//!    a script is live, a failure is reported with `effect: "unknown"` and never replayed.
//! 4. **Nothing on the seam is a JSON document.** The control channel this module speaks to Lua is JSON
//!    (a capability call is JSON, like every other `host.*`), but the component boundary is `wit/codemode`:
//!    typed records, a `refusal` variant, and `args-json`/`payload-json` only where the value is the
//!    model's own JavaScript.
use crate::quickjs;
use serde_json::{json, Value};
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Config as WasmConfig, Engine, Store, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

/// The installed name this seam is served from (`<components>/codemode.wasm`).
pub const COMPONENT: &str = "codemode";
/// How long one seam call may take end to end. The *script's* deadline is the sandbox's own
/// (`timeout_ms`, 30 s by default); this one only bounds a component that has stopped answering, so a
/// single `deliver` that runs the guest for the rest of its fuel is not cut short.
const DEFAULT_TIMEOUT_MS: u64 = 120_000;
/// The component's own memory cap, from `limits.memory_mb` in its manifest when present.
const DEFAULT_MEMORY_MB: u64 = 64;
const TICK: Duration = Duration::from_millis(10);

wasmtime::component::bindgen!({
    path: "../../wit/codemode",
    world: "codemode-component",
});

use wa::codemode::types as seam;
use wa::kernel::quickjs as sandbox;

/// Where one call gets what it needs. A value rather than ambient environment, so a test can point two
/// calls at two artifacts at once; [`Config::from_env`] is the only place these are read from the
/// process, which is what a node does.
#[derive(Clone, Debug)]
pub struct Config {
    pub components_dir: PathBuf,
    /// `WA_CODEMODE_COMPONENT_WASM`: an artifact from this checkout instead of the pinned install.
    pub wasm: Option<PathBuf>,
    /// `WA_CODEMODE_COMPONENT_MANIFEST`: the manifest that goes with `wasm`, when it is not beside it.
    pub manifest: Option<PathBuf>,
    pub timeout_ms: u64,
    /// The sandbox this host serves to the component. `Kernel` is the pinned QuickJS; `Stub` is the
    /// benchmark's scripted protocol peer (see [`Sandbox::Stub`]) — named, never ambient.
    pub sandbox: Sandbox,
}

/// The sandbox backend the `wa:kernel/quickjs` import is answered by.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sandbox {
    /// The checksum-pinned QuickJS guest (`crate::quickjs`).
    Kernel,
    /// A scripted protocol peer that emits the same events for the benchmark's five scripts, and runs
    /// no guest at all. It exists because the pinned assets are not provisioned in every checkout
    /// (`scripts/bench-codemode.sh` says so in its output): it makes the *seam* measurable on a machine
    /// that cannot run a script, and it is refused by anything but that benchmark. `WA_CODEMODE_SANDBOX_STUB=1`
    /// is the only way to select it.
    Stub,
}

impl Config {
    pub fn from_env() -> Config {
        let env_path = |key: &str| std::env::var(key).ok().filter(|value| !value.is_empty()).map(PathBuf::from);
        let stub = std::env::var("WA_CODEMODE_SANDBOX_STUB").map(|value| value == "1").unwrap_or(false);
        Config {
            components_dir: wa_host_support::paths::component_dir(),
            wasm: env_path("WA_CODEMODE_COMPONENT_WASM"),
            manifest: env_path("WA_CODEMODE_COMPONENT_MANIFEST"),
            timeout_ms: std::env::var("WA_CODEMODE_COMPONENT_TIMEOUT_MS")
                .ok()
                .and_then(|value| value.parse::<u64>().ok())
                .filter(|value| *value > 0)
                .unwrap_or(DEFAULT_TIMEOUT_MS),
            sandbox: if stub { Sandbox::Stub } else { Sandbox::Kernel },
        }
    }

    pub fn with_components(mut self, dir: impl Into<PathBuf>) -> Config {
        self.components_dir = dir.into();
        self
    }

    pub fn with_sandbox(mut self, sandbox: Sandbox) -> Config {
        self.sandbox = sandbox;
        self
    }

    pub fn with_timeout(mut self, timeout_ms: u64) -> Config {
        self.timeout_ms = timeout_ms;
        self
    }
}

// ----------------------------------------------------------------------------------------- the engine

/// One component engine for this seam: component model on, epoch interruption on, one ticker thread.
///
/// It is deliberately not `wa-kernel-runtime`'s engine (that crate sits below this one, and its helpers
/// are crate-private): the QuickJS capability already keeps its own engine, so a second one for the
/// component costs a ticker thread and nothing else, and keeps a deadline reachable from here.
fn engine() -> Result<Engine, String> {
    static ENGINE: OnceLock<Engine> = OnceLock::new();
    if let Some(engine) = ENGINE.get() {
        return Ok(engine.clone());
    }
    let mut config = WasmConfig::new();
    config.wasm_component_model(true);
    config.epoch_interruption(true);
    let engine = Engine::new(&config).map_err(|error| format!("component_engine:{error}"))?;
    if ENGINE.set(engine.clone()).is_ok() {
        std::thread::Builder::new()
            .name("wa-codemode-epoch".into())
            .spawn(move || loop {
                std::thread::sleep(TICK);
                engine.increment_epoch();
            })
            .map_err(|error| format!("epoch_ticker:{error}"))?;
    }
    Ok(ENGINE.get().expect("engine initialized").clone())
}

/// A compiled component, kept for the life of the process **and** on disk: compiling is what makes a
/// *cold* script slow (Cranelift on a 200 KB component is ~450 ms; deserialising it is ~10 ms), and the
/// same bytes always compile to the same component. The file is named by the artifact's sha256 and the
/// engine's compatibility hash, so a different wasmtime rebuilds the file rather than trusting it —
/// the same rule `quickjs.rs` applies to its module cache, including owner-only permissions: a
/// deserialised module is trusted code, so nobody but the node's user may write it.
fn compiled(config: &Config, engine: &Engine, sha: &str, bytes: &[u8]) -> Result<Component, String> {
    static CACHE: Mutex<Option<HashMap<String, Component>>> = Mutex::new(None);
    {
        let mut cache = CACHE.lock().map_err(|_| "component_cache_poisoned".to_string())?;
        let cache = cache.get_or_insert_with(HashMap::new);
        if let Some(component) = cache.get(sha) {
            return Ok(component.clone());
        }
    }
    let path = config.components_dir.join(format!("{COMPONENT}-{}-{:016x}.cwasm", &sha[..16.min(sha.len())], engine_hash(engine)));
    if path.is_file() && private(&path) {
        if let Ok(component) = unsafe { Component::deserialize_file(engine, &path) } {
            let _ = CACHE.lock().map(|mut cache| cache.get_or_insert_with(HashMap::new).insert(sha.to_string(), component.clone()));
            return Ok(component);
        }
    }
    let _ = std::fs::remove_file(&path);
    let component = Component::new(engine, bytes).map_err(|error| format!("component_compile:{error}"))?;
    if std::fs::create_dir_all(&config.components_dir).is_ok() {
        if let Ok(serialized) = component.serialize() {
            let tmp = path.with_extension(format!("tmp{}", std::process::id()));
            if write_private(&tmp, &serialized).is_ok() {
                let _ = std::fs::rename(&tmp, &path);
            }
        }
    }
    let _ = CACHE.lock().map(|mut cache| cache.get_or_insert_with(HashMap::new).insert(sha.to_string(), component.clone()));
    Ok(component)
}

fn engine_hash(engine: &Engine) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    engine.precompile_compatibility_hash().hash(&mut hasher);
    hasher.finish()
}

/// A cache file nobody but this user can write. Off unix the node's home is already the boundary, so the
/// check is the same one `quickjs.rs` makes: the antivirus/ACL case is not something this file can see.
#[cfg(unix)]
fn private(path: &std::path::Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path).map(|meta| meta.mode() & 0o022 == 0 && meta.uid() == unsafe { libc::getuid() }).unwrap_or(false)
}

#[cfg(not(unix))]
fn private(_path: &std::path::Path) -> bool {
    true
}

fn write_private(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

fn hex_of(bytes: &[u8]) -> String {
    use ring::digest::{digest, SHA256};
    digest(&SHA256, bytes).as_ref().iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The artifact this call runs: the pinned install, or — for a checkout that built it itself — the
/// artifact `WA_CODEMODE_COMPONENT_WASM` names.
fn artifact(config: &Config) -> Result<(String, Vec<u8>, Value), String> {
    let path: PathBuf = match &config.wasm {
        Some(path) => path.clone(),
        None => config.components_dir.join(format!("{COMPONENT}.wasm")),
    };
    let bytes = std::fs::read(&path).map_err(|error| format!("component_not_installed:{}:{error}", path.display()))?;
    let manifest_path = config.manifest.clone().unwrap_or_else(|| path.with_file_name(format!("{COMPONENT}.json")));
    let manifest: Value = std::fs::read_to_string(&manifest_path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_else(|| json!({}));
    Ok((hex_of(&bytes), bytes, manifest))
}

// ------------------------------------------------------------------------------------------ the store

/// One script's live state on the host side: its store, its instantiated component, and — when the
/// benchmark's stub is in use — the stub's own little protocol state.
struct Live {
    store: Store<Host>,
    bindings: CodemodeComponent,
}

thread_local! {
    static LIVE: RefCell<HashMap<String, Live>> = RefCell::new(HashMap::new());
}

/// What a host call has: the WASI view a `cdylib` needs, the memory cap, and the sandbox backend.
struct Host {
    wasi: WasiCtx,
    limits: StoreLimits,
    table: ResourceTable,
    sandbox: Sandbox,
    stub: StubState,
}

impl WasiView for Host {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

impl wasmtime::component::HasData for Host {
    type Data<'a> = &'a mut Host;
}

fn failure(detail: impl Into<String>) -> sandbox::Failure {
    sandbox::Failure::Failed(detail.into())
}

// ------------------------------------------------------------------------------- wa:kernel/quickjs

/// The kernel's answer for one sandbox action, as `host.quickjs` already words it.
fn kernel(action: &str, args: &Value) -> Value {
    match quickjs::control(action, args) {
        Ok(answer) => answer,
        Err(error) => json!({"ok": false, "error": format!("codemode_sandbox: {error:#}")}),
    }
}

fn events_of(answer: &Value) -> Vec<sandbox::Event> {
    let mut events = Vec::new();
    for event in answer.get("events").and_then(Value::as_array).into_iter().flatten() {
        match event.get("type").and_then(Value::as_str).unwrap_or_default() {
            "call" => events.push(sandbox::Event::Call(sandbox::CallEvent {
                id: event.get("id").and_then(Value::as_u64).unwrap_or(0),
                target: event.get("target").and_then(Value::as_str).unwrap_or("tool").to_string(),
                name: event.get("name").and_then(Value::as_str).unwrap_or_default().to_string(),
                args_json: event.get("args").and_then(Value::as_str).map(str::to_string),
            })),
            "output" => {
                let item = event.get("item");
                events.push(sandbox::Event::Output(sandbox::OutputEvent {
                    text: item.and_then(|item| item.get("text")).and_then(Value::as_str).unwrap_or_default().to_string(),
                    console: item.and_then(|item| item.get("console")).and_then(Value::as_bool).unwrap_or(false),
                }))
            }
            // A finished script reports its value; a FAILED one reports its message in `error`
            // (`rust/wa-capabilities/src/quickjs.rs`, the `done` event: `ok` selects which field the
            // guest fills). The seam's record carries both: `error` is the reason the component reads
            // (it had no field to read before, so every failed script reached the agent through the
            // component with no reason at all), and `value` keeps the legacy spelling - the error, when
            // there is no value - so a component built against the older record still learns why its
            // script failed.
            "done" => events.push(sandbox::Event::Done(sandbox::DoneEvent {
                ok: event.get("ok").and_then(Value::as_bool).unwrap_or(false),
                value: event.get("value").or_else(|| event.get("error"))
                    .and_then(Value::as_str).map(str::to_string),
                error: event.get("error").and_then(Value::as_str).map(str::to_string),
                writes: event.get("writes").and_then(Value::as_str).map(str::to_string),
            })),
            other => events.push(sandbox::Event::Output(sandbox::OutputEvent {
                text: format!("codemode_sandbox: unknown event {other}"),
                console: false,
            })),
        }
    }
    events
}

fn parse(input: &str) -> Value {
    serde_json::from_str(input).unwrap_or(Value::Null)
}

impl sandbox::Host for Host {
    fn start(&mut self, spec: sandbox::Spec) -> sandbox::Started {
        if self.sandbox == Sandbox::Stub {
            let (events, session, failure) = self.stub.start(&spec);
            return sandbox::Started { id: session, events, backend: "stub".to_string(), failure };
        }
        let args = json!({
            "owner": spec.owner,
            "code": spec.code,
            "timeout_ms": spec.timeout_ms,
            "tools": parse(&spec.tools_json),
            "globals": parse(&spec.globals_json),
            "store": parse(&spec.store_json),
            "wasm_path": spec.wasm_path,
            "prelude_path": spec.prelude_path,
            "module_cache": spec.module_cache,
        });
        let answer = kernel("start", &args);
        let events = events_of(&answer);
        if answer.get("ok").and_then(Value::as_bool) == Some(true) {
            sandbox::Started {
                id: answer.get("id").and_then(Value::as_str).map(str::to_string),
                events,
                backend: answer.get("backend").and_then(Value::as_str).unwrap_or("rust-wasmtime-quickjs-wasi").to_string(),
                failure: None,
            }
        } else {
            sandbox::Started {
                id: None,
                events,
                backend: String::new(),
                failure: Some(answer.get("error").and_then(Value::as_str).unwrap_or("codemode_sandbox: start failed").to_string()),
            }
        }
    }

    fn admit(&mut self, id: String, owner: String) -> Result<(), sandbox::Failure> {
        if self.sandbox == Sandbox::Stub {
            return self.stub.admit(&id, &owner);
        }
        let answer = kernel("admit", &json!({"id": id, "owner": owner}));
        match answer.get("ok").and_then(Value::as_bool) {
            Some(true) => Ok(()),
            _ => Err(failure(answer.get("error").and_then(Value::as_str).unwrap_or("codemode_sandbox: admit refused"))),
        }
    }

    fn deliver(&mut self, id: String, owner: String, call_id: u64, ok: bool, payload_json: String) -> sandbox::Delivered {
        if self.sandbox == Sandbox::Stub {
            let events = self.stub.deliver(&id, &owner, call_id, ok, &payload_json);
            return sandbox::Delivered { events, failure: None };
        }
        let answer = kernel("deliver", &json!({"id": id, "owner": owner, "call_id": call_id, "ok": ok, "payload": payload_json}));
        let events = events_of(&answer);
        let failure = match answer.get("ok").and_then(Value::as_bool) {
            Some(true) => None,
            _ => Some(answer.get("error").and_then(Value::as_str).unwrap_or("codemode_sandbox: deliver failed").to_string()),
        };
        sandbox::Delivered { events, failure }
    }

    fn close(&mut self, id: String, owner: String) -> Result<(), sandbox::Failure> {
        if self.sandbox == Sandbox::Stub {
            return self.stub.close(&id);
        }
        let answer = kernel("close", &json!({"id": id, "owner": owner}));
        match answer.get("ok").and_then(Value::as_bool) {
            Some(true) => Ok(()),
            _ => Err(failure(answer.get("error").and_then(Value::as_str).unwrap_or("codemode_sandbox: close failed"))),
        }
    }
}

// ------------------------------------------------------------------------- the benchmark's stub peer

/// A scripted peer of the sandbox protocol: for each of the benchmark's five scripts it emits the events
/// the real guest emits, and nothing else. It exists so the *seam* can be measured where the pinned
/// assets are not provisioned (see [`Sandbox::Stub`]); it never parses JavaScript, and any script it
/// does not recognise is a visible `codemode_sandbox: stub does not know this script`.
#[derive(Default)]
struct StubState {
    scripts: HashMap<String, StubScript>,
    /// How many scripts this process has started: the bench reports the first one as the cold start.
    started: u64,
}

struct StubScript {
    owner: String,
    calls: Vec<(u64, String, String, String)>,
    delivered: usize,
    echo: bool,
}

impl StubState {
    fn start(&mut self, spec: &sandbox::Spec) -> (Vec<sandbox::Event>, Option<String>, Option<String>) {
        self.started += 1;
        let id = format!("stub-{}", self.started);
        let mut calls: Vec<(u64, String, String, String)> = Vec::new();
        let mut echo = false;
        let code = spec.code.as_str();
        let mut unknown = false;
        if code.contains("Promise.all") {
            // The batching shape: the guest queues every call before it awaits any of them.
            for index in 0..BENCH_PARALLEL {
                calls.push((index + 1, "tool".into(), "sessions".into(), format!("{{\"limit\":{}}}", index + 1)));
            }
        } else if code.contains("searchTools(") {
            calls.push((1, "global".into(), "searchTools".into(), "[\"*\"]".into()));
            echo = true;
        } else if let Some(name) = described_global(code) {
            calls.push((1, "global".into(), "describeTool".into(), format!("[\"{name}\"]")));
            echo = name == "showCall";
        } else if let Some(name) = tool_call(code) {
            echo = name == "read";
            calls.push((1, "tool".into(), name.to_string(), "{}".into()));
        } else if code.trim() != "return 1" {
            unknown = true;
        }
        if unknown {
            // A guest that throws before it yields any event is a start failure, not a finished script:
            // the native path gets `ok:false` from the sandbox's `start` action and keeps its events.
            return (Vec::new(), None, Some("codemode_sandbox: stub does not know this script".to_string()));
        }
        let mut events: Vec<sandbox::Event> = calls
            .iter()
            .map(|(call, target, name, args)| sandbox::Event::Call(sandbox::CallEvent {
                id: *call,
                target: target.clone(),
                name: name.clone(),
                args_json: Some(args.clone()),
            }))
            .collect();
        if calls.is_empty() {
            events.push(sandbox::Event::Done(sandbox::DoneEvent { ok: true, value: Some("1".to_string()), writes: None, error: None }));
        }
        self.scripts.insert(id.clone(), StubScript { owner: spec.owner.clone(), calls, delivered: 0, echo });
        (events, Some(id), None)
    }

    fn admit(&self, id: &str, owner: &str) -> Result<(), sandbox::Failure> {
        let Some(script) = self.scripts.get(id) else {
            return Err(failure("codemode_sandbox: sandbox unavailable"));
        };
        if script.owner != owner {
            return Err(failure("codemode_sandbox: sandbox owner mismatch"));
        }
        Ok(())
    }

    fn deliver(&mut self, id: &str, owner: &str, call_id: u64, _ok: bool, payload: &str) -> Vec<sandbox::Event> {
        let Some(script) = self.scripts.get_mut(id) else {
            return vec![sandbox::Event::Done(sandbox::DoneEvent {
                ok: false,
                value: Some("codemode_sandbox: sandbox unavailable".to_string()),
                error: Some("codemode_sandbox: sandbox unavailable".to_string()),
                writes: None,
            })];
        };
        if script.owner != owner {
            return vec![sandbox::Event::Done(sandbox::DoneEvent {
                ok: false,
                value: Some("codemode_sandbox: sandbox owner mismatch".to_string()),
                error: Some("codemode_sandbox: sandbox owner mismatch".to_string()),
                writes: None,
            })];
        }
        script.delivered += 1;
        if script.delivered < script.calls.len() {
            return Vec::new();
        }
        if !script.calls.iter().any(|(call, _, _, _)| *call == call_id) {
            return Vec::new();
        }
        let value = if script.echo { payload.to_string() } else { "ok".to_string() };
        vec![sandbox::Event::Done(sandbox::DoneEvent { ok: true, value: Some(value), error: None, writes: None })]
    }

    fn close(&mut self, id: &str) -> Result<(), sandbox::Failure> {
        self.scripts.remove(id);
        Ok(())
    }
}

/// How many calls the benchmark's parallel script makes (`Promise.all` over ten tools).
const BENCH_PARALLEL: u64 = 10;

/// The global a `describeTool("name")` script asks about, if it asks about one.
fn described_global(code: &str) -> Option<&str> {
    let rest = code.split("describeTool(").nth(1)?;
    let rest = rest.trim_start().strip_prefix('"')?;
    Some(&rest[..rest.find('"')?])
}

/// The tool a `tools.<name>(...)` script calls, if it calls one.
fn tool_call(code: &str) -> Option<&str> {
    let rest = code.split("tools.").nth(1)?;
    let end = rest.find('(')?;
    let name = &rest[..end];
    if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return None;
    }
    Some(name)
}

// ---------------------------------------------------------------------------------------- the seam

/// Whether the component is installed and loadable — what the router asks before routing, so a missing
/// component is a decision it makes with a reason instead of a failed call per script.
pub fn available() -> Result<String, String> {
    let config = Config::from_env();
    let (sha256, _, _) = artifact(&config)?;
    Ok(sha256)
}

/// `host.codemode(request_json)` → one answer. One capability, one call: the Lua side names the
/// operation and carries the records; the component decides what runs next.
pub fn call(request: &Value) -> Value {
    call_with(&Config::from_env(), request)
}

pub fn call_with(config: &Config, request: &Value) -> Value {
    let op = request.get("op").and_then(Value::as_str).unwrap_or_default().to_string();
    let started = Instant::now();
    let mut answer = match dispatch(config, &op, request) {
        Ok(mut answer) => {
            answer["ok"] = json!(true);
            answer
        }
        Err(error) => json!({"ok": false, "error": error}),
    };
    answer["op"] = json!(op);
    answer["elapsed_ms"] = json!(started.elapsed().as_millis() as u64);
    answer
}

fn dispatch(config: &Config, op: &str, request: &Value) -> Result<Value, String> {
    match op {
        "open" => open(config, request),
        "advance" => advance(config, request),
        "finish" => finish(config, request),
        other => Err(format!("invalid_codemode_op:{other}")),
    }
}

fn session_of(request: &Value) -> Result<String, String> {
    request
        .get("session")
        .and_then(Value::as_str)
        .filter(|session| !session.is_empty())
        .map(str::to_string)
        .ok_or_else(|| "invalid_codemode_request:session_required".to_string())
}

fn text_field(value: &Value, key: &str) -> String {
    value.get(key).and_then(Value::as_str).unwrap_or_default().to_string()
}

fn optional(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).filter(|text| !text.is_empty()).map(str::to_string)
}

fn execution(value: Option<&Value>) -> seam::Execution {
    let Some(value) = value else {
        return seam::Execution {
            status: "not_blocked".to_string(),
            scope: String::new(),
            workspace_binding: String::new(),
            reason: None,
            detail: None,
            next: None,
            available: None,
            required: None,
        };
    };
    seam::Execution {
        status: text_field(value, "status"),
        scope: text_field(value, "scope"),
        workspace_binding: text_field(value, "workspace_binding"),
        reason: optional(value, "reason"),
        detail: optional(value, "detail"),
        next: optional(value, "next"),
        available: value.get("available").and_then(Value::as_bool),
        required: value.get("required").and_then(Value::as_bool),
    }
}

/// Start a script: compile/instantiate the component for this session (cold start) and hand it the
/// catalogue. One instance per session, kept until `finish`.
fn open(config: &Config, request: &Value) -> Result<Value, String> {
    let session = session_of(request)?;
    let (sha, bytes, manifest) = artifact(config)?;
    let engine = engine()?;
    let component = compiled(config, &engine, &sha, &bytes)?;
    let memory_mb = manifest
        .get("limits")
        .and_then(|limits| limits.get("memory_mb"))
        .and_then(Value::as_u64)
        .filter(|mb| *mb > 0)
        .unwrap_or(DEFAULT_MEMORY_MB);
    let mut store = Store::new(
        &engine,
        Host {
            wasi: {
                let mut builder = WasiCtxBuilder::new();
                builder.args(&[COMPONENT]);
                builder.build()
            },
            limits: StoreLimitsBuilder::new().memory_size((memory_mb as usize) << 20).build(),
            table: ResourceTable::new(),
            sandbox: config.sandbox,
            stub: StubState::default(),
        },
    );
    store.limiter(|host| &mut host.limits);
    store.set_epoch_deadline(ticks(config));
    let mut linker: Linker<Host> = Linker::new(&engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker).map_err(|error| format!("component_link_wasi:{error}"))?;
    sandbox::add_to_linker::<Host, Host>(&mut linker, |host| host).map_err(|error| format!("component_link_quickjs:{error}"))?;
    let bindings = CodemodeComponent::instantiate(&mut store, &component, &linker)
        .map_err(|error| format!("component_instantiate:{error}"))?;

    let catalogue: Vec<seam::ToolFacts> = request
        .get("catalogue")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| seam::ToolFacts {
                    name: text_field(item, "name"),
                    description: text_field(item, "description"),
                    schema_json: text_field(item, "schema_json"),
                    execution: execution(item.get("execution")),
                })
                .collect()
        })
        .unwrap_or_default();
    // The guest's own names as discovery entries, composed by the loop: this bridge copies them through
    // unchanged (`builtin-fact` in wit/codemode), because their text is the node's.
    let builtins: Vec<seam::BuiltinFact> = request
        .get("builtins")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| seam::BuiltinFact {
                    name: text_field(item, "name"),
                    description: text_field(item, "description"),
                    execution: execution(item.get("execution")),
                    entry_json: text_field(item, "entry_json"),
                })
                .collect()
        })
        .unwrap_or_default();
    let store_entries: Vec<seam::StoreEntry> = request
        .get("store")
        .and_then(Value::as_object)
        .map(|entries| {
            entries
                .iter()
                .map(|(key, value)| seam::StoreEntry { key: key.clone(), value: value.as_str().map(str::to_string) })
                .collect()
        })
        .unwrap_or_default();
    let open = seam::OpenRequest {
        session: session.clone(),
        owner: text_field(request, "owner"),
        code: text_field(request, "code"),
        timeout_ms: request.get("timeout_ms").and_then(Value::as_u64),
        catalogue,
        builtins,
        store: store_entries,
        wasm_path: optional(request, "wasm_path"),
        prelude_path: optional(request, "prelude_path"),
        module_cache: optional(request, "module_cache"),
    };
    let opened = {
        let seam_api = bindings.wa_codemode_codemode();
        seam_api.call_open(&mut store, &open).map_err(|error| trap_error("open", &error))?
    };
    let answer = opened_json(&opened);
    LIVE.with(|live| live.borrow_mut().insert(session, Live { store, bindings }));
    Ok(answer)
}

fn ticks(config: &Config) -> u64 {
    config.timeout_ms.div_ceil(TICK.as_millis() as u64).max(1)
}

/// One step of a live script.
fn advance(config: &Config, request: &Value) -> Result<Value, String> {
    let session = session_of(request)?;
    let reply = request.get("reply").filter(|reply| !reply.is_null()).map(|reply| seam::Reply {
        call_id: reply.get("call_id").and_then(Value::as_u64).unwrap_or(0),
        ok: reply.get("ok").and_then(Value::as_bool).unwrap_or(false),
        payload_json: reply.get("payload_json").and_then(Value::as_str).unwrap_or("null").to_string(),
    });
    with_live(&session, |live| {
        let seam_api = live.bindings.wa_codemode_codemode();
        live.store.set_epoch_deadline(ticks(config));
        let progress = seam_api.call_advance(&mut live.store, &session, reply.as_ref()).map_err(|error| trap_error("advance", &error))?;
        Ok(progress_json(&progress))
    })
}

/// Close a live script: the component closes its sandbox and reports what the script did.
fn finish(config: &Config, request: &Value) -> Result<Value, String> {
    let session = session_of(request)?;
    let live = LIVE.with(|live| live.borrow_mut().remove(&session));
    let Some(mut live) = live else {
        return Err("component_session_unknown".to_string());
    };
    let seam_api = live.bindings.wa_codemode_codemode();
    live.store.set_epoch_deadline(ticks(config));
    let report = seam_api.call_finish(&mut live.store, &session).map_err(|error| trap_error("finish", &error))?;
    Ok(report_json(&report))
}

/// Run one step against a live session. A trap drops the session: its sandbox cannot be trusted, and the
/// router's rule is that a live script is never replayed.
fn with_live<F>(session: &str, body: F) -> Result<Value, String>
where
    F: FnOnce(&mut Live) -> Result<Value, String>,
{
    let mut live = LIVE.with(|live| live.borrow_mut().remove(session));
    let Some(current) = live.as_mut() else {
        return Err("component_session_unknown".to_string());
    };
    match body(current) {
        Ok(answer) => {
            let taken = live.take().expect("live taken");
            LIVE.with(|live| live.borrow_mut().insert(session.to_string(), taken));
            Ok(answer)
        }
        Err(error) => {
            // Dropped here: `live` goes out of scope, so the instantiated guest and its sandbox id are
            // forgotten rather than reused after a trap.
            drop(live);
            Err(error)
        }
    }
}

// ------------------------------------------------------------------------------------ the answer shape

fn output_json(items: &[seam::OutputItem]) -> Value {
    Value::Array(items.iter().map(|item| json!({"type": "text", "text": item.text, "console": item.console})).collect())
}

fn unexecuted_json(items: &[seam::UnexecutedCall]) -> Value {
    Value::Array(
        items
            .iter()
            .map(|call| json!({"id": call.id, "name": call.name, "executed": false, "effect": "none", "reason": call.reason}))
            .collect(),
    )
}

fn writes_json(writes: &[seam::StoreEntry]) -> Value {
    Value::Array(
        writes
            .iter()
            .map(|entry| match &entry.value {
                Some(value) => json!([entry.key, value]),
                None => json!([entry.key, Value::Null]),
            })
            .collect(),
    )
}

fn outcome_json(outcome: &seam::Outcome) -> Value {
    json!({
        "ok": outcome.ok,
        "value": outcome.value,
        "error": outcome.error,
        "writes": writes_json(&outcome.writes),
    })
}

fn refusal_json(refusal: &seam::Refusal) -> Value {
    match refusal {
        seam::Refusal::TargetNotAvailable(target) => json!({
            "kind": "target_not_available",
            "name": target.name,
            "route": target.route,
        }),
    }
}

fn step_json(step: &seam::Step) -> Value {
    match step {
        seam::Step::Call(call) => {
            let mut answer = json!({"kind": "call", "id": call.id, "target": call.target, "name": call.name, "args_json": call.args_json});
            if let Some(refusal) = &call.refusal {
                answer["refusal"] = refusal_json(refusal);
            }
            answer
        }
        seam::Step::HostGlobal(global) => {
            // `target: "global"` is what the loop records in the attempt, the same field, with the same
            // value, the native loop writes for a guest global.
            json!({"kind": "host_global", "id": global.id, "target": "global", "name": global.name, "args_json": global.args_json})
        }
        seam::Step::Finished(outcome) => json!({"kind": "finished", "outcome": outcome_json(outcome)}),
        seam::Step::Aborted(reason) => json!({"kind": "aborted", "reason": reason}),
    }
}

fn opened_json(opened: &seam::Opened) -> Value {
    json!({
        "session": opened.session,
        "items": output_json(&opened.items),
        "backend": opened.backend,
        "sandbox_failure": opened.sandbox_failure,
        "unexecuted": unexecuted_json(&opened.unexecuted),
        "aborted": opened.aborted,
    })
}

fn progress_json(progress: &seam::Progress) -> Value {
    // `answered` is the seam's journal row for a global it answered inside the guest: the loop writes
    // one attempt per guest call exactly as the native path does, so dropping it here would put the two
    // journals back out of step (and the parity suite exists to catch that).
    let answered: Vec<Value> = progress
        .answered
        .iter()
        .map(|answer| {
            json!({
                "id": answer.id,
                "name": answer.name,
                "ok": answer.ok,
                "args_json": answer.args_json,
                "result_json": answer.result_json,
            })
        })
        .collect();
    json!({"items": output_json(&progress.items), "answered": answered, "step": step_json(&progress.step)})
}

fn report_json(report: &seam::Report) -> Value {
    json!({
        "items": output_json(&report.items),
        "unexecuted": unexecuted_json(&report.unexecuted),
        "outcome": report.outcome.as_ref().map(outcome_json),
        "aborted": report.aborted,
        "close_failure": report.close_failure,
        "sandbox_calls": report.sandbox_calls,
    })
}

/// The call itself failed (a trap, the epoch deadline, a missing export). Reported apart from the seam's
/// own answers, so "the component stopped answering" never reads as "code mode said no".
fn trap_error(op: &str, error: &wasmtime::Error) -> String {
    let detail = error.to_string().lines().next().unwrap_or_default().to_string();
    let chain = format!("{error:?}").to_ascii_lowercase();
    let wedged = chain.contains("interrupt") || chain.contains("epoch deadline") || chain.contains("deadline reached");
    let kind = if wedged { "component_wedged" } else { "component_failed" };
    format!("{kind}:{op}:{detail}")
}

/// `host.codemode(request_json)` -> the answer from [`call`].
pub extern "C-unwind" fn capability(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => call(&request),
        Err(_) => json!({"ok": false, "error": "invalid_codemode_request:not_json"}),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

#[cfg(test)]
mod tests;
