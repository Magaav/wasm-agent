# Orchestrator workspace

The topbar Orchestrator control opens a separate native view window (a browser
window outside the companion). The current chat remains the coordinator. The
left sidebar creates cards only for active delegated sessions; pinning opens their conversations in the
main canvas, with four panes forming a 2×2 grid. Expansion, collapse and window
closure are presentation operations and never cancel work. Layout and drafts
are local to the authenticated window account; execution is node-owned.

## Active-only cards

Cards require a positive `running`, `accepted`, `queued` or `placing` task state
and no terminal settlement. Completed/failed/cancelled/refused/unknown records
remain in history but create no card or lane group. The live-child list uses the
same filter; a recordless child needs an actual current health run, not merely
an unfinished ledger or retained worktree. Unknown effects remain unknown in
Engine → Sessions; filtering never settles, cancels, deletes or replays them.
Only active cards are restored as panes on window startup. Already-open panes,
promoted windows and unsent drafts remain until explicitly closed; their task
status continues updating after settlement. Existing polling is unchanged.

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

## Native worker admission

Delegate all workers through this node's native `subagent` facade. The main
Orchestrator registry must own and control the task and expose its transcript,
status and controls. Authorized configured placement and node limits still apply;
a placed child remains owned and supervised through that facade, not a separate
worker registry. Preserve the explicitly approved profile, model and reasoning;
admission failure never authorizes silent substitution.

On an actual admission failure:

1. Preserve the original refusal/receipt, transcript and any allocated worktree.
   Report the failed step and whether admission proved nothing started or the
   outcome is uncertain. Reconcile uncertainty through the facade before retrying;
   do not claim a refused task launched.
2. Diagnose within authorized, visible read-only scope when appropriate. A
   read-only profile is not a writing bypass. Report missing capabilities or
   dependencies and repair the authorized native route only within granted scope;
   otherwise report the blocker and required repair rather than launching elsewhere.
3. Never relax ownership, copy another identity or hide a registry to bypass the
   refusal. Do not start separate wasm-agent bootstraps, candidate inference
   processes, isolated registries, Orca, Pi CLI or another external runtime as a
   delegated-worker workaround. Retired scratch launchers stay retired; preserve
   archived originals, do not reuse them.
4. After authorized repair, use the native facade and inspect its task receipt and
   main-registry transcript/status/control evidence. Accepted or launched is not
   completed; inspect settlement and results before reporting completion, and keep
   independent verification distinct from a worker's claim. Registry visibility
   does not prove what the user's window rendered; do not claim screenshot proof
   without actually observing it.

This boundary concerns worker delegation, not private deterministic mock-fixture
subprocesses, builds or headless UI checks. Those checks are not substitute workers
and do not prove live worker admission or user-window visibility.

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
Only explicit `node_full`/`queue_full`/runtime-unavailable admission refusals, and a destination
that has no usable checkout of its own, permit moving to the next candidate. An unavailable discovery
entry is skipped before sending; an unobserved delivery keeps its destination and key for
`reconcile` and is not sent again until that answer arrives.

A destination's answer decides the attempt in four ways, and the difference is what it *proved*:

* **admitted** — a receipt with a subagent id: a run exists there.
* **spilled** — a refusal that proves nothing was started and that another candidate may still take
  (capacity, runtime unavailable, or no checkout on that node). The pin is dropped, so the next tick
  re-reads eligibility: removing a node from the policy stops it being tried. These are exactly the
  refusals that keep the child session a refused attempt created, for the retry to reuse.
* **refused** — a refusal that proves nothing was started and that no candidate can be asked to take
  as it stands. The attempt *ends* (`refused`, with the answer on the row), the coordinator is woken
  to decide, and `cancel` retracts it without a reconciliation it does not need. Measured before this
  rule: a destination that answered `workspace_session_not_found` was re-dispatched every ~2.5s for
  minutes, and every attempt wrote another empty, already-ended session shell on the node that had
  just refused it.
* **uncertain** — nothing is proved: the request may or may not have arrived, so re-sending it could
  start a second child for one task. The row is **parked** (`unknown`), keeping the destination and
  the key; `cancel` refuses until the outcome is known, because a child may be running there.

### Admission refusal versus an unobserved delivery

An unobserved delivery is not retried. `subagent` action `reconcile` asks the pinned destination the
only question that decides it — `{"action":"resolve","idempotency_key":<the task's key>}` — which the
runtime answers from its durable records under the same lock admission takes, so a request still in
flight there is waited for rather than raced:

* a run exists there → the dispatch adopts its receipt and is supervised; nothing was re-sent;
* nothing was admitted there → the row returns to the queue (pin dropped) and may be placed again,
  because the destination proved that key was never started;
* no answer (destination unreachable, or a runtime that cannot answer) → the row stays `unknown` with
  that failure recorded, and nothing is retried.

Every attempt is counted on the receipt (`attempts`), so "it keeps retrying" is a number an operator
reads rather than a pattern a log reader has to infer. Capacity refusals are not capped: each of them
proved that nothing was started and left no effect behind, and all-full work stays durably queued
(asserted by the two-node fixture). Nothing else loops at all.

### One shell per request, not one per attempt

A request the destination refuses must not add a durable effect, because the coordinator may ask
again. Two things enforce it: a refusal the destination can decide by reading — a source it does not
have, a parent workspace that is not allocated — is refused *before* the child's session exists; and
the child session of a request that carries an idempotency key is named by that key, so the next
attempt reuses the first attempt's session and its checkout instead of writing another. Measured
before this rule: one empty, already-ended session shell — and one git worktree — per retry, ~840 in
forty minutes on a node that answered `workspace_allocation_failed`.

Residual, stated because it is not free: while a dispatch is unresolved, the node that refused it
holds that one reusable session (it becomes the child's own thread if that node is asked again and
admits). Nothing reaps it if the task is finished elsewhere, because the destination cannot see the
coordinator's queue. A refusal that ends the request retires its shell instead.

### A placed child's source

A destination never forks a child from a path another machine recorded: `C:/Users/.../wasm_the_first`
is the coordinator's checkout and means nothing on a Linux node. The source is the tree the
*destination's* node runs from (`runtime-worktree.txt`, else its working directory when that is a
checkout) — the same thing a local child gets — and the session records both it (`source_origin`) and
what the incoming session named (`source_requested`, with `source_fallback` saying why it was left
alone). A path recorded by a session of another node is never used, even when that same path exists
here, because one path on two machines is two different repositories; a path that names nothing here
falls back to this node's checkout; a path that is here and is not a checkout is refused.

A node with no usable checkout of its own refuses with `workspace_destination_source_missing`, naming
what is missing on both sides, and does so *before* it creates the child's session, so a refusing node
is left holding no session shell. It also refuses in place of a session: the child's workspace record
is written `failed`, never left `pending` for a dispatcher to read as "not finished yet".

The SQLite queue is bounded at 128 pending placements per owner. A serve-owned
worker calls Lua placement policy every two seconds, independently of browsers.
The destination's native admission lock reserves capacity, preventing concurrent
dispatchers from both taking the last slot. Local authority is rechecked before
dispatch; remote calls use the existing signed, target-bound peer capability path.
Managed guest nodes do not acquire an autonomous inference capability.

Queued work persists across restarts. A destination is recorded before dispatch;
an unobserved delivery is parked and reconciled rather than retried, and the same
child key is never active twice: the destination's runtime deduplicates an admitted
key, and a key that was never admitted resolves to nothing. The destination recovers
interrupted children as unknown and never reruns their effects automatically. The UI
reports uncertainty rather than success.

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
fences each *effectful* tool admission, sequentially or in parallel: a read-only
call has no effect to undo, so it runs and the steering is delivered with its
results rather than costing the batch a whole model round. After admission an
effect is in-flight: steering cannot undo it. A tool this file does not list as
read-only keeps the fence. The first fenced call of a batch carries the
instruction to re-issue what remains valid; the rest carry the bare code, because
the transcript needs one result per call id. Read means entered context, not
obedience. Unread messages at settlement or boot mismatch are deferred, never
replayed.

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
