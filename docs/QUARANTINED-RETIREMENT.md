# Operator-authorized quarantined retirement

This is **risk acceptance, not proof of execution drain or external-effect settlement**.
Original execution outcomes stay unknown; no action is replayed and every original
state/output/before-reconcile file, claim/binding and recoverable Git draft is retained.
The operator authorized this alternative on 2026-10-06 for the exact historical
77 operation records, 3 uncertain execution reservations and 46 managed workspaces.
Normal reconcile/adjudication rules are unchanged. No default retention/sweep/job.

## Trusted boundary and named risk

`<data>/quarantined-retirement.json` is explicit trusted local operator policy.
It pins the actual human authorization evidence bytes/hash, data root, item kind/ID,
complete expected state and per-item private archive manifest/hash. It explicitly
states `risk_accepted:true`, `original_outcome:unknown`, `never_replay:true`,
`drain_proven:false`, `effect_settlement_proven:false`. Privileged local filesystem
writers remain outside the guarantee; this is cooperative admission, not an OS sandbox.

**Risk:** original commands/containment/remote outcomes may be unreconstructable.
Releasing their obsolete reservations improves availability but does not undo or
certify old external effects. Absent PIDs are only a conservative current-live-owner
refusal check in this risk path, never retroactive positive drain proof.

## Safeguards and application

`scripts/prepare-quarantined-retirement.mjs DATA REPO SEED APPROVAL ARCHIVE` only
creates exact private archives/policy/execution plan; it releases nothing. Existing
policy/archive generations refuse, so inspect a partial preparation before retry.
It copies every operation directory byte, exact claim/identity/history and original
session binding, creates/validates per-workspace source Git bundles, and refuses
new/changed counts, active session turns, foreign Git registry, dirty/ignored files,
changed tips or unmerged source. Prior draft backups remain preserved separately.

An approved sentinel `request run` wrapper executes installed `wa` with private
external cwd, `WA_QUARANTINE_EXECUTOR=1`, exact `WA_QUARANTINE_PLAN`, explicit Lua
root and `WA_SCRIPT=scripts/quarantined-retirement.lua`. Node turns and inherited
in-turn markers refuse mutation. No model tool or HTTP action exposes this escape.

- Native `host.operation('quarantine_retire', ...)` binds exact raw state, live
  directory inventory/hashes and archive to policy. A present original PID generation or held/missing current-format owner lease
  refuses. A positive newer Windows creation timestamp can distinguish recycled
  PIDs from original admission; this is identity exclusion, not drain proof.
  When a protected service denies `OpenProcess`, a bounded native system-process
  snapshot supplies positive creation-time evidence. Invalid/truncated/error
  snapshots still refuse; access denied alone never means the owner is absent. An additive `risk_quarantine` row and
  audited history retire only allocation-blocking reservation; state/output remain
  untouched. `relevant` revalidates policy, archives, originals and live-owner refusal:
  missing/moved evidence restores the blocker. Normal known settlement remains separate.
- Native `host.resource('quarantine_retire', ...)` binds exact key/principal/run/boot,
  existing free OS lease, archive and policy. A live/current owner refuses. Original
  claim evidence moves into append-only quarantine history, not a fabricated settled
  task. Only that exact reservation is removed; identities/lease files remain.
  Reusing a retired claim key revalidates its retained archive; corrupt/missing
  preservation refuses a new claim. Quarantined parked trees cannot be deleted
  by ordinary workspace release/reconciliation.
- Lua `workspaces.quarantine_park` claims the session fence, validates exact original
  binding/archive, canonical managed path, actual Git common directory/tip/branch,
  clean/ignored status, ancestry and native relevant-operation proof. Authorized
  historical source/branch mismatches are captured, never silently relabelled.
  Original binding is retained in `start_state.quarantined_retirement`; tree is
  parked at its exact detached tip, refs/bundles/transcript retained, not deleted.
  Unobserved detach records `park_unknown` and refuses automatic replay.

Effects are sequential and separately durable: partial success is not overall
completion. Inspect exact records and actual postconditions before continuing after
interruption. Do not automatically rerun the whole execution plan after an unknown
outcome. A known duplicate operation disposition can collect its original receipt;
released claims/park transitions need inspection, not blind effect retry.

Proof: native archive/authorization mutations, operation unit tests and
`scripts/test-quarantined-retirement.cjs` (private native claims, real Git parking,
archive corruption restoring operation blockers, unknown outcome preservation,
live owner refusal). `WASM_AGENT_LUA_ROOT` must point at the candidate source.
No production cleanup is inferred from private fixtures; actual receipts and fresh
inventories are required. Full release gating remains the operator's separate choice.
