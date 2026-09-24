# Concurrent runs: the implementation

The canonical execution concepts and the target contract are in
[ARCHITECTURE.md section 6](../ARCHITECTURE.md#6-naming-and-execution-ownership) and
[EXECUTION.md](EXECUTION.md). This file is only the **mechanism** behind the admission,
lane, cancellation and per-run-output clauses, so a reader can find the code and a
reviewer can see what is not yet covered. Read EXECUTION.md for the contract; read this for
where it lives.

Mechanism: `rust/wa-host/src/serve/scheduler.rs`, the admission block in
`rust/wa-host/src/serve.rs`, `wa_admission`/`wa_identity`/`wa_verify_peer` in
`lua/core/server.lua`, and the runtime's `subagents` module.
Proof: that module's unit tests, `scripts/test-run-isolation.sh` (hermetic, local
marker-echoing provider) and the UI check in `scripts/test-ui.ps1`.

## Identity and conversation, resolved before admission

`X-WA-Session` is an authenticated **credential**; the chat body's `thread` is the
**conversation**. They are separate, and the conversation is never taken from the header.

The accept thread owns one **control interpreter**, and it runs on its own **resolver
thread** so the accept thread can bound the wait (`WASM_AGENT_ADMISSION_TIMEOUT_MS`,
default 8000) - a busy SQLite lock or a slow interpreter must not stop the node accepting.
The resolver calls `wa_admission(session, node, body)` before any worker is reserved and
returns the authenticated user and the real conversation id, or an error:

- a nonempty invalid/expired credential is refused `401 invalid_session` - it never reaches a
  run as the default master (`lua/core/users.lua`'s strict `users.resolve`);
- a named thread owned by another user is refused `403 forbidden_thread` before a slot is
  taken;
- a body with no thread returns the session `agent_for` would resume (created if needed), so
  the scheduler owns a real id instead of an empty key.

This matches [EXECUTION.md](EXECUTION.md#seven-concepts-seven-different-identities).

## The admission rules

1. **One writer per conversation, from admission to completion.** A conversation is
   claimed when the run is admitted - not when it starts - and held until the last run
   queued behind it completes. A second run for the same conversation is *behind* the
   owner and cannot be handed a different worker.
2. **A worker never executes a conversation it does not own.** The claimed set is passed
   to the worker pick, so a worker reserved for a run that has not started is not offered
   to another conversation.
3. **The lanes are separate index ranges, not priorities.** Run workers live below the
   control floor; the control lane owns the top of the range. Background runs use only
   indices `WASM_AGENT_INTERACTIVE_RESERVE..run_capacity` (default reserve **2**), so two
   concurrent chats remain possible while background work saturates the rest. Background
   concurrency and backlog are bounded (`WASM_AGENT_BACKGROUND_MAX`, default
   `capacity - reserve`; `WASM_AGENT_BACKGROUND_BACKLOG`, default 8), and one
   conversation's own backlog is bounded (`WASM_AGENT_SESSION_QUEUE_DEPTH`, default 4).
   Overflow is an explicit 503 (`background_queue_full`, `session_queue_full`), never
   invisible loss.
4. **One admission for every run.** A local `/chat`, a directly-arriving peer `/node/chat`,
   and a relayed `/node/chat` all travel the same scheduler. The worker channel carries both
   HTTP and relay work, so a peer run cannot bypass admission on worker 0's housekeeping
   path. A peer's signature is verified **once, before admission**
   (`wa_verify_peer`), and the conversation is keyed by the verified author, never by the
   `x-wa-node` header; the run half (`wa_node_chat_verified`) does not re-verify, because a
   second check of the same signed request is refused as a replay.
5. **The class marker is one-way.** `X-WA-Run-Class: background` (case-insensitive)
   demotes a run into the background lane. Every other value, including `interactive`, is
   ignored and the run keeps the default. **No header value grants reserved capacity**, so
   an untrusted caller cannot promote itself.

`/health` reports `runs[]` (conversation, worker, lane, pending), `run_ids[]`
(conversation, run_id, state), `run_limits` (session backlog, background bounds,
interactive reserve, control workers) and `subagents`/`subagent_counts`, so the guarantees
are observable from outside the process. None of these carry a prompt or a credential.

## Cancellation

`POST /runs {action:"status"|"cancel", thread|conversation:"<id>", run_id?}` is answered on
the accept thread from the scheduler's own state, so it never queues behind the run it is
cancelling. Identity comes from `wa_identity`; an invalid credential is `401`, and a run
owned by another user is `403` (with a run id) or `404` (without). A run has its **own**
cancel flag, so cancelling a running run does not cancel the run queued behind it.

`cancel` sets the flag and reports the state the run was in; it never claims the run
stopped. The run's state becomes `cancelled` only when it settles, and a queued run that was
cancelled before it started settles its own stream exactly once and never executes.

The worker installs the run's flag as a thread-local current-run context, and
`serve::run_cancel_requested()` is registered with the runtime as the run half of unified
cancellation (`host::set_run_cancel_probe`). The runtime's provider reader and agent loop
poll `host::run_cancel_requested()`, which combines the run flag with a child task's own
flag. The UI's Stop sends this request before aborting the stream, so stopping a run stops
it on the node rather than only in the page.

## The per-run output sink

`host.stream` is a host function, so `write_event` cannot take a run id through its
signature without changing `host.rs`; the signature is deliberately unchanged. The sink is
**thread-local**: the SSE handler installs the run's socket for the length of the Lua call
and restores the previous sink on drop; a relayed run installs a buffer local to that call.
There is deliberately no process-wide fallback.

When a browser reloads during a local SSE run, the old socket cannot be transferred to the new page. The node
keeps the active run's unsaved event tail in memory and serves it through owner-scoped `POST /run-events`.
`record_turn` emits a checkpoint after each durable message; events before it are already represented by the
transcript, so the refreshed page reloads through that message and then applies only the newer events. Tool-call
ids let the page attach a replayed live call to its already-painted pending row, and message ids prevent a saved
final reply from appearing twice. The replay tail is capped at 4 MiB per run and discarded when the run settles.
If it fills before another checkpoint, the endpoint reports overflow and the UI says live replay is waiting for
the next saved step. A process restart does not preserve the tail; the durable transcript remains the recovery
source.

## Subagents are a control call

`POST /subagents` calls the runtime's global `wa_subagents(body, session)`. It is served by
the **control lane**, never a run slot, and is never admitted as a run: `start` launches a
native background child, so the route itself is a control call. An invalid credential is
refused `401` at the boundary. The HTTP `await` is capped
(`WASM_AGENT_SUBAGENT_AWAIT_MS`, default 10000) so one control slot cannot be held
indefinitely; `POST /runs`, `POST /run-events` and `/health` are answered without a worker,
so cancellation, live replay and health stay prompt even while every control slot is awaiting.

## What this does not cover

Stated so a verdict is not read for more than it says:

- **A foreground run's silent provider read is not socket-interruptible.** Cancellation is
  observed between provider chunks, and the runtime's socket shutdown is wired for child
  tasks. A foreground run blocked on a provider that has sent nothing is stopped when the
  next chunk arrives or the read times out, not the instant the flag is set.
- **The sentinel does not set `X-WA-Run-Class`.** A wake takes the default (interactive);
  the sentinel already limits wake concurrency and refuses to wake while a person's turn is
  running, so the reserve is not unprotected.
- **A slow write still occupies worker 0.** Writes remain pinned to worker 0 for the
  one-writer guarantee; the two interactive slots mean an operator's *run* is not stuck
  behind it, but an operator's next *write* can be.

## Peer-run proof

`scripts/test-peer-run-admission.cjs` proves the authorized peer path end to end with two isolated
nodes, a local rendezvous/relay and a local mock model - no cloud rendezvous, no paid account:

    node scripts/test-peer-run-admission.cjs [wa-binary]

It runs a signed direct `POST /node/chat`, a signed relayed one, and one through the native Lua sender
(`nodeslib.remote_chat`), and asserts against the node's own `/health` that the run went *through
admission*: the verified peer author owns the conversation, the authenticated body `thread` is the
scheduling key, the peer run is `background` on a background worker (not one of the two interactive
slots), a duplicate signed request is `replayed_request`, a body that does not match its signature and
an unregistered master are refused before admission (no owner is created), a registered guest is
`forbidden_role`, and the peer's transcript is not in the destination operator's session list. A
successful reply is itself the proof that the signature was verified exactly once: the run half does
not re-verify, because a second verification of the same signed request would be refused as a replay.

### The signed target binds the request

A `/node/chat` body is an envelope whose `to_node_id` is inside the signed bytes:

    {"to_node_id":"<target node id>","text":"<prompt>","thread":"<optional conversation>"}

The signature domain is **`chat-v2`**: `chat-v2|<from>|<ts>|<sha256(body)>`. The version is part of
the signed message, so the target, the prompt and the thread are all authenticated *and* a new request
cannot execute on an old receiver. The receiver checks `to_node_id` against its own node id at
admission, before any conversation, worker or model call. This is what stops a relay (or anyone on the
path) from redirecting a valid chat: the relay envelope's outer `to`/`path` are not covered by the
transport signature, but a chat signed for node A delivered to node B is refused `wrong_target`, a
changed path is refused because the signature names the `chat-v2` kind, and a changed body is refused
`bad_signature`. The fixture proves this with two real destination nodes that both trust the same
peer: A and B are both valid recipients, so only the signed target tells them apart.

### Compatibility and migration

**Both directions fail closed until both ends are upgraded, and nothing ever runs the body as text.**

The signature domain changed from `chat` to `chat-v2`:

- a new sender -> a new receiver works (the target-bound envelope, verified as `chat-v2`);
- a legacy sender -> a new receiver: the legacy `chat|...` signature does not verify as `chat-v2`, so
the receiver refuses `legacy_peer_protocol` (direct: 400; relay: 403) and the request never reaches a
model. This holds even when the body carries the new target fields;
- a new sender -> a legacy receiver: the legacy verifier reconstructs `chat|...` and the signature is
`chat-v2|...`, so it refuses `bad_signature` before any model. A new request cannot execute on an old
receiver, even if a malicious relay redirects it.

The version is deliberately breaking: there is no capability negotiation and no insecure fallback.
Upgrade both ends together. The fixture proves both directions with a faithful legacy ed25519
verification routine (it accepts a real `chat|...` signature and rejects a `chat-v2` one), so the
old-receiver check is not a stub. The transport (`relay-send|node_id|ts`) is unchanged, so the
deployed rendezvous keeps working; the binding and the version are in the inner request, which is the
part the target verifies.
