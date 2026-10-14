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

`agent-benchmark-model-route.mjs` is currently a loopback-only, model-free factory.
It implements the existing vault-compatible presence/Responses shape, with opaque
per-arm route/cache scopes and fixed model/reasoning/stream pins. It forwards only
to an explicit fixed mock upstream. It captures original client wire bytes, exact
decoded JSON (including Pi1.2 zstd requests), the actual scope-bound upstream body,
and complete observed response bytes with hashes and start/end/refusal journals.
No real credentials enter solvers; the fixtures use unmistakably synthetic values.

Reported-token/request/time controls apply only to the declared experiment fixture,
never production worker loops. Token ceilings are observed after a response, so a
future paid manifest must declare the one-request overshoot bound; this is not an
unproven hard-dollar cap. Unknown/truncated/failed usage halts that arm before any
new upstream request. Cached input and reasoning remain subsets, not added twice;
missing fields/costs stay unknown. Provider KV contents are opaque.

The terminal SSE frame is the completion boundary, not socket EOF. UTF8 and raw
partial bytes are retained; the relay does not wait indefinitely on an already
completed provider. A refusal is visible and retained, not silently substituted.

## Actual framework-loop proof

```
node scripts/test-codemode-reference-native.mjs <native-binary> <prepared-assets> <fresh-evidence>
node scripts/test-agent-benchmark-model-route.mjs <fresh-evidence>
node scripts/test-agent-benchmark-runtime-route.mjs <native-binary> <prepared-assets> <fresh-evidence> <pi-coding-agent-package>
node scripts/test-agent-benchmark-pi-route.mjs <pi-ai-package> <fresh-evidence>
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

Exact per-arm runtime/source/binary/image/tool/instruction pins; credential-isolated
real common route and model entitlement; complete real provider attempts/usage;
blind task export and isolated grading; explicit experimental controls and native
owner admission; serial timed arms; actual behavioral grading and subjective quality
notes; lossless sealing before ownership/drain-aware cleanup. Do not remove the
paid-readiness refusal merely because these model-free fixtures pass.
