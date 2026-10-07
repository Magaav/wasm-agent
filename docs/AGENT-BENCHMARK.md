# Agent benchmark: current readiness and next experiment

2026-10-07; preparation, not a completed coding comparison.

## Existing components and actual limits

- Skill: `skills/agent-benchmark/SKILL.md` (Agent Skills layout, not agent-benchmark.md).
- Paired container runner: `scripts/agent-benchmark.mjs`.
- Trace adapter: `scripts/agent-benchmark-report.py`.
- Frozen historical fixture: `benchmarks/agent-benchmark/ui-diff-topic.json`.
- Offline accounting: `scripts/audit-tokens.cjs`, `docs/OBSERVABILITY.md`,
  `docs/TOKEN_EFFICIENCY.md`. Native spans record model/tool/run latency, usage,
  retries and summary attempts; Pi JSONL records its messages, tools and usage.
- Docker daemon answered27.3.1 during preparation; no benchmark launched.

We have the measurement substrate, NOT a ready Luna three-runtime experiment:

1. The paired runner currently accepts only `scripts/test-ui.ps1` and its historical
   oracle verdict. It copies only UI into the grading tree. A non-UI adapter is needed.
2. Its fixed proxy is OpenCode Go chat completions. It does not implement a shared,
   isolated Luna subscription Responses route. The navigation experiment supports
   `openai-sub`, but runs wasm-agent variants, not a Pi arm, and is not a substitute.
3. One image supplies one wasm runtime. `wasm-graph` changes instructions, not binary
   source. Current and patched runtime images/revisions need separate pins; the task
   checkout must stay identical. Pin the current baseline before any treatment.
4. The old trace reporter sums missing fields as zero, can report Pi's catalogue
   zero cost as actual cost, omits summary accounting, and does not distinguish an
   oracle-pass-at-timeout from finished handoff. Reuse the stricter offline auditor
   for wasm and add equivalent Pi completeness validation before ranking anything.
5. Record exact package/model/reasoning/provider and image/native/Lua/script hashes.
   Trace telemetry, not configured defaults, must confirm `gpt-6-luna` / `medium`
   for all three; no fallback model or route. Shared transport must be proven before
   calibration. Credentials/gold fixes stay inaccessible to solvers.

These gaps are documented, not silently fixed by launching ad hoc runtimes or
weakening the network fence. No new scheduler, watcher, factory or full gate.

## Latest Pi, not the historical0.87.1

The npm stable `latest` tag for `@earendil-works/pi-coding-agent` was1.0.4 on
2026-10-07; engines require Node>=22.19.0. Package integrity:
`sha512-+956nfMFHr5lDUVY/2Q4k+YzojzBuCaBXFgj0eSlXVGr7QVliVddKdc1Pz6yVg1dOlJQmb67doOVrlMsIcIdaw==`.
Resolve latest again immediately before calibration, pin the exact version and
integrity, build the disposable image with `--build-arg PI_VERSION=<resolved>`,
and verify the package manifest inside it. Do not install globally or upgrade the
live subscription adapter merely to benchmark. Keep that exact version fixed
through the wave; do not let an unpinned `@latest` change halfway through.
Version discovery is not proof of CLI/adapter compatibility or model entitlement.

## Safe artifact discovery

Do not recurse over benchmark roots: retained `worktrees/` contain full repositories
and many SKILL.md files. For known artifacts inspect only immediate run directories
and their exact `manifest.json`, `report.json`, `summary.json` and
`three-lane-summary.json` names using the skill's `scripts/artifacts.mjs`.
It reads no report bodies, returns relative addresses/byte sizes, distinguishes
missing reports from no matching runs, bounds JSON to8KiB by default and carries
metadata-snapshot continuation. A filesystem error is an error, not absence.
Scope prefix/root explicitly; follow pages or narrow the query rather than clipping.
Metadata continuity is an inventory check, not a content snapshot or security sandbox.
The fixture oracle deliberately walks no unrelated historical worktrees.

## Proposed main fixture: telemetry-empty-payload

Descriptor: `benchmarks/agent-benchmark/telemetry-empty-payload.json`.
Status: **candidate-awaiting-pi-qualification**, not the new default yet.

Real historical defect at task source `9fa1ae552d96d5f54f97a3c857035246a7d69d1d`:
a fieldless Lua table becomes `[]`, while the offline JavaScript auditor accepts
only object payloads and aborts on a genuine export. Fix the normalization boundary,
not every consumer; accept decoded and serialized empty arrays while still rejecting
nonempty arrays/null/primitives/malformed JSON. Unknown inference usage/cost must
remain unknown, duplicate/span validation must remain strict, and input must not
change. Add focused regression tests. No service, browser or Cargo build is needed.

Why this fixture:
- realistic self-maintenance bug, compact diagnosis/repair/test flow;
- existing Node/stdlib implementation, no new dependency or architectural rewrite;
- tests simplification without asking the model to minimize lines;
- exact behavioral outcomes and deceptive easy repair (“accept every array”);
- portable fast checks rather than the old UI snapshot's missing component and
  PowerShell requirements;
- enough related source/tests/docs to reveal navigation/model-round overhead.

All arms receive the same four-file historical task snapshot and no gold history,
plus identical documented task requirements. Build harness runtimes from their
own pinned modern sources, NOT from that historical task source. The checked-in
oracle/descriptor/known repair are outside solver exports/mounts and network access.
A focused snapshot is deliberate: it measures a small repair, not full-repo navigation.
Do not put the instruction treatment in the task checkout or export this experiment
plan to a solver. Report unavoidable harness instruction/schema differences.

Model-free preflight proved: broken source fails; minimal known normalization repair
passes28 oracle checks; permissive accept-all-arrays mutant fails; current source
passes. The oracle also runs the existing historical regressions and the real CLI,
checks duplicate identity, reversed spans, missing accounting and unchanged input.
It checks behavior, not textual resemblance. This is scorer validation, not agent success.

**Duration is an unverified5–10-minute target.** Latest Pi/Luna-medium must first
finish normally, pass the hidden oracle and existing regressions, and leave a scoped
diff within that window. If it is trivial (<5min), too slow (>10min), or fails,
reassess the fixture before promotion; never relabel a timeout patch as completion.
The separate qualification run is not counted in the comparative results. Keep
qualification failures visible to avoid presenting a Pi-selected fixture as a
representative task distribution. The small fix may be too easy: one model-free
repair is not a Pi calibration and must not be called one.

## Rollout after the execution restriction is explicitly lifted

The active direct-workflow rule forbids subagents/external inference agents. Current
preparation executes no Pi or wasm solver. An authorized future benchmark needs a
scoped exception for these isolated solver processes, not general re-enabled delegation.

1. Fix/test the adapter, accounting completeness, exact-runtime selection, latest-Pi
   compatibility and credential-isolated shared Luna route above. No provider calls
   until transport/model/reasoning pins and the experimental budget are explicit.
2. Run one Pi qualification only. Promote the candidate only after actual5–10min,
   normal completion, hidden acceptance and diff review. Freeze prompt/source/oracle.
3. Run a baseline triad: latest Pi, pinned current wasm, wasm candidate1. Same task,
   model, medium reasoning, external data, execution resources and test facilities.
   Run solvers serially/counterbalance order to avoid upstream/CPU contention. Fresh
   homes do not prove cold provider caches; record actual cache observations.
4. Up to4 wasm treatments, changed separately, only while trace evidence justifies it:
   - candidate1: explicit independent-read/check batching and scoped discovery;
   - candidate2: understand/reuse/root-cause/minimal-change guidance, without one-liner
     pressure, restricted testing, or the whole Ponytail prompt;
   - candidate3: opt-in evidence locator only if traces show retrieval is the remaining
     bottleneck; exact originals, surrounding reads and missed-caveat controls;
   - candidate4: one targeted repair justified by prior outcomes, not automatic scope.
   These are hypotheses, not existing patches. Stop once success/efficiency meets the
   predeclared criterion or no credible bottleneck remains. Do not build an index
   merely to fill an iteration number.
5. Selection pilots can use one fresh attempt per arm/treatment. Freeze the chosen
   candidate and confirm with at least3 interleaved attempts per arm on this fixture
   and a held-out small-fix task. Do not select and certify on the same lucky run.
   Each treatment triad includes a fresh current/Pi control; preserve all earlier runs.
6. Proposed experimental cap:15min/attempt, plus predeclared attempt/output/quota
   limits before inference. A complete4-pilot-plus-confirmation design is1 qualification
   +12 pilot +9 confirmation attempts (22 total, <=330 solver-min at that cap).
   This is a proposed upper bound, not authorization or an expected duration. Pilot
   budgeting does not add caps to the production agent loop. No automatic retries.

## Measurements and upfront predictions

Primary: verified completion rate and sum of ALL attempt resources divided by verified
completions; zero completions gives no finite efficiency score. A passing snapshot at
an experimental timeout is reported separately from normal finished delivery.
Track wall-to-finish, model/summary calls and time, tool calls/batches/time/errors,
first edit/test, uncached/cache-read/cache-write input, output/reasoning (subset),
retries, compaction, human help/rework and unintended diff/dependency scope. Keep
build/index/oracle/setup overhead separately and include it in end-to-end totals.
Under subscription, dollars and quota burn remain unknown unless actually measured;
never call absent/zero catalogue prices free. CPU overlap is not implied by tool counts.
Keep source/diff, JSONL/SQLite, raw outputs, oracle/exit/cleanup and accounting receipts.

Predeclared hypotheses, NOT estimates from completed trials:
- Worth a bounded pilot: yes. Existing tooling means we need adapters, not a new
  experiment platform; batching has a concrete historical mechanism.
- candidate1 vs current: target>=15% fewer model exchanges and>=10% lower median
  verified-completion latency, without lower acceptance or lost evidence. Could be
  near-zero if the current loop already batches well. This fixture is not log-heavy.
- candidate2: may reduce exploratory edits/unnecessary abstractions; no guaranteed
  token saving. Target no new dependencies/unrelated changes and same acceptance.
- candidate3: unlikely to repay an index on this small fixture; defer unless measured
  retrieval dominates. Include indexing overhead and a late-caveat negative case.
- Pi latest may improve over its2026-09 sample. No predicted winner or promise of
  general superiority.3 repeats are diagnostic confirmation, not statistical proof.

Do not promote a permanent runtime default from one task or marketing byte/LOC figures.
