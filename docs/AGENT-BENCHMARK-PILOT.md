# Qualified four-arm pilot: execution and approval

This is the existing benchmark runner's integration, not a new agent platform.
Qualification runs actual Pi1.2, historical wasm, Node-hosted QuickJS-WASI V1
and Node-free Rust/Wasmtime V2 loops against a deterministic provider through the
actual synthetic vault. It is **not an autonomous comparison**. No score, winner,
real-provider acceptance or subscription-dollar result follows from qualification.

## Authority and scope

Development is direct while orchestration is off: no coding subagents, alternate
worker registries, production configuration changes, installation or recurrent wakes.
The later experiment needs explicit human approval of one isolated contestant
attempt per arm and its exact manifest/limits. That is a narrow experiment exception,
not general delegation. The coordinator owns the enclosing native operation and
retains its actual receipt. Do not fabricate an approval message, independent review,
factory admission or native child task. Sentinel notices never supply approval.

`--pilot-run-approved` requires an unchanged prepared manifest hash and an original
human message reference. References are evidence pointers, not authentication or
self-issued grants: the native master invocation and actual human decision remain
authoritative. Preparation's `operator_approved:false` is never edited into a grant.
A once-only, fsynced launch intent in the manifest's original directory precedes
trial effects. Copies cannot create another reservation. An existing/unknown intent
is observation/reconciliation work, never permission to rerun a contestant.
The legacy/UI paid path remains disabled; boolean readiness declarations grant nothing.

## Pi-only output-capture repair and fresh reservation

The original four-arm reservation is consumed; never edit, resume or replay it.
Its Pi output-limit failure and unknown final-request usage remain original evidence.
The human's subsequent “fix output limit, rerun pi” request authorizes **one fresh
Pi attempt**, not another four-arm wave. The coordinator must record that actual
human message reference; no example reference or metadata flag is a grant.

Pi now writes every SDK event, unabridged, to private `pi-events.jsonl` with exclusive
creation, checked writes and fsync per event. Final fsync/close and a durable result
file precede the single bounded console receipt (count/bytes/SHA-256 only). Complete
messages and SDK session files remain private alongside the raw journal. Event,
result-write or close failures cannot produce a normal-finish receipt; partial files
and stderr remain evidence. Abrupt native termination may leave no completion hash;
that is incomplete evidence, never a normal finish. `events_file` names the raw
journal, not console metadata. Lifecycle verification and lossless sealing retain
all of these files. No raw event is elided or made solver-visible; the global50KiB
view and inherited8MiB supervisor capture bound are unchanged. Per-event fsync adds
real logging overhead; this is disclosed, not a performance-neutral change.

The new commands reuse the same source/artifact qualification, isolated arm,
route/grader, durable once-only intent and seal-first cleanup. Old four-arm commands
and defaults remain four-arm; neither entry accepts the other scope's manifest.
Use absolute paths and **new directories**, with the original artifact config:

```
node scripts/agent-benchmark.mjs --pilot-pi-qualify <artifact-config.json> <fresh-pi-proof>
node scripts/check-agent-benchmark-pilot-proof.mjs <artifact-config.json> <fresh-pi-proof> <verified-grade-proof> --pi-only
# Copy artifact/preparation config privately; set qualificationReceipt to
# <fresh-pi-proof>/receipt.json. Keep build/grading receipts and artifact pins.
node scripts/agent-benchmark.mjs --pilot-pi-prepare <pi-preparation-config.json> <fresh-pi-plan>
# Coordinator only, after recording the ACTUAL new human message reference:
node scripts/agent-benchmark.mjs --pilot-pi-run-approved <fresh-pi-plan>/manifest.json <fresh-pi-results> <manifest-sha256> <actual-approval-reference.json>
```

Pi-only qualification streams over8MiB of actual SDK raw events through the unchanged
native supervisor, followed by real blind read/write/bash results and final handoff,
using the actual synthetic vault and **zero real provider calls**. The postcheck
verifies source/artifact equality, archive integrity, raw event counts/bytes/hash,
full later messages, bounded console receipt and owned cleanup. Source drift requires
new qualification; a historical four-arm proof is not a Pi-only proof. Model-free
failure controls reuse `test-agent-benchmark-pilot-policy.mjs --capture <native-binary>
<fresh-evidence>` (old console overflow, exact raw retention and write/fsync/close
failures), `test-agent-benchmark-pi-route.mjs <Pi-package> <fresh-evidence>
--controller-failures` (actual SDK partial-stream and raw-write-failure aborts,
retained failures/unknown usage and one dispatch/no replay), and
`test-agent-benchmark-vault-route.mjs <fresh-evidence>` (unknown usage,
abort/deadline/failure capture and no replay).

The fresh Pi-only manifest fixes `arms/order` to `["pi"]`, gpt-6.1-sol LOW and exactly
the same per-arm controls below (including180s absolute request deadline and zero
automatic whole-trial retries). Task source, instructions, oracle, SDK/tools, blind
broker, token overshoot and unknown dollars/quota are unchanged. Fresh home/session,
volume/output and launch intent are mandatory; never continue request0010 or the
failed Pi workspace. Preparation does not contact the live vault or launch a model.

## Real blind boundary

Trusted runtime processes stay outside the tool box. Every model-directed file/shell
operation is confined to a networkless Docker container, with read-only root,
dropped capabilities, no-new-privileges, private PID namespace and no host/Docker/
credential mounts. A fresh generation-owned **persistent volume** holds only the
frozen task, public context, local snapshot Git and contestant work. Repaired runtime
Lua/binaries, credentials, grader and original Git history never enter the live box.

The common verification host in the cached tool image predates the task: the actual
embedded `tools.lua` hash matches ancestor `1ab3024e2e8098718efae269d20bbe60181a4900`
and `envelope.lua` is absent. The image tag was not sufficient provenance. The full
binary's build source remains unknown; image bytes and observed embedded module
hashes are pinned. Only this compatibility facility is used in the box. Native
contestant runtime source/binary pins are separate, including a clean-built
`b384a15c` historical baseline. Do not call it today's production runtime.

The task is the original `dc11c462` tracked snapshot plus exactly the sanitized
`solver/` inputs. Five instruction files remain byte-identical. Original POSIX file
modes are restored from that Git tree. A new snapshot-only Git repository has no
remotes/shared objects or solved history. Context paths are explicitly mapped to
`/tmp/work/.benchmark-input`; no private provenance or memory is injected.

Private native adapters retain the original schemas/role/dispatch/routing/code-mode
checks and narrow available tools to file operations, discovery and own-result
retrieval. Raw filesystem effects go to Docker, never an ambient fallback. Static
trusted module loading is separate. Generated/hash-validated result and image
storage may use only that runtime's private home; attempts to read those host paths
through ordinary file tools still fail. Cached read-many pages do not refetch files.
Pi uses its built-in tool definitions with supported operation adapters; extensions,
skills and warming are disabled, and its private generated output files remain
readable without exposing runtime or credential files. Preserve cooperative markers.
These are disclosed benchmark adapters, not new production capabilities.

## Qualification and preparation

Use absolute paths and a fresh directory for every attempt:

```
node scripts/agent-benchmark.mjs --pilot-qualify <artifact-config.json> <fresh-runtime-proof>
node scripts/test-agent-benchmark-pilot-grade.mjs <fresh-grade-proof> <exact-cached-image-sha256>
node scripts/check-agent-benchmark-pilot-proof.mjs <artifact-config.json> <runtime-proof> <grade-proof>
node scripts/agent-benchmark.mjs --pilot-prepare <preparation-config.json> <fresh-plan>
```

Artifact configuration names `baselineBinary`, `candidateBinary`, `piPackage`,
`assets` and exact `imageId`. Preparation additionally requires `baselineReceipt`,
`candidateReceipt`, `qualificationReceipt`, `gradingReceipt`; optional `vaultUrl`
selects the proposed private origin (default127.0.0.1:8810, **not asserted configured**).
Preparation reads no real credentials, changes no provider state and makes no
real provider call. It records the Node platform/version, full Pi module tree/lock,
asset tree, binaries, fixture and all execution-source hashes. Source/artifact drift
refuses launch. Runtime and grader proof receipts must match their verified archives.

The real Linux grader uses a fresh box only after the contestant settles. The exact
original task SQL schema is supplied to the older verification host before importing
candidate Lua; this is compatibility setup, not a repaired tool module. Original
failure, repaired142+144 checks and eleven deceptive repairs must agree, including
actual private-DB loss/restart. Client/exec/network calls are fenced; untrusted
candidate code still stays inside the OS box, not in the controller.

Focused checks also include `test-agent-benchmark-sandbox.mjs <wa> <fresh> <node-image>
[--embedded]` (real file/receipt/role/image/cache/host-path refusals),
`test-agent-benchmark-sandbox-lifecycle.mjs <fresh> <node-image>` (exit survival,
read-only recovery and unknown-effect/no-replay), `test-agent-benchmark-bundle.mjs
<fresh>`, and `test-agent-benchmark-pilot-policy.mjs <manifest> <fresh>` (no network).
The retained/current-source postcheck above settles the qualification claim; it does
not certify provider entitlement, quality, billing or paid launch.

## Proposed first-pilot limits

All four arms use `gpt-6.1-sol`, LOW, the same task/tool permissions and common route,
serially in the declared order. One attempt each is exploratory, not statistical
proof or a basis for a production default.

| Control | Per arm | Four-arm threshold total |
| --- | ---: | ---: |
| Provider dispatches, including summaries/failures |120|480|
| Reported total input (cached input is a subset) |20,000,000|80,000,000|
| Reported output (reasoning is a subset) |120,000|480,000|
| Solver wall time |45min|180min|
| Absolute provider request deadline |180s|—|
| Automatic whole-trial retries |0|0|

Token thresholds are checked **after** responses: one response per arm can cross
one. Unknown usage halts that arm without replay; unknown tool effects halt the wave.
Subscription billing/quota and actual dollars remain unknown. This is **not** a hard
dollar/token cap. The proposal is an upper envelope, not an expected spend/duration.

The tool box has2CPUs,2GiB RAM,128PIDs and1GiB `/tmp` scratch. Its persistent
workspace has **no hard disk quota**; name that risk before approval. The controller
runtimes share one Windows host serially without CPU affinity/process-memory caps;
complete CPU/memory accounting can remain unknown. V2 fuel/linear-memory limits
have no identical V1 SDK mechanism; disclose the qualified differences in CODEMODE.md.
The existing global50KiB native output view is unchanged; complete originals remain.

## Approved execution and outcome

After actual human approval, preserve its original message reference in an approval
file (`session_id`, `message_id`, `manifest_sha256`) and invoke only the exact plan:

```
node scripts/agent-benchmark.mjs --pilot-run-approved <manifest.json> <fresh-results> <approved-sha256> <approval-reference.json>
```

A local vault-presence check precedes trial admission; no login/import/refresh or
production setup is performed by this runner. An unavailable/disabled credential
route refuses before a trial. The first approved request establishes actual model
acceptance; no extra unbudgeted paid probe or provider fallback is used. `/status`
configuration alone is not entitlement. Capture every observed provider attempt,
prepared request and response, including retries/summaries/partial failures. Keep
unknown usage unknown and hypothetical pricing separate from actual billing.

The actual actor is natively supervised to complete tree settlement. Tool commands
are bounded by remaining solver time. On actor exit, stop/drain the writer namespace,
then use a fresh **read-only** reader to capture patch and complete workspace before
retirement. The51min one-shot box lifetime is an abnormal-controller-loss backstop,
not a recurring job. Abrupt controller death can leave owned tool work until that
backstop/recovery; never claim immediate Docker cancellation or complete cleanup
from a closed Windows process. The persistent volume preserves recoverable drafts.

Recovery inspects the exact generation/nonce and containing native operation first.
Use the owned Docker adapter to stop only known live resources; held unknown effects
stay held. A reader can use `createToolSandbox(root,{imageId,existingVolume,
readOnly:true})` only for an already-owned, drained volume. It observes/captures data;
it never reruns tools, model calls or scripts. Foreign mounts/owners and shared live
writers refuse. Never hand-edit resource ownership or release a live owner.

Sealing requires verified complete volume snapshots. Containers are removed before
volumes; exact absence is read back only after lossless archive verification. Unknown
or partial capture blocks deletion. Large archives use version2 bounded JSONL gzip
members (header/chunks/end); old version1 remains readable. Use `verifyBundle`/
`readSealedRecord`, not an archive-sized JSON string. Raw bytes, modes and failures
remain retained; no log/context elision or output-view budget increase is involved.

Report normal finish separately from hidden acceptance and timed-out recovery. A
snapshot captured after namespace drain is **not proof of state at the exact time
cutoff**. Keep actual snapshot/solver/setup/grading/drain timestamps distinct. Quality
notes remain coordinator reasoning under35/25/20/15/5, separate from counters and
oracle acceptance; execution alone never fabricates a score or winner. See
[AGENT-BENCHMARK-FOUNDATIONS.md](AGENT-BENCHMARK-FOUNDATIONS.md) for accounting,
cache evidence and post-seal sidecar contracts.
