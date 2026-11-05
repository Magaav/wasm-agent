//! The in-memory ring of host-call records for one component, bounded by bytes and by age.
//!
//! One [`Record`] is one call that crossed the component boundary — a `wa:kernel` import (kv, http,
//! websocket, log, speech…), or a `wasi:clocks`/`wasi:random` answer, because those two are what
//! makes a replay non-deterministic if they are not recorded (docs/REPLAY.md).
//!
//! Bounds are enforced on every push, so a component that never calls `expire` is still bounded:
//!
//! * **age** — records older than `max_age` relative to the newest record's timestamp are dropped;
//! * **bytes** — the oldest records go until the ring is under `max_bytes`, but the newest record is
//!   always kept, because the call that just failed is the one the replay exists for.
//!
//! Payload policy: a payload up to `blob_threshold` is stored inline; a larger one is spilled into
//! the [`BlobStore`] and referenced, so the ring's byte bound is a bound on record *count* and small
//! payloads, never on one big message body. With no blob store attached, an oversized payload is
//! reduced to its digest — recorded as "this is what crossed, and here is its sha256", not silently
//! dropped and not allowed to fill memory.
//!
//! Every dagger in that list is reversible: a record evicted from the ring releases its blob
//! references, and so does `clear`, so the blob store's `gc` is the only thing that actually deletes
//! payload bytes.

use crate::blob::{sha256, BlobKey, BlobRef, BlobStore};
use crate::{caps, Error, Result};
use std::collections::VecDeque;
use std::time::{Duration, SystemTime};

/// Per-record accounting overhead: seq, ts, duration, lengths. Not exact per allocation — it is a
/// stable cost charged against the byte bound so the bound means something.
const RECORD_OVERHEAD: u64 = 96;

/// How much of a call is written down.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Payload {
    /// Nothing recorded (e.g. a call with no result, or an argument the policy drops).
    Empty,
    /// The bytes, with their sha256 so a replay can prove it is feeding back what was recorded.
    Inline { sha256: [u8; 32], bytes: Vec<u8> },
    /// Only the digest and the length: the bytes were too large to keep and there was nowhere to
    /// spill them, or the policy records digests for arguments.
    Digest { sha256: [u8; 32], len: u64 },
    /// The bytes are in the blob store under their sha256.
    Blob(BlobRef),
}

impl Payload {
    pub fn digest(&self) -> Option<[u8; 32]> {
        match self {
            Payload::Empty => None,
            Payload::Inline { sha256, .. } => Some(*sha256),
            Payload::Digest { sha256, .. } => Some(*sha256),
            Payload::Blob(r) => Some(r.key.0),
        }
    }

    pub fn len(&self) -> u64 {
        match self {
            Payload::Empty => 0,
            Payload::Inline { bytes, .. } => bytes.len() as u64,
            Payload::Digest { len, .. } => *len,
            Payload::Blob(r) => r.len,
        }
    }

    pub fn is_empty(&self) -> bool {
        matches!(self, Payload::Empty)
    }

    /// The bytes, when this variant carries them.
    pub fn inline_bytes(&self) -> Option<&[u8]> {
        match self {
            Payload::Inline { bytes, .. } => Some(bytes),
            _ => None,
        }
    }

    pub fn blob(&self) -> Option<&BlobRef> {
        match self {
            Payload::Blob(r) => Some(r),
            _ => None,
        }
    }

    fn accounted_len(&self) -> u64 {
        match self {
            Payload::Empty => 0,
            Payload::Inline { bytes, .. } => bytes.len() as u64,
            Payload::Digest { .. } => 32,
            Payload::Blob(_) => 32,
        }
    }
}

/// One recorded host call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    /// Monotonic within a ring; the replay's ordering, and what the host matches a replayed call on.
    pub seq: u64,
    /// When the call happened, as the host's clock reported it.
    pub ts: SystemTime,
    /// The WIT interface, e.g. `wa:kernel/kv`, `wasi:clocks/monotonic-clock`.
    pub interface: String,
    /// The function within it, e.g. `get`, `now`.
    pub function: String,
    pub args: Payload,
    pub result: Payload,
    pub duration: Duration,
}

impl Record {
    fn accounted_len(&self) -> u64 {
        RECORD_OVERHEAD
            .saturating_add(self.interface.len() as u64)
            .saturating_add(self.function.len() as u64)
            .saturating_add(self.args.accounted_len())
            .saturating_add(self.result.accounted_len())
    }
}

/// A call about to be pushed: borrowed, so recording one costs no allocation for its bytes.
#[derive(Clone, Copy, Debug)]
pub struct NewRecord<'a> {
    pub interface: &'a str,
    pub function: &'a str,
    pub args: &'a [u8],
    /// `None` records `Payload::Empty` (a call that returns nothing).
    pub result: Option<&'a [u8]>,
    pub duration: Duration,
    /// The host's timestamp for the call. Explicit: this library never reads a clock.
    pub ts: SystemTime,
}

/// The ring's caps.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RingConfig {
    pub max_bytes: u64,
    pub max_age: Duration,
    /// A payload above this goes to the blob store.
    pub blob_threshold: u64,
    /// When false, arguments are recorded as a digest only (results are always recorded in full):
    /// a policy for components whose arguments carry other people's message text.
    pub keep_args: bool,
}

impl Default for RingConfig {
    fn default() -> Self {
        RingConfig {
            max_bytes: caps::RING_MAX_BYTES,
            max_age: caps::RING_MAX_AGE,
            blob_threshold: caps::BLOB_THRESHOLD_BYTES,
            keep_args: true,
        }
    }
}

/// The ring itself: one per component, in memory, never on disk until `save`.
pub struct RecordRing {
    cfg: RingConfig,
    records: VecDeque<Record>,
    bytes: u64,
    next_seq: u64,
    blobs: Option<BlobStore>,
}

impl std::fmt::Debug for RecordRing {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RecordRing")
            .field("config", &self.cfg)
            .field("records", &self.records.len())
            .field("bytes", &self.bytes)
            .field("blobs", &self.blobs.is_some())
            .finish()
    }
}

impl RecordRing {
    pub fn new(cfg: RingConfig) -> Self {
        RecordRing { cfg, records: VecDeque::new(), bytes: 0, next_seq: 0, blobs: None }
    }

    /// A ring that spills oversized payloads into `store` instead of reducing them to digests.
    pub fn with_blobs(cfg: RingConfig, store: BlobStore) -> Self {
        RecordRing { cfg, records: VecDeque::new(), bytes: 0, next_seq: 0, blobs: Some(store) }
    }

    pub fn config(&self) -> &RingConfig {
        &self.cfg
    }

    pub fn blobs(&self) -> Option<&BlobStore> {
        self.blobs.as_ref()
    }

    pub fn records(&self) -> &VecDeque<Record> {
        &self.records
    }

    pub fn len(&self) -> usize {
        self.records.len()
    }

    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    /// Bytes charged against `max_bytes` (records, inline payloads, digests and blobs by reference).
    pub fn bytes(&self) -> u64 {
        self.bytes
    }

    pub fn newest_ts(&self) -> Option<SystemTime> {
        self.records.back().map(|r| r.ts)
    }

    pub fn oldest_ts(&self) -> Option<SystemTime> {
        self.records.front().map(|r| r.ts)
    }

    /// Record one call. Enforces both bounds before returning, and returns the record's sequence.
    pub fn push(&mut self, call: NewRecord<'_>) -> Result<u64> {
        if !field_ok(call.interface) {
            return Err(Error::BadField("interface"));
        }
        if !field_ok(call.function) {
            return Err(Error::BadField("function"));
        }
        let args = self.encode(call.args, self.cfg.keep_args)?;
        let result = match call.result {
            Some(bytes) => self.encode(bytes, true)?,
            None => Payload::Empty,
        };
        let seq = self.next_seq;
        self.next_seq = self.next_seq.saturating_add(1);
        let record = Record {
            seq,
            ts: call.ts,
            interface: call.interface.to_string(),
            function: call.function.to_string(),
            args,
            result,
            duration: call.duration,
        };
        self.bytes = self.bytes.saturating_add(record.accounted_len());
        self.records.push_back(record);

        // The newest timestamp is the ring's "now": a call that arrives late (or an age bound that
        // nobody runs) still bounds the ring from the caller's own view of time.
        self.expire(call.ts)?;
        while self.bytes > self.cfg.max_bytes && self.records.len() > 1 {
            self.drop_front();
        }
        Ok(seq)
    }

    fn encode(&self, bytes: &[u8], keep: bool) -> Result<Payload> {
        let digest = sha256(bytes);
        if !keep {
            return Ok(Payload::Digest { sha256: digest, len: bytes.len() as u64 });
        }
        if bytes.len() as u64 > self.cfg.blob_threshold {
            return match &self.blobs {
                Some(store) => {
                    let blob = store.put(bytes)?;
                    store.add_ref(&blob.key)?;
                    Ok(Payload::Blob(blob))
                }
                None => Ok(Payload::Digest { sha256: digest, len: bytes.len() as u64 }),
            };
        }
        Ok(Payload::Inline { sha256: digest, bytes: bytes.to_vec() })
    }

    fn drop_front(&mut self) -> Option<Record> {
        let record = self.records.pop_front()?;
        self.bytes = self.bytes.saturating_sub(record.accounted_len());
        if let Some(store) = &self.blobs {
            for payload in [&record.args, &record.result] {
                if let Some(blob) = payload.blob() {
                    // A missing blob is not an error here: the record is already gone, and the
                    // store's gc removes the ghost count. Never fail an eviction on cleanup.
                    let _ = store.release(&blob.key);
                }
            }
        }
        Some(record)
    }

    /// Drop records at least `max_age` older than `now`. Returns how many went.
    pub fn expire(&mut self, now: SystemTime) -> Result<usize> {
        let mut dropped = 0;
        while let Some(front) = self.records.front() {
            let age = now.duration_since(front.ts).unwrap_or_default();
            if age < self.cfg.max_age {
                break;
            }
            self.drop_front();
            dropped += 1;
        }
        Ok(dropped)
    }

    /// Empty the ring, releasing every blob reference it held.
    pub fn clear(&mut self) -> Result<()> {
        while self.drop_front().is_some() {}
        Ok(())
    }
}

fn field_ok(field: &str) -> bool {
    !field.is_empty()
        && field.len() <= 128
        && field.bytes().all(|b| b.is_ascii_graphic())
}

/// The blobs a set of records references, de-duplicated and sorted.
pub fn referenced_blobs<'a>(records: impl IntoIterator<Item = &'a Record>) -> Vec<BlobKey> {
    let mut keys: Vec<BlobKey> = records
        .into_iter()
        .flat_map(|r| [r.args.blob(), r.result.blob()])
        .flatten()
        .map(|r| r.key)
        .collect();
    keys.sort();
    keys.dedup();
    keys
}
