# STATUS: repair of D1's pre-lease grace (branch `change/wa-session-childdispatch054d4d9b-...`)

Started from the delivery tip `c78ab73130b13c0da967b5ce7ce7d1f96d3f0301` ("factory(temp): bound the
clone and the gate home a failing run keeps"), base `origin/main` = `da8dc8918a34c880768956ff775d883802dcb7a7`.
The first commit of this branch (`380181d`) is this file BEFORE the fix, on purpose: this lane's
predecessors died at the 7200 s window and left nothing behind. This is the final state of it.

## What is fixed

D1 of the independent review (`change/wa-session-childdispatchdb0ce06c-...`, tip `ab555f93`,
`verify/REVIEW-disk-temp.md`), not re-litigated here. The false sentence, in `scripts/merge-lane.mjs`'s
BOUNDED RETENTION comment:

> A pre-lease name is pruned only once it is an hour old, so a rollout cannot delete the clone of a run
> the previous script started.

It was false because the flat hour is SHORTER THAN THE GATE LANE'S OWN WAIT BUDGET
(`WA_GATE_LANE_WAIT_SECONDS`, 7200 s by default) and the clone is made at the top of the run, BEFORE
the slot is waited for - so a run merely queued for the gate had an aged-out clone.

The rule now, in `scripts/merge-lane.mjs` only (one defect, one rule):

* the pre-lease grace is **DERIVED, not chosen**: gate lane wait (7200 s) + this lane's gate timeout
  (`--timeout-seconds`, 3600 s) + 60 s slack = **10860 s (3 h 1 min)**, with each term the budget of a
  run that is still alive while it holds the clone. `legacyGraceMs()` makes the arithmetic executable
  and it follows `WA_GATE_LANE_WAIT_SECONDS` and the run's own timeout. The flat hour was 7260 s short
  of the wait alone.
* **evidence before deletion, for every candidate**: before `rm -rf`, the sweep renames the directory
  within its parent (`holderProbe`). A refused rename is proof that something is using the directory
  and it is kept whatever its age and whoever minted it; an allowed rename is what lets it go. Measured
  on this machine: refused with EBUSY when a native process's working directory is the clone or below
  it (how this lane spawns its own gate), with EPERM when a native process holds an open file inside it
  - and `rm -rf` succeeds in some of those states, so nothing else would have stopped the deletion.
* `scripts/test.sh`'s gate-home block: the sweep logic is UNCHANGED and its hour kept, but its comment
  no longer claims rollout safety. No queue arithmetic applies there (the home is made when the gate
  starts, i.e. after the slot), the hour equals the lane's own gate timeout, so a hand-run gate or a
  lane started with a larger `--timeout-seconds` can be at that boundary; that is now named, together
  with the Cygwin `kill -0` limit the review measured.

## What is proven, on real processes, in this session

* **The deletion at the tip.** `verify/prelease-grace.mjs A`, a REAL pre-change lane run (main's
  `scripts/merge-lane.mjs`, pid 59440, pre-lease clone `wa-merge-lane-qNNYBo`), aged 2 h with a newer
  dead leftover beside it, swept with the tip's own `sweepClones`: `removed: [wa-merge-lane-qNNYBo]`,
  the run exited 4 with `ENOENT ... wa-merge-lane-qNNYBo/.git/wa-merge-lane-gate.log` - its own clone
  deleted under it, the unattributed failure the rule exists to prevent.
* **Gone after the fix.** The same scenario with this branch's byte-identical code path: pid 29628,
  clone `wa-merge-lane-mGYDs0`, `recent_legacy: [Cand01, mGYDs0]`, `removed: []`, the clone survives and
  the run reaches its own gate. `grace_seconds: 10860`.
* **The queue case** (`verify/prelease-grace.mjs B`): a real slot held in a scratch gate-lane store of
  its own by a real `gate-lane.mjs acquire` (pid 77132/63708), a real pre-change run queued behind it
  (pid 66936/36356 - its own words: "acquire #2 waiting (4s). capacity 1 of 1 in use", gate started =
  false), its clone aged 2 h. At the TIP the sweep SELECTED that queued live clone and handed it to
  `rm -rf`, which Windows refused (EPERM recorded in the sweep's errors) because the acquirer child
  holds the clone as its working directory; with the fix the clone is not a candidate at all
  (`recent_legacy`). Both runs were killed by pid and the scratch root removed.
* **Evidence over age** (`verify/prelease-grace.mjs C`): two pre-lease clones aged 3.5 h, one idle and
  one held by a real native process; the fix removes the idle one (`evidence: "rename allowed"`) and
  keeps the held one (`in_use: [["wa-merge-lane-Held90","rename refused (EBUSY)"]]`), where the tip
  handed both to `rm -rf` (the held one survived only because Windows refused the removal).
* **The bound still works** (`D`): a stale pre-lease family (6 h/5.5 h/5 h) still loses all but the
  newest, and `keep=all` - the inherited falsifier - still removes nothing.
* **The delivery's own suite**, extended by this branch: `node scripts/test-merge-lane-retention.mjs`
  -> exit 0, `temp retention ok (52 checks)` (45 inherited + 7 new pinning the derived grace, the
  evidence probe, and that a real run records a grace longer than a gate alone can live). Run with
  `WA_GATE_LANE=off`: the focused test drives real lane runs and the gate slot is held by another lane
  right now, so with a slot requested it queues (observed: exit 143 when killed while waiting).
  Bounded: 4 runs, 20.0 MB each; unbounded (`WA_MERGE_LANE_KEEP=all`): 40.1/60.1/80.1/100.1 MB.
* `node scripts/test-merge-lane.mjs` -> `merge-lane spine ok (70 checks)` (also `WA_GATE_LANE=off`);
  `node scripts/check-instructions.mjs` -> PASS (74 checks); `bash -n scripts/test.sh`; `node --check`
  on both changed JavaScript files.

## The MSYS-cwd shape: partly covered, named

`verify/probe-holders.mjs` and `verify/probe-msys-cwd.mjs` measured four holder shapes:

| holder | rename probe | `rm -rf` |
|---|---|---|
| nobody (idle) | allowed | removed |
| native process, cwd = the clone | **refused EBUSY** | removed |
| native process, cwd = a subdirectory | **refused EPERM** | removed |
| native process, open file inside | **refused EPERM** | removed |
| MSYS/Cygwin process that `cd`-ed in | allowed (blind spot) | removed |
| MSYS/Cygwin process spawned WITH the clone as its cwd (this lane's gate spawn) | **refused EBUSY** | refused EPERM |

So the rule covers the lane's real gate spawn (EBUSY) but NOT an MSYS process that arrived by `cd`;
that is the residual limit now written in the comment. It does not reopen the queue case, which is
covered by the derived grace instead.

## What is NOT proven / not done

* `scripts/test.sh` as a whole was NOT run: its own constraint for this lane, and the gate slot is held
  by another lane's cold landing. Only the gate-home block's slice was exercised, through
  `scripts/test-merge-lane-retention.mjs`.
* The gate-home family's pre-lease window is unchanged (an hour) and was not the reproduced defect; its
  comment now states what that hour really covers instead of claiming more.
* A pre-change run whose wait budget was raised ABOVE the sweeping run's own
  `WA_GATE_LANE_WAIT_SECONDS` is outside the derived arithmetic; the filesystem evidence is then what
  protects it, unless the holder is the MSYS-`cd` shape.
* No sweep in this repair ever ran against the live `wa-merge-lane-*` / `wa-gate-home-*` families
  (33 and 18 of them in the live temp root, untouched); every harness pinned TEMP/TMP/TMPDIR to
  `C:/Users/Victor/.wasm-agent/wa-repair-c78ab73/`. One stray request (#190) that the killed test run
  left in the LIVE gate-lane store was settled by the lane itself ("abandoned while waiting: pid 84700
  is gone; its place in the queue is released"), not by me: the live store was read with `status` only.
