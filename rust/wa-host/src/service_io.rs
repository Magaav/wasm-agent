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
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
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

enum WsEvent {
    Data(Vec<u8>),
    Closed,
}

pub struct WsConn {
    out: Sender<Option<Vec<u8>>>,
    inbound: Receiver<WsEvent>,
    pending: Option<Vec<u8>>,
    closed: bool,
    /// Wakes a 0.2 guest task waiting on `poll_next` when the pump moves a frame.
    notify: Arc<Notify>,
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
        let (out_tx, out_rx) = mpsc::channel::<Option<Vec<u8>>>();
        let (in_tx, in_rx) = mpsc::channel::<WsEvent>();
        let notify = Notify::new();
        let wake = notify.clone();
        std::thread::Builder::new()
            .name("wa-service-ws".into())
            .spawn(move || pump(socket, out_rx, in_tx, wake))
            .map_err(|e| e.to_string())?;
        Ok(WsConn { out: out_tx, inbound: in_rx, pending: None, closed: false, notify })
    }

    fn fill(&mut self) {
        if self.pending.is_some() || self.closed {
            return;
        }
        match self.inbound.try_recv() {
            Ok(WsEvent::Data(data)) => self.pending = Some(data),
            Ok(WsEvent::Closed) | Err(TryRecvError::Disconnected) => self.closed = true,
            Err(TryRecvError::Empty) => {}
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

    /// The next inbound frame (`Some`), or `None` once the peer closed, for a 0.2 guest stream:
    /// `Poll::Pending` registers the caller so the pump's `notify` re-polls it. The race between
    /// "no frame yet" and "register" cannot lose a frame: the pump queues before it notifies.
    pub fn poll_next(&mut self, cx: &mut Context<'_>) -> Poll<Option<Vec<u8>>> {
        match self.inbound.try_recv() {
            Ok(WsEvent::Data(data)) => Poll::Ready(Some(data)),
            Ok(WsEvent::Closed) | Err(TryRecvError::Disconnected) => {
                self.closed = true;
                Poll::Ready(None)
            }
            Err(TryRecvError::Empty) => {
                if self.notify.poll(cx).is_ready() {
                    return self.poll_next(cx);
                }
                Poll::Pending
            }
        }
    }

    pub fn send(&self, data: Vec<u8>) -> i32 {
        if self.closed || self.out.send(Some(data)).is_err() {
            CLOSED
        } else {
            0
        }
    }
}

impl Drop for WsConn {
    fn drop(&mut self) {
        let _ = self.out.send(None);
    }
}

type Socket = tungstenite::WebSocket<tungstenite::stream::MaybeTlsStream<std::net::TcpStream>>;

fn pump(mut socket: Socket, out: Receiver<Option<Vec<u8>>>, inbound: Sender<WsEvent>, notify: Arc<Notify>) {
    use tungstenite::{Error, Message};
    loop {
        loop {
            match out.try_recv() {
                Ok(Some(data)) => {
                    if let Err(error) = socket.send(Message::Binary(data.into())) {
                        eprintln!("[service] wa_ws send error: {error}");
                        let _ = inbound.send(WsEvent::Closed);
                        notify.notify();
                        return;
                    }
                }
                Ok(None) | Err(TryRecvError::Disconnected) => {
                    let _ = socket.close(None);
                    let _ = socket.flush();
                    return;
                }
                Err(TryRecvError::Empty) => break,
            }
        }
        match socket.read() {
            Ok(Message::Binary(data)) if data.len() <= MAX_MESSAGE => {
                if inbound.send(WsEvent::Data(data.to_vec())).is_err() {
                    return;
                }
                notify.notify();
            }
            Ok(Message::Close(frame)) => {
                eprintln!("[service] wa_ws closed by peer: {frame:?}");
                let _ = inbound.send(WsEvent::Closed);
                notify.notify();
                return;
            }
            Ok(Message::Binary(data)) => {
                eprintln!("[service] wa_ws message over limit ({} bytes); closing", data.len());
                let _ = inbound.send(WsEvent::Closed);
                notify.notify();
                return;
            }
            Ok(_) => {} // ping/pong/text: tungstenite answers pings on the next flush
            Err(Error::Io(e)) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {
                let _ = socket.flush();
            }
            Err(error) => {
                eprintln!("[service] wa_ws read error: {error}");
                let _ = inbound.send(WsEvent::Closed);
                notify.notify();
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
}
