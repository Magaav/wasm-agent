# Observed provider serving eligibility

Node responsiveness and provider serving are separate facts. `provider.lua` contains
an embedded availability component backed by SQLite `provider_serving`. Only the real
HTTP inference result seam records OpenCode Go HTTP 429 structured
`error.type=GoUsageLimitError`, `error.metadata.limitName=monthly` as
`blocked/provider_monthly_quota`. Exception strings, assistant/tool prose, other
429s, transport failures and catalogue/limit reads are not quota evidence.

Monthly state is account-route wide, not model-specific. Binding hashes node state
identity, configured provider, base URL and non-secret
`WASM_AGENT_PROVIDER_ACCOUNT_PROFILE` (default `default`); credentials are neither
stored nor used as identity. Key rotation and calendar passage cannot clear state.
Operators sharing one route between accounts should configure stable profile labels;
unlabelled accounts conservatively share the default binding. Do not rename a label
to evade a block. No account discovery or credential change is performed.

Placement reads existing signed peer `status` (including managed peers) before a
new launch, and local availability directly. A known block skips that destination.
Existing operator bounds/disables stay unchanged; no provider/model substitution or
paid recovery probes occur. Queued rows retain keys and become
`waiting_provider_serving:provider_monthly_quota` or `waiting_approved_capacity`.
Uncertain deliveries retain the original reconciliation contract, never replayed
on this evidence. Existing absent-state/old-peer behavior remains compatible and
**unknown**, not a guarantee of quota availability. Native admission remains the
capacity authority; approved profile/model validation is unchanged.

A completed authenticated inference records observed serving on its bound route.
An already in-flight successful call can therefore clear a concurrently observed
block; blocked routes are not automatically probed. Internal
`recover_serving(binding,evidence,true)` requires the exact binding and independently
verified operator evidence; it is not exposed as a model tool. Recovery returns
unknown, not proof of serving. No prompts or memory receive availability metadata.

Run `node scripts/test-provider-serving.cjs <fresh-own-wa-binary>` after building
`cargo build --offline --manifest-path rust/Cargo.toml -p wa-host`.
Four private processes exercise source Lua and compiled embedded Lua, durable restart,
HTTP outcome recording, zero-call block refusal, account/key binding, unsupported
outcomes, operator recovery, authenticated success, bounded local placement,
named waiting without duplicate launches and cloud0. Host HTTP envelopes and peer
boundaries are deterministic mocks; no real provider or paid model is contacted.
