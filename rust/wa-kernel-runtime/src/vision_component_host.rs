//! The `vision` COMPONENT behind `wa:vision`: the host side of the seam.
//!
//! `vision_host.rs` beside this file is the kernel's own reader (the Python worker) and stays the fallback
//! until the component is green through the real caller. This file is the other path: it instantiates
//! `rust/components/vision` on the shared async engine, **provides the `assets` import** the world declares
//! (the model pair and the dictionary, fetched once into the component set and verified by the component
//! against `models.lock`), and answers one image at a time.
//!
//! Small on purpose: the pipeline lives in `vision-ocr`, the pins live in `models.lock`, and this file only
//! moves bytes and one image across the boundary.
use std::sync::Mutex;

use serde_json::Value;
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Engine, Store, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

use crate::components::{component_dir, load_in, Installed};

const COMPONENT: &str = "vision";
const DEFAULT_MEMORY_MB: u64 = 256;
/// One epoch tick is 10 ms (the same ticker `stt_host` arms): the deadline below is counted in ticks.
const TICK: std::time::Duration = std::time::Duration::from_millis(10);
const DEFAULT_TIMEOUT_MS: u64 = 180_000;

wasmtime::component::bindgen!({
    path: "../../wit/vision",
    world: "vision-component",
});

use wa::vision::types::{Line, Refusal};

/// Where the guest's assets come from: the node's component set (never a path the guest names) and the
/// artifact beside them.
pub struct Config {
    pub components_dir: std::path::PathBuf,
}

impl Config {
    pub fn installed() -> Config {
        Config { components_dir: component_dir() }
    }
}

struct State {
    wasi: WasiCtx,
    limits: StoreLimits,
    table: ResourceTable,
    assets_dir: std::path::PathBuf,
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

impl wasmtime::component::HasData for State {
    type Data<'a> = &'a mut State;
}

/// The `assets` the world imports: one named file from the component set. The component holds the pins and
/// refuses a byte that does not match; this side only says which file a name means.
impl wa::vision::assets::Host for State {
    fn load(&mut self, name: String) -> Result<Vec<u8>, String> {
        let file = match name.as_str() {
            "vision.det" | "vision.rec" | "vision.dict" => name,
            other => return Err(format!("unknown_asset:{other}")),
        };
        let path = self.assets_dir.join(&file);
        std::fs::read(&path).map_err(|error| format!("asset_missing:{}:{error}", path.display()))
    }
}

struct Served {
    store: Store<State>,
    bindings: VisionComponent,
    sha256: String,
}

static SERVED: Mutex<Option<Served>> = Mutex::new(None);

fn engine() -> Result<Engine, String> {
    crate::components::engine().map_err(|error| format!("component_engine:{error}"))
}

fn runtime() -> Result<&'static tokio::runtime::Runtime, String> {
    static RUNTIME: std::sync::OnceLock<Result<tokio::runtime::Runtime, String>> = std::sync::OnceLock::new();
    RUNTIME
        .get_or_init(|| tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| format!("component_runtime:{e}")))
        .as_ref()
        .map_err(|error| error.clone())
}

fn with_instance<T>(config: &Config, body: impl FnOnce(&mut Served, &tokio::runtime::Runtime) -> Result<T, String>) -> Result<T, String> {
    let installed: Installed = load_in(&config.components_dir, COMPONENT).map_err(|error| error.to_string())?;
    let engine = engine()?;
    let runtime = runtime()?;
    let mut held = SERVED.lock().map_err(|_| "seam_gate_poisoned".to_string())?;
    let stale = held.as_ref().map(|served| served.sha256 != installed.sha256).unwrap_or(true);
    if stale {
        if held.is_some() {
            *held = None;
        }
        let guest = Component::new(&engine, &installed.bytes).map_err(|error| format!("component_compile:{error}"))?;
        let memory_mb = installed
            .manifest
            .get("limits")
            .and_then(|limits: &Value| limits.get("memory_mb"))
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
                assets_dir: config.components_dir.clone(),
            },
        );
        store.limiter(|state| &mut state.limits);
        // Without a deadline the engine's epoch ticker interrupts the guest on its first tick (measured: the
        // instantiation trapped with `wasm trap: interrupt`). One tick is 10 ms; the deadline is the call's
        // own budget, so a wedged reader ends with `component_wedged` instead of holding the node.
        store.set_epoch_deadline(DEFAULT_TIMEOUT_MS.div_ceil(TICK.as_millis() as u64).max(1));
        let mut linker: Linker<State> = Linker::new(&engine);
        wasmtime_wasi::p2::add_to_linker_sync(&mut linker).map_err(|error| format!("component_link_wasi:{error}"))?;
        wa::vision::assets::add_to_linker::<State, State>(&mut linker, |state| state)
            .map_err(|error| format!("component_link_assets:{error}"))?;
        let bindings = runtime
            .block_on(async { VisionComponent::instantiate_async(&mut store, &guest, &linker).await })
            .map_err(|error| format!("component_instantiate:{error}"))?;
        *held = Some(Served { store, bindings, sha256: installed.sha256 });
    }
    let served = held.as_mut().expect("instantiated above");
    body(served, runtime)
}

fn flatten<T>(
    raced: Result<Result<Result<T, wasmtime::Error>, wasmtime::Error>, tokio::time::error::Elapsed>,
    op: &str,
) -> Result<T, String> {
    let ran = raced.map_err(|_| format!("component_wedged:{op}:timeout"))?;
    let call = ran.map_err(|error| format!("component_failed:{op}:{error}"))?;
    call.map_err(|error| format!("component_failed:{op}:{error}"))
}

/// Whether the resolver says the component answers this node's reads. The switch is the FEATURE - the same
/// question `stt_node` asks (`wa_features::status`), never an environment this module reads itself - and the
/// kernel's own reader stays the answer when it is not `Component`.
pub fn enabled() -> bool {
    matches!(
        wa_features::status("vision").map(|status| status.active),
        Some(wa_features::ActivePath::Component)
    )
}

/// One image, as words. The lines carry their corners in the image's own pixels.
pub fn read(image: &[u8]) -> Result<Vec<Line>, Refusal> {
    read_with(&Config::installed(), image)
}

pub fn read_with(config: &Config, image: &[u8]) -> Result<Vec<Line>, Refusal> {
    let bytes = image.to_vec();
    with_instance(config, |served, runtime| {
        let Served { store, bindings, .. } = &mut *served;
        let timeout = std::time::Duration::from_millis(30_000);
        let raced = runtime.block_on(async {
            tokio::time::timeout(
                timeout,
                store.run_concurrent(async move |store| {
                    bindings.wa_vision_vision().call_read(store, bytes).await
                }),
            )
            .await
        });
        flatten(raced, "read")
    })
    .map_err(Refusal::EngineFailed)?
}

/// Which models this node's reader is using, as the component itself reports them.
pub fn models() -> Vec<String> {
    with_instance(&Config::installed(), |served, _runtime| {
        let Served { store, bindings, .. } = &mut *served;
        bindings
            .wa_vision_vision()
            .call_models(&mut *store)
            .map_err(|error| format!("call:{error}"))
    })
    .unwrap_or_default()
}
