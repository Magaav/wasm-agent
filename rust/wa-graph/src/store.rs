//! The graph store: SQLite tables for files, nodes, and edges, plus the query verbs.
//!
//! Same store the node already uses (SQLite), so this is not a new dependency on disk — it is a
//! second database file the agent can query with SQL if it wants. Incremental by content hash:
//! a file whose bytes did not change is never reparsed.

use crate::extract::{self, Extract};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

pub struct Store {
    conn: Connection,
}

#[derive(Debug, Clone)]
pub struct NodeRow {
    pub id: i64,
    pub kind: String,
    pub name: String,
    pub path: String,
    pub line: i64,
    pub col: i64,
    pub lang: String,
    pub detail: Option<String>,
}

#[derive(Debug, Clone)]
pub struct EdgeRow {
    pub kind: String,
    pub target: String,
    pub path: String,
    pub line: i64,
    pub dst: Option<i64>,
    pub dst_name: Option<String>,
    pub dst_path: Option<String>,
    pub dst_line: Option<i64>,
}

#[derive(Debug, Default, Clone)]
pub struct Stats {
    pub files: i64,
    pub nodes: i64,
    pub edges: i64,
    pub resolved: i64,
    pub unresolved: i64,
    pub by_kind: Vec<(String, i64)>,
}

#[derive(Debug, Default)]
pub struct IndexReport {
    pub indexed: usize,
    pub unchanged: usize,
    pub removed: usize,
    pub nodes: usize,
    pub edges: usize,
    pub resolved: usize,
    pub unresolved: usize,
}

impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let conn = Connection::open(path)?;
        conn.busy_timeout(std::time::Duration::from_secs(10))?;
        let _ = conn.pragma_update(None, "journal_mode", "WAL");
        let store = Self { conn };
        store.init()?;
        Ok(store)
    }

    /// Open an existing graph without creating or migrating it. A reader never takes the write
    /// lock, so the node can query while the watcher reindexes.
    pub fn open_readonly(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open_with_flags(
            path.as_ref(),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        Ok(Self { conn })
    }

    fn init(&self) -> Result<()> {
        self.conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS files(
              path TEXT PRIMARY KEY, lang TEXT NOT NULL, hash TEXT NOT NULL,
              mtime INTEGER NOT NULL, size INTEGER NOT NULL, indexed_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS nodes(
              id INTEGER PRIMARY KEY,
              kind TEXT NOT NULL, name TEXT NOT NULL, path TEXT NOT NULL,
              line INTEGER NOT NULL, col INTEGER NOT NULL, lang TEXT NOT NULL, detail TEXT);
            CREATE TABLE IF NOT EXISTS edges(
              id INTEGER PRIMARY KEY,
              src INTEGER NOT NULL, kind TEXT NOT NULL, target TEXT NOT NULL,
              path TEXT NOT NULL, line INTEGER NOT NULL, col INTEGER NOT NULL, dst INTEGER);
            CREATE TABLE IF NOT EXISTS imports(
              alias TEXT NOT NULL, module TEXT NOT NULL, path TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS idx_nodes_name ON nodes(name);
            CREATE INDEX IF NOT EXISTS idx_nodes_path ON nodes(path);
            CREATE INDEX IF NOT EXISTS idx_edges_src ON edges(src);
            CREATE INDEX IF NOT EXISTS idx_edges_dst ON edges(dst);
            CREATE INDEX IF NOT EXISTS idx_edges_target ON edges(target);
            CREATE INDEX IF NOT EXISTS idx_edges_path ON edges(path);
            "#,
        )?;
        Ok(())
    }

    /// Index a directory tree. Only changed files are reparsed; removed files are dropped.
    ///
    /// The whole run is one `BEGIN IMMEDIATE` transaction. A reader sees the old graph or the new
    /// one, never a half-indexed file; taking the write lock up front stops the watcher and a manual
    /// `host.graph_index` from interleaving, and stops two deferred writers deadlocking on the
    /// upgrade. Readers are unaffected (WAL): they keep the previous snapshot until this commits.
    pub fn index(&mut self, root: &Path, force: bool) -> Result<IndexReport> {
        self.conn.execute_batch("BEGIN IMMEDIATE")?;
        match self.index_inner(root, force) {
            Ok(report) => {
                self.conn.execute_batch("COMMIT")?;
                Ok(report)
            }
            Err(error) => {
                let _ = self.conn.execute_batch("ROLLBACK");
                Err(error)
            }
        }
    }

    fn index_inner(&self, root: &Path, force: bool) -> Result<IndexReport> {
        let mut report = IndexReport::default();
        let mut seen: Vec<String> = Vec::new();
        let files = collect_files(root)?;
        for abs in files {
            let rel = relative(root, &abs);
            let lang = match extract::language_for(&rel) {
                Some(l) => l,
                None => continue,
            };
            let source = match std::fs::read_to_string(&abs) {
                Ok(s) => s,
                Err(_) => continue, // binary or unreadable: not ours
            };
            let meta = std::fs::metadata(&abs).ok();
            let mtime = meta
                .as_ref()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            let size = source.len() as i64;
            let hash = fnv1a(source.as_bytes());
            seen.push(rel.clone());

            if !force {
                if let Some((old_hash, old_mtime, old_size)) = self.file_stamp(&rel)? {
                    if old_hash == hash && old_mtime == mtime && old_size == size {
                        report.unchanged += 1;
                        continue;
                    }
                }
            }

            self.remove_file(&rel)?;
            let ex = extract::extract(&rel, lang, &source);
            self.insert_extract(&rel, lang, &ex, hash, mtime, size)?;
            report.indexed += 1;
            report.nodes += ex.nodes.len();
            report.edges += ex.edges.len();
        }

        // Anything recorded but no longer present is removed.
        for rel in self.all_file_paths()? {
            if !seen.contains(&rel) {
                self.remove_file(&rel)?;
                report.removed += 1;
            }
        }

        let (resolved, unresolved) = self.resolve()?;
        report.resolved = resolved;
        report.unresolved = unresolved;
        Ok(report)
    }

    fn file_stamp(&self, path: &str) -> Result<Option<(String, i64, i64)>> {
        let row = self
            .conn
            .query_row(
                "SELECT hash, mtime, size FROM files WHERE path=?1",
                params![path],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        Ok(row)
    }

    fn all_file_paths(&self) -> Result<Vec<String>> {
        let mut stmt = self.conn.prepare("SELECT path FROM files")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    fn remove_file(&self, path: &str) -> Result<()> {
        // Incoming edges to this file's nodes lose their target; they are re-resolved at the end.
        self.conn.execute(
            "UPDATE edges SET dst=NULL WHERE dst IN (SELECT id FROM nodes WHERE path=?1)",
            params![path],
        )?;
        self.conn
            .execute("DELETE FROM nodes WHERE path=?1", params![path])?;
        self.conn
            .execute("DELETE FROM edges WHERE path=?1", params![path])?;
        self.conn
            .execute("DELETE FROM imports WHERE path=?1", params![path])?;
        self.conn
            .execute("DELETE FROM files WHERE path=?1", params![path])?;
        Ok(())
    }

    fn insert_extract(
        &self,
        path: &str,
        lang: &str,
        ex: &Extract,
        hash: String,
        mtime: i64,
        size: i64,
    ) -> Result<()> {
        let now = now_secs();
        {
            let mut insert_node = self.conn.prepare(
                "INSERT INTO nodes(kind,name,path,line,col,lang,detail) VALUES(?1,?2,?3,?4,?5,?6,?7)",
            )?;
            for n in &ex.nodes {
                insert_node.execute(params![
                    n.kind,
                    n.name,
                    path,
                    n.line as i64,
                    n.col as i64,
                    lang,
                    n.detail
                ])?;
            }
            let rowids: Vec<i64> = {
                let mut stmt = self
                    .conn
                    .prepare("SELECT id FROM nodes WHERE path=?1 ORDER BY id")?;
                let rows = stmt.query_map(params![path], |r| r.get::<_, i64>(0))?;
                rows.collect::<std::result::Result<_, _>>()?
            };
            let mut insert_edge = self.conn.prepare(
                "INSERT INTO edges(src,kind,target,path,line,col,dst) VALUES(?1,?2,?3,?4,?5,?6,NULL)",
            )?;
            for e in &ex.edges {
                let src = rowids
                    .get(e.src)
                    .copied()
                    .unwrap_or_else(|| rowids.first().copied().unwrap_or(0));
                insert_edge.execute(params![
                    src,
                    e.kind,
                    e.target,
                    path,
                    e.line as i64,
                    e.col as i64
                ])?;
            }
            let mut insert_import = self
                .conn
                .prepare("INSERT INTO imports(alias,module,path) VALUES(?1,?2,?3)")?;
            for imp in &ex.imports {
                insert_import.execute(params![imp.alias, imp.module, path])?;
            }
            self.conn.execute(
                "INSERT OR REPLACE INTO files(path,lang,hash,mtime,size,indexed_at) VALUES(?1,?2,?3,?4,?5,?6)",
                params![path, lang, hash, mtime, size, now],
            )?;
        }
        Ok(())
    }

    /// Turn every unresolved edge's target name into a node id. Same-file beats same-directory
    /// beats globally-unique. A `host.*` reference with no definition becomes a capability node.
    fn resolve(&self) -> Result<(usize, usize)> {
        let pending: Vec<(i64, String, String, String)> = {
            let mut stmt = self
                .conn
                .prepare("SELECT id, target, path, kind FROM edges WHERE dst IS NULL")?;
            let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?;
            rows.collect::<std::result::Result<_, _>>()?
        };
        let mut resolved = 0usize;
        for (edge_id, target, path, kind) in &pending {
            let simple = extract::simple_name(target);
            let hit = pick_candidate(&self.conn, target, simple, path)?;
            let dst = match hit {
                Some(id) => Some(id),
                None if kind == "capability" && extract::is_capability(target) => {
                    Some(ensure_capability(&self.conn, target)?)
                }
                // `memory.append_turn` where `local memory = require('core.memory')` names the
                // module's `M.append_turn`. Resolve through the require alias.
                None if kind == "calls" => resolve_alias(&self.conn, target, path)?,
                None => None,
            };
            if let Some(id) = dst {
                self.conn
                    .execute("UPDATE edges SET dst=?1 WHERE id=?2", params![id, edge_id])?;
                resolved += 1;
            } else if kind == "mentions" {
                // A doc mention that names no real definition is noise; keep the graph clean.
                self.conn
                    .execute("DELETE FROM edges WHERE id=?1", params![edge_id])?;
            }
        }
        let unresolved: i64 =
            self.conn
                .query_row("SELECT COUNT(*) FROM edges WHERE dst IS NULL", [], |r| {
                    r.get(0)
                })?;
        Ok((resolved, unresolved as usize))
    }

    pub fn explain(&self, name: &str) -> Result<Vec<(NodeRow, Vec<EdgeRow>, Vec<EdgeRow>)>> {
        let defs = self.find_nodes(name, 25)?;
        let mut out = Vec::new();
        for n in defs {
            let outgoing = self.outgoing(n.id)?;
            let incoming = self.incoming(n.id)?;
            out.push((n, outgoing, incoming));
        }
        Ok(out)
    }

    fn find_nodes(&self, name: &str, limit: i64) -> Result<Vec<NodeRow>> {
        let like = format!("%{name}%");
        let mut stmt = self.conn.prepare(
            "SELECT id,kind,name,path,line,col,lang,detail FROM nodes
             WHERE name=?1 OR name LIKE ?2 ORDER BY (name=?1) DESC, path, line LIMIT ?3",
        )?;
        let rows = stmt.query_map(params![name, like, limit], row_to_node)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    fn outgoing(&self, id: i64) -> Result<Vec<EdgeRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT e.kind, e.target, e.path, e.line, e.dst,
                    n.name, n.path, n.line
             FROM edges e LEFT JOIN nodes n ON n.id = e.dst
             WHERE e.src=?1 ORDER BY e.line",
        )?;
        let rows = stmt.query_map(params![id], row_to_edge)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    fn incoming(&self, id: i64) -> Result<Vec<EdgeRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT e.kind, e.target, e.path, e.line, e.src,
                    s.name, s.path, s.line
             FROM edges e JOIN nodes s ON s.id = e.src
             WHERE e.dst=?1 ORDER BY e.path, e.line",
        )?;
        let rows = stmt.query_map(params![id], row_to_edge)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    /// Breadth-first path between two named nodes over resolved edges, in either direction.
    pub fn path(&self, from: &str, to: &str) -> Result<Option<Vec<(NodeRow, String)>>> {
        let starts = self.find_nodes(from, 5)?;
        let goals: std::collections::HashSet<i64> =
            self.find_nodes(to, 5)?.into_iter().map(|n| n.id).collect();
        if starts.is_empty() || goals.is_empty() {
            return Ok(None);
        }
        let mut visited: std::collections::HashMap<i64, (Option<i64>, String)> =
            std::collections::HashMap::new();
        let mut queue: std::collections::VecDeque<i64> = std::collections::VecDeque::new();
        for s in &starts {
            visited.insert(s.id, (None, String::new()));
            queue.push_back(s.id);
        }
        let mut found: Option<i64> = None;
        while let Some(id) = queue.pop_front() {
            if goals.contains(&id) && !starts.iter().any(|s| s.id == id) {
                found = Some(id);
                break;
            }
            for (next, label) in self.neighbors(id)? {
                if !visited.contains_key(&next) {
                    visited.insert(next, (Some(id), label));
                    queue.push_back(next);
                }
            }
        }
        let Some(mut cur) = found else {
            return Ok(None);
        };
        let mut chain = Vec::new();
        loop {
            let node = self.node_by_id(cur)?.ok_or("node vanished")?;
            let (prev, label) = visited.get(&cur).cloned().unwrap_or((None, String::new()));
            chain.push((node, label));
            match prev {
                Some(p) => cur = p,
                None => break,
            }
        }
        chain.reverse();
        Ok(Some(chain))
    }

    fn neighbors(&self, id: i64) -> Result<Vec<(i64, String)>> {
        // Doc mentions are for lookup, not traversal: following them makes every `path` hop
        // through prose and lands on a coincidence.
        let mut stmt = self.conn.prepare(
            "SELECT dst, kind, target FROM edges WHERE src=?1 AND dst IS NOT NULL AND kind<>'mentions'
             UNION
             SELECT src, kind, target FROM edges WHERE dst=?1 AND kind<>'mentions'",
        )?;
        let rows = stmt.query_map(params![id], |r| {
            let other: i64 = r.get(0)?;
            let kind: String = r.get(1)?;
            let target: String = r.get(2)?;
            Ok((other, format!("{kind} {target}")))
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    fn node_by_id(&self, id: i64) -> Result<Option<NodeRow>> {
        let row = self
            .conn
            .query_row(
                "SELECT id,kind,name,path,line,col,lang,detail FROM nodes WHERE id=?1",
                params![id],
                row_to_node,
            )
            .optional()?;
        Ok(row)
    }

    pub fn query(&self, text: &str, limit: i64) -> Result<Vec<NodeRow>> {
        let like = format!("%{text}%");
        let mut stmt = self.conn.prepare(
            "SELECT DISTINCT n.id,n.kind,n.name,n.path,n.line,n.col,n.lang,n.detail
             FROM nodes n LEFT JOIN edges e ON e.dst=n.id
             WHERE n.name LIKE ?1 OR n.path LIKE ?1 OR n.detail LIKE ?1 OR e.target LIKE ?1
             ORDER BY n.path, n.line LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![like, limit], row_to_node)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn stats(&self) -> Result<Stats> {
        let mut s = Stats::default();
        s.files = self
            .conn
            .query_row("SELECT COUNT(*) FROM files", [], |r| r.get(0))?;
        s.nodes = self
            .conn
            .query_row("SELECT COUNT(*) FROM nodes", [], |r| r.get(0))?;
        s.edges = self
            .conn
            .query_row("SELECT COUNT(*) FROM edges", [], |r| r.get(0))?;
        s.resolved = self.conn.query_row(
            "SELECT COUNT(*) FROM edges WHERE dst IS NOT NULL",
            [],
            |r| r.get(0),
        )?;
        s.unresolved = s.edges - s.resolved;
        let mut stmt = self
            .conn
            .prepare("SELECT kind, COUNT(*) FROM nodes GROUP BY kind ORDER BY COUNT(*) DESC")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        s.by_kind = rows.collect::<std::result::Result<_, _>>()?;
        Ok(s)
    }

    pub fn capabilities(&self) -> Result<Vec<(String, i64)>> {
        let mut stmt = self.conn.prepare(
            "SELECT n.name, COUNT(e.id) FROM nodes n LEFT JOIN edges e ON e.dst=n.id
             WHERE n.kind='capability' GROUP BY n.name ORDER BY COUNT(e.id) DESC, n.name",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    /// `explain` as a JSON value: one entry per matching definition.
    pub fn explain_json(&self, name: &str) -> Result<Value> {
        let rows = self.explain(name)?;
        Ok(Value::Array(
            rows.into_iter()
                .map(|(node, outgoing, incoming)| {
                    json!({
                        "node": node.to_json(),
                        "outgoing": outgoing.iter().map(EdgeRow::to_json).collect::<Vec<_>>(),
                        "incoming": incoming.iter().map(EdgeRow::to_json).collect::<Vec<_>>(),
                    })
                })
                .collect(),
        ))
    }

    /// `path` as a JSON value: `{found, steps}` where each step carries the edge that reached it.
    pub fn path_json(&self, from: &str, to: &str) -> Result<Value> {
        Ok(match self.path(from, to)? {
            Some(chain) => json!({
                "found": true,
                "steps": chain
                    .into_iter()
                    .map(|(node, via)| {
                        let mut value = node.to_json();
                        value["via"] = json!(via);
                        value
                    })
                    .collect::<Vec<_>>(),
            }),
            None => json!({ "found": false, "steps": [] }),
        })
    }

    pub fn caps_json(&self) -> Result<Value> {
        Ok(Value::Array(
            self.capabilities()?
                .into_iter()
                .map(|(capability, uses)| json!({"capability": capability, "uses": uses}))
                .collect(),
        ))
    }

    pub fn query_json(&self, text: &str, limit: i64) -> Result<Value> {
        Ok(Value::Array(
            self.query(text, limit)?
                .iter()
                .map(NodeRow::to_json)
                .collect(),
        ))
    }
}

fn pick_candidate(
    conn: &Connection,
    target: &str,
    simple: &str,
    edge_path: &str,
) -> Result<Option<i64>> {
    // A dotted Lua definition keeps its table in the name (`M.append_turn`), so try the exact
    // target before falling back to the last segment (`append_turn`).
    for name in [target, simple] {
        let same_file: Option<i64> = conn
            .query_row(
                "SELECT id FROM nodes WHERE name=?1 AND path=?2 ORDER BY (kind!='fn') ASC, line LIMIT 1",
                params![name, edge_path],
                |r| r.get(0),
            )
            .optional()?;
        if same_file.is_some() {
            return Ok(same_file);
        }
    }
    let dir = edge_path.rsplit_once('/').map(|(d, _)| d).unwrap_or("");
    for name in [target, simple] {
        let same_dir: Option<i64> = conn
            .query_row(
                "SELECT id FROM nodes WHERE name=?1 AND path LIKE ?2 ORDER BY line LIMIT 1",
                params![name, format!("{dir}/%")],
                |r| r.get(0),
            )
            .optional()?;
        if same_dir.is_some() {
            return Ok(same_dir);
        }
    }
    for name in [target, simple] {
        let mut stmt = conn.prepare("SELECT id FROM nodes WHERE name=?1 LIMIT 2")?;
        let mut rows = stmt.query(params![name])?;
        let first = rows.next()?.map(|r| r.get::<_, i64>(0)).transpose()?;
        let second = rows.next()?.map(|r| r.get::<_, i64>(0)).transpose()?;
        if first.is_some() && second.is_none() {
            return Ok(first);
        }
    }
    Ok(None)
}

/// Resolve `alias.member` through a `require` binding: `memory.append_turn` in a file whose
/// `local memory = require('core.memory')` points at `lua/core/memory.lua`, where the definition
/// is `M.append_turn` (the module table's name, not the alias's).
fn resolve_alias(conn: &Connection, target: &str, edge_path: &str) -> Result<Option<i64>> {
    let Some((alias, _)) = target.split_once('.') else {
        return Ok(None);
    };
    if alias.is_empty() {
        return Ok(None);
    }
    let module: Option<String> = conn
        .query_row(
            "SELECT module FROM imports WHERE alias=?1 AND path=?2 LIMIT 1",
            params![alias, edge_path],
            |r| r.get(0),
        )
        .optional()?
        .or_else(|| {
            conn.query_row(
                "SELECT module FROM imports WHERE alias=?1 LIMIT 1",
                params![alias],
                |r| r.get(0),
            )
            .optional()
            .ok()
            .flatten()
        });
    let Some(module) = module else {
        return Ok(None);
    };
    let simple = extract::simple_name(target);
    let mod_path = format!("%{}.lua", module.replace('.', "/"));
    let dot_suffix = format!("%.{simple}");
    let hit: Option<i64> = conn
        .query_row(
            "SELECT id FROM nodes WHERE path LIKE ?1 AND (name=?2 OR name LIKE ?3)
             ORDER BY (name=?2) DESC, line LIMIT 1",
            params![mod_path, simple, dot_suffix],
            |r| r.get(0),
        )
        .optional()?;
    Ok(hit)
}

fn ensure_capability(conn: &Connection, name: &str) -> Result<i64> {
    if let Some(id) = conn
        .query_row(
            "SELECT id FROM nodes WHERE kind='capability' AND name=?1 LIMIT 1",
            params![name],
            |r| r.get::<_, i64>(0),
        )
        .optional()?
    {
        return Ok(id);
    }
    conn.execute(
        "INSERT INTO nodes(kind,name,path,line,col,lang,detail) VALUES('capability',?1,'<capability>',0,0,'','')",
        params![name],
    )?;
    Ok(conn.last_insert_rowid())
}

fn row_to_node(r: &rusqlite::Row) -> rusqlite::Result<NodeRow> {
    Ok(NodeRow {
        id: r.get(0)?,
        kind: r.get(1)?,
        name: r.get(2)?,
        path: r.get(3)?,
        line: r.get(4)?,
        col: r.get(5)?,
        lang: r.get(6)?,
        detail: r.get(7)?,
    })
}

fn row_to_edge(r: &rusqlite::Row) -> rusqlite::Result<EdgeRow> {
    Ok(EdgeRow {
        kind: r.get(0)?,
        target: r.get(1)?,
        path: r.get(2)?,
        line: r.get(3)?,
        dst: r.get(4)?,
        dst_name: r.get(5)?,
        dst_path: r.get(6)?,
        dst_line: r.get(7)?,
    })
}

impl NodeRow {
    pub fn to_json(&self) -> Value {
        json!({
            "kind": self.kind,
            "name": self.name,
            "path": self.path,
            "line": self.line,
            "col": self.col,
            "lang": self.lang,
            "detail": self.detail,
        })
    }
}

impl EdgeRow {
    pub fn to_json(&self) -> Value {
        json!({
            "kind": self.kind,
            "target": self.target,
            "path": self.path,
            "line": self.line,
            "resolved": self.dst.is_some(),
            "dst": self.dst_name,
            "dst_path": self.dst_path,
            "dst_line": self.dst_line,
        })
    }
}

impl Stats {
    pub fn to_json(&self) -> Value {
        let kinds: serde_json::Map<String, Value> = self
            .by_kind
            .iter()
            .map(|(kind, count)| (kind.clone(), json!(count)))
            .collect();
        json!({
            "files": self.files,
            "nodes": self.nodes,
            "edges": self.edges,
            "resolved": self.resolved,
            "unresolved": self.unresolved,
            "byKind": Value::Object(kinds),
        })
    }
}

/// Recursively collect indexable files, skipping build artifacts and VCS internals.
fn collect_files(root: &Path) -> Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = match std::fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if path.is_dir() {
                if matches!(
                    name.as_str(),
                    ".git"
                        | "target"
                        | "node_modules"
                        | ".wa-graph"
                        | "releases"
                        | ".orca-worktree-trash"
                ) {
                    continue;
                }
                stack.push(path);
            } else if extract::language_for(&name).is_some() {
                out.push(path);
            }
        }
    }
    out.sort();
    Ok(out)
}

fn relative(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// FNV-1a: a fast, dependency-free content hash. We only compare equality, not resist attacks.
pub fn fnv1a(bytes: &[u8]) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}
