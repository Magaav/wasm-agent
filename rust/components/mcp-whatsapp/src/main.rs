//! The WhatsApp linked-device MCP, as a WASI component (wasm32-wasip2).
//!
//! It was ported from `scripts/mcp-whatsapp.mjs`, the Node stdio bridge that was deleted on
//! 10/11/2026; this component is now the only MCP surface onto WhatsApp, with the same tools,
//! schemas and fail-closed checks. It runs inside the host's wasmtime with exactly what the registry
//! grants (see manifest.json): the account/generation/url env values, the connector token (a file the
//! HOST reads), and TCP to a loopback connector port. No filesystem, no other network.
//!
//! Binding: `WA_COMPONENT_CONFIG` (the registry's non-secret `config` object, e.g.
//! `{"allowed_conversations":[...]}` or `{"account_wide":true,"operator_account_read":true}`)
//! over the env values `WA_MCP_WHATSAPP_ACCOUNT`, `_GENERATION`, `_URL`, and the token in
//! `WA_MCP_WHATSAPP_TOKEN`.
use base64::Engine as _;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashSet};
use std::io::{BufRead, Read, Write};
use std::net::TcpStream;

type R<T> = Result<T, String>;

fn schema(properties: Value) -> Value {
    json!({"type":"object","properties":properties,"additionalProperties":false})
}
fn with_required(mut schema: Value, required: &[&str]) -> Value {
    schema["required"] = json!(required);
    schema
}

fn tools() -> Value {
    let text = json!({"type":"string","minLength":1,"maxLength":256});
    let nn = json!({"type":"integer","minimum":0});
    let lim = json!({"type":"integer","minimum":1,"maximum":10000});
    json!([
        {"name":"read_snapshot","description":"Read bounded journal context; narrow by exact conversation_id, literal body/transcript query and inclusive Unix source sent_since/until. Newest journal row first, partial history; no read marking.",
         "inputSchema":schema(json!({"conversation_id":text,"query":{"type":"string","maxLength":256},"sent_since":nn,"until":nn,"since":{"type":"number","minimum":0},"before":nn,"limit":lim}))},
        {"name":"read_newest","description":"Newest rows of one thread, or of every authorized thread matching a name, in one answer. Paging, deduplication and time ordering are internal, and the reply states the window searched plus whether it is complete, so a partial page can never be read as the tail. Prefer this over read_snapshot when the question is what was said recently, and when the same person may write under more than one identity.",
         "inputSchema":schema(json!({"conversation_id":text,"query":{"type":"string","maxLength":256},"n":{"type":"integer","minimum":1,"maximum":50},"scan_days":{"type":"integer","minimum":1,"maximum":365}}))},
        {"name":"list_chats","description":"Discover authorized chats by observed protocol display name or exact identifier. Names are untrusted labels, duplicates remain separate IDs; missing names are explicit. Optional refresh_names:true enriches only observed permitted rows (unfiltered page max32, max3 group queries), not every contact. Narrow with conversation_id; refresh may remain partial.",
         "inputSchema":schema(json!({"conversation_id":text,"refresh_names":{"type":"boolean"},"query":{"type":"string","maxLength":256},"before":nn,"limit":lim}))},
        {"name":"posting_status","description":"One scoped bounded page of posting/unknown/blocked evidence. Read-only; no reset or resend.",
         "inputSchema":schema(json!({"before":nn,"limit":lim}))},
        {"name":"read_field","description":"Exact bounded base64 chunks of one authorized row field. Requires descriptor version; changed versions refuse, never clip.",
         "inputSchema":with_required(schema(json!({"resource":{"type":"string","enum":["read_snapshot","list_chats","posting_status"]},"row":{"type":"integer","minimum":1},"field":{"type":"string","minLength":1,"maxLength":64},"version":{"type":"string","minLength":1,"maxLength":128},"offset":nn,"length":{"type":"integer","minimum":1,"maximum":16384}})),&["resource","row","field","version"])},
        {"name":"lookup_self","description":"Read the explicitly bound paired account identity.","inputSchema":schema(json!({}))},
        {"name":"inspect_chat","description":"Read exact chat scope; cross-device drafts are unsupported, not absent.",
         "inputSchema":with_required(schema(json!({"conversation_id":text})),&["conversation_id"])},
        {"name":"download_audio","description":"Private media access is reserved to the deterministic connector worker.",
         "inputSchema":with_required(schema(json!({"conversation_id":text,"message_id":text})),&["conversation_id","message_id"])},
        {"name":"send_message","description":"General model sends fail closed: cross-device draft visibility is unsupported. Transcript posting is a separate explicitly activated deterministic policy.",
         "inputSchema":with_required(schema(json!({"conversation_id":text,"body":{"type":"string","minLength":1,"maxLength":4096},"confirm":{"type":"boolean","const":true}})),&["conversation_id","body","confirm"])}
    ])
}

const PAGED: [&str; 3] = ["read_snapshot", "list_chats", "posting_status"];

struct Binding {
    account: String,
    generation: i64,
    host: String,
    port: u16,
    token: String,
    allowed: Vec<String>,
    wide: bool,
}

fn binding() -> R<Binding> {
    let explicit: Value = match std::env::var("WA_COMPONENT_CONFIG") {
        Ok(text) => serde_json::from_str(&text).map_err(|_| "invalid_whatsapp_profile")?,
        Err(_) => json!({}),
    };
    if !explicit.is_object() {
        return Err("invalid_whatsapp_profile".into());
    }
    let pick = |key: &str, env: &str| explicit.get(key).cloned().or_else(|| std::env::var(env).ok().map(Value::String));
    let account = pick("account", "WA_MCP_WHATSAPP_ACCOUNT").and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default();
    let generation = match pick("generation", "WA_MCP_WHATSAPP_GENERATION") {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        Some(Value::String(s)) => s.parse().unwrap_or(0),
        _ => 0,
    };
    let url = pick("connector_url", "WA_MCP_WHATSAPP_URL").and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default();
    let wide = explicit.get("account_wide") == Some(&json!(true)) && explicit.get("operator_account_read") == Some(&json!(true));
    let allowed: Vec<String> = explicit
        .get("allowed_conversations")
        .and_then(Value::as_array)
        .map(|list| list.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    if explicit.get("backend").is_some_and(|b| b != "linked_device")
        || account.is_empty()
        || generation < 1
        || (!wide && (allowed.is_empty() || allowed.len() > 256))
        || (!wide && explicit.get("account_wide") == Some(&json!(true)))
    {
        return Err("linked_device_account_generation_chat_binding_required".into());
    }
    // Loopback http only inside a component: no TLS stack, no remote connector.
    let rest = url.strip_prefix("http://").ok_or("component_supports_loopback_connector_only")?;
    // `http://127.0.0.1:28787` and `.../` are the same origin (the Node server normalizes both).
    let hostport = rest.strip_suffix('/').unwrap_or(rest);
    if hostport.contains('/') || hostport.contains('@') || hostport.contains('?') || hostport.contains('#') {
        return Err("connector_url_must_not_contain_credentials_or_path".into());
    }
    let (host, port) = hostport.rsplit_once(':').ok_or("component_supports_loopback_connector_only")?;
    if host != "127.0.0.1" && host != "[::1]" {
        return Err("component_supports_loopback_connector_only".into());
    }
    let port: u16 = port.parse().map_err(|_| "component_supports_loopback_connector_only")?;
    let token = std::env::var("WA_MCP_WHATSAPP_TOKEN").map_err(|_| "connector_token_file_required")?.trim().to_string();
    if token.len() != 64 || !token.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) {
        return Err("invalid_private_connector_token".into());
    }
    Ok(Binding { account, generation, host: host.trim_matches(|c| c == '[' || c == ']').to_string(), port, token, allowed, wide })
}

fn http_post(b: &Binding, method: &str, body: &str, limit: usize) -> R<(u16, Vec<u8>)> {
    let target = if b.host.contains(':') { format!("[{}]:{}", b.host, b.port) } else { format!("{}:{}", b.host, b.port) };
    let mut stream = TcpStream::connect(&target).map_err(|_| "connector_transport_failed")?;
    let request = format!(
        "POST /{method} HTTP/1.1\r\nHost: {target}\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        b.token,
        body.len()
    );
    stream.write_all(request.as_bytes()).map_err(|_| "connector_transport_failed")?;
    let mut raw = Vec::new();
    let mut chunk = [0u8; 65536];
    loop {
        let n = stream.read(&mut chunk).map_err(|_| "connector_response_failed")?;
        if n == 0 {
            break;
        }
        raw.extend_from_slice(&chunk[..n]);
        if raw.len() > limit + 65536 {
            return Err("connector_response_too_large".into());
        }
    }
    let split = raw.windows(4).position(|w| w == b"\r\n\r\n").ok_or("connector_response_invalid")?;
    let head = String::from_utf8_lossy(&raw[..split]).to_ascii_lowercase();
    let mut payload = raw[split + 4..].to_vec();
    let status: u16 = head.split_whitespace().nth(1).and_then(|s| s.parse().ok()).ok_or("connector_response_invalid")?;
    if head.lines().any(|line| line.starts_with("transfer-encoding:") && line.contains("chunked")) {
        payload = dechunk(&payload)?;
    }
    if payload.len() > limit {
        return Err("connector_response_too_large".into());
    }
    Ok((status, payload))
}

fn dechunk(mut data: &[u8]) -> R<Vec<u8>> {
    let mut out = Vec::new();
    loop {
        let line_end = data.windows(2).position(|w| w == b"\r\n").ok_or("connector_response_invalid")?;
        let size_text = String::from_utf8_lossy(&data[..line_end]);
        let size = usize::from_str_radix(size_text.split(';').next().unwrap_or("").trim(), 16).map_err(|_| "connector_response_invalid")?;
        data = &data[line_end + 2..];
        if size == 0 {
            return Ok(out);
        }
        if data.len() < size + 2 {
            return Err("connector_response_invalid".into());
        }
        out.extend_from_slice(&data[..size]);
        data = &data[size + 2..];
    }
}

fn connector(b: &Binding, method: &str, args: Map<String, Value>) -> R<(Value, usize)> {
    let paged = PAGED.contains(&method);
    let limit = if paged { 4 << 20 } else if method == "read_field" { 64 << 10 } else { 24 << 20 };
    let mut body = Map::new();
    body.insert("account".into(), json!(b.account));
    body.insert("generation".into(), json!(b.generation));
    body.extend(args);
    let (status, payload) = http_post(b, method, &Value::Object(body).to_string(), limit)?;
    if (300..400).contains(&status) {
        return Err("connector_redirect_refused".into());
    }
    let data: Value = serde_json::from_slice(&payload).map_err(|_| "connector_response_invalid")?;
    if paged
        && data["ok"] == json!(true)
        && (data["page_version"] != json!(2) || data["encoded_bytes"] != json!(payload.len()) || data["byte_limit"] != json!(4 << 20))
    {
        return Err("connector_requires_byte_page_v2".into());
    }
    Ok((data, payload.len()))
}

fn int(args: &Map<String, Value>, key: &str, default: i64) -> R<i64> {
    match args.get(key) {
        None => Ok(default),
        Some(v) => v.as_i64().filter(|n| n.abs() < (1 << 53)).ok_or_else(|| format!("invalid_{key}")),
    }
}

fn adapter(b: &Binding, name: &str, args: Map<String, Value>) -> R<Value> {
    let all = tools();
    let tool = all.as_array().unwrap().iter().find(|t| t["name"] == name).ok_or("invalid_whatsapp_mcp_call")?;
    let props = tool["inputSchema"]["properties"].as_object().cloned().unwrap_or_default();
    for key in args.keys() {
        if !props.contains_key(key) {
            return Err(format!("unsupported_whatsapp_argument:{key}"));
        }
    }
    for key in tool["inputSchema"]["required"].as_array().cloned().unwrap_or_default() {
        if !args.contains_key(key.as_str().unwrap_or("")) {
            return Err(format!("whatsapp_argument_required:{}", key.as_str().unwrap_or("")));
        }
    }
    let conv = args.get("conversation_id").and_then(Value::as_str).map(str::to_string);
    if let Some(c) = &conv {
        if !b.wide && !b.allowed.contains(c) {
            return Err("whatsapp_conversation_not_bound".into());
        }
    }
    match name {
        "send_message" => return Ok(json!({"ok":false,"error":"general_send_refused_draft_visibility_unsupported","pre_dispatch":true})),
        "download_audio" => return Ok(json!({"ok":false,"error":"media_is_private_to_deterministic_worker","pre_dispatch":true})),
        _ => {}
    }
    let scope = |m: &mut Map<String, Value>, wide: bool, selected: &[String]| {
        if wide {
            m.insert("account_wide".into(), json!(true));
        } else {
            m.insert("conversations".into(), json!(selected));
        }
    };
    if name == "read_field" {
        let resource = args.get("resource").and_then(Value::as_str).unwrap_or("");
        let row = int(&args, "row", 0)?;
        let offset = int(&args, "offset", 0)?;
        let length = int(&args, "length", 16384)?;
        if !PAGED.contains(&resource) || row < 1 || offset < 0 || !(1..=16384).contains(&length) {
            return Err("invalid_field_window".into());
        }
        let mut request = args.clone();
        scope(&mut request, b.wide, &b.allowed);
        let (data, _) = connector(b, name, request)?;
        if data["ok"] != json!(true) {
            return Ok(data);
        }
        if data["account"] != json!(b.account)
            || data["generation"] != json!(b.generation)
            || data["scope_kind"] != json!(if b.wide { "account" } else { "selected" })
            || (!b.wide && !b.allowed.iter().any(|c| data["conversation_id"] == json!(c)))
        {
            return Err("connector_response_scope_mismatch".into());
        }
        let encoded = data["data_base64"].as_str().unwrap_or("");
        let chunk = base64::engine::general_purpose::STANDARD.decode(encoded).map_err(|_| "connector_content_no_progress")?;
        let byte_length = data["byte_length"].as_i64().unwrap_or(-1);
        let next = data["next_offset"].as_i64().unwrap_or(-1);
        let n = chunk.len() as i64;
        if data["content_encoding"] != "base64"
            || data["resource"] != json!(resource)
            || data["row"] != json!(row)
            || data["field"] != args["field"]
            || data["field_version"] != args["version"]
            || data["offset"] != json!(offset)
            || base64::engine::general_purpose::STANDARD.encode(&chunk) != encoded
            || data["chunk_bytes"] != json!(n)
            || n > length
            || next != offset + n
            || data["complete"] != json!(next == byte_length)
            || (offset < byte_length && n == 0)
        {
            return Err("connector_content_no_progress".into());
        }
        return Ok(data);
    }
    if PAGED.contains(&name) {
        let refresh = args.get("refresh_names");
        let since = int(&args, "since", 0)?;
        let before = int(&args, "before", 0)?;
        let limit = int(&args, "limit", if refresh == Some(&json!(true)) { 32 } else { 2000 })?;
        if before < 0 || since < 0 || !(1..=10000).contains(&limit) {
            return Err("invalid_whatsapp_snapshot_window".into());
        }
        let query = match args.get("query") {
            None => String::new(),
            Some(Value::String(s)) => s.clone(),
            _ => return Err("invalid_whatsapp_search_window".into()),
        };
        let sent_since = int(&args, "sent_since", 0)?;
        let until = int(&args, "until", 0)?;
        if query.len() > 256 || sent_since < 0 || until < 0 || (until != 0 && sent_since > until) || conv.as_deref() == Some("") {
            return Err("invalid_whatsapp_search_window".into());
        }
        if let Some(r) = refresh {
            if !r.is_boolean() || name != "list_chats" || (r == &json!(true) && (!query.is_empty() || limit > 32)) {
                return Err("refresh_requires_unfiltered_page_max32".into());
            }
        }
        // A model may NARROW an approved binding, never widen it.
        let request_wide = b.wide && conv.is_none();
        let selected: Vec<String> = match &conv {
            Some(c) => vec![c.clone()],
            None => b.allowed.clone(),
        };
        let mut request = Map::new();
        for (k, v) in [("since", json!(since)), ("before", json!(before)), ("limit", json!(limit)), ("query", json!(query)), ("sent_since", json!(sent_since)), ("until", json!(until))] {
            request.insert(k.into(), v);
        }
        if let Some(r) = refresh {
            request.insert("refresh_names".into(), r.clone());
        }
        scope(&mut request, request_wide, &selected);
        let (mut data, _) = connector(b, name, request)?;
        if data["ok"] != json!(true) {
            return Ok(data);
        }
        if data["account"] != json!(b.account) || data["generation"] != json!(b.generation) {
            return Err("connector_response_scope_mismatch".into());
        }
        if data["cursor_version"] != json!(1)
            || data["limit_scope"] != "total"
            || data["scope_kind"] != json!(if request_wide { "account" } else { "selected" })
            || data["source_state"].is_null()
            || data["source_state"] == json!(false)
        {
            return Err("connector_requires_total_page_v1".into());
        }
        let permitted = |id: &Value| -> bool {
            let Some(id) = id.as_str() else { return false };
            if !request_wide {
                return selected.iter().any(|s| s == id);
            }
            let parts: Vec<&str> = id.split('@').collect();
            parts.len() == 2
                && !parts[0].is_empty()
                && parts[0].bytes().all(|c| c.is_ascii_alphanumeric() || b":._-".contains(&c))
                && ["s.whatsapp.net", "lid", "g.us"].contains(&parts[1])
        };
        let order = data["order"].as_array().cloned().ok_or("connector_page_no_progress")?;
        let delivered = data["rows_delivered"].as_i64().unwrap_or(-1);
        let truncated = data["truncated"] == json!(true) || data["byte_truncated"] == json!(true);
        if delivered != order.len() as i64
            || delivered > limit
            || (truncated && (delivered == 0 || order.last().map(|o| &o["cursor"]) != Some(&data["next_before"])))
        {
            return Err("connector_page_no_progress".into());
        }
        let key = match name { "read_snapshot" => "messages", "list_chats" => "conversations", _ => "posts" };
        let primary = data[key].as_array().cloned().unwrap_or_default();
        let oversized = data["oversized_rows"].as_array().cloned().unwrap_or_default();
        if delivered != (primary.len() + oversized.len()) as i64 || (data["truncated"] != json!(true) && data["next_before"] != json!(0)) {
            return Err("connector_page_no_progress".into());
        }
        let mut previous = if before > 0 { before } else { i64::MAX };
        let mut seen = HashSet::new();
        for outcome in &order {
            let index = outcome["index"].as_i64().unwrap_or(-1);
            let cursor = outcome["cursor"].as_i64().unwrap_or(0);
            let array = match outcome["kind"].as_str() { Some("inline") => Some(&primary), Some("oversized") => Some(&oversized), _ => None };
            let item = array.and_then(|a| usize::try_from(index).ok().and_then(|i| a.get(i)));
            let k = format!("{}:{}", outcome["kind"], index);
            if cursor <= 0 || cursor >= previous || index < 0 || item.is_none() || seen.contains(&k) || item.map(|i| &i["cursor"]) != Some(&outcome["cursor"]) {
                return Err("connector_page_order_invalid".into());
            }
            seen.insert(k);
            previous = cursor;
        }
        if oversized.iter().any(|row| {
            row["resource"] != json!(name)
                || row["inline_complete"] != json!(false)
                || (!request_wide && !permitted(&row["conversation_id"]))
                || (request_wide && !row["conversation_id"].is_null() && !permitted(&row["conversation_id"]))
        }) {
            return Err("connector_response_scope_mismatch".into());
        }
        let field = |key: &str, id: &str| -> bool {
            data[key].as_array().is_some_and(|rows| rows.len() as i64 > limit || rows.iter().any(|r| !permitted(&r[id])))
        };
        if field("messages", "conversation_id") || field("conversations", "id") || field("posts", "conversation_id") {
            return Err("connector_response_scope_or_limit_mismatch".into());
        }
        if refresh == Some(&json!(true)) && (data["name_refresh"]["version"] != json!(1) || data["names_version"] != json!(1)) {
            return Err("connector_requires_name_refresh_v1".into());
        }
        let (mut newest, mut oldest) = (0i64, 0i64);
        let messages = data["messages"].as_array().cloned().unwrap_or_default();
        for m in &messages {
            let at = m["sent_at"].as_i64().unwrap_or(0);
            if at <= 0 {
                continue;
            }
            if newest == 0 || at > newest { newest = at; }
            if oldest == 0 || at < oldest { oldest = at; }
        }
        data["page"] = json!({"truncated": data["truncated"] == json!(true), "next_before": data["next_before"], "rows": delivered, "newest_sent_at": newest, "oldest_sent_at": oldest});
        // A no-window read asks for the newest rows; a forward-running truncated page is not them.
        if name == "read_snapshot" && before == 0 && sent_since == 0 && until == 0 && data["truncated"] == json!(true) && newest > 0 && oldest > 0 && newest > oldest
            && messages.len() > 1 && messages[0]["sent_at"] == json!(oldest) && messages[messages.len() - 1]["sent_at"] == json!(newest)
        {
            return Err("connector_page_not_newest".into());
        }
        return Ok(data);
    }
    let (data, _) = connector(b, name, args)?;
    if data["ok"] == json!(true) && (data["account"] != json!(b.account) || data["generation"] != json!(b.generation)) {
        return Err("connector_response_scope_mismatch".into());
    }
    Ok(data)
}

fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// read_newest: newest rows without paging by the caller and without trusting a name match.
fn read_newest(b: &Binding, args: &Map<String, Value>) -> R<Value> {
    const MAX_PAGES: usize = 6;
    const WANT: i64 = 100;
    let n = int(args, "n", 10)?;
    let scan = int(args, "scan_days", 30)?;
    let conv = match args.get("conversation_id") {
        None => None,
        Some(Value::String(s)) if !s.is_empty() && s.len() <= 256 => Some(s.clone()),
        _ => return Err("invalid_newest_conversation".into()),
    };
    let q = match args.get("query") {
        None => None,
        Some(Value::String(s)) if s.len() <= 256 => Some(s.clone()),
        _ => return Err("invalid_newest_query".into()),
    };
    if !(1..=50).contains(&n) {
        return Err("invalid_newest_count".into());
    }
    if !(1..=365).contains(&scan) {
        return Err("invalid_newest_window".into());
    }
    if conv.is_none() && q.is_none() {
        return Err("newest_needs_conversation_or_query".into());
    }
    let since = now() - scan * 86400;
    let mut rows: BTreeMap<String, Value> = BTreeMap::new();
    let mut threads: Vec<Value> = Vec::new();
    let mut errors = Vec::new();
    let (mut pages, mut complete) = (0, true);
    let keep = |rows: &mut BTreeMap<String, Value>, m: &Value, fallback: Option<&str>| {
        let at = m["sent_at"].as_i64().unwrap_or(-1);
        if at < since {
            return;
        }
        let id = m["conversation_id"].as_str().or(fallback).unwrap_or("").to_string();
        let cursor = if m["cursor"].is_null() { m["id"].to_string() } else { m["cursor"].to_string() };
        let mut row = m.clone();
        row["conversation_id"] = json!(id);
        rows.insert(format!("{id}:{cursor}"), row);
    };
    let mut matched: Vec<(String, String)> = Vec::new();
    if let Some(c) = &conv {
        matched.push((c.clone(), String::new()));
    } else {
        let mut list = Map::new();
        list.insert("query".into(), json!(q.clone().unwrap()));
        list.insert("limit".into(), json!(32));
        let found = match adapter(b, "list_chats", list) { Ok(v) => v, Err(e) => return Ok(json!({"ok":false,"error":e})) };
        if found["ok"] != json!(true) {
            return Ok(found);
        }
        for chat in found["conversations"].as_array().cloned().unwrap_or_default() {
            if let Some(id) = chat["id"].as_str() {
                matched.push((id.to_string(), chat["title"].as_str().unwrap_or("").to_string()));
            }
        }
    }
    for (id, title) in &matched {
        threads.push(json!({"id":id,"title":title,"matched":true,"rows":0,"newest_sent_at":0}));
    }
    // A refusal (Err: unbound chat, bad window) fails the whole call, as the Node reader's thrown
    // error does; only a connector answer with ok:false is recorded per thread and scanning goes on.
    let scan_leg = |rows: &mut BTreeMap<String, Value>, conversation: Option<&str>, errors: &mut Vec<Value>, pages: &mut i32, complete: &mut bool| -> R<()> {
        let mut before = 0i64;
        for page in 0..MAX_PAGES {
            let mut request = Map::new();
            if let Some(c) = conversation {
                request.insert("conversation_id".into(), json!(c));
            }
            request.insert("sent_since".into(), json!(since));
            request.insert("limit".into(), json!(WANT));
            if before > 0 {
                request.insert("before".into(), json!(before));
            }
            let data = adapter(b, "read_snapshot", request)?;
            *pages += 1;
            if data["ok"] != json!(true) {
                errors.push(json!({"conversation_id":conversation,"error":data["error"]}));
                break;
            }
            let messages = data["messages"].as_array().cloned().unwrap_or_default();
            for m in &messages {
                keep(rows, m, conversation);
            }
            let next = data["next_before"].as_i64().unwrap_or(0);
            if data["truncated"] != json!(true) || next == 0 || messages.is_empty() {
                break;
            }
            before = next;
            if page == MAX_PAGES - 1 {
                *complete = false;
            }
        }
        Ok(())
    };
    for (id, _) in &matched {
        scan_leg(&mut rows, Some(id), &mut errors, &mut pages, &mut complete)?;
    }
    // The account-wide leg makes a renamed or dual-identity thread unable to hide its rows.
    if b.wide && conv.is_none() {
        scan_leg(&mut rows, None, &mut errors, &mut pages, &mut complete)?;
    }
    let mut all: Vec<Value> = rows.into_values().collect();
    all.sort_by_key(|r| std::cmp::Reverse(r["sent_at"].as_i64().unwrap_or(0)));
    for row in &all {
        let id = row["conversation_id"].as_str().unwrap_or("");
        let at = row["sent_at"].as_i64().unwrap_or(0);
        let t = match threads.iter_mut().find(|t| t["id"] == json!(id)) {
            Some(t) => t,
            None => {
                threads.push(json!({"id":id,"title":"","matched":false,"rows":0,"newest_sent_at":0}));
                threads.last_mut().unwrap()
            }
        };
        t["rows"] = json!(t["rows"].as_i64().unwrap_or(0) + 1);
        if at > t["newest_sent_at"].as_i64().unwrap_or(0) {
            t["newest_sent_at"] = json!(at);
        }
    }
    let mut summary: Vec<Value> = threads.into_iter().filter(|t| t["rows"].as_i64().unwrap_or(0) > 0 || t["matched"] == json!(true)).collect();
    summary.sort_by_key(|t| std::cmp::Reverse(t["newest_sent_at"].as_i64().unwrap_or(0)));
    let is_matched = |id: &Value| summary.iter().any(|t| &t["id"] == id && t["matched"] == json!(true));
    let n = n as usize;
    let messages: Vec<Value> = all.iter().take(n).cloned().collect();
    let matched_messages: Vec<Value> = all.iter().filter(|m| is_matched(&m["conversation_id"])).take(n).cloned().collect();
    let newest_matched = matched_messages.first().and_then(|m| m["sent_at"].as_i64()).unwrap_or(0);
    let loudest = summary.iter().find(|t| t["matched"] != json!(true) && t["rows"].as_i64().unwrap_or(0) > 0).cloned();
    let mut answer = json!({"ok":true,"conversation_id":conv,"query":q,"window_days":scan,"searched_since":since,"account_wide_scan":b.wide,
        "pages_read":pages,"rows_seen":all.len(),"complete":complete && errors.is_empty(),"messages":messages,"matched_messages":matched_messages});
    if let (Some(first), Some(last)) = (answer["messages"].as_array().and_then(|m| m.first()).cloned(), answer["messages"].as_array().and_then(|m| m.last()).cloned()) {
        answer["newest_sent_at"] = first["sent_at"].clone();
        answer["oldest_sent_at"] = last["sent_at"].clone();
    } else {
        answer["note"] = json!("no authorized message in the stated window");
    }
    if let (Some(_), Some(other)) = (&q, loudest) {
        if other["newest_sent_at"].as_i64().unwrap_or(0) > newest_matched {
            let title = other["title"].as_str().unwrap_or("");
            answer["hint"] = json!(format!(
                "newest rows are outside the name-matched threads: {} has {} row(s){}{}",
                other["id"].as_str().unwrap_or(""),
                other["rows"],
                if title.is_empty() { String::new() } else { format!(" ({title})") },
                if answer["matched_messages"].as_array().is_some_and(|m| !m.is_empty()) { "; the newest name-matched row is older" } else { "" }
            ));
        }
    }
    answer["threads"] = json!(summary);
    if !errors.is_empty() {
        answer["errors"] = json!(errors);
    }
    Ok(answer)
}

fn call(name: &str, args: Map<String, Value>) -> Value {
    let outcome = binding().and_then(|b| if name == "read_newest" { read_newest(&b, &args) } else { adapter(&b, name, args) });
    match outcome {
        Ok(data) => data,
        Err(error) => json!({"ok": false, "error": error}),
    }
}

/// Minimal stdio MCP server: the same protocol contract as scripts/mcp-server-core.mjs.
fn main() {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout();
    let mut send = |value: Value| {
        let _ = writeln!(out, "{value}");
        let _ = out.flush();
    };
    let (mut initialized, mut ready) = (false, false);
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let Ok(message) = serde_json::from_str::<Value>(&line) else {
            send(json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}));
            continue;
        };
        let method = message["method"].as_str().unwrap_or("");
        if message["jsonrpc"] != "2.0" {
            send(json!({"jsonrpc":"2.0","id":message.get("id").cloned().unwrap_or(Value::Null),"error":{"code":-32600,"message":"Invalid Request"}}));
            continue;
        }
        if method == "notifications/initialized" {
            ready = initialized;
            continue;
        }
        let Some(id) = message.get("id").cloned() else { continue };
        let error = |code: i64, text: &str| json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":text}});
        match method {
            "initialize" => {
                if initialized {
                    send(error(-32600, "Already initialized"));
                    continue;
                }
                let asked = message["params"]["protocolVersion"].as_str().unwrap_or("");
                let selected = if ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"].contains(&asked) { asked } else { "2025-11-25" };
                initialized = true;
                send(json!({"jsonrpc":"2.0","id":id,"result":{"protocolVersion":selected,"capabilities":{"tools":{}},"serverInfo":{"name":"wasm-agent-whatsapp","version":"1"}}}));
            }
            "ping" => send(json!({"jsonrpc":"2.0","id":id,"result":{}})),
            _ if !ready => send(error(-32000, "Initialize first")),
            "tools/list" => send(json!({"jsonrpc":"2.0","id":id,"result":{"tools":tools()}})),
            "tools/call" => {
                let name = message["params"]["name"].as_str().unwrap_or("");
                if !tools().as_array().unwrap().iter().any(|t| t["name"] == name) {
                    send(error(-32602, "Unknown tool"));
                    continue;
                }
                let args = message["params"]["arguments"].as_object().cloned().unwrap_or_default();
                let data = call(name, args);
                let is_error = data["ok"] == json!(false);
                send(json!({"jsonrpc":"2.0","id":id,"result":{"content":[{"type":"text","text":data.to_string()}],"structuredContent":data,"isError":is_error}}));
            }
            _ => send(error(-32601, "Method not found")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dechunks_go_responses() {
        assert_eq!(dechunk(b"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n").unwrap(), b"hello world");
        assert!(dechunk(b"9\r\nshort\r\n").is_err());
    }

    #[test]
    fn tool_list_matches_the_node_server() {
        let names: Vec<String> = tools().as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap().to_string()).collect();
        assert_eq!(names, ["read_snapshot", "read_newest", "list_chats", "posting_status", "read_field", "lookup_self", "inspect_chat", "download_audio", "send_message"]);
    }

    #[test]
    fn binding_is_loopback_only_and_scoped() {
        std::env::set_var("WA_MCP_WHATSAPP_TOKEN", "a".repeat(64));
        std::env::set_var("WA_COMPONENT_CONFIG", r#"{"account":"1@s.whatsapp.net","generation":2,"connector_url":"https://x/","allowed_conversations":["c@g.us"]}"#);
        assert_eq!(binding().err().unwrap(), "component_supports_loopback_connector_only");
        std::env::set_var("WA_COMPONENT_CONFIG", r#"{"account":"1@s.whatsapp.net","generation":2,"connector_url":"http://127.0.0.1:28787/"}"#);
        assert!(binding().is_err(), "no conversations and not account-wide");
        std::env::set_var("WA_COMPONENT_CONFIG", r#"{"account":"1@s.whatsapp.net","generation":2,"connector_url":"http://127.0.0.1:28787/","allowed_conversations":["c@g.us"]}"#);
        let b = binding().unwrap();
        assert_eq!((b.port, b.wide), (28787, false));
        std::env::set_var("WA_COMPONENT_CONFIG", r#"{"account":"1@s.whatsapp.net","generation":2,"connector_url":"http://127.0.0.1:28787","allowed_conversations":["c@g.us"]}"#);
        assert_eq!(binding().unwrap().port, 28787, "no trailing slash is the same origin");
        std::env::set_var("WA_COMPONENT_CONFIG", r#"{"account":"1@s.whatsapp.net","generation":2,"connector_url":"http://127.0.0.1:28787/x","allowed_conversations":["c@g.us"]}"#);
        assert!(binding().is_err(), "a path is refused");
        std::env::set_var("WA_COMPONENT_CONFIG", r#"{"account":"1@s.whatsapp.net","generation":2,"connector_url":"http://127.0.0.1:28787/","allowed_conversations":["c@g.us"]}"#);
        let refused = adapter(&b, "inspect_chat", serde_json::from_str(r#"{"conversation_id":"other@g.us"}"#).unwrap());
        assert_eq!(refused.err().unwrap(), "whatsapp_conversation_not_bound");
        let send = adapter(&b, "send_message", serde_json::from_str(r#"{"conversation_id":"c@g.us","body":"x","confirm":true}"#).unwrap()).unwrap();
        assert_eq!(send["error"], "general_send_refused_draft_visibility_unsupported");
    }
}
