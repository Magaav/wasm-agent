# VERDICT: the pre-lease grace repair (delivery `62868e3c`)

**Independent review. I did not write this repair.** Verdict: **accept with named residue.**

* delivery under review: branch `change/wa-session-childdispatch054d4d9b-ae24-4604-9a51-2685384ff0c8`,
  tip **`62868e3c2264eac8d656f3ea0ef802619e6beae9`**
* **the tree this verdict covers: `2e73cf186b2966e208f314b2115d89b7443ae797`**
  (`git rev-parse 62868e3c^{tree}`); parent delivery `c78ab731`
  (`scripts/merge-lane.mjs` = `a3e8328a...`), base `origin/main` = `da8dc891`.
* reviewer: session `child:dispatch:e70d7d00-8702-4363-b997-e9589e493dfb`, worktree
  `C:/Users/Victor/.wasm-agent/wa-worktree-childdispatche70d7d00-8702-4363-b997-e9589e493dfb`,
  branch `change/wa-session-childdispatche70d7d00-8702-4363-b997-e9589e493dfb`.
* every experiment below is my own harness (`evidence/harness.mjs`, `evidence/sweep.mjs`,
  `evidence/probe-child.mjs`), written for this review; the delivery's `verify/` was read for its
  claims but is **not** the evidence for any verdict line. Raw output of every run is in `evidence/`.

I did not run `scripts/test.sh`, I did not take, hold or steal a gate slot, I did not edit or merge
the delivery, and no sweep of mine ever saw the live `wa-merge-lane-*` / `wa-gate-home-*` families
(proof in "Non-interference").

---

## 1. The scenario that failed: before and after, with real processes and real pids

The defect (D1, already reproduced by another reviewer; not re-litigated) is that the flat hour was
shorter than the gate lane's own wait budget and the clone is made **before** the slot is waited for.

**My reproduction of the tip's deletion** — `node harness.mjs gate ./tip tip`
(`evidence/gate-tip.txt`): a REAL pre-change lane run (main's `scripts/merge-lane.mjs`, pid **39892**,
clone `wa-merge-lane-ZLCX3H`, `WA_GATE_LANE=off`, inside its own gate, swept by the tip's own
`sweepClones` while it is alive):

    removed: [wa-merge-lane-ZLCX3H]                 <- rm -rf SUCCEEDED on the live run's clone
    the LIVE run's clone exists after the sweep: false
    the run's exit: 4    verdict=refused exit_code=4
    error: "ENOENT: no such file or directory, open
      '...\wa-merge-lane-ZLCX3H\.git\wa-merge-lane-gate.log'"

**The same scenario at the fix** — `node harness.mjs gate ./fix fix` (`evidence/gate-fix.txt`,
pid **56176**):

    grace_seconds: 10860   recent_legacy: [..., \wa-merge-lane-QITp7l]   removed: []
    the LIVE run's clone exists after the sweep: true
    the run's exit: 0   verdict=pass exit_code=0   (its gate ran on its intact clone)

**The queue case itself** (the shape named in the task): a real slot held in a scratch gate-lane store
of my own by a real `gate-lane.mjs acquire`, a real pre-change run queued behind it (its own words:
`acquire #2 waiting (0s). capacity 1 of 1 in use`), its clone aged 2.0 h, beside a newer dead leftover.

`node harness.mjs queued ./tip tip` (`evidence/queued-tip.txt`) — slot holder pid **33676**, run pid
**82700**, clone `wa-merge-lane-GU5dil`:

    QUEUED: clone=wa-merge-lane-GU5dil gate_log_exists=false run_alive=true
    SWEEP ... "recent_legacy":[], "removed":[], "kept":[wa-merge-lane-Cand01],
      "errors":[[wa-merge-lane-GU5dil, "EPERM, Permission denied: ..."]]

So at the tip a queued live run's clone is **never protected**: it is selected and handed to `rm -rf`
at every age. In *this* holder shape Windows refused the removal (EPERM) — my measurement agrees with
the delivery's own honest note about its case B. The shape where the removal is carried through is the
in-gate shape above: clone gone, live run exit 4. That is the failure the rule exists to prevent.

`node harness.mjs queued ./fix fix` (`evidence/queued-fix.txt`) — slot holder pid **38084**, run pid
**76116**, clone `wa-merge-lane-98w8e6`:

    grace_seconds: 10860   recent_legacy: [wa-merge-lane-98w8e6, wa-merge-lane-Cand01]   removed: []
    the QUEUED run's clone exists after the sweep: true
    scratch slot released cleanly (gate-lane release --id 1): exit 0
    the run's exit: 0   verdict=pass exit_code=0     (its gate ran on its intact clone)

Every run was killed by pid (`taskkill /F /T`), each harness removed its own scratch root
(`cleanup: scratch root removed = true` in every evidence file), and no child of mine is alive at the
time of writing (`Get-CimInstance Win32_Process` filtered to my scratch path: empty).

## 2. The arithmetic: derived, and falsified

`evidence/arithmetic.txt` (the fix's own exported `legacyGraceMs`):

       10860  s  <- no knobs (defaults)                       = 7200 + 3600 + 60
       10860  s  <- wait 7200, gate timeout 3600
     1003660  s  <- a caller exporting WA_GATE_LANE_WAIT_SECONDS=1000000
        7260  s  <- --timeout-seconds 0 (spawnSync timeout 0 = NO gate timeout)
          60  s  <- wait 0 and gate timeout 0
       10860  s  <- a non-numeric / negative / empty wait budget (falls back)

The derivation is real and it follows the budgets: the default **10860 s (3 h 1 min)** is exactly
`gate lane wait + this lane's gate timeout + 60 s slack`, and the flat hour it replaces was 7260 s
short of the wait alone. A mangled env value falls back to the default, which is the safe direction.

**Falsification — the raise the task asks for.** The grace is computed from the **sweeping** run's
budgets, but it has to cover the **holder's**, and the two can differ:

* `REVIEW_RUN_WAIT=20000 REVIEW_AGE_HOURS=6 REVIEW_DECOY_MINUTES=330 node harness.mjs queued ./fix`
  (`evidence/queued-fix-runwait20000.txt`): the queued run exported **20000 s** as its own wait budget
  (its own arithmetic would want 23660 s), its clone was aged 6 h (decoy 330 min, i.e. past the
  sweeper's grace). The sweeper still derives 10860 s, so the arithmetic does **not** protect it —
  `recent_legacy: []` — and what kept it alive was the filesystem probe alone:
  `in_use: [[wa-merge-lane-dco9VQ, "rename refused (EBUSY)"]]`, `removed: []`, the run passed.
  The milder form of the same case — a 4 h clone with a 3.5 h decoy, both past the sweeper's grace,
  the queued run's own budget at the default — is `evidence/queued-fix-pastgrace.txt`:
  `in_use: [[wa-merge-lane-ij5RHc, "rename refused (EBUSY)"]]`, run exit 0.
  The lower direction is the same story
  (`node harness.mjs queued ./fix fix-sweeper600 600`, `evidence/queued-fix-sweeper600.txt`: the
  sweeper's own budget 600 -> grace 4260 s, the queued run's own budget the default 7200 s ->
  `recent_legacy: []`, `in_use: [..., "rename refused (EBUSY)"]`).
* **Residue R1 (named, not hidden):** the derivation protects a queued run only while the *queued*
  run's `WA_GATE_LANE_WAIT_SECONDS` + `--timeout-seconds` stay inside the *sweeping* run's derivation.
  Above it, liveness rests entirely on the probe — and the probe has a measured blind spot (§5), so a
  queued run with a raised budget *and* an MSYS-`cd` holder is still deletable.
* **Residue R2 (measured):** the same variable in the over direction defeats the count bound.
  In `node harness.mjs bound ./fix fix` (`evidence/bound-fix.txt`), with the sweeper's
  `WA_GATE_LANE_WAIT_SECONDS=1000000` -> `grace_seconds: 1003660` (11.6 days), a 6 h/5.5 h/5 h stale
  family loses **nothing** (`removed: []`, all three in `recent_legacy`). The tip, which ignores the
  variable, still pruned it (`evidence/bound-tip.txt`). The family bound is now a function of the
  node's environment: it becomes a time bound in which a 13 h-old clone reads as "recent".
* **Residue R3 (arithmetic hole):** `--timeout-seconds 0` is accepted, and for `spawnSync` a timeout
  of 0 means *no* timeout — so `legacyGraceMs` derives 7260 s for a gate that may run without limit.
  `budgetSeconds`'s `value >= 0` lets a non-budget through as if it were one.

## 3. Evidence over age: does deletion now require proof?

**Yes.** `holderProbe(dir)` renames the directory within its own parent and renames it back. Read
against `evidence/probe-smoke.txt` (`node harness.mjs probe ./fix fix`, sweeps run by pids 81284 and
35896), where the second sweep does remove a 5 h-stale clone with `"evidence": "rename allowed"`:

* only *renamed and restored* produces a deletion (`evidence: "rename allowed"`);
* every other rename outcome means **keep**: a refusal of any code is recorded as
  `in_use: [..., "rename refused (EPERM)"]` with the directory untouched, and `ENOENT` means the
  directory went away on its own — the sweep does nothing;
* an **unanswerable** probe does not mean delete: with the probe's own target path occupied (what a
  leftover probe path from a crashed sweep looks like) the rename fails and the clone is kept —
  `in_use: [..., "rename refused (EPERM)"]`, `removed: []`;
* a rename that succeeds but cannot be restored is also read as in use (`probe_path` recorded and an
  error logged), never as "free to delete".

This is a change of kind, not of degree: at the tip, age alone bought a deletion (`gate-tip.txt`,
`removed: [wa-merge-lane-ZLCX3H]`); at the fix, a positive filesystem answer is the only thing that
ever deletes. Where that answer is *false* (MSYS `cd`, §5) the rule deletes anyway — a false negative
in the probe, not an inference from age.

## 4. The bound still works, with the real counts

`node harness.mjs bound ./fix fix` (`evidence/bound-fix.txt`):

    family: [wa-merge-lane-Middle, wa-merge-lane-Newest, wa-merge-lane-Oldest]  (6 h / 5.5 h / 5 h)
    SWEEP keep=1   -> after: [wa-merge-lane-Newest]
      removed: [[wa-merge-lane-Middle, "rename allowed"], [wa-merge-lane-Oldest, "rename allowed"]]
    SWEEP keep=all (the inherited falsifier) -> after: all three   (nothing removed)

The delivery's own suite, as delivered, from a tree carrying only the files it needs
(`fix/scripts/{test-merge-lane-retention.mjs, merge-lane.mjs, gate-lane.mjs, test.sh}`):

    $ WA_GATE_LANE=off node scripts/test-merge-lane-retention.mjs     # evidence/retention-test-fix.txt
    EXIT=0
    ok count: 52 | FAIL count: 0
    "temp retention ok (52 checks)"

**It matches what the branch claims**: `verify/STATUS-prelease-grace.md` says "exit 0, temp retention
ok (52 checks) (45 inherited + 7 new)"; the diff adds exactly 7 `ok(` calls
(`git diff c78ab731 62868e3c -- scripts/test-merge-lane-retention.mjs | grep -c '^+  ok('` -> 7) and
45 + 7 = 52. That suite also exercises the `scripts/test.sh` gate-home slice ("gate home
(scripts/test.sh, the sliced block)") among the 52. I ran it with `WA_GATE_LANE=off` because the live
gate holds a slot; the delivery's reason for the same choice (a run that requests a slot here queues
behind the live holder instead of finishing) is sound.

## 5. The MSYS-cwd shape

`node verify/probe-msys-cwd.mjs` as delivered (`evidence/theirs-probe-msys-cwd.txt`) and my
independent two-holder test (`node harness.mjs msys ./fix fix`, `evidence/msys-fix.txt`, MSYS bash pids
**31432** cd-ed in / **81856** spawned in) agree:

    MSYS bash cd-ed in from elsewhere:        rename probe "renamable (looks idle)"
      -> SWEEP keep=0 removed: [[wa-merge-lane-Cd0001, "rename allowed"]];
         dir exists = false while its shell is still alive = true
    MSYS bash spawned WITH the dir as its cwd (the way the lane spawns its gate):
      rename probe refused (EBUSY) -> in_use -> kept; dir exists = true

**The rule explicitly does NOT cover the `cd` shape** — the comment in `scripts/merge-lane.mjs` says so
by name ("an MSYS/Cygwin process that reached the directory by `cd` is invisible to that ask"), and the
sweep now even records that false answer as its evidence. It does cover the lane's real shapes: the
acquirer child is spawned with `cwd = clone` and the gate with `cwd = clone` (`scripts/merge-lane.mjs`,
`laneAcquire` and `spawnSync('bash', ..., {cwd: clone.dir})`), and both measure EBUSY. This residue
does **not** reopen the reproduced queue case: there the clone is kept by the derived grace (§1) and,
past that grace, by EBUSY (§2).

## 6. New defects and blast radius

* **Deletion never happens on an unavailable or ambiguous answer** (§3). The failure mode I could find
  is the opposite one: a *false* "free" answer deletes (MSYS `cd`) — residue R4, named by the delivery
  and confirmed by me.
* **Unbounded growth:** three ways, each measured or read directly — (a) R2 above: a raised wait budget
  turns the count bound into an 11.6-day time bound (`removed: []`); (b) an in-use directory is kept
  *and* still consumes the budget, so leaked long-lived holders grow the family by design; (c) **new**:
  a probe whose *restore* fails leaves `<name>.in-use-<pid>`, which does not match
  `wa-merge-lane-<6>` and is therefore counted as `not_this_family` and **never pruned again** —
  visible in `evidence/probe-smoke.txt` (`not_this_family: 1`, the leftover still present after a
  further sweep). Bounded by the number of such failures, but invisible to the bound.
* **Blast radius:** `scripts/gate-lane.mjs` is byte-identical to `origin/main` (sha256 `59946c2a...`
  at all three revisions) — the admission code is untouched. In `scripts/merge-lane.mjs` every hunk is
  the retention block (`legacyGraceMs`, `holderProbe`, `sweepClones`, the retention notice) plus the
  two `sweepClones` call sites that pass `gateTimeoutSeconds: options.timeoutSeconds`; nothing else in
  that file changed. `scripts/test.sh`'s only change is that comment block (one hunk, comment lines
  only): the gate-home sweep logic and its hour are unchanged, as claimed. I did not run `test.sh`.
* The delivery's own probe table over-generalises one row: "native process, cwd = the clone" is listed
  as `rm -rf` **removed**, but the lane's own acquirer child (native, `cwd = clone`) made `rm -rf`
  fail EPERM in my queue run (`evidence/queued-tip.txt`). That makes their case-B prose (which says
  Windows refused there) accurate and the table row optimistic, not the reverse.
* Cosmetic: `verify/probe-msys-cwd.mjs` leaves its two fixtures behind in its scratch root
  ("left: wa-merge-lane-Gate00, wa-merge-lane-Gate01"); it touches no live family.

## What I could NOT verify

* `scripts/test.sh` as a whole was not run (hard constraint of this review, and of the delivery): its
  gate-home block is covered only through the slice the retention suite runs.
* The gate-home family's own pre-lease window (an hour) was not the reproduced defect and I did not
  re-derive it; I verified only that its logic is unchanged and that its comment no longer claims
  rollout safety — a documentation change I read, not a behaviour I measured.
* The real lock-window for `gate-lane` under a *cold landing*: the delivery cites slot waits of 4909 s
  and 5399 s; I could not measure a genuine multi-hour wait. My queued runs were queued for seconds,
  and the age of a clone in a real queue was simulated with `utimes` (the technique the delivery also
  used). What stands behind a 2 h wait is the arithmetic of §2 — and §2 is where it stops covering the
  holder.
* No live-node reclaim pass was exercised: nothing here says how the disk half behaves in production,
  only what this rule does to a family in a fenced temp root.
* I did not verify the fix against a run whose clone is held *only* by an open handle with no cwd
  holder (a shape the lane does not produce) beyond the probe's own row for it.

## Non-interference

* Every child of mine had `TEMP`/`TMP`/`TMPDIR` pinned to its own scratch `temp`, and
  `WA_GATE_LANE_DIR` pinned to a scratch store (or `WA_GATE_LANE=off`); every sweep was given that same
  `tmp`. The live gate-lane store was never named by any call and the live slot was never touched.
* Read-only check of the live temp root: the live families **grew** during this review
  (`wa-merge-lane-*` 33 -> 54, `wa-gate-home-*` 18 -> 20). A sweep can only remove, so nothing of mine
  swept them; and the newest live clones point at fixture repos that are not mine
  (`.../wa-merge-lane-test-lcORj1/repo`, `.../wa-gate-lane-wiring-dzTRtQ/merge-repo`), i.e. another
  session's lane activity.
* My scratch (`C:/Users/Victor/.wasm-agent/wa-review-054d4d9b`, 676 KB before evidence copies) holds
  the harnesses and the raw evidence; every case root was removed by its harness, and the case
  directories left by two crashed harness attempts were removed by hand.

## Reproduce

    git fetch origin change/wa-session-childdispatch054d4d9b-ae24-4604-9a51-2685384ff0c8
    # extract scripts/merge-lane.mjs + scripts/gate-lane.mjs + skills/git-orchestrator/scripts/audit.mjs
    # for 62868e3c (fix), c78ab731 (tip) and origin/main (pre) into three directories, then
    node harness.mjs {queued|gate|bound|msys|probe} <treeDir> <label> [sweeperWaitSecondsEnv]
    WA_GATE_LANE=off node <fix>/scripts/test-merge-lane-retention.mjs
    # REVIEW_RUN_WAIT / REVIEW_AGE_HOURS / REVIEW_DECOY_MINUTES drive the falsification cases (§2).
    # The harness creates its own scratch root, starts its own processes and kills them by pid;
    # it never reads the live temp root except through readdir, and never the live gate-lane store.
