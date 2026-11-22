# tui-fit - the TUI fits the window after every resize, and /nodes publishes

Worktree `/home/victor/Work/missions/tui-fit2/wt`, branch `change/tui-fit2`, base `0b9d574c`. Built
and tested on this node (avell) only. Committed locally, never pushed. Three commits, one per item:

    a5f54212  local-views: wrap a detail row to the client's line limit, so a node with 143 tools publishes
    28e8dfb5  local views: a refused panel goes to the node's log, never into the chat
    2866a05f  cli view: the welcome block is drawn again at the width the window has now

## Premises re-measured before any code (rule 9)

| the brief said | measured here |
| --- | --- |
| `nodes_cli.lua M.details` joins all capabilities on one `Tools:` line and endpoints on another | confirmed: `lua/core/nodes_cli.lua` (`table.concat(node.capabilities, ", ")`, `table.concat(shown, ", ")`) |
| `spec.rs MAX_LINE_CHARS = 400` | confirmed |
| the refusal is `line_too_long views[2].lines[3]: 3030 characters` | the same class, a different count: for a node with 143 tools named `mcp_google_imap_get_message_NNN` and three endpoints the refused line is **4724 characters** (`views[1].lines[3]` in my probe's stack), and the brief's own second message says 1018 - the number follows the tool names, not the bug |
| the previous worker was on `width_of()` counting bytes instead of cells for the banner rule | **not this tree's defect.** There is no `width_of` in `lua/`: the rule is expanded from the marker `\1r\1` by `M.expand_rules` (Lua) and `expand_rule` (Rust), both `string.rep` the rule CHARACTER to a count of cells/characters, never bytes. The real defect is measured below and is not a counting bug at all |

## Item 1 - the welcome block follows a width change (2866a05f)

### What wa owns today (measured on the base, `0b9d574c`)

- **No alternate screen.** `wa chat` draws inline, in a DECSTBM scroll region `1..bottom` reserved by
  `cli_view.METHODS:screen_on` (`lua/core/cli_view.lua`), with the input box, status line and footer
  rows below that region. Rows that scroll out of the region's top are gone; they are not scrollback.
- **With the native editor the transcript is the process's own MODEL**
  (`rust/wa-term/src/transcript.rs`): blocks of lines, re-rendered every frame at the frame's width,
  with the rule marker expanded per row (`expand_rule`). On a resize the host already clears the
  screen AND the scrollback and repaints that model (`REPAINT_CLEAR` = `2J 3J H`, then
  `layout_frame`, in `rust/wa-capabilities/src/host.rs`, behind the 150 ms debounce of the previous
  round).
- **The welcome block was inside that model - and was committed finished.** `chat.lua` writes it with
  its own local `print`, which is an alias for `view:line` (`lua/core/chat.lua:330` on the base), so
  with a raw editor the banner went through `host.transcript_write` as a block; but `M.banner` had
  already called `M.expand_rules`, so the stored row held 80 rule CHARACTERS. The host's own re-wrap
  (`wrap_rows`) then turned that row into 60 columns plus an orphan row of 20 when the window
  narrowed - the stray row under the rule - and no repaint can undo it, because the width was decided
  when the row was composed. In the plain layout (no raw editor: `WASM_AGENT_CLI_EDITOR=off`, a
  console without one) the same characters were written into the terminal once, and the terminal
  itself reflows them on a shrink.

### The fix

- `M.banner(opts)` takes `opts.marker`: with it the rule stays `M.RULE` for a renderer that knows the
  width at DRAW time; without it the rule is expanded as before (a pipe, a captured transcript, the
  existing tests).
- `cli_view.METHODS:welcome(opts)` takes the banner's own INPUTS and keeps them (`self.welcome`);
  `render_welcome` draws the block where output goes - into the host's transcript with a raw editor
  (marker intact, expanded per frame by `expand_rule`), expanded here at `self.limit` in the plain
  layout.
- `METHODS:refresh_limit` records the width it replaced (`self.width_from`) and the `FRAMED` wrapper
  acts on it ONCE: `METHODS:resized(previous)` gives the screen back, clears screen and scrollback
  (`2J 3J H`, inside a synchronized-output frame), lays the region out for the console that is there
  now, and draws the welcome block again. In the editor layout it returns immediately: the host owns
  the transcript and repaints it (`self:transcript()`).
- `METHODS:note(text)` owns the line under the banner (the reload source) the same way; `chat.lua`
  calls `view:welcome(...)` and `view:note(...)` instead of printing them.

**Cost, stated plainly:** the plain layout keeps no transcript model - it streams the bytes it is
written - so a resize clears the screen and the rows between the welcome block and the frame are not
restored. That is the same loss a DECSTBM scroll already imposes on that layout (a row scrolled out of
the region is gone), and it is written in `METHODS:resized`'s comment rather than hidden. The editor
layout, which is what `wa chat` in foot uses, loses nothing: its transcript is a model.

### Tests, and what they can and cannot see

- `scripts/test-cli-resize.lua` now drives the REAL view through the widths Victor drove
  (80 -> 200 -> 60), feeds every byte it wrote into a recorded terminal
  (`scripts/lib/recorded_terminal.lua`: a grid, a scroll region, erase/clear, and the REFLOW a resize
  performs - soft-wrapped rows are joined back into their line and wrapped at the new width), and
  asserts on the FINAL screen: no row wider than 60 cells; the rule present exactly once at exactly
  60 cells with the greeting directly under it; the banner still drawn once (the repaint puts it back
  rather than wiping it).
- The same file pins the routing for the editor layout: the block reaches `host.transcript_write`
  with the marker intact and no width measured here.
- `rust/wa-term/src/transcript.rs` gains
  `a_block_written_once_draws_its_rule_at_the_width_of_the_frame`: a block written once with the
  marker is drawn as 80, 60 and 200 rule cells at those frame widths, one rule and no other.
- On the base the Lua test fails (`welcome` is nil, line 230) and, with the recorded terminal driven
  by the base's own printed banner, the final screen holds a 20-cell orphan rule row instead of the
  60-cell rule (measured: `base: rule rows on the final screen: 1, row 24 -> 20 cells`).

### In a real terminal, both directions (tmux on a private socket, `env -i`, scratch home)

`wa chat` was started at 80x24 in a private tmux server (`-L wa-tuifit-<pid>`, so the operator's
sessions are untouched), resized to 200 and then to 60, and the screen read back with `capture-pane`:

    the TREE's binary (2866a05f), banner rule per capture:  80 -> 200 -> 60 cells
        at 60: one rule row of 60 cells, the greeting under it, widest row 60, no orphan
    the BASE's Lua (0b9d574c) in the same pty:             80 ->  80 -> 60 + 20 cells
        at 200: the rule is still 80 cells in a 200-column window (maximise leaves it short)
        at 60:  "────────────────────────────────────────────────────────────"  (60 cells)
                "────────────────────"                                        (20 cells - the stray row)

That is Victor's screenshot, row for row, and its absence on this branch - the same process, the same
terminal, the same resizes.

## Item 2 - /nodes publishes (a5f54212)

`lua/core/view_lines.lua` is the one place that knows the client's limit: a detail row is broken at
`, ` into lines of at most 400 CHARACTERS (the number `spec.rs` counts), each continuation line
carrying a two-space indent, and a single fact longer than a line is cut rather than refused.

- `lua/core/nodes_cli.lua`: the `Endpoints:` and `Tools:` rows.
- `lua/core/mcp_command.lua`: the rows that carry data - `input:`, `note:`, `carries:`, `last
  observation:`, `peers not answering:` (the others are already fitted or wrapped by `balloon`).
- `lua/core/balloon.lua` (`publish`): every page's lines are wrapped and the title (120) and the
  option label (200) are fitted, so a builder that forgets costs the reader nothing instead of
  costing them the whole panel. A builder over the limit is a TEST failure, never a refusal at run
  time.

`scripts/test-local-views.lua` publishes the reported node (143 capabilities, three endpoints)
through the REAL channel - `host.local_view`, so the Rust check runs, not a stub - and checks every
builder that can produce a long line (`/nodes`, `/mcp`, `/help`, `/keybindings`, `/login`) against the
client's own caps. On the base the same publish answers
`false, line_too_long views[1].lines[3]: 4724 characters` (measured).

## Item 3 - a cosmetic refusal goes to the log, not to the chat (28e8dfb5)

**Choice: nothing in the transcript; one line in the node log.** `lua/core/local_views.lua` reports a
view it could not publish itself (`M.report`), once per view and once per process (the record lives in
the reload store, so a swapped-in copy does not repeat it), through `host.log` - the `[lua] ...`
channel a bug is read in - with `redact.text`. `M.publish_all(view, opts)` is what the chat calls, and
it answers a COUNT: there is no problem left for a caller to print, which is what makes the red line
unreachable rather than merely unwritten. `refresh` still returns `(count, problem)` for the callers
that want it (`scripts/test-nodes-instant.lua` asserts a refusal names its view and code, and stays
green).

`scripts/test-local-views.lua` drives the refusing client: no transcript write at all, one log line
naming `/nodes` and `line_too_long`, a later round that does not repeat it, nothing raising - and it
reads `lua/core/chat.lua` to assert its publish step IS that function and that the
`view:warn(redact.text("  local views: ..."))` line is gone from it (the closure only exists inside a
live chat). On the base: `publish_all` is nil and the log stays empty (measured with only this item
reverted).

`METHODS:warn` itself is unchanged: a renderer bug that costs the reader their transcript still says
so, in red, once (`scripts/test-cli-view.lua` keeps asserting it).

## Where each test is wired

- `scripts/test-local-views.lua`: new row in `scripts/test.sh` (`WA_SCRIPT=scripts/test-local-views.lua
  ... | grep "local views ok"`), and picked up by `scripts/fast.sh`, which runs every
  `scripts/test-*.lua` not listed in `scripts/fast-path.exclude`.
- `scripts/test-cli-resize.lua`: already a row of `scripts/test.sh` and of the fast path; extended
  here.
- `rust/wa-term`: `cargo test -p wa-term` (the gate's Rust rows).

## What I ran, and what I did not

Ran here, on this node, with a scratch HOME/WASM_AGENT_HOME and `WASM_AGENT_LUA_ROOT=<worktree>`, no
rendezvous, no fleet:

- `cargo test --offline --manifest-path rust/Cargo.toml -p wa-term`: **177 passed, 0 failed** (unit),
  4 passed (`tests/live_region.rs`), 0 doc-tests.
- Lua rows: `test-cli-resize` 81 checks, `test-cli-view` 552, `test-cli-welcome` 15, `test-cli-balloon`
  75, `test-local-views` 46, `test-nodes-instant` 26, `test-nodes-cli` 12, `test-mcp-command` 132,
  `test-chat-printer` 7, `test-cli-notice` 18, `test-hotreload` 217, `test-cli-ticker` ok - all green.
- Base comparisons in a separate worktree (`/home/victor/Work/missions/tui-fit2/base`, `0b9d574c`),
  never a stash: the three failure measurements quoted above.

**Not run, and named rather than implied:**

- The whole gate (`scripts/test.sh`) and the whole fast path (`scripts/fast.sh`). The suite lock
  `/home/victor/Work/missions/.suite.lock` was held by two `wa land` runs for most of this session
  (55 min and 28 min at one point), so I ran the rows this change can reach by hand instead; the
  landing gate is where the full run belongs.
- No `scripts/test-*.mjs` row of the repository was run: the pty reproduction above is a probe I
  ran by hand against the tree's release binary and the base worktree, not a test wired into a gate.
  A gate row for it would need a release build of the tree (the existing pty rows take `WA_BIN`), and
  that is the obvious next step if the operator wants the resize watched by the gate rather than by
  this report.
- Other lines the chat sends through `view:line` ("wakes resumed", "restarted", "resuming the
  interrupted run") are ordinary transcript lines and unchanged: they contain no rule, so a narrow
  window re-wraps them into more rows rather than leaving an orphan.
- The live fleet was never called; nothing was pushed.

## Texts to approve (verbatim)

1. New, node log only (one per view, once per process):
   `local view %s was not published: %s` - e.g.
   `local view /nodes was not published: line_too_long views[2].lines[3]: 4724 characters`.
2. Removed from the transcript (it was the finding):
   `! the run view failed: local views: /nodes was not published: line_too_long ... (reported once)`.
   Kept, unchanged, for a renderer bug: `! the run view failed: <problem>`.
3. Re-flowed, same words, in a node's page: `Tools: ...`, `Endpoints: ...`, and in `/mcp` `input: ...`,
   `note: ...`, `carries: ...`, `last observation: ...`, `peers not answering: ...` - now split across
   several lines of at most 400 characters, each continuation line indented by two spaces.
4. The welcome box itself is unchanged text; the rule is simply drawn at the window's width.
