//! The chat as the fullscreen console draws it: blocks that fold, a scroll position that is the
//! reader's and not the writer's, the new-lines marker and the scrollbar.
//!
//! `crate::transcript` is the inline chat: it owns a scroll *region* inside the terminal's own
//! screen, and its position is a row inside that region. This is the other half of the same idea.
//! The whole screen belongs to this program (the alternate screen, `screen.rs`), so the viewport can
//! be any height and a scrolled-up reader keeps a view that nothing scrolls under them: output lands
//! below, `unseen` counts it, and one row says how much is down there.
//!
//! The position is kept as *rows above the bottom*, not as a row on the screen, and a write while
//! scrolled up adds the rows it appended to it. That is what makes the two halves of the promise
//! true at once: the reader's first row keeps showing the same text, and the distance to the newest
//! output is what the marker measures. Following (`scrolled == 0`) is the default and the only state
//! that moves on its own.
//!
//! Blocks are wrapped once and cached (`rows`), because a session's transcript is thousands of rows
//! and re-wrapping all of it on every keystroke is the one thing this design cannot afford. A block
//! is re-wrapped when it changes, when the width changes, or when a fold moves - nothing else.
use crate::scroll::settings::Scrollbar;
use crate::transcript::{visible, wrap_rows};

/// How many rows a collapsed tool block keeps: its summary row (the tool's own line) and two rows of
/// what it did. `… +N lines` follows when there is more.
pub const COLLAPSED_TOOL_ROWS: usize = 3;
/// A collapsed thinking block keeps its one summary row: thinking is the model's work, and a reader
/// who wants it asks for it.
pub const COLLAPSED_THINKING_ROWS: usize = 1;
/// The same ceiling the inline transcript keeps, so a long run cannot grow the cache without end.
const MAX_LINES: usize = 20_000;

const DIM: &str = "\x1b[38;2;119;119;119m";
/// The marker is an event, not a state: it gets the console's accent, so it is seen.
const ACCENT: &str = "\x1b[38;2;215;119;87m";
const BAR_TRACK: &str = "\x1b[38;2;80;80;80m";
const BAR_THUMB: &str = "\x1b[38;2;136;136;136m";
const RESET: &str = "\x1b[0m";

/// What a block is. Prose is what the reader came for and never folds; thinking and tool output are
/// the agent's work, and they are the two things Ctrl+T and Ctrl+O fold.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind { Prose, Thinking, Tool }

struct Block { kind: Kind, lines: Vec<String>, open: bool, rows: Vec<String>, stale: bool }

impl Default for Block {
    fn default() -> Self { Block { kind: Kind::Prose, lines: Vec::new(), open: false, rows: Vec::new(), stale: true } }
}

pub struct Chat {
    blocks: Vec<Block>,
    tools_collapsed: bool,
    thinking_collapsed: bool,
    collapse: (bool, bool),
    width: usize,
    height: usize,
    /// Rows above the bottom. 0 = following the newest output.
    scrolled: usize,
    /// Rows that arrived while scrolled up: what the marker counts.
    unseen: usize,
    total: usize,
    lines_total: usize,
    /// Whether the last view drew the scrollbar (it takes a column from the text).
    bar: bool,
    /// Blocks wrapped so far: a test asserts that drawing an unchanged screen wraps nothing.
    wraps: usize,
}

impl Default for Chat {
    /// Collapsed is the default for both: a transcript that opens with a screen of tool output and
    /// thinking has buried the answer it is for.
    fn default() -> Self {
        Chat { blocks: Vec::new(), tools_collapsed: true, thinking_collapsed: true, collapse: (true, true),
            width: 0, height: 0, scrolled: 0, unseen: 0, total: 0, lines_total: 0, bar: false, wraps: 0 }
    }
}

impl Chat {
    /// Start a new block. An empty current block is reused, the way the inline transcript does it.
    pub fn block(&mut self, kind: Kind) {
        if let Some(last) = self.blocks.last_mut() {
            if last.lines.is_empty() && !last.open { last.kind = kind; last.stale = true; return; }
        }
        self.blocks.push(Block { kind, ..Default::default() });
    }

    /// Append text to the current block; a newline ends a line, text without one leaves the line open
    /// for the next write. Returns the rows the viewport gained, which is what a scrolled-up reader's
    /// position is moved by.
    pub fn write(&mut self, text: &str) -> usize {
        if self.blocks.is_empty() { self.blocks.push(Block::default()); }
        let before = if self.width > 0 && self.scrolled > 0 { self.refresh(self.width); self.total } else { 0 };
        let open = self.blocks.last().map(|block| block.open).unwrap_or(false);
        let mut pushed = 0usize;
        {
            let block = self.blocks.last_mut().expect("a block was just made");
            let text = text.replace('\r', "");
            let (body, ends) = match text.strip_suffix('\n') { Some(body) => (body.to_string(), true), None => (text.clone(), false) };
            for (index, segment) in body.split('\n').enumerate() {
                if index == 0 && open { block.lines.last_mut().unwrap().push_str(segment); }
                else { block.lines.push(segment.to_string()); pushed += 1; }
            }
            block.open = !ends;
            block.stale = true;
        }
        self.lines_total += pushed;
        self.trim();
        if self.width == 0 || self.scrolled == 0 { return 0; }
        self.refresh(self.width);
        let added = self.total.saturating_sub(before);
        self.scrolled += added;
        self.unseen += added;
        added
    }

    /// The oldest block goes when the chat is longer than the inline transcript's ceiling.
    fn trim(&mut self) {
        while self.lines_total > MAX_LINES && self.blocks.len() > 1 {
            let gone = self.blocks.remove(0);
            self.lines_total -= gone.lines.len();
        }
    }

    /// Collapse or expand tool output (Ctrl+O). Returns whether tools are collapsed now.
    pub fn toggle_tools(&mut self) -> bool { self.tools_collapsed = !self.tools_collapsed; self.tools_collapsed }
    /// Collapse or expand thinking (Ctrl+T).
    pub fn toggle_thinking(&mut self) -> bool { self.thinking_collapsed = !self.thinking_collapsed; self.thinking_collapsed }
    pub fn tools_collapsed(&self) -> bool { self.tools_collapsed }
    pub fn thinking_collapsed(&self) -> bool { self.thinking_collapsed }

    /// Move the view by `rows` rows: positive is up (toward older output).
    pub fn scroll(&mut self, rows: isize) {
        let max = self.total.saturating_sub(self.height);
        self.scrolled = if rows >= 0 {
            (self.scrolled + rows as usize).min(max)
        } else {
            self.scrolled.saturating_sub(rows.unsigned_abs())
        };
        if self.scrolled == 0 { self.unseen = 0; }
    }

    /// One page: a screen less one row, so the reader keeps a row of what they had for orientation.
    pub fn page_rows(&self) -> usize { self.height.saturating_sub(1).max(1) }
    pub fn page(&mut self, up: bool) { let rows = self.page_rows() as isize; self.scroll(if up { rows } else { -rows }); }
    pub fn half_page(&mut self, up: bool) { let rows = (self.page_rows() / 2).max(1) as isize; self.scroll(if up { rows } else { -rows }); }
    pub fn line(&mut self, up: bool) { self.scroll(if up { 1 } else { -1 }); }

    /// Ctrl+Home: the oldest row.
    pub fn to_top(&mut self) { self.scrolled = self.total.saturating_sub(self.height); }
    /// Ctrl+End: the newest row, and follow it again.
    pub fn to_bottom(&mut self) { self.scrolled = 0; self.unseen = 0; }

    pub fn following(&self) -> bool { self.scrolled == 0 }
    pub fn scrolled(&self) -> usize { self.scrolled }
    pub fn unseen(&self) -> usize { self.unseen }
    pub fn total_rows(&self) -> usize { self.total }
    /// How many blocks have been wrapped so far: a test's evidence that a frame was cheap.
    pub fn wraps(&self) -> usize { self.wraps }
    /// The viewport height of the last draw: what a page, a half page and the wheel are measured in.
    pub fn height(&self) -> usize { self.height }

    /// `↓ N new lines` while the reader is scrolled up and output has arrived below them.
    pub fn marker(&self) -> Option<String> {
        if self.scrolled == 0 || self.unseen == 0 { return None; }
        let lines = if self.unseen == 1 { "new line" } else { "new lines" };
        Some(format!("\u{2193} {} {lines}", self.unseen))
    }

    /// Re-wrap the blocks that changed, at this width and with these folds.
    fn refresh(&mut self, width: usize) {
        let width = width.max(1);
        let collapse = (self.tools_collapsed, self.thinking_collapsed);
        if width != self.width { self.width = width; for block in &mut self.blocks { block.stale = true; } }
        if collapse != self.collapse { self.collapse = collapse; for block in &mut self.blocks { block.stale = true; } }
        if !self.blocks.iter().any(|block| block.stale) { return; }
        let mut total = 0;
        for block in &mut self.blocks {
            if block.stale {
                block.rows = wrap_block(block, width, fold_rows(block.kind, collapse.0, collapse.1));
                block.stale = false;
                self.wraps += 1;
            }
            total += block.rows.len();
        }
        self.total = total;
    }

    /// The rows `height` tall, `width` wide: bottom-anchored while following, moved by the reader's
    /// position otherwise, with the scrollbar in the last column when it is shown and the marker over
    /// the last row when there is something below it.
    ///
    /// The bar costs a column, so the text is wrapped one column narrower - and that decision is kept
    /// in `bar` between frames. Deciding it afresh each frame would re-wrap the whole chat twice on
    /// every keystroke of a long session, which is the one cost this design cannot pay; it only
    /// re-wraps when the decision actually changes.
    pub fn view(&mut self, width: usize, height: usize, scrollbar: Scrollbar) -> Vec<String> {
        let (width, height) = (width.max(1), height.max(1));
        self.height = height;
        let wanted = |total: usize| match scrollbar {
            Scrollbar::Hidden => false,
            Scrollbar::Auto => total > height,
            Scrollbar::Always => height >= 2,
        } && width > 1;
        let mut text_width = if self.bar { width - 1 } else { width };
        self.refresh(text_width);
        // The decision is re-made from the current row count, and a flip re-wraps once (at the other
        // width) and then holds: narrower text cannot overflow less, so it cannot flip back.
        let want = wanted(self.total);
        if want != self.bar {
            self.bar = want;
            text_width = if want { width - 1 } else { width };
            self.refresh(text_width);
        }
        let bar = self.bar && width > 1;
        let max = self.total.saturating_sub(height);
        if self.scrolled > max { self.scrolled = max; }
        if self.scrolled == 0 { self.unseen = 0; }
        let pad = height.saturating_sub(self.total);
        let shown = height - pad;
        let first = self.total.saturating_sub(shown + self.scrolled);
        let mut rows: Vec<String> = (0..height).map(|index| {
            if index < pad { String::new() } else { self.row_at(first + index - pad) }
        }).collect();
        if let Some(marker) = self.marker() {
            if let Some(last) = rows.last_mut() { *last = fit(&format!("{ACCENT}{marker}{RESET}"), text_width); }
        }
        if bar {
            let (top, len) = thumb(height, self.total, first);
            for (index, row) in rows.iter_mut().enumerate() {
                let glyph = if index >= top && index < top + len { format!("{BAR_THUMB}\u{2588}") } else { format!("{BAR_TRACK}\u{2502}") };
                let row_width = visible(row);
                *row = format!("{row}{}{glyph}{RESET}", " ".repeat(text_width.saturating_sub(row_width)));
            }
        }
        rows
    }

    /// Row `index` of the whole chat, escape sequences and all.
    fn row_at(&self, index: usize) -> String {
        let mut at = index;
        for block in &self.blocks {
            if at < block.rows.len() { return block.rows[at].clone(); }
            at -= block.rows.len();
        }
        String::new()
    }
}

/// The fold a block gets: `Some(preview rows)` when it is collapsed, `None` when it is drawn whole.
fn fold_rows(kind: Kind, tools_collapsed: bool, thinking_collapsed: bool) -> Option<usize> {
    match kind {
        Kind::Prose => None,
        Kind::Tool => tools_collapsed.then_some(COLLAPSED_TOOL_ROWS),
        Kind::Thinking => thinking_collapsed.then_some(COLLAPSED_THINKING_ROWS),
    }
}

/// A block's wrapped rows, folded to `fold` rows plus a count of what is hidden. Blank rows at the
/// end are dropped first, so a folded block spends its rows on text: three rows are three lines.
fn wrap_block(block: &Block, width: usize, fold: Option<usize>) -> Vec<String> {
    let mut rows: Vec<String> = block.lines.iter().flat_map(|line| wrap_rows(line, width)).collect();
    let Some(preview) = fold else { return rows };
    while rows.last().is_some_and(|row| visible(row) == 0) { rows.pop(); }
    if rows.len() <= preview { return rows; }
    let hidden = rows.len() - preview;
    let mut out: Vec<String> = rows.into_iter().take(preview).collect();
    out.push(format!("{DIM}\u{2026} +{hidden} lines{RESET}"));
    out
}

/// A row cut or padded to exactly `width` cells - what a row must be for the scrollbar and the marker
/// to land in the last column. Escape sequences take no cells and are kept.
pub(crate) fn fit(text: &str, width: usize) -> String {
    let mut out = String::new();
    let mut cells = 0usize;
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\x1b' {
            out.push(ch);
            if chars.peek() == Some(&'[') { out.push(chars.next().unwrap()); for c in chars.by_ref() { out.push(c); if ('@'..='~').contains(&c) { break; } } }
            continue;
        }
        let cell = crate::terminal_editor::cell_width_of(ch);
        if cells + cell > width { break; }
        out.push(ch);
        cells += cell;
    }
    out.push_str(&" ".repeat(width.saturating_sub(cells)));
    out
}

/// The scrollbar's thumb for a track of `track` rows over `total` rows whose first visible row is
/// `first`: (first row of the thumb, how many rows it is). At least one row, never off the track.
pub fn thumb(track: usize, total: usize, first: usize) -> (usize, usize) {
    if track == 0 { return (0, 0); }
    let thumb = ((track * track) / total.max(1)).clamp(1, track);
    let max_first = total.saturating_sub(track);
    let top = (first * (track - thumb) + max_first / 2).checked_div(max_first).unwrap_or(0);
    (top.min(track - thumb), thumb)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::selection::plain;
    const BAR: char = '│';

    fn chat_fn(lines: usize) -> Chat {
        let mut chat = Chat::default();
        for n in 0..lines { chat.write(&format!("line {n}\n")); }
        chat
    }

    fn text(rows: &[String]) -> Vec<String> {
        rows.iter().map(|row| plain(row).trim_end().to_string()).collect()
    }

    #[test]
    fn a_scrolled_view_does_not_move_while_output_arrives_and_the_marker_counts_it() {
        let mut chat = chat_fn(60);
        let bottom = text(&chat.view(40, 10, Scrollbar::Hidden));
        assert_eq!(bottom.last().unwrap(), "line 59", "following the newest");
        chat.page(true);
        let up = text(&chat.view(40, 10, Scrollbar::Hidden));
        assert_eq!(up.first().unwrap(), "line 41", "a page is the screen less one row");
        assert_eq!(up.last().unwrap(), "line 50");
        chat.write("line 60\nline 61\n");
        let after = text(&chat.view(40, 10, Scrollbar::Hidden));
        assert_eq!(&after[..9], &up[..9], "the reader's rows stay put: {after:?}");
        assert_eq!(after.last().unwrap(), "\u{2193} 2 new lines", "and the arrival is counted");
        chat.to_bottom();
        assert!(chat.following() && chat.unseen() == 0);
        assert_eq!(text(&chat.view(40, 10, Scrollbar::Hidden)).last().unwrap(), "line 61");
    }

    #[test]
    fn the_ends_and_the_half_page_and_the_line_steps() {
        let mut chat = chat_fn(100);
        chat.view(40, 10, Scrollbar::Hidden);
        chat.to_top();
        let top = text(&chat.view(40, 10, Scrollbar::Hidden));
        assert_eq!(top.first().unwrap(), "line 0");
        chat.to_bottom();
        chat.line(true);
        chat.line(true);
        assert_eq!(chat.scrolled(), 2, "two lines up");
        chat.half_page(true);
        assert_eq!(chat.scrolled(), 6, "then half of nine rows");
        chat.half_page(false);
        assert_eq!(chat.scrolled(), 2);
        chat.page(true);
        chat.page(true);
        let up = chat.view(40, 10, Scrollbar::Hidden);
        assert_eq!(text(&up).first().unwrap(), "line 70", "two pages from two lines up");
        for _ in 0..40 { chat.page(true); }
        assert_eq!(text(&chat.view(40, 10, Scrollbar::Hidden)).first().unwrap(), "line 0", "clamped at the top, never past it");
    }

    #[test]
    fn a_short_chat_sits_at_the_bottom_of_the_viewport() {
        let mut chat = chat_fn(3);
        let rows = text(&chat.view(20, 8, Scrollbar::Hidden));
        assert_eq!(rows, vec!["", "", "", "", "", "line 0", "line 1", "line 2"]);
        assert!(chat.following());
        chat.to_top();
        assert_eq!(chat.scrolled(), 0, "there is nothing above the top of a short chat");
    }

    #[test]
    fn tool_output_folds_to_its_summary_and_two_lines_and_thinking_to_one() {
        let mut chat = Chat::default();
        chat.block(Kind::Tool);
        chat.write("\u{23fa} Bash(cargo test)\ncompiling\nrunning 3 tests\nok\nok\nok\nexit 0\n");
        chat.block(Kind::Thinking);
        chat.write("\u{273b} Thinking\u{2026}\nfirst thought\nsecond thought\n");
        chat.block(Kind::Prose);
        chat.write("the answer\n");
        let folded = text(&chat.view(40, 20, Scrollbar::Hidden));
        let joined = folded.join("\n");
        assert!(joined.contains("Bash(cargo test)") && joined.contains("compiling") && joined.contains("running 3 tests"), "{joined}");
        assert!(!joined.contains("exit 0") && joined.contains("+4 lines"), "the tool folds to a summary: {joined}");
        assert!(!joined.contains("second thought") && folded.iter().any(|row| row.contains("+2 lines")), "thinking to its title: {joined}");
        assert!(joined.contains("the answer"), "prose never folds");
        assert!(!chat.toggle_tools(), "expanded now");
        assert!(!chat.tools_collapsed());
        assert!(text(&chat.view(40, 20, Scrollbar::Hidden)).join("\n").contains("exit 0"), "Ctrl+O expands");
        chat.toggle_thinking();
        assert!(text(&chat.view(40, 20, Scrollbar::Hidden)).join("\n").contains("second thought"), "Ctrl+T expands");
    }

    #[test]
    fn drawing_an_unchanged_view_wraps_nothing_again() {
        // The cost that matters: a session of thousands of rows must not re-wrap them per keystroke.
        let mut chat = Chat::default();
        for n in 0..200 { chat.write(&format!("row {n} {}
", "word ".repeat(n % 9))); }
        let _ = chat.view(40, 20, Scrollbar::Auto);
        let after_first = chat.wraps();
        for _ in 0..5 { let _ = chat.view(40, 20, Scrollbar::Auto); }
        assert_eq!(chat.wraps(), after_first, "nothing changed: nothing was wrapped");
        chat.write("another row
");
        let _ = chat.view(40, 20, Scrollbar::Auto);
        assert_eq!(chat.wraps(), after_first + 1, "only the block that changed");
        let _ = chat.view(39, 20, Scrollbar::Auto);
        assert!(chat.wraps() > after_first + 1, "a resize re-wraps, once");
        let after_resize = chat.wraps();
        let _ = chat.view(39, 20, Scrollbar::Auto);
        assert_eq!(chat.wraps(), after_resize, "and not again on the next frame");
    }

    #[test]
    fn the_thumb_is_at_least_one_row_and_sits_on_its_track() {
        assert_eq!(thumb(10, 100, 0), (0, 1));
        assert_eq!(thumb(10, 100, 90), (9, 1));
        assert_eq!(thumb(50, 100, 0), (0, 25));
        assert_eq!(thumb(50, 100, 50), (25, 25));
        assert_eq!(thumb(10, 5, 0), (0, 10), "no overflow: the whole track");
        assert_eq!(thumb(0, 100, 0), (0, 0));
    }

    #[test]
    fn the_scrollbar_is_shown_by_its_setting_and_reserves_the_last_column() {
        let mut chat = chat_fn(30);
        let hidden = chat.view(10, 5, Scrollbar::Hidden);
        assert_eq!(plain(&hidden[0]).trim_end(), "line 25", "no bar: the whole width is text: {hidden:?}");
        assert!(!hidden.iter().any(|row| plain(row).contains(BAR)), "{hidden:?}");
        let always = chat.view(10, 5, Scrollbar::Always);
        assert!(always.iter().all(|row| plain(row).ends_with('\u{2588}') || plain(row).ends_with('\u{2502}')), "{always:?}");
        assert!(always[4].contains('\u{2588}'), "following: the thumb is at the bottom: {always:?}");
        let mut short = chat_fn(2);
        assert!(short.view(20, 5, Scrollbar::Auto).iter().all(|row| !plain(row).contains(BAR)), "no overflow, no bar");
        assert!(short.view(20, 5, Scrollbar::Always).iter().all(|row| plain(row).ends_with('\u{2588}')));
    }
}
