# Roadmap

Where wasm-agent is going, what already exists, and how we would know each step
actually worked. Status is honest: ✅ shipped, 🔜 next, 🧭 later.

## The shape of the target

Today wasm-agent is **one node running one agent**. The target is a **fleet in one
window**: many agents working at once, on this machine and others, with the UI as the
thing that holds the picture and orchestrates them — an agentic OS rather than a chat
box. Orca is the reference for what that feels like to use; the difference is that
here the UI *is* the orchestrator, and the agents are nodes the UI can see, dispatch
to, and compare.

That gives the UI three surfaces, which are also the three things a person does with an
agent:

| View | What it is for | Status |
|---|---|---|
| **Avatar** | Always there, always on top: a round, translucent presence you can drag anywhere and click to open. | ✅ |
| **Compact chat** | The conversation: streaming tokens, tool topics, per-turn diffs with real undo, sessions, skills. | ✅ |
| **Orchestrator** | The fleet: nodes and shells side by side, one lane per agent thread, dispatch and watch, compare results, merge. | 🔜 |

The orchestrator is not a bigger chat window. It is a different surface: panes that
each own a node, a session, a terminal, a diff, a status — and a way to send work to
one, to all of them, and to see what came back.

## 🔜 Many threads, not one

**The blocker for everything else.** A node has a single interpreter and runs one turn
at a time; a second request queues. The vision is 16–32 agent threads in one UI.

Two mechanisms, and we want both:

1. **A pool inside a node.** The Lua state is not thread-safe, so concurrency means
   *N states* — a pool of interpreters, each with its own session lane, sharing the
   ledger and the model budget. This is the piece that makes 16–32 threads real.
2. **The fabric across nodes.** Nodes already have their own identity, sessions and
   worktrees, and can call each other. A fleet is mostly *this*, and it works today —
   what it lacks is a UI that shows it.

*How we would know:* N concurrent turns, measured — `scripts/bench-*.sh` extended to
report wall-clock for N=1, 8, 16, 32 turns, and `/health` reporting per-lane state
instead of one `current`.

**Implementation notes, from reading the node's core (so the next pass starts from facts):**

- One `Lua` state is built in `rust/wa-host/src/main.rs` (around the host registration
  block); the `Host` — one SQLite `Connection` behind a `Mutex`, plus the plugin
  registry and the client bridge — is created once and shared **by pointer** with
  `register_with_upvalue`. So N states can share it and every DB access stays
  serialized by that `Mutex`. `PRAGMA journal_mode=WAL` and `busy_timeout=5000` are
  already set, so a future design with one connection per worker is also safe.
- The refactor is: factor that registration + `EMBEDDED` + the `dofile` bootstrap into
  a `boot_state(host) -> Lua` closure, build N of them, load `lua/core/server.lua`
  into each, and change `serve::run(lua, port, ui)` to take the vector.
- `beat()` is a global with no idea which worker called it, so per-worker beats need a
  `thread_local` worker id set when each worker thread starts; `health_body` then
  reports per-worker `state`/`ms` and the *newest* beat drives `ok`.
- The self-exit must become "every worker is stalled", not "the worker is stalled":
  one wedged lane should not kill healthy ones. With the default of one worker the
  behaviour is unchanged, which is why the pool ships **opt-in** (`WASM_AGENT_WORKERS`,
  default 1) and is measured before it becomes the default.
- Safety rules the pool must not break: **one writer per session** (requests carrying
  the same `X-WA-Session` must not run concurrently), and per-session order. The cheap
  first cut — worker 0 owns turns and writes, extra workers serve reads — gets the
  responsiveness win with no ordering risk at all; affinity for concurrent turns is
  the second step.
- The test that judges it already has a shape: `scripts/test-serve-concurrency.sh`
  (it caught the single-threaded node answering nothing while a turn ran). With a
  pool, a read must be answered *while* a turn is in flight, and `/health` must name
  the worker that is busy.

## 🔜 Orchestration context

An orchestrator that does not know the fleet is a window with panes in it. The UI needs
one document that answers: *which nodes, which are alive, what is each one doing, what
did each one change, what is waiting on a human.*

Most of the inputs exist — `/nodes`, `/health`, `/sessions`, the rendezvous list, the
relay, per-turn diffs, the ledger. What is missing is a **fleet state** assembled from
them and streamed as one SSE feed the UI (and the model) can subscribe to.

Then the interesting half: **the agent gets that context too.** The UI is a service, not
just a client — the model can ask "what is the fleet doing", "open a lane for this
node", "show me that diff", "dispatch this to the node that owns that worktree". That
is the user's own phrasing: *talk to the wasm-agent UI and it has the orchestration
context itself.*

*How we would know:* a turn that answers "what is running right now" correctly while
four other turns are in flight, and a dispatch that lands in the right lane.

## 🔜 The orchestrator view

One window per node is already possible — the shell opens real, OS-managed windows
(`open_view`), and the UI routes them by URL (`?view=…`). The orchestrator is that
mechanism used deliberately:

- a **lane** per agent thread: transcript, terminal, diff, status, cost;
- **dispatch**: send a task to a lane, to a selection, or to all;
- **compare**: the same task across lanes, side by side, with each lane's evidence;
- **merge**: per-lane diffs, and the handoff gate per lane.

*How we would know:* two nodes, four lanes, one dispatch, and a readable answer to
"which lane did it better" that is built from evidence rather than from prose.

## 🧭 Wake word

Talk to it without touching anything: a wake word, then a turn with the fleet context
already attached, answered out loud. Needs audio capture in the shell, a **local** wake
model (a cloud round trip for "are you there" is the wrong trade), and a short "what is
happening" summary the model can be handed.

Deliberately last. A wake word is the easiest feature in this list to make annoying, and
the least useful until the fleet is real.

## Also on the list

- 🔜 **Live-partial replay.** A page reloaded mid-turn shows history and the finished
  reply, but not the tokens arriving now. Needs a per-turn event buffer and a replay
  path (the relay already has one).
- 🔜 **A branch that cannot drift.** A node that cannot see `main` cannot see the rules.
  A sentinel trigger — "when the node comes up, merge `origin/main` into its worktree" —
  makes the 21-commit blindness impossible rather than merely unlikely.
- 🔜 **The sentinel as a service.** The unit file exists; the installer does not install
  it yet.
- 🔜 **`bash` refuses the node's own port.** The self-deadlock (an agent curling the node
  it is running on, so the request queues behind the turn that made it) has happened
  three times. The exec deadline reports it; the tool should refuse it.
- 🔜 **An anchored native balloon.** Undecorated, always-on-top, positioned at its
  anchor, closing on deactivation, sharing the main window's profile so it can talk to
  the page. Needs a `wa-window` change; the in-page balloon and the view window cover
  the need until then.
- 🧭 **Plugin ABI → component model + WIT.** The ABI is a tiny core-module contract
  today; typed interfaces and capability imports are the destination.
- 🧭 **Lua core → `wasm32-wasip2`.** The agent's brain as a portable component, which is
  why the host/agent split is drawn where it is.
- 🧭 **The desktop client as its own node.** The window becomes a peer: it can hold a
  session, run tools, and be orchestrated like any other node.

## What we will not do

- **No silent success.** A failure that cannot be seen is a failure that will be
  repeated. This is why a failing tool opens its topic, why a refusal names the file,
  and why a skipped test is reported as skipped.
- **No unorganized memory.** Facts the model writes are explicit and editable; the
  ledger is append-only and never rewritten by a model.
- **No capability the agent can talk itself into.** The thing that can restart the node
  is a separate process with a fixed verb list, not a tool.
