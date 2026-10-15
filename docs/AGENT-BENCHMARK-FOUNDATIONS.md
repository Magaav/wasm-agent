# Model-free benchmark foundations

This extends `scripts/agent-benchmark.mjs` and the existing offline token auditor;
it is not another platform or a ready four-arm comparison. No code-mode engines,
benchmark solver inference, installed assets/configuration or production caps change.
Subsequent experimental engine implementation is documented separately in
[CODEMODE.md](CODEMODE.md); the foundation below remains a model-free fixture,
not a completed four-arm comparison.
Preparation assistant inference is real work and must not be labeled zero inference.

## Fixture and hidden behavioral acceptance

`fixtures/benchmarks/binding-discovery/v1/README.md` describes the final fixture.
Its manifest hashes the exact original task, sanitized input, native declarations,
original private artifact and sealed complete selected original message rows. The
private rows include full original fields/trace/encrypted reasoning without elision;
only necessary pre-request context is exported. Raw task-source instruction bytes
are privately retained and checked unchanged in exports. No memory is auto-injected.
The original task/run6592 and the final answer6682 are actual retrieved boundaries.
Run elapsed1,797,766ms differs slightly from start/end field subtraction and answer
latency; all are retained, none relabeled as a new solver result. The historical run
included push/deployment coordination outside the restricted future solver scope.

```
node scripts/agent-benchmark.mjs --binding-export <fresh-private-output>
node scripts/agent-benchmark.mjs --binding-preflight <native-binary> <fresh-evidence>
node scripts/agent-benchmark.mjs --binding-grade <native-binary> <candidate-tree> <fresh-evidence>
```

Task source is `dc11c4626358438514624afa05c20bacb68cdbe7`; native grader binary is
separately SHA-256 pinned. Hidden oracle and known repair never enter solver exports.
A full tracked snapshot is archived without original Git metadata/remotes/history.
Exactly five instruction files are preserved, not trimmed. New solver containers
may initialize their own snapshot-only Git repository, never mount the original
object store or live credentials. Only locally verified patch/handoff is permitted;
no push/deploy/install/restart/client/browser/send effects. The sanitized reference
artifact stands for the original private prompt-bearing HTML, explicitly disclosed.

The oracle imports actual task modules, preserves all original native parameter
schemas/names, and checks scoped capability/discovery metadata, loading, role/profile
ceilings, allocated/failed/unreadable bindings, argument-dependent tools, binding
changes, original direct refusals and ordinary unbound status using a client mock.
Independent native processes share only the private grade DB for restart/load tests.
External client/exec/operation/network capabilities are fenced before task imports.
That cooperative Lua fence is NOT an OS sandbox against malicious source; future
untrusted solver grading must remain inside the isolated container substrate.

Preflight validates original failure, repaired success and eleven negative controls:
blanket deny, discovery hiding, hardcoded unavailability, guard bypass, unbound rejection, profile
bypass, stale load state, actual private DB-loss across restart, role bypass,
dynamic scope hardcoding and schema drift. An expected-negative exit is not enough
for success claims about the repair: the positive must finish both native phases,
return the complete counted oracle summary and make zero planner client effects.

## Trace and accounting adapters

```
node scripts/agent-benchmark-observe.mjs native <complete-private-events.json>
node scripts/agent-benchmark-observe.mjs pi <private-session.jsonl>
node scripts/agent-benchmark-observe.mjs prepared <private-prepared-requests.json>
python scripts/agent-benchmark-report.py <private-trace-dir> <fixture.json>
```

`agent-benchmark-telemetry.mjs` reuses `lib/token-audit.cjs` for native identity,
span chronology, duplicate/conflicting event and incomplete-export validation.
Actual SQLite rows include all kinds/phases, not just successful model ends.
Failed/pending requests, summaries and `transport_failed_attempts` remain present;
unknown lost usage makes complete cost unknown. Exact duplicate events are counted
once, conflicts fail. Pi session messages and compaction records are adapted with
ID/tool-call/result validation. Uncorroborated all-zero Pi SDK usage stays unknown,
including aborted/error rows. Absent compaction inference usage is unknown. Pi
JSONL alone cannot prove all provider attempts/retries/summaries: complete worker
cost stays false, even if the visible catalogue subtotal exists. Worker totals
remain unknown; visible rows cannot establish complete worker cost.

Normalized disjoint fields are:

```
prompt_total = uncached_input + cache_read + cache_write
reasoning <= output                    # subset, never added again
```

Pi `usage.input` is uncached input; native normalized `prompt` is total prompt.
Counts must be nonnegative safe integers and internally consistent; overflow,
fractional counts and ambiguous old `input` accounting fail. Missing values stay
null. Reported/configured/catalogue price is `reported_priced_cost`, NOT billing.
`actual_cost` requires an explicit USD priced receipt hash; absent/subscription
prices remain unknown, including Pi catalogue zero. Optional
`referenceRatesUsdPerMillion` uses the four disjoint categories and produces only
`hypotheticalReferenceCostUsd`, never an invoice or actual billing claim. Incomplete
usage makes that comparison unknown too. All attributable setup/retry/summary work
belongs in the worker's complete journal, not just the winning final attempt.

Metadata reports do not emit prompts, arguments, summaries, private output text or
credentials. Raw/private files and their hashes remain the source of evidence.
`tokens_wasted` is null: avoidable-work entries require explicit adjudicator,
decision and evidence references, not repeated-call counts automatically labeled
waste. Raw reported usage is retained privately and referenced by hash.

Native model *decision steps* use observed round/run identity when present;
model/summary attempts are separate. Pi visible assistant messages are not proven
provider steps. Tool/nested-code-mode counts, retries, compactions, redundant calls,
human help, CPU and peak memory are known only where actually observed. Missing
nested-code-mode/CPU/memory stays null. Native timings reuse actual span evidence.
Generic setup/build/index/test/model/tool/sandbox startup and end-to-end observations
require paired clock values and receipt hashes; phase sums can overlap and are not
inferred CPU/global wall time. Normal process exit, verified handoff and behavioral
pass-at-timeout are distinct. No present quality score or winner is fabricated.

## Prepared-prefix/cache analysis

`preparedRequests` compares canonical per-message hashes and the exact tool/model/
routing/instruction fences, matching native `prefix_audit` semantics. It does not
compare serialized whole JSON prefixes: appending a message changes closing brackets
and the old `startsWith` control therefore falsely breaks a stable prefix. Request
settings such as output caps are separate from cache-relevant changes; explicit
prompt_cache_key changes are treated as routing changes. The actual
native provider/serializer loop with mocked HTTP independently verifies append-only
parity; realistic message/tool-call fixtures cover long runs, edits, session/scope
changes, missing routing, eviction/restart and instruction/schema/model changes.
Baselines are local to this analysis, at most16 scope/session/kind keys and8,192
messages; missing/evicted/oversized baselines stay unmeasured.

Only provider-reported counts produce observed-cache-read/observed-zero labels.
Fresh homes/bytes are not evidence of cold provider caches or occupancy. Backend KV
contents remain opaque. Reports expose hashes/counts/reasons/TTFT only, not request
text or routing identifiers. Credential-bearing headers/routing/endpoints and
provided secret-exposure controls refuse. These tests check invariants, not a
comprehensive absence-of-leakage theorem. Pi provider-wire prepared captures are
still a future runner requirement; session JSONL does not contain that wire body.

## Seal first, then owned cleanup

`agent-benchmark-results.mjs` owns fresh evidence generations. Create a root with
`createGeneration`; `disposable` registers each newly created directory with a
nonce, exact filesystem identity and marker. It cannot adopt arbitrary directories.
Record manifest, task/context/oracle IDs, final outputs, patches, full relevant raw
traces/logs, failed attempts, receipts, accounting/cache/quality data using `record`.
Extra files under `records/` are included byte-for-byte, including binary bytes.
Drain processes and collect final outputs before sealing; live/uncertain effects
cannot be certified as complete results. Completeness is of the declared/retained
records, not proof that an uninstrumented provider never made another attempt.

```
node scripts/agent-benchmark.mjs --seal-results <owned-generation>
node scripts/agent-benchmark.mjs --verify-results <owned-generation>
node scripts/agent-benchmark.mjs --cleanup-results <owned-generation>
node scripts/agent-benchmark.mjs --reconcile-results <owned-generation>
```

Independent native/OS-owned tree settlement and complete
volume capture precede sealing; large evidence uses bounded version2 gzip JSONL
frames, with version1 still readable through the same verifier. Use `readSealedRecord`
for selected evidence rather than materializing an archive-sized JSON string. Its generation/nonce, manifest,
every file hash/length/path, required records and original-copy inventory are checked
before removal. Keep the archive, owner journal, cleanup/reconciliation receipts and
fixture. Only then remove exact registered disposable directories and redundant
record copies. Symlinks/junctions, hardlinks, special files, escaping paths, changed
identity/marker, unregistered/shared/active managed trees, corrupt/missing records
and live/merely-exited/unknown processes refuse. `registerSnapshotGit` accepts only
an already generation-created standalone snapshot repository: exact root/common-dir
and Git-directory identity, one worktree, no remotes/alternates/shared object stores.
Managed `.git` files, external trees and shared Git stores are refused. Contents are
inventoried at seal and must remain unchanged before deletion. Snapshot exports,
registered standalone solver checkouts, temporary builds and homes are supported;
paid solver lifecycle wiring must use this adapter, never the old recursive remover.

`containedProcess` uses the production native operation supervisor and requires
settled tree/closed-stream receipts, with full output retained. A bare child exit
never proves detached descendants drained. Native Windows job-object settlement was
actually tested with a detached descendant. Long SQLite paths can exceed native
Windows limits; use short names inside the owned scratch root, not another home.

`agent-benchmark-docker.mjs` provides actual exact-generation Docker create/inspect/
start/stop/drain/remove adapters. It requires an existing pinned image ID; never
pulls, prunes, force-removes or removes shared images/caches. Resources carry the
nonce label. Inspect rejects foreign/shared mounts, live processes, attached
networks/volumes and uncertain states. The direct pilot's exact generation-owned
workspace volume is the narrow exception: it persists across process loss, is
captured through a drained read-only reader, and requires a verified snapshot before
sealing/removal. No host or credential mount is admitted. Drain/log capture precedes sealing; deletion
is journaled before the effect and exact absence is read back. Actual model-free
container/network/volume cleanup was tested against Docker27.3.1 with a cached Node
image, no network/mounts and no inference. Shared image remained. Mock tests cover
uncertain receipts without replay; they are separate from the actual Docker proof.

After a crash, `reconcileFilesystem` reads exact ownership/absence and preserves
unfinished/unknown scopes; it never retries deletion. `reconcileDocker` can resolve
an already-journaled deletion only from exact absence readback; other unknown
operations remain unresolved. Cleanup failures are visible and block 'finished
clean'. After sealing, deletion/recovery receipts are append-only sidecars linked to
the bundle hash; they cannot have existed before their effects. The private owner
journal and same-user filesystem checks are coordination boundaries, not an OS-wide
transaction or protection against an administrator racing filesystem mutations.
Never delete parent/historical evidence, credentials, active worktrees or unresolved
effects. Negative-test generations remain retained evidence, not swept scratch.

## Quality, controls and remaining paid-run work

`qualityNotes` validates the fixed100-point rubric: correctness35, completeness25,
safety/scope20, verification15, clarity5. Each actual subjective score requires
reasoning and evidence. Default score/notes are unknown; coordinator grades later.
`anonymizedOutputId` uses a private grading salt; keep the arm mapping out of grading
inputs where feasible, without changing original output bytes.

Coordination must use approved native task ownership with explicit operator enablement.
No nested workers/hidden coding agents. Parallelize only independent hermetic setup
and checks; timed arms run serially/counterbalanced to avoid provider/CPU contention.
Fresh evidence generations preserve failed attempts. Use these verified CLI/postchecks
where the allowed tool profile lacks spell tools; unsupported replay is not attempted.
Do not grow AGENTS.md or impose benchmark caps on production coding.

The new guarded direct pilot is in [AGENT-BENCHMARK-PILOT.md](AGENT-BENCHMARK-PILOT.md).
It connects these adapters to actual blind persistent tool workspaces and isolated
grading; no autonomous trials or paid results are implied. The older boolean/UI
entry remains refused. Exact current-source qualification and human approval are
required before the new explicit entry can launch. The proposed first pilot is one attempt per four arms,45min each,
gpt-6.1-sol LOW only after a common isolated route is proved. V1 Node hosting remains comparison only; the confirmed V2 target is
Node-free Rust/Wasmtime, with no Node process/bridge/fallback during execution.
Benchmark/test tooling and Pi are separate. The experimental ABI/imports/native dispatcher and Node-unavailable proof now exist;
see CODEMODE.md and CODEMODE-BENCHMARK-WIRING.md. The V1 broker and four-framework
two-round tool loops are wired and tested with a mock upstream, now also through the
actual vault using synthetic credentials. The candidate vault-subscription relay
and restart-readable attempt journal are implemented; absolute upload/stream clocks,
partial failure retention and a synthetic two-container isolation topology are
model-free tested. The direct pilot qualifies the actual runtime/tool-box topology and isolated
behavioral oracle, with a source-bound limits proposal. Real provider entitlement,
operator-owned credential configuration, approval and actual trials are still
separate. No autonomous comparison results exist here.
