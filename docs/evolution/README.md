# How wa evolves - the measured log

One entry per day (`YYYY-MM-DD.md`) and one row per day in `metrics.csv`, so a later day can be compared with an earlier one
without re-deriving anything. Numbers come from the mission logs (`~/Work/missions/*/out.log` footers), the land journals
(`~/.wasm-agent/land/*/journal.json`), the A/B runs (`docs/measurements/`), and the independent reviews. Aggregates only:
no email, contact or transcript content ever enters this folder.

## What each number means
- **mission run** - one `wa chat --once` session working a brief on the build node.
- **rounds / tool calls / tokens** - the footer each run prints (`N rounds · N tools · time · ↑in ↓out · CH cache%`).
- **review rounds to land** - how many brief→review cycles a branch needed before an independent reviewer said LAND.
- **MUST findings** - review findings that block landing (fail-open, missing test, wrong claim, unsafe test).
- **land stops** - times `wa land` stopped and needed a hand step; each one should become a harness item.
- **harness items** - numbered weaknesses in docs/missions/harness-fixes (opened today / landed today).
- **mode** - how the worker acted: codemode (code inside a JSON tool call), CodeAct (run blocks), JSON tools.
- **turn themes** - what the model itself reported as "what hurt" in its `<turn>` blocks, clustered and counted.

## How to add a day
Copy the previous entry's headings, fill them from the sources above, append one row to metrics.csv. Say plainly when a
number is an estimate or a small sample.
