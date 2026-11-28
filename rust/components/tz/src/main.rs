//! This node's own time-zone identifier as a WASI component: MCP over stdin/stdout, one request per
//! run, the same shape `graph` speaks (`rust/components/graph/src/main.rs`).
//!
//! Everything it does is `wa_local_tz`: `TZ` when the operator set it, else the target of
//! `/etc/localtime`, else `/etc/timezone` (the kernel mounts `/etc` read-only, `manifest.json`), and
//! the word saying which of them answered. The offset and the abbreviation are NOT here - they come
//! from the host's own C runtime (`lua/core/platform.lua`), which is what makes a native run and a
//! guest run report the same local timestamp for the same instant.
//!
//! One tool: `zone`, answered as `{id, source}`. `id` absent means the OS answered "no name", which
//! is a fact the caller prints as such rather than guessing a zone.
use serde_json::{json, Value};
use std::io::{BufRead, Write};

fn tools() -> Value {
    json!([{
        "name": "zone",
        "description": "The identifier of the time zone this node's OS is configured with (America/Sao_Paulo, UTC, ...) and which of TZ, /etc/localtime, /etc/timezone answered. Absent `id` means the OS holds no name.",
        "inputSchema": {"type": "object", "properties": {}}
    }])
}

fn call(name: &str, _args: &Value) -> Result<Value, String> {
    match name {
        "zone" => {
            let tz = std::env::var("TZ").ok();
            let zone = wa_local_tz::zone_id(tz.as_deref());
            Ok(json!({"id": zone.id, "source": zone.source}))
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
            "initialize" => json!({"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"tz","version":env!("CARGO_PKG_VERSION")}}),
            "tools/list" if ready => json!({"tools": tools()}),
            "tools/call" if ready => {
                let name = message["params"]["name"].as_str().unwrap_or("");
                let args = message["params"]["arguments"].clone();
                let data = call(name, &args).unwrap_or_else(|error| json!({"error": error}));
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
