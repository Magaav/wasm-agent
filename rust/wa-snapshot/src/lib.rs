//! Consistent, checked snapshots of SQLite stores that are being written.
//!
//! The pre-update backup used to read a store with `VACUUM INTO` and check the result, which is the
//! right idea, but it treated every failure as final. On 07/11 three `wa update`s on two nodes
//! refused with
//!
//! ```text
//! backup_failed: .../graph.db.d/graph.db: database disk image is malformed
//! ```
//!
//! while the same file passed `PRAGMA quick_check` immediately afterwards and the second `wa update`
//! succeeded: the store was being written (WAL/checkpoint in progress) and the copy read a torn state.
//! A backup that refuses on contention costs the operator an update; a backup that silently accepts a
//! torn copy costs them the only recovery source they have.
//!
//! This crate keeps both halves:
//!
//! * **Never a byte copy.** A store is read through SQLite's *online backup API*
//!   (`sqlite3_backup_*`) from a connection with a busy timeout, page batch by page batch. A step
//!   that cannot get the pages reports [`StepResult::Busy`]/[`StepResult::Locked`] instead of
//!   tearing the read, so the failure is a decision, not an accident.
//! * **Retry contention, refuse damage.** `SQLITE_BUSY`, `SQLITE_LOCKED` and a read that reports a
//!   malformed image are retried with backoff, up to [`Policy::attempts`]. Before a retry the
//!   **source** is asked `PRAGMA quick_check`; a source that reports a problem twice (one torn read
//!   is contention) is damage, and the snapshot is refused immediately with the SQLite verdict as
//!   the message — the same `backup_failed: <store>: database disk image is malformed` an operator
//!   saw before, so the wording and the decision stay recognisable.
//! * **Check the copy.** The new file passes `PRAGMA integrity_check` before it is published. It is
//!   written as `<copy>.partial` and renamed only then, so a failed attempt can never leave
//!   something that looks like a snapshot.
//!
//! Not claimed: one simultaneous snapshot of several stores (each store is consistent on its own),
//! and no compaction — the online backup API copies the store page for page, so a copy is as large as
//! its source. `VACUUM INTO` shrinks; it also gives one opaque statement instead of steps that can
//! see `busy`, which is the trade this crate makes on purpose.

use rusqlite::backup::{Backup, StepResult};
use rusqlite::{Connection, OpenFlags};
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

/// How hard to try before one store is declared unsnapshottable.
#[derive(Clone, Copy, Debug)]
pub struct Policy {
    /// How long SQLite itself waits for a lock before a step returns busy (`PRAGMA busy_timeout`).
    pub busy_timeout: Duration,
    /// How many attempts one store gets before the backup is refused.
    pub attempts: u32,
    /// Pages per backup step. A step is the unit that can observe `busy`.
    pub page_batch: i32,
    /// Backoff base: attempt *n* waits `backoff * n`.
    pub backoff: Duration,
}

impl Default for Policy {
    fn default() -> Self {
        Policy {
            busy_timeout: Duration::from_secs(15),
            attempts: 3,
            page_batch: 256,
            backoff: Duration::from_millis(250),
        }
    }
}

/// A store that was copied, checked, and published.
#[derive(Clone, Debug)]
pub struct Snapshot {
    pub source: PathBuf,
    pub copy: PathBuf,
    /// The verdict of `PRAGMA integrity_check` on the copy; `"ok"` or the snapshot is not published.
    pub check: String,
    /// Which attempt succeeded (1 = no contention was seen).
    pub attempts: u32,
    /// Pages copied, counting the steps taken.
    pub pages: u32,
}

/// Why one store could not be snapshotted. Every variant is a refusal, never a quiet success.
#[derive(Debug)]
pub enum SnapshotError {
    /// The store stayed busy or locked for the whole retry budget.
    Busy {
        source: PathBuf,
        attempts: u32,
        detail: String,
    },
    /// `PRAGMA quick_check` on the *source* failed: damaged, not contended.
    SourceCorrupt { source: PathBuf, detail: String },
    /// The copy does not pass `PRAGMA integrity_check`.
    CopyCorrupt {
        source: PathBuf,
        copy: PathBuf,
        detail: String,
    },
    /// The store could not be read or the copy could not be written.
    Io { source: PathBuf, detail: String },
}

impl fmt::Display for SnapshotError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            // The operator-facing wording `wa update` already prints; a damaged store keeps exactly
            // the message it had before this crate existed.
            SnapshotError::SourceCorrupt { source, detail } => {
                write!(f, "backup_failed: {}: {}", source.display(), detail)
            }
            SnapshotError::Busy {
                source,
                attempts,
                detail,
            } => write!(
                f,
                "backup_failed: {}: {} (the store stayed busy for {} attempts; it is still being written, and the source passes quick_check)",
                source.display(),
                detail,
                attempts
            ),
            SnapshotError::CopyCorrupt {
                source,
                copy,
                detail,
            } => write!(
                f,
                "backup_corrupt: {}: {} (the copy of {} did not pass integrity_check)",
                copy.display(),
                detail,
                source.display()
            ),
            SnapshotError::Io { source, detail } => {
                write!(f, "backup_failed: {}: {}", source.display(), detail)
            }
        }
    }
}

impl std::error::Error for SnapshotError {}

impl SnapshotError {
    /// The one thing an operator needs to know: is the store damaged, or was it just busy?
    pub fn source_is_damaged(&self) -> bool {
        matches!(self, SnapshotError::SourceCorrupt { .. })
    }
}

/// Snapshot `source` to `copy`, which must not exist, with the default [`Policy`].
pub fn snapshot(source: &Path, copy: &Path) -> Result<Snapshot, SnapshotError> {
    snapshot_with(source, copy, &Policy::default())
}

/// Snapshot `source` to `copy` under `policy`. The copy is written beside itself as
/// `<copy>.partial` and renamed on success, so the destination name is either a checked snapshot or
/// absent.
pub fn snapshot_with(
    source: &Path,
    copy: &Path,
    policy: &Policy,
) -> Result<Snapshot, SnapshotError> {
    if copy.exists() {
        return Err(SnapshotError::Io {
            source: copy.to_path_buf(),
            detail: "the snapshot target already exists; a snapshot is never overwritten".into(),
        });
    }
    let partial = partial_path(copy);
    let attempts_limit = policy.attempts.max(1);
    let mut attempts = 0;
    let mut last = String::from("no attempt was made");
    while attempts < attempts_limit {
        attempts += 1;
        // Our own leftover from the previous attempt; never someone else's file.
        let _ = fs::remove_file(&partial);
        match copy_once(source, &partial, policy) {
            Ok(pages) => {
                if let Err(error) = fs::rename(&partial, copy) {
                    let _ = fs::remove_file(&partial);
                    return Err(SnapshotError::Io {
                        source: source.to_path_buf(),
                        detail: format!("the checked copy could not be published: {error}"),
                    });
                }
                return Ok(Snapshot {
                    source: source.to_path_buf(),
                    copy: copy.to_path_buf(),
                    check: "ok".into(),
                    attempts,
                    pages,
                });
            }
            Err(failure) => {
                last = failure.detail;
                let _ = fs::remove_file(&partial);
                // The source decides whether this was contention or damage. Asked before the retry,
                // so a damaged store is refused at the first attempt instead of after the budget.
                if let Some(verdict) = source_damage(source, policy) {
                    return Err(SnapshotError::SourceCorrupt {
                        source: source.to_path_buf(),
                        detail: verdict,
                    });
                }
                if !failure.transient {
                    return Err(SnapshotError::Io {
                        source: source.to_path_buf(),
                        detail: last,
                    });
                }
                if attempts < attempts_limit {
                    thread::sleep(policy.backoff * attempts);
                }
            }
        }
    }
    Err(SnapshotError::Busy {
        source: source.to_path_buf(),
        attempts,
        detail: last,
    })
}

/// `PRAGMA quick_check` on one store, through a read-only connection.
pub fn quick_check(store: &Path) -> Result<String, String> {
    pragma_verdict(store, "quick_check")
}

/// `PRAGMA integrity_check` on one store, through a read-only connection.
pub fn integrity_check(store: &Path) -> Result<String, String> {
    pragma_verdict(store, "integrity_check")
}

fn pragma_verdict(store: &Path, pragma: &str) -> Result<String, String> {
    let connection = Connection::open_with_flags(store, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|error| error.to_string())?;
    let mut statement = connection
        .prepare(&format!("PRAGMA {pragma}"))
        .map_err(|error| error.to_string())?;
    let mut rows = statement.query([]).map_err(|error| error.to_string())?;
    let mut problems: Vec<String> = Vec::new();
    let mut saw_ok = false;
    while let Some(row) = rows.next().map_err(|error| error.to_string())? {
        let text: String = row.get(0).map_err(|error| error.to_string())?;
        if text == "ok" {
            saw_ok = true;
        } else {
            problems.push(text);
        }
    }
    match problems.first() {
        Some(problem) => Ok(problem.clone()),
        None if saw_ok => Ok("ok".into()),
        None => Ok("unknown".into()),
    }
}

/// Is the store itself damaged? `Some(verdict)` when two independent checks agree it is; `None` when
/// it is sound, or when the check could not run (a busy store is not evidence of damage).
fn source_damage(source: &Path, policy: &Policy) -> Option<String> {
    match quick_check(source) {
        Ok(verdict) if verdict == "ok" => None,
        Ok(verdict) => confirm_damage(source, policy, verdict),
        // A check that stops with a corruption verdict (`database disk image is malformed` is how
        // SQLite answers for a damaged b-tree) is evidence; one that stops because it could not read
        // the store at all (busy, locked, no permission) is not.
        Err(detail) if names_corruption(&detail) => confirm_damage(source, policy, detail),
        Err(_) => None,
    }
}

/// One failed check is contention; two are damage. The second read is what stops a store that was
/// torn by a writer for a moment from being declared corrupt — and vice versa: a store that is really
/// damaged fails both times, so nothing is retried into a false pass.
fn confirm_damage(source: &Path, policy: &Policy, first: String) -> Option<String> {
    thread::sleep(policy.backoff);
    match quick_check(source) {
        Ok(verdict) if verdict == "ok" => None,
        Ok(verdict) => Some(verdict),
        Err(detail) if names_corruption(&detail) => Some(detail),
        // The first read said damaged and the second could not run: refuse rather than call a damaged
        // store sound because someone was holding it.
        Err(_) => Some(first),
    }
}

/// Whether a SQLite error is the store's own damage rather than a lock or a permission problem.
fn names_corruption(detail: &str) -> bool {
    let lower = detail.to_ascii_lowercase();
    ["malformed", "not a database", "corrupt", "checksum"]
        .iter()
        .any(|marker| lower.contains(marker))
}

struct Failure {
    detail: String,
    /// Contention (or a read that a writer tore): worth another attempt.
    transient: bool,
}

impl Failure {
    fn classify(detail: String) -> Failure {
        let lower = detail.to_ascii_lowercase();
        // `database disk image is malformed` and `file is not a database` are what a read of a store
        // a writer is holding *looks* like on the nodes we have; whether it is really damage is
        // decided by `source_damage`, never by the wording.
        let transient = [
            "database is locked",
            "database table is locked",
            "database schema is locked",
            "sqlite_busy",
            "sqlite_locked",
            "database disk image is malformed",
            "file is not a database",
        ]
        .iter()
        .any(|marker| lower.contains(marker));
        Failure { detail, transient }
    }

    fn contention(detail: impl Into<String>) -> Failure {
        Failure {
            detail: detail.into(),
            transient: true,
        }
    }
}

/// One attempt: online copy into `partial`, then check the copy. `Ok(pages)` means the copy is
/// complete and passes `integrity_check`.
fn copy_once(source: &Path, partial: &Path, policy: &Policy) -> Result<u32, Failure> {
    let from = open_source(source, policy).map_err(|error| {
        Failure::classify(format!("{}: {error}", source.display()))
    })?;
    let mut to = Connection::open(partial).map_err(|error| Failure {
        detail: format!("{}: {error}", partial.display()),
        transient: false,
    })?;
    let pages = {
        let backup = Backup::new(&from, &mut to)
            .map_err(|error| Failure::classify(format!("backup_start: {error}")))?;
        let mut steps: u32 = 0;
        loop {
            match backup.step(policy.page_batch) {
                Ok(StepResult::Done) => break,
                Ok(StepResult::Busy) => {
                    return Err(Failure::contention("database is locked (the store is being written)"))
                }
                Ok(StepResult::Locked) => {
                    return Err(Failure::contention("database table is locked (the store is being written)"))
                }
                Ok(_) => {
                    // `StepResult` is non-exhaustive: `More`, and any variant a later rusqlite adds,
                    // is another non-final step, not a reason to give up.
                    steps = steps.saturating_add(1);
                    // A copy of a growing store makes progress every step; a store that never
                    // finishes is a writer that never stops and is left to the retry budget.
                    if steps as u64 * policy.page_batch as u64 > MAX_PAGES {
                        return Err(Failure::contention(
                            "the store kept growing through every step of the copy",
                        ));
                    }
                }
                Err(error) => return Err(Failure::classify(error.to_string())),
            }
        }
        steps
    };
    // The destinations's pages are flushed when the connection closes; the check opens the file
    // again, which is what a restore would do.
    drop(to);
    let verdict = integrity_check(partial).map_err(|error| Failure {
        detail: format!("integrity_check: {error}"),
        transient: true,
    })?;
    if verdict != "ok" {
        return Err(Failure::contention(format!(
            "integrity_check on the copy: {verdict}"
        )));
    }
    Ok(pages)
}

/// A hard ceiling on the copy: 4 GiB at the default page size. A store larger than this needs a
/// different mechanism (a checkpointed file, a store-level export), not an unbounded read.
const MAX_PAGES: u64 = 1_048_576;

/// Open the store for reading, with the busy timeout that makes contention a wait instead of an
/// error. Read-write *without create*: a WAL store needs its `-shm`/`-wal` writable to be read
/// consistently, and a read-only open of a WAL store whose `-shm` is absent fails outright.
fn open_source(source: &Path, policy: &Policy) -> rusqlite::Result<Connection> {
    let write = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let connection = match Connection::open_with_flags(source, write) {
        Ok(connection) => connection,
        // A store on a read-only medium still deserves a snapshot: a WAL reader can work read-only
        // while a writer holds the store, which is exactly the case this crate exists for.
        Err(_) => Connection::open_with_flags(
            source,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?,
    };
    connection.busy_timeout(policy.busy_timeout)?;
    Ok(connection)
}

fn partial_path(copy: &Path) -> PathBuf {
    let mut name = copy.as_os_str().to_os_string();
    name.push(".partial");
    PathBuf::from(name)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn seeded(dir: &Path, rows: usize) -> PathBuf {
        let path = dir.join("store.db");
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "PRAGMA journal_mode=WAL;
                 CREATE TABLE t(seq INTEGER PRIMARY KEY, body TEXT);",
            )
            .unwrap();
        let mut statement = connection
            .prepare("INSERT INTO t(body) VALUES(?1)")
            .unwrap();
        for index in 0..rows {
            statement.execute([format!("row-{index}-{}", "x".repeat(64))]).unwrap();
        }
        drop(statement);
        drop(connection);
        path
    }

    #[test]
    fn a_sound_store_is_copied_and_checked() {
        let dir = tempdir().unwrap();
        let source = seeded(dir.path(), 4);
        let copy = dir.path().join("copy.db");
        let snapshot = snapshot(&source, &copy).unwrap();
        assert_eq!(snapshot.check, "ok");
        assert_eq!(snapshot.attempts, 1);
        let connection = Connection::open(&copy).unwrap();
        let rows: i64 = connection
            .query_row("SELECT count(*) FROM t", [], |row| row.get(0))
            .unwrap();
        assert_eq!(rows, 4);
    }

    #[test]
    fn committed_pages_still_in_the_wal_are_in_the_copy() {
        let dir = tempdir().unwrap();
        let source = dir.path().join("wal.db");
        {
            let connection = Connection::open(&source).unwrap();
            connection
                .execute_batch(
                    "PRAGMA journal_mode=WAL;
                     PRAGMA wal_autocheckpoint=0;
                     CREATE TABLE t(x TEXT);
                     INSERT INTO t VALUES('only-in-the-wal');",
                )
                .unwrap();
            // Hold the connection open: closing it would checkpoint and hide the case.
            let copy = dir.path().join("copy.db");
            let snapshot = snapshot(&source, &copy).unwrap();
            assert_eq!(snapshot.check, "ok");
            let restored = Connection::open(&copy).unwrap();
            let value: String = restored
                .query_row("SELECT x FROM t", [], |row| row.get(0))
                .unwrap();
            assert_eq!(value, "only-in-the-wal");
        }
    }

    #[test]
    fn a_damaged_source_is_refused_with_the_sqlite_verdict() {
        let dir = tempdir().unwrap();
        let source = seeded(dir.path(), 400);
        // The sample the 07/11 reports carried: a damaged page in the middle of the b-tree, header
        // untouched, reported as `database disk image is malformed`.
        let mut bytes = fs::read(&source).unwrap();
        assert!(bytes.len() > 4096 * 3, "the fixture needs several pages");
        for byte in bytes[4096 * 2..4096 * 3].iter_mut() {
            *byte = 0;
        }
        fs::write(&source, &bytes).unwrap();
        let damaged = match quick_check(&source) {
            Ok(verdict) => verdict,
            Err(detail) => detail,
        };
        assert_ne!(damaged, "ok", "the fixture must be damaged");
        assert!(
            damaged.contains("malformed") || damaged.contains("corrupt") || damaged.contains("not a database"),
            "unexpected verdict for the fixture: {damaged}"
        );
        let copy = dir.path().join("copy.db");
        let error = snapshot(&source, &copy).unwrap_err();
        assert!(error.source_is_damaged(), "{error}");
        let message = error.to_string();
        assert!(message.starts_with("backup_failed: "), "{message}");
        assert!(message.contains("store.db"), "{message}");
        assert!(
            message.contains("malformed") || message.contains("not a database"),
            "the refusal must carry SQLite's own verdict: {message}"
        );
        assert!(!copy.exists(), "a refused snapshot publishes nothing");
        assert!(
            !dir.path().join("copy.db.partial").exists(),
            "and leaves no partial copy behind"
        );
    }

    #[test]
    fn an_existing_target_is_never_overwritten() {
        let dir = tempdir().unwrap();
        let source = seeded(dir.path(), 2);
        let copy = dir.path().join("copy.db");
        fs::write(&copy, b"someone else's evidence").unwrap();
        let error = snapshot(&source, &copy).unwrap_err();
        assert!(matches!(error, SnapshotError::Io { .. }), "{error}");
        assert_eq!(fs::read(&copy).unwrap(), b"someone else's evidence");
    }
}
