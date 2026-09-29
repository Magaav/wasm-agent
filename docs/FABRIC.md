# Fabric scheduling contract

The first ordered child dispatcher and external workspace are described in
[ORCHESTRATOR-WORKSPACE.md](ORCHESTRATOR-WORKSPACE.md). It implements priority,
task-count admission and a durable queue. The broader resource/affinity contract
below still includes planned behavior; task-count limits are not memory quotas.

The rendezvous is the fabric control plane. It carries identity, reachability and the latest
advisory resource sample. A node's local scheduler remains the authority for admission; a remote
sample can guide placement but cannot reserve capacity.

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

Three naming rules follow from the map, and they are the same concern as "one home per rule":

1. a node's execution threads are **node-threads**. `/health`'s `workers`, `workers_count`,
   `control_workers` and `workers_spawned` fields are the pre-rename names of that array and of the
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
- A **run** is one admitted execution of an agent against one durable conversation. It owns a run
  id, a node-thread, cancellation state and resource claims, and may contain several model calls.
- A **turn** is one user message and the agent activity it causes inside a conversation. A turn can
  span several model/tool rounds and normally belongs to one run. Steering during execution joins
  that run at a round boundary; a later message after settlement begins another run.

The interactive node (desktop or mobile) owns the conversation and streams a cloud run's events as
they arrive. Execution location must not change transcript identity: the cloud node executes it, while
the originating master remains the author and presentation endpoint.

## Placement order

Placement is lexicographic, not a blended score:

1. eligibility: online, authorized, required capabilities and enough hard capacity;
2. explicit preference tier;
3. existing conversation/workspace/model affinity;
4. packing within that tier: prefer the already-loaded node while it remains below safety limits;
5. free capacity and observed latency;
6. stable round robin only as the final tie breaker.

This deliberately fills the first preferred node before spilling into the next preference tier.
CPU, RAM, disk, thermal state and queue limits are safety gates, so preference can never place work
on an overloaded node. A future dispatcher must reserve capacity at admission rather than assuming
that a heartbeat sample is still current.

## Transport direction

The application envelope and scheduling contract stay independent of transport. The migration
target is native QUIC between nodes, direct paths established through ICE/STUN when possible, and
the Ohana relay as fallback. Browser clients use WebTransport to their node or gateway. Control and
run events use reliable streams; replaceable telemetry may use datagrams. The current HTTPS relay
remains the compatibility path until both ends negotiate the newer protocol.
