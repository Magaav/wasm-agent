//! The store this crate runs over: four operations and a paged scan.
//!
//! It is intentionally smaller than the host's kv: `get`/`put`/`del`/`scan_prefix` are enough for
//! every rule in `docs/STATE.md`, and the paged `scan_page` (with the same cursor shape as
//! `wa:kernel/kv.scan`) is the one addition a snapshot needs so export does not have to hold a whole
//! namespace in memory.

use crate::meta::is_reserved;
use crate::{check_size, Error, Result};
use std::collections::BTreeMap;
use std::ops::Bound;

/// A component's kv namespace. Implementations should treat keys and values as opaque bytes; the
/// host's SQLite store does, and so does [`MemKv`].
///
/// Errors must be *reported*, never swallowed: a migration decides whether to continue or resume
/// from whether a write failed, so a silent no-op here would be a silent state loss.
pub trait Kv {
    fn get(&mut self, key: &[u8]) -> Result<Option<Vec<u8>>>;
    fn put(&mut self, key: &[u8], value: &[u8]) -> Result<()>;
    fn del(&mut self, key: &[u8]) -> Result<()>;
    /// Every entry whose key starts with `prefix`, ordered by key. The empty prefix is a full scan.
    fn scan_prefix(&mut self, prefix: &[u8]) -> Result<Vec<(Vec<u8>, Vec<u8>)>>;

    /// One page after `cursor` (exclusive; `None` from the start). The default walks
    /// [`Kv::scan_prefix`], so an implementation that can page natively (the host's `wa:kernel/kv`
    /// can) should override it; the default exists so a minimal store still satisfies the trait.
    fn scan_page(
        &mut self,
        prefix: &[u8],
        cursor: Option<&[u8]>,
        limit: usize,
    ) -> Result<Vec<(Vec<u8>, Vec<u8>)>> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let mut out = Vec::new();
        for (key, value) in self.scan_prefix(prefix)? {
            if let Some(cursor) = cursor {
                if key.as_slice() <= cursor {
                    continue;
                }
            }
            out.push((key, value));
            if out.len() == limit {
                break;
            }
        }
        Ok(out)
    }

    /// Delete every entry under `prefix`, returning how many were removed. Implementations with a
    /// native range delete should override it; the default is what the host's kv does per key.
    fn del_prefix(&mut self, prefix: &[u8]) -> Result<u64> {
        let entries = self.scan_prefix(prefix)?;
        let mut removed = 0;
        for (key, _) in entries {
            self.del(&key)?;
            removed += 1;
        }
        Ok(removed)
    }
}

/// An in-memory namespace: the test double, and the reference implementation of the trait's
/// ordering guarantees.
///
/// It can also fail on purpose. [`MemKv::set_write_budget`] makes the n-th mutating call return
/// [`Error::Injected`], which is how the crash/resume tests put a crash at *every* point of a
/// migration instead of at the one point a human guessed.
#[derive(Clone, Debug, Default)]
pub struct MemKv {
    entries: BTreeMap<Vec<u8>, Vec<u8>>,
    writes: u64,
    budget: Option<u64>,
}

impl MemKv {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn from_entries<K, V>(entries: impl IntoIterator<Item = (K, V)>) -> Self
    where
        K: Into<Vec<u8>>,
        V: Into<Vec<u8>>,
    {
        Self {
            entries: entries.into_iter().map(|(k, v)| (k.into(), v.into())).collect(),
            writes: 0,
            budget: None,
        }
    }

    pub fn entries(&self) -> &BTreeMap<Vec<u8>, Vec<u8>> {
        &self.entries
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// How many `put`/`del` calls this store has accepted. Tests use it to prove a dry run wrote
    /// nothing.
    pub fn writes(&self) -> u64 {
        self.writes
    }

    /// Fault injection: after `budget` mutating calls, every further mutation fails as if the
    /// process had died there. `None` removes the budget. Reads always work, which is what a
    /// resumed process sees: the store survived, the run did not.
    pub fn set_write_budget(&mut self, budget: Option<u64>) {
        self.budget = budget;
    }

    fn mutating(&mut self) -> Result<()> {
        if let Some(budget) = self.budget {
            if self.writes >= budget {
                return Err(Error::Injected("write budget exhausted"));
            }
        }
        self.writes += 1;
        Ok(())
    }
}

impl Kv for MemKv {
    fn get(&mut self, key: &[u8]) -> Result<Option<Vec<u8>>> {
        Ok(self.entries.get(key).cloned())
    }

    fn put(&mut self, key: &[u8], value: &[u8]) -> Result<()> {
        self.mutating()?;
        self.entries.insert(key.to_vec(), value.to_vec());
        Ok(())
    }

    fn del(&mut self, key: &[u8]) -> Result<()> {
        self.mutating()?;
        self.entries.remove(key);
        Ok(())
    }

    fn scan_prefix(&mut self, prefix: &[u8]) -> Result<Vec<(Vec<u8>, Vec<u8>)>> {
        Ok(self
            .entries
            .range(prefix.to_vec()..)
            .take_while(|(key, _)| key.starts_with(prefix))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect())
    }

    fn scan_page(
        &mut self,
        prefix: &[u8],
        cursor: Option<&[u8]>,
        limit: usize,
    ) -> Result<Vec<(Vec<u8>, Vec<u8>)>> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        // A cursor below the prefix would otherwise stop `take_while` at the first key below the
        // prefix; the caller asks for "after this key, under this prefix", so clamp.
        let start = match cursor {
            Some(cursor) if cursor >= prefix => Bound::Excluded(cursor.to_vec()),
            _ => Bound::Included(prefix.to_vec()),
        };
        Ok(self
            .entries
            .range((start, Bound::Unbounded))
            .take_while(|(key, _)| key.starts_with(prefix))
            .take(limit)
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect())
    }

    fn del_prefix(&mut self, prefix: &[u8]) -> Result<u64> {
        let keys: Vec<Vec<u8>> = self
            .entries
            .range(prefix.to_vec()..)
            .take_while(|(key, _)| key.starts_with(prefix))
            .map(|(key, _)| key.clone())
            .collect();
        for key in &keys {
            self.mutating()?;
            self.entries.remove(key);
        }
        Ok(keys.len() as u64)
    }
}

/// The view a component gets of its own namespace: meta keys are invisible, and writing one is
/// refused rather than accepted and hidden. Without this, a component could forge its schema
/// version and make the next upgrade skip a migration.
///
/// It also enforces the host's key/value size limits, so a guest learns "too large" from the same
/// place whether it runs here or through `wa:kernel/kv`.
pub struct UserView<'a> {
    inner: &'a mut dyn Kv,
}

impl<'a> UserView<'a> {
    pub fn new(inner: &'a mut dyn Kv) -> Self {
        Self { inner }
    }

    pub fn inner_mut(&mut self) -> &mut dyn Kv {
        self.inner
    }
}

impl Kv for UserView<'_> {
    fn get(&mut self, key: &[u8]) -> Result<Option<Vec<u8>>> {
        if is_reserved(key) {
            return Ok(None);
        }
        self.inner.get(key)
    }

    fn put(&mut self, key: &[u8], value: &[u8]) -> Result<()> {
        if is_reserved(key) {
            return Err(Error::Reserved);
        }
        check_size(key, Some(value))?;
        self.inner.put(key, value)
    }

    fn del(&mut self, key: &[u8]) -> Result<()> {
        if is_reserved(key) {
            return Err(Error::Reserved);
        }
        self.inner.del(key)
    }

    fn scan_prefix(&mut self, prefix: &[u8]) -> Result<Vec<(Vec<u8>, Vec<u8>)>> {
        // A guest may scan under any prefix, including one that spans `__wa/`; filter, never refuse
        // the scan, so a scan of the empty prefix stays a full scan of *its* data.
        Ok(self
            .inner
            .scan_prefix(prefix)?
            .into_iter()
            .filter(|(key, _)| !is_reserved(key))
            .collect())
    }

    fn del_prefix(&mut self, prefix: &[u8]) -> Result<u64> {
        // `self.scan_prefix` already filtered the meta keys out.
        let keys: Vec<Vec<u8>> = self
            .scan_prefix(prefix)?
            .into_iter()
            .map(|(key, _)| key)
            .collect();
        for key in &keys {
            self.inner.del(key)?;
        }
        Ok(keys.len() as u64)
    }
}
