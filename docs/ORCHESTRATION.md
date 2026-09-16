# wasm-agent orchestration — design & plan

Status: **proposal** (for review). This document plans turning wasm-agent from a
single host+client pair into a multi-node fabric. It is deliberately staged so
each phase ships something usable.

## 1. Goal

One agent, many machines. Install wasm-agent on a host (CLI), invite other nodes
(an Ubuntu backend, phones, browsers, other desktops), and let the agent
**orchestrate** them: route work to whichever node has the capability, stream
events between them, and keep a single memory/ledger.

Non-goals for v1: replacing Kubernetes; running untrusted third-party code;
consensus over a WAN.

## 2. What we already have (the seed)

| Piece | Today | Becomes |
| --- | --- | --- |
| Host runtime | Rust host + embedded Lua, WASM plugins | the **host node** runtime |
| Client bridge | `client_bridge.rs` + `wa-window` executor (screenshot/input/CDP) | the generic **remote tool** channel |
| Roles | `users.json` → `admin` / `guest`, tool gating | the **node + user** trust model |
| Tool tiers | memory / spells / pi / ledger / client / plugins | **capabilities** advertised per node |
| Ledger | SQLite (WAL, FTS5) | replicated event log |
| Transport | SSH tunnel (Windows → host) | QUIC / WebTransport, SSH as fallback |

The important precedent: `client` already proves the pattern — a remote node
long-polls for a command, executes it, posts a typed result, and the host blocks
on it. **Orchestration is that pattern generalised to N nodes and many streams.**

## 3. Concepts

- **Node** — any process running wasm-agent (host, backend, mobile, browser tab).
- **Node identity** — an ed25519 keypair; `node_id = base32(sha256(pubkey))[:26]`.
- **Capability** — a named tool a node can execute (`bash`, `client.screenshot`,
  `camera.capture`, `ledger.search`, …), with a JSON schema and a risk tier.
- **Role** — what a node is trusted with: `admin` (all tiers), `operator`
  (no destructive/code tiers), `guest` (memory + spells only). Same tiers as
  `DESIGN.md §8`, now attached to nodes as well as users.
- **Invitation** — a short-lived, single-use token that admits a node with a
  chosen role and capability mask.
- **Stream** — a named, ordered event channel (`events`, `ledger`, `telemetry`,
  `control`). Kafka-like: topic + partition key + offset + consumer cursor.

## 4. Topology phases

**Phase 0 — today.** One host; clients connect in. Works.

**Phase 1 — hub & spoke (next).** The host node is the hub. Spokes (backend,
mobile, browser) dial in over the existing tunnel. The hub routes tool calls by
capability and fans out events. No new transport; we generalise the client
bridge to a node registry.

**Phase 2 — QUIC / WebTransport mesh.** Replace the tunnel with WebTransport
(HTTP/3). Nodes establish authenticated QUIC connections; the hub can relay
node↔node. Datagrams for low-latency control, reliable streams for events.
Fallbacks: WebSocket over TLS → SSH tunnel.

**Phase 3 — p2p + relay fallback.** Nodes attempt direct QUIC (hole punching via
STUN-like rendezvous); if that fails, relay through any node willing to relay.
The "cloud" becomes optional rendezvous, never required.

## 5. Node protocol (Phase 1 target)

```
hello        node_id, pubkey, version, capabilities[{name,tier,schema}], role_request
invite       token -> { role, capability_mask, expires_at }
welcome      hub pubkey, session id, stream offsets
call         { call_id, node_id, capability, args }        -> result | error
event        { stream, key, seq, ts, body }                (pub/sub)
lease        { call_id, node_id, ttl }                     (at-most-once execution)
```

Rules:
- Every `call` is idempotent by `call_id`; the executor dedupes.
- A node may execute only capabilities inside its mask; the hub re-checks too
  (never trust the caller — the `dispatch` re-check we already do for roles).
- Results are typed and size-capped (we already truncate tool output).

## 6. Transport & streams

Requirement: "game-like" latency and Kafka-like multi-stream.

- **Transport**: WebTransport over QUIC. One connection multiplexes many streams
  and datagrams. 0-RTT on reconnect; no head-of-line blocking across streams.
- **Streams**: each logical stream (`events`, `ledger`, `telemetry`, `control`)
  maps to its own WebTransport stream (reliable) or datagram flow (ephemeral).
- **Framing**: length-prefixed CBOR/MessagePack (compact, fast) with a JSON
  escape hatch for debugging.
- **Semantics**: per-stream monotonic `seq`; consumer cursors persisted per node
  so a reconnect resumes (at-least-once). Effects that must not repeat carry a
  `lease` and are deduped by `call_id`.
- **Backpressure**: per-stream credit (QUIC flow control + an app-level credit
  window); slow consumers don't stall others.
- **Fallback ladder**: WebTransport → WebSocket+TLS → SSE (down) + POST (up) →
  SSH tunnel. Capability negotiation on `hello` picks the best common rung.

## 7. Trust, roles and safety

- Node keys sign every `hello`; the hub pins `node_id → pubkey` on first invite.
- **Invite flow**: hub mints a one-use token with `role` + `capability_mask` +
  TTL (e.g. 15 min). The invitee redeems it, presenting its pubkey. Re-invite
  required to escalate.
- **Escalation is explicit**: a guest node can *request* a capability; the user
  approves in the UI (a balloon, per DESIGN.md). Approvals are logged.
- **High-risk capabilities** (`client.*`, `bash`, `write`, `camera`) always
  prompt on first use per node per session, even for admin.
- **Kill switch**: revoke a node → all its streams close, its leases expire, its
  cursor is retained for audit.

## 8. State & memory

- One **ledger** (event log) is the source of truth; SQLite now, replicated
  later. Phase 1: hub owns the ledger, spokes ship events to it.
- Phase 3: log shipping both ways with per-node checkpointing; optional
  offline-first mode where a mobile node keeps a local SQLite and reconciles by
  `seq` on reconnect. CRDT only if we hit real conflicts (last-writer-wins on
  `(stream, key, seq)` is enough to start).
- Memory stays **on demand** (DESIGN.md §7): replication is plumbing, not UX.

## 9. Orchestration (the actual "multi-node" value)

- **Capability routing**: "take a screenshot" → pick the node advertising
  `client.screenshot` (if several, prefer the requester's own node, then
  least-loaded).
- **Fan-out**: "screenshot every node" → `call` to all, gather with a timeout,
  stream partial results.
- **Task DAG**: a plan is a DAG of capability calls with dependencies; the hub
  schedules ready nodes, retries idempotently, and settles effects (the old
  hermes orchestrator had effect settlement — we reuse that idea).
- **Placement hints**: `where: {os: "linux", gpu: true, role: admin}`.
- **Budgets**: per-node and per-plan token/time budgets (reuse the `/usage`
  limits we already surface).

## 10. Migration plan & milestones

| # | Milestone | Ships |
| --- | --- | --- |
| M1 | Node registry + `hello` over the existing tunnel | `wa nodes` lists peers; capability routing for one remote node |
| M2 | Generalise the client bridge into `remote call` | `client` becomes a built-in capability of the *client node* |
| M3 | Invites + roles per node (UI approval balloon) | invite a guest node from the UI |
| M4 | Event streams over SSH (SSE + POST) | `events`/`telemetry` fan-out, cursors |
| M5 | WebTransport transport + fallback ladder | QUIC mesh, datagrams for control |
| M6 | Task DAG + leases + effect settlement | multi-node plans |
| M7 | Ledger replication + offline mobile node | mobile in the fabric |
| M8 | p2p + relay fallback | no cloud dependency |

Sequencing note: M1–M4 are pure refactors of what exists (the bridge, roles,
SSE). M5 is the first genuinely new subsystem and should not block M1–M4.

## 11. Open questions (the "doubts")

1. **Node identity source** — do we derive node keys from the existing SSH keys,
   or mint a fresh ed25519 per node? (SSH reuse is convenient; a dedicated key is
   cleaner to rotate and works on mobile without SSH.)
2. **Invite UX** — link? code the user types? QR for mobile? expiring how long?
3. **Role granularity** — is a node `admin`/`guest` globally, or per capability
   (e.g. a phone may `camera.capture` but never `bash`)? I'd propose per
   capability, defaults by role.
4. **Mobile runtime** — does a phone run Lua/WASM (`wasm32-wasip2`) itself, or is
   it a thin native client that only executes capabilities we ship? This decides
   whether we need the WASI port next.
5. **How soon is WebTransport real?** It needs a QUIC stack. We are offline-capped
   (`crates.io` blocked, 566 cached crates). Do you want to vendor a QUIC crate,
   or should M5 wait until crate access is restored? Until then, SSE+POST over
   the tunnel is the honest transport.
6. **Kafka semantics depth** — do we need consumer groups, partitions and replay
   from offset, or is "per-stream ordered + cursor resume" enough for v1?
7. **Relay policy** — may any admin node relay for others (bandwidth), or do we
   designate relay nodes? What's the abuse story?
8. **Approval fatigue** — for high-risk capabilities, approve per call, per
   session, or per node with a TTL? (I'd default: per node per session, revocable.)
9. **Data gravity** — when a plan spans nodes, does the ledger move to the data,
   or the data to the ledger? (Affects privacy + latency.)
10. **Naming** — "node", "peer", or "spoke" in the UI? ("node" reads best for
    infra users; "peer" for the p2p future.)
