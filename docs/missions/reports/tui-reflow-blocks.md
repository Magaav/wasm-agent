# tui-reflow-blocks - a run box and a fence follow the window, with ONE continuation mark

Branch `change/tui-reflow-blocks`, base 57551064 (merge base with `origin/main` at the time of writing).

Victor, 22/11, in his own maximised window: the codeact (run) box and a fenced code block stayed wrapped
at the OLD width - a line cut at about half the new window stayed cut, with empty space to its right,
while the prose around them reflowed - and the mark that says "this line goes on below" was drawn two
ways: at the END of the cut row in the run box, at the START of the next row in the fence.

## What was measured before anything was written

The brief said the fence is cut in `rust/wa-term/src/transcript.rs` ~1017-1050. That is the consequence,
not the cause. Measured on the base:

- **The fence was cut in LUA, at compose width**: `lua/core/markdown.lua:667`
  (`local room = math.max(8, width - columns(indent) - 2)`, loop to ~690) cut the body line into rows and
  wrote `│↪` at the start of each continuation. The host's `transcript.rs:1024` `wrap_card` was already a
  draw-time cut, but it only ever saw a row that FIT, so it had nothing to re-cut: maximising could not
  take a cut back, and shrinking made the host cut an already-cut row a second time.
- **The run box was cut in LUA too**: `lua/core/codemode_block.lua:937` called `M.wrap_marked` (876),
  which cut at `width - 1` and put `↪` **in the last cell of the cut row**. Same consequence.
- Prose and rules reflow because they are handed over whole (`transcript.rs` `wrap_rows`, `expand_rule`).

So both blocks had one cause: the cut happened where the text was COMPOSED, and a terminal holds the rows
it was given.

## What changed

**One owner of the cut: the frame that draws it.** `cac58768`

- `lua/core/markdown.lua` - on the transcript's own call (`opts.reflow`) a fence's body row is handed
  over WHOLE, one stored row per source line. The host cuts it at the frame's width with `wrap_card`,
  which already wrote `│↪` in the card's gutter. A plain rendering (a log, a captured run: no host to cut
  it) keeps the old cut, byte for byte.
- `lua/core/codemode_block.lua` - `M.band_mark` writes a script row whole behind the marker
  `\1b<fill>\1`: the fill is the band's own rest-of-row sequence (background + EL), so the palette stays
  in Lua and Rust knows no colour. `M.rows` emits one such row per source line when the host will cut it
  (`reflow`), and the old `M.wrap_marked` cut otherwise.
- `rust/wa-term/src/transcript.rs` - `band_row` reads that marker and `wrap_band` cuts the row at this
  frame's width: the row that is cut keeps its WHOLE width (the mark is never paid for out of it), and
  every row after it opens with `↪` in the LEFT GUTTER, with the band's fill at its end and the colour
  active at the cut reopened after the mark.
- `lua/core/cli_view.lua` - `codemode_opts` passes `reflow = self:transcript()`, so only a real transcript
  asks for the hand-over.

The mark is now the fence's, in the fence's place, in both blocks: one cell in front of the text of the
row the line goes on - never inside the text of the row that was cut.

## Texts to approve

Displays strings that changed. Nothing else in this change is text a reader sees.

1. The run box's continuation mark moved: it used to be `↪` appended to the **end of the cut row**
   (e.g. `... $(du -s↪`), and it is now `↪` at the **start of the row the line goes on**
   (e.g. `↪ -20 | wc -l'});`). The glyph itself is unchanged.
2. No other text changed: a fence still reads `│↪` on a continuation, a code block still has no title,
   results, call rows and the copy affordance read exactly as before.

Screen, at 60 columns, from `scripts/test-reflow-blocks-pty.mjs` on this branch:

```
┌─  bash
│ sh -e <<'EOF' | while read -r line; do printf '%s\n' "$lin
│↪e"; done | sort -u | head -20
└─
And the run block the model wrote, drawn on its band:
const r = await tools.bash({command: 'sh -e | sort -u | head
↪ -20 | wc -l'});
```

## Tests, and that each one fails on the base

Base = a worktree of 57551064 (`git worktree add --detach`, never `git stash`), with the branch's own test
files checked out on top and a binary built from that tree.

| row | on the branch | on the base |
| --- | --- | --- |
| `rust/wa-term/tests/reflow_blocks.rs` | 1 ok | FAILS: no row starts with the band's script line at all |
| `scripts/test-reflow-blocks-pty.mjs` (`9d88cb79`) | 32 ok, 0 failed | 26 ok, 6 failed |
| `scripts/test-markdown.lua` | 107 ok, exit 0 | 110 checks, 5 failed, exit 1 |
| `scripts/test-codemode-blocks.lua` | 63 ok, exit 0 | 63 checks, 5 failed, exit 1 |
| `scripts/test-cli-view.lua` | 553 ok, exit 0 | 553 checks, 3 failed, exit 1 |

The pty row is wired in `scripts/fast.sh` next to `fence-card-pty` (`9d88cb79`); the Lua rows are
discovered by the fast path (`scripts/test-*.lua`, none excluded); the Rust row is a `tests/` file, so
`cargo test -p wa-term` runs it. `node scripts/test-orphan-tests.mjs` is green (325 wired).

What the pty row pins, at 120, 60, 120 and 60 columns on the real binary:

- where the line fits: ONE row per block, whole, and no mark anywhere;
- where it does not: the cut row uses the whole width and carries NO mark, the row the line goes on opens
  with `↪` in both blocks (`│↪` in the fence's border), and neither block loses a character to the cut;
- going back to a width draws the rows the first visit drew (re-cut, not remembered).

`4b8b6126` also closed two holes found while proving the base failure:

- `scripts/test-markdown.lua` printed its verdict ~110 lines before the end of the file, so every check
  under it could print FAIL and still exit 0 - including the pre-existing fence test. The three lines now
  stand at the end. Nothing was loosened; the same lines now see every check.
- two new checks indexed a row the base does not produce and died on a nil index instead of failing by
  name.

Changed assertion, named (rule 6 is honoured by replacing it, not dropping it): `scripts/test-cli-view.lua`
used to pin "nine rows, the mark in the last cell of the cut row" for a code-mode block. That is the
contract this change replaces. It now pins "eight rows, the long one handed over WHOLE behind the host's
marker, no mark where it is composed" - asserted on the marker, on the absence of the mark and on the
exact line, all three of which fail on the base.

## Nothing the model reads changed - how that was checked

- `git diff 57551064..HEAD --name-only` changes ten paths: `lua/core/cli_view.lua`,
  `lua/core/codemode_block.lua`, `lua/core/markdown.lua`, `rust/wa-term/src/transcript.rs`, the Rust test,
  and five test/harness files. Nothing on the model-facing path (`lua/core/agent.lua`,
  `lua/core/codemode.lua`, `lua/core/codemode_results.lua`, the prompt builder) is in the diff
  (`cac58768`, `9d88cb79`, `4b8b6126`).
- `lua/core/codemode_block.lua` is required by `lua/core/cli_view.lua` only among the runtime modules
  (`grep -rn codemode_block lua/` -> cli_view + comments + `reload.lua`'s list); its own header and the
  comment at `lua/core/agent.lua:3721` say nothing on the result path reads it.
- `fixtures/codemode-blocks.txt` - the snapshot of the rows the PLAIN rendering produces at 80x24 and
  120x40, the rows a captured run and the model's own view see - is **not** in the diff, and its test
  (`scripts/test-codemode-blocks.lua`, live=false) is green: the plain rows are byte-identical.
- The stored result view (`M.result_rows`, `M.tail_rows`, `M.finish`) and the answer path are not touched
  by the diff; only `M.rows` (the script's display rows), `M.opts` and the new `M.band_mark` are.

**A hole this build could not close, named:** `scripts/test-codemode-blocks.lua` prints
`SKIP model-facing bytes: this node has no embedded code-mode assets` - the byte-parity check between the
tool result with and without a view listening needs code-mode assets embedded, which this
`WA_CODEMODE_ALLOW_EMPTY=1` build does not have. So the model-facing evidence here is the file list, the
untouched snapshot fixture and the module graph, not a byte comparison of a live run.

## Not verified

- The full `scripts/test.sh` gate was not run (this is a display change; the rows above plus
  `cargo test -p wa-term` are what was measured). `scripts/fast.sh` was run in full under
  `flock -o ~/Work/missions/.suite.lock` and its verdict is in the session log.
- `scripts/test-codemode-parity.lua` and `scripts/test-codemode-boundary.lua` refuse on this build
  ("code mode is admitted for this run" / no assets); neither was judged.

## Rollback

`git revert --no-commit 4b8b6126 9d88cb79 cac58768` restores the compose-time cut of both blocks in one
step; nothing outside the ten paths above is touched, so no state, journal or fixture needs undoing.
