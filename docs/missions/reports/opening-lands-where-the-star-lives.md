# opening-lands-where-the-star-lives (Victor 23/11)

Victor, on the opening (rust/wa-term/src/opening.rs, the 3D supernova, fadf11ed): "its nice but we can
improve it. right now the supernova shrinks into its very top left then it moves suddenly to the very bottom
of the terminal. ideally it should collapse into the exact position it will be printed" - the green star at
the start of the status row above the input box (bottom of the window).

Commits: `0181cabc` (items 1-5, the star), `5e539c17` (item 6, the unknown-font line and the remembered
choice), the item-7 commit (the stock-font set, this report). Branch `change/opening-lands-where-the-star-lives`.

## 1. Measured first: where the collapse ended, and where the chat prints the star

Real pty, `wa chat` on a scratch home, three sizes, the LAST frame of the alternate screen (bytes up to
`ESC[?1049l`) against the chat's own screen (measured with `wa_term::scroll::vt::Vt`, the terminal in memory
the render tests use).

| window | opening's star (last frame) | chat's star (first frame) | the jump |
|---|---|---|---|
| 80x24  | row 2, col 1 | row 12, col 1 | 10 rows |
| 120x40 | row 2, col 1 | row 28, col 1 | 26 rows |
| 200x60 | row 2, col 1 | row 49, col 1 | 47 rows |

(The rows here are 1-based, as the captures print them; the SGR of every one of those cells was
`38;2;0;175;0`, the matrix green, on both screens - the colour was never wrong, the cell was.)

WHY THEY DIFFERED, and it was two layouts and not one:

* the opening placed the header at the TOP of the screen - its own decision, `star = (1, 0)` in
  `act_frame` - and parsed each painted line with `parse()` and TRUNCATED it to the width;
* the chat draws the same block into its transcript, which is BOTTOM-anchored: the block's last line lands
  on the output region's last row, `TerminalEditor::out_bottom` (footer, input box, status line, bottom up),
  so the star sits `out_bottom - (block rows - 1) + 1`;
* and the two heights differed too: at 80 columns the model line WRAPS in the transcript (`wrap_rows`) and
  was merely cut in the opening, so the opening's block was 9 rows where the chat's was 10.

So the collapse fell into a cell that existed only in the opening's own arithmetic, and the reader saw the
star jump the height of the window when the alternate screen was given back.

## 2. ONE source for the target cell

`0181cabc`. The opening no longer decides a cell; it is given the chat's own layout and draws its block - and
its star - on the rows the chat will draw them on:

* `Opening::region_bottom(row)` is the 0-based row of the chat's output region's last row, and the host sets
  it from `TerminalEditor::out_bottom()` - the SAME function the input box and the status line above it are
  laid out on (`opening_region_bottom` in `rust/wa-capabilities/src/host.rs`), asked when the block arrives and
  again on every resize. One number, no second estimate;
* the block is laid out with the TRANSCRIPT'S OWN functions, not copies: `crate::transcript::wrap_rows` and
  `crate::transcript::expand_rule`, so a line that wraps wraps here as it wraps there, and the rule is
  expanded at the width being drawn;
* the star is the block's SECOND line, column 0 (`Opening::star_cell`), which is where the collapse lands and
  where the landing frames leave the glyph - `✻` in `PALETTE.matrix`'s green - and the block then draws the
  very same glyph, in the same colour, over the same cell;
* `lua/core/cli_view.lua` hands the block over with its rule still the MARKER (`welcome_painted`), which is
  what lets the opening expand it at its own width, and now hands over the notes under the block as well - a
  note added after the hand-over was in the chat's block and not in the animation's (one row of difference,
  and the star one row off: found while wiring this).

After the change, measured the same way:

| window | opening's star | chat's star |
|---|---|---|
| 80x24  | (12, 1) | (12, 1) |
| 120x40 | (28, 1) | (28, 1) |
| 200x60 | (49, 1) | (49, 1) |

and the rule above the star is the window's width on both screens.

## 3. A resize re-targets; a window under the floor still skips

`0181cabc`. `opening_tick` no longer ends the opening when the window changes size: it resizes the opening
(`Opening::resize`, the rain re-drawn on the new grid, the block re-wrapped at the new width), lets the
chat's own rows follow (`resize_console`) and re-reads `out_bottom` for the new window. A window that is no
longer big enough to hold the box (`< 60x14`) ends it at once - there is no output region to hang a block on
and so no cell to land in - which is what a window under that floor has always done (no opening at all).

THE ROW THAT ASSERTED THE OLD ANSWER is now two rows: `a_resize_retargets_the_opening_and_the_star_lands_on_the_new_size`
(the opening kept playing past the resize, and its last frame's star is the cell the chat uses at the NEW
size) and `a_resize_under_the_openings_floor_ends_it`. The property the old row carried (a resize never leaves
a frame for a width the window no longer has) is stronger in the first: the frame is re-drawn for the new size.

## 4. Start time did not grow

Two numbers, both from the speed board's own machinery, on this node (16 cores), before = the base commit
ffd2a0a5's binary, after = this branch:

* **cold start** (`scripts/speed/probe-cold-start.py`, the board's `start` row: process start -> the prompt is
  up in a real pty), 7 samples: **308 ms before, 293 ms after** (medians);
* **the opening's own length** (pty, `ESC[?1049h` -> `ESC[?1049l`), 3 samples each, both binaries built from a
  CLEAN tree: **1966/1962/1968 ms before, 1968/1964/1965 ms after** - the same sequence, and the 2000 ms
  budget (`TOTAL_MS`) is untouched. Measured with a DIRTY build first and it read 2000 ms: the label was
  `v…+dirty`, six cells longer than the base's, which is four more decode frames at 16 ms - a property of the
  label, not of the change. Nothing in the acts, the delays, `header_frames` or `planned_ms` moved (the diff
  of `opening.rs` touches none of them).

## 5. The tests

* `rust/wa-term/src/opening.rs` (unit): `the_star_lands_in_the_cell_the_block_prints_it_in` (three sizes, a
  block that wraps, the block's last line on the region's last row, the star landing in the block's own cell in
  the matrix green), `a_resize_retargets_the_star_and_re_lays_the_block`, and the existing rows re-stated for
  the bottom-anchored block (`the_last_frame_is_the_header_the_view_painted` and three others).
* `rust/wa-term/tests/opening.rs` (real pty): `the_star_lands_in_the_cell_the_chat_prints_it_in` - 80x24,
  120x40, 200x60, the last alternate-screen frame vs the chat's screen: the star cell and the rule row, cell
  for cell. **It fails on the base binary** (measured: `(2,0)` vs `(12,0)` at 80x24), as do the two resize rows.
  Wired in `scripts/test.sh` (the row next to `test-opening.lua`, unchanged).

## 6. The font wa cannot know: one line, once, and /icons remembered

`5e539c17`. The premise was re-measured and holds: `lua/core/icons.lua:183` (`resolve`) returned "unicode" at
`:198` when `<data>/setup/fonts.json` was missing, and the terminal-face check at `:200` was never reached.

* `resolve` now asks `icon_face.face()` whatever the record says, and carries its "could not tell" as
  `unknown`;
* `icons.NOTICE` / `icons.notice_line` own the sentence, `cli_view.icons_notice()` prints it once at start,
  and only while the set was chosen by DEFAULT and the font could not be measured - a config line, WA_ICONS or
  `/icons` silences it;
* `/icons <set>` writes `icons = <set>` into this node's config file (`icons.remember`), replacing the line
  rather than appending, so the next start draws it;
* the notice and the reload note are written BEFORE the block is handed to the opening (see 2).

Tests: `scripts/test-icons.lua` (the resolver's unknown answer, the exact sentence, the silence of an explicit
set, the config line, and that repeated `/icons` leaves ONE line - 256 checks) and `rust/wa-term/tests/icons.rs`
(new): two real starts on a pty whose PATH has no shell in it - so the font genuinely cannot be measured - the
line appears exactly once, `/icons wa` writes one config line, and the second start neither repeats the line
nor forgets the set. Wired in `scripts/test.sh` beside the opening pty row.

## 7. The stock-font set, rebuilt from measurement

`icons.lua`'s `unicode` set, which is what a terminal draws whenever wa Icons is not known to be there, was
drawn from U+25B8, U+25F7, U+21BB, U+25A4, U+25D1, U+25CB, U+25CF. Measured: the first four are in NEITHER
JetBrains Mono nor Liberation Mono (the terminal took them from a fallback face), U+25D1 is missing from
JetBrains Mono, and every one of them is East-Asian-**Ambiguous** - a CJK-locale terminal may spend two cells
on one. It was also the only set that kept a space after each icon, so the row with no font was WIDER than
ours - Victor's "that is horrible".

THE NEW SET is glued like wa (`gap = ""`) and drawn from measured glyphs:

| slot | glyph | codepoint | East-Asian Width | one cell in |
|---|---|---|---|---|
| steps | › | U+203A | N (Narrow) | JetBrains Mono, Liberation Mono, Noto Sans Mono, Adwaita Mono |
| clock | ~ | ASCII | Na | all |
| turns | # | ASCII | Na | all |
| cache | = | ASCII | Na | all |
| check | + | ASCII | Na | all |
| ballEmpty | ▫ | U+25AB | N | all four |
| ballEighth/Quarter | ◦ | U+25E6 | N | all four |
| ballThreeEighths/Half | ◔ | U+25D4 | N | all four |
| ballFiveEighths/ThreeQuarters | ◕ | U+25D5 | N | all four |
| ballSevenEighths/Full | ▪ | U+25AA | N | all four |

`+` for the finish stamp because U+2713 ✓ - the obvious glyph - is NOT in Liberation Mono or Noto Sans Mono
(measured below); ✓ would be a fallback glyph on a stock Linux box.

WHAT WAS MEASURED IN, and what was not. The faces on this node, read from the font FILES (cmap + hmtx, no
fontTools): JetBrains Mono (cell 600/1000), Liberation Mono (1229/2048), Noto Sans Mono (600/1000), Adwaita
Mono (600/1000) - every glyph above is present and advances exactly one cell in each. NOT INSTALLED here and
so NOT MEASURED: DejaVu Sans Mono, Menlo, Consolas, Cascadia Code. The row NAMES them as unmeasured and never
counts them as a pass; the set stands on glyphs those faces carry (ASCII, and the squares/circles of
U+25AA/U+25AB/U+25D4/U+25D5/U+25E6, which are in WGL4 and in the Vera/Menlo family), and that is an argument,
not a measurement - said here so nobody reads it as one.

The measurement is a row, `scripts/test-unicode-icons.py` (wired in `scripts/test.sh`): it reads the set out of
`lua/core/icons.lua` itself, refuses an ambiguous/wide/emoji codepoint, and checks presence and advance in every
family it can open on the machine it runs on. Output on this node:

```
unicode-icons: 14 glyphs, 4 faces measured, 4 named unmeasured
  measured: JetBrains Mono (cell 600/1000), Liberation Mono (cell 1229/2048), Noto Sans Mono (cell 600/1000), Adwaita Mono (cell 600/1000)
  unmeasured (not installed here): DejaVu Sans Mono, Menlo, Consolas, Cascadia Code
unicode-icons: ok (14 glyphs, 0 failures, 4 families unmeasured: ...)
```

### Captures, wa and unicode side by side (Fable looks at them)

Both status rows, composed by the view the operator sees (`cli_view.run_numbers` and
`M.session_summary` with the same fixture), the cell count beside each:

```
wa       run    |󰷺3·3s Δ↑5.3k ↓851 󰔛0:25 · 󰄬07:20|  32 cells
unicode  run    |›3·3s Δ↑5.3k ↓851 ~0:25 · +07:20|  32 cells
wa       footer |󰑐3 Σ↑120.4k Σ↓1.0k 󰪞12.2%/200.0k 󰆼74.75%|  40 cells
unicode  footer |#3 Σ↑120.4k Σ↓1.0k ◦12.2%/200.0k =74.75%|  40 cells
nerd     run    |󰷺 3·3s Δ↑5.3k ↓851 󰔛 0:25 · 󰄬07:20|  34 cells
nerd     footer |󰑐 3 Σ↑120.4k Σ↓1.0k 󰪞 12.2%/200.0k 󰆼 74.75%|  43 cells
ascii    run    |steps 3·3s Δ↑5.3k ↓851 time 0:25 · done07:20|  44 cells
ascii    footer |turns 3 Σ↑120.4k Σ↓1.0k [.   ] 12.2%/200.0k cache 74.75%|  56 cells
```

THE UNICODE ROW IS NOW THE SAME WIDTH AS OURS - 32 and 40 cells, the same layout, only the shapes differ.
The wa and unicode rows above are byte-for-byte what the terminal is handed (the wa row's glyphs are wa
Icons, which only a terminal with the font draws; the unicode row needs nothing installed).

### The font on the DRAWING machine (one line)

A container cannot install a font for the terminal that draws its output, so the release carries the font
itself and `/icons` prints ONE line:

```
wa Icons on this machine: curl -fsSL https://github.com/Magaav/wasm-agent/releases/download/node-<sha12>/waIcons-Regular.ttf -o ~/.local/share/fonts/waIcons-Regular.ttf && fc-cache -f ~/.local/share/fonts
```

* WHAT IT DOWNLOADS: `waIcons-Regular.ttf`, the A2 icon face - the same bytes as
  `assets/fonts/waIcons-Regular.ttf`, from THIS build's own node release (tag `node-<sha12>`, the tag the
  release index and the install path already use). Nothing else: no installer, no token, no second URL;
* FROM WHERE, and why it is trustworthy: `waIcons-Regular.ttf` is now part of the node release's assets
  (`asset_list()` in `scripts/publish-node-binaries.sh`, copied beside the binaries), so it is listed in that
  release's `SHA256SUMS` - the file the vault's `release-signing` key SIGNS (`SHA256SUMS.sig`) and that a
  release is not published without. It can be checked with the sums the reader already trusts:
  `curl -fsSL .../SHA256SUMS | grep waIcons` and `sha256sum -c`;
* the line is printed only when the set in force is not `wa`, and only when a release can be named: a dev tree
  whose label is not a commit prints nothing rather than a guessed URL (`icons.fetch_line`);
* WHAT IS NOT YET TRUE: the font is an asset of the NEXT published release - the ones already on GitHub were
  cut before this change, so their `node-<sha12>` has no font beside it. Until the next release ships, the same
  bytes are at the commit-pinned path `https://raw.githubusercontent.com/Magaav/wasm-agent/<commit>/assets/fonts/waIcons-Regular.ttf`.

## Texts to approve (verbatim)

1. `icons: unicode (font unknown here). If your terminal has wa Icons: /icons wa` - the once-at-start line
   (`lua/core/icons.lua` M.NOTICE), printed with two leading spaces under the welcome block.
2. `  icons <set>  (remembered in <config file>)` - the answer to `/icons <set>` when the choice was written.
3. `  icons <set>  (this session only: <why>)` - the same when the config file could not be written.
4. `  wa Icons on this machine: curl -fsSL https://github.com/Magaav/wasm-agent/releases/download/node-<sha12>/waIcons-Regular.ttf -o ~/.local/share/fonts/waIcons-Regular.ttf && fc-cache -f ~/.local/share/fonts`
   - the one line `/icons` prints when this window is not drawing wa Icons.
5. `font_absent: <out>/waIcons-Regular.ttf is not in this set, so this release ships no icons (a set built before item 7 has none)`
   - `scripts/publish-artifacts-branch.sh`, printed for a set that predates the font; never for a set this
     tree's publisher made (that one refuses with `font_missing` instead).

## Deviations and open facts

* **The nerd and ascii sets keep their space.** Item 7's headline is "ONE layout in every icon set", and the
  row that must look like ours is the unicode one (it does now, 32/40 cells both). `nerd` keeps its one space
  because 19/11 measured that face drawing its glyphs WIDER than their cell, where gluing collides with the
  value (Victor's 21/11 "bottom is glued" photograph); `ascii`'s glyphs are words, which carry their own
  separator. Making them glued too is one line each in `icons.lua` plus a restatement of the cell-width proof
  in `scripts/test-icons.lua` - say the word.
* **DejaVu Sans Mono, Menlo, Consolas and Cascadia Code are not installed on this node**, so the four fonts
  the brief names could not be measured here. The row names them as unmeasured on every run; nothing in this
  report claims them.
* `a_resize_ends_the_opening` is gone, replaced by the two rows named in 3: the brief asks a resize to
  re-target, which is the opposite of what that row asserted. No other assertion was removed or loosened; the
  cell-width proof in `scripts/test-icons.lua` is untouched.
* **The release shape changed by one file.** `5df877b7` makes `waIcons-Regular.ttf` part of a node release: it
  is copied beside the binaries by `scripts/publish-node-binaries.sh` and carried into the artifacts commit by
  `scripts/publish-artifacts-branch.sh`, so it is in the signed `SHA256SUMS`. Three test rows follow that shape
  and were updated with it, not loosened: `test-land-signing.sh`'s fixture now copies the font (a fixture that
  mirrors a requirement), `test-publish-artifacts.sh`'s exact file list and sums row count (3 -> 4), and
  `scripts/test-icons.lua`'s "the chosen set is spaced" (the unicode set is glued now, which is the item).

## Rows run (each singly, this branch)

* Lua: `test-opening.lua` (44 ok), `test-icons.lua` (256 ok), `test-cli-view.lua` (566 ok),
  `test-icon-face.lua` (44 ok), `test-font-setup.lua` (183 ok);
* Python: `scripts/test-unicode-icons.py` (ok: 14 glyphs, 4 faces measured, 4 named unmeasured);
* Rust: `cargo test -p wa-term --lib opening::` (16 ok), `--test opening` (7 ok), `--test icons` (1 ok); the two
  pty rows were also run against the BASE binary and fail there (the discriminator);
* Shell: `test-land-signing.sh` (46 ok), `test-publish-artifacts.sh` (56 ok), `test-publish-shared-commit.sh`
  (43 ok). `test-deploy-node-binaries.sh` fails on this node with "the installed prebuilt supervisor is not
  executable" - measured on a base worktree (`git worktree add /tmp/base-ffd2 ffd2a0a5`) and identical there,
  so it is PRE-EXISTING and not this branch's.
* The narrowed `scripts/fast.sh` run over the touched paths (`WA_FAST_ROWS=/tmp/rows-opening-star.txt`, the
  rows for the files this branch changes) was started under `flock -o ~/Work/missions/.suite.lock` and waited
  31 minutes for the lock: three other missions' suites were queued ahead of it on this node (the holder at
  the end had run 28 minutes), so it never started and was CANCELLED, not left running. Its result is not
  claimed here. Every row the branch touches was run singly, above and green; the narrowed run the landing
  does (`wa land`, land-quick) is the one that will see them together.
