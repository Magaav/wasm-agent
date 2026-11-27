//! The speech queue's wire layer, served: `wa:stt` in a component, the queue and the key in the kernel.
//!
//! The seam loads the installed `stt` component, keeps **one** instance for the process, and calls the
//! five exports. One instance, not one per thread: the component holds the `rid` ledger that refuses a
//! replayed call, and two instances would be two ledgers — the node had one. Every `stt_node` call
//! already serialises on its own runtime mutex, so the instance sits behind a mutex of its own and the
//! calls queue there exactly as they queued before.
//!
//! The world is **async** (the rule of 26/11: a future for each result), so this seam is the first in the
//! tree that calls a guest on wasmtime's async path — the one `service_components_v2` uses for a
//! service's `run`, on the same pinned wasmtime 50 with `component-model-async`. That needs its own
//! engine (`async_support(true)`), because `components::engine` is the sync one every other seam shares;
//! the cost is one more engine and its epoch ticker, which is stated in the mission's report rather than
//! hidden.
//!
//! Three rules this module is the place for:
//!
//! 1. **A refusal is an answer, not a failure.** A call the component refuses comes back as the wire
//!    bytes the peer reads (`admitted.refused`), and the router hands them on unchanged. Only a guest
//!    that cannot answer at all is a `component_*` failure, and then the native path runs.
//! 2. **A wedged guest never takes the node with it.** Every call re-arms an epoch deadline, and a
//!    future that parks past the seam's own timeout is dropped: a dead guest is a fallback, not a hang.
//! 3. **The answer is the same bytes.** The refusal reply and the envelope record are what the native
//!    path produces, so `scripts/test-stt-*.lua` and the two-node row can compare them.
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use serde_json::Value;
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Engine, Store, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

use crate::components::{component_dir, load_in, Installed};

/// The installed name this seam is served from (`<components>/stt.wasm`, `stt.json`).
pub const COMPONENT: &str = "stt";
/// How long one seam call may take. The layer is a decode, a hash and a signature check over a
/// kilobyte of envelope: a guest that has not answered by then is wedged.
/// The component's own memory cap, from `limits.memory_mb` in its manifest when present.
const DEFAULT_MEMORY_MB: u64 = 32;
const TICK: Duration = Duration::from_millis(10);

wasmtime::component::bindgen!({
    path: "../../wit/stt",
    world: "stt-component",
});

use wa::stt::types as seam;

/// Where one call gets what it needs: the node's component directory and the call's deadline.
///
/// **No ambient override.** The artifact is whatever the installed component set holds (the node's
/// component dir, pinned by `components.lock`), and the deadline is a constant: a product path that
/// reads its own environment cannot be reasoned about, and a row that needs another artifact points the
/// node's component dir at a prepared set (`WA_COMPONENTS_DIR`) instead of naming a file behind the
/// code's back.
#[derive(Clone, Debug)]
pub struct Config {
    pub components_dir: std::path::PathBuf,
    pub timeout_ms: u64,
}

impl Config {
    /// The installed set and the default deadline: what the node uses.
    pub fn installed() -> Config {
        Config { components_dir: component_dir(), timeout_ms: wa_component_wait::wait_ms() }
    }

    pub fn with_components(mut self, dir: impl Into<std::path::PathBuf>) -> Config {
        self.components_dir = dir.into();
        self
    }
}

/// The store's data: a WASI view (a `cdylib` still imports `wasi:cli`/`io`/`clocks`) and its limits.
struct State {
    wasi: WasiCtx,
    limits: StoreLimits,
    table: ResourceTable,
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

impl wasmtime::component::HasData for State {
    type Data<'a> = &'a mut State;
}

/// The one live instance: the store it runs in, its bindings, and which artifact it came from (a pin
/// change is a new instance rather than a stale one answering with yesterday's bytes).
struct Served {
    store: Store<State>,
    bindings: SttComponent,
    sha256: String,
}

static SERVED: Mutex<Option<Served>> = Mutex::new(None);

/// The async engine, its epoch ticker, and the runtime the calls park on. One of each for the process:
/// a runtime per call would cost more than the call.
/// The engine every component already shares. This seam was written with one of its own because the
/// async path was expected to need it; wasmtime 50 says otherwise - its Config::async_support is
/// deprecated there ("no longer has any effect"), and the async call path runs on the shared engine. So
/// there is no second engine and no second epoch ticker here.
fn engine() -> Result<Engine, String> {
    crate::components::engine().map_err(|error| format!("component_engine:{error}"))
}

fn runtime() -> Result<&'static tokio::runtime::Runtime, String> {
    static RUNTIME: OnceLock<Result<tokio::runtime::Runtime, String>> = OnceLock::new();
    RUNTIME
        .get_or_init(|| {
            let mut builder = tokio::runtime::Builder::new_multi_thread();
            builder.worker_threads(1).enable_time();
            builder.build().map_err(|error| format!("runtime_failed:{error}"))
        })
        .as_ref()
        .map_err(|error| error.clone())
}

/// The component this call runs: the node's installed set, read through the same loader every other
/// seam uses (it verifies the pin, so a stale or half-installed artifact is a named failure, not a run).
fn component(config: &Config) -> Result<Installed, String> {
    load_in(&config.components_dir, COMPONENT).map_err(|error| error.to_string())
}

/// Whether the component is installed and loadable — what the router asks once, with a reason.
pub fn available() -> Result<String, String> {
    component(&Config::installed())
        .map_err(|error| format!("component_unavailable:{error}"))
        .map(|installed| installed.sha256)
}

/// One answer the wire carries: the admitted envelope's fields, or the reply bytes for a refusal.
pub enum Admit {
    Call { op: String, from: String, to: String, ts_ms: i64, rid: String, body_json: String },
    Refused { word: String, bytes: Vec<u8> },
}

fn failure(op: &str, error: &wasmtime::Error) -> String {
    let detail = error.to_string().lines().next().unwrap_or_default().to_string();
    let chain = format!("{error:?}").to_ascii_lowercase();
    let wedged = chain.contains("interrupt")
        || chain.contains("epoch deadline")
        || chain.contains("deadline reached")
        || chain.contains("timeout")
        || chain.contains("elapsed");
    let kind = if wedged { "component_wedged" } else { "component_failed" };
    format!("{kind}:{op}:{detail}")
}

/// Run `body` against the one instance, instantiating it first when it is missing or a different
/// artifact answered last time.
fn with_instance<T>(
    config: &Config,
    body: impl FnOnce(&mut Served, &tokio::runtime::Runtime) -> Result<T, String>,
) -> Result<T, String> {
    let installed = component(config)?;
    let engine = engine()?;
    let runtime = runtime()?;
    let mut held = SERVED.lock().map_err(|_| "seam_gate_poisoned".to_string())?;
    let stale = held.as_ref().map(|served| served.sha256 != installed.sha256).unwrap_or(true);
    if stale {
        if held.is_some() {
            // Dropping the old instance releases its store before the new one is built: a pin change
            // must not double the node's wasm footprint for the length of a call.
            *held = None;
        }
        let component = Component::new(&engine, &installed.bytes)
            .map_err(|error| format!("component_compile:{error}"))?;
        let memory_mb = installed
            .manifest
            .get("limits")
            .and_then(|limits| limits.get("memory_mb"))
            .and_then(Value::as_u64)
            .filter(|mb| *mb > 0)
            .unwrap_or(DEFAULT_MEMORY_MB);
        let mut store = Store::new(
            &engine,
            State {
                wasi: {
                    let mut builder = WasiCtxBuilder::new();
                    builder.args(&[COMPONENT]);
                    builder.build()
                },
                limits: StoreLimitsBuilder::new().memory_size((memory_mb as usize) << 20).build(),
                table: ResourceTable::new(),
            },
        );
        store.limiter(|state| &mut state.limits);
        store.set_epoch_deadline(config.timeout_ms.div_ceil(TICK.as_millis() as u64).max(1));
        let mut linker: Linker<State> = Linker::new(&engine);
        wasmtime_wasi::p2::add_to_linker_sync(&mut linker).map_err(|error| format!("component_link_wasi:{error}"))?;
        let bindings = runtime
            .block_on(async { SttComponent::instantiate_async(&mut store, &component, &linker).await })
            .map_err(|error| format!("component_instantiate:{error}"))?;
        *held = Some(Served { store, bindings, sha256: installed.sha256 });
    }
    let served = held.as_mut().expect("instance installed");
    served.store.set_epoch_deadline(config.timeout_ms.div_ceil(TICK.as_millis() as u64).max(1));
    body(served, runtime)
}

/// One call, admitted by the guest: the envelope's fields, or the reply bytes for the refusal.
///
/// The nesting is wasmtime's, not this module's: `run_concurrent` answers `Result<guest answer,
/// wasmtime::Error>`, the guest's own call answers `Result<T, wasmtime::Error>`, and the timeout
/// wraps both. Each layer is named where it is handled, so "the guest refused" and "the guest could not
/// answer" never collapse into one.
pub fn admit(me: &str, owner_nodes: &[String], skew_ms: i64, bytes: &[u8], caller: &str, now_ms: i64) -> Result<Admit, String> {
    admit_with(&Config::installed(), me, owner_nodes, skew_ms, bytes, caller, now_ms)
}

/// [`admit`] with a config, so a test can point it at an artifact it just built.
pub fn admit_with(config: &Config, me: &str, owner_nodes: &[String], skew_ms: i64, bytes: &[u8], caller: &str, now_ms: i64) -> Result<Admit, String> {
    with_instance(config, |served, runtime| {
        let (me, owners, bytes, caller) = (me.to_string(), owner_nodes.to_vec(), bytes.to_vec(), caller.to_string());
        let timeout = Duration::from_millis(config.timeout_ms);
        let raced = runtime.block_on(async {
            let Served { store, bindings, .. } = &mut *served;
            tokio::time::timeout(
                timeout,
                store.run_concurrent(async move |store| {
                    bindings.wa_stt_stt().call_admit(store, me, owners, skew_ms, bytes, caller, now_ms).await
                }),
            )
            .await
        });
        let admitted = flatten(raced, "admit")?;
        Ok(match admitted {
            seam::Admitted::Call(envelope) => Admit::Call {
                op: envelope.op,
                from: envelope.from_node,
                to: envelope.to,
                ts_ms: envelope.ts_ms,
                rid: envelope.rid,
                body_json: envelope.body_json,
            },
            seam::Admitted::Refused(refusal) => Admit::Refused { word: refusal.word, bytes: refusal.bytes },
        })
    })
}

/// One answer the node composed, as the wire carries it.
pub fn reply_ok(body_json: &str) -> Result<Vec<u8>, String> {
    let config = Config::installed();
    with_instance(&config, |served, runtime| {
        let body = body_json.to_string();
        let timeout = Duration::from_millis(config.timeout_ms);
        let raced = runtime.block_on(async {
            let Served { store, bindings, .. } = &mut *served;
            tokio::time::timeout(
                timeout,
                store.run_concurrent(async move |store| {
                    bindings.wa_stt_stt().call_reply_ok(store, body).await
                }),
            )
            .await
        });
        flatten(raced, "reply_ok")
    })
}

/// The three layers of one async call, flattened into the one answer this module promises:
/// the timeout, `run_concurrent`'s own error, and the guest's call.
fn flatten<T>(
    raced: Result<Result<Result<T, wasmtime::Error>, wasmtime::Error>, tokio::time::error::Elapsed>,
    op: &str,
) -> Result<T, String> {
    let ran = raced.map_err(|_| format!("component_wedged:{op}:timeout"))?;
    let call = ran.map_err(|error| failure(op, &error))?;
    call.map_err(|error| failure(op, &error))
}

#[cfg(test)]
mod tests {
    //! The seam's own happy path, against the artifact this checkout built: the guest admits one call and
    //! refuses its own replay (the rid ledger is the component's state, so this is also the test that the
    //! ledger survives between calls). SKIPPED, and said so, when the artifact is not named — a skip is
    //! never a pass. scripts/test-stt-seam.sh is the row that points it at a built component.
    use super::*;
    use wa_stt_remote::protocol::{Envelope, Op};

    fn config() -> Option<Config> {
        let config = Config::installed();
        component(&config).ok().map(|_| config)
    }

    #[test]
    fn the_guest_admits_one_call_and_refuses_its_own_replay() {
        let Some(config) = config() else {
            eprintln!("SKIPPED: no stt component in the node component dir (scripts/test-stt-seam.sh installs one)");
            return;
        };
        let owners = vec!["node-a".to_string()];
        // The envelope a worker's take carries, composed by the same crate the guest links.
        let envelope = Envelope::new(
            Op::Take,
            "node-a",
            "node-b",
            1_700_000_000_000,
            "rid-admit-1",
            serde_json::json!({"queue": "stt.requests", "worker": "w1", "wait_ms": 0}),
        );
        let bytes = envelope.encode();
        let first = admit_with(&config, "node-b", &owners, 60_000, &bytes, "node-a", 1_700_000_000_000).expect("the seam answers");
        match first {
            Admit::Call { op, from, to, rid, .. } => {
                assert_eq!(op, "take", "the guest decoded the op");
                assert_eq!(from, "node-a");
                assert_eq!(to, "node-b");
                assert_eq!(rid, "rid-admit-1");
            }
            Admit::Refused { word, .. } => panic!("a valid call was refused: {word}"),
        }
        // The same rid again: the guest's own ledger, not the host's, is what refuses it.
        let again = admit_with(&config, "node-b", &owners, 60_000, &bytes, "node-a", 1_700_000_000_000).expect("the seam answers");
        match again {
            Admit::Refused { word, .. } => assert_eq!(word, "replayed_request", "the ledger refused the replay"),
            Admit::Call { .. } => panic!("a replayed call was admitted"),
        }
        // A caller that is not one of the owner's nodes is refused by the same rule.
        let stranger = admit_with(&config, "node-b", &owners, 60_000, &bytes, "node-z", 1_700_000_000_001).expect("the seam answers");
        match stranger {
            Admit::Refused { word, .. } => assert_eq!(word, "unknown_caller"),
            Admit::Call { .. } => panic!("a stranger was admitted"),
        }
    }
}
