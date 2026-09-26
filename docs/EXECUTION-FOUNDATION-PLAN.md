# Execution foundation: plan, evidence and staged roadmap

Status: exact conversational forks are on `origin/main`. This change auto-allocates and durably binds isolated git worktrees for forks and write-capable delegated children. It does not complete the multi-agent milestone or deployment/adoption acceptance.

## Audit and chosen slice

Implemented: per-conversation admission/order/cancellation and reserved interactive workers (`rust/wa-host/src/serve/scheduler.rs`); per-run output/reconnect tails; durable native subagents with separate child sessions, bounded capacity, cancellation, owner checks and restart-unknown outcomes; transcript-backed recovery; explicit session worktree bindings; authorized signed peer execution. Existing proof includes `scripts/test-run-isolation.sh`, `scripts/test-subagents.cjs`, `scripts/test-peer-run-admission.cjs`, recovery fixtures and `scripts/test-ui.ps1` (hermetic/runtime fixtures, not deployed proof). See `docs/CONCURRENCY.md`, `docs/SUBAGENTS.md`, `docs/MEMORY.md`, and `docs/release/ORCHESTRATION_ROLLOUT.md` for exact boundaries.

Missing: durable cross-process ordinary-run admission/event replay; comprehensive recovery reconciliation; coordinated locks for shared resources; automatic workspace reaping; integrated UI/deployed evidence on one candidate. Existing ordinary sessions remain compatible and unbound unless explicitly allocated. Allocated workspaces are node-local git worktrees, not a filesystem sandbox or cross-node shared checkout. Subagent parentage remains distinct from conversational fork ancestry.

Exact forks use explicit message boundaries, separate ancestry metadata, complete tool exchanges, copied non-summary evidence and no later context. This change then binds each fork to a newly allocated worktree before reporting success. Write-capable delegated profiles are bound before native child admission. Both reuse `sessions.worktree` and preserve source HEAD/branch/status. Dirty sources are explicitly recorded and refused; failed required bindings block writes rather than falling back to node cwd. Ordinary legacy sessions and read-only children remain unchanged. Filesystem/external effects are never rolled back.

## Acceptance checklist

- [x] Fork requires explicit existing source session and message sequence.
- [x] Authorization checks source ownership; tool-call/result exchanges cannot be split.
- [x] Copies only non-summary source messages through the selected boundary; source is unchanged; child summary is empty.
- [x] Records parent session/sequence separately from subagent linkage; no workspace inheritance.
- [x] Existing sessions migrate additively; malformed/missing boundaries fail visibly.
- [x] Targeted tests cover fork, tool boundary, compacted-summary exclusion, retention/deletion, ownership and workspace non-inheritance (`14 checks`).
- [x] Workspace allocation records source HEAD/branch/status; dirty/unavailable source failures are visible and write fallback is blocked (`scripts/test-session-workspaces.lua`).
- [x] Concurrent delegated coding children write the same relative path into distinct worktrees; cancelling one leaves the sibling's binding/effect intact (`scripts/test-subagents-integration.lua`).
- [x] Two simultaneous local processes write independently, and a fresh process resolves persisted bindings (`scripts/test-session-workspaces.cjs`).
- [x] Cross-owner allocation and worktree control are denied in the fixture.
- [ ] Smoke/regression and finish gate pass with skips and retained evidence.
- [x] Re-sync, prove mergeability, commit with provenance, push, run the finish check and verify the finish gate on the exact commit.

## Foundation contract

Identity stays layered: principal + node authorize a session; session owns ordered runs; a fork is a new session with immutable `(source session, source sequence)` ancestry; a delegated subagent remains a separate child task/session linked through existing parent-task machinery; operations/workers are runtime resources, not conversation identities. Rust host owns native worker lifetime/admission; Lua owns agent policy. A future Wasm executor must satisfy the same contract.

Forking copies selected immutable transcript evidence into an independently writable conversation; it does not fork/rollback a workspace, operation, browser state or external effect. Summary rows are not ancestry input. Exact tool-call/result pairs are atomic boundary units. Retention must preserve referenced ancestry or report source unavailable; this implementation's copied rows preserve the selected text independently of source retention. Existing session ordering and subagent scheduling remain authoritative. Recovery distinguishes terminal outcomes from unknown effects and reconciles before retry.

## Roadmap

### A. Reliable local sessions, branching, delegation, ownership and recovery
- Outcome: concurrent conversations, exact forks, bounded children, isolated workspaces and attributable recovery.
- Dependencies: scheduler, durable transcript, authentication, subagent runtime, worktree allocator, resource coordination.
- Acceptance: adversarial isolation/fork/order/cancel/restart/authorization tests; independent workspace writes; verified child-result consumption; unknown effects never blindly replayed.
- Status: scheduling, subagents, transcript recovery, exact forks, explicit worktree binding, and automatic local git worktrees for fork/write-capable child sessions have targeted fixture proof. Durable ordinary-run claims/event log, automatic cleanup, resource locks, comprehensive recovery reconciliation, full UI/deployed proof and combined acceptance remain unproven.
- Risks: git worktrees share an object store and can accumulate; dirty source changes are refused rather than transferred; interrupted allocation can remain unknown; arbitrary shell is not a sandbox; node-local paths/artifacts do not provide cross-node workspace portability.

### B. Multi-agent UI and daily development through wasm-agent
- Outcome: inspect, redirect, fork, cancel and recover work without changing output destination.
- Dependencies: stable owner-scoped execution APIs/events and isolated workspaces.
- Acceptance: reconnect/dedup/order under concurrent runs; UI reconnect tests; daily development task completes implementation, verification and repository delivery with interventions recorded.
- Status: session view, child controls and run replay exist; task board and workflow planned. In-agent follow-up is pending installed candidate/model authorization.
- Risks: reconnect uses durable transcript plus bounded in-memory tail; restart loses transient tail; full redesign deferred.

### C. Authorized remote placement and resource-aware admission
- Outcome: explicitly place work on eligible nodes without changing selected model or required context.
- Dependencies: authenticated peer fabric, capability/resource declarations, evidence replication and budgets.
- Acceptance: real authorized two-node task with attribution, target binding, denial/revocation, resource evidence and uncertainty reconciliation.
- Status: signed remote execution/relay exist with fixture proof; comprehensive placement and deployed proof planned.
- Risks: partitions, secrets/context locality; no new distributed scheduler here.

### D. Interchangeable native/Lua and Wasm execution backends
- Outcome: same policy contract on native and Wasm workers with attributable outcomes.
- Dependencies: stable host capability/WIT contract, conformance suite, resource/cancellation semantics.
- Acceptance: backend conformance on identity, ordering, authority, cancellation, output/evidence and restart uncertainty; equivalent authorized fixture effects.
- Status: Rust host + Lua policy is current; Wasm backend planned.
- Risks: sandbox and capability semantics; no wholesale Pi/runtime rewrite.

## Criteria for replacing Pi as primary environment

Compare a predeclared representative task set under equivalent models/context: verified completion rate; human interventions per verified task; continuity after reconnect/restart; recovery correctness and explicit-unknown rate; latency distributions; model/resource usage. Require repeated runs, uncertainty intervals, no safety/isolation regression and human-approved thresholds. Agent count, one success, anecdotal speed or lower tokens alone are insufficient.

## Evidence ledger

| Proof | Type | Command / result | Evidence |
|---|---|---|---|
| Exact fork + authorization/retention | hermetic | `WASM_AGENT_HOME=<scratch> WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=<repo>/scripts/test-session-fork.lua rust/target/release/wa --db <scratch>` -> exit 0, 14 checks | `scripts/test-session-fork.lua`; local command output |
| Automatic session workspaces | local runtime fixture | `node scripts/test-session-workspaces.cjs rust/target/release/wa.exe` -> exit 0; real temporary Git repos/worktrees, 23 Lua contract assertions plus 10 harness assertions, independent writes, dirty/unavailable fail-closed, HTTP fork endpoint and fresh-process persistence; no inference | `scripts/test-session-workspaces.lua`, `scripts/test-session-workspaces-verify.lua`, `scripts/test-session-workspace-worker.lua`; CJS fixture output |
| Delegated coding workspace and cancellation isolation | local runtime fixture | `node scripts/test-subagents.cjs rust/target/release/wa.exe` -> exit 0, 18 checks; mock inference only, sibling child writes survive cancellation of another child | `scripts/test-subagents-integration.lua`; `C:\\Users\\Victor\\AppData\\Local\\Temp\\wa-subagents-G4Cvbl` (fixture retained) |
| Run isolation + scheduling | runtime fixture | `bash scripts/test-run-isolation.sh` -> exit 0; streams, ordering, lanes, auth and cancellation; counts in retained gate output | `C:\\Users\\Victor\\AppData\\Local\\Temp\\pi-bash-7ea7c56f5fdb1bcd.log` |
| Authorized peer execution | two-node runtime fixture | `node scripts/test-peer-run-admission.cjs rust/target/release/wa.exe` -> exit 0, 43 checks, 0 skips; two isolated destination nodes/local relay/mock inference | same retained command output; script-created fixture records |
| Previous integration candidate smoke/regression | hermetic + local fixture services | `RUST_TEST_THREADS=1 CARGO_BUILD_JOBS=2 node skills/parallel-evolution/scripts/finish.mjs gate <repo> <exact pushed HEAD>` -> gate verified, exit 0, 1 skip; UI structure/mid-run reload/startup recovery passed; one Windows process-environment inspection skip. This predates the current workspace change. | `C:\\Users\\Victor\\orca\\projects\\wasm-agent\\.git\\worktrees\\generalson-2\\wa-finish-gate.json.log` |
| Startup regression comparison and fix | two-node runtime fixture + controlled binary probe | On current `origin/main` `5f59561116908296f3d66fb4dd9584d4caf938f9`, freshly built baseline binaries (wa SHA256 `646020a996022ef65bca5a1a95397bb0182bb20ca90ff8b647a8b83f8635eb8c`, sentinel `3f58fb3ccc8661dd15b02703bd9590f0a817dc73326a41b67957b9076d09bbb7`) passed the hardened fixture: 62 checks, 1 platform skip. On pre-fix workspace candidate `eeac0d95404723f5c80ed5f1957dea5c22f40fab`, a foreground wa probe using the installed candidate binary (SHA256 `bafdbc87c1e80f8d4c428be32e9a8c4d6a7192337f1c86babb1ee14bdfb18478`) emitted `embedded module missing: lua/core/workspaces.lua`; `rust/wa-host/src/main.rs` had omitted the new Lua module from the embedded registry, so detached nodes exited before HTTP startup. After adding it, the same fixture passed on both baseline and fixed-candidate binaries (candidate wa SHA256 `ea762aaf3b956b2908faaef5e24c90e27db596ef81a9f71f4cb67fd637d768d3`; 62 checks, 1 documented skip each). A failure-injection run with the pre-fix binary failed the startup checks, marked 29 downstream checks skipped, retained sentinel output and the node stderr probe; it did not falsely pass dependent assertions. | baseline verdict `/tmp/wa-node-startup-baseline-final.json`; fixed candidate verdict `/tmp/wa-node-startup-candidate-final.json`; failure artifacts `/tmp/wa-node-instance-failure-injection` and `/tmp/wa-node-instance-failure-injection.verdict.json`; pre-fix output `/tmp/wa-node-start-diagnostic-candidate/foreground.stderr` |
| Repository smoke/regression before commit | hermetic + local fixture services | `RUST_TEST_THREADS=1 CARGO_BUILD_JOBS=2 bash scripts/test.sh` -> `ALL PASS`; node instances 62 checks/1 skip; smoke 2 skipped. Deploy-downgrade check explicitly skipped because this worktree was dirty. This is working-tree evidence, not yet the final committed finish gate. | `C:\\Users\\Victor\\AppData\\Local\\Temp\\pi-bash-c9d507be95493903.log`; node verdict included in retained output |
| Concurrency-sensitive gate observation | hermetic | An initial unbounded `finish.mjs gate` attempt exited 101: one wa-operation test hit Windows `PermissionDenied` (code 5); the test passed in isolation, and the serialized whole gate above passed. The initial failure is retained as a risk; the serial pass does not erase it. | Initial gate command output; final machine verdict/log above |
| UI reconnect | runtime fixture | UI invoked by smoke and passed structure, mid-run reload and startup recovery; not a new UI change | same retained gate log |
| Earlier pre-commit smoke | hermetic | exit 0, `smoke ok (2 skipped)`; deploy-downgrade also skipped because tree was dirty; superseded by final post-commit run above | `C:\\Users\\Victor\\AppData\\Local\\Temp\\pi-bash-7ea7c56f5fdb1bcd.log` |
| Installed/deployed candidate | deployed | pending; gate/authorization required | pending |
| Luna follow-up inside wasm-agent | runtime/deployed | blocked pending installed candidate/deployment authorization and model selection | pending |
