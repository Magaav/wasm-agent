//! The row a long tool call draws, rendered here because BOTH sides draw it: the program on the
//! terminal it owns, and the node on the frame it writes while Lua is blocked. One renderer, so the two
//! can never disagree about what a running call looks like.
//!
//! MOVED OUT OF `wa-term` in the last slice of `wa-term-own-program`: this crate is what both sides
//! already depend on for the facts (`row_from_facts`, `progress_path`, `elsewhere`), so the drawing of
//! those facts belongs beside them - and the node stops needing the drawing crate for its own row.
use std::sync::Mutex;
use std::time::{Instant, SystemTime};

use serde_json::Value;

use crate::{elsewhere, progress_path, row_from_facts, Detail, Row, FRESH, MIN_SECONDS};

/// The loader's colour: the same glyph and colour the build row uses while it runs.
const LOADER: &str = "\u{1b}[38;5;214m";
/// The stall hint is a quieter fact than the progress: dim, like the footer's hints.
const DIM: &str = "\u{1b}[2m";
const RESET: &str = "\u{1b}[0m";
/// How often the live directory is looked at: the host publishes at most four times a second.
const REFRESH_MS: u128 = 250;

/// What the row is now: a call making progress, or one that has said nothing for `STALL_SECONDS`.
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
    row_from_facts(facts, now, &[])
}

/// `Content` from the same facts, for a renderer that reserves the row before drawing it.
pub fn content(facts: &Value, now: f64) -> Option<Content> {
    let row = facts_now(facts, now)?;
    Some(if row.stalled { Content::Stalled } else { Content::Running })
}

/// The row, coloured and clipped to `width` cells - ONE line, never wrapped. `None` = draw nothing.
pub fn line(facts: &Value, now: f64, width: usize) -> Option<String> {
    if width == 0 { return None; }
    let row = facts_now(facts, now)?;
    let text = clip(&row.text, width);
    if std::env::var_os("NO_COLOR").is_some() { return Some(text); }
    let colour = if row.stalled { DIM } else { LOADER };
    Some(format!("{colour}{text}{RESET}"))
}

/// What this reader last saw: its own session's file (re-read only when its mtime moved).
struct Cache { checked: Option<Instant>, mtime: Option<SystemTime>, facts: Option<Value> }
static CACHE: Mutex<Cache> = Mutex::new(Cache { checked: None, mtime: None, facts: None });

fn now_epoch() -> f64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// The row to show now at `width` ("" = none) for THIS session: only its own file is opened, and when
/// it has no row of its own but other sessions are running, the dim aggregate `node: N ops elsewhere` -
/// a count, never a name, never a line of another session's output.
pub fn current(width: usize, session: &str, elsewhere_count: usize) -> String {
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if cache.checked.is_none_or(|t| t.elapsed().as_millis() >= REFRESH_MS) {
        cache.checked = Some(Instant::now());
        let mine = progress_path(session);
        let mtime = mine.as_ref().and_then(|path| std::fs::metadata(path).and_then(|meta| meta.modified()).ok());
        if mtime != cache.mtime {
            cache.mtime = mtime;
            cache.facts = mine.as_ref().filter(|_| mtime.is_some())
                .and_then(|path| std::fs::read_to_string(path).ok())
                .and_then(|text| serde_json::from_str(&text).ok());
        }
    }
    if let Some(facts) = cache.facts.as_ref() {
        if let Some(row) = line(facts, now_epoch(), width) {
            return row;
        }
    }
    if elsewhere_count == 0 || width == 0 { return String::new() }
    let text = clip(&elsewhere(elsewhere_count), width);
    if std::env::var_os("NO_COLOR").is_some() { return text }
    format!("{DIM}{text}{RESET}")
}

/// The detail a settled call's row keeps (`{detail}` in the block): its last lines, or a bar.
pub fn detail(facts: &Value) -> Option<Detail> {
    facts.get("detail").and_then(Detail::from_json)
}

/// One line clipped to `room` terminal cells, escape sequences kept whole and counted as none.
pub fn clip(text: &str, room: usize) -> String {
    // What fits is returned whole: the mark below is for a row that was CUT, not for every row.
    fn visible(text: &str) -> usize {
        let mut total = 0usize;
        let mut chars = text.chars().peekable();
        while let Some(ch) = chars.next() {
            if ch == '\u{1b}' {
                if chars.peek() == Some(&'[') { chars.next(); for c in chars.by_ref() { if ('@'..='~').contains(&c) { break; } } }
                continue;
            }
            total += cell_width(ch);
        }
        total
    }
    if visible(text) <= room { return text.to_string() }
    let mut out = String::new();
    let mut used = 0usize;
    let mut open_colour = false;
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' {
            open_colour = true;
            out.push(ch);
            if chars.peek() == Some(&'[') {
                out.push(chars.next().unwrap());
                for c in chars.by_ref() { out.push(c); if ('@'..='~').contains(&c) { break; } }
            }
            continue;
        }
        let width = cell_width(ch);
        // One cell is kept for the mark that says the row was cut.
        if used + width + 1 > room { break; }
        out.push(ch);
        used += width;
    }
    if room > 0 {
        out.push('\u{2026}');
        // The row was cut while a colour was open: close it AFTER the mark, or the terminal paints it -
        // and whatever is drawn beside it - in a colour the row no longer claims.
        if open_colour { out.push_str(RESET); }
    }
    out
}

/// One character's width in terminal cells: the same table the transcript and the editor use
/// (`wa_term::terminal_editor::cell_width`, and `wa_capabilities::selection`'s copy of it).
fn cell_width(ch: char) -> usize {
    let cp = ch as u32;
    if (0x300..=0x36f).contains(&cp) || (0x1ab0..=0x1aff).contains(&cp)
        || (0xfe00..=0xfe0e).contains(&cp) || (0x200b..=0x200d).contains(&cp) { return 0; }
    if (0x1100..=0x115f).contains(&cp) || (0x2e80..=0xa4cf).contains(&cp)
        || (0xac00..=0xd7a3).contains(&cp) || (0xf900..=0xfaff).contains(&cp)
        || (0xfe10..=0xfe6f).contains(&cp) || (0xff01..=0xff60).contains(&cp)
        || (0x1f300..=0x1faff).contains(&cp) || wide_emoji(cp) { 2 } else { 1 }
}

fn wide_emoji(cp: u32) -> bool {
    matches!(cp, 0x231a..=0x231b | 0x23e9..=0x23ec | 0x23f0 | 0x23f3 | 0x25fd..=0x25fe | 0x2614..=0x2615
        | 0x2648..=0x2653 | 0x267f | 0x2693 | 0x26a1 | 0x26aa..=0x26ab | 0x26bd..=0x26be | 0x26c4..=0x26c5
        | 0x26ce | 0x26d4 | 0x26ea | 0x26f2..=0x26f3 | 0x26f5 | 0x26fa | 0x26fd | 0x2705 | 0x270a..=0x270b
        | 0x2728 | 0x274c | 0x274e | 0x2753..=0x2755 | 0x2757 | 0x2795..=0x2797 | 0x27b0 | 0x27bf
        | 0x2b1b..=0x2b1c | 0x2b50 | 0x2b55)
}

#[cfg(test)]
mod tests {
    /// ANSI stripped: what the reader sees.
    fn stripped(text: &str) -> String {
        let mut out = String::new();
        let mut chars = text.chars().peekable();
        while let Some(ch) = chars.next() {
            if ch == '\u{1b}' {
                if chars.peek() == Some(&'[') { chars.next(); for c in chars.by_ref() { if ('@'..='~').contains(&c) { break; } } }
                continue;
            }
            out.push(ch);
        }
        out
    }
    fn cells(ch: char) -> usize { super::cell_width(ch) }

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
        let plain = stripped(&row);
        assert_eq!(plain, format!("\u{27f3} bash \u{b7} 3m10s {} 143/412 building serde_json",
            crate::bar(143.0 / 412.0)));
        assert_eq!(content(&facts, 1190.0), Some(Content::Running));
    }

    #[test]
    fn the_generic_last_line_is_the_row() {
        let facts = running(0.0, 5.0, 5.0, json!({"kind":"text","text":"test result: ok. 41 passed"}));
        assert_eq!(stripped(&line(&facts, 5.0, 80).unwrap()),
            "\u{27f3} bash \u{b7} 5s \u{b7} test result: ok. 41 passed");
    }

    #[test]
    fn a_silent_call_is_a_dim_stall_hint() {
        let facts = running(0.0, 400.0, 40.0, json!({"kind":"text","text":"compiling x"}));
        let row = line(&facts, 400.0, 120).unwrap();
        assert!(row.starts_with(DIM), "the hint is dim: {row:?}");
        assert_eq!(stripped(&row), "\u{27f3} bash \u{b7} 6m40s \u{b7} no output for 6m");
        assert_eq!(content(&facts, 400.0), Some(Content::Stalled));
    }

    #[test]
    fn the_row_is_clipped_to_the_width_and_never_wraps() {
        let facts = running(0.0, 100.0, 100.0,
            json!({"kind":"text","text":"a very long line that cannot possibly fit in a narrow terminal at all"}));
        let row = line(&facts, 100.0, 30).unwrap();
        let plain = stripped(&row);
        let cells: usize = plain.chars().map(cells).sum();
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
        let plain = stripped(&line(&facts, 100.0, 80).unwrap());
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
        let threshold = crate::STALL_SECONDS;
        let facts = running(0.0, threshold - 1.0, 0.0, json!({"kind":"text","text":"compiling x"}));
        assert_eq!(content(&facts, threshold - 1.0), Some(Content::Running), "179 s is not a stall");
        let stalled = running(0.0, threshold, 0.0, json!({"kind":"text","text":"compiling x"}));
        assert_eq!(content(&stalled, threshold), Some(Content::Stalled));
    }
}

