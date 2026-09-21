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
| Canonical naming and distinct ownership | pending | pending |
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
| Full regression gate with counted skips | pending | n/a |
| Verified installed version / hashes | n/a | pending |

Populate with commands, test counts, exit codes and retained evidence paths as work
lands. Do not replace `pending` with a qualitative claim. A passed fixture cannot fill
a live-proof cell. A blocked requirement stays blocked and names the external dependency.
