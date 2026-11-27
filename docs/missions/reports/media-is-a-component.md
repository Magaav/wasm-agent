# media-is-a-component (Victor 27/11): ffmpeg controls media, as a WASI component

Branch `change/media-is-a-component`. First slice: is ffmpeg-on-wasm fast enough to be the engine at all,
and what does its contract look like. The measurement came first, as the item demands.

## The measurement (30 s 720p, 28.5 MB, h264 + aac)

libav* (ffmpeg 7.1) and libx264 built for wasm with wasi-sdk 34, run under wasmtime 36:

| operation | wasm | native (16 cores + SIMD) |
|---|---|---|
| probe (header only) | 8.1 ms | - |
| 5 frames, scaled to 640x360, written | 98 - 136 ms | - |
| audio track -> 16 kHz mono s16 | 85 - 98 ms | - |
| **the three together** | **0.19 - 0.24 s**, peak RSS ~60 MB | - |
| compress 720p -> 480p h264 | **41 - 56 s** (encode 33 - 43 s), 3.04 MB out | **1.24 s**, 3.01 MB |

So the INDEXING path - what a video needs to be searchable - costs a quarter of a second. The on-demand
`compress` family is ~35x native and slower than realtime, because x264 on wasm has no assembly and no
SIMD128 path (`using cpu capabilities: none!`) and no threads. No non-WASI fallback was added: that is
Victor's call, which is the open question in the ready file.

## What is proven, and what is not

* Proven by running it: decode (h264, aac), scale, five stills, audio extraction and resampling, and a full
  30 s 480p H.264 encode, all inside wasm, with the numbers above.
* **Not proven: the `frames` output as JPEG.** ffmpeg's own mjpeg encoder traps on wasm
  (`out of bounds memory access` inside `ff_mpv_encode_picture`), reproduced in a 20-line program with one
  synthetic frame and no decoder, and with `YUV420P` + `color_range` as well as the removed `YUVJ420P`. The
  stills in the measurement are PPM. The next step there is libjpeg-turbo for wasm, not more poking.
* **Not done: the component itself.** No Rust crate, no build wiring, no rows. `wit/media/media.wit` is the
  contract they will be written against.
* wasi-sdk 34's wasip2 components import `wasi:cli/exit@0.2.12`, which neither wasmtime 27 nor 36 implements,
  so the measurements are a wasm32-**wasip1** module built from the same objects. The component model
  packaging is a separate step and the node's own runtime already runs wasip2 components.

## The contract (`wit/media/media.wit`)

Its own package, not an interface in `wit/kernel-v2/kernel.wit`: that file is copied byte for byte into
six components' `wit/deps/` and a row compares the copies, so an interface added there edits six components
in one commit. `wa:media@0.1.0` carries `probe.describe`, `frames.take` and `audio.extract` - each taking a
`file` and answering either a small record or more `file`s, never media bytes. `cut`/`trim`/`compress`/
`thumbnail` land there once the encoder question is answered.

## What is left, in order

1. The encoder decision (the ready file's question).
2. libjpeg-turbo for wasm, so `frames` answers JPEG.
3. The component crate + build wiring (C libraries in a Rust component: `cc` cross-compiling for wasip2, or
   a vendored build with a reproducible recipe), and rows on fixtures.
4. The WhatsApp side: a video indexed like a voice note (audio -> stt, frames -> vision), calling the vision
   component that codemode-seam-leaves-the-host is building - not duplicating it.
