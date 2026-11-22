# icons-box — the status rows' icons sit in one box (Victor 22/11)

Branch `change/icons-box`, base `57551064`. Mission: finish `_queue/done/tui-chrome.md` item 2 (the rows'
icons), which the last round only MEASURED with a named SKIP.

    d8efa511  icons-box: wa Icons drawn into one box inside the cell (18% right bearing, left >= 6%, one centre)
    193f6a32  status-icon-metrics: the two rows' box is an assertion, and every row glyph names the face that draws it
    1ca7097b  icons-box: the eye test draws both status rows from real font files (old, 18%, 14%, 24%)
    486fc1f0  icons-box: the manifest states the box in whole units, and --foot names the face foot really uses

## 1. The brief's premises, re-measured on the base before any code was written

`python3 scripts/test-status-icon-metrics.py` on 57551064 prints one row per glyph. Every claim in the
brief held, with one refinement:

| premise (brief) | measured on 57551064 |
|---|---|
| all 14 wa Icons glyphs advance one cell | yes, 100.0% of the cell for all 14 |
| right bearing 13.8% of the cell | yes, 13.8% for all 14 (`fit()` pinned the right edge) |
| left bearing 0% .. 17.7% | yes: 0% for check, turns and the nine balls; 9.4% cache, 12.3% clock, 17.7% steps |
| the check is a different vertical box | yes: 27.8%..93.8% of the cell against 17.7%..103.9% for the others |
| the digit after an icon leaves 11%..13% | yes: digit 0 13.3%, digit 8 11.0% |

**Refined, and it matters for what was built:** the right bearing was ALREADY identical for every icon,
so "the gap is not the same for every icon" was never about the right edge. What differed was the ink's
SIZE and its LEFT edge (0%..17.7%) and, for the check, its vertical box - the gap a reader sees is
13.8% + 12% = about a quarter of a cell and it MOVED because the icon's own drawing did. The fix is
therefore one box (size, centre, and a right edge the digit can see) rather than a bigger margin alone.

## 2. What was built (item 1)

`scripts/build-wa-icons.py` (d8efa511). `fit()` no longer scales each glyph by its LONGER side to 517
units with the right edge pinned; it fits every glyph by ONE scale into a SQUARE box inside the cell and
places it with the box's right edge and the capitals' centre. The numbers are named constants:

    LEFT_BEARING_PCT = 6.0      RIGHT_BEARING_PCT = 18.0     (the shipped number)
    -> left bearing 36 units, right bearing 108 units, box side 456 units, right edge 492 of 600
    CAP_HEIGHT = 730, YMID = 365            (where the digits sit; centre of the box)

`geometry()` derives the box from those two shares; `verify()` asserts advance, the one right edge, the
left bearing, the square box and the centre; the manifest states them (`box`, in whole units).

Measured after the rebuild (same script):

    wa Icons: right bearing 18.0%..18.0%, left bearing 6.0%..21.6%, centre 60.8%..60.8% (14 glyphs)

The 6.0% left is the check, turns and the nine balls; 21.6% is the steps (tall, so correctly narrower).
Every glyph's centre is 60.8% of the cell, which is the digits' centre measured from JetBrains Mono.

**THE RULE WAS CORRECTED, NOT LOOSENED.** The old assertion was "the same yMin and the same yMax". A
glyph fitted by one scale into a box cannot have both - the check is wide and therefore short (31.7%..
89.9% of the cell), the steps tall and narrow - so the assertion is now "the same CENTRE (within 2% of a
cell), inside the box (never bigger than 456x456 units)", and it is stated as a correction in
`scripts/test-status-icon-metrics.py`'s docstring, in `tests/test-wa-fonts.mjs` and in the constants'
comment. The right bearing went from ">= 18%" (a floor) to "== 18% within 0.2% of a cell", which is
stricter.

Reproducible rebuild: `--out assets/fonts` builds twice from the pinned archive and refuses if the bytes
differ ("reproducible: a second build of the same source is byte-identical"); `--check`, and
`--verify-font` on the installed copy, both answer `wa icons: ok`. Consumers updated: `assets/fonts/*`
(font + manifest), `ui/fonts/waIcons-Regular.ttf` (the served copy, written by the same build), the user
font directory (item 5). The terminal icon map needed no change: the glyph SET is unchanged, so
`lua/core/font_setup.lua`'s `ICON_RANGES` is untouched - `git diff 57551064 -- lua/` is empty on this
branch.

## 3. Item 2: every glyph of both rows, and the face that draws it in foot here

Measured, not asserted from a table: `python3 scripts/test-status-icon-metrics.py --foot` reads
`~/.config/foot/foot.ini` (`font=JetBrains Mono:size=9, wa Icons:size=9`), resolves each family through
fontconfig to a file on this machine, and asks the file's own cmap.

    foot asks for, in this order: JetBrains Mono, wa Icons

    run       steps   U+F0DFA  wa Icons          |  middle dot U+00B7   JetBrains Mono
    run       clock   U+F051B  wa Icons          |  delta      U+0394   JetBrains Mono
    run       check   U+F012C  wa Icons          |  arrow up   U+2191   JetBrains Mono
    run/sess  colon   U+003A   JetBrains Mono    |  arrow down U+2193   JetBrains Mono
    session   turns   U+F0450  wa Icons          |  sigma      U+03A3   JetBrains Mono
    session   cache   U+F01BC  wa Icons          |  percent    U+0025   JetBrains Mono
    session   balls   U+F0766, U+F0A9E..U+F0AA5  wa Icons          |  slash U+002F, period U+002E  JetBrains Mono
    both      the ten digits U+0030..U+0039      JetBrains Mono

19 glyphs from `JetBrainsMono-Regular.ttf`, 14 from `waIcons-Regular.ttf`, **none from a fallback face**.
The script now fails (exit 1) when a row glyph is in neither wa face - it could not tell before.

**A FALLBACK FOUND, NOT FIXED, and it is not on the two rows:** the animated status line above them
cycles ten frames (`M.spinner`), and seven of them are not in JetBrains Mono either:

    U+2733 ✳  U+2737 ✷  U+2738 ✸  U+2739 ✹  U+273A ✺  U+2726 ✦  U+2727 ✧   -> FALLBACK -> Adwaita Mono

so those frames are drawn by another face, at another size, on every spinner cycle. Only ✶ (U+2736),
• (U+2022) and · (U+00B7) are in JetBrains Mono, and wa Icons carries none of them, so a fix is either a
thinner cycle of three shapes or nine new wa Icons glyphs - a look change that needs Victor's eye, and
outside the "two status rows" this item names. It is printed by every run of the script, so it is not a
hidden hole. `lua/core/cli_view.lua`'s SPINNER table is the place to change it.

## 4. Item 3: the metrics test is a check, not a SKIP (193f6a32)

`scripts/test-status-icon-metrics.py` asserts the box by default (no `--strict`, no SKIP line, exit 1 on
any violation) and `scripts/fast.sh` runs it as an ordinary `check status-icon-metrics` row; the grep
for `^SKIP` and the "python3 not on PATH -> skipped" branch are gone, so a host without python3 fails the
row by name instead of counting a skip.

**It discriminates.** Against the base in a separate worktree (`git worktree add /tmp/icons-box-base
57551064`, the new test copied in): **51 measurement(s) outside the rule, exit 1**. On this branch:
exit 0. The byte-level test likewise: `node tests/test-wa-fonts.mjs` -> 99 checks, 0 failed here; 40
failed on the base.

## 5. Item 4: the eye test (1ca7097b) - `~/Work/missions/icons-box/compare/`

`scripts/render-status-rows.py --out ~/Work/missions/icons-box/compare` draws both rows from REAL FONT
FILES: `01-old-a2.png` is the face committed at 57551064 (read out of git), `02-shipped-18.png` is what
this branch ships, `03-candidate-14.png` and `04-candidate-24.png` are full rebuilds through the same
`geometry()` with 14% and 24%. Each PNG is 1085x318 and carries, at 1x (9 pt = 12 px em, one cell
7.2 px - the terminal's real size) and at 4x (48 px em), the run row
`<steps>1·12s Δ↑0 ↓1.2k <clock>0:25 · <check>18:47` and the session row
`<turns>2 Σ↑1.1M Σ↓14.5k <ball>6.5%/1.0M <cache>94.05%`.

Measured on the PNGs themselves (ink columns per cell, 4x), so the pictures can be trusted to carry the
numbers:

| image | steps glyph ink in its cell (of 28.8 px) | turns glyph | the digit after it |
|---|---|---|---|
| 01 old (13.8%) | 5.0 .. 24.0 | 0.0 .. 24.0 | 4.2 .. 24.2 (unchanged) |
| 02 shipped 18% | 6.0 .. 23.0 | 2.0 .. 23.0 | 4.2 .. 24.2 |
| 03 candidate 14% | 7.0 .. 24.0 | 2.0 .. 24.0 | 4.2 .. 24.2 |
| 04 candidate 24% | 6.0 .. 21.0 | 2.0 .. 21.0 | 4.2 .. 24.2 |

The gap between an icon's last ink and the next digit's first ink is 9 px at 14%, 10 px at 18%, 12 px at
24% (of a 28.8 px cell, i.e. 2.3 / 2.5 / 3.0 px at the terminal's real size) - and the same for every
icon at 18%, which is the thing that was wrong. The text glyphs are pixel-identical in all four.

**The DEFAULT I SHIP IS 18%**; Victor picks by eye.

The renderer is not a gate test (it needs fontTools, PIL and the pinned archives, and its answer is a
picture): it is not wired into `scripts/test.sh` or `scripts/fast.sh`, and says so in its docstring.

## 6. Item 5: install, and what the terminal needs

    cd ~ && WA_UI_DIR=/home/victor/Work/missions/icons-box/wt/ui wa setup fonts

Run on this laptop: it copied the three faces into `~/.local/share/fonts` and refreshed the font cache,
and left every terminal config alone (foot's `font=JetBrains Mono:size=9, wa Icons:size=9` already draws
wa's icons with wa Icons: "no terminal config needed a change"). Verified afterwards, not assumed:
`sha256sum ~/.local/share/fonts/waIcons-Regular.ttf` = `b954c7b031dd...` = the committed font, and
`--verify-font` on the installed file answers `wa icons: ok`; `fc-match 'wa Icons'` resolves to it.

After the landing the deploy carries `ui/fonts` into the installed bundle (`scripts/upgrade.sh:99`,
`scripts/verify-deployed.sh:139`) and `scripts/install.sh:371` runs `wa setup fonts` itself, so the same
command without `WA_UI_DIR` installs the landed bytes.

**The terminal must be restarted** - foot loads its faces when the window is created, so a NEW foot window
is what draws the new glyphs; running `wa chat` again inside the window that is already open does not,
because that window kept the face it loaded at startup. (`wa setup fonts` changes the font files, never a
running process; this is why the brief asks for a restarted terminal.)

## 7. Texts to approve (nothing the model sees changed)

1. `ok - 14 wa Icons status glyphs in one box (right 18%, left >= 6%, centre 60.8%), and every glyph of both rows drawn by one of wa's own faces`
2. `  outside the rule - U+F012C check right bearing 13.8% of the cell, the box says 18%` (one per violation; the label and the numbers vary)
3. `the animated status line's frames: 3 of 10 are drawn by JetBrainsMono-Regular.ttf, 7 by no wa face (U+2733, U+2737, U+2738, U+2739, U+273A, U+2726, U+2727)`
4. `each row glyph's face, as the font files answer: 19 from JetBrainsMono-Regular.ttf; 14 from waIcons-Regular.ttf`
5. `foot asks for, in this order: JetBrains Mono, wa Icons` and, per glyph, `FALLBACK -> Adwaita Mono (AdwaitaMono-Regular.ttf)` (`--foot` only)
6. the PNG captions: `THE SHIPPED FONT: one box, right bearing 18% = 1.3 px, left >= 6%, one centre on the digits' line`, and at 1x/4x: `1x (12 px em, cell 7.2 px)` / `4x (48 px em, cell 28.8 px)`

No prompt, tool output or transcript text changed: `lua/` is untouched on this branch.

## 8. Verified, not verified, not done

Verified here (avell):
- the font rebuilds byte-identically twice from the pinned archive, and `--check` passes (d8efa511, 486fc1f0);
- the box holds for all 14 glyphs, measured from the committed font (right 18.0% for all, left 6.0%..21.6%, centre 60.8%);
- `node tests/test-wa-fonts.mjs`: 99 checks, 0 failed (base: 40 failed);
- `python3 scripts/test-status-icon-metrics.py`: exit 0 (base: 51 violations, exit 1);
- `--foot`: every row glyph drawn by wa Icons or JetBrains Mono, the seven spinner frames by Adwaita Mono;
- the four PNGs, measured by ink columns as in the table above;
- the install: installed bytes == committed bytes, `--verify-font` ok, fontconfig resolves the family.

NOT verified: the live pixels in a foot window (that is the eye test); the full `scripts/fast.sh` path and
the release build - this node has no release binary in the mission target
(`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-icons-box` holds no `release/wa`), and a release build
of the workspace was not run here, so the Lua view tests (`test-cli-view.lua`, `test-icons.lua`,
`test-font-setup.lua`) were NOT run in this round. Nothing in `lua/` changed, so none of them can depend
on this branch's diff, but they are unrun and this report does not claim them.

NOT done: the spinner's seven fallback frames (section 3) - a look change outside this item; and no
landing, no push, no deploy.

Pre-existing failures: none met. The full suite was not run, so none is named.
