//! The transactional install, proven against a real temp directory and the real SQLite store.
//!
//! Every test builds its own directory under the temp dir and never touches the node's own component
//! directory: an install test that used `~/.wasm-agent` would be a test that eats the operator's
//! data the day it goes wrong.

use super::*;
use serde_json::json;

fn temp_dir(tag: &str) -> PathBuf {
    let base = std::env::temp_dir().join(format!(
        "wa-state-host-{}-{}-{}",
        tag,
        std::process::id(),
        crate::state_host::now_ms()
    ));
    let _ = std::fs::remove_dir_all(&base);
    std::fs::create_dir_all(&base).expect("temp dir");
    base
}

/// An `Installed` without a file on disk: the install path only reads the name, the pin and the
/// manifest, and every one of those comes from the loader in production.
fn installed(name: &str, manifest: serde_json::Value) -> Installed {
    Installed { name: name.to_string(), sha256: "a".repeat(64), bytes: Vec::new(), manifest }
}

fn manifest(state_version: Option<u32>) -> serde_json::Value {
    let mut manifest = json!({"name": "svc-queue-echo", "kind": "service", "capabilities": {"storage": true}});
    if let Some(version) = state_version {
        manifest["state_version"] = json!(version);
    }
    manifest
}

#[test]
fn a_component_without_a_declaration_is_left_alone() {
    let dir = temp_dir("untracked");
    let outcome = prepare_install_in(&dir, &installed("svc-queue-echo", manifest(None))).unwrap();
    assert_eq!(outcome, StateOutcome::Untracked);
    assert!(!kv_path(&dir, "svc-queue-echo").exists(), "nothing opened a namespace they do not own");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_fresh_namespace_starts_at_the_declared_version() {
    let dir = temp_dir("fresh");
    let outcome = prepare_install_in(&dir, &installed("svc-queue-echo", manifest(Some(2)))).unwrap();
    assert_eq!(outcome, StateOutcome::Fresh { schema: 2 });
    // Not at v1: the version the component writes natively is where an empty namespace starts
    // (`docs/STATE.md`, rule 1).
    let mut kv = namespace_in(&dir, "svc-queue-echo");
    let meta = Meta::read(&mut kv).unwrap().unwrap();
    assert_eq!(meta.schema_version, 2);
    assert_eq!(meta.component, "svc-queue-echo");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn the_same_version_is_up_to_date_and_writes_nothing_new() {
    let dir = temp_dir("same");
    prepare_install_in(&dir, &installed("svc-queue-echo", manifest(Some(2)))).unwrap();
    let before = std::fs::read(kv_path(&dir, "svc-queue-echo")).unwrap();
    let outcome = prepare_install_in(&dir, &installed("svc-queue-echo", manifest(Some(2)))).unwrap();
    assert_eq!(outcome, StateOutcome::UpToDate { schema: 2 });
    assert!(!dir.join("svc-queue-echo.state.next").exists(), "no copy for a no-op");
    assert_eq!(std::fs::read(kv_path(&dir, "svc-queue-echo")).unwrap().len(), before.len());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_v1_namespace_is_migrated_on_a_copy_and_the_copy_is_swapped_in() {
    let dir = temp_dir("migrate");
    // v1: the component's data written by a previous build.
    {
        let mut kv = namespace_in(&dir, "svc-queue-echo");
        let info = ComponentInfo::new("svc-queue-echo", "1.0.0", &"b".repeat(64)).unwrap();
        meta::open(&mut kv, &info, 1, 1_000).unwrap();
        kv.put(b"note", b"written at v1").unwrap();
    }

    let outcome = prepare_install_in(&dir, &installed("svc-queue-echo", manifest(Some(2)))).unwrap();
    match &outcome {
        StateOutcome::Migrated { from, to, steps, changes, snapshot } => {
            assert_eq!((*from, *to, *steps), (1, 2, 1));
            assert_eq!(*changes, 2, "one key added, one removed");
            let snapshot = snapshot.as_ref().expect("a snapshot before the migration");
            assert!(snapshot.exists(), "the pre-migration snapshot is kept");
            // And it verifies, so it is a real backup and not just a file.
            assert_eq!(verify(snapshot)["ok"], json!(true));
        }
        other => panic!("expected a migration, got {other:?}"),
    }

    // The live namespace now has the v2 shape and a v2 metadata block.
    let mut kv = namespace_in(&dir, "svc-queue-echo");
    assert_eq!(kv.get(b"note/v2").unwrap().as_deref(), Some(&b"written at v1"[..]));
    assert_eq!(kv.get(b"note").unwrap(), None);
    let meta = Meta::read(&mut kv).unwrap().unwrap();
    assert_eq!(meta.schema_version, 2);
    assert_eq!(meta.component_version, "0.1.0");
    // The previous generation is kept as evidence, and the copy is gone (it *is* the live one).
    assert!(dir.join("svc-queue-echo.state.prev").exists());
    assert!(!dir.join("svc-queue-echo.state.next").exists());

    // A second install at the same version is a no-op on a namespace that is already there.
    assert_eq!(
        prepare_install_in(&dir, &installed("svc-queue-echo", manifest(Some(2)))).unwrap(),
        StateOutcome::UpToDate { schema: 2 }
    );
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_failed_migration_refuses_the_install_and_keeps_the_old_state() {
    let dir = temp_dir("refuse");
    {
        let mut kv = namespace_in(&dir, "svc-queue-echo");
        let info = ComponentInfo::new("svc-queue-echo", "1.0.0", &"b".repeat(64)).unwrap();
        meta::open(&mut kv, &info, 1, 1_000).unwrap();
        kv.put(b"note", b"written at v1").unwrap();
    }

    // v3 is a version no registered step reaches: the install must refuse *before* anything moves.
    let error = prepare_install_in(&dir, &installed("svc-queue-echo", manifest(Some(3)))).unwrap_err();
    // The registry exists but has no v2 -> v3 step: the refusal names the gap, before any write.
    assert!(error.starts_with("state_no_migration_path:1->3"), "{error}");

    // Nothing changed: the old data, at the old version, is what a rollback would find anyway.
    let mut kv = namespace_in(&dir, "svc-queue-echo");
    assert_eq!(kv.get(b"note").unwrap().as_deref(), Some(&b"written at v1"[..]));
    assert_eq!(Meta::read(&mut kv).unwrap().unwrap().schema_version, 1);
    assert!(!dir.join("svc-queue-echo.state.next").exists());
    // No snapshot either: a refusal must not look like work started (`docs/STATE.md`).
    assert!(snapshot_files(&dir, "svc-queue-echo").is_empty());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_namespace_that_belongs_to_another_component_is_never_adopted() {
    let dir = temp_dir("owner");
    {
        let mut kv = namespace_in(&dir, "svc-queue-echo");
        let info = ComponentInfo::new("someone-else", "1.0.0", &"b".repeat(64)).unwrap();
        meta::open(&mut kv, &info, 1, 1_000).unwrap();
    }
    let error = prepare_install_in(&dir, &installed("svc-queue-echo", manifest(Some(2)))).unwrap_err();
    assert!(error.starts_with("state_owner_mismatch"), "{error}");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn keys_without_metadata_are_refused_not_adopted() {
    let dir = temp_dir("uninitialised");
    {
        // A namespace written before metadata existed: the host must not guess a version for it.
        let mut kv = namespace_in(&dir, "svc-queue-echo");
        kv.put(b"loose", b"key").unwrap();
    }
    let error = prepare_install_in(&dir, &installed("svc-queue-echo", manifest(Some(1)))).unwrap_err();
    assert!(error.starts_with("state_open_failed"), "{error}");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn snapshot_export_import_and_status_round_trip() {
    let dir = temp_dir("snapshot");
    {
        let mut kv = namespace_in(&dir, "svc-queue-echo");
        let info = ComponentInfo::new("svc-queue-echo", "1.0.0", &"b".repeat(64)).unwrap();
        meta::open(&mut kv, &info, 1, 1_000).unwrap();
        kv.put(b"a", b"1").unwrap();
        kv.put(b"b", b"2").unwrap();
    }
    assert_eq!(status_in(&dir, "svc-queue-echo")["keys"], json!(2));

    let exported = export_in(&dir, "svc-queue-echo", None);
    assert_eq!(exported["ok"], json!(true), "{exported}");
    assert_eq!(exported["schema"], json!(1));
    assert_eq!(exported["entries"], json!(2));
    let path = PathBuf::from(exported["path"].as_str().unwrap());
    assert!(path.exists());
    assert_eq!(verify(&path)["ok"], json!(true));

    // A second component's namespace is empty, so the import needs no `replace`.
    let imported = import_in(&dir, "svc-queue-echo", &path, true);
    assert_eq!(imported["ok"], json!(true), "{imported}");
    assert_eq!(imported["entries"], json!(2));

    // Importing another component's snapshot into this name is refused by the header's identity.
    let wrong = import_in(&dir, "other", &path, true);
    assert_eq!(wrong["ok"], json!(false));
    assert!(wrong["error"].as_str().unwrap().starts_with("snapshot_import"), "{wrong}");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn the_host_store_is_the_kernel_kv() {
    // The adapter is only useful if it is the same store the component's own `wa:kernel/kv` writes:
    // a key set here is a key the kernel's `scan` returns, through the same SQLite file.
    let dir = temp_dir("store");
    let ns = namespace_in(&dir, "svc-queue-echo");
    ns.put(b"k", b"v").unwrap();
    let mut kernel = crate::service_io::Kv::new(Some(kv_path(&dir, "svc-queue-echo")));
    assert_eq!(kernel.get(b"k".to_vec()).unwrap().as_deref(), Some(&b"v"[..]));
    // And the reserved meta prefix is a normal key here: the refusal of `__wa/` writes is the state
    // view's job (`wa_state::UserView`), not the store's.
    ns.put(b"__wa/meta/schema", b"9").unwrap();
    assert!(kernel.get(b"__wa/meta/schema".to_vec()).unwrap().is_some());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn old_snapshots_are_pruned_but_the_newest_are_kept() {
    let dir = temp_dir("prune");
    for n in 0..6u32 {
        std::fs::write(dir.join(format!("svc-queue-echo.state.snapshot-{}", 1_000 + n)), b"x").unwrap();
    }
    prune_snapshots(&dir, "svc-queue-echo");
    let left = snapshot_files(&dir, "svc-queue-echo");
    assert_eq!(left.len(), SNAPSHOTS_KEPT);
    assert!(left.iter().all(|path| {
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        name.ends_with('5') || name.ends_with('4') || name.ends_with('3')
    }));
    let _ = std::fs::remove_dir_all(dir);
}
