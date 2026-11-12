//! The chat transcript as the CLI shows it: a list of blocks the view appends to, drawn by the host
//! into the output region. Owning the transcript here (rather than streaming text into the
//! terminal) is what lets a block be folded, focused and expanded while Lua is blocked, and what
//! puts the chat back exactly where it was after the slash menu or a panel closes.
//!
//! A *topic* is a collapsible block - the model's thinking, a tool call - shown at most
//! `FOLDED_ROWS` rows until it is expanded. Ctrl+Up (from the draft) focuses the latest topic; Up and
//! Down move between topics, Right expands, Left folds, Esc goes back to typing.
use crate::scroll::chat::{fit, thumb};
use crate::scroll::settings::Scrollbar;
use crate::terminal_editor::cell_width_of;
use std::collections::HashMap;

pub const FOLDED_ROWS: usize = 3;
/// The copy affordance shown in front of a block that can be copied (#114): one glyph and a space,
/// what pi and Claude Code put before a fenced block's title. A mouse press on it copies the block's
/// content through OSC 52 (the terminal's clipboard), which is the only clipboard that works over
/// ssh and inside a container without a display.
pub const COPY_PREFIX: &str = "\u{29c9} ";
const MAX_LINES: usize = 20_000;
const RESET: &str = "\x1b[0m";
const DIM: &str = "\x1b[38;2;119;119;119m";
const FOCUS: &str = "\x1b[38;2;255;255;255m";
/// The scrollbar's colours, the fullscreen console's own (`scroll::chat`): one bar, one look.
const BAR_TRACK: &str = "\x1b[38;2;80;80;80m";
const BAR_THUMB: &str = "\x1b[38;2;136;136;136m";

#[derive(Default, Clone)]
pub struct Block { pub lines: Vec<String>, open: bool, pub topic: bool, pub expanded: bool,
    /// Lines that can be copied, by line index: `{line: content}`. The content is the block's own
    /// text (a fenced block's body), not the drawn rows - the rows carry the border and the icon.
    pub copies: HashMap<usize, String> }

pub struct Transcript { pub blocks: Vec<Block>, pub focus: Option<usize>, pub dirty: bool,
    /// The scrollbar in the last column (#115): `auto` shows it when the chat is taller than the
    /// region, and it costs a column - the same knob and the same rule as the fullscreen console
    /// (`scroll::settings::Scrollbar`, `scroll::chat`), because two transcripts must not disagree
    /// about what a scrollbar is. `Hidden` is for a caller that measures rows and nothing else.
    pub scrollbar: Scrollbar,
    /// Rows each block wraps to at `count_width`, for the bar's total: a resumed session is
    /// thousands of rows, and a frame that re-wrapped all of them to size a thumb would cost the
    /// frame rate. A write touches one block, and only that entry is dropped.
    counts: Vec<Option<usize>>,
    count_width: usize,
    /// Whether the last view drew the bar (and so wrapped one column narrower).
    bar: bool,
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
    pub nav: bool,
    /// Where the live line sits while a tool call runs: `(block, line)` of the row the host rewrites
    /// in place. `None` = there is no such line. It is never a committed line - see `live`.
    live_row: Option<(usize, usize)>,
    /// Copies waiting for the next `write` (`copyable`): offsets are lines of that write.
    pending_copy: Vec<(usize, String)>,
    /// Where the icon of each copyable line was drawn in the last `view`: screen row -> content.
    /// A mouse press asks this before it asks anything else, so a click on the icon copies and a
    /// click anywhere else starts a selection - one gesture, one meaning.
    copy_rows: HashMap<usize, String> }

impl Default for Transcript {
    fn default() -> Self {
        Transcript { blocks: Vec::new(), focus: None, dirty: false, top: None, freeze: false,
            page_delta: 0, nav: false, live_row: None, pending_copy: Vec::new(),
            copy_rows: HashMap::new(), scrollbar: Scrollbar::Auto, counts: Vec::new(),
            count_width: 0, bar: false }
    }
}

/// One PageUp/PageDown step for a chat that occupies `area` screen rows: a third of it, at least one
/// row. A whole screen jumped past what the reader was following; a third keeps two thirds in view.
pub fn page_step(area: usize) -> isize { (area / 3).max(1) as isize }

impl Transcript {
    /// Start a new block (`topic` = collapsible). An empty current block is reused.
    pub fn block(&mut self, topic: bool) {
        self.clear_live();
        self.pending_copy.clear();
        if let Some(last) = self.blocks.last_mut() {
            if last.lines.is_empty() { last.topic = topic; last.expanded = false; return; }
        }
        self.blocks.push(Block { topic, ..Default::default() });
        self.counts.push(None);
    }

    /// The running tool call's line, **inside that call's own block** (Victor, 2026-11-10: the
    /// session-status-content row below the box belongs to the update notice and its loader, never to
    /// a tool). `Some(text)` writes it where it already is, replacing the text in place - the host's
    /// ticker is the only painter awake while Lua is blocked in `host.exec`, so that is what keeps the
    /// clock and the output tail moving; `None` (or an empty text) takes it away.
    ///
    /// It is not a committed line: the next real `write` or `block` drops it first, so a result can
    /// never land under a progress row that has outlived its call.
    pub fn live(&mut self, text: Option<&str>) {
        if let Some(last) = self.counts.last_mut() { *last = None; }
        let text = text.map(str::trim).filter(|text| !text.is_empty());
        let Some(text) = text else { self.clear_live(); return };
        match self.live_row {
            Some((block, line)) if self.blocks.get(block).is_some_and(|b| line < b.lines.len()) => {
                if self.blocks[block].lines[line] != text {
                    self.blocks[block].lines[line] = text.to_string();
                    self.dirty = true;
                }
            }
            _ => {
                if self.blocks.is_empty() { self.blocks.push(Block::default()); }
                let block = self.blocks.len() - 1;
                self.blocks[block].lines.push(text.to_string());
                self.blocks[block].open = false;
                self.live_row = Some((block, self.blocks[block].lines.len() - 1));
                self.dirty = true;
            }
        }
    }

    /// Mark lines of the NEXT `write` as copyable (#114): `(offset, content)`, where the offset is
    /// the line of that write (0 = its first line). The rows are drawn by `write`, so the marker has
    /// to arrive just before it; a marker that never meets a write is dropped by the next `block`.
    pub fn copyable(&mut self, markers: &[(usize, String)]) {
        self.pending_copy = markers.iter().map(|(at, text)| (*at, text.clone())).collect();
    }

    /// The content a mouse press at `(row, col)` copies: the icon cell of a copyable row, and
    /// nothing else. Rows and columns are the ones the last `view` drew (1-based, screen cells), so
    /// a caller reads its own coordinates without translating anything.
    pub fn copy_at(&self, row: usize, col: usize) -> Option<String> {
        if col > visible(COPY_PREFIX) { return None }
        self.copy_rows.get(&row).cloned()
    }

    /// Take the live line away (its call finished, or real output is about to land under it).
    pub fn clear_live(&mut self) {
        let Some((block, line)) = self.live_row.take() else { return };
        if let Some(count) = self.counts.get_mut(block) { *count = None; }
        if let Some(found) = self.blocks.get_mut(block) { if line < found.lines.len() { found.lines.remove(line); } }
        self.dirty = true;
    }

    /// Replace the current block's first line - a tool call's heading, rewritten once its result lands
    /// so that row's dot can say how the call went. Returns false when there is nothing to rewrite (no
    /// block, an empty one, or a live line that is the only row). It never touches the live line.
    pub fn head(&mut self, text: &str) -> bool {
        if let Some(last) = self.counts.last_mut() { *last = None; }
        let Some(block) = self.blocks.len().checked_sub(1) else { return false };
        let live_here = matches!(self.live_row, Some((at, 0)) if at == block);
        let found = &mut self.blocks[block];
        if live_here || found.lines.is_empty() { return false }
        if found.lines[0] != text {
            found.lines[0] = text.to_string();
            found.copies.remove(&0);
            self.dirty = true;
        }
        true
    }

    /// Append text to the current block. A newline ends a line; text without one leaves the line
    /// open for the next write.
    pub fn write(&mut self, text: &str) {
        self.clear_live();
        let markers = std::mem::take(&mut self.pending_copy);
        if self.blocks.is_empty() { self.blocks.push(Block::default()); }
        let block = self.blocks.last_mut().unwrap();
        let text = text.replace('\r', "");
        let (body, closed) = match text.strip_suffix('\n') { Some(b) => (b.to_string(), true), None => (text.clone(), false) };
        // Where this write's first line lands: an open last line is *continued*, so the write's own
        // line zero is that line - which is what `copyable`'s offsets are counted from.
        let was_open = block.open;
        let first = block.lines.len().saturating_sub(usize::from(was_open));
        let mut produced = 0usize;
        for (index, segment) in body.split('\n').enumerate() {
            if index == 0 && was_open { block.lines.last_mut().unwrap().push_str(segment); }
            else { block.lines.push(segment.to_string()); }
            produced = index + 1;
        }
        // The copy markers of this write, now that its lines have indices of their own.
        for (at, content) in markers {
            if at < produced.max(1) && first + at < block.lines.len() {
                block.copies.insert(first + at, content);
            }
        }
        block.open = !closed;
        self.dirty = true;
        // One block changed, so one cached row count is stale - not the whole chat's.
        if let Some(last) = self.counts.last_mut() { *last = None; }
        let total: usize = self.blocks.iter().map(|b| b.lines.len()).sum();
        if total > MAX_LINES && self.blocks.len() > 1 {
            self.blocks.remove(0);
            if !self.counts.is_empty() { self.counts.remove(0); }
            self.focus = self.focus.and_then(|f| f.checked_sub(1));
        }
    }

    pub fn topics(&self) -> Vec<usize> { (0..self.blocks.len()).filter(|&i| self.blocks[i].topic && !self.blocks[i].lines.is_empty()).collect() }

    /// Up: the latest topic first, then older ones. Returns whether there is one to focus.
    pub fn focus_prev(&mut self) -> bool {
        let topics = self.topics();
        let next = match self.focus { None => topics.last().copied(), Some(f) => topics.iter().rev().find(|&&t| t < f).copied().or(Some(f)) };
        if next.is_some() { self.focus = next; self.counts.clear(); self.dirty = true; }
        next.is_some()
    }
    /// Down: a newer topic; past the newest, focus leaves the transcript (returns false).
    pub fn focus_next(&mut self) -> bool {
        let topics = self.topics();
        let Some(f) = self.focus else { return false };
        self.dirty = true;
        self.counts.clear();
        match topics.iter().find(|&&t| t > f) { Some(&t) => { self.focus = Some(t); true } None => { self.focus = None; false } }
    }
    pub fn set_expanded(&mut self, expanded: bool) {
        if let Some(f) = self.focus {
            self.blocks[f].expanded = expanded;
            if let Some(count) = self.counts.get_mut(f) { *count = None; }
            self.dirty = true;
        }
    }
    pub fn unfocus(&mut self) {
        // Focus decides the width a block wraps at (a focused topic is boxed), so every count moves.
        if self.focus.take().is_some() { self.counts.clear(); self.dirty = true; }
    }
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
    fn rows_of(&self, index: usize, width: usize) -> Vec<String> { self.rows_with_copies(index, width).0 }

    /// The same rows, plus where each copyable line's icon was drawn (`(row offset in this block,
    /// content)`): the index a mouse press turns into a clipboard write (#114).
    fn rows_with_copies(&self, index: usize, width: usize) -> (Vec<String>, Vec<(usize, String)>) {
        let block = &self.blocks[index];
        let focused = self.focus == Some(index);
        let inner = if focused { width.saturating_sub(2).max(1) } else { width.max(1) };
        let mut rows: Vec<String> = Vec::new();
        let mut copies: Vec<(usize, String)> = Vec::new();
        for (line_index, line) in block.lines.iter().enumerate() {
            let content = block.copies.get(&line_index);
            let start = rows.len();
            if content.is_some() {
                // The affordance is part of the row, so the wrap and the click agree about where it
                // ends: the icon takes its columns from the text and the header wraps two columns
                // narrower, which is what a reader sees either way.
                rows.extend(wrap_rows(&format!("{COPY_PREFIX}{line}"), inner));
                copies.push((start, content.expect("checked").clone()));
            } else {
                rows.extend(wrap_rows(line, inner));
            }
        }
        while block.topic && rows.last().is_some_and(|r| visible(r) == 0) { rows.pop(); }
        // Folded: the topic's title row, then its first FOLDED_ROWS rows of content - blank rows
        // skipped, so three rows are three lines of text - then how much is hidden.
        if block.topic && !block.expanded && rows.len() > 1 + FOLDED_ROWS {
            let title = rows[0].clone();
            let kept: Vec<usize> = (1..rows.len()).filter(|&i| visible(&rows[i]) > 0).collect();
            if kept.len() > FOLDED_ROWS {
                let hidden = kept.len() - FOLDED_ROWS;
                let keep = &kept[..FOLDED_ROWS];
                // A copyable line that the fold hides is not drawn, so its icon is not there to be
                // clicked: the marker goes with the row.
                copies.retain(|(at, _)| *at == 0 || keep.contains(at));
                let mut folded: Vec<String> = vec![title];
                for (position, &from) in keep.iter().enumerate() {
                    folded.push(rows[from].clone());
                    for (at, _) in copies.iter_mut() { if *at == from { *at = position + 1; } }
                }
                folded.push(format!("{DIM}\u{2026} +{hidden} lines{}{RESET}", if focused { " (\u{2192} to expand)" } else { "" }));
                rows = folded;
            }
        }
        if !focused { return (rows, copies); }
        // A thin (light) white border around the focused topic: one row above, so every copy moves
        // down by it.
        let mut out = vec![format!("{FOCUS}\u{250c}{}\u{2510}{RESET}", "\u{2500}".repeat(width.saturating_sub(2)))];
        for row in rows {
            let pad = inner.saturating_sub(visible(&row));
            out.push(format!("{FOCUS}\u{2502}{RESET}{row}{RESET}{}{FOCUS}\u{2502}{RESET}", " ".repeat(pad)));
        }
        out.push(format!("{FOCUS}\u{2514}{}\u{2518}{RESET}", "\u{2500}".repeat(width.saturating_sub(2))));
        for (at, _) in copies.iter_mut() { *at += 1; }
        (out, copies)
    }

    /// How many rows the whole chat occupies at `width` - the number the scrollbar's thumb is sized
    /// from. Cached per block: a resumed session is thousands of rows, and wrapping them all on every
    /// frame to size a thumb is the cost this design cannot pay (`scroll::chat` caches the same way).
    fn total_rows(&mut self, width: usize) -> usize {
        if self.count_width != width {
            self.count_width = width;
            self.counts.clear();
        }
        self.counts.resize(self.blocks.len(), None);
        let mut total = 0;
        for index in 0..self.blocks.len() {
            if self.counts[index].is_none() {
                let rows = self.rows_of(index, width).len();
                self.counts[index] = Some(rows);
            }
            total += self.counts[index].unwrap_or(0);
        }
        total
    }

    /// The rows `1..=height` show: bottom-anchored while following, fixed while frozen, and always
    /// keeping a focused topic on screen.
    pub fn view(&mut self, width: usize, height: usize) -> Vec<String> {
        self.copy_rows.clear();
        let (width, height) = (width.max(1), height.max(1));
        // The bar costs a column, and WHICH width the chat wraps at is decided once per change:
        // deciding it afresh each frame would re-wrap the whole chat twice on every keystroke of a
        // long session (`scroll::chat`'s rule, borrowed with its arithmetic).
        let wanted = |bar: Scrollbar, total: usize| match bar {
            Scrollbar::Hidden => false,
            Scrollbar::Auto => total > height,
            Scrollbar::Always => height >= 2,
        } && width > 1;
        let mut text_width = (if self.bar { width - 1 } else { width }).max(1);
        let mut total = self.total_rows(text_width);
        let want = wanted(self.scrollbar, total);
        if want != self.bar {
            self.bar = want;
            text_width = (if want { width - 1 } else { width }).max(1);
            total = self.total_rows(text_width);
        }
        // Following the bottom with nothing focused (the usual case, and every write of a replay):
        // only the blocks that reach the screen are wrapped, newest first. Wrapping the whole chat
        // on every frame made each write cost the length of the chat - a resumed session of a few
        // thousand rows drew for over a minute.
        if self.focus.is_none() && self.top.is_none() && !self.freeze && self.page_delta == 0 {
            let mut tail: Vec<String> = Vec::new();
            // Copies seen so far, as offsets into `tail`: a block is prepended, so its own offsets
            // are already the right ones.
            let mut copies: Vec<(usize, String)> = Vec::new();
            for index in (0..self.blocks.len()).rev() {
                let (mut rows, block_copies) = self.rows_with_copies(index, text_width);
                if !block_copies.is_empty() {
                    let before = tail.len();
                    for (at, content) in block_copies { copies.push((at, content)); if before > 0 { let _ = before; } }
                }
                rows.extend(tail);
                tail = rows;
                if tail.len() >= height { break; }
            }
            let skip = tail.len().saturating_sub(height);
            let blank = height.saturating_sub(tail.len());
            for (at, content) in copies {
                if at >= skip { self.copy_rows.insert(blank + at - skip + 1, content); }
            }
            let mut shown = vec![String::new(); blank];
            shown.extend(tail.into_iter().skip(skip));
            // Following the bottom: the first row shown is the one `height` above the end.
            let first = total.saturating_sub(shown.len());
            Transcript::draw_bar(&mut shown, text_width, self.bar, total, first);
            return shown;
        }
        let mut rows = Vec::new();
        let mut copies: Vec<(usize, String)> = Vec::new();
        let mut focus_range = None;
        for index in 0..self.blocks.len() {
            let start = rows.len();
            let (block_rows, block_copies) = self.rows_with_copies(index, text_width);
            rows.extend(block_rows);
            for (at, content) in block_copies { copies.push((start + at, content)); }
            if self.focus == Some(index) { focus_range = Some((start, rows.len())); }
        }
        let (whole, h) = (rows.len() as isize, height as isize);
        // The first row to show; negative = that many blank rows above the chat.
        let bottom = whole - h;
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
            .map(|i| if i < 0 || i >= whole { String::new() } else { rows[i as usize].clone() }).collect();
        // Where the icons are on the screen: row 1 is the region's first row, as `render` draws it.
        for (at, content) in copies {
            let row = at as isize - start;
            if row >= 0 && row < h { self.copy_rows.insert(row as usize + 1, content); }
        }
        let below = whole - (start + h);
        if below > 0 {
            if let Some(last) = shown.last_mut() {
                *last = format!("{DIM}\u{2193} {} more lines (PgDn){RESET}", below + 1);
            }
        }
        // The bar is sized from the rows this frame actually wrapped: in this path every block is
        // laid out, so that is the whole chat.
        let first = start.max(0) as usize;
        Transcript::draw_bar(&mut shown, text_width, self.bar, rows.len(), first);
        shown
    }

    /// The scrollbar drawn over `rows` (#115): the track in the last column and the thumb where the
    /// reader is. `scroll::chat`'s `thumb` and `fit` are borrowed rather than re-invented - the
    /// fullscreen console's bar and this one are the same bar, and its arithmetic is the part a
    /// second implementation would get subtly wrong.
    fn draw_bar(rows: &mut [String], text_width: usize, bar: bool, total: usize, first: usize) {
        if !bar || rows.is_empty() { return }
        let (top, len) = thumb(rows.len(), total, first);
        for (index, row) in rows.iter_mut().enumerate() {
            let glyph = if index >= top && index < top + len {
                format!("{BAR_THUMB}\u{2588}")
            } else {
                format!("{BAR_TRACK}\u{2502}")
            };
            *row = format!("{}{}{RESET}", fit(row, text_width), glyph);
        }
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
/// Prose arrives unwrapped (markdown.lua `reflow`) and is wrapped here at draw time, so a resize
/// reflows it (29/10): rows break at a space when there is one, and continuation rows hang under
/// the text after the line's indent and marker (`  • `, `1. `, `│ `, `⏺ `), as Lua's layout did.
pub fn wrap_rows(line: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    // The printable characters, each with the escape sequences just before it; `esc` = after the last.
    let (mut cells, mut esc): (Vec<(String, char, usize)>, String) = (Vec::new(), String::new());
    let mut chars = line.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\x1b' {
            esc.push(ch);
            if chars.peek() == Some(&'[') {
                esc.push(chars.next().unwrap());
                for c in chars.by_ref() { esc.push(c); if ('@'..='~').contains(&c) { break; } }
            }
            continue;
        }
        cells.push((std::mem::take(&mut esc), ch, cell_width_of(ch)));
    }
    let total: usize = cells.iter().map(|c| c.2).sum();
    if total <= width { return vec![line.to_string()]; }
    let (hang_at, hang) = hanging_indent(&cells);
    // An indent that leaves no room hangs nothing (and one wider than the screen is not kept whole).
    let hang_at = if hang >= width { 0 } else { hang_at };
    let hang = if width.saturating_sub(hang) < 8 { 0 } else { hang };
    let (mut rows, mut row, mut sgr) = (Vec::new(), String::new(), String::new());
    let (mut i, mut start, mut cols) = (0usize, 0usize, 0usize);
    while i < cells.len() {
        let w = cells[i].2;
        let content = if start == 0 { hang_at } else { start };
        if cols + w > width && i > content {
            // Break at the last space of this row past its indent; none (one long word) = cut here.
            let space = (content + 1..i).rev().find(|&k| cells[k].1 == ' ');
            let (end, next) = match (cells[i].1 == ' ', space) { (true, _) => (i, i), (_, Some(k)) => (k, k), _ => (i, i) };
            for cell in &cells[start..end] { row.push_str(&cell.0); row.push(cell.1); track(&cell.0, &mut sgr); }
            // The spaces the break swallows: their escapes still count (and still close the row).
            let mut next = next;
            while next < cells.len() && cells[next].1 == ' ' { row.push_str(&cells[next].0); track(&cells[next].0, &mut sgr); next += 1; }
            rows.push(std::mem::take(&mut row) + RESET);
            row.push_str(&" ".repeat(hang));
            row.push_str(&sgr);
            start = next; i = next; cols = hang;
            continue;
        }
        cols += w;
        i += 1;
    }
    for cell in &cells[start..] { row.push_str(&cell.0); row.push(cell.1); }
    row.push_str(&esc);
    rows.push(row);
    rows
}

/// Follow the SGR state through `esc` (escape sequences only): a reset clears it, colours add up.
fn track(esc: &str, sgr: &mut String) {
    for seq in esc.split_inclusive(|c: char| c != '\x1b' && c != '[' && ('@'..='~').contains(&c)) {
        let seq = &seq[seq.find('\x1b').unwrap_or(0)..];
        if !seq.ends_with('m') { continue; }
        if seq == "\x1b[0m" || seq == "\x1b[m" { sgr.clear(); } else { sgr.push_str(seq); }
    }
}

/// Where a line's text starts after its indent and list/quote markers: (cell index, columns).
fn hanging_indent(cells: &[(String, char, usize)]) -> (usize, usize) {
    let (mut at, mut cols) = (0usize, 0usize);
    loop {
        while at < cells.len() && cells[at].1 == ' ' { cols += 1; at += 1; }
        let mut end = at;
        while end < cells.len() && cells[end].1.is_ascii_digit() { end += 1; }
        let marker = if end > at { (end < cells.len() && matches!(cells[end].1, '.' | ')')).then_some(end + 1) }
            else { (at < cells.len() && matches!(cells[at].1, '\u{2022}' | '\u{25e6}' | '\u{25aa}' | '\u{2610}' | '\u{2611}' | '\u{2502}' | '\u{23fa}' | '\u{23bf}')).then_some(at + 1) };
        match marker {
            Some(m) if m < cells.len() && cells[m].1 == ' ' => { cols += cells[at..m].iter().map(|c| c.2).sum::<usize>(); at = m; }
            _ => return (at, cols),
        }
    }
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
    /// A transcript with the scrollbar off: the tests that read rows for their TEXT (a page step, a
    /// fold, the bottom anchor) are not about the bar, and the bar's own tests set it. What the bar
    /// adds to a row is one column at the end (`view`), so a test that compared whole rows would
    /// otherwise be asserting the bar's width in every one of them.
    fn plain(mut t: Transcript) -> Transcript { t.scrollbar = Scrollbar::Hidden; t }
    #[test]
    fn following_the_bottom_wraps_only_what_is_on_screen_and_draws_the_same() {
        let mut t = plain(Transcript::default());
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
    /// #121 (operator, 11/11 ~11:45): a code-mode call shows three rows of its script while it is
    /// collapsed, and the whole of it once the reader selects and expands it. The view writes what
    /// `cli_view.code_block` gives it - the heading, three rows of the script, then the result - and
    /// the fold here is what turns that into "three rows, then how much is behind them".
    // ---- #115: the transcript has a scrollbar, and its position follows the reader ----------------
    // The operator, 11/11 ~11:25: the chat has no scrollbar; pi has one. `scroll::chat` already had
    // the bar for the fullscreen console - the same thumb arithmetic, the same `auto`/`always`/
    // `hidden` knob - so this borrows it instead of inventing a second one, and the two transcripts
    // now answer the same question the same way.
    fn thumb_rows(view: &[String]) -> Vec<usize> {
        (0..view.len()).filter(|&at| view[at].ends_with("\u{2588}\u{1b}[0m")).collect()
    }
    fn bar_rows(view: &[String]) -> usize {
        view.iter().filter(|row| row.ends_with("\u{2588}\u{1b}[0m") || row.ends_with("\u{2502}\u{1b}[0m")).count()
    }
    #[test]
    fn a_long_chat_draws_a_scrollbar_and_its_position_follows_the_reader() {
        let mut t = Transcript::default();
        for n in 0..200 { t.write(&format!("line {n}\n")); }
        let bottom = t.view(40, 10);
        assert_eq!(bar_rows(&bottom), 10, "every row of the region carries a bar cell: {bottom:?}");
        assert!(bottom.iter().all(|row| visible(row) == 40), "the bar takes the last column, never more");
        let at_bottom = thumb_rows(&bottom);
        assert!(!at_bottom.is_empty() && *at_bottom.last().unwrap() == 9,
            "following the newest output, the thumb is at the bottom of the track: {at_bottom:?}");
        assert!(at_bottom.len() < 10, "a fifth of a long chat is a thumb, not the whole track: {at_bottom:?}");
        // Paged up: the thumb moves up the track, and it moves with the text rather than jumping.
        t.page(50);
        let up = t.view(40, 10);
        let higher = thumb_rows(&up);
        assert!(higher.first().copied().unwrap_or(9) < at_bottom.first().copied().unwrap_or(0),
            "paged back, the thumb is higher: {higher:?} was {at_bottom:?}");
        assert_eq!(bar_rows(&up), 10, "and the track is still drawn");
        // The very top: the thumb starts at row one, and the first row is the oldest line.
        t.page(10_000);
        let top = t.view(40, 10);
        assert_eq!(top.first().map(|row| thumb_rows(std::slice::from_ref(row)).len()), Some(1),
            "at the top the thumb's first row is the track's first row: {top:?}");
        // Back to the bottom: following again, thumb at the end again.
        t.page(-10_000);
        assert_eq!(thumb_rows(&t.view(40, 10)), at_bottom, "PageDown all the way home returns it");
    }
    #[test]
    fn a_chat_that_fits_its_region_has_no_bar_unless_it_is_asked_for() {
        let mut t = Transcript::default();
        t.write("one\ntwo\nthree\n");
        let auto = t.view(40, 10);
        assert_eq!(bar_rows(&auto), 0, "auto: a chat shorter than the region has no bar: {auto:?}");
        assert!(auto.iter().all(|row| visible(row) <= 40), "and keeps all 40 columns for text");
        // `always` draws the track even when everything fits: the knob's other end, and what the
        // fullscreen console does with the same setting.
        t.scrollbar = Scrollbar::Always;
        let always = t.view(40, 10);
        assert_eq!(bar_rows(&always), 10, "always: the track is there: {always:?}");
        assert_eq!(thumb_rows(&always).len(), 10, "and a chat that fits is a thumb the whole way");
        t.scrollbar = Scrollbar::Hidden;
        assert_eq!(bar_rows(&t.view(40, 10)), 0, "hidden: nothing, whatever the length");
    }
    // ---- a fenced block can be copied from the transcript (#114) -------------------------------
    // The operator's ask (11/11 ~11:25): a fenced block in the CLI transcript gets a copy icon in
    // front of its title, and clicking it puts the block's content on the clipboard. pi does this;
    // the mouse reports were already here for selection (`wa_term::selection`), so the icon is a
    // cell a click can be resolved against, and the copy itself is OSC 52 - the clipboard that
    // works over ssh and in a container with no display.
    fn fenced(t: &mut Transcript) {
        t.box_block("```lua\nprint('hi')\nreturn 1\n```");
    }
    trait Fence {
        fn box_block(&mut self, body: &str);
    }
    impl Fence for Transcript {
        /// The shape `lua/core/markdown.lua` renders for a fence (a card with its language on the
        /// border) and the marker `lua/core/cli_view.lua` sends for it: the title row, the body.
        fn box_block(&mut self, body: &str) {
            let lines: Vec<&str> = body.lines().collect();
            let language = lines[0].trim_start_matches('`');
            let code = lines[1..lines.len() - 1].join("\n");
            self.copyable(&[(1, code.to_string())]);
            self.write(&format!("intro\n\u{256d}\u{2500} {language}\n\u{2502} print('hi')\n\u{2502} return 1\n\u{2570}\u{2500}\n"));
        }
    }
    #[test]
    fn a_copy_icon_is_drawn_before_the_block_it_copies_and_a_click_on_it_finds_the_content() {
        let mut t = Transcript::default();
        fenced(&mut t);
        let view = t.view(60, 10);
        let header = view.iter().find(|row| row.contains("\u{256d}")).expect("the fence header is drawn").clone();
        assert!(header.contains(COPY_PREFIX.trim_end()), "the icon is before the title: {header:?}");
        assert!(!view.iter().any(|row| row.contains("\u{2502} print") && row.contains(COPY_PREFIX.trim_end())),
            "and only the title carries it, not the body rows: {view:?}");
        let row = view.iter().position(|row| row.contains(COPY_PREFIX.trim_end())).unwrap() + 1;
        assert_eq!(t.copy_at(row, 1).as_deref(), Some("print('hi')\nreturn 1"),
            "a click on the icon row, in its first cells, copies the block's content");
        assert_eq!(t.copy_at(row, visible(COPY_PREFIX) + 1), None,
            "past the icon it is text: a press there starts a selection");
        assert_eq!(t.copy_at(row + 1, 1), None, "and the body rows are not a copy target");
        assert_eq!(t.copy_at(row - 1, 1), None, "nor is the prose above it");
        // The clipboard write itself: OSC 52, the same encoder the selection uses.
        assert!(crate::selection::osc52("print('hi')\nreturn 1").starts_with("\x1b]52;c;"));
    }
    #[test]
    fn the_icon_follows_its_row_when_the_chat_scrolls_and_a_folded_copy_is_not_clickable() {
        let mut t = Transcript::default();
        for n in 0..20 { t.write(&format!("line {n}\n")); }
        fenced(&mut t);
        let bottom = t.view(60, 10);
        let row = bottom.iter().position(|row| row.contains(COPY_PREFIX.trim_end())).unwrap() + 1;
        assert_eq!(t.copy_at(row, 1).as_deref(), Some("print('hi')\nreturn 1"), "following: the icon's row");
        // Scrolled up past it: the icon is below the view, so nothing on the screen copies anything.
        t.page(4);
        let up = t.view(60, 10);
        assert!(!up.iter().any(|row| row.contains(COPY_PREFIX.trim_end())),
            "scrolled up, the fence is below the view: {up:?}");
        assert_eq!(t.copy_at(row, 1), None, "and the row it was on copies nothing");
        for at in 1..=10 { assert_eq!(t.copy_at(at, 1), None, "nothing else on the screen copies"); }
        // Back at the bottom the icon is where it was: the mapping is the drawn frame's, not a cache
        // of what once was drawn.
        t.page(-4);
        let back = t.view(60, 10);
        assert_eq!(back.iter().position(|row| row.contains(COPY_PREFIX.trim_end())).map(|at| at + 1), Some(row));
        assert_eq!(t.copy_at(row, 1).as_deref(), Some("print('hi')\nreturn 1"));
        // A copy whose rows the fold hides is not drawn, so there is nothing to click until the
        // topic is expanded - and then the icon is there, on the row it belongs to.
        let mut folded = Transcript::default();
        folded.block(true);
        folded.write("\u{23fa} Bash(cat)\none\ntwo\nthree\n");
        folded.copyable(&[(0, "print('hi')".to_string())]);
        folded.write("\u{256d}\u{2500} lua\n\u{2502} print('hi')\n\u{2570}\u{2500}\n");
        let hidden = folded.view(60, 12);
        assert!(!hidden.iter().any(|row| row.contains(COPY_PREFIX.trim_end())),
            "the fold keeps the first three rows, and the fence is the fourth: {hidden:?}");
        assert_eq!(folded.copy_at(2, 1), None, "so a click where it would have been copies nothing");
        assert!(folded.focus_prev(), "the call is a topic");
        folded.set_expanded(true);
        let open = folded.view(60, 20);
        assert!(open.iter().any(|row| row.contains(COPY_PREFIX.trim_end())),
            "expanded, the copy is drawn: {open:?}");
        let row = open.iter().position(|row| row.contains(COPY_PREFIX.trim_end())).unwrap() + 1;
        assert_eq!(folded.copy_at(row, 1).as_deref(), Some("print('hi')"));
    }
    #[test]
    fn a_code_mode_call_folds_to_three_rows_of_its_script_and_expands_to_all_of_it() {
        let mut t = Transcript::default();
        t.block(true);
        t.write("\u{23fa} Codemode(const files = await tools.ls({path: 'lua/core'});)\n");
        t.write("  const files = await tools.ls({path: 'lua/core'});\n");
        t.write("  const hits = files.filter(f => f.endsWith('.lua'));\n");
        t.write("  await tools.read({path: 'lua/core/chat.lua'});\n");
        t.write("\u{23bf} {\"count\":2}\nexit 0 \u{b7} 812ms\n");
        let folded = t.view(100, 10).join("\n");
        assert!(folded.contains("tools.ls") && folded.contains("endsWith") && folded.contains("chat.lua"),
            "the three script rows are what a collapsed call shows: {folded}");
        assert!(!folded.contains("count") && folded.contains("+2 lines"),
            "the rest is counted, not lost: {folded}");
        assert!(t.focus_prev(), "the call is a topic: Ctrl+Up selects it");
        t.set_expanded(true);
        let open = t.view(100, 14).join("\n");
        assert!(open.contains("const files") && open.contains("endsWith")
            && open.contains("chat.lua") && open.contains("\"count\":2"),
            "expanded: the whole script and the value the model received: {open}");
        assert!(!open.contains("+2 lines"), "and nothing left hidden: {open}");
    }
    #[test]
    fn the_view_is_bottom_anchored_and_keeps_a_focused_topic_on_screen() {
        let mut t = plain(Transcript::default());
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
        let mut t = plain(Transcript::default());
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
        let mut t = plain(Transcript::default());
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
        let mut t = plain(Transcript::default());
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
    fn widening_reflows_a_wrapped_paragraph_to_fewer_rows() {
        // One logical line (markdown.lua `reflow`), drawn at 30 then at 80 columns (29/10).
        let mut t = Transcript::default();
        let para = "The quick brown fox jumps over the lazy dog and keeps running across the field";
        t.write(&format!("{para}\n"));
        let narrow: Vec<String> = t.view(30, 6).iter().map(|r| crate::selection::plain(r)).filter(|r| !r.is_empty()).collect();
        assert!(narrow.len() == 3 && narrow.iter().all(|r| visible(r) <= 30), "{narrow:?}");
        assert!(narrow.iter().all(|r| !r.starts_with(' ') && !r.ends_with(' ')), "breaks at spaces, none left over: {narrow:?}");
        assert_eq!(narrow.join(" "), para, "no word cut");
        let wide: Vec<String> = t.view(80, 6).into_iter().filter(|r| !r.is_empty()).collect();
        assert_eq!(wide, vec![para.to_string()]);
    }
    #[test]
    fn narrowing_rewraps_a_list_item_with_a_hanging_indent() {
        let item = "  \x1b[36m\u{2022} \x1b[0malpha beta gamma delta epsilon zeta eta theta";
        let rows = wrap_rows(item, 20);
        let plain: Vec<String> = rows.iter().map(|r| crate::selection::plain(r)).collect();
        assert_eq!(plain, vec!["  \u{2022} alpha beta gamma", "    delta epsilon", "    zeta eta theta"], "{rows:?}");
        // Numbered, quoted and answered lines hang under their text too; a long word is still cut.
        let second = |line: &str| crate::selection::plain(&wrap_rows(line, 16)[1]);
        assert_eq!(second("12. one two three four five"), "    three four");
        assert_eq!(second("\u{2502} quoted words wrap under the bar"), "  wrap under the");
        assert_eq!(second("\u{23fa} the answer wraps under its dot"), "  wraps under");
        assert_eq!(wrap_rows("abcdefghij", 4), vec![format!("abcd{RESET}"), format!("efgh{RESET}"), "ij".to_string()]);
    }
    // ---- the live line a running tool call owns (docs/TOOL-PROGRESS.md) ----------------------
    // Victor, 2026-11-10: a call's progress is a row in that call's OWN block, under its heading,
    // rewritten while the call runs - not a line on the session-status-content row below the box.
    #[test]
    fn a_live_line_sits_in_the_call_block_and_is_replaced_in_place() {
        let mut t = Transcript::default();
        t.block(true);
        t.write("\u{23fa} Bash(test-remote-call-shape)\n");
        t.live(Some("\u{27f3} bash \u{b7} 43s \u{b7} remote call shape ok"));
        assert_eq!(t.blocks.len(), 1, "one block: the call's own");
        assert_eq!(t.blocks[0].lines.len(), 2, "heading, then the live row");
        assert!(t.blocks[0].lines[1].contains("43s"));
        t.live(Some("\u{27f3} bash \u{b7} 44s \u{b7} remote call shape ok"));
        assert_eq!(t.blocks[0].lines.len(), 2, "an update rewrites that row, never adds one");
        assert!(t.blocks[0].lines[1].contains("44s"));
        // The result lands under the same heading: the live row is gone, the heading can be
        // rewritten in place (its dot says how the call went), and nothing is duplicated.
        assert!(t.head("\u{23fa} Bash(test-remote-call-shape)"), "the heading is there to rewrite");
        t.write("\u{23fa} ok \u{b7} 43s\nremote call shape ok (59 checks, 0 skipped)\n");
        assert_eq!(t.blocks[0].lines.len(), 3, "heading, the result's lead and its output: {:#?}", t.blocks[0].lines);
        assert!(!t.blocks[0].lines.iter().any(|line| line.contains("\u{27f3}")), "no clock row left behind");
        t.live(None);
        assert_eq!(t.blocks[0].lines.len(), 3, "and nothing is removed when there is no live row");
    }
    #[test]
    fn the_next_real_write_takes_the_live_line_away() {
        let mut t = Transcript::default();
        t.block(true);
        t.write("heading\n");
        t.live(Some("progress"));
        t.write("answer\n");
        assert_eq!(t.blocks[0].lines, vec!["heading".to_string(), "answer".to_string()],
            "a result never lands under a progress row that outlived its call");
        // A new block does the same: the live row belongs to the block it was opened in.
        t.live(Some("progress for the next call"));
        t.block(true);
        assert_eq!(t.blocks.len(), 2);
        assert_eq!(t.blocks[0].lines, vec!["heading".to_string(), "answer".to_string()]);
        assert!(t.blocks[1].lines.is_empty(), "and it is not carried into the next block");
        // `head` refuses to rewrite a row that is the live one, and an empty block has none.
        assert!(!t.head("x"), "nothing to rewrite in an empty block");
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
