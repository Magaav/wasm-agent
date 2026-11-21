# run-live: draw the run tool's JS live, as the model writes it

Victor, 21/11: *"i want our wa agent (run code) to draw the JS as it used to do in raw code
channel, so we can see it in real time writing js, that was a nice experience. once we moved to
run(code=...) we encapsulated it and collapsed it ... as we only have one way of executing, we do not
need Run(code=...), just output the code written, the promises waiting for coming back, the way to
explore result just like we had."*

Branch `change/run-live`, base `7ddbfa98`, worktree `/home/victor/Work/missions/run-live/wt`.
Committed locally; never pushed.

## The transport did not change

The native `run` tool call is still the one way of executing. No provider was moved to the fenced
channel. What changed is what the operator SEES.

## Premises re-measured before writing code

| brief says | measured | verdict |
|---|---|---|
| `http_stream` assembles `delta.tool_calls[].function.arguments` silently | `rust/wa-capabilities/src/host.rs` `ToolCallAssembly::absorb` fed the assembly and the bounded `decision` preview; the argument bytes reached no consumer | **partly stale**: a provisional `decision` event already existed, but its preview is capped at `DECISION_PREVIEW_CHARS = 256` and cannot carry a script |
| the old block rendering lives in `cli_view.lua` and can be reused | `METHODS:code_stream` (from `cce58429`) plus `lua/core/codemode_block.lua` `M.rows` / `M.call_lines` | correct; reused, no second renderer |
| each awaited `tools.X(...)` needs a waiting row | `lua/core/codemode.lua` already emits `codemode_call` `{state="running"}` and settles it; `cli_view.lua` draws it | already true - the native turn never reached it, because the call was not routed through the block |
| the calm-mode closed-input rendering | n/a | not touched |

The one premise that mattered: a native turn reached the view only as a finished `tool` event, so the
block that already existed was never opened for it.

## What was built, item by item

1. **Host - the fragments reach the reader** (`c2569cc4`, hardened by `eaa85dd8` and `c65226ed`):
   `http_stream` emits `{type:"tool_call_delta", index, call_id, name, arguments}` for every argument
   fragment, beside the `decision` preview (never instead of it), and hands the same fact to the
   running process through the `wa_stream_event` global the CLI already installs. Evidence: a REAL
   opencode-go / `deepseek-v4.1-flash` stream recorded on this node 21/11 through the vault route,
   `tests/fixtures/provider/opencode-go-run-code-recorded.sse` (+ README): **14 argument frames**, the
   script split mid-string. Two host tests pin it, one of them byte for byte against that capture.
2. **Agent - the `code` argument decoded as it grows** (`5bfe4ea1`): `lua/core/run_stream.lua` is an
   incremental scanner for the argument JSON (split escapes, `\uXXXX` across chunks, surrogate pairs
   across chunks, the `code` key found after another key). `lua/core/agent.lua` emits `run_code_delta`
   with the decoded text. A call whose tool NAME is still a prefix of `run` (`r` then `un`) holds its
   fragments and decodes them when the name lands, so no byte is lost to chunk timing.
3. **Views**: the TUI (`5bfe4ea1`) draws those deltas with the block the fenced channel already uses
   (`run_code_piece`, whole lines, the last line flushed when the call announces itself) and routes a
   native `run` call through `codemode_start`/`codemode_settle`; the window (`a0a8fb1d`) gained a
   `wa-run-code` element per call, fed by `run_code_delta`, completed from the assembled arguments.
   Two rows a fenced block never had are gone: the `Run(code=...)` heading and the native call's own
   `codemode_call` row (`ce788d08`).
4. **Parity**: `fixtures/run-live/` holds four real turns recorded through the real agent loop with a
   stubbed provider - `before-native` / `before-block` (base `7ddbfa98`, from a scratch worktree) and
   `after-native` / `after-block` (this branch) - with a README that records every step. See the
   parity table below.
5. **Tests**: `scripts/test-run-live.lua` (24 checks) and `scripts/test-run-code-ui.mjs` (14 checks),
   both wired into `scripts/test.sh` (the run-level rows, beside `test-raw-view-stream.lua`), both with
   their own scratch HOME and the home guard, both discriminating (below).

## Parity: what the reader saw, before and after

| capture | tree | rows |
|---|---|---|
| `before-native` | base | `⏺ Run(code=return await tools.bash({command: 'seq 1 40'});)` + `⎿ 0ms` - collapsed, no call row, no output |
| `before-block` | base | script on its band, `✓ bash · 74ms`, then ONE row of transport metadata (`{"cleanup":"terminated",…` +1409 chars) |
| `after-native` | branch | script on its band, `✓ bash · 76ms`, the command's own output, the dim operation row |
| `after-block` | branch | same code rows, same call row, same output |

`after-native` and `after-block` draw the SAME code rows and the SAME call row; the test asserts that
on the committed files.

## Tests and how they discriminate

The two rows `test-discriminates.sh` could not judge are named **unrevertable** by it, because this
branch also changes `rust/` and the Lua rows would run against this tree's binary. Judged by hand
instead, with a base binary at `7ddbfa98`:

| test | on the base code | verdict |
|---|---|---|
| `scripts/test-run-live.lua` | **6 checks fail** (script not drawn, no waiting row, no flip, native block != fenced block) once `lua/core/run_stream.lua` and the fixtures are placed on the base tree; without them it dies on `lua_root_unreadable` | discriminates |
| `scripts/test-run-code-ui.mjs` | `AssertionError: app.js still has "// A native run tool call draws its SCRIPT"` | discriminates (named by the tool itself) |

`scripts/test-raw-view-stream.lua` (picked from `raw-default`) passes `19/19` on this branch; it is a
picked test, not a new one.

## Cherry-picks, and whether they are transport-independent

Taken from `~/Work/missions/raw-default/wt`:

- `ff7612d6` **taken** (`7367b0b9`): `codemode_block.lua` draws a managed operation as the command's
  output with the whole object on `/console`. Pure view code (`codemode_block.lua` + a recorder + a
  test), no transport knowledge - true for a fenced block and a native `run` call alike.
- `c49aef74` **taken** (`e89010d8`): the same preview reads the JSON STRING a script really returns.
  Also pure view code, and it was needed: the real turn hands the view the operation as a string.

Both touch only `lua/core/codemode_block.lua` and tests; neither knows which transport produced the
script.

## Texts to approve (model- or operator-facing, verbatim)

1. **Removed** from the native turn: `⏺ Run(code=<first line of the script>…)` and its `⎿ 0ms` row.
2. **Removed** from the native turn: the `✓ run · <N>ms` row that the call's own `codemode_call`
   produced (the script block is that call).
3. **Added** to the native turn's status row (same string the fenced channel already used):
   `Running your script`.
4. **Unchanged**, now reached by the native turn too: `  ✓ bash · 74ms`, `  ✗ <tool> · <error code>`,
   `  ⎿ <the script's value>`, `  operation <id> · completed · exit <N> · <N>ms · the whole result is in
   /console`.
5. **Wire-level, never displayed**: `tool_call_delta` (host -> Lua) and `run_code_delta` (Lua -> view).

No new sentence was added to the transcript, and no existing string changed wording.

## What I did not do / could not verify

- **A live run against the real provider was not driven end to end through the agent loop.** The
  provider was asked once, by hand, with `curl` through the vault (that is the fixture), and the two
  loops were driven with the stubbed provider the golden recorder uses. A real conversational turn on
  this branch is the remaining measurement.
- **The window was not driven in a browser.** `scripts/test-run-code-ui.mjs` runs the real functions
  from `ui/app.js` in a page scope; it does not prove the CSS of `pre.run-code-script` reads well.
  `ui/style.css` gained ONE rule for `wa-run-code pre.run-code-script` (the band: no wrap, a left
  border, the mono font already used elsewhere) - whether it reads well at a narrow width is still a
  human look.
- **`scripts/test.sh` as a whole was not run** (one heavy suite at a time; the earlier full-gate rows
  on this node are known-flaky for reasons unrelated to this change). The rows I added were run
  directly, and the two view suites plus the host tests are green (24/24, 14/14, 19/19).

## An honest note on one of my own mistakes

My first cut routed `tool_call_delta` to the running process ONLY (`write_event_if_no_stream`), to
avoid a second event on the wire. The host tests I had written caught it (2 of 14 red): the two events
are not duplicates - the wire carries the raw fragment, the process carries the decoded script - and
that helper deleted a fact from the run's record. `c65226ed` restores both and removes the helper.
