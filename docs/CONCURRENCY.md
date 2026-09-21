# Concurrent runs: identity, conversation, and the lanes

The node used to run one thing at a time, so "one writer per session" needed no mechanism: one
interpreter meant one writer. Runs are now routed to several workers, and the guarantees that
used to be free are now enforced at **admission**. This file is that contract. Its mechanism is
`rust/wa-host/src/serve/scheduler.rs`; its tests are that module's unit tests and
`scripts/test-run-isolation.sh`.

## The nouns

`ARCHITECTURE.md` §6 settles the words. For concurrency they mean:

| noun | here it means |
| --- | --- |
| **owner** | the authenticated identity (`x-wa-session`). It decides *authority* and is passed to Lua unchanged. |
| **conversation** | the body's `thread`, else `x-wa-session`. It decides *what serialises*: the transcript a run may write. |
| **run** | one execution in a conversation. |
| **lane** | interactive or background: which capacity a run may use. |

**Identity is not conversation.** The window puts the account session in the header and the
conversation in the body; the sentinel does the same for a wake. `routing_session()` therefore
prefers the body's `thread`. Conflating them is how a wake with no auth session looked unrouted,
and how a logged-in window looked as if all its conversations were one.

## The four rules

1. **One writer per conversation, from admission to completion.** A conversation is claimed when
   the run is admitted - not when it starts - and held until the last run queued behind it
   completes. A second run for the same conversation is *behind* the owner and cannot be handed a
   different worker. This is what keeps back-to-back admissions ordered; the old dispatcher looked
   only at sessions *currently running*, so two runs admitted together for a fresh conversation
   could land on two workers and write one transcript twice.
2. **A worker never executes a conversation it does not own.** The claimed set is passed to the
   worker pick, so a worker reserved for a run that has not started is not offered to another
   conversation.
3. **The interactive reserve is real.** Worker 0 is the reserve. A background run may use only
   workers `1..=max`, so a burst of wakes cannot take the worker a person's next run needs.
   Background concurrency and backlog are bounded (`WASM_AGENT_BACKGROUND_MAX`,
   `WASM_AGENT_BACKGROUND_BACKLOG`), and one conversation's own backlog is bounded
   (`WASM_AGENT_SESSION_QUEUE_DEPTH`), so no single conversation can fill a worker's queue.
4. **The class marker is one-way.** `X-WA-Run-Class: background` (case-insensitive) demotes a run
   into the background lane. Every other value, including `interactive`, is ignored and the run
   keeps the default. **No header value grants reserved capacity**, so an untrusted caller cannot
   promote itself; the worst it can do is enter the smaller lane. Relayed peer runs are classified
   background by the node itself, never by a header.

## The per-run event sink

`host.stream` is a host function, so `write_event` cannot take a run id through its signature
without changing `host.rs`. The sink is therefore **thread-local**: the SSE handler installs the
run's socket for the length of the Lua call and restores the previous sink on drop; a relayed run
installs a buffer local to that call. There is deliberately no process-wide fallback. Before this,
two concurrent runs shared `CLIENT`/`EVENT_SINK` and the last run to set it owned both streams -
the other run's deltas were written into a socket belonging to a different conversation, or to
nobody.

## What this does not cover

Stated so a verdict is not read for more than it says:

- **A relayed peer run executes on worker 0.** Relay jobs are handled in worker 0's loop, so they
  still occupy the interactive reserve even though they are classified background for accounting.
  The lane rule is enforced at HTTP admission, and relay admission is not yet routed through it.
- **An unnamed first run of a brand-new conversation routes by identity, not conversation.** The
  conversation does not exist until Lua creates it, so the node cannot know its id at admission.
  Once the window has learned the id (its next load), scoping is exact. The window's live `busy`
  state does not depend on this.
- **The sentinel does not set `X-WA-Run-Class`.** Until the sentinel owner adds it, a wake takes
  the default (interactive). The sentinel already limits wake concurrency and refuses to wake while
  a person's turn is running, so the reserve is not unprotected - but the node-side lane would be
  the belt to that suspenders.
