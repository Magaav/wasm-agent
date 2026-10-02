# Independent review: `change/wave-activity-lifecycle` (tip `6a613380117ee07feddf5e89b5b52940a9b38d6a`)

Reviewer lane: `child:dispatch:8077a6cf-8e1d-42dd-b32f-75e4178fd598` (worktree
`C:/Users/Victor/.wasm-agent/wa-worktree-childdispatch8077a6cf-8e1d-42dd-b32f-75e4178fd598`),
branch `review/wave-activity-lifecycle`, base `6a61338` (1 commit ahead of `origin/main` `2f02b4c`).
The producer was `child:dispatch:eae7f780-048c-40ad-ac82-d7c4b7d7ccc2`; I did not produce this
delivery.

**Model note (as instructed).** This node's provider refuses `gpt-6-luna`
(`model_not_servable`), so this review ran on `deepseek-v4.1-flash`/high — the same family as the
producer. Independence here is the **lane**, not the model: different session, own worktree, own
fixtures, and every claim re-measured on the delivered tree.

**VERDICT: `narrowed`.** The core is real: the derived ON/OFF works, the live lane is not fenced,
the Orca-free proofs decide, and the migration is non-destructive and reversible. Nothing here
should block landing on the live-lane question — `produce`/`allocate` are admitted for a lane
producing right now, before and after the migration. Two things are narrower than claimed:
`land`/`admit` are **not** refused while the convergence is unverified in two reachable corners
(one of them a relaxation of a refusal that existed before this change), and the derived ON/OFF
has both a false-OFF and a false-ON shape that admission never consults.

## What I ran (all in my own worktree; nothing written to the live wave store)

* Copies of the live store: `cp -r <repo>/.git/wa-waves <scratch>/…` (read-only source, never opened
  for writing). Migration, `checkAdmission`, `create` and `inspect` were exercised **only** on copies.
* Pre-change code for every "before" comparison was extracted with `git archive 2f02b4c scripts` —
  the real old module, not a paraphrase.
* **Disclosed live read:** `activityInventory()`/`waveActivity()` were pointed at the live node
  runtime exactly as production derives it (the row's own verifier config `C:/Users/Victor/.wasm-agent`),
  so the live `memory.db` (712 MB) was opened with `{readOnly: true}` for `SELECT`s — the same read
  `wave-adapter.mjs`/`wave-proof.mjs` already perform. No write, no WAL/shm manipulation, no node restart.
* Not run: `scripts/test.sh` (full gate, out of scope), the migration against the live store, any
  push, any node/window restart. `test-wave-public.mjs` used the repository's own release build
  (`rust/target/release/wa.exe`, sha256 `69686dff…b905e`) — byte-identical to the installed binary,
  so the live install was never touched.

## 1. THE LIVE-LANE RISK — no blocking finding

Store read = **copy** of the live store; activity source = the **real** one
(`{kind:"node-runtime",repo:"C:/Users/Victor/orca/projects/wasm-agent",data:"C:/Users/Victor/.wasm-agent",process_probe:true}`).

```
activityInventory(real source): on=true  in_flight=4  managed_bindings=1345  git_worktrees=53
  session_store {ok:true, rows:1395}   processes {available:true, checked:203}   unresolved=5  leftovers=1339
  agents (4): child:dispatch:0a63f37c…, child:dispatch:ffda98e4…, child:dispatch:8077a6cf… (this review), …
              each turn.state="active", registered=true, corroborated=false
waveActivity(row): {"activity":"on","convergence":"open","runtime_state":"active","agents":4}
```

| phase | before the migration (old code) | after the migration (new code) |
| --- | --- | --- |
| `produce` | `ok:true` | `ok:true` (activity `on`) |
| `allocate` | `ok:true` | `ok:true` (activity `on`) |
| `land` | `ok:true` | `ok:true` (activity `on`) |
| `admit` | `ok:true` | `ok:true` (activity `on`) |

After `wave-migrate.mjs apply` on the same copy the row reports
`{"activity":"on","convergence":"legacy-unverified","runtime_state":"active"}` and all four phases
are still `ok:true`. **`produce` and `allocate` are not refused — the live lane is not fenced.**

`create()` on a copy of the live store, with the real source, refuses:
`previous_wave_active:wave-2026-10-02-subagent-chat-and-enforcement` — correct, and it shows claim (2)'s
"refuses only an ON previous wave" is enforced against the real inventory.

**A fresh wave created while the previous is idle works** — measured on fixture stores where the
derived verdict is genuinely `off`: `create()` returned `ok:true` and the new row was admitted in
five independent shapes (no sessions; a `running` row with nothing in flight; an unowned registered
tree; a live turn with no tree; a binding mid-release), and `test-wave-derived-state.mjs` asserts the
same (`second.ok===true`, `previous.activity==='off'`). With a real in-flight child it refuses
(`previous_wave_active`). Note: on the **live** repository today `create()` is additionally refused by
the lane boundary — `lane_boundary_enter_refused:lane_boundary_check_failed:enter:node
skills/git-orchestrator/scripts/audit.mjs verify . origin/main|lane_boundary_detector:integration_incomplete`
— which is the detector working, not a defect.

## 2. Can ON/OFF lie? Yes, in both directions — and admission never reads the named reasons

| shape | verdict | consequence |
| --- | --- | --- |
| a **running turn with no worktree** | `on:false`, `unresolved:["stale_in_flight_turn_without_a_registered_worktree"]` | `create()` **ADMITTED the next wave** |
| a **live turn whose tree exists but is not registered with Git** | `on:false`, same named reason | `create()` **ADMITTED the next wave** |
| a **turn running while the binding is `releasing`** | `on:false`, `unresolved:["binding_transition_unresolved_releasing"]` | `create()` **ADMITTED the next wave** |
| a crashed finisher's row left `running` | `inspect.state="idle"`, `bookkeeping_state="running"`, `activity:"off"` | correct: a row never makes the wave active |
| a child with a real registered tree, no session row | `on:false`, `unresolved:["unowned_managed_worktree"]` | `create()` admitted; completion proofs fold it in |
| a **stale `child_completions` row** (parent open+allocated, real tree, no turn, no process) | `on:true`, `corroborated:false` | `create()` refused `previous_wave_active`; only that row can clear it |

The probe cannot produce a false OFF — it only fills `corroborated`, and it cannot veto. It *is* a
false-negative corroborator in production: all four genuinely running live lanes reported
`corroborated:false`. The false OFF comes from the tree requirement (`if (!treePath || !exists || !tree)
{ … continue; }`), not from the probe.

The asymmetry worth naming: the delivery's own principle — *a durable row is bookkeeping, not
evidence that anyone is working* — is applied to the wave row but **not** to `child_completions`,
whose `running` state alone makes the wave ON. Because the probe is designed never to veto, no
observation can clear a stale child row: "an idle wave never blocks the next" fails in that direction.
Conversely, the false-OFF shapes are named in `unresolved`, but `create()` and `checkAdmission()`
read only `activity`; the name is consulted by the *completion* proofs, not at admission.

## 3. Suites and mutations

Delivered suites, run on the delivered tree (all green):

```
test-wave-derived-state  55 checks   test-wave-no-orca        47 checks
test-wave-lifecycle      44 checks   test-wave-proof          33 checks
test-wave-public         23 checks   test-wave-restart        14 checks
test-wave-monitor-budget 16 checks   test-wave-retire         20 checks
```

Mutations in a pristine copy (`git archive HEAD`), one at a time; "RED" = the suite failed:

```
derived-state=RED  no-orca=green lifecycle=green  proof=RED*   M-A ON/OFF derived from the durable row again
derived-state=RED  no-orca=green lifecycle=green  proof=RED*   M-B the process probe VETOES instead of corroborating
derived-state=RED  no-orca=green lifecycle=green  proof=RED*   M-C the legacy convergence is no longer named
derived-state=RED  no-orca=green lifecycle=RED    proof=RED*   M-D create() refuses ANY previous row
derived-state=RED  no-orca=green lifecycle=green  proof=green  M-H create() admits while a child is in flight
public=RED restart=RED (all others green)                      M-E an IDLE wave refuses produce/allocate
public=RED restart=RED (all others green)                      M-G a BLOCKED+idle wave stops refusing land/admit
```

\* `test-wave-proof.mjs` is RED in that extraction only because it needs `skills/parallel-evolution/`;
in the full tree it is green (33 checks) and unaffected by M-A…M-D. Six mutations are pinned by the
suites, including the live-lane regression (M-E) — caught by `test-wave-public` and `test-wave-restart`.

## 4. Orca absence cannot skip the assertions — proven, including against a *lying* third party

`test-wave-no-orca.mjs` passes (47 checks) with a real `orca` 1.4.201 reachable on this machine's
PATH, and with the suite's own sanitized PATH. I added an independent 24-check attack
(`review/wave-activity-lifecycle/attack4-liar.mjs`) using three conditions: **absent**, **broken**
(exits nonzero with a stack trace), and **lying** — a real `orca.exe` that exits 0 with a complete,
well-formed inventory claiming the unowned tree is a healthy card:

```
liar attack ok (24 checks; absent, broken and LYING third parties all reach the same verdicts,
the assertions still decide, and the lie is advisory evidence only)
```

With the liar consulted (`evidence.orca_view.used=true`) the registry proof still refuses
`unowned_worktree_registration` and the ownership proof still refuses `unowned_managed_worktree`;
`decision_input:false` is recorded; removing the offending tree makes the same assertion PASS, so it
is not vacuous. No required-orca marker remains in `wave-owners.mjs` / `wave-adapter.mjs` /
`wave-proof.mjs`; the only remaining `orca` invocations are the opt-in viewer and
`wave-audit.mjs`'s `WA_WAVE_ORCA_VIEW=1` advisory block.

## 5. Migration review — non-destructive and reversible on a copy

On a copy of the live row (`state=pending`, three steps pending, `active_repo` present):

* `plan` is read-only and names the row, its steps, the original columns and the index it will drop.
* `apply` moved **no original column**. Column-by-column diff of the whole store:

```
table events: rows 2 -> 3    + ADDED 3
table steps:  rows 3 -> 3
table waves:  rows 1 -> 1    ~ … .legacy: null -> "{\"schema\":1,\"kind\":\"derived-activity-migration\"…
indexes DIFFER  - index active_repo:CREATE UNIQUE INDEX … WHERE state!='complete'
                + index waves_repo:CREATE INDEX waves_repo ON waves(repo, created_at)
TOTAL_DIFFERENCES=2
```

* `revert` restored the row **exactly** (`table waves: rows 1 -> 1`, zero column differences; steps
  unchanged), removed `migration.json`, and restored `active_repo`. The only residue is the
  append-only journal (two added events) — by design.
* Nothing is unrecoverable: the row's own columns were never touched, and `revert` refuses if the row
  moved since the migration.
* **One real defect.** `apply` writes `migration.json` with `flag:'wx'` *after* committing. With the
  unique index gone, two waves in one store is now reachable, and the second `apply` throws after its
  transaction has committed:

```
first apply  => {"ok":true,"record":"migration.json"}      migration.json names: first
second apply => THREW EEXIST: file already exists, open '…\state\migration.json'
rows now: [{"id":"first",…,"migrated":1},{"id":"second",…,"migrated":1}]
```

The second wave is migrated with **no durable record**; the caller sees an error. Recovery still works
(`revert(second)` succeeded from the row's `legacy` column and left `first`'s record alone), so this
is not data loss — but "writes `migration.json` beside the store (never overwritten)" does not hold
for the second wave.

## 6. What the unique-index removal gives up

"One wave at a time" was a safety property, and it is now only a *checked* one — `create()` refuses
when the previous wave is ON, but nothing prevents two unfinished rows existing. Measured on a fixture:

```
indexes after create():       ["sqlite_autoindex_waves_1","sqlite_autoindex_steps_1","waves_repo"]
indexes after a SECOND create(): same (no active_repo)
readers_see: {"id":"a-two-waves-second","state":"pending"}
rows_in_store: [{"a-two-waves-second","pending"},{"a-two-waves","pending"}]   ← two unfinished waves
the older row: steps ["land:pending","deploy:pending","retire:pending"], next_action "advance"
wave-migrate plan without an id also picks: a-two-waves-second
```

**What a reader sees: nothing.** `checkAdmission`, `monitor`, `inspect`-by-latest and
`wave-migrate plan` all take `ORDER BY created_at DESC LIMIT 1`; the older unfinished row is an
orphan reachable only by naming its id, and its steps are never advanced. A `created_at` tie between
two rows is also unspecified by that ordering (20 consecutive reads picked the same row here, so this
is an unproven risk, not a demonstrated flip). Second, smaller consequence: `revert`'s restored
`active_repo` is dropped again by the very next `open()` — `wave-lifecycle.mjs`'s `open()` runs
`DROP INDEX IF EXISTS active_repo` unconditionally, verified on the reverted copy:

```
indexes BEFORE any wave command: [ … ,"waves_repo","active_repo"]
create() threw: previous_wave_active:wave-2026-10-02-subagent-chat-and-enforcement
indexes AFTER the first open()-using command: [ … ,"waves_repo"]
```

So the index reversal is transient, and the migration's `one_row_per_repository_index.restored:true`
is true only until the next `create`/`advance`.

## 7. Freeze, lane boundary and retirement — intact, and the edited prose overstates one rule

* `scripts/wave-retire.mjs`, `scripts/lib/lane-boundary.mjs`, `scripts/lib/wave-guard.mjs`,
  `scripts/wave-legacy.mjs` are **not in the diff** (`git diff --stat 2f02b4c 6a61338 -- <files>` is empty).
* The freeze and `complete` refusals are unchanged code and mutation-sensitive: M-E and M-G both turn
  `test-wave-public.mjs` (which asserts the freeze refusal, the `observe`-without-`admit` read-only
  path, and the blocked wave) RED.
* The lane boundary is live: `create()` refused on the real repository with
  `lane_boundary_enter_refused:…|lane_boundary_detector:integration_incomplete` while lanes are unfinished.
* **`skills/git-orchestrator/SKILL.md` and `docs/WAVE-CONVERGENCE.md` say more than the code does.**
  Both state that landing and independent delivery admission "stay refused while the convergence is
  unverified". Measured on copies of the live row:

| shape | `produce` | `allocate` | `land` | `admit` |
| --- | --- | --- | --- | --- |
| idle + `pending` (the live row as it is now) | ok (both) | ok (both) | ok (both) | ok (both) |
| idle + `blocked` | old: refused `wave_blocked` / new: ok | old: refused / new: ok | refused `wave_convergence_unverified` (both) | refused (both) |
| idle + **migrated legacy row** | ok | ok | **ok** (convergence `legacy-unverified`, `runtime_state unverified`) | **ok** |
| **active** + `blocked` | old: refused `wave_blocked` / new: ok | old: refused / new: ok | **old: refused / new: ok** | **old: refused / new: ok** |

The `if (verdict.activity === 'on') return ok` short-circuit runs **before** the blocked refusal, so
while any lane is in flight (the normal case during work) a blocked wave admits `land` and `admit` —
refusals that existed before this change. And a migrated legacy row, whose `runtime_state` the
delivery itself names `unverified`, admits `land`/`admit` even when idle. No regression for the live
row (which is `pending` and was admitted before too), but the claim as written is false in both corners.

## Proven vs unproven

**Proven:** the live lane is not fenced (all four phases, copy of the live store, real inventory,
before and after the migration); `create()` refuses an ON previous wave and admits an idle one; a
`running` row never reports active; `inspect()` reports `idle` with `bookkeeping_state` preserved;
unverifiable convergence is a named state (`unverifiable`/`legacy-unverified`), never a completion;
the ownership/registry proofs reach identical verdicts with Orca absent, broken and lying, and still
decide; the migration is non-destructive and column-exact and reverts exactly; 252 delivered checks
green plus 24 reviewer checks; six mutations red; freeze/lane-boundary/retirement files untouched.

**Unproven / unmeasured:** the `created_at`-tie ordering flip (argued from SQL semantics, not
observed); behaviour of the derived rule under a real concurrent `create` race (no two-writer test
was run); whether a stale `child_completions` row can arise in practice (constructed by me, not
observed live); the second-wave `EEXIST` path under a real migration (constructed on a fixture);
`test-wave-monitor-budget`/`retire`/`public` were run in my worktree, not as part of the full gate.

**Should anything block landing?** No — the live-lane question is answered and the Orca-free proofs
hold. I would land only with the two claims narrowed: fix or restate the `land`/`admit` rule (the
guard belongs outside the `activity==='on'` short-circuit and should cover a `legacy-unverified` row),
and record the derived rule's false-OFF/false-ON shapes (a turn without a registered tree; a stale
child row) plus the orphan-when-duplicated consequence of dropping `active_repo`.

Agent: wasm-agent node=wasm_the_first role=reviewer session=child:dispatch:8077a6cf-8e1d-42dd-b32f-75e4178fd598
