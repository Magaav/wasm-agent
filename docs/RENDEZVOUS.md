# Rendezvous

A tiny always-on registry that lets nodes find each other. It stores
`node_id → {public_key, name, role, endpoints, last_seen}` and verifies every
announcement with the node's ed25519 key. It carries no traffic, so it stays
small: one always-on host (our Oracle instance) is enough.

## Why a rendezvous at all

Nodes are bound by **key**, not by address. A node that comes back after a
restart re-announces itself and is recognised by `node_id`, so dynamic IPs, CGNAT
and NAT are non-issues. The only thing that cannot be solved locally is *finding*
a node whose address changed — that is all the rendezvous does.

## What is implemented

| Piece | Status |
| --- | --- |
| ed25519 node identity (`~/.wasm-agent/node.key`) | done — `wa node`, `host.node_identity/sign/verify` |
| Rendezvous service | done — `wa rendezvous --port 8890 --db ~/.wasm-agent/rendezvous.db` |
| `POST /register`, `POST /heartbeat` (signature-verified) | done |
| `GET /lookup?node_id=`, `GET /nodes`, `GET /health` | done |
| Outbound-only client heartbeat | done — set `WASM_AGENT_RENDEZVOUS` |
| **Relay** (reach nodes behind NAT) | **done** — `GET /relay/poll`, `POST /relay/respond`, `POST /relay/send`, `GET /relay/status` |

Verified locally: a valid announcement registers and looks up; a forged
signature is rejected (`bad_signature`); a `serve` instance with
`WASM_AGENT_RENDEZVOUS` set registers itself and appears online.

## How it is reached

- **Outbound only.** Nodes POST to the rendezvous; nothing needs an inbound port.
- **The rendezvous itself** must be publicly reachable by guests, so it needs one
  inbound port and a stable name.

## Deployment (live)

| | |
| --- | --- |
| Public name | **https://rendezvous.colmeio.com** |
| Address | `147.15.64.233` (reserved) |
| Host | `openclaw.ohana` / `openclaw-instance` (Ubuntu 24.04, Oracle) |
| Service | `wa-rendezvous.service` (systemd, **enabled**, restarts on failure) |
| Binds | `127.0.0.1:8890` — never exposed directly |
| TLS | Let's Encrypt via **Caddy** (`tls-alpn-01`), renewed automatically |
| Certificate | `CN = rendezvous.colmeio.com`, Let's Encrypt, ~90 days |
| State | `~/.wasm-agent/rendezvous.db` (SQLite, WAL) |

Caddy already ran on 80/443 for the other colmeio.com sites, so the rendezvous
is a **new site block** in `/etc/caddy/Caddyfile` proxying to localhost; nothing
existing was replaced. `admin off` means `caddy reload` is unavailable, so the
change was applied with a validated restart; every pre-existing site was checked
before and after and is unchanged.

### Verified

- `GET /` — service banner with node counts and the endpoint list.
- `GET /health` — `{"ok":true}` from the public internet (TLS 1.3, valid cert).
- `POST /register` — the `openclaw` node registers and appears online.
- `GET /nodes` / `GET /lookup?node_id=` — returns the node with its endpoint.
- `POST /register` with a forged signature — **401 `bad_signature`**.
- Unknown `node_id` — 404 `unknown_node`.
- Survives reboot — unit is `enabled`.

### Notes and limits

- **Node identity is per instance.** It was per machine (`~/.wasm-agent/node.key`), so two
  processes on one host shared a key and overwrote each other's registration. With named instances
  ([INSTANCES.md](INSTANCES.md)) each node has its own home, key, database and ports, and several
  nodes co-exist on one host; the rendezvous still sees them as separate `node_id`s.
- Port 80 is **not** reachable from Let's Encrypt (the http-01 challenge timed
  out), which is why issuance used **tls-alpn-01 on 443**. Renewal will keep
  using it; no port-80 rule is required.
- Pre-existing and unrelated: `fernanda.colmeio.com` has **no A record**, so
  Caddy cannot renew it (it is only a redirect). Left untouched.
- The relay (for nodes that are not directly reachable) is still phase 3; this
  instance is the natural first relay.

## What I will do once the port is open

```bash
# on the Oracle instance
wa rendezvous --port 8890 --db ~/.wasm-agent/rendezvous.db   # (systemd unit)
```

then on every node:

```bash
export WASM_AGENT_RENDEZVOUS=https://wa.colmeio.com
export WASM_AGENT_NODE_NAME=phone
export WASM_AGENT_ENDPOINT=phone.example:8799   # optional, advertised address
wa serve --port 8799
```

The node registers, heartbeats every 60s, and any master can resolve it by
`node_id`.

## Guest nodes

A node is a **guest** when `WASM_AGENT_NODE_ROLE=guest`, or when `<config>/node.role`
contains `guest` (the environment wins). Anything else is a master.

```bash
export WASM_AGENT_NODE_ROLE=guest   # no worktree of its own, read-only unprompted
```

A guest node owns no worktree and no branch: it is never named after a directory
and `wa` will refuse to rename a branch on its behalf (`guest_has_no_branch`).
It advertises read-only capabilities, and it edits files when a master asks — a
signed `/node/call`, which runs as that master, with the session and tool calls
filed under the master's name rather than the guest's. A caller whose node is not
a master is refused before any of that (`forbidden_role`), so one guest cannot
command another.

A call is believed only when the **rendezvous** confirms the caller, at the moment
of the call: the signature must match the public key the rendezvous currently
associates with that node id (`unknown_caller` otherwise), the call must be fresh
and not a repeat of one already answered (`stale_request`, `replayed_request`),
and if the rendezvous cannot be reached the call is refused rather than allowed
on the strength of a cached list. That is the answer to "a guest can fake a master
call": it would have to hold the master's private key *and* still be enrolled for
that node id.

The rendezvous records what each node says about itself, which is all it can know.
With `WASM_AGENT_TRUSTED_MASTERS` set (comma-separated node ids or names) an
enrolled list decides instead: a caller not named there is refused even though the
rendezvous would vouch for its key.

`scripts/test-guest-e2e.sh` starts a real guest beside the master and attacks it —
a shell request, a forged master call, a replay, a rename that must not move a
branch — and checks that a master's wish is filed under the master. It needs a
reachable rendezvous and a running master node, so it is run on demand rather than
as part of `test.sh`.

## Relay

A node that cannot accept inbound connections attaches by **long-polling** the
relay (`GET /relay/poll`); it never exposes a port. A caller posts to
`POST /relay/send {rid, to, method, path, headers, body}` and the relay hands the
request to the attached node and returns its response. The node's own
`/node/call`, `/node/chat` and `/sync/push` handlers do the work, so a node
behaves identically whether it is reached directly or through the relay.

Design points that matter:

- **Idempotent by request id.** The caller generates one `rid` for the whole
  operation; the relay queues that action **at most once**. A retry after a slow
  fetch re-collects the same result instead of re-running the action — so a
  click or a file write can never double-apply because the network was slow.
- **Abandoned work is dropped.** When a caller gives up, the request is removed
  from the queue, so a node never receives a stale, out-of-date instruction.
- **Attach gating.** `POST /relay/send` returns `503 node_not_attached`
  immediately when the target has not polled recently, instead of hanging.
- **Authenticated end to end.** Every relay call carries `action|node_id|ts`
  signed by the node key; only registered nodes with role `master` may send.
- **Buffered streaming.** `/node/chat` is captured as an SSE body and replayed
  by the caller, so a relayed turn looks the same in the UI as a direct one.

Verified with a node that advertises **no endpoints at all** (NAT simulation):
`bash`/`read` calls, a full chat turn (`relayed-chat-ok`) and a journal sync all
succeeded through `https://rendezvous.colmeio.com`, with the queue draining to
zero afterwards (`GET /relay/status`).

## Security notes

- Every write is **signature-verified**; a node cannot claim another's identity.
- `role` is *claimed* by the node and recorded; the master still enforces
  permissions locally (never trust a peer's self-description).
- Nothing sensitive is stored: only public keys and endpoints.
- The service is read-mostly and tiny; rate-limit per source if it is ever
  abused.
