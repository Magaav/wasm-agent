# Warm Whisper WASM benchmark

This is an experimental Rust/Candle core WASM plugin, separate from the
WhatsApp job. It uses the wasm-agent plugin exports `memory`, `alloc`,
`describe`, and `call`, plus `free` for returned JSON and `asset` for
one-time binary model transfer. The host accepts `free` optionally so older
plugins remain valid. This experiment's `asset` export is exercised by the
runner but not wired into the WhatsApp job. The module has **zero imports**
and cannot access the filesystem or network.
The Wasmtime runner supplies local weights, keeps one instance alive, makes one
warmup transcription, then times three repeated transcriptions.

The model assets are not included in this repository. For each model, place
`model.safetensors`, `config.json`, and `tokenizer.json` from
`openai/whisper-tiny` or `openai/whisper-small` in a local model directory,
plus `mel_filters.safetensors` from the
[`lmz/candle-whisper` Space](https://huggingface.co/spaces/lmz/candle-whisper/tree/main).
The benchmark reads these files locally. The runtime makes no download attempt.

Build the no-import module using Rust's `wasm32-unknown-unknown` target:

```sh
RUSTFLAGS='--cfg=getrandom_backend="custom"' cargo build --release --target wasm32-unknown-unknown --manifest-path benchmarks/whisper-wasm/Cargo.toml
cargo run --release --manifest-path benchmarks/whisper-wasm/runner/Cargo.toml -- benchmarks/whisper-wasm benchmarks/whisper-wasm/fixtures/unique.f32 /path/to/model-directory
```

The runner's `imports: []` line proves compatibility with the no-import
Wasmtime host. Run the current engine on the same decoded PCM:

```sh
python benchmarks/whisper-wasm/bench-native.py benchmarks/whisper-wasm/fixtures/unique.f32 tiny /path/to/faster-whisper-model-cache
python benchmarks/whisper-wasm/bench-native.py benchmarks/whisper-wasm/fixtures/unique.f32 small /path/to/faster-whisper-model-cache
```

Run 0 is warmup in both commands. The model is loaded before all four calls;
the medians below use runs 1–3. The fixture is 9.7 seconds of synthetic English
speech saying, “Please call me when the train reaches the station. We will meet
beside the blue clock at 6. Bring the maps and leave the heavy bags at home.”

| Model | Native faster-whisper CPU int8 median | Candle WASM CPU fp32 median |
| --- | ---: | ---: |
| Multilingual tiny | 0.335 s | 4.477 s |
| Multilingual small | 1.902 s | 32.125 s |

Measured 2026-09-23 on an Intel i7-12650H, Wasmtime 37.0.3, Candle 0.11.0.
The WASM output had the same words as the native output on this fixture.
Native faster-whisper uses CTranslate2 int8 and native CPU threads. Candle uses
fp32 and one WASM thread, so these are deployment-engine comparisons, not an
isolation of WASM overhead. Both timed paths include audio feature computation
and greedy decoding; the WASM path also includes JSON/base64 transfer.

An exploratory SIMD build used `-C target-feature=+simd128` and a local patch
to Candle 0.11.0 that keeps f16/bf16 operations scalar where the upstream
module references missing `CurrentCpuF16` and `CurrentCpuBF16` types.
Its medians were 4.414 s for tiny and 30.966 s for small. These values are
not in the table because the required upstream patch is not part of this
reproducible build.

This module is a proof of the plugin boundary, not a production transcription
backend. It supports at most 30 seconds of 16 kHz mono PCM, assumes a caller
has decoded audio, and takes an explicit language. The existing WhatsApp job
launches a fresh `wa` process each tick, so adopting a warm WASM recognizer
would also require a resident worker and a host-side asset-loading contract.
The deterministic hash seed in this benchmark must be replaced by host entropy
for production use.
