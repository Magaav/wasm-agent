//! Run the media component on a real file and print what its operations answer.
//!
//! WHY THIS EXISTS: this node has no component runner (no wasmtime binary, no wasm-tools, no jco), so the only
//! way to check that `probe`/`frames`/`audio` really read and write a container - rather than merely compile -
//! is to be the host. It is deliberately small and argument-driven:
//!
//!   media-probe <component.wasm> <media-file> [out-dir]
//!
//! The file is handed to the guest through a preopened directory (`/media`), and the out-dir as `/media-out`,
//! because a component has no path of its own: that is the same grant the kernel runtime makes.
//!
//! THE CALLS ARE ASYNC because the component's contract is (`async func`): a sync call against an async-lifted
//! export answers "cannot synchronously call an async-lifted export". A current-thread runtime drives them.

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
        eprintln!("usage: media-probe <component.wasm> <media-file> [out-dir]");
        std::process::exit(2);
    };
    let out_dir = args.next();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    runtime.block_on(run(component_path, media_path, out_dir))
}

async fn run(component_path: String, media_path: String, out_dir: Option<String>) -> Result<()> {
    let media_path = std::path::Path::new(&media_path)
        .canonicalize()
        .map_err(|error| anyhow::anyhow!("cannot read {media_path}: {error}"))?;
    let directory = media_path.parent().expect("a file has a parent").to_path_buf();
    let name = media_path.file_name().expect("a file has a name").to_string_lossy().into_owned();
    let bytes = std::fs::read(&media_path)?;

    let engine = Engine::default();
    let component = Component::from_file(&engine, &component_path)?;
    let mut linker: Linker<Host> = Linker::new(&engine);
    wasmtime_wasi::p2::add_to_linker_async(&mut linker)?;

    let mut builder = WasiCtxBuilder::new();
    builder.inherit_stderr();
    builder.preopened_dir(&directory, "/media", FsPerms::ReadOnly)?;
    if let Some(out_dir) = &out_dir {
        builder.preopened_dir(out_dir, "/media-out", FsPerms::ReadWrite)?;
    }
    let mut store = Store::new(&engine, Host { ctx: builder.build(), table: ResourceTable::new() });

    let bindings = MediaService::instantiate_async(&mut store, &component, &linker).await?;
    let source = wa::media::types::File {
        path: format!("/media/{name}"),
        bytes: bytes.len() as u64,
        sha256: String::new(),
        mime: String::new(),
    };

    if out_dir.is_some() {
        let request = exports::wa::media::frames::Request {
            source: source.clone(),
            moments: vec![
                exports::wa::media::frames::Moment { at_ms: 1000, scene: false },
                exports::wa::media::frames::Moment { at_ms: 5000, scene: false },
            ],
            max_pixels: 640 * 360,
            out_dir: "/media-out".to_string(),
        };
        let stills = store
            .run_concurrent(async move |store| bindings.wa_media_frames().call_take(store, request).await)
            .await?;
        // Two levels: the async-lifted call answers with the CALL's outcome, and inside it the guest's own
        // result. Both are unwrapped here, and a guest refusal is reported rather than panicked on.
        let stills = match stills {
            Ok(inner) => inner,
            Err(error) => {
                eprintln!("frames: call failed: {error}");
                std::process::exit(1);
            }
        };
        match stills {
            Ok(stills) => {
                for still in stills {
                    println!("still:       {} ms -> {} ({} bytes)", still.at_ms, still.image.path, still.image.bytes);
                }
            }
            Err(error) => {
                eprintln!("frames refused: {error:?}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    let answer = store
        .run_concurrent(async move |store| bindings.wa_media_probe().call_describe(store, source).await)
        .await?;
    let description = match answer {
        Ok(inner) => inner,
        Err(error) => {
            eprintln!("probe: call failed: {error}");
            std::process::exit(1);
        }
    };
    match description {
        Ok(description) => {
            println!("format:      {}", description.format);
            println!("duration-ms: {}", description.duration_ms);
            println!("size-bytes:  {}", description.size_bytes);
            println!("has-audio:   {}", description.has_audio);
            println!("elapsed-ms:  {}", description.elapsed_ms);
            for stream in &description.streams {
                println!("stream:      {} {} {}x{}", stream.kind, stream.codec, stream.width, stream.height);
            }
            Ok(())
        }
        Err(error) => {
            eprintln!("the component refused: {error:?}");
            std::process::exit(1);
        }
    }
}
