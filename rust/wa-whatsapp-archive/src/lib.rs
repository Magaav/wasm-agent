//! The monthly archive of the WhatsApp index: what falls out of the 180-day window is cut into ONE
//! self-describing, compressed and encrypted file per month.
//!
//! The live index keeps 180 days (`index_retention_days`). A month that is *entirely* outside that
//! window is cut: its records and every key pointing at them leave the component's kv and go into one
//! file, `whatsapp-archive-YYYY-MM.waa`, under the node's archive directory. The file is kept up to 360
//! days from the message date (month end + 360 days), can be pushed to another disk or another node to
//! free the account node, and a month can be loaded back on demand (`wa whatsapp archive restore`).
//!
//! ```text
//! "WAWAARC1"                       8 bytes, so an operator can tell it from any other file
//! u32 manifest_len | manifest JSON plaintext: what the file is, without a key
//! sealed body                       XChaCha20-Poly1305 (the node's keystore) over a zstd frame
//!
//! body (after open + decompress) =
//!   u32 count | (u16 klen | key | u32 vlen | value)*
//!   footer: "WAA1" | u64 entries | u64 bytes | sha256(body[..footer])
//! ```
//!
//! Decisions worth naming:
//!
//! * **The manifest is readable and the payload is not.** "Self-describing" means an operator, a push
//!   target and `wa whatsapp archive list` can say which month a file holds, how many chats and
//!   messages it holds, what it was cut from and by which component build - without the key. Message
//!   text, chat ids and tokens are inside the sealed body only.
//! * **The checksum the push verifies is over the sealed bytes.** A target that cannot open the file
//!   (it has no key, and it must not need one) can still prove the bytes arrived unchanged: the
//!   manifest carries `sha256` of the sealed body, and `verify_file` recomputes it from the file.
//! * **The entries are the index's own key/value pairs.** Not a re-encoding of the records: a cut
//!   archives exactly what the component wrote (record, `ix/id`, `ix/all`, `ix/s`, `ix/k`, `ix/w`,
//!   `ix/ocr`, the reactions folded onto the month's targets) and a restore puts exactly that back.
//!   The key layout and the tokenizer come from `wa-whatsapp-index`, so the node cannot produce a
//!   different key set than the component did.
//! * **A month is a UTC calendar month.** The month is a storage decision, not a display one: a fixed
//!   zone makes the boundary of `whatsapp-archive-2026-04` the same on every node and in every
//!   archive, and `at_local` in an answer is what a reader uses for the operator's own zone.
//! * **The file is written, verified and only then is the index cut.** A crash between the two leaves
//!   the same records in both places, which a later cut overwrites (the file is replaced) and never a
//!   month that exists in neither.
//! * **A restored month is read-only and marked.** The restored record carries `restored: true`, the
//!   month has a mark (`ix/arc/<YYYY-MM>`), retention skips a restored range instead of deleting it,
//!   and an answer built from such a record says so.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use wa_whatsapp_index::keys;

pub mod ops;

pub use ops::{
    cut, due, expire, is_due, list, push_to_dir, push_to_node, restore, restored_months, unload, verify_file, Build, Cut,
    Listed, PushReceipt, Restored, Sink, Unloaded, PUSH_CHUNK,
};

/// Identifies the file. An archive is not a snapshot and not a database file.
pub const MAGIC: &[u8; 8] = b"WAWAARC1";
/// The format this code writes and the only one it reads.
pub const FORMAT: u32 = 1;
/// How long an archive is kept after the last day of its month (the operator's 360-day rule).
pub const KEEP_AFTER_MONTH_DAYS: i64 = 360;
/// The file name of one month's archive, without the directory.
pub const FILE_PREFIX: &str = "whatsapp-archive-";

/// The keystore namespace the archive's key is derived under: one namespace, its own subkey, so an
/// archive blob is not openable as a vault entry even under the same root key.
pub const SEAL_NAMESPACE: &str = "wa-whatsapp-archive";

/// The context (AAD) a month's body is sealed with: a blob cannot be opened as another month's.
pub fn seal_context(month: &str) -> String {
    format!("whatsapp-archive|{FORMAT}|{month}")
}

// ---- the two seams the operations need -----------------------------------------------------------

/// The four kv calls an index lives behind: the component's own kv, or the node's view of it.
///
/// Deliberately the shape the component's `Store` has, so the same operation code reads a month out of
/// the index in `cargo test` (over [`Memory`]) and in the node (over `wa_kv`).
pub trait Kv {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, String>;
    fn set(&self, key: &[u8], value: &[u8]) -> Result<(), String>;
    fn del(&self, key: &[u8]) -> Result<(), String>;
    /// Entries under `prefix`, ordered by key, after `cursor` (exclusive).
    fn scan(&self, prefix: &[u8], cursor: Option<Vec<u8>>, limit: usize) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String>;
}

/// The keystore's keyless seal/open, as the node's root key is used: never a key in hand.
pub trait Sealer {
    fn seal(&self, context: &str, plaintext: &[u8]) -> Result<Vec<u8>, String>;
    fn open(&self, context: &str, sealed: &[u8]) -> Result<Vec<u8>, String>;
}

/// An in-memory kv: the tests' index, ordered by key exactly as `wa:kernel/kv` is.
#[derive(Default)]
pub struct Memory {
    keys: std::cell::RefCell<std::collections::BTreeMap<Vec<u8>, Vec<u8>>>,
}

impl Memory {
    pub fn new() -> Memory {
        Memory::default()
    }

    /// Every key currently stored (the tests assert a cut took its secondary keys too).
    pub fn keys(&self) -> Vec<String> {
        self.keys.borrow().keys().map(|key| String::from_utf8_lossy(key).into_owned()).collect()
    }

    pub fn len(&self) -> usize {
        self.keys.borrow().len()
    }

    pub fn is_empty(&self) -> bool {
        self.keys.borrow().is_empty()
    }

    /// Every `(key, value)` currently stored, for a test that seeds one index from another.
    pub fn entries(&self) -> Vec<(Vec<u8>, Vec<u8>)> {
        self.keys.borrow().iter().map(|(key, value)| (key.clone(), value.clone())).collect()
    }

    pub fn get_str(&self, key: &str) -> Option<String> {
        self.keys.borrow().get(key.as_bytes()).map(|value| String::from_utf8_lossy(value).into_owned())
    }
}

impl Kv for Memory {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, String> {
        Ok(self.keys.borrow().get(key).cloned())
    }

    fn set(&self, key: &[u8], value: &[u8]) -> Result<(), String> {
        self.keys.borrow_mut().insert(key.to_vec(), value.to_vec());
        Ok(())
    }

    fn del(&self, key: &[u8]) -> Result<(), String> {
        self.keys.borrow_mut().remove(key);
        Ok(())
    }

    fn scan(&self, prefix: &[u8], cursor: Option<Vec<u8>>, limit: usize) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
        let mut out = Vec::new();
        let range = self.keys.borrow();
        for (key, value) in range.iter() {
            if !key.starts_with(prefix) {
                continue;
            }
            if let Some(after) = &cursor {
                if key <= after {
                    continue;
                }
            }
            out.push((key.clone(), value.clone()));
            if out.len() >= limit {
                break;
            }
        }
        Ok(out)
    }
}

/// A test sealer that is not the keystore: a real transform (so a payload that was not sealed cannot
/// be read as if it were) with a key the test can hold.
///
/// The keystore's own paths are exercised where the operator's key is (the node capability and
/// `docs/VAULT.md`'s tests); what these tests measure is the archive's format and its operations.
pub struct Xor {
    pub key: u8,
}

impl Sealer for Xor {
    fn seal(&self, context: &str, plaintext: &[u8]) -> Result<Vec<u8>, String> {
        let mut out = context.as_bytes().to_vec();
        out.push(0);
        out.extend(plaintext.iter().map(|byte| byte ^ self.key));
        Ok(out)
    }

    fn open(&self, context: &str, sealed: &[u8]) -> Result<Vec<u8>, String> {
        let mut want = context.as_bytes().to_vec();
        want.push(0);
        let body = sealed.strip_prefix(want.as_slice()).ok_or_else(|| "archive_context_mismatch".to_string())?;
        Ok(body.iter().map(|byte| byte ^ self.key).collect())
    }
}

// ---- the manifest --------------------------------------------------------------------------------

/// What a file says about itself, in the clear: enough to list, push, verify and expire it without a
/// key, and never a message.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Manifest {
    pub format: u32,
    /// `YYYY-MM`, UTC.
    pub month: String,
    /// How many distinct chats the month holds.
    pub chats: u64,
    /// How many messages (records) the month holds. `entries` is larger: every key points at one.
    pub messages: u64,
    /// How many index entries travel: the records and every secondary key of them.
    pub entries: u64,
    /// The component build that wrote the data (`wa-whatsapp`'s version from its installed manifest).
    pub component_version: String,
    /// The component's kv schema version at the time of the cut.
    pub schema: String,
    /// `zstd`.
    pub compression: String,
    /// `xchacha20poly1305`, through the node keystore.
    pub seal: String,
    /// The keystore namespace the key is derived under (a name, never a key).
    pub key_namespace: String,
    /// Bytes of the sealed body.
    pub payload_bytes: u64,
    /// Lowercase hex sha256 of the sealed body - what a push target verifies.
    pub sha256: String,
    /// Unix ms of the cut.
    pub created_ms: i64,
    /// The month's first and last instant (ms, inclusive end), so a reader can say when it is expired.
    pub month_start_ms: i64,
    pub month_end_ms: i64,
}

impl Manifest {
    /// When this archive is deleted: the last day of its month plus the operator's 360 days.
    pub fn expire_ms(&self) -> i64 {
        self.month_end_ms + KEEP_AFTER_MONTH_DAYS * 86_400_000
    }
}

// ---- calendar ------------------------------------------------------------------------------------

// One definition, in the seam: the component names a restored record's month with the same code the
// node cuts with, so a mark and an answer never disagree about where a boundary is.
pub use wa_whatsapp_index::month::{bounds as month_bounds, is_month, of as month_of};

/// Is `month` past the 360 days it is kept after its last day?
pub fn expired(month: &str, now_ms: i64) -> bool {
    match month_bounds(month) {
        Ok((_, end)) => now_ms >= end + KEEP_AFTER_MONTH_DAYS * 86_400_000,
        Err(_) => false,
    }
}

/// The archive file name of a month.
pub fn file_name(month: &str) -> String {
    format!("{FILE_PREFIX}{month}.waa")
}

/// The month a file name names, if it is one of ours.
pub fn month_of_file(name: &str) -> Option<String> {
    let stem = name.strip_prefix(FILE_PREFIX)?.strip_suffix(".waa")?;
    if is_month(stem) {
        Some(stem.to_string())
    } else {
        None
    }
}

// ---- the file format -----------------------------------------------------------------------------

/// The bytes of one archive file: manifest in the clear, sealed body after it.
pub fn encode(manifest: &Manifest, body: &[u8]) -> Vec<u8> {
    let json = serde_json::to_vec(manifest).unwrap_or_default();
    let mut out = Vec::with_capacity(MAGIC.len() + 4 + json.len() + body.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&(json.len() as u32).to_le_bytes());
    out.extend_from_slice(&json);
    out.extend_from_slice(body);
    out
}

/// Split a file into its manifest and its sealed body, refusing anything that is not this format.
pub fn decode(bytes: &[u8]) -> Result<(Manifest, Vec<u8>), String> {
    if bytes.len() < MAGIC.len() + 4 || &bytes[..MAGIC.len()] != MAGIC {
        return Err("archive_not_an_archive".to_string());
    }
    let at = MAGIC.len();
    let len = u32::from_le_bytes(bytes[at..at + 4].try_into().map_err(|_| "archive_truncated".to_string())?) as usize;
    let json_start = at + 4;
    let json_end = json_start.checked_add(len).ok_or_else(|| "archive_truncated".to_string())?;
    if json_end > bytes.len() {
        return Err("archive_truncated".to_string());
    }
    let manifest: Manifest =
        serde_json::from_slice(&bytes[json_start..json_end]).map_err(|_| "archive_manifest_unreadable".to_string())?;
    if manifest.format != FORMAT {
        return Err(format!("archive_format_unsupported:{}", manifest.format));
    }
    Ok((manifest, bytes[json_end..].to_vec()))
}

/// Lowercase hex sha256.
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The body's own framing: `count | entries | footer{tag, entries, bytes, sha256}`.
fn payload_encode(entries: &[(Vec<u8>, Vec<u8>)]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(entries.len() as u32).to_le_bytes());
    for (key, value) in entries {
        out.extend_from_slice(&(key.len() as u16).to_le_bytes());
        out.extend_from_slice(key);
        out.extend_from_slice(&(value.len() as u32).to_le_bytes());
        out.extend_from_slice(value);
    }
    let bytes = out.len() as u64;
    // The digest covers the entries and nothing after them: the footer carries it, so it cannot be
    // inside what it protects.
    let digest = Sha256::digest(&out);
    out.extend_from_slice(b"WAA1");
    out.extend_from_slice(&(entries.len() as u64).to_le_bytes());
    out.extend_from_slice(&bytes.to_le_bytes());
    out.extend_from_slice(&digest);
    out
}

fn payload_decode(bytes: &[u8]) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
    const FOOTER: usize = 4 + 8 + 8 + 32;
    if bytes.len() < FOOTER {
        return Err("archive_payload_truncated".to_string());
    }
    let (head, footer) = bytes.split_at(bytes.len() - FOOTER);
    if &footer[..4] != b"WAA1" {
        return Err("archive_payload_truncated".to_string());
    }
    let entries = u64::from_le_bytes(footer[4..12].try_into().map_err(|_| "archive_payload_truncated".to_string())?);
    let payload_bytes = u64::from_le_bytes(footer[12..20].try_into().map_err(|_| "archive_payload_truncated".to_string())?);
    if payload_bytes != head.len() as u64 {
        return Err("archive_payload_size_mismatch".to_string());
    }
    let want = hex(&footer[20..]);
    if want != sha256_hex(head) {
        return Err("archive_payload_corrupt".to_string());
    }
    let mut at = 0usize;
    let count = u32::from_le_bytes(head.get(..4).ok_or_else(|| "archive_payload_truncated".to_string())?[..].try_into().unwrap());
    at += 4;
    let mut out: Vec<(Vec<u8>, Vec<u8>)> = Vec::with_capacity(count as usize);
    for _ in 0..count {
        let klen = u16::from_le_bytes(head.get(at..at + 2).ok_or_else(|| "archive_payload_truncated".to_string())?[..].try_into().unwrap()) as usize;
        at += 2;
        let key = head.get(at..at + klen).ok_or_else(|| "archive_payload_truncated".to_string())?.to_vec();
        at += klen;
        let vlen = u32::from_le_bytes(head.get(at..at + 4).ok_or_else(|| "archive_payload_truncated".to_string())?[..].try_into().unwrap()) as usize;
        at += 4;
        let value = head.get(at..at + vlen).ok_or_else(|| "archive_payload_truncated".to_string())?.to_vec();
        at += vlen;
        out.push((key, value));
    }
    if entries != out.len() as u64 {
        return Err("archive_payload_corrupt".to_string());
    }
    Ok(out)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Seal one payload: zstd, then the keystore's seal under the month's context.
pub fn seal_payload(sealer: &dyn Sealer, month: &str, entries: &[(Vec<u8>, Vec<u8>)]) -> Result<Vec<u8>, String> {
    let framed = payload_encode(entries);
    let compressed = zstd::stream::encode_all(framed.as_slice(), 9).map_err(|error| format!("archive_compress_failed: {error}"))?;
    sealer.seal(&seal_context(month), &compressed)
}

/// Open one payload: the keystore's open, then zstd, then the body's own checksum.
pub fn open_payload(sealer: &dyn Sealer, month: &str, body: &[u8]) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
    let compressed = sealer.open(&seal_context(month), body)?;
    let framed = zstd::stream::decode_all(compressed.as_slice()).map_err(|error| format!("archive_decompress_failed: {error}"))?;
    payload_decode(&framed)
}

/// The file names one directory holds, sorted. A directory that does not exist is empty, not an error:
/// a node that has never cut a month has no archive directory.
pub fn list_dir_files(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .map(|entries| entries.flatten().filter(|entry| entry.file_type().map(|kind| kind.is_file()).unwrap_or(false)).map(|entry| entry.file_name().to_string_lossy().to_string()).collect())
        .unwrap_or_default();
    names.sort();
    names
}

/// Where the archive directory of this node is, under the components directory.
pub fn dir_in(components: &Path) -> PathBuf {
    components.join("wa-whatsapp.archive")
}

// ---- the index, as the archive sees it ------------------------------------------------------------

/// One month's worth of index entries, read out of kv: the records, their pointers, and the reactions
/// folded onto them.
#[derive(Clone, Debug, Default)]
pub struct Collected {
    pub entries: Vec<(Vec<u8>, Vec<u8>)>,
    pub messages: u64,
    pub chats: u64,
}

impl Collected {
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// The largest reaction rows one message may contribute (a message with more than this is answered with
/// the first ones, as `reactions` already bounds its answer).
pub const MAX_REACTIONS: usize = 256;
/// How many keys one scan page holds while a month is collected.
pub const PAGE: usize = 500;

/// Read one month's entries out of the index, without deleting anything.
///
/// The walk is the age index (`ix/all`, oldest first), which is the order retention uses: the month is
/// a timestamp range, so the walk stops at its end instead of reading the whole index.
pub fn collect<S: Kv + ?Sized>(kv: &S, month: &str) -> Result<Collected, String> {
    let (start, end) = month_bounds(month)?;
    let prefix = format!("{}all/", keys::PREFIX);
    let mut collected = Collected::default();
    let mut chats: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    let mut cursor: Option<Vec<u8>> = None;
    'walk: loop {
        let page = kv.scan(prefix.as_bytes(), cursor.clone(), PAGE)?;
        if page.is_empty() {
            break;
        }
        cursor = page.last().map(|(key, _)| key.clone());
        let short = page.len() < PAGE;
        for (key, _) in page {
            let text = String::from_utf8_lossy(&key).into_owned();
            let rest = text.strip_prefix(&prefix).unwrap_or_default();
            let parts: Vec<&str> = rest.splitn(3, '/').collect();
            if parts.len() != 3 {
                continue;
            }
            let Some(ts) = keys::from_age(parts[0]) else { continue };
            if ts >= end {
                // Everything after this key is newer: the month is complete.
                break 'walk;
            }
            if ts < start {
                continue;
            }
            let (chat, id) = (parts[1].to_string(), parts[2].to_string());
            let record_key = keys::message(&chat, ts, &id);
            let Some(raw) = kv.get(record_key.as_bytes())? else {
                // An age key whose record is gone (a crash between the two deletes): retention and
                // `repair` own that case, and an archive must not invent a record for it.
                continue;
            };
            let facts = facts_of(&chat, &id, ts, &raw);
            let mut entry_keys = facts.keys();
            // The OCR lane's mark belongs to the record, not to the message: it is archived with it so
            // a restored month does not offer an image to be read a second time.
            let ocr = keys::ocr_seen(&chat, &id);
            if let Some(mark) = kv.get(ocr.as_bytes())? {
                collected.entries.push((ocr.into_bytes(), mark));
            }
            // The reactions folded onto this message are the target's rows, which `remove` leaves alone
            // and the archive cannot: a restored month must answer "who reacted" the same way.
            for (row, value) in kv.scan(keys::reaction_prefix(&chat, &id).as_bytes(), None, MAX_REACTIONS)? {
                collected.entries.push((row, value));
            }
            let values = facts.values(&raw);
            for (key, value) in entry_keys.drain(..).zip(values) {
                collected.entries.push((key.into_bytes(), value));
            }
            collected.messages += 1;
            chats.insert(chat);
        }
        if short {
            break;
        }
    }
    collected.chats = chats.len() as u64;
    Ok(collected)
}

/// The facts a record's keys follow from, read out of the archived record JSON.
///
/// `None`-safety matters here: a record written by an older build may lack a field, and a default is
/// the right answer for every one of them (an absent `source` is a live record, an absent `kind` is
/// still a kind key).
pub fn facts_of(chat: &str, id: &str, ts: i64, raw: &[u8]) -> keys::RecordFacts {
    let record: RecordView = serde_json::from_slice(raw).unwrap_or_default();
    let options: Vec<&str> = record.poll.as_ref().map(|poll| poll.options.iter().map(String::as_str).collect()).unwrap_or_default();
    let contacts: Vec<&str> = record.contacts.iter().map(|contact| contact.name.as_str()).collect();
    let searchable = wa_whatsapp_index::Searchable {
        body: &[record.text.as_str(), record.transcript.as_str(), record.ocr.as_str()],
        media: record.media.as_ref().map(|media| (media.filename.as_str(), media.mime.as_str())),
        place: record.place.as_ref().map(|place| (place.name.as_str(), place.address.as_str())),
        poll: record.poll.as_ref().map(|poll| (poll.name.as_str(), options.as_slice())),
        contacts: &contacts,
    };
    keys::RecordFacts {
        chat: chat.to_string(),
        id: id.to_string(),
        sender: record.sender,
        ts,
        kind: if record.kind.is_empty() { "other".to_string() } else { record.kind },
        source: if record.source == "history" { "history".to_string() } else { String::new() },
        tokens: searchable.tokens(),
    }
}

/// The part of a record the archive needs, with a default for every field an older build may not have.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct RecordView {
    sender: String,
    kind: String,
    source: String,
    text: String,
    transcript: String,
    ocr: String,
    media: Option<MediaView>,
    place: Option<PlaceView>,
    poll: Option<PollView>,
    contacts: Vec<ContactView>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct MediaView {
    filename: String,
    mime: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct PlaceView {
    name: String,
    address: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct PollView {
    name: String,
    options: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct ContactView {
    name: String,
}

/// Mark one record's JSON as restored (read-only, from an archive), leaving every other field alone.
pub(crate) fn mark_restored(raw: &[u8]) -> Vec<u8> {
    let Ok(mut value) = serde_json::from_slice::<serde_json::Value>(raw) else { return raw.to_vec() };
    if let Some(object) = value.as_object_mut() {
        object.insert("restored".to_string(), serde_json::Value::Bool(true));
        serde_json::to_vec(&value).unwrap_or_else(|_| raw.to_vec())
    } else {
        raw.to_vec()
    }
}

#[cfg(test)]
mod tests;
