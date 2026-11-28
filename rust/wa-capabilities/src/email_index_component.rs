//! The email-query contract, asked of the `email-index` component (`rust/components/email-index`).
//!
//! WHAT THIS REPLACED. `rust/wa-email-index` is the vocabulary an email query is written in: the three ops,
//! the twelve fields a request may carry, which of them make it valid, the refusal a bad one gets, and the
//! queue with its limits. The host words every query with it (`wa-capabilities/src/email_query.rs`) and the
//! `wa-email` component indexes with the same crate, so a change to either end rebuilt the node.
//!
//! WHAT STAYS HERE. A caller has to be able to NAME an op, so this module carries the three names as an enum -
//! a name, not a rule. Every decision (is this query valid, what does its refusal say, what bytes does the
//! queue carry, what is the queue called) is the component's answer, and the component's `constants` is what
//! the limits are read from.
//!
//! A NODE WITH NO `email-index` COMPONENT CANNOT ANSWER A QUERY, and says so rather than falling back in-process.
use serde_json::{json, Value};

const COMPONENT: &str = "email-index";

/// The ops a caller may name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Op {
    Search,
    Read,
    Media,
}

impl Op {
    pub(crate) const ALL: [Op; 3] = [Op::Search, Op::Read, Op::Media];

    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Op::Search => "search",
            Op::Read => "read",
            Op::Media => "media",
        }
    }

    pub(crate) fn parse(text: &str) -> Option<Op> {
        Op::ALL.iter().copied().find(|op| op.as_str() == text.trim())
    }
}

/// A request the component accepted: the bytes the queue carries, and the queue with its limits.
#[derive(Clone, Debug)]
pub(crate) struct Verified {
    pub request: Vec<u8>,
    pub dedupe: String,
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

/// Check one query through the component. `Err` is the contract's own refusal envelope, unchanged.
pub(crate) fn validate(request: Value) -> Result<Verified, Value> {
    let answer = call("validate", json!({"request": request}))
        .ok_or_else(|| absent())?;
    if answer["ok"] != json!(true) {
        // `wa-email-index::refusal` builds this envelope; the seam hands it on as it arrived.
        return Err(answer);
    }
    Ok(Verified {
        request: answer["request_hex"].as_str().and_then(unhex).unwrap_or_default(),
        dedupe: answer["dedupe"].as_str().unwrap_or_default().to_string(),
        queue: answer["queue"].as_str().unwrap_or_default().to_string(),
        fresh_ms: answer["fresh_ms"].as_i64().unwrap_or_default(),
        max_attempts: answer["max_attempts"].as_u64().unwrap_or_default() as u32,
    })
}

/// The word a caller reads when this node runs no index component.
pub(crate) fn absent() -> Value {
    json!({"ok": false, "error": "email_query_component_absent", "effect": "none",
        "detail": "this node runs no email-index component, so it cannot answer an email query"})
}

/// The contract's own bounds, read once from the component.
pub(crate) fn constant(name: &str) -> Value {
    use std::sync::OnceLock;
    static CONSTANTS: OnceLock<Value> = OnceLock::new();
    let all = CONSTANTS.get_or_init(|| call("constants", json!({})).unwrap_or(Value::Null));
    all[name].clone()
}

pub(crate) fn queue() -> String {
    constant("queue").as_str().unwrap_or("email.query").to_string()
}

pub(crate) fn max_q() -> usize {
    constant("max_q").as_u64().unwrap_or(200) as usize
}
