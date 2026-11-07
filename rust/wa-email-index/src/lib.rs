//! The email index's seam: one query somebody asked for, and the answer it came back with.
//!
//! Every message the connector fetches is written into the component's own kv namespace (a typed
//! [`Record`] under a stable key, plus a message-id pointer), and a query is a **job** on the shared
//! durable queue (`wa:queue`, queue name [`QUEUE`]) - the same architecture the explicit send uses
//! (`rust/wa-email-outbox`): not a side channel, not a host call into somebody else's state.
//!
//! ```text
//! tool email_search {q?, from?, subject?, mailbox?, since?, until?, has_attachment?, limit?}
//!   -> validate here, enqueue `email.query` (dedupe = the request itself)
//! component wa-email (granted queue worker on `email.query`)
//!   -> read its own index, settle done(answer) | fail(reason)
//! tool answer <- the job's result (bounded, text-carrying, never logged)
//! ```
//!
//! This crate is the part both ends must agree on:
//!
//! * [`Record`] - one fetched message as the index keeps it: envelope, subject, a bounded text body,
//!   the attachment metadata and the flags. It never carries a credential.
//! * [`keys`] - where that record lives in kv, and why the key sorts by mailbox, UIDVALIDITY and UID
//!   (so `scan` is a mailbox read, and a UIDVALIDITY change is a visible namespace change, never a
//!   silent overwrite of a different message).
//! * [`Request`] - the three operations the agent may ask for ([`Op`]), the bounds on each argument,
//!   and the dedupe key: a repeated identical query is *the same job*, so a caller that retried after
//!   a timeout reads the answer the first call already produced.
//! * [`search`] / [`read`] / [`media`] - the answer side, pure functions over a [`Store`], so the
//!   component's guest loop is a thin adapter and every ranking rule is testable natively.
//! * [`bound`] - a job's result has a hard size (`wa:queue` refuses more than 64 KiB rather than
//!   truncating it). Trailing items are dropped *here*, visibly (`truncated: true`), so a big answer
//!   is a smaller answer and never a failed one.
//! * [`received_event`] - the `email.received` bus fact: ids and envelope metadata, never the body.
//!
//! Nothing here logs: the answer carries text because a search result *is* text, and the component's
//! log carries ids, counts and stable words only.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// The queue every query travels on.
pub const QUEUE: &str = "email.query";
/// A query nobody picked up within this window is answered "too old" instead of answered late: the
/// index is a snapshot, and an answer produced ten minutes after the question is a different answer.
pub const FRESH_MS: i64 = 120_000;
/// Attempts before a retryable query failure is final.
pub const MAX_ATTEMPTS: u32 = 2;
/// How long the node waits for the component to settle before answering "still running, here is the
/// job id". Bounded because the caller is a Lua tool call on the node's own thread.
pub const WAIT_MS: u64 = 2_000;
/// The queue's result bound (64 KiB) with room for the JSON envelope around the answer.
pub const RESULT_BOUND: usize = 60 * 1024;
/// Most hits one answer may carry.
pub const MAX_LIMIT: u32 = 50;
pub const DEFAULT_LIMIT: u32 = 20;
/// Most kv records one search may look at. A search is a scan of this component's own index, not an
/// unbounded walk: a node that spends a second per query to answer "did that mail arrive" has stopped
/// answering everything else.
pub const MAX_SCAN: usize = 4_000;
/// Longest text kept per record and per snippet, in characters.
pub const MAX_TEXT: usize = 8_000;
pub const MAX_SNIPPET: usize = 280;
/// Longest query string.
pub const MAX_Q: usize = 200;

/// Every topic the connector publishes (manifest `capabilities.bus.publish`).
pub const TOPIC_RECEIVED: &str = "email.received";
/// The payload schema name and version a consumer refuses to guess about.
pub const SCHEMA_RECEIVED: &str = "wa:email/received";
pub const SCHEMA_RECEIVED_VERSION: u32 = 1;

/// One address in an envelope: the display name the sender wrote (optional) and the addr-spec.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Address {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub addr: String,
}

impl Address {
    pub fn new(name: Option<&str>, addr: &str) -> Address {
        Address { name: name.map(str::to_string).filter(|name| !name.trim().is_empty()), addr: addr.trim().to_string() }
    }

    /// `Name <a@b>` or `a@b`, for an answer.
    pub fn display(&self) -> String {
        match &self.name {
            Some(name) => format!("{name} <{}>", self.addr),
            None => self.addr.clone(),
        }
    }
}

/// The metadata of one attachment. The bytes live under [`keys::media`], never in the record.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachmentMeta {
    /// The filename the sender wrote, bounded and stripped of control characters at index time.
    pub filename: String,
    pub mime: String,
    /// Decoded size in bytes.
    pub size: u64,
    /// `sha256` of the decoded bytes: the media handle, and the download's own proof.
    pub sha256: String,
    /// The MIME part this attachment came from (`2.1`), so a later fetch can name it.
    pub part: String,
    /// True when the bytes were small enough to keep in kv; a bigger attachment is metadata only and
    /// answers `media_too_large` instead of pretending to have it.
    #[serde(default)]
    pub stored: bool,
}

/// One message as the index keeps it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    /// The mailbox it arrived in (`INBOX`), upper-cased at index time.
    pub mailbox: String,
    /// The IMAP UID, stable inside one UIDVALIDITY.
    pub uid: u32,
    /// The mailbox generation; a change invalidates every UID the index knows.
    pub uid_validity: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    pub from: Address,
    #[serde(default)]
    pub to: Vec<Address>,
    #[serde(default)]
    pub cc: Vec<Address>,
    #[serde(default)]
    pub subject: String,
    /// When the server says the message arrived (Unix ms).
    pub received_ms: i64,
    /// The `Date` header, when it parsed (Unix ms).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sent_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub in_reply_to: Option<String>,
    /// The first [`MAX_SNIPPET`] characters of the text body, whitespace-collapsed.
    #[serde(default)]
    pub snippet: String,
    /// The text body, bounded to [`MAX_TEXT`] characters (`truncated` says whether it was cut).
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub text_truncated: bool,
    #[serde(default)]
    pub attachments: Vec<AttachmentMeta>,
    /// IMAP flags as the server wrote them (`\Seen`, `\Flagged`, …), bounded.
    #[serde(default)]
    pub flags: Vec<String>,
}

impl Record {
    /// Store the record under its key. Idempotent: the same UID fetched twice is one record (a
    /// reconnect re-fetches the last message; it must not duplicate the index).
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    pub fn decode(bytes: &[u8]) -> Result<Record, String> {
        serde_json::from_slice(bytes).map_err(|error| format!("record is not readable: {error}"))
    }

    /// The key this record is stored under.
    pub fn key(&self) -> Vec<u8> {
        keys::record(&self.mailbox, self.uid_validity, self.uid)
    }

    /// The one-line form a search hit carries: no full body, no attachment bytes.
    pub fn hit(&self, score: i64) -> serde_json::Value {
        serde_json::json!({
            "mailbox": self.mailbox,
            "uid": self.uid,
            "received": self.received_ms,
            "from": self.from.display(),
            "to": self.to.iter().map(Address::display).collect::<Vec<_>>(),
            "subject": self.subject,
            "snippet": self.snippet,
            "attachments": self.attachments.iter().map(|attachment| serde_json::json!({
                "filename": attachment.filename, "mime": attachment.mime, "size": attachment.size,
            })).collect::<Vec<_>>(),
            "seen": self.flags.iter().any(|flag| flag.eq_ignore_ascii_case("\\seen")),
            "score": score,
        })
    }

    /// The whole record as an answer (`email_read`, one message).
    pub fn full(&self) -> serde_json::Value {
        serde_json::json!({
            "mailbox": self.mailbox,
            "uid": self.uid,
            "message_id": self.message_id,
            "from": self.from.display(),
            "to": self.to.iter().map(Address::display).collect::<Vec<_>>(),
            "cc": self.cc.iter().map(Address::display).collect::<Vec<_>>(),
            "subject": self.subject,
            "received": self.received_ms,
            "sent": self.sent_ms,
            "in_reply_to": self.in_reply_to,
            "text": self.text,
            "truncated": self.text_truncated,
            "attachments": self.attachments,
            "flags": self.flags,
        })
    }

    /// The text a search matches against: subject, envelopes and body, folded once.
    pub fn haystack(&self) -> String {
        let mut text = String::with_capacity(self.subject.len() + self.text.len() + 128);
        text.push_str(&self.subject);
        text.push('\n');
        text.push_str(&self.from.display());
        text.push(' ');
        for address in self.to.iter().chain(self.cc.iter()) {
            text.push_str(&address.display());
            text.push(' ');
        }
        text.push('\n');
        text.push_str(&self.text);
        fold(&text)
    }
}

/// The kv key layout. All keys are ASCII; a mailbox is sanitized so a key can never contain a
/// separator it did not mint.
pub mod keys {
    use super::*;

    /// Record prefix: `r/`.
    pub const RECORD: &[u8] = b"r/";
    /// Message-id pointer prefix: `m/`.
    pub const MESSAGE_ID: &[u8] = b"m/";
    /// Attachment bytes: `b/`.
    pub const MEDIA: &[u8] = b"b/";
    /// Per-mailbox sync state: `s/`.
    pub const STATE: &[u8] = b"s/";
    /// Largest attachment kept in kv (the media download path). Bigger ones are metadata only.
    pub const MAX_MEDIA: usize = 512 * 1024;

    /// A mailbox as it appears in a key: upper-cased, with anything but `A-Z0-9_-` replaced by `_`.
    pub fn name(name: &str) -> String {
        let upper = name.trim().to_ascii_uppercase();
        if upper.is_empty() {
            return "INBOX".to_string();
        }
        upper.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' }).take(64).collect()
    }

    /// `r/<mailbox>/<uidvalidity:010>/<uid:010>` - sorts by mailbox, then generation, then UID.
    pub fn record(mailbox: &str, uid_validity: u32, uid: u32) -> Vec<u8> {
        format!("r/{}/{uid_validity:010}/{uid:010}", name(mailbox)).into_bytes()
    }

    /// The prefix of one mailbox's records (`r/<mailbox>/`).
    pub fn mailbox_prefix(mailbox: &str) -> Vec<u8> {
        format!("r/{}/", name(mailbox)).into_bytes()
    }

    /// `m/<sha16>/<mailbox>/<uid>` - what a message id points at (a duplicate delivery is visible).
    pub fn message_id(message_id: &str, mailbox: &str, uid: u32) -> Vec<u8> {
        format!("m/{}/{}/{uid:010}", &digest(message_id.trim().to_ascii_lowercase().as_bytes())[..16], name(mailbox)).into_bytes()
    }

    /// `b/<sha256>` - one attachment's bytes.
    pub fn media(sha256: &str) -> Vec<u8> {
        format!("b/{sha256}").into_bytes()
    }

    /// `s/<mailbox>/<uidvalidity:010>` - the next UID to ask for.
    pub fn state(mailbox: &str, uid_validity: u32) -> Vec<u8> {
        format!("s/{}/{uid_validity:010}", name(mailbox)).into_bytes()
    }

    /// The prefix of one mailbox's sync state.
    pub fn state_prefix(mailbox: &str) -> Vec<u8> {
        format!("s/{}/", name(mailbox)).into_bytes()
    }
}

/// The next UID a mailbox session should ask for, and the generation it belongs to.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncState {
    pub mailbox: String,
    pub uid_validity: u32,
    /// Every UID at or below this is indexed (or was skipped as a known duplicate).
    pub last_uid: u32,
    /// Unix ms of the last successful sync, so a reconnect after days is visible in the answer.
    pub synced_ms: i64,
}

/// Where a record goes. The component implements this over `wa:kernel/kv`; the tests implement it in
/// memory, so every ranking and key rule is exercised without a host.
/// One page of kv entries: `(key, value)` pairs, ordered by key.
pub type Page = Vec<(Vec<u8>, Vec<u8>)>;

pub trait Store {
    fn get(&self, key: &[u8]) -> Option<Vec<u8>>;
    fn set(&mut self, key: &[u8], value: &[u8]) -> Result<(), String>;
    fn delete(&mut self, key: &[u8]) -> Result<(), String>;
    /// Entries whose key starts with `prefix`, ordered by key, after `cursor`, at most `limit`.
    fn scan(&self, prefix: &[u8], cursor: Option<&[u8]>, limit: u32) -> Result<Page, String>;

    /// Every entry under `prefix`, bounded by `max` entries (a search's own bound).
    fn scan_bounded(&self, prefix: &[u8], max: usize) -> Result<Page, String> {
        let mut out = Vec::new();
        let mut cursor: Option<Vec<u8>> = None;
        loop {
            let page = self.scan(prefix, cursor.as_deref(), 256)?;
            if page.is_empty() {
                return Ok(out);
            }
            cursor = page.last().map(|(key, _)| key.clone());
            for entry in page {
                if out.len() >= max {
                    return Ok(out);
                }
                out.push(entry);
            }
        }
    }
}

/// An in-memory [`Store`]: the shape a test measures the index against, and the shape the guest keeps
/// while it works (it materialises the prefixes an operation needs, then writes the changes back to
/// `wa:kernel/kv`). Ordered like the real `kv.scan`: byte order, `limit` entries, `cursor` exclusive.
#[derive(Default, Debug)]
pub struct MemoryStore {
    entries: std::collections::BTreeMap<Vec<u8>, Vec<u8>>,
}

impl MemoryStore {
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn keys(&self) -> Vec<String> {
        self.entries.keys().map(|key| String::from_utf8_lossy(key).to_string()).collect()
    }

    /// The pending writes, so a guest can flush them to kv and a test can inspect them.
    pub fn iter(&self) -> impl Iterator<Item = (&Vec<u8>, &Vec<u8>)> {
        self.entries.iter()
    }
}

impl Store for MemoryStore {
    fn get(&self, key: &[u8]) -> Option<Vec<u8>> {
        self.entries.get(key).cloned()
    }

    fn set(&mut self, key: &[u8], value: &[u8]) -> Result<(), String> {
        self.entries.insert(key.to_vec(), value.to_vec());
        Ok(())
    }

    fn delete(&mut self, key: &[u8]) -> Result<(), String> {
        self.entries.remove(key);
        Ok(())
    }

    fn scan(&self, prefix: &[u8], cursor: Option<&[u8]>, limit: u32) -> Result<Page, String> {
        Ok(self
            .entries
            .iter()
            .filter(|(key, _)| key.starts_with(prefix))
            .filter(|(key, _)| cursor.map(|cursor| key.as_slice() > cursor).unwrap_or(true))
            .take(limit as usize)
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect())
    }
}

/// What the index did with one record.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Indexed {
    /// False when the same mailbox/UIDVALIDITY/UID was already there: a refetch is not a new message.
    pub new: bool,
    /// Bytes of attachment carried into kv.
    pub media_bytes: usize,
}

/// Write one record (and its message-id pointer and attachment bytes) into the store.
pub fn index_record<S: Store>(store: &mut S, record: &Record, attachment_bytes: &[Vec<u8>]) -> Result<Indexed, String> {
    let key = record.key();
    let new = store.get(&key).is_none();
    let mut media_bytes = 0usize;
    for (meta, bytes) in record.attachments.iter().zip(attachment_bytes.iter()) {
        if bytes.len() <= keys::MAX_MEDIA {
            store.set(&keys::media(&meta.sha256), bytes)?;
            media_bytes += bytes.len();
        }
    }
    store.set(&key, &record.encode())?;
    if let Some(message_id) = record.message_id.as_deref() {
        store.set(&keys::message_id(message_id, &record.mailbox, record.uid), record.addr_digest().as_bytes())?;
    }
    Ok(Indexed { new, media_bytes })
}

impl Record {
    /// What the message-id pointer stores: the address digest, so a pointer carries no address either.
    pub fn addr_digest(&self) -> String {
        format!("{}#{}", hash16(self.from.addr.as_bytes()), self.received_ms)
    }
}

/// The three questions the agent may ask of the mailbox.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Op {
    /// Search the index.
    Search,
    /// Read one mailbox newest first, or one message when a UID is named.
    Read,
    /// One record's attachment metadata, plus the media handle a download can name.
    Media,
}

/// One query, exactly as it travels in the job payload.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Request {
    pub op: Op,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub q: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mailbox: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub until: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_attachment: Option<bool>,
    /// `read`: one message by UID. `media`: the message whose attachments are asked for.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uid: Option<u32>,
    /// `read`: read older than this UID (the previous answer's `next_before`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
}

impl Request {
    pub fn search() -> Request {
        Request { op: Op::Search, q: None, mailbox: None, from: None, subject: None, since: None, until: None, has_attachment: None, uid: None, before: None, limit: None }
    }

    pub fn read(mailbox: Option<&str>) -> Request {
        Request { op: Op::Read, mailbox: mailbox.map(str::to_string), ..Request::search() }
    }

    pub fn media(uid: u32, mailbox: Option<&str>) -> Request {
        Request { op: Op::Media, uid: Some(uid), mailbox: mailbox.map(str::to_string), ..Request::search() }
    }

    pub fn with_q(mut self, q: &str) -> Request {
        self.q = Some(q.to_string());
        self
    }

    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    pub fn decode(payload: &[u8]) -> Result<Request, String> {
        serde_json::from_slice(payload).map_err(|error| format!("payload is not an email query: {error}"))
    }

    /// Check the request before it is enqueued, so a malformed query is a refusal with a code and not
    /// a job the component has to discover.
    pub fn validate(&self) -> Result<(), Refusal> {
        if let Some(q) = self.q.as_deref() {
            if q.trim().is_empty() {
                return Err(Refusal::new("empty_query", "q is empty: pass words to look for, or another filter"));
            }
            if q.chars().count() > MAX_Q {
                return Err(Refusal::new("query_too_long", format!("q is longer than {MAX_Q} characters")));
            }
            if q.chars().any(|c| c.is_control()) {
                return Err(Refusal::new("bad_query", "q contains a control character"));
            }
        }
        for (name, value) in [("mailbox", &self.mailbox), ("from", &self.from), ("subject", &self.subject)] {
            if let Some(value) = value.as_deref() {
                if value.chars().count() > 200 {
                    return Err(Refusal::new("filter_too_long", format!("{name} is longer than 200 characters")));
                }
                if value.chars().any(|c| c.is_control()) {
                    return Err(Refusal::new("bad_filter", format!("{name} contains a control character")));
                }
            }
        }
        if let (Some(since), Some(until)) = (self.since, self.until) {
            if since > until {
                return Err(Refusal::new("bad_window", "since is later than until"));
            }
        }
        if let Some(limit) = self.limit {
            if limit == 0 || limit > MAX_LIMIT {
                return Err(Refusal::new("bad_limit", format!("limit must be 1..={MAX_LIMIT}")));
            }
        }
        // A read with no filter reads the mailbox; everything else needs at least one narrowing.
        match self.op {
            Op::Search => {
                let narrowed = self.q.is_some()
                    || self.mailbox.is_some()
                    || self.from.is_some()
                    || self.subject.is_some()
                    || self.since.is_some()
                    || self.until.is_some()
                    || self.has_attachment.is_some();
                if !narrowed {
                    return Err(Refusal::new(
                        "empty_query",
                        "a search needs at least one of q, from, subject, mailbox, since, until or has_attachment",
                    ));
                }
            }
            Op::Read | Op::Media => {
                // UID 0 is not a UID: IMAP numbers from 1, so "0" is a caller that passed nothing.
                if self.op == Op::Media && self.uid.unwrap_or(0) == 0 {
                    return Err(Refusal::new("uid_required", "media needs the uid of one message"));
                }
            }
        }
        Ok(())
    }

    /// The producer's idempotency key: the request's own canonical JSON.
    pub fn dedupe_key(&self) -> String {
        hash16(serde_json::to_string(self).unwrap_or_default().as_bytes())
    }

    /// The limit this request will be answered with.
    pub fn limit(&self) -> u32 {
        self.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT)
    }
}

/// Why a query was refused. `code` is a stable word; [`Refusal::error`] is the tool-facing spelling
/// (`email_search_empty_query`, `email_read_bad_limit`, …).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub detail: String,
}

impl Refusal {
    pub fn new(code: &'static str, detail: impl Into<String>) -> Refusal {
        Refusal { code, detail: detail.into() }
    }

    pub fn error(&self) -> String {
        format!("email_{}", self.code)
    }
}

/// What one query answered.
pub type Answer = serde_json::Value;

/// The bounded answer shape: `{ok, ...}` on the way back, `{ok:false, error, detail}` on a refusal.
pub fn answer(value: serde_json::Value) -> Answer {
    let mut object = serde_json::Map::new();
    object.insert("ok".into(), serde_json::Value::Bool(true));
    if let serde_json::Value::Object(fields) = value {
        object.extend(fields);
    }
    serde_json::Value::Object(object)
}

/// The refusal shape both tools and the component answer with.
pub fn refusal(refusal: &Refusal) -> Answer {
    serde_json::json!({ "ok": false, "error": refusal.error(), "code": refusal.code, "detail": refusal.detail })
}

/// Keep an answer inside [`RESULT_BOUND`] by dropping trailing items, visibly.
pub fn bound(mut answer: Answer) -> (Answer, bool) {
    let over = |answer: &Answer| serde_json::to_string(answer).map(|text| text.len() > RESULT_BOUND).unwrap_or(false);
    if !over(&answer) {
        return (answer, false);
    }
    let mut dropped = false;
    for key in ["hits", "messages"] {
        loop {
            if !over(&answer) {
                break;
            }
            let popped = match answer.get_mut(key).and_then(serde_json::Value::as_array_mut) {
                Some(items) if !items.is_empty() => {
                    items.pop();
                    true
                }
                _ => false,
            };
            if !popped {
                break;
            }
            dropped = true;
        }
    }
    if dropped {
        answer["truncated"] = serde_json::Value::Bool(true);
    }
    (answer, dropped)
}

/// Fold text for matching: lowercase and strip Latin diacritics, so `acao` finds `Ação` and
/// `relatorio` finds `Relatório`. Deliberately a small table, not a Unicode database: the languages this
/// connector actually sees (pt, en, es, fr, de) are covered, and a character it does not know is left
/// alone rather than mangled.
pub fn fold(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        let lower = c.to_lowercase().next().unwrap_or(c);
        let mapped = match lower {
            'á' | 'à' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => 'a',
            'é' | 'è' | 'ê' | 'ë' | 'ē' | 'ė' | 'ę' => 'e',
            'í' | 'ì' | 'î' | 'ï' | 'ī' | 'į' => 'i',
            'ó' | 'ò' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ő' => 'o',
            'ú' | 'ù' | 'û' | 'ü' | 'ū' | 'ů' | 'ű' => 'u',
            'ç' | 'ć' | 'č' => 'c',
            'ñ' | 'ń' => 'n',
            'ý' | 'ÿ' => 'y',
            'š' | 'ś' => 's',
            'ž' | 'ź' | 'ż' => 'z',
            'ß' => 's',
            'æ' => 'a',
            'œ' => 'o',
            other => other,
        };
        out.push(mapped);
    }
    out
}

/// The words of a query, folded, with an empty term dropped.
pub fn terms(q: &str) -> Vec<String> {
    fold(q).split_whitespace().map(str::to_string).filter(|term| !term.is_empty()).collect()
}

/// Search the index. Every term must match; the ranking is phrase-before-words and subject/envelope
/// before body, with recency breaking ties.
pub fn search<S: Store>(store: &S, request: &Request) -> Result<Answer, String> {
    let limit = request.limit() as usize;
    let prefix = request.mailbox.as_deref().map(keys::mailbox_prefix).unwrap_or_else(|| keys::RECORD.to_vec());
    let entries = store.scan_bounded(&prefix, MAX_SCAN)?;
    let scanned = entries.len();
    let scanned_all = scanned < MAX_SCAN;
    let q = request.q.as_deref().map(fold);
    let phrase = q.as_deref().map(|q| q.split_whitespace().collect::<Vec<_>>().join(" ")).filter(|q| !q.is_empty());
    let q_terms = request.q.as_deref().map(terms).unwrap_or_default();
    let from = request.from.as_deref().map(fold).filter(|from| !from.is_empty());
    let subject = request.subject.as_deref().map(fold).filter(|subject| !subject.is_empty());
    let mut matches: Vec<(i64, Record)> = Vec::new();
    for (_, value) in entries {
        let Ok(record) = Record::decode(&value) else { continue };
        if let Some(since) = request.since {
            if record.received_ms < since {
                continue;
            }
        }
        if let Some(until) = request.until {
            if record.received_ms > until {
                continue;
            }
        }
        if let Some(want) = request.has_attachment {
            if want != !record.attachments.is_empty() {
                continue;
            }
        }
        let haystack = record.haystack();
        let subject_folded = fold(&record.subject);
        let from_folded = record.from.display().to_lowercase();
        let mut score = 0i64;
        if let Some(from) = from.as_deref() {
            if !from_folded.contains(from) {
                continue;
            }
            score += 20;
        }
        if let Some(subject) = subject.as_deref() {
            if !subject_folded.contains(subject) {
                continue;
            }
            score += 20;
        }
        if let Some(phrase) = phrase.as_deref() {
            if !q_terms.iter().all(|term| haystack.contains(term.as_str())) {
                continue;
            }
            if subject_folded.contains(phrase) {
                score += 1_000;
            } else if haystack.contains(phrase) {
                score += 500;
            }
            for term in &q_terms {
                if subject_folded.contains(term.as_str()) {
                    score += 100;
                }
                if from_folded.contains(term.as_str()) {
                    score += 50;
                }
            }
        }
        if from.is_none() && subject.is_none() && phrase.is_none() {
            // A filter-only query (a time window, an attachment flag): the score is recency.
            score += 1;
        }
        matches.push((score, record));
    }
    let matched = matches.len();
    matches.sort_by(|(score_a, record_a), (score_b, record_b)| score_b.cmp(score_a).then(record_b.received_ms.cmp(&record_a.received_ms)));
    let truncated = matched > limit || !scanned_all;
    let hits: Vec<serde_json::Value> = matches.iter().take(limit).map(|(score, record)| record.hit(*score)).collect();
    let answer = answer(serde_json::json!({
        "query": request.q,
        "mailbox": request.mailbox.as_deref().map(keys::name),
        "matched": matched,
        "returned": hits.len(),
        "truncated": truncated,
        "scanned": scanned,
        "hits": hits,
    }));
    Ok(bound(answer).0)
}

/// Read one mailbox newest first, or one message when a UID is named.
pub fn read<S: Store>(store: &S, request: &Request) -> Result<Answer, String> {
    let mailbox = keys::name(request.mailbox.as_deref().unwrap_or("INBOX"));
    let prefix = keys::mailbox_prefix(&mailbox);
    let entries = store.scan_bounded(&prefix, MAX_SCAN)?;
    let scanned = entries.len();
    let scanned_all = scanned < MAX_SCAN;
    let mut records: Vec<Record> = Vec::with_capacity(entries.len());
    for (_, value) in entries {
        if let Ok(record) = Record::decode(&value) {
            records.push(record);
        }
    }
    if let Some(uid) = request.uid {
        let Some(record) = records.iter().find(|record| record.uid == uid) else {
            return Ok(serde_json::json!({
                "ok": true, "mailbox": mailbox, "uid": uid, "found": false,
                "note": "no such message in the index: it may have been deleted before it was fetched",
            }));
        };
        return Ok(answer(serde_json::json!({
            "mailbox": mailbox, "found": true, "message": record.full(),
            "indexed": records.len(),
        })));
    }
    records.sort_by_key(|record| std::cmp::Reverse(record.uid));
    let before = request.before;
    let eligible: Vec<&Record> = records.iter().filter(|record| before.map(|before| record.uid < before).unwrap_or(true)).collect();
    let limit = request.limit() as usize;
    let has_more = eligible.len() > limit;
    let page: Vec<serde_json::Value> = eligible.iter().take(limit).map(|record| record.full()).collect();
    let next_before = if has_more { eligible.get(limit.saturating_sub(1)).map(|record| record.uid) } else { None };
    let answer = answer(serde_json::json!({
        "mailbox": mailbox,
        "count": page.len(),
        "indexed": records.len(),
        "has_more": has_more,
        "next_before": next_before,
        "truncated": !scanned_all,
        "messages": page,
    }));
    Ok(bound(answer).0)
}

/// One record's attachment metadata plus the media handle a download can name. No bytes: the bytes
/// ride the job's progress stream (`wa:queue` bounds them), never the result.
pub fn media<S: Store>(store: &S, request: &Request) -> Result<Answer, String> {
    let uid = request.uid.unwrap_or(0);
    let mailbox = keys::name(request.mailbox.as_deref().unwrap_or("INBOX"));
    let records = store.scan_bounded(&keys::mailbox_prefix(&mailbox), MAX_SCAN)?;
    let record = records.iter().find_map(|(_, value)| {
        let record = Record::decode(value).ok()?;
        (record.uid == uid).then_some(record)
    });
    let Some(record) = record else {
        return Ok(serde_json::json!({
            "ok": true, "mailbox": mailbox, "uid": uid, "found": false,
            "note": "no such message in the index",
        }));
    };
    let attachments: Vec<serde_json::Value> = record
        .attachments
        .iter()
        .map(|attachment| {
            // `stored` was set when the message was read, and kv keeps at most `MAX_MEDIA` bytes: an
            // attachment above that bound has metadata only. The media answer never loads the bytes (a
            // search must not read 512 KiB per attachment to answer "is it there").
            let stored = attachment.stored && attachment.size <= keys::MAX_MEDIA as u64;
            serde_json::json!({
                "filename": attachment.filename,
                "mime": attachment.mime,
                "size": attachment.size,
                "sha256": attachment.sha256,
                "part": attachment.part,
                "downloadable": stored,
                "handle": format!("email-media:{}", &attachment.sha256[..attachment.sha256.len().min(16)]),
            })
        })
        .collect();
    Ok(answer(serde_json::json!({
        "mailbox": mailbox, "uid": uid, "found": true,
        "subject": record.subject, "received": record.received_ms,
        "attachments": attachments,
    })))
}

/// The `email.received` fact. The payload is envelope metadata - enough for an agent to decide whether
/// to read the message - and never the body: a subscriber that wants the text asks the index
/// (`email_read`). This is an event, not a log line; the component's log carries ids and counts only.
pub fn received_event(record: &Record) -> (String, String, u32, serde_json::Value) {
    let payload = serde_json::json!({
        "mailbox": record.mailbox,
        "uid": record.uid,
        "uid_validity": record.uid_validity,
        "message_id": record.message_id,
        "from": record.from.display(),
        "to": record.to.iter().map(Address::display).collect::<Vec<_>>(),
        "subject": record.subject,
        "received": record.received_ms,
        // The body stays behind the index: a subscriber that wants the text asks `email_read`. The
        // event is envelope metadata, and a subscriber may log it.
        "has_text": !record.text.is_empty(),
        "text_truncated": record.text_truncated,
        "attachments": record.attachments.iter().map(|attachment| serde_json::json!({
            "filename": attachment.filename, "mime": attachment.mime, "size": attachment.size,
        })).collect::<Vec<_>>(),
    });
    (TOPIC_RECEIVED.to_string(), SCHEMA_RECEIVED.to_string(), SCHEMA_RECEIVED_VERSION, payload)
}

fn digest(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut text = String::with_capacity(digest.len() * 2);
    for byte in digest {
        text.push_str(&format!("{byte:02x}"));
    }
    text
}

/// The first 16 hex characters of `sha256(bytes)` - a digest short enough for a key, long enough that a
/// collision is not a thing that happens by accident.
pub fn hash16(bytes: &[u8]) -> String {
    digest(bytes)[..16].to_string()
}

#[cfg(test)]
mod tests;
