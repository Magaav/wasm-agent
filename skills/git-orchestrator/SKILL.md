---
name: git-orchestrator
description: >-
  Converge committed repository branches into main when /merge is invoked or the
  owner asks for integration. /merge all explicitly includes open PRs, including
  outside contributions. Discover exact tips, review, integrate, gate, push and
  re-audit in one run. Report worktree synchronization and cleanup separately.
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

## 4. Synchronize and clean up without blocking integration

Report this as a separate phase. For each actor checkout, inspect its status,
branch and activity. Only fast-forward a clean, confirmed-idle branch whose tip
is already contained in main. Keep its branch identity; it need not be renamed
to the directory's name merely to receive main. A branch's unique committed work
must first be integrated by the earlier loop, not treated as a permanent blocker.
If no owner/activity evidence establishes idleness, preserve the checkout and
report deferred sync. Never move the current executing workspace out from under
its run. Dirty, live, locked and detached trees are retained with exact reasons.

Delete only disposable merged `change/` refs: re-read each exact tip, prove it
is in main, verify no checkout uses it, and check local/remote divergence. Keep
actor/name branches. Never wildcard-delete, force-delete or switch a live tree
just to delete its branch. Retaining a checked-out merged ref is not a failed
merge and never requires another `/merge` to integrate that same work.

## Report three independent outcomes

1. **Integration:** complete or blocked, scope (`internal` or `all`), final main
   SHA, merged/excluded/blocked exact inputs, review and gate verdict/skips.
2. **Worktree synchronization:** updated and deferred paths with concrete reasons.
3. **Branch cleanup:** deleted and retained refs with concrete reasons.

Say `Integration complete; workspace synchronization deferred for ...` when all
in-scope commits reached tested/pushed main but a dirty/live tree remains. Never
call that `orchestration partially complete`. Conversely, never call integration
complete if a real in-scope commit, PR review requirement or discovery error is
unresolved. Preserve those distinctions in the final response.
