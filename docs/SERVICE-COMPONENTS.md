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
log, credentials in; `service.run(config)` out). The supervisor picks the runner from the binary's
preamble (component vs core module), so wasip1 modules keep working. `wa-whatsapp` is now a
`wasm32-wasip2` library component (wit-bindgen 0.63): store replay through `kv.scan` pages, health
through `lifecycle.report` (`status` shows it). Verified on wasm_the_first: 5372 entries restored,
resumed IK handshake, CONNECTED in 0.68 s, live messages.

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
