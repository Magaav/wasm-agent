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
