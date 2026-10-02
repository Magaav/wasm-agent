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

The `state` column is the batch's working state **on 2026-09-29, not a live status**: the table was written
before the batch's first landing, and its last three rows were still moving then. What each of them ended
as is the landing table in the "Batch 1" section below: the two `(in flight)` rows are landing 2
(`878b60b`, the peer-cwd fix and the embedded-Lua notice) and `f269b97` is in landing 1 (`d192fdf`).

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
| the lane's own switches ride into the gate | `MSYS_NO_PATHCONV=1`, set so the lane's own `--repo` argument survives, reaches every native process the gate spawns — `/tmp/wa-instances-…` becomes `C:\tmp\…`, the node-instances suite fails 10 of 62 with both sentinels started but not answering, and the nested verdict read dies on `C:\tmp\…` | `scripts/merge-lane.mjs` drops its own variables before the gate and records `gate.environment_dropped`; `scripts/test-merge-lane.mjs` fails if `${MSYS_NO_PATHCONV-unset}` is not `unset` inside the gate |
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
3. **Gate the merged tree when the landing is a release.** The branch's receipt does not cover the
   merge. Record exit status, the skip count, and every failure verbatim. `scripts/merge-lane.mjs` is this step
   plus the two before it, run in a disposable clone; see "The merge lane" below. Since 2026-10-02 its
   default is `--gate-mode none`: an evolution landing is merged and reported, and the full gate belongs to
   a release (`scripts/wave-release.mjs`), which gates the exact tree it will name.
4. **Push `origin/main` and read the ref back.** A push that reports success and a ref
   that matches are two facts, not one.
5. **Prove integration before deleting anything.** `git branch -d` is not proof: on git
   2.55 it deletes a branch whose tip lives only in its own upstream. Use
   `git branch --merged main` or `git merge-base --is-ancestor <tip> main`.
6. **Delete the branch, prune the worktree, release the session workspace.** Keep the
   transcript; the tree is disposable, the evidence is not.
7. **Deploy through the sentinel**, never from inside a run: queue the request, then read
   `installed.txt` and `deploy-result.json` rather than trusting the request's receipt.

## The merge lane (2026-09-29)

Integration was the last step a person did by hand. This is the lane that does it instead: a
deterministic spine that produces a *tested candidate*, one main-mover that may push it, and a
reserved merger who decides what a script cannot. The serial resource is not the merge commit — it is
the gate. A merge costs a second; the gate on the merged tree costs ~15 minutes at
`WA_GATE_JOBS=2`, so **~4 landings/hour is the ceiling no matter how many producers run**, and
batching is the only lever that moves it (batch 1 gated seven verified branches in one run,
`d192fdf`).

### The front of the lane: the record, the rule, the trigger (2026-09-30)

A delivery enters the lane through its record: one JSON file per delivery in the sentinel's `deliveries`
store, holding the branch, tip, tree, producer, the reviewer's verdict on that exact tree, the admission
decision, the lane's outcome and the landing sha. `node scripts/delivery-admission.mjs check <delivery>`
answers whether it may enter - branch pushed, an independent review naming the same tree, no unresolved
`summary_exceeds_code` finding - and refuses by naming the failed condition. `delivery-admission`
(schedule, deterministic) emits one `delivery.admitted` event per newly-admitted delivery; `delivery-lane`
wakes on that event. See `scripts/delivery-admission.md`.

### The spine — `scripts/merge-lane.mjs`

A `run`-class script: no model, no inference, one JSON object on stdout, human lines on stderr. It
reuses `skills/git-orchestrator/scripts/audit.mjs` for discovery (fetch, every tip's state,
`git merge-tree --write-tree` per tip, worktrees) and adds only what the audit does not do: build the
candidate, gate the merged tree, and say so in one object.

```
node scripts/merge-lane.mjs --repo <path> [tip ...] [--all-pending] [--jobs 2] [--json <file>]
```

| phase | what it does | what it cannot do |
| --- | --- | --- |
| discover | the audit, in the repository it was pointed at | claim integration is complete |
| prove | per input: `rev-list --left-right --count <base>...<tip>`, subject, `merge-tree --write-tree <base> <tip>` | resolve a conflict |
| build | `git clone --local` into a temp dir, a `lane/merge-<utc>` branch, then `git merge --no-ff -m "merge(<branch>): …"` per accepted tip, in order | touch the source repository, or merge a tip it has not identity-checked |
| check | `git grep --cached -I -l $'\r'` on the merged tree (the `pre-commit` rule, which a merge does not run) | — |
| gate | `bash scripts/test.sh` in the clone with `WA_GATE_JOBS`, inside a `scripts/gate-lane.mjs` slot (`acquire`/`release`); exit, wall ms, log + sha256, skip count from the gate's own `smoke ok (N skipped)` | call exit 0 without that line a pass |
| report | one object: per-input state, the candidate tree and branch, gate exit/skips, timings, `push_precondition` | push |

Exit codes: `0` pass (or nothing to merge), `2` a named blocked input, `3` the merged-tree gate
failed, `4` usage/repository error, `5` discovery could not establish the base or an input, `6` the gate
lane granted no slot, so the merged tree was not gated. Two seams exist for tests and only for tests:
`--gate-command` and `WA_MERGE_LANE_AUDIT`; both are recorded verbatim in the output, so a run that used
them cannot be mistaken for a real gate.

The gate runs inside the lane's reservation (`docs/CONCURRENCY.md`, "Lane reservations and the serial
gate"): this script takes a slot with `acquire`, keeps its own runner and its own verdict, and calls
`release` when the gate ends. A lane that cannot be consulted is **fail open** - a named notice on stderr,
`gate.lane.mode: "unavailable"`, and the merged tree is gated anyway; `WA_GATE_LANE=off` produces the same
outcome deliberately, by name. A lane that is *reached* and refuses is **fail closed and terminal**: the
gate does not run, `gate.refused` is set, the verdict is `gate_refused` and the exit is `6` - never the
`merge_only` that would read as "merged, nothing to gate" - and nothing is retried.

Discovery errors are classified rather than swallowed: one that touches the base or a named input stops
the run (`5`), while one that does not — a sibling's branch moving while this run reads the world, a
live `origin` head that differs from the fetched refs — is reported in `discovery.warnings` and does
not block a candidate whose own inputs are re-proved by SHA. With `--all-pending`, discovery *is* the
input list, so every discovery error is fatal there.

Facts it always states, because a landing needs them: the base ref before and after
(`main_moved_by_this_run`), `pushed: false`, the exact SHA of every input, the merge commit each input
produced, the candidate tree, the gate's own admission row (`gate.lane`, and `gate_lane` in the finish
receipt: the slot it waited for and the wait `gate_ms` leaves out), and `push_precondition` — which is
only `can_push: true` when the verdict passed *and* the base ref did not move while the candidate was
built.

### One main-mover — the mechanism this repository already had

No new lock was written. Two existing mechanisms already answer "who may move `main`, and how is a
dead holder reconciled":

- **Authority.** `.githooks/pre-commit` and `.githooks/commit-msg` decide who may commit on `main`
  from the host's answer about the process (`WASM_AGENT_PROVENANCE`: `orchestrator` = a run of a
  session, `child` = a bounded subagent task), and they judge a merge by its *subject naming the
  branch it merged* — which is why the spine passes an explicit `merge(<branch>): …` message instead
  of letting git write `Merge commit '<sha>'`.
- **Exclusivity, durable and reconcilable.** `rust/wa-jobs` claims deliveries atomically inside one
  SQLite immediate transaction, and "one delivery per job runs at once" (`docs/JOBS.md`). The one
  process that may consume them holds the sentinel's exclusive OS runner lock,
  `<sentinel>/runner.lock` (`rust/wa-sentinel/src/jobs.rs`, `try_lock`: "another sentinel owns the
  runner"), and on acquiring it calls `Store::recover()`, which flips deliveries left `running` by a
  dead holder to `unknown` — "sentinel restarted; reconcile external effects before retry".

So the main-mover token is **one delivery of one job, id `merge-lane`**, whose action is a single
`run` step pointing at this script. The holder is identifiable without reading a process list: job id +
delivery id + `started_at` in `<sentinel>/jobs.db`, readable with `wa-sentinel jobs history`. It is
reconcilable after a death because the lane's only external effect is a disposable clone plus its JSON:
the delivery is `unknown`, never replayed, and the next holder reads what the dead one left (the
retained clone and `gate.log`) instead of guessing. The key this introduces is the job id `merge-lane`;
the `run` action requires an absolute, allow-listed script path, so installing it is an operator act.

### Per-landing or batched — with the numbers

| gating | gates per batch of k | attribution | measured |
| --- | --- | --- | --- |
| per landing | k | the branch's own receipt | 965.7 s at `WA_GATE_JOBS=2`, one tree (`docs/EVOLUTION.md`) |
| batched | 1 | the merged tree, not the branch | batch 1: six branches, one gate, green |

The gate is ~860 s on a real `wa-finish-gate.json` at `WA_GATE_JOBS=2` and 965.7 s in the controlled
pair in `docs/EVOLUTION.md`; a measured lane run today is in the table below. Batching therefore buys
`k`-fold throughput and spends attribution: a red gate names the merged tree, so finding the input that
broke it costs one re-run per subset. The honest rule: **batch independent, reviewed inputs; gate per
landing when one delivery must carry its own receipt** (a contract change, a risky platform path, an
input whose review is thin). `--partial` exists for the middle case — gate the accepted subset, keep
the blocked input named, and still exit nonzero, because a batch with a blocked input is not a success.

### Measured, on the real pending branches (2026-09-29)

Real runs of the spine on this repository's own committed `change/` tips, at `WA_GATE_JOBS=2`, with the
gate a real `bash scripts/test.sh` in a disposable clone (`--gate-command` was not used):

| run | inputs (exact SHA) | candidate tree | discovery | clone | merges | gate | verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `380e168` (`change/wa-session-08cb06ff…`), `54b7874` (`change/wa-session-e6bfc741…`) | `ee9c46bc` | 26.7 s | 0.38 s | 1.4 s | exit 1, 688.8 s, no verdict line | `gate_failed` (exit 3) — the lane's own `MSYS_NO_PATHCONV=1` |
| 2 | `380e168`, `ee15da23` (that branch moved between the runs) | `200309f2` | 277.2 s | 0.66 s | 2.0 s | exit 1, 907.6 s, no verdict line | `gate_failed` (exit 3) — `scripts/test-openai-sub.cjs`, **not attributed** |
| blocked | `dcf49653` (`wip(update): check sentinel before queuing deploy`, 45 commits behind) | base tree `8f50e352` | 23.7 s | — | — | not run | `blocked` (exit 2): the tip is named, with `content: Merge conflict in lua/core/update.lua` |

What these runs establish, and what they do not:

- the spine never pushed and never moved `main`: `pushed: false` and `base_ref_before = base_ref_after =
f962844` in all three, and the source worktree was clean after each;
- the candidate merges are real merges of the exact proven SHAs (`merged: true`,
`identity_checked_in_clone: true`, a `merge_commit` per input), and the candidate's LF check was `clean`;
- run 1's gate failure was the lane's own environment, and run 2 proves it: `node instances` failed 10 of
62 in run 1 and passed 62 of 62 in run 2, with the same kind of candidate and the leak removed;
- run 2's gate failure is **not** attributed to anything yet. `scripts/test-openai-sub.cjs` fails inside
the gate but passes standalone in the same candidate clone, both with `TEMP=/tmp` and with a native
`TEMP`, so neither the merged tree in isolation nor the temp-path mechanism explains it. That is an open
input for a merger, not a property of the batch, and it is exactly the case this section hands to the
reserved merger;
- discovery is dominated by the audit's worktree inspection, which scales with the number of worktrees on
the machine rather than with the number of inputs: 345 worktrees → 20.7 s of the 26.7 s total, 734
worktrees (three children active) → 270.4 s of the 277.2 s total. Fetch, PR discovery and the merge proofs
together stayed under 5 s.

Two of these three runs ended in a failed gate, and that is the honest shape of the result: the lane's job
was to make the merged tree's verdict impossible to misread, and it did — including naming its own
environment as the cause of the first one.

### What needs judgement, and what does not

Decidable, so the spine does it: fetch, per-tip state, mergeability against the target, the identity of
every SHA it merges, the merge itself with `--no-ff` and a subject that names the branch, the LF
invariant on the merged tree, the gate on the merged tree, the exit code, the skip count, and the JSON.

Judgement, so a **reserved merger** does it — the lane reports, it does not decide:

- an **ambiguous conflict**: which intended effect wins, or that the tip is held for its author. A
  mechanical overlap that preserves both effects is not ambiguous; a product or contract choice is;
- a **conflicting contract** between two accepted deliveries (both are "right" and only one can win);
- a delivery whose **review falsified its claim** — the spine cannot see review, and a tip that is
  merely committed is not a tip that is accepted;
- a **failed merged-tree gate**: diagnose and repair, or name the input to hold and re-run. The failure
  is a fact about the merged tree, so the merger also owns the bisect;
- the **order** of inputs, when a conflict depends on it (`--all-pending` sorts by ref name; naming the
  order is a decision), and whether to land the batch or split it.

What a merger must **never** do: drop commits, force-push, reset shared `main`, call a failed gate
success, land an unreviewed tip, or read `--partial` as a pass. The spine refuses the mechanical
versions of the first four by construction (it never pushes, and a blocked input is never a success);
the rest are decisions, and that is the point.

### The boundary, and the identity automatic merging needs

A client-side hook is not a boundary, and this repository has measured its own limits
(`scripts/test-main-guard.sh`): `cherry-pick`, `revert` and `rebase --onto` never consult a hook,
`--no-verify` and `git -c core.hooksPath=` skip them, and `git update-ref refs/heads/main` moves `main`
from any worktree. So an automatic merge needs two things the lane does not supply:

1. **a named identity** — the lane commits as `merge lane <merge-lane@wasm-agent.invalid>` (recorded in
the output as `identity`) and every merge subject names the branch it merged, so a `main` commit from
the lane is attributable without a trailer a merge cannot truthfully carry;
2. **a remote-side enforcement point** — branch protection on `origin/main`, or a `pre-receive` check
   that refuses a non-merge update. Until one exists, `push_precondition` is a client-side check and
   nothing more.

### Still the owner's decision

- **Install the job.** `merge-lane` as a `run` job (absolute script path, `WA_SENTINEL_SCRIPTS`
  allow-list) and who may hold it. The lane is a protocol plus a script; it does not install itself.
- **The remote boundary.** Branch protection or a `pre-receive` check on `origin/main` is the only
  unskippable enforcement point, and it is a repository setting, not a file.
- **The batch policy.** How many inputs per gate, when to prefer per-landing gating, and who is the
  reserved merger for a given batch.
- **Whether the lane should push at all.** It does not, today: the push stays the merger's act, and the
  lane's job is to make the tested candidate and the preconditions impossible to misread.

Done since this list was written: **the lane's own test runs in the gate.** Five tests tonight's
deliveries shipped unrunnable are wired into `scripts/test.sh`, each next to the kind of check it is
(`bcdda53`): `scripts/test-merge-lane.mjs` (`70` checks, not the 67 this list used to quote - counted by
running it on this tree), the gate lane's own `scripts/test-gate-lane.cjs`,
`scripts/test-delivery-admission.mjs`, `scripts/test-telemetry-lock.sh` and the `openai-sub` levels check.
They add ~48 s, and the gate is green with them.

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
