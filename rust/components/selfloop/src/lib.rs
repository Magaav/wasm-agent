//! The self-loop as a component (`docs/CORE-SPLIT.md`, `docs/KERNEL.md`, "The self-loop as a
//! component").
//!
//! It exports `wa:selfloop` — the wake/notes/probe state machine, its validation, its refusals, the
//! claim/settle compare-and-set and the rendered wake turn — and imports one thing: `wa:kernel/sql`,
//! scoped by this component's manifest to `self_wakes`, `self_notes`, `self_notes_archive` (read and
//! write) and `sessions` (read, for the authority checks). The file stays in the kernel.
//!
//! What is deliberately **not** here, because it needs living state of the node rather than a row:
//!
//! * running a probe — it needs the QuickJS sandbox and the read-only tool catalogue, so the node
//!   runs the script and hands the answer back ([`probe`]);
//! * the run scheduler a due wake is handed to (`host.enqueue_completion`) — [`plan`], [`claim`] and
//!   [`settle_dispatch`] are the three points it participates in;
//! * the `SelfWake` and bus hooks that may veto a turn, and the agent turn itself;
//! * the schema. `setup()` in `lua/core/selfloop.lua` creates the three tables; this component's grant
//!   has no DDL, so a missing table is a visible `store-failed`, never a silently created one.
//!
//! Nothing on the seam is a JSON document: every field is a record from `wit/selfloop/selfloop.wit`.
//! Two stored *columns* are JSON because the native path already writes them that way and both paths
//! read the same rows — `self_wakes.on_topics` (an array of strings) and the rendering a probe leaves
//! in `self_wakes.probe_result` — and both are documented where they are read or written.
use crate::exports::wa::selfloop::selfloop::{
    Caller, DispatchOutcome, DueWake, FinishReport, Guest, NotesCompactReport, ProbeDecision,
    ProbeResult, PublishReport, ScheduleRequest, TickPlan, TurnRequest, WakeTurn,
};
use wa::selfloop::types::{
    Error, EventFact, Notes, NotesArchive, NotesReadAnswer, NotesVersion, NotesWriteReport,
    PastTime, TooLarge, Wake, WakePage, WakeSummary,
};

wit_bindgen::generate!({ path: "../../../wit/selfloop", world: "selfloop-component", generate_all });

mod logic;

use logic::{
    backoff, claim_row, encode_topics, entry_matches, exec, int, min_repeat_seconds,
    probe_decision, probe_detail, probe_failure, query, real, slug, text, topics_valid, trim,
    turn_content, view, Row, ARCHIVE_KEEP, DUE_LIMIT, LIST_LIMIT, MAX_PROBE, MAX_PROMPT,
    MAX_REASON, NOTES_LIMIT,
};

/// The exported component: one fn per seam operation, no state of its own between calls. Every call
/// opens its own SQL session inside the host (`memory_host` does the same for `wa:memory`), so a
/// component instance can never hold a transaction open across two calls.
struct SelfloopComponent;

// ------------------------------------------------------------------------------------- small things

/// A fresh row id, shaped like the native `host.uuid()`: 32 lower-case hex digits in the RFC 4122
/// version-4 layout. The entropy is the process's own `RandomState` seed mixed with the clock and a
/// counter, which is enough for a primary key in a local store and needs no dependency and no WASI
/// interface beyond a clock. It is an id, not a capability: nothing is authorised by guessing it.
fn new_id() -> String {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let mut bytes = [0u8; 16];
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
    let seed = RandomState::new();
    for (half, salt) in [(0usize, 0u64), (8usize, 1u64)] {
        let mut hasher = seed.build_hasher();
        hasher.write_u64(salt);
        hasher.write_u128(nanos);
        hasher.write_u64(counter);
        bytes[half..half + 8].copy_from_slice(&hasher.finish().to_le_bytes());
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

/// The session a call is for, after the two checks the native `owner_of` makes: it exists, and it is
/// the caller's. A subagent session is refused by the callers that must (a wake), not here.
struct Session {
    user_id: String,
    objective: String,
    parent_session_id: Option<String>,
}

fn session(owner: &str, session_id: &str) -> Result<Session, Error> {
    if session_id.is_empty() {
        return Err(Error::RequiresSession);
    }
    // A store fault stays a store fault: "no such session" and "the store did not answer" must never
    // look the same.
    let rows = query(
        "SELECT user_id,objective,parent_session_id FROM sessions WHERE id=?",
        &[text(session_id)],
    )?;
    let Some(row) = rows.rows.first() else {
        return Err(Error::UnknownSession);
    };
    if row.text("user_id") != owner {
        return Err(Error::ForbiddenSession);
    }
    Ok(Session {
        user_id: row.text("user_id"),
        objective: row.text("objective"),
        parent_session_id: if row.is_null("parent_session_id") {
            None
        } else {
            Some(row.text("parent_session_id"))
        },
    })
}

/// `owner_of` plus the two checks a wake makes: the session exists, it is the caller's, and it is not
/// a child (a child that wakes itself would outlive the run its parent waits on).
fn wake_session(who: &Caller) -> Result<Session, Error> {
    let session = session(&who.owner, &who.session_id)?;
    if session.objective == "subagent" || session.parent_session_id.is_some() {
        return Err(Error::NotForSubagent);
    }
    Ok(session)
}

/// The row a mutation is about, or `unknown-wake` (with the caller's owner and session already
/// checked).
fn wake_row(id: &str, owner: &str, session_id: &str) -> Result<Row, Error> {
    let rows = query(
        "SELECT * FROM self_wakes WHERE id=? AND owner=? AND session_id=?",
        &[text(id), text(owner), text(session_id)],
    )?;
    rows.rows.into_iter().next().ok_or(Error::UnknownWake)
}

fn wake_by_id(id: &str) -> Result<Row, Error> {
    let rows = query("SELECT * FROM self_wakes WHERE id=?", &[text(id)])?;
    rows.rows.into_iter().next().ok_or(Error::UnknownWake)
}

fn notes_text(session_id: &str) -> Result<String, Error> {
    let rows = query("SELECT text FROM self_notes WHERE session_id=?", &[text(session_id)])?;
    Ok(rows.rows.first().map(|row| row.text("text")).unwrap_or_default())
}

fn notes_put(session_id: &str, value: &str, now: f64) -> Result<(), Error> {
    exec(
        "INSERT INTO self_notes(session_id,text,updated_at) VALUES(?,?,?) \
         ON CONFLICT(session_id) DO UPDATE SET text=excluded.text, updated_at=excluded.updated_at",
        &[text(session_id), text(value), real(now)],
    )?;
    Ok(())
}

/// Archive one document and keep the last [`ARCHIVE_KEEP`] versions. Returns the version id, or
/// nothing when there was nothing to archive.
fn notes_archive(session_id: &str, value: &str, reason: &str, now: f64) -> Result<Option<String>, Error> {
    if value.is_empty() {
        return Ok(None);
    }
    let id = new_id();
    exec(
        "INSERT INTO self_notes_archive(id,session_id,text,bytes,reason,created_at) VALUES(?,?,?,?,?,?)",
        &[
            text(&id),
            text(session_id),
            text(value),
            int(value.len() as i64),
            text(reason),
            real(now),
        ],
    )?;
    exec(
        "DELETE FROM self_notes_archive WHERE session_id=? AND id NOT IN \
         (SELECT id FROM self_notes_archive WHERE session_id=? ORDER BY created_at DESC LIMIT ?)",
        &[text(session_id), text(session_id), int(ARCHIVE_KEEP)],
    )?;
    Ok(Some(id))
}

fn summary_of(session_id: &str, now: f64) -> Result<WakeSummary, Error> {
    let rows = query(
        "SELECT \
           SUM(CASE WHEN status='pending' THEN 1 ELSE 0 END) AS pending, \
           SUM(CASE WHEN status='pending' AND due_at IS NULL THEN 1 ELSE 0 END) AS event_pending, \
           SUM(CASE WHEN status='dispatching' THEN 1 ELSE 0 END) AS dispatching, \
           MIN(CASE WHEN status='pending' AND due_at IS NOT NULL THEN due_at END) AS next_at \
         FROM self_wakes WHERE session_id=? AND status IN ('pending','dispatching')",
        &[text(session_id)],
    )?;
    let row = rows.rows.first().cloned().unwrap_or_else(Row::empty);
    let pending = row.number("pending").unwrap_or(0.0) as u64;
    let dispatching = row.number("dispatching").unwrap_or(0.0) as u64;
    let next_at = row.number("next_at");
    Ok(WakeSummary {
        pending,
        event_pending: row.number("event_pending").unwrap_or(0.0) as u64,
        dispatching,
        total: pending + dispatching,
        next_at,
        next_in_seconds: next_at.map(|at| (at - now + 0.999).floor().max(0.0) as u64),
        now,
    })
}

// --------------------------------------------------------------------------------- the seam itself

impl Guest for SelfloopComponent {
    fn schedule(request: ScheduleRequest) -> Result<Wake, Error> {
        let session = wake_session(&Caller {
            owner: request.owner.clone(),
            session_id: request.session_id.clone(),
        })?;
        let now = request.now;

        let reason = trim(&request.reason);
        if reason.is_empty() {
            return Err(Error::ReasonRequired);
        }
        if reason.len() > MAX_REASON {
            return Err(Error::ReasonTooLong);
        }
        if request.prompt.len() > MAX_PROMPT {
            return Err(Error::PromptTooLong);
        }
        if request.probe.len() > MAX_PROBE {
            return Err(Error::ProbeTooLong);
        }

        let timed = request.in_seconds.is_some() || request.at.is_some();
        let evented = request.on.is_some();
        if timed && evented {
            return Err(Error::TimeAndEventExclusive);
        }
        if !timed && !evented {
            return Err(Error::NeedsWakeTarget);
        }

        let mut due_at: Option<f64> = None;
        let mut every: Option<f64> = None;
        let mut topics: Vec<String> = Vec::new();
        if timed {
            if request.in_seconds.is_some() && request.at.is_some() {
                return Err(Error::InSecondsAndAtExclusive);
            }
            if let Some(seconds) = request.in_seconds {
                if seconds < 0.0 {
                    return Err(Error::InSecondsNotANumber);
                }
                due_at = Some(now + seconds);
            } else {
                let at = request.at.ok_or(Error::AtNotANumber)?;
                if at <= now {
                    return Err(Error::AtInThePast(PastTime { now, at }));
                }
                due_at = Some(at);
            }
            if let Some(seconds) = request.every_seconds {
                let minimum = min_repeat_seconds();
                if seconds < minimum {
                    return Err(Error::EverySecondsTooSmall(minimum));
                }
                every = Some(seconds);
            }
        } else {
            if request.in_seconds.is_some() || request.at.is_some() || request.every_seconds.is_some() {
                return Err(Error::EventTakesNoTimeArguments);
            }
            topics = topics_valid(request.on.as_deref().unwrap_or(&[]))?;
        }
        if !request.probe.is_empty() && every.is_none() && timed {
            return Err(Error::ProbeNeedsCadence);
        }

        let id = new_id();
        // Two statements rather than one with an absent parameter, exactly as the native schedule
        // writes it: a wake is pending with no clock first, then the clock (if it has one) is set.
        exec(
            "INSERT INTO self_wakes(id,owner,session_id,status,reason,prompt,on_topics,probe,probe_result, \
             event_json,fired_at,created_at,updated_at,attempts,last_error,boot) \
             VALUES(?,?,?,'pending',?,?,?,?,'','',0,?,?,0,'','')",
            &[
                text(&id),
                text(&session.user_id),
                text(&request.session_id),
                text(&reason),
                text(&request.prompt),
                text(&encode_topics(&topics)),
                text(&request.probe),
                real(now),
                real(now),
            ],
        )?;
        if let Some(due) = due_at {
            match every {
                Some(seconds) => exec(
                    "UPDATE self_wakes SET due_at=?, every_seconds=? WHERE id=?",
                    &[real(due), real(seconds), text(&id)],
                )?,
                None => exec("UPDATE self_wakes SET due_at=? WHERE id=?", &[real(due), text(&id)])?,
            };
        }
        Ok(view(&wake_by_id(&id)?, Some(now)))
    }

    fn list(who: Caller, all: bool, now: f64) -> Result<WakePage, Error> {
        session(&who.owner, &who.session_id)?;
        let statuses = if all {
            "('pending','dispatching','delivered','failed','cancelled','unknown')"
        } else {
            "('pending','dispatching')"
        };
        let rows = query(
            &format!(
                "SELECT * FROM self_wakes WHERE owner=? AND session_id=? AND status IN {statuses} \
                 ORDER BY CASE WHEN due_at IS NULL THEN 1 ELSE 0 END, due_at, created_at LIMIT ?"
            ),
            &[text(&who.owner), text(&who.session_id), int(LIST_LIMIT)],
        )?;
        let wakes: Vec<Wake> = rows.rows.iter().map(|row| view(row, Some(now))).collect();
        Ok(WakePage {
            count: wakes.len() as u64,
            wakes,
            summary: summary_of(&who.session_id, now)?,
        })
    }

    fn cancel(who: Caller, id: String, now: f64) -> Result<String, Error> {
        session(&who.owner, &who.session_id)?;
        let id = trim(&id);
        if id.is_empty() {
            return Err(Error::WakeIdRequired);
        }
        let row = wake_row(&id, &who.owner, &who.session_id)?;
        let status = row.text("status");
        if status == "dispatching" {
            // The run is already handed to the scheduler; cancelling here would claim an effect this
            // call cannot observe (the native `wake_already_dispatching`).
            return Err(Error::WakeAlreadyDispatching(view(&row, Some(now))));
        }
        if status != "pending" {
            return Err(Error::WakeNotPending(status));
        }
        let changed = exec(
            "UPDATE self_wakes SET status='cancelled', updated_at=? WHERE id=? AND status='pending'",
            &[real(now), text(&id)],
        )?;
        if changed.changes != 1 {
            return Err(Error::WakeNotPending(status));
        }
        Ok(id)
    }

    fn summary(session_id: String, now: f64) -> Result<WakeSummary, Error> {
        // A session id the store cannot answer for is not a fault of the footer: an empty summary is
        // the honest answer, exactly as the native `summary("")` returns zeros. A *store* fault is
        // still reported, so a broken grant never reads as "no wakes".
        if session_id.is_empty() {
            return Ok(WakeSummary {
                pending: 0,
                event_pending: 0,
                dispatching: 0,
                total: 0,
                next_at: None,
                next_in_seconds: None,
                now,
            });
        }
        summary_of(&session_id, now)
    }

    fn notes_read(
        who: Caller,
        version: Option<String>,
        versions: bool,
        _now: f64,
    ) -> Result<NotesReadAnswer, Error> {
        let session = session(&who.owner, &who.session_id)?;
        if let Some(version) = version.filter(|value| !value.is_empty()) {
            let rows = query(
                "SELECT * FROM self_notes_archive WHERE id=? AND session_id=?",
                &[text(&version), text(&who.session_id)],
            )?;
            let row = rows.rows.into_iter().next().ok_or(Error::UnknownNotesVersion)?;
            return Ok(NotesReadAnswer::Archive(NotesArchive {
                version: row.text("id"),
                reason: row.text("reason"),
                text: row.text("text"),
                bytes: row.number("bytes").unwrap_or(0.0) as u64,
                created_at: row.number("created_at").unwrap_or(0.0),
            }));
        }
        if versions {
            let rows = query(
                "SELECT id,bytes,reason,created_at FROM self_notes_archive WHERE session_id=? \
                 ORDER BY created_at DESC LIMIT 20",
                &[text(&who.session_id)],
            )?;
            return Ok(NotesReadAnswer::Versions(
                rows.rows
                    .iter()
                    .map(|row| NotesVersion {
                        version: row.text("id"),
                        bytes: row.number("bytes").unwrap_or(0.0) as u64,
                        reason: row.text("reason"),
                        created_at: row.number("created_at").unwrap_or(0.0),
                    })
                    .collect(),
            ));
        }
        let _ = session;
        let rows = query(
            "SELECT text,updated_at FROM self_notes WHERE session_id=?",
            &[text(&who.session_id)],
        )?;
        let row = rows.rows.into_iter().next();
        let value = row.as_ref().map(|row| row.text("text")).unwrap_or_default();
        Ok(NotesReadAnswer::Document(Notes {
            bytes: value.len() as u64,
            lines: value.matches('\n').count() as u64 + 1,
            updated_at: row.as_ref().and_then(|row| row.number("updated_at")),
            empty: value.is_empty(),
            text: value,
        }))
    }

    fn notes_write(who: Caller, text: String, now: f64) -> Result<NotesWriteReport, Error> {
        session(&who.owner, &who.session_id)?;
        if text.len() > NOTES_LIMIT {
            return Err(Error::NotesTooLarge(TooLarge { limit: NOTES_LIMIT as u64, current_bytes: None }));
        }
        let previous = notes_text(&who.session_id)?;
        let archived = if !previous.is_empty() && previous != text {
            notes_archive(&who.session_id, &previous, "write", now)?
        } else {
            None
        };
        notes_put(&who.session_id, &text, now)?;
        Ok(NotesWriteReport {
            bytes: text.len() as u64,
            archived,
            replaced: !previous.is_empty(),
        })
    }

    fn notes_append(who: Caller, text: String, now: f64) -> Result<NotesWriteReport, Error> {
        session(&who.owner, &who.session_id)?;
        if text.is_empty() {
            return Err(Error::NotesTextRequired);
        }
        let current = notes_text(&who.session_id)?;
        let joined = if current.is_empty() {
            text.clone()
        } else {
            let separator = if current.ends_with('\n') { "" } else { "\n" };
            format!("{current}{separator}{text}")
        };
        if joined.len() > NOTES_LIMIT {
            return Err(Error::NotesTooLarge(TooLarge {
                limit: NOTES_LIMIT as u64,
                current_bytes: Some(current.len() as u64),
            }));
        }
        notes_put(&who.session_id, &joined, now)?;
        Ok(NotesWriteReport {
            bytes: joined.len() as u64,
            archived: None,
            replaced: false,
        })
    }

    fn notes_compact(who: Caller, keep_lines: u32, now: f64) -> Result<NotesCompactReport, Error> {
        session(&who.owner, &who.session_id)?;
        if keep_lines < 1 || keep_lines > 1000 {
            return Err(Error::KeepLinesInvalid);
        }
        let current = notes_text(&who.session_id)?;
        if current.is_empty() {
            return Ok(NotesCompactReport {
                unchanged: true,
                kept_lines: 0,
                archived: None,
                archived_lines: 0,
                before_bytes: 0,
                bytes: 0,
            });
        }
        let keep = keep_lines as usize;
        let (lines, kept) = logic::keep_lines(&current, keep);
        if lines.len() <= keep {
            return Ok(NotesCompactReport {
                unchanged: true,
                kept_lines: lines.len() as u64,
                archived: None,
                archived_lines: 0,
                before_bytes: current.len() as u64,
                bytes: current.len() as u64,
            });
        }
        let archived = notes_archive(&who.session_id, &current, "compact", now)?;
        notes_put(&who.session_id, &kept, now)?;
        Ok(NotesCompactReport {
            unchanged: false,
            kept_lines: keep as u64,
            archived,
            archived_lines: (lines.len() - keep) as u64,
            before_bytes: current.len() as u64,
            bytes: kept.len() as u64,
        })
    }

    fn publish(event: EventFact) -> Result<PublishReport, Error> {
        let topic = event.topic;
        if topic.is_empty() {
            return Err(Error::PublishTopicRequired);
        }
        let now = event.now;
        let rows = query(
            "SELECT * FROM self_wakes WHERE status='pending' AND due_at IS NULL AND on_topics<>'[]'",
            &[],
        )?;
        let mut matched: Vec<String> = Vec::new();
        for row in &rows.rows {
            let id = row.text("id");
            let row_session = row.text("session_id");
            for entry in logic::decode_topics(&row.text("on_topics")) {
                // The message topic names its session in the payload the producer publishes; the
                // event fact carries that identity as the event's `id` (native `payload.session_id`).
                let session_id = event.session.as_deref();
                if entry_matches(&entry, &topic, session_id, &row_session) {
                    let identity = serde_json::json!({
                        "topic": topic,
                        "id": event.id,
                        "at": now,
                    })
                    .to_string();
                    exec(
                        "UPDATE self_wakes SET due_at=?, fired_at=?, event_json=?, updated_at=? \
                         WHERE id=? AND status='pending'",
                        &[real(now), real(now), text(&identity), real(now), text(&id)],
                    )?;
                    matched.push(id.clone());
                    break;
                }
            }
        }
        Ok(PublishReport { topic, matched })
    }

    fn plan(now: f64, stale_seconds: f64) -> Result<TickPlan, Error> {
        let reconciled = exec(
            "UPDATE self_wakes SET status='unknown', last_error='dispatch interrupted; not replayed', \
             updated_at=? WHERE status='dispatching' AND updated_at<?",
            &[real(now), real(now - stale_seconds)],
        )?
        .changes;
        let rows = query(
            "SELECT * FROM self_wakes WHERE status='pending' AND due_at IS NOT NULL AND due_at<=? \
             ORDER BY due_at LIMIT ?",
            &[real(now), int(DUE_LIMIT)],
        )?;
        let due: Vec<DueWake> = rows
            .rows
            .iter()
            .map(|row| DueWake {
                id: row.text("id"),
                owner: row.text("owner"),
                session_id: row.text("session_id"),
                reason: row.text("reason"),
                probe: row.text("probe"),
                every_seconds: row.number("every_seconds"),
                attempts: row.number("attempts").unwrap_or(0.0) as u64,
            })
            .collect();
        Ok(TickPlan { reconciled, due })
    }

    fn probe(
        id: String,
        result: Option<ProbeResult>,
        failure: Option<String>,
        now: f64,
    ) -> Result<ProbeDecision, Error> {
        let row = wake_by_id(&id)?;
        if let Some(reason) = failure {
            // A probe that could not answer wakes the model: it decides what to do about it.
            exec(
                "UPDATE self_wakes SET probe_result=?, updated_at=? WHERE id=?",
                &[text(&probe_failure(&reason)), real(now), text(&id)],
            )?;
            return Ok(ProbeDecision::Wake);
        }
        let Some(result) = result else { return Ok(ProbeDecision::Wake) };
        let decision = probe_decision(result.changed);
        if result.changed {
            exec(
                "UPDATE self_wakes SET probe_result=?, updated_at=? WHERE id=?",
                &[text(&probe_detail(&result)), real(now), text(&id)],
            )?;
            return Ok(decision);
        }
        // Nothing changed: re-arm exactly as the model asked, and never spend a turn.
        match row.number("every_seconds") {
            Some(every) => exec(
                "UPDATE self_wakes SET probe_result=?, due_at=?, updated_at=? WHERE id=? AND status='pending'",
                &[text(&probe_detail(&result)), real(now + every), real(now), text(&id)],
            )?,
            None => exec(
                "UPDATE self_wakes SET probe_result=?, due_at=NULL, updated_at=? WHERE id=? AND status='pending'",
                &[text(&probe_detail(&result)), real(now), text(&id)],
            )?,
        };
        Ok(decision)
    }

    fn claim(id: String, boot: String, now: f64) -> Result<Option<Wake>, Error> {
        claim_row(&id, None, &boot, now)
    }

    fn settle_dispatch(
        id: String,
        outcome: DispatchOutcome,
        attempts: u64,
        now: f64,
    ) -> Result<String, Error> {
        match &outcome {
            // The scheduler will call back `run_wake`; the row stays in flight until it settles.
            DispatchOutcome::Accepted => Ok("dispatching".to_string()),
            DispatchOutcome::NotStarted(reason) => {
                exec(
                    "UPDATE self_wakes SET status='pending', due_at=?, last_error=?, updated_at=? WHERE id=?",
                    &[real(now + backoff(attempts)), text(&slug(reason)), real(now), text(&id)],
                )?;
                Ok("pending".to_string())
            }
            DispatchOutcome::Unknown(reason) => {
                exec(
                    "UPDATE self_wakes SET status='unknown', last_error=?, updated_at=? WHERE id=?",
                    &[text(&slug(reason)), real(now), text(&id)],
                )?;
                Ok("unknown".to_string())
            }
        }
    }

    fn finish(id: String, ok: bool, detail: String, now: f64) -> Result<FinishReport, Error> {
        let every = wake_by_id(&id)?.number("every_seconds");
        let last_error = if ok { String::new() } else { slug(&detail) };
        match every.filter(|seconds| *seconds > 0.0) {
            Some(seconds) => {
                exec(
                    "UPDATE self_wakes SET status='pending', due_at=?, probe_result='', event_json='', \
                     updated_at=?, last_error=? WHERE id=?",
                    &[real(now + seconds), real(now), text(&last_error), text(&id)],
                )?;
                Ok(FinishReport { status: "pending".to_string(), due_at: Some(now + seconds) })
            }
            None => {
                let status = if ok { "delivered" } else { "failed" };
                exec(
                    "UPDATE self_wakes SET status=?, due_at=NULL, probe_result='', event_json='', \
                     updated_at=?, last_error=? WHERE id=?",
                    &[text(status), real(now), text(&last_error), text(&id)],
                )?;
                Ok(FinishReport { status: status.to_string(), due_at: None })
            }
        }
    }

    fn turn(row: TurnRequest) -> Result<WakeTurn, Error> {
        let notes = notes_text(&row.session_id)?;
        Ok(turn_content(&row, &notes))
    }

    fn cancel_claimed(id: String, now: f64) -> Result<bool, Error> {
        let row = wake_by_id(&id)?;
        if row.text("status") != "dispatching" {
            return Err(Error::NotDispatching(row.text("status")));
        }
        exec(
            "UPDATE self_wakes SET status='cancelled', last_error='cancelled before execution', \
             updated_at=? WHERE id=?",
            &[real(now), text(&id)],
        )?;
        Ok(true)
    }

    fn claim_due(
        session_id: String,
        owner: String,
        boot: String,
        now: f64,
    ) -> Result<Option<Wake>, Error> {
        claim_row("", Some((&session_id, &owner)), &boot, now)
    }
}

export!(SelfloopComponent);
