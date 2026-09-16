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
| Relay (for masters behind NAT) | planned, phase 3 |

Verified locally: a valid announcement registers and looks up; a forged
signature is rejected (`bad_signature`); a `serve` instance with
`WASM_AGENT_RENDEZVOUS` set registers itself and appears online.

## How it is reached

- **Outbound only.** Nodes POST to the rendezvous; nothing needs an inbound port.
- **The rendezvous itself** must be publicly reachable by guests, so it needs one
  inbound port and a stable name.

## Infrastructure we need (asks)

1. **A static address.** Attach a **reserved public IP** to the Oracle instance
   (if the instance uses an ephemeral IP, reserve one and reassign it) so a DNS
   record stays valid.
2. **A DNS name.** Create an `A` (and `AAAA` if there is IPv6) record:
   `wa.colmeio.com → <reserved public IP>`. (`rendezvous.colmeio.com` is fine
   too; pick one and I will wire it.)
3. **One inbound port**, opened in **two** places on Oracle Cloud:
   - the **VCN security list / NSG** ingress rule (console — I cannot do this
     from the shell), and
   - the instance firewall (I can do this: `iptables -I INPUT -p tcp --dport
     <port> -j ACCEPT`, persisted).
   Preferred: **TCP 443** (never blocked by client networks). Alternative:
   **TCP 8890** (the current default) or **8443**.
4. **TLS.** For HTTPS on 443 pick one:
   - **Cloudflare (easiest if colmeio.com is on Cloudflare):** create the record
     proxied (orange cloud) and terminate TLS at the edge, forwarding to the
     instance on a port it can reach. No certificate on the box.
   - **Let's Encrypt on the instance:** needs **TCP 80** reachable once for the
     HTTP-01 challenge (or DNS-01 with a token). I can run certbot and add the
     renewal timer.
   - **Cloudflare Tunnel (`cloudflared`):** no inbound ports at all — the tunnel
     dials out and Cloudflare publishes the hostname. Good fallback if opening
     ports is awkward.
5. **Keep it running.** I will add a systemd unit
   (`wa-rendezvous.service`) so it survives reboots.

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

## Security notes

- Every write is **signature-verified**; a node cannot claim another's identity.
- `role` is *claimed* by the node and recorded; the master still enforces
  permissions locally (never trust a peer's self-description).
- Nothing sensitive is stored: only public keys and endpoints.
- The service is read-mostly and tiny; rate-limit per source if it is ever
  abused.
