//! The `__wa/` guard in front of a component's own kv (`docs/STATE.md`, "One namespace, one owner,
//! one version").
//!
//! A component's `wa:kernel/kv` and the host's state machine are the *same* SQLite file: the
//! component's own keys and the host-owned meta keys (`__wa/meta/schema`, `.../component`,
//! `.../migration/journal`, ...) live in one namespace, and the meta keys are what decides which
//! migration has already run. A component that could read them could learn another build's business;
//! a component that could write `__wa/meta/schema` could skip a migration, and one that could write
//! the journal could make the next upgrade replay someone else's writes (`rust/wa-state`'s
//! `Error::Reserved`, which says exactly this).
//!
//! `rust/wa-state` already has the reference answer as a library view ([`wa_state::UserView`]): reads
//! of a meta key are not-found, writes are refused, and a scan filters them out. `docs/STATE.md`
//! names the missing half - *"the host broker must enforce the same refusal for `wa:kernel/kv`; today
//! the library enforces it, the WIT host does not yet"*. This module is that half, and it is one
//! module rather than two so the WASI 0.2 (polling) and WASI 0.3 (async) runners cannot drift:
//!
//! | call | a key under `__wa/` | any other key |
//! | --- | --- | --- |
//! | `get` | `Ok(None)` - not found, never a value | the store's answer |
//! | `set` / `delete` | `Err(`[`RESERVED`]`)` - a refusal the guest can log | the store's answer |
//! | `delete_prefix` | `Err(RESERVED)` when the prefix *is* reserved; when a prefix merely *covers* `__wa/` (`""`, `"_"`), only the guest's own keys under it are deleted and the count says how many | the store's answer |
//! | `scan` | skipped; the page is filled from further pages so a guest never sees a short page | the store's answer |
//!
//! Two deliberate asymmetries, both from `UserView`: a *read* of a meta key is not-found rather than a
//! refusal (a component probing a key it does not own learns nothing, not even "that exists"), and a
//! covering `delete_prefix` filters instead of refusing, so "wipe my namespace" stays one call that
//! cannot take the host's meta keys with it. A `delete_prefix` *aimed at* `__wa/` refuses: a no-op
//! success there would be a silent success (`AGENTS.md`).
//!
//! The host keeps full access: `state_host.rs` writes and reads the same keys through
//! `wa_state`/`wa_kv` and never comes through here. Neither does any future host-side caller - the
//! guard is a wrapper, not a change to [`crate::service_io::Kv`].

use crate::service_io::{Entry, Kv as KvStore};

/// The reserved prefix, from its one definition (`wa_state::meta::RESERVED_PREFIX`, `b"__wa/"`).
pub const RESERVED_PREFIX: &[u8] = wa_state::meta::RESERVED_PREFIX;

/// The refusal word a guest sees for a write aimed at `__wa/`. It is a stable word, like the
/// `docs/GRANT-POLICY.md` reason words, so a component log and an audit line can be searched for it.
pub const RESERVED: &str = "reserved_prefix";

/// Is this key (or prefix) inside the host-owned part of the namespace?
pub fn is_reserved(key: &[u8]) -> bool {
    wa_state::meta::is_reserved(key)
}

/// Does the set of keys under `prefix` include a host-owned key? True when one of the two is a
/// prefix of the other: `""` and `"__w"` cover `__wa/`, and `"__wa/meta"` sits inside it.
fn covers_reserved(prefix: &[u8]) -> bool {
    RESERVED_PREFIX.starts_with(prefix) || prefix.starts_with(RESERVED_PREFIX)
}

/// The same page size [`KvStore::scan`] clamps to, so the page-filling loop below asks the store for
/// exactly the page the guest asked for.
const MAX_PAGE: u32 = 10_000;

/// A component's kv as `wa:kernel/kv` is allowed to see it: the store, with the host's `__wa/` keys
/// filtered, hidden or refused. Both runners hold one of these instead of a bare [`KvStore`].
pub struct GuestKv(KvStore);

impl GuestKv {
    pub fn new(inner: KvStore) -> GuestKv {
        GuestKv(inner)
    }

    /// The store, for a host-side caller that is not a guest. Nothing in the runners uses this; it
    /// exists so a diagnostic that must count *all* keys does not have to reach around the guard.
    pub fn store_mut(&mut self) -> &mut KvStore {
        &mut self.0
    }

    /// A read of a host-owned key is not-found: the guest's namespace does not have that key.
    pub fn get(&mut self, key: Vec<u8>) -> Result<Option<Vec<u8>>, String> {
        if is_reserved(&key) {
            return Ok(None);
        }
        self.0.get(key)
    }

    pub fn set(&mut self, key: Vec<u8>, value: Vec<u8>) -> Result<(), String> {
        if is_reserved(&key) {
            return Err(RESERVED.to_string());
        }
        self.0.set(key, value)
    }

    pub fn delete(&mut self, key: Vec<u8>) -> Result<(), String> {
        if is_reserved(&key) {
            return Err(RESERVED.to_string());
        }
        self.0.delete(key)
    }

    /// Delete the guest's own keys under `prefix`, and only those.
    ///
    /// A prefix that covers `__wa/` (`""` above all) cannot use the store's range delete - that would
    /// take the host's meta keys with it, and the next upgrade would find a namespace with no schema
    /// version - so it walks the visible keys page by page and deletes them one at a time. A prefix
    /// that names the host's keys refuses.
    pub fn delete_prefix(&mut self, prefix: Vec<u8>) -> Result<u32, String> {
        if is_reserved(&prefix) {
            return Err(RESERVED.to_string());
        }
        if !covers_reserved(&prefix) {
            return self.0.delete_prefix(prefix);
        }
        let mut removed: u32 = 0;
        let mut cursor: Option<Vec<u8>> = None;
        loop {
            let page = self.scan(prefix.clone(), cursor.clone(), 512)?;
            let Some((last, _)) = page.last() else { break };
            cursor = Some(last.clone());
            for (key, _) in page {
                self.0.delete(key)?;
                removed = removed.saturating_add(1);
            }
        }
        Ok(removed)
    }

    /// One page of the guest's own entries, ordered by key, after `cursor` (exclusive).
    ///
    /// The guest's rule is "an empty page means the end" (`wit/kernel/kernel.wit`), so a page that
    /// lost entries to the reserved filter must be topped up from the next page: `__wa/...` sorts
    /// before most of a guest's keys, so a naive filter would end a full scan at its first page.
    pub fn scan(&mut self, prefix: Vec<u8>, cursor: Option<Vec<u8>>, limit: u32) -> Result<Vec<Entry>, String> {
        let limit = limit.clamp(1, MAX_PAGE);
        let mut out: Vec<Entry> = Vec::with_capacity((limit as usize).min(512));
        let mut cursor = cursor;
        loop {
            let want = limit - out.len() as u32;
            let page = self.0.scan(prefix.clone(), cursor.clone(), want)?;
            let exhausted = page.len() < want as usize;
            match page.last() {
                Some((last, _)) => cursor = Some(last.clone()),
                None => return Ok(out),
            }
            out.extend(page.into_iter().filter(|(key, _)| !is_reserved(key)));
            if exhausted || out.len() >= limit as usize {
                return Ok(out);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::service_io::Kv as KvStore;

    /// A store in a directory of its own, with a pre-seeded host-owned part: exactly what a
    /// component's `kv.sqlite` looks like after one host install.
    fn store(tag: &str) -> (std::path::PathBuf, GuestKv) {
        let dir = std::env::temp_dir().join(format!("wa-guest-kv-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("kv.sqlite");
        let mut raw = KvStore::new(Some(path.clone()));
        raw.set(b"__wa/meta/schema".to_vec(), b"v3".to_vec()).unwrap();
        raw.set(b"__wa/meta/component".to_vec(), b"graph".to_vec()).unwrap();
        raw.set(b"ses/one".to_vec(), b"1".to_vec()).unwrap();
        raw.set(b"ses/two".to_vec(), b"2".to_vec()).unwrap();
        (dir, GuestKv::new(KvStore::new(Some(path))))
    }

    /// A guest read of a meta key is not-found, and its own key still answers.
    #[test]
    fn get_hides_the_reserved_prefix() {
        let (dir, mut kv) = store("get");
        assert_eq!(kv.get(b"__wa/meta/schema".to_vec()).unwrap(), None);
        assert_eq!(kv.get(b"__wa/".to_vec()).unwrap(), None);
        assert_eq!(kv.get(b"__wa".to_vec()).unwrap(), None, "the prefix without its slash is the guest's own key");
        assert_eq!(kv.get(b"ses/one".to_vec()).unwrap(), Some(b"1".to_vec()));
        std::fs::remove_dir_all(dir).ok();
    }

    /// A guest write to a meta key is refused with the stable word, and nothing is written: the host's
    /// schema version is still what the host wrote.
    #[test]
    fn set_refuses_the_reserved_prefix() {
        let (dir, mut kv) = store("set");
        match kv.set(b"__wa/meta/schema".to_vec(), b"v1".to_vec()) {
            Err(error) => assert_eq!(error, RESERVED),
            Ok(()) => panic!("a write to a host-owned key must be refused"),
        }
        assert_eq!(kv.store_mut().get(b"__wa/meta/schema".to_vec()).unwrap(), Some(b"v3".to_vec()));
        // A key that merely starts with the same bytes is the guest's own.
        kv.set(b"__wax".to_vec(), b"fine".to_vec()).unwrap();
        assert_eq!(kv.get(b"__wax".to_vec()).unwrap(), Some(b"fine".to_vec()));
        std::fs::remove_dir_all(dir).ok();
    }

    /// A guest delete of a meta key is refused, and the key survives.
    #[test]
    fn delete_refuses_the_reserved_prefix() {
        let (dir, mut kv) = store("delete");
        match kv.delete(b"__wa/meta/component".to_vec()) {
            Err(error) => assert_eq!(error, RESERVED),
            Ok(()) => panic!("a delete of a host-owned key must be refused"),
        }
        assert_eq!(kv.store_mut().get(b"__wa/meta/component".to_vec()).unwrap(), Some(b"graph".to_vec()));
        kv.delete(b"ses/two".to_vec()).unwrap();
        assert_eq!(kv.get(b"ses/two".to_vec()).unwrap(), None);
        std::fs::remove_dir_all(dir).ok();
    }

    /// `delete_prefix` refuses a prefix inside `__wa/`, deletes the guest's keys under a prefix that
    /// covers it, and never removes a host-owned key on the way.
    #[test]
    fn delete_prefix_stops_at_the_reserved_prefix() {
        let (dir, mut kv) = store("delete-prefix");
        match kv.delete_prefix(b"__wa/".to_vec()) {
            Err(error) => assert_eq!(error, RESERVED),
            Ok(n) => panic!("a delete_prefix aimed at the meta keys must be refused, not delete {n}"),
        }
        match kv.delete_prefix(b"__wa/meta".to_vec()) {
            Err(error) => assert_eq!(error, RESERVED),
            Ok(n) => panic!("a delete_prefix inside the meta keys must be refused, not delete {n}"),
        }
        assert_eq!(kv.store_mut().get(b"__wa/meta/schema".to_vec()).unwrap(), Some(b"v3".to_vec()));

        // A covering prefix deletes the guest's keys under it and reports how many.
        assert_eq!(kv.delete_prefix(b"ses/".to_vec()).unwrap(), 2);
        assert_eq!(kv.scan(Vec::new(), None, 100).unwrap().len(), 0);
        // ... and a full wipe keeps the host's keys and says what it removed.
        kv.set(b"pk/a".to_vec(), b"a".to_vec()).unwrap();
        assert_eq!(kv.delete_prefix(Vec::new()).unwrap(), 1);
        assert_eq!(kv.store_mut().get(b"__wa/meta/schema".to_vec()).unwrap(), Some(b"v3".to_vec()));
        assert_eq!(kv.store_mut().get(b"__wa/meta/component".to_vec()).unwrap(), Some(b"graph".to_vec()));
        std::fs::remove_dir_all(dir).ok();
    }

    /// A scan never returns a meta key, and a page that the filter empties is topped up, so
    /// `limit = 1` over a namespace whose first key is `__wa/` still finds the guest's data.
    #[test]
    fn scan_skips_the_reserved_prefix_without_shortening_the_page() {
        let (dir, mut kv) = store("scan");
        let all = kv.scan(Vec::new(), None, 100).unwrap();
        assert_eq!(all, vec![(b"ses/one".to_vec(), b"1".to_vec()), (b"ses/two".to_vec(), b"2".to_vec())]);

        // `__wa/...` sorts first, so the first raw page is entirely reserved: the page must still be
        // one visible entry, not an empty page the guest reads as the end.
        let first = kv.scan(Vec::new(), None, 1).unwrap();
        assert_eq!(first, vec![(b"ses/one".to_vec(), b"1".to_vec())]);
        let second = kv.scan(Vec::new(), Some(b"ses/one".to_vec()), 1).unwrap();
        assert_eq!(second, vec![(b"ses/two".to_vec(), b"2".to_vec())]);
        // A cursor the guest could only have got from a visible key still pages cleanly.
        let third = kv.scan(Vec::new(), Some(b"ses/two".to_vec()), 1).unwrap();
        assert!(third.is_empty(), "the scan ended after the last visible key: {third:?}");
        // A prefix inside the meta keys is simply empty, never a refusal.
        assert!(kv.scan(b"__wa/".to_vec(), None, 10).unwrap().is_empty());
        std::fs::remove_dir_all(dir).ok();
    }
}
