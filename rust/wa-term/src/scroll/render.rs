//! The render tests: a fixed-size virtual terminal, the console's own frames, and assertions on the
//! screen a reader would see.
//!
//! Every test here drives the real seam the host will use - `Console::feed` with the bytes a terminal
//! sends, `Console::write` with the output a run produces, `Console::frame` with the real
//! `terminal_editor::Editor` - and reads `vt.rs` instead of the escape bytes. Scroll position, follow
//! mode, the marker, the folds, a resize and the restore are facts about that screen, so that is where
//! they are asserted.
use super::chat::Kind;
use super::screen::{self, Console, Handled};
use super::settings::{Mode, Settings};
use super::vt::Vt;
use crate::selection::plain;
use crate::terminal_editor::Editor;

const PAGE_UP: &[u8] = b"\x1b[5~"; // PageUp
const PAGE_DOWN: &[u8] = b"\x1b[6~";
const CTRL_HOME: &[u8] = b"\x1b[1;5H";
const CTRL_END: &[u8] = b"\x1b[1;5F";
const WHEEL_UP: &[u8] = b"\x1b[<64;10;10M";
const WHEEL_DOWN: &[u8] = b"\x1b[<65;10;10M";

fn settings(env: &[(&str, &str)]) -> Settings {
    let pairs: Vec<(String, String)> = env.iter().map(|(key, value)| (key.to_string(), value.to_string())).collect();
    Settings::from_env(move |name| pairs.iter().find(|(key, _)| key == name).map(|(_, value)| value.clone()))
}

/// A console on a virtual terminal of a fixed size, with the input editor configured the way the host
/// configures it (`EDITOR_ROWS` = 3).
struct Term {
    console: Console,
    vt: Vt,
    width: usize,
    height: usize,
    editor: Editor,
    handoffs: Vec<Handled>,
}

impl Term {
    fn new(env: &[(&str, &str)], width: usize, height: usize) -> Term {
        let mut console = Console::new(settings(env), Mode::Fullscreen);
        let mut vt = Vt::new(width, height);
        vt.feed_str(&screen::enter_bytes(console.mode));
        let mut editor = Editor::default();
        editor.height = 3;
        editor.footer = "esc to interrupt".into();
        editor.footer_right = "model".into();
        console.write("");
        Term { console, vt, width, height, editor, handoffs: Vec::new() }
    }

    fn draw(&mut self) {
        let mut editor = std::mem::take(&mut self.editor);
        let frame = self.console.frame(&mut editor, self.width, self.height);
        self.vt.feed_str(&frame);
        self.editor = editor;
    }

    fn feed(&mut self, bytes: &[u8]) {
        let handled = self.console.feed(bytes);
        self.handoffs.push(handled);
        self.draw();
    }

    fn rows(&self) -> Vec<String> { self.vt.rows() }
    fn row(&self, row: usize) -> String { self.vt.row(row) }
    fn screen(&self) -> String { self.rows().join("\n") }
    /// The text a row shows, without the scrollbar's column: what a reader reads.
    fn row_text(&self, row: usize) -> String { strip_bar(&self.row(row)) }
    fn text_rows(&self) -> Vec<String> { (0..self.height).map(|row| self.row_text(row)).collect() }

    /// The rows the chat owns at this height: everything above the input box.
    fn chat_rows(&self) -> usize { Console::region(&self.editor) }
}

fn lines(term: &mut Term, count: usize) {
    for n in 0..count { term.console.write(&format!("line {n}\n")); }
}

/// A row without the scrollbar column, trimmed: the reader's text. The bar's three glyphs are the
/// model's (`scroll::bar`): `│` the track, `┃` the thumb, `█` the thumb under the pointer.
fn strip_bar(row: &str) -> String {
    let text = plain(row).trim_end().to_string();
    let stripped = text.strip_suffix('\u{2588}')
        .or_else(|| text.strip_suffix('\u{2503}'))
        .or_else(|| text.strip_suffix('\u{2502}'));
    stripped.unwrap_or(&text).trim_end().to_string()
}

#[test]
fn fullscreen_enters_the_alternate_screen_and_pins_the_editor_below_the_chat() {
    let mut term = Term::new(&[], 80, 24);
    lines(&mut term, 40);
    term.draw();
    assert!(term.vt.on_alt(), "the chat is drawn on the alternate screen");
    assert!(term.vt.mouse, "SGR mouse reports are on for the wheel");
    assert_eq!(term.chat_rows(), 20, "twenty rows of chat above the box at 24 rows");
    assert_eq!(term.row_text(0), "line 20", "following the newest output, bottom-anchored");
    assert_eq!(term.row_text(19), "line 39");
    assert!(term.row(20).starts_with('\u{2500}') && term.row(20).ends_with('\u{2500}'), "the box's top border: {:?}", term.row(20));
    assert!(term.row(21).starts_with("\u{276f} "), "the draft row: {:?}", term.row(21));
    assert!(term.row(22).starts_with('\u{2500}'), "the box's bottom border: {:?}", term.row(22));
    assert_eq!(term.row(23), "esc to interrupt                                                           model", "the footer keeps its row, with the model on the right");
    assert!(term.vt.cursor_visible, "the cursor comes back to the draft at the end of the frame");
    assert_eq!(term.vt.cursor, (21, 2), "and it is on the draft, after the prompt");
}

#[test]
fn page_up_moves_one_screen_and_the_ends_are_the_ends() {
    let mut term = Term::new(&[], 80, 24);
    lines(&mut term, 100);
    term.draw();
    assert_eq!(term.row_text(19), "line 99");
    term.feed(PAGE_UP);
    assert_eq!(term.console.chat().scrolled(), 19, "a page is the chat's height less one row");
    assert_eq!(term.row_text(0), "line 61", "one page up from the bottom");
    assert_eq!(term.row_text(19), "line 80", "and its last row");
    term.feed(CTRL_HOME);
    assert_eq!(term.row_text(0), "line 0", "Ctrl+Home is the top");
    term.feed(CTRL_END);
    assert_eq!(term.row_text(19), "line 99", "Ctrl+End is the bottom");
    assert!(term.console.chat().following(), "and it follows again");
    term.feed(PAGE_UP);
    term.feed(PAGE_DOWN);
    assert!(term.console.chat().following(), "PageDown at the bottom stays there");
    assert_eq!(term.row_text(19), "line 99");
}

#[test]
fn new_output_while_scrolled_up_does_not_move_the_view_and_shows_the_marker() {
    let mut term = Term::new(&[], 80, 24);
    lines(&mut term, 100);
    term.draw();
    term.feed(PAGE_UP);
    let before = term.text_rows();
    for n in 100..105 { term.console.write(&format!("line {n}\n")); }
    term.draw();
    let after = term.text_rows();
    assert_eq!(&before[..19], &after[..19], "what the reader was reading stayed still: {after:?}");
    assert_eq!(after[19], "\u{2193} 5 new lines", "the arrivals are counted on one row: {after:?}");
    term.feed(CTRL_END);
    let followed = term.text_rows();
    assert_eq!(followed[19], "line 104", "Ctrl+End shows the newest output");
    assert!(!followed.iter().any(|row| row.contains("new line")), "and the marker is gone: {followed:?}");
    // A single arrival says so in the singular.
    term.feed(PAGE_UP);
    term.console.write("line 105\n");
    term.draw();
    assert_eq!(term.text_rows()[19], "\u{2193} 1 new line");
}

#[test]
fn ctrl_o_folds_tool_output_and_ctrl_t_expands_thinking() {
    let mut term = Term::new(&[], 80, 24);
    term.console.begin(Kind::Tool);
    term.console.write("\u{23fa} Bash(cargo test)\ncompiling\nrunning 3 tests\nok\nok\nok\nexit 0\n");
    term.console.begin(Kind::Thinking);
    term.console.write("\u{273b} Thinking\u{2026}\nfirst thought\ndeep thought\n");
    term.console.begin(Kind::Prose);
    term.console.write("the answer\n");
    term.draw();
    let folded = term.screen();
    assert!(folded.contains("Bash(cargo test)") && folded.contains("running 3 tests"), "{folded}");
    assert!(!folded.contains("exit 0"), "tool output is collapsed to its summary and first lines: {folded}");
    assert!(folded.contains("+4 lines"), "{folded}");
    assert!(!folded.contains("deep thought") && folded.contains("+2 lines"), "thinking to its title: {folded}");
    assert!(folded.contains("the answer"), "prose never folds");
    term.feed(b"\x0f");
    let tools = term.screen();
    assert!(tools.contains("exit 0"), "Ctrl+O expands the tool output: {tools}");
    assert!(!tools.contains("deep thought"), "and leaves thinking as it was");
    term.feed(b"\x14");
    assert!(term.screen().contains("deep thought"), "Ctrl+T expands thinking");
    term.feed(b"\x0f");
    assert!(!term.screen().contains("exit 0"), "Ctrl+O folds it again");
}

#[test]
fn a_resize_repins_the_editor_and_leaves_no_row_of_the_old_frame() {
    let mut term = Term::new(&[], 80, 24);
    lines(&mut term, 60);
    term.draw();
    term.width = 60;
    term.height = 14;
    term.vt.resize(60, 14);
    term.draw();
    assert_eq!(term.chat_rows(), 10, "ten rows of chat at 14 rows");
    assert_eq!(term.row_text(9), "line 59", "still following the newest");
    assert!(term.row(10).starts_with('\u{2500}'), "the box moved up with the screen: {:?}", term.row(10));
    assert!(term.row(12).starts_with('\u{2500}'), "{:?}", term.row(12));
    assert!(term.row(13).starts_with("esc to interrupt"), "the footer is on the last row: {:?}", term.row(13));
    assert!(!term.rows()[10..].iter().any(|row| row.contains("line 5")), "no chat row survives under the box: {:?}", &term.rows()[10..]);
    // A wider chat re-wraps prose rather than leaving the old cut: one long line at two widths.
    let mut term = Term::new(&[], 80, 24);
    let prose = "word ".repeat(40);
    term.console.begin(Kind::Prose);
    term.console.write(&format!("{}\n", prose.trim()));
    term.draw();
    let wide = term.rows()[..20].iter().filter(|row| row.contains("word")).count();
    term.width = 40;
    term.vt.resize(40, 24);
    term.draw();
    let narrow = term.rows()[..20].iter().filter(|row| row.contains("word")).count();
    assert!(narrow > wide, "the same paragraph takes more rows at 40 columns: {wide} -> {narrow}");
    assert!(term.rows()[..20].iter().all(|row| row.chars().count() <= 40), "and never overflows the width");
}

#[test]
fn the_wheel_scrolls_the_configured_number_of_rows() {
    let mut term = Term::new(&[], 80, 24);
    lines(&mut term, 100);
    term.draw();
    assert!(term.vt.mouse);
    term.feed(WHEEL_UP);
    assert_eq!(term.console.chat().scrolled(), 3, "auto: the inline console's three rows");
    assert_eq!(term.row_text(19), "line 96", "and the view moved by exactly that");
    term.feed(WHEEL_DOWN);
    assert!(term.console.chat().following(), "the wheel down returns to the bottom");

    let mut five = Term::new(&[("WA_TUI_WHEEL_LINES", "5")], 80, 24);
    lines(&mut five, 100);
    five.draw();
    five.feed(WHEEL_UP);
    assert_eq!(five.console.chat().scrolled(), 5, "WA_TUI_WHEEL_LINES=5");
}

#[test]
fn the_scrollbar_is_shown_by_its_setting_in_the_last_column() {
    let mut term = Term::new(&[], 80, 24);
    lines(&mut term, 100);
    term.draw();
    let drawn = term.row(19).chars().last().unwrap();
    assert!(drawn == '\u{2588}' || drawn == '\u{2503}' || drawn == '\u{2502}', "auto with 100 rows in 20: {:?}", term.row(19));
    assert!(term.rows()[..20].iter().all(|row| plain(row).chars().count() == 80), "the bar owns the last column");
    let mut hidden = Term::new(&[("WA_TUI_SCROLLBAR", "hidden")], 80, 24);
    lines(&mut hidden, 100);
    hidden.draw();
    assert!(!hidden.rows()[..20].iter().any(|row| row.contains('\u{2588}') || row.contains('\u{2503}') || row.contains('\u{2502}')), "{:?}", &hidden.rows()[..3]);
    assert_eq!(strip_bar(&hidden.row(19)), "line 99", "no bar, and the row is all text");
    let mut short = Term::new(&[("WA_TUI_SCROLLBAR", "always")], 80, 24);
    short.console.write("one\ntwo\n");
    short.draw();
    assert!(short.rows()[..20].iter().all(|row| row.ends_with('\u{2588}') || row.ends_with('\u{2503}') || row.ends_with('\u{2502}')), "always: {:?}", &short.rows()[..3]);
}

/// One SGR mouse report: `button` 0 = the left button, 32 = a drag with it down, 35 = motion with
/// no button, and 64/65 the wheel. `press` false is the button coming up (lowercase `m`).
fn sgr(button: u8, col: usize, row: usize, press: bool) -> Vec<u8> {
    format!("\x1b[<{};{};{}{}", button, col, row, if press { 'M' } else { 'm' }).into_bytes()
}

/// The bar's glyphs, one per row of the chat region: the column a reader sees.
fn bar_column(term: &Term) -> String {
    (0..term.chat_rows()).map(|row| term.row(row).chars().last().unwrap_or(' ')).collect()
}

fn counts(term: &Term, glyph: char) -> usize {
    (0..term.chat_rows()).filter(|&row| term.row(row).ends_with(glyph)).count()
}

#[test]
fn the_track_is_one_continuous_line_at_every_height() {
    // The operator's screenshot: the track was drawn as segments with air between them. Every row
    // of the region carries a bar cell, and the column is the same column on every row.
    for (width, height) in [(80usize, 24usize), (60, 14), (40, 8), (24, 6)] {
        let mut term = Term::new(&[], width, height);
        lines(&mut term, 300);
        term.draw();
        let region = term.chat_rows();
        assert!(region >= 1, "{width}x{height}: the chat owns rows");
        for row in 0..region {
            let last = term.row(row).chars().last().unwrap();
            assert!(matches!(last, '\u{2502}' | '\u{2503}' | '\u{2588}'),
                "{width}x{height} row {row} has no bar cell: {:?}", term.row(row));
            assert_eq!(term.row(row).chars().count(), width, "{width}x{height} row {row} is exactly the width");
        }
        assert!(counts(&term, '\u{2502}') + counts(&term, '\u{2503}') == region, "{width}x{height}: {bar_column:?}",
            bar_column = bar_column(&term));
        // A click on the track's last row is the bottom of the chat - where the track has room to
        // move at all: a one- or two-row track is all thumb, and a click on it cannot go anywhere.
        if region >= 3 {
            term.feed(&sgr(0, width, region, true));
            assert_eq!(term.row_text(region - 1), "line 299", "{width}x{height}: {bar_column:?}",
                bar_column = bar_column(&term));
            term.feed(&sgr(0, width, region, false));
        }
    }
}

#[test]
fn a_click_on_the_track_jumps_there_and_a_drag_scrolls() {
    let mut term = Term::new(&[], 80, 24);
    lines(&mut term, 100);
    term.draw();
    assert_eq!(term.row_text(0), "line 80", "forty rows of chat: following, the newest at the bottom");
    // Two rows below the top of the track: the chat's top, and the thumb thick while it is held.
    term.feed(&sgr(0, 80, 2, true));
    assert_eq!(term.row_text(0), "line 0", "the click jumped to the top: {:?}", term.text_rows());
    assert!(counts(&term, '\u{2588}') >= 2, "the grabbed thumb is thick: {:?}", term.rows());
    assert_eq!(counts(&term, '\u{2503}'), 0, "and no thin thumb is left: {:?}", term.rows());
    // Dragged down the track: the view follows the pointer, and at the bottom it follows again.
    term.feed(&sgr(32, 80, 15, true));
    let mid = term.console.chat().scrolled();
    assert!(mid > 0 && mid < 80, "a drag down scrolls toward the bottom: {mid}");
    term.feed(&sgr(32, 80, 20, true));
    assert_eq!(term.row_text(19), "line 99", "the drag's end is the newest output: {:?}", term.text_rows());
    assert!(term.console.chat().following(), "and the chat follows again at the bottom");
    // The button up: the thumb is thin again.
    term.feed(&sgr(0, 80, 20, false));
    assert_eq!(counts(&term, '\u{2588}'), 0, "no pointer, no thick thumb: {:?}", term.rows());
    // Nothing the bar took was typed into the draft.
    let forwarded: Vec<u8> = term.handoffs.iter().flat_map(|handled| handled.forwarded.clone()).collect();
    assert!(forwarded.is_empty(), "no mouse report reached the draft: {forwarded:?}");
}

#[test]
fn the_thumb_thickens_under_the_pointer_and_thins_when_it_leaves() {
    let mut term = Term::new(&[], 80, 24);
    lines(&mut term, 100);
    term.draw();
    let thin = counts(&term, '\u{2503}');
    assert!(thin >= 2 && counts(&term, '\u{2588}') == 0, "at rest: a thin thumb: {bar:?}", bar = bar_column(&term));
    // Motion with no button down, over the bar's column: thicker, in the same rows.
    term.feed(&sgr(35, 80, 10, true));
    assert_eq!(counts(&term, '\u{2588}'), thin, "hovering thickens the thumb: {bar:?}", bar = bar_column(&term));
    assert_eq!(counts(&term, '\u{2503}'), 0, "and thins nothing else: {bar:?}", bar = bar_column(&term));
    // The same motion over the chat's text: thin again - the bar is one column, not the screen.
    term.feed(&sgr(35, 40, 10, true));
    assert_eq!(counts(&term, '\u{2503}'), thin, "the pointer left: thin again: {bar:?}", bar = bar_column(&term));
    assert_eq!(counts(&term, '\u{2588}'), 0);
    // A pointer that stays where it is costs no frame: the third report changes nothing.
    let before = term.console.chat().wraps();
    term.feed(&sgr(35, 40, 11, true));
    assert_eq!(term.console.chat().wraps(), before, "a hover that changed nothing re-wrapped nothing");
}

#[test]
fn a_frame_of_the_bar_is_the_screen_a_reader_sees() {
    // A snapshot: twenty-five rows in six, at forty columns. The bar is the last column of every
    // row - the thumb where the reader is (the bottom, following), the track above it.
    let mut term = Term::new(&[], 40, 10);
    for n in 0..25 { term.console.write(&format!("row {n}\n")); }
    term.draw();
    let screen: Vec<String> = (0..term.chat_rows()).map(|row| term.row(row).trim_end().to_string()).collect();
    assert_eq!(screen, vec![
        "row 19                                 \u{2502}",
        "row 20                                 \u{2502}",
        "row 21                                 \u{2502}",
        "row 22                                 \u{2502}",
        "row 23                                 \u{2503}",
        "row 24                                 \u{2503}",
    ], "the frame: {screen:?}");
    // And the same picture folded to its bar: one line, no gap between the thumb and the track.
    assert_eq!(bar_column(&term), "\u{2502}\u{2502}\u{2502}\u{2502}\u{2503}\u{2503}");
    // The editor keeps its rows under it, untouched.
    assert!(term.row(6).starts_with('\u{2500}'), "the box is where it was: {:?}", term.row(6));
    assert_eq!(strip_bar(&term.row(9)), "esc to interrupt                   model");
}

#[test]
fn the_console_writes_the_bars_cell_at_its_own_column_on_every_row() {
    // The same rule as the inline transcript: the bar's cell is written at an absolute column after
    // the row, so an over-wide row cannot carry the glyph onto the next line and leave a break.
    let mut console = Console::new(settings(&[]), Mode::Fullscreen);
    console.write(&"word ".repeat(400));
    let mut editor = Editor::default();
    editor.height = 3;
    let frame = console.frame(&mut editor, 40, 12);
    let bar = console.chat().bar().expect("a long chat draws the bar");
    assert_eq!(bar.track, Console::region(&editor), "the track is the chat's own height");
    for (row, (glyph, colour)) in bar.cells().iter().enumerate() {
        let at = format!("\x1b[{};40H{colour}{glyph}", row + 1);
        assert!(frame.contains(&at), "row {} writes its bar at column 40: {at:?} in {frame:?}", row + 1);
    }
}

#[test]
fn inline_mode_draws_nothing_and_leaves_the_editor_where_it_was() {
    let mut console = Console::new(settings(&[]), Mode::Inline);
    console.write("a line\n");
    let mut editor = Editor::default();
    editor.height = 3;
    assert_eq!(console.frame(&mut editor, 80, 24), "", "the fallback frame is empty");
    assert_eq!((editor.row, editor.width), (0, 0), "and the editor is not moved or resized");
    assert!(screen::enter_bytes(Mode::Inline).is_empty() && screen::leave_bytes(Mode::Inline).is_empty());
    assert_eq!(console.feed(WHEEL_UP), Handled { forwarded: WHEEL_UP.to_vec(), changed: false }, "the fallback hands every byte back");
    // The mode decision itself, which is what the caller selects the console with.
    assert_eq!(settings(&[]).mode(&["--inline".to_string()], |_| None, true), Mode::Inline);
    assert_eq!(settings(&[("WA_TUI_FULLSCREEN", "off")]).mode(&[], |_| None, true), Mode::Inline);
    assert_eq!(settings(&[]).mode(&[], |_| None, false), Mode::Inline);
}

#[test]
fn key_report_classifies_the_batch_buttons_start_presses_and_releases() {
    // The wheel is a mouse report, not a key: it must never reach the draft.
    let mut console = Console::new(settings(&[]), Mode::Fullscreen);
    assert_eq!(console.feed(WHEEL_UP), Handled { forwarded: Vec::new(), changed: true });
    // A report split across two reads is held, not forwarded.
    let (head, tail) = WHEEL_UP.split_at(5);
    assert_eq!(console.feed(head), Handled::default());
    assert_eq!(console.feed(tail).forwarded, Vec::<u8>::new(), "the rest of the report is not typed");
}

#[test]
fn keys_the_chat_does_not_own_reach_the_draft_unchanged() {
    let mut term = Term::new(&[], 80, 24);
    lines(&mut term, 100);
    term.draw();
    term.feed(b"hello");
    term.feed(b"\x15");            // Ctrl+U: unbound, and the draft's kill-line
    term.feed(b"\x1b[D");          // Left
    let forwarded: Vec<u8> = term.handoffs.iter().flat_map(|handled| handled.forwarded.clone()).collect();
    assert_eq!(forwarded, b"hello\x15\x1b[D".to_vec(), "every unbound byte, in order");
    assert_eq!(forwarded.iter().filter(|byte| **byte == 0x1b).count(), 1, "the wheel report put no escape into the draft");
    term.handoffs.clear();
    term.feed(PAGE_UP);
    assert!(term.handoffs[0].forwarded.is_empty(), "PageUp is the chat's and is consumed");
    // And what was forwarded actually drives the editor it was forwarded to.
    let mut editor = Editor::default();
    editor.width = 40;
    editor.height = 3;
    for &byte in b"hello\x15" { editor.feed(byte); }
    assert_eq!(editor.render(), Editor::default().render(), "Ctrl+U emptied the draft (both frames are the empty placeholder)");
}

#[test]
fn half_page_and_line_scroll_once_an_operator_binds_them() {
    let mut unbound = Term::new(&[], 80, 24);
    lines(&mut unbound, 100);
    unbound.draw();
    unbound.feed(b"\x1bv"); // Alt+V
    assert_eq!(unbound.console.chat().scrolled(), 0, "unbound by default");
    assert_eq!(unbound.handoffs[0].forwarded, b"\x1bv".to_vec(), "and the editor keeps it");

    let mut bound = Term::new(&[("WA_TUI_KEYS", "alt+v=half-page-down,ctrl+u=line-up")], 80, 24);
    lines(&mut bound, 100);
    bound.draw();
    bound.feed(PAGE_UP);
    let page = bound.console.chat().scrolled();
    assert_eq!(page, 19, "one page up");
    bound.feed(b"\x1bv");
    assert_eq!(bound.console.chat().scrolled(), 10, "half a page down: 19 - 9");
    bound.feed(b"\x15");
    assert_eq!(bound.console.chat().scrolled(), 11, "and a line up");
    assert!(bound.handoffs.iter().all(|handled| handled.forwarded.is_empty()), "bound keys do not reach the draft");
}

#[test]
fn the_status_line_keeps_its_own_row_when_a_run_is_in_flight() {
    let mut term = Term::new(&[], 80, 24);
    lines(&mut term, 40);
    term.editor.status = true; // what `host.editor_status` sets while a turn runs
    term.draw();
    assert_eq!(term.chat_rows(), 19, "the status line takes a row from the chat");
    assert_eq!(term.row_text(18), "line 39", "the chat ends above it");
    assert_eq!(term.row_text(19), "", "and the status row is the ticker's, not the chat's");
    assert!(term.row(20).starts_with('\u{2500}'), "the box is still under it: {:?}", term.row(20));
    assert_eq!(strip_bar(&term.row(23)), "esc to interrupt                                                           model");
}

#[test]
fn ctrl_c_reaches_the_driver_and_the_guard_gives_the_screen_back() {
    let mut term = Term::new(&[], 80, 24);
    lines(&mut term, 10);
    term.draw();
    term.feed(b"a draft");
    term.feed(b"\x03"); // Ctrl+C: raw mode means byte 3, and it is the editor's, never the chat's
    let forwarded: Vec<u8> = term.handoffs.iter().flat_map(|handled| handled.forwarded.clone()).collect();
    assert_eq!(forwarded, b"a draft\x03".to_vec(), "the interrupt is forwarded, not swallowed");
    let seen = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
    {
        let _guard = super::screen::Guard::with_sink(Mode::Fullscreen, {
            let seen = seen.clone();
            move |bytes: &str| seen.lock().unwrap().push_str(bytes)
        });
    }
    let bytes = seen.lock().unwrap().clone();
    assert!(bytes.ends_with("\x1b[?1049l"), "the screen is given back when the session ends, Ctrl+C included: {bytes:?}");
}

#[test]
fn leaving_gives_back_the_screen_the_shell_had() {
    let mut console = Console::new(settings(&[]), Mode::Fullscreen);
    let mut vt = Vt::new(60, 12);
    vt.feed_str("$ cargo run\r\nrunning\r\n$ ");
    let shell = vt.rows();
    vt.feed_str(&screen::enter_bytes(console.mode));
    let mut editor = Editor::default();
    editor.height = 3;
    console.write("a chat line\n");
    vt.feed_str(&console.frame(&mut editor, 60, 12));
    assert_ne!(vt.rows(), shell, "the chat is not on the shell's screen");
    vt.feed_str(&screen::leave_bytes(console.mode));
    assert_eq!(vt.rows(), shell, "and the shell's screen is exactly as it was");
    assert!(!vt.on_alt() && vt.cursor_visible && !vt.mouse, "alternate screen left, cursor back, mouse off");
    assert_eq!(vt.cursor, (2, 2), "with the cursor where the shell left it");
}
