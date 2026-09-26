# Execution foundation: plan, evidence and staged roadmap

Status: the exact-fork slice is implemented on `change/exact-session-fork`; this is not a claim that the full multi-agent milestone or deployment acceptance is complete.

## Audit and chosen slice

Implemented: per-conversation admission/order/cancellation and reserved interactive workers (`rust/wa-host/src/serve/scheduler.rs`); per-run output/reconnect tails; durable native subagents with separate child sessions, bounded capacity, cancellation, owner checks and restart-unknown outcomes; transcript-backed recovery; explicit session worktree bindings; authorized signed peer execution. Existing proof includes `scripts/test-run-isolation.sh`, `scripts/test-subagents.cjs`, `scripts/test-peer-run-admission.cjs`, recovery fixtures and `scripts/test-ui.ps1` (hermetic/runtime fixtures, not deployed proof). See `docs/CONCURRENCY.md`, `docs/SUBAGENTS.md`, `docs/MEMORY.md`, and `docs/release/ORCHESTRATION_ROLLOUT.md` for exact boundaries.

Missing: first-class fork from an explicit historical boundary; automatic isolated workspace allocation/state capture; durable cross-process ordinary-run admission and event replay; coordinated locks for shared resources; integrated/restart/UI evidence on one candidate. Existing session workspace binding is explicit; unbound sessions share the node cwd. Subagent parentage is not conversational fork ancestry.

This concern adds authenticated conversation forks at explicit message sequence boundaries. Fork ancestry is separate metadata from subagent parentage. Only complete tool exchanges may end a fork; copied evidence excludes summaries and future messages, while a new branch starts with empty summary/watermark. Source rows remain untouched. The fork has no inherited writable workspace. File/external effects are not rolled back.

## Acceptance checklist

- [x] Fork requires explicit existing source session and message sequence.
- [x] Authorization checks source ownership; tool-call/result exchanges cannot be split.
- [x] Copies only non-summary source messages through the selected boundary; source is unchanged; child summary is empty.
- [x] Records parent session/sequence separately from subagent linkage; no workspace inheritance.
- [x] Existing sessions migrate additively; malformed/missing boundaries fail visibly.
- [x] Targeted tests cover fork, tool boundary, compacted-summary exclusion, retention/deletion, ownership and workspace non-inheritance (`14 checks`).
- [x] Run smoke/regression and targeted scheduler/two-node fixtures; evidence is below. UI, deployed and two-node fixture proof are distinguished.
- [ ] Re-sync, prove mergeability, commit with provenance, push and complete finish procedure.

## Foundation contract

Identity stays layered: principal + node authorize a session; session owns ordered runs; a fork is a new session with immutable `(source session, source sequence)` ancestry; a delegated subagent remains a separate child task/session linked through existing parent-task machinery; operations/workers are runtime resources, not conversation identities. Rust host owns native worker lifetime/admission; Lua owns agent policy. A future Wasm executor must satisfy the same contract.

Forking copies selected immutable transcript evidence into an independently writable conversation; it does not fork/rollback a workspace, operation, browser state or external effect. Summary rows are not ancestry input. Exact tool-call/result pairs are atomic boundary units. Retention must preserve referenced ancestry or report source unavailable; this implementation's copied rows preserve the selected text independently of source retention. Existing session ordering and subagent scheduling remain authoritative. Recovery distinguishes terminal outcomes from unknown effects and reconciles before retry.

## Roadmap

### A. Reliable local sessions, branching, delegation, ownership and recovery
- Outcome: concurrent conversations, exact forks, bounded children, isolated workspaces and attributable recovery.
- Dependencies: scheduler, durable transcript, authentication, subagent runtime, worktree allocator, resource coordination.
- Acceptance: adversarial isolation/fork/order/cancel/restart/authorization tests; independent workspace writes; verified child-result consumption; unknown effects never blindly replayed.
- Status: scheduling, subagents, transcript recovery and explicit worktree binding implemented with targeted fixture proof; exact fork implemented here. Automatic allocation, durable ordinary-run claims/event log, resource locks, and combined acceptance remain planned/unproven.
- Risks: node-local SQLite/artifacts; uncertain provider/effect windows; native shell is not sandboxed; retention.

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
| Run isolation + scheduling | runtime fixture | `bash scripts/test-run-isolation.sh` -> exit 0; streams, ordering, lanes, auth and cancellation; counts in retained gate output | `C:\\Users\\Victor\\AppData\\Local\\Temp\\pi-bash-7ea7c56f5fdb1bcd.log` |
| Authorized peer execution | two-node runtime fixture | `node scripts/test-peer-run-admission.cjs rust/target/release/wa.exe` -> exit 0, 43 checks, 0 skips; two isolated destination nodes/local relay/mock inference | same retained command output; script-created fixture records |
| Repository smoke/regression | hermetic + local fixture services | `RUST_TEST_THREADS=1 CARGO_BUILD_JOBS=2 node skills/parallel-evolution/scripts/finish.mjs gate <repo> 02df01807f1d2b563a62264ac1b60a649e40c71d` -> gate verified, exit 0, 1 skip; UI structure/mid-run reload/startup recovery passed; one Windows process-environment inspection skip | `C:\\Users\\Victor\\orca\\projects\\wasm-agent\\.git\\worktrees\\generalson-2\\wa-finish-gate.json.log` |
| Concurrency-sensitive gate observation | hermetic | An initial unbounded `finish.mjs gate` attempt exited 101: one wa-operation test hit Windows `PermissionDenied` (code 5); the test passed in isolation, and the serialized whole gate above passed. The initial failure is retained as a risk; the serial pass does not erase it. | Initial gate command output; final machine verdict/log above |
| UI reconnect | runtime fixture | UI invoked by smoke and passed structure, mid-run reload and startup recovery; not a new UI change | same retained gate log |
| Earlier pre-commit smoke | hermetic | exit 0, `smoke ok (2 skipped)`; deploy-downgrade also skipped because tree was dirty; superseded by final post-commit run above | `C:\\Users\\Victor\\AppData\\Local\\Temp\\pi-bash-7ea7c56f5fdb1bcd.log` |
| Installed/deployed candidate | deployed | pending; gate/authorization required | pending |
| Luna follow-up inside wasm-agent | runtime/deployed | blocked pending installed candidate/deployment authorization and model selection | pending |
