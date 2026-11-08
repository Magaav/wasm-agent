//! `wa:model`'s vocabulary: task classes, data labels, the canonical request and usage/route records.
//!
//! Everything here is a value the seam decides or carries; JSON belongs to the policy file and to the
//! provider edge, and neither is represented by these types.

use serde_json::Value;

/// What the caller is doing. The class, not a model name, is what a turn asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum TaskClass {
    Plan,
    Code,
    Cheap,
    Vision,
    Default,
}

impl TaskClass {
    pub const ALL: [TaskClass; 5] = [
        TaskClass::Plan,
        TaskClass::Code,
        TaskClass::Cheap,
        TaskClass::Vision,
        TaskClass::Default,
    ];

    pub fn parse(text: &str) -> Option<TaskClass> {
        match text.trim().to_ascii_lowercase().as_str() {
            "plan" => Some(TaskClass::Plan),
            "code" => Some(TaskClass::Code),
            "cheap" => Some(TaskClass::Cheap),
            "vision" => Some(TaskClass::Vision),
            "default" | "" => Some(TaskClass::Default),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            TaskClass::Plan => "plan",
            TaskClass::Code => "code",
            TaskClass::Cheap => "cheap",
            TaskClass::Vision => "vision",
            TaskClass::Default => "default",
        }
    }
}

/// The data label a request carries (`docs/MODEL-GATEWAY.md`, "Data labels").
///
/// The order of the variants *is* the strictness order: `client` is the strictest. A session's label
/// is the strictest label seen in it, and a request is sent only to a provider that allows it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Label {
    Public,
    Internal,
    Client,
}

impl Label {
    pub const ALL: [Label; 3] = [Label::Public, Label::Internal, Label::Client];

    pub fn parse(text: &str) -> Option<Label> {
        match text.trim().to_ascii_lowercase().as_str() {
            "public" => Some(Label::Public),
            "internal" => Some(Label::Internal),
            "client" => Some(Label::Client),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Label::Public => "public",
            Label::Internal => "internal",
            Label::Client => "client",
        }
    }

    /// The strictest of `self` and `other`; the session rule, and the tool-result rule's base.
    pub fn strictest(self, other: Label) -> Label {
        if other > self {
            other
        } else {
            self
        }
    }

    pub fn parse_list(texts: &[String]) -> Result<Vec<Label>, String> {
        let mut out = Vec::new();
        for text in texts {
            match Label::parse(text) {
                Some(label) => out.push(label),
                None => return Err(format!("{text:?} is not a data label (public|internal|client)")),
            }
        }
        out.sort();
        out.dedup();
        Ok(out)
    }
}

/// Where a message came from, which is what decides its label.
///
/// The rule (job spec, and `docs/MODEL-GATEWAY.md`): a message from a channel is `client` unless the
/// chat is the operator's own; the operator's own typing is `internal`; a tool result inherits the
/// label of the source it read; the model's own output inherits the label of the turn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source<'a> {
    /// A WhatsApp/email/… message. `own_chat` is the operator's own chat with the node.
    Channel { own_chat: bool },
    /// The operator typing in the console: their own data.
    Operator,
    /// A tool result; `inherited` is the label of the thing that produced it.
    ToolResult { inherited: Label },
    /// The model's own text: never stricter than what it was shown.
    Model { inherited: Label },
    /// A file the node itself owns (its instructions, its notes).
    Node,
    /// Anything the caller could not classify. Fails closed: `client`.
    Unclassified(&'a str),
}

/// The label a source contributes to a session.
pub fn label_of_source(source: Source<'_>) -> Label {
    match source {
        Source::Channel { own_chat: true } => Label::Internal,
        Source::Channel { own_chat: false } => Label::Client,
        Source::Operator => Label::Internal,
        Source::ToolResult { inherited } => inherited,
        Source::Model { inherited } => inherited,
        Source::Node => Label::Internal,
        Source::Unclassified(_) => Label::Client,
    }
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ModelRef {
    pub provider: String,
    pub model: String,
}

impl ModelRef {
    pub fn parse(text: &str) -> Result<ModelRef, String> {
        let text = text.trim();
        match text.split_once('/') {
            Some((provider, model)) if !provider.is_empty() && !model.is_empty() => Ok(ModelRef {
                provider: provider.to_string(),
                model: model.to_string(),
            }),
            _ => Err(format!("{text:?} is not a provider/model reference")),
        }
    }

    pub fn as_string(&self) -> String {
        format!("{}/{}", self.provider, self.model)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    System,
    User,
    Assistant,
    Tool,
}

impl Role {
    pub fn parse(text: &str) -> Option<Role> {
        match text.trim().to_ascii_lowercase().as_str() {
            "system" | "developer" => Some(Role::System),
            "user" => Some(Role::User),
            "assistant" | "model" => Some(Role::Assistant),
            "tool" | "function" => Some(Role::Tool),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Role::System => "system",
            Role::User => "user",
            Role::Assistant => "assistant",
            Role::Tool => "tool",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Part {
    Text(String),
    Image { mime: String, bytes: Vec<u8> },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    /// The model's own arguments, verbatim (`{}` when it sent none).
    pub arguments_json: String,
}

/// One message of the request, byte for byte what the caller assembled.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Message {
    pub role: Role,
    pub parts: Vec<Part>,
    pub tool_calls: Vec<ToolCall>,
    pub tool_call_id: Option<String>,
    pub name: Option<String>,
    /// A prompt-cache breakpoint goes *after* this message. Never moved, never merged.
    pub cache_breakpoint: bool,
}

impl Message {
    pub fn text(role: Role, text: impl Into<String>) -> Message {
        Message {
            role,
            parts: vec![Part::Text(text.into())],
            tool_calls: Vec::new(),
            tool_call_id: None,
            name: None,
            cache_breakpoint: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolDef {
    pub name: String,
    pub description: String,
    /// The model-facing parameter schema; opaque to the seam.
    pub schema_json: String,
}

/// One turn, as the caller names it. The gateway never edits `messages` or `tools`.
#[derive(Clone, Debug, PartialEq)]
pub struct ChatRequest {
    pub session: String,
    pub class: TaskClass,
    pub model: Option<ModelRef>,
    pub label: Label,
    pub messages: Vec<Message>,
    pub tools: Vec<ToolDef>,
    pub max_output_tokens: u32,
    pub temperature: Option<f32>,
    /// The caller's estimate, so a drained budget refuses before a byte leaves the node.
    pub estimated_input_tokens: Option<u64>,
    pub timeout_ms: Option<u64>,
}

impl ChatRequest {
    /// A request with the fields a provider needs and the seam's defaults elsewhere.
    pub fn new(session: impl Into<String>, class: TaskClass, label: Label, messages: Vec<Message>) -> Self {
        ChatRequest {
            session: session.into(),
            class,
            model: None,
            label,
            messages,
            tools: Vec::new(),
            max_output_tokens: 4096,
            temperature: None,
            estimated_input_tokens: None,
            timeout_ms: None,
        }
    }

    /// The shape checks that are the seam's own (`invalid` refusals). A malformed request is refused
    /// before routing, so a bug in the loop cannot spend a provider call.
    pub fn validate(&self) -> Result<(), String> {
        if self.session.trim().is_empty() {
            return Err("session is empty".into());
        }
        if self.messages.is_empty() {
            return Err("messages is empty".into());
        }
        if self.max_output_tokens == 0 {
            return Err("max_output_tokens is 0".into());
        }
        let last = self.messages.last().expect("checked above");
        if last.role == Role::System {
            return Err("the last message is a system message".into());
        }
        match last.role {
            Role::User | Role::Tool | Role::Assistant => {}
            Role::System => unreachable!("checked above"),
        }
        for (index, message) in self.messages.iter().enumerate() {
            if message.parts.is_empty() && message.tool_calls.is_empty() {
                return Err(format!("messages[{index}] is empty"));
            }
            if message.role == Role::Tool && message.tool_call_id.is_none() {
                return Err(format!("messages[{index}] is a tool result without tool_call_id"));
            }
            for call in &message.tool_calls {
                if call.id.trim().is_empty() || call.name.trim().is_empty() {
                    return Err(format!("messages[{index}] has a tool call without id or name"));
                }
                if serde_json::from_str::<Value>(&call.arguments_json).is_err() {
                    return Err(format!("messages[{index}] tool call {} arguments are not JSON", call.name));
                }
            }
            if let Some(temperature) = self.temperature {
                if !(0.0..=2.0).contains(&temperature) {
                    return Err(format!("temperature {temperature} is outside 0..=2"));
                }
            }
            for part in &message.parts {
                match part {
                    Part::Text(text) => {
                        let _ = text;
                    }
                    Part::Image { mime, bytes } => {
                        if !mime.starts_with("image/") || bytes.is_empty() {
                            return Err(format!("messages[{index}] carries an image part that is not an image"));
                        }
                    }
                }
            }
        }
        for (index, tool) in self.tools.iter().enumerate() {
            if tool.name.trim().is_empty() {
                return Err(format!("tools[{index}] has no name"));
            }
            if serde_json::from_str::<Value>(&tool.schema_json).is_err() {
                return Err(format!("tools[{index}] ({}) schema is not JSON", tool.name));
            }
        }
        Ok(())
    }

    /// The bytes that must never move: the ordered prefix up to the last cache breakpoint.
    ///
    /// This is the number a prompt cache is scored on, so it is a first-class value here rather than
    /// something a test derives: `text()` concatenates the roles and text parts, and any provider
    /// adapter's own rendering must be a stable function of it.
    pub fn prefix(&self) -> Vec<u8> {
        let last = self
            .messages
            .iter()
            .rposition(|message| message.cache_breakpoint)
            .map(|index| index + 1)
            .unwrap_or(self.messages.len());
        let mut out = Vec::new();
        for message in &self.messages[..last] {
            out.extend_from_slice(message.role.as_str().as_bytes());
            out.push(b':');
            for part in &message.parts {
                if let Part::Text(text) = part {
                    out.extend_from_slice(text.as_bytes());
                }
            }
            if message.cache_breakpoint {
                out.extend_from_slice(b"\x00cache\x00");
            }
            out.push(b'\n');
        }
        out
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EmbedRequest {
    pub session: String,
    pub class: TaskClass,
    pub model: Option<ModelRef>,
    pub label: Label,
    pub texts: Vec<String>,
    pub timeout_ms: Option<u64>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub reasoning_tokens: u64,
}

impl Usage {
    /// What a token budget is charged: everything the provider counted, reasoning included (a budget
    /// that ignored reasoning would be a budget a thinking model can walk through).
    pub fn spent(self) -> u64 {
        self.input_tokens + self.output_tokens + self.reasoning_tokens
    }

    pub fn total_tokens(self) -> u64 {
        self.spent()
    }

    pub fn merge(&mut self, other: Usage) {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.cache_read_tokens += other.cache_read_tokens;
        self.cache_write_tokens += other.cache_write_tokens;
        self.reasoning_tokens += other.reasoning_tokens;
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FinishReason {
    Stop,
    Length,
    ToolCalls,
    ContentFilter,
    Error,
}

impl FinishReason {
    pub fn as_str(self) -> &'static str {
        match self {
            FinishReason::Stop => "stop",
            FinishReason::Length => "length",
            FinishReason::ToolCalls => "tool_calls",
            FinishReason::ContentFilter => "content_filter",
            FinishReason::Error => "error",
        }
    }
}

/// Where a request went, and why. The same record is what `wa models explain` prints.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Route {
    pub provider: String,
    pub model: String,
    pub kind: crate::policy::ProviderKind,
    pub host: String,
    pub class: TaskClass,
    pub label: Label,
    pub attempt: u32,
    pub fallback_from: Option<ModelRef>,
    pub reason: String,
}

/// One item of the call, as it arrives.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    Delta(String),
    ReasoningDelta(String),
    /// A tool call the model completed: the adapter assembled its deltas.
    ToolCall(ToolCall),
    Usage(Usage),
    Finish(Finish),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Finish {
    pub reason: FinishReason,
    pub route: Route,
    pub usage: Usage,
    pub attempts: u32,
    pub latency_ms: u64,
    pub cache_hit: bool,
}

impl Finish {
    pub fn cache_hit(usage: Usage) -> bool {
        usage.cache_read_tokens > usage.cache_write_tokens && usage.cache_read_tokens > 0
    }
}

/// A refusal: the caller's own vocabulary, never a provider fault.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    LabelNotAllowed(LabelRefusal),
    NoRoute(NoRoute),
    BudgetExceeded(BudgetRefusal),
    Invalid(String),
}

impl Refusal {
    pub fn as_str(&self) -> &'static str {
        match self {
            Refusal::LabelNotAllowed(_) => "label_not_allowed",
            Refusal::NoRoute(_) => "no_route",
            Refusal::BudgetExceeded(_) => "budget_exceeded",
            Refusal::Invalid(_) => "invalid",
        }
    }

    /// One line for the caller and the log: a reason and a shape, never a message body.
    pub fn reason(&self) -> String {
        match self {
            Refusal::LabelNotAllowed(refusal) => refusal.reason.clone(),
            Refusal::NoRoute(refusal) => {
                let skipped: Vec<String> = refusal
                    .skipped
                    .iter()
                    .map(|skip| format!("{}/{}: {}", skip.provider, skip.model, skip.reason))
                    .collect();
                if skipped.is_empty() {
                    format!("no route for class {} at label {}", refusal.class.as_str(), refusal.label.as_str())
                } else {
                    format!("no route for class {}: {}", refusal.class.as_str(), skipped.join("; "))
                }
            }
            Refusal::BudgetExceeded(refusal) => refusal.reason.clone(),
            Refusal::Invalid(reason) => format!("invalid request: {reason}"),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LabelRefusal {
    pub provider: String,
    pub model: String,
    pub label: Label,
    pub allowed: Vec<Label>,
    pub reason: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Skip {
    pub provider: String,
    pub model: String,
    pub reason: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NoRoute {
    pub class: TaskClass,
    pub label: Label,
    pub skipped: Vec<Skip>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BudgetRefusal {
    /// `node` or `session:<id>`.
    pub scope: String,
    pub spent: u64,
    pub limit: u64,
    pub reason: String,
}

/// A provider or transport fault: the call produced nothing (or broke mid-stream).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Fault {
    /// A status the seam does not retry (400, 401 after the breaker, …), with its body's first line.
    Status { status: u16, detail: String },
    /// 429 / 5xx / timeout / transport: the next candidate may serve.
    Retryable { status: Option<u16>, detail: String },
    /// The stream broke after items were delivered; the caller has already seen text.
    StreamCut { detail: String, emitted: bool },
    /// The provider answered in a shape the adapter cannot parse (a fail-visible answer, never silence).
    Shape(String),
}

impl Fault {
    pub fn retryable(&self) -> bool {
        matches!(self, Fault::Retryable { .. })
    }

    pub fn detail(&self) -> &str {
        match self {
            Fault::Status { detail, .. }
            | Fault::Retryable { detail, .. }
            | Fault::StreamCut { detail, .. } => detail,
            Fault::Shape(detail) => detail,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Fault::Status { .. } => "fault_status",
            Fault::Retryable { .. } => "fault_retryable",
            Fault::StreamCut { .. } => "fault_stream_cut",
            Fault::Shape(_) => "fault_shape",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_strictest_label_wins_across_a_session() {
        let mut session = Label::Public;
        for label in [Label::Public, Label::Internal, Label::Client, Label::Public] {
            session = session.strictest(label);
        }
        assert_eq!(session, Label::Client);
        assert_eq!(Label::Public.strictest(Label::Internal), Label::Internal);
        assert_eq!(Label::Client.strictest(Label::Public), Label::Client);
    }

    #[test]
    fn a_client_message_labels_a_channel_and_the_operator_chat_does_not() {
        assert_eq!(label_of_source(Source::Channel { own_chat: false }), Label::Client);
        assert_eq!(label_of_source(Source::Channel { own_chat: true }), Label::Internal);
        assert_eq!(label_of_source(Source::Operator), Label::Internal);
        // A tool result is never weaker than the thing it read.
        assert_eq!(label_of_source(Source::ToolResult { inherited: Label::Client }), Label::Client);
        assert_eq!(label_of_source(Source::Model { inherited: Label::Internal }), Label::Internal);
        // An unclassified source fails closed.
        assert_eq!(label_of_source(Source::Unclassified("telegram")), Label::Client);
    }

    #[test]
    fn an_unknown_label_spelling_is_refused_not_defaulted() {
        assert!(Label::parse("secret").is_none());
        assert_eq!(Label::parse(" CLIENT "), Some(Label::Client));
        assert!(Label::parse_list(&["public".into(), "nope".into()]).is_err());
    }

    #[test]
    fn a_model_ref_needs_both_halves() {
        assert_eq!(
            ModelRef::parse("deepseek/deepseek-v4.1-flash").expect("parses"),
            ModelRef {
                provider: "deepseek".into(),
                model: "deepseek-v4.1-flash".into()
            }
        );
        assert!(ModelRef::parse("deepseek").is_err());
        assert!(ModelRef::parse("/model").is_err());
        assert!(ModelRef::parse("provider/").is_err());
    }

    #[test]
    fn the_prefix_stops_at_the_last_breakpoint_and_is_stable() {
        let mut first = Message::text(Role::System, "instructions");
        first.cache_breakpoint = true;
        let mut request = ChatRequest::new("s", TaskClass::Default, Label::Public, vec![
            first,
            Message::text(Role::User, "hello"),
            Message::text(Role::Assistant, "hi"),
        ]);
        let prefix = request.prefix();
        assert!(String::from_utf8_lossy(&prefix).starts_with("system:instructions"));
        assert!(!String::from_utf8_lossy(&prefix).contains("hello"));
        request.messages.push(Message::text(Role::User, "next"));
        assert_eq!(request.prefix(), prefix, "appending a turn must not move the prefix");
    }

    #[test]
    fn a_malformed_request_is_refused_before_it_is_routed() {
        let mut request = ChatRequest::new("s", TaskClass::Default, Label::Public, vec![]);
        assert!(request.validate().unwrap_err().contains("messages is empty"));
        request.messages = vec![Message::text(Role::System, "only system")];
        assert!(request.validate().unwrap_err().contains("last message is a system"));
        request.messages = vec![Message::text(Role::User, "hi")];
        request.max_output_tokens = 0;
        assert!(request.validate().unwrap_err().contains("max_output_tokens"));
        request.max_output_tokens = 10;
        request.temperature = Some(3.0);
        assert!(request.validate().unwrap_err().contains("temperature"));
        request.temperature = None;
        request.tools = vec![ToolDef {
            name: "read".into(),
            description: "".into(),
            schema_json: "{not json".into(),
        }];
        assert!(request.validate().unwrap_err().contains("schema is not JSON"));
    }
}
