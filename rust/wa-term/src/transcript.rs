//! The chat transcript as the CLI shows it: a list of blocks the view appends to, drawn by the host
//! into the output region. Owning the transcript here (rather than streaming text into the
//! terminal) is what lets a block be folded, focused and expanded while Lua is blocked, and what
//! puts the chat back exactly where it was after the slash menu or a panel closes.
//!
//! A *topic* is a collapsible block - the model's thinking, a tool call - shown at most
//! `FOLDED_ROWS` rows until it is expanded. Ctrl+Up (from the draft) focuses the latest topic; Up and
//! Down move between topics, Right expands, Left folds, Esc goes back to typing.
use crate::scroll::bar::{fit, Bar};
use crate::scroll::settings::Scrollbar;
use crate::terminal_editor::cell_width_of;
use std::collections::HashMap;

pub const FOLDED_ROWS: usize = 3;
/// How much of a CARD (a file change's diff, lua/core/diff_view.lua) is drawn when it is drawn: its
/// whole body up to this many lines, then one row that counts what it hid. A card is never folded to
/// `FOLDED_ROWS`: a reader looking at a change wants the change (Victor 23/11, twice). Every line is
/// here - the bound is display only - so Ctrl+O or a press on the counting row draws the rest.
pub const CARD_ROWS: usize = 40;
/// The copy affordance shown in front of a block that can be copied (#114): one glyph and a space,
/// what pi and Claude Code put before a fenced block's title. A mouse press on it copies the block's
/// content through OSC 52 (the terminal's clipboard), which is the only clipboard that works over
/// ssh and inside a container without a display.
pub const COPY_PREFIX: &str = "\u{29c9} ";
const MAX_LINES: usize = 20_000;
const RESET: &str = "\x1b[0m";
const DIM: &str = "\x1b[38;2;119;119;119m";
const FOCUS: &str = "\x1b[38;2;255;255;255m";
/// An expandable line under the pointer: drawn bright, so the reader sees it answers a click.
const BRIGHT: &str = "\x1b[1m\x1b[38;2;255;255;255m";
/// Marks an expandable line among a block's copy markers (`rows_with_copies`), so the screen-row map
/// is built in the one place the copy icons' map is: `\u{1}expand:<block>:<line>`.
const EXPAND_TAG: &str = "\u{1}expand:";
/// Marks the counting row of a folded card among a block's markers (`rows_with_copies`), so a press
/// on it opens the card: `\u{1}card:<block>`.
const CARD_TAG: &str = "\u{1}card:";
/// Marks a copy icon drawn at the RIGHT end of a row (a code block's first row: its code keeps the
/// band's left edge, operator 17/11 "a copy icon on its top"): `{RIGHT_TAG}{col}\u{1}{content}`.
const RIGHT_TAG: &str = "\u{1}right:";
/// The right-end copy icon.
const COPY_ICON: char = '\u{29c9}';
/// The colour `lua/core/markdown.lua` paints a fenced code card's border with (`mdCodeBlockBorder`,
/// `777777`). A quote's bar wears the same colour (`mdQuoteBorder`), so the colour alone does not make
/// a row a card row: a card is the rows BETWEEN its open corner and its close corner.
const CARD_BORDER: &str = "\x1b[38;2;119;119;119m";
/// The pinned request's band: white on the grey the reader's own turn is drawn on in the chat
/// (`lua/core/cli_view.lua` paints `48;2;68;68;68` there), so the top row and the bubble it stands
/// for are the same band. Claude Code keeps the same row at the top of its window.
const PIN_BAND: &str = "\x1b[38;2;255;255;255m\x1b[48;2;68;68;68m";
/// The notice row's colour: the view's warm accent, the one the footer's one-keystroke notes wear
/// (`wa_term::terminal_editor::NOTICE`), so a message looks the same wherever it is written from.
const NOTICE: &str = "\x1b[38;2;215;119;87m";
/// The jump-to-bottom pill: light text on a grey pill, over the row it covers.
const PILL: &str = "\x1b[38;2;230;230;230m\x1b[48;2;58;58;58m";
/// How long a transient notice stays on the notice row: about two seconds (Victor, 23/11 11:20Z).
/// An ERROR is not transient: it stays until the next key, because a message that says why nothing
/// was pasted is worth more than the row it costs.
pub const NOTICE_MS: u64 = 2000;

#[derive(Default, Clone)]
pub struct Block { pub lines: Vec<String>, open: bool, pub topic: bool, pub expanded: bool,
    /// Lines that can be copied, by line index: `{line: content}`. The content is the block's own
    /// text (a fenced block's body), not the drawn rows - the rows carry the border and the icon.
    pub copies: HashMap<usize, String>,
    /// Lines that expand on a click (a code-mode result folded to one row, operator 17/11): by line
    /// index, the full text, one row per `\n`. `opened` = the lines the reader has expanded.
    pub expands: HashMap<usize, String>,
    pub opened: std::collections::HashSet<usize>,
    /// A code-mode block (`⏺ Code · …`): drawn expanded while it is the running one, and folded to
    /// `summary` - ONE row - once the next one starts (`fold_code`).
    pub code: bool,
    /// The one row this block collapses to, set when a newer code-mode block takes the screen:
    /// `⏺ Code · bash ×3 ✓ · 1.2s → "a,b,c"`.
    pub summary: Option<String>,
    /// Ctrl+O on this block: pinned expanded, so the next code-mode block does not collapse it. The
    /// same key lets it go.
    pub pinned: bool,
    /// The CARD body ranges of this block, by line: `(from, to)`, inclusive - the lines of one diff
    /// body inside a card's frame (`cardable`, marked by lua/core/cli_view.lua's `card_mark`). A block
    /// carrying one is a card: one blank row above and below it, never folded by the topic rule, and
    /// drawn open up to `CARD_ROWS` lines per range with the rest counted on one row.
    pub cards: Vec<(usize, usize)>,
    /// This block is the READER'S OWN TURN: the `❯` line they sent (`lua/core/cli_view.lua`'s
    /// `accepted` marks its write). The view pins the last one above the viewport on the top row,
    /// which is what keeps a long run's question in sight.
    pub request: bool }

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
    /// The bar as the last view drew it: what a mouse report is measured against (`scroll::bar`).
    /// `None` while no bar is shown.
    bar_last: Option<Bar>,
    /// The pointer is on the bar: the thumb is drawn thick while it is (`scroll::bar`).
    bar_hovered: bool,
    /// A press grabbed the thumb (or came down on the track): the pointer's offset on the thumb,
    /// held for as long as the button is.
    bar_grab: Option<usize>,
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
    copy_rows: HashMap<usize, String>,
    /// Right-end copy icons of the last view: screen row -> (first column of the icon, content).
    copy_right: HashMap<usize, (usize, String)>,
    /// Expandable lines waiting for the next `write` (`expandable`), like `pending_copy`.
    pending_expand: Vec<(usize, String)>,
    /// Where each expandable line was drawn in the last `view`: screen row -> (block, line).
    expand_rows: HashMap<usize, (usize, usize)>,
    /// The expandable line under the pointer, drawn bright.
    expand_hover: Option<(usize, usize)>,
    /// The screen row whose copy icon the pointer is on: drawn bright, so the icon reads as a button
    /// (operator 17/11 "it does not have a hover effect").
    copy_hover: Option<usize>,
    /// The card body ranges waiting for the next `write` (`cardable`), like `pending_copy`.
    pending_card: Vec<(usize, usize)>,
    /// Where a folded card's counting row was drawn in the last `view`: screen row -> block. A press
    /// there opens the card, exactly as Ctrl+O does.
    card_rows: HashMap<usize, usize>,
    /// The transient TUI message of the moment, on the notice row above everything (`notice`).
    notice: Notice,
    /// The first content row the last `view` drew (`isize`, negative while the chat is shorter than
    /// the screen): the pinned request is measured against it, so the pin follows the turn in view
    /// and costs nothing per frame beyond the row counts `total_rows` already keeps.
    first_row: isize,
    /// How many rows the last `view` left below the viewport (the old "N more lines" count, now the
    /// pill's "N more lines"): what has arrived while the reader was away, in rows.
    below_rows: usize,
    /// How many rows the last `view` reserved at the top of the region (the notice, then the pinned
    /// request): every screen row the pointer reports is one of these plus a content row.
    reserved: usize,
    /// The last `view` drew the notice row (so it is row 1 of the region).
    notice_shown: bool,
    /// The last `view` drew the pinned request, one row under the notice row.
    pin_shown: bool,
    /// The columns the jump-to-bottom pill covered in the last `view` (1-based, inclusive), or
    /// `None` while no pill was drawn.
    pill_row: Option<(usize, usize)> }

impl Default for Transcript {
    fn default() -> Self {
        Transcript { blocks: Vec::new(), focus: None, dirty: false, top: None, freeze: false,
            page_delta: 0, nav: false, live_row: None, pending_copy: Vec::new(),
            copy_rows: HashMap::new(), copy_right: HashMap::new(), scrollbar: Scrollbar::Auto, counts: Vec::new(),
            count_width: 0, bar: false, bar_last: None, bar_hovered: false, bar_grab: None,
            pending_expand: Vec::new(), expand_rows: HashMap::new(), expand_hover: None, copy_hover: None,
            pending_card: Vec::new(), card_rows: HashMap::new(), notice: Notice::default(),
            first_row: isize::MAX, reserved: 0, below_rows: 0,
            notice_shown: false, pin_shown: false, pill_row: None }
    }
}

/// The notice row's message and its lifetime: `until` is the instant a transient notice goes, and
/// `None` while the text is empty OR while the message is one that stays until the next key (an
/// error). Written only through `Transcript::notice`, which is the one place a TUI message lands.
#[derive(Default, Clone)]
pub struct Notice { text: String, until: Option<std::time::Instant> }

impl Notice {
    pub fn text(&self) -> &str { &self.text }
    /// Whether there is nothing to draw at `now`.
    fn gone(&self, now: std::time::Instant) -> bool {
        self.text.is_empty() || self.until.is_some_and(|until| now >= until)
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
        self.pending_expand.clear();
        self.pending_card.clear();
        if let Some(last) = self.blocks.last_mut() {
            if last.lines.is_empty() {
                last.topic = topic; last.expanded = false;
                last.code = false; last.summary = None; last.pinned = false; last.cards.clear();
                last.request = false;
                return;
            }
        }
        self.blocks.push(Block { topic, ..Default::default() });
        self.counts.push(None);
    }

    /// Start a code-mode block: collapsible, but drawn **expanded** while it is the newest one - the
    /// block that is running is the one a reader is watching stream (`lua/core/codemode_block.lua`
    /// decides its rows; this decides its fold).
    pub fn code_block(&mut self) {
        self.block(true);
        if let Some(last) = self.blocks.last_mut() {
            last.code = true; last.expanded = true; last.pinned = false; last.summary = None;
        }
        self.dirty = true;
    }

    /// Collapse the code-mode blocks a newer one supersedes: the newest takes `summary` (the one row
    /// it becomes) and folds, and every older code block folds too - so exactly ONE code block is
    /// open, the one that is running, plus whatever the reader pinned with Ctrl+O. Called by the view
    /// immediately before it starts the next block. Returns whether anything folded.
    pub fn fold_code(&mut self, summary: &str) -> bool {
        let Some(newest) = (0..self.blocks.len()).rev().find(|&i| self.blocks[i].code && !self.blocks[i].lines.is_empty()) else { return false };
        let mut folded = false;
        if !self.blocks[newest].pinned {
            self.blocks[newest].summary = Some(summary.to_string());
            self.blocks[newest].expanded = false;
            if let Some(count) = self.counts.get_mut(newest) { *count = None; }
            folded = true;
        }
        for index in 0..newest {
            if self.blocks[index].code && !self.blocks[index].pinned && self.blocks[index].expanded {
                self.blocks[index].expanded = false;
                if let Some(count) = self.counts.get_mut(index) { *count = None; }
                folded = true;
            }
        }
        if folded { self.dirty = true; }
        folded
    }

    /// Rewrite a committed line of the current block by offset from its end (`-1` is the last row):
    /// how a code-mode block flips a running call's `⏳` row to `✓` in place instead of drawing the
    /// block again. The live row is not a committed line and is taken away first, as a write does.
    pub fn rewrite(&mut self, offset: isize, text: &str) -> bool {
        self.clear_live();
        let Some(block) = self.blocks.last_mut() else { return false };
        let index = block.lines.len() as isize + offset;
        if index < 0 || index as usize >= block.lines.len() { return false }
        block.lines[index as usize] = text.to_string();
        // An expand marker waiting for "the next write" belongs to this row when the row is
        // rewritten instead (a run block's call row learns its output only when it settles): the
        // row then opens on a click exactly as a written one does. Without a marker the row is a
        // plain row again - a rewrite never keeps the fold of the text it replaced.
        block.expands.remove(&(index as usize));
        block.opened.remove(&(index as usize));
        for (at, full) in std::mem::take(&mut self.pending_expand) {
            if at == 0 { block.expands.insert(index as usize, full); }
        }
        if let Some(count) = self.counts.last_mut() { *count = None; }
        self.dirty = true;
        true
    }

    /// Ctrl+O: pin the focused block - or the newest code-mode block - expanded, so the blocks that
    /// follow it no longer collapse it; the same key lets it go. Returns the new state.
    pub fn pin_toggle(&mut self) -> Option<bool> {
        // The newest block that can answer, whether it is a code-mode block or a CARD: after a run the
        // card is the newer one, and this key on it means "show me all of it" (Victor 23/11).
        let index = self.focus.or_else(|| (0..self.blocks.len()).rev().find(|&i|
            (self.blocks[i].code && !self.blocks[i].lines.is_empty()) || !self.blocks[i].cards.is_empty()))?;
        let block = &mut self.blocks[index];
        // A folded RESULT line (`⎿ script output · 2,549 chars`, lua/core/codemode_block.lua)
        // opens with this key too, and the same key folds it back: the row's own press does exactly
        // this (expand_at), and a reader told "click or Ctrl+O" has one key to remember (Victor
        // 23/11). Only when the block HAS such a line: a block without one keeps the pin below.
        if !block.expands.is_empty() {
            let open_all = block.opened.len() < block.expands.len();
            if open_all {
                for line in block.expands.keys() { block.opened.insert(*line); }
            } else {
                block.opened.clear();
            }
            if let Some(count) = self.counts.get_mut(index) { *count = None; }
            self.dirty = true;
            return Some(open_all);
        }
        // A card's key IS its fold: the same press opens it and folds it back. A code block's key is
        // the pin, which is what keeps a LATER block from collapsing it.
        if !block.cards.is_empty() {
            block.expanded = !block.expanded;
            if let Some(count) = self.counts.get_mut(index) { *count = None; }
            self.dirty = true;
            return Some(block.expanded);
        }
        block.pinned = !block.pinned;
        if block.pinned { block.expanded = true; }
        if let Some(count) = self.counts.get_mut(index) { *count = None; }
        self.dirty = true;
        Some(block.pinned)
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

    /// Mark lines of the NEXT `write` as expandable: `(offset, full text)`. The line is drawn as written
    /// (one row); a click on it shows the full text in its place, a second click folds it again.
    pub fn expandable(&mut self, markers: &[(usize, String)]) {
        self.pending_expand = markers.iter().map(|(at, text)| (*at, text.clone())).collect();
    }

    /// Mark the current block's FIRST line copyable with `text` (a code-mode block: its code is known only once
    /// the call settles, after its rows streamed). The copy icon is drawn in front of that line.
    pub fn copy_first(&mut self, text: &str) -> bool {
        let Some(block) = self.blocks.last_mut() else { return false };
        if block.lines.is_empty() { return false }
        block.copies.insert(0, text.to_string());
        if let Some(count) = self.counts.last_mut() { *count = None; }
        self.dirty = true;
        true
    }
    /// Mark the CARD body ranges of the NEXT `write`: `(from, to)`, inclusive line offsets of that
    /// write - the lines of one diff body inside a card's frame. The block then draws them open up to
    /// `CARD_ROWS`, counts the rest on one row, and opens fully on Ctrl+O or a press: the frame, the
    /// heading and the counts are never folded away.
    pub fn cardable(&mut self, ranges: &[(usize, usize)]) {
        self.pending_card = ranges.to_vec();
    }

    /// A press on an expandable line toggles it; a press on a folded card's counting row opens (or
    /// folds) that card. Returns whether the press was one of those.
    pub fn expand_at(&mut self, row: usize) -> bool {
        if let Some(&index) = self.card_rows.get(&row) {
            if let Some(block) = self.blocks.get_mut(index) {
                block.expanded = !block.expanded;
                if let Some(count) = self.counts.get_mut(index) { *count = None; }
                self.dirty = true;
                return true;
            }
        }
        let Some(&(block, line)) = self.expand_rows.get(&row) else { return false };
        let Some(found) = self.blocks.get_mut(block) else { return false };
        if !found.opened.remove(&line) { found.opened.insert(line); }
        if let Some(count) = self.counts.get_mut(block) { *count = None; }
        self.dirty = true;
        true
    }

    /// The pointer moved: the expandable line under it (if any) is drawn bright. Only a change of line
    /// sets `dirty`, so a moving pointer costs no frame.
    pub fn expand_hover(&mut self, row: usize) -> bool {
        let now = self.expand_rows.get(&row).copied();
        if now == self.expand_hover { return false }
        self.expand_hover = now;
        self.dirty = true;
        true
    }

    /// The pointer moved: is it on a copy icon? Only a change sets `dirty` (a moving pointer costs no frame).
    pub fn copy_hover(&mut self, row: usize, col: usize) -> bool {
        let now = self.copy_at(row, col).map(|_| row);
        if now == self.copy_hover { return false }
        self.copy_hover = now;
        self.dirty = true;
        true
    }

    /// The hovered copy icon, brightened in the rows about to be drawn (bold + bright white, ended with
    /// the codes that undo only those two, so a band's background stays).
    fn light_icon(&self, shown: &mut [String], base: usize) {
        let Some(row) = self.copy_hover else { return };
        if !(self.copy_rows.contains_key(&row) || self.copy_right.contains_key(&row)) { return }
        if let Some(line) = shown.get_mut(row.saturating_sub(1 + base)) {
            let icon = COPY_ICON.to_string();
            if let Some(at) = if self.copy_right.contains_key(&row) { line.rfind(&icon) } else { line.find(&icon) } {
                line.replace_range(at..at + icon.len(), &format!("\x1b[1;97m{icon}\x1b[22;39m"));
            }
        }
    }

    /// One marker of `rows_with_copies`, placed on the screen: a copy icon or an expandable line.
    fn place(&mut self, row: usize, content: String) {
        if let Some(key) = content.strip_prefix(CARD_TAG) {
            if let Ok(index) = key.parse() { self.card_rows.insert(row, index); }
            return;
        }
        if let Some(key) = content.strip_prefix(EXPAND_TAG) {
            if let Some((b, l)) = key.split_once(':') {
                if let (Ok(b), Ok(l)) = (b.parse(), l.parse()) { self.expand_rows.insert(row, (b, l)); }
            }
            return;
        }
        if let Some(rest) = content.strip_prefix(RIGHT_TAG) {
            if let Some((col, text)) = rest.split_once('\u{1}') {
                if let Ok(col) = col.parse() { self.copy_right.insert(row, (col, text.to_string())); }
            }
            return;
        }
        self.copy_rows.insert(row, content);
    }

    /// The content a mouse press at `(row, col)` copies: the icon cell of a copyable row, and
    /// nothing else. Rows and columns are the ones the last `view` drew (1-based, screen cells), so
    /// a caller reads its own coordinates without translating anything.
    pub fn copy_at(&self, row: usize, col: usize) -> Option<String> {
        if let Some((at, text)) = self.copy_right.get(&row) {
            if col + 1 >= *at && col <= *at + 2 { return Some(text.clone()) }
        }
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
            found.expands.remove(&0);
            self.dirty = true;
        }
        true
    }

    /// Append text to the current block. A newline ends a line; text without one leaves the line
    /// open for the next write.
    pub fn write(&mut self, text: &str) {
        self.clear_live();
        let markers = std::mem::take(&mut self.pending_copy);
        let expands = std::mem::take(&mut self.pending_expand);
        let cards = std::mem::take(&mut self.pending_card);
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
        for (at, full) in expands {
            if at < produced.max(1) && first + at < block.lines.len() {
                block.expands.insert(first + at, full);
            }
        }
        // The card body ranges of this write, now that its lines have indices of their own.
        for (from, to) in cards {
            if from <= to && to < produced.max(1) && first + to < block.lines.len() {
                block.cards.push((first + from, first + to));
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

    /// Append text, and mark the block as the READER'S OWN TURN when `request`. The view pins the
    /// last one above the viewport on the top row: a run's question stays in sight while its answer
    /// scrolls. The mark is drawing only - nothing of it reaches the model or a stored message.
    pub fn write_marked(&mut self, text: &str, request: bool) {
        self.write(text);
        if !request { return }
        // A request gets a block of its OWN, closed behind it: the answer that follows streams into
        // the next block (it is written with no `topic` call of its own, so without this it would
        // join the request and the two could never be separated - the pin needs the request's rows
        // to be able to leave the viewport while the answer grows).
        if let Some(block) = self.blocks.last_mut() { block.request = true; }
        self.blocks.push(Block::default());
        self.counts.push(None);
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

    // ---- the notice row, the pinned request, and the way back to the bottom ------------------

    /// THE one place a transient TUI message is written: a copy, a paste, an attachment, an
    /// interrupt hint, a refusal. It lands on the notice row at the top of the transcript, never on
    /// the session status bar or the input box (Victor, 23/11 11:20Z). `sticky` = it stays until
    /// the next key (an error the reader must see); otherwise it goes after `NOTICE_MS`. Returns
    /// whether anything changed, so a caller can repaint only when it must.
    pub fn notice(&mut self, text: &str, now: std::time::Instant, sticky: bool) -> bool {
        let line: String = text.split('\n').map(str::trim).filter(|part| !part.is_empty())
            .collect::<Vec<_>>().join(" ");
        if line == self.notice.text && !self.notice.gone(now) { return false }
        let empty = line.is_empty();
        self.notice.text = line;
        self.notice.until = if empty || sticky {
            None
        } else {
            Some(now + std::time::Duration::from_millis(NOTICE_MS))
        };
        self.dirty = true;
        true
    }

    /// The message on the notice row, if one is showing at `now`.
    pub fn notice_text(&self, now: std::time::Instant) -> Option<String> {
        if self.notice.gone(now) { None } else { Some(self.notice.text.clone()) }
    }

    /// Whether the message on the row has run out of its time: the caller takes it away and
    /// repaints, which is what makes the row disappear after about two seconds.
    pub fn notice_expired(&self, now: std::time::Instant) -> bool {
        !self.notice.text.is_empty() && self.notice.until.is_some_and(|until| now >= until)
    }

    /// Take a notice whose time is up off the row. Returns whether there was one.
    pub fn expire_notice(&mut self, now: std::time::Instant) -> bool {
        if !self.notice_expired(now) { return false }
        self.notice = Notice::default();
        self.dirty = true;
        true
    }

    /// The notice goes now: the reader pressed its row, or a key landed on a message that waits for
    /// one. Returns whether there was one.
    pub fn clear_notice(&mut self) -> bool {
        if self.notice.text.is_empty() { return false }
        self.notice = Notice::default();
        self.dirty = true;
        true
    }

    /// The notice row as it is drawn: right-aligned, one column short of the edge, in the warm
    /// accent - a small balloon at the top of the window. `None` = nothing to say, so the row does
    /// not exist and the pinned request is the top row.
    fn notice_line(&self, width: usize, now: std::time::Instant) -> Option<String> {
        let text = self.notice_text(now)?;
        let text = clip_row(&text, width.saturating_sub(1)).trim_end().to_string();
        let pad = width.saturating_sub(visible(&text) + 1);
        Some(format!("{}{NOTICE}{text}{RESET}", " ".repeat(pad)))
    }

    /// The pill's words. The KEY is passed in - the caller reads it from the keymap
    /// (`keymap::label`), so a rebinding changes this label and no key name is written here - and
    /// `new_lines` says how much output arrived while the reader was away.
    pub fn pill_text(key: &str, new_lines: usize) -> String {
        let key = key.trim();
        let jump = if key.is_empty() {
            "Jump to bottom".to_string()
        } else {
            format!("Jump to bottom ({key})")
        };
        if new_lines > 0 {
            format!("\u{2193} {new_lines} more line{} \u{b7} {jump} \u{2193}",
                if new_lines == 1 { "" } else { "s" })
        } else {
            format!("{jump} \u{2193}")
        }
    }

    /// The content row the next frame will show first, as far as it can be known BEFORE it is drawn:
    /// the bottom-anchored arithmetic while the view follows the output (which is nearly always,
    /// during a run), the frozen position while it does not. `None` = only the frame itself knows
    /// (a focus, a page step, a freeze that has not landed yet).
    fn expected_first(&mut self, width: usize, rows: usize) -> Option<isize> {
        if self.focus.is_some() || self.nav || self.page_delta != 0 || (self.freeze && self.top.is_none()) {
            return None;
        }
        let total = self.total_rows(self.text_width(width)) as isize;
        match self.top {
            None => Some(total - rows as isize),
            Some(top) => Some(top),
        }
    }

    /// The pill when the window is too narrow for `pill_text`: the count and the key, without the
    /// words that name the action (the key IS the action). Never a clipped key.
    fn pill_compact(key: &str, new_lines: usize) -> String {
        let key = key.trim();
        match (new_lines, key.is_empty()) {
            (0, true) => "Jump to bottom \u{2193}".to_string(),
            (0, false) => format!("{key} \u{2193}"),
            (n, true) => format!("\u{2193} {n} more line{} \u{2193}", if n == 1 { "" } else { "s" }),
            (n, false) => format!("\u{2193} {n} more line{} \u{b7} {key} \u{2193}", if n == 1 { "" } else { "s" }),
        }
    }

    /// The reader's own request that sits entirely ABOVE the row `first`: the LAST such block, so
    /// scrolling up into an older turn pins that turn's request. `None` when the newest request is
    /// on screen (nothing to pin) or when the session has not sent one yet.
    fn pinned_block(&mut self, width: usize, first: isize) -> Option<usize> {
        if first <= 0 || first == isize::MAX { return None }
        // The same per-block row counts the bar is sized from, filled here if this is the first
        // frame that asks: one block is wrapped, and only the one whose count was stale.
        self.total_rows(self.text_width(width));
        let mut row = 0usize;
        let mut found = None;
        for index in 0..self.blocks.len() {
            let rows = self.rows_cached(index);
            if self.blocks[index].request && !self.blocks[index].lines.is_empty()
                && row + rows <= first as usize {
                found = Some(index);
            }
            row += rows;
        }
        found
    }

    /// The rows one block was last counted at (`total_rows`'s cache).
    fn rows_cached(&self, index: usize) -> usize {
        self.counts.get(index).copied().flatten().unwrap_or(0)
    }

    /// The pinned row: the prompt mark and the request's first line, on the band the chat draws the
    /// reader's own turn on. The caller clips it to the window with an ellipsis.
    fn pin_line(&self, index: usize) -> String {
        let text = self.blocks.get(index)
            .and_then(|block| block.lines.iter().find(|line| !line.trim().is_empty()))
            .map(|line| crate::selection::plain(line))
            .unwrap_or_default();
        let text = text.trim();
        format!("{PIN_BAND}{text}\x1b[K{RESET}")
    }

    /// Whether the pointer at `(row, col)` is on the pinned request: a press there scrolls to it.
    pub fn on_pin(&self, row: usize) -> bool {
        self.pin_shown && row == 1 + usize::from(self.notice_shown)
    }

    /// Whether the pointer is on the notice row: a press there takes the message away now.
    pub fn on_notice(&self, row: usize) -> bool {
        self.notice_shown && row == 1
    }

    /// Whether the pointer is on the jump-to-bottom pill (its own cells only: the rest of that row
    /// is the chat, and a press there is a selection as it always was).
    pub fn on_pill(&self, row: usize, col: usize, height: usize) -> bool {
        self.pill_row.map(|(at, to)| row == height && col >= at && col <= to).unwrap_or(false)
    }

    /// Scroll to the request the pinned row stands for: its block comes to the top of the region,
    /// and the view stops following new output there (the pill then offers the way back).
    pub fn jump_to_pinned(&mut self, width: usize) -> bool {
        let Some(index) = self.pinned_block(width, self.first_row) else { return false };
        let mut row = 0usize;
        for block in 0..index { row += self.rows_cached(block); }
        self.freeze = true;
        self.page_delta = 0;
        self.top = Some(row as isize);
        self.dirty = true;
        true
    }

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
        // A CARD is drawn OPEN (Victor 23/11): its body up to `CARD_ROWS` lines, then ONE row that
        // counts what it hid. Per card range, `(last line kept, lines hidden, first line hidden)`;
        // nothing at all while the card is expanded, focused, or short enough to fit.
        let card = !block.cards.is_empty();
        let mut folds: Vec<(usize, usize, usize)> = Vec::new();
        if card && !block.expanded && !focused {
            for &(from, to) in &block.cards {
                if to >= from + CARD_ROWS {
                    folds.push((from + CARD_ROWS - 1, to - (from + CARD_ROWS - 1), from + CARD_ROWS));
                }
            }
        }
        let count_at = |line: usize| folds.iter().find(|&&(_, _, first)| first == line).map(|&(_, hidden, _)| hidden);
        let hidden_at = |line: usize| folds.iter().any(|&(kept, hidden, _)| line > kept && line <= kept + hidden);
        // Where each card's body is DRAWN, while the card is open: those rows answer a press too, so a
        // second click folds the card it just opened - the same rule `expandable` already uses for an
        // opened result (every row it covers answers the click).
        let mut open_spans: Vec<(usize, usize)> = Vec::new();
        let mut span_from: Option<usize> = None;
        // One blank row ABOVE a card, so its frame is never glued to the line that introduced it; the
        // row below is added after the loop. Both are the block's own rows, so they survive a resize,
        // a re-render, and the transcript a --continue replays.
        if card { rows.push(String::new()); }
        // A card's rows are cut, not wrapped as prose (`CardWrap`): the frame state follows the
        // block's lines in order, which is the only way a row can be known to be a card's.
        let mut cards = CardWrap::default();
        for (line_index, raw) in block.lines.iter().enumerate() {
            // Where a card's body stops fitting: ONE row counts the rest, and it keeps the card's own
            // bar so the frame still reads as one frame.
            if let Some(hidden) = count_at(line_index) {
                rows.push(format!("{CARD_BORDER}\u{2502}{RESET} {DIM}\u{2026} +{hidden} lines (ctrl+o to expand){RESET}"));
                copies.push((rows.len() - 1, format!("{CARD_TAG}{index}")));
            }
            if let Some((&(from, _), _)) = block.cards.iter().zip(0..).find(|(&(from, _), _)| from == line_index) {
                if card && block.expanded { span_from = Some(rows.len()); }
                let _ = from;
            }
            if let Some(&(_, to)) = block.cards.iter().find(|&&(_, to)| to + 1 == line_index) {
                if let Some(start) = span_from.take() { open_spans.push((start, rows.len().saturating_sub(1))); }
                let _ = to;
            }
            // A folded line is not drawn: its count is on the row above, and Ctrl+O or a press on
            // that row draws every one of them - the lines are all in the block.
            if hidden_at(line_index) { continue; }
            // A rule is drawn at THIS frame's width, never at the width it was written at
            // (expand_rule): a transcript outlives a resize, and what is drawn inside it does not.
            let line = &expand_rule(raw, inner);
            let content = block.copies.get(&line_index);
            let start = rows.len();
            if let Some(full) = block.expands.get(&line_index) {
                if block.opened.contains(&line_index) {
                    for part in full.split('\n') { rows.extend(wrap_rows(part, inner)); }
                } else if self.expand_hover == Some((index, line_index)) {
                    rows.extend(wrap_rows(&format!("{BRIGHT}{}{RESET}", crate::selection::plain(line)), inner));
                } else {
                    rows.extend(cards.rows(line, inner));
                }
                // Every row it now covers answers the click, so a reader can fold it from anywhere.
                for at in start..rows.len() { copies.push((at, format!("{EXPAND_TAG}{index}:{line_index}"))); }
                continue;
            }
            if content.is_some() && block.code && line_index == 0 {
                // A code block keeps its code at the band's left edge: the icon takes the last blank
                // cell of the first row instead (no blank cell = the code fills the row: no icon).
                // A band row is stored UNCUT and cut here (`wrap_band`), like a fence's body row
                // (`CardWrap`): the two blocks have ONE owner of the cut, and it is this frame's width.
                let mut wrapped = match band_row(line) {
                    Some((fill, code)) => wrap_band(&cells_of(code).0, inner, fill),
                    None => wrap_rows(line, inner),
                };
                if let Some(first) = wrapped.first_mut() {
                    let placed = icon_at_right(first)
                        // A band row paints its rest with EL and carries no blank cell to put the
                        // icon in (item F): the icon still goes onto the band, at its right end.
                        .or_else(|| icon_at_band_end(first, inner));
                    if let Some((with_icon, col)) = placed {
                        *first = with_icon;
                        copies.push((start, format!("{RIGHT_TAG}{}\u{1}{}", col + usize::from(focused), content.expect("checked"))));
                    }
                }
                rows.extend(wrapped);
                continue;
            }
            // A band row that is not the block's first line is cut the same way: the copy icon never
            // rides inside the band (`COPY_PREFIX` in front of a row would paint outside it).
            if let Some((fill, code)) = band_row(line) {
                let mut wrapped = wrap_band(&cells_of(code).0, inner, fill);
                if let Some(content) = content {
                    if let Some(first) = wrapped.first_mut() {
                        if let Some((with_icon, col)) = icon_at_right(first).or_else(|| icon_at_band_end(first, inner)) {
                            *first = with_icon;
                            copies.push((start, format!("{RIGHT_TAG}{}\u{1}{}", col + usize::from(focused), content)));
                        }
                    }
                }
                rows.extend(wrapped);
                continue;
            }
            // The running call's line is a STATUS row: one screen row, always (see `clip_row`).
            let is_live = self.live_row == Some((index, line_index));
            if content.is_some() {
                // The affordance is part of the row, so the wrap and the click agree about where it
                // ends: the icon takes its columns from the text and the header wraps two columns
                // narrower, which is what a reader sees either way.
                // Through `cards` too: a fence's OPENING row carries the copy icon, so it is the
                // row that opens the card frame - wrapped as prose, the rows under it would never
                // be known to be a card's.
                // A fence's opening row keeps its corner where the border is: the icon goes AFTER
                // `┌─`, before the title (`┌─ ⧉ bash`), and the click target is that cell - the
                // column travels with the marker (RIGHT_TAG), as the code block's right-end icon does.
                if let Some((with_icon, col)) = icon_after_corner(line) {
                    rows.extend(cards.rows(&with_icon, inner));
                    copies.push((start, format!("{RIGHT_TAG}{}\u{1}{}", col + usize::from(focused), content.expect("checked"))));
                    continue;
                }
                rows.extend(cards.rows(&format!("{COPY_PREFIX}{line}"), inner));
                copies.push((start, content.expect("checked").clone()));
            } else if is_live {
                rows.push(clip_row(line, inner));
            } else {
                rows.extend(cards.rows(line, inner));
            }
        }
        for (start, end) in open_spans {
            for at in start..=end.min(rows.len().saturating_sub(1)) {
                copies.push((at, format!("{CARD_TAG}{index}")));
            }
        }
        // A card keeps exactly ONE blank row under it, so the thinking or answer text that follows is
        // never glued to its closing corner (Victor 23/11). Every other topic loses its trailing
        // blanks: they separated it from a block that is no longer drawn.
        while rows.last().is_some_and(|r| visible(r) == 0) { rows.pop(); }
        if card { rows.push(String::new()); }
        // A code-mode block is open while it runs and ONE row afterwards: the summary a newer block
        // left it with. Pinned (Ctrl+O) or focused, it shows everything it holds.
        if block.code && !block.expanded && !block.pinned && !focused {
            if let Some(summary) = block.summary.as_ref() { return (vec![summary.clone()], Vec::new()) }
            // No summary was ever handed to this block (it was pinned when its successor started): its
            // own heading is the row it keeps - `⏺ Code · bash … 1.2s` says what it was and how it
            // went, which is what the collapsed state is for.
            if let Some(head) = block.lines.first() { return (vec![expand_rule(head, inner)], Vec::new()) }
        }
        // Folded: the topic's title row, then its first FOLDED_ROWS rows of content - blank rows
        // skipped, so three rows are three lines of text - then how much is hidden.
        // A card is never folded by this rule: its own bound (`CARD_ROWS`) is the one it answers to.
        if block.cards.is_empty() && block.topic && !block.expanded && rows.len() > 1 + FOLDED_ROWS {
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

    /// The rows `1..=height` show: the notice row, the pinned request, and the chat under them -
    /// bottom-anchored while following, fixed while frozen, always keeping a focused topic on
    /// screen. See `view_at`.
    pub fn view(&mut self, width: usize, height: usize) -> Vec<String> {
        self.view_at(width, height, std::time::Instant::now())
    }

    /// The same at a stated instant - the notice row's clock, so a test can age a message without
    /// sleeping. The rows reserved at the top are rows OF the region, not rows drawn over it: the
    /// chat is that much shorter, and every row below them keeps its own place in the chat.
    pub fn view_at(&mut self, width: usize, height: usize, now: std::time::Instant) -> Vec<String> {
        let (width, height) = (width.max(1), height.max(1));
        let mut top: Vec<String> = Vec::new();
        let has_notice = self.notice_line(width, now);
        if let Some(row) = has_notice.clone() { top.push(row); }
        // One row of the region always stays the chat's, however short the window is.
        let mut has_pin = false;
        if height > top.len() + 1 {
            let first = self.expected_first(width, height - top.len()).unwrap_or(self.first_row);
            if let Some(index) = self.pinned_block(width, first) {
                // Clipped with an ellipsis, one row, never wider than the window (a very long or
                // multi-line request is one row of the reader's own words).
                top.push(clip_row(&self.pin_line(index), width));
                has_pin = true;
            }
        }
        top.truncate(height.saturating_sub(1).min(top.len()));
        let reserved = top.len();
        self.reserved = reserved;
        self.notice_shown = has_notice.is_some() && reserved >= 1;
        self.pin_shown = has_pin && reserved >= 1 + usize::from(self.notice_shown);
        let rows = height - reserved;
        let mut shown = self.paint(width, rows, reserved);
        // The way back: the reader is not following the newest output, so a pill says so on the
        // region's last row and answers a press and the key. It never reaches the row below it.
        self.pill_row = None;
        if rows >= 1 && !self.following() {
            let key = crate::keymap::label(crate::keymap::Act::Nav(crate::keymap::NavAct::Bottom))
                .unwrap_or_default();
            let text_width = self.text_width(width);
            let room = text_width.saturating_sub(2);
            // The key is what the brief asks the pill to name, so a narrow window keeps it and
            // drops the count instead of cutting the key in half; a wide one says both.
            let full = Self::pill_text(key, self.below_rows);
            let compact = Self::pill_compact(key, self.below_rows);
            let text = if visible(&full) <= room { full }
                else if visible(&compact) <= room { compact }
                else { clip_row(&compact, room) };
            if let Some(row) = shown.last_mut() {
                let (line, span) = pill_row(row, &text, text_width);
                // The bar's cell of that row survives the pill: the track does not break for it.
                *row = match self.bar_last.and_then(|bar| bar.cells().last().copied()) {
                    Some((glyph, colour)) => format!("{}{colour}{glyph}{RESET}", fit(&line, text_width)),
                    None => line,
                };
                self.pill_row = Some(span);
            }
        }
        let mut view = top;
        view.extend(shown);
        view
    }

    /// The chat's own rows for `height` rows of region, drawn `base` rows down: what `view_at`
    /// reserves at the top is the caller's business, and only the offset of what the pointer can
    /// press (a copy icon, an expandable line) is this function's.
    fn paint(&mut self, width: usize, height: usize, base: usize) -> Vec<String> {
        self.copy_rows.clear();
        self.copy_right.clear();
        self.expand_rows.clear();
        self.card_rows.clear();
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
                // This block goes ABOVE what is already in `tail`, so every marker found so far moves down
                // by its rows (17/11: without the shift a click on a newer block's line - a copy icon, an
                // expandable result - landed on the wrong row, or on none).
                let shift = rows.len();
                for (at, _) in copies.iter_mut() { *at += shift; }
                for (at, content) in block_copies { copies.push((at, content)); }
                rows.extend(tail);
                tail = rows;
                if tail.len() >= height { break; }
            }
            let skip = tail.len().saturating_sub(height);
            let blank = height.saturating_sub(tail.len());
            for (at, content) in copies {
                if at >= skip { self.place(base + blank + at - skip + 1, content); }
            }
            let mut shown = vec![String::new(); blank];
            shown.extend(tail.into_iter().skip(skip));
            // Following the bottom: the first row shown is the one `height` above the end.
            let first = total.saturating_sub(shown.len());
            // The reader is following the model: nothing is waiting for them.
            self.first_row = first as isize;
            self.below_rows = 0;
            self.light_icon(&mut shown, base);
            self.draw_bar(&mut shown, text_width, self.bar, total, first);
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
            if row >= 0 && row < h { self.place(base + row as usize + 1, content); }
        }
        let below = whole - (start + h);
        self.below_rows = if below > 0 { below as usize + 1 } else { 0 };
        // The bar is sized from the rows this frame actually wrapped: in this path every block is
        // laid out, so that is the whole chat.
        let first = start.max(0) as usize;
        self.first_row = start;
        if self.following() { self.below_rows = 0; }
        self.light_icon(&mut shown, base);
        self.draw_bar(&mut shown, text_width, self.bar, rows.len(), first);
        shown
    }

    /// The scrollbar drawn over `rows` (#115): the track in the last column and the thumb where the
    /// reader is. `scroll::chat`'s `thumb` and `fit` are borrowed rather than re-invented - the
    /// fullscreen console's bar and this one are the same bar, and its arithmetic is the part a
    /// second implementation would get subtly wrong.
    fn draw_bar(&mut self, rows: &mut [String], text_width: usize, bar: bool, total: usize, first: usize) {
        if !bar || rows.is_empty() { self.bar_last = None; return }
        // One glyph per row, from the first row of the region to the last: a click is measured
        // against exactly this (`scroll::bar`), so what is drawn and what is hit cannot drift apart.
        let drawn = Bar { active: self.bar_active(), ..Bar::new(rows.len(), total, first) };
        for (row, (glyph, colour)) in rows.iter_mut().zip(drawn.cells()) {
            *row = format!("{}{colour}{glyph}{RESET}", fit(row, text_width));
        }
        self.bar_last = Some(drawn);
    }

    /// The bar as the last `view` drew it: `None` while no bar is shown.
    pub fn bar(&self) -> Option<Bar> { self.bar_last }

    /// How many columns the chat's text occupies at a screen `width`: the last column a mouse
    /// selection may reach. The bar costs a column while it is drawn and `view` wraps the chat one
    /// column narrower then; this repeats that arithmetic for the caller that copies what was dragged
    /// over, so a copy cannot disagree with the draw and take the bar's glyph as text (Victor, 21/11:
    /// every pasted line ended in `\u{2502}`).
    pub fn text_width(&self, width: usize) -> usize {
        let width = width.max(1);
        if self.bar { width.saturating_sub(1).max(1) } else { width }
    }

    /// The bar's column alone, each cell at its own absolute position: what a frame that repainted
    /// the chat's rows must write back after it. `selection::overlay` clears a row with `2K`, the
    /// bar's column with it, so without this the track would vanish under a selection. Empty while
    /// no bar is drawn.
    pub fn bar_frame(&self, width: usize) -> String {
        let Some(bar) = self.bar_last else { return String::new() };
        let mut frame = String::new();
        for (offset, (glyph, colour)) in bar.cells().iter().enumerate() {
            frame.push_str(&format!("\x1b[{};{width}H{colour}{glyph}{RESET}", offset + 1 + self.reserved));
        }
        frame
    }

    /// Whether a pointer at `(row, col)` of a `width`-wide screen is on the bar: its last column,
    /// while the bar is shown. Rows and columns are screen rows and cells, 1-based, as the terminal
    /// reports them.
    pub fn on_bar(&self, row: usize, col: usize, width: usize) -> bool {
        // The bar's rows are the CHAT's rows: the rows reserved above it (the notice, the pinned
        // request) are nobody's bar, and a press there is theirs.
        self.bar_last.is_some_and(|bar| width > 1 && col == width
            && row > self.reserved && row <= self.reserved + bar.track)
    }

    /// A press on the bar: the thumb comes to the pointer (its middle, when the press was on the
    /// track) and the drag starts there. Returns whether the press was the bar's - a press that is
    /// not on the bar is the selection's, as it always was.
    pub fn bar_press(&mut self, row: usize, col: usize, width: usize) -> bool {
        if !self.on_bar(row, col, width) { return false }
        let bar = self.bar_last.expect("on_bar checked it");
        if !bar.scrolling() { return false }
        let at = row.saturating_sub(1 + self.reserved).min(bar.track - 1);
        let grab = bar.grab(at);
        self.bar_grab = Some(grab);
        self.bar_to(bar.first_at(at, grab));
        true
    }

    /// The button is down and the pointer moved: the bar scrolls with it. Only a press that grabbed
    /// the bar drags it, and a drag that wandered off the bar still scrolls (as it does in pi).
    pub fn bar_drag(&mut self, row: usize) -> bool {
        let Some(grab) = self.bar_grab else { return false };
        let Some(bar) = self.bar_last else { return false };
        if bar.track == 0 { return false }
        let at = row.saturating_sub(1 + self.reserved).min(bar.track - 1);
        self.bar_to(bar.first_at(at, grab));
        true
    }

    /// The button came up: the thumb lets go.
    pub fn bar_release(&mut self) -> bool {
        let had = self.bar_grab.take().is_some() || self.bar_hovered;
        self.bar_hovered = false;
        had
    }

    /// The pointer is on the bar, or left it: the thumb thickens and thins. Returns whether the
    /// frame changed - a pointer that stays on one side of the bar costs no redraw.
    pub fn bar_hover(&mut self, row: usize, col: usize, width: usize) -> bool {
        if self.bar_grab.is_some() { return false }
        let hovered = self.on_bar(row, col, width);
        if hovered == self.bar_hovered { return false }
        self.bar_hovered = hovered;
        self.dirty = true;
        true
    }

    /// Whether the pointer is on the bar (or holding it): the thumb is drawn thick.
    pub fn bar_active(&self) -> bool { self.bar_hovered || self.bar_grab.is_some() }

    /// Put the view at content row `first`, frozen there: what the bar's click and drag are. At the
    /// bottom the view follows again, which `view` decides from the same number.
    fn bar_to(&mut self, first: usize) {
        self.freeze = true;
        self.page_delta = 0;
        self.top = Some(first as isize);
        self.dirty = true;
    }

    /// The frame that draws the output region (`rows` = its last row).
    ///
    /// The bar's cell is written a second time, at its own column, after the row. A row's text can
    /// turn out one cell wider than `cell_width` believes - an emoji a terminal draws two cells wide
    /// and this crate counts as one - and a terminal then wraps the rest of the row onto the next
    /// line, which used to carry the bar's glyph with it and leave a break in the track (the
    /// operator's screenshot, 13/11 ~06:50). An absolute cursor position cannot wrap: every row of
    /// the track gets its glyph at the same column, whatever the text does.
    pub fn render(&mut self, width: usize, rows: usize) -> String {
        let view = self.view(width, rows);
        let bar = self.bar();
        let base = self.reserved;
        let mut frame = String::new();
        for (offset, row) in view.iter().enumerate() {
            frame.push_str(&format!("\x1b[{};1H\x1b[2K{row}{RESET}", offset + 1));
            // The bar's grid is the chat's rows: the rows reserved above it (the notice, the
            // pinned request) have no cell of it, and the band runs the whole window there.
            if let Some((glyph, colour)) = offset.checked_sub(base)
                .and_then(|at| bar.and_then(|bar| bar.cells().get(at).copied())) {
                frame.push_str(&format!("\x1b[{};{width}H{colour}{glyph}{RESET}", offset + 1));
            }
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
/// The rule marker the Lua view writes instead of a measured rule: `\1r\1` (lua/core/cli_view.lua
/// `M.RULE`). A rule is nothing but its width, so a width measured where the text was composed is a
/// rule of the size the chat had when it was written - the welcome box's top line stayed at the old
/// width after a maximise and was wider than the window after a shrink, where it wraps and moves
/// everything under it (Victor, 18/11). Expanding it here, at the width the frame is drawn at, is what
/// makes it follow the terminal.
///
/// One marker is one whole row of `width` rule characters. Nothing else in the protocol emits a bare
/// \1, so this cannot touch text a tool printed.
pub fn expand_rule(line: &str, width: usize) -> String {
    const MARK: &str = "\u{1}r\u{1}";
    if !line.contains(MARK) { return line.to_string(); }
    let rule: String = std::iter::repeat('\u{2500}').take(width.max(1)).collect();
    line.replace(MARK, &rule)
}

/// A code-mode BAND row that is stored UNCUT, read back as `(fill, code)`: `lua/core/codemode_block.lua`
/// `M.band_mark` writes `\u{1}b{fill}\u{1}{code}`, where `fill` is the row's own rest-of-row sequence
/// (the band's background, then EL). The cut is this frame's (`wrap_band`), for the same reason a rule's
/// width is (`expand_rule`): a row cut when it was written is cut for good, so a maximised window showed
/// it with empty space to its right and a shrunk one cut it again (Victor 22/11). The fill travels
/// inside the row because the palette is Lua's - this file knows no colour of its own.
///
/// Nothing else in the protocol emits a bare \1, so this cannot touch text a tool printed.
fn band_row(line: &str) -> Option<(&str, &str)> {
    let rest = line.strip_prefix("\u{1}b")?;
    let end = rest.find('\u{1}')?;
    Some((&rest[..end], &rest[end + 1..]))
}

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
    // A row that is too wide only because of trailing spaces (a padded band: the code-mode block pads its
    // rows to the screen) is cut at the width, never wrapped: the wrap was a whole blank band row under
    // every code line, and under every row when a focus border took two columns (operator 17/11).
    let trailing = cells.iter().rev().take_while(|c| c.1 == ' ').count();
    if total - trailing <= width {
        let mut row = String::new();
        let mut cols = 0usize;
        for cell in &cells {
            if cols + cell.2 > width { break; }
            row.push_str(&cell.0); row.push(cell.1); cols += cell.2;
        }
        row.push_str(&esc);
        row.push_str(RESET);
        return vec![row];
    }
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

/// A fenced code card being wrapped, row by row: `\u{250c}` opens it, `\u{2514}` closes it, and the
/// `\u{2502}` rows between them are CUT by cells with the bar repeated on every continuation
/// (`\u{2502}\u{21aa}`) - never broken at a space like prose.
///
/// Why the stream and not the row alone: a quote row and a card body row open with the SAME cells
/// (`\u{2502} ` painted `777777`), so a row cannot say what it is. Only the frame can, and the frame is
/// the open/close corner rows `lua/core/markdown.lua` writes around every fence. Prose therefore wraps
/// exactly as it did: no prose row is ever inside a frame.
#[derive(Default)]
pub struct CardWrap { open: bool }

impl CardWrap {
    /// The screen rows of one line of a block. Card body rows are cut (`wrap_card`); an open or close
    /// corner stays one row and moves the frame; everything else is the prose rule, byte for byte.
    pub fn rows(&mut self, line: &str, width: usize) -> Vec<String> {
        let (cells, _) = cells_of(line);
        match card_edge(&cells, self.open) {
            Some(Edge::Open) => { self.open = true; wrap_rows(line, width) }
            Some(Edge::Close) => { self.open = false; wrap_rows(line, width) }
            Some(Edge::Body) if self.open => wrap_card(&cells, width),
            _ => wrap_rows(line, width),
        }
    }
}

/// What a line's leading glyph says about the card it belongs to.
#[derive(PartialEq)]
enum Edge { Open, Body, Close }

/// Which edge of a card `cells` opens - `None` when its first glyph past any indent and the copy icon
/// is not one of the card's own, or is not painted in the card's border colour.
/// Whether the card's border colour is set on any cell up to and including `at`. The escapes ride on
/// the row's FIRST cell for an unindented card (`paint("\u{2502} ", "mdCodeBlockBorder")` puts them before
/// the bar) and on a cell of their own for an INDENTED one (`paint(indent .. "\u{2502} ")` puts them
/// before the indent, so the bar cell itself carries no escape). Both are the same block: a check that
/// only looked at the bar cell would miss every fence nested in a list.
fn border_before(cells: &[(String, char, usize)], at: usize) -> bool {
    if cells.is_empty() { return false; }
    cells[..=at.min(cells.len() - 1)].iter().any(|c| c.0.contains(CARD_BORDER))
}

fn card_edge(cells: &[(String, char, usize)], in_frame: bool) -> Option<Edge> {
    let lead = cells.iter().position(|c| c.1 != ' ' && c.1 != COPY_ICON)?;
    if !border_before(cells, lead) { return None; }
    // A TABLE wears the same border role and must not be read as a card: its rules carry a column
    // divider or a closing corner a card never has, and its body rows END in a border bar of their own
    // (one per column plus the closing one) where a card row has only the one it opens with. Cut by
    // cells, a table row would take the continuation mark into its closing bar and lose a column.
    let table_rule = cells.iter().any(|c| matches!(c.1, '\u{252c}' | '\u{253c}' | '\u{2534}' | '\u{2510}' | '\u{2518}' | '\u{2524}'));
    let bars: Vec<usize> = cells.iter().enumerate().filter(|(_, c)| c.1 == '\u{2502}').map(|(i, _)| i).collect();
    let last_visible = cells.iter().rposition(|c| c.1 != ' ');
    // Inside a frame that is already OPEN there is no table to protect: markdown.lua never nests one,
    // so a code line that merely READS like a table row (`│ a │`) is card code and is cut - the review
    // caught it being wrapped as prose instead.
    let table_body = !in_frame && bars.len() >= 2 && last_visible == bars.last().copied();
    match cells[lead].1 {
        // The OPENING must be exact: a card's is `┌─` and nothing else, or `┌─ <lang>` with the lang from
        // the set markdown.lua accepts (fence_of: letters, digits and `+ - _ # .`). A compiler diagnostic is
        // drawn in the SAME grey (codespan/miette: `┌─ src/main.rs:3:5`), so a check that took any
        // border-coloured corner opened a frame on it and cut the prose under it by cells.
        '\u{250c}' if !table_rule && is_card_opening(cells, lead) => Some(Edge::Open),
        '\u{2514}' if !table_rule => Some(Edge::Close),
        '\u{2502}' if !table_body => Some(Edge::Body),
        _ => None,
    }
}

/// Whether the row from `lead` is a card's OWN opening: `┌─`, or `┌─ <lang>` where the lang is what
/// `lua/core/markdown.lua` `fence_of` accepts (letters, digits, `+ - _ # .`) - nothing else. This is what
/// keeps a dim compiler diagnostic (`┌─ src/main.rs:3:5`, the same grey role) from opening a card frame.
fn is_card_opening(cells: &[(String, char, usize)], lead: usize) -> bool {
    let text: String = cells[lead..].iter().map(|c| c.1).collect();
    // The copy icon after the corner (`icon_after_corner`: `┌─ ⧉ bash`) is the host's own cell, not
    // part of the title: the opening is judged without it.
    let text = text.replacen(&format!(" {COPY_ICON}"), "", 1);
    let Some(rest) = text.strip_prefix("\u{250c}\u{2500}") else { return false };
    if rest.is_empty() { return true; }
    let Some(lang) = rest.strip_prefix(' ') else { return false };
    !lang.is_empty() && lang.chars().all(|c| c.is_alphanumeric() || matches!(c, '+' | '-' | '_' | '#' | '.'))
}

/// One printable character and the escapes just before it, with its width: the parse `wrap_rows` does.
fn cells_of(line: &str) -> (Vec<(String, char, usize)>, String) {
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
    (cells, esc)
}

/// A card BODY row cut to `width` cells: its border is repeated on every continuation
/// (`\u{2502}\u{21aa}`) and the row is cut by CELLS, never at a space. Breaking at a space is what broke
/// Victor's card (19/11): the space after the bar is a space, so the prose rule kept the bar alone on
/// one row and drew the code on the next without it.
///
/// The colour active where the row was cut is closed with `RESET` and reopened after the bar, so no row
/// paints outside its own cells; the bar's own colour is set from `CARD_BORDER`, so a `RESET` never
/// leaves a continuation in the terminal's default colour.
fn wrap_card(cells: &[(String, char, usize)], width: usize) -> Vec<String> {
    // A row that is too wide only by its own PADDING is cut at the width, never continued. The diff
    // card pads every row so its band covers the whole width, and the frame is one column narrower
    // whenever the scrollbar is drawn - so without this every padded row grew an empty continuation
    // row and the card came out twice as tall (measured 23/11: a 30-line card drew 61 rows).
    // `wrap_rows` has the same rule for a padded band row; this is its card twin.
    let total: usize = cells.iter().map(|c| c.2).sum();
    let padding = cells.iter().rev().take_while(|c| c.1 == ' ').count();
    if total > width && total - padding <= width {
        let (mut row, mut cols) = (String::new(), 0usize);
        for cell in cells {
            if cols + cell.2 > width { break; }
            row.push_str(&cell.0); row.push(cell.1); cols += cell.2;
        }
        row.push_str(RESET);
        return vec![row];
    }
    // The prefix is the indent, the bar and the blank after it; the code starts where the view put it.
    let bar = cells.iter().position(|c| c.1 == '\u{2502}').unwrap_or(0);
    let mut start = bar + 1;
    if cells.get(start).is_some_and(|c| c.1 == ' ') { start += 1; }
    // The indent as the renderer wrote it (blank cells before the bar; a copy icon in front of a fence
    // title row is not one). A continuation of an INDENTED card sits at the same column as the row it
    // continues: the view writes a fence inside a list at its item's indent (markdown.lua `opts.indent`).
    let indent: String = cells[..bar].iter().filter(|c| c.1 != COPY_ICON).map(|c| c.1).collect();
    let indent_cols: usize = cells[..bar].iter().filter(|c| c.1 != COPY_ICON).map(|c| c.2).sum();
    let mut rows: Vec<String> = Vec::new();
    let mut row = String::new();
    let mut sgr = String::new();
    let mut cols = 0usize;
    for cell in &cells[..start.min(cells.len())] {
        row.push_str(&cell.0); row.push(cell.1); cols += cell.2;
    }
    let mut i = start.min(cells.len());
    // `fresh`: this row already carries the continuation bar, so a cell too wide for what is left of it
    // still goes on it - a cell cannot be split, and a loop that refused it would spin forever.
    let mut fresh = false;
    while i < cells.len() {
        let w = cells[i].2;
        if !fresh && cols + w > width && i > start {
            row.push_str(RESET);
            rows.push(std::mem::take(&mut row));
            row.push_str(CARD_BORDER); row.push_str(&indent); row.push('\u{2502}'); row.push('\u{21aa}'); row.push_str(RESET);
            row.push_str(&sgr);
            cols = indent_cols + 2;
            fresh = true;
            continue;
        }
        row.push_str(&cells[i].0);
        row.push(cells[i].1);
        track(&cells[i].0, &mut sgr);
        cols += w;
        fresh = false;
        i += 1;
    }
    row.push_str(RESET);
    rows.push(row);
    rows
}

/// The mark a BLOCK row shows when its line continues on the next row: the LEFT GUTTER of the
/// continuation row, never inside the text of the row that was cut (Victor 22/11 - it used to sit in
/// the last cell of the cut row here and in the gutter in a fence, two marks for one fact). The fence's
/// `wrap_card` writes the same glyph in the same place: one cell in front of the text column.
const CONTINUE_MARK: char = '\u{21aa}';

/// A code-mode BAND row cut to `width` cells: the row that is cut keeps its WHOLE width (the mark is
/// never paid for out of it) and every row after it opens with `\u{21aa}` in the gutter and the band's
/// `fill` at its end, so a long script line reads as one line broken and the block is a solid band on
/// every one of its rows. The colour active where it was cut is reopened after the mark, so the rest of
/// a cut token keeps its own syntax colour.
fn wrap_band(cells: &[(String, char, usize)], width: usize, fill: &str) -> Vec<String> {
    let width = width.max(1);
    let mut rows: Vec<String> = Vec::new();
    let mut row = String::new();
    let mut sgr = String::new();
    let mut cols = 0usize;
    let mut i = 0usize;
    loop {
        while i < cells.len() {
            let w = cells[i].2;
            // `cols > 0`: a cell wider than the whole row still goes on it. A cell cannot be split, and
            // a loop that refused it would spin forever.
            if cols + w > width && cols > 0 { break; }
            row.push_str(&cells[i].0);
            row.push(cells[i].1);
            track(&cells[i].0, &mut sgr);
            cols += w;
            i += 1;
        }
        row.push_str(fill);
        rows.push(std::mem::take(&mut row));
        if i >= cells.len() { break; }
        row.push_str(&sgr);
        row.push_str(DIM);
        row.push(CONTINUE_MARK);
        row.push_str(&sgr);
        cols = 1;
    }
    rows
}
/// `line` cut to ONE screen row of at most `width` cells, escapes kept whole and a continuation
/// mark where it was cut: the rule for every STATUS row, and the reason it is a clip.
///
/// A row whose text changes must not change HEIGHT. The running call's line is rewritten in place
/// every quarter second (its clock, the tail of its output), and while it was wrapped like prose each
/// new tail could add a row - which moved every row above and below it, the bounce Victor reported on
/// 19/11. Clipped, the row is one row whatever it says, and the full output still lands in the block
/// when the call settles.
fn clip_row(line: &str, width: usize) -> String {
    let width = width.max(1);
    if width == 1 { return wrap_rows(line, 1).remove(0).chars().next().map(String::from).unwrap_or_default(); }
    let mut rows = wrap_rows(line, width);
    if rows.len() <= 1 { return rows.pop().unwrap_or_default(); }
    // Make room for the mark FIRST, so the row cannot come out `width`+1 and wrap after all.
    let mut first = wrap_rows(line, width - 1).into_iter().next().unwrap_or_default();
    first.push('\u{2026}');
    first
}

/// The bottom row of the region with the jump-to-bottom pill over it: the row's own leading cells
/// are kept (so the text under the pill is not lost needlessly), then the pill, centred on the
/// chat's columns - never over the scrollbar's. Answers the row and the columns the pill covers,
/// 1-based and inclusive, which is what a press is measured against.
fn pill_row(row: &str, text: &str, text_width: usize) -> (String, (usize, usize)) {
    let pill = format!(" {text} ");
    let cells: usize = pill.chars().map(cell_width_of).sum();
    let left = text_width.saturating_sub(cells) / 2;
    let (row_cells, _) = cells_of(row);
    let mut out = String::new();
    let mut used = 0usize;
    for (esc, ch, w) in row_cells.iter() {
        if used + w > left { break }
        out.push_str(esc);
        out.push(*ch);
        used += w;
    }
    while used < left { out.push(' '); used += 1; }
    let from = used + 1;
    out.push_str(&format!("{PILL}{pill}{RESET}\x1b[K"));
    (out, (from, used + cells))
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
pub enum NavKey { None, Up, Down, Right, Left, Pin, Exit, PageUp, PageDown, Bottom, Other(Vec<u8>) }

#[derive(Default)]
pub struct NavDecoder { escape: Vec<u8> }

impl From<crate::keymap::NavAct> for NavKey {
    /// The transcript's acts, as this decoder's caller names them - the one place the two spellings
    /// of the same act meet. The match is exhaustive, so an act the table adds cannot be forgotten.
    fn from(act: crate::keymap::NavAct) -> NavKey {
        use crate::keymap::NavAct as A;
        match act {
            A::Prev => NavKey::Up,
            A::Next => NavKey::Down,
            A::Expand => NavKey::Right,
            A::Fold => NavKey::Left,
            A::PageUp => NavKey::PageUp,
            A::PageDown => NavKey::PageDown,
            A::Bottom => NavKey::Bottom,
            A::Pin => NavKey::Pin,
            A::Back => NavKey::Exit,
        }
    }
}

impl NavDecoder {
    pub fn feed(&mut self, byte: u8) -> NavKey {
        if !self.escape.is_empty() {
            self.escape.push(byte);
            let sequence = self.escape.clone();
            // Two Escapes are the key twice, not a sequence: Esc leaves the blocks.
            if sequence.len() == 2 && byte != b'[' && byte != b'O' {
                self.escape.clear();
                return match crate::keymap::nav_byte(byte) { Some(act) => NavKey::from(act), None => NavKey::Other(vec![byte]) };
            }
            if sequence.len() >= 3 && (0x40..=0x7e).contains(&byte) {
                self.escape.clear();
                return match crate::keymap::nav_seq(&sequence) { Some(act) => NavKey::from(act), None => NavKey::None };
            }
            if sequence.len() > 16 { self.escape.clear(); }
            return NavKey::None;
        }
        // Esc can begin a sequence, so it only starts the buffer: what a lone one means is the
        // console's question (`lone_escape`).
        if byte == 0x1b { self.escape.push(byte); return NavKey::None; }
        match crate::keymap::nav_byte(byte) { Some(act) => NavKey::from(act), None => NavKey::Other(vec![byte]) }
    }
    /// A lone Esc (nothing followed it).
    pub fn lone_escape(&mut self) -> bool { let lone = self.escape.as_slice() == b"\x1b"; if lone { self.escape.clear(); } lone }
}

/// `row` with its last visible blank cell turned into the copy icon, kept inside whatever colours the
/// row paints there (the band's background), and the icon's 1-based column. None when the row ends in
/// text: the icon never covers code.
fn icon_at_right(row: &str) -> Option<(String, usize)> {
    let chars: Vec<char> = row.chars().collect();
    // The char index of every visible cell, escape sequences skipped.
    let mut cells: Vec<usize> = Vec::new();
    let mut i = 0usize;
    while i < chars.len() {
        if chars[i] == '\x1b' {
            i += 1;
            if i < chars.len() && chars[i] == '[' { i += 1; while i < chars.len() && !('@'..='~').contains(&chars[i]) { i += 1; } }
            else if i < chars.len() && chars[i] == ']' { while i < chars.len() && chars[i] != '\x07' && chars[i] != '\\' { i += 1; } }
            i += 1;
            continue;
        }
        cells.push(i);
        i += 1;
    }
    // Two blank cells at the end at least, so the icon never touches the code.
    let n = cells.len();
    if n < 2 || chars[cells[n - 1]] != ' ' || chars[cells[n - 2]] != ' ' { return None }
    let at = cells[n - 1];
    let mut out: String = chars[..at].iter().collect();
    out.push(COPY_ICON);
    out.extend(chars[at + 1..].iter());
    Some((out, n))
}

/// A fenced card's opening row (`┌─ bash`, after any indent and colour) with the copy icon between
/// the corner and the title: `┌─ ⧉ bash`, and the icon's 1-based column. None when the row does not
/// open with `┌─` - then the icon is the row's prefix, as for every other copyable line.
///
/// Why this is the host's to do (Victor 21/11, "we were never able to fix it"): the Lua marker says
/// only WHICH line can be copied and with what content; the column was chosen here, by prefixing
/// `COPY_PREFIX` to the row, and `copy_at` accepted a click in the first two cells only. A fence
/// redrawn on the Lua side could never move the icon.
fn icon_after_corner(row: &str) -> Option<(String, usize)> {
    let chars: Vec<char> = row.chars().collect();
    let (mut i, mut col) = (0usize, 0usize);
    while i < chars.len() {
        if chars[i] == '\x1b' {
            i += 1;
            if i < chars.len() && chars[i] == '[' { i += 1; while i < chars.len() && !('@'..='~').contains(&chars[i]) { i += 1; } }
            i += 1;
            continue;
        }
        if chars[i] == ' ' { i += 1; col += 1; continue; }
        break;
    }
    if chars.get(i) != Some(&'\u{250c}') || chars.get(i + 1) != Some(&'\u{2500}') { return None }
    let after = i + 2;
    let mut out: String = chars[..after].iter().collect();
    out.push(' ');
    out.push(COPY_ICON);
    // `┌─ bash` already has its space before the title; an untitled `┌─` gets none after the icon.
    out.extend(chars[after..].iter());
    Some((out, col + 4))
}

/// The copy icon at the right end of a BAND row: a row that ends with the background-colour erase
/// (ESC[K) has no blank cell for icon_at_right to take, because the band paints its rest with no
/// characters at all (item F). The icon is placed by column instead, on the row's own line, with the
/// band's colour still open, so it wears the band and not the terminal default.
fn icon_at_band_end(row: &str, width: usize) -> Option<(String, usize)> {
    if width < 2 || !row.ends_with("\u{1b}[K") { return None }
    // One column short of the width, so the icon sits at the band's right edge with a cell to spare.
    let column = width.saturating_sub(1).max(1);
    Some((format!("{row}\u{1b}[{column}G{COPY_ICON}"), width))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One CARD block exactly as lua/core/cli_view.lua writes it: a bare opening corner, the heading,
    /// the count row, the numbered body, the closing corner and the blank row under it - with the body
    /// range marked, which is what host.transcript_card carries (0-based, the lines of that write).
    fn card_block(t: &mut Transcript, lines: usize) {
        t.block(true);
        let mut text = String::from("\u{250c}\u{2500}\n");
        text.push_str("\u{2502} \u{25cf} Create(demo.py)\n");
        text.push_str(&format!("\u{2502} Added {lines} lines\n"));
        for i in 1..=lines {
            text.push_str(&format!("\u{2502} {i:2} + value_{i:02} = {i}\n"));
        }
        text.push_str("\u{2514}\u{2500}\n\n");
        t.cardable(&[(3, 2 + lines)]);
        t.write(&text);
    }

    #[test]
    fn a_card_is_drawn_open_not_folded_to_three_rows() {
        let mut t = plain(Transcript::default());
        card_block(&mut t, 12);
        let rows = t.view(60, 30);
        let text = rows.join("\n");
        assert!(text.contains("Create(demo.py)"), "the heading is drawn: {text}");
        assert!(text.contains("value_01") && text.contains("value_12"),
            "every line of a card is drawn, not the topic's three rows: {text}");
        assert!(!text.contains("(ctrl+o") && !text.contains("\u{2026} +"),
            "and nothing is counted away: {text}");
    }

    #[test]
    fn a_card_past_the_bound_counts_the_lines_it_hid_and_a_press_opens_it() {
        let mut t = plain(Transcript::default());
        card_block(&mut t, 60);
        let rows = t.view(60, 120);
        let text = rows.join("\n");
        assert!(text.contains("value_01") && text.contains("value_40"), "the first CARD_ROWS lines: {text}");
        assert!(text.contains(&format!("\u{2026} +{} lines (ctrl+o to expand)", 60 - CARD_ROWS)), "{text}");
        assert!(!text.contains("value_41"), "the rest is not drawn: {text}");
        // A press on the counting row opens the whole card - the lines were never dropped.
        let at = (1..=rows.len()).find(|&r| rows[r - 1].contains("ctrl+o to expand"))
            .expect("the counting row is on screen");
        assert!(t.expand_at(at), "the counting row answers a press");
        let open = t.view(60, 200).join("\n");
        assert!(open.contains("value_60") && !open.contains("ctrl+o to expand"),
            "every line, and no counting row left: {open}");
        // A second press - on the body the first one opened - folds it back, so a reader is never
        // stuck open (the rule `expandable` uses for an opened result).
        let rows = t.view(60, 120);
        let at = (1..=rows.len()).find(|&r| rows[r - 1].contains("value_05"))
            .expect("the opened body is on screen");
        assert!(t.expand_at(at), "a press on the opened body folds the card");
        let folded = t.view(60, 120).join("\n");
        assert!(folded.contains("ctrl+o to expand") && !folded.contains("value_60"), "{folded}");
    }

    #[test]
    fn ctrl_o_opens_the_newest_card_and_the_same_key_folds_it() {
        let mut t = plain(Transcript::default());
        card_block(&mut t, 60);
        let _ = t.view(60, 120);
        assert_eq!(t.pin_toggle(), Some(true), "Ctrl+O on the newest card opens it");
        let open = t.view(60, 200).join("\n");
        assert!(open.contains("value_60") && !open.contains("ctrl+o to expand"),
            "the whole card is drawn: {open}");
        assert_eq!(t.pin_toggle(), Some(false), "and the same key folds it again");
        let folded = t.view(60, 120).join("\n");
        assert!(folded.contains("ctrl+o to expand") && !folded.contains("value_60"),
            "back to the counting row: {folded}");
    }

    #[test]
    fn ctrl_o_opens_a_folded_script_output_row_and_the_same_key_folds_it() {
        // Victor 23/11: "script output should show 'script output · <n> chars' so we can expand". The
        // row's own press opens it (expand_at); this key does the same thing to the newest block, and
        // the same press folds it back, so "click or Ctrl+O" is one behaviour with two doors.
        let mut t = plain(Transcript::default());
        t.code_block();
        t.expandable(&[(0, "value_01\nvalue_02\nvalue_03".to_string())]);
        t.write("\u{23bf} script output \u{b7} 26 chars\n");
        let folded = t.view(60, 20).join("\n");
        assert!(folded.contains("script output"), "the folded row is drawn: {folded}");
        assert!(!folded.contains("value_02"), "and its lines are not: {folded}");
        assert_eq!(t.pin_toggle(), Some(true), "Ctrl+O opens the folded result");
        let open = t.view(60, 20).join("\n");
        assert!(open.contains("value_01") && open.contains("value_03"),
            "the whole result is drawn in its place: {open}");
        assert_eq!(t.pin_toggle(), Some(false), "and the same key folds it back");
        let again = t.view(60, 20).join("\n");
        assert!(again.contains("script output") && !again.contains("value_02"),
            "back to the one row: {again}");
    }

    #[test]
    fn a_block_without_a_folded_row_keeps_ctrl_o_as_its_pin() {
        // The key still pins a code block that has no result line of its own: the new branch must not
        // take the key away from every block.
        let mut t = plain(Transcript::default());
        t.code_block();
        t.write("const x = 1;\n");
        assert_eq!(t.pin_toggle(), Some(true), "Ctrl+O pins a block with nothing to fold");
        assert_eq!(t.pin_toggle(), Some(false), "and the same key lets it go");
    }

    #[test]
    fn a_card_keeps_one_blank_row_above_and_below_it() {
        let mut t = plain(Transcript::default());
        card_block(&mut t, 3);
        t.block(false);
        t.write("done\n");
        let rows: Vec<String> = t.view(60, 20).iter().map(|row| crate::selection::plain(row)).collect();
        let open = rows.iter().position(|row| row.contains('\u{250c}')).expect("the card's opening row");
        let close = rows.iter().position(|row| row.contains('\u{2514}')).expect("the card's closing row");
        assert_eq!(rows[open - 1].trim(), "", "one blank row ABOVE the card: {rows:?}");
        assert_eq!(rows[close + 1].trim(), "", "and one BELOW it: {rows:?}");
        assert_eq!(rows[close + 2].trim(), "done", "so the next text is never glued to it: {rows:?}");
    }

    #[test]
    fn a_card_is_cut_at_the_width_it_is_drawn_at_and_keeps_its_gap() {
        let mut t = plain(Transcript::default());
        card_block(&mut t, 6);
        let narrow = t.view(40, 20);
        for row in &narrow {
            assert!(visible(row) <= 40, "every row fits the frame it is drawn in: {row:?}");
        }
        let text: Vec<String> = narrow.iter().map(|row| crate::selection::plain(row)).collect();
        assert!(text.iter().any(|row| row.contains("value_06")), "the card is still whole: {text:?}");
        let close = text.iter().position(|row| row.contains('\u{2514}')).expect("the closing row");
        assert_eq!(text[close + 1].trim(), "", "and the gap survives the resize: {text:?}");
    }
    /// A transcript with the scrollbar off: the tests that read rows for their TEXT (a page step, a
    /// fold, the bottom anchor) are not about the bar, and the bar's own tests set it. What the bar
    /// adds to a row is one column at the end (`view`), so a test that compared whole rows would
    /// otherwise be asserting the bar's width in every one of them.
    fn plain(mut t: Transcript) -> Transcript { t.scrollbar = Scrollbar::Hidden; t }
    /// The welcome block is a TRANSCRIPT BLOCK since item 1 of tui-fit (`lua/core/cli_view.lua`
    /// `METHODS:welcome`): written ONCE, with the rule left as the marker, and drawn again at every
    /// frame's own width. That is what lets a resized window show the banner at the new width instead of
    /// re-wrapping the row the old width left in the terminal - the stray "─" under the rule (Victor,
    /// 21/11). Nothing here measures a width at composition time, in either direction.
    #[test]
    fn a_block_written_once_draws_its_rule_at_the_width_of_the_frame() {
        let mut t = plain(Transcript::default());
        t.block(false);
        t.write("\u{1}r\u{1}\n\u{2605} Welcome to wasm-agent!\ncwd: ~/work\n");
        for width in [80usize, 60, 200] {
            let rows = t.view(width, 10);
            let rule = rows
                .iter()
                .find(|row| row.chars().filter(|c| *c == '\u{2500}').count() > 0)
                .unwrap_or_else(|| panic!("no rule row at {width}: {rows:?}"));
            assert_eq!(
                rule.matches('\u{2500}').count(),
                width,
                "the rule is the frame's width at {width}, not the width it was written at: {rows:?}"
            );
            let count: Vec<usize> = rows
                .iter()
                .map(|row| row.chars().filter(|c| *c == '\u{2500}').count())
                .filter(|n| *n > 0)
                .collect();
            assert_eq!(count, vec![width], "one rule, exactly the width, at {width}: {rows:?}");
            assert!(
                rows.iter().any(|row| row.contains("Welcome to wasm-agent")),
                "the banner itself is drawn at {width}: {rows:?}"
            );
        }
    }

    #[test]
    fn a_fence_keeps_its_corner_and_the_icon_sits_after_it() {
        assert_eq!(icon_after_corner("\x1b[2m\u{250c}\u{2500} bash\x1b[0m"),
            Some(("\x1b[2m\u{250c}\u{2500} \u{29c9} bash\x1b[0m".to_string(), 4)), "the icon is the fourth cell");
        assert_eq!(icon_after_corner("  \u{250c}\u{2500}"), Some(("  \u{250c}\u{2500} \u{29c9}".to_string(), 6)),
            "an indented, untitled fence");
        assert_eq!(icon_after_corner("a heading"), None, "any other copyable line keeps the prefix");
        // Through the real rows: the corner is the row's first cell, and only the icon's cell copies.
        let mut t = Transcript::default();
        t.copyable(&[(0, "echo one".to_string())]);
        t.write("\u{250c}\u{2500} bash\n\u{2502} echo one\n\u{2514}\u{2500}\n");
        let rows = t.view(40, 10);
        let row = rows.iter().position(|r| crate::selection::plain(r).starts_with("\u{250c}\u{2500} \u{29c9} bash")).expect("the fence's first row") + 1;
        assert_eq!(t.copy_at(row, 4).as_deref(), Some("echo one"));
        assert_eq!(t.copy_at(row, 1), None, "the corner is not the icon");
    }
    #[test]
    fn a_copy_icon_under_the_pointer_is_drawn_bright() {
        let mut t = plain(Transcript::default());
        t.copyable(&[(0, "body".to_string())]);
        t.write("title\nline\n");
        let _ = t.view(40, 5);
        let row = (1..=5).find(|r| t.copy_at(*r, 1).is_some()).expect("icon row");
        assert!(t.copy_hover(row, 1));
        let shown = t.view(40, 5);
        assert!(shown[row - 1].contains("\x1b[1;97m\u{29c9}"), "{:?}", shown[row - 1]);
        assert!(!t.copy_hover(row, 1), "no change, no frame");
        assert!(t.copy_hover(row, 30));
    }
    #[test]
    fn the_code_copy_icon_takes_the_last_blank_cell_and_never_covers_code() {
        let band = "\x1b[48;5;236mreturn 1;     \x1b[0m";
        let (row, col) = icon_at_right(band).expect("blank cells at the end");
        assert_eq!(col, 14);
        assert!(row.contains("return 1;    \u{29c9}\x1b[0m"), "{row:?}");
        assert!(icon_at_right("\x1b[48;5;236mreturn 1;\x1b[0m").is_none());
        assert!(icon_at_right("x ").is_none());
    }
    #[test]
    fn a_marker_in_a_newer_block_maps_to_its_own_screen_row() {
        let mut t = plain(Transcript::default());
        t.block(false);
        t.write("one\ntwo\nthree\n");
        t.block(true);
        t.expandable(&[(1, "full".to_string())]);
        t.write("code\nresult\n");
        let rows = t.view(40, 10);
        let at = rows.iter().position(|r| r.contains("result")).unwrap() + 1;
        assert!(t.expand_rows.contains_key(&at), "the press on the result's row is the expand: {:?} at {at}", t.expand_rows);
        assert!(t.expand_at(at));
    }
    #[test]
    fn an_expandable_line_is_one_row_brightens_under_the_pointer_and_opens_on_a_click() {
        let mut t = plain(Transcript::default());
        t.block(false);
        t.write("before\n");
        t.expandable(&[(0, "\u{23bf} {\"a\":1,\n  \"b\":2}".to_string())]);
        t.write("\u{23bf} {\"a\":1,\u{2026} +9 chars\nafter\n");
        let rows = t.view(40, 3);
        assert_eq!(rows.len(), 3);
        assert!(rows[1].contains("+9 chars"), "folded to its one row: {rows:?}");
        // The pointer on it: drawn bright; off it: plain again.
        assert!(t.expand_hover(2));
        let lit = t.view(40, 3);
        assert!(lit[1].starts_with(BRIGHT), "bright under the pointer: {lit:?}");
        assert!(t.expand_hover(1));
        assert!(!t.view(40, 3)[1].starts_with(BRIGHT));
        // A click opens it in place - the full text, two rows - and a second click folds it again.
        assert!(!t.expand_at(1), "a press on another row is not an expand");
        assert!(t.expand_at(2));
        let open = t.view(40, 4);
        assert!(open.iter().any(|r| r.contains("\"b\":2")), "opened: {open:?}");
        assert!(!open.iter().any(|r| r.contains("+9 chars")));
        let row = (1..=4).find(|&r| t.expand_rows.contains_key(&r)).expect("the opened rows still answer a click");
        assert!(t.expand_at(row));
        assert!(t.view(40, 3)[1].contains("+9 chars"), "folded again");
    }
    #[test]
    fn a_band_too_wide_only_by_its_padding_is_cut_not_wrapped() {
        // The code-mode band, padded to 79 columns, inside a focus border (78) or a narrower screen.
        let band = format!("\x1b[48;5;236mconst r = 1;{}\x1b[0m", " ".repeat(67));
        let rows = wrap_rows(&band, 78);
        assert_eq!(rows.len(), 1, "no blank second row: {rows:?}");
        assert_eq!(crate::selection::plain(&rows[0]).chars().count(), 78);
        // Text that really is too wide still wraps.
        assert_eq!(wrap_rows("abcdefghij", 4).len(), 3);
        assert_eq!(wrap_rows("ab  ", 3).len(), 1);
    }
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
    /// The rows the thumb is on: at rest it is `┃` (`scroll::bar`), joined to the `│` track.
    fn thumb_rows(view: &[String]) -> Vec<usize> {
        (0..view.len()).filter(|&at| view[at].ends_with("\u{2503}\u{1b}[0m") || view[at].ends_with("\u{2588}\u{1b}[0m")).collect()
    }
    fn bar_rows(view: &[String]) -> usize {
        view.iter().filter(|row| row.ends_with("\u{2503}\u{1b}[0m") || row.ends_with("\u{2588}\u{1b}[0m")
            || row.ends_with("\u{2502}\u{1b}[0m")).count()
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
    // ---- the bar takes the mouse (operator, 13/11 ~06:50) ---------------------------------------
    // The same bar, now a handle: a click on the track jumps there, a drag on the thumb scrolls,
    // and the thumb is thick while the pointer is on it (`scroll::bar` has the arithmetic and the
    // rules; this is the transcript's side of them). What must not change: a press that is not in
    // the bar's column is still the start of a text selection.
    /// A row's text, without the escapes and without the bar's column.
    fn text_of(row: &str) -> String {
        crate::selection::plain(row).trim_end()
            .trim_end_matches(['\u{2502}', '\u{2503}', '\u{2588}']).trim_end().to_string()
    }

    #[test]
    fn the_bars_column_takes_a_click_and_a_drag_and_nothing_else_is_the_bars() {
        let mut t = Transcript::default();
        for n in 0..100 { t.write(&format!("line {n}\n")); }
        let bottom = t.view(40, 10);
        assert_eq!(bar_rows(&bottom), 10, "a bar on every row of the region: {bottom:?}");
        // A press in the text, or where there is no bar at all, is not the bar's: the host keeps it
        // for the selection it has always started.
        assert!(!t.bar_press(2, 20, 40), "a press in the chat's text is not the bar's");
        assert!(!t.bar_press(2, 41, 40), "past the last column is not the bar's either");
        assert!(!t.bar_press(2, 40, 1), "a screen one column wide has no bar");
        // The bar's column, two rows down: the thumb's middle comes to the pointer, which is the
        // top of the chat, and the press is held as a grab.
        assert!(t.bar_press(2, 40, 40), "a press in the bar's column is the bar's");
        let at_top = t.view(40, 10);
        assert_eq!(text_of(&at_top[0]), "line 0", "the click jumped to the top: {at_top:?}");
        // Still held, moved down to the last row: the newest output, and following again.
        assert!(t.bar_drag(10), "a drag that began on the bar scrolls it");
        let at_bottom = t.view(40, 10);
        assert_eq!(text_of(&at_bottom[9]), "line 99", "the drag's end is the newest output: {at_bottom:?}");
        assert!(t.following(), "at the bottom the transcript follows new output again");
        assert!(t.bar_release(), "the button came up on the bar");
        assert!(!t.bar_drag(5), "and a drag after the release does not belong to the bar");
        // A chat that fits its region has no scroll position to move, so its bar takes nothing.
        let mut short = Transcript::default();
        short.write("one\ntwo\n");
        short.scrollbar = Scrollbar::Always;
        short.view(40, 10);
        assert!(!short.bar_press(3, 40, 40), "nothing to scroll, nothing to press");
    }

    #[test]
    fn the_thumb_is_thick_under_the_pointer_and_thin_when_it_leaves() {
        let mut t = Transcript::default();
        for n in 0..100 { t.write(&format!("line {n}\n")); }
        let rest = t.view(40, 10);
        assert!(thumb_rows(&rest).len() >= 2, "at rest: a thin thumb on the track: {rest:?}");
        assert!(!rest.iter().any(|row| row.ends_with("\u{2588}\u{1b}[0m")), "and nothing thick: {rest:?}");
        // The pointer arrives on the bar's column: a redraw, and the thumb is a block.
        assert!(t.bar_hover(5, 40, 40), "the pointer arrived: redraw");
        let hovered = t.view(40, 10);
        assert_eq!(thumb_rows(&hovered), thumb_rows(&rest), "the same rows: the thumb did not move");
        assert!(hovered.iter().any(|row| row.ends_with("\u{2588}\u{1b}[0m")), "thicker where it was: {hovered:?}");
        assert!(!hovered.iter().any(|row| row.ends_with("\u{2503}\u{1b}[0m")), "and the thin glyph is gone");
        // A pointer that stays on the bar costs no frame; one that leaves thins the thumb again.
        assert!(!t.bar_hover(6, 40, 40), "still on the bar: nothing changed");
        assert!(t.bar_hover(5, 20, 40), "the pointer left the column: redraw");
        let thin = t.view(40, 10);
        assert!(!thin.iter().any(|row| row.ends_with("\u{2588}\u{1b}[0m")), "thin again: {thin:?}");
        assert_eq!(thumb_rows(&thin), thumb_rows(&rest), "in the same rows");
    }

    #[test]
    fn every_row_of_the_track_writes_its_glyph_at_the_columns_own_position() {
        // The operator's break in the track: a row whose text the terminal draws one cell wider than
        // `cell_width` counts wraps, and a glyph that is part of the row's text wraps with it. The
        // render writes the bar's cell again at an absolute column, so the column is one line.
        let mut t = Transcript::default();
        for n in 0..100 { t.write(&format!("line {n}\n")); }
        t.write("done \u{2705} and more\n"); // U+2705: one cell here, two in most terminals
        let frame = t.render(40, 10);
        let bar = t.bar().expect("a long chat draws the bar");
        for (row, (glyph, colour)) in bar.cells().iter().enumerate() {
            let at = format!("\x1b[{};40H{colour}{glyph}", row + 1);
            assert!(frame.contains(&at), "row {} writes its bar at column 40 and no other: {at:?} in {frame:?}", row + 1);
        }
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
    fn a_code_mode_block_is_open_while_it_runs_and_one_row_after() {
        let mut t = Transcript::default();
        t.code_block();
        t.write("\u{23fa} Code \u{b7} bash                                                     1.2s\n");
        t.write("  const files = await tools.ls({path: 'lua/core'});\n");
        t.write("  \u{2713} bash \u{b7} $ ls lua/core \u{b7} 210ms\n");
        t.write("\u{23bf} {\"count\":2,\"first\":\"chat.lua\"}\n");
        let open = t.view(80, 24).join("\n");
        assert!(open.contains("Code \u{b7} bash") && open.contains("ls lua/core")
            && open.contains("\"count\":2"), "the running block is open, all of it: {open}");
        assert!(!open.contains("+2 lines"), "and folds none of its own rows: {open}");
        // The next code-mode call starts: this one collapses to the ONE row the view built for it.
        let summary = "\u{23fa} Code \u{b7} bash \u{2713} \u{b7} 1.2s \u{2192} {\"count\":2}";
        assert!(t.fold_code(summary), "the block before the new one folds");
        t.code_block();
        t.write("\u{23fa} Code \u{b7} grep\n");
        t.write("  return hits.count;\n");
        let screen = t.view(80, 24);
        let text = screen.join("\n");
        assert!(text.contains(summary), "the older block is its summary row: {text}");
        assert!(!text.contains("ls lua/core") && !text.contains("const files"),
            "and none of its rows are drawn: {text}");
        assert!(text.contains("grep") && text.contains("hits.count"), "the new one is open: {text}");
        assert_eq!(screen.iter().filter(|row| row.contains("\u{23fa} Code")).count(), 2,
            "two headings, one row for the collapsed one: {text}");
    }

    #[test]
    fn a_pinned_code_mode_block_survives_the_next_one() {
        let mut t = Transcript::default();
        t.code_block();
        t.write("\u{23fa} Code \u{b7} bash\n");
        t.write("  const files = await tools.ls({path: 'lua/core'});\n");
        assert_eq!(t.pin_toggle(), Some(true), "Ctrl+O pins the newest code-mode block");
        assert!(!t.fold_code("\u{23fa} Code \u{b7} bash \u{2713} \u{b7} 1.2s"),
            "a pinned block is not collapsed when the next one starts");
        t.code_block();
        t.write("\u{23fa} Code \u{b7} grep\n");
        t.write("  return 1;\n");
        let text = t.view(80, 24).join("\n");
        assert!(text.contains("tools.ls"), "the pinned block keeps every row: {text}");
        assert!(text.contains("return 1"), "and the newer one is open beside it: {text}");
        // Ctrl+O again lets it go: focus it (newest topic first, then the older one) and toggle.
        assert!(t.focus_prev(), "the newest topic is the code block that is running");
        assert!(t.focus_prev(), "and the one before it is the pinned block");
        assert_eq!(t.pin_toggle(), Some(false), "Ctrl+O again unpins it");
        t.unfocus();
        assert!(t.fold_code("\u{23fa} Code \u{b7} grep \u{2713}"), "now the next block collapses it");
        let after = t.view(80, 24).join("\n");
        assert!(!after.contains("tools.ls"), "to its summary row: {after}");
    }

    #[test]
    fn rewriting_a_row_flips_a_running_call_in_place() {
        let mut t = Transcript::default();
        t.code_block();
        t.write("\u{23fa} Code \u{b7} bash\n");
        t.write("  \u{23f3} bash \u{b7} $ wc -l a.txt\n");
        let before = t.view(80, 24);
        assert!(before.join("\n").contains("\u{23f3} bash"), "the call is drawn as running: {before:?}");
        assert!(t.rewrite(-1, "  \u{2713} bash \u{b7} $ wc -l a.txt \u{b7} 210ms"),
            "its own row is rewritten in place");
        let after = t.view(80, 24);
        assert!(after.join("\n").contains("\u{2713} bash \u{b7} $ wc -l a.txt \u{b7} 210ms"),
            "to the settled row: {after:?}");
        let rows = |view: &Vec<String>| view.iter().filter(|row| visible(row) > 0).count();
        assert_eq!(rows(&after), rows(&before), "without adding or removing a row: {after:?}");
        assert!(!t.rewrite(-99, "x"), "an offset past the block rewrites nothing");
        // A row REWRITTEN with an expand marker waiting opens on a click like a written one (a run
        // block's call row learns its output when it settles); rewritten without one it is plain.
        t.expandable(&[(0, "  \u{2713} bash\n    line 1\n    line 2".to_string())]);
        assert!(t.rewrite(-1, "  \u{2713} bash"));
        let folded = t.view(60, 12);
        let row = (1..=12).find(|&r| t.expand_rows.contains_key(&r)).expect("the rewritten row answers a click");
        assert!(!folded.join("\n").contains("line 2"), "folded by default: {folded:?}");
        assert!(t.expand_at(row));
        assert!(t.view(60, 12).join("\n").contains("line 2"), "the click shows what the call said");
        assert!(t.rewrite(-1, "  \u{2713} bash again"));
        let plain = t.view(60, 12);
        assert!(!plain.join("\n").contains("line 2") && t.expand_rows.is_empty(), "a plain rewrite is a plain row: {plain:?}");
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
    /// The welcome rule follows the window (Victor, 18/11: maximising left it at the old width, and
    /// shrinking left it wider than the window, where it wraps). The marker is drawn at the width of
    /// the frame, so one transcript viewed at three widths has three rules - never a stored one.
    #[test]
    fn a_rule_is_drawn_at_the_width_of_the_frame_and_never_at_the_width_it_was_written() {
        let mut chat = Transcript::default();
        chat.write("\u{1}r\u{1}\n");
        for width in [80usize, 200, 60] {
            let rows = chat.view(width, 10);
            let rule = rows.iter().find(|row| visible(row) > 0).expect("the rule is a row");
            assert_eq!(visible(rule), width, "the rule is exactly {width} columns");
            assert!(visible(rule) <= width, "and never wider than the terminal, which would wrap it");
        }
        // No marker ever reaches the screen, whatever the width.
        for row in chat.view(120, 10) { assert!(!row.contains('\u{1}'), "no marker is drawn: {row:?}"); }
    }

    /// Item G: a resize is a REPAINT FROM STATE, not a reflow of printed bytes.
    ///
    /// The chat is drawn into a scroll region from the blocks this crate owns, so what a changed
    /// width must produce is exactly what a session opened at that width would show - in both
    /// directions. The comparison is against a FRESH transcript built from the same writes, so a
    /// stale row, a lost block or a half-reflowed one all fail it.
    #[test]
    fn a_resize_repaints_the_whole_chat_at_the_new_width_in_both_directions() {
        let writes: Vec<String> = (0..12)
            .map(|i| format!("message {i}: {}", "uma frase longa com palavras ".repeat(3)))
            .collect();
        let build = || {
            let mut t = plain(Transcript::default());
            for w in &writes { t.write(w); }
            t
        };
        // 120 -> 60 and back: the same view a session at that width shows.
        let mut resized = build();
        let at120 = resized.view(120, 40);
        let mut fresh120 = build();
        assert_eq!(at120, fresh120.view(120, 40), "120 columns matches a fresh render");
        let at60 = resized.view(60, 40);
        let mut fresh60 = build();
        assert_eq!(at60, fresh60.view(60, 40), "after a shrink, 60 columns matches a fresh render");
        let back = resized.view(120, 40);
        assert_eq!(back, at120, "and widening back restores the 120-column view exactly");
        assert_ne!(at60, at120, "the two widths really differ, so the comparison is not vacuous");
    }

    /// Item G's cost, asserted DETERMINISTICALLY: what makes a repaint cheap is that it draws one
    /// screenful and re-measures nothing at an unchanged width. A wall clock here measured the
    /// machine as much as the code, so the counters carry it instead.
    #[test]
    fn a_long_session_repaints_one_screenful_and_remeasures_nothing() {
        let build = |messages: usize| {
            let mut t = plain(Transcript::default());
            for i in 0..messages {
                t.write(&format!("row {i}: {}", "palavras de uma mensagem longa ".repeat(2)));
            }
            t
        };
        let mut long = build(240);
        let mut short = build(12);
        assert_eq!(long.view(120, 40).len(), 40, "240 messages draw 40 rows");
        assert_eq!(short.view(120, 40).len(), 40, "12 messages draw the same 40 rows");
        let mut third = build(240);
        let _ = third.view(120, 40);
        let measured = third.count_width;
        let _ = third.view(120, 40);
        assert_eq!(third.count_width, measured, "a second frame at 120 measures at the same width");
        let _ = third.view(60, 40);
        assert_ne!(third.count_width, measured, "and a resize is what makes it measure again");
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
    // ---- a fenced code card stays whole on any width (#fence-card) -----------------------------
    // Victor 19/11: a card laid out at the render width was re-wrapped by the HOST's prose wrapper
    // when drawn narrower (a focused block is boxed two columns in, and a resize redraws at the new
    // width). The prose wrapper breaks at a space, and the space after the bar is a space: the bar
    // was left alone on a row and the code went to the next row without it.

    /// The rows `lua/core/markdown.lua` writes for a fence, byte for byte: the opening corner with
    /// its language in the border colour, each code row as the bar, a blank and the code, and the
    /// closing corner. `open` is prefixed by the copy icon the view puts in front of a fence
    /// (`cli_view.say_emit` -> `transcript_copy` -> `COPY_PREFIX` on the first row).
    fn card_rows(code: &[&str], open: bool) -> Vec<String> {
        let border = CARD_BORDER;
        let code_style = "\x1b[38;2;212;212;212m";
        let mut lines = Vec::new();
        lines.push(format!("{}{border}\u{250c}\u{2500} bash{RESET}", if open { COPY_PREFIX } else { "" }));
        for line in code {
            lines.push(format!("{border}\u{2502} {RESET}{code_style}{line}{RESET}"));
        }
        lines.push(format!("{border}\u{2514}\u{2500}{RESET}"));
        lines
    }

    /// Every screen row of a card: what `CardWrap` makes of the rows the renderer wrote, at `width`.
    fn card_screen(code: &[&str], width: usize, open: bool) -> Vec<String> {
        let mut cards = CardWrap::default();
        card_rows(code, open).iter().flat_map(|line| cards.rows(line, width)).collect()
    }

    #[test]
    fn a_card_is_cut_by_cells_and_every_continuation_keeps_its_bar() {
        let code = "for f in a b c; do echo \"one rather long line of shell here to push past the border\"; done";
        for width in [120usize, 80, 60, 40] {
            let rows = card_screen(&[code], width, true);
            let plain: Vec<String> = rows.iter().map(|r| crate::selection::plain(r)).collect();
            assert!(plain.iter().all(|r| visible(r) <= width), "no row is wider than the screen at {width}: {plain:?}");
            // The screenshot rows: a bar with nothing after it, and a code row without its bar.
            assert!(!plain.iter().any(|r| r.trim_end() == "\u{2502}"), "no empty bar at {width}: {plain:?}");
            let body: Vec<&String> = plain.iter().filter(|r| r.contains("for f in")).collect();
            assert!(!body.is_empty(), "the code is drawn at {width}: {plain:?}");
            for row in &body {
                assert!(row.trim_start().starts_with('\u{2502}'), "the first code row keeps its bar at {width}: {row:?}");
            }
            // Every continuation row opens with the bar and the continuation mark, and carries code.
            let continuations: Vec<&String> = plain.iter().filter(|r| r.contains("\u{2502}\u{21aa}")).collect();
            assert_eq!(continuations.len(), rows.len().saturating_sub(3),
                "one continuation per row past the first, at {width}: {plain:?}");
            // Nothing is dropped and nothing is added: the body rows, in order, are the code. A CUT
            // falls inside a word when no space comes first - that is what "cut by cells" means, and
            // the continuation carries the rest of it.
            let rebuilt: String = plain.iter()
                .filter(|r| r.contains("\u{2502}"))
                .map(|r| {
                    let body = r.trim_start_matches('\u{2502}');
                    let body = body.strip_prefix('\u{21aa}').unwrap_or(body);
                    // The first row keeps the blank the view puts after the bar; a continuation does
                    // not (the mark took its column).
                    (if r.contains("\u{21aa}") { body } else { body.strip_prefix(' ').unwrap_or(body) }).to_string()
                })
                .collect();
            assert_eq!(rebuilt.trim_end(), code.trim_end(),
                "the body rows spell the code exactly, at {width}: {plain:?}");
        }
    }

    #[test]
    fn a_code_line_exactly_as_wide_as_the_card_stays_one_row() {
        // The card holds `width - 2` cells (the bar and its blank). A line of exactly that many
        // characters must not produce a continuation: a wrap that fired on `==` would print a bar
        // and a mark under a line that already fitted.
        for width in [80usize, 60] {
            let exact = "x".repeat(width - 2);
            let rows = card_screen(&[exact.as_str()], width, false);
            let plain: Vec<String> = rows.iter().map(|r| crate::selection::plain(r)).collect();
            assert!(!plain.iter().any(|r| r.contains("\u{21aa}")), "a card-wide line is one row at {width}: {plain:?}");
            assert!(plain.iter().any(|r| r.contains(&exact)), "and it is drawn whole at {width}: {plain:?}");
            // One cell more is a continuation - the check above can fail.
            let one_more = "x".repeat(width - 1);
            let wider = card_screen(&[one_more.as_str()], width, false);
            let wide_plain: Vec<String> = wider.iter().map(|r| crate::selection::plain(r)).collect();
            assert!(wide_plain.iter().any(|r| r.contains("\u{21aa}")), "one cell past it continues at {width}: {wide_plain:?}");
        }
    }

    #[test]
    fn prose_and_quotes_wrap_exactly_as_before_a_card_bar_wears_their_same_colour() {
        // A quote row opens with the same cells a card body row does (`\u{2502} ` in the one grey the
        // view uses for both roles), and a prose line may start with a bar of its own. Neither is
        // inside a card frame, so both keep the prose rule BYTE FOR BYTE - the fix must not reflow a
        // quote or a paragraph.
        let quote = "\x1b[38;2;119;119;119m\u{2502} \x1b[0m\x1b[38;2;153;153;153mquoted words wrap under the bar and keep going\x1b[0m";
        let mut cards = CardWrap::default();
        assert_eq!(cards.rows(quote, 24), wrap_rows(quote, 24), "a quote row is prose");
        let prose = "a plain paragraph that is long enough to wrap at this width, with words in it";
        assert_eq!(cards.rows(prose, 20), wrap_rows(prose, 20), "a paragraph is prose");
        assert_eq!(cards.rows(prose, 20).len(), 5, "and it does wrap where it always did: {:?}", cards.rows(prose, 20));
        // After a card closes, the rows below it are prose again.
        let mut after = CardWrap::default();
        for line in card_rows(&["code"], false) { after.rows(&line, 40); }
        let trailing = "words after the card wrap like prose again, at the same width as before";
        assert_eq!(after.rows(trailing, 24), wrap_rows(trailing, 24), "the frame closed with the card");
    }



    /// The rows `lua/core/markdown.lua` writes for a TABLE: the same `mdCodeBlockBorder` role as a card,
    /// but a rule carries a column divider and a body row ends in its own border bar.
    fn table_rows(wide: bool) -> Vec<String> {
        let border = CARD_BORDER;
        let cell = "a table cell with quite a lot of words in it to make the table wide";
        let row = |a: &str, b: &str| format!("{border}\u{2502}{RESET} {a} {border}\u{2502}{RESET} {b} {border}\u{2502}{RESET}");
        let width = |text: &str| text.chars().count() + 2;
        let rule = |left: &str, mid: &str, right: &str| {
            let a = if wide { width(cell) } else { 10 };
            let b = if wide { width("another value") } else { 15 };
            format!("{border}{left}{}{mid}{}{right}{RESET}", "\u{2500}".repeat(a), "\u{2500}".repeat(b))
        };
        let (a, b) = if wide { (cell, "another value") } else { ("head one", "head two") };
        vec![
            rule("\u{250c}", "\u{252c}", "\u{2510}"),
            row(a, b),
            rule("\u{251c}", "\u{253c}", "\u{2524}"),
            row("a value", "another value"),
            rule("\u{2514}", "\u{2534}", "\u{2518}"),
        ]
    }


    #[test]
    fn the_card_border_colour_is_the_one_the_theme_table_names() {
        // The colour cannot be read from a theme table at draw time: the host has no channel for the
        // palette (Lua paints, Rust receives bytes), so the constant is the contract. This test is what
        // keeps it honest - it reads the ROLE's own value out of `lua/core/cli_view.lua` and fails the
        // moment the two drift apart, which a comment cannot do.
        let palette = include_str!("../../../lua/core/cli_view.lua");
        let role = palette.lines()
            .find(|line| line.contains("mdCodeBlockBorder"))
            .and_then(|line| line.split("mdCodeBlockBorder").nth(1))
            .and_then(|rest| rest.split('"').nth(1))
            .expect("the mdCodeBlockBorder role is in the palette");
        assert_eq!(role.len(), 6, "a 24-bit colour: {role:?}");
        let (r, g, b) = (role[0..2].to_string(), role[2..4].to_string(), role[4..6].to_string());
        let expected = format!("\x1b[38;2;{};{};{}m",
            u8::from_str_radix(&r, 16).expect("red"), u8::from_str_radix(&g, 16).expect("green"),
            u8::from_str_radix(&b, 16).expect("blue"));
        assert_eq!(CARD_BORDER, expected,
            "CARD_BORDER must be the colour lua/core/cli_view.lua paints the border with (role {role:?})");
    }


    #[test]
    fn only_the_exact_card_opening_opens_a_frame_a_dim_diagnostic_does_not() {
        // codespan/miette draw a source location as a DIM `┌─ path:line:col` (cli_view.lua:80 dim == 777777,
        // the same grey as the card border), so a check that accepted any border-coloured corner opened a
        // frame on a compiler diagnostic and cut the rows under it by cells instead of wrapping them.
        // The DIM role IS the border colour (both 777777), so the one constant paints the diagnostic.
        let dim_row = format!("{CARD_BORDER}   ┌─ src/main.rs:3:5{RESET}");
        let dim_text = format!("{CARD_BORDER}│ the diagnostic text under it is long enough that it wraps at a narrow width{RESET}");
        let mut cards = CardWrap::default();
        assert_eq!(cards.rows(&dim_row, 40), wrap_rows(&dim_row, 40), "a dim diagnostic corner is prose");
        let after = cards.rows(&dim_text, 40);
        assert_eq!(after, wrap_rows(&dim_text, 40), "and the dim rows under it are prose, never card rows: {after:?}");
        assert!(!after.iter().any(|r| r.contains("│↪")), "no card continuation on a diagnostic: {after:?}");
        // A card's OWN opening row is `┌─` or `┌─ <lang>` and nothing else, and it still opens one.
        for opening in ["┌─", "┌─ bash", "┌─ js"] {
            let mut fresh = CardWrap::default();
            let row = format!("{CARD_BORDER}{opening}{RESET}");
            fresh.rows(&row, 40);
            let body = format!("{CARD_BORDER}│ {RESET}one rather long line of code that has to be cut at this width to fit");
            let cut = fresh.rows(&body, 40);
            assert!(cut.iter().any(|r| r.contains("│↪")), "{opening:?} opens a real card: {cut:?}");
        }
    }


    #[test]
    fn with_colour_off_there_is_no_frame_and_the_card_falls_back_to_prose() {
        // NO_COLOR / WASM_AGENT_CLI_VIEW=plain: `markdown.lua`\'s paint returns the text unchanged, so the
        // border carries no colour bytes. The host then cannot see a frame and the card wraps as PROSE -
        // the pre-existing behaviour, which the report states and this test pins.
        let code = "for f in a b c; do echo one rather long line of shell here to push past the border; done";
        let plain_rows = vec![
            "┌─ bash".to_string(),
            format!("│ {code}"),
            "└─".to_string(),
        ];
        let mut cards = CardWrap::default();
        let mut screen: Vec<String> = Vec::new();
        for line in &plain_rows { screen.extend(cards.rows(line, 60)); }
        let prose: Vec<String> = plain_rows.iter().flat_map(|l| wrap_rows(l, 60)).collect();
        assert_eq!(screen, prose, "an unpainted card is prose, exactly: {screen:?}");
        assert!(!screen.iter().any(|r| r.contains("│↪")), "no card mark without colour: {screen:?}");
    }

    #[test]
    fn a_table_looking_code_line_inside_a_real_card_is_still_card_code() {
        // A code line may be anything, including something that reads like a table row. The table check
        // exists to keep a TABLE out of a card frame; inside a frame that is already OPEN there is no table
        // to protect (markdown.lua never nests one), so the row must be cut like any other card code.
        let code = "│ a long line of text that must be cut by cells and ends with a bar │";
        let mut cards = CardWrap::default();
        let rows = card_rows(&[code], false).iter().flat_map(|line| cards.rows(line, 40)).collect::<Vec<String>>();
        let plain: Vec<String> = rows.iter().map(|r| crate::selection::plain(r)).collect();
        let shown = plain.join("\n");
        assert!(plain.iter().any(|r| r.contains("│↪")),
            "a table-looking code line inside an open card is cut like card code: {shown}");
        assert!(!plain.iter().any(|r| r.trim_end() == "│"), "and no row is only a bar: {shown}");
    }

    #[test]
    fn a_table_is_not_a_card_and_keeps_the_prose_rule_byte_for_byte() {
        // A table is painted with the card's own border role and opens with a bar row, so a check that
        // only looked at the glyph and the colour would cut it by cells - losing its closing bar and a
        // column. Every row of a table must come out of the card wrapper exactly as prose made it.
        let mut cards = CardWrap::default();
        for wide in [false, true] {
            for width in [120usize, 60, 40] {
                for line in table_rows(wide) {
                    let from_card = cards.rows(&line, width);
                    let from_prose = wrap_rows(&line, width);
                    assert_eq!(from_card, from_prose,
                        "table row wrapped as prose at {width}, wide={wide}: {line:?}");
                    assert!(!from_card.iter().any(|r| r.contains("\u{21aa}")),
                        "a table row is never given a card continuation mark at {width}: {from_card:?}");
                    // Its own bars survive: a cut table row that ate its closing bar would be shorter.
                    let before = crate::selection::plain(&line).matches('\u{2502}').count();
                    let after: usize = from_card.iter().map(|r| crate::selection::plain(r).matches('\u{2502}').count()).sum();
                    assert_eq!(after, before, "every table bar survives at {width}: {from_card:?}");
                }
            }
        }
    }


    #[test]
    fn an_indented_card_is_cut_and_its_indent_repeats_on_every_continuation() {
        // A fence nested in a list arrives with the view's indent in front of every row
        // (markdown.lua `opts.indent`): `  ┌─ js`, `  │ code`, `  └─`. The border colour is set once,
        // BEFORE that indent, so the bar cell carries no escape of its own - the reason a colour check
        // that only looked at the bar missed these rows entirely.
        let indent = "  ";
        let border = CARD_BORDER;
        let code = "const x = 1; const yy = 2; const zzz = 3; const wide = 4; const more = 5; const tail = 6;";
        let rows = vec![
            format!("{border}{indent}┌─ js{RESET}"),
            format!("{border}{indent}│ {RESET}\x1b[38;2;212;212;212m{code}{RESET}"),
            format!("{border}{indent}└─{RESET}"),
        ];
        let mut cards = CardWrap::default();
        let mut screen: Vec<String> = Vec::new();
        for line in &rows { screen.extend(cards.rows(line, 40)); }
        let plain: Vec<String> = screen.iter().map(|r| crate::selection::plain(r)).collect();
        let shown = plain.join("\n");
        assert!(plain.iter().any(|r| r.contains("│↪")), "the indented card was cut: {shown}");
        // Every continuation keeps the item's indent, so the card stays inside the list.
        for row in plain.iter().filter(|r| r.contains("│↪")) {
            assert!(row.starts_with(indent), "a continuation keeps the indent: {row:?} in {shown}");
        }
        // And no row is only a bar, and the code survives whole.
        assert!(!plain.iter().any(|r| r.trim() == "│"), "no empty bar: {shown}");
        assert!(!plain.iter().any(|r| !r.starts_with(indent)), "every card row stays indented: {shown}");
        let rebuilt: String = plain.iter()
            .map(|r| { let t = r.trim_start_matches(' ').trim_start_matches('│'); t.strip_prefix('↪').unwrap_or(t).trim_start().to_string() })
            .collect();
        // A cut falls mid-word when no space comes first, so compare the words, not the bytes.
        let squash = |s: &str| s.chars().filter(|c| !c.is_whitespace()).collect::<String>();
        assert!(squash(&rebuilt).contains(&squash(code)), "the code survives at 40 columns: {shown}");
    }

    #[test]
    fn a_card_after_a_table_is_still_a_card() {
        // The frame state must come out of the table clean: a table's closing rule looks like nothing
        // the card logic knows, so the next fence still opens and closes on its own rows.
        let mut cards = CardWrap::default();
        for line in table_rows(false) { cards.rows(&line, 40); }
        let code = "for f in a b c; do echo one rather long line of shell here to push past the border; done";
        let rows: Vec<String> = card_rows(&[code], false).iter().flat_map(|l| cards.rows(l, 40)).collect();
        let plain: Vec<String> = rows.iter().map(|r| crate::selection::plain(r)).collect();
        assert!(plain.iter().any(|r| r.contains("\u{2502}\u{21aa}")), "the card still cuts: {plain:?}");
        assert!(!plain.iter().any(|r| r.trim_end() == "\u{2502}"), "no empty bar: {plain:?}");
    }

    #[test]
    fn a_focused_card_is_cut_two_columns_narrower_and_keeps_its_bar() {
        // The focused width is the one that broke the screenshot card: a focused topic is boxed, so
        // its rows wrap at width - 2 (transcript.rs rows_with_copies). A card in a TOOL block is
        // inside that box, so this drives the real view rather than CardWrap alone.
        let mut t = Transcript::default();
        t.block(true);
        t.write("\u{23fa} Bash(cat notes.txt)\n");
        let border = CARD_BORDER;
        let code = "for f in a b c; do echo \"one rather long line of shell here to push past the border\"; done";
        t.copyable(&[(1, code.to_string())]);
        t.write(&format!("{COPY_PREFIX}{border}\u{250c}\u{2500} bash{RESET}\n"));
        t.write(&format!("{border}\u{2502} {RESET}\x1b[38;2;212;212;212m{code}{RESET}\n"));
        t.write(&format!("{border}\u{2514}\u{2500}{RESET}\n"));
        assert!(t.focus_prev(), "the call is a topic");
        t.set_expanded(true);
        let width = 60usize;
        let view = t.view(width, 20);
        let plain: Vec<String> = view.iter().map(|r| crate::selection::plain(r)).collect();
        let shown = plain.join("\n");
        // The focus box is drawn, and every card row inside it keeps the bar: the box eats two
        // columns, so the card wraps at width - 2 and its continuations still open with bar + mark.
        assert!(plain.iter().any(|r| r.starts_with('\u{250c}')), "the focus frame is drawn: {shown}");
        let inside = plain.iter().filter(|r| r.starts_with("\u{2502}")).count();
        assert!(inside >= 2, "card rows are inside the box: {shown}");
        assert!(plain.iter().any(|r| r.contains("\u{2502}\u{21aa}")), "a card row continued: {shown}");
        // Every row inside the card frame keeps a bar, at the boxed width.
        let mut open = false;
        let mut orphans: Vec<String> = Vec::new();
        for text in &plain {
            let body = text.trim_start_matches('\u{2502}').trim_start();
            if body.starts_with('\u{250c}') { open = true; continue; }
            if body.starts_with('\u{2514}') { open = false; continue; }
            if open && !text.contains('\u{2502}') && !text.trim().is_empty() { orphans.push(text.clone()); }
        }
        assert!(orphans.is_empty(), "every row inside the card keeps its bar: {orphans:?}\n{shown}");
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

    // ---- the pinned request, the notice row, and the way back to the bottom ---------------------
    // Victor, 23/11 11:20Z, with a Claude Code screenshot: "claude code shows sticked to the top the
    // last user input turn ... and we want on top of that sticked user input a line reserved to TUI
    // messages". The status row is his to keep: a message never takes it.

    /// A session with two turns: a request, the answer under it, and the same again.
    fn two_turns() -> Transcript {
        let mut t = plain(Transcript::default());
        // A little chat above the first turn, so that turn can scroll off the top as well.
        t.block(false); for n in 0..4 { t.write(&format!("welcome {n}\n")); }
        t.block(false); t.write_marked("\u{276f} first question\n\n", true);
        t.block(false); for n in 0..12 { t.write(&format!("answer one {n}\n")); }
        t.block(false); t.write_marked("\u{276f} second question\n\n", true);
        t.block(false); for n in 0..12 { t.write(&format!("answer two {n}\n")); }
        t
    }

    /// The band a pinned row wears: the reader's own turn's grey, never the notice's accent.
    fn is_pin(row: &str) -> bool { row.contains(PIN_BAND) }

    #[test]
    fn the_request_above_the_viewport_is_pinned_on_the_top_row() {
        let mut t = two_turns();
        let view = t.view(40, 8);
        assert_eq!(view.len(), 8, "the region keeps every row it was given: {view:?}");
        assert!(is_pin(&view[0]) && view[0].contains("second question"),
            "the top row is the last request, on its band: {view:?}");
        assert!(view[0].contains("\u{276f}"), "with the prompt mark it was sent with: {view:?}");
        assert!(view.last().unwrap().contains("answer two 11"),
            "and the answer is still the last row: {view:?}");
    }

    /// The row under the pinned request is the chat's OWN row: the region is one row shorter, not
    /// overdrawn (the brief). The proof is exact: the same chat with no request mark draws the same
    /// rows, one row further down.
    #[test]
    fn the_pinned_row_takes_its_row_from_the_region_and_not_from_the_chat() {
        let mut marked = two_turns();
        let mut plain_t = plain(Transcript::default());
        plain_t.block(false); for n in 0..4 { plain_t.write(&format!("welcome {n}\n")); }
        plain_t.block(false); plain_t.write("\u{276f} first question\n\n");
        plain_t.block(false); for n in 0..12 { plain_t.write(&format!("answer one {n}\n")); }
        plain_t.block(false); plain_t.write("\u{276f} second question\n\n");
        plain_t.block(false); for n in 0..12 { plain_t.write(&format!("answer two {n}\n")); }
        let pinned = marked.view(40, 8);
        let free = plain_t.view(40, 8);
        assert!(is_pin(&pinned[0]), "the marked chat pins: {pinned:?}");
        assert!(!free.iter().any(|row| is_pin(row)), "an unmarked chat pins nothing: {free:?}");
        assert_eq!(pinned[1..].to_vec(), free[1..].to_vec(),
            "the chat's rows are the same rows, one row lower: nothing is hidden or moved");
    }

    #[test]
    fn scrolling_up_pins_the_turn_in_view() {
        let mut t = two_turns();
        let _ = t.view(40, 8);
        // One page up is still the second turn.
        t.page(4);
        let _ = t.view(40, 8);
        let up = t.view(40, 8);
        assert!(is_pin(&up[0]) && up[0].contains("second question"), "{up:?}");
        // Paged back PAST the second turn's request, the FIRST turn's request is what sits on top.
        t.page(12);
        let _ = t.view(40, 8);
        let older = t.view(40, 8);
        assert!(is_pin(&older[0]) && older[0].contains("first question"),
            "the pin follows the turn in view: {older:?}");
    }

    #[test]
    fn a_session_with_no_request_yet_has_no_pinned_row() {
        let mut t = plain(Transcript::default());
        t.block(false); for n in 0..20 { t.write(&format!("answer {n}\n")); }
        let view = t.view(40, 8);
        assert!(!view.iter().any(|row| is_pin(row)), "nothing to pin, no band: {view:?}");
        assert_eq!(view.len(), 8, "and the chat keeps every row: {view:?}");
        assert!(t.notice_text(std::time::Instant::now()).is_none(), "no notice either");
    }

    #[test]
    fn a_long_wide_request_is_one_row_clipped_with_an_ellipsis() {
        let mut t = plain(Transcript::default());
        t.block(false);
        t.write_marked(&format!("\u{276f} {}\n\n", "\u{4f60}\u{597d}\u{4e16}\u{754c}".repeat(20)), true);
        t.block(false); for n in 0..30 { t.write(&format!("answer {n}\n")); }
        let view = t.view(40, 8);
        assert!(is_pin(&view[0]), "{view:?}");
        assert!(visible(&view[0]) <= 40, "the row never overflows its window: {view:?}");
        assert!(view[0].contains("\u{2026}"), "and says so with an ellipsis: {view:?}");
        assert!(!is_pin(&view[1]), "one row, never two: {view:?}");
    }

    #[test]
    fn the_notice_sits_above_the_pinned_request_and_goes_after_its_time() {
        let mut t = two_turns();
        let now = std::time::Instant::now();
        assert!(t.notice("Copied 12 characters", now, false), "a copy says so on the notice row");
        let view = t.view_at(40, 8, now);
        assert!(view[0].contains("Copied 12 characters") && !is_pin(&view[0]),
            "the notice is the top row, and not on the band: {view:?}");
        assert!(is_pin(&view[1]) && view[1].contains("second question"),
            "the pinned request is one row under it: {view:?}");
        assert!(!view.iter().any(|row| row.contains("Copied") && is_pin(row)), "{view:?}");
        // Two seconds later the message is gone and the pinned request is the top row again.
        let later = now + std::time::Duration::from_millis(NOTICE_MS + 50);
        let view = t.view_at(40, 8, later);
        assert!(!view.iter().any(|row| row.contains("Copied")), "the message's time is up: {view:?}");
        assert!(is_pin(&view[0]), "and the pinned request is the top row: {view:?}");
        assert!(t.expire_notice(later), "the caller is told to take it away");
        assert_eq!(t.notice_text(later), None, "and it is gone from the state");
    }

    #[test]
    fn an_error_stays_until_the_next_key() {
        let mut t = two_turns();
        let now = std::time::Instant::now();
        assert!(t.notice("no clipboard tool answered", now, true));
        let long_after = now + std::time::Duration::from_secs(600);
        assert_eq!(t.notice_text(long_after).as_deref(), Some("no clipboard tool answered"),
            "an error does not time out: it waits for a key");
        assert!(!t.expire_notice(long_after), "nothing takes it away on its own");
        let view = t.view_at(40, 8, long_after);
        assert!(view[0].contains("no clipboard tool answered"), "{view:?}");
        assert!(t.clear_notice(), "the next key clears it");
        assert!(!view.is_empty() && t.notice_text(long_after).is_none());
    }

    #[test]
    fn the_pill_names_the_key_the_table_binds() {
        // The key is the table's, not a literal here: a rebinding changes the label.
        let key = crate::keymap::label(crate::keymap::Act::Nav(crate::keymap::NavAct::Bottom))
            .expect("the way back to the bottom is bound");
        assert_eq!(Transcript::pill_text(key, 0), format!("Jump to bottom ({key}) \u{2193}"));
        // ... and the words around it are a function of whatever key is passed, which is what a
        // second key proves.
        assert_eq!(Transcript::pill_text("Alt+End", 0), "Jump to bottom (Alt+End) \u{2193}");
        assert_eq!(Transcript::pill_text("Alt+End", 12), "\u{2193} 12 more lines \u{b7} Jump to bottom (Alt+End) \u{2193}");
        let mut t = two_turns();
        let _ = t.view(40, 8);
        t.page(6);
        // A narrow window keeps the key and the count; a wide one says the whole sentence.
        let narrow = t.view(40, 8);
        assert!(narrow.last().unwrap().contains(key), "the key survives a narrow window: {narrow:?}");
        assert!(narrow.last().unwrap().contains("more lines"), "and how much is below: {narrow:?}");
        let wide = t.view(80, 8);
        assert!(wide.last().unwrap().contains(&format!("Jump to bottom ({key})")), "{wide:?}");
        assert!(wide.last().unwrap().contains("more lines"), "{wide:?}");
    }

    #[test]
    fn a_press_on_the_pill_or_the_key_goes_back_to_the_bottom() {
        let mut t = two_turns();
        let _ = t.view(40, 8);
        t.page(6);
        let view = t.view(40, 8);
        let span = t.on_pill(8, 1, 8);
        let inside = (1..=40).find(|col| t.on_pill(8, *col, 8)).expect("the pill answers a press");
        assert!(span || inside > 0, "{view:?}");
        assert!(!t.on_pill(7, inside, 8), "only the region's last row: the status row is never the pill's");
        // The key (Ctrl+PageDown, the table's Bottom) and the pill do the same thing.
        t.to_bottom();
        let back = t.view(40, 8);
        assert!(!back.last().unwrap().contains("Jump to bottom"), "the pill is gone: {back:?}");
        assert!(t.following(), "and the view follows the output again");
    }

    #[test]
    fn a_press_on_the_pinned_request_scrolls_to_it() {
        let mut t = two_turns();
        let view = t.view(40, 8);
        assert!(t.on_pin(1), "the pinned row answers a press: {view:?}");
        assert!(!t.on_pin(2), "and only that row does");
        assert!(t.jump_to_pinned(40), "the press scrolls to the request it stands for");
        let jumped = t.view(40, 8);
        assert!(jumped.iter().any(|row| row.contains("second question") && !is_pin(row)),
            "the request itself is on screen now, as a chat row: {jumped:?}");
        // What is above the viewport now is the turn BEFORE it, and that is what the pin names -
        // the rule is "the last request that scrolled off", not "the last request there was".
        assert!(is_pin(&jumped[0]) && jumped[0].contains("first question"), "{jumped:?}");
    }

    /// The answer streams into its own block, never into the request's: the pin is measured against
    /// the request's OWN rows, and a block that keeps growing with the answer could never be above
    /// the viewport.
    #[test]
    fn the_answer_does_not_join_the_request_block() {
        let mut t = plain(Transcript::default());
        t.block(false);
        t.write_marked("❯ a question\n\n", true);
        for n in 0..4 { t.write(&format!("answer {n}\n")); }
        let blocks = t.blocks.len();
        assert!(t.blocks[0].request, "the first block is the request");
        assert_eq!(t.blocks[0].lines.len(), 2, "and holds only the request: {:?}", t.blocks[0].lines);
        assert!(blocks >= 2 && !t.blocks[1].request, "the answer is a block of its own: {blocks} blocks");
        assert!(t.blocks[1].lines.iter().any(|line| line.contains("answer 3")), "{:?}", t.blocks[1].lines);
        // And the view pins it once the answer has pushed it off the top.
        let view = t.view(40, 4);
        assert!(view[0].contains(PIN_BAND) && view[0].contains("a question"), "{view:?}");
    }

    /// NOT an assertion: a MEASUREMENT. 5,000 rows is one resumed session's replay, and the two rows
    /// this view now reserves must not cost a frame anything the reader can feel. Run it on two
    /// commits and compare, exactly as the report for this change did:
    ///
    ///   WA_FRAME_MS=1 cargo test -p wa-term --lib frame_cost -- --nocapture
    ///
    /// Two frames are measured, because they cost different things: FOLLOWING (bottom-anchored,
    /// only what reaches the screen is wrapped - the usual frame while a stream arrives) and FROZEN
    /// a page up (fixed position, the failing-measurement path that a reader is in while reading).
    #[test]
    fn frame_cost_of_a_5000_row_chat() {
        if std::env::var("WA_FRAME_MS").is_err() { return }
        let mut t = plain(Transcript::default());
        t.block(false); t.write_marked("❯ a question about the whole session\n\n", true);
        t.block(false);
        for n in 0..5000 { t.write(&format!("line {n} of a long session\n")); }
        let _ = t.view(120, 40); // the first frame fills the row-count cache
        let start = std::time::Instant::now();
        for _ in 0..2000 { let _ = t.view(120, 40); }
        let following = start.elapsed() / 2000;
        t.page(20);
        let _ = t.view(120, 40);
        let start = std::time::Instant::now();
        for _ in 0..100 { let _ = t.view(120, 40); }
        let frozen = start.elapsed() / 100;
        println!("frame (5000 rows, 120x40): following {following:?}, frozen {frozen:?}");
    }
}
