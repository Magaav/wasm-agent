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
| `paused-watchdog.sh` | 31 | `orch-paused-watchdog` (loops every 5 min) | `_orch/..`/`<mission>/continue-auto.txt`, the `paused` marker removed, a HANDOVER line, and `systemd-run --unit=orch-pw-<n> ... resume-when-idle.sh` | a mission the node paused for an install and never resumed | after the swap, a 20-min-old marker with a quiet session is resumed once and the marker is gone; nothing is resumed while `requests: N waiting` |
| `throughput-watch.sh` | 26 | `orch-throughput.timer` (every 10 min) | `ATTENTION` + `HANDOVER.md` for three conditions - 0 landings in an hour with a READY branch waiting (naming the oldest and its age), READY branches with no train, no health loop - at most once an hour per alarm; `_orch/FABLE-NUDGE` for a Fable item open > 60 min; one row per run in `_orch/throughput-samples.tsv` | the train stalling quietly | after the swap, two consecutive timer runs raise nothing new, and a Fable item past an hour appears in `FABLE-NUDGE` |
| `reboot-snapshot.sh` | 25 | `orch-snapshot.timer` (every 10 min, and at every launch/landing) | `_orch/reboot-state.tsv` (mission, state, branch tip, session, detail) and `_orch/reboot-units.tsv` (active orch units + command lines), written atomically, with `_orch/reboot-snapshot.at` | a power cut with no "before" | after the swap, `list-timers orch-snapshot.timer` shows a next run and the .tsv carries a header plus every mission that has a brief and a worktree |
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
