//! `wa:kernel/sql` — the kernel's database, granted one table at a time.
//!
//! The memory seam keeps `memory.db` in the kernel (docs/KERNEL.md, "Memory as a component") and
//! gives the component statements instead of a file handle. This module is the whole of that grant:
//! a scope (which tables may be read, which may be written), one SQLite connection per seam call,
//! and a **SQLite authorizer** that decides every action the engine asks permission for.
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
/// guest's own epoch deadline is the outer bound; this one keeps a wedged query from holding the
/// connection (and the write lock) after the guest was stopped.
pub const STATEMENT_DEADLINE: Duration = Duration::from_secs(10);
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
}

/// Where a component's SQL may reach. One of these per installed component, built from its manifest.
#[derive(Debug)]
pub struct SqlScope {
    name: String,
    db: PathBuf,
    read: Vec<String>,
    write: Vec<String>,
    max_rows: usize,
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

    /// One connection for one seam call: the component's `BEGIN IMMEDIATE` … `COMMIT` has to span
    /// several statements, so all of them run here, and the connection (and any transaction left
    /// open on it) is closed when the call ends.
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
        let deadline = Instant::now() + STATEMENT_DEADLINE;
        // The authorizer decides every action the engine asks about; the progress handler stops a
        // statement that has run too long even when every action in it was allowed.
        {
            let guard = guard.clone();
            connection.authorizer(Some(move |context: AuthContext<'_>| guard.verdict(context)));
        }
        connection.progress_handler(1_000, Some(move || Instant::now() > deadline));
        Ok(SqlSession { connection, guard, max_rows: self.max_rows })
    }
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

    fn verdict(&self, context: AuthContext<'_>) -> Authorization {
        let (allowed, action, target) = self.decide(&context.action);
        if allowed {
            return Authorization::Allow;
        }
        self.audit.denials.fetch_add(1, Ordering::Relaxed);
        if std::env::var("WA_SQL_DEBUG").is_ok() {
            eprintln!("DENY {action} {target} {context:?}");
        }
        self.record(&format!("{action} {target}"));
        Authorization::Deny
    }

    /// The whole policy, in one place: (allowed, action name, target for the audit line).
    fn decide(&self, action: &AuthAction<'_>) -> (bool, &'static str, String) {
        let covers_read = |table: &str| self.readable(table);
        let covers_write = |table: &str| self.writable(table);
        match action {
            // Reads, and a statement that only selects.
            AuthAction::Select | AuthAction::Recursive => (true, "select", String::new()),
            AuthAction::Read { table_name, .. } => (covers_read(table_name), "read", format!("table={table_name}")),
            // Writes the grant names.
            AuthAction::Insert { table_name } => (covers_write(table_name), "insert", format!("table={table_name}")),
            AuthAction::Update { table_name, .. } => (covers_write(table_name), "update", format!("table={table_name}")),
            AuthAction::Delete { table_name } => (covers_write(table_name), "delete", format!("table={table_name}")),
            // Transactions are how one memory write stays one unit. Savepoints are the same shape
            // one level down and are what rusqlite's own nested statements use.
            AuthAction::Transaction { .. } | AuthAction::Savepoint { .. } => (true, "transaction", String::new()),
            // Functions: everything SQLite and FTS5 provide is fine; the ones that reach outside the
            // database are not, and a loader is not a memory operation.
            AuthAction::Function { function_name } => {
                let banned = [
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
                (
                    !banned.contains(&function_name.to_ascii_lowercase().as_str()),
                    "function",
                    format!("name={function_name}"),
                )
            }
            // Everything below is outside the grant by construction, and named so the log says why.
            AuthAction::Pragma { pragma_name, pragma_value } => (
                pragma_allowed(pragma_name, pragma_value.is_some()),
                "pragma",
                format!("name={pragma_name}"),
            ),
            AuthAction::Attach { .. } => (false, "attach", String::new()),
            AuthAction::Detach { .. } => (false, "detach", String::new()),
            AuthAction::CreateTable { table_name } => (false, "create-table", format!("table={table_name}")),
            AuthAction::CreateTempTable { table_name } => (false, "create-temp-table", format!("table={table_name}")),
            AuthAction::CreateIndex { table_name, .. } => (false, "create-index", format!("table={table_name}")),
            AuthAction::CreateTempIndex { table_name, .. } => (false, "create-temp-index", format!("table={table_name}")),
            AuthAction::CreateTrigger { table_name, .. } => (false, "create-trigger", format!("table={table_name}")),
            AuthAction::CreateTempTrigger { table_name, .. } => (false, "create-temp-trigger", format!("table={table_name}")),
            AuthAction::CreateView { .. } => (false, "create-view", String::new()),
            AuthAction::CreateTempView { .. } => (false, "create-temp-view", String::new()),
            AuthAction::CreateVtable { table_name, module_name } => {
                (false, "create-vtable", format!("table={table_name} module={module_name}"))
            }
            AuthAction::DropTable { table_name } => (false, "drop-table", format!("table={table_name}")),
            AuthAction::DropTempTable { table_name } => (false, "drop-temp-table", format!("table={table_name}")),
            AuthAction::DropIndex { table_name, .. } => (false, "drop-index", format!("table={table_name}")),
            AuthAction::DropTempIndex { table_name, .. } => (false, "drop-temp-index", format!("table={table_name}")),
            AuthAction::DropTrigger { table_name, .. } => (false, "drop-trigger", format!("table={table_name}")),
            AuthAction::DropTempTrigger { table_name, .. } => (false, "drop-temp-trigger", format!("table={table_name}")),
            AuthAction::DropView { .. } => (false, "drop-view", String::new()),
            AuthAction::DropTempView { .. } => (false, "drop-temp-view", String::new()),
            AuthAction::DropVtable { table_name, module_name } => {
                (false, "drop-vtable", format!("table={table_name} module={module_name}"))
            }
            AuthAction::AlterTable { table_name, .. } => (false, "alter-table", format!("table={table_name}")),
            AuthAction::Reindex { index_name } => (false, "reindex", format!("index={index_name}")),
            AuthAction::Analyze { table_name } => (false, "analyze", format!("table={table_name}")),
            // An action this build does not know is not an action it can vouch for. `AuthAction` is
            // `#[non_exhaustive]`, so a future SQLite action lands in the same arm as an unknown one.
            other => (false, "unknown", format!("{other:?}")),
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
}
