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

## Unproven (unmeasured, and labelled as such)

* The fixes themselves do not exist yet at this commit. Nothing above is a claim about them.
* `df`'s `--output=` form is rejected here (`df: options -P and --output are mutually exclusive`),
  so the parse is anchored on the Capacity field (`NN%`) instead - it must be asserted against
  the real Cygwin/MSYS root line, which this file does not yet do.
* A process that holds *no* handle on a family and names it only on its command line is not
  detected by the rename probe. The pid evidence for a refusal comes from a command-line scan
  (planned), whose matching is textual: an 8.3 short-path form (`C:/Users/VICTOR~1/...`) would
  not match, and that limit will be stated rather than papered over.
* On a POSIX host the rename probe is expected to succeed even while a file inside is held (POSIX
  renames are metadata-only), so on POSIX the probe alone would not be the rule. This delivery is
  measured on this Windows node only; the POSIX half is labelled unexercised.
* Free space on this node is ~66 GiB. The refusal path is exercised with `--floor-bytes`, never by
  provoking a genuinely low disk.

## Out of scope, deliberately

`scripts/merge-lane.mjs` is untouched. Its own defect - an mtime-based one-hour pre-lease grace
against the gate lane's `WA_GATE_LANE_WAIT_SECONDS` default of 7200 s, with 4909 s and 5399 s
waits observed - belongs to a delivery being verified against that file. If this repair seems to
need a change there, that is a stop-and-say-so, not an edit.

## Next, in order

1. The liveness rule in `scripts/reclaim-disk.mjs`: an in-use family is never a candidate, decided
   by the rename probe (and the pid from the command-line scan), in report mode too; where
   liveness cannot be established, leave it and say so.
2. The anchored `df` parse in `scripts/check-disk-floor.sh` and in `freeSpace()`, with the same
   numbers on both sides before and after.
3. Proof: the live-holder case left alone with pid evidence, then released and reclaimed; the `df`
   case before and after with the same numbers; the deferences still recorded.
4. This file updated with what was actually observed, and the closing gate on the committed tree.

Agent: wasm-agent node=wasm_the_first role=child session=child:dispatch:4e773dae-d31f-43db-8d08-59e0cf154ec9
