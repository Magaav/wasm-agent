//! Durable automation definitions and deliveries. No model calls or shell execution here.
//! A job is a disabled-by-default trigger + declared action. A delivery pins its revision.
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};
pub mod artifact;
pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
#[derive(Clone)]
pub struct Store {
    path: PathBuf,
}
fn fail<T>(why: &str) -> Result<T> {
    Err(why.into())
}
fn ident(s: &str) -> bool {
    ident_str(s)
}
/// Does this action need a model? `wake` and `subagent` do; `run` does not; a `pipeline` does when any of
/// its steps does. The lanes are decided from the *action*, not from its kind name: a pipeline that starts
/// a child must never be claimed on the deterministic lane, or it would push a person's turn aside - the
/// property the two lanes exist to keep.
pub fn action_is_inference(action: &Value) -> bool {
    match action["kind"].as_str().unwrap_or("") {
        "wake" | "subagent" => true,
        "pipeline" => action["steps"]
            .as_array()
            .map(|steps| steps.iter().any(step_is_inference))
            .unwrap_or(false),
        _ => false,
    }
}

fn step_is_inference(step: &Value) -> bool {
    match step["kind"].as_str().unwrap_or("") {
        "wake" | "subagent" => true,
        "foreach" => step_is_inference(&step["step"]),
        _ => false,
    }
}

fn ident_str(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 100
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
}
/// The controls a job may carry, and **only** these. A control is a whole number of seconds that the
/// job's own deterministic steps read from their environment, so the surface stays small enough to
/// reason about: a second way to express one of them is a second way for the two to disagree. A name
/// that is not here is refused by `validate_controls` rather than accepted and ignored.
pub const JOB_CONTROLS: &[&str] = &["grace_seconds", "max_age_seconds"];

/// The environment name one control arrives in. The sentinel is not the WhatsApp pipeline: it passes
/// `WA_JOB_CONTROL_<NAME>` to every deterministic step, and a step's own script decides what that number
/// means. `scripts/whatsapp-read.mjs` is the reader of these two.
pub fn control_env_name(control: &str) -> String {
    format!("WA_JOB_CONTROL_{}", control.to_ascii_uppercase())
}

/// The controls as (name, value) environment pairs, in a stable order, or nothing when the job carries
/// none. Values are read with `as_u64`, so a control that `validate_controls` refused (a string, a
/// negative number, a fraction) cannot reach a step by another route.
pub fn control_env(controls: &Value) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    for name in JOB_CONTROLS {
        if let Some(seconds) = controls.get(name).and_then(Value::as_u64) {
            pairs.push((control_env_name(name), seconds.to_string()));
        }
    }
    pairs
}

/// A job's optional `controls`, validated.
///
/// Three refusals, each for a way a control can be configured into something nobody can observe:
///
///   - a name outside `JOB_CONTROLS` is refused, not ignored: a definition that carries a knob no step
///     reads looks configured and is not;
///   - a value must be whole seconds in range - `max_age_seconds` needs at least 1, because a hard bound
///     of zero refuses every message and is indistinguishable from a job that does nothing;
///   - `grace_seconds` may not exceed `max_age_seconds`: the prompt window is derived as what is left of
///     the bound, so a grace band wider than the bound would make the derived window silently empty.
///
/// The action must be one whose steps can read the environment. A `wake` or `subagent` action cannot, and
/// carrying controls it would never apply is the silent no-op this refuses by name.
pub fn validate_controls(job: &Value) -> Result<()> {
    let Some(controls) = job.get("controls") else {
        return Ok(());
    };
    let map = match controls.as_object() {
        Some(map) => map,
        None => return fail("job_controls_must_be_an_object"),
    };
    match job["action"]["kind"].as_str().unwrap_or("") {
        "run" | "pipeline" => {}
        _ => return fail("job_controls_need_a_deterministic_action"),
    }
    let max_allowed = 86400;
    for (name, value) in map {
        if !JOB_CONTROLS.contains(&name.as_str()) {
            return fail(&format!("unknown_job_control:{name}"));
        }
        let Some(seconds) = value.as_u64() else {
            return fail(&format!("job_control_must_be_whole_seconds:{name}"));
        };
        let floor = if name == "max_age_seconds" { 1 } else { 0 };
        if seconds < floor || seconds > max_allowed {
            return fail(&format!("job_control_out_of_range:{name}"));
        }
    }
    let grace = map.get("grace_seconds").and_then(Value::as_u64);
    let max_age = map.get("max_age_seconds").and_then(Value::as_u64);
    if let (Some(grace), Some(max_age)) = (grace, max_age) {
        if grace > max_age {
            return fail("job_control_grace_exceeds_max_age_seconds");
        }
    }
    Ok(())
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
    validate_action(&job["action"])?;
    // After the action, so a malformed action is reported as itself rather than as a control it could
    // not have carried.
    validate_controls(job)
}

/// One action, validated. Split out of `validate` because a `pipeline` validates each of its steps with
/// exactly these rules: a nested step must not be able to be something the action level would refuse.
pub fn validate_action(action: &Value) -> Result<()> {
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
            if let Some(profile) = action.get("profile").and_then(Value::as_str) {
                if !ident(profile) {
                    return fail("invalid_action_profile");
                }
            }
        }
        // A durable child run with its own capacity and a profile-scoped tool envelope. Distinct from
        // `wake`, which is the legacy operator-chat route: a subagent action never falls back to `/chat`
        // because the whole point of the profile is that the run cannot reach the operator's tools.
        "subagent" => {
            if !action.get("profile").and_then(Value::as_str).map(|p| ident_str(p)).unwrap_or(false) {
                return fail("subagent_needs_profile");
            }
            if action["prompt"].as_str().unwrap_or("").trim().is_empty() {
                return fail("subagent_needs_prompt");
            }
            if action.get("timeout_seconds").is_some() {
                if !matches!(action["timeout_seconds"].as_u64(), Some(1..=86400)) {
                    return fail("invalid_action_timeout");
                }
            }
        }
        "run" => {
            if !Path::new(action["script"].as_str().unwrap_or("")).is_absolute() {
                return fail("run_needs_absolute_allowlisted_script");
            }
        }
        // A chain of steps in one delivery: deterministic and inference steps together. A job is one
        // trigger + one action, so this is what lets "read, decide, report" be a single job instead of two
        // joined by an event - while keeping the per-step identity the event seam used to provide.
        "pipeline" => {
            let steps = match action["steps"].as_array() {
                Some(steps) if !steps.is_empty() => steps,
                _ => return fail("pipeline_needs_steps"),
            };
            if steps.len() > 32 {
                return fail("pipeline_too_many_steps");
            }
            for (index, step) in steps.iter().enumerate() {
                let number = index + 1;
                match step["kind"].as_str().unwrap_or("") {
                    "run" => {
                        if !Path::new(step["script"].as_str().unwrap_or("")).is_absolute() {
                            return fail(&format!("step_{number}_run_needs_absolute_script"));
                        }
                        if let Some(name) = step.get("returns") {
                            if !name.as_str().map(ident_str).unwrap_or(false) {
                                return fail(&format!("step_{number}_returns_must_be_a_name"));
                            }
                        }
                    }
                    "foreach" => {
                        if !step["from"].as_str().map(ident_str).unwrap_or(false) {
                            return fail(&format!("step_{number}_foreach_needs_from"));
                        }
                        if !step["key"].as_str().map(ident_str).unwrap_or(false) {
                            return fail(&format!("step_{number}_foreach_needs_key"));
                        }
                        if !matches!(step["max"].as_u64(), Some(1..=64)) {
                            return fail(&format!("step_{number}_foreach_max_out_of_range"));
                        }
                        let inner = &step["step"];
                        // The inner step is what spends the money, so it must be a `subagent` - the child
                        // service's capacity is what bounds it. A `wake` is refused: its allowance is
                        // counted per hour in one place, and a loop is not that place.
                        if inner["kind"].as_str() != Some("subagent") {
                            return fail(&format!("step_{number}_foreach_step_must_be_a_subagent"));
                        }
                        validate_action(inner)?;
                    }
                    // A `wake` step is refused for the same reason: one budget, spent in one place.
                    "subagent" => validate_action(step)?,
                    "wake" => return fail(&format!("step_{number}_wake_not_allowed_in_pipeline")),
                    _ => return fail(&format!("step_{number}_unknown_kind")),
                }
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
          CREATE TABLE IF NOT EXISTS source_cursors(job_id TEXT NOT NULL,revision INTEGER NOT NULL,key TEXT NOT NULL,PRIMARY KEY(job_id,revision,key));
          CREATE INDEX IF NOT EXISTS deliveries_queue ON deliveries(state,id);
          CREATE INDEX IF NOT EXISTS deliveries_job_state ON deliveries(job_id,state);
          CREATE INDEX IF NOT EXISTS deliveries_job_recent ON deliveries(job_id,id DESC);
          CREATE INDEX IF NOT EXISTS deliveries_wake_budget ON deliveries(action_kind,started_at);")?;
        Ok(db)
    }
    pub fn put(&self, definition: &Value) -> Result<Value> {
        validate(definition)?;
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let id = definition["id"].as_str().unwrap();
        let prepared = definition.to_string();
        // A put that says nothing new must not invalidate anything. A delivery is pinned to a revision, so
        // bumping the revision cancels every queued delivery for this job - and that is not hypothetical: a
        // re-deploy that re-sent a byte-identical job turned eight freshly ingested messages into
        // `definition changed`/`cancelled` rows. An import may be repeated safely, so it has to be a no-op.
        let unchanged: bool = tx
            .query_row(
                "SELECT definition=?2 FROM jobs WHERE id=?1",
                params![id, prepared],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(false);
        if unchanged {
            tx.commit()?;
            return self.get(id);
        }
        // Editing invalidates approval, including edits to the trigger or instruction.
        tx.execute("INSERT INTO jobs(id,revision,enabled,definition) VALUES(?1,1,0,?2) ON CONFLICT(id) DO UPDATE SET revision=revision+1,enabled=0,definition=excluded.definition,next_at=0,source_status='not observed'",params![id,prepared])?;
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
    /// Remove a job and everything the store keeps for it.
    ///
    /// `disable` leaves the row, and a row that is off on purpose is indistinguishable from one that is
    /// off because its definition changed - so the board cannot say what is meant to run. Forgetting is
    /// the deliberate act that makes it say only that, and it is the only way to remove a job whose
    /// template is no longer shipped at all.
    ///
    /// Refuses while a delivery of it is queued or running: a child whose job no longer exists would
    /// have nowhere to record its result, and that is not a decision the store may make for the operator.
    pub fn forget(&self, id: &str) -> Result<Value> {
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let active: i64 = tx.query_row(
            "SELECT COUNT(*) FROM deliveries WHERE job_id=? AND state IN ('queued','running')",
            params![id],
            |r| r.get(0),
        )?;
        if active > 0 {
            return fail("job_has_active_delivery");
        }
        if tx.execute("DELETE FROM jobs WHERE id=?", params![id])? != 1 {
            return fail("job_not_found");
        }
        tx.execute("DELETE FROM deliveries WHERE job_id=?", params![id])?;
        tx.execute("DELETE FROM source_cursors WHERE job_id=?", params![id])?;
        tx.commit()?;
        Ok(json!({"id": id, "forgotten": true}))
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
                match self.enqueue(
                    id,
                    rev,
                    &format!("schedule:{next}"),
                    &json!({"scheduled_at":next}),
                    now,
                ) {
                    Ok(true) => count += 1,
                    Ok(false) => {}
                    // A scheduled tick is this store's *own* event, so a full queue is
                    // backpressure, not a failure: the deliveries already queued have not been
                    // consumed yet. Failing the whole tick logged `jobs-error tick
                    // job_queue_full` every second and retried forever; skipping one interval
                    // lets the queue drain and the next interval enqueue again. An external
                    // `emit` is different - it must not be silently dropped, so it still errors
                    // and its source backs off (cdp.rs).
                    Err(error) if error.to_string().starts_with("job_queue_full") => {
                        let _ = self.source_status(
                            id,
                            rev,
                            "backpressure: delivery queue full; skipped this interval",
                        );
                    }
                    Err(error) => return Err(error),
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
            "UPDATE jobs SET source_status=?1 WHERE id=?2 AND revision=?3 AND source_status<>?1",
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
    /// Claim the next delivery. `allow_inference` separates the two lanes explicitly: a deterministic
    /// `run` action never waits behind a person's interactive turn, and an inference action (`wake` or
    /// `subagent`) is only claimed when its own lane has capacity. The wake budget is spent only by
    /// legacy `wake`; a `subagent` has its own reserved child capacity in the subagent service.
    pub fn claim(&self, now: i64, wake_budget: i64) -> Result<Option<Value>> {
        self.claim_next(now, wake_budget, true)
    }
    pub fn claim_next(&self, now: i64, wake_budget: i64, allow_inference: bool) -> Result<Option<Value>> {
        if allow_inference {
            self.claim_kinds(now, wake_budget, None)
        } else {
            self.claim_kinds(now, wake_budget, Some(&["run"]))
        }
    }
    /// Claim only an inference delivery. The sentinel runs deterministic and inference work on their own
    /// lanes, so this is how the inference lane stays free of run deliveries. A `subagent` has reserved
    /// child capacity in the subagent service and therefore does not spend the legacy `wake` allowance.
    pub fn claim_inference(&self, now: i64, wake_budget: i64) -> Result<Option<Value>> {
        self.claim_kinds(now, wake_budget, Some(&["wake", "subagent"]))
    }
    fn claim_kinds(
        &self,
        now: i64,
        wake_budget: i64,
        kinds: Option<&[&str]>,
    ) -> Result<Option<Value>> {
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        tx.execute("UPDATE deliveries SET state='cancelled',detail='disabled or superseded' WHERE state='queued' AND NOT EXISTS(SELECT 1 FROM jobs WHERE jobs.id=deliveries.job_id AND jobs.enabled=1 AND jobs.revision=deliveries.revision)",[])?;
        let mut statement=tx.prepare("SELECT d.id,d.job_id,d.revision,d.event_id,d.payload,j.definition FROM deliveries d JOIN jobs j ON j.id=d.job_id WHERE d.state='queued' AND NOT EXISTS(SELECT 1 FROM deliveries active WHERE active.job_id=d.job_id AND active.state='running') ORDER BY d.id")?;
        let rows = statement
            .query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, String>(5)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(statement);
        for (id, job_id, revision, event_id, payload, definition) in rows {
            let job: Value = serde_json::from_str(&definition)?;
            let action = &job["action"];
            // Classified from the action, not from its kind name: a pipeline that starts a child is
            // inference, and must never be claimed on the lane that runs beside a person's turn.
            let inference = action_is_inference(action);
            if let Some(kinds) = kinds {
                let wanted = if inference {
                    kinds.iter().any(|kind| matches!(*kind, "wake" | "subagent"))
                } else {
                    kinds.contains(&"run")
                };
                if !wanted {
                    continue;
                }
            }
            if action["kind"].as_str() == Some("wake") {
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
                // The controls ride with the action, from the same definition row this delivery was
                // claimed against: a delivery pins its revision, so reading the *current* definition
                // later would apply a knob that was never approved for this delivery. `null` when the
                // job carries none, which is what `control_env` reads as no pairs.
                json!({"id":id,"job_id":job_id,"revision":revision,"event_id":event_id,"event":serde_json::from_str::<Value>(&payload)?,"action":job["action"],"controls":job.get("controls").cloned().unwrap_or(Value::Null)}),
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
    /// Put a claimed delivery back in the queue, because the reason it could not run is temporary.
    ///
    /// The wake budget is the case this exists for: a model turn that is refused for budget has not had an
    /// ambiguous side effect - nothing happened at all - so marking it `failed` throws away a delivery that
    /// only needed to wait. Clearing `started_at` also keeps the refusal from spending the allowance it was
    /// refused from, which `claim` counts from `started_at`.
    pub fn defer(&self, id: i64, detail: &str) -> Result<()> {
        if self.db()?.execute(
            "UPDATE deliveries SET state='queued',started_at=NULL,detail=? WHERE id=? AND state='running'",
            params![detail.chars().take(2000).collect::<String>(), id],
        )? != 1
        {
            return fail("delivery_not_running");
        }
        Ok(())
    }
    /// Export an installed job as a portable, machine-independent artifact.
    pub fn export_job(&self, id: &str) -> Result<Value> {
        artifact::export_artifact(&self.get(id)?)
    }
    /// Import a portable artifact with explicit local bindings. Always installs disabled; `put` keeps the
    /// revision no-op rule, so a repeated identical import changes nothing and a changed one invalidates
    /// approval. `approved` authorises the *bindings*, never the enabling. `importer_role` is the caller's
    /// authority, so a guest import cannot select operator capabilities by claiming them.
    pub fn put_artifact(
        &self,
        artifact: &Value,
        bindings: &Value,
        approved: bool,
        importer_role: &str,
    ) -> Result<Value> {
        let imported = artifact::import_artifact(artifact, bindings, approved, importer_role)?;
        let stored = self.put(&imported["definition"])?;
        Ok(json!({"job": stored, "bound": imported["bound"], "artifact": imported["artifact"]}))
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
