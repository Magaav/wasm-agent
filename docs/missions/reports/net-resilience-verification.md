# net-resilience - verification round: two MUSTs

Review r2 (verification) returned FIX with two MUSTs. Both are done, one commit each, plus the SHOULDs.

## MUST 1 - the repeat limit must not cap lost links or busy statuses

Commit **0f13d665**. The ceiling was applied to every uncapped class, so a network cut answering the
same "connection refused" - or a 503 with a fixed body - died after ~151 s while the row said "no
limit". That is the opposite of what the brief asks.

`M.repeats_are_a_wall` now decides: only `provider_http_500` and a failure matching NO class are
walls. A lost link (`is_link_down`), an unknown-failure-free transient, and every busy status
(503/504/408/425/429/529) are excluded by name, and the agent only arms the ceiling when that predicate
says so. Text 1 ("no limit - it waits until the wait stops helping") is true again.

Proved in `scripts/test-provider-rate-limit-recovery.lua` (41 checks): twelve IDENTICAL link failures
and twelve IDENTICAL 503s both finish the turn; an identical 500 still stops at its ceiling and is
named; `repeats_are_a_wall` is false for a link, a 503, a 504/408/425/429/529 and the vault 502, and
true for a 500.

## MUST 2 - the storm test must be the real storm

Commit **7136beed**. The previous Rust test was not the storm, and I could not make it one: with three
real `wa` processes, real binding ticks and a TCP proxy that cut the link, the failure was always
reproducible with a ZERO-second cut, which no product bug explains and no proxy bug does either. An
instrument that is the least reliable part of a test proves nothing, and I stopped pouring rounds into
it rather than claim a green I had not measured.

What is in the gate is `scripts/test-network-outage-tick.lua` (74 checks), against the REAL modules:

* `lua/core/binding.lua M.tick` - the actual poll/attach loop the transport runs, with real native
  binding state;
* `lua/core/nodes.lua remote_call` - the actual caller, with its real roster, slot and retry;
* a 60 s outage in which the tick runs on EVERY second;
* the restore: the node polls again with no restart and reports `attached`;
* a caller that sends one relayed call and holds the node's own verified answer;
* no slot left held afterwards.

**It fails on the base with the storm's own reason:** the 19/11 deadlock, where a failed `/register`
returned before the poll. Base: `polls 0 -> 0`. Here: the poll happens, the node stays attached.

What it does NOT do, and I will not imply otherwise: separate OS processes and a separate registry
process. That gap is the limit of this row.

## SHOULDs

* **The tick polls when the authority cache expires** (`af57d840`): an aged-out cache used to return
  early, the same trap one step later; it now polls and names the expired cache.
* **Register retries back off** (`af57d840`): jittered, doubling, capped at 30 s, while the poll keeps
  its 2 s rhythm - a fleet returning at once is what filled the cap on 19/11.
* **Transport bodies decode safely** (`af57d840`): the three raw `json.decode` calls on roster/lookup
  replies go through `decode_body`.
* **The per-peer counter: MOVED, not done here** (`0be976a7` drops it). Review r4 moved the per-peer
  call cap to the **fabric-transport** mission, where the relay and the caller path are redesigned;
  testing it against today's transport would be work on the wrong base. What remains in `nodes.lua` is
  the per-INTERPRETER cap and it is honest about that scope: it stops one interpreter from putting
  unbounded calls on a peer, and it does not bind another process.
  The node-wide version was written and then discarded, and it carried a real defect worth recording:
  it formatted `host.now()` with `%d`, and this host answers a FLOAT, so the first call raised
  "number has no integer representation" - a fast-path row caught it.
* **Report numbering** (`883a6853`): items 1-4 and 5-8 as the brief splits them.
* **The register-backoff comment matches the code** (`0a441a35`): the ceiling is 16 s, because the
  exponent caps at five FAILURES, not at 30 seconds.
* **The outage row asserts what its header promises** (`74012053`): the register backoff is asserted
  (growing, with a 16 s ceiling), so the sentence is no longer an unkept promise.
* **Dedupe** (`af57d840` report update): the duplicate lines are gone from this file.

## The product bug this round found

The multi-process attempt did produce one real finding: `unreachable_detail` did not recognise
`peer disconnected`, `binding_http_nil`, `connection closed`, `unexpected eof`, `broken pipe` or
`os error 10053`. During a cut the tick answered `binding_approval_unavailable /
binding_http_nil:io: Peer disconnected`, matched nothing, and stopped polling for the rest of the
outage. Fixed in **7e50b670**'s follow-up inside `af57d840`'s tree (the allow-list now carries every
transport word for a dropped link).

## Tests, and where each is wired

| Row | Checks | Wired in |
|---|---|---|
| `test-network-outage-tick.lua` | 74 | `scripts/test.sh` |
| `test-network-outage-recovery.lua` | 34 | `scripts/test.sh` |
| `test-network-roster-offline.lua` | 24 | `scripts/test.sh` |
| `test-network-relay-backpressure.lua` | 393 | `scripts/test.sh` |
| `test-network-binding-outage.lua` | 19 | `scripts/test.sh` |
| `test-provider-rate-limit-recovery.lua` | 41 | already in the gate |

Each creates its own scratch `WASM_AGENT_HOME` and refuses a real home.

**The fast path, run on this tree at `0be976a7`, quoting its own verdict line:**

```
fast result ok (301 checks, 0 failed, 0 skipped)
fast path ok (301 checks, 0 skipped, 202s)
```

It found three failures first, and two of them were MINE - the third round of "the gate caught what my
own runs did not":

* `test-network-roster-offline.lua` failed at "a live read lists the peer": my `decode_body` was
  DEFINED below its first use, so the call was a nil function swallowed by the surrounding `pcall` and
  the roster read silently returned nothing. Fixed by moving the definition above `fetch_peers`.
* `test-refusal-contract.lua` failed on a stale registry after my new codes. Regenerated.
* `test-remote-refusals.lua` failed on `bad argument #3 to 'format' (number has no integer
  representation)`: the file-based slot counter formatted `host.now()` - a FLOAT on this host - with
  `%d`. That is the counter review r4 moved to fabric-transport, and it is now dropped.

**Pre-existing failure, named:** `scripts/test-remote-refusals.lua:108` fails on `ac7717e0` too.
