//! Content-addressed blobs: sha256 key, stored once, reference-counted, TTL'd, gated by pins.
//!
//! A ring of 20 MB must never hold a 20 MB message body, and a replay of forty calls to the same
//! interface must not hold forty copies of one attachment. So a payload larger than the ring's spill
//! threshold is stored here once, and the record keeps a [`BlobRef`] — the sha256 key plus the
//! length. Two identical payloads collapse to one file (dedupe), and the count of records/files
//! pointing at it decides when it may go.
//!
//! Layout: `<root>/<first two hex chars>/<64 hex chars>` for the blob, the same name plus `.pin` for
//! a pin, and `<root>/refs.idx` for the counts (`<hex> <count>` per line, replaced atomically).
//! Sharding keeps a directory of thousands of blobs workable on every filesystem we ship on.
//!
//! The refcount is *persistent*, not in-memory only: a replay file that references a blob must keep
//! it alive across a kernel restart, so a count that only lived in RAM would let the next `gc` delete
//! the evidence behind a saved replay. `refs.idx` is written whole on every mutation (a few hundred
//! bytes at most for the node's caps) and read tolerantly — a malformed line is ignored rather than
//! failing the open, because a corrupt index must not make the store unusable.
//!
//! [`BlobStore`] uses interior mutability (`&self` everywhere): a shared `&BlobStore` is enough to
//! store, reference and collect, which is what the ring and a save need while other threads read.

use crate::{Error, Result};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

const REFS_FILE: &str = "refs.idx";
const REFS_HEADER: &str = "# wa-bounded blob refs v1";
const PIN_SUFFIX: &str = ".pin";
const TMP_SUFFIX: &str = ".tmp";

pub fn sha256(bytes: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let out = hasher.finalize();
    let mut key = [0u8; 32];
    key.copy_from_slice(&out);
    key
}

pub fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(DIGITS[(b >> 4) as usize] as char);
        out.push(DIGITS[(b & 0x0f) as usize] as char);
    }
    out
}

/// A sha256 content key. Ordering and hashing are byte order, so a key sorts and de-duplicates
/// without touching the hex form.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct BlobKey(pub [u8; 32]);

impl BlobKey {
    pub fn of(bytes: &[u8]) -> Self {
        BlobKey(sha256(bytes))
    }

    pub fn hex(&self) -> String {
        hex(&self.0)
    }

    pub fn from_hex(text: &str) -> Option<Self> {
        if text.len() != 64 {
            return None;
        }
        let mut key = [0u8; 32];
        for (i, byte) in key.iter_mut().enumerate() {
            let hi = hex_digit(text.as_bytes()[i * 2])?;
            let lo = hex_digit(text.as_bytes()[i * 2 + 1])?;
            *byte = (hi << 4) | lo;
        }
        Some(BlobKey(key))
    }

    /// Hex without the last half, as a log- and file-name-safe short form.
    pub fn short(&self) -> String {
        self.hex()[..16].to_string()
    }
}

fn hex_digit(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

impl fmt::Display for BlobKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.hex())
    }
}

impl fmt::Debug for BlobKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "BlobKey({})", self.hex())
    }
}

impl FromStr for BlobKey {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self> {
        BlobKey::from_hex(s).ok_or_else(|| Error::BadName(s.to_string()))
    }
}

/// A reference a record (or a saved replay) holds on a blob.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlobRef {
    pub key: BlobKey,
    pub len: u64,
}

impl BlobRef {
    pub fn new(key: BlobKey, len: u64) -> Self {
        BlobRef { key, len }
    }
}

/// What one `gc` did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GcReport {
    pub scanned: usize,
    pub removed: Vec<BlobKey>,
    pub bytes_freed: u64,
    pub kept: usize,
    /// Blobs whose age could not be read (metadata error) and were therefore kept: never delete on
    /// a guess.
    pub unreadable: usize,
}

/// A content-addressed blob directory with persistent reference counts.
pub struct BlobStore {
    root: PathBuf,
    refs: Mutex<BTreeMap<BlobKey, u32>>,
}

impl fmt::Debug for BlobStore {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BlobStore").field("root", &self.root).finish()
    }
}

impl BlobStore {
    pub fn open(root: impl Into<PathBuf>) -> Result<Self> {
        let root = root.into();
        fs::create_dir_all(&root)?;
        let refs = read_refs(&root)?;
        Ok(BlobStore { root, refs: Mutex::new(refs) })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn shard(&self, key: &BlobKey) -> PathBuf {
        self.root.join(&key.hex()[..2])
    }

    pub fn blob_path(&self, key: &BlobKey) -> PathBuf {
        self.shard(key).join(key.hex())
    }

    fn pin_path(&self, key: &BlobKey) -> PathBuf {
        self.shard(key).join(format!("{}{PIN_SUFFIX}", key.hex()))
    }

    /// Store `bytes` under its sha256. Idempotent: storing the same bytes again writes nothing and
    /// keeps the original mtime, so the TTL counts from the first store, not the last reference.
    pub fn put(&self, bytes: &[u8]) -> Result<BlobRef> {
        let key = BlobKey::of(bytes);
        let path = self.blob_path(&key);
        if !path.is_file() {
            fs::create_dir_all(self.shard(&key))?;
            let staging = self.shard(&key).join(format!("{}{TMP_SUFFIX}", key.hex()));
            {
                let mut file = fs::File::create(&staging)?;
                file.write_all(bytes)?;
                file.flush()?;
            }
            if let Err(e) = fs::rename(&staging, &path) {
                let _ = fs::remove_file(&staging);
                return Err(e.into());
            }
        }
        Ok(BlobRef { key, len: bytes.len() as u64 })
    }

    pub fn get(&self, key: &BlobKey) -> Result<Option<Vec<u8>>> {
        match fs::read(self.blob_path(key)) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    pub fn has(&self, key: &BlobKey) -> bool {
        self.blob_path(key).is_file()
    }

    /// Add one reference. Refuses a blob that is not stored: a count on a missing file would be a
    /// count nobody can ever resolve, and `gc` would then keep a ghost slot.
    pub fn add_ref(&self, key: &BlobKey) -> Result<u32> {
        if !self.has(key) {
            return Err(Error::BlobMissing(*key));
        }
        let count = {
            let mut refs = self.refs.lock().map_err(|_| Error::Poisoned)?;
            let slot = refs.entry(*key).or_insert(0);
            *slot = slot.saturating_add(1);
            *slot
        };
        self.flush_refs()?;
        Ok(count)
    }

    /// Drop one reference; saturates at zero (a double release is a bug in the caller, not a reason
    /// to underflow into a count that wraps and keeps a blob forever).
    pub fn release(&self, key: &BlobKey) -> Result<u32> {
        let count = {
            let mut refs = self.refs.lock().map_err(|_| Error::Poisoned)?;
            let slot = refs.entry(*key).or_insert(0);
            *slot = slot.saturating_sub(1);
            let count = *slot;
            if count == 0 {
                refs.remove(key);
            }
            count
        };
        self.flush_refs()?;
        Ok(count)
    }

    pub fn refcount(&self, key: &BlobKey) -> u32 {
        self.refs.lock().map(|refs| refs.get(key).copied().unwrap_or(0)).unwrap_or(0)
    }

    pub fn pin(&self, key: &BlobKey) -> Result<()> {
        if !self.has(key) {
            return Err(Error::BlobMissing(*key));
        }
        fs::write(self.pin_path(key), b"")?;
        Ok(())
    }

    pub fn unpin(&self, key: &BlobKey) -> Result<()> {
        match fs::remove_file(self.pin_path(key)) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    pub fn is_pinned(&self, key: &BlobKey) -> bool {
        self.pin_path(key).is_file()
    }

    /// Every stored blob key, sorted.
    pub fn keys(&self) -> Result<Vec<BlobKey>> {
        let mut keys = Vec::new();
        let shards = match fs::read_dir(&self.root) {
            Ok(rd) => rd,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(keys),
            Err(e) => return Err(e.into()),
        };
        for shard in shards {
            let shard = shard?;
            if !shard.file_type()?.is_dir() {
                continue;
            }
            for item in fs::read_dir(shard.path())? {
                let item = item?;
                if !item.file_type()?.is_file() {
                    continue;
                }
                let name = item.file_name().to_string_lossy().into_owned();
                if name.ends_with(PIN_SUFFIX) || name.ends_with(TMP_SUFFIX) {
                    continue;
                }
                if let Some(key) = BlobKey::from_hex(&name) {
                    keys.push(key);
                }
            }
        }
        keys.sort();
        Ok(keys)
    }

    pub fn len(&self) -> Result<usize> {
        Ok(self.keys()?.len())
    }

    pub fn is_empty(&self) -> Result<bool> {
        Ok(self.len()? == 0)
    }

    /// Bytes on disk in blob files (pins and the index are metadata).
    pub fn total_bytes(&self) -> Result<u64> {
        let mut total = 0u64;
        for key in self.keys()? {
            if let Ok(meta) = fs::metadata(self.blob_path(&key)) {
                total = total.saturating_add(meta.len());
            }
        }
        Ok(total)
    }

    /// Delete blobs that are unpinned, unreferenced and at least `ttl` old relative to `now`.
    /// Anything referenced, pinned, younger, or whose age cannot be read stays.
    pub fn gc(&self, now: SystemTime, ttl: Duration) -> Result<GcReport> {
        let mut report = GcReport::default();
        for key in self.keys()? {
            report.scanned += 1;
            if self.is_pinned(&key) || self.refcount(&key) > 0 {
                report.kept += 1;
                continue;
            }
            let meta = match fs::metadata(self.blob_path(&key)) {
                Ok(meta) => meta,
                Err(_) => {
                    report.unreadable += 1;
                    continue;
                }
            };
            let age = meta.modified().map(|ts| now.duration_since(ts).unwrap_or_default()).ok();
            match age {
                Some(age) if age >= ttl => {
                    match fs::remove_file(self.blob_path(&key)) {
                        Ok(()) => {
                            report.removed.push(key);
                            report.bytes_freed = report.bytes_freed.saturating_add(meta.len());
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                        Err(e) => return Err(e.into()),
                    }
                }
                Some(_) => report.kept += 1,
                None => report.unreadable += 1,
            }
        }
        // Drop counts that no longer name a blob (a blob removed by hand, or an index line for a
        // file that never landed), so the index does not grow forever.
        {
            let mut refs = self.refs.lock().map_err(|_| Error::Poisoned)?;
            let stale: Vec<BlobKey> = refs.keys().copied().filter(|k| !self.has(k)).collect();
            for key in stale {
                refs.remove(&key);
            }
        }
        self.flush_refs()?;
        Ok(report)
    }

    fn flush_refs(&self) -> Result<()> {
        let text = {
            let refs = self.refs.lock().map_err(|_| Error::Poisoned)?;
            let mut text = String::from(REFS_HEADER);
            text.push('\n');
            for (key, count) in refs.iter() {
                text.push_str(&format!("{} {}\n", key.hex(), count));
            }
            text
        };
        let staging = self.root.join(format!("{REFS_FILE}{TMP_SUFFIX}"));
        fs::write(&staging, text.as_bytes())?;
        if let Err(e) = fs::rename(&staging, self.root.join(REFS_FILE)) {
            let _ = fs::remove_file(&staging);
            return Err(e.into());
        }
        Ok(())
    }
}

fn read_refs(root: &Path) -> Result<BTreeMap<BlobKey, u32>> {
    let mut out = BTreeMap::new();
    let text = match fs::read_to_string(root.join(REFS_FILE)) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(out),
        Err(e) => return Err(e.into()),
    };
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.split_whitespace();
        let (Some(key), Some(count), None) = (parts.next(), parts.next(), parts.next()) else {
            continue; // a malformed line is dropped, never fatal
        };
        let Some(key) = BlobKey::from_hex(key) else { continue };
        let Ok(count) = count.parse::<u32>() else { continue };
        if count > 0 {
            out.insert(key, count);
        }
    }
    Ok(out)
}
