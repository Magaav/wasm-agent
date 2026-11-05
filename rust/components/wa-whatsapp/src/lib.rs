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

mod alerts;
mod posting;
mod queue;
mod store;

wit_bindgen::generate!({
    world: "service-component",
    path: "../../../wit/kernel",
});

use wa::kernel::types::Error as KError;
use wa::kernel::{http as khttp, kv as kkv, lifecycle, speech, websocket::Socket};


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
    /// The connected client, for media downloads from the audio pipeline.
    static CLIENT: RefCell<Option<Arc<whatsapp_rust::Client>>> = const { RefCell::new(None) };
    /// Audio messages handed over by the (Send) message handler, admitted by the main loop.
    static AUDIO_INBOX: RefCell<Vec<AudioJob>> = const { RefCell::new(Vec::new()) };
    /// Message IDs named by revokes/edits, handed over by the message handler.
    static INBOX_FENCES: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
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

// ---- transcription pipeline ------------------------------------------------------------------
// A voice note: queue (queue.rs: freshness, retry, one at a time) -> media download (host HTTP) ->
// kernel recognizer (wa:kernel/speech, segments streamed) -> posting policy (posting.rs: allowlist,
// holds, chunks, post-then-edit) -> own-chat alerts for anything given up (alerts.rs).
// Logged with metadata only - never the text. Posting is off unless the configuration says
// `post_transcripts: true` AND the chat is in `post_allow` (the native connector is the poster
// meanwhile; the B2 deployment allows only the own chat).

use whatsapp_rust::waproto::whatsapp as wa;
use wacore::proto_helpers::{MessageBuilderExt, MessageExt};

struct AudioJob {
    chat: whatsapp_rust::Jid,
    sender: whatsapp_rust::Jid,
    id: String,
    title: String,
    sent_ms: i64,
    received_ms: i64,
    /// The whole received message, quoted by the transcript (the audio bubble above the reply).
    message: Arc<wa::Message>,
    audio: wa::message::AudioMessage,
}

enum Outcome {
    Done,
    Retry(String),
    Permanent(String),
}

thread_local! {
    static QUEUE: RefCell<queue::AudioQueue<AudioJob>> = RefCell::new(queue::AudioQueue::new(queue::Policy::default()));
    static COMPLETIONS: RefCell<Vec<(queue::Item<AudioJob>, Outcome)>> = const { RefCell::new(Vec::new()) };
    static ALERTS: RefCell<alerts::AlertBook> = RefCell::new(alerts::AlertBook::default());
    static ALERT_SENDING: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// Message IDs a revoke/edit named (exact per-message fences); also kept in kv `fence/<id>`.
    static FENCES: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn tx_key(chat: &str, id: &str) -> String {
    format!("tx/{chat}/{id}")
}

fn record(chat: &str, id: &str, value: serde_json::Value) {
    let _ = kkv::set(tx_key(chat, id).as_bytes(), value.to_string().as_bytes());
}

fn already_handled(chat: &str, id: &str) -> bool {
    matches!(kkv::get(tx_key(chat, id).as_bytes()), Ok(Some(_)))
}

fn fence(id: &str) {
    FENCES.with(|f| {
        let mut f = f.borrow_mut();
        if !f.iter().any(|x| x == id) {
            f.push(id.to_string());
        }
    });
    let _ = kkv::set(format!("fence/{id}").as_bytes(), b"1");
}

fn fenced(id: &str) -> bool {
    FENCES.with(|f| f.borrow().iter().any(|x| x == id)) || matches!(kkv::get(format!("fence/{id}").as_bytes()), Ok(Some(_)))
}

/// Queue an own-chat alert for a live voice note that ends without a posted transcript.
fn alert(chat: &str, title: &str, kind: &str, reason: &str, sent_ms: i64) {
    ALERTS.with(|a| {
        a.borrow_mut().push(alerts::Alert { chat: chat.into(), title: title.into(), kind: kind.into(), reason: reason.into(), sent_ms, at_ms: now_ms() })
    });
}

fn own_users() -> Vec<String> {
    CLIENT.with(|c| c.borrow().clone()).map(|client| [client.pn(), client.lid()].into_iter().flatten().map(|j| j.user.to_string()).collect()).unwrap_or_default()
}

fn permanent(reason: &str) -> bool {
    ["no_speech_detected", "audio_too_large", "transcript_too_long", "cross_language_translation_unsupported", "language_must_be_en_pt_auto"].iter().any(|p| reason.contains(p))
}

fn reason_of(error: &KError) -> String {
    match error {
        KError::Failed(r) | KError::Refused(r) => r.clone(),
        other => format!("{other:?}"),
    }
}

/// Hand a received voice note to the queue (or settle it at once when it cannot be transcribed).
fn admit(job: AudioJob) {
    let chat = job.chat.to_string();
    if already_handled(&chat, &job.id) {
        return; // never transcribe or post the same voice note twice (re-delivery, restart)
    }
    let now = now_ms();
    let unsupported = if job.sent_ms <= 0 {
        Some("timestamp_unknown")
    } else if job.sent_ms > now + 300_000 {
        Some("future_timestamp_untrusted")
    } else if job.message.is_view_once() {
        Some("view_once")
    } else if job.audio.file_length.unwrap_or(0) > 20 << 20 {
        Some("audio_too_large")
    } else {
        None
    };
    let live = job.sent_ms >= now - QUEUE.with(|q| q.borrow().policy().fresh_ms);
    if let Some(reason) = unsupported {
        say!("transcript unsupported chat={chat} id={} reason={reason}", job.id);
        record(&chat, &job.id, serde_json::json!({"state": "unsupported", "reason": reason}));
        if live && job.sent_ms > 0 {
            alert(&chat, &job.title, "unsupported", reason, job.sent_ms);
        }
        return;
    }
    if fenced(&job.id) {
        say!("transcript blocked chat={chat} id={} reason=source_fence", job.id);
        record(&chat, &job.id, serde_json::json!({"state": "blocked", "reason": "source_fence"}));
        if live {
            alert(&chat, &job.title, "blocked", "source_fence", job.sent_ms);
        }
        return;
    }
    let key = format!("{chat}\u{0}{}", job.id);
    let sent = job.sent_ms;
    QUEUE.with(|q| q.borrow_mut().enqueue(key, sent, job));
}

struct Posted {
    first_id: Option<String>,
    first_ms: Option<i64>,
    edits: u32,
    edit_errors: u32,
}

async fn send(client: &whatsapp_rust::Client, chat: &whatsapp_rust::Jid, body: String, context: &wa::ContextInfo) -> Result<String, String> {
    client.send_message(chat.clone(), wa::Message::text_with_context(body, context.clone())).await.map(|r| r.message_id).map_err(|e| e.to_string())
}

async fn edit(client: &whatsapp_rust::Client, chat: &whatsapp_rust::Jid, id: &str, body: String, context: &wa::ContextInfo) -> Result<(), String> {
    client.edit_message(chat.clone(), id.to_string(), wa::Message::text_with_context(body, context.clone())).await.map(|_| ()).map_err(|e| e.to_string())
}

/// One voice note, start to finish. Returns how it ended; the main loop tells the queue.
async fn process(job: &AudioJob, language: &str, cfg: &posting::PostConfig) -> Outcome {
    let chat = job.chat.to_string();
    let Some(client) = CLIENT.with(|c| c.borrow().clone()) else {
        return Outcome::Retry("not_connected".into());
    };
    let picked = now_ms();
    let bytes = match client.download(&job.audio).await {
        Ok(bytes) => bytes,
        Err(error) => {
            say!("transcript download failed chat={chat} id={} reason={error}", job.id);
            return Outcome::Retry("download".into());
        }
    };
    let downloaded = now_ms();
    let mime = job.audio.mimetype.clone().unwrap_or_else(|| "audio/ogg".into());
    let recognizer = match speech::Job::start(&bytes, &mime, language) {
        Ok(started) => started,
        Err(error) => {
            let reason = reason_of(&error);
            return if permanent(&reason) { Outcome::Permanent(reason) } else { Outcome::Retry(format!("stt_start:{reason}")) };
        }
    };
    let seconds = job.audio.seconds.unwrap_or(0);
    let own = own_users();
    let may_post = cfg.allowed(&chat, &own) && !cfg.held(&chat);
    let streaming = may_post && cfg.streams(seconds);
    let context = wacore::proto_helpers::build_quote_context_with_info(&job.id, &job.sender, &job.chat, &job.chat, &job.message);
    let mut posted = Posted { first_id: None, first_ms: None, edits: 0, edit_errors: 0 };
    let mut pacer = posting::EditPacer::new(cfg.edit_interval_ms);
    let mut so_far = String::new();
    let mut seen = 0u32;
    let result = loop {
        match recognizer.poll() {
            Err(KError::Again) => {}
            other => break other,
        }
        if streaming {
            let fresh = recognizer.segments(seen);
            if !fresh.is_empty() {
                seen += fresh.len() as u32;
                for segment in fresh {
                    if !so_far.is_empty() {
                        so_far.push(' ');
                    }
                    so_far.push_str(segment.trim());
                }
                let now = now_ms();
                if pacer.ready(now) && !fenced(&job.id) {
                    match &posted.first_id {
                        None => match send(&client, &job.chat, posting::partial(&so_far), &context).await {
                            Ok(id) => {
                                posted.first_id = Some(id);
                                posted.first_ms = Some(now_ms());
                                pacer.mark(now, false);
                            }
                            Err(error) => say!("transcript partial post failed chat={chat} id={} reason={error}", job.id),
                        },
                        Some(first) => {
                            match edit(&client, &job.chat, first, posting::partial(&so_far), &context).await {
                                Ok(()) => posted.edits += 1,
                                Err(error) => {
                                    posted.edit_errors += 1;
                                    say!("transcript edit failed chat={chat} id={} edit={} reason={error}", job.id, posted.edits + 1);
                                }
                            }
                            pacer.mark(now, false);
                        }
                    }
                }
            }
        }
        Sleep(Instant::now() + Duration::from_millis(250)).await;
    };
    let transcript = match result {
        Ok(t) => t,
        Err(error) => {
            let reason = reason_of(&error);
            say!("transcript failed chat={chat} id={} reason={reason}", job.id);
            return if permanent(&reason) { Outcome::Permanent(reason) } else { Outcome::Retry(reason) };
        }
    };
    let ready = now_ms();
    let chars = transcript.text.chars().count();
    say!(
        "transcript ready chat={chat} id={} ms={} chars={chars} latency_ms={} download_ms={} wait_ms={} seconds={seconds} segments={seen}",
        job.id,
        transcript.elapsed_ms,
        ready - job.sent_ms,
        downloaded - picked,
        picked - job.received_ms
    );
    let base = serde_json::json!({"state": "transcribed", "text": transcript.text, "elapsed_ms": transcript.elapsed_ms, "latency_ms": ready - job.sent_ms});
    if !cfg.allowed(&chat, &own) {
        let mut v = base;
        v["posted"] = false.into();
        v["reason"] = "shadow".into();
        record(&chat, &job.id, v);
        return Outcome::Done;
    }
    if cfg.held(&chat) {
        let mut v = base;
        v["posted"] = false.into();
        v["reason"] = "posting_held_chat".into();
        record(&chat, &job.id, v);
        alert(&chat, &job.title, "post_held", "posting_held_chat", job.sent_ms);
        return Outcome::Done;
    }
    if fenced(&job.id) {
        let mut v = base;
        v["posted"] = false.into();
        v["reason"] = "source_fence_during_decode".into();
        record(&chat, &job.id, v);
        say!("transcript not posted chat={chat} id={} reason=source_fence_during_decode", job.id);
        return Outcome::Done;
    }
    // Never post an old transcript: a ready result that could not go out within the window expires.
    if now_ms() - ready > QUEUE.with(|q| q.borrow().policy().fresh_ms) {
        record(&chat, &job.id, serde_json::json!({"state": "expired", "reason": "post_expired"}));
        alert(&chat, &job.title, "post_expired", "post_stale_over_5m", job.sent_ms);
        return Outcome::Done;
    }
    let parts = posting::chunks(&transcript.text);
    let mut ids = Vec::new();
    let mut failure = None;
    for (i, part) in parts.iter().enumerate() {
        let outcome = match (i, &posted.first_id) {
            (0, Some(first)) => edit(&client, &job.chat, first, part.clone(), &context).await.map(|_| {
                posted.edits += 1;
                first.clone()
            }),
            _ => send(&client, &job.chat, part.clone(), &context).await,
        };
        match outcome {
            Ok(id) => {
                if posted.first_ms.is_none() {
                    posted.first_ms = Some(now_ms());
                }
                ids.push(id)
            }
            Err(error) => {
                // Unknown sends never auto-retry (a duplicate in a real chat is worse than a gap).
                failure = Some(error);
                break;
            }
        }
    }
    let done = now_ms();
    let first_ms = posted.first_ms.unwrap_or(done);
    say!(
        "transcript posted chat={chat} id={} parts={}/{} edits={} edit_errors={} first_text_ms={} total_ms={} streamed={streaming}",
        job.id,
        ids.len(),
        parts.len(),
        posted.edits,
        posted.edit_errors,
        first_ms - job.received_ms,
        done - job.received_ms
    );
    let mut v = base;
    v["posted"] = (failure.is_none()).into();
    v["message_ids"] = serde_json::json!(ids);
    v["edits"] = posted.edits.into();
    v["first_text_ms"] = (first_ms - job.received_ms).into();
    v["total_ms"] = (done - job.received_ms).into();
    if let Some(error) = &failure {
        v["reason"] = format!("send:{}", error.chars().take(120).collect::<String>()).into();
        alert(&chat, &job.title, "failed", "send", job.sent_ms);
    }
    record(&chat, &job.id, v);
    Outcome::Done
}

/// Run the next queued voice note, if the recognizer is free.
fn dispatch(spawner: &LocalSpawner, language: &str, cfg: &posting::PostConfig) {
    let now = now_ms();
    for notice in QUEUE.with(|q| q.borrow_mut().expire_stale(now)) {
        settle_notice(&notice, None);
    }
    let Some(item) = QUEUE.with(|q| q.borrow_mut().take(now)) else { return };
    let language = language.to_string();
    let cfg = cfg.clone();
    let _ = spawner.spawn_local(async move {
        let outcome = process(&item.payload, &language, &cfg).await;
        COMPLETIONS.with(|c| c.borrow_mut().push((item, outcome)));
    });
}

fn settle_notice(notice: &queue::Notice, title: Option<&str>) {
    let (chat, id) = notice.key.split_once('\u{0}').unwrap_or((notice.key.as_str(), ""));
    let kind = if notice.kind == "failed" && permanent(&notice.reason) { "unsupported" } else { notice.kind };
    say!("transcript {} chat={chat} id={id} reason={}", if kind == "audio_expired" { "expired" } else { kind }, notice.reason);
    record(chat, id, serde_json::json!({"state": kind, "reason": notice.reason}));
    alert(chat, title.unwrap_or(""), kind, &notice.reason, notice.sent_ms);
}

fn settle_completions() {
    let now = now_ms();
    for (item, outcome) in COMPLETIONS.with(|c| std::mem::take(&mut *c.borrow_mut())) {
        let title = item.payload.title.clone();
        let notice = QUEUE.with(|q| {
            let mut q = q.borrow_mut();
            match outcome {
                Outcome::Done => {
                    q.done(&item.key);
                    None
                }
                Outcome::Retry(reason) => q.fail(item, now, &reason, true),
                Outcome::Permanent(reason) => q.fail(item, now, &reason, false),
            }
        });
        if let Some(notice) = notice {
            settle_notice(&notice, Some(&title));
        }
    }
}

/// Send the batched own-chat log when one is due (never into a source chat).
fn send_alerts(spawner: &LocalSpawner, enabled: bool) {
    if !enabled || ALERT_SENDING.with(|s| s.get()) {
        return;
    }
    let Some(client) = CLIENT.with(|c| c.borrow().clone()) else { return };
    let Some(own) = client.pn().map(|j| j.to_non_ad()) else { return };
    let now = now_ms();
    let Some(text) = ALERTS.with(|a| a.borrow_mut().due(now)) else { return };
    ALERT_SENDING.with(|s| s.set(true));
    let _ = spawner.spawn_local(async move {
        match client.send_message(own, wa::Message::text(text)).await {
            Ok(_) => {
                ALERTS.with(|a| a.borrow_mut().sent(now_ms()));
                say!("alerts sent (own chat)");
            }
            Err(error) => say!("alerts send failed reason={error}"),
        }
        ALERT_SENDING.with(|s| s.set(false));
    });
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
    let language = config["language"].as_str().unwrap_or("pt").to_string();
    let post = posting::PostConfig::from_json(&config);
    if let Some(seconds) = config["fresh_seconds"].as_i64() {
        let policy = queue::Policy { fresh_ms: seconds.clamp(60, 86_400) * 1000, ..queue::Policy::default() };
        QUEUE.with(|q| *q.borrow_mut() = queue::AudioQueue::new(policy));
    }
    say!(
        "transcription: language {language}, posting {} (allow {:?}), alerts {}, stream_edits {} (min {} s, edit every {} s), held chats {}",
        if post.post { "on" } else { "off" },
        post.allow,
        if post.alerts { "on" } else { "off" },
        post.stream_edits,
        post.stream_min_seconds,
        post.edit_interval_ms / 1000,
        post.held.len()
    );
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
            .on_connected(|client| {
                CLIENT.with(|c| *c.borrow_mut() = Some(client));
                async move {
                    say!("CONNECTED");
                    lifecycle::report(lifecycle::Health::Ready, None);
                }
            })
            .on_logged_out(|_client| async move { say!("LOGGED OUT") })
            .on_message(|ctx| {
                let line = format!("message chat={} kind={} media={} id={}", ctx.info.source.chat, ctx.info.r#type, ctx.info.media_type, ctx.info.id);
                let base = ctx.message.get_base_message();
                // Exact per-message fences: a revoke or edit names the message ID it changes.
                if let Some(pm) = base.protocol_message.as_option() {
                    let kind = pm.r#type;
                    if kind == Some(wa::message::protocol_message::Type::REVOKE) || kind == Some(wa::message::protocol_message::Type::MESSAGE_EDIT) {
                        if let Some(id) = pm.key.as_option().and_then(|k| k.id.clone()) {
                            INBOX_FENCES.with(|f| f.borrow_mut().push(id));
                        }
                    }
                }
                let chat_str = ctx.info.source.chat.to_string();
                let skip = chat_str == "status@broadcast" || chat_str.ends_with("@newsletter");
                if let (Some(audio), false) = (base.audio_message.as_option(), skip) {
                    AUDIO_INBOX.with(|q| {
                        q.borrow_mut().push(AudioJob {
                            chat: ctx.info.source.chat.clone(),
                            sender: ctx.info.source.sender.clone(),
                            id: ctx.info.id.to_string(),
                            title: if ctx.info.source.is_group { String::new() } else { ctx.info.push_name.to_string() },
                            sent_ms: ctx.info.timestamp.timestamp_millis(),
                            received_ms: now_ms(),
                            message: ctx.message.clone(),
                            audio: audio.clone(),
                        })
                    });
                }
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
    let mut last_tick = Instant::now();
    loop {
        for id in INBOX_FENCES.with(|f| std::mem::take(&mut *f.borrow_mut())) {
            say!("fence id={id}");
            fence(&id);
        }
        for job in AUDIO_INBOX.with(|q| std::mem::take(&mut *q.borrow_mut())) {
            admit(job);
        }
        settle_completions();
        if last_tick.elapsed() >= Duration::from_millis(200) {
            last_tick = Instant::now();
            dispatch(&spawner, &language, &post);
            send_alerts(&spawner, post.alerts);
        }
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
