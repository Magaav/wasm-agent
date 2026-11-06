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
interpreter (`rust/wa-host/src/core_component.rs`), so nothing is reimplemented per guest. The guest
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
-p wa-host` passes all 201 tests, and the component / service / agent-core blocks of `scripts/test.sh`
run for real (24 + 23 + 245 checks, and the svc-echo service end to end).

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
the kernel runs the *unchanged* native `http_sse` (`rust/wa-host/src/host.rs`) on a thread of its own,
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
### C1 results — the code graph as a component (05/11, wasm_the_first)

The graph is the first capability moved out of `wa` without touching Lua. The 14 `host.graph_*`
functions keep their names, arguments and answer shapes; `rust/wa-host/src/graph.rs` is now a kernel
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
`wit/kernel-v2/kernel.wit` is `wa:kernel@0.2.0`; `rust/wa-host/src/service_components_v2.rs` serves it;
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

Two things the async path needed that the poll path did not:

- **A runtime for timers.** `wasmtime_wasi`'s WASI 0.3 clock is built on tokio's timer, so the 0.2
  runner owns a current-thread tokio runtime (`rt` + `time`) and drives the guest with
  `store.run_concurrent`.
- **A watchdog for a parked guest.** The epoch deadline traps a guest that is *running*; a guest
  sitting in `wait-for` has no wasm to interrupt, so `services::stop` would never join its thread.
  After the grace period the runner drops the guest's future instead (measured: stop returns in
  under a second with the fixture parked in a 300 ms timer).

**Results** (`cargo test -p wa-host`, debug build, 206 tests): the three service fixtures each run
end to end — wasip1 core module, 0.1 component, 0.2 component — including a granted and a refused
`net` dial against real local servers, a kv round trip, a websocket echo read over the inbound
stream, a clean stop, and the restart path. The 0.2 guest's heartbeat is a WASI 0.3 timer.
`wa-whatsapp`'s 0.2 component (8 MB) compiles and **instantiates** on the 0.2 runner, which is the
check that every import name it emits is served (`WA_TEST_WHATSAPP_WASM` in
`service_components_v2::tests`). One expressiveness loss: `exit_3` cannot be named — `wasi:cli/exit`
takes a `result`, so a component that exits non-zero is reported as `exit_1`.

**Known limits, next.** A response body is buffered whole and handed out in 64 KiB chunks (a real
streaming download needs a reader thread, not `read_to_vec`); the send backpressure is the channel
bound, not the TCP window; a 0.1 component is compiled twice at start; and `wa-whatsapp` was not run
against a phone from this lane (no pairing, no messages — see
[SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md)).

## Order of work

1. This document + `wit/` (v1 draft). ← now
2. `wa-whatsapp` ported to a `wasip2` component on `wa:kernel` (the reference module); host bindings
   generated from the same WIT.
3. wasi-nn spike: `wa:speech/recognizer` and `wa:vision/text-reader` providers on ONNX, measured
   against native faster-whisper on openclaw.
4. Supervisor features: start-by-imports, revocable registrations, transactional install with
   health-gated switch, profiles.
5. Carve-out in batches, smallest and most frequently changed first; the Lua core as one component.
6. Watchdog replaces the sentinel for kernel upgrades.

## Memory as a component (planned, phase 4, after A2.4)

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

Order: after A2.4 (the agent loop already calls from inside wasm), before the seamless-update work.
