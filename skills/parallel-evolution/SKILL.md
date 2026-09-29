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

You are one writer among several, and another branch may be editing the same file right
now. The integration branch (call it `main`) is the only shared truth; **your branch is a
proposal, not a copy of the project.** The goal is never "my branch works" — it is **"my
change merges cleanly onto today's `main`, and the gate still passes after it does."** A
change that is correct but three days stale is not finished work; it is a task handed to
whoever has to merge it.

If this repository has its own contributor rules (`AGENTS.md`, `CONTRIBUTING.md`), they
override this file. Read those first; this is the general procedure.

## One change per branch

- Cut a **short-lived** branch from current `main` for exactly one concern, and name it
  for that concern.
- A branch that lives a day cannot fall behind. A branch that lives a week will meet
  everything that landed meanwhile.
- Do not carry two unrelated changes on one branch. If you find an unrelated defect,
  record it (an issue, a note, its own branch) — do not fix it silently inside this one.
- Never commit to the integration branch unless you are the integrator the repository (or the host)
  names as such — see "Landing on `main`" in the repository's own mapping below. Never force-push a
  branch someone else may have built on.

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

**4. Run the gate.**
Whatever the repository uses as its test entry point, run it on the merged result. A
change is not done because it compiles; it is done when the repository's own check passes
with your change in it. If there is no gate, say so in your report.
In wasm-agent, the closing spell below supplies this gate after the candidate commit
and push, before integration. A published concern branch is still a proposal until it passes.

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

### The wasm-agent closing spell

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
| one concern | the diff touches one thing |
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
- **Only the integrator moves `main`.** `.githooks/pre-commit` refuses a direct commit on `main`
  unless it is a merge, or unless the host set `WASM_AGENT_PROVENANCE=orchestrator` on the process —
  a run of a session, which is the coordinator the owner is talking to. A bounded child task is told
  `child` and is refused even when it exports `WASM_AGENT_ALLOW_MAIN=1`; a person at a terminal has
  no provenance and keeps that flag as their visible, explicit override. `scripts/test-main-guard.sh`
  pins all five cases.
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

#### Landing on `main`

The integrator's path, in full, because "the human merges" was the whole instruction and it left the
coordinator with no tree to merge in. Each step names the command whose output proves it; a step you
cannot show is a step you did not do.

1. **Pick the sanctioned tree.** The canonical checkout (`orca/projects/wasm-agent`) is the one tree
   whose branch is `main`. Address it by absolute path — never switch your own worktree's branch
   onto `main`, and never merge in a node's worktree.
   Check: `git -C <canonical> symbolic-ref --short HEAD` prints `main` and
   `git -C <canonical> status --porcelain` is empty.
2. **Review, then merge the exact tip.** `git -C <canonical> fetch origin`, merge the reviewed branch
   SHA with `--no-ff` and a subject naming it (`merge(<branch>): what it brings`). A merge is allowed
   on `main` whatever the provenance; a *direct* commit there is not, unless step 5 applies.
   Check: `git -C <canonical> log --first-parent -1 --format=%s` names the merged branch, and
   `git -C <canonical> rev-parse HEAD^2` resolves.
3. **Gate the MERGED tree, not the branch tree.** A merge changes the tree, so the branch's gate
   receipt no longer covers what is about to be pushed; the merged HEAD needs its own run.
   Check: `bash scripts/test.sh` on the merged HEAD, exit 0, with its skips counted — in
   wasm-agent, `node skills/parallel-evolution/scripts/finish.mjs gate <canonical>` records the
   receipt against that exact tree.
4. **Push `origin/main`, then verify the ref.** `git -C <canonical> push origin main`, then read
   the remote rather than trusting the push output.
   Check: `git -C <canonical> ls-remote origin refs/heads/main` equals
   `git -C <canonical> rev-parse HEAD`.
5. **A direct commit on `main` (no merge) is the exception.** Allowed only for the orchestrator
   session, for `main`'s own change (a document, a version bump), and it carries the trailer like
   any other commit. A child is refused, and a person at a terminal needs
   `WASM_AGENT_ALLOW_MAIN=1`.
6. **Clean up after the fact, never instead of it.** Only once the tip is in `main` and pushed:
   delete the merged branch and prune its worktree.
   Check: `git -C <canonical> branch --merged main --contains <tip>`
   lists `change/<name>`, then `git -C <canonical> branch -d change/<name>` and
   `git -C <canonical> worktree prune`. `-d` (not `-D`) is the proof: git refuses to delete a branch
   whose tip is not integrated.

What is policy here, not verified: which machine is authoritative, whether a PR review is required
before step 2, and whether the owner wants the pushed `main` to be the cloud tree's. Steps 1, 2 and 6
are mechanical and checkable on any machine; step 3 must be run wherever the tree you push lives.
