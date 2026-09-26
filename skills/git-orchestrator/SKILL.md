---
name: git-orchestrator
description: >-
  Integrate every open branch of this repository into main as the designated git orchestrator:
  audit all branches, merge the ones that merge clean, run the gate on the merged result, push,
  sync every worktree, and delete the branches that are now in main. Use when asked to "merge all
  branches", "orchestrate the merges", "act as git orchestrator", "integrate the lanes", "clean up
  the branches", or when the board shows more than one open change branch. This is the role that
  may merge to main; ordinary work may not.
---

# The git orchestrator

You are the repository's integrator. The owner designates this role by invoking `/merge` (or by
asking in words). **That designation suspends the `AGENTS.md` rule that "agents hand off a branch
and the human merges":** for this command you may merge to `main`, and you may enter the main
checkout and the other worktrees to converge them. Every other rule still holds - keep LF, end
every commit with its provenance trailer, run the gate, never hand a POSIX path to a native Windows
process, never restart a node to patch it.

The goal is convergence in **one run where safely possible**: merge every eligible open branch,
gate and push the result, then report worktree/branch cleanup. A branch that cannot merge or a
dirty/independent worktree is escalated, never forced. Escalation means **partial completion**; do
not delete or relabel unresolved work to make the board look clean. The general per-turn rules are
in `skills/parallel-evolution/SKILL.md`; this file is the integrator's half of them.

## 1. Audit before touching anything

Read-only. Fetch first. Inspect **local and remote** `change/*` refs, since an open branch may exist
only locally or only remotely. Do not serialize `path:branch` pairs or split on `:` (Windows drive
letters contain colons). Use `git worktree list --porcelain` as structured records; paths and
branch refs are separate fields.

```sh
git fetch origin --prune
git worktree list --porcelain
git for-each-ref --format='%(refname)' refs/heads/change refs/remotes/origin/change
```

For each unique candidate ref, record its exact tip, compare it to `origin/main` with
`git rev-list --left-right --count origin/main...<ref>`, and check mergeability with
`git merge-tree --write-tree origin/main <ref>`. Treat exit 0 as clean and nonzero as a result to
classify—not automatically a harness failure. Keep the command's actual error/output so a missing
ref or invalid invocation is not mislabeled as a conflict. Re-fetch and re-audit before merging;
refs may move during the run.

- `ahead 0` -> already contained in `main`; candidate for deletion only after the explicit safety
  checks in step 6.
- A local-only ref is still open work. If the same branch name exists both locally and remotely,
  compare tips; report divergence instead of silently choosing one.
- `CONFLICT` -> classify it before touching it. An **additive-only** conflict (both sides are
  independent additions - different keys, adjacent insertions, a line neither side is rewriting)
  may be resolved by you as the **union**: keep both sides verbatim, and say in the merge message
  that you did. Anything that touches a **shared value** - the same key, the same line's meaning,
  a schema, a wire format, one side deleting what the other adds - is escalated, not resolved.
  Never force it. Recency is not a tie-breaker: the newer side is usually the one that never saw
  the other's work, so resolving by timestamp silently drops it (measured: an additive conflict
  resolved "latest wins" would have unregistered another branch's fixture test, and the gate would
  still have been green, because nothing cross-checks that every `scripts/test-*.cjs` is registered).
- **Subsets:** if every commit of A is in B (`git merge-base --is-ancestor A B`), merge B only,
  but retain/delete A only under the safety checks in step 6.

## 2. Merge the clean ones, one at a time, in the main checkout

```
git -C <main-checkout> fetch origin
git -C <main-checkout> merge --no-ff --no-edit -m "merge(change/<name>): <what it brings>" origin/change/<name>
```

Merge into `main` in the main checkout. `--no-ff` on purpose: a branch cut from the current
`main` would otherwise fast-forward, and the integration would lose its named merge commit - the
provenance this repository reads from the merge's second parent. A merge is allowed where a direct
commit is not, and its subject must name the branch it merged. **After each merge, re-check the
next branch against the new `main`:** two branches that each merge clean against the old base can
still collide with each other. If a merge stops on a conflict, classify it the same way: `git merge
--abort` and escalate anything that touches a shared value; an additive-only conflict may be
resolved in the merge itself, as the union, saying so in the merge message.

A branch may move while you work, and a new lane may appear. **Re-fetch and re-audit after the last
merge**; if a tip advanced and still merges clean, merge the new tip too. Loop until no eligible
branch remains; unresolved branches are explicitly escalated, not silently treated as integrated.

## 3. Gate the merged result

Run the repository's gate (`bash scripts/test.sh`) **on merged `main`**. A merge is not done
because it applied cleanly; it is done when the gate passes with it in. If the gate fails, do not
push: bisect the merges, drop the one that broke it, and report which one and how.

## 4. Push

```
git -C <main-checkout> push origin main
```

## 5. Sync worktrees conservatively

A worktree is **not** safe to move merely because it is behind `main`. Read
`git worktree list --porcelain`; for each target, inspect status and its current branch. Do not
switch, reset, clean, or merge into a dirty tree. Do not move a worktree off an independent branch
just to make it match `main`.

Only fast-forward a clean worktree already on its designated base/name branch, after verifying it
has no unique commits (`git rev-list origin/main..HEAD` is empty). If a worktree is on a merged
change branch, return it to its designated branch only when that branch exists and the worktree is
clean; then fast-forward. Otherwise leave it untouched and report the exact blocker. Detached
benchmark worktrees are not ordinary actor worktrees; leave them alone unless explicitly in scope.

```sh
git -C <worktree> status --short --branch
git -C <worktree> fetch origin
git -C <worktree> merge --ff-only origin/main
```

Never leave a tree on a branch other than the one it is named for **as a desired end state**, but
never switch a live/dirty/independent tree to achieve that state without its owner's authorization.

## 6. Delete branches only after proving safety

Never bulk-delete a wildcard expansion. For **each exact ref**, prove it is an ancestor of the
current `main`, confirm no worktree is checked out on that branch, and ensure local and remote tips
do not diverge. Delete local refs individually with `git branch -d <name>` and remote refs
individually with `git push origin --delete <name>`. If any check is inconclusive, keep the ref and
report it. Do not delete unmerged/escalated refs or a branch merely because its name starts
`change/`.

```sh
git merge-base --is-ancestor <exact-ref> origin/main
git worktree list --porcelain
git branch -d <local-name>
git push origin --delete <remote-name>
```

Keep `main` and the branches that carry a node's name. A branch on a dirty or independent worktree
is not deletable even if another ref with the same name appears merged.

## 7. Report

One line per branch - merged / already in / escalated - plus exact refs deleted, gate verdict and
the new `main` commit. For a conflict you resolved, name both sides and the union you applied, so
the next reader sees a decision rather than a merge that quietly picked one. Name anything you
could not prove. Then say what moved since the last convergence, so the next run starts from the
truth rather than from memory.

## Done means

Convergence may be partial when a branch or worktree is safely escalated. Never claim full
completion unless every applicable property below is proven; report each unmet property and why.

| property | how to prove it |
| --- | --- |
| union | every open `change/*` ref is either an ancestor of `main` or explicitly listed as escalated |
| gate | `bash scripts/test.sh` passes on merged `main` |
| pushed | `git rev-parse HEAD` equals `git ls-remote origin refs/heads/main` |
| synced | each in-scope actor worktree is clean, on its intended branch, and equal to main or explicitly reported as blocked/exempt |
| clean board | no merged, safe-to-delete `change/*` ref remains; unresolved refs are listed, not hidden |
| nothing lost | each merge named its branch; nothing was force-resolved or squashed |
