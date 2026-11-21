# copy-clean - a mouse copy from the TUI chat carries no scrollbar glyph and no padding

Mission: Victor pasted text copied from `wa chat` (21/11) and every line ended with the bar glyph
`│`, padded with spaces - "make the scroll top level than the cli text so copying content from the
tui chat does not select the scroll".

Base: eae9a3a9 (origin/main). Branch change/copy-clean. One item: one commit for the change, one for
this report.

## What shipped

| item | commit | what it does |
|---|---|---|
| 1 | fae66f9a | A selection lives in the chat's columns: `selection::span`/`text`/`overlay` take `cols` and clamp every span to it, `Transcript::text_width` is the one answer to "how wide is the chat", the host stores it in `Selection` and clamps the anchor, the head and the copy, and `Transcript::bar_frame` puts the bar's own column back after the overlay clears a row. Three tests, plus the base check below. |

Nothing else was touched: no Lua, no keymap table, no scrollbar arithmetic (`scroll::bar`).

## Premises, re-measured before writing code

- `rust/wa-term/src/selection.rs:119` `text()` sliced each selected screen row from `from` to `to` and
  `trim_end()`ed it - true, and the only trimming: `│` survived. Confirmed the shape of Victor's paste.
- `lua/core/cli_view.lua:2132` "One column is left for the scrollbar": true, in the legacy Lua view.
  The live path is the Rust transcript (`rust/wa-term/src/transcript.rs`), which spends the same column
  - `Transcript::draw_bar` (`transcript.rs:679`) writes `fit(row, text_width)` and then the glyph, so a
  drawn row's last cell IS the bar and `text()` copied it. That is the fix's target.
- "A drag that starts on the scrollbar is a scrollbar drag, not a selection": already true - `keymap`'s
  `BarJump` runs before `TranscriptSelection` (`rust/wa-capabilities/src/host.rs:3767`) and `bar_press`
  returns true only on the bar's column, tested by `a_press_on_the_bar_scrolls_it_and_starts_no_selection`.
  What was missing is the other half, and it is what changed: a drag that wanders ONTO the bar's column
  now stops at the chat's last column (it never grabs the bar - `bar_drag` requires a press on the bar).
- "If the row model records a soft wrap": it does not. `wrap_rows` (`transcript.rs:835`) returns
  `Vec<String>` with no marker, `rows_with_copies` likewise, and `Selection.rows` is plain screen rows;
  a soft-wrapped logical line therefore still copies as two lines. Left alone, as the brief says - not
  guessed at. Doing it would need the wrap marker in the row model first.

## The change, by requirement

1. **The selection is the chat area only.** `selection::span` clamps both ends to `cols`
   (`selection.rs:114`), `within` cuts a row to `cols` cells (`selection.rs:123`) so nothing past them is
   copied or highlighted, `text` and `overlay` both use them (`selection.rs:127`, `:142`). `cols` comes
   from `Transcript::text_width` (`transcript.rs:698`, the same arithmetic `view` wraps at) and is stored
   in `Selection` (`host.rs:3729`), clamped at the press (`host.rs:3837`), at the drag (`host.rs:3893`),
   and used by both copy paths (release and Ctrl+C).
2. **What is highlighted is exactly what is copied.** The overlay paints the chat's columns only; a
   row's `2K` does clear the bar's column, so `layout_frame` writes the bar back with
   `Transcript::bar_frame` (`transcript.rs:707`, called at `host.rs:4007`) - the track keeps its glyph
   and colour, and the reverse video never covers it.
3. **A drag over the bar is the bar's.** A press on the bar scrolls and starts no selection (unchanged,
   cited above); a drag that reaches the bar's column stops at the chat's last one and takes nothing
   from it.
4. **Native Shift+drag** (the terminal's own selection): not fixable by drawing, and nothing was done
   there. A character-cell terminal selects columns of what was written to it; the bar is a cell in the
   last column of every chat row, and there is no way to draw a cell that a terminal's own selection
   skips - no layering, no clipping region, no "ignore this column" attribute. The only alternatives are
   not to draw the bar (losing a feature Victor asked for on 13/11) or to make the chat one column
   narrower and leave the column blank, which costs the same column and looks the same. Shift+drag still
   copies the bar's glyph, and that is the terminal's behaviour, not wa's.

## Tests

| test | file | what it pins |
|---|---|---|
| `selection::tests::a_multi_line_copy_stops_at_the_chat_and_carries_no_bar_and_no_padding` | rust/wa-term/src/selection.rs:215 | rows that end in the bar (track, thumb, thumb-active), a drag to the chat's last column and on to the bar's: no glyph, no trailing spaces, identical either way |
| `selection::tests::the_overlay_paints_the_chat_and_never_the_bar_column` | rust/wa-term/src/selection.rs:230 | the overlay's frame carries no bar glyph; a drag onto the bar's column produces the same frame |
| `host::terminal_tests::a_drag_onto_the_bar_column_copies_the_chat_and_never_the_bar` | rust/wa-capabilities/src/host.rs:5425 | the whole path: a real transcript with a real bar, a press in the text, a drag onto the bar's column, and the copied text (and its highlight) - the view test the brief asked for |

Wiring: they are `#[cfg(test)] mod tests` inside `wa-term` and `wa-capabilities`, and the fast path's
rust row already runs `cargo test` for every changed crate including both (`scripts/fast.sh:638`'s crate
list). No new row was needed and none was added.

Run here (avell, 16 cores), `HOME` a scratch dir, `flock -o` on the suite lock:

    cargo test --offline --manifest-path rust/Cargo.toml -p wa-term -p wa-capabilities
    test result: ok. 356 passed; 0 failed    (wa-capabilities)
    test result: ok. 176 passed; 0 failed    (wa-term)
    cargo check --offline --workspace       Finished, no new warning

Two wa-capabilities tests fail when `HOME` is NOT a scratch dir
(`operations::adoption_survives_the_relay_deadline`, `operations::await_returns_at_its_own_wait`): they
refuse to run on the operator's own home by design, and `scripts/test.sh` sets `HOME=$GATE_HOME` for
them. They are pre-existing, not this branch's.

## The base check (a test that cannot fail catches nothing)

A scratch worktree of eae9a3a9, the same two assertions written against the base's three-argument
`text()` and the base `Selection` (no `cols`), run there:

    test selection::tests::base_check_a_multi_line_copy_carries_no_bar_glyph ... FAILED
      no bar glyph: "anchors.            │\nsecond line         │\nthird               │"
    test host::terminal_tests::base_check_a_drag_onto_the_bar_column_copies_no_bar ... FAILED
      no glyph of the bar: " 366            │\nline 367        │\nline 368        │"

That is Victor's paste, reproduced from the base code. Both failed as assertions (not as a missing
symbol), and the branch's own versions pass. The scratch worktree and its target dir were removed;
`git worktree list` has no `base-copy-clean`.

## Not done / unknown

- Soft-wrapped lines still copy as several lines (requirement 3's "if the row model records it": it does
  not - see above).
- Native Shift+drag still takes the bar's glyph (requirement 4: nothing risky there, and nothing drawn
  can change it).
- `scripts/test.sh` and `scripts/fast.sh` were not run in full on this branch - the focused check was the
  two affected crates' whole suites plus a workspace `cargo check`. The Lua suite is untouched by the
  diff (no `.lua` file changed) but that is an argument, not a measurement.
- The fullscreen console (`scroll::chat`) has no text selection at all (only the bar takes its mouse), so
  there is nothing to clamp there.

## Texts to approve

None: no model- or operator-facing string was added or changed. The only new words are code comments,
doc comments and test assertion messages.
