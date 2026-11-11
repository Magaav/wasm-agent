//! Contention policy for every SQLite store the node opens.
//!
//! Measured 2026-11-12 on `work`: an interactive run ended at 18:14:58 on
//! `lua/core/memory.lua:1056: database is locked` while `wa serve` was handling relayed calls, and a
//! relay proof against `wasm_the_first` failed 2 of 10 parallel `status` calls while one long call
//! ran (0 of 10 with no long call). Both were the same defect, in different clothes: every store set
//! its own busy timeout - 5 s here, 2 s in `wa-jobs`, 10 s in `wa-graph`, none at all in the
//! subagent journal - and nothing retried. A lock held longer than the one number chosen at that
//! site became an error a *run* died of.
//!
//! The rules this module exists to make true, everywhere:
//!
//! * **One number.** `busy_timeout` is [`busy_ms`], WAL and `synchronous=FULL` are set the same way
//!   for every file-backed store (`a store that is not the node's ledger is still the node's data`).
//! * **A statement is retried, not a unit.** A statement that returns `SQLITE_BUSY` applied nothing,
//!   so re-running *that statement* is safe. Re-running a whole transaction closure is not, and this
//!   module never does it: the one exception SQLite itself creates is `SQLITE_BUSY_SNAPSHOT`, where a
//!   write conflict rolls the transaction back - that is detected (`is_autocommit` before/after) and
//!   reported as a failure to retry *the unit*, never as a silently autocommitted retry.
//! * **A lock that cannot be had ends in a name.** [`failure`] produces
//!   `database_busy: <action> ...(retryable)`, which a caller can match and a human can act on. It is
//!   never a bare `database is locked` several frames down from the thing that failed.
//! * **Total patience is bounded and configurable**, not a wait that doubles a call's cost silently:
//!   `WASM_AGENT_SQLITE_BUSY_MS` (one wait, default 5 s) and `WASM_AGENT_SQLITE_RETRY_MS` (all
//!   attempts together, default 20 s).

use rusqlite::{Connection, OpenFlags};
use std::path::Path;
use std::time::{Duration, Instant};

/// How long one statement waits inside SQLite before it reports busy.
///
/// 5 s is what the node has run with: long enough that ordinary bursts (a telemetry record, a
/// placement tick, a second lane booting) never surface, short enough that a caller waiting on a
/// wedged writer still answers. The patience that matters is [`retry_ms`], which is spent in
/// *attempts*: that is what survives a queue of writers, where one long wait does not.
pub const BUSY_MS_DEFAULT: u64 = 5_000;

/// Total time all attempts of one statement/transaction may spend before the named error.
pub const RETRY_MS_DEFAULT: u64 = 20_000;

/// Attempts per unit of work. Each attempt already includes SQLite's own wait, so this is a cap on
/// the *number of collisions*, not the patience itself.
pub const ATTEMPTS_DEFAULT: u32 = 5;

/// The name a caller matches on. Stable: it is an API, not a message.
pub const BUSY_NAME: &str = "database_busy";

const BACKOFF_START_MS: u64 = 20;
const BACKOFF_MAX_MS: u64 = 400;

fn env_ms(name: &str, default: u64, high: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|raw| raw.trim().parse::<u64>().ok())
        .map(|value| value.min(high))
        .unwrap_or(default)
}

/// `PRAGMA busy_timeout` for every connection this node opens.
pub fn busy_ms() -> u64 {
    env_ms("WASM_AGENT_SQLITE_BUSY_MS", BUSY_MS_DEFAULT, 120_000)
}

/// The budget one unit of work may spend on contention, in total.
pub fn retry_ms() -> u64 {
    env_ms("WASM_AGENT_SQLITE_RETRY_MS", RETRY_MS_DEFAULT, 600_000)
}

/// How many attempts one unit of work may make.
pub fn attempts_max() -> u32 {
    std::env::var("WASM_AGENT_SQLITE_RETRY_ATTEMPTS")
        .ok()
        .and_then(|raw| raw.trim().parse::<u32>().ok())
        .map(|value| value.clamp(1, 50))
        .unwrap_or(ATTEMPTS_DEFAULT)
}

/// The pragma batch every store applies, so the same numbers show up in `sqlite3 file.db 'PRAGMA
/// busy_timeout'` on any node and the question "is this store configured?" has one answer.
///
/// `FULL`, not `NORMAL`: in WAL mode `NORMAL` can lose the last commits on power loss, and the
/// node's durable records (claims, operations, receipts) must survive a reboot.
pub fn pragmas(busy_ms: u64) -> String {
    // `busy_timeout` is set first so a lock met by the later pragmas is waited for, not refused.
    format!(
        "PRAGMA busy_timeout={busy_ms}; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; \
         PRAGMA foreign_keys=ON;"
    )
}

/// The wait, without the durability decisions a store makes for itself.
///
/// A component's private key-value store picks `synchronous=NORMAL` on purpose (it is its own state,
/// not the node's ledger), but it still must not fail because another process booted at the same
/// moment: the wait is the part that is shared, and the journal mode is the part that is not.
pub fn tune_wait(conn: &Connection) -> rusqlite::Result<()> {
    conn.busy_timeout(Duration::from_millis(busy_ms()))
}

/// The read-only half of the policy.
///
/// A reader cannot change the journal mode, and asking it to on a store that is not yet WAL fails the
/// whole read, so a read-only connection gets the shared busy timeout and nothing else. It still
/// waits instead of failing: the wait is what a reader actually needs.
pub fn tune_read_only(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(&format!(
        "PRAGMA busy_timeout={}; PRAGMA foreign_keys=ON;",
        busy_ms()
    ))
}

/// Apply the policy to a connection that was opened by someone else (`wa-graph` needs its own VFS
/// on Windows; the component pool opens its own URI).
///
/// A lock met here is retried: switching the journal mode is a write, and two processes booting at
/// the same moment is the ordinary case on a busy node.
pub fn tune(conn: &Connection) -> rusqlite::Result<()> {
    tune_with(conn, busy_ms())
}

pub fn tune_with(conn: &Connection, busy_ms: u64) -> rusqlite::Result<()> {
    let batch = pragmas(busy_ms);
    let mut attempt = 0u32;
    let deadline = Instant::now() + Duration::from_millis(retry_ms());
    loop {
        attempt += 1;
        match conn.execute_batch(&batch) {
            Ok(()) => return Ok(()),
            Err(error) => {
                if !is_busy(&error) || attempt >= attempts_max() || Instant::now() >= deadline {
                    return Err(error);
                }
                pause(attempt);
            }
        }
    }
}

/// Open a store with the policy applied. `busy_timeout` is set *before* the journal mode so the
/// mode change itself is waited for rather than refused.
pub fn open(path: impl AsRef<Path>) -> rusqlite::Result<Connection> {
    let conn = Connection::open(path)?;
    tune(&conn)?;
    Ok(conn)
}

pub fn open_with_flags(path: impl AsRef<Path>, flags: OpenFlags) -> rusqlite::Result<Connection> {
    let conn = Connection::open_with_flags(path, flags)?;
    tune(&conn)?;
    Ok(conn)
}

/// True when SQLite refused because someone else holds the lock - the one error worth retrying.
///
/// Both the primary code and the extended code are checked: rusqlite reports `SQLITE_BUSY_SNAPSHOT`
/// (extended 517) as `DatabaseBusy`, and a build that maps it differently must not turn a transient
/// collision into a failed run.
pub fn is_busy(error: &rusqlite::Error) -> bool {
    match error {
        rusqlite::Error::SqliteFailure(code, _) => {
            matches!(
                code.code,
                rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked
            ) || matches!(code.extended_code & 0xff, 5 | 6)
        }
        _ => false,
    }
}

/// The same question about a message, for the Lua side and for errors that crossed a boundary as
/// text (a `{error=...}` from the host, a stderr line from a peer process).
pub fn is_busy_text(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("database is locked")
        || lower.contains("database table is locked")
        || lower.contains("sqlite_busy")
        || lower.contains("sqlite_locked")
        || lower.contains(BUSY_NAME)
}

/// `database_busy: ... (retryable)` - the one string every layer names this failure with.
pub fn failure(action: &str, last: &str, attempts: u32, spent: Duration) -> String {
    format!(
        "{BUSY_NAME}: {action} could not get the lock within {}ms ({attempts} attempt(s), last: {last}) (retryable)",
        spent.as_millis()
    )
}

/// The retry loop itself. `f` is called once per attempt and must be safe to call again after a
/// busy refusal - which every single SQLite statement is (`BEGIN IMMEDIATE` included: a BEGIN that
/// failed began nothing).
pub fn retry<T>(
    action: &str,
    mut f: impl FnMut() -> rusqlite::Result<T>,
) -> Result<T, String> {
    let limit = attempts_max();
    let deadline = Instant::now() + Duration::from_millis(retry_ms());
    let started = Instant::now();
    let mut attempt = 0u32;
    loop {
        attempt += 1;
        match f() {
            Ok(value) => return Ok(value),
            Err(error) => {
                if !is_busy(&error) {
                    return Err(error.to_string());
                }
                if attempt >= limit || Instant::now() >= deadline {
                    return Err(failure(action, &error.to_string(), attempt, started.elapsed()));
                }
                pause(attempt);
            }
        }
    }
}

/// Take the write lock now, waiting with the shared policy. A `BEGIN IMMEDIATE` that failed took no
/// lock, so retrying it cannot half-apply anything.
pub fn begin_immediate(conn: &Connection) -> Result<(), String> {
    retry("BEGIN IMMEDIATE", || conn.execute_batch("BEGIN IMMEDIATE"))
}

/// Commit, retrying only the commit itself.
///
/// A `COMMIT` that returns busy has not committed and the transaction is still open, so repeating
/// `COMMIT` is what SQLite's own documentation asks for. `no transaction is active` after a busy
/// commit means an earlier attempt landed: that is success, not a failure.
pub fn commit(conn: &Connection) -> Result<(), String> {
    match retry("COMMIT", || conn.execute_batch("COMMIT")) {
        Ok(()) => Ok(()),
        Err(error) if error.contains("no transaction is active") && conn.is_autocommit() => Ok(()),
        Err(error) => Err(error),
    }
}

fn backoff_ms(attempt: u32) -> u64 {
    // Exponential, capped, with jitter: without the jitter a queue of waiters wakes in lockstep and
    // re-collides, which is exactly how ten parallel calls turn one slow commit into ten failures.
    let step = BACKOFF_START_MS.saturating_mul(1u64 << (attempt.min(6) - 1));
    let base = step.min(BACKOFF_MAX_MS);
    base / 2 + jitter_ms(base / 2 + 1)
}

/// Sleep before the next attempt. Public so a caller that must inspect the connection between
/// attempts (the host checks whether SQLite rolled the transaction back) still backs off the same way.
pub fn backoff(attempt: u32) {
    pause(attempt);
}

/// When set, one statement slower than this is reported on stderr with what it was doing.
///
/// Off by default: this is a diagnostic for answering "who holds the store for so long", and a line
/// per slow statement on a busy node is exactly the noise a terminal run cannot afford. The live
/// proof uses it (`WASM_AGENT_SQLITE_SLOW_MS=250` in the node's env file) to name a long holder.
pub fn slow_ms() -> u64 {
    env_ms("WASM_AGENT_SQLITE_SLOW_MS", 0, 600_000)
}

#[cfg(not(target_os = "wasi"))]
fn pause(attempt: u32) {
    std::thread::sleep(Duration::from_millis(backoff_ms(attempt)));
}

/// Inside the graph guest there is no concurrency to back off from: the kernel serializes calls per
/// database and retries the call itself, so a wait here would only spend the caller's budget twice.
#[cfg(target_os = "wasi")]
fn pause(_attempt: u32) {}

fn jitter_ms(spread: u64) -> u64 {
    // Nanos are good enough for spread and cost no dependency; the value only has to differ between
    // two waiters starting in the same millisecond.
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos() as u64)
        .unwrap_or(0);
    nanos % spread.max(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("wa-sqlite-{name}-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        dir.join("store.db")
    }

    #[test]
    fn a_fresh_store_is_wal_with_one_busy_timeout() {
        let path = scratch("wal");
        let conn = open(&path).unwrap();
        let mode: String = conn
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .unwrap();
        assert_eq!(mode.to_lowercase(), "wal", "every store is WAL");
        let busy: i64 = conn
            .query_row("PRAGMA busy_timeout", [], |row| row.get(0))
            .unwrap();
        assert_eq!(busy as u64, busy_ms(), "one busy timeout, from one place");
        let sync: i64 = conn
            .query_row("PRAGMA synchronous", [], |row| row.get(0))
            .unwrap();
        assert_eq!(sync, 2, "FULL: a committed row survives a power loss");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn busy_is_recognised_and_other_errors_are_not_retried() {
        let path = scratch("busy-detect");
        let first = open(&path).unwrap();
        let second = open(&path).unwrap();
        first.execute_batch("BEGIN IMMEDIATE").unwrap();
        second.busy_timeout(Duration::from_millis(0)).unwrap();
        let error = second
            .execute_batch("BEGIN IMMEDIATE")
            .expect_err("a held write lock must refuse");
        assert!(is_busy(&error), "a held write lock reads as busy: {error}");
        let other = second
            .execute_batch("INSERT INTO no_such_table(k) VALUES(1)")
            .expect_err("a missing table is an error");
        assert!(!is_busy(&other), "a missing table is never retried");
        assert!(!is_busy_text("no such table"));
        assert!(is_busy_text("database is locked"));
        assert!(is_busy_text("database_busy: BEGIN IMMEDIATE ..."));
        first.execute_batch("ROLLBACK").unwrap();
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_statement_is_retried_past_a_short_hold_and_the_total_is_bounded() {
        let path = scratch("retry");
        let holder = open(&path).unwrap();
        holder
            .execute_batch("CREATE TABLE IF NOT EXISTS t(k TEXT)")
            .unwrap();
        holder.execute_batch("BEGIN IMMEDIATE").unwrap();
        holder.execute("INSERT INTO t(k) VALUES('held')", []).unwrap();
        let waiter = open(&path).unwrap();
        waiter.busy_timeout(Duration::from_millis(20)).unwrap();
        // The holder releases after 400 ms; the waiter must still land its own write.
        let release = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(400));
            holder.execute_batch("COMMIT").unwrap();
        });
        let wrote = retry("INSERT", || {
            waiter.execute("INSERT INTO t(k) VALUES('waited')", []).map(|_| ())
        });
        release.join().unwrap();
        assert!(wrote.is_ok(), "a 400 ms hold is ridden out: {wrote:?}");
        let rows: i64 = waiter
            .query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0))
            .unwrap();
        assert_eq!(rows, 2, "the retried statement applied exactly once");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_lock_held_past_the_budget_names_itself_and_is_retryable() {
        let path = scratch("timeout");
        let holder = open(&path).unwrap();
        holder
            .execute_batch("CREATE TABLE IF NOT EXISTS t(k TEXT)")
            .unwrap();
        holder.execute_batch("BEGIN IMMEDIATE").unwrap();
        let waiter = open(&path).unwrap();
        waiter.busy_timeout(Duration::from_millis(10)).unwrap();
        let started = Instant::now();
        let error = retry("INSERT", || {
            waiter.execute("INSERT INTO t(k) VALUES('never')", []).map(|_| ())
        })
        .expect_err("a lock held past the budget must fail");
        assert!(error.starts_with("database_busy: "), "named: {error}");
        assert!(error.contains("(retryable)"), "marked retryable: {error}");
        assert!(error.contains("INSERT"), "it says what it was doing: {error}");
        assert!(
            started.elapsed() < Duration::from_secs(120),
            "the wait is bounded"
        );
        holder.execute_batch("ROLLBACK").unwrap();
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn commit_after_a_committed_transaction_is_not_an_error() {
        let path = scratch("commit");
        let conn = open(&path).unwrap();
        conn.execute_batch("CREATE TABLE IF NOT EXISTS t(k TEXT)").unwrap();
        begin_immediate(&conn).unwrap();
        conn.execute("INSERT INTO t(k) VALUES('a')", []).unwrap();
        commit(&conn).unwrap();
        // The second commit is the shape a retried COMMIT takes when the first one landed.
        commit(&conn).unwrap();
        let rows: i64 = conn.query_row("SELECT COUNT(*) FROM t", [], |r| r.get(0)).unwrap();
        assert_eq!(rows, 1);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn the_pragma_batch_sets_the_timeout_first() {
        let batch = pragmas(1234);
        let first = batch.split(';').next().unwrap().trim();
        assert_eq!(first, "PRAGMA busy_timeout=1234");
        assert!(batch.contains("journal_mode=WAL"));
        assert!(batch.contains("synchronous=FULL"));
    }
}
