# launch-opening

Priority 1. Victor iterated nine demos with Fable and chose one (22/11 21:22Z): "totally yeah! that one! but
change ✻ into the matrix green color as well as the thinking animated stars first glyph on run status
bar". The header's TEXT stays exactly as it is today; the star and that one glyph turn green.

Branch `change/launch-opening`, base `23791f56`, worktree
`/home/victor/Work/missions/launch-opening/wt`.

**The reference, FINAL (Victor, 22/11 23:32Z): `scratch/wa-header-demo10.py`, the 3D supernova** - his
favourite of the two (demo 8, the tornado, was replaced: there is no tornado code left and no switch).
Both sketches were run first, in a private tmux pty at 100x30, and both are copied into the mission folder
(`wa-header-demo8.py`, `wa-header-demo10.py`); the frames of each run are kept (`refs/`, `refs10/`). The
order is the spec: rain over the whole screen, a point of light igniting in the middle of the rain, a white
flash, a sphere of glyph debris flying apart in depth (near pieces bright, far pieces dim dots), ONE ring
racing outward in a tilted plane (near arc solid and bright, far arc faint) blowing the rain away as it
passes, the cloud and ring turning for a moment, everything falling into the header's star cell, the star
landing, the title translated from the sketch's ALIEN table, then the rest of the header.

## Premises, re-measured on the base before writing code

| brief said | measured on `23791f56` | verdict |
| --- | --- | --- |
| the star is `STAR` (cli_view.lua:171) painted "accent" | `lua/core/cli_view.lua:171` is the `DOT, RESULT, STAR` line; the banner paints it at `:3444` (`paint(STAR, "accent", live)`) | correct |
| palette accent at line 79 | `:79` is `accent = "d77757", ...` | correct |
| the banner is `M.banner` at ~3431 | `:3431` is `function M.banner(opts)` | correct |
| the run status row's animated first glyph travels to the host (~162) | `M.marks` at `:164` builds one painted string per spinner frame and the view hands them to `host.ticker` (`lua/core/cli_view.lua:360` in `scripts/test-cli-view.lua` asserts the hand-over) | correct; the colour was chosen in `M.marks` itself, so the host needed no change |
| chat.lua ~489 redraws the welcome block on a resize | `chat.lua:489` is a comment about the reload source; the redraw is `METHODS:resized` (`cli_view.lua:2161`), called at the frame boundary. The start path needed it only as a downstream fact | wrong file, right mechanism |
| the live view frames its output with mode 2026 | `:209` `SYNC_START, SYNC_END = "\27[?2026h", "\27[?2026l"` | correct |
| — | the reader thread (`rust/wa-capabilities/src/host.rs`, `console_reader`) polls stdin with `byte_ready(150)` and is the ONE thread that owns keys and the editor's rows; `wa_term::terminal_editor::write` is the one funnel every console write goes through | this is where the animation had to live, and why |

## Where the animation runs, and why there (`7d1db266`, `2c0af8a3`, `495e582d`)

In Rust, in the reader thread, on the ALTERNATE screen. The reasons, in the order they decided it:

* **Input is live from the first frame** (item 2). The reader thread is what accepts a key, so a version of
  the animation that ran in Lua would have blocked the interpreter the keys are delivered to. In the reader
  thread the animation and the key are on the same thread: the key ends it in the same iteration and is
  passed on to the editor, which is what "any key ends it at once, is not lost, and lands in the draft"
  means. Nothing the node does at start waits for it either: `chat.lua` calls `host.opening_start` and
  returns to its own work.
* **The final screen is today's screen, byte for byte.** Every console write goes through
  `wa_term::terminal_editor::write`; while the opening plays that funnel KEEPS the bytes
  (`terminal_editor::hold`/`release`, `rust/wa-term/src/terminal_editor.rs`). When the opening ends -
  a key, a resize, its own last frame, the interpreter leaving - the alternate screen is left and the held
  bytes are written in the order they were made. So the reader lands on exactly what a start without an
  opening writes, and the alternate screen is what guarantees "no leftover glyph, no moved scrollback".
* **Giving the terminal back is not new machinery.** The panic hook is `wa_term::scroll::screen::install_panic_restore_with(Mode::Fullscreen)` (armed for the opening, put back when it ends), and an `atexit`
  handler writes the restore sequence with a bare `write(1, ..)` if the process leaves mid-opening. Ctrl+C is
  a byte in raw mode: it ends the opening like any other key.

`rust/wa-term/src/opening.rs` is the animator and owns no screen, no clock and no keys: `Opening::step`
answers the next frame's bytes and `Opening::delay` how long it is held. Its frames are a function of a
step counter, not of the wall clock, so a starved thread cannot make it skip; the host still enforces the
budget, so it can only be shortened.

### The acts, as the sketch has them, inside 2.0 s (`7d1db266`, reworked for demo 10)

rain 8 frames, the ignition 6 (a growing point of light in the middle of the rain: dot, bullet, circle,
star), the supernova 22 (the flash, the debris sphere, the ring), the cloud hanging and turning 8, the
collapse 12, the star landing 3 - then the header: the rule and the title in alien letters, the translation
in at most 24 beats (so a long release tag cannot stretch it), then the rest of the block a line at a time.
`planned_ms()` for a 100x30 console with today's 9-line banner is **1922 ms** (measured: 87 frames, 59 of them acts) - asserted, not measured by
eye, by `the_whole_opening_fits_the_budget` and `a_longer_header_cannot_push_the_opening_past_the_budget`.

The 3D is the sketch's, ported: world units are terminal ROWS, the camera looks down +z (`cam = 3.2 x`
the ring's radius), a point is drawn at `x*2` columns and scaled by its distance (`k = cam/(cam+z)`), and
depth picks both brightness and glyph - which is why the far debris is a line of middle dots and the near
pieces keep their letters. The ring is three bands in ONE tilted plane (`TILT`, `ROLL`), solid and bright
where it is in front and a light shade where it is behind; it scours the rain inside its radius as it
passes. The collapse is the sketch's too: a last turn (`(1-s) * 0.9`, signed by depth), `s = (1-a)^2.4`,
ending white in the star's cell. The 3D scene is `Opening::scene`/`collapse`, a pure function of progress
and turn - which is what lets the tests assert on it without a screen.

Each frame writes only the cells that changed, addressed by row and column, so the translation beats are
one row each (`a_frame_writes_only_what_changed`: under 400 bytes, and the rule is not redrawn).

### The supernova's own tests (the tornado's are gone with it)

At the level a reader sees it, in `rust/wa-term/src/opening.rs`:

* `a_point_of_light_ignites_in_the_middle_of_the_rain` - the centre cell holds one of the ignition glyphs
  in the white of `HEAD`, with the rain still falling around it (over 100 painted cells);
* `the_supernova_flashes_and_blows_a_sphere_of_glyphs_apart` - the first supernova frame is a disc of
  light (at least 20 solid blocks in the 3 rows around the centre, not one cell), and by the end of the act
  the lit cells reach across more than 40 columns;
* `the_ring_is_one_band_in_one_tilted_plane_with_a_bright_near_arc` - the ring's glyphs occupy under 45%
  of the box they span (a band, not a filled disc), span at least 6 rows and 30 columns, and BOTH arcs are
  there: bright near cells and dim far ones;
* `everything_falls_into_the_stars_cell_and_the_star_lands_in_it` - through the collapse the spread only
  shrinks, ends under 10 columns wide, and the star then lands in that cell;
* the pty row still measures the promise itself: the final screen equals the one with the opening off (and,
  with `WA_BASE_BIN`, the base binary's), a key ends it, a resize ends it, and off/NO_COLOR/resumed/message/
  pipe/too-small write zero frames.


## The two green glyphs (`c8e3f625`)

`PALETTE.matrix = "00ff41"` is an entry of its own (`cli_view.lua:104`, inside the palette the base has at `:79`), so `accent` keeps every other use.
Three call sites moved to it: the welcome line's star (`M.banner`), `M.marks` (the frames that travel to the
host, i.e. the animated first glyph of the run status row), and the fallback layout's spinner - the same
glyph on the same row when there is no native editor, which would otherwise have kept the old colour on a
short window. The phase word of that row is still `accent`, and `Summary of earlier turns` is untouched.

## The policy (`2c0af8a3`)

`cli_view.opening(opts)` (`cli_view.lua:1036`) answers `(plays, reason)`. Off: the setting `WASM_AGENT_CLI_OPENING=off|0|no|false`;
a scripted run; a start whose stdout is not a live view; no native editor; a resumed session (`--continue`,
`--resume`, `--session`); a message argument; `NO_COLOR`; `TERM=dumb`; a window under 60x14 (from the view's
width and `view:rows()`). It refuses on doubt: `editor` must be exactly `true`, `live` exactly `true`.

The host refuses AGAIN, by name, in `host.opening_start`: `no_console`, `no_editor`, `too_small`,
`already_playing`, and `draft` (a key or a paste that arrived before the first frame - the reader is
already typing and is not made to wait for a decoration). `host.opening_header` answers `false` when no
opening is playing. Nothing here is a silent pass.

The one setting is the node config knob beside the other CLI ones (`WASM_AGENT_CLI_EDITOR`,
`WASM_AGENT_CLI_FRAME`, `WASM_AGENT_CLI_SYNC`, `WASM_AGENT_CLI_TICKER`): `KEY=VALUE` in the node's
`<config>/env` file, read through `host.getenv`. `WA_OPENING_MS` is the same shape of knob for a test only:
clamped to `[100, 2000]`, so it can shorten the opening and never lengthen it.

A second `wa chat` within the same minute plays it: there is no state for that, as asked.

## What was measured, and what each row proves

* `rust/wa-term/tests/opening.rs` (new; five rows, 5.2 s) drives the REAL binary in a private pty and reads the
  screen back through `wa_term::scroll::vt::Vt` - the terminal in memory the render tests use.
  * the final screen with the opening ON equals the final screen with it OFF, row by row, with only the
    session id and the build's own version blanked (two starts cannot share either); with `WA_BASE_BIN`
    set it also equals the BASE binary's screen, so "off" is the old path and not merely this tree's
    opinion of it (measured green against `23791f56`, built in a separate worktree);
  * the bytes hold `\e[?1049h` and `\e[?1049l`, and at least 8 of the 26 alien glyphs appear in the frames;
  * `opening = off` writes ZERO animation frames;
  * a key sent while it plays ends it in under 1500 ms and is in the draft; a key sent 100 ms after the
    process starts (before the first frame) is in the draft too, and the opening it interrupts plays under
    400 ms of its 700;
  * `NO_COLOR`, `--session <id>`, a message argument, a pipe (stdout not a tty) and a 50x12 window each
    write zero frames and never take the alternate screen.
  * The child is started with `env_clear` and an allow-list. Measured before that fix: the pty inherited
    the operator's provider variables and the compared screen said `model: deepseek-v4.1-flash @
    http://127.0.0.1:8810/...` on a scratch home with no provider at all.
* `scripts/test-opening.lua` (new; 39 checks) is the Lua half, with no terminal: `matrix` is `00ff41` and
  `accent` is still `d77757`; the welcome line's star and every `marks` frame carry the matrix escape and
  not the accent; the phase word of that row still carries the accent; the policy table with all eleven
  refusals, each by name; `WASM_AGENT_CLI_OPENING=on|0|nonsense`; and `welcome_painted` (the block the last
  beat draws, `cli_view.lua:2178`) has the rule at the console's width, the green star, and no rule marker left in it.
  Wired into `scripts/test.sh` (next to `test-cli-view.lua`) and picked up by the fast path automatically
  (every `scripts/test-*.lua` not in `scripts/fast-path.exclude` is a fast row, and this one is not listed).
  The pty row is wired into `scripts/test.sh` as `gate_run env WA_BIN="$BIN" cargo test ... -p wa-term --test opening`.
* Its discriminating power was measured BY HAND against the base, because `scripts/test-discriminates.sh`
  cannot judge it: this branch changes `rust/`, so the tool names the Lua row `unrevertable` and the Rust row
  `skipped` ("this platform has no runner for it") and says, correctly, that nothing was judged. Run against
  the BASE tree and the BASE binary, `scripts/test-opening.lua` answers `opening: 7 ok, 10 failed` with the
  colour assertions failing first - the star is the accent there.
* `scripts/test-start-instant.lua`, run with each binary against its own scratch home: 330 ms (quiet ledger)
  and 604 ms (write lock held 10 s) on this branch, 330 ms and 594 ms on the base. Within noise. The row
  drives a scripted fixture turn, which is a path the opening never plays on; the interactive
  time-to-first-accepted-key is the pty row's "a key 100 ms in is in the draft".
* The pty tests that drive `wa chat` for something else now say `WASM_AGENT_CLI_OPENING: 'off'` in their
  environment: the opening is measured by its own row, and those rows should not pay two seconds of
  animation before the screen they read (measured: `test-chat-start-pty` reached its prompt at 2210 ms with
  the opening on, 16 ok both ways).

## Glyph widths, measured on this node

With `unicodedata.east_asian_width`: all 26 alien letters are `N` (narrow), the 56 half-width katakana are
`H` (narrow), and `✻` is `N` - so every glyph is one column and the title's translation keeps its cells
(`the_title_is_alien_letters_until_it_is_decoded_and_it_keeps_its_cells` asserts the row is 34 cells before
and after). With `fc-list :charset=..` on this node: all 56 katakana have a monospace provider; 5 of the 26
alien letters (`☊` U+260A `⎎` U+238E `☌` U+260C `☍` U+260D `⎐` U+2390) are provided only by a
proportional font (Noto Sans Symbols, beside JetBrains Mono), which foot falls back to inside the same cell.
So the katakana stayed: they do not break alignment, and no font on this node is missing them.

## What is not done, or not measured

* A resize ENDS the opening (the simplest answer the brief allowed). `opening_tick` compares the console's
  size with the one the opening was built for and finishes it; the buffered start bytes then go out at the
  old width and the view repaints at the new one at its next frame. MEASURED by
  `a_resize_ends_the_opening`: the pty's window is moved to 80x20 while the rain plays, the alternate
  screen is left within 1500 ms, and the header is on the screen at the new size.
* The panic path and the `atexit` path are implemented and reviewed but NOT measured: forcing a panic or an
  `os.exit` inside the two seconds the opening is up needs a fault injected into the start path, and none of
  the honest ways to inject it were in scope. `Ctrl+C` IS the ordinary key path and is measured.
* `WA_OPENING_MS` below 100 ms is clamped, and no test drives the clamp.
* The first frame's first paint happens inside `host.opening_start`; a frame that arrives while the reader
  thread is descheduled is skipped rather than delayed, which is by design and not separately measured.

## The fast path, measured side by side with the base

`flock -o ~/Work/missions/.suite.lock bash scripts/fast.sh` on this branch and on the base worktree
(`/home/victor/Work/missions/launch-opening/base` at `23791f56`), each with its own binary and target dir:

| | branch `3313a8e9` | base `23791f56` |
| --- | --- | --- |
| rows | 397 | 394 |
| failed | 45 | 44 |

The 44 are the SAME rows by name on both trees - they are not this change, and they are named here
rather than waved away: `scripts/test-capability-inventory.lua`, the fifteen `scripts/test-codemode-*.lua`
rows, `test-edit-aliases.lua`, `test-envelope.lua`, `test-harness-evaluator-replay.lua`, `test-hooks-nested.lua`
and the rest of the list in `trees/wt4` and `trees/base2`'s `wa-fast-result.json`, all of them failing on
`the sandbox answered capabilities()` / `codemode_not_enabled` in this node's setup. `run-live-pty` fails
2 ok / 6 failed on both.

The 3 extra rows are the ones this branch adds (`rust wa-term`, `rust wa-capabilities`,
`scripts/test-opening.lua`) and they PASS. The one row that differed, `build-info`, was the test binary
being one commit behind its tree (`got '5a575215...' want '3313a8e9...'`, `dirty=true`): after rebuilding
at HEAD the row answers `test-build-info: 24 checks, 0 failed`.

`scripts/test-discriminates.sh 23791f56` judges neither of the new rows on this machine and says why
(`unrevertable` for the Lua row - this branch changes `rust/`, so the row would run against this tree's
binary - and `skipped` for the Rust row). The hand measurement that replaces it is above: the base
tree + base binary answer `opening: 7 ok, 10 failed`, and the pty row compares this tree's `opening = off`
screen with the BASE binary's screen when `WA_BASE_BIN` is set (green).

## ADDED 22/11 21:33Z: the two text changes, and the colour FINAL at xterm 41

### The product version in the title line

The welcome line is now `✻ Welcome to wasm-agent! v0.1.0 · v<sha>`: the product version, a space-dot-space,
then the build's own label as it was.

**Where the constant lives:** `lua/core/build_identity.lua`, `M.PRODUCT_VERSION = "0.1.0"` (line 42). It lives
there because that module already owns the question "what version is this?" and the *difference between a
product version and a build's identity* - which it now spells out beside the constant, so the two can never
be confused again. It is a LITERAL on purpose: it is the product number, not the tags’ `v0.1.0-alpha.N` slug (a release
step will own it), and deriving one from the other is the exact mistake this module exists to prevent.
**Victor’s correction, 22/11: it is `0.1.0`, not `1.0` - "v1.0 is wrong"** - which also makes it agree
with the crates and the public tags. The release step owns that one line from now on - nothing else in the
tree spells the number, and `scripts/test-opening.lua` asserts both that it is 0.1.0 and that it carries no
`alpha`.

The tree had NO product-version constant before this: `build_identity` carries `crate_version` (0.1.0, read
from the binary and explicitly never the identity) and `release.parse_version` parses tags, and neither is a
product version.

Composition: `M.banner` draws `paint(STAR, "matrix") .. " Welcome to " .. bold("wasm-agent") .. "!"`, then
` v<product>`, then ` · `, then `v<label>` - each piece from `opts`, so the view composes no number of its own
(a caller that passes no product gets today's `! v<sha>`, which a test pins). `lua/core/chat.lua` passes
`product = build_identity.PRODUCT_VERSION` beside `version = build_identity.label()`.

### The model line: one space on each side of the dot

`deepseek-v4.1-flash @ http://127.0.0.1:8810/opencode-go/v1 · reasoning high` - it had two spaces on each
side. The string was composed inline in `lua/core/chat.lua` (the only place that composed it, measured with
`rg` over `lua/core`); it is now `cli_view.model_line(mode, reasoning)`, one composer beside the box that
draws it, and `chat.lua` calls it. `scripts/test-cli-view.lua` pins the exact string, that no double space
survives in it, and that a provider with no reasoning level gets no dangling dot (`""` and `nil`).

### The colour, FINAL

The star is **xterm 41, `#00d75f`**, not the `00ff41` this branch started from (Victor, 22/11 21:33Z):
`PALETTE.matrix = "00d75f"` (`lua/core/cli_view.lua:104`) and `wa_term::opening::MATRIX =
"\x1b[1;38;2;0;215;95m"`, so the star that LANDS in the animation is the star the finished header keeps.
`scripts/test-opening.lua` asserts the hex, the role's 24-bit escape, the star of the welcome line and every
`marks` frame; the animator's own unit test asserts the star cell's SGR. The rain's trail ramp is its own
ramp (it fades through darker greens) and was not moved.

Tests, as they stand after this addition: `scripts/test-opening.lua` **39 checks**, `scripts/test-cli-view.lua`
**557 checks**, `rust/wa-term` 194 + 4 + **5 pty rows** + 1, all green. In the pty row the screen comparison
blanks everything after `Welcome to wasm-agent!` (two binaries cannot share a commit, and the product version
is still compared) and collapses the spaces around `·` (the one string this change edits), so parity with the
base binary is still a whole-screen comparison of everything else - measured green against `23791f56`.

One thing found and NOT touched, measured on the base as well: `scripts/test-cli-resize.lua:94` and
`scripts/test-run-live.lua` contain the byte pair `\x0194\x0183` where a `·` was meant - mojibake from an
earlier patch, identical on `23791f56`, so it is named here and left alone. `scripts/test-cli-input.lua`
answers `5 failed of 24` on BOTH trees (it is already in `scripts/fast-path.exclude`).


## Texts to approve

No user-visible text is added: the animation draws the existing header (its words, its version, its
rule) and glyphs from the alien table. The new operator-facing names, verbatim:

1. `WASM_AGENT_CLI_OPENING` - the setting, `on | off`, default `on` (node config `env` file).
2. `WA_OPENING_MS` - test-only pacing override, clamped to `[100, 2000]`.
3. The refusal reasons `host.opening_start` can answer: `no_console`, `no_editor`, `too_small`,
   `already_playing`, `draft`.
4. The new host capabilities: `opening_start`, `opening_header`.
### Texts this addition changes (verbatim)

5. The title line: `✻ Welcome to wasm-agent! v0.1.0 · vc6f890e3` (was `✻ Welcome to wasm-agent! vc6f890e3`).
6. The model line: `deepseek-v4.1-flash @ http://127.0.0.1:8810/opencode-go/v1 · reasoning high`
   (was `... /v1  ·  reasoning high`, two spaces on each side).
7. The palette entry `matrix`, FINAL at `00d75f` (xterm 41).


## Files

`lua/core/cli_view.lua` (palette entry, the star, the marks, the fallback spinner, `M.opening`,
`M.model_line`, `METHODS:welcome_painted`), `lua/core/chat.lua` (start the opening, hand it the painted block,
pass the product version, compose the model line through `cli_view.model_line`), `lua/core/build_identity.lua`
(`M.PRODUCT_VERSION`, the one place the product version is spelled),
`rust/wa-term/src/opening.rs` (new), `rust/wa-term/src/lib.rs`, `rust/wa-term/src/terminal_editor.rs`
(the hold and `write_now`), `rust/wa-capabilities/src/host.rs` (the two capabilities, the reader thread's
clock and the hand-back), `rust/wa-capabilities/src/capabilities.rs`, `rust/wa-capabilities/src/core_component.rs`
(refused in a component run), `rust/wa-term/tests/opening.rs` (new), `scripts/test-opening.lua` (new),
`scripts/test.sh`, `scripts/test-cli-view.lua` (one assertion moves from `accent` to `matrix`), and the seven
`scripts/test-*-pty.mjs` files that now say `WASM_AGENT_CLI_OPENING: 'off'`.

One assertion was CHANGED, never loosened: `scripts/test-cli-view.lua`'s "this view's marks, in this view's
order" compared the mark against `paint(spinner(0), "accent", true)`; it now compares it against
`paint(spinner(0), "matrix", true)` and says so in its own comment. `scripts/test-opening.lua` asserts the
rest of that row is still the accent, so the change cannot spread.
