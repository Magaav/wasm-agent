//! Durable observation of queued requests: what was asked, what is happening to it now, and how it ended.
//!
//! The `requests/` directory records *intent* and is consumed when the work starts. That is the right shape
//! for dispatch and the wrong shape for a person: once a request is claimed there is nothing left to read,
//! and a held request is only a line in a log. This module writes one small file per request under
//! `sentinel/queue/`, kept across the claim, so `status`, `/health` and the window can all answer
//! "queued for how long, doing what, and did it fail?" without parsing the log.
//!
//! It is observation only. Nothing here claims, performs or retries a request, and a missing or unreadable
//! record never changes dispatch.

use super::*;
use std::cell::RefCell;

thread_local! {
    /// The request this thread is performing right now, so `step()` can attach progress without threading an
    /// id through every verb. Empty outside `finish_request`; a stray call is a no-op, never an error.
    static PERFORMING: RefCell<Option<(String, Value)>> = const { RefCell::new(None) };
}

pub(crate) fn dir() -> PathBuf {
    let dir = sentinel_dir().join("queue");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// Request ids are `<epoch-nanos>-<pid>-<sequence>`; anything else cannot name a record file.
fn record_path(id: &str) -> Option<PathBuf> {
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        return None;
    }
    Some(dir().join(format!("{id}.json")))
}

fn clipped(value: Option<&Value>) -> String {
    value.and_then(Value::as_str).unwrap_or("").chars().take(400).collect()
}

fn clip(text: &str) -> String {
    text.chars().take(400).collect()
}

fn read_record(path: &Path) -> Option<Value> {
    std::fs::read(path).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok())
}

/// Record one observation. Repeated identical observations are skipped: the watcher ticks five times a
/// second and an unchanged "waiting" must not rewrite a file five times a second (or move its timestamp,
/// which is what "how long has this been stuck?" reads). Observation never fails a request: a record that
/// cannot be written is audited and dispatch continues.
pub(crate) fn observe(request: &Value, id: &str, state: &str, phase: &str, detail: &str) {
    if let Err(error) = write(request, id, state, phase, detail) {
        audit("queue-record-failed", id, &error.to_string());
    }
}

fn write(request: &Value, id: &str, state: &str, phase: &str, detail: &str) -> Result<()> {
    let Some(path) = record_path(id) else { return Ok(()) };
    let previous = read_record(&path);
    let verb = request.get("verb").and_then(Value::as_str).unwrap_or("(no verb recorded)");
    let queued_at = request
        .get("queued_at")
        .and_then(Value::as_u64)
        .or_else(|| previous.as_ref().and_then(|p| p["queued_at"].as_u64()))
        .unwrap_or_else(now_epoch);
    let previous_state = previous.as_ref().and_then(|p| p["state"].as_str()).unwrap_or("");
    let attempts = previous.as_ref().and_then(|p| p["attempts"].as_u64()).unwrap_or(0)
        + u64::from(state == "running" && previous_state != "running");
    let unchanged = previous.as_ref().is_some_and(|p| {
        p["verb"].as_str() == Some(verb)
            && p["state"].as_str() == Some(state)
            && p["phase"].as_str() == Some(phase)
            && p["detail"].as_str().unwrap_or("") == clip(detail)
            && p["attempts"].as_u64().unwrap_or(0) == attempts
    });
    if unchanged {
        return Ok(());
    }
    let record = json!({
        "schema": 1,
        "id": id,
        "verb": verb,
        "state": state,
        "phase": phase,
        "detail": clip(detail),
        "reason": clipped(request.get("reason")),
        "queued_at": queued_at,
        "updated_at": now_epoch(),
        "attempts": attempts,
    });
    wa_operation::atomic_json(&path, &record)?;
    if matches!(state, "done" | "failed") {
        prune();
    }
    Ok(())
}

/// A request the watcher has not looked at yet. Existing records are left alone: a request that was put back
/// in the box after a deferral is still the same request, and "queued" must not overwrite "waiting" or
/// "failed" evidence.
pub(crate) fn ensure_queued(request: &Value, id: &str) {
    if record_path(id).as_deref().and_then(read_record).is_none() {
        observe(request, id, "queued", "queued", "waiting for the watcher to observe it");
    }
}

/// Mark the request this thread is performing, so verb internals can report steps.
pub(crate) fn begin(request: &Value, id: &str) {
    PERFORMING.with(|slot| *slot.borrow_mut() = Some((id.to_string(), request.clone())));
}

pub(crate) fn end() {
    PERFORMING.with(|slot| *slot.borrow_mut() = None);
}

/// A scoped mark: progress is attached for as long as this value lives, and a panic or early return cannot
/// leave a later, unrelated request reporting steps into this one.
pub(crate) struct Scope;

impl Drop for Scope {
    fn drop(&mut self) {
        end();
    }
}

pub(crate) fn begin_scope(request: &Value, id: &str) -> Scope {
    begin(request, id);
    Scope
}

/// A progress step for the request being performed on this thread. No-op when nothing is being performed
/// (for example `restart_self`, which is not a queued request).
pub(crate) fn step(phase: &str, detail: &str) {
    PERFORMING.with(|slot| {
        if let Some((id, request)) = slot.borrow().clone() {
            observe(&request, &id, "running", phase, detail);
        }
    });
}

/// Keep the observation directory bounded. Failures are evidence for a week; everything else is history.
fn prune() {
    let Ok(read) = std::fs::read_dir(dir()) else { return };
    let now = now_epoch();
    let mut kept: Vec<(u64, PathBuf)> = Vec::new();
    for entry in read.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Some(record) = read_record(&path) else { continue };
        let updated = record["updated_at"].as_u64().unwrap_or(0);
        let state = record["state"].as_str().unwrap_or("");
        let fresh = if state == "failed" { now.saturating_sub(updated) < 7 * 86_400 } else { now.saturating_sub(updated) < 86_400 };
        if fresh {
            kept.push((updated, path));
        } else {
            let _ = std::fs::remove_file(&path);
        }
    }
    kept.sort();
    let overflow = kept.len().saturating_sub(100);
    for (_, path) in kept.into_iter().take(overflow) {
        let _ = std::fs::remove_file(path);
    }
}

/// One line per observed request, newest activity first, for `wa-sentinel status`. A request that is still
/// active comes first in queue order; a failure stays until its week is up.
pub(crate) fn lines(now: u64, limit: usize) -> Vec<String> {
    let Ok(read) = std::fs::read_dir(dir()) else { return Vec::new() };
    let mut records: Vec<Value> = read.flatten().filter_map(|entry| read_record(&entry.path())).collect();
    let rank = |state: &str| match state { "running" => 0, "waiting" => 1, "queued" => 2, "failed" => 3, _ => 4 };
    records.sort_by(|a, b| {
        rank(a["state"].as_str().unwrap_or("")).cmp(&rank(b["state"].as_str().unwrap_or("")))
            .then_with(|| a["queued_at"].as_u64().unwrap_or(0).cmp(&b["queued_at"].as_u64().unwrap_or(0)))
            .then_with(|| b["updated_at"].as_u64().unwrap_or(0).cmp(&a["updated_at"].as_u64().unwrap_or(0)))
    });
    records.into_iter().take(limit).map(|record| {
        let id = record["id"].as_str().unwrap_or("");
        let verb = record["verb"].as_str().unwrap_or("");
        let state = record["state"].as_str().unwrap_or("");
        let phase = record["phase"].as_str().unwrap_or("");
        let detail = record["detail"].as_str().unwrap_or("");
        let updated = record["updated_at"].as_u64().unwrap_or(now);
        format!("  {state:<8} {verb:<8} {id}  {}  {phase}: {detail}", age(now, updated))
    }).collect()
}
