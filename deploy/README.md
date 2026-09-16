# Deployment

How the always-on instance is set up, captured here so it is reproducible rather
than hand-built. Everything that is *code* lives in git; this directory holds the
pieces that live outside it.

## Topology

```
                    DNS: rendezvous.colmeio.com -> reserved public IP
                                    |
                          Caddy :443 (Let's Encrypt)
                                    |  reverse_proxy 127.0.0.1:8890
                                    v
   openclaw.ohana   +--------------------------+
   (always on)      | wa-rendezvous.service    |  registry + relay
                    |  bind 127.0.0.1:8890     |  nodes attach by long-poll
                    +--------------------------+
                    | wa-serve.service         |  this node
                    |  :8799 UI   :8800 client |  UI, client bridge,
                    |  attaches to the relay   |  relay attach, sync ticks
                    +--------------------------+
                                    ^
                                    | outbound only (no inbound port needed)
                    +--------------------------+
                    | other nodes (NAT, mobile)|  reachable via the relay
                    +--------------------------+
```

Nodes bind by **ed25519 key**, never by address, so rotating IPs and NAT do not
matter. A node with no routable address leaves `WASM_AGENT_ENDPOINT` empty and is
reached through the relay.

## Install

```bash
sudo bash deploy/install.sh --with-relay      # on the always-on instance
sudo bash deploy/install.sh                   # on any other node
```

It creates `~/.wasm-agent/env` (from `env.example`, left untouched if present),
installs the systemd units, and enables them. Then fill in the keys:

```bash
$EDITOR ~/.wasm-agent/env      # WASM_AGENT_LLM_API_KEY at minimum
sudo systemctl restart wa-serve
```

## Manual steps (deliberately not automated)

These touch resources shared with other applications, so the installer prints
them instead of doing them:

1. **DNS** — `rendezvous.colmeio.com  A  <reserved public IP>`. Reserve the IP on
   Oracle, or the record dies when the instance's address changes.
2. **Caddy** — append `caddy/rendezvous.colmeio.com.caddy` to
   `/etc/caddy/Caddyfile`, then
   `caddy validate --config /etc/caddy/Caddyfile && systemctl restart caddy`.
   **`reload` does not work** — the Caddyfile sets `admin off`, so the reload API
   is closed. Restart, and check the other sites afterwards:
   `for s in <sites>; do curl -so /dev/null -w "%{http_code} $s\n" -k --resolve $s:443:127.0.0.1 https://$s/; done`
3. **Firewall** — allow `443/tcp` (Caddy). Nothing else needs to be public: nodes
   dial the relay outbound, and `8890` stays bound to localhost.

## Verify

```bash
curl -s http://127.0.0.1:8799/health                 # this node
curl -s https://rendezvous.colmeio.com/health        # rendezvous
curl -s https://rendezvous.colmeio.com/relay/status  # relay + attached nodes
wa nodes                                             # registry from this node
```

## The Windows side

The desktop shell (`rust/wa-window`) is cross-built on Linux
(`scripts/build-window.sh`) and fetched by `scripts/wa-ui.ps1`, which opens an
SSH tunnel (`8799` UI, `8800` client bridge) and launches the window. It talks to
`127.0.0.1` on the client, so the same launcher works against any node.

## GitHub access

Each machine holds its **own** deploy key on the repo (Settings → Deploy keys,
write access), so a machine can be revoked independently — no shared private key
in two places.

| Machine | Key | SSH alias |
| --- | --- | --- |
| the always-on instance | `~/.ssh/id_ed25519_wasm_agent` | `github-wasm-agent` |
| the local clone | `~/.ssh/id_ed25519_wasm_agent_local` | `github-wasm-agent` |

Both use the same remote: `git@github-wasm-agent:Magaav/wasm-agent.git`. To check
which key is being used:

```bash
ssh -v -T git@github-wasm-agent 2>&1 | grep -E "Offering|accepts key"
```

## Notes

- One node per machine: the key lives in `~/.wasm-agent/node.key`. Override with
  `WASM_AGENT_NODE_KEY` to run several (as the tests do).
- `~/.wasm-agent/env` is machine-wide, so **per-node settings** (name, endpoint,
  relay) must be passed in the process environment when running more than one.
  Per-node *state* (provider/model choice, spells) already lives under
  `~/.wasm-agent/nodes/<node_id>/`.
