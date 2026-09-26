//! The graph store: SQLite tables for files, nodes, and edges, plus the query verbs.
//!
//! Same store the node already uses (SQLite), so this is not a new dependency on disk — it is a
//! second database file the agent can query with SQL if it wants. Incremental by content hash:
//! a file whose bytes did not change is never reparsed.

use crate::extract::{self, Extract};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

// Include extraction semantics in file stamps. A new binary must reparse unchanged
// source after a graph upgrade; content-only stamps would leave old edges in place.
// Past both intents: main's "4" (change/graph-accuracy-followup) and this branch's "3"
// (change/graph-freshness) each changed what a source's stamp covers - the branch adds the
// `graph_sources` record of the exact bytes a generation was built from. A stamp written by either
// binary must therefore be re-parsed rather than trusted, and keeping either value would leave the
// other side's edges in place, which is the failure this constant exists to prevent.
const EXTRACT_VERSION: &str = "6";

pub struct Store {
    pub(crate) conn: Connection,
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
    pub resolution: String,
    pub confidence: i64,
}

#[derive(Debug, Clone)]
pub struct SearchHit {
    pub node: NodeRow,
    pub score: i64,
    pub confidence: &'static str,
    pub reason: &'static str,
    pub matched_terms: Vec<String>,
    pub unmatched_terms: Vec<String>,
    pub unmatched_definition_terms: Vec<String>,
    pub score_breakdown: BTreeMap<String, i64>,
}

#[derive(Debug, Clone)]
struct Resolved {
    id: i64,
    strategy: &'static str,
    confidence: i64,
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

    /// Pin a committed graph generation while the caller verifies and reads it.
    pub fn begin_read(&self) -> Result<()> {
        self.conn.execute_batch("BEGIN")?;
        Ok(())
    }

    pub fn end_read(&self) -> Result<()> {
        self.conn.execute_batch("COMMIT")?;
        Ok(())
    }

    /// Compare the complete target area with the exact bytes used to build this generation.
    /// A missed watcher event, changed file, unreadable file, or different root is not fresh.
    pub fn verify_snapshot(&self, root: &Path) -> Result<bool> {
        let has_tables: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('graph_meta','graph_sources')",
            [],
            |row| row.get(0),
        )?;
        if has_tables != 2 {
            return Ok(false);
        }
        let indexed_root: Option<String> = self
            .conn
            .query_row("SELECT value FROM graph_meta WHERE key='root'", [], |row| {
                row.get(0)
            })
            .optional()?;
        let actual_root = root.canonicalize()?.to_string_lossy().into_owned();
        if indexed_root.as_deref() != Some(actual_root.as_str()) {
            return Ok(false);
        }
        let mut sources = BTreeMap::new();
        let mut stmt = self.conn.prepare("SELECT path,source FROM graph_sources")?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?))
        })?;
        for row in rows {
            let (path, source) = row?;
            sources.insert(path, source);
        }
        let mut stamps = self.conn.prepare("SELECT path,hash FROM files")?;
        let rows = stamps.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        let mut file_count = 0;
        for row in rows {
            let (path, hash) = row?;
            let Some(source) = sources.get(&path) else {
                return Ok(false);
            };
            if hash != format!("{EXTRACT_VERSION}:{}", fnv1a(source)) {
                return Ok(false);
            }
            file_count += 1;
        }
        if file_count != sources.len() {
            return Ok(false);
        }
        for abs in collect_files(root)? {
            let rel = relative(root, &abs);
            let source = std::fs::read(&abs)?;
            if sources.remove(&rel).as_deref() != Some(source.as_slice()) {
                return Ok(false);
            }
        }
        Ok(sources.is_empty())
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
              path TEXT NOT NULL, line INTEGER NOT NULL, col INTEGER NOT NULL, dst INTEGER,
              resolution TEXT NOT NULL DEFAULT 'unresolved',
              confidence INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS imports(
              alias TEXT NOT NULL, module TEXT NOT NULL, path TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS graph_meta(
              key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS graph_sources(
              path TEXT PRIMARY KEY, source BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS idx_nodes_name ON nodes(name);
            CREATE INDEX IF NOT EXISTS idx_nodes_path ON nodes(path);
            CREATE INDEX IF NOT EXISTS idx_edges_src ON edges(src);
            CREATE INDEX IF NOT EXISTS idx_edges_dst ON edges(dst);
            CREATE INDEX IF NOT EXISTS idx_edges_target ON edges(target);
            CREATE INDEX IF NOT EXISTS idx_edges_path ON edges(path);
            "#,
        )?;
        ensure_column(
            &self.conn,
            "edges",
            "resolution",
            "TEXT NOT NULL DEFAULT 'unresolved'",
        )?;
        ensure_column(
            &self.conn,
            "edges",
            "confidence",
            "INTEGER NOT NULL DEFAULT 0",
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
        match self.index_inner(root, force).and_then(|report| {
            if self.verify_snapshot(root)? {
                Ok(report)
            } else {
                Err("graph_source_changed_during_index".into())
            }
        }) {
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
            let source = std::fs::read_to_string(&abs)?;
            let meta = std::fs::metadata(&abs).ok();
            let mtime = meta
                .as_ref()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            let size = source.len() as i64;
            let hash = format!("{EXTRACT_VERSION}:{}", fnv1a(source.as_bytes()));
            seen.push(rel.clone());

            if !force {
                if let Some((old_hash, old_mtime, old_size, old_source)) = self.file_stamp(&rel)? {
                    if old_hash == hash
                        && old_mtime == mtime
                        && old_size == size
                        && old_source == source.as_bytes()
                    {
                        report.unchanged += 1;
                        continue;
                    }
                }
            }

            self.remove_file(&rel)?;
            let ex = extract::extract(&rel, lang, &source);
            self.insert_extract(&rel, lang, &ex, hash, mtime, size, source.as_bytes())?;
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
        let generation = self.compute_generation()?;
        self.conn.execute(
            "INSERT OR REPLACE INTO graph_meta(key,value) VALUES('root',?1)",
            params![root.canonicalize()?.to_string_lossy().as_ref()],
        )?;
        self.conn.execute(
            "INSERT OR REPLACE INTO graph_meta(key,value) VALUES('generation',?1)",
            params![generation],
        )?;
        report.resolved = resolved;
        report.unresolved = unresolved;
        Ok(report)
    }

    fn compute_generation(&self) -> Result<String> {
        let mut stmt = self
            .conn
            .prepare("SELECT path,hash FROM files ORDER BY path")?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        let mut bytes = Vec::new();
        for row in rows {
            let (path, hash) = row?;
            bytes.extend_from_slice(path.as_bytes());
            bytes.push(0);
            bytes.extend_from_slice(hash.as_bytes());
            bytes.push(b'\n');
        }
        Ok(fnv1a(&bytes))
    }

    pub fn generation(&self) -> Result<String> {
        Ok(self
            .conn
            .query_row(
                "SELECT value FROM graph_meta WHERE key='generation'",
                [],
                |row| row.get(0),
            )
            .optional()?
            .unwrap_or_else(|| "unknown".to_string()))
    }

    fn file_stamp(&self, path: &str) -> Result<Option<(String, i64, i64, Vec<u8>)>> {
        let row = self
            .conn
            .query_row(
                "SELECT files.hash, files.mtime, files.size, graph_sources.source FROM files LEFT JOIN graph_sources USING(path) WHERE files.path=?1",
                params![path],
                |r| {
                    Ok((
                        r.get(0)?,
                        r.get(1)?,
                        r.get(2)?,
                        r.get::<_, Option<Vec<u8>>>(3)?.unwrap_or_default(),
                    ))
                },
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
            "UPDATE edges SET dst=NULL,resolution='unresolved',confidence=0
             WHERE dst IN (SELECT id FROM nodes WHERE path=?1)",
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
        self.conn
            .execute("DELETE FROM graph_sources WHERE path=?1", params![path])?;
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
        source: &[u8],
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
                "INSERT INTO edges(src,kind,target,path,line,col,dst,resolution,confidence)
                 VALUES(?1,?2,?3,?4,?5,?6,NULL,'unresolved',0)",
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
            self.conn.execute(
                "INSERT OR REPLACE INTO graph_sources(path,source) VALUES(?1,?2)",
                params![path, source],
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
            // A dotted call is `receiver.member`, and the receiver decides the resolution
            // (`resolve_dotted`). The one thing it must never do is guess a bare local that
            // shares `member`'s name: `provider.budget()` resolved to a local `budget` that way,
            // and the edge read as *resolved* while pointing at the wrong symbol.
            let hit = if kind == "capability" && extract::is_capability(target) {
                Some(Resolved {
                    id: ensure_capability(&self.conn, target)?,
                    strategy: "capability_exact",
                    confidence: 100,
                })
            } else if kind == "calls" && target.contains('.') {
                resolve_dotted(&self.conn, target, simple, path)?
            } else {
                pick_candidate(&self.conn, target, simple, path)?
            };
            if let Some(hit) = hit {
                self.conn.execute(
                    "UPDATE edges SET dst=?1,resolution=?2,confidence=?3 WHERE id=?4",
                    params![hit.id, hit.strategy, hit.confidence, edge_id],
                )?;
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
        let member = format!("%.{name}");
        let method = format!("%:{name}");
        let mut stmt = self.conn.prepare(
            "SELECT id,kind,name,path,line,col,lang,detail FROM nodes
             WHERE name=?1 OR name LIKE ?2 OR name LIKE ?3
                OR (name LIKE ?4 AND NOT EXISTS
                    (SELECT 1 FROM nodes WHERE name=?1 OR name LIKE ?2 OR name LIKE ?3))
             ORDER BY (name=?1) DESC, path, line LIMIT ?5",
        )?;
        let rows = stmt.query_map(params![name, member, method, like, limit], row_to_node)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    /// Endpoints for `path`. An exact definition wins; the substring search is only a fallback,
    /// because it made `path a b` seed `a` with every name containing `a` — and then the real goal,
    /// being also a start, was skipped and the route dropped. `explain` keeps the substring search:
    /// it wants every mention.
    fn find_seeds(&self, name: &str) -> Result<Vec<NodeRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT id,kind,name,path,line,col,lang,detail FROM nodes WHERE name=?1
             ORDER BY path, line LIMIT 5",
        )?;
        let rows = stmt.query_map(params![name], row_to_node)?;
        let exact: Vec<NodeRow> = rows.collect::<std::result::Result<_, _>>()?;
        if !exact.is_empty() {
            return Ok(exact);
        }
        self.find_nodes(name, 5)
    }

    fn outgoing(&self, id: i64) -> Result<Vec<EdgeRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT e.kind, e.target, e.path, e.line, e.dst,
                    n.name, n.path, n.line, e.resolution, e.confidence
             FROM edges e LEFT JOIN nodes n ON n.id = e.dst
             WHERE e.src=?1 ORDER BY e.line",
        )?;
        let rows = stmt.query_map(params![id], row_to_edge)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    fn incoming(&self, id: i64) -> Result<Vec<EdgeRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT e.kind, e.target, e.path, e.line, e.src,
                    s.name, s.path, s.line, e.resolution, e.confidence
             FROM edges e JOIN nodes s ON s.id = e.src
             WHERE e.dst=?1 ORDER BY e.path, e.line",
        )?;
        let rows = stmt.query_map(params![id], row_to_edge)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    /// Breadth-first path from one named node to another over resolved edges, followed in the
    /// direction they point: `path a b` holds when a calls/uses/imports b.
    pub fn path(&self, from: &str, to: &str) -> Result<Option<Vec<(NodeRow, String)>>> {
        let starts = self.find_seeds(from)?;
        let goals: std::collections::HashSet<i64> =
            self.find_seeds(to)?.into_iter().map(|n| n.id).collect();
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
        // Only outgoing edges are followed, because direction is the meaning: a route *through a
        // caller* is not a route. Traversing incoming edges too turned every shared callee into a
        // hub - `path build_context complete_with` answered
        // `build_context -> emit -> json.encode -> complete_with`, and `host.sha256`, a leaf with
        // ~42 callers, bridged two functions that never call each other. `not found` is the true
        // answer there. Doc mentions are for lookup, not traversal: following them hops through
        // prose onto a coincidence.
        let mut stmt = self.conn.prepare(
            "SELECT dst, kind, target, path, line, resolution, confidence FROM edges
             WHERE src=?1 AND dst IS NOT NULL AND kind<>'mentions'",
        )?;
        let rows = stmt.query_map(params![id], |r| {
            let other: i64 = r.get(0)?;
            let kind: String = r.get(1)?;
            let target: String = r.get(2)?;
            let path: String = r.get(3)?;
            let line: i64 = r.get(4)?;
            let resolution: String = r.get(5)?;
            let confidence: i64 = r.get(6)?;
            Ok((
                other,
                format!("{kind} {target} at {path}:{line} [{resolution} {confidence}]"),
            ))
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
        let member = format!("%.{text}");
        let mut stmt = self.conn.prepare(
            "SELECT n.id,n.kind,n.name,n.path,n.line,n.col,n.lang,n.detail
             FROM nodes n
             WHERE n.name LIKE ?1 OR n.path LIKE ?1 OR n.detail LIKE ?1
                OR EXISTS (SELECT 1 FROM edges e WHERE e.dst=n.id AND e.target LIKE ?1)
             ORDER BY CASE
                WHEN n.name=?2 THEN 0
                WHEN n.name LIKE ?3 THEN 1
                WHEN n.name LIKE ?1 THEN 2
                WHEN n.path LIKE ?1 THEN 3
                WHEN n.detail LIKE ?1 THEN 4
                ELSE 5 END,
                CASE WHEN n.path LIKE 'tests/%' OR n.path LIKE 'scripts/test-%'
                       OR n.path LIKE '%/tests.rs' THEN 1 ELSE 0 END,
                CASE WHEN n.kind IN ('fn','method','struct','module') THEN 0
                     WHEN n.kind='file' THEN 1
                     WHEN n.kind='capability' THEN 2
                     WHEN n.kind='var' THEN 3 ELSE 4 END,
                n.path,n.line LIMIT ?4",
        )?;
        let rows = stmt.query_map(params![like, text, member, limit], row_to_node)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    /// Ranked symbol discovery for retrieval, rather than the legacy location-oriented query.
    /// The score is deliberately explainable lexical evidence plus a small incoming-edge boost;
    /// it is not presented as semantic similarity.
    pub fn search_symbols(&self, text: &str, limit: i64) -> Result<Vec<SearchHit>> {
        self.search_symbols_with_preference(text, limit, false)
    }

    pub fn search_symbols_with_preference(
        &self, text: &str, limit: i64, prefer_implementations: bool,
    ) -> Result<Vec<SearchHit>> {
        let query = text.trim().to_ascii_lowercase();
        let terms = lexical_terms(text.trim());
        if query.is_empty() || terms.is_empty() {
            return Ok(Vec::new());
        }
        let wants_test = terms.iter().any(|term| term == "test" || term == "tests");
        let mut stmt = self.conn.prepare(
            "SELECT n.id,n.kind,n.name,n.path,n.line,n.col,n.lang,n.detail,
                    (SELECT COUNT(*) FROM edges e WHERE e.dst=n.id)
             FROM nodes n WHERE n.kind NOT IN ('file','doc','capability')",
        )?;
        let rows = stmt.query_map([], |row| Ok((row_to_node(row)?, row.get::<_, i64>(8)?)))?;
        let mut documents = Vec::new();
        for row in rows {
            let (node, incoming) = row?;
            let name_terms = lexical_terms(&node.name);
            let detail_terms = lexical_terms(node.detail.as_deref().unwrap_or(""));
            let path_terms = lexical_terms(&node.path);
            documents.push((node, incoming, name_terms, detail_terms, path_terms));
        }
        let document_count = documents.len().max(1) as f64;
        let average_length = documents
            .iter()
            .map(|(_, _, names, details, paths)| names.len() * 4 + details.len() * 2 + paths.len())
            .sum::<usize>()
            .max(1) as f64
            / document_count;
        let mut document_frequency: HashMap<String, usize> = HashMap::new();
        for term in &terms {
            let count = documents
                .iter()
                .filter(|(_, _, names, details, paths)| {
                    names
                        .iter()
                        .chain(details)
                        .chain(paths)
                        .any(|token| token == term)
                })
                .count();
            document_frequency.insert(term.clone(), count);
        }
        let mut hits = Vec::new();
        for (node, incoming, name_terms, detail_terms, path_terms) in documents {
            let name = node.name.to_ascii_lowercase();
            let simple = extract::simple_name(&name).to_string();
            let path = node.path.to_ascii_lowercase();
            let detail = node.detail.as_deref().unwrap_or("").to_ascii_lowercase();
            let mut score = 0i64;
            let mut matched = Vec::new();
            let mut definition_matched = Vec::new();
            let mut reason = "path";
            let mut score_breakdown = BTreeMap::new();

            if name == query {
                score += 1_000;
                score_breakdown.insert("exact".to_string(), 1_000);
                reason = "exact_name";
            } else if simple == query {
                score += 950;
                score_breakdown.insert("exact".to_string(), 950);
                reason = "exact_member";
            } else if name.contains(&query) {
                score += 450;
                score_breakdown.insert("phrase".to_string(), 450);
                reason = "name_phrase";
            }
            let weighted_length = name_terms.len() * 4 + detail_terms.len() * 2 + path_terms.len();
            let mut lexical_score = 0i64;
            for term in &terms {
                let name_tf = name_terms.iter().filter(|token| *token == term).count() * 4;
                let detail_tf = detail_terms.iter().filter(|token| *token == term).count() * 2;
                let path_tf = path_terms.iter().filter(|token| *token == term).count();
                let tf = name_tf + detail_tf + path_tf;
                if tf > 0 {
                    matched.push(term.clone());
                    if name_tf > 0 || detail_tf > 0 {
                        definition_matched.push(term.clone());
                    }
                    let df = *document_frequency.get(term).unwrap_or(&0) as f64;
                    let idf = (1.0 + (document_count - df + 0.5) / (df + 0.5)).ln();
                    let tf = tf as f64;
                    let length_norm = weighted_length.max(1) as f64 / average_length;
                    let bm25 = idf * (tf * 2.2) / (tf + 1.2 * (0.25 + 0.75 * length_norm));
                    lexical_score += (bm25 * 100.0).round() as i64;
                    if name_tf > 0 && reason == "path" {
                        reason = "name_terms";
                    } else if detail_tf > 0 && reason == "path" {
                        reason = "signature";
                    }
                } else if name.contains(term) || detail.contains(term) || path.contains(term) {
                    // Preserve substring recall for identifiers that the tokenizer cannot split.
                    matched.push(term.clone());
                    if name.contains(term) || detail.contains(term) {
                        definition_matched.push(term.clone());
                    }
                    lexical_score += 25;
                }
            }
            if matched.is_empty() {
                continue;
            }
            score += lexical_score;
            score_breakdown.insert("bm25".to_string(), lexical_score);
            if matched.len() == terms.len() {
                score += 120;
                score_breakdown.insert("all_terms".to_string(), 120);
                if definition_matched.len() == terms.len()
                    && reason != "exact_name" && reason != "exact_member" {
                    reason = "all_terms";
                }
            }
            // A local variable mentioning one concept word is a useful lead, but its
            // tiny definition is usually a poor first implementation to retrieve.
            if prefer_implementations && terms.len() > 1
                && matched.len() < terms.len() && node.kind == "var" {
                score -= 240;
                score_breakdown.insert("partial_variable".to_string(), -240);
            }
            let graph_score = incoming.min(20) * 2;
            score += graph_score;
            score_breakdown.insert("incoming_edges".to_string(), graph_score);
            let mut kind_score = 0;
            if matches!(node.kind.as_str(), "fn" | "method") {
                kind_score = 25;
            } else if matches!(
                node.kind.as_str(),
                "struct" | "class" | "interface" | "enum" | "type"
            ) {
                kind_score = 15;
            }
            score += kind_score;
            score_breakdown.insert("symbol_kind".to_string(), kind_score);
            if !wants_test && is_test_path(&path) {
                score -= 30;
                score_breakdown.insert("test_penalty".to_string(), -30);
            }
            let confidence = if reason == "exact_name" || reason == "exact_member" {
                "exact"
            } else if definition_matched.len() == terms.len() {
                "high"
            } else if !definition_matched.is_empty() {
                "medium"
            } else {
                "low"
            };
            let unmatched_terms = terms.iter().filter(|term| !matched.contains(term))
                .cloned().collect();
            let unmatched_definition_terms = terms.iter()
                .filter(|term| !definition_matched.contains(term)).cloned().collect();
            hits.push(SearchHit {
                node,
                score,
                confidence,
                reason,
                matched_terms: matched,
                unmatched_terms,
                unmatched_definition_terms,
                score_breakdown,
            });
        }
        hits.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then_with(|| a.node.path.cmp(&b.node.path))
                .then_with(|| a.node.line.cmp(&b.node.line))
        });
        hits.truncate(limit.max(1) as usize);
        Ok(hits)
    }

    /// Return a byte-exact page of one definition from the same source snapshot the graph
    /// verified. Selection uses the path/name/line tuple emitted by `search_symbols`, so this
    /// cannot become an arbitrary file-read surface.
    pub fn symbol_source_json(
        &self,
        path: &str,
        name: &str,
        line: i64,
        kind: Option<&str>,
        byte_offset: usize,
        max_bytes: usize,
    ) -> Result<Value> {
        let (lang, bytes): (String, Vec<u8>) = self.conn.query_row(
            "SELECT f.lang,s.source FROM files f JOIN graph_sources s USING(path) WHERE f.path=?1",
            params![path],
            |row| Ok((row.get(0)?, row.get(1)?)),
        ).optional()?.ok_or("symbol_path_not_found")?;
        let source = std::str::from_utf8(&bytes).map_err(|_| "graph_source_not_utf8")?;
        let extracted = extract::extract(path, &lang, source);
        let symbol = extracted
            .nodes
            .into_iter()
            .find(|node| {
                node.name == name
                    && node.line as i64 == line
                    && kind.map_or(true, |want| node.kind == want)
            })
            .ok_or("symbol_not_found_in_verified_source")?;
        let exact = source
            .get(symbol.start_byte..symbol.end_byte)
            .ok_or("symbol_source_range_invalid")?;
        if byte_offset > exact.len() || !exact.is_char_boundary(byte_offset) {
            return Err("symbol_source_offset_invalid".into());
        }
        let mut end = (byte_offset + max_bytes).min(exact.len());
        while end > byte_offset && !exact.is_char_boundary(end) {
            end -= 1;
        }
        let chunk = &exact[byte_offset..end];
        let eof = end == exact.len();
        Ok(json!({
            "symbol": {"kind": symbol.kind, "name": symbol.name, "path": path,
                "line": symbol.line, "language": lang},
            "source": chunk,
            "bytes": exact.len(),
            "byte_offset": byte_offset,
            "returned_bytes": chunk.len(),
            "next_byte_offset": if eof { Value::Null } else { json!(end) },
            "eof": eof,
            "freshness": "verified_snapshot",
        }))
    }

    /// A bounded, on-demand orientation bundle. Each section carries its total and truncation
    /// state so a small response is never presented as the whole graph.
    pub fn architecture_json(&self, aspects: &[String], limit: usize) -> Result<Value> {
        let limit = limit.clamp(1, 50);
        let wants = |name: &str| {
            aspects.is_empty()
                || aspects
                    .iter()
                    .any(|aspect| aspect == "overview" || aspect == "all" || aspect == name)
        };
        let stats = self.stats()?;
        let mut root = serde_json::Map::new();
        root.insert("generation".into(), json!(self.generation()?));
        root.insert("freshness".into(), json!("verified_snapshot"));
        root.insert("counts".into(), stats.to_json());

        if wants("languages") {
            let mut stmt = self.conn.prepare(
                "SELECT lang,COUNT(*) FROM files GROUP BY lang ORDER BY COUNT(*) DESC,lang",
            )?;
            let rows = stmt
                .query_map([], |row| {
                    Ok(json!({"language":row.get::<_, String>(0)?,"files":row.get::<_, i64>(1)?}))
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            root.insert("languages".into(), bounded_section(rows, limit));
        }
        if wants("modules") {
            let mut modules: BTreeMap<String, i64> = BTreeMap::new();
            for path in self.all_file_paths()? {
                *modules.entry(top_component(&path).to_string()).or_default() += 1;
            }
            let mut rows: Vec<Value> = modules
                .into_iter()
                .map(|(module, files)| json!({"module":module,"files":files}))
                .collect();
            rows.sort_by(|a, b| {
                b["files"]
                    .as_i64()
                    .cmp(&a["files"].as_i64())
                    .then_with(|| a["module"].as_str().cmp(&b["module"].as_str()))
            });
            root.insert("modules".into(), bounded_section(rows, limit));
        }
        if wants("entry_points") {
            let mut stmt = self.conn.prepare(
                "SELECT n.id,n.kind,n.name,n.path,n.line,n.col,n.lang,n.detail,
                        (SELECT COUNT(*) FROM edges e WHERE e.dst=n.id),
                        (SELECT COUNT(*) FROM edges e WHERE e.src=n.id AND e.dst IS NOT NULL)
                 FROM nodes n WHERE n.kind IN ('fn','method') AND
                   (n.name IN ('main','run','serve','dispatch') OR n.name LIKE 'wa_%')
                 ORDER BY CASE n.name WHEN 'main' THEN 0 WHEN 'serve' THEN 1 WHEN 'run' THEN 2 ELSE 3 END,
                          n.path,n.line",
            )?;
            let rows = stmt
                .query_map([], |row| {
                    let node = row_to_node(row)?;
                    Ok(
                        json!({"kind":node.kind,"name":node.name,"path":node.path,"line":node.line,
                    "incoming":row.get::<_, i64>(8)?,"outgoing":row.get::<_, i64>(9)?}),
                    )
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            root.insert("entry_points".into(), bounded_section(rows, limit));
        }
        if wants("routes") {
            let mut stmt = self.conn.prepare(
                "SELECT id,kind,name,path,line,col,lang,detail FROM nodes WHERE kind='route'
                 ORDER BY path,line",
            )?;
            let rows = stmt
                .query_map([], |row| Ok(row_to_node(row)?.to_json()))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            root.insert("routes".into(), bounded_section(rows, limit));
        }
        if wants("capabilities") {
            let rows = self
                .capabilities()?
                .into_iter()
                .map(|(name, uses)| json!({"capability":name,"uses":uses}))
                .collect();
            root.insert("capabilities".into(), bounded_section(rows, limit));
        }
        if wants("hotspots") {
            let mut stmt = self.conn.prepare(
                "SELECT n.id,n.kind,n.name,n.path,n.line,n.col,n.lang,n.detail,
                        (SELECT COUNT(*) FROM edges e WHERE e.dst=n.id),
                        (SELECT COUNT(*) FROM edges e WHERE e.src=n.id AND e.dst IS NOT NULL)
                 FROM nodes n WHERE n.kind NOT IN ('file','doc','capability','route')
                 ORDER BY ((SELECT COUNT(*) FROM edges e WHERE e.dst=n.id) +
                           (SELECT COUNT(*) FROM edges e WHERE e.src=n.id AND e.dst IS NOT NULL)) DESC,
                          n.path,n.line",
            )?;
            let rows = stmt
                .query_map([], |row| {
                    let node = row_to_node(row)?;
                    Ok(
                        json!({"kind":node.kind,"name":node.name,"path":node.path,"line":node.line,
                    "incoming":row.get::<_, i64>(8)?,"outgoing":row.get::<_, i64>(9)?}),
                    )
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            root.insert("hotspots".into(), bounded_section(rows, limit));
        }
        if wants("boundaries") {
            let mut stmt = self.conn.prepare(
                "SELECT s.path,d.path,e.kind FROM edges e JOIN nodes s ON s.id=e.src
                 JOIN nodes d ON d.id=e.dst WHERE e.dst IS NOT NULL AND e.kind<>'mentions'",
            )?;
            let edges = stmt.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?;
            let mut boundaries: BTreeMap<(String, String, String), i64> = BTreeMap::new();
            for edge in edges {
                let (from_path, to_path, kind) = edge?;
                let from = top_component(&from_path);
                let to = top_component(&to_path);
                if from != to {
                    *boundaries
                        .entry((from.to_string(), to.to_string(), kind))
                        .or_default() += 1;
                }
            }
            let mut rows: Vec<Value> = boundaries.into_iter().map(|((from,to,kind), edges)|
                json!({"from":from,"to":to,"kind":kind,"edges":edges})).collect();
            rows.sort_by(|a, b| {
                b["edges"]
                    .as_i64()
                    .cmp(&a["edges"].as_i64())
                    .then_with(|| a["from"].as_str().cmp(&b["from"].as_str()))
            });
            root.insert("boundaries".into(), bounded_section(rows, limit));
        }
        if wants("resolution") {
            let mut stmt = self.conn.prepare(
                "SELECT resolution,confidence,COUNT(*) FROM edges GROUP BY resolution,confidence
                 ORDER BY COUNT(*) DESC,resolution",
            )?;
            let rows = stmt
                .query_map([], |row| {
                    Ok(json!({"strategy":row.get::<_, String>(0)?,
                "confidence":row.get::<_, i64>(1)?,"edges":row.get::<_, i64>(2)?}))
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            root.insert("resolution".into(), bounded_section(rows, limit));
        }
        Ok(Value::Object(root))
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

    pub fn search_symbols_json(&self, text: &str, limit: i64) -> Result<Value> {
        self.search_symbols_json_with_preference(text, limit, false)
    }

    pub fn search_symbols_json_with_preference(
        &self, text: &str, limit: i64, prefer_implementations: bool,
    ) -> Result<Value> {
        Ok(Value::Array(
            self.search_symbols_with_preference(text, limit, prefer_implementations)?
                .into_iter()
                .map(|hit| {
                    json!({
                        "kind": hit.node.kind,
                        "name": hit.node.name,
                        "path": hit.node.path,
                        "line": hit.node.line,
                        "language": hit.node.lang,
                        "signature": hit.node.detail,
                        "score": hit.score,
                        "confidence": hit.confidence,
                        "reason": hit.reason,
                        "matched_terms": hit.matched_terms,
                        "unmatched_terms": hit.unmatched_terms,
                        "unmatched_definition_terms": hit.unmatched_definition_terms,
                        "score_breakdown": hit.score_breakdown,
                    })
                })
                .collect(),
        ))
    }
}

fn lexical_terms(text: &str) -> Vec<String> {
    let mut terms = Vec::new();
    let mut current = String::new();
    let mut previous_lower_or_digit = false;
    for ch in text.chars() {
        if !ch.is_alphanumeric() {
            push_term(&mut terms, &mut current);
            previous_lower_or_digit = false;
            continue;
        }
        if ch.is_uppercase() && previous_lower_or_digit {
            push_term(&mut terms, &mut current);
        }
        current.extend(ch.to_lowercase());
        previous_lower_or_digit = ch.is_lowercase() || ch.is_ascii_digit();
    }
    push_term(&mut terms, &mut current);
    terms
}

fn push_term(terms: &mut Vec<String>, current: &mut String) {
    if !current.is_empty() && !terms.contains(current) {
        terms.push(std::mem::take(current));
    } else {
        current.clear();
    }
}

fn ensure_column(conn: &Connection, table: &str, column: &str, declaration: &str) -> Result<()> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(1))?;
    for row in rows {
        if row? == column {
            return Ok(());
        }
    }
    conn.execute_batch(&format!(
        "ALTER TABLE {table} ADD COLUMN {column} {declaration}"
    ))?;
    Ok(())
}

fn is_test_path(path: &str) -> bool {
    path.starts_with("tests/")
        || path.contains("/tests/")
        || path.contains("/test_")
        || path.contains("/test-")
        || path.ends_with("/tests.rs")
}

fn top_component(path: &str) -> &str {
    path.split('/')
        .next()
        .filter(|part| !part.is_empty())
        .unwrap_or(".")
}

fn bounded_section(mut rows: Vec<Value>, limit: usize) -> Value {
    let total = rows.len();
    rows.truncate(limit);
    json!({"total":total,"returned":rows.len(),"truncated":total > rows.len(),"rows":rows})
}

fn pick_candidate(
    conn: &Connection,
    target: &str,
    simple: &str,
    edge_path: &str,
) -> Result<Option<Resolved>> {
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
        if let Some(id) = same_file {
            return Ok(Some(Resolved {
                id,
                strategy: "same_file",
                confidence: 95,
            }));
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
        if let Some(id) = same_dir {
            return Ok(Some(Resolved {
                id,
                strategy: "same_directory",
                confidence: 85,
            }));
        }
    }
    for name in [target, simple] {
        let mut stmt = conn.prepare("SELECT id FROM nodes WHERE name=?1 LIMIT 2")?;
        let mut rows = stmt.query(params![name])?;
        let first = rows.next()?.map(|r| r.get::<_, i64>(0)).transpose()?;
        let second = rows.next()?.map(|r| r.get::<_, i64>(0)).transpose()?;
        if first.is_some() && second.is_none() {
            return Ok(first.map(|id| Resolved {
                id,
                strategy: "unique_name",
                confidence: 75,
            }));
        }
    }
    Ok(None)
}

/// Resolve a dotted call `receiver.member`. The receiver decides:
///
/// * a bound module alias (`require`/`dofile`/`import`) resolves to that module's export, which
///   is its precise meaning;
/// * `self`/`this`/`M` resolve within the caller's own file (the module table or the enclosing
///   class), because the receiver has no name of its own to match;
/// * anything else - `response.text`, `fs.readFileSync`, `obj.budget` - must match the full name
///   exactly. It must **not** fall back to a bare local that merely shares `member`'s name: that
///   is how `provider.budget()` once landed on an unrelated local `budget`.
fn resolve_dotted(
    conn: &Connection,
    target: &str,
    simple: &str,
    path: &str,
) -> Result<Option<Resolved>> {
    if let Some(id) = resolve_alias(conn, target, path)? {
        return Ok(Some(Resolved {
            id,
            strategy: "import_exact",
            confidence: 98,
        }));
    }
    let receiver = target.split('.').next().unwrap_or("");
    if matches!(receiver, "self" | "this" | "M" | "cls") {
        let exact = conn
            .query_row(
                "SELECT id FROM nodes WHERE path=?1 AND name=?2 LIMIT 1",
                params![path, target],
                |r| r.get(0),
            )
            .optional()?;
        if exact.is_some() {
            return Ok(exact.map(|id| Resolved {
                id,
                strategy: "same_file_qualified",
                confidence: 97,
            }));
        }
        return Ok(scoped_member(conn, simple, path)?.map(|id| Resolved {
            id,
            strategy: "same_file_member",
            confidence: 92,
        }));
    }
    Ok(exact_node(conn, target)?.map(|id| Resolved {
        id,
        strategy: "qualified_unique",
        confidence: 88,
    }))
}

/// A member of the caller's own file: `self.emit`, `this.render`, `M.append_turn`. A function or
/// method is preferred over a field or variable that shares the name.
fn scoped_member(conn: &Connection, simple: &str, path: &str) -> Result<Option<i64>> {
    let hit = conn
        .query_row(
            "SELECT id FROM nodes WHERE path=?1 AND (name=?2 OR name LIKE ?3 OR name LIKE ?4)
             ORDER BY (kind='fn' OR kind='method') DESC, (name=?2) DESC, line LIMIT 1",
            params![path, simple, format!("%.{simple}"), format!("%:{simple}")],
            |r| r.get(0),
        )
        .optional()?;
    Ok(hit)
}

/// A node whose name is exactly `target` (a qualified name such as `Thing::new` or `Provider.foo`).
fn exact_node(conn: &Connection, target: &str) -> Result<Option<i64>> {
    let mut stmt = conn.prepare("SELECT id FROM nodes WHERE name=?1 LIMIT 2")?;
    let mut rows = stmt.query(params![target])?;
    let first = rows.next()?.map(|r| r.get::<_, i64>(0)).transpose()?;
    let second = rows.next()?.map(|r| r.get::<_, i64>(0)).transpose()?;
    Ok(if first.is_some() && second.is_none() {
        first
    } else {
        None
    })
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
    // The binding may be a Lua dotted module (`require('core.memory')`), a Lua path
    // (`dofile('lua/core/memory.lua')`) or a JS path (`require('./reply.mjs')`,
    // `import * as x from '../lib/x.mjs'`). Build the path suffix each spelling needs; one rule
    // built `lua/core/memory/lua.lua` for a dofile and `//reply/mjs.lua` for a JS import, and
    // matched no node at all.
    let raw = module.trim();
    let trimmed = raw.strip_prefix("./").unwrap_or(raw);
    let by_path = format!("%{trimmed}");
    let by_lua = format!(
        "%{}.lua",
        trimmed.trim_end_matches(".lua").replace('.', "/")
    );
    let base = trimmed.rsplit('/').next().unwrap_or(trimmed);
    let by_base = format!("%{base}");
    let dot_suffix = format!("%.{simple}");
    // Prefer the module table's export (`M.budget`) over a bare `budget` declared inside it: the
    // alias names the module, so `provider.budget` is `M.budget`, not a local variable that
    // happens to share the name. Without this the edge resolved - to the wrong symbol.
    let hit: Option<i64> = conn
        .query_row(
            "SELECT id FROM nodes WHERE (path LIKE ?1 OR path LIKE ?2 OR path LIKE ?3)
               AND (name=?4 OR name LIKE ?5)
             ORDER BY (name LIKE ?5) DESC, (kind='fn' OR kind='method') DESC, (name=?4) DESC, line LIMIT 1",
            params![by_path, by_lua, by_base, simple, dot_suffix],
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
        resolution: r.get(8)?,
        confidence: r.get(9)?,
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
            "resolution": self.resolution,
            "confidence": self.confidence,
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
        let entries = std::fs::read_dir(&dir)?;
        for entry in entries {
            let entry = entry?;
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if std::fs::metadata(&path)?.is_dir() {
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
