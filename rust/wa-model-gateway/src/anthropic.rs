//! Anthropic Messages (`POST /v1/messages`, SSE).
//!
//! Streaming frames the seam consumes: `message_start` (the prompt's usage, cache reads/writes
//! included), `content_block_start` / `content_block_delta` (`text_delta`, `thinking_delta`,
//! `input_json_delta`), `content_block_stop`, `message_delta` (`stop_reason`, output tokens) and
//! `message_stop`. A `cache_control` breakpoint is emitted on the message that carries it and nowhere
//! else — the one thing this adapter must never do is move it, because that is a cache miss on every
//! following call.

use serde_json::{json, Map, Value};

use crate::adapter::{finish_reason, Adapter, Calls, StreamItem};
use crate::policy::ProviderSpec;
use crate::transport::EdgeRequest;
use crate::types::{ChatRequest, FinishReason, Message, Part, Refusal, Role, Usage};

const API_VERSION: &str = "2023-06-01";

#[derive(Debug, Default)]
pub struct AnthropicAdapter {
    calls: Calls,
    usage: Usage,
    finish: Option<FinishReason>,
    /// The content-block index → the tool call index, since Anthropic's block index is its own.
    blocks: std::collections::BTreeMap<u32, u32>,
    started: bool,
}

impl Adapter for AnthropicAdapter {
    fn kind(&self) -> crate::policy::ProviderKind {
        crate::policy::ProviderKind::Anthropic
    }

    fn build(&self, spec: &ProviderSpec, request: &ChatRequest, model: &str) -> Result<EdgeRequest, Refusal> {
        let body = self.body(spec, request, model)?;
        Ok(EdgeRequest {
            method: "POST".into(),
            url: crate::adapter::endpoint(&spec.base_url, "v1/messages"),
            headers: vec![
                ("content-type".into(), "application/json".into()),
                ("accept".into(), "text/event-stream".into()),
                ("anthropic-version".into(), API_VERSION.into()),
            ],
            body: serde_json::to_vec(&body).map_err(|error| Refusal::Invalid(format!("body: {error}")))?,
            credential: spec.credential.clone(),
        })
    }

    fn on_data(&mut self, data: &str) -> Vec<StreamItem> {
        let Ok(payload) = serde_json::from_str::<Value>(data) else { return Vec::new() };
        let kind = payload.get("type").and_then(Value::as_str).unwrap_or("");
        let mut out = Vec::new();
        match kind {
            "message_start" => {
                self.started = true;
                if let Some(usage) = payload.pointer("/message/usage") {
                    self.merge_usage(usage);
                }
            }
            "content_block_start" => {
                let index = payload.get("index").and_then(Value::as_u64).unwrap_or(0) as u32;
                let block = payload.get("content_block").cloned().unwrap_or(Value::Null);
                if block.get("type").and_then(Value::as_str) == Some("tool_use") {
                    let tool_index = self.blocks.len() as u32;
                    self.blocks.insert(index, tool_index);
                    let id = block.get("id").and_then(Value::as_str).unwrap_or("").to_string();
                    let name = block.get("name").and_then(Value::as_str).unwrap_or("").to_string();
                    // The accumulator learns the call here and the deltas add to it; the caller sees the
                    // assembled call once, at the block's end.
                    self.calls.start(tool_index, id.clone(), name.clone());
                    out.push(StreamItem::ToolCallStart { index: tool_index, id, name });
                }
            }
            "content_block_delta" => {
                let index = payload.get("index").and_then(Value::as_u64).unwrap_or(0) as u32;
                let delta = payload.get("delta").cloned().unwrap_or(Value::Null);
                match delta.get("type").and_then(Value::as_str).unwrap_or("") {
                    "text_delta" => {
                        if let Some(text) = delta.get("text").and_then(Value::as_str) {
                            out.push(StreamItem::Delta(text.to_string()));
                        }
                    }
                    "thinking_delta" => {
                        if let Some(text) = delta.get("thinking").and_then(Value::as_str) {
                            out.push(StreamItem::ReasoningDelta(text.to_string()));
                        }
                    }
                    "input_json_delta" => {
                        if let (Some(tool_index), Some(partial)) =
                            (self.blocks.get(&index), delta.get("partial_json").and_then(Value::as_str))
                        {
                            let tool_index = *tool_index;
                            self.calls.args(tool_index, partial);
                            out.push(StreamItem::ToolCallArgs { index: tool_index, delta: partial.to_string() });
                        }
                    }
                    _ => {}
                }
            }
            "content_block_stop" => {
                let index = payload.get("index").and_then(Value::as_u64).unwrap_or(0) as u32;
                if let Some(tool_index) = self.blocks.remove(&index) {
                    out.extend(self.calls.take(tool_index));
                }
            }
            "message_delta" => {
                if let Some(usage) = payload.get("usage") {
                    self.merge_usage(usage);
                }
                if let Some(reason) = payload.pointer("/delta/stop_reason").and_then(Value::as_str) {
                    self.finish = Some(finish_reason(reason));
                }
            }
            "message_stop" => {
                out.extend(self.calls.drain());
                out.push(StreamItem::Usage(self.usage));
                out.push(StreamItem::Finish(self.finish.unwrap_or(FinishReason::Stop)));
            }
            "error" => {
                let detail = payload
                    .pointer("/error/message")
                    .and_then(Value::as_str)
                    .unwrap_or("anthropic sent an error event")
                    .to_string();
                out.push(StreamItem::Fault(detail));
            }
            _ => {}
        }
        out
    }

    fn finish(&mut self) -> Vec<StreamItem> {
        let mut out = self.calls.drain();
        if self.finish.is_none() {
            // A stream that closed without `message_stop`: report what did arrive, and say the end was
            // implicit rather than pretending the provider said `stop`.
            out.push(StreamItem::Usage(self.usage));
            out.push(StreamItem::Finish(if self.started { FinishReason::Stop } else { FinishReason::Error }));
        }
        out
    }

    fn prefix_bytes(&self, spec: &ProviderSpec, request: &ChatRequest, model: &str) -> Result<Vec<u8>, Refusal> {
        let body = self.body(spec, request, model)?;
        let prefix = json!({
            "system": body.get("system").cloned().unwrap_or(Value::Null),
            "messages": body.get("messages").cloned().unwrap_or(Value::Null),
        });
        serde_json::to_vec(&prefix).map_err(|error| Refusal::Invalid(format!("prefix: {error}")))
    }
}

impl AnthropicAdapter {
    fn merge_usage(&mut self, usage: &Value) {
        if let Some(tokens) = usage.get("input_tokens").and_then(Value::as_u64) {
            self.usage.input_tokens = self.usage.input_tokens.max(tokens);
        }
        if let Some(tokens) = usage.get("output_tokens").and_then(Value::as_u64) {
            self.usage.output_tokens = self.usage.output_tokens.max(tokens);
        }
        if let Some(tokens) = usage.get("cache_read_input_tokens").and_then(Value::as_u64) {
            self.usage.cache_read_tokens = self.usage.cache_read_tokens.max(tokens);
        }
        if let Some(tokens) = usage.get("cache_creation_input_tokens").and_then(Value::as_u64) {
            self.usage.cache_write_tokens = self.usage.cache_write_tokens.max(tokens);
        }
    }

    fn body(&self, _spec: &ProviderSpec, request: &ChatRequest, model: &str) -> Result<Value, Refusal> {
        let mut system = Vec::new();
        let mut messages = Vec::new();
        for message in &request.messages {
            match message.role {
                // System messages are leading (validated), and they stay in their order: Anthropic's
                // `system` is one array, so the block boundaries are preserved instead of joined.
                Role::System => {
                    let mut block = Map::new();
                    block.insert("type".into(), json!("text"));
                    block.insert("text".into(), json!(text_of(message)));
                    if message.cache_breakpoint {
                        block.insert("cache_control".into(), json!({"type": "ephemeral"}));
                    }
                    system.push(Value::Object(block));
                }
                Role::User | Role::Assistant => {
                    let mut content = Vec::new();
                    for part in &message.parts {
                        match part {
                            Part::Text(text) => {
                                content.push(json!({"type": "text", "text": text}));
                            }
                            Part::Image { mime, bytes } => {
                                content.push(json!({"type": "image", "source": {
                                    "type": "base64", "media_type": mime, "data": base64(bytes)
                                }}));
                            }
                        }
                    }
                    for call in &message.tool_calls {
                        let input: Value = serde_json::from_str(&call.arguments_json).unwrap_or_else(|_| json!({}));
                        content.push(json!({"type": "tool_use", "id": call.id, "name": call.name, "input": input}));
                    }
                    if message.cache_breakpoint {
                        if let Some(last) = content.last_mut() {
                            if let Some(object) = last.as_object_mut() {
                                object.insert("cache_control".into(), json!({"type": "ephemeral"}));
                            }
                        }
                    }
                    messages.push(json!({
                        "role": if message.role == Role::Assistant { "assistant" } else { "user" },
                        "content": content,
                    }));
                }
                Role::Tool => {
                    // A tool result travels as a `user` message with a `tool_result` block: that is
                    // Anthropic's shape for it, not a reordering of the conversation.
                    let mut content = vec![json!({
                        "type": "tool_result",
                        "tool_use_id": message.tool_call_id.clone().unwrap_or_default(),
                        "content": text_of(message),
                    })];
                    if message.cache_breakpoint {
                        if let Some(object) = content[0].as_object_mut() {
                            object.insert("cache_control".into(), json!({"type": "ephemeral"}));
                        }
                    }
                    messages.push(json!({"role": "user", "content": content}));
                }
            }
        }
        let mut body = Map::new();
        body.insert("model".into(), json!(model));
        body.insert("max_tokens".into(), json!(request.max_output_tokens));
        body.insert("stream".into(), json!(true));
        if !system.is_empty() {
            body.insert("system".into(), Value::Array(system));
        }
        body.insert("messages".into(), Value::Array(messages));
        if let Some(temperature) = request.temperature {
            body.insert("temperature".into(), json!(temperature));
        }
        if !request.tools.is_empty() {
            let tools: Vec<Value> = request
                .tools
                .iter()
                .map(|tool| {
                    let schema: Value = serde_json::from_str(&tool.schema_json).unwrap_or_else(|_| json!({"type": "object"}));
                    json!({"name": tool.name, "description": tool.description, "input_schema": schema})
                })
                .collect();
            body.insert("tools".into(), Value::Array(tools));
        }
        Ok(Value::Object(body))
    }
}

fn text_of(message: &Message) -> String {
    let mut out = String::new();
    for part in &message.parts {
        if let Part::Text(text) = part {
            if !out.is_empty() {
                out.push('\n');
            }
            out.push_str(text);
        }
    }
    out
}

/// Base64 for an image part. Small and local: the seam's only binary encoding, and a dependency for
/// one function would be a dependency the component pays for on every call.
pub fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(TABLE[(n >> 18) as usize & 63] as char);
        out.push(TABLE[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { TABLE[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[n as usize & 63] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::policy::Policy;
    use crate::transport::sse;
    use crate::types::{Label, TaskClass};

    fn spec() -> ProviderSpec {
        Policy::parse(
            r#"{"providers":[{"id":"a","kind":"anthropic","base_url":"https://api.anthropic.com",
                "allowed_labels":["public","internal","client"]}],"routes":{"default":["a/m"]}}"#,
        )
        .expect("policy")
        .provider("a")
        .expect("a")
        .clone()
    }

    fn request() -> ChatRequest {
        let mut system = crate::types::Message::text(Role::System, "be brief");
        system.cache_breakpoint = true;
        let mut request = ChatRequest::new("s1", TaskClass::Default, Label::Internal, vec![
            system,
            crate::types::Message::text(Role::User, "hello"),
        ]);
        request.model = Some(crate::types::ModelRef::parse("a/claude").expect("ref"));
        request.temperature = Some(0.2);
        request.tools = vec![crate::types::ToolDef {
            name: "read".into(),
            description: "read a file".into(),
            schema_json: r#"{"type":"object","properties":{"path":{"type":"string"}}}"#.into(),
        }];
        request
    }

    #[test]
    fn the_body_is_the_anthropic_shape_with_the_breakpoint_in_place() {
        let adapter = AnthropicAdapter::default();
        let call = adapter.build(&spec(), &request(), "claude").expect("builds");
        assert_eq!(call.url, "https://api.anthropic.com/v1/messages");
        assert_eq!(call.header("anthropic-version"), Some(API_VERSION));
        let body = call.body_json();
        assert_eq!(body["model"], "claude");
        assert_eq!(body["max_tokens"], 4096);
        assert_eq!(body["stream"], true);
        assert_eq!(body["system"][0]["text"], "be brief");
        assert_eq!(body["system"][0]["cache_control"]["type"], "ephemeral");
        assert_eq!(body["messages"][0]["role"], "user");
        assert_eq!(body["messages"][0]["content"][0]["text"], "hello");
        assert_eq!(body["tools"][0]["input_schema"]["type"], "object");
        assert!(call.credential.is_none(), "the mock spec has no credential");
    }

    #[test]
    fn a_streaming_anthropic_turn_yields_deltas_tool_calls_usage_and_finish() {
        let frames = [
            r#"{"type":"message_start","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":900,"cache_creation_input_tokens":40}}}"#,
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
            r#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"read"}}"#,
            r#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#,
            r#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"a.txt\"}"}}"#,
            r#"{"type":"content_block_stop","index":1}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}"#,
            r#"{"type":"message_stop"}"#,
        ];
        let mut scanner = crate::adapter::SseScanner::default();
        let mut adapter = AnthropicAdapter::default();
        let mut items = Vec::new();
        for payload in scanner.feed(&sse(&frames)) {
            items.extend(adapter.on_data(&payload));
        }
        assert!(scanner.saw_any());
        assert_eq!(items[0], StreamItem::Delta("Hel".into()));
        assert_eq!(items[1], StreamItem::Delta("lo".into()));
        assert!(items.contains(&StreamItem::ToolCall(crate::types::ToolCall {
            id: "toolu_1".into(),
            name: "read".into(),
            arguments_json: "{\"path\":\"a.txt\"}".into(),
        })));
        let usage = items
            .iter()
            .find_map(|item| match item {
                StreamItem::Usage(usage) => Some(*usage),
                _ => None,
            })
            .expect("usage");
        assert_eq!(usage.input_tokens, 12);
        assert_eq!(usage.output_tokens, 7);
        assert_eq!(usage.cache_read_tokens, 900);
        assert_eq!(usage.cache_write_tokens, 40);
        assert!(items.contains(&StreamItem::Finish(FinishReason::ToolCalls)));
    }

    #[test]
    fn an_error_event_is_a_fault_not_a_finish() {
        let mut adapter = AnthropicAdapter::default();
        let items = adapter.on_data(r#"{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}"#);
        assert_eq!(items, vec![StreamItem::Fault("overloaded".into())]);
    }

    #[test]
    fn an_image_part_is_base64_encoded_under_its_media_type() {
        assert_eq!(base64(b"hi"), "aGk=");
        assert_eq!(base64(b"hi!"), "aGkh");
        assert_eq!(base64(b""), "");
    }
}
