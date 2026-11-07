# WhatsApp original-language audio transcription

Canonical service/setup: [WHATSAPP-CONNECTOR.md](WHATSAPP-CONNECTOR.md).

**Explicit requested sends are a different feature, with a different gate.** This page is the
automatic pipeline: a voice note arrives, it is transcribed, and (only when `post_transcripts` and
`post_allow` say so) the transcript is posted. Nothing on this page changed on 06/11. A message the
model sends because someone asked it to (`whatsapp_send`, chat + text + optional quote and mentions)
travels the other way: it is a job on the shared queue `whatsapp.outbox`, the node's
`whatsapp.send` policy admits it per chat, and the component sends it
([SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md#component-services-on-wakernel02-wasi-03-native-async),
[GRANT-POLICY.md](GRANT-POLICY.md)). The two never share a gate: `post_allow`/holds govern the
transcript posts, and `whatsapp.send` governs requested sends - which is why widening requested sends
to any chat (the owner's decision) did not widen posting by one character.

Where the transcript goes besides the post: it is attached to the voice note's own record in the
message index (`index::attach_text(…, Source::Transcript)`), so the agent can find the note later by
what was said in it (`whatsapp_search`) instead of transcribing it again - see
[SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md#the-message-index-and-whatsappquery-0611). The attached
text is never logged, and a note the sender later revokes loses it with the rest of the record.

The linked-device service journals incoming AND synchronized own outgoing audio.
Ingestion, independent durable compute tasks and held/confirmed outbox parts are
separate. Incoming audio **and synchronized own outgoing audio** are posted when transcript
posting is enabled; both are transcribed for the journal and reply-linked. One failure
does not block ingestion. Audio not picked up within 5 minutes of being sent (for
example a downtime backlog) expires and is logged to the own chat instead of being
transcribed late (see "Fresh-only transcripts" below). Initial history is never bulk-posted. No
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

## Fresh-only transcripts and the own-chat log (2026-11-05)

A transcript is worth posting only while the conversation is live.

- **5-minute window** (`WA_WHATSAPP_FRESH_SECONDS`, default `300`). Pending audio
  is picked up only if it was sent within the window. A sweep every 15 s moves
  older pending audio to `expired` (`stale_over_5m`, prior reason kept in
  parentheses), even while both lanes are busy. Audio a lane is already decoding
  is never cut off: picked up in time means still fresh.
- **No old reposts.** Each outbox part records `created`; a `ready` part not
  dispatched within the window is never sent and becomes `expired`. Upgrading a
  journal expires every pre-existing `ready` part and stale pending audio once,
  silently (`stale_at_freshness_upgrade`).
- **Reply to the audio.** The transcript quotes the retained `AudioMessage` itself
  (stanza ID + participant + the voice note), so WhatsApp shows the audio bubble
  above the transcript and a tap jumps to the original to play it. A text
  placeholder is used only when no retained copy exists.
- **Own-chat log.** Every live audio that ends without a posted transcript queues
  one alert: `audio_expired`, `post_expired`, `post_held` (transcribed into a held
  chat), `failed`, `unsupported`, `blocked`. History audio stays silent. Alerts go
  as one plain-text message, at most once a minute (12 items listed, the rest
  counted), to this account's own chat (`WA_WHATSAPP_ALERT_CHAT` = an exact JID, or
  `off`). Each line has chat title, send time (America/Sao_Paulo), what happened and
  the reason; never audio or transcript text. Undeliverable alerts drop after 6 h.
- Schema: additive (`outbox.created`, table `alerts`); an older release ignores both.

## The wasm component path (B2, 2026-11-05)

The `wa-whatsapp` service component on openclaw (whatsapp-rust on `wa:kernel`) runs the same
pipeline in parallel with this connector, for the cutover (B3). Its rules are this document's:
5-minute freshness, no old reposts, reply quoting the audio, the same `🤖 _Copiloto_` parts, the
same own-chat log wording. Posting is gated by an allowlist (`post_allow`); while this connector is
the production poster the component may post only into the own chat (`"own"`), so a test never
reaches a real chat. Details and settings: [SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md)
("Speech and posting parity").

New there, not here: **post-then-edit streaming** (`stream_edits`, off by default). For a voice
note of at least 15 s, the first recognized segments go out as the reply within seconds
(`🤖 _Copiloto_ ⏳` … `…`), the same message is edited as more segments arrive (at most once per
5 s), and the final edit is the full text without the marker. Short notes get one post. The
recognizer worker accepts `"segments": true` per request to stream segment text; this connector
does not ask for it, so its progress lines stay timings-only.

The component has since ported the connector's remaining B3 prerequisites (see
[SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md)): the **unproven-mutation chat holds** of
`reliability.go`/`mutation_mapping.go` (a provable revoke fences only the IDs it names; an unproven
one fences its target everywhere and holds the chat for posting only; an untargeted or owner
mutation holds the whole chat; holds strengthen and are re-proved from the recorded author when
possible), the **express lane** for short notes (same 90 s rule as `audioLane`), a **durable
queue** through the component's kv (an item in flight at a restart is reported, never re-posted,
matching this connector's "an unknown send is never retried"), and **group subjects** in the
own-chat log instead of the sender's push name. One limit: the host runs a single warm recognizer,
so the express lane overlaps download and posting with a long decode, not the decode itself.

### Shadow run and comparison (p3a)

The component is ready to be run beside this connector, transcription on and posting off
(`config/whatsapp-shadow.json`), and then, for the post-then-edit test, with posting limited to the
own chat (`config/whatsapp-own-chat.json`). Both are documented examples: this tree deploys nothing
and connects to no account.

The recognizer is the node's one warm worker: the kernel starts it when the component starts, and it
is never stopped for idleness unless `WA_STT_IDLE_SECONDS` > 0 (default `0` = never), so the second
voice note does not pay the model load. Unit tests on the host fake the worker and count its loads.

For the comparison, the component writes metadata-only lines to its service log
(`wa-transcript v=1 kind=… chat=… id=… download_ms=… first_segment_ms=… total_ms=… chars=…
segments=…`); `scripts/compare-transcripts.mjs --log <component.log> --journal <journal.db>` joins
them with this connector's `journal.db` read-only and prints ids, states, counts and timings side by
side. It never reads a transcript's text out of the journal (`length(...)` only), and its own test
plants a canary transcript to prove that.

## The past: history sync and `whatsapp_backfill`

The index (`rust/components/wa-whatsapp/src/index.rs`) began as a record of what arrived while the
node was connected, so after the component swap `whatsapp_search` found only messages received since
start, while the account had months of history. The past does reach a linked device - WhatsApp
delivers it as `historySync` blobs on (re)link and answers an explicit per-chat request - so
`rust/components/wa-whatsapp/src/history.rs` indexes it into the *same* index:

```text
Event::HistorySync(LazyHistorySync)        one event per blob (chunked: several)
  -> HistorySyncStream::next_conversation  one chat at a time, bounded memory
  -> candidates(conversation)              envelope + message, as `on_message` builds them
  -> record::from_message + source=history the same parser, kinds and tokens as a live message
  -> index::put                            the same records, keys and query answers
```

* **The id is the dedupe, and the first writer keeps the row.** A message already indexed - live or
  backfilled - is counted as a duplicate and not rewritten, so a sync that re-delivers the last week
  never reorders a thread and never turns a live record into a history one. A backfilled record is
  otherwise indistinguishable: `read`, `search`, `reactions` and `media` answer with it, and a hit
  carries `source: "history"` so the two can be told apart.
* **Bounded, and it says which bound it hit.** One blob can carry tens of thousands of messages, so a
  drain stops at the first budget - per chat, in total, or per notification - and logs the counts
  (`history: conversations=… seen=… written=… duplicate=… skipped=… over_budget=… remaining=…
  stopped=per_chat|total|per_sync|store`). Never a message, never a chat's text.
* **The storage grant is the wall, not a promise.** A failed write stops the drain with `stopped=store`
  and its reason instead of retrying into the same wall; what was written stays.
* **The counters are read, not maintained.** `index::age_index` walks the age keys once (`ix/all`, whose
  value now says `history` or nothing) to learn how much backfill the index holds, so a budget cannot
  drift away from what is on disk.

**Configuration** (the service definition's `config`, all optional):

| key | default | meaning |
| --- | --- | --- |
| `index_history` | `true` | index history syncs at all; `false` drops a blob and says so once |
| `index_history_per_chat` | `200` | most backfilled records one chat may hold |
| `index_history_total` | `2000` | most backfilled records the index may hold |
| `index_history_per_sync` | `1000` | most records one notification may add (the rest is a later sync) |

**The on-demand request.** `whatsapp_backfill {chat?, count}` is a sixth op on `whatsapp.query`
(`rust/wa-whatsapp-index`): the component anchors on the oldest message it holds for the chat
(`oldest_msg_id`/`oldest_msg_from_me`/`oldest_msg_timestamp_ms`), calls the library's
`fetch_message_history`, and settles an answer that is the *request list* (chat, anchor, count) -
never a message, because the phone answers through the protocol and the sync above does the indexing.
With no `chat` it asks for the chats the index already knows, most recently active first, at most
`wa_whatsapp_index::BACKFILL_MAX_CHATS` (20) of them; `count` is clamped to `BACKFILL_MAX` (500) and
travels in the request's `limit` field (the request's one count), which the dedupe key covers, so
asking for 120 messages is a different job from asking for 50. A
component that is not connected answers `not_connected` (the queue retries); a phone that refuses is
counted and named in the answer's `note`.

**What it never does.** It does not read the Go connector's `journal.db` (another process, another
owner: history comes only through the WhatsApp protocol), it does not post history - the
transcription pipeline's 5-minute freshness rule already refuses anything old, and this lane only
indexes - and it logs no text.

**Tests.** `src/history/tests.rs` (11 tests, native, no account): a compressed blob driven through
`LazyHistorySync::stream()` into records a `whatsapp_search` then finds; the dedupe against a live
message (the live row keeps its own source); the total, per-chat and per-sync budgets; an off budget;
a failed write stopping the drain with its reason; the anchor an on-demand request names, including a
chat the index has never seen; and the attribution of a group/DM/own message.

## Remote workers: the strong node decodes for the small one (queue phase 2)

The 2-core node that owns the journal does not have to be the node that decodes. A node whose config
carries the `stt_worker` role long-polls the producing node's `stt.requests` queue through the relay,
downloads the audio, decodes it with its own warm `faster-whisper`, and streams the segments back as
progress. The producing node's own worker is the fallback, so nothing depends on the strong node
being there.

What is built. The library (`rust/wa-stt-remote`, `cargo test -p wa-stt-remote`) has the request
payload, the signed worker envelope and its admission rules, the preference policy and both worker
loops, with a two-node simulation that proves remote-wins, remote-dies-mid-job -> local finishes and
stale-never-decoded. The node half (`rust/wa-kernel-runtime/src/stt_node.rs`) puts it on a real node,
and `scripts/test-stt-two-nodes.sh` proves it with three real processes on loopback: a local
rendezvous, the producing node and an `stt_worker` node, with a fake recognizer that logs a digest per
decode. A note is decoded by the other node, a note past its window is refused at enqueue and never
decoded by either, and a worker killed mid-decode leaves its lease to lapse so the producer's own
worker finishes the same note (`lease_expiries` on the record, at-least-once).

The role is configuration, not a new trust path: `WASM_AGENT_STT_ROLE` (`producer` by default,
`worker`/`stt_worker`, `both`, `off`), the producer's selector in `WASM_AGENT_STT_PRODUCER`, and the
lease/heartbeat/grace/freshness knobs in `WASM_AGENT_STT_*_MS`. `lua/core/stt.lua` hands them to the
node on boot, and the node's housekeeping loop pumps the worker's signed calls. The environment is no
longer the only way to set the role: it is also a stored node setting that a running node adopts on
its next tick ("Changing the role live", below). The operator view is
the `services` tool's action `stt`: role, attached workers, their recent latency, the local vs remote
decode counts and the last settled jobs - ids and durations, never text. `docs/QUEUE.md` ("The node
half") has the full table and what is still open: the component enqueues with the real chat/message
ids and send time only once the speech interface carries them, so the kernel path dates a job at
submission.

Rules that do not change on the remote path — and where they are enforced:

- **Freshness.** The window still starts when the note was *sent* (`WA_WHATSAPP_FRESH_SECONDS`).
  `take` on the producing node drops a stale job; a worker checks the same bound before the decode
  and again before it settles, so a job that goes stale during a slow download is dropped instead of
  posted late. A result that arrives after the window is never sent.
- **First lease wins.** One queue, one lease key on the producing node. A remote that takes the job
  first owns it; the local worker's "hold back for the remote" is only a decision not to take, so
  two decodes of one note cannot happen.
- **A vanished node costs a lease, not a note.** A remote that dies mid-job never settles; its lease
  lapses and the local worker takes the job (`lease_expiries` on the record, counted as a recovery,
  not as a failed attempt). At-least-once: a transcript whose `done` was lost is produced again.
- **Preference is measured.** Remote first when it is online and its recent decode is faster than
  this node's; otherwise — or after a 3 s grace with no remote take — the local worker does it. No
  fixed "the strong node always wins", and no waiting on a node that is not attached.
- **Privacy.** The audio crosses only between the owner's own nodes: the producing node refuses a
  call from any node not in the owner's node list, and the signature, timestamp and request id are
  checked before the queue is touched. The payload carries a short-lived fetch handle rather than a
  blob above 256 KiB, only the worker currently holding the lease is served the bytes, and the audio
  is deleted when the job settles (with a sweeper for what nobody settled). Logs carry ids and
  timings — the same rule as the `wa-transcript` line: never the audio, never the text.

Knobs: `fallback_after_ms` (default 3000) and the latency estimate's lifetime (default 10 min) are
`policy::Preference`; the freshness window, attempts (6) and the 256 KiB inline bound are
`producer::SttPolicy`. A remote that has never decoded anything gets one chance inside the grace,
which is the named risk of the default: a cold strong node is preferred for up to 3 s on the first
note before the local worker takes it.

### Changing the role live (no restart)

The role used to be environment-only, so changing it on a node meant restarting the node - on the
box that owns the journal, the riskiest thing an operator can do to fix a small problem. The role is
now a **stored setting** the running node reads again on every housekeeping tick (once a second).

```
wa stt status                                     what this node is doing now, and which layer said so
wa stt role worker --producer openclaw            become the worker node's worker, from now on
wa stt role producer | both | off [--producer <node>]
wa call <node> services '{"action":"stt","set_role":"worker","producer":"openclaw"}'
```

Precedence, highest first: `WASM_AGENT_STT_ROLE` (the environment is the operator's emergency and
test override and always wins) > the stored setting (`stt.role` / `stt.producer` in the ledger's
`meta` table, written by the two commands above) > the legacy `~/.wasm-agent/node.stt` file (first
line role, second line producer) > `producer`. `wa stt status` prints `role`, `role_source`
(`env`/`setting`/`file`/`default`), `producer_selector`, `producer_source` and the stored `setting`,
so "I set worker, why is it still producing?" is answered by one field instead of a restart. An
unreadable word is skipped rather than obeyed: a typo can never turn a node `off`.

What "live" means, exactly:

- **Becoming a worker** starts long-polling the producer on the next tick (the node's worker thread
  is already there; the role is what it checks before each take).
- **Becoming `producer`/`off`** stops *polling*: no new take is issued. A job the thread had already
  taken is finished and settled, because a settle nobody answers is a lease that lapses and a note
  the producer's own worker decodes a second time. The Lua pump therefore keeps answering the
  worker thread's calls after the switch - that is the "no lost lease" part, and it is why a switch
  is safe mid-decode.
- **The stored setting is the only thing that survives a restart**; the environment is not read
  again for a different answer. `wa stt role` from a shell writes the setting and does *not* start
  the speech threads in that short-lived process - the serving node applies it on its next tick,
  which is what keeps a one-shot command from taking a job it would die holding.
- **Who may change it.** Locally: the operator. Remotely: the `services` tool's action `stt` with
  `set_role`, which `lua/core/services.lua` admits only for a caller this node treats as its
  master/admin (`verify_peer` refuses everyone else with `forbidden_role`). Every applied change is
  written to the node's audit trail (`access_events`, `wa access log`) as `stt.set_role` with the
  caller and the role; a refused call writes nothing. Nothing in that row is message text.

The test that proves it is `scripts/test-stt-live-role.sh`: three real nodes on loopback (producer,
worker, and a third one that is a rendezvous admin but not in the producer's
`WASM_AGENT_TRUSTED_MASTERS`), the worker switched off/on three times - alternately with `wa stt
role` and with a master's remote `wa call` - with a note decoded in each half, plus one switch in the
middle of a long decode. Every note is decoded exactly once (the fake recognizer logs a digest per
decode), every job settles `done` with `lease_expiries = 0`, the queue ends
`done=9 dead=0 expired=0 ready=0`, the environment still outranks the setting, and the non-admin
caller is refused with no audit row.

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
