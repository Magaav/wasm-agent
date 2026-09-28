# Orchestrator workspace

The topbar Orchestrator control opens a separate native view window (a browser
window outside the companion). The current chat remains the coordinator. The
left sidebar lists delegated sessions; pinning opens their conversations in the
main canvas, with four panes forming a 2×2 grid. Expansion, collapse and window
closure are presentation operations and never cancel work. Layout and drafts
are local to the authenticated window account; execution is node-owned.

## Instructions and envelope

Operator conversations load the applicable project `AGENTS.md` plus
`AGENTS.orchestrator.md`. Children load `AGENTS.subagents.md` plus their approved
profile and mandatory boundary instructions. Guests retain the guest boundary
and receive neither operator execution-role file. Execution role grants no tools.

Role-file resolution is explicit `WASM_AGENT_AGENTS_MD_ORCHESTRATOR` or
`WASM_AGENT_AGENTS_MD_SUBAGENTS`, then the named file in the working directory,
then config, then the embedded default. A missing explicit override fails visibly.
Files are re-read when constructing context. No memory is automatically injected.

Both prompts now use the same tool-index builder. Authored tool cues, complete
schemas, project instructions, profile restrictions and original transcript
content remain intact. The child event accumulator was only used for its length;
it is now a counter, with events forwarded to the child's live preview. Neither
change reduces model context or establishes a measured cost/quality improvement.

## Placement

`POST /subagents` action `placement` reads or saves an operator's policy:

```json
{"action":"placement","policy":{"enabled":true,"nodes":[
  {"node":"<preferred cloud node id>","max_tasks":2},
  {"node":"<second cloud node id>","max_tasks":2},
  {"node":"local","max_tasks":0}
]}}
```

Policy is disabled until configured. Order is strict; zero excludes a device.
The limit caps admitted background child tasks and can narrow, never raise, the
destination's `WASM_AGENT_SUBAGENT_MAX_CONCURRENT` runtime ceiling. It is not a
RAM allocation or an OS-enforced resource quota. Resource samples remain advisory.
Only explicit `node_full`/`queue_full`/runtime-unavailable admission refusals
permit moving to the next candidate. An unavailable discovery entry is skipped
before sending; an uncertain request pins the destination and idempotency key.

The SQLite queue is bounded at 128 pending placements per owner. A serve-owned
worker calls Lua placement policy every two seconds, independently of browsers.
The destination's native admission lock reserves capacity, preventing concurrent
dispatchers from both taking the last slot. Local authority is rechecked before
dispatch; remote calls use the existing signed, target-bound peer capability path.
Managed guest nodes do not acquire an autonomous inference capability.

Queued work persists across restarts. A destination is recorded before dispatch;
an uncertain delivery retries only that destination with the same child key.
The destination recovers interrupted children as unknown and never reruns their
effects automatically. Unknown remote delivery cannot honestly be cancelled
until admission is reconciled. The UI reports uncertainty rather than success.

## Conversations

`start`, `status`, `result`, `await`, `cancel`, `list`, `profiles` remain on the
existing subagent facade. `fleet` reads placement and node inventory. `session`
reads original child messages; `before_seq` pages older records and `after_seq`
returns bounded earliest-unseen pages with `next_after_seq`, without silently
skipping a busy interval. See [bounded inspection](SUBAGENTS.md#bounded-explicit-inspection).
`message`
requires an idempotency key and creates a follow-up run in the same session,
copying the admitted profile, model and limits. An active predecessor settles
before that follow-up acquires a worker. An unknown predecessor blocks it.
Ordinary `/chat` refuses child sessions, preventing profile loss through that path.

### Live steering

`steer` targets a child; `steer_session` targets an owned main session.
`steering_status` reads receipts. A request needs an idempotency key and can carry
an expected `run_id`. Owner checks precede lookup and dispatch; remote callers
must name a child, not an arbitrary session. The inbox and its run identity are
durable. Only the active run consumes the original text into its own transcript,
atomically with its read receipt, before the next model call. Pending steering
fences each sequential/parallel tool admission. After admission an effect is
in-flight: steering cannot undo it. Read means entered context, not obedience.
Unread messages at settlement or boot mismatch are deferred, never replayed.

Main chat exposes **Steer** / Ctrl+Enter while busy; plain Enter keeps the draft
and Stop remains explicit. Child panes distinguish **Send** (follow-up) from
**Steer** (active run). Drafts clear only after an accepted receipt. Cards expose
model and reasoning, with unknown values labeled rather than guessed. Links are
blue-ish and underlined; executable URL schemes are refused.

### Completion return

New delegated tasks register a durable owner/parent-scoped completion outbox.
The serve-owned tick observes settlement (including failure/unknown) without a
browser, then enqueues one background coordinator continuation through the normal
same-session scheduler, not loopback HTTP. Child text is not promoted to authority:
the notice names the result to inspect and grants no merge/deploy permission.
A wake interrupted after admission is unknown and is not replayed. Capacity
refusals proven not started remain ready. Existing historical tasks are not
backfilled. The outbox is node-local; remote destinations retain their original
records and the coordinator observes them through the signed facade.

Set `WASM_AGENT_COMPLETION_WAKE=0` to pause automatic completion delivery;
the durable watching/ready rows remain for later inspection or resumption.
Task `status`/`result` includes its latest `completion` delivery state, distinct
from the child's execution state; failed/unknown delivery is not hidden as success.

Risk: automatic return spends coordinator inference and may queue behind active
user work. It does not interrupt that run or claim task verification. Authority
is rechecked at both observation and execution. The coordinator instructions
bound feedback to one deduplicated improvement task and one review; this is an
instruction policy, not a native semantic classifier of feedback requests.
The showroom polls durable messages and bounded live model/tool preview every
two seconds. Tool starts are visible before results; active runs are expanded by
default, with reader folds and scroll position preserved across refreshes. Each
pane has `chat-content-run-status`, an elapsed clock, and per-balloon duration
footers. Final durations come from stored message timing, not time since repaint.
`start.title` supplies a short task heading; legacy tasks use a bounded prompt
fallback, while profile/model/reasoning remain secondary details. Interrupted
preview is not durable transcript evidence. Very short tools between polls may
appear directly as completed transcript rows rather than an observed running state.

## Scope and risks

Remote workers need their own provider access, approved profiles and source
checkout. Placement does not copy credentials, worktrees or uncommitted files.
Signed peer authorization follows the existing fabric's trust model; this is not
new customer enrollment or a cross-node filesystem sandbox. Slow remote status
reads can delay a fleet refresh; errors remain visible. No migration of an active
process, distributed RAM, wake-word detector or voice adapter is included here.

The standalone Drift panel is retired. Read-only replication diagnostics remain
under Engine → nodes, and the underlying sync API is retained.

Verification: `scripts/test-orchestrator.cjs` uses two actual isolated node
processes, a local rendezvous and mock inference. It covers priority/overflow,
queueing, idempotency, session/profile preservation and coordinator restart.
Native subagent tests cover atomic capacity reservation and foreign-owner denial;
`scripts/test-ui.ps1` covers the external-window request and real DOM layout.
These are fixture proofs, not deployment or paid-model acceptance.
