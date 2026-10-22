# WhatsApp original-language audio transcription

Canonical service/setup: [WHATSAPP-CONNECTOR.md](WHATSAPP-CONNECTOR.md).
Mandatory cutover: [WHATSAPP-MIGRATION.md](WHATSAPP-MIGRATION.md).

The linked-device service journals incoming AND synchronized own outgoing audio.
Ingestion, independent durable compute tasks and held/confirmed outbox parts are
separate. Incoming audio **and synchronized own outgoing audio** are posted when transcript
posting is enabled; both are transcribed for the journal and reply-linked. One failure
does not block ingestion, and downtime backlog after the explicit first activation
cutoff is not expired after ten minutes. Initial history is never bulk-posted. No
general AI responder, read marking or composer action.

A persistent private local `faster-whisper` worker loads multilingual `small`,
CPU/int8, beam5/VAD once. Model cache provisioning is separate; message processing
is offline/local-files-only with NO hosted fallback. Missing cache/media, unsupported
view-once/ephemeral/large audio and no-speech remain visible.

Product default: **EN (`en`)**. This operator must explicitly persist **PT (`pt`)**
per account (`wa-whatsapp init ... --language pt`, or stop service then
`wa-whatsapp language --state <private-path> --language pt`). Status exposes the setting.
`auto` is explicit original-language detection. A speech-language hint is NOT
cross-language translation; translation mode is unsupported, not silently rerouted
to another language/provider. Queued tasks retain their language snapshot.

Marked UTF-8/rune-safe numbered transcripts are `🤖 _Copiloto_` followed by the text
and reply-link to the source audio in the original chat. `transcript_posting` is a
separate toggle, default **off**; enable/disable offline with
`wa-whatsapp posting --state <private-path> --set enable|disable`. Reserve/dispatch
uncertainty is persisted before posting; unknown sends never auto-retry. Server
acceptance is not a recipient delivery/read receipt.

Pin `av==18.1.0`: PyAV 19 removed `metadata_errors`, which faster-whisper 1.2.1 still
passes. The model cache must contain the full multilingual `small` snapshot.
Image OCR is separate: see [WHATSAPP-OCR.md](WHATSAPP-OCR.md).
No live STT quality, media compatibility or message delivery is claimed from fixtures.

Former browser pipeline documentation is retained as
[historical evidence](history/whatsapp-browser/WHATSAPP-TRANSCRIPTION.md), not current setup.
