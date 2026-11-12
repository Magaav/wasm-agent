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
    // `mcp_whatsapp_send` is deliberately absent: it is callable inside a script, its send form is an
    // effect the dispatcher runs one at a time and its resume form ({id}/{ids}) only waits on a job and
    // is a read (`lua/core/whatsapp.lua`, `M.effect`).
    "email_send",
];

/// The guest globals that come from the node rather than from this seam: the retained evidence behind
/// `showCall`, and the live capability registry behind `capabilities()`/`describe()`.
pub const HOST_GLOBALS: &[&str] = &[
    "showCall",
    "capabilities",
    "describe",
    "results",
    // A call that outlives its wait answers `{state:"pending", op}` and these two are how a script
    // resumes or stops it (`lua/core/codemode_pending.lua`). They are the loop's to answer: the work
    // is a managed operation, which this seam neither runs nor reads.
    "wait",
    "cancel",
];

/// The guest globals this seam answers, with the prelude's `spread` flag.
///
/// The list is the native loop's, name for name and flag for flag (`lua/core/codemode.lua`: `searchTools`
/// spread, then `describeTool`, `showCall`, `capabilities`, `describe`). A shorter list here means a
/// script that calls `capabilities()` runs natively and fails with `ReferenceError: capabilities is not
/// defined` through the component - the parity suite compared the two and said so.
pub const GUEST_GLOBALS: &[(&str, bool)] = &[
    ("searchTools", true),
    ("results", true),
    // Spread, so `wait(op, {wait_s:120})` reaches the loop with both arguments.
    ("wait", true),
    ("cancel", true),
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

/// One of the guest's own names (`searchTools`, `results`, `showCall`) as a discovery entry. The entry
/// itself is the loop's
/// (`lua/core/codemode.lua`, `builtin_entries`), copied verbatim: its help text is model-facing prose
/// that lives in the node, and a second rendering here is a second answer to one question.
#[derive(Clone, Debug)]
pub struct Builtin {
    pub name: String,
    pub description: String,
    pub execution: Execution,
    pub entry: Value,
}

/// What one script's catalogue is: the callable set, the fenced set (what discovery still shows and the
/// guest's table still carries, answering with its route), and the order the node sent them in.
/// `None` from [`plan`] is the identifier collision the loop refuses.
#[derive(Clone, Debug, Default)]
pub struct Catalogue {
    pub tools: Vec<Tool>,
    pub outside: Vec<Outside>,
    /// The guest's own names, as entries the loop composed. Not tools: nothing here is dispatchable.
    pub builtins: Vec<Builtin>,
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

    /// One of the guest's own names (`searchTools`, `results`, `showCall`).
    pub fn builtin(&self, name: &str) -> Option<&Builtin> {
        self.builtins.iter().find(|builtin| builtin.name == name)
    }

    /// Every name discovery can mention, sorted: the listing's order and the pool suggestions draw from.
    /// The guest's own names are part of that catalogue, so one list answers every form.
    pub fn names(&self) -> Vec<String> {
        let mut names: Vec<String> = self.tools.iter().map(|tool| tool.name.clone()).collect();
        names.extend(self.outside.iter().map(|tool| tool.name.clone()));
        names.extend(self.builtins.iter().map(|builtin| builtin.name.clone()));
        names.sort();
        names
    }
}

/// The spelling a tool has inside the guest: everything that is not a word character becomes `_`.
pub fn js_name(name: &str) -> String {
    name.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' }).collect()
}

/// The reasons a tool is direct-only, sentence for sentence from `DIRECT_ONLY` in
/// `lua/core/codemode.lua`. The fence's sentence is part of what the model reads, and the parity suite
/// compares the two loops field for field: a second wording here is a divergence, not a variation (the
/// suite caught exactly that once it stopped skipping this comparison - `subagent` read
/// "Control plane: call subagent as an ordinary tool..." on this side and "Direct call only: ..." on
/// the other).
///
/// The fence itself is [`FORBIDDEN`]; this table is the sentence a refusal carries, and it is copied
/// character for character because discovery's answer is compared field for field across the seam
/// (`scripts/test-codemode-component.lua`): a reworded sentence here is a different fact on the two
/// paths, and the model reads whichever path ran. The keys are exactly `codemode.DIRECT_ONLY`'s, which
/// `scripts/test-codemode-parity.lua` asserts on the node's side and the fence test below asserts on
/// this one. The sentences exist once: `direct_only_reason` is a lookup in this table.
pub const DIRECT_ONLY: &[(&str, &str)] = &[
    ("codemode", "a script does not nest: a second sandbox inside the first would hide one effect stream behind another"),
    ("tool_call", "the outer facade pins definitions into this session's loadout; a script calls await tools.<name>(args) directly instead"),
    ("tool_search", "the outer facade pins definitions into this session's loadout; searchTools/describeTool answer the same question inside without changing it"),
    ("subagent", "delegation spends model calls and creates a child session: one reviewable call, never a step inside a script"),
    ("integrate", "landing a worker tip is a single receipted integration action, never a script step"),
    ("session_worktree", "it allocates and owns this session's worktree; a bound root that re-points mid-script would change what every later call means"),
    ("resume_session", "it folds another session into the conversation the script is already running in"),
    ("session_debug", "it sets this session's recording mode: changing what is recorded mid-script makes the script its own unrecorded effect"),
    ("session_fixture", "it exports this session as a fixture while the script is still writing that session"),
    ("wave_autoflush", "it installs a durable wave-end obligation for the coordinator; installation is a direct receipted action"),
    ("node_update", "it updates and restarts a node: a deployment, not a script step"),
    ("email_send", "an outbound message is one operator-gated effect with a durable message id and a documented status; it stays a direct call"),
];

/// One direct-call-only tool's reason, looked up in [`DIRECT_ONLY`] so the sentence has one copy on
/// this side of the seam.
pub fn direct_only_reason(name: &str) -> Option<&'static str> {
    DIRECT_ONLY.iter().find(|(tool, _)| *tool == name).map(|(_, reason)| *reason)
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
/// and the keyword form, in that order — exactly the branches the native loop takes, and every one of
/// them answers a plain ARRAY, so `.map` works on whatever a script asked for.
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
    let names = catalogue.names();

    if let Some(wanted) = wanted {
        if options.get("limit").is_some() && !bounded(&limit, 1, 8) {
            return (json!({"error": "invalid_tool_search_limit"}), false);
        }
        // One shape for every spelling: a plain ARRAY in the order asked for, with an unknown name a
        // member of it rather than a second envelope. `searchTools({names:[…]}).map(…)` answered "not a
        // function" on the old `{tools,missing,requested}` object (11/11); the shape is documented in
        // the same place the native loop documents it (`searchTools("select:searchTools")`).
        let mut tools = Vec::new();
        for name in &wanted {
            tools.push(select_one(catalogue, name).unwrap_or_else(|| unknown(name, &names)));
        }
        return (Value::Array(tools), true);
    }

    if listing {
        if !bounded(&limit, 1, 200) || !integer(&offset, 0) {
            return (json!({"error": "invalid_tool_search_limit"}), false);
        }
        let limit = limit.as_f64().unwrap_or(50.0) as usize;
        let offset = offset.as_f64().unwrap_or(0.0) as usize;
        let mut page = Vec::new();
        for name in names.iter().take(names.len().min(offset.saturating_add(limit))).skip(offset) {
            if let Some(tool) = catalogue.callable(name) {
                page.push(listing_row(&tool.name, &schema_description(&tool.schema), &tool.execution, None));
            } else if let Some(outside) = catalogue.fenced(name) {
                page.push(listing_row(&outside.name, &schema_description(&outside.schema), &outside.execution, Some(&outside.route)));
            } else if let Some(builtin) = catalogue.builtin(name) {
                page.push(listing_row(&builtin.name, &builtin.description, &builtin.execution, None));
            }
        }
        return (Value::Array(page), true);
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
    let score = |text: &str| terms.iter().filter(|term| text.contains(term.as_str())).count() as u32;
    let mut matches: Vec<(u32, String, Value)> = Vec::new();
    for name in &names {
        // The catalogue's entry, the fenced entry, or the loop's own: one object per name, however it
        // was found.
        let Some(value) = select_one(catalogue, name) else { continue };
        let hay = format!("{name} {}", value.get("description").and_then(Value::as_str).unwrap_or_default()).to_lowercase();
        let hit = score(&hay);
        if hit > 0 {
            matches.push((hit, name.clone(), value));
        }
    }
    matches.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    let found: Vec<Value> = matches.into_iter().take(limit.as_f64().unwrap_or(8.0) as usize).map(|(_, _, value)| value).collect();
    (Value::Array(found), true)
}

/// One name, one object: what the batch answers for it and what the compatibility alias
/// `describeTool(name)` answers — `{name, description, parameters, schema, execution, callable, route}`
/// for a catalogue name, the loop's own entry for a built-in, and `found:false` for a name this script
/// cannot see. `None` only when the built-ins were not handed over (an old host): the loop then owns the
/// answer, exactly as it did before they travelled.
pub fn select_one(catalogue: &Catalogue, name: &str) -> Option<Value> {
    if let Some(tool) = catalogue.callable(name) {
        return Some(entry(&tool.name, &tool.schema, &tool.execution, None));
    }
    if let Some(outside) = catalogue.fenced(name) {
        // `execution` is the node's pre-flight status, and the native loop's `describeTool` answers it
        // for a fenced tool as well as a callable one. Leaving it out here made the two loops answer
        // different bytes for the same question - caught by the parity suite the moment it stopped
        // skipping this comparison. #120 said the same thing in the assertion that reads it
        // (`outside["execution"]["status"]`), so the two intents are this one field.
        return Some(entry(&outside.name, &outside.schema, &outside.execution, Some(&outside.route)));
    }
    if let Some(builtin) = catalogue.builtin(name) {
        return Some(builtin.entry.clone());
    }
    if catalogue.builtins.is_empty() {
        return None;
    }
    Some(unknown(name, &catalogue.names()))
}

/// A miss: a member of the same array that says so — `found:false`, the reason, and the nearest
/// permitted names — never a throw and never a second envelope.
fn unknown(name: &str, available: &[String]) -> Value {
    let echo = echo_name(name);
    json!({
        "name": echo,
        "found": false,
        "missing": true,
        "error": "unknown_tool",
        "reason": format!("no name like '{echo}' in this script's catalogue"),
        "suggestions": nearest(&echo, available, 3),
    })
}

/// `describeTool(name)`: the hidden compatibility alias of `searchTools("select:"..name)[0]`, the same
/// object the batch answers. No argument is the `showCall` entry, which is the presentation help it has
/// always returned. No catalogue or guidance list offers this name any more.
pub fn describe_tool(catalogue: &Catalogue, params: &Value) -> Option<Value> {
    let name = match params {
        Value::String(text) => text.clone(),
        Value::Array(items) => match items.first() {
            Some(Value::String(text)) => text.clone(),
            None => "showCall".to_string(),
            _ => return None,
        },
        _ => return None,
    };
    select_one(catalogue, &name)
}

// ----------------------------------------------------------------------------------- small pieces

/// One name, one object — the batch's element, the keyword hit and the listing's source: `{name,
/// description, parameters, schema, execution, callable, route}`. The native loop's `entry` has these
/// fields and no others (`lua/core/codemode.lua`, `tool_lookup.entry`), because a script may `.map` any
/// form and read the same keys.
fn entry(name: &str, schema: &Value, execution: &Execution, route: Option<&str>) -> Value {
    let mut out = Map::new();
    out.insert("name".into(), json!(name));
    out.insert("description".into(), json!(schema_description(schema)));
    if let Some(parameters) = schema.get("function").and_then(|f| f.get("parameters")) {
        out.insert("parameters".into(), parameters.clone());
    }
    out.insert("schema".into(), schema.clone());
    out.insert("execution".into(), execution.json());
    out.insert("callable".into(), json!(route.is_none()));
    if let Some(route) = route {
        out.insert("route".into(), json!(route));
    }
    Value::Object(out)
}

/// One listing row (`searchTools("*")`): the name, its first description line and the node's pre-flight
/// status — no schema, so a page of 200 stays cheap. The built-ins' rows are composed from the loop's
/// entry the same way.
fn listing_row(name: &str, description: &str, execution: &Execution, route: Option<&str>) -> Value {
    let mut out = Map::new();
    out.insert("name".into(), json!(name));
    out.insert("description".into(), json!(first_line(description)));
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

    /// The guest's own names, exactly as the loop hands them over (`lua/core/codemode.lua`,
    /// `builtin_entries`): the entry is the loop's bytes, reproduced here without the prose.
    fn builtin(name: &str) -> Builtin {
        let live = Execution { status: "available".into(), scope: "codemode".into(), binding: "none".into(), ..Execution::default() };
        Builtin {
            name: name.to_string(),
            description: format!("{name} is the guest's own"),
            entry: json!({
                "name": name,
                "description": format!("{name} is the guest's own"),
                "schema": {"name": name, "description": format!("{name} is the guest's own")},
                "execution": {"status": "available", "scope": "codemode", "workspace_binding": "none"},
                "callable": true,
                "builtin": true,
            }),
            execution: live,
        }
    }

    fn catalogue_with_builtins() -> Catalogue {
        let mut catalogue = catalogue();
        catalogue.builtins = vec![builtin("searchTools"), builtin("results"), builtin("showCall")];
        catalogue
    }

    #[test]
    fn the_fence_keeps_delegation_and_the_facades_out_and_names_their_route() {
        let catalogue = catalogue();
        assert!(catalogue.callable("sessions").is_some(), "a read tool is callable");
        assert!(catalogue.callable("subagent").is_none(), "delegation is fenced");
        assert!(catalogue.callable("operation").is_none(), "a blocked target is fenced by status");
        // The fence sentence is the loop's own (`lua/core/codemode.lua` DIRECT_ONLY), word for word, and
        // the sentence table names exactly the tools the fence refuses.
        assert_eq!(catalogue.fenced("codemode").unwrap().route,
            "Direct call only: a script does not nest: a second sandbox inside the first would hide one effect stream behind another. End the script, then call codemode as an ordinary tool.");
        assert!(catalogue.fenced("tool_call").unwrap().route
            .starts_with("Direct call only: the outer facade pins definitions"));
        let mut sentences: Vec<&str> = DIRECT_ONLY.iter().map(|(name, _)| *name).collect();
        let mut fence: Vec<&str> = FORBIDDEN.to_vec();
        sentences.sort();
        fence.sort();
        assert_eq!(sentences, fence, "the sentence table and the fence name the same tools");
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
        let page = value.as_array().expect("the listing is a plain array, not an envelope");
        assert_eq!(page.len(), 3);
        assert_eq!(page[0]["name"], "codemode");
        assert_eq!(page[0]["callable"], false);
        assert!(page[0]["route"].as_str().unwrap().contains("a script does not nest"), "the fence sentence is the loop's own: {page:?}");
        assert_eq!(page[2]["name"], "read");
        assert_eq!(page[2]["callable"], true);
        // The page is a window on the whole catalogue, not the whole of it: all seven names are listed.
        let (everything, listed) = search_tools(&catalogue(), &json!(["*", {"limit": 200}]));
        assert!(listed);
        assert_eq!(everything.as_array().unwrap().len(), 7);
        assert_eq!(everything.as_array().unwrap().len(), catalogue().names().len());
    }

    #[test]
    fn a_batch_keeps_the_asked_order_and_suggests_a_correction_for_a_miss() {
        let (value, ok) = search_tools(&catalogue(), &json!([{"names": ["remote", "sesions"]}]));
        assert!(ok);
        let rows = value.as_array().expect("a batch is a plain array too");
        assert_eq!(rows.len(), 2, "the miss is a member of the same array: {value}");
        assert_eq!(rows[0]["name"], "remote");
        assert_eq!(rows[1]["name"], "sesions");
        assert_eq!(rows[1]["missing"], true);
        assert!(rows[1]["suggestions"].as_array().unwrap().iter().any(|s| s == "sessions"));
        // The string spelling is the same request.
        let (select, ok) = search_tools(&catalogue(), &json!(["select:remote,sessions"]));
        assert!(ok);
        assert_eq!(select.as_array().unwrap().len(), 2);
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
        let rows = value.as_array().expect("a keyword search is a plain array");
        assert_eq!(rows[0]["name"], "sessions");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["callable"], true);
    }

    #[test]
    fn describe_gives_a_schema_and_an_outside_route_and_showcall_is_the_nodes() {
        let catalogue = catalogue();
        let described = describe_tool(&catalogue, &json!(["remote"])).unwrap();
        assert_eq!(described["callable"], true);
        assert!(described["parameters"]["type"] == "object");
        let outside = describe_tool(&catalogue, &json!(["subagent"])).unwrap();
        assert_eq!(outside["callable"], false);
        assert!(outside["execution"]["status"].is_string(), "a fenced tool answers the node's pre-flight status, as natively: {outside}");
        assert!(outside["route"].as_str().unwrap().starts_with("Direct call only: delegation spends model calls"), "{}", outside["route"]);
        assert!(describe_tool(&catalogue, &json!("showCall")).is_none(), "presentation is the loop's");
        assert!(describe_tool(&catalogue, &json!(["searchTools"])).is_none(), "searchTools' shape is the loop's one text");
        assert!(describe_tool(&catalogue, &json!(["results"])).is_none(), "results' shape is the loop's one text");
        assert!(describe_tool(&catalogue, &json!(["nope"])).is_none(),
            "an unknown name is the node's answer (`unknown_tool` with suggestions), as it is natively");
        assert!(describe_tool(&catalogue, &json!([42])).is_none(), "a non-string argument is the loop's answer too");
    }

    #[test]
    fn the_one_tool_answers_one_shape_and_the_alias_is_its_element_zero() {
        let catalogue = catalogue_with_builtins();
        // The listing is the whole catalogue, the guest's own names included, sorted.
        let (everything, ok) = search_tools(&catalogue, &json!(["*", {"limit": 200}]));
        assert!(ok);
        let names: Vec<&str> = everything.as_array().unwrap().iter().map(|row| row["name"].as_str().unwrap()).collect();
        assert_eq!(names, vec!["codemode", "operation", "read", "remote", "results", "searchTools", "sessions", "showCall", "subagent", "tool_call"]);
        let search = everything.as_array().unwrap().iter().find(|row| row["name"] == "searchTools").unwrap();
        assert_eq!(search["callable"], true, "a built-in is callable: it is a global, not a dispatched tool");
        assert!(search["schema"].is_null(), "a listing row carries no schema: {search}");
        // The batch answers the loop's entry for a built-in, byte for byte.
        let (selected, ok) = search_tools(&catalogue, &json!(["select:results,read"]));
        assert!(ok);
        let rows = selected.as_array().expect("a batch is a plain array");
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0], builtin("results").entry, "a built-in answers its own entry");
        assert_eq!(rows[1]["name"], "read");
        assert!(rows[1]["schema"]["function"]["name"] == "read", "a catalogue entry carries its full schema");
        assert_eq!(rows[1]["parameters"]["type"], "object", "and the parameters the alias has always answered");
        // A keyword hit reaches a built-in too, and is that same entry.
        let (keyword, ok) = search_tools(&catalogue, &json!(["showCall", {"limit": 8}]));
        assert!(ok);
        let hits = keyword.as_array().unwrap();
        assert!(hits.iter().any(|row| row["name"] == "showCall"), "a built-in is found by keyword: {keyword}");
        assert_eq!(hits.iter().find(|row| row["name"] == "showCall").unwrap(), &builtin("showCall").entry);
        // The hidden alias is element 0 of a one-name batch - same object, every kind of name.
        for name in ["read", "session_worktree", "subagent", "searchTools", "results"] {
            let (batch, ok) = search_tools(&catalogue, &json!([{"names": [name]}]));
            assert!(ok);
            let alias = describe_tool(&catalogue, &json!([name])).expect("the alias answers what the batch answers");
            assert_eq!(alias, batch.as_array().unwrap()[0], "describeTool({name}) is select:{name}[0]");
        }
        // No argument is the presentation help it has always answered.
        assert_eq!(describe_tool(&catalogue, &json!([])), Some(builtin("showCall").entry));
    }

    #[test]
    fn an_unknown_name_is_a_member_of_the_array_that_says_so() {
        let catalogue = catalogue_with_builtins();
        let (value, ok) = search_tools(&catalogue, &json!([{"names": ["searchtools_"]}]));
        assert!(ok, "an unknown name never fails the call");
        let rows = value.as_array().expect(".map always works");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["found"], false);
        assert_eq!(rows[0]["missing"], true, "the old marker stays, so an older script keeps reading it");
        assert_eq!(rows[0]["error"], "unknown_tool");
        assert!(rows[0]["reason"].as_str().unwrap().contains("searchtools_"), "the entry says why: {value}");
        assert!(rows[0]["suggestions"].as_array().unwrap().iter().any(|name| name == "searchTools"),
            "a built-in is a permitted name for the correction: {value}");
        assert_eq!(describe_tool(&catalogue, &json!(["searchtools_"])), Some(rows[0].clone()),
            "the alias answers the same member, never a throw");
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
                assert_eq!(value.as_array().map(|rows| rows.len()), Some(7));
            }
            other => panic!("searchTools is answered here: {other:?}"),
        }
        assert!(matches!(interpret(&catalogue, "global", "results", Some("[{\"op\":\"last\"}]")), Guest::Host), "the retained results belong to the node");
        // A pending call's handle is resumed and stopped by the node, never by this seam: the work is a
        // managed operation, which a component neither runs nor reads (`lua/core/codemode_pending.lua`).
        assert!(matches!(interpret(&catalogue, "global", "wait", Some("[\"op-1\",{\"wait_s\":5}]")), Guest::Host),
            "wait is answered by the loop");
        assert!(matches!(interpret(&catalogue, "global", "cancel", Some("[\"op-1\"]")), Guest::Host),
            "cancel is answered by the loop");
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
