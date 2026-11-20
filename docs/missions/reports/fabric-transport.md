# PHASE 0 — the fabric measured on main 39bbf2b6: what a fan-out costs today

Branch `wa/fabric-bench`, base `origin/main` = 39bbf2b6 ("land 2b: merge change/tui-polish-3").
This branch is **PHASE 0 only**: the harness, its judge, its gate row and this report. No Lua, no Rust,
no relay change. Scratch-only: a local rendezvous and scratch nodes on 127.0.0.1, never the live fleet.

| commit | what |
| --- | --- |
| 1c048fef | `scripts/bench-fabric-transport.mjs` — the PHASE 0 harness (serial, fan-out, storm; per-node CPU from /proc). |
| e27f1445 | `scripts/test-fabric-bench.mjs` — the harness's judge, wired into `scripts/test.sh` beside the binding rows. |
| a3ae1d7a | the judge's guard test creates the base it points at (its first form failed ENOENT, not on the guard). |

Build note, so the next phase does not lose an hour to it: this tree's binary needs
`WA_CODEMODE_ALLOW_EMPTY=1` (or prepared code-mode assets, `wa-capabilities/build.rs:44`), and
`CARGO_TARGET_DIR` moves the binary out of `rust/target`. A `cargo build … | tail` **hides cargo's
exit status** — a build here "passed" with rc 0 from `tail` and produced no binary. The binary also
**embeds the Lua core**, so a changed Lua module only runs after a rebuild.

## What the harness does

It starts the shipped path and measures it; nothing is re-implemented:

~~~
caller: wa call <peer-id> bash '{"command":"timeout 1 sh -c \"while :; do :; done\""}'
  -> rendezvous /relay/send        (signed envelope, one held connection per call)
  -> target /relay/poll            (relay_client.rs, the node's poll lane, cap 3)
  -> target serve loop             (serve.rs, node-thread 0 runs the call, one at a time)
  -> target /relay/respond         -> the caller collects it
~~~

* one scratch rendezvous and N scratch `wa serve` nodes, each with its own `WASM_AGENT_HOME` under
  `/tmp/wa-fabric-bench-*`; the whole inherited `WASM_AGENT_*`/`WA_*` environment is dropped for every child;
* the harness **refuses** a scratch root that overlaps the real node home (and the judge proves the refusal fires);
* peers are addressed by **node id**: a serving node re-announces itself under its host name on its own
  heartbeat (`[rendezvous] … re-registered as 'host' (was 'target1')`, measured in the first smoke run);
* CPU is attributed per node from /proc **two ways** — the process tree of `wa serve` *and* the node home in a
  process's environment. The second is not decoration: the shell a relayed `bash` call forks is **not** a
  descendant of `wa serve` here (a tree-only number was 2.6 CPU-seconds against 16 burned). Whatever neither
  can claim is reported as `unattributed_cpu_seconds`, never folded into a node's number.

Run it: `node scripts/bench-fabric-transport.mjs --binary <wa> --targets 4 --jobs 64 --burn-ms 1000`,
plus `--storm --cut-seconds 60`. Judge: `node scripts/test-fabric-bench.mjs <wa>` — 13 checks, green here.

## The brief's premises, re-measured on 39bbf2b6

| # | premise in the brief | measured on this base | verdict |
| --- | --- | --- | --- |
| 1 | a node answers relayed calls 3 at a time | `relay_client.rs:47-52`: `WA_RELAY_CONCURRENCY`, clamp 1..8, default 3; every serve log in the run shows `running=N/3` | **confirmed** |
| 2 | rendezvous is thread-per-connection, MAX_CONNECTIONS 256 | `rendezvous.rs`: one thread per socket; `MAX_CONNECTIONS 256` (`:1392`), `WA_RENDEZVOUS_MAX_CONNECTIONS` override (`:1387`); since the 19/11 storm the listener also **reserves lanes** and **sheds fairly**: `MAX_IN_FLIGHT_PER_CALLER = 8` (`:1442`) and `MAX_QUEUED_PER_TARGET = 32` (`:1445`), answered 503 `relay_busy` with `retry_after_ms: 2000` | **confirmed, and the shed gate is the new binding wall** |
| 3 | callers retry with no backoff | **wrong on this base.** `nodes.lua:666` sleeps `M.relay_backoff_ms(attempt)` (750 ms doubling, capped 8 s, jittered ×0.5-1.5); `:641` does the same with a hint; `M.RELAY_MAX_IN_FLIGHT = 4` (`:869`) caps one interpreter's calls per peer | stale premise |
| 4 | every answer needs a live binding check against the same rendezvous | `bindings::permits` is checked for sender and target on every `/relay/send`; it answers **true** when a node has no binding row ("existing protocol-1 installations"), so the check is conditional and is a SQLite read on the hot path | **half true** |
| 5 | avell and the laptop talk through Oracle for every call | **not measured**, deliberately: it needs the live fleet, which this branch may not touch (rule 13). The harness reproduces the shape (every call through the rendezvous, no direct endpoint) on one host | unmeasured here |

## The measurement

Host: avell, 16 logical cores, 31 GB, Linux; another session's build was running (its CPU lands in
`unattributed`, 5.36 s of this run). Binary: this branch's, built from 39bbf2b6.

### One call at a time (10 calls, 1 s CPU burn each, one node, nothing else running)

| n | p50 | p95 | p99 | max | mean |
| --- | --- | --- | --- | --- | --- |
| 10 | **1478 ms** | 2262 ms | 2262 ms | 2262 ms | 1531 ms |

The burn is 1000 ms, so ~480 ms is the call as a caller pays it — most of it `wa call`'s own process
start, not the wire.

### 4 x cores jobs over 4 nodes (64 concurrent calls, 1 s each) — the shape the brief asks for

| number | value |
| --- | --- |
| jobs / targets | 64 / 4, **one caller node** |
| **answered** | **8** |
| **failed** | **56 — 52 `remote_error:relay_busy`, 4 `remote_error:node_busy`** |
| calls/s | 0.85 |
| wall | 9.4 s |
| latency, answered calls | p50 **3895 ms**, p95 9418 ms |
| CPU into work | **0.84 of 16 cores = 5.3 %** |
| rendezvous sockets | mean 10, peak 16 |
| rendezvous log | 19 `[relay] busy`, 0 abandon, 0 late, 0 `too_many_connections` |
| per-node logs | dispatches 15/4/4/4; node-side busy refusals 6/10/0/3 |

The wall is now the **relay's fair-shed gate**: 64 concurrent calls from **one** caller node are
counted as one caller (8 in flight, `rendezvous.rs:1442`), so 52 of them are refused before they are
ever queued. The node side is untouched and still runs one relayed call at a time (peak 1.05 cores per
node), which is why the CPU number does not move either way.

For comparison, the same fan-out measured on the previous base (ac7717e0, before the shed gate) answered
14 of 64, with 50 `node_busy` refusals and the same ~1 core per node: the shed gate moved *where* the
refusal happens (fast, at the relay), not how much work the fabric can carry.

### The storm: rendezvous frozen for 60 s, mid-fan-out (32 calls, 0.5 s each)

| number | value |
| --- | --- |
| answered / failed | 5 / 27 |
| failures | 24 `relay_busy`, 2 `node_not_attached`, 1 `node_no_answer` |
| wall | 62.1 s (cut at 2.06 s, resumed at 62.06 s) |
| successes after the resume | **0** |
| last failure | 62071 ms — **10 ms after the relay came back** |
| rendezvous log | 6 attach, 2 detach, 4 `[relay] late`, 15 busy |

This is the storm's worst shape: after the relay returns, the retries of one caller are themselves the
thing the per-caller gate counts, so the fan-out cannot re-establish inside the 60 s window — nothing
succeeded after the resume, and the run ends with every call refused. Whatever the outage does, the
recovery has to be measured, and on this base a single-caller fan-out has no recovery path.

## What this means for the later phases (measured, not planned)

* **Per-caller accounting is the binding constraint.** The relay allows 8 calls in flight **per caller
  node** and 32 queued per target (`rendezvous.rs:1442-1445`); the caller's own cap is 4 per interpreter
  (`nodes.lua:869`, in-process only, as its own comment says). A coordinator that wants 4 x cores
  calls in flight cannot get them through today's transport, whatever the nodes' capacity.
* **One interpreter per node runs one relayed call at a time** (peak 1.05 cores per node, 3-slot lane):
  the CPU ceiling for a fan-out is `targets`, not cores.
* **A 60 s relay outage leaves no recovery inside the next 60 s** for a single-caller fan-out (0 successes
  after the resume, above).

## Texts to approve

No model-facing string is added or changed: the harness and its judge are operator tools, and no Lua
prompt, tool schema, refusal or hint moved.

Operator-facing strings this branch introduces, verbatim:

* `bench: refusing to use a real node home (<home> overlaps <candidate>)`
* `bench: scratch home must carry the wa-fabric-bench- marker (<home>)`
* `bench: unknown argument <word>`
* `bench: timed out waiting for <label> (<last error>)`
* `bench: no binary at <path> (build it: cargo build --release --manifest-path rust/Cargo.toml)`
* `bench smoke: PASS <ok>/<jobs> calls answered, <p50> ms p50` / `bench smoke: FAIL <problems>`
* `SKIP test-fabric-bench: no binary at <path>`
* `test-fabric-bench: <n> checks`
* the stderr summary lines `serial: {…}`, `fanout: {…}`, `storm: {…}`, `kept: <root>`.

## What this branch did not do

* No PHASE 1/2/3 code and no claim that the ceiling moved: this branch is the instrument.
* No live-fleet measurement (rule 13): the Oracle hop in premise 5 stays unmeasured by this mission.
* No full gate run: the judge was run directly (13/13) and its row is wired into `scripts/test.sh`; the
  bench itself is not in `scripts/fast.sh` (a 75 MB release binary and ~10 s is the gate's budget).
* The storm's "no recovery" figure is one run of one shape (32 calls from one caller); it is reported as
  measured, not as a bound.
