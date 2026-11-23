# star-green-34: the wa green is xterm 34 (`#00af00`)

Branch `change/star-green-34`, base `42f49385`, worktree `/home/victor/Work/missions/star-green-34/wt`.
One commit: **`dd66cc4e`** "star-green-34: the matrix green is xterm 34 (#00af00), one source".
Victor: "lets go 34" (23/11), chosen from the 30 greens in `~/wasm-agent/scratch/wa-greens.py`; the
xterm 41 (`#00d75f`) this tree carried read too bright.

## The premises, re-measured before the change (FACTORY rule 9)

| brief said | measured on `42f49385` | verdict |
| --- | --- | --- |
| `lua/core/cli_view.lua:104: matrix = "00d75f"` | line 104, `matrix = "00d75f"` | right |
| `rust/wa-term/src/opening.rs:26` `MATRIX` | line 26 doc, line 29 `pub const MATRIX: &str = "\x1b[1;38;2;0;215;95m"` | right |
| `scripts/test-opening.lua:8,27,34,35,53` pin `00d75f` | all five lines | right |
| nothing said about the rain's own shades | **lines 81-89 spell ten SGRs by hand** - the trails, the supernova's two faces, the far arc, the dimmest trail, the decode cell - all in the 41-green and none derived from `MATRIX` | the brief's item 1 asked for them to be derived; they were literals |
| - | `wa_term::opening::MATRIX` had **no user outside `opening.rs`** (`git grep MATRIX` on the base) | so it can become a function without touching another crate |
| - | the Rust star escape is **bold** (`1;38;2;...`), the Lua star is **not** (``fg()`` builds `38;2;...`) | the two never were the same string: the agreement check compares the RGB channels, never the escape text |

The historical report `docs/missions/reports/launch-opening.md` (lines 216, 252-253, 286) still says
xterm 41. It is the record of the 22/11 decision, not a live claim, and it is left as it was.

## The change (`dd66cc4e`)

1. **ONE source.** `lua/core/cli_view.lua`: `PALETTE.matrix = "00af00"`. Everything that paints the star,
the run status row's working glyph and the welcome block reads that role (`paint(..., "matrix", live)`),
so nothing else in Lua spells a colour.
2. **The Rust opening derives every green from it.** `rust/wa-term/src/opening.rs` now holds
   * `pub const MATRIX_RGB: [u8; 3] = [0x00, 0xaf, 0x00]` - the three channels, spelled once;
   * `fn sgr(rgb, bold) -> String` - the escape built from channels, so no escape is written by hand;
   * `fn shade(weight, pale)` - the base scaled by `weight` (1.0 = the green itself) and lifted `pale` of
     the way toward white;
   * `pub fn matrix()` - the star's own SGR (`sgr(MATRIX_RGB, true)`), replacing `pub const MATRIX`;
   * `default_palette()` returns the eleven entries built from those: entry 2 = `matrix()`, the trails at
     weights 1.45 / 1.00 / 0.78 / 0.59, the far arc 0.90, the dimmest trail 0.44, the supernova's near
     face and the decode cell at weight 1.00 lifted 0.62 and 0.72 toward white.
   The rain, the supernova, the star it collapses into and the rune decode therefore move together with
   the one constant: **`grep -c '38;2;0;' rust/wa-term/src/opening.rs` after the change is 0**, and the only
   truecolour escapes the file still spells are the shade builder itself (`sgr`), the grey header lines of
   the test fixture and the yellow "unfinished" note of a long-header test - the white rain head and the
   flash are `sgr([255, 255, 255], true)` like everything else.
3. **The Lua palette is not touched by anything the model reads.** `matrix` is used in three places and
   all three paint (`cli_view.lua`: the welcome star, `marks()`, the status row); `git grep matrix` finds
   no reader other than those and the comment in `lua/core/chat.lua:422`.

## Tests

* **`scripts/test-opening.lua`**, section "1b. the ONE green" (new):
  * reads `rust/wa-term/src/opening.rs` (io.open, then `host.read_file`; a source it cannot read FAILS by
    name, it never passes), extracts `MATRIX_RGB`'s three channels and compares them with
    `PALETTE.matrix`;
  * refuses a second green in the Rust file: no `38;2;0;` escape may be spelled there at all.
  The pins on `00d75f` moved to `00af00` (the palette entry, `style("matrix")` = `\27[38;2;0;175;0m`).
* **`rust/wa-term/src/opening.rs`**, `the_rain_is_the_stars_green_at_other_weights` (new): the star's entry
  IS `matrix()`, `shade(1.0, 0.0) == MATRIX_RGB`, every other green in the palette is the `sgr` of a
  `shade`, and the ramp still descends (brighter first, dimmer last).
* Wired where they already run: the Lua row is `scripts/test-opening.lua`, a fast-path row (run here
  through `WA_FAST_ROWS`), and the Rust test is the `wa-term` crate row `scripts/fast.sh` selects when
  `rust/wa-term/` changes.

### These tests fail on the base (rule 16), measured

With the new `scripts/test-opening.lua` copied into a worktree of `42f49385` and run against the base
Lua root:

```
base: opening: 35 ok, 10 failed     (the star, the status glyph, every mark, the block, and the three
                                     new channel checks)
wt:   opening: 44 ok, 0 failed
```

The Rust assertion cannot exist on the base at all (it names `MATRIX_RGB`, which the base does not have),
so the discriminating row is the Lua one; the Rust test guards the derivation on the new code.

## The check runs

Narrowed fast path over the rows the touched paths map to (`scripts/lib/fast-rows.sh`: the 22 rows that
name `lua/core/cli_view.lua`, plus the never-dropped core rows - the runner reported "47 of 338 Lua rows"),
under the suite lock:

```
fast: lua 46/47 passed (58 excluded: scripts/fast-path.exclude)
fast: rust wa-term ok (6s)
fast path FAILED (1 of 133 checks, 0 skipped, 479s)
```

The one red row is **`scripts/test-land-marks.lua`**: `lua error: ...:42: attempt to index a nil value`
(`step_of("case27", "publish").state`), after its own line said the scratch `wa-vault` did not start. It is
not this change's:

* the code diff is three files (`git diff --stat 42f49385..dd66cc4e`: `lua/core/cli_view.lua`,
  `rust/wa-term/src/opening.rs`, `scripts/test-opening.lua` - 126 insertions, 28 deletions), and
  `lua/core/land.lua` and its harness are byte-identical to the base;
* run SINGLY through the runner's own `wa_fast_row_exec` (scratch HOME/`WASM_AGENT_HOME`, watchdog, this
tree's binary) the row passes on **both** trees: `land ok (27 checks)`, exit 0 - on `change/star-green-34`
  and on a worktree of `42f49385`.

So it is a pre-existing, environment-sensitive failure (the vault fixture), named here rather than hidden.
Everything else the run touched is green, `scripts/test-opening.lua` included (`pass`, 203 ms).

Rust, singly, before the suite: `cargo test -p wa-term --lib opening::` - **14 passed, 0 failed**.

## Texts to approve (operator-facing)

1. None. No word a reader or the model sees changed: the change is the value of one palette entry and the
derivation of the console's own colours. The welcome line, the status row and every prompt/hint string are
unchanged.

## Proposed FACTORY.md text (not written)

Rule 12 is the numbering to extend; the text proposed is:

> **A shared colour has one source.** When two surfaces paint the same colour (the Lua view and the Rust
> console today), the colour is spelled ONCE - `PALETTE.matrix` in `lua/core/cli_view.lua` - and every
> other spelling is built from it: derived at compile time in Rust, never a second literal. A row refuses
> a tree where the two disagree (`scripts/test-opening.lua`), and a shade is a weight of the base, so a
> colour change moves the whole ramp with it.

## Proposed HANDOVER.md text (not written)

> The matrix green is **xterm 34, `#00af00`** (Victor, 23/11: "lets go 34"; it replaced xterm 41
> `#00d75f`, which read too bright). It lives in `PALETTE.matrix` (`lua/core/cli_view.lua`); the opening
> (`rust/wa-term/src/opening.rs`) builds `MATRIX_RGB` and every rain/supernova/decode shade from it, and
> `scripts/test-opening.lua` fails when the two drift apart.

## How Victor tests it

Open a new `wa` window: the opening, the star in the header and the working glyph are the calmer green
(`#00af00`).
