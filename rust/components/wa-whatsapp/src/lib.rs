//! WhatsApp linked-device client as a service component.
//!
//! whatsapp-rust's protocol core, with everything that touches the outside world supplied by the
//! host: the websocket (wa_ws, TLS in the host), HTTP (wa_http), the clock (WASI) and stop
//! (wa_ctl). Single-threaded: one LocalPool polled by a main loop that also drives timers and host
//! I/O, so nothing ever blocks.
//!
//! Milestone 1: pair (by code when `pair_phone` is configured, else QR), connect, receive. The log
//! carries the pairing code, connection state and message metadata (chat, kind, id) - never content.
//! Store: store.rs - in-memory reads with write-through of durable state to the host (wa_kv);
//! a restart reconnects without pairing again.
use async_trait::async_trait;
use bytes::Bytes;
use futures::executor::{LocalPool, LocalSpawner};
use futures::task::LocalSpawnExt;
use std::cell::RefCell;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll, Waker};
use std::time::{Duration, Instant};
use wacore::net::{DisconnectReason, HttpClient, HttpRequest, HttpResponse, Transport, TransportEvent, TransportFactory, WHATSAPP_WEB_ORIGIN, WHATSAPP_WEB_WS_URL};
use wacore::runtime::{AbortHandle, Runtime};

mod store;

wit_bindgen::generate!({
    world: "service-component",
    path: "../../../wit/kernel",
});

use wa::kernel::types::Error as KError;
use wa::kernel::{http as khttp, lifecycle, websocket::Socket};


thread_local! {
    static STARTED: Instant = Instant::now();
}
/// Every log line carries seconds since start, so connection events can be ordered and timed.
macro_rules! say {
    ($($arg:tt)*) => {{
        let t = STARTED.with(|s| s.elapsed().as_secs_f32());
        println!("[{t:8.2}s] {}", format!($($arg)*));
    }};
}

// ---- the reactor: timers and host I/O, driven by the main loop -------------------------------

struct WsSlot {
    id: u32,
    socket: Socket,
    events: async_channel::Sender<TransportEvent>,
}

thread_local! {
    static TIMERS: RefCell<Vec<(Instant, Waker)>> = const { RefCell::new(Vec::new()) };
    static IO_WAKERS: RefCell<Vec<Waker>> = const { RefCell::new(Vec::new()) };
    static SOCKETS: RefCell<Vec<WsSlot>> = const { RefCell::new(Vec::new()) };
    static NEXT_SOCKET: std::cell::Cell<u32> = const { std::cell::Cell::new(1) };
}

/// Move host websocket frames into their transports' channels; returns whether anything moved.
fn pump_sockets() -> bool {
    let mut moved = false;
    SOCKETS.with(|sockets| {
        sockets.borrow_mut().retain(|slot| loop {
            match slot.socket.recv() {
                Ok(data) => {
                    moved = true;
                    if slot.events.try_send(TransportEvent::DataReceived(Bytes::from(data))).is_err() {
                        slot.socket.close();
                        return false;
                    }
                }
                Err(KError::Again) => return true,
                Err(_) => {
                    say!("transport: socket {} closed", slot.id);
                    let _ = slot.events.try_send(TransportEvent::Disconnected(DisconnectReason::StreamEnded));
                    moved = true;
                    return false;
                }
            }
        })
    });
    moved
}

/// Wake due timers; returns the time to the next one.
fn fire_timers() -> Option<Duration> {
    let now = Instant::now();
    TIMERS.with(|timers| {
        let mut timers = timers.borrow_mut();
        let (due, later): (Vec<_>, Vec<_>) = timers.drain(..).partition(|(at, _)| *at <= now);
        *timers = later;
        for (_, waker) in due {
            waker.wake();
        }
        timers.iter().map(|(at, _)| at.saturating_duration_since(now)).min()
    })
}

fn wake_io() {
    let wakers: Vec<Waker> = IO_WAKERS.with(|w| w.borrow_mut().drain(..).collect());
    for waker in wakers {
        waker.wake();
    }
}

struct Sleep(Instant);
impl Future for Sleep {
    type Output = ();
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if Instant::now() >= self.0 {
            return Poll::Ready(());
        }
        TIMERS.with(|t| t.borrow_mut().push((self.0, cx.waker().clone())));
        Poll::Pending
    }
}

struct YieldOnce(bool);
impl Future for YieldOnce {
    type Output = ();
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if self.0 {
            return Poll::Ready(());
        }
        self.0 = true;
        cx.waker().wake_by_ref();
        Poll::Pending
    }
}

// ---- Runtime --------------------------------------------------------------------------------

struct HostRuntime {
    spawner: LocalSpawner,
}
// Single-threaded guest: the runtime never crosses a thread.
unsafe impl Send for HostRuntime {}
unsafe impl Sync for HostRuntime {}

#[async_trait(?Send)]
impl Runtime for HostRuntime {
    fn spawn(&self, future: Pin<Box<dyn Future<Output = ()> + 'static>>) -> AbortHandle {
        let (task, handle) = futures::future::abortable(future);
        let _ = self.spawner.spawn_local(async move {
            let _ = task.await;
        });
        AbortHandle::new(move || handle.abort())
    }
    fn sleep(&self, duration: Duration) -> Pin<Box<dyn Future<Output = ()>>> {
        Box::pin(Sleep(Instant::now() + duration))
    }
    fn spawn_blocking(&self, f: Box<dyn FnOnce() + 'static>) -> Pin<Box<dyn Future<Output = ()>>> {
        f();
        Box::pin(std::future::ready(()))
    }
    fn yield_now(&self) -> Option<Pin<Box<dyn Future<Output = ()>>>> {
        Some(Box::pin(YieldOnce(false)))
    }
    fn yield_frequency(&self) -> u32 {
        1
    }
}

// ---- Transport over wa_ws -------------------------------------------------------------------

struct HostTransport {
    id: u32,
}
unsafe impl Send for HostTransport {}
unsafe impl Sync for HostTransport {}

#[async_trait(?Send)]
impl Transport for HostTransport {
    async fn send(&self, data: Bytes) -> Result<(), anyhow::Error> {
        SOCKETS.with(|s| match s.borrow().iter().find(|slot| slot.id == self.id) {
            Some(slot) => slot.socket.send(&data).map_err(|e| anyhow::anyhow!("websocket send: {e:?}")),
            None => Err(anyhow::anyhow!("websocket closed")),
        })
    }
    async fn disconnect(&self) {
        SOCKETS.with(|s| {
            s.borrow_mut().retain(|slot| {
                if slot.id == self.id {
                    slot.socket.close();
                    false
                } else {
                    true
                }
            })
        });
    }
}

struct HostTransportFactory;
unsafe impl Send for HostTransportFactory {}
unsafe impl Sync for HostTransportFactory {}

#[async_trait(?Send)]
impl TransportFactory for HostTransportFactory {
    async fn create_transport(&self) -> Result<(Arc<dyn Transport>, async_channel::Receiver<TransportEvent>), anyhow::Error> {
        let socket = Socket::connect(WHATSAPP_WEB_WS_URL, Some(WHATSAPP_WEB_ORIGIN)).map_err(|e| anyhow::anyhow!("websocket connect: {e:?}"))?;
        let id = NEXT_SOCKET.with(|n| {
            let id = n.get();
            n.set(id + 1);
            id
        });
        let (tx, rx) = async_channel::unbounded();
        let _ = tx.try_send(TransportEvent::Connected);
        SOCKETS.with(|s| s.borrow_mut().push(WsSlot { id, socket, events: tx }));
        say!("transport: connected (socket {id})");
        Ok((Arc::new(HostTransport { id }), rx))
    }
}

// ---- HttpClient over wa_http ----------------------------------------------------------------

struct HostHttp;
unsafe impl Send for HostHttp {}
unsafe impl Sync for HostHttp {}

struct HttpWait(khttp::Pending);
impl Future for HttpWait {
    type Output = Result<khttp::Response, KError>;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        match self.0.poll() {
            Err(KError::Again) => {
                IO_WAKERS.with(|w| w.borrow_mut().push(cx.waker().clone()));
                Poll::Pending
            }
            other => Poll::Ready(other),
        }
    }
}

#[async_trait(?Send)]
impl HttpClient for HostHttp {
    async fn execute(&self, request: HttpRequest) -> anyhow::Result<HttpResponse> {
        let req = khttp::Request {
            method: request.method,
            url: request.url,
            headers: request.headers.into_iter().collect(),
            body: request.body.map(|b| b.to_vec()).unwrap_or_default(),
        };
        let pending = khttp::Pending::start(&req).map_err(|e| anyhow::anyhow!("http start: {e:?}"))?;
        let response = HttpWait(pending).await.map_err(|e| anyhow::anyhow!("http exchange: {e:?}"))?;
        Ok(HttpResponse { status_code: response.status, body: response.body })
    }
}

// ---- the wall clock: wacore reads no clock on wasm32 unless given one ---------------------------
// Without this every timestamp is 1970 and the phone rejects the pair-code registration
// ("could not link device"). WASI's clock_time_get is the real wall clock under wasmtime.

struct WasiClock;
impl wacore::time::TimeProvider for WasiClock {
    fn now_millis(&self) -> i64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
    }
}

// ---- logging: route whatsapp-rust's `log` records into the service log -------------------------

struct Logger(log::LevelFilter);
impl log::Log for Logger {
    fn enabled(&self, meta: &log::Metadata) -> bool {
        meta.level() <= self.0
    }
    fn log(&self, record: &log::Record) {
        if self.enabled(record.metadata()) {
            say!("{} {}: {}", record.level(), record.target(), record.args());
        }
    }
    fn flush(&self) {}
}

// ---- the service ----------------------------------------------------------------------------

struct Service;
export!(Service);

impl exports::wa::kernel::service::Guest for Service {
    fn run(config: String) -> Result<(), String> {
        serve(serde_json::from_str(&config).unwrap_or_default());
        Ok(())
    }
}

fn serve(config: serde_json::Value) {
    let level = match config["log"].as_str().unwrap_or("info") {
        "debug" => log::LevelFilter::Debug,
        "trace" => log::LevelFilter::Trace,
        "warn" => log::LevelFilter::Warn,
        _ => log::LevelFilter::Info,
    };
    let _ = log::set_boxed_logger(Box::new(Logger(level))).map(|_| log::set_max_level(level));
    let _ = wacore::time::set_time_provider(WasiClock);
    say!("clock: {} ms since epoch", wacore::time::now_millis());
    let mut pool = LocalPool::new();
    let spawner = pool.spawner();
    let runtime = HostRuntime { spawner: spawner.clone() };
    let pair_phone = config["pair_phone"].as_str().map(str::to_string);
    say!("wa-whatsapp: starting (pairing by {})", if pair_phone.is_some() { "code" } else { "QR" });
    let _ = spawner.spawn_local(async move {
        use whatsapp_rust::prelude::*;
        use wacore::store::traits::DeviceStore;
        let backend = match store::PersistentBackend::open().await {
            Ok((backend, restored)) => {
                say!("store: {restored} entries restored");
                backend
            }
            Err(error) => {
                say!("store: unavailable ({error}); not starting");
                return;
            }
        };
        // A paired device on disk must never be replaced by a fresh one, even if the replay failed:
        // check the stored record itself, not only what the replay produced.
        let stored_paired = store::stored_device_paired();
        let paired = backend.load().await.ok().flatten().is_some_and(|d| d.pn.is_some());
        if stored_paired && !paired {
            say!("store: a paired device is on disk but the replay did not restore it; refusing to pair over it");
            return;
        }
        let pair_phone = if paired { None } else { pair_phone };
        say!("device: {}", if paired { "restored (no pairing needed)" } else { "new (pairing)" });
        let mut builder = Bot::builder()
            .with_backend(backend)
            .with_runtime(runtime)
            .with_transport_factory(HostTransportFactory)
            .with_http_client(HostHttp)
            .on_qr_code(|code, _timeout| async move { say!("pairing QR: {code}") })
            .on_pair_code(|code, timeout| async move { say!("PAIRING CODE: {code} (valid {}s) - WhatsApp > Linked devices > Link with phone number", timeout.as_secs()) })
            .on_connected(|_client| async move {
                say!("CONNECTED");
                lifecycle::report(lifecycle::Health::Ready, None);
            })
            .on_logged_out(|_client| async move { say!("LOGGED OUT") })
            .on_message(|ctx| {
                let line = format!("message chat={} kind={} media={} id={}", ctx.info.source.chat, ctx.info.r#type, ctx.info.media_type, ctx.info.id);
                async move { say!("{line}") }
            });
        if let Some(phone) = pair_phone {
            builder = builder.with_pair_code(wacore::pair_code::PairCodeOptions { phone_number: phone, ..Default::default() });
        }
        lifecycle::report(lifecycle::Health::Starting, None);
        match builder.build().await {
            Ok(bot) => bot.run().await,
            Err(error) => say!("build failed: {error}"),
        }
        say!("bot stopped");
    });
    loop {
        pool.run_until_stalled();
        let moved = pump_sockets();
        wake_io();
        let next_timer = fire_timers();
        if lifecycle::stopping() {
            say!("wa-whatsapp: stopping");
            return;
        }
        if !moved {
            let nap = next_timer.unwrap_or(Duration::from_millis(5)).min(Duration::from_millis(5));
            std::thread::sleep(nap);
        }
    }
}
