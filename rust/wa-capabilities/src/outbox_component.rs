//! The explicit-send contract, asked of the `outbox` component (`rust/components/outbox`).
//!
//! WHAT THIS REPLACED. `rust/wa-whatsapp-outbox` is the part both ends of the send queue must agree on, and
//! both ends were compiled into `wa`: the host validated a send before enqueueing it, and the
//! `wa-whatsapp` component decided what to send. A change to either therefore rebuilt the node. The
//! contract is pure - no fs, no net, no clock it does not receive - so it is a component, and this is
//! the seam: one MCP call through `wa_kernel_runtime::components::mcp`, the same shape `graph.rs` and
//! `tz_component.rs` use.
//!
//! NOTHING IS CACHED. A send is a decision about one message, and a cached acceptance would be a claim
//! about a message nobody asked about yet; the call is one component start on a path that ends in a
//! network send, so its cost does not matter here.
//!
//! A NODE WITH NO `outbox` COMPONENT CANNOT SEND, and says so in the words the read path already uses
//! (`whatsapp_component_absent`) rather than falling back to an in-process copy - that fallback is what
//! kept the crate in the binary.
use serde_json::{json, Value};

const COMPONENT: &str = "outbox";

/// What the component accepted, in the shape the enqueue needs: the normalised fields, the exact payload
/// bytes, the dedupe key, and the three numbers the job is enqueued with.
#[derive(Clone, Debug)]
pub(crate) struct Verified {
    pub chat: String,
    pub text: String,
    pub reply_to: Option<String>,
    pub mentions: Vec<String>,
    pub payload: Vec<u8>,
    pub dedupe: String,
    pub queue: String,
    pub fresh_ms: i64,
    pub max_attempts: u32,
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 {
        return None;
    }
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 2);
    let mut i = 0;
    while i < bytes.len() {
        let pair = std::str::from_utf8(&bytes[i..i + 2]).ok()?;
        out.push(u8::from_str_radix(pair, 16).ok()?);
        i += 2;
    }
    Some(out)
}

fn call(tool: &str, arguments: Value) -> Option<Value> {
    let request = json!({
        "action": "call", "component": COMPONENT, "tool": tool, "arguments": arguments,
        "dirs": [], "env": {}, "timeout_seconds": 10,
    });
    let answer = wa_kernel_runtime::components::mcp(&request);
    if answer["ok"] != json!(true) {
        return None;
    }
    Some(
        answer["result_json"]
            .as_str()
            .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
            .map(|result| result["structuredContent"].clone())
            .unwrap_or(Value::Null),
    )
}

/// Accept or refuse one explicit send. `Err` carries the refusal the caller must see: either the contract's
/// own `{code, detail}` or the absent-component word.
pub(crate) fn validate(chat: &str, text: &str, reply_to: Option<&str>, mentions: &[String]) -> Result<Verified, Value> {
    let answer = call(
        "validate",
        json!({"chat": chat, "text": text, "reply_to": reply_to, "mentions": mentions}),
    )
    .ok_or_else(|| json!({"ok": false, "error": "outbox_component_absent", "effect": "none",
        "detail": "this node runs no outbox component, so it cannot validate a send"}))?;
    if answer["ok"] != json!(true) {
        // The tool's own word for a refusal is `whatsapp_send_<code>` (the contract's `Refusal::error`),
        // so the seam keeps the vocabulary a caller already branches on.
        let word = format!("whatsapp_send_{}", answer["code"].as_str().unwrap_or("bad_chat"));
        return Err(json!({"ok": false, "error": word,
            "detail": answer["detail"].as_str().unwrap_or("the send did not pass the exact-JID rule"),
            "effect": "none"}));
    }
    let payload = answer["payload_hex"].as_str().and_then(unhex).unwrap_or_default();
    Ok(Verified {
        chat: answer["chat"].as_str().unwrap_or_default().to_string(),
        text: answer["text"].as_str().unwrap_or_default().to_string(),
        reply_to: answer["reply_to"].as_str().map(str::to_string),
        mentions: answer["mentions"].as_array()
            .map(|items| items.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default(),
        payload,
        dedupe: answer["dedupe_key"].as_str().unwrap_or_default().to_string(),
        queue: answer["queue"].as_str().unwrap_or_default().to_string(),
        fresh_ms: answer["fresh_ms"].as_i64().unwrap_or_default(),
        max_attempts: answer["max_attempts"].as_u64().unwrap_or_default() as u32,
    })
}

/// One job's state, in the contract's own words. `None` means the component did not answer.
pub(crate) fn status(id: u64, state: &str, attempts: u32, result: Option<&[u8]>, last_error: Option<&str>) -> Value {
    let result_hex = result.map(|bytes| bytes.iter().map(|byte| format!("{byte:02x}")).collect::<String>());
    call("status", json!({"id": id, "state": state, "attempts": attempts,
        "result_hex": result_hex, "last_error": last_error}))
    .unwrap_or_else(|| json!({"id": id, "state": state, "error": "outbox_component_absent"}))
}

/// The queue name the contract uses, asked of the component. A send that cannot learn it has no queue to
/// write to, which is the same fact as an absent component.
pub(crate) fn queue_name() -> Option<String> {
    let answer = call("constants", json!({}))?;
    answer["queue"].as_str().map(str::to_string)
}
