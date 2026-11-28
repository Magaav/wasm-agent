//! The explicit-send contract as a WASI component: MCP over stdin/stdout, one request per run - the
//! same shape `graph` and `tz` speak.
//!
//! Every answer here is `wa-whatsapp-outbox`'s own: the exact-JID rule, the payload the queue carries,
//! its dedupe key, the limits the job is enqueued with, and the outcome a worker reports. The host used
//! to answer all of that in-process, which is why a change to either end of the queue rebuilt the node.
//!
//! Two tools:
//!  * `validate` - {chat, text, reply_to?, mentions?} -> the verified request, the payload (hex, exactly
//!    what the queue carries), its dedupe key and the three numbers the enqueue needs; or the refusal's
//!    own code and detail, unchanged.
//!  * `outcome` - {payload_hex} -> the outcome a worker wrote (`message id`, note, indexed).
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use wa_whatsapp_outbox as outbox;

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
    let mut out = Vec::with_capacity(text.len() / 2);
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let pair = std::str::from_utf8(&bytes[i..i + 2]).ok()?;
        out.push(u8::from_str_radix(pair, 16).ok()?);
        i += 2;
    }
    Some(out)
}

fn text_of(args: &Value, key: &str) -> Option<String> {
    args.get(key).and_then(Value::as_str).map(str::to_string).filter(|text| !text.is_empty())
}

fn tools() -> Value {
    json!([
        {
            "name": "validate",
            "description": "Accept or refuse one explicit send and say what the queue must carry: the payload bytes, the dedupe key, the queue name and its limits. The acceptance rule is the exact-JID rule - a refusal carries its own code and detail, never a guess.",
            "inputSchema": {"type": "object", "required": ["chat", "text"], "properties": {
                "chat": {"type": "string"}, "text": {"type": "string"},
                "reply_to": {"type": "string"}, "mentions": {"type": "array", "items": {"type": "string"}}
            }}
        },
        {
            "name": "constants",
            "description": "The queue name and the two limits every enqueue of this contract uses.",
            "inputSchema": {"type": "object", "properties": {}}
        },
        {
            "name": "status",
            "description": "One job's state in the contract's own words: queued, sent with a message id, or failed with its reason.",
            "inputSchema": {"type": "object", "required": ["id", "state"], "properties": {
                "id": {"type": "integer"}, "state": {"type": "string"}, "attempts": {"type": "integer"},
                "result_hex": {"type": "string"}, "last_error": {"type": "string"}
            }}
        },
        {
            "name": "outcome",
            "description": "Read the outcome a worker reported for one job ('sent, here is its message id'), or say the payload is not one.",
            "inputSchema": {"type": "object", "required": ["payload_hex"], "properties": {"payload_hex": {"type": "string"}}}
        }
    ])
}

fn call(name: &str, args: &Value) -> Result<Value, String> {
    match name {
        "validate" => {
            let request = outbox::Request {
                chat: text_of(args, "chat").unwrap_or_default(),
                text: text_of(args, "text").unwrap_or_default(),
                reply_to: text_of(args, "reply_to"),
                mentions: args.get("mentions").and_then(Value::as_array)
                    .map(|items| items.iter().filter_map(Value::as_str).map(str::to_string).collect())
                    .unwrap_or_default(),
            };
            match request.validate() {
                Ok(verified) => Ok(json!({
                    "ok": true,
                    "chat": verified.chat.jid(),
                    "text": verified.text,
                    "reply_to": verified.reply_to,
                    "mentions": verified.mentions.iter().map(|chat| chat.jid()).collect::<Vec<String>>(),
                    "payload_hex": hex(&request.encode()),
                    "dedupe_key": request.dedupe_key(),
                    "queue": outbox::QUEUE,
                    "fresh_ms": outbox::FRESH_MS,
                    "max_attempts": outbox::MAX_ATTEMPTS,
                })),
                Err(refusal) => Ok(json!({"ok": false, "code": refusal.code, "detail": refusal.detail})),
            }
        }
        "outcome" => {
            let bytes = args.get("payload_hex").and_then(Value::as_str).and_then(unhex)
                .ok_or_else(|| "payload_hex_required".to_string())?;
            match outbox::Outcome::decode(&bytes) {
                Some(outcome) => Ok(json!({"ok": true, "message_id": outcome.message_id,
                    "note": outcome.note, "in_history": outcome.in_history})),
                None => Ok(json!({"ok": false, "code": "not_an_outcome"})),
            }
        }
        "constants" => Ok(json!({
            "queue": outbox::QUEUE, "fresh_ms": outbox::FRESH_MS, "max_attempts": outbox::MAX_ATTEMPTS,
        })),
        "status" => {
            // `wa-whatsapp-outbox::status` is the sentence a caller reads about one job: here it is
            // built where the contract lives, so the host cannot word it differently.
            let id = args.get("id").and_then(Value::as_u64).unwrap_or_default();
            let state = args.get("state").and_then(Value::as_str).unwrap_or("");
            let attempts = args.get("attempts").and_then(Value::as_u64).unwrap_or(0) as u32;
            let result = args.get("result_hex").and_then(Value::as_str).and_then(unhex);
            let last_error = args.get("last_error").and_then(Value::as_str);
            Ok(outbox::status(id, state, attempts, result.as_deref(), last_error))
        }
        other => Err(format!("unknown_tool:{other}")),
    }
}

fn main() {
    let mut out = std::io::stdout();
    let mut ready = false;
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        let method = message["method"].as_str().unwrap_or("");
        if method == "notifications/initialized" {
            ready = true;
            continue;
        }
        let Some(id) = message.get("id").cloned() else { continue };
        let answer = match method {
            "initialize" => json!({"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"outbox","version":env!("CARGO_PKG_VERSION")}}),
            "tools/list" if ready => json!({"tools": tools()}),
            "tools/call" if ready => {
                let name = message["params"]["name"].as_str().unwrap_or("");
                let args = message["params"]["arguments"].clone();
                let data = call(name, &args).unwrap_or_else(|error| json!({"ok": false, "code": error}));
                json!({"content":[{"type":"text","text":data.to_string()}],"structuredContent":data,"isError":false})
            }
            _ => {
                let _ = writeln!(out, "{}", json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"method_not_found"}}));
                let _ = out.flush();
                continue;
            }
        };
        let _ = writeln!(out, "{}", json!({"jsonrpc":"2.0","id":id,"result":answer}));
        let _ = out.flush();
    }
}
