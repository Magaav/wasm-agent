# diff-card-reads-like-claude-code

Branch `change/diff-card-reads-like-claude-code`, base `5956ae15`. Two commits implement it:
`05d7fa72` (the card itself) and `9fcdfe1b` (the pty test and its wiring). Nothing was pushed, no
release, no fleet update, nothing on a live peer, no install into `~/.local/bin`, no `git stash`.

Victor, 23/11, with a Claude Code screenshot beside wa's: "we are quite distant from the Claude Code
diff view experience. 1. our block does not expand. 2. our block does not have a 1 line gap between it
and the next block." Re-reported at 11:05Z: unreadable first row, no blank row after the card.

## What was measured on the base, before a line changed

A real `wa chat` in a private tmux pty, a local SSE fixture playing the model, one `write` of 30 lines
(`/tmp/dcard/m.mjs`, the same shape as the new `scripts/test-diff-card-pty.mjs`):

```
⏺ Write(/tmp/wa-dcard-BAgy2m/demo.py)
⎿ written · 1.0s

┌─
│ Create(/tmp/wa-dcard-BAgy2m/demo.py)
│ Added 30 lines, removed 0 lines
│     1 + value_01 = 1
… +31 lines
done
```

and the same screen with escapes on (`tmux capture-pane -e`):

```
^[[38;2;18;48;28mM-bM-^TM-^B     1 + value_01 = 1
^[[38;2;119;119;119mM-bM-^@M-& +31 lines^[[39m
```

Three facts, all three of them Victor's two screenshots:

1. the card folded to **three rows** (`Transcript`'s topic fold), and its marker counted ROWS (31)
   under a heading that counted LINES (30);
2. the answer `done` was **glued** to the fold marker: the blank row the writer adds was popped with
   every other topic's trailing blanks;
3. the row's TEXT was `38;2;18;48;28` - `toolDiffAddedBand` painted as a **foreground**, because
   `paint()` only ever writes `38;2` codes. On the terminal's black that is a contrast of **1.47:1**
   (1.19:1 on its own `#1c1c1c` band): the unreadable row.

## The job, item by item

| # | what | where |
|---|------|-------|
| 1 | drawn OPEN, bound 40 body lines, `… +N lines (ctrl+o to expand)` in LINES above it, a press or Ctrl+O opens, Left / a second press folds | `05d7fa72`: `rust/wa-term/src/transcript.rs` (`CARD_ROWS`, `Block::cards`, `cardable`, `pin_toggle`, `expand_at`, the fold in `rows_with_copies`), `rust/wa-capabilities/src/host.rs` + `capabilities.rs` + `docs/HOST.md` (`transcript_card`), `lua/core/cli_view.lua` (`METHODS:card_mark`, one write per card) |
| 2 | one blank row above and below every card | `05d7fa72`: `transcript.rs` `rows_with_copies` (a card block keeps one blank row either side, at any width and after a resize); `lua/core/cli_view.lua` `bash_changes_block` (between two cards of one block), `card_gap`-free plain layout: the plain writer already wrote its own blank (asserted) |
| 3 | readable rows | `05d7fa72`: `lua/core/cli_view.lua` - `toolDiffAddedBand` / `toolDiffRemovedBand` are now **backgrounds** (`bg(PALETTE.…)`), never the text colour |
| 4 | `● Create(path)` / `Update` / `Delete`, bullet in the status colour, path shortened, node in the heading, one count row that says only what happened | `05d7fa72`: `lua/core/diff_view.lua` (`short_path`, `counts`, the heading row's coloured `parts`), `lua/core/cli_view.lua` (`M.place`, the remote card's node in the heading and no line after it) |
| 5 | ONE number column (new for context/added, old for removed) | `05d7fa72`: `lua/core/diff_view.lua` `rows` (`lead_cells = 2 + digits + 3`) |
| 6 | context 3, hunks separated by a dim `⋮`; word-level highlight | `05d7fa72` (`M.CONTEXT = 3`, the gap row is `⋮`); **word-level highlight NOT done** - see "Not done" |
| 7 | the footnote gone from the card | `05d7fa72`: `lua/core/diff_view.lua` (the row is removed; the sentence stays in `docs/missions/reports/tui-diff-view.md`) |
| 8 | nothing the MODEL reads changes | `05d7fa72`: no file on the model path is touched (`git diff --stat 5956ae15..HEAD`: only `cli_view`, `diff_view`, `transcript`, the display capability, docs and tests), and `scripts/test-script-writes-show-diff.lua`'s "the same bytes with a listener and without one" row passes |

## What the reader sees now (the same pty, the same fixture)

```
❯ create the demo file
⏺ Write(/tmp/wa-dcard-vxdTTv/demo.py)
⎿ written · 1.1s

┌─
│ ● Create(demo.py)
│ Added 6 lines
│  1 + value_01 = 1
│  2 + value_02 = 2
… (every line, to)
│  6 + value_06 = 6
└─

done
```

and the escapes of one added row: `^[[38;2;119;119;119m^[[48;2;18;48;28m│ 1 + ` then the code in
`38;2;78;186;101` - the band behind the row, the diff colour on it. Contrast at the default theme:

| row | foreground | background | ratio |
|-----|-----------|-----------|-------|
| added | `toolDiffAdded` `4eba65` | `toolDiffAddedBand` `12301c` | **5.83:1** (WCAG AA needs 4.5) |
| removed | `toolDiffRemoved` `ff6b80` | `toolDiffRemovedBand` `3a1620` | **5.83:1** |
| the base's added row | `12301c` as a FOREGROUND | the terminal's own | 1.47:1 |

The palette roles used by a card, and nothing else: `mdCodeBlockBorder` (the frame, `777777`),
`mdCodeBlock` (the heading's name, `d4d4d4`), `success` (the bullet, `4eba65`) / `error` (a Delete's
bullet, `ff6b80`), `dim` (the count row, the `⋮`, the counting row), `toolDiffAdded` /
`toolDiffRemoved` / `toolDiffContext` (the code) and the two `…Band` roles (the row behind it).
Residual, named rather than hidden: a `#` comment on an added row is `syntaxComment 6a9955` on the
added band = **4.30:1**, just under AA. It is the syntax role, not the row, and it is not changed here.

## How it is held

* `tests/diff-view.lua` - 70 checks under a bare `lua`, 73 through the binary: the heading and its
  bullet, the one number column, the count row that never says `removed 0`, no footnote, one blank row
  after the card, `⋮` between hunks, the whole diff rendered, the host's ceiling row, `short_path`,
  the node in a remote heading, and the band's contrast (a ratio computed from the palette, not a
  string match).
* `scripts/test-script-writes-show-diff.lua` - 37 checks: the three cards a script's writes draw, the
  peer card with its node in the heading, and the model's bytes unchanged.
* `rust/wa-term` - five new tests: `a_card_is_drawn_open_not_folded_to_three_rows`,
  `a_card_past_the_bound_counts_the_lines_it_hid_and_a_press_opens_it`,
  `ctrl_o_opens_the_newest_card_and_the_same_key_folds_it`,
  `a_card_keeps_one_blank_row_above_and_below_it`,
  `a_card_is_cut_at_the_width_it_is_drawn_at_and_keeps_its_gap` (202 lib tests, all green).
* `scripts/test-diff-card-pty.mjs` - **23 checks through the REAL binary in a private tmux pty**, and
  wired into the fast path next to `fence-card-pty`: create open with all 10 lines, the blank row above
  and below, the one number column, the update's `Added 1 line, removed 1 line`, the 60-line card
  stopping at 40 with `… +20 lines (ctrl+o to expand)`, Ctrl+O drawing the hidden line, the Delete card
  and its gap, the same rows inside a 72-column screen after a resize, and `--continue`.

## Not done, and what is unknown

* **Word-level highlight inside a changed pair of lines** (item 6's second half) is NOT implemented.
  Candidate, as the brief allows: `M.hunks` already returns the paired ops, so a `-`/`+` pair could
  take a `span` per row and `cli_view` a stronger band for it; it is a small change but it touches the
  band painting item 3 just fixed, and item 3 is what Victor sees first.
* **`--continue` draws no card at all** (MEASURED, and asserted in the pty test): a resumed session
  replays its ledger as turn rows (`⏺ Write` / `⎿ written`), because a card is built from the live
  change event and nothing stores it. So "the same rules in --continue" cannot hold today for any
  card; the block-level rules are covered by the Rust tests, which take the same path a replay would.
* **A Delete card needs the removal in the same RUN as the write** (MEASURED): Victor's "then delete
  it" is a second turn, and `lua/core/agent.lua` starts a fresh `self.changes = changeset.new()` per
  message - so `announce_gone` has no recorded path to prove the removal from and draws nothing. This
  is pre-existing, outside items 1-8, and it is why the pty test asks for the write and the removal in
  one turn. Worth its own mission.
* **A press is covered by a Rust test, not by a mouse event through tmux**: `tmux send-keys` cannot
  deliver a click at a cell, so the pty test proves Ctrl+O on the real screen and the press at the
  transcript's seam (`expand_at`).
* **The counting row does not brighten under the pointer** (`expand_hover` covers `expands` rows only).
  A press works, the affordance does not light up. Small, not done.
* The card is still drawn by the pure renderer and painted by `cli_view`: `diff_view.rows` reads no
  host; `M.place()` is the only place the two directories come from (`WA_HOME_BEFORE_OVERRIDE` /
  `HOME` for the operator's own home, `platform.cwd()` for the workdir).

## Texts to approve (verbatim, operator- and reader-facing)

1. `● Create(<path>)`, `● Update(<path>)`, `● Delete(<path>)` - the bullet glyph `U+25CF`, the path
   shortened (`demo.py` inside the workdir, `~/x` inside home, absolute otherwise) and a remote change
   as `Create(nextcloud:/tmp/x.py)`.
2. `Added 26 lines` / `Removed 3 lines` / `Added 4 lines, removed 2 lines` / `Added 1 line` (singular)
   / `No lines changed` (a write with no line change).
3. `⋮` (U+22EE) as the row between two hunks.
4. `… +20 lines (ctrl+o to expand)` - the card's counting row, N = LINES.
5. `… +N lines: /console shows all` - only past the host's own 19 960-line ceiling.
6. Removed from the card: `convenience view, not a review`.
7. New capability name and description (the sandbox `capabilities()` list and `wa --json`):
   `transcript_card` - "Mark the diff body of a card in the next transcript write: drawn open up to the
   card bound, the rest counted on one row, Ctrl+O or a click draws it all".

## Proposed FACTORY.md text (propose only, not written)

> A change card is OPEN. A file change drawn in the transcript shows its whole diff up to 40 body
> lines; past that, ONE row - `… +N lines (ctrl+o to expand)`, N in lines - and a press on it or
> Ctrl+O on the newest card draws the rest, while Left or a second press folds it back. A card is
> framed by one blank row above and one below, at any width and after a resize or a replay, and its
> changed rows keep a band BEHIND the text (never the band colour as a foreground: 5.83:1 at the
> default theme). The heading is `● Create(path)` / `Update` / `Delete` with the path shortened to the
> workdir or `~`, a remote change names its node in the heading, and one count row says only what
> happened. The card is display only: tool results and the model's context are byte-identical.

## Proposed HANDOVER.md text (propose only, not written)

> Diff cards (`lua/core/diff_view.lua`, `lua/core/cli_view.lua`, `rust/wa-term/src/transcript.rs`):
> `host.transcript_card([{from,to}])` marks a card's diff body in the next write (one write per card,
> 0-based offsets - a per-row write drops the marker, measured 23/11); the host keeps the frame, the
> heading and the counts, folds the body to `CARD_ROWS` (40) with one counting row, and answers a press
> or Ctrl+O. Two open ends: `--continue` draws no card (a card is built from the live event), and a
> Delete card needs the removal in the run that wrote the file.
