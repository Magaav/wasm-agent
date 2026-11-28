//! The WhatsApp query contract, asked of the `whatsapp-index` component (`rust/components/whatsapp-index`).
//!
//! WHAT THIS REPLACED. `rust/wa-whatsapp-index` is the vocabulary every WhatsApp query is written in: the op
//! list, what a request may carry, which arguments make one valid (`Request::validate` -> `Verified`), the
//! refusal a bad one gets, and the sentence a caller reads back. Two ends need it - the host, which
//! validates and words every query, and the `wa-whatsapp` component, which writes its answers in the same
//! words - and both were compiled into the node, so a change to either rebuilt it.
//!
//! WHAT STAYS HERE, AND WHY IT IS NOT A COPY OF THE CONTRACT. A caller has to be able to *name* an op and an
//! effect, so this module carries the eight op names and the three effect names as an enum: a name, not a
//! rule. Every decision - is this request valid, what does its refusal say, what bytes does the queue carry,
//! what is its dedupe key for this build, what is a state called - is answered by the component, and the
//! seam only carries the answer. The one place the two could drift is that enum, and
//! `scripts/test-whatsapp-index-component.sh` compares it with the component's own `constants` answer, so a
//! name added on one side and not the other fails a row instead of a query.
//!
//! A NODE WITH NO `whatsapp-index` COMPONENT CANNOT ANSWER A QUERY, and says so in the word the read path
//! already uses (`whatsapp_component_absent`) rather than falling back in-process - the fallback is what kept
//! the crate in the binary in the first place.
use serde_json::{json, Value};

const COMPONENT: &str = "whatsapp-index";

/// The ops a caller may name, and the effect each has.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Op {
    Search,
    Read,
    Message,
    Reactions,
    Media,
    Download,
    Backfill,
    Contacts,
}

impl Op {
    pub(crate) const ALL: [Op; 8] = [
        Op::Search, Op::Read, Op::Message, Op::Reactions, Op::Media, Op::Download, Op::Backfill, Op::Contacts,
    ];

    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Op::Search => "search",
            Op::Read => "read",
            Op::Message => "message",
            Op::Reactions => "reactions",
            Op::Media => "media",
            Op::Download => "download",
            Op::Backfill => "backfill",
            Op::Contacts => "contacts",
        }
    }

    pub(crate) fn parse(text: &str) -> Option<Op> {
        Op::ALL.iter().copied().find(|op| op.as_str() == text.trim())
    }

    /// The op's own name as a tool (`whatsapp_<op>`, the contract's spelling); a door prefixes it with its
    /// own namespace (`mcp_whatsapp_<op>`) where it needs to.
    pub(crate) fn tool(self) -> &'static str {
        match self {
            Op::Search => "whatsapp_search",
            Op::Read => "whatsapp_read",
            Op::Message => "whatsapp_message",
            Op::Reactions => "whatsapp_reactions",
            Op::Media => "whatsapp_media",
            Op::Download => "whatsapp_download",
            Op::Backfill => "whatsapp_backfill",
            Op::Contacts => "whatsapp_contacts",
        }
    }

    /// What the op does to the world, and the one place this enum could drift from the contract: the
    /// table is the component's own (`constants.effects`), and `scripts/test-whatsapp-index-component.sh`
    /// compares the two, because 28/11 got it wrong here (`backfill` is a NETWORK op - it asks the phone -
    /// and calling it read-only sent the call to the wrong door).
    pub(crate) fn effect(self) -> Effect {
        match self {
            Op::Search | Op::Read | Op::Message | Op::Reactions | Op::Media | Op::Contacts => Effect::ReadOnly,
            Op::Backfill => Effect::Network,
            Op::Download => Effect::WritesFiles,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Effect {
    ReadOnly,
    WritesFiles,
    Network,
}

/// A refusal as the component stated it: its code and its own words, nothing inferred here.
#[derive(Clone, Debug)]
pub(crate) struct Refusal {
    pub code: String,
    pub detail: String,
}

/// A request the component accepted, reduced to what the host actually needs: the op, the exact bytes the
/// queue carries, and the dedupe key for this build. The normalised fields are not carried - a second copy
/// of them in the host is a second answer to a question the contract already answered.
#[derive(Clone, Debug)]
pub(crate) struct Verified {
    pub op: Op,
    pub request: Vec<u8>,
    pub dedupe: String,
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

/// The word a caller reads when this node runs no index component. One spelling, like the read path's own.
pub(crate) fn absent(op: Op) -> Value {
    json!({"ok": false, "error": "whatsapp_component_absent", "effect": "none",
        "detail": format!("this node runs no {} component, so it cannot answer {}", COMPONENT, op.as_str())})
}

/// Check one request through the component. `Err` is the caller's refusal verbatim, or the absent word.
pub(crate) fn validate(request: Value, build: &str) -> Result<Verified, Refusal> {
    let absent = Refusal {
        code: "component_absent".to_string(),
        detail: "this node runs no whatsapp-index component, so it cannot check a query".to_string(),
    };
    let answer = call("validate", json!({"request": request, "build": build})).ok_or_else(|| absent.clone())?;
    if answer["ok"] != json!(true) {
        return Err(Refusal {
            code: answer["code"].as_str().unwrap_or("bad_request").to_string(),
            detail: answer["detail"].as_str().unwrap_or_default().to_string(),
        });
    }
    let op = answer["op"].as_str().and_then(Op::parse).ok_or(absent)?;
    Ok(Verified {
        op,
        request: answer["request_hex"].as_str().and_then(unhex).unwrap_or_default(),
        dedupe: answer["dedupe"].as_str().unwrap_or_default().to_string(),
    })
}

/// The envelope one op's body is delivered in.
pub(crate) fn answer(op: Op, body: Value) -> Value {
    call("answer", json!({"op": op.as_str(), "body": body}))
        .unwrap_or_else(|| absent(op))
}

/// The envelope a refusal makes, by typed op.
pub(crate) fn refusal(op: Op, code: &str, detail: impl AsRef<str>) -> Value {
    call("refusal", json!({"op": op.as_str(), "code": code, "detail": detail.as_ref()}))
        .unwrap_or_else(|| absent(op))
}

/// The same envelope for a door that names its op as text.
pub(crate) fn refusal_text(op: &str, code: &str, detail: impl AsRef<str>) -> Value {
    match call("refusal_text", json!({"op": op, "code": code, "detail": detail.as_ref()})) {
        Some(answer) => answer,
        None => json!({"ok": false, "error": format!("whatsapp_{op}_component_absent"),
            "effect": "none", "op": op, "detail": "this node runs no whatsapp-index component"}),
    }
}

/// One word for a queue state.
pub(crate) fn state_word(state: &str) -> String {
    call("state_word", json!({"state": state}))
        .and_then(|answer| answer["state"].as_str().map(str::to_string))
        .unwrap_or_else(|| state.to_string())
}

/// One time form as the epoch millis a request carries.
pub(crate) fn parse_time(text: &str) -> Option<i64> {
    call("parse_time", json!({"text": text})).and_then(|answer| answer["millis"].as_i64())
}

/// What the ops are, for the door that answers "what can I ask".
pub(crate) fn registry() -> Value {
    call("registry", json!({})).unwrap_or(Value::Null)
}

/// The contract's own constants, read once and kept: they are the component's data, and a query path is not
/// the place to start a component for a string it already answered.
pub(crate) fn constant(name: &str) -> Value {
    use std::sync::OnceLock;
    static CONSTANTS: OnceLock<Value> = OnceLock::new();
    let all = CONSTANTS.get_or_init(|| call("constants", json!({})).unwrap_or(Value::Null));
    all[name].clone()
}

/// Whether a string is a calendar month (`YYYY-MM`).
pub(crate) fn is_month(text: &str) -> bool {
    call("is_month", json!({"text": text})).and_then(|answer| answer["month"].as_bool()).unwrap_or(false)
}

/// Which job failures will never succeed on a retry, in the contract's own list.
pub(crate) fn permanent_code(reason: &str) -> Option<String> {
    call("permanent_code", json!({"reason": reason}))
        .and_then(|answer| answer["code"].as_str().map(str::to_string))
}

/// One typed op's answer while its job is still running.
pub(crate) fn slow(op: Op, id: u64, state: &str) -> Value {
    call("slow", json!({"op": op.as_str(), "id": id, "state": state}))
        .unwrap_or_else(|| absent(op))
}

/// The job id a download progress chunk names, or nothing when the chunk is not one.
pub(crate) fn download_header_job(chunk: &[u8]) -> Option<u64> {
    call("download_header_job", json!({"chunk_hex": hex(chunk)})).and_then(|answer| answer["job"].as_u64())
}

/// A downloadable file as the component described it. The fields are the wire shape `Download` carries
/// (`rust/wa-whatsapp-index/src/lib.rs`), mirrored as data: the host reads them to check the file it was
/// handed, and decides nothing about them.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub(crate) struct Download {
    #[serde(default)] pub chat: String,
    #[serde(default)] pub id: String,
    #[serde(default)] pub kind: String,
    #[serde(default)] pub mime: String,
    #[serde(default)] pub filename: String,
    #[serde(default)] pub sha256: String,
    #[serde(default)] pub bytes: u64,
    #[serde(default)] pub chunks: u32,
    #[serde(default)] pub path: Option<String>,
}

impl Download {
    pub(crate) fn decode(bytes: &[u8]) -> Option<Download> {
        serde_json::from_slice(bytes).ok()
    }
}

/// The answer a caller gets while a job is still running, in the contract's words.
pub(crate) fn slow_text(op: &str, id: u64, state: &str) -> Value {
    call("slow_text", json!({"op": op, "id": id, "state": state})).unwrap_or_else(|| {
        json!({"ok": false, "error": "whatsapp_component_absent", "effect": "none", "op": op})
    })
}

/// A refusal this seam states itself, for the cases no component call decides (a malformed argument list).
/// It carries the contract's `{code, detail}` shape and is worded by [`refusal`] like any other.
#[derive(Clone, Debug)]
pub(crate) struct Why {
    pub code: String,
    pub detail: String,
}

impl Refusal {
    pub(crate) fn new(code: &'static str, detail: impl AsRef<str>) -> Refusal {
        Refusal { code: code.to_string(), detail: detail.as_ref().chars().take(160).collect() }
    }
}

fn constant_text(name: &str, fallback: &'static str) -> &'static str {
    use std::sync::OnceLock;
    static QUEUE: OnceLock<String> = OnceLock::new();
    static REGISTRY: OnceLock<String> = OnceLock::new();
    static TIMES: OnceLock<String> = OnceLock::new();
    match name {
        "queue" => QUEUE.get_or_init(|| constant("queue").as_str().unwrap_or(fallback).to_string()).as_str(),
        "registry_op" => REGISTRY.get_or_init(|| constant("registry_op").as_str().unwrap_or(fallback).to_string()).as_str(),
        "time_forms" => TIMES.get_or_init(|| constant("time_forms").as_str().unwrap_or(fallback).to_string()).as_str(),
        _ => fallback,
    }
}

/// The queue a query is enqueued on, the op that answers the registry, and the time shapes a caller may
/// write - the component's own strings, read once.
pub(crate) fn queue() -> &'static str { constant_text("queue", "whatsapp.query") }
pub(crate) fn registry_op() -> &'static str { constant_text("registry_op", "ops") }
pub(crate) fn time_forms() -> &'static str { constant_text("time_forms", "a time is an epoch or a date") }

/// The numbers a job is enqueued with.
pub(crate) fn max_attempts() -> u32 {
    constant("max_attempts").as_u64().unwrap_or(2) as u32
}

pub(crate) fn fresh_ms() -> i64 {
    // `wa-whatsapp-index` does not state a freshness window; the enqueue takes the contract's own if it
    // ever does, and the host keeps the value it has always used until then.
    constant("fresh_ms").as_i64().unwrap_or(FRESH_MS)
}

const FRESH_MS: i64 = 60_000;

/// Kept for the callers that need to spell a value as hex (the seam's own tests and the download path).
pub(crate) fn hex_of(bytes: &[u8]) -> String {
    hex(bytes)
}

#[cfg(test)]
mod tests;
