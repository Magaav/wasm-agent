//! Unit tests. They run over [`MemKv`] only: the crate has no filesystem, no clock and no wasmtime,
//! which is exactly what makes a crash at *every* write cheap enough to test.

use super::*;
use crate::batch::{decode_changes, encode_changes};
use crate::meta::{is_reserved, open};
#[cfg(feature = "snapshot")]
use crate::snapshot::{FOOTER_TAG, MAGIC, SNAPSHOT_FORMAT};
use std::collections::BTreeMap;

const NOW: u64 = 1_760_000_000_000;
/// sha256("test"), lowercase hex - the shape `last_migrated_by` holds.
const SHA: &str = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";

fn component() -> ComponentInfo {
    ComponentInfo::new("wa-whatsapp", "1.2.0", SHA).unwrap()
}

/// A namespace at v1 with the two keys every step below transforms.
fn seeded() -> (MemKv, ComponentInfo) {
    let mut kv = MemKv::new();
    let info = component();
    open(&mut kv, &info, 1, NOW).unwrap();
    kv.put(b"m/a", b"alpha").unwrap();
    kv.put(b"m/b", b"beta").unwrap();
    (kv, info)
}

/// Three steps whose composition is easy to verify by hand:
/// 1: `m/` -> `msg/`, 2: prefix values with `v3:`, 3: an index count.
fn registry() -> Registry {
    Registry::new(vec![
        Step::new(1, "messages/prefix", |batch: &mut Batch| {
            batch.rename_prefix(b"m/", b"msg/")?;
            Ok(())
        })
        .down(|batch: &mut Batch| {
            batch.rename_prefix(b"msg/", b"m/")?;
            Ok(())
        }),
        Step::new(2, "values/v3", |batch: &mut Batch| {
            let entries: Vec<(Vec<u8>, Vec<u8>)> = batch
                .prefix(b"msg/")
                .map(|(key, value)| (key.to_vec(), value.to_vec()))
                .collect();
            for (key, value) in entries {
                let mut next = b"v3:".to_vec();
                next.extend_from_slice(&value);
                batch.insert(&key, next)?;
            }
            Ok(())
        })
        .down(|batch: &mut Batch| {
            let entries: Vec<(Vec<u8>, Vec<u8>)> = batch
                .prefix(b"msg/")
                .map(|(key, value)| (key.to_vec(), value.to_vec()))
                .collect();
            for (key, value) in entries {
                batch.insert(&key, &value[3..])?;
            }
            Ok(())
        }),
        Step::new(3, "index/count", |batch: &mut Batch| {
            let count = batch.prefix(b"msg/").count();
            batch.insert(b"index/count", count.to_string().as_bytes())?;
            Ok(())
        })
        .down(|batch: &mut Batch| {
            batch.remove(b"index/count");
            Ok(())
        }),
    ])
    .unwrap()
}

fn user_entries(kv: &MemKv) -> BTreeMap<Vec<u8>, Vec<u8>> {
    kv.entries()
        .iter()
        .filter(|entry| !is_reserved(entry.0.as_slice()))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

#[cfg(feature = "snapshot")]
fn snapshot_bytes(kv: &mut MemKv) -> Vec<u8> {
    let meta = Meta::read(kv).unwrap().unwrap();
    let mut out = Vec::new();
    export(kv, &meta, &mut out, NOW, &ExportOptions::default()).unwrap();
    out
}

#[test]
fn open_creates_meta_and_refuses_to_adopt_foreign_data() {
    let info = component();
    let mut kv = MemKv::new();
    let meta = open(&mut kv, &info, 1, NOW).unwrap();
    assert_eq!(meta.schema_version, 1);
    assert_eq!(meta.component, "wa-whatsapp");
    assert_eq!(meta.component_version, "1.2.0");
    assert_eq!(meta.last_migrated_by, SHA);
    assert_eq!(meta.created_at_ms, NOW);

    // Opening again records the running build but does not claim a migration.
    let newer = ComponentInfo::new("wa-whatsapp", "1.3.0", SHA).unwrap();
    let meta = open(&mut kv, &newer, 1, NOW + 1).unwrap();
    assert_eq!(meta.component_version, "1.3.0");
    assert_eq!(meta.schema_version, 1);
    assert_eq!(meta.last_migrated_at_ms, NOW);

    // Keys without metadata are refused, never adopted at `initial_version`.
    let mut foreign = MemKv::from_entries([(b"m/a".to_vec(), b"x".to_vec())]);
    assert_eq!(
        open(&mut foreign, &info, 1, NOW),
        Err(Error::Uninitialised { keys: 1 })
    );

    // A namespace has one owner.
    let other = ComponentInfo::new("other-component", "1.0.0", SHA).unwrap();
    assert!(matches!(
        open(&mut kv, &other, 1, NOW),
        Err(Error::OwnerMismatch { .. })
    ));

    // v0 is not a schema version.
    let mut fresh = MemKv::new();
    assert!(matches!(
        open(&mut fresh, &info, 0, NOW),
        Err(Error::Corrupt(_))
    ));

    // A partial meta set is corruption, not "almost initialised".
    let mut partial = MemKv::new();
    partial
        .put(crate::meta::key::COMPONENT, b"wa-whatsapp")
        .unwrap();
    assert!(matches!(Meta::read(&mut partial), Err(Error::Corrupt(_))));
}

#[test]
fn the_user_view_cannot_see_or_forge_meta() {
    let (mut kv, _) = seeded();
    let writes_before = kv.writes();
    {
        let mut view = UserView::new(&mut kv);
        assert_eq!(view.get(crate::meta::key::SCHEMA_VERSION).unwrap(), None);
        assert_eq!(
            view.put(crate::meta::key::SCHEMA_VERSION, b"99"),
            Err(Error::Reserved)
        );
        assert_eq!(
            view.del(crate::meta::key::SCHEMA_VERSION),
            Err(Error::Reserved)
        );
        let keys: Vec<Vec<u8>> = view
            .scan_prefix(b"")
            .unwrap()
            .into_iter()
            .map(|(key, _)| key)
            .collect();
        assert_eq!(keys, vec![b"m/a".to_vec(), b"m/b".to_vec()]);
        // Even a scan aimed at the reserved prefix returns nothing.
        assert!(view.scan_prefix(b"__wa/").unwrap().is_empty());
        // Guest-visible limits apply here, not only in the host.
        let big = vec![0u8; (MAX_VALUE_BYTES + 1) as usize];
        assert!(matches!(view.put(b"k", &big), Err(Error::Limit { .. })));
    }
    assert_eq!(kv.writes(), writes_before);
    assert_eq!(Meta::read(&mut kv).unwrap().unwrap().schema_version, 1);
}

#[test]
fn batch_refuses_reserved_keys_and_renames_prefixes() {
    let mut batch = Batch::new();
    batch.insert(b"m/a", b"1").unwrap();
    assert_eq!(
        batch.insert(crate::meta::key::SCHEMA_VERSION, b"9"),
        Err(Error::Reserved)
    );
    assert_eq!(batch.rename_prefix(b"__wa/", b"x/"), Err(Error::Reserved));
    assert_eq!(batch.rename_prefix(b"m/", b"msg/").unwrap(), 1);
    assert_eq!(batch.get(b"msg/a"), Some(b"1".as_slice()));
    assert!(batch.get(b"m/a").is_none());

    let (mut kv, _) = seeded();
    let loaded = Batch::load(&mut kv, 64).unwrap();
    assert_eq!(loaded.len(), 2);
    assert!(matches!(
        Batch::load(&mut kv, 1),
        Err(Error::Limit { .. })
    ));
}

#[test]
fn registry_refuses_forks_and_names_the_missing_step() {
    assert!(matches!(
        Registry::new(vec![
            Step::new(1, "a", |_: &mut Batch| Ok(())),
            Step::new(1, "b", |_: &mut Batch| Ok(())),
        ]),
        Err(Error::Corrupt(_))
    ));
    assert!(matches!(
        Registry::new(vec![Step::new(0, "a", |_: &mut Batch| Ok(()))]),
        Err(Error::Corrupt(_))
    ));
    let reg = registry();
    assert_eq!(reg.len(), 3);
    assert_eq!(reg.latest(), Some(4));
    assert_eq!(reg.plan(1, 1, false).unwrap().len(), 0);
    assert_eq!(reg.plan(1, 4, false).unwrap().len(), 3);

    // A gap is not a path: the version that is missing is named, not skipped over.
    let gap = Registry::new(vec![
        Step::new(1, "a", |_: &mut Batch| Ok(())),
        Step::new(3, "c", |_: &mut Batch| Ok(())),
    ])
    .unwrap();
    assert!(matches!(
        gap.plan(1, 4, false),
        Err(Error::NoMigrationPath {
            missing: 2,
            direction: Direction::Up,
            ..
        })
    ));
}

#[test]
fn multi_step_migration_runs_in_order_and_records_provenance() {
    let (mut kv, info) = seeded();
    let reg = registry();
    let report = Migrator::new(&mut kv, &reg, &info)
        .migrate(4, NOW + 10, &mut ())
        .unwrap();

    assert_eq!(report.from, 1);
    assert_eq!(report.target, 4);
    assert_eq!(report.final_version, 4);
    assert!(!report.resumed);
    assert!(!report.dry_run);
    let names: Vec<&str> = report.steps.iter().map(|step| step.name.as_str()).collect();
    assert_eq!(names, vec!["messages/prefix", "values/v3", "index/count"]);
    assert_eq!(
        report.steps[0].counts,
        ChangeCounts { added: 2, removed: 2, changed: 0, unchanged: 0 }
    );
    assert_eq!(
        report.steps[1].counts,
        ChangeCounts { added: 0, removed: 0, changed: 2, unchanged: 0 }
    );
    assert_eq!(
        report.steps[2].counts,
        ChangeCounts { added: 1, removed: 0, changed: 0, unchanged: 2 }
    );
    assert_eq!(report.totals.added, 3);
    assert_eq!(report.totals.removed, 2);
    assert_eq!(report.totals.changed, 2);

    let entries = user_entries(&kv);
    assert_eq!(entries.len(), 3);
    assert_eq!(entries.get(b"msg/a".as_slice()), Some(&b"v3:alpha".to_vec()));
    assert_eq!(entries.get(b"msg/b".as_slice()), Some(&b"v3:beta".to_vec()));
    assert_eq!(entries.get(b"index/count".as_slice()), Some(&b"2".to_vec()));

    let meta = Meta::read(&mut kv).unwrap().unwrap();
    assert_eq!(meta.schema_version, 4);
    assert_eq!(meta.last_migrated_by, SHA);
    assert_eq!(meta.last_migrated_at_ms, NOW + 10);
    assert_eq!(meta.created_at_ms, NOW);
    assert!(journal(&mut kv).unwrap().is_none());

    // The snapshot is the state *before* the first write, which is what makes it a rollback point.
    let snapshot = report.snapshot.as_ref().unwrap();
    assert_eq!(snapshot.header.schema_version, 1);
    assert_eq!(snapshot.header.entries, 2);
    assert!(snapshot
        .entries
        .iter()
        .any(|(key, value)| key == b"m/a" && value == b"alpha"));

    // Re-running at the same target writes nothing and claims no migration.
    let before = kv.entries().clone();
    let writes = kv.writes();
    let again = Migrator::new(&mut kv, &reg, &info)
        .migrate(4, NOW + 20, &mut ())
        .unwrap();
    assert!(again.steps.is_empty());
    assert_eq!(kv.entries(), &before);
    assert_eq!(kv.writes(), writes);
}

#[test]
fn crash_at_any_write_resumes_to_the_same_state() {
    let reg = registry();
    let info = component();
    let (mut reference, _) = seeded();
    Migrator::new(&mut reference, &reg, &info)
        .migrate(4, NOW + 10, &mut ())
        .unwrap();
    let want = user_entries(&reference);
    assert_eq!(want.len(), 3);

    let mut crashed = 0;
    let mut reached_a_clean_run = false;
    for budget in 0..400u64 {
        let (mut kv, info) = seeded();
        kv.set_write_budget(Some(budget));
        match Migrator::new(&mut kv, &reg, &info).migrate(4, NOW + 10, &mut ()) {
            Ok(_) => {
                reached_a_clean_run = true;
                break;
            }
            Err(Error::Injected(_)) => {
                crashed += 1;
                // Wherever the crash landed, a journal must describe usable work - and a dry run
                // must succeed even though writes are still exhausted.
                if journal(&mut kv).unwrap().is_some() {
                    let dry = Migrator::new(&mut kv, &reg, &info).dry_run(4).unwrap();
                    assert!(dry.resumed, "budget {budget}");
                    assert_eq!(dry.final_version, 4, "budget {budget}");
                }
                kv.set_write_budget(None);
                let resumed = Migrator::new(&mut kv, &reg, &info)
                    .migrate(4, NOW + 20, &mut ())
                    .unwrap();
                assert_eq!(resumed.final_version, 4, "budget {budget}");
                assert_eq!(user_entries(&kv), want, "budget {budget}");
                let meta = Meta::read(&mut kv).unwrap().unwrap();
                assert_eq!(meta.schema_version, 4, "budget {budget}");
                assert!(journal(&mut kv).unwrap().is_none(), "budget {budget}");
            }
            Err(other) => panic!("unexpected error at budget {budget}: {other}"),
        }
    }
    assert!(reached_a_clean_run, "the loop never reached a clean run");
    assert!(
        crashed > 5,
        "the loop did not crash inside the migration ({crashed} crashes)"
    );
}

#[test]
fn downgrade_is_refused_unless_every_step_can_run_backwards() {
    let reg = registry();
    let info = component();
    let (mut kv, _) = seeded();
    Migrator::new(&mut kv, &reg, &info)
        .migrate(4, NOW + 10, &mut ())
        .unwrap();

    let refused = Migrator::new(&mut kv, &reg, &info).migrate(2, NOW + 20, &mut ());
    assert_eq!(
        refused.err().unwrap(),
        Error::DowngradeRefused { from: 4, to: 2 }
    );
    // Refused before the snapshot and before any write: still v4 with the v4 data.
    assert_eq!(Meta::read(&mut kv).unwrap().unwrap().schema_version, 4);
    assert!(user_entries(&kv).contains_key(b"index/count".as_slice()));

    let allow = MigrateOptions {
        allow_downgrade: true,
        ..Default::default()
    };
    let report = Migrator::new(&mut kv, &reg, &info)
        .options(allow.clone())
        .migrate(2, NOW + 30, &mut ())
        .unwrap();
    let names: Vec<&str> = report.steps.iter().map(|step| step.name.as_str()).collect();
    assert_eq!(names, vec!["index/count", "values/v3"]);
    let entries = user_entries(&kv);
    assert_eq!(entries.len(), 2);
    assert_eq!(entries.get(b"msg/a".as_slice()), Some(&b"alpha".to_vec()));
    assert_eq!(Meta::read(&mut kv).unwrap().unwrap().schema_version, 2);
    assert_eq!(
        Meta::read(&mut kv).unwrap().unwrap().last_migrated_at_ms,
        NOW + 30
    );

    // One step without a `down` refuses the whole downgrade: a version the component never produced
    // is worse than a refused request.
    let mixed = Registry::new(vec![
        Step::new(1, "a", |batch: &mut Batch| {
            batch.rename_prefix(b"m/", b"msg/")?;
            Ok(())
        })
        .down(|batch: &mut Batch| {
            batch.rename_prefix(b"msg/", b"m/")?;
            Ok(())
        }),
        Step::new(2, "b", |batch: &mut Batch| {
            let entries: Vec<(Vec<u8>, Vec<u8>)> = batch
                .prefix(b"msg/")
                .map(|(key, value)| (key.to_vec(), value.to_vec()))
                .collect();
            for (key, value) in entries {
                let mut next = b"v3:".to_vec();
                next.extend_from_slice(&value);
                batch.insert(&key, next)?;
            }
            Ok(())
        })
        .down(|batch: &mut Batch| {
            let entries: Vec<(Vec<u8>, Vec<u8>)> = batch
                .prefix(b"msg/")
                .map(|(key, value)| (key.to_vec(), value.to_vec()))
                .collect();
            for (key, value) in entries {
                batch.insert(&key, &value[3..])?;
            }
            Ok(())
        }),
        // v3 -> v4 has no reverse.
        Step::new(3, "c", |batch: &mut Batch| {
            let count = batch.prefix(b"msg/").count();
            batch.insert(b"index/count", count.to_string().as_bytes())?;
            Ok(())
        }),
    ])
    .unwrap();
    let (mut kv4, _) = seeded();
    Migrator::new(&mut kv4, &reg, &info)
        .migrate(4, NOW + 40, &mut ())
        .unwrap();
    assert!(matches!(
        Migrator::new(&mut kv4, &mixed, &info)
            .options(allow)
            .migrate(1, NOW + 50, &mut ()),
        Err(Error::NoMigrationPath {
            missing: 3,
            direction: Direction::Down,
            ..
        })
    ));
    // Nothing was written by the refused path.
    assert_eq!(Meta::read(&mut kv4).unwrap().unwrap().schema_version, 4);
}

#[test]
fn dry_run_reports_counts_and_writes_nothing() {
    let reg = registry();
    let info = component();
    let (mut kv, _) = seeded();
    let before = kv.entries().clone();
    let writes = kv.writes();
    // Any write at all is now a crash, so "dry" is proven, not promised.
    kv.set_write_budget(Some(0));
    let report = Migrator::new(&mut kv, &reg, &info).dry_run(4).unwrap();
    assert!(report.dry_run);
    assert_eq!(report.from, 1);
    assert_eq!(report.target, 4);
    assert_eq!(report.final_version, 4);
    assert!(!report.resumed);
    assert_eq!(
        report.totals,
        ChangeCounts { added: 3, removed: 2, changed: 2, unchanged: 2 }
    );
    assert_eq!(report.steps.len(), 3);
    assert_eq!(kv.entries(), &before);
    assert_eq!(kv.writes(), writes);
    assert!(journal(&mut kv).unwrap().is_none());
    // A plan that cannot run is refused exactly as the real run would refuse it.
    assert!(matches!(
        Migrator::new(&mut kv, &reg, &info).dry_run(9),
        Err(Error::NoMigrationPath { .. })
    ));
}

#[test]
#[cfg(feature = "snapshot")]
fn snapshot_round_trip_carries_version_and_provenance() {
    let reg = registry();
    let info = component();
    let (mut kv, _) = seeded();
    Migrator::new(&mut kv, &reg, &info)
        .migrate(4, NOW + 10, &mut ())
        .unwrap();

    let bytes = snapshot_bytes(&mut kv);
    let header = verify(&mut bytes.as_slice(), &ImportOptions::default()).unwrap();
    assert_eq!(header.format, SNAPSHOT_FORMAT);
    assert_eq!(header.schema_version, 4);
    assert_eq!(header.component, "wa-whatsapp");
    assert_eq!(header.component_version, "1.2.0");
    assert_eq!(header.component_sha256, SHA);
    assert_eq!(header.entries, 3);
    assert_eq!(header.sha256.len(), 64);

    let mut dest = MemKv::new();
    let opts = ImportOptions {
        expect_component: Some("wa-whatsapp".into()),
        expect_version: Some(4),
        ..Default::default()
    };
    let imported = import(&mut dest, &mut bytes.as_slice(), NOW + 20, &opts).unwrap();
    assert_eq!(imported, header);
    assert_eq!(user_entries(&dest), user_entries(&kv));
    let meta = Meta::read(&mut dest).unwrap().unwrap();
    assert_eq!(meta.schema_version, 4);
    assert_eq!(meta.component, "wa-whatsapp");
    assert_eq!(meta.last_migrated_by, SHA);
    assert_eq!(meta.created_at_ms, header.created_at_ms);
    assert_eq!(meta.last_migrated_at_ms, NOW + 20);

    // Importing over live data is refused without `replace`.
    assert_eq!(
        import(&mut dest, &mut bytes.as_slice(), NOW + 30, &opts)
            .err()
            .unwrap(),
        Error::NotEmpty { keys: 3 }
    );
    let replace = ImportOptions {
        replace: true,
        ..opts.clone()
    };
    import(&mut dest, &mut bytes.as_slice(), NOW + 30, &replace).unwrap();
    assert_eq!(user_entries(&dest), user_entries(&kv));

    // Every mismatch is refused before a write, and the live data survives.
    let wrong_version = ImportOptions {
        expect_version: Some(3),
        replace: true,
        ..Default::default()
    };
    assert!(matches!(
        import(&mut dest, &mut bytes.as_slice(), NOW + 40, &wrong_version),
        Err(Error::SchemaVersionMismatch { expected: 3, found: 4 })
    ));
    let wrong_owner = ImportOptions {
        expect_component: Some("someone-else".into()),
        replace: true,
        ..Default::default()
    };
    assert!(matches!(
        import(&mut dest, &mut bytes.as_slice(), NOW + 40, &wrong_owner),
        Err(Error::OwnerMismatch { .. })
    ));
    let wrong_pin = ImportOptions {
        expect_sha256: Some("0".repeat(64)),
        replace: true,
        ..Default::default()
    };
    assert!(matches!(
        import(&mut dest, &mut bytes.as_slice(), NOW + 40, &wrong_pin),
        Err(Error::ComponentMismatch { .. })
    ));
    assert_eq!(user_entries(&dest), user_entries(&kv));
}

#[test]
#[cfg(feature = "snapshot")]
fn snapshot_taken_in_memory_matches_the_streamed_export() {
    let (mut kv, _) = seeded();
    let meta = Meta::read(&mut kv).unwrap().unwrap();
    let taken = Snapshot::take(&mut kv, &meta, NOW, snapshot::DEFAULT_MAX_BYTES).unwrap();
    let streamed = snapshot_bytes(&mut kv);
    let header = verify(&mut streamed.as_slice(), &ImportOptions::default()).unwrap();
    assert_eq!(taken.header, header);
    // Reserved meta keys never travel: a snapshot cannot be used to forge a schema version.
    assert!(taken
        .entries
        .iter()
        .all(|(key, _)| !is_reserved(key)));

    let bytes = taken.to_vec(3).unwrap();
    let mut dest = MemKv::new();
    import(&mut dest, &mut bytes.as_slice(), NOW, &ImportOptions::default()).unwrap();
    assert_eq!(user_entries(&dest), user_entries(&kv));

    // A Snapshot whose header does not describe its entries refuses to be written.
    let mut broken = taken.clone();
    broken.entries.push((b"extra".to_vec(), b"1".to_vec()));
    assert!(matches!(broken.to_vec(3), Err(Error::Corrupt(_))));
}

#[test]
#[cfg(feature = "snapshot")]
fn export_paging_does_not_change_the_bytes() {
    let mut kv = MemKv::new();
    let info = component();
    open(&mut kv, &info, 1, NOW).unwrap();
    for index in 0..25u32 {
        kv.put(
            format!("k/{index:02}").as_bytes(),
            format!("value-{index}").as_bytes(),
        )
        .unwrap();
    }
    let meta = Meta::read(&mut kv).unwrap().unwrap();
    let mut one = Vec::new();
    export(
        &mut kv,
        &meta,
        &mut one,
        NOW,
        &ExportOptions { page: 1, ..Default::default() },
    )
    .unwrap();
    let mut seven = Vec::new();
    export(
        &mut kv,
        &meta,
        &mut seven,
        NOW,
        &ExportOptions { page: 7, ..Default::default() },
    )
    .unwrap();
    assert_eq!(one, seven);
    assert_eq!(
        verify(&mut one.as_slice(), &ImportOptions::default())
            .unwrap()
            .entries,
        25
    );
    // A size bound refuses instead of filling a disk.
    let mut bounded = Vec::new();
    assert!(matches!(
        export(
            &mut kv,
            &meta,
            &mut bounded,
            NOW,
            &ExportOptions { max_bytes: 16, ..Default::default() }
        ),
        Err(Error::Limit { .. })
    ));
}

/// Build a snapshot file by hand (correct checksum, chosen contents) so the reader's checks can be
/// tested one at a time.
#[cfg(feature = "snapshot")]
fn craft(head: serde_json::Value, entries: &[(&[u8], &[u8])], footer: (u64, u64)) -> Vec<u8> {
    let head = serde_json::to_vec(&head).unwrap();
    let mut payload = Vec::new();
    payload.extend_from_slice(&(head.len() as u32).to_le_bytes());
    payload.extend_from_slice(&head);
    for (key, value) in entries {
        payload.extend_from_slice(&(key.len() as u32).to_le_bytes());
        payload.extend_from_slice(key);
        payload.extend_from_slice(&(value.len() as u32).to_le_bytes());
        payload.extend_from_slice(value);
    }
    let digest = {
        use sha2::{Digest, Sha256};
        let digest: [u8; 32] = Sha256::digest(&payload).into();
        digest
    };
    payload.extend_from_slice(FOOTER_TAG);
    payload.extend_from_slice(&footer.0.to_le_bytes());
    payload.extend_from_slice(&footer.1.to_le_bytes());
    payload.extend_from_slice(&digest);
    let mut file = MAGIC.to_vec();
    file.extend(zstd::stream::encode_all(payload.as_slice(), 3).unwrap());
    file
}

#[cfg(feature = "snapshot")]
fn head_json(component: &str, version: &str, sha: &str, schema: u32) -> serde_json::Value {
    serde_json::json!({
        "format": SNAPSHOT_FORMAT,
        "schema_version": schema,
        "component": component,
        "component_version": version,
        "component_sha256": sha,
        "created_at_ms": NOW,
    })
}

#[test]
#[cfg(feature = "snapshot")]
fn corrupted_snapshots_are_rejected_in_every_way_it_matters() {
    let (mut kv, _) = seeded();
    let bytes = snapshot_bytes(&mut kv);
    let decompressed = |file: &[u8]| zstd::stream::decode_all(&file[MAGIC.len()..]).unwrap();
    let recompressed = |payload: &[u8]| {
        let mut file = MAGIC.to_vec();
        file.extend(zstd::stream::encode_all(payload, 3).unwrap());
        file
    };

    // Not a snapshot at all.
    let mut bad_magic = bytes.clone();
    bad_magic[0] = b'X';
    assert!(matches!(
        verify(&mut bad_magic.as_slice(), &ImportOptions::default()),
        Err(Error::Format(_))
    ));
    // Truncated.
    let short = &bytes[..bytes.len() - 5];
    assert!(verify(&mut short.to_vec().as_slice(), &ImportOptions::default()).is_err());
    // A byte changed in the payload with the old checksum still attached.
    let mut payload = decompressed(&bytes);
    let at = payload.windows(5).position(|w| w == b"1.2.0").unwrap();
    payload[at + 4] = b'1';
    assert!(matches!(
        verify(
            &mut recompressed(&payload).as_slice(),
            &ImportOptions::default()
        ),
        Err(Error::ChecksumMismatch { .. })
    ));
    // A footer that lies about the counts (its checksum region is untouched).
    let mut payload = decompressed(&bytes);
    let len = payload.len();
    payload[len - 48..len - 40].copy_from_slice(&99u64.to_le_bytes());
    assert!(matches!(
        verify(
            &mut recompressed(&payload).as_slice(),
            &ImportOptions::default()
        ),
        Err(Error::Format(_))
    ));
    // A decompression bomb is bounded, not allocated.
    assert!(matches!(
        verify(
            &mut bytes.as_slice(),
            &ImportOptions { max_bytes: 8, ..Default::default() }
        ),
        Err(Error::Limit { .. })
    ));
    // A reserved meta key smuggled into a valid file.
    let smuggled = craft(
        head_json("wa-whatsapp", "1.2.0", SHA, 4),
        &[(crate::meta::key::SCHEMA_VERSION, b"99")],
        (1, 6),
    );
    assert!(matches!(
        verify(&mut smuggled.as_slice(), &ImportOptions::default()),
        Err(Error::Corrupt(_))
    ));
    // A malformed owner is refused by the header check, before an import could write it into meta.
    let bad_owner = craft(
        head_json("bad component id", "1.2.0", SHA, 4),
        &[(b"k", b"v")],
        (1, 2),
    );
    assert!(matches!(
        verify(&mut bad_owner.as_slice(), &ImportOptions::default()),
        Err(Error::Corrupt(_))
    ));
    // A format newer than this build.
    let future = craft(
        serde_json::json!({"format": 9, "schema_version": 4, "component": "wa-whatsapp",
            "component_version": "1.2.0", "component_sha256": SHA, "created_at_ms": NOW}),
        &[(b"k", b"v")],
        (1, 2),
    );
    assert!(matches!(
        verify(&mut future.as_slice(), &ImportOptions::default()),
        Err(Error::Format(_))
    ));
}

#[test]
fn change_encoding_round_trips_and_refuses_corrupt_journals() {
    let changes = vec![
        Change::Put {
            key: b"k\x00\xff".to_vec(),
            value: Vec::new(),
        },
        Change::Del {
            key: b"gone".to_vec(),
        },
        Change::Put {
            key: b"big".to_vec(),
            value: vec![7u8; 4096],
        },
    ];
    let encoded = encode_changes(&changes);
    assert_eq!(decode_changes(&encoded).unwrap(), changes);
    assert!(decode_changes(&encode_changes(&[])).unwrap().is_empty());

    // Truncation at every byte is a refusal, never a panic.
    for cut in 0..encoded.len() {
        let mut short = encoded.clone();
        short.truncate(cut);
        assert!(decode_changes(&short).is_err(), "cut at {cut}");
    }
    let mut unknown_tag = encoded.clone();
    unknown_tag[8] = 9;
    assert!(matches!(
        decode_changes(&unknown_tag),
        Err(Error::Corrupt(_))
    ));
    let mut trailing = encoded.clone();
    trailing.push(0);
    assert!(matches!(decode_changes(&trailing), Err(Error::Corrupt(_))));
    let mut huge_count = encoded.clone();
    huge_count[4..8].copy_from_slice(&1_000_000u32.to_le_bytes());
    assert!(matches!(decode_changes(&huge_count), Err(Error::Corrupt(_))));

    // Well-formed bytes that address a reserved key are still refused: the journal is untrusted
    // input by the time it is read back.
    let mut reserved = Vec::new();
    reserved.extend_from_slice(b"WC1\0");
    reserved.extend_from_slice(&1u32.to_le_bytes());
    reserved.push(1);
    let key = crate::meta::key::SCHEMA_VERSION;
    reserved.extend_from_slice(&(key.len() as u32).to_le_bytes());
    reserved.extend_from_slice(key);
    reserved.extend_from_slice(&2u32.to_le_bytes());
    reserved.extend_from_slice(b"99");
    assert!(matches!(
        decode_changes(&reserved),
        Err(Error::Corrupt(_))
    ));

    // Two changes for one key cannot come from a diff and cannot be replayed safely.
    let del = &encoded[8..];
    // Re-use the second change (a Del of "gone") as a second entry by writing it twice.
    let mut second = Vec::new();
    second.extend_from_slice(b"WC1\0");
    second.extend_from_slice(&2u32.to_le_bytes());
    let del_bytes = &del[del.len() - 26..];
    second.extend_from_slice(del_bytes);
    second.extend_from_slice(del_bytes);
    assert!(matches!(decode_changes(&second), Err(Error::Corrupt(_))));
}

#[test]
#[cfg(feature = "snapshot")]
fn a_moved_namespace_migrates_after_import() {
    // The old node exports v1 data.
    let (mut source, _) = seeded();
    let bytes = snapshot_bytes(&mut source);
    // The new node has no state; it imports the move at the version it knows, then upgrades as usual.
    let mut dest = MemKv::new();
    let info = component();
    import(
        &mut dest,
        &mut bytes.as_slice(),
        NOW + 5,
        &ImportOptions {
            expect_component: Some("wa-whatsapp".into()),
            expect_version: Some(1),
            ..Default::default()
        },
    )
    .unwrap();
    let meta = open(&mut dest, &info, 1, NOW + 6).unwrap();
    assert_eq!(meta.schema_version, 1);
    let report = Migrator::new(&mut dest, &registry(), &info)
        .migrate(4, NOW + 10, &mut ())
        .unwrap();
    assert_eq!(report.final_version, 4);
    assert_eq!(
        user_entries(&dest).get(b"msg/a".as_slice()),
        Some(&b"v3:alpha".to_vec())
    );
    assert_eq!(Meta::read(&mut dest).unwrap().unwrap().schema_version, 4);
}

