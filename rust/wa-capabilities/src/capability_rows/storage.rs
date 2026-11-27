//! Storage and the ledger: the interpreter's own SQLite connection (sql_exec, sql_query,
//! sql_rows), the two per-process facts a preamble asks (script_run, sql_patience) and the
//! readiness marker the ledger migration sets. The handlers are in crate::host.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::{plain, upvalue};

pub const ROWS: &[crate::capabilities::Capability] = &[
    upvalue!("sql_exec", WritesFiles, crate::host::sql_exec, "Run one statement against this interpreter's own SQLite connection; returns the changes/row count"),
    upvalue!("sql_query", ReadOnly, crate::host::sql_query, "Run one read query against this interpreter's own SQLite connection; returns rows"),
    upvalue!("sql_rows", ReadOnly, crate::host::sql_rows, "Run one read query against this interpreter's own SQLite connection; returns the rows as a Lua table, not JSON text"),
    plain!("script_run", ReadOnly, crate::host::script_run, "Whether this process was started to run one Lua script file (WA_SCRIPT), a per-process fact no child inherits"),
    plain!("sql_patience", ReadOnly, crate::host::sql_patience, "Bound how long this process's statements may wait for a lock, until it is set back with 0 (a turn's preamble)"),
    plain!("db_ready", ReadOnly, crate::host::db_ready, "Whether the ledger schema migration has run in this process"),
    plain!("mark_db_ready", WritesFiles, crate::host::mark_db_ready, "Record that the ledger schema migration has run"),
];
