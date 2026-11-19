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

