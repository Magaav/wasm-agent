# Sentinel bootstrap checkpoint (coordinator only)

Base: 898a9a238c89c5f64b83cfa219f8c17840b441f9.
Owned branch: change/wa-session-childdispatch40f63603-1bc4-4a48-9812-12a1055151be.

## Immediate answer

`WA_DEPLOY_ROOT` chooses the BUILD TREE, not the executable deploy script. The sentinel resolves `WA_SENTINEL_DEPLOY` first, then scripts beside its own executable, then cwd. Neither variable is a request field; setting it on the request-writing CLI does NOT change an already-running watcher's environment. The installed script does not exec the canonical script after resolving ROOT. Therefore `WA_DEPLOY_ROOT=<canonical> wa-sentinel request deploy` alone is NOT a stale-script recovery procedure.

Private fixture PASSED using the actual installed wa-sentinel.exe (SHA in adjacent JSON). With WA_SENTINEL_DEPLOY pointing at canonical scripts/deploy.sh, the installed handler invoked that exact script; the retained WASM_AGENT_IN_TURN=1 guard refused before install. Its done receipt said ok/detached while deploy-result said false. A negative control pointing at a stale stub, with identical WA_DEPLOY_ROOT, invoked the stale stub. This proves script selection and acceptance != completion, not a successful install and not the live watcher's environment.

## Read-only diagnosis

Installed record: commit/branch/dirty unknown, source hint e2a86bc50d5db5b8882aee4c8daf2d403c2e0a7f, unverified-binary, final via upgrade.sh, at 2026-10-02T23:02:02Z. Deploy verdict remains false from probe at 20:33:12Z, before the installed record. Existing deploy.out shows node pid 9356 was replaced, sentinel pid 2904 -> 2004, then installed deploy.sh line 572 `-n: command not found` and line 574 syntax error near `done`. This is partial installation, NOT verified deploy completion. It is consistent with the documented running-script overwrite failure; logs alone do not prove the precise byte-write race. Original files were only read; fixture-stub lines already present in that live capture were preserved and are not successful-install evidence.

## Exact conditional bootstrap procedure

Only coordinator may execute outside all node turns, after review/landing. No hand copy, no marker removal, no job/config edits, no effect replay:

1. Pin the intended landed SHA S and canonical checkout R. Verify clean R, `git -C R rev-parse HEAD` equals S, S is on origin/main, deployed target/port ownership, no pending/claimed deploy or unsettled prior effect. Preserve original receipts/logs. Refuse if source changes during preparation; existing deploy has no exact-SHA request field, so coordinator must reserve/freeze R through its source reads.
2. If independently verified running watcher ALREADY has `WA_SENTINEL_DEPLOY=R/scripts/deploy.sh` and `WA_DEPLOY_ROOT=R`, queue exactly once using the installed CLI:
   `wa-sentinel.exe request deploy --if-no-pending --session <parent-id> --prompt "Sentinel deploy returned; reconcile request and deploy verdict against exact SHA S, then verify install. A launch receipt is not completion; do not retry effects." --reason "authorized canonical bootstrap S"`
   Save the returned request path/id. This is queued, NOT sentinel acceptance. Existing protocol has no five-second accepted handshake. Read request/claimed/done/failed and deploy.out; absence is unknown/stale, never replay automatically.
3. If the live watcher environment cannot be proved or selects stale script, STOP: no safe existing request-only bootstrap was proved. Coordinator's sanctioned fallback, if its authority permits an outside-run direct deploy, is `WA_DEPLOY_ROOT=R bash R/scripts/deploy.sh --require-main --session <parent-id> --prompt <same verification prompt> --reason "authorized canonical bootstrap S"`. This executes canonical script directly, not stale install. It intentionally restarts node/sentinel as deploy does; this lane DID NOT execute it. Do not launch from a tool turn, detach from a turn, strip WASM_AGENT_IN_TURN, or start a second watcher on the live box. If coordinator must use ONLY the existing watcher with unknown environment, recovery is BLOCKED pending explicit supervisor bootstrap authority.
4. After actual outcome, run canonical `bash R/scripts/verify-install.sh --json` with correct install target. Require verdict ok, source commit S, clean-built-by-deploy/final provenance, fresh successful deploy-result at or after installed record, matching built/installed node+sentinel+shipped scripts, listener pid identity and live watcher. Preserve failure/outcome evidence and investigate named refusal. Only then say `I am updated`. No-op upgrade must not launder unknown provenance; final alone is insufficient.

## Deferred protocol contract (not implemented)

Cross-component persistent protocol needs coordinator review before implementation, not half a live state:

- Request is durable exact intent `{id, verb, requested_sha, session, reason}`; strict parser/backcompat, no new arbitrary command field. Validate SHA before any effect and again before install; do not schedule unrelated SHA.
- Sentinel emits durable acceptance `{id, phase:accepted, at, requested_sha}` or named rejection within five seconds policy, even while busy. CLI queue acknowledgement is distinct. Missing acceptance is stale/unknown and requires read-only reconciliation, never replay.
- Persistent per-id settlement states: queued/accepted/held/spawned/verified/failed/unknown. Spawn receipt never verified. Survive watcher replacement; attribute result to request id+SHA, require valid timestamps and artifact/script proofs. Exit zero alone cannot establish installation.
- Engine onSentinelReturn consumes acceptance/outcome idempotently, injects fixed operating instructions and evidence only, queues parent wake even busy, no provider call in hook. Ack queues a check; updating queues a ten-second follow-up policy. Actual outcome triggers verification, not automatic deployment. Terminal unknown/failure preserves evidence and reports cause/regression. No onSubagentReturn enabling or notifications.
- Focused tests needed: busy acceptance, named malformed/rejected intent, missing ack, restart between spawn and settlement, stale/global result rejected, wrong SHA, missing timestamps fail closed, duplicate return no replay, busy parent durable wake, failure followed by verification, no provider invocation. Engine/operation lanes own overlapping infrastructure; implementation deferred rather than modifying their contracts without coordination.

## Delivery limitations

Added only reusable private fixture and evidence/report; no production protocol patch. Installed executable tested in a new private process, not running watcher. Fixture guard refusal proves canonical invocation but intentionally does not build/install. No live deploy, restart, installed edit, marker stripping, remote push, provider call, notification, or operation-index mutation. Full finish gate may refuse unpublished branch by policy; no remote push is authorized. Coordinator must independently review and gate combined tree.
