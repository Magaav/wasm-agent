# Observed provider serving eligibility

Node responsiveness and provider serving are separate facts. `provider.lua` contains
an embedded availability component backed by SQLite `provider_serving`. Only the real
HTTP inference result seam records OpenCode Go HTTP 429 structured
`error.type=GoUsageLimitError`, `error.metadata.limitName=monthly` as
`blocked/provider_monthly_quota`. Exception strings, assistant/tool prose, other
429s, transport failures and catalogue/limit reads are not quota evidence.

Monthly state is account-route wide, not model-specific. Binding hashes node state
identity, configured provider and non-secret
`WASM_AGENT_PROVIDER_ACCOUNT_PROFILE` (default `default`); credentials are neither
stored nor used as identity. Key rotation and calendar passage cannot clear state.
Operators sharing one route between accounts should configure stable profile labels;
unlabelled accounts conservatively share the default binding. Do not rename a label
to evade a block. No account discovery or credential change is performed.

Endpoint spelling or replacement cannot clear account exhaustion. A success is
bound to the endpoint actually requested as well as the account; an endpoint
change while inference is in flight cannot certify the old route.

Placement reads signed peer `status` (including managed peers) in two phases before
a new launch, and local availability directly. An identity-only read establishes
the active route account/profile/binding/generation for the independently selected
destination node and requested model/provider override. A separate status request
carries that exact tuple; the destination checks its current route and generation,
and placement compares every returned field. Foreign metadata, identity drift,
unsupported provider overrides and bare `model_error` stay unknown. Neither phase
performs inference or catalogue/usage HTTP. A correctly bound block skips that destination.
Existing operator bounds/disables stay unchanged; no provider/model substitution or
paid recovery probes occur. Queued rows retain keys and become
`waiting_provider_serving:provider_monthly_quota` or `waiting_approved_capacity`.
Uncertain deliveries retain the original reconciliation contract, never replayed
on this evidence. Existing absent-state/old-peer behavior remains compatible and
**unknown**, not a guarantee of quota availability. Native admission remains the
capacity authority; approved profile/model validation is unchanged.

A completed authenticated inference with an explicit matching response model and
completion marker records observed serving on its captured request route. A SQLite
generation and snapshot compare-and-swap prevents older successes from clearing a
newer block or verified recovery, even across processes. Responses lacking model
identity (including the current host stream aggregator and subscription adapter)
cannot certify serving; ordinary inference behavior remains compatible. Blocked
routes are not automatically probed. Internal
`recover_serving(binding,evidence,true)` requires the exact binding and independently
verified operator evidence; it is not exposed as a model tool. Recovery returns
unknown, not proof of serving, and advances generation rather than deleting the
row. Persisted state/reason/model/generation are validated: corruption is a visible
`provider_eligibility_corrupt` refusal with zero provider calls, requiring explicit
verified recovery. Absent legacy state remains distinct unknown. The additive
generation migration preserves valid predecessor monthly blocks.
No prompts or memory receive availability metadata.

Run `node scripts/test-provider-serving.cjs <fresh-own-wa-binary>` after building
`cargo build --offline --manifest-path rust/Cargo.toml -p wa-host`.
Four private processes exercise source Lua and compiled embedded Lua, durable restart,
HTTP outcome recording, zero-call block refusal, account/key binding, unsupported
outcomes, operator recovery, authenticated success, bounded local placement,
named waiting without duplicate launches and cloud0. Host HTTP envelopes and peer
boundaries are deterministic mocks; no real provider or paid model is contacted.

Additional focused suites (each accepts the fresh binary and optional evidence directory):

- `scripts/test-serving-contract.cjs`: source/embedded hostile tuples, model identity,
  CAS races, corrupt rows and corrupt restart, old-peer compatibility.
- `scripts/test-serving-http.cjs`: actual loopback host HTTP with authenticated mock
  requests, source/embedded restarts and real signed two-node status.
- `scripts/test-serving-guards.cjs`: twelve causal runtime guard removals must fail
  their corresponding assertions in source and embedded mode.
- `scripts/test-provider-binding-negative.cjs`: original raw-endpoint binding
  regression must fail in both modes.
- `scripts/test-orchestrator-queue-race.cjs`: delayed real admission reproduces the
  old timer sample of `placing`, then proves the capacity-refusal observation with
  all twenty compatibility checks. The retained independent F5 database had its
  third task durably queued with `node_full`; reservation is a transient state.

Risks: account identity remains the operator-declared non-secret profile, not account
discovery. Mislabelled accounts on the same configured route conservatively share a
block. Strict recovery evidence can leave compatible but unidentified successful
responses unknown; no automatic probe or paid recovery is introduced. These are
focused fixtures, not a full release gate or a claim about live provider recovery.
