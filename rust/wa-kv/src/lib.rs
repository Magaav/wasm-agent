//! `wa-kv` — the one host store, seen through the three kv traits the libraries expect.
//!
//! The kernel already has a kv: one SQLite file per component (`<components>/<name>.state/kv.sqlite`,
//! `rust/wa-host/src/service_io.rs`). Three libraries want to live on it, and each declared its own
//! trait for the four operations it needs:
//!
//! | crate | trait | receiver | why |
//! | --- | --- | --- | --- |
//! | `wa-queue` | `Kv` | `&self` | the queue holds `Arc<dyn Kv>` and is used from several host calls |
//! | `wa-bus` | `Kv` | `&self`, `Send + Sync` | durable topics are written from a publisher inside the bus lock |
//! | `wa-state` | `Kv` | `&mut self` | the migrator is a single-writer engine and says so |
//!
//! Rather than fork the kernel's store three times, this crate has one [`Store`] trait (the host
//! implements it once, over the connection it already has), one in-memory [`MemoryStore`] for tests,
//! and [`Namespaced`]: a prefixed view of a store that implements **all three** library traits.
//! Two namespaces over one store cannot see each other's keys, and a scan never crosses the prefix,
//! which is what gives a component (and a queue or a durable bus topic inside it) its own world.
//!
//! Key layout, and why it is a prefix and not a second file: `wa:kernel/kv` is per component and is
//! the grant boundary (`docs/STATE.md`, "One namespace, one owner, one version"). Everything this
//! adapter hands to a library lives below one prefix:
//!
//! ```text
//! <component>/          the component's own kv, as wa:kernel/kv sees it (wa-state's namespace)
//! <component>/q/        wa-queue job records, index, dedupe, progress, alerts
//! <component>/b/        wa-bus durable-topic retention records
//! <component>/__wa/     wa-state's host-owned meta keys (never visible to the component)
//! ```
//!
//! `docs/QUEUE.md` (item 1 and 6), `docs/BUS.md` ("Retention via wa:kernel/kv") and the host
//! integration in `docs/STATE.md` are the documents this crate serves. Ordering and paging are the
//! store's job: `scan_prefix` must return keys in ascending byte order, because the queue's ready
//! index *is* that order (priority then FIFO).

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

/// One page of `(key, value)` pairs, as a store returns them: ordered by key.
pub type Entries = Vec<(Vec<u8>, Vec<u8>)>;

/// The store the host already has: four operations and a paged scan, all fallible.
///
/// `&self` (not `&mut self`) because the three library traits disagree about the receiver and a
/// queue or a bus is used from more than one host call at a time; an implementation that needs
/// mutable access to a connection takes it under its own mutex.
///
/// Errors are text, and they must be *reported*: every library here treats a failed write as a
/// failure of the operation, never as a silent no-op.
pub trait Store: Send + Sync {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, String>;
    fn put(&self, key: &[u8], value: &[u8]) -> Result<(), String>;
    fn del(&self, key: &[u8]) -> Result<(), String>;
    /// Delete every entry under `prefix`; returns how many were removed.
    fn delete_prefix(&self, prefix: &[u8]) -> Result<u64, String>;
    /// Entries whose key starts with `prefix`, ordered by key, after `cursor` (exclusive).
    /// `limit == 0` means "one page of the implementation's own size"; the default below is the
    /// reference behaviour and is what [`MemoryStore`] uses.
    fn scan_page(
        &self,
        prefix: &[u8],
        cursor: Option<&[u8]>,
        limit: usize,
    ) -> Result<Entries, String>;
}

/// Every entry under `prefix`, by paging a [`Store`] until it is exhausted.
///
/// The library traits want a whole prefix (`scan_prefix`), the host store wants a page (`scan_page`,
/// the same cursor shape as `wa:kernel/kv.scan`). This is the loop in one place, so the queue, the
/// bus and the state crate cannot each get the cursor arithmetic subtly wrong.
pub fn scan_all<S: Store + ?Sized>(store: &S, prefix: &[u8], page: usize) -> Result<Entries, String> {
    let page = page.max(1);
    let mut out: Entries = Vec::new();
    let mut cursor: Option<Vec<u8>> = None;
    loop {
        let chunk = store.scan_page(prefix, cursor.as_deref(), page)?;
        let done = chunk.len() < page;
        match chunk.last() {
            Some((key, _)) => cursor = Some(key.clone()),
            None => {
                if done {
                    return Ok(out);
                }
                // An empty page before the prefix is exhausted means the store's cursor moved
                // without yielding a row; stop rather than spin.
                return Ok(out);
            }
        }
        out.extend(chunk);
        if done {
            return Ok(out);
        }
    }
}

/// An in-memory [`Store`]: the reference behaviour for ordering, paging and namespacing, and what
/// the tests of every crate above this one use instead of a database file.
#[derive(Debug, Default)]
pub struct MemoryStore {
    map: Mutex<BTreeMap<Vec<u8>, Vec<u8>>>,
}

impl MemoryStore {
    pub fn new() -> MemoryStore {
        MemoryStore::default()
    }

    /// Number of stored keys, across every namespace.
    pub fn len(&self) -> usize {
        self.lock().len()
    }

    pub fn is_empty(&self) -> bool {
        self.lock().is_empty()
    }

    /// Raw key/value pairs of the whole store, ordered. Tests assert on these to prove that a
    /// namespace really wrote under its prefix (and nowhere else).
    pub fn entries(&self) -> Entries {
        self.lock().iter().map(|(k, v)| (k.clone(), v.clone())).collect()
    }

    /// Every key, ordered. A test that says "only these keys exist" is stronger than one that reads
    /// four known keys back.
    pub fn keys(&self) -> Vec<Vec<u8>> {
        self.lock().keys().cloned().collect()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, BTreeMap<Vec<u8>, Vec<u8>>> {
        self.map.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Store for MemoryStore {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, String> {
        Ok(self.lock().get(key).cloned())
    }

    fn put(&self, key: &[u8], value: &[u8]) -> Result<(), String> {
        self.lock().insert(key.to_vec(), value.to_vec());
        Ok(())
    }

    fn del(&self, key: &[u8]) -> Result<(), String> {
        self.lock().remove(key);
        Ok(())
    }

    fn delete_prefix(&self, prefix: &[u8]) -> Result<u64, String> {
        let keys: Vec<Vec<u8>> = self
            .lock()
            .range(prefix.to_vec()..)
            .take_while(|(k, _)| k.starts_with(prefix))
            .map(|(k, _)| k.clone())
            .collect();
        let mut map = self.lock();
        for key in &keys {
            map.remove(key);
        }
        Ok(keys.len() as u64)
    }

    fn scan_page(
        &self,
        prefix: &[u8],
        cursor: Option<&[u8]>,
        limit: usize,
    ) -> Result<Entries, String> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let map = self.lock();
        // A cursor below the prefix would stop `take_while` at the first key below the prefix; the
        // caller asks for "after this key, under this prefix", so clamp to the prefix.
        let start = match cursor {
            Some(cursor) if cursor >= prefix => {
                std::ops::Bound::Excluded(cursor.to_vec())
            }
            _ => std::ops::Bound::Included(prefix.to_vec()),
        };
        Ok(map
            .range((start, std::ops::Bound::Unbounded))
            .take_while(|(k, _)| k.starts_with(prefix))
            .take(limit)
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect())
    }
}

/// A prefixed view of a [`Store`]: every key gains `prefix` on the way down, every key loses it on
/// the way up, and no operation can reach outside it.
///
/// This is the grant boundary the three libraries share. `wa-queue` keeps its invariants by being
/// the only writer of the keys under its prefix; `wa-bus`'s durable topics and `wa-state`'s
/// namespace get the same guarantee from the same type. One component, one prefix, no exceptions:
/// a component's own `wa:kernel/kv` must not overlap a namespace the host serves a library from
/// (`docs/QUEUE.md`, item 3), which is why the prefixes below are not reachable by a component's
/// ordinary keys.
pub struct Namespaced<S: Store + ?Sized> {
    inner: Arc<S>,
    prefix: Vec<u8>,
}

// Hand-written so a clone does not require `S: Clone`: the store is shared through the `Arc`, and
// cloning a namespace is cloning a view (the host hands the queue one and the bus another).
impl<S: Store + ?Sized> Clone for Namespaced<S> {
    fn clone(&self) -> Namespaced<S> {
        Namespaced { inner: self.inner.clone(), prefix: self.prefix.clone() }
    }
}

impl<S: Store + ?Sized> Namespaced<S> {
    pub fn new(inner: Arc<S>, prefix: impl Into<Vec<u8>>) -> Namespaced<S> {
        Namespaced { inner, prefix: prefix.into() }
    }

    pub fn prefix(&self) -> &[u8] {
        &self.prefix
    }

    pub fn inner(&self) -> &Arc<S> {
        &self.inner
    }

    /// A child namespace under this one. `child("q/")` is heads-down its own namespace: it cannot
    /// read a key its parent wrote outside that prefix.
    pub fn child(&self, suffix: impl AsRef<[u8]>) -> Namespaced<S> {
        let mut prefix = self.prefix.clone();
        prefix.extend_from_slice(suffix.as_ref());
        Namespaced { inner: self.inner.clone(), prefix }
    }

    fn key(&self, key: &[u8]) -> Vec<u8> {
        let mut full = self.prefix.clone();
        full.extend_from_slice(key);
        full
    }

    fn strip(&self, key: &[u8]) -> Vec<u8> {
        key[self.prefix.len().min(key.len())..].to_vec()
    }

    /// The store's own name for a key inside this namespace (for a log line that names a key the
    /// component chose - never its value).
    pub fn physical(&self, key: &[u8]) -> Vec<u8> {
        self.key(key)
    }

    pub fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, String> {
        self.inner.get(&self.key(key))
    }

    pub fn put(&self, key: &[u8], value: &[u8]) -> Result<(), String> {
        self.inner.put(&self.key(key), value)
    }

    pub fn del(&self, key: &[u8]) -> Result<(), String> {
        self.inner.del(&self.key(key))
    }

    pub fn delete_prefix(&self, prefix: &[u8]) -> Result<u64, String> {
        self.inner.delete_prefix(&self.key(prefix))
    }

    /// Every entry under `prefix` in this namespace, ordered by key, prefix stripped. The store is
    /// read page by page, so a namespace larger than one page is still one correct answer.
    pub fn scan_prefix(&self, prefix: &[u8]) -> Result<Entries, String> {
        let full = self.key(prefix);
        Ok(scan_all(&*self.inner, &full, PAGE)?
            .into_iter()
            .map(|(k, v)| (self.strip(&k), v))
            .collect())
    }

    pub fn scan_page(
        &self,
        prefix: &[u8],
        cursor: Option<&[u8]>,
        limit: usize,
    ) -> Result<Entries, String> {
        let full = self.key(prefix);
        let cursor = cursor.map(|c| self.key(c));
        Ok(self
            .inner
            .scan_page(&full, cursor.as_deref(), limit)?
            .into_iter()
            .map(|(k, v)| (self.strip(&k), v))
            .collect())
    }

    /// Every key in this namespace, ordered, prefix stripped. Tests use it to say "the queue wrote
    /// under `q/` and nothing else".
    pub fn keys(&self) -> Result<Vec<Vec<u8>>, String> {
        Ok(scan_all(&*self.inner, &self.prefix, PAGE)?
            .into_iter()
            .map(|(k, _)| self.strip(&k))
            .collect())
    }
}

/// How many entries [`Namespaced`] asks the store for per page when the caller wants a whole prefix.
/// The same page size `wa_kernel`'s `kv.scan` uses as a default, so one page is one round trip.
const PAGE: usize = 512;

// ---- the three library traits, one implementation --------------------------------------------------

impl<S: Store + ?Sized> wa_queue::Kv for Namespaced<S> {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, wa_queue::KvError> {
        Namespaced::get(self, key).map_err(wa_queue::KvError)
    }

    fn put(&self, key: &[u8], value: &[u8]) -> Result<(), wa_queue::KvError> {
        Namespaced::put(self, key, value).map_err(wa_queue::KvError)
    }

    fn del(&self, key: &[u8]) -> Result<(), wa_queue::KvError> {
        Namespaced::del(self, key).map_err(wa_queue::KvError)
    }

    /// Ordered by key: the queue's ready index relies on it for priority-then-FIFO order.
    fn scan_prefix(&self, prefix: &[u8]) -> Result<wa_queue::Entries, wa_queue::KvError> {
        Namespaced::scan_prefix(self, prefix).map_err(wa_queue::KvError)
    }
}

impl<S: Store + ?Sized> wa_bus::Kv for Namespaced<S> {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, wa_bus::KvError> {
        Namespaced::get(self, key).map_err(into_bus_error)
    }

    fn put(&self, key: &[u8], value: &[u8]) -> Result<(), wa_bus::KvError> {
        Namespaced::put(self, key, value).map_err(into_bus_error)
    }

    fn del(&self, key: &[u8]) -> Result<(), wa_bus::KvError> {
        Namespaced::del(self, key).map_err(into_bus_error)
    }

    fn scan_prefix(&self, prefix: &[u8], limit: usize) -> Result<wa_bus::KvEntries, wa_bus::KvError> {
        let mut entries = Namespaced::scan_prefix(self, prefix).map_err(into_bus_error)?;
        if limit != 0 && entries.len() > limit {
            entries.truncate(limit);
        }
        Ok(entries)
    }
}

impl<S: Store + ?Sized> wa_state::Kv for Namespaced<S> {
    fn get(&mut self, key: &[u8]) -> wa_state::Result<Option<Vec<u8>>> {
        Namespaced::get(self, key).map_err(wa_state::Error::Kv)
    }

    fn put(&mut self, key: &[u8], value: &[u8]) -> wa_state::Result<()> {
        Namespaced::put(self, key, value).map_err(wa_state::Error::Kv)
    }

    fn del(&mut self, key: &[u8]) -> wa_state::Result<()> {
        Namespaced::del(self, key).map_err(wa_state::Error::Kv)
    }

    fn scan_prefix(&mut self, prefix: &[u8]) -> wa_state::Result<Entries> {
        Namespaced::scan_prefix(self, prefix).map_err(wa_state::Error::Kv)
    }

    /// Native paging: the host store already has a cursor, so an export does not have to hold a
    /// whole namespace in memory (`docs/STATE.md`, snapshots).
    fn scan_page(
        &mut self,
        prefix: &[u8],
        cursor: Option<&[u8]>,
        limit: usize,
    ) -> wa_state::Result<Entries> {
        Namespaced::scan_page(self, prefix, cursor, limit).map_err(wa_state::Error::Kv)
    }

    fn del_prefix(&mut self, prefix: &[u8]) -> wa_state::Result<u64> {
        Namespaced::delete_prefix(self, prefix).map_err(wa_state::Error::Kv)
    }
}

fn into_bus_error(error: String) -> wa_bus::KvError {
    Box::new(StoreError(error))
}

/// A store failure as an `std::error::Error`, so it can travel through `wa_bus::KvError` (a boxed
/// error) without inventing a second string type.
#[derive(Debug)]
pub struct StoreError(pub String);

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "store: {}", self.0)
    }
}

impl std::error::Error for StoreError {}

#[cfg(test)]
mod tests;
