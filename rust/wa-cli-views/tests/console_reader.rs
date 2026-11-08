//! The console reader's two decisions, exercised the way the reader thread makes them.
//!
//! The rule Victor reported is a *sequencing* rule and nothing else: while a turn is running, a
//! `/nodes` must be answered on the spot and must not become an entry in the queue the turn will hand
//! to the model or to the REPL afterwards. So this test owns a tiny stand-in for
//! `rust/wa-capabilities/src/host.rs`'s `ConsoleInput` - a queue, an optional panel and the snapshot
//! store - and drives it exactly as the real one does: `route` on Submit, `answer` on the panel's
//! result. If the sequencing here is wrong, the integration is wrong; the glue that copies this shape
//! into the reader thread is three lines and adds no rule of its own.
use serde_json::{json, Value};
use wa_cli_views::{Answer, Route, Store};

/// The reader thread, as far as snapshots are concerned.
#[derive(Default)]
struct Reader {
    /// `state.lines`: what waits for the interpreter - the REPL's queue and the run's steering.
    queue: Vec<String>,
    /// `state.panel`: what is drawn over the draft right now.
    panel: Option<Value>,
    /// `state.status_snapshot`'s newer sibling: the snapshots Lua published.
    views: Store,
}

impl Reader {
    fn submit(&mut self, line: &str, running: bool, now: i64) {
        match self.views.route(line, running, now) {
            // The line is answered here: drawn now, and *not* queued behind the run.
            Route::Local(spec) => self.panel = Some(spec),
            // Everything else is what it was before this crate: one entry in the queue.
            Route::Repl => self.queue.push(line.to_string()),
        }
    }

    fn key(&mut self, result: Value, now: i64) {
        if self.panel.is_none() {
            return;
        }
        match self.views.answer(&result, now) {
            Answer::Draw(spec) => self.panel = Some(spec),
            Answer::Close => self.panel = None,
        }
    }

    fn title(&self) -> Option<&str> {
        self.panel
            .as_ref()
            .and_then(|panel| panel["title"].as_str())
    }
}

const CAPTURED_AT: i64 = 1_700_000_000;

/// The stack `lua/core/nodes_cli.lua` publishes for this node and one peer.
fn nodes_spec() -> String {
    json!({
        "command": "/nodes",
        "captured_at": CAPTURED_AT,
        "views": [
            {
                "title": "Nodes",
                "lines": ["Cluster: rendezvous.example:8787", "1 peer"],
                "options": [
                    {"label": "laptop (this node)", "hint": "master \u{b7} local \u{b7} 1a2b3c4d", "view": 1},
                    {"label": "phone", "hint": "guest \u{b7} online \u{b7} 5e6f7a8b", "view": 2},
                ],
                "selected": 1,
            },
            {
                "title": "laptop (this node)",
                "lines": ["Node id: 1a2b3c4d", "Role: master   this node"],
                "options": [{"label": "Back", "pop": true}],
            },
            {
                "title": "phone",
                "lines": ["Node id: 5e6f7a8b", "Role: guest   online"],
                "options": [{"label": "Back", "pop": true}],
            },
        ],
    })
    .to_string()
}

fn reader_with_nodes() -> Reader {
    let mut reader = Reader::default();
    assert_eq!(
        reader
            .views
            .publish("/nodes", &nodes_spec())
            .map(|published| published.views),
        Ok(3)
    );
    reader
}

#[test]
fn submit_during_a_run_answers_locally_and_queues_nothing() {
    let mut reader = reader_with_nodes();
    reader.submit("/nodes", true, CAPTURED_AT);

    // The view is on screen now ...
    assert_eq!(reader.title(), Some("Nodes"));
    let options = reader.panel.as_ref().unwrap()["options"]
        .as_array()
        .unwrap()
        .clone();
    assert_eq!(options.len(), 2, "one option per node");
    assert_eq!(options[1]["label"], "phone");
    assert_eq!(options[1]["hint"], "guest \u{b7} online \u{b7} 5e6f7a8b");
    // ... and nothing was queued behind the turn, for the model or for the REPL.
    assert!(
        reader.queue.is_empty(),
        "the line must not become a queue entry: {:?}",
        reader.queue
    );
}

#[test]
fn a_node_page_opens_and_escape_walks_back_without_the_run_noticing() {
    let mut reader = reader_with_nodes();
    reader.submit("/nodes", true, CAPTURED_AT);
    reader.key(json!({"action": "select", "index": 2}), CAPTURED_AT);
    assert_eq!(reader.title(), Some("phone"));
    assert!(reader.panel.as_ref().unwrap()["lines"]
        .as_array()
        .unwrap()
        .iter()
        .any(|line| line == "Node id: 5e6f7a8b"));

    // "Back" (the page's only option) returns to the list, on the node just opened.
    reader.key(json!({"action": "select", "index": 1}), CAPTURED_AT);
    assert_eq!(reader.title(), Some("Nodes"));
    assert_eq!(
        reader.panel.as_ref().unwrap()["selected"],
        2,
        "the reader lands where they were"
    );

    // Esc at the root closes the view; the reader has their draft back.
    reader.key(json!({"action": "cancel"}), CAPTURED_AT);
    assert_eq!(reader.panel, None);
    // Through all of it the run's queue stayed empty.
    assert!(reader.queue.is_empty());
}

#[test]
fn the_same_line_between_runs_is_left_to_the_repl() {
    let mut reader = reader_with_nodes();
    reader.submit("/nodes", false, CAPTURED_AT);
    assert_eq!(
        reader.panel, None,
        "between runs the REPL arm reads the roster again: it is the better answer"
    );
    assert_eq!(reader.queue, vec!["/nodes".to_string()]);
}

#[test]
fn a_command_with_arguments_is_an_operation_and_stays_in_the_queue() {
    let mut reader = reader_with_nodes();
    reader.submit("/nodes pending", true, CAPTURED_AT);
    assert_eq!(
        reader.panel, None,
        "`/nodes pending` is a binding request, not a read"
    );
    assert_eq!(reader.queue, vec!["/nodes pending".to_string()]);
}

#[test]
fn an_ordinary_message_still_queues_for_the_run() {
    let mut reader = reader_with_nodes();
    reader.submit("and then check the roster", true, CAPTURED_AT);
    assert_eq!(reader.panel, None);
    assert_eq!(reader.queue, vec!["and then check the roster".to_string()]);
}

#[test]
fn a_command_with_no_snapshot_yet_takes_the_old_path_rather_than_dying() {
    let mut reader = Reader::default();
    reader.submit("/nodes", true, CAPTURED_AT);
    assert_eq!(reader.panel, None);
    assert_eq!(
        reader.queue,
        vec!["/nodes".to_string()],
        "no snapshot: the REPL answers it after the turn, as before"
    );
}

#[test]
fn the_panel_says_how_old_the_data_is() {
    let mut reader = reader_with_nodes();
    reader.submit("/nodes", true, CAPTURED_AT + 130);
    let lines: Vec<String> = reader.panel.as_ref().unwrap()["lines"]
        .as_array()
        .unwrap()
        .iter()
        .map(|line| line.as_str().unwrap_or_default().to_string())
        .collect();
    assert_eq!(
        lines.last().map(String::as_str),
        Some("snapshot 2m ago"),
        "lines: {lines:?}"
    );
}

#[test]
fn a_malformed_snapshot_never_replaces_a_working_one() {
    let mut reader = reader_with_nodes();
    let refused = reader
        .views
        .publish("/nodes", "{\"command\":\"/nodes\",\"views\":[]}")
        .unwrap_err();
    assert_eq!(refused.code, "views_missing");
    assert_eq!(
        reader.views.report().refused,
        1,
        "the refusal is counted, not swallowed"
    );
    reader.submit("/nodes", true, CAPTURED_AT);
    assert_eq!(
        reader.title(),
        Some("Nodes"),
        "the older snapshot is still true, only older"
    );
}

#[test]
fn two_read_only_views_do_not_share_a_stack() {
    let mut reader = reader_with_nodes();
    let wakes = json!({"command": "/wakes", "captured_at": CAPTURED_AT, "views": [{"title": "Wakes", "lines": ["no pending wakes"]}]});
    reader.views.publish("/wakes", &wakes.to_string()).unwrap();
    reader.submit("/nodes", true, CAPTURED_AT);
    reader.key(json!({"action": "select", "index": 1}), CAPTURED_AT);
    assert_eq!(reader.title(), Some("laptop (this node)"));
    // A second command's snapshot landing does not disturb the stack that is open.
    reader.views.publish("/wakes", &wakes.to_string()).unwrap();
    reader.key(json!({"action": "cancel"}), CAPTURED_AT);
    assert_eq!(reader.title(), Some("Nodes"));
}
