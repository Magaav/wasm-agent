//! What a live region may put on the screen: rows, in SCREEN rows, at the width it is drawn at.
//!
//! Victor's report (19/11) is one frame of this: a code-mode line wider than the terminal is drawn
//! unclipped, the TERMINAL wraps it into several rows, everything below moves down - and while the
//! call's clock ticks and the row is rewritten, the content bounces.
//!
//! There is no cursor-up count to compare here: this transcript addresses every row absolutely
//! (`\x1b[{row};1H`, `Transcript::render`), so its only way of moving is a row whose HEIGHT
//! changes. That is what "the rows drawn equal the rows the frame claims" means for this renderer, and
//! it is asserted the stronger way: the same addresses, the same row count, frame after frame - and
//! every row that is not the live one keeps its exact text.
use wa_term::scroll::settings::Scrollbar;
use wa_term::scroll::vt::Vt;
use wa_term::transcript::{visible, Transcript};

/// The code line from Victor's screenshot: a script the model wrote, longer than any terminal.
fn long_code_line(columns: usize) -> String {
    let head = "const cmd = `ls -la /home/ubuntu/nextcloud | head -40; echo ===APPS; ls /home/ubuntu/nextcloud/apps ";
    let mut line = String::from(head);
    while visible(&line) < columns { line.push('x'); }
    line.push_str("`;");
    line
}

/// The running call's line, as the host rewrites it: the tool, its clock, and the tail of its output.
fn live_line(seconds: usize, tail: &str) -> String {
    format!("⏳ remote · bash · {seconds}s · {tail}")
}

/// A transcript shaped like the one on screen when the report was taken: the streaming script's band
/// rows, a settled call row, and a call still running (the row the clock rewrites in place).
fn running_script(columns: usize) -> Transcript {
    let mut t = Transcript::default();
    t.scrollbar = Scrollbar::Hidden;
    t.code_block();
    t.write(&format!("{}
", long_code_line(columns)));
    t.write("  ✓ bash · ls lua/core · 0.2s
");
    t.live(Some(&live_line(3, "remote call shape ok")));
    t
}

/// The row addresses a frame draws, in order: the rows the frame CLAIMS. The twin of a cursor-up
/// count for a renderer that addresses absolutely - if a frame's claims change, something moved.
fn claimed_rows(frame: &str) -> Vec<u16> {
    let mut out = Vec::new();
    let mut at = String::new();
    let mut chars = frame.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '' || chars.peek() != Some(&'[') { continue; }
        chars.next();
        at.clear();
        let mut last = ' ';
        for next in chars.by_ref() {
            last = next;
            if ('@'..='~').contains(&next) { break; }
            at.push(next);
        }
        if last == 'H' {
            if let Some(row) = at.split(';').next().and_then(|n| n.parse().ok()) { out.push(row); }
        }
    }
    out
}

/// Every row of a view is one SCREEN row at this width: nothing is wider than the terminal.
fn assert_fits(t: &mut Transcript, width: usize, height: usize, what: &str) {
    let rows = t.view(width, height);
    assert_eq!(rows.len(), height, "{what}: the region is exactly {height} rows at {width}");
    for (index, row) in rows.iter().enumerate() {
        let cells = visible(row);
        assert!(cells <= width, "{what}: row {index} is {cells} cells at width {width}: {row:?}");
    }
}

#[test]
fn a_300_column_code_line_fits_the_region_at_every_width() {
    for width in [60usize, 80, 120, 200] {
        let mut t = running_script(300);
        assert_fits(&mut t, width, 20, "a 300-column script");
    }
}

#[test]
fn the_live_row_is_one_screen_row_however_long_its_tail_is() {
    // THE defect, measured where a reader sees it: the live line was wrapped like prose, so each new
    // tail (its clock, the last line of output) could add a row to the block - and a block that grows
    // pushes everything under it. Counting the rows that carry the prefix would MISS a wrap, because a
    // continuation row does not carry it; so the measure is the whole screen: every row that is not
    // the live one must keep its exact text, frame after frame.
    for width in [60usize, 80, 120, 200] {
        let mut t = running_script(20);
        let height = 20;
        let mut first: Option<Vec<String>> = None;
        for tick in 0..20 {
            let tail = "y".repeat(tick * 7);
            t.live(Some(&live_line(3 + tick, &tail)));
            let rows = t.view(width, height);
            assert_eq!(rows.len(), height, "width {width} tick {tick}: the region kept its height");
            for (index, row) in rows.iter().enumerate() {
                assert!(visible(row) <= width,
                    "width {width} tick {tick}: row {index} is {} cells: {row:?}", visible(row));
            }
            match &first {
                None => first = Some(rows.clone()),
                Some(was) => {
                    for (index, (now, then)) in rows.iter().zip(was.iter()).enumerate() {
                        if now.contains('⏳') || then.contains('⏳') { continue; }
                        assert_eq!(now, then,
                            "width {width} tick {tick}: row {index} moved while the live line grew");
                    }
                }
            }
        }
        let rows = first.expect("twenty frames");
        let live: Vec<&String> = rows.iter().filter(|row| row.contains('⏳')).collect();
        assert_eq!(live.len(), 1, "width {width}: the live line is ONE screen row: {rows:?}");
    }
}

#[test]
fn twenty_ticks_move_nothing_and_draw_the_same_rows_every_frame() {
    // The brief's "tick 20 times and assert the count equals the rows drawn": drawn through the
    // emulator, so the assertion is on the SCREEN and not on the bytes the transcript meant.
    for width in [60usize, 80, 120, 200] {
        let mut t = running_script(300);
        let height = 20;
        let mut v = Vt::new(width, height);
        let mut addresses = None;
        for tick in 0..20 {
            t.live(Some(&live_line(3 + tick, &format!("tail {}", "z".repeat(tick * 9)))));
            let frame = t.render(width, height);
            let claimed = claimed_rows(&frame);
            if let Some(previous) = &addresses {
                assert_eq!(&claimed, previous, "width {width} tick {tick}: the same rows, at the same addresses");
            }
            addresses = Some(claimed);
            v.feed_str(&frame);
            let screen = v.rows();
            assert_eq!(screen.len(), height, "width {width} tick {tick}: the screen kept its height");
            let live: Vec<&String> = screen.iter().filter(|row| row.contains('⏳')).collect();
            assert_eq!(live.len(), 1, "width {width} tick {tick}: the clock's row wrapped: {screen:?}");
        }
    }
}

#[test]
fn a_resize_rewraps_the_same_live_line_without_moving_the_rest() {
    // 60 -> 120 -> 200 -> 80 -> 60: the region is redrawn at each width, and each frame fits its own.
    let mut t = running_script(300);
    for width in [60usize, 120, 200, 80, 60] {
        assert_fits(&mut t, width, 20, "after a resize");
        if width == 80 { t.live(None); }
    }
}
