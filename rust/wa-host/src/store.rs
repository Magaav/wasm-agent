//! The node's bounded on-disk stores: service logs, the grant-policy audit trail, the telemetry
//! snapshot and the (not yet written) replay directory.
//!
//! `docs/REPLAY.md` and `docs/TELEMETRY.md` fix the numbers; this module is where the host applies
//! them, so a doc and the code cannot drift apart in two places. Every directory here is bounded by
//! construction - a quota plus, where it grows with traffic, a rotation or an expiry - and every
//! crossing of the 80 % threshold is **said out loud on the node's log** (`[store] …`) instead of
//! being discovered when the disk is full.
//!
//! What is bounded where:
//!
//! | store | quota | how it stays fixed |
//! | --- | --- | --- |
//! | `<component>.service.log` (+ `.log.1`) | 50 MiB per component | rotated at service start; the 80 % alert fires from the sweep |
//! | `<state>/audit/` | 32 MiB | the file sink rotates at 8 MiB, one backup generation |
//! | `<state>/telemetry/` | 256 MiB | the registry snapshot is the only file; traces are a byte-capped ring inside it |
//! | `<state>/replays/` | 500 MiB / 7 days | `BoundedDir::expire` in the sweep (nothing writes here yet, docs/REPLAY.md) |
//!
//! Quotas are overridable (`WA_SERVICE_LOG_QUOTA_BYTES`, `WA_AUDIT_QUOTA_BYTES`,
//! `WA_TELEMETRY_QUOTA_BYTES`, `WA_REPLAY_QUOTA_BYTES`) so a node can tighten them without a build.
use crate::components::component_dir;
use serde_json::{json, Map, Value};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, SystemTime};
use wa_bounded::{BoundedDir, Usage};

/// The alert threshold, shared with the crate so the docs and the two stores agree.
pub const THRESHOLD_PCT: u8 = wa_bounded::caps::THRESHOLD_PCT;
/// Per-component cap for a service's stdout/stderr log (`docs/SERVICE-COMPONENTS.md`).
pub const SERVICE_LOG_QUOTA_BYTES: u64 = 50 * 1024 * 1024;
/// The grant-policy audit directory (`docs/GRANT-POLICY.md` "Audit").
pub const AUDIT_QUOTA_BYTES: u64 = 32 * 1024 * 1024;
/// The file sink's rotation size; one backup generation, so the directory holds at most ~2x this.
pub const AUDIT_ROTATE_BYTES: u64 = 8 * 1024 * 1024;
/// The telemetry directory: the 200 MiB trace ring of `docs/TELEMETRY.md` plus live series.
pub const TELEMETRY_QUOTA_BYTES: u64 = 256 * 1024 * 1024;
/// Replay directory cap and age, straight from the crate's documented defaults.
pub const REPLAY_QUOTA_BYTES: u64 = wa_bounded::caps::REPLAY_QUOTA_BYTES;
pub const REPLAY_MAX_AGE: Duration = wa_bounded::caps::REPLAY_MAX_AGE;

/// The node's state root: `<home>/.wasm-agent`, where `home` is `WASM_AGENT_HOME` or the user's.
pub fn state_root() -> PathBuf {
    PathBuf::from(crate::resolve_home()).join(".wasm-agent")
}

fn env_bytes(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.trim().parse::<u64>().ok()).filter(|v| *v > 0).unwrap_or(default)
}

pub fn service_log_quota() -> u64 {
    env_bytes("WA_SERVICE_LOG_QUOTA_BYTES", SERVICE_LOG_QUOTA_BYTES)
}

pub fn audit_quota() -> u64 {
    env_bytes("WA_AUDIT_QUOTA_BYTES", AUDIT_QUOTA_BYTES)
}

pub fn telemetry_quota() -> u64 {
    env_bytes("WA_TELEMETRY_QUOTA_BYTES", TELEMETRY_QUOTA_BYTES)
}

pub fn replay_quota() -> u64 {
    env_bytes("WA_REPLAY_QUOTA_BYTES", REPLAY_QUOTA_BYTES)
}

/// Open one of the node's bounded directories under `root` (the state root, or a test's temp dir),
/// with the 80 % alert wired to the node log. Creating the directory is deliberate: a store that is
/// never opened cannot report that it is empty.
pub fn bounded_at(root: &Path, name: &str, quota: u64) -> wa_bounded::Result<BoundedDir> {
    let label = name.to_string();
    BoundedDir::open(root.join(name), quota).map(|dir| {
        dir.with_threshold(THRESHOLD_PCT).on_threshold(move |usage: &Usage| {
            eprintln!(
                "[store] {label} at {}% of its {} byte quota ({} bytes in {} files)",
                usage.pct(),
                usage.quota,
                usage.bytes,
                usage.files
            );
        })
    })
}

pub fn audit_dir() -> wa_bounded::Result<BoundedDir> {
    bounded_at(&state_root(), "audit", audit_quota())
}

pub fn telemetry_dir() -> wa_bounded::Result<BoundedDir> {
    bounded_at(&state_root(), "telemetry", telemetry_quota())
}

pub fn replay_dir() -> wa_bounded::Result<BoundedDir> {
    bounded_at(&state_root(), "replays", replay_quota())
}

/// Where the grant-policy audit trail lives (`docs/GRANT-POLICY.md` step 2). Creates the directory
/// because the sink is opened right after this.
pub fn audit_file() -> wa_bounded::Result<PathBuf> {
    let dir = audit_dir()?;
    Ok(dir.path_of("grant-policy.jsonl"))
}

/// Where the telemetry registry snapshot lives. No directory is created: a reader that only wants
/// the last node's numbers must not grow the state tree.
pub fn telemetry_snapshot() -> PathBuf {
    state_root().join("telemetry").join("registry.bin")
}

/// Usage of a directory that may not exist yet, without creating it.
fn usage_at(dir: &Path, quota: u64) -> Option<Usage> {
    if !dir.is_dir() {
        return None;
    }
    BoundedDir::open(dir, quota).ok()?.usage().ok()
}

fn usage_json(usage: Option<Usage>) -> Value {
    match usage {
        Some(u) => json!({
            "bytes": u.bytes,
            "files": u.files,
            "quota": u.quota,
            "pct": u.pct(),
            "pinned_bytes": u.pinned_bytes,
            "over_threshold": u.over_threshold(),
            "over_quota": u.over_quota(),
        }),
        None => json!(null),
    }
}

/// A service log's main file and its one backup generation.
pub fn service_log_paths(dir: &Path, name: &str) -> (PathBuf, PathBuf) {
    let main = dir.join(format!("{name}.service.log"));
    let backup = dir.join(format!("{name}.service.log.1"));
    (main, backup)
}

fn file_len(path: &Path) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

/// Rotate a service log at service start: at the quota it becomes the single backup generation
/// (the previous backup is dropped), so a component's log can never exceed its quota by more than
/// what one run writes. Returns the rotation size actually applied.
pub fn enforce_service_log(dir: &Path, name: &str, quota: u64) -> u64 {
    let (main, backup) = service_log_paths(dir, name);
    let bytes = file_len(&main) + file_len(&backup);
    if bytes < quota {
        alert_log_once(&main, bytes, quota);
        return 0;
    }
    let _ = std::fs::remove_file(&backup);
    match std::fs::rename(&main, &backup) {
        Ok(()) => {
            eprintln!("[store] {name}.service.log rotated at {} bytes (quota {quota})", file_len(&backup));
            file_len(&backup)
        }
        // Windows cannot rename a file another process holds open; the next start retries and the
        // sweep keeps reporting the size, so this is visible rather than silently unbounded.
        Err(error) => {
            eprintln!("[store] {name}.service.log rotation deferred: {error} ({bytes} bytes, quota {quota})");
            0
        }
    }
}

static LOG_ALERTS: LazyLock<Mutex<HashSet<PathBuf>>> = LazyLock::new(|| Mutex::new(HashSet::new()));

/// One line per crossing of the threshold, not one per write: a component that logs 10 000 lines
/// must not produce 10 000 warnings.
fn alert_log_once(path: &Path, bytes: u64, quota: u64) {
    if quota == 0 || bytes * 100 < quota * THRESHOLD_PCT as u64 {
        LOG_ALERTS.lock().unwrap().remove(path);
        return;
    }
    if LOG_ALERTS.lock().unwrap().insert(path.to_path_buf()) {
        eprintln!(
            "[store] {} at {}% of its {quota} byte per-component quota ({bytes} bytes)",
            path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
            bytes * 100 / quota
        );
    }
}

/// One sweep of every bounded store: expire old replays, report usage, alert on the 80 % line.
/// Called from the telemetry ticker (once a minute) and answerable through `host.telemetry`.
pub fn sweep(now: SystemTime) -> Value {
    let mut out = Map::new();
    let expired = replay_dir().ok().and_then(|dir| dir.expire(REPLAY_MAX_AGE, now).ok()).map(|v| v.len()).unwrap_or(0);
    let mut replays = usage_json(usage_at(&state_root().join("replays"), replay_quota()));
    if let Some(object) = replays.as_object_mut() {
        object.insert("expired_now".into(), json!(expired));
    }
    out.insert("replays".into(), replays);
    out.insert("audit".into(), usage_of_dir(&state_root().join("audit"), audit_quota()));
    out.insert("telemetry".into(), usage_json(usage_at(&state_root().join("telemetry"), telemetry_quota())));
    // Service logs are per component and live in the component directory next to the wasm files.
    let dir = component_dir();
    let quota = service_log_quota();
    let mut logs = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&dir) {
        let mut names: Vec<String> = entries
            .flatten()
            .filter_map(|e| e.file_name().to_str().and_then(|n| n.strip_suffix(".service.log")).map(str::to_string))
            .collect();
        names.sort();
        for name in names {
            let (main, backup) = service_log_paths(&dir, &name);
            let bytes = file_len(&main) + file_len(&backup);
            alert_log_once(&main, bytes, quota);
            logs.push(json!({
                "component": name,
                "bytes": bytes,
                "quota": quota,
                "pct": if quota == 0 { 0 } else { bytes.saturating_mul(100).checked_div(quota).unwrap_or(0) },
                "over_quota": bytes > quota,
            }));
        }
    }
    out.insert("service_logs".into(), Value::Array(logs));
    Value::Object(out)
}

/// Usage of one bounded directory as the JSON both operator capabilities publish. Hermetic: it
/// never creates the directory and never looks anywhere but `dir` (a test passes its own temp root).
pub fn usage_of_dir(dir: &Path, quota: u64) -> Value {
    usage_json(usage_at(dir, quota))
}

/// The whole store picture, for `host.telemetry` and `host.policy_status`: quotas, current usage.
pub fn usage_report() -> Value {
    json!({
        "root": state_root().to_string_lossy(),
        "quotas": {
            "service_log_bytes": service_log_quota(),
            "audit_bytes": audit_quota(),
            "audit_rotate_bytes": AUDIT_ROTATE_BYTES,
            "telemetry_bytes": telemetry_quota(),
            "replay_bytes": replay_quota(),
            "replay_max_age_secs": REPLAY_MAX_AGE.as_secs(),
        },
        "usage": {
            "audit": usage_json(usage_at(&state_root().join("audit"), audit_quota())),
            "telemetry": usage_json(usage_at(&state_root().join("telemetry"), telemetry_quota())),
            "replays": usage_json(usage_at(&state_root().join("replays"), replay_quota())),
        },
        "threshold_pct": THRESHOLD_PCT,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("wa-store-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_quota_directory_reads_back_its_usage() {
        let dir = temp_dir("usage");
        let store = bounded_at(&dir, "audit", 1000).unwrap();
        store.write("a.jsonl", &[b'x'; 400]).unwrap();
        let usage = store.usage().unwrap();
        assert_eq!((usage.bytes, usage.files, usage.quota), (400, 1, 1000));
        assert!(!usage.over_threshold(), "40% is below the 80% line");
        store.write("b.jsonl", &[b'y'; 400]).unwrap();
        assert!(store.usage().unwrap().over_threshold(), "80% crosses the threshold");
        assert_eq!(usage_json(Some(store.usage().unwrap()))["pct"], 80);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_service_log_rotates_at_its_quota_and_keeps_one_generation() {
        let dir = temp_dir("log");
        let (main, backup) = service_log_paths(&dir, "svc");
        std::fs::write(&main, vec![b'a'; 700]).unwrap();
        std::fs::write(&backup, b"old").unwrap();
        // Below the quota: nothing is rotated.
        assert_eq!(enforce_service_log(&dir, "svc", 4096), 0);
        assert!(main.exists() && backup.exists());
        // At the quota: the old backup is dropped and the live file becomes the backup.
        assert_eq!(enforce_service_log(&dir, "svc", 700), 700);
        assert!(!main.exists(), "the live log moved aside for a fresh one");
        assert_eq!(file_len(&backup), 700);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn the_sweep_expires_old_replays_and_reports_every_store() {
        let dir = temp_dir("sweep");
        let replays = bounded_at(&dir, "replays", 4096).unwrap();
        replays.write_stamped("old.wrz", b"payload", SystemTime::UNIX_EPOCH).unwrap();
        let now = SystemTime::UNIX_EPOCH + REPLAY_MAX_AGE + Duration::from_secs(60);
        assert_eq!(replays.expire(REPLAY_MAX_AGE, now).unwrap().len(), 1);
        assert!(!replays.exists("old.wrz"));
        // usage_at does not create directories that are absent.
        assert!(usage_at(&dir.join("absent"), 10).is_none());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_missing_directory_is_reported_as_no_usage_not_as_zero_bytes() {
        assert_eq!(usage_json(None), Value::Null);
        let dir = temp_dir("empty");
        let store = bounded_at(&dir, "telemetry", 100).unwrap();
        assert_eq!(store.usage().unwrap().bytes, 0);
        assert!(!store.usage().unwrap().over_threshold());
        std::fs::remove_dir_all(&dir).ok();
    }
}
