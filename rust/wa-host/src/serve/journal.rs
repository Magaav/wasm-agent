//! Durable admission and stream evidence. This is node-local runtime state, never synced.
//! The lease database holds an OS-backed SQLite lock for the server's lifetime. A second
//! server cannot recover a live server's runs. Crash recovery records uncertainty; it never
//! replays inference, a shell command, or an external effect.
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Mutex;

pub struct Journal {
    db: Mutex<Connection>,
    _lease: Mutex<Connection>,
    /// Streamed deltas not yet written. A token stream used to cost one fsync'd transaction per token
    /// under the node-wide lock; deltas now go to disk in one transaction per batch, and any other event
    /// (checkpoint, tool, error, done) flushes the batch first, so the order on disk is unchanged.
    pending: Mutex<(Vec<(u64, String)>, std::time::Instant)>,
}

/// Events that only carry more streamed text. Losing the last fraction of a second of these in a crash
/// loses display text the transcript checkpoint does not depend on.
fn coalescable(kind: &str) -> bool {
    kind == "delta" || kind == "reasoning" || kind.ends_with("_delta")
}

const PENDING_MAX: usize = 64;
const PENDING_AGE: std::time::Duration = std::time::Duration::from_millis(250);

impl Journal {
    pub fn open(path: &Path) -> Result<Self, String> {
        let lease = Connection::open(std::path::PathBuf::from(format!("{}.run-lease.sqlite",path.display()))).map_err(|e| e.to_string())?;
        lease.busy_timeout(std::time::Duration::from_millis(0)).map_err(|e| e.to_string())?;
        lease.execute_batch("PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE;")
            .map_err(|e| format!("run_journal_already_owned: {e}"))?;
        let db = Connection::open(std::path::PathBuf::from(format!("{}.run-journal.sqlite",path.display()))).map_err(|e| e.to_string())?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS admissions (
                id INTEGER PRIMARY KEY AUTOINCREMENT, owner TEXT NOT NULL, conversation TEXT NOT NULL,
                state TEXT NOT NULL, cancel_requested INTEGER NOT NULL DEFAULT 0, had_error INTEGER NOT NULL DEFAULT 0, request TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL DEFAULT (unixepoch()), updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
            CREATE INDEX IF NOT EXISTS admissions_owner ON admissions(owner, conversation, id);
            CREATE TABLE IF NOT EXISTS events (
                run_id INTEGER NOT NULL, seq INTEGER NOT NULL, payload TEXT NOT NULL,
                PRIMARY KEY(run_id, seq));
            UPDATE admissions SET state=CASE WHEN state='queued' THEN 'not_started' ELSE 'unknown' END,
                updated_at=unixepoch() WHERE state IN ('queued','running');")
            .map_err(|e| e.to_string())?;
        // Nothing pruned this store, and every streamed token was a row. Settled runs keep their stream
        // evidence for a week and their admission row for a month; an unsettled one is never pruned.
        db.execute_batch("DELETE FROM events WHERE run_id IN (SELECT id FROM admissions
                WHERE state NOT IN ('queued','running','unknown') AND updated_at < unixepoch() - 7*86400);
            DELETE FROM admissions WHERE state NOT IN ('queued','running','unknown') AND updated_at < unixepoch() - 30*86400;
            PRAGMA wal_checkpoint(TRUNCATE);")
            .map_err(|e| e.to_string())?;
        Ok(Self { db: Mutex::new(db), _lease: Mutex::new(lease),
            pending: Mutex::new((Vec::new(), std::time::Instant::now())) })
    }

    /// Write any batched deltas. Called before every other write and read, so nothing observes a gap.
    fn flush(&self, db: &mut Connection) -> Result<(), String> {
        let mut pending = self.pending.lock().map_err(|e| e.to_string())?;
        if pending.0.is_empty() {
            return Ok(());
        }
        let tx = db.transaction().map_err(|e| e.to_string())?;
        for (id, payload) in pending.0.iter() {
            tx.execute("INSERT INTO events(run_id,seq,payload) SELECT ?,COALESCE(MAX(seq),0)+1,? FROM events WHERE run_id=?",
                params![id, payload, id]).map_err(|e| e.to_string())?;
        }
        tx.commit().map_err(|e| e.to_string())?;
        pending.0.clear();
        pending.1 = std::time::Instant::now();
        Ok(())
    }

    /// A write that proves the database accepts writes again, so a transient failure (a busy or full
    /// disk) does not refuse every run until the process restarts.
    pub fn probe(&self) -> Result<(), String> {
        let mut db = self.db.lock().map_err(|e| e.to_string())?;
        self.flush(&mut db)?;
        db.execute_batch("BEGIN IMMEDIATE; COMMIT;").map_err(|e| e.to_string())
    }

    pub fn admit(&self, owner: &str, conversation: &str) -> Result<u64, String> {
        let db = self.db.lock().map_err(|e| e.to_string())?;
        db.execute("INSERT INTO admissions(owner,conversation,state) VALUES(?,?,'queued')", params![owner, conversation])
            .map_err(|e| e.to_string())?;
        Ok(db.last_insert_rowid() as u64)
    }

    pub fn request(&self, id: u64, body: &str) -> Result<(),String> {
        let db = self.db.lock().map_err(|e|e.to_string())?;
        db.execute("UPDATE admissions SET request=? WHERE id=? AND state='queued'",params![body,id]).map_err(|e|e.to_string())?;
        Ok(())
    }

    pub fn inspect(&self, owner: &str, conversation: &str, id: u64) -> Result<Option<Value>,String> {
        use rusqlite::OptionalExtension;
        let db = self.db.lock().map_err(|e|e.to_string())?;
        db.query_row("SELECT state,request,created_at,updated_at FROM admissions WHERE id=? AND owner=? AND conversation=?",
            params![id,owner,conversation], |row| Ok(json!({"ok":true,"run_id":id,"run_key":id.to_string(),
                "state":row.get::<_,String>(0)?,"request":row.get::<_,String>(1)?,
                "created_at":row.get::<_,u64>(2)?,"updated_at":row.get::<_,u64>(3)?,
                "recovery":"Inspect transcript, operations and external effects before submitting a continuation; this request is never replayed automatically."})))
            .optional().map_err(|e|e.to_string())
    }

    pub fn state(&self, id: u64, state: &str, cancelled: bool) -> Result<(), String> {
        let mut db = self.db.lock().map_err(|e| e.to_string())?;
        self.flush(&mut db)?;
        // Failed stream evidence must never later become a successful settlement.
        db.execute("UPDATE admissions SET state=CASE WHEN had_error=1 AND ?='completed' THEN 'failed' ELSE ? END,
            cancel_requested=MAX(cancel_requested,?), updated_at=unixepoch() WHERE id=?",
            params![state, state, cancelled, id]).map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn views(&self, owner: &str, conversation: &str) -> Result<Vec<Value>, String> {
        let db = self.db.lock().map_err(|e| e.to_string())?;
        let mut stmt = db.prepare("SELECT id,state,cancel_requested FROM admissions
            WHERE owner=? AND conversation=? ORDER BY id DESC LIMIT 100").map_err(|e| e.to_string())?;
        let rows = stmt.query_map(params![owner, conversation], |row| {
            Ok(json!({"run_id":row.get::<_,u64>(0)?, "run_key":row.get::<_,u64>(0)?.to_string(), "state":row.get::<_,String>(1)?,
                "cancel_requested":row.get::<_,bool>(2)?}))
        }).map_err(|e| e.to_string())?;
        let mut result = rows.collect::<Result<Vec<_>,_>>().map_err(|e| e.to_string())?;
        result.reverse();
        Ok(result)
    }

    pub fn event(&self, id: u64, payload: &str) -> Result<(), String> {
        let value: Value = serde_json::from_str(payload).map_err(|e| e.to_string())?;
        let mut db = self.db.lock().map_err(|e| e.to_string())?;
        if coalescable(value["type"].as_str().unwrap_or("")) {
            let due = {
                let mut pending = self.pending.lock().map_err(|e| e.to_string())?;
                pending.0.push((id, payload.to_string()));
                pending.0.len() >= PENDING_MAX || pending.1.elapsed() >= PENDING_AGE
            };
            return if due { self.flush(&mut db) } else { Ok(()) };
        }
        self.flush(&mut db)?;
        let tx = db.transaction().map_err(|e| e.to_string())?;
        tx.execute("INSERT INTO events(run_id,seq,payload) SELECT ?,COALESCE(MAX(seq),0)+1,? FROM events WHERE run_id=?",
            params![id,payload,id]).map_err(|e| e.to_string())?;
        if value["type"] == "error" {
            tx.execute("UPDATE admissions SET had_error=1,updated_at=unixepoch() WHERE id=?", [id]).map_err(|e| e.to_string())?;
        }
        tx.commit().map_err(|e| e.to_string())
    }

    pub fn replay(&self, owner: &str, conversation: &str, id: u64, after: u64, archive: bool) -> Result<Option<Value>, String> {
        use rusqlite::OptionalExtension;
        let mut db = self.db.lock().map_err(|e| e.to_string())?;
        self.flush(&mut db)?;
        let state = db.query_row("SELECT state FROM admissions WHERE id=? AND owner=? AND conversation=?",
            params![id,owner,conversation], |row| row.get::<_,String>(0)).optional().map_err(|e| e.to_string())?;
        let Some(state) = state else { return Ok(None) };
        let checkpoint = db.query_row("SELECT seq,payload FROM events WHERE run_id=?
            AND json_extract(payload,'$.type')='checkpoint' ORDER BY seq DESC LIMIT 1", [id],
            |row| Ok((row.get::<_,u64>(0)?, row.get::<_,String>(1)?))).optional().map_err(|e| e.to_string())?;
        let (checkpoint_seq, checkpoint_message_seq) = match checkpoint {
            Some((seq, payload)) => (seq, serde_json::from_str::<Value>(&payload).map_err(|e|e.to_string())?["seq"].as_u64().unwrap_or(0)),
            None => (0, 0),
        };
        // Page without dropping evidence. next_seq is the last delivered cursor, not the
        // end of the archive, so a client cannot skip an undisplayed page.
        let mut stmt = db.prepare("SELECT seq,payload FROM events WHERE run_id=? AND seq>? ORDER BY seq LIMIT 512")
            .map_err(|e| e.to_string())?;
        // Reconnect starts after the transcript checkpoint; evidence inspection
        // must also expose earlier partial output that a failed turn did not save.
        let start=if archive {after} else {after.max(checkpoint_seq)};
        let rows = stmt.query_map(params![id,start], |row| Ok((row.get::<_,u64>(0)?,row.get::<_,String>(1)?)))
            .map_err(|e| e.to_string())?;
        let mut next = start;
        let mut events = Vec::new();
        for row in rows {
            let (seq,payload) = row.map_err(|e|e.to_string())?;
            events.push(json!({"seq":seq,"event":serde_json::from_str::<Value>(&payload).map_err(|e|e.to_string())?}));
            next = seq;
        }
        let latest: u64 = db.query_row("SELECT COALESCE(MAX(seq),0) FROM events WHERE run_id=?", [id], |row|row.get(0)).map_err(|e|e.to_string())?;
        Ok(Some(json!({"ok":true,"run_id":id,"run_key":id.to_string(),"state":state,"durable":true,"archive":archive,
            "checkpoint_seq":checkpoint_seq,"checkpoint_message_seq":checkpoint_message_seq,
            "next_seq":next,"latest_seq":latest,"has_more":next<latest,"overflow":false,"events":events})))
    }
}

impl Drop for Journal {
    /// A clean shutdown keeps every batched delta. Only a hard crash can lose the last batch (at most
    /// PENDING_AGE of streamed text; checkpoints, tool events and errors are never batched).
    fn drop(&mut self) {
        if let Ok(mut db) = self.db.lock() {
            let _ = self.flush(&mut db);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn high_identity_is_exact_and_owner_scoped() {
        let root=std::env::temp_dir().join(format!("wa-high-run-{}-{}",std::process::id(),crate::serve::now_ms()));
        std::fs::create_dir_all(&root).unwrap();
        let path=root.join("memory.db");
        let journal=Journal::open(&path).unwrap();
        let id=9_007_199_254_740_993u64;
        journal.db.lock().unwrap().execute("INSERT INTO admissions(id,owner,conversation,state,created_at,updated_at) VALUES(?, 'alice','thread','completed',unixepoch(),unixepoch())",[id]).unwrap();
        assert_eq!(journal.inspect("alice","thread",id).unwrap().unwrap()["run_key"],id.to_string());
        assert!(journal.inspect("bob","thread",id).unwrap().is_none());
        assert!(journal.inspect("alice","foreign",id).unwrap().is_none());
        assert!(journal.inspect("alice","thread",id+1).unwrap().is_none());
        journal.event(id,r#"{"type":"delta","text":"exact high id"}"#).unwrap();
        assert_eq!(journal.replay("alice","thread",id,0,true).unwrap().unwrap()["run_key"],id.to_string());
        assert!(journal.replay("bob","thread",id,0,true).unwrap().is_none());
        drop(journal);
        let journal=Journal::open(&path).unwrap();
        assert_eq!(journal.views("alice","thread").unwrap()[0]["run_key"],id.to_string());
        drop(journal);std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn restart_preserves_evidence_scopes_owners_and_never_replays_work() {
        let root = std::env::temp_dir().join(format!("wa-run-journal-{}-{}",std::process::id(),crate::serve::now_ms()));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("memory.db");
        let journal = Journal::open(&path).unwrap();
        assert!(Journal::open(&path).is_err(), "a second server cannot recover a live server");
        let running = journal.admit("alice","a").unwrap();
        journal.state(running,"running",false).unwrap();
        journal.event(running,r#"{"type":"checkpoint","seq":4}"#).unwrap();
        journal.event(running,r#"{"type":"delta","text":"unsaved evidence"}"#).unwrap();
        let queued = journal.admit("alice","a").unwrap();
        drop(journal);
        let journal = Journal::open(&path).unwrap();
        let views = journal.views("alice","a").unwrap();
        assert_eq!(views[0]["state"],"unknown");
        assert_eq!(views[1]["state"],"not_started");
        assert!(journal.replay("bob","a",running,0,false).unwrap().is_none());
        assert!(journal.replay("alice","b",running,0,false).unwrap().is_none());
        let replay = journal.replay("alice","a",running,0,false).unwrap().unwrap();
        assert_eq!(replay["checkpoint_message_seq"],4);
        assert_eq!(replay["events"][0]["event"]["text"],"unsaved evidence");
        assert!(journal.admit("alice","a").unwrap() > queued, "run IDs survive restart");
        for _ in 0..520 { journal.event(running,r#"{"type":"delta","text":"x"}"#).unwrap(); }
        let page = journal.replay("alice","a",running,0,false).unwrap().unwrap();
        assert_eq!(page["events"].as_array().unwrap().len(),512);
        assert_eq!(page["has_more"],true);
        let tail = journal.replay("alice","a",running,page["next_seq"].as_u64().unwrap(),false).unwrap().unwrap();
        assert_eq!(tail["events"].as_array().unwrap().len(),9);
        journal.event(running,r#"{"type":"checkpoint","seq":5}"#).unwrap();
        let reconnect=journal.replay("alice","a",running,0,false).unwrap().unwrap();
        assert!(reconnect["events"].as_array().unwrap().is_empty());
        let archive=journal.replay("alice","a",running,0,true).unwrap().unwrap();
        assert_eq!(archive["events"][1]["event"]["text"],"unsaved evidence");
        assert_eq!(archive["has_more"],true);
        drop(journal);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn deltas_are_batched_but_never_reordered() {
        let root=std::env::temp_dir().join(format!("wa-run-batch-{}-{}",std::process::id(),crate::serve::now_ms()));
        std::fs::create_dir_all(&root).unwrap();
        let journal=Journal::open(&root.join("memory.db")).unwrap();
        let id=journal.admit("alice","a").unwrap();
        journal.event(id,r#"{"type":"delta","text":"a"}"#).unwrap();
        journal.event(id,r#"{"type":"delta","text":"b"}"#).unwrap();
        let rows: i64 = journal.db.lock().unwrap().query_row("SELECT COUNT(*) FROM events",[],|r|r.get(0)).unwrap();
        assert_eq!(rows, 0, "two deltas inside the window are not yet written");
        journal.event(id,r#"{"type":"tool","name":"x"}"#).unwrap();
        let replay=journal.replay("alice","a",id,0,true).unwrap().unwrap();
        let kinds: Vec<String> = replay["events"].as_array().unwrap().iter()
            .map(|e| e["event"]["text"].as_str().or(e["event"]["type"].as_str()).unwrap_or("").to_string()).collect();
        assert_eq!(kinds, vec!["a","b","tool"], "a non-delta event flushes the batch first, in order");
        drop(journal);std::fs::remove_dir_all(root).unwrap();
    }
}
