//! The rules, apart from the boundary: the fence, the guest's tool table, the two guest globals this
//! seam answers (`searchTools`, `describeTool`) and the join between a guest call and the loop.
//!
//! Everything here is a port of `lua/core/codemode.lua`'s in-sandbox half — the `forbidden` set, the
//! `route_of` sentences, the guest identifier mapping and the four branches of `searchTools` — so that
//! the two paths answer a script identically. The sentences are copied verbatim on purpose: they are
//! what the model reads, and `scripts/test-codemode-boundary.lua` asserts them on both paths.
//!
//! It is plain data in and plain data out (no WIT types), which is what lets `cargo test` run it on this
//! machine without a wasm target.

use serde_json::{json, Map, Value};

/// Tools that are a direct call only: the effect stays one reviewable call with a receipt outside the
/// script, and each one is here for a stated reason. Everything else is callable inside a script with
/// exactly the per-call checks an ordinary call gets, and a tool that refuses outside refuses inside
/// with the same text because both reach the same dispatcher.
///
/// This list must equal `DIRECT_ONLY` in `lua/core/codemode.lua`; `scripts/test-codemode-parity.lua`
/// asserts the two seams answer the same way for every name in it.
pub const FORBIDDEN: &[&str] = &[
    // a second sandbox inside the first would hide one effect stream behind another
    "codemode",
    // the outer facades pin definitions into this session's loadout
    "tool_call",
    "tool_search",
    // delegation spends model calls and creates a child session
    "subagent",
    // landing a worker tip is a single receipted integration action
    "integrate",
    // owns this session's worktree / folds a session into this conversation / shapes this session
    "session_worktree",
    "resume_session",
    "session_debug",
    "session_fixture",
    // installs a durable wave-end obligation
    "wave_autoflush",
    // a deployment, not a script step
    "node_update",
    // outbound messages are operator-gated effects with a durable message id
    "whatsapp_send",
    "email_send",
];

/// The guest globals that come from the node rather than from this seam: the retained evidence behind
/// `showCall`, and the live capability registry behind `capabilities()`/`describe()`.
pub const HOST_GLOBALS: &[&str] = &["showCall", "capabilities", "describe"];

/// The guest globals this seam answers, with the prelude's `spread` flag.
///
/// The list is the native loop's, name for name and flag for flag (`lua/core/codemode.lua`: `searchTools`
/// spread, then `describeTool`, `showCall`, `capabilities`, `describe`). A shorter list here means a
/// script that calls `capabilities()` runs natively and fails with `ReferenceError: capabilities is not
/// defined` through the component - the parity suite compared the two and said so.
pub const GUEST_GLOBALS: &[(&str, bool)] = &[
    ("searchTools", true),
    ("describeTool", false),
    ("showCall", false),
    ("capabilities", false),
    ("describe", false),
];

/// The node's pre-flight view of a tool (`tools.discovery_execution`), pinned at `open`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Execution {
    pub status: String,
    pub scope: String,
    pub binding: String,
    pub reason: Option<String>,
    pub detail: Option<String>,
    pub next: Option<String>,
    pub available: Option<bool>,
    pub required: Option<bool>,
}

impl Execution {
    /// The two statuses the node itself calls not-executable right now.
    pub fn blocked(&self) -> bool {
        self.status == "blocked" || self.status == "unknown"
    }

    fn json(&self) -> Value {
        let mut out = Map::new();
        out.insert("scope".into(), json!(self.scope));
        out.insert("workspace_binding".into(), json!(self.binding));
        out.insert("status".into(), json!(self.status));
        if let Some(reason) = &self.reason {
            out.insert("reason".into(), json!(reason));
        }
        if let Some(detail) = &self.detail {
            out.insert("detail".into(), json!(detail));
        }
        if let Some(next) = &self.next {
            out.insert("next".into(), json!(next));
        }
        if let Some(available) = self.available {
            out.insert("available".into(), json!(available));
        }
        if let Some(required) = self.required {
            out.insert("required".into(), json!(required));
        }
        Value::Object(out)
    }
}

/// One catalogue entry as the loop hands it over.
#[derive(Clone, Debug)]
pub struct Fact {
    pub name: String,
    pub description: String,
    pub schema: Value,
    pub execution: Execution,
}

/// A tool a script may call.
#[derive(Clone, Debug)]
pub struct Tool {
    pub name: String,
    pub js_name: String,
    pub description: String,
    pub schema: Value,
    pub execution: Execution,
}

/// A tool a script may see and not call, with the sentence that says where it runs.
#[derive(Clone, Debug)]
pub struct Outside {
    pub name: String,
    pub js_name: String,
    pub description: String,
    pub schema: Value,
    pub execution: Execution,
    pub route: String,
}

/// What one script's catalogue is: the callable set, the fenced set (what discovery still shows and the
/// guest's table still carries, answering with its route), and the order the node sent them in.
/// `None` from [`plan`] is the identifier collision the loop refuses.
#[derive(Clone, Debug, Default)]
pub struct Catalogue {
    pub tools: Vec<Tool>,
    pub outside: Vec<Outside>,
    /// Every catalogue name, in the order the node sent it. The guest's `tools` object is built from the
    /// descriptors in this order on both paths, and the proxy's "Available: a, b, c" message reads it
    /// back - so an order that differs is a message that differs (`lua/core/codemode.lua`, `descriptors`).
    pub order: Vec<String>,
}

impl Catalogue {
    pub fn callable(&self, name: &str) -> Option<&Tool> {
        self.tools.iter().find(|tool| tool.name == name)
    }

    pub fn fenced(&self, name: &str) -> Option<&Outside> {
        self.outside.iter().find(|tool| tool.name == name)
    }

    /// Every name discovery can mention, sorted: the listing's order and the pool suggestions draw from.
    pub fn names(&self) -> Vec<String> {
        let mut names: Vec<String> = self.tools.iter().map(|tool| tool.name.clone()).collect();
        names.extend(self.outside.iter().map(|tool| tool.name.clone()));
        names.sort();
        names
    }
}

/// The spelling a tool has inside the guest: everything that is not a word character becomes `_`.
pub fn js_name(name: &str) -> String {
    name.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' }).collect()
}

/// Every direct-call-only tool's reason, verbatim from `DIRECT_ONLY` in `lua/core/codemode.lua`.
///
/// The fence itself is [`FORBIDDEN`]; this table is the sentence a refusal carries, and it is copied
/// character for character because discovery's answer is compared field for field across the seam
/// (`scripts/test-codemode-component.lua`): a reworded sentence here is a different fact on the two
/// paths, and the model reads whichever path ran. `scripts/test-codemode-parity.lua` asserts the keys
/// are exactly `codemode.DIRECT_ONLY`'s.
pub fn direct_only_reason(name: &str) -> Option<&'static str> {
    Some(match name {
        "codemode" => "a script does not nest: a second sandbox inside the first would hide one effect stream behind another",
        "tool_call" => "the outer facade pins definitions into this session's loadout; a script calls await tools.<name>(args) directly instead",
        "tool_search" => "the outer facade pins definitions into this session's loadout; searchTools/describeTool answer the same question inside without changing it",
        "subagent" => "delegation spends model calls and creates a child session: one reviewable call, never a step inside a script",
        "integrate" => "landing a worker tip is a single receipted integration action, never a script step",
        "session_worktree" => "it allocates and owns this session's worktree; a bound root that re-points mid-script would change what every later call means",
        "resume_session" => "it folds another session into the conversation the script is already running in",
        "session_debug" => "it sets this session's recording mode: changing what is recorded mid-script makes the script its own unrecorded effect",
        "session_fixture" => "it exports this session as a fixture while the script is still writing that session",
        "wave_autoflush" => "it installs a durable wave-end obligation for the coordinator; installation is a direct receipted action",
        "node_update" => "it updates and restarts a node: a deployment, not a script step",
        "whatsapp_send" => "an outbound message is one operator-gated effect with a durable message id and a documented status; it stays a direct call",
        "email_send" => "an outbound message is one operator-gated effect with a durable message id and a documented status; it stays a direct call",
        _ => return None,
    })
}

/// Why a tool is not callable here, in the words the model already knows: a verbatim port of `route_of`
/// in `lua/core/codemode.lua`, in the same order and with the same sentences. The direct-call list comes
/// first (as it does natively, which is why that branch also covers `tool_call`/`tool_search`), then the
/// outer facades, then the node's own refusal, then the generic control-plane sentence.
pub fn route_of(name: &str, execution: &Execution) -> String {
    if let Some(reason) = direct_only_reason(name) {
        return format!("Direct call only: {reason}. End the script, then call {name} as an ordinary tool.");
    }
    if name == "tool_search" || name == "tool_call" {
        return "Outer facade: inside a script use searchTools/describeTool and call await tools.<name>(args) directly.".to_string();
    }
    if execution.blocked() {
        let reason = execution.reason.clone().unwrap_or_else(|| execution.status.clone());
        let next = execution.next.clone().unwrap_or_default();
        return format!("Not callable in this run: {reason}. {next}");
    }
    format!(
        "Control plane: call {name} as an ordinary tool, outside codemode (end the script, then call it directly). Inside a script it is refused."
    )
}

/// Split the run's catalogue into the callable set and the fence. `None` is a collision: two tools whose
/// names are the same inside the guest, which would make `tools.<name>` ambiguous.
pub fn plan(facts: Vec<Fact>) -> Option<Catalogue> {
    let mut catalogue = Catalogue::default();
    for fact in facts {
        catalogue.order.push(fact.name.clone());
        if FORBIDDEN.iter().any(|forbidden| *forbidden == fact.name) || fact.execution.blocked() {
            let route = route_of(&fact.name, &fact.execution);
            catalogue.outside.push(Outside {
                name: fact.name.clone(),
                js_name: js_name(&fact.name),
                description: fact.description,
                schema: fact.schema,
                execution: fact.execution,
                route,
            });
            continue;
        }
        let js = js_name(&fact.name);
        if let Some(existing) = catalogue.tools.iter().find(|tool| tool.js_name == js) {
            if existing.name != fact.name {
                return None;
            }
        }
        catalogue.tools.push(Tool {
            name: fact.name,
            js_name: js,
            description: fact.description,
            schema: fact.schema,
            execution: fact.execution,
        });
    }
    Some(catalogue)
}

// ------------------------------------------------------------------------------- the guest's globals

/// What `tools.<name>(args)` carries: the argument list the guest passed, and — when the seam decides
/// the call cannot run — the refusal, as the `{error:…}` value the model already knows.
#[derive(Clone, Debug)]
pub struct ToolCall {
    pub name: String,
    /// `None` is a call with no arguments, which the guest sends as `undefined`.
    pub args: Option<String>,
    pub admittance: ToolAdmittance,
}

#[derive(Clone, Debug)]
pub enum ToolAdmittance {
    /// The loop validates the arguments and dispatches it.
    Dispatch,
    /// Not callable here. `Some(route)` means the catalogue knows the name and says where it runs;
    /// `None` means no such target, which is the plain `codemode_target_not_available`.
    Fenced(Option<String>),
}

/// What a guest call means for the loop.
#[derive(Clone, Debug)]
pub enum Guest {
    /// The loop dispatches (or refuses) a tool.
    Tool(ToolCall),
    /// The node answers this global (`showCall`, `capabilities`, `describe`, `describeTool("showCall")`).
    Host,
    /// The seam answered it; the value is the guest's and the call is over.
    Answered(Value, bool),
}

/// One guest call event, as the sandbox reported it.
pub fn interpret(catalogue: &Catalogue, target: &str, name: &str, args: Option<&str>) -> Guest {
    if target == "global" {
        return match name {
            "searchTools" => {
                let params = parse_params(args);
                let (value, ok) = search_tools(catalogue, &params);
                Guest::Answered(value, ok)
            }
            "describeTool" => {
                let params = parse_params(args);
                match describe_tool(catalogue, &params) {
                    Some(value) => Guest::Answered(value, true),
                    // `describeTool("showCall")` is the presentation's own help, which the loop owns.
                    None => Guest::Host,
                }
            }
            _ if HOST_GLOBALS.contains(&name) => Guest::Host,
            _ => Guest::Answered(json!({"error": "codemode_global_not_available"}), false),
        };
    }
    let admittance = match catalogue.callable(name) {
        Some(_) => ToolAdmittance::Dispatch,
        None => ToolAdmittance::Fenced(catalogue.fenced(name).map(|outside| outside.route.clone())),
    };
    Guest::Tool(ToolCall { name: name.to_string(), args: args.map(str::to_string), admittance })
}

/// The guest's argument list: `undefined` and `""` are "no arguments", which is `[]`.
fn parse_params(args: Option<&str>) -> Value {
    match args {
        None | Some("") | Some("undefined") => Value::Array(Vec::new()),
        Some(raw) => serde_json::from_str(raw).unwrap_or_else(|_| Value::Array(Vec::new())),
    }
}

/// `searchTools(args)`: the batch form (`{names:[…]}`, `"select:a,b"`), the listing (`"*"` or nothing)
/// and the keyword form, in that order — exactly the branches the native loop takes.
pub fn search_tools(catalogue: &Catalogue, params: &Value) -> (Value, bool) {
    // (1) the two argument shapes the model knows: `searchTools("text", {limit})` and
    // `searchTools({query, limit})`.
    let (mut query, mut options) = (params.get(0).cloned(), params.get(1).cloned());
    if matches!(query, Some(Value::Object(_))) && options.is_none() {
        let object = query.clone().unwrap_or(Value::Object(Map::new()));
        options = Some(object.clone());
        query = object.get("query").cloned();
    }
    let options = match options {
        Some(Value::Object(map)) => Value::Object(map),
        _ => Value::Object(Map::new()),
    };
    let names_arg = options.get("names").cloned().filter(|value| !value.is_null());
    let query_text = match &query {
        Some(Value::String(text)) => Some(text.clone()),
        _ => None,
    };
    let wanted = match requested_names(query_text.as_deref(), names_arg.as_ref()) {
        Err(refusal) => return (json!({"error": refusal}), false),
        Ok(wanted) => wanted,
    };
    // The listing is decided by the argument as the guest sent it, not by its text: a `null` or a
    // number is neither a listing nor a keyword.
    let listing = wanted.is_none()
        && match &query {
            None => true,
            Some(Value::String(text)) => text == "*" || !has_graphic(text),
            Some(_) => false,
        };
    let limit = options.get("limit").cloned().unwrap_or(if listing { json!(50) } else { json!(8) });
    let offset = options.get("offset").cloned().unwrap_or(json!(0));

    if let Some(wanted) = wanted {
        if options.get("limit").is_some() && !bounded(&limit, 1, 8) {
            return (json!({"error": "invalid_tool_search_limit"}), false);
        }
        let mut tools = Vec::new();
        let mut missing = Vec::new();
        for name in &wanted {
            match (catalogue.callable(name), catalogue.fenced(name)) {
                (Some(tool), _) => tools.push(entry(&tool.name, &tool.schema, &tool.execution, None)),
                (None, Some(outside)) => {
                    tools.push(entry(&outside.name, &outside.schema, &outside.execution, Some(&outside.route)))
                }
                (None, None) => {
                    let echo = echo_name(name);
                    missing.push(json!({"name": echo, "suggestions": nearest(&echo, &catalogue.names(), 3)}));
                }
            }
        }
        let value = json!({
            "tools": tools,
            "matches": tools.len(),
            "missing": missing,
            "requested": wanted.len(),
            "invocation": BATCH_INVOCATION,
        });
        return (value, true);
    }

    if listing {
        if !bounded(&limit, 1, 200) || !integer(&offset, 0) {
            return (json!({"error": "invalid_tool_search_limit"}), false);
        }
        let names = catalogue.names();
        let limit = limit.as_f64().unwrap_or(50.0) as usize;
        let offset = offset.as_f64().unwrap_or(0.0) as usize;
        let mut page = Vec::new();
        for index in offset..names.len().min(offset.saturating_add(limit)) {
            let name = &names[index];
            match (catalogue.callable(name), catalogue.fenced(name)) {
                (Some(tool), _) => page.push(json!({
                    "name": tool.name,
                    "description": first_line(&tool.description),
                    "execution": tool.execution.json(),
                    "callable": true,
                })),
                (None, Some(outside)) => page.push(json!({
                    "name": outside.name,
                    "description": first_line(&schema_description(&outside.schema)),
                    "execution": outside.execution.json(),
                    "callable": false,
                    "route": outside.route,
                })),
                (None, None) => {}
            }
        }
        return (
            json!({
                "tools": page,
                "matches": names.len(),
                "offset": offset,
                "has_more": offset.saturating_add(limit) < names.len(),
                "invocation": LISTING_INVOCATION,
            }),
            true,
        );
    }

    let query_text = match query_text {
        Some(text) if text.len() <= 256 => text,
        _ => return (json!({"error": "tool_search_query_required"}), false),
    };
    if !bounded(&limit, 1, 8) {
        return (json!({"error": "invalid_tool_search_limit"}), false);
    }
    let lowered = query_text.to_lowercase();
    let terms: Vec<String> = lowered.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_')).filter(|term| !term.is_empty()).map(str::to_string).collect();
    let mut matches: Vec<(u32, String, Value)> = Vec::new();
    let mut consider = |name: &str, schema: &Value, execution: &Execution, route: Option<&str>| {
        let hay = format!("{} {}", name, schema_description(schema)).to_lowercase();
        let mut score = 0u32;
        for term in &terms {
            if hay.contains(term.as_str()) {
                score += 1;
            }
        }
        if score > 0 {
            matches.push((score, name.to_string(), entry(name, schema, execution, route)));
        }
    };
    for tool in &catalogue.tools {
        consider(&tool.name, &tool.schema, &tool.execution, None);
    }
    for outside in &catalogue.outside {
        consider(&outside.name, &outside.schema, &outside.execution, Some(&outside.route));
    }
    matches.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    let count = matches.len();
    let found: Vec<Value> = matches.into_iter().take(limit.as_f64().unwrap_or(8.0) as usize).map(|(_, _, value)| value).collect();
    (
        json!({
            "tools": found,
            "matches": count,
            "invocation": KEYWORD_INVOCATION,
        }),
        true,
    )
}

/// `describeTool(name)`: `None` when the node owns the answer (`showCall`), the schema view otherwise —
/// including the `null` an unknown name produces, which is what the native path delivers.
pub fn describe_tool(catalogue: &Catalogue, params: &Value) -> Option<Value> {
    let name = match params {
        Value::String(text) => text.clone(),
        Value::Array(items) => match items.first() {
            Some(Value::String(text)) => text.clone(),
            _ => return Some(Value::Null),
        },
        _ => return Some(Value::Null),
    };
    if name == "showCall" {
        return None;
    }    if let Some(tool) = catalogue.callable(&name) {
        return Some(json!({
            "name": tool.name,
            "description": schema_description(&tool.schema),
            "parameters": tool.schema.get("function").and_then(|f| f.get("parameters")).cloned().unwrap_or(Value::Null),
            "execution": tool.execution.json(),
            "callable": true,
        }));
    }
    if let Some(outside) = catalogue.fenced(&name) {
        return Some(json!({
            "name": outside.name,
            "description": schema_description(&outside.schema),
            "parameters": outside.schema.get("function").and_then(|f| f.get("parameters")).cloned().unwrap_or(Value::Null),
            // The node's pre-flight view travels with a fenced entry too: `describeTool` is how the model
            // learns *why* a name it can see is not callable here, and the native loop's `described()`
            // returns `execution` for both views. Omitting it here made the two answers differ by one
            // field - which the parity suite compares as a hash and reported (`describeTool gives a
            // schema`).
            "execution": outside.execution.json(),
            "callable": false,
            "route": outside.route,
        }));
    }
    // A name this seam does not know is answered by the node, not here: the loop's `describeTool` returns
    // the `unknown_tool` record with the nearest permitted names (`lua/core/codemode.lua`,
    // `tool_lookup.described`), which is what the native path has always answered. Returning `null` here
    // made the two paths disagree on `describeTool("no_such_tool")` - the parity suite compares the
    // answer, not only its shape - and the loop's answer is the one the model already knows.
    None
}

const BATCH_INVOCATION: &str = "Guest-local metadata only; every entry listed here is callable in this script (callable:false entries run outside, see route). Native current-catalog/profile/type/effect checks apply to each call.";
const LISTING_INVOCATION: &str = "The whole catalogue, paged; describeTool(name) gives the full schema. callable:false entries run outside the script: their route says how. Native checks apply to each call.";
const KEYWORD_INVOCATION: &str = "Guest-local metadata only; callable:false entries run outside the script (see route). Native current-catalog/profile/type/effect checks apply to each call.";

// ----------------------------------------------------------------------------------- small pieces

fn entry(name: &str, schema: &Value, execution: &Execution, route: Option<&str>) -> Value {
    let mut out = Map::new();
    out.insert("name".into(), json!(name));
    out.insert("schema".into(), schema.clone());
    out.insert("execution".into(), execution.json());
    out.insert("callable".into(), json!(route.is_none()));
    if let Some(route) = route {
        out.insert("route".into(), json!(route));
    }
    Value::Object(out)
}

/// The model's own tool schema: `{"function":{"description":…,"parameters":…}}`.
pub fn schema_description(schema: &Value) -> String {
    match schema.get("function").and_then(|f| f.get("description")) {
        Some(Value::String(text)) => text.clone(),
        _ => String::new(),
    }
}

/// The first line of a description, bounded — what a listing entry shows.
fn first_line(text: &str) -> String {
    let line = text.split('\n').next().unwrap_or("");
    bound_bytes(line, 200)
}

/// Lua's `sub(1, n)` is byte-based; the one deliberate difference is that a slice never splits a
/// character (the prompt bounding elsewhere in this tree makes the same choice).
fn bound_bytes(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_string();
    }
    let mut end = limit;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_string()
}

/// A miss echoes the model's own text, bounded so a huge string cannot cost the transcript.
pub fn echo_name(name: &str) -> String {
    if name.len() > 64 {
        bound_bytes(name, 64)
    } else {
        name.to_string()
    }
}

fn has_graphic(text: &str) -> bool {
    text.chars().any(|c| !c.is_whitespace())
}

fn integer(value: &Value, min: u64) -> bool {
    match value.as_f64() {
        Some(number) => number.fract() == 0.0 && number >= min as f64,
        None => false,
    }
}

fn bounded(value: &Value, min: u64, max: u64) -> bool {
    match value.as_f64() {
        Some(number) => number.fract() == 0.0 && number >= min as f64 && number <= max as f64,
        None => false,
    }
}

/// `^%s*(.-)%s*$` with the 256-byte bound the declared `maxLength` gives.
fn requested_text(value: &Value) -> Option<String> {
    let text = value.as_str()?.trim();
    if text.is_empty() {
        return None;
    }
    Some(bound_bytes(text, 256))
}

/// `"select:a,b,c"` — one request spelled inside a string.
fn select_list(query: &str) -> Option<Vec<String>> {
    let text = query.trim_start();
    let word_len = text.chars().take_while(|c| c.is_ascii_alphabetic() || *c == '_').count();
    if word_len == 0 || !text[word_len..].starts_with(':') {
        return None;
    }
    if !text[..word_len].eq_ignore_ascii_case("select") {
        return None;
    }
    let body = text[word_len + 1..].trim();
    Some(body.split(',').filter_map(|part| requested_text(&Value::String(part.to_string()))).collect())
}

/// `(names, Some(list))` is a batch, `(…, None)` a keyword search, `Err` a refusal. A comma list sent as
/// a string has exactly one reading, so it is the same batch.
fn requested_names(query: Option<&str>, names: Option<&Value>) -> Result<Option<Vec<String>>, &'static str> {
    if names.is_some() && query.is_some_and(|text| has_graphic(text)) {
        return Err("tool_search_arguments_exclusive");
    }
    let list = match names {
        None => match query.and_then(select_list) {
            None => return Ok(None),
            Some(list) if list.is_empty() => return Err("invalid_tool_search_names"),
            Some(list) => list,
        },
        Some(Value::String(raw)) => match select_list(&format!("select:{raw}")) {
            Some(list) if !list.is_empty() => list,
            _ => return Err("invalid_tool_search_names"),
        },
        Some(Value::Array(items)) if !items.is_empty() => {
            let mut list = Vec::new();
            for item in items {
                match requested_text(item) {
                    Some(name) => list.push(name),
                    None => return Err("invalid_tool_search_names"),
                }
            }
            list
        }
        Some(_) => return Err("invalid_tool_search_names"),
    };
    let mut unique: Vec<String> = Vec::new();
    for name in list {
        if !unique.iter().any(|seen| *seen == name) {
            unique.push(name);
        }
    }
    if unique.len() > 8 {
        return Err("invalid_tool_search_names");
    }
    Ok(Some(unique))
}

/// A misspelt name becomes a correction: the candidates come from the script's own catalogue, so a
/// suggestion can never disclose a name the role was denied.
pub fn nearest(name: &str, available: &[String], limit: usize) -> Vec<String> {
    let wanted = name.to_lowercase();
    let mut near: Vec<(usize, String)> = Vec::new();
    for candidate in available {
        let lowered = candidate.to_lowercase();
        let contained = lowered.contains(&wanted) || wanted.contains(&lowered);
        let score = distance(&wanted, &lowered);
        if score <= std::cmp::max(2, wanted.len() / 3) || (contained && wanted.len() >= 3) {
            near.push((score, candidate.clone()));
        }
    }
    near.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    near.into_iter().take(limit).map(|(_, name)| name).collect()
}

fn distance(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut current = vec![i; b.len() + 1];
        for j in 1..=b.len() {
            let cost = if a[i - 1] == b[j - 1] { 0 } else { 1 };
            current[j] = std::cmp::min(std::cmp::min(previous[j] + 1, current[j - 1] + 1), previous[j - 1] + cost);
        }
        previous = current;
    }
    previous[b.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn execution(status: &str) -> Execution {
        Execution { status: status.to_string(), scope: "workspace_policy_only".into(), binding: "not_applicable".into(), ..Execution::default() }
    }

    fn fact(name: &str, read_only: bool) -> Fact {
        Fact {
            name: name.to_string(),
            description: format!("{name} does something"),
            schema: json!({"type": "function", "function": {"name": name, "description": format!("{name} does something"), "parameters": {"type": "object"}}}),
            execution: execution(if read_only { "not_blocked" } else { "not_blocked" }),
        }
    }

    fn catalogue() -> Catalogue {
        plan(vec![
            fact("sessions", true),
            fact("read", true),
            fact("remote", true),
            fact("subagent", false),
            fact("tool_call", false),
            fact("codemode", false),
            Fact { name: "operation".into(), description: "operation".into(), schema: json!({"type":"function","function":{"name":"operation","parameters":{"type":"object"}}}), execution: execution("blocked") },
        ])
        .expect("no collision")
    }

    #[test]
    fn the_fence_keeps_delegation_and_the_facades_out_and_names_their_route() {
        let catalogue = catalogue();
        assert!(catalogue.callable("sessions").is_some(), "a read tool is callable");
        assert!(catalogue.callable("subagent").is_none(), "delegation is fenced");
        assert!(catalogue.callable("operation").is_none(), "a blocked target is fenced by status");
        assert_eq!(catalogue.fenced("codemode").unwrap().route,
            "Direct call only: a script does not nest: a second sandbox inside the first would hide one effect stream behind another. End the script, then call codemode as an ordinary tool.");
        assert!(catalogue.fenced("tool_call").unwrap().route
            .starts_with("Direct call only: the outer facade pins definitions"));
        assert!(catalogue.fenced("operation").unwrap().route.starts_with("Not callable in this run: blocked"));
        assert_eq!(catalogue.fenced("tool_call").unwrap().route, route_of("tool_call", &execution("not_blocked")));
    }

    #[test]
    fn every_discoverable_name_is_listed_and_sorted() {
        let names = catalogue().names();
        assert_eq!(names, vec!["codemode", "operation", "read", "remote", "sessions", "subagent", "tool_call"]);
    }

    #[test]
    fn a_collision_of_guest_names_is_refused_not_guessed() {
        let mut facts = vec![fact("a-b", true), fact("a.b", true)];
        assert!(plan(facts.clone()).is_none(), "both spell a_b inside the guest");
        facts.pop();
        assert!(plan(facts).is_some());
    }

    #[test]
    fn the_listing_marks_the_fence_and_pages() {
        let (value, ok) = search_tools(&catalogue(), &json!(["*", {"limit": 3}]));
        assert!(ok);
        assert_eq!(value["matches"], 7);
        assert_eq!(value["has_more"], true);
        assert_eq!(value["tools"].as_array().unwrap().len(), 3);
        assert_eq!(value["tools"][0]["name"], "codemode");
        assert_eq!(value["tools"][0]["callable"], false);
        assert!(value["tools"][0]["route"].as_str().unwrap().contains("a script does not nest"));
        assert_eq!(value["tools"][2]["name"], "read");
        assert_eq!(value["tools"][2]["callable"], true);
    }

    #[test]
    fn a_batch_keeps_the_asked_order_and_suggests_a_correction_for_a_miss() {
        let (value, ok) = search_tools(&catalogue(), &json!([{"names": ["remote", "sesions"]}]));
        assert!(ok);
        assert_eq!(value["requested"], 2);
        assert_eq!(value["matches"], 1);
        assert_eq!(value["tools"][0]["name"], "remote");
        assert_eq!(value["missing"][0]["name"], "sesions");
        assert!(value["missing"][0]["suggestions"].as_array().unwrap().iter().any(|s| s == "sessions"));
        // The string spelling is the same request.
        let (select, ok) = search_tools(&catalogue(), &json!(["select:remote,sessions"]));
        assert!(ok);
        assert_eq!(select["tools"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn the_refusals_are_the_ones_the_model_knows() {
        let catalogue = catalogue();
        assert_eq!(search_tools(&catalogue, &json!([{"names": ["read"], "query": "read"}])).0["error"], "tool_search_arguments_exclusive");
        assert_eq!(search_tools(&catalogue, &json!([{"names": []}])).0["error"], "invalid_tool_search_names");
        assert_eq!(search_tools(&catalogue, &json!([{"names": ["a", "b", "c", "d", "e", "f", "g", "h", "i"]}])).0["error"], "invalid_tool_search_names");
        assert_eq!(search_tools(&catalogue, &json!(["*", {"limit": 201}])).0["error"], "invalid_tool_search_limit");
        assert_eq!(search_tools(&catalogue, &json!(["read", {"limit": 9}])).0["error"], "invalid_tool_search_limit");
        assert_eq!(search_tools(&catalogue, &json!([42])).0["error"], "tool_search_query_required");
    }

    #[test]
    fn a_keyword_search_ranks_a_name_hit_above_a_description_hit() {
        let (value, ok) = search_tools(&catalogue(), &json!(["session"]));
        assert!(ok);
        assert_eq!(value["tools"][0]["name"], "sessions");
        assert_eq!(value["matches"], 1);
        assert_eq!(value["tools"][0]["callable"], true);
    }

    #[test]
    fn describe_gives_a_schema_and_an_outside_route_and_showcall_is_the_nodes() {
        let catalogue = catalogue();
        let described = describe_tool(&catalogue, &json!(["remote"])).unwrap();
        assert_eq!(described["callable"], true);
        assert!(described["parameters"]["type"] == "object");
        let outside = describe_tool(&catalogue, &json!(["subagent"])).unwrap();
        assert_eq!(outside["callable"], false);
        assert!(outside["route"].as_str().unwrap()
            .starts_with("Direct call only: delegation spends model calls"));
        assert!(describe_tool(&catalogue, &json!("showCall")).is_none(), "presentation is the loop's");
        assert!(describe_tool(&catalogue, &json!(["nope"])).is_none(),
            "an unknown name is the node's answer (`unknown_tool` with suggestions), as it is natively");
    }

    #[test]
    fn a_call_is_interpreted_as_dispatch_a_refusal_or_a_host_global() {
        let catalogue = catalogue();
        match interpret(&catalogue, "tool", "read", Some("{}")) {
            Guest::Tool(call) => assert!(matches!(call.admittance, ToolAdmittance::Dispatch)),
            other => panic!("read is dispatchable: {other:?}"),
        }
        match interpret(&catalogue, "tool", "subagent", None) {
            Guest::Tool(call) => match call.admittance {
                ToolAdmittance::Fenced(Some(route)) => {
                    assert!(route.starts_with("Direct call only: delegation"), "the fence says where it runs: {route}")
                }
                other => panic!("subagent is fenced: {other:?}"),
            },
            other => panic!("subagent is a tool call: {other:?}"),
        }
        match interpret(&catalogue, "tool", "nope", None) {
            Guest::Tool(call) => match call.admittance {
                ToolAdmittance::Fenced(None) => {}
                other => panic!("an unknown name has no route: {other:?}"),
            },
            other => panic!("unknown is a tool call: {other:?}"),
        }
        assert!(matches!(interpret(&catalogue, "global", "showCall", None), Guest::Host));
        assert!(matches!(interpret(&catalogue, "global", "describeTool", Some("[\"showCall\"]")), Guest::Host));
        match interpret(&catalogue, "global", "searchTools", Some("[\"*\"]")) {
            Guest::Answered(value, ok) => {
                assert!(ok);
                assert_eq!(value["matches"], 7);
            }
            other => panic!("searchTools is answered here: {other:?}"),
        }
        match interpret(&catalogue, "global", "nope", None) {
            Guest::Answered(value, ok) => {
                assert!(!ok);
                assert_eq!(value["error"], "codemode_global_not_available");
            }
            other => panic!("an unknown global is refused: {other:?}"),
        }
    }

    #[test]
    fn a_call_with_no_arguments_is_an_empty_argument_list() {
        assert_eq!(parse_params(None), json!([]));
        assert_eq!(parse_params(Some("undefined")), json!([]));
        assert_eq!(parse_params(Some("")), json!([]));
        assert_eq!(parse_params(Some("[{\"limit\":1}]")), json!([{"limit": 1}]));
    }
}
