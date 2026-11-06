//! What one `stt.requests` job carries: the audio (inline when small, otherwise a short-lived fetch
//! handle), the language snapshot, the freshness bound and the ids of the message it belongs to.
//!
//! Nothing else. In particular there is **no text**: the request is written before anything is
//! recognized, and a decoder that refuses unknown fields (rather than dropping them) is what keeps a
//! transcript, a chat title or a caption from being smuggled into a job record later.
//!
//! The payload is the queue's opaque bytes (`wa_queue::EnqueueRequest::new("stt.requests", payload)`);
//! this module is the one place that knows how to read them. `docs/QUEUE.md` names the media handle
//! (`chat\x00id`) of phase 1; phase 2 moves the bytes themselves across the relay, so the handle
//! grows a token and an expiry, and a worker that does not hold the job any more cannot fetch them.

use serde_json::{json, Map, Value};
use std::fmt;

/// Most audio a job may carry inline in its queue payload. Above this the producer writes the bytes
/// to its own kv behind a [`FetchHandle`]: a media blob in the payload would be copied by every take
/// reply (and by every progress read), which is exactly what `docs/QUEUE.md` tells phase 2 not to do.
pub const INLINE_MAX_BYTES: usize = 256 * 1024;

/// Hard bound on audio a job may name at all (the recognizer's own cap, `service_stt::MAX_AUDIO`).
pub const MAX_AUDIO_BYTES: usize = 20 * 1024 * 1024;

/// Bounds on the identifier strings, so a job record cannot become a log sink or an oversized key.
pub const MAX_ID_CHARS: usize = 128;
pub const MAX_LANGUAGE_CHARS: usize = 16;

/// The payload version. A job written by a newer producer is refused, never guessed at.
pub const PAYLOAD_VERSION: u64 = 1;

/// The audio's declared type. It decides the file extension the worker's recognizer is handed, and
/// nothing else; an unknown type is not a guess.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mime {
    Ogg,
    Mp3,
    Wav,
    M4a,
}

impl Mime {
    pub fn as_str(self) -> &'static str {
        match self {
            Mime::Ogg => "audio/ogg",
            Mime::Mp3 => "audio/mpeg",
            Mime::Wav => "audio/wav",
            Mime::M4a => "audio/mp4",
        }
    }

    /// The extension the recognizer's temp file gets (`service_stt` maps the same way).
    pub fn ext(self) -> &'static str {
        match self {
            Mime::Ogg => "ogg",
            Mime::Mp3 => "mp3",
            Mime::Wav => "wav",
            Mime::M4a => "m4a",
        }
    }

    pub fn parse(text: &str) -> Option<Mime> {
        match text.split(';').next().unwrap_or("").trim() {
            "audio/ogg" | "audio/opus" => Some(Mime::Ogg),
            "audio/mpeg" | "audio/mp3" => Some(Mime::Mp3),
            "audio/wav" | "audio/x-wav" => Some(Mime::Wav),
            "audio/mp4" | "audio/aac" | "audio/m4a" => Some(Mime::M4a),
            _ => None,
        }
    }
}

/// A short-lived permission to fetch one job's audio from the producing node.
///
/// The handle is opaque and per job; the producer serves the bytes only while `expires_at_ms` has not
/// passed *and* the job is still fresh (`Producer::serve_audio`), so a worker that sat on a lease
/// cannot come back later for audio whose transcript would be posted too late.
#[derive(Clone, PartialEq, Eq)]
pub struct FetchHandle {
    pub handle: String,
    pub expires_at_ms: i64,
    pub bytes: u64,
    pub mime: Mime,
}

impl FetchHandle {
    pub fn new(handle: impl Into<String>, expires_at_ms: i64, bytes: u64, mime: Mime) -> FetchHandle {
        FetchHandle { handle: handle.into(), expires_at_ms, bytes, mime }
    }

    pub fn is_expired(&self, now_ms: i64) -> bool {
        now_ms >= self.expires_at_ms
    }
}

impl fmt::Debug for FetchHandle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        // The token itself is not a secret (it is bound to a job id and expires), but it is also not
        // worth printing: a log line about a job carries ids and timings only.
        write!(formatter, "FetchHandle {{ {} bytes, {}, expires_at_ms: {} }}", self.bytes, self.mime.as_str(), self.expires_at_ms)
    }
}

/// Where a job's audio is: in the payload, or behind a fetch handle in the producer's store.
#[derive(Clone, PartialEq, Eq)]
pub enum AudioSource {
    Inline(Vec<u8>, Mime),
    Fetch(FetchHandle),
}

impl AudioSource {
    pub fn mime(&self) -> Mime {
        match self {
            AudioSource::Inline(_, mime) => *mime,
            AudioSource::Fetch(handle) => handle.mime,
        }
    }

    /// The declared size, in bytes (the inline length, or what the producer wrote).
    pub fn bytes(&self) -> u64 {
        match self {
            AudioSource::Inline(bytes, _) => bytes.len() as u64,
            AudioSource::Fetch(handle) => handle.bytes,
        }
    }

    pub fn is_inline(&self) -> bool {
        matches!(self, AudioSource::Inline(..))
    }

    fn redacted(&self) -> String {
        match self {
            AudioSource::Inline(bytes, mime) => format!("inline({} bytes, {})", bytes.len(), mime.as_str()),
            AudioSource::Fetch(handle) => format!("fetch({handle:?})"),
        }
    }
}

impl fmt::Debug for AudioSource {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.redacted())
    }
}

/// One queued transcription request. Ids and timings only; the bytes live in `audio`.
#[derive(Clone, PartialEq, Eq)]
pub struct SttRequest {
    pub audio: AudioSource,
    /// The language snapshot taken when the note arrived (`pt`, `en`, `auto`); never re-detected
    /// here, and never translated.
    pub language: String,
    /// Unix ms. After this the job is worthless: a worker that reads it is told to drop it, and no
    /// result is posted late.
    pub fresh_until_ms: i64,
    pub chat: String,
    pub msg: String,
    /// The account the note belongs to, and its generation: together with `chat`/`msg` they are the
    /// dedupe key, so the same voice note cannot be transcribed twice across a restart.
    pub account: String,
    pub generation: u64,
    /// The sender-declared length in seconds (0/`None` = unknown). It routes work to a lane on the
    /// producing node; it is never trusted as a duration.
    pub declared_seconds: Option<u32>,
}

impl SttRequest {
    /// `{account}/{generation}/{chat}/{msg}` — the queue's dedupe key, the same tuple the connector
    /// used for `UNIQUE(account,generation,chat,id)` (`docs/QUEUE.md`, "WhatsApp transcription").
    pub fn dedupe_key(&self) -> String {
        format!("{}/{}/{}/{}", self.account, self.generation, self.chat, self.msg)
    }

    /// Is this job still worth running at `now_ms`? The queue answers the same question for a job it
    /// hands out; this is the worker's own belt for a job that went stale while it was downloading.
    pub fn is_fresh(&self, now_ms: i64) -> bool {
        now_ms < self.fresh_until_ms
    }

    /// The queue payload.
    pub fn encode(&self) -> Vec<u8> {
        let audio = match &self.audio {
            AudioSource::Inline(bytes, mime) => json!({
                "inline": {"mime": mime.as_str(), "b64": base64::encode(bytes)},
            }),
            AudioSource::Fetch(handle) => json!({
                "fetch": {
                    "handle": handle.handle,
                    "expires_at_ms": handle.expires_at_ms,
                    "bytes": handle.bytes,
                    "mime": handle.mime.as_str(),
                },
            }),
        };
        let mut object = Map::new();
        object.insert("v".into(), json!(PAYLOAD_VERSION));
        object.insert("audio".into(), audio);
        object.insert("language".into(), json!(self.language));
        object.insert("fresh_until_ms".into(), json!(self.fresh_until_ms));
        object.insert("chat".into(), json!(self.chat));
        object.insert("msg".into(), json!(self.msg));
        object.insert("account".into(), json!(self.account));
        object.insert("generation".into(), json!(self.generation));
        if let Some(seconds) = self.declared_seconds {
            object.insert("declared_seconds".into(), json!(seconds));
        }
        Value::Object(object).to_string().into_bytes()
    }

    /// Read a payload. Every refusal names the field, never its value.
    pub fn decode(payload: &[u8]) -> Result<SttRequest, RequestError> {
        let text = std::str::from_utf8(payload).map_err(|_| RequestError::Malformed("not_utf8"))?;
        let value: Value = serde_json::from_str(text).map_err(|_| RequestError::Malformed("not_json"))?;
        let object = value.as_object().ok_or(RequestError::Malformed("not_an_object"))?;
        strict_keys(object, &["v", "audio", "language", "fresh_until_ms", "chat", "msg", "account", "generation", "declared_seconds"])?;
        let version = number(object, "v")?.as_u64().ok_or(RequestError::Field("v"))?;
        if version != PAYLOAD_VERSION {
            return Err(RequestError::UnsupportedVersion(version));
        }
        let audio_object = object.get("audio").and_then(Value::as_object).ok_or(RequestError::Field("audio"))?;
        strict_keys(audio_object, &["inline", "fetch"])?;
        let audio = match (audio_object.get("inline"), audio_object.get("fetch")) {
            (Some(inline), None) => {
                let inline = inline.as_object().ok_or(RequestError::Field("audio.inline"))?;
                strict_keys(inline, &["mime", "b64"])?;
                let mime = text_field(inline, "mime").and_then(Mime::parse).ok_or(RequestError::Field("audio.mime"))?;
                let encoded = text_field(inline, "b64").ok_or(RequestError::Field("audio.b64"))?;
                // Decode against the cap before allocating the real buffer: the encoded length
                // bounds the decoded one.
                if encoded.len() / 4 * 3 > INLINE_MAX_BYTES + 3 {
                    return Err(RequestError::TooLarge("audio.inline"));
                }
                let bytes = base64::decode(encoded).map_err(|_| RequestError::Malformed("audio.b64"))?;
                if bytes.len() > INLINE_MAX_BYTES {
                    return Err(RequestError::TooLarge("audio.inline"));
                }
                if bytes.is_empty() {
                    return Err(RequestError::Field("audio.inline"));
                }
                AudioSource::Inline(bytes, mime)
            }
            (None, Some(fetch)) => {
                let fetch = fetch.as_object().ok_or(RequestError::Field("audio.fetch"))?;
                strict_keys(fetch, &["handle", "expires_at_ms", "bytes", "mime"])?;
                let handle = text_field(fetch, "handle").ok_or(RequestError::Field("audio.handle"))?;
                if handle.is_empty() || handle.chars().count() > MAX_ID_CHARS {
                    return Err(RequestError::Field("audio.handle"));
                }
                let expires_at_ms = number(fetch, "expires_at_ms")?.as_i64().ok_or(RequestError::Field("audio.expires_at_ms"))?;
                let bytes = number(fetch, "bytes")?.as_u64().ok_or(RequestError::Field("audio.bytes"))?;
                if bytes == 0 || bytes > MAX_AUDIO_BYTES as u64 {
                    return Err(RequestError::TooLarge("audio.bytes"));
                }
                let mime = text_field(fetch, "mime").and_then(Mime::parse).ok_or(RequestError::Field("audio.mime"))?;
                AudioSource::Fetch(FetchHandle::new(handle, expires_at_ms, bytes, mime))
            }
            _ => return Err(RequestError::Field("audio")),
        };
        let language = text_field(object, "language").ok_or(RequestError::Field("language"))?;
        if language.is_empty() || language.chars().count() > MAX_LANGUAGE_CHARS {
            return Err(RequestError::Field("language"));
        }
        let fresh_until_ms = number(object, "fresh_until_ms")?.as_i64().ok_or(RequestError::Field("fresh_until_ms"))?;
        let chat = id_field(object, "chat")?;
        let msg = id_field(object, "msg")?;
        let account = id_field(object, "account")?;
        let generation = number(object, "generation")?.as_u64().ok_or(RequestError::Field("generation"))?;
        let declared_seconds = match object.get("declared_seconds") {
            None | Some(Value::Null) => None,
            Some(value) => Some(value.as_u64().filter(|s| *s <= 24 * 3600).ok_or(RequestError::Field("declared_seconds"))? as u32),
        };
        Ok(SttRequest { audio, language: language.to_string(), fresh_until_ms, chat, msg, account, generation, declared_seconds })
    }
}

impl fmt::Debug for SttRequest {
    /// Redacted on purpose: the audio bytes never reach a log line, and neither does anything that
    /// was said in them. A field name that a reader would want (`language`, ids, freshness) is kept.
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "SttRequest {{ account: {:?}, generation: {}, chat: {:?}, msg: {:?}, language: {:?}, fresh_until_ms: {}, declared_seconds: {:?}, audio: {} }}",
            self.account,
            self.generation,
            self.chat,
            self.msg,
            self.language,
            self.fresh_until_ms,
            self.declared_seconds,
            self.audio.redacted()
        )
    }
}

/// Why a payload was refused. Never carries bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RequestError {
    /// Not JSON, not an object, or a value that is not what the field says it is.
    Malformed(&'static str),
    /// A named field is missing, empty or out of bounds.
    Field(&'static str),
    /// A field or the audio exceeds its bound.
    TooLarge(&'static str),
    /// Written by a producer this decoder does not know.
    UnsupportedVersion(u64),
}

impl RequestError {
    /// One word for a metric or a refusal reply; no field values, no bytes.
    pub fn reason(&self) -> String {
        match self {
            RequestError::Malformed(what) => format!("malformed:{what}"),
            RequestError::Field(name) => format!("invalid:{name}"),
            RequestError::TooLarge(name) => format!("too-large:{name}"),
            RequestError::UnsupportedVersion(version) => format!("version:{version}"),
        }
    }
}

impl fmt::Display for RequestError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.reason())
    }
}

impl std::error::Error for RequestError {}

fn strict_keys(object: &Map<String, Value>, allowed: &[&str]) -> Result<(), RequestError> {
    for key in object.keys() {
        if !allowed.iter().any(|name| name == key) {
            // The name of the offending key is a field name, never a value: `text` is refused here.
            return Err(RequestError::Malformed("unknown_field"));
        }
    }
    Ok(())
}

fn number(object: &Map<String, Value>, key: &str) -> Result<Value, RequestError> {
    object.get(key).filter(|value| value.is_number()).cloned().ok_or(RequestError::Field(match key {
        "v" => "v",
        "fresh_until_ms" => "fresh_until_ms",
        "generation" => "generation",
        _ => "field",
    }))
}

fn text_field<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key)?.as_str()
}

fn id_field(object: &Map<String, Value>, key: &str) -> Result<String, RequestError> {
    let value = text_field(object, key).ok_or(RequestError::Field(match key {
        "chat" => "chat",
        "msg" => "msg",
        _ => "account",
    }))?;
    if value.is_empty() || value.chars().count() > MAX_ID_CHARS {
        return Err(RequestError::Field(match key {
            "chat" => "chat",
            "msg" => "msg",
            _ => "account",
        }));
    }
    Ok(value.to_string())
}

/// Standard base64, for a transport that carries bytes in JSON (the `audio` op). The payload's own
/// encoder is below; these two are the same functions, published for the sim and a host transport.
pub fn base64_encode(bytes: &[u8]) -> String {
    base64::encode(bytes)
}

pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    base64::decode(text).ok()
}

/// Standard base64 (RFC 4648, padded). Hand-rolled rather than a dependency: the payload needs one
/// alphabetic encoding of a byte string, and a 40-line function with tests is smaller than the crate
/// it would replace.
mod base64 {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    pub fn encode(bytes: &[u8]) -> String {
        let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
        for chunk in bytes.chunks(3) {
            let b0 = chunk[0] as u32;
            let b1 = *chunk.get(1).unwrap_or(&0) as u32;
            let b2 = *chunk.get(2).unwrap_or(&0) as u32;
            let triple = (b0 << 16) | (b1 << 8) | b2;
            out.push(ALPHABET[(triple >> 18) as usize & 0x3f] as char);
            out.push(ALPHABET[(triple >> 12) as usize & 0x3f] as char);
            out.push(if chunk.len() > 1 { ALPHABET[(triple >> 6) as usize & 0x3f] as char } else { '=' });
            out.push(if chunk.len() > 2 { ALPHABET[triple as usize & 0x3f] as char } else { '=' });
        }
        out
    }

    pub fn decode(text: &str) -> Result<Vec<u8>, ()> {
        let mut out = Vec::with_capacity(text.len() / 4 * 3);
        let mut accumulator: u32 = 0;
        let mut bits: u32 = 0;
        let mut symbols = 0usize;
        let mut padding = 0usize;
        for &byte in text.as_bytes() {
            if byte.is_ascii_whitespace() {
                continue;
            }
            if byte == b'=' {
                padding += 1;
                if padding > 2 {
                    return Err(());
                }
                continue;
            }
            if padding > 0 {
                return Err(()); // data after padding
            }
            accumulator = (accumulator << 6) | position(byte)? as u32;
            bits += 6;
            symbols += 1;
            if bits >= 8 {
                bits -= 8;
                out.push((accumulator >> bits) as u8);
                accumulator &= (1 << bits) - 1;
            }
        }
        // A padded block is four symbols including its padding, and one leftover symbol can never
        // carry a byte; leftover bits that are not zero mean the input was not base64 of a byte
        // string at all.
        if padding > 0 && !(symbols + padding).is_multiple_of(4) {
            return Err(());
        }
        if symbols % 4 == 1 {
            return Err(());
        }
        if accumulator != 0 {
            return Err(());
        }
        Ok(out)
    }

    fn position(byte: u8) -> Result<u8, ()> {
        match byte {
            b'A'..=b'Z' => Ok(byte - b'A'),
            b'a'..=b'z' => Ok(byte - b'a' + 26),
            b'0'..=b'9' => Ok(byte - b'0' + 52),
            b'+' => Ok(62),
            b'/' => Ok(63),
            _ => Err(()),
        }
    }
}
