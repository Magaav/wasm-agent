# tui-run-block - the run block: stream the script, show the output once, keep the scrollbar whole

Branch `change/tui-run-block`, cut from origin/main 975d4612. Not pushed. Three commits, one per item.

| item | state |
| --- | --- |
| 1. the script is not streamed | fixed and tested (host, Rust) |
| 2. the output is shown twice | fixed and tested (Lua, plus four lines of host) |
| 3. the scrollbar splits while a call waits | fixed and tested (host, Rust, and its Lua twin) |

Both diagnoses ended in the host, so this branch needs a new binary: a Lua-only swap carries item 2's
result row and nothing else.

## Diagnoses, with the evidence

### Item 3 - who draws the bar, and which write puts the stray cell there

The bar has ONE owner already: `Transcript::draw_bar` (rust/wa-term/src/transcript.rs:679) appends the
bar's glyph to every row of the pane after `scroll::bar::fit` (rust/wa-term/src/scroll/bar.rs:117) has
cut or padded the row to `text_width` cells. No Lua code draws a bar cell. The owner measured one row
wrong.

Bytes of the waiting frame, captured with `tmux pipe-pane` from the real binary (100 columns):

    ESC[35;1H ESC[2K ESC[38;2;232;213;138m "  <E2 8F B3> bash" ESC[0m <91 spaces> ESC[38;2;136;136;136m <E2 94 83> ESC[0m

`"  ⏳ bash"` is 8 characters; 8 + 91 = 99, so the host believes the bar lands in column 100. U+23F3 is
drawn TWO cells wide by a terminal (Unicode Emoji_Presentation, East Asian Width W - tmux and foot
agree), so the row is 100 cells and the bar's glyph is the 101st: it wraps to column 1 of the next row
(the "stub under the waiting row"), and when the waiting row is the pane's last row the wrap scrolls the
region by one line, which is why the waiting row is left without a bar and PgUp/wheel then work on a
shifted pane. The frame as read back:

      ⏳ bash
    ┃                                                                                                  ┃

The wrong number comes from `cell_width` (rust/wa-term/src/terminal_editor.rs:1193), which knew wide
characters from U+1F300 up and CJK, and counted the wide emoji below U+1F300 as one cell. The earlier
attempts moved the live row (lua/core/cli_view.lua:2654, the comment is still there); the live row was
not the writer.

Fix: `wide_emoji` in terminal_editor.rs (the Emoji_Presentation code points below U+1F300), and the same
list in lua/core/markdown.lua `cell`, which is documented as that function's twin.

### Item 1 - why the script was printed in one piece

Not (a) the view, not (b) one-run-path, not (c) the provider. The fixture sent the code argument in 24-byte
deltas 120 ms apart; a trace placed in `wa_stream_event` (lua/core/agent.lua:1008) and in
`run_code_piece` (lua/core/cli_view.lua:2336) showed every fragment arriving TWICE:

    FWD {"arguments":"{\"code\":\"const quick = a","call_id":"call_run_live_1","index":0,"name":"run","type":"tool_call_delta"}
    PIECE transcript=true const quick = a
    FWD {"arguments":"{\"code\":\"const quick = a","call_id":"call_run_live_1","index":0,"name":"run","type":"tool_call_delta"}
    PIECE transcript=true {
    FWD {"arguments":"wait tools.bash({ comman", ...}
    FWD {"arguments":"wait tools.bash({ comman", ...}
    ... (no PIECE ever again)

rust/wa-capabilities/src/host.rs:3276 emits the fragment through `serve::write_event`, which for a run
with no SSE sink (the CLI) forwards every event to the process's own Lua (serve.rs:1544); line 3287 then
handed the same fragment to Lua again through `tool_call_delta_to_lua`. That second call was added by
run-live's own commit eaa85dd8 ("argument fragments reach the RUNNING process even with an SSE sink") -
right for a served run, a duplicate for a CLI run. lua/core/run_stream.lua decoded `{"code":"...` twice,
emitted a stray `{` and stopped; the block was completed in one go by `run_code_settle_block` when the
call event arrived. This is the `const a = await{` row described at cli_view.lua:2388. one-run-path's
diff (0b9d574c^1..0b9d574c) changes two comments in cli_view.lua's streaming path, leaves
lua/core/run_stream.lua and rust/wa-capabilities untouched, and its agent.lua hunks do not touch
`install_stream_forwarder` (grep of the diff for run_stream / run_code / tool_call_delta / wa_stream_event).

Gate rows: scripts/test-run-live.lua and scripts/test-raw-view-stream.lua are in scripts/test.sh
(lines 2011, 2016), NOT in scripts/fast.sh. They would not have caught this in either place: they feed
`run_code_delta` events to the view, one layer above the duplication.

## What changed, per commit

- `d8c0446c` item 2. lua/core/codemode_block.lua: in the interactive window a settled call is one row and
  its output rides on that row as an expand marker; a FAILED call keeps its first lines visible; a text
  result is one row, `⎿ line 1 … +12 lines`, never a JSON-quoted string; in a pipe a text result is
  printed whole and a call whose output the script returned is not printed again under its row.
  lua/core/cli_view.lua `codemode_sync` hands the marker to the host. rust/wa-term/src/transcript.rs
  `rewrite` accepts a pending expand marker (unit test extended). New scripts/test-run-block-pty.mjs,
  wired into scripts/fast.sh directly after `run-live-pty` as row `run-block-pty`. The click is the
  host's existing `host.transcript_expand` / `Transcript::expand_at`; nothing new was invented.
- `1f738714` item 3. `wide_emoji` in rust/wa-term/src/terminal_editor.rs, the same list in
  lua/core/markdown.lua, unit test in rust/wa-term/src/scroll/bar.rs. scripts/test-run-live-pty.mjs: the
  SKIP is a hard assertion; its "output under the row" checks now click the row (item 2 changed that
  contract on the owner's instruction). The slow settle loop near line 318 was not touched.
- `64e687c2` item 1. `serve::write_event_forwarded` (rust/wa-capabilities/src/serve.rs) answers whether
  the event already reached the process; host.rs hands the fragment over directly only when it did not.

The one test file carries all three items' checks and was committed with item 2; it is green only at the
third commit. The commits are not individually green on that row.

## Tests run (the tree's binary: ~/wasm-agent/target/m-tui-run-block/release/wa)

- `TMPDIR=<scratch> WA_BIN=<tree binary> node scripts/test-run-block-pty.mjs` -> `run block pty: 22 ok, 0 failed, 0 skipped`
- the same test with the INSTALLED binary (a5d8c616; no Rust changed between it and 975d4612) and this
  tree's Lua -> `run block pty: 16 ok, 6 failed, 0 skipped`: partial frames `[]`, bar groups
  `[[0..32],[34]]`, waiting row without a bar, a row starting with a bar glyph, call-row click. With the
  base Lua as well, the settled frame shows the output under the call row and again as
  `⎿ "line 1\nline 2\n… +29 chars`.
- `TMPDIR=<scratch> WA_BIN=<tree binary> node scripts/test-run-live-pty.mjs` -> `run live pty: 21 ok, 0 failed, 0 skipped`
- `cargo test --release --offline -p wa-term` -> three `test result: ok` (177 + 4 + 0), 0 failed
- Lua, each with a scratch HOME and `WASM_AGENT_LUA_ROOT=$PWD`: test-codemode-blocks (66), test-cli-view
  (552), test-raw-view-stream (19), test-run-live (31), test-cli-resize (73), test-markdown (102) - all ok.

## Not verified

- No real model and no real foot window: the pty is tmux, the provider is the local fixture.
- scripts/fast.sh, scripts/test.sh and scripts/test-discriminates.sh were not run (rules).
- wa-capabilities: only `cargo test -p wa-capabilities tool_call` was run (11 passed, 347 filtered out);
  the rest of that crate's tests were not. No unit test pins "once per CLI run" - the pty test does.
- A FAILED call keeping its error lines is covered by the existing Lua tests' rows only as far as they
  go; the pty test has no failing call.
- A served (web) run: its path is unchanged by construction (a sink is present, so the direct hand-over
  still happens once), but it was not exercised.
- The markdown width list also widens `✅ ⭐ ❌ ⚡` and the like in tables Lua lays out; test-markdown
  and test-cli-view pass, other view goldens were not run.
- A result that is a managed operation object (`return await tools.bash(...)` without `.stdout`) keeps
  its existing preview rows; only text results got the one-row form.
- /tmp quota: every scratch of mine was under ~/wasm-agent/scratch; the two pty tests still default to
  os.tmpdir(), so they were run with TMPDIR pointing there.

## Texts to approve

- result row: `⎿ <first line> … +N lines` (was `… +N chars` over a quoted string).
- no other new operator-facing text.

## How Victor tests it

Needs a binary built from this branch (not a Lua swap). Then, in a new foot window:

1. `wa chat`, type: use code to run bash `for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo line $i; done; sleep 15; echo end` then tell me.
2. The script appears line by line while the model writes it.
3. While `⏳ bash` waits: one scrollbar in the last column, on the waiting row too, nothing in column 1
   of the row under it; PgUp and the wheel scroll.
4. When it settles: `✓ bash · 15.x s` on one row and, if the script returned the text,
   `⎿ line 1 … +12 lines`. Click that row -> all 13 lines; click again -> one row. Click the `✓ bash` row
   -> that call's own output; click again -> hidden.
5. `wa chat --once "<the same prompt>" | cat` prints the 13 lines once.
