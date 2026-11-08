//! Google Gemini (`POST /v1beta/models/<model>:streamGenerateContent?alt=sse`).
//!
//! Streaming frames the seam consumes: `candidates[0].content.parts[]` — `text`, `functionCall` — plus
//! `usageMetadata` (`promptTokenCount`, `candidatesTokenCount`, `cachedContentTokenCount`,
//! `thoughtsTokenCount`) and `candidates[0].finishReason`. The API key travels in the query string, which
//! is why the credential reference carries a `Query` scheme: the *kernel* appends `key=<secret>`, so the
//! guest never sees it and cannot log it.
//!
//! Gemini has a structural difference the adapter absorbs rather than leaking: a tool result is a
//! `functionResponse` part inside a `user` turn, and a `functionCall` is a part of the model's own turn.
//! The conversation's order is still the caller's order.

use serde_json::{json, Map, Value};

use crate::adapter::{finish_reason, Adapter, Calls, StreamItem};
use crate::policy::ProviderSpec;
use crate::transport::EdgeRequest;
use crate::types::{ChatRequest, FinishReason, Part, Refusal, Role, Usage};

#[derive(Debug, Default)]
pub struct GeminiAdapter {
    calls: Calls,
    usage: Usage,
    finish: Option<FinishReason>,
    started: bool,
}

impl Adapter for GeminiAdapter {
    fn kind(&self) -> crate::policy::ProviderKind {
        crate::policy::ProviderKind::Gemini
    }

    fn build(&self, spec: &ProviderSpec, request: &ChatRequest, model: &str) -> Result<EdgeRequest, Refusal> {
        let body = self.body(spec, request, model)?;
        Ok(EdgeRequest {
            method: "POST".into(),
            url: format!(
                "{}/models/{}:streamGenerateContent?alt=sse",
                version_root(&spec.base_url),
                model
            ),
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
                .unwrap_or("gemini sent an error object")
                .to_string();
            return vec![StreamItem::Fault(detail)];
        }
        self.started = true;
        let mut out = Vec::new();
        if let Some(usage) = payload.get("usageMetadata") {
            self.merge_usage(usage);
        }
        let candidate = payload.pointer("/candidates/0").cloned().unwrap_or(Value::Null);
        if let Some(parts) = candidate.pointer("/content/parts").and_then(Value::as_array) {
            for part in parts {
                if let Some(text) = part.get("text").and_then(Value::as_str) {
                    if part.get("thought").and_then(Value::as_bool).unwrap_or(false) {
                        out.push(StreamItem::ReasoningDelta(text.to_string()));
                    } else if !text.is_empty() {
                        out.push(StreamItem::Delta(text.to_string()));
                    }
                }
                if let Some(call) = part.get("functionCall") {
                    let name = call.get("name").and_then(Value::as_str).unwrap_or("").to_string();
                    let arguments = call.get("args").cloned().unwrap_or_else(|| json!({}));
                    let index = self.calls_count() as u32;
                    let id = format!("call_{index}_{name}");
                    out.push(StreamItem::ToolCallStart { index, id: id.clone(), name: name.clone() });
                    self.calls.start(index, id, name);
                    let text = arguments.to_string();
                    out.push(StreamItem::ToolCallArgs { index, delta: text.clone() });
                    self.calls.args(index, &text);
                    // Gemini sends a call whole: it is complete now, not at the stream's end.
                    out.extend(self.calls.take(index));
                }
            }
        }
        if let Some(reason) = candidate.get("finishReason").and_then(Value::as_str) {
            self.finish = Some(finish_reason(reason));
        }
        out
    }

    fn finish(&mut self) -> Vec<StreamItem> {
        let mut out = self.calls.drain();
        out.push(StreamItem::Usage(self.usage));
        let reason = self.finish.unwrap_or(if self.started { FinishReason::Stop } else { FinishReason::Error });
        out.push(StreamItem::Finish(reason));
        out
    }

    fn prefix_bytes(&self, spec: &ProviderSpec, request: &ChatRequest, model: &str) -> Result<Vec<u8>, Refusal> {
        let body = self.body(spec, request, model)?;
        serde_json::to_vec(&json!({
            "systemInstruction": body.get("systemInstruction").cloned().unwrap_or(Value::Null),
            "contents": body.get("contents").cloned().unwrap_or(Value::Null),
        }))
        .map_err(|error| Refusal::Invalid(format!("prefix: {error}")))
    }
}

impl GeminiAdapter {
    fn calls_count(&self) -> usize {
        // Gemini numbers calls in arrival order; the counter lives in the id it hands the seam.
        self.calls.len()
    }

    fn merge_usage(&mut self, usage: &Value) {
        let read = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
        self.usage = Usage {
            input_tokens: read("promptTokenCount").max(self.usage.input_tokens),
            output_tokens: read("candidatesTokenCount").max(self.usage.output_tokens),
            cache_read_tokens: read("cachedContentTokenCount").max(self.usage.cache_read_tokens),
            cache_write_tokens: self.usage.cache_write_tokens,
            reasoning_tokens: read("thoughtsTokenCount").max(self.usage.reasoning_tokens),
        };
    }

    fn body(&self, _spec: &ProviderSpec, request: &ChatRequest, _model: &str) -> Result<Value, Refusal> {
        let mut system = Vec::new();
        let mut contents = Vec::new();
        for message in &request.messages {
            let mut parts = Vec::new();
            for part in &message.parts {
                match part {
                    Part::Text(text) => parts.push(json!({"text": text})),
                    Part::Image { mime, bytes } => parts.push(json!({
                        "inlineData": {"mimeType": mime, "data": crate::anthropic::base64(bytes)}
                    })),
                }
            }
            for call in &message.tool_calls {
                let args: Value = serde_json::from_str(&call.arguments_json).unwrap_or_else(|_| json!({}));
                parts.push(json!({"functionCall": {"name": call.name, "args": args}}));
            }
            match message.role {
                Role::System => {
                    for part in parts {
                        system.push(part);
                    }
                }
                Role::Tool => contents.push(json!({
                    "role": "user",
                    "parts": [{
                        "functionResponse": {
                            "name": message.name.clone().unwrap_or_default(),
                            "response": {"content": text_of(message)},
                        }
                    }],
                })),
                Role::User => contents.push(json!({"role": "user", "parts": parts})),
                Role::Assistant => contents.push(json!({"role": "model", "parts": parts})),
            }
        }
        let mut body = Map::new();
        if !system.is_empty() {
            body.insert("systemInstruction".into(), json!({"parts": system}));
        }
        body.insert("contents".into(), Value::Array(contents));
        let mut config = Map::new();
        config.insert("maxOutputTokens".into(), json!(request.max_output_tokens));
        if let Some(temperature) = request.temperature {
            config.insert("temperature".into(), json!(temperature));
        }
        body.insert("generationConfig".into(), Value::Object(config));
        if !request.tools.is_empty() {
            let declarations: Vec<Value> = request
                .tools
                .iter()
                .map(|tool| {
                    let parameters: Value =
                        serde_json::from_str(&tool.schema_json).unwrap_or_else(|_| json!({"type": "object"}));
                    json!({"name": tool.name, "description": tool.description, "parameters": parameters})
                })
                .collect();
            body.insert("tools".into(), json!([{"functionDeclarations": declarations}]));
        }
        Ok(Value::Object(body))
    }
}

/// `https://generativelanguage.googleapis.com` → `…/v1beta`; a base that already names a version keeps it.
fn version_root(base_url: &str) -> String {
    let trimmed = base_url.trim_end_matches('/');
    if trimmed.ends_with("/v1beta") || trimmed.ends_with("/v1") || trimmed.ends_with("/v1alpha") {
        trimmed.to_string()
    } else {
        format!("{trimmed}/v1beta")
    }
}

fn text_of(message: &crate::types::Message) -> String {
    message
        .parts
        .iter()
        .filter_map(|part| match part {
            Part::Text(text) => Some(text.clone()),
            Part::Image { .. } => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::policy::Policy;
    use crate::transport::sse;
    use crate::types::{Label, Message, ModelRef, TaskClass};

    fn spec() -> ProviderSpec {
        Policy::parse(
            r#"{"providers":[{"id":"gemini","kind":"gemini","base_url":"https://generativelanguage.googleapis.com",
                "allowed_labels":["public","internal","client"],
                "credential":{"secret":"GEMINI_API_KEY","header":"key","scheme":"query"}}],
                "routes":{"default":["gemini/gemini-3-pro"]}}"#,
        )
        .expect("policy")
        .provider("gemini")
        .expect("gemini")
        .clone()
    }

    fn request() -> ChatRequest {
        let mut request = ChatRequest::new(
            "s1",
            TaskClass::Default,
            Label::Public,
            vec![Message::text(Role::System, "be brief"), Message::text(Role::User, "hello")],
        );
        request.model = Some(ModelRef::parse("gemini/gemini-3-pro").expect("ref"));
        request
    }

    #[test]
    fn the_url_names_the_model_and_the_streaming_alt() {
        let call = GeminiAdapter::default().build(&spec(), &request(), "gemini-3-pro").expect("builds");
        assert_eq!(
            call.url,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro:streamGenerateContent?alt=sse"
        );
        let credential = call.credential.expect("credential reference");
        assert_eq!(credential.header, "key");
        assert_eq!(credential.secret, "GEMINI_API_KEY");
        assert!(
            !call.url.contains("API"),
            "the query carries a reference, never the secret: {}",
            call.url
        );
    }

    #[test]
    fn the_body_uses_contents_system_instruction_and_generation_config() {
        let body = GeminiAdapter::default().build(&spec(), &request(), "gemini-3-pro").expect("builds").body_json();
        assert_eq!(body["systemInstruction"]["parts"][0]["text"], "be brief");
        assert_eq!(body["contents"][0]["role"], "user");
        assert_eq!(body["contents"][0]["parts"][0]["text"], "hello");
        assert_eq!(body["generationConfig"]["maxOutputTokens"], 4096);
    }

    #[test]
    fn a_streaming_turn_yields_deltas_calls_and_usage() {
        let frames = [
            r#"{"candidates":[{"content":{"role":"model","parts":[{"text":"Hel"}]}}]}"#,
            r#"{"candidates":[{"content":{"role":"model","parts":[{"text":"lo"}]}}]}"#,
            r#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"read","args":{"path":"a.txt"}}}]}}]}"#,
            r#"{"candidates":[{"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":9,"candidatesTokenCount":4,"cachedContentTokenCount":3}}"#,
        ];
        let mut scanner = crate::adapter::SseScanner::default();
        let mut adapter = GeminiAdapter::default();
        let mut items = Vec::new();
        for payload in scanner.feed(&sse(&frames)) {
            items.extend(adapter.on_data(&payload));
        }
        items.extend(adapter.finish());
        assert_eq!(items[0], StreamItem::Delta("Hel".into()));
        assert_eq!(items[1], StreamItem::Delta("lo".into()));
        assert!(items.contains(&StreamItem::ToolCall(crate::types::ToolCall {
            id: "call_0_read".into(),
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
        assert_eq!(usage.input_tokens, 9);
        assert_eq!(usage.output_tokens, 4);
        assert_eq!(usage.cache_read_tokens, 3);
        assert!(items.contains(&StreamItem::Finish(FinishReason::Stop)));
    }

    #[test]
    fn a_tool_result_is_a_function_response_in_a_user_turn() {
        let mut request = request();
        request.messages.push(Message {
            role: Role::Tool,
            parts: vec![Part::Text("file body".into())],
            tool_calls: Vec::new(),
            tool_call_id: Some("call_0_read".into()),
            name: Some("read".into()),
            cache_breakpoint: false,
        });
        let body = GeminiAdapter::default().build(&spec(), &request, "gemini-3-pro").expect("builds").body_json();
        assert_eq!(body["contents"][1]["role"], "user");
        assert_eq!(body["contents"][1]["parts"][0]["functionResponse"]["name"], "read");
        assert_eq!(body["contents"][1]["parts"][0]["functionResponse"]["response"]["content"], "file body");
    }

    #[test]
    fn a_base_url_that_already_names_a_version_is_not_doubled() {
        assert_eq!(version_root("https://h/v1beta"), "https://h/v1beta");
        assert_eq!(version_root("https://h/v1beta/"), "https://h/v1beta");
        assert_eq!(version_root("https://h"), "https://h/v1beta");
    }
}
