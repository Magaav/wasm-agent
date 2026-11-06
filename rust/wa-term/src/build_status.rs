//! A sandbox rebuild, shown in `wa chat` on the session-status-content row (see
//! `session_line`). The build script writes `$WASM_AGENT_DATA/build-status.json` (else
//! `~/.wasm-agent`) atomically:
//! `{state: building|installed|failed, phase: preflight|provisioning|fetching|compiling|proving|installing|done|...,
//! done, total, crate, commit, started_at, at}` (on `installed`, `crate` holds the elapsed time).
//! Drawn by the host, not Lua: Lua is blocked in a run and while idle on input, and the host already
//! wakes every 150 ms idle (`console_reader`) and every tick during a run (`refresh_editor_size`).
//! Stale (`at` older than `FRESH`) or absent = no row, so the chat keeps all its rows.
use serde_json::Value;
use std::sync::Mutex;
use std::time::{Instant, SystemTime};

/// A `building` status older than this is a build that died without saying so.
const FRESH: f64 = 120.0;
const INSTALLED_FOR: f64 = 30.0;
const FAILED_FOR: f64 = 60.0;
const BAR: usize = 14;
const BUILDING: &str = "\x1b[38;2;177;185;249m";
const DONE: &str = "\x1b[38;2;181;189;104m";
const FAILED: &str = "\x1b[38;2;204;102;102m";
const RESET: &str = "\x1b[0m";
/// The standing session notice's colour: the CLI view's `warning` role (`lua/core/cli_view.lua`,
/// #ffc107), so the update line is the same yellow in both renderers.
pub const NOTICE: &str = "\x1b[38;2;255;193;7m";

fn path() -> std::path::PathBuf {
    let data = std::env::var("WASM_AGENT_DATA").ok().filter(|d| !d.is_empty())
        .unwrap_or_else(|| format!("{}/.wasm-agent", std::env::var("HOME").unwrap_or_else(|_| ".".into())));
    std::path::Path::new(&data).join("build-status.json")
}

/// `125` -> `2m05s`, `45` -> `45s`, `3720` -> `1h02m`.
fn elapsed(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s >= 3600 { format!("{}h{:02}m", s / 3600, s / 60 % 60) } else if s >= 60 { format!("{}m{:02}s", s / 60, s % 60) } else { format!("{s}s") }
}

/// What the build is, if it is anything that is still worth a row: `building`, `installed` (a
/// result shown briefly) or `failed` (shown briefly, then the standing notice comes back).
#[derive(Debug, PartialEq, Clone, Copy)]
pub enum Build { Building, Installed, Failed }

/// The build facts from `status` at `now`, or `None` when the file is stale/absent/finished - the
/// same freshness rule `line` has always had, factored out so `session_line` can share it.
fn facts(status: &Value, now: f64) -> Option<(Build, &'static str, String, String)> {
    let num = |k: &str| status.get(k).and_then(Value::as_f64);
    let text = |k: &str| status.get(k).and_then(Value::as_str).unwrap_or("");
    let age = now - num("at")?;
    let (kind, colour, full, short) = match text("state") {
        "building" if age < FRESH => {
            let phase = text("phase");
            let (done, total) = (num("done").unwrap_or(0.0).max(0.0), num("total").unwrap_or(0.0));
            // `total` is an upper bound (the cargo cache skips most crates): clamp, and past compiling
            // the crates are all built.
            let fraction = match phase { "packaging" | "proving" | "installing" | "done" => 1.0, "compiling" if total > 0.0 => (done / total).min(1.0), _ => 0.0 };
            let filled = (fraction * BAR as f64).round() as usize;
            let bar = format!("\u{2595}{}{}\u{258f} ", "\u{2588}".repeat(filled), "\u{2591}".repeat(BAR - filled));
            let what = match phase {
                "compiling" if total > 0.0 => format!("{}/{} compiling {}", done.min(total) as u64, total as u64, text("crate")),
                "compiling" => format!("compiling {}", text("crate")),
                other => other.to_string(),
            };
            let what = what.trim_end();
            let clock = num("started_at").map(|s| format!(" \u{b7} {}", elapsed(now - s))).unwrap_or_default();
            (Build::Building, BUILDING, format!("\u{27f3} building wasm-agent {bar}{what}{clock}"), format!("\u{27f3} building wasm-agent {what}{clock}"))
        }
        "installed" if age < INSTALLED_FOR => {
            let took = text("crate");
            let took = if took.is_empty() { String::new() } else { format!(" ({took})") };
            (Build::Installed, DONE, format!("\u{2713} wasm-agent rebuilt{took} \u{2014} restarting into the new build"), String::new())
        }
        "failed" if age < FAILED_FOR => {
            let phase = text("phase");
            let why = if phase.is_empty() { String::new() } else { format!(" ({phase})") };
            (Build::Failed, FAILED, format!("\u{2717} wasm-agent build failed{why}"), String::new())
        }
        _ => return None,
    };
    Some((kind, colour, full, short))
}

/// One build row, clipped to `width` cells, or `None` (nothing to show).
pub fn line(status: &Value, now: f64, width: usize) -> Option<String> {
    let (_, colour, full, short) = facts(status, now)?;
    if width == 0 { return None; }
    let cells = |t: &str| t.chars().map(crate::terminal_editor::cell_width_of).sum::<usize>();
    // Narrow: the bar goes first, then the words are cut.
    let plain = if cells(&full) > width && !short.is_empty() { short } else { full };
    Some(format!("{colour}{}{RESET}", crate::terminal_editor::clip_cells(&plain, width)))
}

/// The **session-status-content** row: ONE line directly above the session status bar, reserved for
/// transient session notices, and empty (no row at all, so the chat keeps it) when there is nothing
/// to say.
///
/// Two writers share the line and the precedence is the point of this function:
///
///   * an in-flight (or just-finished) **build replaces the notice** - the loader says what the
///     terminal is actually doing, and the update notice would be a second, stale instruction while
///     it does it; a finished build shows its result for `INSTALLED_FOR`, a failed one for
///     `FAILED_FOR` and then the **notice comes back** (the failed build left the update available,
///     and the failure is also reported by the command that ran it - see `docs/RELEASE-UPDATE.md`);
///   * otherwise the standing **notice** is drawn, in the same yellow the CLI view paints it
///     (`NOTICE` = the `warning` role), so the CLI and the window cannot drift about how it looks.
///
/// `notice` is plain text (no escapes); it is clipped to `width` here, so the row can never wrap.
pub fn session_line(notice: &str, status: Option<&Value>, now: f64, width: usize) -> Option<String> {
    if width == 0 { return None; }
    if let Some(status) = status {
        if let Some(row) = line(status, now, width) { return Some(row); }
    }
    let notice = notice.trim();
    if notice.is_empty() { return None; }
    if std::env::var_os("NO_COLOR").is_some() {
        return Some(crate::terminal_editor::clip_cells(notice, width));
    }
    Some(format!("{NOTICE}{}{RESET}", crate::terminal_editor::clip_cells(notice, width)))
}

/// What the session-status-content row says now: which part of a build, the standing notice, or
/// nothing (no row - the chat keeps its last line). The editor reserves the row only when this is
/// `Some`, and the two renderers (this one and `lua/core/update_banner.lua`) decide the same thing
/// from the same facts.
#[derive(Debug, PartialEq, Clone, Copy)]
pub enum Content { Building, Installed, Failed, Notice }

/// Precedence, as `session_line` renders it: a build outranks the notice, and no row is `None`.
pub fn content(notice: &str, status: Option<&Value>, now: f64) -> Option<Content> {
    if let Some(status) = status {
        if let Some((kind, _, _, _)) = facts(status, now) {
            return Some(match kind {
                Build::Building => Content::Building,
                Build::Installed => Content::Installed,
                Build::Failed => Content::Failed,
            });
        }
    }
    if notice.trim().is_empty() { None } else { Some(Content::Notice) }
}

/// The status file as last read, re-read at most once a second and only when its mtime moved.
struct Cache { checked: Option<Instant>, mtime: Option<SystemTime>, status: Option<Value> }
static CACHE: Mutex<Cache> = Mutex::new(Cache { checked: None, mtime: None, status: None });

/// The row to show now at `width` ("" = none). Cheap: a stat a second, a read when the file changed.
pub fn current(width: usize) -> String {
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if cache.checked.is_none_or(|t| t.elapsed().as_millis() >= 1000) {
        cache.checked = Some(Instant::now());
        let path = path();
        let mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        if mtime != cache.mtime {
            cache.mtime = mtime;
            cache.status = mtime.and_then(|_| std::fs::read_to_string(&path).ok()).and_then(|t| serde_json::from_str(&t).ok());
        }
    }
    let Some(status) = cache.status.as_ref() else { return String::new() };
    let now = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
    line(status, now, width).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn plain(text: &str) -> String { crate::selection::plain(text) }
    #[test]
    fn a_build_in_flight_is_one_row_with_a_bar_and_nothing_once_stale() {
        let s: Value = serde_json::from_str(r#"{"state":"building","phase":"compiling","done":143,"total":412,"crate":"serde_json","started_at":1000,"at":1123}"#).unwrap();
        assert_eq!(plain(&line(&s, 1125.0, 100).unwrap()), format!("\u{27f3} building wasm-agent \u{2595}{}{}\u{258f} 143/412 compiling serde_json \u{b7} 2m05s",
            "\u{2588}".repeat(5), "\u{2591}".repeat(9)));
        assert!(line(&s, 1123.0 + FRESH + 1.0, 100).is_none(), "stale: a build that died silently shows nothing");
        // Past the upper bound, and packaging, are a full bar.
        let over: Value = serde_json::from_str(r#"{"state":"building","phase":"compiling","done":500,"total":412,"crate":"x","at":10}"#).unwrap();
        assert!(plain(&line(&over, 10.0, 100).unwrap()).contains("412/412"));
        let pack: Value = serde_json::from_str(r#"{"state":"building","phase":"packaging","at":10}"#).unwrap();
        assert!(plain(&line(&pack, 10.0, 100).unwrap()).contains(&format!("{}\u{258f} packaging", "\u{2588}".repeat(BAR))));
        let proving: Value = serde_json::from_str(r#"{"state":"building","phase":"proving","done":1,"total":319,"at":10}"#).unwrap();
        assert!(plain(&line(&proving, 10.0, 100).unwrap()).contains(&format!("{}\u{258f} proving", "\u{2588}".repeat(BAR))), "past compiling the crates are built");
    }
    #[test]
    fn installed_and_failed_show_for_a_while() {
        let ok: Value = serde_json::from_str(r#"{"state":"installed","phase":"done","crate":"312s","at":100}"#).unwrap();
        assert_eq!(plain(&line(&ok, 110.0, 100).unwrap()), "\u{2713} wasm-agent rebuilt (312s) \u{2014} restarting into the new build");
        assert!(line(&ok, 100.0 + INSTALLED_FOR + 1.0, 100).is_none());
        let bad: Value = serde_json::from_str(r#"{"state":"failed","phase":"exit 101","at":100}"#).unwrap();
        assert_eq!(plain(&line(&bad, 150.0, 100).unwrap()), "\u{2717} wasm-agent build failed (exit 101)");
        assert!(line(&bad, 100.0 + FAILED_FOR + 1.0, 100).is_none());
        assert!(line(&serde_json::json!({"state":"building"}), 0.0, 100).is_none(), "no `at`: nothing");
    }
    #[test]
    fn a_narrow_screen_drops_the_bar_then_cuts() {
        let s: Value = serde_json::from_str(r#"{"state":"building","phase":"compiling","done":1,"total":4,"crate":"serde","started_at":0,"at":5}"#).unwrap();
        let mid = plain(&line(&s, 5.0, 50).unwrap());
        assert_eq!(mid, "\u{27f3} building wasm-agent 1/4 compiling serde \u{b7} 5s", "no room for the bar");
        let tiny = plain(&line(&s, 5.0, 12).unwrap());
        assert!(tiny.chars().count() == 12 && tiny.ends_with('\u{2026}'), "{tiny}");
    }

    // ---- session-status-content -------------------------------------------------------------
    // The row above the session status bar: the notice when there is one, the build loader while a
    // build is in flight, no row at all when there is neither. These mirror the Lua render tests
    // (`scripts/test-cli-view.lua`) and the window's (`tests/update-banner.js`).
    const NOTICE_TEXT: &str = "Update available (cccccccccccc): run wa update or /update";

    #[test]
    fn no_notice_and_no_build_is_no_row() {
        assert_eq!(content("", None, 1.0), None);
        assert_eq!(session_line("", None, 1.0, 80), None, "nothing to say takes no line");
        assert_eq!(content("   ", None, 1.0), None, "whitespace is nothing");
    }

    #[test]
    fn the_notice_is_one_yellow_row() {
        assert_eq!(content(NOTICE_TEXT, None, 1.0), Some(Content::Notice));
        let row = session_line(NOTICE_TEXT, None, 1.0, 80).unwrap();
        assert!(row.starts_with(NOTICE), "the notice carries the warning yellow: {row:?}");
        assert!(row.ends_with(RESET));
        assert_eq!(plain(&row), NOTICE_TEXT, "and the sentence itself is untouched");
        assert!(row.contains("run wa update or /update"));
    }

    #[test]
    fn a_build_replaces_the_notice_and_the_notice_comes_back() {
        let building: Value = serde_json::from_str(r#"{"state":"building","phase":"compiling","done":1,"total":4,"crate":"serde","started_at":0,"at":5}"#).unwrap();
        assert_eq!(content(NOTICE_TEXT, Some(&building), 5.0), Some(Content::Building));
        let row = plain(&session_line(NOTICE_TEXT, Some(&building), 5.0, 80).unwrap());
        assert!(row.starts_with("\u{27f3} building wasm-agent"), "the loader is the line: {row}");
        assert!(!row.contains("Update available"), "and the notice is gone from it");
        // Finished: the result briefly, then the notice is back.
        let done: Value = serde_json::from_str(r#"{"state":"installed","crate":"312s","at":5}"#).unwrap();
        assert_eq!(content(NOTICE_TEXT, Some(&done), 6.0), Some(Content::Installed));
        assert_eq!(content(NOTICE_TEXT, Some(&done), 6.0 + INSTALLED_FOR + 1.0), Some(Content::Notice),
            "the result is shown briefly and then the row is the notice again");
        assert_eq!(plain(&session_line(NOTICE_TEXT, Some(&done), 6.0 + INSTALLED_FOR + 1.0, 80).unwrap()), NOTICE_TEXT);
        // Failed: the failure is visible first, and then the notice comes back - a failed build
        // leaves the update available, so the notice is never lost.
        let failed: Value = serde_json::from_str(r#"{"state":"failed","phase":"exit 101","at":5}"#).unwrap();
        assert_eq!(content(NOTICE_TEXT, Some(&failed), 6.0), Some(Content::Failed));
        assert!(plain(&session_line(NOTICE_TEXT, Some(&failed), 6.0, 80).unwrap()).contains("build failed (exit 101)"));
        assert_eq!(content(NOTICE_TEXT, Some(&failed), 6.0 + FAILED_FOR + 1.0), Some(Content::Notice));
        assert_eq!(plain(&session_line(NOTICE_TEXT, Some(&failed), 6.0 + FAILED_FOR + 1.0, 80).unwrap()), NOTICE_TEXT,
            "after the failure has been shown, the notice is back");
        // A build that died without saying so is not a row either.
        let stale: Value = serde_json::from_str(r#"{"state":"building","at":5}"#).unwrap();
        assert_eq!(content(NOTICE_TEXT, Some(&stale), 5.0 + FRESH + 1.0), Some(Content::Notice));
    }

    #[test]
    fn a_narrow_row_truncates_with_an_ellipsis() {
        let row = session_line(NOTICE_TEXT, None, 1.0, 40).unwrap();
        let cells = |t: &str| t.chars().map(crate::terminal_editor::cell_width_of).sum::<usize>();
        assert_eq!(cells(&plain(&row)), 40, "exactly the width asked for: {row:?}");
        assert!(plain(&row).ends_with('\u{2026}'), "truncated with an ellipsis, never wrapped");
        assert!(!plain(&row).contains('\n'));
        assert_eq!(session_line(NOTICE_TEXT, None, 1.0, 0), None, "no columns, no row");
        // A width wider than the sentence is the sentence.
        assert_eq!(plain(&session_line(NOTICE_TEXT, None, 1.0, 200).unwrap()), NOTICE_TEXT);
    }
}
