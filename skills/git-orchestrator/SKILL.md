---
name: git-orchestrator
description: >-
  Converge committed repository branches into main when /merge is invoked or the
  owner asks for integration. /merge all explicitly includes open PRs, including
  outside contributions. Discover exact tips, review, integrate, gate, push and
  re-audit in one run. Preserve every worktree and local ref; verify source alignment.
---

# The git orchestrator

Invoking `/merge` designates you as the integrator and authorizes reviewed merges
and the push to main. The ordinary human-handoff restriction is suspended for
this task - and the guard agrees with the role and not with the command:
`.githooks/pre-commit` refuses a direct commit on `main` from a `child` task
whatever it exports, and allows it from a session's own run
(`WASM_AGENT_PROVENANCE=orchestrator`, exported by the host). Do not hand routine
integration back to another integrator or stop at a plan. Load
`skills/parallel-evolution/SKILL.md`; its convergence escalation is
addressed to you and its "Landing on `main`" section is this task's last mile.
Keep LF, provenance, tests and all existing work.

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
  someone else's unfinished files to satisfy this command. Preserve all worktrees,
  including detached benchmark worktrees, from synchronization and cleanup.

The audit and the final gate are the slowest expensive phases. Use their measured times and counts to decide whether later work should reduce redundant review/proof, parallelize independent review, or serialize only the short shared-write phase. Do not claim speedup from one run; retain baseline/candidate JSON from the same fixture set and compare medians, conflict counts, and gate reruns. Historical phase times are unknown unless an actual artifact records them.

A suitable bounded workflow is: parallelize read-only review of independent tips, then serialize exact integration of overlapping tips in a short-lived candidate branch. Never run multiple writers against the same checkout, main, a shared ref, or the same staging index. Preserve source-bound gate evidence only when the exact Git tree matches; any changed tree requires a new gate.

`/merge` and `/merge all` authorize integrating reviewed commit tips and enforcing the remote main-only invariant below. Delete only exact non-main remote refs after proving they are integrated and no open PR depends on them. Preserve every local ref and worktree, including dirty drafts, detached benches and worktrees where the branch is already merged; do not synchronize or delete local refs/worktrees.

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

`audit` reports per-phase milliseconds, tip/conflict/worktree counts, and
`integration_complete` independently from verification. `gate_proof` reports
whether the current HEAD tree has a valid source-bound gate receipt and log hash,
and the saved gate run count; it never runs the test gate. `verify` exits nonzero
unless discovery is complete, every in-scope tip is integrated, the current tree
has valid gate evidence, the fetched `origin` refs match a fresh
`git ls-remote --heads origin`, and the only remote head is `main` at the target
SHA. Gate proof is evidence only for that tree; it does not replace required human review or the full final gate when source changes. It does not delete a ref. Re-fetch/repeat for late arrivals. A valid final manifest plus exact-tree gate and remote-main proof
establishes integration completion. Do not infer it from names of refs or a
model-written summary.

Use the exact JSON timings/counts from an `audit`/`verify` result and the closing
`finish.mjs gate` receipt for measurements. Keep a baseline result (for example,
from the preceding revision) and candidate result for the same fixture/worktree
and remote layout; compare `timings_ms`, `counts`, `gate_ms`, `skipped`, and
`gate_exit`. This measures wall time and work avoided, not correctness by itself.
No historical baseline is implied by adding telemetry.

## 4. Enforce remote main-only; preserve local work

After the tested candidate is published and the final audit is clean, `origin`
must have exactly one branch: `main`. This is a required postcondition of `/merge`
and `/merge all`. Read the exact remote `refs/heads/*` tips; for each non-main
remote branch, prove its exact tip is an ancestor of the tested `origin/main`,
confirm no open PR still depends on it, and recheck that its remote tip has not
moved immediately before deleting that exact remote ref with a normal, non-force
deletion. Never wildcard-delete or delete `main`. If any tip moves, arrives late,
is not integrated, or belongs to an unresolved PR, stop cleanup and re-audit/review
it. `verify` checks without changing refs and succeeds only when the current
source tree has exact-tree gate evidence and fresh `git ls-remote --heads origin`
shows `refs/heads/main` at the tested SHA and nothing else.

The remote invariant does **not** authorize local cleanup. Preserve all local
branch refs and worktrees—including dirty drafts, live, locked, detached and clean
merged worktrees. Do not synchronize, retire, delete, or move any worktree; report
its state separately. Never discard unfinished files. A separate cleanup request
is required for local ref or worktree changes.

## Report three independent outcomes

1. **Integration:** complete or blocked, scope (`internal` or `all`), final main
   SHA, merged/excluded/blocked exact inputs, review and gate verdict/skips.
2. **Worktree synchronization:** none by default; list observed worktrees as
   preserved and any separately requested sync as a distinct task.
3. **Branch cleanup:** remote non-main refs removed only under the explicit rule
   above; all local refs/worktrees retained with concrete reasons.

Say `Integration complete; local workspace synchronization deferred for ...`
when in-scope commits reached tested/pushed main and the remote invariant passes,
even when local drafts or worktrees remain. Never call integration complete if a
real in-scope commit, PR review requirement or discovery error is unresolved.
