# whatsapp-transcription-works: voice notes, the copilot reply, the index, and the per-node module

Branch `change/whatsapp-transcription-works`, base `42f49385`. Every measurement is from 2026-11-23
(UTC) unless it says otherwise. Live nodes were read only: `services status`, `wa stt status`,
journals, the component's own logs and the node's audit trail. No write, no restart, no install, no
config change happened on any live node; the three things that need one are listed in
"Needs the orchestrator's OK" and are deliberately NOT done.

## 0. The four answers the orchestrator asked for first

| question | answer |
| --- | --- |
| Which node is the WhatsApp producer? | **`openclaw`** (OCI Ampere A1 Flex, 2 OCPU, 12 GB, arm64). `wa-whatsapp` runs there as `wa-whatsapp#1`, `started_at` 1795424981 = `2026-11-23T09:09:41Z`, `restarts 0`, `health: ready`. Read from the node's own answer (`wa call openclaw services '{"action":"status","name":"wa-whatsapp"}'`), not from the CLI. |
| When did transcription last work? | **`2026-11-23T12:04:19Z`** - and it still works. Two notes were decoded that minute (`job 45` 12:04:10, `job 46` 12:04:19, 12 510 ms and 7 367 ms) and both transcripts are in the index and answer a search: `whatsapp_search {kind: voice}` at 12:23Z returned them with their text (Fernanda, 22 s and 10 s notes). |
| When did the copilot reply last work? | **Not once in the retained logs.** Every component start since `2026-11-21T13:52Z` (the oldest component log on the node) printed `transcription: language pt, posting off (allow [])`, and the 2 896 retained lines contain **zero** `kind=posted` lines. The `🤖 _Copiloto_` reply has not been posted for at least two days, and nothing in the tree can currently turn it on (below). |
| Is the auto indexer behind? | **No.** `index: 1/1 records written` runs to the last message received (12:23Z) and the index answers back to `2026-11-01T13:10:35Z`. No `history:` line appears in the retained log (no history-sync blob was processed in that window; the past it holds came from earlier syncs). Its defect was on the **query** side, not the writer: transcripts were cut at 280 characters with nothing saying so. |

## 1. PART 1 - what is broken, stage by stage

The pipeline is: note received -> audio downloaded -> enqueued -> leased -> decoded -> text sent back.
Measured for a note received at 12:03:57Z (job 45):

| stage | state today | evidence |
| --- | --- | --- |
| note received | works | `message chat=sha256:... kind=` + `index: 1/1 records written` on every arrival |
| audio downloaded | works | `download_ms=240` / `170` on the two notes of 12:04 |
| enqueued | works | `lane Main takes id=...`, `stt.requests` queue: `done 45`, `ready 0`, `expired 0` |
| leased | works | `[stt] local: done job=45 by=local took_ms=12510` |
| decoded | works | `transcript ready ... ms=12510 chars=371`, `recognize_ms=12577` |
| **text sent back** | **does not happen** | `posting off (allow [])`, `kind=shadow reason=shadow`, zero `kind=posted` |

The break is the last step only. There are two independent reasons it cannot post, and both are
confirmed by the artifact rather than inferred.

### (a)+(b) `posting off`: the reply is never sent, and the toggle talks to a removed service

* The gate is `post_transcripts` + `post_allow` (`rust/components/wa-whatsapp/src/posting.rs:42-43`),
  read from the component's config JSON. The stored definition
  (`~/.wasm-agent/components/wa-whatsapp.json`) has **no `config` key at all**, so the component starts
  with `{}`: `post_transcripts` unset = off, `post_allow` empty, `alerts` off, `language` "pt" (the
  hardcoded default, which is why the language looks correct and posting does not).
* The operator door in the tree for this exact switch is `wa_whatsapp_posting`
  (`lua/core/server.lua:545`). It reads `WA_WHATSAPP_POSTING_URL`, `WA_WHATSAPP_ACCOUNT`,
  `WA_WHATSAPP_GENERATION` and two token files, and POSTs to `<base>/operator/posting` - the **Go
  connector's HTTP API**, the one removed in Phase 4 on 11/11 (`docs/WHATSAPP-TRANSCRIPTION.md`,
  first paragraph). With those env vars unset it answers `whatsapp_posting_not_configured`, so the
  only switch the operator had no longer has a target. The component's own switch is a config key
  with no CLI verb anywhere in the tree.
* That is why Victor used to get `🤖 _Copiloto_` and does not now: the poster was the connector, the
  connector is gone, and the port that replaced it was never given a way to be switched on. Nothing
  in the suite could catch it: every Rust test constructs `post_transcripts: true` itself
  (`posting.rs` tests) and the end-to-end rows run a fake recognizer with posting off by design, so
  the product default (off) was never a failing state - it is the *configuration* that is absent, and
  no test asserts that a deployed component can be configured.

### (b'), second reason, on the same path: `queue` and `holds` were refused by the node's policy

* The node's audit (`~/.wasm-agent/audit/grant-policy.jsonl`) holds **62** `kv.write ->
  deny(target_not_allowed)` refusals for `wa-whatsapp` between `2026-11-21T15:58:30Z` and
  `2026-11-23T12:10:49Z` - exactly when a transcript settles.
* The audit records the target as a digest, so the key could not be read off the image. It can be
  computed: `sha256("queue")[:32] = 00b109cf1123a591253cc534b17e5268` and
  `sha256("holds")[:32] = 3b97260d76d3d7dfa0c66ca08ec5ac15`, the two targets in every refusal.
  `queue` is the durable outbox part and `holds` the chat holds, both written by `kkv::set` in
  `rust/components/wa-whatsapp/src/guest.rs:677` and `:680`.
* `policies/default.json` allowed every other prefix the component writes (`dev`, `id/*`, ... `ix/*`)
  and neither of these two, so a reserved post never survived and a held chat was never remembered -,
  and the audit could not name the key that was refused. Fixed in **6af69e4a**.

### (c) the auto indexer

It is not stopped. `index: 1/1 records written, retried 0, lost 0` runs on every arrival up to
12:23Z; the index answers a windowed search for `2026-11-01` (a voice note at 13:10:35Z), so it is
not behind either. Two things made it *look* broken:

1. The query side cut transcripts at 280 characters **silently** (`seam::MAX_TEXT_CHARS`,
   `src/index.rs:2927`), so the text an agent got back ended mid-word.
2. `whatsapp_media` carried no transcript at all, so the way to see the rest was to transcribe the
audio again - on openclaw, which had already transcribed it. Fixed in **4012380f**.

That defect has a measurable trigger: at 12:23Z `whatsapp_search {kind: voice}` returned a
371-character transcript as a 280-character string ending `"... o proced"`, with `text_truncated:
false` (that flag is about the body), no `transcript_truncated`, no length, and no pointer.

### (d) the tool results a model reads

Landed in **4012380f**, one shape in `crate::view::message` so a hit and a read cannot drift:

* `transcript` / `ocr` keep the snippet, and now carry `transcript_truncated: true`,
  `transcript_chars`, and `transcript_full: {tool: "whatsapp_message", chat, id, field, chars}` when
  the index holds more.
* `whatsapp_message` and `whatsapp_media` answer with the **whole** stored transcript (and OCR text)
  plus its length, so nothing is transcribed twice to read what was said.

### (e) download: node and path - NOT DONE

Not built, deliberately: the brief says to use the bounded peer transfer that
`run-block-images-reach-model` item 3 builds and not to build a second transport. What is measured
here: `whatsapp_media` already answers `"node": "openclaw"` / `"served_by": "openclaw"` with the
file's metadata, so the *node* half is there for media; `whatsapp_download` was **not** run against
the live node (it writes a decrypted file on it, which is a live-node write), so its path answer is
unverified and the 13-call base64 claim from the forwarded note is neither confirmed nor refuted.

## 2. What landed

| commit | what | why it fails on the code before it |
| --- | --- | --- |
| `6af69e4a` | `policies/default.json` allows `queue` and `holds`; `wa-grant-policy` holds the shipped policy against the component's 16 write sites; that crate now runs in `scripts/fast.sh` and `scripts/test.sh` (it ran in **no row at all** before) | the new test asserts `kv.write` is allowed for `queue`/`holds`; on the base policy it answers `Deny(TargetNotAllowed)` (verified by running it against `git show HEAD:policies/default.json`) |
| `4012380f` | a cut transcript says so, names `whatsapp_message`, and `whatsapp_message`/`whatsapp_media` return the whole stored text | `index::tests::a_cut_transcript_says_so_and_the_two_exact_ops_return_it_whole` fails on the base source (`transcript_truncated` missing, media without a transcript) - verified by reverting the two source files and re-running it |
| `772261ba` | one health line, at start and every `health_every_seconds` (default 300): last transcription, last post, last index pass, last refusal reason, and the posting mode | four unit tests on the renderer and the counters; the wasm32-wasip2 build compiles |
| `ee5e5899` | `scripts/measure-transcription.mjs`, the Part 2 harness | run by hand: a tone clip through `superwhisper` scored WER 1.0 ("No speech detected") and a fixture engine 0.0 |

Where the new tests are wired: `cargo test -p wa-grant-policy` (new row in `scripts/test.sh`, new crate
in `scripts/fast.sh`'s crate loop) and `cargo test` in `rust/components/wa-whatsapp` (its own
workspace; its rows already build that directory).
`scripts/test-install-default-policy.sh` was run because `policies/default.json` changed: 23 checks
passed.

## 3. What is still silent, and needs the orchestrator's OK

None of these is a code change; each is a decision about the live node's configuration, which this
brief put behind an approval.

1. **Turn posting on for the component** - this is what makes Victor's test pass ("send a voice note,
the text comes back"). There is no supported verb today; the supported path is a definition change
   (`services` tool `action:"put"` with a `config` block, which requires `disable` first, then
   `enable`), i.e. writing:
   `{"post_transcripts": true, "post_allow": ["<the chat JIDs the owner allows>"], "alerts": true, "language": "pt"}`.
   Until that is done, transcription is correct and invisible.
2. **Port the posting toggle** so the next operator does not have to hand-edit a definition:
   `lua/core/server.lua:545` still points at the removed Go connector. Proposed, not written (it
   touches an operator endpoint and a security-adjacent path: Fable reviews).
3. **Own-chat alerts for a note that cannot be transcribed.** The path exists
   (`rust/components/wa-whatsapp/src/alerts.rs` + `WA_WHATSAPP_ALERT_CHAT`) and is **off** in this
   definition (`alerts off`), so a note that fails is still silent in the chat. Requirement 3 of the
   brief is met only when `alerts` is on - same config change as item 1.

## 4. Texts to approve

1. The health line, verbatim (operator-facing log; no chat, no id, no text):
   `health: v=1 transcripts ok=<n> last=<RFC3339|-> chars=<n> failed=<n> last_failure=<RFC3339|-> reason=<code|-> posting=<on|off> posted=<n> last_post=<RFC3339|-> index written=<n> last=<RFC3339|->`
2. The new component config key and its default: `health_every_seconds` (300, clamped 30..86400).
3. The policy note sentence added to `policies/default.json`'s `wa-whatsapp` note (quoted in the diff
   of `6af69e4a`): it names `queue`/`holds`, the two audit digests and the date, and points at the new
   test.
4. Model-facing tool fields added by `4012380f`: `transcript_truncated`, `transcript_chars`,
   `transcript_full{tool,chat,id,field,chars}`, `ocr_truncated`, `ocr_chars`, `ocr_full{…}`, and
   `transcript`/`transcript_chars` on `whatsapp_media` and `whatsapp_message`.

## 5. Proposals (never written)

**FACTORY.md** - under the wave's rules:

> A component's own configuration is part of its contract. If a feature is gated by a config key,
> that key has a supported operator verb, and the definition the node stores is asserted by a test.
> 23/11: `wa-whatsapp` shipped with `post_transcripts`/`post_allow`/`alerts` readable only from a
> config block no tool in the tree could write, while the operator switch for the same feature still
> posted to a service removed twelve days earlier. Transcription worked and nothing was delivered, and
> no row could see it.

> A key a component writes but the node's policy does not allow is a bug in one of the two, and the
> audit must name the key. 23/11: 62 `kv.write -> deny(target_not_allowed)` in two days recorded only
> `sha256:...`, so "which key" was a digest nobody could invert without the source at hand.

**HANDOVER.md** - for the next session:

> WhatsApp runs on `openclaw` and it is the only node with a recognizer (`faster-whisper small`,
> int8, CPU, ~30 s of decoding per minute of audio). `avell`, `work`, `nextcloud` and `mail` have no
> recognizer and say `recognizer=false`. Transcription works; posting is off by config and there is no
> supported verb to turn it on (`lua/core/server.lua:545` talks to the connector removed on 11/11).
> Read a component's live state through its node (`wa call <node> services '{"action":"status",
> "name":"..."}'`), never from `wa services list` in a shell: that process reads its own empty host
> and answers `not_running` for a running service (`lua/core/services_cli.lua:151` says so in a
> comment). The component's health line now dates the last transcription, post and index pass.

## 6. What I did not do, and what I could not verify

* **No write, restart, install or config change on a live node** (the brief's rule): posting is still
  off, alerts are still off, the copied policy on `openclaw` is whatever its last deploy installed.
* **WER was not measured** for any engine (no TTS on this node, no whisper.cpp/faster-whisper venv
  here, no scratch arm64/VPS node in this session). `docs/TRANSCRIPTION.md` says so on the page.
* **`whatsapp_download` was not run** against the live node (it writes there). Item (e) is unbuilt and
  unverified, by instruction.
* **The `wa services list` defect is reported, not fixed**: the operator CLI cannot see the serving
  node's state. It is a real bug (`not_running` for a running component) and it is what made the first
  read of this mission look like a dead service. Fixing it means giving the CLI a way to ask the
  serving node; it is not in this diff.
* The quoted `400`/`429`-class claims in the forwarded model note (13 base64 calls for one 120 KB
  image) are neither confirmed nor refuted here.
