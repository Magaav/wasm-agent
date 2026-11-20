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

## Items, in the BRIEF's numbering, and the commits that implement them

Brief items 1-4 are the provider/missions half; items 5-8 are the second-evidence (relay deadlock) half.

**Item 1 - a transient error never ends a run, and a final one fails at once by name.**
`95c51654` (link class + patient wait), `6be1efef` (unknown class), `564952d8` (MUST 1),
`ed6ab83f` (status outranks the body). `LINK_EVIDENCE`/`is_link_down`; `is_final` allow-list
(401/403, 400/422/404/413/415, unknown model, content refusal) read BEFORE any body text; plain
5xx/408/425/429 wait with NO total cap (1 s doubling to a 30 s cap, jittered); a failure matching NO
class is retried 5 times then failed by name (`is_unknown_failure`/`unknown_retries`); only an
UNCHANGED repeat is bounded (`identical_repeat_ceiling`, default 10) and then named.

**Item 2 - the run row says it is waiting, and one line when it comes back.**
`95c51654`, `564952d8`, `374a60bc`. Row: `waiting for the network · <provider> unreachable · retry
in Ns (N, no limit - it waits until the wait stops helping, Esc stops the run)`; recovery line
`network back after NmNNs`, emitted only after a REAL link failure and a measurable wait.

**Item 3 - mesh/relay: the roster is re-learned, and an unreachable peer stays in it.**
`bc1e2869`, `374a60bc`. A failed roster read keeps every known peer marked `online=false` with
`last_seen`; `remote_call` answers `peer_offline:<name> (last seen ...)`; a COLD cache during an
outage answers `roster_unavailable` (never `unknown_node`); a SUCCESSFUL read may still remove a peer.

**Item 4 - missions need no launcher change; the launcher's continue pattern is the safety net.**
`60f42483`, `29648369`. `RECOVERABLE_FAILURE` learned `vault_upstream_unreachable`,
`provider_http_5`, `provider_unreachable`, `waiting for the network`; a tail that already repeated
one failure unchanged is NOT re-driven.

**Item 5 - callers back off with jitter and hold at most N relayed calls per node.**
`7a48bb73`, `e403c8df`, `374a60bc`. `RELAY_MAX_IN_FLIGHT` = 4 per target, refused by name
(`peer_busy_caller`) before anything is sent; the counter is NODE-WIDE (one file per peer under
`paths.data()`, TTL 120 s), because the old table was per interpreter and `wa call` is its own
process. `relay_backoff_ms` doubles 750 ms to 8 s, jittered, honours `Retry-After`. The slot is
released on EVERY path and every transport body is decoded safely (`e403c8df`).

**Item 6 - the rendezvous sheds load fairly, with Retry-After.**
`ef56769c`, `7e50b670`, `29648369`. `reserved_lanes_at` scaled to the cap (so a test cap of 16
reserves 4); `is_priority_lane` covers `/relay/poll`, `/relay/respond`, `/bindings/*`, `/lookup`,
`/health`, `/service` AND `/register`; `lane_refusal` caps per-caller (8) and per-target (32);
`Retry-After` in the header and `retry_after_ms` in the body on every shed; the decision reads the
LIVE open count.

**Item 7 - a binding check survives a rendezvous outage.**
`ef56769c`, `7e50b670`. `M.authorize` remembers a POSITIVE admission for `ADMISSION_CACHE_SECONDS`
(600 s) and falls back to it only on a LINK failure - a registry that ANSWERS (removed, revoked,
expired) still refuses at once, and a caller never admitted before is refused. The binding TICK uses
the same cached authority, keeps polling when `/register` fails, and still names the outage.

**Item 8 - a test that reproduces the storm and asserts the fleet converges: NOT PROVEN HERE.**
The end-to-end storm MOVED to the **fabric-transport** mission, where the relay is redesigned; testing
today's relay storm end to end would be work on the wrong base. What was attempted, and why it is
gone: `rust/wa-rendezvous/tests/storm.rs` (four keyed nodes, 300 held sockets, a proxy that cut the
link) failed identically with a ZERO-second cut, which no product bug explains - the instrument was the
least reliable part, so it proved nothing and was deleted. The end-to-end storm is an OPEN claim.

What IS landed here is the node's half, at unit level: `scripts/test-network-outage-tick.lua`
(71 checks). Through a 60 s relay outage the REAL `binding.tick` keeps TRYING to poll on every second
(the 19/11 deadlock - a failed `/register` used to return before the poll), re-attaches with no
restart, and a REAL `nodes.remote_call` then holds the node's verified answer.

MUST 3 (item 6/7's deadlock) was additionally proved with a direct probe: on the base a failing
`/register` gives `POLLS=0` and no tick state; here it gives `POLLS=1` and `state=attached`.

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
| `test-provider-rate-limit-recovery.lua` | 46 checks (MUST 1, r3 item 1) | already in the gate |
| `test-stream-cut-recovery.lua` | 33 assertions | already in the gate |
| `test-network-outage-tick.lua` | new, 71 checks | `scripts/test.sh` |
| `wa-rendezvous` unit tests | new | `gate_run cargo test -p wa-rendezvous` |

Every new Lua row creates its own scratch `WASM_AGENT_HOME` and refuses a real home. All four also pass
under the fast path's own environment, so none is in `scripts/fast-path.exclude`.

**Proved on the base, not assumed:** `test-network-roster-offline` fails at "a FAILED roster read does
not erase the peers it already knew"; the MUST 3 probe gives `POLLS=0` there; and the outage row's
own deadlock assertion fails on the base with `polls 0 -> 0`.

**Pre-existing failure, named:** `scripts/test-remote-refusals.lua` fails at line 108 on `ac7717e0`
too. It is not this change's and was not fixed here.

## What is NOT proved, and what I did not do

- **The end-to-end storm is NOT proved here.** It moved to fabric-transport; the Rust attempt that
  stood in for it was deleted for being an unreliable instrument (see Item 8). Only the node's half -
  real tick, real caller, unit level - is landed.
- No live fleet was called at any point (no `wa call`, `tools.remote`, `land` or deploy), per rule 13.
- I did not run the whole 311-row gate; I ran the rows that touch what changed plus a wider sweep of
  20 neighbours, all green.
- `/tmp` on this node is a 16 GB tmpfs at 80% full (other missions' leftovers, 3.2 GB free); all my
  scratch work lived in `/home/victor/nr-scratch`. I left other missions' files alone.
