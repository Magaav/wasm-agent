---
name: git-orchestrator
description: >-
  The merge lane's runbook and the one home of the integration protocol: who may
  move main, the lifecycle (produce -> verify -> accept -> land -> deploy -> converge), the lanes
  and their reservations, and the landing steps. It runs continuously - a delivery an
  independent reviewer verified, whose own tree carries focused source checks and whose branch is
  current with origin/main, is landed without asking - and /merge and /merge all are
  manual entry points into the same procedure that widen its input scope, /merge all
  explicitly including open PRs and outside contributions. Discover exact tips,
  review, integrate, gate, push and re-audit in one run. Preserve live, dirty, unmerged and uncertain work; close an authorized wave through
  durable main-only convergence and verify the next-wave baseline.
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
`origin/main`, and whose own tree carries the producer proof required by admission, is admitted by the lane on its own. Routine shared runtime changes may carry actual focused checks with an independently anchored scope declaration. Only the user selects pre-release gating: source paths never infer a full or combined gate, and routine publication/deployment does not require one (`lane-policy.json`). Routine admission reports `gate_verified:false`, `release_verified:false`, and `requires_combined_gate:false`; an explicit pre-release claim still requires valid exact-tree full proof.
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
2. the **merged tree's own gate receipt** *when the landing is a release* - exit status, skip count,
   log hash, and the tree it is bound to - because a merge changes the tree and the branch's receipt
   covers only the branch (no effect before its proof - invariant 2). Since 2026-10-02 the full gate
   is a **release's**, not a landing's: an evolution landing is merged, LF-checked and reported
   (`--gate-mode none`, the default; `release_verified: false` in its JSON), and
   `scripts/wave-release.mjs` is what gates an exact tree, records the receipt and names it. What did
   not change is invariant 2 itself - a branch's receipt never covers the merge - so a release is
   gated on the merged tree it will certify, never on the branch it came from;
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
produce -> verify -> accept -> land -> deploy -> converge
```

- **produce** - a producer lane: its own worktree, its own `change/<name>` from current `origin/main`,
one delivery (adjacent concerns may join it - see "Steering a warm lane"), committed with its
provenance trailer and pushed. Its branch is its deliverable.
- **verify** - a reviewer lane that did **not** produce the branch: read the diff and its intent,
  attack the claim on the exact tree, re-run what proves it, and report what it broke.
- **accept** - the delivery carries evidence bound to one exact tree: the reviewer's verdict plus a
  producer receipt naming that tree. `finish.mjs admit <repo> <head>` produces the focused receipt; `delivery-admission.mjs check/admit --producer-proof <receipt>` validates it. It records `admission_verified=true`, `gate_verified=false`, and `requires_combined_gate=true`; admission never claims full verification. Activate this policy only after its bootstrap combined tree passes the prior full gate.
- **land** - the merge lane: merge the reviewed tip onto the sanctioned tree, gate the **merged**
  tree, push `origin/main` under the sole lock, read the ref back, prove integration, then clean up.
- **deploy** - the sentinel, queued from inside a run and never run in that run's own turn:
  `wa-sentinel request upgrade` for the node and UI, `wa-sentinel request deploy` when the change is
  in the sentinel itself, each with `--session`/`--prompt`, then read `installed.txt` and
  `deploy-result.json` rather than the request's receipt (`skills/self-update/SKILL.md`).
- **converge** - an explicitly authorized external finisher: pin exact inputs and owner settlements, reconcile operations/claims and runtime bindings, retire only proven integrated refs, then verify fresh main-only Git, exact installed source/artifact/skills, functional recovery and complete registries. `scripts/wave-lifecycle.mjs` persists this continuation; a wave is **ON while any child/agent for the repository is in flight and OFF when none is** (derived from the node's own session/turn records, never from the stored row), so an idle row never blocks starting the next wave while a wave whose convergence could not be verified stays a NAMED, visible state (see `docs/WAVE-CONVERGENCE.md`). No routine permission ping separates these already authorized stages.

### The lanes and what each may do

| lane | it may | it may not |
| --- | --- | --- |
| producer | edit, commit, push `change/<name>`, run the gate on its own tree, ask to be landed | move `main`, merge, deploy, accept or review its own delivery, move another actor's tree or ref |
| reviewer | read the diff and the tree, re-run fixtures and the gate, falsify the claim, report | change the producer's branch, land, accept its own work |
| gate | run `scripts/test.sh` / `finish.mjs gate` on one tree at a time and record the receipt | run against the same tree as another gate, or claim evidence for a tree it did not test |
| merge | merge reviewed tips, gate the merged tree, push `origin/main`, read the ref back, prove integration, retire explicitly handed-over settled wave inputs | force-push, merge an unreviewed or unverified tip, move an active actor's tree, deploy, move `main` from a producer's tree |

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
  including detached benchmark worktrees, until exact owner settlement and preservation evidence authorize retirement. An explicit wave includes safe local retirement; a manual merge alone does not move an unrelated active checkout.

The audit and the final gate are the slowest expensive phases. Use their measured times and counts to decide whether later work should reduce redundant review/proof, parallelize independent review, or serialize only the short shared-write phase. Do not claim speedup from one run; retain baseline/candidate JSON from the same fixture set and compare medians, conflict counts, and gate reruns. Historical phase times are unknown unless an actual artifact records them.

A suitable bounded workflow is: parallelize read-only review of independent tips, then serialize exact integration of overlapping tips on the sanctioned tree. Never run multiple writers against the same checkout, main, a shared ref, or the same staging index. Preserve source-bound gate evidence only when the exact Git tree matches; any changed tree requires a new gate.

`/merge` and `/merge all` authorize integrating reviewed commit tips and enforcing the remote main-only invariant below. Delete only exact non-main remote refs after proving they are integrated and no open PR depends on them. Live work stays owned. For an explicitly authorized wave, local refs and finished worktrees are retired only through the convergence procedure after accepted settlement; dirty drafts, unmerged tips and uncertain effects remain durable blockers. A manual merge alone does not broaden that authority.

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

### 3. Push under the sole lock; gate only for user-selected pre-release

For routine landings, keep the default `--gate-mode none`, source review, LF checks,
current bindings and exact ref readback. The full-gate instructions below apply only
when the user explicitly requests pre-release gating, never as a routine prerequisite.

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

### 4. Close the authorized wave with an external finisher

An explicit main-only wave supersedes the historical permanent-local-ref retention
policy. Establish the external finisher before closing the producer's own branch
or tree. Only the canonical checkout owns `main`; idle finished terminals and
benchmarks may be safely parked detached after their valuable work is reconciled.
No active, dirty, unmerged, locked or uncertain checkout is moved or discarded.
Age, zero output, an absent PID, cancellation and a UI card are not settlement.

Use `scripts/wave-audit.mjs` for a new read-only diagnostic artifact, preserving
manual `state.json.before-reconcile-*` originals. Complete discovery, independent
review and integration before retirement. Resource claims are reconciled through
the existing resource API with exact owner/run and inspected effects. Operations
use durable effective cwd/boot identity and the indexed relevant/reconcile API;
legacy identity uncertainty is explicit, never rewritten as execution success.

Use `scripts/wave-retire.mjs apply <exact-plan> <private-state>` only after the
fresh owner, dependency, operation and claim proofs in that plan pass. Its journal
records each effect before it runs and refuses to replay an ambiguous action.
Every exact tip must be an ancestor of accepted `main`; local deletion uses
`git update-ref -d <ref> <expected-tip>` after no worktree checks it out. A normal
non-force remote deletion uses a private pre-push guard, after existing pre-push
checks, to validate the remote SHA from that push's own advertisement. Receive-pack
then checks the old OID atomically; moving tips are refused and preserved. No
wildcards, force flags, reset, PR dependency bypass or image-name termination.
Runtime/Orca reconciliation has separate verified postconditions; deleting Git
refs alone cannot establish release.

`scripts/wave-lifecycle.mjs` owns ordered land/deploy/retire progress, operation
IDs, an OS-held boot lease, completion-triggered continuation, restart recovery,
bounded observation retry/backoff and an actionable blocked state. Effect commands
run through a real external operation driver (`scripts/wave-executor.lua`), never
through a node turn or a worktree being removed. Launch receipt, command exit,
zero resources released and queued deploy are not completion. A crash/uncertain
effect requires exact drain/effect evidence and observation before continuation;
no unknown effect is replayed automatically.

The final receipt proves, with fresh readback: only `main` in remote and shared
local refs; clean canonical main equal to origin/main; only clean integrated
released/detached finished trees; no unresolved deliveries, relevant operations,
claims, owners or unowned/unreconciled managed workspaces; Git/runtime agreement
over the node's OWN inventory (no third-party CLI is required or consulted); exact
combined full gate tree/log hash and counted skips; installed accepted
main/artifact/skills, healthy runtime
and verified functional recovery. Preserve canonical ignored build caches.
The next wave re-verifies this baseline; a previous passing receipt alone cannot
admit it. The manifest and proof adapter contracts are in
`docs/WAVE-CONVERGENCE.md`; missing adapters/inventories fail closed.

## Report independent outcomes

Report integration (exact accepted main/review/combined gate and skips), deployment
(exact installed source/artifact/skills and functional evidence), and convergence
(main-only refs, actual worktrees/registries, operation/claim/owner state and durable
receipt). A blocked wave retains an owner, exact reason and recovery path; it is
not called complete or left silently stalled, and it does not fence producing or
allocating whether or not agents are working - only landing and independent delivery
admission stay refused, by name, until its convergence is verified. A branch delivery can be complete
while independent review/merge/deploy/convergence remain owned by the coordinator.

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
