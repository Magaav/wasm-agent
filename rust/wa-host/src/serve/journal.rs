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
}

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
        Ok(Self { db: Mutex::new(db), _lease: Mutex::new(lease) })
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
            params![id,owner,conversation], |row| Ok(json!({"ok":true,"run_id":id,
                "state":row.get::<_,String>(0)?,"request":row.get::<_,String>(1)?,
                "created_at":row.get::<_,u64>(2)?,"updated_at":row.get::<_,u64>(3)?,
                "recovery":"Inspect transcript, operations and external effects before submitting a continuation; this request is never replayed automatically."})))
            .optional().map_err(|e|e.to_string())
    }

    pub fn state(&self, id: u64, state: &str, cancelled: bool) -> Result<(), String> {
        let db = self.db.lock().map_err(|e| e.to_string())?;
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
            Ok(json!({"run_id":row.get::<_,u64>(0)?, "state":row.get::<_,String>(1)?,
                "cancel_requested":row.get::<_,bool>(2)?}))
        }).map_err(|e| e.to_string())?;
        let mut result = rows.collect::<Result<Vec<_>,_>>().map_err(|e| e.to_string())?;
        result.reverse();
        Ok(result)
    }

    pub fn event(&self, id: u64, payload: &str) -> Result<(), String> {
        let value: Value = serde_json::from_str(payload).map_err(|e| e.to_string())?;
        let mut db = self.db.lock().map_err(|e| e.to_string())?;
        let tx = db.transaction().map_err(|e| e.to_string())?;
        tx.execute("INSERT INTO events(run_id,seq,payload) SELECT ?,COALESCE(MAX(seq),0)+1,? FROM events WHERE run_id=?",
            params![id,payload,id]).map_err(|e| e.to_string())?;
        if value["type"] == "error" {
            tx.execute("UPDATE admissions SET had_error=1,updated_at=unixepoch() WHERE id=?", [id]).map_err(|e| e.to_string())?;
        }
        tx.commit().map_err(|e| e.to_string())
    }

    pub fn replay(&self, owner: &str, conversation: &str, id: u64, after: u64) -> Result<Option<Value>, String> {
        use rusqlite::OptionalExtension;
        let db = self.db.lock().map_err(|e| e.to_string())?;
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
        let rows = stmt.query_map(params![id,after.max(checkpoint_seq)], |row| Ok((row.get::<_,u64>(0)?,row.get::<_,String>(1)?)))
            .map_err(|e| e.to_string())?;
        let mut next = after.max(checkpoint_seq);
        let mut events = Vec::new();
        for row in rows {
            let (seq,payload) = row.map_err(|e|e.to_string())?;
            events.push(json!({"seq":seq,"event":serde_json::from_str::<Value>(&payload).map_err(|e|e.to_string())?}));
            next = seq;
        }
        let latest: u64 = db.query_row("SELECT COALESCE(MAX(seq),0) FROM events WHERE run_id=?", [id], |row|row.get(0)).map_err(|e|e.to_string())?;
        Ok(Some(json!({"ok":true,"run_id":id,"state":state,"durable":true,
            "checkpoint_seq":checkpoint_seq,"checkpoint_message_seq":checkpoint_message_seq,
            "next_seq":next,"latest_seq":latest,"has_more":next<latest,"overflow":false,"events":events})))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
        assert!(journal.replay("bob","a",running,0).unwrap().is_none());
        assert!(journal.replay("alice","b",running,0).unwrap().is_none());
        let replay = journal.replay("alice","a",running,0).unwrap().unwrap();
        assert_eq!(replay["checkpoint_message_seq"],4);
        assert_eq!(replay["events"][0]["event"]["text"],"unsaved evidence");
        assert!(journal.admit("alice","a").unwrap() > queued, "run IDs survive restart");
        for _ in 0..520 { journal.event(running,r#"{"type":"delta","text":"x"}"#).unwrap(); }
        let page = journal.replay("alice","a",running,0).unwrap().unwrap();
        assert_eq!(page["events"].as_array().unwrap().len(),512);
        assert_eq!(page["has_more"],true);
        let tail = journal.replay("alice","a",running,page["next_seq"].as_u64().unwrap()).unwrap().unwrap();
        assert_eq!(tail["events"].as_array().unwrap().len(),9);
        drop(journal);
        std::fs::remove_dir_all(root).unwrap();
    }
}
