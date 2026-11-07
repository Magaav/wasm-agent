//! `host.email_search`, `host.email_read` and `host.email_media`: the mailbox index, asked as a job.
//!
//! The architecture is the WhatsApp message index's (`rust/wa-capabilities/src/whatsapp_query.rs`,
//! `docs/EMAIL-CONNECTOR.md`): every message the connector fetches is recorded in the component's own kv,
//! and a question is a **job** on the shared durable queue (`email.query`) - not a host call into another
//! component's state.
//!
//! ```text
//! tool email_search {q?, from?, subject?, mailbox?, since?, until?, has_attachment?, limit?}
//!   -> validate here, enqueue `email.query` (dedupe = the request itself)
//! component wa-email (granted queue worker on `email.query`)
//!   -> read its own index, settle done(answer)
//! tool answer <- the job's result (bounded to the queue's 64 KiB)
//! ```
//!
//! The answer is text because a search result *is* text; the log lines on the way carry ids, counts and
//! stable words only, and a refusal is `{ok:false, error:"email_<word>", detail}`.
use serde_json::{json, Value};
use std::time::{Duration, Instant};
use wa_email_index as seam;
use wa_queue::{EnqueueRequest, JobId, Queue};

/// The component name the queue namespace belongs to.
const COMPONENT: &str = "wa-email";

fn queue() -> Queue {
    wa_kernel_runtime::queue_host::node().queue(COMPONENT)
}

/// `host.email_search({q?, from?, subject?, mailbox?, since?, until?, has_attachment?, limit?})`.
pub extern "C-unwind" fn search(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    answer(l, seam::Op::Search)
}

/// `host.email_read({mailbox?, uid?, before?, limit?})`.
pub extern "C-unwind" fn read(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    answer(l, seam::Op::Read)
}

/// `host.email_media({uid, mailbox?})`.
pub extern "C-unwind" fn media(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    answer(l, seam::Op::Media)
}

fn answer(l: *mut wa_host_support::lua::LuaState, op: seam::Op) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(args) => ask(op, &args, seam::WAIT_MS),
        Err(_) => json!({"ok": false, "error": "email_invalid_request", "detail": "the arguments are not a JSON object"}),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

/// Build the request from the tool's arguments, in the one shape the component reads back. `count` is
/// accepted as a synonym of `limit`, so a caller that says either is understood.
fn request_of(op: seam::Op, args: &Value) -> seam::Request {
    let text = |key: &str| args.get(key).and_then(Value::as_str).map(str::to_string);
    let number = |key: &str| args.get(key).and_then(Value::as_i64);
    let limit = args.get("limit").and_then(Value::as_u64).or_else(|| args.get("count").and_then(Value::as_u64));
    seam::Request {
        op,
        q: text("q"),
        mailbox: text("mailbox"),
        from: text("from"),
        subject: text("subject"),
        // A caller may pass seconds (a common mistake); the index stores milliseconds.
        since: number("since").map(from_epoch),
        until: number("until").map(from_epoch),
        has_attachment: args.get("has_attachment").and_then(Value::as_bool),
        uid: args.get("uid").and_then(Value::as_u64).map(|value| value as u32),
        before: args.get("before").and_then(Value::as_u64).map(|value| value as u32),
        limit: limit.map(|value| value.min(u32::MAX as u64) as u32),
    }
}

/// Epoch milliseconds from a number that may be seconds: anything below 100_000_000_000 is taken as
/// seconds, which covers every date this connector can hold (1970-5138).
fn from_epoch(value: i64) -> i64 {
    if value.abs() < 100_000_000_000 {
        value.saturating_mul(1_000)
    } else {
        value
    }
}

fn ask(op: seam::Op, args: &Value, wait_ms: u64) -> Value {
    ask_in(&queue(), op, args, wait_ms)
}

fn ask_in(q: &Queue, op: seam::Op, args: &Value, wait_ms: u64) -> Value {
    let request = request_of(op, args);
    if let Err(refusal) = request.validate() {
        return seam::refusal(&refusal);
    }
    let id = match q.enqueue(
        EnqueueRequest::new(seam::QUEUE, request.encode())
            .fresh_for(seam::FRESH_MS)
            .max_attempts(seam::MAX_ATTEMPTS)
            .dedupe(request.dedupe_key()),
    ) {
        Ok(enqueued) => enqueued.id.0,
        Err(error) => return json!({"ok": false, "error": "email_queue_failed", "detail": one_line(&error.to_string())}),
    };
    settle(q, id, wait_ms)
}

/// Wait (bounded) for the job to settle, then turn it into the tool's answer.
fn settle(q: &Queue, id: u64, wait_ms: u64) -> Value {
    let deadline = Instant::now() + Duration::from_millis(wait_ms.max(1));
    loop {
        let job = match q.job(JobId(id)) {
            Ok(Some(job)) => job,
            Ok(None) => return json!({"ok": false, "error": "email_job_lost", "id": id}),
            Err(error) => return json!({"ok": false, "error": "email_queue_failed", "detail": one_line(&error.to_string())}),
        };
        match job.state.as_str() {
            "done" => {
                let Some(result) = job.result.as_deref() else {
                    return json!({"ok": false, "error": "email_answer_missing", "id": id});
                };
                return serde_json::from_slice::<Value>(result).unwrap_or_else(|_| json!({"ok": false, "error": "email_answer_unreadable", "id": id}));
            }
            "dead" | "expired" => {
                let reason = job.last_error.unwrap_or_else(|| job.state.as_str().to_string());
                return json!({
                    "ok": false,
                    "id": id,
                    "state": job.state.as_str(),
                    "error": "email_query_failed",
                    "reason": reason.chars().take(160).collect::<String>(),
                });
            }
            _ => {}
        }
        if Instant::now() >= deadline {
            // Still running: answer with the id instead of blocking the node's only tool thread.
            return json!({
                "ok": true,
                "id": id,
                "state": "running",
                "note": "the connector has not answered yet; the job id names it if you ask again later",
            });
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn one_line(text: &str) -> String {
    text.chars().map(|c| if c.is_control() { ' ' } else { c }).take(160).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_tool_arguments_become_the_request_the_component_reads() {
        let request = request_of(seam::Op::Search, &json!({"q": "fatura", "mailbox": "INBOX", "limit": 5}));
        assert_eq!(request.q.as_deref(), Some("fatura"));
        assert_eq!(request.mailbox.as_deref(), Some("INBOX"));
        assert_eq!(request.limit, Some(5));
        assert!(request.validate().is_ok());
        // `count` is a synonym, and a second-resolution timestamp is milliseconds by the time the index
        // sees it.
        let request = request_of(seam::Op::Read, &json!({"count": 3, "since": 1_793_959_200}));
        assert_eq!(request.limit, Some(3));
        assert_eq!(request.since, Some(1_793_959_200_000));
        assert_eq!(from_epoch(1_793_959_200_000), 1_793_959_200_000, "a millisecond value is left alone");
        assert_eq!(from_epoch(0), 0);
        // The op decides which fields the component will read.
        let media = request_of(seam::Op::Media, &json!({"uid": 12}));
        assert_eq!(media.uid, Some(12));
        assert_eq!(media.op, seam::Op::Media);
    }

    #[test]
    fn a_question_that_cannot_be_one_is_refused_before_it_is_enqueued() {
        let empty = request_of(seam::Op::Search, &json!({}));
        let refusal = empty.validate().unwrap_err();
        assert_eq!(refusal.error(), "email_empty_query");
        let too_long = request_of(seam::Op::Search, &json!({"q": "x".repeat(seam::MAX_Q + 1)}));
        assert_eq!(too_long.validate().unwrap_err().code, "query_too_long");
        let bad_limit = request_of(seam::Op::Search, &json!({"q": "ok", "limit": 0}));
        assert_eq!(bad_limit.validate().unwrap_err().code, "bad_limit");
        let media_without_uid = request_of(seam::Op::Media, &json!({"mailbox": "INBOX"}));
        assert_eq!(media_without_uid.validate().unwrap_err().code, "uid_required");
        // A valid search is one job per distinct question.
        assert_eq!(request_of(seam::Op::Search, &json!({"q": "ok"})).dedupe_key(), request_of(seam::Op::Search, &json!({"q": "ok"})).dedupe_key());
        assert_ne!(request_of(seam::Op::Search, &json!({"q": "ok"})).dedupe_key(), request_of(seam::Op::Read, &json!({})).dedupe_key());
    }
}
