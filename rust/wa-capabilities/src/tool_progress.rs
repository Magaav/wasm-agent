//! The live facts behind a long tool call's row (`docs/TOOL-PROGRESS.md`).
//!
//! The row itself is decided in `wa-tool-progress` and drawn in `wa_term::tool_progress`; this module
//! is the one place that *feeds* it. It exists because of a structural fact: a foreground `bash`
//! blocks the node-thread inside `host.exec`, so neither Lua nor the view can poll while the call
//! runs. The operation supervisor's own wait loop is awake every 100 ms, and it already owns the
//! operation's output files - so it reads the tail there, at most four times a second, and publishes
//! the facts to `$WASM_AGENT_DATA/tool-progress.json`. Every surface then reads one file:
//!
//!   * `wa_term::tool_progress` for the native editor's session-status-content row (drawn by the
//!     host's ticker, which is awake while Lua is blocked);
//!   * `lua/core/tool_progress.lua` for the CLI's own layout and its transcript line;
//!   * the window, which reads `/health` + `/operation` itself and renders the same wording.
//!
//! Three bounds, because this runs inside somebody else's wait loop:
//!
//! * **at most four writes a second** ([`INTERVAL_MS`]) - a reader cannot read faster, and the row
//!   must not become a file-write storm;
//! * **a grow-only byte cursor per operation**, so the cost is the output's own size and no line is
//!   read twice;
//! * **the output file, never the process**: the tail is the already-redacted bytes
//!   `wa-operation` wrote, so the row cannot contain a secret the redactor removed, and reading it
//!   cannot disturb the call.
//!
//! The final tool result is untouched: nothing here is on the result path, and a failure to write the
//! file is dropped (`publish` returns `io::Result` and the callers ignore it). A stale file shows
//! nothing after `wa_tool_progress::FRESH` seconds anyway.
use serde_json::Value;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};
use wa_tool_progress::Tracker;

/// How often the facts are refreshed: four times a second, which is faster than a reader can read and
/// slow enough that a build's 100 ms wait loop is not turned into a file-write loop.
pub const INTERVAL_MS: u64 = 250;
/// How much of the output's own bytes are read per tick. A compiler can print megabytes; the row needs
/// the newest lines, and the cursor means nothing is read twice.
const CHUNK: u64 = 32 * 1024;
/// The tail of each stream, for the first read of a call that has already written a lot.
const FIRST_READ: u64 = 8 * 1024;

struct Live { id: String, tracker: Tracker, cursor: u64, errors: u64 }
static LIVE: Mutex<Option<Live>> = Mutex::new(None);
static LAST: Mutex<Option<Instant>> = Mutex::new(None);

pub fn now_epoch() -> f64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// The bytes written to `path` since `cursor`, and where the cursor now is. A missing file is no
/// output yet, not a failure.
fn read_since(path: &str, cursor: u64) -> Option<(String, u64)> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    // A call that has written more than one chunk before we looked: skip to the last `FIRST_READ`
    // bytes rather than replaying a build log line by line.
    let start = if cursor == 0 && len > FIRST_READ { len - FIRST_READ } else { cursor.min(len) };
    if start >= len { return Some((String::new(), len)); }
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut buffer = vec![0u8; (len - start).min(CHUNK) as usize];
    let read = file.read(&mut buffer).ok()?;
    buffer.truncate(read);
    Some((String::from_utf8_lossy(&buffer).into_owned(), start + read as u64))
}

/// Refresh the row for operation `id`: read whatever its two streams have written since the last tick
/// and publish the facts. `tool` is the name the reader knows the call by (`bash`), `started_at` epoch
/// seconds. Returns the facts when they were refreshed, `None` when this tick was throttled.
///
/// Both streams matter: a compiler writes its `Compiling`/`Building` progress to **stderr** and a test
/// runner writes its results to **stdout**. They are fed stderr first, so that when both wrote, the
/// newest line the row falls back to is the one on stdout - what a reader watching a terminal would
/// have seen last - while a build that says nothing on stdout still shows its compile progress.
pub fn tick(id: &str, tool: &str, started_at: f64, stdout_path: &str, stderr_path: &str) -> Option<Value> {
    {
        let mut last = LAST.lock().unwrap_or_else(|e| e.into_inner());
        if last.is_some_and(|at| at.elapsed() < Duration::from_millis(INTERVAL_MS)) { return None; }
        *last = Some(Instant::now());
    }
    let now = now_epoch();
    let mut live = LIVE.lock().unwrap_or_else(|e| e.into_inner());
    let current = match live.as_mut() {
        Some(current) if current.id == id => current,
        _ => {
            *live = Some(Live { id: id.to_string(), tracker: Tracker::new(tool, started_at), cursor: 0, errors: 0 });
            live.as_mut().expect("just set")
        }
    };
    feed(current, stdout_path, stderr_path, now);
    let facts = current.tracker.facts(now, &wa_tool_progress::env_secrets());
    let _ = wa_term::tool_progress::publish(&facts);
    Some(facts)
}

/// Read whatever both streams wrote since the last tick, stderr first and stdout last (see `tick`).
fn feed(current: &mut Live, stdout_path: &str, stderr_path: &str, now: f64) {
    if let Some((chunk, cursor)) = read_since(stderr_path, current.errors) {
        current.errors = cursor;
        if !chunk.is_empty() { current.tracker.observe(&chunk, now); }
    }
    if let Some((chunk, cursor)) = read_since(stdout_path, current.cursor) {
        current.cursor = cursor;
        if !chunk.is_empty() { current.tracker.observe(&chunk, now); }
    }
}

/// The call is over (settled, cancelled or failed): the row goes away. Not on a timer - the operation
/// record is what says the call ended, so the row cannot outlive it by more than the freshness window.
pub fn finish(id: &str) {
    let mut live = LIVE.lock().unwrap_or_else(|e| e.into_inner());
    let mine = live.as_ref().is_some_and(|current| current.id == id);
    if mine { *live = None; }
    if mine { wa_term::tool_progress::finish(); }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_path(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("wa-tool-progress-{}-{}", std::process::id(), name));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("stdout")
    }

    #[test]
    fn the_cursor_reads_each_byte_once_and_the_tracker_sees_it() {
        let path = temp_path("cursor");
        std::fs::write(&path, "Compiling serde v1.0\n").unwrap();
        let (first, cursor) = read_since(path.to_str().unwrap(), 0).unwrap();
        assert_eq!(first, "Compiling serde v1.0\n");
        // Nothing new: an empty chunk and the same cursor.
        let (again, same) = read_since(path.to_str().unwrap(), cursor).unwrap();
        assert_eq!((again.as_str(), same), ("", cursor));
        // Appended bytes are the only thing read the second time.
        std::fs::write(&path, "Compiling serde v1.0\nBuilding [=> ] 3/9: serde\n").unwrap();
        let (new, moved) = read_since(path.to_str().unwrap(), cursor).unwrap();
        assert_eq!(new, "Building [=> ] 3/9: serde\n");
        assert!(moved > cursor);
        // A file that does not exist yet is "no output", not an error.
        assert_eq!(read_since(path.with_extension("missing").to_str().unwrap(), 0).map(|(t, _)| t), None);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_long_backlog_starts_at_its_tail_rather_than_replaying_it() {
        let path = temp_path("backlog");
        std::fs::write(&path, "x".repeat(FIRST_READ as usize + 5000)).unwrap();
        let (chunk, cursor) = read_since(path.to_str().unwrap(), 0).unwrap();
        assert_eq!(chunk.len() as u64, FIRST_READ, "only the tail of a big backlog");
        assert_eq!(cursor, FIRST_READ + 5000);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn both_streams_are_read_and_stdout_has_the_last_word() {
        // A compiler writes its progress to stderr and a test runner its results to stdout: the row
        // must see both, and the line it falls back to is the one on stdout (what a reader watching a
        // terminal would have seen last).
        let dir = std::env::temp_dir().join(format!("wa-tool-progress-both-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (out, err) = (dir.join("stdout"), dir.join("stderr"));
        std::fs::write(&out, "").unwrap();
        std::fs::write(&err, "").unwrap();
        let mut live = Live { id: "op-1".into(), tracker: Tracker::new("bash", 0.0), cursor: 0, errors: 0 };
        // The build speaks on stderr only: that is the row.
        std::fs::write(&err, "    Building [=====>    ] 143/412: serde_json, syn
").unwrap();
        feed(&mut live, out.to_str().unwrap(), err.to_str().unwrap(), 100.0);
        let detail = live.tracker.detail().expect("a detail");
        assert!(matches!(detail, wa_tool_progress::Detail::Bar { done: 143, total: 412, .. }), "{detail:?}");
        // Then the tests speak on stdout. While the runner's lines are still inside the four-line
        // window the build's bar is allowed to speak (`wa-tool-progress`'s `RECENT`), so the row is
        // the bar for a moment...
        std::fs::write(&out, "     Running unittests src/lib.rs
running 41 tests
").unwrap();
        feed(&mut live, out.to_str().unwrap(), err.to_str().unwrap(), 150.0);
        assert!(matches!(live.tracker.detail(), Some(wa_tool_progress::Detail::Bar { .. })),
            "{:?}", live.tracker.detail());
        // ...and once the results are the newest lines, the last line is the answer.
        std::fs::write(&out, "     Running unittests src/lib.rs
running 41 tests
test a::one ... ok
test result: ok. 41 passed; 0 failed
").unwrap();
        feed(&mut live, out.to_str().unwrap(), err.to_str().unwrap(), 200.0);
        assert_eq!(live.tracker.detail(), Some(wa_tool_progress::Detail::Text("test result: ok. 41 passed; 0 failed".into())));
        // Nothing new on either stream is no output at all: the stall clock keeps running.
        feed(&mut live, out.to_str().unwrap(), err.to_str().unwrap(), 400.0);
        assert_eq!(live.tracker.last_output_at(), 200.0, "an empty read is not output");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_interval_is_four_updates_a_second() {
        assert_eq!(INTERVAL_MS, 250);
    }
}
