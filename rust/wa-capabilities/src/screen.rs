//! The transcript's handle in the node: THE SAME CALLS, answered by the terminal program
//! (`rust/wa-term/src/bin/wa-term.rs`) over `wa-term-proto`.
//!
//! There is ONE path now. The in-process `Transcript` was deleted in the last slice of
//! `wa-term-own-program`: its answers are recorded in `tests/golden/term_log.txt` (captured from the
//! old path before it went) and the wire is compared against that file on every run, so the move is
//! judged by the bytes it replaced. A display-only change is now built into `wa-term` and installed
//! there; the node is not rebuilt for it.
//!
//! Refusals, never a silent fallback: the first call attaches - the program is looked for at
//! `WA_TERM_BIN`, then beside this executable, then on `PATH` (`term_program_missing` names the
//! three) - and the handshake compares protocol numbers (`term_protocol_mismatch` names both). A
//! failure STICKS: every later call draws nothing, and the name is printed once to stderr.
use std::cell::RefCell;
use std::io::{BufReader, BufWriter};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde_json::{json, Value};
use wa_term_proto::{self as proto, Failure};

/// The scrollbar as the node reads it back from the program's last frame: what a press is measured
/// against. It is `wa_term::scroll::bar::Bar`'s four numbers, in the node's own words now that the
/// node no longer links that crate.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bar {
    pub track: usize,
    pub total: usize,
    pub first: usize,
    pub active: bool,
}

impl Bar {
    /// Whether there is anything to scroll: a chat that fits its region has a bar that no click can
    /// move, and a click on it says nothing.
    pub fn scrolling(&self) -> bool { self.total > self.track }
}

/// The input box's state, as the program's own `Editor` answers it (`editor_state` on the wire):
/// every number the node used to read off the struct when it held the editor in process.
#[derive(Clone, Debug, Default)]
pub struct EditorState {
    pub row: usize,
    pub width: usize,
    pub height: usize,
    pub status: bool,
    pub out_bottom: usize,
    pub status_row: usize,
    pub footer_row: usize,
    pub session_row: usize,
    pub wakes_row: usize,
    pub bottom: usize,
    pub box_rows: Option<(usize, usize)>,
    pub menu_rows: usize,
    pub draft: String,
    pub selection: Option<(usize, usize)>,
    pub empty: bool,
    pub bash: bool,
    pub pasting: bool,
    pub footer: String,
    pub footer_right: String,
    pub wakes_content: String,
    pub session_content: String,
    pub cursor_frame: String,
}

/// A key's answer in the node's own words, decoded from the program's `editor_key` reply. The console
/// loop matches on this exactly where it used to match `wa_term::terminal_editor::Action`.
#[derive(Clone, Debug, PartialEq)]
pub enum EditorAction {
    None,
    Submit(String),
    SubmitNow(String),
    Eof,
    Interrupt,
    Nav,
    PageUp,
    PageDown,
    Bottom,
    Copy(String),
    Paste,
    Pasted(usize),
}

/// The state the node SETS on the editor, one call per change: what the console knows and the editor
/// draws. Absent fields keep what the editor has, so a change sends only what changed (`editor_setup`).
#[derive(Clone, Debug, Default)]
pub struct EditorSetup {
    pub row: Option<usize>,
    pub width: Option<usize>,
    pub height: Option<usize>,
    pub status: Option<bool>,
    pub bash: Option<bool>,
    pub queued: Option<Vec<String>>,
    pub history: Option<Vec<String>>,
    pub wakes: Option<String>,
    pub build: Option<String>,
    pub session_notice: Option<String>,
    pub footer: Option<String>,
    pub footer_right: Option<String>,
    /// The slash menu's commands: `(name, takes args, hint)`.
    pub commands: Option<Vec<(String, bool, String)>>,
}

impl EditorSetup {
    /// The whole object the wire takes, omitting what this change does not touch.
    fn to_json(&self) -> Value {
        let mut spec = serde_json::Map::new();
        if let Some(row) = self.row { spec.insert("row".into(), json!(row)); }
        if let Some(width) = self.width { spec.insert("width".into(), json!(width)); }
        if let Some(height) = self.height { spec.insert("height".into(), json!(height)); }
        if let Some(status) = self.status { spec.insert("status".into(), json!(status)); }
        if let Some(bash) = self.bash { spec.insert("bash".into(), json!(bash)); }
        if let Some(queued) = &self.queued { spec.insert("queued".into(), json!(queued)); }
        if let Some(history) = &self.history { spec.insert("history".into(), json!(history)); }
        if let Some(value) = &self.wakes { spec.insert("wakes".into(), json!(value)); }
        if let Some(value) = &self.build { spec.insert("build".into(), json!(value)); }
        if let Some(value) = &self.session_notice { spec.insert("session_notice".into(), json!(value)); }
        if let Some(value) = &self.footer { spec.insert("footer".into(), json!(value)); }
        if let Some(value) = &self.footer_right { spec.insert("footer_right".into(), json!(value)); }
        if let Some(commands) = &self.commands {
            let list: Vec<Value> = commands.iter()
                .map(|(name, args, hint)| json!({ "name": name, "args": args, "hint": hint }))
                .collect();
            spec.insert("commands".into(), json!(list));
        }
        Value::Object(spec)
    }
}

/// An action decoded from the wire: the tag the program sent, never a guess.
fn editor_action(value: &Value) -> EditorAction {
    let text = || value.get("text").and_then(Value::as_str).unwrap_or_default().to_string();
    match value.get("kind").and_then(Value::as_str).unwrap_or("none") {
        "submit" => EditorAction::Submit(text()),
        "submit_now" => EditorAction::SubmitNow(text()),
        "eof" => EditorAction::Eof,
        "interrupt" => EditorAction::Interrupt,
        "nav" => EditorAction::Nav,
        "page_up" => EditorAction::PageUp,
        "page_down" => EditorAction::PageDown,
        "bottom" => EditorAction::Bottom,
        "copy" => EditorAction::Copy(text()),
        "paste" => EditorAction::Paste,
        "pasted" => EditorAction::Pasted(value.get("from").and_then(Value::as_u64).unwrap_or(0) as usize),
        _ => EditorAction::None,
    }
}

fn editor_state_of(value: &Value) -> EditorState {
    let number = |key: &str| value.get(key).and_then(Value::as_u64).unwrap_or(0) as usize;
    let boolean = |key: &str| value.get(key).and_then(Value::as_bool).unwrap_or(false);
    let line = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
    let pair = |key: &str| value.get(key).and_then(Value::as_array).and_then(|pair| {
        Some((pair.first()?.as_u64()? as usize, pair.get(1)?.as_u64()? as usize))
    });
    EditorState {
        row: number("row"),
        width: number("width"),
        height: number("height"),
        status: boolean("status"),
        out_bottom: number("out_bottom"),
        status_row: number("status_row"),
        footer_row: number("footer_row"),
        session_row: number("session_row"),
        wakes_row: number("wakes_row"),
        bottom: number("bottom"),
        box_rows: pair("box_rows"),
        menu_rows: number("menu_rows"),
        draft: line("draft"),
        selection: pair("selection"),
        empty: boolean("empty"),
        bash: boolean("bash"),
        pasting: boolean("pasting"),
        footer: line("footer"),
        footer_right: line("footer_right"),
        wakes_content: line("wakes_content"),
        session_content: line("session_content"),
        cursor_frame: line("cursor_frame"),
    }
}

/// The console's transcript, answered by the terminal program.
pub struct Screen {
    remote: Remote,
}

impl Default for Screen {
    fn default() -> Self { Screen { remote: Remote::new(None) } }
}

impl Screen {
    /// A handle whose program's path is stated instead of looked for: the console looks it up
    /// (`WA_TERM_BIN`, beside the executable, `PATH`), and a test names the binary it built.
    pub fn remote_at(program: impl Into<std::path::PathBuf>) -> Screen { Screen { remote: Remote::new(Some(program.into())) } }

    /// The refusal that must stop the console from starting, if there is one: the program is not
    /// there, or it speaks another protocol. `None` once the program has answered the handshake.
    pub fn attach_error(&mut self) -> Option<Failure> { self.remote.attach().err() }

    /// Whether the console has a frame to draw: every reply carries the program's `dirty` flag.
    pub fn dirty(&self) -> bool { self.remote.dirty() }

    /// The node says a frame is due (a resize is the node's own reason and never reaches the
    /// program): the flag is kept here and ORed with the program's until the frame is out.
    pub fn mark_dirty(&mut self) { self.remote.mark_dirty() }

    /// The frame is out: the flag is cleared on both sides, so the next tick draws nothing.
    pub fn clean(&mut self) { self.remote.clean() }

    pub fn write(&mut self, text: &str) {
        self.remote.nothing("write", json!([text]))
    }
    pub fn write_marked(&mut self, text: &str, request: bool) {
        self.remote.nothing("write_marked", json!([text, request]))
    }
    pub fn block(&mut self, topic: bool) {
        self.remote.nothing("block", json!([topic]))
    }
    pub fn code_block(&mut self) {
        self.remote.nothing("code_block", json!([]))
    }
    pub fn fold_code(&mut self, summary: &str) -> bool {
        self.remote.want_bool("fold_code", json!([summary]))
    }
    pub fn head(&mut self, text: &str) -> bool {
        self.remote.want_bool("head", json!([text]))
    }
    pub fn live(&mut self, text: Option<&str>) {
        self.remote.nothing("live", json!([text]))
    }
    pub fn rewrite(&mut self, offset: isize, text: &str) -> bool {
        self.remote.want_bool("rewrite", json!([offset, text]))
    }
    pub fn pin_toggle(&mut self) -> Option<bool> {
        self.remote.want("pin_toggle", json!([])).ok().and_then(|value| value.as_bool())
    }
    pub fn copyable(&mut self, markers: &[(usize, String)]) {
        self.remote.nothing("copyable", json!([markers]))
    }
    pub fn expandable(&mut self, markers: &[(usize, String)]) {
        self.remote.nothing("expandable", json!([markers]))
    }
    pub fn cardable(&mut self, ranges: &[(usize, usize)]) {
        self.remote.nothing("cardable", json!([ranges]))
    }
    pub fn copy_first(&mut self, text: &str) -> bool {
        self.remote.want_bool("copy_first", json!([text]))
    }
    pub fn copy_at(&self, row: usize, col: usize) -> Option<String> {
        self.remote.want("copy_at", json!([row, col])).ok().and_then(|value| value.as_str().map(str::to_string))
    }
    pub fn copy_hover(&mut self, row: usize, col: usize) -> bool {
        self.remote.want_bool("copy_hover", json!([row, col]))
    }
    pub fn expand_at(&mut self, row: usize) -> bool {
        self.remote.want_bool("expand_at", json!([row]))
    }
    pub fn expand_hover(&mut self, row: usize) -> bool {
        self.remote.want_bool("expand_hover", json!([row]))
    }
    pub fn topics(&self) -> Vec<usize> {
        self.remote.want("topics", json!([])).ok()
            .and_then(|value| value.as_array().map(|list| list.iter().filter_map(Value::as_u64).map(|n| n as usize).collect()))
            .unwrap_or_default()
    }
    pub fn focus_prev(&mut self) -> bool {
        self.remote.want_bool("focus_prev", json!([]))
    }
    pub fn focus_next(&mut self) -> bool {
        self.remote.want_bool("focus_next", json!([]))
    }
    pub fn set_expanded(&mut self, expanded: bool) {
        self.remote.nothing("set_expanded", json!([expanded]))
    }
    pub fn unfocus(&mut self) {
        self.remote.nothing("unfocus", json!([]))
    }
    pub fn page(&mut self, rows: isize) {
        self.remote.nothing("page", json!([rows]))
    }
    pub fn hold(&mut self) {
        self.remote.nothing("hold", json!([]))
    }
    pub fn sync(&mut self) {
        self.remote.nothing("sync", json!([]))
    }
    pub fn to_bottom(&mut self) {
        self.remote.nothing("to_bottom", json!([]))
    }
    pub fn following(&self) -> bool {
        self.remote.want_bool("following", json!([]))
    }
    /// The notice row. `now` is the caller's clock in process and meaningless over the wire: the
    /// program reads its own (`rust/wa-term/src/session.rs`), so the two-second rule has one owner.
    pub fn notice(&mut self, text: &str, _now: std::time::Instant, sticky: bool) -> bool {
        self.remote.want_bool("notice", json!([text, sticky]))
    }
    pub fn clear_notice(&mut self) -> bool {
        self.remote.want_bool("clear_notice", json!([]))
    }
    pub fn expire_notice(&mut self, _now: std::time::Instant) -> bool {
        self.remote.want_bool("expire_notice", json!([]))
    }
    pub fn on_pin(&self, row: usize) -> bool {
        self.remote.want_bool("on_pin", json!([row]))
    }
    pub fn on_notice(&self, row: usize) -> bool {
        self.remote.want_bool("on_notice", json!([row]))
    }
    pub fn on_pill(&self, row: usize, col: usize, height: usize) -> bool {
        self.remote.want_bool("on_pill", json!([row, col, height]))
    }
    pub fn jump_to_pinned(&mut self, width: usize) -> bool {
        self.remote.want_bool("jump_to_pinned", json!([width]))
    }
    pub fn view(&mut self, width: usize, height: usize) -> Vec<String> {
        self.remote.want("view", json!([width, height])).ok()
            .and_then(|value| value.as_array().map(|list| list.iter().map(|row| row.as_str().unwrap_or_default().to_string()).collect()))
            .unwrap_or_default()
    }
    /// The output region's frame (`Transcript::render`): the bytes, ready for the tty.
    pub fn render(&mut self, width: usize, rows: usize) -> String {
        self.remote.want_frame("render", json!([width, rows]))
    }

    // ---- the input box: the program owns the editor, the node sets its state, sends the key bytes
    // and draws what it answers (part 2 of `wa-term-own-program`). ----

    /// A fresh editor: the console starts a session with an empty box.
    pub fn editor_open(&mut self) { self.remote.nothing("editor_open", json!([])) }

    /// The state the node sets: one call per change, absent fields keeping what the editor has.
    pub fn editor_setup(&mut self, setup: &EditorSetup) {
        self.remote.nothing("editor_setup", json!([setup.to_json()]))
    }

    /// One key byte, answered as an `EditorAction`. A refused call answers `None`, never a guess.
    pub fn editor_key(&mut self, byte: u8) -> EditorAction {
        self.remote.want("editor_key", json!([byte])).ok()
            .map(|value| editor_action(&value))
            .unwrap_or(EditorAction::None)
    }

    /// Everything the console lays out from: the editor's own numbers, not the node's copy of them.
    pub fn editor_state(&mut self) -> EditorState {
        self.remote.want("editor_state", json!([])).ok()
            .map(|value| editor_state_of(&value))
            .unwrap_or_default()
    }

    /// The box's frame, drawn by the editor that owns it.
    pub fn editor_render(&mut self) -> String { self.remote.want_frame("editor_render", json!([])) }

    pub fn editor_paste(&mut self, text: &str) -> EditorAction {
        self.remote.want("editor_paste", json!([text])).ok()
            .map(|value| editor_action(&value))
            .unwrap_or(EditorAction::None)
    }
    pub fn editor_insert(&mut self, text: &str) { self.remote.nothing("editor_insert", json!([text])) }
    pub fn editor_replace(&mut self, from: usize, to: usize, text: &str) {
        self.remote.nothing("editor_replace", json!([from, to, text]))
    }
    pub fn editor_select(&mut self, anchor: usize, cursor: usize) {
        self.remote.nothing("editor_select", json!([anchor, cursor]))
    }
    pub fn editor_slice(&mut self, from: usize, to: usize) -> String {
        self.remote.want("editor_slice", json!([from, to])).ok()
            .and_then(|value| value.as_str().map(str::to_string))
            .unwrap_or_default()
    }
    pub fn editor_selection(&mut self) -> Option<String> {
        self.remote.want("editor_selection", json!([])).ok()
            .filter(|value| !value.is_null())
            .and_then(|value| value.as_str().map(str::to_string))
    }
    pub fn editor_click(&mut self, index: usize) { self.remote.nothing("editor_click", json!([index])) }
    pub fn editor_wheel(&mut self, up: bool, rows: usize) -> bool {
        self.remote.want_bool("editor_wheel", json!([up, rows]))
    }
    pub fn editor_escape(&mut self) -> bool { self.remote.want_bool("editor_escape", json!([])) }

    pub fn bar_frame(&self, width: usize) -> String {
        self.remote.want_frame("bar_frame", json!([width]))
    }
    pub fn text_width(&self, width: usize) -> usize {
        self.remote.want("text_width", json!([width])).ok().and_then(|value| value.as_u64()).map(|n| n as usize).unwrap_or(width)
    }
    pub fn on_bar(&self, row: usize, col: usize, width: usize) -> bool {
        self.remote.want_bool("on_bar", json!([row, col, width]))
    }
    pub fn bar_press(&mut self, row: usize, col: usize, width: usize) -> bool {
        self.remote.want_bool("bar_press", json!([row, col, width]))
    }
    pub fn bar_drag(&mut self, row: usize) -> bool {
        self.remote.want_bool("bar_drag", json!([row]))
    }
    pub fn bar_release(&mut self) -> bool {
        self.remote.want_bool("bar_release", json!([]))
    }
    pub fn bar_hover(&mut self, row: usize, col: usize, width: usize) -> bool {
        self.remote.want_bool("bar_hover", json!([row, col, width]))
    }
    pub fn bar_active(&self) -> bool {
        self.remote.want_bool("bar_active", json!([]))
    }
    pub fn bar(&self) -> Option<Bar> {
        let value = self.remote.want("bar", json!([])).ok()?;
        Some(Bar {
            track: value.get("track")?.as_u64()? as usize,
            total: value.get("total")?.as_u64()? as usize,
            first: value.get("first")?.as_u64()? as usize,
            active: value.get("active")?.as_bool()?,
        })
    }
    /// The inline scrollbar (`WA_TUI_SCROLLBAR`), handed to the program by name instead of read from
    /// its environment a second time: one reader, one meaning.
    pub fn set_scrollbar(&mut self, name: &str) {
        self.remote.nothing("scrollbar", json!([name]))
    }
    /// Whether the newest block is a code block - what the host asked `transcript.blocks.last().code`.
    pub fn last_is_code(&self) -> bool {
        self.remote.want_bool("last_is_code", json!([]))
    }
}
/// One terminal program's session: the child, its pipe, its last answer's `dirty`, and the failure
/// that stops it.
pub struct Remote {
    /// `None` until the first call attaches.
    inner: RefCell<Inner>,
    /// A refusal that needs no child: the switch said something that is not a switch.
    refused: Option<Failure>,
    /// The program's path, when the caller stated it ([`Screen::remote_at`]); `None` looks it up.
    explicit: Option<std::path::PathBuf>,
}

struct Inner {
    explicit: Option<std::path::PathBuf>,
    child: Option<Child>,
    pipe: Option<(BufWriter<ChildStdin>, BufReader<ChildStdout>)>,
    failure: Option<Failure>,
    dirty: bool,
    /// A frame the NODE decided is due (a resize) and the program has not been told about yet.
    pending: bool,
}

impl Remote {
    fn new(explicit: Option<std::path::PathBuf>) -> Self {
        Remote {
            inner: RefCell::new(Inner { explicit, child: None, pipe: None, failure: None, dirty: false, pending: false }),
            refused: None,
            explicit: None,
        }
    }

    fn dirty(&self) -> bool {
        if self.refused.is_some() { return false }
        let inner = self.inner.borrow();
        inner.pending || inner.dirty
    }

    fn mark_dirty(&mut self) { self.inner.borrow_mut().pending = true }

    fn clean(&mut self) {
        if self.refused.is_some() { return }
        self.inner.borrow_mut().pending = false;
        let _ = self.call("dirty", json!([false]));
    }

    /// Spawn the program and compare protocols, once.
    fn attach(&mut self) -> Result<(), Failure> {
        if let Some(failure) = &self.refused { return Err(failure.clone()) }
        let mut inner = self.inner.borrow_mut();
        inner.attach()
    }

    fn call(&self, method: &str, args: Value) -> Result<Value, Failure> {
        if let Some(failure) = &self.refused { return Err(failure.clone()) }
        self.inner.borrow_mut().exchange(method, args)
    }

    /// A call whose answer the caller does not read: only its refusal matters.
    fn nothing(&self, method: &str, args: Value) { let _ = self.call(method, args); }

    fn want(&self, method: &str, args: Value) -> Result<Value, Failure> { self.call(method, args) }

    fn want_bool(&self, method: &str, args: Value) -> bool {
        self.call(method, args).ok().and_then(|value| value.as_bool()).unwrap_or(false)
    }

    fn want_frame(&self, method: &str, args: Value) -> String {
        let Ok(value) = self.call(method, args) else { return String::new() };
        let Some(encoded) = value.get("frame").and_then(Value::as_str) else { return String::new() };
        String::from_utf8(proto::unbytes(encoded).unwrap_or_default()).unwrap_or_default()
    }
}

impl Inner {
    fn attach(&mut self) -> Result<(), Failure> {
        if let Some(failure) = &self.failure { return Err(failure.clone()) }
        if self.pipe.is_some() { return Ok(()) }
        let path = match resolve(self.explicit.clone()) { Ok(path) => path, Err(failure) => return Err(self.stop(failure)) };
        let mut child = match Command::new(&path).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit()).spawn() {
            Ok(child) => child,
            Err(error) => return Err(self.stop(Failure::new(proto::code::CALL_FAILED, format!("could not start {}: {error}", path.display())))),
        };
        let stdin = child.stdin.take().expect("stdin was piped");
        let stdout = child.stdout.take().expect("stdout was piped");
        self.child = Some(child);
        self.pipe = Some((BufWriter::new(stdin), BufReader::new(stdout)));
        let (to, from) = self.pipe.as_mut().expect("just set");
        if let Err(error) = proto::send(&proto::hello(), to) {
            return Err(self.stop(Failure::new(proto::code::CALL_FAILED, format!("could not say hello to {}: {error}", path.display()))));
        }
        let message = match proto::recv(from) {
            Ok(Some(message)) => message,
            Ok(None) => return Err(self.stop(Failure::new(proto::code::CALL_FAILED, format!("{} exited before it answered the handshake", path.display())))),
            Err(failure) => return Err(self.stop(failure)),
        };
        let hello = match proto::parse_hello(&message) {
            Ok(hello) => hello,
            Err(failure) => return Err(self.stop(failure)),
        };
        if hello.protocol != proto::PROTOCOL { return Err(self.stop(Failure::mismatch(hello.protocol))) }
        Ok(())
    }

    fn exchange(&mut self, method: &str, args: Value) -> Result<Value, Failure> {
        self.attach()?;
        let (to, from) = self.pipe.as_mut().expect("attach left a pipe");
        if let Err(error) = proto::send(&proto::call(method, args), to) {
            return Err(self.stop(Failure::new(proto::code::CALL_FAILED, format!("could not send '{method}' to the terminal program: {error}"))));
        }
        let message = match proto::recv(from) {
            Ok(Some(message)) => message,
            Ok(None) => return Err(self.stop(Failure::new(proto::code::CALL_FAILED, format!("the terminal program exited while answering '{method}'")))),
            Err(mut failure) => {
                failure.message = format!("answering '{method}': {}", failure.message);
                return Err(self.stop(failure));
            }
        };
        match proto::parse_reply(&message) {
            Ok(reply) => { self.dirty = reply.dirty; Ok(reply.value) }
            Err(mut failure) => { failure.message = format!("answering '{method}': {}", failure.message); Err(self.stop(failure)) }
        }
    }

    /// Record the failure (once, in a way a reader can quote), kill the child, and give the caller the
    /// same refusal for as long as this session lasts.
    fn stop(&mut self, failure: Failure) -> Failure {
        if self.failure.is_none() {
            eprintln!("wa: {}", failure.line());
            self.failure = Some(failure.clone());
        }
        self.pipe = None;
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.failure.clone().unwrap_or(failure)
    }
}

impl Drop for Inner {
    fn drop(&mut self) {
        self.pipe = None;
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// Where the terminal program is: the path a caller stated, else `WA_TERM_BIN`, then beside this
/// executable (the pair is installed together), then `PATH`. The refusal names what was tried, so a
/// wrong `WA_TERM_BIN` is the line it prints.
fn resolve(explicit: Option<std::path::PathBuf>) -> Result<std::path::PathBuf, Failure> {
    if let Some(path) = explicit {
        if path.is_file() { return Ok(path) }
        return Err(Failure::new(proto::code::PROGRAM_MISSING, format!("no {} at {}", proto::PROGRAM, path.display())));
    }
    program_path()
}

fn program_path() -> Result<std::path::PathBuf, Failure> {
    let mut tried: Vec<String> = Vec::new();
    if let Some(explicit) = std::env::var_os("WA_TERM_BIN") {
        let path = std::path::PathBuf::from(&explicit);
        if path.is_file() { return Ok(path) }
        tried.push(format!("WA_TERM_BIN={}", path.display()));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let path = dir.join(proto::PROGRAM);
            if path.is_file() { return Ok(path) }
            tried.push(format!("beside the executable ({})", path.display()));
        }
    }
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            let candidate = dir.join(proto::PROGRAM);
            if candidate.is_file() { return Ok(candidate) }
        }
        tried.push(format!("PATH ({})", path.to_string_lossy()));
    }
    Err(Failure::new(proto::code::PROGRAM_MISSING, format!(
        "no {} found - tried {}", proto::PROGRAM,
        if tried.is_empty() { "nothing: no WA_TERM_BIN, no executable path, no PATH".to_string() } else { tried.join(", ") })))
}
