//! The email-query contract as a WASI component: MCP over stdin/stdout, one request per run - the same shape
//! `graph`, `tz`, `outbox`, `whatsapp-index` and `email-outbox` speak.
//!
//! Every answer is `wa-email-index`'s own: which fields make a query valid, the refusal a bad one gets, the
//! bytes the queue carries, and the queue with its limits. The host used to answer all of that in-process
//! (`wa-capabilities/src/email_query.rs`), which is why a change to the contract rebuilt the node.
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use wa_email_index as contract;

fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

fn tools() -> Value {
    json!([
        {
            "name": "validate",
            "description": "Check one email query and say what the queue must carry: the bytes, the op and the queue with its limits. A refusal is the contract's own envelope (ok false, error, code, detail).",
            "inputSchema": {"type": "object", "required": ["request"], "properties": {"request": {"type": "object"}}}
        },
        {
            "name": "constants",
            "description": "The queue name, its freshness and attempt cap, and the bounds a query is held to (query text, limit, scan, result size).",
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
            Ok(match request.validate() {
                Ok(_verified) => json!({
                    "ok": true,
                    // The bytes the queue carries, exactly as the contract encodes them.
                    "request_hex": hex(&request.encode()),
                    "op": serde_json::to_value(request.op).unwrap_or(Value::Null),
                    // `Request::dedupe_key` is the contract's (`hash16` of the serialised request): the same
                    // query asked twice is the same job.
                    "dedupe": request.dedupe_key(),
                    "queue": contract::QUEUE,
                    "fresh_ms": contract::FRESH_MS,
                    "max_attempts": contract::MAX_ATTEMPTS,
                }),
                Err(refusal) => contract::refusal(&refusal),
            })
        }
        "constants" => Ok(json!({
            "queue": contract::QUEUE, "fresh_ms": contract::FRESH_MS, "max_attempts": contract::MAX_ATTEMPTS,
            "max_q": contract::MAX_Q, "max_limit": contract::MAX_LIMIT, "default_limit": contract::DEFAULT_LIMIT,
            "max_scan": contract::MAX_SCAN, "result_bound": contract::RESULT_BOUND, "max_snippet": contract::MAX_SNIPPET,
            "ops": ["search", "read", "media"],
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
            "initialize" => json!({"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"email-index","version":env!("CARGO_PKG_VERSION")}}),
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
