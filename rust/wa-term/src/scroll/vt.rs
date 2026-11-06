//! A terminal in memory: the render tests' screen.
//!
//! A test of "the reader's rows stay put" that asserts on the escape bytes would be a test of the
//! encoder, not of the screen: the bytes say where the cursor was told to go, and only a terminal can
//! say what ended up there. So this is the smallest terminal that can answer that - a fixed grid, the
//! alternate screen, cursor addressing, erasing, SGR (kept per cell, not interpreted) and the private
//! modes the console turns on - and the tests read the grid, the way a reader reads the screen.
//!
//! It is deliberately not a general terminal: it knows the sequences `wa` emits plus the ordinary
//! ones, it has no scrollback, and an unknown sequence is skipped rather than emulated. That is the
//! contract it is used under: every frame it parses is one this crate produced.
use crate::terminal_editor::cell_width_of;

#[derive(Clone)]
struct Cell { ch: char, tail: bool, sgr: String }

impl Default for Cell {
    fn default() -> Self { Cell { ch: ' ', tail: false, sgr: String::new() } }
}

pub struct Vt {
    pub width: usize,
    pub height: usize,
    main: Vec<Vec<Cell>>,
    alt: Vec<Vec<Cell>>,
    used_alt: bool,
    /// The cursor, 0-based; a column equal to `width` means "the next character wraps".
    pub cursor: (usize, usize),
    saved_cursor: (usize, usize),
    pub cursor_visible: bool,
    /// SGR mouse reports on (either encoding).
    pub mouse: bool,
    pub paste: bool,
    scroll_top: usize,
    scroll_bottom: usize,
    sgr: String,
    pending: Vec<u8>,
}

impl Vt {
    pub fn new(width: usize, height: usize) -> Vt {
        Vt { width, height, main: blank(width, height), alt: blank(width, height), used_alt: false,
            cursor: (0, 0), saved_cursor: (0, 0), cursor_visible: true, mouse: false, paste: false,
            scroll_top: 0, scroll_bottom: height.saturating_sub(1), sgr: String::new(),
            pending: Vec::new() }
    }

    /// Resize like a terminal does: the new grid is blank, the cursor is clamped, and the screen it
    /// resizes is the one in use.
    pub fn resize(&mut self, width: usize, height: usize) {
        let fresh = blank(width, height);
        if self.used_alt { self.alt = fresh; } else { self.main = fresh; }
        self.width = width;
        self.height = height;
        self.cursor = (self.cursor.0.min(height.saturating_sub(1)), self.cursor.1.min(width));
        self.scroll_top = 0;
        self.scroll_bottom = height.saturating_sub(1);
    }

    /// Whether the alternate screen is the one being drawn on.
    pub fn on_alt(&self) -> bool { self.used_alt }

    /// The current screen, one string per row, trailing blanks trimmed.
    pub fn rows(&self) -> Vec<String> {
        let cells = if self.used_alt { &self.alt } else { &self.main };
        cells.iter().map(|row| {
            let mut text = String::new();
            for cell in row.iter().filter(|cell| !cell.tail) { text.push(cell.ch); }
            text.trim_end().to_string()
        }).collect()
    }

    /// Row `row` (0-based) as text.
    pub fn row(&self, row: usize) -> String { self.rows().get(row).cloned().unwrap_or_default() }

    pub fn text(&self) -> String { self.rows().join("\n") }

    /// The SGR state each cell of `row` was drawn with: `["\x1b[38;2;119;119;119m", ...]`.
    pub fn sgr(&self, row: usize) -> Vec<String> {
        let cells = if self.used_alt { &self.alt } else { &self.main };
        cells.get(row).map(|cells| cells.iter().filter(|cell| !cell.tail).map(|cell| cell.sgr.clone()).collect()).unwrap_or_default()
    }

    /// The hangs the tests need for a size that changed on the other side of the fence.
    pub fn feed_str(&mut self, text: &str) { self.feed(text.as_bytes()); }

    pub fn feed(&mut self, bytes: &[u8]) {
        let mut data = std::mem::take(&mut self.pending);
        data.extend_from_slice(bytes);
        let mut at = 0;
        while at < data.len() {
            let byte = data[at];
            if byte == 0x1b {
                match self.escape(&data[at..]) {
                    Some(len) => { at += len; continue; }
                    None => { self.pending = data[at..].to_vec(); return; }
                }
            }
            match byte {
                b'\r' => { self.cursor.1 = 0; at += 1; }
                b'\n' => { self.line_feed(); at += 1; }
                0x08 => { self.cursor.1 = self.cursor.1.saturating_sub(1); at += 1; }
                b if b < 0x20 => at += 1,
                _ => {
                    let len = match byte { 0xf0..=0xf4 => 4, 0xe0..=0xef => 3, 0xc0..=0xdf => 2, _ => 1 };
                    if at + len > data.len() { self.pending = data[at..].to_vec(); return; }
                    match std::str::from_utf8(&data[at..at + len]) {
                        Ok(text) => { for ch in text.chars() { self.put(ch); } at += len; }
                        Err(_) => at += 1,
                    }
                }
            }
        }
    }

    /// The length of the escape sequence at the start of `data`, or None if it is not all there yet.
    fn escape(&mut self, data: &[u8]) -> Option<usize> {
        if data.len() < 2 { return None; }
        match data[1] {
            b'[' => {
                let mut at = 2;
                while at < data.len() && (0x30..=0x3f).contains(&data[at]) { at += 1; }
                while at < data.len() && (0x20..=0x2f).contains(&data[at]) { at += 1; }
                if at >= data.len() { return None; }
                let last = data[at];
                if !(0x40..=0x7e).contains(&last) { return Some(at + 1); }
                let params = String::from_utf8_lossy(&data[2..at]).to_string();
                self.csi(&params, last as char);
                Some(at + 1)
            }
            b']' => {
                let mut at = 2;
                while at < data.len() {
                    if data[at] == 0x07 { return Some(at + 1); }
                    if data[at] == 0x1b && data.get(at + 1) == Some(&b'\\') { return Some(at + 2); }
                    at += 1;
                }
                None
            }
            b'(' | b')' | b'#' => if data.len() < 3 { None } else { Some(3) },
            _ => Some(2),
        }
    }

    fn csi(&mut self, params: &str, last: char) {
        let private = params.starts_with('?');
        let body = params.trim_start_matches('?');
        let numbers: Vec<usize> = body.split(';').map(|part| part.trim().parse().unwrap_or(0)).collect();
        let count = |index: usize| numbers.get(index).copied().filter(|n| *n > 0).unwrap_or(1);
        if private {
            for mode in numbers.iter() {
                match (mode, last) {
                    (1049, 'h') | (47, 'h') => {
                        self.saved_cursor = self.cursor;
                        self.used_alt = true;
                        self.alt = blank(self.width, self.height);
                        self.cursor = (0, 0);
                    }
                    (1049, 'l') | (47, 'l') => { self.used_alt = false; self.cursor = self.saved_cursor; }
                    (25, 'h') => self.cursor_visible = true,
                    (25, 'l') => self.cursor_visible = false,
                    (1000 | 1002 | 1003 | 1006, 'h') => self.mouse = true,
                    (1000 | 1002 | 1003 | 1006, 'l') => self.mouse = false,
                    (2004, 'h') => self.paste = true,
                    (2004, 'l') => self.paste = false,
                    _ => {}
                }
            }
            return;
        }
        match last {
            'H' | 'f' => {
                let row = numbers.first().copied().filter(|n| *n > 0).unwrap_or(1);
                let col = numbers.get(1).copied().filter(|n| *n > 0).unwrap_or(1);
                self.cursor = ((row - 1).min(self.height.saturating_sub(1)), (col - 1).min(self.width));
            }
            'A' => self.cursor.0 = self.cursor.0.saturating_sub(count(0)),
            'B' => self.cursor.0 = (self.cursor.0 + count(0)).min(self.height.saturating_sub(1)),
            'C' => self.cursor.1 = (self.cursor.1 + count(0)).min(self.width),
            'D' => self.cursor.1 = self.cursor.1.saturating_sub(count(0)),
            'G' => self.cursor.1 = (count(0) - 1).min(self.width),
            'd' => self.cursor.0 = (count(0) - 1).min(self.height.saturating_sub(1)),
            'J' => {
                match numbers.first().copied().unwrap_or(0) {
                    2 | 3 => self.clear(0, 0, self.width, self.height),
                    1 => { self.clear(0, 0, self.cursor.1 + 1, self.cursor.0); self.erase_line(2); }
                    _ => self.erase_to_end(),
                }
            }
            'K' => self.erase_line(numbers.first().copied().unwrap_or(0)),
            'm' => {
                if numbers.is_empty() || numbers[0] == 0 { self.sgr.clear(); } else { self.sgr.push_str(&format!("\x1b[{params}m")); }
            }
            'r' => {
                let top = numbers.first().copied().filter(|n| *n > 0).unwrap_or(1);
                let bottom = numbers.get(1).copied().filter(|n| *n > 0).unwrap_or(self.height);
                self.scroll_top = (top - 1).min(self.height.saturating_sub(1));
                self.scroll_bottom = (bottom - 1).min(self.height.saturating_sub(1));
                self.cursor = (0, 0);
            }
            'S' => for _ in 0..count(0) { self.scroll_up(); },
            'T' => for _ in 0..count(0) { self.scroll_down(); },
            _ => {}
        }
    }

    fn put(&mut self, ch: char) {
        let cells_w = cell_width_of(ch).max(1);
        if self.cursor.1 + cells_w > self.width { self.cursor.1 = 0; self.line_feed(); }
        let (row, col) = self.cursor;
        let sgr = self.sgr.clone();
        {
            let line = self.line_mut(row);
            if col < line.len() { line[col] = Cell { ch, tail: false, sgr: sgr.clone() }; }
            if cells_w == 2 && col + 1 < line.len() { line[col + 1] = Cell { ch: ' ', tail: true, sgr }; }
        }
        self.cursor.1 = (col + cells_w).min(self.width);
    }

    fn line_feed(&mut self) {
        if self.cursor.0 == self.scroll_bottom { self.scroll_up(); }
        else { self.cursor.0 = (self.cursor.0 + 1).min(self.height.saturating_sub(1)); }
    }

    fn scroll_up(&mut self) {
        let (top, bottom) = (self.scroll_top, self.scroll_bottom);
        let cells = if self.used_alt { &mut self.alt } else { &mut self.main };
        if top < bottom && bottom < cells.len() {
            for row in top..bottom { cells[row] = cells[row + 1].clone(); }
            cells[bottom] = vec![Cell::default(); self.width];
        }
    }

    fn scroll_down(&mut self) {
        let (top, bottom) = (self.scroll_top, self.scroll_bottom);
        let cells = if self.used_alt { &mut self.alt } else { &mut self.main };
        if top < bottom && bottom < cells.len() {
            for row in (top + 1..=bottom).rev() { cells[row] = cells[row - 1].clone(); }
            cells[top] = vec![Cell::default(); self.width];
        }
    }

    fn line_mut(&mut self, row: usize) -> &mut Vec<Cell> {
        let cells = if self.used_alt { &mut self.alt } else { &mut self.main };
        &mut cells[row]
    }

    fn clear(&mut self, from_col: usize, from_row: usize, to_col: usize, to_row: usize) {
        for row in from_row..=to_row.min(self.height.saturating_sub(1)) {
            let line = self.line_mut(row);
            let (a, b) = if row == from_row { (from_col, to_col.min(line.len())) } else { (0, to_col.min(line.len())) };
            for cell in line.iter_mut().take(b).skip(a) { *cell = Cell::default(); }
        }
    }

    fn erase_line(&mut self, mode: usize) {
        let (row, col) = self.cursor;
        match mode {
            1 => self.clear(0, row, col + 1, row),
            2 => self.clear(0, row, self.width, row),
            _ => self.clear(col, row, self.width, row),
        }
    }

    fn erase_to_end(&mut self) {
        let (row, col) = self.cursor;
        self.clear(col, row, self.width, row);
        for next in row + 1..self.height { self.clear(0, next, self.width, next); }
    }

    /// Every cell of the screen, as `rows` but without trimming: what a frame must fill.
    pub fn cells_text(&self) -> Vec<String> {
        let cells = if self.used_alt { &self.alt } else { &self.main };
        cells.iter().map(|row| row.iter().filter(|cell| !cell.tail).map(|cell| cell.ch).collect()).collect()
    }
}

fn blank(width: usize, height: usize) -> Vec<Vec<Cell>> { vec![vec![Cell::default(); width]; height] }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_alternate_screen_comes_back_untouched() {
        let mut vt = Vt::new(10, 3);
        vt.feed_str("shell\r\nprompt");
        let before = vt.rows();
        vt.feed_str("\x1b[?1049h\x1b[2J\x1b[Hhello");
        assert!(vt.on_alt());
        assert_eq!(vt.row(0), "hello");
        vt.feed_str("\x1b[?25l\x1b[?1002h\x1b[?1006h");
        assert!(!vt.cursor_visible && vt.mouse);
        vt.feed_str("\x1b[?1002l\x1b[?1006l\x1b[?25h\x1b[?1049l");
        assert_eq!(vt.rows(), before, "the shell's screen is exactly as it was");
        assert!(vt.cursor_visible && !vt.mouse);
    }

    #[test]
    fn rows_wrap_at_the_width_and_a_wide_character_takes_two_cells() {
        let mut vt = Vt::new(4, 3);
        vt.feed_str("abcdef");
        assert_eq!(vt.rows()[..2], ["abcd", "ef"]);
        vt.feed_str("\x1b[2J\x1b[H\u{2500}ab\r\nx");
        assert_eq!(vt.rows()[0], "\u{2500}ab");
        assert_eq!(vt.rows()[1], "x", "a carriage return before the line feed, as the console emits it");
        // A carriage return then a newline is the line break the console emits.
        vt.feed_str("\x1b[3;1H\r\nlast");
        assert_eq!(vt.rows()[2], "last");
    }

    #[test]
    fn erasing_a_line_and_the_cursor_addressing_work() {
        let mut vt = Vt::new(8, 3);
        vt.feed_str("aaaaaaaa\x1b[1;3Hbb\x1b[1;5H\x1b[K");
        assert_eq!(vt.row(0), "aabb", "two bytes over the row, then erased from the cursor");
        vt.feed_str("\x1b[2;1Hfull\x1b[2;1H\x1b[2K");
        assert_eq!(vt.row(1), "");
        vt.feed_str("\x1b[3;1Hzzzz\x1b[3;2H\x1b[1K");
        assert_eq!(vt.row(2), "  zz");
    }
}
