# WhatsApp original-language audio transcription

Canonical service/setup: [WHATSAPP-CONNECTOR.md](WHATSAPP-CONNECTOR.md).

The linked-device service journals incoming AND synchronized own outgoing audio.
Ingestion, independent durable compute tasks and held/confirmed outbox parts are
separate. Incoming audio **and synchronized own outgoing audio** are posted when transcript
posting is enabled; both are transcribed for the journal and reply-linked. One failure
does not block ingestion, and downtime backlog after the explicit first activation
cutoff is not expired after ten minutes. Initial history is never bulk-posted. No
general AI responder, read marking or composer action.

A persistent private local `faster-whisper` worker loads multilingual `small`,
CPU/int8, greedy (beam 1)/VAD once, at service start. Model cache provisioning is separate; message processing
is offline/local-files-only with NO hosted fallback. Missing cache/media, unsupported
view-once/ephemeral/large audio and no-speech remain visible.

A hold on a whole chat (`chat_holds`: an unproven mutation or an owner clear) gates
**posting, not the local derive**. Audio arriving in a held chat is transcribed and
retained with state `transcribed` and reason `source_hold_transcription_only`; the
outbox is not written, `Ready`/`Send`/admission still refuse, and releasing the hold
neither rewrites the retained transcript nor replays a posting for it. A chat hold
used to leave the audio in `blocked_source` forever, so one unproven mutation made
every later voice note in that chat unreadable. A **proven per-message fence** is
different and stays absolute: `source_blocks` (a revoke/edit/delete the SDK names for
that exact ID) stops the audio before transcription, and it is never replayed.

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

## Receive → transcript path (2026-10-27)

Goal: an audio never ends failed because it is long or the host is slow, and a
voice note is picked up the moment it is journaled.

- **Event-driven pickup.** `ingest` wakes the audio lanes right after the pending
  task commits; each lane drains its queue before sleeping. The 10 s tick is only a
  safety net (backoff expiry, reconnect). A finished transcript wakes the poster too.
  The previous connector polled every second, one task per tick.
- **Queue order.** Never-failed tasks first. Among them, audio sent in the last 15
  minutes runs oldest-first (conversation order), then older backlog newest-first, so
  a requeued or downtime backlog never delays a live voice note. Tasks that genuinely
  failed run last, after their backoff.
- **Two lanes, justified for 2 cores.** The main lane takes anything. An express lane
  (second warm worker) runs ONLY while the main lane decodes audio declared longer
  than 90 s (or of unknown length), and only takes audio declared ≤ 90 s. The two
  decodes then share the CPU: the long one slows while they overlap, the short one
  lands in seconds instead of waiting minutes. Cost: one more model in RAM (~0.6 GB
  RSS for `small` int8). `WA_WHATSAPP_STT_LANES=1` turns it off.
- **Progress watchdog, not a wall clock.** The worker prints a progress line after
  decode/VAD and after every segment (timings only, never text). Go kills the
  worker only if no line arrives for `WA_WHATSAPP_STT_STALL_SECONDS` (default 180),
  or past a budget of 300 s + 6 × audio seconds (sender-declared, replaced by the
  decoded duration once reported). A slow but advancing decode is never cut off;
  a warm worker is never killed for being slow.
- **Retries and fallbacks.** Failures are classified. *Permanent* (no speech, too
  large) is visible `unsupported` at once. *Environment* (missing cache/interpreter,
  media download) retries with backoff 1 min doubling to a 10 min cap and never
  becomes terminal: it is fixed outside the audio. *Decode* failures (stall, budget,
  worker crash/protocol) count in `audio.failures`, back off 30 s doubling to a 1 h
  cap, and walk decode tiers: 2 tries at the configured decode, 2 greedy with no
  temperature re-decode, 2 greedy without timestamps (and `WA_WHATSAPP_STT_FALLBACK_MODEL`,
  if set and provisioned). Only when all six fail does the task become
  `failed` / `stt_exhausted_<reason>`. Shutdown cancellation costs nothing.

### Speed knobs (set in the service environment, e.g. a systemd drop-in)

| Variable | Default | Meaning |
| --- | --- | --- |
| `WA_WHATSAPP_STT_MODEL` | `small` | model in the private cache |
| `WA_WHATSAPP_STT_BEAM` | `1` | tier-0 beam size (1 = greedy; `5` restores the old decode) |
| `WA_WHATSAPP_STT_THREADS` | usable CPU count | CTranslate2 threads (its own default is 4, which oversubscribes a 2-core host) |
| `WA_WHATSAPP_STT_FALLBACK_MODEL` | none | cheaper model for the last tier; must already be in the cache |
| `WA_WHATSAPP_STT_STALL_SECONDS` | `180` | no-progress window before the worker is killed |
| `WA_WHATSAPP_STT_LANES` | `2` | `1` disables the express lane |

Risk named: greedy decoding can cost some accuracy versus beam 5 on hard audio; it
is a knob, and the measurement behind the default is in the commit/report, not a
quality claim. `without_timestamps` and the batched pipeline are not defaults: they
are unmeasured on the production host.

## Unproven revokes no longer hold a whole chat's transcription

A revoke whose chat scope or author cannot be proven used to insert a chat hold that
blocked every later audio in that chat from transcription forever (38 chats, 553
tasks on the production journal, 2026-10-27). The most common cause was a DM
journaled under its `@lid` while the revoke key carried the phone-number JID.

- **Alias proof.** When the envelope carries no PN/LID alternate, the mapper asks the
  SDK device store's LID map (both directions must agree) for that exact user.
  A match proves the scope (`scope_proof=sdk_lid_store`) and fills the author alias,
  so the revoke becomes an exact source fence. Groups never use the DM map.
- **Policy.** An unproven mutation that still names an exact target ID now
  (1) fences THAT ID in every chat of the account (`target_fences`; a revoked audio
  that arrives later, under either alias, is never transcribed), and (2) holds the
  chat for **posting only** (`chat_holds.reason=unproven_mutation_chat_hold`). Other
  audio in that chat is transcribed into the private journal with
  `reason=posting_held_chat` and NO outbox row, so nothing is posted into a held
  chat and a later `release-hold` replays nothing. Posting, operator replies and
  final dispatch admission still honour every hold and every fence.
- Unchanged: an unproven mutation with no target ID (`untargeted_mutation_chat_hold`),
  owner ClearChat/DeleteChat (`owner_chat_clear_hold`) and exact verified fences still
  block transcription. A broader mutation upgrades a posting-only hold; nothing
  weakens one.

### Re-proving a posting hold from the journal (operator, offline, 29/10)

On openclaw a DM journaled under its `@lid` had carried a posting-only hold since
21/10 (one revoke, `remote_mismatch`): every voice note from that contact was
transcribed (`source_hold_transcription_only`) and never posted. The 27/10
`sdk_lid_store` proof only helps mutations that arrive after it is deployed.

`reprove-holds` re-checks each `unproven_mutation_chat_hold` against the journal.
A hold is replaced by exact source fences (`verified_source_<kind>_journal_reproof`)
only when it has recorded evidence (`hold_origins`) and EVERY `chat_hold` mutation
recorded for that chat is a revoke/edit naming a message journaled in that same chat
by the same author (the `mutationProof` author rules, alias and ambiguity included).
Legacy holds without evidence, untargeted or owner mutations, a target never seen in
the chat, a mismatched or ambiguous author, and compute holds stay. The revoked
message stays fenced; nothing is replayed (already-held transcripts remain unposted);
only later audio in the chat is posted. Dry run unless `--apply`, counts only, event
`hold_reproved`, idempotent. Service stopped (owner lock):

```sh
"$WA" reprove-holds --state "$STATE"           # dry run
"$WA" reprove-holds --state "$STATE" --apply
```

### Re-queueing audio blocked only by a chat hold (operator, offline)

Existing `blocked_source` rows are NOT reopened automatically. With the service
stopped (the owner lock refuses a running service):

```sh
WA="$RELEASE/wa-whatsapp"; STATE="$HOME/.local/state/wa-whatsapp"
"$WA" requeue-held-audio --state "$STATE"                 # dry run: counts only
"$WA" requeue-held-audio --state "$STATE" --limit 50 --apply   # 50 newest
"$WA" requeue-held-audio --state "$STATE" --apply         # all eligible
```

It moves a row only if its chat's hold is posting-only and the row's own ID is not a
source block, target fence or ANY recorded mutation target; it skips chats with an
untargeted recorded mutation. Rows are taken newest first and get state by the
normal rules: `pending` (attempts/failures reset), `journal_only` before the
activation cutoff, or `unsupported` for their recorded reason. Holds are not
released, no outbox row is created, an event `held_audio_requeued` records the
counts, and a second run finds nothing (idempotent). Output is counts only.

Legacy holds (created before `hold_origins`, no recorded target): audio that was
already in the chat when the hold landed may BE the revoked message and is never
requeued (`skipped_possible_target_legacy_hold`). Audio that arrived after such a
hold is requeued only with `--include-legacy-holds`, an explicit operator decision
(the small residual risk: a revoke delivered before its own original, out of order).
New audio arriving in a legacy-held chat after this version is transcribed (not
posted) without that flag, because a revoke targets an earlier message.
