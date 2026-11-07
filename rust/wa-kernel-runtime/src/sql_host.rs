//! `wa:kernel/sql` — the kernel's database, granted one table at a time.
//!
//! The memory seam keeps `memory.db` in the kernel (docs/KERNEL.md, "Memory as a component") and
//! gives the component statements instead of a file handle. This module is the whole of that grant:
//! a scope (which tables may be read, which may be written), one SQLite connection per seam call, a
//! **SQLite authorizer** that decides every action the engine asks permission for, and the **unit of
//! work** the kernel closes.
//!
//! A mutation is one transaction: the component writes its rows inside `begin_unit`, and
//! `commit_unit` appends the replication journal row (whose `origin` is the node's identity, which a
//! component never names) and commits. The journal row and the mutation therefore land together or
//! not at all — the gap a second transaction would leave between them is gone.
//!
//! Why an authorizer and not a statement parser: a guard that reads the text of a statement is a
//! guard that can be talked past — a subquery, a view, a CTE or a `;`-separated second statement all
//! reach tables the text did not obviously name. The authorizer is called by SQLite itself for every
//! table, column, function and pragma a prepared statement touches, so the answer is the engine's
//! answer, not a guess about the text. What the text guard here still does is refuse things early
//! and legibly: NUL bytes, an oversized statement, and `PRAGMA`/`ATTACH` — the authorizer would
//! refuse those too, and does, because a second line of defence that is never exercised is not a
//! defence.
//!
//! Nothing here inspects values. A refusal names the action and the table, never a row, so the audit
//! trail can be read by an operator without leaking a transcript.

use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags};
use serde_json::Value as Json;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// The largest statement a component may send. The memory logic is a page of SQL with bound
/// parameters; anything near this is not a statement a caller meant to send.
const MAX_STATEMENT: usize = 16 << 10;
/// The most rows one statement may answer with. A caller that wants more is asking the kernel to
/// hold a whole table in memory, which is the thing a scoped grant exists to prevent.
pub const MAX_ROWS: usize = 10_000;
/// How long one seam call may spend inside SQLite before its progress handler interrupts it. The
/// guest's own epoch deadline is the outer bound (the caller sets this *above* it, see
/// `memory_host::STATEMENT_MARGIN_MS`, so the guest is stopped first and this is the backstop for a
/// connection whose guest is already gone); this one keeps a wedged query from holding the
/// connection (and the write lock) after the guest was stopped.
pub const STATEMENT_DEADLINE: Duration = Duration::from_secs(10);
/// The largest journal payload one unit of work may carry. A memory's journal entry is a few
/// hundred bytes of JSON; a payload near this is not an entry a caller meant to write.
pub const MAX_JOURNAL_PAYLOAD: usize = 64 << 10;
/// The longest entity id a journal entry may name.
const MAX_JOURNAL_ENTITY: usize = 256;
/// The audit file is rotated at this size, keeping one previous generation: a refusal storm must not
/// fill a disk, and the newest lines are the ones an operator needs.
const AUDIT_MAX_BYTES: u64 = 256 << 10;

/// One column value or bound parameter, with its SQLite type kept.
#[derive(Clone, Debug, PartialEq)]
pub enum Scalar {
    Null,
    Integer(i64),
    Real(f64),
    Text(String),
    Blob(Vec<u8>),
}

impl From<Scalar> for rusqlite::types::Value {
    fn from(value: Scalar) -> Self {
        match value {
            Scalar::Null => rusqlite::types::Value::Null,
            Scalar::Integer(n) => rusqlite::types::Value::Integer(n),
            Scalar::Real(f) => rusqlite::types::Value::Real(f),
            Scalar::Text(text) => rusqlite::types::Value::Text(text),
            Scalar::Blob(bytes) => rusqlite::types::Value::Blob(bytes),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Answer {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<Scalar>>,
    pub changes: u64,
}

/// Why a statement did not run, in the two shapes a caller has to tell apart: the grant does not
/// cover it, or the store broke.
#[derive(Clone, Debug, PartialEq)]
pub enum SqlFailure {
    Refused(String),
    Failed(String),
}

impl std::fmt::Display for SqlFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SqlFailure::Refused(why) => write!(f, "refused: {why}"),
            SqlFailure::Failed(why) => write!(f, "failed: {why}"),
        }
    }
}

impl std::error::Error for SqlFailure {}

/// Counters for the two surfaces that ask "did anything try to leave its grant": the audit file lines
/// and the telemetry numbers.
#[derive(Debug, Default)]
pub struct SqlAudit {
    pub statements: AtomicU64,
    pub denials: AtomicU64,
    /// Journal rows the kernel wrote inside a component's unit of work. The kernel's own statement,
    /// counted apart from the guest's so an operator can tell who wrote what.
    pub journal_entries: AtomicU64,
}

/// What a unit of work owes the replication log, and who owes it.
///
/// The `kind` is the log's own word for the entity family (`memory` today) and the `origin` is the
/// node's identity; both come from the kernel that opened the scope, never from the guest, which is
/// why `journal` never has to be in a component's write grant.
#[derive(Clone, Debug, PartialEq)]
pub struct JournalTarget {
    pub kind: String,
    pub origin: String,
}

/// One entry a unit of work asks the kernel to append: the entity, the log's verb and the JSON a peer
/// applies. Validated by [`SqlScope::commit_unit`] before it reaches a row.
#[derive(Clone, Debug, PartialEq)]
pub struct JournalEntry {
    pub entity_id: String,
    pub op: String,
    pub payload: String,
}

/// Where a component's SQL may reach. One of these per installed component, built from its manifest.
#[derive(Debug)]
pub struct SqlScope {
    name: String,
    db: PathBuf,
    read: Vec<String>,
    write: Vec<String>,
    max_rows: usize,
    statement_deadline: Duration,
    journal: Option<JournalTarget>,
    audit_path: Option<PathBuf>,
    audit: Arc<SqlAudit>,
}

impl SqlScope {
    /// A scope that can reach nothing: every statement is refused until a grant names a table.
    pub fn new(name: &str, db: impl Into<PathBuf>) -> SqlScope {
        SqlScope {
            name: name.to_string(),
            db: db.into(),
            read: Vec::new(),
            write: Vec::new(),
            max_rows: MAX_ROWS,
            statement_deadline: STATEMENT_DEADLINE,
            journal: None,
            audit_path: None,
            audit: Arc::new(SqlAudit::default()),
        }
    }

    /// The `capabilities.sql` object of a component's manifest, as the grant the host will enforce.
    ///
    /// A manifest that declares `sql` but no table is not an error: it buys a component nothing, and
    /// a scope that names no table refuses everything, which is the safe reading of an empty grant.
    pub fn from_manifest(
        name: &str,
        db: impl Into<PathBuf>,
        manifest: &Json,
    ) -> Result<SqlScope, String> {
        let Some(grant) = manifest.get("capabilities").and_then(|c| c.get("sql")) else {
            return Ok(SqlScope::new(name, db));
        };
        let object = grant.as_object().ok_or_else(|| "invalid_component_grant:sql".to_string())?;
        if let Some(database) = object.get("database") {
            let database = database.as_str().ok_or_else(|| "invalid_component_grant:sql".to_string())?;
            // The kernel owns exactly one database for this grant. A future second store is
            // another name here, never a path a manifest can point anywhere it likes.
            if database != "memory" {
                return Err(format!("component_sql_database_unknown:{database}"));
            }
        }
        let tables = |field: &str| -> Result<Vec<String>, String> {
            let Some(list) = object.get(field) else { return Ok(Vec::new()) };
            let list = list.as_array().ok_or_else(|| format!("invalid_component_grant:sql:{field}"))?;
            let mut out = Vec::new();
            for item in list {
                let table = item.as_str().ok_or_else(|| format!("invalid_component_grant:sql:{field}"))?;
                // A grant names a table, never a path, a schema qualifier or a wildcard.
                let ok = !table.is_empty()
                    && table.len() <= 64
                    && table.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
                if !ok {
                    return Err(format!("invalid_component_grant:sql:{field}"));
                }
                out.push(table.to_string());
            }
            Ok(out)
        };
        let mut scope = SqlScope::new(name, db);
        scope.read = tables("read")?;
        scope.write = tables("write")?;
        Ok(scope)
    }

    pub fn with_max_rows(mut self, max_rows: usize) -> SqlScope {
        self.max_rows = max_rows.max(1);
        self
    }

    /// The transaction guard's deadline. A caller sets it just above its own call deadline, so the
    /// guest is stopped first and a statement can never outlive the call that started it.
    pub fn with_statement_deadline(mut self, deadline: Duration) -> SqlScope {
        self.statement_deadline = deadline;
        self
    }

    /// What a unit of work closed here appends to the replication log, and whose identity it carries.
    /// Without this, `commit_unit` still commits — but an entry is refused rather than dropped: a
    /// mutation that cannot be journalled is reported, never stored silently.
    pub fn with_journal(mut self, kind: impl Into<String>, origin: impl Into<String>) -> SqlScope {
        self.journal = Some(JournalTarget { kind: kind.into(), origin: origin.into() });
        self
    }

    /// Where refusals are appended. `None` (the default) keeps the counters and says nothing to
    /// disk; a production scope always has one.
    pub fn with_audit_file(mut self, path: impl Into<PathBuf>) -> SqlScope {
        self.audit_path = Some(path.into());
        self
    }

    pub fn audit(&self) -> Arc<SqlAudit> {
        self.audit.clone()
    }

    pub fn tables(&self) -> (&[String], &[String]) {
        (&self.read, &self.write)
    }

    /// One connection for one seam call: the component's unit of work (`begin-unit` … `commit-unit`)
    /// has to span several statements, so all of them run here, and the connection (and any
    /// transaction left open on it) is closed when the call ends.
    pub fn session(&self) -> Result<SqlSession, SqlFailure> {
        let connection = Connection::open_with_flags(
            &self.db,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE | OpenFlags::SQLITE_OPEN_URI,
        )
        .map_err(|error| SqlFailure::Failed(format!("open: {error}")))?;
        // The host sets its own pragmas, before the authorizer exists: the guest may not.
        connection
            .execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;")
            .map_err(|error| SqlFailure::Failed(format!("pragmas: {error}")))?;
        let guard = Guard {
            name: self.name.clone(),
            read: self.read.clone(),
            write: self.write.clone(),
            audit: self.audit.clone(),
            audit_path: self.audit_path.clone(),
        };
        let deadline = Instant::now() + self.statement_deadline;
        // The authorizer decides every action the engine asks about; the progress handler stops a
        // statement that has run too long even when every action in it was allowed.
        {
            let guard = guard.clone();
            connection.authorizer(Some(move |context: AuthContext<'_>| guard.verdict(context)));
        }
        connection.progress_handler(1_000, Some(move || Instant::now() > deadline));
        Ok(SqlSession { connection, guard, max_rows: self.max_rows, journal: self.journal.clone() })    }
}

/// `no PRAGMA writes`: a pragma is allowed only when its name is on one of these two lists.
///
/// - `PLAIN_PRAGMAS` never take an argument, and these are the read-only ones a caller may want
///   (`data_version` is what FTS5's own vtable constructor reads while it prepares).
/// - `INTROSPECTION_PRAGMAS` take an *object name* as their argument (`PRAGMA table_info(memories)`),
///   which is why they cannot be told apart from a write by the value alone; they only read schema.
///
/// Everything else is refused with or without a value: `PRAGMA optimize`, `incremental_vacuum` and
/// `wal_checkpoint` write without taking one, and `journal_mode`/`user_version` take one.
fn pragma_allowed(name: &str, has_value: bool) -> bool {
    const PLAIN_PRAGMAS: &[&str] = &[
        "data_version", "schema_version", "database_list", "page_count",
        "freelist_count", "page_size", "encoding", "compile_options", "quick_check",
        "integrity_check", "collation_list", "pragma_list",
    ];
    const INTROSPECTION_PRAGMAS: &[&str] = &[
        "table_info", "table_xinfo", "index_list", "index_info", "index_xinfo", "foreign_key_list",
    ];
    let name = name.to_ascii_lowercase();
    if has_value {
        INTROSPECTION_PRAGMAS.contains(&name.as_str())
    } else {
        PLAIN_PRAGMAS.contains(&name.as_str())
    }
}

/// The functions a statement may not call: everything SQLite and FTS5 provide is fine, but these
/// reach outside the database (a file, a shared library, a tokenizer's internals), and a loader is
/// not a memory operation. Compared lower-cased, because SQLite's own name is case-insensitive.
const BANNED_FUNCTIONS: &[&str] = &[
    "load_extension",
    "readfile",
    "writefile",
    "edit",
    "fts3_tokenizer",
    "zipfile",
    "eval",
    "readblob",
    "writeblob",
];

/// `base` and the `base_*` shadow tables SQLite addresses by name for it.
fn covers(grant: &[String], table: &str) -> bool {
    grant.iter().any(|base| {
        base == table
            || (table.len() > base.len() && table.starts_with(base.as_str()) && table.as_bytes()[base.len()] == b'_')
    })
}

#[derive(Clone)]
struct Guard {
    name: String,
    read: Vec<String>,
    write: Vec<String>,
    audit: Arc<SqlAudit>,
    audit_path: Option<PathBuf>,
}

impl Guard {
    /// Whether a read of `table` is inside the grant. A table's *shadow* tables belong to it: FTS5
    /// reads and writes `memories_fts_data`, `_idx`, `_content`, `_docsize` and `_config` for the one
    /// table the grant names, and SQLite asks the authorizer about them by name.
    fn readable(&self, table: &str) -> bool {
        covers(&self.read, table)
    }

    fn writable(&self, table: &str) -> bool {
        covers(&self.write, table)
    }

    /// SQLite asks this for every table, column, function and pragma a statement touches, so the allow
    /// path is on the hot path of every statement and must not allocate or format anything: before
    /// this split, an allowed read built its audit text (`format!("table={table_name}")`) for nothing.
    ///
    /// The split is a cleanup, not a measured win: the seam's p99 is SQLite's (a common-word search
    /// spends ~220 ms of its ~230 ms inside the engine — measured on the bench store), so no timing
    /// change is claimed for it. Only a refusal pays for words.
    fn verdict(&self, context: AuthContext<'_>) -> Authorization {
        if self.permitted(&context.action) {
            return Authorization::Allow;
        }
        self.audit.denials.fetch_add(1, Ordering::Relaxed);
        let (action, target) = self.describe(&context.action);
        if std::env::var("WA_SQL_DEBUG").is_ok() {
            eprintln!("DENY {action} {target} {context:?}");
        }
        self.record(&format!("{action} {target}"));
        Authorization::Deny
    }

    /// The whole policy, in one place, as a yes or a no. `permitted` and `describe` must answer about
    /// the same action: every arm of `permitted` is the allowed half of the corresponding arm of
    /// `describe`, and the tests drive both sides (an allowed statement never reaches `describe`).
    fn permitted(&self, action: &AuthAction<'_>) -> bool {
        match action {
            // Reads, and a statement that only selects.
            AuthAction::Select | AuthAction::Recursive => true,
            AuthAction::Read { table_name, .. } => self.readable(table_name),
            // Writes the grant names.
            AuthAction::Insert { table_name } => self.writable(table_name),
            AuthAction::Update { table_name, .. } => self.writable(table_name),
            AuthAction::Delete { table_name } => self.writable(table_name),
            // Transactions are how one memory write stays one unit. Savepoints are the same shape
            // one level down and are what rusqlite's own nested statements use.
            AuthAction::Transaction { .. } | AuthAction::Savepoint { .. } => true,
            // Functions: everything SQLite and FTS5 provide is fine; the ones that reach outside the
            // database are not, and a loader is not a memory operation.
            AuthAction::Function { function_name } => !BANNED_FUNCTIONS
                .contains(&function_name.to_ascii_lowercase().as_str()),
            // A read-only pragma is allowed; every write one, and every action below, is not.
            AuthAction::Pragma { pragma_name, pragma_value } => pragma_allowed(pragma_name, pragma_value.is_some()),
            other => Self::always_refused(other),
        }
    }

    /// The actions that are outside the grant by construction, whichever component asks.
    fn always_refused(action: &AuthAction<'_>) -> bool {
        matches!(
            action,
            AuthAction::Attach { .. }
                | AuthAction::Detach { .. }
                | AuthAction::CreateTable { .. }
                | AuthAction::CreateTempTable { .. }
                | AuthAction::CreateIndex { .. }
                | AuthAction::CreateTempIndex { .. }
                | AuthAction::CreateTrigger { .. }
                | AuthAction::CreateTempTrigger { .. }
                | AuthAction::CreateView { .. }
                | AuthAction::CreateTempView { .. }
                | AuthAction::CreateVtable { .. }
                | AuthAction::DropTable { .. }
                | AuthAction::DropTempTable { .. }
                | AuthAction::DropIndex { .. }
                | AuthAction::DropTempIndex { .. }
                | AuthAction::DropTrigger { .. }
                | AuthAction::DropTempTrigger { .. }
                | AuthAction::DropView { .. }
                | AuthAction::DropTempView { .. }
                | AuthAction::DropVtable { .. }
                | AuthAction::AlterTable { .. }
                | AuthAction::Reindex { .. }
                | AuthAction::Analyze { .. }
        )
    }

    /// What a refusal is called in the audit line: the action's name and what it named. Only a denial
    /// pays for this, which is why it may allocate.
    fn describe(&self, action: &AuthAction<'_>) -> (&'static str, String) {
        match action {
            AuthAction::Select | AuthAction::Recursive => ("select", String::new()),
            AuthAction::Read { table_name, .. } => ("read", format!("table={table_name}")),
            AuthAction::Insert { table_name } => ("insert", format!("table={table_name}")),
            AuthAction::Update { table_name, .. } => ("update", format!("table={table_name}")),
            AuthAction::Delete { table_name } => ("delete", format!("table={table_name}")),
            AuthAction::Transaction { .. } | AuthAction::Savepoint { .. } => ("transaction", String::new()),
            AuthAction::Function { function_name } => ("function", format!("name={function_name}")),
            AuthAction::Pragma { pragma_name, .. } => ("pragma", format!("name={pragma_name}")),
            AuthAction::Attach { .. } => ("attach", String::new()),
            AuthAction::Detach { .. } => ("detach", String::new()),
            AuthAction::CreateTable { table_name } => ("create-table", format!("table={table_name}")),
            AuthAction::CreateTempTable { table_name } => ("create-temp-table", format!("table={table_name}")),
            AuthAction::CreateIndex { table_name, .. } => ("create-index", format!("table={table_name}")),
            AuthAction::CreateTempIndex { table_name, .. } => ("create-temp-index", format!("table={table_name}")),
            AuthAction::CreateTrigger { table_name, .. } => ("create-trigger", format!("table={table_name}")),
            AuthAction::CreateTempTrigger { table_name, .. } => ("create-temp-trigger", format!("table={table_name}")),
            AuthAction::CreateView { .. } => ("create-view", String::new()),
            AuthAction::CreateTempView { .. } => ("create-temp-view", String::new()),
            AuthAction::CreateVtable { table_name, module_name } => {
                ("create-vtable", format!("table={table_name} module={module_name}"))
            }
            AuthAction::DropTable { table_name } => ("drop-table", format!("table={table_name}")),
            AuthAction::DropTempTable { table_name } => ("drop-temp-table", format!("table={table_name}")),
            AuthAction::DropIndex { table_name, .. } => ("drop-index", format!("table={table_name}")),
            AuthAction::DropTempIndex { table_name, .. } => ("drop-temp-index", format!("table={table_name}")),
            AuthAction::DropTrigger { table_name, .. } => ("drop-trigger", format!("table={table_name}")),
            AuthAction::DropTempTrigger { table_name, .. } => ("drop-temp-trigger", format!("table={table_name}")),
            AuthAction::DropView { .. } => ("drop-view", String::new()),
            AuthAction::DropTempView { .. } => ("drop-temp-view", String::new()),
            AuthAction::DropVtable { table_name, module_name } => {
                ("drop-vtable", format!("table={table_name} module={module_name}"))
            }
            AuthAction::AlterTable { table_name, .. } => ("alter-table", format!("table={table_name}")),
            AuthAction::Reindex { index_name } => ("reindex", format!("index={index_name}")),
            AuthAction::Analyze { table_name } => ("analyze", format!("table={table_name}")),
            // An action this build does not know is not an action it can vouch for. `AuthAction` is
            // `#[non_exhaustive]`, so a future SQLite action lands in the same arm as an unknown one.
            other => ("unknown", format!("{other:?}")),
        }
    }

    /// One line per refusal: the component, the action and what it named. Never a value.
    fn record(&self, detail: &str) {
        let Some(path) = &self.audit_path else { return };
        let _ = rotate_if_large(path);
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis())
                .unwrap_or(0);
            let _ = writeln!(file, "{stamp}\t{}\tsql refused\t{detail}", self.name);
        }
    }
}

fn rotate_if_large(path: &Path) -> std::io::Result<()> {
    let size = std::fs::metadata(path).map(|meta| meta.len()).unwrap_or(0);
    if size >= AUDIT_MAX_BYTES {
        let _ = std::fs::rename(path, path.with_extension("log.1"));
    }
    Ok(())
}

/// One seam call's connection. Every statement of the call runs here, so a transaction the component
/// opened is still open for its next statement and is rolled back by SQLite when this is dropped.
pub struct SqlSession {
    connection: Connection,
    guard: Guard,
    max_rows: usize,
    journal: Option<JournalTarget>,
}

impl SqlSession {
    pub fn query(&mut self, statement: &str, params: &[Scalar]) -> Result<Answer, SqlFailure> {
        self.run(statement, params, true)
    }

    pub fn exec(&mut self, statement: &str, params: &[Scalar]) -> Result<Answer, SqlFailure> {
        self.run(statement, params, false)
    }

    fn run(&mut self, statement: &str, params: &[Scalar], read: bool) -> Result<Answer, SqlFailure> {
        self.guard.audit.statements.fetch_add(1, Ordering::Relaxed);
        // Legibility, not enforcement: the authorizer below is what actually refuses these.
        early_refusal(statement)?;
        let mut prepared = self
            .connection
            .prepare(statement)
            .map_err(|error| classify(self.guard.name.as_str(), &error))?;
        let columns: Vec<String> = prepared.column_names().iter().map(|name| name.to_string()).collect();
        if read {
            let bound: Vec<rusqlite::types::Value> = params.iter().cloned().map(Into::into).collect();
            let mut rows = prepared
                .query(rusqlite::params_from_iter(bound))
                .map_err(|error| classify(self.guard.name.as_str(), &error))?;
            let mut out = Vec::new();
            loop {
                let row = rows.next().map_err(|error| classify(self.guard.name.as_str(), &error))?;
                let Some(row) = row else { break };
                if out.len() >= self.max_rows {
                    return Err(SqlFailure::Refused(format!("sql_row_limit:{max}", max = self.max_rows)));
                }
                let mut values = Vec::with_capacity(columns.len());
                for index in 0..columns.len() {
                    let value = row.get_ref(index).map_err(|error| classify(self.guard.name.as_str(), &error))?;
                    values.push(match value {
                        ValueRef::Null => Scalar::Null,
                        ValueRef::Integer(n) => Scalar::Integer(n),
                        ValueRef::Real(f) => Scalar::Real(f),
                        ValueRef::Text(text) => Scalar::Text(String::from_utf8_lossy(text).to_string()),
                        ValueRef::Blob(bytes) => Scalar::Blob(bytes.to_vec()),
                    });
                }
                out.push(values);
            }
            let changes = self.connection.changes();
            Ok(Answer { columns, rows: out, changes })
        } else {
            let bound: Vec<rusqlite::types::Value> = params.iter().cloned().map(Into::into).collect();
            prepared
                .execute(rusqlite::params_from_iter(bound))
                .map_err(|error| classify(self.guard.name.as_str(), &error))?;
            let changes = self.connection.changes();
            Ok(Answer { columns, rows: Vec::new(), changes })
        }
    }

    /// Whether the connection still has a transaction open — used by the caller to report a
    /// component that tried to leave one behind (it is rolled back when the session drops).
    pub fn in_transaction(&self) -> bool {
        !self.connection.is_autocommit()
    }

    /// `BEGIN IMMEDIATE`: the write lock is taken now, so a caller's duplicate check inside the unit
    /// cannot be passed by two interpreters at once, and a unit that is never committed is rolled
    /// back when the call ends.
    ///
    /// The transaction is the kernel's, but the statements inside it are the guest's, so the
    /// authorizer stays armed: an open transaction is not a way around the grant.
    pub fn begin_unit(&mut self) -> Result<(), SqlFailure> {
        if self.in_transaction() {
            return Err(SqlFailure::Refused("sql_unit_already_open".into()));
        }
        self.connection
            .execute_batch("BEGIN IMMEDIATE")
            .map_err(|error| classify(self.guard.name.as_str(), &error))
    }

    /// Append the unit's journal entry (when it owes one) and commit, in one transaction. A journal
    /// row that cannot be written rolls the unit back: the caller gets an error and the store is
    /// exactly as it was, instead of holding a mutation that has not replicated.
    pub fn commit_unit(&mut self, entry: Option<JournalEntry>) -> Result<(), SqlFailure> {
        if !self.in_transaction() {
            return Err(SqlFailure::Refused("sql_unit_not_open".into()));
        }
        if let Some(entry) = entry {
            let Some(target) = self.journal.clone() else {
                let _ = self.connection.execute_batch("ROLLBACK");
                return Err(SqlFailure::Refused("sql_journal_unavailable".into()));
            };
            if let Err(failure) = self.append_journal(&target, &entry) {
                let _ = self.connection.execute_batch("ROLLBACK");
                return Err(failure);
            }
        }
        self.connection
            .execute_batch("COMMIT")
            .map_err(|error| classify(self.guard.name.as_str(), &error))
    }

    /// Abandon the unit. A rollback with nothing open is a no-op, so a component that fails before
    /// it wrote anything does not have to guess whether to call this.
    pub fn rollback_unit(&mut self) -> Result<(), SqlFailure> {
        if !self.in_transaction() {
            return Ok(());
        }
        self.connection
            .execute_batch("ROLLBACK")
            .map_err(|error| classify(self.guard.name.as_str(), &error))
    }

    /// The kernel's own statement, on the kernel's own table, inside the guest's transaction.
    ///
    /// `journal` is deliberately absent from every manifest's write grant — the row's `origin` is the
    /// node's identity, which a component must not be able to name. So this statement is prepared
    /// with the authorizer removed and the guard restored immediately: the guest never gets this
    /// path, and a guest statement that names `journal` is still refused by the guard.
    fn append_journal(&mut self, target: &JournalTarget, entry: &JournalEntry) -> Result<(), SqlFailure> {
        validate_journal(target, entry)?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0);
        self.connection.authorizer::<fn(AuthContext<'_>) -> Authorization>(None);
        let written = self.connection.execute(
            "INSERT INTO journal(kind,entity_id,op,origin,payload,created_at) VALUES(?,?,?,?,?,?)",
            rusqlite::params![target.kind, entry.entity_id, entry.op, target.origin, entry.payload, now],
        );
        let guard = self.guard.clone();
        self.connection.authorizer(Some(move |context: AuthContext<'_>| guard.verdict(context)));
        written.map_err(|error| SqlFailure::Failed(format!("journal: {error}")))?;
        self.guard.audit.journal_entries.fetch_add(1, Ordering::Relaxed);
        Ok(())
    }
}

/// Whether an entry may reach the log at all. Every refusal here is one the caller can act on, and
/// none of them leaves a half-written mutation: `commit_unit` rolls the unit back when this fails.
fn validate_journal(target: &JournalTarget, entry: &JournalEntry) -> Result<(), SqlFailure> {
    let kind_ok = !target.kind.is_empty()
        && target.kind.len() <= 32
        && target.kind.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
    if !kind_ok {
        return Err(SqlFailure::Refused("sql_journal_kind_invalid".into()));
    }
    if entry.entity_id.is_empty() || entry.entity_id.len() > MAX_JOURNAL_ENTITY {
        return Err(SqlFailure::Refused("sql_journal_entity_invalid".into()));
    }
    // The log's vocabulary, not a free-form verb: a reader splits entries by `op`.
    if entry.op != "upsert" && entry.op != "delete" {
        return Err(SqlFailure::Refused(format!("sql_journal_op_unknown:{}", entry.op)));
    }
    if entry.payload.len() > MAX_JOURNAL_PAYLOAD {
        return Err(SqlFailure::Refused("sql_journal_payload_too_large".into()));
    }
    // A payload a peer cannot apply is not an entry: it is refused here, where the unit can still
    // be rolled back, instead of reaching a log whose reader would have to skip it.
    match serde_json::from_str::<Json>(&entry.payload) {
        Ok(Json::Object(_)) => Ok(()),
        _ => Err(SqlFailure::Refused("sql_journal_payload_invalid".into())),
    }
}

/// Whether `text` holds at most one statement. Semicolons inside a literal, a quoted identifier or a
/// comment do not separate anything; a second statement after one does.
fn single_statement(text: &str) -> bool {
    #[derive(PartialEq)]
    enum State {
        Normal,
        Single,
        Double,
        Backtick,
        Bracket,
        Line,
        Block,
    }
    let mut state = State::Normal;
    let mut chars = text.chars().peekable();
    let mut after_separator = false;
    while let Some(c) = chars.next() {
        match state {
            State::Normal => match c {
                '\'' => state = State::Single,
                '"' => state = State::Double,
                '`' => state = State::Backtick,
                '[' => state = State::Bracket,
                '-' if chars.peek() == Some(&'-') => {
                    chars.next();
                    state = State::Line;
                }
                '/' if chars.peek() == Some(&'*') => {
                    chars.next();
                    state = State::Block;
                }
                ';' => after_separator = true,
                _ if !c.is_whitespace() && after_separator => return false,
                _ => {}
            },
            // In a literal, `''` is an escaped quote, not the end of it.
            State::Single => {
                if c == '\'' {
                    if chars.peek() == Some(&'\'') {
                        chars.next();
                    } else {
                        state = State::Normal;
                    }
                }
            }
            State::Double => {
                if c == '"' {
                    if chars.peek() == Some(&'"') {
                        chars.next();
                    } else {
                        state = State::Normal;
                    }
                }
            }
            State::Backtick => {
                if c == '`' {
                    state = State::Normal;
                }
            }
            State::Bracket => {
                if c == ']' {
                    state = State::Normal;
                }
            }
            State::Line => {
                if c == '\n' {
                    state = State::Normal;
                }
            }
            State::Block => {
                if c == '*' && chars.peek() == Some(&'/') {
                    chars.next();
                    state = State::Normal;
                }
            }
        }
    }
    true
}

/// The statement shapes refused before the engine sees them. Every one of them is also refused by the
/// authorizer (see the tests): this is the message, not the wall. Pragmas are *not* short-circuited
/// here — the authorizer decides them, because a read-only one (`table_info`) has to keep working.
fn early_refusal(statement: &str) -> Result<(), SqlFailure> {
    if statement.len() > MAX_STATEMENT {
        return Err(SqlFailure::Refused("sql_statement_too_large".into()));
    }
    if !single_statement(statement) {
        // rusqlite executes only the first statement of a string and drops the rest without a word.
        // That is a silent failure on a security boundary, so it is a refusal here instead.
        return Err(SqlFailure::Refused("sql_multiple_statements".into()));
    }
    if statement.contains('\0') {
        return Err(SqlFailure::Refused("sql_nul_byte".into()));
    }
    let head = statement
        .trim_start()
        .split(|c: char| c.is_whitespace() || c == '(')
        .next()
        .unwrap_or("")
        .to_ascii_uppercase();
    if head == "ATTACH" || head == "DETACH" {
        return Err(SqlFailure::Refused(format!("sql_{}", head.to_ascii_lowercase())));
    }
    Ok(())
}

/// SQLite's "not authorized" is the authorizer speaking; everything else is the store.
fn classify(name: &str, error: &rusqlite::Error) -> SqlFailure {
    let text = error.to_string();
    if text.contains("not authorized") || text.contains("is prohibited") {
        return SqlFailure::Refused(format!("sql_not_authorized:{name}"));
    }
    if text.contains("interrupted") {
        return SqlFailure::Refused("sql_deadline".into());
    }
    if text.contains("multiple statements") || text.contains("multiple statement") {
        return SqlFailure::Refused("sql_multiple_statements".into());
    }
    SqlFailure::Failed(text)
}

/// The database this node's memory lives in: the path the CLI resolved (`WASM_AGENT_DB`), else the
/// node's home. The same resolution `wa --db` does, so a component and the native path open the same
/// file even in a test with a scratch home.
pub fn database_path() -> PathBuf {
    if let Ok(path) = std::env::var("WASM_AGENT_DB") {
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }
    let home = wa_host_support::paths::resolve_home();
    PathBuf::from(home).join(".wasm-agent").join("memory.db")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::Ordering;

    /// A scratch database with the real memory schema: `lua/core/schema.sql` is what a node runs, so
    /// the shadow tables the FTS index keeps are the real ones.
    fn scratch() -> (PathBuf, PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "wa-sql-host-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        let db = dir.join("memory.db");
        let _dir = dir;
        let schema = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../lua/core/schema.sql"))
            .expect("the node's schema is readable");
        let connection = Connection::open(&db).expect("open");
        connection.execute_batch(&schema).expect("schema applies");
        connection
            .execute_batch(
                "INSERT INTO memories(id,scope,content,tags,source,created_at,updated_at,content_sha256) \
                 VALUES('m1','global','the deploy token lives in the vault','[]','user',1.0,1.0,'abc');
                 INSERT INTO memories_fts(content,tags,memory_id) \
                 VALUES('the deploy token lives in the vault','','m1');",
            )
            .expect("seed");
        (_dir, db)
    }

    fn memory_scope(db: &Path) -> SqlScope {
        SqlScope::from_manifest(
            "memory",
            db,
            &serde_json::json!({"capabilities": {"sql": {
                "database": "memory",
                "read": ["memories", "memories_fts", "messages", "messages_fts", "sessions"],
                "write": ["memories", "memories_fts"]
            }}}),
        )
        .expect("manifest grant")
    }

    #[test]
    fn the_granted_tables_answer_and_the_fts_shadow_tables_are_part_of_the_index() {
        let (_dir, db) = scratch();
        let mut session = memory_scope(&db).session().expect("session");
        let answer = session
            .query(
                "SELECT m.id, bm25(memories_fts) AS rank FROM memories_fts \
                 JOIN memories m ON m.id=memories_fts.memory_id WHERE memories_fts MATCH ?",
                &[Scalar::Text("\"vault\"".into())],
            )
            .expect("the FTS match is inside the grant");
        assert_eq!(answer.columns, vec!["id", "rank"]);
        assert_eq!(answer.rows.len(), 1);
        assert_eq!(answer.rows[0][0], Scalar::Text("m1".into()));
    }

    #[test]
    fn another_table_read_is_refused_and_audited() {
        let (dir, db) = scratch();
        let audit_path = dir.join("memory.sql-audit.log");
        let scope = memory_scope(&db).with_audit_file(&audit_path);
        let audit = scope.audit();
        let mut session = scope.session().expect("session");
        let error = session.query("SELECT * FROM runs", &[]).expect_err("runs is not granted");
        assert!(matches!(error, SqlFailure::Refused(_)), "{error:?}");
        assert_eq!(audit.denials.load(Ordering::Relaxed), 1);
        let line = std::fs::read_to_string(&audit_path).expect("audit file");
        assert!(line.contains("sql refused") && line.contains("table=runs"), "{line:?}");
        // Nothing of the database's own values is in the line.
        assert!(!line.contains("vault"));
    }

    #[test]
    fn a_write_outside_the_grant_is_refused_even_when_the_read_is_allowed() {
        let (_dir, db) = scratch();
        let mut session = memory_scope(&db).session().expect("session");
        assert!(session.query("SELECT id FROM sessions", &[]).is_ok());
        let error = session
            .exec("UPDATE sessions SET objective='x'", &[])
            .expect_err("sessions is read-only in this grant");
        assert!(matches!(error, SqlFailure::Refused(_)), "{error:?}");
    }

    #[test]
    fn attach_detach_and_pragma_are_refused() {
        let (_dir, db) = scratch();
        let mut session = memory_scope(&db).session().expect("session");
        for statement in [
            "ATTACH DATABASE '/tmp/other.db' AS other",
            // A pragma that takes a value is a write, whatever its name.
            "PRAGMA user_version=7",
            "PRAGMA journal_mode=DELETE",
            // ... and these write without taking a value, which is why the rule is an allow-list.
            "PRAGMA optimize",
            "PRAGMA incremental_vacuum",
            "PRAGMA wal_checkpoint",
        ] {
            let error = session.exec(statement, &[]).expect_err(statement);
            assert!(matches!(error, SqlFailure::Refused(_)), "{statement}: {error:?}");
        }
        // Read-only introspection is allowed: it is how a caller asks what shape the store is in.
        assert!(session.query("PRAGMA table_info(memories)", &[]).is_ok());
        // The database is unchanged by the refused pragma.
        let mut session = memory_scope(&db).session().expect("session");
        // `PRAGMA user_version` as the *host* (no authorizer) still reads 0.
        let check = Connection::open(&db).expect("open");
        let version: i64 = check.query_row("PRAGMA user_version", [], |row| row.get(0)).expect("read");
        assert_eq!(version, 0);
        assert!(session.query("SELECT 1 AS one", &[]).is_ok());
    }

    #[test]
    fn ddl_and_a_second_statement_are_refused() {
        let (_dir, db) = scratch();
        let mut session = memory_scope(&db).session().expect("session");
        for statement in [
            "CREATE TABLE secrets (x TEXT)",
            "DROP TABLE memories",
            "CREATE TEMP TABLE scratch (x TEXT)",
            "INSERT INTO memories_fts(content,tags,memory_id) VALUES('a','b','m2'); DROP TABLE memories_fts",
        ] {
            let error = session.exec(statement, &[]).expect_err(statement);
            assert!(matches!(error, SqlFailure::Refused(_)), "{statement}: {error:?}");
        }
        // A function that reaches outside the database is refused even inside an allowed read.
        let error = session.query("SELECT load_extension('/tmp/x') AS x", &[]).expect_err("load_extension");
        assert!(matches!(error, SqlFailure::Refused(_)), "{error:?}");
    }

    #[test]
    fn a_transaction_spans_statements_and_rolls_back_when_the_call_ends() {
        let (_dir, db) = scratch();
        {
            let mut session = memory_scope(&db).session().expect("session");
            session.exec("BEGIN IMMEDIATE", &[]).expect("begin");
            session
                .exec(
                    "INSERT INTO memories(id,scope,content,tags,source,created_at,updated_at,content_sha256) \
                     VALUES('m2','global','forgotten again','[]','user',2.0,2.0,'def')",
                    &[],
                )
                .expect("insert");
            session
                .exec(
                    "INSERT INTO memories_fts(content,tags,memory_id) VALUES('forgotten again','','m2')",
                    &[],
                )
                .expect("index");
            assert!(session.in_transaction());
            session.exec("ROLLBACK", &[]).expect("rollback");
            assert!(!session.in_transaction());
        }
        let check = Connection::open(&db).expect("open");
        let count: i64 = check.query_row("SELECT COUNT(*) FROM memories", [], |row| row.get(0)).expect("count");
        assert_eq!(count, 1, "the rolled-back row is gone");
    }

    #[test]
    fn an_empty_grant_refuses_everything() {
        let (_dir, db) = scratch();
        let mut session = SqlScope::new("memory", &db).session().expect("session");
        let error = session.query("SELECT id FROM memories", &[]).expect_err("nothing is granted");
        assert!(matches!(error, SqlFailure::Refused(_)), "{error:?}");
        assert!(session.query("SELECT 1 AS one", &[]).is_ok(), "a statement with no table is harmless");
    }

    #[test]
    fn the_row_limit_is_a_refusal_not_a_truncation() {
        let (_dir, db) = scratch();
        let mut session = memory_scope(&db).with_max_rows(1).session().expect("session");
        let connection = Connection::open(&db).expect("open");
        connection
            .execute_batch(
                "INSERT INTO memories(id,scope,content,tags,source,created_at,updated_at,content_sha256) \
                 VALUES('m2','global','second','[]','user',2.0,2.0,'def');",
            )
            .expect("seed a second row");
        let error = session.query("SELECT id FROM memories", &[]).expect_err("over the limit");
        assert_eq!(error, SqlFailure::Refused("sql_row_limit:1".into()));
    }

    #[test]
    fn a_manifest_that_names_no_database_or_names_another_one() {
        let (_dir, db) = scratch();
        let scope = SqlScope::from_manifest("memory", &db, &serde_json::json!({"capabilities": {"sql": {}}})).expect("empty grant");
        assert_eq!(scope.tables(), (&[][..], &[][..]));
        let error = SqlScope::from_manifest(
            "memory",
            &db,
            &serde_json::json!({"capabilities": {"sql": {"database": "the-whole-disk"}}}),
        )
        .expect_err("an unknown database is refused");
        assert!(error.contains("component_sql_database_unknown"), "{error}");
        let error = SqlScope::from_manifest(
            "memory",
            &db,
            &serde_json::json!({"capabilities": {"sql": {"read": ["../escape"]}}}),
        )
        .expect_err("a table name is not a path");
        assert!(error.contains("invalid_component_grant"), "{error}");
    }

    #[test]
    fn the_single_statement_guard_ignores_literals_and_comments() {
        assert!(single_statement("SELECT 1"));
        assert!(single_statement("SELECT 1;"));
        assert!(single_statement("SELECT ';' AS semi"));
        assert!(single_statement("SELECT \";\" AS semi -- a; comment
"));
        assert!(single_statement("SELECT 1 /* ; */"));
        assert!(!single_statement("SELECT 1; DROP TABLE memories"));
        assert!(!single_statement("SELECT 1;SELECT 2"));
        assert!(!single_statement("SELECT 1; /* c */ DELETE FROM memories"));
    }

    #[test]
    fn the_pragma_policy_refuses_every_write_and_allows_introspection() {
        for name in ["data_version", "schema_version", "integrity_check", "page_count"] {
            assert!(pragma_allowed(name, false), "{name} should be readable");
        }
        assert!(pragma_allowed("table_info", true), "an object-name argument is not a write");
        for name in ["optimize", "incremental_vacuum", "wal_checkpoint", "journal_mode", "user_version", "foreign_keys"] {
            assert!(!pragma_allowed(name, false), "{name} must not be allowed without a value");
            assert!(!pragma_allowed(name, true), "{name} must not be allowed with a value");
        }
    }

    /// A WIT interface's body with comments and whitespace removed: what has to match between the
    /// kernel's own files and the copy a component compiles against.
    fn interface_body(source: &str, name: &str) -> String {
        let mut lines = Vec::new();
        let mut depth = 0i32;
        let mut inside = false;
        for raw in source.lines() {
            let line = match raw.find("//") {
                Some(at) => &raw[..at],
                None => raw,
            };
            let line = line.trim();
            if !inside {
                if line == format!("interface {name} {{") {
                    inside = true;
                    depth = 1;
                }
                continue;
            }
            depth += line.matches('{').count() as i32;
            depth -= line.matches('}').count() as i32;
            if depth <= 0 {
                break;
            }
            if !line.is_empty() {
                lines.push(line.to_string());
            }
        }
        assert!(inside, "interface {name} not found");
        lines.join("
")
    }

    /// The grant a component compiles against is a *copy* (`wit/memory/deps/kernel/kernel.wit`, because
    /// a WIT package resolves its imports from `deps/`). A copy that drifts would let a component
    /// build against one contract and be refused at run time by another, so it is checked here: the
    /// `sql` and `types` interfaces must be identical to the kernel's own files.
    #[test]
    fn vendored_kernel_copy_matches_the_kernel() {
        let read = |path: &str| {
            std::fs::read_to_string(format!("{}/../../{path}", env!("CARGO_MANIFEST_DIR"))).expect(path)
        };
        let canonical = read("wit/kernel/sql.wit");
        let kernel = read("wit/kernel/kernel.wit");
        let vendored = read("wit/memory/deps/kernel/kernel.wit");
        assert_eq!(
            interface_body(&canonical, "sql"),
            interface_body(&vendored, "sql"),
            "wit/memory/deps/kernel/kernel.wit has drifted from wit/kernel/sql.wit"
        );
        assert_eq!(
            interface_body(&kernel, "types"),
            interface_body(&vendored, "types"),
            "wit/memory/deps/kernel/kernel.wit has drifted from wit/kernel/kernel.wit"
        );
    }

    #[test]
    fn the_database_path_follows_the_node() {
        // `WASM_AGENT_DB` is process-wide, so this test owns the variable while it runs.
        let key = "WASM_AGENT_DB";
        let previous = std::env::var(key).ok();
        std::env::set_var(key, "/tmp/wa-memory-path-test.db");
        assert_eq!(database_path(), PathBuf::from("/tmp/wa-memory-path-test.db"));
        match previous {
            Some(value) => std::env::set_var(key, value),
            None => std::env::remove_var(key),
        }
    }

    // ------------------------------------------------------------------------------- unit of work

    /// The grant the memory component runs under, plus the journal target the kernel configures.
    fn journal_scope(db: &Path, origin: &str) -> SqlScope {
        memory_scope(db).with_journal("memory", origin)
    }

    /// The two writes a `remember` is: the row and its search entry.
    fn write_a_fact(session: &mut SqlSession, id: &str, content: &str) {
        session
            .exec(
                "INSERT INTO memories(id,scope,content,tags,source,created_at,updated_at,content_sha256) \
                 VALUES(?,?,?,'[]','user',2.0,2.0,?)",
                &[
                    Scalar::Text(id.to_string()),
                    Scalar::Text("global".into()),
                    Scalar::Text(content.into()),
                    Scalar::Text(format!("sha-{id}")),
                ],
            )
            .expect("insert");
        session
            .exec(
                "INSERT INTO memories_fts(content,tags,memory_id) VALUES(?,?,?)",
                &[Scalar::Text(content.into()), Scalar::Text(String::new()), Scalar::Text(id.to_string())],
            )
            .expect("index");
    }

    fn entry(op: &str, payload: &str) -> JournalEntry {
        JournalEntry { entity_id: "m2".into(), op: op.into(), payload: payload.into() }
    }

    fn counts(db: &Path) -> (i64, i64) {
        let check = Connection::open(db).expect("open");
        let memories: i64 = check.query_row("SELECT COUNT(*) FROM memories", [], |row| row.get(0)).expect("count");
        let journal: i64 = check.query_row("SELECT COUNT(*) FROM journal", [], |row| row.get(0)).expect("count");
        (memories, journal)
    }

    #[test]
    fn a_unit_of_work_appends_its_journal_row_and_commits_both() {
        let (_dir, db) = scratch();
        let scope = journal_scope(&db, "node-a");
        let audit = scope.audit();
        let mut session = scope.session().expect("session");
        session.begin_unit().expect("begin");
        write_a_fact(&mut session, "m2", "the release key is in the vault");
        // While the unit is open nobody else sees either half: this is what makes the journal row
        // part of the component's transaction instead of a second one.
        assert_eq!(counts(&db), (1, 0), "an open unit is invisible to the store's own readers");
        session
            .commit_unit(Some(entry(
                "upsert",
                r#"{"id":"m2","scope":"global","content":"the release key is in the vault"}"#,
            )))
            .expect("commit");
        assert!(!session.in_transaction());
        assert_eq!(counts(&db), (2, 1), "the fact and its replication entry landed together");
        let check = Connection::open(&db).expect("open");
        let (kind, entity, op, origin, payload): (String, String, String, String, String) = check
            .query_row("SELECT kind,entity_id,op,origin,payload FROM journal", [], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?))
            })
            .expect("the journal row");
        assert_eq!((kind.as_str(), entity.as_str(), op.as_str(), origin.as_str()), ("memory", "m2", "upsert", "node-a"));
        assert!(payload.contains("release key"), "the payload is the entry's own JSON: {payload}");
        assert_eq!(audit.journal_entries.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn a_unit_that_is_dropped_leaves_neither_the_fact_nor_the_entry() {
        let (_dir, db) = scratch();
        {
            let mut session = journal_scope(&db, "node-a").session().expect("session");
            session.begin_unit().expect("begin");
            write_a_fact(&mut session, "m2", "never committed");
            // The guest is killed here (`memory-crash` wedges mid-call; the epoch stops it): the
            // session is dropped with the transaction open and SQLite rolls it back.
        }
        assert_eq!(counts(&db), (1, 0));
    }

    #[test]
    fn a_journal_the_kernel_refuses_rolls_the_unit_back() {
        let (_dir, db) = scratch();
        for (label, bad) in [
            ("an unknown verb", entry("merge", r#"{"id":"m2"}"#)),
            ("a payload that is not JSON", entry("upsert", "{")),
            ("a payload that is not an object", entry("upsert", "[1,2,3]")),
            ("an empty entity", JournalEntry { entity_id: String::new(), ..entry("upsert", "{}") }),
        ] {
            let mut session = journal_scope(&db, "node-a").session().expect("session");
            session.begin_unit().expect("begin");
            write_a_fact(&mut session, "m2", "must not survive a refused journal");
            let error = session.commit_unit(Some(bad)).expect_err(label);
            assert!(matches!(error, SqlFailure::Refused(_)), "{label}: {error:?}");
            assert!(!session.in_transaction(), "{label}: the refusal did not leave a transaction");
            // Either both or neither: a fact the kernel could not journal is not stored.
            assert_eq!(counts(&db), (1, 0), "{label}: the write was rolled back with the entry");
        }
    }

    #[test]
    fn a_unit_with_no_journal_target_commits_nothing_but_still_commits_when_it_owes_nothing() {
        let (_dir, db) = scratch();
        let mut session = memory_scope(&db).session().expect("session");
        session.begin_unit().expect("begin");
        write_a_fact(&mut session, "m2", "a read-shaped unit owes no entry");
        session.commit_unit(None).expect("commit with no entry");
        assert_eq!(counts(&db), (2, 0));
        let mut session = memory_scope(&db).session().expect("session");
        session.begin_unit().expect("begin");
        write_a_fact(&mut session, "m3", "this one does");
        let error = session.commit_unit(Some(entry("upsert", "{}"))).expect_err("no origin is configured");
        assert_eq!(error, SqlFailure::Refused("sql_journal_unavailable".into()));
        assert_eq!(counts(&db), (2, 0), "the unjournalled fact is not stored");
    }

    #[test]
    fn a_journal_kind_the_log_cannot_carry_is_refused() {
        let (_dir, db) = scratch();
        let mut session = memory_scope(&db)
            .with_journal("not a word", "node-a")
            .session()
            .expect("session");
        session.begin_unit().expect("begin");
        let error = session.commit_unit(Some(entry("upsert", "{}"))).expect_err("bad kind");
        assert_eq!(error, SqlFailure::Refused("sql_journal_kind_invalid".into()));
        assert_eq!(counts(&db), (1, 0));
    }

    #[test]
    fn begin_and_commit_take_turns_and_a_guest_still_cannot_write_the_journal() {
        let (_dir, db) = scratch();
        let mut session = journal_scope(&db, "node-a").session().expect("session");
        let error = session.commit_unit(None).expect_err("no unit is open");
        assert_eq!(error, SqlFailure::Refused("sql_unit_not_open".into()));
        session.begin_unit().expect("begin");
        let error = session.begin_unit().expect_err("a unit is already open");
        assert_eq!(error, SqlFailure::Refused("sql_unit_already_open".into()));
        // `journal` is not in the guest's write grant, with or without a unit of work.
        let error = session
            .exec(
                "INSERT INTO journal(kind,entity_id,op,origin,payload,created_at) VALUES('memory','m2','upsert','mine','{}',1)",
                &[],
            )
            .expect_err("a guest may not name the origin");
        assert!(matches!(error, SqlFailure::Refused(_)), "{error:?}");
        // A rollback with nothing written is a no-op, and the unit is gone either way.
        session.rollback_unit().expect("rollback");
        assert!(!session.in_transaction());
        session.rollback_unit().expect("rollback again is harmless");
        assert_eq!(counts(&db), (1, 0));
    }
}
