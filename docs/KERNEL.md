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
today. Preview 3 (native async) replaces the polling when it is stable; the interfaces are shaped so
that is a mechanical change (every potentially slow call already has a non-blocking form).

## Carve-out map (first pass, from the capability inventory in HOST.md)

| stays in the microkernel | becomes components |
| --- | --- |
| runtime, loader, pins (`components`, `service`, `component_mcp`, `plugins`, `invoke`) | `graph_*` (indexer, queries) |
| node identity + transport (`node_identity`, `sign`, `verify`, `relay`, `binding_*`) | code mode (`quickjs` — already wasm) |
| supervised processes (`exec`, `operation`, `subagent`) — until a process-less design exists | providers and the agent loop (today in the Lua core) |
| durable state for the kernel itself (`sql_*`, `db_ready`) | MCP servers (Node scripts → components, `mcp-whatsapp` done) |
| console/device I/O for the CLI (`terminal_*`, `input_*`, `panel`, `audio`) | channels (`wa-whatsapp` done; connector logic next) |
| files/paths under grants (`read_file`, `write_file`, `list_dir`, `grep`, `paths`) | STT, OCR (wasi-nn), file search |

The Lua core is the largest single block: the agent loop, tool dispatch, MCP and services registries.
Lua compiles to wasm, so it can move as one component first (the "agent" component) and then split
along the seams above.
Measured 05/11 ([benchmarks/lua-wasi-spike](../benchmarks/lua-wasi-spike/README.md)): wa-host's Lua 5.4
runs in a wasm32-wasip2 component with every `host.*` bridged through one generic import — ~1.45× on
pure-Lua compute, ~+0.8 µs per host call, `pcall` works (wasm exceptions) and is faster, instantiate
0.1–0.2 ms. Estimated ≈3.5–4.5 days to parity.

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
