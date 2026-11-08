//! The adapter seam: a canonical request becomes one provider's HTTP call, and that provider's stream
//! becomes [`StreamItem`]s. Three adapters share this file's scanner and trait, so a difference between
//! them is a difference in one provider's protocol and never in the seam's rules.

use crate::policy::{Policy, ProviderKind, ProviderSpec};
use crate::transport::EdgeRequest;
use crate::types::{ChatRequest, FinishReason, Refusal, ToolCall, Usage};

/// One item a provider's stream produced. `Start`/`Args` are the deltas the adapters assemble into a
/// `ToolCall` here rather than in the caller (`docs/MODEL-GATEWAY.md`, "Tool calls are assembled once").
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StreamItem {
    Delta(String),
    ReasoningDelta(String),
    ToolCallStart { index: u32, id: String, name: String },
    ToolCallArgs { index: u32, delta: String },
    ToolCall(ToolCall),
    Usage(Usage),
    Finish(FinishReason),
    /// The provider reported an error inside the stream (an `error` SSE frame).
    Fault(String),
}

pub trait Adapter {
    fn kind(&self) -> ProviderKind;

    /// The provider call for `request`. The body is JSON because the provider's protocol is; the
    /// messages and tools are emitted in the order the caller gave them.
    fn build(&self, spec: &ProviderSpec, request: &ChatRequest, model: &str) -> Result<EdgeRequest, Refusal>;

    /// One SSE `data:` payload, in order.
    fn on_data(&mut self, data: &str) -> Vec<StreamItem>;

    /// The stream ended: emit whatever the provider left implicit (the finish reason, the usage).
    fn finish(&mut self) -> Vec<StreamItem>;

    /// The prompt-prefix bytes this adapter would put on the wire, for the cache test: the provider's
    /// own rendering of everything up to and including the last cache breakpoint.
    fn prefix_bytes(&self, spec: &ProviderSpec, request: &ChatRequest, model: &str) -> Result<Vec<u8>, Refusal>;
}

pub fn adapter_for(kind: ProviderKind) -> Box<dyn Adapter> {
    match kind {
        ProviderKind::Anthropic => Box::new(crate::anthropic::AnthropicAdapter::default()),
        ProviderKind::OpenAi => Box::new(crate::openai::OpenAiAdapter::default()),
        ProviderKind::Gemini => Box::new(crate::gemini::GeminiAdapter::default()),
    }
}

/// The adapter of the provider a model ref names, with the policy that describes it.
pub fn adapter_for_policy(policy: &Policy, provider: &str) -> Option<(ProviderSpec, Box<dyn Adapter>)> {
    let spec = policy.provider(provider)?.clone();
    Some((spec.clone(), adapter_for(spec.kind)))
}

/// Server-sent events, split into `data:` payloads.
///
/// One scanner for every provider because the framing is the same and the payload is the adapter's:
/// lines are terminated by `\n` or `\r\n`, `data:` payloads are concatenated per event, blank lines
/// end an event, `:`-prefixed lines are comments (some providers send keep-alives) and a payload of
/// `[DONE]` means the stream is complete. The buffer is kept across chunks, so a JSON object split
/// across two TCP reads is parsed once, whole.
#[derive(Clone, Debug, Default)]
pub struct SseScanner {
    buffer: String,
    data: String,
    saw_any: bool,
    done: bool,
}

impl SseScanner {
    /// Feed bytes; returns the data payloads that completed, in order.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        // A provider that sends invalid UTF-8 has broken the protocol; the lossy read keeps the
        // failure visible in the parse instead of panicking on it.
        self.buffer.push_str(&String::from_utf8_lossy(bytes));
        let mut out = Vec::new();
        while let Some(index) = self.buffer.find('\n') {
            let mut line: String = self.buffer.drain(..=index).collect();
            if line.ends_with('\n') {
                line.pop();
            }
            if line.ends_with('\r') {
                line.pop();
            }
            if line.is_empty() {
                if !self.data.is_empty() {
                    let payload = std::mem::take(&mut self.data);
                    if payload.trim() == "[DONE]" {
                        self.done = true;
                    } else {
                        self.saw_any = true;
                        out.push(payload);
                    }
                }
                continue;
            }
            if line.starts_with(':') {
                continue;
            }
            if let Some(rest) = line.strip_prefix("data:") {
                if !self.data.is_empty() {
                    self.data.push('\n');
                }
                self.data.push_str(rest.trim_start());
            }
            // `event:`, `id:` and `retry:` carry nothing the seam needs: every provider puts its type
            // inside the payload.
        }
        out
    }

    /// Flush a final payload that arrived without its blank line (a provider that closed the body
    /// right after the last `data:`).
    pub fn flush(&mut self) -> Option<String> {
        // A final `data:` line that arrived without its blank line is still a payload; a tail that is not
        // one is dropped, because an incomplete frame is not an event.
        if !self.buffer.is_empty() {
            let tail: String = std::mem::take(&mut self.buffer);
            let tail = tail.trim_end_matches('\r');
            if let Some(rest) = tail.strip_prefix("data:") {
                if !self.data.is_empty() {
                    self.data.push('\n');
                }
                self.data.push_str(rest.trim_start());
            }
        }
        if self.data.is_empty() {
            return None;
        }
        let payload = std::mem::take(&mut self.data);
        if payload.trim() == "[DONE]" {
            self.done = true;
            return None;
        }
        self.saw_any = true;
        Some(payload)
    }

    pub fn done(&self) -> bool {
        self.done
    }

    pub fn saw_any(&self) -> bool {
        self.saw_any
    }
}

/// The tool calls of one stream, assembled from their deltas by index.
#[derive(Clone, Debug, Default)]
pub struct Calls {
    calls: std::collections::BTreeMap<u32, Call>,
    order: Vec<u32>,
}

#[derive(Clone, Debug, Default)]
struct Call {
    id: String,
    name: String,
    arguments: String,
}

impl Calls {
    pub fn len(&self) -> usize {
        self.calls.len()
    }

    pub fn is_empty(&self) -> bool {
        self.calls.is_empty()
    }

    pub fn start(&mut self, index: u32, id: String, name: String) {
        if !self.calls.contains_key(&index) {
            self.order.push(index);
        }
        let entry = self.calls.entry(index).or_default();
        if !id.is_empty() {
            entry.id = id;
        }
        if !name.is_empty() {
            entry.name = name;
        }
    }

    pub fn args(&mut self, index: u32, delta: &str) {
        if !self.calls.contains_key(&index) {
            self.order.push(index);
        }
        self.calls.entry(index).or_default().arguments.push_str(delta);
    }

    pub fn take(&mut self, index: u32) -> Vec<StreamItem> {
        let Some(call) = self.calls.remove(&index) else { return Vec::new() };
        self.order.retain(|entry| *entry != index);
        if call.name.is_empty() {
            return vec![StreamItem::Fault("the provider sent a tool call with no name".into())];
        }
        let id = if call.id.is_empty() { format!("call_{index}") } else { call.id };
        let arguments = if call.arguments.trim().is_empty() { "{}".to_string() } else { call.arguments };
        if serde_json::from_str::<serde_json::Value>(&arguments).is_err() {
            return vec![StreamItem::Fault(format!("tool call {} has arguments that are not JSON", call.name))];
        }
        vec![StreamItem::ToolCall(ToolCall { id, name: call.name, arguments_json: arguments })]
    }

    /// Whatever the stream left open, in the order the calls started.
    pub fn drain(&mut self) -> Vec<StreamItem> {
        let order = std::mem::take(&mut self.order);
        let mut out = Vec::new();
        for index in order {
            out.extend(self.take(index));
        }
        out
    }
}

/// The URL a provider's endpoint is under, from its granted base URL.
pub fn endpoint(base_url: &str, path: &str) -> String {
    format!("{}/{}", base_url.trim_end_matches('/'), path.trim_start_matches('/'))
}

/// The provider's own name for a stop, mapped onto the seam's four cases.
pub fn finish_reason(text: &str) -> FinishReason {
    match text.trim().to_ascii_lowercase().as_str() {
        "" => FinishReason::Stop,
        "stop" | "end_turn" | "stop_sequence" | "end" | "complete" | "stop_now" | "finished" => FinishReason::Stop,
        "length" | "max_tokens" | "max_output_tokens" | "max_tokens_reached" | "model_length" => {
            FinishReason::Length
        }
        "tool_calls" | "tool_use" | "function_call" | "tool-calls" => FinishReason::ToolCalls,
        "content_filter" | "refusal" | "safety" | "recitation" | "blocklist" | "prohibited_content" => {
            FinishReason::ContentFilter
        }
        _ => FinishReason::Stop,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_scanner_reassembles_a_payload_split_across_reads() {
        let mut scanner = SseScanner::default();
        assert!(scanner.feed(b"data: {\"a\":").is_empty());
        let payloads = scanner.feed(b"1}\n\n");
        assert_eq!(payloads, vec!["{\"a\":1}"]);
    }

    #[test]
    fn the_scanner_handles_crlf_comments_blank_lines_and_done() {
        let mut scanner = SseScanner::default();
        let payloads = scanner.feed(b": keep-alive\r\n\r\nevent: x\r\ndata: {}\r\n\r\ndata: [DONE]\r\n\r\n");
        assert_eq!(payloads, vec!["{}"]);
        assert!(scanner.done());
        assert!(scanner.saw_any());
    }

    #[test]
    fn a_multi_line_data_field_is_joined_with_a_newline() {
        let mut scanner = SseScanner::default();
        assert_eq!(scanner.feed(b"data: a\ndata: b\n\n"), vec!["a\nb"]);
    }

    #[test]
    fn a_last_payload_without_its_blank_line_is_flushed() {
        let mut scanner = SseScanner::default();
        assert!(scanner.feed(b"data: {\"x\":1}").is_empty());
        assert_eq!(scanner.flush(), Some("{\"x\":1}".to_string()));
        assert_eq!(scanner.flush(), None);
    }

    #[test]
    fn tool_call_deltas_are_assembled_once_in_order() {
        let mut calls = Calls::default();
        calls.start(0, "call_a".into(), "read".into());
        calls.args(0, "{\"path\":");
        calls.args(0, "\"a.txt\"}");
        calls.start(1, "".into(), "grep".into());
        calls.args(1, "{\"q\":\"x\"}");
        let items = calls.drain();
        assert_eq!(items.len(), 2);
        assert_eq!(
            items[0],
            StreamItem::ToolCall(ToolCall {
                id: "call_a".into(),
                name: "read".into(),
                arguments_json: "{\"path\":\"a.txt\"}".into()
            })
        );
        assert_eq!(
            items[1],
            StreamItem::ToolCall(ToolCall { id: "call_1".into(), name: "grep".into(), arguments_json: "{\"q\":\"x\"}".into() })
        );
    }

    #[test]
    fn a_tool_call_with_broken_arguments_is_a_visible_fault() {
        let mut calls = Calls::default();
        calls.start(0, "id".into(), "read".into());
        calls.args(0, "{not json");
        match calls.drain().first() {
            Some(StreamItem::Fault(detail)) => assert!(detail.contains("not JSON"), "{detail}"),
            other => panic!("expected a fault, got {other:?}"),
        }
    }

    #[test]
    fn stop_reasons_map_onto_the_seams_four_cases() {
        assert_eq!(finish_reason("end_turn"), FinishReason::Stop);
        assert_eq!(finish_reason("max_tokens"), FinishReason::Length);
        assert_eq!(finish_reason("tool_use"), FinishReason::ToolCalls);
        assert_eq!(finish_reason("tool_calls"), FinishReason::ToolCalls);
        assert_eq!(finish_reason("SAFETY"), FinishReason::ContentFilter);
        assert_eq!(finish_reason(""), FinishReason::Stop);
    }
}
