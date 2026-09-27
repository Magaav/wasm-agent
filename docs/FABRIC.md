# Fabric scheduling contract

The first ordered child dispatcher and external workspace are described in
[ORCHESTRATOR-WORKSPACE.md](ORCHESTRATOR-WORKSPACE.md). It implements priority,
task-count admission and a durable queue. The broader resource/affinity contract
below still includes planned behavior; task-count limits are not memory quotas.

The rendezvous is the fabric control plane. It carries identity, reachability and the latest
advisory resource sample. A node's local scheduler remains the authority for admission; a remote
sample can guide placement but cannot reserve capacity.

## Work vocabulary

- A **task** is a schedulable unit of work with requirements, affinity and an outcome. It may be
  retried or moved before execution, and a larger request may create several tasks.
- A **run** is one admitted execution of an agent against one durable conversation. It owns a run
  id, worker, cancellation state and resource claims, and may contain several model calls.
- A **turn** is one user message and the agent activity it causes inside a conversation. A turn can
  span several model/tool rounds and normally belongs to one run. Steering during execution joins
  that run at a round boundary; a later message after settlement begins another run.

The interactive node (desktop or mobile) owns the conversation and streams a cloud run's events as
they arrive. Execution location must not change transcript identity: the cloud is the worker, while
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
