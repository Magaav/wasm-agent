//! The transcript's handle in the node: THE SAME CALLS, either in process (today's path, the default)
//! or across the wire to the terminal program (`rust/wa-term/src/bin/wa-term.rs`, `WA_TERM_REMOTE=1`).
//!
//! It exists so the node's draws and its Lua view keep calling `write`, `render`, `bar_press` ... as
//! they always did: the move is WHERE the state and the painting live, not how they are asked for. With
//! the switch off nothing here is on any path - [`Screen::Local`] forwards to the crate the node
//! already links, call for call, so today's bytes are today's.
//!
//! Refusals, never a silent fallback (docs/missions/reports/wa-term-own-program.md):
//!
//! - `WA_TERM_REMOTE` takes `1` or `0`; any other value is `term_switch_invalid` and the console
//!   refuses to start, because "unknown" is not "today's path".
//! - The first call attaches: the program is looked for at `WA_TERM_BIN`, then beside this
//!   executable, then on `PATH` (`term_program_missing` names the three), and the handshake compares
//!   protocol numbers (`term_protocol_mismatch` names both).
//! - A failure STICKS: every later call is a no-op that draws nothing, and the name is printed once to
//!   stderr. A frame from a program that died would be a lie about the screen.
use std::cell::RefCell;
use std::io::{BufReader, BufWriter};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde_json::{json, Value};
use wa_term::scroll::bar::Bar;
use wa_term::transcript::Transcript;
use wa_term_proto::{self as proto, Failure};

/// The switch: `WA_TERM_REMOTE=1` draws the transcript through the terminal program. Unset or `0` is
/// today's in-process path.
pub const SWITCH: &str = "WA_TERM_REMOTE";

/// The console's transcript, in process or behind the wire.
pub enum Screen {
    Local(Transcript),
    Remote(Remote),
}

impl Default for Screen {
    fn default() -> Self { Screen::Local(Transcript::default()) }
}

impl Screen {
    /// What the console state is built with (`console_input`): the local path unless the switch asks
    /// for the program. An invalid switch value comes back as a [`Failure`] carried by the handle, so
    /// the console can refuse by name before it takes the screen.
    pub fn for_console() -> Screen {
        match std::env::var(SWITCH) {
            Err(_) => Screen::Local(Transcript::default()),
            Ok(value) => match value.trim() {
                "" | "0" => Screen::Local(Transcript::default()),
                "1" => Screen::Remote(Remote::new(None)),
                other => Screen::Remote(Remote::failed(Failure::new(
                    "term_switch_invalid",
                    format!("{SWITCH}={other}: it takes 1 (the terminal program) or 0 (in process)"),
                ))),
            },
        }
    }

    /// The wire, for a caller that has already decided: the console reads [`SWITCH`], and a test
    /// names the program itself instead of setting an environment for the whole process.
    pub fn remote_at(program: impl Into<std::path::PathBuf>) -> Screen { Screen::Remote(Remote::new(Some(program.into()))) }

    /// The refusal that must stop the console from starting, if there is one: the switch said
    /// something that is not a switch, the program is not there, or it speaks another protocol.
    /// `None` on today's path, and `None` once the program has answered the handshake.
    pub fn attach_error(&mut self) -> Option<Failure> {
        match self {
            Screen::Local(_) => None,
            Screen::Remote(remote) => remote.attach().err(),
        }
    }

    /// Whether the console has a frame to draw (`Transcript::dirty`). The wire's copy is kept in step
    /// with the program's: every reply carries it.
    pub fn dirty(&self) -> bool {
        match self {
            Screen::Local(t) => t.dirty,
            Screen::Remote(remote) => remote.dirty(),
        }
    }

    /// The node says a frame is due (`transcript.dirty = true`): the program's own flag is not asked,
    /// because a host-side reason (a resize) never reaches it.
    pub fn mark_dirty(&mut self) {
        match self {
            Screen::Local(t) => t.dirty = true,
            Screen::Remote(remote) => remote.mark_dirty(),
        }
    }

    /// The frame is out: the flag is cleared on both sides, so the next tick draws nothing.
    pub fn clean(&mut self) {
        match self {
            Screen::Local(t) => t.dirty = false,
            Screen::Remote(remote) => remote.clean(),
        }
    }

    // ---- wa_term::transcript's own surface, unchanged -------------------------------------------
    //
    // Every method is the SAME call: `Local` is the crate's own; `Remote` is one message. Nothing is
    // re-decided here, so a display-only change cannot appear in this file.

    pub fn write(&mut self, text: &str) {
        match self { Screen::Local(t) => t.write(text), Screen::Remote(r) => r.nothing("write", json!([text])) }
    }
    pub fn write_marked(&mut self, text: &str, request: bool) {
        match self { Screen::Local(t) => t.write_marked(text, request), Screen::Remote(r) => r.nothing("write_marked", json!([text, request])) }
    }
    pub fn block(&mut self, topic: bool) {
        match self { Screen::Local(t) => t.block(topic), Screen::Remote(r) => r.nothing("block", json!([topic])) }
    }
    pub fn code_block(&mut self) {
        match self { Screen::Local(t) => t.code_block(), Screen::Remote(r) => r.nothing("code_block", json!([])) }
    }
    pub fn fold_code(&mut self, summary: &str) -> bool {
        match self { Screen::Local(t) => t.fold_code(summary), Screen::Remote(r) => r.want_bool("fold_code", json!([summary])) }
    }
    pub fn head(&mut self, text: &str) -> bool {
        match self { Screen::Local(t) => t.head(text), Screen::Remote(r) => r.want_bool("head", json!([text])) }
    }
    pub fn live(&mut self, text: Option<&str>) {
        match self { Screen::Local(t) => t.live(text), Screen::Remote(r) => r.nothing("live", json!([text])) }
    }
    pub fn rewrite(&mut self, offset: isize, text: &str) -> bool {
        match self { Screen::Local(t) => t.rewrite(offset, text), Screen::Remote(r) => r.want_bool("rewrite", json!([offset, text])) }
    }
    pub fn pin_toggle(&mut self) -> Option<bool> {
        match self {
            Screen::Local(t) => t.pin_toggle(),
            Screen::Remote(r) => r.want("pin_toggle", json!([])).ok().and_then(|value| value.as_bool()),
        }
    }
    pub fn copyable(&mut self, markers: &[(usize, String)]) {
        match self { Screen::Local(t) => t.copyable(markers), Screen::Remote(r) => r.nothing("copyable", json!([markers])) }
    }
    pub fn expandable(&mut self, markers: &[(usize, String)]) {
        match self { Screen::Local(t) => t.expandable(markers), Screen::Remote(r) => r.nothing("expandable", json!([markers])) }
    }
    pub fn cardable(&mut self, ranges: &[(usize, usize)]) {
        match self { Screen::Local(t) => t.cardable(ranges), Screen::Remote(r) => r.nothing("cardable", json!([ranges])) }
    }
    pub fn copy_first(&mut self, text: &str) -> bool {
        match self { Screen::Local(t) => t.copy_first(text), Screen::Remote(r) => r.want_bool("copy_first", json!([text])) }
    }
    pub fn copy_at(&self, row: usize, col: usize) -> Option<String> {
        match self {
            Screen::Local(t) => t.copy_at(row, col),
            Screen::Remote(r) => r.want("copy_at", json!([row, col])).ok().and_then(|value| value.as_str().map(str::to_string)),
        }
    }
    pub fn copy_hover(&mut self, row: usize, col: usize) -> bool {
        match self { Screen::Local(t) => t.copy_hover(row, col), Screen::Remote(r) => r.want_bool("copy_hover", json!([row, col])) }
    }
    pub fn expand_at(&mut self, row: usize) -> bool {
        match self { Screen::Local(t) => t.expand_at(row), Screen::Remote(r) => r.want_bool("expand_at", json!([row])) }
    }
    pub fn expand_hover(&mut self, row: usize) -> bool {
        match self { Screen::Local(t) => t.expand_hover(row), Screen::Remote(r) => r.want_bool("expand_hover", json!([row])) }
    }
    pub fn topics(&self) -> Vec<usize> {
        match self {
            Screen::Local(t) => t.topics(),
            Screen::Remote(r) => r.want("topics", json!([])).ok()
                .and_then(|value| value.as_array().map(|list| list.iter().filter_map(Value::as_u64).map(|n| n as usize).collect()))
                .unwrap_or_default(),
        }
    }
    pub fn focus_prev(&mut self) -> bool {
        match self { Screen::Local(t) => t.focus_prev(), Screen::Remote(r) => r.want_bool("focus_prev", json!([])) }
    }
    pub fn focus_next(&mut self) -> bool {
        match self { Screen::Local(t) => t.focus_next(), Screen::Remote(r) => r.want_bool("focus_next", json!([])) }
    }
    pub fn set_expanded(&mut self, expanded: bool) {
        match self { Screen::Local(t) => t.set_expanded(expanded), Screen::Remote(r) => r.nothing("set_expanded", json!([expanded])) }
    }
    pub fn unfocus(&mut self) {
        match self { Screen::Local(t) => t.unfocus(), Screen::Remote(r) => r.nothing("unfocus", json!([])) }
    }
    pub fn page(&mut self, rows: isize) {
        match self { Screen::Local(t) => t.page(rows), Screen::Remote(r) => r.nothing("page", json!([rows])) }
    }
    pub fn hold(&mut self) {
        match self { Screen::Local(t) => t.hold(), Screen::Remote(r) => r.nothing("hold", json!([])) }
    }
    pub fn sync(&mut self) {
        match self { Screen::Local(t) => t.sync(), Screen::Remote(r) => r.nothing("sync", json!([])) }
    }
    pub fn to_bottom(&mut self) {
        match self { Screen::Local(t) => t.to_bottom(), Screen::Remote(r) => r.nothing("to_bottom", json!([])) }
    }
    pub fn following(&self) -> bool {
        match self { Screen::Local(t) => t.following(), Screen::Remote(r) => r.want_bool("following", json!([])) }
    }
    /// The notice row. `now` is the caller's clock in process and meaningless over the wire: the
    /// program reads its own (`rust/wa-term/src/session.rs`), so the two-second rule has one owner.
    pub fn notice(&mut self, text: &str, _now: std::time::Instant, sticky: bool) -> bool {
        match self { Screen::Local(t) => t.notice(text, _now, sticky), Screen::Remote(r) => r.want_bool("notice", json!([text, sticky])) }
    }
    pub fn clear_notice(&mut self) -> bool {
        match self { Screen::Local(t) => t.clear_notice(), Screen::Remote(r) => r.want_bool("clear_notice", json!([])) }
    }
    pub fn expire_notice(&mut self, _now: std::time::Instant) -> bool {
        match self { Screen::Local(t) => t.expire_notice(_now), Screen::Remote(r) => r.want_bool("expire_notice", json!([])) }
    }
    pub fn on_pin(&self, row: usize) -> bool {
        match self { Screen::Local(t) => t.on_pin(row), Screen::Remote(r) => r.want_bool("on_pin", json!([row])) }
    }
    pub fn on_notice(&self, row: usize) -> bool {
        match self { Screen::Local(t) => t.on_notice(row), Screen::Remote(r) => r.want_bool("on_notice", json!([row])) }
    }
    pub fn on_pill(&self, row: usize, col: usize, height: usize) -> bool {
        match self { Screen::Local(t) => t.on_pill(row, col, height), Screen::Remote(r) => r.want_bool("on_pill", json!([row, col, height])) }
    }
    pub fn jump_to_pinned(&mut self, width: usize) -> bool {
        match self { Screen::Local(t) => t.jump_to_pinned(width), Screen::Remote(r) => r.want_bool("jump_to_pinned", json!([width])) }
    }
    pub fn view(&mut self, width: usize, height: usize) -> Vec<String> {
        match self {
            Screen::Local(t) => t.view(width, height),
            Screen::Remote(r) => r.want("view", json!([width, height])).ok()
                .and_then(|value| value.as_array().map(|list| list.iter().map(|row| row.as_str().unwrap_or_default().to_string()).collect()))
                .unwrap_or_default(),
        }
    }
    /// The output region's frame (`Transcript::render`): the bytes, ready for the tty.
    pub fn render(&mut self, width: usize, rows: usize) -> String {
        match self { Screen::Local(t) => t.render(width, rows), Screen::Remote(r) => r.want_frame("render", json!([width, rows])) }
    }
    pub fn bar_frame(&self, width: usize) -> String {
        match self { Screen::Local(t) => t.bar_frame(width), Screen::Remote(r) => r.want_frame("bar_frame", json!([width])) }
    }
    pub fn text_width(&self, width: usize) -> usize {
        match self {
            Screen::Local(t) => t.text_width(width),
            Screen::Remote(r) => r.want("text_width", json!([width])).ok().and_then(|value| value.as_u64()).map(|n| n as usize).unwrap_or(width),
        }
    }
    pub fn on_bar(&self, row: usize, col: usize, width: usize) -> bool {
        match self { Screen::Local(t) => t.on_bar(row, col, width), Screen::Remote(r) => r.want_bool("on_bar", json!([row, col, width])) }
    }
    pub fn bar_press(&mut self, row: usize, col: usize, width: usize) -> bool {
        match self { Screen::Local(t) => t.bar_press(row, col, width), Screen::Remote(r) => r.want_bool("bar_press", json!([row, col, width])) }
    }
    pub fn bar_drag(&mut self, row: usize) -> bool {
        match self { Screen::Local(t) => t.bar_drag(row), Screen::Remote(r) => r.want_bool("bar_drag", json!([row])) }
    }
    pub fn bar_release(&mut self) -> bool {
        match self { Screen::Local(t) => t.bar_release(), Screen::Remote(r) => r.want_bool("bar_release", json!([])) }
    }
    pub fn bar_hover(&mut self, row: usize, col: usize, width: usize) -> bool {
        match self { Screen::Local(t) => t.bar_hover(row, col, width), Screen::Remote(r) => r.want_bool("bar_hover", json!([row, col, width])) }
    }
    pub fn bar_active(&self) -> bool {
        match self { Screen::Local(t) => t.bar_active(), Screen::Remote(r) => r.want_bool("bar_active", json!([])) }
    }
    pub fn bar(&self) -> Option<Bar> {
        match self {
            Screen::Local(t) => t.bar(),
            Screen::Remote(r) => {
                let value = r.want("bar", json!([])).ok()?;
                Some(Bar {
                    track: value.get("track")?.as_u64()? as usize,
                    total: value.get("total")?.as_u64()? as usize,
                    first: value.get("first")?.as_u64()? as usize,
                    active: value.get("active")?.as_bool()?,
                })
            }
        }
    }
    /// The inline scrollbar (`WA_TUI_SCROLLBAR`), handed to the program by name instead of read from
    /// its environment a second time: one reader, one meaning.
    pub fn set_scrollbar(&mut self, name: &str) {
        match self { Screen::Local(t) => { if let Some(bar) = wa_term::scroll::settings::Scrollbar::parse(name) { t.scrollbar = bar } }, Screen::Remote(r) => r.nothing("scrollbar", json!([name])) }
    }
    /// Whether the newest block is a code block - what the host asked `transcript.blocks.last().code`.
    pub fn last_is_code(&self) -> bool {
        match self {
            Screen::Local(t) => t.blocks.last().is_some_and(|block| block.code),
            Screen::Remote(r) => r.want_bool("last_is_code", json!([])),
        }
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

    fn failed(failure: Failure) -> Self { Remote { refused: Some(failure), ..Remote::new(None) } }

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
