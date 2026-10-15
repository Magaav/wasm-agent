# Code-mode benchmark wiring (model-free)

This is implementation/transport qualification, **not the requested autonomous comparison**.
No completion-time, dollars/cache rankings or 0–100 final-quality scores exist here.
The paid entry in `scripts/agent-benchmark.mjs` remains refused. Current direct mode
also forbids native/external inference-agent launches until explicitly enabled.

## Same native policy, different guest hosts

`benchmarks/codemode/reference-server.mjs` hosts the checksum-pinned upstream Pi1.2
VM driver and QuickJS-WASI3.6.2 guest. It returns queued tool calls only; it cannot
execute tools. A private `reference-client.lua` injects its control protocol into
the same `core/codemode.lua` used by V2. Role/profile/workspace/definition/typed JSON
checks, original-result retention and effect admission remain native and shared.
No production flag selects this backend; the production path stays Node-free.
The comparison entry changes the model-facing V1 description to say Node-hosted.
Returned backend metadata comes from the actual host rather than claiming Rust.

Controller nonce, scoped owner/IDs, input/output bounds, pending result identity,
expiry and disposal are explicit. A failed transport has unknown state and is never
replayed. Unawaited effects are not admitted. Helpers are disposed at native process
exit; active scripts are not resumed after restart. Empty JSON objects and successful
undefined return values are normalized deliberately to the native facade contract.

V1 has Node/HTTP control overhead; V2 calls its in-process Wasmtime capability.
Startup/IPC must be measured separately rather than attributed to model reasoning.
Both use the same guest/prelude/heap/stack and serial native tool broker. Wasmtime
fuel and linear-memory bounds have no identical upstream Node SDK mechanism:
V1 explicitly skips the fuel-specific control (one per source/embedded seed), not
pretending it passed. All other common cases execute with real native tools.

## Shared Responses route

`agent-benchmark-model-route.mjs` now supports a candidate **vault-subscription**
transport as well as the original loopback model-free factory. A controller calls
`createVaultSubscriptionRoute({vaultUrl, root, arms})` with an exact fixed vault
origin and fresh private evidence root. It selects only `/openai-sub/codex/responses`;
model/reasoning/stream must be exactly `gpt-6.1-sol`/`low`/`true`. No credential is
accepted in this mode. The existing `vault/wa_vault.py` attaches the subscription
bearer/account to its fixed provider endpoint. No caller Host, credential, cookie,
forwarding or identity headers pass through the relay. Common fixed subscription
headers use the native measured codex-cli contract; session/cache scopes are opaque
and arm-specific. Neither hop follows redirects. The relay exposes no vault login,
usage, admin, URL override or provider continuation surface. `/status` describes
transport configuration only, NOT credential presence or model entitlement.

Original client wire bytes, decoded bytes (including Pi1.2 zstd), the exact prepared
body and all observed response bytes are retained with lengths/hashes. An admitted
upload is reserved before awaiting data, and its arm clock starts at first upload
or explicit idempotent `activate(handle)`, not when all arm scopes are created.
Absolute upload/stream timers cannot be extended by heartbeats. Failed/abandoned
uploads and partial/error responses remain evidence. Each admitted attempt has one
end; durable dispatch intent precedes the effect, including connection failures.
Unknown usage halts the arm; there is no retry/replay. `readModelRouteJournal(root)`
independently verifies completed capture hashes and leaves missing ends/crashes
unsettled. This journals every observed HTTP request, including retries/summaries;
it does not establish coverage of inference routed outside this controlled seam.

Reported-token/request/time controls apply only to declared experiment arms, never
production worker loops. Each arm requires maxRequests/maxPromptTotal/maxOutputTotal/
maxMilliseconds and may specify a shorter maxRequestMilliseconds. Requests count
provider dispatch intents, not rejected validation uploads. Token ceilings are
observed AFTER a response: at most one response can overshoot, and its measured
prompt/output overshoot is explicit. No hard token, quota or dollar cap is claimed;
a paid manifest must budget the overshoot separately. Cached input and reasoning
remain subsets, not added twice; cache-write/missing fields and subscription dollars
stay unknown. Provider KV contents are opaque.

Model-free tests exercise the **actual vault implementation**, with a fake upstream
and synthetic credentials only, including failures, slow/abandoned uploads,
heartbeats, serial clocks, malformed usage, no redirects/replay and journal integrity.
An additional actual two-container proof uses a pinned cached image, internal owned
network, private PID/mount namespaces, read-only roots and no shared credential
store/admin/Docker socket. Only the trusted container contains vault/relay/fake
provider; vault itself binds loopback. The client cannot reach that private vault
port or store/processes. Exact captured bytes are collected after drain, sealed and
verified before generation-owned removal; the shared image is preserved. This is
proof of that synthetic topology, NOT qualification of a later solver image/network
or a comprehensive container-security theorem. Same-user fixtures alone are NOT OS
credential isolation; Windows file modes alone do not create an ACL sandbox.

The terminal SSE frame is the completion boundary, not socket EOF. UTF8 and raw
partial bytes are retained; the relay does not wait indefinitely on an already
completed provider. A refusal is visible and retained, not silently substituted.

## Actual framework-loop proof

```
node scripts/test-codemode-reference-native.mjs <native-binary> <prepared-assets> <fresh-evidence>
node scripts/test-agent-benchmark-model-route.mjs <fresh-evidence>
node scripts/test-agent-benchmark-runtime-route.mjs <native-binary> <prepared-assets> <fresh-evidence> <pi-coding-agent-package>
node scripts/test-agent-benchmark-pi-route.mjs <pi-ai-package> <fresh-evidence>
node scripts/test-agent-benchmark-vault-route.mjs <fresh-evidence>
node scripts/agent-benchmark.mjs --route-journal <retained-route-evidence>
node scripts/test-agent-benchmark-runtime-route.mjs <native-binary> <prepared-assets> <fresh-evidence> <pi-coding-agent-package> --vault-fixture
node scripts/test-agent-benchmark-vault-container.mjs <fresh-evidence> <exact-cached-image-sha256>
```

The four-framework fixture uses real Pi1.2 coding-agent and native current-style,
Node V1 and Rust V2 agent/tool loops. Each consumes two deterministic mocked model
responses, executes a real private read, then replays its tool output on the second
request to the same model route. These are not autonomous solvers or task acceptance.
Current-style mode in this fixture uses the candidate runtime with code mode off;
it does not qualify the separately pinned historical baseline binary/image.
The standalone Pi serializer proof additionally observes its zstd wire encoding.
Public npm versions/integrities are `benchmarks/codemode/pi-package-pins.json`;
retain the exact transitive lockfile, not only the direct package versions.

A real integration catch: `WASM_AGENT_LLM_MODEL` pins only the legacy opencode-go
route. Subscription otherwise selected its default Luna model. The strict relay
refused that mismatch before forwarding. The private benchmark entry now selects
provider/model/reasoning through supported state APIs and checks the selected model;
no production configuration is changed. No silent model fallback is accepted.

## Still required before paid results

Exact per-arm runtime/source/binary/image/tool/instruction pins; qualification of the
actual solver topology using this vault transport, real provider entitlement and
operator-owned credential configuration (none mutated here); predeclared quota/spend
controls with overshoot allowance; native owner admission and paid-run lifecycle
wiring; serial timed arms, blind fixture export/isolated grading, actual behavioral
acceptance and subjective quality notes. Capture/route and owned cleanup APIs are
implemented and model-free tested, not a completed autonomous comparison. The paid
CLI remains refused; do not remove that boundary merely because these tests pass.
