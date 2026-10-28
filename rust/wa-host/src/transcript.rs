//! The chat transcript as the CLI shows it: a list of blocks the view appends to, drawn by the host
//! into the output region. Owning the transcript here (rather than streaming text into the
//! terminal) is what lets a block be folded, focused and expanded while Lua is blocked, and what
//! puts the chat back exactly where it was after the slash menu or a panel closes.
//!
//! A *topic* is a collapsible block - the model's thinking, a tool call - shown at most
//! `FOLDED_ROWS` rows until it is expanded. Ctrl+Up (from the draft) focuses the latest topic; Up and
//! Down move between topics, Right expands, Left folds, Esc goes back to typing.
use crate::terminal_editor::cell_width_of;

pub const FOLDED_ROWS: usize = 3;
const MAX_LINES: usize = 20_000;
const RESET: &str = "\x1b[0m";
const DIM: &str = "\x1b[38;2;119;119;119m";
const FOCUS: &str = "\x1b[38;2;255;255;255m";

#[derive(Default, Clone)]
pub struct Block { pub lines: Vec<String>, open: bool, pub topic: bool, pub expanded: bool }

#[derive(Default)]
pub struct Transcript { pub blocks: Vec<Block>, pub focus: Option<usize>, pub dirty: bool,
    /// The view's first row while it is frozen (the reader is navigating or has paged back): new
    /// output then lands below it without moving what they are reading. `None` = follow the bottom.
    /// Negative while the chat is shorter than the screen: the blank rows above it are part of
    /// what stays put (otherwise new output would shrink them and slide everything up).
    top: Option<isize>,
    /// Freeze at the next draw (the current bottom-anchored position becomes `top`).
    freeze: bool,
    /// Rows to move a frozen view by at the next draw (PageUp > 0).
    page_delta: isize,
    /// Navigating topics (Ctrl+Up): the view stays frozen even at the bottom.
    pub nav: bool }

/// One PageUp/PageDown step for a chat that occupies `area` screen rows: a third of it, at least one
/// row. A whole screen jumped past what the reader was following; a third keeps two thirds in view.
pub fn page_step(area: usize) -> isize { (area / 3).max(1) as isize }

impl Transcript {
    /// Start a new block (`topic` = collapsible). An empty current block is reused.
    pub fn block(&mut self, topic: bool) {
        if let Some(last) = self.blocks.last_mut() {
            if last.lines.is_empty() { last.topic = topic; last.expanded = false; return; }
        }
        self.blocks.push(Block { topic, ..Default::default() });
    }

    /// Append text to the current block. A newline ends a line; text without one leaves the line
    /// open for the next write.
    pub fn write(&mut self, text: &str) {
        if self.blocks.is_empty() { self.blocks.push(Block::default()); }
        let block = self.blocks.last_mut().unwrap();
        let text = text.replace('\r', "");
        let (body, closed) = match text.strip_suffix('\n') { Some(b) => (b.to_string(), true), None => (text.clone(), false) };
        for (index, segment) in body.split('\n').enumerate() {
            if index == 0 && block.open { block.lines.last_mut().unwrap().push_str(segment); }
            else { block.lines.push(segment.to_string()); }
        }
        block.open = !closed;
        self.dirty = true;
        let total: usize = self.blocks.iter().map(|b| b.lines.len()).sum();
        if total > MAX_LINES && self.blocks.len() > 1 {
            self.blocks.remove(0);
            self.focus = self.focus.and_then(|f| f.checked_sub(1));
        }
    }

    pub fn topics(&self) -> Vec<usize> { (0..self.blocks.len()).filter(|&i| self.blocks[i].topic && !self.blocks[i].lines.is_empty()).collect() }

    /// Up: the latest topic first, then older ones. Returns whether there is one to focus.
    pub fn focus_prev(&mut self) -> bool {
        let topics = self.topics();
        let next = match self.focus { None => topics.last().copied(), Some(f) => topics.iter().rev().find(|&&t| t < f).copied().or(Some(f)) };
        if next.is_some() { self.focus = next; self.dirty = true; }
        next.is_some()
    }
    /// Down: a newer topic; past the newest, focus leaves the transcript (returns false).
    pub fn focus_next(&mut self) -> bool {
        let topics = self.topics();
        let Some(f) = self.focus else { return false };
        self.dirty = true;
        match topics.iter().find(|&&t| t > f) { Some(&t) => { self.focus = Some(t); true } None => { self.focus = None; false } }
    }
    pub fn set_expanded(&mut self, expanded: bool) {
        if let Some(f) = self.focus { self.blocks[f].expanded = expanded; self.dirty = true; }
    }
    pub fn unfocus(&mut self) { if self.focus.take().is_some() { self.dirty = true; } }
    /// PageUp (`rows` > 0) / PageDown: freezes the view and moves it; clamped when drawn.
    pub fn page(&mut self, rows: isize) { self.freeze = true; self.page_delta += rows; self.dirty = true; }
    /// Start navigating: the view stops following new output.
    pub fn hold(&mut self) { self.nav = true; self.freeze = true; self.dirty = true; }
    /// Back to the chat: unfrozen, at the bottom, nothing focused.
    pub fn sync(&mut self) {
        self.nav = false; self.freeze = false; self.top = None; self.page_delta = 0;
        self.focus = None; self.dirty = true;
    }
    pub fn to_bottom(&mut self) { if self.top.is_some() || self.freeze { self.sync(); } }
    /// Following the bottom (nothing frozen, not paged back): what a mouse selection restores.
    pub fn following(&self) -> bool { self.top.is_none() && !self.freeze && !self.nav }

    /// The screen rows of one block at `width`: folded, or boxed in a heavy white border when focused.
    fn rows_of(&self, index: usize, width: usize) -> Vec<String> {
        let block = &self.blocks[index];
        let focused = self.focus == Some(index);
        let inner = if focused { width.saturating_sub(2).max(1) } else { width.max(1) };
        let mut rows: Vec<String> = block.lines.iter().flat_map(|line| wrap_rows(line, inner)).collect();
        while block.topic && rows.last().is_some_and(|r| visible(r) == 0) { rows.pop(); }
        // Folded: the topic's title row, then its first FOLDED_ROWS rows of content - blank rows
        // skipped, so three rows are three lines of text - then how much is hidden.
        if block.topic && !block.expanded && rows.len() > 1 + FOLDED_ROWS {
            let title = rows[0].clone();
            let body: Vec<String> = rows[1..].iter().filter(|r| visible(r) > 0).cloned().collect();
            if body.len() > FOLDED_ROWS {
                let hidden = body.len() - FOLDED_ROWS;
                rows = std::iter::once(title).chain(body.into_iter().take(FOLDED_ROWS)).collect();
                rows.push(format!("{DIM}\u{2026} +{hidden} lines{}{RESET}", if focused { " (\u{2192} to expand)" } else { "" }));
            }
        }
        if !focused { return rows; }
        // A thin (light) white border around the focused topic.
        let mut out = vec![format!("{FOCUS}\u{250c}{}\u{2510}{RESET}", "\u{2500}".repeat(width.saturating_sub(2)))];
        for row in rows {
            let pad = inner.saturating_sub(visible(&row));
            out.push(format!("{FOCUS}\u{2502}{RESET}{row}{RESET}{}{FOCUS}\u{2502}{RESET}", " ".repeat(pad)));
        }
        out.push(format!("{FOCUS}\u{2514}{}\u{2518}{RESET}", "\u{2500}".repeat(width.saturating_sub(2))));
        out
    }

    /// The rows `1..=height` show: bottom-anchored while following, fixed while frozen, and always
    /// keeping a focused topic on screen.
    pub fn view(&mut self, width: usize, height: usize) -> Vec<String> {
        // Following the bottom with nothing focused (the usual case, and every write of a replay):
        // only the blocks that reach the screen are wrapped, newest first. Wrapping the whole chat
        // on every frame made each write cost the length of the chat - a resumed session of a few
        // thousand rows drew for over a minute.
        if self.focus.is_none() && self.top.is_none() && !self.freeze && self.page_delta == 0 {
            let mut tail: Vec<String> = Vec::new();
            for index in (0..self.blocks.len()).rev() {
                let mut rows = self.rows_of(index, width);
                rows.extend(tail);
                tail = rows;
                if tail.len() >= height { break; }
            }
            let skip = tail.len().saturating_sub(height);
            let mut shown = vec![String::new(); height.saturating_sub(tail.len())];
            shown.extend(tail.into_iter().skip(skip));
            return shown;
        }
        let mut rows = Vec::new();
        let mut focus_range = None;
        for index in 0..self.blocks.len() {
            let start = rows.len();
            rows.extend(self.rows_of(index, width));
            if self.focus == Some(index) { focus_range = Some((start, rows.len())); }
        }
        let (total, h) = (rows.len() as isize, height as isize);
        // The first row to show; negative = that many blank rows above the chat.
        let bottom = total - h;
        if self.freeze && self.top.is_none() { self.top = Some(bottom); }
        let mut start = self.top.map(|t| t.min(bottom.max(t))).unwrap_or(bottom);
        if self.page_delta != 0 {
            let lowest = start.min(bottom.min(0));
            start = (start - self.page_delta as isize).clamp(lowest, bottom.max(lowest));
            self.page_delta = 0;
        }
        if let Some((a, b)) = focus_range {
            // Keep the focused topic on screen (its top first when it is taller than the screen).
            let (a, b) = (a as isize, b as isize);
            if b > start + h { start = (b - h).min(a); }
            if a < start { start = a; }
        }
        if self.top.is_some() {
            // Paged back down to the end outside navigation: follow the bottom again.
            if start >= bottom && !self.nav && focus_range.is_none() { self.top = None; self.freeze = false; start = bottom; }
            else { self.top = Some(start); }
        }
        let mut shown: Vec<String> = (start..start + h)
            .map(|i| if i < 0 || i >= total { String::new() } else { rows[i as usize].clone() }).collect();
        let below = total - (start + h);
        if below > 0 {
            if let Some(last) = shown.last_mut() {
                *last = format!("{DIM}\u{2193} {} more lines (PgDn){RESET}", below + 1);
            }
        }
        shown
    }

    /// The frame that draws the output region (`rows` = its last row).
    pub fn render(&mut self, width: usize, rows: usize) -> String {
        let mut frame = String::new();
        for (offset, row) in self.view(width, rows).iter().enumerate() {
            frame.push_str(&format!("\x1b[{};1H\x1b[2K{row}{RESET}", offset + 1));
        }
        frame
    }
}

/// Columns a row takes: escape sequences take none.
pub fn visible(text: &str) -> usize {
    let mut cols = 0;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            if chars.peek() == Some(&'[') { chars.next(); for c in chars.by_ref() { if ('@'..='~').contains(&c) { break; } } }
            continue;
        }
        cols += cell_width_of(c);
    }
    cols
}

/// Split one line into the rows a `width`-column screen wraps it into. Colour carries over: each
/// continuation row starts with the colour that was active where the previous one was cut.
pub fn wrap_rows(line: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let (mut rows, mut row, mut cols, mut sgr) = (Vec::new(), String::new(), 0usize, String::new());
    let mut chars = line.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\x1b' {
            let mut seq = String::from(ch);
            if chars.peek() == Some(&'[') {
                seq.push(chars.next().unwrap());
                for c in chars.by_ref() { seq.push(c); if ('@'..='~').contains(&c) { break; } }
            }
            if seq.ends_with('m') { if seq == "\x1b[0m" || seq == "\x1b[m" { sgr.clear(); } else { sgr.push_str(&seq); } }
            row.push_str(&seq);
            continue;
        }
        let w = cell_width_of(ch);
        if cols + w > width && cols > 0 {
            rows.push(std::mem::take(&mut row) + RESET);
            row.push_str(&sgr);
            cols = 0;
        }
        row.push(ch);
        cols += w;
    }
    rows.push(row);
    rows
}

/// Keys while the transcript has focus.
#[derive(Debug, PartialEq)]
pub enum NavKey { None, Up, Down, Right, Left, Exit, PageUp, PageDown, Bottom, Other(Vec<u8>) }

#[derive(Default)]
pub struct NavDecoder { escape: Vec<u8> }

impl NavDecoder {
    pub fn feed(&mut self, byte: u8) -> NavKey {
        if !self.escape.is_empty() {
            self.escape.push(byte);
            let seq = self.escape.clone();
            if seq.len() == 2 && byte != b'[' && byte != b'O' { self.escape.clear(); return if byte == 0x1b { NavKey::Exit } else { NavKey::Other(vec![byte]) }; }
            if seq.len() >= 3 && (0x40..=0x7e).contains(&byte) {
                self.escape.clear();
                return match (byte, &seq[2..seq.len() - 1]) {
                    (b'A', _) => NavKey::Up, (b'B', _) => NavKey::Down, (b'C', _) => NavKey::Right, (b'D', _) => NavKey::Left,
                    (b'~', b"5") => NavKey::PageUp, (b'~', b"6") => NavKey::PageDown, (b'~', b"6;5") => NavKey::Bottom,
                    _ => NavKey::None,
                };
            }
            if seq.len() > 16 { self.escape.clear(); }
            return NavKey::None;
        }
        match byte {
            0x1b => { self.escape.push(byte); NavKey::None }
            b'\r' | 3 => NavKey::Exit,
            _ => NavKey::Other(vec![byte]),
        }
    }
    /// A lone Esc (nothing followed it).
    pub fn lone_escape(&mut self) -> bool { let lone = self.escape.as_slice() == b"\x1b"; if lone { self.escape.clear(); } lone }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn following_the_bottom_wraps_only_what_is_on_screen_and_draws_the_same() {
        let mut t = Transcript::default();
        for n in 0..400 {
            t.block(n % 3 == 0);
            t.write(&format!("block {n} {}\nsecond\nthird\nfourth\nfifth\n", "word ".repeat(n % 17)));
        }
        let all: Vec<String> = (0..t.blocks.len()).flat_map(|i| t.rows_of(i, 30)).collect();
        for height in [1, 5, 40] {
            let expected: Vec<String> = all[all.len() - height..].to_vec();
            assert_eq!(t.view(30, height), expected, "height {height}");
        }
        // Shorter than the screen: blank rows above, as before.
        let mut short = Transcript::default();
        short.write("one\ntwo\n");
        assert_eq!(short.view(30, 4), vec!["", "", "one", "two"]);
    }
    #[test]
    fn a_topic_folds_to_three_rows_and_expands() {
        let mut t = Transcript::default();
        t.write("> hello\n\n");
        t.block(true);
        t.write("\u{273b} Thinking\u{2026}\none\ntwo\nthree\nfour\n");
        t.block(false);
        t.write("answer\n");
        let view = t.view(40, 10);
        let text = view.join("\n");
        assert!(text.contains("one") && text.contains("three") && !text.contains("four") && text.contains("+1 lines"),
            "folded: the title and three lines of content: {text}");
        assert!(t.focus_prev(), "Up focuses the latest topic");
        assert!(t.view(40, 10).join("\n").contains("\u{250c}"), "focused: a thin border");
        t.set_expanded(true);
        let open = t.view(40, 12).join("\n");
        assert!(open.contains("four") && open.contains("answer"), "{open}");
        assert!(!t.focus_next() && t.focus.is_none(), "Down past the newest topic leaves the transcript");
    }
    #[test]
    fn the_view_is_bottom_anchored_and_keeps_a_focused_topic_on_screen() {
        let mut t = Transcript::default();
        t.block(true); t.write("old topic\na\nb\n");
        t.block(false);
        for n in 0..30 { t.write(&format!("line {n}\n")); }
        let view = t.view(40, 5);
        assert_eq!(view.last().unwrap(), "line 29");
        t.focus_prev();
        let view = t.view(40, 5).join("\n");
        assert!(view.contains("old topic"), "the focused topic scrolls into view: {view}");
    }
    #[test]
    fn folding_skips_blank_rows() {
        let mut t = Transcript::default();
        t.block(true);
        t.write("title\npara one\n\npara two\n\npara three\n\npara four\n");
        let text = t.view(40, 10).join("\n");
        assert!(text.contains("para three") && !text.contains("para four") && text.contains("+1 lines"), "{text}");
    }
    #[test]
    fn page_up_and_down_scroll_the_view() {
        let mut t = Transcript::default();
        for n in 0..30 { t.write(&format!("line {n}\n")); }
        t.page(9);
        let view = t.view(40, 10);
        assert!(view[0] == "line 11" && view[9].contains("more lines"), "{view:?}");
        t.page(100);
        assert_eq!(t.view(40, 10)[0], "line 0", "clamped at the top");
        t.page(-1000);
        assert_eq!(t.view(40, 10).last().unwrap(), "line 29", "and back at the bottom");
        t.write("line 30\n");
        assert_eq!(t.view(40, 10).last().unwrap(), "line 30", "paged to the end, the view follows again");
    }
    #[test]
    fn a_page_is_a_third_of_the_chat_area() {
        assert_eq!(page_step(30), 10);
        assert_eq!(page_step(31), 10, "rounded down");
        assert_eq!(page_step(2), 1, "never zero on a tiny area");
        assert_eq!(page_step(0), 1);
        // One step on a 10-row area moves the view three rows, not a screen.
        let mut t = Transcript::default();
        for n in 0..30 { t.write(&format!("line {n}\n")); }
        let bottom = t.view(40, 10)[0].clone();
        t.page(page_step(10));
        let up = t.view(40, 10);
        assert_eq!((bottom.as_str(), up[0].as_str()), ("line 20", "line 17"), "{up:?}");
        t.page(-page_step(10));
        assert_eq!(t.view(40, 10)[0], "line 20", "PageDown undoes PageUp");
    }
    #[test]
    fn a_frozen_view_does_not_move_while_output_arrives() {
        let mut t = Transcript::default();
        t.block(true); t.write("topic\na\n");
        t.block(false);
        for n in 0..20 { t.write(&format!("line {n}\n")); }
        t.hold(); t.focus_prev();
        let before = t.view(40, 8);
        for n in 20..40 { t.write(&format!("line {n}\n")); }
        let after = t.view(40, 8);
        assert_eq!(before[..7], after[..7], "what the reader is looking at stays put");
        assert!(after[7].contains("more lines"), "and the new output is counted below: {after:?}");
        t.sync();
        assert_eq!(t.view(40, 8).last().unwrap(), "line 39", "back in the chat it syncs to the bottom");
    }
    #[test]
    fn frozen_while_the_run_appends_and_the_status_row_goes() {
        let mut t = Transcript::default();
        t.block(false); for n in 0..10 { t.write(&format!("banner {n}\n")); }
        t.block(false); t.write("> prompt\n\n");
        t.block(true); t.write("Thinking\na\nb\nc\nd\ne\n");
        t.block(false); t.write("\n");
        let _ = t.view(100, 25);
        t.hold(); t.focus_prev();
        let before = t.view(100, 25);
        let at = |v: &Vec<String>| v.iter().position(|r| r.contains("Thinking")).unwrap();
        let row = at(&before);
        t.block(true); t.write("Bash(x)\ntick 1\ntick 2\ntick 3\nexit 0\n");
        t.block(false); t.write("\nanswer\n\nfooter\n\n");
        let after = t.view(100, 26);
        assert_eq!(at(&after), row, "the focused topic stays on its row: {after:?}");
    }
    #[test]
    fn paging_while_navigating_never_blanks_the_view() {
        let mut t = Transcript::default();
        t.block(false); for n in 0..6 { t.write(&format!("banner {n}\n")); }
        t.block(true); t.write("Thinking\na\nb\n");
        t.block(false); t.write("\n");
        let _ = t.view(100, 25);
        t.hold(); t.focus_prev();
        let _ = t.view(100, 25);
        for n in 0..20 { t.write(&format!("out {n}\n")); }
        let _ = t.view(100, 26);
        t.page(23); let up = t.view(100, 26);
        t.page(-23); let down = t.view(100, 26);
        assert!(up.iter().any(|r| r.contains("Thinking")), "{up:?}");
        assert!(down.iter().any(|r| !r.is_empty()), "PageDown while navigating blanked the view: {down:?}");
    }
    #[test]
    fn nav_page_keys() {
        let mut n = NavDecoder::default();
        let mut last = NavKey::None;
        for b in b"\x1b[5~" { last = n.feed(*b); } assert_eq!(last, NavKey::PageUp);
        for b in b"\x1b[6;5~" { last = n.feed(*b); } assert_eq!(last, NavKey::Bottom);
    }
    #[test]
    fn colour_carries_across_a_wrap() {
        let rows = wrap_rows("\x1b[31mabcdef\x1b[0m", 3);
        assert_eq!(rows.len(), 2);
        assert!(rows[1].starts_with("\x1b[31m"), "{rows:?}");
    }
    #[test]
    fn nav_keys() {
        let mut n = NavDecoder::default();
        for b in b"\x1b[" { assert_eq!(n.feed(*b), NavKey::None); }
        assert_eq!(n.feed(b'A'), NavKey::Up);
        assert_eq!(n.feed(b'x'), NavKey::Other(vec![b'x']));
        n.feed(0x1b); assert!(n.lone_escape());
    }
}
