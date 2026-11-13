//! The scrollbar as a model: one continuous track, a thumb on it, and the arithmetic that turns a
//! pointer into a scroll position.
//!
//! The operator, 13/11 ~06:50: the track was drawn with breaks instead of one line, and it ignored
//! the mouse. pi's console (`packages/tui`, `layout.ts`'s `paintScrollbar` and
//! `tui-alt-screen.ts`'s `handleScrollbarMouseEvent`) is the shape this copies, because it is the
//! one that reads as a bar under a pointer:
//!
//! - **One track.** Every row of the region gets the track glyph - the thumb is the same column,
//!   drawn heavier - so the column is a line from the first row to the last, never segments with
//!   air between them. `Bar::cells` is a total function of `(track, total, first, active)`: it
//!   returns exactly `track` glyphs, and the test walks several heights to say so.
//! - **A thumb you can see and hit.** At least two rows (`track.min(2)`), so a long session's thumb
//!   is a handle rather than a speck: pi's `minThumbHeight`.
//! - **A click jumps, a drag scrolls.** A press on the thumb grabs it where it was pressed; a press
//!   on the track puts the thumb's *middle* under the pointer (pi's `Math.floor(thumbHeight / 2)`)
//!   and starts the same drag. `first_at` is that mapping, in rows of content.
//! - **Hover thickens.** Resting, the thumb is `┃` (heavy vertical) joined to the `│` track; while
//!   the pointer is on the bar it is `█` (a block: thicker, and the brighter colour), and it goes
//!   back to `┃` when the pointer leaves. pi: `isScrollbarActive() ? "█" : "┃"`.
//!
//! Nothing here knows about a terminal, a screen or a transcript: both transcripts (`scroll::chat`
//! for the fullscreen console, `transcript` for the inline one) draw from `Bar`, so the two bars
//! cannot disagree about what a click means - `thumb` and `fit` were already shared that way.
use crate::terminal_editor::cell_width_of;

/// The track: a light vertical stroke, one cell wide, on every row of the bar.
pub const TRACK: char = '\u{2502}';
/// The thumb at rest: a heavy vertical stroke, so it continues the track instead of cutting it.
pub const THUMB: char = '\u{2503}';
/// The thumb under the pointer or being dragged: a block - thicker than the track it sits on.
pub const THUMB_ACTIVE: char = '\u{2588}';

/// The track's colour: dim, so it never competes with the text it sits beside.
pub const TRACK_COLOUR: &str = "\x1b[38;2;80;80;80m";
/// The thumb's colour: readable against the track without being an alarm.
pub const THUMB_COLOUR: &str = "\x1b[38;2;136;136;136m";
/// The thumb's colour while the pointer is on it: brighter, because a pointer is over it.
pub const ACTIVE_COLOUR: &str = "\x1b[38;2;204;204;204m";

/// One bar as it is drawn: the track's height in rows, the chat's rows, the first content row the
/// track shows, and whether the pointer is on it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Bar {
    pub track: usize,
    pub total: usize,
    pub first: usize,
    pub active: bool,
}

impl Bar {
    pub fn new(track: usize, total: usize, first: usize) -> Bar { Bar { track, total, first, active: false } }

    /// Whether there is anything to scroll: a chat that fits its region has a bar (with `always`)
    /// that no click can move, and a click on it says nothing.
    pub fn scrolling(&self) -> bool { self.total > self.track }

    /// The rows above the bottom a first visible row of `first` means: what the fullscreen console's
    /// `scrolled` is.
    pub fn scrolled(&self) -> usize { self.total.saturating_sub(self.track).saturating_sub(self.first) }

    /// Where the track's rows are: `(top, len)` of the thumb, `len >= track.min(2)`.
    pub fn thumb(&self) -> (usize, usize) { thumb(self.track, self.total, self.first) }

    /// The glyph and colour of every row of the track, first row first: `track` cells, always.
    pub fn cells(&self) -> Vec<(char, &'static str)> {
        let (top, len) = self.thumb();
        (0..self.track)
            .map(|row| {
                if row >= top && row < top + len {
                    if self.active { (THUMB_ACTIVE, ACTIVE_COLOUR) } else { (THUMB, THUMB_COLOUR) }
                } else {
                    (TRACK, TRACK_COLOUR)
                }
            })
            .collect()
    }

    /// The grab offset a press at track row `row` takes: where on the thumb the pointer landed, or
    /// the thumb's middle when the press was on the track (so the thumb comes to the pointer).
    pub fn grab(&self, row: usize) -> usize {
        let (top, len) = self.thumb();
        if row >= top && row < top + len { row - top } else { len / 2 }
    }

    /// The first content row that puts the thumb at track row `row` with grab offset `grab`:
    /// the inverse of `thumb`, clamped to the content (`0 ..= total - track`).
    pub fn first_at(&self, row: usize, grab: usize) -> usize { first_at(self.track, self.total, row, grab) }
}

/// The scrollbar's thumb for a track of `track` rows over `total` rows whose first visible row is
/// `first`: (first row of the thumb, how many rows it is). At least two rows on a track that has
/// them - a one-row thumb is a speck no pointer can hit - and never wider than the track.
pub fn thumb(track: usize, total: usize, first: usize) -> (usize, usize) {
    if track == 0 { return (0, 0); }
    let len = ((track * track) / total.max(1)).clamp(track.min(2), track);
    let max_first = total.saturating_sub(track);
    let top = (first * (track - len) + max_first / 2).checked_div(max_first).unwrap_or(0);
    (top.min(track - len), len)
}

/// The inverse of `thumb`: which content row brings the thumb's top to `row - grab`.
///
/// Rounded to the nearest row, so a press between two positions lands on the nearer one, and clamped
/// to `0 ..= total - track`, so a click near an end stops at the end rather than off the track.
pub fn first_at(track: usize, total: usize, row: usize, grab: usize) -> usize {
    let max_first = total.saturating_sub(track);
    let len = thumb(track, total, 0).1;
    let span = track.saturating_sub(len);
    if max_first == 0 || span == 0 { return 0; }
    let top = row.saturating_sub(grab).min(span);
    ((top * max_first + span / 2) / span).min(max_first)
}

/// A row cut or padded to exactly `width` cells - what a row must be for the scrollbar to land in
/// the last column. Escape sequences take no cells and are kept.
pub fn fit(text: &str, width: usize) -> String {
    let mut out = String::new();
    let mut cells = 0usize;
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\x1b' {
            out.push(ch);
            if chars.peek() == Some(&'[') { out.push(chars.next().unwrap()); for c in chars.by_ref() { out.push(c); if ('@'..='~').contains(&c) { break; } } }
            continue;
        }
        let cell = cell_width_of(ch);
        if cells + cell > width { break; }
        out.push(ch);
        cells += cell;
    }
    out.push_str(&" ".repeat(width.saturating_sub(cells)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The bar drawn for a chat read from its first row, at these heights.
    fn bars() -> Vec<Bar> {
        let mut bars = Vec::new();
        for track in [1usize, 2, 3, 5, 7, 10, 24, 40] {
            for total in [track, track + 1, track * 3, track * 20, 5_000] {
                let max = total.saturating_sub(track);
                for first in [0, max / 2, max] {
                    bars.push(Bar::new(track, total, first));
                }
            }
        }
        bars
    }

    #[test]
    fn the_track_is_one_continuous_line_at_every_height() {
        for bar in bars() {
            let cells = bar.cells();
            assert_eq!(cells.len(), bar.track, "one cell per row of the track: {bar:?}");
            let kinds: Vec<char> = cells.iter().map(|(glyph, _)| *glyph).collect();
            assert!(kinds.iter().all(|glyph| matches!(*glyph, TRACK | THUMB | THUMB_ACTIVE)),
                "every row of the bar is a bar glyph, never a gap: {bar:?} {kinds:?}");
            // The thumb is one run, and the track is the rest: no thumb row is followed by a gap.
            let thumb_rows: Vec<usize> = kinds.iter().enumerate()
                .filter(|(_, glyph)| matches!(**glyph, THUMB | THUMB_ACTIVE)).map(|(row, _)| row).collect();
            let (top, len) = bar.thumb();
            assert_eq!(thumb_rows, (top..top + len).collect::<Vec<usize>>(), "the thumb is one run on the track: {bar:?}");
            assert!(len >= bar.track.min(2) || len == bar.track, "a thumb is a handle, not a speck: {bar:?} len {len}");
            assert!(top + len <= bar.track, "the thumb never runs off the track: {bar:?}");
            // And with the pointer on it, the same run is thicker - nothing else changes.
            let hovered: Vec<char> = Bar { active: true, ..bar }.cells().into_iter().map(|(glyph, _)| glyph).collect();
            let thick: Vec<usize> = hovered.iter().enumerate().filter(|(_, glyph)| **glyph == THUMB_ACTIVE).map(|(row, _)| row).collect();
            assert_eq!(thick, thumb_rows, "hovering thickens the thumb's own rows and moves nothing: {bar:?}");
            assert_eq!(hovered.iter().filter(|glyph| **glyph == TRACK).count(), bar.track - len,
                "the rest of the track stays a track: {bar:?}");
        }
    }

    #[test]
    fn the_thumb_is_two_rows_until_a_fifth_of_the_chat_is_shorter_than_that() {
        assert_eq!(thumb(10, 100, 0), (0, 2), "a hundred rows in ten: a two-row handle at the top");
        assert_eq!(thumb(50, 100, 0), (0, 25), "a half of the chat in view: half the track");
        assert_eq!(thumb(10, 5, 0), (0, 10), "a short chat: the whole track, no overflow");
        assert_eq!(thumb(10, 1_000_000, 0), (0, 2), "a huge chat still has a handle to hold");
        assert_eq!(thumb(0, 100, 0), (0, 0), "no track, no thumb");
        assert_eq!(thumb(1, 100, 0), (0, 1), "a one-row track is one row");
        assert_eq!(thumb(10, 100, 90), (8, 2), "at the bottom the thumb is at the track's end");
    }

    #[test]
    fn a_click_on_the_track_puts_the_thumb_there() {
        // A hundred rows in ten: the ends are exact, and the middle lands on the middle row.
        let bar = Bar::new(10, 100, 0);
        let top_click = bar.first_at(0, bar.grab(0));
        assert_eq!(top_click, 0, "the first row of the track is the top of the chat");
        let bottom_click = bar.first_at(9, bar.grab(9));
        assert_eq!(bottom_click, 90, "the last row of the track is the bottom: 100 - 10");
        let middle = bar.first_at(5, bar.grab(5));
        assert_eq!(middle, 45, "the middle of the track is the middle of the chat: 90 rows over 8 free rows");
        // Clicking the track never runs past the ends, however far off the row is.
        assert_eq!(bar.first_at(0, 0), 0);
        assert_eq!(bar.first_at(99, 0), 90);
        // And a click on the thumb keeps the grab: the thumb does not jump under the pointer.
        let at_middle = Bar::new(10, 100, 45);
        let (top, len) = at_middle.thumb();
        let grabbed = at_middle.grab(top + len / 2);
        assert_eq!(grabbed, len / 2, "the press landed on the thumb's middle");
        let moved = at_middle.first_at(top + len / 2, grabbed);
        assert_eq!(moved, 45, "the same place: nothing moved under a click that grabbed the thumb");
    }

    #[test]
    fn a_drag_moves_the_view_with_the_pointer_and_stops_at_the_ends() {
        let mut bar = Bar::new(10, 100, 0);
        let (top, _) = bar.thumb();
        let grab = bar.grab(top); // press the thumb's first row: grab 0
        // Dragging down one track row moves the chat by one thumb step: 90 rows over 8 free rows.
        let mut seen = Vec::new();
        for row in 0..10 {
            bar.first = bar.first_at(row, grab);
            seen.push(bar.first);
        }
        assert_eq!(seen.first().copied(), Some(0), "at the top row of the track");
        assert_eq!(seen.last().copied(), Some(90), "at the bottom row of the track");
        assert!(seen.windows(2).all(|pair| pair[0] <= pair[1]), "a drag down never scrolls up: {seen:?}");
        assert!(seen.contains(&45), "the middle of the drag is the middle of the chat: {seen:?}");
        // Up again, from where the drag left it.
        let up: Vec<usize> = (0..10).rev().map(|row| bar.first_at(row, grab)).collect();
        assert_eq!(up.first().copied(), Some(90), "the drag's end");
        assert_eq!(up.last().copied(), Some(0), "and back to the top: a drag is reversible");
    }

    #[test]
    fn the_bar_reports_the_position_it_draws_and_whether_a_click_can_move_it() {
        assert_eq!(Bar::new(10, 100, 90).scrolled(), 0, "the bottom: rows above the bottom = 0");
        assert_eq!(Bar::new(10, 100, 0).scrolled(), 90, "the top: every row that is not shown");
        assert!(Bar::new(10, 100, 0).scrolling());
        assert!(!Bar::new(10, 10, 0).scrolling(), "a chat that fits its region has nothing to click");
        assert!(!Bar::new(10, 4, 0).scrolling());
    }

    #[test]
    fn a_row_is_fitted_to_the_tracks_width_in_cells_whatever_it_holds() {
        assert_eq!(fit("abc", 6), "abc   ");
        assert_eq!(fit("abcdefgh", 4), "abcd", "cut, never wrapping into the bar's column");
        assert_eq!(fit("\x1b[38;2;1;2;3mab\x1b[0m", 3), "\x1b[38;2;1;2;3mab\x1b[0m ", "escape sequences take no cells");
    }
}
