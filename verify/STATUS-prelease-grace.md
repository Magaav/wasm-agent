# STATUS: repair of D1's pre-lease grace (branch `change/wa-session-childdispatch054d4d9b-...`)

Started from the delivery tip `c78ab73130b13c0da967b5ce7ce7d1f96d3f0301` ("factory(temp): bound the
clone and the gate home a failing run keeps"), base `origin/main` = `da8dc8918a34c880768956ff775d883802dcb7a7`.
Branch tip of this repair: this commit (the status commit) is the first commit of the repair.

Written BEFORE the code change, on purpose: this lane's predecessors died at the 7200 s window and
left nothing behind, so the first commit is the state of knowledge, not the fix.

## What is fixed

Nothing yet. The defect is accepted from the independent review
(`change/wa-session-childdispatchdb0ce06c-...`, tip `ab555f93`, `verify/REVIEW-disk-temp.md`, D1,
"the pre-lease grace is shorter than the queue") and is not re-litigated here.

The false sentence (merge-lane.mjs's BOUNDED RETENTION comment, and the same sentence in
scripts/test.sh's gate-home block):

> A pre-lease name is pruned only once it is an hour old, so a rollout cannot delete the clone of a
> run the previous script started.

The mechanism, as reproduced by the review: `LEGACY_GRACE_MS = 60 * 60 * 1000` is shorter than the
gate lane's own default wait budget (`WA_GATE_LANE_WAIT_SECONDS`, 7200 s), and the clone is made
before the slot is waited for, so a run merely queued for the gate has an aged-out clone.

## What is proven (at this commit)

* the delivery tip and its numbers are taken as given by two independent reviews; nothing here
  re-litigates them.

## What is unproven / not yet done (plan)

1. a live pre-change lane run's clone, deleted by `sweepClones` at `c78ab731` (reproduce),
2. the same clone surviving with the fix,
3. the queue case: a real slot held (in my own scratch gate-lane store, not the live one), a real
   run waiting, its clone surviving a sweep,
4. the bound still working: a stale pre-lease family is still removed, and `WA_MERGE_LANE_KEEP=all`
   still destroys the bound,
5. whether the rule covers an MSYS/Cygwin process's cwd (the shape a rename probe cannot see).

Scratch root for every experiment in this repair: `C:/Users/Victor/.wasm-agent/wa-repair-c78ab73/`.
No sweep in this repair ever runs against the real `~/.wasm-agent/wa-merge-lane-*` /
`wa-gate-home-*` families: every harness pins `TMPDIR`/`TEMP`/`os.tmpdir()` to that scratch root and
asserts it before sweeping.

`scripts/test.sh` (the whole gate) is NOT run by this repair, per its own constraint - another lane
holds the gate slot.
