//! Service components on `wa:kernel@0.2` — the same grants, limits and supervisor as the 0.1
//! runner in `service_components.rs`, on WASI 0.3: a guest that suspends instead of polling.
//!
//! What is the same: the manifest grants (`net` addresses, `storage` namespace, `file_env` secrets,
//! `stt`), the memory cap from `limits.memory_mb`, stdout/stderr into the service log, the epoch
//! deadline that stops a stopped-but-unresponsive guest after the grace period, and the shape of
//! the outcome string (`exit_0`, `stopped`, `exit_3`, `trap:…`) the supervisor reports.
//!
//! What differs is where the waiting happens. In 0.1 the guest owned a reactor and called
//! `recv`/`poll`/`segments` in a loop; here the host hands the guest a `stream`/`future` and the
//! guest awaits it. The host half is one `StreamProducer` per inbound socket, per response body and
//! per recognizer, plus one `FutureProducer` for the transcript; each is woken by the same
//! `service_io` worker that fed the 0.1 poll contract (`Notify`/`Slot`, woken from the pump thread).
//!
//! Version detection is the caller's job (`services.rs`): a component whose imports name
//! `wa:kernel/*@0.2.0` runs here, everything else runs on 0.1 or as a wasip1 core module, unchanged.
//!
//! Governance is the 0.1 runner's, unchanged in order and in reason (`docs/GRANT-POLICY.md`, "How
//! the host wires it"): the **manifest grant** first (`net`/`storage`/`file_env`/`stt`), then the
//! **node policy** - and a node with no `policy.json` runs in manifest mode, exactly as 0.1 does.
//! The checks are the same ones at the same points: `net.dial` on `websocket.connect`,
//! `net.send`+`whatsapp.send` on an opaque `websocket.send`, `http.request` on `http.send`,
//! `kv.read`/`kv.write` on the store, `credentials.read`, `stt.start`. Both runners call the same
//! `service_components::{gate, target_of, authority_target}` so the two contracts cannot drift into
//! two different policies. Every answered host call records one telemetry observation
//! (`node_telemetry::HostCallGuard`), attributed to the component by name.
use crate::components::{Grant, Installed};
use crate::node_telemetry::HostCallGuard;
use crate::service_components::{authority_target, gate_verdict, target_of, Verdict};
use wa_grant_policy::Decision;
use crate::service_io::{http_exchange, url_authority, Kv as KvStore, Slot, SlotFuture, WsConn};
use crate::services::{dial_allowed, Shared};
use std::io::Write as _;
use std::pin::Pin;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use wasmtime::component::{
    Access, Accessor, Component, Destination, FutureProducer, FutureReader, HasData, Linker, Resource, ResourceTable, StreamProducer, StreamReader,
    StreamResult,
};
use wasmtime::{AsContextMut, Store, StoreContextMut, StoreLimits, StoreLimitsBuilder, UpdateDeadline};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

use crate::service_components::service_stt;

const STOP_GRACE: Duration = Duration::from_secs(5);
/// How much of a response body one stream item carries. The exchange itself is buffered whole (the
/// 0.1 contract's `read_to_vec`), so this only decides the chunk size the guest sees.
const BODY_CHUNK: usize = 64 << 10;

wasmtime::component::bindgen!({
    world: "service-component",
    path: "../../wit/kernel-v2",
    // Every `async func` in the WIT is already lowered with the store (bindgen decides that from
    // WIT, not from here); these rules add the store to the four *synchronous* calls that hand the
    // guest a stream or a future, because the transmit handle is created from it.
    imports: {
        "wa:kernel/websocket.[method]socket.messages": store | trappable,
        "wa:kernel/http.[method]response.body": store | trappable,
        "wa:kernel/speech.[method]recognition.segments": store | trappable,
        "wa:kernel/speech.[method]recognition.transcript": store | trappable,
    },
    exports: { default: async | store },
    with: {
        "wa:kernel/websocket.socket": WsSocket,
        "wa:kernel/http.response": HttpResponse,
        "wa:kernel/speech.recognition": Recognition,
    },
});

use wa::kernel::types::Error as KError;

/// The guest's socket: the 0.1 host-side connection, handed out as a stream instead of a poll.
///
/// The authority it was granted for is kept beside the connection because `websocket.send` takes
/// ciphertext: the address is the only target the policy layer can name for the interim
/// `whatsapp.send` budget (`docs/GRANT-POLICY.md`, "The honest gap").
pub struct WsSocket {
    conn: Option<WsConn>,
    authority: String,
}

/// A completed exchange plus the body the guest drains as a stream.
pub struct HttpResponse {
    status: u16,
    headers: Vec<(String, String)>,
    body: Option<Vec<u8>>,
}

/// A queued recognition: the same job slot the 0.1 guest polls, exposed as segments + result.
pub struct Recognition {
    slot: service_stt::JobSlot,
    language: String,
    started: Instant,
}

pub struct State {
    wasi: WasiCtx,
    table: ResourceTable,
    limits: StoreLimits,
    net: Vec<String>,
    shared: Arc<Shared>,
    kv: KvStore,
    log: Option<std::fs::File>,
    secrets: std::collections::BTreeMap<String, String>,
    /// Manifest `capabilities.stt == true`.
    stt: bool,
    /// The installed name: policy checks and telemetry are attributed to the component, so one
    /// running instance answers "who called this" without a second registry (as in 0.1).
    name: String,
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

/// The store's data projection is the state itself, so the store-taking imports (`messages`,
/// `body`, `segments`, `result`, `connect`, `send`, `recognize`) reach it as `&mut State`.
impl HasData for State {
    type Data<'a> = &'a mut State;
}

/// The shared store's errors as the kernel's (identical to the 0.1 runner).
fn kv_error(error: String) -> KError {
    if error == "storage not declared" {
        KError::Refused(error)
    } else {
        KError::Failed(error)
    }
}

/// The installed name for attribution: a 0.2 host function is an `async fn` over `Accessor`, so it
/// has no `&self`, and the name comes out of the store's state instead.
fn who(accessor: &Accessor<State, State>) -> String {
    accessor.with(|mut access| access.get().name.clone())
}

/// The 0.1 runner's `gate`, spelled with this bindings module's `KError`: the table itself is
/// `service_components::gate_verdict`, so both contracts answer a policy question identically.
fn gate_decision(decision: Decision) -> Result<(), KError> {
    match gate_verdict(decision) {
        Verdict::Allow => Ok(()),
        Verdict::Again => Err(KError::Again),
        Verdict::Refuse(reason) => Err(KError::Refused(reason)),
    }
}

/// Ask the node policy before a host call does anything (`docs/GRANT-POLICY.md`): a node with no
/// `policy.json` answers in manifest mode (the manifest grant is the only gate), a node with one
/// enforces it, and an unruled sensitive capability is refused `no_policy`.
fn gate(component: &str, capability: &str, target: Option<&str>) -> Result<(), KError> {
    gate_decision(crate::node_policy::check(component, capability, target))
}

impl wa::kernel::types::Host for State {}

impl wa::kernel::kv::Host for State {}

/// kv is `async` in the 0.2 contract but the answer is local: nothing is awaited, so a call
/// completes in the same poll it started in (docs/KERNEL.md keeps a local store synchronous in
/// spirit; the async shape is what the job asked of 0.2). The policy gate and the telemetry guard
/// are the 0.1 runner's, at the same points: a read is `kv.read`, a write is `kv.write`, and the
/// key is the target (`docs/GRANT-POLICY.md`).
impl wa::kernel::kv::HostWithStore<State> for State {
    async fn get(accessor: &Accessor<State, Self>, key: Vec<u8>) -> Result<Option<Vec<u8>>, KError> {
        let name = who(accessor);
        let mut call = HostCallGuard::start(&name, "kv.get");
        let target = target_of(&key);
        let out = (|| {
            gate(&name, "kv.read", Some(&target))?;
            accessor.with(|mut access| access.get().kv.get(key).map_err(kv_error))
        })();
        call.outcome(&out);
        out
    }
    async fn set(accessor: &Accessor<State, Self>, key: Vec<u8>, value: Vec<u8>) -> Result<(), KError> {
        let name = who(accessor);
        let mut call = HostCallGuard::start(&name, "kv.set");
        let target = target_of(&key);
        let out = (|| {
            // A write is a shadow copy of state: sensitive by default, so a node with a policy file
            // and no rule for it refuses the write with `no_policy` (a node with no policy file
            // runs in manifest mode, and the manifest grant is the only gate).
            gate(&name, "kv.write", Some(&target))?;
            accessor.with(|mut access| access.get().kv.set(key, value).map_err(kv_error))
        })();
        call.outcome(&out);
        out
    }
    async fn delete(accessor: &Accessor<State, Self>, key: Vec<u8>) -> Result<(), KError> {
        let name = who(accessor);
        let mut call = HostCallGuard::start(&name, "kv.delete");
        let target = target_of(&key);
        let out = (|| {
            gate(&name, "kv.write", Some(&target))?;
            accessor.with(|mut access| access.get().kv.delete(key).map_err(kv_error))
        })();
        call.outcome(&out);
        out
    }
    async fn delete_prefix(accessor: &Accessor<State, Self>, prefix: Vec<u8>) -> Result<u32, KError> {
        let name = who(accessor);
        let mut call = HostCallGuard::start(&name, "kv.delete_prefix");
        let target = target_of(&prefix);
        let out = (|| {
            gate(&name, "kv.write", Some(&target))?;
            accessor.with(|mut access| access.get().kv.delete_prefix(prefix).map_err(kv_error))
        })();
        call.outcome(&out);
        out
    }
    async fn scan(accessor: &Accessor<State, Self>, prefix: Vec<u8>, cursor: Option<Vec<u8>>, limit: u32) -> Result<Vec<wa::kernel::kv::Entry>, KError> {
        let name = who(accessor);
        let mut call = HostCallGuard::start(&name, "kv.scan");
        let target = target_of(&prefix);
        let out = (|| {
            gate(&name, "kv.read", Some(&target))?;
            accessor.with(|mut access| {
                let rows = access.get().kv.scan(prefix, cursor, limit).map_err(kv_error)?;
                Ok(rows.into_iter().map(|(key, value)| wa::kernel::kv::Entry { key, value }).collect())
            })
        })();
        call.outcome(&out);
        out
    }
}

/// Lifecycle: never policy-checked (a component must be able to report that it is ready, and a stop
/// the operator asked for is already the operator's decision), recorded for latency like every
/// other call - the same rule as 0.1 (`docs/GRANT-POLICY.md` step 4).
impl wa::kernel::lifecycle::Host for State {
    fn stopping(&mut self) -> bool {
        let mut call = HostCallGuard::start(&self.name, "lifecycle.stopping");
        let stopping = self.shared.stop.load(Ordering::Relaxed);
        call.succeed();
        stopping
    }
    fn report(&mut self, state: wa::kernel::lifecycle::Health, detail: Option<String>) {
        let mut call = HostCallGuard::start(&self.name, "lifecycle.report");
        let text = match state {
            wa::kernel::lifecycle::Health::Starting => "starting",
            wa::kernel::lifecycle::Health::Ready => "ready",
            wa::kernel::lifecycle::Health::Degraded => "degraded",
        };
        *self.shared.health.lock().unwrap() = format!("{text}{}", detail.map(|d| format!(": {d}")).unwrap_or_default());
        call.succeed();
    }
}

impl wa::kernel::log::Host for State {
    /// Never policy-checked: a log line cannot exceed anything a person sees
    /// (`docs/GRANT-POLICY.md` step 4). The file is the bounded `<component>.service.log`
    /// `services.rs` opens and rotates at its quota (`store.rs`), so the quota is per component and
    /// the same one the 0.1 runner writes into.
    fn write(&mut self, level: wa::kernel::log::Level, target: String, message: String) {
        let mut call = HostCallGuard::start(&self.name, "log.write");
        if let Some(file) = self.log.as_mut() {
            let _ = writeln!(file, "{:?} {target}: {message}", level);
        }
        call.succeed();
    }
}

impl wa::kernel::credentials::Host for State {
    /// A secret is the most sensitive thing a component can ask for, so the policy is asked first
    /// and the name of the secret is the target (`docs/GRANT-POLICY.md`).
    fn get(&mut self, name: String) -> Result<String, KError> {
        let mut call = HostCallGuard::start(&self.name, "credentials.get");
        let out = (|| {
            gate(&self.name, "credentials.read", Some(&name))?;
            self.secrets.get(&name).cloned().ok_or(KError::Refused(name))
        })();
        call.outcome(&out);
        out
    }
}

// ---- websocket: an inbound stream in, one suspendable send out ---------------------------------

impl wa::kernel::websocket::Host for State {}
impl wa::kernel::websocket::HostSocket for State {
    fn close(&mut self, socket: Resource<WsSocket>, _code: u16, _reason: String) {
        let mut call = HostCallGuard::start(&self.name, "websocket.close");
        if let Ok(s) = self.table.get_mut(&socket) {
            s.conn = None;
        }
        call.succeed();
    }
    fn drop(&mut self, socket: Resource<WsSocket>) -> wasmtime::Result<()> {
        self.table.delete(socket)?;
        Ok(())
    }
}

impl wa::kernel::websocket::HostSocketWithStore<State> for State {
    /// One frame, answered from the host's outbound queue: this never waits today, so the guest's
    /// `send().await` completes in one poll. The async shape is what lets it wait later, when the
    /// queue is full, without changing the guest.
    ///
    /// The frame is opaque, so what the host can charge is the socket's authority and the global
    /// message budget, and only for a policy rule that names no chats
    /// (`node_policy::check_opaque_send`, exactly the 0.1 `websocket.send` path). The per-chat check
    /// needs `wa:channel/messages`; until it exists this is the honest cap.
    async fn send(accessor: &Accessor<State, Self>, socket: Resource<WsSocket>, frame: Vec<u8>) -> Result<(), KError> {
        let name = who(accessor);
        let mut call = HostCallGuard::start(&name, "websocket.send");
        let out = (|| {
            let authority = accessor.with(|mut access| {
                access.get().table.get(&socket).ok().map(|s| s.authority.clone()).ok_or(KError::Closed)
            })?;
            match crate::node_policy::check_opaque_send(&name, &authority) {
                Decision::Allow => {}
                Decision::RateLimited { retry_after_ms, .. } if retry_after_ms < 1_000 => return Err(KError::Again),
                other => return Err(KError::Refused(other.reason_str().to_string())),
            }
            accessor.with(|mut access| {
                match access.get().table.get(&socket).ok().and_then(|s| s.conn.as_ref()) {
                    Some(conn) if conn.send(frame) == 0 => Ok(()),
                    _ => Err(KError::Closed),
                }
            })
        })();
        call.outcome(&out);
        out
    }

    /// The handshake is the kernel's, on its own thread: the guest task parks and the store's other
    /// tasks keep running (0.1 could not offer this without the guest polling for readiness).
    async fn connect(accessor: &Accessor<State, Self>, url: String, origin: Option<String>) -> Result<Resource<WsSocket>, KError> {
        let name = who(accessor);
        let mut call = HostCallGuard::start(&name, "websocket.connect");
        let out: Result<Resource<WsSocket>, KError> = async {
            // Grant first, policy second: a rule can only ever narrow what the manifest allows.
            let authority = accessor.with(|mut access| {
                let state = access.get();
                url_authority(&url).filter(|addr| dial_allowed(&state.net, addr))
            });
            let authority = authority.ok_or_else(|| KError::Refused(url.clone()))?;
            gate(&name, "net.dial", Some(&authority_target(&authority)))?;
            let slot = Slot::new();
            let done = slot.clone();
            let spawned = std::thread::Builder::new()
                .name("wa-service-ws-connect".into())
                .spawn(move || done.put(WsConn::open(&url, origin.as_deref())));
            let conn = match spawned {
                Ok(_) => SlotFuture(slot).await,
                Err(error) => Err(error.to_string()),
            };
            let conn = conn.map_err(KError::Failed)?;
            accessor.with(|mut access| {
                access.get().table.push(WsSocket { conn: Some(conn), authority }).map_err(|e| KError::Failed(e.to_string()))
            })
        }
        .await;
        call.outcome(&out);
        out
    }

    fn messages(mut access: Access<State, Self>, socket: Resource<WsSocket>) -> wasmtime::Result<StreamReader<Vec<u8>>> {
        StreamReader::new(access.as_context_mut(), FrameProducer { socket })
    }
}

/// Inbound frames as the stream `socket.messages()` returns: each poll moves whatever the pump has
/// queued and parks the task when it has nothing (the pump's `Notify` wakes it).
struct FrameProducer {
    socket: Resource<WsSocket>,
}

impl StreamProducer<State> for FrameProducer {
    type Item = Vec<u8>;
    type Buffer = Option<Vec<u8>>;

    fn poll_produce<'a>(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        mut store: StoreContextMut<'a, State>,
        mut dst: Destination<'a, Self::Item, Self::Buffer>,
        finish: bool,
    ) -> Poll<wasmtime::Result<StreamResult>> {
        let name = store.data_mut().name.clone();
        let Some(conn) = store.data_mut().table.get_mut(&self.socket).ok().and_then(|s| s.conn.as_mut()) else {
            return Poll::Ready(Ok(StreamResult::Dropped));
        };
        match conn.poll_next(cx) {
            Poll::Ready(Some(frame)) => {
                // One delivered frame is one `recv` in 0.1 terms, so it is recorded under the same
                // capability name and a dashboard reads both contracts the same way.
                let mut call = HostCallGuard::start(&name, "websocket.recv");
                dst.set_buffer(Some(frame));
                call.succeed();
                Poll::Ready(Ok(StreamResult::Completed))
            }
            Poll::Ready(None) => Poll::Ready(Ok(StreamResult::Dropped)),
            Poll::Pending if finish => Poll::Ready(Ok(StreamResult::Cancelled)),
            Poll::Pending => Poll::Pending,
        }
    }
}

// ---- http: one suspendable exchange, a body stream out -----------------------------------------

impl wa::kernel::http::Host for State {}
impl wa::kernel::http::HostResponse for State {
    fn status(&mut self, response: Resource<HttpResponse>) -> u16 {
        self.table.get(&response).map(|r| r.status).unwrap_or(0)
    }
    fn headers(&mut self, response: Resource<HttpResponse>) -> Vec<(String, String)> {
        self.table.get(&response).map(|r| r.headers.clone()).unwrap_or_default()
    }
    fn drop(&mut self, response: Resource<HttpResponse>) -> wasmtime::Result<()> {
        self.table.delete(response)?;
        Ok(())
    }
}

impl wa::kernel::http::HostResponseWithStore<State> for State {
    fn body(mut access: Access<State, Self>, response: Resource<HttpResponse>) -> wasmtime::Result<StreamReader<Vec<u8>>> {
        let body = access.data_mut().table.get_mut(&response).ok().and_then(|r| r.body.take()).unwrap_or_default();
        let chunks: Vec<Vec<u8>> = body.chunks(BODY_CHUNK).map(|chunk| chunk.to_vec()).collect();
        StreamReader::new(access.as_context_mut(), BodyProducer { chunks: chunks.into_iter() })
    }
}

/// A response body, chunk by chunk, from the buffer the exchange filled.
struct BodyProducer {
    chunks: std::vec::IntoIter<Vec<u8>>,
}

impl StreamProducer<State> for BodyProducer {
    type Item = Vec<u8>;
    type Buffer = Option<Vec<u8>>;

    fn poll_produce<'a>(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        _store: StoreContextMut<'a, State>,
        mut dst: Destination<'a, Self::Item, Self::Buffer>,
        _finish: bool,
    ) -> Poll<wasmtime::Result<StreamResult>> {
        match self.get_mut().chunks.next() {
            Some(chunk) => {
                dst.set_buffer(Some(chunk));
                Poll::Ready(Ok(StreamResult::Completed))
            }
            None => Poll::Ready(Ok(StreamResult::Dropped)),
        }
    }
}

impl wa::kernel::http::HostWithStore<State> for State {
    /// `http.send`: the exchange runs on its own thread (as in 0.1) and the guest awaits the result
    /// instead of polling for it. The grant check is the same `url_authority` + `dial_allowed` pair,
    /// and the policy is asked second, exactly as 0.1's `http.start` asks it.
    async fn send(accessor: &Accessor<State, Self>, request: wa::kernel::http::Request) -> Result<Resource<HttpResponse>, KError> {
        let name = who(accessor);
        let mut call = HostCallGuard::start(&name, "http.send");
        let out: Result<Resource<HttpResponse>, KError> = async {
            let authority = accessor.with(|mut access| {
                let state = access.get();
                url_authority(&request.url).filter(|addr| dial_allowed(&state.net, addr))
            });
            let authority = authority.ok_or_else(|| KError::Refused(request.url.clone()))?;
            gate(&name, "http.request", Some(&authority_target(&authority)))?;
            let headers: serde_json::Map<String, serde_json::Value> =
                request.headers.into_iter().map(|(k, v)| (k, serde_json::Value::String(v))).collect();
            let meta = serde_json::json!({"url": request.url, "method": request.method, "headers": headers});
            let slot = http_exchange(&meta, request.body).map_err(KError::Failed)?;
            let outcome = SlotFuture(slot).await.map_err(KError::Failed)?;
            let response = HttpResponse { status: outcome.status, headers: outcome.headers, body: Some(outcome.body) };
            accessor.with(|mut access| access.get().table.push(response).map_err(|e| KError::Failed(e.to_string())))
        }
        .await;
        call.outcome(&out);
        out
    }
}

// ---- speech: segments in, the transcript once ---------------------------------------------------

impl wa::kernel::speech::Host for State {}
impl wa::kernel::speech::HostRecognition for State {
    fn drop(&mut self, recognition: Resource<Recognition>) -> wasmtime::Result<()> {
        self.table.delete(recognition)?;
        Ok(())
    }
}

impl wa::kernel::speech::HostWithStore<State> for State {
    /// Queue `audio` for the node's recognizer (the same hub the 0.1 guest polls) and hand back the
    /// resource that carries the segment stream and the result future.
    async fn recognize(accessor: &Accessor<State, Self>, audio: Vec<u8>, mime: String, language: String) -> Result<Resource<Recognition>, KError> {
        let name = who(accessor);
        let mut call = HostCallGuard::start(&name, "speech.recognize");
        let out = (|| {
            if !accessor.with(|mut access| access.get().stt) {
                return Err(KError::Refused("stt not declared".into()));
            }
            gate(&name, "stt.start", None)?;
            let slot = service_stt::submit(audio, &mime, &language).map_err(KError::Failed)?;
            accessor.with(|mut access| {
                access.get().table.push(Recognition { slot, language, started: Instant::now() }).map_err(|e| KError::Failed(e.to_string()))
            })
        })();
        call.outcome(&out);
        out
    }
}

impl wa::kernel::speech::HostRecognitionWithStore<State> for State {
    fn segments(mut access: Access<State, Self>, recognition: Resource<Recognition>) -> wasmtime::Result<StreamReader<wa::kernel::speech::Segment>> {
        let (slot, started) = match access.data_mut().table.get(&recognition) {
            Ok(r) => (r.slot.clone(), r.started),
            Err(_) => return Err(wasmtime::Error::msg("recognition gone")),
        };
        StreamReader::new(access.as_context_mut(), SegmentProducer { slot, cursor: 0, started, offset_ms: 0 })
    }

    fn transcript(
        mut access: Access<State, Self>,
        recognition: Resource<Recognition>,
    ) -> wasmtime::Result<FutureReader<Result<wa::kernel::speech::Transcript, KError>>> {
        let (slot, language) = match access.data_mut().table.get(&recognition) {
            Ok(r) => (r.slot.clone(), r.language.clone()),
            Err(_) => return Err(wasmtime::Error::msg("recognition gone")),
        };
        FutureReader::new(access.as_context_mut(), TranscriptFuture { slot, language })
    }
}

/// The recognizer's segments as a stream: each poll emits the segments the worker has appended since
/// the last one, and parks on the job's `Notify` between them.
struct SegmentProducer {
    slot: service_stt::JobSlot,
    cursor: usize,
    started: Instant,
    /// Where the last emitted segment ended, so `start-ms`/`end-ms` are contiguous.
    offset_ms: u64,
}

impl SegmentProducer {
    /// The next segment, whether the job has finished, and the job's wake-up edge — taken under the
    /// lock so nothing is held while the destination buffer is written.
    fn next_segment(&mut self) -> (Option<wa::kernel::speech::Segment>, bool, Arc<crate::service_io::Notify>) {
        let job = self.slot.lock().unwrap();
        let terminal = matches!(job.state, service_stt::JobState::Done { .. } | service_stt::JobState::Failed(_));
        let notify = job.notify.clone();
        let Some(text) = job.segments.get(self.cursor).cloned() else {
            return (None, terminal, notify);
        };
        self.cursor += 1;
        // The worker reports the audio duration decoded so far, not per-segment audio positions, so
        // a segment ends where the decode had reached when it was emitted (falling back to the wall
        // clock when the worker reported no duration) and starts where the previous one ended.
        let end_ms = if job.duration_ms > 0 { job.duration_ms } else { self.started.elapsed().as_millis() as u64 }.max(self.offset_ms);
        let segment = wa::kernel::speech::Segment { start_ms: self.offset_ms, end_ms, text };
        self.offset_ms = end_ms;
        (Some(segment), terminal, notify)
    }
}

impl StreamProducer<State> for SegmentProducer {
    type Item = wa::kernel::speech::Segment;
    type Buffer = Option<wa::kernel::speech::Segment>;

    fn poll_produce<'a>(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        _store: StoreContextMut<'a, State>,
        mut dst: Destination<'a, Self::Item, Self::Buffer>,
        finish: bool,
    ) -> Poll<wasmtime::Result<StreamResult>> {
        let me = self.get_mut();
        let (segment, terminal, notify) = me.next_segment();
        if let Some(segment) = segment {
            dst.set_buffer(Some(segment));
            // The last segment of a finished job ends the stream in the same read.
            return Poll::Ready(Ok(if terminal { StreamResult::Dropped } else { StreamResult::Completed }));
        }
        if terminal {
            return Poll::Ready(Ok(StreamResult::Dropped));
        }
        if finish {
            return Poll::Ready(Ok(StreamResult::Cancelled));
        }
        if notify.poll(cx).is_ready() {
            // Woken by a segment or by the job finishing: answer in this read if there is anything.
            let (segment, terminal, _) = me.next_segment();
            if let Some(segment) = segment {
                dst.set_buffer(Some(segment));
                return Poll::Ready(Ok(if terminal { StreamResult::Dropped } else { StreamResult::Completed }));
            }
            if terminal {
                return Poll::Ready(Ok(StreamResult::Dropped));
            }
        }
        Poll::Pending
    }
}

/// The whole transcript, as the future `recognition.result()` returns.
struct TranscriptFuture {
    slot: service_stt::JobSlot,
    language: String,
}

impl FutureProducer<State> for TranscriptFuture {
    type Item = Result<wa::kernel::speech::Transcript, KError>;

    fn poll_produce(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        _store: StoreContextMut<State>,
        finish: bool,
    ) -> Poll<wasmtime::Result<Option<Self::Item>>> {
        let me = self.get_mut();
        let job = me.slot.lock().unwrap();
        let state = job.state.clone();
        let notify = job.notify.clone();
        drop(job);
        let resolved = match state {
            service_stt::JobState::Queued => None,
            service_stt::JobState::Done { text, elapsed_ms } => {
                Some(Ok(wa::kernel::speech::Transcript { text, language: me.language.clone(), elapsed_ms }))
            }
            service_stt::JobState::Failed(reason) => Some(Err(KError::Failed(reason))),
        };
        if let Some(value) = resolved {
            return Poll::Ready(Ok(Some(value)));
        }
        if finish {
            return Poll::Ready(Ok(None));
        }
        if notify.poll(cx).is_ready() {
            let job = me.slot.lock().unwrap();
            let state = job.state.clone();
            drop(job);
            match state {
                service_stt::JobState::Queued => Poll::Pending,
                service_stt::JobState::Done { text, elapsed_ms } => Poll::Ready(Ok(Some(Ok(wa::kernel::speech::Transcript {
                    text,
                    language: me.language.clone(),
                    elapsed_ms,
                })))),
                service_stt::JobState::Failed(reason) => Poll::Ready(Ok(Some(Err(KError::Failed(reason))))),
            }
        } else {
            // A job that was queued and is still queued: park until the hub wakes us again.
            Poll::Pending
        }
    }
}

/// Two futures, whichever finishes first — enough of `select` for the stop watchdog, without a
/// dependency for it.
struct Race<A: std::future::Future, B: std::future::Future>(Pin<Box<A>>, Pin<Box<B>>);

enum Either<A, B> {
    Left(A),
    Right(B),
}

impl<A: std::future::Future, B: std::future::Future> std::future::Future for Race<A, B> {
    type Output = Either<A::Output, B::Output>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        if let Poll::Ready(value) = self.0.as_mut().poll(cx) {
            return Poll::Ready(Either::Left(value));
        }
        if let Poll::Ready(value) = self.1.as_mut().poll(cx) {
            return Poll::Ready(Either::Right(value));
        }
        Poll::Pending
    }
}

/// Resolves once the supervisor asked for a stop and the grace period is over: the runner then drops
/// the guest, which is the only way to end a 0.2 task that is parked rather than running.
async fn stop_watchdog(shared: Arc<Shared>) {
    loop {
        tokio::time::sleep(Duration::from_millis(50)).await;
        if shared.stop.load(Ordering::Relaxed) {
            tokio::time::sleep(STOP_GRACE).await;
            return;
        }
    }
}

/// One run of `service.run(config)` until it returns, traps, or is stopped. Same grants and limits
/// as `service_components::run_once`; the difference is the store's async event loop and the
/// current-thread runtime that gives `wasi:clocks@0.3.0` its timer.
pub fn run_once(installed: &Installed, grant: &Grant, component: &Component, shared: &Arc<Shared>, log_file: std::fs::File) -> String {
    let mut builder = WasiCtxBuilder::new();
    builder.args(&[installed.name.as_str()]);
    if let Ok(clone) = log_file.try_clone() {
        builder.stdout(wasmtime_wasi::cli::OutputFile::new(clone));
    }
    if let Ok(clone) = log_file.try_clone() {
        builder.stderr(wasmtime_wasi::cli::OutputFile::new(clone));
    }
    for (key, name) in &grant.env {
        if let Ok(value) = std::env::var(name) {
            builder.env(key, &value);
        }
    }
    // Secrets are read by the host from their file and handed only through `credentials.get`.
    let mut secrets = std::collections::BTreeMap::new();
    for (key, name) in &grant.file_env {
        let path = if name.starts_with('/') || name.as_bytes().get(1) == Some(&b':') { name.clone() } else { std::env::var(name).unwrap_or_default() };
        if let Ok(value) = std::fs::read_to_string(&path) {
            secrets.insert(key.clone(), value.trim().to_string());
        }
    }
    let memory_mb = installed.manifest.get("limits").and_then(|l| l.get("memory_mb")).and_then(serde_json::Value::as_u64).unwrap_or(512).clamp(16, 4096);
    let storage = installed.manifest.get("capabilities").and_then(|c| c.get("storage")).and_then(serde_json::Value::as_bool) == Some(true);
    let stt = installed.manifest.get("capabilities").and_then(|c| c.get("stt")).and_then(serde_json::Value::as_bool) == Some(true);
    if stt {
        service_stt::prewarm(); // the model loads before the first note, as in 0.1
    }
    let state = State {
        wasi: builder.build(),
        table: ResourceTable::new(),
        limits: StoreLimitsBuilder::new().memory_size((memory_mb as usize) << 20).instances(64).build(),
        net: grant.net.clone(),
        shared: shared.clone(),
        kv: KvStore::new(storage.then(|| crate::components::component_dir().join(format!("{}.state", installed.name)).join("kv.sqlite"))),
        log: Some(log_file),
        secrets,
        stt,
        name: installed.name.clone(),
    };
    let engine = component.engine();
    let mut store = Store::new(engine, state);
    store.limiter(|s| &mut s.limits);
    let stop_seen: Arc<Mutex<Option<Instant>>> = Arc::new(Mutex::new(None));
    let watcher = shared.clone();
    store.epoch_deadline_callback(move |_| {
        if watcher.stop.load(Ordering::Relaxed) {
            let mut seen = stop_seen.lock().unwrap();
            if seen.get_or_insert_with(Instant::now).elapsed() > STOP_GRACE {
                return Err(wasmtime::Error::msg("service_stopped"));
            }
        }
        Ok(UpdateDeadline::Continue(10))
    });
    store.set_epoch_deadline(10);
    let mut linker: Linker<State> = Linker::new(engine);
    if let Err(error) = wasmtime_wasi::p2::add_to_linker_async(&mut linker) {
        return format!("link_failed:{error}");
    }
    // The WASI 0.3 timer a native-async guest awaits; a guest that never waits needs it not at all.
    if let Err(error) = wasmtime_wasi::p3::clocks::add_to_linker::<State>(&mut linker) {
        return format!("link_failed:{error}");
    }
    for added in [
        wa::kernel::websocket::add_to_linker::<State, State>(&mut linker, |s| s),
        wa::kernel::http::add_to_linker::<State, State>(&mut linker, |s| s),
        wa::kernel::speech::add_to_linker::<State, State>(&mut linker, |s| s),
        wa::kernel::kv::add_to_linker::<State, State>(&mut linker, |s| s),
        wa::kernel::lifecycle::add_to_linker::<State, State>(&mut linker, |s| s),
        wa::kernel::log::add_to_linker::<State, State>(&mut linker, |s| s),
        wa::kernel::credentials::add_to_linker::<State, State>(&mut linker, |s| s),
    ] {
        if let Err(error) = added {
            return format!("link_failed:{error}");
        }
    }
    let config = grant.config.clone().unwrap_or_else(|| "{}".into());
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_time().build() {
        Ok(runtime) => runtime,
        Err(error) => return format!("runtime_failed:{error}"),
    };
    // The guest's `run` is one suspendable call: `run_concurrent` is what lets the streams, the
    // futures and the WASI timers it awaits make progress while it is parked. The stop watchdog
    // races it: the epoch deadline stops a guest that is *running*, but a guest parked in a timer
    // or a stream read has no wasm to interrupt, so after the grace its future is dropped instead.
    let outcome = runtime.block_on(async {
        let bindings = match ServiceComponent::instantiate_async(&mut store, component, &linker).await {
            Ok(bindings) => bindings,
            Err(error) => return Err(("instantiate_failed", error)),
        };
        let guest = store.run_concurrent(async move |store| bindings.wa_kernel_service().call_run(store, config).await);
        match Race(Box::pin(guest), Box::pin(stop_watchdog(shared.clone()))).await {
            Either::Left(Ok(Ok(outcome))) => Ok(outcome),
            Either::Left(Ok(Err(error))) => Err(("concurrent_failed", error)),
            Either::Left(Err(error)) => Err(("call_failed", error)),
            Either::Right(()) => Err(("stopped", wasmtime::Error::msg("stop grace expired"))),
        }
    });
    match outcome {
        Ok(Ok(())) => "exit_0".into(),
        Ok(Err(reason)) => format!("service_error:{reason}").chars().take(300).collect(),
        Err(("stopped", _)) => "stopped".to_string(),
        Err((kind, error)) => {
            if let Some(exit) = error.downcast_ref::<wasmtime_wasi::I32Exit>() {
                return format!("exit_{}", exit.0);
            }
            if shared.stop.load(Ordering::Relaxed) {
                return "stopped".into();
            }
            format!("{kind}:{}", error.root_cause()).chars().take(300).collect()
        }
    }
}

/// Which `wa:kernel` contract a component speaks, read from its own imports: the 0.2 package is
/// imported as `wa:kernel/<interface>@0.2.0`, so the component type answers this without running
/// anything. A component that imports no `wa:kernel` interface at all is not a service.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Contract {
    V1,
    V2,
}

impl Contract {
    pub fn of(component: &Component) -> Contract {
        let engine = component.engine();
        let ty = component.component_type();
        let names: Vec<&str> = ty.imports(engine).map(|(name, _)| name).collect();
        if names.iter().any(|name| is_kernel_v2(name)) {
            Contract::V2
        } else {
            Contract::V1
        }
    }
}

/// `wa:kernel/<interface>@0.2.0`, the only spelling a 0.2 import has.
fn is_kernel_v2(name: &str) -> bool {
    match name.strip_prefix("wa:kernel/") {
        Some(rest) => rest.ends_with("@0.2.0"),
        None => false,
    }
}

/// The engine the 0.2 runner needs: the component model plus native async. Deliberately separate
/// from `components::engine()` so that no existing component (0.1 services, MCP, agent-core)
/// changes the engine it is compiled and run on.
pub fn engine() -> wasmtime::Result<wasmtime::Engine> {
    static ENGINE: std::sync::OnceLock<wasmtime::Engine> = std::sync::OnceLock::new();
    if let Some(engine) = ENGINE.get() {
        return Ok(engine.clone());
    }
    let mut config = wasmtime::Config::new();
    config.wasm_component_model(true);
    config.wasm_component_model_async(true);
    config.epoch_interruption(true);
    let engine = wasmtime::Engine::new(&config)?;
    if ENGINE.set(engine.clone()).is_ok() {
        let ticker = engine.clone();
        std::thread::Builder::new()
            .name("wa-component-v2-epoch".into())
            .spawn(move || loop {
                std::thread::sleep(Duration::from_millis(100));
                ticker.increment_epoch();
            })?;
    }
    Ok(ENGINE.get().expect("engine initialized").clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The version in the imports is what picks the runner. `wasi:cli/stdout@0.2.0` is a preview-2
    /// import every wasip2 component carries, so only a `wa:kernel` import may decide.
    #[test]
    fn only_a_kernel_v2_import_is_async() {
        assert!(is_kernel_v2("wa:kernel/websocket@0.2.0"));
        assert!(is_kernel_v2("wa:kernel/service@0.2.0"));
        assert!(!is_kernel_v2("wa:kernel/websocket@0.1.0"));
        assert!(!is_kernel_v2("wasi:cli/stdout@0.2.0"));
        assert!(!is_kernel_v2("wasi:cli/stdout@0.2.9"));
        assert!(!is_kernel_v2("wa:kernel"));
    }

    /// End to end with the 0.2 fixture (`svc-echo`, wa:kernel@0.2): the guest awaits a WASI 0.3
    /// timer for its heartbeat, awaits its kv calls, awaits one http exchange against a real local
    /// server (and one refused by the grant), reads a websocket peer over a `stream<list<u8>>` and
    /// awaits the send, then returns cleanly on `lifecycle.stopping()`.
    #[test]
    fn fixture_v2_awaits_streams_and_stops() {
        use crate::services::{logs, start, status, stop, support};
        let _dir = crate::components::TEST_DIR_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        if support::install("v2", &["svc-echo"]).is_none() {
            return;
        }
        let http_port = support::http_echo("pong");
        let ws_port = support::ws_echo();
        let config = serde_json::json!({
            "dial": format!("http://127.0.0.1:{http_port}/note"),
            "refused": "http://127.0.0.2:9/note",
            "ws": format!("ws://127.0.0.1:{ws_port}/ws"),
        });
        // The node grant names the two local ports exactly: `net` entries are matched per address
        // by the dial check, so a wildcard port in the manifest is not a wildcard in a grant.
        let net = [format!("127.0.0.1:{http_port}"), format!("127.0.0.1:{ws_port}")];
        let started = start(&serde_json::json!({"name": "svc-echo", "net": net, "config": config}));
        assert_eq!(started["ok"], true, "{started}");
        let log = support::wait_for_log("svc-echo", "echo ok", Duration::from_secs(15));
        assert!(log.contains("heartbeat start"), "{log}");
        assert!(log.contains("kv ok"), "the kv round trip ran: {log}");
        assert!(log.contains("dial ok status=200 bytes=4"), "the granted http exchange completed: {log}");
        assert!(log.contains("refused -13 (grant)"), "the ungranted address was refused: {log}");
        assert!(log.contains("echo ok 4 bytes"), "the websocket peer's frame arrived over the stream: {log}");
        assert_eq!(status(Some("svc-echo"))["state"], "running");
        assert_eq!(status(Some("svc-echo"))["health"], "ready");
        // A 0.2 guest is parked in a timer between ticks: the runner must still stop it promptly.
        let began = Instant::now();
        let stopped = stop("svc-echo");
        assert_eq!(stopped["was_running"], true);
        assert!(began.elapsed() < STOP_GRACE + Duration::from_secs(3), "stop took {:?}", began.elapsed());
        let log = logs("svc-echo", 16 << 10)["log"].as_str().unwrap_or("").to_string();
        assert!(log.contains("stopping cleanly"), "{log}");
        assert_eq!(status(Some("svc-echo"))["state"], "not_running");
        // Crash mode. `wasi:cli/exit` takes a `result`, not a code, so a component that exits
        // non-zero is reported as exit_1 (the wasip1 fixture, with proc_exit, says exit_3); what
        // matters for the supervisor is the same: a non-zero exit is restarted.
        assert_eq!(start(&serde_json::json!({"name": "svc-echo", "config": {"crash": true}}))["ok"], true);
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut restarts = 0;
        while Instant::now() < deadline {
            let s = status(Some("svc-echo"));
            restarts = s["restarts"].as_u64().unwrap_or(0);
            if restarts >= 1 && s["last_exit"].as_str().unwrap_or("").starts_with("exit_1") {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        let s = status(Some("svc-echo"));
        assert!(restarts >= 1, "{s}");
        assert!(s["last_exit"].as_str().unwrap_or("").starts_with("exit_1"), "{s}");
        stop("svc-echo");
    }

    /// The real 0.2 service component (`wa-whatsapp`, 8 MB, built outside the gate) must compile,
    /// read as 0.2 and instantiate against this runner's linker: instantiation is where every
    /// import name has to line up (the kernel's, `wasi:clocks@0.3.0`'s and the preview-2 WASI ones
    /// `std` brings). Nothing of it runs, so it never dials WhatsApp.
    #[test]
    fn the_whatsapp_component_instantiates_on_the_v2_runner() {
        // Opt-in (the gate does not build this 8 MB component): unset means skip, but a path that
        // does not read is a failure - asking for the test and getting silence would be a pass by
        // absence.
        let Ok(path) = std::env::var("WA_TEST_WHATSAPP_WASM") else { return };
        let bytes = std::fs::read(&path).unwrap_or_else(|error| panic!("cannot read {path}: {error}"));
        let engine = engine().expect("engine");
        let component = Component::new(&engine, &bytes).expect("compiles");
        assert_eq!(Contract::of(&component), Contract::V2);
        let mut linker: Linker<State> = Linker::new(&engine);
        wasmtime_wasi::p2::add_to_linker_async(&mut linker).expect("wasi p2");
        wasmtime_wasi::p3::clocks::add_to_linker::<State>(&mut linker).expect("wasi p3 clocks");
        for added in [
            wa::kernel::websocket::add_to_linker::<State, State>(&mut linker, |s| s),
            wa::kernel::http::add_to_linker::<State, State>(&mut linker, |s| s),
            wa::kernel::speech::add_to_linker::<State, State>(&mut linker, |s| s),
            wa::kernel::kv::add_to_linker::<State, State>(&mut linker, |s| s),
            wa::kernel::lifecycle::add_to_linker::<State, State>(&mut linker, |s| s),
            wa::kernel::log::add_to_linker::<State, State>(&mut linker, |s| s),
            wa::kernel::credentials::add_to_linker::<State, State>(&mut linker, |s| s),
        ] {
            added.expect("kernel interface links");
        }
        let runtime = tokio::runtime::Builder::new_current_thread().enable_time().build().expect("runtime");
        let state = State {
            wasi: WasiCtxBuilder::new().build(),
            table: ResourceTable::new(),
            limits: StoreLimitsBuilder::new().memory_size(256 << 20).build(),
            net: Vec::new(),
            shared: Arc::new(Shared::default()),
            kv: KvStore::new(None),
            log: None,
            secrets: Default::default(),
            stt: false,
            name: "wa-whatsapp".into(),
        };
        let mut store = Store::new(&engine, state);
        // Compiling and instantiating the real component takes minutes in a debug build; the epoch
        // ticker must not interrupt it.
        store.set_epoch_deadline(u64::MAX);
        runtime.block_on(async {
            ServiceComponent::instantiate_async(&mut store, &component, &linker).await.expect("instantiates: every import the component asks for is served");
        });
    }

    /// The mirror of the 0.1 runner's `a_policy_answer_maps_to_the_guest_error`, against this
    /// bindings module's own error type: the table is shared (`service_components::gate_verdict`),
    /// the error it becomes is not. A short rate limit is `again` (the guest already retries that);
    /// anything else is a refusal carrying the reason word the audit record also carries.
    #[test]
    fn a_policy_answer_maps_to_the_v2_guest_error() {
        use wa_grant_policy::Reason;
        assert!(gate_decision(Decision::Allow).is_ok());
        match gate_decision(Decision::Deny(Reason::NoPolicy)) {
            Err(KError::Refused(reason)) => assert_eq!(reason, "no_policy"),
            other => panic!("expected refused(no_policy), got {other:?}"),
        }
        match gate_decision(Decision::NeedsApproval(Reason::ApprovalRequired)) {
            Err(KError::Refused(reason)) => assert_eq!(reason, "approval_required"),
            other => panic!("expected refused(approval_required), got {other:?}"),
        }
        assert!(matches!(
            gate_decision(Decision::RateLimited { retry_after_ms: 400, reason: Reason::TargetRateLimited }),
            Err(KError::Again)
        ));
        match gate_decision(Decision::RateLimited { retry_after_ms: 5_000, reason: Reason::CapabilityRateLimited }) {
            Err(KError::Refused(reason)) => assert_eq!(reason, "capability_rate_limited"),
            other => panic!("expected refused(capability_rate_limited), got {other:?}"),
        }
    }

    /// The 0.2 call sites charge the same capabilities, with the same targets, as the 0.1 ones -
    /// the reason both runners call `service_components::{gate, target_of, authority_target}`.
    /// This drives a real policy engine (not the process-wide one, which another test may have
    /// already loaded), so each pair here is one of the checks the runner above performs.
    #[test]
    fn the_v2_call_sites_charge_what_the_v1_runner_charges() {
        let root = std::env::temp_dir().join(format!("wa-v2-governance-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("audit")).unwrap();
        std::fs::write(
            root.join("policy.json"),
            r#"{"version":1,"components":{"svc-echo":{"capabilities":{
                 "net.dial":{"allow":["echo.example:8080"]},
                 "http.request":{"allow":["echo.example:8080"]},
                 "kv.read":{"allow":["*"]},
                 "kv.write":{"allow":["ses/*"]},
                 "credentials.read":{"allow":["ECHO_TOKEN"]},
                 "stt.start":{"allow":[]},
                 "net.send":{"allow":[]},
                 "whatsapp.send":{"rate":{"per_minute":1,"burst":1}}
               }}}}"#,
        )
        .unwrap();
        let paths = crate::node_policy::Paths {
            policy: root.join("policy.json"),
            state: root.join("state.json"),
            audit: root.join("audit").join("grant-policy.jsonl"),
        };
        let policy = crate::node_policy::NodePolicy::open(paths);
        assert_eq!(policy.mode(), crate::node_policy::Mode::Policy);

        // websocket.connect: the authority the manifest allows, lowercased before the check - the
        // client emitted a host name in mixed case, and the rule is written in lower case.
        let authority = authority_target(&url_authority("wss://ECHO.Example:8080/ws").expect("an authority"));
        assert_eq!(authority, "echo.example:8080");
        assert!(gate_decision(policy.check_at("svc-echo", "net.dial", Some(&authority), 1_000)).is_ok());
        assert!(gate_decision(policy.check_at("svc-echo", "net.dial", Some("127.0.0.1:9"), 1_000)).is_err());

        // http.send: the same target, the same refusal word.
        assert!(gate_decision(policy.check_at("svc-echo", "http.request", Some(&authority), 1_000)).is_ok());
        match gate_decision(policy.check_at("svc-echo", "http.request", Some("evil.example:443"), 1_000)) {
            Err(KError::Refused(reason)) => assert_eq!(reason, "target_not_allowed"),
            other => panic!("expected a refusal, got {other:?}"),
        }

        // kv: a read of any key is allowed, a write only under its prefix; the key is the target.
        let key = target_of(b"ses/abc");
        assert!(gate_decision(policy.check_at("svc-echo", "kv.read", Some(&key), 1_000)).is_ok());
        assert!(gate_decision(policy.check_at("svc-echo", "kv.write", Some(&key), 1_000)).is_ok());
        match gate_decision(policy.check_at("svc-echo", "kv.write", Some("pk/other"), 1_000)) {
            Err(KError::Refused(reason)) => assert_eq!(reason, "target_not_allowed"),
            other => panic!("expected a refusal, got {other:?}"),
        }

        // credentials.read names the secret, and stt.start has no target to name.
        assert!(gate_decision(policy.check_at("svc-echo", "credentials.read", Some("ECHO_TOKEN"), 1_000)).is_ok());
        assert!(gate_decision(policy.check_at("svc-echo", "credentials.read", Some("OTHER"), 1_000)).is_err());
        assert!(gate_decision(policy.check_at("svc-echo", "stt.start", None, 1_000)).is_ok());

        // websocket.send is opaque: `net.send` first, then the capability-wide message budget for a
        // rule that names no chat (`node_policy::check_opaque_send`, the 0.1 send path).
        assert!(gate_decision(policy.check_opaque_send_at("svc-echo", &authority, 1_000)).is_ok());
        match gate_decision(policy.check_opaque_send_at("svc-echo", &authority, 1_000)) {
            Err(KError::Refused(_)) => {}
            other => panic!("the message budget must run out, got {other:?}"),
        }
        // A capability the policy file has no rule for is the case that matters after a deploy: the
        // 0.2 runner asks the same question and gets the same `no_policy`.
        match gate_decision(policy.check_at("svc-echo", "exec.run", None, 1_000)) {
            Err(KError::Refused(reason)) => assert_eq!(reason, "no_policy"),
            other => panic!("expected no_policy, got {other:?}"),
        }
        // An unlisted component is not silently allowed either.
        match gate_decision(policy.check_at("unlisted", "net.dial", Some(&authority), 1_000)) {
            Err(KError::Refused(reason)) => assert_eq!(reason, "no_policy"),
            other => panic!("expected no_policy, got {other:?}"),
        }
        std::fs::remove_dir_all(root).ok();
    }

    /// The async engine is a real engine: it compiles a component and refuses a non-component.
    #[test]
    fn the_async_engine_compiles_a_component() {
        let engine = engine().expect("engine");
        assert!(engine.precompile_component(b"\0asm\x0d\0\x01\0not a component").is_err());
    }
}
