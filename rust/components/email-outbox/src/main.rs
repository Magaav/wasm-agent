//! The email-send contract as a WASI component: MCP over stdin/stdout, one request per run - the same shape
//! `graph`, `tz`, `outbox` and `whatsapp-index` speak.
//!
//! Every answer is `wa-email-outbox`'s own: which mailboxes the request names, what it may carry, the payload
//! the queue holds, its dedupe key, the spend target, and the outcome a worker reports. The host used to
//! answer all of that in-process, which is why a change to either end of the email queue rebuilt the node.
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use wa_email_outbox as outbox;

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

fn text_of(args: &Value, key: &str) -> Option<String> {
    args.get(key).and_then(Value::as_str).map(str::to_string).filter(|text| !text.is_empty())
}

fn list_of(args: &Value, key: &str) -> Vec<String> {
    match args.get(key) {
        Some(Value::Array(items)) => items.iter().filter_map(Value::as_str).map(str::to_string).collect(),
        Some(Value::String(text)) => vec![text.clone()],
        _ => Vec::new(),
    }
}

fn tools() -> Value {
    json!([
        {
            "name": "validate",
            "description": "Check one email send and say what the queue must carry: the normalised mailboxes, the payload bytes, the dedupe key for this build, the queue and its limits, and the policy target the spend is accounted against. A refusal carries its own code and detail.",
            "inputSchema": {"type": "object", "required": ["request"], "properties": {
                "request": {"type": "object"}, "build": {"type": "string"}
            }}
        },
        {
            "name": "status",
            "description": "One queued send's state, in the contract's own words: a done job's message id, a pending one's wait, a failure's reason.",
            "inputSchema": {"type": "object", "required": ["id", "state"], "properties": {
                "id": {"type": "integer"}, "state": {"type": "string"}, "attempts": {"type": "integer"},
                "result_hex": {"type": "string"}, "last_error": {"type": "string"}
            }}
        },
        {
            "name": "audit_target",
            "description": "The policy target a send is accounted against (the recipients' digest).",
            "inputSchema": {"type": "object", "required": ["recipients"], "properties": {
                "recipients": {"type": "array", "items": {"type": "string"}}
            }}
        },
        {
            "name": "constants",
            "description": "The queue name, its freshness, the attempt cap, the recipient/subject/body/attachment limits and the default rate policy.",
            "inputSchema": {"type": "object", "properties": {}}
        }
    ])
}

fn call(name: &str, args: &Value) -> Result<Value, String> {
    match name {
        "validate" => {
            let raw = args.get("request").cloned().unwrap_or_else(|| json!({}));
            // The attachment bytes travel as hex from the host (it already decoded the base64 a caller
            // wrote) and are rebuilt here, so the contract sees the same `Attachment` it always did.
            let attachments = match raw.get("attachments") {
                Some(Value::Array(items)) => items
                    .iter()
                    .map(|item| outbox::Attachment {
                        filename: item.get("filename").and_then(Value::as_str).unwrap_or_default().to_string(),
                        mime: item.get("mime").and_then(Value::as_str).unwrap_or_default().to_string(),
                        bytes: item.get("bytes_hex").and_then(Value::as_str).and_then(unhex).unwrap_or_default(),
                    })
                    .collect(),
                _ => Vec::new(),
            };
            let request = outbox::Request {
                to: list_of(&raw, "to"),
                cc: list_of(&raw, "cc"),
                subject: raw.get("subject").and_then(Value::as_str).unwrap_or_default().to_string(),
                body: raw.get("body").and_then(Value::as_str).unwrap_or_default().to_string(),
                in_reply_to: text_of(&raw, "in_reply_to"),
                attachments,
            };
            let _build = args.get("build").and_then(Value::as_str).unwrap_or("");
            Ok(match request.validate() {
                Ok(verified) => {
                    let recipients = verified.recipients();
                    let addresses: Vec<String> = recipients.iter().map(|mailbox| mailbox.addr()).collect();
                    json!({
                        "ok": true,
                        "request_hex": hex(&request.encode()),
                        // The contract's key is the request alone (`sha256(to|cc|subject|body|in_reply_to)`);
                        // the WhatsApp contract scopes its key to the component build and this one does not.
                        // I do not change that here: `build` is carried for the day it does.
                        "dedupe": request.dedupe_key(),
                        "recipients": addresses.len(),
                        "audit_target": outbox::audit_target(&recipients),
                        "queue": outbox::QUEUE,
                        "fresh_ms": outbox::FRESH_MS,
                        "max_attempts": outbox::MAX_ATTEMPTS,
                    })
                }
                Err(refusal) => json!({"ok": false, "code": refusal.code, "detail": refusal.detail}),
            })
        }
        "status" => {
            let id = args.get("id").and_then(Value::as_u64).unwrap_or_default();
            let state = args.get("state").and_then(Value::as_str).unwrap_or("");
            let attempts = args.get("attempts").and_then(Value::as_u64).unwrap_or_default() as u32;
            let result = args.get("result_hex").and_then(Value::as_str).and_then(unhex);
            let last_error = args.get("last_error").and_then(Value::as_str);
            Ok(outbox::status(id, state, attempts, result.as_deref(), last_error))
        }
        "audit_target" => {
            let recipients: Vec<String> = list_of(args, "recipients");
            let parsed: Vec<outbox::Mailbox> = recipients.iter().filter_map(|text| outbox::Mailbox::parse(text).ok()).collect();
            let refs: Vec<&outbox::Mailbox> = parsed.iter().collect();
            Ok(json!({"target": outbox::audit_target(&refs)}))
        }
        "constants" => Ok(json!({
            "queue": outbox::QUEUE, "fresh_ms": outbox::FRESH_MS, "max_attempts": outbox::MAX_ATTEMPTS,
            "max_recipients": outbox::MAX_RECIPIENTS, "max_subject": outbox::MAX_SUBJECT,
            "max_body": outbox::MAX_BODY, "max_attachments": outbox::MAX_ATTACHMENTS,
            "max_attachment_bytes": outbox::MAX_ATTACHMENT_BYTES,
        })),
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
            "initialize" => json!({"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"email-outbox","version":env!("CARGO_PKG_VERSION")}}),
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
