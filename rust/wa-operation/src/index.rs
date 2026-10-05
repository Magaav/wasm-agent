//! Relevant-operation lookup and reconciliation. State/output originals are never rewritten.
use crate::{error, validate_id};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::{fs, io, path::{Path, PathBuf}, sync::Mutex, time::{Duration, SystemTime, UNIX_EPOCH}};

pub(crate) struct Index {
    root: PathBuf,
    pub boot: String,
    db: Mutex<Connection>,
    _lease: Mutex<Connection>,
}
fn path_key(path: &str) -> String {
    let path = path.replace('\\', "/");
    let path = path.strip_prefix("//?/").unwrap_or(&path).trim_end_matches('/').to_string();
    if cfg!(windows) { path.to_lowercase() } else { path }
}
fn unresolved(state: &Value) -> bool {
    state["settled"] != true || state["cleanup"] == "unknown" || !state["persistence_error"].is_null()
}
impl Index {
    pub fn open(root: &Path) -> io::Result<Self> {
        fs::create_dir_all(root)?;
        // Only a new empty store can claim completeness without migration. Existing
        // stores require an explicit import after old runtimes have been quiesced.
        let empty = fs::read_dir(root)?.next().is_none();
        let boot = format!("boot-{}-{}-{}", std::process::id(), SystemTime::now().duration_since(UNIX_EPOCH).map_err(error)?.as_nanos(), crate::SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
        let lease = Connection::open(root.join(format!("{boot}.lease.sqlite"))).map_err(error)?;
        lease.execute_batch("PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE").map_err(error)?;
        let db = Connection::open(root.join("index.sqlite")).map_err(error)?;
        db.busy_timeout(Duration::from_secs(5)).map_err(error)?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
          CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY,cwd TEXT NOT NULL,blocked INTEGER NOT NULL,state TEXT NOT NULL,originals TEXT NOT NULL);
          CREATE INDEX IF NOT EXISTS relevant ON operations(blocked,cwd,id);
          CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS reconciliation(id TEXT PRIMARY KEY,expected TEXT NOT NULL,evidence TEXT NOT NULL,at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
          CREATE TABLE IF NOT EXISTS legacy_quarantine(id TEXT PRIMARY KEY,expected TEXT NOT NULL,bundle TEXT NOT NULL,receipt TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS history(at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,action TEXT NOT NULL,id TEXT NOT NULL,evidence TEXT NOT NULL);").map_err(error)?;
        if empty { db.execute("INSERT OR IGNORE INTO meta VALUES('complete','new-store')", []).map_err(error)?; }
        Ok(Self { root: root.into(), boot, db: Mutex::new(db), _lease: Mutex::new(lease) })
    }
    pub fn record(&self, state: &Value) -> io::Result<()> {
        let id = state["operation_id"].as_str().ok_or_else(|| error("operation_id_required"))?;
        let db = self.db.lock().map_err(error)?;
        db.execute("INSERT INTO operations VALUES(?,?,?,?, '[]') ON CONFLICT(id) DO UPDATE SET cwd=excluded.cwd,blocked=excluded.blocked,state=excluded.state",
            params![id,path_key(state["effective_cwd"].as_str().or_else(|| state["cwd"].as_str()).unwrap_or("")), unresolved(state),state.to_string()]).map_err(error)?;
        Ok(())
    }
    pub fn import(&self, evidence: &str) -> io::Result<Value> {
        if evidence.trim().is_empty() { return Err(error("legacy_writer_quiescence_evidence_required")); }
        let mut db = self.db.lock().map_err(error)?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(error)?;
        let mut imported = 0;
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            if !entry.file_type()?.is_dir() { continue; }
            let id = entry.file_name().to_string_lossy().to_string();
            validate_id(&id)?;
            let state: Value = serde_json::from_slice(&fs::read(entry.path().join("state.json"))?).map_err(error)?;
            let mut originals = Vec::new();
            // Historical hand edits are evidence, not authoritative settlement. An
            // unresolved original requires separate reconciliation, even if the current
            // record claims never_spawned/terminated from age or zero output.
            let mut blocked = unresolved(&state);
            let mut cwd = path_key(state["effective_cwd"].as_str().or_else(|| state["cwd"].as_str()).unwrap_or(""));
            let mut attributed = blocked;
            for original in fs::read_dir(entry.path())? {
                let original = original?;
                if original.file_name().to_string_lossy().starts_with("state.json.before-reconcile-") {
                    let old: Value = serde_json::from_slice(&fs::read(original.path())?).map_err(error)?;
                    if unresolved(&old) {
                        let old_cwd=path_key(old["effective_cwd"].as_str().or_else(|| old["cwd"].as_str()).unwrap_or(""));
                        if attributed && cwd!=old_cwd { cwd=String::new(); }
                        else if !attributed { cwd=old_cwd; }
                        attributed=true;
                        blocked=true;
                    }
                    originals.push(json!({"path":original.path(),"state":old}));
                }
            }
            // A current-format writer may already have admitted this row. Never
            // overwrite a concurrently recorded operation or its reconciliation.
            tx.execute("INSERT OR IGNORE INTO operations VALUES(?,?,?,?,?)", params![id,cwd,blocked,state.to_string(),json!(originals).to_string()]).map_err(error)?;
            imported += 1;
        }
        tx.execute("INSERT OR REPLACE INTO meta VALUES('complete',?)", [evidence]).map_err(error)?;
        tx.execute("INSERT INTO history(action,id,evidence) VALUES('import','*',?)", [evidence]).map_err(error)?;
        tx.commit().map_err(error)?;
        Ok(json!({"ok":true,"imported":imported,"note":"Original evidence retained; unknown effects were not settled."}))
    }
    pub fn relevant(&self, cwd: &str, after: &str, limit: usize) -> io::Result<Value> {
        if cwd.is_empty() { return Err(error("effective_cwd_required")); }
        let target = path_key(cwd);
        let db = self.db.lock().map_err(error)?;
        if db.query_row("SELECT value FROM meta WHERE key='complete'", [], |row| row.get::<_,String>(0)).optional().map_err(error)?.is_none() {
            return Err(error("operation_index_import_required: quiesce legacy writers and import originals"));
        }
        let limit = limit.clamp(1, 256);
        // Range comparisons use the cwd index; LIKE would make Windows case folding
        // and wildcard paths ambiguous. Empty legacy attribution is always relevant.
        let prefix = format!("{target}/");
        let upper = format!("{target}0");
        let mut query = db.prepare("SELECT id,state,originals FROM operations o WHERE blocked=1 AND id>? AND (?='*' OR cwd='' OR cwd=? OR (cwd>=? AND cwd<?)) AND NOT EXISTS(SELECT 1 FROM reconciliation r WHERE r.id=o.id AND r.expected=o.state) ORDER BY id LIMIT 257").map_err(error)?;
        let rows = query.query_map(params![after,target,target,prefix,upper], |row| Ok((row.get::<_,String>(0)?,row.get::<_,String>(1)?,row.get::<_,String>(2)?))).map_err(error)?;
        let mut operations = Vec::new();
        let mut examined=0;let mut last=String::new();let mut quarantined=0;
        for row in rows {
            let (id, state, originals) = row.map_err(error)?;
            examined+=1;last=id.clone();
            let bundle=db.query_row("SELECT bundle FROM legacy_quarantine WHERE id=? AND expected=?",params![id,state],|r|r.get::<_,String>(0)).optional().map_err(error)?;
            if let Some(bundle)=bundle {
                let bundle:Value=serde_json::from_str(&bundle).map_err(error)?;
                if crate::legacy::validate(&self.root,&bundle).is_ok(){quarantined+=1;continue;}
            }
            let state: Value = serde_json::from_str(&state).map_err(error)?;
            let originals: Value = serde_json::from_str(&originals).map_err(error)?;
            operations.push(json!({"operation_id":id,"state":state,"originals":originals}));
        }
        let more = operations.len() > limit || examined>256;
        operations.truncate(limit);
        let next = if more { Some(json!(operations.last().and_then(|v|v["operation_id"].as_str()).unwrap_or(&last))) } else { None };
        Ok(json!({"ok":true,"operations":operations,"next":next,"truncated":more,"lookup":"indexed-unresolved","quarantined_unknown_outcomes":quarantined}))
    }
    pub fn adjudicate_legacy(&self,args:&Value)->io::Result<Value>{
        let receipt=crate::legacy::validate(&self.root,args)?;
        let id=args["id"].as_str().ok_or_else(||error("legacy_id_required"))?;
        let mut db=self.db.lock().map_err(error)?;
        let tx=db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(error)?;
        let state:String=tx.query_row("SELECT state FROM operations WHERE id=?",[id],|r|r.get(0)).map_err(error)?;
        if state!=args["expected_state"].to_string(){return Err(error("legacy_index_state_moved"));}
        let previous=tx.query_row("SELECT bundle FROM legacy_quarantine WHERE id=?",[id],|r|r.get::<_,String>(0)).optional().map_err(error)?;
        if let Some(previous)=previous {
            if serde_json::from_str::<Value>(&previous).map_err(error)?!=*args{return Err(error("legacy_adjudication_bundle_moved"));}
            return crate::legacy::validate(&self.root,args);
        }
        crate::legacy::validate(&self.root,args)?;
        tx.execute("INSERT OR IGNORE INTO legacy_quarantine VALUES(?,?,?,?)",params![id,state,args.to_string(),receipt.to_string()]).map_err(error)?;
        tx.execute("INSERT INTO history(action,id,evidence) VALUES('legacy_allocation_safety',?,?)",params![id,receipt.to_string()]).map_err(error)?;
        tx.commit().map_err(error)?;
        Ok(receipt)
    }
    pub fn allocation_safety(&self,args:&Value)->io::Result<Value>{
        let id=args["id"].as_str().ok_or_else(||error("operation_id_required"))?;validate_id(id)?;
        let db=self.db.lock().map_err(error)?;
        let bundle=db.query_row("SELECT bundle FROM legacy_quarantine WHERE id=?",[id],|r|r.get::<_,String>(0)).optional().map_err(error)?;
        match bundle {Some(bundle)=>crate::legacy::validate(&self.root,&serde_json::from_str::<Value>(&bundle).map_err(error)?),None=>Err(error("legacy_allocation_safety_not_adjudicated"))}
    }
    pub fn reconcile(&self, args: &Value) -> io::Result<Value> {
        let required = |name: &str| args[name].as_str().filter(|s| !s.trim().is_empty()).ok_or_else(|| error(format!("{name}_required")));
        let id = required("id")?;
        validate_id(id)?;
        // Lua's ordinary JSON decoder maps null to nil, so decoding/re-encoding
        // a durable state loses fields (and can round large integers). Accept an
        // explicit raw JSON string without weakening exact object comparison.
        let raw_expected;
        let expected = if args.get("expected_state_json").is_some() {
            if args.get("expected_state").is_some() {
                return Err(error("expected_state_forms_exclusive"));
            }
            raw_expected = serde_json::from_str::<Value>(required("expected_state_json")?)
                .map_err(|_| error("expected_state_json_invalid"))?;
            raw_expected.as_object().ok_or_else(|| error("expected_state_json_object_required"))?
        } else {
            args["expected_state"].as_object().ok_or_else(|| error("expected_state_required"))?
        };
        required("evidence")?; required("drain_evidence")?; required("effect_evidence")?;
        let raw = fs::read(self.root.join(id).join("state.json"))?;
        let current: Value = serde_json::from_slice(&raw).map_err(error)?;
        if current.as_object() != Some(expected) { return Err(error("operation_state_moved")); }
        let boot = current["owner_boot"].as_str().filter(|s| !s.is_empty()).ok_or_else(|| error("legacy_operation_owner_identity_unknown"))?;
        if required("owner_boot")? != boot { return Err(error("operation_owner_mismatch")); }
        if !boot.starts_with("boot-") || boot.len()>100 || boot.bytes().any(|c| !c.is_ascii_alphanumeric() && c!=b'-') { return Err(error("invalid_owner_boot")); }
        let lease_path = self.root.join(format!("{boot}.lease.sqlite"));
        if !lease_path.is_file() { return Err(error("operation_owner_lease_missing")); }
        let lease = Connection::open(lease_path).map_err(error)?;
        lease.busy_timeout(Duration::ZERO).map_err(error)?;
        lease.execute_batch("BEGIN EXCLUSIVE").map_err(|_| error("operation_owner_live_or_unverifiable"))?;
        let mut db = self.db.lock().map_err(error)?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(error)?;
        // Holding the dead owner's lease fences another reconciler; PID reuse and
        // output silence never authorize this transition. Effects need their own proof.
        if fs::read(self.root.join(id).join("state.json"))? != raw { return Err(error("operation_state_moved")); }
        if tx.query_row("SELECT id FROM operations WHERE id=?", [id], |r| r.get::<_,String>(0)).optional().map_err(error)?.is_none() { return Err(error("operation_not_indexed")); }
        tx.execute("INSERT OR IGNORE INTO reconciliation(id,expected,evidence) VALUES(?,?,?)", params![id,current.to_string(),args.to_string()]).map_err(error)?;
        tx.execute("INSERT INTO history(action,id,evidence) VALUES('reconcile',?,?)", params![id,args.to_string()]).map_err(error)?;
        tx.commit().map_err(error)?;
        Ok(json!({"ok":true,"operation_id":id,"reconciled":true,"execution_outcome":"unchanged","original_preserved":true}))
    }
}
