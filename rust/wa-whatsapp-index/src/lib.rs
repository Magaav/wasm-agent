//! The WhatsApp message index's seam: one query somebody asked for, and the answer it came back with.
//!
//! Every message the linked device receives is recorded by the `wa-whatsapp` component in its own kv
//! namespace (record, secondary keys, token index), and a query is a **job** on the shared durable
//! queue (`wa:queue`, queue name [`QUEUE`]) - the same architecture the explicit send already uses
//! (`rust/wa-whatsapp-outbox`): not a side channel, not a host call into somebody else's state.
//!
//! ```text
//! tool whatsapp_search {q, chat?, kind?, from?, since?, until?, limit}
//!   -> validate the request here, enqueue `whatsapp.query` (dedupe = the request itself)
//! component wa-whatsapp (granted queue worker on `whatsapp.query`)
//!   -> read the index in its own kv, settle done(answer) | fail(reason)
//! tool answer <- the job's result (bounded, text-carrying, never logged)
//! ```
//!
//! This crate is the part both ends must agree on, and it is deliberately small:
//!
//! * [`Request`] - the five operations the agent may ask for ([`Op`]), the bounds on each argument,
//!   and the dedupe key: a repeated identical query is *the same job*, so a caller that retried
//!   after a timeout reads the answer the first call already produced.
//! * [`refusal`]/[`answer`] - the shape of both answers, so a tool answer and a documented answer
//!   cannot drift.
//! * [`bound`] - the result is carried in a queue job, and a job's result has a hard size (`wa:queue`
//!   refuses more than 64 KiB rather than truncating it). Trailing items are dropped *here*, visibly
//!   (`truncated: true`), so a big answer is a smaller answer and never a failed one.
//! * [`Download`] - the manifest a `whatsapp_download` job settles with. The decrypted bytes travel
//!   as the job's progress chunks (the queue's bounded byte stream), never in the result: a video
//!   must not become a kv record.
//!
//! Nothing here logs and nothing here reads a message: the answer carries text because a search
//! result is text, and the component's log carries ids, kinds and counts.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use wa_whatsapp_outbox::Chat;

/// The queue every query travels on (`docs/SERVICE-COMPONENTS.md`).
pub const QUEUE: &str = "whatsapp.query";

/// A query nobody picked up within this window is answered "too old" instead of answered late: the
/// index is a snapshot, and an answer produced ten minutes after the question is a different answer.
pub const FRESH_MS: i64 = 120_000;

/// Attempts before a retryable query failure is final. A read of a local store either works or is
/// broken; two attempts cover a restarting component.
pub const MAX_ATTEMPTS: u32 = 2;

/// How long the node waits for the component to settle before answering "still running, here is the
/// job id". Bounded because the caller is a Lua tool call on the node's own thread: a search is a
/// local scan, and a node that blocks longer than this to answer "what did they say" is a node that
/// stopped serving everything else.
pub const WAIT_MS: u64 = 2_000;

/// Largest media one `whatsapp_download` may hand back. The bytes ride the job's progress stream,
/// which `wa:queue` bounds at 1 MiB of chunks; 512 KiB of plaintext stays inside that with room for
/// the manifest, and a photo, a voice note or a one-page document fits. A video does not: the answer
/// says `download_too_large` with the size instead of pretending.
pub const MAX_DOWNLOAD_BYTES: u64 = 512 * 1024;

/// Largest answer the component will settle with. `wa:queue`'s own cap is 64 KiB; the margin is the
/// job record around the result.
pub const MAX_RESULT_BYTES: usize = 56 * 1024;

/// Longest text a hit or a message carries in an answer. The full text stays in the index; an answer
/// is a pointer to it (`chat` + `id`), not a transcript dump.
pub const MAX_TEXT_CHARS: usize = 280;

/// Most mentions, reactions or poll options one answer lists.
pub const MAX_LISTED: usize = 16;

pub const SEARCH_DEFAULT: u32 = 20;
pub const SEARCH_MAX: u32 = 50;
pub const READ_DEFAULT: u32 = 30;
pub const READ_MAX: u32 = 100;

const MAX_Q_CHARS: usize = 200;
const MAX_ID_CHARS: usize = 128;

/// The kinds the index distinguishes. `voice` is a push-to-talk audio (`audio` is a music file);
/// `edit` and `delete` are the events a source mutation produces, indexed as events.
pub const KINDS: [&str; 14] = [
    "text",
    "image",
    "video",
    "audio",
    "voice",
    "document",
    "sticker",
    "location",
    "contact",
    "poll",
    "reaction",
    "edit",
    "delete",
    "other",
];

/// The five questions the agent may ask about the index.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    /// `whatsapp_search {q, chat?, kind?, from?, since?, until?, limit}` - full-text over records.
    Search,
    /// `whatsapp_read {chat, before?, limit}` - one thread, newest first, reactions folded on.
    Read,
    /// `whatsapp_reactions {chat, id}` - who reacted to one message, with which emoji.
    Reactions,
    /// `whatsapp_media {chat, id}` - the metadata of one message's media, never the bytes.
    Media,
    /// `whatsapp_download {chat, id}` - decrypt the media to a bounded host directory.
    Download,
}

impl Op {
    pub fn as_str(self) -> &'static str {
        match self {
            Op::Search => "search",
            Op::Read => "read",
            Op::Reactions => "reactions",
            Op::Media => "media",
            Op::Download => "download",
        }
    }

    pub fn parse(text: &str) -> Option<Op> {
        match text {
            "search" => Some(Op::Search),
            "read" => Some(Op::Read),
            "reactions" => Some(Op::Reactions),
            "media" => Some(Op::Media),
            "download" => Some(Op::Download),
            _ => None,
        }
    }

    /// The tool that asks this question: the name in the catalogue, in the refusal and in the log.
    pub fn tool(self) -> &'static str {
        match self {
            Op::Search => "whatsapp_search",
            Op::Read => "whatsapp_read",
            Op::Reactions => "whatsapp_reactions",
            Op::Media => "whatsapp_media",
            Op::Download => "whatsapp_download",
        }
    }

    pub fn parse_tool(name: &str) -> Option<Op> {
        match name {
            "whatsapp_search" => Some(Op::Search),
            "whatsapp_read" => Some(Op::Read),
            "whatsapp_reactions" => Some(Op::Reactions),
            "whatsapp_media" => Some(Op::Media),
            "whatsapp_download" => Some(Op::Download),
            _ => None,
        }
    }
}

/// One refusal: a stable `code` (the tool answer is `whatsapp_<op>_<code>`) and one bounded line of
/// detail that never carries message text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub detail: String,
}

impl Refusal {
    pub fn new(code: &'static str, detail: impl Into<String>) -> Refusal {
        Refusal { code, detail: detail.into().chars().take(160).collect() }
    }

    /// The stable error word for `op`: what the tool answer, the log line and the test all name.
    pub fn error(&self, op: Op) -> String {
        format!("{}_{}", op.tool(), self.code)
    }
}

/// One query as it travels in the job payload.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Request {
    pub op: String,
    pub q: Option<String>,
    pub chat: Option<String>,
    pub id: Option<String>,
    pub kind: Option<String>,
    pub from: Option<String>,
    /// Unix milliseconds (a seconds epoch is accepted and converted: a model writing `1760000000`
    /// means the same instant as `1760000000000`).
    pub since: Option<i64>,
    pub until: Option<i64>,
    /// A message id or an epoch; `read` returns what is *older* than it.
    pub before: Option<String>,
    pub limit: Option<u32>,
    /// `download` only: how many plaintext bytes the caller will accept.
    pub max_bytes: Option<u64>,
}

/// A request that passed every check, with the bounds already applied.
#[derive(Clone, Debug, PartialEq)]
pub struct Verified {
    pub op: Op,
    pub q: Option<String>,
    pub chat: Option<Chat>,
    pub id: Option<String>,
    pub kind: Option<String>,
    pub from: Option<Chat>,
    pub since: Option<i64>,
    pub until: Option<i64>,
    pub before: Option<String>,
    pub limit: u32,
    pub max_bytes: u64,
}

impl Request {
    /// Check every argument. The first refusal wins; a query is all-or-nothing.
    pub fn validate(&self) -> Result<Verified, Refusal> {
        let op = Op::parse(self.op.trim())
            .ok_or_else(|| Refusal::new("bad_op", "op must be search, read, reactions, media or download"))?;
        let chat = match self.chat.as_deref().map(str::trim) {
            None | Some("") => None,
            Some(text) => Some(parse_chat(text)?),
        };
        let from = match self.from.as_deref().map(str::trim) {
            None | Some("") => None,
            Some(text) => Some(parse_chat(text)?),
        };
        let id = match self.id.as_deref().map(str::trim) {
            None | Some("") => None,
            Some(text) => {
                if text.chars().count() > MAX_ID_CHARS {
                    return Err(Refusal::new("bad_id", "id is longer than 128 characters"));
                }
                if text.chars().any(|c| c.is_control() || c.is_whitespace()) {
                    return Err(Refusal::new("bad_id", "id contains whitespace or a control character"));
                }
                Some(text.to_string())
            }
        };
        let before = match self.before.as_deref().map(str::trim) {
            None | Some("") => None,
            Some(text) => {
                if text.chars().count() > MAX_ID_CHARS || text.chars().any(|c| c.is_control() || c.is_whitespace()) {
                    return Err(Refusal::new("bad_before", "before is not a message id or an epoch"));
                }
                Some(text.to_string())
            }
        };
        let kind = match self.kind.as_deref().map(str::trim) {
            None | Some("") => None,
            Some(text) => {
                let kind = text.to_ascii_lowercase();
                if !KINDS.contains(&kind.as_str()) {
                    return Err(Refusal::new("bad_kind", format!("kind must be one of {}", KINDS.join(", "))));
                }
                Some(kind)
            }
        };
        let q = match self.q.as_deref().map(str::trim) {
            None | Some("") => None,
            Some(text) => {
                if text.chars().count() > MAX_Q_CHARS {
                    return Err(Refusal::new("bad_query", "q is longer than 200 characters"));
                }
                if text.chars().any(char::is_control) {
                    return Err(Refusal::new("bad_query", "q contains a control character"));
                }
                Some(text.to_string())
            }
        };
        let since = self.since.map(epoch_ms);
        let until = self.until.map(epoch_ms);
        if let (Some(since), Some(until)) = (since, until) {
            if since > until {
                return Err(Refusal::new("bad_window", "since is later than until"));
            }
        }
        let (limit, max_bytes) = match op {
            Op::Search => {
                let limit = clamp_limit(self.limit, SEARCH_DEFAULT, SEARCH_MAX);
                // A search needs at least one narrowing: an unfiltered dump of the whole index is not
                // a search, and it would be answered with the newest 20 messages and a lie.
                if q.is_none() && chat.is_none() && from.is_none() && kind.is_none() {
                    return Err(Refusal::new("empty_query", "a search needs q, chat, kind or from"));
                }
                (limit, 0)
            }
            Op::Read => {
                if chat.is_none() {
                    return Err(Refusal::new("chat_required", "read needs the exact chat JID"));
                }
                (clamp_limit(self.limit, READ_DEFAULT, READ_MAX), 0)
            }
            Op::Reactions | Op::Media | Op::Download => {
                if chat.is_none() || id.is_none() {
                    return Err(Refusal::new("chat_and_id_required", "one message: pass chat and id"));
                }
                let bytes = self.max_bytes.unwrap_or(MAX_DOWNLOAD_BYTES).clamp(1, MAX_DOWNLOAD_BYTES);
                (1, bytes)
            }
        };
        Ok(Verified { op, q, chat, id, kind, from, since, until, before, limit, max_bytes })
    }

    /// The payload bytes for the queue.
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    /// Read a payload back. A payload this crate did not write is `malformed`, never guessed at.
    pub fn decode(bytes: &[u8]) -> Result<Request, Refusal> {
        serde_json::from_slice(bytes)
            .map_err(|_| Refusal::new("malformed_job", "the job payload is not a whatsapp query"))
    }

    /// The producer's idempotency key: the validated request itself, hex sha256. Two identical
    /// searches are one job, so a caller that asks again after a slow answer reads that answer
    /// instead of queueing the same scan twice.
    pub fn dedupe_key(&self) -> String {
        match self.validate() {
            Ok(verified) => verified.dedupe_key(),
            // A request that does not validate still gets a stable key, so a repeated bad call does
            // not pile up jobs either.
            Err(_) => hex(&Sha256::digest(self.encode())),
        }
    }
}

impl Verified {
    /// The dedupe material, in a fixed order so the same query always hashes the same.
    pub fn dedupe_key(&self) -> String {
        let material = format!(
            "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}",
            self.op.as_str(),
            self.q.as_deref().unwrap_or(""),
            self.chat.as_ref().map(|chat| chat.jid()).unwrap_or_default(),
            self.id.as_deref().unwrap_or(""),
            self.kind.as_deref().unwrap_or(""),
            self.from.as_ref().map(|chat| chat.jid()).unwrap_or_default(),
            self.since.map(|ms| ms.to_string()).unwrap_or_default(),
            self.until.map(|ms| ms.to_string()).unwrap_or_default(),
            self.before.as_deref().unwrap_or(""),
            self.limit,
            self.max_bytes,
        );
        hex(&Sha256::digest(material.as_bytes()))
    }

    /// The request as the component reads it back out of the job payload. The verified form is the
    /// only one the worker acts on: `decide` in the component validates the payload it took.
    pub fn to_request(&self) -> Request {
        Request {
            op: self.op.as_str().to_string(),
            q: self.q.clone(),
            chat: self.chat.as_ref().map(|chat| chat.jid()),
            id: self.id.clone(),
            kind: self.kind.clone(),
            from: self.from.as_ref().map(|chat| chat.jid()),
            since: self.since,
            until: self.until,
            before: self.before.clone(),
            limit: Some(self.limit),
            max_bytes: Some(self.max_bytes),
        }
    }
}

/// The exact-JID rule, with the outbox's refusal turned into this crate's: one code, one shape.
fn parse_chat(text: &str) -> Result<Chat, Refusal> {
    Chat::parse(text).map_err(|refusal| Refusal::new(refusal.code, refusal.detail))
}

/// One epoch as milliseconds: seconds (any value a human would type for a date) are scaled.
fn epoch_ms(value: i64) -> i64 {
    if value.abs() < 100_000_000_000 {
        value.saturating_mul(1000)
    } else {
        value
    }
}

fn clamp_limit(limit: Option<u32>, default: u32, max: u32) -> u32 {
    match limit {
        None | Some(0) => default,
        Some(value) => value.min(max),
    }
}

/// The settled answer of one `whatsapp_download`: what the bytes are and how to collect them.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Download {
    pub chat: String,
    pub id: String,
    pub kind: String,
    pub mime: String,
    pub filename: String,
    pub sha256: String,
    pub bytes: u64,
    /// How many progress chunks the job carries, in order, starting at sequence 0.
    pub chunks: u32,
}

impl Download {
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    pub fn decode(bytes: &[u8]) -> Option<Download> {
        serde_json::from_slice(bytes).ok()
    }
}

/// The answer of a query that succeeded: `op` says which question it answers, and the body is the
/// answer itself (`hits`, `messages`, `reactions` or `media`).
pub fn answer(op: Op, body: serde_json::Value) -> serde_json::Value {
    let mut answer = match body {
        serde_json::Value::Object(map) => serde_json::Value::Object(map),
        other => serde_json::json!({"value": other}),
    };
    answer["ok"] = serde_json::Value::Bool(true);
    answer["op"] = serde_json::Value::String(op.as_str().to_string());
    bound(answer)
}

/// The answer of a query that was refused or failed: a word, one line of detail, no text, and never
/// an `ok` a caller could read as success.
pub fn refusal(op: Op, code: &str, detail: impl AsRef<str>) -> serde_json::Value {
    serde_json::json!({
        "ok": false,
        "op": op.as_str(),
        "error": format!("{}_{code}", op.tool()),
        "detail": detail.as_ref().chars().take(160).collect::<String>(),
        "effect": "none",
    })
}

/// The answer when the component has not settled inside [`WAIT_MS`]: the job id, so the caller can
/// ask again (the dedupe key makes that a read of the same job, not a second scan).
pub fn slow(op: Op, id: u64, state: &str) -> serde_json::Value {
    serde_json::json!({
        "ok": false,
        "op": op.as_str(),
        "error": format!("{}_slow", op.tool()),
        "id": id,
        "state": state_word(state),
        "retry": true,
        "detail": "the wa-whatsapp component has not answered yet; the same call reads the same job",
        "effect": "none",
    })
}

/// The first progress entry of a `whatsapp_download` attempt: a magic word and the job id.
///
/// `wa:queue` progress is append-only, so a retried download appends a *second* set of chunks after the
/// first attempt's. The header is what makes them distinguishable: the reader finds the last header for
/// the job and takes the chunks that follow it, instead of concatenating two half-files.
pub const DOWNLOAD_MAGIC: &[u8; 8] = b"WA-DL1\0\0";

/// The header a download attempt writes before its first chunk.
pub fn download_header(job: u64) -> Vec<u8> {
    let mut header = Vec::with_capacity(DOWNLOAD_MAGIC.len() + 8);
    header.extend_from_slice(DOWNLOAD_MAGIC);
    header.extend_from_slice(&job.to_le_bytes());
    header
}

/// The job a progress chunk is a header for, or `none` when it is payload.
pub fn download_header_job(chunk: &[u8]) -> Option<u64> {
    if chunk.len() != DOWNLOAD_MAGIC.len() + 8 || !chunk.starts_with(DOWNLOAD_MAGIC) {
        return None;
    }
    let mut id = [0u8; 8];
    id.copy_from_slice(&chunk[DOWNLOAD_MAGIC.len()..]);
    Some(u64::from_le_bytes(id))
}

/// Is this failure worth another attempt? A refusal the caller can act on (no such message, no media,
/// view-once, too large, a malformed payload) is permanent; a disconnected client and a transport
/// error are not. The queue decides *how many* attempts a retryable failure gets; this says whether
/// retrying can possibly help.
pub fn retryable(reason: &str) -> bool {
    const PERMANENT: [&str; 14] = [
        "bad_op",
        "bad_chat",
        "bad_id",
        "bad_before",
        "bad_kind",
        "bad_query",
        "bad_window",
        "empty_query",
        "chat_required",
        "chat_and_id_required",
        "malformed_job",
        "deleted",
        "no_media",
        "not_downloadable",
    ];
    if reason.starts_with("not_indexed") || reason.starts_with("download_too_large") || reason == "stale" {
        return false;
    }
    !PERMANENT.iter().any(|code| reason == *code || reason.starts_with(&format!("{code}:")))
}

/// The queue's own word for a state: `ready` is what a caller asked for and understands ("queued").
pub fn state_word(queue_state: &str) -> &str {
    match queue_state {
        "ready" => "queued",
        other => other,
    }
}

/// Drop trailing items until the answer fits the queue's result bound, and say so.
///
/// `wa:queue` refuses an oversized result (`too-large`) instead of truncating it, and a query that
/// fails because it found too much is a worse answer than a shorter list. The lists keep the answer's
/// own order (best hit first, newest message first), so what is dropped is the tail - and `count`
/// becomes the number of items the answer actually carries, because a count that disagrees with the
/// list is a lie a model will act on.
pub fn bound(answer: serde_json::Value) -> serde_json::Value {
    let fits = |value: &serde_json::Value| serialized_len(value) <= MAX_RESULT_BYTES;
    if fits(&answer) {
        return answer;
    }
    // What the answer costs before it carries a single item: the fixed fields, an empty list, and the
    // truncation marker it is about to earn.
    let mut answer = answer;
    let mut skeleton = answer.clone();
    if let Some(object) = skeleton.as_object_mut() {
        for key in ["hits", "messages", "reactions"] {
            if object.contains_key(key) {
                object.insert(key.to_string(), serde_json::Value::Array(Vec::new()));
                object.insert("count".to_string(), serde_json::Value::from(0));
            }
        }
        object.insert("truncated".to_string(), serde_json::Value::Bool(true));
    }
    let base = serialized_len(&skeleton);
    if base >= MAX_RESULT_BYTES {
        // The fixed fields alone are over the bound. Say it, rather than let the queue refuse the
        // settle and leave the job to be retried into the same wall.
        return serde_json::json!({
            "ok": false,
            "op": answer.get("op").cloned().unwrap_or(serde_json::Value::Null),
            "error": "whatsapp_query_too_large",
            "detail": "the answer does not fit one queue result even after truncation",
            "effect": "none",
        });
    }
    let mut remaining = MAX_RESULT_BYTES - base;
    let mut truncated = false;
    for key in ["hits", "messages", "reactions"] {
        let Some(items) = answer.get(key).and_then(serde_json::Value::as_array).cloned() else { continue };
        let wanted = items.len();
        let mut kept = 0;
        let mut cost = 0;
        for item in &items {
            // One comma (or the brackets) per item is already in the skeleton's margin.
            let size = serialized_len(item) + 1;
            if size > remaining.saturating_sub(cost) {
                break;
            }
            cost += size;
            kept += 1;
        }
        remaining -= cost;
        if kept < wanted {
            truncated = true;
            if let Some(object) = answer.as_object_mut() {
                object.insert(key.to_string(), serde_json::Value::Array(items[..kept].to_vec()));
                object.insert("count".to_string(), serde_json::Value::from(kept));
            }
        }
    }
    if truncated {
        if let Some(object) = answer.as_object_mut() {
            object.insert("truncated".to_string(), serde_json::Value::Bool(true));
        }
    }
    // The estimate keeps a margin of one item per list; if it was still not enough, say so instead of
    // handing the queue a result it will refuse.
    if !fits(&answer) {
        return serde_json::json!({
            "ok": false,
            "op": answer.get("op").cloned().unwrap_or(serde_json::Value::Null),
            "error": "whatsapp_query_too_large",
            "detail": "the answer does not fit one queue result even after truncation",
            "effect": "none",
        });
    }
    answer
}

fn serialized_len(value: &serde_json::Value) -> usize {
    serde_json::to_vec(value).map(|bytes| bytes.len()).unwrap_or(usize::MAX)
}

fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(op: &str) -> Request {
        Request { op: op.into(), ..Request::default() }
    }

    #[test]
    fn every_operation_validates_its_own_required_arguments() {
        let search = Request { q: Some("boleto".into()), ..request("search") };
        let verified = search.validate().unwrap();
        assert_eq!((verified.op, verified.limit), (Op::Search, SEARCH_DEFAULT));

        let read = Request { chat: Some("5511999999999@lid".into()), ..request("read") };
        assert_eq!(read.validate().unwrap().limit, READ_DEFAULT);

        for op in ["reactions", "media", "download"] {
            let missing = Request { chat: Some("5511999999999@lid".into()), ..request(op) };
            assert_eq!(missing.validate().unwrap_err().code, "chat_and_id_required", "{op}");
            let both = Request {
                chat: Some("5511999999999@lid".into()),
                id: Some("3EB0ABCDEF".into()),
                ..request(op)
            };
            let verified = both.validate().unwrap();
            assert_eq!(verified.max_bytes, MAX_DOWNLOAD_BYTES, "{op}");
        }
        assert_eq!(request("").validate().unwrap_err().code, "bad_op");
        assert_eq!(request("delete).drop table").validate().unwrap_err().code, "bad_op");
    }

    #[test]
    fn a_search_must_narrow_something() {
        assert_eq!(request("search").validate().unwrap_err().code, "empty_query");
        // Any one of the four narrowings is enough, and whitespace alone is not one.
        for request_with in [
            Request { q: Some("oi".into()), ..request("search") },
            Request { chat: Some("120363000000000001@g.us".into()), ..request("search") },
            Request { kind: Some("document".into()), ..request("search") },
            Request { from: Some("5511888888888@s.whatsapp.net".into()), ..request("search") },
        ] {
            assert!(request_with.validate().is_ok(), "{request_with:?}");
        }
        assert_eq!(
            Request { q: Some("   ".into()), ..request("search") }.validate().unwrap_err().code,
            "empty_query"
        );
    }

    #[test]
    fn chats_ids_kinds_and_windows_are_bounded_with_stable_codes() {
        let bad_chat = Request { chat: Some("5511999999999".into()), ..request("read") };
        assert_eq!(bad_chat.validate().unwrap_err().code, "bad_chat");
        let bad_id = Request {
            chat: Some("5511999999999@lid".into()),
            id: Some("3EB0 ABC".into()),
            ..request("media")
        };
        assert_eq!(bad_id.validate().unwrap_err().code, "bad_id");
        let bad_kind = Request { kind: Some("gif".into()), ..request("search") };
        assert_eq!(bad_kind.validate().unwrap_err().code, "bad_kind");
        // Every kind the index can store is a kind a search may name.
        for kind in KINDS {
            let narrowed = Request { kind: Some(kind.to_string()), ..request("search") };
            assert!(narrowed.validate().is_ok(), "{kind}");
        }
        let backwards = Request {
            q: Some("a".into()),
            since: Some(1_760_000_000_000),
            until: Some(1_700_000_000),
            ..request("search")
        };
        assert_eq!(backwards.validate().unwrap_err().code, "bad_window");
        let long = Request { q: Some("a".repeat(MAX_Q_CHARS + 1)), ..request("search") };
        assert_eq!(long.validate().unwrap_err().code, "bad_query");
    }

    #[test]
    fn a_seconds_epoch_and_a_milliseconds_epoch_are_the_same_instant() {
        let seconds = Request { q: Some("a".into()), since: Some(1_760_000_000), ..request("search") };
        let millis = Request { q: Some("a".into()), since: Some(1_760_000_000_000), ..request("search") };
        assert_eq!(
            seconds.validate().unwrap().since,
            millis.validate().unwrap().since,
            "a model writing seconds means the same instant"
        );
        // A pre-1970 epoch is scaled the same way: seconds are seconds, whichever side of 1970.
        let old = Request { q: Some("a".into()), since: Some(-86_400), ..request("search") };
        assert_eq!(old.validate().unwrap().since, Some(-86_400_000));
        // A millisecond epoch that is already unambiguous is left exactly as it is.
        let old_ms = Request { q: Some("a".into()), since: Some(-200_000_000_000), ..request("search") };
        assert_eq!(old_ms.validate().unwrap().since, Some(-200_000_000_000));
    }

    #[test]
    fn limits_are_clamped_and_the_effective_value_travels() {
        let huge = Request { q: Some("a".into()), limit: Some(5_000), ..request("search") };
        assert_eq!(huge.validate().unwrap().limit, SEARCH_MAX);
        let huge_read = Request { chat: Some("5511999999999@lid".into()), limit: Some(5_000), ..request("read") };
        assert_eq!(huge_read.validate().unwrap().limit, READ_MAX);
        let zero = Request { q: Some("a".into()), limit: Some(0), ..request("search") };
        assert_eq!(zero.validate().unwrap().limit, SEARCH_DEFAULT);
        let download = Request {
            chat: Some("5511999999999@lid".into()),
            id: Some("3EB0ABCDEF".into()),
            max_bytes: Some(64 * 1024 * 1024),
            ..request("download")
        };
        assert_eq!(download.validate().unwrap().max_bytes, MAX_DOWNLOAD_BYTES, "a video is not one kv record");
    }

    #[test]
    fn the_dedupe_key_is_the_query_itself() {
        let one = Request { q: Some("boleto".into()), chat: Some("5511999999999@lid".into()), ..request("search") };
        let same = one.clone();
        let other_q = Request { q: Some("boleta".into()), ..one.clone() };
        let other_limit = Request { limit: Some(5), ..one.clone() };
        let other_op = Request { op: "read".into(), q: None, ..one.clone() };
        assert_eq!(one.dedupe_key(), same.dedupe_key(), "the same question is one job");
        assert_ne!(one.dedupe_key(), other_q.dedupe_key());
        assert_ne!(one.dedupe_key(), other_limit.dedupe_key(), "a different limit is a different answer");
        assert_ne!(one.dedupe_key(), other_op.dedupe_key());
        assert_eq!(one.dedupe_key().len(), 64, "sha256, hex");
        // A request that does not validate still has one stable key (a repeated bad call is not two).
        let bad = request("nope");
        assert_eq!(bad.dedupe_key(), bad.clone().dedupe_key());
    }

    #[test]
    fn the_payload_round_trips_and_a_foreign_payload_is_malformed() {
        let verified = Request {
            chat: Some("120363000000000001@g.us".into()),
            id: Some("3EB0ABCDEF".into()),
            ..request("download")
        }
        .validate()
        .unwrap();
        let payload = verified.to_request().encode();
        let back = Request::decode(&payload).unwrap();
        assert_eq!(back.validate().unwrap(), verified);
        assert_eq!(Request::decode(b"not json").unwrap_err().code, "malformed_job");
    }

    #[test]
    fn a_refusal_names_the_tool_and_never_echoes_the_query() {
        let refusal = refusal(Op::Search, "empty_query", "a search needs q, chat, kind or from");
        assert_eq!(refusal["ok"], false);
        assert_eq!(refusal["error"], "whatsapp_search_empty_query");
        assert_eq!(refusal["effect"], "none");
        let detail = Refusal::new("bad_query", "segredo-do-operator");
        assert_eq!(detail.error(Op::Download), "whatsapp_download_bad_query");
        assert_eq!(detail.detail, "segredo-do-operator");
    }

    #[test]
    fn a_big_answer_loses_its_tail_and_says_so() {
        let hits: Vec<serde_json::Value> = (0..500)
            .map(|i| serde_json::json!({"chat": "5511999999999@lid", "id": format!("3EB0{i:04}"), "text": "x".repeat(MAX_TEXT_CHARS)}))
            .collect();
        let answer = answer(Op::Search, serde_json::json!({"hits": hits, "count": 500, "limit": SEARCH_MAX}));
        let bytes = serde_json::to_vec(&answer).unwrap();
        assert!(bytes.len() <= MAX_RESULT_BYTES, "{} bytes", bytes.len());
        assert_eq!(answer["truncated"], true);
        assert_eq!(answer["ok"], true);
        let kept = answer["hits"].as_array().unwrap().len();
        assert!(kept < 500 && kept > 0, "kept {kept}");
        assert_eq!(answer["count"], kept, "the count is what the answer carries");
        assert_eq!(answer["op"], "search");
    }

    #[test]
    fn a_small_answer_is_untouched() {
        let answer = answer(Op::Read, serde_json::json!({"messages": [{"id": "3EB01"}], "count": 1}));
        assert!(answer.get("truncated").is_none());
        assert_eq!(answer["messages"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn a_download_manifest_round_trips() {
        let manifest = Download {
            chat: "5511999999999@lid".into(),
            id: "3EB0ABCDEF".into(),
            kind: "image".into(),
            mime: "image/jpeg".into(),
            filename: "IMG-0001.jpg".into(),
            sha256: "ab".repeat(32),
            bytes: 1024,
            chunks: 1,
        };
        assert_eq!(Download::decode(&manifest.encode()).unwrap(), manifest);
        assert!(Download::decode(b"\x00").is_none());
    }

    #[test]
    fn a_download_header_says_which_attempt_a_chunk_belongs_to() {
        let header = download_header(42);
        assert_eq!(download_header_job(&header), Some(42));
        // A payload chunk is not a header, and neither is a truncated one.
        assert_eq!(download_header_job(&[0u8; 32]), None);
        assert_eq!(download_header_job(&header[..8]), None);
        // Two attempts are distinguishable, which is the whole point (progress is append-only).
        assert_ne!(download_header_job(&download_header(7)), download_header_job(&download_header(8)));
    }

    #[test]
    fn what_is_worth_retrying_is_named() {
        for reason in ["not_connected", "download:timeout", "progress:again", "kv failed"] {
            assert!(retryable(reason), "{reason} is worth another attempt");
        }
        for reason in ["not_indexed", "no_media", "not_downloadable", "deleted", "download_too_large", "bad_chat", "chat_and_id_required"] {
            assert!(!retryable(reason), "{reason} can never succeed on a retry");
        }
    }

    #[test]
    fn a_slow_answer_offers_the_id_and_the_same_question() {
        let answer = slow(Op::Read, 42, "ready");
        assert_eq!(answer["error"], "whatsapp_read_slow");
        assert_eq!(answer["state"], "queued");
        assert_eq!(answer["id"], 42);
        assert_eq!(answer["retry"], true);
        assert_eq!(state_word("done"), "done");
    }
}
