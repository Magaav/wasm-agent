# tui-chrome - the input box grows, the fence keeps its corner, the footer icons measured

Branch `change/tui-chrome`, on `origin/main` 975d4612. Three items, in the order asked.

| Item | State |
| --- | --- |
| A. the input area grows, scrolls, has a bar, takes the wheel | fixed and tested |
| B. the copy icon on a code fence | fixed and tested |
| C. the footer icons | diagnosed with numbers, NOT fixed (as asked for this round); test wired as a named SKIP |

## Commits

- `9f5d449e` **A** - the input box grows to max(3, 30% of the window), scrolls under the transcript's
  bar, takes the wheel. Files: `rust/wa-term/src/terminal_editor.rs`, `rust/wa-term/src/selection.rs`,
  `rust/wa-term/src/scroll/screen.rs`, `rust/wa-term/src/keymap.rs`, `rust/wa-capabilities/src/host.rs`,
  `scripts/test-tui-chrome-pty.mjs` (new), `scripts/fast.sh`.
- `4de72812` **B** - a fence's copy icon sits after its corner and the click follows it. Files:
  `rust/wa-term/src/transcript.rs`, `scripts/test-tui-chrome-pty.mjs` (section B).
- the commit after `4de72812` **C** - `scripts/test-status-icon-metrics.py` (new), its row in `scripts/fast.sh`, this report.

No Lua file changed (`lua/core/cli_view.lua` is untouched, so nothing to merge with the run-block branch).
Nothing the model sees changed.

## A. Who owns the input's rows and the wheel

**The Rust host owns both.**

- Rows: `wa_term::terminal_editor::Editor` (`frame_geometry`). Lua only passes a number:
  `lua/core/cli_view.lua` `M.EDITOR_ROWS = 3` goes to `host.input_editor(row, width, 3)`, and
  `rust/wa-capabilities/src/host.rs` `input_editor` clamps it to `1..=3`. The box then showed
  `lines.clamp(1, height)` rows. That is why it never passed three. `lua/core/cli_input.lua` does not
  decide the row count.
- Wheel: `rust/wa-capabilities/src/host.rs` `handle_mouse` sent every wheel report to
  `state.transcript.page(±3)`. The report's position was thrown away at parse time
  (`wa_term::selection::decode` returned `Mouse::WheelUp` with no cell), so the host could not know
  where the pointer was.

What changed:

- `Editor::max_rows()` = `max(height, (row + 1) * 3 / 10)`, where `row + 1` is the window's row count.
  It is computed from the editor's own row on every frame, so a resize needs no extra state.
  40 rows -> 12, 12 rows -> 3, 10 rows -> 3.
- Past the limit the draft scrolls; the cursor's line is the one kept in view (as before).
- When the draft overflows, the box's last column carries `scroll::bar::Bar` - the same track, thumb
  and colours as the transcript's - and the draft wraps one cell earlier so no character is under it.
- `Mouse::WheelUp/WheelDown` now carry `(row, col)`. A wheel report over the box, with a draft that
  overflows, moves the draft three lines (`Editor::wheel`) and leaves the chat alone. Anywhere else,
  or with a draft that fits, the wheel is the transcript's as before.
- After the wheel moved the cursor's line out of the box the cursor is hidden; any key brings its line back.

**A decision I took:** the brief's text says "30% of the transcript area's height" but its own examples
("a 40-row window: up to 12 lines; a 10-row window: 3") and its done-when (12 rows at 80x40) are 30% of
the WINDOW's rows. I implemented the examples. 30% of the transcript area at 40 rows would be 10 or 11.

Not done in A: the input's bar is drawn but is not clickable or draggable (the transcript's is); the
thumb does not thicken on hover. A drag selection inside the box uses the same geometry as before and
the unit test for it still passes, but I did not drive a drag in the pty.

## B. Why the earlier fixes did not hold

**The host chooses the icon's column, not the marker.** The Lua marker (`host.transcript_copy`,
`lua/core/cli_view.lua` ~2753) says only "line N of the next write is copyable, with this content".
`rust/wa-term/src/transcript.rs` `rows_with_copies` then drew the icon by PREFIXING `COPY_PREFIX`
(`⧉ `) to that row, and `copy_at` accepted a click only in the first two cells. So however the fence
was drawn on the Lua side, the host put the icon back in cell 1 and pushed the corner two cells right.
A fix had to be in the host.

What changed: a marked row that opens with `┌─` gets the icon between the corner and the title
(`icon_after_corner`), and its column travels with the marker through the existing `RIGHT_TAG` path
(the one the run block's right-end icon uses), so hover-brightening and the click follow it.
`is_card_opening` judges the row without the icon; without that the card frame stopped opening and
long code lines lost their bar on a narrow screen (`test-fence-card-pty` caught it: 4 failures, then 25 ok).

Run blocks are not changed. A fence drawn with the rounded corner `╭─` (a code-mode script card in a
tool block) keeps the old prefix: only `┌─` was asked for and tested.

The click target is the existing `RIGHT_TAG` tolerance: the icon's cell and one cell either side
(plus one more on the right). A click on the corner copies nothing (tested).

## C. The footer icons - diagnosis

Font source and build: `scripts/build-wa-icons.py` (needs fontTools in a venv; pinned Nerd Fonts and
JetBrains Mono archives) builds `assets/fonts/waIcons-Regular.ttf`; manifest `assets/fonts/waIcons.json`;
existing parser test `tests/test-wa-fonts.mjs`. The installed `~/.local/share/fonts/waIcons-Regular.ttf`
is byte-identical to the tree's.

python3 on this laptop has **no fontTools**, and installing it means the network, so the new script
reads the TrueType tables with `struct` (head, hhea, hmtx, cmap, loca, glyf).

What the two rows draw (`lua/core/cli_view.lua` `run_numbers` ~1906, `session_summary` ~453). The
brief's `⟡ 👣 ⏱ ↻ ◔ ⛃` are stand-ins: the code draws private-use code points (set `wa`/`nerd`) or
`▸ ◷ ↻ ▤ ○◔◑◕● ✓` (set `unicode`).

Which font supplies each, on this machine:

- `~/.config/foot/foot.ini`: `font=JetBrains Mono:size=9, wa Icons:size=9`. foot tries its own list
  first, so in a foot window opened after that line was written the private-use icons come from
  **wa Icons**.
- fontconfig alone answers differently: `fc-match -s "JetBrains Mono:charset=f0766"` gives
  **JetBrainsMono Nerd Font** (`/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf`). That is the
  face a foot window opened before the config change, or any terminal that does not list wa Icons, draws.
- `Δ Σ ↑ ↓ ·`, the spinner `✶` and the digits come from **JetBrains Mono** itself.

I could not ask a running foot which face it drew (not checkable from here).

Measured, as a share of one JetBrains Mono cell (0.600 em). left = xMin, right = advance - xMax:

| Code point | Icon | Font | advance | left | right | bottom | top |
| --- | --- | --- | --- | --- | --- | --- | --- |
| U+F0DFA | steps | wa Icons | 100% | 17.7% | 13.8% | 17.7% | 103.9% |
| U+F051B | clock | wa Icons | 100% | 12.3% | 13.8% | 17.7% | 103.9% |
| U+F012C | check | wa Icons | 100% | 0.0% | 13.8% | 27.8% | 93.8% |
| U+F0450 | turns | wa Icons | 100% | 0.0% | 13.8% | 17.7% | 103.9% |
| U+F01BC | cache | wa Icons | 100% | 9.4% | 13.8% | 17.7% | 103.9% |
| U+F0766, U+F0A9E..U+F0AA5 | the nine context balls | wa Icons | 100% | 0.0% | 13.8% | 17.7% | 103.9% |
| U+2736 | spinner, first frame | JetBrains Mono | 100% | 6.5% | 6.7% | 10.0% | 110.0% |
| U+0394 | Δ | JetBrains Mono | 100% | 8.3% | 8.3% | 0.0% | 121.7% |
| U+03A3 | Σ | JetBrains Mono | 100% | 12.5% | 8.3% | 0.0% | 121.7% |
| U+2191 | ↑ | JetBrains Mono | 100% | 6.7% | 6.7% | 0.0% | 123.3% |
| U+2193 | ↓ | JetBrains Mono | 100% | 6.7% | 6.7% | -1.7% | 121.7% |
| U+0030 | 0 | JetBrains Mono | 100% | 13.3% | 13.3% | -1.7% | 123.3% |
| U+0038 | 8 | JetBrains Mono | 100% | 11.0% | 11.0% | -1.7% | 123.3% |

The same icons in the Nerd fallback (JetBrainsMono Nerd Font, measured ad hoc, not in the script):

| Icon | advance | left | right | bottom | top |
| --- | --- | --- | --- | --- | --- |
| steps | 100% | -0.5% | **-12.2%** | -11.2% | 130.7% |
| clock | 100% | 0.0% | **-25.0%** | -13.0% | 133.0% |
| check | 100% | 0.0% | **-21.5%** | 13.3% | 106.7% |
| turns | 100% | 0.0% | **-11.3%** | 4.3% | 115.7% |
| cache | 100% | 0.0% | **-11.3%** | -2.5% | 122.5% |
| balls | 100% | 0.0% | **-38.7%** | -9.3% | 129.3% |

### The hypothesis, against the numbers

"The rows mix glyphs from several fonts with different advances and bearings, so no spacing rule in
the text can make them even." **Partly confirmed, partly refuted.**

- Refuted: the advances do not differ. Every glyph, in all three fonts, advances exactly one cell.
- Refuted for wa Icons' right side: all 14 glyphs have the same right bearing, 13.8%. Glued to a digit
  the gap is 13.8% + the digit's own 11-13%: about a quarter of a cell, the same for every icon.
- Confirmed for the left side: wa Icons' left bearing runs from 0% (balls, turns, check) to 17.7%
  (steps). The build scales each drawing into the box and pushes it to the right edge. So the gap
  BEFORE an icon is one cell + 0% for some and one cell + 17.7% for others, and a 0% icon touches
  whatever is glued in front of it.
- Confirmed for the vertical box: the check is 10% of a cell lower and shorter than the other 13.
- Confirmed for the mix: on the same row `Σ↑1.1M` is glued with a gap of 6.7% + 13.3% = 20% of a
  cell, while an icon in a spaced set (`nerd`, `unicode`: what screenshot 7 shows) has a whole cell
  plus bearings, about 127%. Those two gaps are side by side and no character can make them equal.
- Confirmed for the fallback: the Nerd face draws 11% to 39% of a cell PAST its advance. Glued, it
  overlaps the digit; that is the "overlaps" Victor saw whenever the window drew the Nerd face.

So the unevenness has three causes, in this order: the spaced set next to glued `Σ↑`/`Δ↑` groups;
the Nerd face overflowing its cell when it is the one drawn; wa Icons' uneven LEFT bearings and the
check's own vertical box. The brief's box (6% left, 18% right) fails today for all 14 glyphs: every
right bearing is 13.8% (< 18%), 11 left bearings are 0% (< 6%).

### The test

`scripts/test-status-icon-metrics.py` prints the table and asserts the brief's rule for the 14 wa Icons
glyphs. It fails today, so it ends with
`SKIP test-status-icon-metrics: 26 measurement(s) of the 14 wa Icons status glyphs are outside the brief's box ...`
and exit 0. `--strict` exits 1 instead. Wired in `scripts/fast.sh` after `tui-chrome-pty`; the row
copies the SKIP line into the run's skips file and `NAMED_SKIPS`, the way the Lua rows do.

Not done in C (not asked this round): no glyph redrawn, no Σ/Δ/arrows moved into wa Icons, no
`wa setup fonts --proof`, no check of foot's cell count for the icons.

## Tests run (last output line of each)

Binary: `~/wasm-agent/target/m-tui-chrome/release/wa`, built from this tree. `WASM_AGENT_LUA_ROOT` = the worktree.

| Command | Last line |
| --- | --- |
| `WA_BIN=<mine> node scripts/test-tui-chrome-pty.mjs` | `tui-chrome pty: 18 ok, 0 failed` |
| same, `WA_BIN=~/.local/bin/wa` (the base host) | `tui-chrome pty: 9 ok, 9 failed` (7 of A's, 2 of B's) |
| `WA_BIN=<mine> node scripts/test-fence-card-pty.mjs` | `fence-card pty: 25 ok, 0 failed` |
| `cargo test --offline -p wa-term --lib` | `test result: ok. 178 passed; 0 failed` |
| `WA_SCRIPT=scripts/test-keybindings.lua` | `53 checks, 0 failed` |
| `WA_SCRIPT=scripts/test-cli-view.lua` | `cli view ok (552 checks)` |
| `WA_SCRIPT=scripts/test-cli-resize.lua` | `resize ok (73 checks)` |
| `python3 scripts/test-status-icon-metrics.py` | the SKIP line above, exit 0 (`--strict`: exit 1) |
| `WA_BIN=<mine> node scripts/test-run-live-pty.mjs` | `run live pty: 19 ok, 0 failed, 1 skipped` (3m28s) |
| `WA_SCRIPT=scripts/test-cli-steering.lua` | `cli steering ok (round boundary, model context, durable transcript)` |
| `WA_SCRIPT=scripts/test-icons.lua` | `icons: ok (224 checks, 0 failed, 0 skipped)` |
| `WA_SCRIPT=scripts/test-icon-face.lua` | `icon face: ok (43 checks, 0 failed, 1 skipped)` |

`test-run-live-pty`'s one skip is its own known one (the scrollbar splits while a call waits), not
new. My first run of it was cut by my own 200 s limit; the test takes about three and a half minutes
here. Scratch for every run was under `~/wasm-agent/scratch/tui-chrome` (the /tmp quota warning).

## What I did NOT verify

- `scripts/fast.sh` was not run (rule). Its two new rows are syntax-checked (`bash -n`) only. In
  particular the SKIP hand-off of `status-icon-metrics` (that the line is printed and counted under
  the totals) is written by analogy with the Lua rows and is untested.
- `scripts/test-discriminates.sh` was not run; the base comparison above was done by hand with the
  installed binary and this tree's Lua.
- `cargo test -p wa-capabilities` was not run (cold debug build). `host.rs` compiles in the release
  build; its mouse unit tests do not use the wheel variants.
- One existing assertion's literals changed, in `terminal_editor.rs`
  `long_draft_does_not_wrap_terminal`: the window went from 16 rows to 12 (so the limit is still three)
  and the expected rows are now cut at nine cells instead of ten, because the bar takes the last
  column. It still asserts that the last rows show and the first scrolls out. Please look at it.
- The look in a real foot window: not seen by anyone. tmux has no font.
- The Windows console path and the fullscreen `scroll::Console` path (`scroll/screen.rs`): the wheel
  there still always scrolls the chat; only its pattern was updated to compile.

## Texts to approve

- `/keybindings`, Scrolling: `the wheel: the transcript three rows up or down (over an input box with more lines than it shows: the draft)`
  (was `the wheel: the transcript three rows up or down`).

## How Victor tests it

The installed `wa` does not have this; use the branch's binary with the branch's Lua:

    cd ~/Work/missions/tui-chrome/wt
    WASM_AGENT_LUA_ROOT=$PWD ~/wasm-agent/target/m-tui-chrome/release/wa chat

1. Ask: `show me a two-line bash snippet in a code block`. The block reads `┌─ ⧉ bash`, with `┌`, `│`,
   `└` in one column. Click the `⧉`: the footer says `Copied N characters`. Click the `┌`: nothing.
2. Paste 40 lines into the input. In a 40-row window the box grows to 12 rows, a bar like the chat's
   is on its right edge, and the last line is in view.
3. Wheel with the pointer over the box: the draft's lines move, the chat does not. Wheel over the
   chat: the chat moves, the draft does not. Type a key: the cursor's line is back.
4. Make the window 12 rows tall: the box is 3 rows.
5. Footer icons: `python3 scripts/test-status-icon-metrics.py` prints the table above. Nothing about
   their look changed in this round.
