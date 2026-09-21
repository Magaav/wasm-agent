# Concurrent runs: the implementation

The canonical execution concepts and the target contract are in
[ARCHITECTURE.md section 6](../ARCHITECTURE.md#6-naming-and-execution-ownership) and
[EXECUTION.md](EXECUTION.md). This file is only the **mechanism** behind the admission,
lane and per-run-output clauses, so a reader can find the code and a reviewer can see what
is not yet covered. Read EXECUTION.md for the contract; read this for where it lives.

Mechanism: `rust/wa-host/src/serve/scheduler.rs`, wired into `rust/wa-host/src/serve.rs`.
Proof: that module's unit tests, `scripts/test-run-isolation.sh` (hermetic, local
marker-echoing provider) and the UI check in `scripts/test-ui.ps1`.

## Identity and conversation

`X-WA-Session` is the authenticated **identity**; the chat body's `thread` is the
**conversation**. They are separate, and `routing_session()` prefers the body's `thread`.
Conflating them is how a wake with no auth session looked unrouted, and how a logged-in
window looked as if all of its conversations were one. This matches
[EXECUTION.md](EXECUTION.md#seven-concepts-seven-different-identities).

## The four admission rules

1. **One writer per conversation, from admission to completion.** A conversation is
   claimed when the run is admitted - not when it starts - and held until the last run
   queued behind it completes. A second run for the same conversation is *behind* the
   owner and cannot be handed a different worker. This is what keeps back-to-back
   admissions ordered; the old dispatcher looked only at sessions *currently running*.
2. **A worker never executes a conversation it does not own.** The claimed set is passed
   to the worker pick, so a worker reserved for a run that has not started is not offered
   to another conversation.
3. **The interactive reserve is real.** Worker 0 is the reserve: a background run may use
   only workers `1..=max`. Background concurrency and backlog are bounded
   (`WASM_AGENT_BACKGROUND_MAX`, `WASM_AGENT_BACKGROUND_BACKLOG`), and one conversation's
   own backlog is bounded (`WASM_AGENT_SESSION_QUEUE_DEPTH`), so no single conversation can
   fill a worker's queue. Overflow is an explicit 503 (`background_queue_full`,
   `session_queue_full`), never invisible loss.
4. **The class marker is one-way.** `X-WA-Run-Class: background` (case-insensitive)
   demotes a run into the background lane. Every other value, including `interactive`, is
   ignored and the run keeps the default. **No header value grants reserved capacity**, so
   an untrusted caller cannot promote itself; the worst it can do is enter the smaller
   lane. Relayed peer runs are classified background by the node itself, not by a header.

`/health` reports `runs[]` (conversation, worker, lane, pending) and `run_limits`, so the
guarantee is observable from outside the process.

## The per-run output sink

`host.stream` is a host function, so `write_event` cannot take a run id through its
signature without changing `host.rs`. The sink is therefore **thread-local**: the SSE
handler installs the run's socket for the length of the Lua call and restores the previous
sink on drop; a relayed run installs a buffer local to that call. There is deliberately no
process-wide fallback. Before this, two concurrent runs shared `CLIENT`/`EVENT_SINK` and
the last run to set it owned both streams - the other run's deltas were written into a
socket belonging to a different conversation, or to nobody.

## What this does not cover

Stated so a verdict is not read for more than it says:

- **A relayed peer run executes on worker 0.** Relay jobs are handled in worker 0's loop,
  so they still occupy the interactive reserve even though they are classified background
  for accounting. The lane rule is enforced at HTTP admission; relay admission is not yet
  routed through it.
- **An unnamed first run of a brand-new conversation routes by identity, not conversation.**
  The conversation does not exist until Lua creates it, so the node cannot know its id at
  admission. Once the window has learned the id (its next load), scoping is exact. The
  window's live `busy` state does not depend on this.
- **The sentinel does not set `X-WA-Run-Class`.** Until the sentinel owner adds it, a wake
  takes the default (interactive). The sentinel already limits wake concurrency and refuses
  to wake while a person's turn is running, so the reserve is not unprotected - but the
  node-side lane would be the belt to that suspenders.
