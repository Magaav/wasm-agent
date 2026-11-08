# WhatsApp image OCR and audio transcript indexing

Status: **implemented in the connector and in the component, not yet a live
acceptance claim** (the component's path has native tests and a parity harness;
it has not run against the node's real OCR venv in an acceptance run).

The linked-device connector journals text, audio transcripts and image OCR text
locally. It does not send images, does not expose media keys and does not use a
hosted OCR/STT provider.

Two implementations exist side by side, and this document describes both:

| | provider of OCR | where the text lands |
| --- | --- | --- |
| **old bridge** (native `wa-whatsapp` release) | `whatsapp-ocr-local.py`, spawned by the connector | `messages.media_text` |
| **component** (`rust/components/wa-whatsapp`, `wa:kernel@0.2`) | the kernel's text reader, which runs the *same* script (`wa:kernel/vision`) | the index record's `ocr` field |

The cutover finding that produced the component path (08/11): the component imported
only http/kv/lifecycle/speech/types/websocket/queue, so switching the connector off
would have silently dropped image OCR while voice notes kept working. The
component's world now imports `wa:kernel/vision@0.2.0` and its manifest grants
`ocr: true`; `scripts/test-whatsapp-send.lua` fails if either goes away.

## A chat hold gates posting, not indexing

Indexing an image (and transcribing audio) is a **local derive with no external
effect**, so a `chat_holds` row annotates the queued task instead of fencing it:
`media_reason = source_hold_index_only` / `audio.reason = source_hold_transcription_only`.
Before this, one unproven mutation in a chat marked every later image
`media_state = blocked_source` and the OCR worker never saw it; Fernanda's two
27 Oct screenshots were lost that way. A **proven per-message fence** is different
and still absolute: a `source_blocks` row (revoke/edit/delete naming that exact ID)
stops the media before indexing, and the outbox/`Ready`/`Send` path keeps refusing
to post anything from a held chat.

History is recoverable on request, not silently: `wa-whatsapp reindex --state
<private-dir> [--chat <exact-id>] --confirm` re-queues faded audio/media rows in one
transaction, skips every row with a `source_blocks` entry, releases no hold, writes
no outbox row, and records one `hold_rederive` event with the counts. It is an
offline owner command: stop the service, run it, start again.

## OCR choice

**RapidOCR (PP-OCR ONNX)** is the local OCR stack. It was chosen over Tesseract for
screenshot/document accuracy and over PaddleOCR because PaddleOCR segfaulted on this
ARM64 host during a real recognition test. RapidOCR recognized a 1000x260 Portuguese
fixture in ~4.5 s on two ARM cores, including accents and `R$ 1.234,56`; PaddleOCR
did not complete recognition.

The recognition model is the **Latin PP-OCRv5 mobile** ONNX model, not RapidOCR's
default Chinese/English recognizer. With
`WA_WHATSAPP_OCR_REC_MODEL=…/latin/inference.onnx` and
`WA_WHATSAPP_OCR_REC_KEYS=…/latin/keys.txt`, the same fixture recognized
`Convênio` correctly and improved confidence from 0.976 to 0.994; run time was
4.21 s versus 4.41 s for the default model. If the env pair is unset the worker
uses the bundled default recognizer; if only one is set, or a path is missing, it
fails as `offline_model_unavailable` instead of silently falling back.

- package: `rapidocr_onnxruntime==1.4.4`
- recognition: `PaddlePaddle/latin_PP-OCRv5_mobile_rec_onnx` (`inference.onnx` + `keys.txt`)
- runtime: ONNX Runtime 1.31.0 (already present for the STT VAD stack)
- engine: one warm Python worker, newline JSON, no network at message time
- language: the Latin/Portuguese script; `pt` is the configured hint, not translation
- limits: 20 MiB image, 12,000 output characters, confidence >= 0.5, 2-minute worker deadline

Install the private OCR venv on the connector host (setup-time network, never at
message time):

```sh
python3 -m venv /home/ubuntu/.local/wa-ocr-rapid
/home/ubuntu/.local/wa-ocr-rapid/bin/pip install "rapidocr_onnxruntime==1.4.4"
# Latin recognition model and its 836-character dictionary
mkdir -p /home/ubuntu/.local/wa-ocr-rapid/latin
curl -L -o /home/ubuntu/.local/wa-ocr-rapid/latin/inference.onnx \
  https://huggingface.co/PaddlePaddle/latin_PP-OCRv5_mobile_rec_onnx/resolve/main/inference.onnx
curl -L -o /home/ubuntu/.local/wa-ocr-rapid/latin/inference.yml \
  https://huggingface.co/PaddlePaddle/latin_PP-OCRv5_mobile_rec_onnx/resolve/main/inference.yml
python3 - <<'PY'
import yaml
chars = yaml.safe_load(open('/home/ubuntu/.local/wa-ocr-rapid/latin/inference.yml'))['PostProcess']['character_dict']
open('/home/ubuntu/.local/wa-ocr-rapid/latin/keys.txt', 'w', encoding='utf-8').write('\n'.join(chars) + '\n')
PY
```

## Connector pipeline

1. `adapter.mapMessage` stores the image protobuf in `messages.raw` (never for
   view-once or ephemeral media) and keeps an image caption in `body`.
2. `ingest` sets `media_kind='image'` and a `media_state`:
   `pending` at/after the activation cutoff, `journal_only` before it,
   `unsupported` for view-once/ephemeral/oversized/mime failures, or
   `blocked_source` for a source/target fence or a compute hold (a posting-only
   hold from an unproven targeted revoke does not block OCR).
3. `processMedia` downloads the exact image with the same bounded media client,
   writes a private temp file, calls the OCR worker, deletes the temp file and stores
   the text in `messages.media_text`.
4. `read_snapshot` exposes `media_kind`, `media_state`, `media_text` and
   `media_reason`; literal `query` searches `body`, audio `transcript` and
   `media_text`. The MCP server needs no new tool: code mode composes these reads.

The OCR worker is enabled by default for a new generation. `ocr_disabled:true` in
the connector config keeps images journaled without OCR. This is an offline config
change; stop the owned service before changing it.

## Audio transcript posting toggle

`transcript_posting` is separate from transcription. Audio is always transcribed for
the journal when the worker is healthy. A reply is queued only when all of these hold:

- the source audio is incoming or own outgoing (`own` is not a reason to skip it);
- `transcript_posting` is enabled;
- the audio is at/after the activation cutoff, not view-once/ephemeral and its chat is not held.

The reply quotes the audio message and its body is:

```text
🤖 _Copiloto_
<transcribed_message>
```

Long audio is numbered `🤖 _Copiloto_ (i/n)`. The outbox primary key
`(account,generation,chat,source,part)` makes the queue idempotent; an unknown send
is never replayed. Enable/disable offline:

```sh
wa-whatsapp posting --state "$STATE" --set enable
wa-whatsapp posting --state "$STATE" --set disable
```

Default is **off**. A UI checkbox must control this connector policy; it must not be
an MCP send tool. General model sends remain refused.

## STT dependency note

The local STT stack is `faster-whisper==1.2.1` with the multilingual `small` model,
CPU/int8. **Pin `av==18.1.0`**: PyAV 19 removed the `metadata_errors` argument that
faster-whisper 1.2.1 still passes, so transcription fails with
`local_compute_unavailable` on PyAV 19. The model cache must contain the full
`Systran/faster-whisper-small` snapshot (about 464 MiB), not only metadata.

## The component path

Same worker, same bounds, one more hop. The image is read by the kernel's own
warm worker, exactly as a voice note is transcribed by the kernel's recognizer.

1. **The index lane writes the record first.** An image message becomes an index
   record like any other (`ix/m/<chat>/<inv(ts)>/<id>`); only after that write does
   the record join the OCR inbox, so text can never be attached to a record that
   does not exist.
2. **The OCR lane reads one image per pipeline tick.** One at a time on purpose:
   the kernel keeps one warm worker, so a second concurrent read would only queue
   inside the kernel. The bytes are fetched with `download_from_params` and the
   record's own media keys - the same bounded client the query lane's
   `whatsapp_download` uses - never by re-reading a chat.
3. **`wa:kernel/vision.read(image, mime)`** (WIT: `wit/kernel-v2/kernel.wit`,
   `interface vision`; host: `rust/wa-kernel-runtime/src/vision_host.rs`,
   `service_ocr.rs`) starts `scripts/whatsapp-ocr-local.py --worker` on demand
   under `nice -n 10`, keeps it warm, takes one image at a time from a **bounded**
   queue (a fifth concurrent request is `again`, never a block), kills it at the
   2-minute deadline, and restarts it after a crash. The kernel retries a lost
   worker **once**.
4. **The text is attached to the record** with `index::attach_text(…, Source::Ocr)`:
   the same `ocr` field a search already reads, bounded to `record::MAX_TEXT`
   characters like a transcript. So `whatsapp_search` finds a photo by what it
   shows with no new query path, and a revoke deletes the OCR text with the rest.

**Bounds and privacy, unchanged from the old bridge.** 20 MiB per image
(`ocr::MAX_IMAGE_BYTES`, refused before the download *and* before the reader);
12 000 output characters and the 0.5 confidence floor are the worker's own
(`scripts/whatsapp-ocr-local.py`), so the component must not add a second opinion;
2-minute worker deadline; no image bytes, no text and no media key in any log line -
the lane logs `chat`, `id`, `chars`, `bytes`, `download_ms` and a reason word only.
A failure is classified once: `no_text_detected`, `image_too_large`,
`unsupported_media`, `ocr_text_too_long` and an unprovisioned reader are
**permanent** (never retried, never re-downloaded); a stalled/timed-out worker, a
full queue (`busy`) and a disconnected client are retried, an image at most twice.

**The backlog.** Images indexed without OCR text - the lane was off, the node
restarted mid-download, or a history sync wrote the record - are read by a bounded
background pass: `index::ocr_backlog(budget)` scans `ix/k/image` and
`ix/k/document` (newest first, one bounded read), and the lane refills its inbox
from it when the inbox is empty, one image per tick, under the same media limits.
Nothing is re-downloaded that the limits would refuse, and an image whose size the
record already reports as over the bound is refused from the record without a
fetch.

**Configuration** (service definition `config`, defaults in parentheses):
`index_ocr` (`true`) turns the lane off without touching the index; a node whose
OCR venv is not provisioned sets `false` rather than logging a refusal per photo.
`index_ocr_every_seconds` (`60`) is the backlog refill cadence and
`index_ocr_budget` (`8`) how many images one refill may queue.

**Policy.** The call is `ocr.read`, asked after the manifest grant, exactly as
`stt.start` is: a node with a `policy.json` and no rule for it refuses the call
(`no_policy`) rather than starting a worker; a node in manifest mode relies on the
manifest grant alone. The reader returns the text to the guest, the guest owns the
index it lands in, and the kernel never writes a component's text anywhere.

**Tests** (`cargo test -p wa-kernel-runtime service_ocr`, `cargo test --lib ocr::`
in `rust/components/wa-whatsapp`):

| claim | test |
| --- | --- |
| the same worker text is attached verbatim, accents and newlines intact, and a photo becomes searchable | `ocr::tests::the_reader_text_is_attached_verbatim_and_bounded_by_the_record_limit`, `…::an_image_is_ocred_attached_and_found_by_its_text` |
| an oversized image is refused cleanly before the reader runs | `ocr::tests::an_oversized_image_is_refused_cleanly_and_the_reader_is_never_started`, `service_ocr::tests::an_oversized_image_is_refused_cleanly_before_any_worker_starts` |
| a crashed worker is restarted and the job retried once | `service_ocr::tests::a_crashed_worker_is_restarted_and_the_job_retried_once`, `…::a_worker_that_stays_dead_fails_after_one_retry_instead_of_looping` |
| a wedged worker is dropped, the queue is bounded | `service_ocr::tests::a_stalled_worker_is_dropped_and_counts_as_a_failure`, `…::the_queue_is_bounded_so_a_burst_cannot_park_the_kernel` |
| a second image never reloads the engine | `service_ocr::tests::a_second_image_does_not_reload_the_engine` |
| only images and image documents are read; a PDF, a revoked or an already-read record is skipped | `ocr::tests::only_images_and_image_documents_are_read`, `…::a_revoked_or_already_read_image_is_skipped` |
| the backlog lists unread images only and stops at its budget | `ocr::tests::the_backlog_lists_images_without_ocr_text_and_stops_at_its_budget` |

`scripts/test-waocr-parity.py` is the parity harness for a host that has the OCR
venv: it drives `scripts/whatsapp-ocr-local.py --worker` twice on the same fixture
(the same script the kernel runs) and reports `SKIP` with the reason when
`rapidocr_onnxruntime`, the model pair or the fixture is absent - it never claims a
parity run it did not do.

## Limits

- Image messages, and documents whose media type is an image, are OCRed. A PDF is
  not: it needs a text-extraction path this component does not have (the old bridge
  had none either).
- Images received before this path was deployed have no stored raw protobuf, so they
  cannot be OCRed retroactively. In the component, a record with no media keys is
  `not_downloadable`, and the backlog pass skips it.
- The component path is tested natively (fake reader, fake worker) and by the parity
  harness; it is **not** yet a live acceptance claim on the node's real OCR venv.
- OCR is text extraction, not visual reasoning or translation. Layout, charts and
  unreadable handwriting can be lost.
- History coverage and upstream redelivery are not guaranteed.
