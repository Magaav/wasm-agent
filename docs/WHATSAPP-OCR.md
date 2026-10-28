# WhatsApp image OCR and audio transcript indexing

Status: **implemented in the connector, not yet a live acceptance claim.**

The linked-device connector journals text, audio transcripts and image OCR text
locally. It does not send images, does not expose media keys and does not use a
hosted OCR/STT provider.

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
   `blocked_source` for a held chat.
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

## Limits

- Only image messages are OCRed. Documents/PDFs remain unsupported until a separate
  text-extraction path exists.
- Images received before this path was deployed have no stored raw protobuf, so they
  cannot be OCRed retroactively.
- OCR is text extraction, not visual reasoning or translation. Layout, charts and
  unreadable handwriting can be lost.
- History coverage and upstream redelivery are not guaranteed.
