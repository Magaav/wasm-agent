//! The fullscreen console: the alternate screen, the chat drawn into it, the input box pinned to the
//! bottom row, and the terminal given back on every way out.
//!
//! Everything below the chat stays exactly where it is today: `terminal_editor::Editor` owns the
//! bottom rows (its box, the status line the ticker writes, the footer) and draws them itself, so
//! fullscreen changes *where the output region is*, never how the input looks or behaves. This module
//! only takes the rows the editor does not own - `Editor::out_bottom()` of them - and pins the editor
//! to the last row: `editor.row = height - 1`, which is what `host.input_editor` already does with
//! the row it is handed.
//!
//! `--inline`, a pipe, `WA_TUI=inline` or `WA_TUI_FULLSCREEN=off` leave `mode` at `Inline`, and then
//! every method here that could touch the terminal returns nothing at all: the caller keeps today's
//! inline path byte for byte (`enter`, `leave` and `frame` are empty strings).
//!
//! Giving the terminal back is not left to the normal exit path. `Guard::arm` restores on `Drop`, and
//! `install_panic_restore` restores before a panic's message is printed - a panic while the alternate
//! screen is up would otherwise leave the reader in a blank screen with no cursor, which is the one
//! failure a terminal program must not have.
use crate::scroll::chat::{Chat, Kind};
use crate::scroll::keys::Decoder;
use crate::scroll::settings::{Action, Mode, Scrollbar, Settings};
use crate::terminal_editor::Editor;
use std::sync::{Arc, Mutex};

/// The bytes that put the terminal back: mouse and paste off, the cursor back, the attributes cleared,
/// and the alternate screen left (which restores what the shell had on it).
pub fn leave_bytes(mode: Mode) -> String {
    if mode == Mode::Inline { return String::new(); }
    format!("{}\x1b[?2004l\x1b[?25h\x1b[0m\x1b[?1049l", crate::selection::DISABLE)
}

/// The bytes that take the screen: the alternate screen, cleared, the cursor hidden until the first
/// frame places it, and SGR mouse reports on for the wheel.
pub fn enter_bytes(mode: Mode) -> String {
    if mode == Mode::Inline { return String::new(); }
    format!("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l{}", crate::selection::ENABLE)
}

/// What a key did, or what the editor has to be given: the bytes of every key no binding claimed.
#[derive(Debug, Default, PartialEq)]
pub struct Handled {
    pub forwarded: Vec<u8>,
    /// Whether the view moved, so the caller knows to draw again.
    pub changed: bool,
}

/// The chat on the alternate screen: its content, its keys, and the frame it draws.
pub struct Console {
    pub settings: Settings,
    pub mode: Mode,
    chat: Chat,
    keys: Decoder,
    /// A mouse report split across two reads, waiting for the rest.
    mouse_pending: Vec<u8>,
    last: Vec<String>,
    drawn: (usize, usize),
}

impl Console {
    pub fn new(settings: Settings, mode: Mode) -> Console {
        Console { settings, mode, chat: Chat::default(), keys: Decoder::default(), mouse_pending: Vec::new(),
            last: Vec::new(), drawn: (0, 0) }
    }

    pub fn chat(&self) -> &Chat { &self.chat }
    pub fn chat_mut(&mut self) -> &mut Chat { &mut self.chat }

    /// Start a block: `Kind::Tool` and `Kind::Thinking` fold under Ctrl+O and Ctrl+T.
    pub fn begin(&mut self, kind: Kind) { self.chat.block(kind); }
    /// Append output. The rows it added are what a scrolled-up reader's position moves by.
    pub fn write(&mut self, text: &str) { self.chat.write(text); }

    /// One key or mouse read. Mouse reports are taken out first (`selection::take`), then the bytes
    /// are decoded: a bound key moves the chat, an unbound one is forwarded to the input editor.
    pub fn feed(&mut self, bytes: &[u8]) -> Handled {
        // The inline console owns its keys: nothing here may eat one, so in fallback mode the bytes
        // are handed back untouched and no view state moves.
        if self.mode == Mode::Inline { return Handled { forwarded: bytes.to_vec(), changed: false }; }
        let mut data = std::mem::take(&mut self.mouse_pending);
        data.extend_from_slice(bytes);
        let (keys, mice, pending) = crate::selection::take(&data);
        self.mouse_pending = pending;
        let mut handled = Handled::default();
        for event in mice {
            match event {
                crate::selection::Mouse::WheelUp => { self.wheel(true); handled.changed = true; }
                crate::selection::Mouse::WheelDown => { self.wheel(false); handled.changed = true; }
                _ => {}
            }
        }
        for byte in keys {
            let key = self.keys.feed(byte);
            if key.pending() { continue; }
            let action = key.name.and_then(|name| self.settings.action(name));
            match action {
                Some(action) => handled.changed |= self.apply(action),
                // No binding: the editor keeps the key, byte for byte.
                None => handled.forwarded.extend(key.raw),
            }
        }
        handled
    }

    /// A lone Esc (the terminal sent nothing after it), which `feed` holds waiting for the rest of a
    /// sequence. Forwarded, so the editor's menus close as they always did.
    pub fn lone_escape(&mut self) -> Option<Vec<u8>> {
        self.keys.lone_escape().map(|key| key.raw)
    }

    fn apply(&mut self, action: Action) -> bool {
        match action {
            Action::PageUp => self.chat.page(true),
            Action::PageDown => self.chat.page(false),
            Action::HalfPageUp => self.chat.half_page(true),
            Action::HalfPageDown => self.chat.half_page(false),
            Action::LineUp => self.chat.line(true),
            Action::LineDown => self.chat.line(false),
            Action::Top => self.chat.to_top(),
            Action::Bottom => self.chat.to_bottom(),
            Action::ToggleTools => { self.chat.toggle_tools(); }
            Action::ToggleThinking => { self.chat.toggle_thinking(); }
        }
        true
    }

    /// The wheel scrolls `WA_TUI_WHEEL_LINES` rows (`auto` = the inline console's three).
    pub fn wheel(&mut self, up: bool) {
        let rows = self.settings.wheel_rows(self.chat.height()).max(1) as isize;
        self.chat.scroll(if up { rows } else { -rows });
    }

    /// The rows the chat gets: everything the input box, the status line, the slash menu and the
    /// footer do not own.
    pub fn region(editor: &Editor) -> usize { editor.out_bottom() }

    /// One full frame: the chat's rows, then the editor's own bottom rows and its cursor. Only the
    /// chat rows that changed are written, so a stream of output on a tall screen costs the rows that
    /// grew, not the screen.
    ///
    /// The caller has already put the terminal in raw mode and drawn nothing else: this pins the
    /// editor to the last row (`width`, `height` = the console's size) and draws.
    pub fn frame(&mut self, editor: &mut Editor, width: usize, height: usize) -> String {
        if self.mode == Mode::Inline || width == 0 || height < 4 { return String::new(); }
        editor.width = width;
        editor.row = height - 1;
        let region = Self::region(editor).clamp(1, height);
        let rows = self.chat.view(width, region, self.settings.scrollbar);
        let mut out = String::new();
        if self.drawn != (width, height) {
            out.push_str("\x1b[2J");
            self.last.clear();
            self.drawn = (width, height);
        }
        for (index, row) in rows.iter().enumerate() {
            if self.last.get(index) == Some(row) { continue; }
            out.push_str(&format!("\x1b[{};1H\x1b[2K{row}\x1b[0m", index + 1));
            if index >= self.last.len() { self.last.resize(index + 1, String::new()); }
            self.last[index] = row.clone();
        }
        // Rows the chat had and no longer does (the box grew, the menu opened): cleared before the
        // editor draws over its own, so no old line can show through a border.
        for index in rows.len()..self.last.len() { out.push_str(&format!("\x1b[{};1H\x1b[2K", index + 1)); }
        self.last.truncate(rows.len());
        out.push_str(&editor.render());
        out.push_str(&editor.cursor_frame());
        out
    }

    /// The scrollbar in force, for a caller that wants to describe the frame (and for tests).
    pub fn scrollbar(&self) -> Scrollbar { self.settings.scrollbar }
}

/// Puts the terminal back when it goes out of scope - on a normal exit, on a `return` from a `?`, and
/// while a panic unwinds. Idempotent, so an explicit `leave()` and the `Drop` do not fight.
pub struct Guard { mode: Mode, sink: Box<dyn FnMut(&str) + Send>, left: bool }

impl Guard {
    /// Restore to the process's own stdout, through the same writer the console uses.
    pub fn arm(mode: Mode) -> Guard {
        Guard::with_sink(mode, |bytes| { let _ = crate::terminal_editor::write(bytes); })
    }

    /// The same, to a sink of the caller's: a test's buffer, a log on the way out.
    pub fn with_sink(mode: Mode, sink: impl FnMut(&str) + Send + 'static) -> Guard {
        Guard { mode, sink: Box::new(sink), left: false }
    }

    /// Give the screen back now (the `Drop` then does nothing).
    pub fn leave(&mut self) {
        if self.left || self.mode == Mode::Inline { self.left = true; return; }
        self.left = true;
        (self.sink)(&leave_bytes(self.mode));
    }

    pub fn left(&self) -> bool { self.left }
}

impl Drop for Guard {
    fn drop(&mut self) { self.leave(); }
}

type Hook = Box<dyn Fn(&std::panic::PanicHookInfo<'_>) + Sync + Send + 'static>;

/// A panic hook that gives the terminal back before the message is printed. The previous hook is kept
/// in this value so `restore` can put it back; dropping it does not, because a process wants the hook
/// for its whole life and a test wants to put the old one back explicitly.
pub struct PanicRestore { slot: Arc<Mutex<Option<Hook>>> }

impl PanicRestore {
    pub fn restore(self) {
        if let Some(previous) = self.slot.lock().ok().and_then(|mut slot| slot.take()) {
            std::panic::set_hook(previous);
        }
    }
}

/// Install the restore-on-panic hook, writing to the process's stdout.
pub fn install_panic_restore(mode: Mode) -> PanicRestore {
    install_panic_restore_with(mode, |bytes| { let _ = crate::terminal_editor::write(bytes); })
}

/// The same, to a sink: the hook runs inside a panic, so its writer must not panic itself.
pub fn install_panic_restore_with(mode: Mode, sink: impl FnMut(&str) + Send + 'static) -> PanicRestore {
    let slot: Arc<Mutex<Option<Hook>>> = Arc::new(Mutex::new(Some(std::panic::take_hook())));
    let kept = slot.clone();
    let sink = Mutex::new(sink);
    let restore = leave_bytes(mode);
    std::panic::set_hook(Box::new(move |info| {
        if let Ok(mut sink) = sink.lock() { sink(&restore); }
        // The previous hook prints the message; it must see the restored screen.
        if let Ok(slot) = kept.lock() {
            if let Some(previous) = slot.as_ref() { previous(info); }
        }
    }));
    PanicRestore { slot }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn a_guard_gives_the_screen_back_once_even_when_it_is_dropped_and_left() {
        let seen = Arc::new(Mutex::new(String::new()));
        {
            let mut guard = Guard::with_sink(Mode::Fullscreen, {
                let seen = seen.clone();
                move |bytes: &str| seen.lock().unwrap().push_str(bytes)
            });
            assert!(!guard.left());
            guard.leave();
            assert!(guard.left());
            guard.leave();
        }
        let bytes = seen.lock().unwrap().clone();
        assert_eq!(bytes, leave_bytes(Mode::Fullscreen), "once, and it is the restore sequence");
        assert!(bytes.contains("\x1b[?1049l") && bytes.contains("\x1b[?1002l"), "{bytes:?}");
        assert!(!bytes.contains("\x1b[?1049h"), "leaving never enters");
        let empty = Arc::new(Mutex::new(String::new()));
        drop(Guard::with_sink(Mode::Inline, { let empty = empty.clone(); move |text: &str| empty.lock().unwrap().push_str(text) }));
        assert!(empty.lock().unwrap().is_empty(), "the inline fallback writes nothing on the way out");
    }

    #[test]
    fn the_restore_sequences_are_one_enter_and_one_leave() {
        assert!(enter_bytes(Mode::Inline).is_empty() && leave_bytes(Mode::Inline).is_empty());
        let enter = enter_bytes(Mode::Fullscreen);
        assert!(enter.starts_with("\x1b[?1049h") && enter.contains("\x1b[?1002h"), "{enter:?}");
        assert!(leave_bytes(Mode::Fullscreen).ends_with("\x1b[?1049l"));
    }

    #[test]
    fn a_panic_gives_the_terminal_back_before_it_prints() {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let seen = Arc::new(Mutex::new(String::new()));
        let restore = install_panic_restore_with(Mode::Fullscreen, {
            let seen = seen.clone();
            move |bytes: &str| seen.lock().unwrap().push_str(bytes)
        });
        let quiet = std::panic::catch_unwind(|| panic!("the console is up"));
        assert!(quiet.is_err(), "the panic still unwinds");
        assert!(seen.lock().unwrap().contains("\x1b[?1049l"), "the screen came back first: {:?}", seen.lock().unwrap());
        restore.restore();
        std::panic::set_hook(previous);
    }
}
