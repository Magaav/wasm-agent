# The factory, in the repo

wa hosts its own factory (Victor 27/11). This directory is the live factory's home **in the product repo**, so a
change to it is reviewed, tested and landed like any other code - not edited in place on a running node.

## How it works now, and what this directory is

The scripts that run today live in `~/Work/missions/_orch/` and are started by `~/.config/systemd/user/orch-*`
units. **They are not edited from here.** A script arrives in this directory with a test, and the
**orchestrator** swaps it into `_orch` between landings, one at a time, from the list in
`ready-factory-inventory.md`. Until that swap, the copy here is the reviewed next version.

```
factory/
  test-all.sh          runs every test-*.sh in seconds (no network, no install, no real session)
  test-<name>.sh       one test per live script; each MUST be able to fail
  <name>.sh            a copy of a live _orch script, byte-identical until a change is reviewed
  MAP.md               this file: what starts what, what it writes, what it alarms on
```

## In this round

| script | lines | started by | writes | alarms on | swap check |
| --- | --- | --- | --- | --- | --- |
| `disk-watch.sh` | 8 | `orch-disk.timer` | `_orch/disk.state`, `_orch/disk.warned`, a `DISK:` line in `ATTENTION` at 70% (once an hour) | `/` at or over 70% (the node's disk_cap refuses work at 85%) | after the swap, `_orch/disk.state` keeps its clock and no `DISK:` line appears under 70% |
| `health-loop.sh` | 28 + `lib/main-binary.sh` 47 | `orch-health-loop.service` | `_orch/health-last`, `health-green`, `REVERT-PROPOSAL-<sha>.txt`, a HANDOVER line | a new red on main (after one rerun alone) | after the swap: the first loop turn prints a HANDOVER line naming the binary it graded with, and that path is under `~/.wasm-agent/releases` or `~/wasm-agent/health-target` - never `~/.local/bin` |
| `canary.sh` | 23 | `orch-canary.timer` (every minute, `orch-canary.service`) | `_orch/canary.state` + `_orch/canary.log`, and `ATTENTION` only after TWO reds in a row; skipped while `deploy-alive.json` or `orch-land-*` is active | the live install drifting outside a landing | after the swap, `systemctl --user list-timers orch-canary.timer` shows the next run and `bash factory/test-all.sh canary` is green |
| `quarantine-watch.sh` | 16 | `orch-quarantine-watch.service` | `_orch/evidence/quarantines.txt`: one five-line block per `graph_db_quarantined` line, with the deploys/missions/orch units that were running, the installed build and the load | a store quarantine (it is a recorder, not an alarm) | after the swap, the service stays active and the next quarantine gives a block with all three lists - `bash factory/test-all.sh quarantine` green against the copy |
| `daily-line.sh` | 24 | `orch-daily.timer` (08:00 local) | one `DAILY <day>:` line in `HANDOVER.md`, and a notification | never alarms; it is the daily line | after the swap, run it once with `DAY=<yesterday>` and read the line: the counts must match the day, and a row stamped 03:30Z must be counted on the LOCAL day it happened |
| `what-hurt-loop.sh` | 2 | `orch-what-hurt.service` | nothing itself; the harvester writes the run journal's feed | never - it is a loop, and the unit restarts it | the unit stays active and `harvest-what-hurt.py` keeps being called every 30 min |

Copies are byte-identical to `_orch/` except `health-loop.sh`, whose ONE change is documented in its header (main own binary, never the installed one) to `_orch/`, and both tests pass with them; each test was also proved able to
fail by mutating the script (a threshold moved from 70 to 50, the hourly rule removed, the loop's interval; and for the daily line, the day window computed in UTC instead of the local day).

## Where the runtime data stays

Outside this directory and outside the repo: `_orch/*.tsv`, `*.log`, `*.json`, `*.state`, `*.warned`,
`run-copies/`, `evidence/`, and everything under `~/.wasm-agent/`. The repo holds the programs and their tests;
the node holds its data.

## Nothing private

No tokens, no vault paths, no JIDs, no chat text, no owner email. A script that needs one of those reads it from
the node at run time (an env var or a path under `~/.wasm-agent/`), never from a copy in here.

## What is not here, and why

The dead and superseded scripts (`row-runner9..14`, `land-one.sh`, `train.sh`, `slots4.sh`, the 28 `*2.sh`
twins) are **not copied**: they have no test, nobody starts them, and copying them would import the rot. The
full list, with the counts, is in `ready-factory-inventory.md`; when a script is retired for real it moves to
`factory/attic/` with a one-line reason.
