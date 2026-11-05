//! WASI 0.3 spike host (wasmtime 50, component-model-async): a websocket-shaped resource whose
//! inbound frames are a `stream<list<u8>>` fed by a host task, consumed by an async guest export.
//! Usage: wasi03-runner <guest.wasm> [count] [size] [interval-us]
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use futures::channel::mpsc;
use futures::Stream;
use wasmtime::component::{
    Access, Component, Destination, HasData, Linker, Resource, ResourceTable, StreamProducer,
    StreamReader, StreamResult,
};
use wasmtime::{Config, Engine, Store, StoreContextMut};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    path: "../wit",
    world: "spike",
    imports: { "spike:ws/socket.[method]conn.messages": store | trappable, default: trappable },
    exports: { default: async | store },
    with: { "spike:ws/socket.conn": Conn },
});

/// Host side of one connection: the receiving end of the frames a peer task produces.
pub struct Conn {
    rx: Option<mpsc::Receiver<Vec<u8>>>,
}

struct State {
    wasi: WasiCtx,
    table: ResourceTable,
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

/// `HasData` marker so the store-taking import can reach `State`.
struct SpikeData;
impl HasData for SpikeData {
    type Data<'a> = &'a mut State;
}

impl spike::ws::socket::Host for State {}

impl spike::ws::socket::HostConn for State {
    fn open(&mut self, count: u32, size: u32, interval_us: u32) -> wasmtime::Result<Resource<Conn>> {
        let (mut tx, rx) = mpsc::channel::<Vec<u8>>(64);
        // The "peer": a tokio task, the way a real socket pump would feed frames.
        tokio::spawn(async move {
            for i in 0..count {
                if interval_us > 0 {
                    tokio::time::sleep(Duration::from_micros(interval_us as u64)).await;
                }
                let frame = vec![(i % 251) as u8; size as usize];
                if futures::SinkExt::send(&mut tx, frame).await.is_err() {
                    break;
                }
            }
        });
        Ok(self.table.push(Conn { rx: Some(rx) })?)
    }

    fn drop(&mut self, conn: Resource<Conn>) -> wasmtime::Result<()> {
        self.table.delete(conn)?;
        Ok(())
    }
}

impl<T: Send> spike::ws::socket::HostConnWithStore<T> for SpikeData {
    fn messages(mut store: Access<T, Self>, conn: Resource<Conn>) -> wasmtime::Result<StreamReader<Vec<u8>>> {
        let rx = store.get().table.get_mut(&conn)?.rx.take();
        let rx = rx.ok_or_else(|| wasmtime::Error::msg("messages already taken"))?;
        StreamReader::new(&mut store, Frames(rx))
    }
}

/// Producer: hands each frame to the guest's pending read; wakes it when the peer sends.
struct Frames(mpsc::Receiver<Vec<u8>>);

impl<D> StreamProducer<D> for Frames {
    type Item = Vec<u8>;
    type Buffer = Option<Vec<u8>>;

    fn poll_produce<'a>(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        store: StoreContextMut<'a, D>,
        mut dst: Destination<'a, Self::Item, Self::Buffer>,
        finish: bool,
    ) -> Poll<wasmtime::Result<StreamResult>> {
        if dst.remaining(store) == Some(0) {
            return Poll::Ready(Ok(StreamResult::Completed));
        }
        match Pin::new(&mut self.0).poll_next(cx) {
            Poll::Ready(Some(frame)) => {
                dst.set_buffer(Some(frame));
                Poll::Ready(Ok(StreamResult::Completed))
            }
            Poll::Ready(None) => Poll::Ready(Ok(StreamResult::Dropped)),
            Poll::Pending if finish => Poll::Ready(Ok(StreamResult::Cancelled)),
            Poll::Pending => Poll::Pending,
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> wasmtime::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let path = args.get(1).expect("usage: wasi03-runner <guest.wasm> [count] [size] [interval-us]");
    let num = |i: usize, d: u32| args.get(i).and_then(|v| v.parse().ok()).unwrap_or(d);
    let (count, size, interval_us) = (num(2, 10_000), num(3, 512), num(4, 0));

    let mut config = Config::new();
    config.wasm_component_model(true);
    config.wasm_component_model_async(true);
    let engine = Engine::new(&config)?;

    let t0 = Instant::now();
    let component = Component::from_file(&engine, path)?;
    let compile_ms = t0.elapsed().as_secs_f64() * 1e3;

    let mut linker = Linker::<State>::new(&engine);
    wasmtime_wasi::p2::add_to_linker_async(&mut linker)?;
    spike::ws::socket::add_to_linker::<State, SpikeData>(&mut linker, |s| s)?;

    let mut store = Store::new(&engine, State { wasi: WasiCtxBuilder::new().inherit_stdio().build(), table: ResourceTable::new() });
    let t1 = Instant::now();
    let spike = Spike::instantiate_async(&mut store, &component, &linker).await?;
    let inst_ms = t1.elapsed().as_secs_f64() * 1e3;

    let t2 = Instant::now();
    let (frames, bytes) = store
        .run_concurrent(async move |store| spike.call_run(store, count, size, interval_us).await)
        .await??;
    let run = t2.elapsed();
    let per_frame_us = run.as_secs_f64() * 1e6 / frames.max(1) as f64;
    println!(
        "wasi03 ok frames={frames} bytes={bytes} expected_frames={count} compile_ms={compile_ms:.1} instantiate_ms={inst_ms:.2} run_ms={:.1} per_frame_us={per_frame_us:.2} interval_us={interval_us}",
        run.as_secs_f64() * 1e3
    );
    if frames != count || bytes != count as u64 * size as u64 {
        return Err(wasmtime::Error::msg("frame count mismatch"));
    }
    Ok(())
}
