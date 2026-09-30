# Independent verification: the two disk/temp deliveries

Reviewer: `child:dispatch:db0ce06c-05ff-4f77-b4af-e1919e14e392`, own session worktree
(`change/wa-session-childdispatchdb0ce06c-05ff-4f77-b4af-e1919e14e392`).
Nothing in either delivery was edited, merged, pushed or re-pointed; every script in `verify/` below is
mine. The two deliveries were checked out into a throwaway clone of the canonical repo
(`/tmp/rev/repo` → worktrees `treeB1`, `treeB2`, `treeMain`, `treeCombined`), never into my own tree only
to read.

    main      ab827c88a6ac091318b5adb8be34e83e858c4e9a
    D1        c78ab73130b13c0da967b5ce7ce7d1f96d3f0301  change/…fdbfecc8-d5a7-4681-8eed-4d56490fa394
    D2        72530c583de343d42023f72117b0893509f945ff  change/…c66e86ed-0184-40b7-b2db-d98b90d82e3d

    git hash-object verify/b1-merge-lane.mjs  9baf37b5e5146dca686dde60e9b480d358996f4f  == D1:scripts/merge-lane.mjs
    git hash-object verify/b1-test.sh         8cac788fab7ac1b2ebe4c630b432c464cfc008e6  == D1:scripts/test.sh

Harnesses (mine, all in `verify/`): `liveness-node.mjs`, `gate-home-liveness.sh` (+ `slice-gate-home.mjs`),
`retention-sequence.mjs`, `refusal-chain.sh`. Ran: `node --version` v24.19.0, `bash` 5.3.15 (x86_64-pc-cygwin).

## Verdicts

**D1 `c78ab731` — NEEDS-CHANGE.** Every *number* it claims reproduced on real processes: a failing run keeps
its own artifact, the family is bounded at the newest N, a live lease is never pruned (node sweeper *and* the
shell gate-home sweep), and the falsifier (`=all`) removes the bound; a passing run removes its own clone in
the lane half, and its own home in the sliced gate-home half (on a real gate that removal was **best-effort
and silent** — see attempt 2 below). But
the sentence that carries the safety argument — "A pre-lease name is pruned only once it is an hour old, so a
rollout cannot delete the clone of a run the previous script started" — is **false on this machine, and I
reproduced the failure three times**: a live pre-change lane run's clone WAS deleted by the sweep. The hour
is shorter than the gate lane's own default wait budget (2 h), and the clone is made before the slot is
waited for. Fix belongs in its own delivery; see "D1's pre-lease grace is shorter than the queue" below. The
retention bound itself needs no change.

**D2 `72530c58` — NEEDS-CHANGE.** The floor, the refusal, the reclaim pass and the leak check all work as
described, and its own tests pass (28 + 7 + 23 checks). Two real defects, both reproduced: (1) the floor's
free-space parse is positional and **hard-refuses every run (exit 3) when the measured path's `df`
Filesystem field contains a space** — which is the Cygwin root mount on this very machine
(`C:/Program Files/Git`), and which is where the script lands whenever it is invoked as a copy outside a
repo; (2) the reclaim pass's temp rule is **age only** — with `--apply` it removed a temp directory a live
process was holding open (reproduced). Fix belongs in its own delivery (below). Secondary: its job definition
cannot be fired or installed by anything in the tree, and its action points at a script that is not installed.

## The contradiction check (the highest-value item)

**No fight. D2 explicitly yields the two families to D1, and the merge is clean.** D2 names D1's families as
protected in `scripts/reclaim-disk.mjs`:

    const PROTECTED_TEMP_FAMILIES = [
      { prefix: 'wa-gate-home',  why: "the gate's retained home: scripts/test.sh keeps it … the lane that bounds gate homes owns that rule" },
      { prefix: 'wa-merge-lane', why: 'a merge-lane clone: scripts/merge-lane.mjs owns its retention' },
      { prefix: 'wa-lane-',      why: 'a merge/gate lane scratch tree: its lane owns its retention' },
    ];

so the two pruners never see the same candidate: D1 sweeps `wa-merge-lane-*` (node, liveness by
`process.pid` lease) and `wa-gate-home-*` (bash, liveness by `kill -0`); D2 sweeps neither. `check-temp-retention`
is keyed by **file path**, not line, so D1's edits to `test.sh`/`merge-lane.mjs` cannot invalidate its 36
DEFERRED entries: on the combined tree the check is `PASS (229 files, 85 mint temp paths, 1 declared, 36
deferred, 0 resolved)`. No keep-budget is counted twice: D1's budgets are `1/0` per run (pre-clone sweep 1,
post-run sweep 0 once the run keeps its own), which is exactly one artifact on disk.

The one *hole*, which neither commit claims and which is the shape of the original incident: **the deterministic
reclaim pass cannot free the family the incident was made of.** D1's rule runs only inside a merge-lane run
(`retention.sweeps.push(sweepClones(...))`, `scripts/merge-lane.mjs:521`) or a gate run (the EXIT trap in
`scripts/test.sh`); D2's pass refuses both families by name. If 135 dead clones (~150 GB) are already sitting
in temp and no lane or gate ever runs again, nothing prunes them and D2's job — the only always-available
actor — will not. Self-healing in practice (the next lane's pre-clone sweep is exactly the cleanup), but it
means the two policies together still have no *triggerable* owner of the big family. Named, not fatal.

## D1, claim by claim (real processes)

Bound, with a real sequence of `scripts/merge-lane.mjs` runs (`verify/retention-sequence.mjs`, 400 MB written
into each clone by a real gate command, temp root fenced to the harness, `WA_GATE_LANE=off`):

| run | default (`WA_MERGE_LANE_KEEP` unset) | `WA_MERGE_LANE_KEEP=all` |
|---|---|---|
| 1 | 400.0 MB, 1 dir, `budget_for_others=1/0` | 400.0 MB, 1 dir |
| 2 | 400.0 MB, 1 dir | 800.1 MB, 2 dirs |
| 3 | 400.0 MB, 1 dir | 1200.1 MB, 3 dirs |

Disk cost per run: run 1's free-space delta 409,884 KiB, runs 2–3 only 584 and 180 KiB — the bound is
observable in the filesystem, not only in the JSON. **Where my numbers differ from theirs:** they report
409/409/409 bounded and 810/1211/1612 unbounded, i.e. ~405–409 MB per clone against my 400.0. Same shape,
same one-clone step; the ~5–9 MB per clone is their per-clone overhead (their fixture clone carries more git
object data than mine). Their 1612 MB is 3 clones + the base ~400 MB, which my 1200.1 MB matches exactly in
step, not in absolute value.

* passing run: `verdict=pass`, `exit 0`, `clone.removed=true`, family `[]`, 0 bytes — the clone really is gone,
  and it does not delete the failure beside it (family stays at the one leftover, 400.0 MB).
* `WA_MERGE_LANE_KEEP=0`: `exit 3`, family `[]` (a red gate with nothing to re-run, as documented).
* `WA_MERGE_LANE_KEEP=twelve`: `exit 4`, `WA_MERGE_LANE_KEEP must be a non-negative whole number or 'all'`.
* **live lease, node side** (`verify/liveness-node.mjs`, 17/18 checks — the one FAIL was my own inverted
  expectation, see below): two clones leased by a live process are never candidates even at `keep=0`;
  a live 6 MB clone is held back; a pre-lease name younger than an hour is kept and one 3 h old is pruned;
  a directory of another family is untouched; some other live process's pid in a name is kept (safe direction,
  i.e. a reused pid leaks rather than deletes).
* **live lease, concurrent run** (`retention-sequence.mjs` E): a 600 MB clone owned by a live process survived
  a real failing lane run that swept both before and after (`sweeps=[{live:1,removed:0,kept:0},{live:1,removed:0,kept:0}]`);
  the run kept its own beside it. This is the property the claim exists for, on real processes.
* The one FAIL in my node harness was my assertion, not their code: with `currentKept=true` the budget for
  *others* is 0, so an older dead clone is pruned too — the run keeps exactly one clone (its own). The commit
  says this ("the bound counts the current run's own artifact"); I had written the opposite expectation.

Gate home (D1's `scripts/test.sh` block, sliced at its own marker and run with a one-line body,
`verify/gate-home-liveness.sh` — the delivered bytes, not a paraphrase):

* a failing run exits 3 through the EXIT trap, keeps exactly 1 home, and narrates what it removed;
* a passing run removes its own home, prints `smoke ok …` as its **last** line and nothing on stderr;
* a live sibling's home survived even as the *oldest* candidate (Cygwin pid, `kill -0` says alive);
* `WA_GATE_HOME_KEEP=all` grows the family (+2 for two runs); `=0` removes its own; `=maybe` exits 4 with the rule named.

**Limitation 1 (latent, real, not triggered by the real minter).** The shell half's liveness predicate is
Cygwin `kill -0`:

    kill -0 "$pid" 2>/dev/null && continue ;;          # a live sibling's home is never a candidate

I proved it is namespace-bound: for a live **native Windows** pid (a real `node` process, pid 40276)
`kill -0 40276` → **not alive** and `/proc/40276` does not exist, and a home named
`wa-gate-home-40276-LLLLLL` (the oldest candidate, 400-minute mtime) was **pruned** by a passing run; for a
live Cygwin bash pid (49002) `kill -0` → alive and the home survived. The only minter of that family is
`test.sh` with `$$` (a Cygwin pid) and the checker is Cygwin bash, so the delivered path is safe — but anyone
who names a gate home after a node/Windows pid (the way D1's *clone* family already does,
`wa-merge-lane-<process.pid>-…`) gets a live tree deleted. D1's own test uses `$!` from bash, i.e. it tests
only the namespace where this is true. Second asymmetry, same predicate: the shell treats *any* `kill`
failure (including `EPERM`) as dead, while the node half treats `EPERM` as live (`cloneOwner`).

**Limitation 2 (follow-up, not a false claim).** D1's own suite is not run by the gate: `scripts/test.sh`
mentions `test-merge-lane-retention.mjs` only in comments — `grep -rn "test-merge-lane-retention" scripts/test.sh`
matches lines 98 and 148, both prose. The file itself says so ("wiring … is what puts it in the gate"), and
D2 wired *its* three tests in at the same place, so the merge is clean and the wiring is a one-line edit. As
delivered, the retention policy can regress without a red gate.

## D2, claim by claim (real processes)

* **The floor passes on this machine**: `bash scripts/check-disk-floor.sh` in its own tree → `exit 0`,
  `floor: 3.71 GiB (3987386368 B)`, `free: 70.13 GiB of 476.83 GiB on /tmp`, and `--json` gives
  `{"floor_bytes":3987386368,"available_bytes":75302961152,"total_bytes":511987150848,"mount":"/tmp","path":".","ok":true,…}`.
  This was the fail-safe check that mattered: a floor that refused a healthy 70 GiB disk would have bricked
  every gate on the node. It does not.
* **The refusal, forced the way the task asks (floor raised above real free space, in a COPY; the delivered
  file is hash-identical before and after — `77791eed…` / `757fe866…` verified at the end of the run).**
  `bash scripts/test.sh` with `FLOOR_BYTES=1099511627776`: **exit 1 in 279 ms**, stdout first lines
  `disk floor check / floor: 1024.00 GiB … / free: 69.06 GiB of 476.83 GiB on /tmp`, and on stderr
  `FAIL: the build refused to start: it needs ~1024.00 GiB free space and has 69.06 GiB (1099511627776 B needed, 74147966976 B available on /tmp).`
  Exactly **one** refusal line, **zero** `cargo` invocations anywhere in stdout/stderr, **zero** gate homes
  left behind, and nothing built. `scripts/test.sh:3` is `set -euo pipefail`, so the refusal is fatal rather
  than advisory, and it is the gate's first act (`scripts/test.sh:19`) — before the environment fence and
  before the first `cargo`. No retry loop.
* **Distinguishable from a red gate?** Honest answer: *not by exit code*. A failing suite also exits 1
  (`grep -n 'exit 1' scripts/test.sh` → lines 223, 248, 283, 359, 1317, 1333, …). What distinguishes it is the
  text (`FAIL: the build refused to start`), the numbers it names, and the fact that nothing was built
  (279 ms, no cargo). Corollary worth naming for the reviewer of the *next* delivery: inside the merge lane
  the refusal is not distinguishable either —
  `verify/refusal-chain.sh` with a real `scripts/merge-lane.mjs` gating a tree whose floor refuses:
  `verdict=gate_failed`, `lane exit=3`, `gate exit=1`, clone **kept**, and the lane's log ends on
  `for what can be freed.` The lane has a distinct verdict for a lane-slot refusal (`gate_refused`, exit 6)
  but none for a disk refusal, so a disk refusal is attributed to the *change* — the exact misattribution the
  incident was about.
* **The false-refusal defect (my main finding against D2).** `bash scripts/check-disk-floor.sh --path /` →
  `check-disk-floor: cannot measure free space at / (df said: 'C:/Program Files/Git   499987452 426449404  73538048      86% /')`,
  **exit 3**, with 69 GiB actually free. Cause, at `scripts/check-disk-floor.sh`:

      df_line="$(df -Pk "$path" …)"
      total_kb="$(printf '%s' "$df_line" | awk '{print $2}')"
      avail_kb="$(printf '%s' "$df_line" | awk '{print $4}')"

  The Filesystem field is assumed to be a single word; Cygwin's root mount string is `C:/Program Files/Git`,
  so `$2` is `Files/Git` and the guard rejects the line. The trigger is not exotic: the same script run as a
  copy outside a repo cds to `dirname $0/..` = `/` and lands on that mount (I hit it on the first run). The
  same positional assumption is in `scripts/reclaim-disk.mjs::freeSpace()` (`Number(fields[1])`,
  `Number(fields[3])`) — that file's comment says only the *mount* may contain spaces. Suggested change for
  its own delivery (not made here): read the fields from the right (`awk '{print $(NF-2)}'` for available with
  `-P`, or `df -Pk --output=avail,target`), and assert the parse by feeding it the Cygwin root line. Note the
  script's own header says an unmeasurable disk is refused rather than assumed healthy — that policy is sound;
  what is wrong is that a parse quirk, not a full disk, is what triggers it.
* **Its own tests**: `node scripts/test-disk-floor.cjs` → `disk floor ok (28 checks, 0 skipped; refusal names
  75302002688 B free against a 3987386368 B floor)`; `test-temp-retention-check.cjs` → `ok (7 checks …)`;
  `test-reclaim-disk.cjs` → `ok (23 checks; pruned an ended session's target, kept the live, unrecorded,
  canonical and lane targets)`. All exit 0. Its tests are wired into `scripts/test.sh` (lines 1640–1650 of the
  combined tree).
* **The leak check** on its own tree and on the combined tree: PASS, 36 deferred, 0 resolved.
* **`/health` is not in this delivery, and the commit message says so.** `git diff --stat` against `rust/`,
  `ui/`, `lua/`, `docs/` is **empty for both branches**. The body is built only in
  `rust/wa-host/src/serve.rs:736 fn health_body()`, and it carries no disk field, so there is no free/total to
  verify and no existing field changed (nothing changed at all). The "free/total in `/health`" claim exists in
  the task's framing of D2, not in D2. What does carry the numbers is `check-disk-floor.sh --json` (shape above).
  I did not and cannot verify the live `/health` body over HTTP without starting/querying the node (out of scope).
* **Unclaimed side effect (disclosed in prose, invisible in the diff): a live job was written into the node's
  job store.** Read-only `wa-sentinel job list` shows `disk-reclaim`, `enabled: false`, `revision: 1`,
  `trigger {kind: event, topic: disk.reclaim}`, `action.script = C:/Users/Victor/AppData/Local/wasm-agent/scripts/reclaim-disk.sh`.
  Two facts about it that neither the diff nor the commit states: (a) that script path **does not exist**
  (`fs.existsSync` → false; the installed `…/wasm-agent/scripts/` has no `reclaim-disk.sh` or
  `check-disk-floor.sh`), so enabling the job today would run nothing; (b) `scripts/deploy.sh:557` installs
  job definitions from `"$ROOT"/jobs/whatsapp-*.json` only, so `jobs/disk-reclaim.json` is never installed by
  a deploy — it is a manual `job put`, exactly like the already-live `jobs/delivery-admission.json` of another
  lane (existing convention, so not a fault of D2's, but the reclaim pass has **no trigger**: the topic
  `disk.reclaim` is emitted nowhere in the tree, the job is disabled, and nothing installs it).

## Convergence

`git merge-tree --write-tree`, no side effects on any branch:

| merge | result |
|---|---|
| `origin/main` + D1 | clean (tree `db4d3658…`, no conflicts) |
| `origin/main` + D2 | clean |
| D1 + D2 | clean |
| both onto `origin/main` | clean — a real two-parent merge in my throwaway clone auto-merged `scripts/test.sh` only |

In `treeCombined`: `bash -n scripts/test.sh` OK; the file carries **both** changes (floor call at line 19,
`GATE_HOME_KEEP` + trap at 79–147, the retention/floor tests wired at 1640–1650); `check-temp-retention` PASS;
`check-disk-floor` exit 0. So the two deliveries do not merely apply — they compose. (A sibling lane is
concurrently rewriting `scripts/test.sh`; that is a fact about the sibling's work, not a conflict between these
two commits, and I did not test against the sibling's tree.)

## The gate (item 7): one attempt, polluted and interrupted, and why

Gate-lane status was checked before and after, both attempts ran one at a time (never two of mine), and the
lane was already occupied by a sibling for the whole window:

* before attempt 1 (13:19Z): `1 of 1 slot(s) held … 3 waiting`, slot #145 running mode=acquire held 1013 s.
* before attempt 2 (13:45Z): `1 of 1 slot(s) held … 1 waiting`.
* free space: **71,531,380 KiB (68.2 GiB) before attempt 1**, **70,089,224 KiB (66.8 GiB) before attempt 2**
  (the fall is other lanes' builds; D2's 3.71 GiB floor was never in question).

**Attempt 1, D1's tree (`/tmp/rev/treeB1`, its own commit c78ab731), 13:19:02Z → 13:39:46Z (1244 s): exit
127, no suite verdict, no skip count.** The log's last productive line is the Rust build completing after
10 m 16 s, and the next command in `scripts/test.sh` (`node scripts/test-parallel-finish.mjs`, the nested
fixture gate) is where the run stopped. Cause, and it is an environment fault rather than a delivery fault:
the installed `~/.wasm-agent/skills/parallel-evolution/scripts/finish.mjs` was stale and did not pass
`GATE_LANE_HELD` into the gate it spawns, so a nested fixture gate waited on the slot its own parent held. I
reproduced that wait independently in the same tree: `node scripts/test-parallel-finish.mjs` ran **300 s with
zero output** before I killed it. The coordinator has since replaced the skill with the repo's copy
(sha `129fabc56c44256a`). So attempt 1 is **not** evidence about either delivery: it never reached a suite.

What attempt 1 *does* show, as real behaviour of D1's policy on this machine rather than on a fixture: the
EXIT trap ran on the 127, kept its own home (`/tmp/wa-gate-home-61110-z9DePd (kept: this run exited 127,
WA_GATE_HOME_KEEP=1)` - a failing run keeps its own), and pruned **11 real homes** in the OS temp root: ten
pre-lease names (`wa-gate-home-uF5H92`, `-M1dcfj`, `-g0t3zE`, `-9E5psF`, `-h6lnLJ`, `-sblnzK`, `-ObeYur`,
`-v3pTZN`, `-sGNROX`, `-uVzY6F`) and one lease-shaped name whose owner was already dead
(`wa-gate-home-1212-KowbJ2`). Exactly one leased removal was logged, and the sweep only logs a removal for a
candidate whose pid read as dead, so the liveness rule held here; my 13:17 inventory had seen a single live
lease (its pid was not recorded), and by 13:47 no live lease remains while every lease-shaped home now has a
dead owner - consistent with the sibling gate that held slot #145 having ended, not with a live removal.
Pre-lease leftovers fell 99 → 94 across the run, i.e. 11 removed and ~6 minted again by sibling lanes running
pre-change code in the same window.

**Attempt 2, same tree, 13:45:45Z → 14:04:39Z (1134 s, 18.9 min), `GATE_LANE_HELD=1` (the marker a held
gate inherits, so the nested fixture gate does not queue behind a sibling): exit 0, verdict line
`smoke ok (2 skipped)`, free space 70,089,028 KiB → 69,577,284 KiB (66.8 → 66.4 GiB).** The gate lane still
showed `1 of 1 slot(s) held, 0 waiting` afterwards, i.e. a sibling gate held the slot across my run, so this
is a real result but **not a clean isolated timing** (the machine had two gates on it). Skips, named: the
gate's own count is **2** (`smoke ok (2 skipped)`); the run also reports `node instances ok (62 checks,
1 skipped)` and `termux launcher: 8 passed, 1 skipped`.

Two things this real gate showed that the sliced harness could not:

1. **D1's own retention suite did not run in it**: `grep -c test-merge-lane-retention gate-B1-run2.log` → **0**.
   The policy ships unguarded by the gate, confirmed end to end rather than by reading `test.sh`.
2. **The passing gate did not remove its own home.** Run 2's own home is named in its log
   (`wa-gate-home-65888-PIyjpM`, `birthtime 13:45:45.575Z` = the run's start) and it was **still on disk 22
   minutes after exit 0**: `du -sk` → **22,446 KiB (21.9 MB**, which also confirms their "gate home 21 MiB"
   measurement), contents `.rustup` and `.wasm-agent`. A hand `rm -rf` of it a moment later **succeeded
   immediately (exit 0)**, so the failure was transient - a descendant of the suite still holding a handle
   inside the home when the EXIT trap ran, which Windows refuses to unlink, and the passing path is silent on
   purpose (`rm -rf "$home" 2>/dev/null`, and a pass prints nothing). Their own comment anticipates the
   fallout ("a home that survives this is one whose pid is already dead, so the next sweep removes it"), but
   the claim as written - "a passing run removes its own artifact" - is **best-effort on a real gate, and
   silently so**. Cost per occurrence: up to 22 MB, bounded by the next gate's sweep. The same run also
   pruned the family **silently** (a pass narrates nothing): `wa-gate-home-*` went 96 dirs (13:47Z, 94
   pre-lease + 2 leased) → **10** (14:07Z, 8 pre-lease + 2 leased), i.e. ~86 stale pre-lease homes removed by
   one passing gate, keeping the newest candidate and the homes inside the hour's grace. That is the bound
   doing real work on the real leak, at the cost of being invisible in the log unless the run failed.

Per the coordinator's note this review does not depend on a gate: the merged candidate gets one at the merge
gate. Everything above stands on real runs of the delivered code.

## D1's pre-lease grace is shorter than the queue (reproduced live-run deletion)

The claim: "A name with the pre-change shape has no pid to ask about, so it is pruned only once it is an hour
old - a rollout cannot delete the clone of a run the previous script started" (`scripts/merge-lane.mjs`,
BOUNDED RETENTION comment; `LEGACY_GRACE_MS = 60 * 60 * 1000`).

Three facts make that grace the wrong length for this machine, and one experiment shows the consequence:

* the gate lane's own wait budget is longer than the grace — `scripts/merge-lane.mjs:377` names a budget of
  `WA_GATE_LANE_WAIT_SECONDS`, **2 h by default**, against a 1 h grace;
* a clone is made *before* the slot is waited for (`cloneRepo` runs at the top of the run; `laneAcquire`
  happens inside the gate step), and a slot wait of **4909 s and 5399 s** is in today's `gate-lane status`;
* nothing inside the clone refreshes the clone root's mtime while it waits — the sweep reads `fs.statSync(dir).mtimeMs`
  of the clone directory itself.

Evidence on the real machine, in the same pass: `os.tmpdir()` currently holds **87 pre-lease
`wa-merge-lane-*` directories, 1910.3 MB, 69 of them older than an hour**, the newest created 2026-09-30T13:14Z
— i.e. every other lane is running pre-change code right now, which is exactly the rollout window.

`verify/legacy-grace-live-run.mjs` holds a REAL pre-change lane run alive (main's `merge-lane.mjs`, its gate
sleeping), ages its clone to 2 h the way a long slot wait does, puts a newer dead leftover beside it (keep=1
keeps the newest), and runs c78ab731's own `sweepClones` over that root. Three runs, same result:

    sweep record: {"keep":1,"live":0,"kept":["wa-merge-lane-Cand01"],"removed":["wa-merge-lane-FTNh4X"],…,"errors":[]}
    live run's clone after the sweep: exists=false
    live run's exit: 4; its own gate reported: (no probe line)
    RESULT: THE LIVE RUN'S CLONE WAS DELETED by the sweep while its owner was alive

(the live run's pid was 70804 and it was inside its gate; the victim exited **4** - the lane's refusal path -
with no gate verdict line, which is the unattributed failure this rule exists to prevent). Note the benign
variant I first ran, for honesty: if the aged live clone happens to be the *newest* candidate, keep=1 keeps it
and nothing is lost — the deletion needs one newer leftover, and the real temp root has 69 of them.

Fix (not made here, belongs in its own delivery): stop using age as a stand-in for liveness for the pre-lease
shape. The commit itself names the authority - "the gate lane's slot row, not this lease, is the authority on
which gates are live" - so either consult the gate lane's live slot rows before pruning a pre-lease name, or
skip the pre-lease shape entirely until the family holds none, and in any case set the grace above the lane's
own wait budget (2 h default) rather than below it.

## D2's reclaim pass: age decides for temp, and it deletes a live process's directory

`verify/reclaim-falsify.sh` (scratch temp root; session store a scratch path with no rows, so the
`rust/target` half refuses every candidate and cannot touch anyone's worktree) with `--apply`:

| fixture (age) | outcome |
|---|---|
| `wa-subagent-test-Aged02` (15 h, dead) | **REMOVED** |
| `wa-subagent-test-Fresh1` (10 min) | LEFT — `fresh: younger than --min-age-hours 6` |
| `wa-merge-lane-Aged01` (7 h) | LEFT — `another lane's retention rule: a merge-lane clone: scripts/merge-lane.mjs owns its retention` |
| `wa-gate-home-Aged01` (7 h) | LEFT — `the gate's retained home: scripts/test.sh keeps it…` |
| `wa-sentinel-Aged01` (7 h) | LEFT — `never expired by rule: the sentinel watches this path while it runs` |
| `wa-not-a-tracked-family-SomeId` (7 h) | LEFT — `not matched to a known family (left alone): 1 entries` |

The pass is report-first, it names every decision, and it defers to D1's families in exactly the words above —
this is the contradiction check's answer from the other side, and it is clean.

The gap: **there is no liveness rule for temp families at all.** `NEVER_EXPIRE` holds one entry
(`wa-sentinel-`). Second experiment: a directory `wa-subagent-test-Live01` created and written by a live
process (pid 64792, `held.open` open and fsync'ed), whose mtime was then aged past the window -
`--apply` reported `expired: 1 entries, 33 B … wa-subagent-test* n=1 33 B oldest=7h … removed=1` and both the
directory and the file the live process held were gone. It is realistic rather than theoretical: a
long-running process that appends to a file *inside* its family keeps the file's mtime fresh, not the
directory's, so the directory ages while its owner is alive. Exposure today is low (report-only by default,
and the job is disabled and unfireable), but if that job is ever enabled with `WA_RECLAIM_MODE=apply` it is a
live-process deletion path. Fix (own delivery): the same lease discipline D1 uses for its families (a pid in
the name, or the pass's own `--protect`), or skip a family whose owning pid is alive, as its `rust/target`
half already refuses a live session's tree.

## What else I could not verify

* A genuinely low disk (forbidden by the task): the floor's refusal was forced by raising the floor, never by
  filling the disk. The 3.98 GB constant itself — a one-run measurement on 2026-09-30 — I cannot re-derive
  without a 20-minute timed run on a tree with no `rust/target`, and it is their measurement, not mine.
* ~~The reclaim pass's `--apply` behaviour on a real live family~~ — done, above: `verify/reclaim-falsify.sh`
  plus the `wa-subagent-test-Live01` experiment. What remains unverified is the same behaviour on the real
  machine's 13,075 other `wa-*` families (I did not run `--apply` against the real temp root or anyone's
  worktree; the session half would have touched other lanes' trees).
* only one gate ran on one tree (D1's). D2's tree was not gated: its three new suites (28 + 7 + 23 checks) and
  its floor were run individually instead, and the merge gate will cover the merged candidate. No gate time
  here is a clean measurement - a sibling gate held the lane's only slot across both of my attempts.
* `/health` over HTTP (the node's own endpoint), for the reason above.
* The `disk-reclaim` job firing: its topic is emitted nowhere and the job is disabled; I did not emit it (that
  would be driving live state).

## Running log

* pass 1: convergence, D1's bound and liveness, D2's floor/refusal/leak check, `/health`, the job's live row.
* pass 2: D1's pre-lease grace falsified three times against a live pre-change run; D2's temp expiry
  falsified against a live process's directory; real temp-root inventory (99 pre-lease leftovers, 2.0 GB).
* pass 3: the gate on D1's own tree — see "The gate" above.
