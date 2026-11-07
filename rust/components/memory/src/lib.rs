//! The memory seam as a component (`docs/KERNEL.md`, "Memory as a component").
//!
//! It exports `wa:memory/memory` — remember, recall, forget, list, search-messages, sessions and the
//! retention decision — and imports one thing: `wa:kernel/sql`, scoped by this component's manifest
//! to the memory tables of `memory.db`. The file stays in the kernel; the ranking, the search passes,
//! the scope rules and the retention policy are here, where they can be swapped without rebuilding
//! the node.
//!
//! Every rule below is a port of `lua/core/memory.lua`, and the parity suite
//! (`scripts/test-memory-component.lua`) sends the same inputs through both and compares the answers
//! field for field. A deliberate difference would be reported as a failure, so the comments name the
//! native rule each block copies rather than inventing a better one.
//!
//! What is *not* here, on purpose: the replication journal. A journal entry has to carry the node's
//! own identity as its origin, and a component never names itself — so the kernel writes that row
//! after a call that changed something (see `rust/wa-kernel-runtime/src/memory_host.rs`).
// The world lives in the repo's wit/ tree, next to the kernel package it imports, so there is one
// copy of the contract rather than a vendored one per component (the pattern `svc-wasi-kv` uses).
wit_bindgen::generate!({ path: "../../../wit/memory", world: "memory-component", generate_all });

mod logic;

use sha2::{Digest, Sha256};
use wa::kernel::sql::{self, Value};
use wa::memory::types::{Error as MError, Forgotten, Memory, MessageHit, Remembered, Session};

use crate::exports::wa::memory::memory::{Guest, RetentionPlan};

/// `memory_too_large`: the native bound on one fact, in bytes.
const MAX_CONTENT: usize = 8000;
/// `memory_scope_full`: how many live facts one `user:` scope may hold.
const MAX_PER_GUEST_SCOPE: i64 = 500;
/// The recency bonus fades over a month, as in the native ranking's `2592000.0`.
const RECENCY_WINDOW: f64 = 2_592_000.0;

/// The exported component: one fn per seam operation, no state of its own.
struct MemoryComponent;

// ---------------------------------------------------------------------------------------- helpers

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// A host-side SQL failure, as the seam reports it. `refused` stays `refused`: the caller must be
/// able to tell "the grant does not cover this" from "the database broke".
fn fault(error: wa::kernel::sql::Error) -> MError {
    match error {
        wa::kernel::sql::Error::Refused(why) => MError::Refused(why),
        wa::kernel::sql::Error::Failed(why) => MError::Failed(why),
        wa::kernel::sql::Error::Again => MError::Failed("again".into()),
        wa::kernel::sql::Error::Closed => MError::Failed("closed".into()),
    }
}

fn query(statement: &str, params: &[Value]) -> Result<Answer, MError> {
    sql::query(statement, params).map(Answer::from).map_err(fault)
}

fn exec(statement: &str, params: &[Value]) -> Result<Answer, MError> {
    sql::exec(statement, params).map(Answer::from).map_err(fault)
}

/// One statement's answer, addressed by column name, so the columns a statement asks for decide
/// nothing about how its values are read.
struct Answer {
    columns: Vec<String>,
    rows: Vec<Vec<Value>>,
    changes: u64,
}

impl From<wa::kernel::sql::Rows> for Answer {
    fn from(rows: wa::kernel::sql::Rows) -> Self {
        Answer { columns: rows.columns, rows: rows.rows, changes: rows.changes }
    }
}

impl Answer {
    fn index(&self, name: &str) -> Option<usize> {
        self.columns.iter().position(|column| column == name)
    }

    fn text(&self, row: &[Value], name: &str) -> String {
        match self.index(name).and_then(|i| row.get(i)) {
            Some(Value::Text(text)) => text.clone(),
            Some(Value::Integer(n)) => n.to_string(),
            Some(Value::Real(f)) => f.to_string(),
            Some(Value::Blob(bytes)) => String::from_utf8_lossy(bytes).to_string(),
            _ => String::new(),
        }
    }

    fn optional_text(&self, row: &[Value], name: &str) -> Option<String> {
        match self.index(name).and_then(|i| row.get(i)) {
            Some(Value::Null) | None => None,
            Some(_) => Some(self.text(row, name)),
        }
    }

    fn real(&self, row: &[Value], name: &str) -> f64 {
        match self.index(name).and_then(|i| row.get(i)) {
            Some(Value::Real(f)) => *f,
            Some(Value::Integer(n)) => *n as f64,
            Some(Value::Text(text)) => text.parse::<f64>().unwrap_or(0.0),
            _ => 0.0,
        }
    }

    fn integer(&self, row: &[Value], name: &str) -> i64 {
        match self.index(name).and_then(|i| row.get(i)) {
            Some(Value::Integer(n)) => *n,
            Some(Value::Real(f)) => *f as i64,
            Some(Value::Text(text)) => text.parse::<i64>().unwrap_or(0),
            _ => 0,
        }
    }

    fn tags(&self, row: &[Value], name: &str) -> Vec<String> {
        let raw = self.text(row, name);
        serde_json::from_str::<Vec<String>>(&raw).unwrap_or_default()
    }

    fn first(&self) -> Option<&Vec<Value>> {
        self.rows.first()
    }
}

/// `content_sha256`, byte for byte what `host.sha256(content)` returns: the dedupe key the unique
/// index is built on, so the two paths must agree or one fact would be stored twice.
fn content_digest(content: &str) -> String {
    let digest = Sha256::digest(content.as_bytes());
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A fresh id in the shape the native path mints (`host.uuid()`), so a caller storing both ways never
/// sees two formats in one store.
///
/// The bytes are a digest of the fact plus the clock plus a process-local counter: an id only has to
/// be unique, and the store's PRIMARY KEY is what refuses a repeat — visibly, instead of silently
/// overwriting. `nanos` is taken from the system clock, which the guest may read through WASI.
fn fresh_id(scope: &str, content: &str) -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tick = COUNTER.fetch_add(1, Ordering::Relaxed);
    let digest = Sha256::digest(format!("wa:memory.v1\0{scope}\0{content}\0{nanos}\0{tick}").as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32])
}

fn guest_scope(scope: &str) -> bool {
    scope.len() >= 5 && &scope[..5] == "user:"
}

/// The scope clause the native `query_memories` applies, and its parameters.
fn scope_clause(scope: Option<&str>, exclusive: bool) -> (&'static str, Vec<String>) {
    match scope {
        Some(scope) if exclusive => (" AND m.scope=?", vec![scope.to_string()]),
        Some(scope) => (" AND (m.scope=? OR m.scope='global')", vec![scope.to_string()]),
        // An unscoped recall (a master's default) leaves out guests' own scopes: what a guest stored
        // is that guest's text, and surfacing it in a master's context would let a guest plant
        // instructions.
        None => (" AND m.scope NOT LIKE 'user:%'", Vec::new()),
    }
}

const RECALL_COLUMNS: &str = "m.id,m.scope,m.content,m.tags,m.source,m.created_at,m.updated_at,\
                              bm25(memories_fts) AS rank";

fn memory_of(answer: &Answer, row: &[Value]) -> Memory {
    Memory {
        id: answer.text(row, "id"),
        scope: answer.text(row, "scope"),
        content: answer.text(row, "content"),
        tags: answer.tags(row, "tags"),
        source: answer.text(row, "source"),
        created_at: answer.real(row, "created_at"),
        updated_at: answer.real(row, "updated_at"),
        rank: answer.real(row, "rank"),
    }
}

/// One recall pass: bm25 (lower is better) with a small bonus for recent rows, so of two equally
/// relevant facts the newer one — usually the correction — comes first.
fn recall_pass(match_expression: &str, limit: u32, scope: Option<&str>, exclusive: bool) -> Result<Vec<Memory>, MError> {
    let (clause, mut values) = scope_clause(scope, exclusive);
    let mut params = vec![Value::Text(match_expression.to_string())];
    params.extend(values.drain(..).map(Value::Text));
    params.push(Value::Real(now()));
    params.push(Value::Integer(i64::from(limit)));
    let sql = format!(
        "SELECT {RECALL_COLUMNS} FROM memories_fts \
         JOIN memories m ON m.id=memories_fts.memory_id \
         WHERE memories_fts MATCH ? AND m.deleted_at IS NULL{clause} \
         ORDER BY rank - 1.0 / (1.0 + (? - m.updated_at) / {RECENCY_WINDOW}) LIMIT ?"
    );
    let answer = query(&sql, &params)?;
    Ok(answer.rows.iter().map(|row| memory_of(&answer, row)).collect())
}

// ------------------------------------------------------------------------------------------ the seam

impl Guest for MemoryComponent {
    fn remember(content: String, scope: Option<String>, tags: Vec<String>, id: Option<String>) -> Result<Remembered, MError> {
        if content.is_empty() {
            return Err(MError::Invalid("memory_empty".into()));
        }
        if content.len() > MAX_CONTENT {
            return Err(MError::Invalid("memory_too_large".into()));
        }
        let scope = scope.unwrap_or_else(|| "global".to_string());
        let tags_json = serde_json::to_string(&tags).unwrap_or_else(|_| "[]".into());
        // One unit: the row and its search entry. BEGIN IMMEDIATE takes the write lock before the
        // duplicate check, so a crash cannot leave a fact recall could never find.
        exec("BEGIN IMMEDIATE", &[])?;
        let outcome = remember_in_transaction(&content, &scope, &tags, &tags_json, id);
        match outcome {
            Ok(remembered) => {
                exec("COMMIT", &[])?;
                Ok(remembered)
            }
            Err(error) => {
                // The refusal must not leave a transaction behind: the connection is dropped at the
                // end of the call, but a peer statement in the same call would see it.
                let _ = exec("ROLLBACK", &[]);
                Err(error)
            }
        }
    }

    fn recall(text: String, limit: u32, scope: Option<String>, exclusive: bool) -> Result<Vec<Memory>, MError> {
        let passes = logic::recall_passes(&text);
        if passes.is_empty() {
            return Ok(Vec::new());
        }
        let mut rows = recall_pass(&passes[0], limit, scope.as_deref(), exclusive)?;
        if rows.is_empty() {
            if let Some(second) = passes.get(1) {
                // Any-term matching, minus one-letter words: requiring every term is the precise
                // case, and a conversational question shares no complete term set with the note it
                // is about — returning nothing there is what once made the agent say the store was
                // empty while the fact was sitting in it.
                rows = recall_pass(second, limit, scope.as_deref(), exclusive)?;
            }
        }
        Ok(rows)
    }

    fn forget(id: String) -> Result<Forgotten, MError> {
        let stamp = now();
        exec("BEGIN IMMEDIATE", &[])?;
        let outcome = (|| -> Result<Forgotten, MError> {
            let changed = exec(
                "UPDATE memories SET deleted_at=?, updated_at=? WHERE id=? AND deleted_at IS NULL",
                &[Value::Real(stamp), Value::Real(stamp), Value::Text(id.clone())],
            )?;
            if changed.changes > 0 {
                exec("DELETE FROM memories_fts WHERE memory_id=?", &[Value::Text(id)])?;
            }
            Ok(Forgotten { retired: changed.changes > 0, deleted_at: stamp })
        })();
        match outcome {
            Ok(forgotten) => {
                exec("COMMIT", &[])?;
                Ok(forgotten)
            }
            Err(error) => {
                let _ = exec("ROLLBACK", &[]);
                Err(error)
            }
        }
    }

    fn list(scope: Option<String>, limit: u32) -> Result<Vec<Memory>, MError> {
        let mut sql = String::from(
            "SELECT id,scope,content,tags,source,created_at,updated_at FROM memories WHERE deleted_at IS NULL",
        );
        let mut params: Vec<Value> = Vec::new();
        if let Some(scope) = scope {
            sql.push_str(" AND scope=?");
            params.push(Value::Text(scope));
        }
        sql.push_str(" ORDER BY updated_at DESC LIMIT ?");
        params.push(Value::Integer(i64::from(limit)));
        let answer = query(&sql, &params)?;
        Ok(answer.rows.iter().map(|row| memory_of(&answer, row)).collect())
    }

    fn search_messages(text: String, user_id: Option<String>, limit: u32) -> Result<Vec<MessageHit>, MError> {
        let match_expression = logic::fts_query(&text);
        if match_expression.is_empty() {
            return Ok(Vec::new());
        }
        let mut sql = String::from(
            "SELECT t.id,t.session_id,t.seq,t.role,t.content,t.tool_name,t.ok,t.created_at,\
             s.user_id,s.title,bm25(messages_fts) AS rank \
             FROM messages_fts JOIN messages t ON t.id=messages_fts.message_id \
             JOIN sessions s ON s.id=t.session_id WHERE messages_fts MATCH ?",
        );
        let mut params = vec![Value::Text(match_expression)];
        if let Some(user_id) = user_id.filter(|value| !value.is_empty()) {
            sql.push_str(" AND s.user_id=?");
            params.push(Value::Text(user_id));
        }
        sql.push_str(" ORDER BY rank LIMIT ?");
        params.push(Value::Integer(i64::from(limit)));
        let answer = query(&sql, &params)?;
        Ok(answer
            .rows
            .iter()
            .map(|row| MessageHit {
                id: answer.text(row, "id"),
                session_id: answer.text(row, "session_id"),
                seq: answer.integer(row, "seq").max(0) as u64,
                role: answer.text(row, "role"),
                content: answer.text(row, "content"),
                tool_name: answer.text(row, "tool_name"),
                ok: answer.integer(row, "ok") != 0,
                created_at: answer.real(row, "created_at"),
                user_id: answer.text(row, "user_id"),
                title: answer.text(row, "title"),
                rank: answer.real(row, "rank"),
            })
            .collect())
    }

    fn sessions(user_id: Option<String>, limit: u32, states: bool) -> Result<Vec<Session>, MError> {
        // The last message per thread, in the same query: one row per thread, no N+1.
        let mut sql = String::from(
            "SELECT s.id,s.user_id,s.node_id,s.route_id,s.objective,s.title,s.parent_session_id,\
             s.started_at,s.ended_at,s.updated_at,\
             (SELECT COUNT(*) FROM messages t WHERE t.session_id=s.id) AS message_count",
        );
        if states {
            sql.push_str(
                ", l.role AS last_role, l.ok AS last_ok, l.phase AS last_phase, \
                 l.tool_calls AS last_tool_calls, l.created_at AS last_at, l.seq AS last_seq, \
                 CASE WHEN l.role='assistant' AND l.ok=0 THEN l.trace ELSE '[]' END AS last_trace",
            );
        }
        sql.push_str(" FROM sessions s");
        if states {
            sql.push_str(
                " LEFT JOIN messages l ON l.session_id=s.id \
                  AND l.seq=(SELECT MAX(seq) FROM messages WHERE session_id=s.id)",
            );
        }
        let mut params: Vec<Value> = Vec::new();
        if let Some(user_id) = user_id.filter(|value| !value.is_empty()) {
            sql.push_str(" WHERE s.user_id=?");
            params.push(Value::Text(user_id));
        }
        sql.push_str(" ORDER BY s.updated_at DESC LIMIT ?");
        params.push(Value::Integer(i64::from(limit)));
        let answer = query(&sql, &params)?;
        Ok(answer
            .rows
            .iter()
            .map(|row| {
                let last = if states && answer.integer(row, "last_seq") != 0 {
                    Some(logic::LastMessage {
                        role: answer.text(row, "last_role"),
                        ok: Some(answer.integer(row, "last_ok")),
                        phase: answer.optional_text(row, "last_phase"),
                        tool_calls: answer.optional_text(row, "last_tool_calls"),
                    })
                } else {
                    None
                };
                let state = if states { logic::classify(last.as_ref()).to_string() } else { String::new() };
                let failed_trace = last
                    .as_ref()
                    .and_then(|_| answer.optional_text(row, "last_trace"))
                    .filter(|trace| trace != "[]");
                Session {
                    id: answer.text(row, "id"),
                    user_id: answer.text(row, "user_id"),
                    node_id: answer.text(row, "node_id"),
                    route_id: answer.text(row, "route_id"),
                    objective: answer.text(row, "objective"),
                    title: answer.text(row, "title"),
                    parent_session_id: answer.optional_text(row, "parent_session_id"),
                    started_at: answer.real(row, "started_at"),
                    ended_at: answer.optional_text(row, "ended_at").map(|_| answer.real(row, "ended_at")),
                    updated_at: answer.real(row, "updated_at"),
                    message_count: answer.integer(row, "message_count").max(0) as u64,
                    state,
                    last_role: last.as_ref().map(|last| last.role.clone()),
                    last_ok: last.as_ref().and_then(|last| last.ok),
                    last_phase: last.as_ref().and_then(|last| last.phase.clone()),
                    last_tool_calls: last.as_ref().and_then(|last| last.tool_calls.clone()),
                    last_at: last.as_ref().map(|_| answer.real(row, "last_at")),
                    last_trace: failed_trace,
                }
            })
            .collect())
    }

    fn retention(older_than_seconds: f64) -> Result<RetentionPlan, MError> {
        // What a sweep would take, never a deletion: the decision itself is the component's policy
        // and it refuses (docs/MEMORY.md, "Retention").
        let cutoff = now() - older_than_seconds.max(0.0);
        let answer = query(
            "SELECT COUNT(*) AS n FROM memories WHERE deleted_at IS NOT NULL AND deleted_at < ?",
            &[Value::Real(cutoff)],
        )?;
        let forgotten = answer.first().map(|row| answer.integer(row, "n")).unwrap_or(0).max(0) as u64;
        let decision = logic::retention(now(), older_than_seconds, forgotten);
        Ok(RetentionPlan { refused: decision.refused, eligible: decision.eligible })
    }
}

fn remember_in_transaction(
    content: &str,
    scope: &str,
    tags: &[String],
    tags_json: &str,
    id: Option<String>,
) -> Result<Remembered, MError> {
    let hash = content_digest(content);
    if let Some(id) = id {
        if id.is_empty() {
            return Err(MError::Invalid("memory_id_required".into()));
        }
        let existing = query(
            "SELECT scope,content,tags,created_at FROM memories WHERE id=? AND deleted_at IS NULL",
            &[Value::Text(id.clone())],
        )?;
        let Some(row) = existing.first() else {
            return Err(MError::NotFound);
        };
        let stored_scope = existing.text(row, "scope");
        // A guest's scope is a boundary, not a default: a replace may not name another guest's row.
        if guest_scope(scope) && stored_scope != scope {
            return Err(MError::NotFound);
        }
        let stored_content = existing.text(row, "content");
        let stored_tags = existing.tags(row, "tags");
        let created_at = existing.real(row, "created_at");
        // Re-storing the identical text is a no-op, not churn: no write, no new updated_at.
        if stored_content == content && stored_tags == tags {
            return Ok(Remembered {
                id: id.clone(),
                scope: stored_scope,
                content: stored_content,
                tags: stored_tags,
                source: "user".into(),
                created_at,
                updated_at: now(),
                content_sha256: hash,
                written: false,
            });
        }
        let stamp = now();
        exec(
            "UPDATE memories SET content=?, tags=?, content_sha256=?, updated_at=? WHERE id=? AND deleted_at IS NULL",
            &[
                Value::Text(content.to_string()),
                Value::Text(tags_json.to_string()),
                Value::Text(hash.clone()),
                Value::Real(stamp),
                Value::Text(id.clone()),
            ],
        )?;
        exec("DELETE FROM memories_fts WHERE memory_id=?", &[Value::Text(id.clone())])?;
        exec(
            "INSERT INTO memories_fts(content,tags,memory_id) VALUES(?,?,?)",
            &[Value::Text(content.to_string()), Value::Text(tags.join(" ")), Value::Text(id.clone())],
        )?;
        // The scope stays the entry's own: a caller's default scope (or a guest's bounded one) is not
        // permission to move a fact out of the scope that owns it.
        return Ok(Remembered {
            id,
            scope: stored_scope,
            content: content.to_string(),
            tags: tags.to_vec(),
            source: "user".into(),
            created_at,
            updated_at: stamp,
            content_sha256: hash,
            written: true,
        });
    }
    let duplicate = query(
        "SELECT id FROM memories WHERE scope=? AND content_sha256=? AND deleted_at IS NULL LIMIT 1",
        &[Value::Text(scope.to_string()), Value::Text(hash.clone())],
    )?;
    if let Some(row) = duplicate.first() {
        let id = duplicate.text(row, "id");
        let stamp = now();
        return Ok(Remembered {
            id: id.clone(),
            scope: scope.to_string(),
            content: content.to_string(),
            tags: tags.to_vec(),
            source: "user".into(),
            created_at: stamp,
            updated_at: stamp,
            content_sha256: hash,
            written: false,
        });
    }
    if guest_scope(scope) {
        // A guest's scope is bounded, so one caller cannot fill the shared database.
        let held = query(
            "SELECT COUNT(*) AS n FROM memories WHERE scope=? AND deleted_at IS NULL",
            &[Value::Text(scope.to_string())],
        )?;
        let count = held.first().map(|row| held.integer(row, "n")).unwrap_or(0);
        if count >= MAX_PER_GUEST_SCOPE {
            return Err(MError::Invalid("memory_scope_full".into()));
        }
    }
    let id = fresh_id(scope, content);
    let stamp = now();
    exec(
        "INSERT INTO memories(id,scope,content,tags,source,session_id,created_at,updated_at,content_sha256) \
         VALUES(?,?,?,?,?,?,?,?,?)",
        &[
            Value::Text(id.clone()),
            Value::Text(scope.to_string()),
            Value::Text(content.to_string()),
            Value::Text(tags_json.to_string()),
            Value::Text("user".into()),
            Value::Text(String::new()),
            Value::Real(stamp),
            Value::Real(stamp),
            Value::Text(hash.clone()),
        ],
    )?;
    exec(
        "INSERT INTO memories_fts(content,tags,memory_id) VALUES(?,?,?)",
        &[Value::Text(content.to_string()), Value::Text(tags.join(" ")), Value::Text(id.clone())],
    )?;
    Ok(Remembered {
        id,
        scope: scope.to_string(),
        content: content.to_string(),
        tags: tags.to_vec(),
        source: "user".into(),
        created_at: stamp,
        updated_at: stamp,
        content_sha256: hash,
        written: true,
    })
}

export!(MemoryComponent);
