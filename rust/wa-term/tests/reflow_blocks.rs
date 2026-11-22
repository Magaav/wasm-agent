//! A RUN BOX AND A FENCE FOLLOW THE WINDOW, in both directions, with one mark in one place.
//!
//! Victor 22/11, in his own maximised window: the codeact box and the fenced code block stayed wrapped
//! where the OLD width had cut them - a line cut at about half the new window stayed cut, with empty
//! space to its right, while the prose around them reflowed. And the mark that says "this line goes on
//! below" was drawn two ways: in the run box at the END of the cut row, in a fence at the START of the
//! next row, in the gutter.
//!
//! Both blocks are now stored UNCUT and cut HERE, at the width the frame is drawn at: a wider window
//! shows longer rows, a narrower one re-cuts them, and the mark is the fence's - in the gutter of the
//! row the line continues on, never inside the text of the row it was cut at.
//!
//! The rows below are what Lua hands over since that change: a code-mode band row with its marker
//! (`lua/core/codemode_block.lua` `M.band_mark`) and a fence's body row inside its frame
//! (`lua/core/markdown.lua` with `reflow`). Nothing here is cut.
use wa_term::scroll::settings::Scrollbar;
use wa_term::selection::plain;
use wa_term::transcript::{visible, Transcript};

const RESET: &str = "\x1b[0m";
/// The colour `lua/core/markdown.lua` paints a fence's border with (`mdCodeBlockBorder`): an unpainted
/// card row is PROSE to the host (`card_edge` asks for the border colour), and prose breaks at a space.
const CARD_BORDER: &str = "\x1b[38;2;119;119;119m";
/// The band's own rest-of-row fill, as the Lua palette hands it over (`band_erase`).
const FILL: &str = "\x1b[48;2;23;23;23m\x1b[K";

/// The one line both blocks hold: a shell line longer than either block holds at 60 columns.
const LINE: &str = "sh -e <<'EOF' | while read -r line; do printf '%s\\n' \"$line\"; done | sort -u | head -20";

/// A transcript with the scrollbar off: every row is the text the block asked for, and no column is
/// taken by the bar (the bar's own tests set it).
fn plain_transcript() -> Transcript {
    let mut t = Transcript::default();
    t.scrollbar = Scrollbar::Hidden;
    t
}

/// The two blocks as the view writes them: one code-mode band row (stored uncut, behind its marker) and
/// one fence (a frame of three rows, its body row stored uncut).
fn blocks() -> Transcript {
    let mut t = plain_transcript();
    t.write(&format!("\u{1}b{FILL}\u{1}\x1b[48;2;23;23;23m\x1b[38;2;200;200;200m{LINE}\x1b[0m\n"));
    t.write(&format!("{CARD_BORDER}\u{250c}\u{2500} bash{RESET}\n{CARD_BORDER}\u{2502} {LINE}{RESET}\n{CARD_BORDER}\u{2514}\u{2500}{RESET}\n"));
    t
}

/// The drawn rows, as a reader sees them (no escape sequences, no trailing blanks).
fn shown(rows: &[String]) -> Vec<String> {
    rows.iter().map(|r| plain(r).trim_end().to_string()).collect()
}

#[test]
fn a_run_box_and_a_fence_are_cut_at_the_width_of_the_frame_in_both_directions() {
    let fresh = |width: usize| blocks().view(width, 40);
    let mut resized = blocks();
    for width in [60usize, 120, 60] {
        let rows = resized.view(width, 40);
        assert_eq!(rows, fresh(width),
            "at {width} columns a resized chat draws what a fresh one draws at that width");
        let text = shown(&rows);
        let band = text.iter().position(|r| r.starts_with("sh -e <<'EOF'")).expect("the band row");
        let fence = text.iter().position(|r| r.starts_with("\u{2502} sh -e")).expect("the fence row");
        if width == 60 {
            // CUT: the row that is cut keeps the WHOLE width of the block and carries no mark...
            assert_eq!(visible(&rows[band]), 60,
                "at 60 the cut band row is the whole width, not one cell short of it: {:?}", text[band]);
            assert!(!text[band].contains('\u{21aa}'), "the mark is never inside the cut row: {:?}", text[band]);
            assert_eq!(visible(&rows[fence]), 60, "and the fence's cut row is the whole width: {:?}", text[fence]);
            assert!(!text[fence].contains('\u{21aa}'), "neither is the fence's: {:?}", text[fence]);
            // ...and the row the line goes on below opens with it, in the gutter, one cell in front of
            // the text column - the same mark in the same place in both blocks.
            assert!(text[band + 1].starts_with('\u{21aa}'),
                "the band's continuation opens with the mark in the gutter: {:?}", text[band + 1]);
            assert!(text[fence + 1].starts_with("\u{2502}\u{21aa}"),
                "and so does the fence's, behind its bar: {:?}", text[fence + 1]);
        } else {
            // The line fits at 120: one row each, whole, and no mark anywhere.
            assert_eq!(text[band], LINE, "at 120 the band row is the whole line, unmarked");
            assert_eq!(text[fence], format!("\u{2502} {LINE}"), "at 120 the fence row is the whole line, unmarked");
            assert!(!text.iter().any(|r| r.contains('\u{21aa}')),
                "a line that fits carries no mark at 120: {text:?}");
        }
    }
}
