//! The only storage the queue needs: four operations on byte keys.
//!
//! This is the shape of `wa:kernel/kv` (`get`/`set`/`delete`/`scan`), minus the grant model: the
//! queue never decides *whose* namespace it writes in, the host does by handing it one. A scan is
//! ordered by key (the kernel's `kv.scan` contract), which is what makes the ready index sort:
//! priority first, then FIFO.

use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};

/// One page of a scan: `(key, value)` pairs ordered by key.
pub type Entries = Vec<(Vec<u8>, Vec<u8>)>;

/// The storage the queue is built on. Implementations must be single-writer (the queue assumes
/// nobody else mutates the keys under its prefix) and scans must return keys in ascending byte
/// order — the ready index relies on it for priority/FIFO ordering.
pub trait Kv {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, KvError>;
    fn put(&self, key: &[u8], value: &[u8]) -> Result<(), KvError>;
    fn del(&self, key: &[u8]) -> Result<(), KvError>;
    /// Every (key, value) whose key starts with `prefix`, ordered by key.
    fn scan_prefix(&self, prefix: &[u8]) -> Result<Entries, KvError>;
}

/// A storage failure, carried through as text. The queue never invents storage semantics: a failed
/// `put` is an error, never a silent success.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KvError(pub String);

impl KvError {
    pub fn new(reason: impl Into<String>) -> Self {
        Self(reason.into())
    }
}

impl std::fmt::Display for KvError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "kv: {}", self.0)
    }
}

impl std::error::Error for KvError {}

/// In-memory [`Kv`], for tests and for a host that has not wired a durable namespace yet.
///
/// Clones share one map, so a "restart" in a test is a new `Queue` over the same `MemoryKv`.
#[derive(Clone, Default)]
pub struct MemoryKv {
    inner: Arc<Mutex<BTreeMap<Vec<u8>, Vec<u8>>>>,
}

impl MemoryKv {
    pub fn new() -> Self {
        Self::default()
    }

    /// Number of stored keys. For assertions about what the queue really wrote.
    pub fn len(&self) -> usize {
        self.inner.lock().expect("memory kv poisoned").len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Raw key/value pairs, ordered. Tests use this to simulate a crash between two writes.
    pub fn entries(&self) -> Entries {
        self.inner
            .lock()
            .expect("memory kv poisoned")
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
    }

    /// Delete one exact key, bypassing the queue. Only for crash/repair tests.
    pub fn remove_raw(&self, key: &[u8]) -> bool {
        self.inner
            .lock()
            .expect("memory kv poisoned")
            .remove(key)
            .is_some()
    }

    /// Write one exact key/value, bypassing the queue. Only for crash/repair tests.
    pub fn put_raw(&self, key: &[u8], value: &[u8]) {
        self.inner
            .lock()
            .expect("memory kv poisoned")
            .insert(key.to_vec(), value.to_vec());
    }
}

impl Kv for MemoryKv {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, KvError> {
        Ok(self
            .inner
            .lock()
            .expect("memory kv poisoned")
            .get(key)
            .cloned())
    }

    fn put(&self, key: &[u8], value: &[u8]) -> Result<(), KvError> {
        self.inner
            .lock()
            .expect("memory kv poisoned")
            .insert(key.to_vec(), value.to_vec());
        Ok(())
    }

    fn del(&self, key: &[u8]) -> Result<(), KvError> {
        self.inner.lock().expect("memory kv poisoned").remove(key);
        Ok(())
    }

    fn scan_prefix(&self, prefix: &[u8]) -> Result<Entries, KvError> {
        Ok(self
            .inner
            .lock()
            .expect("memory kv poisoned")
            .range(prefix.to_vec()..)
            .take_while(|(k, _)| k.starts_with(prefix))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect())
    }
}

/// Namespaced view of another [`Kv`]: every key the queue writes gains `prefix`, and scans strip it
/// again. One `wa:queue` per component namespace is the intended use.
pub struct Prefixed<K: Kv> {
    pub inner: K,
    pub prefix: Vec<u8>,
}

impl<K: Kv> Prefixed<K> {
    pub fn new(inner: K, prefix: impl Into<Vec<u8>>) -> Self {
        Self {
            inner,
            prefix: prefix.into(),
        }
    }
}

impl<K: Kv> Kv for Prefixed<K> {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, KvError> {
        self.inner.get(&self.key(key))
    }

    fn put(&self, key: &[u8], value: &[u8]) -> Result<(), KvError> {
        self.inner.put(&self.key(key), value)
    }

    fn del(&self, key: &[u8]) -> Result<(), KvError> {
        self.inner.del(&self.key(key))
    }

    fn scan_prefix(&self, prefix: &[u8]) -> Result<Entries, KvError> {
        let mut full = self.prefix.clone();
        full.extend_from_slice(prefix);
        let mut out = Vec::new();
        for (key, value) in self.inner.scan_prefix(&full)? {
            out.push((key[self.prefix.len()..].to_vec(), value));
        }
        Ok(out)
    }
}

impl<K: Kv> Prefixed<K> {
    fn key(&self, key: &[u8]) -> Vec<u8> {
        let mut out = self.prefix.clone();
        out.extend_from_slice(key);
        out
    }
}
