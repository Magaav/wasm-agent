# WhatsApp original-language audio transcription

Canonical service/setup: [WHATSAPP-CONNECTOR.md](WHATSAPP-CONNECTOR.md).
Mandatory cutover: [WHATSAPP-MIGRATION.md](WHATSAPP-MIGRATION.md).

The linked-device service journals incoming AND synchronized own outgoing audio.
Ingestion, independent durable compute tasks and held/confirmed outbox parts are
separate. One failure does not block ingestion, and downtime backlog after the
explicit first activation cutoff is not expired after ten minutes. Initial history
is never bulk-posted. No general AI responder, read marking or composer action.

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

Marked UTF-8/rune-safe numbered transcripts reply-link to the source audio in the
original chat. Reserve/dispatch uncertainty is persisted before posting; unknown
sends never auto-retry. Server acceptance is not a recipient delivery/read receipt.
No live STT quality, media compatibility or message delivery is claimed from fixtures.

Former browser pipeline documentation is retained as
[historical evidence](history/whatsapp-browser/WHATSAPP-TRANSCRIPTION.md), not current setup.
