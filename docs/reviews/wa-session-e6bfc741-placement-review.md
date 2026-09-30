# Review: `change/wa-session-e6bfc741-…` (`ee15da2`, tree `9de61108…`)

Reviewer: wasm-agent subagent session `7db14e40-0209-4938-a36d-cea73bb8c6d1`, in its own managed
worktree, on branch `change/wa-session-7db14e40-…`. The delivery branch was merged **into this review
branch only** (`git merge --no-edit --no-ff change/wa-session-e6bfc741-…`); nothing was changed on the
delivery, nothing was merged to `main`, nothing was pushed to `main`, no live node state was touched
(placement stayed OFF, no dispatch row was placed, cancelled or amended), and no worktree or branch on
this machine was pruned or deleted.

The two fixtures and this report are **review artifacts**, not part of the delivery: they are here so
the measurements below can be re-run (`node scripts/review-placement-leak.cjs <wa-binary> <label>
[<lua-script>]`, binary built from this tree with
`cargo build --release --offline --manifest-path rust/Cargo.toml`, `Finished … in 3m 58s`). They are
safe to drop.

## Verdicts (one line each)

1. **CONFIRMED** — capacity refusals no longer create a session or a worktree per tick; the falsified
   build reproduces the exact live shape (+3 sessions and +3 worktrees per tick, 30/30 after 10 ticks).
2. **CONFIRMED with two named gaps** — every refusal in the current tree lands in a class, but the
   `not_started` stamp that makes a refusal terminal is version-coupled, and the spills/keeps-shell
   pin only tests one direction.
3. **CONFIRMED for one node** (4 attacks reproduced against the real runtime, 1 forged answer, 1 stuck
   row); the cross-node peer hop remains **UNVERIFIABLE** here.
4. **CONFIRMED, quantified** — one reusable session+worktree per (task, refusing destination), nothing
   reaps it; bound is queue depth × policy size.
5. **CONFIRMED** — the delivery's own fixture passes (74 + 24 + 10 checks) and both pins I reproduced
   fire on a falsified build with their own assertion messages.
6. **CONFIRMED as scope** (13 files: 6 `lua/`, 5 `scripts/`, 2 `docs/` — the brief says 7 under `lua/`,
   it is 6); both docs are accurate except the two overstatements in check 8, and `ORCHESTRATOR-WORKSPACE.md`
   is **not** new — it is the existing home of the placement contract.
7. **Reported, nothing deleted** — measured 1371 worktree registrations, 1336 `change/*` branches,
   1323 `~/.wasm-agent/wa-worktree-*` directories, 0 missing, 0 prunable.
8. **CONFIRMED** — three claims are wider than the code/evidence (below), including one doc sentence
   attributed to a two-node fixture that has no such assertion.

**Overall: safe to keep as a candidate for integration.** Its central claim holds under measurement:
the leak the machine just paid 1322 worktrees for is stopped, and the mechanism (one shell per key)
survives the attacks I could run. **The single most important thing still unproven is the peer hop:**
`reconcile` → the destination's `resolve` was never exercised across two nodes, and its failure mode is
not a leak but a *stuck row* — an `unknown` task that no verb can retry and that `cancel` refuses (case
E below), which is what a mixed-version fleet produces (an older peer answers `forbidden_peer_action`).

## 1. Does the fix stop what was measured? CONFIRMED

Fixture `scripts/review-placement-leak.lua` (driven by `review-placement-leak.cjs`): three queued rows
with write-capable profile `task-worker`, a disposable destination checkout with
`runtime-worktree.txt`, placement policy `{local, max_tasks=1}`, and **the real facade** as the
destination (`api.control = subagents.control`), with only the placement limit zeroed so the runtime's
own admission lock answers a real `node_full`. Ten ticks. Session count from `sessions`,
`WORKTREE` count from the session rows, and the count that mirrors the live report from the
destination repository's own `git worktree list`.

```
baseline before any tick: sessions=0 recorded_worktrees=0 registrations=0
tick | child_sessions | recorded_worktrees | git_registrations | pending_ws | rows | attempts | tick_ms
   1 |              3 |                  3 |                 3 |          0 | queued,queued,queued | 1,1,1 | 2365
   2 |              3 |                  3 |                 3 |          0 | queued,queued,queued | 2,2,2 | 1232
   3 |              3 |                  3 |                 3 |          0 | queued,queued,queued | 3,3,3 | 1203
   4 |              3 |                  3 |                 3 |          0 | queued,queued,queued | 4,4,4 | 1387
   5 |              3 |                  3 |                 3 |          0 | queued,queued,queued | 5,5,5 | 1283
   6 |              3 |                  3 |                 3 |          0 | queued,queued,queued | 6,6,6 | 1210
   7 |              3 |                  3 |                 3 |          0 | queued,queued,queued | 7,7,7 | 1170
   8 |              3 |                  3 |                 3 |          0 | queued,queued,queued | 8,8,8 | 1196
   9 |              3 |                  3 |                 3 |          0 | queued,queued,queued | 9,9,9 | 1115
  10 |              3 |                  3 |                 3 |          0 | queued,queued,queued | 10,10,10 | 1139
VERDICT reuse-by-key: 3 sessions and 3 worktrees after 10 ticks for 3 rows (baseline 0/0)
placement leak review ok (18 checks)
```

Tick 1 writes the pair; ticks 2–10 write nothing — the shell is `child:dispatch:<uuid>` and its
worktree is reused (`…/.wasm-agent/wa-worktree-childdispatch<uuid>`, printed at tick 1 with
`state=allocated`). The rows stay `queued` with `detail=node_full` and `attempts` counting every ask:
the retry cadence is visible and uncapped, but it costs no durable effect. Ten ticks × 3 rows = 30
refused attempts for 3 sessions and 3 worktrees.

**Falsification** (scratch patch in this worktree, since restored): in `lua/core/subagents.lua:549`,
`local shell_id = nil` — reuse-by-key disabled.

```
--- FALSIFICATION: reuse-by-key disabled ---
   1 |              3 |                  3 |                 3 | queued,queued,queued | 1,1,1
   2 |              6 |                  6 |                 6 | queued,queued,queued | 2,2,2
   …
  10 |             30 |                 30 |                30 | queued,queued,queued | 10,10,10
FAIL: lua error: ten ticks leave exactly what one tick left (no second session, no second worktree):
{"first":[3,3,3,"queued,queued,queued"],"last":[30,30,30,"queued,queued,queued"]}
exit=1
```

That is the measured defect reproduced exactly: 3 new child sessions and 3 new worktrees per tick,
all of them empty shells held by a task that never started. Restored with
`git checkout -- lua/core/subagents.lua` and re-run clean (the table above is the restored run; the
falsification run is the FAIL line). `git status --porcelain` shows only the two untracked review
fixtures.

## 2. Every refusal code classified

Codes were grepped out of the code path (not taken from the summary): `lua/core/workspaces.lua`,
`lua/core/subagents.lua`, `lua/core/orchestrator.lua`, `lua/core/nodes.lua`, `lua/core/server.lua`,
`rust/wa-host/src/subagents.rs`.

| Class | Codes | Where |
| --- | --- | --- |
| **spilled** (`orchestrator.lua:176-178`: pin dropped, next candidate) | `node_full` (rust subagents.rs:532), `queue_full` (525), `subagent_runtime_unavailable` (479), `workspace_destination_source_missing` (workspaces.lua:197,201) | `unadmitted` at orchestrator.lua:117-118 |
| of those, **shell kept for the retry** | `node_full`, `queue_full`, `subagent_runtime_unavailable` | `RETRYABLE_ADMISSION`, subagents.lua:33, used at 624 |
| **terminal `refused`** (`orchestrator.lua:179-184`; `cancel` retracts it, 224-229) | *every* start error that carries `not_started` — i.e. everything else, because `mark_unadmitted` (subagents.lua:639-642) stamps it on any error without a `subagent_id` | — |
| … the ones that matter in practice | `workspace_source_dirty` (268), `workspace_source_unavailable` (167), `workspace_source_not_git` (113), `workspace_source_root_missing` (115), `workspace_source_inspection_failed` (120), `workspace_owner_mismatch` (152) — preflight; `workspace_allocation_failed` (303), `workspace_verification_failed` (309), `workspace_binding_*` (55-65), `workspace_released_or_release_unresolved` (232), `workspace_allocation_uncertain` (89,91), `workspace_destination_exists` (285), `workspace_argument_unsafe` (280), `workspace_exec_*` (24,26), `workspace_git_failed` (34), `workspace_session_not_found` (228), `workspace_requirement_failed` (230), `workspace_record_unavailable` (337) — after the shell, which is then retired (624); `idempotency_key_conflict` (556), `idempotency_key_retired` (562); `profile_exceeds_caller:<tool>` (238), model/reasoning approval, `provider.unservable` (482), `cost_budget_requires_rates` (501), `subagent_token_budget` (528), `event_conversation_not_in_profile` (441) — before the shell; native `recovery_error:*` (rust:501), `subagent_id_exists` (522), `record_write_failed:*`, `thread_spawn_failed:*`, `invalid_id` (486), `owner_user_required` (490); `forbidden_subagent`/`predecessor_unknown`/`session_tail_changed`/`session_tail_unobserved:*`/`prompt_too_large` (rust:538-554,648 — only on a continuation, not placement) | — |
| **parked `unknown`** (`orchestrator.lua:185-190`; nothing re-sent) | `dispatch_uncertain` (orchestrator.lua:170), `remote_unreachable` (nodes.lua:465,528), `forbidden_peer_action` (server.lua:551), `wrong_target`, peer verify refusals, `forbidden_role` (521); a non-table answer; a table with neither id nor error; **and any error from a destination that does not stamp `not_started`** | — |

**No code in the current tree is left without a class** — `mark_unadmitted` is a catch-all on the start
path, and a `not_started` refusal never returns to the queue. Two gaps are where the next leak lives:

* **Gap A (version-coupled classification, the important one).** The class of a refusal depends on a
  *flag from the destination*. A peer running pre-delivery code sends none, so the exact codes the live
  leak produced (`workspace_allocation_failed`, `workspace_session_not_found`) are classified
  `uncertain` → parked → and that peer refuses `resolve` (`forbidden_peer_action`) → `reconcile_failed`
  → the row is stuck (case E). Not a resource leak, but a task that neither runs nor cancels.
* **Gap B (the pin tests one direction).** `spills_on` has 4 codes, `RETRYABLE_ADMISSION` has 3; they
  differ by `workspace_destination_source_missing`. Today that is safe *only* because that code is
  refused before the shell exists (`subagents.lua:533-540` before 549-580), not because of anything the
  code lists say. The fixture pins `RETRYABLE ⊆ spills` and that `workspace_source_dirty` is not
  spillable (`scripts/test-placed-child-workspace.lua:263-270`) — not the reverse. A future fifth spill
  code that is refused *after* the shell exists would restore one session+worktree per tick per row and
  the existing pin would stay green.
* Two judgements worth naming, not bugs: `workspace_source_dirty`/`workspace_source_unavailable` are
  treated as *terminal*, although another candidate with a clean source could have taken the task — the
  one place where "refused = no candidate can take it as it stands" is narrower than the code. And the
  spill loop is uncapped and un-backed-off (the delivery says so): 3 refused rows cost ~1.1–1.4 s of a
  tick here (~0.4 s per row, ~2 `git` processes per reused attempt through `ensure` →
  `verify_binding`, workspaces.lua:234-238); at the 32-row ceiling of one tick that is tens of seconds
  per 2 s cadence.

## 3. Can one task run twice? Not in the paths I could execute

Fixture `scripts/review-reconcile-handshake.lua`, one node, **real** `host.subagent("resolve")`
(durable records) behind a stubbed `start` hop, 27 checks, two consecutive runs green:

* **"found" for a key it never started** (forged answer): `orchestrator.lua:245-248` adopts the receipt
  and sends nothing. Measured: the runtime holds 0 runs for that key, the row sits `admitted` with
  `subagent_id = "not-a-real-run"`, and every later read is the destination's `unknown_subagent`
  (`orchestrator.lua:263-270` returns the raw error). So a wrong "found" **loses** the task; it cannot
  duplicate it.
* **an answer arriving after the coordinator re-placed the task** (the real race): park → `resolve`
  says `found:false` → `queued` + pin dropped (231-251) → the *original* request then arrives and is
  admitted by the runtime → the next tick re-sends the same key (`args.idempotency_key=row.id`,
  orchestrator.lua:167-169) → the runtime deduplicates (`rust/wa-host/src/subagents.rs:504-516`) →
  **one run**, the row adopts the late run's `subagent_id`, and no second child session is written.
  This is the case that would have run twice if the key were not the row id.
* **two coordinators ticking**: the tick itself is one dedicated thread (`rust/wa-host/src/serve.rs:1336-1342`,
  a 2 s loop), so ticks do not overlap each other; but a coordinator's tool call (`reconcile`/`cancel`)
  runs on a *run worker's* Lua state against the same SQLite DB. The reconcile updates
  (`orchestrator.lua:246-247`, `249-251`) are `WHERE id=?` with **no state guard**, unlike the tick's
  reservation (`WHERE id=? AND state='queued'`, with a `changes ~= 1` check, 162-165). Interleaving a
  reconcile-answered-`false` with a concurrent admission can therefore clobber `admitted` back to
  `queued` — the next tick re-sends and the key dedupes, so still no second run, but the row can flip
  and `attempts` grows. A one-line `AND state='unknown'` (and a `changes` check) would close it.
* **`resolve` under a different lock than admission**: **CONFIRMED same lock** in the native code —
  admission holds `tasks` then `idem` (`rust/wa-host/src/subagents.rs:500-516`, insert at 585-587 under
  the tasks guard), `resolve` reads in the same order (755-763). Caveat: the map is per-process and
  rebuilt from the record directory once at boot (`recover`, 357-440), so a *second process* over the
  same runtime root answers from a map it loaded earlier (rust:750 already states this hazard). The
  guarantee is the idempotency map; `resolve` only makes the lookup atomic with an admission *inside
  that process*.
* **a key reused by a new request**: the shell guard refuses another caller/node/parent
  (`idempotency_key_conflict`, subagents.lua:551-559), the runtime dedupes by `owner_user␁key`
  (rust:505), and the delivery's fixture pins both. **CONFIRMED.**
* **UNVERIFIABLE**: anything that needs the real peer hop — a signed `nodes.remote_call` carrying
  `not_started`, and `resolve` answered by another machine. The settling scenario: two nodes, one
  coordinator, destination B refuses `node_full` twice, the answer to the third delivery is dropped in
  transit, then `subagent{action="reconcile", id=<task>}` and `resolve` must come back over the relay
  and adopt/dedupe; plus one old-binary peer to confirm the case-E stuck row.

## 4. The held-session residual, quantified (reported, not implemented)

* **What holds it**: the destination's own `sessions` row (`workspace_required=1`,
  `workspace_state=allocated`, a real worktree) named `child:<task id>`. Measured in check 1: one per
  queued row, `…/wa-worktree-childdispatch<uuid>`. Nothing in the coordinator references it after the
  task is admitted elsewhere; the destination cannot see the coordinator's queue (`resolve` answers
  only "does a key own a run"), and only `M.start` ever retires a shell (subagents.lua:624,630, and the
  `ensure` failure path ~592).
* **How many**: one per (task, refusing destination) pair whose refusal was retryable — bounded per
  pair now (that is the fix), but summed over the eligible candidates of every still-queued row:
  `128` queued placements per owner (`orchestrator.lua:76-79`) × ≤ `32` policy nodes
  (`M.validate`, orchestrator.lua:22-40) ≈ **4096 sessions + worktrees** in the worst case, at the
  ~9 MB per worktree the live report measured. It is not reaped at all today.
* **Smallest honest fix** (not implemented here): let the coordinator tell the destination to retire
  the unadmitted shell for a key it is no longer asking — one peer action (`resolve` already looks the
  key up under the admission lock) at the two transitions where the shell becomes garbage: adopted
  elsewhere and cancelled/refused. It needs no new state, and it is the same key the retry uses, so it
  cannot touch another request's thread.

## 5. Two of the delivery's own pins reproduced

`node scripts/test-placed-child-workspace.cjs rust/target/release/wa.exe` → exit 0:
`placed child workspace ok (74 checks)`, `unprepared destination refused: workspace_destination_source_missing: …`,
`placed child workspace ok (24 checks)`, `placed child workspace integration ok (10 harness checks; real
git checkouts, real placement path, no inference)`. `node scripts/test-session-workspaces.cjs …` → exit 0
(`workspace release ok (21 checks)`, `session workspaces integration ok (11 checks; real git worktrees,
two concurrent processes, restart, no inference)`).

Negative controls (scratch patches, both restored, `git status --porcelain` shows only the untracked
review fixtures):

* **foreign path never used** — `lua/core/workspaces.lua:154` `usable = source ~= nil` (drop the node
  check) → the fixture fails with its own assertion:
  `AssertionError: prepared destination exit 1: lua error: a path recorded on another node is never the source, even when it exists here`.
* **`node_full` twice leaves one session and one worktree** — `lua/core/subagents.lua:549`
  `shell_id = nil` → the fixture fails at:
  `AssertionError: prepared destination exit 1: lua error: the shell is named by its key, so the retry can find it: child:placed-retry`.

Both pins are live, not decorative.

## 6. Scope and receipt

`git diff --name-only origin/main...ee15da2` = 13 files: **6** under `lua/` (completions, orchestrator,
server, subagents, tools, workspaces — the brief says 7), 5 under `scripts/` (two new fixtures, two
edited fixtures, `test.sh` wiring at scripts/test.sh:746-749), 2 docs. `git diff --stat
origin/main...ee15da2` = 992 insertions / 78 deletions.

`docs/ORCHESTRATOR-WORKSPACE.md` is **not new** (141 lines on `origin/main`); it is the existing home of
the placement contract and the only doc that says `node_full`/`spilled`. What *is* new is duplication:
the placed-child source rule is now stated in `docs/EXECUTION.md:110-123` **and**
`docs/ORCHESTRATOR-WORKSPACE.md:99-108`, and "a retry must have the effect of the attempt before it" in
`docs/EXECUTION.md:124-127` **and** `docs/ORCHESTRATOR-WORKSPACE.md:84-97` — both files edited by this
same delivery, with the third home being the code comment at `lua/core/workspaces.lua:96-136`. I found
no in-flight sibling refactor of these docs in this repo's refs (`git log --all -- docs/ORCHESTRATOR-WORKSPACE.md`
shows only `1fe6018`, `0cee3aa`, `0176de4` and this delivery's two commits); `change/orchestrator-workspace`
is the original placement branch from `0176de4`, not a consolidation. If a protocol refactor is
consolidating this, it is not visible from this checkout, so I can only name the duplication. Both docs
are accurate as code descriptions except the two sentences in check 8; I did not edit either.

## 7. Cleanup evidence (for the factory's cleanup phase; nothing deleted)

Measured read-only, on the canonical checkout:

```
git worktree list | wc -l                          -> 1371
git branch --list 'change/*' | wc -l               -> 1336   (report said 1035; it has grown)
git branch | wc -l                                 -> 1350
git worktree list --porcelain | grep -c prunable   -> 0
ls -d C:/Users/Victor/.wasm-agent/wa-worktree-* | wc -l -> 1323   (report said 1322)
registered paths whose directory is missing        -> 0
git branch --merged origin/main --list 'change/*' | wc -l -> 1327
```

`git worktree list --porcelain` minus the `wa-worktree-*` and benchmark paths leaves the canonical
checkout `C:/Users/Victor/orca/projects/wasm-agent` and a few dozen `benchmarks/edit-workflow-*` trees —
i.e. the 1323 session worktrees plus benchmarks, not the agent lanes (the lanes are separate checkouts
under `orca/workspaces/wasm-agent/`).

**Trees that must never be touched**: the primary/canonical checkout (the only tree on `main`), the
node's own worktree and the lanes by role, and — the part that is easy to get wrong — the worktree of
any session that is still live, *including the one this review runs in right now*
(`wa-worktree-7db14e40-…`, on its own `change/wa-session-7db14e40-…` branch). I did not query the live
session store or any process table (that is live state), so I cannot name the live ones from evidence;
a reap has to establish that itself.

**A safe reap must check, in order**: (1) it is not the primary worktree (first `git worktree list`
entry; its gitdir has no `worktrees/` component); (2) it is not a role tree by name and not the tree of
a session that is still live — quiescence (session has `ended_at`, no process holds the path), never
age; (3) `git -C <tree> status --porcelain` is empty; (4) the branch tip is reachable from a pushed ref
(`git branch --merged origin/main` covers 1327 of 1336 today) so no delivery is lost; (5) placement is
still OFF and no new child is placing, or the reap races the fabric. Then `git worktree remove` **first**
(removing the directory by hand leaves the registration behind — which is how 1371 registrations exist
with 0 prunable), then `git branch -d`. I neither pruned nor removed anything.

## 8. Where the summary is wider than the code

1. `docs/ORCHESTRATOR-WORKSPACE.md:82` — "all-full work stays durably queued **(asserted by the
   two-node fixture)**": no fixture asserts that. `scripts/test-peer-run-admission.cjs` contains no
   `node_full`/`queued`/placement assertion (grep), and the fixture that does assert the requeue
   (`scripts/test-placed-child-workspace.lua` section 7) is single-node. The durability is asserted;
   "two-node" and "all-full capacity" are not.
2. `docs/ORCHESTRATOR-WORKSPACE.md:71` — "a request still in flight there is waited for rather than
   raced": `resolve` is serialized with an admission *inside the runtime* (same lock order,
   rust:500-516 vs 755-763), but a request still in the transport is invisible to `resolve`; the actual
   guarantee is the destination's idempotency map (my case C). The sentence credits the lock for
   something the lock does not do.
3. `docs/ORCHESTRATOR-WORKSPACE.md:57` — "These are **exactly** the refusals that keep the child
   session a refused attempt created": 4 spillable codes vs 3 shell-keeping codes; the difference is
   safe today for a different reason (pre-shell preflight), and the pin cannot catch a new divergence
   (check 2, gap B).
4. Minor: the brief's "7 under `lua/`" is 6; the "1035 stale `change/*` branches" is 1336 now.
5. The delivery's own admission — the peer `resolve` hop is reasoned, not measured — is **accurate**;
   so is its residual and the uncapped capacity loop, which I re-measured (check 2). One phrasing worth
   tightening: "an unobserved delivery is parked … instead of re-sent" is true of the *tick's* refusal
   branch, but a row left `placing` by a crash **is** re-sent by the next tick
   (`orchestrator.lua:145-165` keeps `placing` in the query and skips only the reservation) — safe only
   because the destination deduplicates the key, which is the same mechanism case C exercises.
6. The `view`→`error` wart is real and visible in my fixtures: `orchestrator.lua:50` puts the raw
   `detail` into `error`, so a refused or stuck row reports `{"error":"forbidden_peer_action"}` as its
   error string.

## What I did not do

No live two-node run (no cloud node, no relay, no peer binary of another version), so the peer hop is
unmeasured; no live node state touched (placement untouched and still OFF, no dispatch row placed,
cancelled or amended); no main merge, no push to main, no deploy, no restart; no worktree or branch
pruned; the delivery branch was merged into this review branch only, and the two falsification patches
were restored (`git status` shows only the untracked review fixtures and this report).
