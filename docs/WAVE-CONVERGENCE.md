# Durable evolution wave closure

## The wave is ON while agents work, OFF when they do not

The wave's ON/OFF is a **derived** fact, not a stored one. The durable row keeps
bookkeeping (`pending`/`running`/`blocked`/`complete`) and a receipt, but it is never
evidence that anyone is working: a crashed finisher leaves `running` behind with nothing
running, and a row left `pending` says nothing about whether a lane is live.

> The wave is ON while any child/agent **for this repository** is in flight, and OFF when
> none is. Every time an agent is working the wave is on; when all are off the wave is off.

`scripts/lib/wave-activity.mjs` reads that fact from the node's OWN records - never from a
durable row and never from a third-party CLI:

| source | what it proves |
| --- | --- |
| `memory.db` `sessions` (`worktree`, `workspace_required`, `workspace_state`, `workspace_branch`, `workspace_source_path`, `workspace_start_state`, `ended_at`) | who was given which tree, whether that binding is still allocated/parked/released, and the runtime owner identity (`runtime:<session>:<boot>`) |
| `memory.db` `steering_runs` / `child_completions` | the node's own record of a turn running now (or a child dispatched and not settled) |
| `git worktree list --porcelain` of the repository | what Git itself believes: real registrations, tips, branches, detached/locked/prunable |
| a local holder probe (Win32 CIM / `ps`) | corroboration only: a process naming a live agent's tree. It never vetoes an agent, because a turn is between process spawns more often than a lane is idle |

An agent counts as **in flight** when its session is still open (`ended_at IS NULL`), its
binding is not released/parked, the node records a running turn (or an unsettled child) for
it, and the tree it runs in is really there and really registered. A turn left behind by a
tree that has gone is reported as `stale_in_flight_turn_without_a_registered_worktree`, not
counted as activity. A binding that is neither resolved nor in flight is a **leftover**
(`managed_binding_not_reconciled`): work a retirement plan may still be settling, reported
separately from a hard inconsistency.

`waveActivity()` reports, for any row:

| field | values | meaning |
| --- | --- | --- |
| `activity` | `on` \| `off` \| `unverifiable` | the ON/OFF fact. `unverifiable` means the node records could not be read at all - it is named, never guessed |
| `convergence` | `verified` \| `unverified` \| `legacy-unverified` \| `open` | whether the wave's own completion was proved |
| `runtime_state` | `complete` \| `active` \| `unverified` \| `idle` | what the wave reports. `active` is only ever derived from real activity |

A wave whose convergence genuinely could not be verified is a **named** state (`blocked`
durably, `unverified` in the derived report, with its exact reason - an unknown effect, an
unresolved claim, a missing full-gate receipt). It is never silently treated as complete.

### What each boundary does with it

* `create()` refuses only when the previous wave is **ON** (`previous_wave_active:<id>`). An
  idle wave never blocks starting the next one, whatever its bookkeeping says; its named
  convergence is recorded in the new wave's creation event and returned as `previous`.
  When no activity source can be resolved at all it fails closed
  (`previous_wave_activity_unverifiable`), and production `start` requires a concrete source.
* `checkAdmission()` admits producing and allocating while the wave is ON (that is how lanes
  work under an umbrella) and while it is OFF (`produce`/`allocate` keep being admitted, so an
  idle row cannot fence live lanes). A closing freeze and a `complete` row still refuse as
  before. The repository-level acts - `land` (the merge lane) and `admit` (independent
  delivery admission) - stay refused while the convergence is unverified, with the named
  reason `wave_convergence_unverified:<reason>`.
* `inspect()` never reports an active state with nothing running: a durable `running` row
  whose owner is provably gone and whose inventory is empty is reported as `idle`, with the
  durable value preserved as `bookkeeping_state`.
* The one-row-per-repository unique index (`active_repo`) is **replaced** by a lookup index.
  It encoded "at most one unfinished wave per repository", which is exactly the rule that is
  gone; a SQL index cannot see whether agents are working. The refusal moved into `create()`,
  which reads real activity. `scripts/wave-migrate.mjs` reports this and can restore it.

## Migration of a legacy durable row (explicit, non-destructive, reversible)

A live example sat in the shared store: `wave-2026-10-02-subagent-chat-and-enforcement` in
`pending` with its three steps never run, although no agent was working and all its work was
in `main`. Under the derived rule that row fences nothing, but it is still a wave whose
convergence was never verified, and that stays visible.

```text
node scripts/wave-migrate.mjs plan   <store-dir> [wave-id]
node scripts/wave-migrate.mjs apply  <store-dir> <wave-id> [actor]
node scripts/wave-migrate.mjs revert <store-dir> <wave-id>
```

`apply` moves **no original column**: `state`, `reason`, `receipt`, `owner`, `created_at`,
`updated_at`, `manifest` and every step row are left exactly as they were. It records the
exact original bookkeeping in a new additive `legacy` column and in the append-only event
journal, and writes `migration.json` beside the store (never overwritten). The row then
reports `convergence: legacy-unverified`, which is a named state: its steps never ran and its
convergence was never verified. `revert` refuses if anything moved since the migration,
clears `legacy`, removes the record and (when it still can) restores the `active_repo` index -
the original columns were never touched, so the reversal is exact by construction. Admission
keeps admitting producing and allocating throughout.

## Sanctioned entry and repaired proof boundaries

Use `wave-entry.mjs register <canonical-main> <config> <bootstrap-admission>`
once, then `start <repo> <manifest>`. Registration and the store live at the real
shared Git directory's `wa-waves/registration.json` and `wa-waves/`; a caller
cannot choose a new store to repeat bootstrap. Bootstrap admission binds current
main/local-ref inventory and independent issuer/reviewer. No producer in this
delivery activated live registration. Registration with no started wave,
malformed/missing activation, blocked progress, and a closing freeze refuse
actual new workspace allocation and producer/admission hooks. Private local
temporary Git fixtures are identified explicitly and never claim production
verification. The throughput dependency wires real finish/admission/merge
consumers through `lib/wave-guard.mjs`; source Lua allocations and existing
managed writers use the same `checkAdmission` guard.

Public start registers the approved `wave-convergence` sentinel schedule using
`wave-monitor.sh`. That external procedure resumes the registered shared wave,
never creates another one. A dead runner's interrupted effect is unknown and
blocked rather than replayed. At most three continuation admissions and 120
liveness observations are allowed; exhausted observation preserves the owner
and records an actionable blockage. **A tick that found the owner alive is not
an observation and spends none of that budget**: `monitor()` used to increment
`monitor.observations` before it asked whether the owner was alive, so a wave
being driven by a live owner reached
`external_monitor_observation_budget_exhausted_owner_preserved` on its 121st
tick - about one hour at the schedule's own declared `every_seconds: 30` - and a
blocked wave then fences every future admission. The observation that spends the
budget is now the one that did *not* find the owner, and the cap still blocks
(`scripts/test-wave-monitor-budget.mjs`: 200 real `monitor()` ticks with a live
owner spend 0, an owner identity the lease proves absent spends 1 per tick, and
a counter preset past the bound blocks on the real `monitor()` call).

**Where each bound is actually met, recorded because the numbers above read as
if 120 were the binding limit.** A dead owner is normally blocked by the
*restart* budget first: three continuation admissions, so the fourth tick blocks
with `external_monitor_restart_budget_exhausted` and the wave stops being
observed at all. The 120-observation bound is therefore a backstop for a wave
whose owner identity cannot be resolved at all, not the limit an operator will
meet in practice. Two consequences of the fix are also worth stating rather than
leaving to be rediscovered: a counter already past the bound is **not** a fence
while the owner is alive again (a live tick returns before the budget is read,
and the counter is preserved, so the next tick that finds no owner blocks
immediately), and a live tick neither spends the counter nor blocks the wave.
All three are asserted in `scripts/test-wave-monitor-budget.mjs`.
Complete/blocked disables the scheduled
job. A private local test may explicitly use `monitor_mode:external-cli-test`;
this does not replace production watcher registration. `watcher-definition`
prints the actual schedule/run procedure. Install must ship this shell and all
transitive wave modules before activation; no running binary/window is replaced
by these helpers.

### `start`'s sentinel preflight and the sentinel's `home` (recorded, blocking)

One precondition of `wave-entry.mjs start` is not satisfied on this machine, and
it is recorded here rather than fixed because the wrong value is in the wave's own
config, outside this repository. `start` invokes the configured sentinel's
`preflight` with `WASM_AGENT_HOME` set to the config's `home`; the sentinel reads
`WASM_AGENT_HOME` as a **home** and looks in `<home>/.wasm-agent/sentinel`, while
the config's `home` is the *config directory*. Measured 2026-10-02:

```
$ "<install>/wa-sentinel.exe" preflight
{"watcher":"running","watcher_pid":16712,...}
$ WASM_AGENT_HOME=C:/Users/Victor/.wasm-agent "<install>/wa-sentinel.exe" preflight
{"watcher":"not_running","watcher_pid":null,...}
$ WASM_AGENT_HOME=C:/Users/Victor "<install>/wa-sentinel.exe" preflight
{"watcher":"running","watcher_pid":16712,...}
```

So `start` fails its own preflight with `monitor_watcher_unverifiable` on this
machine, and the wave was recovered with the sanctioned
`wave-lifecycle.mjs resume`. Two things are needed before the next wave uses
`start`: the config's `home` field must mean the same thing the sentinel means by
`WASM_AGENT_HOME` (or `start` must stop overriding it and let the sentinel answer
for the machine it runs on), and `scripts/lib/service-target.sh` and `upgrade.sh`
must agree on that meaning - they currently read the same variable as a home and
as a config directory. This is a named, blocking precondition, not a claim that
`start` works.

Full-gate proof now uses the shared `fullProof/findFullProof` implementation and
the actual terminal `smoke ok` / `smoke ok (N skipped)` format. Retained and durable
combined receipts preserve their tested repository/head separately from storage
owner/candidate head, and explicit overrides must belong to the shared source
registry. Wrong kind/tree/exit/skip/hash/source rejects proof. Observation retry
counts and post argv/timeouts are validated as finite bounded integers before
admission and again when consumed from durable progress.

Delivery closure validates immutable tip/tree, actual reviewed tip/tree,
independent published reviewer anchor, admission owner/tip/tree, and ancestry of
the delivered tip inside both recorded landing and accepted main. A landing SHA
of main cannot hide an unmerged delivery. The binding remains verifiable after
its branch is retired. Final read-only observation is distinct from admitting
new work under a closing freeze.

Ownership and registry come from OUR OWN inventory, never from a third party. `ownerInventory`
reads the node's managed session workspaces and their recorded state, the real Git worktree
list, and the node's own turn/process records (`scripts/lib/wave-activity.mjs`): no unowned or
unresolved leftovers, exact tree/tip agreement, and parked/released bindings reconciled. A
registered managed tree with no session binding is `unowned_worktree_registration`; a binding
whose tree is missing, whose parked shape is not a detached exact tip, or whose transition
(`releasing`/`parking`/`*_unknown`) never settled is refused by name. If an Orca binary happens
to exist it may be used **only as an optional viewer** (`orca_view: true`), recorded as
advisory evidence with `decision_input: false`; its absence changes no verdict, and no proof
path requires it. `wave-adapter.mjs freeze <config> <issuer> <reviewer>` records the current
session/turn identity and exact tree-owner IDs after real combined operation/claim safety;
retirement rechecks that freeze (owner identity, the session's recorded branch, the exact tip)
before any effect. Runtime allocations record native executor boot/process/creation identity;
legacy path-only ownership is not silently promoted. Freeze is a cooperative repository
admission fence, not an OS sandbox against arbitrary privileged file writes.

Concrete adapters are `owner`, `owners`, `dependencies`, `safety`, `operations`,
`runtime-retire`, `reconcile`, and `registry-post`. Hosting dependencies use complete
GitHub pull pages bound to the configured origin namespace; actual local Git
transport has no hosting PR namespace and is labelled as such. Missing hosting
discovery is a refusal. Managed runtime removal/parking invokes real Lua under
the session resource fence with expected immutable HEAD, before the mutation.
Registry postconditions are read from Git's own worktree list and the session
binding: a removed tree is unregistered and its binding `released`; a parked tree
is a real detached exact tip with an empty branch and a `parked` binding. The
`retire` plan's owner fence is required before any effect, and only then - a target
whose binding is already released or parked has nothing left to settle.

## External legacy allocation-safety bridge

`wave-legacy.mjs <config> <bundle>` invokes native `legacy_adjudicate` only from an
external reviewed executor; a node turn or inherited in-turn marker refuses it.
The fixed runtime operations directory's `legacy-authority.json` must explicitly
contain trusted Ed25519 public keys and identity/drain/effects/review roles.
Private keys are never shipped. No live authority file was created by this
producer. The signer custody and genuine observer provenance are trusted operator
boundaries; a signed observation must represent an actual inspected fact.

A bundle pins ID, exact current state/object/hash, and every before-reconcile
original name/hash. Each separately signed artifact binds operation ID, normalized
canonical store identity, current state hash and the hash of sorted original
inventory JSON. Identity observes original process ID, actual OS creation stamp,
stable containment identity and preserved writer binary artifact/hash. Drain
matches those identities and supplies positive signalled-wait, exact-handle and
contained-member-exit observations. Current matching live identity is refused;
absence alone is insufficient because the signed positive drain is also required.
Windows stamps are `windows-filetime:<creation FILETIME64>`; Linux stamps include
kernel boot ID and process start ticks. Unsupported observation fails closed.

Effects supply nonempty scoped settled observations with actual artifact paths
and verified preservation hashes, `original_execution_outcome:unknown`,
`never_replay:true` and `quarantine_preserved:true`. A distinct authorized reviewer
binds all three source artifact hashes and the verdict
`allocation_safe_original_unknown`. Native validation checks signatures, role
separation, source/store/identity binding, originals, live identity, actual
preservation/binary bytes and evidence movement. It writes a separate
`legacy_quarantine` receipt/history and never rewrites state/output/originals or
claims execution success. Relevant lookup revalidates adjudicated evidence;
missing/moved/invalid evidence is an unresolved blocker again. Explicit replay
identities are rejected and every receipt remains visibly original-outcome-unknown.
Indexed pages stay bounded; an incomplete page cannot mean zero blockers.

`wave-legacy-map.mjs <data> <prior-evidence> <new-report>` reads full saved originals,
exact tool-result/artifact references and process/source journal leads. The actual
76-record mapping found three exact ledger bindings, seven PID/source leads, no
additional artifact bindings and **zero independently verified stable identities**.
Leads are not attestations. Neither age, mtime, elapsed time, empty output, a PID
mention nor a synthetic boot permits adjudication. All 76 remain explicit pending
proof in this producer task. The 46 uncertain resource claims continue through the
existing resource API only after exact original boot-lease and scoped effect
inspection; two missing-ledger cases remain visible. No live record/ref mutation
or claimed live closure occurred here.

The repair fixtures exercise actual native child identity/owned exit and signature
refusal, original byte preservation, invalid/moved evidence, exact real Git
review/admission/landing and actual retained/combined smoke schema, malformed
retry budgets, public shared admission/restart/no replay, real live claim refusal
and owned-drain reconciliation, native session-fenced removal, exact Git deletion,
and actual Orca create/park/refresh. The public contract fixture proves those
closure stages but intentionally lacks application deployment/full-gate evidence;
the overall wave correctly remains blocked. It is not a production deployment
receipt. Actual combined full gate/install/recovery and final legacy adjudication
remain coordinator/finisher acceptance requirements.

An authorized wave owns produce → independent verify → accept → land → deploy →
converge. Branch delivery and command exit are intermediate outcomes. A wave is
complete only after fresh proof of the clean next-wave baseline. The merge lane
alone moves canonical `main`; an external finisher closes its own producer lanes
after accepted settlement. No live tree is moved and no unknown effect is replayed.

## Operation attribution and indexed release

`wa-operation` records the actual starting directory even when requested cwd was
empty, canonical `effective_cwd`, process ID, a process-held `owner_boot` lease,
operation ID and owner. Admission enters `operations/index.sqlite` before spawn;
settlement updates it after the original state/output records. SQLite FULL writes
and an indexed unresolved-cwd lookup replace one full history scan per release.
An index write failure remains visible and cannot turn an accepted blocker into
successful cleanup. Windows extended path prefixes/case are normalized for lookup.
Unattributed legacy operations remain relevant to every target. A maintenance
command is not exempt: use a correctly attributed external executor outside the
tree it will retire. Cwd identifies possible workspace effects, not a sandbox
against commands that access other paths/network services.

Host actions through `host.operation(action,json)`:

| Action | Inputs | Result |
| --- | --- | --- |
| `relevant` | canonical/native `cwd`, optional lexical `after`, `limit` 1–256 | bounded unresolved rows, originals, `next` cursor and truncation flag |
| `index` | nonempty legacy-writer quiescence `evidence` | explicit one-time historical import; no original is rewritten |
| `reconcile` | `id`, exact raw durable `expected_state`, `owner_boot`, `evidence`, `drain_evidence`, `effect_evidence` | separate audited reconciliation; original execution outcome unchanged |

A fresh empty store is complete. An existing store refuses relevant lookup until
explicit import. Quiesce all legacy writers before importing, then prohibit mixed
old/new writers: an old binary does not participate in the index protocol. Import
reads `state.json.before-reconcile-*`; an unresolved original stays blocking even
if its manually edited current record says `never_spawned` or `no_live_containment`.
Unreadable records fail the transaction. Ordinary releases never scan history.

Reconciliation refuses a live/unverifiable OS lease, missing stable owner identity,
an exact-state mismatch, missing drain/effect evidence or an unindexed record.
Process death does not undo external effects. Legacy records without stable boot
identity require external investigation and remain explicit blockers; neither
elapsed time ≤50 ms, zero output, mtime before `serve.pid` nor an absent current PID
authorizes this API to manufacture settlement. Preserve originals and report the
decision still needed. This conservative boundary costs availability rather than
discarding uncertain work.

`workspaces.release` keeps the session claim, canonical path/binding checks,
dirty/ignored-file refusal and integrated-tip proof, and asks for only one indexed
relevant blocker. It never exempts the operation that happens to call release.
`workspaces.reconcile_release(memory,id,principal,evidence)` handles an already
missing directory with an allocated binding only after filesystem/Git absence,
session exclusion, integrated extant refs and relevant-operation proof. It changes
only the binding and records evidence. `reconcile_park(...,exact_head,evidence)`
records an already detached, clean, integrated exact tip as `parked`, with an empty
current branch; `ensure` refuses to silently reallocate a finished parked session.
Use `wave-reconcile-workspaces.lua` only with an exact session/principal/evidence
plan in `WA_WAVE_RECONCILE_PLAN`. It does not retire refs or infer effects.

## External wave runner

Run Node 24's SQLite-enabled CLI from an external native working directory that
will survive closure. Keep state outside every tree being retired:

```text
node scripts/wave-lifecycle.mjs create <state-dir> <manifest.json>
node scripts/wave-lifecycle.mjs advance <state-dir> <wave-id>
node scripts/wave-lifecycle.mjs inspect <state-dir> <wave-id>
node scripts/wave-lifecycle.mjs reconcile <state-dir> <wave-id> <evidence.json>
node scripts/wave-lifecycle.mjs resume <state-dir> <wave-id> "observed resolution"
node scripts/wave-lifecycle.mjs verify <manifest.json>
```

The immutable manifest has `id`, durable `owner`, native absolute canonical
`repo`, native absolute `executor_cwd`, exactly ordered `steps` named `land`,
`deploy`, `retire`, and six fresh `verifiers`: `operations`, `claims`, `runtime`,
`registries`, `deliveries`, `owners`. Each step/verifier has native argv without
shell interpolation. Effect steps also carry `post:{argv,max_attempts?}`; optional
`timeout_ms` is bounded at 10,800,000. Step `env` supplies the external driver
configuration. Never configure a node turn or a tree that will be removed as cwd.
Pin the approved driver/source in the reviewed manifest; changing it requires a
new reviewed plan, not editing the stored manifest hash.

`wave-executor.lua` is the real model-free effect driver. Invoke an external `wa`
with its absolute `WA_SCRIPT`, Lua root pointing to this source tree, and
`WA_WAVE_COMMAND` JSON containing native `program`, string-array `args`, actual
external `cwd`, timeout and owner budget. The runner sets `WA_WAVE_ID`,
`WA_WAVE_OPERATION_ID`, `WA_WAVE_STATE_DIR`; the driver starts one actual operation,
awaits full settlement and returns its native ID plus correlated wave operation ID.
A valid effect receipt requires `ok:true`, `settled:true`, exact correlated
`operation_id`, and a known cleanup outcome. Merely emitting a release count,
starting detached work, queueing a sentinel request or exiting zero is refused.
Deploy's actual post must observe installed outcome/verification, not queue success.

SQLite persists progress, attempts, next observation time and every transition.
The OS-held per-boot lease distinguishes an active owner from a crashed runner;
PID reuse and timers do not reclaim it. A crashed `running` effect becomes
`unknown` with its original operation ID and an actionable `blocked` reason.
Fresh lease takeover can continue interrupted observation checks, but never
replays an interrupted effect. A settled stage immediately continues the next
stage without a model call or human ping. Observation checks retry at most three
times by default (cap five), with persisted exponential backoff capped at 30 s.
Exhaustion is a durable blocked state, not a retry/poll loop. `inspect` detects
dead/missing owner authority without mutating the row. Restart an external
finisher with the same `advance` command; no resident daemon is introduced.

Unknown-effect reconciliation names the exact `operation_id` and
`expected_manifest_hash`, with nonempty inspected `evidence`, `drain_evidence`,
`effect_evidence`. `outcome:"settled"` additionally supplies a complete correlated
settlement receipt and advances to observation; `outcome:"no_effect"` authorizes
a replacement only after no-effect proof, bounded to three command attempts.
All prior attempts remain in the append-only event journal. `resume` only restarts
bounded observations after an explicitly observed repair; any unknown effect
still requires reconciliation. It does not launch another effect command.

First recovery of an already dirty historical repository may set `bootstrap:true`.
That authorizes creating the recovery wave; it does not waive any final proof.
Every subsequent `create` re-verifies the previous completed wave's real baseline
before admission, including fresh remote refs and install/registry/owner checks.

## Exact retirement

`wave-retire.mjs apply <plan.json> <private-state-dir> [<resolutions.json>]` performs
only explicitly settled, handed-over inputs. Its plan pins `wave_id`, external
`owner`, canonical `repo`, accepted `main`, canonical `managed_roots`, local/remote
`[{ref,tip}]`, and worktree rows. Each worktree pins native `path`, `tip`, branch,
`mode:"park"|"remove"`, `owner_id`, fresh `owner_argv`/`safety_argv`, and separate
`reconcile_argv`/`registry_post_argv`. Global `owners_argv` and `dependencies_argv`
must report complete empty unresolved sets. Owner proof must report accepted
settlement, exact owner/tree/tip and inspected evidence. Safety proof inventories
relevant operations/claims; registry post proves actual Git/runtime/Orca agreement.
Adapters are trusted reviewed procedures, not model-written booleans.

The external finisher refuses its current cwd, canonical main, paths outside
approved roots, symlink/junction ambiguity, checked-out local refs, dirty/untracked
or ignored evidence, unmerged tips and changing identities. It preserves canonical
ignored build caches. Local ref deletion is exact old-OID CAS after no tree owns
the branch. Normal remote deletion preserves prior pre-push checks and validates
the SHA in that same push advertisement, then receive-pack's old-OID CAS rejects
a later move. There are no force flags. PR/dependency uncertainty refuses cleanup.

`retirement.sqlite` records every individual Git and registry action before effect.
A partially completed retirement never prints successful wave completion. A
crash after effect but before receipt leaves `running`; explicit resolutions name
that exact action identity/plan hash and drain/effect evidence, and observed
postconditions must pass before the row is reconciled `done`. Originals remain in
history. Automatic replay is refused. A settled rerun rechecks postconditions.

## Completion proofs

Final verification freshly checks only `main` in remote/shared local heads,
canonical main clean and equal to origin/main, clean integrated detached retained
trees (or removed/released ones), and no locked/prunable/unresolved Git trees.
Remote/local refs are read again around workspace/proof checks to detect movement.
The shared `full-gate-proof.mjs` validator requires the actual accepted Git tree,
successful exit, valid log hash, one gate run and terminal counted skip verdict.
Focused admission cannot substitute for that receipt. `gate_receipt` can name an
identical-tree retained receipt; otherwise canonical `wa-finish-gate.json` is used.

Every verifier returns `{ok:true,main:<accepted-sha>,wave_id:<id>,...}`. Operations,
claims, deliveries and owners additionally return `complete:true,unresolved:[]`.
An opaque `ok` count is not proof. Missing/incomplete inventories, stale source
attribution and failed/skipped installation checks block completion. The default
`wave-proof.mjs <kind> <config.json>` supplies concrete observation adapters:

| Config | Purpose |
| --- | --- |
| `repo`, `data`, `install` | canonical source and actual runtime roots. `data` is the node runtime root the activity/ownership inventory reads; there is no third-party registry id to configure |
| optional `activity` | an explicit activity source for a fixture or a non-default runtime (`{data, process_probe}`); production resolves it from the verifier config |
| optional `orca_view` | `true` makes an existing Orca binary an optional viewer. Advisory evidence only; never a decision input, never required |
| `delivery_store` | existing durable delivery records, independent review and landed ancestry |
| `verify_install_argv` | sanctioned verifier `--json`, zero failures/skips required |
| `functional_receipt` | accepted-main two-window recovery evidence with `scope:"two-window-recovery"`, `checks`, `log`, `log_sha256`, `ok` |
| optional `health_url` | fresh health, default local 8799 |

The adapters read index/claims/ledger SQLite read-only, refuse stale allocated
bindings, compare the real Git worktree list against the session bindings and
detached parked evidence, verify installed clean-built source and binary hash,
require the sanctioned installation and functional recovery evidence, and fetch
health. Their config must inventory all managed owners; absence from a partial
roster is not settlement. A fresh `WA_WAVE_TARGET` bounds operation/claim safety
checks during one retirement; final checks without a target inventory the whole
managed runtime. Original diagnostics and transcripts are not rewritten by any
verifier. The `registries` verifier folds leftovers in as well: a wave cannot be
complete while this repository still holds an unreconciled managed workspace.

## Evidence and limits

`wave-audit.mjs <repo> <data> <new-report>` creates a non-overwriting read-only audit
of Git refs/trees/dirt, operation/original hashes, claims, bindings, health and - only when
`WA_WAVE_ORCA_VIEW=1` asks for it - an advisory Orca view that is never a decision input.
The 2026-10-01 recovery audit observed 72 Git trees, 35 clean integrated candidates
still needing positive owner settlement, 36 dirty/ignored trees, four unmerged
tips, 100,888 operation records, two live operations, 76 uncertain manually edited
originals, 50 claims (46 uncertain), and 1,380 bindings (1,374 allocated). Counts
are a point-in-time observation during live work, not a completed closure receipt.
No tree/ref/claim/operation was retired or rewritten by that audit.

Focused repair proof: 40 real `wa-operation` tests (one helper is marked ignored
and is launched explicitly by its parent identity/drain test); Lua-root workspace
integration has 37 release/reconciliation checks plus 11 two-process/restart checks;
`test-wave-executor.cjs` verifies 11 real native-child driver checks in a private
home with the source Lua root;
`test-wave-lifecycle.mjs` uses private Git/SQLite and stand-in effect/proof drivers
for crash/restart, no replay, dirty/unmerged work, zero-release failure, uncertain
claims/deploy, stale next-wave baseline and ref movement;
`test-wave-retire.mjs` uses real disposable Git for non-force advertisement/server
CAS, preserved prior hooks, active-owner refusal, parking and durable partial
retirement. Stand-in observation receipts are not production deployment proof.
`test-wave-proof.mjs` uses real immutable review/landing Git objects and actual
full-gate receipt schemas. `test-wave-restart.mjs` exercises bounded public
continuation in external processes. `test-wave-public.mjs` ships the actual entry,
registers a private local-transport repository, reconciles an exactly drained
native claim, removes a native session workspace, parks a second managed session
workspace through the node's own runtime reconciliation, and proves main-only
local/remote refs - with no third party anywhere in the fixture. It then requires
durable blocking because full application gate/deployment evidence is absent; this
is contract closure proof, not a production completed-wave receipt.
`test-wave-derived-state.mjs` proves the derived rule on real private Git and a real
node store: zero live children cannot block the next wave, a live child reports ON, a
`running` row with nothing running is never reported active, an unverifiable
convergence stays a named state, and the legacy row's migration is exact and
reversible. `test-wave-no-orca.mjs` runs the ownership and registry proofs with no
`orca` reachable on `PATH` and again with a broken one, requires the same verdicts,
and requires the same proofs to still refuse an unowned tree - so the assertions
cannot be silently skipped when it is absent.

Risk: explicitly configured local proof adapters and external operator evidence
remain trusted. These are cooperative evolution safeguards, not an OS security
sandbox against arbitrary shell or manual DB edits. Legacy unprovable effects may
require an actual owner decision and remain blocked. No speedup is asserted from
the synthetic history fixture; it proves bounded relevant lookup and no repeated
historical state-file reads, not features shipped per hour.
