# Concurrent execution and automation rollout

Status: **in progress; not deployed or claimed complete**.

## Baseline (2026-09-21)

- Integration origin/main: `d485a51`.
- Existing deployed node source record: `60eaa29` (WhatsApp persistence lineage).
- Existing telemetry branch: `95b1c26`.
- `change/orchestration-baseline` merges both existing lines from main, without moving
  either other owner's worktree. The combined merge was clean.
- Live inspection before work: node `/health` answered, no active run/queue/operation;
  client connected. No deployment or browser mutation was performed for baseline.
- The first baseline `bash scripts/test.sh` observation timed out at 300 seconds.
  Its retained log ends in an MSYS fork resource failure in `check-naming.sh`.
  Earlier emitted suite verdicts are evidence only for those suites; there is no
  successful whole-gate verdict. Log: operator temp `wa-orchestration-baseline-gate.log`.

## Landed baseline corrections

- Main `5e22062`: shared, hashed, expiring, node-bound authentication sessions replace
  interpreter-local tokens. Unknown nonempty credentials no longer fall back to master.
  This is **not** remote password authentication; absent credentials retain the existing
  trusted-local behavior. `node scripts/test-auth-sessions.cjs` passes 22 independent-process
  checks, zero inference/skips.
- Main `e3ac17a`: fixture exit status and terminal verdict are both required; a printed
  success followed by exit 1 fails. `node scripts/test-fixture-verdict.cjs`: 15 checks,
  zero skips, including real exit-after-verdict mutations.
- `CARGO_BUILD_JOBS=2 RUST_TEST_THREADS=1 bash scripts/test.sh` at `e3ac17a`:
  exit 0, `smoke ok`, no skips. Retained log: operator temp
  `wa-gate-terminal-evidence.log`. This is a baseline gate, **not** an integrated-feature gate.
  Earlier unrestricted parallel operation tests had timing failures under load; those
  failures are not erased by the serialized rerun.
- `scripts/test-orchestration-e2e.cjs` is an acceptance harness under development, not
  wired into the passing baseline gate. Its first negative baseline run exited 1 on
  `POST /subagents` HTTP 404. Evidence: operator temp `wa-orchestration-e2e-syNJZx`.
  It now also requires real sentinel artifact/import/delivery execution; that extension
  awaits the runtime before its first execution.

## Integration review status

Only the baseline corrections above are accepted on main. Candidate automation and
instance implementations have targeted passing tests but **failed coordinator review**
for untested boundary cases. Corrections are in progress:

- Durable child admission must propagate persistence errors, use the selected node home,
  enforce empty tool ceilings, and interrupt silent provider I/O on cancellation.
- Send effects need an atomic durable reservation before any external effect; missing or
  ambiguous completion must not become permission to retry. A child `unknown` result
  must not settle its Delivery as completed.
- Group mentions must be actual verified mentions, not arbitrary matching digits;
  malformed archived/left metadata must fail closed.
- Corrupt instance registries, protected environment overrides, overlapping homes/ports,
  and weak legacy PID-only lifecycle proof require explicit refusals and mutation tests.
- The two-node candidate reports one Windows environment-inspection skip. Its skip must
  propagate to the parent gate, not disappear into a bare `smoke ok` verdict.

Read-only live readiness observation: WhatsApp's existing page/store was reachable via
`[::1]:9222` (Chrome 153, hook present); IPv4 returned 404. No chats were opened, no
composer modified, and no message sent by this observation. It is **not** a live proof.

## Stages and ownership

1. Canonical terminology and contracts: `ARCHITECTURE.md`, `docs/EXECUTION.md`.
2. Session scheduling, admission, streaming and session-scoped UI: isolated run-isolation change.
3. Durable bounded local subagents, profiles, enforced tools: isolated local-subagents change.
4. Portable artifacts and deterministic WhatsApp/send pipeline: isolated portable-automation change.
5. Co-located node configuration and supervisor ownership: isolated node-instances change.
6. Integrated review, regression gate, deployment and real two-session plus WhatsApp proof.

Stages 2-5 have non-overlapping implementation ownership. Shared interfaces are agreed
before integration. Each change must be committed/pushed and its merge checked; no
worker deploys or mutates the live WhatsApp account. The integrator owns live proof.

## Acceptance evidence ledger

| Requirement | Fixture proof | Deployed/live proof |
| --- | --- | --- |
| Canonical naming and distinct ownership | 45 terminology checks; documentation only, runtime ownership pending | pending |
| Parallel sessions, isolated streams/transcripts | pending | pending |
| Same-session atomic ordering and authorization | pending | pending |
| Background saturation preserves two interactive sessions | pending | pending |
| Subagent spawn/result/cancel/limits/restart ambiguity | pending | pending |
| Capability and cross-user/node denials | pending | pending |
| Portable jobs disabled until local approval | pending | pending |
| Deterministic WhatsApp eligibility and bounded context | pending | pending |
| Exact send verification, draft/unread protection, ambiguity | pending | pending |
| Independent co-located node lifecycle | pending | pending |
| UI observability, correct session busy/cancel | pending | pending |
| Full regression gate with counted skips | baseline `e3ac17a`: exit 0, no skips; integrated gate pending | n/a |
| Verified installed version / hashes | n/a | pending |

Populate with commands, test counts, exit codes and retained evidence paths as work
lands. Do not replace `pending` with a qualitative claim. A passed fixture cannot fill
a live-proof cell. A blocked requirement stays blocked and names the external dependency.
