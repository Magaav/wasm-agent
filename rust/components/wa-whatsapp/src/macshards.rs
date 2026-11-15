//! App-state mutation MACs as a few kv blobs per collection, not one kv key per MAC.
//!
//! Why this exists (15/11, openclaw): the phone answers the contacts request with a full
//! `critical_unblock_low` snapshot, and wacore persists it as `clear_mutation_macs` +
//! `put_mutation_macs(<every mutation>)` + `set_version`. The store used to write one key per MAC
//! (`mac/<name>/<hex>`), so a snapshot of N contacts was N `kv.write` calls in one burst. The node
//! policy grants this component `kv.write` at 240/min with a burst of 480; the grant-policy audit on
//! openclaw shows `kv.write -> rate_limited(capability_rate_limited)` once per snapshot attempt
//! (~80 writes allowed, then the refusal). The refusal became `StoreError::Io`, whatsapp-rust logged
//! `Failed app state sync for CriticalUnblockLow: I/O error`, the version never advanced, and the
//! address book never reached the index - every attempt, every connection.
//!
//! Here a collection's MACs live in [`SHARDS`] blobs keyed by the high nibble of the index MAC
//! (`mac/<name>~<x>`), so a snapshot of any size costs at most `SHARDS` sets plus the clear, and an
//! incremental patch rewrites only the shards it touches. The keys stay under `mac/` - the prefix the
//! node policy already allows - and the old per-MAC keys (`mac/<name>/<hex>`) are still read, then
//! removed with ONE prefix delete the first time their collection is written again.
//!
//! Pure: this module only plans kv writes and keeps the mirror the blobs are built from; `store.rs`
//! (wasm-only) executes the plan and commits it, so `cargo test` covers the budget natively.
use std::collections::{BTreeMap, HashMap};

/// Blobs per collection. 16 keeps a full snapshot far inside the 480-write burst (16 sets + 2 prefix
/// deletes + the version) while a one-mutation patch rewrites 1/16 of the collection.
pub const SHARDS: usize = 16;

/// Blob format version (first byte of every shard value).
const FORMAT: u8 = 1;

/// One kv call the store must make, in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Write {
    Set(String, Vec<u8>),
    Delete(String),
    DeletePrefix(String),
}

impl Write {
    /// The key (or prefix) this call names, for a log line that must not carry the value.
    pub fn key(&self) -> &str {
        match self {
            Write::Set(k, _) | Write::Delete(k) | Write::DeletePrefix(k) => k,
        }
    }
}

type Shard = BTreeMap<Vec<u8>, Vec<u8>>;

pub fn shard_of(index_mac: &[u8]) -> usize {
    index_mac.first().map(|b| (*b as usize) >> 4).unwrap_or(0) % SHARDS
}
pub fn shard_key(name: &str, shard: usize) -> String {
    format!("mac/{name}~{shard:x}")
}
pub fn shard_prefix(name: &str) -> String {
    format!("mac/{name}~")
}
/// The per-MAC keys an older build wrote: `mac/<name>/<hex index mac>`.
pub fn legacy_prefix(name: &str) -> String {
    format!("mac/{name}/")
}

/// `[FORMAT]` then, per entry, `u16 LE len, index mac, u16 LE len, value mac`, ordered by index mac.
pub fn encode(shard: &Shard) -> Vec<u8> {
    let mut out = Vec::with_capacity(1 + shard.len() * 68);
    out.push(FORMAT);
    for (index, value) in shard {
        for part in [index, value] {
            out.extend_from_slice(&(part.len() as u16).to_le_bytes());
            out.extend_from_slice(part);
        }
    }
    out
}

fn take<'b>(rest: &mut &'b [u8]) -> Option<Vec<u8>> {
    let r: &'b [u8] = rest;
    if r.len() < 2 {
        return None;
    }
    let len = u16::from_le_bytes([r[0], r[1]]) as usize;
    let part = r.get(2..2 + len)?.to_vec();
    *rest = &r[2 + len..];
    Some(part)
}

/// The inverse of [`encode`]; `None` for a blob this build cannot read (never a partial answer).
pub fn decode(bytes: &[u8]) -> Option<Vec<(Vec<u8>, Vec<u8>)>> {
    let (&format, mut rest) = bytes.split_first()?;
    if format != FORMAT {
        return None;
    }
    let mut entries = Vec::new();
    while !rest.is_empty() {
        let index = take(&mut rest)?;
        let value = take(&mut rest)?;
        entries.push((index, value));
    }
    Some(entries)
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 {
        return None;
    }
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok()).collect()
}

struct Collection {
    shards: Vec<Shard>,
    /// Per-MAC keys from an older build may still be on disk under [`legacy_prefix`].
    legacy: bool,
}

impl Collection {
    fn new() -> Collection {
        Collection { shards: vec![Shard::new(); SHARDS], legacy: false }
    }
}

/// What a restore found for one collection, before deciding which form is authoritative.
#[derive(Default)]
struct Found {
    shards: Vec<(usize, Vec<(Vec<u8>, Vec<u8>)>)>,
    legacy: Vec<(Vec<u8>, Vec<u8>)>,
}

/// A planned change: execute [`Pending::writes`] in order, then [`MacShards::commit`] it. A plan
/// whose writes fail is simply dropped - the mirror still says what the kv said before, and the
/// caller's retry plans again from there (every write is a whole-shard replacement, so a partly
/// executed plan is repaired by the next one).
pub struct Pending {
    name: String,
    clear: bool,
    shards: Vec<(usize, Shard)>,
    pub writes: Vec<Write>,
}

/// The mirror of every collection's MACs, from which the shard blobs are built.
#[derive(Default)]
pub struct MacShards {
    collections: HashMap<String, Collection>,
    found: HashMap<String, Found>,
}

impl MacShards {
    pub fn new() -> MacShards {
        MacShards::default()
    }

    /// Feed one persisted `mac/...` key during the replay. Returns false for a key that is not a MAC
    /// key this build understands (it is then ignored, as before).
    pub fn restore_key(&mut self, key: &str, value: &[u8]) -> bool {
        let Some(rest) = key.strip_prefix("mac/") else { return false };
        if let Some((name, shard)) = rest.split_once('~') {
            let (Ok(shard), Some(entries)) = (usize::from_str_radix(shard, 16), decode(value)) else { return false };
            if shard >= SHARDS || name.is_empty() || name.contains('/') {
                return false;
            }
            self.found.entry(name.to_string()).or_default().shards.push((shard, entries));
            return true;
        }
        match rest.rsplit_once('/').and_then(|(name, idx)| Some((name, unhex(idx)?))) {
            Some((name, index)) if !name.is_empty() && !index.is_empty() => {
                self.found.entry(name.to_string()).or_default().legacy.push((index, value.to_vec()));
                true
            }
            _ => false,
        }
    }

    /// End the replay: per collection, the shards are authoritative when any exist (a build that
    /// wrote them had already folded the legacy keys in; leftovers are a migration that stopped
    /// before its prefix delete), else the legacy keys are. Returns what the in-memory backend must
    /// be given, per collection.
    pub fn finish_restore(&mut self) -> Vec<(String, Vec<(Vec<u8>, Vec<u8>)>)> {
        let mut out = Vec::new();
        for (name, found) in std::mem::take(&mut self.found) {
            let mut collection = Collection::new();
            collection.legacy = !found.legacy.is_empty();
            let entries: Vec<(Vec<u8>, Vec<u8>)> = if found.shards.is_empty() {
                found.legacy
            } else {
                found.shards.into_iter().flat_map(|(_, entries)| entries).collect()
            };
            for (index, value) in &entries {
                collection.shards[shard_of(index)].insert(index.clone(), value.clone());
            }
            self.collections.insert(name.clone(), collection);
            out.push((name, entries));
        }
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out
    }

    /// How many MACs the mirror holds for `name`.
    pub fn len(&self, name: &str) -> usize {
        self.collections.get(name).map_or(0, |c| c.shards.iter().map(|s| s.len()).sum())
    }

    pub fn get(&self, name: &str, index_mac: &[u8]) -> Option<&Vec<u8>> {
        self.collections.get(name)?.shards[shard_of(index_mac)].get(index_mac)
    }

    pub fn plan_put(&self, name: &str, macs: &[(Vec<u8>, Vec<u8>)]) -> Pending {
        self.plan(name, |shards| {
            for (index, value) in macs {
                shards.entry(shard_of(index)).or_default().insert(index.clone(), value.clone());
            }
        }, macs.iter().map(|(i, _)| shard_of(i)).collect())
    }

    pub fn plan_delete(&self, name: &str, index_macs: &[Vec<u8>]) -> Pending {
        self.plan(name, |shards| {
            for index in index_macs {
                if let Some(shard) = shards.get_mut(&shard_of(index)) {
                    shard.remove(index);
                }
            }
        }, index_macs.iter().map(|i| shard_of(i)).collect())
    }

    /// Wipe a collection: one prefix delete for the shards and one for any legacy keys.
    pub fn plan_clear(&self, name: &str) -> Pending {
        Pending {
            name: name.to_string(),
            clear: true,
            shards: Vec::new(),
            writes: vec![Write::DeletePrefix(shard_prefix(name)), Write::DeletePrefix(legacy_prefix(name))],
        }
    }

    /// Copy the touched shards (all of them while legacy keys remain, so the migration writes the
    /// whole collection once), let `change` edit the copies, and turn each into a set (or a delete,
    /// for a shard that became empty). Legacy keys go last, in one prefix delete, after every shard
    /// that now holds their MACs is written.
    fn plan(&self, name: &str, change: impl FnOnce(&mut BTreeMap<usize, Shard>), touched: Vec<usize>) -> Pending {
        let current = self.collections.get(name);
        let legacy = current.is_some_and(|c| c.legacy);
        let empty = Shard::new();
        let old = |i: usize| current.map_or(&empty, |c| &c.shards[i]);
        let mut shards: BTreeMap<usize, Shard> = BTreeMap::new();
        let indices: Vec<usize> = if legacy { (0..SHARDS).collect() } else { touched };
        for i in indices {
            shards.entry(i).or_insert_with(|| old(i).clone());
        }
        change(&mut shards);
        let mut writes = Vec::new();
        for (&i, shard) in &shards {
            if !shard.is_empty() {
                if legacy || shard != old(i) {
                    writes.push(Write::Set(shard_key(name, i), encode(shard)));
                }
            } else if !old(i).is_empty() {
                writes.push(Write::Delete(shard_key(name, i)));
            }
        }
        if legacy {
            writes.push(Write::DeletePrefix(legacy_prefix(name)));
        }
        Pending { name: name.to_string(), clear: false, shards: shards.into_iter().collect(), writes }
    }

    /// Apply a plan whose writes all succeeded.
    pub fn commit(&mut self, pending: Pending) {
        if pending.clear {
            self.collections.remove(&pending.name);
            return;
        }
        let collection = self.collections.entry(pending.name).or_insert_with(Collection::new);
        for (i, shard) in pending.shards {
            collection.shards[i] = shard;
        }
        collection.legacy = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The node policy's `kv.write` grant for this component (policies/default.json): 240/min, burst 480.
    struct Bucket {
        tokens: f64,
        burst: f64,
        per_ms: f64,
        now_ms: f64,
    }
    impl Bucket {
        fn openclaw() -> Bucket {
            Bucket { tokens: 480.0, burst: 480.0, per_ms: 240.0 / 60_000.0, now_ms: 0.0 }
        }
        fn advance(&mut self, ms: f64) {
            self.now_ms += ms;
            self.tokens = (self.tokens + ms * self.per_ms).min(self.burst);
        }
        fn take(&mut self) -> bool {
            if self.tokens >= 1.0 {
                self.tokens -= 1.0;
                true
            } else {
                false
            }
        }
    }

    /// A kv file plus the bucket in front of it: every call is one `kv.write`, as the host charges it
    /// (`service_components_v2.rs`: set, delete and delete_prefix each gate `kv.write` once).
    struct Kv {
        map: BTreeMap<String, Vec<u8>>,
        bucket: Bucket,
        calls: usize,
    }
    impl Kv {
        fn new() -> Kv {
            Kv { map: BTreeMap::new(), bucket: Bucket::openclaw(), calls: 0 }
        }
        fn run(&mut self, writes: &[Write]) -> Result<(), String> {
            for w in writes {
                self.calls += 1;
                if !self.bucket.take() {
                    return Err(format!("capability_rate_limited at call {} ({})", self.calls, w.key()));
                }
                match w {
                    Write::Set(k, v) => {
                        self.map.insert(k.clone(), v.clone());
                    }
                    Write::Delete(k) => {
                        self.map.remove(k);
                    }
                    Write::DeletePrefix(p) => self.map.retain(|k, _| !k.starts_with(p.as_str())),
                }
            }
            Ok(())
        }
        fn apply(&mut self, macs: &mut MacShards, pending: Pending) -> Result<(), String> {
            self.run(&pending.writes)?;
            macs.commit(pending);
            Ok(())
        }
        fn apply_with(&mut self, macs: &mut MacShards, plan: impl FnOnce(&MacShards) -> Pending) -> Result<(), String> {
            let pending = plan(macs);
            self.apply(macs, pending)
        }
        fn restore(&self) -> (MacShards, Vec<(String, Vec<(Vec<u8>, Vec<u8>)>)>) {
            let mut macs = MacShards::new();
            for (k, v) in &self.map {
                if k.starts_with("mac/") {
                    assert!(macs.restore_key(k, v), "unreadable key {k}");
                }
            }
            let restored = macs.finish_restore();
            (macs, restored)
        }
    }

    /// Deterministic 32-byte MACs, spread over every shard like real HMAC output.
    fn mac(seed: u32, salt: u8) -> Vec<u8> {
        let mut x = seed.wrapping_mul(2_654_435_761) ^ (salt as u32) << 24;
        (0..32)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                (x >> 24) as u8
            })
            .collect()
    }
    fn snapshot(n: u32) -> Vec<(Vec<u8>, Vec<u8>)> {
        (0..n).map(|i| (mac(i, 1), mac(i, 2))).collect()
    }
    const NAME: &str = "critical_unblock_low";

    #[test]
    fn a_2000_contact_snapshot_fits_the_openclaw_kv_budget() {
        let mut kv = Kv::new();
        let mut macs = MacShards::new();
        let snap = snapshot(2000);
        // wacore's snapshot path: clear, put every MAC, then the version (one more write).
        kv.apply_with(&mut macs, |m| m.plan_clear(NAME)).unwrap();
        kv.apply_with(&mut macs, |m| m.plan_put(NAME, &snap)).unwrap();
        kv.run(&[Write::Set(format!("ver/{NAME}"), b"{}".to_vec())]).unwrap();
        assert!(kv.calls <= SHARDS + 3, "{} kv.write calls for one snapshot", kv.calls);
        assert_eq!(macs.len(NAME), 2000);
        // ...and again right away: retries on the next connection must not need a refill either.
        for _ in 0..10 {
            kv.apply_with(&mut macs, |m| m.plan_clear(NAME)).unwrap();
            kv.apply_with(&mut macs, |m| m.plan_put(NAME, &snap)).unwrap();
        }
        assert!(kv.calls < 480);
    }

    #[test]
    fn the_old_one_key_per_mac_layout_could_not_fit_it() {
        // The failure this module removes, pinned so the budget arithmetic stays visible: 2000
        // per-MAC sets against a full 480 burst are refused at call 481.
        let mut kv = Kv::new();
        let writes: Vec<Write> = snapshot(2000)
            .iter()
            .map(|(i, v)| Write::Set(format!("mac/{NAME}/{}", i.iter().map(|b| format!("{b:02x}")).collect::<String>()), v.clone()))
            .collect();
        let error = kv.run(&writes).unwrap_err();
        assert!(error.starts_with("capability_rate_limited at call 481"), "{error}");
    }

    #[test]
    fn a_snapshot_survives_a_restart_exactly() {
        let mut kv = Kv::new();
        let mut macs = MacShards::new();
        let snap = snapshot(2000);
        kv.apply_with(&mut macs, |m| m.plan_clear(NAME)).unwrap();
        kv.apply_with(&mut macs, |m| m.plan_put(NAME, &snap)).unwrap();
        assert!(kv.map.len() <= SHARDS);
        let (restored, given) = kv.restore();
        assert_eq!(given.len(), 1);
        assert_eq!(given[0].0, NAME);
        let mut got = given[0].1.clone();
        let mut want = snap.clone();
        got.sort();
        want.sort();
        assert_eq!(got, want);
        for (i, v) in &snap {
            assert_eq!(restored.get(NAME, i), Some(v));
        }
    }

    #[test]
    fn a_patch_rewrites_only_the_shards_it_touches() {
        let mut kv = Kv::new();
        let mut macs = MacShards::new();
        kv.apply_with(&mut macs, |m| m.plan_put(NAME, &snapshot(2000))).unwrap();
        let before = kv.calls;
        let one = vec![(mac(9_999, 1), mac(9_999, 2))];
        let plan = macs.plan_put(NAME, &one);
        assert_eq!(plan.writes.len(), 1);
        kv.apply(&mut macs, plan).unwrap();
        // A remove + add of the same index (an overwrite) is two shard rewrites at most.
        let gone = vec![mac(5, 1)];
        kv.apply_with(&mut macs, |m| m.plan_delete(NAME, &gone)).unwrap();
        assert_eq!(kv.calls - before, 2);
        assert_eq!(macs.len(NAME), 2000);
        assert_eq!(macs.get(NAME, &mac(5, 1)), None);
        // An unchanged put writes nothing.
        assert!(macs.plan_put(NAME, &one).writes.is_empty());
        let (restored, _) = kv.restore();
        assert_eq!(restored.len(NAME), 2000);
        assert_eq!(restored.get(NAME, &mac(9_999, 1)), Some(&mac(9_999, 2)));
        assert_eq!(restored.get(NAME, &mac(5, 1)), None);
    }

    #[test]
    fn an_emptied_shard_is_deleted_not_left_behind() {
        let mut kv = Kv::new();
        let mut macs = MacShards::new();
        let snap = snapshot(3);
        kv.apply_with(&mut macs, |m| m.plan_put(NAME, &snap)).unwrap();
        let all: Vec<Vec<u8>> = snap.iter().map(|(i, _)| i.clone()).collect();
        kv.apply_with(&mut macs, |m| m.plan_delete(NAME, &all)).unwrap();
        assert!(kv.map.is_empty(), "{:?}", kv.map.keys().collect::<Vec<_>>());
        assert_eq!(macs.len(NAME), 0);
    }

    #[test]
    fn legacy_per_mac_keys_are_read_and_migrated_in_one_pass() {
        // A store an older build wrote: 2000 `mac/<name>/<hex>` keys plus another collection's.
        let mut kv = Kv::new();
        for (i, v) in snapshot(2000) {
            kv.map.insert(format!("mac/{NAME}/{}", i.iter().map(|b| format!("{b:02x}")).collect::<String>()), v);
        }
        kv.map.insert(format!("mac/regular/{}", "ab".repeat(32)), vec![7; 32]);
        let (mut macs, given) = kv.restore();
        assert_eq!(given.iter().map(|(n, e)| (n.as_str(), e.len())).collect::<Vec<_>>(), vec![(NAME, 2000), ("regular", 1)]);
        // The first write to the collection folds everything into shards, then one prefix delete.
        let plan = macs.plan_put(NAME, &[(mac(77_777, 1), mac(77_777, 2))]);
        assert_eq!(plan.writes.len(), SHARDS + 1);
        assert_eq!(plan.writes.last(), Some(&Write::DeletePrefix(legacy_prefix(NAME))));
        kv.apply(&mut macs, plan).unwrap();
        assert!(kv.map.keys().all(|k| !k.starts_with(&legacy_prefix(NAME))));
        // `mac/regular/` is a different prefix: untouched until `regular` is written.
        assert!(kv.map.contains_key(&format!("mac/regular/{}", "ab".repeat(32))));
        let (restored, _) = kv.restore();
        assert_eq!(restored.len(NAME), 2001);
        assert_eq!(restored.len("regular"), 1);
        // Migrated: the next patch is back to one shard.
        assert_eq!(restored.plan_put(NAME, &[(mac(88_888, 1), mac(88_888, 2))]).writes.len(), 1);
    }

    #[test]
    fn shards_win_over_legacy_leftovers_from_an_interrupted_migration() {
        let mut kv = Kv::new();
        let mut macs = MacShards::new();
        kv.apply_with(&mut macs, |m| m.plan_put(NAME, &snapshot(10))).unwrap();
        // A stale legacy key the migration did not get to delete (or one since removed).
        kv.map.insert(format!("mac/{NAME}/{}", "cd".repeat(32)), vec![1; 32]);
        let (mut restored, given) = kv.restore();
        assert_eq!(given[0].1.len(), 10);
        assert_eq!(restored.get(NAME, &vec![0xcd; 32]), None);
        // ...and the leftover is cleaned on the next write.
        let plan = restored.plan_put(NAME, &[(mac(1_234, 1), mac(1_234, 2))]);
        assert_eq!(plan.writes.last(), Some(&Write::DeletePrefix(legacy_prefix(NAME))));
        kv.apply(&mut restored, plan).unwrap();
        assert!(!kv.map.keys().any(|k| k.starts_with(&legacy_prefix(NAME))));
    }

    #[test]
    fn clear_removes_both_layouts_and_only_that_collection() {
        let mut kv = Kv::new();
        let mut macs = MacShards::new();
        kv.apply_with(&mut macs, |m| m.plan_put("regular", &snapshot(50))).unwrap();
        kv.apply_with(&mut macs, |m| m.plan_put("regular_low", &snapshot(50))).unwrap();
        kv.map.insert(format!("mac/regular/{}", "ef".repeat(32)), vec![2; 32]);
        kv.apply_with(&mut macs, |m| m.plan_clear("regular")).unwrap();
        assert!(kv.map.keys().all(|k| k.starts_with("mac/regular_low~")), "{:?}", kv.map.keys().collect::<Vec<_>>());
        assert_eq!(macs.len("regular"), 0);
        assert_eq!(macs.len("regular_low"), 50);
    }

    #[test]
    fn a_failed_plan_leaves_the_mirror_as_the_kv_was_and_the_retry_repairs_it() {
        let mut kv = Kv::new();
        let mut macs = MacShards::new();
        kv.bucket.tokens = 5.0; // drained by other writers: the plan dies part-way
        let snap = snapshot(2000);
        assert!(kv.apply_with(&mut macs, |m| m.plan_put(NAME, &snap)).is_err());
        assert_eq!(macs.len(NAME), 0);
        kv.bucket.advance(60_000.0);
        kv.apply_with(&mut macs, |m| m.plan_clear(NAME)).unwrap();
        kv.apply_with(&mut macs, |m| m.plan_put(NAME, &snap)).unwrap();
        let (restored, _) = kv.restore();
        assert_eq!(restored.len(NAME), 2000);
    }

    #[test]
    fn blobs_round_trip_and_garbage_is_refused() {
        let mut shard = Shard::new();
        shard.insert(vec![1; 32], vec![2; 32]);
        shard.insert(vec![0x10; 32], vec![3; 31]);
        let blob = encode(&shard);
        assert_eq!(decode(&blob).unwrap(), shard.clone().into_iter().collect::<Vec<_>>());
        assert_eq!(decode(&blob[..blob.len() - 1]), None);
        assert_eq!(decode(&[9]), None);
        assert_eq!(decode(&[]), None);
        assert_eq!(decode(&[FORMAT]), Some(vec![]));
        let mut macs = MacShards::new();
        assert!(!macs.restore_key("mac/regular~zz", &blob));
        assert!(!macs.restore_key("mac/regular~10", &blob));
        assert!(!macs.restore_key("mac/regular/nothex", b"x"));
        assert!(!macs.restore_key("ver/regular", b"x"));
    }
}
