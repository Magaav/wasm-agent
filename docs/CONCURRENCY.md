# Concurrent runs: the implementation

The canonical execution concepts and the target contract are in
[ARCHITECTURE.md section 6](../ARCHITECTURE.md#6-naming-and-execution-ownership) and
[EXECUTION.md](EXECUTION.md). This file is only the **mechanism** behind the admission,
lane and per-run-output clauses, so a reader can find the code and a reviewer can see what
is not yet covered. Read EXECUTION.md for the contract; read this for where it lives.

Mechanism: `rust/wa-host/src/serve/scheduler.rs`, the admission block in
`rust/wa-host/src/serve.rs`, and `wa_admission` in `lua/core/server.lua`.
Proof: that module's unit tests, `scripts/test-run-isolation.sh` (hermetic, local
marker-echoing provider) and the UI check in `scripts/test-ui.ps1`.

## Identity and conversation, resolved before admission

`X-WA-Session` is an authenticated **credential**; the chat body's `thread` is the
**conversation**. They are separate, and the conversation is never taken from the header.

The accept thread owns one **control interpreter** and calls
`wa_admission(session, node, body)` before it reserves a worker. The resolver returns the
authenticated user and the real conversation id, or an error:

- a nonempty invalid/expired credential is refused `401 invalid_session` - it never reaches a
  run as the default master (`lua/core/users.lua`'s strict `users.resolve`);
- a named thread owned by another user is refused `403 forbidden_thread` before a slot is
  taken;
- a body with no thread returns the session `agent_for` would resume (created if needed), so
  the scheduler owns a real id instead of an empty key. This is what makes same-conversation
  ordering hold for unnamed runs too.

This matches [EXECUTION.md](EXECUTION.md#seven-concepts-seven-different-identities).

## The admission rules

1. **One writer per conversation, from admission to completion.** A conversation is
   claimed when the run is admitted - not when it starts - and held until the last run
   queued behind it completes. A second run for the same conversation is *behind* the
   owner and cannot be handed a different worker.
2. **A worker never executes a conversation it does not own.** The claimed set is passed
   to the worker pick, so a worker reserved for a run that has not started is not offered
   to another conversation.
3. **Two interactive slots are reserved.** Worker indices below
   `WASM_AGENT_INTERACTIVE_RESERVE` (default **2**) are never given to background work, so
   two concurrent chats remain possible while background work saturates the rest. Background
   concurrency and backlog are bounded (`WASM_AGENT_BACKGROUND_MAX`, default
   `capacity - reserve`; `WASM_AGENT_BACKGROUND_BACKLOG`, default 8), and one conversation's
   own backlog is bounded (`WASM_AGENT_SESSION_QUEUE_DEPTH`, default 4). Overflow is an
   explicit 503 (`background_queue_full`, `session_queue_full`), never invisible loss.
4. **One admission for every run.** A local `/chat`, a directly-arriving peer `/node/chat`,
   and a relayed `/node/chat` all travel the same scheduler. The worker channel carries both
   HTTP and relay work, so a peer run cannot bypass admission on worker 0's housekeeping
   path. A peer run is forced background and keyed by its thread, else its peer node id.
5. **The class marker is one-way.** `X-WA-Run-Class: background` (case-insensitive)
   demotes a run into the background lane. Every other value, including `interactive`, is
   ignored and the run keeps the default. **No header value grants reserved capacity**, so
   an untrusted caller cannot promote itself; the worst it can do is enter the smaller lane.

`/health` reports `runs[]` (conversation, worker, lane, pending) and `run_limits`
(session backlog, background bounds, interactive reserve), so the guarantees are observable
from outside the process.

## The per-run output sink

`host.stream` is a host function, so `write_event` cannot take a run id through its
signature without changing `host.rs`; the signature is deliberately unchanged. The sink is
**thread-local**: the SSE handler installs the run's socket for the length of the Lua call
and restores the previous sink on drop; a relayed run installs a buffer local to that call.
There is deliberately no process-wide fallback. Before this, two concurrent runs shared
`CLIENT`/`EVENT_SINK` and the last run to set it owned both streams - the other run's deltas
were written into a socket belonging to a different conversation, or to nobody.

## What this does not cover

Stated so a verdict is not read for more than it says:

- **The sentinel does not set `X-WA-Run-Class`.** Until the sentinel owner adds it, a wake
  takes the default (interactive). The sentinel already limits wake concurrency and refuses
  to wake while a person's turn is running, so the reserve is not unprotected - but the
  node-side lane would be the belt to that suspenders.
- **Run cancellation is not implemented here.** `/health` has no per-run cancelled state and
  no route sets one. Cancelling a model call needs the Lua run loop to observe a stop signal,
  which is the runtime worker's module; the admission bookkeeping here is ready to carry a
  `cancel(conversation)` flag but nothing consumes it yet. This is a real gap, not a silent
  success.
- **A slow write still occupies worker 0.** Writes remain pinned to worker 0 for the
  one-writer guarantee; the two interactive slots mean an operator's *run* is not stuck
  behind it, but an operator's next *write* can be.
