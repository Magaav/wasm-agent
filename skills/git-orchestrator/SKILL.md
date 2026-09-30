---
name: git-orchestrator
description: >-
  The merge lane's runbook and the one home of the integration protocol: who may
  move main, the lifecycle (produce -> verify -> accept -> land -> deploy), the lanes
  and their reservations, and the landing steps. It runs continuously - a delivery an
  independent reviewer verified, whose own tree passed the gate and whose branch is
  current with origin/main, is landed without asking - and /merge and /merge all are
  manual entry points into the same procedure that widen its input scope, /merge all
  explicitly including open PRs and outside contributions. Discover exact tips,
  review, integrate, gate, push and re-audit in one run. Preserve every worktree and
  local ref; verify source alignment.
---

# The git orchestrator - the merge lane's runbook

**This file is the one home of the integration protocol.** `AGENTS.md` states each of its rules in
one line and points here; `skills/parallel-evolution/SKILL.md` is the producer's per-turn loop;
`docs/CONCURRENCY.md` owns the lane reservations; `docs/FACTORY.md` is the batch ledger, and its
own "The landing procedure" section is to be replaced by a pointer to this one. Keep LF, provenance,
tests and all existing work.

## The integration protocol

### The authority statement

**Who may move `main`: the merge lane, and only the merge lane.** A lane is a role a *run* takes,
not a person and not a session - the run the owner is talking to when it lands, a run started as
`/merge`, and any run opened for integration all take the same lane, and taking it is what
authorises reviewed merges and the push to `main`. **Merging a delivery is authorised without
asking each time**: a delivery an independent reviewer verified, whose branch is current with
`origin/main`, and whose own tree carries a passing gate receipt, is landed by the lane on its own.
A coordinator merging each delivery by hand is the bottleneck this lane removes.

- **A producer or reviewer lane never moves `main`.** Its branch is its deliverable, and handoff is
a push, not a merge.
- **The merge lane lands in one sanctioned tree**: the canonical checkout, the only worktree whose
branch is `main`, addressed by absolute path (`git -C <canonical> ...`) - never by switching the
lane's own worktree onto `main`, and never in a node's or a producer's worktree.
- **One unlanded editor per hot file** - a file many branches touch (`scripts/test.sh`, a shared
module, this protocol). Not one per batch: every other concern runs in parallel, and the hot file's
change lands first because that is the shortest path to unblocking the rest.
- **A direct commit on `main` (no merge) is the exception**: it belongs to the run of a session, it
is for `main`'s own change (a document, a version bump), and it carries the trailer like any other
commit. The guard enforces this case and no other.

**What a landing must carry.** A landing missing any of these is not a landing:

1. the **reviewer's independent verdict** on the exact tip, from a lane that did not produce it
   (an agent's report is evidence, not verification - `docs/FACTORY.md`, invariant 1);
2. the **merged tree's own gate receipt** - exit status, skip count, log hash, and the tree it is
   bound to - because a merge changes the tree and the branch's receipt covers only the branch (no
   effect before its proof - invariant 2);
3. the **provenance trailer** on every commit, and a merge whose subject names the branch it merged;
4. the **ref read back from the remote** after the push, never the push's own output;
5. the **delivery's record** (`scripts/delivery-record.mjs`): a landing starts from the delivery's record,
   and the admission rule (`scripts/delivery-admission.mjs check`) is what says a delivery may enter the
   lane. The record holds the reviewer's verdict on that exact tree and the admission decision, and the
   lane writes its own outcome and the landing sha back into it.

**What the guard does, exactly.** `.githooks/pre-commit` and `.githooks/commit-msg` decide the
*direct commit* case from the host's provenance - `WASM_AGENT_PROVENANCE=orchestrator` for a run of a
session, `child` for a bounded subagent task, empty for a person at a terminal - so the guard agrees
with the role and not with the command. That is all it claims: a client-side hook is **convenience,
not a boundary** - measured on git 2.55.0.windows.3, `--no-verify`, `git -c core.hooksPath=<empty>`,
`git cherry-pick`, `git revert`, `git rebase --onto`, a detached-HEAD commit, a hand-written
`.git/MERGE_HEAD`, and `git update-ref refs/heads/main <sha>` all skip or fool it.
`WASM_AGENT_ALLOW_MAIN=1` stays the human's explicit override and does not open a direct commit on
`main` for a child. **The boundary that cannot be skipped is remote-side**: branch protection on
`origin/main`, or a pre-receive check that refuses a direct update. Until one of those exists, this
procedure is what makes a landing *reviewable*, not what makes it impossible to bypass. Which
remote-side boundary, and who may push `origin/main`, is **not decided here** - naming it is the
change required, and making it is not this lane's call.

### The lifecycle, stated once

```
produce -> verify -> accept -> land -> deploy
```

- **produce** - a producer lane: its own worktree, its own `change/<name>` from current `origin/main`,
one delivery (adjacent concerns may join it - see "Steering a warm lane"), committed with its
provenance trailer and pushed. Its branch is its deliverable.
- **verify** - a reviewer lane that did **not** produce the branch: read the diff and its intent,
  attack the claim on the exact tree, re-run what proves it, and report what it broke.
- **accept** - the delivery carries evidence bound to one exact tree: the reviewer's verdict plus a
  gate receipt naming that tree. Nothing proceeds on a claim.
- **land** - the merge lane: merge the reviewed tip onto the sanctioned tree, gate the **merged**
  tree, push `origin/main` under the sole lock, read the ref back, prove integration, then clean up.
- **deploy** - the sentinel, queued from inside a run and never run in that run's own turn:
  `wa-sentinel request upgrade` for the node and UI, `wa-sentinel request deploy` when the change is
  in the sentinel itself, each with `--session`/`--prompt`, then read `installed.txt` and
  `deploy-result.json` rather than the request's receipt (`skills/self-update/SKILL.md`).

### The lanes and what each may do

| lane | it may | it may not |
| --- | --- | --- |
| producer | edit, commit, push `change/<name>`, run the gate on its own tree, ask to be landed | move `main`, merge, deploy, accept or review its own delivery, move another actor's tree or ref |
| reviewer | read the diff and the tree, re-run fixtures and the gate, falsify the claim, report | change the producer's branch, land, accept its own work |
| gate | run `scripts/test.sh` / `finish.mjs gate` on one tree at a time and record the receipt | run against the same tree as another gate, or claim evidence for a tree it did not test |
| merge | merge reviewed tips, gate the merged tree, push `origin/main`, read the ref back, prove integration, clean up the branch it landed | force-push, merge an unreviewed or unverified tip, delete another actor's refs or worktrees, deploy, move `main` from a producer's tree |

How many lanes run at once, and why the gate is a reserved serial resource, is
`docs/CONCURRENCY.md` ("Lane reservations and the serial gate"): the target is 16-32 lanes with a
few reserved for verify/gate/merge, so a delivery never waits behind producers, and a lane count is
raised only with the measurement named there.

### Steering a warm lane

New work that is **adjacent** to what a live session is already doing belongs *in that session*.
Steer it - `steer` for an active session, `message` for a queued follow-up - instead of restarting
it or spawning a sibling lane to do the neighbour work. A warm session keeps its context, its
worktree, its branch, its evidence and its unsent state; a new one re-derives all of it, which is
the expensive path (measured on this node: 3-15M prompt tokens for a child to get back to where the
warm one already is). Adjacent means the same subsystem, the same files, the same evidence, the
same causal chain.

The bounds still hold, and they are what keeps "warm" from meaning "unbounded":

- **No unrelated drift** - a concern that is not adjacent gets its own session, and the brief says
  why.
- **No recursive feedback chain** - at most one bounded improvement and one review per original
  task.
- **One delivery, not one idea.** A branch that ends up carrying several adjacent concerns is
  acceptable: it is reviewed **per commit** and lands as one delivery. The trade is atomic landing
  - one failed commit holds the whole branch - not a rule violation, and "one concern per branch"
  is not a gate a steered warm lane fails.

### Manual entry points

`/merge` and `/merge all` are entry points into **this** procedure, not its trigger: they designate
the run as the merge lane and widen the inputs (step 1). The lane does not wait for them - a delivery
that passed review and its own gate is landed when it is ready. Do not hand routine integration back
to another integrator or stop at a plan. Load `skills/parallel-evolution/SKILL.md`, whose
convergence escalation is addressed to you; this file is the last mile.

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

A suitable bounded workflow is: parallelize read-only review of independent tips, then serialize exact integration of overlapping tips on the sanctioned tree. Never run multiple writers against the same checkout, main, a shared ref, or the same staging index. Preserve source-bound gate evidence only when the exact Git tree matches; any changed tree requires a new gate.

`/merge` and `/merge all` authorize integrating reviewed commit tips and enforcing the remote main-only invariant below. Delete only exact non-main remote refs after proving they are integrated and no open PR depends on them. Preserve every local ref and worktree, including dirty drafts, detached benches and worktrees where the branch is already merged; do not synchronize or delete local refs/worktrees.

## The landing steps

Each step names the command whose output proves it; a step whose output you cannot show is a step you
did not do.

### 1. Discover inputs with the audit

Use the loaded skill directory (the installed node copy can be newer than a
producer's checkout) and a native absolute repository path:

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

### 2. Review the tip, then merge it onto the sanctioned tree

Merge in the sanctioned tree - the canonical checkout, the only worktree whose branch is `main` -
addressed by absolute path (`git -C <canonical> ...`); never switch your own worktree onto `main`, and
never merge in a node's or a producer's worktree. Probe an unclear overlap for free before making it:
`git merge-tree --write-tree origin/main <tip>` writes nothing. Then fetch and keep the tree current -
`git -C <canonical> fetch origin`, `git -C <canonical> merge --ff-only origin/main`; a tree that is
dirty or behind is refused here, not merged into. Review each pending diff and its intent against the
exact recorded SHA, and merge it by name - `git -C <canonical> merge --no-ff change/<name>` - or pass
the subject yourself:
`git -C <canonical> merge --no-ff <sha> -m "merge(change/<name>): what it brings"`. Measured on git
2.55: `git merge --no-ff <sha>` **alone is refused**, because git's default subject for a SHA merge is
`Merge commit '<sha>'`, which names nothing - that refusal is the rule (a merge whose subject names
its source), not an obstacle to route around. A refused merge leaves `MERGE_HEAD` in place, so abort it
(`git -C <canonical> merge --abort`) before trying again. Preserve both local and remote inputs; merge
a containing tip once when it subsumes others. **One landing at a time**: the merge lane is the only
writer on `main` in that tree, and two of them there are the sole-lock violation this lane exists to
prevent.

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

### 3. Gate the merged tree, then push under the sole lock

Re-run the audit against the merged HEAD with the same scope. Integrate new
or advanced tips until no in-scope pending tip remains. **The branch's receipt does not cover the
merge**: the branch's tree and the merged tree are the same object only when `main` has not moved since
the branch was cut - measured as identical in exactly that case, and different as soon as another
branch landed first, which is the ordinary case. Record `git -C <canonical> rev-parse HEAD^{tree}`; if
it equals the tree the branch's receipt names, that receipt is still evidence for that tree and
`finish.mjs verify` re-checks it instead of re-running the gate.

Otherwise run the gate on the merged HEAD - `bash scripts/test.sh` (exit 0, skips counted) or
`node skills/parallel-evolution/scripts/finish.mjs gate <canonical> <merged-HEAD>`, which records the
receipt against that exact tree. Retain its commit/tree and log. The gate has to run where the tree you
push lives, and it is a **reserved serial resource**: one gate per tree at a time
(`docs/CONCURRENCY.md`). A failure requires diagnosis and repair, or a named blocked input; do not
silently drop commits, reset shared main, or call a failed gate success.

Push and read the ref back - two facts, not one:

```
git -C <canonical> push origin main
git -C <canonical> ls-remote origin refs/heads/main   # must equal rev-parse HEAD
```

Fetch and re-audit after the gate. If a new tip changes the candidate, review,
merge and re-gate it. Publish only a passing, current candidate. A normal PR merge
or fast-forward of clean idle main to the tested candidate preserves its tree;
verify that equivalence and `origin/main`. Never force-push. If main or a producer
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

### 4. Prove integration, then clean up the branch you landed

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

Cleaning up is after the fact, never instead of it, and it is limited to the branch this landing
produced:

- **Prove the branch is integrated before deleting it.** `git -C <canonical> branch --merged main`
  lists `change/<name>`, or `git -C <canonical> merge-base --is-ancestor <tip> main` exits 0. Do
  **not** use `git branch -d` as that proof: measured on git 2.55, a branch whose tip is in its own
  upstream (`refs/remotes/origin/change/<name>`) but not in `main` is deleted by `-d` after a warning,
  not refused.
- **Let git refuse to give up unfinished work.** `git -C <canonical> worktree remove <path>` refuses a
  worktree with modified or untracked files (`contains modified or untracked files, use --force`), and
  that refusal is the check, so never reach for `--force`. `git worktree prune` is only for a worktree
  whose directory was already deleted by hand.
- **The producer's session releases its own worktree** - clean, inactive, merged - and keeps its branch
  and transcript. The merge lane never removes, switches or prunes another actor's worktree, and a
  `/merge` run leaves every local ref alone.

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

### What is measured, and what is policy

Measured in a throwaway clone against a bare remote on this machine (git 2.55.0.windows.3): the
sanctioned tree's checks (step 2); that `--no-ff` names the branch in the first-parent subject and
resolves `HEAD^2` **when the merge names a branch**, and that a SHA merge's default subject is refused
(step 2); that the merged tree equals the branch tree only when `main` has not moved, and differs when
it has (step 3); that `ls-remote` equals `HEAD` after the push (step 3); that `worktree remove`
refuses a dirty worktree while `prune` clears a hand-deleted one, and that `branch -d` deletes a branch
that is not integrated when it has an upstream (step 4). Policy, not verified anywhere: which machine
is authoritative, whether a PR review is required before step 2, and whether the cloud tree must be
pulled after the push. The cloud tree consumes what `origin/main` becomes; the canonical checkout is
where the pushed tree is built and gated.

**Before trusting any of this as enforcement:** see the authority statement above - the guard is
convenience, its bypasses are pinned as a recorded boundary in `scripts/test-main-guard.sh`, and
remote branch protection on `origin/main` or a pre-receive check is the thing to set up. Which one,
and who may push `origin/main`, is not this lane's decision to make.
