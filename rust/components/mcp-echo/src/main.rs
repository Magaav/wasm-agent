//! Fixture MCP component: `echo` returns its arguments exactly; `env` reports what the sandbox
//! sees (granted keys only - nothing else is inherited); `spin` never returns (deadline test).
use serde_json::{json, Value};
use std::io::{BufRead, Write};

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
        let result = match method {
            "initialize" => json!({"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"mcp-echo","version":"1"}}),
            "tools/list" if ready => json!({"tools":[
                {"name":"echo","description":"Return the arguments","inputSchema":{"type":"object","properties":{"value":{}},"additionalProperties":false}},
                {"name":"env","description":"What the sandbox sees","inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
                {"name":"spin","description":"Never returns","inputSchema":{"type":"object","properties":{},"additionalProperties":false}}]}),
            "tools/call" if ready => {
                let data = match message["params"]["name"].as_str() {
                    Some("echo") => json!({"ok":true,"arguments":message["params"]["arguments"]}),
                    Some("env") => json!({"ok":true,"vars":std::env::vars().map(|(k, _)| k).collect::<Vec<_>>(),
                        "echo":std::env::var("WA_ECHO").ok(),"secret_len":std::env::var("WA_ECHO_SECRET").map(|s| s.len()).ok(),
                        "fs_root_readable":std::fs::read_dir("/").is_ok()}),
                    Some("spin") => loop { std::hint::spin_loop() },
                    _ => json!({"ok":false,"error":"unknown"}),
                };
                json!({"content":[{"type":"text","text":data.to_string()}],"structuredContent":data,"isError":data["ok"]==json!(false)})
            }
            _ => {
                let _ = writeln!(out, "{}", json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"Method not found"}}));
                continue;
            }
        };
        let _ = writeln!(out, "{}", json!({"jsonrpc":"2.0","id":id,"result":result}));
        let _ = out.flush();
    }
}
