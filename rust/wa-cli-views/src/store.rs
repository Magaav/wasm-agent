//! The snapshots a client keeps, and the three questions its reader thread asks them.
//!
//! The reader thread asks, in this order, and nothing else:
//!
//! 1. `route`  - the reader pressed Enter: is this line mine (`/nodes`), or the interpreter's?
//! 2. `answer` - a key came back from an open panel: draw the next level, or close?
//! 3. `publish` (from Lua) - here is a fresh stack of panels for a command.
//!
//! ## Why the run is a parameter and not a flag
//!
//! A `/` command typed *between* runs is the interpreter's: the REPL arm can re-read the roster, ask
//! the rendezvous and open the richer panel. Only *during* a run is the reader's line stranded, and
//! only then does a snapshot answer it. So `route` takes `running` and refuses to answer when it is
//! false: this crate can never take a command away from the side that could do it properly.
//!
//! ## Why nothing is ever silently dropped
//!
//! A spec that fails a check is refused with a code and a count, the previous snapshot for that
//! command stays in place, and the refusal is kept in [`Store::report`] for whoever asks. A `/nodes`
//! with no snapshot yet is not intercepted at all: the line falls through to the REPL exactly as
//! before, so the key never dies, it only takes the old path.
use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard, OnceLock};

use serde_json::{json, Value};

use crate::age::age_line;
use crate::spec::{Refusal, ViewSet, MAX_VIEWS};

/// Deepest a stack may get. A spec may not link a panel to itself, and a chain of panels is bounded
/// by the number of panels it has, so this is belt and braces around a validated spec.
const MAX_DEPTH: usize = MAX_VIEWS;

/// Where the stack is: one frame per level, each remembering which panel it is on and which option
/// the reader was standing on when they left it.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Frame {
    view: usize,
    /// 1-based, the way the panel reports it.
    focus: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Session {
    command: String,
    stack: Vec<Frame>,
}

impl Session {
    fn new(command: &str, set: &ViewSet) -> Session {
        Session {
            command: command.to_string(),
            stack: vec![Frame {
                view: 0,
                focus: set.root_focus(),
            }],
        }
    }

    fn frame(&self) -> &Frame {
        self.stack
            .last()
            .expect("a session always has its root frame")
    }

    fn frame_mut(&mut self) -> &mut Frame {
        self.stack
            .last_mut()
            .expect("a session always has its root frame")
    }

    /// Whether this stack still points into `set` after a new snapshot replaced the old one. A
    /// shorter set (a node left the roster) resets the stack instead of drawing a dangling index.
    fn survives(&self, set: &ViewSet) -> bool {
        self.stack.len() <= MAX_DEPTH && self.stack.iter().all(|frame| frame.view < set.views.len())
    }
}

/// What one line submitted during a run means.
#[derive(Debug, Clone, PartialEq)]
pub enum Route {
    /// Not this side's: hand it to the caller's normal path (the REPL's queue), unchanged.
    Repl,
    /// This side's: show this panel now. The line is *not* handed to the caller.
    Local(Value),
}

/// What the reader's answer to a panel means.
#[derive(Debug, Clone, PartialEq)]
pub enum Answer {
    /// Stay open, on this panel.
    Draw(Value),
    /// Nothing left to show: the panel closes and the draft comes back.
    Close,
}

/// What a publish did, as the caller can report it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Published {
    pub command: String,
    pub views: usize,
    pub captured_at: i64,
}

/// Counters for `Store::report`, so "the snapshot never lands" is a fact somebody can look up rather
/// than a silent nothing on a screen (AGENTS.md, "Failures are visible").
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Report {
    pub published: u64,
    pub refused: u64,
    pub last_refusal: Option<Refusal>,
    pub open: Option<String>,
}

/// The snapshots, one per command, and the stack the reader is in.
#[derive(Debug, Default)]
pub struct Store {
    sets: BTreeMap<String, ViewSet>,
    session: Option<Session>,
    published: u64,
    refused: u64,
    last_refusal: Option<Refusal>,
}

impl Store {
    pub fn new() -> Store {
        Store::default()
    }

    /// Files a snapshot. The command it is filed under must be the command the spec claims.
    ///
    /// A refusal changes nothing: the previous snapshot - which is still true, only older - keeps
    /// answering, and the refusal is reported. Losing a working `/nodes` because a newer capture was
    /// malformed would turn a display bug into a missing feature.
    pub fn publish(&mut self, command: &str, spec_json: &str) -> Result<Published, Refusal> {
        match ViewSet::parse(spec_json, command) {
            Ok(set) => {
                let published = Published {
                    command: set.command.clone(),
                    views: set.views.len(),
                    captured_at: set.captured_at,
                };
                // An open stack survives a refresh only while it still points at panels that exist;
                // otherwise the reader is put back at the root of the new snapshot. A snapshot for
                // a *different* command changes nothing: the reader is standing in another view.
                if self.session.as_ref().is_some_and(|session| {
                    session.command == set.command && !session.survives(&set)
                }) {
                    self.session = None;
                }
                self.sets.insert(set.command.clone(), set);
                self.published += 1;
                self.last_refusal = None;
                Ok(published)
            }
            Err(refusal) => {
                self.refused += 1;
                self.last_refusal = Some(refusal.clone());
                Err(refusal)
            }
        }
    }

    /// The answer `host.local_view` pushes back to Lua, so one line of glue in the caller is enough.
    pub fn publish_answer(&mut self, command: &str, spec_json: &str) -> Value {
        match self.publish(command, spec_json) {
            Ok(published) => json!({
                "ok": true,
                "command": published.command,
                "views": published.views,
                "captured_at": published.captured_at,
            }),
            Err(refusal) => refusal.answer(),
        }
    }

    /// Whether a submitted line is one of ours, and if so the panel to draw.
    ///
    /// `running` false leaves the line to the caller: between runs the REPL's own arm is the better
    /// answer, because it can read the roster again instead of showing a snapshot.
    pub fn route(&mut self, line: &str, running: bool, now: i64) -> Route {
        if !running {
            return Route::Repl;
        }
        let command = line.trim();
        let Some(set) = self.sets.get(command) else {
            return Route::Repl;
        };
        self.session = Some(Session::new(command, set));
        Route::Local(self.draw(now))
    }

    /// The reader answered the open panel: `{"action":"select","index":n}`, `{"action":"cancel"}`, or
    /// anything else, which closes. Never panics and never needs the interpreter.
    ///
    /// The decision is read out of the snapshot first and acted on afterwards, so nothing here holds
    /// a borrow of the store across a change to it - the reader thread has exactly one key press to
    /// get this right with, and a refused borrow is a panic on that thread.
    pub fn answer(&mut self, result: &Value, now: i64) -> Answer {
        /// What one keystroke asks for, decided from the snapshot alone.
        enum Decision {
            Pop,
            Push { child: usize, focus: usize },
            Close,
        }
        let decision = {
            let Some(session) = self.session.as_ref() else {
                return Answer::Close;
            };
            let Some(set) = self.sets.get(&session.command) else {
                self.session = None;
                return Answer::Close;
            };
            let frame = session.frame().clone();
            let depth = session.stack.len();
            match result.get("action").and_then(Value::as_str) {
                Some("cancel") => Decision::Pop,
                Some("select") => {
                    let index = result
                        .get("index")
                        .and_then(Value::as_u64)
                        .map(|n| n as usize)
                        .unwrap_or(0);
                    match set
                        .views
                        .get(frame.view)
                        .and_then(|view| view.options.get(index.saturating_sub(1)))
                    {
                        // A number that names no option (a redraw raced the reader): go back, do not
                        // close on them for a keystroke this side asked for.
                        None => Decision::Pop,
                        Some(option) if option.pop => Decision::Pop,
                        Some(option) => match option.view {
                            Some(child)
                                if child != frame.view
                                    && child < set.views.len()
                                    && depth < MAX_DEPTH =>
                            {
                                Decision::Push {
                                    child,
                                    focus: index.max(1),
                                }
                            }
                            // A leaf panel's Enter is its way back, the way the panel's own Enter
                            // closes a panel with nothing to choose.
                            _ => Decision::Pop,
                        },
                    }
                }
                _ => Decision::Close,
            }
        };
        match decision {
            Decision::Close => {
                self.session = None;
                Answer::Close
            }
            Decision::Pop => {
                if self.pop() {
                    Answer::Draw(self.draw(now))
                } else {
                    self.session = None;
                    Answer::Close
                }
            }
            Decision::Push { child, focus } => {
                let Some(session) = self.session.as_mut() else {
                    return Answer::Close;
                };
                session.frame_mut().focus = focus;
                session.stack.push(Frame {
                    view: child,
                    focus: 1,
                });
                Answer::Draw(self.draw(now))
            }
        }
    }

    /// Closes whatever is open (an ordinary line arrived, or the caller lost its editor).
    pub fn dismiss(&mut self) {
        self.session = None;
    }

    /// Which commands have a snapshot: what the caller can offer and what a test can assert.
    pub fn commands(&self) -> Vec<String> {
        self.sets.keys().cloned().collect()
    }

    pub fn report(&self) -> Report {
        Report {
            published: self.published,
            refused: self.refused,
            last_refusal: self.last_refusal.clone(),
            open: self.session.as_ref().map(|session| session.command.clone()),
        }
    }

    fn pop(&mut self) -> bool {
        let Some(session) = self.session.as_mut() else {
            return false;
        };
        if session.stack.len() > 1 {
            session.stack.pop();
            true
        } else {
            false
        }
    }

    /// Draws the panel the reader is standing on, with its age when the snapshot said when it was
    /// taken. The root carries the selection the reader left behind, so Back lands where they were.
    fn draw(&self, now: i64) -> Value {
        let Some(session) = self.session.as_ref() else {
            return json!({});
        };
        let Some(set) = self.sets.get(&session.command) else {
            return json!({});
        };
        let frame = session.frame();
        let Some(view) = set.views.get(frame.view) else {
            return json!({});
        };
        let mut drawn = view.clone();
        if frame.view == 0 {
            drawn.selected = Some(frame.focus.max(1));
        }
        drawn.panel_spec(age_line(now, set.captured_at))
    }
}

// ---- the process-wide seam the console reader calls ---------------------------------------------
//
// One store per process, like the console reader itself: two would split the reader's keystrokes
// between two ideas of what is open, exactly the bug the one reader exists to prevent.

static SNAPSHOTS: OnceLock<Mutex<Store>> = OnceLock::new();

/// The process's store. Also the handle a test or a future `wa capabilities` report can read.
pub fn global() -> &'static Mutex<Store> {
    SNAPSHOTS.get_or_init(|| Mutex::new(Store::new()))
}

/// A poisoned lock is a panicked *other* thread, not a reason to fail this one: the store is plain
/// data and half of an insert is still a valid store.
fn lock() -> MutexGuard<'static, Store> {
    global()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// `host.local_view(command, spec_json)` in one call: files the snapshot and answers `{"ok":...}`.
pub fn publish(command: &str, spec_json: &str) -> Value {
    lock().publish_answer(command, spec_json)
}

/// The console reader's Enter handler. `now` is seconds since the epoch, the same clock the spec's
/// `captured_at` was written with (`host.now`).
pub fn route(line: &str, running: bool, now: i64) -> Route {
    lock().route(line, running, now)
}

/// The console reader's panel-answer handler.
pub fn answer(result: &Value, now: i64) -> Answer {
    lock().answer(result, now)
}

pub fn dismiss() {
    lock().dismiss()
}

/// Seconds since the epoch, for a caller that has no clock of its own. Here rather than in the
/// caller so both sides of the age line read one clock (`host.now` is this same clock, in seconds).
pub fn now_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nodes_spec(captured_at: i64, peers: &[&str]) -> String {
        let mut views = vec![json!({
            "title": "Nodes",
            "lines": ["Cluster: rendezvous.test", format!("{} peers", peers.len())],
            "options": peers.iter().enumerate().map(|(index, name)| json!({"label": name, "hint": "online", "view": index + 1})).collect::<Vec<_>>(),
        })];
        for name in peers {
            views.push(json!({
                "title": name,
                "lines": [format!("Node id: {name}-id"), "Role: master"],
                "options": [{"label": "Back", "pop": true}],
            }));
        }
        json!({"command": "/nodes", "captured_at": captured_at, "views": views}).to_string()
    }

    #[test]
    fn a_publish_can_be_reported_and_replaced() {
        let mut store = Store::new();
        let first = store
            .publish("/nodes", &nodes_spec(1_000, &["laptop"]))
            .unwrap();
        assert_eq!(first.views, 2);
        assert_eq!(first.command, "/nodes");
        store
            .publish("/nodes", &nodes_spec(1_010, &["laptop", "phone"]))
            .unwrap();
        assert_eq!(store.commands(), vec!["/nodes".to_string()]);
        assert_eq!(store.report().published, 2);
    }

    #[test]
    fn a_refused_snapshot_leaves_the_working_one_alone() {
        let mut store = Store::new();
        store
            .publish("/nodes", &nodes_spec(1_000, &["laptop"]))
            .unwrap();
        let error = store
            .publish("/nodes", "{\"command\":\"/nodes\"}")
            .unwrap_err();
        assert_eq!(error.code, "views_missing");
        let report = store.report();
        assert_eq!(report.refused, 1);
        assert_eq!(report.last_refusal.map(|r| r.code), Some("views_missing"));
        // Still answers, with the snapshot that was true a moment ago.
        assert!(matches!(
            store.route("/nodes", true, 1_000),
            Route::Local(_)
        ));
    }

    #[test]
    fn the_answer_lua_gets_is_ok_or_a_code() {
        let mut store = Store::new();
        let ok = store.publish_answer("/nodes", &nodes_spec(1_000, &["laptop"]));
        assert_eq!(ok["ok"], true);
        assert_eq!(ok["views"], 2);
        let refused = store.publish_answer("/nodes", "not json");
        assert_eq!(refused["ok"], false);
        assert_eq!(refused["error"], "spec_unreadable");
    }

    #[test]
    fn a_snapshot_that_shrinks_puts_the_reader_back_at_the_root() {
        let mut store = Store::new();
        store
            .publish("/nodes", &nodes_spec(1_000, &["laptop", "phone"]))
            .unwrap();
        let Route::Local(root) = store.route("/nodes", true, 1_000) else {
            panic!("root")
        };
        assert_eq!(root["title"], "Nodes");
        // Open the second page, then replace the snapshot with a set with no pages at all.
        assert!(matches!(
            store.answer(&json!({"action": "select", "index": 2}), 1_000),
            Answer::Draw(_)
        ));
        store
            .publish(
                "/nodes",
                &json!({"command": "/nodes", "captured_at": 1_000, "views": [{"title": "Nodes"}]})
                    .to_string(),
            )
            .unwrap();
        // The open stack pointed at a page that no longer exists: it is gone, and cancel closes.
        assert_eq!(
            store.answer(&json!({"action": "cancel"}), 1_000),
            Answer::Close
        );
    }

    #[test]
    fn a_refresh_that_still_fits_keeps_the_reader_where_they_were() {
        let mut store = Store::new();
        store
            .publish("/nodes", &nodes_spec(1_000, &["laptop", "phone"]))
            .unwrap();
        store.route("/nodes", true, 1_000);
        assert!(matches!(
            store.answer(&json!({"action": "select", "index": 2}), 1_000),
            Answer::Draw(_)
        ));
        store
            .publish("/nodes", &nodes_spec(1_030, &["laptop", "phone"]))
            .unwrap();
        let Answer::Draw(page) = store.answer(&json!({"action": "cancel"}), 1_030) else {
            panic!("back to the list")
        };
        assert_eq!(page["title"], "Nodes");
        // Back lands on the option the reader opened.
        assert_eq!(page["selected"], 2);
    }

    #[test]
    fn an_answer_with_no_open_panel_closes_rather_than_guessing() {
        let mut store = Store::new();
        assert_eq!(
            store.answer(&json!({"action": "select", "index": 1}), 0),
            Answer::Close
        );
    }

    #[test]
    fn a_number_that_names_no_option_goes_back_instead_of_closing_on_the_reader() {
        let mut store = Store::new();
        store
            .publish("/nodes", &nodes_spec(1_000, &["laptop"]))
            .unwrap();
        store.route("/nodes", true, 1_000);
        store.answer(&json!({"action": "select", "index": 1}), 1_000);
        // On the page, option 9 does not exist: back to the list, not out of the view.
        let Answer::Draw(list) = store.answer(&json!({"action": "select", "index": 9}), 1_000)
        else {
            panic!("list")
        };
        assert_eq!(list["title"], "Nodes");
    }
}
