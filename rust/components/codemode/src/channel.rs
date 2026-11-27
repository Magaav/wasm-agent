//! The loop's door to the seam: one JSON call in, one JSON answer out.
//!
//! `host.codemode(request_json)` is a capability like every other `host.*`, so the loop speaks JSON to
//! it (`lua/core/codemode.lua`, `seam`). Until this door existed the two halves of that JSON lived in
//! the *host* (`rust/wa-capabilities/src/codemode_seam.rs`): the request was decoded into the typed
//! records of `wa:codemode` and the answer was rendered back. Both halves are the seam's own
//! vocabulary - a step's `kind`, a refusal's `kind`, `target: "global"`, `executed: false`,
//! `effect: "none"`, the report's `sandbox_calls` - and every change to it rebuilt the `wa` binary
//! (`f2d2c3cc` added `error` and `answered`; `1c19bf5c` added the `searchTools` row shape). They
//! live here now: a change to the channel is a change to this component, not to the host.
//!
//! What the host still owns, because it is the host's and not the seam's: the request's `session` (it
//! keys the instance it keeps alive), the four preconditions only it can answer
//! (`invalid_codemode_op`, `invalid_codemode_request:session_required`, `component_session_unknown`,
//! `component_not_installed`), the epoch deadline, and `elapsed_ms` - it timed the call.
//!
//! The typed `codemode` interface stays exactly what it was: this door is a rendering of it, built on
//! the same `open`/`advance`/`finish`, so the two cannot answer differently.
use serde_json::{json, Value};

use crate::exports::wa::codemode::codemode::Guest as CodemodeGuest;
use crate::wa::codemode::types as seam;
use crate::CodemodeComponent;

/// `{"op":"open"|"advance"|"finish", …}` in; `{"ok":true,"answer":{…}}` or
/// `{"ok":false,"error":"…"}` out.
pub fn call(raw: &str) -> String {
    let request: Value = match serde_json::from_str(raw) {
        Ok(request) => request,
        // The host parses the request before it gets here (it needs the session), so this branch is the
        // door's own guard for any other caller: the same sentence the capability answers.
        Err(_) => return refusal("invalid_codemode_request:not_json"),
    };
    let op = request.get("op").and_then(Value::as_str).unwrap_or_default().to_string();
    let answered = match op.as_str() {
        "open" => open(&request).map(|opened| opened_json(&opened)),
        "advance" => advance(&request).map(|progress| progress_json(&progress)),
        "finish" => finish(&request).map(|report| report_json(&report)),
        other => Err(format!("invalid_codemode_op:{other}")),
    };
    match answered {
        Ok(answer) => json!({"ok": true, "answer": answer}).to_string(),
        Err(reason) => refusal(&reason),
    }
}

fn refusal(reason: &str) -> String {
    json!({"ok": false, "error": reason}).to_string()
}

fn session_of(request: &Value) -> Result<String, String> {
    request
        .get("session")
        .and_then(Value::as_str)
        .filter(|session| !session.is_empty())
        .map(str::to_string)
        .ok_or_else(|| "invalid_codemode_request:session_required".to_string())
}

fn text_field(value: &Value, key: &str) -> String {
    value.get(key).and_then(Value::as_str).unwrap_or_default().to_string()
}

fn optional(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).filter(|text| !text.is_empty()).map(str::to_string)
}

/// The node's pre-flight view of one tool, as the loop hands it over (a missing one is the node's own
/// "not blocked, nothing known" default, which is what `lua/core/tools.lua` sends for a bare call).
fn execution(value: Option<&Value>) -> seam::Execution {
    let Some(value) = value else {
        return seam::Execution {
            status: "not_blocked".to_string(),
            scope: String::new(),
            workspace_binding: String::new(),
            reason: None,
            detail: None,
            next: None,
            available: None,
            required: None,
        };
    };
    seam::Execution {
        status: text_field(value, "status"),
        scope: text_field(value, "scope"),
        workspace_binding: text_field(value, "workspace_binding"),
        reason: optional(value, "reason"),
        detail: optional(value, "detail"),
        next: optional(value, "next"),
        available: value.get("available").and_then(Value::as_bool),
        required: value.get("required").and_then(Value::as_bool),
    }
}

fn open(request: &Value) -> Result<seam::Opened, String> {
    let session = session_of(request)?;
    let catalogue: Vec<seam::ToolFacts> = request
        .get("catalogue")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| seam::ToolFacts {
                    name: text_field(item, "name"),
                    description: text_field(item, "description"),
                    schema_json: text_field(item, "schema_json"),
                    execution: execution(item.get("execution")),
                })
                .collect()
        })
        .unwrap_or_default();
    // The guest's own names as discovery entries, composed by the loop: the door copies them through
    // unchanged (`builtin-fact` in wit/codemode), because their text is the node's.
    let builtins: Vec<seam::BuiltinFact> = request
        .get("builtins")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| seam::BuiltinFact {
                    name: text_field(item, "name"),
                    description: text_field(item, "description"),
                    execution: execution(item.get("execution")),
                    entry_json: text_field(item, "entry_json"),
                })
                .collect()
        })
        .unwrap_or_default();
    let store_entries: Vec<seam::StoreEntry> = request
        .get("store")
        .and_then(Value::as_object)
        .map(|entries| {
            entries
                .iter()
                .map(|(key, value)| seam::StoreEntry { key: key.clone(), value: value.as_str().map(str::to_string) })
                .collect()
        })
        .unwrap_or_default();
    Ok(CodemodeComponent::open(seam::OpenRequest {
        session,
        owner: text_field(request, "owner"),
        code: text_field(request, "code"),
        timeout_ms: request.get("timeout_ms").and_then(Value::as_u64),
        catalogue,
        builtins,
        store: store_entries,
        wasm_path: optional(request, "wasm_path"),
        prelude_path: optional(request, "prelude_path"),
        module_cache: optional(request, "module_cache"),
    }))
}

fn advance(request: &Value) -> Result<seam::Progress, String> {
    let session = session_of(request)?;
    let reply = request.get("reply").filter(|reply| !reply.is_null()).map(|reply| seam::Reply {
        call_id: reply.get("call_id").and_then(Value::as_u64).unwrap_or(0),
        ok: reply.get("ok").and_then(Value::as_bool).unwrap_or(false),
        payload_json: reply.get("payload_json").and_then(Value::as_str).unwrap_or("null").to_string(),
    });
    Ok(CodemodeComponent::advance(session, reply))
}

fn finish(request: &Value) -> Result<seam::Report, String> {
    let session = session_of(request)?;
    Ok(CodemodeComponent::finish(session))
}

// ------------------------------------------------------------------------------------ the answer shape
//
// Moved here whole from `codemode_seam.rs` (commit 522e12ae and before): the keys, their names and
// their order are what `lua/core/codemode.lua` reads, and `scripts/test-codemode-seam-bytes.lua`
// holds the model-facing bytes of a fixed task set against the run recorded before the move.

fn output_json(items: &[seam::OutputItem]) -> Value {
    Value::Array(items.iter().map(|item| json!({"type": "text", "text": item.text, "console": item.console})).collect())
}

fn unexecuted_json(items: &[seam::UnexecutedCall]) -> Value {
    Value::Array(
        items
            .iter()
            .map(|call| json!({"id": call.id, "name": call.name, "executed": false, "effect": "none", "reason": call.reason}))
            .collect(),
    )
}

fn writes_json(writes: &[seam::StoreEntry]) -> Value {
    Value::Array(
        writes
            .iter()
            .map(|entry| match &entry.value {
                Some(value) => json!([entry.key, value]),
                None => json!([entry.key, Value::Null]),
            })
            .collect(),
    )
}

fn outcome_json(outcome: &seam::Outcome) -> Value {
    json!({
        "ok": outcome.ok,
        "value": outcome.value,
        "error": outcome.error,
        "writes": writes_json(&outcome.writes),
    })
}

fn refusal_json(refusal: &seam::Refusal) -> Value {
    match refusal {
        seam::Refusal::TargetNotAvailable(target) => json!({
            "kind": "target_not_available",
            "name": target.name,
            "route": target.route,
        }),
    }
}

fn step_json(step: &seam::Step) -> Value {
    match step {
        seam::Step::Call(call) => {
            let mut answer = json!({"kind": "call", "id": call.id, "target": call.target, "name": call.name, "args_json": call.args_json});
            if let Some(refusal) = &call.refusal {
                answer["refusal"] = refusal_json(refusal);
            }
            answer
        }
        seam::Step::HostGlobal(global) => {
            // `target: "global"` is what the loop records in the attempt, the same field, with the same
            // value, the native loop writes for a guest global.
            json!({"kind": "host_global", "id": global.id, "target": "global", "name": global.name, "args_json": global.args_json})
        }
        seam::Step::Finished(outcome) => json!({"kind": "finished", "outcome": outcome_json(outcome)}),
        seam::Step::Aborted(reason) => json!({"kind": "aborted", "reason": reason}),
    }
}

fn opened_json(opened: &seam::Opened) -> Value {
    json!({
        "session": opened.session,
        "items": output_json(&opened.items),
        "backend": opened.backend,
        "sandbox_failure": opened.sandbox_failure,
        "unexecuted": unexecuted_json(&opened.unexecuted),
        "aborted": opened.aborted,
    })
}

fn progress_json(progress: &seam::Progress) -> Value {
    // `answered` is the seam's journal row for a global it answered inside the guest: the loop writes one
    // attempt per guest call exactly as the native path does, so dropping it here would put the two
    // journals back out of step (and the parity suite exists to catch that).
    let answered: Vec<Value> = progress
        .answered
        .iter()
        .map(|answer| {
            json!({
                "id": answer.id,
                "name": answer.name,
                "ok": answer.ok,
                "args_json": answer.args_json,
                "result_json": answer.result_json,
            })
        })
        .collect();
    json!({"items": output_json(&progress.items), "answered": answered, "step": step_json(&progress.step)})
}

fn report_json(report: &seam::Report) -> Value {
    json!({
        "items": output_json(&report.items),
        "unexecuted": unexecuted_json(&report.unexecuted),
        "outcome": report.outcome.as_ref().map(outcome_json),
        "aborted": report.aborted,
        "close_failure": report.close_failure,
        "sandbox_calls": report.sandbox_calls,
    })
}

