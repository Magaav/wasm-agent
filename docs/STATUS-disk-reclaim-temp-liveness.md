# Status: the temp-family liveness rule and the `df` parse (repair of `72530c58`)

Branch `change/wa-session-childdispatch4e773dae-d31f-43db-8d08-59e0cf154ec9`, started at the
refused delivery's tip **`72530c58`**. Scope: `scripts/reclaim-disk.{sh,mjs}`,
`scripts/check-disk-floor.sh`, their tests, this file. Nothing else, and deliberately not
`scripts/merge-lane.mjs` (see "Out of scope" below).

This file was committed **before** any fix, so the state below is the state at that commit.

## The two findings this delivery repairs (from `verify/REVIEW-disk-temp.md`)

1. **No liveness rule for temp families.** With `--apply` the pass removed
   `wa-subagent-test-Live01` while a live process held a file inside it (33 B, `oldest=7h`). Age
   was the only test.
2. **The `df` parse false-refuses.** `bash scripts/check-disk-floor.sh --path /` exits 3
   ("cannot measure free space") with 69 GiB free, because the parse assumes the Filesystem field
   holds no space and this machine's root mount is `C:/Program Files/Git`. The same assumption is
   in `scripts/reclaim-disk.mjs::freeSpace` (`fields[1]`, `fields[3]`).

## Works (the reviewed delivery, kept as it stands)

* `scripts/check-disk-floor.sh`: the measured 3.98 GB floor, the named refusal (floor, free, both
  in bytes), the `--json` shape, and the exit-code policy - 0 above, 1 below, 2 bad argument,
  **3 unmeasurable** ("an unmeasurable disk is refused, never assumed healthy").
* `scripts/reclaim-disk.mjs`: report-first, `--apply` the only way anything is removed, the
  `rust/target` half with its session-store proofs, and the deferences the review found clean
  (`wa-merge-lane*`, `wa-gate-home*`, `wa-lane-*`, `wa-sentinel-*`, and entries no tracked
  script claims). All of these are **kept, with their reasons**.
* Its own tests pass on this tree (`test-disk-floor.cjs`, `test-reclaim-disk.cjs`,
  `test-temp-retention-check.cjs`) and are wired into `scripts/test.sh`.

## Proven by measurement, before any fix (this machine, MSYS/MINGW64)

The liveness evidence is the OS's own exclusive-access test on the family directory: a
**same-name rename** of the directory needs DELETE access on it and on what it holds, so it is
refused exactly while something is in use and succeeds once nothing is:

| fixture | `fs.renameSync(dir, dir)` |
|---|---|
| idle directory | **OK** (and a rename out-and-back succeeds) |
| a file inside held open by a live process | **REFUSED EPERM** |
| the directory is a live process's working directory | **REFUSED EBUSY** |
| the same directory after the holder was killed | **OK** |

Consequences checked in the same run: `fs.rmSync(dir, {recursive:true})` **does** remove a family
whose file is held open by a live process (the review's finding, reproduced: the held file is
gone while the holder is still alive), and it refuses (`EPERM`) when the directory is a live
process's cwd. So removal succeeding is not evidence of staleness, and this probe is what makes
"in use" and "idle" distinguishable without deleting anything.

Also measured: `df -Pk /` prints `C:/Program Files/Git   499987452 430894512  69092940      87% /`
- `$2`/`$4` (the old parse) are `Files/Git` and `430894512`, the free space is `$5`. PowerShell
exists here and its `[System.IO.File]::Open($p,'Open','ReadWrite','None')` probe does distinguish
a held file from a free one, but the rename probe above is cheap, needs no platform tool, and is
non-destructive, so it is the one used.

## Proven by measurement, after the fixes (the evidence)

The fixes are `6067c35` (the liveness rule, and the mjs half of the parse) and `31a818f` (the
check's parse). Each block below is output, not a summary of output.

**The live-holder case.** A scratch temp root, a real child process holding `held.open` (33 B)
inside `wa-subagent-test-Live01`, its directory aged to 7 h, then `--apply`:

    LEFT   wa-subagent-test-Live01  — in use: a live process names this family - pid 49552 ("C:/Program
           Files/nodejs/node.exe" -e "const fs=require('node:fs');const fd=fs.openSync(...)…)  34 B
    expired: 1 entries, 1 B — removed …   wa-subagent-test*  n=1  1 B  oldest=7h  removed=1
    [disk] live family present: true, stale family present: false

The family, and the file the holder had open, survived; the genuinely stale `wa-subagent-test-Stale01`
(7 h, no holder) was removed in the same run, so the rule is not "leave everything". After the
holder was killed the same command reclaimed the family:

    expired: 1 entries, 34 B — removed …   wa-subagent-test*  n=1  34 B  oldest=7h  removed=1
    [disk] live family present after run 2: false

The deferences in those same runs, unchanged and still named: `wa-sentinel-Aged01` ("never expired by
rule: the sentinel watches this path while it runs"), `wa-gate-home*` and `wa-merge-lane*` ("another
lane's retention rule: …"), and `wa-not-a-tracked-family-SomeId` ("not matched to a known family
(left alone): 1 entries"). The pid evidence line is `live-process scan (the pid evidence): powershell
Get-CimInstance Win32_Process, 289 processes`.

**The `df` case, the same numbers on both sides.** Both sides read
`C:/Program Files/Git   499987452 430894512  69092940      87% /` (64.36 GiB free, floor 3.71 GiB):

    before (tip 72530c58):  exit 3   cannot measure free space at / (df said: 'C:/Program Files/Git … 87% /')
    after:                  exit 0   free: 65.89 GiB of 476.83 GiB on /   ok: 65.89 GiB >= the 3.71 GiB a run needs
    after, --json:          available_bytes 70751170560  (= 69092940 KiB exactly), mount "/", ok true
    after, floor above it:  exit 1   ok false — the refusal is the floor's, not the parse's

With the real `df -Pk /` on this node, un-stubbed: before exit 3 `cannot measure free space at /`,
after exit 0 `free: 64.06 GiB of 476.83 GiB on /`.

**The tests.** `node scripts/test-reclaim-disk.cjs` -> exit 0, `reclaim pass ok (47 checks, 0 skipped;
…)` (23 before); `node scripts/test-disk-floor.cjs` -> exit 0, `disk floor ok (43 checks, 0 skipped;
…)` (28 before); `node scripts/test-temp-retention-check.cjs` -> exit 0 (7 checks).

## Still unproven, or not measured here

* The `/proc` branch of the liveness source is **unexercised**: this node is Windows and the branch
  is not reached. It is written to the POSIX rule (a live process's cwd, or an open file inside the
  family) and a /proc entry that cannot be inspected yields `liveness unproven`, never "clean" - but
  that is code, not a measurement.
* The rename probe's coverage is the OS's own: it refused here for a held file (EPERM) and for a
  working directory (EBUSY), and allowed an idle directory. A holder that shares nothing, and a
  family on a filesystem with different semantics, were not measured.
* The pid match is textual - the family path as a substring of a command line, backslashes and case
  normalised. A process that names the family only in an 8.3 short form would not match; the rename
  probe is what still decides such a case.
* A family entry that is not a directory is left with `liveness unproven`, because the directory
  probe cannot answer for the open handles inside a file. That is a deliberate behaviour change from
  the reviewed pass, named rather than hidden.
* Cost: one process scan per run when there are candidates (289 processes, about a second here) and
  one same-name rename per candidate. Not measured against a temp directory holding thousands of
  aged entries.
* Free space on this node is ~66 GiB. The refusal path is exercised with `--floor-bytes`, never by
  provoking a genuinely low disk.

## Out of scope, deliberately

`scripts/merge-lane.mjs` is untouched. Its own defect - an mtime-based one-hour pre-lease grace
against the gate lane's `WA_GATE_LANE_WAIT_SECONDS` default of 7200 s, with 4909 s and 5399 s
waits observed - belongs to a delivery being verified against that file. If this repair seems to
need a change there, that is a stop-and-say-so, not an edit.

## State at this commit

1. The liveness rule: done, in `6067c35`, with the evidence above.
2. The anchored `df` parse in `scripts/check-disk-floor.sh` and in `freeSpace()`: done, in `6067c35`
   and `31a818f`, with the same numbers on both sides before and after.
3. Proof: above - the live-holder case left alone with pid evidence and then reclaimed, the `df` case
   before and after, and the deferences still recorded.
4. This file: done. The closing gate on the committed tree: **not run** - the lane was held, and it is
   not claimed. `finish.mjs gate` on `05972055b85498f229cbb96353057d79ea8ace32` (with
   `WA_GATE_LANE_WAIT_SECONDS=240`, so it gives up visibly instead of queueing for hours) passed every
   precondition - `repository_ready: true`, all 8 checks ok (`clean`, `fresh_remote_refs`, `current`,
   `pushed` = `origin/change/wa-session-childdispatch4e773dae-d31f-43db-8d08-59e0cf154ec9`,
   `merge_proof` = tree `72aacaba`) - and then

       gate_error: the gate did not run: the gate lane granted no slot (acquire #163 refused after 240s
       (terminal, not a retry). capacity 1 of 1 in use; running #162 (finish
       change/wa-session-childdispatch389b8886-2cfb-45bc-be85-64f4357931f9, pid 48476, held 318s);
       queue depth 1 (next to run); waited 240s; also waiting: #164)
       gate_verified: false

   So there is **no skip count and no gate exit status to report**: the gate did not execute, and
   inventing either would be the lie this whole delivery is about. What is reported instead is the
   lane's own record of why, and the three test suites above, which did run and did pass. Free space
   when the attempt was made: 64.54 GiB (67677504 KiB free of 499987452 KiB, 13%).

Agent: wasm-agent node=wasm_the_first role=child session=child:dispatch:4e773dae-d31f-43db-8d08-59e0cf154ec9
