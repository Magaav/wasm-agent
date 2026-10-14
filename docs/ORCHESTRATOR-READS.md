# Why one child can exhaust orchestration reads

`503 read_capacity_busy` counts concurrent read/control HTTP requests, **not
subagents**. `serve.rs::choose_node_thread` reserves one independent destination
before enqueue; the default reserve is two (`WASM_AGENT_CONTROL_WORKERS`). Runs
have separate capacity. `/health` and `/version` are listener-owned, while
`POST /subagents` (including read actions), `/sessions`, `/me`, and `/models`
share the read/control reserve. A slow catalogue or a long subagent await can
occupy a slot even with only one child running. Increasing that reserve would
hide fan-out, not make the window lighter.

## Source findings and controlled reproduction

Before this patch the orchestration view skipped initial chat boot, but still
started `watch()` and `watchTurn()`: version recovery then called `/me`, restored
the invisible main transcript, looked up its native task, and fetched model
metadata. The component separately refreshed every two seconds.

Other multiplicative reads:

- Every pin/restore/promote/collapse layout refreshed **all** panes, outside the
  workspace's single-flight flag. A simultaneous poll could read the same pane.
- `paneMessages` fetched the newest page twice when older history existed, then
  used `Promise.all` for every oversized original row. One transcript could
  issue more concurrent reads than the two available destinations.
- A native refresh loaded full history before attachment, attachment loaded it
  again, and the first checkpoint loaded it again. Every refresh restarted its
  journal at zero; long history and tails repeated all page/exact-row work.
- Fleet configuration was fetched on every poll; failures and idle/hidden panes
  used the same two-second cadence.

A real-Chromium staged test allows one read at a time, representing another
caller occupying one of the default two slots. The original source reaches peak
2 concurrent reads and 3 self-inflicted overload refusals in the pin/poll fixture;
its actual component startup also fails the no-hidden-chat-reads assertion.
The patched source reaches peak 1 with zero self-inflicted refusals. This proves
the browser's causal fan-out, not the exact holder during the operator's original
incident. A single live `/health` sample showed both read threads idle; no
historical request trace identified that incident's slot holder.

## Repaired behavior

The component owns its recovery. Main chat/model watchers do not run behind
component-only views; the version/shell heartbeat still runs. Main chat and the
inspector keep their normal recovery.

Read-only orchestration requests share one promise chain, with an eight-second
request deadline. Explicit message/steer/cancel/placement controls bypass it and
are never retried by that chain. Pane refresh is single-flight; restoration and
layout changes do not duplicate existing refreshes. Original oversized messages
are retrieved sequentially, never summarized, dropped, or rewritten.

Native panes cache validated rows/checkpoint/tail by full node/account/task/
attempt/event identity and request only events after the last validated cursor.
Checkpoint changes reload complete original ledger history. Identity, sequence,
checkpoint regression and incomplete cursor errors refuse without replacing the
last confirmed view. Failed refreshes back off (4/8/16/30 seconds), retain drafts
and loaded output, and name the error. A new attempt resets old backoff/cursors.
Terminal journal storage gaps retain the existing explicit stored-message fallback.

A steady visible running native pane now uses four requests per poll: list,
sessions, health, events (three read/control destinations, **sequential**, plus
listener-owned health). There are zero history/placement requests in an unchanged
poll. Fleet configuration is sampled every 30 seconds or explicit Refresh;
settled panes sample their journal at most every 30 seconds. Workspace polls use
2 seconds active, 10 seconds idle, 15 seconds hidden, up to 30 seconds on failure;
focus/visibility and explicit Refresh reconcile immediately. Refresh also clears
pane caches so deliberate ledger repairs can be reread.

Risks/limits: serial original loading can take longer on first attachment; other
windows or long controls can still saturate capacity. Fleet changes made elsewhere
can take 30 seconds to appear. Cached running ledger repairs without a new native
checkpoint need explicit Refresh; no durable history is changed. `/sessions`
still returns its bounded latest 50-session list, and task discovery still reads
recorded history; no claim of constant backend cost for arbitrarily large history.
Promoted panes have separate render caches, but their network reads serialize.
Tail event storage is retained until checkpoint, not truncated for a memory claim.
No measured production CPU/GPU/power improvement or freedom from all overload.

## Server admission: short collisions

The browser repair above did not repair server admission. `choose_node_thread`
refused immediately if both reserved read/control destinations were occupied.
Two windows' individually serialized reads can overlap: one long control plus
one ordinary local read leaves a third follow read refused, even with **zero
model runs**. Also, the response is written before `node_thread_loop` clears its
busy label, so a client's completion-to-next-read edge is not itself a server
release fence. A per-window promise chain cannot guarantee global availability.

A private real-node barrier fixture proves the causal case: two occupied read
slots, a follow event request, and one holder released shortly afterwards. The
unchanged source returns `503 read_capacity_busy`; the candidate waits and serves
that same request with the same two interpreters. This is an admission-policy
bug, not evidence that one child consumes the read pool. It does not identify the
original incident's exact slot holders; no live window or node was instrumented.

Read/control admission now has one bounded FIFO dispatcher separate from both the
listener and run/resolver admission. Destination release wakes it via a condition
variable, not a polling thread or per-request timer. Queue residence and waiting
share one deadline. Expired waiting requests never enter Lua; a full queue or
sustained saturation keeps the exact visible `read_capacity_busy` refusal. Runs
remain isolated, authentication/ownership is unchanged, and no request is replayed.

- `WASM_AGENT_READ_ADMISSION_MS`: default 250 ms, clamped to 1–1000 ms.
- `WASM_AGENT_READ_QUEUE_DEPTH`: default 16 waiting sockets, clamped to 1–256,
  plus the single dispatcher-held request. No extra Lua interpreter capacity.
- `/health.read_admission`: `waiting` (pending admission, including dispatcher),
  `queue_depth`, and `timeout_ms`. Existing health fields are unchanged.

Risk: a sustained collision is reported up to one admission budget later; FIFO
head-of-line waiting can spend a later request's budget. These knobs bound local
admission, not slow Lua/provider/database work, interpreter construction, OS
scheduling or socket writes. Health/assets and run status/cancellation stay off
this FIFO. The 250 ms default is a small-burst allowance, not a production latency
SLA or proof that arbitrary overload can never occur.

`node scripts/test-read-admission.cjs <candidate-wa> <fresh-evidence> [baseline-wa]`
and its `--post` mode retain source/binary/log hashes. It checks baseline refusal,
short-collision success, default budget, bounded queue/deadline, responsive health,
no expired Lua entry, 128 serial follow reads with another slot still held, recovery
and actual owned-process exit. The initial controlled sample served the short
collision in 39 ms, sustained overload in 264 ms, and all 128 follow reads returned
200 (maximum 18 ms); these are fixture samples, not production throughput claims.
The existing four-phase background responsiveness proof and 27 focused Rust serve
checks also pass. The unchanged staged orchestration browser proof passes 28 checks
with peak one read and zero self-inflicted refusals.

Self-review only; no installed UI/configuration writes, deployment or full release
gate. The full native two-window recovery check hit the same encoded child-session
`unknown_session` failure on both baseline and candidate (`query_value` does not
URL-decode `%3A`); that separate main-chat child path was not changed. The explicit
`--interactive-only` two-window run passed 22 checks, with its one native-child
check group reported as skipped. Do not call that skipped path verified by the
staged browser fixture.

## Verification

`node scripts/test-orchestrator-reads.cjs <fresh-evidence>` and the same with
`--post` retain staged source/DOM/screenshot hashes. Twenty-eight browser checks,
zero skips: actual view startup, pin/poll single-flight, exact oversized rows,
steady request count/cursor, incremental/multi-page tails, checkpoint reload and
regression, foreign identity refusal, promotion, visible overload/backoff/recovery,
draft retention, control bypass, terminal freshness, new-attempt reset and cadence.
The unchanged original source fails both startup and contention assertions.
`scripts/test-ui.ps1` includes this proof plus the existing main/child, recovery,
native journal, inspector, component-view and styling suites. A pre-existing
null phase-clock guard surfaced by the serialized schedule is also fixed: two
absent keys must not authorize dereferencing a missing active phase.

Self-review only. No server capacity/auth changes, inference, deployment, installed
UI writes, full release gate, or claim that the original live incident was captured.
