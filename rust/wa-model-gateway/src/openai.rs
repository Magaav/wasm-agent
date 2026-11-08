//! OpenAI-compatible chat completions (`POST <base>/chat/completions`, SSE) — the edge DeepSeek and
//! opencode-go speak, and every local server that copies them.
//!
//! Streaming frames the seam consumes: `choices[0].delta.content`, `delta.reasoning_content` (or
//! `reasoning`/`reasoning_text`, the three spellings `lua/core/provider.lua` already reads),
//! `delta.tool_calls[{index,id,function{name,arguments}}]`, `choices[0].finish_reason`, and `usage`
//! (top level, present when the request asked for `stream_options.include_usage`).
//!
//! OpenAI-compatible endpoints have no request-side cache breakpoint: the provider caches the longest
//! matching prefix by itself, so the breakpoint flag is *ignored here* rather than translated into some
//! invented field. The prefix the caller assembled is still byte-identical, which is the only thing the
//! cache needs.

use serde_json::{json, Map, Value};

use crate::adapter::{finish_reason, Adapter, Calls, StreamItem};
use crate::policy::ProviderSpec;
use crate::transport::EdgeRequest;
use crate::types::{ChatRequest, FinishReason, Refusal, Role, Usage};

#[derive(Debug, Default)]
pub struct OpenAiAdapter {
    calls: Calls,
    usage: Usage,
    finish: Option<FinishReason>,
    started: bool,
    saw_usage: bool,
}

impl Adapter for OpenAiAdapter {
    fn kind(&self) -> crate::policy::ProviderKind {
        crate::policy::ProviderKind::OpenAi
    }

    fn build(&self, spec: &ProviderSpec, request: &ChatRequest, model: &str) -> Result<EdgeRequest, Refusal> {
        let body = self.body(spec, request, model)?;
        Ok(EdgeRequest {
            method: "POST".into(),
            url: crate::adapter::endpoint(&spec.base_url, "chat/completions"),
            headers: vec![
                ("content-type".into(), "application/json".into()),
                ("accept".into(), "text/event-stream".into()),
            ],
            body: serde_json::to_vec(&body).map_err(|error| Refusal::Invalid(format!("body: {error}")))?,
            credential: spec.credential.clone(),
        })
    }

    fn on_data(&mut self, data: &str) -> Vec<StreamItem> {
        let Ok(payload) = serde_json::from_str::<Value>(data) else { return Vec::new() };
        if let Some(error) = payload.get("error") {
            let detail = error
                .get("message")
                .and_then(Value::as_str)
                .or_else(|| error.as_str())
                .unwrap_or("the provider sent an error object")
                .to_string();
            return vec![StreamItem::Fault(detail)];
        }
        self.started = true;
        let mut out = Vec::new();
        if let Some(usage) = payload.get("usage") {
            if !usage.is_null() {
                self.saw_usage = true;
                self.merge_usage(usage);
            }
        }
        let choice = payload.pointer("/choices/0").cloned().unwrap_or(Value::Null);
        if let Some(delta) = choice.get("delta") {
            if let Some(text) = delta.get("content").and_then(Value::as_str) {
                if !text.is_empty() {
                    out.push(StreamItem::Delta(text.to_string()));
                }
            }
            for field in ["reasoning_content", "reasoning", "reasoning_text"] {
                if let Some(text) = delta.get(field).and_then(Value::as_str) {
                    if !text.is_empty() {
                        out.push(StreamItem::ReasoningDelta(text.to_string()));
                        break;
                    }
                }
            }
            if let Some(calls) = delta.get("tool_calls").and_then(Value::as_array) {
                for call in calls {
                    let index = call.get("index").and_then(Value::as_u64).unwrap_or(0) as u32;
                    let id = call.get("id").and_then(Value::as_str).unwrap_or("").to_string();
                    let name = call
                        .pointer("/function/name")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let arguments = call
                        .pointer("/function/arguments")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    if !id.is_empty() || !name.is_empty() {
                        out.push(StreamItem::ToolCallStart { index, id: id.clone(), name: name.clone() });
                        self.calls.start(index, id, name);
                    }
                    if !arguments.is_empty() {
                        out.push(StreamItem::ToolCallArgs { index, delta: arguments.clone() });
                        self.calls.args(index, &arguments);
                    }
                }
            }
        }
        if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
            self.finish = Some(finish_reason(reason));
            // OpenAI closes the stream's content with `finish_reason` and sends usage *after* it
            // (include_usage): the calls are complete here, the usage is not. The usage and the finish
            // are emitted by `finish`, once.
            out.extend(self.calls.drain());
        }
        out
    }

    fn finish(&mut self) -> Vec<StreamItem> {
        let mut out = self.calls.drain();
        if self.saw_usage {
            out.push(StreamItem::Usage(self.usage));
        }
        let reason = self.finish.unwrap_or(if self.started { FinishReason::Stop } else { FinishReason::Error });
        out.push(StreamItem::Finish(reason));
        out
    }

    fn prefix_bytes(&self, spec: &ProviderSpec, request: &ChatRequest, model: &str) -> Result<Vec<u8>, Refusal> {
        let body = self.body(spec, request, model)?;
        serde_json::to_vec(&json!({ "messages": body.get("messages").cloned().unwrap_or(Value::Null) }))
            .map_err(|error| Refusal::Invalid(format!("prefix: {error}")))
    }
}

impl OpenAiAdapter {
    fn merge_usage(&mut self, usage: &Value) {
        let read = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
        let mut details = usage.get("prompt_tokens_details").and_then(|details| details.get("cached_tokens"));
        let cache_read = read("cache_read_input_tokens")
            .max(read("prompt_cache_hit_tokens"))
            .max(details.take().and_then(|tokens| tokens.as_u64()).unwrap_or(0));
        let reasoning = usage
            .pointer("/completion_tokens_details/reasoning_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        self.usage = Usage {
            input_tokens: read("prompt_tokens").max(self.usage.input_tokens),
            output_tokens: read("completion_tokens").max(self.usage.output_tokens),
            cache_read_tokens: cache_read.max(self.usage.cache_read_tokens),
            // OpenAI-compatible edges report cache *reads*; DeepSeek's `prompt_cache_miss_tokens` is
            // the write side of the same cache.
            cache_write_tokens: read("cache_write_tokens")
                .max(read("prompt_cache_miss_tokens"))
                .max(self.usage.cache_write_tokens),
            reasoning_tokens: reasoning.max(self.usage.reasoning_tokens),
        };
    }

    fn body(&self, _spec: &ProviderSpec, request: &ChatRequest, model: &str) -> Result<Value, Refusal> {
        let mut messages = Vec::new();
        for message in &request.messages {
            let text = message
                .parts
                .iter()
                .filter_map(|part| match part {
                    crate::types::Part::Text(text) => Some(text.clone()),
                    crate::types::Part::Image { .. } => None,
                })
                .collect::<Vec<_>>()
                .join("\n");
            let images: Vec<Value> = message
                .parts
                .iter()
                .filter_map(|part| match part {
                    crate::types::Part::Image { mime, bytes } => Some(json!({
                        "type": "image_url",
                        "image_url": {"url": format!("data:{mime};base64,{}", crate::anthropic::base64(bytes))}
                    })),
                    crate::types::Part::Text(_) => None,
                })
                .collect();
            let mut object = Map::new();
            object.insert("role".into(), json!(message.role.as_str()));
            if message.role == Role::Tool {
                object.insert("tool_call_id".into(), json!(message.tool_call_id.clone().unwrap_or_default()));
                object.insert("content".into(), json!(text));
            } else if images.is_empty() {
                object.insert("content".into(), json!(text));
            } else {
                let mut content = vec![json!({"type": "text", "text": text})];
                content.extend(images);
                object.insert("content".into(), Value::Array(content));
            }
            if let Some(name) = &message.name {
                object.insert("name".into(), json!(name));
            }
            if !message.tool_calls.is_empty() {
                let calls: Vec<Value> = message
                    .tool_calls
                    .iter()
                    .map(|call| {
                        json!({
                            "id": call.id,
                            "type": "function",
                            "function": {"name": call.name, "arguments": call.arguments_json},
                        })
                    })
                    .collect();
                object.insert("tool_calls".into(), Value::Array(calls));
            }
            messages.push(Value::Object(object));
        }
        let mut body = Map::new();
        body.insert("model".into(), json!(model));
        body.insert("messages".into(), Value::Array(messages));
        body.insert("max_tokens".into(), json!(request.max_output_tokens));
        body.insert("stream".into(), json!(true));
        body.insert("stream_options".into(), json!({"include_usage": true}));
        if let Some(temperature) = request.temperature {
            body.insert("temperature".into(), json!(temperature));
        }
        if !request.tools.is_empty() {
            let tools: Vec<Value> = request
                .tools
                .iter()
                .map(|tool| {
                    let parameters: Value =
                        serde_json::from_str(&tool.schema_json).unwrap_or_else(|_| json!({"type": "object"}));
                    json!({
                        "type": "function",
                        "function": {"name": tool.name, "description": tool.description, "parameters": parameters},
                    })
                })
                .collect();
            body.insert("tools".into(), Value::Array(tools));
            body.insert("tool_choice".into(), json!("auto"));
        }
        Ok(Value::Object(body))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::policy::Policy;
    use crate::transport::sse;
    use crate::types::{Label, Message, ModelRef, TaskClass};

    fn spec() -> ProviderSpec {
        Policy::parse(
            r#"{"providers":[{"id":"deepseek","kind":"openai","base_url":"https://api.deepseek.com/v1",
                "allowed_labels":["public","internal"],"models":["deepseek-v4.1-flash"]}],
                "routes":{"default":["deepseek/deepseek-v4.1-flash"]}}"#,
        )
        .expect("policy")
        .provider("deepseek")
        .expect("deepseek")
        .clone()
    }

    fn request() -> ChatRequest {
        let mut request = ChatRequest::new(
            "s1",
            TaskClass::Code,
            Label::Internal,
            vec![
                Message::text(Role::System, "be brief"),
                Message::text(Role::User, "hello"),
            ],
        );
        request.model = Some(ModelRef::parse("deepseek/deepseek-v4.1-flash").expect("ref"));
        request
    }

    #[test]
    fn the_body_is_the_openai_compatible_shape() {
        let adapter = OpenAiAdapter::default();
        let call = adapter.build(&spec(), &request(), "deepseek-v4.1-flash").expect("builds");
        assert_eq!(call.url, "https://api.deepseek.com/v1/chat/completions");
        let body = call.body_json();
        assert_eq!(body["model"], "deepseek-v4.1-flash");
        assert_eq!(body["messages"][0], json!({"role": "system", "content": "be brief"}));
        assert_eq!(body["messages"][1], json!({"role": "user", "content": "hello"}));
        assert_eq!(body["stream"], true);
        assert_eq!(body["stream_options"]["include_usage"], true);
    }

    #[test]
    fn a_streaming_turn_yields_deltas_reasoning_tool_calls_and_usage() {
        let frames = [
            r#"{"choices":[{"delta":{"role":"assistant","content":""}}]}"#,
            r#"{"choices":[{"delta":{"reasoning_content":"think "}}]}"#,
            r#"{"choices":[{"delta":{"content":"Hel"}}]}"#,
            r#"{"choices":[{"delta":{"content":"lo"}}]}"#,
            r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read","arguments":""}}]}}]}"#,
            r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":"}}]}}]}"#,
            r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a.txt\"}"}}]}}]}"#,
            r#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            r#"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20,"prompt_cache_hit_tokens":80,"completion_tokens_details":{"reasoning_tokens":5}}}"#,
        ];
        let mut scanner = crate::adapter::SseScanner::default();
        let mut adapter = OpenAiAdapter::default();
        let mut items = Vec::new();
        for payload in scanner.feed(&sse(&frames)) {
            items.extend(adapter.on_data(&payload));
        }
        assert!(scanner.done() || scanner.saw_any());
        items.extend(adapter.finish());
        assert_eq!(items[0], StreamItem::ReasoningDelta("think ".into()));
        assert_eq!(items[1], StreamItem::Delta("Hel".into()));
        assert!(items.contains(&StreamItem::ToolCall(crate::types::ToolCall {
            id: "call_1".into(),
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
        assert_eq!(usage.input_tokens, 100);
        assert_eq!(usage.output_tokens, 20);
        assert_eq!(usage.cache_read_tokens, 80);
        assert_eq!(usage.reasoning_tokens, 5);
        assert_eq!(items.last(), Some(&StreamItem::Finish(FinishReason::ToolCalls)));
    }

    #[test]
    fn an_error_object_is_a_fault() {
        let mut adapter = OpenAiAdapter::default();
        let items = adapter.on_data(r#"{"error":{"message":"Rate limit reached","type":"rate_limit"}}"#);
        assert_eq!(items, vec![StreamItem::Fault("Rate limit reached".into())]);
    }

    #[test]
    fn a_tool_message_carries_its_call_id() {
        let mut request = request();
        request.messages.push(Message {
            role: Role::Tool,
            parts: vec![crate::types::Part::Text("file body".into())],
            tool_calls: Vec::new(),
            tool_call_id: Some("call_1".into()),
            name: Some("read".into()),
            cache_breakpoint: false,
        });
        let call = OpenAiAdapter::default().build(&spec(), &request, "deepseek-v4.1-flash").expect("builds");
        let body = call.body_json();
        assert_eq!(body["messages"][2]["role"], "tool");
        assert_eq!(body["messages"][2]["tool_call_id"], "call_1");
        assert_eq!(body["messages"][2]["content"], "file body");
    }
}
