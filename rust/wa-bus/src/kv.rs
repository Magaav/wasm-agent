//! Durable topics: last-N retention through a small key-value store.
//!
//! The trait is the same shape as the queue's/`wa:kernel/kv`'s (get / put / del / scan_prefix), so
//! the host can back it with the per-component kv it already has, with SQLite, or with an in-memory
//! map (`MemoryKv`, used by the tests). The bus owns the key layout; a host that wants quota or
//! trimming of its own can read it (see [`retention_prefix`] / [`retention_key`]).
//!
//! Keys are `v1/<topic>/<ts_ms:020>/<id:020>`, so lexicographic order is time order even across a
//! restart, and `scan_prefix("v1/<topic>/")` is the whole retained log of that topic.

use crate::event::EventId;
use crate::topic::Topic;
use std::collections::BTreeMap;
use std::sync::Mutex;

/// A store failure, as the host would report it (`closed`, `quota`, `io`…).
pub type KvError = Box<dyn std::error::Error + Send + Sync>;

/// One page of `(key, value)` pairs, as `scan_prefix` returns them: ordered by key.
pub type KvEntries = Vec<(Vec<u8>, Vec<u8>)>;

/// The small store the durable topics need. Deliberately four methods: this is a last-N cache, not
/// a database, and a bus that needed transactions would be a queue.
pub trait Kv: Send + Sync {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, KvError>;
    fn put(&self, key: &[u8], value: &[u8]) -> Result<(), KvError>;
    fn del(&self, key: &[u8]) -> Result<(), KvError>;
    /// Every pair whose key starts with `prefix`, ordered by key. `limit == 0` means no limit.
    fn scan_prefix(&self, prefix: &[u8], limit: usize) -> Result<KvEntries, KvError>;
}

/// The prefix under which one topic's retained events live.
pub fn retention_prefix(topic: &Topic) -> Vec<u8> {
    format!("v1/{}/", topic.as_str()).into_bytes()
}

/// The retention key of one event.
pub fn retention_key(topic: &Topic, ts_ms: u64, id: EventId) -> Vec<u8> {
    format!("v1/{}/{:020}/{:020}", topic.as_str(), ts_ms, id.0).into_bytes()
}

/// An in-memory [`Kv`]. Useful for tests, for a node that has no durable store, and as the reference
/// behaviour for scan ordering.
#[derive(Debug, Default)]
pub struct MemoryKv {
    map: Mutex<BTreeMap<Vec<u8>, Vec<u8>>>,
}

impl MemoryKv {
    pub fn new() -> MemoryKv {
        MemoryKv::default()
    }

    /// Number of rows stored (test/diagnostic).
    pub fn len(&self) -> usize {
        self.lock().len()
    }

    pub fn is_empty(&self) -> bool {
        self.lock().is_empty()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, BTreeMap<Vec<u8>, Vec<u8>>> {
        self.map.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Kv for MemoryKv {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, KvError> {
        Ok(self.lock().get(key).cloned())
    }

    fn put(&self, key: &[u8], value: &[u8]) -> Result<(), KvError> {
        self.lock().insert(key.to_vec(), value.to_vec());
        Ok(())
    }

    fn del(&self, key: &[u8]) -> Result<(), KvError> {
        self.lock().remove(key);
        Ok(())
    }

    fn scan_prefix(&self, prefix: &[u8], limit: usize) -> Result<KvEntries, KvError> {
        let map = self.lock();
        let mut out = Vec::new();
        for (k, v) in map.range(prefix.to_vec()..) {
            if !k.starts_with(prefix) {
                break;
            }
            if limit != 0 && out.len() >= limit {
                break;
            }
            out.push((k.clone(), v.clone()));
        }
        Ok(out)
    }
}
