---
name: parallel-evolution
description: >-
  How to change code on a branch while other people or agents may be changing the same
  repository, so your change stays current with the integration branch and merges without
  an integrator untangling it. Use at the start of every turn that edits code, before each
  commit, and before reporting done; also when a branch has drifted, when two branches
  overlap, or when deciding whether to resolve a conflict yourself or hand it to a
  third-party integrator.
---

# Evolving code in parallel

## Active operator-selected direct workflow

When `AGENTS.md` selects direct work, handle the human request serially without
subagents or external inference agents. Self-review is allowed and must be named
honestly. Use focused checks, ordinary Git integration through canonical main,
remote readback and clean trees. Do not create factory admission receipts or
run a full release gate unless requested. Preserve original unknown effects;
clean Git is not runtime settlement. The parallel procedure below applies only
when the operator re-enables it.

Verify this policy with
`node <repo>/scripts/test-direct-workflow-instructions.mjs`. It runs the complete
instruction checker plus private policy-removal mutations, not a full release gate.
Spell replay currently refuses mandatory session workspaces
(`workspace_execution_context_unsupported`); use the direct CLI without weakening
that binding or the original instruction byte budget. A refusal needs inspection,
not a blind retry or fabricated verification.

**wasm-agent policy (parallel mode):** routine merges use appropriate focused source checks and independent
exact-source review, including shared runtime changes. Only the user selects pre-release
gating (`lane-policy.json`); never infer a full/combined gate from paths. Gate/closing-spell
instructions below apply to explicitly requested pre-release verification. Routine work
reports `gate_verified:false`, `release_verified:false`, and no combined gate requirement.

You are one writer among several, and another branch may be editing the same file right
now. The integration branch (call it `main`) is the only shared truth; **your branch is a
proposal, not a copy of the project.** The goal is never "my branch works" — it is **"my
change merges cleanly onto today's `main`, and the gate still passes after it does."** A
change that is correct but three days stale is not finished work; it is a task handed to
whoever has to merge it.

If this repository has its own contributor rules (`AGENTS.md`, `CONTRIBUTING.md`), they
override this file. Read those first; this is the general procedure.

## One delivery per branch

- Cut a **short-lived** branch from current `main` for one delivery, and name it for that delivery.
  Adjacent work that arrives while it lives does not start a second branch: the warm session is
  steered and the branch carries both, because a branch is one *delivery*, reviewed per commit
  (`skills/git-orchestrator/SKILL.md`, "Steering a warm lane"). The trade is atomic landing - one
  failed commit holds the whole branch.
- A branch that lives a day cannot fall behind. A branch that lives a week will meet
  everything that landed meanwhile.
- **Unrelated** is the line, not "more than one". A concern that is not adjacent - a different
  subsystem, different evidence, no shared causal chain - gets its own note, issue or branch; do not
  fix it silently inside this one, and do not smuggle it in as "adjacent".
- Never commit to the integration branch: it belongs to the merge lane (see the mapping below).
  Never force-push a branch someone else may have built on.

## The per-turn loop

Run this **every turn that writes code**, not once per task.

**1. Sync before you read or edit.**
```
git fetch origin
git merge --ff-only origin/main      # or: git rebase origin/main
```
If that conflicts, stop here. That is the convergence signal (see below), not a step to
push through. If you are behind and skip this, you are building on a stale base and the
conflict only grows.

**2. Keep the diff small and local.**
Touch the fewest files that solve the concern. Do not reformat, rename, or reorganise code
you did not need to change: every unrelated line is a line someone else may also be
changing. Prefer additive edits over edits of shared lines.

**3. Re-sync immediately before you commit.**
`main` moved while you worked. Merge it in again, then **prove the result merges**:
```
git merge-tree --write-tree origin/main HEAD     # exit 0 = clean
```
Fix a conflict now, while the change is small and fresh in your head, not later.

**4. Run appropriate source checks; full gate only on explicit pre-release request.**
Whatever the repository uses as its test entry point, run it on the merged result. A
change is not done because it compiles; it is done when the repository's own check passes
with your change in it. If there is no gate, say so in your report.
In wasm-agent, the closing spell below supplies this gate after the candidate commit
and push, before integration. A published concern branch is still a proposal until it passes.

For a native Node `--test` suite, never infer its reporter from captured stdout.
Use `--test-reporter=tap` explicitly when collecting TAP. The verified helper
[scripts/node-tests.mjs](scripts/node-tests.mjs) takes absolute cwd, a fresh
absolute evidence directory, and explicit test files:

```
node <absolute-skill-dir>/scripts/node-tests.mjs <repo> <new-evidence-dir> <test-file> [test-file...]
```

It retains full stdout/stderr and a receipt with the actual process exit/signal,
TAP counts and hashes. Missing/duplicate/incomplete summaries, zero tests,
nonzero exits and timeouts refuse success. Skips/todos stay visible; decide
whether they satisfy the requested scope rather than calling them tested.
Never manufacture `status:0` from an old text log or rerun effects merely to
repair a format assumption. Existing evidence generations refuse overwrite.
This is a test collector, not a process-tree settlement certificate; external
long-lived descendants still require the operation supervisor. Validate with
`node <skill>/scripts/test-node-tests.mjs <absolute-evidence-scratch>`.
The recorded `node-test-tap-collect` spell uses shell-quoted runner/cwd/evidence/
file arguments and a JS string literal `receipt_js`; its post reads the retained
receipt rather than rerunning tests. Replay currently refuses mandatory worktree
bindings (`workspace_execution_context_unsupported`); it is not replay-verified
or preferred. Keep this verified CLI until actual spell postconditions pass.

**5. Commit one logical change.**
A small commit whose message says **why**, not what — the diff already says what. Include
the provenance trailer the repository requires (harness, node, session), or the commit
cannot be attributed later.

**6. End the turn clean.**
- Working tree clean, or a `wip(...)` commit that says exactly what is unfinished — never
  an uncommitted edit.
- Branch pushed.
- Branch current with `main`.
- A one-line status: what changed, ahead/behind, does it merge, does the gate pass.

### The wasm-agent pre-release closing spell

In wasm-agent, use [scripts/finish.mjs](scripts/finish.mjs) for the mechanical
closing sequence. Commit and push your concern first, then:

1. Run `node <absolute-skill-dir>/scripts/finish.mjs spell <absolute-own-repo>`.
   Save each returned definition with `spell_save` and pass `composition` to
   `spell_compose`. This creates `parallel-evolution-finish` on this node.
2. Observe your current `git rev-parse HEAD`. Run `parallel-evolution-finish`
   with `p1_head` and `p2_head` both set to that exact hash, and `p1_repo_arg`
   and `p2_repo_arg` both set to your shell-quoted native repository path.
   Repository paths are required so a node's shared spell cannot silently use
   another actor's checkout. The runner default is shell-quoted for this node's
   bash; regenerate it when the skill moves.
3. Read the trace: repository readiness, gate verdict/skips, and postcondition
   proof must all pass. It checks only your tree, fetches refs, and writes gate
   evidence under your worktree's Git metadata; it never commits, pushes, merges,
   switches another tree, or deploys.
4. Review the `inference_required` items: one concern/patch review, impact audit
   coverage, and requested integration/deployment. The spell cannot decide these.
5. After integration, `node <runner> verify <own-repo> <new-HEAD>` rechecks Git
   state and gate proof. Proof is bound to the exact Git source tree and its log
   hash; an identical-tree merge can reuse it, and changed source requires a new gate.

For Pi/Orca without spell tools, run the same `check`, `gate`, and `verify` commands
directly. If the spell refuses, inspect its trace and use inference to finish or
repair; dirty/unpushed/stale work is a valid refusal, never a reason to weaken it.
Rebuild a composition after repairing a source spell: source versions are snapshots.

## Before you report done

A branch is **merge-ready** only when every row below is true, and you can state each as a
fact:

| property | how to prove it |
| --- | --- |
| one delivery | the branch carries one delivery's concerns; adjacent ones are expected, and every commit is reviewable on its own |
| current | `git rev-list --count HEAD..origin/main` is 0, or you merged it |
| merges | `git merge-tree --write-tree origin/main HEAD` exits 0 |
| gate | the repository's test command passes on the merged result |
| reviewable | the last commit is the whole change, with a reason |
| nothing lost | nothing is uncommitted, and the branch is pushed |

If you cannot prove one, say which and why. **A claim that outruns its evidence is the
failure this list exists to prevent.**

## When branches diverge

Drift is normal; hiding it is not. Watch it and act early:

- **You are behind.** Merge `main` in, re-run the gate, push. Never continue on a stale base.
- **`main` already contains your change** (someone landed an equivalent). Prove it and drop
  yours:
  ```
  git cherry origin/main HEAD      # a line starting with '-' is an equivalent patch
  ```
  Do not merge a duplicate. Two branches implementing the same intent on different bases
  is how a "fix" becomes a revert of everyone else's work.
- **Two open branches overlap on the same code.** Stop both before they diverge further.
  Let one land on current `main`; the other rebases onto it and re-derives its change. Do
  not each independently "fix" the same lines on your own bases.
- **The conflict is semantic, not textual** (the two changes mean different things). Resolve
  it only with the other writer; otherwise escalate.

## When to stop and call a judge

Stop evolving and ask for a **third-party integrator** when any of these is true:

- a rebase conflicts in a way that needs a decision, not just a marker edit;
- two branches implement the same intent and neither obviously wins;
- your change touches a shared contract — a schema, a wire key, a public API, a config
  format — that other open branches depend on;
- you cannot prove the merge or the gate, and the failure is in the interaction between
  branches rather than inside your change.

Hand over a packet, not a request to "figure it out":

```
branch:
base (merge-base with main):
ahead / behind:
git merge-tree --write-tree origin/main HEAD : <clean | conflict in these files>
the gate: <command> -> <exit code / verdict>
proven: <what you ran>
claimed but unproven: <what you did not>
other open branches that may overlap: <list>
```

The judge integrates; it does not redesign your change. Its job is to make the branches
converge on current `main` and leave the gate green.

## The freeze

When the board shows more than one non-mergeable branch, or a judge has been called:

1. **Stop all new evolution.** No new commits on the involved branches; owners do not
   "quickly fix" them.
2. **Converge.** The judge, or the owners one at a time, rebases each branch onto current
   `main`, resolves overlaps by intent, and runs the gate.
3. **Resume.** Only when every branch merges clean and the gate is green do new changes
   start again — each from the new `main`.

A freeze is cheap and short. Letting branches drift while "just one more change" lands is
how the same file collects three different fixes and none of them merge.

## Adapt the words to this repository

This procedure is generic — it is not tied to any project, language or harness. Before relying on
it, find the repository's own rules (`AGENTS.md`, `CONTRIBUTING.md`, `.github/`) and map its words:

| this file says | find the repository's word for it |
| --- | --- |
| integration branch | the branch everyone merges into |
| gate | the test entry point |
| board / drift | the branch-status command |
| change branch | the short-lived branch name |
| provenance trailer | what the commit hook requires |
| judge | the human, or an agent the human nominates |

If the repository has no gate, say so in your report rather than inventing one.

### Example: the wasm-agent repository

**If you are not in wasm-agent, ignore this section** — it is one repository's worked mapping.
Here `main` is the integration branch; the gate is `bash scripts/test.sh`; the board is
`bash scripts/worktrees.sh`; a change branch is `change/<name>`; the trailer is
`Agent: wasm-agent node=<node> session=<id>` or `Agent: pi session=<id>`; hooks are enabled with
`git config core.hooksPath .githooks`.

- **Your branch is your name** (`git symbolic-ref --short HEAD`); `main` is never a node's name.
- **Only the merge lane moves `main`.** The authority statement, the guard's exact claim (a direct
  *commit* on `main` needs the host's `orchestrator` provenance; a merge is trusted by its parents; the
  human's `WASM_AGENT_ALLOW_MAIN=1` override is theirs alone) and the client-side-hook boundary are
  stated once in `skills/git-orchestrator/SKILL.md`. `scripts/test-main-guard.sh` pins the measured
  boundary.
- **Work in your own worktree.** Never switch, commit in, or leave a branch in another checkout —
  a live run did that and left the human's `main` checkout sitting on its branch.
- **One `change/<name>` per concern**, cut from `origin/main`, merged and deleted.
- **Before you start:** `git fetch origin && git merge origin/main`.
- **Before you report done:** rebase onto `origin/main` and prove it with
  `git merge-tree --write-tree origin/main HEAD`.
- **Commit before you stop**; a `wip(...)` commit that says what remains beats a dirty tree.
- **Build and verify:** `cargo build --release --offline --manifest-path rust/Cargo.toml`, then
  `bash scripts/test.sh` (hermetic, no model). `bash scripts/test-behavior.sh` needs a model; on
  Windows `powershell -File scripts/test-windows.ps1` runs the local suite. The smoke test needs
  `cargo` on `PATH` — run it on the cloud tree if the local one lacks it. The window shell is
  cross-built from Linux with `bash scripts/build-window.sh`.

#### Landing

Landing is the merge lane's step, not the producer's. The authority, the lifecycle, the lanes and the
landing steps — merge the reviewed tip onto the sanctioned tree, gate the **merged** tree, push
`origin/main` under the sole lock, read the ref back, prove integration, then clean up — are stated
once in [skills/git-orchestrator/SKILL.md](../git-orchestrator/SKILL.md) ("The landing steps"), with
the measurements behind them. Do not re-derive them here.

What a producer owes that lane, all provable from its own worktree:

- the branch pushed, current with `origin/main`, and one delivery (adjacent commits included);
- `git merge-tree --write-tree origin/main HEAD` exits 0;
- the gate's verdict on its own tree, with the skip count;
- the exact tip SHA, and what it did **not** verify, in the report.

The lane may land several reviewed tips before it gates and pushes, so expect your commit to be part
of a combined tree — and expect a re-gate of that tree, because a merge changes the tree and your
receipt covers only your branch.

## Focused producer admission after bootstrap

`finish.mjs admit <own-repo> <exact-head>` can produce source-bound focused evidence
for supported paths. For shared/unknown paths, `producer-admission.mjs` accepts an
explicit focused scope of actual catalog checks or tracked local test cases, bound
by `Focused-Scope-SHA256` in the independent review commit. Actual independent
observation packets may be imported without relabelling their original source,
runner, raw logs, counts or unknown timing as a new execution. Carry the receipt with
`delivery-admission.mjs ... --producer-proof <receipt>`; it never authorizes self
review or publication. A focused result has `admission_verified:true` but
`gate_verified:false`, `release_verified:false` and `requires_combined_gate:false`.
The merge lane verifies actual records with `--delivery-store`; it does not infer
a full gate before publication. Explicit user-selected pre-release verification
still requires valid exact-tree full proof, including preserved raw/retained identity.
See `docs/RECOVERY-THROUGHPUT.md` for commands, coverage and measured limits.
