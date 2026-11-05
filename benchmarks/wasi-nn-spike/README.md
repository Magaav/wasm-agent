# Spike: speech-to-text / OCR as WASI modules via wasi-nn (05/11)

Question: does running inference from a wasm component through `wasi:nn` cost speed compared with
native ONNX Runtime? (The pure-wasm route - Candle in wasm - measured ~17x slower: benchmarks/whisper-wasm.)

Setup: Whisper-small **encoder**, int8 ONNX (`onnx-community/whisper-small`,
`onnx/encoder_model_quantized.onnx`, 92 MB), input `input_features` `[1, 80, 3000]` f32 (a 30 s window),
wasm_the_first (Windows, i7-12650H). 5 timed runs after a warm-up; the guest rebuilds the input tensor
every run so the copy into the host is measured.

| path | median | min | max |
| --- | ---: | ---: | ---: |
| native `onnxruntime` 1.31.1 (Python, `native.py`) | 966 ms | 673 ms | 1454 ms |
| wasm32-wasip2 component → `wasi:nn` → ONNX Runtime (`runner` + `guest`) | **517 ms** | 507 ms | 969 ms |

Reading: the tensor math is native in both; crossing from wasm costs only the input copy (~1 MB), noise
next to the compute. The two paths bundle different ONNX Runtime builds and thread defaults, so this
says "wasm costs nothing measurable", not "wasm is faster". Conclusion: STT and OCR can be WASI modules;
what remains is the pipeline around the model (mel features, decoder loop, tokenizer; OCR pre/post)
inside the component.

Build notes: `wasmtime-wasi-nn` 37 with `onnx-download`; pin `ort` **and** `ort-sys` to `=2.0.0-rc.2`
(the version wasmtime-wasi-nn 37 was locked against - newer rc's require a TLS feature and changed API).
The backend loads `<dir>/model.onnx`; the directory name is the graph name for `load-by-name`.

Run: `python native.py <model-dir> 5`; `runner/target/release/nnrunner guest/target/wasm32-wasip2/release/nnguest.wasm <model-dir> 5`.
