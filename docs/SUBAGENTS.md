# Local subagents

The [orchestrator workspace](ORCHESTRATOR-WORKSPACE.md) extends this facade with
ordered remote placement and direct follow-up messages in the same child session.
Original local profile and ownership restrictions remain authoritative.

A **subagent** is a supervised child task with its own fresh context and its own
execution state. It runs a child *run*, in a child *session*, and is owned by a
parent run or job delivery. It is not a job (an automation definition), not an
operation (an external process) and not a run in the parent's session. The
canonical definitions are in `ARCHITECTURE.md` §6 and `docs/EXECUTION.md`; this
file specifies the local implementation.

## The seam: Rust owns lifetime, Lua owns policy

| Concern | Owner | Where |
| --- | --- | --- |
| OS thread, capacity, cancellation flag, deadline, durable record, `await` | Rust | `rust/wa-host/src/subagents.rs` |
| Profile, tool allow-list, prompt, budgets, ownership derivation, child loop | Lua | `lua/core/subagents.lua`, `lua/core/agent.lua` |
| Lease on the provider call | Rust (deadline) + Lua (between steps) | `host.http*` reads the thread-local task context |

Rust never decides what a child may do; Lua never owns a thread or a record. A
child is run by a fresh, registered interpreter factory (`subagents::set_factory`
in `main.rs`), not by reusing the serve interpreter and never by `/chat`.

## Host and Lua API

```
host.subagent(action, args_json) -> JSON
  start    -> durable launch receipt {subagent_id, state:"accepted", settled:false,
              session_id, queue_position, profile, depth, note}
  status   -> one task view (owner-scoped)
  list     -> {subagents:[...]} for the caller (owner-scoped)
  result   -> terminal view with result, or the non-settled view
  await    -> bounded native wait; terminal view, or the still-running view
  cancel   -> a request; the view is not necessarily settled yet
  self     -> {cancelled, cancel_requested, deadline_exceeded} for the child thread
  resolve  -> the child an idempotency key already owns, without a second run
```

The Lua facade is one entrypoint used by every caller:

```
wa_subagents(body, auth_session) -> JSON     -- HTTP control (`POST /subagents`)
subagents.control(args, ctx)                  -- the `subagent` tool and jobs
wa_subagent_run(receipt_json) -> JSON         -- the child entrypoint (never model-callable)
```

`ctx` is built by the server. **No owner, depth or allowed-tool list is read from
a request body.** The HTTP facade resolves the user from the authenticated session
and the node's role (`nodes.is_master()`); the tool path passes the running
agent's `(user_id, role, session_id, run_id, node_id)`.

### Route and health wiring (owned by whoever edits `serve.rs`)

- Add `"/subagents"` to the independent control routes (`is_read_route`), like
  `/jobs` and `/operation`, so inspecting or cancelling a child never queues
  behind the run it is inspecting.
- Dispatch: `POST /subagents` → `wa_subagents(body, session)`; `GET /subagents`
  → `wa_subagents("{}", session)`.
- `/health` should include `subagents: crate::subagents::health()` (active tasks,
  owners, states, capacity; no prompts or transcripts).

## Profiles

The Engine's **tasks** panel lists owner-scoped children with their objectives,
parent conversations, state and result. **New child task** starts work using an
approved profile and the selected model. Retrying an unanswered submission uses
the same idempotency key while the form is unchanged. Switching conversations
does not cancel any work. Cancellation targets one child or ordinary run.

Interrupted ordinary runs appear as `unknown`; queued requests recovered before
execution appear as `not_started`. Inspect the preserved request and paginated
output before deciding whether to continue. This panel controls the local node;
remote placement remains a separate capability. Run discovery covers the recent
conversations returned by the sessions endpoint, not an unbounded history search.

The sessions transcript offers **Fork here** at an explicit message boundary.
The server refuses incomplete tool exchanges and workspace allocation failures.
Fork ancestry is separate from delegated parentage; neither forks nor cancellation
roll back files or external effects.

Profiles are local approved JSON files at `<config>/subagent-profiles/<id>.json`
(`config` is `host.paths().config`, i.e. `~/.wasm-agent`). Built-ins live in Lua
and cannot be broad: `explore` (read-only) and `guest` (its own memory only).
There is no duplicate database source of truth.

```json
{
  "schema_version": 1,
  "id": "worker",
  "description": "A bounded task that may edit files and run a shell.",
  "operator_authorized": true,
  "instructions": "Do the task you were given, then stop.",
  "allowed_tools": ["read", "read_many", "grep", "ls", "diagnose", "write", "edit", "bash"],
  "resources": {},
  "limits": {
    "max_depth": 0,
    "timeout_seconds": 900,
    "max_output_bytes": 131072,
    "max_tokens": 400000,
    "max_cost_usd": 0.50
  }
}
```

Rules, each enforced in `lua/core/subagents.lua`:

- **`allowed_tools` is exact.** Filtered into the schema the child is offered
  (`tools.all_for`) *and* re-checked in `tools.dispatch`; a tool the model asks
  for but the profile did not name is `capability_not_in_profile`.
- **A profile can only narrow.** Every allowed tool must be in the *caller's* own
  schema list, or the start is refused (`profile_exceeds_caller:<tool>`). A guest
  cannot name a profile that reads files, runs a shell or reaches the network.
- **Broad tools need an operator.** A profile naming `bash`, `shell`, `client`,
  `remote`, `write`, `edit`, `spell_save`, `spell_run` or `spell_export` must set
  `operator_authorized: true`; otherwise the start is refused
  (`profile_not_authorized:<tool>`). `worker` is never a default.
- **No recursion.** `subagent` is refused inside a child profile, and a child
  context cannot call the facade at all. Nesting depth defaults to 1: children do
  not spawn children.
- **Cost fails closed.** `max_cost_usd` requires known model rates; an unpriceable
  model refuses the start (`cost_budget_requires_rates`) rather than pretending a
  dollar bound.
- **Model/reasoning inherit by default.** An override must already equal the
  caller's model, be listed in the profile's `approved_models`, or appear in
  `WASM_AGENT_SUBAGENT_MODELS`; a reasoning level must be one the model supports.
  The override applies to the child interpreter only and is never persisted.

General operator profiles have no implicit cumulative token/cost cap. Omit
`max_tokens` / `max_cost_usd` for unlimited; explicit numeric limits (including
zero as a zero-spend ceiling) remain enforced. Specialist/guest limits are not
removed. `profiles` exposes declared and effective model approvals, reasoning
choices, defaults and budget semantics without granting new approvals.

Subscription inference has a separate 3600s request safety deadline rather than
the 300s shell default. `WASM_AGENT_SUBSCRIPTION_TIMEOUT` overrides it (1–86400s),
then `WASM_AGENT_LLM_TIMEOUT` for compatibility. Child task deadlines and cancellation
still apply. Risk: a hung provider can occupy capacity longer; explicit deadlines
and cancellation remain available. No failed call or external effect is auto-replayed.

## Context, transcripts and budgets

- A child gets a **fresh, lean context**: the mandatory boundary rules, the
  profile instructions, the environment, its exact tool list and its budgets. It
  never receives the parent transcript, automatic memory, skills it was not
  allowed, or the operator instruction file (`AGENTS.md`). The boundary rules are
  not optional and cannot be removed by a profile.
- A child writes to its **own session** (`sessions.parent_session_id` links it to
  the parent). The parent transcript is never written by a child; `ensure_session`
  excludes child sessions so a normal turn cannot land in one.
- Budgets (`timeout_seconds`, `max_tokens`, `max_cost_usd`, `max_output_bytes`)
  are enforced in the child loop and by the runtime's deadline. Before admission,
  the initial system prompt, tool schemas and bounded task/context use the same
  first-call token estimator; when that estimate alone exhausts `max_tokens`,
  start refuses with the estimate and limit, before a child session or provider call.
  Child compaction reserves estimated summary input plus maximum output against
  the same per-run token/cost caps before inference, charging the full reservation
  even when usage is missing. This conservative reservation is not provider billing.
  Original rows survive; a valid checkpoint is required before advancing coverage.
  Later context growth and provider usage remain subject to the child-loop check;
  an estimate is not a tokenizer guarantee. Output over the byte budget is
  truncated with a visible marker; token/cost overruns stop with a named error.
- Runaway guard exhaustion preserves its incomplete assistant draft, settles the child as
  `failed` with the stable error `runaway_guard`, and carries that reason into the parent's
  completion notice. A normal final answer remains `completed`; cancellation remains `cancelled`.

### Bounded explicit inspection

`subagent session` and the `session` tool default to the newest eight messages
within a 16,000-byte encoded page. `limit`, `byte_limit`, and `view` are explicit
inspection controls, not changes to the child's model context. Rows always remain
chronological. `next_before_seq` traverses older evidence; child incremental
reads use `after_seq` and `next_after_seq` to return the earliest unseen rows,
never skipping a middle page. Oversized rows carry an `evidence` address for
owner-checked `message_id` / `byte_offset` / `message_version` exact JSON retrieval.
No transcript is summarized, deleted or rewritten by inspection.

## Scheduling, waiting and recovery

- The runtime has a **separate bounded pool**: `WASM_AGENT_SUBAGENT_CONCURRENCY`
  (default 2) executing children, plus `WASM_AGENT_SUBAGENT_QUEUE_DEPTH` (default
  6) admitted-but-waiting. Over that, `start` refuses with `queue_full`: an
  explicit refusal, never invisible loss. Child inference therefore cannot consume
  a reserved interactive HTTP worker.
- `await` is **one bounded native wait** on a condition variable; it never makes
  the model poll. A caller waits on its own worker while the child runs on the
  subagent pool, so a parent waiting for a child does not hold the capacity that
  runs the child. Because children do not spawn children by default, there is no
  nested-wait deadlock.
- **A child session has one writer, durably.** A `message` continues *its* child's
  session: the new task chains to the tail (`after_id`) and waits for that task to
  settle before it takes an execution slot, so a queued follow-up inherits the
  session's transcript by design and never runs beside its predecessor. The chain
  is additionally checked against the durable records, not only against this
  process's map: an unsettled task in the same session that this process cannot
  account for - a second process sharing the runtime home whose successor was
  admitted after this process read the records - refuses the second writer with
  `session_tail_unobserved:<subagent_id>` instead of sharing the session. The
  refusal names the occupant and is retryable once that task settles; a fresh
  child, which gets its own session, is unaffected. The check reads the records of
  this runtime home on a continuation, so its cost grows with the number of stored
  child records.
- Cancellation is a **request** until settlement. The cancel flag is read by the
  provider reader at each streamed chunk (a native effect on I/O), and the child
  loop checks it between steps. A cancel that arrives while the provider is quiet
  lands at the next chunk or at the child's deadline.
- A `running`/`accepted` record left by another boot reads `unknown`, with no
  replay. Durable records live at `<data>/subagents/<id>/record.json`; the record
  keeps the resolved spec and the terminal result, but is never injected into
  model context.

## Lifetime, CLI and exits

The registered factory builds a fresh interpreter for both serve and ordinary CLI
runs. A factory that fails to load its modules prints the error and continues, so
a spawned child settles as `failed` instead of taking the process (and its
siblings) down. A CLI process that exits while children are running leaves their
records in `running`; the next process reads them as `unknown`, never as success
and never as an automatic retry.

## Tests

- `cargo test --manifest-path rust/Cargo.toml -p wa-host subagents::` — durable receipt, idempotency under a
  simultaneous-start barrier, owner scoping, capacity/overflow, cancel-wins-label,
  restart-unknown, corrupt-record quarantine, the strict health shape and
  socket-shutdown wakeup.
- `node scripts/test-subagents-policy.cjs [wa-binary]` — isolated profile
  validation (including empty `allowed_tools` and malformed/negative limits),
  caller clamping, the empty-ceiling rule, operator authorization, schema/dispatch
  parity, the durable effect adapter, the WhatsApp dispatch shapes, trusted-event
  resolution and the lean prompt. Model-free.
- `node scripts/test-subagents.cjs <wa>` — mock-inference integration: start,
  await, idempotency, per-user isolation, cancellation on provider I/O,
  **silent-provider cancellation** and delayed first token, queue overflow, tool
  denial, restart-unknown, independent transcripts, the ordinary-run parent tool
  path, an over-budget prompt making zero provider calls, and a provider that
  reports no usage being stopped by its reservation. Zero paid inference.

## Health

`crate::subagents::health()` returns one strict shape inside `/health`'s top-level
`subagents` object:

```json
{ "queued": 0, "running": 0, "active": 0,
  "settled": {"completed":0,"failed":0,"cancelled":0,"unknown":0},
  "recovery_error": null }
```

`active` is `queued + running`. `queued` counts admitted children waiting for a
execution slot; everything else that is not settled counts as `running`, so a
cancellation that has been requested but whose execution has not stopped is still
active. `recovery_error` is non-null when a durable record could not be read; in
that state new admission is refused (a lost record also lost the idempotency key
that prevents a replay). No prompts, transcripts or credentials are included.

## WhatsApp responder seam (with the automation worker)

The specialist profile is `whatsapp-responder`, and `lua/core/whatsapp.lua` is
embedded in the host. Its advertised tools are `whatsapp_read`,
`whatsapp_decide` and `whatsapp_send`; the schemas are added to `tools.all(role)`
and filtered by the profile's exact `allowed_tools`, with `tools.dispatch`
re-checking the ceiling before routing to `whatsapp.dispatch`.

The runtime passes the module the trusted snapshot the child already holds:
`ctx.subagent` (the immutable resolved profile, with its `resources` and every
declared limit), `ctx.event` (only `{conversation_id, message_id}`, resolved from
the ledger - a raw event cannot supply a script, path, endpoint or wider scope),
and `ctx.effects` (the durable SQLite adapter built by `lua/core/effects.lua` for
this child session). `ctx.send` is for tests only.

`ctx.effects` satisfies the contract the module documents:

```
effects.reserve({message_id, conversation_id, body, limit})
  -> {status="reserved"|"already_sent"|"ambiguous"|"budget_exceeded", record?}
effects.confirm({message_id, conversation_id, message})
  -> boolean   -- only advances a pending reservation
effects.record(decision_record)
  -> boolean   -- separate table; can never erase a send reservation
effects.reconcile({message_id, ...}) -> {status="sent"|"not_sent"|"unknown", record?}
effects.release({message_id}) -> boolean   -- only when no effect happened
effects.unknown({message_id, detail}) -> boolean   -- ambiguous, never replayed
effects.find(message_id) -> record|nil
effects.count() -> n   -- this child's persistent send budget used
```

`reserve` is one atomic `INSERT .. SELECT`: a new reservation is created only
when no send record exists for the message and this child's pending+sent+unknown
count is below `limit`. A crash between reserve and confirm therefore leaves a
pending row, and the next attempt returns `ambiguous` (`reconcile` is read-only
and returns `unknown`, never `not_sent`, because this adapter cannot see the
app's store). A send whose confirmation cannot be written is reported as
not-success, not as sent. Decisions live in their own table, keyed by the message
id, so recording one never erases a reservation.

Drafting and sending remain different capabilities: `resources.actions` gates
them separately, `resources.send_approved` must be true to send, and the route
(`store` vs `ui`) is bound in the profile, never derived from an event or an
argument.
