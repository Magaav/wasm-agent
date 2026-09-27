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
returns every new message, without silently skipping a busy interval. `message`
requires an idempotency key and creates a follow-up run in the same session,
copying the admitted profile, model and limits. An active predecessor settles
before that follow-up acquires a worker. An unknown predecessor blocks it.
Ordinary `/chat` refuses child sessions, preventing profile loss through that path.

Direct messages currently queue after the active run, rather than interrupting a
tool or steering mid-step. Parent attribution is retained; the parent can inspect
the conversation and latest child result. This slice does not automatically wake
a settled parent after a child result. The showroom polls durable messages and a
live model-text preview; an interrupted preview is not durable transcript evidence.

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
