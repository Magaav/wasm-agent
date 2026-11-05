//! Unit tests for the bounded store, the blob store, the ring and the replay format.
//!
//! Every test owns its directory (a `tempfile::TempDir`), passes its own timestamps, and never
//! sleeps: time in this crate is an argument, which is the whole reason expiry is testable.

use crate::blob::{sha256, BlobKey, BlobStore};
use crate::dir::{valid_name, BoundedDir, Usage};
use crate::replay::{read_header, save, Replay, ReplayReader, SaveOptions, Trigger, FORMAT_VERSION, MAGIC};
use crate::ring::{NewRecord, Payload, RecordRing, RingConfig};
use crate::{Error, Result};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tempfile::TempDir;

fn t(secs: u64) -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(secs)
}

fn dir(quota: u64) -> (TempDir, BoundedDir) {
    let tmp = tempfile::tempdir().unwrap();
    let dir = BoundedDir::open(tmp.path().join("store"), quota).unwrap();
    (tmp, dir)
}

fn names(dir: &BoundedDir) -> Vec<String> {
    dir.entries().unwrap().into_iter().map(|e| e.name).collect()
}

fn ring(max_bytes: u64, max_age_secs: u64, blob_threshold: u64) -> RecordRing {
    RecordRing::new(RingConfig {
        max_bytes,
        max_age: Duration::from_secs(max_age_secs),
        blob_threshold,
        keep_args: true,
    })
}

fn call<'a>(interface: &'a str, function: &'a str, args: &'a [u8], result: Option<&'a [u8]>, ts: SystemTime) -> NewRecord<'a> {
    NewRecord { interface, function, args, result, duration: Duration::from_micros(12), ts }
}

// ---------------------------------------------------------------- BoundedDir

#[test]
fn quota_evicts_oldest_first_and_never_the_new_file() {
    let (_tmp, dir) = dir(300);
    for (name, secs) in [("a.wrz", 1), ("b.wrz", 2), ("c.wrz", 3)] {
        dir.write_stamped(name, &[0u8; 100], t(secs)).unwrap();
    }
    assert_eq!(names(&dir), ["a.wrz", "b.wrz", "c.wrz"]);
    // The fourth 100-byte file only fits by dropping the oldest.
    dir.write_stamped("d.wrz", &[0u8; 100], t(4)).unwrap();
    assert_eq!(names(&dir), ["b.wrz", "c.wrz", "d.wrz"]);
    assert_eq!(dir.usage().unwrap().bytes, 300);

    // Rewriting an existing file charges only the difference: it must not evict to replace itself.
    dir.write_stamped("d.wrz", &[0u8; 100], t(5)).unwrap();
    assert_eq!(names(&dir), ["b.wrz", "c.wrz", "d.wrz"]);
}

#[test]
fn pinned_files_are_counted_reported_and_never_evicted() {
    let (_tmp, dir) = dir(300);
    dir.write_stamped("incident.wrz", &[7u8; 100], t(1)).unwrap();
    dir.pin("incident.wrz").unwrap();
    dir.write_stamped("b.wrz", &[0u8; 100], t(2)).unwrap();
    dir.write_stamped("c.wrz", &[0u8; 100], t(3)).unwrap();

    let usage = dir.usage().unwrap();
    assert_eq!((usage.bytes, usage.files), (300, 3));
    assert_eq!((usage.pinned_bytes, usage.pinned_files), (100, 1));

    // Oldest-first skips the pinned file (it is the oldest) and takes b instead.
    dir.write_stamped("d.wrz", &[0u8; 100], t(4)).unwrap();
    assert_eq!(names(&dir), ["incident.wrz", "c.wrz", "d.wrz"]);
    assert!(dir.exists("incident.wrz"));

    // Unpinning makes it evictable again.
    dir.unpin("incident.wrz").unwrap();
    assert!(!dir.is_pinned("incident.wrz"));
    dir.write_stamped("e.wrz", &[0u8; 100], t(5)).unwrap();
    assert!(!dir.exists("incident.wrz"));
}

#[test]
fn a_write_that_cannot_fit_is_refused_and_deletes_nothing() {
    let (_tmp, dir) = dir(200);
    dir.write_stamped("incident.wrz", &[0u8; 150], t(1)).unwrap();
    dir.pin("incident.wrz").unwrap();
    dir.write_stamped("small.wrz", &[0u8; 50], t(2)).unwrap();
    assert_eq!(names(&dir), ["incident.wrz", "small.wrz"]);

    let err = dir.write_stamped("next.wrz", &[0u8; 100], t(3)).unwrap_err();
    match err {
        Error::QuotaExceeded { needed, quota, .. } => {
            assert_eq!((needed, quota), (100, 200));
        }
        other => panic!("expected QuotaExceeded, got {other:?}"),
    }
    // Evicting the only unpinned file would not have helped; it is still there, and nothing landed.
    assert_eq!(names(&dir), ["incident.wrz", "small.wrz"]);
}

#[test]
fn a_pinned_file_may_grow_past_the_quota_and_says_so() {
    let (_tmp, dir) = dir(100);
    dir.write_stamped("incident.wrz", &[0u8; 90], t(1)).unwrap();
    dir.pin("incident.wrz").unwrap();
    // Rewriting a pinned file is a pinned write: allowed past the quota, and reported, because an
    // incident keeps its evidence. The same bytes under a new unpinned name would be refused.
    dir.write_stamped("incident.wrz", &[0u8; 150], t(2)).unwrap();
    let usage = dir.usage().unwrap();
    assert_eq!((usage.bytes, usage.pinned_bytes), (150, 150));
    assert!(usage.over_quota());
    assert_eq!(usage.remaining(), 0);
    assert_eq!(usage.pct(), 150);
    assert!(matches!(dir.write_stamped("other.wrz", &[0u8; 10], t(3)), Err(Error::QuotaExceeded { .. })));
}

#[test]
fn the_threshold_callback_fires_on_the_crossing_only_and_rearms() {
    let (tmp, dir) = dir(1000);
    let seen: Arc<Mutex<Vec<Usage>>> = Arc::new(Mutex::new(Vec::new()));
    let fires = Arc::new(AtomicUsize::new(0));
    let (seen2, fires2) = (seen.clone(), fires.clone());
    let dir = dir
        .with_threshold(80)
        .on_threshold(move |usage| {
            seen2.lock().unwrap().push(usage.clone());
            fires2.fetch_add(1, Ordering::SeqCst);
        });

    dir.write_stamped("a.wrz", &[0u8; 500], t(1)).unwrap();
    assert_eq!(fires.load(Ordering::SeqCst), 0);
    dir.write_stamped("b.wrz", &[0u8; 300], t(2)).unwrap(); // exactly 80 %
    assert_eq!(fires.load(Ordering::SeqCst), 1);
    dir.write_stamped("c.wrz", &[0u8; 100], t(3)).unwrap(); // still above: no second call
    assert_eq!(fires.load(Ordering::SeqCst), 1);
    let usage = seen.lock().unwrap()[0].clone();
    assert_eq!((usage.pct(), usage.over_threshold()), (80, true));

    dir.remove("c.wrz").unwrap();
    dir.remove("b.wrz").unwrap();
    dir.write_stamped("d.wrz", &[0u8; 900], t(4)).unwrap(); // below then above again
    assert_eq!(fires.load(Ordering::SeqCst), 2);
    drop(tmp);
}

#[test]
fn expiry_drops_unpinned_files_only() {
    let (_tmp, dir) = dir(10_000);
    dir.write_stamped("old.wrz", b"x", t(0)).unwrap();
    dir.write_stamped("incident.wrz", b"x", t(0)).unwrap();
    dir.pin("incident.wrz").unwrap();
    dir.write_stamped("new.wrz", b"x", t(6 * 24 * 3600)).unwrap();

    let gone = dir.expire(Duration::from_secs(7 * 24 * 3600), t(8 * 24 * 3600)).unwrap();
    assert_eq!(gone, ["old.wrz"]);
    assert_eq!(names(&dir), ["incident.wrz", "new.wrz"]);
    let gone = dir.expire(Duration::from_secs(7 * 24 * 3600), t(20 * 24 * 3600)).unwrap();
    assert_eq!(gone, ["new.wrz"]);
    // Nothing left to expire is not an error.
    assert!(dir.expire(Duration::from_secs(1), t(9 * 24 * 3600)).unwrap().is_empty());
}

#[test]
fn names_are_flat_and_markers_are_skipped() {
    let (tmp, dir) = dir(1000);
    for bad in ["", "../x", "a/b", ".hidden", "x.tmp", "x.pin", "a..b"] {
        assert!(!valid_name(bad), "{bad:?} must be refused");
        assert!(matches!(dir.write_stamped(bad, b"x", t(1)), Err(Error::BadName(_))));
    }
    for good in ["a.wrz", "replay.error.1700000000000.wrz", "A_b-1"] {
        assert!(valid_name(good), "{good:?} must be allowed");
    }
    dir.write_stamped("replay.wrz", b"payload", t(1)).unwrap();
    dir.pin("replay.wrz").unwrap();
    // A nested directory is somebody else's files: not listed, not counted, not evicted.
    std::fs::create_dir_all(tmp.path().join("store/blobs")).unwrap();
    std::fs::write(tmp.path().join("store/blobs/abcdef"), [0u8; 500]).unwrap();
    assert_eq!(names(&dir), ["replay.wrz"]);
    assert_eq!(dir.usage().unwrap().bytes, 7);
    assert_eq!(dir.read("replay.wrz").unwrap(), b"payload");
    assert!(matches!(dir.read("nope.wrz"), Err(Error::NotFound(_))));
    assert!(matches!(dir.pin("nope.wrz"), Err(Error::NotFound(_))));
}

// ---------------------------------------------------------------- BlobStore

#[test]
fn blobs_dedupe_by_sha256_and_refcount() {
    let tmp = tempfile::tempdir().unwrap();
    let store = BlobStore::open(tmp.path().join("blobs")).unwrap();
    let payload = b"the same bytes twice";

    let first = store.put(payload).unwrap();
    let second = store.put(payload).unwrap();
    assert_eq!(first.key, second.key);
    assert_eq!(first.key, BlobKey::of(payload));
    assert_eq!(first.key.hex(), crate::blob::hex(&sha256(payload)));
    assert_eq!(store.len().unwrap(), 1);
    assert_eq!(store.total_bytes().unwrap(), payload.len() as u64);

    assert_eq!(store.add_ref(&first.key).unwrap(), 1);
    assert_eq!(store.add_ref(&first.key).unwrap(), 2);
    assert_eq!(store.refcount(&first.key), 2);
    assert_eq!(store.release(&first.key).unwrap(), 1);
    assert_eq!(store.release(&first.key).unwrap(), 0);
    // A double release saturates: never a wrapped count that keeps a blob alive forever.
    assert_eq!(store.release(&first.key).unwrap(), 0);
    assert_eq!(store.refcount(&first.key), 0);
    assert_eq!(store.get(&first.key).unwrap().unwrap(), payload);
    assert!(matches!(store.add_ref(&BlobKey([9u8; 32])), Err(Error::BlobMissing(_))));
}

#[test]
fn refcounts_survive_reopening_the_store() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("blobs");
    let key = {
        let store = BlobStore::open(&path).unwrap();
        let key = store.put(b"referenced").unwrap().key;
        store.add_ref(&key).unwrap();
        key
    };
    let store = BlobStore::open(&path).unwrap();
    assert_eq!(store.refcount(&key), 1);
    // And a malformed index line is ignored rather than making the store unusable.
    let mut text = std::fs::read_to_string(path.join("refs.idx")).unwrap();
    text.push_str("not-a-key 3\n");
    std::fs::write(path.join("refs.idx"), text).unwrap();
    let store = BlobStore::open(&path).unwrap();
    assert_eq!(store.refcount(&key), 1);
}

#[test]
fn gc_keeps_referenced_pinned_fresh_and_unreadable_blobs() {
    let tmp = tempfile::tempdir().unwrap();
    let store = BlobStore::open(tmp.path().join("blobs")).unwrap();
    let ttl = Duration::from_secs(24 * 3600);
    let now = t(10 * 24 * 3600);
    let old = t(0);

    let stale = store.put(b"unreferenced and old").unwrap().key;
    let fresh = store.put(b"unreferenced but new").unwrap().key;
    let referenced = store.put(b"referenced and old").unwrap().key;
    let pinned = store.put(b"pinned and old").unwrap().key;
    store.add_ref(&referenced).unwrap();
    store.pin(&pinned).unwrap();

    // Age is the file's mtime; the store never fakes it, so the test sets it.
    for key in [&stale, &referenced, &pinned] {
        std::fs::File::options()
            .write(true)
            .open(store.blob_path(key))
            .unwrap()
            .set_modified(old)
            .unwrap();
    }
    std::fs::File::options()
        .write(true)
        .open(store.blob_path(&fresh))
        .unwrap()
        .set_modified(now - Duration::from_secs(60))
        .unwrap();

    let report = store.gc(now, ttl).unwrap();
    assert_eq!(report.scanned, 4);
    assert_eq!(report.removed, vec![stale]);
    assert_eq!(report.kept, 3);
    assert_eq!(report.bytes_freed, b"unreferenced and old".len() as u64);
    assert!(!store.has(&stale));
    assert!(store.has(&fresh) && store.has(&referenced) && store.has(&pinned));

    // Once the reference and the pin go, the same gc removes both.
    store.release(&referenced).unwrap();
    store.unpin(&pinned).unwrap();
    let report = store.gc(now, ttl).unwrap();
    assert_eq!(report.removed.len(), 2);
    assert_eq!(store.len().unwrap(), 1);
}

// ---------------------------------------------------------------- RecordRing

#[test]
fn the_ring_drops_oldest_records_to_stay_under_its_byte_bound() {
    let mut ring = ring(400, 300, 64);
    for i in 0..10u8 {
        ring.push(call("wa:kernel/kv", "get", b"", Some(&[i; 32]), t(1))).unwrap();
    }
    assert!(ring.bytes() <= 400, "bytes {} over the bound", ring.bytes());
    assert!(ring.len() >= 2 && ring.len() <= 4, "len {}", ring.len());
    // The newest call is always kept: it is the one that failed.
    assert_eq!(ring.records().back().unwrap().seq, 9);
    assert!(ring.records().front().unwrap().seq > 0);
}

#[test]
fn the_ring_drops_records_past_the_age_bound_on_push() {
    let mut ring = ring(10 * 1024 * 1024, 300, 64);
    ring.push(call("wa:kernel/kv", "get", b"", Some(b"a"), t(0))).unwrap();
    ring.push(call("wa:kernel/kv", "get", b"", Some(b"b"), t(299))).unwrap();
    assert_eq!(ring.len(), 2);
    // The third call is 301 s after the first: the first is past the bound and goes with it.
    ring.push(call("wa:kernel/kv", "get", b"", Some(b"c"), t(301))).unwrap();
    assert_eq!(ring.len(), 2);
    assert_eq!(ring.records().front().unwrap().ts, t(299));
    assert_eq!(ring.expire(t(700)).unwrap(), 2);
    assert!(ring.is_empty());
}

#[test]
fn a_large_payload_spills_to_a_blob_and_releases_when_the_record_goes() {
    let tmp = tempfile::tempdir().unwrap();
    let store = BlobStore::open(tmp.path().join("blobs")).unwrap();
    let mut ring = RecordRing::with_blobs(
        RingConfig { max_bytes: 1024 * 1024, max_age: Duration::from_secs(300), blob_threshold: 16, keep_args: true },
        store,
    );
    let body = vec![b'Z'; 4096];
    ring.push(call("wasi:http/incoming-handler", "handle", b"small", Some(&body), t(0))).unwrap();

    let record = ring.records().front().unwrap().clone();
    let reference = record.result.blob().expect("a 4 KiB payload must become a blob reference");
    assert_eq!(reference.len, 4096);
    {
        let store = ring.blobs().unwrap();
        assert_eq!(store.len().unwrap(), 1);
        assert_eq!(store.refcount(&reference.key), 1);
    }
    // The ring's byte bound counts the reference, not the payload.
    assert!(ring.bytes() < 4096, "ring charged {} bytes for a 4 KiB payload", ring.bytes());

    // Evicting the record releases the reference, so gc may collect it.
    ring.push(call("wa:kernel/kv", "get", b"", Some(b"x"), t(400))).unwrap();
    let store = ring.blobs().unwrap();
    assert_eq!(store.refcount(&reference.key), 0);
    std::fs::File::options()
        .write(true)
        .open(store.blob_path(&reference.key))
        .unwrap()
        .set_modified(t(0))
        .unwrap();
    let report = store.gc(t(2 * 24 * 3600), Duration::from_secs(24 * 3600)).unwrap();
    assert_eq!(report.removed, vec![reference.key]);
}

#[test]
fn with_no_blob_store_a_large_payload_becomes_a_digest_not_memory() {
    let mut ring = ring(1024 * 1024, 300, 16);
    let body = vec![b'Q'; 4096];
    ring.push(call("wa:kernel/http", "start", b"", Some(&body), t(0))).unwrap();
    let result = ring.records().front().unwrap().result.clone();
    assert!(matches!(result, Payload::Digest { len: 4096, .. }));
    assert_eq!(result.digest().unwrap(), sha256(&body));
    assert!(ring.bytes() < 4096);
}

#[test]
fn keep_args_false_records_a_digest_and_no_argument_bytes() {
    let mut ring = RecordRing::new(RingConfig {
        max_bytes: 1024 * 1024,
        max_age: Duration::from_secs(300),
        blob_threshold: 4096,
        keep_args: false,
    });
    ring.push(call("wa:kernel/log", "write", b"a message body", Some(b"ok"), t(0))).unwrap();
    let record = ring.records().front().unwrap();
    assert_eq!(record.args.digest().unwrap(), sha256(b"a message body"));
    assert!(record.args.inline_bytes().is_none());
    // Results are always recorded in full: the replay has to feed something back.
    assert_eq!(record.result.inline_bytes().unwrap(), b"ok");
}

#[test]
fn record_fields_must_be_names() {
    let mut ring = ring(1024, 300, 64);
    assert!(matches!(ring.push(call("", "get", b"", None, t(0))), Err(Error::BadField("interface"))));
    assert!(matches!(ring.push(call("wa:kernel/kv", "", b"", None, t(0))), Err(Error::BadField("function"))));
    let long = "x".repeat(129);
    assert!(matches!(ring.push(call(&long, "get", b"", None, t(0))), Err(Error::BadField("interface"))));
    assert!(ring.is_empty());
}

// ---------------------------------------------------------------- save / replay

fn sample_ring(tmp: &TempDir) -> RecordRing {
    let store = BlobStore::open(tmp.path().join("blobs")).unwrap();
    let mut ring = RecordRing::with_blobs(
        RingConfig { max_bytes: 1024 * 1024, max_age: Duration::from_secs(300), blob_threshold: 64, keep_args: true },
        store,
    );
    ring.push(call("wa:kernel/kv", "get", b"key-1", Some(b"value-1"), t(1000))).unwrap();
    ring.push(call("wa:kernel/http", "start", &[b'A'; 200], Some(b"{\"status\":200}"), t(1001))).unwrap();
    ring.push(call("wasi:clocks/monotonic-clock", "now", b"", Some(&0u64.to_le_bytes()), t(1002))).unwrap();
    ring
}

#[test]
fn save_then_load_round_trips_every_field_and_resolves_blobs() {
    let tmp = tempfile::tempdir().unwrap();
    let ring = sample_ring(&tmp);
    let (_q, dir) = dir(1024 * 1024);
    let opts = SaveOptions { trigger: Trigger::Error, label: "wa-whatsapp 12".to_string(), pin: false };
    let saved = save(&ring, &dir, &opts, t(1100)).unwrap();

    assert_eq!(saved.records, 3);
    assert_eq!(saved.bytes, std::fs::metadata(dir.path_of(&saved.name)).unwrap().len());
    assert!(saved.missing_blobs.is_empty());
    assert_eq!(saved.name, "wa-whatsapp-12.error.1100000.wrz");

    let replay = Replay::load(dir.path_of(&saved.name)).unwrap();
    assert_eq!(replay.header.version, FORMAT_VERSION);
    assert_eq!(replay.header.trigger, Trigger::Error);
    assert_eq!(replay.header.label, "wa-whatsapp 12");
    assert_eq!(replay.header.records, 3);
    assert_eq!(replay.header.created, t(1100));
    assert_eq!(replay.header.ring.max_age, Duration::from_secs(300));
    assert_eq!(replay.header.ring.blob_threshold, 64);
    assert_eq!(replay.header.blobs.len(), 1);
    replay.verify().unwrap();

    let original = ring.records().iter().cloned().collect::<Vec<_>>();
    assert_eq!(replay.records.len(), original.len());
    for (loaded, want) in replay.records.iter().zip(original.iter()) {
        assert_eq!((loaded.seq, loaded.ts, loaded.duration), (want.seq, want.ts, want.duration));
        assert_eq!((&loaded.interface, &loaded.function), (&want.interface, &want.function));
        assert_eq!(loaded.args.digest(), want.args.digest());
        assert_eq!(loaded.result.digest(), want.result.digest());
    }
    // The spilled argument comes back from the blob store by reference.
    let store = ring.blobs().unwrap();
    let loaded_args = replay.resolve(store, &replay.records[1].args).unwrap().unwrap();
    assert_eq!(loaded_args, vec![b'A'; 200]);
    let loaded_result = replay.resolve(store, &replay.records[1].result).unwrap().unwrap();
    assert_eq!(loaded_result, b"{\"status\":200}");
    // A save takes its own reference, so the file survives the ring being cleared; releasing the
    // file's reference (what deleting it does) leaves the ring's.
    assert_eq!(store.refcount(&replay.header.blobs[0].key), 2);
    replay.header.release_blobs(store).unwrap();
    assert_eq!(store.refcount(&replay.header.blobs[0].key), 1);
    drop(ring);
}

#[test]
fn the_saved_file_is_a_zstd_compressed_versioned_file() {
    let mut ring = ring(10 * 1024 * 1024, 300, 64);
    for i in 0..50u16 {
        ring.push(call("wa:kernel/log", "write", b"", Some(&[b'A'; 200]), t(i as u64))).unwrap();
    }
    let (_q, dir) = dir(1024 * 1024);
    let saved = save(&ring, &dir, &SaveOptions::default(), t(1000)).unwrap();
    let bytes = std::fs::read(dir.path_of(&saved.name)).unwrap();
    assert_eq!(&bytes[..8], MAGIC);
    assert_eq!(u16::from_le_bytes([bytes[8], bytes[9]]), FORMAT_VERSION);
    let (header, header_len) = read_header(&bytes).unwrap();
    assert_eq!(header.records, 50);
    assert_eq!(header.trigger, Trigger::Manual);
    // 50 records x 200 identical bytes compress to far less than their inline size, and the header
    // is a small plaintext prefix of the file.
    assert!(header_len < 256);
    assert!(bytes.len() < header_len + 50 * 200, "file {} bytes did not compress", bytes.len());
}

#[test]
fn pins_survive_the_quota_and_the_operator_can_see_them() {
    let tmp = tempfile::tempdir().unwrap();
    let ring = sample_ring(&tmp);
    let (_q, dir) = dir(10_000);
    let opts = SaveOptions { trigger: Trigger::Crash, label: "incident".to_string(), pin: true };
    let saved = save(&ring, &dir, &opts, t(1100)).unwrap();
    assert!(saved.pinned);
    assert!(dir.is_pinned(&saved.name));
    let usage = dir.usage().unwrap();
    assert_eq!(usage.pinned_files, 1);
    assert!(usage.pinned_bytes > 0);
    // Pinned replays are not expired.
    assert!(dir.expire(Duration::from_secs(1), t(10_000_000)).unwrap().is_empty());
    assert!(dir.exists(&saved.name));
}

#[test]
fn a_replay_names_blobs_it_could_not_reference_and_still_saves() {
    let tmp = tempfile::tempdir().unwrap();
    let ring = sample_ring(&tmp);
    let key = ring.records()[1].args.blob().unwrap().key;
    std::fs::remove_file(ring.blobs().unwrap().blob_path(&key)).unwrap();

    let (_q, dir) = dir(1024 * 1024);
    let saved = save(&ring, &dir, &SaveOptions::default(), t(1100)).unwrap();
    assert_eq!(saved.missing_blobs, vec![key]);
    let replay = Replay::load(dir.path_of(&saved.name)).unwrap();
    // Readable, and honest about what it cannot resolve.
    assert_eq!(replay.records.len(), 3);
    assert!(matches!(replay.resolve(ring.blobs().unwrap(), &replay.records[1].args), Err(Error::BlobMissing(_))));
    assert_eq!(replay.verify_blobs(ring.blobs().unwrap()).unwrap(), vec![key]);
}

#[test]
fn a_damaged_replay_file_is_refused_whole() {
    let tmp = tempfile::tempdir().unwrap();
    let ring = sample_ring(&tmp);
    let (_q, dir) = dir(1024 * 1024);
    let saved = save(&ring, &dir, &SaveOptions::default(), t(1100)).unwrap();
    let good = std::fs::read(dir.path_of(&saved.name)).unwrap();
    let read = |bytes: &[u8]| ReplayReader::from_bytes(bytes).map(|_| ());

    // Wrong magic: not our file.
    let mut bad = good.clone();
    bad[0] = b'X';
    assert!(matches!(read(&bad), Err(Error::Corrupt(_))), "{:?}", read(&bad));

    // A version from the future is refused as such, not read as if it were ours.
    let mut bad = good.clone();
    bad[8..10].copy_from_slice(&99u16.to_le_bytes());
    assert!(matches!(read(&bad), Err(Error::UnsupportedVersion(99))));

    // Unknown flag bits.
    let mut bad = good.clone();
    bad[10] = 0b0000_0010;
    assert!(matches!(read(&bad), Err(Error::Corrupt(_))));

    // Truncated header, and a truncated body.
    assert!(matches!(read(&good[..20]), Err(Error::Corrupt(_))));
    assert!(matches!(read(&good[..good.len() - 8]), Err(Error::Corrupt(_))));

    // A flipped byte inside the compressed body: zstd's frame checksum or the body digest catches it.
    let mut bad = good.clone();
    let last = bad.len() - 1;
    bad[last] ^= 0xff;
    assert!(matches!(read(&bad), Err(Error::Corrupt(_))), "{:?}", read(&bad));

    // A body that decompresses and matches its digest but carries a short record stream: the header
    // count is the authority, so the truncated record is an error, not "the records we could read".
    let (header, header_len) = read_header(&good).unwrap();
    let mut body = zstd::stream::decode_all(&good[header_len..]).unwrap();
    body.truncate(body.len() - 3);
    let mut rebuilt = Vec::new();
    rebuilt.extend_from_slice(&good[..28]);
    rebuilt.extend_from_slice(&(body.len() as u64).to_le_bytes());
    rebuilt.extend_from_slice(&sha256(&body));
    rebuilt.extend_from_slice(&good[68..header_len]);
    let mut encoder = zstd::Encoder::new(Vec::new(), 3).unwrap();
    encoder.include_checksum(true).unwrap();
    use std::io::Write as _;
    encoder.write_all(&body).unwrap();
    rebuilt.extend_from_slice(&encoder.finish().unwrap());
    assert_eq!(read_header(&rebuilt).unwrap().0.records, header.records);
    let open = ReplayReader::from_bytes(&rebuilt);
    match open {
        Err(Error::Corrupt(_)) => {}
        Ok(reader) => {
            let mut errors = 0;
            for item in reader {
                if item.is_err() {
                    errors += 1;
                }
            }
            assert_eq!(errors, 1, "a truncated record must be reported, not skipped");
        }
        Err(other) => panic!("expected a corrupt body, got {other:?}"),
    }
}

#[test]
fn resolved_bytes_must_match_their_key() {
    let tmp = tempfile::tempdir().unwrap();
    let store = BlobStore::open(tmp.path().join("blobs")).unwrap();
    let key = store.put(b"true content").unwrap().key;
    let payload = Payload::Blob(crate::blob::BlobRef::new(key, 12));
    assert_eq!(crate::replay::resolve_payload(&store, &payload).unwrap().unwrap(), b"true content");

    // Swap the file under the key: the resolver refuses rather than feeding the guest the wrong bytes.
    std::fs::write(store.blob_path(&key), b"tampered!!!!").unwrap();
    assert!(matches!(crate::replay::resolve_payload(&store, &payload), Err(Error::Corrupt(_))));
}

#[test]
fn an_empty_ring_saves_a_readable_but_empty_replay() -> Result<()> {
    let (_q, dir) = dir(1024);
    let ring = ring(1024, 300, 64);
    let saved = save(&ring, &dir, &SaveOptions::default(), t(1))?;
    assert_eq!(saved.records, 0);
    let replay = Replay::load(dir.path_of(&saved.name))?;
    assert!(replay.records.is_empty());
    assert!(replay.header.blobs.is_empty());
    Ok(())
}
