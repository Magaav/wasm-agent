//! WhatsApp linked-device client as a service component on `wa:kernel@0.2`.
//!
//! whatsapp-rust's protocol core, with everything that touches the outside world supplied by the
//! host: the websocket (`wa:kernel/websocket`, TLS in the host), HTTP (`wa:kernel/http`), the
//! recognizer (`wa:kernel/speech`), the store (`wa:kernel/kv`), the clock (WASI 0.3
//! `monotonic-clock.wait-for`) and stop (`wa:kernel/lifecycle`).
//!
//! Native async: there is no reactor and no polling loop over host I/O. The inbound frames are a
//! `stream<list<u8>>` the socket task awaits, an exchange is one `http.send`, the recognizer yields
//! a segment stream plus one transcript future, and a timer is an awaited `wait-for`. The one
//! executor left is the set the protocol crate insists on (`Runtime::spawn` returns an
//! `AbortHandle`), and it is a plain `FuturesUnordered` joined with the main loop.
//!
//! Milestone 1: pair (by code when `pair_phone` is configured, else QR), connect, receive. The log
//! carries the pairing code, connection state and message metadata (chat, kind, id) - never content.
//! Store: store.rs - in-memory reads with write-through of durable state to the host (wa_kernel/kv);
//! a restart reconnects without pairing again.
//!
//! The crate is split so the decisions can be tested on the host: `queue` (freshness, retry, the
//! express lane), `posting` (allowlist gate, holds, chunks, edit pacing), `alerts` (own-chat log,
//! group titles) and `holds` (chats held until a revoke is proven) are pure logic with no host call
//! and no wasm target requirement; everything else (`guest`, `store`) needs the wasm32-wasip2
//! bindings and is compiled only for that target, so `cargo test` runs the decisions natively while
//! `cargo build --target wasm32-wasip2` builds the component.
use crate::holds::{Author, Holds, Mutation, POSTING_ONLY};
use crate::wa::kernel::types::Error as KError;
use crate::wa::kernel::{http as khttp, kv as kkv, lifecycle, speech, websocket};
use crate::wasi::clocks::monotonic_clock;
use crate::{alerts, export, exports, posting, queue, store};
use async_trait::async_trait;
use bytes::Bytes;
use futures::stream::{FuturesUnordered, Stream, StreamExt};
use std::cell::RefCell;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};
use wacore::net::{DisconnectReason, HttpClient, HttpRequest, HttpResponse, Transport, TransportEvent, TransportFactory, WHATSAPP_WEB_ORIGIN, WHATSAPP_WEB_WS_URL};
use wacore::runtime::{AbortHandle, Runtime};

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

// ---- the tasks: what the protocol crate spawns, polled by the runtime ------------------------

type Task = Pin<Box<dyn Future<Output = ()>>>;

thread_local! {
    /// Where a spawned task goes. Set once `serve` starts the driver; a spawn before that (there is
    /// none) is dropped rather than run on another thread.
    static TASKS: RefCell<Option<futures::channel::mpsc::UnboundedSender<Task>>> = const { RefCell::new(None) };
}

fn spawn_task(task: Task) {
    TASKS.with(|cell| {
        if let Some(inbox) = cell.borrow().as_ref() {
            if inbox.unbounded_send(task).is_err() {
                say!("task dropped: the driver is gone");
            }
        }
    });
}

/// The driver: every task the protocol crate spawned, plus everything the pipeline spawns. This is
/// the whole of the guest's scheduling - there is no timer list and no I/O wake list any more,
/// because a task that waits is parked by the runtime.
struct Tasks {
    inbox: futures::channel::mpsc::UnboundedReceiver<Task>,
    running: FuturesUnordered<Task>,
}

impl Tasks {
    fn start() -> Tasks {
        let (inbox_tx, inbox) = futures::channel::mpsc::unbounded();
        TASKS.with(|cell| *cell.borrow_mut() = Some(inbox_tx));
        Tasks { inbox, running: FuturesUnordered::new() }
    }
}

impl Future for Tasks {
    type Output = ();

    fn poll(self: Pin<&mut Self>, cx: &mut std::task::Context<'_>) -> std::task::Poll<()> {
        let me = self.get_mut();
        loop {
            let mut took = false;
            while let std::task::Poll::Ready(Some(task)) = Pin::new(&mut me.inbox).poll_next(cx) {
                me.running.push(task);
                took = true;
            }
            match me.running.poll_next_unpin(cx) {
                std::task::Poll::Ready(Some(())) => continue,
                std::task::Poll::Ready(None) => {
                    // Nothing running: the inbox registered its waker above, so a new task wakes us.
                    let _ = took;
                    return std::task::Poll::Pending;
                }
                std::task::Poll::Pending => return std::task::Poll::Pending,
            }
        }
    }
}

/// `wasi:clocks/monotonic-clock@0.3.0.wait-for`: the timer the runtime suspends the task on. This
/// replaces the 0.1 guest's timer list, its waker bookkeeping and its 5 ms nap.
async fn wait(for_: Duration) {
    monotonic_clock::wait_for(for_.as_nanos() as u64).await;
}

// ---- transcription pipeline ------------------------------------------------------------------
// A voice note: queue (queue.rs: freshness, retry, one at a time) -> media download (host HTTP) ->
// kernel recognizer (wa:kernel/speech: a segment stream and one transcript future) -> posting
// policy (posting.rs: allowlist, holds, chunks, post-then-edit) -> own-chat alerts for anything
// given up (alerts.rs). Logged with metadata only - never the text. Posting is off unless the
// configuration says `post_transcripts: true` AND the chat is in `post_allow`.

use whatsapp_rust::waproto::buffa::Message as _;
use whatsapp_rust::waproto::whatsapp as wap;
use wacore::proto_helpers::{MessageBuilderExt, MessageExt};
use whatsapp_rust::wacore_binary::jid::JidExt;

struct AudioJob {
    chat: whatsapp_rust::Jid,
    sender: whatsapp_rust::Jid,
    /// The sender's other address (PN<->LID), when the envelope carried it; author proof uses it.
    sender_alt: String,
    id: String,
    title: String,
    /// The message is our own (echo of our own voice note): its revoke needs no author proof.
    own: bool,
    sent_ms: i64,
    received_ms: i64,
    /// The whole received message, quoted by the transcript (the audio bubble above the reply).
    message: Arc<wap::Message>,
    audio: wap::message::AudioMessage,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok()).collect()
}

/// The queue payload as it survives a restart: the message as protobuf bytes (it is what the
/// download and the quote need), and the metadata the pipeline logs. A record that does not read
/// back is dropped by the queue, never guessed.
impl queue::Persist for AudioJob {
    fn save(&self) -> serde_json::Value {
        serde_json::json!({
            "chat": self.chat.to_string(),
            "sender": self.sender.to_string(),
            "sender_alt": self.sender_alt,
            "id": self.id,
            "title": self.title,
            "own": self.own,
            "sent_ms": self.sent_ms,
            "received_ms": self.received_ms,
            "message": hex(&self.message.encode_to_vec()),
        })
    }

    fn load(v: &serde_json::Value) -> Option<Self> {
        let chat: whatsapp_rust::Jid = v["chat"].as_str()?.parse().ok()?;
        let sender: whatsapp_rust::Jid = v["sender"].as_str().and_then(|s| s.parse().ok()).unwrap_or_else(|| chat.clone());
        let message = wap::Message::decode_from_slice(&unhex(v["message"].as_str()?)?).ok()?;
        let audio = message.audio_message.as_option()?.clone();
        Some(AudioJob {
            chat,
            sender,
            sender_alt: v["sender_alt"].as_str().unwrap_or("").to_string(),
            id: v["id"].as_str()?.to_string(),
            title: v["title"].as_str().unwrap_or("").to_string(),
            own: v["own"].as_bool().unwrap_or(false),
            sent_ms: v["sent_ms"].as_i64().unwrap_or(0),
            received_ms: v["received_ms"].as_i64().unwrap_or(0),
            message: Arc::new(message),
            audio,
        })
    }
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
    /// Chat holds and message fences derived from revokes/edits (holds.rs); persisted in kv.
    static HOLDS: RefCell<Holds> = RefCell::new(Holds::new());
    /// The queue or the holds changed: write them to kv on the next tick.
    static STATE_DIRTY: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// Revoke/edit envelopes, handed over by the message handler.
    static INBOX_MUTATIONS: RefCell<Vec<Mutation>> = const { RefCell::new(Vec::new()) };
    /// The connected client, for media downloads from the audio pipeline.
    static CLIENT: RefCell<Option<Arc<whatsapp_rust::Client>>> = const { RefCell::new(None) };
    /// Audio messages handed over by the (Send) message handler, admitted by the main loop.
    static AUDIO_INBOX: RefCell<Vec<AudioJob>> = const { RefCell::new(Vec::new()) };
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn tx_key(chat: &str, id: &str) -> String {
    format!("tx/{chat}/{id}")
}

async fn record(chat: &str, id: &str, value: serde_json::Value) {
    let _ = kkv::set(tx_key(chat, id).into_bytes(), value.to_string().into_bytes()).await;
}

async fn already_handled(chat: &str, id: &str) -> bool {
    matches!(kkv::get(tx_key(chat, id).into_bytes()).await, Ok(Some(_)))
}

async fn fence(id: &str) {
    // Kept for the targets an older build fenced directly: this build fences through holds.rs,
    // but a fence already on disk must never be forgotten.
    let _ = kkv::set(format!("fence/{id}").into_bytes(), b"1".to_vec()).await;
}

/// Fenced: a proven revoke/edit of this message here, an unproven target anywhere (a DM alias may
/// differ from the chat), or a fence written by an earlier build.
async fn fenced(chat: &str, id: &str) -> bool {
    if HOLDS.with(|h| h.borrow().blocked(chat, id)) {
        return true;
    }
    matches!(kkv::get(format!("fence/{id}").into_bytes()).await, Ok(Some(_)))
}

/// Is this the same chat? A mutation key may carry a device part or the other address of the same
/// user (`7210:12@lid` vs `7210@lid`): the comparison is on the user and server only.
fn same_chat(a: &str, b: &str) -> bool {
    let bare = |jid: &str| {
        let (user, server) = jid.split_once('@').unwrap_or((jid, ""));
        format!("{}@{server}", user.split(':').next().unwrap_or(user))
    };
    bare(a) == bare(b)
}

/// What a recorded author row says (kv `tx/<chat>/<id>`): the only thing that can prove a revoke is
/// about that message by the same person.
fn author_of(bytes: &[u8]) -> Option<Author> {
    let value: serde_json::Value = serde_json::from_slice(bytes).ok()?;
    let sender = value["sender"].as_str().filter(|s| !s.is_empty())?;
    let alt = value["sender_alt"].as_str().unwrap_or("");
    Some(Author::new(sender, alt, value["own"] == serde_json::json!(true)))
}

async fn known_author(chat: &str, id: &str) -> Option<Author> {
    let bytes = kkv::get(tx_key(chat, id).into_bytes()).await.ok().flatten()?;
    author_of(&bytes)
}

/// Apply one revoke/edit: fence the exact message, hold the chat, or hold nothing (holds.rs decides).
async fn apply_mutation(mutation: Mutation) {
    let chat = mutation.chat.clone();
    let key = if mutation.target.is_empty() { None } else { Some(format!("{chat}\u{0}{}", mutation.target)) };
    let known = known_author(&chat, &mutation.target).await;
    let verdict = HOLDS.with(|h| h.borrow_mut().apply(&mutation, known.as_ref()));
    STATE_DIRTY.with(|d| d.set(true));
    say!(
        "mutation chat={chat} kind={} verified={} proof={} fence_here={} fence_anywhere={} hold={}",
        mutation.kind,
        verdict.verified,
        verdict.proof,
        verdict.fence_here.len(),
        verdict.fence_everywhere.len(),
        verdict.hold.unwrap_or("none")
    );
    for id in &verdict.fence_everywhere {
        fence(id).await;
    }
    // A proven revoke/edit is a source we must not even transcribe: drop it if it is still queued
    // (an item already decoding finishes and is caught by the fence before it posts).
    if let (true, Some(key)) = (!verdict.fence_here.is_empty(), key) {
        if QUEUE.with(|q| q.borrow_mut().drop_key(&key)) {
            record(&chat, &mutation.target, serde_json::json!({"state": "blocked", "reason": "source_fence"})).await;
        }
    }
    // The common unproven case (a DM revoked under its other alias) is provable as soon as the
    // target's author is on record: try at once instead of leaving the chat held until a restart.
    if verdict.hold == Some(POSTING_ONLY) {
        reprove(chat.as_str()).await;
    }
}

/// Re-prove the posting-only hold of one chat from what the component recorded (hold_reprove.go).
/// The author rows are read in one scan of the chat's keys, so the proof itself stays the pure
/// function holds.rs tests.
async fn reprove(chat: &str) {
    let prefix = format!("tx/{chat}/");
    let mut known: std::collections::HashMap<String, Author> = std::collections::HashMap::new();
    let mut cursor: Option<Vec<u8>> = None;
    loop {
        let Ok(page) = kkv::scan(prefix.clone().into_bytes(), cursor.clone(), 500).await else { break };
        if page.is_empty() {
            break;
        }
        cursor = page.last().map(|entry| entry.key.clone());
        for entry in page {
            let key = String::from_utf8_lossy(&entry.key).into_owned();
            if let Some(id) = key.strip_prefix(&prefix) {
                if let Some(author) = author_of(&entry.value) {
                    known.insert(id.to_string(), author);
                }
            }
        }
    }
    let report = HOLDS.with(|h| h.borrow_mut().reprove(chat, |id| known.get(id).cloned()));
    if report.reproved > 0 {
        say!("hold reproved chat={chat} fenced={}", report.fenced);
        STATE_DIRTY.with(|d| d.set(true));
    } else if let Some(skipped) = report.skipped {
        say!("hold kept chat={chat} reason={skipped}");
    }
}

/// Re-prove every posting-only hold at start: a hold left by the last run may be provable now.
async fn reprove_holds() {
    for (chat, reason) in HOLDS.with(|h| h.borrow().held_reasons()) {
        if reason == POSTING_ONLY {
            reprove(&chat).await;
        }
    }
}

fn compute_held(chat: &str) -> bool {
    HOLDS.with(|h| h.borrow().compute_held(chat))
}

/// Write the queue and the holds to kv (one key each). Called when they changed, never per tick
/// with nothing to say.
async fn persist_state() {
    if !STATE_DIRTY.with(|d| d.replace(false)) {
        return;
    }
    let now = now_ms();
    let queue = QUEUE.with(|q| q.borrow().snapshot(now));
    if let Ok(text) = serde_json::to_vec(&queue) {
        let _ = kkv::set(b"queue".to_vec(), text).await;
    }
    let holds = HOLDS.with(|h| h.borrow().to_json());
    let _ = kkv::set(b"holds".to_vec(), holds.into_bytes()).await;
}

/// Read what the last run left in kv: the held chats and fences, and the queue. Items that were in
/// flight when the component stopped are reported, never re-posted (an unknown send is not retried).
async fn restore_state() {
    if let Ok(Some(bytes)) = kkv::get(b"holds".to_vec()).await {
        let text = String::from_utf8_lossy(&bytes).into_owned();
        let restored = Holds::from_json(&text);
        let held = restored.held_chats();
        HOLDS.with(|h| *h.borrow_mut() = restored);
        if held > 0 {
            say!("holds: {held} chat(s) held from the last run");
        }
    }
    let Ok(Some(bytes)) = kkv::get(b"queue".to_vec()).await else { return };
    let Ok(snapshot) = serde_json::from_slice::<serde_json::Value>(&bytes) else { return };
    let (report, notices) = QUEUE.with(|q| q.borrow_mut().restore(&snapshot));
    for notice in &notices {
        let (chat, id) = notice.key.split_once('\u{0}').unwrap_or((notice.key.as_str(), ""));
        say!("transcript interrupted chat={chat} id={id} reason={}", notice.reason);
        record(chat, id, serde_json::json!({"state": notice.kind, "reason": notice.reason})).await;
        alert(chat, "", notice.kind, &notice.reason, notice.sent_ms);
    }
    say!("queue: {} restored, {} interrupted, {} dropped", report.queued, report.interrupted, report.dropped);
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
async fn admit(job: AudioJob) {
    let chat = job.chat.to_string();
    if already_handled(&chat, &job.id).await {
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
        record(&chat, &job.id, serde_json::json!({"state": "unsupported", "reason": reason})).await;
        if live && job.sent_ms > 0 {
            alert(&chat, &job.title, "unsupported", reason, job.sent_ms);
        }
        return;
    }
    if fenced(&chat, &job.id).await {
        say!("transcript blocked chat={chat} id={} reason=source_fence", job.id);
        record(&chat, &job.id, serde_json::json!({"state": "blocked", "reason": "source_fence"})).await;
        if live {
            alert(&chat, &job.title, "blocked", "source_fence", job.sent_ms);
        }
        return;
    }
    if compute_held(&chat) {
        // An untargeted mutation or an owner clear: nothing narrower than the chat is provable, so
        // this audio is not even transcribed (Go: blocked_source / source_mutation_or_chat_hold).
        let reason = HOLDS.with(|h| h.borrow().reason(&chat).unwrap_or("chat_hold").to_string());
        say!("transcript blocked chat={chat} id={} reason={reason}", job.id);
        record(&chat, &job.id, serde_json::json!({"state": "blocked", "reason": reason})).await;
        if live {
            alert(&chat, &job.title, "blocked", &reason, job.sent_ms);
        }
        return;
    }
    let key = format!("{chat}\u{0}{}", job.id);
    let sent = job.sent_ms;
    let seconds = job.audio.seconds.unwrap_or(0);
    // The author record is what a later revoke/edit of this message is proved against.
    record(&chat, &job.id, serde_json::json!({"state": "queued", "sender": job.sender.to_string(), "sender_alt": job.sender_alt, "own": job.own})).await;
    if QUEUE.with(|q| q.borrow_mut().enqueue(key, sent, seconds, job)) {
        STATE_DIRTY.with(|d| d.set(true));
    }
}

struct Posted {
    first_id: Option<String>,
    first_ms: Option<i64>,
    edits: u32,
    edit_errors: u32,
}

async fn send(client: &whatsapp_rust::Client, chat: &whatsapp_rust::Jid, body: String, context: &wap::ContextInfo) -> Result<String, String> {
    client.send_message(chat.clone(), wap::Message::text_with_context(body, context.clone())).await.map(|r| r.message_id).map_err(|e| e.to_string())
}

/// The chat title an alert names: a group's `subject` (fetched only when an alert is actually due,
/// and never the push name, which in a group is the sender's), a direct chat's push name.
async fn alert_title(client: &whatsapp_rust::Client, job: &AudioJob) -> String {
    if job.title.is_empty() && job.chat.is_group() {
        return client.groups().get_metadata(&job.chat).await.map(|meta| meta.subject).unwrap_or_default();
    }
    job.title.clone()
}

async fn edit(client: &whatsapp_rust::Client, chat: &whatsapp_rust::Jid, id: &str, body: String, context: &wap::ContextInfo) -> Result<(), String> {
    client.edit_message(chat.clone(), id.to_string(), wap::Message::text_with_context(body, context.clone())).await.map(|_| ()).map_err(|e| e.to_string())
}

/// One step of a recognition: a recognized segment, or the transcript once the recognizer finished.
enum SpeechStep {
    Segment(speech::Segment),
    Done(Result<speech::Transcript, KError>),
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
    let recognition = match speech::recognize(bytes, mime, language.to_string()).await {
        Ok(started) => started,
        Err(error) => {
            let reason = reason_of(&error);
            return if permanent(&reason) { Outcome::Permanent(reason) } else { Outcome::Retry(format!("stt_start:{reason}")) };
        }
    };
    let seconds = job.audio.seconds.unwrap_or(0);
    let own = own_users();
    let holds = HOLDS.with(|h| h.borrow().clone());
    let gate = cfg.gate(&chat, &own, &holds);
    let may_post = gate == posting::Gate::Post;
    let streaming = may_post && cfg.streams(seconds);
    let context = wacore::proto_helpers::build_quote_context_with_info(&job.id, &job.sender, &job.chat, &job.chat, &job.message);
    let mut posted = Posted { first_id: None, first_ms: None, edits: 0, edit_errors: 0 };
    let mut pacer = posting::EditPacer::new(cfg.edit_interval_ms);
    let header = cfg.header();
    let mut so_far = String::new();
    let mut seen = 0u32;
    // The two halves the 0.1 guest polled every 250 ms are two async values now: the segments arrive
    // on a stream while the transcript resolves once. `select` over both is the whole loop.
    let segments = recognition.segments();
    let transcript = recognition.transcript();
    let recognized = futures::stream::unfold(segments, |mut segments| async move {
        segments.next().await.map(|segment| (SpeechStep::Segment(segment), segments))
    });
    let settled = futures::stream::once(async move { SpeechStep::Done(transcript.await) });
    let mut steps = Box::pin(futures::stream::select(recognized, settled));
    let result = loop {
        let Some(step) = steps.next().await else {
            break Err(KError::Failed("recognizer_stream_ended".into()));
        };
        let SpeechStep::Segment(segment) = step else {
            let SpeechStep::Done(result) = step else { unreachable!() };
            break result;
        };
        if !streaming {
            continue;
        }
        let text = segment.text.trim();
        if text.is_empty() {
            continue;
        }
        seen += 1;
        if !so_far.is_empty() {
            so_far.push(' ');
        }
        so_far.push_str(text);
        let now = now_ms();
        if pacer.ready(now) && !fenced(&chat, &job.id).await {
            match &posted.first_id {
                None => match send(&client, &job.chat, posting::partial(&so_far, &header), &context).await {
                    Ok(id) => {
                        posted.first_id = Some(id);
                        posted.first_ms = Some(now_ms());
                        pacer.mark(now, false);
                    }
                    Err(error) => say!("transcript partial post failed chat={chat} id={} reason={error}", job.id),
                },
                Some(first) => {
                    match edit(&client, &job.chat, first, posting::partial(&so_far, &header), &context).await {
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
    if gate == posting::Gate::Shadow {
        let mut v = base;
        v["posted"] = false.into();
        v["reason"] = "shadow".into();
        record(&chat, &job.id, v).await;
        return Outcome::Done;
    }
    if gate == posting::Gate::Held {
        let mut v = base;
        v["posted"] = false.into();
        v["reason"] = "posting_held_chat".into();
        record(&chat, &job.id, v).await;
        let reason = HOLDS.with(|h| h.borrow().reason(&chat).unwrap_or("posting_held_chat").to_string());
        let title = alert_title(&client, job).await;
        alert(&chat, &title, "post_held", &reason, job.sent_ms);
        return Outcome::Done;
    }
    if fenced(&chat, &job.id).await {
        let mut v = base;
        v["posted"] = false.into();
        v["reason"] = "source_fence_during_decode".into();
        record(&chat, &job.id, v).await;
        say!("transcript not posted chat={chat} id={} reason=source_fence_during_decode", job.id);
        return Outcome::Done;
    }
    // Never post an old transcript: a ready result that could not go out within the window expires.
    if now_ms() - ready > QUEUE.with(|q| q.borrow().policy().fresh_ms) {
        record(&chat, &job.id, serde_json::json!({"state": "expired", "reason": "post_expired"})).await;
        let title = alert_title(&client, job).await;
        alert(&chat, &title, "post_expired", "post_stale_over_5m", job.sent_ms);
        return Outcome::Done;
    }
    let parts = posting::chunks(&transcript.text, &header);
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
        let title = alert_title(&client, job).await;
        alert(&chat, &title, "failed", "send", job.sent_ms);
    }
    record(&chat, &job.id, v).await;
    Outcome::Done
}

/// Run the next queued voice note(s): the main lane, and the express lane while the main lane is
/// decoding a long note, so a short note is not stuck behind it (Go: `processAudioLane`).
fn dispatch(language: &str, cfg: &posting::PostConfig) {
    let now = now_ms();
    for notice in QUEUE.with(|q| q.borrow_mut().expire_stale(now)) {
        settle_notice(&notice, None);
    }
    for lane in [queue::Lane::Main, queue::Lane::Express] {
        let item = QUEUE.with(|q| {
            let mut q = q.borrow_mut();
            match lane {
                queue::Lane::Main => q.take_main(now),
                queue::Lane::Express => q.take_express(now),
            }
        });
        let Some(item) = item else { continue };
        say!("lane {lane:?} takes id={} seconds={}", item.payload.id, item.seconds);
        let language = language.to_string();
        let cfg = cfg.clone();
        spawn_task(Box::pin(async move {
            let outcome = process(&item.payload, &language, &cfg).await;
            COMPLETIONS.with(|c| c.borrow_mut().push((item, outcome)));
        }));
    }
}

/// `settle_notice` is the async half: the queue bookkeeping is sync, the record and alert are not.
fn settle_notice(notice: &queue::Notice, title: Option<&str>) {
    let (chat, id) = notice.key.split_once('\u{0}').unwrap_or((notice.key.as_str(), ""));
    let kind = if notice.kind == "failed" && permanent(&notice.reason) { "unsupported" } else { notice.kind };
    say!("transcript {} chat={chat} id={id} reason={}", if kind == "audio_expired" { "expired" } else { kind }, notice.reason);
    let (chat, id) = (chat.to_string(), id.to_string());
    let (kind, reason, sent_ms, title) = (kind.to_string(), notice.reason.clone(), notice.sent_ms, title.unwrap_or("").to_string());
    STATE_DIRTY.with(|d| d.set(true));
    spawn_task(Box::pin(async move {
        record(&chat, &id, serde_json::json!({"state": kind, "reason": reason})).await;
        alert(&chat, &title, &kind, &reason, sent_ms);
    }));
}

async fn settle_completions() {
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
        let committed = match (&notice, title.as_str()) {
            (Some(notice), title) => {
                let (chat, id) = notice.key.split_once('\u{0}').unwrap_or((notice.key.as_str(), ""));
                let kind = if notice.kind == "failed" && permanent(&notice.reason) { "unsupported" } else { notice.kind };
                say!("transcript {} chat={chat} id={id} reason={}", if kind == "audio_expired" { "expired" } else { kind }, notice.reason);
                Some((chat.to_string(), id.to_string(), kind.to_string(), notice.reason.clone(), notice.sent_ms, title.to_string()))
            }
            (None, _) => None,
        };
        if let Some((chat, id, kind, reason, sent_ms, title)) = committed {
            record(&chat, &id, serde_json::json!({"state": kind, "reason": reason})).await;
            alert(&chat, &title, &kind, &reason, sent_ms);
        }
        STATE_DIRTY.with(|d| d.set(true));
    }
}

/// Send the batched own-chat log when one is due (never into a source chat).
fn send_alerts(enabled: bool) {
    if !enabled || ALERT_SENDING.with(|s| s.get()) {
        return;
    }
    let Some(client) = CLIENT.with(|c| c.borrow().clone()) else { return };
    let Some(own) = client.pn().map(|j| j.to_non_ad()) else { return };
    let now = now_ms();
    let Some(text) = ALERTS.with(|a| a.borrow_mut().due(now)) else { return };
    ALERT_SENDING.with(|s| s.set(true));
    spawn_task(Box::pin(async move {
        match client.send_message(own, wap::Message::text(text)).await {
            Ok(_) => {
                ALERTS.with(|a| a.borrow_mut().sent(now_ms()));
                say!("alerts sent (own chat)");
            }
            Err(error) => say!("alerts send failed reason={error}"),
        }
        ALERT_SENDING.with(|s| s.set(false));
    }));
}

// ---- Runtime --------------------------------------------------------------------------------

struct HostRuntime;
// Single-threaded guest: the runtime never crosses a thread, and neither do the tasks it spawns.
unsafe impl Send for HostRuntime {}
unsafe impl Sync for HostRuntime {}

#[async_trait(?Send)]
impl Runtime for HostRuntime {
    fn spawn(&self, future: Pin<Box<dyn Future<Output = ()> + 'static>>) -> AbortHandle {
        let (task, handle) = futures::future::abortable(future);
        let abort = handle.clone();
        spawn_task(Box::pin(async move {
            let _ = task.await;
        }));
        AbortHandle::new(move || abort.abort())
    }
    /// A timer the runtime suspends this task on: `wasi:clocks@0.3.0.wait-for`, not a thread sleep
    /// and not an entry in a timer list the guest has to wake.
    fn sleep(&self, duration: Duration) -> Pin<Box<dyn Future<Output = ()>>> {
        Box::pin(wait(duration))
    }
    fn spawn_blocking(&self, f: Box<dyn FnOnce() + 'static>) -> Pin<Box<dyn Future<Output = ()>>> {
        f();
        Box::pin(std::future::ready(()))
    }
    fn yield_now(&self) -> Option<Pin<Box<dyn Future<Output = ()>>>> {
        Some(Box::pin(std::future::ready(())))
    }
    fn yield_frequency(&self) -> u32 {
        1
    }
}

// ---- Transport over wa:kernel/websocket -------------------------------------------------------

/// What the protocol asks the socket to do; the socket task owns the socket itself.
enum Outgoing {
    Frame(Bytes),
    Close,
}

struct HostTransport {
    out: async_channel::Sender<Outgoing>,
}

#[async_trait(?Send)]
impl Transport for HostTransport {
    async fn send(&self, data: Bytes) -> Result<(), anyhow::Error> {
        // `async_channel` gives backpressure: a full queue parks this task instead of dropping a
        // frame, which is what 0.1's non-blocking `wa_ws.send` could not do.
        self.out.send(Outgoing::Frame(data)).await.map_err(|_| anyhow::anyhow!("websocket closed"))
    }
    async fn disconnect(&self) {
        let _ = self.out.send(Outgoing::Close).await;
    }
}

struct HostTransportFactory;

#[async_trait(?Send)]
impl TransportFactory for HostTransportFactory {
    async fn create_transport(&self) -> Result<(Arc<dyn Transport>, async_channel::Receiver<TransportEvent>), anyhow::Error> {
        let socket = websocket::Socket::connect(WHATSAPP_WEB_WS_URL.to_string(), Some(WHATSAPP_WEB_ORIGIN.to_string()))
            .await
            .map_err(|e| anyhow::anyhow!("websocket connect: {e:?}"))?;
        let (out, outgoing) = async_channel::unbounded::<Outgoing>();
        let (events, received) = async_channel::unbounded::<TransportEvent>();
        let _ = events.try_send(TransportEvent::Connected);
        spawn_task(Box::pin(pump(socket, outgoing, events)));
        say!("transport: connected");
        Ok((Arc::new(HostTransport { out }), received))
    }
}

/// The socket task: the inbound `stream<list<u8>>` and the outbound queue, joined. This is what the
/// 0.1 guest's `pump_sockets` + `wake_io` + 5 ms nap loop did, as one select over two streams.
async fn pump(socket: websocket::Socket, outgoing: async_channel::Receiver<Outgoing>, events: async_channel::Sender<TransportEvent>) {
    let frames = socket.messages();
    let inbound = futures::stream::unfold(frames, |mut frames| async move {
        frames.next().await.map(|frame| (Step::Inbound(frame), frames))
    });
    // The outbound queue ends when every transport handle is dropped, which is a disconnect.
    let outbound = outgoing.map(Step::Outbound).chain(futures::stream::once(async { Step::OutboundClosed }));
    let mut steps = Box::pin(futures::stream::select(inbound, outbound));
    while let Some(step) = steps.next().await {
        match step {
            Step::Inbound(frame) => {
                if events.try_send(TransportEvent::DataReceived(Bytes::from(frame))).is_err() {
                    return;
                }
            }
            Step::Outbound(Outgoing::Frame(frame)) => {
                if let Err(error) = socket.send(frame.to_vec()).await {
                    say!("transport: send failed ({error:?})");
                    let _ = events.try_send(TransportEvent::Disconnected(DisconnectReason::StreamEnded));
                    socket.close(1000, "send failed".into());
                    return;
                }
            }
            Step::Outbound(Outgoing::Close) | Step::OutboundClosed => {
                socket.close(1000, "bye".into());
                return;
            }
        }
    }
    say!("transport: stream ended");
    let _ = events.try_send(TransportEvent::Disconnected(DisconnectReason::StreamEnded));
}

enum Step {
    Inbound(Vec<u8>),
    Outbound(Outgoing),
    OutboundClosed,
}

// ---- HttpClient over wa:kernel/http -----------------------------------------------------------

struct HostHttp;

#[async_trait(?Send)]
impl HttpClient for HostHttp {
    async fn execute(&self, request: HttpRequest) -> anyhow::Result<HttpResponse> {
        let req = khttp::Request {
            method: request.method,
            url: request.url,
            headers: request.headers.into_iter().collect(),
            body: request.body.map(|b| b.to_vec()).unwrap_or_default(),
        };
        // One awaitable exchange instead of `start` + a poll loop; the body is a stream, drained
        // here into the bytes the protocol's HttpClient contract promises.
        let response = khttp::send(req).await.map_err(|e| anyhow::anyhow!("http exchange: {e:?}"))?;
        let status_code = response.status();
        let mut body = Vec::new();
        let mut chunks = response.body();
        while let Some(chunk) = chunks.next().await {
            body.extend_from_slice(&chunk);
        }
        Ok(HttpResponse { status_code, body })
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
    /// One suspendable call: the runtime parks it while it waits, and it returns when the
    /// supervisor asks it to stop (or when the protocol loop gives up).
    async fn run(config: String) -> Result<(), String> {
        serve(serde_json::from_str(&config).unwrap_or_default()).await;
        Ok(())
    }
}

/// The main loop's cadence: how often the pipeline re-reads its own queues. It is not a poll of
/// host I/O - the host has its own task - only of what the tasks in this process left behind.
const TICK: Duration = Duration::from_millis(100);

async fn serve(config: serde_json::Value) {
    let level = match config["log"].as_str().unwrap_or("info") {
        "debug" => log::LevelFilter::Debug,
        "trace" => log::LevelFilter::Trace,
        "warn" => log::LevelFilter::Warn,
        _ => log::LevelFilter::Info,
    };
    let _ = log::set_boxed_logger(Box::new(Logger(level))).map(|_| log::set_max_level(level));
    let _ = wacore::time::set_time_provider(WasiClock);
    say!("clock: {} ms since epoch", wacore::time::now_millis());
    let pair_phone = config["pair_phone"].as_str().map(str::to_string);
    let language = config["language"].as_str().unwrap_or("pt").to_string();
    let post = posting::PostConfig::from_json(&config);
    if let Some(seconds) = config["fresh_seconds"].as_i64() {
        let policy = queue::Policy { fresh_ms: seconds.clamp(60, 86_400) * 1000, ..queue::Policy::default() };
        QUEUE.with(|q| *q.borrow_mut() = queue::AudioQueue::new(policy));
    }
    // What the last run left behind: held chats, fences, and queued (or interrupted) voice notes.
    restore_state().await;
    reprove_holds().await;
    say!(
        "transcription: language {language}, posting {} (allow {:?}), alerts {}, stream_edits {} (min {} s, edit every {} s), held chats {} (configured {})",
        if post.post { "on" } else { "off" },
        post.allow,
        if post.alerts { "on" } else { "off" },
        post.stream_edits,
        post.stream_min_seconds,
        post.edit_interval_ms / 1000,
        HOLDS.with(|h| h.borrow().held_chats()),
        post.held.len()
    );
    say!("wa-whatsapp: starting (pairing by {})", if pair_phone.is_some() { "code" } else { "QR" });
    let tasks = Tasks::start();
    let runtime = HostRuntime;
    say!("wa-whatsapp: starting the protocol task");
    spawn_task(Box::pin(async move {
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
        let stored_paired = store::stored_device_paired().await;
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
                let chat = ctx.info.source.chat.to_string();
                // Revokes and edits are the only source mutations we can see: each names the message
                // ID it changes, and holds.rs decides whether that is provable (holds.rs).
                let kind = match base.protocol_message.as_option().map(|pm| pm.r#type) {
                    Some(Some(wap::message::protocol_message::Type::REVOKE)) => Some("revoke"),
                    Some(Some(wap::message::protocol_message::Type::MESSAGE_EDIT)) => Some("edit"),
                    _ => match ctx.info.edit {
                        wacore::types::message::EditAttribute::SenderRevoke | wacore::types::message::EditAttribute::AdminRevoke => Some("revoke"),
                        wacore::types::message::EditAttribute::MessageEdit => Some("edit"),
                        _ => None,
                    },
                };
                if let Some(kind) = kind {
                    if let Some((target, key_chat)) = base.protocol_message.as_option().and_then(|pm| pm.key.as_option()).map(|k| (k.id.clone().unwrap_or_default(), k.remote_jid.clone().unwrap_or_default())) {
                        // Proved when the mutation's key names this chat; a DM may be journaled under
                        // its LID while the key carries the PN, which is exactly the unproven case
                        // (proven later from the recorded author, holds.rs `reprove`).
                        let scope_proven = key_chat.is_empty() || same_chat(&key_chat, &chat);
                        INBOX_MUTATIONS.with(|m| {
                            m.borrow_mut().push(Mutation {
                                chat: chat.clone(),
                                kind: kind.to_string(),
                                target,
                                // The mutation's author is the envelope's sender, never the key's
                                // participant (that is the author of the message being changed).
                                sender: ctx.info.source.sender.to_string(),
                                sender_alt: ctx.info.source.sender_alt.as_ref().map(|j| j.to_string()).unwrap_or_default(),
                                own: ctx.info.source.is_from_me,
                                owner: false,
                                scope_proven,
                            })
                        });
                    }
                }
                let skip = chat == "status@broadcast" || chat.ends_with("@newsletter");
                if let (Some(audio), false) = (base.audio_message.as_option(), skip) {
                    AUDIO_INBOX.with(|q| {
                        q.borrow_mut().push(AudioJob {
                            chat: ctx.info.source.chat.clone(),
                            sender: ctx.info.source.sender.clone(),
                            sender_alt: ctx.info.source.sender_alt.as_ref().map(|j| j.to_string()).unwrap_or_default(),
                            id: ctx.info.id.to_string(),
                            // A group is named by its subject, which the pipeline fetches (alerts.rs
                            // title_of); the push name in a group is the sender's.
                            title: alerts::title_of(ctx.info.source.is_group, &ctx.info.push_name, None),
                            own: ctx.info.source.is_from_me,
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
    }));
    futures::pin_mut!(tasks);
    let main = main_loop(&language, &post);
    futures::pin_mut!(main);
    // Whichever finishes ends the service: the driver never does, so in practice the main loop.
    futures::future::select(tasks, main).await;
    say!("wa-whatsapp: stopped");
}

/// The pipeline's own loop: admit what the message handler handed over, settle what the tasks
/// finished, dispatch the next lane, send the alert batch, persist. Every wait in it is an await on
/// a runtime timer, and a stop is noticed within one tick.
async fn main_loop(language: &str, post: &posting::PostConfig) {
    let mut last_tick = Instant::now();
    loop {
        for mutation in INBOX_MUTATIONS.with(|m| std::mem::take(&mut *m.borrow_mut())) {
            apply_mutation(mutation).await;
        }
        for job in AUDIO_INBOX.with(|q| std::mem::take(&mut *q.borrow_mut())) {
            admit(job).await;
        }
        settle_completions().await;
        if last_tick.elapsed() >= TICK * 2 {
            last_tick = Instant::now();
            dispatch(language, post);
            send_alerts(post.alerts);
            persist_state().await;
        }
        if lifecycle::stopping() {
            say!("wa-whatsapp: stopping");
            persist_state().await;
            return;
        }
        wait(TICK).await;
    }
}
