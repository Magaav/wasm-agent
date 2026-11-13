# Kernel — from monolith to sharded WASI components (target architecture, v1 draft)

Status 2026-11-05: design. What exists today is in [COMPONENTS.md](COMPONENTS.md) (request
components) and [SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md) (long-lived services, with the
WhatsApp client live on openclaw as `wa-whatsapp`). This document is where that is heading and the
contract (WIT, in `wit/`) every module will be built against.

## Why

`wa` is one Rust binary (host + embedded Lua core + ~90 capabilities). Any change rebuilds and
redeploys all of it: ~10 min incremental, ~20 min cold on the laptop, and a full node restart. The
WhatsApp client built as a component showed the alternative: built once in ~4 min on wasm_the_first,
hash-verified, copied to an arm64 node, started without rebuilding or restarting anything. Build and
deploy time should scale with the module touched, not the system.

## Three layers

| layer | what | native? | changes |
| --- | --- | --- | --- |
| **watchdog** | starts the kernel, restarts it on crash, swaps the kernel binary on upgrade (keeps the old one until the new one is healthy) | yes — it must survive what it replaces | almost never |
| **microkernel** | wasm runtime; component loader + pin/signature check; capability broker implementing the `wa:kernel` WIT interfaces; supervisor (lifecycle, health, revocation, start-by-imports); registry + profiles; node identity + relay transport | yes — something native has to run wasm and touch the OS | rarely |
| **components** | everything with logic: agent loop, providers (DeepSeek, Anthropic…), tools, MCP servers, channels (WhatsApp, Telegram, mail), STT, OCR, code mode, graph index, policy (including the watchdog's upgrade policy) | no — pinned `.wasm` | constantly, independently |

The kernel cannot itself be wasm (something must host the runtime), but it is the only per-OS/CPU
binary, and components depend only on WIT, so any WASI runtime that implements `wa:kernel` (wasmtime
here; a browser via jco; a phone) can host the same modules. The sentinel of today shrinks to the
watchdog: with hot-swappable components, ordinary deploys are "verify pin, start new instance, wait
healthy, stop old" inside the kernel — no process restart.

## Lessons taken from DeepSeek Harness (study: deepseek-harness-study.md)

DSH (`deepseek-ai/deepseek-harness`) proves "everything is a plugin" for an agent harness: a ~7k-line
plugin kernel (Cordis) and ~380 plugins, including the agent loop. Taken, adapted to WASI:

1. **Capability seams.** Every capability is three parts: a WIT interface package, a provider
   component that exports it, consumer components that import it. Never one leg alone.
2. **Revocable registrations.** Everything a component registers through the broker (a tool, a route,
   a timer, a subscription) returns a handle the kernel revokes when the component stops or is
   replaced. Hot swap is then exact: nothing of the old instance lingers.
3. **Start by imports.** The supervisor starts a component when every interface it imports is served by
   a running provider (or by the kernel); configuration order means nothing.
4. **Profiles as layers.** The effective configuration is an ordered stack (base → node → user → patch),
   rows addressed by id; `wa profile dump` prints the effective result.
5. **Transactional installs.** Install = stage files → verify pin (and signature) → check the WIT
   versions it imports are served → start the new instance → health → switch → stop the old one. Any
   failure leaves the old instance running. Exact versions only. (DSH's own reload has a gap where a
   replacement that loads but fails to start is not rolled back; keeping the old instance until health
   closes it.)
6. **What we do not copy:** DSH runs all plugins in one process with full authority, does not scope
   credentials to their owner, has unsigned indexes and "pre-stable" APIs. Here: WASI isolation,
   manifest-declared capabilities with a granted subset, sha256 pins, **per-component credential
   scoping** in the broker, and semver'd WIT with never-rewritten vN→vN+1 migrations.

## The contract: `wa:kernel` WIT v1

Standard WASI first: `wasi:clocks`, `wasi:random` and `wasi:cli` (args/env/stdio) are used as they
are. `wa:kernel` adds only what WASI lacks, each interface a grant:

| interface | replaces today's | grant |
| --- | --- | --- |
| `wa:kernel/websocket` | `wa_ws` (wasip1 imports) | `net` addresses |
| `wa:kernel/kv` | `wa_kv` | `storage` (own namespace only) |
| `wa:kernel/lifecycle` | `wa_ctl.stopping` | always |
| `wa:kernel/log` | stdout/stderr to the service log | always |
| `wa:kernel/credentials` | `file_env` | named secrets scoped to this component |
| `wa:kernel/http` | `wa_http` | `net` addresses — a small non-blocking start/poll; standard `wasi:http` later (its host crate pulls hyper/tokio, against a light kernel) |

Capability seams defined next to it (providers to come): `wa:speech/recognizer` (STT),
`wa:vision/text-reader` (OCR), `wa:mcp/server` (tools list/call, the request-component shape),
`wa:channel/messages` (inbound/outbound for WhatsApp, Telegram, mail).

Worlds: `service` (long-lived: imports the kernel interfaces it needs, exports `lifecycle-handler`)
and `tool` (request: exports `wa:mcp/server`). See `wit/`.

Async: WIT v1 targets WASI preview 2 (sync calls + non-blocking polling), what the toolchains build
today. `wa:kernel@0.2` (below, step 1) is the same contract on WASI 0.3, where a slow call suspends and
one request can yield many items as a `stream<T>`; both versions are served side by side.

## Carve-out map (first pass, from the capability inventory in HOST.md)

| stays in the microkernel | becomes components |
| --- | --- |
| runtime, loader, pins (`components`, `service`, `component_mcp`, `plugins`, `invoke`) | `graph_*` (indexer, queries) — **done, stream C**: see "C1 results" below |
| node identity + transport (`node_identity`, `sign`, `verify`, `relay`, `binding_*`) | code mode (`quickjs` — already wasm) |
| supervised processes (`exec`, `operation`, `subagent`) — until a process-less design exists | providers and the agent loop (today in the Lua core) |
| durable state for the kernel itself (`sql_*`, `db_ready`; the `memory.db` file) | memory logic (`wa:memory` component, see below) · MCP servers (Node scripts → components, `mcp-whatsapp` done) |
| console/device I/O for the CLI (`terminal_*`, `input_*`, `panel`, `audio`) | channels (`wa-whatsapp` done; connector logic next) |
| files/paths under grants (`read_file`, `write_file`, `list_dir`, `grep`, `paths`) | STT, OCR (wasi-nn), file search |

The Lua core is the largest single block: the agent loop, tool dispatch, MCP and services registries.
Lua compiles to wasm, so it can move as one component first (the "agent" component) and then split
along the seams above.
Measured 05/11 ([benchmarks/lua-wasi-spike](../benchmarks/lua-wasi-spike/README.md)): wa-host's Lua 5.4
runs in a wasm32-wasip2 component with every `host.*` bridged through one generic import — ~1.45× on
pure-Lua compute, ~+0.8 µs per host call, `pcall` works (wasm exceptions) and is faster, instantiate
0.1–0.2 ms. Estimated ≈3.5–4.5 days to parity.

### A2.1 results (05/11, wasm_the_first)

`wa --core-component <agent-core.wasm> <script.lua> [args]` runs a script with the Lua core inside
the `agent-core` component ([rust/components/agent-core](../rust/components/agent-core), built by
`scripts/build-agent-core.sh`, 377 KB). Every `host.*` crosses one import, `wa:kernel/host.call`
([wit/kernel/host.wit](../wit/kernel/host.wit), world `core-component`), and the kernel answers it by
calling the capability's existing C function on a native Lua state booted like every other
interpreter (`rust/wa-capabilities/src/core_component.rs`), so nothing is reimplemented per guest. The guest
keeps the native boot: `host.*` resolves only names in the capability registry, `EMBEDDED` resolves
through the kernel (installed lua-core tree, else compiled in, assignment still overrides), `dofile`
is the native bootstrap byte for byte, `print` goes to stdout. The value variant has two members beyond
the first draft: `integer` (Lua 5.4 prints `5` and `5.0` differently) and `string-map` (results only;
`paths` and `platform` return flat string tables).

Same binary, same scripts, own home per run, 3 runs each (median wall time, ms):

| script | native | component | component `run` only | host calls |
| --- | --- | --- | --- | --- |
| test-mcp-component (24 checks) | 5756 ✅ | 6170 ✅ | 5725 | 1 137 |
| test-service-component (23) | 1524 ✅ | 1920 ✅ | 1482 | ~1.9 M (polling loop) |
| test-batch-tools (245) | 5347 ✅ | 8124 ✅ | 7671 | 29 079 |
| test-tool-cues (120) | 726 ✅ | 1154 ✅ | 731 | 1 838 |

The fixed cost is compilation: 364–391 ms per cold load; with the compiled-code cache
(`~/.wasm-agent/cache/core-component`, keyed by module sha256 + engine hash) a load is ~1 ms and
instantiation 0.13–0.25 ms. I/O-bound scripts then run at native speed; Lua-compute-heavy ones
(batch-tools: JSON and string work) are ~1.45×, as the spike measured. `scripts/test.sh` runs three
of these through the component when wasi-sdk is present and says it skipped them otherwise.

Refused in v1 with `unsupported_in_component_v1:<name>`: `http_sse` (Lua line callback),
`input_start`, `input_editor`, `input_commands`, `input_held`, `input_take`, `input_stop`,
`input_idle`, `editor_status`, `editor_footer`, `panel`, `ticker` (the live console), plus any call
whose argument is a function or a table. `http_stream` crosses (four strings in, JSON out).
**A2.2, below, lifted the `http_sse`, table-argument and console-output refusals**; the interactive
reader and a function argument stay refused, now naming the reason.
WASI side: stdio and env inherited, the working directory preopened as `.` (so `io.open` on an
absolute path fails in the guest; the core reads files through `host.read_file`), `os.execute`,
`os.tmpname`, `io.popen` and `io.tmpfile` fail.

### WASI 0.3 step 0 — wasmtime 50 and native async (05/11, wasm_the_first)

The runtime is on **wasmtime 50.0.1** (`wasmtime` + `wasmtime-wasi`; the `anyhow` feature is now
needed because `wasmtime::Error` is no longer `anyhow::Error`). Same binary: `cargo test --release
-p wa-host` passed all 201 tests, and the component / service / agent-core blocks of `scripts/test.sh`
run for real (24 + 23 + 245 checks, and the svc-echo service end to end). (Since the crate split those
tests live in `wa-kernel-runtime` and `wa-capabilities`; `scripts/test.sh` runs them there.)

What the upgrade needed, in the order it bites:

| where | 37 → 50 |
| --- | --- |
| `service_components.rs` (bindgen `with`) | a resource is named `wa:kernel/websocket.socket`, not `wa:kernel/websocket/socket` |
| `core_component.rs` | `DirPerms`/`FilePerms` → `FsPerms::ReadWrite`; `LinkOptions::cli_exit_with_code` is gone (exit-with-code is always linked) → `p2::add_to_linker_sync` |
| `quickjs.rs` | the six `func_wrap` closures return `wasmtime::Result` (`.map_err(wasmtime::Error::from_anyhow)`) |
| `services.rs` | the epoch callback returns `wasmtime::Error::msg("service_stopped")` |
| `components.rs` | **capability regression, found and fixed**: 50's `AllowedNetworkUses::default()` denies TCP and UDP (37 wrote both `true`), and the address check is now also asked about the *implicit* wildcard bind of `connect` (37 checked only the address the guest named). With grant enforcement unchanged, every `TcpStream::connect` in a component failed with EACCES; `scripts/test-component-whatsapp-parity.mjs` was the test that said so |
| `scripts/test.sh` | the component and agent-core blocks unset `CARGO_TARGET_DIR`: each component is its own cargo workspace and `build-components.sh` reads `rust/components/<name>/target/<target>/release/`, so a redirected gate target dir installed nothing and silently turned three blocks into skips |

Spike (`benchmarks/wasi03-spike`): a `wasm32-wasip2` guest (wit-bindgen 0.63, 70 KB, WASI 0.2 imports
beside the async ABI) exports `run: async func` and reads inbound frames from a host resource as
`stream<list<u8>>`; the host side is a `StreamProducer` over a channel fed by a task, driven by
`store.run_concurrent`. Per frame, end to end (host task → channel → producer → guest `next().await`):
**~2.6 µs** (10 000 × 512 B in 25.6 ms; 100 000 × 64 B in 266 ms), instantiate 0.2–0.3 ms, compile
72–76 ms. The 4 KiB / 100 µs case measures the Windows timer (15.6 ms), not wasm. A WhatsApp pump is
tens of messages per second, so native async costs nothing this project can measure.

C verdict: wit-bindgen 0.63 *does* generate async for C — `crates/c/src/lib.rs:generate_async_helpers`
(waitable sets, subtask/stream/future events, callback codes) with upstream `.c` runtime tests under
`tests/runtime/simple-stream*`, `simple-future`, `pending-import` — but only at the raw ABI level:
there is no high-level `await`. The Lua core is C and single-threaded, so step 0 keeps every `host.*`
a **sync** call and leaves the waiting to the host, which already owns the runtime. Async `host.*` for
Lua is a step of its own, not a precondition for changing the WIT.

Proposed `wa:kernel@0.2` — async only where the host may have to wait on a peer, `stream<T>` wherever
one request can yield many items, everything local staying sync:

```wit
// websocket: the pump itself becomes the stream, recv + poll disappear
resource socket {
  messages: func() -> stream<list<u8>>;
  send: async func(frame: list<u8>) -> result<_, send-error>;
  close: func(code: u16, reason: string);
}
// http: one async call instead of start/poll; the body is a stream in both directions
send: async func(request: request) -> result<response, http-error>;
// speech: segments arrive while the recognizer is still listening
recognize: async func(request: recognize-request) -> stream<segment>;
// kv (put/get/del/del_prefix/scan), log, lifecycle: unchanged, sync — a local store answer is
// sub-millisecond and a stream would buy nothing.
```

### A2.2 results — `http_sse` and the live console as streams (05/11, wasm_the_first)

A2.1 refused every capability that takes a Lua callback, every call carrying a table argument, and
all twelve console capabilities. A2.2 removes the first two and most of the third **without changing
the Lua-facing API**: `lua/core` is untouched, because the guest-side shim keeps
`host.http_sse(method, url, headers_json, body, on_line, timeout?)` exactly as the native interpreter
has it, and a table argument now arrives as a table.

**`http_sse` as a stream.** A guest cannot be re-entered while it is blocked inside a host call, so
the kernel runs the *unchanged* native `http_sse` (`rust/wa-capabilities/src/host.rs`) on a thread of its own,
with the guest's line callback replaced by one that hands each line over and blocks for the guest's
verdict. `wa:kernel/host` grew three functions beside `call` — `open`/`next`/`close`, with
`next: func(handle, option<verdict>) -> result<option<list<u8>>, string>` — and `glue.c` loops over
them calling the script's own callback. Because the request, the timeouts, the cancellation, the
budget, the termination names and the JSON answer are the native code's, the answer is byte-identical
to a native call's, including `callback_stopped` when the callback returns `false` and
`line_callback_failed` when it raises. A verdict travels with the *next* pull and is `none` on the
first call, which is what stops the read running ahead of the guest deciding about the last line —
the one defect the first version had (a `stop` then ended the read one line late, `lines:4` instead
of `lines:3`), caught by the parity test and not by review.

Why not `stream<list<u8>>` yet: the C guest has the async ABI but no `await` ("WASI 0.3 step 0"
above), so a `stream<T>` would still be pulled one item at a time from Lua's point of view and would
have to be waited on by hand for nothing. The sync handle is the cheap direction today, and its
contract — one item per call, nothing read ahead — is what a `stream<list<u8>>` replaces later
without the Lua changing.

**Table arguments.** A Lua table crosses as JSON (`value.json`), so the capability receives a real
table instead of a refusal: arrays, objects and nesting round-trip, and `1` stays an integer while
`1.0` stays a float (Lua prints them differently, so the encoder keeps the `.0`). A table JSON cannot
carry — holding a function/thread/userdata, a key that is neither a string nor an array index, a
non-finite number, or a non-UTF-8 string — is refused naming the cause. Function arguments are still
refused except for the callback `http_sse` owns. **Results are unchanged** (a scalar or a flat string
map): the guest has no JSON decoder, so a table result the kernel cannot place is still refused
rather than encoded. That gap is the recursive `list`/`map` variant or a decoder in the guest.

**The console.** `ticker`, `panel`, `editor_status` and `editor_footer` cross now and answer exactly
what they answer to a native `wa run` with no CLI in front of them (`nil`, `{"action":"unsupported"}`,
`false`) — same binary, same script, same output. What stays refused is the interactive **reader**
(`input_start/editor/commands/held/take/stop/idle`), now with a reason: a `--core-component` run has
no editor to read into, and starting the reader would take the guest's own stdin. `lua/core/chat.lua`
already guards every one of those on `input.editor`, so nothing in the core calls them in a
non-interactive run.

Same binary, same script, fresh home and ledger per run, release build, median of 3, wall ms:

| script | checks | native | component | component `run` only |
| --- | --- | --- | --- | --- |
| test-mcp-component | 24 | 5 807 | 6 238 | 5 777 |
| test-service-component | 38 | 4 762 | 5 289 | 4 813 |
| test-batch-tools | 245 | 4 897 | 7 543 | 6 945 |
| test-tool-cues | 120 | 722 | 1 173 | 729 |
| core-component streams (new) | 31 | 302 | 676 | — |

Every block's output is identical between the two modes except `test-batch-tools`' two
`*_measurement` rows, whose `wall_ms` and byte counts differ between any two runs of the *same* mode
(`scripts/test.sh` already matches only its `batch tools ok` line). Compilation is the component's
fixed cost here: 362–402 ms per cold load on this machine — the `cwasm` cache in
`$HOME/.wasm-agent/cache/core-component` did not hit in the MSYS shell these numbers were taken in
(`HOME` is `/c/Users/...`, which the kernel resolves as a relative path), so every run paid it.

The new `scripts/fixtures/core-component-streams.lua` (a fixture, not a standalone fast-path test: it
needs a server) runs its checks in **both** modes, and `scripts/test-core-component-streams.mjs` fails
when the two outputs differ (one local SSE stub on
127.0.0.1, no internet): lines in order with the blank ones counted, `callback_stopped`,
`line_callback_failed` with the callback's own text, a 500 as `http_error` with its body, the three
pre-socket refusals in the native words, a line delivered while the socket is still open (the stub
holds it 250 ms after the first line, so a buffered reader would fail the timing check), table
arguments in three shapes, and the four console answers above. What it does **not** cover: a ticker
that actually draws (its animation frames go to the same stdout, so the harness runs with
`WASM_AGENT_CLI_TICKER=off` and the `true` answer is unverified), and `input_start`/`input_stop`
end-to-end (the native side would start the CLI's reader; their refusal is a unit test in
`core_component.rs`). A stream the script abandons is stopped when the handle is dropped, not joined:
the reader thread exits at its next line or read timeout, which is fine for the one-stream-at-a-time
foreground use and a thing to revisit before anything opens streams concurrently.
### A2.3 results — an instance pool and a boot snapshot for agent-core (06/11, wasm_the_first)

`--core-component` is one guest for one script, so every turn used to pay: a compile (365–525 ms cold,
1–4 ms from the `cwasm` cache), an instantiation (0.13–0.25 ms), the guest's own Lua boot, and the
answers the guest asks the kernel for on the way in (the capability registry's names, the shipping
modules' sources). A node that answers turns, subagent turns and node-thread reads wants those once,
not per turn. A2.3 adds a pooling engine, a bounded instance pool and an instance-level snapshot, and
measures each.

**A pooling engine.** `wa-kernel-runtime::components::pooled_engine(&PoolLimits)` builds an engine on
wasmtime's pooling allocator (`InstanceAllocationStrategy::Pooling`, crate feature
`pooling-allocator`): every slot's memories, tables and stacks are reserved up front, so a node's wasm
footprint is a number in `PoolLimits` rather than whatever a guest happened to ask for, and creating an
instance is a slot reset instead of fresh mappings. It is deliberately **a separate engine** from
`components::engine()`: the reservation bounds the engine, so the MCP and service runners keep the
on-demand engine that lets an arbitrarily large component start, and only agent-core pays. Two things
the engine does *not* have: epoch interruption (a deadline needs a ticker thread and a per-store
deadline; enabling the feature with neither traps every guest on its first instruction — measured as
`wasm trap: interrupt` on the pool's first run), and therefore a per-run time budget, which a runaway
script never had under `--core-component` either.

**The pool.** `wa-capabilities::core_component::{CoreComponentPool, CorePoolConfig, CoreInstance}`:
`acquire()` (an idle instance, else a new one while the pool is below `max_instances`, else wait up to
`acquire_timeout` and answer `pool_exhausted`), `run_script(script, args)` → `RunReport { code,
host_calls, streams_open, first_host_call_ms, run_ms, memory_bytes, runs_on_instance }`, and release by
dropping the lease (or `release()`), which clears the per-run state and aborts any stream the run left
open. `warm(n)` pre-creates instances, `try_acquire()` never waits, `stats()` reports
created/idle/leased/peak/acquisitions/reuses/exhausted/runs. A `max_instances` above the allocator's
`component_instances` is refused at construction, not on the ninth acquire of a serving node. A store
that *trapped* cannot serve another run, so that instance is dropped and the pool's count corrected
instead of handing a broken store to the next caller.

Thread safety is the simple kind: a lease owns its `Store` and the instance's only reference to it, so
one instance serves one caller at a time and nothing else touches it. **One native interpreter, and one
SQLite connection, per instance** — not one shared interpreter behind host calls. A `lua_State` is
single-threaded by construction, the upvalue-bound capabilities hold a raw pointer into that state's
`Host`, and `Host` owns the interpreter's own connection (a transaction one interpreter holds open must
not be visible to, or rolled back by, another). Sharing one would put a mutex around every `host.*`
call — 29 079 of them in `test-batch-tools`, which is exactly what a pool exists to avoid — and would
give every instance one transaction space. The bound is the pool's `max_instances`, and the cost is one
interpreter boot each (0.26–0.38 ms): the pool keeps that instead of paying it per run.

**The snapshot.** The guest (`rust/components/agent-core/glue.c`) now caches, for the life of the
*instance*, the two answers it would otherwise re-ask on every run: the registry's names (`__names`)
and the shipping modules' sources (`__embedded`, which the native interpreter reads into `EMBEDDED`
once at boot). Every run still gets a **fresh `lua_State`**, so globals, `package.loaded` and the stack
are exactly as fresh as a one-shot run promises; only the kernel's immutable boot answers survive. A
wizer-style pre-init is not the shape here: the world exports only `run`, so there is no "boot without
a script" entry to freeze, and what the guest asks for at run time includes the *node's* installed
lua-core tree, which a build-time snapshot would bake stale. So the snapshot is the immutable part of
the boot, reused — not a cloned live state.

`rust/wa-core-pool-bench bench` (a workspace member, not part of the binary;
[benchmarks/agent-core-pool](../benchmarks/agent-core-pool/README.md)): medians of 5 per run, the range
across four runs, release, `agent-core.wasm` 388 439 B:

| measurement | value |
| --- | --- |
| native interpreter boot (per instance, kept across runs) | 0.26–0.52 ms |
| cold: new pool (engine + compiled component + instance + run) | 1.8–2.7 ms |
| cold: compile alone, no `cwasm` cache | 525–1 175 ms |
| to first Lua statement: cold / pooled (unrun instance) / snapshotted (warm instance) | 0.23–0.26 / 0.43–0.78 / 0.07–0.13 ms |
| run, after the first statement: cold / pooled / snapshotted | 0.72–0.77 / 0.34–0.60 / 0.27–0.46 ms |
| host calls per run: pooled → snapshotted | 6 → 4 |
| guest linear memory per instance (after a run) | 1 152 KiB |
| pooling allocator reservation (8 instances × 256 MiB cap) | 2 048 MiB virtual |

The snapshot's 2 host calls are its whole point: from run 2 an instance asks the kernel neither for the
registry's names nor for a module's source, and the measured effect is `to first statement`
0.43–0.78 → 0.07–0.13 ms and `run` 0.34–0.60 → 0.27–0.46 ms. The module is still parsed per run — a compiled-chunk cache
keyed by the source's sha256 is the next step, and would be safe because the key carries the content.

The four gate scripts, same guest, same environment, medians of 5 (wall ms, `benchmarks/agent-core-pool/bench.sh`;
every script's output identical between the component and pooled columns except `test-batch-tools`' two
wall_ms rows, which differ between any two runs of the same mode):

| script | checks | native | component | pooled | native/component | native/pooled |
| --- | --- | --- | --- | --- | --- | --- |
| test-mcp-component | 24 | 5 757 | 6 264 | 5 839 | 1.09× | 1.01× |
| test-service-component | 38 | 5 085 | 5 745 | 5 064 | 1.13× | 1.00× |
| test-batch-tools | 245 | 6 267 | 9 296 | 7 391 | 1.48× | 1.18× |
| test-tool-cues | 120 | 711 | 1 179 | 754 | 1.66× | 1.06× |

Read that carefully: part of the component column is a *per-process* cost and not the guest's — the
binary's boot (ripgrep provisioning, plugin scan, graph configuration) and, in an MSYS shell where
`$HOME` is a `/c/...` path the kernel cannot resolve, a missed `cwasm` cache and therefore a ~0.4–0.6 s
compile on every run. `wa-core-pool-bench` is a leaner process and its per-slot interpreter is booted
from the registry alone, so the pooled column is "a turn from a process that already exists", which is
what `serve` and its subagents are. The Lua-compute gap A2.1 measured on `test-batch-tools` (1.45×,
re-measured here at 1.48×) narrows to **1.18×** once the per-turn fixed costs are gone; what is left is
the guest's own Lua running ~1.2× slower than native Lua, which pooling cannot change — the remaining
distance is inside the interpreter, not around it.

Tests: `cargo test -p wa-capabilities core_component` (11 tests, 6 of them new: acquire/run/release with
the report, a reused instance keeping each run's state fresh, four callers each getting their own
instance, an exhausted pool refusing after its timeout and recovering, a pool larger than its allocator
refused, and a warmed pool handing out unrun instances). `scripts/test.sh`'s core-component block now
also runs the four scripts through the pool, `diff`s one whole output against the one-shot component
run, and runs four concurrent callers holding four leases (`pool concurrency ok`). The fixtures are in
[benchmarks/agent-core-pool/fixtures](../benchmarks/agent-core-pool/fixtures).

**a23fix — the pool and the rest of the process.** Two things the first landing got wrong, both about
cost paid *outside* the pool's own callers:

1. **`boot_native_state` no longer rewrites the process environment.** It used to `std::env::set_var`
   `HOME`, `WASM_AGENT_DB` and every `KEY=VALUE` of `~/.wasm-agent/env`. That is defensible for the
   binary, which is one node in one process, but this function exists for callers *outside* it — the
   tests and `wa-core-pool-bench` — and it runs once per pool slot: in the `wa-capabilities` test binary
   it changed what the other 160 tests and their subprocesses saw (a `HOME` pointing at the pool's
   scratch directory, a `WASM_AGENT_DB` of `:memory:`, a node's provider keys copied into a process that
   never asked for them) and it outlived the run. It also only half-worked on Windows, where the UCRT
   caches the environment at startup: Rust readers saw the new `HOME`, the C side did not — which is
   exactly why `host.getenv` exists. The boot now publishes the same values through the capability
   layer's override map only, and the two Rust readers that resolve a home (`host.paths()` and the
   plugin directory) use `host::resolved_env`, the same order `host.getenv` uses, so a pooled slot still
   resolves the node's home and not the operator's.
2. **The pool's tests run one at a time.** A pool is the heaviest thing that test binary builds — a
   pooling engine with its slot reservation, a compile of the 388 kB guest, up to eight native
   interpreters and four wasm instances running at once. `http_transport`'s streaming tests sit in the
   same binary and assert on wall-clock budgets (250 ms to response headers, 500 ms of body silence,
   read from the socket this crate owns), so they measure the *process's* scheduling, not just the
   provider's silence: with seven pools live they fail on a loaded machine, and the pool is what put the
   process there. The pool tests take a process-wide test lock, and `scripts/fast.sh` gives the
   streaming tests their own process (the rest of the crate with `--skip http_transport::
   streaming_timeout_tests`, then that module alone) so a future heavy test cannot starve them either.
   Nothing is skipped or weakened: the same five assertions run, in a process that is quiet when they
   measure.

**Not done here, and why.** The pool has no caller in the binary yet: `rust/wa-host` (its `main.rs`
boot and CLI dispatch) was outside this lane's edit list, so the callers today are
`wa-core-pool-bench` and the gate block. Wiring it is a small change in `main.rs` — hand
`CoreComponentPool` the existing `interpreter_factory` and take a lease in `serve`, in the subagent
supervisor and in a node-thread read — and it belongs with the WASI 0.3 work, where the same pool also
gets an async `run` and a per-turn deadline. Also unmeasured: resident memory with 8 live instances
(the 1 152 KiB figure is one instance's linear memory; 2 048 MiB is the allocator's *virtual*
reservation, not resident bytes), and several concurrent streams (one run per lease, one lease per
caller, is what the pool promises; several streams inside one run stay A2.2's one-at-a-time foreground
contract).

### A2.4 results — serve, node threads and subagents on the component core (06/11, wasm_the_first)

The pool had no caller in the binary (A2.3, "Not done here"); it has one now, behind a switch.

**The switch.** `core = "component" | "native"`, default `native`, resolved once at startup in this
order: `--core` on the command line, then `WASM_AGENT_CORE` (which `<home>/.wasm-agent/env` also
supplies), then a `core` key in `<home>/.wasm-agent/config.json`, then native. The source of the
answer is printed at startup (`[serve] core = component (--core): …`), an unknown value is refused
with `core_mode_invalid`, and a node asked for the component core without an `agent-core.wasm`
refuses to start rather than serve the other one. `/health` carries `core: {mode: …}` on every node
and, on the component core, the pool's own counters.

**What runs where.** One seam, `core_bridge::Core`, is either the native `Lua` the node always used
or a lease from the A2.3 pool. Everything the serving layer asks of an interpreter is
`call_string(name, args)`, so the switch is one enum at the bottom of `serve.rs`; admission, the
scheduler, the socket lanes, run events, cancellation and the hooks/selfloop paths are unchanged.
On the component core these all come from the pool: node-thread 0, every read/control node-thread,
the control (admission) interpreter, the placement interpreter (the 2 s `wa_orchestrator_tick` that
fires wakes), and every subagent turn (`subagents::set_runner`, one lease per child turn). The pool
is sized from the node's own configuration — `node_thread_slots() + subagent concurrency + 3`, and
`WASM_AGENT_CORE_POOL_MAX` / `WASM_AGENT_CORE_POOL_WARM` override it.

**How a call crosses.** The guest exports `run(entry, args) -> result<_, string>`, whose `ok` payload
is unit, so a call cannot return a value. The bridge runs one dispatch script
(`rust/wa-capabilities/src/core_bridge.rs`) that boots `lua/core/server.lua` (and
`lua/core/subagents.lua` only for the calls that need it), calls the named global with the arguments
the kernel passed as the guest's `args`, and writes `status\npayload` through `host.write_file` into
`<home>/.wasm-agent/core-bridge/<pid>-<n>.reply`; the kernel reads it, deletes it and returns the
payload. A `pcall` around the call turns a Lua error into the `Err` half of `call_string` in the
script's own words; `core_bridge_*` names the bridge's own failures and none of them is silent.
Every `host.*` still crosses A2.1's one import and is answered by the instance's own native
interpreter **on the caller's thread** — which is why a run's SSE sink, cancel flag and run id
(thread-locals of the node thread) still reach the guest's `host.stream` unchanged.

**State.** Each run gets a fresh `lua_State` (A2.3), so a node thread rebuilds the Lua core per
request and conversation state comes from the database, exactly as it does for a fresh `wa run`.
What that changes: `local agent` and the in-Lua caches are rebuilt per request (correct, and slower —
see the numbers), and the pending `/bind` confirmation table in `server.lua` does not survive between
requests. A long-lived guest (one Lua state per node thread, work items delivered through the bridge)
would fix both, and it is blocked on the guest: `run` creates the state and returns, and the run's
thread-local context (sink, cancel, run id) is installed by the node thread, so a guest loop would
need the context to travel with each work item — a guest-side export (`run_loop`/`call`) or the WASI
0.3 async `run`. `rust/components` is outside this lane's edit list.

**Parity.** `scripts/test-core-parity.sh` runs every self-contained `scripts/test-*.lua` the fast
path runs (115 of them, `scripts/fast-path.exclude` respected) twice — `WA_SCRIPT=…` and
`--core-component agent_core.wasm` — with its own scratch home and ledger each, and diffs the
normalized outputs (uuids, `Nms` timings, `cpu_seconds`, `wall_ms`, the scratch path, chunk names).

| result | scripts |
| --- | --- |
| pass on both cores, identical output | **100/115** |
| fail identically on both cores (environment, not the core) | 12/115 |
| differ | 3/115 |

The 12 both-fail are `test-codemode-*` (the QuickJS sandbox assets are absent in this checkout),
`test-graph-*` (the `graph` component is not installed), `test-patch-audit`, `test-toolcall-gate` and
`test-experiment-verify` (a fixture fact that no longer matches `lua/core/agent.lua`): they fail the
same way natively, so they say nothing about the component either way, and the harness counts them
separately rather than as passes. The three that differ:

* `test-cli-ticker`, `test-cli-view` — the console ticker draws one more frame inside the component
  (1.0 s instead of 0.9 s; `test-cli-view` prints two frames natively none). The checks pass in both
  (232 checks); the difference is that `host.ticker`'s animation is answered by the slot's native
  interpreter, whose stdout/`isatty` state is not the CLI's. Cosmetic, CLI-only, and not on any
  `serve` path.
* `test-completion-packet` — the fixture calls `os.remove(<absolute path>)`, which fails in the guest:
  WASI preopens the process cwd as `.` (A2.1), so Lua-level `io`/`os` file calls on an absolute path
  fail while every `host.*` file call works. The core itself never does this; the test fixture does.

**Serve smoke.** `scripts/test-serve-core-component.sh` starts the same node on both cores (a stub
OpenAI-shaped model on loopback, scratch home and ledger per mode, every `WASM_AGENT_*` of the
calling shell dropped) and compares the behaviour, not the log: three `/chat` turns (all `stub-ok`),
one `UserPromptSubmit` hook (6 payloads on both), one subagent (`completed`/`stub-ok` on both) and
one self-wake — a turn whose prompt makes the stub answer with a `wake` tool call, after which the
node's own placement tick fires a `[self-wake · smoke]` turn with no further request from the
harness (1 on both). Identical on both cores.

**Cost.** `scripts/bench-serve-core-component.sh`, release build, one node per core, the same stub
model, medians of 10 turns (each in its own thread) after two warm-up turns:

| measurement | native | component | component/native |
| --- | --- | --- | --- |
| turn (`POST /chat`, stub model) | 220 ms | 1 410 ms | 6.4× (+1 190 ms) |
| read (`GET /sessions`) | 10.5 ms | 357 ms | 34× (+346 ms) |
| serve process RSS after the run | 108 MiB | 185 MiB | +77 MiB |

The component column is almost entirely the guest's own boot: `guest_run_ms / calls` is ~680 ms per
call, of which `lua/core/server.lua`'s module bodies (and `memory.setup()` on a real database) are the
bulk — parsing is only ~15 ms for seven modules. Loading `lua/core/subagents.lua` lazily for the calls
that need it already took the turn from 3 213 ms to 1 410 ms and the read from 888 ms to 357 ms; the
rest needs the long-lived guest described above, not a cheaper boot. Memory: the pool's allocator
reserves `max_instances × 256 MiB` of *virtual* address space per node (10 instances here), and the
resident cost measured is +77 MiB with 4 instances alive.

**Not done, and why.** (1) The long-lived guest, as above. (2) `wa --core-component <wasm> <script>`
and `WA_SCRIPT` are unchanged: they are one-shot runs, not a node. (3) The component is found by
`WA_AGENT_CORE_WASM`, then `<components dir>/agent-core.wasm`, then the checkout's build — a deploy
that installs a pinned `agent-core.wasm` needs no flag. (4) Epoch interruption is still off on the
pooling engine (A2.3), so a wedged guest has no per-run deadline; the stall watchdog reports it
exactly as it reports a wedged native interpreter.

### A2.5 results — the node's own zone in the guest (06/11, pi deepseek)

A2.4 shipped a node that can serve a whole turn from the guest while reading the wrong clock. The
guest's C runtime is wasi-libc, which ships no zone database: `os.date` inside the component is UTC
whatever zone the node is in, so `platform.local_clock()` — the `time` tool and the platform line of
the prompt — answered `+00:00` on a node in `-03:00`. The native core was right, because its C runtime
is the OS's. Nothing else diverged, which is what made it a quiet bug.

**The inequality, fixed at its root.** The kernel answers a new bridge call, `host.local_tz(epoch?)`
(`rust/wa-capabilities/src/core_component.rs`, `KERNEL_CALLS`), and it answers it in two halves that
are deliberately different in kind:

* the **offset** and the **zone abbreviation** are the C runtime's, produced by running
  `lua/core/platform.lua`'s `runtime_clock` in the instance's *native* interpreter. That is the same
  function, the same `tzset` and the same DST rules the native core calls, so the two cores agree by
  construction rather than by two implementations that mostly match;
* the **identifier** of the zone (`America/Sao_Paulo` on Unix, `E. South America Standard Time` on
  Windows) comes from `rust/wa-local-tz`, which reads `TZ`, the `/etc/localtime` link, `/etc/timezone`
  or `GetDynamicTimeZoneInformation`. The C runtime cannot portably name its zone, and a guest can
  read none of those.

`local_tz` is a kernel call and not a capability: there is no native `host.*` C function to forward it
to, so it does not come from `capabilities::REGISTRY` — it is listed in `__names` beside the registry so
a guest's `if host.local_tz then` still reads the truth. It costs one `lua_pcallk` on the instance's
native interpreter and a resolve of the zone name, per call, never cached: an offset read at boot is
exactly the stale answer a DST change produces.

**The Lua side.** `platform.local_clock` asks the host first and falls back to the C runtime, so a
native run takes the branch it always took — same fields, same values, no new behaviour. The host
branch builds `local_iso` from the UTC fields of the instant the reported offset puts it at (the
guest's own `os.date` is UTC), takes the weekday from the same shifted instant, and carries the two new
fields `zone_id`/`zone_source`. `platform.describe()` names the zone by `zone` when the platform has an
abbreviation and by `zone_id` otherwise, so the prompt line on a Windows node no longer says "zone name
unknown". A host that has the call and fails is a Lua error, not a silent fall back to the guest's UTC:
that silence *was* the defect.

**Measured.** `scripts/test-local-tz.lua` (new, in the fast path) prints the fields for a fixed instant
and `scripts/test-core-parity.sh` diffs the two cores; the same instant read through both, on a Windows
node whose own zone is `-03:00`:

| `TZ` | native | component |
| --- | --- | --- |
| unset | `-180`, `-03:00`, `E. South America Standard Time`, `2026-01-15T09:00:00-03:00` | identical |
| `America/Sao_Paulo` | same line | identical |
| `UTC` | `0`, `+00:00`, `UTC`, `2026-01-15T12:00:00+00:00` | identical |

A container with no `TZ` and no zone files reports `+00:00`, `zone_source=none` and no `zone_id`: UTC
honestly, never a guessed name (`wa-local-tz`'s `a_bare_container_reports_no_name_and_says_so`). The
Windows CRT parses a POSIX rule and ignores an IANA name in `TZ` (measured: `TZ=Europe/Berlin` leaves
the machine's offset and abbreviation untouched, `TZ=UTC` takes effect), which is why `TZ` naming a zone
this platform has no database for answers `zone_source=tz_env_unknown` and no name instead of claiming
the operator's string.

Tests: `cargo test -p wa-local-tz` (9, all pure: the rule with the filesystem questions injected) and
`cargo test -p wa-capabilities` (`the_node_zone_is_a_kernel_call_and_never_a_silent_utc`,
`the_kernel_answers_the_node_zone_with_the_runtime_offset_and_the_os_name`,
`the_same_instant_reads_the_same_on_both_cores` — the last one reads the instant through the native
interpreter and through the real guest and compares them field for field, with a mutation check: an
hour added inside the host branch makes it fail with both lines in the message).

**Not done, and why.** (1) `wa-local-tz` reports the Windows zone *key* on Windows, not an IANA name: a
mapping is CLDR's `windowsZones` table, and a partial one would be worse than the OS's own identifier.
(2) The native core gets no `host.local_tz` (it needs no offset help and the registry is the native
capability list), so `zone_id` is absent from a native `local_clock` — which is why the parity test does
not print it. (3) `docs/HOST.md`'s "The clock" section describes the native contract and should gain a
sentence about `zone_id`/`zone_source`; that file belongs to another lane.
### A2.5 results — a long-lived agent-core guest, a deadline and a memory knob (07/11, wasm_the_first)

A2.4's cost had one cause: every request rebuilt the Lua core inside the guest (`lua/core/server.lua`'s
module bodies plus `memory.setup()`), and its state could not survive between requests — `local agent` and the pending
`/bind` table in `server.lua` were recreated per turn. A2.4 listed the fix and why it was not possible
yet: `run(entry, args)` creates the `lua_State` and returns. A2.5 adds the second entry point and turns
on the two engine knobs that were waiting.

**The guest exports `call` (and `reset`).** `wit/kernel/host.wit`'s world `core-component` now has
`call(name, args) -> result<string, string>` beside `run` and `reset()`. `call` runs the named global on
the instance's **own** `lua_State`: the first call boots it (`lua/core/server.lua`, and
`lua/core/subagents.lua` the first time an item needs it), every later call reuses it. A node thread —
which leases once and keeps the lease for its life — therefore boots the core once, not once per
request, and `local agent`, `package.loaded` and the in-Lua caches are the ones the native interpreter
has. `run` is unchanged, which is what `wa --core-component` and `CoreComponentPool::run_script` still
use: a one-shot run keeps its promise of a fresh interpreter per run.

**Nothing of the run lives in the guest.** The work item carries its own context: `serve` installs the
item's sink, cancel flag and run id on the node thread before it calls in (as it always did), the bridge
copies the item's arguments in, the guest copies the answer out. The guest holds no run id, no sink and
no thread-local, which is exactly what makes a `lua_State` that outlives one request sound. The old
per-call reply file (`<home>/.wasm-agent/core-bridge/<pid>-<n>.reply`) is gone with the dispatch script:
a call writes nothing to disk and answers in the `Result<String, String>` the native
`Lua::call_string` returns.

**A lease resets the core; an instance does not.** A retired node thread is replaced in the same pool
slot, and a subagent turn leases per turn (a native subagent turn builds its own interpreter), so the
pool calls the guest's `reset` when a lease goes back. The persistence guarantee is therefore "one
`lua_State` per **lease**", which is "per node thread" because that is how `serve` leases — and a fresh
caller never inherits a previous one's `local agent` or its pending `/bind` table.

**Epoch interruption on the pooling engine, with a per-run deadline.** `wa_kernel_runtime`'s
`pooled_engine` keeps the feature off on purpose (A2.3: the feature without a ticker traps every guest
on its first instruction, and that engine is shared with callers that have no budget). The pool is the
caller that has one, so it builds its own engine — `rust/wa-capabilities/src/core_pool.rs`, same
`PoolLimits`, plus `epoch_interruption(true)` and one ticker thread (10 ms ticks, stopped when the engine
is dropped) — and every store gets a deadline armed **per work item** (`CorePoolConfig::run_deadline`,
`WASM_AGENT_CORE_RUN_DEADLINE_MS`, default 60 s, `0` = none). A guest that reaches it is interrupted,
that item fails with `core_bridge_run_deadline`, the pool counts it (`core.deadlines`) and the instance
is retired — and the lease takes a replacement from the pool, so the failure belongs to the item and not
to every later request on that node thread. What the budget counts is guest instructions: a run blocked
in a host call (the model, an HTTP read, an SSE stream) is not executing wasm and is not interrupted.
Measured cost of the boot it must not trip over: ~600 ms of guest instructions for the first call on an
instance (2.4 s in a debug host build), which is why the default is a minute and not a second.

**The memory knob.** The pooling allocator reserves `limits.memories` linear-memory slots of
`limits.max_memory_bytes` each, so A2.4's numbers (`memories = 40`, 256 MiB) reserved 10 GiB of address
space for a node sized for ten instances, and grew with neither the instance count nor anything a guest
measured. `CorePoolConfig::pooled(instances, warm, reserve)` now sizes `memories` from the instance
count (`instances + 8`) and takes the one-memory cap from `WASM_AGENT_CORE_POOL_RESERVE_MB` (default
64 MiB). A node sized for 16 node threads (23 instances) reserves **31 × 64 MiB ≈ 2 GiB** of address
space instead of 10 GiB, and `/health`'s `core` block reports `reservation_bytes` and
`run_deadline_ms` beside the counters, so the number is an operator's and not an allocator's default.
The guests measured 1-3 MiB of linear memory; 64 MiB is the headroom for a Lua-heavy turn
(`test-batch-tools`' 245 checks run inside it), and cutting it further is a knob with a measurement
behind it rather than a guess.

**Cost.** `scripts/bench-serve-core-component.sh <port> 10 4`, release build, one node per core, the
same stub model, medians of 10 turns (each in its own thread) after two warm-up turns, four alternating
rounds — the modes run one after the other on a machine that is also an operator's desktop (`wa-sentinel`
and two browsers were live), so a pair from a quiet minute and one from a busy minute are two samples of
the same two cores:

| round | turn native / component | read native / component | component/native (turn, read) |
| --- | --- | --- | --- |
| 1 | 319 / 351 ms | 7.0 / 9.0 ms | 1.10× , 1.29× |
| 2 | 222 / 412 ms | 9.5 / 11.5 ms | 1.86× , 1.21× |
| 3 | 316 / 546 ms | 11.0 / 28.5 ms | 1.73× , 2.59× |
| 4 | 706 / 728 ms | 30.5 / 38.5 ms | 1.03× , 1.26× |
| **median** | 318 / 479 ms | 10 / 20 ms | **1.42× , 1.28×** |
| serve RSS after the run | 110 MiB | 190 MiB | +80 MiB |

A2.4 measured 1 410 ms per turn and 357 ms per read on the same pair of cores (6.4× and 34× native).
The variance here is the host's, not the core's: the same native node answers a turn in 222 ms in one
round and 706 ms in another, and the component node's per-round ratio moves from 1.03× to 1.86× with
it. What the numbers support is that the per-request boot is gone — the component column sits inside
the native column's noise band — and that the target (turn ≤ 1.5×, read ≤ 3×) holds at the median of
those rounds (1.42× / 1.28×); a run on a quiet machine (this session's first, 1 round) measured 1.17×
and 2.00×. `/health` at the end of a round: `calls=41-48`, `boots=4` (one per instance), so the guest's
boot is paid once per instance and not per call — a per-request boot would make those two numbers equal.
The `guest_run_ms / calls` figure (a round here: 6.3-20.6 s over 41-48 calls) is *time inside the core
call*, which includes the model call the core makes, so it is not a boot measure and is not used as one.

**Parity is unchanged.** `scripts/test-core-parity.sh` runs the fast path's self-contained Lua tests
once natively and once through the one-shot `--core-component` path, whose guest `run` A2.5 refactored
(the boot's tables moved into one `install_globals` both entry points use). Result: **100/115 identical, 12/115 fail identically on both
cores, 3/115 differ** — the same three A2.4 had (`test-cli-ticker` and `test-cli-view` draw one extra
ticker frame from the slot's interpreter, `test-completion-packet` calls `os.remove` on an absolute path
the guest has no preopen for), and the same 12 environment failures (`test-codemode-*` without the QuickJS
assets, `test-graph-*` without the component, `test-patch-audit`, `test-toolcall-gate`,
`test-experiment-verify`, `test-capability-inventory`). No new difference, which is what the refactor had
to prove.

**Serve smoke, with the long-lived core.** `scripts/test-serve-core-component.sh` (three `/chat` turns,
one `UserPromptSubmit` hook, one subagent, one self-wake) passes identically on both cores. It now also
checks the thing this step is about, semantically rather than by latency: `/health` counts the core calls
and how many of them had to boot the guest (`core.boots`, the first item on an instance or on a lease
after its reset), and the smoke fails when more than half of the calls booted — a per-request `lua_State`
would make those two numbers equal, which is exactly A2.4's shape. The last run reported `46 core calls,
6 of them booted the guest`. `guest_run_ms` is *not* that check: it is time inside the core call and
includes the model call the core makes, so it measures the stub as much as the boot.

**Tests.** `cargo test -p wa-capabilities core_pool core_bridge` — `core_pool`'s 2 (the tick
arithmetic; the engine really has epoch interruption and its ticker), and `core_bridge`'s 5 new ones:
one `lua_State` across work items (a probe module the factory publishes in `EMBEDDED` answers `1`, `2`,
`3` where A2.4 answered `1` three times), a released lease handing out a fresh core, a wedged guest
(`while true do end`) hitting its deadline, being counted, and its lease getting a replacement instance
— plus the two A2.4 tests (a call from inside the guest, a Lua error keeping its own text) unchanged.
The pool's own A2.3 tests still pass on the epoch engine.

**Not done here.** (1) A subagent turn still leases per turn, so it still pays the guest boot once per
turn: a small warm pool of subagent cores, or keeping a subagent's lease across its own tool loop, is
the next step and moves ~600 ms off the subagent path. (2) The reservation is address space, not RSS:
`+80-99 MiB` resident with 4-5 instances alive is measured and the ~1.94 GiB figure is reserved. (3) A lease's
replacement after a deadline trap is a fresh instance (`created` churns by one): a node that wedges a
guest often enough pays instantiations, which is visible in `/health` (`instances`, `deadlines`) rather
than silent. (4) `wa --core-component` keeps no state between runs — the one-shot promise — so the CLI
cannot demonstrate what a node thread's second request gets; the Rust tests do.

### C1 results — the code graph as a component (05/11, wasm_the_first)

The graph is the first capability moved out of `wa` without touching Lua. The 14 `host.graph_*`
functions keep their names, arguments and answer shapes; `rust/wa-capabilities/src/graph.rs` is now a kernel
shim that forwards each call to the `graph` component
([rust/components/graph](../rust/components/graph), wasm32-wasip2, 8.2 MB — tree-sitter's grammars
and SQLite are C, so building it needs wasi-sdk) through `components::mcp`, one run per call. `wa`
no longer links tree-sitter or `wa-graph`: 35.4 MB → 29.0 MB, and a graph change no longer rebuilds
the kernel.

What stayed in the kernel is what a per-call guest cannot do: choose the root and database, mount
them (the new `dirs` grant: the root read-only at `/graph/root`, a private database directory
read-write at `/graph/db`), serialize calls per database (a mutex plus `.<db>.lock`, which other
processes also take) and schedule refreshes from edit hints and the OS watcher. The component is
stateless: every call admits content first (capture → compare with the committed manifest → index
the changes as revision committed+1) and then reads one pinned snapshot, so an answer is never
older than the bytes on disk when the call began.

Measured on this repository (1,533 files, 57,364 definitions, 167,878 edges); native = `wa` from
origin/main b56485e2 with wa-graph in-process, component = this tree's `wa` with the `graph`
component; same tree indexed by both, a fresh database per run, 3 runs each, medians of
`benchmarks/graph-component/bench.lua`:

| call | native | component | ratio |
| --- | --- | --- | --- |
| `index` (cold, 1,533 files) | 50,607 ms | 577,625 ms | 11.4× |
| `index` (nothing changed) | 306 ms | 3,840 ms | 12.5× |
| `query` | 433 ms | 5,570 ms | 12.9× |
| `search` | 652 ms | 4,192 ms | 6.4× |
| `explain` | 286 ms | 3,589 ms | 12.6× |
| `caps` | 489 ms | 7,883 ms | 16.1× |

Three defects the previous WIP commit hid, all found by running the tests it lacked:

- The kernel's cross-process lock was `<db>.lock`, and SQLite inside the guest locks through the
  same name (its dot-file style; the `%s.lock` literal is in the wasm, and a directory appeared at
  that path during a call). A lock file at that path made SQLite treat every transaction as
  contended: 22 s of busy timeout, then `graph_index_failed: database is locked`. The kernel's file
  is now `.<db>.lock`.
- A component run killed mid-transaction leaves the guest's lock behind, and then every later write
  answers `database is locked` for the whole busy timeout. Holding the kernel lock proves no graph
  call on that database is running, so a `<db>.lock` found at that point is stale and is removed.
- When the `db` option names a path under the indexed root (`test-graph-freshness` does), an index
  run writes the database, its rollback journal and both lock files inside the watched tree. The
  watcher counted those writes as edits, so one refresh scheduled the next forever: `active` and
  `dirty_hint` never settled and `ready` never came back. The database's own files are now excluded
  by name, and `status.ready` is the component's own byte-for-byte verdict rather than "nothing is
  queued".

The cost is the finding. A per-call guest pays the whole admission again on every call: capture and
hash the tree, then compare it with every stored source blob in a 75 MB database, and every one of
those pages crosses the WASI boundary instead of staying in the host's page cache. That is 11.4× on
a cold build and 12.5× on a call that changes nothing; a `graph_search` on this repository goes from
652 ms to 4,192 ms. Correct, exact, and too slow to navigate a repository of this size from a cold
node: an index run now gets a 900 s budget (`INDEX_BUDGET` in graph.rs) because this tree needs
577,625 ms once, and a read that would have to build a cold graph keeps the caller's 60 s wait and
answers "use read/grep" while the background build finishes. On a small tree the same code is
~12× native too (`rust/` alone: cold 1.7 s native, 19.7 s component), so this is the shape of the
design, not a constant to tune.

What the WASI 0.3 / wasmtime 50 upgrade should change here, in order:

1. **A long-lived instance, not one run per call.** The graph is a service with state (an open
   SQLite connection and its page cache); the MCP-over-stdio run is the reason none of it survives.
   The typed `wa:mcp/server` export, hosted once per database, removes the spawn per call and keeps
   the cache warm. This is the single change that matters most.
2. **Native async for the build.** `future<T>`/`stream<T>` let the index run as a background task
   that yields instead of holding the caller's deadline, so `serve` can build a cold graph without a
   10-minute request and without the 900 s budget.
3. **A cheaper admission.** The exactness check reads every stored source blob; storing the manifest
   hash per file and comparing hashes (the bytes stay for `source`/`sources`) would cut the per-call
   read in half without weakening "never older than the disk". The kernel's watcher state can then
   decide when a full capture is needed at all.
4. **A temp directory in the grant.** SQLite spills temp tables and large sorts to `TMPDIR`, which a
   guest has none of: an index of this tree died with `graph_index_failed: disk I/O error` after
   parsing 1,533 files. It runs with `temp_store=MEMORY` today (bounded by the guest's 256 MB), which
   is a workaround for a missing mount, not a design.

### WASI 0.3 step 1 — `wa:kernel@0.2` served (05/11, wasm_the_first)

The proposed shape above is now a package, a runner and two fixtures:
`wit/kernel-v2/kernel.wit` is `wa:kernel@0.2.0`; `rust/wa-kernel-runtime/src/service_components_v2.rs` serves it;
`rust/components/svc-echo` is a 0.2 component and `rust/components/svc-echo-v1` the same fixture on
0.1 (the compat proof). `wa-whatsapp` is ported and builds for `wasm32-wasip2` against 0.2.

**Contract** (differs from the sketch above where noted):

| item | 0.2 |
| --- | --- |
| `websocket` | `connect` is `async`; `messages() -> stream<list<u8>>` is the inbound pump; `send: async func(frame)` suspends instead of dropping; `close(code, reason)` |
| `http` | `send: async func(request) -> result<response, error>`; `response` is a resource with `status`, `headers`, `body() -> stream<list<u8>>` |
| `speech` | `recognize: async func(...)` → resource `recognition` with `segments() -> stream<segment>` and `transcript() -> future<result<transcript, error>>` (`result` is a WIT keyword, so the future's accessor is `transcript`; each `segment` carries `start-ms`/`end-ms`) |
| `kv` | `get/set/delete/delete-prefix/scan` are `async` (the host answers without suspending); the names stay 0.1's so a port is a mechanical `await` |
| `lifecycle`, `log`, `credentials` | unchanged |
| `drain` (new, optional) | the cooperative hot swap: `draining: func() -> bool` is the kernel's "take no new work", `idle: func()` is the guest's "nothing in flight, stop me". Not in `world service-component` - a world's imports are obligations, so a component *opts in by importing it*, and that import is what a swap reads from the artifact to know whether waiting is meaningful. A component without it is stopped immediately, as before (`docs/SERVICE-COMPONENTS.md`, "A swap waits for the work in flight") |
| `service` | `run: async func(config: string) -> result<_, string>` |
| timers | `import wasi:clocks/monotonic-clock@0.3.0` — `wait-for`/`wait-until` are the async timers a guest awaits. Not `wa:kernel`: this is WASI 0.3, served by `wasmtime_wasi::p3::clocks` |

**Why the out direction is one `async` call per frame.** The sketch drew `stream<list<u8>>` in both
directions. A guest→host stream has to be created by the guest and consumed by the host, so every
sender would build a stream per Noise frame — the opposite of what the protocol does. `send` suspends
when the host cannot take the frame, which is the property the out stream was for.

**Runner.** Same grants, limits, log and epoch deadline as 0.1; a component is served by the 0.1
runner or the 0.2 one according to *its own imports* (`wa:kernel/*@0.2.0`), read from the component
type by an engine with `component-model-async`. A 0.1 component is then compiled again on the engine
every other component uses, so nothing about 0.1 changes. The 0.2 engine is separate on purpose:
`components::engine()` is shared with MCP components and agent-core.

**Swap, drained.** `services::replace` asks a 0.2 instance that imports `wa:kernel/drain@0.2.0` to
finish the job in hand before it stops it (`rust/wa-kernel-runtime/src/drain.rs`). Before this, a
swap stopped the old instance and handed its in-flight queue leases to the new one, which then ran a
job whose effect could already be half-applied: safe (the queue's fencing refuses a second settle)
but a second attempt at work that never failed. The drain removes that for the components that
implement it, and the deadline path (`WA_SERVICE_DRAIN_MS`, 30 s) keeps the old behaviour for the
ones that do not - including every 0.1 component and every wasip1 module, which have no hook at all.

Two things the async path needed that the poll path did not:

- **A runtime for timers.** `wasmtime_wasi`'s WASI 0.3 clock is built on tokio's timer, so the 0.2
  runner owns a current-thread tokio runtime (`rt` + `time`) and drives the guest with
  `store.run_concurrent`.
- **A watchdog for a parked guest.** The epoch deadline traps a guest that is *running*; a guest
  sitting in `wait-for` has no wasm to interrupt, so `services::stop` would never join its thread.
  After the grace period the runner drops the guest's future instead (measured: stop returns in
  under a second with the fixture parked in a 300 ms timer).

**Results** (`cargo test -p wa-host` at the time - today `-p wa-kernel-runtime -- service_components_v2::tests` - debug build, 206 tests): the three service fixtures each run
end to end — wasip1 core module, 0.1 component, 0.2 component — including a granted and a refused
`net` dial against real local servers, a kv round trip, a websocket echo read over the inbound
stream, a clean stop, and the restart path. The 0.2 guest's heartbeat is a WASI 0.3 timer.
`wa-whatsapp`'s 0.2 component (8 MB) compiles and **instantiates** on the 0.2 runner, which is the
check that every import name it emits is served (`WA_TEST_WHATSAPP_WASM` in
`service_components_v2::tests`). One expressiveness loss: `exit_3` cannot be named — `wasi:cli/exit`
takes a `result`, so a component that exits non-zero is reported as `exit_1`.

### WASI 0.3 step 2 — every interface, under the grant policy (07/11, pi deepseek on wasm_the_first)

The 0.2 runner used to link WASI wholesale: `wasmtime_wasi::p2::add_to_linker_async` plus the 0.3
clock. That is one switch for everything, and it cannot express "this component may read its granted
directory but not the network". It now links **one interface at a time**, from
`rust/wa-kernel-runtime/src/wasi_grants.rs`, and every tier B interface is decided by the same two
layers as the `wa:kernel` calls (manifest grant, then `policy.json`):

| tier | interfaces | gate |
| --- | --- | --- |
| A | clocks, random, `wasi:cli/{exit,stdout,stderr,terminal-*,types}`, `wasi:io/*` | none: nothing outside the component is reachable |
| B | filesystem, sockets, `cli/environment`, `cli/stdin`, keyvalue, config | manifest capability + policy rule, with a scope, audited per decision |
| C | TLS, vault/secrets, logging, node policy, deploy, mesh, machine control, shell | never linked: the component is refused before wasm starts, with the interface named |

[WASI-INTERFACES.md](WASI-INTERFACES.md) is the table (and the code's own table is kept equal to it by
a test): every interface, its tier, the manifest key and the policy capability. `wa:http` is not
shipped by `wasmtime` 50 at all, so outgoing HTTP stays `wa:kernel/http`; keyvalue and config are
served by wa itself as `wa:kernel/{keyvalue,config}`, over the component's own kv namespace and its
granted config.

Two details worth knowing when reading the runner:

- **A refused import is a refused start**, not a link error. `check_imports` walks the component's
  `wasi:` imports before instantiation and answers `wasi_import_<reason>:<interface>`, which the
  supervisor records as `last_exit` and the component's log repeats. `imports.rs` asks the same table
  whether the kernel *serves* an interface, so a tier C import shows up as `waiting for <interface>`
  at install time instead of a mysterious failure.
- **A `std`-built component imports the whole preview-2 cli surface** whether or not it uses it
  (measured: `wasi:cli/{environment,exit,stderr,stdin,stdout,terminal-*}@0.2.9` in each fixture). So
  `cli/environment` and `cli/stdin` at `@0.2.x` are linked for every component and carry no
  capability (empty list, empty pipe); the `@0.3.0` spellings are tier B and need the grant.

**Known limits, next.** A response body is buffered whole and handed out in 64 KiB chunks (a real
streaming download needs a reader thread, not `read_to_vec`); the send backpressure is the channel
bound, not the TCP window; a 0.1 component is compiled twice at start; and `wa-whatsapp` was not run
against a phone from this lane (no pairing, no messages — see
[SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md)).

### A2.6 results — what a turn's crossings and the pool's deadline cost (07/11, pi deepseek on wasm_the_first)

A2.4 measured the component core at 1.42x native for a turn and 1.28x for a read on this host, and left
the split unexplained. This pass profiles one serving node and cuts what the profile pointed at. The
measurement harnesses are in the tree, so the numbers below can be taken again on any node:

| script | what it measures |
| --- | --- |
| `scripts/bench-core-profile.sh` | one serve turn's crossings, per `host.*` name, with bytes and handler time (`WA_CORE_CALL_PROFILE=1` in `core_component.rs`) |
| `scripts/bench-core-bridge.sh` | the interpreter factor and one crossing's cost, native vs component, on identical fixtures |
| `scripts/bench-core-epoch.sh` | what `Config::epoch_interruption` costs the guest, with nothing else different |

**The profile (20 turns, 12 + 2 work items per turn).** A turn is one big `call` item of ~1080
crossings plus a handful of small ones. Before this pass, the biggest item of a turn was: `read_file`
250 crossings / 2.37 MB out, `sha256` 248 crossings / 2.58 MB in (the module boot: read the text, then
send the same text back to be hashed), `getenv` 335, `sql_exec` 42, `sql_query` 50, `stream` 15,
`http_stream` 1 (the 26 KB model request, the only JSON-table argument on the hot path), one
`system_resources`. Table arguments are rare (JSON decode 0.3-3.8 ms per turn) and a crossing's own
machinery is ~0.9 us, so **the crossings were not the cost: the copied bytes and the engine's
compile-time configuration were**.

**What was changed, each measured on its own** (medians; this host was shared with other builds, so
every number below is quoted beside its A/B pair rather than across runs):

| change | measured effect |
| --- | --- |
| guest built `-O3` + fat LTO + one codegen unit (`rust/components/agent-core/Cargo.toml`, `build.rs`: Lua's C at `-O3`) | pure-Lua loop 0.95x (5% faster); wasm 394 KB -> 393 KB |
| the boot asks for text and digest in one typed crossing (`__source` / `__module` in `glue.c`, answered by `core_component.rs`) | per turn: crossings 1082 -> 877, bytes *into* the guest 2.68 MB -> 0.32 MB; the `dofile` fixture's per-op cost over native 24-41 us -> 21-27 us; the guest's RSS 200 -> 181 MiB |
| pool engine chosen by the deadline: `run_deadline == ZERO` now takes `pooled_engine` (no epoch checks, no ticker) instead of `epoch_engine` | pure-Lua loop 1.28x -> 0.99x of the one-shot engine (that is, the epoch checks were the whole of it); serving node, deadline off vs default: turn 0.92x, read 0.81x |

`wasm-opt` was not available offline on this host, so the binaryen step is **not** in the numbers above;
`cargo build` with `-O3`/LTO is. Cranelift's `opt_level` was confirmed to be `Speed` already (wasmtime's
default, set nowhere in this tree), so no change was made there.

**The finding worth carrying forward.** `epoch_interruption(true)` is what gives a work item its
deadline, and wasmtime pays for it by compiling a check into every function entry and loop back-edge.
On a pure-Lua loop that check costs **1.28-1.38x the guest's own time** — more than running the
interpreter in wasm costs at all (1.1-1.3x native on the same fixtures). `serve` configures the pool
with `DEFAULT_RUN_DEADLINE` (60 s), so every turn pays it for a protection that fires on a wedged guest.
It is now a knob a caller opts into: `WASM_AGENT_CORE_RUN_DEADLINE_MS=0` means no deadline and
therefore no epoch checks. The default is unchanged — losing the deadline is a policy decision, not a
benchmark result.

**Not done, and why.** Typed WIT records for the three most frequent calls: those three (`getenv`,
`__source`/`read_file`, `sha256`) already cross as `bytes`/integers, so a record would replace nothing.
The JSON that remains on the hot path is `http_stream`'s model request, once per turn.

### A2.7 results — the compiled-module cache: a turn stops paying to compile what it already compiled (07/11, pi deepseek)

A2.6 cut the boot's crossings and the bytes *into* the guest (2.68 MB → 0.32 MB per turn), but the
profile's biggest item was still `__source`: **205 module loads per turn, 2.37 MB of module text copied
into the guest, and a Lua compile for every one of them.** The turn's item was 877 crossings, 327 KB in,
2.42 MB out, 236 ms of guest time. The modules are not re-booted by a new `lua_State` (a node thread
keeps its lease; `/health` counts 4-5 boots over ~60 calls) — they are *re-`dofile`d* every turn, because
`dofile` is the core's module system (`server.lua`'s own body, plus every lazily-loaded module a turn
touches, all go through it). Each of those loads read the file, copied the text into the guest and
compiled it again.

**The change: a compiled-chunk cache in the guest, keyed by the module's digest.** `glue.c` keeps the
bytecode of every module it has compiled (it survives `wa_core_reset`, which drops the `lua_State`, not
the cache). A load now asks the kernel one new question — `__digest(path)` (a file) or `__edigest(path)`
(the shipping `EMBEDDED` tree) — which answers the SHA-256 of exactly the bytes `__source` would hand
over, in 64 bytes instead of thousands. Same digest as last time: `luaL_loadbufferx` the chunk. Different
digest (a new `WASM_AGENT_LUA_ROOT`, a `/update`, an edited module): forget that chunk, take the text as
before, compile it, dump it with `lua_dump` (debug information kept, so a module's error still names the
file and line) and keep it. The chunk name is the same `@<path>`, `LOADED_SOURCES[path]` is the same
digest, and a module that cannot be read answers `nil`, so `dofile`'s errors are the ones it always had.
The digest is the kernel's answer about the file *now*, revalidated by `(len, mtime)` so a boot pays one
`metadata` call per module instead of a read and a hash — the cache is a check on the file, never a
memory of it. Both halves live in one place each: `glue.c` (`__load`, `module_store`/`module_find`) and
`core_component.rs` (`__digest`, `__edigest`, and the two digest maps in `State`).

**Why not a Wizer-style pre-initialized image.** The guest's boot calls `wa:kernel/host` (`getenv`,
`__names`, the module reads), and Wizer works by running the guest to snapshot it: it would need a live
kernel connected at build time, and no `wizer` is vendored offline in this tree. A bytecode cache needs
nothing but the interpreter the guest already contains, and it survives the reset that a pre-initialized
*instance* would not (the pool re-instantiates nothing; it resets a `lua_State`). It is also the only one
of the two that helps the case measured here: the 205 loads happen inside a *live* state, so a snapshot
of a freshly booted state would not have removed any of them.

**Also cut, in the same pass.** `dofile` used to call `host.getenv('WASM_AGENT_LUA_ROOT')` per module
(~205 crossings a turn): the root is read once per boot now (`install_globals`, published as `__root` for
`dofile`'s own error text). Nothing in the guest can change it (`host` has no `setenv`), and native's
`dofile` still reads it per call, so the two agree on everything a script can observe.

**`core.boots` was under-counting, and now means what it says.** `core_bridge` incremented `boots` when
`runs_on_instance == 1`, i.e. once per *instance*, which is why A2.5 read `boots=4` and concluded "one
boot per instance" while every turn was in fact re-loading the module tree. A `Slot` now carries a
`booted` flag that `reset`/`return_to_pool` clears and the next item reports (`RunReport::booted`,
`CallReport::booted`), so `boots` counts the items that really booted a `lua_State`. Measured on the smoke
run: **5 of 59 calls** booted the guest — the module *loads* per turn were never boots, and the counter
could not have shown that before.

**The profile, 20 turns + 20 reads, before → after** (this host, `scripts/bench-core-profile.sh`; the
per-item rows are averages over the marked items, the turn rows are one turn's own item):

| per turn's main item | before | after |
| --- | --- | --- |
| crossings | 877 | 672 |
| bytes into the guest | 2.42 MB | 55 KB |
| bytes out of the guest (arguments) | 327 KB | 323 KB |
| guest + crossing time | 236 ms (of 428 ms) | 33 ms (of 182 ms) |
| `__source` | 205 calls / 2.37 MB | none on a cache hit |
| `__digest` | — | 205 calls / 13 KB back |

Per-item averages over the 85-92 marked items move with it: `result_bytes` **632-638 KiB → 32.9 KiB**
(a 19x cut), `guest_ms` **62.8-66.2 → 30.7 ms**, `run_ms` 115.9 → 80.7 ms on an equally quiet pair of
runs. The turns' remaining bytes are the core's own data, not the bridge's: `sha256` 225 KB/turn (the
prompt-layer hashes `agent.lua` takes), `sql_exec` 46 KB, and the 26 KB model request in `http_stream`,
which is already `bytes` on both sides.

**A serving node, one node per core, medians of 10 turns** (`scripts/bench-serve-core-component.sh`, the
old guest as `a` and the new one as `b` inside the same round, so a change to the guest alone is measured
without a machine that drifted in between; two runs of two quiet rounds each):

| round | turn native / a / b | read native / a / b | b/native (turn) | a/b (turn) |
| --- | --- | --- | --- | --- |
| 1 | 237.5 / 458.5 / 302.5 ms | 8.0 / 11.0 / 10.0 ms | 1.27x | 0.66x |
| 2 | 219.5 / 481.5 / 202.5 ms | 8.0 / 10.5 / 11.5 ms | 0.92x | 0.42x |
| 1 | 237.5 / 456.0 / 298.0 ms | 8.5 / 12.5 / 13.5 ms | 1.25x | 0.65x |
| 2 | 220.5 / 462.0 / 200.5 ms | 8.0 / 11.0 / 10.0 ms | 0.91x | 0.43x |

The median of the quiet rounds is **1.1x native for a turn** (target ≤ 1.3x; A2.4/A2.5 measured 1.42x,
and the same guest unfixed measures 1.92-2.10x on this host), reads 10-13 ms on both cores, RSS +70 MiB
for the pool (unchanged: the cache holds ~2.4 MB of bytecode per instance, inside the reserve). The last
round of a longer run is a host outlier (turn 1.6-1.7 s, read 1.3-2.7 s) and it lands on whichever mode
runs last, so it is quoted as noise rather than as a result. The epoch tax is still there and is still the
biggest single knob left: the same guest with `WASM_AGENT_CORE_RUN_DEADLINE_MS=0` measures 0.88x of itself
(A2.6's number, re-measured here), and the default stays 60 s.

**Parity.** `scripts/test-core-parity.sh` (131 self-contained Lua tests, native vs the one-shot
component): **114 identical, 14 failing identically on both cores, 3 differing** — `test-cli-view` and
`test-completion-packet` (both already differing at A2.5) and `test-backup-live`, whose output contains
the backup directory's own `YYYYMMDDTHHMMSSZ` timestamp: two *native* runs a second apart differ the same
way, so it is a normalizer gap in the harness, not a difference between the cores. A2.5's
`test-cli-ticker` difference did not appear this run. `scripts/test-serve-core-component.sh` passes on
both cores (three turns, one hook, one subagent, one self-wake, identical answers).

**Tests.** `scripts/test-core-module-cache.sh` (new; no node, no network) proves both halves with one
probe: three loads of one module, with the file rewritten between the second and the third, must answer
`v1`, `v2`, `v2` on both cores and — from `WA_CORE_CALL_PROFILE` — cross `__source` **2** times and
`__digest` **3**, i.e. the third load was answered from the chunk and the second was not.
`cargo test -p wa-capabilities`: 207 pass, including the new
`core_component::tests::the_module_digest_follows_the_file_it_describes` (the same bytes answer the same
digest; a rewritten file answers a different one; a missing file is `nil`). The one-shot
`wa --core-component` path now prints one `core_call_profile` block per run when `WA_CORE_CALL_PROFILE=1`,
which is what lets a CLI run show a single boot's crossings.

**Not done here.** (1) The 205 `__digest` crossings are 205 `metadata` calls per turn (~15 ms of handler
time on Windows): cheaper than the read-and-hash they replaced (27 ms) but not free — one manifest call
per boot would cut the crossings, not the stats, and a real fix is a directory watch, not a cache. (2) The
remaining per-turn copies are the core's own (`sha256` 225 KB, `sql_exec` 46 KB, the 26 KB model
request): none of them is a bridge re-encoding, and each needs a `lua/core` change, which this pass did
not make. (3) The cache is per instance and dies with it: four instances hold four copies of the bytecode
(~2.4 MB each), which is inside the 64 MiB reserve but is not shared. (4) Nothing here is WASI 0.3: the
cache is in the guest's C, so it moves to `future<T>`/`stream<T>` unchanged.

## Supervisor features, step 4 (implemented 06/11, wasm_the_first)

The four lessons that were design in the list above are now code, with the two runtime gaps that
mattered in production closed beside them. Everything is in `rust/wa-kernel-runtime` (plus one new
`wa-governance` module) and every claim below has a test; the file names are the entry points.

### 1. Start by imports (`imports.rs`, `supervisor.rs`)

A definition's position in configuration means nothing. `imports::of_installed` reads the **artifact's
own type** (compiled once, cached by pin) and returns what it imports and exports; `kernel_serves`
answers which of those the runner links; everything else has to be exported by a *running* provider.
`supervisor::plan` simulates the starts, so a provider listed after its consumer is planned first, and
`supervisor::reconcile` (the `services supervise` action) performs it until nothing more can start.

* **Exact versions.** `wa:kernel/kv@0.1.0` and `@0.2.0` are different interfaces served by different
  runners. A component that asks for a version nobody serves **waits** and says which one; it is never
  started against a contract it was not built for. The served list is a constant, and
  `imports::tests::the_served_interface_lists_match_the_wit_worlds` reads `wit/kernel*/kernel.wit` and
  fails when the constant and the world disagree - the one way that constant could rot silently.
* **What "waiting" looks like.** `services status` answers `{"state": "waiting", "waiting_for":
  ["wa:vision/text-reader@0.1.0"], "waiting_reason": "imports_not_served"}` (`not_installed` when the
  component is not on the node at all: two very different operator problems). A definition that is
  waiting is not reported as `not_running`, which says nothing about why.
* **Boot uses it.** `lua/core/services.lua`'s `autostart` no longer starts enabled definitions in store
  order; it hands them all to `supervise`, so a channel that needs a provider which is also enabled
  comes up without the operator ordering anything. `already_running` keeps the old idempotency answer.

### 2. Revocable registrations (`registrations.rs`, `bus_host.rs`, `queue_host.rs`)

Every running instance gets an identity: `{name, generation, token}` where the token is
`name#generation`. The name is what the ACL, the policy and telemetry attribute a call to; the token is
what a provider keys its rows by. `registrations::Ledger` records what an instance registered (bus
subscription, queue grant, and the `Timer`/`Tool`/`Route` seams a provider will use) together with the
provider's own `cancel` closure, and `revoke_generation` runs exactly those.

The rule that made this necessary: a hot swap starts the replacement **beside** the old instance, so
both are alive under one name. A name-keyed revoke at "old stops" time revokes the *new* instance's
rows - the swap would leave the winner with no subscriptions and refused queue calls. Now `wa:bus`
subscribes as the token (the ACL grants subscribe to the component name *and* each open instance),
`wa:queue` gates by the token, and `services::replace` revokes one generation. `stop` (the component
stops for good) still takes everything.

Proof: `install::tests::an_upgrade_switches_only_when_the_candidate_is_good` asserts, after a real
switch, `count_generation(name, old) == 0`, one bus token (`name#N`) on the node and one queue grant -
the retired instance's rows are gone and the live instance's are not. `registrations::tests` proves the
same two properties on the ledger alone, including that a cancel runs (so "revoked" never means only
"forgotten").

### 3. Transactional install (`install.rs`, `services::retire`/`replace`)

`services upgrade {name, source: {wasm, manifest|manifest_path, pin}, ready_ms?}`:

```text
stage (<components>/.stage-<name>-<pid>/, three files)   -> pin verified against the staged bytes
-> every imported interface is served                    -> else refused, quoting the interface
-> grant checked against the staged manifest              -> state migration on a snapshot copy
-> the running instance is retired                        -> drain (if it opted in), stop, join, leases back
-> candidate started (one instance per name: services::claim)
-> lifecycle.report(ready), or alive-unreported
-> staged files committed (wasm, manifest, pin last)      -> services::replace: switch and revoke the retired generation
```

One service name holds **one** instance at every step (`services::claim`, 11/11): the claim is taken
inside `spawn_instance`, so `start`, `enable`, `autostart`/`supervise`, this upgrade and the dev loop all
meet the same refusal (`service_already_running`) instead of stacking. The earlier order - start the
candidate beside the old instance - is right for a stateless component and wrong for one that owns a
device, a port or a lock: on 09-11 both `wa-whatsapp` instances restored the same device and
authenticated, WhatsApp replaced one, and the replaced instance's outbox kept claiming sends it could not
deliver.

Any failure before the switch stops the candidate, deletes the staging directory, and leaves the
installed files untouched; because the previous instance was already retired, the previous pin is then
**put back** (`restore_previous`) and the answer says `restored: {restored: true}`. A refused upgrade
costs a restart, never an outage and never two instances. The test walks a pin mismatch, a non-wasm
source and an unserved import before the successful upgrade - each refused before anything is retired,
so the running instance does not move - plus the restore path and the negative control for the claim.
The health rule is `dev::wait_ready`'s, extracted so the dev loop and this path cannot disagree:
`ready`/`degraded` is health, a vanished thread is an exit, and an instance that runs for the whole
window without reporting is accepted **and reported as `unreported`** (the report is optional in the WIT
and absent in a wasip1 module, so inventing health would be worse than naming its absence). The files are
committed *before* the switch, so a crash between the switch and the next start finds a consistent
installation (the pin moves last: new bytes with an old pin are `component_hash_mismatch`, never an
unverified run).

### 4. Profiles as layers (`profiles.rs`)

`base -> node -> user -> patch`, rows addressed by id, merged per key (recursively for nested objects),
where a `null` removes a key and an absent key inherits. `base` is what the binary knows; the other
three are `<state>/profiles/{node,user,patch}.json`. `services profile_dump [name]` prints the order,
the effective rows, which layers existed, and - with a name - the `config` that component would be
started with (its own row over `default`) and its `limits`. `install::upgrade` fills a missing `config`
grant from there, so the effective configuration is one stack, not a fourth place to look.

A broken layer is reported and skipped: profiles shape configuration, not authority (grants stay in
the manifest and the node policy), so a typo must not stop a node - and must not be silent either.

### 5. Per-component limits (`wa-governance/src/component_limits.rs`, `wa-kernel-runtime/src/limits.rs`)

A manifest *declares* `limits: {memory_mb, cpu_ms}`; the node *caps* it (`WA_COMPONENT_LIMITS`, else
the `limits` section of `policy.json`, else `<state>/limits.json`, else the defaults 512 MB / 5000 ms).
`min(declared, cap)` is resolved in one place (`limits::for_service`) and all three runners build their
store from it, so the same manifest cannot yield two different caps depending on which contract it was
built for. The answer says which side decided (`manifest`, `node` or `both`).

* **memory** through `StoreLimits` (unchanged mechanism, now capped).
* **CPU** through the epoch callback: `CpuBudget` sums the gaps between epoch firings while the guest
  keeps the CPU, and traps with `cpu_limit` when `cpu_ms` is spent inside one window. A gap longer than
  60 ms means the guest was parked (a timer, a stream read, a slow host call) and the window restarts,
  so an async guest that waits is never killed for waiting.
  **The default is 5000 ms, and that is a finding, not a guess:** the first default tried here was
  50 ms and it trapped `svc-echo-v1` in the middle of its `wa_http` poll - a `wa:kernel@0.1` guest is
  *supposed* to poll (the 0.1 contract is sync calls plus non-blocking polls), so a tight poll loop is
  normal there, and a budget shorter than a legitimate poll wait turns a contract into a bug.
  **The risk, named:** a guest preempted by the OS mid-loop looks parked for that gap, so the budget
  errs towards running longer. It is a starvation guard, not an accounting instrument; on the 0.2
  runner the parked-guest watchdog (`stop`) is still what ends a guest that never returns. What it does
  prove is `services::tests::a_guest_that_never_yields_is_trapped_by_its_cpu_budget`: a `loop { br 0 }`
  guest really is trapped, with `last_exit = trap:cpu_limit`, once its declared 10 ms is spent.

### 6. The policy reload, and the 06/11 deploy bug

Production, 06/11: the node started 14:55:13, the deploy wrote `policy.json` at 14:55:37, and every
WhatsApp send after that was refused. The node had loaded the policy it had - nothing watched the file.

Two fixes, both tested:

* **the node reloads** (`wa_governance::node_policy`): a watcher thread polls the file's mtime/size/
  sha256 (`WA_GRANT_POLICY_WATCH_MS`, default 1000, `0` disables), and a change is parsed and
  validated *first*, then installed with `Engine::set_policy` under the engine's lock - budgets
  (rate buckets, daily counters) are kept, so a reload cannot reset a limit. A file that appears while
  the node runs switches the layer on; a broken file applies nothing and is reported; a *removed* file
  keeps the loaded policy (going back to `manifest` mode would widen what the node allows). `mode` and
  `loaded` became atomics for this, and `host.policy_status` grew a `reload` block: the sha256 the
  loaded policy came from, how many changes were applied, the last change that was refused.
  Tests: `a_policy_file_that_appears_after_start_is_loaded_without_a_restart`,
  `a_reload_tightens_a_running_node_and_keeps_its_budgets`,
  `a_broken_or_removed_file_keeps_the_loaded_policy_and_says_why`, and the watcher itself
  (`the_watcher_applies_a_file_written_while_the_node_runs`).
* **the deploy orders it** (`scripts/deploy.sh`): the policy install is step 6a, *before* the
  `upgrade.sh` invocation that restarts the node; what remains after the restart is only the
  informational "installed components with no rule" listing, which has to read the freshly installed
  component directory. `scripts/test-deploy-policy-order.sh` reads the script and fails if the install
  drifts back below the restart, and source-checks that the reload still exists.

The reload is the safety net; the order is the contract, because a node should not be on the wrong
policy for even one second.

## The crate split (step 5, first batch) — `wa-host` is the binary

`wa-host` was one 29k-line binary crate: host runtime, capabilities, the Lua bridge, both service
runners, governance, the queue/bus/state providers, the console, the transport, the CLI. Every change
rebuilt all of it. The first batch of the carve-out (row 5 of "Order of work") is done, with no logic
change — moves, `pub(crate)` → `pub` where a crate boundary needed it, and re-exports:

| crate | holds | depends on |
| --- | --- | --- |
| `wa-host-support` | vendored Lua 5.4 and its C ABI (`lua`), `paths` (home, private dir, component dir), `json` (the shared answer), `system_resources` | — |
| `wa-governance` | `node_policy`, `node_telemetry`, `store` (GRANT-POLICY, TELEMETRY, REPLAY) | support |
| `wa-term` | `terminal_editor`, `selection`, `build_status`, `transcript` | support |
| `wa-rendezvous` | `node`, `binding_runtime`, `rendezvous`, `relay_client` | support |
| `wa-kernel-runtime` | `components`, `services`, `service_components`, `service_components_v2`, `service_io`, `queue_host`, `bus_host`, `state_host` (and `service_stt`, declared where it was) | support, governance |
| `wa-capabilities` | `capabilities`, `host`, `serve`, `subagents`, `operations`, `resources`, `graph`, `quickjs`, `plugins`, `core_component`, `client_bridge`, `http_transport`, `audio`, `file_search`, `ripgrep` | support, governance, term, rendezvous, kernel |
| `wa-host` (binary `wa`) | `main.rs`, `build.rs`: HOME, the interpreter, CLI dispatch, wiring | all of the above |

Three seams had to be named rather than moved, and each is a wiring change, not a behaviour change:
`Lua::rollback_if_open` stays with the connection it knows about (`host::rollback_if_open`, driven by
`Lua::owned()`), `push_json` is the one answer shape the kernel and the capabilities share, and
`component_dir` is asked for by the graph store and the bound queue, so it lives in `paths`. The
vendored Lua sources moved to `wa-host-support/vendor/lua` with `lua.rs`, and the code-mode assets are
provisioned by `wa-capabilities/build.rs`, which is the crate that embeds them.

What the split buys, measured on wasm_the_first (release, warm dependency graph): a change in a leaf
crate rebuilds that crate and the binary; a change at the bottom (the Lua ABI) still rebuilds
everything, because everything answers on a Lua state. What it does not buy is a faster rebuild after
editing `node_policy.rs` or `service_components_v2.rs`: both sit below the 13k-line capability crate, so
their rebuild still reaches it. The next batch is therefore a *shape* change rather than another move:
split `wa-capabilities` (`host`, `serve`, `subagents`) so the volatile capability surface stops sitting
under the kernel, and a policy edit stops paying for it.

## Watchdog (`rust/wa-watchdog`) — the bottom layer, built

Row 6 of "Order of work" has its first half: a native supervisor that starts the kernel, restarts it on a
crash with exponential backoff, and replaces the kernel binary only after the new bytes have answered
`/health`, keeping the old binary on disk so a rollback is a path change and a restart, never a rebuild.

The sentinel of today does the same job for a *node* (docs/SENTINEL.md) with a shell script, `curl`,
`netstat` and a good deal of hard-won caution. The watchdog is that job as one small program, because the
layer that must survive what it replaces should not be the layer that changes: the kernel will be replaced
constantly and the watchdog almost never.

### What it is

One binary, **no dependencies at all** (std only). That is a constraint, not an accident: a supervisor that
shares a dependency graph with the thing it supervises can be broken by that thing's build (the reason
`wa-sentinel` carries its own lock file), and carrying nothing is the same property without a second
workspace. What that costs is one SHA-256 (`src/hash.rs`, checked against the NIST vectors), a loopback
HTTP/1.1 GET for `/health` (`src/health.rs`, chunked and `Content-Length` both decoded), and a JSON writer
plus a top-level field reader (`src/json.rs`) - a cost paid once, which also keeps `cargo zigbuild` for
`aarch64-unknown-linux-gnu` a pure-Rust build (`cargo zigbuild --release --offline --locked -p wa-watchdog
--target aarch64-unknown-linux-gnu.2.31`, the same flow as `wa-host`, see COMPONENTS.md).

```
wa-watchdog run    [--config FILE] [--home DIR]        supervise the kernel in the foreground
wa-watchdog stop   [--home DIR]                        ask the supervisor to stop its kernel and exit
wa-watchdog status [--json] [--home DIR]               what the supervisor last wrote down (exit 0 = healthy)
wa-watchdog swap <binary> --sha256 <pin>               verify, stage, prove on a spare port, ask for the switch
                   [--arg <value>]... [--wait-ms N] [--spare-port N]
wa-watchdog verify <binary> --sha256 <pin>             the pin check alone
wa-watchdog init --kernel <path> [--port N]            write a config for a fresh home
```

State lives in one directory (`--home`, else `WA_WATCHDOG_HOME`, else `<node home>/watchdog`), all of it
plain files a shell script can read: `watchdog.conf`, `current` (one line: the binary that is running),
`current.json` (that binary, its pin, and its argument line), `status.json`, `kernel.pid`,
`supervisor.pid`, `logs/`, `requests/` + `results/` (the swap protocol below) and `bin/<sha12>/` (every
binary ever swapped in). Writes are atomic - write beside, rename over - for the reason `upgrade.sh`
renames: a crash between two writes must not leave a record a later reader believes.

### The swap, in the order that matters

1. **verify** - the bytes must hash to the pin. Nothing else happens before it.
2. **stage** - copy into `bin/<sha12>/<name>` and verify the copy. The binary that is running is never
   overwritten, so a rollback needs no build.
3. **prove** - start the staged bytes on a spare port with a **scratch home**, its own `db`, and
   `WASM_AGENT_RENDEZVOUS`/`WASM_AGENT_RELAY` removed, then wait for `/health`. The running kernel is
   untouched for all of this. (Sections 1 and 1b of `scripts/upgrade.sh` do the same thing with `curl` and
   the code-mode check; the reason is identical - a binary that cannot start must be found out while nothing
   has changed.)
4. **switch** - a request file appears in `requests/`; the supervisor (the only process that holds the
   kernel's pid) claims it by renaming it, waits until the service port is *bindable*, stops the old kernel,
   starts the new binary, and waits for `/health` within `swap_health_window_ms`. Then, and only then, does
   `current` name the new binary.
5. **rollback** - a new kernel that does not answer is stopped, the previous binary is put back and proved
   before the supervisor reports. A kernel that answers and *then* dies inside `stability_ms` is rolled back
   the same way, with its own `results/<id>.rollback.json` (a result is never rewritten to say something
   else).

Arguments are stored **as written**, with `{port}`, `{client_port}`, `{service_port}`, `{home}` and `{db}`
substituted at launch. That is what lets one recorded line start the service instance on the service port and
the proof instance on a spare port - a list of already-resolved arguments could only name one of them.

### Two states, and what is deliberately not the watchdog's

- **A crash** is an exit, settled by `try_wait` on every pass, so a kernel that died between two passes is
  never missed. The restart is delayed by `backoff_base_ms`, doubled per attempt to `backoff_max_ms`
  (500 ms → 60 s by default).
- **A slow node** is not a crash. `health_miss_limit` defaults to `0`: a busy node answers `ok:false` while
  a run is stalled, and restarting it for that would interrupt the turn the node exists for. Waiting for
  idle is `upgrade.sh`'s job, and it still does it.
- The watchdog does **not** judge idle and does not read the node's state: no `memory.db`, no `serve.pid`, no
  session, no credential. It knows a pid, a port and a pin.
- Stopping a kernel is `kill`/`TerminateProcess`, not a graceful SIGTERM: a killed kernel cannot write a
  goodbye, so `serve.pid` can be stale after a swap. The next start refuses nothing on that basis, and
  `serve.pid` is rewritten from `kernel.pid` by the caller that asked for the swap.

### Why an upgrade is seamless enough

A process cannot hand its listening socket to another on Windows, so the gap is a restart: the old kernel is
stopped, the new one is up and answering within a fraction of a second. Everything that makes that survivable
sits above the kernel, not in it: **sessions live in `memory.db`, written by the kernel that is running**, so
the thread continues across the swap - a CLI reconnects and re-reads its session, and the window polls the
node's version every second and reloads itself. A turn in flight is not written; that is why `upgrade.sh`
waits for idle before it asks, and why the watchdog does not decide that question.

### Wired in behind a flag, default off

`scripts/upgrade.sh` takes the watchdog path only with `WA_WATCHDOG=1` (and `WA_WATCHDOG_BIN`/
`WA_WATCHDOG_HOME`/`WA_WATCHDOG_WAIT_MS` to say where it lives). With the flag on and no watchdog installed it
**refuses** (exit 2) rather than falling back to the old restart silently. With it on:

- the pin, the downgrade guard, the code-mode proof and the idle gate all still run;
- the switch is one `wa-watchdog swap` call, and the script does not stop the node itself - it must not,
  or the node is down for the whole wait (measured: the watchdog saw its kernel killed by the script and
  restarted it with backoff while the script was still preparing);
- `serve.pid` is written from the watchdog's `kernel.pid`, so the install tooling keeps reading the pid that
  listens, and the listener check after health still means what it meant;
- a swap that is refused or rolled back restores the script's own file backup (binary and UI) and exits 1.

Tests: `cargo test -p wa-watchdog` (unit + integration, two fake kernels), `scripts/test-watchdog.sh` (the
crate plus the CLI contract the upgrade script depends on) and `scripts/test-watchdog-upgrade.sh` (a scratch
install upgraded through the flag, with the default path checked to be untouched). The fake kernel is
`wa-watchdog selftest-kernel`: it binds one port and answers `/health`, and it can be told to be unwell, to
hang, to fail to bind, or to die - nothing it does reaches a real node.

## Order of work

1. This document + `wit/` (v1 draft). ← now
2. `wa-whatsapp` ported to a `wasip2` component on `wa:kernel` (the reference module); host bindings
   generated from the same WIT.
3. wasi-nn spike: `wa:speech/recognizer` and `wa:vision/text-reader` providers on ONNX, measured
   against native faster-whisper on openclaw.
4. ~~Supervisor features: start-by-imports, revocable registrations, transactional install with
   health-gated switch, profiles.~~ Landed 06/11 - see "Supervisor features, step 4" below, plus the
   per-component limits and the policy reload that came with it.
5. Carve-out in batches, smallest and most frequently changed first; the Lua core as one component.
   First batch landed: the crate split above (`wa-host` is the binary).
6. Watchdog replaces the sentinel for kernel upgrades. First half landed: `rust/wa-watchdog` plus the
   `WA_WATCHDOG=1` path in `scripts/upgrade.sh` (see "Watchdog" above). What is left: the sentinel's own
   start/stop/restart verbs have to address the watchdog rather than the node (two supervisors cannot both
   own the pid), and the deploy has to ship and start it.

## Memory as a component (seam landed; the 0.3 pass remains)

The split is in place: the memory **logic** is a component that exports `wa:memory`
(`wit/memory/memory.wit`, `rust/components/memory`), and the memory **storage** is the kernel's — the
same `memory.db`, its WAL, its transaction, its backups and its journal. The component reaches it
through `wa:kernel/sql` (`wit/kernel/sql.wit`), scoped by its manifest to named tables.

| part | where | why |
| --- | --- | --- |
| memory **logic**: recall ranking (bm25 + the recency bonus), the two recall passes, term extraction, scope rules, transcript search, the derived session state, the retention decision | the `memory` component, exporting `wa:memory` (remember, recall, forget, list, search-messages, sessions, retention) | changes often, hot-swappable, a capability seam others can provide |
| memory **storage**: the SQLite file, durability, locking, backups, the replication journal | the kernel (`sql_host.rs`, `memory_host.rs`) | something native owns the file; several consumers share it; it must survive any component swap |

- **The grant is enforced by the engine, not by reading the statement.** `sql_host` runs every
  statement under a SQLite authorizer: a read outside the granted tables, a write outside the writable
  ones, `ATTACH`/`DETACH`, every write `PRAGMA` (read-only introspection only), DDL, `load_extension`
  and a second statement in one string are refused by SQLite itself. Refusals are counted and appended
  to `<components>/memory.sql-audit.log` — the action and the table, never a value from the database.
  A table's FTS shadow tables belong to the table the grant names.
- **A component that cannot answer does not answer for the node.** Every call has a deadline (the
  guest's epoch, so a wedged guest is stopped, not waited for) and every statement has its own; a
  failure is `ok: false` with a name (`component_unavailable`, `component_wedged`,
  `sql_policy_refused:…`), and `lua/core/memory.lua` falls back to the native path with one log line.
- **Identity stays in the kernel.** A journal entry's `origin` is the node's identity, and a component
  never names itself, so `remember`/`forget` report what they wrote and the kernel appends the entry
  (`journalled: false` when it could not). The seam's known gap: that row is a second transaction, so
  a crash between the component's commit and the kernel's journal leaves a memory that has not
  replicated yet. Closing it is part of the 0.3 pass below.
- `WA_MEMORY_COMPONENT=1` routes the Lua core through the seam; **the default is the native path,
  unchanged**. Parity is asserted, not assumed: `scripts/test-memory-component.lua` sends the same
  inputs through both and compares the answers field for field (including FTS ranking order and the
  session detail text), in `scripts/fast.sh`.

What the WASI 0.3 pass still owes this seam:

1. **`async func` on the seam.** `wa:memory` and `wa:kernel/sql` are written for `wa:kernel@0.1`
   (wasm32-wasip2, synchronous). On 0.2 they become `async func` with identical records, so a slow
   statement parks the guest task instead of blocking the caller's thread; `memory_host` then runs
   under `store.run_concurrent` like `service_components_v2`. Nothing in the records has to change.
2. **The journal in the component's transaction.** Either `wa:kernel/sql` gains a way to stamp the
   calling node as the row's origin (then the component journals inside its own transaction, which is
   what the native path does), or `wa:memory` returns a unit of work the kernel commits. Until then
   the entry is a second transaction, reported as such.
3. **The consumers move.** `agent-core` should import `wa:memory` directly and call it in-wasm (it is
   the reason the seam exists); the UI and other components call it instead of SQL; then the Lua
   router is deleted rather than left as a flag.
4. **Governance wiring.** `sql` refusals are audited per component today; the grant policy
   (`docs/GRANT-POLICY.md`) should own that budget explicitly (statements and rows per minute), the way
   `kv.read`/`kv.write` are gated for a service.
5. **Journal sync on the new plumbing**: entries published as `memory.*` bus events, delivery per peer
   as queue jobs, semantics unchanged (signed, idempotent, never echoed). Not started; the cursor loop
   is still the transport.

## The self-loop as a component (seam landed; the rest of the split is `docs/CORE-SPLIT.md`)

The model's own long-mission controls — wakes, notes, probes (`docs/SELF-LOOP.md`) — are the second
piece of `lua/core` to leave the interpreter, and the first one taken out of the *agent* rather than
out of the store. The state machine is a component that exports `wa:selfloop`
(`wit/selfloop/selfloop.wit`, `rust/components/selfloop`); its three tables stay in `memory.db`, which
stays the kernel's.

| part | where | why |
| --- | --- | --- |
| the **state machine**: validation and the named refusals, the schedule/list/cancel rules, the notes document, append and compaction with its archive, the event subscriptions and what a publish matches, the claim/settle compare-and-set, the stale-dispatch reconciliation, and the rendered wake turn | the `selfloop` component, exporting `wa:selfloop` | it is a state machine over rows: swapping it loses nothing, and a restart re-reads the rows |
| the **node's half**: running a probe in the QuickJS sandbox (it calls the read-only tool catalogue), the run scheduler a due wake is handed to, the `SelfWake`/bus hooks, and the agent turn itself | `lua/core/selfloop.lua` (`run_probe`, `dispatch_default`, `run_wake`, `publish`'s hook call) and the capabilities it already had | these need the living turn and the node's threads; a component must own neither |

- **The seam is typed, and one value is text on purpose.** Every argument and answer is a record
  (`wake`, `schedule-request`, `tick-plan`, `probe-result`, `trace-entry`, …), and every refusal is a
  case of `error`, so the router still switches on the names it always did (`wake_reason_required`,
  `wake_already_dispatching`, `notes_too_large`, …). The one text field is a *rendering*:
  `probe-result.detail` is the probe's answer as the model will read it on its next turn, stored
  verbatim because the native path stores it verbatim.
- **The tick keeps its shape.** The component answers `plan` (what is due, what was reconciled), and
  the node runs each row's probe, then `claim`s it, then `settle-dispatch`es the scheduler's verdict,
  then `finish`es the turn. So the component never dispatches, never runs a probe, and never decides
  that a turn happened; it decides what the row is.
- **No DDL.** The component's `wa:kernel/sql` grant is read/write on `self_wakes`, `self_notes` and
  `self_notes_archive` plus read on `sessions` (the authority checks). `setup()` in
  `lua/core/selfloop.lua` still creates the tables: a grant has no `CREATE TABLE`, and a store without
  them is a visible `store_failed`, not a component that silently invents a schema.
- **The interrupt hold is the kernel's, on both paths.** Whether a session's schedule is held (an
  interrupted run, `docs/SELF-LOOP.md`) is a row in `self_wake_pauses`, read and written by
  `lua/core/selfloop.lua` itself, not asked of the component and not in its grant: it is one fact the
  node decides at a claim, and `summary` adds it to the component's answer so both paths report it.
- **A refusal is an answer, not a failure.** The capability answers `ok:true` with the refusal table,
  so a refused wake never reads as a broken component; only "the component could not answer" returns
  `ok:false`, and `lua/core/selfloop.lua` then runs the native path with one log line per (operation,
  reason). `WA_SELFLOOP_COMPONENT=1` is the switch; **the default is the native path, unchanged**.
- **Parity and cost are measured.** `scripts/test-selfloop-component.lua` runs the same calls through
  both paths and compares them field for field (54 comparisons, ids normalised), including the tick's
  three counters, a wake surviving a new interpreter, and an unchanged probe spending no turn;
  `scripts/bench-selfloop.sh` reports ms, host-call crossings, SQL statements and process RSS per
  scenario (table in `docs/CORE-SPLIT.md`, "Cost").
- What the 0.3 pass owes this seam: `async func` with identical records, the same as `wa:memory`; a
  pooled instance instead of per-call instantiation if a second caller makes the tick's 1.6 ms matter;
  and the schema moving to a kernel-owned migration so the component can stop relying on `setup()`.



Today the memory logic (`remember`/`recall`, sessions, compaction, the journal sync loop) is Lua in the
core, and it reaches `memory.db` through the kernel's `sql_*` capabilities (docs/MEMORY.md). The split
follows the three layers:

| part | where | why |
| --- | --- | --- |
| memory **logic**: recall ranking, full-text and later semantic search (wasi-nn embeddings), compaction and retention policy, sync policy | a `memory` component exporting `wa:memory` (remember, recall, sessions, session, search, resume) | changes often, hot-swappable, a capability seam others can provide |
| memory **storage**: the SQLite file, durability, locking, backups | kernel | something native owns the file; several consumers share it; it must survive any component swap |

- The component gets a scoped grant to its own database (`wa:kernel/sql` limited to `memory.db`); the
  agent (`agent-core`), the UIs and other components call `wa:memory`, never SQL. Governance audits and
  rate-limits it like any capability; a component that only needs `recall` cannot read transcripts.
- Journal sync moves onto the new plumbing: entries published as `memory.*` bus events, delivery to
  each peer as queue jobs (retries, dead-letter) instead of the cursor loop; semantics unchanged (signed,
  idempotent, never echoed).
- The existing schema is adopted by wa-state (schema version, never-rewritten migrations).
- Because the transcript stays the context and the file stays in the kernel, a kernel swap through the
  watchdog loses nothing: the CLI/UI reconnect and the thread continues (seamless update).

See `docs/MEMORY.md`, "The memory seam", for the manifest shape, the flags and the gap in the journal.
