# Fabric: routing heavy work by state, never by a rule

The compute fabric answers one question for every heavy job — *which live node runs this, right now?* —
and it answers it in one round trip, with a local path that is always available. The implementation is
`rust/wa-fabric` (the rules), `rust/wa-kernel-runtime/src/fabric_node.rs` (the node half: presence, the
offer pump, the lease), `wit/fabric/fabric.wit` (the typed records) and the operator view
`services {"action":"fabric"}`. The first user is speech: `rust/wa-stt-remote/src/fabric.rs`.

The rule that shapes everything below: **machines come and go** (the 2-core cloud node powers off, the
16-thread desktop sleeps), so placement reads *state* — a heartbeat with a TTL — and never a static
list, a role, or a config file naming a favourite machine.

The first ordered child dispatcher and external workspace are described in
[ORCHESTRATOR-WORKSPACE.md](ORCHESTRATOR-WORKSPACE.md). The broader resource/affinity contract below
covers the interactive dispatch path; task-count limits are not memory quotas.

The rendezvous is the control plane: it carries identity, reachability and the latest advisory
resource sample. A node's local scheduler remains the authority for admission; a remote sample can
guide placement but cannot reserve capacity.

## Topology: the layers and their real names

The concepts and their ownership are [ARCHITECTURE.md section
6](../ARCHITECTURE.md#6-naming-and-execution-ownership) and [EXECUTION.md](EXECUTION.md); this is the
map of who is what, so a thing can be named correctly before it is changed.

| layer | what it is | its real name |
| --- | --- | --- |
| client | the page a person looks at (`ui/`, `<wa-chat-shell>`), served by a node and reloading on its own | **the window**, or **the client** - it is not "the node" |
| node process | one `wa serve`: one identity, one state home, one transcript, admission, plugins, capabilities | **the node** - a node is not a computer, and one machine may host several instances |
| execution inside the node | the threads that serve work, reported by `/health` as one array per thread with `role: "runs"` or `"reads"` and a state (`rust/wa-host/src/serve.rs`) | **node-threads** (singular **node-thread**) - never `workers`, never `nodes` |
| conversation | an independently resumable conversation: a **session** holds many **runs**, and a run holds many **turns** | **session -> runs -> turns** |
| delegated work | a supervised child task with its own context and execution state - a session of its own, which a profile may bind to its own worktree and branch (`session_worktree`, [EXECUTION.md](EXECUTION.md)) | **a subagent** - never `factory worker`, never `child node` |
| supervisor | the process outside the node that starts work without doing it: declared verbs, never a shell, and it installs or restarts when the node is idle | **the sentinel** (`wa-sentinel`, [SENTINEL.md](SENTINEL.md)) |
| other machines | peer nodes carrying an identity and authenticated messages, resolved by the control plane; the relay is the fallback transport | **peers** and **the rendezvous** |
| the compute fabric | presence, placement and the lease that routes heavy work between peers (`rust/wa-fabric`) | **the fabric** - not "the cluster", not "the grid" |

Three naming rules follow from the map, and they are the same concern as "one home per rule":

1. a node's execution threads are **node-threads**. `/health`'s `workers`, `workers_count`, <!-- naming-check: allow (a naming map prints the pre-rename field names on purpose, so a reader who greps for one finds the new one) -->
   `control_workers` and `workers_spawned` fields are the pre-rename names of that array and of the <!-- naming-check: allow (same line, same reason: the old field names, printed on purpose) -->
   same count; the code rename is a separate, in-flight change, so prose says node-thread while the
   literal field name stays exactly as the wire has it.
2. the containment is **sessions -> runs -> turns**: a run belongs to one session, a turn to one run.
3. a delegated child is **a subagent**, and that is the only name for it. Live config keeps its own
   identifiers until an operator changes them: the profile id `task-worker`, the profile file
   `<home>/subagent-profiles/task-worker.json`, and the env keys `WASM_AGENT_WORKERS`,
   `WASM_AGENT_WORKERS_MAX`, `WASM_AGENT_WORKERS_IDLE_SECONDS`, `WASM_AGENT_CONTROL_WORKERS`,
   `WASM_AGENT_WORKER_STALL_SECONDS`, `WASM_AGENT_WORKER_STALL_EXIT_SECONDS` and
   `WASM_AGENT_SUBAGENT_CONCURRENCY`. Naming them is not renaming them.

This is a naming map, not a capability claim: what each layer may do is in the documents this table
points at, and the placement and transport below are their own sections.

## Work vocabulary

- A **task** is a schedulable unit of work with requirements, affinity and an outcome. It may be
  retried or moved before execution, and a larger request may create several tasks.
- A **job** is one task the fabric routes: an id, a kind (`stt`, `ocr`, `embed`, `index`, `build`, or
  any capability word a node advertises), a payload size, and a lease. The payload stays in the queue;
  the fabric records never carry it.
- A **run** is one admitted execution of an agent against one durable conversation. It owns a run
  id, a node-thread, cancellation state and resource claims, and may contain several model calls.
- A **turn** is one user message and the agent activity it causes inside a conversation. A turn can
  span several model/tool rounds and normally belongs to one run. Steering during execution joins
  that run at a round boundary; a later message after settlement begins another run.

The interactive node (desktop or mobile) owns the conversation and streams a cloud run's events as
they arrive. Execution location must not change transcript identity: the cloud node executes it, while
the originating master remains the author and presentation endpoint.

## Presence: a heartbeat with a TTL, not a directory of favourites

Every node publishes a small heartbeat every 2–5 s (default 3 s, `WASM_AGENT_FABRIC_HEARTBEAT_MS`):
its id, the capabilities it serves, three load numbers (`queue_depth`, `cpu_busy_pct`,
`mem_used_pct`), its version and its own clock. Every node keeps the last heartbeat of every peer and
nothing else.

- **Stale after three missed beats** (`stale_after_beats = 3`, 9 s at the default cadence). A machine
  that powers off stops being a candidate by being silent, not by announcing a departure. Three, not
  one: one missed beat is a stall, two is a hiccup, by the third the node is either gone or too busy
  to be a candidate.
- **Age is the receiver's clock.** A peer with a wrong clock can only make itself look late.
- **A sample is not a reservation.** A heartbeat says what was true a moment ago; admission stays
  local (see the lease below).
- The view is bounded: a sample nobody has heard from for four TTLs is forgotten, and a peer that
  comes back is live again on its next beat (`resurrected`), not after a timeout.
- `queue_depth` in the published heartbeat is read from the node's own fabric queues, so the number
  placement scores is the number the queue holds.

## Placement: eligibility, then cost, then the local tie

Placement is two steps, in this order, and the order is the contract:

1. **Eligibility** — live, covers the capabilities the job needs, and inside the safety gates:
   `cpu_busy_pct ≤ 95`, `mem_used_pct ≤ 95`, `queue_depth ≤ 64`, and a recent offer round trip no
   worse than 2 s. A gate is not a preference: an overloaded node is never a candidate.
2. **Cost** — the cheapest eligible node wins. The score is in **milliseconds**, so every term is a
   number an operator can read and disagree with, and the admin view prints the terms, not just the
   total:

   | term | default | what it prices |
   | --- | --- | --- |
   | `queue_depth` | 1 000 ms per queued job | waiting already in front of this job |
   | `cpu` | 10 ms per busy percent | machine pressure |
   | `mem` | 4 ms per used percent | machine pressure |
   | `latency` | measured | the recent offer round trip to that node (an EWMA of accepts) |
   | `transfer` | 20 MB/s | moving a payload ≥ 256 KiB to a node that does not hold it |
   | `locality` | −5 000 ms | running where the bytes already are, for a payload ≥ 256 KiB |

   Payloads below 256 KiB are not priced for transport at all: a 4 kB job costs nothing to move, and
   pretending otherwise would prefer a slow local node. Above it, `locality` plus `transfer` say "send
   the job to the data, not the data to the job".

**Self is a candidate like any other, and it wins an exact tie.** Local execution costs zero round
trips, so a peer has to be measurably better to be worth an offer — that is what makes the fabric as
instantaneous as possible instead of as distributed as possible. The tie-break after that is the node
id, so the answer is stable across processes and a test can assert it.

Ranking order for interactive dispatch (conversation/workspace affinity, packing, round robin) is
unchanged for agent runs; the fabric's cost model is the placement step for *heavy jobs*.

## Offer/accept: one round trip, one window, then the local path

1. The producer ranks the candidates and sends **one OFFER** to the best one, directly, over the
   transport that already exists (the signed node call: relay, or the mesh's direct hop). Nothing new
   listens; nothing new is exposed.
2. The peer **ACCEPTS or REFUSES** in one answer, decided from its load *now*, not from the beat the
   producer scored: an acceptance is an admission check, not a reservation.
3. On accept, the peer **takes the lease** from the producing node's queue. On refuse, the producer
   offers the next candidate — but only inside the same window, never a second one.
4. When the window elapses (`WASM_AGENT_FABRIC_OFFER_MS`, default **200 ms**) or nothing better than
   self was found, the job runs **here, now**. That is a plan, not an error path: the local path never
   waits for anything, so the fabric can be slow, wrong or absent without blocking work.

The window is one budget for the whole placement, and the number of fall-through offers is capped, so
a fleet of refusing peers costs one window and not one window per peer. A reply whose id does not
match the offer in flight (a duplicate, a replay, an answer to a previous attempt) is ignored.

## The lease: `wa-queue`'s, not a second one

The fabric routes work onto a `wa-queue` queue (`fabric.<kind>`, one per job kind) and does not invent
a second notion of ownership. So the properties are the queue's own (`docs/QUEUE.md`):

- **A killed node costs one lease.** Its heartbeats stop, `take`'s own recovery (or the producer's
  `sweep`) puts the job back to `Ready`, and the next worker — another peer or this node — takes it.
- **Exactly once.** The queue refuses a settle from a worker that no longer holds the lease, so a node
  that wakes up after being declared dead cannot write a second result.
- **Heartbeat progress.** A running job extends its lease and appends progress chunks; an admin reads
  the same records to tell "running" from "stuck".

A node's lease worker id is `<node>:<generation>`, so a restarted node is a new worker and its old
lease is nobody's.

## Job kinds are open

A capability is a word: `stt`, `ocr`, `embed`, `index`, `build`, or anything a node advertises. A job
kind is the capability a node must serve, and a job may require more than one. A new heavy job kind is
therefore a new word plus a queue (`fabric.<kind>`) — no new interface, no change to this crate. The
speech queue is the first user and keeps its behaviour: with the fabric off, `Preference` decides
exactly as before (`rust/wa-stt-remote/src/fabric.rs`).

## Knobs

| key | default | meaning |
| --- | --- | --- |
| `WASM_AGENT_FABRIC` | on | `0`/`false`/`off` disables the fabric: every job runs locally, as before |
| `WASM_AGENT_FABRIC_HEARTBEAT_MS` | 3 000 | heartbeat cadence (accepted 500–60 000) |
| `WASM_AGENT_FABRIC_OFFER_MS` | 200 | the whole placement window (accepted 1–10 000) |
| `WASM_AGENT_FABRIC_TRANSFER_BYTES_PER_MS` | 20 000 | the relay throughput the `transfer` term assumes |

A value that is present but unreadable keeps the default and is reported, never silently zeroed; an
unreadable `WASM_AGENT_FABRIC` word is not consent to turn routing off.

## The operator view

`services {"action":"fabric"}` answers the node's own view, in the order an operator asks:

1. **who is in the fabric** — every node held, its capabilities, its load, `age_ms`, `missed_beats`
   and whether that makes it `live` or stale;
2. **what was placed recently and why** — the last placements with the winning node, the score's terms
   and the one word that excluded each node that was not eligible (`stale`, `incapable`, `busy`,
   `slow`);
3. **what fell back** — local runs by reason (`disabled`, `self_best`, `no_peer`, `no_capable_peer`,
   `offer_window_elapsed`, `all_refused`), the offers that timed out, the refusals by word;
4. **what is leased** — the leases the fabric queues carry, when each lapses, and how many already
   lapsed and are waiting for recovery;
5. **the measured latency** — the last 256 placement round trips as p50/p95, and per node the EWMA
   the score uses. With no samples the view prints `null` and `samples: 0`, never a zero that looks
   like a measurement.

Nothing in it carries a payload, a transcript, a result or a secret: ids, kinds, numbers and words.

## What is measured

`cargo test -p wa-fabric` — 19 tests, including the three scenarios from the brief on a three-node
harness (`rust/wa-fabric/src/sim.rs`: real queues, real leases, one process, a clock moved by hand):

- placement picks the idle capable node, and the score's terms say why;
- a node killed mid-job loses its lease, the job is requeued and finished exactly once (the dead
  node's late settle is refused by the queue);
- every peer gone runs locally without waiting, and a silent peer costs exactly the 200 ms window;
- the flag off is the local path, byte for byte the pre-fabric behaviour;
- placement latency on this checkout: decision p50 **2 µs**, p95 **5 µs**; one offer round trip on
  loopback p50 **104 µs**, p95 **213 µs** — one RTT plus microseconds, well inside the 5 ms target.

`bash scripts/bench-fabric.sh` prints the same distribution from the same test, and
`bash scripts/test-fabric.sh` runs the crate, the node half and the speech integration together.

## Transport direction

The application envelope and scheduling contract stay independent of transport. The migration
target is native QUIC between nodes, direct paths established through ICE/STUN when possible, and
the Ohana relay as fallback. Browser clients use WebTransport to their node or gateway. Control and
run events use reliable streams; replaceable telemetry may use datagrams. The current HTTPS relay
remains the compatibility path until both ends negotiate the newer protocol.

The fabric adds no transport of its own: a heartbeat and an offer are bodies of the existing signed
node call, tunneled out through the node's Lua pump (`host.fabric_pending`/`host.fabric_deliver`) so
the private key never leaves the interpreter.

The first step of that direction exists: [MESH.md](MESH.md) is a **direct node-to-node hop** — a
signed ed25519 call from one node's listener to another's, authorized by the fleet's hierarchy rather
than by the rendezvous — with the relay kept as the fallback for a peer that cannot be reached
directly. It is plain HTTP on loopback/LAN today and it is behind `WA_MESH=1`; the rendezvous stays a
directory, which is the part of this section that does not change.
