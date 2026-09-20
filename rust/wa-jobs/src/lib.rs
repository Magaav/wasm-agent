//! Durable automation definitions and deliveries. No model calls or shell execution here.
//! A job is a disabled-by-default trigger + declared action. A delivery pins its revision.
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};
pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
#[derive(Clone)]
pub struct Store {
    path: PathBuf,
}
fn fail<T>(why: &str) -> Result<T> {
    Err(why.into())
}
fn ident(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 100
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
}
pub fn validate(job: &Value) -> Result<()> {
    if !ident(job["id"].as_str().unwrap_or("")) {
        return fail("invalid_job_id");
    }
    if job["name"].as_str().unwrap_or("").is_empty() {
        return fail("job_name_required");
    }
    if job.to_string().len() > 32768 {
        return fail("job_definition_too_large");
    }
    let trigger = &job["trigger"];
    match trigger["kind"].as_str().unwrap_or("") {
        "event" => {
            if !ident(trigger["topic"].as_str().unwrap_or("")) {
                return fail("event_topic_required");
            }
        }
        "schedule" => {
            if !matches!(trigger["every_seconds"].as_u64(), Some(1..=31536000)) {
                return fail("invalid_schedule_interval");
            }
        }
        "file" => {
            if !Path::new(trigger["path"].as_str().unwrap_or("")).is_absolute() {
                return fail("file_trigger_needs_absolute_directory");
            }
        }
        "cdp" => {
            let url = trigger["websocket_url"].as_str().unwrap_or("");
            if !(url.starts_with("ws://127.0.0.1:") || url.starts_with("ws://localhost:"))
                || !url.contains("/devtools/page/")
            {
                return fail("cdp_requires_explicit_loopback_page_websocket");
            }
            if !ident(trigger["binding"].as_str().unwrap_or("")) {
                return fail("cdp_binding_required");
            }
        }
        _ => return fail("unknown_job_trigger"),
    }
    let action = &job["action"];
    match action["kind"].as_str().unwrap_or("") {
        "wake" => {
            if action["session"].as_str().unwrap_or("").is_empty()
                || action["prompt"].as_str().unwrap_or("").trim().is_empty()
            {
                return fail("wake_needs_session_and_prompt");
            }
            if let Some(skill) = action["skill"].as_str() {
                if !ident(skill) {
                    return fail("invalid_skill_name");
                }
            }
        }
        "run" => {
            if !Path::new(action["script"].as_str().unwrap_or("")).is_absolute() {
                return fail("run_needs_absolute_allowlisted_script");
            }
        }
        _ => return fail("job_action_must_be_wake_or_run"),
    }
    if let Some(value) = action.get("timeout_seconds") {
        if !matches!(value.as_u64(), Some(1..=86400)) {
            return fail("invalid_action_timeout");
        }
    }
    Ok(())
}
impl Store {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }
    fn db(&self) -> Result<Connection> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let db = Connection::open(&self.path)?;
        db.busy_timeout(Duration::from_secs(2))?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
          CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,enabled INTEGER NOT NULL,definition TEXT NOT NULL,next_at INTEGER NOT NULL DEFAULT 0,source_status TEXT NOT NULL DEFAULT 'not observed');
          CREATE TABLE IF NOT EXISTS deliveries(id INTEGER PRIMARY KEY AUTOINCREMENT,job_id TEXT NOT NULL,revision INTEGER NOT NULL,event_id TEXT NOT NULL,payload TEXT NOT NULL,action_kind TEXT NOT NULL,state TEXT NOT NULL,created_at INTEGER NOT NULL,started_at INTEGER,ended_at INTEGER,detail TEXT,UNIQUE(job_id,revision,event_id));
          CREATE TABLE IF NOT EXISTS source_cursors(job_id TEXT NOT NULL,revision INTEGER NOT NULL,key TEXT NOT NULL,PRIMARY KEY(job_id,revision,key));")?;
        Ok(db)
    }
    pub fn put(&self, definition: &Value) -> Result<Value> {
        validate(definition)?;
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let id = definition["id"].as_str().unwrap();
        // Editing invalidates approval, including edits to the trigger or instruction.
        tx.execute("INSERT INTO jobs(id,revision,enabled,definition) VALUES(?1,1,0,?2) ON CONFLICT(id) DO UPDATE SET revision=revision+1,enabled=0,definition=excluded.definition,next_at=0,source_status='not observed'",params![id,definition.to_string()])?;
        tx.execute("UPDATE deliveries SET state='cancelled',detail='definition changed' WHERE job_id=? AND state='queued'",[id])?;
        tx.commit()?;
        self.get(id)
    }
    pub fn get(&self, id: &str) -> Result<Value> {
        self.list()?
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["id"] == id)
            .cloned()
            .ok_or_else(|| "job_not_found".into())
    }
    pub fn list(&self) -> Result<Value> {
        let db = self.db()?;
        let mut statement = db
            .prepare("SELECT id,revision,enabled,definition,source_status FROM jobs ORDER BY id")?;
        let mut values = Vec::new();
        for row in statement.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, bool>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, String>(4)?,
            ))
        })? {
            let (id, revision, enabled, definition, status) = row?;
            let mut value: Value = serde_json::from_str(&definition)?;
            value["id"] = json!(id);
            value["revision"] = json!(revision);
            value["enabled"] = json!(enabled);
            value["source_status"] = json!(status);
            let pending: i64 = db.query_row(
                "SELECT count(*) FROM deliveries WHERE job_id=? AND state='queued'",
                [&id],
                |r| r.get(0),
            )?;
            let last: Option<(String, Option<String>)> = db
                .query_row(
                    "SELECT state,detail FROM deliveries WHERE job_id=? ORDER BY id DESC LIMIT 1",
                    [&id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            value["queued"] = json!(pending);
            if let Some((state, detail)) = last {
                value["last_delivery"] = json!({"state":state,"detail":detail});
            }
            values.push(value);
        }
        Ok(json!(values))
    }
    pub fn enable(&self, id: &str, enabled: bool) -> Result<Value> {
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        if tx.execute("UPDATE jobs SET enabled=?, revision=revision+1,next_at=0,source_status='not observed' WHERE id=?",params![enabled,id])?!=1 {return fail("job_not_found")}
        tx.execute("UPDATE deliveries SET state='cancelled',detail='enable state changed' WHERE job_id=? AND state='queued'",[id])?;
        tx.commit()?;
        self.get(id)
    }
    pub fn enqueue(
        &self,
        id: &str,
        revision: i64,
        event_id: &str,
        payload: &Value,
        now: i64,
    ) -> Result<bool> {
        if event_id.is_empty() || event_id.len() > 256 || payload.to_string().len() > 16384 {
            return fail("invalid_event_size_or_id");
        }
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let enabled = tx
            .query_row(
                "SELECT enabled AND revision=? FROM jobs WHERE id=?",
                params![revision, id],
                |r| r.get::<_, bool>(0),
            )
            .optional()?
            .unwrap_or(false);
        if !enabled {
            return Ok(false);
        }
        let existing: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM deliveries WHERE job_id=? AND revision=? AND event_id=?)",
            params![id, revision, event_id],
            |r| r.get(0),
        )?;
        if existing {
            return Ok(false);
        }
        let pending: i64 = tx.query_row(
            "SELECT count(*) FROM deliveries WHERE state='queued'",
            [],
            |r| r.get(0),
        )?;
        let own: i64 = tx.query_row(
            "SELECT count(*) FROM deliveries WHERE job_id=? AND state='queued'",
            [id],
            |r| r.get(0),
        )?;
        if pending >= 128 || own >= 8 {
            return fail("job_queue_full; event not acknowledged");
        }
        tx.execute("INSERT INTO deliveries(job_id,revision,event_id,payload,action_kind,state,created_at) SELECT ?1,?2,?3,?4,json_extract(definition,'$.action.kind'),'queued',?5 FROM jobs WHERE id=?1",params![id,revision,event_id,payload.to_string(),now])?;
        tx.commit()?;
        Ok(true)
    }
    pub fn emit(&self, topic: &str, event_id: &str, payload: &Value, now: i64) -> Result<u64> {
        if !ident(topic) {
            return fail("invalid_event_topic");
        }
        let mut count = 0;
        for job in self.list()?.as_array().unwrap() {
            if job["enabled"] == true
                && job["trigger"]["kind"] == "event"
                && job["trigger"]["topic"] == topic
                && self.enqueue(
                    job["id"].as_str().unwrap(),
                    job["revision"].as_i64().unwrap(),
                    event_id,
                    payload,
                    now,
                )?
            {
                count += 1;
            }
        }
        Ok(count)
    }
    pub fn schedule(&self, now: i64) -> Result<u64> {
        let mut count = 0;
        for job in self.list()?.as_array().unwrap() {
            if job["enabled"] != true || job["trigger"]["kind"] != "schedule" {
                continue;
            }
            let id = job["id"].as_str().unwrap();
            let rev = job["revision"].as_i64().unwrap();
            let every = job["trigger"]["every_seconds"].as_i64().unwrap();
            let db = self.db()?;
            let next: i64 =
                db.query_row("SELECT next_at FROM jobs WHERE id=?", [id], |r| r.get(0))?;
            if next == 0 {
                db.execute(
                    "UPDATE jobs SET next_at=? WHERE id=? AND revision=?",
                    params![now + every, id, rev],
                )?;
                continue;
            }
            if now >= next {
                if self.enqueue(
                    id,
                    rev,
                    &format!("schedule:{next}"),
                    &json!({"scheduled_at":next}),
                    now,
                )? {
                    count += 1;
                }
                db.execute(
                    "UPDATE jobs SET next_at=? WHERE id=? AND revision=?",
                    params![now + every, id, rev],
                )?;
            }
        }
        Ok(count)
    }
    pub fn source_status(&self, id: &str, revision: i64, status: &str) -> Result<()> {
        self.db()?.execute(
            "UPDATE jobs SET source_status=? WHERE id=? AND revision=?",
            params![status, id, revision],
        )?;
        Ok(())
    }
    pub fn seen(&self, id: &str, revision: i64, key: &str) -> Result<bool> {
        Ok(self.db()?.query_row(
            "SELECT EXISTS(SELECT 1 FROM source_cursors WHERE job_id=? AND revision=? AND key=?)",
            params![id, revision, key],
            |r| r.get(0),
        )?)
    }
    pub fn mark_seen(&self, id: &str, revision: i64, key: &str) -> Result<()> {
        self.db()?.execute(
            "INSERT OR IGNORE INTO source_cursors VALUES(?,?,?)",
            params![id, revision, key],
        )?;
        Ok(())
    }
    pub fn claim(&self, now: i64, wake_budget: i64) -> Result<Option<Value>> {
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        tx.execute("UPDATE deliveries SET state='cancelled',detail='disabled or superseded' WHERE state='queued' AND NOT EXISTS(SELECT 1 FROM jobs WHERE jobs.id=deliveries.job_id AND jobs.enabled=1 AND jobs.revision=deliveries.revision)",[])?;
        let mut statement=tx.prepare("SELECT d.id,d.job_id,d.revision,d.payload,j.definition FROM deliveries d JOIN jobs j ON j.id=d.job_id WHERE d.state='queued' AND NOT EXISTS(SELECT 1 FROM deliveries active WHERE active.job_id=d.job_id AND active.state='running') ORDER BY d.id")?;
        let rows = statement
            .query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(statement);
        for (id, job_id, revision, payload, definition) in rows {
            let job: Value = serde_json::from_str(&definition)?;
            if job["action"]["kind"] == "wake" {
                let used: i64 = tx.query_row(
                    "SELECT count(*) FROM deliveries WHERE started_at>=? AND action_kind='wake'",
                    [now - 3600],
                    |r| r.get(0),
                )?;
                if used >= wake_budget {
                    continue;
                }
            }
            tx.execute(
                "UPDATE deliveries SET state='running',started_at=? WHERE id=? AND state='queued'",
                params![now, id],
            )?;
            tx.commit()?;
            return Ok(Some(
                json!({"id":id,"job_id":job_id,"revision":revision,"event":serde_json::from_str::<Value>(&payload)?,"action":job["action"]}),
            ));
        }
        tx.commit()?;
        Ok(None)
    }
    pub fn current(&self, id: &str, revision: i64) -> Result<bool> {
        Ok(self
            .db()?
            .query_row(
                "SELECT enabled AND revision=? FROM jobs WHERE id=?",
                params![revision, id],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(false))
    }
    pub fn finish(&self, id: i64, state: &str, detail: &str, now: i64) -> Result<()> {
        if !["completed", "failed", "cancelled", "unknown"].contains(&state) {
            return fail("invalid_delivery_outcome");
        }
        if self.db()?.execute(
            "UPDATE deliveries SET state=?,detail=?,ended_at=? WHERE id=? AND state='running'",
            params![
                state,
                detail.chars().take(2000).collect::<String>(),
                now,
                id
            ],
        )? != 1
        {
            return fail("delivery_already_settled");
        }
        Ok(())
    }
    // Caller MUST hold the sentinel's exclusive runner lock. Never retry an ambiguous side effect.
    pub fn recover(&self, now: i64) -> Result<usize> {
        Ok(self.db()?.execute("UPDATE deliveries SET state='unknown',detail='sentinel restarted; reconcile external effects before retry',ended_at=? WHERE state='running'",[now])?)
    }
    pub fn history(&self) -> Result<Value> {
        let db = self.db()?;
        let mut stmt =
            db.prepare("SELECT id,job_id,state,detail FROM deliveries ORDER BY id DESC LIMIT 100")?;
        let rows=stmt.query_map([],|r|Ok(json!({"id":r.get::<_,i64>(0)?,"job_id":r.get::<_,String>(1)?,"state":r.get::<_,String>(2)?,"detail":r.get::<_,Option<String>>(3)?})))?.collect::<std::result::Result<Vec<_>,_>>()?;
        Ok(json!(rows))
    }
}
#[cfg(test)]
mod tests;
