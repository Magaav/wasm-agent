# tui-polish-3 - the ball is not green, and the turn block stays in the answer

Base: origin/main `ac7717e0` (branch `change/tui-polish-3`). Two commits, one per item.
Every claim below cites the commit that implements it.

## Item 1 - the one space after a status icon is KEPT (no commit: nothing changed)

Victor, 19/11 09:20: the one space between an icon and its value is better than before. It is not
reverted, and this mission did not touch it.

* `GAP` is still the single constant and still one space: `lua/core/cli_view.lua:298` reads
  `local GAP = " "` on this branch AND on the base - `git show ac7717e0:lua/core/cli_view.lua |
  grep -n "local GAP"` gives the same line 298.
* No commit of this branch changes it: `git diff ac7717e0..HEAD -- lua/core/cli_view.lua | grep GAP`
  finds nothing.
* The orchestrator note warned that a commit here may have set `GAP` back to "" (glued). No such
  commit exists in this branch history: `git log --oneline -S'local GAP = ""' --
  lua/core/cli_view.lua` answers empty, so there was nothing to revert. (Re-measured, not assumed.)

The run row is therefore byte-identical to the base - rendered from both trees with the same inputs:

```text
before: 󰷺 3·3s Δ5.3k ↑9.5k ↓851 󰔛 0:25
after : 󰷺 3·3s Δ5.3k ↑9.5k ↓851 󰔛 0:25
```

## Item 2 - the context ball has no colour of its own at the normal level (commit `8bc48e37`)

What was wrong: `M.ball_role("normal")` returned `success`, so a comfortable context drew the
success GREEN. Green is not this row icon pattern - the steps, clock, turn and cache icons beside it
wear the row own secondary colour, and on a status row a colour has to MEAN something.

The fix (`8bc48e37`, `lua/core/cli_view.lua`):

* `M.ball_role` answers `nil` for the normal level - "no colour of its own" is a value, not a
  missing case - and keeps `warning` (amber) from `threshold - 15` and `error` (red) at or above
  the trigger. Nothing else about the level arithmetic changed.
* `M.colour_ball` returns the row BYTE FOR BYTE when the level has no role, so the glyph inherits
  exactly what its four neighbours wear - whatever role the row happens to paint (the run row says
  `muted`, the session bar under the box says `dim`). That is why normal is "no role" rather than
  a hardcoded hex: the ball cannot become the one shade that disagrees with the row it sits in.
* Warning and alert are unchanged and still close after the glyph, so the percentage beside it keeps
  the row own colour.

Rendered footer rows, threshold 90.0% on a 1.0M window (same inputs on both trees):

```text
                        before                                 after
normal  (0.5%)   [green]󰝦 0.5%/1.0M 󰆼 49.47%          󰝦 0.5%/1.0M 󰆼 49.47%  (no escapes at all)
warning (80%)    [amber]󰪣 80.0%/1.0M 󰆼 49.47%         [amber]󰪣 80.0%/1.0M 󰆼 49.47%
alert   (90%)    [red]󰪤 90.0%/1.0M 󰆼 49.47%           [red]󰪤 90.0%/1.0M 󰆼 49.47%
```

The exact bytes, taken from the two trees with the same script:

```text
base  normal : \e[38;2;78;186;101m󰝦\e[0m\e[38;2;119;119;119m 0.5%/1.0M 󰆼 49.47%
HEAD  normal : 󰝦 0.5%/1.0M 󰆼 49.47%
base  warning: \e[38;2;255;193;7m󰪣\e[0m\e[38;2;119;119;119m 80.0%/1.0M 󰆼 49.47%
HEAD  warning: \e[38;2;255;193;7m󰪣\e[0m\e[38;2;119;119;119m 80.0%/1.0M 󰆼 49.47%
base  alert  : \e[38;2;255;107;128m󰪤\e[0m\e[38;2;119;119;119m 90.0%/1.0M 󰆼 49.47%
HEAD  alert  : \e[38;2;255;107;128m󰪤\e[0m\e[38;2;119;119;119m 90.0%/1.0M 󰆼 49.47%
```

Render tests for the three levels (`8bc48e37`, `scripts/test-cli-view.lua`): a new block drives the
REAL composition - `session_summary` composes the glyph, `colour_ball` paints the row with the same
percentage - and asserts, against the node own `compaction_threshold`: (1) the normal row is
identical to the bare row and contains no escape at all; (2) warning opens amber at the glyph and
leaves the visible characters unchanged; (3) alert opens red at the trigger; (4) the three rows are
three different rows, so a test that rendered two levels alike could not pass.

The older assertions that pinned green were rewritten, not deleted: "a comfortable context paints the
ball in the normal role" became "a comfortable context leaves the row byte for byte, with no colour
of its own", plus an explicit `ball_role("normal") == nil`. `scripts/test-cli-view.lua` now runs 479
checks (was 463).

## Item 3 (added, Victor 19/11 09:15) - the turn block STAYS in the answer (commit `419ec9b4`)

"leave the <turn> block IN THE ANSWER as before - stripping it was over-engineering for a temporary
signal (once we mature the harness we just remove it)".

* `lua/core/turn_journal.lua`: `M.split` now PARSES and never cuts. `visible` keeps its name
  because every caller asks for it by that name, but it is the text the function was handed, byte
  for byte, block included. The `seam` whitespace cleanup went with the cut it existed to serve.
* `lua/core/agent.lua`: the answer and the run outcome are `reply`, whole. The note is still parsed
  and still recorded in the run journal (session, mission, build, mode, the three fields and the
  block), and the `turn_note` event still carries the fields so a consumer need not re-read the
  journal.
* `lua/core/cli_view.lua`: the dim "circled mark turn · ..." row and its `turn_notes` handling are
  gone - `M.turn_note_line`, `METHODS:turn_notes_flush`, the `turn_note` event arm and the run-end
  flush call. The block is already in the answer, where the model wrote it, so a second row would
  print it twice.
* The envelope no longer tells the model its block is removed, and `docs/TURNS.md` says so too.

The journal keeps working: `wa turns`, `wa turns --day` and `/turns` all read the same `turn_notes`
table through the same `journal.recent` / `record` calls, which this commit did not touch
(`git show 419ec9b4 -- lua/core/turn_journal.lua` changes `split` and the header only).

Plain-text before/after of what a reader sees for an answer of "42" plus a block:

```text
before                              after
42                                  42
circled-mark turn · the parser...    <turn>
                                      - **what hurt** - ...
                                      - **what it buys** - ...
                                      - **focus** - ...
                                    </turn>
```

## Tests, and where they are wired

No new test FILE was added: every new check lives in a suite `scripts/test.sh` already runs, each
with its own scratch HOME (the home guard in `scripts/lib/test-home-guard.lua` refuses to run
otherwise).

| suite | wired at | result |
| --- | --- | --- |
| `scripts/test-cli-view.lua` (item 2 render tests) | `scripts/test.sh:1741` (and :1747 with the reserve fixture) | 479 ok |
| `scripts/test-turn-signal.lua` (item 3 end-to-end) | `scripts/test.sh:1139`, own scratch home | 152 ok, 0 failed |
| `scripts/test-turnfeed.lua` (the reader the journal feeds) | `scripts/test.sh` | 143 ok |

The end-to-end test for item 3 (`419ec9b4`, `scripts/test-turn-signal.lua`) drives the REAL agent
loop with a stubbed provider - no network, no paid call - and asserts both halves of the brief:

1. the answer contains the `<turn>` block VERBATIM (`reply_text:find(BLOCK, 1, true) == 5`, with the
   42 and its blank line still in front), and `reply_text == REPLY` byte for byte;
2. the journal row exists for that session, read back through `journal.recent`, with the session, the
   focus, what hurt, what it buys and the block itself.

What I ran: `test-turn-signal` 152/0 failed, `test-cli-view` 479 ok, `test-turnfeed` 143 ok,
`test-raw-code-answer` 11 ok, `test-hooks-agent` 23 ok. Built with
`WA_CODEMODE_ALLOW_EMPTY=1 cargo build --release -p wa-host` (the code-mode assets are not needed by
Lua-only suites; the default build refuses without them).

## Pre-existing failures (measured on the base, not mine)

Two suites fail IDENTICALLY on a base worktree at `ac7717e0` with the same binary, so neither is
caused by this mission:

* `scripts/test-context-usage.lua`: `:23: no actual summary, and no attempted request, at threshold
  equality` - same message on base.
* `scripts/test-prompt-layers.lua`: `:5: read is native main-loop bootstrap` - same on base.

## Premises of the brief that were wrong or stale

1. The brief calls the context ball an icon in the ROW; the ball is composed by `session_summary` and
   painted by `colour_ball` on the footer/session bar, not by `run_numbers`. The colour fix therefore
   lives in `ball_role`/`colour_ball`, and the run row is untouched (that is item 1 row).
2. The orchestrator note anticipated a commit that set `GAP` to "". There is none - see item 1.
3. The brief says "GAP as the single constant"; that is accurate (`cli_view.lua:298`) and it is the
   only definition - the ball mapping is still one place, as tui-polish-2 left it.

## Texts to approve (new or changed, verbatim)

1. Model-facing envelope line, `lua/core/agent.lua:267` (REPLACES "The harness removes this block
   from the answer it shows, ..."):

   > The block stays in your answer exactly where you write it - it is not removed from what the
   > reader sees - and it is also stored in the run journal (session, mission, build, mode and the
   > three fields) so the fleet can read the friction without parsing a transcript.

2. Operator-facing docs, `docs/TURNS.md`, new paragraph after the intro:

   > **The block stays in the answer.** It used to be cut out of what the reader sees and kept only
   > in the ledger; that was over-engineering for a temporary signal (Victor, 19/11 09:15: "once we
   > mature the harness we just remove it"). `turn_journal.split` therefore PARSES the note and
   > returns the answer unchanged - `visible` is the text it was handed, byte for byte - so the
   > answer a reader gets, the answer a parent reads and the answer the ledger keeps are one text.
   > The run journal still records the row (session, mission, build, mode, the three fields and the
   > block), which is what the readers below work from.

3. REMOVED operator-facing strings (no longer printed anywhere): the dim row
   "circled mark turn · <focus> ... +N chars" and its fallback "(kept in the run journal)"
   (`M.turn_note_line`, deleted in `419ec9b4`).

## What I did NOT do

* I did not run the full `scripts/test.sh` gate (a cold gate on this node compiles the whole Rust
  workspace and runs the fleet proofs). I ran the suites this mission touches plus their nearest
  neighbours, and the two failures I found are pre-existing and named above.
* I did not push, tag or land anything. Two commits are local on `change/tui-polish-3`.
* I did not capture a live terminal frame of the Rust footer renderer (`rust/wa-term`). I read it:
  `footer_draw` hands `colour_ball` the row text and the host clips by CELLS with escapes counting
  zero - existing behaviour this commit does not change - but I did not run a terminal capture.

---

# tui-polish-3, round 2 - the run row says when, the bubble wraps at spaces, a band paints with EL

Base: origin/main `ac7717e0`, rebased before any edit (`git rebase origin/main` answered "up to date").
Every claim below names the commit that implements it. Round 1's two commits (`8bc48e37`,
`419ec9b4`) are untouched by this round.

| item | what Victor asked for | commit |
| --- | --- | --- |
| A | a SIGMA on both session totals | `8c63b62a` |
| B | a finished run appends ` · 🄬HH:MM`; a failed one keeps the row without it | `3cf4bf22` |
| C | the turn block stays in the answer, no dim row | round 1 `419ec9b4` (verified, nothing to change) |
| D | wrap at the last space, not mid-word - one wrapper | `c094a20d` |
| E | the bubble takes its width at render time | `54525ab6` |
| F | backgrounds paint with EL, never pad spaces | `54525ab6` |
| G | a resize repaints the whole chat from state, debounced | `4c0259ba` |
| H | the run row is THIS RUN only; totals live in the footer | `b4cf075e` |
| I | the fence card is in step (phase 0 first) | `68444949` |

## A - a SIGMA on both totals (`8c63b62a`)

`M.session_summary` now writes the sigma before the down arrow as well:
```text
before: 👐1 Σ↑9.5k ↓851 🪟0.5%/1.0M 🆼42.99%
after : 👐1 Σ↑9.5k Σ↓851 🪟0.5%/1.0M 🆼42.99%
```
The two arrows were already TEXT and already glued to their number; the sigma says the pair are the
session's two SUMS, which is what the footer means. Test: the composed row is compared whole, and two
further checks count the sigmas (exactly 2) and prove every arrow on the row carries one - so a bare
arrow anywhere fails (`scripts/test-cli-view.lua`).

## B - a finished run says WHEN (`3cf4bf22`)

`M.run_numbers` takes a third argument, `finish`, and appends ` · 🄬 HH:MM` only when
`finish.ok`. `M.finish_time` is the one place the hour is formatted (`os.date("%H:%M", epoch)` - the
reader's own zone, measured on this node: local 07:23 against UTC 10:23). `METHODS:answered` hands
`{ ok = true, at = self.now() }`; `METHODS:failed` hands `{ ok = false }`.

```text
in flight: 🍺 3·3s Δ↑0 ↑9.5k ↓851 🔛 0:25
finished : 🍺 3 Δ↑0 ↑9.5k ↓851 🔛 0:25 · 🄬 07:20
failed   : 🍺 3 Δ↑0 ↑9.5k ↓851 🔛 0:25
```
Tests: both rows are rendered and asserted (the finished row is the bare row plus the stamp, the stamp
follows the elapsed clock, the local hour is not the UTC hour, a missing clock prints nothing), and the
WIRING is asserted separately on the two paths, so what each caller says is checked and not only how
the row is drawn.

## C - the turn block (`419ec9b4`, verified)

`turn_journal.split` parses and returns the text unchanged, `M.turn_note_line` and
`METHODS:turn_notes_flush` are gone. Re-measured this round: `grep -n 'turn_note_line|turn_notes_flush'`
over `lua/` answers nothing. **No change was needed and none was made.**

## D - one wrapper, breaking at spaces (`c094a20d`)

`codemode_block.wrap` used to cut at the exact cell. It now walks the text one CHARACTER at a time
(with its byte width, so a multi-byte character is never split), takes the last space that fits on the
row, and breaks there - swallowing the space, because the space IS the break. It goes inside a word
only when that word alone is wider than the row (a URL).

```text
60 cols, before: [preciso que a anotacao na linha aqui seja quebrada nas pal] [avras e nao ...]
60 cols, after : [preciso que a anotacao na linha aqui seja quebrada nas] [palavras e nao no meio dela]
```
Every wrapped prose component already went through this one function (the bubble in
`METHODS:accepted`, the code band in `codemode_block.rows`), so the rule and the fix are one place.
Tests: long Portuguese text at 60/80/120 - every row is a slice of the original, every break falls on
a space, every row fits - plus the long-word case and the single-row case. The committed code-mode
snapshot changed in exactly four lines, all of them a break moving from mid-token to a space.

## E - the bubble takes its width at render time (`54525ab6`)

`METHODS:accepted` calls `self:refresh_limit()` before it wraps, the same read every other framed
component makes (round 1's resize wiring). **A scrollback row that is already printed cannot be
reflowed** - the terminal owns those characters - so there is no full-screen redraw in this path; the
repaint on resize is item G's, and it redraws from state rather than reflowing bytes.

## F - a background paints with EL, not with spaces (`54525ab6`)

What was wrong: a band padded its rows to the screen with SPACES, and padding is characters, so a
narrower terminal re-wraps them - which is the ragged block in Victor's 11:20 screenshot.

* The code band (`codemode_block.rows`) and the user-message bubble (`METHODS:accepted`) now set the
  background colour, print the text, and emit EL (`ESC[K`), which erases in the CURRENT background
  and stops at the screen edge whatever the width is. No row carries trailing blanks at all.
* The band keeps its colour open after the EL on purpose: the host draws a code block's copy icon on
  that right-hand cell and it must wear the band, not the terminal default. `icon_at_band_end`
  (`rust/wa-term/src/transcript.rs`) places it by column on a row that ends with EL, because there is
  no blank cell left to take - so the affordance survived the padding it used to sit in.
* The native input box (`rust/wa-term/src/terminal_editor.rs`) never padded: it draws each row with
  `ESC[2K` first and then the row's own text, and its box is a border of `─` characters, not a
  background. Measured by reading `render` and its border tests; nothing to change there.
* The notices (`METHODS:session_draw`) have no background role at all - the notice is a coloured
  FOREGROUND on the terminal's own background - so there is no pad to remove. Measured, not assumed:
  `grep 'string.rep(" ", ' lua/core/cli_view.lua` answers nothing.

Tests: the emitted bytes of a bubble row end with `ESC[K` and hold no pad space before it; the band's
rows carry no pad before the erase and end on their last character; and the committed code-mode
snapshot's band rows lost their trailing blanks (110 changed lines, every one of them a pad).

## G - a resize repaints the whole chat from state (`4c0259ba`)

The host already re-lays-out its frame on a size change, and the transcript is drawn from its own
block state, so what was missing was the terminal hygiene and the guarantee:

* `resize_console` sets `repaint_after = now + 150 ms`; `repaint_if_due`, called from the idle reader
  loop, clears the screen AND the scrollback (`ESC[2J ESC[3J ESC[H`) once the burst has been quiet for
  the debounce, then draws the whole transcript again at the new width. Old bubbles, code blocks and
  boxes come back correctly sized in both directions. EL (item F) is what holds the picture together
  inside the 150 ms interval.
* Cost, measured on this node (`cargo test --release -p wa-term a_long_session -- --nocapture`, 240
  messages): first view at 120 columns **2.06 ms**, the same chat re-wrapped at 60 columns **575 µs**.
  The draw wraps only what is on screen; nothing re-lays-out per message.

Test: a 12-message chat rendered at 120, shrunk to 60 and widened back to 120 is compared against a
FRESH transcript built from the same writes at each width, and the two widths are asserted to differ so
the comparison is not vacuous.

## H - the run row is this run only (`b4cf075e`)

```text
before: 🍺 2·5s Δ12.3k ↑4.6M ↓310 🔛 1:51      (delta, then the SESSION input total)
after : 🍺 2·5s Δ↑12.3k ↓310 🔛 1:51            (what THIS run sent and received)
```
The session's two sums are the footer's (item A) and no number is printed on both rows. Three older
assertions that pinned the old pair were REWRITTEN, not deleted: the editor's running row, the later
run's row, and the first-step row. The item H test additionally asserts the OLD pair is absent, so a
regression to the old shape fails on its own words and not only on a count.

## I - the fence card is in step (`68444949`)

**Phase 0 first.** `markdown.lua:636-675` builds the rows correctly - so I reproduced one level below
it, in a Rust test that dumps what the host actually stores and draws for these exact inputs
(`a_card_written_into_an_open_line_is_glued_unless_the_line_is_closed_first`). The cause:

* The prose before a fence is written with NO final newline, so its line stays OPEN (the next delta
  continues it).
* `Transcript::write` appends a write's first segment to an open last line - so the card's top border
  was GLUED onto the paragraph: `⏺ Para:┌─`.
* The copy marker counts lines OF THAT WRITE (`copyable`), so with the first line swallowed by the
  prose every later marker pointed one row early - which is the icon where the title row should be,
  the empty bar, and the code line without its bar in Victor's screenshot.

The fix is in `METHODS:markdown`: the line is closed BEFORE the marker is handed over, so the card
starts its own row and the marker counts the card's own rows.

Tests (all in the gate): the Rust rule above (glued without the fix, and with it the prose keeps its
row, the title is its own row, the code bar sits directly under it, the copy icon is on the TITLE row);
and a Lua render test over the three shapes Victor named - untagged one line, tagged css three lines,
and a fence that opens the answer - at 60/80/120 columns, asserting the card has a top, one bar per
code line and a bottom, the bar directly under the title, the paragraph above and NOT glued to the
border, and the copy marker landing on the title row.

## Where the tests are wired

| suite | wired at |
| --- | --- |
| `scripts/test-cli-view.lua` (A, B, D, F, I render tests) | `scripts/test.sh:1741` and `:1747` (reserve fixture) |
| `scripts/test-cli-resize.lua` (F's pad-free band, then reflow) | `scripts/test.sh:1758` |
| `scripts/test-codemode-blocks.lua` (the committed band snapshot) | run by the gate's code-mode block section |
| `rust/wa-term` `transcript::tests` (G's repaint and budget, I's phase-0 rule) | **added this round** at `scripts/test.sh:278` |

What I ran, this node: `test-cli-view` 573 ok, `test-cli-resize` 73 ok, `test-codemode-blocks`
40 ok, `test-markdown` 102 ok, `cargo test --release -p wa-term` 164 ok, `-p wa-capabilities` 340 ok.
The binary is rebuilt from this tree's Lua and Rust (`WA_CODEMODE_ALLOW_EMPTY=1 cargo build --release -p
wa-host`), and the Lua suites run with `WASM_AGENT_LUA_ROOT` pointed at the worktree.

## Pre-existing failures

Round 1 named two, measured on a base worktree: `scripts/test-context-usage.lua` ("
no actual summary, and no attempted request, at threshold equality") and
`scripts/test-prompt-layers.lua` ("read is native main-loop bootstrap"). This round did not run those
two suites and did not touch either file, so their state is UNCHANGED and UNVERIFIED here - they are
not claimed fixed and not claimed broken.

Two suites I tried are unrunnable on this node for reasons that are not this round's:
`test-codemode-presentation` refuses ("actual native helper available") and `test-codemode-friction`
refuses (`codemode_not_enabled`): both need code-mode assets this build was made without
(`WA_CODEMODE_ALLOW_EMPTY=1`). Named, not skipped silently.

## Texts to approve (new or changed, verbatim)

1. The run row while a run is in flight (changed by H):
   `🍺 2·5s Δ↑12.3k ↓310 🔛 1:51`
2. The row a FINISHED run leaves, with the local finish hour (new, B+H):
   `🍺 2 Δ↑12.3k ↓310 🔛 0:25 · 🄬 18:47`
3. The row a FAILED run leaves (unchanged, deliberately without the check):
   `🍺 2·5s Δ↑12.3k ↓310 🔛 1:51`
4. The session footer (changed by A):
   `👐1 Σ↑9.5k Σ↓851 🪟0.5%/1.0M 🆼42.99%`

## What I did NOT do

* I did not run the whole `scripts/test.sh` gate (a cold gate compiles the workspace and runs the fleet
  proofs). I ran the five suites above plus the two Rust crates, and wired the new Rust tests into the
  gate so a gate run includes them.
* I did not push, tag or land anything. Nine commits are local on `change/tui-polish-3`.
* I did not capture a live terminal frame of the items I touched: the render assertions read the bytes
  the view emits and the rows the host draws, not a photograph of a terminal.
* I did not reproduce item F's shrink in a real pty. The property is asserted on the emitted bytes and
  on the stored rows; a pty capture would be a second, stronger witness and is not here.
