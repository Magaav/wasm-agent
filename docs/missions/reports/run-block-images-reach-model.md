# run-block-images-reach-model

A picture the model reads inside `run(code=...)` is a picture the model sees. Branch
`change/run-block-images-reach-model`, base `42f49385`, worktree
`/home/victor/Work/missions/run-block-images-reach-model/wt`.

## 1. Re-measured first (item 1), and what the brief got right and wrong

Method: a real agent turn driven by a stub `provider.complete_with` (the harness
`scripts/test-codemode-model-boundary.lua` uses), the real sandbox, and a real 800x600 PNG
(12,226 bytes, generated with zlib). Round two inspects the messages the loop actually built for
the provider. Run twice: once on a borrowed host binary, once on this tree's own build
(`v42f49385`, code-mode assets embedded). Same numbers both times.

| door | image parts in the next request | tool text |
|---|---|---|
| `run` block, `return await tools.read({path:"shot.png"})` | **0** | 795 bytes, carrying the reference table itself: `{"_images":[{"bytes":12226,"mime":"image/png","name":"shot.png","path":"/…/.wasm-agent/attachments/3c/3ca4….png","sha256":"3ca48…"}],…}` |
| `run` block keeping the picture (`const s = await tools.read(...); return {mime:s.mime}`) | **0** | 290 bytes, no picture and no reference |
| direct `read` of the PNG | **1** (sha256 `3ca48…`, 16,304 base64 bytes, one user message right after the tool block, labelled "Image returned by the preceding tool result: shot.png") | 351 bytes, clean |
| picture the USER pastes | **1** (same digest, "[Image #1]") | — |
| picture on a peer (`remote {capability:"read"}`) | **0** | `remote_image_transport_unsupported` |

What this settles:

* **The brief's headline is right, and the mechanism is one level deeper than it said.** The model is
  shown one tool, `run`. But a DIRECT `read` is not a second path either: `tools.dispatch` rewrites the
  model's own call into a one-line codemode script (`lua/core/tools.lua`, the wrap at "under code mode a
  tool the MODEL calls directly runs as the one-line script it stands for") and returns the script's own
  `value`. On base that value still carried `_images`, which is why a direct read worked while a run
  block did not: the promotion had no name to match, not a missing route.
* **The "unreadable strip" was not this bug.** The pasted 4x1086 PNG did reach the model as an image
  (Fable's ledger reading), and my probe reproduces the paste path delivering exactly what was captured.
  The strip was a wrong capture upstream of wa, and nothing in the pipeline said how big the picture was
  — which is item 7.
* **The model takes image input.** Confirmed twice: the paste door and the direct-read door both deliver
  an `image_url` part, and the session's own reasoning described what it saw.
* **A run block leaked more than silence**: it printed an absolute path in this node's attachment store
  and a digest as text. That is gone with the transport key.

## 2. A picture read inside a run block becomes an image (item 2) — `8143c3b9`

* `lua/core/codemode.lua` captures the reference from the dispatcher's own `read` (and only from it —
  `take_result_images`), removes the transport key from the value the script receives, and attaches the
  references to the run's result (`attach_result_images`). Both loops (native and component) go through
  the same `settle_call`, so both attach the same pictures.
* `lua/core/agent.lua` promotes `_images` for a call named `read`, `run` or `codemode` — one function,
  one mechanism: `materialize_tool_images` still places ONE provider image message after the complete
  tool-result block.
* `lua/core/tools.lua` carries the key out of the one-line wrap, so a direct read keeps working (this was
  a real regression I introduced and caught with the probe: the wrap returns only the script's `value`).
* **Fence:** only the dispatcher's built-in `read` may promote. A plugin's `_images` stays ordinary JSON in
  the script's value (measured: a synthetic `fixture_plugin` returning `_images` promotes nothing at the
  run result, and its path stays visible as text), and a call named `grep` carrying `_images` is not
  promoted at the model boundary either.
* **Bounds:** at most `MAX_IMAGES = 4` pictures, at most `MAX_IMAGE_BYTES = 12,000,000` source bytes in
  total, on top of the read tool's own 4 MB per picture. What the model is told when one does not fit
  (a field of the result, never silence):

  > A picture read in the script is attached to this result as an image. Read in the script but NOT attached: red-64x48.png (125 bytes: at most 4 pictures ride out of one run result). Read one again in a run of its own to see it.

  plus a structured `images_dropped = [{name, bytes, reason}]`.

## 3. A picture on a peer (item 3) — `5f95d54a`

`lua/core/remote_image.lua` is the whole protocol, in three functions:

* `request(args)` — a remote `read` asks for the bytes (`image_bytes: true`), on a copy: the model's own
  arguments are never mutated. An old peer ignores the field and answers exactly what it answered before.
* `offer(result, load)` — the peer half: for the built-in read's own picture, below the cap, it sends
  `image_data = {name, mime, sha256, bytes, base64}` **instead of** the reference (no path from the wrong
  machine ever crosses). Over the cap it refuses by name.
* `adopt(memory, result)` — the caller half: supported mime, `host.sha256(base64)` equal to the digest the
  peer named, encoded size under the cap, then `memory.store_image` here and a reference of THIS node's
  own. A mismatch stores nothing and refuses.

**The cap is 1,000,000 source bytes, not the read tool's 4 MB**, because a signed answer crosses
`wa-mesh`, whose own ceiling is `MAX_BODY = 4 * 1024 * 1024` (`rust/wa-mesh/src/http.rs:24`); 4 MB of
picture is 5.3 MB of base64, which cannot travel in a 4 MiB answer. 1 MB is 1.34 MB of base64. The
refusal says so:

> The picture (huge.png, 1000001 bytes) was not sent from that node: a peer transfer carries at most
> 1000000 bytes (the signed answer has a 4 MiB ceiling of its own). Read it on the node that holds it, or
> copy it here first.

Measured in-process with the peer stubbed at the wire seam (no rendezvous, no relay, no live node):
peer half sends 12,226 bytes with a matching digest and no reference; caller half answers one reference
whose file exists on this node (`path_kind = file`) and whose stored bytes are the picture; a lying digest
answers `remote_image_digest_mismatch` and stores nothing; a run block doing
`await tools.remote({node, capability:"read", path})` sends **one image part** and a 193-byte result text
with no reference table.

**Not covered, named:** the batch form (`capability:"batch"`) still refuses a picture per entry — the
per-entry references would each need their own adoption, and the budget was spent on the single call
Victor's test uses. And no two-node run was made: rule 13 forbids touching a live peer, and the wire
seam is where the decision lives, so the row stubs exactly that seam and says so in its header.

## 4. A model that takes no images (item 4) — `a307052c`

`lua/core/model_window.lua` gains the per-model fact (`M.image_input`, with the same override chain as the
other per-model facts: `WASM_AGENT_MODEL_IMAGES` on/off, `WASM_AGENT_MODEL_LIMITS` per model,
`M.WINDOWS[model].images = false`), `provider.image_input` delegates to it, and `agent.lua` threads the
model into the message builders. Measured with `WASM_AGENT_MODEL_IMAGES=off`, a run block reading the
64x48 fixture:

> this model takes no image input; the file is at /tmp/probe…/.wasm-agent/attachments/8c/8c8f….png, 64x48, 125 bytes

one sentence per picture, no image part, no base64, no reference table. The size comes from
`lua/core/image_meta.lua` (PNG/GIF/JPEG/WebP headers; unknown answers "pixel size not read", never a guess).

**The default is "send".** It is the behaviour this node MEASURED, not an assumption; a declared text-only
route is what gets the sentence. Sending an image to an undeclared text-only route fails loudly at the
provider, which is visible; refusing the picture for every model would remove a working feature.

## 5. The prompt cache (item 5): nothing before the image message moved

Two probes, base vs this tree, same code:

* `scripts/probe-prompt-bytes.lua`: `system_bytes 13539`, `envelope_bytes 786`, `prompt_bytes 14325`,
  catalogue `{guest:23, master:74}`, envelope `["run"]` — identical.
* A replay probe: a ledger written BY HAND in the OLD shape (a `run` tool result whose text carried the
  reference table, then a later user turn) is replayed through `agent:build_context` on both trees:
  `system 12392 bytes / sha256 97371001…`, `tools 786 / 4684aa73…`, whole turn list `13763 / 137baaf7…`
  — **identical**. An existing session's earlier turns replay byte for byte.

No tool description changed (the run tool's sentence is untouched), so the cached prefix of every live
thread is unaffected. The one thing that did change is a picture turn's own tool RESULT text (the reference
table is gone) — which is new content in the current turn, not a cached prefix.

## 6. Tests (item 6), and what fails on base

| row | checks | base result |
|---|---|---|
| `scripts/test-run-images.lua` (`3f7c56a4`) | 31 | **fails**: `the provider request carries exactly one image part for the picture the script read: expected 1, got 0` |
| `scripts/test-remote-image.lua` (`5f95d54a`) | 37 | **fails**: `the picture the peer sent is stored HERE and answered as this node reference` (1 expected, 0 got) |
| `scripts/test-image-meta.lua` (`617ac11b`) | 11 | **fails** on base (module absent; the row's header says why each format is pinned) |

Each is a fast-path row by the default rule (`scripts/test-*.lua` not in `scripts/fast-path.exclude`) —
no list to edit. `fixtures/run-images/{red,blue}-64x48.png` are real PNGs (125 bytes each, CRC verified).

## 7. The paste (item 7) — `617ac11b`

How wa chat reads a pasted picture (`rust/wa-capabilities/src/host.rs`):

* Ctrl+V is ONE clipboard read. **Wayland first** (`wl-paste --list-types`, then `wl-paste --no-newline
  --type <kind>`), **X11 second** (`xclip -selection clipboard -t TARGETS`, then `-t <kind> -o`); the
  Wayland arm runs when `WAYLAND_DISPLAY` is set in the process and `wl-paste` exists.
* **Which type wins:** an IMAGE always beats text — `CLIPBOARD_TYPES = [image/png, image/jpeg, image/webp,
  image/gif]` is tried in that order, and only if the list holds no image is the first text type taken
  (`text/plain;charset=utf-8`, `text/plain`, `UTF8_STRING`, `TEXT`, `STRING`). That is deliberate ("an
  image wins when a clipboard offers both"), and it is also the most likely explanation for the strip:
  a region grab on the clipboard wins over the HTML/text the browser put beside it. Nothing in wa crops
  or resizes — it stores the bytes it read, which is why the paste path delivered the strip faithfully.
* **What is new:** the paste notice now carries the pixel size, and a picture under 16 px on either side
  says so in the same row, before the message is sent:

  > [Image #1] attached (11 KB, 800x600)
  > [Image #1] attached (11 KB, 4x1086) - that looks like a stray selection: paste again

  The token text stayed `[Image #N]` on purpose: it is a contract two parsers share (`submitted_tokens`
  in the host and the `%[Image #(%d+)%]` scan in `lua/core/chat.lua`), and changing it to carry the size
  would have put the attachment at risk for a cosmetic win. The size rides beside it in the notice row.

This also found and fixed a real defect in both header readers (Rust `picture_size`, Lua
`image_meta.lua`): JPEG segment lengths and frame sizes are BIG-endian, and reading them little-endian
turned a 16-byte segment into 4096 and walked off the file. The Rust unit test caught it first; the Lua
row pins it now.

## 8. What I could not verify

* **A live two-node picture transfer.** No live peer may be touched (rule 13) and a scratch rendezvous was
  not stood up; the wire seam is stubbed instead, in the shape the real call produces. The first real use
  (nextcloud) is the check that remains.
* **A real provider accepting the image part.** Every measurement here is at the request boundary, where
  the defect was; the provider is stubbed so nothing was billed. The model's own image input is evidenced
  by the pasted picture in session 6a89dcbc, not re-tested here.
* **The batch picture path** (see §3) — still refused per entry.
* `tests/image-roundtrip.lua` and `tests/image-read.lua` (handoff-era tests, not rows) were not re-run;
  the image store itself is untouched.
* Two `wa-capabilities` tests (`operations::adoption_survives_the_relay_deadline`,
  `operations::await_returns_at_its_own_wait`) refuse to run without a scratch HOME. With
  `HOME=$(mktemp -d)` the whole crate is green: **391 passed, 0 failed**.

## 9. Proposed FACTORY.md / HANDOVER.md text (not written)

> **A picture is a route, not a shape.** `_images` is a transport key, not data: only the built-in `read`
> creates it, only `lua/core/remote_image.lua` adopts one from a peer (verified against the digest the peer
> named), and every other producer's `_images` is ordinary untrusted JSON. What the model receives is one
> provider image message after the complete tool-result block — whether the picture came from a direct
> read, a run block, or a peer.

> **Bounds are spoken.** A picture dropped for a count, byte or transport bound is named in the result
> (file, size, the bound it hit), never dropped in silence: `codemode.MAX_IMAGES`/`MAX_IMAGE_BYTES`
> locally, `remote_image.MAX_BYTES` across nodes. A silent drop reads to a model as "there was nothing".

> **A peer's answer carries 4 MiB** (`wa_mesh::http::MAX_BODY`). Anything a node sends inside a signed
> answer — a picture, a file body — must fit `base64(1.33×bytes)` inside that, and the cap it is refused
> at belongs in the refusal text, with the number.

## 10. Texts to approve (verbatim, model- or operator-facing)

1. `A picture read in the script is attached to this result as an image. Read in the script but NOT attached: <name> (<bytes> bytes: <reason>). Read one again in a run of its own to see it.`
2. the bound reasons: `at most 4 pictures ride out of one run result`, `their total is capped at 12000000 bytes`
3. `this model takes no image input; the file is at <path>, <w>x<h>, <bytes> bytes`
4. `pixel size not read` (in place of `<w>x<h>` when a header is not understood)
5. `The picture (<name>, <bytes> bytes) was not sent from that node: a peer transfer carries at most 1000000 bytes (the signed answer has a 4 MiB ceiling of its own). Read it on the node that holds it, or copy it here first.`
6. `the stored copy of <name> could not be read on the node that holds it`
7. `the peer said it sent <name> but sent no picture data`
8. `the peer sent <name> as <mime>, which this node does not store`
9. `the picture the peer sent is not the one it named (<name>): nothing was stored, and the refusal is the whole answer`
10. `the picture was stored under a different digest than the one the peer named`
11. `[Image #1] attached (11 KB, 800x600)` — and with a stray selection: `[Image #1] attached (11 KB, 4x1086) - that looks like a stray selection: paste again`
12. `[Image #1] attached (11 KB)` (header not understood — no size is invented)

## 11. The narrowed run (suite rule), measured

`flock -o ~/Work/missions/.suite.lock env WA_FAST_ROWS=/tmp/rows-ok.txt bash scripts/fast.sh --jobs 6` with the 32
rows this branch's paths map to (the planner's own rule: a changed `lua/core/*.lua` selects the rows named after
it and every row that mentions it), plus the never-dropped core rows and every contract check:

    fast: narrowed by the landing plan: 56 of 341 Lua rows
    fast: lua 56/56 passed
    fast: rust wa-capabilities ok (10s)
    fast: prompt-docs ok
    fast path ok (142 checks, 0 skipped, 554s)

The first attempt was red in one row and that red was real: `scripts/test-refusal-contract.lua` refused
`lua/core/refusal_codes.lua is stale` because the transfer adds six codes. `lua5.4 scripts/gen-refusal-codes.lua
--write` regenerated it (`185fea03`), the row then reported `17353 checks passed`, and the run above is the one
after it. `wa-capabilities` was also run directly with a scratch HOME: 391 passed, 0 failed.

