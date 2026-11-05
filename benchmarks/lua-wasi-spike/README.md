# Spike: the Lua core inside a WASI component (05/11)

Question: can the embedded Lua core (lua/core, today run by wa-host's native Lua 5.4 through 85
`host.*` capabilities) run inside a wasm component, with every `host.*` call bridged through ONE
generic WIT import, at acceptable cost? (Context: docs/KERNEL.md — carve the monolith.)

## What was built

- **guest/**: wa-host's vendored Lua 5.4.8 (`rust/wa-host/vendor/lua`) compiled with wasi-sdk 34 clang
  for `wasm32-wasip2`, wrapped by a Rust `wit-bindgen` 0.63 cdylib. `glue.c` gives Lua a `host` table
  whose `__index` makes any `host.<name>(...)` a call to ONE import:
  `wa:spike/host-call.call(name: string, args: list<string>) -> result<list<string>, string>`
  (`wit/spike.wit`). Libraries opened: base, string, table, math, utf8, coroutine (io/os/package
  excluded: the core reaches the outside only through `host.*`). 330 KB component.
- **runner/**: wasmtime 37 with `wasm_exceptions` on; implements host-call generically
  (noop, now, monotonic_ms, getenv, sha256, read_file under a granted dir, sql_exec/sql_query on an
  in-memory SQLite).
- **scripts/bench.lua**: the same script runs natively (wa.exe, `WA_SCRIPT`, real host) and in wasm.

## Results (wasm_the_first, i7-12650H, Windows; 3 runs each)

| measure | native wa.exe | wasm component | |
| --- | --- | --- | --- |
| `host.sha256` × 100k (full host round trip) | 2.19–2.38 µs/call | 3.01–3.34 µs/call | bridge ≈ +0.8 µs/call |
| pure Lua call × 100k | 1.4–1.6 ms | 2.1–2.5 ms | ~1.5× |
| `pcall(error)` × 10k | 10.1–11.5 ms | 6.7–7.3 ms | wasm faster (EH unwind vs longjmp) |
| json.lua encode+decode, 200 items × 50 (pure-Lua compute) | 220–244 ms | 327–346 ms | ~1.45× |
| component compile (cold, uncached) | — | 330–341 ms | cacheable (`Component::serialize`) |
| instantiate | — | 0.1–0.2 ms | |
| new Lua state + load + run a trivial chunk | — | 0.07–0.08 ms | |
| SQL through the generic bridge | — | `[{"n":3,"vs":"a,b,c"}]` | works |

Reading: the interpreter in wasm costs ~1.45–1.5× on pure-Lua compute and ~0.8 µs per host call. The
agent core is I/O-bound (model calls take seconds, tool calls milliseconds), so this is noise in
practice. Error recovery (`pcall`, which the core uses everywhere) works and is faster.

## What broke on the way (all fixed in this spike)

1. **setjmp/longjmp**: Lua's error recovery needs them; wasm provides them through the
   exception-handling proposal — compile with `-mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false`,
   link wasi-sdk's `libsetjmp`, and enable `Config::wasm_exceptions(true)` (feature `gc`) in the host.
2. `lstate.h` includes `<signal.h>` (WASI has none): `-Dl_signalT=int`.
3. `ltablib.c` calls `clock()` (absent from Rust's bundled wasi-libc): `-D'l_randomizePivot()=0'`
   (removes only table.sort pivot randomization).
4. wasi-libc's `exit()` imports `wasi:cli/exit` `exit-with-code` (opt-in): host links WASI with
   `LinkOptions::cli_exit_with_code(true)`.

## What the full move needs

- **One generic `host-call` in the kernel.** 85 capabilities; almost all take strings and return JSON
  text (`push_json` pushes text) — bridge-friendly. Fastest transitional dispatcher: keep each
  existing `extern "C-unwind" fn(LuaState)` and drive it with a scratch native Lua state used only for
  marshaling (push args, call, read results) — zero rewrite of the 85; replace with typed WIT per
  capability seam over time.
- **Callbacks into Lua** (`http_stream`, `http_sse` call a Lua function per chunk via `lua_pcallk`;
  console/device ones like `panel`/`input_*` block on the terminal) need a host→guest shape: stream
  resources the guest polls (like `wa:kernel/websocket.recv`) instead of callbacks. ~6–8 capabilities.
- **Host-state capabilities** (`sql_exec`, `sql_query`, `plugins`, `invoke`, `client`, `client_status`
  are upvalue-bound) stay in the kernel; the bridge only forwards.
- **Binary-safe strings**: this spike passes `list<string>` (lossy UTF-8). The real interface should
  carry `list<u8>` for args/results (some capabilities move binary data, e.g. image base64 is fine but
  raw bytes are not).
- **Interpreter per request**: `serve` builds an interpreter per request. In wasm that is an instance
  per interpreter (0.1–0.2 ms) plus loading the core modules; use an instance pool, and pre-initialize
  the loaded core with Wizer-style snapshots so a request starts from a warm Lua state.
- **Compile cache**: precompile the component once per kernel (`Component::serialize`/`deserialize`),
  turning 330 ms cold compile into a load of a few ms.

Effort estimate (fast loop, builds on wasm_the_first): generic dispatcher + core-as-component running
the existing Lua test suite ~1.5–2 days; streaming/device capabilities reshaped ~1 day; `serve` and CLI
switched to the component behind a flag, pool + snapshot ~1–1.5 days. **≈ 3.5–4.5 days** to parity.

## Recommendation

Proceed with the carve-out. The cost is acceptable for an I/O-bound agent, error handling works, and
start-up per request is sub-millisecond once compiled. Order: (1) kernel `host-call` dispatcher with
the marshaling shim; (2) the existing Lua tests running inside the component; (3) streaming/device
capabilities as pollable resources; (4) `serve` on the component behind a flag, instance pool and
snapshot; (5) then split the core component along the WIT seams (providers, tools, MCP).

## Reproduce

```sh
# guest (wasi-sdk 34): CC_wasm32_wasip2=<sdk>/bin/clang AR_wasm32_wasip2=<sdk>/bin/llvm-ar \
#   WASI_SYSROOT=<sdk>/share/wasi-sysroot LUA_SRC=<repo>/rust/wa-host/vendor/lua
cargo build --release --target wasm32-wasip2 --manifest-path guest/Cargo.toml
cargo build --release --manifest-path runner/Cargo.toml
JSON_PATH=<repo>/lua/vendor/json.lua runner/target/release/luarunner guest/target/wasm32-wasip2/release/luaguest.wasm scripts/bench.lua <repo>
WA_SCRIPT=scripts/bench.lua JSON_PATH=... wa --db /tmp/b.db     # native baseline
```
