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
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::time::Duration;

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
        std::thread::Builder::new()
            .name("wa-service-ws".into())
            .spawn(move || pump(socket, out_rx, in_tx))
            .map_err(|e| e.to_string())?;
        Ok(WsConn { out: out_tx, inbound: in_rx, pending: None, closed: false })
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

fn pump(mut socket: Socket, out: Receiver<Option<Vec<u8>>>, inbound: Sender<WsEvent>) {
    use tungstenite::{Error, Message};
    loop {
        loop {
            match out.try_recv() {
                Ok(Some(data)) => {
                    if socket.send(Message::Binary(data.into())).is_err() {
                        let _ = inbound.send(WsEvent::Closed);
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
            }
            Ok(Message::Close(_)) | Ok(Message::Binary(_)) => {
                let _ = inbound.send(WsEvent::Closed);
                return;
            }
            Ok(_) => {} // ping/pong/text: tungstenite answers pings on the next flush
            Err(Error::Io(e)) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {
                let _ = socket.flush();
            }
            Err(_) => {
                let _ = inbound.send(WsEvent::Closed);
                return;
            }
        }
    }
}

pub enum HttpState {
    Pending(Receiver<Result<(u16, Vec<u8>), String>>),
    Done(u16, Vec<u8>),
    Failed,
}

/// Start one HTTP exchange on its own thread; 4xx/5xx are results, not errors.
pub fn http_start(meta: &serde_json::Value, body: Vec<u8>) -> Result<HttpState, String> {
    let url = meta.get("url").and_then(|v| v.as_str()).ok_or("url required")?.to_string();
    let method = meta.get("method").and_then(|v| v.as_str()).unwrap_or("GET").to_ascii_uppercase();
    let mut builder = ureq::http::Request::builder().method(method.as_str()).uri(&url);
    if let Some(headers) = meta.get("headers").and_then(|v| v.as_object()) {
        for (k, v) in headers {
            if let Some(v) = v.as_str() {
                builder = builder.header(k.as_str(), v);
            }
        }
    }
    let request = builder.body(body).map_err(|e| e.to_string())?;
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("wa-service-http".into())
        .spawn(move || {
            let agent: ureq::Agent = ureq::Agent::config_builder()
                .http_status_as_error(false)
                .timeout_global(Some(Duration::from_secs(120)))
                .build()
                .into();
            let result = agent.run(request).map_err(|e| e.to_string()).and_then(|mut response| {
                let status = response.status().as_u16();
                response
                    .body_mut()
                    .with_config()
                    .limit(MAX_HTTP_BODY)
                    .read_to_vec()
                    .map(|body| (status, body))
                    .map_err(|e| e.to_string())
            });
            let _ = tx.send(result);
        })
        .map_err(|e| e.to_string())?;
    Ok(HttpState::Pending(rx))
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
