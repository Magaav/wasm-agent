# HANDOFF — step 0: wasmtime 37 → 50 + WASI 0.3 spike (branch change/wasmtime-50, WIP, not pushed)

Base: origin/main 0ac3c606. Built only on wasm_the_first. Nothing deployed, nothing pushed.

## Done
- `rust/wa-host/Cargo.toml`: wasmtime / wasmtime-wasi 37 → 50 (resolved 50.0.1); wasmtime feature
  `anyhow` added (wasmtime::Error is no longer anyhow::Error; the feature gives `?` into anyhow).
- API fixes:
  - `service_components.rs`: bindgen `with` keys now use `.` before the resource
    (`"wa:kernel/websocket.socket"`, `http.pending`, `speech.job`).
  - `core_component.rs`: `DirPerms/FilePerms` → `FsPerms::ReadWrite`; `LinkOptions::cli_exit_with_code`
    is gone (exit-with-code always linked) → plain `p2::add_to_linker_sync`.
  - `quickjs.rs`: the 6 `func_wrap` closures returning anyhow `Result` are wrapped to return
    `wasmtime::Result` via `.map_err(wasmtime::Error::from_anyhow)`.
  - `services.rs`: epoch callback returns `wasmtime::Error::msg("service_stopped")`.
- `cargo build --release -p wa-host` passes (exit 0, 15 warnings).
- `cargo test --release -p wa-host`: 201 passed, 0 failed.
- `benchmarks/wasi03-spike/`: WORKS on wasmtime 50 (component-model-async). Rust guest
  (wit-bindgen 0.63, target wasm32-wasip2, 70 KB) exports `run: async func` reading a host
  `stream<list<u8>>` from resource `conn`. ~2.6 µs per frame (10k×512 B 25.6 ms; 100k×64 B 266 ms),
  instantiate 0.2–0.3 ms, compile ~75 ms. Results in its README.md.
- wit-bindgen C async: supported at the raw ABI level in 0.63 (`crates/c/src/lib.rs`
  generate_async_helpers: waitable sets, subtask/stream/future events, callback codes; runtime tests
  `tests/runtime/simple-stream*`, `simple-future`, `pending-import` have `.c` sources). No high-level
  runtime — the Lua guest can keep sync host imports.

## Not passing / not done
1. `services::tests::fixture_service_runs_dials_and_stops` FAILS (panic at services.rs:699) when
   `WA_TEST_SERVICE_WASM` points at svc-echo. Not yet known if pre-existing on 37 — check on main first.
2. Gate component blocks did not really run: `build-components.sh` produced nothing in the proof dir
   (mcp-echo/svc-echo "not installed") and agent-core wasm was "not found". Likely gotcha: the gate
   script exported `CARGO_TARGET_DIR` globally, so component/agent-core builds landed there instead of
   their own `target/`. Unset it for those builds and re-run.
3. Full `scripts/test.sh` not run.
4. `docs/KERNEL.md` "WASI 0.3 step 0" section not written (wasmtime version, host changes, spike
   result, C verdict, proposed `wa:kernel@0.2` async shape: websocket `recv` → `messages() ->
   stream<list<u8>>` + async `send`; http `start/poll` → `send: async func(request) -> result<response>`
   with body as stream; speech `start/poll` → `recognize: async func(...)`; kv stays sync).
5. Benchmarks under `benchmarks/*-spike` still on wasmtime 37 (standalone crates, untouched).
6. Not rebased / not merged to main; not deployed (deploy only after gate passes, via sentinel).

## Commands (wasm_the_first, Git Bash)
- Host build: `bash C:/Users/Victor/wa-build/w3-host.sh` (CARGO_TARGET_DIR=C:/Users/Victor/wa-build/host-target-w3, WA_CODEMODE_ALLOW_EMPTY=1) → log `w3-host.log`.
- Gate: `bash C:/Users/Victor/wa-build/w3-all.sh` (build + `w3-gate.sh`) → `w3-gate.log`. Fix item 2 in w3-gate.sh first.
- Spike: `bash benchmarks/wasi03-spike/build.sh C:/Users/Victor/wa-build/w3-spike-target`.
- agent-core needs WASI_SDK=C:/Users/Victor/wasi-sdk-34.0-x86_64-windows.

## Gotchas
- Windows tokio sleep granularity ~15.6 ms (spike interval case measures the timer, not wasm).
- Push only as Magaav from wasm_the_first; rebase on origin/main and check `git diff --stat` for unexpected deletions (stream C may touch capabilities.rs).
