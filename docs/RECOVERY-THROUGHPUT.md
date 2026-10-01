# Recovery throughput and deployment evidence

`scripts/test.sh` remains the complete smoke gate. All pre-existing checks, suite verdicts,
skip accounting and failure exits remain; new runner, proof, installation and sentinel checks
are additions. The EXIT handler now preserves fixture cleanup, phase reporting and the original
status together. Successful homes are removed; failed homes retain their evidence under the
existing retention rule. Standalone merge/finish fixtures own private gate queues.

`node scripts/gate-check.mjs list` discovers independently runnable checks, commands, coverage,
isolation and declared resources. `run ui-js --jobs 1..4` runs the same JS fixtures as the full
gate. Each child gets private runtime/home/config paths, stripped provider environment and its
own logs. Width is a hard bound; declared memory sums also bound admission using available
memory by default. Memory values are estimates, not OS quotas. Browser checks use private DB,
profile and dynamic ports; a port allocation race is an explicit fixture failure. The complete
inline Lua/runtime suites remain serial until their dependencies and isolation are established.
A declaration does not authorize parallel execution of unknown suites.

The default width is **1**. `WA_CHECK_JOBS` deliberately opts the smoke gate into a measured
width; `WA_GATE_JOBS` separately bounds Cargo and Rust tests. The existing production reservation
remains serial. Both finish and merge consumers validate live ancestor inheritance and refuse
missing/unreadable/skewed reservations. A timed-out merged-tree shell retains the reservation
until explicit descendant-drain reconciliation. No result caching by guessed inputs is added.

Individual top-level Rust/Node/shell command durations and statuses are written to
`git rev-parse --git-path wa-gate-check-timings.tsv`; phase timing remains a separate segment
measurement. UI JS logs/receipts survive successful home cleanup under `wa-gate-ui-js` in this
worktree's Git metadata. Full smoke logs remain source-tree-bound and hashed by the finisher.

## Producer admission and complete integration

After this implementation passes the unchanged complete coverage requirement for bootstrap:

1. Commit/push a current producer tip and independently review that exact tree.
2. `node skills/parallel-evolution/scripts/finish.mjs admit <own-repo> <exact-head>` runs
   conservatively selected checks and writes `wa-producer-check.json` in its Git metadata.
   Only JS test changes and `ui/app.js` / `ui/components.js` currently have focused plans;
   UI source changes include the browser check. Unknown paths, shared Rust/Lua/runtime changes,
   configuration, documentation and tooling changes require the full gate. The UI browser
   fixture may use an installed host when no candidate host exists; it proves source-page
   behavior, not a new runtime. Complete candidate verification still follows.
3. An independent lane uses `delivery-admission.mjs check|admit ... --producer-proof <receipt>`.
   The rule verifies exact tree, current coverage, runner identity, successful exits, zero
   focused skips and log hashes. The admitted record retains the proof. Existing independent
   published-review and excess-claim refusals remain. Focused proof is
   `admission_verified:true`, **`gate_verified:false`**, `requires_combined_gate:true`.
4. `merge-lane.mjs ... --delivery-store <store>` reads these actual admission records, rejects
   moved/unreviewed/unverified recorded tips and creates one combined candidate. The complete
   gate covers that exact candidate before publication. Legacy manual entry points without a
   delivery store still require the merger's independent review decision; they are not focused
   admission. Integration policy and automatic continuation are owned by the convergence lane.
5. A complete identical-tree smoke receipt may be reused. Reuse checks schema, passed state,
   exact Git tree, real exit/run count, duration, terminal verdict, skips and log hash. A custom
   stand-in gate never creates reusable production evidence. Merge receipts/logs survive clone
   removal under `wa-combined-gate.json` in the invoking lane's Git metadata; source-tree changes
   require execution. `deploy.sh` requires discoverable complete proof for a real Rust source
   workspace before building/installing. It still proves the built binary on a scratch port and
   verifies the actual installed PID/artifact. No focused receipt authorizes installation.

Queue wait, build/check duration, combined verification and live installation are different
measurements. An identical-tree reuse has zero new gate runs and retains the original measured
run duration. A receipt proves source execution and is not a toolchain or binary attestation.
The current upgrade proof separately binds actual binary/UI/helper bytes before swap.

## Equivalent workload measurements, 2026-10-01

Reproduce with `node scripts/measure-gate-checks.mjs <evidence-directory>`. Each sample alternates
serial and width-two execution on the same source/test IDs. All assertions and exits run;
no race waits are shortened. Final runner measurements on upstream `1035175` (same source/test IDs within each pair):

| Workload | n per width | Serial median | Width-two median | Median summed child wall time, serial / two |
| --- | ---: | ---: | ---: | ---: |
| single composer-input fixture | 3 | 205.81 ms | 204.60 ms | 205.07 / 203.69 ms |
| all eight JS fixtures | 3 | 14,296.65 ms | 13,200.48 ms | 14,288.49 / 14,293.08 ms |

The batch is about **7.7% faster**; the single fixture is effectively unchanged. `whatsapp-store.js`
dominates at about 13 seconds. This supports keeping the knob, not choosing a wider default.
Summed child wall time includes waiting and is not CPU work.

A separate sampled run per width (`measure-throughput-resources.ps1`, n=1 each) observed:

| Width | Wall | CPU lower bound | Peak summed working set | Read/write transfer lower bounds |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 14,682 ms | 203.125 ms | 188,596,224 bytes | 631,090 / 7,345 bytes |
| 2 | 13,586 ms | 343.750 ms | 236,023,808 bytes | 673,042 / 7,344 bytes |

CIM sampling at 500 ms plus scan time misses short-lived children. Working sets double-count
shared pages; transfer counters include non-disk I/O. The sampler and other lanes may perturb
latency. These small samples establish neither peak capacity nor a production throughput default.

`test-producer-admission.mjs` creates actual committed scratch candidates: a narrow single change
runs one focused check, the published independent review is admitted, a shared runtime change
requires full verification, a deliberately failing narrow candidate stays refused despite printing
success text, and altered/missing/stale evidence fails. `test-merge-lane.mjs` exercises an independent
change batch, a failing candidate, timeout/descendant drain and combined-tree checks through a
stand-in full gate. These are correctness scenarios (n=1 per case), not production deployment
latency samples. The existing full-gate baseline at UI reservation 207 was 1,381,595.656 ms,
2 skips, n=1; its phase total was 1,381,211 ms and build segment 528,387 ms. That different source,
build state and phase-level instrumentation cannot establish a before/after speedup.

Evidence is retained outside live runtime diagnostics at
`C:/Users/Victor/.codex/handoffs/throughput-main103-measurements/summary.json` and
`throughput-resource-fixed-{1,2}/resources.json`. Full bootstrap evidence belongs to this
worktree's `wa-finish-gate.json` and its hashed log. Actual reviewed-tip-to-deployment timing,
combined-tree verification and installed-source proof belong to the coordinator's integration
receipt. No two-minute delivery claim is made by these suite measurements.

## Installation and watcher recovery

Upgrade uses the shared `wa_config_dir` interpretation of `WASM_AGENT_HOME`: repository skills
and their helpers ship to `<home>/.wasm-agent/skills`, and verification compares every source
skill file there. Legacy `<home>/skills` is not the current writer and may contain unrelated user
content; stale runtime files still fail comparison. Missing service-target helpers fail before
swap. The downgrade fixture uses private install/home for every refusal, including the production
main-only rule via `--require-main`, and asserts live binary/record/log/result preservation.

Held intent from `dcf49653c42375f5e7c32cadc28a83405d88527c` was rederived on current sentinel/update
source rather than replacing newer behavior. The watcher holds an OS lifetime lock; a live PID
without that proof is unverified and cannot justify a second watcher. `preflight` is JSON and never
calls node health, so `/update` can use it while the node serves that very request. Start/stop/restart
serialize lifecycle ownership; explicit start is operator resumption, while unsolicited watch and
restart preserve a pre-existing intentional stop. A successful direct start names its actual spawned
PID only after that PID's record and lifetime ownership are proved.

`request deploy --if-no-pending` serializes pending/claimed inspection and durable request write
with the claim transition. Its lock never covers health probes, idle waits or execution. It also
checks watcher identity and intentional stop under lifecycle ownership. Concurrent duplicates name
the existing request and do not overwrite it; `/update` reports `already_pending`, not queued.
An exit-zero response without a durable request path is unverifiable. Request filenames cannot
silently replace same-process requests. Dedupe covers queued/claimed intents, not detached deploy
completion: a launch receipt still does not prove installed effects, and the wave owner must read
actual deploy-result/installed/health evidence before completion.

`test-sentinel-ownership.cjs` proves real process concurrency, recycled-PID refusal, preflight
responsiveness under a held health probe, one durable concurrent deploy intent, independent claims,
original request preservation and intentional stop (25 checks, n=1 fixture). The Rust suite passed
33 tests; the source-root Lua watcher fixture passed 33 checks. These are scratch fixtures; the
coordinator alone owns live install and end-of-wave convergence.

The opt-in graph audit ran against this working tree using a private graph home/database.
It reported no unread resolved caller leads, but an incomplete verdict with 176 coverage
gaps (truncated) and 27 relevant unresolved calls. Shell/PowerShell/top-level edits and
dynamic dispatch remain outside its useful coverage; this is not a correctness certificate.
Source inspection and the focused/full suites remain necessary. The audit artifact is
`C:/Users/Victor/.codex/handoffs/throughput-graph-audit.json`.

Bootstrap attempt 213 failed after 759,898.563 ms (n=1 incomplete run):
`test-disk-floor.cjs` looked for a bare `cargo build` line and did not recognize
its new transparent `gate_run` timing prefix. The floor still executed before
any build; the wiring assertion now recognizes that prefix and still requires
an actual build after preflight. Its other disk/refusal assertions are unchanged.
The failed log and command timings are archived as `throughput-full-gate-213-*`
under the external evidence directory. This failed attempt is not a smoke pass.

Bootstrap 214 passed the complete original gate at `9bf1dd8`, tree
`3d0df35f82c99abfd31498f172faab03f98533d1`: 843,906.577 ms, 2 skips,
queue wait 59 ms, n=1 warm successful run. Individual phase and command timings
are archived as `throughput-bootstrap-214-*`. It is not directly comparable to
the different-source cold UI baseline and does not prove whole-pipeline speedup.

Independent review of that exact tip required two corrections: focused receipt
verification now re-parses terminal log evidence even when flags and recomputed
hash match; combined gate proof now requires post-gate HEAD/tree and tracked plus
untracked cleanliness to match the captured candidate. Synthetic JS/browser
matching-hash invalid logs and three real default-command source mutations
(tracked content, untracked content, moved HEAD) must refuse reusable proof.

Pending/claimed malformed or unreadable records now surface `unknown_inventory`;
preflight retains watcher identity but advertises unverified inventory, and
atomic deployment admission refuses until the evidence is reconciled. Uncertain
records remain untouched. Native read-error/malformed fixtures and the Lua update
refusal prove this behavior rather than treating unknown as an empty queue.

Deployment defaults its runtime binding to the sole clean canonical `main`
checkout equal to fetched `origin/main`, chosen read-only. It atomically writes
`runtime-worktree.txt` with the prior binding backed up. This keeps future `/update`
source on canonical main without a permanent feature branch; an explicit runtime
override remains a deliberate active-wave choice. No foreign checkout/ref moves.

Requested primary checks are discoverable and wired with independent terminal
proofs: selection state has minimum 9 checks; actual two-window recovery has
minimum 13 and requires Windows Chromium. Absent dependency files or unsupported
platform are explicit counted skips in a producer tree, never inferred passes.
The final combined integration candidate must contain and execute these fixtures.
Focused UI admission includes them when available; missing/unsupported critical
integration coverage falls back to complete verification. The additional wiring
and review fixes need new exact-tree verification and cannot reuse bootstrap 214.

The exact held tip `dcf49653` is also a semantic merge parent, so closure can prove
its ancestry without force-deleting an unmerged ref. Conflict decisions preserve
current supervisor delegation, health-free JSON lifetime ownership, short queue
locks, durable-path proof, and explicit operator resume. Obsolete status-based
preflight/automatic watcher start are superseded; they would call the node being
served and retain recycled-PID uncertainty. The held lifetime/start/dedupe intent
and its useful classifier/pending-preservation tests remain. Unknown inventory
now refuses instead of preserving the held test's old silent malformed-record
skip. Per-conflict decisions are archived in `throughput-held-semantic-decisions.json`.

Final follow-up proof preserves tested directory/head separately from receipt
storage owner/candidate head; an identical-tree reuse never rewrites the original
execution provenance. Combined receipts can be found after clone removal through
`owner_repo`, while `tested_repo` still names where the actual source ran.

Actual public finish check/gate/admit, delivery evaluation/admission and merged
candidate entry now call the registered wave admission guard before execution or
mutation. Shared registration is resolved from real Git common-dir, no alternate
store or fresh automatic bootstrap. A registered missing/unreadable module is a
refusal; unregistered legacy/isolated bootstrap is explicitly unverified. The
convergence-owned helper controls freeze/baseline and bounded continuation. A
private eight-check fixture drives the real hot entrypoints under registered
freeze. Wave scripts (including wave-observe.lua) and their literal relative dependency closure ship beside
the sentinel, and verification compares shipped wave files to accepted source.
Dynamic source references continue to use the recorded canonical runtime tree.

The immutable primary `a991d9f` is a dependency merge parent in this producer
branch, so new selection/two-window fixtures are runnable here rather than absent
placeholders. Selection proof passed 9 checks and embedded two-window proof 13
with source primary's matching compiled artifact; sentinel inventory suite passed
35 Rust tests and real ownership/inventory fixture 29 checks. Source root update
refusals passed 35 checks. Focused log validator, mutation/default-command and
wave/canonical shipping fixtures are reported separately; final modified combined
source still requires its own full gate before publication/deployment. Bootstrap
214 is historical foundation proof, not a receipt for these later changes.

Delivery tip steering now uses supported `delivery-record.mjs refresh` with the
exact old expected tip, exact newly published descendant tip and existing
producer. It uses the store's revision/snapshot CAS, preserves complete prior
review/admission/failed-lane/check history, and clears stale current evidence.
An immutable published landing cannot be refreshed into another delivery.
The private published-record fixture passes 10 checks; production records are
not manually overwritten. Wave monitor/shipping and closure adapters use the
shared full-proof validator and original tested-directory provenance.
