//! The WhatsApp query contract as a WASI component: MCP over stdin/stdout, one request per run - the
//! same shape `graph`, `tz` and `outbox` speak.
//!
//! Every answer is `wa-whatsapp-index`'s own. That crate is the vocabulary of a WhatsApp query: which ops
//! exist, what a request may carry, which arguments make one valid, the refusal a bad one gets and the
//! sentence a caller reads back. The host answered all of it in-process (`
//! wa-capabilities/src/whatsapp_query.rs`, 103 references) and the `wa-whatsapp` component writes its
//! answers in the same words - which is why a change to either end rebuilt the node.
//!
//! The tools are the contract's own surface, not a convenience API:
//!  * `validate`      - one `Request` in, the `Verified` request out (or the refusal, unchanged).
//!  * `answer`        - the envelope an op's body is delivered in.
//!  * `refusal`       - the envelope a refusal makes, by op and by op *name* (the two spellings the host
//!                      uses: a typed op on the queue path, an op string on the text doors).
//!  * `state_word`    - the one word a queue state is reported as.
//!  * `parse_time`    - the time forms a caller may write, as the epoch the request carries.
//!  * `registry`      - what the ops are, for the door that answers "what can I ask".
//!  * `constants`     - the queue name, the registry op, the attempt cap and the accepted time shapes.
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use wa_whatsapp_index as contract;

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

fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// The contract's `Verified` has no serde derive on purpose (it is a checked value, not a wire shape),
/// so the component states the fields it hands over. A new field added to `Verified` without a line here
/// is a field the host cannot read - and that shows up in the tests, not in production.
fn verified_json(v: &contract::Verified) -> Value {
    json!({
        "op": v.op.as_str(),
        "q": v.q,
        "chat": v.chat,
        "chat_name": v.chat_name,
        "id": v.id,
        "kind": v.kind,
        "from": v.from,
        "since": v.since,
        "until": v.until,
        "before": v.before,
        "limit": v.limit,
        "max_bytes": v.max_bytes,
        "order": v.order.map(|order| order.as_str()),
        "full": v.full,
        "limit_asked": v.limit_asked,
    })
}

fn tools() -> Value {
    json!([
        {
            "name": "validate",
            "description": "Check one WhatsApp query request and say what it means: the op, the normalised chat and id, the effective page size. A refusal carries its own code and detail, never a guess.",
            "inputSchema": {"type": "object", "required": ["request"], "properties": {"request": {"type": "object"}}}
        },
        {
            "name": "answer",
            "description": "Wrap one op's body in the envelope every caller reads (op, status, ok, effect).",
            "inputSchema": {"type": "object", "required": ["op", "body"], "properties": {
                "op": {"type": "string"}, "body": {"type": "object"}
            }}
        },
        {
            "name": "refusal",
            "description": "The envelope a refusal makes for one typed op: the op's own error word, its message, its fix and its tier.",
            "inputSchema": {"type": "object", "required": ["op", "code"], "properties": {
                "op": {"type": "string"}, "code": {"type": "string"}, "detail": {"type": "string"}
            }}
        },
        {
            "name": "refusal_text",
            "description": "The same envelope for a door that names its op as text rather than as a value.",
            "inputSchema": {"type": "object", "required": ["op", "code"], "properties": {
                "op": {"type": "string"}, "code": {"type": "string"}, "detail": {"type": "string"}
            }}
        },
        {
            "name": "state_word",
            "description": "The one word a queue state is reported as ('queued', 'sent', ...), so two ends cannot word it differently.",
            "inputSchema": {"type": "object", "required": ["state"], "properties": {"state": {"type": "string"}}}
        },
        {
            "name": "parse_time",
            "description": "Read one time form a caller may write and answer the epoch millis a request carries, or nothing when it is not a time.",
            "inputSchema": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}}
        },
        {
            "name": "is_month",
            "description": "Whether a string is a calendar month (YYYY-MM), the form an archive read is addressed by.",
            "inputSchema": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}}
        },
        {
            "name": "permanent_code",
            "description": "The code a job failure is remembered by when it will never succeed on a retry, or nothing when it will.",
            "inputSchema": {"type": "object", "required": ["reason"], "properties": {"reason": {"type": "string"}}}
        },
        {
            "name": "download_header_job",
            "description": "The job id a download progress chunk names, or nothing when the chunk is not one.",
            "inputSchema": {"type": "object", "required": ["chunk_hex"], "properties": {"chunk_hex": {"type": "string"}}}
        },
        {
            "name": "slow",
            "description": "The answer a caller gets while one typed op's job is still running.",
            "inputSchema": {"type": "object", "required": ["op", "id"], "properties": {
                "op": {"type": "string"}, "id": {"type": "integer"}, "state": {"type": "string"}
            }}
        },
        {
            "name": "slow_text",
            "description": "The answer a caller gets while a job is still running: what state it is in, worded by the contract rather than by the door.",
            "inputSchema": {"type": "object", "required": ["op", "id"], "properties": {
                "op": {"type": "string"}, "id": {"type": "integer"}, "state": {"type": "string"}
            }}
        },
        {
            "name": "registry",
            "description": "What the ops are: the door that answers \"what can I ask\" reads this, not a copy of it.",
            "inputSchema": {"type": "object", "properties": {}}
        },
        {
            "name": "constants",
            "description": "The queue name, the registry op, the attempt cap and the accepted time shapes.",
            "inputSchema": {"type": "object", "properties": {}}
        }
    ])
}

fn call(name: &str, args: &Value) -> Result<Value, String> {
    match name {
        "validate" => {
            let raw = args.get("request").cloned().unwrap_or_else(|| json!({}));
            let request: contract::Request = serde_json::from_value(raw)
                .map_err(|error| format!("not_a_request: {error}"))?;
            // The build is part of the dedupe key (`Verified::dedupe_key_in`): a job enqueued by an
            // older build must not answer a caller of this one, so the key is computed HERE with the
            // build the caller passes, and the host never holds that rule.
            let build = args.get("build").and_then(Value::as_str).unwrap_or("");
            Ok(match request.validate() {
                Ok(verified) => json!({
                    "ok": true,
                    "verified": verified_json(&verified),
                    "op": verified.op.as_str(),
                    // The bytes the queue carries, exactly as the crate encodes them, so the host
                    // enqueues what the contract verified instead of re-encoding it itself.
                    "request_hex": hex(&verified.to_request().encode()),
                    "dedupe": verified.dedupe_key_in(build),
                }),
                Err(refusal) => json!({"ok": false, "code": refusal.code, "detail": refusal.detail}),
            })
        }
        "answer" => {
            let op = args.get("op").and_then(Value::as_str).unwrap_or("");
            let body = args.get("body").cloned().unwrap_or_else(|| json!({}));
            match contract::Op::parse(op) {
                Some(parsed) => Ok(contract::answer(parsed, body)),
                None => Err("bad_op".to_string()),
            }
        }
        "refusal" => {
            let op = args.get("op").and_then(Value::as_str).unwrap_or("");
            let code = args.get("code").and_then(Value::as_str).unwrap_or("bad_request");
            let detail = args.get("detail").and_then(Value::as_str).unwrap_or("");
            match contract::Op::parse(op) {
                Some(parsed) => Ok(contract::refusal(parsed, code, detail)),
                None => Err("bad_op".to_string()),
            }
        }
        "refusal_text" => {
            let op = args.get("op").and_then(Value::as_str).unwrap_or("");
            let code = args.get("code").and_then(Value::as_str).unwrap_or("bad_request");
            let detail = args.get("detail").and_then(Value::as_str).unwrap_or("");
            Ok(contract::refusal_text(op, code, detail))
        }
        "state_word" => {
            let state = args.get("state").and_then(Value::as_str).unwrap_or("");
            Ok(json!({"state": contract::state_word(state)}))
        }
        "slow" => {
            let op = args.get("op").and_then(Value::as_str).unwrap_or("");
            let id = args.get("id").and_then(Value::as_u64).unwrap_or_default();
            let state = args.get("state").and_then(Value::as_str).unwrap_or("");
            Ok(contract::slow_text(op, id, state))
        }
        "is_month" => {
            // Whether a string is a calendar month (`YYYY-MM`), the rule an archive read depends on.
            let text = args.get("text").and_then(Value::as_str).unwrap_or("");
            Ok(json!({"month": wa_whatsapp_index::month::is_month(text)}))
        }
        "permanent_code" => {
            // Which job failures will never succeed on a retry. The rule, not a list the door keeps.
            let reason = args.get("reason").and_then(Value::as_str).unwrap_or("");
            Ok(json!({"code": contract::permanent_code(reason)}))
        }
        "download_header_job" => {
            // The job id a download progress chunk names, or nothing when the chunk is not one.
            let hexed = args.get("chunk_hex").and_then(Value::as_str).unwrap_or("");
            let job = unhex(hexed).and_then(|bytes| contract::download_header_job(&bytes));
            Ok(json!({"job": job}))
        }
        "slow_text" => {
            let op = args.get("op").and_then(Value::as_str).unwrap_or("");
            let id = args.get("id").and_then(Value::as_u64).unwrap_or_default();
            let state = args.get("state").and_then(Value::as_str).unwrap_or("");
            Ok(contract::slow_text(op, id, state))
        }
        "parse_time" => {
            let text = args.get("text").and_then(Value::as_str).unwrap_or("");
            Ok(json!({"millis": contract::parse_time(text)}))
        }
        "registry" => Ok(contract::registry()),
        "constants" => Ok(json!({
            "queue": contract::QUEUE,
            "registry_op": contract::REGISTRY_OP,
            "max_attempts": contract::MAX_ATTEMPTS,
            "time_forms": contract::TIME_FORMS,
            "ops": contract::Op::ALL.iter().map(|op| op.as_str()).collect::<Vec<&str>>(),
            // The op -> effect table, so the host's own enum can be checked against it instead of drifting
            // (28/11: the host called `backfill` read-only and the call went to the wrong door).
            "effects": Value::Object(contract::Op::ALL.iter().map(|op| {
                let name = match op.effect() {
                    contract::Effect::ReadOnly => "read_only",
                    contract::Effect::WritesFiles => "writes_files",
                    contract::Effect::Network => "network",
                };
                (op.as_str().to_string(), Value::String(name.to_string()))
            }).collect()),
            "max_text_chars": contract::MAX_TEXT_CHARS,
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
            "initialize" => json!({"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"whatsapp-index","version":env!("CARGO_PKG_VERSION")}}),
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
