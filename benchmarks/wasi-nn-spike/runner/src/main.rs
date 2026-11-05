//! nnrunner <guest.wasm> <model-dir> <iterations>
//! Preloads <model-dir>/model.onnx under the directory's name and runs the guest command with
//! (name, iterations). The guest times wasi-nn compute calls; this binary only hosts them.
use anyhow::{anyhow, Result};
use std::path::Path;
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Config, Engine, Store};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};
use wasmtime_wasi_nn::wit::{WasiNnCtx, WasiNnView};

struct State {
    wasi: WasiCtx,
    table: ResourceTable,
    nn: WasiNnCtx,
}
impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let [_, guest, dir, iters] = args.as_slice() else { return Err(anyhow!("usage: nnrunner <guest.wasm> <model-dir> <iterations>")) };
    let name = Path::new(dir).file_name().and_then(|n| n.to_str()).ok_or(anyhow!("model dir name"))?.to_string();
    let t0 = std::time::Instant::now();
    let (backends, registry) = wasmtime_wasi_nn::preload(&[("onnx".to_string(), dir.clone())])?;
    println!("host: preloaded {name} in {} ms", t0.elapsed().as_millis());
    let mut config = Config::new();
    config.wasm_component_model(true);
    let engine = Engine::new(&config)?;
    let component = Component::from_file(&engine, guest)?;
    let mut linker = Linker::<State>::new(&engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker)?;
    wasmtime_wasi_nn::wit::add_to_linker(&mut linker, |s: &mut State| WasiNnView::new(&mut s.table, &mut s.nn))?;
    let wasi = WasiCtxBuilder::new().inherit_stdout().inherit_stderr().args(&["guest", name.as_str(), iters.as_str()]).build();
    let mut store = Store::new(&engine, State { wasi, table: ResourceTable::new(), nn: WasiNnCtx::new(backends, registry) });
    let command = wasmtime_wasi::p2::bindings::sync::Command::instantiate(&mut store, &component, &linker)?;
    command.wasi_cli_run().call_run(&mut store)?.map_err(|_| anyhow!("guest returned an error"))?;
    Ok(())
}
