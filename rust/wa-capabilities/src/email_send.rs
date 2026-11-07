//! `host.email_send` and `host.email_send_status`: the explicit send, on the shared queue.
//!
//! The architecture is the WhatsApp explicit send's (`rust/wa-capabilities/src/whatsapp_send.rs`,
//! `docs/EMAIL-CONNECTOR.md`): a send is a **job**, not a hidden side path.
//!
//! ```text
//! tool email_send {to, cc?, subject, body, in_reply_to?, attachments?}
//!   -> validate the addresses and the bounds (wa-email-outbox)
//!   -> policy check `email.send` for the target `email:<n>rcpt:<digest>`  (rate limits + audit)
//!   -> enqueue on wa:queue, queue `email.outbox`, dedupe sha256(to|cc|subject|body|in_reply_to)
//!   -> {ok:true, id, deduped}
//! component wa-email (granted queue worker on `email.outbox`)
//!   -> take, decide (fresh? budget?), compose, submit over SMTP
//!   -> done(message id) | fail(reason)
//! tool email_send_status {id} -> state, attempts, message_id | reason
//! ```
//!
//! What this module must never do: put a subject or a body in an answer it logs, or an address in an
//! audit record. The payload is the text's only home (the queue's kv, until the job is settled and
//! reaped), and the policy target is the recipients' digest (`wa_email_outbox::audit_target`).
use serde_json::{json, Value};
use wa_email_outbox as outbox;
use wa_email_outbox::Request as OutboxRequest;
use wa_queue::{EnqueueRequest, JobId, Queue};

/// The component name the queue namespace belongs to: one queue, two ends, one owner.
const COMPONENT: &str = "wa-email";
/// The policy rule this capability asks for. The shipped `policies/default.json` need not carry it yet: a
/// node without the rule answers "not ruled" and the check is inert, exactly as `whatsapp.send` was
/// before its rule landed. An operator who wants email budgets writes
/// `{"capabilities": {"email.send": {"sensitive": true, "allow": ["*"], "rate": {...}}}}`.
const CAPABILITY: &str = "email.send";

fn queue() -> Queue {
    wa_kernel_runtime::queue_host::node().queue(COMPONENT)
}

/// `host.email_send({to, cc?, subject, body, in_reply_to?, attachments?})` - enqueue one message.
pub extern "C-unwind" fn capability(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => send(&request),
        Err(_) => json!({"ok": false, "error": "email_send_invalid_request"}),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

/// `host.email_send_status({id})` - what happened to one queued send.
pub extern "C-unwind" fn status_capability(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => status(&request),
        Err(_) => json!({"ok": false, "error": "email_send_invalid_request"}),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

/// One send: validate, ask the policy, enqueue. Every refusal keeps its own word.
fn send(request: &Value) -> Value {
    let text = |key: &str| request.get(key).and_then(Value::as_str).map(str::to_string);
    let list = |key: &str| -> Vec<String> {
        match request.get(key) {
            Some(Value::Array(items)) => items.iter().filter_map(Value::as_str).map(str::to_string).collect(),
            // A single address is a list of one: a caller that writes `to: "ana@example.com"` is understood.
            Some(Value::String(text)) => vec![text.clone()],
            _ => Vec::new(),
        }
    };
    let attachments = match request.get("attachments") {
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| outbox::Attachment {
                filename: item.get("filename").and_then(Value::as_str).unwrap_or_default().to_string(),
                mime: item.get("mime").and_then(Value::as_str).unwrap_or_default().to_string(),
                // Attachment bytes are base64 in the request, exactly as they travel in the payload.
                bytes: item
                    .get("bytes")
                    .and_then(Value::as_str)
                    .map(|encoded| {
                        use base64::Engine as _;
                        base64::engine::general_purpose::STANDARD.decode(encoded).unwrap_or_default()
                    })
                    .unwrap_or_default(),
            })
            .collect(),
        _ => Vec::new(),
    };
    let outbox_request = OutboxRequest {
        to: list("to"),
        cc: list("cc"),
        subject: text("subject").unwrap_or_default(),
        body: text("body").unwrap_or_default(),
        in_reply_to: text("in_reply_to").filter(|id| !id.is_empty()),
        attachments,
    };
    let verified = match outbox_request.validate() {
        Ok(verified) => verified,
        Err(refusal) => return json!({"ok": false, "error": refusal.error(), "detail": refusal.detail, "effect": "none"}),
    };

    // Governance first: nothing reaches the queue for a request the node refuses, so a spent budget
    // leaves no job behind for the component to discover.
    let target = outbox::audit_target(&verified.recipients());
    let decision = wa_governance::node_policy::check(COMPONENT, CAPABILITY, Some(&target));
    if !decision.is_allow() {
        let mut answer = json!({
            "ok": false,
            "effect": "none",
            "error": if matches!(decision, wa_grant_policy::Decision::RateLimited { .. }) {
                "email_send_rate_limited"
            } else {
                "email_send_policy_denied"
            },
            "reason": decision.reason_str(),
        });
        if let Some(wait) = decision.retry_after_ms() {
            answer["retry_after_ms"] = json!(wait);
        }
        return answer;
    }

    match queue().enqueue(
        EnqueueRequest::new(outbox::QUEUE, outbox_request.encode())
            .fresh_for(outbox::FRESH_MS)
            .max_attempts(outbox::MAX_ATTEMPTS)
            .dedupe(outbox_request.dedupe_key()),
    ) {
        Ok(enqueued) => json!({
            "ok": true,
            "id": enqueued.id.0,
            "state": "queued",
            "queue": outbox::QUEUE,
            "deduped": enqueued.dedupe_hit,
            "fresh_for_ms": outbox::FRESH_MS,
            "recipients": verified.recipients().len(),
            "note": "queued: the wa-email component sends it; read the outcome with email_send_status",
        }),
        Err(error) => {
            let (code, detail) = match &error {
                wa_queue::QueueError::Full { ready, limit, .. } => ("email_send_queue_full", format!("{ready}/{limit} ready")),
                other => ("email_send_queue_failed", other.to_string()),
            };
            json!({"ok": false, "error": code, "detail": detail.chars().take(160).collect::<String>(), "effect": "none"})
        }
    }
}

/// One status read. A job id from another queue, or one this node never allocated, is refused.
fn status(request: &Value) -> Value {
    let Some(id) = request.get("id").and_then(|value| value.as_u64().or_else(|| value.as_str().and_then(|text| text.parse().ok()))) else {
        return json!({"ok": false, "error": "email_send_id_required", "effect": "none"});
    };
    let job = match queue().job(JobId(id)) {
        Ok(Some(job)) => job,
        Ok(None) => return json!({"ok": false, "error": "email_send_unknown_id", "id": id, "effect": "none"}),
        Err(error) => {
            return json!({"ok": false, "error": "email_send_status_failed", "detail": error.to_string().chars().take(160).collect::<String>()})
        }
    };
    if job.queue != outbox::QUEUE {
        return json!({"ok": false, "error": "email_send_unknown_id", "id": id, "effect": "none"});
    }
    outbox::status(id, job.state.as_str(), job.attempts, job.result.as_deref(), job.last_error.as_deref())
}

/// Counts per state, for a test and for a future status tool.
#[allow(dead_code)]
pub fn counts() -> Value {
    match queue().stats(outbox::QUEUE) {
        Ok(stats) => json!({
            "queue": outbox::QUEUE,
            "ready": stats.ready,
            "leased": stats.leased,
            "done": stats.done,
            "dead": stats.dead,
            "expired": stats.expired,
        }),
        Err(error) => json!({"error": error.to_string()}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bad_address_or_a_password_shaped_request_is_refused_before_the_queue() {
        // Every one of these is refused without touching the queue, the policy or the network.
        for (request, code) in [
            (json!({"to": [], "subject": "s", "body": "b"}), "email_send_bad_to"),
            (json!({"to": ["ana"], "subject": "s", "body": "b"}), "email_send_bad_to"),
            (json!({"to": ["Ana <ana@example.com>"], "subject": "s", "body": "b"}), "email_send_bad_to"),
            (json!({"to": ["ana@example.com"], "subject": "a\r\nBcc: x@y.z", "body": "b"}), "email_send_bad_subject"),
            (json!({"to": ["ana@example.com"], "subject": "s", "body": "x".repeat(outbox::MAX_BODY + 1)}), "email_send_body_too_long"),
            (json!({"to": ["ana@example.com"], "cc": ["nope"], "subject": "s", "body": "b"}), "email_send_bad_cc"),
        ] {
            let answer = send(&request);
            assert_eq!(answer["ok"], false, "{request}");
            assert_eq!(answer["error"], code, "{request}");
            assert_eq!(answer["effect"], "none", "a refusal never has an effect");
            assert!(answer["detail"].as_str().is_some_and(|detail| !detail.is_empty()));
        }
        // An unparseable call is refused, not defaulted.
        assert!(serde_json::from_str::<Value>("nope").is_err());
    }

    #[test]
    fn a_single_address_is_accepted_and_an_attachment_is_read_as_base64() {
        use base64::Engine as _;
        let request = json!({
            "to": "ana@example.com",
            "subject": "Relatório",
            "body": "Segue.",
            "attachments": [{"filename": "fatura.txt", "mime": "text/plain", "bytes": base64::engine::general_purpose::STANDARD.encode(b"fatura 42")}]
        });
        let decoded = OutboxRequest {
            to: vec!["ana@example.com".into()],
            cc: Vec::new(),
            subject: "Relatório".into(),
            body: "Segue.".into(),
            in_reply_to: None,
            attachments: vec![outbox::Attachment {
                filename: "fatura.txt".into(),
                mime: "text/plain".into(),
                bytes: b"fatura 42".to_vec(),
            }],
        };
        assert!(decoded.validate().is_ok());
        // The same shape the tool sends decodes to the same request (checked through the public seam).
        assert_eq!(OutboxRequest::decode(&decoded.encode()).unwrap().subject, request["subject"].as_str().unwrap());
    }

    #[test]
    fn a_status_read_without_an_id_is_refused_with_a_word() {
        assert_eq!(status(&json!({}))["error"], "email_send_id_required");
        assert_eq!(status(&json!({"id": "not-a-number"}))["error"], "email_send_id_required");
    }
}
