# run-live: the native run tool's view, before and after

Four real turns recorded through the REAL agent loop with a stubbed provider
(scripts/record-raw-view-golden.lua), each in its own scratch HOME, replaying them through
scripts/replay-events.lua so `rendered` is what a reader saw. They are the parity record for
change/run-live (rule 14: record the old path first, then the new one).

| file | tree | what the reader saw |
|---|---|---|
| `before-native.json` | base 7ddbfa98 | `⏺ Run(code=return await tools.bash({command: 'seq 1 40'});)` then `⎿ 0ms` - the script arrived COLLAPSED, with no call row and no output |
| `before-block.json` | base 7ddbfa98 | the script on its code band, `✓ bash · 74ms`, then ONE row of transport metadata (`{"cleanup":"terminated",…` +1409 chars) |
| `after-native.json` | change/run-live | the script on its code band, `✓ bash · 74ms`, then the command's own output and the dim operation row - the SAME block the fenced turn draws |
| `after-block.json` | change/run-live | unchanged in shape; the operation result is the command's output with the whole object on `/console` |

The two `after` files draw the same code rows and the same call row. The `before-native` file is
the regression this change is about: it is the collapsed `Run(code=...)` presentation.

## How they were made

The eight steps, in a scratch HOME each (a run writes a node key, so one HOME cannot serve two
recordings - the guard says so):

```sh
H=$(mktemp -d); mkdir -p $H/home $H/out
WASM_AGENT_HOME=$H/home GATE_ROOT=$H TMPDIR=$H WASM_AGENT_LUA_ROOT=<tree> \
  WA_CAPTURE_STREAM=1 WA_CAPTURE_MODE=native WA_CAPTURE_OUT=$H/out/native.json \
  WA_SCRIPT=scripts/record-raw-view-golden.lua <bin> --db $H/r.db
```

`WA_CAPTURE_STREAM=1` makes the stub replay the provider's argument FRAGMENTS through
`wa_stream_event` (the same global the host calls) before it returns the assembled call, so the
"after" capture is the live path and not a description of it. `WA_CAPTURE_MODE` then selects the
transport: `native` (the `run` tool) or `only` (a fenced ```js run block).

`<tree>` is `/tmp/run-live-base` (a worktree at 7ddbfa98) for the two `before` files and this
worktree for the two `after` ones.
