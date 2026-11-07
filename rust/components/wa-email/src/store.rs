//! The index, over `wa:kernel/kv`.
//!
//! `wa_email_index::Store` is synchronous (it is the shape the ranking rules are tested in), and a
//! kernel kv call is `async`. The bridge is a materialised view: the guest loads the prefixes an
//! operation needs, the pure code works in memory, and [`KvStore::flush`] writes the changes back. The
//! alternative - an async `Store` trait - would make every ranking rule async and untestable natively
//! for no gain: a scan page is 256 entries and an index operation reads one prefix.
//!
//! What is *not* loaded is the mailbox's records while it is indexed: a fetched UID is above the stored
//! sync-state floor, so it is new by construction, and `wa_email_index::index_record` writes it without a
//! read. The one visible consequence is a `email.received` fact repeated if a round indexed a UID and
//! died before storing the floor: the record is still one (the key is one), and a consumer dedupes on
//! `uid` + `uid_validity`, which the payload carries.
//!
//! Every key is inside this component's own namespace (`wa:kernel/kv`, one namespace per component), so
//! the view can never read another component's state, and `delete-prefix` is never needed: a key layout
//! that grows by UIDVALIDITY generation (`wa_email_index::keys`) does not have to be cleared to stay
//! correct.
use std::collections::BTreeSet;

use wa_email_index::{MemoryStore, Store};

use crate::wa::kernel::{kv, types::Error as KError};

/// The in-memory view of this component's kv, plus what still has to be written back.
pub struct KvStore {
    view: MemoryStore,
    dirty: BTreeSet<Vec<u8>>,
    removed: BTreeSet<Vec<u8>>,
    /// Keys already read from kv, so a `get` that found nothing is not re-read every time.
    loaded: BTreeSet<Vec<u8>>,
}

impl Default for KvStore {
    fn default() -> Self {
        KvStore::new()
    }
}

impl KvStore {
    pub fn new() -> KvStore {
        KvStore { view: MemoryStore::default(), dirty: BTreeSet::new(), removed: BTreeSet::new(), loaded: BTreeSet::new() }
    }

    /// Load every entry under `prefix` into the view, at most `max` of them (the same bound the
    /// operation itself applies), page by page through `kv.scan`.
    pub async fn load_prefix(&mut self, prefix: &[u8], max: usize) -> Result<usize, String> {
        let mut cursor: Option<Vec<u8>> = None;
        let mut loaded = 0usize;
        loop {
            let page = kv::scan(prefix.to_vec(), cursor.clone(), 256).await.map_err(error_text)?;
            if page.is_empty() {
                return Ok(loaded);
            }
            cursor = page.last().map(|entry| entry.key.clone());
            for entry in page {
                self.view.set(&entry.key, &entry.value)?;
                self.loaded.insert(entry.key);
                loaded += 1;
                if loaded >= max {
                    return Ok(loaded);
                }
            }
        }
    }

    /// Write every change back. Returns how many kv calls it took, for the log.
    pub async fn flush(&mut self) -> Result<usize, String> {
        let mut calls = 0usize;
        for key in std::mem::take(&mut self.removed) {
            kv::delete(key).await.map_err(error_text)?;
            calls += 1;
        }
        for key in std::mem::take(&mut self.dirty) {
            if let Some(value) = self.view.get(&key) {
                kv::set(key.clone(), value).await.map_err(error_text)?;
                calls += 1;
            }
        }
        Ok(calls)
    }

}

impl Store for KvStore {
    fn get(&self, key: &[u8]) -> Option<Vec<u8>> {
        self.view.get(key)
    }

    fn set(&mut self, key: &[u8], value: &[u8]) -> Result<(), String> {
        self.view.set(key, value)?;
        self.removed.remove(key);
        self.dirty.insert(key.to_vec());
        Ok(())
    }

    fn delete(&mut self, key: &[u8]) -> Result<(), String> {
        self.view.delete(key)?;
        self.dirty.remove(key);
        self.removed.insert(key.to_vec());
        Ok(())
    }

    fn scan(&self, prefix: &[u8], cursor: Option<&[u8]>, limit: u32) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
        self.view.scan(prefix, cursor, limit)
    }
}

/// A `wa:kernel` error as a stable word plus its detail: the caller logs the word, and the detail is
/// the host's own reason (never a payload).
pub fn error_text(error: KError) -> String {
    match error {
        KError::Refused(reason) => format!("kv_refused: {reason}"),
        KError::Again => "kv_again".to_string(),
        KError::Closed => "kv_closed".to_string(),
        KError::Failed(reason) => format!("kv_failed: {reason}"),
    }
}
