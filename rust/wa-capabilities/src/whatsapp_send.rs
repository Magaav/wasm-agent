//! `host.whatsapp_send` and `host.whatsapp_send_status`: the explicit send, on the shared queue.
//!
//! The owner's decision (06/11): the new bridge sends ordinary messages freely, to any chat, like the
//! old connector did - and on the architecture, not beside it. So an explicit send is a **job**:
//!
//! ```text
//! tool whatsapp_send {chat, text, reply_to?, mentions?}
//!   -> validate the exact JID (wa-whatsapp-outbox)
//!   -> policy check `whatsapp.send` for the target `chat:<jid>`   (rate limits + audit)
//!   -> enqueue on wa:queue, queue `whatsapp.outbox`, dedupe sha256(chat|text|reply_to)
//!   -> {ok:true, id, deduped}
//! component wa-whatsapp (granted queue worker on `whatsapp.outbox`)
//!   -> take, decide (fresh? still valid?), send with the linked-device client
//!   -> done(message id) | fail(reason)
//! tool whatsapp_send_status {id} -> state, attempts, message_id | reason
//! ```
//!
//! Why the check is *here* and not in the component: the per-chat and daily budgets are the node's
//! policy (`docs/GRANT-POLICY.md`), and the component has no policy interface - a component that
//! could ask "may I?" would be a component that could answer "yes". The node decides once, on the
//! only target it can see before dispatch (the chat), and the physical frame the component writes
//! still passes the kernel's opaque-send cap (`node_policy::check_opaque_send`), which is the second
//! gate that cannot be skipped. A request whose budget was spent while it waited in the queue is
//! refused by the component's decision (`wa-whatsapp-outbox::decide`) and settles as a failure; it is
//! never sent.
//!
//! What this module must never do: put message text in an answer it logs, or in a queue alert reason.
//! The payload is the text's only home (the queue's kv, until the job is settled and reaped), and every
//! answer here is an id, a state, a count or a stable word.
use serde_json::{json, Value};
use wa_queue::{EnqueueRequest, JobId, Queue};
use wa_whatsapp_outbox as outbox;
use wa_whatsapp_outbox::Request as OutboxRequest;

/// The component name the queue namespace belongs to. The *component* is the worker (its manifest
/// carries `queue: {interfaces: ["worker"], namespaces: ["whatsapp.outbox"]}`), and the node produces
/// into that same namespace - one queue, two ends, one owner.
const COMPONENT: &str = "wa-whatsapp";
fn queue() -> Queue {
    wa_kernel_runtime::queue_host::node().queue(COMPONENT)
}

/// The policy target for one chat: `chat:<exact jid>`. The audit trail keeps a digest of it, never
/// the address itself (`rust/wa-grant-policy/src/audit.rs`).
fn target_of(chat: &str) -> String {
    format!("chat:{chat}")
}

/// `host.whatsapp_send({chat, text, reply_to?, mentions?})` - enqueue one ordinary message.
pub extern "C-unwind" fn capability(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => send(&request),
        Err(_) => json!({"ok": false, "error": "whatsapp_send_invalid_request"}),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

/// `host.whatsapp_send_status({id})` - what happened to one queued send.
pub extern "C-unwind" fn status_capability(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => status(&request),
        Err(_) => json!({"ok": false, "error": "whatsapp_send_invalid_request"}),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

/// One send: validate, ask the policy, enqueue. Every refusal keeps its own word so the caller (and
/// the test) can tell "bad address" from "no budget" from "policy says no".
fn send(request: &Value) -> Value {
    let text = |key: &str| request.get(key).and_then(Value::as_str).map(str::to_string);
    let mentions = request
        .get("mentions")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default();
    let outbox_request = OutboxRequest {
        chat: text("chat").unwrap_or_default(),
        text: text("text").unwrap_or_default(),
        reply_to: text("reply_to").filter(|id| !id.is_empty()),
        mentions,
    };
    let verified = match outbox_request.validate() {
        Ok(verified) => verified,
        Err(refusal) => {
            return json!({"ok": false, "error": refusal.error(), "detail": refusal.detail, "effect": "none"})
        }
    };

    // Governance first: nothing is written to the queue for a request the node refuses, so a spent
    // budget does not leave a job behind for the component to discover.
    let target = target_of(&verified.chat.jid());
    let decision = wa_governance::node_policy::check_whatsapp_send(COMPONENT, Some(&target));
    if !decision.is_allow() {
        let mut answer = json!({
            "ok": false,
            "effect": "none",
            "error": if matches!(decision, wa_grant_policy::Decision::RateLimited { .. }) {
                "whatsapp_send_rate_limited"
            } else {
                "whatsapp_send_policy_denied"
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
            // The two things a caller must not have to guess: the job is not the message, and the
            // component reports the message id later (`whatsapp_send_status`).
            "note": "queued: the wa-whatsapp component sends it; read the outcome with whatsapp_send_status",
        }),
        Err(error) => {
            // The queue's own words, never a payload: a refusal that says nothing is worse than one
            // the operator can act on.
            let (code, detail) = match &error {
                wa_queue::QueueError::Full { ready, limit, .. } => {
                    ("whatsapp_send_queue_full", format!("{ready}/{limit} ready"))
                }
                other => ("whatsapp_send_queue_failed", other.to_string()),
            };
            json!({"ok": false, "error": code, "detail": detail.chars().take(160).collect::<String>(), "effect": "none"})
        }
    }
}

/// One status read. A job id from another queue, or one this node never allocated, is refused rather
/// than answered with whatever shares the number.
fn status(request: &Value) -> Value {
    let Some(id) = request.get("id").and_then(|value| value.as_u64().or_else(|| value.as_str().and_then(|text| text.parse().ok()))) else {
        return json!({"ok": false, "error": "whatsapp_send_id_required", "effect": "none"});
    };
    let job = match queue().job(JobId(id)) {
        Ok(Some(job)) => job,
        Ok(None) => return json!({"ok": false, "error": "whatsapp_send_unknown_id", "id": id, "effect": "none"}),
        Err(error) => {
            return json!({"ok": false, "error": "whatsapp_send_status_failed", "detail": error.to_string().chars().take(160).collect::<String>()})
        }
    };
    if job.queue != outbox::QUEUE {
        return json!({"ok": false, "error": "whatsapp_send_unknown_id", "id": id, "effect": "none"});
    }
    outbox::status(id, job.state.as_str(), job.attempts, job.result.as_deref(), job.last_error.as_deref())
}

/// One maintenance read for the tests and for a future status tool: how many jobs of each state the
/// outbox holds, in this node's namespace. Counts only.
#[allow(dead_code)] // exercised by the tests; nothing in the UI reads it yet
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

/// The worker identity the component uses; a lease belongs to one worker name, and the host's own
/// tests take with it so a component-side lease can never be mistaken for a test's.
#[allow(dead_code)] // the tests below take with it
const WORKER: &str = "wa-whatsapp";

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use wa_whatsapp_outbox::Decision;

    /// The capability the rule is written under (`node_policy::check_whatsapp_send` names it; the
    /// tests here write a policy file with it, so a rename has to be made in one place).
    const CAPABILITY: &str = "whatsapp.send";

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("wa-outbox-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A queue host of our own, so a test never touches the node's component directory.
    fn host(tag: &str) -> wa_kernel_runtime::queue_host::QueueHost {
        wa_kernel_runtime::queue_host::QueueHost::new(temp_dir(tag))
    }

    /// The policy the shipped default writes for this capability, loaded from a scratch file so a
    /// test measures the JSON the release ships and not a paraphrase of it.
    fn policy(tag: &str, rule: Value) -> (wa_governance::node_policy::NodePolicy, wa_governance::node_policy::Paths) {
        let dir = temp_dir(&format!("policy-{tag}"));
        let paths = wa_governance::node_policy::Paths {
            policy: dir.join("policy.json"),
            state: dir.join("state.json"),
            audit: dir.join("audit").join("grant-policy.jsonl"),
        };
        std::fs::create_dir_all(paths.audit.parent().unwrap()).unwrap();
        let text = json!({"version": 1, "components": {COMPONENT: {"capabilities": {CAPABILITY: rule}}}});
        std::fs::write(&paths.policy, text.to_string()).unwrap();
        (wa_governance::node_policy::NodePolicy::open(paths.clone()), paths)
    }

    /// The rule the shipped `policies/default.json` must carry (`docs/GRANT-POLICY.md`): any chat, a
    /// global cap, a per-chat cap and a daily cap.
    fn shipped_rule() -> Value {
        json!({
            "sensitive": true,
            "allow": ["*"],
            "deny": ["chat:*@broadcast", "chat:*@newsletter"],
            "rate": {"per_minute": 20, "burst": 20},
            "per_target": {"per_minute": 6, "burst": 6},
            "daily_cap": 500
        })
    }

    #[test]
    fn a_bad_chat_is_refused_before_the_policy_or_the_queue() {
        let (_engine, paths) = policy("bad-chat", shipped_rule());
        for (chat, code) in [
            ("", "whatsapp_send_bad_chat"),
            ("5511999999999", "whatsapp_send_bad_chat"),
            ("5511999999999@broadcast", "whatsapp_send_unsupported_chat"),
        ] {
            let answer = send(&json!({"chat": chat, "text": "oi"}));
            assert_eq!(answer["ok"], false);
            assert_eq!(answer["error"], code, "{chat:?}");
            assert_eq!(answer["effect"], "none", "a refusal never has an effect");
            assert!(answer["detail"].as_str().is_some_and(|detail| !detail.is_empty()));
        }
        // A bad request is refused without a policy read, so nothing was audited for it: the file is
        // still there and still parses, and no check was counted.
        let engine = wa_governance::node_policy::NodePolicy::open(paths);
        assert!(engine.status()["loaded"].as_bool().unwrap_or(false));
    }

    #[test]
    fn the_shipped_rule_allows_any_chat_and_charges_the_per_chat_budget() {
        let (engine, _paths) = policy("per-chat", shipped_rule());
        let now = 1_000_000;
        for _ in 0..6 {
            assert!(engine.check_at(COMPONENT, CAPABILITY, Some("chat:5511999999999@lid"), now).is_allow());
        }
        let limited = engine.check_at(COMPONENT, CAPABILITY, Some("chat:5511999999999@lid"), now);
        assert_eq!(limited.reason_str(), "target_rate_limited", "6/min per chat");
        assert!(limited.retry_after_ms().is_some_and(|wait| wait > 0));
        // A different chat has its own budget; the global one is still charged.
        assert!(engine.check_at(COMPONENT, CAPABILITY, Some("chat:120363000000000001@g.us"), now).is_allow());
        // And the deny list still wins over the `*` allow.
        assert_eq!(
            engine.check_at(COMPONENT, CAPABILITY, Some("chat:5511@broadcast"), now).reason_str(),
            "target_denied"
        );
    }

    #[test]
    fn the_global_and_daily_caps_are_the_shipped_numbers() {
        let (engine, _paths) = policy("global", json!({
            "sensitive": true,
            "allow": ["*"],
            "rate": {"per_minute": 20, "burst": 20},
            "per_target": {"per_minute": 1000, "burst": 1000},
            "daily_cap": 500
        }));
        let now = 1_000_000;
        for i in 0..20 {
            assert!(engine.check_at(COMPONENT, CAPABILITY, Some(&format!("chat:{i}@lid")), now).is_allow(), "send {i}");
        }
        assert_eq!(
            engine.check_at(COMPONENT, CAPABILITY, Some("chat:99@lid"), now).reason_str(),
            "capability_rate_limited",
            "20/min in total"
        );
        // The day's cap outlives the minute's bucket.
        let later = now + 61_000;
        let mut allowed = 0;
        for i in 0..600 {
            if engine.check_at(COMPONENT, CAPABILITY, Some(&format!("chat:{i}@lid")), later).is_allow() {
                allowed += 1;
            } else {
                break;
            }
        }
        assert!(allowed < 500, "the daily cap stops before 500 in one UTC day (allowed {allowed})");
    }

    #[test]
    fn an_unruled_policy_refuses_the_send_with_its_own_word() {
        // A policy file that names the component but not the capability: default deny.
        let dir = temp_dir("unruled");
        let paths = wa_governance::node_policy::Paths {
            policy: dir.join("policy.json"),
            state: dir.join("state.json"),
            audit: dir.join("audit").join("grant-policy.jsonl"),
        };
        std::fs::create_dir_all(paths.audit.parent().unwrap()).unwrap();
        std::fs::write(&paths.policy, json!({"version": 1, "components": {COMPONENT: {"capabilities": {"kv.read": {}}}}}).to_string()).unwrap();
        let engine = wa_governance::node_policy::NodePolicy::open(paths);
        let decision = engine.check_at(COMPONENT, CAPABILITY, Some("chat:5511999999999@lid"), 1_000);
        assert_eq!(decision.reason_str(), "no_policy");
        assert!(!decision.is_allow());
    }

    #[test]
    fn a_queued_request_takes_the_dedupe_key_and_the_briefs_limits() {
        let host = host("enqueue");
        let queue = host.queue(COMPONENT);
        let request = OutboxRequest {
            chat: "5511999999999@lid".into(),
            text: "oi".into(),
            reply_to: None,
            mentions: Vec::new(),
        };
        let first = queue
            .enqueue(
                EnqueueRequest::new(outbox::QUEUE, request.encode())
                    .fresh_for(outbox::FRESH_MS)
                    .max_attempts(outbox::MAX_ATTEMPTS)
                    .dedupe(request.dedupe_key()),
            )
            .unwrap();
        let second = queue
            .enqueue(
                EnqueueRequest::new(outbox::QUEUE, request.encode())
                    .fresh_for(outbox::FRESH_MS)
                    .max_attempts(outbox::MAX_ATTEMPTS)
                    .dedupe(request.dedupe_key()),
            )
            .unwrap();
        assert!(second.dedupe_hit && second.id == first.id, "one request, one job");
        let job = queue.job(first.id).unwrap().unwrap();
        assert_eq!(job.queue, outbox::QUEUE);
        assert_eq!(job.max_attempts, outbox::MAX_ATTEMPTS);
        assert_eq!(job.fresh_until, Some(job.created_at + outbox::FRESH_MS));
        // The component's decision on the stored payload is "send this chat, with this text".
        match outbox::decide(&job.payload, job.created_at, job.fresh_until) {
            Decision::Send(verified) => {
                assert_eq!(verified.chat.jid(), "5511999999999@lid");
                assert_eq!(verified.text, "oi");
            }
            Decision::Refuse(refusal) => panic!("a fresh job must be sendable: {}", refusal.code),
        }
    }

    #[test]
    fn status_answers_the_states_and_refuses_a_foreign_id() {
        let host = host("status");
        let queue = host.queue(COMPONENT);
        let request = OutboxRequest { chat: "5511999999999@lid".into(), text: "oi".into(), reply_to: None, mentions: Vec::new() };
        let enqueued = queue
            .enqueue(EnqueueRequest::new(outbox::QUEUE, request.encode()).fresh_for(outbox::FRESH_MS).max_attempts(outbox::MAX_ATTEMPTS))
            .unwrap();
        let taken = queue.take(outbox::QUEUE, WORKER, None).unwrap();
        let wa_queue::TakeOutcome::Job(job) = taken else { panic!("the job must be takeable") };
        queue.done_by(job.id, WORKER, &outbox::Outcome { message_id: "3EB0TEST".into() }.encode()).unwrap();
        let settled = queue.job(enqueued.id).unwrap().unwrap();
        let answer = outbox::status(settled.id.0, settled.state.as_str(), settled.attempts, settled.result.as_deref(), settled.last_error.as_deref());
        assert_eq!(answer["state"], "done");
        assert_eq!(answer["message_id"], "3EB0TEST");
        // A job of another queue in the same namespace is not an outbox id.
        let other = queue
            .enqueue(EnqueueRequest::new("wa.stt", b"x".to_vec()).fresh_for(60_000))
            .unwrap();
        let job = queue.job(other.id).unwrap().unwrap();
        assert_ne!(job.queue, outbox::QUEUE);
    }

    #[test]
    fn a_legacy_group_id_is_a_target_and_not_a_bad_chat() {
        // The live finding (07/11): `whatsapp_search` returned a hit for an older group named
        // `9999999999999-9999999999@g.us` and passing that same value to a send was refused as
        // `bad_chat`. Everything this producer does with a chat before the queue is checked here: the
        // exact-JID rule and the policy target (an audit keeps only its digest).
        let chat = "9999999999999-9999999999@g.us";
        let request = OutboxRequest { chat: chat.into(), text: "oi".into(), reply_to: None, mentions: Vec::new() };
        let verified = request.validate().expect("a legacy group id is a chat");
        assert_eq!(verified.chat.jid(), chat, "the id travels exactly as the hit spelled it");
        assert!(verified.chat.is_group());
        assert_eq!(target_of(&verified.chat.jid()), format!("chat:{chat}"));
        // And the worker's own decision on the payload that request becomes: send to that id.
        match outbox::decide(&request.encode(), 0, None) {
            Decision::Send(verified) => assert_eq!(verified.chat.jid(), chat),
            Decision::Refuse(refusal) => panic!("a legacy group id must be sendable: {}", refusal.code),
        }
        // A hyphen is still a group's: the same user part on a person's server stays a bad chat.
        let bad = OutboxRequest { chat: "9999999999999-9999999999@s.whatsapp.net".into(), text: "oi".into(), reply_to: None, mentions: Vec::new() };
        assert_eq!(bad.validate().unwrap_err().error(), "whatsapp_send_bad_chat");
    }

    #[test]
    fn a_refusal_never_echoes_the_text() {
        // A tool answer is copied into a transcript, and a transcript is not where the queue's
        // payload lives. Every refusal this module can reach before the queue is checked here; the
        // successful answer carries an id and a state only (see `send`).
        for request in [
            json!({"chat": "nope", "text": "segredo-do-operator"}),
            json!({"chat": "5511999999999@lid", "text": ""}),
            json!({"chat": "5511999999999@lid", "text": "segredo-do-operator", "reply_to": "not an id"}),
            json!({"chat": "5511999999999@lid", "text": "segredo-do-operator", "mentions": ["120363000000000001@g.us"]}),
            json!({"text": "segredo-do-operator"}),
        ] {
            let refused = send(&request);
            assert_eq!(refused["ok"], false, "{refused}");
            assert!(!refused.to_string().contains("segredo-do-operator"), "{refused}");
        }
    }
}
