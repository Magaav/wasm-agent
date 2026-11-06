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
cd rust/components/wa-whatsapp && cargo test --lib        # 38 tests
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
cargo test --lib                                          # 38 tests, native
cargo build --release --target wasm32-wasip2               # the component (8 MB)
WA_TEST_WHATSAPP_WASM=<that .wasm> cargo test -p wa-host the_whatsapp
```

That last line compiles and **instantiates** the real component on the 0.2 runner — the check that
every import it emits (kernel 0.2, `wasi:clocks@0.3.0`, preview-2 WASI) is served — without pairing or
sending anything. It is opt-in because the gate does not build this component, and it takes minutes in
a debug build.

**Not yet verified, and unchanged by the port:** delivery of `protocol_message` REVOKE/MESSAGE_EDIT to
`on_message` (the component's only source of mutations), two-decode parallelism (the host recognizer is
still one warm worker), and anything at all against a live account: this lane did not pair, connect or
send, so the component's behaviour on a phone is the same unknown it was at B3.

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
