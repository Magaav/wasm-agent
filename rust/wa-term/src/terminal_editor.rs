//! The interactive CLI's input row. This is a terminal capability, not agent logic:
//! Lua decides what to do with submitted lines. A reader thread owns keystrokes so it
//! can redraw a draft even while Lua is blocked in the model or a tool.
use crate::keymap;
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
    let dir = std::path::PathBuf::from(wa_host_support::paths::resolve_home()).join(".wasm-agent").join("logs");
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
pub enum Action { None, Submit(String), SubmitNow(String), Eof, Interrupt, Nav, PageUp, PageDown, Bottom,
    /// The draft's selection, for the host to put on the clipboard (OSC 52): Ctrl+C or Ctrl+Insert with
    /// text selected (operator 17/11: "ctrl+a should select whole text-area so we can copy it").
    Copy(String),
    /// Ctrl+V: the host reads the system clipboard ONCE - an image becomes `[Image #n]` in the draft
    /// (`insert_text`), and text is pasted at the cursor (`paste`), the two things pi and Claude Code
    /// do (operator 17/11, Victor 22/11).
    Paste,
    /// A bracketed paste ended; it put draft[start..cursor]. A file path dropped or pasted there is the host's
    /// to turn into an attachment (an image path becomes `[Image #n]`).
    Pasted(usize) }

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
    /// A sandbox rebuild in progress (crate::build_status). It shares the **session-status-content**
    /// row with `session_notice` - one line between the box and the footer - and replaces it while
    /// there is a build to show (29/10, then 08/11 for the row's position). "" = no build, so the
    /// notice (or the box) has the row.
    pub build: String,
    /// The **session-status-content** line's standing text: a transient session notice, plain text,
    /// painted yellow here (`lua/core/cli_view.lua` paints the same sentence in the canonical layout,
    /// `lua/core/update_banner.lua` owns the wording). "" = no notice, so the box keeps the row.
    pub session_notice: String,
    /// Lines submitted during the run that the agent has not taken yet: drawn above the status line
    /// (`Steering queued`), never into the chat, so a steer is not printed twice. The host sets it.
    pub queued: Vec<String>,
    /// The self-wake fact (`⏰ 2 wakes · next 14:05`, `lua/core/selfloop.lua`), on a row of its own
    /// directly above the session status bar. It used to be appended to the footer's numbers row, where
    /// it squeezed them; "" (no wake scheduled) means the row does not exist and the chat keeps it.
    pub wakes: String,
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
    /// The selection's other end (the cursor is one end): Shift+arrows, Shift+Home/End, Ctrl+A and a mouse
    /// drag set it; any plain movement clears it; typing, Backspace and Delete replace what it covers.
    anchor: Option<usize>,
    /// Where the current bracketed paste began in the draft.
    paste_from: usize,
    /// The first draft line shown, while the wheel has moved the box away from the cursor's line
    /// (`wheel`). None = follow the cursor, which every key goes back to.
    scroll: Option<usize>,
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
    fn insert(&mut self, ch: char) { self.delete_selection(); self.chars.insert(self.cursor, ch); self.cursor += 1; }
    /// The selected range `[start, end)`, when there is one.
    pub fn selection(&self) -> Option<(usize, usize)> {
        let anchor = self.anchor?;
        let cursor = self.cursor.min(self.chars.len());
        let anchor = anchor.min(self.chars.len());
        if anchor == cursor { return None; }
        Some((anchor.min(cursor), anchor.max(cursor)))
    }
    pub fn selected_text(&self) -> Option<String> {
        self.selection().map(|(a, b)| self.chars[a..b].iter().collect())
    }
    /// Remove the selected text; true when there was some.
    fn delete_selection(&mut self) -> bool {
        let Some((a, b)) = self.selection() else { self.anchor = None; return false };
        self.chars.drain(a..b);
        self.cursor = a;
        self.anchor = None;
        true
    }
    /// Select from `anchor` to `cursor` (a mouse drag in the box: both are draft indices).
    pub fn select(&mut self, anchor: usize, cursor: usize) {
        self.anchor = Some(anchor.min(self.chars.len()));
        self.cursor = cursor.min(self.chars.len());
    }
    /// Where the line holding `at` starts / ends (a line is what Shift+Enter or a pasted newline made).
    fn line_start(&self, at: usize) -> usize {
        let at = at.min(self.chars.len());
        self.chars[..at].iter().rposition(|&c| c == '\n').map(|i| i + 1).unwrap_or(0)
    }
    fn line_end(&self, at: usize) -> usize {
        let at = at.min(self.chars.len());
        self.chars[at..].iter().position(|&c| c == '\n').map(|i| at + i).unwrap_or(self.chars.len())
    }
    /// A movement: with `extend` (Shift held) the selection grows from where it started, else it ends.
    fn moved(&mut self, extend: bool, from: usize) {
        if extend { if self.anchor.is_none() { self.anchor = Some(from); } } else { self.anchor = None; }
    }
    /// Nothing typed and not in bash mode: a restart here loses nothing.
    pub fn draft_empty(&self) -> bool { self.chars.is_empty() && !self.bash }
    /// The draft as it is submitted: `!` in front of it in bash mode.
    fn line(&self) -> String { if self.bash { format!("!{}", self.text()) } else { self.text() } }
    /// A recalled `!command` comes back in bash mode, its `!` the mode again rather than text.
    fn recall(&mut self, text: &str) {
        match text.strip_prefix('!') { Some(rest) => { self.bash = true; self.replace(rest); } None => { self.bash = false; self.replace(text); } }
    }
    fn history(&mut self, up: bool) {
        self.anchor = None;
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
        // A key is about the cursor: the box goes back to showing its line.
        self.scroll = None;
        self.notice.clear();
        // Undo bookkeeping: a byte that extends the open group (the next letter of a word, the next
        // byte of a paste) needs no snapshot - the group's entry already holds the draft before it.
        let kind = if self.paste { Some(Group::Paste) }
            else if self.escape.is_empty() && byte >= 32 && byte != 127 { Some(Group::Typing) } else { None };
        let word_break = byte == b' ' && self.cursor > 0 && !self.chars[self.cursor - 1].is_whitespace();
        let extends = kind.is_some() && kind == self.group && self.cursor == self.group_cursor
            && !(kind == Some(Group::Typing) && word_break) && self.selection().is_none();
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
        if matches!(action, Action::Submit(_) | Action::SubmitNow(_)) { self.undo.clear(); self.redo.clear(); self.group = None; }
        action
    }

    /// Ctrl+Z / Ctrl+Y (and Ctrl+Shift+Z where the terminal reports it): back to the draft before the
    /// last step, or forward again, cursor included. A recalled history entry becomes a plain draft.
    fn restore(&mut self, undo: bool) {
        self.anchor = None;
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
        // The menu's keys are rows of the same table (the Menu surface): the arrow that moves the
        // selection is the row the table calls Up/Down here, and the two keys the menu also owns are
        // Tab and Enter.
        if !self.escape.is_empty() {
            let mut sequence = self.escape.clone();
            sequence.push(byte);
            let act = keymap::menu_seq(&sequence)?;
            self.escape.clear();
            let n = items.len();
            self.menu_at = match act {
                keymap::MenuAct::MovePrev => (self.menu_at + n - 1) % n,
                keymap::MenuAct::MoveNext => (self.menu_at + 1) % n,
                _ => return None,
            };
            return Some(Action::None);
        }
        if self.paste { return None; }
        let act = keymap::menu_byte(byte)?;
        let chosen = self.commands[items[self.menu_at.min(items.len() - 1)]].clone();
        match act {
            keymap::MenuAct::Complete => {
                let text = if chosen.args { format!("{} ", chosen.name) } else { chosen.name.clone() };
                self.replace(&text); self.menu_hidden = chosen.args;
                Some(Action::None)
            }
            keymap::MenuAct::Run if chosen.args && self.text() != chosen.name => {
                let text = format!("{} ", chosen.name); self.replace(&text); self.menu_hidden = true;
                Some(Action::None)
            }
            keymap::MenuAct::Run => {
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
        if self.escape_closes() { return true; }
        lone
    }
    /// What Esc does inside the draft once the key itself is established (the terminal sent nothing
    /// after it): close the slash menu, else leave bash mode. True when it closed something.
    fn escape_closes(&mut self) -> bool {
        if self.menu_rows() > 0 { self.menu_hidden = true; return true; }
        if self.bash { self.bash = false; return true; }
        false
    }
    /// The box's bottom border: the row above the footer, one higher while the session-status-content
    /// line has something to say - the line sits between the box and the footer (Victor, 08/11).
    pub fn bottom(&self) -> usize {
        self.row.saturating_sub(self.session_rows() + self.wakes_rows())
    }
    /// The footer row: the last row of the screen, which is the CLI's session status bar.
    pub fn footer_row(&self) -> usize { self.row + 1 }
    /// Inside a paste: an Esc here is the start of the paste's end marker, never the Esc key.
    pub fn pasting(&self) -> bool { self.paste }
    /// The input's top divider: as many rows above the bottom one as the draft shows.
    fn top(&self) -> usize {
        let (lines, cursor) = self.layout();
        self.frame_geometry(lines.len(), cursor.0).2
    }
    /// Bottom up: footer, the session-status-content line, the box's bottom divider, the draft, the
    /// top divider, the slash menu (opening upward), the status line, then the output. The run's own
    /// status line stays above the box; the standing session line sits below it, between the box and
    /// the footer - the order the window has (text area, notice, status bar). Nothing is reserved that
    /// is not drawn, so the chat sits right on top of the input.
    pub fn status_row(&self) -> usize { self.top().saturating_sub(self.menu_rows() + 1) }
    /// The **session-status-content** row: ONE line directly below the CLI's text area and directly
    /// above the session status bar (the footer), shared by the build loader and the standing session
    /// notice (`build` wins, then `session_notice`). It exists only while one of them has something to
    /// say - an empty area takes no line, so the box keeps the row and there is never a blank gap above
    /// the status bar. The row is fixed at the last row before the footer, so it does not move when the
    /// draft grows, when the slash menu opens or while a run's status line shows.
    ///
    /// A tool call's progress is **not** one of its claimants (Victor, 2026-11-10): it belongs in that
    /// call's own block in the transcript (`crate::transcript::Transcript::live`), where the host's
    /// ticker rewrites it while Lua is blocked. The row is the update notice's.
    pub fn session_row(&self) -> usize { self.row.saturating_sub(self.wakes_rows()) }
    /// The self-wake row: ONE row directly above the session status bar (`footer_row`), so the fact cannot
    /// squeeze the numbers and cannot wrap them. It exists only while a wake is scheduled - nothing is
    /// reserved that is not drawn, so the chat keeps the row when there is none.
    pub fn wakes_row(&self) -> usize { self.row }
    fn wakes_rows(&self) -> usize { usize::from(!self.wakes.trim().is_empty()) }
    /// That row, rendered: the fact in the hint colour, clipped to the width so it can never wrap.
    pub fn wakes_content(&self) -> String {
        let text = self.wakes.trim();
        if text.is_empty() { return String::new(); }
        let text = clip_cells(text, self.width);
        if std::env::var_os("NO_COLOR").is_some() { text } else { format!("{HINT}{text}{RESET}") }
    }
    fn session_rows(&self) -> usize { usize::from(self.has_session_content()) }
    fn has_session_content(&self) -> bool {
        !self.build.is_empty() || !self.session_notice.trim().is_empty()
    }
    /// That row, rendered: the loader's own line when a build is showing (it carries its colour and
    /// is already clipped), else the notice in the warning yellow, clipped to the width so the row
    /// can never wrap. "" = draw nothing (there is no row).
    pub fn session_content(&self) -> String {
        if !self.build.is_empty() { return self.build.clone(); }
        let notice = self.session_notice.trim();
        if notice.is_empty() { return String::new(); }
        let text = clip_cells(notice, self.width);
        if std::env::var_os("NO_COLOR").is_some() { return text; }
        // The commands in the sentence are bold - BOTH of them (Victor, 18/11): the notice reads
        // `Update available (<sha>) — /update here, or wa update in a terminal`, and the two things a
        // reader can do with it are those two. The words are `update_banner.COMMANDS`' list on the Lua
        // side, and this is the same emphasis in the renderer that owns the row when the native editor
        // does (a plain row, one colour, two bold words).
        let mut text = text.to_string();
        for word in ["/update", "wa update"] {
            if let Some(at) = text.find(word) {
                let end = at + word.len();
                text = format!("{}\x1b[1m{word}\x1b[22m{}", &text[..at], &text[end..]);
            }
        }
        format!("{NOTICE_ROW}{text}{RESET}")
    }
    /// The output region's last row: everything the bottom furniture draws is above it. The run's
    /// status line and the queued-steer rows are taken out of the chat here; the session-status-content
    /// row is below the box, so it costs the chat nothing.
    pub fn out_bottom(&self) -> usize {
        self.status_row().saturating_sub(usize::from(self.status) + self.queued_count())
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
            // Every key the draft answers is a row of the table in `keymap`; this decoder only decides
            // when the bytes are one. An exact row performs its act, a prefix of a row waits for the
            // rest, and anything else is swallowed - an escape sequence nobody binds must never be
            // typed into the reader's prompt.
            if let Some(act) = keymap::draft_seq(&self.escape) {
                // Esc twice is the key itself, and its buffer still holds both bytes.
                if act == keymap::DraftAct::Escape { self.escape.clear(); self.escape_closes(); return Action::None; }
                self.escape.clear();
                return self.perform(act);
            }
            if keymap::draft_prefix(&self.escape) { return Action::None; }
            // ESC + one byte that begins no row is Alt+<key>: drop the ESC and keep the key.
            if self.escape.len() == 2 { self.escape.clear(); return self.feed_inner(byte); }
            // An escape sequence nobody binds: swallow it to its final byte, never insert it.
            if self.escape.len() <= 16 && !(0x40..=0x7e).contains(&byte) { return Action::None; }
            self.escape.clear();
            return Action::None;
        }
        if let Some(act) = keymap::draft_byte(byte) {
            if act != keymap::DraftAct::Type { return self.perform(act); }
        } else if byte < 32 || byte == 127 {
            // Inside a paste, Tab is data: code pasted from an editor keeps its indentation. Every
            // other control byte nobody binds is dropped.
            if self.paste && byte == b'\t' { self.insert('\t'); }
            return Action::None; // a control key nobody binds
        }
        // Any other character goes into the draft (the terminal sends it as UTF-8, byte by byte).
        self.utf8.push(byte);
        match std::str::from_utf8(&self.utf8) {
            Ok(text) => { let chars: Vec<char> = text.chars().collect(); self.utf8.clear(); for c in chars { self.insert(c); } }
            Err(error) if error.error_len().is_some() || self.utf8.len() > 4 => self.utf8.clear(),
            Err(_) => {}
        }
        Action::None
    }

    /// What a row of the table says the key does. The match is exhaustive: an act the table names
    /// cannot be left unimplemented, and a behaviour with no act cannot be reached by a key at all.
    fn perform(&mut self, act: keymap::DraftAct) -> Action {
        use keymap::DraftAct as A;
        match act {
            A::Submit => {
                let line = self.line(); self.chars.clear(); self.cursor = 0; self.history_at = None; self.bash = false; self.anchor = None;
                if !line.is_empty() && line != "!" && !carries_secret(&line) { self.history.push(line.clone()); }
                Action::Submit(line)
            }
            // Send now: the same draft, the same history, the same clearing - the only difference is
            // what the reader may do with the line while a run is in flight (docs/HOST.md).
            A::SubmitNow => match self.perform(A::Submit) {
                Action::Submit(line) => Action::SubmitNow(line),
                other => other,
            },
            A::Newline => { self.insert('\n'); Action::None } // Ctrl+J / Shift+Enter
            // A lone Esc only starts the sequence buffer: the console asks the terminal whether
            // anything follows it, and calls escape() when nothing does.
            A::Escape => { if self.escape.is_empty() { self.escape.push(0x1b); } Action::None }
            // Ctrl+C never touches the draft. During a run it interrupts the turn (raw mode turned the
            // terminal's own SIGINT off, so a runaway turn could otherwise only be stopped by killing
            // the terminal); on an empty line a second one within a second leaves. With a draft and no
            // run it only says how to clear or leave - quitting would throw the draft away. Ctrl+C with
            // text selected copies it (never interrupts, never touches the draft).
            A::Interrupt => {
                if self.selection().is_some() { return Action::Copy(self.selected_text().unwrap_or_default()); }
                if self.bash && self.chars.is_empty() { self.bash = false; return Action::None; }
                if !self.chars.is_empty() {
                    self.last_interrupt = None;
                    if self.status {
                        self.notice = "Interrupting\u{2026} (draft kept)".into();
                        Action::Interrupt
                    } else {
                        self.notice = "Draft kept \u{b7} ctrl+u clears it \u{b7} ctrl+z undoes".into();
                        Action::None
                    }
                } else {
                    let now = std::time::Instant::now();
                    let twice = self.last_interrupt.is_some_and(|at| now.duration_since(at) < std::time::Duration::from_secs(1));
                    self.last_interrupt = Some(now);
                    if twice { return Action::Eof; }
                    self.notice = if self.status { "Interrupting\u{2026} (ctrl+c again to quit)" } else { "ctrl+c again to quit" }.into();
                    Action::Interrupt
                }
            }
            A::Copy => match self.selected_text() { Some(text) => Action::Copy(text), None => Action::None },
            A::DeleteForward => { if !self.delete_selection() && self.cursor < self.chars.len() { self.chars.remove(self.cursor); } Action::None }
            A::Backspace => {
                if self.bash && self.chars.is_empty() { self.bash = false; }
                else if !self.delete_selection() && self.cursor > 0 { self.cursor -= 1; self.chars.remove(self.cursor); }
                Action::None
            }
            A::DeleteForwardOrLeave => {
                if self.chars.is_empty() { return Action::Eof; }
                if !self.delete_selection() && self.cursor < self.chars.len() { self.chars.remove(self.cursor); }
                Action::None
            }
            // Ctrl+K / Ctrl+U / Ctrl+W with a selection act on the SELECTION: every editor kills what is
            // selected, and with nothing selected these stay the line and word kills they always were.
            A::KillLine => { if !self.delete_selection() { self.chars.truncate(self.cursor); } Action::None }
            A::KillToStart => { if !self.delete_selection() { self.chars.drain(..self.cursor); self.cursor = 0; } Action::None }
            A::KillWord => {
                if !self.delete_selection() {
                    while self.cursor > 0 && self.chars[self.cursor - 1].is_whitespace() { self.cursor -= 1; self.chars.remove(self.cursor); }
                    while self.cursor > 0 && !self.chars[self.cursor - 1].is_whitespace() { self.cursor -= 1; self.chars.remove(self.cursor); }
                }
                Action::None
            }
            A::SelectAll => { if !self.chars.is_empty() { self.anchor = Some(0); self.cursor = self.chars.len(); } Action::None }
            A::Undo => { self.restore(true); Action::None } // raw mode turned SIGTSTP off
            A::Redo => { self.restore(false); Action::None }
            A::Paste => if self.paste { Action::None } else { Action::Paste },
            A::PasteStart => { self.delete_selection(); self.paste = true; self.paste_from = self.cursor; Action::None }
            A::PasteEnd => { self.paste = false; Action::Pasted(self.paste_from.min(self.cursor)) }
            // A plain movement ends a selection; Left/Right land on its edge, as every editor does.
            A::Left => {
                if let Some((a, _)) = self.selection() { self.cursor = a; } else { self.cursor = self.cursor.saturating_sub(1); }
                self.anchor = None;
                Action::None
            }
            A::Right => {
                if let Some((_, b)) = self.selection() { self.cursor = b; } else { self.cursor = (self.cursor + 1).min(self.chars.len()); }
                self.anchor = None;
                Action::None
            }
            A::Up => { self.anchor = None; if !self.move_line(true) { self.history(true); } Action::None }
            A::Down => { self.anchor = None; if !self.move_line(false) { self.history(false); } Action::None }
            // Home/End act on the line the cursor is on, not the whole draft (operator 17/11).
            A::LineStart => { self.anchor = None; self.cursor = self.line_start(self.cursor); Action::None }
            A::LineEnd => { self.anchor = None; self.cursor = self.line_end(self.cursor); Action::None }
            A::DocStart => { self.anchor = None; self.cursor = 0; Action::None }
            A::DocEnd => { self.anchor = None; self.cursor = self.chars.len(); Action::None }
            A::ExtendLeft => { self.moved(true, self.cursor); self.cursor = self.cursor.saturating_sub(1); Action::None }
            A::ExtendRight => { self.moved(true, self.cursor); self.cursor = (self.cursor + 1).min(self.chars.len()); Action::None }
            A::ExtendUp => { self.moved(true, self.cursor); if !self.move_line(true) { self.cursor = self.line_start(self.cursor); } Action::None }
            A::ExtendDown => { self.moved(true, self.cursor); if !self.move_line(false) { self.cursor = self.line_end(self.cursor); } Action::None }
            A::ExtendLineStart => { self.moved(true, self.cursor); self.cursor = self.line_start(self.cursor); Action::None }
            A::ExtendLineEnd => { self.moved(true, self.cursor); self.cursor = self.line_end(self.cursor); Action::None }
            A::HistoryPrev => { self.history(true); Action::None }
            A::HistoryNext => { self.history(false); Action::None }
            A::PageUp => Action::PageUp,
            A::PageDown => Action::PageDown,
            A::Bottom => Action::Bottom,
            A::Nav => Action::Nav,
            // The first `!` of an empty draft is the mode; anywhere else it is a character.
            A::BashMode => { if self.chars.is_empty() && !self.bash && !self.paste { self.bash = true; } else { self.insert('!'); } Action::None }
            // feed_key types the byte itself: the row is what makes "any other character" a fact the
            // list can state, not a behaviour this match has to re-state.
            A::Type => Action::None,
        }
    }
    /// The draft index under a screen cell of the input box (1-based row/col, as mouse reports give them),
    /// or None outside the box's text rows. The prompt's two columns sit before the text.
    pub fn index_at(&self, row: usize, col: usize) -> Option<usize> {
        if !self.drawable() { return None; }
        let (lines, cursor) = self.layout();
        let (first, shown, top) = self.frame_geometry(lines.len(), cursor.0);
        if row <= top || row > top + shown { return None; }
        let visual = first + (row - top - 1);
        let starts = self.line_starts();
        let start = *starts.get(visual)?;
        let end = starts.get(visual + 1).copied().unwrap_or(self.chars.len());
        let want = col.saturating_sub(3); // col is 1-based; the prompt takes two cells
        let mut at = start;
        let mut used = 0usize;
        while at < end && self.chars[at] != '\n' {
            let width = cell_width(self.chars[at]);
            if used + width > want { break; }
            used += width;
            at += 1;
        }
        Some(at)
    }
    /// The draft text in `[a, b)`.
    pub fn slice(&self, a: usize, b: usize) -> String {
        let (a, b) = (a.min(self.chars.len()), b.min(self.chars.len()));
        if a >= b { return String::new(); }
        self.chars[a..b].iter().collect()
    }
    /// The cursor, as a draft index.
    pub fn cursor(&self) -> usize { self.cursor }
    /// Replace `[a, b)` with `text` (a dropped path becoming its `[Image #n]`); the cursor lands after it.
    pub fn replace_range(&mut self, a: usize, b: usize, text: &str) {
        let (a, b) = (a.min(self.chars.len()), b.min(self.chars.len()));
        if a > b { return; }
        self.chars.splice(a..b, text.chars());
        self.cursor = a + text.chars().count();
        self.anchor = None;
        self.scroll = None;
    }
    /// Text the host puts in the draft at the cursor (an `[Image #n]` token), as one undo step.
    pub fn insert_text(&mut self, text: &str) {
        let snapshot = Snapshot { chars: self.chars.clone(), cursor: self.cursor };
        self.scroll = None;
        for ch in text.chars() { self.insert(ch); }
        if self.undo.len() == UNDO_MAX { self.undo.remove(0); }
        self.undo.push(snapshot);
        self.redo.clear();
        self.group = None;
        self.group_cursor = self.cursor;
    }
    /// The clipboard's text at the cursor, exactly as a bracketed paste puts one: the selection goes,
    /// its newlines stay lines, and the whole paste is ONE undo step (Ctrl+Z takes all of it back).
    /// The returned span is where it landed, so the host can attach a path to an image in it exactly
    /// as it does for a dropped one (`Action::Pasted`).
    pub fn paste(&mut self, text: &str) -> Action {
        if text.is_empty() { return Action::None; }
        let from = self.cursor.min(self.chars.len());
        self.insert_text(text);
        Action::Pasted(from.min(self.cursor))
    }
    /// A press in the box: the cursor goes there and the selection ends (a drag then extends from it).
    pub fn click(&mut self, index: usize) { self.anchor = None; self.cursor = index.min(self.chars.len()); }
    /// The draft index each visual row of `layout` starts at (same wrapping rule), for drawing a selection
    /// and for turning a mouse position in the box into a draft index.
    pub fn line_starts(&self) -> Vec<usize> {
        let available = self.wrap_width();
        let mut starts = vec![0usize];
        let mut col = 0usize;
        for (index, &ch) in self.chars.iter().enumerate() {
            if ch == '\n' { starts.push(index + 1); col = 0; continue; }
            let width = cell_width(ch);
            if col + width > available && col > 0 { starts.push(index); col = 0; }
            col += width;
        }
        starts
    }
    /// The most draft rows the box shows: what the view asked for (`height`, three) as the floor, and
    /// 30% of the window's rows when that is more (40 rows -> 12, 12 rows -> 3). `row` is the row above
    /// the footer, so `row + 1` is the window's height: the limit follows a resize with no other state.
    /// Never more than the rows above the box's bottom border leave for it and its top border.
    pub fn max_rows(&self) -> usize {
        if self.height < 3 { return self.height; }
        self.height.max((self.row + 1) * 3 / 10).min(self.bottom().saturating_sub(2).max(self.height))
    }
    /// How many visual rows the draft wraps into at `available` cells (the rule `layout` applies).
    fn wrapped_lines(&self, available: usize) -> usize {
        let (mut lines, mut col) = (1usize, 0usize);
        for &ch in &self.chars {
            if ch == '\n' { lines += 1; col = 0; continue; }
            let width = cell_width(ch);
            if col + width > available && col > 0 { lines += 1; col = 0; }
            col += width;
        }
        lines
    }
    /// Whether the draft has more rows than the box shows: then the box's last column is the
    /// scrollbar's, and the text wraps one cell earlier so no character sits under it.
    pub fn overflows(&self) -> bool {
        self.wrapped_lines(self.width.saturating_sub(BOX_CHROME)) > self.max_rows()
    }
    fn wrap_width(&self) -> usize {
        self.width.saturating_sub(BOX_CHROME + usize::from(self.overflows()))
    }
    /// The box's rows on screen, borders included: `(top border, bottom border)`. None when not drawn.
    pub fn box_rows(&self) -> Option<(usize, usize)> {
        if !self.drawable() { return None; }
        Some((self.top(), self.bottom()))
    }
    /// The wheel over the box: move the visible lines `rows` up or down, without moving the cursor.
    /// False when the draft fits (nothing to scroll) - the caller then leaves the wheel to the chat.
    pub fn wheel(&mut self, up: bool, rows: usize) -> bool {
        if !self.drawable() { return false; }
        let (lines, cursor) = self.layout();
        let (first, shown, _) = self.frame_geometry(lines.len(), cursor.0);
        if lines.len() <= shown { return false; }
        let last = lines.len() - shown;
        self.scroll = Some(if up { first.saturating_sub(rows) } else { (first + rows).min(last) });
        true
    }
    fn layout(&self) -> (Vec<String>, (usize, usize)) {
        let available = self.wrap_width();
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
        let shown = lines.clamp(1, self.max_rows().max(1));
        let follow = cursor_line.saturating_sub(shown - 1).min(lines.saturating_sub(shown));
        let first = self.scroll.map(|first| first.min(lines.saturating_sub(shown))).unwrap_or(follow);
        (first, shown, self.bottom().saturating_sub(shown + 1))
    }

    fn drawable(&self) -> bool { self.bottom() > self.height.min(3) + 1 && self.width >= 12 && self.height > 0 }

    /// Explicit placement avoids saved cursors moving with Windows scrollback.
    pub fn cursor_frame(&self) -> String {
        if !self.drawable() { return String::new(); }
        let (lines, cursor) = self.layout();
        let (first, shown, top) = self.frame_geometry(lines.len(), cursor.0);
        // The wheel moved the cursor's line out of the box: nothing to place (render hid the cursor).
        if cursor.0 < first || cursor.0 >= first + shown { return String::new(); }
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
        let starts = self.line_starts();
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
        // Session-status-content, the row between the box and the footer: the build loader while a
        // build is in flight (it replaces the notice), the standing notice otherwise, nothing when
        // there is neither - and then the box's bottom border takes the row, which is what `bottom`
        // and `out_bottom` account for. Drawn before the box, so a shrinking box never erases it.
        // The rows below the box, bottom up: the session-status-content line, then the self-wake fact,
        // then the session status bar (the footer). Erased first, because a row that stops having a fact
        // must lose its text: the wake line disappears when the last wake fires.
        for row in self.bottom() + 1..self.footer_row() {
            frame.push_str(&format!("\x1b[{row};1H\x1b[2K"));
        }
        let session = self.session_content();
        if !session.is_empty() {
            frame.push_str(&format!("\x1b[{};1H\x1b[2K{session}", self.session_row()));
        }
        let wakes = self.wakes_content();
        if !wakes.is_empty() {
            frame.push_str(&format!("\x1b[{};1H\x1b[2K{wakes}", self.wakes_row()));
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
                let hint: String = clip_cells(placeholder, self.width.saturating_sub(BOX_CHROME));
                frame.push_str(&format!("{HINT}{hint}{RESET}"));
            } else if let Some((a, b)) = self.selection() {
                // The selection, drawn in reverse video over the characters it covers on this row.
                let start = starts.get(index).copied().unwrap_or(0);
                let mut at = start;
                for ch in text.chars() {
                    while at < self.chars.len() && self.chars[at] == '\n' && ch != '\n' { at += 1; }
                    let inside = at >= a && at < b;
                    if inside { frame.push_str("\x1b[7m"); }
                    frame.push(ch);
                    if inside { frame.push_str("\x1b[27m"); }
                    at += 1;
                }
            } else {
                frame.push_str(text);
            }
        }
        // The scrollbar, when the draft has more rows than the box: the transcript's own bar
        // (`scroll::bar`: same track, thumb and colours) on the box's last column, one cell per row.
        if lines.len() > shown {
            let bar = crate::scroll::bar::Bar::new(shown, lines.len(), first);
            for (visual, (glyph, colour)) in bar.cells().into_iter().enumerate() {
                frame.push_str(&format!("\x1b[{};{}H{colour}{glyph}{RESET}", top + 1 + visual, self.width));
            }
        }
        frame.push_str(&format!("\x1b[{};1H\x1b[2K{border}{}{RESET}", bottom, "\u{2500}".repeat(self.width)));
        // The footer under the box - hints or the last run's numbers on the left, the model on the
        // right - and the slash menu above the input, opening upward toward the chat.
        // By CELLS, never by characters: this row carries Nerd Font icons and the footer's own
        // number runs, and a row one cell too wide WRAPS - which moves the box and the chat above it
        // (Victor, 19/11: the bounce is the row under the box changing height).
        let right: String = clip_cells(&self.footer_right, self.width / 2);
        let right_width: usize = visible_cells(&right);
        let room = self.width.saturating_sub(right_width + if right.is_empty() { 0 } else { 1 });
        let bash_hint = BASH_FOOTER.to_string();
        let (color, text) = if !self.notice.is_empty() { (NOTICE, &self.notice) }
            else if self.bash { (BASH, &bash_hint) } else { (HINT, &self.footer) };
        let footer: String = clip_cells(text, room);
        frame.push_str(&format!("\x1b[{};1H\x1b[2K{color}{footer}{RESET}", self.footer_row()));
        if !right.is_empty() {
            frame.push_str(&format!("\x1b[{};{}H{MODEL}{right}{RESET}", self.footer_row(), self.width - right_width + 1));
        }
        if menu > 0 {
            let selected = self.menu_at.min(items.len() - 1);
            let first = selected.saturating_sub(MENU_MAX - 1).min(items.len().saturating_sub(MENU_MAX));
            let name_width = items.iter().map(|&i| self.commands[i].name.chars().count()).max().unwrap_or(0) + 3;
            for (offset, &index) in items.iter().skip(first).take(MENU_MAX).enumerate() {
                let command = &self.commands[index];
                let name = format!("{:<name_width$}", command.name);
                let room = self.width.saturating_sub(name.chars().count() + 1);
                let hint: String = clip_cells(&command.hint, room);
                let color = if first + offset == selected { SELECTED } else { RESET };
                frame.push_str(&format!("\x1b[{};1H\x1b[2K{color}{name}{RESET}{HINT}{hint}{RESET}", top - menu + offset));
            }
        }
        if cursor.0 >= first && cursor.0 < first + shown {
            frame.push_str(&format!("\x1b[{};{}H", top + 1 + cursor.0 - first, self.left(cursor.0) + 1 + cursor.1));
            frame.push_str("\x1b[?25h");
        }
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
/// The session-status-content row's notice colour: the view's `warning` role, in Rust because this
/// renderer draws that row when the native editor owns the screen.
const NOTICE_ROW: &str = crate::build_status::NOTICE;
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
    /// A field that keeps its spaces: what an `input: "line"` page types into. A `text` field drops
    /// whitespace (it has always been a name, a key or a path); a message draft is a sentence, and a
    /// sentence typed into a field that eats its spaces is not editable at all.
    pub spaces: bool,
    /// The letters a page offers as shortcuts, with the 1-based option each one means
    /// (`{"e": 2}`). Opt-in per page, so no other panel's keys change: pressing a letter on a list
    /// that did not name it still does nothing.
    pub keys: Vec<(u8, usize)>,
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
        let input = match spec.get("input").and_then(|v| v.as_str()) {
            Some("secret") => Some(true),
            Some("text") => Some(false),
            // A line of prose: spaces kept, Enter submits - the field `docs/APPROVE.md`'s edit page
            // needs, because a draft with its spaces removed is a different message.
            Some("line") => Some(false),
            _ => None,
        };
        let spaces = spec.get("input").and_then(|v| v.as_str()) == Some("line");
        // A page that starts with text already in its field (an edit in place, not a blank prompt).
        // A carriage return is dropped for the same reason the field is one line: it renders nothing
        // and would only be backspaced away.
        let value: Vec<char> = spec.get("value").and_then(|v| v.as_str()).unwrap_or("")
            .chars().filter(|c| *c != '\r' && (!c.is_control() || *c == '\n')).collect();
        // The letter shortcuts a page names, and only those: an entry that points at no option on
        // the page is dropped rather than made into a keystroke that does nothing.
        let keys: Vec<(u8, usize)> = spec.get("keys").and_then(|v| v.as_object()).map(|object| object
            .iter()
            .filter_map(|(letter, index)| {
                let byte = letter.as_bytes();
                let option = index.as_u64()? as usize;
                if byte.len() != 1 || option == 0 { return None; }
                Some((byte[0].to_ascii_lowercase(), option))
            })
            .collect()).unwrap_or_default();
        let selected = spec.get("selected").and_then(|v| v.as_u64()).map(|n| (n as usize).saturating_sub(1)).unwrap_or(0)
            .min(options.len().saturating_sub(1));
        let hint = match text("hint") {
            h if !h.is_empty() => h,
            _ if input.is_some() => "Enter to save \u{b7} Esc to cancel".into(),
            _ if !options.is_empty() => "\u{2191}\u{2193} to move \u{b7} Enter to select \u{b7} Esc or \u{2190} to go back".into(),
            _ => "Esc or \u{2190} to go back".into(),
        };
        Panel { title: text("title"), lines, options, selected, input, placeholder: text("placeholder"), hint,
            spaces, keys, text: value, width, rows, ..Default::default() }
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
            let sequence = self.escape.clone();
            // The page's keys are rows of the same table (`keymap`, surface Panel): an exact sequence is its act,
            // an unknown one is swallowed to its final byte and never typed into the field.
            if let Some(act) = keymap::panel_seq(&sequence) { self.escape.clear(); self.perform(act, byte); return; }
            if sequence.len() == 2 && !matches!(byte, b'[' | b'O') { self.escape.clear(); return; } // Alt+key: ignored
            if sequence.len() >= 3 && (0x40..=0x7e).contains(&byte) { self.escape.clear(); return; }
            if sequence.len() > 16 { self.escape.clear(); }
            return;
        }
        if byte == 0x1b { self.escape.push(byte); return; } // the first byte of every sequence
        if let Some(act) = keymap::panel_byte(byte) { self.perform(act, byte); return; }
        // A page with no field offers its options: 1-9, and the letters the page itself named. With a
        // field, every printable byte is the text being typed.
        if self.input.is_none() {
            if let Some(act) = keymap::panel_digit(byte) { self.perform(act, byte); return; }
            if !self.options.is_empty() {
                if let Some(act) = keymap::panel_letter() { self.perform(act, byte); return; }
            }
        }
        if byte < 32 || byte == 127 { return; }
        if self.input.is_none() { return; }
        self.utf8.push(byte);
        match std::str::from_utf8(&self.utf8) {
            // `spaces` is the difference between a field for a name and a field for a sentence: a
            // draft's spaces are part of the message.
            Ok(text) => {
                let chars: Vec<char> = if self.spaces { text.chars().filter(|c| !c.is_control()).collect() }
                    else { text.chars().filter(|c| !c.is_whitespace()).collect() };
                self.utf8.clear();
                self.text.extend(chars);
            }
            Err(error) if error.error_len().is_some() || self.utf8.len() > 4 => self.utf8.clear(),
            Err(_) => {}
        }
    }

    /// What a row of the table says a key does to this page. Exhaustive, as the draft's own match is.
    fn perform(&mut self, act: keymap::PanelAct, byte: u8) {
        use keymap::PanelAct as A;
        match act {
            A::Prev => { if !self.options.is_empty() { self.selected = (self.selected + self.options.len() - 1) % self.options.len(); } }
            A::Next => { if !self.options.is_empty() { self.selected = (self.selected + 1) % self.options.len(); } }
            A::Back => { if self.text.is_empty() { self.escape(); } } // Left goes back unless a field has text
            A::Choose => {
                if self.input.is_some() {
                    let text: String = self.text.iter().collect();
                    self.finish(serde_json::json!({"action": "submit", "text": text.trim()}));
                } else if !self.options.is_empty() {
                    self.finish(serde_json::json!({"action": "select", "index": self.selected + 1}));
                } else {
                    self.escape(); // a panel that only shows something: Enter closes it too
                }
            }
            A::Cancel => self.escape(),
            A::ChooseDigit => {
                let index = (byte - b'0') as usize;
                if index <= self.options.len() {
                    self.selected = index - 1;
                    self.finish(serde_json::json!({"action": "select", "index": index}));
                }
            }
            // A letter this page named as a shortcut (`keys`): [e] edits, [r] rejects, and a letter no
            // page named is still not a key.
            A::ChooseLetter => {
                let letter = byte.to_ascii_lowercase();
                if let Some((_, index)) = self.keys.iter().find(|(named, _)| *named == letter) {
                    if *index >= 1 && *index <= self.options.len() {
                        self.selected = index - 1;
                        self.finish(serde_json::json!({"action": "select", "index": *index}));
                    }
                }
            }
            A::Backspace => { if self.input.is_some() { self.text.pop(); } }
            A::ClearField => { if self.input.is_some() { self.text.clear(); } }
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
                let tail: String = clip_cells(hint, room);
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

/// The terminal cells `text` takes on screen: every character's width, escape sequences
/// counting none. The one measure of what "fits" means, beside the clip that enforces it.
pub fn visible_cells(text: &str) -> usize {
    let mut total = 0usize;
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\x1b' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for c in chars.by_ref() { if ('@'..='~').contains(&c) { break; } }
            }
            continue;
        }
        total += cell_width(ch);
    }
    total
}

pub fn clip_cells(text: &str, room: usize) -> String {
    let total = visible_cells(text);
    if total <= room { return text.to_string(); }
    let mut out = String::new(); let mut used = 0;
    let mut open_colour = false;
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\x1b' {
            open_colour = true;
            out.push(ch);
            if chars.peek() == Some(&'[') {
                out.push(chars.next().unwrap());
                for c in chars.by_ref() { out.push(c); if ('@'..='~').contains(&c) { break; } }
            }
            continue;
        }
        let width = cell_width(ch);
        if used + width + 1 > room { break; }
        out.push(ch); used += width;
    }
    if room > 0 {
        out.push('\u{2026}');
        // The row was cut while a colour was open: close it AFTER the ellipsis, or the terminal paints
        // the mark - and whatever is drawn beside it - in a colour the row no longer claims.
        if open_colour { out.push_str(RESET); }
    }
    out
}

/// `text` cut to `room` terminal cells, ending in `…` when it was cut.
///
/// An escape sequence takes ZERO cells and is never cut in half: the footer can carry colour now
/// (the context ball's level, lua/core/cli_view.lua), and counting its bytes as characters would
/// clip a row that fits the terminal, while cutting inside one would print the rest as text
/// (Victor, 19/11: a status row measures what the terminal draws).
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
        || (0x1f300..=0x1faff).contains(&cp) || wide_emoji(cp) { 2 } else { 1 }
}

/// The emoji below U+1F300 that a terminal draws TWO cells wide (Unicode `Emoji_Presentation`, East
/// Asian Width W): `\u{23f3}` is the run block's waiting mark. Counted as one cell, its row was padded
/// one cell too far, the scrollbar's glyph wrapped onto the next row and scrolled the pane (Victor
/// 21/11: "the scrollbar splits while a call waits").
fn wide_emoji(cp: u32) -> bool {
    matches!(cp, 0x231a..=0x231b | 0x23e9..=0x23ec | 0x23f0 | 0x23f3 | 0x25fd..=0x25fe | 0x2614..=0x2615
        | 0x2648..=0x2653 | 0x267f | 0x2693 | 0x26a1 | 0x26aa..=0x26ab | 0x26bd..=0x26be | 0x26c4..=0x26c5
        | 0x26ce | 0x26d4 | 0x26ea | 0x26f2..=0x26f3 | 0x26f5 | 0x26fa | 0x26fd | 0x2705 | 0x270a..=0x270b
        | 0x2728 | 0x274c | 0x274e | 0x2753..=0x2755 | 0x2757 | 0x2795..=0x2797 | 0x27b0 | 0x27bf
        | 0x2b1b..=0x2b1c | 0x2b50 | 0x2b55)
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
    /// The rows a panel frame actually drew, as text: cursor moves split them, colour and erase sequences
    /// are dropped. This is how "nothing is wider than the terminal" is measured instead of assumed.
    fn drawn_rows(frame: &str) -> Vec<String> {
        let mut rows: Vec<String> = Vec::new();
        let mut current = String::new();
        let mut chars = frame.chars().peekable();
        while let Some(ch) = chars.next() {
            if ch != '\x1b' {
                current.push(ch);
                continue;
            }
            // A sequence: ESC [ params final-byte (or a two-character one we can ignore).
            if chars.peek() == Some(&'[') {
                chars.next();
                let mut params = String::new();
                let mut last = ' ';
                for next in chars.by_ref() {
                    last = next;
                    if last.is_ascii_alphabetic() { break; }
                    params.push(last);
                }
                if last == 'H' && params.ends_with(";1") {
                    rows.push(std::mem::take(&mut current));
                }
            }
        }
        rows.push(current);
        rows
    }

    #[test]
    fn a_balloon_at_80x24_moves_opens_and_closes_with_its_keys() {
        let spec = serde_json::json!({
            "title": "MCP connectors",
            "lines": ["4 connectors \u{b7} 3 here, 1 from peers \u{b7} 2 enabled"],
            "options": [
                {"label": "WhatsApp", "hint": "whatsapp \u{b7} connected \u{b7} 3 tools"},
                {"label": "Filesystem reads", "hint": "native_reads \u{b7} failed \u{b7} no tool"},
                {"label": "Back", "hint": "the list"},
            ],
            "selected": 1,
        });
        let mut panel = Panel::from_spec(&spec, 80, 22);
        let frame = panel.render();
        assert!(frame.contains("MCP connectors"), "the title is drawn");
        assert!(frame.contains("\u{276f}"), "the reader's row is marked");
        assert!(frame.contains("Esc or \u{2190} to go back"), "the hint row says how to leave: {frame:?}");
        // Down moves and wraps; Up wraps back.
        for &key in b"\x1b[B\x1b[B\x1b[B" { panel.feed(key); }
        assert_eq!(panel.selected, 0, "past the last row, the selection wraps to the first");
        for &key in b"\x1b[A" { panel.feed(key); }
        assert_eq!(panel.selected, 2, "and Up from the first lands on the last");
        // Enter picks the row the reader is on, 1-based, the way the client reads it.
        panel.feed(b'\r');
        assert_eq!(panel.result, Some(serde_json::json!({"action": "select", "index": 3})));
        // A lone Esc closes it: back to the chat, never cancelling the run behind it.
        let mut panel = Panel::from_spec(&spec, 80, 22);
        panel.feed(0x1b);
        panel.escape();
        assert_eq!(panel.result, Some(serde_json::json!({"action": "cancel"})));
    }

    #[test]
    fn a_balloon_in_a_narrow_terminal_never_draws_wider_than_it() {
        let spec = serde_json::json!({
            "title": "whatsapp \u{b7} WhatsApp",
            "lines": [
                "where: this node (local) \u{b7} transport native \u{b7} revision 42",
                "error:",
                "  401 unauthorized: the access token was rejected by the reports service, which is long",
            ],
            "options": [
                {"label": "Tools (3)", "hint": "names, approvals, inputs"},
                {"label": "Reconnect", "hint": "probe again, now"},
                {"label": "Turn off", "hint": "the model stops seeing its tools"},
                {"label": "Back", "hint": "the list"},
            ],
        });
        for &width in &[80usize, 40, 24] {
            // A 12-row terminal as well: the panel may take no more rows than there are.
            for &rows in &[24usize, 12] {
                let panel = Panel::from_spec(&spec, width, rows);
                let frame = panel.render();
                for row in drawn_rows(&frame) {
                    let wide = row.chars().count();
                    assert!(wide <= width, "{wide} cells at {width} columns: {row:?}");
                }
                assert!(panel.height() <= rows.saturating_sub(2).max(1), "the panel fits the screen");
            }
        }
        // The field variant, at the same widths: the bullets and the counter fit too.
        let field = Panel::from_spec(&serde_json::json!({"title": "Key", "input": "secret", "placeholder": "sk-..."}), 24, 24);
        for row in drawn_rows(&field.render()) {
            assert!(row.chars().count() <= 24, "field row: {row:?}");
        }
    }

    fn editor_at(width: usize) -> Editor {
        // A 24-row terminal: the status bar is the last row, so the editor's `row` is 23 and the footer 24.
        let mut editor = Editor::default();
        editor.row = 23;
        editor.width = width;
        editor.height = 1;
        editor
    }

    #[test]
    fn the_self_wake_row_sits_directly_above_the_status_bar_and_goes_away_when_empty() {
        let mut editor = editor_at(80);
        // Nothing scheduled: no wake row at all, and the box keeps the row above the status bar.
        assert_eq!(editor.footer_row(), 24, "the status bar is the last row");
        assert_eq!(editor.wakes_row(), 23);
        assert_eq!(editor.bottom(), 23);

        // A fact: its own row directly above the status bar, everything above it up by one.
        editor.wakes = "\u{23f0} 2 wakes \u{b7} next 14:05".into();
        assert_eq!(editor.footer_row() - editor.wakes_row(), 1, "directly above the status bar");
        assert_eq!(editor.session_row(), 22, "the row above that one");
        assert_eq!(editor.bottom(), 22, "and the box - so the chat moved up, not the bar");
        assert!(editor.out_bottom() < 22, "the output region lost the row, it is not drawn over");

        // A notice as well: two rows under the box, wake last (nearest the bar).
        editor.session_notice = "update available".into();
        assert_eq!(editor.session_row(), 22);
        assert_eq!(editor.bottom(), 21);
    }

    /// What each screen row ended up holding, by row number: cursor moves address the rows, and text is
    /// appended to the row the cursor is on (a row can be written in pieces - the footer's numbers, then the
    /// model at a column of its own), so this is the screen as the reader sees it.
    fn rows_by_number(frame: &str) -> std::collections::BTreeMap<usize, String> {
        let mut rows: std::collections::BTreeMap<usize, String> = std::collections::BTreeMap::new();
        let mut rest = frame;
        let mut row: Option<usize> = None;
        while !rest.is_empty() {
            if let Some(start) = rest.find('\x1b') {
                // Text before the sequence belongs to the row the cursor is on.
                if start > 0 {
                    if let Some(known) = row { rows.entry(known).or_default().push_str(&rest[..start]); }
                }
                let after = &rest[start + 2..];
                let end = after.find(|c: char| !(c.is_ascii_digit() || c == '[' || c == ';' || c == '?')).unwrap_or(after.len());
                let sequence = &after[..=end];
                if sequence.ends_with('H') {
                    if let Some(parsed) = sequence.trim_start_matches('[').trim_end_matches('H')
                        .split(';').next().and_then(|first| first.parse::<usize>().ok()) {
                        row = Some(parsed);
                    }
                }
                rest = &after[end + 1..];
                continue;
            }
            if let Some(known) = row { rows.entry(known).or_default().push_str(rest); }
            break;
        }
        rows
    }

    #[test]
    fn at_80x24_the_fact_is_on_its_own_row_and_the_status_bar_keeps_its_numbers() {
        let mut editor = editor_at(80);
        editor.footer = "\u{f0450}3 \u{2692}2 \u{2191}9 \u{2193}4 \u{f01bc}0.31%".into();
        editor.footer_right = "stub-model".into();
        // Without a wake: no wake text anywhere, and the status bar keeps its numbers and its model.
        let plain = rows_by_number(&editor.render());
        assert!(plain.values().all(|row| !row.contains("wakes")), "no wake text anywhere: {plain:?}");
        let bar = plain.get(&editor.footer_row()).cloned().unwrap_or_default();
        assert!(bar.contains("\u{f0450}3") && bar.contains("stub-model"), "the status bar: {bar:?}");

        // With a wake: one more row, directly above the status bar, and the numbers are untouched.
        editor.wakes = "\u{23f0} 2 wakes \u{b7} next 14:05".into();
        let with = rows_by_number(&editor.render());
        let bar = with.get(&24).cloned().unwrap_or_default();
        assert!(bar.contains("\u{f0450}3") && bar.contains("stub-model"),
            "the status bar keeps the numbers and the model: {bar:?}");
        assert!(!bar.contains("wakes"), "and no wake text on it: {bar:?}");
        let above = with.get(&23).cloned().unwrap_or_default();
        assert!(above.contains("2 wakes") && above.contains("next 14:05"),
            "the fact is on row 23, directly above the bar at 24: {above:?} in {with:?}");
        assert_eq!(with.get(&22).map(String::as_str), Some(&*"\u{2500}".repeat(80)),
            "the box's bottom divider moved up to row 22, so nothing overlaps it: {with:?}");
        assert_eq!(with.get(&23).map(String::as_str).map(|row| row.contains("wakes")), Some(true),
            "row 23 is the fact and nothing else: {with:?}");
        for row in with.values() {
            assert!(row.chars().count() <= 80, "nothing is wider than the terminal: {row:?}");
        }

        // It disappears again, and takes its row with it.
        editor.wakes = String::new();
        let gone = rows_by_number(&editor.render());
        assert!(gone.values().all(|row| !row.contains("wakes")), "the row is gone: {gone:?}");
        assert_eq!(gone.get(&23).map(String::as_str), Some(&*"\u{2500}".repeat(80)),
            "and the box's divider came back down to row 23: {gone:?}");
    }

    fn type_bytes(editor: &mut Editor, bytes: &[u8]) -> Action {
        let mut action = Action::None;
        for &byte in bytes { action = editor.feed(byte); }
        action
    }
    /// Ctrl+Enter asks for the line NOW; Enter queues it. The chord is the reader's, so it is decided
    /// here, once, and the same act is reachable from the fallback chord (Ctrl+G) for a terminal whose
    /// Ctrl+Enter arrives as a plain Enter, and from the xterm form. docs/HOST.md has the rule.
    #[test]
    fn enter_queues_and_ctrl_enter_sends_now() {
        let mut e = Editor::default();
        e.insert_text("queued");
        assert_eq!(e.feed(b'\r'), Action::Submit("queued".into()), "Enter sends the draft as it always did");
        e.insert_text("now please");
        assert_eq!(type_bytes(&mut e, b"[13;5u"), Action::SubmitNow("now please".into()),
            "the kitty keyboard protocol's Ctrl+Enter sends now");
        e.insert_text("fallback");
        assert_eq!(e.feed(7), Action::SubmitNow("fallback".into()),
            "Ctrl+G is the same send-now for a terminal that reports Ctrl+Enter as a plain Enter");
        e.insert_text("xterm");
        assert_eq!(type_bytes(&mut e, b"[27;5;13~"), Action::SubmitNow("xterm".into()),
            "and so is xterm's modifyOtherKeys form");
        assert_eq!(e.text(), "", "a send-now line clears the draft exactly as Enter does");
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
    fn ctrl_v_asks_for_a_clipboard_image_and_the_token_is_one_step() {
        let mut e = Editor::default();
        e.width = 80;
        type_bytes(&mut e, b"look at ");
        assert_eq!(e.feed(22), Action::Paste, "Ctrl+V asks the host for the clipboard, once");
        assert_eq!(type_bytes(&mut e, b"\x1b[118;5u"), Action::Paste, "and so does kitty's Ctrl+V");
        e.insert_text("[Image #1]");
        assert_eq!(e.text(), "look at [Image #1]");
        e.feed(26);
        assert_eq!(e.text(), "look at ", "the inserted token is one undo step");
        // Inside a bracketed paste, byte 22 is data, never a command.
        type_bytes(&mut e, b"\x1b[200~a\x16b\x1b[201~");
        assert!(!e.text().contains("[Image"), "{}", e.text());
    }
    #[test]
    fn a_clipboard_text_paste_is_the_bracketed_paste_and_one_undo_step() {
        let mut e = Editor::default();
        e.width = 80;
        type_bytes(&mut e, b"look at ");
        assert_eq!(e.feed(22), Action::Paste, "Ctrl+V asks the host for the clipboard, once");
        assert_eq!(e.paste("one\ntwo\tthree"), Action::Pasted(8), "the span it wrote is the host's");
        assert_eq!(e.text(), "look at one\ntwo\tthree", "its newlines stay lines and its tab is data");
        assert_eq!(e.cursor, e.chars.len());
        e.feed(26);
        assert_eq!(e.text(), "look at ", "the whole paste is one undo step");
        assert_eq!(e.cursor, 8, "and the cursor goes back with it");
        assert_eq!(e.paste(""), Action::None, "an empty paste is nothing to undo");
        // A selection is replaced, and one undo brings back what it covered.
        type_bytes(&mut e, b"abc");
        type_bytes(&mut e, b"\x1b[1;2D\x1b[1;2D"); // Shift+Left twice: the last two characters
        assert_eq!(e.selection(), Some((9, 11)), "two characters are selected");
        assert_eq!(e.paste("XY"), Action::Pasted(9));
        assert_eq!(e.text(), "look at aXY", "the paste replaced them");
        e.feed(26);
        assert_eq!(e.text(), "look at abc", "and one undo brings them back");
    }
    #[test]
    fn a_bracketed_paste_keeps_its_tabs() {
        let mut e = Editor::default();
        type_bytes(&mut e, b"\x1b[200~if x {\n\treturn 1;\n}\x1b[201~");
        assert_eq!(e.text(), "if x {\n\treturn 1;\n}", "pasted code keeps its indentation");
        e.feed(26);
        assert_eq!(e.text(), "", "and the paste is still one undo step");
    }
    #[test]
    fn home_and_end_move_within_the_line_and_shift_selects() {
        // Operator 17/11: Home/End act on the focused line, Ctrl+A selects all, Shift+arrows select.
        let mut e = Editor::default();
        e.width = 80;
        type_bytes(&mut e, b"first line\x1b\rsecond line");
        assert_eq!(e.cursor, e.chars.len());
        type_bytes(&mut e, b"\x1b[H");
        assert_eq!(e.cursor, 11, "Home goes to the start of the second line, not the draft");
        type_bytes(&mut e, b"\x1b[F");
        assert_eq!(e.cursor, e.chars.len(), "End goes to the end of that line");
        type_bytes(&mut e, b"\x1b[A\x1b[F");
        assert_eq!(e.cursor, 10, "End on the first line stops before its newline");
        // Shift+Left x4 selects "line", the four characters before the cursor.
        type_bytes(&mut e, b"\x1b[1;2D\x1b[1;2D\x1b[1;2D\x1b[1;2D");
        assert_eq!(e.selected_text().as_deref(), Some("line"));
        // Typing replaces the selection; one undo brings it back.
        type_bytes(&mut e, b"row");
        assert_eq!(e.text(), "first row\nsecond line");
        e.feed(26);
        assert_eq!(e.text(), "first line\nsecond line", "typing over a selection is one undo step");
        // Ctrl+A selects everything; Ctrl+C copies it instead of interrupting.
        e.feed(1);
        assert_eq!(e.selected_text().as_deref(), Some("first line\nsecond line"));
        assert!(matches!(e.feed(3), Action::Copy(ref t) if t == "first line\nsecond line"));
        assert_eq!(e.text(), "first line\nsecond line", "copying never touches the draft");
        // Ctrl+Insert copies too; Backspace deletes the selection; Ctrl+X redoes.
        assert!(matches!(type_bytes(&mut e, b"\x1b[2;5~"), Action::Copy(ref t) if t == "first line\nsecond line"), "Ctrl+Insert copies");
        e.feed(127);
        assert_eq!(e.text(), "", "Backspace deletes the selection");
        e.feed(26);
        assert_eq!(e.text(), "first line\nsecond line");
        e.feed(24);
        assert_eq!(e.text(), "", "Ctrl+X redoes");
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
        type_bytes(&mut e, b"\x1b[1;5H\x0b"); assert_eq!(e.text(), "", "Ctrl+Home (the draft's start; Ctrl+A selects all since 17/11) then Ctrl+K");
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
    /// The CLI's two status rows name their glyphs in `lua/core/cli_view.lua`'s `GLYPH` table, and this
    /// crate is the one that LAYS THOSE ROWS OUT - the box, its divider, the footer - so the widths that
    /// matter are the ones this function gives. Victor's terminal (18/11, JetBrainsMono Nerd Font) has
    /// every one of these, and draws it in ONE cell: a character measured two here moves every number
    /// after it, and a character the font does NOT have (the `\u{25d1}` and `\u{25f7}` these replaced) is
    /// drawn from a fallback face at another size, which is the defect this test keeps out.
    /// The footer can carry colour now (the context ball's level), so "fits" must be measured on what
    /// the terminal draws: an escape sequence takes no cells and is never cut in half (Victor, 19/11).
    #[test]
    fn a_coloured_row_is_measured_and_clipped_by_its_visible_cells() {
        let red = "\x1b[38;2;255;107;128m";
        let row = format!("{red}\u{f0aa5}\x1b[0m\x1b[38;2;119;119;119m 93.8%/1.0M");
        assert_eq!(visible_cells(&row), 12, "the escapes take no cells: {row:?}");
        let kept = clip_cells(&row, 40);
        assert_eq!(kept, row, "a row inside 40 cells is returned WHOLE, colour and all");
        assert_eq!(visible_cells(&clip_cells(&row, 6)), 6, "cut to 6 cells, ellipsis included");
        let cut = clip_cells(&row, 6);
        assert!(cut.starts_with(red), "the colour that opened the row is kept: {cut:?}");
        assert!(cut.contains('\u{2026}'), "and the cut is marked: {cut:?}");
        // THE RESET COMES AFTER THE MARK. A cut that leaves the colour open paints the ellipsis - and
        // whatever the terminal draws beside it - in a colour the row no longer claims.
        assert!(cut.ends_with("\u{2026}\x1b[0m"), "and the colour is closed after the mark: {cut:?}");
    }

    #[test]
    fn the_status_bar_glyphs_are_one_cell_each() {
        let glyphs = [
            ("\u{f0766}", "the context ball, empty (below 3%)"),
            ("\u{f0a9e}", "the context ball, one eighth"),
            ("\u{f0a9f}", "the context ball, a quarter"),
            ("\u{f0aa0}", "the context ball, three eighths"),
            ("\u{f0aa1}", "the context ball, half"),
            ("\u{f0aa2}", "the context ball, five eighths"),
            ("\u{f0aa3}", "the context ball, three quarters"),
            ("\u{f0aa4}", "the context ball, seven eighths"),
            ("\u{f0aa5}", "the full context ball, 100% and past the window"),
            ("\u{f0dfa}", "the run's steps"),
            ("\u{f051b}", "the run's elapsed clock"),
            ("\u{f0450}", "the session's turns"),
            ("\u{f01bc}", "the cache-hit rate"),
        ];
        for (glyph, what) in glyphs {
            assert_eq!(glyph.chars().count(), 1, "{what}: one character, not a sequence");
            assert_eq!(cell_width_of(glyph.chars().next().unwrap()), 1,
                "{what} takes exactly one terminal cell: {glyph:?}");
        }
        // The row they sit on is one cell per character, so its column count is its character count -
        // which is what keeps `\u{394}` and `\u{2191}` in the columns the next redraw expects, whatever
        // the clocks are doing.
        let bar = "\u{f0dfa}2\u{b7}5s \u{394}12.3k \u{2191}4.6k \u{2193}310 \u{f051b}1:51";
        assert_eq!(bar.chars().count(), 29, "the sample row: {bar:?}");
        assert_eq!(bar.chars().map(cell_width_of).sum::<usize>(), bar.chars().count(),
            "no character of the status row is zero or two cells: {bar:?}");
        assert_eq!(clip_cells(bar, 40), bar, "and it fits the 40 cells it asks for, whole");
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
        type_bytes(&mut e, b"\x1b[1;5H\x1b[3~"); assert_eq!(e.text(), "ello\nworld é");
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
    #[test]
    fn a_rebuild_row_sits_between_the_box_and_the_footer_only_while_there_is_one() {
        let mut e = Editor::default(); e.row = 29; e.width = 60; e.height = 3;
        assert_eq!(e.out_bottom(), 26, "no build: the chat ends right on the input");
        e.build = "\u{27f3} building".into();
        assert_eq!((e.status_row(), e.session_row(), e.out_bottom()), (25, 29, 25),
            "a build takes the row under the box and pushes the box, not the chat, up one");
        assert!(e.render().contains("\x1b[29;1H\x1b[2K\u{27f3} building"), "and is drawn there");
        e.status = true;
        assert_eq!((e.status_row(), e.session_row(), e.out_bottom()), (25, 29, 24),
            "a run's status line keeps its own row above the box and the build stays under it");
    }

    // ---- session-status-content -----------------------------------------------------------
    // One line between the CLI's text area and its session status bar (the footer) for transient
    // session notices; the build loader replaces the notice on that same line; empty takes no line at
    // all. These are the twin of `lua/core/cli_view.lua`'s render tests (`scripts/test-cli-view.lua`)
    // and of the `build_status` ones: three renderers, one layout rule.
    // The sentence `lua/core/update_banner.lua` owns (M.LINE), with a sha in it.
    const SESSION_NOTICE: &str =
        "Update available (cccccccccccc) — /update here, or wa update in a terminal";

    #[test]
    fn no_notice_is_no_row_and_the_box_keeps_it() {
        let mut e = Editor::default(); e.row = 29; e.width = 60; e.height = 3;
        assert_eq!(e.session_content(), "");
        assert_eq!((e.bottom(), e.out_bottom()), (29, 26), "no row: the box sits on its row and the chat ends on the input");
        assert!(!e.render().contains("Update available"));
        // An empty notice and a whitespace one are both nothing.
        e.session_notice = "  \t ".into();
        assert_eq!((e.bottom(), e.out_bottom()), (29, 26), "whitespace is not a line");
    }

    #[test]
    fn the_notice_is_one_yellow_row_below_the_text_area_and_above_the_status_bar() {
        // Wide enough for the whole sentence: at 60 columns the second command is clipped away, and
        // this test is about the emphasis, not the clip (a_narrow_row_truncates_and_never_wraps).
        let mut e = Editor::default(); e.row = 29; e.width = 90; e.height = 3;
        e.session_notice = SESSION_NOTICE.into();
        assert_eq!((e.bottom(), e.session_row(), e.out_bottom()), (28, 29, 25),
            "the row under the box, the box one row higher, the chat one row shorter");
        let row = e.session_content();
        assert!(row.starts_with(crate::build_status::NOTICE), "painted the warning yellow: {row:?}");
        assert!(row.ends_with("\x1b[0m"));
        assert!(crate::selection::plain(&row) == SESSION_NOTICE, "the sentence is unchanged");
        // Both commands are bold, and nothing else is (Victor, 18/11): `/update` here, `wa update` in a
        // terminal. The list is `update_banner.COMMANDS` on the Lua side; this is the same emphasis.
        assert!(row.contains("\x1b[1m/update\x1b[22m"), "the /update word is bold: {row:?}");
        assert!(row.contains("\x1b[1mwa update\x1b[22m"), "and so is wa update: {row:?}");
        assert_eq!(row.matches("\x1b[1m").count(), 2, "two bold words, not three: {row:?}");
        let frame = e.render();
        assert!(frame.contains(&format!("\x1b[29;1H\x1b[2K{row}")), "drawn on the row under the box");
        assert_eq!(e.footer_row(), 30, "with the status bar still on the last row");
        // With a run in flight the status line is above the box and the notice never moves there.
        e.status = true;
        assert_eq!((e.status_row(), e.session_row(), e.out_bottom()), (25, 29, 24),
            "the run's own line is above the box, the notice below it");
        assert!(e.render().contains(&format!("\x1b[29;1H\x1b[2K{row}")));
    }

    #[test]
    fn a_build_replaces_the_notice_on_the_same_row() {
        let mut e = Editor::default(); e.row = 29; e.width = 60; e.height = 3;
        e.session_notice = SESSION_NOTICE.into();
        e.build = "\u{27f3} building wasm-agent \u{25b5}\u{2591}\u{258f} compiling serde".into();
        let frame = e.render();
        assert!(frame.contains("\u{27f3} building wasm-agent"), "the loader is drawn");
        assert!(!frame.contains("Update available"), "and the notice is gone from the same row");
        assert_eq!(e.session_row(), 29, "the row does not move when the loader replaces the notice");
        assert_eq!(e.out_bottom(), 25, "nor does the chat");
        // The build ends: the loader goes, the notice is back without moving anything.
        e.build.clear();
        let after = e.render();
        assert!(after.contains("Update available (cccccccccccc)") && !after.contains("building wasm-agent"));
        assert_eq!(e.session_row(), 29);
    }

    #[test]
    fn a_tool_calls_progress_never_takes_the_row() {
        // Victor, 2026-11-10: a running call says what it is doing inside its own block in the
        // transcript (`crate::transcript::Transcript::live`); this row is the update notice's, the
        // loader's and the result's. The row therefore has no third claimant to give it to.
        let mut e = Editor::default(); e.row = 29; e.width = 80; e.height = 3;
        assert_eq!(e.session_content(), "");
        let chat = e.out_bottom();
        // The notice owns it, and the row is exactly the notice's.
        e.session_notice = SESSION_NOTICE.into();
        assert_eq!(crate::selection::plain(&e.session_content()), SESSION_NOTICE);
        assert!(e.render().contains("Update available (cccccccccccc)"));
        // A build replaces the notice on the same row.
        e.build = "\u{27f3} building wasm-agent compiling serde".into();
        assert!(e.session_content().contains("building wasm-agent"));
        assert!(!e.render().contains("Update available"));
        // And with neither, there is no row at all - never a call's line standing in for one.
        e.build.clear();
        e.session_notice.clear();
        assert_eq!(e.session_content(), "");
        assert_eq!(e.out_bottom(), chat, "no row: the chat keeps the row it had");
        assert!(!e.render().contains("bash"), "nothing about a tool is drawn under the box");
    }

    #[test]
    fn a_narrow_row_truncates_and_never_wraps() {
        let mut e = Editor::default(); e.row = 29; e.width = 40; e.height = 3;
        e.session_notice = SESSION_NOTICE.into();
        let row = crate::selection::plain(&e.session_content());
        assert_eq!(row.chars().count(), 40, "clipped to the terminal's width: {row}");
        assert!(row.ends_with('\u{2026}'), "with an ellipsis");
        assert!(!row.contains('\n'), "one row, never wrapped");
        let frame = e.render();
        assert!(!frame.contains(&format!("\x1b[28;1H\x1b[2K{row}")), "the box's bottom border is not the notice's row");
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

    /// The three things the approval balloon needs from a panel and no other page did (`docs/APPROVE.md`):
    /// a field that keeps a sentence's spaces, a field that starts with text in it (edit in place), and
    /// letters a page names as shortcuts. None of them changes a page that did not ask for it.
    #[test]
    fn a_line_field_keeps_its_spaces_and_starts_from_its_value() {
        let spec = serde_json::json!({"title": "Edit", "input": "line", "value": "bom dia, tudo bem?"});
        let mut p = Panel::from_spec(&spec, 60, 30);
        assert!(p.render().contains("bom dia, tudo bem?"), "the draft is in the field, editable in place");
        // Backspace once, type the rest: what is submitted is the whole edited sentence.
        type_panel(&mut p, &[127]);
        type_panel(&mut p, b"!\r");
        assert_eq!(p.result.take(), Some(serde_json::json!({"action": "submit", "text": "bom dia, tudo bem!"})));
        // A `text` field is unchanged: it is a name, a key or a path, and whitespace still never lands.
        let mut t = Panel::from_spec(&serde_json::json!({"title": "Name", "input": "text"}), 60, 30);
        type_panel(&mut t, b"a b c\r");
        assert_eq!(t.result.take(), Some(serde_json::json!({"action": "submit", "text": "abc"})));
    }

    #[test]
    fn only_a_page_that_names_its_letters_has_them() {
        let spec = serde_json::json!({
            "title": "Draft for Laura",
            "lines": ["bom dia"],
            "options": [{"label": "Send as is"}, {"label": "Edit the text"}, {"label": "Reject with a note"}],
            "keys": {"e": 2, "r": 3},
        });
        type_panel_action(&spec, b'r', 3);
        type_panel_action(&spec, b'E', 2);
        // A letter the page did not name does nothing at all, exactly as before this existed.
        let mut quiet = Panel::from_spec(&spec, 60, 30);
        type_panel(&mut quiet, b"z");
        assert_eq!(quiet.result, None, "an unnamed letter is not a key");
        // And a page with no `keys` field is untouched by the feature.
        let plain = serde_json::json!({"title": "Sign in", "options": [{"label": "ChatGPT"}]});
        let mut p = Panel::from_spec(&plain, 60, 30);
        type_panel(&mut p, b"c");
        assert_eq!(p.result, None, "a page that named no letter keeps none");
    }

    fn type_panel_action(spec: &serde_json::Value, key: u8, expected: usize) {
        let mut p = Panel::from_spec(spec, 60, 30);
        type_panel(&mut p, &[key]);
        assert_eq!(p.result.take(), Some(serde_json::json!({"action": "select", "index": expected})),
            "{:?} picks option {expected}", key as char);
    }
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
        type_bytes(&mut e, b"\x1b[1;5H\x1b[B"); assert_eq!(e.cursor, 4, "Down from the first line moves a line");
    }
    #[test]
    fn the_box_grows_to_thirty_percent_of_the_window_then_scrolls_under_a_bar() {
        // A 40-row window: the limit is 12 rows (30% of 40), not the three the view asked for.
        let mut e = Editor::default(); e.row = 39; e.width = 80; e.height = 3;
        for i in 0..40 { if i > 0 { e.insert('\n'); } for ch in format!("line{i:02}").chars() { e.insert(ch); } }
        assert_eq!(e.max_rows(), 12);
        let (top, bottom) = e.box_rows().expect("drawn");
        assert_eq!(bottom - top - 1, 12, "twelve draft rows between the two rules");
        let frame = e.render();
        assert!(frame.contains("line39") && frame.contains("line28") && !frame.contains("line27"), "the last twelve lines: {frame:?}");
        for row in top + 1..bottom {
            assert!(frame.contains(&format!("\x1b[{row};80H")), "the bar's cell on row {row}, in the last column");
        }
        assert!(frame.contains(crate::scroll::bar::THUMB) && frame.contains(crate::scroll::bar::TRACK), "the transcript's glyphs");
        // The wheel moves the lines, not the cursor; with the cursor's line out of the box it is hidden.
        assert!(e.wheel(true, 3));
        let frame = e.render();
        assert!(frame.contains("line25") && frame.contains("line36") && !frame.contains("line37"), "{frame:?}");
        assert!(e.cursor_frame().is_empty() && !frame.contains("\x1b[?25h"), "no cursor is placed outside the box");
        assert_eq!(e.cursor(), e.chars.len(), "the wheel never moves the cursor");
        for _ in 0..40 { e.wheel(true, 3); }
        assert!(e.render().contains("\u{276f} line00"), "the wheel stops at the first line");
        // A key is about the cursor: its line comes back.
        let _ = e.feed(b'x');
        assert!(e.render().contains("line39x"));
        // The limit follows the window: 12 rows -> three, 10 rows -> three.
        e.row = 11; assert_eq!(e.max_rows(), 3);
        e.row = 9; assert_eq!(e.max_rows(), 3);
        // A draft that fits has no bar and leaves the wheel to the chat.
        let mut short = Editor::default(); short.row = 39; short.width = 80; short.height = 3;
        for ch in "one\ntwo".chars() { short.insert(ch); }
        assert!(!short.wheel(true, 3) && !short.overflows());
        assert!(!short.render().contains(crate::scroll::bar::TRACK));
    }
    #[test]
    fn long_draft_does_not_wrap_terminal() {
        // A 12-row window (row 11): the box's limit is three rows there (30% of 12 is 3), which is the
        // limit this test was written against; at 16 rows the limit is four and the draft would fit.
        let mut e = Editor::default(); e.row = 11; e.width = 12; e.height = 3;
        type_bytes(&mut e, b"abcdefghijklmnopqrstuvwxyz0123456789");
        // Four rows of text in a three-row box: the last column is the scrollbar's, so the draft wraps at
        // nine cells (it was ten before the box had a bar) and the last three rows are the ones shown.
        assert!(e.render().contains("stuvwxyz0") && e.render().contains("123456789") && e.render().contains("jklmnopqr"));
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

    // ---- the twin-render contract -----------------------------------------------------------------
    // `lua/core/cli_view.lua` draws the same console as this editor, and on 2026-11-11 two rendering
    // bugs came from the twins disagreeing (the status-row geometry and `session_content`) rather than
    // from either being wrong alone. Both tests read `fixtures/twin-frames.json`: the Lua one is
    // scripts/test-twin-render.lua, and this is the Rust one, so a change to either renderer that the
    // other does not follow fails where it was made.
    fn strip_ansi(text: &str) -> String {
        let mut out = String::new();
        let mut skip = false;
        for ch in text.chars() {
            if ch == '\u{1b}' { skip = true; }
            else if skip { if ch == 'm' { skip = false; } }
            else { out.push(ch); }
        }
        out
    }

    #[test]
    fn twin_frames_agree_with_the_shared_fixture() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/twin-frames.json");
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
        let fixture: serde_json::Value = serde_json::from_str(&text).expect("fixtures/twin-frames.json is valid JSON");
        let cases = fixture["cases"].as_array().expect("the fixture has cases");
        assert!(!cases.is_empty(), "the twin-render contract has no cases");
        for case in cases {
            let name = case["name"].as_str().expect("every case is named");
            let rows = case["rows"].as_u64().expect("rows") as usize;
            let width = case["width"].as_u64().expect("width") as usize;
            let mut editor = Editor::default();
            // The editor's `row` is the input row, which is the row above the footer.
            editor.row = rows - 1;
            editor.width = width;
            editor.height = 3;
            editor.session_notice = case["notice"].as_str().unwrap_or("").to_string();
            editor.build = case["build"].as_str().unwrap_or("").to_string();
            assert_eq!(editor.session_row(), rows - 1, "{name}: the session row is the row above the footer");
            assert_eq!(editor.footer_row(), rows, "{name}: the footer is the screen's last row");
            let drawn = strip_ansi(&editor.session_content());
            match case["session_text"].as_str() {
                Some(want) => assert_eq!(drawn, want, "{name}: session_content"),
                None => assert!(drawn.is_empty(), "{name}: nothing claims the row, so nothing is drawn (got {drawn:?})"),
            }
        }
    }

    /// The screen row the draft is drawn on, for an editor whose box sits at the bottom of an
    /// otherwise empty screen (no session row, no wakes row) with a draft of N text rows.
    fn draft_row(editor: &Editor, lines: usize) -> usize {
        editor.bottom() - lines
    }

    #[test]
    fn kill_keys_act_on_the_selection_when_there_is_one() {
        // Ctrl+K / Ctrl+U / Ctrl+W with text selected kill the selection, the way every editor does.
        // Without a selection they stay the line and word kills they were.
        for (key, label) in [(11u8, "Ctrl+K"), (21, "Ctrl+U"), (23, "Ctrl+W")] {
            let mut e = Editor::default();
            e.width = 80;
            type_bytes(&mut e, b"one two three");
            e.select(4, 7); // "two"
            assert_eq!(e.selected_text().as_deref(), Some("two"), "{label} starts from a selection");
            e.feed(key);
            assert_eq!(e.text(), "one  three", "{label} removes the selection, not the rest of the line");
            assert_eq!(e.cursor, 4, "{label} leaves the cursor where the selection began");
            assert_eq!(e.selection(), None, "{label} ends the selection");
            e.feed(26);
            assert_eq!(e.text(), "one two three", "{label} is one undo step");
        }
        // A selection made backwards behaves the same.
        let mut e = Editor::default();
        e.width = 80;
        type_bytes(&mut e, b"alpha beta gamma");
        e.select(10, 6); // "beta", selected right to left
        e.feed(21);
        assert_eq!(e.text(), "alpha  gamma", "Ctrl+U with a backwards selection kills it, not the prefix");
        // With nothing selected the three keys are unchanged.
        let mut e = Editor::default();
        e.width = 80;
        type_bytes(&mut e, b"abc def\x1b[D\x1b[D\x1b[D\x1b[D");
        e.feed(11);
        assert_eq!(e.text(), "abc", "Ctrl+K truncates at the cursor");
        let mut e = Editor::default();
        e.width = 80;
        type_bytes(&mut e, b"abc def\x1b[D\x1b[D\x1b[D\x1b[D");
        e.feed(21);
        assert_eq!(e.text(), " def", "Ctrl+U kills the prefix and keeps what follows the cursor");
        let mut e = Editor::default();
        e.width = 80;
        type_bytes(&mut e, b"abc def");
        e.feed(23);
        assert_eq!(e.text(), "abc ", "Ctrl+W kills the preceding word");
    }

    #[test]
    fn ctrl_x_and_ctrl_y_are_undo_and_redo_on_the_byte_and_from_kitty() {
        let mut e = Editor::default();
        e.width = 80;
        type_bytes(&mut e, b"hello world");
        e.feed(26);
        assert_eq!(e.text(), "hello", "Ctrl+Z (byte 26) undoes");
        e.feed(24);
        assert_eq!(e.text(), "hello world", "Ctrl+X (byte 24) redoes");
        e.feed(26);
        assert_eq!(e.text(), "hello");
        assert_eq!(type_bytes(&mut e, b"\x1b[121;5u"), Action::None, "kitty's Ctrl+Y is a key, not text");
        assert_eq!(e.text(), "hello world", "kitty's Ctrl+Y redoes");
        assert!(!e.text().contains("121"), "and it never lands in the draft");
        e.feed(26);
        assert_eq!(e.text(), "hello");
        assert_eq!(type_bytes(&mut e, b"\x1b[120;5u"), Action::None, "kitty's Ctrl+X is a key, not text");
        assert_eq!(e.text(), "hello world", "kitty's Ctrl+X redoes, as byte 24 does");
        assert!(!e.text().contains("120"), "and it never lands in the draft");
    }

    #[test]

    /// The other direction of the table's promise: a key the dispatcher handles must be a row.
    /// Every control byte with no row leaves the draft exactly as it was, any other character is
    /// text (the row that says so), and an escape sequence nobody binds is swallowed whole - so a
    /// binding added here and not to KEYMAP fails this test instead of drifting out of /keybindings.
    #[test]
    fn no_key_outside_the_table_does_anything() {
        for byte in 0u8..=127 {
            if crate::keymap::draft_byte(byte).is_some() { continue; }
            let mut e = Editor::default();
            type_bytes(&mut e, b"abc");
            let before = (e.text(), e.cursor(), e.bash, e.selected_text());
            let action = e.feed(byte);
            if byte >= 32 && byte != 127 {
                assert_eq!(e.text(), format!("abc{}", byte as char), "{} is a character, and it types", byte);
                assert_eq!(action, Action::None, "{} types, so it reports nothing", byte);
            } else {
                assert_eq!((e.text(), e.cursor(), e.bash, e.selected_text()), before,
                    "the control byte {byte} changed the draft but is not a row in /keybindings");
                assert_eq!(action, Action::None, "the control byte {byte} answers {action:?} but is not a row in /keybindings");
            }
        }
    }

    /// A terminal sends more sequences than a draft binds (a colour set, an unknown key). None of
    /// their bytes may reach the prompt, and none may become a key: the table names the keys, and
    /// everything else is swallowed to its final byte.
    #[test]
    fn an_escape_sequence_nobody_binds_is_swallowed() {
        let mut e = Editor::default();
        type_bytes(&mut e, b"ab");
        for sequence in [b"\x1b[38;5;9m".as_slice(), b"\x1b[99~", b"\x1b[1;9P", b"\x1bOz", b"\x1b[13;9u"] {
            type_bytes(&mut e, sequence);
            assert_eq!(e.text(), "ab", "{:?} left bytes in the draft", String::from_utf8_lossy(sequence));
        }
        assert_eq!(e.escape.len(), 0, "and the decoder is not stuck mid-sequence");
    }
    fn index_at_maps_a_cell_to_a_draft_index_and_never_splits_a_wide_character() {
        // The mouse drag in the input box turns a screen cell into a draft index (host.rs,
        // handle_mouse). A wide character is two cells and ONE index: a press on either half must land
        // on the character, never inside it.
        let mut e = Editor::default();
        e.row = 20;
        e.width = 80;
        e.height = 4;
        type_bytes(&mut e, "\u{4f60}\u{597d}ab".as_bytes());
        let row = draft_row(&e, 1);
        assert_eq!(e.index_at(row, 3), Some(0), "the first cell of the wide character");
        assert_eq!(e.index_at(row, 4), Some(0), "and its second cell: both are one index");
        assert_eq!(e.index_at(row, 5), Some(1), "the second wide character");
        assert_eq!(e.index_at(row, 6), Some(1));
        assert_eq!(e.index_at(row, 7), Some(2), "an ASCII character is one cell");
        assert_eq!(e.index_at(row, 8), Some(3));
        assert_eq!(e.index_at(row, 9), Some(4), "past the end of the text is the end of the draft");
        assert_eq!(e.index_at(row - 1, 3), None, "above the box there is no index");
        assert_eq!(e.index_at(row + 1, 3), None, "and below it the border is not text");
    }

    #[test]
    fn a_mouse_drag_over_the_box_selects_between_the_two_cells() {
        // The two halves of a drag, as host.rs drives them: a press turns its cell into an index and
        // calls click(); the drag turns the cell under the pointer into one and calls select().
        let mut e = Editor::default();
        e.row = 20;
        e.width = 80;
        e.height = 4;
        type_bytes(&mut e, b"select this word");
        let row = draft_row(&e, 1);
        let anchor = e.index_at(row, 3).expect("the press lands in the text");
        e.click(anchor);
        assert_eq!(e.selection(), None, "a press alone selects nothing");
        e.select(anchor, e.index_at(row, 9).expect("so does the drag"));
        assert_eq!(e.selected_text().as_deref(), Some("select"), "the drag selects what it crossed");
        // Dragging to a cell left of the press selects to the left.
        let back = e.index_at(row, 14).expect("the far cell");
        e.select(back, anchor);
        assert_eq!(e.selected_text().as_deref(), Some("select this"), "dragging backwards selects to the left");
        // A release on the press's own cell selects nothing (host.rs clears it the same way).
        e.click(anchor);
        e.select(anchor, anchor);
        assert_eq!(e.selection(), None);
        // With no selection Ctrl+C is what it was: no copy, and (between runs) a note about the draft.
        assert_eq!(e.feed(3), Action::None, "an empty drag leaves Ctrl+C to interrupt, not to copy");
    }

}
