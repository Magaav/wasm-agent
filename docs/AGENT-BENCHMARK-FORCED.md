# Explicit forced-code-mode parallel pilot

This narrowly guarded experiment extends the existing pilot runner. It does not
change production tools, defaults, global output limits, task/oracle bytes or
instruction files. The original serial four-arm and Pi-only entries retain their
separate scopes. Old/consumed/copied manifests do not authorize a new wave.
The historical implementation checkpoint is retained in
[AGENT-BENCHMARK-FORCED-CHECKPOINT.md](AGENT-BENCHMARK-FORCED-CHECKPOINT.md).
Current evidence, counts and the private prepared-manifest reference are in
[AGENT-BENCHMARK-FORCED-VERIFICATION.md](AGENT-BENCHMARK-FORCED-VERIFICATION.md).

## Treatments and model-facing condition

| Arm key | Explicit adapted treatment | Actual VM host |
| --- | --- | --- |
| pi | Pi 1.2 + benchmark Node QuickJS-WASI adapter | pinned upstream Node VM |
| wasm-current | historical b384 wasm + benchmark Node QuickJS-WASI adapter | pinned upstream Node VM |
| node-v1 | candidate wasm + Node V1 | pinned upstream Node VM |
| rust-v2 | candidate wasm + native Rust/Wasmtime V2 | native Wasmtime |

These are **not unmodified Pi/historical controls**. Historical b384 retains its
original runtime/native dispatcher; the disclosed benchmark adapter loads the
shared checksum/source-pinned VM policy, not a silently modernized runtime.
All arms present the same neutral `codemode` declaration and common routing
appendix. Original task instruction files stay byte-identical. Native outer
admission rejects direct/routed tools even if the model emits an undeclared name;
Pi registers/activates only the custom VM tool and journals undeclared attempts.
Only trusted VM callbacks enter nested native authorization. Original role,
profile, workspace, schema, typed JSON, receipt, output and effect checks remain.
No one-token VM ritual permits later direct tools or ambient filesystem fallback.

All use the pinned guest/prelude and blind broker. The three Node VM hosts run
inside their own existing natively supervised actor trees, not the shared route
controller's event loop. A CPU-bound Node guest cannot block peer route clocks.
V2 has no reference endpoint, Node bridge or fallback. Its runtime PATH excludes
Node and includes a copy of the already-provisioned rg, avoiding downloads.
Node benchmark coordination and Pi are separate from V2 VM execution.

## Private changeset storage (benchmark adapter only)

The static module loader shares a single changeset module and wraps only its
trusted `store/load` functions in the existing controller-I/O scope. Generated
content addresses must be 64 lowercase hex digits and map to the exact private
home's `.wasm-agent/changes/<prefix>/<digest>` path. Data-root/path identity,
canonical ancestors, existing and dangling links, bytes/digest and write/readback
are checked. Storage failures propagate; changesets are neither disabled nor
silently marked successful. Scope restoration applies on exceptions.
Model-selected read/write paths still go exclusively to Docker, including attempts
to access these private paths, other homes and traversal addresses. No generic
host-prefix exception is exposed to a model. Production `lua/core/changeset.lua`
is unchanged; reversible before/after blobs/records remain authoritative.
Same-user filesystem coordination is not an OS-wide race-proof transaction.

## Parallel lifecycle and evidence

One fresh wave reserves four separate homes, SDK/native sessions, workspaces,
volumes, keys and evidence roots. Stage all boxes before the start barrier; record
release, actual controller-loop start/end, actor settlement, writer drain and
capture timestamps. Wait for **all** actor/process-tree settlements, close task
RPC listeners, drain all writers, then capture. Grade only after all lifecycles
finish. Ownership updates remain synchronous/single-writer. Never fail-fast and
abandon actors, replay uncertain effects or seal a live/uncertain generation.
Unknown usage halts its arm; unknown tool outcome sets a shared trusted admission
fence and halts the wave. Known broker refusals (for example a missing read with
`effect:none`) remain known no-effect results, not invented unknown outcomes.
Counters distinguish nested attempts from successful task operations.
Already-admitted effects are not rolled back/replayed.
Failed/unknown live waves retain their failure/generation for exact-owned recovery;
absence of a successful seal/cleanup receipt is never called finished clean.

Trusted journals bind arm/session, invocation/source hashes, actual host VM IDs,
owner scopes, guest/prelude hashes, nested arguments/results and protocol delivery.
Printed backend labels from JS/model text are not evidence. Verification rejects
bypass, wrong host/owner/call/result, zero/meaningless use, missing/incomplete trace
or unbound receipts. Outer VM executions and nested reads/writes/edits/bash are
separate counters. Handoff, acceptance, usage, VM-use and valid-treatment verdicts
are distinct; invalid treatments must not rank as VM winners.

Qualification uses real concurrent framework/VM/controller loops, Docker tools and
the actual synthetic vault, with no live provider calls. Unique per-arm file
markers and persistent guest-store sentinels test state/result isolation. All
prepared requests must expose only the common neutral code-mode schema. The
negative wave deliberately emits undeclared write/bash/discovery/routed calls;
it must have no effects and cannot qualify as used. Sealed archives are lossless,
verified before exact-owned cleanup. Pi's exclusive checked/fsynced raw journal
remains complete beyond 8MiB, including later results/final; console is bounded.
Pi's new VM-tool presentation reuses the SDK's existing 50KiB truncation utility,
retains the full selected result with checked exclusive write/fsync/close in that
runtime's private temp directory, and supplies a bytes/SHA reference. Full raw VM
and SDK journals remain private and lossless. It does not repair the SDK's existing
oversized-single-line/private-artifact viewing limitations. Qualification checks
actual prepared tool-result sizes after a multibyte over-limit VM output.

The cached common tool image retains its pre-task verification host (critical Lua
matched to `1ab3024e`); its full binary build source remains unknown. It is not the
candidate runtime and never mounts repaired runtime or credential files.

## Coordinator CLI

Use absolute paths and fresh directories. `artifact-config` uses the existing
baseline/candidate binaries, Pi package, assets and exact cached image. Preparation
also requires their build receipts plus current runtime/grader qualification.
The installed skill may be stale: use this selected repository's files.

```
node scripts/agent-benchmark.mjs --pilot-forced-qualify <artifact-config.json> <fresh-runtime-proof>
node scripts/agent-benchmark.mjs --pilot-forced-negative <artifact-config.json> <fresh-negative-proof>
node scripts/check-agent-benchmark-forced-proof.mjs <artifact-config.json> <runtime-proof>
node scripts/check-agent-benchmark-forced-proof.mjs <artifact-config.json> <negative-proof> --negative
node scripts/test-agent-benchmark-forced-unknown.mjs <artifact-config.json> <fresh-unknown-proof>
# Requalify the frozen grader if one of its execution-source pins changed:
node scripts/test-agent-benchmark-pilot-grade.mjs <fresh-grade-proof> <exact-image-sha256>
# Privately set qualificationReceipt/gradingReceipt in preparation config.
node scripts/agent-benchmark.mjs --pilot-forced-prepare <preparation-config.json> <fresh-plan>
```

Preparation and postchecks make no live vault/provider request and create no grant.
The prepared manifest pins `forced-codemode-parallel`, concurrent admission,
adapted labels, artifacts, execution sources and the same approved per-arm
`gpt-6.1-sol` LOW /120 dispatch /20M input /120k output /45min /180s request /
zero whole-trial-retry envelope. Only the coordinator records the actual human
approval reference and runs the single fresh wave:

```
node scripts/agent-benchmark.mjs --pilot-forced-run-approved <manifest.json> <fresh-results> <exact-manifest-sha256> <actual-human-reference.json>
node scripts/check-agent-benchmark-forced-proof.mjs <artifact-config.json> <results> --live
```

One durable exclusive/fsynced launch intent precedes trial effects. Consumed or
unknown intents require observation/reconciliation, never another launch.
Token thresholds are post-response and may overshoot once per arm. Dollars and
subscription quota are unknown, not hard caps. Each box retains2CPU/2GiB/128PIDs/
1GiB tmp, network-none and persistent workspace without hard disk quota. Four
limits aggregate up to8CPU/8GiB plus uncapped Windows controllers, **not** host
capacity/reservation. Concurrent timings are shared-CPU/provider-contention
affected, not a clean backend latency ranking or a production-default decision.

No autonomous quality, provider entitlement, actual billing, full release gate,
installation or HTML publication follows from these model-free proofs. The frozen
oracle/interface limitation, original task, original native absolute-path behavior
and native base64/text representation are not repaired by this change.

## Retained q5 rg reconciliation

Read-only inspection of the exact q5 owner inventory and verified sealed record
found `rust-v2/h/.wasm-agent/bin/rg.exe`:4,218,880 bytes, SHA256
`14231169855ec5205cf5a1b6f1db358ff4aed4247c86b69ce8aae647c77f6680`.
It is the only provisioning-related entry in that isolated home; the original
copy is absent after q5's verified exact-owned cleanup. All four native trees were
settled and its Docker resources removed. The executable is retained in q5's
lossless archive, not installed into another home or replayed. The downloaded
archive/network-transfer provenance was not retained and is not independently
certified. New qualification uses the existing-rg copy/Node-absent path instead.
