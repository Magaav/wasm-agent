//! Saving the ring into one file, and reading it back — the record side of record/replay.
//!
//! # File format, version 1 (`.wrz`)
//!
//! One file = an **uncompressed, versioned header** (so a reader can refuse or inspect a file
//! without trusting its body) followed by a **zstd frame** (level 3, frame checksum on) holding the
//! length-prefixed record stream. All integers are little-endian; every string and byte string is
//! length-prefixed; nothing is padded and nothing is optional inside a version.
//!
//! ```text
//! header (plaintext)
//!   0   [u8; 8]  magic              "WA-REPLY"
//!   8   u16      format version     1
//!  10   u16      flags              0 today; a reader refuses any bit it does not know
//!  12   u64      created_ms        the save's own timestamp, epoch milliseconds
//!  20   u64      record count      records in the body
//!  28   u64      body length       uncompressed body bytes
//!  36   [u8;32]  body sha256       sha256 of the uncompressed body
//!  68   u64      ring max_age_ms   the age bound that was in effect
//!  76   u64      ring max_bytes    the byte bound that was in effect
//!  84   u64      ring blob_threshold
//!  92   u8       keep_args         1 when arguments were recorded, 0 when only their digests were
//!  93   u16      trigger_len, then trigger bytes (utf-8)
//!       u16      label_len,   then label bytes
//!       u32      blob_count,  then per blob: [u8;32] sha256 key, u64 length
//! body = zstd(frame checksum on) of the record stream
//! ```
//!
//! Record stream, per record:
//!
//! ```text
//!   u64  seq
//!   u64  ts_ms            epoch milliseconds
//!   u32  duration_us      microseconds (a host call longer than ~71 min saturates)
//!   u16  interface_len, interface bytes
//!   u16  function_len,  function bytes
//!   args   payload
//!   result payload
//! payload:
//!   u8 tag   0 empty | 1 inline | 2 digest | 3 blob
//!   1: u32 len, bytes
//!   2: [u8;32] sha256, u64 len
//!   3: [u8;32] sha256 key, u64 len        (the blob is NOT in the file: it lives in the store)
//! ```
//!
//! Rules a reader holds to, because a replay is evidence and evidence that is quietly wrong is worse
//! than evidence that is absent:
//!
//! * magic, version and flags are checked before anything is decompressed;
//! * the body must decompress to exactly `body length` bytes with exactly `body sha256`;
//! * a truncated or over-long record stream is [`Error::Corrupt`], not "the records we could read";
//! * a blob is referenced by sha256 and length, never inlined twice, so one save of a ring full of
//!   attachments is small and identical attachments appear once.
//!
//! Blobs are not copied into the file. A save therefore *takes a reference* on every blob its
//! records reference, and deleting the file is the caller's signal to release them (docs/REPLAY.md);
//! [`SavedReplay::missing_blobs`] names any blob that was already gone when the file was written, so
//! the operator learns it now rather than when a replay stops early.

use crate::blob::{sha256, BlobKey, BlobRef, BlobStore};
use crate::dir::BoundedDir;
use crate::ring::{referenced_blobs, Payload, Record, RecordRing, RingConfig};
use crate::{Error, Result};
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub const MAGIC: &[u8; 8] = b"WA-REPLY";
pub const FORMAT_VERSION: u16 = 1;
const ZSTD_LEVEL: i32 = 3;
const FLAG_KNOWN: u16 = 0;

/// Why a replay was saved. Recorded in the header so a directory of replays can be triaged without
/// opening any of them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Trigger {
    /// A host call returned an error.
    Error,
    /// A call or a component run hit its deadline.
    Timeout,
    /// The component trapped, or the supervisor restarted it.
    Crash,
    /// Transcription failed for long enough to matter (the five-minute case, docs/REPLAY.md).
    Transcription,
    /// `wa replay save`, or a test.
    Manual,
    /// Anything the kernel learns later; kept verbatim so adding a trigger upstream never rewrites a
    /// file format.
    Other(String),
}

impl Trigger {
    pub fn as_str(&self) -> &str {
        match self {
            Trigger::Error => "error",
            Trigger::Timeout => "timeout",
            Trigger::Crash => "crash",
            Trigger::Transcription => "transcription",
            Trigger::Manual => "manual",
            Trigger::Other(other) => other,
        }
    }

    pub fn parse(text: &str) -> Trigger {
        match text {
            "error" => Trigger::Error,
            "timeout" => Trigger::Timeout,
            "crash" => Trigger::Crash,
            "transcription" => Trigger::Transcription,
            "manual" => Trigger::Manual,
            other => Trigger::Other(other.to_string()),
        }
    }
}

impl std::fmt::Display for Trigger {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// What `save` should do with the file it writes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SaveOptions {
    pub trigger: Trigger,
    pub label: String,
    /// Pin the file: never evicted by the quota, never expired. For an incident.
    pub pin: bool,
}

impl Default for SaveOptions {
    fn default() -> Self {
        SaveOptions { trigger: Trigger::Manual, label: "replay".to_string(), pin: false }
    }
}

/// What `save` wrote.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SavedReplay {
    pub name: String,
    pub bytes: u64,
    pub records: u64,
    pub pinned: bool,
    /// Blobs the saved records point at that the store no longer had. The file is still written and
    /// still readable; resolving those payloads will report [`Error::BlobMissing`].
    pub missing_blobs: Vec<BlobKey>,
}

/// Save the ring as one zstd-compressed file inside `dir`.
///
/// The write goes through [`BoundedDir::write_stamped`], so the directory's quota, its eviction and
/// its threshold all apply to replays exactly as they do to logs: a node cannot fill its disk with
/// replays, and pinned replays are visible as pinned usage.
pub fn save(ring: &RecordRing, dir: &BoundedDir, opts: &SaveOptions, now: SystemTime) -> Result<SavedReplay> {
    let body = encode_records(ring)?;
    let body_sha = sha256(&body);
    let created_ms = millis(now);
    let mut blobs: Vec<BlobRef> = Vec::new();
    let mut missing: Vec<BlobKey> = Vec::new();
    for key in referenced_blobs(ring.records()) {
        let len = record_len_of_blob(ring, &key);
        blobs.push(BlobRef::new(key, len));
        match ring.blobs() {
            Some(store) if store.has(&key) => {
                // The file becomes its own reference: the ring may evict the record tomorrow.
                store.add_ref(&key)?;
            }
            _ => missing.push(key),
        }
    }

    let compressed = compress(&body)?;
    let mut header = Vec::with_capacity(128);
    header.extend_from_slice(MAGIC);
    header.extend_from_slice(&FORMAT_VERSION.to_le_bytes());
    header.extend_from_slice(&FLAG_KNOWN.to_le_bytes());
    header.extend_from_slice(&created_ms.to_le_bytes());
    header.extend_from_slice(&(ring.len() as u64).to_le_bytes());
    header.extend_from_slice(&(body.len() as u64).to_le_bytes());
    header.extend_from_slice(&body_sha);
    header.extend_from_slice(&duration_millis(ring.config().max_age).to_le_bytes());
    header.extend_from_slice(&ring.config().max_bytes.to_le_bytes());
    header.extend_from_slice(&ring.config().blob_threshold.to_le_bytes());
    header.push(u8::from(ring.config().keep_args));
    put_str(&mut header, opts.trigger.as_str())?;
    put_str(&mut header, &opts.label)?;
    header.extend_from_slice(&(blobs.len() as u32).to_le_bytes());
    for blob in &blobs {
        header.extend_from_slice(&blob.key.0);
        header.extend_from_slice(&blob.len.to_le_bytes());
    }
    header.extend_from_slice(&compressed);

    let name = file_name(dir, opts, created_ms);
    dir.write_stamped(&name, &header, now)?;
    if opts.pin {
        dir.pin(&name)?;
    }
    Ok(SavedReplay {
        name,
        bytes: header.len() as u64,
        records: ring.len() as u64,
        pinned: opts.pin,
        missing_blobs: missing,
    })
}

fn record_len_of_blob(ring: &RecordRing, key: &BlobKey) -> u64 {
    for record in ring.records() {
        for payload in [&record.args, &record.result] {
            if let Some(blob) = payload.blob() {
                if blob.key == *key {
                    return blob.len;
                }
            }
        }
    }
    0
}

/// `<label>.<trigger>.<created_ms>[-n].wrz`, made safe for any filesystem and unique in `dir`.
fn file_name(dir: &BoundedDir, opts: &SaveOptions, created_ms: u64) -> String {
    let mut label = sanitize(&opts.label);
    if label.is_empty() {
        label = "replay".to_string();
    }
    let trigger = sanitize(opts.trigger.as_str());
    let trigger = if trigger.is_empty() { "other".to_string() } else { trigger };
    let stem = format!("{label}.{trigger}.{created_ms}");
    let mut name = format!("{stem}.wrz");
    let mut n = 2;
    while dir.exists(&name) {
        name = format!("{stem}-{n}.wrz");
        n += 1;
    }
    name
}

fn sanitize(text: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;
    for ch in text.chars().take(64) {
        let c = ch.to_ascii_lowercase();
        if c.is_ascii_alphanumeric() {
            out.push(c);
            last_dash = false;
        } else if !last_dash && !out.is_empty() {
            out.push('-');
            last_dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    out.truncate(40);
    out
}

fn encode_records(ring: &RecordRing) -> Result<Vec<u8>> {
    let mut body = Vec::with_capacity(ring.bytes() as usize);
    for record in ring.records() {
        body.extend_from_slice(&record.seq.to_le_bytes());
        body.extend_from_slice(&millis(record.ts).to_le_bytes());
        let duration_us = record.duration.as_micros().min(u32::MAX as u128) as u32;
        body.extend_from_slice(&duration_us.to_le_bytes());
        put_str(&mut body, &record.interface)?;
        put_str(&mut body, &record.function)?;
        put_payload(&mut body, &record.args);
        put_payload(&mut body, &record.result);
    }
    Ok(body)
}

fn put_payload(out: &mut Vec<u8>, payload: &Payload) {
    match payload {
        Payload::Empty => out.push(0),
        Payload::Inline { bytes, .. } => {
            out.push(1);
            out.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
            out.extend_from_slice(bytes);
        }
        Payload::Digest { sha256, len } => {
            out.push(2);
            out.extend_from_slice(sha256);
            out.extend_from_slice(&len.to_le_bytes());
        }
        Payload::Blob(blob) => {
            out.push(3);
            out.extend_from_slice(&blob.key.0);
            out.extend_from_slice(&blob.len.to_le_bytes());
        }
    }
}

fn put_str(out: &mut Vec<u8>, text: &str) -> Result<()> {
    if text.len() > u16::MAX as usize {
        return Err(Error::BadField("string too long for the v1 format"));
    }
    out.extend_from_slice(&(text.len() as u16).to_le_bytes());
    out.extend_from_slice(text.as_bytes());
    Ok(())
}

fn compress(body: &[u8]) -> Result<Vec<u8>> {
    let mut encoder = zstd::Encoder::new(Vec::new(), ZSTD_LEVEL)?;
    encoder.include_checksum(true)?;
    std::io::Write::write_all(&mut encoder, body)?;
    Ok(encoder.finish()?)
}

fn millis(ts: SystemTime) -> u64 {
    ts.duration_since(UNIX_EPOCH).unwrap_or_default().as_millis().min(u64::MAX as u128) as u64
}

fn from_millis(ms: u64) -> SystemTime {
    UNIX_EPOCH + Duration::from_millis(ms)
}

fn duration_millis(d: Duration) -> u64 {
    d.as_millis().min(u64::MAX as u128) as u64
}

/// The header of a saved replay, as read back.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReplayHeader {
    pub version: u16,
    pub flags: u16,
    pub created: SystemTime,
    pub records: u64,
    pub body_len: u64,
    pub body_sha256: [u8; 32],
    pub trigger: Trigger,
    pub label: String,
    pub blobs: Vec<BlobRef>,
    /// The ring bounds the recording was taken under.
    pub ring: RingConfig,
}

impl ReplayHeader {
    /// Release the references this file holds on its blobs. Call it when the file is deleted or its
    /// pin is removed, so `BlobStore::gc` may eventually collect payloads nothing references; the
    /// count is per file, which is why the ring's own reference and this one are counted apart.
    pub fn release_blobs(&self, store: &BlobStore) -> Result<()> {
        for reference in &self.blobs {
            store.release(&reference.key)?;
        }
        Ok(())
    }
}

/// Reads a saved file record by record. The body is decompressed once (a ring is at most
/// `ring.max_bytes`) and then decoded lazily, so a caller can stop early.
pub struct ReplayReader {
    header: ReplayHeader,
    body: Vec<u8>,
    pos: usize,
    read: u64,
    failed: bool,
}

impl ReplayReader {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let bytes = std::fs::read(path.as_ref())?;
        Self::from_bytes(&bytes)
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        let (header, consumed) = read_header(bytes)?;
        let compressed = &bytes[consumed..];
        if compressed.is_empty() {
            return Err(Error::Corrupt("body is empty".to_string()));
        }
        let body = zstd::stream::decode_all(compressed).map_err(|e| Error::Corrupt(format!("zstd: {e}")))?;
        if body.len() as u64 != header.body_len {
            return Err(Error::Corrupt(format!(
                "body length {} does not match header {}",
                body.len(),
                header.body_len
            )));
        }
        if sha256(&body) != header.body_sha256 {
            return Err(Error::Corrupt("body sha256 does not match header".to_string()));
        }
        Ok(ReplayReader { header, body, pos: 0, read: 0, failed: false })
    }

    pub fn header(&self) -> &ReplayHeader {
        &self.header
    }

    pub fn remaining(&self) -> u64 {
        self.header.records.saturating_sub(self.read)
    }

    pub fn next_record(&mut self) -> Result<Option<Record>> {
        if self.failed || self.read >= self.header.records {
            return Ok(None);
        }
        match parse_record(&self.body, &mut self.pos) {
            Ok(record) => {
                self.read += 1;
                Ok(Some(record))
            }
            Err(e) => {
                self.failed = true;
                Err(e)
            }
        }
    }
}

impl Iterator for ReplayReader {
    type Item = Result<Record>;
    fn next(&mut self) -> Option<Self::Item> {
        match self.next_record() {
            Ok(Some(record)) => Some(Ok(record)),
            Ok(None) => None,
            Err(e) => Some(Err(e)),
        }
    }
}

/// A whole saved replay in memory, with its header.
#[derive(Clone, Debug)]
pub struct Replay {
    pub header: ReplayHeader,
    pub records: Vec<Record>,
}

impl Replay {
    pub fn load(path: impl AsRef<Path>) -> Result<Replay> {
        let mut reader = ReplayReader::open(path)?;
        let header = reader.header().clone();
        let mut records = Vec::with_capacity(header.records as usize);
        while let Some(record) = reader.next_record()? {
            records.push(record);
        }
        Ok(Replay { header, records })
    }

    /// The bytes a replay step must feed back, or `None` when the record carries no bytes (an empty
    /// payload, or a digest-only payload that was never kept).
    pub fn resolve(&self, blobs: &BlobStore, payload: &Payload) -> Result<Option<Vec<u8>>> {
        resolve_payload(blobs, payload)
    }

    /// Check what can be checked without the blob store: the record count matches the header, and
    /// every blob a record points at is one the file declared. (Inline bytes are covered by the
    /// body sha256 in the header, which is checked before a record is ever decoded.)
    pub fn verify(&self) -> Result<()> {
        if self.records.len() as u64 != self.header.records {
            return Err(Error::Corrupt(format!(
                "{} records, header says {}",
                self.records.len(),
                self.header.records
            )));
        }
        for record in &self.records {
            for payload in [&record.args, &record.result] {
                if let Some(blob) = payload.blob() {
                    if !self.header.blobs.iter().any(|declared| declared.key == blob.key) {
                        return Err(Error::Corrupt(format!(
                            "seq {} references blob {} the header does not declare",
                            record.seq,
                            blob.key.short()
                        )));
                    }
                }
            }
        }
        Ok(())
    }

    /// Resolve every blob the file references and prove each one is the content it claims to be.
    /// Returns the keys that are missing or do not verify.
    pub fn verify_blobs(&self, blobs: &BlobStore) -> Result<Vec<BlobKey>> {
        let mut bad = Vec::new();
        for reference in &self.header.blobs {
            match blobs.get(&reference.key)? {
                Some(bytes) if self_digest(&bytes) == reference.key.0 => {}
                _ => bad.push(reference.key),
            }
        }
        Ok(bad)
    }
}

fn self_digest(bytes: &[u8]) -> [u8; 32] {
    sha256(bytes)
}

/// Resolve one payload: inline bytes, or the blob the record points at. A digest-only payload has no
/// bytes to give back — `Ok(None)` — and a missing blob is an error, because feeding the guest
/// something else would be worse than stopping the replay.
pub fn resolve_payload(blobs: &BlobStore, payload: &Payload) -> Result<Option<Vec<u8>>> {
    match payload {
        Payload::Empty | Payload::Digest { .. } => Ok(None),
        Payload::Inline { bytes, .. } => Ok(Some(bytes.clone())),
        Payload::Blob(reference) => match blobs.get(&reference.key)? {
            Some(bytes) => {
                if self_digest(&bytes) != reference.key.0 {
                    return Err(Error::Corrupt(format!("blob {} does not match its key", reference.key.short())));
                }
                Ok(Some(bytes))
            }
            None => Err(Error::BlobMissing(reference.key)),
        },
    }
}

/// A bounds-checked cursor over the file bytes. Every read either succeeds or says why not.
struct Cursor<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Cursor { bytes, pos: 0 }
    }
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self.pos.checked_add(n).ok_or_else(|| Error::Corrupt("length overflow".to_string()))?;
        if end > self.bytes.len() {
            return Err(Error::Corrupt(format!("truncated at {} (wanted {n} more bytes)", self.pos)));
        }
        let slice = &self.bytes[self.pos..end];
        self.pos = end;
        Ok(slice)
    }
    fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16> {
        let b = self.take(2)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }
    fn u32(&mut self) -> Result<u32> {
        let b = self.take(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }
    fn u64(&mut self) -> Result<u64> {
        let b = self.take(8)?;
        let mut out = [0u8; 8];
        out.copy_from_slice(b);
        Ok(u64::from_le_bytes(out))
    }
    fn digest(&mut self) -> Result<[u8; 32]> {
        let mut out = [0u8; 32];
        out.copy_from_slice(self.take(32)?);
        Ok(out)
    }
    fn text(&mut self, len: usize) -> Result<String> {
        let bytes = self.take(len)?;
        std::str::from_utf8(bytes)
            .map(|s| s.to_string())
            .map_err(|_| Error::Corrupt("string not utf-8".to_string()))
    }
}

/// Parse the plaintext header out of a file's first bytes and return it with the number of bytes it
/// consumed (where the zstd body starts). Cheap and safe on a file that is not ours: this is what a
/// `replay list` needs, without decompressing anything.
pub fn read_header(bytes: &[u8]) -> Result<(ReplayHeader, usize)> {
    let mut cur = Cursor::new(bytes);
    let magic = cur.take(8)?;
    if magic != MAGIC {
        return Err(Error::Corrupt("not a wa replay file (bad magic)".to_string()));
    }
    let version = cur.u16()?;
    if version > FORMAT_VERSION {
        return Err(Error::UnsupportedVersion(version));
    }
    if version < FORMAT_VERSION {
        return Err(Error::Corrupt(format!("no reader for format version {version}")));
    }
    let flags = cur.u16()?;
    if flags & !FLAG_KNOWN != 0 {
        return Err(Error::Corrupt(format!("unknown flags 0x{flags:04x}")));
    }
    let created = from_millis(cur.u64()?);
    let records = cur.u64()?;
    let body_len = cur.u64()?;
    let body_sha256 = cur.digest()?;
    let max_age = Duration::from_millis(cur.u64()?);
    let max_bytes = cur.u64()?;
    let blob_threshold = cur.u64()?;
    let keep_args = cur.u8()? != 0;
    let trigger_len = cur.u16()? as usize;
    let trigger = Trigger::parse(&cur.text(trigger_len)?);
    let label_len = cur.u16()? as usize;
    let label = cur.text(label_len)?;
    let blob_count = cur.u32()? as usize;
    // A header cannot be larger than the file; refusing before allocating keeps a corrupt file from
    // asking for gigabytes of Vec.
    if blob_count.saturating_mul(40) > bytes.len().saturating_sub(cur.pos) {
        return Err(Error::Corrupt("blob table larger than the file".to_string()));
    }
    let mut blobs = Vec::with_capacity(blob_count);
    for _ in 0..blob_count {
        let key = BlobKey(cur.digest()?);
        let len = cur.u64()?;
        blobs.push(BlobRef::new(key, len));
    }
    let header = ReplayHeader {
        version,
        flags,
        created,
        records,
        body_len,
        body_sha256,
        trigger,
        label,
        blobs,
        ring: RingConfig { max_bytes, max_age, blob_threshold, keep_args },
    };
    Ok((header, cur.pos))
}

fn parse_record(body: &[u8], pos: &mut usize) -> Result<Record> {
    let mut cur = Cursor::new(&body[*pos..]);
    let seq = cur.u64()?;
    let ts = from_millis(cur.u64()?);
    let duration = Duration::from_micros(cur.u32()? as u64);
    let interface_len = cur.u16()? as usize;
    let interface = cur.text(interface_len)?;
    let function_len = cur.u16()? as usize;
    let function = cur.text(function_len)?;
    let args = parse_payload(&mut cur)?;
    let result = parse_payload(&mut cur)?;
    *pos += cur.pos;
    Ok(Record { seq, ts, interface, function, args, result, duration })
}

fn parse_payload(cur: &mut Cursor<'_>) -> Result<Payload> {
    match cur.u8()? {
        0 => Ok(Payload::Empty),
        1 => {
            let len = cur.u32()? as usize;
            let bytes = cur.take(len)?.to_vec();
            let sha256 = self_digest(&bytes);
            Ok(Payload::Inline { sha256, bytes })
        }
        2 => {
            let sha256 = cur.digest()?;
            let len = cur.u64()?;
            Ok(Payload::Digest { sha256, len })
        }
        3 => {
            let key = BlobKey(cur.digest()?);
            let len = cur.u64()?;
            Ok(Payload::Blob(BlobRef::new(key, len)))
        }
        tag => Err(Error::Corrupt(format!("unknown payload tag {tag}"))),
    }
}
