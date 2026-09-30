# Independent review: gate lifecycle ownership

Verdict: **refused**. The three requested suites pass, but an independent
timeout/drain falsification allows a new private gate command while owned work
from the timed-out gate remains alive. The exact delivery requires repair before
acceptance. **Full merged-tree smoke and Linux coverage remain pending.**

## Binding and ownership

| Field | Value |
| --- | --- |
| Producer branch | `change/codex-gate-lifecycle` |
| Producer tip | `19bf2bdd2f434f48756a522cb2388923c3a02e5b` |
| Producer tree | `8e305e5b1428113deb1024c9cd9902ecdca0d20b` |
| Producer session | `term_2806604b-b664-48da-8aed-68b78b482bdd` |
| Independent reviewer | `codex` |
| Reviewer session | `term_3baca61f-5cd3-4e24-92d2-0a4eb0eb6f50` |
| Reviewer Codex thread | `01a0f296-0194-7cf3-ba24-f89d764b1a0b` |
| Reviewer branch | `change/review-codex-gate-lifecycle` |
| Reviewer worktree | `C:/Users/Victor/orca/workspaces/wasm-agent/codex-admission-review` |
| Base after fetch | `origin/main` = `ab827c88a6ac091318b5adb8be34e83e858c4e9a` |
| Dispatch | `task_c44569afca7b` / `ctx_b0a97f34a6c0` |
| Review date | 2026-09-30 |

I did not author this delivery. I read `AGENTS.md`, parallel-evolution,
git-orchestrator's integration protocol, and the delivery's gate-lifecycle
procedure. The old review ref `change/review-codex-admission-platform` remains at
`1d5f7ca119e0431e158f6962fa63f441655dd520`, preserving its committed artifact.
This new branch starts at current main and changes only this report. All source
tests used an archive of the exact delivery, not this branch's older code.

## Blocking finding and required repair

**`summary_exceeds_code:unresolved` — uncertain drain does not remain protected
after a timed-out shell's owner exits.** The new finish error path reports
`reservation retained pending process drain`. The new procedure says a timed-out
shell retains its reservation for reconciliation because children may survive.
That guarantee does not hold for the deeper surviving process in this fixture.

The exact archived finish runner executed a committed fake gate in a private
repository/store. A native Node preload shortened only the shell execution
timeout from 3,500,000 ms to 2,500 ms and kept the finish owner alive for nine
seconds after its result. Producer source bytes were unchanged. The fake gate
used an intermediate launcher to start a detached, idle 60-second Node process,
then remained in a shell builtin loop until the execution timeout. This was
owned scratch work, with no model, build, real test gate, or production slot.

Observed sequence in `drain-variant-evidence/drain-evidence.json`:

1. Finish owner PID **50464** obtained private acquisition **#1**, then reported
   `spawnSync C:\Program Files\Git\bin\bash.exe ETIMEDOUT`, `gate_verified:false`,
   and the retention notice. Its native Bash path and source runner hashes were
   verified independently.
2. While that owner was alive, the acquisition was `running` and a no-wait
   contender was refused with exit **75**. The separate owned process PID
   **35644**, launched by PID **49288** from shell PID **30756**, remained alive.
3. After the owner exited, read-only inspection still showed acquisition #1 as
   `running`. A new private `gate-lane.mjs run --no-wait` reconciled the old row
   to **`abandoned`**, ran its fake command, and exited **0**.
4. PID **35644** was independently confirmed alive both before and after that
   new command. The old row nevertheless said:

   > abandoned: holder pid 50464 gone, no gate pid was recorded and nothing the
   > holder started for this slot is still running, lease
   > e5f5fc73-d153-4fca-8902-d93f6ed745a0 not held; slot released after 15s

5. The safety assertion failed with exit **1**:
   `unsafe drain: a surviving descendant did not retain its reservation`.
   The probe printed `FALSIFIED: a new private command ran while timed-shell
   descendant remained alive`. Owned probe processes were then cleaned up.

The source explanation is local: acquire-mode rows record no gate PID;
`win32HolderChildren`/`survivorsOf` inspect only processes whose **direct** parent
is the holder. After the intermediate launcher and timed-out shell disappear,
that answer does not establish that deeper owned work is gone. Once the lease
is gone, `reconcileHolders` treats that incomplete observation as drain and
`tryGrant` admits another request. Keeping the acquisition during the finish
owner's lifetime is insufficient.

**Required repair:** preserve the uncertain-drain reservation across owner/lease
loss in this case, or establish that the owned descendant work has actually
drained before abandonment/grant. Add a regression that checks a contender
after owner exit while the deeper survivor is positively alive. The 3500-second
production timeout was not waited out; the preload exercises its actual error
branch with a shorter budget. This result demonstrates a liveness/safety
violation, not a throughput measurement. I made no producer repair.

## Passing evidence and limits

- Release now requires acquire mode, a live holder in the caller's ancestry,
  and the real lease. The wiring suite refuses sibling release and preserves
  the held row; the independent grant probe successfully releases acquisitions
  from their actual holder process tree.
- A bare foreign marker and a copied live sibling origin/lease refuse with
  `invalid_inheritance`. Genuine nested execution validates its source store,
  lease and live ancestor, survives the repository environment fence, and takes
  no second slot. Unreadable finish reservation stores refuse execution.
- The independent grant probe observes a wait naming its real holder, then a
  granted row with `reason:null`, `waits_for:null`, and depth zero. History keeps
  the measured wait duration; the cleared prior holder explanation itself is
  not preserved as a waiting history event.
- Independent read-only inspection changes neither request rows nor history,
  including a deliberately stale running row. `status` reconciles the same
  provably dead fixture. Inspection is not reconciliation.
- Runner receipts identify the exact source paths/hashes and Windows platform.
  Native execution selected `C:\Program Files\Git\bin\bash.exe`; the unchanged
  merge adapter additionally required Git's bin directory on PATH.
- Queue and execution budgets are distinct: default acquisition **7200 s**,
  shell execution **3500 s**, regenerated spell step **10800 s**. The independent
  timeout probe confirms queue refusal while the owner still holds its lease;
  it falsifies drain safety after that owner exits.
- The lifecycle suite's direct surviving gate after caller cancellation retains
  its slot and refuses reconciliation while that direct process lives. Its
  successful 16-check orphan suite does not cover the deeper timeout survivor
  above. None of these fixtures establishes full smoke or Linux coverage.
- **`unverifiable_claim:unresolved`:** no live gate, production store, full smoke,
  build, deployment, installed-runner convergence, Linux/macOS execution, or
  merged-tree gate receipt was tested. Only owned fixture processes were stopped.

`scripts/merge-lane.mjs` is **unchanged** in this delivery. Its existing adapter
still trusts an inherited marker, fails open on unavailable reservation wiring,
and selects `bash` through PATH. The wiring suite intentionally continues to
observe that merge version-skew behavior. The producer explicitly defers adapter
convergence until the warm owner lands; this report does not claim that repair
was included. The test file's old generic fail-open header also needs narrowing
when that convergence is documented. This is separate from the blocking drain
finding, not an invented claim that the producer promised full convergence.

## Exact commands, results and skips

Private retained root, assigned to `$lifecycleScratch` below:
`C:/Users/Victor/AppData/Local/Temp/wa-codex-gate-review-a8761494ca5f452681296ce4c823e5c9`.
Source materialization, exit 0:

```powershell
git archive --format=zip --output="$lifecycleScratch/delivery.zip" 19bf2bdd2f434f48756a522cb2388923c3a02e5b scripts skills .githooks
Expand-Archive -LiteralPath "$lifecycleScratch/delivery.zip" -DestinationPath "$lifecycleScratch/source"
```

The specified suites ran from `$lifecycleScratch/source`, with
`C:/Program Files/Git/bin` prepended to PATH, their own separate private TEMP/TMP
directories, private outer `WA_GATE_LANE_DIR` fences, private `WASM_AGENT_HOME`,
and cleared inherited markers/override. Their inner fixtures also use private
stores. Successful suite fixtures clean themselves up; their logs and exact
archived source remain retained. Node was `v24.19.0`, Git `2.55.0.windows.3`.

| Command | Observed result | Skips / scope |
| --- | --- | --- |
| `node scripts/test-parallel-finish.mjs` | Exit 0; `parallel finish checks ok (26 checks, 0 skipped)` | Private queue and stand-in gate scripts. |
| `node scripts/test-gate-lane.cjs` | Exit 0; core 30 checks plus acquire-mode orphan 16 checks | Both verdicts report 0 skipped; real OS leases/processes, fake gate commands. |
| `node scripts/test-gate-lane-wiring.cjs` | Exit 0; `gate lane wiring ok (38 checks, 0 skipped; ...)` | Private finish/merge consumers; source repository smoke never run. |
| `node "$lifecycleScratch/grant-inspect-probe.cjs"` | Exit 0; `grant/inspect checks ok (9 checks, 0 skipped; private queue only)` | Grant cleanup, actual owner release, source identity, stale read-only inspection. |
| `node "$lifecycleScratch/drain-probe.cjs"` | **Exit 1; failed safety assertion and positive falsification above** | No skip; unchanged source with explicit shortened-timeout/native-function seam. |
| `git merge-tree --write-tree origin/main 19bf2bdd2f434f48756a522cb2388923c3a02e5b` | Exit 0; `8e305e5b1428113deb1024c9cd9902ecdca0d20b` | Textual merge proof against the base named above, not gate acceptance. |

The final drain command ran with Git's bin directory prepended to PATH. It
creates a private repository, origin and lane, then invokes the exact source
runner as `node --require <private>/short-timeout-preload.cjs <archived>/finish.mjs
gate <private-repo> <private-head>`. The probe's command/state details and receipt
are retained in its evidence JSON. Repeating it requires a fresh private parent
directory containing this probe and the same archived `source` tree, because it
creates its own fixture remote and worktree.

Exploratory probe failures remain visible: two earlier harness variants timed
out waiting for read-only inspection to free a row (an unsuitable oracle), and a
third stopped parsing mixed command/JSON stdout. Those logs and script snapshots
are retained; they are not passing checks or skipped tests. The corrected final
probe asks a real private contender, records the survivor before/after, saves its
evidence before asserting, and fails on the actual safety property. The three
specified suites were not edited or repeatedly run.

### Retained SHA-256 evidence

| File relative to retained root | SHA-256 |
| --- | --- |
| `source/scripts/gate-lane.mjs` | `51408369579925fca84a526e700b9110a468a33d82c9bcd0dbc699d03f722acd` |
| `source/skills/parallel-evolution/scripts/finish.mjs` | `2f62f0725e623501a920c68e7e4f8f00f816bfc676db13613d8817e6bca3b3b7` |
| `source/skills/gate-lifecycle/SKILL.md` | `96f0d5da78c8ff989a8a61cd49e40183b74b2a76cda618aa6ecce9d047e76106` |
| `finish-suite.log` | `1cfbef351377690d557a85abcc4ba5f12502596748a20bfb548547c387ede526` |
| `lifecycle-suite.log` | `ad2a0e0146029302490aed850b4fc1cb6fb40eb86715e8a601042d6c7d7a3a69` |
| `wiring-suite.log` | `7d3f752dd1924283ac6ac7414da22ab59e56bf32fc61c26b3bcf95658419a528` |
| `grant-inspect-probe.log` | `ee769190169ed08a13f8064c87918342b6c7458ae73ed4137bba61623d8c15e9` |
| `drain-probe.cjs` | `e71e74b46d1f3f89fbd8a41171b39764414b3adaf2afabbd1f091ff7558a4264` |
| `drain-probe-evidence.log` | `dce8807eb6e8b7be92f402e0642600ec6b9242b13eaf71e60ad90d440537e040` |
| `drain-variant-evidence/drain-evidence.json` | `5f3cad1ffaf01b3a886c1931057c3e52e4dfaf781a4ba499b302567b1a1237ef` |
| `drain-variant-evidence/short-timeout-preload.cjs` | `dc4212371d057c11e7f84de7b75a85cb3cb2c3f49a9831ed278b5099d6b47a7c` |

The source hashes were checked again after the falsification and remained
unchanged. Scratch evidence is retained until publication settlement. The
blocking result was sent promptly to the parent through this dispatch's
escalation message `msg_ef6d4fc718cc`.

Only this independent report is committed/pushed, with the real reviewer
`Agent: codex session=term_3baca61f-5cd3-4e24-92d2-0a4eb0eb6f50` trailer. The
closing review-tip merge proof is reported through `worker_done` with this
dispatch's new IDs. The parent relays the exact artifact to wasm-agent `df71ee84`,
the sole publisher. No producer code, main, other checkout, production gate
state, or live runtime was changed; the blocked delivery was not accepted.
