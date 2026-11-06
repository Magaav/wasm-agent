//! `wa:kernel@0.2` served in memory, so a component's own tests can run it (`docs/SERVICE-COMPONENTS.md`,
//! "Iterating on a component").
//!
//! A service component's tests otherwise need a node: an installed `<name>.wasm`, a pin, a manifest,
//! a component directory, a kv file, a whisper worker and a real socket. This crate is the other
//! half of the contract, in memory and scripted: the real `.wasm` runs on the real runner (the same
//! wasmtime engine configuration, the same `wa:kernel@0.2` host functions, the same WASI 0.3 clock),
//! and everything the node would answer - kv, http, websocket, speech, logs, health, secrets - is a
//! value the test sets.
//!
//! ```no_run
//! use wa_fake_kernel::{FakeKernel, scripts::HttpRule};
//! let mut kernel = FakeKernel::new("svc-echo");
//! kernel.grant_net(&["127.0.0.1:9999"]).grant_storage(true);
//! kernel.http_response(HttpRule::ok_json("POST", "http://127.0.0.1:9999/note", r#"{"ok":true}"#));
//! let outcome = kernel.run_file(std::path::Path::new("svc_echo.wasm"), r#"{"dial":"http://127.0.0.1:9999/note"}"#);
//! assert!(outcome.logs_text().contains("dial ok"));
//! ```
//!
//! # What is faked, and what is not
//!
//! Real: the component model, WASI preview 2 (args, env, stdout/stderr, random, filesystem-less),
//! `wasi:clocks@0.3.0` timers, the kernel's WIT signatures, resource lifetimes, the store's async
//! executor, the memory cap.
//!
//! Scripted: every answer that would leave the machine. An http call for a URL no rule names is
//! **refused** (`refused("http_not_scripted:…")`), never quietly answered with an empty 200 - a test
//! that forgets to script an exchange must fail, not pass by accident. Same for a websocket it does
//! not know, a key it does not have, and a secret it was not given.
//!
//! Nothing here enforces the manifest: a test says what the component is granted with
//! [`FakeKernel::grant_net`], [`FakeKernel::grant_storage`] and friends, and the fake kernel refuses
//! everything else exactly as the node would. The manifest check itself is the host's, and the host
//! tests prove it (`rust/wa-kernel-runtime/src/services.rs`).
//!
//! # Record and replay
//!
//! [`FakeKernel::record`] turns the in-memory [`wa_bounded::RecordRing`] on: every answered host call
//! becomes one record (interface, function, arguments, answer). [`FakeKernel::save_replay`] writes
//! the ring into a `wa-bounded` `.wrz` file, and [`FakeKernel::replay_from`] runs a component from
//! that file instead of from its scripts - so a failure seen once can be re-run with no network, no
//! clock and no speech worker, and a call the recording does not contain is a named failure
//! (`replay_mismatch:…`), never a silent script answer.

use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use wasmtime::component::{Linker, ResourceTable};
use wasmtime::{Store, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

pub mod build;
pub mod host;
pub mod journal;
pub mod scripts;
#[cfg(test)]
mod tests;

pub use journal::Journal;

/// What a host call answered: the value, or the reason it did not. The same type a record holds
/// (`ok:<json>` / `err:<reason>`), so recording, replaying and calling cannot disagree about it.
#[derive(Clone, Debug, PartialEq)]
pub enum Answer {
    Ok(Value),
    Err(String),
}
pub use scripts::{HttpRule, RecognitionScript, SttScript, WsRule};

wasmtime::component::bindgen!({
    world: "service-component",
    path: "../../wit/kernel-v2",
    // The four synchronous calls that hand the guest a stream or a future need the store, because
    // the transmit handle is created from it (the same rules the host's runner uses).
    imports: {
        "wa:kernel/websocket.[method]socket.messages": store | trappable,
        "wa:kernel/http.[method]response.body": store | trappable,
        "wa:kernel/speech.[method]recognition.segments": store | trappable,
        "wa:kernel/speech.[method]recognition.transcript": store | trappable,
    },
    exports: { default: async | store },
    with: {
        "wa:kernel/websocket.socket": host::Socket,
        "wa:kernel/http.response": host::Response,
        "wa:kernel/speech.recognition": host::Recognition,
    },
});

/// One captured log line: `wa:kernel/log.write`, with the guest's own `println!` output (stdout) and
/// stderr kept separately in [`RunOutcome`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LogLine {
    pub level: String,
    pub target: String,
    pub message: String,
}

/// One host call the component made, in order, with the answer it got. Arguments are the JSON the
/// record would carry; they never include a secret's value (a `credentials.get` records the name).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Call {
    pub interface: String,
    pub function: String,
    pub args: String,
    /// `ok:<json>` or `err:<reason>`.
    pub answer: String,
}

/// Everything a component left behind when it returned, trapped or was stopped.
#[derive(Clone, Debug, Default)]
pub struct RunOutcome {
    /// `exit_0`, `exit_3` (a guest's own non-zero exit), `trap:…`, `service_error:…`,
    /// `instantiate_failed:…`, `link_failed:…`, `deadline` or `stopped`.
    pub outcome: String,
    /// The last `lifecycle.report`, `""` when the component never reported.
    pub health: String,
    pub logs: Vec<LogLine>,
    pub calls: Vec<Call>,
    pub kv: BTreeMap<Vec<u8>, Vec<u8>>,
    /// The guest's stdout, and the tail of its stderr.
    pub stdout: String,
    pub stderr: String,
    /// Records the ring holds, and the first place a replay disagreed with the component.
    pub records: u64,
    pub replay_mismatch: Option<String>,
}

impl RunOutcome {
    pub fn logs_text(&self) -> String {
        let mut text = String::new();
        for line in &self.logs {
            text.push_str(&format!("{} {}: {}\n", line.level, line.target, line.message));
        }
        text
    }
    /// The value a component left under `key` in its own namespace.
    pub fn kv_get(&self, key: &str) -> Option<String> {
        self.kv.get(key.as_bytes()).map(|value| String::from_utf8_lossy(value).into_owned())
    }
    /// The functions the component called, in order (`kv.get`, `http.send`, …).
    pub fn called(&self) -> Vec<String> {
        self.calls.iter().map(|call| format!("{}.{}", call.interface, call.function)).collect()
    }
}

/// The kernel's own state: one per run, shared by the store and by whatever the test holds.
pub struct Kernel {
    pub name: String,
    pub kv: BTreeMap<Vec<u8>, Vec<u8>>,
    pub logs: Vec<LogLine>,
    pub health: String,
    pub secrets: BTreeMap<String, String>,
    /// Addresses (`host:port`, `host:*` or `*.suffix:port`) the component may dial.
    pub net: Vec<String>,
    pub storage: bool,
    pub stt: bool,
    pub http: Vec<HttpRule>,
    pub ws: Vec<WsRule>,
    pub speech: Option<SttScript>,
    pub calls: Vec<Call>,
    pub stopping: bool,
    pub journal: Journal,
}

/// A handle that asks the running component to stop, the way a supervisor's `lifecycle.stopping()`
/// does: set it from the test (or the CLI's signal thread) and the component returns at its next
/// check.
#[derive(Clone)]
pub struct Stopper {
    kernel: Arc<Mutex<Kernel>>,
}

impl Stopper {
    pub fn stop(&self) {
        if let Ok(mut kernel) = self.kernel.lock() {
            kernel.stopping = true;
        }
    }
    pub fn stop_requested(&self) -> bool {
        self.kernel.lock().map(|kernel| kernel.stopping).unwrap_or(false)
    }
}

/// What the store's data projection is: the WASI context, the resource table, the limits and the
/// kernel. One store per run.
pub struct State {
    pub wasi: WasiCtx,
    pub table: ResourceTable,
    pub limits: StoreLimits,
    pub kernel: Arc<Mutex<Kernel>>,
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

impl wasmtime::component::HasData for State {
    type Data<'a> = &'a mut State;
}

/// The fake kernel: what the test grants and scripts, and the entry point that runs a component.
pub struct FakeKernel {
    kernel: Arc<Mutex<Kernel>>,
    /// What the guest sees as its own environment (grant `env`), beside `WA_COMPONENT_CONFIG`.
    env: Vec<(String, String)>,
    config_env: bool,
    memory_mb: u64,
    deadline: Duration,
}

impl FakeKernel {
    /// A kernel for `name`: no network, no storage, no speech, no secrets, nothing scripted - every
    /// answerless call is refused until the test grants and scripts it.
    pub fn new(name: &str) -> FakeKernel {
        FakeKernel {
            kernel: Arc::new(Mutex::new(Kernel {
                name: name.to_string(),
                kv: BTreeMap::new(),
                logs: Vec::new(),
                health: String::new(),
                secrets: BTreeMap::new(),
                net: Vec::new(),
                storage: false,
                stt: false,
                http: Vec::new(),
                ws: Vec::new(),
                speech: None,
                calls: Vec::new(),
                stopping: false,
                journal: Journal::off(),
            })),
            env: Vec::new(),
            config_env: true,
            memory_mb: 64,
            deadline: Duration::from_secs(60),
        }
    }

    /// Change the kernel's state through its lock: a [`Stopper`] or a kv view may already hold the
    /// same kernel, so nothing is mutated behind a raw pointer.
    fn with<F: FnOnce(&mut Kernel)>(&mut self, change: F) -> &mut Self {
        if let Ok(mut kernel) = self.kernel.lock() {
            change(&mut kernel);
        }
        self
    }

    /// Grant `net` addresses exactly as the node's manifest grant does (`host:port`, `host:*`,
    /// `*.suffix:port`).
    pub fn grant_net(&mut self, addresses: &[&str]) -> &mut Self {
        self.with(|kernel| kernel.net = addresses.iter().map(|address| address.to_string()).collect())
    }
    /// Grant (or not) the component's own kv namespace (`capabilities.storage`).
    pub fn grant_storage(&mut self, granted: bool) -> &mut Self {
        self.with(|kernel| kernel.storage = granted)
    }
    /// Grant (or not) speech-to-text (`capabilities.stt`).
    pub fn grant_stt(&mut self, granted: bool) -> &mut Self {
        self.with(|kernel| kernel.stt = granted)
    }
    /// A secret the component's `credentials.get` may read by name. Its value is never logged.
    pub fn secret(&mut self, name: &str, value: &str) -> &mut Self {
        self.with(|kernel| {
            kernel.secrets.insert(name.to_string(), value.to_string());
        })
    }
    /// A key the component finds already in its namespace.
    pub fn kv_put(&mut self, key: &str, value: &str) -> &mut Self {
        self.with(|kernel| {
            kernel.kv.insert(key.as_bytes().to_vec(), value.as_bytes().to_vec());
        })
    }
    /// Script one http answer. An exchange no rule names is refused.
    pub fn http_response(&mut self, rule: HttpRule) -> &mut Self {
        self.with(|kernel| kernel.http.push(rule))
    }
    /// Script one websocket: what it delivers on `messages`, and whether a `send` comes back.
    pub fn websocket(&mut self, rule: WsRule) -> &mut Self {
        self.with(|kernel| kernel.ws.push(rule))
    }
    /// Script the recognizer (`grant_stt(true)` first).
    pub fn speech(&mut self, script: SttScript) -> &mut Self {
        self.with(|kernel| kernel.speech = Some(script))
    }
    /// An environment variable the guest sees (the node's `env` grant reference, already resolved).
    pub fn env(&mut self, key: &str, value: &str) -> &mut Self {
        self.env.push((key.to_string(), value.to_string()));
        self
    }
    /// Whether `WA_COMPONENT_CONFIG` carries the run's config (the node sets it for every service).
    pub fn config_env(&mut self, on: bool) -> &mut Self {
        self.config_env = on;
        self
    }
    pub fn memory_mb(&mut self, mb: u64) -> &mut Self {
        self.memory_mb = mb.clamp(16, 4096);
        self
    }
    /// How long a run may take before the guest is dropped (`deadline`, the outcome). The node's
    /// equivalent is the component's `timeout_seconds`; a test wants a short one.
    pub fn deadline(&mut self, deadline: Duration) -> &mut Self {
        self.deadline = deadline;
        self
    }
    /// Record every answered host call into a bounded [`wa_bounded::RecordRing`].
    pub fn record(&mut self) -> &mut Self {
        self.with(|kernel| kernel.journal = Journal::recording())
    }
    /// Answer host calls from a saved replay (`.wrz`) instead of from the scripts. Anything the file
    /// does not contain is a named failure.
    pub fn replay_from(&mut self, path: impl AsRef<Path>) -> Result<&mut Self, String> {
        let journal = Journal::replaying(path.as_ref())?;
        if let Ok(mut kernel) = self.kernel.lock() {
            kernel.journal = journal;
        }
        Ok(self)
    }
    /// A handle a test can use to stop a running component (from another thread, or before it runs).
    pub fn stopper(&self) -> Stopper {
        Stopper { kernel: self.kernel.clone() }
    }
    /// Write the recorded run into `dir` as a `wa-bounded` replay file, and return its path.
    pub fn save_replay(&self, dir: impl AsRef<Path>, label: &str) -> Result<PathBuf, String> {
        let kernel = self.kernel.lock().map_err(|_| "kernel_poisoned".to_string())?;
        kernel.journal.save(dir.as_ref(), label)
    }

    /// A read-only view of the kv namespace between runs.
    pub fn kv(&self) -> BTreeMap<Vec<u8>, Vec<u8>> {
        self.kernel.lock().map(|kernel| kernel.kv.clone()).unwrap_or_default()
    }

    /// Run the component at `path` with `config` (the JSON text `service.run(config)` receives).
    pub fn run_file(&self, path: impl AsRef<Path>, config: &str) -> RunOutcome {
        let path = path.as_ref();
        match std::fs::read(path) {
            Ok(bytes) => self.run(&bytes, config),
            Err(error) => RunOutcome { outcome: format!("read_failed:{}:{error}", path.display()), ..RunOutcome::default() },
        }
    }

    /// Run the component's bytes with `config`.
    ///
    /// The run is blocking: it owns a current-thread tokio runtime (which is what gives the WASI 0.3
    /// timer its wake-ups) until `run` returns, traps or the deadline passes.
    pub fn run(&self, wasm: &[u8], config: &str) -> RunOutcome {
        host::run(self, wasm, config)
    }
}

/// The engine: the component model with native async, which is what a `wa:kernel@0.2` guest needs.
/// One per process; the same configuration the host's 0.2 runner builds.
pub(crate) fn engine() -> Result<wasmtime::Engine, String> {
    static ENGINE: std::sync::OnceLock<wasmtime::Engine> = std::sync::OnceLock::new();
    if let Some(engine) = ENGINE.get() {
        return Ok(engine.clone());
    }
    let mut config = wasmtime::Config::new();
    config.wasm_component_model(true);
    config.wasm_component_model_async(true);
    // Epoch interruption backs the run deadline for a guest that never yields: the ticker below
    // advances the epoch every 100 ms and a store's deadline is a number of ticks.
    config.epoch_interruption(true);
    let engine = wasmtime::Engine::new(&config).map_err(|error| format!("engine_failed:{error}"))?;
    if ENGINE.set(engine.clone()).is_ok() {
        let ticker = engine.clone();
        std::thread::Builder::new()
            .name("wa-fake-kernel-epoch".into())
            .spawn(move || loop {
                std::thread::sleep(Duration::from_millis(100));
                ticker.increment_epoch();
            })
            .map_err(|error| format!("engine_failed:{error}"))?;
    }
    Ok(ENGINE.get().expect("engine initialized").clone())
}

/// Where the components a test runs come from: the fixture this crate ships, built on demand for
/// `wasm32-wasip2`, and any `.wasm` a test names. Kept here (not in the tests) because both the CLI
/// and the script smoke test want the same build step.
pub fn fixture_wasm() -> Result<PathBuf, String> {
    if let Ok(path) = std::env::var("WA_FAKE_KERNEL_FIXTURE") {
        return Ok(PathBuf::from(path));
    }
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixture");
    build::build(&dir, false).map(|built| built.wasm)
}

/// The guards the store is built with: the memory cap and the instance cap, exactly the node's
/// defaults (`limits.memory_mb`, 64 instances).
pub(crate) fn limits(memory_mb: u64) -> StoreLimits {
    StoreLimitsBuilder::new().memory_size((memory_mb as usize) << 20).instances(64).build()
}

/// The store a run uses: WASI preview 2 with captured stdout/stderr and the granted environment,
/// plus the two pipes `host::run` reads once the guest has stopped (stdout, stderr).
pub(crate) fn store(
    kernel: Arc<Mutex<Kernel>>,
    env: &[(String, String)],
    config: Option<&str>,
    memory_mb: u64,
) -> (Store<State>, wasmtime_wasi::p2::pipe::MemoryOutputPipe, wasmtime_wasi::p2::pipe::MemoryOutputPipe) {
    let mut builder = WasiCtxBuilder::new();
    let name = kernel.lock().map(|kernel| kernel.name.clone()).unwrap_or_default();
    builder.args(&[name.as_str()]);
    for (key, value) in env {
        builder.env(key, value);
    }
    if let Some(config) = config {
        builder.env("WA_COMPONENT_CONFIG", config);
    }
    let stdout = wasmtime_wasi::p2::pipe::MemoryOutputPipe::new(256 << 10);
    let stderr = wasmtime_wasi::p2::pipe::MemoryOutputPipe::new(64 << 10);
    builder.stdout(stdout.clone());
    builder.stderr(stderr.clone());
    let state = State { wasi: builder.build(), table: ResourceTable::new(), limits: limits(memory_mb), kernel };
    let engine = engine().expect("engine");
    let mut store = Store::new(&engine, state);
    store.limiter(|state| &mut state.limits);
    (store, stdout, stderr)
}

/// The linker every run uses: WASI preview 2, the WASI 0.3 clock a 0.2 guest awaits, and the seven
/// `wa:kernel@0.2` interfaces.
pub(crate) fn linker(engine: &wasmtime::Engine) -> Result<Linker<State>, String> {
    let mut linker: Linker<State> = Linker::new(engine);
    wasmtime_wasi::p2::add_to_linker_async(&mut linker).map_err(|error| format!("link_failed:{error}"))?;
    wasmtime_wasi::p3::clocks::add_to_linker::<State>(&mut linker).map_err(|error| format!("link_failed:{error}"))?;
    for added in [
        wa::kernel::websocket::add_to_linker::<State, State>(&mut linker, |state| state),
        wa::kernel::http::add_to_linker::<State, State>(&mut linker, |state| state),
        wa::kernel::speech::add_to_linker::<State, State>(&mut linker, |state| state),
        wa::kernel::kv::add_to_linker::<State, State>(&mut linker, |state| state),
        wa::kernel::lifecycle::add_to_linker::<State, State>(&mut linker, |state| state),
        wa::kernel::log::add_to_linker::<State, State>(&mut linker, |state| state),
        wa::kernel::credentials::add_to_linker::<State, State>(&mut linker, |state| state),
    ] {
        added.map_err(|error| format!("link_failed:{error}"))?;
    }
    Ok(linker)
}

