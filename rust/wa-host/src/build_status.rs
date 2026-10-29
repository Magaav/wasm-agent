//! A sandbox rebuild, shown in `wa chat` as one row above the input box (29/10). The build script
//! writes `$WASM_AGENT_DATA/build-status.json` (else `~/.wasm-agent`) atomically:
//! `{state: building|installed|failed, phase: context|compiling|packaging|installing|done|"exit N",
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

/// The row for `status` at `now` (unix seconds), clipped to `width` cells, or `None` (nothing to show).
pub fn line(status: &Value, now: f64, width: usize) -> Option<String> {
    let num = |k: &str| status.get(k).and_then(Value::as_f64);
    let text = |k: &str| status.get(k).and_then(Value::as_str).unwrap_or("");
    let age = now - num("at")?;
    let (colour, full, short) = match text("state") {
        "building" if age < FRESH => {
            let phase = text("phase");
            let (done, total) = (num("done").unwrap_or(0.0).max(0.0), num("total").unwrap_or(0.0));
            // `total` is an upper bound (the cargo cache skips most crates): clamp, and past compiling
            // the crates are all built.
            let fraction = match phase { "packaging" | "installing" | "done" => 1.0, "compiling" if total > 0.0 => (done / total).min(1.0), _ => 0.0 };
            let filled = (fraction * BAR as f64).round() as usize;
            let bar = format!("\u{2595}{}{}\u{258f} ", "\u{2588}".repeat(filled), "\u{2591}".repeat(BAR - filled));
            let what = match phase {
                "compiling" if total > 0.0 => format!("{}/{} compiling {}", done.min(total) as u64, total as u64, text("crate")),
                "compiling" => format!("compiling {}", text("crate")),
                other => other.to_string(),
            };
            let what = what.trim_end();
            let clock = num("started_at").map(|s| format!(" \u{b7} {}", elapsed(now - s))).unwrap_or_default();
            (BUILDING, format!("\u{27f3} building wasm-agent {bar}{what}{clock}"), format!("\u{27f3} building wasm-agent {what}{clock}"))
        }
        "installed" if age < INSTALLED_FOR => {
            let took = text("crate");
            let took = if took.is_empty() { String::new() } else { format!(" ({took})") };
            (DONE, format!("\u{2713} wasm-agent rebuilt{took} \u{2014} restarting into the new build"), String::new())
        }
        "failed" if age < FAILED_FOR => {
            let phase = text("phase");
            let why = if phase.is_empty() { String::new() } else { format!(" ({phase})") };
            (FAILED, format!("\u{2717} wasm-agent build failed{why}"), String::new())
        }
        _ => return None,
    };
    if width == 0 { return None; }
    let cells = |t: &str| t.chars().map(crate::terminal_editor::cell_width_of).sum::<usize>();
    // Narrow: the bar goes first, then the words are cut.
    let plain = if cells(&full) > width && !short.is_empty() { short } else { full };
    Some(format!("{colour}{}{RESET}", crate::terminal_editor::clip_cells(&plain, width)))
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
}
