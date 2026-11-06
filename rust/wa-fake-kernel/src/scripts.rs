//! Scripted answers: what the kernel says when the component reaches out.
//!
//! Every script is data, never a closure: a test writes down what the world answers, and the same
//! list can be recorded and replayed. An exchange no rule names is refused by name
//! (`http_not_scripted:…`) - a test that forgets to script one fails instead of passing on an empty
//! answer.

use serde_json::json;

/// One scripted http answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpRule {
    /// `GET`, `POST`, … or `*` for every method.
    pub method: String,
    /// The whole URL, or a prefix ending in `*` (`http://127.0.0.1:9999/*`).
    pub url: String,
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl HttpRule {
    /// `200` with the given bytes and no headers.
    pub fn ok(method: &str, url: &str, body: &[u8]) -> HttpRule {
        HttpRule { method: method.to_string(), url: url.to_string(), status: 200, headers: Vec::new(), body: body.to_vec() }
    }

    /// `200 application/json` with `body` as the text.
    pub fn ok_json(method: &str, url: &str, body: &str) -> HttpRule {
        HttpRule {
            method: method.to_string(),
            url: url.to_string(),
            status: 200,
            headers: vec![("content-type".into(), "application/json".into())],
            body: body.as_bytes().to_vec(),
        }
    }

    /// Any status with those bytes: a 4xx/5xx answer is a response, not an error (`wa:kernel@0.2`,
    /// `http.send`), so this is how a test scripts a server failure.
    pub fn status(method: &str, url: &str, status: u16, body: &[u8]) -> HttpRule {
        HttpRule { method: method.to_string(), url: url.to_string(), status, headers: Vec::new(), body: body.to_vec() }
    }

    pub fn with_header(mut self, name: &str, value: &str) -> HttpRule {
        self.headers.push((name.to_string(), value.to_string()));
        self
    }

    pub(crate) fn matches(&self, method: &str, url: &str) -> bool {
        let method_ok = self.method == "*" || self.method.eq_ignore_ascii_case(method);
        if !method_ok {
            return false;
        }
        match self.url.strip_suffix('*') {
            Some(prefix) => url.starts_with(prefix),
            None => self.url == url,
        }
    }
}

/// One scripted websocket: the frames the peer sends, and whether a `send` comes back.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WsRule {
    pub url: String,
    /// Delivered on `socket.messages()`, in order, before the peer closes.
    pub inbound: Vec<Vec<u8>>,
    /// Echo every frame the component sends back into `messages` (a peer that answers).
    pub echo: bool,
}

impl WsRule {
    pub fn new(url: &str) -> WsRule {
        WsRule { url: url.to_string(), inbound: Vec::new(), echo: false }
    }
    pub fn delivering(mut self, frames: &[&[u8]]) -> WsRule {
        self.inbound = frames.iter().map(|frame| frame.to_vec()).collect();
        self
    }
    pub fn echoing(mut self) -> WsRule {
        self.echo = true;
        self
    }
}

/// A scripted recognition: the recognizer's segments and its whole transcript.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SttScript {
    pub text: String,
    pub language: String,
    pub elapsed_ms: u64,
    /// `(start-ms, end-ms, text)`, in order.
    pub segments: Vec<(u64, u64, String)>,
    /// When set, `transcript` resolves to `failed(reason)` and no segments are emitted.
    pub error: Option<String>,
}

impl SttScript {
    pub fn text(text: &str) -> SttScript {
        SttScript { text: text.to_string(), language: "pt".into(), elapsed_ms: 5, segments: Vec::new(), error: None }
    }
    pub fn language(mut self, language: &str) -> SttScript {
        self.language = language.to_string();
        self
    }
    pub fn elapsed_ms(mut self, ms: u64) -> SttScript {
        self.elapsed_ms = ms;
        self
    }
    pub fn segment(mut self, start_ms: u64, end_ms: u64, text: &str) -> SttScript {
        self.segments.push((start_ms, end_ms, text.to_string()));
        self
    }
    pub fn failing(mut self, reason: &str) -> SttScript {
        self.error = Some(reason.to_string());
        self
    }
    /// The script as one JSON value, which is what a record/replay step stores and what the CLI's
    /// `--speech` flag takes.
    pub fn to_json(&self) -> serde_json::Value {
        json!({
            "text": self.text,
            "language": self.language,
            "elapsed_ms": self.elapsed_ms,
            "segments": self.segments.iter().map(|(start, end, text)| json!({"start_ms": start, "end_ms": end, "text": text})).collect::<Vec<_>>(),
            "error": self.error,
        })
    }
}

/// A recognition as a record or a replay holds it: the scripted `SttScript` without its builder
/// methods, so a recorded answer and a script are the same value.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RecognitionScript {
    pub text: String,
    pub language: String,
    pub elapsed_ms: u64,
    pub segments: Vec<(u64, u64, String)>,
    pub error: Option<String>,
}

impl RecognitionScript {
    pub fn from_json(value: &serde_json::Value) -> RecognitionScript {
        RecognitionScript {
            text: value["text"].as_str().unwrap_or_default().to_string(),
            language: value["language"].as_str().unwrap_or("auto").to_string(),
            elapsed_ms: value["elapsed_ms"].as_u64().unwrap_or(0),
            segments: value["segments"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|segment| {
                    (
                        segment["start_ms"].as_u64().unwrap_or(0),
                        segment["end_ms"].as_u64().unwrap_or(0),
                        segment["text"].as_str().unwrap_or_default().to_string(),
                    )
                })
                .collect(),
            error: value["error"].as_str().map(str::to_string),
        }
    }
}

impl From<&SttScript> for RecognitionScript {
    fn from(script: &SttScript) -> RecognitionScript {
        RecognitionScript {
            text: script.text.clone(),
            language: script.language.clone(),
            elapsed_ms: script.elapsed_ms,
            segments: script.segments.clone(),
            error: script.error.clone(),
        }
    }
}

/// Does a granted `net` entry cover `address`? The node's rule, verbatim
/// (`rust/wa-kernel-runtime/src/services.rs`, `dial_allowed`): an exact entry, or `host:*` for every
/// port on that host, or `*.suffix:port` for any host under that suffix.
pub fn dial_allowed(granted: &[String], address: &str) -> bool {
    let Some((host, port)) = address.rsplit_once(':') else { return false };
    if host.is_empty() || port.parse::<u16>().is_err() || host.contains(['/', '@', ' ']) {
        return false;
    }
    let host = host.to_ascii_lowercase();
    let port_wild = format!("{host}:*");
    granted.iter().any(|entry| {
        let entry = entry.to_ascii_lowercase();
        if entry == format!("{host}:{port}") || entry == port_wild {
            return true;
        }
        match entry.strip_prefix("*.").and_then(|rest| rest.rsplit_once(':')) {
            Some((suffix, p)) => p == port && host.ends_with(&format!(".{suffix}")) && host.len() > suffix.len() + 1,
            None => false,
        }
    })
}

/// The `host:port` of a URL, which is what a `net` grant names: `http://user@[::1]:80/x` is
/// refused rather than guessed at (as in the host's own `url_authority`).
pub fn url_authority(url: &str) -> Option<String> {
    let rest = url.split_once("://").map(|(_, rest)| rest)?;
    let authority = rest.split(['/', '?', '#']).next()?;
    let authority = authority.rsplit_once('@').map(|(_, host)| host).unwrap_or(authority);
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) if port.parse::<u16>().is_ok() => (host, port.parse::<u16>().ok()?),
        _ => (authority, if url.starts_with("wss://") || url.starts_with("https://") { 443 } else { 80 }),
    };
    if host.is_empty() || host.contains(['[', ']']) {
        return None;
    }
    Some(format!("{}:{port}", host.to_ascii_lowercase()))
}
