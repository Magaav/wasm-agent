# change/harness-fixes-2 - three harness bugs, each measured

Base: `3bd47f4d` (batch 4). Branch `change/harness-fixes-2`, worktree
`/home/victor/Work/missions/harness-fixes-2/wt`. **4 commits, never pushed.**

| Commit | What it does |
| --- | --- |
| `c2e060e7` | item 1: WA_SCRIPT belongs to the host process, never to a child |
| `019f0a68` | item 2: a test process starts no REAL probe children |
| `bdadc811` | item 3, first shape: a gate check writes its log while it runs |
| `40c7b4df` | item 3, final shape, **plus a pre-existing P1 it uncovered** |

## Premises re-measured before writing code

| The brief said | Measured on this tree | Verdict |
| --- | --- | --- |
| `rust/wa-host/src/main.rs:615` reads WA_SCRIPT and runs the file | `git show 3bd47f4d:rust/wa-host/src/main.rs` line **615**: `if let Ok(script) = std::env::var("WA_SCRIPT")` | **right** |
| the variable stays in the environment for children | `rust/wa-operation/src/lib.rs:94` builds a child environment from `std::env::vars_os()` with no `env_clear` | **right, and the propagation point is named** |
| `lua/core/server.lua:2153,2157` read WA_SCRIPT | both, `if host.getenv("WA_SCRIPT") == nil then` | **right** |
| `nodes.list()` fans out real probe children | `lua/core/nodes.lua` `probe_peers` starts one `host.operation(start)` per peer | **right** |
| `test-network-roster-offline`, `test-remote-refusals` call it unstubbed | roster-offline already refused starts with its own `host.operation` stub (node-ops B); remote-refusals calls `nodes.list()` with no probe stub | **partly stale: of the two named, one was already fixed** |
| `test-federation`, `test-guest`, `test-stt-node-script` also callers | federation stubs `nodes.list` itself; guest and stt call the real one | **right for guest/stt** |
| land writes gate.log only when a check exits | `impl.gate` ran `M.exec`, then `evidence(...)` with the collected streams | **right** |
| a failed row's log dies with its scratch dir | base `scripts/fast.sh:236` `trap 'rm -rf "$work"' EXIT` (line 252 after this branch) | **right** |

**One premise was stale in a way that mattered.** The brief expected the item-2 fix to go in the fixture the rows
already load. The rows that call `nodes.list()` load no shared fixture: `scripts/fast.sh` runs each row on its own
with no common prelude. So the refusal lives in the PRODUCT (`lua/core/nodes.lua`, one place, using the
per-process fact item 1 created) and the shared fake gained the counted `host.operation`. No row was edited except
the two that test probing.

## Item 1 - WA_SCRIPT is the host process's, never a child's (`c2e060e7`)

**Measured on the base, depth-guarded** (`HF2_DEPTH` refuses above 1, `timeout -s KILL`, RLIMIT_NPROC capped at
the live thread count + 80): a script run under WA_SCRIPT started `wa status` as a child, and the child printed
`RAN script at depth 1` - it re-ran the script instead of doing its own job.

**The fix.** `main.rs` reads WA_SCRIPT once, calls `std::env::remove_var("WA_SCRIPT")` before any interpreter runs,
and records the answer in the process (`wa_capabilities::serve::set_script_run`). New host capability
`host.script_run()` (`rust/wa-capabilities/src/host.rs`, registered at `capabilities.rs:113`).
`lua/core/server.lua`'s housekeeping tick now asks `host.script_run()` instead of `host.getenv("WA_SCRIPT")`.

**The test.** `scripts/test-wa-script-child.lua` (new; `wa_fast_row_candidates` lists it and
`scripts/fast-path.exclude` does not). It crosses the process boundary twice: a child command prints
`${WA_SCRIPT-unset}` and must say `unset`; a child `wa help` must not print the row's own
`CHILD_RE_RAN_THE_SCRIPT` marker.

| Run | mine | base |
| --- | --- | --- |
| `test-wa-script-child.lua` | `wa-script-child ok (9 checks)` | **fails**: `a child of a script run inherits no WA_SCRIPT (saw: WA_SCRIPT=[scripts/test-wa-script-child.lua])` |

The row is safe on the base because the script refuses at `HF2_WA_SCRIPT_DEPTH > 1` and exits by name, so the
recursion stops at one level instead of forking.

## Item 2 - a test process starts no real probe children (`019f0a68`)

**Measured on the base**: a row calling `nodes.list()` with two peers produced `host.operation start calls: 2` -
one real `wa nodes probe` child per peer.

**The fix, in one product place.** `lua/core/nodes.lua` refuses the fan-out when `host.script_run()` is true unless
the caller asks (`nodes.list{ probe = true }` - an allow-list), and a peer it did not ask carries
`capabilities_reason = "probe_disabled_script_run"`, so *not asked* never reads like *asked, no answer*. The two
rows that DO test probing (`test-nodes-probe-parallel.lua`, `test-nodes-probe-instances.lua`) opt in explicitly.

**The shared fake.** `scripts/lib/contract-host.lua` (judged against the real host by `test-contract-host.lua`)
gained `host.operation`: it refuses to start anything and COUNTS the attempt, so zero children is a measured fact.

**The test.** `scripts/test-nodes-list-no-probe.lua` (new, in the fast path).

| Run | mine | base |
| --- | --- | --- |
| `test-nodes-list-no-probe.lua` | `nodes-list-no-probe ok (11 checks)` | **fails**: `a test process started ZERO probe children (host.operation start calls: 2)` |
| `test-nodes-probe-parallel.lua` | ok (3 peers, 3 children, by design) | - |
| `test-nodes-probe-instances.lua` | ok | - |
| `test-network-roster-offline.lua` | `network roster offline ok (24 checks)` | - |
| `test-guest.lua` | `guest ok (37 checks)` | - |
| `test-federation.lua` | `{"checks":48,"ok":true}` | - |
| `test-contract-host.lua` | `host contract: 52 checks ok, 11 capabilities compared` | - |

## Item 3 - the gate log exists while the check runs (`bdadc811`, final shape `40c7b4df`)

**The mechanism, and why it changed between the two commits.** The first shape ran each check as a supervised
operation and polled it with `host.operation("await")`. That HUNG (measured, then killed): a script run owns no
operation, the await was refused by name, and the loop spun for 150 s. The final shape needs no supervisor:
`M.exec(command, cwd, timeout, { tee = path })` wraps the check so its OWN shell appends to the log, the kernel
flushes it, and a killed check has already written every line. The closing brace goes on its own line: a check
command may legally end in a shell comment (`bash x.sh # changed`) and `; }` on the same line made `test-land`
case5b exit 2 - measured. `M.exec` answers only the bytes THAT check wrote (offset taken before it started), so
per-check test counts are unchanged and a stubbed seam still sees the exact command the gate decided on. The
evidence sink re-reads the file before every write instead of buffering it; a buffer would have deleted the
check's own lines.

**The failed row's log.** `scripts/fast.sh` copies every failed row's log into `WA_FAST_KEEP_LOGS` before the trap
deletes its scratch directory, and the gate points that at `<run>/evidence/fast-logs`.

**The test.** `scripts/test-land-gate-log.lua` (new, in the fast path) goes through the REAL gate path
(`land.impl.gate`, no stubbed runner) with a real `sh` check that prints a line, reads its own gate.log from
INSIDE the running check, then hangs until the deadline kills it.

| Run | mine | base |
| --- | --- | --- |
| `test-land-gate-log.lua` | `land-gate-log ok (8 checks)` | **fails**: `the gate tells fast.sh where to keep a failed row log (got: WA_FAST_ROWS= bash scripts/fast.sh)` |
| `test-land.lua` | `land ok (470 checks)` | - |

### A pre-existing P1 this item uncovered (fixed in `40c7b4df`)

`lua/core/land.lua` built every gate check's command with a build-record prefix containing UNQUOTED parentheses:
`echo refused(build_env_key_unknown): ...`. That is a bash syntax error, so every check exited 2 without running
and the gate read a red check. **Measured on the base**: `gate_ok=false`, `CHECK_RAN=false`, the log carries
`syntax error near unexpected token`. Introduced by `f49dd9d4` (19/11), present on the base, not caused by this
branch. After quoting the messages (same words a reader sees) the same probe answers `gate_ok=true`,
`CHECK_RAN=true`. `test-land.lua` could not see it because it stubs `land.exec` for its gate checks - which is
why the new row drives `land.impl.gate` with the real runner.

## Discrimination (rule 16)

`scripts/test-discriminates.sh 3bd47f4d --branches change/harness-fixes-2` answers `0 discriminating, 0 blocking,
7 not judged`: every Lua row is `unrevertable` - *this branch changes rust/, and the Lua rows would run against
this tree's binary, not the base's*. None of them is a pass. So I built the base binary myself
(`/tmp/hf2-base-target`, worktree `/tmp/hf2-base` at `3bd47f4d`) and ran each new/changed row against it: the
three tables above are that measurement.

## Pre-existing failure named (not mine)

| Row | Base | Mine |
| --- | --- | --- |
| `test-remote-refusals.lua` | `lua error: [string ...]:18: node refusal through the relay` | identical |

## Text to approve (verbatim, new or changed user- or model-facing strings)

1. `host.script_run` description: `Whether this process was started to run one Lua script file (WA_SCRIPT), a per-process fact no child inherits`
2. `nodes.list()` peer reason: `probe_disabled_script_run`
3. `fast: kept N failed row log(s) in <dir>` (`scripts/fast.sh`)
4. `fast: refused(keep_logs_unwritable): cannot keep failed row logs in <dir>` (`scripts/fast.sh`)
5. contract fake refusal: `operation_disabled_for_test` / `a test process starts no child process: a probe that needs one opts in explicitly (scripts/lib/contract-host.lua)`
6. gate prefix messages, quoted once more (same words): `refused(build_env_key_unknown): the build record names a setting no build reads`, `refused(build_env_incomplete): the build record names a directory that is not there`

## What I did not verify

- `scripts/fast.sh` and `scripts/test.sh` in full were NOT run (one heavy suite at a time; neither is needed to
  prove these three changes). The rows I did run, each in its own scratch home, are listed above.
- `wa land` end to end was not run; `lua/core/land.lua` was exercised through `land.impl.gate` and `test-land.lua`
  (470 checks).
- The `--core-component` path never runs the script runner, so item 1 does not touch it and I did not test it.
