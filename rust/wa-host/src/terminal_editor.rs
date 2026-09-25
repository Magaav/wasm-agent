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
pub struct RawMode(libc::termios);
#[cfg(unix)]
pub fn try_raw() -> Option<RawMode> {
    // A redirected stdin is a line stream, not a terminal: do not change it.
    let mut old = unsafe { std::mem::zeroed() };
    if unsafe { libc::tcgetattr(0, &mut old) } != 0 { return None; }
    let mut raw = old;
    unsafe { libc::cfmakeraw(&mut raw) };
    if unsafe { libc::tcsetattr(0, libc::TCSANOW, &raw) } != 0 { return None; }
    Some(RawMode(old))
}
#[cfg(unix)]
impl Drop for RawMode {
    fn drop(&mut self) { unsafe { libc::tcsetattr(0, libc::TCSANOW, &self.0); } }
}

#[cfg(windows)]
pub struct RawMode { handle: *mut std::ffi::c_void, mode: u32, codepage: u32 }
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
        let codepage = GetConsoleCP();
        if SetConsoleCP(65001) == 0 {
            SetConsoleMode(handle, mode);
            return None;
        }
        Some(RawMode { handle, mode, codepage })
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
        unsafe { SetConsoleMode(self.handle, self.mode); SetConsoleCP(self.codepage); }
    }
}
#[cfg(not(any(unix, windows)))]
pub struct RawMode;
#[cfg(not(any(unix, windows)))]
pub fn try_raw() -> Option<RawMode> { None }

#[derive(Debug, PartialEq)]
pub enum Action { None, Submit(String), Eof }

#[derive(Default)]
pub struct Editor {
    chars: Vec<char>, cursor: usize, history: Vec<String>, history_at: Option<usize>, saved: String,
    escape: Vec<u8>, utf8: Vec<u8>, paste: bool, pub row: usize, pub width: usize, pub height: usize,
}

impl Editor {
    fn text(&self) -> String { self.chars.iter().collect() }
    fn replace(&mut self, text: &str) { self.chars = text.chars().collect(); self.cursor = self.chars.len(); }
    fn insert(&mut self, ch: char) { self.chars.insert(self.cursor, ch); self.cursor += 1; }
    fn history(&mut self, up: bool) {
        if self.history.is_empty() { return; }
        if up {
            let next = self.history_at.map(|n| n.saturating_sub(1)).unwrap_or_else(|| {
                self.saved = self.text(); self.history.len() - 1
            });
            self.history_at = Some(next);
            let text = self.history[next].clone(); self.replace(&text);
        } else if let Some(n) = self.history_at {
            if n + 1 == self.history.len() { self.history_at = None; let text = self.saved.clone(); self.replace(&text); }
            else { self.history_at = Some(n + 1); let text = self.history[n + 1].clone(); self.replace(&text); }
        }
    }
    pub fn feed(&mut self, byte: u8) -> Action {
        if !self.escape.is_empty() {
            self.escape.push(byte);
            let seq = self.escape.as_slice();
            // CSI arrows, Home/End, Delete and bracketed paste boundaries.
            if seq == b"\x1b[200~" { self.paste = true; self.escape.clear(); return Action::None; }
            if seq == b"\x1b[201~" { self.paste = false; self.escape.clear(); return Action::None; }
            if seq == b"\x1b[13;2u" || seq == b"\x1b[27;2;13~" {
                self.insert('\n'); self.escape.clear(); return Action::None;
            }
            if seq == b"\x1b[D" { self.cursor = self.cursor.saturating_sub(1); }
            else if seq == b"\x1b[C" { self.cursor = (self.cursor + 1).min(self.chars.len()); }
            else if seq == b"\x1b[A" { self.history(true); }
            else if seq == b"\x1b[B" { self.history(false); }
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
                let line = self.text(); self.chars.clear(); self.cursor = 0; self.history_at = None;
                if !line.is_empty() { self.history.push(line.clone()); }
                Action::Submit(line)
            }
            b'\n' => { self.insert('\n'); Action::None } // Ctrl+J: multiline without submitting
            3 => { self.chars.clear(); self.cursor = 0; Action::None } // Ctrl+C clears a draft
            4 if self.chars.is_empty() => Action::Eof,
            4 => { if self.cursor < self.chars.len() { self.chars.remove(self.cursor); } Action::None }
            8 | 127 => { if self.cursor > 0 { self.cursor -= 1; self.chars.remove(self.cursor); } Action::None }
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
    /// Three rows of wrapped, editable input below the ticker. Only this region is
    /// erased; the output scroll region never moves when Enter is pressed.
    pub fn render(&self) -> String {
        if self.row == 0 || self.width < 8 || self.height == 0 { return String::new(); }
        let available = self.width.saturating_sub(4);
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
        let first = cursor.0.saturating_sub(self.height - 1);
        let mut frame = String::new();
        for visual in 0..self.height {
            let row = self.row - self.height + 1 + visual;
            frame.push_str(&format!("\x1b[{row};1H\x1b[2K"));
            if let Some(text) = lines.get(first + visual) {
                frame.push_str(if first + visual == 0 { "> " } else { "  " });
                frame.push_str(text);
            }
        }
        frame.push_str(&format!("\x1b[{};{}H", self.row - self.height + 1 + cursor.0 - first,
            3 + cursor.1));
        frame
    }
}

// UTF-8 is not a terminal column count. Keep CJK and emoji inside the viewport;
// combining marks share their preceding cell. A full grapheme engine would also
// handle ZWJ sequences, but this covers the common terminal width contract.
fn cell_width(ch: char) -> usize {
    let cp = ch as u32;
    if (0x300..=0x36f).contains(&cp) || (0x1ab0..=0x1aff).contains(&cp) { return 0; }
    if (0x1100..=0x115f).contains(&cp) || (0x2e80..=0xa4cf).contains(&cp)
        || (0xac00..=0xd7a3).contains(&cp) || (0xf900..=0xfaff).contains(&cp)
        || (0xfe10..=0xfe6f).contains(&cp) || (0xff01..=0xff60).contains(&cp)
        || (0x1f300..=0x1faff).contains(&cp) { 2 } else { 1 }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn type_bytes(editor: &mut Editor, bytes: &[u8]) -> Action {
        let mut action = Action::None;
        for &byte in bytes { action = editor.feed(byte); }
        action
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
        assert!(e.render().contains("> first") && e.render().contains("  second"));
        assert_eq!(type_bytes(&mut e, b"\r"), Action::Submit("first\nsecond".into()));
        assert!(!e.render().contains("first") && !e.render().contains("second"));
    }
    #[test]
    fn long_draft_does_not_wrap_terminal() {
        let mut e = Editor::default(); e.row = 15; e.width = 12; e.height = 3;
        type_bytes(&mut e, b"abcdefghijklmnopqrstuvwxyz");
        assert!(e.render().contains("qrstuvwx"));
        assert!(!e.render().contains("> abcdefgh"), "older rows scroll out of the editor");
        assert_eq!(type_bytes(&mut e, b"\r"), Action::Submit("abcdefghijklmnopqrstuvwxyz".into()));
    }
}
