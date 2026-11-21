# raw-default: what the view draws, before the change

Three real turns recorded against **base 7ddbfa98** through the real agent loop with a stubbed
provider (`scripts/record-raw-view-golden.lua` writes them; it never touches a network). They are
the parity record for the branch's view change (rule 14: record the OLD path first), and they are
the evidence in `docs/missions/reports/raw-default.md`.

| file | the turn | what base draws |
|---|---|---|
| `base-block.json` | `WASM_AGENT_RAW_CODE=only`, a fenced run block whose script awaits `tools.bash` | the script's lines as a code block, `✓ bash · 95ms`, then the value |
| `base-native.json` | `WASM_AGENT_RAW_CODE=native`, the same action as a `run(code=)` tool call | `⏺ Run(code=const r = await tools.bash({command: 'printf …`, then `⎿ 0ms` - the script arrives collapsed |
| `base-op-block.json` | `only`, a script that RETURNS the whole operation object (`return await tools.bash(...)`) | one row of transport metadata: `⎿ {"cleanup":"terminated","cleanup_budget_ms":1000,…` and `… +1483 chars` |

Each file is a JSON object: `mode`, `declared` (the tool names the node declared for that turn),
`kinds` (a count of every event type the view was handed), `events` (the events themselves) and
`rendered` (the rows `scripts/replay-events.lua` draws from them - the transcript double that keeps
the host's own rules).

Regenerate (from the tree, in a scratch HOME):

```sh
WA_CAPTURE_MODE=only   WA_CAPTURE_OUT=/tmp/block.json  WA_SCRIPT=scripts/record-raw-view-golden.lua wa --db scratch.db
WA_CAPTURE_MODE=native WA_CAPTURE_OUT=/tmp/native.json WA_SCRIPT=scripts/record-raw-view-golden.lua wa --db scratch.db
```

`rendered` is what a reader saw. The `events` are what a renderer change must keep answering.
