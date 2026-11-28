//! Run the media component on a real file and print what its probe answers.
//!
//! WHY THIS EXISTS: this node has no component runner (no wasmtime binary, no wasm-tools, no jco), so the only
//! way to check that `probe.describe` really reads a container - rather than merely compiling - is to be the
//! host. It is deliberately small and argument-driven so it can be pointed at any component build and any
//! media file:
//!
//!   media-probe <component.wasm> <media-file>
//!
//! The file is handed to the guest through a preopened directory (`/work`), because a component has no path
//! of its own: that is the same grant the kernel runtime makes when it starts one.

use anyhow::Result;
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Engine, Store};
use wasmtime_wasi::{FsPerms, WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    path: "../wit",
    world: "media-service",
});

struct Host {
    ctx: WasiCtx,
    table: ResourceTable,
}

impl WasiView for Host {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.ctx, table: &mut self.table }
    }
}

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let (Some(component_path), Some(media_path)) = (args.next(), args.next()) else {
        eprintln!("usage: media-probe <component.wasm> <media-file>");
        std::process::exit(2);
    };
    let media_path = std::path::Path::new(&media_path)
        .canonicalize()
        .map_err(|error| anyhow::anyhow!("cannot read {media_path}: {error}"))?;
    let directory = media_path.parent().expect("a file has a parent").to_path_buf();
    let name = media_path
        .file_name()
        .expect("a file has a name")
        .to_string_lossy()
        .into_owned();
    let bytes = std::fs::read(&media_path)?;

    let engine = Engine::default();
    let component = Component::from_file(&engine, &component_path)?;
    let mut linker: Linker<Host> = Linker::new(&engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker)?;

    let mut builder = WasiCtxBuilder::new();
    builder.inherit_stderr();
    builder.preopened_dir(&directory, "/media", FsPerms::ReadOnly)?;
    let mut store = Store::new(&engine, Host { ctx: builder.build(), table: ResourceTable::new() });

    let bindings = MediaService::instantiate(&mut store, &component, &linker)?;
    let source = wa::media::types::File {
        path: format!("/media/{name}"),
        bytes: bytes.len() as u64,
        // The probe does not consult the digest in this slice (the host verifies it after a write).
        sha256: String::new(),
        mime: String::new(),
    };
    let description = bindings.wa_media_probe().call_describe(&mut store, &source)?;
    match description {
        Ok(description) => {
            println!("format:      {}", description.format);
            println!("duration-ms: {}", description.duration_ms);
            println!("size-bytes:  {}", description.size_bytes);
            println!("has-audio:   {}", description.has_audio);
            println!("elapsed-ms:  {}", description.elapsed_ms);
            for stream in &description.streams {
                println!(
                    "stream:      {} {} {}x{}",
                    stream.kind, stream.codec, stream.width, stream.height
                );
            }
            Ok(())
        }
        Err(error) => {
            eprintln!("the component refused: {error:?}");
            std::process::exit(1);
        }
    }
}
