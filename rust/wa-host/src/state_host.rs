//! State in the host: the transactional install, and the snapshot admin surface.
//!
//! `rust/wa-state` is the rule book made executable - schema versions, never-edited steps, a
//! journal, a snapshot format - and it is deliberately pure: no files, no clock, no store. This
//! module is the other half: the SQLite `wa_kv::Store` the three libraries run on, the install
//! sequence `docs/STATE.md` prescribes, and the operator's `status | export | import | verify`
//! tools.
//!
//! The install sequence, in the order it runs (`docs/STATE.md`, "Host integration"):
//!
//! 1. the caller has staged and pin-verified the component (`components::load`) and checked the
//!    contract it speaks; nothing has started;
//! 2. if the manifest declares `state_version`, the namespace is inspected: a namespace that does
//!    not exist starts at that version (`meta::open`), one that is already there is left alone;
//! 3. otherwise a **snapshot** of the live namespace is written to
//!    `<components>/<name>.state.snapshot-<unix-ms>` (bounded, verified, kept on failure);
//! 4. the snapshot is **imported into a copy** (`<name>.state.next/`) and the migration runs on the
//!    copy. A failure here returns an error, deletes the copy, and leaves the running instance and
//!    its state exactly as they were;
//! 5. only after the copy is at the declared version is it swapped in: `<name>.state` becomes
//!    `<name>.state.prev` and `<name>.state.next` becomes `<name>.state`. The previous directory is
//!    kept as evidence and removed by the next successful migration;
//! 6. the new instance starts against the migrated copy (`services::start` returns, and the
//!    supervisor waits for `lifecycle.report(ready)`); an install that never becomes ready is the
//!    supervisor's failure, not a silent success.
//!
//! Where the migration *steps* come from is the one decision a host has to make. `wa-state` says the
//! default is inside the component (the steps travel with the pinned artifact) and the alternative
//! is a sidecar. The host cannot run guest code before the guest starts, so what it can run are the
//! steps registered here by component id - the sidecar path, in-process. A manifest that declares a
//! `state_version` this host has no registered step for is **refused**
//! (`state_migration_unavailable`), never started on data whose shape nobody checked; the operator's
//! recourse is a sidecar install or a snapshot restore, both of which are explicit.
//!
//! Snapshot export/import is the admin capability `host.state` ([`capability`]), and it is also what
//! a node move uses: export here, import there at the snapshot's own version, then the ordinary
//! install migrates forward (`docs/STATE.md`, "Snapshots").

use crate::components::{component_dir, Installed};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use wa_kv::{Namespaced, Store};
use wa_state::{meta, ComponentInfo, Meta, Migrator, Registry, SnapshotSink, Step};

/// How many pre-migration snapshots a component's directory keeps. The migrator writes one per
/// upgrade; a node that upgrades often should not grow a directory forever, and three is enough to
/// walk back over a bad week.
const SNAPSHOTS_KEPT: usize = 3;

/// The largest namespace a migration will load, and the largest snapshot a file may decompress to.
/// A component above this is refused with a reason instead of being migrated in the dark.
const MAX_STATE_BYTES: u64 = 512 << 20;

/// The host store: the kernel's per-component SQLite kv behind `wa_kv::Store`.
///
/// `service_io::Kv` needs `&mut self` (it owns the lazily opened connection); the three library
/// traits disagree about the receiver; so the connection is behind a mutex here and every library
/// call takes it for the length of one statement. That is the same serialisation the 0.1 and 0.2
/// runners already impose on a component's own `wa:kernel/kv` calls.
#[derive(Clone)]
pub struct HostStore {
    kv: Arc<Mutex<crate::service_io::Kv>>,
}

impl HostStore {
    /// A store at one kv file. The file and its directory are created on the first call, exactly as
    /// `wa:kernel/kv` creates them, so an unopened namespace is an empty namespace.
    pub fn at(path: impl Into<PathBuf>) -> HostStore {
        HostStore { kv: Arc::new(Mutex::new(crate::service_io::Kv::new(Some(path.into())))) }
    }

    fn with<T>(&self, f: impl FnOnce(&mut crate::service_io::Kv) -> Result<T, String>) -> Result<T, String> {
        let mut kv = self.kv.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut kv)
    }
}

impl Store for HostStore {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, String> {
        self.with(|kv| kv.get(key.to_vec()))
    }

    fn put(&self, key: &[u8], value: &[u8]) -> Result<(), String> {
        self.with(|kv| kv.set(key.to_vec(), value.to_vec()))
    }

    fn del(&self, key: &[u8]) -> Result<(), String> {
        self.with(|kv| kv.delete(key.to_vec()))
    }

    fn delete_prefix(&self, prefix: &[u8]) -> Result<u64, String> {
        self.with(|kv| kv.delete_prefix(prefix.to_vec()).map(u64::from))
    }

    fn scan_page(&self, prefix: &[u8], cursor: Option<&[u8]>, limit: usize) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
        // `Kv::scan` clamps `limit` to 1..=10_000 itself; `0` means "the store's default page".
        let limit = if limit == 0 { 512 } else { limit.min(10_000) as u32 };
        self.with(|kv| kv.scan(prefix.to_vec(), cursor.map(<[u8]>::to_vec), limit))
    }
}

/// The kv file of a component's state directory.
pub fn kv_path(dir: &Path, name: &str) -> PathBuf {
    dir.join(format!("{name}.state")).join("kv.sqlite")
}

/// The directory a component's state lives in (`<components>/<name>.state`).
pub fn state_dir(dir: &Path, name: &str) -> PathBuf {
    dir.join(format!("{name}.state"))
}

/// The component's own namespace, rooted at its state directory. `prefix` is empty: the file *is*
/// the component's namespace, and `q/` / `b/` inside it are the queue's and the bus's
/// (`rust/wa-kv`).
pub fn namespace_in(dir: &Path, name: &str) -> Namespaced<HostStore> {
    Namespaced::new(Arc::new(HostStore::at(kv_path(dir, name))), "")
}

/// A heads-down sub-namespace, e.g. `q/` for the queue provider or `b/` for bus retention.
pub fn sub_namespace(dir: &Path, name: &str, suffix: &str) -> Namespaced<HostStore> {
    namespace_in(dir, name).child(suffix)
}

// ---- the registry of migration steps the host can run ---------------------------------------------

fn host_registry() -> &'static Mutex<BTreeMap<String, Arc<Registry>>> {
    static REGISTRY: OnceLock<Mutex<BTreeMap<String, Arc<Registry>>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(builtin_steps()))
}

fn step(from: u32, name: &'static str, f: fn(&mut wa_state::Batch) -> wa_state::Result<()>) -> Step {
    Step::new(from, name, f)
}

/// The steps this host build carries (the sidecar path, in-process).
///
/// Every entry is a shipped, never-edited step: `docs/STATE.md` rule 3. Adding one is adding a row
/// to the release that raises the component's `state_version`; editing one is a data-loss bug
/// against every node that already applied it.
fn builtin_steps() -> BTreeMap<String, Arc<Registry>> {
    let mut table = BTreeMap::new();
    // The fixture `svc-queue-echo` (rust/components/svc-queue-echo) writes its own kv note at v1 as
    // `note`; v2 moves it to `note/v2` and records the shape it is at. It exists to prove the
    // transactional install end to end in `scripts/test.sh`.
    let fixture = Registry::new(vec![step(1, "note/v2", |batch| {
        if let Some(value) = batch.get(b"note") {
            batch.insert(b"note/v2", value.to_vec())?;
            batch.remove(b"note");
        }
        Ok(())
    })])
    .expect("the svc-queue-echo step registry is contiguous");
    table.insert("svc-queue-echo".to_string(), Arc::new(fixture));
    table
}

/// Register (or replace) the migration registry for one component id. A sidecar host or a future
/// in-tree component uses this; the shipped table above is the default. It is also how a test proves
/// that a manifest declaring a version this host *can* migrate is installed rather than refused.
#[allow(dead_code)] // the injection point for a sidecar host or a test, not yet called by the node
pub fn register_steps(component: &str, registry: Registry) {
    host_registry()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(component.to_string(), Arc::new(registry));
}

/// The registry for a component id, if this host can migrate it.
pub fn registry_for(component: &str) -> Option<Arc<Registry>> {
    host_registry().lock().unwrap_or_else(|e| e.into_inner()).get(component).cloned()
}

// ---- the install ----------------------------------------------------------------------------------

/// What the manifest says about state. Absent `state_version` means the component owns its keys and
/// the host does not touch them (`docs/STATE.md`: migrations inside the artifact are the default).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateDeclaration {
    pub component: String,
    pub version: u32,
    pub semver: String,
}

impl StateDeclaration {
    pub fn from_manifest(name: &str, manifest: &Value) -> Option<StateDeclaration> {
        let version = manifest.get("state_version")?.as_u64()? as u32;
        // The id the namespace belongs to. Defaults to the installed name; a component that wants a
        // state id independent of the file it is installed as says so.
        let component = manifest.get("state_component").and_then(Value::as_str).unwrap_or(name).to_string();
        let semver = manifest
            .get("version")
            .and_then(Value::as_str)
            .filter(|v| wa_state::meta::is_semver(v))
            .unwrap_or("0.1.0")
            .to_string();
        Some(StateDeclaration { component, version: version.max(1), semver })
    }
}

/// What the install did, for the log and for `services::start`'s answer. Counts and versions only:
/// no key, no value, no path inside the namespace.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StateOutcome {
    /// The manifest declared no `state_version`: the guest owns its keys.
    Untracked,
    /// The namespace was empty and now carries `schema`.
    Fresh { schema: u32 },
    /// The namespace was already at `schema`.
    UpToDate { schema: u32 },
    /// A migration ran on a copy and the copy was swapped in.
    Migrated { from: u32, to: u32, steps: usize, changes: usize, snapshot: Option<PathBuf> },
}

impl StateOutcome {
    pub fn to_json(&self) -> Value {
        match self {
            StateOutcome::Untracked => json!({"state": "untracked"}),
            StateOutcome::Fresh { schema } => json!({"state": "fresh", "schema": schema}),
            StateOutcome::UpToDate { schema } => json!({"state": "up-to-date", "schema": schema}),
            StateOutcome::Migrated { from, to, steps, changes, snapshot } => json!({
                "state": "migrated",
                "from": from,
                "to": to,
                "steps": steps,
                "changes": changes,
                "snapshot": snapshot.as_ref().map(|p| p.to_string_lossy().to_string()),
            }),
        }
    }
}

fn now_ms() -> u64 {
    crate::node_telemetry::now_ms()
}

fn info_for(declared: &StateDeclaration, installed: &Installed) -> Result<ComponentInfo, String> {
    ComponentInfo::new(&declared.component, &declared.semver, &installed.sha256)
        .map_err(|e| format!("state_info_invalid:{}", reason(&e)))
}

fn reason(error: &wa_state::Error) -> String {
    // The crate's Display is written to be safe to log: keys, payloads and secrets are never in it.
    error.to_string().replace(' ', "_")
}

/// The transactional install. Called by `services::start` before the instance is created; an error
/// here means **nothing started** and the previous instance and its state are untouched.
///
/// Every namespace handle is scoped: a SQLite connection inside `<name>.state/` keeps the directory
/// busy, and Windows refuses to rename a directory that is. The handles are therefore dropped before
/// the swap, not left to the end of the function.
pub fn prepare_install_in(dir: &Path, installed: &Installed) -> Result<StateOutcome, String> {
    let Some(declared) = StateDeclaration::from_manifest(&installed.name, &installed.manifest) else {
        return Ok(StateOutcome::Untracked);
    };
    let info = info_for(&declared, installed)?;

    // 1. What is there now? One handle, dropped before anything else touches the directory.
    let current = {
        let mut kv = namespace_in(dir, &installed.name);
        let current = Meta::read(&mut kv)
            // A namespace with keys but no metadata is refused rather than adopted: `meta::open`
            // would be a silent restart at the declared version (`docs/STATE.md`).
            .map_err(|e| format!("state_unreadable:{}", reason(&e)))?;
        let Some(current) = current else {
            // Nothing has ever opened this namespace. Create it at the version the component writes
            // natively, not at v1 - and refuse to adopt keys that predate the metadata.
            let meta = meta::open(&mut kv, &info, declared.version, now_ms())
                .map_err(|e| format!("state_open_failed:{}", reason(&e)))?;
            return Ok(StateOutcome::Fresh { schema: meta.schema_version });
        };
        if current.component != declared.component {
            return Err(format!(
                "state_owner_mismatch:expected_{}_found_{}",
                declared.component, current.component
            ));
        }
        // An unfinished step means the data is mid-migration even when the version looks right, so
        // "up to date" is only true without a journal.
        let pending = wa_state::journal(&mut kv).map_err(|e| format!("state_journal_unreadable:{}", reason(&e)))?;
        if current.schema_version == declared.version && pending.is_none() {
            // Still record the build that is running now (`open` only touches `component-version`).
            meta::open(&mut kv, &info, declared.version, now_ms())
                .map_err(|e| format!("state_open_failed:{}", reason(&e)))?;
            return Ok(StateOutcome::UpToDate { schema: current.schema_version });
        }
        current
    };

    // 2. A step path this host can execute, or a refusal. The plan is checked *before* the
    // snapshot: a missing step must not leave a snapshot file behind as though work had started.
    let registry = registry_for(&declared.component).ok_or_else(|| {
        format!(
            "state_migration_unavailable:{}:{}->{}",
            declared.component, current.schema_version, declared.version
        )
    })?;
    registry
        .plan(current.schema_version, declared.version, false)
        .map_err(|e| format!("state_no_migration_path:{}->{}:{}", current.schema_version, declared.version, reason(&e)))?;

    // 3. Snapshot the live namespace. Read-only, bounded, checksummed; kept on failure.
    let snapshot_path = dir.join(format!("{}.state.snapshot-{}", installed.name, now_ms()));
    {
        let mut file = std::fs::File::create(&snapshot_path).map_err(|e| format!("state_snapshot_write:{e}"))?;
        let mut kv = namespace_in(dir, &installed.name);
        wa_state::export(&mut kv, &current, &mut file, now_ms(), &wa_state::ExportOptions::default())
            .map_err(|e| {
                let _ = std::fs::remove_file(&snapshot_path);
                format!("state_snapshot_failed:{}", reason(&e))
            })?;
    }

    // 4. Migrate a copy, never the live namespace.
    let next_dir = dir.join(format!("{}.state.next", installed.name));
    let _ = std::fs::remove_dir_all(&next_dir);
    let report = match migrate_copy(&next_dir, &snapshot_path, &info, &registry, declared.version, &current) {
        Ok(report) => report,
        Err(error) => {
            // The copy is evidence, not a rollback path; the live namespace was never touched.
            let _ = std::fs::remove_dir_all(&next_dir);
            return Err(error);
        }
    };

    // 5. Swap, with every connection closed.
    swap_in(dir, &installed.name)?;
    prune_snapshots(dir, &installed.name);

    Ok(StateOutcome::Migrated {
        from: report.from,
        to: report.final_version,
        steps: report.steps.len(),
        changes: report.totals.total(),
        snapshot: Some(snapshot_path),
    })
}

fn migrate_copy(
    next_dir: &Path,
    snapshot_path: &Path,
    info: &ComponentInfo,
    registry: &Registry,
    target: u32,
    current: &Meta,
) -> Result<wa_state::MigrationReport, String> {
    std::fs::create_dir_all(next_dir).map_err(|e| format!("state_copy_create:{e}"))?;
    let mut copy = Namespaced::new(Arc::new(HostStore::at(next_dir.join("kv.sqlite"))), "");
    {
        let mut file = std::fs::File::open(snapshot_path).map_err(|e| format!("state_snapshot_read:{e}"))?;
        let options = wa_state::ImportOptions {
            expect_component: Some(current.component.clone()),
            replace: true,
            expect_version: Some(current.schema_version),
            expect_sha256: None,
            max_bytes: MAX_STATE_BYTES,
        };
        wa_state::import(&mut copy, &mut file, now_ms(), &options)
            .map_err(|e| format!("state_import_failed:{}", reason(&e)))?;
    }
    // Open with the version the *data* is at: the copy is a snapshot, not a fresh namespace.
    meta::open(&mut copy, info, current.schema_version, now_ms()).map_err(|e| format!("state_copy_open:{}", reason(&e)))?;
    let mut migrator = Migrator::new(&mut copy, registry, info);
    migrator
        .migrate(target, now_ms(), &mut CopySink)
        .map_err(|e| format!("state_migration_failed:{}", reason(&e)))
}

/// The copy's own pre-migration snapshot is already on disk (it is the file the copy was imported
/// from), so the migrator's mandatory snapshot is not written a second time.
struct CopySink;

impl SnapshotSink for CopySink {
    fn write(&mut self, _meta: &Meta, _snapshot: &wa_state::Snapshot) -> wa_state::Result<()> {
        Ok(())
    }
}

fn swap_in(dir: &Path, name: &str) -> Result<(), String> {
    let live = state_dir(dir, name);
    let next = dir.join(format!("{name}.state.next"));
    let previous = dir.join(format!("{name}.state.prev"));
    // Windows refuses to rename a directory while a file inside it is open, so the previous
    // generation is removed first. A failed remove is reported: continuing would rename over it and
    // that is a silent loss of the only copy of the old data.
    if previous.exists() {
        std::fs::remove_dir_all(&previous).map_err(|e| format!("state_previous_busy:{e}"))?;
    }
    if live.exists() {
        std::fs::rename(&live, &previous).map_err(|e| format!("state_swap_failed:{e}"))?;
    }
    if let Err(error) = std::fs::rename(&next, &live) {
        // Put the old directory back: a swap that failed half way must not leave a component with
        // no state at all.
        let _ = std::fs::rename(&previous, &live);
        return Err(format!("state_swap_failed:{error}"));
    }
    Ok(())
}

/// Keep the newest `SNAPSHOTS_KEPT` snapshots of one component. Best effort: a missing file is not a
/// failure, and this never deletes the snapshot of the upgrade that just ran.
fn prune_snapshots(dir: &Path, name: &str) {
    let prefix = format!("{name}.state.snapshot-");
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut files: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with(&prefix))
        })
        .collect();
    files.sort();
    while files.len() > SNAPSHOTS_KEPT {
        let oldest = files.remove(0);
        let _ = std::fs::remove_file(oldest);
    }
}

/// `prepare_install_in` under the installed component directory (`WA_COMPONENTS_DIR`).
pub fn prepare_install(installed: &Installed) -> Result<StateOutcome, String> {
    prepare_install_in(&component_dir(), installed)
}

// ---- the admin surface: status, export, import, verify, dry run ------------------------------------

/// One component's state, as `host.state({action:"status"})` reports it. Counts, versions and paths
/// only: no key, no value, no payload.
pub fn status_in(dir: &Path, name: &str) -> Value {
    let path = kv_path(dir, name);
    if !path.exists() {
        return json!({"ok": true, "name": name, "state": "none", "kv": path.to_string_lossy()});
    }
    let mut kv = namespace_in(dir, name);
    match Meta::read(&mut kv) {
        Ok(None) => json!({"ok": true, "name": name, "state": "uninitialised", "kv": path.to_string_lossy()}),
        Ok(Some(meta)) => {
            let journal = wa_state::journal(&mut kv).ok().flatten();
            let keys = wa_state::meta::user_keys(&mut kv).map(|keys| keys.len()).unwrap_or(0);
            let pending = journal.as_ref().and_then(|j| j.pending_step.as_ref()).map(|p| {
                json!({"from": p.from, "to": p.to, "name": p.name, "applied": p.applied})
            });
            json!({
                "ok": true,
                "name": name,
                "state": "ready",
                "kv": path.to_string_lossy(),
                "schema": meta.schema_version,
                "component": meta.component,
                "component_version": meta.component_version,
                "last_migrated_by": meta.last_migrated_by,
                "last_migrated_at_ms": meta.last_migrated_at_ms,
                "keys": keys,
                "journal": pending,
                "snapshots": snapshot_files(dir, name).len(),
                "host_steps": registry_for(&meta.component).map(|r| r.len()).unwrap_or(0),
            })
        }
        Err(error) => json!({"ok": false, "name": name, "error": format!("state_unreadable:{}", reason(&error))}),
    }
}

pub fn status(name: &str) -> Value {
    status_in(&component_dir(), name)
}

fn snapshot_files(dir: &Path, name: &str) -> Vec<PathBuf> {
    let prefix = format!("{name}.state.snapshot-");
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut files: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with(&prefix))
        })
        .collect();
    files.sort();
    files
}

/// Export one namespace to `out` (or to a fresh `<name>.state.snapshot-<ms>` in `dir`). Returns the
/// file's path, its size and the snapshot header's identity - what an operator writes down.
pub fn export_in(dir: &Path, name: &str, out: Option<&Path>) -> Value {
    let kv = namespace_in(dir, name);
    let mut kv = kv.clone();
    let Ok(Some(meta)) = Meta::read(&mut kv) else {
        return json!({"ok": false, "error": "state_uninitialised"});
    };
    let path = out.map(Path::to_path_buf).unwrap_or_else(|| dir.join(format!("{name}.state.snapshot-{}", now_ms())));
    let written = (|| -> Result<Value, String> {
        let mut file = std::fs::File::create(&path).map_err(|e| format!("snapshot_write:{e}"))?;
        let header = wa_state::export(&mut kv, &meta, &mut file, now_ms(), &wa_state::ExportOptions::default())
            .map_err(|e| format!("snapshot_export:{}", reason(&e)))?;
        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        Ok(json!({
            "ok": true,
            "name": name,
            "path": path.to_string_lossy(),
            "bytes": size,
            "schema": header.schema_version,
            "component": header.component,
            "component_version": header.component_version,
            "sha256": header.component_sha256,
            "entries": header.entries,
        }))
    })();
    written.unwrap_or_else(|error| json!({"ok": false, "error": error}))
}

pub fn export(name: &str, out: Option<&Path>) -> Value {
    export_in(&component_dir(), name, out)
}

/// Import a snapshot file into one namespace. `replace` is required over a non-empty namespace and
/// `component` is required: an import that adopted another component's data would be a silent
/// ownership change (`docs/STATE.md`).
pub fn import_in(dir: &Path, name: &str, path: &Path, replace: bool) -> Value {
    let mut kv = namespace_in(dir, name);
    let result = (|| -> Result<Value, String> {
        let mut file = std::fs::File::open(path).map_err(|e| format!("snapshot_open:{e}"))?;
        let options = wa_state::ImportOptions {
            expect_component: Some(name.to_string()),
            replace,
            expect_version: None,
            expect_sha256: None,
            max_bytes: MAX_STATE_BYTES,
        };
        let header = wa_state::import(&mut kv, &mut file, now_ms(), &options)
            .map_err(|e| format!("snapshot_import:{}", reason(&e)))?;
        Ok(json!({
            "ok": true,
            "name": name,
            "schema": header.schema_version,
            "component": header.component,
            "entries": header.entries,
        }))
    })();
    result.unwrap_or_else(|error| json!({"ok": false, "error": error}))
}

pub fn verify(path: &Path) -> Value {
    let result = (|| -> Result<Value, String> {
        let mut file = std::fs::File::open(path).map_err(|e| format!("snapshot_open:{e}"))?;
        let options = wa_state::ImportOptions { max_bytes: MAX_STATE_BYTES, ..Default::default() };
        let header = wa_state::verify(&mut file, &options).map_err(|e| format!("snapshot_verify:{}", reason(&e)))?;
        Ok(json!({
            "ok": true,
            "path": path.to_string_lossy(),
            "schema": header.schema_version,
            "component": header.component,
            "component_version": header.component_version,
            "sha256": header.component_sha256,
            "entries": header.entries,
        }))
    })();
    result.unwrap_or_else(|error| json!({"ok": false, "error": error}))
}

/// What a migration to `target` would change, without writing anything (not even a timestamp).
pub fn dry_run_in(dir: &Path, name: &str, target: Option<u32>) -> Value {
    let Some(declared) = declaration_from_dir(dir, name) else {
        return json!({"ok": false, "error": "state_not_declared"});
    };
    let target = target.unwrap_or(declared.version);
    let Some(registry) = registry_for(&declared.component) else {
        return json!({"ok": false, "error": format!("state_migration_unavailable:{}", declared.component)});
    };
    let mut kv = namespace_in(dir, name);
    let result = (|| -> Result<Value, String> {
        let meta = Meta::read(&mut kv).map_err(|e| format!("state_unreadable:{}", reason(&e)))?.ok_or("state_uninitialised")?;
        let info = ComponentInfo::new(&meta.component, &meta.component_version, &meta.last_migrated_by)
            .map_err(|e| format!("state_info_invalid:{}", reason(&e)))?;
        let mut migrator = Migrator::new(&mut kv, &registry, &info);
        let report = migrator.dry_run(target).map_err(|e| format!("state_dry_run:{}", reason(&e)))?;
        Ok(json!({
            "ok": true,
            "name": name,
            "from": report.from,
            "to": report.final_version,
            "steps": report.steps.len(),
            "changes": report.totals.total(),
            "dry_run": true,
        }))
    })();
    result.unwrap_or_else(|error| json!({"ok": false, "error": error}))
}

fn declaration_from_dir(dir: &Path, name: &str) -> Option<StateDeclaration> {
    let manifest = std::fs::read_to_string(dir.join(format!("{name}.json"))).ok()?;
    let manifest: Value = serde_json::from_str(&manifest).ok()?;
    StateDeclaration::from_manifest(name, &manifest)
}

/// `host.state(request_json)`: `{action: status|export|import|verify|dry-run, name, path, replace,
/// target}`. An operator tool, not a component-facing one: it moves a whole namespace and a
/// component never sees it.
pub extern "C-unwind" fn capability(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => {
            let name = request.get("name").and_then(Value::as_str).unwrap_or_default().to_string();
            let path = request.get("path").and_then(Value::as_str).map(PathBuf::from);
            match request.get("action").and_then(Value::as_str).unwrap_or_default() {
                "status" if name.is_empty() => {
                    let dir = component_dir();
                    let mut list: Vec<Value> = std::fs::read_dir(&dir)
                        .map(|entries| {
                            entries
                                .flatten()
                                .filter_map(|entry| {
                                    let name = entry.file_name().to_string_lossy().to_string();
                                    name.strip_suffix(".state").map(str::to_string)
                                })
                                .map(|name| status_in(&dir, &name))
                                .collect()
                        })
                        .unwrap_or_default();
                    list.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
                    json!({"ok": true, "states": list})
                }
                "status" => status(&name),
                "export" => export(&name, path.as_deref()),
                "import" => match path {
                    Some(path) => {
                        let replace = request.get("replace").and_then(Value::as_bool).unwrap_or(false);
                        import_in(&component_dir(), &name, &path, replace)
                    }
                    None => json!({"ok": false, "error": "state_path_required"}),
                },
                "verify" => match path {
                    Some(path) => verify(&path),
                    None => json!({"ok": false, "error": "state_path_required"}),
                },
                "dry-run" => {
                    let target = request.get("target").and_then(Value::as_u64).map(|n| n as u32);
                    dry_run_in(&component_dir(), &name, target)
                }
                other => json!({"ok": false, "error": format!("state_action_unknown:{other}")}),
            }
        }
        Err(_) => json!({"ok": false, "error": "state_request_invalid"}),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

#[cfg(test)]
pub(crate) mod tests;
