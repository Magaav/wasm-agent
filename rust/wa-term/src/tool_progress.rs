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

/// How often the live directory is looked at. The host publishes at most four times a second
/// (`wa_capabilities::tool_progress::INTERVAL_MS`), so a quarter-second check is as fresh as the files
/// can be, and it is one `read_dir` per tick - cheaper than the build loader's, which it shares the
/// tick with.
const REFRESH_MS: u128 = 250;

/// What this reader last saw: **its own** session's file (re-read only when its mtime moved) and how
/// many other sessions have a live file. Both are re-derived at most once a quarter second.
struct Cache { checked: Option<Instant>, mtime: Option<SystemTime>, facts: Option<Value> }
static CACHE: Mutex<Cache> = Mutex::new(Cache { checked: None, mtime: None, facts: None });

fn now_epoch() -> f64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// How many sessions other than this one have a live file. Counted by freshness alone: a settled call
/// removes its file, so a file younger than `wa_tool_progress::FRESH` is a call still running. Nothing
/// is read out of those files - no tool, no session id, no line of output - which is the whole reason
/// the keying is per session.
fn count_elsewhere(dir: &std::path::Path, mine: Option<&std::path::Path>) -> usize {
    let Ok(entries) = std::fs::read_dir(dir) else { return 0 };
    let now = SystemTime::now();
    entries
        .flatten()
        .filter(|entry| {
            let path = entry.path();
            if path.extension().and_then(|extension| extension.to_str()) != Some("json") { return false; }
            if mine.is_some_and(|mine| mine == path) { return false; }
            entry
                .metadata()
                .and_then(|meta| meta.modified())
                .ok()
                .and_then(|mtime| now.duration_since(mtime).ok())
                .is_some_and(|age| age.as_secs_f64() <= FRESH)
        })
        .count()
}

/// The row to show now at `width` ("" = none) for **this** session.
///
/// Only the caller's own session's file is opened: the row carries that session's call's last line, and
/// drawing it for another session was the leak this keying exists to close
/// (`wa_tool_progress::progress_dir`). When this session has no row of its own but other sessions are
/// running, the row is the dim aggregate `node: N ops elsewhere` - a count, never a name, never a line.
/// `elsewhere` is the operation manager's count of the OTHER sessions' unsettled operations
/// (`operations_elsewhere`), passed in because this crate cannot reach the manager: the row says "ops",
/// and this module used to count live per-session FILES instead, so four unsettled operations in one
/// other session read as one (session isolation, item 3 round 4).
pub fn current(width: usize, session: &str, elsewhere: usize) -> String {
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    let mut elsewhere = elsewhere;
    if cache.checked.is_none_or(|t| t.elapsed().as_millis() >= REFRESH_MS) {
        cache.checked = Some(Instant::now());
        let mine = wa_tool_progress::progress_path(session);
        let mtime = mine
            .as_ref()
            .and_then(|path| std::fs::metadata(path).and_then(|meta| meta.modified()).ok());
        if mtime != cache.mtime {
            cache.mtime = mtime;
            cache.facts = mine
                .as_ref()
                .filter(|_| mtime.is_some())
                .and_then(|path| std::fs::read_to_string(path).ok())
                .and_then(|text| serde_json::from_str(&text).ok());
        }
    }
    if let Some(facts) = cache.facts.as_ref() {
        if let Some(row) = line(facts, now_epoch(), width) {
            return row;
        }
    }
    if elsewhere == 0 { return String::new() }
    if width > 0 {
        let text = crate::terminal_editor::clip_cells(&wa_tool_progress::elsewhere(elsewhere), width);
        if std::env::var_os("NO_COLOR").is_some() {
            return text;
        }
        return format!("{DIM}{text}{RESET}");
    }
    String::new()
}

/// Write one session's facts, atomically, so a reader never sees half a file.
pub fn publish(owner: &str, facts: &Value) -> std::io::Result<()> {
    let Some(path) = wa_tool_progress::progress_path(owner) else {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "tool_progress_owner_required"));
    };
    if let Some(dir) = path.parent() { std::fs::create_dir_all(dir)?; }
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, serde_json::to_vec(facts)?)?;
    std::fs::rename(&temporary, &path)
}

/// Mark that session's call over: **its** file is removed, so neither its own reader nor the aggregate
/// sees a row for a call that ended - and no other session's row is touched. A failed removal is not
/// worth failing a run over: the aggregate also stops counting a file older than `FRESH`.
pub fn finish(owner: &str) {
    if let Some(path) = wa_tool_progress::progress_path(owner) {
        let _ = std::fs::remove_file(path);
    }
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
    fn the_reader_counts_other_sessions_and_needs_no_word_of_them() {
        // The aggregate is a count of live files, never a read of one: a file younger than `FRESH` is
        // a call still running (a settled call removes its own), and the reader's own file is not
        // counted as "elsewhere".
        let dir = std::env::temp_dir().join(format!("wa-term-progress-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mine = dir.join("mine.json");
        let other = dir.join("other.json");
        std::fs::write(&mine, "{\"state\":\"running\"}").unwrap();
        std::fs::write(&other, "{\"state\":\"running\"}").unwrap();
        // A half-written file is not a row either: the publisher renames, so a `.tmp` is never counted.
        std::fs::write(dir.join("half.json.tmp"), "{}").unwrap();
        assert_eq!(count_elsewhere(&dir, Some(&mine)), 1, "the other session is counted, mine is not");
        assert_eq!(count_elsewhere(&dir, None), 2, "with no session of my own, every live file is elsewhere");
        std::fs::remove_file(&other).unwrap();
        assert_eq!(count_elsewhere(&dir, Some(&mine)), 0, "a finished call removes its file");
        // A process that died mid-call leaves one behind; age bounds it, exactly as it bounds its row.
        let stale = dir.join("stale.json");
        std::fs::write(&stale, "{\"state\":\"running\"}").unwrap();
        let old = SystemTime::now() - std::time::Duration::from_secs((FRESH as u64) + 5);
        std::fs::File::options().write(true).open(&stale).unwrap().set_modified(old).unwrap();
        assert_eq!(count_elsewhere(&dir, Some(&mine)), 0, "a stale file is not a running call");
        assert_eq!(wa_tool_progress::elsewhere(2), "node: 2 ops elsewhere");
        let _ = std::fs::remove_dir_all(&dir);
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
