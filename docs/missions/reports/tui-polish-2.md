# TUI polish 2 - four findings from avell, 18/11

Worktree `/home/victor/Work/missions/tui-polish-2/wt`, branch `change/tui-polish-2`, base
`origin/main 44229140`. Built and tested on this node (avell) only. Committed locally, not pushed.

Each item below is one test that fails on the base and passes here, run with a scratch HOME and
`WASM_AGENT_LUA_ROOT=<worktree>`, and no real node.

---

## Item 1 - the node-wide aggregate, drawn dim, never a named row

The backend (per-session progress rows, `node: N ops elsewhere`) lives in
`change/session-isolation` and is **not landed**. This is the TUI half, built against that branch's
function name with a fallback that says nothing until it lands.

| | |
|---|---|
| backend names used | `tool_progress.elsewhere({now, session})`, `tool_progress.elsewhere_text(count)` |
| TUI side | `cli_view.lua` `METHODS:elsewhere_text`; drawn by `METHODS:status_template` |
| test | `scripts/test-cli-welcome.lua` |

**Fallback, stated plainly.** `M.elsewhere` is only called when the module actually has it
(`type(module.elsewhere) == "function"`). On this tree, which does not have it, `elsewhere_text()`
returns `nil` and the status row says nothing about other sessions - the view never invents a count
it cannot read. When the branch lands, the same call returns the count and the row says
`node: N ops elsewhere`, dim, with no tool name, no session id and no line of anybody's output
(asserted, including the three leaks the old node-wide row had).

Strings, verbatim: `node: 1 op elsewhere`, `node: N ops elsewhere`.

## Item 2 - components follow a terminal resize

The width was measured once, before the welcome box, and cached for the life of the process. The
host redrew the input rule and the footer from its own size, so those followed a resize while the
welcome rule, the welcome box, the code-mode box and the rest did not.

**Measured on the base** (a chat created at 80 columns, then maximised to a 200-column terminal):

```
BEFORE terminal=200 drawn_rule=80
AFTER  terminal=200 drawn_rule=200
```

What changed:

* `cli_view.lua` `METHODS:refresh_limit` - the terminal's width, read again. Called at every frame
  boundary (the `FRAMED` wrapper) and by `screen_on`, so a frame's components are laid out from the
  width the terminal has now. A console that will not answer (a pipe, a CI log) or answers nonsense
  keeps the width the view already had; `M.MIN_COLUMNS = 24` is the floor.
* `cli_view.lua` `M.RULE` / `M.expand_rules` / `METHODS:rule` - a rule is written as a marker and
  expanded where the width is known. The banner's divider is the marker, not `string.rep("\u{2500}", limit)`.
* `rust/wa-term/src/transcript.rs` `expand_rule` - the native editor expands the marker **per draw**,
  because a transcript outlives a resize. Plain layout expands at write time (a line written once).
* `chat.lua` no longer passes a one-time `terminal_columns()` as the banner's width.

Inventory of what was checked: welcome box + its top rule, code-mode block, status row, footer,
the aggregate row. Each is rendered at 80, at 200 and back at 60, and no drawn row is wider than the
terminal (a row wider than the terminal wraps - the bounce Victor saw).

Tests: `scripts/test-cli-resize.lua` (54 checks, Lua) and
`rust/wa-term` `a_rule_is_drawn_at_the_width_of_the_frame_and_never_at_the_width_it_was_written`.

## Item 3 - the welcome line says WHY there is no provider

**This is the text that would land. Shown for approval before it does** (Victor: show the exact text):

```
model: none - this shell has no provider env; the node's wa-serve has one: run inside it with `wa chat` via the node, or /login
```

That sentence is the **default** cause: no key, no vault in this environment, while the node runs a
provider. Two other causes are distinguished, and each is *measured*, not assumed:

* model-less node: `this node is declared model-less (<source>, docs/MODEL-LESS.md), so no turn can run here`
* vault set but not answering: `the vault at <url> did not answer (<code>), and the provider is reached through it; check wa-vault, or /login`
* model not served by the route: `the model <id> is not served by this route; pick one with /model`

A note on the vault branch, because it corrected me: on this machine `WASM_AGENT_VAULT_URL` **is**
set and the vault on `:8810` **is** listening. A branch that fired on the variable alone would have
named a false cause; the branch therefore asks the vault its own status and prints the sentence above
when the vault answers. The older sentence `local mode (no model configured)` is gone.

Banner (measured, 120 columns):

```
────────────────────────────────────────────────────────────
✻ Welcome to wasm-agent! v44229140+dirty

/help for help, /login to sign in to a provider

cwd: ~/work/wasm-agent (change/tui-polish-2)
model: none - this shell has no provider env; the node's wa-serve has one: run inside it with `wa chat` via the node, o…
session: abc
```

Test: `scripts/test-cli-welcome.lua`.

## Item 4 - the welcome version is the running build, not a literal

`chat.lua` passed `version = "0.1.0"`; it now passes `build_identity.label()`. One function composes
the identity, and the banner, `wa --version`, `/health` and the update banner read it.

| case | label |
|---|---|
| dev / tree build | `e5ba9089` |
| dirty tree | `e5ba9089+dirty` |
| installed from a release | `node-e5ba908921e8` |
| pinned node | `fc6a9d80 (pinned)` |
| cannot name itself | `unknown build` |

Authorities, in order: **pin** (most specific fact about this node) > **release** (installed from one)
> **build** (the bytes' own compiled-in label) > **unknown** (never a made-up number).

Where it comes from: `rust/wa-host/build.rs` compiles commit/tree/dirty/ancestry into the binary
(`wa --build-info`, existing); `build_info::label()` composes the short name; `install_label()` adds
the release from `installed.txt` and the pin from `<config>/pins.txt`; `main.rs` states it once at
boot through `wa_capabilities::host::set_build_identity`, and Lua reads it via the new
`host.build_identity()` capability (`lua/core/build_identity.lua`, registered in the inventory and
in `docs/HOST.md`).

Measured on this node: `wa --version` -> `wasm-agent 44229140+dirty` (base said `wasm-agent 0.1.0`).

The update banner now fills `commit=` from the running build when the record cannot say it, so
"installed" is the same identity. It still refuses to guess: a build that cannot name itself leaves
the record alone and the answer stays `unknown`. `/health` carries the same string as `build`.

Test: `scripts/test-build-identity.lua` (12 checks).

---

## Pre-existing failures, named

`scripts/test-hotreload.lua`: **5 of 217 checks fail on this tree, and identically on the base**
(stashed and re-run), in the release-payload signature checks
(`payload_signature_invalid` / `payload_file_mismatch`). Not caused by, and not fixed by, this work.

`scripts/test-tool-progress.lua`: **11 of 78 checks fail on this tree AND on the base**, and on the installed binary as well (reproduced three ways). The failing rows are the live-row ones whose fixture depends on the machine's tool-progress file (`two seconds is long enough to say something`, `a live call is the tool kind`, the stall rows). Not caused by, and not fixed by, this work.

`scripts/test-status.lua` fails under the **debug** binary with `codemode_not_enabled` - the debug
build carries no code-mode assets; the same Lua passes 14/14 under the installed binary. Not a
code failure.

## What I did not verify

* A real terminal resize on screen (no real node or pty here): the width behaviour is asserted
  through `refresh_limit`, the banner, the components and the Rust transcript's draw-time expansion,
  not by resizing a window.
* The per-session backend itself: not landed on this base, so item 1's count is exercised against a
  stub module and the fallback (silence) is what this tree actually does.
* `/health`'s new `build` field: asserted by the build and by the capability inventory test, not by
  fetching a running node's `/health` (that would need a deploy, which this mission excludes).

# Round 2 - the bounce, the spacing, the eight slices (19/11)

Mission: `change/tui-polish-2`, worktree `/home/victor/Work/missions/tui-polish-2/wt`, base `44229140`.
Items 1-6 of the 19/11 brief. Every claim below is a commit hash; `git diff --stat 44229140..HEAD` is
quoted in the section it belongs to.

## 1-3. The live row is ONE screen row, and every component measures what the terminal draws

```
1464642d tui polish 2 (1,2): the live row is one screen row (clip_row), the footer is clipped by cells, and the region is measured at 60/80/120/200
 rust/wa-term/src/terminal_editor.rs |   9 ++-
 rust/wa-term/src/transcript.rs      |  23 ++++++
 rust/wa-term/tests/live_region.rs   | 156 ++++++++++++++++++++++++++++++++++++
```

Root cause CONFIRMED, and it is not the one the brief proposed. The native transcript addresses every row
absolutely (`\x1b[{row};1H`) - it never counts cursor-up rows, so there was no drift to find. What the
renderer did do is wrap the RUNNING call's line like prose (`wrap_rows`): each new tail (the clock, the last
line of output) could add a screen row to a block, which moves every row under it and forces the next frame to
redraw them. That is the bounce in Victor's screenshot.

- `transcript.rs`: `clip_row` - the running call's line is cut to one row with a `…` mark (`{`is_live`
  = `self.live_row == Some((index, line_index))``). Code, tool results and prose still SOFT-WRAP
  (`wrap_rows`), because code must stay readable - the brief's "soft-wrap for code, clip for status rows",
  and the code box was never the participant in the bounce: it is static once written.
- `terminal_editor.rs`: the footer's left hint, its right side and the slash menu's hint are clipped by
  CELLS (`clip_cells`) instead of by characters - a status row carrying a Nerd Font icon is measured in
  cells, and a row one cell too wide wraps and moves the box and the chat above it.
- `567e9f2e` also moved the input placeholder and the option hints from `chars().take()` to `clip_cells`
  (+2/-2): they are single-row drawers, so a wide glyph cut by characters overflowed by a cell.
- `0300187d` added `visible_cells` (+15), and `b4c52371` made `clip_cells` escape-aware (-6/+131): an
  escape sequence takes ZERO cells and is never cut in half. Needed because item 6 colours the ball.

Tests (`rust/wa-term/tests/live_region.rs`, wired into `scripts/test.sh` right after
`terminal_editor::tests`): 4 tests, all pass (`cargo test -p wa-term`: 160 passed, 0 failed).
1. `a_300_column_code_line_fits_the_region_at_every_width` - Victor's exact line, 60/80/120/200 columns,
   every row of the view <= width cells.
2. `the_live_row_is_one_screen_row_however_long_its_tail_is` - 20 ticks at each of 60/80/120/200; every row
   that is not the live one keeps its EXACT text, and exactly one row carries `⏳`.
3. `twenty_ticks_move_nothing_and_draw_the_same_rows_every_frame` - through the VT emulator: the same row
   addresses at the same positions every frame, and the screen keeps its height.
4. `a_resize_rewraps_the_same_live_line_without_moving_the_rest` - 60 -> 120 -> 200 -> 80 -> 60.
Plus `a_coloured_row_is_measured_and_clipped_by_its_visible_cells` (1564 cells for a coloured ball row, a
row inside the room returned whole, a cut one ending in the mark) and the clip tests in
`terminal_editor::tests`.

## 4. Regression or not

NOT a regression from round 1, and the 18/11 fix covered something else. Verified:
- `git show deebbca5 -- rust/wa-term/src/transcript.rs` (round 1, 18/11 21:55) is `expand_rule` only: a
  rule marker expanded at DRAW time so a resize does not leave a rule wider than the window. It never
  touched the live row's wrap.
- `093de71f` (18/11, status bar) changed WHICH glyphs sit on the row (U+F0DFA, U+F0450, the five balls),
  not how many rows the row takes: `git show 093de71f -- rust/wa-term/src/terminal_editor.rs` is the
  glyph table and `the_status_bar_glyphs_are_one_cell_each`.
- `git log -S live_row --reverse -- rust/wa-term/src/transcript.rs` first names `ae9893d0` (land27 merge,
  14/11): the live row has been wrapped like prose since it was introduced. Pre-existing for five days.

## 5. One space between every icon and its value

```
ee7176c5 tui polish 2 (5,6): one space between every status icon and its value, nine context balls, the level from the node's own threshold
 lua/core/cli_view.lua     | 67 ++++++++++++++++++++++++++--------
 lua/core/model_window.lua | 17 +++++++++
 scripts/test-cli-view.lua | 92 ++++++++++++++++++++++++++++++++++++++---------
```

ONE constant, `GAP = " "` (`M.GAP`), used by every icon+value pair: steps, clock, turns, cache and the
context ball. The DELTA/UP/DOWN/SIGMA marks are text glyphs and stay glued to their number, as the brief
says. Render test: both rendered rows (run line and session bar) are scanned for every icon and each
occurrence must be followed by exactly one space, and the test fails if fewer than 4 were measured (so an
empty scan cannot pass).

## 6. The context ball: nine states, one function, its colour from the node's own threshold

- Nine glyphs in `GLYPH` (U+F0766 empty floor, then U+F0A9E..U+F0AA5, all verified present in
  `/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf` by the 18/11 test that measures each at one
  cell, and by `the_status_bar_glyphs_are_one_cell_each` in this tree for the four it listed).
- ONE mapping, `M.context_ball(percent)`: below 3% the empty ball, otherwise `round(p*8)` clamped to 1..8.
  No second copy anywhere: `rg 'ballFull|context_ball|F0AA' rust/ lua/ ui/` finds only `cli_view.lua`.
- Colour: `M.context_level(percent, threshold)` - normal below threshold-15, warning from there, alert at
  or above it - and `model_window.threshold_percent(context, reserve)`, which is the SAME arithmetic
  `provider.budget`/compaction uses (window minus reserve, capped by `WASM_AGENT_CONTEXT_BUDGET`), read
  from the code that compacts, never guessed.
- `M.colour_ball(text, context, budget, live)` paints the ball in the level's role and re-opens the row's
  gray after it, so the percentage beside it keeps its own colour; `METHODS:footer_draw` hands that row to
  both drawers (native editor and the fallback row).
- Render test: every boundary (2.99, 3, 18.74, 18.75, 31.24, 31.25, 43.74, 43.75, 56.24, 56.25, 68.74,
  68.75, 81.24, 81.25, 93.74, 93.75, 100) maps to the right glyph; the level's boundaries are asserted
  against the node's own threshold (20 under normal, inside 15 warning, at it alert); a plain rendering is
  untouched; an unmeasured window colours nothing.

## Tests and where they run

- `rust/wa-term --test live_region`: 4 tests, added to `scripts/test.sh` beside `terminal_editor::tests`.
- `scripts/test-cli-view.lua`: 457 checks, 0 failed (was 415 in round 1). Run inside the binary, not bare
  lua: `WASM_AGENT_LUA_ROOT=$PWD WA_SCRIPT=scripts/test-cli-view.lua <wa> --db /tmp/x.db`. Bare
  `lua scripts/test-cli-view.lua` fails at `cli_view.lua:960` (`host` is nil) on the BASE TOO - that is
  the harness's requirement, not a failure of this branch.
- `cargo test -p wa-term`: 160 passed, 0 failed.

## Pre-existing failures, named

None found in `wa-term`. The release build of the `wa` binary cannot be produced in this worktree without
prepared code-mode assets (`wa-capabilities/build.rs` refuses with "code-mode assets required: set
WA_CODEMODE_BUILD_ASSETS"); that is the build's own gate, not a failure of this branch, and it is why the
Lua view test ran on the pre-existing debug binary (Lua is read from `WASM_AGENT_LUA_ROOT`, so it tests
this tree's Lua).

## What I did not verify

- The BOUNCE on a real terminal: everything above is measured in the renderer and through the VT emulator,
  not by watching Victor's screen.
- The two other scenarios the brief lists but this round did not execute end to end: "tick the timer 20
  times and assert the cursor-up count equals the rows drawn" - this renderer has no cursor-up count, so
  the test asserts the stronger property (same addresses, same height, every other row byte-identical);
  and the Fleet View's own ball, which does not exist yet (`rg` finds no copy), so "no second mapping" is
  a statement about today's tree.
- The release binary and the full `scripts/test.sh` gate were not run (code-mode assets were not built
  here).

## Texts to approve (continuing the earlier list)

1. `…` - the continuation mark on a STATUS row that was longer than the terminal (the running call's
   line). Code and prose still wrap in full, so no text is lost.
2. The status/footer rows now render `󰷺 5·17s`, `󰔛 0:56`, `󰑐 1`, `󰆼 0.9%/1.0M`, `󰪟 12.2%/200.0k` -
   one space after each icon. No new words; `Δ`, `↑`, `↓`, `Σ` stay glued.
3. The context ball now has nine states instead of five (the four new glyphs are listed in `GLYPH`), and
   it is COLOURED by the node's compaction threshold: green with room, yellow from threshold-15, red at the
   trigger.
