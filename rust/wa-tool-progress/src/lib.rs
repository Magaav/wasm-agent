//! Live progress for a long tool call, as one line.
//!
//! The finding this exists for (08/11): the agent ran `cargo test` in its `bash` tool for twenty
//! minutes and `wa chat` showed only "Running bash" - no output, no movement, so a healthy build and
//! a wedged process looked the same. The session-status-content row (the one line directly above the
//! status bar, `rust/wa-term/src/build_status.rs`) already had a loader for *node rebuilds*; this is
//! the same row for the *tool calls the agent makes*.
//!
//! What it says, in the order the parts matter:
//!
//! ```text
//! ⟳ bash · 3m10s ▕████░░░░░░░░░░▏ 143/412 compiling serde_json
//! ⟳ bash · 41s · Downloading numpy-1.26.0-cp311.whl (15.8 MB)
//! ⟳ bash · 4m20s · no output for 3m
//! ```
//!
//! * the tool, and how long this call has been running;
//! * what the output's own progress dialect says, when it speaks one (cargo's `Building [=> ] 143/412`,
//!   npm/pnpm's `Progress: resolved 143`, pip's `45%|███  | 45/100`, git's `Receiving objects: 45%`);
//!   otherwise the last non-empty line, which is what a reader would have seen in a terminal;
//! * and, when nothing has been written for [`STALL_SECONDS`], that fact - so slow and stuck stop
//!   looking identical without claiming which one it is.
//!
//! Three rules this crate is built around:
//!
//! 1. **Nothing here changes a tool result.** It reads a tail that is already captured and redacted
//!    (`wa-operation`'s redactor runs before output is written to disk), and produces text.
//! 2. **A row is one line, always.** Control characters and ANSI sequences are stripped here, and
//!    the caller clips to its width (`wa_term::terminal_editor::clip_cells`, `cli_view.clip`).
//! 3. **Secrets never reach the row.** The tail is already redacted at the source; [`redact`] is the
//!    second pass, by exact value, for a value that arrives some other way (a label from the
//!    command, a line the redactor could not see the whole of).
use serde_json::{json, Value};

/// The bar's width, and its glyphs: the same shape `wa-term`'s build loader draws, so the two
/// loaders on the same row cannot look like two different features.
pub const BAR: usize = 14;
const BAR_LEFT: &str = "\u{2595}";
const BAR_RIGHT: &str = "\u{258f}";
const BAR_FULL: &str = "\u{2588}";
const BAR_EMPTY: &str = "\u{2591}";

/// A call shorter than this needs no row: the status line already says `Running bash`, and a line
/// that appears and vanishes inside two seconds is flicker, not information.
pub const MIN_SECONDS: f64 = 2.0;

/// No output for this long is worth saying out loud. A quiet compiler is healthy, so this is not a
/// verdict - it is the one fact a reader cannot get from a still picture.
pub const STALL_SECONDS: f64 = 180.0;

/// A live file older than this is a node that died mid-call, not a running tool. Same rule as the
/// build loader's: a stale fact shows nothing rather than a stale line.
pub const FRESH: f64 = 10.0;

/// How many of the newest lines the tail keeps. The last one is usually the answer; a handful more
/// is what lets a `Building` line survive the `Compiling` lines that follow it.
const KEEP_LINES: usize = 24;
/// How far back a dialect line is still allowed to speak for the call. Four is one progress line plus
/// the three ordinary lines that follow it before the row falls back to the last line: a build's bar
/// outlives the build by a moment, not by a test run.
pub const RECENT: usize = 4;
/// The longest single line kept. A minified dump on one line is not progress.
const MAX_LINE: usize = 400;

/// `125` -> `2m05s`, `45` -> `45s`, `3720` -> `1h02m` - the build loader's clock, so the two rows
/// on the same screen read the same way.
pub fn elapsed(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s >= 3600 {
        format!("{}h{:02}m", s / 3600, s / 60 % 60)
    } else if s >= 60 {
        format!("{}m{:02}s", s / 60, s % 60)
    } else {
        format!("{s}s")
    }
}

/// `▕████░░░░░░░░░░▏` for a fraction in `0.0..=1.0`.
pub fn bar(fraction: f64) -> String {
    let fraction = if fraction.is_finite() { fraction.clamp(0.0, 1.0) } else { 0.0 };
    let filled = (fraction * BAR as f64).round() as usize;
    format!("{BAR_LEFT}{}{}{BAR_RIGHT}", BAR_FULL.repeat(filled), BAR_EMPTY.repeat(BAR - filled))
}

/// `3m` for a whole number of minutes, `3m20s` when the seconds matter, `45s` under a minute. The
/// stall hint is the one clock on the row that is not a stopwatch - it says how long the silence is,
/// not how long the call is - so it reads compactly.
pub fn compact(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s >= 3600 {
        format!("{}h{:02}m", s / 3600, s / 60 % 60)
    } else if s >= 60 && s % 60 == 0 {
        format!("{}m", s / 60)
    } else if s >= 60 {
        format!("{}m{:02}s", s / 60, s % 60)
    } else {
        format!("{s}s")
    }
}

/// The stall hint's own wording, so the CLI, the window and the Rust row cannot drift: `no output
/// for 3m`, `no output for 3m20s`, `no output for 45s`.
pub fn stall(seconds: f64) -> String {
    format!("no output for {}", compact(seconds))
}

/// Remove what must never be drawn on a single row: ANSI sequences (a tool that forces colour still
/// writes them to a pipe), and every other control character. Tabs become a space - a tab is a
/// column count the caller's clip cannot see.
pub fn printable(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' {
            // CSI: `ESC [ params letter`. OSC (`ESC ]`) ends at BEL or ST; anything else is dropped
            // as a two-character sequence. A tail cut mid-sequence loses the rest of the sequence
            // rather than painting half of it.
            match chars.peek() {
                Some('[') => {
                    chars.next();
                    for next in chars.by_ref() {
                        if ('\u{40}'..='\u{7e}').contains(&next) { break; }
                    }
                }
                Some(']') => {
                    chars.next();
                    for next in chars.by_ref() {
                        if next == '\u{7}' { break; }
                        if next == '\u{1b}' { break; }
                    }
                }
                Some(_) => { chars.next(); }
                None => {}
            }
            continue;
        }
        if ch == '\t' { out.push(' '); continue; }
        if ch.is_control() { continue; }
        out.push(ch);
    }
    out
}

/// Mask the node's own secret *values* wherever they appear.
///
/// The tail this row draws comes from an operation's output file, which `wa-operation`'s redactor
/// already wrote without the node's secrets. This is the second pass: a value that reaches a label
/// or a line by another route (a command echoed into the tool name, a tool that printed a key the
/// redactor's environment list does not know) is masked here rather than drawn. Exact-value
/// replacement, the same policy as `wa-operation`: the shape patterns the Lua log redactor uses
/// (`sk-`) would mangle ordinary output, and the node knows its own values anyway.
pub fn redact(text: &str, secrets: &[String]) -> String {
    let mut out = text.to_string();
    for secret in secrets {
        if secret.len() < 8 { continue; }
        if out.contains(secret.as_str()) { out = out.replace(secret.as_str(), "<redacted>"); }
    }
    out
}

/// The names whose values the node treats as its own secrets. Keep in step with
/// `wa-operation`'s `SECRET_ENV` and `lua/core/redact.lua`'s list; all three are a handful of names.
pub const SECRET_ENV: &[&str] = &[
    "WASM_AGENT_LLM_API_KEY",
    "OPENAI_API_KEY",
    "OPENCODE_GO_API_KEY",
    "WASM_AGENT_PROMPT_CACHE_KEY",
];

/// Those values from the process environment, as `wa-operation` does it: a value shorter than eight
/// bytes would redact ordinary text.
pub fn env_secrets() -> Vec<String> {
    let mut values = Vec::new();
    for name in SECRET_ENV {
        if let Ok(value) = std::env::var(name) {
            if value.len() >= 8 { values.push(value); }
        }
    }
    values
}

/// Where the live file goes: `$WASM_AGENT_DATA`, else `$WASM_AGENT_HOME/.wasm-agent`, else
/// `$HOME/.wasm-agent` - the three tiers `scripts/lib/build-status.sh` uses for the build loader.
/// The host writes it and every renderer reads it, which is what lets the CLI, the window and the
/// native editor agree about a call none of them can poll while Lua is blocked.
pub fn data_path() -> std::path::PathBuf {
    let env = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
    let data = env("WASM_AGENT_DATA").or_else(|| env("WASM_AGENT_HOME").map(|home| format!("{home}/.wasm-agent")))
        .or_else(|| env("HOME").map(|home| format!("{home}/.wasm-agent")))
        .unwrap_or_else(|| ".wasm-agent".to_string());
    std::path::Path::new(&data).join("tool-progress.json")
}

/// What the output's own dialect says, newest line first. Rendered as a bar when the line carries
/// numbers, as text when it does not.
#[derive(Debug, PartialEq, Clone)]
pub enum Detail {
    /// `done` of `total`; `percent` when the line only said a percentage (`45%`).
    Bar { label: String, done: u64, total: u64, percent: bool },
    Text(String),
}

impl Detail {
    /// The row's detail, from the tail's lines (oldest first). The newest line a known dialect
    /// recognizes wins - but only within the newest [`RECENT`] non-empty lines, because a build's bar
    /// must not outlive the build: a `cargo test` finishes compiling, then prints its results, and a
    /// bar frozen at `143/412` while the tests run would be a moving picture of a finished thing.
    /// When nothing recent is a dialect, the last non-empty line is the answer - which is exactly what
    /// the reader of a terminal would be looking at.
    pub fn from_lines(lines: &[String]) -> Option<Detail> {
        let recent: Vec<&String> = lines.iter().rev().filter(|line| !line.trim().is_empty()).take(RECENT).collect();
        for line in &recent {
            if let Some(detail) = parse_line(line) { return Some(detail); }
        }
        // The generic fallback: the last line, which is what a reader watching a terminal would see.
        recent.first().map(|line| Detail::Text(line.trim().to_string()))
    }

    /// The JSON the live file carries, so a renderer that never sees the tail can draw the same row.
    pub fn to_json(&self) -> Value {
        match self {
            Detail::Bar { label, done, total, percent } =>
                json!({"kind":"bar","label":label,"done":done,"total":total,"percent":percent}),
            Detail::Text(text) => json!({"kind":"text","text":text}),
        }
    }

    pub fn from_json(value: &Value) -> Option<Detail> {
        match value.get("kind").and_then(Value::as_str) {
            Some("bar") => Some(Detail::Bar {
                label: value.get("label").and_then(Value::as_str).unwrap_or("").to_string(),
                done: value.get("done").and_then(Value::as_u64).unwrap_or(0),
                total: value.get("total").and_then(Value::as_u64).unwrap_or(0),
                percent: value.get("percent").and_then(Value::as_bool).unwrap_or(false),
            }),
            Some("text") => Some(Detail::Text(value.get("text").and_then(Value::as_str).unwrap_or("").to_string())),
            _ => None,
        }
    }
}

/// The words a dialect uses, lowercased for the row (`Receiving objects` -> `receiving objects`).
fn lower_first(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_lowercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// A percentage or a `n/m` pair on a line, with whatever label the line carried.
fn numbers(line: &str) -> Option<(u64, u64, bool)> {
    // `n/m` first: `45% (450/1000)` has both, and the count is the better number.
    if let Some((done, total)) = find_pair(line) {
        if total > 0 && done <= total.saturating_mul(4) { return Some((done, total, false)); }
    }
    if let Some(percent) = find_percent(line) { return Some((percent, 100, true)); }
    None
}

fn find_pair(line: &str) -> Option<(u64, u64)> {
    let bytes: Vec<char> = line.chars().collect();
    let mut index = 0;
    while index < bytes.len() {
        if !bytes[index].is_ascii_digit() { index += 1; continue; }
        let start = index;
        while index < bytes.len() && bytes[index].is_ascii_digit() { index += 1; }
        let first: u64 = bytes[start..index].iter().collect::<String>().parse().ok()?;
        let mut cursor = index;
        // A decimal count (`45.0/100.0`, pip's own bar) is the integer part and a fraction of a
        // step: the pair is still 45 of 100.
        if cursor + 1 < bytes.len() && bytes[cursor] == '.' && bytes[cursor + 1].is_ascii_digit() {
            cursor += 1;
            while cursor < bytes.len() && bytes[cursor].is_ascii_digit() { cursor += 1; }
        }
        while cursor < bytes.len() && bytes[cursor] == ' ' { cursor += 1; }
        if cursor < bytes.len() && bytes[cursor] == '/' {
            cursor += 1;
            while cursor < bytes.len() && bytes[cursor] == ' ' { cursor += 1; }
            let digits = cursor;
            while cursor < bytes.len() && bytes[cursor].is_ascii_digit() { cursor += 1; }
            let digits_end = cursor;
            if cursor + 1 < bytes.len() && bytes[cursor] == '.' && bytes[cursor + 1].is_ascii_digit() {
                cursor += 1;
                while cursor < bytes.len() && bytes[cursor].is_ascii_digit() { cursor += 1; }
            }
            if digits_end > digits {
                let second: u64 = bytes[digits..digits_end].iter().collect::<String>().parse().ok()?;
                return Some((first, second));
            }
        }
    }
    None
}

fn find_percent(line: &str) -> Option<u64> {
    let chars: Vec<char> = line.chars().collect();
    for index in 0..chars.len() {
        if chars[index] != '%' || index == 0 { continue; }
        let mut start = index;
        while start > 0 && chars[start - 1].is_ascii_digit() { start -= 1; }
        if start == index { continue; }
        let value: u64 = chars[start..index].iter().collect::<String>().parse().ok()?;
        if value <= 100 { return Some(value); }
    }
    None
}

/// One line, through the dialects this node actually watches. `None` = no dialect recognized it, and
/// the caller falls back to the raw line.
fn parse_line(raw: &str) -> Option<Detail> {
    let line = printable(raw);
    let line = line.trim();
    if line.is_empty() { return None; }
    let lower = line.to_ascii_lowercase();

    // ---- cargo -------------------------------------------------------------------------------
    // `Building [======>       ] 143/412: serde_json, syn, proc-macro2` - the bar and the count.
    if let Some(rest) = lower.strip_prefix("building [") {
        let label = line.rsplit(": ").next().unwrap_or("");
        let label = if label.starts_with('[') || label.starts_with("Building") { "" } else { label };
        let label = label.split(',').next().unwrap_or("").trim().to_string();
        return match find_pair(rest) {
            Some((done, total)) if total > 0 => Some(Detail::Bar {
                label: if label.is_empty() { "building".into() } else { format!("building {label}") },
                done, total, percent: false,
            }),
            _ => Some(Detail::Text("building".into())),
        };
    }
    if let Some(rest) = line.strip_prefix("Compiling ") {
        let name = rest.split_whitespace().next().unwrap_or("").to_string();
        return Some(Detail::Text(if name.is_empty() { "compiling".into() } else { format!("compiling {name}") }));
    }
    if let Some(rest) = line.strip_prefix("Finished ") {
        return Some(Detail::Text(format!("finished{}", rest.split(" in ").nth(1).map(|t| format!(" in {t}")).unwrap_or_default())));
    }
    // ---- npm / pnpm ---------------------------------------------------------------------------
    // `Progress: resolved 143, reused 120, downloaded 23, added 0`
    if lower.starts_with("progress:") || lower.starts_with("progress ") {
        let resolved = lower.split("resolved ").nth(1)
            .and_then(|rest| rest.split(|c: char| !c.is_ascii_digit()).next())
            .and_then(|digits| digits.parse::<u64>().ok());
        return Some(match resolved {
            Some(count) => Detail::Text(format!("resolved {count} packages")),
            None => Detail::Text(line.to_string()),
        });
    }
    // `reify:foo: timing ...` / `⸨##########⸩ ⠸ reify:foo: timing` - the step name is the progress.
    if let Some(index) = lower.find("reify:") {
        let name: String = line[index..].chars().take_while(|c| *c != ':' || line[index..].starts_with("reify:")).collect();
        let name = name.split(": timing").next().unwrap_or("reify");
        return Some(Detail::Text(lower_first(name.trim())));
    }
    // ---- pip ---------------------------------------------------------------------------------
    if lower.starts_with("downloading ") || lower.starts_with("collecting ") || lower.starts_with("installing ") {
        let text = printable(line);
        let text: String = text.chars().take(120).collect();
        return Some(Detail::Text(lower_first(text.trim())));
    }
    // `  45%|████▌     | 45.0/100.0 [00:03<00:04, 12.3MB/s]` - pip's own bar.
    if let Some((done, total, percent)) = numbers(line) {
        let label = match lower.find('|') {
            Some(_) => "",
            None => line.split('%').next().map(|_| "").unwrap_or(""),
        };
        let _ = label;
        if percent || total > 0 {
            let words = if lower.starts_with("receiving objects") { "receiving objects" }
                else if lower.starts_with("resolving deltas") { "resolving deltas" }
                else if lower.starts_with("counting objects") { "counting objects" }
                else if lower.starts_with("compressing objects") { "compressing objects" }
                else if lower.contains("download") { "downloading" }
                else { "" };
            // Only claim a bar when the line is a progress line: a stray `1/2` inside ordinary text
            // is not progress, and inventing a bar for it would be a lie with a moving picture.
            let progress_shaped = percent || lower.contains("objects") || lower.contains("deltas")
                || lower.contains('|') || lower.contains("download") || lower.contains("compiling")
                || lower.contains("resolved");
            if progress_shaped {
                return Some(Detail::Bar { label: words.to_string(), done, total, percent });
            }
        }
    }
    // ---- git ---------------------------------------------------------------------------------
    // `Receiving objects:  45% (450/1000), 1.20 MiB | 2.00 MiB/s`
    for (prefix, words) in [
        ("receiving objects:", "receiving objects"),
        ("resolving deltas:", "resolving deltas"),
        ("counting objects:", "counting objects"),
        ("compressing objects:", "compressing objects"),
        ("remote: compressing objects:", "compressing objects"),
        ("remote: counting objects:", "counting objects"),
        ("remote: total", "receiving objects"),
    ] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            return match numbers(rest) {
                Some((done, total, percent)) => Some(Detail::Bar { label: words.into(), done, total, percent }),
                None => Some(Detail::Text(words.into())),
            };
        }
    }
    if lower.starts_with("cloning into") || lower.starts_with("remote: enumerating") {
        return Some(Detail::Text(lower_first(line)));
    }
    // `Downloading 12.3 MiB / 45.6 MiB` and friends: a size, no percentage.
    if lower.starts_with("downloading") { return Some(Detail::Text(lower_first(line))); }
    None
}

/// One row: the text a surface draws (no colour, no escapes, one line), and whether the stall hint
/// is in it.
#[derive(Debug, PartialEq, Clone)]
pub struct Row { pub text: String, pub stalled: bool }

impl Row {
    /// The row's text before clipping: `⟳ <tool> · <elapsed>` then the detail, or the stall hint.
    pub fn text(tool: &str, elapsed_seconds: f64, detail: Option<&Detail>, silent_seconds: f64) -> String {
        let tool = if tool.trim().is_empty() { "tool" } else { tool.trim() };
        let mut text = format!("\u{27f3} {tool} \u{b7} {}", elapsed(elapsed_seconds));
        if silent_seconds >= STALL_SECONDS {
            text.push_str(" \u{b7} ");
            text.push_str(&stall(silent_seconds));
            return text;
        }
        match detail {
            Some(Detail::Bar { label, done, total, percent }) => {
                let fraction = if *total > 0 { *done as f64 / *total as f64 } else { 0.0 };
                let count = if *percent { format!("{done}%") } else { format!("{done}/{total}") };
                text.push(' ');
                text.push_str(&bar(fraction));
                text.push(' ');
                text.push_str(&count);
                if !label.is_empty() { text.push(' '); text.push_str(label); }
            }
            Some(Detail::Text(detail)) => {
                if !detail.is_empty() {
                    text.push_str(" \u{b7} ");
                    text.push_str(detail);
                }
            }
            None => {}
        }
        text
    }
}

/// The tail of a running call: the tool, when it started, and the last few lines of its output.
///
/// The caller feeds it output as it arrives (`observe`) and asks for a row; it holds no clock of its
/// own, so a test drives it with the times it wants and a renderer that reads a file needs none.
#[derive(Debug, Clone)]
pub struct Tracker {
    tool: String,
    started_at: f64,
    last_output_at: f64,
    lines: Vec<String>,
}

impl Tracker {
    pub fn new(tool: &str, now: f64) -> Self {
        Self { tool: tool.to_string(), started_at: now, last_output_at: now, lines: Vec::new() }
    }

    pub fn tool(&self) -> &str { &self.tool }
    pub fn started_at(&self) -> f64 { self.started_at }
    pub fn last_output_at(&self) -> f64 { self.last_output_at }

    /// A chunk of output: `\r` is a line break too, because a bar that rewrites itself in place is
    /// exactly the output this row exists for. An empty chunk is not output and does not reset the
    /// stall clock.
    pub fn observe(&mut self, chunk: &str, now: f64) {
        let mut added = false;
        for raw in chunk.split(|c| c == '\n' || c == '\r') {
            let line = printable(raw);
            let line = line.trim();
            if line.is_empty() { continue; }
            let line: String = line.chars().take(MAX_LINE).collect();
            self.lines.push(line);
            added = true;
        }
        if self.lines.len() > KEEP_LINES { self.lines.drain(..self.lines.len() - KEEP_LINES); }
        if added { self.last_output_at = now; }
    }

    pub fn detail(&self) -> Option<Detail> { Detail::from_lines(&self.lines) }

    /// How long nothing has been written. Counted from the start when nothing ever was, so a command
    /// that has said nothing for three minutes says so.
    pub fn silent_for(&self, now: f64) -> f64 { (now - self.last_output_at).max(0.0) }

    /// The row, or `None` while the call is still young enough that the status line is enough.
    pub fn row(&self, now: f64, secrets: &[String]) -> Option<Row> {
        let elapsed_seconds = now - self.started_at;
        if elapsed_seconds < MIN_SECONDS { return None; }
        let detail = self.detail();
        let text = redact(&Row::text(&self.tool, elapsed_seconds, detail.as_ref(), self.silent_for(now)), secrets);
        Some(Row { text, stalled: self.silent_for(now) >= STALL_SECONDS })
    }

    /// The live file's contents: everything a renderer needs to draw the same row without the tail.
    pub fn facts(&self, now: f64, secrets: &[String]) -> Value {
        let detail = self.detail().map(|detail| match detail {
            Detail::Bar { label, done, total, percent } =>
                Detail::Bar { label: redact(&label, secrets), done, total, percent },
            Detail::Text(text) => Detail::Text(redact(&text, secrets)),
        });
        json!({
            "state": "running",
            "tool": redact(&self.tool, secrets),
            "started_at": self.started_at,
            "at": now,
            "last_output_at": self.last_output_at,
            "detail": detail.map(|detail| detail.to_json()),
        })
    }
}

/// A row from the live file, at `now`. `None` when the file says nothing worth a row: not running,
/// stale (`at` older than [`FRESH`]), or younger than [`MIN_SECONDS`] - the same three rules the
/// tracker applies in-process, so the file and the process cannot disagree.
pub fn row_from_facts(facts: &Value, now: f64, secrets: &[String]) -> Option<Row> {
    if facts.get("state").and_then(Value::as_str) != Some("running") { return None; }
    let at = facts.get("at").and_then(Value::as_f64)?;
    if now - at > FRESH { return None; }
    let started_at = facts.get("started_at").and_then(Value::as_f64).unwrap_or(at);
    let elapsed_seconds = (now - started_at).max(0.0);
    if elapsed_seconds < MIN_SECONDS { return None; }
    let tool = facts.get("tool").and_then(Value::as_str).unwrap_or("tool");
    let last_output_at = facts.get("last_output_at").and_then(Value::as_f64).unwrap_or(started_at);
    let silent = (now - last_output_at).max(0.0);
    let detail = facts.get("detail").and_then(Detail::from_json);
    let text = redact(&Row::text(tool, elapsed_seconds, detail.as_ref(), silent), secrets);
    Some(Row { text, stalled: silent >= STALL_SECONDS })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn no_secrets() -> Vec<String> { Vec::new() }

    // ---- the clock and the bar ---------------------------------------------------------------
    #[test]
    fn a_clock_reads_like_the_build_loaders() {
        assert_eq!(elapsed(45.0), "45s");
        assert_eq!(elapsed(125.0), "2m05s");
        assert_eq!(elapsed(3720.0), "1h02m");
        assert_eq!(elapsed(-5.0), "0s", "a clock never runs backwards");
    }

    #[test]
    fn the_bar_is_the_build_loaders_bar() {
        assert_eq!(bar(0.0), "\u{2595}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{258f}");
        assert_eq!(bar(1.0), format!("\u{2595}{}\u{258f}", "\u{2588}".repeat(BAR)));
        // `143/412` rounds to 5 of 14 filled - the same five `build_status` draws for that fraction.
        let five = bar(143.0 / 412.0);
        assert!(five.starts_with(&format!("\u{2595}{}", "\u{2588}".repeat(5))), "{five}");
        assert_eq!(five.chars().count(), BAR + 2);
        assert_eq!(bar(2.0), bar(1.0), "a fraction past one is clamped");
        assert_eq!(bar(f64::NAN), bar(0.0), "and a non-number is empty, not a panic");
    }

    // ---- the dialects ------------------------------------------------------------------------
    #[test]
    fn cargo_speaks_a_bar_and_a_count() {
        let lines: Vec<String> = ["   Compiling serde_json v1.0.0",
            "    Building [=============>         ] 143/412: serde_json, syn, proc-macro2"]
            .iter().map(|line| line.to_string()).collect();
        assert_eq!(Detail::from_lines(&lines), Some(Detail::Bar {
            label: "building serde_json".into(), done: 143, total: 412, percent: false }));
        let only_compiling: Vec<String> = vec!["Compiling wasmtime v50.0.0".into()];
        assert_eq!(Detail::from_lines(&only_compiling), Some(Detail::Text("compiling wasmtime".into())));
        // A crate name with a version is not part of the label: the row is one line and the count is
        // the interesting part.
        let built: Vec<String> = vec!["   Compiling wa-term v0.1.0".into(), "    Finished `test` profile [unoptimized] target(s) in 4m12s".into()];
        assert_eq!(Detail::from_lines(&built), Some(Detail::Text("finished in 4m12s".into())));
    }

    #[test]
    fn npm_pnpm_pip_and_git_speak_their_own_dialects() {
        let pnpm: Vec<String> = vec!["Progress: resolved 143, reused 120, downloaded 23, added 0".into()];
        assert_eq!(Detail::from_lines(&pnpm), Some(Detail::Text("resolved 143 packages".into())));
        let reify: Vec<String> = vec!["\u{2e28}#####\u{2e29} \u{280b} reify:lodash: timing build:queue Completed in 12ms".into()];
        assert_eq!(Detail::from_lines(&reify), Some(Detail::Text("reify:lodash".into())));
        let pip: Vec<String> = vec!["  45%|\u{2588}\u{2588}\u{2588}\u{2588}\u{258c}      | 45.0/100.0 [00:03<00:04, 12.3MB/s]".into()];
        assert_eq!(Detail::from_lines(&pip), Some(Detail::Bar { label: "".into(), done: 45, total: 100, percent: false }));
        let pip_text: Vec<String> = vec!["Downloading numpy-1.26.0-cp311.whl (15.8 MB)".into()];
        assert_eq!(Detail::from_lines(&pip_text), Some(Detail::Text("downloading numpy-1.26.0-cp311.whl (15.8 MB)".into())));
        let git: Vec<String> = vec!["Receiving objects:  45% (450/1000), 1.20 MiB | 2.00 MiB/s".into()];
        assert_eq!(Detail::from_lines(&git), Some(Detail::Bar { label: "receiving objects".into(), done: 450, total: 1000, percent: false }));
        let git_percent: Vec<String> = vec!["Resolving deltas:  12% (120/1000)".into()];
        assert_eq!(Detail::from_lines(&git_percent), Some(Detail::Bar { label: "resolving deltas".into(), done: 120, total: 1000, percent: false }));
        let cloning: Vec<String> = vec!["Cloning into 'wasm-agent'...".into()];
        assert_eq!(Detail::from_lines(&cloning), Some(Detail::Text("cloning into 'wasm-agent'...".into())));
    }

    #[test]
    fn a_dialect_that_says_nothing_falls_back_to_the_last_line() {
        let lines: Vec<String> = vec!["warning: unused import".into(), "test result: ok. 41 passed; 0 failed".into()];
        assert_eq!(Detail::from_lines(&lines), Some(Detail::Text("test result: ok. 41 passed; 0 failed".into())),
            "no dialect claims it, so the last line is the answer");
        assert_eq!(Detail::from_lines(&[]), None, "no output at all: no detail");
        let row = Row::text("bash", 12.0, None, 0.0);
        assert_eq!(row, "\u{27f3} bash \u{b7} 12s", "no detail: the tool and the clock only");
    }

    // ---- the row -------------------------------------------------------------------------------
    #[test]
    fn a_cargo_bar_row_is_one_line_with_the_tool_the_clock_and_the_count() {
        let mut tracker = Tracker::new("bash", 1000.0);
        tracker.observe("   Compiling serde_json v1.0.0\n", 1001.0);
        tracker.observe("    Building [=============>         ] 143/412: serde_json, syn\n", 1190.0);
        let row = tracker.row(1190.0, &no_secrets()).expect("a row after 190 s");
        assert!(!row.stalled);
        assert_eq!(row.text, format!("\u{27f3} bash \u{b7} 3m10s {} 143/412 building serde_json", bar(143.0 / 412.0)));
        assert!(!row.text.contains('\n'));
    }

    #[test]
    fn a_finished_builds_bar_does_not_speak_for_the_test_run_that_follows() {
        // `cargo test`: the build's bar on stderr, then the runner's own lines on stdout. The bar is
        // four ordinary lines back, so the last line is the row - not a bar frozen at 143/412.
        let lines: Vec<String> = vec![
            "    Building [=============>         ] 143/412: serde_json, syn".into(),
            "     Running unittests src/lib.rs".into(),
            "running 41 tests".into(),
            "test a::one ... ok".into(),
            "test result: ok. 41 passed; 0 failed; 0 ignored".into(),
        ];
        assert_eq!(Detail::from_lines(&lines), Some(Detail::Text("test result: ok. 41 passed; 0 failed; 0 ignored".into())));
        // One line later than that and the bar is still the row: a compiler interleaves its progress
        // with ordinary lines all the time.
        let interleaved: Vec<String> = vec![
            "    Building [=============>         ] 143/412: serde_json, syn".into(),
            "     Running unittests src/lib.rs".into(),
            "running 41 tests".into(),
        ];
        assert_eq!(Detail::from_lines(&interleaved), Some(Detail::Bar {
            label: "building serde_json".into(), done: 143, total: 412, percent: false }));
    }

    #[test]
    fn a_generic_last_line_is_the_row() {
        let mut tracker = Tracker::new("bash", 0.0);
        tracker.observe("warning: unused import\n", 1.0);
        tracker.observe("test result: ok. 41 passed; 0 failed; 0 ignored\n", 3.0);
        assert_eq!(tracker.row(3.0, &no_secrets()).unwrap().text,
            "\u{27f3} bash \u{b7} 3s \u{b7} test result: ok. 41 passed; 0 failed; 0 ignored");
    }

    #[test]
    fn a_young_call_has_no_row() {
        let tracker = Tracker::new("bash", 100.0);
        assert!(tracker.row(100.0, &no_secrets()).is_none(), "just started: the status line is enough");
        assert!(tracker.row(101.9, &no_secrets()).is_none(), "still under two seconds");
        assert!(tracker.row(102.0, &no_secrets()).is_some(), "two seconds is long enough to say something");
    }

    #[test]
    fn a_silent_call_says_so_after_three_minutes() {
        let mut tracker = Tracker::new("bash", 0.0);
        tracker.observe("Compiling x\n", 1.0);
        let row = tracker.row(1.0 + 179.0, &no_secrets()).unwrap();
        assert!(!row.stalled, "three minutes is the threshold, not before");
        assert!(row.text.contains("compiling x"));
        let stalled = tracker.row(1.0 + 180.0, &no_secrets()).unwrap();
        assert!(stalled.stalled);
        assert_eq!(stalled.text, "\u{27f3} bash \u{b7} 3m01s \u{b7} no output for 3m");
        assert!(!stalled.text.contains("compiling x"), "the stall hint replaces the detail");
        // A command that never wrote anything counts from its start.
        let quiet = Tracker::new("bash", 0.0);
        assert_eq!(quiet.row(200.0, &no_secrets()).unwrap().text,
            "\u{27f3} bash \u{b7} 3m20s \u{b7} no output for 3m20s");
        // New output clears it.
        let mut live = tracker.clone();
        live.observe("Compiling y\n", 400.0);
        assert!(!live.row(400.0, &no_secrets()).unwrap().stalled);
    }

    #[test]
    fn the_tail_keeps_the_newest_lines_and_strips_what_must_not_be_drawn() {
        let mut tracker = Tracker::new("bash", 0.0);
        // A carriage-return bar: every rewrite is a line of its own, so the newest one wins.
        tracker.observe("Receiving objects:  10% (100/1000)\rReceiving objects:  20% (200/1000)\r", 1.0);
        assert_eq!(tracker.detail(), Some(Detail::Bar { label: "receiving objects".into(), done: 200, total: 1000, percent: false }));
        // ANSI colour, a bell, a backspace: none of it reaches the row.
        let mut coloured = Tracker::new("bash", 0.0);
        coloured.observe("\u{1b}[32mCompiling\u{1b}[0m serde \u{7}\u{8}\n", 1.0);
        assert_eq!(coloured.detail(), Some(Detail::Text("compiling serde".into())));
        // A long single line is cut, and the oldest lines are dropped.
        let mut many = Tracker::new("bash", 0.0);
        for index in 0..40 { many.observe(&format!("line {index}\n"), index as f64); }
        many.observe(&format!("{}\n", "x".repeat(2000)), 41.0);
        let row = many.row(41.0, &no_secrets()).unwrap();
        assert!(row.text.chars().count() <= 40 + 400, "a minified dump is cut: {}", row.text.len());
        assert!(!row.text.contains('\n'));
    }

    #[test]
    fn a_secret_never_reaches_the_row() {
        let secrets = vec!["sk-live-9f2a4c1d8b7e6f50".to_string()];
        let mut tracker = Tracker::new("bash", 0.0);
        tracker.observe("curl -H 'authorization: Bearer sk-live-9f2a4c1d8b7e6f50' https://api\n", 1.0);
        let row = tracker.row(5.0, &secrets).unwrap();
        assert!(!row.text.contains("sk-live-9f2a4c1d8b7e6f50"), "the value is masked: {}", row.text);
        assert!(row.text.contains("<redacted>"));
        // And in the live file, so a renderer reading it cannot leak it either.
        let facts = tracker.facts(5.0, &secrets);
        assert!(!facts.to_string().contains("sk-live-9f2a4c1d8b7e6f50"), "{facts}");
        let from_file = row_from_facts(&facts, 5.0, &secrets).unwrap();
        assert!(!from_file.text.contains("sk-live-9f2a4c1d8b7e6f50"));
        // A short value is not redacted: it would mangle ordinary text.
        assert_eq!(redact("exit 0", &["0".to_string()]), "exit 0");
        assert_eq!(redact("the key is abcdefgh12", &["abcdefgh12".to_string()]), "the key is <redacted>");
    }

    // ---- the live file -------------------------------------------------------------------------
    #[test]
    fn the_live_file_draws_the_same_row_as_the_process() {
        let mut tracker = Tracker::new("bash", 1000.0);
        tracker.observe("  45%|#####     | 45.0/100.0 [00:03<00:04]\n", 1002.0);
        let facts = tracker.facts(1003.0, &no_secrets());
        assert_eq!(facts["state"], "running");
        assert_eq!(facts["tool"], "bash");
        let row = row_from_facts(&facts, 1003.0, &no_secrets()).expect("a row");
        assert_eq!(row, tracker.row(1003.0, &no_secrets()).unwrap(), "one decision, two renderers");
    }

    #[test]
    fn a_stale_or_finished_or_young_live_file_is_no_row() {
        let running = json!({"state":"running","tool":"bash","started_at":100.0,"at":200.0,
            "last_output_at":199.0,"detail":{"kind":"text","text":"compiling x"}});
        assert!(row_from_facts(&running, 205.0, &no_secrets()).is_some());
        assert!(row_from_facts(&running, 200.0 + FRESH + 1.0, &no_secrets()).is_none(), "a node that died mid-call");
        let mut done = running.clone();
        done["state"] = json!("done");
        assert!(row_from_facts(&done, 205.0, &no_secrets()).is_none(), "a settled call has no row");
        let young = json!({"state":"running","tool":"bash","started_at":204.0,"at":205.0,"last_output_at":205.0});
        assert!(row_from_facts(&young, 205.0, &no_secrets()).is_none(), "under two seconds: no row");
        assert!(row_from_facts(&json!({}), 205.0, &no_secrets()).is_none());
        // The stall rule applies to the file too.
        let quiet = json!({"state":"running","tool":"bash","started_at":0.0,"at":400.0,"last_output_at":0.0});
        let row = row_from_facts(&quiet, 400.0, &no_secrets()).unwrap();
        assert!(row.stalled);
        assert!(row.text.ends_with("no output for 6m40s"), "{}", row.text);
    }

    #[test]
    fn the_live_file_lives_where_the_build_loader_does() {
        // The three tiers of scripts/lib/build-status.sh, in the order they win. Not asserted against
        // the process environment: this crate is also used from a node whose env it must not mutate.
        assert!(data_path().ends_with("tool-progress.json"));
    }
}
