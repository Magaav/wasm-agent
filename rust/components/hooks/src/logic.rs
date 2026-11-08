//! The pure half of the hooks engine, ported from `lua/core/hooks.lua` (the native path keeps that
//! code untouched): config sources → normalized entries, the matcher, one hook's answer → the
//! accumulated decision, and rows → the footer's segment.
//!
//! It is deliberately the *same* algorithm, not a cleaner one: the parity suite
//! (`scripts/test-hooks-component.lua`) sends the same calls through both paths and compares the
//! decisions field for field, so a difference here is a difference an operator would see as "the
//! component changed my hooks". Where the native code depends on a Lua quirk the quirk is copied and
//! named, because the quirk is the contract:
//!
//! * a matcher is a **Lua pattern**, not a regex: `bash|shell` is a literal `bash|shell` (there is no
//!   alternation in Lua patterns), and `%b`/`%f` are not implemented here at all;
//! * `#value` is bytes, so a clip counts bytes and appends `…` — here the cut backs off to a character
//!   boundary, the one deliberate difference (a byte slice that is not UTF-8 cannot cross the seam);
//! * a `decision:"block"` answer keeps being read after it blocks (the native loop falls through to
//!   `additionalContext`, `reschedule_seconds` and the StatusLine segment).
//!
//! Nothing here touches a file, a process, a clock or a store: the node reads the config and runs the
//! hooks, and this module answers what is configured and what an answer means.
use crate::wa::hooks::types::{
    Bounds, CommandEntry, ConfigFacts, ConfigRequest, Decision, DecisionError, EntriesRequest, Entry,
    EventEntries, EventFacts, Keybinding, Row, SegmentRequest, Source, SourceFact, Step,
};
use serde_json::{Map, Value};

pub const VERSION: u32 = 1;
pub const DEFAULT_TIMEOUT_MS: f64 = 5000.0;
pub const MAX_TIMEOUT_MS: f64 = 60000.0;
pub const MAX_STDOUT_BYTES: usize = 8192;
pub const MAX_STDERR_BYTES: usize = 2048;
pub const MAX_CONTEXT_BYTES: usize = 4000;
pub const MAX_SYSTEM_MESSAGES: usize = 4;
pub const MAX_SYSTEM_MESSAGE_BYTES: usize = 500;
pub const MAX_STOP_CONTINUES: u32 = 3;
pub const STATUSLINE_TTL_MS: u32 = 10000;
pub const STATUSLINE_TIMEOUT_MS: f64 = 5000.0;
pub const STATUSLINE_MAX: usize = 160;
pub const LAST_KEPT: u32 = 40;

pub fn bounds() -> Bounds {
    Bounds {
        version: VERSION,
        default_timeout_ms: DEFAULT_TIMEOUT_MS as u32,
        max_timeout_ms: MAX_TIMEOUT_MS as u32,
        max_stdout_bytes: MAX_STDOUT_BYTES as u32,
        max_stderr_bytes: MAX_STDERR_BYTES as u32,
        max_context_bytes: MAX_CONTEXT_BYTES as u32,
        max_system_messages: MAX_SYSTEM_MESSAGES as u32,
        max_system_message_bytes: MAX_SYSTEM_MESSAGE_BYTES as u32,
        max_stop_continues: MAX_STOP_CONTINUES,
        statusline_ttl_ms: STATUSLINE_TTL_MS,
        statusline_timeout_ms: STATUSLINE_TIMEOUT_MS as u32,
        statusline_max: STATUSLINE_MAX as u32,
        last_kept: LAST_KEPT,
    }
}

// ------------------------------------------------------------------------------- the catalogue

fn event(name: &str, matcher: bool, may: &[&str], when: &str, fields: &[&str]) -> EventFacts {
    EventFacts {
        name: name.to_string(),
        matcher,
        may: may.iter().map(|item| item.to_string()).collect(),
        when: when.to_string(),
        fields: fields.iter().map(|item| item.to_string()).collect(),
    }
}

/// The one list of hook points (`M.EVENTS`), in the documented order. `/hooks`, the docs and the
/// tests read it, so an event cannot exist here without saying what it is for.
pub fn catalogue() -> Vec<EventFacts> {
    vec![
        event(
            "SessionStart",
            false,
            &["context", "systemMessage"],
            "a session begins a run (new, resumed or replayed) and before the first model request",
            &["session_id", "run_id", "cwd", "source", "resume"],
        ),
        event(
            "UserPromptSubmit",
            false,
            &["block", "context", "systemMessage"],
            "the user message is recorded, before the context is built for the first request",
            &["session_id", "run_id", "prompt", "prompt_len", "cwd"],
        ),
        event(
            "PreToolUse",
            true,
            &["allow", "deny", "ask", "updatedInput", "context", "systemMessage"],
            "after the arguments are decoded, before the tool runs",
            &["session_id", "run_id", "tool_name", "tool_input", "cwd", "role"],
        ),
        event(
            "PostToolUse",
            true,
            &["context", "systemMessage"],
            "after a tool returned, before its result is recorded",
            &["session_id", "run_id", "tool_name", "tool_input", "tool_response", "ok", "cwd"],
        ),
        event(
            "PostToolUseFailure",
            true,
            &["context", "systemMessage"],
            "after a tool answered with an error or raised, before the failure is recorded",
            &["session_id", "run_id", "tool_name", "tool_input", "error", "cwd"],
        ),
        event(
            "PreCompact",
            false,
            &["block", "systemMessage"],
            "a compaction is about to rewrite the transcript prefix",
            &["session_id", "run_id", "tokens_before", "limit", "keep", "trigger", "reason", "cwd"],
        ),
        event(
            "PostCompact",
            false,
            &["context", "systemMessage"],
            "a compaction landed: the prefix was rewritten and the summary recorded",
            &["session_id", "run_id", "tokens_before", "tokens_after", "through", "trigger", "cwd"],
        ),
        event(
            "Stop",
            false,
            &["continue", "stop", "context", "systemMessage"],
            "a completed no-tool candidate is identified as the answer and before it is committed",
            &["session_id", "run_id", "message_id", "text_len", "stop_hook_active", "cwd"],
        ),
        event(
            "SubagentStart",
            true,
            &["context", "systemMessage"],
            "a child run is admitted and before its first model request",
            &["session_id", "run_id", "subagent_id", "profile", "parent_session_id", "prompt_len", "cwd"],
        ),
        event(
            "SubagentStop",
            true,
            &["context", "systemMessage"],
            "a child run settled (completed, failed, cancelled or unknown)",
            &["session_id", "run_id", "subagent_id", "profile", "state", "cwd"],
        ),
        event(
            "Notification",
            false,
            &["context", "systemMessage"],
            "the node has a fact for the reader that is not the answer (a notice, a warning)",
            &["session_id", "run_id", "kind", "text_len", "cwd"],
        ),
        event(
            "SelfWake",
            false,
            &["block", "reschedule", "systemMessage"],
            "a due self-wake is claimed and before its turn runs",
            &["session_id", "run_id", "wake_id", "reason", "due_at", "attempts", "cwd"],
        ),
        event(
            "PreDeploy",
            false,
            &["block", "systemMessage"],
            "a deploy request is about to be written for the sentinel",
            &["session_id", "run_id", "commit", "reason", "cwd"],
        ),
        event(
            "PostDeploy",
            false,
            &["context", "systemMessage"],
            "the sentinel accepted a deploy request (queued, not installed)",
            &["session_id", "run_id", "request", "commit", "cwd"],
        ),
        event(
            "ComponentInstall",
            true,
            &["block", "systemMessage"],
            "a component definition is about to be installed, enabled or upgraded",
            &["session_id", "run_id", "component", "action", "artifact", "cwd"],
        ),
        event(
            "ComponentSwap",
            true,
            &["context", "systemMessage"],
            "a component upgrade switched to the new instance",
            &["session_id", "run_id", "component", "state", "cwd"],
        ),
        event(
            "StatusLine",
            false,
            &["text"],
            "the CLI renders its footer (a mod, not a hook: its stdout is the segment)",
            &["session_id", "model", "cwd", "runs", "tokens"],
        ),
    ]
}

pub fn event_matcher(name: &str) -> bool {
    catalogue().into_iter().find(|event| event.name == name).map(|event| event.matcher).unwrap_or(false)
}

// --------------------------------------------------------------------------------- small helpers

/// `tostring` for the values a config can carry: a JSON string is itself, a number is its own text
/// (`5` is `5`, `5.0` is `5.0`), a boolean is `true`/`false`.
fn lua_tostring(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Number(number) => number.to_string(),
        Value::Bool(flag) => flag.to_string(),
        Value::Null => "nil".to_string(),
        other => other.to_string(),
    }
}

/// `tonumber`: a number, or a string that parses as one (Lua's `tonumber('3000')` is `3000`).
fn tonumber(value: &Value) -> Option<f64> {
    match value {
        Value::Number(number) => number.as_f64(),
        Value::String(text) => text.trim().parse::<f64>().ok(),
        _ => None,
    }
}

fn get_number(object: &Map<String, Value>, key: &str) -> Option<f64> {
    object.get(key).and_then(tonumber)
}

/// `value:sub(1, limit) .. '…'`, on characters: a cut that would split one is moved back instead of
/// producing bytes that are not text.
pub fn clip(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_string();
    }
    let mut end = limit;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    let mut out = text[..end].to_string();
    out.push('…');
    out
}

/// One line, trimmed: `(value:gsub('[\r\n]+', ' '):gsub('^%s+',''):gsub('%s+$',''))`.
pub fn one_line(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut previous_break = false;
    for ch in text.chars() {
        if ch == '\r' || ch == '\n' {
            if !previous_break {
                out.push(' ');
            }
            previous_break = true;
            continue;
        }
        previous_break = false;
        out.push(ch);
    }
    out.trim_matches(is_lua_space).to_string()
}

fn is_lua_space(ch: char) -> bool {
    matches!(ch, ' ' | '\t' | '\n' | '\r' | '\u{0b}' | '\u{0c}')
}

fn text_of(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// A JSON *object* or nothing: the native `decode_object` accepts a Lua table, and an array is a
/// table, so an array answer is an empty object.
fn decode_object(bytes: &[u8]) -> Option<Map<String, Value>> {
    if bytes.is_empty() {
        return None;
    }
    match serde_json::from_slice::<Value>(bytes) {
        Ok(Value::Object(object)) => Some(object),
        Ok(Value::Array(_)) => Some(Map::new()),
        _ => None,
    }
}

// ----------------------------------------------------------------------------------- the matcher

fn is_pattern(matcher: &str) -> bool {
    matcher.chars().any(|ch| "^$()%.[]*+-?".contains(ch))
}

/// `M.matches`: a Lua pattern against the lowered name, or — for a plain word — a case-insensitive
/// substring.
pub fn matches(matcher: Option<&str>, name: &str) -> bool {
    let Some(matcher) = matcher else { return true };
    if matcher.is_empty() || matcher == "*" || matcher == ".*" {
        return true;
    }
    if matcher == name {
        return true;
    }
    let lowered = matcher.to_lowercase();
    let name = name.to_lowercase();
    if !is_pattern(&lowered) {
        return name.contains(&lowered);
    }
    lua_find(&name, &lowered)
}

#[derive(Clone, Copy, PartialEq)]
enum Class {
    Any,
    /// A `%a`-style class; `negated` for the upper-case spelling.
    Kind { letter: char, negated: bool },
    Literal(char),
    Set,
}

struct Set {
    negated: bool,
    items: Vec<(char, char)>,
    classes: Vec<(char, bool)>,
}

impl Set {
    fn contains(&self, ch: char) -> bool {
        let mut hit = self.items.iter().any(|(low, high)| ch >= *low && ch <= *high);
        if !hit {
            hit = self.classes.iter().any(|(letter, negated)| class_matches(*letter, *negated, ch));
        }
        if self.negated {
            !hit
        } else {
            hit
        }
    }
}

fn class_matches(letter: char, negated: bool, ch: char) -> bool {
    let hit = match letter {
        'a' => ch.is_alphabetic(),
        'c' => ch.is_control(),
        'd' => ch.is_ascii_digit(),
        'g' => ch.is_ascii_graphic() || ch == ' ',
        'l' => ch.is_lowercase(),
        'p' => ch.is_ascii_punctuation(),
        's' => is_lua_space(ch),
        'u' => ch.is_uppercase(),
        'w' => ch.is_alphanumeric(),
        'x' => ch.is_ascii_hexdigit(),
        _ => false,
    };
    if negated {
        !hit
    } else {
        hit
    }
}

/// Parse one pattern item at `at`: the class and the index just past it.
fn class_at(pattern: &[char], at: usize) -> Option<(Class, usize)> {
    let ch = *pattern.get(at)?;
    match ch {
        '%' => {
            let letter = *pattern.get(at + 1)?;
            if letter.is_ascii_uppercase() {
                Some((Class::Kind { letter: letter.to_ascii_lowercase(), negated: true }, at + 2))
            } else {
                Some((Class::Kind { letter, negated: false }, at + 2))
            }
        }
        '.' => Some((Class::Any, at + 1)),
        '[' => {
            // The set's own bounds are re-read by `set_at`; here only the end index is needed.
            let mut index = at + 1;
            if pattern.get(index) == Some(&'^') {
                index += 1;
            }
            let mut first = true;
            loop {
                let current = *pattern.get(index)?;
                if current == ']' && !first {
                    return Some((Class::Set, index + 1));
                }
                first = false;
                if current == '%' {
                    index += 2;
                    continue;
                }
                if pattern.get(index + 1) == Some(&'-') && pattern.get(index + 2).is_some_and(|c| *c != ']') {
                    index += 3;
                    continue;
                }
                index += 1;
            }
        }
        other => Some((Class::Literal(other), at + 1)),
    }
}

fn item_matches(class: Class, pattern: &[char], start: usize, ch: char) -> bool {
    match class {
        Class::Any => true,
        Class::Kind { letter, negated } => class_matches(letter, negated, ch),
        Class::Literal(literal) => literal == ch,
        Class::Set => set_at(pattern, start).map(|set| set.contains(ch)).unwrap_or(false),
    }
}

/// Re-read the set that starts at `start` (a `[`).
fn set_at(pattern: &[char], start: usize) -> Option<Set> {
    if pattern.get(start) != Some(&'[') {
        return None;
    }
    let mut index = start + 1;
    let negated = pattern.get(index) == Some(&'^');
    if negated {
        index += 1;
    }
    let mut set = Set { negated, items: Vec::new(), classes: Vec::new() };
    let mut first = true;
    loop {
        let current = *pattern.get(index)?;
        if current == ']' && !first {
            return Some(set);
        }
        first = false;
        if current == '%' {
            let letter = *pattern.get(index + 1)?;
            let (letter, inner_negated) = if letter.is_ascii_uppercase() {
                (letter.to_ascii_lowercase(), true)
            } else {
                (letter, false)
            };
            // `%%` is a literal percent, not a class.
            if letter == '%' {
                set.items.push(('%', '%'));
            } else {
                set.classes.push((letter, inner_negated));
            }
            index += 2;
            continue;
        }
        if pattern.get(index + 1) == Some(&'-') && pattern.get(index + 2).is_some_and(|c| *c != ']') {
            let high = *pattern.get(index + 2)?;
            set.items.push((current, high));
            index += 3;
            continue;
        }
        set.items.push((current, current));
        index += 1;
    }
}

/// Backtracking over a Lua pattern: `Some(end)` when `pattern[pi..]` matches a prefix of `chars[si..]`
/// (the tail is unanchored, as `string.find` is).
fn match_here(chars: &[char], si: usize, pattern: &[char], pi: usize) -> Option<usize> {
    if pi >= pattern.len() {
        return Some(si);
    }
    if pattern[pi] == '$' && pi + 1 == pattern.len() {
        return if si == chars.len() { Some(si) } else { None };
    }
    // A capture is grouping in a matcher: it changes nothing about what matches.
    if pattern[pi] == '(' {
        return match_here(chars, si, pattern, pi + 1);
    }
    if pattern[pi] == ')' {
        return match_here(chars, si, pattern, pi + 1);
    }
    let (class, next) = class_at(pattern, pi)?;
    let quantifier = pattern.get(next).copied();
    match quantifier {
        Some('*') | Some('+') | Some('?') | Some('-') => {
            let minimum = if quantifier == Some('+') { 1 } else { 0 };
            let greedy = quantifier != Some('-');
            // Count the run this item can consume.
            let mut run = 0;
            while si + run < chars.len() && item_matches(class, pattern, pi, chars[si + run]) {
                run += 1;
                if run > 1024 {
                    break;
                }
            }
            if run < minimum {
                return None;
            }
            let after = next + 1;
            if greedy {
                let mut take = run;
                loop {
                    if let Some(end) = match_here(chars, si + take, pattern, after) {
                        return Some(end);
                    }
                    if take == minimum {
                        return None;
                    }
                    take -= 1;
                }
            } else {
                let mut take = minimum;
                loop {
                    if let Some(end) = match_here(chars, si + take, pattern, after) {
                        return Some(end);
                    }
                    if take == run {
                        return None;
                    }
                    take += 1;
                }
            }
        }
        _ => {
            if si < chars.len() && item_matches(class, pattern, pi, chars[si]) {
                match_here(chars, si + 1, pattern, next)
            } else {
                None
            }
        }
    }
}

/// `string.find(name, pattern)` — the boolean, since a caller only asks whether it matched.
pub fn lua_find(name: &str, pattern: &str) -> bool {
    let chars: Vec<char> = name.chars().collect();
    let pattern: Vec<char> = pattern.chars().collect();
    if pattern.is_empty() {
        return true;
    }
    if pattern[0] == '^' {
        return match_here(&chars, 0, &pattern, 1).is_some();
    }
    for start in 0..=chars.len() {
        if match_here(&chars, start, &pattern, 0).is_some() {
            return true;
        }
    }
    false
}

// ------------------------------------------------------------------------------- config sources

fn error(errors: &mut Vec<String>, text: impl Into<String>) {
    errors.push(text.into());
}

fn timeout_of(hook: &Map<String, Value>, fallback: f64) -> f64 {
    let mut timeout = get_number(hook, "timeout_ms");
    if timeout.is_none() {
        // Claude Code counts timeouts in seconds, the native file in milliseconds.
        timeout = get_number(hook, "timeout").map(|seconds| (seconds * 1000.0).floor());
    }
    // The floor and the cap are the engine's, not the config's: a hook cannot grant itself more time,
    // and a 0 in the file is not "no timeout" (`docs/HOOKS.md`, "Safety").
    timeout.unwrap_or(fallback).clamp(100.0, MAX_TIMEOUT_MS)
}

#[allow(clippy::too_many_arguments)]
fn make_entry(
    event: &str,
    name: String,
    matcher: Option<String>,
    command: String,
    timeout_ms: f64,
    on_ask: String,
    origin: &str,
    path: &str,
    order: u32,
) -> Entry {
    Entry {
        name,
        event: event.to_string(),
        kind: "command".to_string(),
        matcher,
        command,
        timeout_ms,
        on_ask,
        origin: origin.to_string(),
        path: Some(path.to_string()),
        order,
    }
}

/// `normalize_entries`: both shapes, because both exist in the world — the native row and Claude
/// Code's `matcher` → `hooks[]` wrapper.
fn normalize_entries(
    event: &str,
    raw: &Value,
    origin: &str,
    path: &str,
    start: u32,
    errors: &mut Vec<String>,
) -> Vec<Entry> {
    let mut out = Vec::new();
    let list = match raw {
        Value::Array(list) => list,
        _ => {
            error(errors, format!("{origin}: {event} is not a list"));
            return out;
        }
    };
    for (position, item) in list.iter().enumerate() {
        let index = position + 1;
        let item = match item {
            Value::Object(object) => object,
            _ => {
                error(errors, format!("{origin}: {event}[{index}] is not an object"));
                continue;
            }
        };
        let matcher = item.get("matcher").map(lua_tostring);
        // Claude Code's shape wraps the hook in `{matcher, hooks:[…]}`; the native row is the hook.
        let inner: Vec<&Value> = match item.get("hooks") {
            Some(Value::Array(list)) => list.iter().collect(),
            _ => vec![&Value::Null],
        };
        for slot in inner {
            let hook = if slot.is_null() {
                item
            } else {
                match slot {
                    Value::Object(object) => object,
                    _ => {
                        error(errors, format!("{origin}: {event} hook is not an object"));
                        continue;
                    }
                }
            };
            let kind = hook.get("type").map(lua_tostring).unwrap_or_else(|| "command".to_string());
            let command = hook
                .get("command")
                .and_then(Value::as_str)
                .filter(|command| kind == "command" && !command.trim().is_empty());
            let Some(command) = command else {
                error(
                    errors,
                    format!("{origin}: {event} entry {index} has no command (only `command` hooks are configurable)"),
                );
                continue;
            };
            let name = hook
                .get("name")
                .map(lua_tostring)
                .or_else(|| item.get("name").map(lua_tostring))
                .unwrap_or_else(|| format!("{event}#{index}"));
            let on_ask = hook
                .get("on_ask")
                .map(lua_tostring)
                .or_else(|| item.get("on_ask").map(lua_tostring))
                .unwrap_or_else(|| "deny".to_string());
            let order = start + out.len() as u32 + 1;
            out.push(make_entry(
                event,
                name,
                matcher.clone(),
                command.to_string(),
                timeout_of(hook, DEFAULT_TIMEOUT_MS),
                on_ask,
                origin,
                path,
                order,
            ));
        }
    }
    out
}

fn normalize_commands(raw: &Value, origin: &str, errors: &mut Vec<String>) -> Vec<CommandEntry> {
    let mut out = Vec::new();
    let list = match raw {
        Value::Array(list) => list,
        Value::Null => return out,
        _ => {
            error(errors, format!("{origin}: mods.commands is not a list"));
            return out;
        }
    };
    for (position, item) in list.iter().enumerate() {
        let index = position + 1;
        let object = item.as_object();
        let name = object.and_then(|object| object.get("name")).map(lua_tostring).unwrap_or_default();
        if !name.starts_with('/') || name.chars().count() > 40 || name.chars().any(is_lua_space) {
            error(errors, format!("{origin}: mods.commands[{index}] needs a name like /hello"));
            continue;
        }
        let command = object
            .and_then(|object| object.get("command"))
            .and_then(Value::as_str)
            .filter(|command| !command.trim().is_empty());
        let Some(command) = command else {
            error(errors, format!("{origin}: {name} has no command"));
            continue;
        };
        out.push(CommandEntry {
            name,
            description: object
                .and_then(|object| object.get("description"))
                .map(lua_tostring)
                .unwrap_or_else(|| "custom command".to_string()),
            command: command.to_string(),
            timeout_ms: object.and_then(|object| get_number(object, "timeout_ms")).unwrap_or(DEFAULT_TIMEOUT_MS),
            origin: origin.to_string(),
        });
    }
    out
}

fn statusline_entries(mods: &Map<String, Value>, origin: &str) -> Vec<Entry> {
    let mut out = Vec::new();
    let Some(Value::Array(list)) = mods.get("statusline") else { return out };
    for item in list {
        let Some(object) = item.as_object() else { continue };
        let Some(command) = object.get("command").and_then(Value::as_str) else { continue };
        let name = object
            .get("name")
            .map(lua_tostring)
            .unwrap_or_else(|| format!("statusline#{}", out.len() + 1));
        let order = out.len() as u32 + 1;
        out.push(Entry {
            name,
            event: "StatusLine".to_string(),
            kind: "command".to_string(),
            matcher: None,
            command: command.to_string(),
            timeout_ms: get_number(object, "timeout_ms").unwrap_or(STATUSLINE_TIMEOUT_MS),
            on_ask: "deny".to_string(),
            origin: origin.to_string(),
            path: None,
            order,
        });
    }
    out
}

fn keybindings(mods: &Map<String, Value>, origin: &str) -> Vec<Keybinding> {
    let mut out = Vec::new();
    let Some(Value::Array(list)) = mods.get("keybindings") else { return out };
    for item in list {
        let Some(object) = item.as_object() else { continue };
        let (Some(key), Some(command)) = (
            object.get("key").and_then(Value::as_str),
            object.get("command").and_then(Value::as_str),
        ) else {
            continue;
        };
        out.push(Keybinding {
            key: key.to_string(),
            command: command.to_string(),
            description: object.get("description").map(lua_tostring).unwrap_or_default(),
            origin: origin.to_string(),
        });
    }
    out
}

/// The merged view, built source by source in the documented order.
#[derive(Default)]
struct View {
    present: bool,
    sources: Vec<SourceFact>,
    errors: Vec<String>,
    hooks: Vec<EventEntries>,
    statusline: Vec<Entry>,
    commands: Vec<CommandEntry>,
    keybindings: Vec<Keybinding>,
}

impl View {
    fn push(&mut self, event: &str, entries: Vec<Entry>) {
        match self.hooks.iter_mut().find(|item| item.event == event) {
            Some(item) => item.entries.extend(entries),
            None => self.hooks.push(EventEntries { event: event.to_string(), entries }),
        }
    }

    /// The number of entries already configured for `event`, so a later source's entries are
    /// ordered after an earlier source's (the native `order` is the position in the event's list).
    fn start(&self, event: &str) -> u32 {
        self.hooks
            .iter()
            .find(|item| item.event == event)
            .map(|item| item.entries.len() as u32)
            .unwrap_or(0)
    }

    fn note_source(&mut self, source: &Source, kind: &str) {
        self.present = true;
        self.sources.push(SourceFact {
            name: source.name.clone(),
            path: source.path.clone(),
            kind: kind.to_string(),
        });
    }
}

fn is_event(name: &str) -> bool {
    catalogue().iter().any(|event| event.name == name)
}

fn declared_compat(object: &Map<String, Value>) -> bool {
    let top = object.get("claude_compat") == Some(&Value::Bool(true));
    let inner = object.get("hooks").and_then(Value::as_object).and_then(|hooks| hooks.get("claude_compat"))
        == Some(&Value::Bool(true));
    top || inner
}

/// One source. A file that is missing is silence (nothing is configured there); a file that is not
/// JSON, or whose `hooks` is not an object, is an error an operator can see, and the file is skipped.
fn read_native(source: &Source, view: &mut View) {
    if source.problem.as_deref() == Some("invalid_json") {
        error(&mut view.errors, format!("{}: {} is not valid JSON", source.name, source.path));
        return;
    }
    let Some(text) = source.text.as_ref().filter(|_| source.problem.is_none()) else { return };
    let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(text) else {
        error(&mut view.errors, format!("{}: {} is not valid JSON", source.name, source.path));
        return;
    };
    view.note_source(source, "native");
    let hooks = match object.get("hooks").cloned() {
        Some(Value::Object(hooks)) => Value::Object(hooks),
        Some(_) => {
            error(&mut view.errors, format!("{}: hooks is not an object", source.name));
            Value::Null
        }
        None => Value::Object(object.clone()),
    };
    if let Value::Object(hooks) = hooks {
        for (name, list) in hooks {
            if is_event(&name) || name.starts_with("bus:") {
                let start = view.start(&name);
                let entries = normalize_entries(&name, &list, &source.name, &source.path, start, &mut view.errors);
                view.push(&name, entries);
            } else if name != "version" && name != "claude_compat" {
                error(&mut view.errors, format!("{}: unknown hook event {name}", source.name));
            }
        }
    }
    if let Some(Value::Object(mods)) = object.get("mods") {
        let entries = statusline_entries(mods, &source.name);
        view.statusline.extend(entries);
        let commands = normalize_commands(mods.get("commands").unwrap_or(&Value::Null), &source.name, &mut view.errors);
        view.commands.extend(commands);
        let keys = keybindings(mods, &source.name);
        view.keybindings.extend(keys);
    }
}

/// Claude Code's settings file. Read only after the operator opted in; a `bus:` topic and the mods
/// are not part of that shape.
fn read_claude(source: &Source, view: &mut View) {
    if source.problem.as_deref() == Some("invalid_json") {
        error(&mut view.errors, format!("{}: {} is not valid JSON", source.name, source.path));
        return;
    }
    let Some(text) = source.text.as_ref().filter(|_| source.problem.is_none()) else { return };
    let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(text) else {
        error(&mut view.errors, format!("{}: {} is not valid JSON", source.name, source.path));
        return;
    };
    view.note_source(source, "claude");
    let block = object.get("hooks").and_then(Value::as_object).cloned().unwrap_or_default();
    for (name, list) in block {
        if is_event(&name) {
            let start = view.start(&name);
            let entries = normalize_entries(&name, &list, &source.name, &source.path, start, &mut view.errors);
            view.push(&name, entries);
        } else {
            error(&mut view.errors, format!("{}: unknown hook event {name}", source.name));
        }
    }
}

/// Read every source in the documented order and answer the merged view: the node's own file, the
/// project's, then — only when the operator opted in — Claude Code's two.
pub fn configure(request: &ConfigRequest) -> ConfigFacts {
    let mut view = View::default();
    if request.disabled {
        return ConfigFacts {
            disabled: true,
            present: false,
            compat: false,
            workdir: request.workdir.clone(),
            sources: Vec::new(),
            errors: Vec::new(),
            hooks: Vec::new(),
            statusline: Vec::new(),
            commands: Vec::new(),
            keybindings: Vec::new(),
        };
    }
    let mut compat = request.claude_env_opt_in;
    for source in request.sources.iter().filter(|source| source.kind == "native") {
        if let Some(text) = source.text.as_ref().filter(|_| source.problem.is_none()) {
            if let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(text) {
                if declared_compat(&object) {
                    compat = true;
                }
            }
        }
        read_native(source, &mut view);
    }
    if compat {
        for source in request.sources.iter().filter(|source| source.kind == "claude") {
            read_claude(source, &mut view);
        }
    }
    ConfigFacts {
        disabled: false,
        present: view.present,
        compat,
        workdir: request.workdir.clone(),
        sources: view.sources,
        errors: view.errors,
        hooks: view.hooks,
        statusline: view.statusline,
        commands: view.commands,
        keybindings: view.keybindings,
    }
}

// ------------------------------------------------------------------------------------ the decision

pub fn blank(event: &str) -> Decision {
    Decision {
        version: VERSION,
        event: event.to_string(),
        ran: 0,
        outcomes: Vec::new(),
        errors: Vec::new(),
        notes: Vec::new(),
        system_messages: Vec::new(),
        blocked: false,
        status: "no_hooks".to_string(),
        additional_context: None,
        updated_input_json: "{}".to_string(),
        input_changes_json: "{}".to_string(),
        permission: None,
        allowed_by: None,
        blocked_by: None,
        reason: None,
        stop: false,
        stop_reason: None,
        reschedule_seconds: None,
        text: None,
    }
}

fn updated_input(decision: &Decision) -> Map<String, Value> {
    match serde_json::from_str::<Value>(&decision.updated_input_json) {
        Ok(Value::Object(object)) => object,
        _ => Map::new(),
    }
}

fn input_changes(decision: &Decision) -> Map<String, Value> {
    match serde_json::from_str::<Value>(&decision.input_changes_json) {
        Ok(Value::Object(object)) => object,
        _ => Map::new(),
    }
}

fn append_context(decision: &mut Decision, extra: &str) {
    if extra.is_empty() {
        return;
    }
    let joined = match decision.additional_context.take() {
        Some(existing) => format!("{existing}\n{extra}"),
        None => extra.to_string(),
    };
    decision.additional_context = Some(clip(&joined, MAX_CONTEXT_BYTES));
}

fn push_error(decision: &mut Decision, name: Option<&str>, error: &str, detail: Option<String>) {
    decision.errors.push(DecisionError {
        name: name.map(str::to_string),
        error: error.to_string(),
        detail,
    });
}

fn step(decision: Decision, stop: bool, payload: Option<Vec<u8>>) -> Step {
    Step { decision, stop, payload }
}

/// A hook that answered at all is `ok`; the protocol's three cases (timeout, error, a code) are
/// handled below. Exposed so the node can record the row before asking for the verdict, exactly as
/// the native `record()` runs before `interpret()`.
/// Interpret one hook's row into the decision (`M.fire`'s loop body, one step at a time).
pub fn decide(payload: &[u8], prior: Option<Decision>, event: &str, entry: &Entry, row: &Row) -> Step {
    // The status a run of hooks starts from is the *driver's* (the native `M.fire` sets `ok`, the bus
    // publish leaves `no_hooks`), so the prior verdict carries it and this never invents one.
    let mut decision = prior.unwrap_or_else(|| blank(event));
    decision.ran += 1;
    let answer = row
        .json
        .as_ref()
        .and_then(|bytes| decode_object(bytes))
        .or_else(|| row.stdout.as_ref().and_then(|bytes| decode_object(bytes)));
    // The row is recorded before its answer is read (native `record()` runs before `interpret()`), and
    // `answered` is set only past the exit-code checks - a hook that exits 2 is a refusal, not an
    // answer, and the row says so.
    let mut recorded = row.clone();
    recorded.answered = row.exit_code.unwrap_or(0) == 0 && answer.is_some();
    decision.outcomes.push(recorded);

    match row.status.as_str() {
        "timeout" => {
            push_error(&mut decision, Some(&entry.name), "timeout", None);
            return step(decision, false, None);
        }
        "error" => {
            let error = row.error.clone().unwrap_or_else(|| "hook_error".to_string());
            push_error(&mut decision, Some(&entry.name), &error, row.detail.clone());
            return step(decision, false, None);
        }
        _ => {}
    }
    let code = row.exit_code.unwrap_or(0);
    if code == 2 {
        let stderr = row.stderr.as_ref().map(|bytes| one_line(&text_of(bytes))).unwrap_or_default();
        decision.blocked = true;
        decision.blocked_by = Some(entry.name.clone());
        decision.reason = Some(if !stderr.is_empty() {
            stderr
        } else if let Some(reason) = answer.as_ref().and_then(|answer| answer.get("reason")).and_then(Value::as_str) {
            reason.to_string()
        } else {
            format!("hook {} exited 2", entry.name)
        });
        decision.status = "blocked".to_string();
        return step(decision, true, None);
    }
    if code != 0 {
        push_error(&mut decision, Some(&entry.name), &format!("exit_{code}"), row.detail.clone());
        return step(decision, false, None);
    }
    let Some(answer) = answer else { return step(decision, false, None) };
    let mut row = row.clone();

    if let Some(message) = answer.get("systemMessage").and_then(Value::as_str) {
        let line = one_line(message);
        if !line.is_empty() && decision.system_messages.len() < MAX_SYSTEM_MESSAGES {
            let clipped = clip(&line, MAX_SYSTEM_MESSAGE_BYTES);
            decision.system_messages.push(clipped.clone());
            row.system_message = Some(clipped);
        }
    }
    if answer.get("continue") == Some(&Value::Bool(false)) && decision.event == "Stop" {
        let reason = answer
            .get("stopReason")
            .map(lua_tostring)
            .or_else(|| answer.get("reason").map(lua_tostring))
            .unwrap_or_else(|| format!("stopped by hook {}", entry.name));
        decision.stop = true;
        decision.stop_reason = Some(reason);
        let mut outcome = step(decision, true, None);
        if let Some(last) = outcome.decision.outcomes.last_mut() {
            last.system_message = row.system_message.clone();
        }
        return outcome;
    }

    let mut merged: Option<Vec<u8>> = None;
    let specific = answer.get("hookSpecificOutput").and_then(Value::as_object).cloned();
    if let Some(specific) = &specific {
        if let Some(name) = specific.get("hookEventName").and_then(Value::as_str) {
            let fired = decision.event.clone();
            if name != fired {
                push_error(
                    &mut decision,
                    Some(&entry.name),
                    "hook_event_name_mismatch",
                    Some(format!("{name} != {fired}")),
                );
            }
        }
        match specific.get("permissionDecision").and_then(Value::as_str) {
            Some("deny") => {
                let reason = specific
                    .get("permissionDecisionReason")
                    .and_then(Value::as_str)
                    .map(one_line)
                    .filter(|text| !text.is_empty())
                    .or_else(|| answer.get("reason").and_then(Value::as_str).map(one_line))
                    .unwrap_or_default();
                decision.blocked = true;
                decision.blocked_by = Some(entry.name.clone());
                decision.permission = Some("deny".to_string());
                decision.reason =
                    Some(if reason.is_empty() { format!("denied by hook {}", entry.name) } else { reason });
                decision.status = "denied".to_string();
                return step(decision, true, None);
            }
            Some("ask") => {
                let asked = specific
                    .get("permissionDecisionReason")
                    .and_then(Value::as_str)
                    .map(one_line)
                    .unwrap_or_default();
                if entry.on_ask == "allow" {
                    decision.notes.push(format!("hook {} asked; on_ask=allow", entry.name));
                    if decision.permission.is_none() {
                        decision.permission = Some("allow".to_string());
                    }
                } else {
                    decision.blocked = true;
                    decision.blocked_by = Some(entry.name.clone());
                    decision.permission = Some("ask".to_string());
                    let tail = if asked.is_empty() { String::new() } else { format!(": {asked}") };
                    decision.reason = Some(format!(
                        "hook {} asked to confirm this call{tail}; no interactive prompt exists for tool calls, so it is refused (set on_ask:\"allow\" on this hook to allow it)",
                        entry.name
                    ));
                    decision.status = "ask".to_string();
                    return step(decision, true, None);
                }
            }
            Some("allow") => {
                if decision.permission.is_none() {
                    decision.permission = Some("allow".to_string());
                }
                decision.allowed_by = Some(entry.name.clone());
            }
            _ => {}
        }
        if let Some(rewrite) = specific.get("updatedInput").and_then(Value::as_object) {
            if decision.event == "PreToolUse" {
                let mut changes = input_changes(&decision);
                let mut accumulated = updated_input(&decision);
                for (key, value) in rewrite {
                    changes.insert(key.clone(), value.clone());
                    accumulated.insert(key.clone(), value.clone());
                }
                decision.updated_input_json = Value::Object(accumulated).to_string();
                decision.input_changes_json = Value::Object(changes).to_string();
                // Apply it to the payload too, so a later hook sees the chain it is part of.
                if let Ok(Value::Object(mut body)) = serde_json::from_slice::<Value>(payload) {
                    let mut tool_input = match body.get("tool_input") {
                        Some(Value::Object(tool_input)) => Some(tool_input.clone()),
                        _ => None,
                    };
                    if let Some(tool_input) = tool_input.as_mut() {
                        for (key, value) in rewrite {
                            if value.is_null() {
                                tool_input.remove(key);
                            } else {
                                tool_input.insert(key.clone(), value.clone());
                            }
                        }
                        body.insert("tool_input".to_string(), Value::Object(tool_input.clone()));
                        if let Ok(bytes) = serde_json::to_vec(&Value::Object(body)) {
                            merged = Some(bytes);
                        }
                    }
                }
            }
        }
        if let Some(context) = specific.get("additionalContext").and_then(Value::as_str) {
            if !context.is_empty() {
                append_context(&mut decision, context);
            }
        }
    }

    match answer.get("decision").and_then(Value::as_str) {
        Some("block") | Some("deny") => {
            let reason = answer.get("reason").and_then(Value::as_str).map(one_line).unwrap_or_default();
            decision.blocked = true;
            decision.blocked_by = Some(entry.name.clone());
            decision.reason = Some(if reason.is_empty() {
                format!("blocked by hook {}", entry.name)
            } else {
                reason
            });
            decision.status = "blocked".to_string();
        }
        Some("approve") | Some("allow") => {
            if decision.permission.is_none() {
                decision.permission = Some("allow".to_string());
            }
            decision.allowed_by = Some(entry.name.clone());
        }
        _ => {}
    }
    if let Some(context) = answer.get("additionalContext").and_then(Value::as_str) {
        if !context.is_empty() {
            append_context(&mut decision, context);
        }
    }
    let reschedule = answer
        .get("reschedule_seconds")
        .and_then(tonumber)
        .or_else(|| specific.as_ref().and_then(|specific| get_number(specific, "rescheduleSeconds")));
    if let Some(reschedule) = reschedule {
        if reschedule > 0.0 {
            decision.reschedule_seconds = Some(reschedule.floor() as u64);
        }
    }
    if decision.event == "StatusLine" {
        if let Some(stdout) = row.stdout.as_ref() {
            let line = one_line(&text_of(stdout));
            if !line.is_empty() {
                decision.text = Some(clip(&line, STATUSLINE_MAX));
            }
        }
    }
    if let Some(last) = decision.outcomes.last_mut() {
        last.system_message = row.system_message.clone();
    }
    let stop = decision.blocked || decision.stop;
    step(decision, stop, merged)
}

/// The entries that run for `event`, in run order, after matchers.
pub fn entries(request: &EntriesRequest) -> Vec<Entry> {
    let narrowing = event_matcher(&request.event);
    request
        .entries
        .iter()
        .filter(|entry| !narrowing || matches(entry.matcher.as_deref(), request.tool.as_deref().unwrap_or("")))
        .cloned()
        .collect()
}

/// The footer's text from the rows the statusline commands produced.
pub fn segment(request: &SegmentRequest) -> String {
    let mut pieces: Vec<String> = Vec::new();
    for (index, entry) in request.entries.iter().enumerate() {
        let row = request.rows.get(index);
        let text = row
            .and_then(|row| row.stdout.as_ref())
            .map(|bytes| one_line(&text_of(bytes)))
            .unwrap_or_default();
        if !text.is_empty() {
            pieces.push(clip(&text, STATUSLINE_MAX));
        }
        let broken = match row {
            None => true,
            Some(row) => {
                row.status != "ok" || row.exit_code.unwrap_or(0) != 0
            }
        };
        if broken {
            pieces.push(format!("!{}", entry.name));
        }
    }
    pieces.join(" · ")
}
