//! Native child evidence is separate from decimal HTTP admissions. No pruning or replay of work.
use rusqlite::{params, Connection, OpenFlags};
use serde_json::{json, Value};
use std::path::Path;

pub fn create(path: &Path) -> Result<(), String> {
    let db = Connection::open(path).map_err(|e| e.to_string())?;
    db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
        CREATE TABLE events(seq INTEGER PRIMARY KEY, payload TEXT NOT NULL,
            message_seq INTEGER NOT NULL DEFAULT 0);").map_err(|e| e.to_string())
}

pub fn append(path: &Path, payload: &str) -> Result<(), String> {
    let event: Value = serde_json::from_str(payload).map_err(|e| e.to_string())?;
    let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)
        .map_err(|e| e.to_string())?;
    db.execute_batch("PRAGMA synchronous=FULL;").map_err(|e| e.to_string())?;
    let checkpoint = if event["type"] == "checkpoint" { event["seq"].as_u64().unwrap_or(0) } else { 0 };
    db.execute("INSERT INTO events(payload,message_seq) VALUES(?,?)", params![payload,checkpoint])
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn page(path: &Path, after: u64, archive: bool) -> Result<Value, String> {
    let mut db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| format!("native_event_evidence_unavailable: {e}"))?;
    let tx = db.transaction().map_err(|e| e.to_string())?;
    let (checkpoint, message): (u64,u64) = tx.query_row(
        "SELECT seq,message_seq FROM events WHERE message_seq>0 ORDER BY seq DESC LIMIT 1", [],
        |row| Ok((row.get(0)?,row.get(1)?))).or_else(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => Ok((0,0)), other => Err(other)
        }).map_err(|e| e.to_string())?;
    let latest: u64 = tx.query_row("SELECT COALESCE(MAX(seq),0) FROM events",[],|r|r.get(0)).map_err(|e| e.to_string())?;
    if after>latest { return Err("native_event_cursor_out_of_range".into()); }
    let start = if archive { after } else { after.max(checkpoint) };
    let mut stmt = tx.prepare("SELECT seq,payload FROM events WHERE seq>? ORDER BY seq LIMIT 256").map_err(|e|e.to_string())?;
    let rows = stmt.query_map([start], |r| Ok((r.get::<_,u64>(0)?,r.get::<_,String>(1)?))).map_err(|e|e.to_string())?;
    let mut events=Vec::new();let mut next=start;
    for row in rows { let (seq,payload)=row.map_err(|e|e.to_string())?;
        events.push(json!({"seq":seq,"event":serde_json::from_str::<Value>(&payload).map_err(|e|e.to_string())?}));next=seq;
    }
    Ok(json!({"durable":true,"archive":archive,"checkpoint_seq":checkpoint,"checkpoint_message_seq":message,
        "events":events,"next_seq":next,"latest_seq":latest,"has_more":next<latest}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn indexed_pages_preserve_raw_content_and_checkpoint_after_reopen() {
        let root=std::env::temp_dir().join(format!("wa-native-journal-{}-{}",std::process::id(),super::super::now_ms()));
        std::fs::create_dir_all(&root).unwrap();let path=root.join("events.sqlite");
        assert!(page(&path,0,false).unwrap_err().contains("unavailable"));
        create(&path).unwrap();
        for i in 0..600 { append(&path,&json!({"type":"delta","text":format!("原始 {i}\n")}).to_string()).unwrap(); }
        let first=page(&path,0,true).unwrap();assert_eq!(first["events"].as_array().unwrap().len(),256);
        assert_eq!(first["events"][0]["event"]["text"],"原始 0\n");assert_eq!(first["next_seq"],256);
        let second=page(&path,256,true).unwrap();assert_eq!(second["events"][0]["seq"],257);
        append(&path,r#"{"type":"checkpoint","seq":42}"#).unwrap();
        append(&path,r#"{"type":"reasoning","text":"exact tail"}"#).unwrap();
        let live=page(&path,0,false).unwrap();assert_eq!(live["checkpoint_seq"],601);
        assert_eq!(live["checkpoint_message_seq"],42);assert_eq!(live["events"][0]["seq"],602);
        assert!(page(&path,603,false).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
