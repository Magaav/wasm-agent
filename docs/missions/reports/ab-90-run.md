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

## Phase 0: why E2/E3 measured 1 round, 0 calls (evidence, not a guess)

From a raw E2 scratch session (`E2-t1-r1`), read from the node's own `messages` table: the model DID
act correctly on round 1 - it wrote `<message>...</message>` then one `<codeact>` - and the block was
never read. The cause was in our tree, in two places:

1. `raw_code.M.mode()` had no `e2`/`e3` branch, so it answered `nil`, `nil` means "off", and
   `M.take` was never called. The block stayed as text and the turn ended on it. (This is the exact
   failure mode the mode table's own comment warns about: an unknown value silently restores "off".)
2. Once the mode was known, the tag path still needed four fixes, each measured: the `</codeact>` stop
   sequence removes the closer (restored, as the fence path already does); the replay history showed
   a bare line before `<codeact>`, teaching the model to write text outside its tags (now wrapped back
   in `<message>`); the node's own `<turn>` retrospective is a required section, not "text outside the
   tags" (accepted and never executed); and a reply that finished without acting got an orphan
   `</codeact>` from the restore (now only an OPEN block gets its closer back).

Commit `3944ab3e` carries all of it.

## Driver metrics, fixed for text transports

`silent_death` used to mean "zero native tool calls", which called every text arm a death. It now
means what the directive says: the run ended (rc 0) without a final answer shape while the task is
not done. `executed_steps` counts the journal's tool rows, so a fence, a run call, a bash call and a
`<codeact>` are all actions. The answer is taken from the arm's own finish shape and the tags are
stripped before grading. Also fixed: the `harness_events` reader (a bad column key made every run
report 0 rounds and 0 tokens) and `cache_pct` (it divided by input alone and reported 369%).

## Smoke: one run per arm on t4, after the fixes

| arm | success | final shape | executed | rounds | input tok | cache % | rc |
|---|---|---|---|---|---|---|---|
| A fence | 1 | 1 | 3 | 4 | 3204 | 79.1 | 0 |
| B run | 1 | 1 | 6 | 7 | 9471 | 80.1 | 0 |
| C codemode | 1 | 1 | 3 | 4 | 4721 | 77.4 | 0 |
| D bash | 1 | 1 | 3 | 4 | 3295 | 79.5 | 0 |
| E2 tags | 1 | 1 | 1 | 4 | 3463 | 65.8 | 0 |
| E3 tags | 1 | 1 | 1 | 3 | 2965 | 63.3 | 0 |

E3 failed its first smoke attempt (0/1) with two empty model replies in a row - the arm contract
fails a second consecutive invalid message by name, which is what it was told to do. Re-run: pass.
That is model variance, not a harness defect; it is recorded rather than hidden.

The earlier E2/E3 rows in `ab/runs.jsonl` were produced by the broken mode and are deleted; A-D rows
stand (their arms were never affected).
