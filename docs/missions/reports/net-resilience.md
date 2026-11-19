# net-resilience - a network drop never kills a run; wa comes back by itself

Brief: Victor, 19/11 12:20, CRITICAL. Worktree `wt`, branch `change/net-resilience`, base `origin/main` ac7717e0.
Independent review r1 returned FIX (3 MUSTs, 6 SHOULDs); everything below is the state AFTER that round.

## PHASE 0 - the root cause, measured before code

The brief's file references were stale: `lua/provider.lua` and `lua/agent.lua` do not exist; the real
paths are `lua/core/provider.lua` and `lua/core/agent.lua`.

**Reproduction (real vault, real bytes).** `vault/wa_vault.py` against a closed port and an
unresolvable host returns, in 0.00 s:

```
502 {"error": {"code": "vault_upstream_unreachable",
     "message": "wa-vault could not reach the opencode-go upstream (gaierror)", "type": "wa_vault"}}
502 {..., "(ConnectionRefusedError)" ...}
```

**Where the run gave up.** 502 is in `TRANSIENT_STATUS`, so `is_rate_limited` claimed it: the run got
`rate_limit_retries()` = 3, waits of 2/4/8 s, then `run_failed: provider_http_502`. Verified in a
separate worktree of `ac7717e0`: `is_rate_limited=true`, `is_connection_lost=false`, retries 3.

**Roster.** `fetch_peers` assigned `cache, cache_at = peers` on every path with `peers` initialised to
`{}`, so one failed `/nodes` read erased the fleet and every call answered `unknown_node`.

## Items (brief numbering) and the commits that implement them

1. **A transient error never ends a run.** `95c51654` (link class), `564952d8` (MUST 1), `ed6ab83f`
   (status outranks body). `LINK_EVIDENCE`/`is_link_down`; `is_final` allow-list (401/403, 400/422/404/
   413/415, unknown model, content refusal) read BEFORE any body text; plain 5xx/408/425/429 now wait with
   NO total cap (1 s doubling to a 30 s cap, jittered), and only an UNCHANGED repeat is bounded
   (`identical_repeat_ceiling`, default 10) and then named.
2. **The wait is visible.** `95c51654`, `564952d8`. Row: `waiting for the network · <provider>
   unreachable · retry in Ns (N, no limit - it waits until the wait stops helping, Esc stops the run)`;
   recovery line `network back after NmNNs` (`374a60bc`: only after a REAL link failure and a
   measurable wait).
3. **Unknown is not final.** `6be1efef`. `is_unknown_failure` + `unknown_retries` = 5, then fail by
   name through `run_failure.classify`.
4. **Missions safety net.** `60f42483`, `29648369`. `RECOVERABLE_FAILURE` learned
   `vault_upstream_unreachable`, `provider_http_5`, `provider_unreachable`, `waiting for the network`;
   and a tail that already repeated one failure unchanged is NOT re-driven.
5. **A caller cannot storm a node.** `7a48bb73`, `e403c8df`, `374a60bc`. `RELAY_MAX_IN_FLIGHT` = 4 per
   target, refused by name (`peer_busy_caller`) before anything is sent; the counter is now NODE-WIDE
   (one file per peer under `paths.data()`, TTL 120 s), because the old table was per interpreter and
   `wa call` is its own process. `relay_backoff_ms` doubles 750 ms to 8 s, jittered, honours
   `Retry-After`. The slot is released on EVERY path and every body is decoded safely (`e403c8df`).
6. **The rendezvous sheds fairly.** `ef56769c`, `29648369`. `reserved_lanes_at` scaled to the cap,
   `is_priority_lane` (now including `/register` - `7e50b670`), `lane_refusal` (per-caller 8, per-target
   32), `Retry-After` in header and `retry_after_ms` in body on every shed, and the shed decision reads
   the LIVE open count.
7. **A binding check survives the outage.** `ef56769c`, `7e50b670`. `M.authorize` remembers a POSITIVE
   admission for `ADMISSION_CACHE_SECONDS` (600 s) and falls back to it only on a LINK failure; the
   binding TICK uses the same cached authority, still names the outage, and keeps polling.
8. **A real storm converges.** `4e4fee17`. `rust/wa-rendezvous/tests/storm.rs`: four scratch nodes with
   real ed25519 keys, 300 held sockets past the base cap, a proxy the test owns that CUTS the link for
   60 s, then every node must answer a REAL signed relayed call (measured 252 ms after the restore,
   peak 301 connections). **It fails on the base registry** with `503 too_many_connections`.

MUST 3 was additionally proved with a direct probe: on the base, a failing `/register` gives
`POLLS=0` and no tick state; here it gives `POLLS=1` and `state=attached`.

## Texts to approve (verbatim)

1. `waiting for the network · %s unreachable · retry in %ds (%d, no limit - it waits until the wait stops helping, Esc stops the run)`
2. `waiting for the network · %s unreachable · retry in %ds (%d/%d); waiting up to %ds for the link`
3. `network back after %dm%02ds`
4. `peer_offline:%s (last seen %s)` and its sentence: `%s is in the roster but unreachable right now (last seen %s): nothing was sent, so nothing ran. Check the link and the node, then retry - a peer that is merely unreachable is never removed from the roster.`
5. `peer_busy_caller` and: `this node already holds %d relayed calls to %s (its cap): nothing was sent and nothing ran. Wait for one to answer, then retry.`
6. `the registry is at its connection cap; nothing ran, wait and retry` / `the registry is serving its reserved lanes first; nothing ran, wait and retry` / `nothing was queued; the same rid may be sent again after the wait`
7. `roster_unavailable:%s` and: `the roster could not be read, so %s cannot be looked up right now: nothing was sent and nothing ran. This is not a missing node - retry once the rendezvous answers.`
8. `[the same failure repeated %d times unchanged; it is not a transient wait any more]`

## Tests, and where each is wired

| Row | New/changed | Wired in |
|---|---|---|
| `test-network-outage-recovery.lua` | new, 34 checks | `scripts/test.sh` |
| `test-network-roster-offline.lua` | new, 24 checks | `scripts/test.sh` |
| `test-network-relay-backpressure.lua` | new, 393 checks | `scripts/test.sh` |
| `test-network-binding-outage.lua` | new, 19 checks | `scripts/test.sh` |
| `test-provider-rate-limit-recovery.lua` | 29 checks (MUST 1) | already in the gate |
| `test-stream-cut-recovery.lua` | 33 assertions | already in the gate |
| `rust/wa-rendezvous/tests/storm.rs` + unit tests | new | `gate_run cargo test -p wa-rendezvous` |

Every new Lua row creates its own scratch `WASM_AGENT_HOME` and refuses a real home. All four also pass
under the fast path's own environment, so none is in `scripts/fast-path.exclude`.

**Proved on the base, not assumed:** `test-network-roster-offline` fails at "a FAILED roster read does
not erase the peers it already knew"; the MUST 3 probe gives `POLLS=0` there; `storm.rs` fails with
`503 too_many_connections`.

**Pre-existing failure, named:** `scripts/test-remote-refusals.lua` fails at line 108 on `ac7717e0`
too. It is not this change's and was not fixed here.

## What is NOT proved, and what I did not do

- `storm.rs` drives the registry over real sockets with real signatures and a real cut, but the four
  "nodes" are threads in one process rather than four OS processes: the registry's fairness and
  recovery are proved; process-level scheduling is not.
- No live fleet was called at any point (no `wa call`, `tools.remote`, `land` or deploy), per rule 13.
- I did not run the whole 311-row gate; I ran the rows that touch what changed plus a wider sweep of
  20 neighbours, all green.
- `/tmp` on this node is a 16 GB tmpfs at 80% full (other missions' leftovers, 3.2 GB free); all my
  scratch work lived in `/home/victor/nr-scratch`. I left other missions' files alone.
