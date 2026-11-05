//! A migration sees the namespace as a batch: an ordered map of the component's own keys.
//!
//! Two properties matter more than convenience here:
//!
//! 1. The reserved `__wa/` keys are not in the map, and [`Batch::insert`] refuses to create one. A
//!    step therefore cannot raise the schema version itself, skip a step or forge `last_migrated_by`.
//! 2. A step is a pure function of the batch. Everything it wants to do it does in memory; the engine
//!    diffs before/after and journals the result. That is what makes replay after a crash exact even
//!    for a step that is not idempotent (append-to-value, add-a-counter, ...).

use crate::kv::Kv;
use crate::meta::is_reserved;
use crate::{check_size, Error, Result};
use std::collections::BTreeMap;

/// The keys of one namespace, reserved meta excluded.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Batch {
    entries: BTreeMap<Vec<u8>, Vec<u8>>,
}

impl Batch {
    pub fn new() -> Self {
        Self::default()
    }

    /// Build a batch from raw entries, refusing reserved keys. The caller (a snapshot import or the
    /// migrator) has already filtered them; refusing again means a bug surfaces here, not in kv.
    pub fn from_entries<K, V>(entries: impl IntoIterator<Item = (K, V)>) -> Result<Self>
    where
        K: Into<Vec<u8>>,
        V: Into<Vec<u8>>,
    {
        let mut batch = Batch::new();
        for (key, value) in entries {
            let (key, value) = (key.into(), value.into());
            batch.insert(&key, value)?;
        }
        Ok(batch)
    }

    /// Load every key the component owns. `max_bytes` bounds the memory a migration may take: a
    /// namespace larger than this is a migration the host must run in chunks (a future step API),
    /// not one this engine silently loads.
    pub fn load(kv: &mut dyn Kv, max_bytes: u64) -> Result<Self> {
        let entries = kv.scan_prefix(b"")?;
        let mut batch = Batch::new();
        let mut total: u64 = 0;
        for (key, value) in entries {
            if is_reserved(&key) {
                continue;
            }
            total += key.len() as u64 + value.len() as u64;
            if total > max_bytes {
                return Err(Error::Limit {
                    what: "migration batch",
                    limit: max_bytes,
                    found: total,
                });
            }
            batch.insert(&key, value)?;
        }
        Ok(batch)
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Bytes of keys plus values: what a budget has to cover.
    pub fn bytes(&self) -> u64 {
        self.entries
            .iter()
            .map(|(key, value)| key.len() as u64 + value.len() as u64)
            .sum()
    }

    pub fn get(&self, key: &[u8]) -> Option<&[u8]> {
        self.entries.get(key).map(Vec::as_slice)
    }

    pub fn contains_key(&self, key: &[u8]) -> bool {
        self.entries.contains_key(key)
    }

    /// Insert or replace. Returns the previous value, like a map - a step often wants to know
    /// whether it is creating or rewriting.
    pub fn insert(&mut self, key: &[u8], value: impl Into<Vec<u8>>) -> Result<Option<Vec<u8>>> {
        if is_reserved(key) {
            return Err(Error::Reserved);
        }
        let value = value.into();
        check_size(key, Some(&value))?;
        Ok(self.entries.insert(key.to_vec(), value))
    }

    pub fn remove(&mut self, key: &[u8]) -> Option<Vec<u8>> {
        self.entries.remove(key)
    }

    pub fn iter(&self) -> impl Iterator<Item = (&[u8], &[u8])> + '_ {
        self.entries
            .iter()
            .map(|(key, value)| (key.as_slice(), value.as_slice()))
    }

    pub fn prefix<'s>(
        &'s self,
        prefix: &'s [u8],
    ) -> impl Iterator<Item = (&'s [u8], &'s [u8])> + 's {
        self.entries
            .range(prefix.to_vec()..)
            .take_while(move |(key, _)| key.starts_with(prefix))
            .map(|(key, value)| (key.as_slice(), value.as_slice()))
    }

    /// Move every entry under `from` to the same suffix under `to`, in place. The most common shape
    /// of a vN -> vN+1 step (a key prefix that became a different prefix), so it is not left to each
    /// component to reimplement with an off-by-one.
    pub fn rename_prefix(&mut self, from: &[u8], to: &[u8]) -> Result<usize> {
        if is_reserved(from) || is_reserved(to) {
            return Err(Error::Reserved);
        }
        let moves: Vec<(Vec<u8>, Vec<u8>, Vec<u8>)> = self
            .prefix(from)
            .map(|(key, value)| {
                let mut moved = to.to_vec();
                moved.extend_from_slice(&key[from.len()..]);
                (key.to_vec(), moved, value.to_vec())
            })
            .collect();
        let moved = moves.len();
        for (old, new, value) in moves {
            self.entries.remove(&old);
            check_size(&new, Some(&value))?;
            self.entries.insert(new, value);
        }
        Ok(moved)
    }

    pub fn into_entries(self) -> Vec<(Vec<u8>, Vec<u8>)> {
        self.entries.into_iter().collect()
    }
}

/// What one step changed, counted for the report (and for the dry run).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ChangeCounts {
    pub added: usize,
    pub removed: usize,
    pub changed: usize,
    pub unchanged: usize,
}

impl ChangeCounts {
    /// Keys that differ before/after; `unchanged` is reported but not counted as work.
    pub fn total(&self) -> usize {
        self.added + self.removed + self.changed
    }

    pub fn is_empty(&self) -> bool {
        self.total() == 0
    }

    pub fn add(&mut self, other: ChangeCounts) {
        self.added += other.added;
        self.removed += other.removed;
        self.changed += other.changed;
        self.unchanged += other.unchanged;
    }
}

/// One journaled write. Full key **and full value** on purpose: applying it twice must be the same
/// as applying it once, which a "set this field" delta would not guarantee after a partial write.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Change {
    Put { key: Vec<u8>, value: Vec<u8> },
    Del { key: Vec<u8> },
}

impl Change {
    pub fn key(&self) -> &[u8] {
        match self {
            Change::Put { key, .. } | Change::Del { key } => key,
        }
    }
}

/// Diff two batches: the changes to apply, and the counts to report.
pub fn diff(before: &Batch, after: &Batch) -> (ChangeCounts, Vec<Change>) {
    let mut counts = ChangeCounts::default();
    let mut changes = Vec::new();
    for (key, value) in after.iter() {
        match before.get(key) {
            None => {
                counts.added += 1;
                changes.push(Change::Put {
                    key: key.to_vec(),
                    value: value.to_vec(),
                });
            }
            Some(old) if old != value => {
                counts.changed += 1;
                changes.push(Change::Put {
                    key: key.to_vec(),
                    value: value.to_vec(),
                });
            }
            Some(_) => counts.unchanged += 1,
        }
    }
    for (key, _) in before.iter() {
        if !after.contains_key(key) {
            counts.removed += 1;
            changes.push(Change::Del { key: key.to_vec() });
        }
    }
    (counts, changes)
}

const ENCODING_MAGIC: &[u8; 4] = b"WC1\0";
/// The pending journal is a host-owned key, so its bound is not the guest's value limit. It is still
/// bounded: a journal bigger than this is refused rather than decoded into memory.
const MAX_JOURNAL_BYTES: u64 = 512 << 20;

/// Encode a step's changes for the pending journal.
///
/// Layout, little endian: `magic(4) count(u32)` then per change `tag(1) klen(u32) key (u32 vlen)
/// value`. Binary because keys are bytes and JSON would need base64 or lossy text, and because the
/// journal is read by this code path only.
pub fn encode_changes(changes: &[Change]) -> Vec<u8> {
    let mut out = Vec::with_capacity(16 + changes.len() * 16);
    out.extend_from_slice(ENCODING_MAGIC);
    out.extend_from_slice(&(changes.len() as u32).to_le_bytes());
    for change in changes {
        match change {
            Change::Put { key, value } => {
                out.push(1);
                out.extend_from_slice(&(key.len() as u32).to_le_bytes());
                out.extend_from_slice(key);
                out.extend_from_slice(&(value.len() as u32).to_le_bytes());
                out.extend_from_slice(value);
            }
            Change::Del { key } => {
                out.push(2);
                out.extend_from_slice(&(key.len() as u32).to_le_bytes());
                out.extend_from_slice(key);
            }
        }
    }
    out
}

/// Decode the pending journal. Every length is checked against the bytes actually left, so a
/// corrupted or truncated journal is refused instead of allocating what it claims.
pub fn decode_changes(bytes: &[u8]) -> Result<Vec<Change>> {
    if bytes.len() as u64 > MAX_JOURNAL_BYTES {
        return Err(Error::Limit {
            what: "migration journal",
            limit: MAX_JOURNAL_BYTES,
            found: bytes.len() as u64,
        });
    }
    if bytes.len() < 8 || &bytes[..4] != ENCODING_MAGIC {
        return Err(Error::Corrupt("migration journal has no magic".into()));
    }
    let count = u32::from_le_bytes(bytes[4..8].try_into().expect("4 bytes")) as usize;
    // Each change costs at least 5 bytes (tag + key length); a count above that is a lie.
    if count > (bytes.len() - 8) / 5 {
        return Err(Error::Corrupt(
            "migration journal count exceeds its length".into(),
        ));
    }
    let mut at = 8;
    let mut changes = Vec::with_capacity(count);
    let mut seen: std::collections::BTreeSet<Vec<u8>> = std::collections::BTreeSet::new();
    for _ in 0..count {
        let tag = journal_take(bytes, &mut at, 1, bytes.len())?[0];
        let key_len = journal_length(bytes, &mut at, bytes.len())?;
        let key = journal_take(bytes, &mut at, key_len, bytes.len())?.to_vec();
        if key.len() as u64 > crate::MAX_KEY_BYTES {
            return Err(Error::Limit {
                what: "journal key",
                limit: crate::MAX_KEY_BYTES,
                found: key.len() as u64,
            });
        }
        if is_reserved(&key) {
            return Err(Error::Corrupt(
                "migration journal addresses a reserved meta key".into(),
            ));
        }
        if !seen.insert(key.clone()) {
            return Err(Error::Corrupt(
                "migration journal repeats a key".into(),
            ));
        }
        match tag {
            1 => {
                let value_len = journal_length(bytes, &mut at, bytes.len())?;
                let value = journal_take(bytes, &mut at, value_len, bytes.len())?.to_vec();
                if value.len() as u64 > crate::MAX_VALUE_BYTES {
                    return Err(Error::Limit {
                        what: "journal value",
                        limit: crate::MAX_VALUE_BYTES,
                        found: value.len() as u64,
                    });
                }
                changes.push(Change::Put { key, value });
            }
            2 => changes.push(Change::Del { key }),
            other => {
                return Err(Error::Corrupt(format!(
                    "migration journal has unknown change tag {other}"
                )))
            }
        }
    }
    if at != bytes.len() {
        return Err(Error::Corrupt(
            "migration journal has trailing bytes".into(),
        ));
    }
    Ok(changes)
}

fn journal_take<'a>(bytes: &'a [u8], at: &mut usize, len: usize, end: usize) -> Result<&'a [u8]> {
    let stop = at
        .checked_add(len)
        .filter(|stop| *stop <= end)
        .ok_or_else(|| Error::Corrupt("migration journal is truncated".into()))?;
    let slice = &bytes[*at..stop];
    *at = stop;
    Ok(slice)
}

fn journal_length(bytes: &[u8], at: &mut usize, end: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        journal_take(bytes, at, 4, end)?.try_into().expect("4 bytes"),
    ) as usize)
}

/// Refuse a change list the host kv would refuse, **before** the journal is written, so a step that
/// produces an oversized value cannot leave the namespace half-migrated.
pub fn validate_changes(changes: &[Change]) -> Result<()> {
    for change in changes {
        match change {
            Change::Put { key, value } => check_size(key, Some(value))?,
            Change::Del { key } => check_size(key, None)?,
        }
    }
    Ok(())
}
