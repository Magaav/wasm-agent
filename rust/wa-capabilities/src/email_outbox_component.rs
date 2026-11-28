//! The email-send contract, asked of the `email-outbox` component (`rust/components/email-outbox`).
//!
//! WHAT THIS REPLACED. `rust/wa-email-outbox` is the part both ends of the email queue must agree on: what a
//! mailbox is, which recipients and how much text an attachment a request may carry, the payload, its dedupe
//! key, the policy target a send is accounted against, and the outcome a worker reports. The HOST answered all
//! of it in-process to validate and enqueue (`wa-capabilities/src/email_send.rs`) and the `wa-email` component
//! uses it to decide and send - so a change to either end rebuilt the node.
//!
//! NOTHING IS DECIDED HERE. The host maps a tool call to the request's shape (that is its own argument
//! surface), and every answer - is this send valid, what does the queue carry, what is its dedupe key, what
//! target is it accounted against, what is this job's state called - comes back from the component.
//!
//! A NODE WITH NO `email-outbox` COMPONENT CANNOT SEND, and says so in its own word
//! (`email_send_component_absent`) rather than falling back in-process: the fallback is what kept the crate in
//! the binary.
use serde_json::{json, Value};

const COMPONENT: &str = "email-outbox";

/// A refusal as the component stated it.
#[derive(Clone, Debug)]
pub(crate) struct Refusal {
    pub code: String,
    pub detail: String,
}

impl Refusal {
    /// The word a caller branches on (`email_send_<code>`), which is how this tool has always worded them.
    pub(crate) fn error(&self) -> String {
        format!("email_send_{}", self.code)
    }
}

/// One accepted send, in the shape the enqueue and the answer need.
#[derive(Clone, Debug)]
pub(crate) struct Verified {
    /// The exact bytes the queue carries.
    pub request: Vec<u8>,
    pub dedupe: String,
    pub recipients: usize,
    pub audit_target: String,
    pub queue: String,
    pub fresh_ms: i64,
    pub max_attempts: u32,
}

fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
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

/// Validate one send through the component. `Err` carries the refusal a caller must see.
pub(crate) fn validate(request: Value) -> Result<Verified, Refusal> {
    let absent = Refusal {
        code: "component_absent".to_string(),
        detail: "this node runs no email-outbox component, so it cannot accept a send".to_string(),
    };
    let answer = call("validate", json!({"request": request})).ok_or_else(|| absent.clone())?;
    if answer["ok"] != json!(true) {
        return Err(Refusal {
            code: answer["code"].as_str().unwrap_or("bad_request").to_string(),
            detail: answer["detail"].as_str().unwrap_or_default().to_string(),
        });
    }
    Ok(Verified {
        request: answer["request_hex"].as_str().and_then(unhex).unwrap_or_default(),
        dedupe: answer["dedupe"].as_str().unwrap_or_default().to_string(),
        recipients: answer["recipients"].as_u64().unwrap_or_default() as usize,
        audit_target: answer["audit_target"].as_str().unwrap_or_default().to_string(),
        queue: answer["queue"].as_str().unwrap_or_default().to_string(),
        fresh_ms: answer["fresh_ms"].as_i64().unwrap_or_default(),
        max_attempts: answer["max_attempts"].as_u64().unwrap_or_default() as u32,
    })
}

/// One job's state, in the contract's own words. `None` means the component did not answer.
pub(crate) fn status(id: u64, state: &str, attempts: u32, result: Option<&[u8]>, last_error: Option<&str>) -> Value {
    let result_hex = result.map(hex);
    call("status", json!({"id": id, "state": state, "attempts": attempts,
        "result_hex": result_hex, "last_error": last_error}))
    .unwrap_or_else(|| json!({"ok": false, "error": "email_send_component_absent", "effect": "none"
        , "detail": "this node runs no email-outbox component"}))
}

/// The policy target one send is accounted against.
pub(crate) fn audit_target(recipients: &[String]) -> String {
    call("audit_target", json!({"recipients": recipients}))
        .and_then(|answer| answer["target"].as_str().map(str::to_string))
        .unwrap_or_else(|| "email:none".to_string())
}

fn constant(name: &str) -> Value {
    use std::sync::OnceLock;
    static CONSTANTS: OnceLock<Value> = OnceLock::new();
    let all = CONSTANTS.get_or_init(|| call("constants", json!({})).unwrap_or(Value::Null));
    all[name].clone()
}

/// The queue the sends are enqueued on.
pub(crate) fn queue() -> String {
    constant("queue").as_str().unwrap_or("email.outbox").to_string()
}
