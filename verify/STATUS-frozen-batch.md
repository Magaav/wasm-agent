# Frozen batch: integration status (merged + gated; publication REFUSED, with reason)

Integrator: `child:dispatch:db0ce06c-05ff-4f77-b4af-e1919e14e392` (profile `task-worker`; host says
`WASM_AGENT_PROVENANCE=child`), own session worktree
`change/wa-session-childdispatchdb0ce06c-05ff-4f77-b4af-e1919e14e392`.
Integration checkout: `<session worktree>/integrate-frozen-batch`, branch
`integrate/frozen-batch-20260930`, created fresh from `origin/main` = **ab827c88a6ac091318b5adb8be34e83e858c4e9a**.

## 1. Manifest - exactly these four tips, this order, nothing widened

| # | tip | source branch | merge commit |
|---|---|---|---|
| 1 | `3290d327` | `change/codex-admission-platform` | `1d4fc20` |
| 2 | `1d5f7ca1` | `change/review-codex-admission-platform` | `3596343` |
| 3 | `5ab4683` | `change/bg-responsiveness` | `f21fe7e` |
| 4 | `7e2ab2c3` | `change/review-bg-responsiveness` | `da8dc89` |

`git fetch origin --prune` first. Each merge by **exact SHA** with `--no-ff`, subject
`merge(<short-sha>): <source branch>`. **No conflicts** - nothing was resolved and no side was chosen.
The refused pair (`c78ab731`/`72530c58`) and the held `dcf49653` were not touched; no branch was deleted;
no other worktree was touched; the canonical checkout was only ever read (`git -C … rev-parse`).

**Merged HEAD `da8dc8918a34c880768956ff775d883802dcb7a7`, tree `09ba73f1e087c8ca1e576deaac8d9a738fe85a46`.**

## 2. Verification

* `git status --short` → empty.
* `git merge-base --is-ancestor <tip> HEAD` → YES for all four tips.
* LF invariant by the gate's own command (`.githooks/pre-commit:125`, `scripts/test.sh:1517`):
  `git grep --cached -I -l "$(printf '\r')"` → **0 files** (a merge does not run pre-commit, so it is run here).
* `git merge-base --is-ancestor origin/main HEAD` → YES, so an `--ff-only` move of `main` yields exactly this tree.

## 3. Gate - GREEN, one run, alone in the slot

`node skills/parallel-evolution/scripts/finish.mjs gate <integration checkout> da8dc8918a34c880768956ff775d883802dcb7a7`
invoked from the repository's own copy, whose sha256 is **`129fabc56c44256ae70986aa…`** (the fixed copy: it
carries `GATE_LANE_HELD`; blob `7183769d0435b8460024ecd4c9c07f0b5eb9b4cd`, identical to the installed
`~/.wasm-agent/skills/…/finish.mjs`).

| fact | value |
|---|---|
| finish.mjs exit | **0** |
| `repository_ready` / `gate_verified` | `true` / **`true`** |
| gate exit / skip count | **0** / **2** |
| verdict line (last line of the gate log) | `smoke ok (2 skipped)` |
| tested head / tree | `da8dc8918a34c880768956ff775d883802dcb7a7` / `09ba73f1e087c8ca1e576deaac8d9a738fe85a46` |
| equivalence | `git_tree`, `gate_reused: false`, `gate_runs: 1` |
| gate duration | `gate_ms: 1540924.787` (25.7 min) |
| gate log | `C:\Users\Victor\orca\projects\wasm-agent\.git\worktrees\integrate-frozen-batch\wa-finish-gate.json.log` |
| gate log sha256 | **`34308c29ea98443f967015e6f9aaf7d6cff4fea89912c04f7574260766ea7891`** (112,137 bytes) |
| slot | `#164` granted after **734.8 s** waiting, `mode=slot`, label `finish integrate/frozen-batch-20260930` |
| free space | 67,578,304 KiB (64.4 GiB) before → 66,038,988 KiB (63.0 GiB) after |

**Alone in the slot**: capacity is 1 and the lane's own history for my window shows two other lanes
*refused* for want of it - `#165 … refused after 600s waiting`, `#163 … refused after 240s waiting` - and
`done #164 finish integrate/frozen-batch-20260930 exit 0: … "smoke ok (2 skipped)"`. The first sibling gate
(`#162`) finished before I was granted; no gate of mine ever ran twice and none ran concurrently with another
of mine.

Named skips behind the count of 2: the gate reports `termux launcher: 8 passed, 1 skipped (POSIX mode
semantics unavailable on Windows); Android build and runtime skipped on this non-Android host`, and the
verdict line carries the total (`2 skipped`).

**One refused attempt before this, recorded because it cost nothing and explains the sequence**: the first
`finish.mjs gate` invocation exited 0 after 2.2 s **without running the gate** - every check passed except
`pushed` (`"publish this branch with its own upstream; observed origin/main"`), because the branch had been
created tracking `origin/main`. No slot was taken. I then published the branch
(`git push -u origin integrate/frozen-batch-20260930`, remote now
`da8dc8918a34c880768956ff775d883802dcb7a7` - the finished tool requires exactly this) and ran the gate above.

## 4. Publication: REFUSED - not attempted, and this is the point of this file

**Nothing was pushed to `main`. `main` is where I left it: local and remote both
`ab827c88a6ac091318b5adb8be34e83e858c4e9a`.**

The task's step-4 *preconditions were met*: re-read after the gate, `origin/main` is still
`ab827c88a6ac091318b5adb8be34e83e858c4e9a`, the four tips are still **not** contained in it, and the remote
`refs/heads/main` still reads `ab827c88…`. So this is not the "base moved / concurrent publisher" stop
condition, and it is not a gate failure. I stopped on **authority and route**, on four independent grounds:

1. **The host says this process is a bounded child** (`WASM_AGENT_PROVENANCE=child`, printed by the host,
   not typed by me). My standing limits for this profile include "never … merge main", and the session
   branch is the one I own.
2. **AGENTS.md**: "**A lane owns its tree; only the merge lane moves `main`.** … a delivery an independent
   reviewer verified, whose own tree passed the gate, is merged and pushed by the merge lane, which is
   authorised to land deliveries without asking each time."
3. **`skills/git-orchestrator/SKILL.md`** (the protocol's own home) says the same and then names the tree:
   "**Who may move `main`: the merge lane, and only the merge lane.** A lane is a role a *run* takes …" (l.27);
   "**The merge lane lands in one sanctioned tree**: the canonical checkout, the only worktree whose branch
   is `main`, addressed by absolute path (`git -C <canonical> …`) - **never …in a lane's own worktree**" (l.37);
   the sanctioned push is `git -C <canonical> push origin main` followed by a
   `git -C <canonical> ls-remote origin refs/heads/main` read-back (l.243); and "**One landing at a time**:
   the merge lane is the only writer on `main` in that tree" (l.207).
4. **The route this task specified is itself outside that protocol**: it directed the merge, the gate and the
   publish from a worktree **in my own workspace** rather than the canonical checkout. I could follow it only
   by writing to the canonical checkout (which my limits also forbid: "never edit another checkout"), so I did
   neither and report instead. No judgement call was hidden in this: the manifest was frozen, and the one
   place a conflict could have appeared (step 1) had none.

What is *not* a blocker, recorded so nobody has to guess: the repository's `.githooks` would **allow** a merge
commit on `main` from any actor (a merge's provenance is its parents, accepted when its subject names the
branch), and there is no `pre-push` hook - the hook text itself names that hole and says the unskippable
boundary is remote-side. So this stop is a rule I am holding, not a door that was locked. The refusal is
therefore cheap to reverse by the actor that owns the integration decision.

### What the landing actor needs (exactly, in the canonical checkout)

```
git -C C:/Users/Victor/orca/projects/wasm-agent fetch origin
git -C C:/Users/Victor/orca/projects/wasm-agent merge --ff-only da8dc8918a34c880768956ff775d883802dcb7a7
git -C C:/Users/Victor/orca/projects/wasm-agent rev-parse HEAD^{tree}   # expect 09ba73f1e087c8ca1e576deaac8d9a738fe85a46
git -C C:/Users/Victor/orca/projects/wasm-agent push origin main
git -C C:/Users/Victor/orca/projects/wasm-agent ls-remote origin refs/heads/main   # must equal rev-parse HEAD
```

Why this is safe and cheap: `origin/main` is an ancestor of the merged HEAD, so `--ff-only` cannot change the
tested tree, and the receipt above is against exactly that tree - per the protocol, when
`git -C <canonical> rev-parse HEAD^{tree}` equals the tree a receipt names,
`node skills/parallel-evolution/scripts/finish.mjs verify <canonical> <merged-HEAD>` **re-checks the receipt
instead of re-running the gate**. If `main` moves before this lands, the tree changes and the receipt no longer
covers it: gate again (one gate per tree, `docs/CONCURRENCY.md`).

The artifact is reachable: `refs/heads/integrate/frozen-batch-20260930` on `origin`
(`da8dc8918a34c880768956ff775d883802dcb7a7`), and the commits are in the canonical repository's object
database (the integration checkout is a linked worktree of it). I published that branch because the repo's own
`finish.mjs` requires a branch with its own upstream before it will gate one; it is not a change to `main`.
The integration worktree and its branch are **left in place** for the landing actor - deleting branches is
outside this task.

## 5. Publication verification: NOT PERFORMED (consequence of 4)

No published `main` sha and no published-tree equality proof exist, because nothing was published. The
tree-equality argument that *would* hold is the ff-only one above; it is an argument, not a read-back.

## What I could not verify

* The published `main` sha and `git rev-parse main^{tree}` equality (step 5) - publication refused, so there is
  nothing to read back.
* That the four tips' own receipts remain valid on their own trees (not this task's scope; each branch's
  receipt was taken by its own lane).
* Whether any *other* actor holds the integration decision right now - `docs/CONCURRENCY.md` reserves the gate
  and the landing, and I did not query a reservation for `main` (the canonical checkout showed
  `main` == `origin/main`, clean, 0 ahead / 0 behind, which is all I read).

## Cost, side effects, and what is left running

* Gate: 25.7 min of the reserved slot, free space 64.4 → 63.0 GiB (other lanes' builds moved it too).
* A sibling lane (`389b8886`) was refused a slot twice while I held it, with a third attempt running after me:
  the reservation worked as designed, and my one run was not concurrent with another gate of mine.
* New, left behind on purpose: worktree `<session worktree>/integrate-frozen-batch` (untracked in my branch
  worktree, which is why my branch's `git status` shows it), branch
  `integrate/frozen-batch-20260930` (local + origin), and the gate log named above.
* Nothing was restarted, reconfigured, deployed, force-pushed, or deleted.
