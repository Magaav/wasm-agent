# `wa events`: the ledger, and the wake that reads it

Every fact about a branch's life is ONE ROW with ONE schema, written by the thing that did it, in the node's
own database: a worker that finished, a preflight that went green or red, a landing that merged, pushed,
installed and verified the install, main's health after it. Reading them is a command; subscribing to them is
the wake that already existed.

```bash
wa events                                   # the last 20 rows
wa events --kind land,mission --limit 50    # one kind, or both
wa events --step main-health --json         # one step, one JSON object per line (a script reads this)
wa events --follow --kind land              # follow: new rows as they land, until you stop it
wa events --follow --kind land --backlog 20 # ...starting with the 20 before you opened it
wa events record --kind mission --step finished --result ready --branch change/x --sha <sha>
```

Code: `lua/core/event_ledger.lua`. The table is `ledger_events`; the producers are `lua/core/land.lua` (one
row per landing step), `lua/core/mission.lua` (`wa mission preflight`) and `wa land ready` (a worker that
finished). Tests: `scripts/test-event-ledger.lua` (the schema, the refusals, the cursor, the wake matching
`land.*` and `land.installed` differently, the CLI, and a follower running as a process of its own) and
`scripts/test-land-quick.lua` (a whole landing's rows).

## The one schema

| field | what it is |
| --- | --- |
| `id` | the cursor. `--since <id>` is exact: a follower never re-prints a row and never skips one |
| `kind` | `land` or `mission` - an allow-list, so a subscriber filters on a closed set and a typo is refused by name |
| `mission` | the mission's name (the branch without its `change/` prefix) |
| `branch` | the branch the row is about |
| `sha` | the commit the row is about - whatever the producer proved, and nothing it did not |
| `step` | the step inside the kind: see the table below |
| `result` | the verdict: `green`, `red`, `skipped`, `started`, `refused`, `ready`... |
| `at` | epoch seconds, when the producer wrote it |
| `detail` | one sentence a person reads; never a claim about a step that did not run |
| `source` | who wrote it (`wa land <run>`, `wa mission preflight`, a script that names itself) |

A refusal writes nothing: an unknown kind, an empty verdict and a step that is not a slug are refused by
name, because a fact log with a hole in it reads as "nothing happened".

## The steps a landing writes

| step | when | result |
| --- | --- | --- |
| `started` | the round begins | `started` |
| `collected`, `planned` | the branches are resolved, the plan is made | `green` / a skip |
| `merged` | the merge commit (with the regenerated files) | `green` or `red` |
| `tests` | the branch's own added or changed `scripts/test-*.lua` | `green`, `red`, or `skipped` with the reason (a Rust branch) |
| `gate` | only with `--gate` | `green` / `red` |
| `pushed`, `main` | the incoming push and main's fast-forward, each read back | `green` / `red` |
| `installed` | `installed.txt` names the landed commit | `green` / `red` |
| `install-verified` | the installed `lua/core` equals the landed tree's | `green` |
| `install-failed` | the record names another commit, or the Lua differs | `red` |
| `main-health` | the health measurement's own verdict (`wa land health-run`) | `green`, `red`, `refused` |
| `refused` | the landing was refused before merging (a red main, FACTORY.md rule 8) | `red` |
| `reported`, `done` | the report, and the round's last line | `green` |
| `stopped` | the round stopped at a step | `red` |

The `mission` kind carries `finished` (`wa land ready`) and `preflight` (`wa mission preflight`).

## Subscribing without polling

Every row is published on the bus as the topic `<kind>.<step>`, which is the wake table the node already
has (docs/SELF-LOOP.md). A session asks once:

```
wake {reason = "the landing is installed", on = ["land.*"]}          every landing fact
wake {reason = "the install is done", on = ["land.install-verified"]} one of them
wake {reason = "the worker finished", on = ["mission.finished"]}      a branch is ready
```

A wake stores the topic and the event's identity, never the row's text, and no publish happens when nothing
is subscribed (one indexed read decides). Nothing here is a new wake mechanism: this is a producer for the
one that exists.

## What it is not

- Not the landing's journal. `wa land status` shows the state machine of ONE run (what still has to happen);
the ledger is the fact log of every run (what did happen). A step writes the journal first and the row after
it settled, so a row is never a plan.
- Not a claim. A row is written after the step's own check answered - `installed` means `installed.txt` named
the commit, not that a command exited 0 - and a step that could not be verified writes `red` or `refused`.
