//! A long tool call's progress, drawn on the **session-status-content** row (docs/TOOL-PROGRESS.md).
//!
//! The decision - what the output's dialect says, how long the call has been silent, what the row
//! reads - is `wa-tool-progress`. This module is the *rendering* half: the colour, the clipping to one
//! row, and the live file the host writes while Lua is blocked in the call.
//!
//! Why a file and not a callback: a foreground `bash` blocks the node-thread inside the host's own
//! `host.exec`, so Lua cannot paint and cannot poll. The host's ticker (`refresh_editor_size`, every
//! 150 ms idle and on every tick of a run) *is* awake, and it can read the operation's output tail; so
//! it writes the facts here (at most four times a second) and every surface reads the same JSON:
//!
//!   * this module, for the native editor's row (`Editor::tool_progress`, drawn by `layout_frame`);
//!   * `lua/core/tool_progress.lua`, for the CLI's own layout and its transcript line;
//!   * the window (`ui/app.js`), which reads the same facts through `/health` + `/operation`.
//!
//! The file is `$WASM_AGENT_DATA/tool-progress.json` (else `$WASM_AGENT_HOME/.wasm-agent`, else
//! `$HOME/.wasm-agent`), the same tiers the build loader uses:
//! `{state: running|done, tool, started_at, at, last_output_at, detail:{kind:bar|text,...}}`.
//! A stale `at` (older than `wa_tool_progress::FRESH`) is a node that died mid-call, and shows
//! nothing rather than a frozen line.
use serde_json::Value;
use std::sync::Mutex;
use std::time::{Instant, SystemTime};
use wa_tool_progress::{Detail, Row, FRESH, MIN_SECONDS};

/// The loader's colour: the same blue `build_status` paints the rebuild line with, because this is the
/// same line and the same kind of fact.
const LOADER: &str = crate::build_status::BUILDING;
/// The stall hint is a quieter fact than the progress: dim, like the footer's hints.
const DIM: &str = "\x1b[2m";
const RESET: &str = "\x1b[0m";

/// What the row is now: a call making progress, or one that has said nothing for
/// `wa_tool_progress::STALL_SECONDS`.
#[derive(Debug, PartialEq, Clone, Copy)]
pub enum Content { Running, Stalled }

/// The facts as they read now, or `None` when there is nothing worth a row: not running, stale, or
/// younger than `MIN_SECONDS` (the status line already says `Running bash`).
pub fn facts_now(facts: &Value, now: f64) -> Option<Row> {
    if facts.get("state").and_then(Value::as_str) != Some("running") { return None; }
    let at = facts.get("at").and_then(Value::as_f64)?;
    if now - at > FRESH { return None; }
    let started_at = facts.get("started_at").and_then(Value::as_f64).unwrap_or(at);
    if now - started_at < MIN_SECONDS { return None; }
    // No secrets are passed here: the host redacted the tail before it wrote it, and the value list is
    // not this crate's to hold. `wa_tool_progress::row_from_facts` is the same decision with them.
    wa_tool_progress::row_from_facts(facts, now, &[])
}

/// `Content` from the same facts, for the renderer that reserves the row before drawing it.
pub fn content(facts: &Value, now: f64) -> Option<Content> {
    let row = facts_now(facts, now)?;
    Some(if row.stalled { Content::Stalled } else { Content::Running })
}

/// The row, coloured and clipped to `width` cells - ONE line, never wrapped. `None` = draw nothing
/// (there is no row, and the chat keeps it).
pub fn line(facts: &Value, now: f64, width: usize) -> Option<String> {
    if width == 0 { return None; }
    let row = facts_now(facts, now)?;
    let text = crate::terminal_editor::clip_cells(&row.text, width);
    if std::env::var_os("NO_COLOR").is_some() {
        return Some(text);
    }
    let colour = if row.stalled { DIM } else { LOADER };
    Some(format!("{colour}{text}{RESET}"))
}

/// How often the live file is stat-ed. The host publishes at most four times a second
/// (`wa_capabilities::tool_progress::INTERVAL_MS`), so a quarter-second check is as fresh as the file
/// can be, and it is one `stat` per tick - cheaper than the build loader's, which it shares the tick
/// with.
const REFRESH_MS: u128 = 250;

/// The live file as last read, re-read at most once a quarter second and only when its mtime moved -
/// the same cheapness as the build loader, because both are asked on the same tick.
struct Cache { checked: Option<Instant>, mtime: Option<SystemTime>, facts: Option<Value> }
static CACHE: Mutex<Cache> = Mutex::new(Cache { checked: None, mtime: None, facts: None });

fn now_epoch() -> f64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// The row to show now at `width` ("" = none), read from the live file.
pub fn current(width: usize) -> String {
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if cache.checked.is_none_or(|t| t.elapsed().as_millis() >= REFRESH_MS) {
        cache.checked = Some(Instant::now());
        let path = wa_tool_progress::data_path();
        let mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        if mtime != cache.mtime {
            cache.mtime = mtime;
            cache.facts = mtime.and_then(|_| std::fs::read_to_string(&path).ok())
                .and_then(|text| serde_json::from_str(&text).ok());
        }
    }
    let Some(facts) = cache.facts.as_ref() else { return String::new() };
    line(facts, now_epoch(), width).unwrap_or_default()
}

/// Write the facts the row is drawn from, atomically, so a reader never sees half a file.
pub fn publish(facts: &Value) -> std::io::Result<()> {
    let path = wa_tool_progress::data_path();
    if let Some(dir) = path.parent() { std::fs::create_dir_all(dir)?; }
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, serde_json::to_vec(facts)?)?;
    std::fs::rename(&temporary, &path)
}

/// Mark the call over: the file says `done`, which every renderer reads as "no row". A failed write is
/// not worth failing a run over - a stale file is bounded by `FRESH` anyway.
pub fn finish() {
    let _ = publish(&serde_json::json!({"state":"done","at":now_epoch()}));
}

/// The detail a row would draw, for a caller that wants the facts without the text (tests, and the
/// transcript line).
pub fn detail(facts: &Value) -> Option<Detail> {
    facts.get("detail").and_then(Detail::from_json)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn running(started_at: f64, at: f64, last_output_at: f64, detail: Value) -> Value {
        json!({"state":"running","tool":"bash","started_at":started_at,"at":at,
            "last_output_at":last_output_at,"detail":detail})
    }

    #[test]
    fn a_cargo_bar_is_one_coloured_row_at_the_asked_width() {
        let facts = running(1000.0, 1190.0, 1189.0,
            json!({"kind":"bar","label":"building serde_json","done":143,"total":412,"percent":false}));
        let row = line(&facts, 1190.0, 200).unwrap();
        assert!(row.starts_with(LOADER), "the loader's blue: {row:?}");
        assert!(row.ends_with(RESET));
        let plain = crate::selection::plain(&row);
        assert_eq!(plain, format!("\u{27f3} bash \u{b7} 3m10s {} 143/412 building serde_json",
            wa_tool_progress::bar(143.0 / 412.0)));
        assert_eq!(content(&facts, 1190.0), Some(Content::Running));
    }

    #[test]
    fn the_generic_last_line_is_the_row() {
        let facts = running(0.0, 5.0, 5.0, json!({"kind":"text","text":"test result: ok. 41 passed"}));
        assert_eq!(crate::selection::plain(&line(&facts, 5.0, 80).unwrap()),
            "\u{27f3} bash \u{b7} 5s \u{b7} test result: ok. 41 passed");
    }

    #[test]
    fn a_silent_call_is_a_dim_stall_hint() {
        let facts = running(0.0, 400.0, 40.0, json!({"kind":"text","text":"compiling x"}));
        let row = line(&facts, 400.0, 120).unwrap();
        assert!(row.starts_with(DIM), "the hint is dim: {row:?}");
        assert_eq!(crate::selection::plain(&row), "\u{27f3} bash \u{b7} 6m40s \u{b7} no output for 6m");
        assert_eq!(content(&facts, 400.0), Some(Content::Stalled));
    }

    #[test]
    fn the_row_is_clipped_to_the_width_and_never_wraps() {
        let facts = running(0.0, 100.0, 100.0,
            json!({"kind":"text","text":"a very long line that cannot possibly fit in a narrow terminal at all"}));
        let row = line(&facts, 100.0, 30).unwrap();
        let plain = crate::selection::plain(&row);
        let cells: usize = plain.chars().map(crate::terminal_editor::cell_width_of).sum();
        assert_eq!(cells, 30, "exactly the width asked for: {plain:?}");
        assert!(plain.ends_with('\u{2026}'), "truncated with an ellipsis: {plain:?}");
        assert!(!plain.contains('\n'));
        assert_eq!(line(&facts, 100.0, 0), None, "no columns, no row");
    }

    #[test]
    fn no_row_for_a_finished_stale_or_young_call() {
        let young = running(100.0, 100.5, 100.5, json!({"kind":"text","text":"starting"}));
        assert!(line(&young, 100.5, 80).is_none(), "under two seconds: the status line is enough");
        let stale = running(0.0, 10.0, 10.0, json!({"kind":"text","text":"x"}));
        assert!(line(&stale, 10.0 + FRESH + 1.0, 80).is_none(), "a node that died mid-call says nothing");
        assert!(line(&json!({"state":"done","at":10.0}), 11.0, 80).is_none());
        assert!(line(&json!({}), 11.0, 80).is_none());
    }

    #[test]
    fn no_colour_when_no_color_is_set() {
        // The same rule every other colour on this screen obeys: a captured transcript gets the text
        // and none of the escapes. Asserted through the shared helper so the env var is not mutated
        // for the other tests in this binary.
        let facts = running(0.0, 100.0, 100.0, json!({"kind":"text","text":"compiling x"}));
        let plain = crate::selection::plain(&line(&facts, 100.0, 80).unwrap());
        assert!(!plain.contains('\u{1b}'));
    }

    #[test]
    fn the_stall_threshold_is_the_crates_own() {
        let threshold = wa_tool_progress::STALL_SECONDS;
        let facts = running(0.0, threshold - 1.0, 0.0, json!({"kind":"text","text":"compiling x"}));
        assert_eq!(content(&facts, threshold - 1.0), Some(Content::Running), "179 s is not a stall");
        let stalled = running(0.0, threshold, 0.0, json!({"kind":"text","text":"compiling x"}));
        assert_eq!(content(&stalled, threshold), Some(Content::Stalled));
    }
}
