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

- **Host runner** `rust/wa-kernel-runtime/src/services.rs`, capability `host.service` (start / stop / status / logs):
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

`rust/wa-kernel-runtime/src/service_components.rs` runs services built as **components** on the
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
`rust/wa-kernel-runtime/src/service_components_v2.rs`. The grants, limits, log file, epoch deadline and
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

**The operator send on this path (Phase 2, 10/11).** `prepare -> approve -> send -> status` is the
same state machine the Go connector ran (`connectors/whatsapp/operator.go`), now in Lua
(`lua/core/whatsapp_operator.lua`) with the dispatch on this same `whatsapp.outbox`:

* prepare composes the `🤖 _Copiloto_` line before anything is stored, so the approval binds the exact
  bytes; the digest covers the intent id, chat, signed body, reply, mentions, reply-source digest and
  the prepared second. approve must echo the exact fields and the digest; send records the durable
  dispatch intent *before* the enqueue, and a repeated send reads the same intent, never a second job.
* the reply source is loaded exactly (`host.whatsapp_message`, full stored text - a `read` answer is a
  280-character snippet and cannot bind a body): in that chat, plain text, not our own, not deleted,
  with no own message newer on the newest page. The digest changes with the source, so approve and
  send refuse a stale preparation (`operator_preparation_stale_reprepare_and_reapprove`).
* the last gate is the component's (`src/outbox.rs` `dispatch_refusal`): a posting hold, a revoke/edit
  fence, or a reply source it cannot prove refuses the job with its own word, and a refusal is never
  retried into a send.
* status maps the queue job to `dispatched`, `accepted` (a message id from the server ACK), `failed`,
  or `echo_confirmed` when the exact own id/chat/body is in the index. Delivery and read stay unknown.
* the capability files (`approval_token_file`, `dispatch_token_file`) are required as provisioning
  proof, as in the Go path. The route is opt-in per node with `WA_WHATSAPP_OPERATOR_BACKEND=native`,
  so a node whose Go connector still owns the linked session keeps its working route.
* the one weaker point, stated: mentions are the exact JIDs the operator names (validated, at most 8);
  the Go connector also proved each against the group's observed participant list. A mention of a JID
  outside the group is ignored by WhatsApp, so this cannot reach a stranger.

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

## A swap waits for the work in flight (`wa:kernel/drain`, 07/11)

A hot swap used to stop the retired instance first and hand its in-flight queue leases to the new one
afterwards (`services::replace`). That is the right shape for a *crash* - the job did not fail, so it
goes back to `Ready` due now, with its attempt budget untouched, and the queue's lease fencing means
it can never be settled twice. But a swap is not a crash: a job whose effect was already half-applied
(a message sent, not yet settled; an index write landing) was retried by the replacement, and
"at-least-once" is the wrong bill for an upgrade an operator asked for.

So a swap now asks first. The contract is its own interface, `wa:kernel/drain@0.2.0`
(`wit/kernel-v2/kernel.wit`):

```wit
interface drain {
    draining: func() -> bool;   // "a replacement is up: take no new work"
    idle: func();               // "nothing in flight: safe to stop me"
}
```

and the swap is:

```
kernel: draining = true            (drain::retire)
guest : finishes the handle in hand, settles it, calls idle()
kernel: stop, join, hand over what is left (normally nothing), log the outcome
```

**Why its own interface, and not a function on `lifecycle`.** A world's imports are obligations: every
component built against `world service-component` imports `lifecycle`, so a function added there would
be imported by components that do not implement anything. A swap has to know *from the artifact*
whether waiting is meaningful, and the one thing a component cannot fake is the list of interfaces it
imports. Importing `drain` is the declaration; `service_components_v2::drains` reads it; a component
without it is stopped immediately, exactly as before. `wa-whatsapp` opts in (`wit/wa.wit`).

**Three cases keep the old behaviour, always logged** in the retired component's own log
(`services logs <name>`) and in the swap's `drain` answer:

| outcome | when | what happened |
| --- | --- | --- |
| `drained` | the guest reported idle inside the deadline | nothing handed back, the job completed once |
| `nothing_in_flight` | the instance held no queue lease | no wait at all: there was no job to protect |
| `deadline` | the guest did not report idle within `WA_SERVICE_DRAIN_MS` (30 s default) | stop + hand the leases back for a retry, at WARN |
| `no_hook` | the artifact does not import `wa:kernel/drain` | stop + hand back, as before (wasip1 modules, 0.1 components, any 0.2 component that did not opt in) |

The wait is a poll of one atomic (5 ms) bounded by the deadline - the guest can report idle at any
point of its own loop, and the kernel cannot be woken by a host function on another thread. The knob
exists because "how long is one job" is a property of the component: `WA_SERVICE_DRAIN_MS` raises it
for a batch importer, and `0` disables waiting entirely.

A run that reported `idle` is treated as **stopping**, never as a crash to restart (`services.rs`):
without that, a guest that returned cleanly after draining would be restarted beside the instance
that replaced it, which is the "two instances, one queue" bug a swap exists to prevent.

Tests, with the real `svc-drain` fixture (a 0.2 guest that consumes one job, takes `handle_ms` over
it, writes one marker per job into its own kv and settles it - so a second handle leaves `2`):

```
cargo test -p wa-kernel-runtime -- services::tests::a_swap_waits services::tests::a_guest_that_never services::tests::a_component_without
cargo test -p wa-kernel-runtime -- drain::tests queue_host::tests
cargo test -p wa-queue -- in_flight
```

The three integration tests are skipped when the gate did not build the fixtures
(`WA_TEST_SERVICE_DIR`). `scripts/test.sh` builds `svc-drain` beside the other service fixtures.

## Supervisor: by imports, per instance, transactional, layered (06/11)

`docs/KERNEL.md` ("Supervisor features, step 4") is the design record; this is what an operator sees.
All of it is the `services` admin tool (master only, never a child agent) plus `host.service`.

| operation | what it does |
| --- | --- |
| `list` / `status` / `logs` | unchanged, plus: a definition whose imports nobody serves reports `state: "waiting"` with `waiting_for: ["wa:vision/text-reader@0.1.0"]` and `waiting_reason` (`imports_not_served` / `not_installed`), and a running one reports its `generation`, its `instance` (`name#N`) and how many `registrations` it holds |
| `enable` / `disable` / `restart` / `remove` | unchanged. Boot now starts enabled definitions **by imports** (`supervise`), not in store order. A `stop` is final: the definition leaves the supervisor's set (it would otherwise be restarted by the next reconcile), and `enable`/`autostart`/`supervise` put it back |
| `start` / `stop` | the instance, without deciding the boot question: `start` runs a stored definition now, `stop` stops it and hands its claimed queue jobs back. `enable` is `start` **and** the boot decision; `disable` is `stop` **and** forgetting it |
| `upgrade {name, source}` | the transactional install below. The definition's grants stay the ones it was enabled with - an upgrade replaces bytes, not authority |
| `profile_dump [name]` | the effective configuration after base → node → user → patch, rows by id |

### The operator's own door: `wa services` (11/11)

```text
wa services list [--json]            every definition, enabled/not and its live state
wa services status <name> [--json]   one definition plus what the host says it is doing
wa services start <name>             run it now (does not change what happens at boot)
wa services stop <name>              stop it now; claimed queue jobs go back to the queue
wa services enable <name>            start it now and at every boot
wa services disable <name>           stop it now and do not start it at boot
```

No turn and no model: this is the door for a node declared model-less (`docs/MODEL-LESS.md`), where the
`services` tool cannot run because running a tool is running a turn. The decisions are still
`lua/core/services.lua`'s - the CLI is dispatch and printing (`lua/core/services_cli.lua`) - so the two
doors cannot disagree about what "enable" means, and the same master gate applies. A refusal names its
reason and exits non-zero; a name nobody stores is `unknown service`, not a `not_running` that looks like
success.

A master on another node runs the same verbs through the **`services` peer capability** (same gate style
as the WhatsApp read capabilities: `author_of` in `lua/core/server.lua`, then the registry's own
master/admin check), so a coordinator can stop a misbehaving component on a managed node without a turn
there. It is graded `control` for the mesh - stopping a service is the same authority as a shell, not a
read.

### `upgrade` — stage, verify, retire, start, health, switch

```text
services upgrade {name:"wa-whatsapp",
                  source:{wasm:"/…/wa-whatsapp.wasm",
                          manifest_path:"/…/wa-whatsapp.json",
                          pin:"/…/wa-whatsapp.wasm.sha256"},   # or the sha256 itself
                  ready_ms: 10000}
```

The order is the contract and every failure before the switch costs nothing:

1. the three files are staged in `<components>/.stage-<name>-<pid>/` (nothing installed yet);
2. the staged bytes must match the pin - a component without one is refused (`upgrade_pin_required`);
3. every interface the artifact imports must be served by the kernel or by a *running* provider,
   otherwise the answer is `imports_not_served:wa:vision/text-reader@0.1.0` and the old instance keeps
   running (this is the same rule the supervisor uses, read from the artifact's own type);
4. the grant is checked against the staged manifest, and a missing `config` is filled from the profile
   stack;
5. the running instance is **retired first** (11/11): a component that imports `wa:kernel/drain` is asked
to finish the job in hand and report `idle`, then stopped and joined, and the queue leases it still holds
are handed back to the queue. Then the candidate starts - same name, same grants, same state; the
manifest's `state_version` migration runs on a snapshot copy first. **One instance per service name, at
every step**: `services::claim` refuses a second instance of a name that is starting, running, draining
or stopping, whichever door asks (`start`, `enable`, `autostart`/`supervise`, this upgrade, the dev loop).
The old order - start the candidate beside the running one - is right for a stateless component and wrong
for one that owns a device session, a port or a lock: on 09-11 the `wa-whatsapp` cutover had both
instances restore the same device and authenticate, WhatsApp replaced one (`conflict=replaced`), and the
replaced one's outbox went on claiming sends it could not deliver;

### One instance per machine, too: the port first, then the lock file

`services::claim` is a claim *in one process*, and on 11/11 openclaw proved that a second **process** is
where the invariant breaks. Two supervisors ran `wa serve` on one port - a systemd unit
(`wa-serve.service`) and the sentinel - so there were two registries; the process that could never bind
8799 still autostarted `wa-whatsapp` first, opened the device session and got the winner kicked off the
phone (`conflict=replaced`, `bot stopped`, 4251 starts). Three rules now hold, each with a test:

1. **The port is the right of way.** `serve` binds/claims `--port` *before* it starts anything, and a
   process that loses the bind starts **no service and touches no component** (`wa_autostart_services`
   is called by the host after the bind, not at `server.lua` load time) and exits non-zero, so a
   `Restart=on-failure` policy stops instead of looping and the operator sees a failure rather than a
   clean stop;
2. **The lock file is the machine-wide claim.** A start takes an OS lock on
   `<components>/<name>.state/instance.lock` and holds it for the instance's life; a second process's
   start is refused `service_locked`, before anything is compiled or opened. The kernel releases it when
   the holder dies, so a crashed instance never leaves a claim a human has to clear - the failure mode
   `serve.pid` has;
3. **One supervisor, named.** On a systemd node the unit is the owner (it carries the node's
   environment and `Restart=always`): the sentinel asks the unit to restart the node and records the
   unit's `MainPID` as the node pid, and never spawns a serve of its own beside it. The deploy path
   already worked this way (`upgrade.sh`'s `MANAGED_UNIT`: swap the bytes, end the old pid, let systemd
   start the new binary).
6. health: `lifecycle.report(ready)`/`degraded`, or - for a guest that never reports, which includes
every wasip1 module - "still alive after the window", reported as `health: "unreported"` rather than
invented;
7. the files are committed (wasm, manifest, **pin last**) and the instance is switched: the retired
generation's bus subscriptions and queue grants are revoked, the new instance's are not touched.

A refusal after step 4 therefore finds the service retired, and **puts the previous pin back**
(`restore_previous`): the installed bytes were never committed over, so the pair that was running starts
again through the supervisor, and the answer says `restored: {restored: true, generation: …}`. A refused
upgrade costs a restart, never an outage and never two instances.

The answer names what happened (`mode: install|upgrade`, `sha256`, `previous`, `health`, `contract`,
`instance`, `retired`, `restored`), so a script can tell "installed", "upgraded" and "kept the old one"
apart without reading a log. `cargo test -p wa-kernel-runtime install` walks the whole path, including two
refusals that must leave the installed files exactly as they were - and
`one_service_name_never_runs_two_instances` is the negative control for the invariant itself.

### Per-component limits

A manifest declares, the node caps (`docs/KERNEL.md`, "Per-component limits"):

```json
{"limits": {"memory_mb": 512, "cpu_ms": 5000}}
```

`min(declared, cap)`, resolved once for all three runners. The cap comes from `WA_COMPONENT_LIMITS`,
else the `limits` section of `policy.json`, else `<state>/limits.json`, else 512 MB / 5000 ms; a component
row can lower its own numbers but never raise the node's cap, and the start answer says which side
decided (`by: "manifest" | "node" | "both"`). Memory is enforced by the store's limiter; CPU is a
budget of execution time inside one epoch window, after which the guest is trapped (`cpu_limit` → the
service's `last_exit`, visible in `status`). It is a starvation guard, not an accounting instrument -
the heuristic and its risk are written down in `wa_governance::component_limits::CpuBudget`.

### The policy file a component's calls pass through

`policy.json` is read at start *and* watched: a change to the file (mtime/sha256, one stat a second) is
parsed, validated, and swapped into the running engine with its budgets kept, so a rule written by a
deploy - or by hand - is enforced within a second without a restart. `host.policy_status` reports the
`reload` block (`policy_sha256`, `applied`, `last`); a broken file applies nothing and is reported, and
a removed file keeps the loaded policy (a reload must never widen what a node allows). Why this exists
as well as the deploy ordering fix is the 06/11 bug: a node that started 24 s before the file was
written kept the old policy for its whole life.

### Tests

| test | proves |
| --- | --- |
| `cargo test -p wa-kernel-runtime` | imports/served sets and the WIT drift check, plan order independence and cycles, profiles layers, limits resolution, the registration ledger, and the whole transactional install against a hand-built artifact (no toolchain needed) |
| `cargo test -p wa-governance` | the policy reload: file appears, tightens, breaks, is removed, and the watcher thread itself |
| `scripts/test-services-kernel-features.lua` | the same decision layer through the binary: `supervise` wait and `waiting_for`, `profile_dump`, `limits`, `registrations`, the upgrade refusals, the tool schema, and that boot reports a wait instead of a failure |
| `scripts/test-deploy-policy-order.sh` | the deploy installs `policy.json` before the restart, and the reload it depends on is still in the kernel |
| `cargo test -p wa-kernel-runtime services` / `scripts/test-service-component.lua` | the existing registry lifecycle over real fixtures, unchanged (they need the built components; the gate builds them) |

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
ix/ct/<chat>                          one chat's card, JSON       (the name side: names observed there)
ix/bf/cards, ix/bf/cards/done         the name walk's cursor and its done mark
ix/arc/<YYYY-MM>                      a month loaded back from its archive (read-only here)
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
* **Retention is by age, in bounded passes.** `index_retention_days` (default 180) decides the window;
  a pass walks `ix/all` from the oldest, deletes at most `index_prune_budget` records (default 200)
  and stops at the first record inside the window, so it costs what it deletes. A range that belongs to
  a month **restored from its archive** is walked past instead of deleted (one scan of `ix/arc/` per
  pass, then a cursor jump), which is what keeps a restore from being undone by the next tick
  (`docs/WHATSAPP-ARCHIVE.md`). There is no record
  count and no counter: a counter that drifts is a counter that deletes live data. The index is bounded
  by the component's storage grant; a write that fails is handed back to the ingest lane and retried
  (`index::RETRY_LIMIT`), never treated as done.

**The name side (`ix/ct/`).** `whatsapp_contacts` answers from one small row per chat, not from the
records: every indexed message folds its sender's push name into that chat's card (`index::card_touch`),
and `contact`/`contact_array` messages name the chats their phone numbers belong to
(`index::contact_cards`, only for a chat the index already holds, and always weaker than the name a
person writes on their own messages). A group is named by its subject and by nothing else.

Two things this side had to learn the hard way, both measured on the account node (13/11: 57310 stored
entries, messages arriving, and every `whatsapp_contacts` query answering `count: 0`):

* **The card is the FIRST write of a message, not the last.** A message costs five keys plus one per
  token plus its card, and the component's `kv.write` grant is a token bucket (`rate` in
  `policies/default.json`, 240/min with a burst of 480). A bucket that runs out part-way through a
  message therefore always runs out at the end of the sequence, and the card used to be that end: the
  one row the name question reads was the first thing a busy account lost. The record cannot be
  rebuilt from anything; the card can, so the name is written first.
* **The name side is derived, and it rebuilds itself.** `index::backfill_cards` walks `ix/m/` (keyed by
  chat, so a page is a handful of chats), folds each chat's records and writes one card per chat -
  bounded per pass, resumable through `ix/bf/cards`, and it writes `ix/bf/cards/done` so a later tick
  costs one read. The pipeline runs one pass per tick (`guest::backfill_names`). So an index restored
  without its cards, written by a build that came before them, or written while the grant was refusing
  the tail of every message, fills its names back in instead of answering "no chat carries that name"
  forever.
* **The answer says which half it has.** `whatsapp_contacts` carries `index: {chats, messages,
  messages_capped, names}` beside its candidates, where `names` is `ready` / `rebuilding` / `pending`,
  so an index of messages whose names are still being derived can never be read as an account nobody
  has ever talked to. `messages` is a bounded count (`index::COUNT_CAP`, 5000) and `messages_capped`
  says when it stopped there.

**The query lane.** `wa:queue`, queue name `whatsapp.query` (`rust/wa-whatsapp-index` is the shared
request/answer shape; the node's seven capabilities are `rust/wa-capabilities/src/whatsapp_query.rs`):

```text
tool whatsapp_contacts | search | read | message | reactions | media | download | backfill
  -> validate + bound the request            wa-whatsapp-index
  -> enqueue `whatsapp.query` (fresh 2 min, 2 attempts, dedupe = the request + the answering build)
component wa-whatsapp (queue worker on `whatsapp.query`, one lease at a time)
  -> read its own kv index, settle done(answer) | fail(reason)
tool answer <- the settled result (bounded below the queue's 64 KiB result cap)
```

The node waits up to two seconds (`wa_whatsapp_index::WAIT_MS`) and heartbeats the node while it
waits, so a search answers in the same turn; a slower one answers `whatsapp_<op>_slow` with the job id
and `retry: true`, and the same call reads the same job - **within one component build**:
`Verified::dedupe_key_in` puts the answering artifact's sha256 (`services::status`) into the key, and
`wa:queue` answers a repeated key with the job that already carries it whatever state that job is in,
so a key that outlived the component would replay an old refusal forever. That is what the account node
reported on 13/11: `whatsapp_contacts {limit:1}` kept answering `whatsapp_contacts_bad_op state: dead`
from a job that died on the build installed before `contacts` existed, while the component actually
running accepted the op. A refusal at
the producer writes nothing: `whatsapp_search_empty_query`, `whatsapp_read_bad_chat`,
`whatsapp_search_bad_kind`, `whatsapp_reactions_chat_and_id_required`, … and a chat given as a *name*
is queued rather than refused, because resolving it is the index's answer (`whatsapp_read_chat_ambiguous`
lists the candidates, `whatsapp_read_chat_not_found` says nobody carries that name).

A refusal the COMPONENT makes is the tool's own error word, at once: a payload it can never read is
settled `done` with `wa_whatsapp_index::terminal_refusal` (an answer, so nothing is retried into the
same wall) and the host answers `whatsapp_<op>_<code>`; a job an **older** component dead-lettered with
a permanent code answers the same way, with `state: "dead"` and a note naming the upgrade. Measured
13/11 on the account node itself: a component built before `contacts` existed refused the job `bad_op`,
the queue retried and dead-lettered it, and the tool answered `whatsapp_contacts_failed state=dead`
twenty seconds later. The op set is now one list on both sides - `Op::ALL` here, `index::OPS` in the
component, and a test on each side that they are equal, so an op cannot be half-added.

**Backfill.** `whatsapp_backfill` is the one query that reaches out: `{chat?, count?}` asks the
primary phone for messages **older** than the index holds, so a search covers the account's past and
not only what arrived while the node was running. Naming no chat asks the chats the index already
knows, newest first, at most `BACKFILL_MAX_CHATS` (20) of them - one request per chat is a message to
the phone. `count` is the messages per chat: default `BACKFILL_DEFAULT` (50), clamped to
`BACKFILL_MAX` (500), and it is the same `limit` field on the wire, so the seam keeps one count. Each
chat is asked from the oldest message the index holds for it (`history::anchors`), or from the phone's
newest messages when the index holds none.

The answer is what was **asked for** - `chats[{chat, count, oldest_id, oldest_ts}], count` and a
`note` when some chats could not be asked - never a message: the delivery arrives through the normal
protocol and the same drain that indexes a relink indexes it, marked `source: history`, so it is
findable by the next `whatsapp_search`. Because it asks the phone, the capability is registered as
`network` (not `read-only`) and the tool is not on the steering fence's read-only list; a client that
is not connected is a failed job (`not_connected`), which the queue retries, and an index that holds
no chat at all answers `count: 0` with the note that a live message has to arrive first.

| tool | arguments | answers |
| --- | --- | --- |
| `whatsapp_backfill` | `chat?, count?` | `chats[{chat, count, oldest_id, oldest_ts}], count, note?` |

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
| `index_retention_days` | `180` | how long a record is kept (clamped to 1..3650); the same window the past is bounded by |
| `index_prune_every_seconds` | `300` | how often a retention pass runs (clamped to 30..86400) |
| - | - | what leaves the window is archived by the node, not the component: `docs/WHATSAPP-ARCHIVE.md` |
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
whatsapp_query` (9: what a tool call enqueues, what it answers, what it refuses before writing, the
backfill's count and request list, the download's chunk collection and the bounded directory), and
`scripts/test-whatsapp-index.lua` (89 checks: the tool shapes, the cues, master-only, the refusals,
the real enqueue). The component builds
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
