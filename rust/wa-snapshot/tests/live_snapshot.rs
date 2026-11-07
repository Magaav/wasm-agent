//! The properties the pre-update backup needs, under a store that is actually being written.
//!
//! The unit tests in `src/lib.rs` cover one store at a time. These two cover the reports of 07/11: a
//! store with a live writer must snapshot every time (no false failure), and a store that is really
//! damaged must be refused even when a lock is involved.

use rusqlite::Connection;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tempfile::tempdir;
use wa_snapshot::{snapshot_with, Policy, SnapshotError};

/// A store in WAL mode with `synchronous=FULL`, which is what the node's stores use.
fn wal_store(path: &std::path::Path) {
    let connection = Connection::open(path).unwrap();
    connection
        .execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=FULL;
             CREATE TABLE t(seq INTEGER PRIMARY KEY, body TEXT);",
        )
        .unwrap();
    connection
        .execute("INSERT INTO t(body) VALUES(?1)", ["seed"])
        .unwrap();
}

/// The report on 07/11 was a backup that refused because the store was being written. Fifty snapshots
/// of a store with a writer committing, rewriting and checkpointing must fail zero times, and each
/// copy must be internally consistent (no gaps in the primary key), not merely openable.
#[test]
fn fifty_snapshots_of_a_store_under_a_writer_never_fail() {
    let dir = tempdir().unwrap();
    let source = dir.path().join("graph.db");
    wal_store(&source);

    let stop = Arc::new(AtomicBool::new(false));
    let writer = {
        let source = source.clone();
        let stop = Arc::clone(&stop);
        thread::spawn(move || {
            let connection = Connection::open(&source).unwrap();
            connection.busy_timeout(Duration::from_secs(10)).unwrap();
            let mut writes: i64 = 0;
            while !stop.load(Ordering::SeqCst) {
                writes += 1;
                // A commit, a rewrite inside a transaction and a checkpoint: the three things that
                // were in flight when the copy came back "database disk image is malformed".
                connection
                    .execute(
                        "INSERT INTO t(body) VALUES(?1)",
                        [format!("body-{writes}-{}", "y".repeat(160))],
                    )
                    .unwrap();
                let _ = connection.execute_batch(
                    "BEGIN IMMEDIATE;
                     UPDATE t SET body = body || ' ' WHERE seq = (SELECT max(seq) FROM t);
                     COMMIT;",
                );
                if writes % 5 == 0 {
                    let _ = connection.execute_batch("PRAGMA wal_checkpoint(PASSIVE)");
                }
                thread::sleep(Duration::from_millis(1));
            }
        })
    };

    let policy = Policy {
        backoff: Duration::from_millis(50),
        ..Policy::default()
    };
    let mut previous = 0i64;
    let mut contended = 0;
    for index in 1..=50 {
        let copy = dir.path().join(format!("copy-{index}.db"));
        let snapshot = snapshot_with(&source, &copy, &policy)
            .unwrap_or_else(|error| panic!("snapshot {index} of a live store failed: {error}"));
        assert_eq!(snapshot.check, "ok");
        if snapshot.attempts > 1 {
            contended += 1;
        }
        let connection = Connection::open(&copy).unwrap();
        let (rows, highest): (i64, i64) = connection
            .query_row("SELECT count(*), coalesce(max(seq), 0) FROM t", [], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })
            .unwrap();
        // Append-only table: a copy whose row count is not its highest key lost pages, which is what
        // a torn copy looks like.
        assert_eq!(rows, highest, "copy {index} has a gap: a torn copy");
        assert!(
            rows >= previous,
            "copy {index} saw fewer committed rows ({rows}) than copy {} ({previous})",
            index - 1
        );
        previous = rows;
        assert!(copy.exists());
    }
    stop.store(true, Ordering::SeqCst);
    writer.join().unwrap();
    assert!(
        previous > 1,
        "the writer must have committed rows while the copies were taken"
    );
    eprintln!("50/50 snapshots ok under a live writer; {contended} needed a retry");
}

/// A writer that holds an exclusive lock is contention, not damage: the snapshot is retried and
/// succeeds once the lock is gone, and while the lock is held it is reported as *busy*, never as
/// corruption.
#[test]
fn a_locked_store_is_reported_busy_and_then_retried() {
    let dir = tempdir().unwrap();
    let source = dir.path().join("jobs.db");
    {
        let connection = Connection::open(&source).unwrap();
        connection
            .execute_batch(
                "PRAGMA journal_mode=DELETE;
                 CREATE TABLE t(x TEXT);
                 INSERT INTO t VALUES('queued');",
            )
            .unwrap();
    }

    let locked = Arc::new(AtomicBool::new(false));
    let release = Arc::new(AtomicBool::new(false));
    let holder = {
        let source = source.clone();
        let locked = Arc::clone(&locked);
        let release = Arc::clone(&release);
        thread::spawn(move || {
            let connection = Connection::open(&source).unwrap();
            connection.busy_timeout(Duration::from_secs(10)).unwrap();
            connection.execute_batch("BEGIN EXCLUSIVE").unwrap();
            locked.store(true, Ordering::SeqCst);
            while !release.load(Ordering::SeqCst) {
                thread::sleep(Duration::from_millis(5));
            }
            connection.execute_batch("ROLLBACK").unwrap();
        })
    };
    while !locked.load(Ordering::SeqCst) {
        thread::sleep(Duration::from_millis(5));
    }

    // One attempt: the lock is held, so the answer must be "busy", not "damaged".
    let single = Policy {
        attempts: 1,
        busy_timeout: Duration::from_millis(100),
        backoff: Duration::from_millis(50),
        ..Policy::default()
    };
    let refused = snapshot_with(&source, &dir.path().join("busy.db"), &single).unwrap_err();
    assert!(
        matches!(refused, SnapshotError::Busy { .. }),
        "a held lock must be reported busy, got: {refused}"
    );
    assert!(!refused.source_is_damaged());
    assert!(
        refused.to_string().contains("quick_check"),
        "the refusal must say the source is sound: {refused}"
    );

    // Three attempts, with the lock released after the first one has certainly failed: the backup
    // must succeed rather than refuse an update over a store that is merely being written.
    let policy = Policy {
        attempts: 6,
        busy_timeout: Duration::from_millis(100),
        backoff: Duration::from_millis(150),
        ..Policy::default()
    };
    let copy = dir.path().join("retried.db");
    let snapshotter = {
        let source = source.clone();
        let copy = copy.clone();
        thread::spawn(move || snapshot_with(&source, &copy, &policy))
    };
    thread::sleep(Duration::from_millis(600));
    release.store(true, Ordering::SeqCst);
    let snapshot = snapshotter
        .join()
        .unwrap()
        .expect("a store that stopped being locked must still be snapshotted");
    holder.join().unwrap();
    assert_eq!(snapshot.check, "ok");
    assert!(
        snapshot.attempts >= 2,
        "the lock was held through at least one attempt (attempts: {})",
        snapshot.attempts
    );
    let restored = Connection::open(&copy).unwrap();
    let value: String = restored
        .query_row("SELECT x FROM t", [], |row| row.get(0))
        .unwrap();
    assert_eq!(value, "queued");
}

/// The same fifty snapshots against a store in rollback-journal mode, where a reader and a writer
/// really do lock each other out, under the shipped policy: SQLite's own busy timeout absorbs the
/// wait inside a step, and every copy must still be a complete, internally consistent store. This is
/// the mode in which a torn read would show up as a copy that opens and is wrong.
#[test]
fn fifty_snapshots_of_a_rollback_journal_store_never_fail() {
    let dir = tempdir().unwrap();
    let source = dir.path().join("memory.db");
    {
        let connection = Connection::open(&source).unwrap();
        connection
            .execute_batch(
                "PRAGMA journal_mode=DELETE;
                 CREATE TABLE t(seq INTEGER PRIMARY KEY, body TEXT);
                 INSERT INTO t(body) VALUES('seed');",
            )
            .unwrap();
    }

    let stop = Arc::new(AtomicBool::new(false));
    let writer = {
        let source = source.clone();
        let stop = Arc::clone(&stop);
        thread::spawn(move || {
            let connection = Connection::open(&source).unwrap();
            connection.busy_timeout(Duration::from_secs(10)).unwrap();
            let mut writes: i64 = 0;
            while !stop.load(Ordering::SeqCst) {
                writes += 1;
                // An exclusive transaction held for a moment: the window in which a reader of a
                // rollback-journal store is refused the file, and in which a byte copy would tear.
                let _ = connection.execute_batch(&format!(
                    "BEGIN EXCLUSIVE;
                     INSERT INTO t(body) VALUES('{}');
                     UPDATE t SET body = body || '.' WHERE seq = (SELECT max(seq) FROM t);
                     COMMIT;",
                    format!("body-{writes}-{}", "z".repeat(160)),
                ));
                thread::sleep(Duration::from_millis(1));
            }
        })
    };

    let policy = Policy::default();
    let mut previous = 0i64;
    let mut contended = 0;
    for index in 1..=50 {
        let copy = dir.path().join(format!("copy-{index}.db"));
        let snapshot = snapshot_with(&source, &copy, &policy)
            .unwrap_or_else(|error| panic!("snapshot {index} of a live store failed: {error}"));
        assert_eq!(snapshot.check, "ok");
        if snapshot.attempts > 1 {
            contended += 1;
        }
        let connection = Connection::open(&copy).unwrap();
        let verdict: String = connection
            .query_row("PRAGMA integrity_check", [], |row| row.get(0))
            .unwrap();
        assert_eq!(verdict, "ok", "copy {index}");
        let (rows, highest): (i64, i64) = connection
            .query_row("SELECT count(*), coalesce(max(seq), 0) FROM t", [], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })
            .unwrap();
        assert_eq!(rows, highest, "copy {index} has a gap: a torn copy");
        assert!(rows >= previous);
        previous = rows;
    }
    stop.store(true, Ordering::SeqCst);
    writer.join().unwrap();
    assert!(previous > 1, "the writer must have committed rows");
    eprintln!("50/50 snapshots ok under a rollback-journal writer; {contended} needed a retry");
}
