# WASI 0.3 spike — async export consuming a host `stream<list<u8>>` (step 0, 2026-11-05)

Question: can wasmtime 50 host a component whose exported **async** function reads inbound frames
from a host resource as a WASI 0.3 `stream<list<u8>>` — the shape `wa:kernel/websocket` would take
in `wa:kernel@0.2` — and what does a frame cost?

- `wit/spike.wit`: resource `conn` (`open`, `messages() -> stream<list<u8>>`); world exports
  `run: async func(...) -> tuple<u32, u64>`.
- `guest/`: Rust, wit-bindgen 0.63 (its default `async` feature), built for **`wasm32-wasip2`** —
  std still imports WASI 0.2.9 (`wasi:cli`, `wasi:io`), while the custom interface uses the
  component-model async ABI. Mixed is valid (`wasm-tools validate --features all`). 70 KB.
  `wasm32-wasip3` is in rustc 1.98's target list but was not tried (tier 3, no prebuilt std).
- `runner/`: wasmtime 50.0.1 with `component-model-async`; `Config::wasm_component_model_async(true)`;
  bindgen `imports: { "...[method]conn.messages": store }`, `exports: { default: async | store }`;
  a `StreamProducer` over a futures `mpsc` channel fed by a tokio task (the socket pump stand-in);
  `store.run_concurrent(...)` drives the call. WASI 0.2 imports via `wasmtime_wasi::p2::add_to_linker_async`.

Run (wasm_the_first, i7-12650H, Windows): `bash build.sh <target-dir>`.

| frames × size | interval | run | per frame |
| --- | --- | --- | --- |
| 10 000 × 512 B | 0 | 25.6 ms | 2.56 µs |
| 100 000 × 64 B | 0 | 266 ms | 2.66 µs |
| 2 000 × 4 KiB | 100 µs | 30.7 s | 15.3 ms ← Windows timer granularity (~15.6 ms per tokio sleep), not wasm |

Compile 72–76 ms (cold, no cache); instantiate 0.16–0.34 ms. Every frame crosses host task → channel
→ producer → guest `next().await`, so ~2.6 µs is the full per-message overhead of the async path —
negligible next to WhatsApp traffic (tens of messages per second at peak).
