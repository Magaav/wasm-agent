# Durable evolution wave closure

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
The combined full-gate receipt must match the actual accepted Git tree, successful
exit, valid log hash, unchanged runner hash, one gate run and counted skip verdict.
Focused admission cannot substitute for that receipt. `gate_receipt` can name an
identical-tree retained receipt; otherwise canonical `wa-finish-gate.json` is used.

Every verifier returns `{ok:true,main:<accepted-sha>,wave_id:<id>,...}`. Operations,
claims, deliveries and owners additionally return `complete:true,unresolved:[]`.
An opaque `ok` count is not proof. Missing/incomplete inventories, stale source
attribution and failed/skipped installation checks block completion. The default
`wave-proof.mjs <kind> <config.json>` supplies concrete observation adapters:

| Config | Purpose |
| --- | --- |
| `repo`, `data`, `install`, `orca_repo_id` | canonical source and actual runtime/registry roots |
| `orchestration_run_ids`, optional `orca` | complete explicitly inventoried worker ownership |
| `delivery_store` | existing durable delivery records, independent review and landed ancestry |
| `verify_install_argv` | sanctioned verifier `--json`, zero failures/skips required |
| `functional_receipt` | accepted-main two-window recovery evidence with `scope:"two-window-recovery"`, `checks`, `log`, `log_sha256`, `ok` |
| optional `health_url` | fresh health, default local 8799 |

The adapters read index/claims/ledger SQLite read-only, refuse stale allocated
bindings, compare actual Orca/Git branches and detached parked evidence, verify
installed clean-built source and binary hash, require the sanctioned installation
and functional recovery evidence, and fetch health. Their config must inventory
all managed owners; absence from a partial roster is not settlement. A fresh
`WA_WAVE_TARGET` bounds operation/claim safety checks during one retirement;
final checks without a target inventory the whole managed runtime. Original
diagnostics and transcripts are not rewritten by any verifier.

## Evidence and limits

`wave-audit.mjs <repo> <data> <new-report>` creates a non-overwriting read-only audit
of Git refs/trees/dirt, operation/original hashes, claims, bindings, Orca and health.
The 2026-10-01 recovery audit observed 72 Git trees, 35 clean integrated candidates
still needing positive owner settlement, 36 dirty/ignored trees, four unmerged
tips, 100,888 operation records, two live operations, 76 uncertain manually edited
originals, 50 claims (46 uncertain), and 1,380 bindings (1,374 allocated). Counts
are a point-in-time observation during live work, not a completed closure receipt.
No tree/ref/claim/operation was retired or rewritten by that audit.

Focused proof: 39 real `wa-operation` tests; the Lua-root workspace integration
has 34 release/reconciliation checks plus two-process/restart evidence;
`test-wave-executor.cjs` verifies 11 real native-child driver checks in a private
home with the source Lua root;
`test-wave-lifecycle.mjs` uses private Git/SQLite and stand-in effect/proof drivers
for crash/restart, no replay, dirty/unmerged work, zero-release failure, uncertain
claims/deploy, stale next-wave baseline and ref movement;
`test-wave-retire.mjs` uses real disposable Git for non-force advertisement/server
CAS, preserved prior hooks, active-owner refusal, parking and durable partial
retirement. Stand-in observation receipts are not production deployment proof.

Risk: explicitly configured local proof adapters and external operator evidence
remain trusted. These are cooperative evolution safeguards, not an OS security
sandbox against arbitrary shell or manual DB edits. Legacy unprovable effects may
require an actual owner decision and remain blocked. No speedup is asserted from
the synthetic history fixture; it proves bounded relevant lookup and no repeated
historical state-file reads, not features shipped per hour.
