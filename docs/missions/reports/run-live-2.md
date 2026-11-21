# run-live-2: the run block's CONTENT (and the script that was only one row)

Victor, 21/11 15:00: *"noticed that the content of run code is not printed"* - `bash x2` and a
four-kilobyte JSON blob where `1 2 3` and the kernel version belonged - and at 15:05: the block showed
only its first line while a call waited, and the scrollbar split in two.

Branch `change/run-live-2`, base `eae9a3a9`, worktree `/home/victor/Work/missions/run-live-2/wt`.
Committed locally, never pushed.

## Premises re-measured

| the brief says | measured | verdict |
|---|---|---|
| the gate never ran `scripts/test-run-live.lua` / `test-raw-view-stream.lua` ("not a gate row") | land244's evidence `gate.log` line 2: **120 rows of the merged tree**, both names in it, and `fast: lua 121/121 passed`; the "not a gate row" lines are the *plan* text, computed in the operator's checkout before the merge, and `M.gate_rows_file` re-added both rows for the merged tree | **stale**: the gate DID run them. What is true is that the plan's line is misleading, and that the branch's own `scripts/test-run-live-pty.mjs` was not in any ledger - fixed here |
| `WASM_AGENT_LUA_ROOT` puts a checkout's Lua under test | `lua/core/reload.lua` `node_text` read `EMBEDDED` FIRST and the root only when a module was not compiled in - every UI module is. `wa chat` therefore drew the BINARY's view while `WA_SCRIPT=` rows drew the tree's: an hour of measuring the wrong copy | **wrong**, fixed (below) |
| the script streams into the block through `run_code_delta` | true, but the fragments reached `lua/core/agent.lua` **twice per frame** (the host's wire event and its Lua event both forwarding), so the decoder produced `const a = await{` and stopped - which is the one row Victor photographed | **confirmed by measurement**, host-side, not fixed here |

## What was built, item by item

1. **Each call's own content** (`2f9e6a74`): `lua/core/codemode_block.lua` gained `M.output_of` (an
   allow-list: a table carrying `stdout`/`stderr` as a STRING), `M.call_content` (stdout, then stderr,
   at most `M.CALL_CONTENT_ROWS = 4` rows with `… +N lines`, four columns in), and `M.call_entries`,
   which both renderers read - a call's row and the content under it. `lua/core/codemode.lua`
   `live_settled` hands the view the two output strings (only those: ids, paths, owner, timing stay
   behind), and `lua/core/cli_view.lua` passes them to `codemode_block.settle`. A fan-out whose calls
   have content is one row per call, each with its own output; one whose calls have none keeps the
   counter row (`scripts/test-codemode-blocks.lua` still asserts the ten-call case is ONE row).
2. **The value, compactly** (`2f9e6a74`): `M.decoded` (the JSON string a value crosses the boundary
   as), `M.readable` (every operation envelope inside it replaced by its own output), `M.pretty`
   (JSON, one member per row) and `M.RESULT_ROWS = 8` with `… +N lines (/console shows all)`; the
   click (`rows.expand`) and `/console` carry the WHOLE object (`M.raw_rows`), which is what
   `scripts/test-raw-view-stream.lua` already asserted byte for byte.
3. **The whole script while a call waits** (`b19961c9`): `cli_view:run_code_settle_block`. The call
   event carries the arguments whole, so when it arrives the block's rows are REWRITTEN in place to
   exactly the script's rows and the missing ones appended - the mechanism a settling block already
   uses. Measured in a real pty: four script rows above `⏳ bash`, where there was one truncated row.
4. **A checkout's UI modules come from the checkout** (`85d811fe`): `reload.node_text` now reads
   `WASM_AGENT_LUA_ROOT` first, which is the boot's own rule; a file the root does not carry falls
   through to `dofile`, which reports `lua_root_unreadable` rather than silently using the binary.
5. **The test the gate was missing** (`b19961c9`, wired `f70d6767`): `scripts/test-run-live-pty.mjs`
   drives the REAL binary twice against a local SSE fixture - `wa chat --once "…"` and the
   interactive window in a private tmux pty - and reads the rows back. 19 checks, and it is a row of
   `scripts/fast.sh` (`check run-live-pty`) beside `fence-card-pty`.
6. **Tests of the view itself** (`d2bc0655`): `scripts/test-codemode-blocks.lua` +21 checks (content
   under a row, the fold, a fan-out with content, the value read as output, the cap and the fold) and
   `scripts/test-run-live.lua` +7 (the whole turn: script, two call rows with `1 2 3` and the kernel,
   no envelope field, a block under 30 rows). Both are rows of `scripts/test.sh` (lines 1997, 2002)
   and of the fast path.

## What the operator sees now (measured, not claimed)

`--once`, from the pty test's own capture:

    const a = await tools.bash({ command: 'seq 1 3' });
    const b = await tools.bash({ command: 'uname -r' });
    return { seq: a, uname: b };
      ✓ bash · 98ms
        1
        2
        3
      ✓ bash · 103ms
        7.2.15-1-omarchy
    ⎿ {"seq":"1\n2\n3","uname":"7.2.15-1-omarchy"}

and the same block in the interactive window while the third call still waits.

## Open, by name

- **The scrollbar still splits while a call waits** (item 7). The bar is one contiguous run of rows
  except ONE: the row the block has just written loses its last column and a stub of the bar appears
  on the blank row under it (captured: `[[0..32], [34]]`). The test measures it and prints
  `SKIP test-run-live-pty: the scrollbar splits while a call waits (2 bar groups)` - a skip, never a
  pass. Taking the live row down before the block grows (`cli_view:codemode_sync`) did not remove it;
  the writer is in the host's row/live-row bookkeeping (`rust/wa-term/src/transcript.rs`), where the
  position of a live row is not moved when the block above it gains a row.
- **The argument fragments reach the agent twice per provider frame**, which is why the streamed
  script was a fragment of itself. The view now repairs the block from the authoritative arguments,
  so what the reader sees is right, but the transport double-delivery is not fixed here (it is on the
  model's path and the brief keeps this mission to the view).
- The window (`ui/`) was NOT changed: item 1's "web UI" is untouched, and I say so rather than imply
  it.

## Texts to approve (model- or operator-facing, verbatim)

1. `  ✓ bash · 98ms` - unchanged wording; the rows UNDER it are new (`1`, `2`, `3`).
2. `    … +N lines` - a call that printed more than four lines (new string).
3. `    … no output` - an operation inside a value that printed nothing (new string).
4. `⎿ {"seq":"1\n2\n3","uname":"7.2.15-1-omarchy"}` - the value, pretty and capped at 8 rows; the
   rest is `  … +N lines (/console shows all)` (existing string, new cap).
5. `  … +N lines (/console shows all)` - unchanged.

Nothing model-facing changed: `scripts/test-codemode-blocks.lua`'s "the model-facing result is the
same bytes with a view listening" still passes, and the settle event it compares only gained a
`output` field the model never sees.
