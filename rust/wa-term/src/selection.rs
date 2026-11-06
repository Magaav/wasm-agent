//! Selecting and copying the chat with the mouse.
//!
//! The CLI paints the transcript itself, into a scroll region, so the terminal's own scrollback never
//! holds the chat and a raw-mode Ctrl+C is byte 3, not "copy". Text could only be copied by dragging
//! over what happened to be on screen and pressing the terminal's own copy key (Ctrl+Shift+C on foot).
//! So the CLI owns the selection the way Claude Code does: it asks the terminal for mouse reports
//! (SGR, button-event tracking), highlights what is dragged over in the chat area, and Ctrl+C with a
//! selection copies it through OSC 52 - the terminal's clipboard, which works over ssh and
//! `docker exec` too. Without a selection Ctrl+C is what it always was (interrupt, twice to quit).
//! Shift+drag still makes a native terminal selection on terminals that honour it (foot, xterm).
//!
//! Pure functions here (decode, slice, extract, overlay) so the rules are tested without a terminal;
//! `host.rs` holds the state and the drawing.
use crate::terminal_editor::cell_width_of;

/// Turn on mouse reports: button-event tracking (press, drag, release, wheel) in SGR encoding.
pub const ENABLE: &str = "\x1b[?1002h\x1b[?1006h";
pub const DISABLE: &str = "\x1b[?1002l\x1b[?1006l";

#[derive(Debug, PartialEq, Clone, Copy)]
pub enum Mouse { Press(usize, usize), Drag(usize, usize), Release(usize, usize), WheelUp, WheelDown, Other }

/// Take every complete SGR mouse report (`ESC [ < b ; x ; y M|m`) out of `bytes`, returning the
/// bytes that were not mouse reports and the reports in order. An incomplete report at the very end
/// is returned as `pending`, to be prefixed to the next read (a terminal may split a report).
pub fn take(bytes: &[u8]) -> (Vec<u8>, Vec<Mouse>, Vec<u8>) {
    let (mut rest, mut events) = (Vec::with_capacity(bytes.len()), Vec::new());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0x1b && bytes.get(i + 1) == Some(&b'[') && bytes.get(i + 2) == Some(&b'<') {
            let mut j = i + 3;
            while j < bytes.len() && (bytes[j].is_ascii_digit() || bytes[j] == b';') { j += 1; }
            if j >= bytes.len() { return (rest, events, bytes[i..].to_vec()); }
            if bytes[j] == b'M' || bytes[j] == b'm' {
                events.push(decode(&bytes[i + 3..j], bytes[j] == b'M'));
                i = j + 1;
                continue;
            }
        }
        rest.push(bytes[i]);
        i += 1;
    }
    (rest, events, Vec::new())
}

fn decode(params: &[u8], press: bool) -> Mouse {
    let text = String::from_utf8_lossy(params);
    let mut parts = text.split(';').map(|p| p.parse::<usize>().unwrap_or(0));
    let (button, x, y) = (parts.next().unwrap_or(0), parts.next().unwrap_or(1).max(1), parts.next().unwrap_or(1).max(1));
    match (button, press) {
        (64, true) => Mouse::WheelUp,
        (65, true) => Mouse::WheelDown,
        (0, true) => Mouse::Press(y, x),
        (32, true) => Mouse::Drag(y, x),
        (0, false) | (32, false) => Mouse::Release(y, x),
        _ => Mouse::Other,
    }
}

/// A row without its escape sequences: what the reader sees, one char per cell run.
pub fn plain(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            match chars.peek() {
                Some('[') => { chars.next(); for c in chars.by_ref() { if ('@'..='~').contains(&c) { break; } } }
                Some(']') => { chars.next(); while let Some(c) = chars.next() { if c == '\x07' { break; } if c == '\x1b' { chars.next(); break; } } }
                _ => {}
            }
            continue;
        }
        out.push(c);
    }
    out
}

/// The part of a plain row between screen columns `from..to` (0-based, cells), and what is around it.
pub fn split_cells(text: &str, from: usize, to: usize) -> (String, String, String) {
    let (mut before, mut inside, mut after, mut col) = (String::new(), String::new(), String::new(), 0usize);
    for c in text.chars() {
        let w = cell_width_of(c);
        if col < from { before.push(c) } else if col < to { inside.push(c) } else { after.push(c) }
        col += w;
    }
    (before, inside, after)
}

/// Anchor and head as `(row, col)`, 1-based screen cells, ordered start..end (end inclusive).
pub fn ordered(a: (usize, usize), b: (usize, usize)) -> ((usize, usize), (usize, usize)) {
    if a <= b { (a, b) } else { (b, a) }
}

/// The columns of `row` inside the selection, as a half-open 0-based range, or None.
fn span(row: usize, start: (usize, usize), end: (usize, usize)) -> Option<(usize, usize)> {
    if row < start.0 || row > end.0 { return None; }
    let from = if row == start.0 { start.1 - 1 } else { 0 };
    let to = if row == end.0 { end.1 } else { usize::MAX };
    Some((from, to))
}

/// The selected text from the rows on screen (`rows[0]` is screen row 1): trailing spaces trimmed
/// per line, lines joined with `\n` - what a terminal copy gives.
pub fn text(rows: &[String], a: (usize, usize), b: (usize, usize)) -> String {
    let (start, end) = ordered(a, b);
    let mut lines = Vec::new();
    for row in start.0..=end.0 {
        let Some(line) = rows.get(row - 1) else { break };
        let (from, to) = span(row, start, end).unwrap_or((0, 0));
        lines.push(split_cells(line, from, to).1.trim_end().to_string());
    }
    lines.join("\n")
}

/// Redraw the selected rows with the selection in reverse video (the rest of each such row plain).
pub fn overlay(rows: &[String], a: (usize, usize), b: (usize, usize)) -> String {
    let (start, end) = ordered(a, b);
    let mut frame = String::new();
    for row in start.0..=end.0.min(rows.len()) {
        let (from, to) = span(row, start, end).unwrap_or((0, 0));
        let (before, inside, after) = split_cells(&rows[row - 1], from, to);
        frame.push_str(&format!("\x1b[{row};1H\x1b[2K\x1b[0m{before}\x1b[7m{inside}\x1b[0m{after}"));
    }
    frame
}

/// OSC 52: put `text` on the terminal's clipboard.
pub fn osc52(text: &str) -> String {
    use base64::Engine as _;
    format!("\x1b]52;c;{}\x07", base64::engine::general_purpose::STANDARD.encode(text.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mouse_reports_are_taken_out_of_the_input_and_the_rest_is_kept() {
        let (rest, events, pending) = take(b"a\x1b[<0;5;3M\x1b[<32;9;4M\x1b[<0;9;4mb\x1b[<64;1;1M");
        assert_eq!(rest, b"ab");
        assert_eq!(events, vec![Mouse::Press(3, 5), Mouse::Drag(4, 9), Mouse::Release(4, 9), Mouse::WheelUp]);
        assert!(pending.is_empty());
        let (rest, events, pending) = take(b"x\x1b[<0;5");
        assert_eq!((rest, events.len(), pending), (b"x".to_vec(), 0, b"\x1b[<0;5".to_vec()), "a split report waits for the rest");
        let (rest, _, _) = take(b"\x1b[A\x1b[200~");
        assert_eq!(rest, b"\x1b[A\x1b[200~", "arrows and paste markers are not mouse reports");
    }

    #[test]
    fn the_selected_text_is_what_was_dragged_over() {
        let rows: Vec<String> = vec!["\x1b[1mhello world\x1b[0m".into(), "second line   ".into(), "third".into()];
        let rows: Vec<String> = rows.iter().map(|r| plain(r)).collect();
        assert_eq!(text(&rows, (1, 7), (1, 11)), "world");
        assert_eq!(text(&rows, (2, 3), (1, 7)), "world\nsec", "dragging backwards selects the same span");
        assert_eq!(text(&rows, (1, 1), (3, 5)), "hello world\nsecond line\nthird", "trailing spaces trimmed");
        let frame = overlay(&rows, (1, 7), (1, 11));
        assert!(frame.contains("hello \x1b[7mworld\x1b[0m"), "{frame:?}");
    }

    #[test]
    fn a_copy_is_osc_52() {
        assert_eq!(osc52("hi"), "\x1b]52;c;aGk=\x07");
    }
}
