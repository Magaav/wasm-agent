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

## Second smoke, after the tag-history and implicit-close fixes

All six measured on t4, executed steps read from the node's journal:

| arm | success | final shape | executed | rounds | calls | rc |
|---|---|---|---|---|---|---|
| A fence | 1 | 1 | 3 | 4 | 3 | 0 |
| B run | 1 | 1 | 4 | 5 | 4 | 0 |
| C codemode | 1 | 1 | 4 | 5 | 4 | 0 |
| D bash | 1 | 1 | 4 | 5 | 4 | 0 |
| E2 tags | 1 | 1 | 4 | 7 | 4 | 0 |
| E3 tags | 1 | 1 | 3 | 6 | 3 | 0 |

Two more measured fixes came out of this round:

1. The t4 criterion crashed on one model's TOP5 format (a trailing parenthesis) and took the whole
   row with it. It now reads the value beside the name, strips the punctuation, and answers a
   readable failure instead of an exception that loses the row.
2. A hyphenated product id (balanca-digital) must not be split on its hyphen, so the name is what
   remains after the trailing number is removed. My first attempt split on the separator and reported
   a real product as missing - the criterion was right and my parser was wrong, which is why the
   expected values were checked against the fixture before trusting either.

The E3 arm's known hole is visible in the smoke history: on its first attempt it wrote bare prose
before its tags and was refused by name, which is exactly the rule it was given; a second attempt
acted and finished.

## The matrix: 90 rows, complete

runs.jsonl holds 6 arms x 5 tasks x 3 runs = 90 rows, interleaved, one fresh scratch home and
session per run. Every row carries all the fields the protocol names; no row has an error, a criterion
crash or an empty session. 75 runs exited 0 and 15 exited 1 (the tag arms' named failure, below).

### One criterion was wrong and the rows were re-scored, not re-run

The T3 criterion required a ranking formatted as "1." at the start of a line. Models that ranked with
a markdown header ("## 1. ...") or bold ("**1. ...**") were scored as unranked although their answers
did rank three repositories - a defect in my checker, not in the model. It was found by reading one
stored answer, not by guessing.

The rows were re-scored from the answers already stored in each run's own memory.db, never
re-generated: success_before_regrade keeps the original score beside the new one, and regraded says
which rows moved and why. 10 T3 rows changed, all from 0 to 1, each with three distinct repository
URLs and a numbered header or a bold number. The pattern was checked against two real answers
before the re-score was trusted.

No other task's criterion reads formatting, so no other row was touched.

### Raw per-arm totals (not a verdict)

| arm | success | executed | rounds | input tok | output tok | silent | premature |
|---|---|---|---|---|---|---|---|
| A fence | 14/15 | 52 | 100 | 139994 | 58475 | 0 | 3 |
| B run | 15/15 | 67 | 126 | 297419 | 68132 | 0 | 1 |
| C codemode | 15/15 | 49 | 97 | 164244 | 52383 | 0 | 3 |
| D bash | 15/15 | 82 | 118 | 178512 | 60054 | 0 | 2 |
| E2 tags | 10/15 | 62 | 98 | 225221 | 44779 | 0 | 5 |
| E3 tags | 9/15 | 87 | 118 | 469024 | 55594 | 0 | 8 |

These are sums over the 15 runs of each arm. The verdict is the orchestrator's to build from the raw
rows; nothing here decides it.
