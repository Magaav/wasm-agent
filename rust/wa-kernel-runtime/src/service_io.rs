//! Host I/O for service components: websocket and HTTP done by the host (TLS stays in the host's
//! rustls/ring stack), exposed to the guest as small non-blocking imports. A guest never blocks the
//! host and never blocks its own executor: every call returns at once, `-11` meaning "not yet".
//!
//!   wa_ws.connect(url, url_len, origin, origin_len) -> handle | -13 refused | -1 failed
//!   wa_ws.next(handle)              -> length of the next binary message | -11 none yet | -32 closed
//!   wa_ws.take(handle, ptr, len)    -> bytes copied (the message `next` announced)
//!   wa_ws.send(handle, ptr, len)    -> 0 | -32 closed
//!   wa_ws.close(handle)             -> 0
//!   wa_http.start(meta, meta_len, body, body_len) -> id | -13 refused | -1 failed
//!                                    meta = {"url","method","headers":{..}} (JSON)
//!   wa_http.poll(id)                -> HTTP status (any, 4xx/5xx included) | -11 pending | -1 failed
//!   wa_http.body_len(id) / wa_http.body(id, ptr, len) / wa_http.free(id)
//!
//! Connects are allowed only to granted addresses (`net`, same rules as `wa_sock`), checked on the
//! URL's host and port (wss/https default 443).
//!
//! `wa:kernel@0.2` components (WASI 0.3) get the same host work without the polling contract: the
//! same websocket pump feeds a stream through `poll_next`, and an exchange's completion, a
//! recognizer's progress and a socket's inbound frame all wake the guest task through `Notify` (
//! the host half of `StreamProducer`/`FutureProducer`, which may be woken from any thread).
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

/// A wake-up edge shared by a host thread (the producer) and the guest task (the consumer):
/// `notify` stores the pending edge and wakes the registered waker, `poll` registers the caller's
/// waker and re-checks the edge, so neither side can lose a wake between the two steps.
#[derive(Debug, Default)]
pub struct Notify {
    pending: Mutex<bool>,
    waker: Mutex<Option<Waker>>,
}

impl Notify {
    pub fn new() -> Arc<Notify> {
        Arc::new(Notify::default())
    }

    /// Mark an edge and wake whoever is waiting. Safe from any thread.
    pub fn notify(&self) {
        *self.pending.lock().unwrap() = true;
        let waker = self.waker.lock().unwrap().take();
        if let Some(waker) = waker {
            waker.wake();
        }
    }

    /// Ready once something happened since the last `poll`; otherwise the caller's waker is
    /// registered for the next `notify`. The waker is registered *before* the edge is checked, so a
    /// `notify` that lands in between is either seen here or wakes the registered waker — never
    /// lost.
    pub fn poll(&self, cx: &mut Context<'_>) -> Poll<()> {
        *self.waker.lock().unwrap() = Some(cx.waker().clone());
        let mut pending = self.pending.lock().unwrap();
        if *pending {
            *pending = false;
            return Poll::Ready(());
        }
        Poll::Pending
    }
}

/// A value produced on another thread, awaited by a guest future: `put` stores it and wakes the
/// waiter; `poll_take` has the same no-lost-wake rule as `Notify::poll`.
#[derive(Debug, Default)]
pub struct Slot<T> {
    value: Mutex<Option<T>>,
    waker: Mutex<Option<Waker>>,
}

impl<T: Send> Slot<T> {
    pub fn new() -> Arc<Slot<T>> {
        Arc::new(Slot { value: Mutex::new(None), waker: Mutex::new(None) })
    }

    pub fn put(&self, value: T) {
        *self.value.lock().unwrap() = Some(value);
        let waker = self.waker.lock().unwrap().take();
        if let Some(waker) = waker {
            waker.wake();
        }
    }

    /// Ready with the value once `put` ran; the waker is registered before the value is checked, so
    /// a `put` that lands in between is either seen here or wakes the registered waker.
    pub fn poll_take(&self, cx: &mut Context<'_>) -> Poll<T> {
        *self.waker.lock().unwrap() = Some(cx.waker().clone());
        match self.value.lock().unwrap().take() {
            Some(value) => Poll::Ready(value),
            None => Poll::Pending,
        }
    }
}

/// `Slot::poll_take` as a future, so a host `async fn` can await one exchange.
pub struct SlotFuture<T>(pub Arc<Slot<T>>);

impl<T: Send> std::future::Future for SlotFuture<T> {
    type Output = T;

    fn poll(self: std::pin::Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<T> {
        self.0.poll_take(cx)
    }
}

const MAX_MESSAGE: usize = 32 << 20;
const MAX_HTTP_BODY: u64 = 96 << 20;
pub const AGAIN: i32 = -11;
pub const REFUSED: i32 = -13;
pub const CLOSED: i32 = -32;

/// "host:port" of a ws/wss/http/https URL, for the allowlist.
pub fn url_authority(url: &str) -> Option<String> {
    let (scheme, rest) = url.split_once("://")?;
    let default = match scheme {
        "wss" | "https" => 443,
        "ws" | "http" => 80,
        _ => return None,
    };
    let authority = rest.split(['/', '?', '#']).next()?;
    if authority.is_empty() || authority.contains('@') {
        return None;
    }
    Some(match authority.rsplit_once(':') {
        Some((_, port)) if port.parse::<u16>().is_ok() && !authority.ends_with(']') => authority.to_string(),
        _ => format!("{authority}:{default}"),
    })
}

// ---- websocket frame queues: the one place a peer's burst piles up --------------------------------
//
// A socket has two frame queues between the guest and the network, and both used to be unbounded
// `mpsc` channels: a guest that stopped reading while a chatty peer (WhatsApp, a relay) kept sending,
// or a guest that sent faster than a stalled network drained, grew the node's memory for as long as
// the connection lived. Neither side has to cooperate for that. Both queues are bounded here.
//
// What happens at the bound is a **close**, not a drop: a websocket stream that silently loses a
// frame is a corrupted protocol rather than a bounded one, so the connection ends where the guest can
// see it (`-32`) and the node counts it (`ws_bound_closes`). The frames are counted, not logged with
// their bytes.

/// Inbound frames held for a guest that is behind, and the bytes across them. Both, because one
/// frame may be `MAX_MESSAGE` (32 MiB): a frame count alone would not bound memory.
pub const WS_INBOUND_FRAMES: usize = 256;
pub const WS_INBOUND_BYTES: usize = 16 << 20;
/// Outbound frames a guest may have written that the socket has not taken yet.
pub const WS_OUTBOUND_FRAMES: usize = 64;

/// Connections this process closed because one of their frame queues reached its bound.
static WS_BOUND_CLOSES: AtomicU64 = AtomicU64::new(0);

/// How many websocket connections this process closed at a frame-queue bound. A close is visible to
/// the guest on its own; this is how a reader tells "the peer went away" from "the node refused to
/// hold more".
pub fn ws_bound_closes() -> u64 {
    WS_BOUND_CLOSES.load(Ordering::Relaxed)
}

fn count_bound_close(direction: &str, frames: usize, bytes: usize) {
    WS_BOUND_CLOSES.fetch_add(1, Ordering::Relaxed);
    eprintln!("[service] wa_ws {direction} queue over its bound ({frames} frames, {bytes} bytes); closing");
}

/// The frames the pump has queued for the guest, bounded by [`WS_INBOUND_FRAMES`] and
/// [`WS_INBOUND_BYTES`], plus the one closed flag both runners read.
struct Inbound {
    state: Mutex<InboundState>,
    /// Wakes a 0.2 guest task waiting on `poll_next` when a frame is queued or the stream ends.
    notify: Arc<Notify>,
}

struct InboundState {
    frames: VecDeque<Vec<u8>>,
    bytes: usize,
    closed: bool,
    /// Set when this node ended the connection because a queue reached its bound (as opposed to the
    /// peer ending it), so a guest or a test can tell the two apart.
    overflowed: bool,
}

impl Inbound {
    fn new(notify: Arc<Notify>) -> Arc<Inbound> {
        Arc::new(Inbound {
            state: Mutex::new(InboundState { frames: VecDeque::new(), bytes: 0, closed: false, overflowed: false }),
            notify,
        })
    }

    /// Queue one frame. `Err((frames, bytes))` is the bound: the caller closes the connection instead
    /// of dropping the frame, and reports what was held when it did.
    fn push(&self, data: Vec<u8>) -> Result<(), (usize, usize)> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.closed {
            return Err((state.frames.len(), state.bytes));
        }
        if state.frames.len() + 1 > WS_INBOUND_FRAMES || state.bytes + data.len() > WS_INBOUND_BYTES {
            return Err((state.frames.len(), state.bytes));
        }
        state.bytes += data.len();
        state.frames.push_back(data);
        drop(state);
        self.notify.notify();
        Ok(())
    }

    /// The stream ended - peer close, a read error, or this node's own bound. Always succeeds, even at
    /// the bound, because the closed flag is not a queue entry.
    fn close(&self) {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).closed = true;
        self.notify.notify();
    }

    fn take(&self) -> Option<Vec<u8>> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let frame = state.frames.pop_front()?;
        state.bytes -= frame.len();
        Some(frame)
    }

    fn is_closed(&self) -> bool {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).closed
    }

    fn mark_overflow(&self) {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).overflowed = true;
    }

    fn is_overflowed(&self) -> bool {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).overflowed
    }

    fn poll(&self, cx: &mut Context<'_>) -> Poll<()> {
        self.notify.poll(cx)
    }
}

pub struct WsConn {
    /// Frames the guest sent that the socket has not taken yet, bounded: `send` closes rather than
    /// growing this for a socket that cannot keep up.
    out: SyncSender<Vec<u8>>,
    /// Set when this side ends the connection (drop, or an outbound overflow); the pump closes the
    /// socket and exits instead of draining what is left.
    stop: Arc<AtomicBool>,
    inbound: Arc<Inbound>,
    pending: Option<Vec<u8>>,
    closed: bool,
}

impl WsConn {
    pub fn open(url: &str, origin: Option<&str>) -> Result<WsConn, String> {
        use tungstenite::client::IntoClientRequest;
        let mut request = url.into_client_request().map_err(|e| e.to_string())?;
        if let Some(origin) = origin {
            request.headers_mut().insert("Origin", origin.parse().map_err(|_| "invalid origin".to_string())?);
        }
        let (mut socket, _response) = tungstenite::connect(request).map_err(|e| e.to_string())?;
        let timeout = Some(Duration::from_millis(20));
        match socket.get_mut() {
            tungstenite::stream::MaybeTlsStream::Plain(s) => s.set_read_timeout(timeout).map_err(|e| e.to_string())?,
            tungstenite::stream::MaybeTlsStream::Rustls(s) => s.get_mut().set_read_timeout(timeout).map_err(|e| e.to_string())?,
            _ => return Err("unsupported stream".into()),
        }
        let (out_tx, out_rx) = mpsc::sync_channel::<Vec<u8>>(WS_OUTBOUND_FRAMES);
        let inbound = Inbound::new(Notify::new());
        let stop = Arc::new(AtomicBool::new(false));
        let (pump_inbound, pump_stop) = (inbound.clone(), stop.clone());
        std::thread::Builder::new()
            .name("wa-service-ws".into())
            .spawn(move || pump(socket, out_rx, pump_inbound, pump_stop))
            .map_err(|e| e.to_string())?;
        Ok(WsConn { out: out_tx, stop, inbound, pending: None, closed: false })
    }

    fn fill(&mut self) {
        if self.pending.is_some() || self.closed {
            return;
        }
        match self.inbound.take() {
            Some(data) => self.pending = Some(data),
            None if self.inbound.is_closed() || self.stop.load(Ordering::Relaxed) => self.closed = true,
            None => {}
        }
    }

    pub fn next(&mut self) -> i32 {
        self.fill();
        match (&self.pending, self.closed) {
            (Some(data), _) => data.len() as i32,
            (None, true) => CLOSED,
            (None, false) => AGAIN,
        }
    }

    pub fn take(&mut self) -> Option<Vec<u8>> {
        self.pending.take()
    }

    /// Did this node end the connection because a frame queue reached its bound? The guest sees the
    /// same thing either way (`CLOSED`); this is what tells the two apart for a reader diagnosing it.
    pub fn over_bound(&self) -> bool {
        self.inbound.is_overflowed()
    }

    /// The next inbound frame (`Some`), or `None` once the peer closed, for a 0.2 guest stream:
    /// `Poll::Pending` registers the caller so the pump's `notify` re-polls it. The race between
    /// "no frame yet" and "register" cannot lose a frame: the pump queues before it notifies.
    pub fn poll_next(&mut self, cx: &mut Context<'_>) -> Poll<Option<Vec<u8>>> {
        if let Some(data) = self.inbound.take() {
            return Poll::Ready(Some(data));
        }
        if self.inbound.is_closed() || self.stop.load(Ordering::Relaxed) {
            self.closed = true;
            return Poll::Ready(None);
        }
        if self.inbound.poll(cx).is_ready() {
            return self.poll_next(cx);
        }
        Poll::Pending
    }

    /// Send one frame. `0` means it is queued; [`CLOSED`] means the stream ended - the peer, this
    /// side's drop, or the outbound queue reaching its bound.
    pub fn send(&self, data: Vec<u8>) -> i32 {
        if self.closed || self.stop.load(Ordering::Relaxed) || self.inbound.is_closed() {
            return CLOSED;
        }
        match self.out.try_send(data) {
            Ok(()) => 0,
            Err(TrySendError::Full(_)) => {
                self.inbound.mark_overflow();
                count_bound_close("outbound", WS_OUTBOUND_FRAMES, 0);
                self.stop.store(true, Ordering::Relaxed);
                CLOSED
            }
            Err(TrySendError::Disconnected(_)) => CLOSED,
        }
    }
}

impl Drop for WsConn {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.inbound.close();
    }
}

type Socket = tungstenite::WebSocket<tungstenite::stream::MaybeTlsStream<std::net::TcpStream>>;

fn pump(mut socket: Socket, out: Receiver<Vec<u8>>, inbound: Arc<Inbound>, stop: Arc<AtomicBool>) {
    use tungstenite::{Error, Message};
    loop {
        if stop.load(Ordering::Relaxed) {
            let _ = socket.close(None);
            let _ = socket.flush();
            inbound.close();
            return;
        }
        loop {
            match out.try_recv() {
                Ok(data) => {
                    if let Err(error) = socket.send(Message::Binary(data.into())) {
                        eprintln!("[service] wa_ws send error: {error}");
                        inbound.close();
                        return;
                    }
                }
                Err(TryRecvError::Disconnected) => {
                    let _ = socket.close(None);
                    let _ = socket.flush();
                    inbound.close();
                    return;
                }
                Err(TryRecvError::Empty) => break,
            }
        }
        match socket.read() {
            Ok(Message::Binary(data)) if data.len() <= MAX_MESSAGE => {
                if let Err((frames, bytes)) = inbound.push(data.to_vec()) {
                    inbound.mark_overflow();
                    count_bound_close("inbound", frames, bytes);
                    let _ = socket.close(None);
                    let _ = socket.flush();
                    inbound.close();
                    return;
                }
            }
            Ok(Message::Close(frame)) => {
                eprintln!("[service] wa_ws closed by peer: {frame:?}");
                inbound.close();
                return;
            }
            Ok(Message::Binary(data)) => {
                eprintln!("[service] wa_ws message over limit ({} bytes); closing", data.len());
                inbound.close();
                return;
            }
            Ok(_) => {} // ping/pong/text: tungstenite answers pings on the next flush
            Err(Error::Io(e)) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {
                let _ = socket.flush();
            }
            Err(error) => {
                eprintln!("[service] wa_ws read error: {error}");
                inbound.close();
                return;
            }
        }
    }
}

/// One stored row: the key and its value, as `Kv::scan` returns them.
pub type Entry = (Vec<u8>, Vec<u8>);

/// The `wa:kernel/kv` store: one SQLite file per component
/// (`<components>/<name>.state/kv.sqlite`), opened on the first call. The 0.1 runner polls it and
/// the 0.2 runner awaits it, so the store itself lives here, once, for both contracts.
pub struct Kv {
    path: Option<std::path::PathBuf>,
    conn: Option<rusqlite::Connection>,
}

impl Kv {
    pub fn new(path: Option<std::path::PathBuf>) -> Kv {
        Kv { path, conn: None }
    }

    fn db(&mut self) -> Result<&rusqlite::Connection, String> {
        if self.conn.is_none() {
            let path = self.path.clone().ok_or_else(|| "storage not declared".to_string())?;
            let dir = path.parent().ok_or_else(|| "kv path".to_string())?;
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
            let conn = rusqlite::Connection::open(&path).map_err(|e| e.to_string())?;
            wa_sqlite::tune_wait(&conn).map_err(|e| e.to_string())?;
            conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS kv(k BLOB PRIMARY KEY, v BLOB NOT NULL);")
                .map_err(|e| e.to_string())?;
            self.conn = Some(conn);
        }
        Ok(self.conn.as_ref().expect("opened"))
    }

    pub fn get(&mut self, key: Vec<u8>) -> Result<Option<Vec<u8>>, String> {
        let db = self.db()?;
        match db.query_row("SELECT v FROM kv WHERE k=?1", rusqlite::params![key], |r| r.get(0)) {
            Ok(v) => Ok(Some(v)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.to_string()),
        }
    }

    pub fn set(&mut self, key: Vec<u8>, value: Vec<u8>) -> Result<(), String> {
        self.db()?
            .execute("INSERT INTO kv(k,v) VALUES(?1,?2) ON CONFLICT(k) DO UPDATE SET v=excluded.v", rusqlite::params![key, value])
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    pub fn delete(&mut self, key: Vec<u8>) -> Result<(), String> {
        self.db()?.execute("DELETE FROM kv WHERE k=?1", rusqlite::params![key]).map(|_| ()).map_err(|e| e.to_string())
    }

    pub fn delete_prefix(&mut self, prefix: Vec<u8>) -> Result<u32, String> {
        let db = self.db()?;
        let n = if prefix.is_empty() {
            db.execute("DELETE FROM kv", [])
        } else {
            db.execute("DELETE FROM kv WHERE substr(k,1,?2)=?1", rusqlite::params![prefix, prefix.len() as i64])
        };
        n.map(|n| n as u32).map_err(|e| e.to_string())
    }

    /// One page of `(key, value)` whose key starts with `prefix`, ordered by key, after `cursor`.
    /// An empty prefix means every key; ordering by key with an exclusive cursor gives stable pages.
    pub fn scan(&mut self, prefix: Vec<u8>, cursor: Option<Vec<u8>>, limit: u32) -> Result<Vec<Entry>, String> {
        let db = self.db()?;
        let limit = limit.clamp(1, 10_000) as i64;
        let after = cursor.unwrap_or_default();
        let mut stmt = db
            .prepare("SELECT k,v FROM kv WHERE (?2 = 0 OR substr(k,1,?2)=?1) AND (?4 = 0 OR k > ?3) ORDER BY k LIMIT ?5")
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(rusqlite::params![prefix, prefix.len() as i64, after, after.len() as i64, limit], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }
}

pub enum HttpState {
    Pending(Receiver<Result<(u16, Vec<u8>), String>>),
    Done(u16, Vec<u8>),
    Failed,
}

/// A completed exchange: what 0.1 threw away (headers) and 0.2's `response` resource exposes.
#[derive(Debug, Clone)]
pub struct HttpOutcome {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// The exchange itself, shared by the 0.1 poll contract and the 0.2 await contract.
fn exchange(url: String, method: String, headers: Vec<(String, String)>, body: Vec<u8>) -> Result<HttpOutcome, String> {
    let mut builder = ureq::http::Request::builder().method(method.as_str()).uri(&url);
    for (k, v) in &headers {
        builder = builder.header(k.as_str(), v.as_str());
    }
    let request = builder.body(body).map_err(|e| e.to_string())?;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_global(Some(Duration::from_secs(120)))
        .build()
        .into();
    let mut response = agent.run(request).map_err(|e| e.to_string())?;
    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .map(|(k, v)| (k.as_str().to_string(), String::from_utf8_lossy(v.as_bytes()).into_owned()))
        .collect();
    let body = response.body_mut().with_config().limit(MAX_HTTP_BODY).read_to_vec().map_err(|e| e.to_string())?;
    Ok(HttpOutcome { status, headers, body })
}

/// One exchange's url, method and headers, as the `{"url","method","headers":{..}}` meta carries
/// them for both contracts.
type Meta = (String, String, Vec<(String, String)>);

fn parts(meta: &serde_json::Value) -> Result<Meta, String> {
    let url = meta.get("url").and_then(|v| v.as_str()).ok_or("url required")?.to_string();
    let method = meta.get("method").and_then(|v| v.as_str()).unwrap_or("GET").to_ascii_uppercase();
    let headers = meta
        .get("headers")
        .and_then(|v| v.as_object())
        .map(|h| h.iter().filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_string()))).collect())
        .unwrap_or_default();
    Ok((url, method, headers))
}

/// Start one HTTP exchange on its own thread; 4xx/5xx are results, not errors.
pub fn http_start(meta: &serde_json::Value, body: Vec<u8>) -> Result<HttpState, String> {
    let (url, method, headers) = parts(meta)?;
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("wa-service-http".into())
        .spawn(move || {
            let _ = tx.send(exchange(url, method, headers, body).map(|out| (out.status, out.body)));
        })
        .map_err(|e| e.to_string())?;
    Ok(HttpState::Pending(rx))
}

/// Start one HTTP exchange and hand its outcome to `slot`, which a 0.2 guest awaits: the same
/// thread and the same request the 0.1 contract polls, without the poll.
pub fn http_exchange(meta: &serde_json::Value, body: Vec<u8>) -> Result<Arc<Slot<Result<HttpOutcome, String>>>, String> {
    let (url, method, headers) = parts(meta)?;
    let slot = Slot::new();
    let done = slot.clone();
    std::thread::Builder::new()
        .name("wa-service-http".into())
        .spawn(move || done.put(exchange(url, method, headers, body)))
        .map_err(|e| e.to_string())?;
    Ok(slot)
}

impl HttpState {
    pub fn poll(&mut self) -> i32 {
        if let HttpState::Pending(rx) = self {
            match rx.try_recv() {
                Ok(Ok((status, body))) => *self = HttpState::Done(status, body),
                Ok(Err(_)) | Err(TryRecvError::Disconnected) => *self = HttpState::Failed,
                Err(TryRecvError::Empty) => return AGAIN,
            }
        }
        match self {
            HttpState::Done(status, _) => *status as i32,
            _ => -1,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn authorities_for_the_allowlist() {
        assert_eq!(url_authority("wss://web.whatsapp.com/ws/chat").as_deref(), Some("web.whatsapp.com:443"));
        assert_eq!(url_authority("https://mmg.whatsapp.net/v/t62?x=1").as_deref(), Some("mmg.whatsapp.net:443"));
        assert_eq!(url_authority("http://127.0.0.1:8080/x").as_deref(), Some("127.0.0.1:8080"));
        assert_eq!(url_authority("ftp://x/"), None);
        assert_eq!(url_authority("https://user@host/"), None);
    }

    /// The inbound queue's bound, both ways it can be reached: a peer sending more frames than it
    /// holds, and a peer sending few frames that are large. The third assertion is the documented
    /// behaviour at the bound - the push is refused (the caller closes) - and the fourth is that a
    /// refusal is not a loss: what was held before the bound is still readable, in order.
    #[test]
    fn the_inbound_queue_stops_at_its_frame_and_byte_bounds() {
        let inbound = Inbound::new(Notify::new());
        for i in 0..WS_INBOUND_FRAMES {
            assert!(inbound.push(vec![i as u8]).is_ok(), "frame {i} fits the bound");
        }
        let (frames, bytes) = inbound.push(vec![0]).unwrap_err();
        assert_eq!((frames, bytes), (WS_INBOUND_FRAMES, WS_INBOUND_FRAMES), "the refusal names what it held");
        assert!(!inbound.is_closed(), "a refused push does not close the stream by itself");
        for i in 0..WS_INBOUND_FRAMES {
            assert_eq!(inbound.take(), Some(vec![i as u8]), "every frame held before the bound is still there, in order");
        }
        assert_eq!(inbound.take(), None);

        // The byte bound, reached with one frame per push.
        let inbound = Inbound::new(Notify::new());
        let big = vec![0u8; WS_INBOUND_BYTES / 2];
        assert!(inbound.push(big.clone()).is_ok());
        assert!(inbound.push(big.clone()).is_ok());
        let (frames, bytes) = inbound.push(vec![0]).unwrap_err();
        assert_eq!((frames, bytes), (2, WS_INBOUND_BYTES), "a frame count alone would not bound memory");

        // Closing is not a queue entry: it succeeds even with the queue full, and it is what the
        // guest's stream ends on.
        inbound.close();
        assert!(inbound.is_closed());
        assert!(inbound.take().is_some(), "close keeps the frames already held");
    }

    /// End to end over a real loopback socket: a peer that keeps sending while the guest does not
    /// read is closed at the bound, the guest sees `CLOSED` after the frames that were held, and the
    /// process counts it. Before this the queue grew for as long as the connection lived.
    #[test]
    fn a_guest_that_stops_reading_ends_the_socket_at_the_bound() {
        use std::net::TcpListener;

        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("loopback bind");
        let port = listener.local_addr().expect("addr").port();
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept");
            let mut socket = tungstenite::accept(stream).expect("handshake");
            let frame = vec![7u8; 4096];
            for _ in 0..(WS_INBOUND_FRAMES + 16) {
                match socket.send(tungstenite::Message::Binary(frame.clone().into())) {
                    Ok(()) => {},
                    // The node closed the socket at the bound: exactly what the bound is for.
                    Err(_) => break,
                }
            }
            let _ = socket.flush();
        });

        let before = ws_bound_closes();
        let mut conn = WsConn::open(&format!("ws://127.0.0.1:{port}/"), None).expect("connect");
        // The guest is not reading: give the pump time to fill the queue and hit the bound.
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        while !conn.over_bound() && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(conn.over_bound(), "the connection was closed at the bound, not left to grow");
        assert!(ws_bound_closes() > before, "and the close is counted for the process");

        // The frames held before the close are all there, and then the stream ends.
        let mut held = 0usize;
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        loop {
            match conn.next() {
                n if n > 0 => {
                    held += 1;
                    assert!(conn.take().is_some());
                },
                CLOSED => break,
                _ if std::time::Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
                _ => panic!("the stream never ended after the bound"),
            }
        }
        assert!(held <= WS_INBOUND_FRAMES, "at most the bound was held ({held})");
        server.join().unwrap();
    }

    /// The outbound bound: a guest writing faster than the socket drains is refused at the bound
    /// instead of growing a queue. The pump is not reading here (the connection is never reversed),
    /// so the socket buffer plus `WS_OUTBOUND_FRAMES` is the whole budget.
    #[test]
    fn the_outbound_queue_is_bounded_and_refuses_at_the_bound() {
        let (out, rx) = mpsc::sync_channel::<Vec<u8>>(WS_OUTBOUND_FRAMES);
        let stop = Arc::new(AtomicBool::new(false));
        let inbound = Inbound::new(Notify::new());
        let mut conn = WsConn { out, stop: stop.clone(), inbound, pending: None, closed: false };
        let mut refused = 0usize;
        for _ in 0..(WS_OUTBOUND_FRAMES + 8) {
            if conn.send(vec![0u8; 16]) == CLOSED {
                refused += 1;
            }
        }
        assert!(refused > 0, "a full outbound queue refuses instead of queuing without bound");
        assert!(stop.load(Ordering::Relaxed), "and it ends the connection, so the guest sees why");
        assert_eq!(conn.send(vec![0u8; 16]), CLOSED);
        assert_eq!(conn.next(), CLOSED, "the guest reads the close, not a silent drop");
        let drained: Vec<Vec<u8>> = rx.try_iter().collect();
        assert_eq!(drained.len(), WS_OUTBOUND_FRAMES, "exactly the bound was accepted");
    }
}
