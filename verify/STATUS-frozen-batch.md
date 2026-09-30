# Frozen batch: status of the integration attempt

Integrator: `child:dispatch:db0ce06c-05ff-4f77-b4af-e1919e14e392` (profile `task-worker`,
`WASM_AGENT_PROVENANCE=child`), own session worktree
`change/wa-session-childdispatchdb0ce06c-05ff-4f77-b4af-e1919e14e392`.
Integration checkout: `<session worktree>/integrate-frozen-batch`, branch `integrate/frozen-batch-20260930`,
created fresh from `origin/main` = **ab827c88a6ac091318b5adb8be34e83e858c4e9a** (this file is committed
before the gate and before any publication attempt, on purpose).

## Manifest (exactly these four tips, this order - nothing widened or reordered)

| # | tip | source branch | merge commit |
|---|---|---|---|
| 1 | `3290d327` | `change/codex-admission-platform` | `1d4fc20` |
| 2 | `1d5f7ca1` | `change/review-codex-admission-platform` | `3596343` |
| 3 | `5ab4683` | `change/bg-responsiveness` | `f21fe7e` |
| 4 | `7e2ab2c3` | `change/review-bg-responsiveness` | `da8dc89` |

`git fetch origin --prune` run first. Every merge by **exact SHA** with `--no-ff` and subject
`merge(<short-sha>): <source branch>`. **No conflicts**: nothing had to be resolved and no side was chosen.

**Merged HEAD: `da8dc8918a34c880768956ff775d883802dcb7a7`**
**Tree: `09ba73f1e087c8ca1e576deaac8d9a738fe85a46`**

## Verification (step 2)

* `git status --short` → empty.
* `git merge-base --is-ancestor <sha> HEAD` → YES for all four tips (`3290d327`, `1d5f7ca1`, `5ab4683`,
  `7e2ab2c3`).
* LF invariant, by the gate's own command (`.githooks/pre-commit:125`, `scripts/test.sh:1517`):
  `git grep --cached -I -l "$(printf '\r')"` → **0 files**. (A merge does not run pre-commit, so it is
  checked here explicitly.)
* Nothing else was merged, cherry-picked, rebased, deleted or force-updated. The refused pair
  (`c78ab731`/`72530c58`, the disk/retention deliveries) and the held `dcf49653` were **not** touched.

## Gate (step 3): PENDING

Run as `node <integration checkout>/skills/parallel-evolution/scripts/finish.mjs gate <worktree> <merged-sha>`
so the slot is acquired and `GATE_LANE_HELD` reaches the nested fixture gates. Filled in below when it ends.

## Publication (steps 4-5): see the note below before reading any tree hash as published

Coordinator's precondition of step 4 was re-checked at the time of writing: `origin/main` still
`ab827c88a6ac091318b5adb8be34e83e858c4e9a`, so no concurrent publisher and no moved base.

One fact has to be recorded before anything else about the publish: **this process is a bounded child**
(`WASM_AGENT_PROVENANCE=child`, printed by the host), and the repository's own integration guard refuses
exactly that actor the integration decision:

* `.githooks/commit-msg`: "Refuse an agent's commit on the integration branch" - on `main`/`master` a commit
  carrying `Agent: wasm-agent …` with `provenance: child` is refused with "a child task does not hold the
  integration decision, so it does not move main", and it states that `WASM_AGENT_ALLOW_MAIN` is
  deliberately not consulted for that case.
* `.githooks/pre-commit`: "a child task cannot *directly commit* on `main`".
* The same hook text points at the branch handoff as the route: "Your branch is the deliverable … push it,
  and report; the orchestrator merges it."

The hooks do allow a *merge* commit on `main` from anyone (a merge's provenance is its parents, accepted when
its subject names the branch), and there is no `pre-push` hook - so a child *could* move `main` here. That is
recorded as the hole it is, not used. Moving `main` is outside this task-worker's standing limits ("never …
merge main"; the session branch is the one I own), so the publish is left to the orchestrator with the tested
commit and tree above, and the exact landing command is in the closing note.
