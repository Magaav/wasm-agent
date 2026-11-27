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
| `what-hurt-loop.sh` | 2 | `orch-what-hurt.service` | nothing itself; the harvester writes the run journal's feed | never - it is a loop, and the unit restarts it | the unit stays active and `harvest-what-hurt.py` keeps being called every 30 min |

Both copies are byte-identical to `_orch/`, and both tests pass with them; each test was also proved able to
fail by mutating the script (a threshold moved from 70 to 50, the hourly rule removed, the loop's interval).

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
