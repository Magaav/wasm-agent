---
name: git-orchestrator
description: >-
  Converge committed repository branches into main when /merge is invoked or the
  owner asks for integration. /merge all explicitly includes open PRs, including
  outside contributions. Discover exact tips, review, integrate, gate, push and
  re-audit in one run. Leave origin with only main after successful integration.
---

# The git orchestrator

Invoking `/merge` designates you as the integrator and authorizes reviewed merges
and the push to main. The ordinary human-handoff restriction is suspended for
this task. Do not hand routine integration back to another integrator or stop at
a plan. Load `skills/parallel-evolution/SKILL.md`; its convergence escalation is
addressed to you. Keep LF, provenance, tests and all existing work.

## Scope is explicit

- `/merge`: all committed local and remote branch tips, including actor/name
  branches, non-`change/` branches and local-only commits. Open PR work is excluded.
- `/merge all`: the same inputs plus every open PR head, including forks and
  branches absent from the local/origin branch list. Read each PR's diff, review
  status and required checks. This command authorizes review/integration, not
  bypassing branch protection or missing required approval. Draft status and
  requested changes require a concrete readiness decision, not automatic merging.
- A branch containing an excluded PR head is also excluded by ordinary `/merge`.
  Listing a PR is not permission to merge it. Never broaden scope silently.
- Uncommitted files are not branch tips. Never commit, stash, reset or discard
  someone else's unfinished files to satisfy this command. Detached benchmark
  worktrees are preserved and exempt from synchronization.

## 1. Discover inputs with the audit

Use the loaded skill directory (the installed node copy can be newer than a
worker checkout) and a native absolute repository path:

```
node <skill-dir>/scripts/audit.mjs audit <repo> origin/main
node <skill-dir>/scripts/audit.mjs audit <repo> origin/main --all
```

Use `--all` only for explicit PR-inclusive scope. The script fetches all remotes,
reads all local/remote branch refs, queries every page of open GitHub PRs, fetches
their exact heads, and reports deduplicated immutable tips. It parses worktree
records with NUL separators, preserving spaces and Windows drive letters. It
never merges, switches checkouts, edits files or deletes branches.

Read the JSON. `discovery_complete=false` is a real discovery failure, never an
empty queue. Fix the named fetch/GitHub error before claiming completion. PR
inspection remains necessary even when multiple refs share one SHA. Save the
manifest under your worktree's Git metadata for the final evidence.

`pending` means a committed input is not yet in the target; `contained` means
ancestry proves it is integrated; `excluded_pr` is outside ordinary `/merge`.
A local/remote name with divergent tips contributes BOTH tips. Review both and
integrate their union; divergence alone is not a reason to abandon that branch.
A dirty checkout does not prevent reading/reviewing/merging its committed tip
from another checkout. Do not confuse unique commits with uncommitted files.

## 2. Review and integrate to a clean staging branch

Use your own clean integration checkout on a short-lived `change/` branch from
current `origin/main`. Keep the main checkout and other workers available while
review/gating runs. Review each pending diff and its intent, and merge the exact
recorded SHA with `--no-ff` and a message naming its source branch or PR. Preserve
both local and remote inputs; merge a containing tip once when it subsumes others.

Recompute mergeability against the growing candidate after each merge. Resolve
mechanical overlaps and understood conflicts by preserving both intended effects;
inspect callers and tests. Never select a side solely by recency, blanket ours/theirs,
or force. For a genuinely ambiguous product/contract decision, retain both refs,
state the exact decision needed, and continue other independent inputs. You are
already the designated integrator; needing to read code is not an escalation.

For PRs, use the hosting service's required review/check policy. Do not evade a
required PR approval by merging its branch SHA through a different PR or direct
push. If protection requires individual PR merges, honor that sequence and
rebuild/gate the final combined candidate after any source-tree change.

## 3. Re-audit, gate and publish

Re-run the audit against the candidate HEAD with the same scope. Integrate new
or advanced tips until no in-scope pending tip remains. Run `bash scripts/test.sh`
on the exact combined candidate, counting skips. Retain its commit/tree and log.
A failure requires diagnosis and repair, or a named blocked input; do not silently
drop commits, reset shared main, or call a failed gate success.

Fetch and re-audit after the gate. If a new tip changes the candidate, review,
merge and re-gate it. Publish only a passing, current candidate. A normal PR merge
or fast-forward of clean idle main to the tested candidate preserves its tree;
verify that equivalence and `origin/main`. Never force-push. If main or a worker
keeps changing, report the concrete moving input rather than hiding the race.

Finally run:

```
node <skill-dir>/scripts/audit.mjs verify <repo> origin/main
# For /merge all, append --all here too.
```

`verify` exits nonzero for incomplete discovery or any unintegrated in-scope tip.
Re-fetch/repeat for late arrivals. A valid final manifest plus exact-tree gate and
remote-main proof establishes integration completion. Do not infer it from the
names of deleted branches or a model-written summary.

## 4. Enforce the remote main-only invariant

After the tested candidate is published and the final audit is clean, `origin`
must have exactly one branch: `main`. This is a required postcondition of both
`/merge` and `/merge all`, not optional housekeeping. A GitHub branch selector
lists refs, not PR state; merged branches remain visible until their refs are
deleted.

Before deleting, fetch and record every exact `refs/heads/*` tip on `origin`.
For each non-main ref, prove its tip is an ancestor of the tested `origin/main`
and confirm no open PR still depends on that head. Delete each exact ref
individually with a normal non-force push deletion, rechecking the remote tip
immediately before deletion. Never use a wildcard, delete `main`, or force-push.
If a tip moved, appeared late, is not integrated, or belongs to an unresolved PR,
stop cleanup, re-audit and integrate/review it as required. Do not claim complete
until a fresh `git ls-remote --heads origin` returns only `refs/heads/main`.
Enable the hosting provider's delete-head-branch-on-merge setting as defense in
depth; the explicit final audit and deletion loop still covers direct merges and
old refs.

This remote invariant does not authorize disturbing local worktrees. Active
worktrees may keep local branch refs while their task is live. Inspect each
checkout separately; preserve dirty, live, locked and detached trees and never
move the current executing workspace out from under its run. Retire a clean,
confirmed-idle worktree through its owner/lifecycle procedure, then delete its
local branch once no checkout uses it and its tip is contained in main. Report
remaining local refs and worktree reasons separately; they do not excuse leaving
non-main refs on `origin`.

## Report three independent outcomes

1. **Integration:** complete or blocked, scope (`internal` or `all`), final main
   SHA, merged/excluded/blocked exact inputs, review and gate verdict/skips.
2. **Worktree synchronization:** updated and deferred paths with concrete reasons.
3. **Branch cleanup:** prove `origin` contains only `main`; report local refs and
   retained worktrees separately with concrete reasons.

Say `Integration complete; workspace synchronization deferred for ...` only
when the tested main is current and the remote main-only invariant passes, even
if a dirty/live local tree remains. If any non-main remote ref remains, report
cleanup blocked and do not claim the command fully completed. Never force-delete
or discard local work to satisfy the invariant. Conversely, never call
integration complete if a real in-scope commit, PR review requirement or
discovery error is unresolved. Preserve those distinctions in the final response.
