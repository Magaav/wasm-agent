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

The goal is convergence in **one run**: **`main` becomes the union of every open branch, the gate is
green on it, every worktree is current with it, and no `change/*` branch is left open.** A branch
that cannot merge is escalated, never forced. The general per-turn rules are in
`skills/parallel-evolution/SKILL.md`; this file is the integrator's half of them.

## 1. Audit before touching anything

Read-only. Never merge a branch you have not checked.

```
git fetch origin --prune
git worktree list
for b in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin/change); do
  git rev-list --left-right --count origin/main...$b
  git merge-tree --write-tree origin/main $b >/dev/null 2>&1 && echo clean || echo CONFLICT
done
```

- `ahead 0` -> already in `main`; nothing to merge, but it is still a branch to delete (step 6).
- `CONFLICT` -> stop and escalate that branch; do not force it.
- **Subsets:** if every commit of A is in B (`git merge-base --is-ancestor A B`), merge B only.
  Merging a branch that is a subset of another double-counts the same work.

## 2. Merge the clean ones, one at a time, in the main checkout

```
git -C <main-checkout> fetch origin
git -C <main-checkout> merge --no-edit -m "merge(change/<name>): <what it brings>" origin/change/<name>
```

Merge into `main` in the main checkout. A merge is allowed where a direct commit is not, and its
subject must name the branch it merged. **After each merge, re-check the next branch against the
new `main`:** two branches that each merge clean against the old base can still collide with each
other. If a merge stops on a conflict, `git merge --abort` and escalate that branch.

A branch may move while you work, and a new lane may appear. **Re-fetch and re-audit after the last
merge**; if a tip advanced and still merges clean, merge the new tip too. Loop until the audit is
empty - this is what keeps the work to one run instead of two.

## 3. Gate the merged result

Run the repository's gate (`bash scripts/test.sh`) **on merged `main`**. A merge is not done because
it applied cleanly; it is done when the gate passes with it in. If the gate fails, do not push:
bisect the merges, drop the one that broke it, and report which one and how.

## 4. Push

```
git -C <main-checkout> push origin main
```

## 5. Sync the worktrees

Every worktree should be current with `main`. A worktree sitting on a merged `change/*` branch
returns to the branch that carries its name first, then comes forward:

```
git -C <worktree> fetch origin && git -C <worktree> merge --ff-only origin/main
```

Never leave a tree on a branch other than the one it is named for. A fast-forward is the strongest
form of "no regression": it cannot drop or rewrite a commit.

## 6. Delete the branches that are now in main

The lifecycle is merge-and-delete: a merged `change/*` branch is clutter that makes the board lie
about how much is open. Delete it once it is an ancestor of `main` and no worktree is on it (step 5
returned every worktree to its name branch).

```
# remote - only the ones that are merged
git push origin --delete $(git for-each-ref --format='%(refname:short)' refs/remotes/origin/change)
# local - -d refuses an unmerged branch, which is the safety net
git branch -d $(git for-each-ref --format='%(refname:short)' refs/heads/change)
```

Keep `main` and the branches that carry a node's name (the worktree branches). Never delete a
branch that is not an ancestor of `main`: that is someone's unmerged work, escalated in step 1, not
removed here.

## 7. Report

One line per branch - merged / already in / escalated - plus what was deleted, the gate verdict and
the new `main` commit. Name anything you could not prove. Then say what moved since the last
convergence, so the next run starts from the truth rather than from memory.

## Done means

All of these are true, and you can state each as a fact:

| property | how to prove it |
| --- | --- |
| union | every `change/*` is an ancestor of `main` (`ahead 0`) |
| gate | `bash scripts/test.sh` passes on merged `main` |
| pushed | `git rev-parse HEAD` equals `git ls-remote origin refs/heads/main` |
| synced | every worktree is `0 behind / 0 ahead` of `main`, clean, on its name branch |
| clean board | no `change/*` branch remains, local or remote |
| nothing lost | each merge named its branch; nothing was force-resolved or squashed |
