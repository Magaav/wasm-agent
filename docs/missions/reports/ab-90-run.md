# The 90-run A/B (next-round.md, 19/11 ~17:30)

6 arms x 5 tasks x 3 runs, interleaved, at most 3 at once, one fresh scratch home and session per
run. Raw rows: `ab/runs.jsonl` (in the mission directory, not this tree).

Every recorded field is read from the node's own journal - `messages` for the answer and tool calls,
`harness_events` for rounds and the provider's normalized usage - never from the model's words.

## Deviations (recorded, not hidden)

1. T1/T2 carry their data as the mission's read-only SNAPSHOT (rule 13: never the live fleet),
   copied into the task directory. Task texts unchanged; one sentence at the end says where the data is.
2. A fresh scratch home has no MCP registry, so no connector is declared in any arm. The snapshot is
   the connection, identical for all six arms, so the arms are compared on how they act.
3. `cache_pct` is measured against input + cache read; dividing by input alone reported 369%.

## Arms

| arm | switch | declared tools |
|---|---|---|
| A fence | `WASM_AGENT_RAW_CODE=only` | 0 |
| B run | `=native` | 1 (`run`) |
| C codemode | `=codemode` | ordinary surface |
| D bash | `=bash` | 1 (`bash`) |
| E2 tags | `=e2` | 0 |
| E3 tags | `=e3` | 0 |

No verdict is computed here: the orchestrator builds it from the raw rows.
