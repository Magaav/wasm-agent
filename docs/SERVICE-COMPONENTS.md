# Service components — long-lived plugins (design, after the 05/11 spike)

[COMPONENTS.md](COMPONENTS.md) covers **request** components: one run per MCP call. A channel like
WhatsApp is different: it holds a session for days, receives events, runs timers and queues, and
keeps state. This is the host class for that, on the same manifest/grant model. Evidence for every
"feasible" below: [benchmarks/service-component-spike](../benchmarks/service-component-spike/README.md).

## Goal

The WhatsApp connector (and later Telegram, mail…) installed as one pinned `.wasm` + manifest on any
node, started and supervised by the host, never rebuilt with the core, with exactly the capabilities
its manifest declares and the node grants.

## What runs where

| piece | where | why |
| --- | --- | --- |
| protocol, journal logic, holds/fences, outbox, freshness, alerts | **guest** (Rust → wasip1, `rust/components/wa-whatsapp`) | protocol = the `whatsapp-rust` crate (MIT; its core compiles to wasip1/wasip2 with defaults off, runtime/transport/HTTP/store injected); our logic rewritten lean on top |
| TLS + websocket | **host** (`wa_ws`, rustls/ring already in the tree) | the guest speaks frames; the WhatsApp Noise session inside them stays end-to-end in the guest |
| media HTTP | **host** (`wa_http`), `net` grant | 4xx/5xx returned as statuses (whatsapp-rust's HttpClient contract) |
| store (device keys, sessions, journal) | **host**, `storage` grant | whatsapp-rust `Backend` over host storage in the component's own state dir (milestone 1 uses its in-memory backend) |
| speech-to-text, OCR | **host**, `stt` / `ocr` capability | native faster-whisper/RapidOCR; wasm `small` measured ~17x slower (benchmarks/whisper-wasm). A node without them answers `unavailable` and the guest records it, as today |
| HTTP API for MCP/operator | host-routed | the guest serves its loopback API through a host listener grant, or the MCP component calls the guest directly through the host (no TCP hop) |
| supervision, restart, logs | **host** | the sentinel model: start at boot, restart on trap with backoff, stop on uninstall |

## Capabilities (manifest declares, node grants)

Existing: `env`, `file_env`, `net`, `config`. New for services:

| capability | grant | guest sees |
| --- | --- | --- |
| `net` (dial) | `["web.whatsapp.com:443", "*.whatsapp.net:443"]` | `wa_sock.connect/read/write/close`; a wildcard is a declared suffix, resolved and checked per connect |
| `storage` | `{"name": "journal", "quota_mb": 512}` | `wa_sql.open(name)` → a SQLite file under `<components>/<name>.state/`, nowhere else |
| `listen` | `["127.0.0.1:28787"]` | an accepted-connection handle per client (the operator/MCP API) |
| `stt` / `ocr` | `true` | `wa_media.transcribe(bytes, language) → text` with the host's bounded worker |

## Runtime shape

- One long-lived instance per service, in its own thread; epoch interruption for fairness, memory cap
  from the manifest (`limits.memory_mb`).
- Guest entry: `_start` runs forever; host stop = epoch trap after a graceful `wa_ctl.stop` flag the
  guest polls.
- Every import is non-blocking (EAGAIN + guest yield): a blocking host call freezes the Go runtime.
- Go `wasip1` is single-threaded: CPU-heavy work stays on host capabilities (STT/OCR).

## Built so far (step 1, 05/11)

- **Host runner** `rust/wa-host/src/services.rs`, capability `host.service` (start / stop / status / logs):
  wasip1 core modules on their own thread, `wa_sock` (exact or `*.suffix:port` allowlist, 64 sockets,
  non-blocking), `wa_ctl.stopping`, 5 s grace then epoch trap, restart with backoff 1 s doubling to
  60 s (reset after 10 min healthy), memory from `limits.memory_mb` (default 512), stdout/stderr to
  `<components>/<name>.service.log` (rotated at 8 MiB per start). Start is idempotent per pin.
- **Registry + tool** `lua/core/services.lua`, admin tool `services`: `put` (stored disabled),
  `enable` (start now and at boot), `disable`, `restart`, `remove`, `status`, `logs`; master only, never
  a child agent; definitions change only while disabled. Enabled services start when `wa serve` loads.
- **Manifest** `"kind": "service"`, `"target": "wasm32-wasip1"` (what `build-components.sh` builds).
- **Proof** fixture `rust/components/svc-echo`: Rust test (real local echo server: granted dial, refused
  dial `-13`, clean stop, crash restart `exit_3`, undeclared grant refused) and
  `scripts/test-service-component.lua` (23 checks, registry lifecycle). Both in `scripts/test.sh`.

Example (a definition the `services` tool stores, then `enable`):

```json
{"name":"wa-connector","net":["web.whatsapp.com:443","*.whatsapp.net:443"],
 "file_env":{"WA_STATE_KEY":"/home/ubuntu/.local/state/wa-whatsapp/api.token"},"config":{"language":"pt"}}
```

## Component services on wa:kernel (05/11)

`rust/wa-host/src/service_components.rs` runs services built as **components** on the
`wa:kernel` WIT contract (`wit/kernel`, `service-component` world: websocket, http, kv, lifecycle,
log, credentials in; `service.run(config)` out). `wa:kernel@0.2` (native async) is served next to it
by `service_components_v2.rs`; the supervisor picks the runner from the binary's preamble
(component vs core module) and, for a component, from its own imports. Wasip1 modules keep working.
`wa-whatsapp` is a `wasm32-wasip2` library component (wit-bindgen 0.63): store replay through
`kv.scan` pages, health through `lifecycle.report` (`status` shows it). Verified on wasm_the_first on
0.1: 5372 entries restored, resumed IK handshake, CONNECTED in 0.68 s, live messages. It is ported to
0.2 now ("Component services on `wa:kernel@0.2`" below), which this lane built and instantiated but
did not run against an account.

## Speech and posting parity (B2, 05/11)

**`wa:kernel/speech`** (manifest `capabilities.stt: true`): `job.start(audio, mime, language)`,
`job.poll()` (the full transcript, or `again`), and `job.segments(from)` - the segment texts
recognized so far, for streaming. The host (`service_stt.rs`) runs the node's faster-whisper worker
(`scripts/whatsapp-stt-local.py --worker`, the same one the Go connector uses), one job at a time,
under `nice -n 10`. It is **started when the component starts** (the model loads before the first
note) and never stopped for idleness unless `WA_STT_IDLE_SECONDS` > 0. Segment text crosses only the
worker pipe (`"segments": true` in the request, which the Go connector never sends), never a log.

**`wa-whatsapp` pipeline** (Rust, `rust/components/wa-whatsapp/src`):

| module | does |
| --- | --- |
| `queue.rs` | the seam: `enqueue` / `take_main` / `take_express` / `done` / `fail` / `expire_stale` / `drop_key` / `snapshot` / `restore`, with a `Policy` (fresh window, retry backoff, attempts) and `Notice`s for what it gives up. Two lanes: the main lane takes anything, the express lane only short notes (≤ 90 s declared) while the main lane decodes a long one. A shared `wa:queue` component (WASI 0.3, kv-backed, future/stream, remote STT workers via the relay) replaces it later without touching the pipeline |
| `holds.rs` | chat holds and message fences derived from revokes/edits (the Go journal's `mutationProof`/`mutate`/`reproveHolds`): a *provable* mutation fences the exact IDs it names, an unproven one fences its target everywhere and holds the chat for posting only, an untargeted or owner mutation holds the whole chat (no transcription either). Holds strengthen, never weaken; `reprove` releases a posting-only hold once the store can prove its evidence |
| `posting.rs` | the single posting gate (`Gate::Post`/`Shadow`/`Held`) over the allowlist, the configured holds and the derived ones; Go-identical parts (`🤖 _Copiloto_`, 2500 characters, `(i/n)`), post-then-edit pacing |
| `alerts.rs` | own-chat log, Go-identical wording, ≤ 1 message a minute, 12 listed, dropped after 6 h; group alerts name the group's *subject*, never the sender's push name |
| `lib.rs` (guest) | glue: admit (unsupported/fence/held/dedup) → download → recognize (segments) → post as a reply quoting the audio → kv record `tx/<chat>/<id>` (which is also the author record a later revoke is proved against). Host I/O only: the crate is split so `queue`/`holds`/`posting`/`alerts` are pure and compiled on the host too |
| `store.rs` (guest) | wacore's in-memory backend for reads plus write-through of the durable protocol state to `wa:kernel/kv` |
| `recognize.rs` | the recognizer's two halves as one job: `steps` selects the segment stream against the transcript future (no poll, no timer) and `Tracker` accumulates the text and the timings (first segment, recognition). Pure `futures`; tested natively with a fake speech provider |
| `telemetry.rs` | the stable `wa-transcript v=1 key=value` metadata lines the comparison script parses (ids, states, reasons, durations, counts — never text) |

Configuration (the service definition's `config`):

| key | default | meaning |
| --- | --- | --- |
| `language` | `pt` | recognizer language hint (`pt`, `en`, `auto`) |
| `post_transcripts` | `false` | posting master switch |
| `post_allow` | `[]` | where posting may happen: `"own"` (the account's own chat, PN or LID), exact chat JIDs, or `"*"` (cutover). Empty = nowhere |
| `held_chats` | `[]` | chats whose posting is held (transcribed and recorded, `post_held` alert) |
| `alerts` | `false` | send the own-chat log (off while the Go connector also sends it) |
| `stream_edits` | `false` | post-then-edit for notes ≥ `stream_min_seconds` |
| `stream_min_seconds` | `15` | streaming threshold (declared audio length) |
| `edit_interval_seconds` | `5` | at most one edit per interval; the final edit always goes |
| `header_tag` | none | marker after the header (`🤖 _Copiloto_ · wasm`) to tell the component's posts from the Go connector's in the own chat during B2 |
| `fresh_seconds` | `300` | the fresh window (`WA_WHATSAPP_FRESH_SECONDS` semantics) |

Rules kept from the Go connector: a voice note not picked up within the window expires and is never
transcribed late; a ready transcript not sent within the window is never posted; unknown sends never
auto-retry; a voice note already recorded in kv is never processed again (re-delivery, restart);
history sync is never posted; `status@broadcast` and newsletters are ignored; view-once, oversized,
untrusted-timestamp audio is `unsupported`; a revoke/edit naming a message ID fences it (never
transcribed, never posted, even if it arrives during the decode).

Carried over in this stream (the B3 prerequisites): the Go journal's unproven-mutation **chat holds**
instead of a hand-maintained list; the **express lane** for short notes; a **durable queue**: the queue
and the holds are written to `wa:kernel/kv` (`queue`, `holds`) whenever they change and read back at
start, where an item that was in flight when the process stopped is reported as
`interrupted_by_restart` and never re-posted (unknown sends are not retried); and **group titles** in
alerts (the group subject from the group metadata, fetched only when a group alert is about to be
formatted).

Known limits after this stream: the express lane overlaps download/post with a long decode but not
recognition - the host's `wa:kernel/speech` runs one warm worker, one request at a time (a second
worker in `service_stt.rs` is the host-side prerequisite for real two-decode parallelism). The
component still learns about source mutations only from `on_message` (
`protocol_message` REVOKE/`MESSAGE_EDIT` and `info.edit`); whether whatsapp-rust delivers those to
that handler has not been verified live (unchanged from B2). The operator hold-release command has no
counterpart: a hold is released by `reprove` or not at all.

Tests: the four pure modules are compiled and tested natively, without the wasm target or the
protocol crate's `Send` bounds:

```
cd rust/components/wa-whatsapp && cargo test --lib        # 47 tests
cargo clippy --lib                                       # clean
cargo build --release --target wasm32-wasip2             # the component
```

## Component services on `wa:kernel@0.2` (WASI 0.3, native async)

The same class, one contract newer: `wit/kernel-v2/kernel.wit` is `wa:kernel@0.2.0`, run by
`rust/wa-host/src/service_components_v2.rs`. The grants, limits, log file, epoch deadline and
supervisor are the ones described above — what changes is that the guest no longer polls. It awaits a
`stream<list<u8>>` for inbound frames, one `http.send` for an exchange, a segment stream plus one
transcript future for recognition, and `wasi:clocks@0.3.0.wait-for` for a timer. The contract and its
deviations from the draft are in [KERNEL.md](KERNEL.md) ("WASI 0.3 step 1").

**Which runner a module gets.** `services.rs` reads the component's own imports: any
`wa:kernel/*@0.2.0` import means the 0.2 runner and its async-capable engine; everything else keeps
the 0.1 runner and the engine every other component already uses (so 0.1 components — including the
`wa-whatsapp` running on openclaw — are unaffected). A wasip1 core module is still chosen by the
binary's preamble, before either.

**`wa-whatsapp` on 0.2.** The port removed the guest's reactor: `pump_sockets`, `wake_io`, the timer
list, the `LocalPool` polling loop and the 5 ms nap are gone. What replaces them:

| 0.1 | 0.2 |
| --- | --- |
| `wa_ws.recv` polled from a pump loop | one socket task `select`s the inbound stream against the outbound queue (`async-channel`, which gives real backpressure) |
| `wa_http.start` + `poll` (`HttpWait`) | one `http.send(...).await`, body drained from its stream |
| `speech::Job::start` + `poll`/`segments` every 250 ms | `recognize(...).await`, then `select` over the segment stream and the transcript future — the streaming edits keep their pacing (`EditPacer`), the gates are the same code |
| `wa_ctl.stopping` + epoch trap | `lifecycle.stopping()` between awaited ticks |
| `Sleep` on a timer vector | `wasi:clocks@0.3.0.wait-for` |
| spawned tasks run by `LocalPool::run_until_stalled` | a `FuturesUnordered` driven by the same entry point, joined with the main loop |

The pipeline modules (`queue`, `holds`, `posting`, `alerts`) are unchanged and still tested natively —
the port is host I/O, not decisions. `store.rs` awaits the kv calls (the names did not change) and
`reprove` reads a chat's author rows in one `kv.scan` page set before the pure proof runs.

Build and test:

```
cd rust/components/wa-whatsapp
cargo test --lib                                          # 52 tests, native (5 of them the outbox wire shape)
cargo build --release --target wasm32-wasip2               # the component (8 MB)
WA_TEST_WHATSAPP_WASM=<that .wasm> cargo test -p wa-kernel-runtime the_whatsapp
```

That last line compiles and **instantiates** the real component on the 0.2 runner — the check that
every import it emits (kernel 0.2, `wasi:clocks@0.3.0`, preview-2 WASI) is served — without pairing or
sending anything. It is opt-in because the gate does not build this component, and it takes minutes in
a debug build.

**Sending an ordinary message (`whatsapp.outbox`, 06/11).** The owner's decision is that the new bridge
sends ordinary messages freely, to any chat, like the old connector — and *on the architecture*: a
requested message is a job on the shared durable queue, not a hidden side path.

```text
whatsapp_send {chat, text, reply_to?, mentions?}          host.whatsapp_send
  validate the exact JID + text bounds                    wa-whatsapp-outbox (shared crate)
  policy check `whatsapp.send`, target `chat:<jid>`       rate limits (20/min, 6/min per chat, 500/day) + audit
  enqueue `whatsapp.outbox` (fresh 5 min, 3 attempts,
     dedupe sha256(chat|text|reply_to))                   wa:queue, per-component kv namespace
  -> {ok, id, state: "queued", deduped}                   (the job id, never a delivery claim)

wa-whatsapp (queue grant: worker on `whatsapp.outbox`)
  take -> decide (fresh? still valid?) -> client.send_message -> done({message_id}) | fail(reason)

whatsapp_send_status {id}                                 state, attempts, message_id | reason
```

* **The grant** is `queue: {consume: ["whatsapp.outbox"]}` in the manifest, which the host reads as the
  `worker` interface on that one namespace; the long spelling
  (`{"interfaces": ["worker"], "namespaces": ["whatsapp.outbox"]}`) means the same thing
  (`queue_host::Grants::from_manifest` accepts both, and `scripts/test-whatsapp-send.lua` pins the
  component's own world: worker, never producer). `admin` has no shorthand on purpose.
* **The payload** is JSON (`{chat, text, reply_to?, mentions?}`); it is the only place the message text
  lives, and it lives in the queue's kv until the job is settled and reaped. Nothing logs it and no
  answer returns it.
* **The JID is exact** and validated before the policy is asked: `<digits>@s.whatsapp.net`,
  `<digits>@lid` or `<digits>@g.us`. A bare number, a device-qualified `user:12@…`, a `@broadcast` /
  `@newsletter` / `@status` address and a server the library cannot address are refusals with a word
  (`whatsapp_send_bad_chat`, `whatsapp_send_unsupported_chat`), never a guess.
* **LID vs PN is not mapped by us.** The library addresses a LID chat directly
  (`Client::send_message` accepts `@lid`, and it learns its own LID↔PN mappings), so a request is sent
  to exactly the address it named: inventing the other form of an address is how a message reaches a
  stranger. An address the library refuses is a refusal, not a fallback.
* **Quote and mentions.** `reply_to` becomes `contextInfo.stanzaId`; the quoted *body* is not fetched
  (this component keeps no message history), so the client shows a reference-only quote, and in a group
  the quoted `participant` is the chat because the original author is unknown. `mentions` become
  `contextInfo.mentionedJid` as full user JIDs — the shape a group notification needs
  (`src/outbox.rs`, tested natively).
* **Freshness.** A request nobody picked up within five minutes is never sent: the queue expires it,
  and the component's own `decide` refuses it a second time. A message is never sent "late but
  eventually".
* **Retries.** A transport failure is retried by the queue (3 attempts); a refusal (`bad_chat`, `stale`,
  `policy_denied`, …) is not worth retrying, but `wa:queue` has no "permanent failure" call, so it is
  failed with its code and the queue's own backoff/dead-letter runs. The record is terminal inside the
  freshness window, and no attempt ever sends.
* **Governance** is the node's: the `whatsapp.send` rule with the target `chat:<jid>` (rate limits,
  daily cap, audit — [GRANT-POLICY.md](GRANT-POLICY.md)), plus the opaque-frame cap every frame the
  guest writes is still charged against. The component cannot ask the policy itself, by design: a
  component that could ask "may I?" could answer "yes".

Files: `rust/wa-whatsapp-outbox` (payload, JID rules, dedupe key, `decide`, status shape — shared with
the host), `rust/wa-capabilities/src/whatsapp_send.rs` (the two host capabilities), `src/outbox.rs` (the wire
message + retry rule), `src/guest.rs` `outbox_tick`, `wit/wa.wit` (the component's world: the kernel
service contract plus `wa:queue/worker`), and `scripts/test-whatsapp-send.lua` (tool shape, refusals,
and the real enqueue on a binary that carries the capability).

**Not yet verified, and unchanged by the port:** delivery of `protocol_message` REVOKE/MESSAGE_EDIT to
`on_message` (the component's only source of mutations), two-decode parallelism (the host recognizer is
still one warm worker), and anything at all against a live account: this lane did not pair, connect or
send, so the component's behaviour on a phone is the same unknown it was at B3.

## Iterating on a component: `wa dev` and `wa-fake-kernel`

A service component's loop used to be: edit, `cargo build --target wasm32-wasip2`, install the three
files into the node's component directory, `services stop` then `services start`, and read the log.
Two pieces make it seconds instead, and neither needs a node.

**`wa-fake-kernel`** (`rust/wa-fake-kernel`) is the host half of `wa:kernel@0.2` served in memory: the
real `.wasm` on the real 0.2 runner (the same engine configuration, WIT signatures, resource
lifetimes and `wasi:clocks@0.3.0` timer), with every answer that would leave the machine scripted -
kv, http, websocket, speech, secrets, log, health. A component's own tests then run under
`cargo test` with no node, no installed pin and no model:

```rust
let mut kernel = FakeKernel::new("my-service");
kernel.grant_net(&["127.0.0.1:9999"]).grant_storage(true)
      .http_response(HttpRule::ok_json("POST", "http://127.0.0.1:9999/note", r#"{"ok":true}"#));
let outcome = kernel.run_file("my_service.wasm", r#"{"dial":"http://127.0.0.1:9999/note"}"#);
assert_eq!(outcome.outcome, "exit_0");
assert!(outcome.logs_text().contains("dial ok"));
```

Discipline the crate keeps, because a test that lies is worse than no test: an exchange no rule
names is **refused by name** (`http_not_scripted:GET …`), never answered with an empty 200; a
capability the test did not grant is refused exactly as the node refuses it (`storage not declared`,
`stt not declared`, `refused(<url>)` for an ungranted address); and a secret's **value never enters
a record** - `credentials.get` records the name and whether it was granted, and a replay answers
with the stand-in `replayed-secret`. The run's deadline is enforced twice (the tokio timer drops a
parked guest, the epoch traps one that never yields), so a component that never returns fails a test
instead of hanging it.

**Record and replay** are `wa-bounded`'s: `kernel.record()` puts every answered host call through the
same `RecordRing` the node uses, `kernel.save_replay(dir, label)` writes a `.wrz`, and
`kernel.replay_from(file)` answers from it with every script removed. Order, interface, function and
(arguments, when they were kept) must match; a drifted replay is `replay_mismatch:…` (or
`replay_arguments_differ:…`, `replay_exhausted:…`) and the guest receives `failed(…)` rather than an
answer to a question it did not ask. Two calls are not recorded, by design: `log.write` and
`lifecycle.report` are the component's own output (nothing to feed back), and
`lifecycle.stopping` is a live signal - a replayed component that is told to stop must stop.

```
cargo test -p wa-fake-kernel                       # the fixture, through the fake kernel (9 tests)
cargo run -p wa-fake-kernel -- run my_service.wasm --storage --net 127.0.0.1:9999 \
      --http '{"method":"GET","url":"http://127.0.0.1:9999/note","body":"pong"}' \
      --config '{"dial":"http://127.0.0.1:9999/note"}' --logs --record /tmp/replays
cargo run -p wa-fake-kernel -- build rust/components/my-service
```

The CLI prints the outcome, health, the host calls in order and (opt-in, `--logs`) the component's
log; `--record`/`--replay` are the two hooks as flags; `--json` prints one summary line.

**`wa dev <component-dir>`** (`rust/wa-host/src/dev.rs`) is the loop: it watches the crate
(`Cargo.toml`, `Cargo.lock`, `manifest.json`, everything under `src/`), builds for
`wasm32-wasip2` on a change, lays the artifact down as an installed component in
`<dir>/.wa-dev/components/` (wasm, pin last, manifest), and calls `wa_kernel_runtime::dev::swap`.
That swap is the transactional upgrade the supervisor already describes, on one instance: the new
instance starts **beside** the old one with the same grants and state, is waited on for
`lifecycle.report(ready)`, and only then is the old one stopped - so a build that traps, or never
becomes healthy, leaves the previous instance running and says so (`mode=kept_previous`).
`--restart` asks for the other order (stop, then start) for a component whose two instances cannot
coexist (a fixed port, a device). Every cycle prints both numbers, because their sum is the loop:

```
dev: build 22925 ms (6821997 bytes)          # debug fixture: 6.8 MB of wasm
dev: swap 17094 ms mode=start sha256=9a6e161fd609 health=ready start=17053ms ready=0ms stop=0ms
dev: build 34519 ms (199511 bytes)           # the same fixture with --release: 200 KB
dev: swap 9212 ms mode=start sha256=afab88d0bb57 health=ready start=9151ms ready=0ms stop=0ms
```

Push those numbers to where they matter: `swap` here is dominated by wasmtime **compiling** the
artifact (a `.wasm` is compiled on every start; the node caches compiled components by pin, this
loop does not yet), and the debug fixture is 34x the size of the release one - so `--release` is the
fast loop, not the slow one, and the second cycle is the one to watch.

```
wa dev rust/components/my-service                       # watch, build, hot-swap
wa dev rust/components/my-service --once                # one cycle, then exit (the smoke test)
wa dev rust/components/my-service --config '{"portal":8644}' --net 127.0.0.1:28787 --release
```

`bash scripts/test-devloop.sh` is the smoke test: it copies the `wa-fake-kernel` fixture out of the
checkout (rewriting its WIT path to the copy), runs one build+start, edits a source file and waits
for a `mode=hot_swap`, breaks the build and proves nothing was swapped, then checks `--restart` and
`--no-swap` - all under a temp home, so a node's state is never read or written. 22 checks, no
network.

**What this is not, yet.** `wa dev` is the local node *for the component it watches*: it runs the
node's own start path (`services::spawn_instance`) in its own process and keeps the instance in its
own slot. It does not join a running `wa serve`: that needs one node endpoint - "start a second
instance of this name, keep the old one until the new reports ready, then stop it" - and a
`services` action that answers with it, which is a change to `wa-capabilities` and the supervisor's
registry rather than to this loop. Until then an operator with a live node still does `services`
`disable`/`enable` across a build; the swap semantics this loop proves are the ones such an endpoint
would use.

## The warm shadow deploy and the post-then-edit test (p3a)

Two `services` definitions to run the component beside the Go connector. They are documented here
and in `config/`; **nothing in this tree deploys them** (an operator stores one with the `services`
tool's `put`/`enable`). A definition's `net` is not used by a component — its manifest grants it.

| file | what it is for |
| --- | --- |
| `config/whatsapp-shadow.json` | **Shadow**: transcription on with `post_transcripts: false` and an empty `post_allow`, so the pipeline runs end to end (queue, media download, `speech.recognize` with segments, the `tx/<chat>/<id>` record, the alert queue) while the posting gate answers `Shadow` for every chat. Nothing is sent; the only output is the component log. |
| `config/whatsapp-own-chat.json` | **Post-then-edit test**: `post_transcripts: true`, `post_allow: ["own"]`, `stream_edits: true`, `header_tag: "wasm"` (so its posts are distinguishable from the Go connector's in the same chat). A voice note of at least `stream_min_seconds` in the account's own chat is posted within seconds and edited as more segments arrive. The job brief's `edit_streaming` is this component's `stream_edits`; there is no second switch. Two independent gates keep it off third parties: `post_allow: ["own"]` and `policies/default.json` (`whatsapp.send` → `chat:self`, `chat:alerts`). |

**The warm worker.** `service_stt.rs` starts the recognizer as soon as a component holding `stt: true`
starts (`prewarm`), and one request runs at a time through one warm worker. `WA_STT_IDLE_SECONDS`
decides how long it may sit unused: unset, `0` or unreadable = **never** (the default; a stopped
worker pays the model load again, ~16 s on openclaw). Four tests in `service_stt.rs` assert exactly
that, with a fake worker that speaks the same line protocol and counts its own model loads:
`a_second_job_does_not_reload_the_model` (prewarm + two jobs = one load),
`a_first_job_without_a_prewarm_loads_once_and_the_next_reuses_it`,
`a_dead_worker_is_replaced_and_counts_as_a_new_load` (a crash costs a load; a warm worker does not)
and `idle_shutdown_is_off_by_default_and_configurable`.

**Speech on 0.2.** `recognize(...).await` returns the two async values; `recognize.rs` (`steps`)
selects the segment stream against the transcript future, and `Tracker` accumulates the text and the
timings. There is no poll, no timer and no reactor in that path. `recognize::tests` drives those same
functions with a **fake speech provider and a fake clock**: the first segment lands at 250 ms and the
whole recognition at 900 ms (`a_fake_provider_measures_the_first_segment_latency`), a blank segment
does not start the clock, a failed recognition keeps the text it had, and an already-ready transcript
loses no segment. Latency is measured, not asserted from a real decode — a real decode needs the
model on the node, which this lane did not touch.

**Telemetry and the comparison with the Go connector.** `wa:kernel@0.2` has **no guest-facing
telemetry interface** (the kernel exports `log`, `lifecycle`, `kv`, `credentials`, … and nothing
else; the host records its own `host_call_duration_micros` for every kernel call, `speech.recognize`
included, but a guest cannot add a metric). So the component writes one stable metadata line per
voice note into its own service log (`telemetry.rs`):

```
wa-transcript v=1 kind=ready chat=<jid> id=<mid> state=transcribed download_ms=250   first_segment_ms=1500 recognize_ms=4000 total_ms=4700 since_sent_ms=4900 chars=214 segments=9 streamed=false
wa-transcript v=1 kind=posted|shadow|held|blocked|expired|failed|unsupported … reason=<code>
```

`download_ms` = pick → media downloaded; `first_segment_ms`/`recognize_ms` = from asking the
recognizer to its first text and to the transcript; `total_ms` = pick → transcript (the whole
pipeline after the queue); `since_sent_ms` = the source message's own latency. Values are single
tokens (anything outside `[A-Za-z0-9_.:@/+-]` becomes `_`, capped at 120 characters), so a parser
needs no quoting rules and no reason string can split a line. No field carries message or transcript
text: `chars` is a count.

`scripts/compare-transcripts.mjs --log <component.log> --journal <journal.db>` prints the two sides
side by side (`chat, id, kind, dl_ms, first_ms, total_ms, c_chars, seg, journal_state, j_reason,
j_chars, verdict`). Both sides are metadata only: the journal is opened read-only and the only thing
read from `transcript`/`body` is `length(...)`; `scripts/test-whatsapp-compare-transcripts.mjs` plants
a canary transcript in its fixture and fails if it reaches stdout, stderr or `--json`.

## The message index and `whatsapp.query` (06/11)

The owner's requirement (06/11): **every** message is indexed and queryable by the agent - text,
image, video, audio/voice, document (with filename, MIME, size, caption), sticker, location, contact
card, poll, and reactions/edits/deletions as events - and a query answers through the same durable
queue an explicit send already uses.

The Go connector's `messages` row (`chat, id, sender, body, sent, media_kind, media_text`) indexed
text and images, tied an OCR/transcript string to the row, and called everything else
`unsupported_non_audio_message`; its search was SQLite `LIKE` on the raw body. The index below keeps
every field it kept, adds the rest of the kinds and the mutation events, and is searchable by
accent-folded token instead of by substring.

**Where it lives.** The component's own kv (`wa:kernel/kv`), below one prefix, so the queue (`q/`),
the protocol store (`ses/`, `pk/`, …) and the transcription pipeline (`tx/`, `fence/`) each keep their
own keys (`rust/components/wa-whatsapp/src/index.rs`):

```text
ix/m/<chat>/<inv(ts)>/<id>            the record, JSON            (thread read: newest first)
ix/id/<chat>/<id>                     inv(ts)                     (id -> thread key)
ix/s/<sender>/<inv(ts)>/<id>/<chat>   empty                       (by sender)
ix/k/<kind>/<inv(ts)>/<id>/<chat>     empty                       (by kind)
ix/w/<token>/<inv(ts)>/<id>/<chat>    empty                       (normalized-token index)
ix/x/<chat>/<id>/<reactor>/<emoji>    reaction, JSON              (folded onto its target)
ix/all/<ts>/<chat>/<id>               empty                       (age order: retention walks it)
ix/pend/<chat>/<id>                   a mutation for a message not indexed yet
```

`inv(ts)` is `u64::MAX - ts` in fixed-width hex, so an ascending scan is newest-first and `before` is
a plain cursor; `ix/all` is the opposite order because retention starts at the oldest. Every record
carries the media metadata a later download needs (`mime, filename, size, sha256, enc_sha256,
duration_s, pages, width/height, direct_path, media_key`) and the fields a query answers with
(`quoted` for a reply, `mentions`, `push_name`, `edited`/`edits`, `deleted`, `unsupported`). The
media key and the direct path never leave the component: they are how it decrypts later
(`DownloadParams`), not something an answer returns.

**Decisions.**

* **A token index, folded on both sides.** `Ação` and `acao` are one token, `Relatório.pdf` is
  findable as `relatorio`, and a sticker is findable by the emoji its sender tagged it with (an emoji
  is a token; a single letter is not). A query is an AND over its tokens with the exact phrase ranked
  first, then a filename/transcript bonus, then recency - a small ranking, measured in
  `src/index/tests.rs` rather than asserted.
* **Reactions fold, edits and deletions mutate.** A reaction is recorded (actor, emoji, target) and
  attached to its message: `read` shows it there and it is not a bubble of its own; an empty emoji is
  a *removal* of that actor's row. An edit replaces its target's text and its tokens (the same message
  id, `edited: true`, `edits: n`), and a revoke clears the text, the media and every token entry - a
  search cannot return words the sender took back. Both are indexed as events as well, so
  `whatsapp_search {kind: "edit"}` answers "what changed".
* **A mutation that arrives first still wins.** A revoke or edit can land before the message it names
  (re-delivery, history sync): it is kept under `ix/pend/<chat>/<id>` and applied when the record
  arrives, so a deleted message is never indexed with its text.
* **What must not be kept is not kept.** A view-once or ephemeral message is a fact (kind, sender,
  time, `unsupported: view_once`) with no text and no keys. `status@broadcast` and newsletters are
  skipped, as the transcription pipeline already skipped them.
* **Retention is by age, in bounded passes.** `index_retention_days` (default 90) decides the window;
  a pass walks `ix/all` from the oldest, deletes at most `index_prune_budget` records (default 200)
  and stops at the first record inside the window, so it costs what it deletes. There is no record
  count and no counter: a counter that drifts is a counter that deletes live data. The index is bounded
  by the component's storage grant; a write that fails is logged, never treated as done.

**The query lane.** `wa:queue`, queue name `whatsapp.query` (`rust/wa-whatsapp-index` is the shared
request/answer shape; the node's five capabilities are `rust/wa-capabilities/src/whatsapp_query.rs`):

```text
tool whatsapp_search | read | reactions | media | download
  -> validate + bound the request            wa-whatsapp-index
  -> enqueue `whatsapp.query` (fresh 2 min, 2 attempts, dedupe = the request itself)
component wa-whatsapp (queue worker on `whatsapp.query`, one lease at a time)
  -> read its own kv index, settle done(answer) | fail(reason)
tool answer <- the settled result (bounded below the queue's 64 KiB result cap)
```

The node waits up to two seconds (`wa_whatsapp_index::WAIT_MS`) and heartbeats the node while it
waits, so a search answers in the same turn; a slower one answers `whatsapp_<op>_slow` with the job id
and `retry: true`, and the same call reads the same job (the dedupe key *is* the request). A refusal at
the producer writes nothing: `whatsapp_search_empty_query`, `whatsapp_read_bad_chat`,
`whatsapp_search_bad_kind`, `whatsapp_reactions_chat_and_id_required`, …

**Download.** `whatsapp_download` is the one with an effect. The component decrypts with the keys it
kept and hands the plaintext back on the job's **progress stream**, because a job's result is capped at
64 KiB and a video is not a kv record: each attempt starts with a header chunk naming the job
(`wa_whatsapp_index::download_header`), so a retried attempt is told apart from the leftovers of a
failed one. The node collects the last attempt's chunks, checks the length and the SHA-256 against the
message's own digest, and writes the file into `<components>/wa-whatsapp.downloads/` - bounded at 64
files and 64 MiB, oldest evicted first - answering with the path. The default bound is 512 KiB of
plaintext (`index_download_max_bytes`), which covers a photo, a voice note and a one-page document; a
bigger one answers `download_too_large` with its `size` instead of pretending.

**Configuration** (the service definition's `config`, all optional):

| key | default | meaning |
| --- | --- | --- |
| `index` | `true` | index every received message and answer queries |
| `index_retention_days` | `90` | how long a record is kept (clamped to 1..3650) |
| `index_prune_every_seconds` | `300` | how often a retention pass runs (clamped to 30..86400) |
| `index_prune_budget` | `200` | records one pass may delete |
| `index_download_max_bytes` | `524288` | most plaintext `whatsapp_download` will decrypt |

**Transcripts and OCR.** The transcription pipeline attaches the transcript to its message record
(`index::attach_text(…, Source::Transcript)`), so a voice note is found by what was said in it; the
same call with `Source::Ocr` is the seam for an OCR pass. The text is never logged: the component's
lines carry the job, the op, the kind and a count.

**Tests.** `cargo test --lib` in `rust/components/wa-whatsapp` (80 tests, 15 of them the index with a
fake client: every kind, reactions add/change/remove, an edit, a revoke, a revoke that arrives first,
ranking, filters, limits, retention, repair), `cargo test -p wa-whatsapp-index` (14 + 7: the request
shape, the bounds and the round trip against the real queue), `cargo test -p wa-capabilities
whatsapp_query` (8: what a tool call enqueues, what it answers, what it refuses before writing, the
download's chunk collection and the bounded directory), and `scripts/test-whatsapp-index.lua` (74
checks: the tool shapes, the cues, master-only, the refusals, the real enqueue). The component builds
for `wasm32-wasip2` (8.4 MB).

**Not verified here:** a live account. This lane did not pair, connect, receive or send, so whether a
phone delivers the `reactionMessage`/`protocolMessage`/`pollCreationMessage` shapes above as
`on_message` receives them is the same unknown the mutation path already carried. Nothing in the index
touches a socket.

## Decision 05/11: Rust, not Go

The spike proved whatsmeow-in-Go reaches WhatsApp from wasip1, but the owner chose the lightest
result: no Go runtime/GC in the guest (11-27 MB), protocol from `whatsapp-rust`, TLS/websocket/HTTP in
the host. The Go spike stays in `benchmarks/service-component-spike` as evidence.

## Order of work

1. ~~**Host: service runner**~~ (built, above) — wasip1 core modules (wasmtime-wasi p1) with `wa_sock` (from the spike,
   hardened: allowlist with wildcards, per-service socket table, limits), start/stop/restart, status in
   `host.components()`.
2. **Host: `wa_sql`** — SQLite through rusqlite, one directory per service, quota.
3. **Guest: `wa-whatsapp`** (Rust) — whatsapp-rust with host runtime/transport (`wa_ws`)/HTTP
   (`wa_http`); milestone 1 pair/connect/receive; then a host-backed store, STT/OCR host capabilities
   and the journal/queue/reply/freshness/log logic.
4. **Pairing and cutover** on a test account, then openclaw with the same backup/rollback as today.

Open questions, unverified until built: whatsmeow's media download/upload paths under the injected
client (`SetMediaHTTPClient` should cover them), Go wasip1 memory footprint over days, and the
journal's SQL under a host-proxied driver (transactions across imports).
