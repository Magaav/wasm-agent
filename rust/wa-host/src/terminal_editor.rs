//! The interactive CLI's input row. This is a terminal capability, not agent logic:
//! Lua decides what to do with submitted lines. A reader thread owns keystrokes so it
//! can redraw a draft even while Lua is blocked in the model or a tool.
use std::io::{self, Write};
use std::sync::Mutex;

static OUTPUT: Mutex<()> = Mutex::new(());

pub fn write(text: &str) -> io::Result<()> {
    let _guard = OUTPUT.lock().unwrap_or_else(|e| e.into_inner());
    let mut out = io::stdout().lock();
    out.write_all(text.as_bytes())?;
    out.flush()
}

#[cfg(unix)]
pub struct RawMode(libc::termios, Option<libc::c_int>);
#[cfg(unix)]
pub fn try_raw() -> Option<RawMode> {
    // A redirected stdin is a line stream, not a terminal: do not change it.
    let mut old = unsafe { std::mem::zeroed() };
    if unsafe { libc::tcgetattr(0, &mut old) } != 0 { return None; }
    let mut raw = old;
    unsafe { libc::cfmakeraw(&mut raw) };
    if unsafe { libc::tcsetattr(0, libc::TCSANOW, &raw) } != 0 { return None; }
    Some(RawMode(old, divert_stderr()))
}
#[cfg(unix)]
impl Drop for RawMode {
    fn drop(&mut self) {
        unsafe { libc::tcsetattr(0, libc::TCSANOW, &self.0); }
        if let Some(saved) = self.1.take() { unsafe { libc::dup2(saved, 2); libc::close(saved); } }
    }
}

/// While the editor owns the screen, nothing else may write to it: a background thread's
/// `eprintln!` (the graph indexer's progress, a `[lua]` log line) would land in the middle of the
/// chat or the input box, at whatever row the cursor was on. A terminal stderr is pointed at
/// `~/.wasm-agent/logs/cli-stderr.log` until the editor stops; a stderr already redirected by the
/// caller is theirs and is left alone. Returns the saved descriptor that Drop puts back.
#[cfg(unix)]
fn divert_stderr() -> Option<libc::c_int> {
    use std::os::unix::io::IntoRawFd;
    if unsafe { libc::isatty(2) } != 1 { return None; }
    let dir = std::path::PathBuf::from(crate::resolve_home()).join(".wasm-agent").join("logs");
    std::fs::create_dir_all(&dir).ok()?;
    let log = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("cli-stderr.log")).ok()?;
    let saved = unsafe { libc::dup(2) };
    if saved < 0 { return None; }
    let fd = log.into_raw_fd();
    let moved = unsafe { libc::dup2(fd, 2) };
    unsafe { libc::close(fd); }
    if moved < 0 { unsafe { libc::close(saved); } return None; }
    Some(saved)
}

#[cfg(windows)]
pub struct RawMode {
    handle: *mut std::ffi::c_void, mode: u32, codepage: u32,
    output: *mut std::ffi::c_void, output_mode: u32,
}
#[cfg(windows)]
unsafe impl Send for RawMode {} // the handle belongs to this process for its entire life
#[cfg(windows)]
pub fn try_raw() -> Option<RawMode> {
    use std::ffi::c_void;
    extern "system" {
        fn GetStdHandle(kind: u32) -> *mut c_void;
        fn GetConsoleMode(handle: *mut c_void, mode: *mut u32) -> i32;
        fn SetConsoleMode(handle: *mut c_void, mode: u32) -> i32;
        fn GetConsoleCP() -> u32;
        fn SetConsoleCP(codepage: u32) -> i32;
    }
    unsafe {
        let handle = GetStdHandle(0xffff_fff6); // STD_INPUT_HANDLE
        let mut mode = 0;
        if handle.is_null() || GetConsoleMode(handle, &mut mode) == 0 { return None; }
        // Disable line/echo/processed input. VT input gives escape sequences for arrows
        // through the same byte stream as UTF-8 text; keep the other console flags.
        let raw = (mode & !(0x0001 | 0x0002 | 0x0004)) | 0x0200;
        if SetConsoleMode(handle, raw) == 0 { return None; }
        let output = GetStdHandle(0xffff_fff5);
        let mut output_mode = 0;
        if GetConsoleMode(output, &mut output_mode) == 0 || SetConsoleMode(output, output_mode | 0x0005) == 0 {
            SetConsoleMode(handle, mode);
            return None;
        }
        let codepage = GetConsoleCP();
        if SetConsoleCP(65001) == 0 {
            SetConsoleMode(handle, mode);
            SetConsoleMode(output, output_mode);
            return None;
        }
        Some(RawMode { handle, mode, codepage, output, output_mode })
    }
}
#[cfg(windows)]
impl Drop for RawMode {
    fn drop(&mut self) {
        use std::ffi::c_void;
        extern "system" {
            fn SetConsoleMode(handle: *mut c_void, mode: u32) -> i32;
            fn SetConsoleCP(codepage: u32) -> i32;
        }
        unsafe {
            SetConsoleMode(self.handle, self.mode);
            SetConsoleMode(self.output, self.output_mode);
            SetConsoleCP(self.codepage);
        }
    }
}
#[cfg(not(any(unix, windows)))]
pub struct RawMode;
#[cfg(not(any(unix, windows)))]
pub fn try_raw() -> Option<RawMode> { None }

#[derive(Debug, PartialEq)]
pub enum Action { None, Submit(String), Eof, Interrupt, Nav, PageUp, PageDown, Bottom }

/// A command the slash menu offers: its name (`/login`), whether it takes arguments, and its hint.
#[derive(Clone, Default)]
pub struct Command { pub name: String, pub args: bool, pub hint: String }

/// The most commands the slash menu shows at once; the window follows the selection.
const MENU_MAX: usize = 8;

#[derive(Default)]
pub struct Editor {
    chars: Vec<char>, cursor: usize, history: Vec<String>, history_at: Option<usize>, saved: String,
    escape: Vec<u8>, utf8: Vec<u8>, paste: bool, pub row: usize, pub width: usize, pub height: usize,
    last_interrupt: Option<std::time::Instant>,
    /// The slash menu: what it offers, which row is selected, and whether Esc closed it for this draft.
    pub commands: Vec<Command>, menu_at: usize, menu_hidden: bool,
    /// The hint row under the box, as the view last set it (plain text; painted dim here), and what
    /// it shows right-aligned: the model in use.
    pub footer: String, pub footer_right: String,
    /// Whether the status line has its row (only while a run is in flight).
    pub status: bool,
    /// Lines submitted during the run that the agent has not taken yet: drawn above the status line
    /// (`Steering queued`), never into the chat, so a steer is not printed twice. The host sets it.
    pub queued: Vec<String>,
    /// A one-keystroke note drawn in the footer's place (`Interrupting…`, `Draft kept`); the next
    /// key clears it, and so does the run's status row coming or going.
    pub notice: String,
    /// Undo/redo of the draft: each entry is the draft and cursor *before* a step. Consecutive typed
    /// characters are one step up to a word boundary, a paste is one step, and every delete, kill,
    /// completion or history recall is a step of its own.
    undo: Vec<Snapshot>, redo: Vec<Snapshot>, group: Option<Group>, group_cursor: usize, restored: bool,
    /// Bash mode, Claude Code's `!`: typed as the first character of an empty draft it is taken as the
    /// mode rather than as text - the prompt and the dividers turn pink and the line is submitted as
    /// `!<command>`. Backspace on the empty draft or Esc leaves it.
    pub bash: bool,
}

#[derive(Clone)]
struct Snapshot { chars: Vec<char>, cursor: usize }
#[derive(Clone, Copy, PartialEq)]
enum Group { Typing, Paste }
/// The most undo steps kept; older ones are dropped first.
const UNDO_MAX: usize = 200;

impl Editor {
    fn text(&self) -> String { self.chars.iter().collect() }
    fn replace(&mut self, text: &str) { self.chars = text.chars().collect(); self.cursor = self.chars.len(); }
    fn insert(&mut self, ch: char) { self.chars.insert(self.cursor, ch); self.cursor += 1; }
    /// Nothing typed and not in bash mode: a restart here loses nothing.
    pub fn draft_empty(&self) -> bool { self.chars.is_empty() && !self.bash }
    /// The draft as it is submitted: `!` in front of it in bash mode.
    fn line(&self) -> String { if self.bash { format!("!{}", self.text()) } else { self.text() } }
    /// A recalled `!command` comes back in bash mode, its `!` the mode again rather than text.
    fn recall(&mut self, text: &str) {
        match text.strip_prefix('!') { Some(rest) => { self.bash = true; self.replace(rest); } None => { self.bash = false; self.replace(text); } }
    }
    fn history(&mut self, up: bool) {
        if self.history.is_empty() { return; }
        if up {
            let next = self.history_at.map(|n| n.saturating_sub(1)).unwrap_or_else(|| {
                self.saved = self.line(); self.history.len() - 1
            });
            self.history_at = Some(next);
            let text = self.history[next].clone(); self.recall(&text);
        } else if let Some(n) = self.history_at {
            if n + 1 == self.history.len() { self.history_at = None; let text = self.saved.clone(); self.recall(&text); }
            else { self.history_at = Some(n + 1); let text = self.history[n + 1].clone(); self.recall(&text); }
        }
    }
    /// Where the cursor would be drawn for every index of the draft (0..=len), wrapped as `layout`
    /// wraps it. Without a width (tests, a pipe) only `\n` breaks a line.
    fn positions(&self) -> Vec<(usize, usize)> {
        let available = if self.width == 0 { usize::MAX } else { self.width.saturating_sub(BOX_CHROME) };
        let (mut line, mut col) = (0usize, 0usize);
        let mut out = Vec::with_capacity(self.chars.len() + 1);
        for &ch in &self.chars {
            if ch == '\n' { out.push((line, col)); line += 1; col = 0; continue; }
            let width = cell_width(ch);
            if col + width > available && col > 0 { line += 1; col = 0; }
            out.push((line, col)); col += width;
        }
        out.push((line, col));
        out
    }
    /// Up/Down inside a draft of several lines move the cursor a line, keeping its column; only on
    /// the first line (Up) or the last one (Down) do they walk the history. False: at that edge.
    fn move_line(&mut self, up: bool) -> bool {
        let positions = self.positions();
        let (line, col) = positions[self.cursor.min(positions.len() - 1)];
        let last = positions.last().map(|p| p.0).unwrap_or(0);
        let target = match up { true if line > 0 => line - 1, false if line < last => line + 1, _ => return false };
        let mut best = None;
        for (index, &(l, c)) in positions.iter().enumerate() {
            if l == target && (c <= col || best.is_none()) { best = Some(index); }
            if l > target { break; }
        }
        if let Some(index) = best { self.cursor = index; }
        true
    }
    /// One byte from the terminal. The slash menu gets the keys it owns first - arrows move its
    /// selection, Tab completes, Enter runs the selected command - and any edit reopens it. A draft
    /// recalled from the history is not an edit: the menu stays closed on it, so Down keeps walking
    /// the history after Up brought back a `/command`.
    pub fn feed(&mut self, byte: u8) -> Action {
        self.notice.clear();
        // Undo bookkeeping: a byte that extends the open group (the next letter of a word, the next
        // byte of a paste) needs no snapshot - the group's entry already holds the draft before it.
        let kind = if self.paste { Some(Group::Paste) }
            else if self.escape.is_empty() && byte >= 32 && byte != 127 { Some(Group::Typing) } else { None };
        let word_break = byte == b' ' && self.cursor > 0 && !self.chars[self.cursor - 1].is_whitespace();
        let extends = kind.is_some() && kind == self.group && self.cursor == self.group_cursor
            && !(kind == Some(Group::Typing) && word_break);
        let snapshot = if extends { None } else { Some(Snapshot { chars: self.chars.clone(), cursor: self.cursor }) };
        let was_pasting = self.paste;
        let action = self.feed_inner(byte);
        if std::mem::take(&mut self.restored) { self.group_cursor = self.cursor; return action; }
        if let Some(snapshot) = snapshot.filter(|s| s.chars != self.chars) {
            if self.undo.len() == UNDO_MAX { self.undo.remove(0); }
            self.undo.push(snapshot);
            self.redo.clear();
            self.group = kind;
        } else if extends {
            self.redo.clear();
        } else if self.cursor != self.group_cursor || kind.is_none() {
            self.group = None; // the cursor moved, or a key that is not typing: the next letter starts a step
        }
        if !was_pasting && self.paste { self.group = None; } // a new paste never merges into the last one
        self.group_cursor = self.cursor;
        if matches!(action, Action::Submit(_)) { self.undo.clear(); self.redo.clear(); self.group = None; }
        action
    }

    /// Ctrl+Z / Ctrl+Y (and Ctrl+Shift+Z where the terminal reports it): back to the draft before the
    /// last step, or forward again, cursor included. A recalled history entry becomes a plain draft.
    fn restore(&mut self, undo: bool) {
        let (from, to) = if undo { (&mut self.undo, &mut self.redo) } else { (&mut self.redo, &mut self.undo) };
        let Some(snapshot) = from.pop() else { return };
        to.push(Snapshot { chars: std::mem::replace(&mut self.chars, snapshot.chars), cursor: self.cursor });
        self.cursor = snapshot.cursor.min(self.chars.len());
        self.history_at = None;
        self.group = None;
        self.restored = true;
    }

    fn feed_inner(&mut self, byte: u8) -> Action {
        let before = self.chars.len();
        let before_text = if self.menu_rows() > 0 || self.chars.first() == Some(&'/') { Some(self.text()) } else { None };
        let before_history = self.history_at;
        if let Some(action) = self.menu_key(byte) { return action; }
        let action = self.feed_key(byte);
        if self.history_at != before_history {
            self.menu_at = 0; self.menu_hidden = self.history_at.is_some();
        } else if self.chars.len() != before || before_text.is_some_and(|text| text != self.text()) {
            self.menu_at = 0; self.menu_hidden = false;
        }
        action
    }

    fn menu_key(&mut self, byte: u8) -> Option<Action> {
        let items = self.menu_items();
        if items.is_empty() { return None; }
        let sequence = |e: &Self, tail: &[u8]| e.escape.len() == 2 && e.escape[0] == 0x1b && e.escape[1] == b'[' && tail.contains(&byte);
        if sequence(self, b"AB") {
            self.escape.clear();
            let n = items.len();
            self.menu_at = if byte == b'A' { (self.menu_at + n - 1) % n } else { (self.menu_at + 1) % n };
            return Some(Action::None);
        }
        if !self.escape.is_empty() || self.paste { return None; }
        let chosen = self.commands[items[self.menu_at.min(items.len() - 1)]].clone();
        match byte {
            b'\t' => {
                let text = if chosen.args { format!("{} ", chosen.name) } else { chosen.name.clone() };
                self.replace(&text); self.menu_hidden = chosen.args;
                Some(Action::None)
            }
            b'\r' if chosen.args && self.text() != chosen.name => {
                let text = format!("{} ", chosen.name); self.replace(&text); self.menu_hidden = true;
                Some(Action::None)
            }
            b'\r' => {
                let line = chosen.name.clone();
                self.chars.clear(); self.cursor = 0; self.history_at = None; self.menu_at = 0;
                self.history.push(line.clone());
                Some(Action::Submit(line))
            }
            _ => None,
        }
    }

    /// The commands that match the draft: it starts with `/` and holds no space yet.
    fn menu_items(&self) -> Vec<usize> {
        if self.menu_hidden || self.commands.is_empty() || self.chars.first() != Some(&'/')
            || self.chars.iter().any(|c| c.is_whitespace()) { return Vec::new(); }
        let typed = self.text();
        let mut items: Vec<usize> = (0..self.commands.len()).filter(|&i| self.commands[i].name.starts_with(&typed)).collect();
        if items.is_empty() {
            let needle = typed.trim_start_matches('/').to_lowercase();
            items = (0..self.commands.len()).filter(|&i| self.commands[i].name.to_lowercase().contains(&needle)).collect();
        }
        items
    }
    pub fn menu_rows(&self) -> usize { self.menu_items().len().min(MENU_MAX) }
    /// A lone Esc (the host saw nothing follow it): closes the slash menu for this draft.
    pub fn escape(&mut self) -> bool {
        let lone = self.escape.as_slice() == b"\x1b";
        if lone { self.escape.clear(); }
        if self.menu_rows() > 0 { self.menu_hidden = true; return true; }
        if self.bash { self.bash = false; return true; }
        lone
    }
    /// The box's bottom border, always the row above the footer.
    pub fn bottom(&self) -> usize { self.row }
    /// Inside a paste: an Esc here is the start of the paste's end marker, never the Esc key.
    pub fn pasting(&self) -> bool { self.paste }
    /// The input's top divider: as many rows above the bottom one as the draft shows.
    fn top(&self) -> usize {
        let (lines, cursor) = self.layout();
        self.frame_geometry(lines.len(), cursor.0).2
    }
    /// Bottom up: footer, bottom divider, the draft, top divider, the slash menu (opening upward),
    /// the status line while a run is in flight, then the output. Nothing is reserved that is not
    /// drawn, so the chat sits right on top of the input.
    pub fn status_row(&self) -> usize { self.top().saturating_sub(self.menu_rows() + 1) }
    pub fn out_bottom(&self) -> usize {
        self.status_row().saturating_sub(if self.status { 1 + self.queued_count() } else { 0 })
    }
    /// How many rows the queued steers take above the status line (only while a run is in flight).
    fn queued_count(&self) -> usize {
        if !self.status || self.queued.is_empty() { 0 } else { self.queued.len().min(QUEUED_MAX) }
    }
    /// The queued lines as the web UI words them (`↪ Steering queued · next safe boundary`), each
    /// clipped to one row; a slash command is REPL control and runs after the run. More than
    /// `QUEUED_MAX`: the last row counts the rest.
    fn queued_rows(&self) -> Vec<String> {
        let count = self.queued_count();
        let mut rows = Vec::with_capacity(count);
        for (index, text) in self.queued.iter().take(count).enumerate() {
            if index + 1 == count && self.queued.len() > count {
                let more = self.queued.len() - index;
                rows.push(format!("{QUEUED}\u{21aa} {more} more queued{RESET}"));
                break;
            }
            let flat: String = text.trim().chars().map(|c| if c == '\n' || c == '\r' || c == '\t' { ' ' } else { c }).collect();
            let (label, meta) = if flat.starts_with('/') || flat.starts_with('!') { ("Queued", "after the run") } else { ("Steering queued", "next safe boundary") };
            let head = format!("\u{21aa} {label} \u{b7} {meta}: ");
            let room = self.width.saturating_sub(head.chars().map(cell_width).sum::<usize>());
            rows.push(format!("{QUEUED}\u{21aa} {label}{RESET}{HINT} \u{b7} {meta}: {RESET}{}", clip_cells(&flat, room)));
        }
        rows
    }

    fn feed_key(&mut self, byte: u8) -> Action {
        if !self.escape.is_empty() {
            self.escape.push(byte);
            // ESC followed by anything that cannot start a sequence (a lone Esc, or Alt+key) is not an
            // escape sequence: drop the ESC and keep the key - it used to swallow the next keystroke.
            if self.escape.len() == 2 && !matches!(byte, b'[' | b'O' | b'\r' | b'\n' | 0x1b) {
                self.escape.clear();
                return self.feed_inner(byte);
            }
            let seq = self.escape.as_slice();
            if seq == b"\x1b\x1b" { self.escape.truncate(1); self.escape(); return Action::None; }
            // CSI arrows, Home/End, Delete and bracketed paste boundaries.
            if seq == b"\x1b[200~" { self.paste = true; self.escape.clear(); return Action::None; }
            if seq == b"\x1b[201~" { self.paste = false; self.escape.clear(); return Action::None; }
            // Orca on Windows sends ESC CR for Shift+Enter (also Alt+Enter).
            if seq == b"\x1b\r" || seq == b"\x1b\n" || seq == b"\x1b[13;2u"
                || seq == b"\x1b[27;2;13~" || seq == b"\x1b[13;2~" {
                self.insert('\n'); self.escape.clear(); return Action::None;
            }
            // Ctrl+Z / Ctrl+Shift+Z as the kitty keyboard protocol reports them (`z` = 122, `Z` = 90).
            if seq == b"\x1b[122;5u" { self.escape.clear(); self.restore(true); return Action::None; }
            if seq == b"\x1b[122;6u" || seq == b"\x1b[90;6u" { self.escape.clear(); self.restore(false); return Action::None; }
            if seq == b"\x1b[D" { self.cursor = self.cursor.saturating_sub(1); }
            else if seq == b"\x1b[C" { self.cursor = (self.cursor + 1).min(self.chars.len()); }
            // Ctrl+Up leaves the draft for the transcript's topics (Up stays history).
            else if seq == b"\x1b[1;5A" { self.escape.clear(); return Action::Nav; }
            else if seq == b"\x1b[5~" { self.escape.clear(); return Action::PageUp; }
            else if seq == b"\x1b[6~" { self.escape.clear(); return Action::PageDown; }
            else if seq == b"\x1b[6;5~" { self.escape.clear(); return Action::Bottom; }
            else if seq == b"\x1b[A" { if !self.move_line(true) { self.history(true); } }
            else if seq == b"\x1b[B" { if !self.move_line(false) { self.history(false); } }
            else if seq == b"\x1b[H" || seq == b"\x1b[1~" { self.cursor = 0; }
            else if seq == b"\x1b[F" || seq == b"\x1b[4~" { self.cursor = self.chars.len(); }
            else if seq == b"\x1b[3~" { if self.cursor < self.chars.len() { self.chars.remove(self.cursor); } }
            else if (seq.len() < 16 && seq.starts_with(b"\x1b[")
                && (seq.len() == 2 || !seq.last().is_some_and(|b| (0x40..=0x7e).contains(b))))
                || (seq.len() == 2 && seq == b"\x1bO") { return Action::None; }
            // Unknown complete escape is ignored, never inserted into the user's prompt.
            self.escape.clear();
            return Action::None;
        }
        if byte == 0x1b { self.escape.push(byte); return Action::None; }
        if self.paste && (byte == b'\r' || byte == b'\n') { self.insert('\n'); return Action::None; }
        match byte {
            b'\r' => {
                let line = self.line(); self.chars.clear(); self.cursor = 0; self.history_at = None; self.bash = false;
                if !line.is_empty() && line != "!" && !carries_secret(&line) { self.history.push(line.clone()); }
                Action::Submit(line)
            }
            b'\n' => { self.insert('\n'); Action::None } // Ctrl+J: multiline without submitting
            // Ctrl+C never touches the draft. During a run it interrupts the turn (raw mode turned the
            // terminal's own SIGINT off, so a runaway turn could otherwise only be stopped by killing the
            // terminal); on an empty line a second one within a second leaves. With a draft and no run
            // it only says how to clear or leave - quitting would throw the draft away.
            3 if self.bash && self.chars.is_empty() => { self.bash = false; Action::None }
            3 if !self.chars.is_empty() => {
                self.last_interrupt = None;
                if self.status {
                    self.notice = "Interrupting\u{2026} (draft kept)".into();
                    Action::Interrupt
                } else {
                    self.notice = "Draft kept \u{b7} ctrl+u clears it \u{b7} ctrl+z undoes".into();
                    Action::None
                }
            }
            3 => {
                let now = std::time::Instant::now();
                let twice = self.last_interrupt.is_some_and(|at| now.duration_since(at) < std::time::Duration::from_secs(1));
                self.last_interrupt = Some(now);
                if twice { return Action::Eof; }
                self.notice = if self.status { "Interrupting\u{2026} (ctrl+c again to quit)" } else { "ctrl+c again to quit" }.into();
                Action::Interrupt
            }
            26 => { self.restore(true); Action::None } // Ctrl+Z: undo (raw mode turned SIGTSTP off)
            25 => { self.restore(false); Action::None } // Ctrl+Y: redo
            4 if self.chars.is_empty() => Action::Eof,
            4 => { if self.cursor < self.chars.len() { self.chars.remove(self.cursor); } Action::None }
            8 | 127 if self.bash && self.chars.is_empty() => { self.bash = false; Action::None }
            8 | 127 => { if self.cursor > 0 { self.cursor -= 1; self.chars.remove(self.cursor); } Action::None }
            b'!' if self.chars.is_empty() && !self.bash && !self.paste => { self.bash = true; Action::None }
            16 => { self.history(true); Action::None } // Ctrl+P / Ctrl+N: history
            14 => { self.history(false); Action::None }
            1 => { self.cursor = 0; Action::None } // Ctrl+A / Ctrl+E
            5 => { self.cursor = self.chars.len(); Action::None }
            11 => { self.chars.truncate(self.cursor); Action::None } // Ctrl+K
            21 => { self.chars.drain(..self.cursor); self.cursor = 0; Action::None } // Ctrl+U
            23 => { // Ctrl+W: delete the preceding word
                while self.cursor > 0 && self.chars[self.cursor - 1].is_whitespace() {
                    self.cursor -= 1; self.chars.remove(self.cursor);
                }
                while self.cursor > 0 && !self.chars[self.cursor - 1].is_whitespace() {
                    self.cursor -= 1; self.chars.remove(self.cursor);
                }
                Action::None
            }
            0..=31 => Action::None,
            _ => {
                self.utf8.push(byte);
                match std::str::from_utf8(&self.utf8) {
                    Ok(text) => { let chars: Vec<char> = text.chars().collect(); self.utf8.clear(); for c in chars { self.insert(c); } }
                    Err(error) if error.error_len().is_some() || self.utf8.len() > 4 => self.utf8.clear(),
                    Err(_) => {}
                }
                Action::None
            }
        }
    }
    fn layout(&self) -> (Vec<String>, (usize, usize)) {
        let available = self.width.saturating_sub(BOX_CHROME);
        let mut lines = vec![String::new()];
        let (mut line, mut col) = (0usize, 0usize);
        let mut cursor = (0usize, 0usize);
        for (index, &ch) in self.chars.iter().enumerate() {
            if index == self.cursor { cursor = (line, col); }
            if ch == '\n' {
                lines.push(String::new()); line += 1; col = 0;
            } else {
                let width = cell_width(ch);
                if col + width > available && col > 0 {
                    lines.push(String::new()); line += 1; col = 0;
                    if index == self.cursor { cursor = (line, col); }
                }
                lines[line].push(ch); col += width;
            }
        }
        if self.cursor == self.chars.len() { cursor = (line, col); }
        (lines, cursor)
    }

    /// The box: `row` is its bottom border, `height` the most draft rows it shows. It grows upward
    /// with the draft, inside the `height + 2` rows the view reserved for it, and the reserved rows
    /// above it stay blank - the status line sits on the row above the reservation.
    /// Returns (first visible draft line, visible rows, top border row).
    fn frame_geometry(&self, lines: usize, cursor_line: usize) -> (usize, usize, usize) {
        let shown = lines.clamp(1, self.height);
        let first = cursor_line.saturating_sub(shown - 1).min(lines.saturating_sub(shown));
        (first, shown, self.bottom().saturating_sub(shown + 1))
    }

    fn drawable(&self) -> bool { self.bottom() > self.height + 1 && self.width >= 12 && self.height > 0 }

    /// Explicit placement avoids saved cursors moving with Windows scrollback.
    pub fn cursor_frame(&self) -> String {
        if !self.drawable() { return String::new(); }
        let (lines, cursor) = self.layout();
        let (first, _, top) = self.frame_geometry(lines.len(), cursor.0);
        format!("\x1b[{};{}H", top + 1 + cursor.0 - first, self.left(cursor.0) + 1 + cursor.1)
    }
    /// Where a draft line's text starts: after `❯ ` on the first line, and under it on the others.
    fn left(&self, _line: usize) -> usize { BOX_LEFT }

    /// The input box below the status line: a rounded border, `❯ ` on the first draft row, the
    /// draft wrapped inside it. Only the reserved rows are erased; the output scroll region never
    /// moves when Enter is pressed.
    pub fn render(&self) -> String {
        if !self.drawable() { return String::new(); }
        let (lines, cursor) = self.layout();
        let (first, shown, top) = self.frame_geometry(lines.len(), cursor.0);
        let bottom = self.bottom();
        let items = self.menu_items();
        let menu = items.len().min(MENU_MAX);
        let mut frame = String::from("\x1b[?25l");
        for (offset, row) in self.queued_rows().iter().enumerate() {
            frame.push_str(&format!("\x1b[{};1H\x1b[2K{row}", self.out_bottom() + 1 + offset));
        }
        // Between the status line (left alone: the ticker owns it) and the top divider.
        for row in self.status_row() + 1..top {
            frame.push_str(&format!("\x1b[{row};1H\x1b[2K"));
        }
        let border = if self.bash { BASH } else { BORDER };
        frame.push_str(&format!("\x1b[{top};1H\x1b[2K{border}{}{RESET}", "\u{2500}".repeat(self.width)));
        for visual in 0..shown {
            let index = first + visual;
            let text = lines.get(index).map(String::as_str).unwrap_or("");
            frame.push_str(&format!("\x1b[{};1H\x1b[2K", top + 1 + visual));
            if index == 0 && self.bash { frame.push_str(&format!("{BASH}! {RESET}")); }
            else { frame.push_str(if index == 0 { PROMPT } else { "  " }); }
            if self.chars.is_empty() && index == 0 {
                let placeholder = if self.bash { BASH_PLACEHOLDER } else { PLACEHOLDER };
                let hint: String = placeholder.chars().take(self.width.saturating_sub(BOX_CHROME)).collect();
                frame.push_str(&format!("{HINT}{hint}{RESET}"));
            } else {
                frame.push_str(text);
            }
        }
        frame.push_str(&format!("\x1b[{};1H\x1b[2K{border}{}{RESET}", bottom, "\u{2500}".repeat(self.width)));
        // The footer under the input - hints or the last run's numbers on the left, the model on the
        // right - and the slash menu above the input, opening upward toward the chat.
        let right: String = self.footer_right.chars().take(self.width / 2).collect();
        let right_width: usize = right.chars().map(cell_width).sum();
        let room = self.width.saturating_sub(right_width + if right.is_empty() { 0 } else { 1 });
        let bash_hint = BASH_FOOTER.to_string();
        let (color, text) = if !self.notice.is_empty() { (NOTICE, &self.notice) }
            else if self.bash { (BASH, &bash_hint) } else { (HINT, &self.footer) };
        let footer: String = text.chars().take(room).collect();
        frame.push_str(&format!("\x1b[{};1H\x1b[2K{color}{footer}{RESET}", self.row + 1));
        if !right.is_empty() {
            frame.push_str(&format!("\x1b[{};{}H{MODEL}{right}{RESET}", self.row + 1, self.width - right_width + 1));
        }
        if menu > 0 {
            let selected = self.menu_at.min(items.len() - 1);
            let first = selected.saturating_sub(MENU_MAX - 1).min(items.len().saturating_sub(MENU_MAX));
            let name_width = items.iter().map(|&i| self.commands[i].name.chars().count()).max().unwrap_or(0) + 3;
            for (offset, &index) in items.iter().skip(first).take(MENU_MAX).enumerate() {
                let command = &self.commands[index];
                let name = format!("{:<name_width$}", command.name);
                let room = self.width.saturating_sub(name.chars().count() + 1);
                let hint: String = command.hint.chars().take(room).collect();
                let color = if first + offset == selected { SELECTED } else { RESET };
                frame.push_str(&format!("\x1b[{};1H\x1b[2K{color}{name}{RESET}{HINT}{hint}{RESET}", top - menu + offset));
            }
        }
        frame.push_str(&format!("\x1b[{};{}H", top + 1 + cursor.0 - first, self.left(cursor.0) + 1 + cursor.1));
        frame.push_str("\x1b[?25h");
        frame
    }
}

/// `❯ ` before the draft (Claude Code's prompt glyph, U+276F: three bytes, one cell); no side
/// borders and no padding - a divider above and below.
pub const PROMPT: &str = "\u{276f} ";
const BOX_LEFT: usize = 2;
const BOX_CHROME: usize = BOX_LEFT;
const BORDER: &str = "\x1b[38;2;136;136;136m";
/// Bash mode's colour: Claude Code's pink.
const BASH: &str = "\x1b[38;2;253;93;177m";
const BASH_PLACEHOLDER: &str = "Run a shell command";
const BASH_FOOTER: &str = "! for bash mode \u{b7} output goes into the context, no model turn \u{b7} esc to exit";
const HINT: &str = "\x1b[38;2;119;119;119m";
const SELECTED: &str = "\x1b[38;2;177;185;249m";
const MODEL: &str = "\x1b[38;2;153;153;153m";
const RESET: &str = "\x1b[0m";
/// The footer's one-keystroke notice and the queued-steer label: the view's warm accent.
const NOTICE: &str = "\x1b[38;2;215;119;87m";
const QUEUED: &str = "\x1b[38;2;215;119;87m";
/// `/vault <name> <value>` carries a key (lua/core/keys.lua): it is submitted, never kept for Up to
/// bring back. A bare `/vault <name>` holds nothing secret and is kept like any command.
pub fn carries_secret(line: &str) -> bool {
    let line = line.trim_start();
    line.strip_prefix("/vault").map(|rest| rest.starts_with(char::is_whitespace)
        && rest.split_whitespace().nth(1).is_some()).unwrap_or(false)
}

/// The most queued lines listed above the status line; the last row counts any beyond.
const QUEUED_MAX: usize = 3;
const PLACEHOLDER: &str = "Type a message, or / for commands";

/// A panel over the bottom of the screen, the way Claude Code shows `/model` or `/usage`: a title, a
/// few lines, then a list to pick from or a field to type in, and Esc closes it. Lua describes it
/// (`host.panel`) and gets back what the reader chose; while it is open every keystroke is its own.
///
/// A secret field shows bullets and nothing else, never enters the editor's history and never
/// reaches the transcript: its text goes only into the result handed to the caller.
#[derive(Default)]
pub struct Panel {
    pub title: String, pub lines: Vec<String>, pub options: Vec<(String, String)>, pub selected: usize,
    pub input: Option<bool>, pub placeholder: String, pub hint: String,
    text: Vec<char>, escape: Vec<u8>, paste: bool, utf8: Vec<u8>,
    pub result: Option<serde_json::Value>, pub width: usize, pub rows: usize,
}

impl Panel {
    pub fn from_spec(spec: &serde_json::Value, width: usize, rows: usize) -> Panel {
        let text = |key: &str| spec.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string();
        let lines = spec.get("lines").and_then(|v| v.as_array()).map(|a| a.iter()
            .map(|l| l.as_str().unwrap_or("").to_string()).collect()).unwrap_or_default();
        let options: Vec<(String, String)> = spec.get("options").and_then(|v| v.as_array()).map(|a| a.iter().map(|o| (
            o.get("label").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            o.get("hint").and_then(|v| v.as_str()).unwrap_or("").to_string())).collect()).unwrap_or_default();
        let input = match spec.get("input").and_then(|v| v.as_str()) { Some("secret") => Some(true), Some("text") => Some(false), _ => None };
        let selected = spec.get("selected").and_then(|v| v.as_u64()).map(|n| (n as usize).saturating_sub(1)).unwrap_or(0)
            .min(options.len().saturating_sub(1));
        let hint = match text("hint") {
            h if !h.is_empty() => h,
            _ if input.is_some() => "Enter to save \u{b7} Esc to cancel".into(),
            _ if !options.is_empty() => "\u{2191}\u{2193} to move \u{b7} Enter to select \u{b7} Esc or \u{2190} to go back".into(),
            _ => "Esc or \u{2190} to go back".into(),
        };
        Panel { title: text("title"), lines, options, selected, input, placeholder: text("placeholder"), hint, width, rows, ..Default::default() }
    }

    /// How many options are on screen at once; the window follows the selection.
    fn visible_options(&self) -> usize {
        let fixed = 2 + 2 + self.lines.len() + 1 + 2; // dividers, title + gap, lines, gap, gap + hint
        self.options.len().min(PANEL_OPTIONS).min(self.rows.saturating_sub(fixed + 2).max(1))
    }
    fn body(&self) -> usize {
        let choice = if self.input.is_some() { 2 } else if self.options.is_empty() { 0 } else { 1 + self.visible_options() };
        2 + self.lines.len() + choice + 2
    }
    pub fn pasting(&self) -> bool { self.paste }
    /// Rows the panel takes, borders included.
    pub fn height(&self) -> usize { (self.body() + 2).min(self.rows.saturating_sub(2)) }

    fn finish(&mut self, value: serde_json::Value) { self.result = Some(value); }
    /// A lone Esc: back to the chat.
    pub fn escape(&mut self) { self.escape.clear(); self.finish(serde_json::json!({"action": "cancel"})); }

    pub fn feed(&mut self, byte: u8) {
        if !self.escape.is_empty() {
            self.escape.push(byte);
            let seq = self.escape.as_slice();
            if seq == b"\x1b\x1b" { return self.escape(); }
            if seq.len() == 2 && !matches!(byte, b'[' | b'O') { self.escape.clear(); return; } // Alt+key: ignored
            if seq == b"\x1b[200~" { self.paste = true; self.escape.clear(); return; }
            if seq == b"\x1b[201~" { self.paste = false; self.escape.clear(); return; }
            if seq.len() >= 3 && (0x40..=0x7e).contains(&byte) {
                if !self.options.is_empty() && (seq == b"\x1b[A" || seq == b"\x1bOA") {
                    self.selected = (self.selected + self.options.len() - 1) % self.options.len();
                } else if !self.options.is_empty() && (seq == b"\x1b[B" || seq == b"\x1bOB") {
                    self.selected = (self.selected + 1) % self.options.len();
                } else if (seq == b"\x1b[D" || seq == b"\x1bOD") && self.text.is_empty() {
                    // Left goes back, as Esc does - unless there is typed text a reader may be editing.
                    return self.escape();
                }
                self.escape.clear();
            } else if seq.len() > 16 { self.escape.clear(); }
            return;
        }
        match byte {
            0x1b => self.escape.push(byte),
            3 => self.escape(),
            b'\r' | b'\n' if self.paste => {}
            b'\r' | b'\n' => {
                if self.input.is_some() {
                    let text: String = self.text.iter().collect();
                    self.finish(serde_json::json!({"action": "submit", "text": text.trim()}));
                } else if !self.options.is_empty() {
                    self.finish(serde_json::json!({"action": "select", "index": self.selected + 1}));
                } else {
                    self.escape(); // a panel that only shows something: Enter closes it too
                }
            }
            8 | 127 if self.input.is_some() => { self.text.pop(); }
            21 if self.input.is_some() => self.text.clear(),
            b'1'..=b'9' if self.input.is_none() && ((byte - b'0') as usize) <= self.options.len() => {
                self.selected = (byte - b'1') as usize;
                self.finish(serde_json::json!({"action": "select", "index": self.selected + 1}));
            }
            0..=31 => {}
            _ if self.input.is_some() => {
                self.utf8.push(byte);
                match std::str::from_utf8(&self.utf8) {
                    Ok(text) => { let chars: Vec<char> = text.chars().filter(|c| !c.is_whitespace()).collect(); self.utf8.clear(); self.text.extend(chars); }
                    Err(error) if error.error_len().is_some() || self.utf8.len() > 4 => self.utf8.clear(),
                    Err(_) => {}
                }
            }
            _ => {}
        }
    }

    /// The panel, anchored to the bottom row, and the cursor where typing goes (hidden otherwise):
    /// a divider above and below, and the text at the edge - no box, no padding.
    pub fn render(&self) -> String {
        let w = self.width.max(20);
        // Colour sequences (`ESC [ ... m`, a `/status` bar) take no cells: copied through, not counted.
        let fit = |text: &str| -> String {
            let mut out = String::new(); let mut used = 0; let mut sequence = false;
            for ch in text.chars() {
                if sequence { out.push(ch); if ch.is_ascii_alphabetic() { sequence = false; } continue; }
                if ch == '\x1b' { out.push(ch); sequence = true; continue; }
                let cw = cell_width(ch); if used + cw > w { break; } out.push(ch); used += cw;
            }
            if sequence || out.contains('\x1b') { out.push_str(RESET); }
            out
        };
        let mut rows: Vec<String> = Vec::new();
        rows.push(format!("\x1b[1m{}{RESET}", fit(&self.title)));
        rows.push(String::new());
        for text in &self.lines { rows.push(fit(text)); }
        let mut cursor = None;
        if let Some(secret) = self.input {
            rows.push(String::new());
            let (body, col) = if self.text.is_empty() {
                (format!("{PROMPT}{HINT}{}{RESET}", fit(&self.placeholder)), 2)
            } else if secret {
                let n = self.text.len();
                let dots = n.min(w.saturating_sub(20));
                (format!("{PROMPT}{}{HINT} ({n} characters){RESET}", "\u{2022}".repeat(dots)), 2 + dots)
            } else {
                let shown = fit(&format!("{PROMPT}{}", self.text.iter().collect::<String>()));
                let used = shown.chars().map(cell_width).sum();
                (shown, used)
            };
            cursor = Some((rows.len(), col));
            rows.push(body);
        } else if !self.options.is_empty() {
            rows.push(String::new());
            let label_width = self.options.iter().map(|(l, _)| l.chars().count()).max().unwrap_or(0) + 2;
            let shown = self.visible_options();
            let start = self.selected.saturating_sub(shown - 1).min(self.options.len() - shown);
            for (index, (label, hint)) in self.options.iter().enumerate().skip(start).take(shown) {
                let mark = if index == self.selected { "\u{276f}" } else { " " };
                let digits = self.options.len().to_string().len();
                let head = fit(&format!("{mark} {:>digits$}. {:<label_width$}", index + 1, label));
                let room = w.saturating_sub(head.chars().map(cell_width).sum());
                let tail: String = hint.chars().take(room).collect();
                rows.push(if index == self.selected { format!("{SELECTED}{head}{tail}{RESET}") }
                    else { format!("{head}{HINT}{tail}{RESET}") });
            }
        }
        rows.push(String::new());
        let hint = if self.options.len() > self.visible_options() {
            format!("{} \u{b7} {}/{}", self.hint, self.selected + 1, self.options.len())
        } else { self.hint.clone() };
        rows.push(format!("{HINT}{}{RESET}", fit(&hint)));
        let keep = self.height().saturating_sub(2);
        if rows.len() > keep {
            let drop = (rows.len() - keep).min(rows.len().saturating_sub(2));
            rows.drain(2..2 + drop);
            if let Some((row, _)) = cursor.as_mut() { *row -= drop; }
        }
        let top = self.rows.saturating_sub(rows.len() + 1);
        let divider = format!("{PANEL}{}{RESET}", "\u{2500}".repeat(w));
        let mut frame = format!("\x1b[?25l\x1b[{top};1H\x1b[2K{divider}");
        for (offset, row) in rows.iter().enumerate() { frame.push_str(&format!("\x1b[{};1H\x1b[2K{row}", top + 1 + offset)); }
        frame.push_str(&format!("\x1b[{};1H\x1b[2K{divider}", self.rows));
        if let Some((row, col)) = cursor { frame.push_str(&format!("\x1b[{};{}H\x1b[?25h", top + 1 + row, col + 1)); }
        frame
    }
}

/// The most options a panel lists at once (a long model list scrolls).
const PANEL_OPTIONS: usize = 10;
const PANEL: &str = "\x1b[38;2;177;185;249m";

pub fn cell_width_of(ch: char) -> usize { cell_width(ch) }

/// `text` cut to `room` terminal cells, ending in `…` when it was cut.
fn clip_cells(text: &str, room: usize) -> String {
    let total: usize = text.chars().map(cell_width).sum();
    if total <= room { return text.to_string(); }
    let mut out = String::new(); let mut used = 0;
    for ch in text.chars() {
        let width = cell_width(ch);
        if used + width + 1 > room { break; }
        out.push(ch); used += width;
    }
    if room > 0 { out.push('\u{2026}'); }
    out
}

// UTF-8 is not a terminal column count. Keep CJK and emoji inside the viewport;
// combining marks share their preceding cell. A full grapheme engine would also
// handle ZWJ sequences, but this covers the common terminal width contract.
fn cell_width(ch: char) -> usize {
    let cp = ch as u32;
    // Text variation selectors and zero-width joiners take no cell; the emoji selector U+FE0F
    // (`❤️` = `❤` + it) widens its base to two cells, so it counts as the second (the default 1).
    // lua/core/markdown.lua (`cell`) is this function's twin: a table Lua lays out is wrapped here.
    if (0x300..=0x36f).contains(&cp) || (0x1ab0..=0x1aff).contains(&cp)
        || (0xfe00..=0xfe0e).contains(&cp) || (0x200b..=0x200d).contains(&cp) { return 0; }
    if (0x1100..=0x115f).contains(&cp) || (0x2e80..=0xa4cf).contains(&cp)
        || (0xac00..=0xd7a3).contains(&cp) || (0xf900..=0xfaff).contains(&cp)
        || (0xfe10..=0xfe6f).contains(&cp) || (0xff01..=0xff60).contains(&cp)
        || (0x1f300..=0x1faff).contains(&cp) { 2 } else { 1 }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_panel_line_with_colour_is_fitted_by_its_visible_cells() {
        let spec = serde_json::json!({"title": "Status", "lines": ["\x1b[38;2;1;2;3m\u{2588}\u{2588}\x1b[0m 5%"]});
        let panel = Panel::from_spec(&spec, 20, 30);
        let frame = panel.render();
        assert!(frame.contains("\x1b[38;2;1;2;3m\u{2588}\u{2588}\x1b[0m 5%"), "colour kept whole: {frame:?}");
        let narrow = Panel::from_spec(&serde_json::json!({"title": "t", "lines": [format!("\x1b[1m{}", "x".repeat(40))]}), 20, 30);
        assert!(narrow.render().contains(&format!("\x1b[1m{}\x1b[0m", "x".repeat(20))), "cut at 20 cells, then reset");
    }
    fn type_bytes(editor: &mut Editor, bytes: &[u8]) -> Action {
        let mut action = Action::None;
        for &byte in bytes { action = editor.feed(byte); }
        action
    }
    #[test]
    fn bang_on_an_empty_draft_is_bash_mode_and_submits_with_its_bang() {
        let mut e = Editor::default();
        assert_eq!(e.feed(b'!'), Action::None);
        assert!(e.bash && e.text().is_empty(), "the ! is the mode, not text");
        type_bytes(&mut e, b"ls -la");
        assert_eq!(e.feed(b'\r'), Action::Submit("!ls -la".into()));
        assert!(!e.bash, "a submitted line leaves bash mode");
        type_bytes(&mut e, b"\x1b[A");
        assert!(e.bash && e.text() == "ls -la", "a recalled !command comes back in bash mode");
        let mut e = Editor::default();
        e.feed(b'!'); e.feed(127);
        assert!(!e.bash, "backspace on the empty draft leaves bash mode");
        e.feed(b'!'); e.escape.push(0x1b);
        assert!(e.escape() && !e.bash, "so does Esc");
        type_bytes(&mut e, b"a!b");
        assert!(!e.bash && e.text() == "a!b", "a ! inside a draft is just a character");
    }
    #[test]
    fn left_or_esc_closes_a_panel_and_enter_closes_one_that_only_shows() {
        let mut panel = Panel::from_spec(&serde_json::json!({"title": "Status", "lines": ["a", "b"]}), 80, 40);
        for &b in b"\x1b[D" { panel.feed(b); }
        assert_eq!(panel.result, Some(serde_json::json!({"action": "cancel"})));
        let mut panel = Panel::from_spec(&serde_json::json!({"title": "Status", "lines": ["a"]}), 80, 40);
        panel.feed(b'\r');
        assert_eq!(panel.result, Some(serde_json::json!({"action": "cancel"})));
        let mut panel = Panel::from_spec(&serde_json::json!({"title": "Key", "input": "secret"}), 80, 40);
        panel.feed(b'x');
        for &b in b"\x1b[D" { panel.feed(b); }
        assert_eq!(panel.result, None, "Left with typed text does not throw the text away");
    }
    #[test]
    fn a_vault_line_with_a_value_never_enters_the_history() {
        assert!(carries_secret("/vault github ghp_abc"));
        assert!(carries_secret("  /vault a b c"));
        assert!(!carries_secret("/vault github"), "a name alone is not a secret");
        assert!(!carries_secret("/vaults x y"));
        let mut e = Editor::default();
        type_bytes(&mut e, b"/vault github ghp_abc\r");
        type_bytes(&mut e, b"hello\r");
        type_bytes(&mut e, b"\x1b[A"); assert_eq!(e.text(), "hello");
        type_bytes(&mut e, b"\x1b[A"); assert_eq!(e.text(), "hello", "the vault line was never kept");
    }
    #[test]
    fn a_lone_escape_does_not_eat_the_next_key() {
        let mut e = Editor::default();
        type_bytes(&mut e, b"\x1bab");
        assert_eq!(e.text(), "ab");
        type_bytes(&mut e, b"\x1b[D!");
        assert_eq!(e.text(), "a!b", "real sequences still work");
    }
    #[test]
    fn ctrl_c_never_wipes_the_draft() {
        let mut e = Editor::default(); e.row = 20; e.width = 60; e.height = 3;
        type_bytes(&mut e, b"draft");
        assert_eq!(e.feed(3), Action::None, "idle with a draft: nothing happens to it");
        assert_eq!(e.text(), "draft");
        assert!(e.render().contains("Draft kept"), "and the footer says how to clear it");
        assert_eq!(e.feed(3), Action::None, "a second one does not quit and lose the draft");
        assert_eq!(e.text(), "draft");
        e.status = true;
        assert_eq!(e.feed(3), Action::Interrupt, "during a run it interrupts the turn");
        assert_eq!(e.feed(3), Action::Interrupt, "again and again, never quitting over a draft");
        assert_eq!((e.text().as_str(), e.cursor), ("draft", 5), "the draft and cursor are untouched");
        assert!(e.render().contains("Interrupting\u{2026} (draft kept)"));
        type_bytes(&mut e, b"!");
        assert!(!e.render().contains("Interrupting"), "the notice lasts one keystroke");
    }
    #[test]
    fn ctrl_c_on_an_empty_line_interrupts_then_quits() {
        let mut e = Editor::default();
        assert_eq!(e.feed(3), Action::Interrupt, "an empty line interrupts the turn");
        assert_eq!(e.feed(3), Action::Eof, "a second Ctrl+C within a second quits");
    }
    #[test]
    fn ctrl_z_undoes_words_and_ctrl_y_redoes() {
        let mut e = Editor::default();
        type_bytes(&mut e, b"hello world");
        e.feed(26); assert_eq!((e.text().as_str(), e.cursor), ("hello", 5), "one undo takes back the last word");
        e.feed(26); assert_eq!(e.text(), "", "and the next one the word before it");
        e.feed(26); assert_eq!(e.text(), "", "nothing left to undo is harmless");
        e.feed(25); assert_eq!(e.text(), "hello");
        e.feed(25); assert_eq!((e.text().as_str(), e.cursor), ("hello world", 11), "Ctrl+Y redoes, cursor and all");
        type_bytes(&mut e, b"\x1b[122;5u"); assert_eq!(e.text(), "hello", "kitty's Ctrl+Z undoes too");
        type_bytes(&mut e, b"\x1b[122;6u"); assert_eq!(e.text(), "hello world", "and Ctrl+Shift+Z redoes");
    }
    #[test]
    fn deletes_kills_pastes_and_recalls_are_steps() {
        let mut e = Editor::default();
        type_bytes(&mut e, b"older\r");
        type_bytes(&mut e, b"abc def");
        type_bytes(&mut e, b"\x7f"); assert_eq!(e.text(), "abc de");
        type_bytes(&mut e, b"\x17"); assert_eq!(e.text(), "abc ", "Ctrl+W");
        type_bytes(&mut e, b"\x1b[200~pasted\ntext\x1b[201~"); assert_eq!(e.text(), "abc pasted\ntext");
        type_bytes(&mut e, b"\x01\x0b"); assert_eq!(e.text(), "", "Ctrl+A then Ctrl+K");
        e.feed(26); assert_eq!((e.text().as_str(), e.cursor), ("abc pasted\ntext", 0), "undo the kill, cursor where it was");
        e.feed(26); assert_eq!((e.text().as_str(), e.cursor), ("abc ", 4), "the whole paste is one step");
        e.feed(26); assert_eq!(e.text(), "abc de", "then the Ctrl+W");
        e.feed(26); assert_eq!(e.text(), "abc def", "then the Backspace");
        type_bytes(&mut e, b"\x1b[A"); assert_eq!(e.text(), "older", "a history recall...");
        e.feed(26); assert_eq!(e.text(), "abc def", "...is undone like any other step");
        type_bytes(&mut e, b"x");
        e.feed(25); assert_eq!(e.text(), "abc defx", "a new edit drops the redo branch");
        assert_eq!(type_bytes(&mut e, b"\r"), Action::Submit("abc defx".into()));
        e.feed(26); assert_eq!(e.text(), "", "a sent message is not undone back into the box");
    }
    #[test]
    fn moving_the_cursor_starts_a_new_undo_step() {
        let mut e = Editor::default();
        type_bytes(&mut e, b"abc\x1b[Dx");
        assert_eq!(e.text(), "abxc");
        e.feed(26); assert_eq!((e.text().as_str(), e.cursor), ("abc", 2));
        e.feed(26); assert_eq!(e.text(), "");
    }
    #[test]
    fn the_prompt_glyph_is_one_cell() {
        assert_eq!(PROMPT, "\u{276f} ");
        assert_eq!(PROMPT.len(), 4, "three UTF-8 bytes and a space");
        assert_eq!(PROMPT.chars().map(cell_width).sum::<usize>(), BOX_LEFT, "but two cells: the draft starts at BOX_LEFT");
        let mut e = Editor::default(); e.row = 20; e.width = 24; e.height = 3;
        type_bytes(&mut e, b"abc");
        assert!(e.render().contains("\x1b[19;1H\x1b[2K\u{276f} abc"));
        assert_eq!(e.cursor_frame(), "\x1b[19;6H", "the cursor counts cells, not bytes");
    }
    #[test]
    fn a_queued_steer_sits_above_the_status_line() {
        let mut e = Editor::default(); e.row = 20; e.width = 80; e.height = 3;
        e.queued = vec!["use the new requirement".into()];
        assert_eq!(e.out_bottom(), 17, "idle: nothing is listed, the chat sits on the box");
        e.status = true;
        assert_eq!(e.status_row(), 17);
        assert_eq!(e.out_bottom(), 15, "a run: the status row and one queued row come out of the chat");
        let frame = e.render();
        assert!(frame.contains("\x1b[16;1H\x1b[2K\x1b[38;2;215;119;87m\u{21aa} Steering queued\x1b[0m"), "{frame:?}");
        assert!(frame.contains("next safe boundary: \x1b[0muse the new requirement"), "the UI's wording, then the text");
        e.queued = vec!["x".repeat(200), "/model".into(), "two".into(), "three".into()];
        assert_eq!(e.out_bottom(), 13, "at most three rows");
        let frame = e.render();
        assert!(frame.contains("\u{2026}"), "a long steer is clipped to the row");
        assert!(frame.contains("Queued\x1b[0m\x1b[38;2;119;119;119m \u{b7} after the run: \x1b[0m/model"), "a command waits for the run's end");
        assert!(frame.contains("\u{21aa} 2 more queued"), "the last row counts the rest");
        for line in e.queued_rows() {
            let shown: String = { let mut out = String::new(); let mut skip = false;
                for c in line.chars() { if c == '\x1b' { skip = true } else if skip { if c == 'm' { skip = false } } else { out.push(c) } } out };
            assert!(shown.chars().map(cell_width).sum::<usize>() <= 80, "{shown}");
        }
        e.queued.clear();
        assert_eq!(e.out_bottom(), 16, "taken by the agent: the rows go back to the chat");
    }
    #[test]
    fn edit_submit_history_and_multiline() {
        let mut e = Editor::default(); e.row = 24; e.width = 30; e.height = 3;
        type_bytes(&mut e, b"ac\x1b[Db");
        assert_eq!(e.text(), "abc");
        assert_eq!(type_bytes(&mut e, b"\r"), Action::Submit("abc".into()));
        assert!(!e.render().contains("abc"), "submitted text is gone immediately");
        type_bytes(&mut e, b"\x1b[A"); assert_eq!(e.text(), "abc");
        type_bytes(&mut e, b"\x1b[B"); assert_eq!(e.text(), "");
        type_bytes(&mut e, b"one\ntwo");
        assert_eq!(type_bytes(&mut e, b"\r"), Action::Submit("one\ntwo".into()));
    }
    #[test]
    fn paste_and_utf8_are_data_not_commands() {
        let mut e = Editor::default();
        type_bytes(&mut e, b"\x1b[200~hello\nworld\x1b[201~");
        assert_eq!(e.text(), "hello\nworld");
        type_bytes(&mut e, " é".as_bytes()); assert_eq!(e.text(), "hello\nworld é");
        type_bytes(&mut e, b"\x1b[H\x1b[3~"); assert_eq!(e.text(), "ello\nworld é");
    }
    #[test]
    fn multiline_is_visible_and_submit_resets_all_rows() {
        let mut e = Editor::default(); e.row = 12; e.width = 20; e.height = 3;
        type_bytes(&mut e, b"first\x1b[13;2usecond");
        assert!(e.render().contains("\u{276f} first") && e.render().contains("\x1b[2K  second"), "continuation lines start under the first line's text");
        assert_eq!(type_bytes(&mut e, b"\r"), Action::Submit("first\nsecond".into()));
        assert!(!e.render().contains("first") && !e.render().contains("second"));
    }
    #[test]
    fn orca_shift_enter_and_modified_enter_keep_the_draft() {
        for sequence in [b"\x1b\r".as_slice(), b"\x1b\n", b"\x1b[13;2u", b"\x1b[27;2;13~", b"\x1b[13;2~"] {
            let mut e = Editor::default();
            type_bytes(&mut e, b"first");
            assert_eq!(type_bytes(&mut e, sequence), Action::None);
            type_bytes(&mut e, b"second");
            assert_eq!(type_bytes(&mut e, b"\r"), Action::Submit("first\nsecond".into()));
        }
    }
    #[test]
    fn redraw_places_the_cursor_at_the_edited_multiline_draft() {
        let mut e = Editor::default(); e.row = 14; e.width = 20; e.height = 3;
        type_bytes(&mut e, b"first\x1b\rsecond\x1b[D\x1b[D");
        assert_eq!(e.cursor_frame(), "\x1b[13;7H");
        assert!(e.render().ends_with("\x1b[13;7H\x1b[?25h"));
        e.row = 24;
        assert_eq!(e.cursor_frame(), "\x1b[23;7H", "a resize moves the cursor with the draft");
    }
    #[test]
    fn the_box_hugs_the_draft_and_grows_upward() {
        let mut e = Editor::default(); e.row = 20; e.width = 24; e.height = 3;
        let empty = e.render();
        assert!(empty.contains("\x1b[18;1H\x1b[2K\x1b[38;2;136;136;136m\u{2500}"), "an empty draft: the top divider on row 18");
        assert!(empty.contains("\x1b[20;1H\x1b[2K\x1b[38;2;136;136;136m\u{2500}") && !empty.contains("\u{2502}"), "the bottom divider on the editor row, and no side borders");
        assert!(empty.contains(PLACEHOLDER.split(',').next().unwrap()), "an empty box shows the hint");
        assert_eq!(e.cursor_frame(), "\x1b[19;3H", "the cursor sits after `❯ `, at the edge");
        type_bytes(&mut e, b"one\ntwo");
        let two = e.render();
        assert!(two.contains("\x1b[17;1H\x1b[2K\x1b[38;2;136;136;136m\u{2500}"), "two rows: the top divider moves up one");
        assert_eq!(e.out_bottom(), 16, "and the output ends right above it: nothing reserved");
        assert!(!two.contains(PLACEHOLDER), "no hint once there is a draft");
    }
    fn commands() -> Vec<Command> {
        ["/help", "/login", "/logout-all", "/remember"].iter().map(|name| Command {
            name: name.to_string(), args: *name == "/remember", hint: format!("hint for {name}") }).collect()
    }
    #[test]
    fn slash_opens_the_menu_and_enter_runs_the_selection() {
        let mut e = Editor::default(); e.row = 29; e.width = 60; e.height = 3; e.commands = commands();
        assert_eq!(e.bottom(), 29, "no menu: the box sits above the footer");
        assert_eq!(e.status_row(), 26, "idle: the row above the top divider (no status row reserved)");
        assert_eq!(e.out_bottom(), 26, "so the output ends right on the input");
        e.status = true;
        assert_eq!(e.out_bottom(), 25, "a run gives the status line its own row");
        e.status = false;
        type_bytes(&mut e, b"/");
        assert_eq!(e.menu_rows(), 4, "`/` lists every command");
        assert_eq!(e.bottom(), 29, "the box stays where it is");
        assert_eq!(e.status_row(), 22, "the menu opens upward: two empty box rows, two from the output");
        let frame = e.render();
        assert!(frame.contains("\x1b[23;1H\x1b[2K\x1b[38;2;177;185;249m/help"), "first command right under the status line, at the edge");
        assert!(frame.contains("\x1b[26;1H\x1b[2K") && frame.contains("/remember"), "last one right above the box (top border on 27)");
        assert!(frame.contains("\x1b[30;1H"), "and the footer stays under the box");
        type_bytes(&mut e, b"lo");
        assert_eq!(e.menu_rows(), 2, "typing narrows it");
        type_bytes(&mut e, b"\x1b[B");
        assert_eq!(e.text(), "/lo", "arrows move the selection, not the history");
        assert_eq!(type_bytes(&mut e, b"\r"), Action::Submit("/logout-all".into()), "Enter runs the selected command");
        assert_eq!(e.menu_rows(), 0);
    }
    #[test]
    fn tab_completes_and_esc_closes_the_menu() {
        let mut e = Editor::default(); e.row = 29; e.width = 60; e.height = 3; e.commands = commands();
        type_bytes(&mut e, b"/rem\t");
        assert_eq!(e.text(), "/remember ", "a command with arguments completes with a space");
        assert_eq!(e.menu_rows(), 0, "and the menu gets out of the way of the arguments");
        let mut e = Editor::default(); e.row = 29; e.width = 60; e.height = 3; e.commands = commands();
        type_bytes(&mut e, b"/h");
        assert!(e.escape(), "Esc closes an open menu");
        assert_eq!(e.menu_rows(), 0);
        assert_eq!(e.text(), "/h", "and keeps the draft");
        type_bytes(&mut e, b"e");
        assert_eq!(e.menu_rows(), 1, "typing again reopens it");
    }
    #[test]
    fn a_panel_selects_cancels_and_keeps_a_secret_out_of_its_frame() {
        let spec = serde_json::json!({"title": "Sign in", "options": [{"label": "ChatGPT"}, {"label": "OpenCode Go"}]});
        let mut p = Panel::from_spec(&spec, 60, 30);
        assert!(p.render().contains("\u{276f} 1. ChatGPT"));
        type_panel(&mut p, b"\x1b[B\r");
        assert_eq!(p.result.take(), Some(serde_json::json!({"action": "select", "index": 2})));
        type_panel(&mut p, b"1");
        assert_eq!(p.result.take(), Some(serde_json::json!({"action": "select", "index": 1})), "a digit picks directly");
        p.escape();
        assert_eq!(p.result.take(), Some(serde_json::json!({"action": "cancel"})));
        let mut k = Panel::from_spec(&serde_json::json!({"title": "Key", "input": "secret"}), 60, 30);
        type_panel(&mut k, b"\x1b[200~sk-abcdef123456\n\x1b[201~");
        let frame = k.render();
        assert!(!frame.contains("abcdef") && frame.contains("(15 characters)"), "the frame shows bullets, never the key");
        type_panel(&mut k, b"\r");
        assert_eq!(k.result.take(), Some(serde_json::json!({"action": "submit", "text": "sk-abcdef123456"})));
    }
    fn type_panel(p: &mut Panel, bytes: &[u8]) { for &b in bytes { p.feed(b); } }
    #[test]
    fn a_long_list_scrolls_with_the_selection() {
        let options: Vec<serde_json::Value> = (1..=37).map(|n| serde_json::json!({"label": format!("model-{n:02}")})).collect();
        let mut p = Panel::from_spec(&serde_json::json!({"title": "Select model", "options": options, "selected": 30}), 60, 30);
        let frame = p.render();
        assert!(frame.contains("\u{276f} 30. model-30") && !frame.contains(" 9. model-09"), "the selected model is on screen");
        assert!(!frame.contains("model-01") && frame.contains("30/37"), "ten at a time, with the position");
        type_panel(&mut p, b"\x1b[B\x1b[B");
        assert!(p.render().contains("\u{276f} 32. model-32"), "and the window follows the arrows");
        assert!(p.height() <= 30, "the panel fits the screen");
    }
    #[test]
    fn up_and_down_walk_the_messages_and_ctrl_up_goes_to_the_transcript() {
        let mut e = Editor::default();
        type_bytes(&mut e, b"first\r"); type_bytes(&mut e, b"second\r");
        type_bytes(&mut e, b"\x1b[A"); assert_eq!(e.text(), "second", "Up: the previous message");
        type_bytes(&mut e, b"\x1b[A"); assert_eq!(e.text(), "first");
        type_bytes(&mut e, b"\x1b[B"); assert_eq!(e.text(), "second", "Down: the next one");
        type_bytes(&mut e, b"\x1b[B"); assert_eq!(e.text(), "", "and back to an empty draft");
        type_bytes(&mut e, b"/login\r"); type_bytes(&mut e, b"/help\r");
        e.commands = commands();
        type_bytes(&mut e, b"\x1b[A"); assert_eq!(e.text(), "/help");
        type_bytes(&mut e, b"\x1b[A"); assert_eq!(e.text(), "/login", "a recalled command does not open the menu");
        type_bytes(&mut e, b"\x1b[B"); assert_eq!(e.text(), "/help", "so Down walks forward again");
        type_bytes(&mut e, b"\x1b[B"); assert_eq!(e.text(), "");
        e.commands.clear();
        assert_eq!(type_bytes(&mut e, b"\x1b[1;5A"), Action::Nav, "Ctrl+Up enters the transcript");
        assert_eq!(type_bytes(&mut e, b"\x1b[5~"), Action::PageUp);
        assert_eq!(type_bytes(&mut e, b"\x1b[6~"), Action::PageDown);
    }
    #[test]
    fn up_and_down_move_between_draft_lines_before_the_history() {
        let mut e = Editor::default(); e.row = 24; e.width = 30; e.height = 3;
        type_bytes(&mut e, b"older\r");
        type_bytes(&mut e, b"one\ntwo\nthree");
        type_bytes(&mut e, b"\x1b[A"); assert_eq!(e.text(), "one\ntwo\nthree", "Up on the last line moves up a line");
        type_bytes(&mut e, b"\x1b[A"); assert_eq!(e.cursor, 3, "column kept, clamped to the shorter line");
        type_bytes(&mut e, b"\x1b[A"); assert_eq!(e.text(), "older", "Up on the first line: the previous message");
        type_bytes(&mut e, b"\x1b[B"); assert_eq!(e.text(), "one\ntwo\nthree", "Down on the last line: forward, back to the draft");
        type_bytes(&mut e, b"\x1b[H\x1b[B"); assert_eq!(e.cursor, 4, "Down from the first line moves a line");
    }
    #[test]
    fn long_draft_does_not_wrap_terminal() {
        let mut e = Editor::default(); e.row = 15; e.width = 12; e.height = 3;
        type_bytes(&mut e, b"abcdefghijklmnopqrstuvwxyz0123456789");
        assert!(e.render().contains("uvwxyz0123") && e.render().contains("456789"));
        assert!(!e.render().contains("\u{276f} abcdef"), "older rows scroll out of the editor");
        assert_eq!(type_bytes(&mut e, b"\r"), Action::Submit("abcdefghijklmnopqrstuvwxyz0123456789".into()));
    }
    #[test]
    fn the_footer_shows_the_model_on_the_right() {
        let mut e = Editor::default(); e.row = 20; e.width = 40; e.height = 3;
        e.footer = "/ for commands".into(); e.footer_right = "gpt-6-luna".into();
        let frame = e.render();
        assert!(frame.contains("\x1b[21;1H\x1b[2K\x1b[38;2;119;119;119m/ for commands"), "hints at the left edge");
        assert!(frame.contains("\x1b[21;31H\x1b[38;2;153;153;153mgpt-6-luna"), "the model ends at the right edge");
    }

}
