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

/// Turn on mouse reports: button-event tracking (press, drag, release, wheel) *and* any-motion
/// tracking (the pointer moving with no button down, which is what the scrollbar's hover needs), in
/// SGR encoding (`1006`, so a column above 223 is one number and not two bytes). Only while the chat
/// owns the screen: `host.input_editor` turns them on when it takes the frame and `restore_input`
/// turns them off on the way out, and the fullscreen console does the same around its session.
///
/// `1003` is the mode that costs something - a moving pointer sends a report - so nothing may
/// redraw on one: the bar redraws only when the pointer enters or leaves it, and a report that
/// matches nothing is dropped (`handle_mouse`). pi enables the same set (`tui-alt-screen.ts`:
/// `1000h 1002h 1003h 1004h 1006h`); `1004` (focus) is left out here, because this decoder has no
/// way to tell a focus event from a key sequence and would type one into the draft.
pub const ENABLE: &str = "\x1b[?1002h\x1b[?1003h\x1b[?1006h";
/// Off in the reverse order, so no terminal is left tracking motion after the last sequence.
pub const DISABLE: &str = "\x1b[?1006l\x1b[?1003l\x1b[?1002l";

/// Motion with no button down (`35`), which only `1003` reports: the pointer's row and column.
pub const MOTION: usize = 35;

#[derive(Debug, PartialEq, Clone, Copy)]
pub enum Mouse { Press(usize, usize), Drag(usize, usize), Release(usize, usize), Motion(usize, usize), WheelUp(usize, usize), WheelDown(usize, usize), Other }

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
        (64, true) => Mouse::WheelUp(y, x),
        (65, true) => Mouse::WheelDown(y, x),
        (0, true) => Mouse::Press(y, x),
        (32, true) => Mouse::Drag(y, x),
        (MOTION, true) => Mouse::Motion(y, x),
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

/// The columns of `row` inside the selection, as a half-open 0-based range, or None. `cols` is how
/// many columns the chat itself owns (the last selectable column, 1-based): every span is clamped to
/// it, so no cell of the scrollbar's column - the screen's last one while the bar is drawn - is ever
/// inside a selection. That column holds the bar's glyph, which a copy used to carry at the end of
/// every line (Victor, 21/11: the pasted text ended in it).
fn span(row: usize, start: (usize, usize), end: (usize, usize), cols: usize) -> Option<(usize, usize)> {
    if row < start.0 || row > end.0 { return None; }
    let from = (if row == start.0 { start.1.saturating_sub(1) } else { 0 }).min(cols);
    let to = (if row == end.0 { end.1 } else { usize::MAX }).min(cols);
    Some((from, to))
}

/// A plain row cut to the chat's `cols` columns: whatever is past them - the scrollbar's column - is
/// not chat text, so it is neither copied nor highlighted.
fn within(text: &str, cols: usize) -> String { split_cells(text, 0, cols).1 }

/// The selected text from the rows on screen (`rows[0]` is screen row 1): the chat's columns only,
/// trailing spaces trimmed per line, lines joined with `\n` - what a terminal copy gives.
pub fn text(rows: &[String], a: (usize, usize), b: (usize, usize), cols: usize) -> String {
    let (start, end) = ordered(a, b);
    let mut lines = Vec::new();
    for row in start.0..=end.0 {
        let Some(line) = rows.get(row - 1) else { break };
        let (from, to) = span(row, start, end, cols).unwrap_or((0, 0));
        lines.push(split_cells(&within(line, cols), from, to).1.trim_end().to_string());
    }
    lines.join("\n")
}

/// Redraw the selected rows with the selection in reverse video (the rest of each such row plain),
/// inside the chat's columns only - what is highlighted is exactly what `text` copies, and the
/// scrollbar's column is never painted by it. A row's `2K` does clear that column, so the caller puts
/// the bar back afterwards (`Transcript::bar_frame`).
pub fn overlay(rows: &[String], a: (usize, usize), b: (usize, usize), cols: usize) -> String {
    let (start, end) = ordered(a, b);
    let mut frame = String::new();
    for row in start.0..=end.0.min(rows.len()) {
        let (from, to) = span(row, start, end, cols).unwrap_or((0, 0));
        let (before, inside, after) = split_cells(&within(&rows[row - 1], cols), from, to);
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
    fn any_motion_tracking_is_turned_on_with_the_reports_and_off_again_in_reverse() {
        // 1006 SGR, 1003 any-motion (the bar's hover), 1002 button-event (drag, wheel).
        assert_eq!(ENABLE, "\x1b[?1002h\x1b[?1003h\x1b[?1006h");
        assert_eq!(DISABLE, "\x1b[?1006l\x1b[?1003l\x1b[?1002l");
        // A pointer moving with no button down is a report of its own, not a press or a drag.
        let (rest, events, pending) = take(b"\x1b[<35;12;7M");
        assert!(rest.is_empty() && pending.is_empty());
        assert_eq!(events, vec![Mouse::Motion(7, 12)], "row 7, column 12: what a hover needs");
        // And a moving pointer arrives with every other report in the same read.
        let (_, events, _) = take(b"\x1b[<35;1;2M\x1b[<0;3;4M\x1b[<32;5;6M\x1b[<35;7;8M");
        assert_eq!(events, vec![Mouse::Motion(2, 1), Mouse::Press(4, 3), Mouse::Drag(6, 5), Mouse::Motion(8, 7)]);
    }

    #[test]
    fn mouse_reports_are_taken_out_of_the_input_and_the_rest_is_kept() {
        let (rest, events, pending) = take(b"a\x1b[<0;5;3M\x1b[<32;9;4M\x1b[<0;9;4mb\x1b[<64;1;1M");
        assert_eq!(rest, b"ab");
        assert_eq!(events, vec![Mouse::Press(3, 5), Mouse::Drag(4, 9), Mouse::Release(4, 9), Mouse::WheelUp(1, 1)]);
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
        // `cols` = 80: a screen wide enough for every row here, so these are the spans themselves.
        assert_eq!(text(&rows, (1, 7), (1, 11), 80), "world");
        assert_eq!(text(&rows, (2, 3), (1, 7), 80), "world\nsec", "dragging backwards selects the same span");
        assert_eq!(text(&rows, (1, 1), (3, 5), 80), "hello world\nsecond line\nthird", "trailing spaces trimmed");
        let frame = overlay(&rows, (1, 7), (1, 11), 80);
        assert!(frame.contains("hello \x1b[7mworld\x1b[0m"), "{frame:?}");
    }

    /// The chat rows as the transcript hands them to the selection: each line padded to the chat's
    /// width, then the scrollbar's glyph in the screen's last column (`Transcript::draw_bar`, with
    /// the bar's three glyphs - track, thumb, thumb under the pointer - one per row).
    const CHAT: usize = 20;
    fn chat_rows() -> Vec<String> {
        let (track, thumb, active) = ('\u{2502}', '\u{2503}', '\u{2588}');
        ["anchors.", "second line", "third"]
            .iter()
            .zip([track, thumb, active])
            .map(|(line, glyph)| plain(&format!("{line:<CHAT$}{glyph}")))
            .collect()
    }

    #[test]
    fn a_multi_line_copy_stops_at_the_chat_and_carries_no_bar_and_no_padding() {
        let rows = chat_rows();
        assert!(rows[0].ends_with('\u{2502}'), "the row the transcript draws ends in the bar: {rows:?}");
        // A drag from the first column of the first row to the chat's last column of the last one.
        let copied = text(&rows, (1, 1), (3, CHAT), CHAT);
        assert_eq!(copied, "anchors.\nsecond line\nthird", "no bar glyph, no trailing spaces: {copied:?}");
        assert!(!copied.contains(['\u{2502}', '\u{2503}', '\u{2588}']), "no glyph of the bar: {copied:?}");
        // And a drag that ran on to the bar's own column - what a mouse at the right edge of the
        // screen reports - copies exactly the same text: that column is not the chat's.
        assert_eq!(text(&rows, (1, 1), (3, CHAT + 1), CHAT), copied, "a drag onto the bar adds nothing");
        assert_eq!(text(&rows, (3, CHAT + 1), (1, 1), CHAT), copied, "and neither does one that starts there");
        assert_eq!(text(&rows, (1, 1), (1, CHAT + 1), CHAT), "anchors.", "one row on its own");
    }

    #[test]
    fn the_overlay_paints_the_chat_and_never_the_bar_column() {
        let rows = chat_rows();
        let frame = overlay(&rows, (1, 1), (3, CHAT), CHAT);
        assert!(!frame.contains(['\u{2502}', '\u{2503}', '\u{2588}']), "the bar's column is the transcript's to draw: {frame:?}");
        // What is highlighted is exactly what a copy takes: the chat's columns, padding included.
        let expected = format!("\x1b[1;1H\x1b[2K\x1b[0m\x1b[7m{:<CHAT$}\x1b[0m", "anchors.");
        assert!(frame.contains(&expected), "{frame:?}");
        // A drag onto the bar's column highlights no more than the chat: same frame.
        assert_eq!(overlay(&rows, (1, 1), (3, CHAT + 1), CHAT), frame);
    }

    #[test]
    fn a_copy_is_osc_52() {
        assert_eq!(osc52("hi"), "\x1b]52;c;aGk=\x07");
    }
}
