# change/tui-diff-view - every file change in the terminal

Victor 20/11. In the wa TUI, follow every file change as it happens, the way Claude Code's view
shows it: for each write/edit/patch, and for the files a bash command changed while it ran, a block
with the path, `+N -M`, the diff with real line numbers, removed rows on a red band and added rows on
a green one, syntax colour inside, a few context lines, `...` between hunks, and a dim footnote
saying it is a convenience view, not a review. Display only: the model's context is unchanged.

## Measurement first (the brief's premise, re-measured)

| Premise | Measured 20/11 |
| --- | --- |
| edits reach the TUI as tool events | Yes. `agent.lua` emits `{type="tool_result", name=..., result=...}`; `lua/core/chat.lua:85` redacts the result and hands it to `cli_view:event`. |
| before/after text is available | Yes, already stored. `tools.lua` write/edit call `changeset.record(ctx.changes, path, before, after)`, which puts BOTH sides in the content-addressed store (`lua/core/changeset.lua`), and the edit result carries `previous_version`/`version`. Nothing had to be captured at the tool. |
| the view showed the diff | No. `cli_view.M.preview` answers nothing for `write`/`edit`, so a change printed `written` and no lines. |
| the card renderer | `lua/core/markdown.lua` draws a fence as `U+250C U+2500`, `U+2502 `, `U+2514 U+2500`; `rust/wa-term/src/transcript.rs` (`CardWrap`, `is_card_opening`) keeps a card whole by cutting body rows by CELLS. Its opening must be exactly the corner and bar (or a fence language after it) - checked, so the path/counts line is the card's first BODY row, not its title. |
| `write` has no version digests | Confirmed: `tools.lua` returns `{ok, path, graph_index}`. The recorded change is therefore attached from `changeset.summary(self.changes)` in `agent.lua`. |
| bash-changed files | No mechanism existed. A snapshot around the command is the honest way, and git's porcelain is the rule readers already trust. |

## What was built, per commit

- `657867fb` - `lua/core/diff_view.lua` (pure renderer) and its wiring in `cli_view`: a `change`
  event draws a diff card. LCS ops carrying REAL line numbers (a removed row shows the number it had,
  and no new-column number), context rows, `...` between hunks, a fold that STATES what it hid
  (`... +N more lines: /console shows all`), the dim footnote `convenience view, not a review`, rows
  cut and padded to the exact width by `markdown.char_at`. `agent.lua` attaches the recorded change to
  the call as a separate `change` event; `chat.lua` forwards it; the model's result is untouched.
- `f9dd7e34` - `tests/diff-view.lua` wired into `scripts/test.sh` beside the view suite
  (`WA_SCRIPT=tests/diff-view.lua ... | grep "diff view ok"`).
- `7cc4e680` - `lua/core/bash_changes.lua`: a git porcelain snapshot around a non-read-only bash call, a
  diff for each file that was CLEAN before it, and a named refusal for a file whose starting text is
  not in the index. Drawn by `cli_view.M.bash_changes_block` from a `bash_changes` event.
- `c285191e` - two real bugs found by measuring: the read-only verdict was passed INVERTED, and git's
  porcelain paths are repository-ROOT relative even when the command runs in a subdirectory, so paths
  are resolved against `git rev-parse --show-toplevel`.
- `654ff0cf` - syntax colour inside a changed row, through `markdown.scan_code` (one definition of what
  a keyword is); the plain rendering stays escape-free.
- `12eedbc2` - a resize re-renders (the same change at 100 and 40 cells gives different rows, each
  fitting its width - the view re-reads its width every frame), and a REAL git answers through the
  real host in a scratch repository the test makes and removes.

## Checks, and where they run

`tests/diff-view.lua` - 35 checks - refuses to run unless `WASM_AGENT_HOME` is a scratch path. Run
through the real binary it prints `diff view ok (35 checks)`; the gate runs it at
`WA_SCRIPT=tests/diff-view.lua "$BIN" --db "$DB.view-diff" | grep "diff view ok"` (`f9dd7e34`).

NO_COLOR is the same rows with no escape: asserted directly, not inferred -
`ok(not text:find("\27%[", 1), "a plain view writes no escape sequence at all")` and the same check
on the rendered block (`654ff0cf`).

## Does the test discriminate? (mutation, not just the harness)

`scripts/test-discriminates.sh` could not answer this. On the base it reported `discriminates` for a
row whose only output was
`lua error: lua_root_unreadable: .../base/lua/core/diff_view.lua` - the base has no such module, so the
test died before any assertion. The script's `ASSERT_RE` (`lua error:` among others) is matched before
its `LOAD_RE`, so a missing file is credited as a caught defect. That is the false-pass direction, and it
is not this branch's file to change; it is named here so a later round does not read a green row as
evidence.

What was done instead: a scratch worktree at `HEAD` (`git worktree add --detach /tmp/dv-mut HEAD`, never
`git stash`), and the branch's code mutated there one change at a time, running `tests/diff-view.lua`
after each. Every mutation failed a NAMED assertion, and the restored tree was green again
(`diff view ok (35 checks)`):

| Mutation | The assertion that caught it |
| --- | --- |
| the view's `change` branch removed (`cli_view.lua`) | `the path is on the block` |
| the footnote text changed | `the footnote says what this is` |
| the fold stopped stating how much it hid | `a big diff states how many rows it hid and how to see them` |
| a removed row's old line number replaced by 0 | `a removed row carries the old line number and no new one` |
| the card opening given a title (`U+250C U+2500 main.lua`) | `the opening row is the bare card corner` |
| every hidden row silently dropped, no count | `a big diff states how many rows it hid and how to see them` |
### The same file, run two ways

| How | Result |
| --- | --- |
| through the built binary (how the gate runs it) | `diff view ok (35 checks)` |
| a bare `lua tests/diff-view.lua` (no node at all) | `diff view ok (32 checks)`, plus `SKIP real git: no host.exec in this run (the gate's binary run judges it)` |
| a bare `lua`, `NO_COLOR=1` | the same 32 checks, the same text, no escape sequence (asserted, not skimmed) |

The bare run is possible because the test uses the ONE shared host fake, `scripts/lib/contract-host.lua`,
when `host` is absent - never a stub written inside the test. That fake gained `sha256` in this branch
(`scripts/lib/contract-host.lua`), with its own comment saying what it is: a stable digest string, NOT
the real algorithm, because two tests needed a content address and a length-only stand-in made both
sides of a diff collide in this very session. It is deliberately not added to the comparison in
`scripts/test-contract-host.lua` for that reason - a fake claiming the real digest would be the
"kinder than the host" failure that file exists to prevent. The fake itself still passes its judgement
against the real host: `host contract: 52 checks ok, 11 capabilities compared`.

The real-git section is NOT skipped silently in the gate: the binary run executes it (35 vs 32 checks is
that section plus its assertions), and the skip line names why it cannot be judged in a bare run.
## What this branch does NOT do

- A file that was ALREADY modified before the command has no captured before-side, so its diff is
  refused by name (`already modified`) rather than guessed. Capturing it would mean reading every
  dirty file before every command.
- The snapshot is taken by running `git status --porcelain` before and after a non-read-only bash
  call. That is two short git calls per such command, and it is display-only work.
- `patch` as a separate tool name does not exist in this tree; `write` and `edit` are the two paths a
  change takes, and both are covered.

## Texts to approve

1. `convenience view, not a review` - the dim footnote on every diff card.
2. `... +N more lines: /console shows all` - the fold marker.
3. `no diff shown: <why>` - where a change cannot be drawn honestly (e.g. `no diff shown: not_recorded`).
4. `<path> changed (<why in words>)` - a bash-changed file whose diff is refused, e.g.
   `src/a.lua changed (already modified before command)` and `(index text unavailable)`.