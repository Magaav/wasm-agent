# change/fence-card - a fenced code card stays whole on any width

Base: origin/main `39bbf2b6` (release 2b, includes tui-polish-3 A-H). Branch `change/fence-card`.
Every claim cites the commit that implements it.

## Premises re-measured on this base (the brief was partly stale)

| the brief said | measured on `39bbf2b6` |
| --- | --- |
| `transcript.rs:441` is the focused width | **the line moved**: on this base the focused inner width is `width.saturating_sub(2).max(1)` at `rust/wa-term/src/transcript.rs:445`, inside `rows_with_copies`; line 441 there is its doc comment |
| the card is painted by `mdCodeBlockBorder` | true, `lua/core/markdown.lua:646-676`, colour `777777` (`lua/core/cli_view.lua:85`). **But `mdQuoteBorder` is the same `777777`** - and is painted at `lua/core/cli_view.lua:86`; a colour sniff alone cannot tell a card from a quote |
| the card is re-wrapped as prose | true, but only from the SECOND row on: the first code row is shorter than the screen so it comes back whole. The break shows at 60 columns, not at 80 |

## PHASE 0 - the defect, through the real path (commit `0ab00a6f`)

`scripts/test-fence-card-pty.mjs`: a real `wa` process in a real pty (a **private** tmux server, `-L`),
a local SSE provider, the screen read back with `tmux capture-pane`. The answer holds an untagged
3-line card, a tagged 1-line card, a card inside a list item and a paragraph above them.

On the base the test fails at 60 columns, with exactly the screenshot shape - the bar was left alone
and the code went on without it:

```text
│ beta with a much longer body that must keep its bar when ┃
  the screen narrows                                       ┃     <- no bar
│ for f in a b c; do echo "one rather long line of shell   ┃
  here to push past the border"; done                      ┃     <- no bar
```

## The fix (commits `7f964622`, `7a71a779`)

The host recognises a **frame**, not a row: `CardWrap` (`rust/wa-term/src/transcript.rs`) walks a
block's lines in order, opens on the `┌` row and closes on the `└` row the renderer writes, and cuts
the `│` rows between them **by cells**, repeating the bar and a `↪` mark on every continuation, with
`RESET` at each cut and the cut colour reopened after the bar. No marker byte is added to the text.

Why the frame and not the row: a quote row and a card body row open with the **same cells**
(`│ ` painted `777777`), so a row cannot say what it is; only the frame can. That is also what keeps
the change narrow - prose and quotes wrap byte for byte as before.

The renderer also had to be reached from the right place: the opening row carries the copy icon
(`COPY_PREFIX`), so it is wrapped through `CardWrap` too - wrapped as ordinary prose, the rows under
it were never known to be a card's (that was the 60-column failure that survived the first fix).

## Tests, and where each is wired

| test | wired at | what it pins |
| --- | --- | --- |
| `scripts/test-fence-card-pty.mjs` (23 checks) | `scripts/fast.sh:739` | the real path: widths 100/80/60/90/120, a ten-column shrink, a real resize to 120, untagged/tagged/list cards. Every row **inside a card frame** keeps its bar, plus a second net on the named code lines |
| `a_card_is_cut_by_cells_and_every_continuation_keeps_its_bar` | `cargo test -p wa-term transcript::tests` (`scripts/test.sh:297`) | 120/80/60/40: no empty bar, one continuation per row, and the body rows spell the code exactly |
| `a_code_line_exactly_as_wide_as_the_card_stays_one_row` | same | `width-2` characters stay one row; one more continues - so the check can fail |
| `prose_and_quotes_wrap_exactly_as_before_a_card_bar_wears_their_same_colour` | same | a quote and a paragraph keep the prose rule byte for byte; after `└` the frame is closed |
| `a_focused_card_is_cut_two_columns_narrower_and_keeps_its_bar` | same | the focused width (width-2), through the real `rows_with_copies` |

`cargo test -p wa-term`: **167 passed, 0 failed** (166 on the base + the focused-card test).

### The tests fail without the fix

Both were run against the base, in a **separate worktree** of `39bbf2b6` (`/tmp/fc/basewt`, never
`git stash`), with only the new tests carried over:

* Rust: `a_card_is_cut_by_cells...` and `a_code_line_exactly_as_wide...` **FAILED** on the base, pass on
  HEAD. `prose_and_quotes...` passes on both - it is a parity guard, not a defect test.
* pty: on the base binary, `FAIL - at 60 columns no card code line is drawn outside its card`
  (22 ok, 1 failed); on HEAD 23 ok, 0 failed.

## No output path outside the host sees new bytes

The only callers of the wrapper are `transcript.rs` and `scroll::chat.rs` - both draw the chat inside
the host. The Lua renderer was not touched: `git diff --stat origin/main...HEAD` shows
`rust/wa-term/src/scroll/chat.rs`, `rust/wa-term/src/transcript.rs`, `scripts/test-fence-card-pty.mjs`,
`scripts/fast.sh` - **no file under `lua/`**.

Rendered output measured on both trees with the same script (`md.render` at widths 98/78/58/38, a
heading, a paragraph, a fence, a quote, a bullet and a table): **6,966 bytes on each, `diff` empty**.

## Pre-existing failures on this base (not mine)

Run in the base worktree, same command, same result:

* `lua scripts/test-markdown.lua`: `1 failed of 77` - "the links are underlined exactly, without the
  full stop or the bracket".
* `lua scripts/test-cli-view.lua`: dies at `cli_view.lua:1094` (`in field 'new'`).

## Review r1: the two MUSTs, and what they measured

**MUST 1 - a table is not a card (`03331441`).** `lua/core/markdown.lua` paints a table with the SAME
`mdCodeBlockBorder` role a card uses, so the frame check caught tables: a body row was cut by cells and
took `│↪` into its own closing bar. Measured on the renderer, a table's rules carry a column divider or
a corner the card never has (`┬ ┼ ┴ ┐ ┘ ┤`) and its body rows END in a border bar (one per column
plus the closing one). `card_edge` now refuses both. Test `a_table_is_not_a_card_and_keeps_the_prose_rule_byte_for_byte`
(**FAILS on the code without this commit**, measured) wraps every table row at 120/60/40 and requires the
prose bytes and every bar to survive; a second test proves the frame state comes back clean so the next
fence is still cut. End to end, the table rows are **byte-identical to the base binary**:

```text
base rows: ['│ cell one │ cell two │', '│ head a   │ head b   │', '└─', '├──────────┼──────────┤']
head rows: ['│ cell one │ cell two │', '│ head a   │ head b   │', '└─', '├──────────┼──────────┤']
```

**MUST 2 - an indented card (`194a13dd`).** The renderer paints the indent and the bar together
(`paint(indent .. "│ ")`), so the colour lands on an EARLIER cell than the bar and a check of the bar
cell alone missed every fence nested in a list. `border_before` looks from the row start through the bar,
and a continuation now repeats the indent (`  │↪`), so the card stays inside its list. Test
`an_indented_card_is_cut_and_its_indent_repeats_on_every_continuation` (**FAILS without this commit**,
measured) drives a real indented card at 40 columns.

## Resize: the host CUTS, it does not re-render

The brief hoped a resize would re-render cards at the new width "when the source is available". It is
not, and this change does not pretend otherwise: the host holds the rendered rows, not the markdown
source, so a resize **cuts** the existing card rows at the new width (`CardWrap`). The card keeps its
border and its code; it does not re-flow to different line breaks. Re-rendering would need the fence
source kept beside the rows - a larger change than this defect justified.

## SHOULD items (`c310b8bb`)

* **The colour is pinned, not hardcoded blindly.** There is no theme channel (Lua paints, Rust receives
  bytes), so the constant stays - but `the_card_border_colour_is_the_one_the_theme_table_names` reads the
  role's own value out of `lua/core/cli_view.lua` and fails when the two drift. Proved: pointing the
  constant at `1;2;3` makes it FAIL.
* The untagged ONE-LINE card is in the pty answer and checked.
* The no-op `.max(0)` on a `usize` is gone.
* The pty test's own frame detector now uses the same table discriminator as the host - it was reporting
  the table as a broken card, which is how the table defect was confirmed from the other side.

## Cleanup: my probe leftovers, and the calls they made

Three directories, listed before deleting: `~/.wasm-agent/tmp/fc-probe-{11qs2J,axOTUK,zhhYuN}`. They are
**deleted**; no other directory under `~/.wasm-agent/tmp` was touched (22,400 entries remain).

The live inference those two probes caused, counted from their own ledgers (no secret read):
**5 assistant messages** (2 + 2 + 1) went through the vault at `127.0.0.1:8810` between 04:36 and 04:38.
The vault log shows 23 `POST /chat/completions` in those two minutes, but that log is shared with every
other process using the vault, so **I cannot attribute the rest to myself** - the 5 is what my own
ledgers prove.

## A mistake I made, and what it cost

My first two probes started `tmux` **without** `env -i`, so the child inherited the operator's shell
environment including `WASM_AGENT_VAULT_URL`. `lua/core/provider.lua:167` lets the vault win over the
fixture URL: those two probes ran **real inference through the live vault** (`127.0.0.1:8810`) rather
than my fixture. Nothing was written to the real ledger (the ledgers went to
`~/.wasm-agent/tmp/fc-probe-*`, left in place as evidence), and the worktree was clean.

The test now makes that impossible to repeat silently: a **private** tmux socket, `env -i` plus an
explicit allow-list, a scratch root that must be outside `~/.wasm-agent` (this node's `TMPDIR` points
inside it, so the guard refuses), and a check that **the fixture itself served the run** and that the
banner names the fixture endpoint - a run that reached any other endpoint fails instead of passing.

## Texts to approve

None: this change prints no new operator-facing string. The one new visible glyph sequence is the
card continuation mark `│↪`, which `lua/core/markdown.lua:652` already used for a card line wrapped at
render width - the fix makes the host follow the same rule when the screen is narrower.
