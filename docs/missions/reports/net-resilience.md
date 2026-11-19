# net-resilience - a network drop never kills a run; wa comes back by itself

Brief: Victor, 19/11 12:20, CRITICAL. Worktree `wt`, branch `change/net-resilience`, base `origin/main` ac7717e0.

## PHASE 0 - the root cause, measured before code

The brief's file references were stale: `lua/provider.lua` and `lua/agent.lua` do not exist; the real
paths are `lua/core/provider.lua` and `lua/core/agent.lua`. Re-measured premises:

| Brief said | Measured |
|---|---|
| `provider.lua:1405/1463`, `agent.lua:2585` | `lua/core/provider.lua:1405` is real; the retry loop is `lua/core/agent.lua:2456-2568` |
| "provider refused the request x3, then run_failed" | true, and the bucket was the RATE-LIMIT one |
| `MAX_CONNECTIONS=256` at `rendezvous.rs:290` | correct |
| `wa nodes` lists only itself after the drop | true, cause found in `fetch_peers` |

**Reproduction (real vault, real bytes).** `vault/wa_vault.py` started against a closed port and an
unresolvable host returns, in 0.00 s:

```
502 {"error": {"code": "vault_upstream_unreachable",
     "message": "wa-vault could not reach the opencode-go upstream (gaierror)", "type": "wa_vault"}}
502 {..., "(ConnectionRefusedError)" ...}
```

**Where the run gave up.** 502 is in `TRANSIENT_STATUS`, so `M.is_rate_limited` claimed it: the
run got the SHORT refusal budget, `rate_limit_retries()` = 3, waits of 2/4/8 s, then
`run_failed: provider_http_502 vault_upstream_unreachable (gaierror)`. `M.is_connection_lost`
did not match it, so the patient policy never ran. Verified against the base commit in a separate
worktree (`ac7717e0`): `is_rate_limited(incident)=true`, `is_connection_lost(incident)=false`,
`rate_limit_retries=3`, and `is_link_down` did not exist.

**Roster.** `fetch_peers` initialised `local peers = {}` and assigned `cache, cache_at = peers` on
EVERY path, so a failed `/nodes` read replaced the cache with an empty table. Every later
`M.find` then returned nil and the caller answered `unknown_node:<peer>` until a restart.

## What changed, per item, with the commit that implements it

1. **A refusal that names a dead link is a lost link** - `95c51654`. New allow-list
   `LINK_EVIDENCE` + `M.is_link_down` (`lua/core/provider.lua`); `is_rate_limited` returns false
   for it, `is_connection_lost` returns true. A TLS handshake failure counts; a certificate-VERIFY
   failure deliberately does not (waiting cannot repair a trust refusal).
2. **The wait is patient and visible** - `95c51654`. `M.link_wait_is_unbounded` (unbounded unless
   `WASM_AGENT_PROVIDER_CONNECT_RETRIES`/`_CONNECT_WAIT_SECONDS` is set), `connection_backoff_ms`
   now 1,2,4,8,16,30 s jittered, the waiting row `waiting for the network · <provider> unreachable ·
   retry in Ns`, and one `network back after NmNNs` line on recovery.
3. **Unknown is not final** - `6be1efef`. `M.is_final` (auth 401/403, 400/422/404/413/415, unknown
   model, content refusal) and `M.is_unknown_failure` + `M.unknown_retries` = 5, then the run fails
   through `run_failure.classify`, i.e. by name.
4. **A failed roster read keeps its peers** - `bc1e2869`. Peers survive marked `online=false` with
   `last_seen`; `M.peer_offline` answers `peer_offline:<name> (last seen ...)`; a SUCCESSFUL read
   still removes a peer. Safety net: `60f42483` teaches `run_recovery.RECOVERABLE_FAILURE`
   `vault_upstream_unreachable`, `provider_http_5`, `provider_unreachable`, `waiting for the network`.
5. **A caller cannot storm a node** - `7a48bb73`. `RELAY_MAX_IN_FLIGHT` = 4 per node, refused by
   name (`peer_busy_caller`) BEFORE anything is sent; `relay_backoff_ms` doubles 750 ms, capped at
   8 s after jitter, honours `Retry-After`.
6. **The rendezvous sheds fairly** - `ef56769c`. `RESERVED_LANES` scaled to the cap
   (`reserved_lanes_at`), `is_priority_lane`, `lane_refusal` (per-caller 8, per-target 32), and every
   shed answer carries `Retry-After` in the header and `retry_after_ms` in the body.
7. **A binding check survives the outage** - `ef56769c`, gate row `a439251e`. An admission already
   granted is remembered (`ADMISSION_CACHE_SECONDS`, 600 s) and stands through a LINK failure only;
   anything the registry ANSWERS (removed, revoked, expired) refuses at once, and a caller never
   admitted before is still refused.
8. **A storm converges on a real socket** - `ef56769c`. `rust/wa-rendezvous/tests/convergence.rs`: cap
   16, ordinary traffic sheds at 12, `/health` served to 16, and ordinary traffic converges **252 ms**
   after the storm clears (assertion bound: 60 s).

## Texts to approve (verbatim)

1. `waiting for the network · %s unreachable · retry in %ds (%d, no limit; the link is waited for until it returns, Esc stops the run)`
2. `waiting for the network · %s unreachable · retry in %ds (%d/%d); waiting up to %ds for the link`
3. `network back after %dm%02ds`
4. `peer_offline:%s (last seen %s)` and its sentence: `%s is in the roster but unreachable right now (last seen %s): nothing was sent, so nothing ran. Check the link and the node, then retry - a peer that is merely unreachable is never removed from the roster.`
5. `peer_busy_caller` and its sentence: `this node already holds %d relayed calls to %s (its cap): nothing was sent and nothing ran. Wait for one to answer, then retry.`
6. `the registry is at its connection cap; nothing ran, wait and retry` and `the registry is serving its reserved lanes first; nothing ran, wait and retry`
7. `nothing was queued; the same rid may be sent again after the wait`

## Tests, and where each is wired

| Row | New/changed | Wired in |
|---|---|---|
| `test-network-outage-recovery.lua` | new, 30 checks | `scripts/test.sh` |
| `test-network-roster-offline.lua` | new, 19 checks | `scripts/test.sh` |
| `test-network-relay-backpressure.lua` | new, 377 checks | `scripts/test.sh` |
| `test-network-binding-outage.lua` | new, 14 checks | `scripts/test.sh` |
| `test-stream-cut-recovery.lua` | +3 assertions (19/11 tail) | already in the gate |
| `wa-rendezvous` unit + `tests/convergence.rs` | new | `gate_run cargo test -p wa-rendezvous` |

Every new Lua row creates its own scratch `WASM_AGENT_HOME` and refuses a real home
(`paths.data()` under it, no `keys`/`secrets`). All four also pass under the fast path's own
environment, so none is listed in `scripts/fast-path.exclude`.

**Proved on the base, not assumed.** `test-network-roster-offline` fails on `ac7717e0` at
"a FAILED roster read does not erase the peers it already knew"; `test-network-outage-recovery`'s
classification assertions are the ones the base measurement above falsifies.

**Pre-existing failure, named:** `scripts/test-remote-refusals.lua` fails at line 108
("node refusal through the relay") on `ac7717e0` too - it is not this change's, and it was not fixed
here.

## What is NOT proved, and what I did not do

- Item 8's convergence test runs ONE registry process against raw sockets: it proves the listener's
  fairness and convergence, not a signed four-node relay exchange. The brief's "4 scratch nodes" was
  not reproduced; the policy it targets is proved at the level where the policy lives.
- The relay-cap path (`too_many_connections` handling in `nodes.request`) is proved against a stub
  relay, not against the real rendezvous at its cap.
- No live fleet was called at any point (no `wa call`, `tools.remote`, `land` or deploy), per rule 13.
- I did not run the whole 311-row gate; I ran the rows that touch what changed (11 suites, all green)
  plus a wider sweep of 10 neighbours.
- The tree under `/tmp` was 80% full (a 16 GB tmpfs) and produced a spurious sqlite I/O error early
  on; all my scratch work moved to `/home/victor/nr-scratch`. Other missions' leftovers in `/tmp`
  (3.2 GB free) were left untouched.
