# The factory — running a batch of delegated work to landed code

This records how this repository's changes were actually produced and landed during the
first batch that used worker subagents with independent verification. It is a ledger plus
a protocol: what the pipeline is, what evidence each step must carry, what we got wrong,
and how a batch is closed. It is deliberately written from the failures, because every
rule below exists because something passed a check it should have failed.

## The pipeline

```
intake (an observed symptom, with evidence)
  -> scope        one concern, its files, its acceptance, its limits
  -> produce      a worker session, own worktree, own branch, pushed
  -> verify       an independent worker attacks the claim, not the code's style
  -> repair       bounded, once, when verification falsifies something
  -> accept       the coordinator checks the artifact, never the sentence
  -> land         merge, gate the MERGED tree, push main, delete, prune
  -> deploy       the sentinel installs and restarts; the node then runs the change
```

Two invariants hold the whole thing up:

1. **An agent's report is evidence, not verification.** Every acceptance in this batch
   came from re-running, re-reading, or re-attacking the artifact.
2. **No effect before its proof.** A gate receipt is bound to an exact tree; a merge
   changes the tree, so the branch's receipt never covers the merge. Re-gate the merged
   tree, then push.

## Batch ledger (first batch, 2026-09-29)

| concern | branch tip | state | evidence carried |
| --- | --- | --- | --- |
| child receipts carry provider/model/usage | `5d93838` | accepted | host tests, gate receipt, live probe against a mock model |
| budget refusal names its provenance | `58176ad` | accepted | 13-check focused test; gate green; refuted the original premise |
| a child session is serialized by durable records | `c860b39` | accepted | new test + falsification by disabling the check; whole-package diff compared against base |
| `/update` refuses when no watcher can claim it | `7180d68` | accepted | 28-check focused test, live route test, gate green after a repair |
| gate owns its build parallelism | `747449e` | accepted | two full gates on one tree, sampled peak `rustc`, mean CPU; default left unchanged on purpose |
| a model is refused by protocol, at request and at launch | `0c08569` | accepted | 52-check test, live catalogue probe, gate green |
| role-scoped authority to move `main` | `f269b97` | in repair | 25-check oracle; falsifier broke the claim, not the mechanism |
| peer shell survives a missing cwd | (in flight) | producing | — |
| a script against embedded Lua says so | (in flight) | producing | — |

Superseded: the first `/update` draft (a luna worker's WIP) — kept, not merged, because a
later branch solved the same concern with tests.

## What verification actually caught

Recorded because the *rate* matters more than any single find. Of eight concerns, **four
were changed by verification**, and two of those were claims I had already repeated to the
operator:

- a "green" gate that never ran past an undefined `$ROOT`, and a focused test that was
  silently testing the binary's embedded Lua instead of the tree;
- a premise I stated twice ("seven children died before their first provider call") that
  was simply false — the ledger showed 8–45 assistant turns each;
- numbers I quoted from a worker's table with two columns swapped;
- a fail-closed guard that refused five models its route genuinely serves.

The pattern in every case: **a claim checked against the wrong artifact, or against an
assumption nobody owned.**

## Landmines found, with their detection

Each of these cost real time in this batch; each has a cheap detector.

| landmine | shape | detection |
| --- | --- | --- |
| shell argument rewriting | MSYS turns `/FI` into `C:/Program Files/Git/FI`, and `origin/x:path` into a backslash path — a probe or a `git show` fails or silently misbehaves | `MSYS_NO_PATHCONV=1` for the affected command; the `/update` probe would have refused *every* update on Windows without it |
| embedded-Lua fallback | `WA_SCRIPT=… wa` without `WASM_AGENT_LUA_ROOT` loads modules compiled into the binary, so a test of a tree edit tests nothing | set `WASM_AGENT_LUA_ROOT`; a stderr note when the embedded copy is used is the fix in flight |
| a client-side hook is not a boundary | hooks do not run for `cherry-pick`, `revert`, `rebase` on this git, and `--no-verify` skips them | treat hooks as convenience; the enforcement point that cannot be skipped is on the remote |
| profiles live outside git | a subagent profile's model/limits changed and no one could date the change | the profile is live config; journal it, or record the effective limits on the child receipt |
| machine-wide measurement | "20 rustc, 91% CPU" was counted across the whole box while other children built | sample the process tree, not the machine; state the sampling method with the number |
| shared hot file | five branches each added one line to `scripts/test.sh`; three touched `subagents.rs` | make the gate discover tests by convention so a new test is a new file; one hot-file editor unlanded at a time |

## The landing procedure

1. **Pick the tree.** Merges happen in one sanctioned tree on `main`, by absolute path.
   A node's own worktree is for its branch; a worker's worktree is its branch's.
2. **Merge the reviewed tip** with `--no-ff`, naming the branch, or pass an explicit
   merge message — git's `Merge commit '<sha>'` default is refused by the guard.
3. **Gate the merged tree.** The branch's receipt does not cover the merge. Record exit
   status, the skip count, and every failure verbatim.
4. **Push `origin/main` and read the ref back.** A push that reports success and a ref
   that matches are two facts, not one.
5. **Prove integration before deleting anything.** `git branch -d` is not proof: on git
   2.55 it deletes a branch whose tip lives only in its own upstream. Use
   `git branch --merged main` or `git merge-base --is-ancestor <tip> main`.
6. **Delete the branch, prune the worktree, release the session workspace.** Keep the
   transcript; the tree is disposable, the evidence is not.
7. **Deploy through the sentinel**, never from inside a run: queue the request, then read
   `installed.txt` and `deploy-result.json` rather than trusting the request's receipt.

## Modules — a feature that is one directory (2026-09-29)

A new capability enters this repository as **a module**: `modules/<id>/` with a `module.json`, listed
by a Lua route that reads the directory, and removed by deleting it. `docs/MODULES.md` is the short
form (add path, remove path, proof); this section is the part that belongs in the factory ledger —
the exact commands and why they are the whole story.

**Remove a module.** No registry, no route table and no document outside the directory names it, so
there is nothing else to edit:

```bash
git rm -r modules/<id>
git commit -m "remove module <id>"
```

**Put it back.** The tag is written in the module's own manifest when it is added
(`module-<id>-v<version>`), so recovery works after the removal is committed and merged:

```bash
git tag module-<id>-v<version>                    # when the module is added
git checkout module-<id>-v<version> -- modules/<id>   # when it is wanted back
```

A module nobody asked for is off, and the ask is data (`WASM_AGENT_MODULES=<id>`, or `"enabled": true`
in its manifest), so an ask that still names a deleted module is an ask about nothing rather than an
error — one deletion fewer thing to keep in step.

**The proof is the deliverable.** `bash scripts/test-modules-removal.sh` asserts (a) the module is
listed and mounted while its directory exists, (b) no listing mentions it after the directory is
deleted, (c) the host page mounts nothing for it and reports no error, and (d) **no file outside
`modules/<id>/` names that module's id** — before *and* after the deletion, over every file in a
scratch copy of the tree, which is the assertion that makes "removed completely" a measurement
rather than a claim. `--render` adds the headless render of the host page.

## Batch hygiene

- **One hot-file editor unlanded at a time.** Five branches on `scripts/test.sh` is the
  cost this rule exists to prevent.
- **Idempotency keys on every message to a worker.** A repeated instruction must not
  produce a second turn of work.
- **Never retry an effect whose outcome is unknown.** Reconcile read-only first; this
  applies to a send, a deploy and a merge alike.
- **A superseded branch is marked, not deleted, until its replacement is landed.**

## Batch 1 — verified and deployed (2026-09-29)

Nine concerns, three landings, one deploy. This is the first batch produced under the
pipeline above, so its numbers are the baseline for the next one.

**Landed** (`main`, remote heads = `main` only):

| landing | content | gate | result |
| --- | --- | --- | --- |
| 1 | the seven verified branches | full gate on the merged tree, green | `d192fdf` |
| 2 | peer-cwd fix + embedded-Lua notice | full gate on the merged tree, green | `878b60b` |
| 3 | the node branch's docs (this file, EXECUTION.md, the notes-to-self rule) | none — docs-only, three files, and the deploy's own gate covers it | `b83ccae` |

**Deployed**: `installed.txt` = `b83ccae`, branch `main`, built by `deploy.sh` at
`2026-09-29T15:01:17Z`; node sha `ac25bbd9…`, sentinel sha `f265cf69…`, watcher
`15928 → 11972`. The deploy built the new node from the canonical tree, proved it on a
scratch port ("it answers") and only then waited for idle — the swap was blocked by the
coordinator's own turns, which is why it sat in `busy after 60s; waiting for the turn to
finish` for several minutes.

**`verify-install.sh --json`: 14 of 16 pass.** Failing, and pre-existing rather than
caused by this batch: `skills/git-orchestrator/SKILL.md` and
`skills/git-orchestrator/scripts/audit.mjs` differ between the repository and
`~/.wasm-agent/skills/`. Measured: the shipped copies are from **2026-09-26 20:59**, the
repository's from **2026-09-29 11:34** (108 and 101 differing lines). Cause:
`upgrade.sh` ships a skill only `if [ -n "$SOURCE_ROOT" ] && [ -f "$SOURCE_ROOT/skills/$skill/SKILL.md" ]`
(`upgrade.sh:363-365`), and `SOURCE_ROOT` is derived from the directory holding the new
binary (`upgrade.sh:69`) — so a deploy that stages the binary anywhere outside a checkout
silently ships no skills, while `verify-install.sh` still compares them. The two failures
survived an authorized install, which is exactly what the earlier note said would happen
until the shipping path itself is fixed.

**Facts worth carrying into the next batch:**

- Three gate runs were needed for one batch, all at `WA_GATE_JOBS=4` to keep the machine
  usable; that knob was written by this batch and used in anger for the first time on its
  own landing.
- Four of eight concerns were **changed by verification** — including two claims the
  coordinator had already repeated to the operator. Self-report is evidence, never proof.
- The remote branch set is `main` only: every landed branch deleted, and the dead
  luna WIP abandoned rather than merged.
- The canonical checkout is the sanctioned merge tree, by absolute path. It was 17 commits
  behind `origin/main` before the first landing; the landing path's own first step now
  refuses that state, which is how it was found.
- `runtime-worktree.txt` pointed at the node's own worktree, so a deploy would have built a
  tree missing the whole batch and the guard would have refused it. It now names the
  canonical tree. A deploy's source and the sanctioned merge tree should be the same tree.
- `wasm_the_first` is a **local-only** branch: `origin/wasm_the_first` has never existed, so
  it must be merged by its local ref, not a remote-tracking one.
- GitHub ssh auth failed intermittently for ~10 minutes (same URL, same key, succeeding
  from one worktree and failing from another), then recovered. Retry the network step and
  read the ref back rather than concluding the repository is unreachable.
