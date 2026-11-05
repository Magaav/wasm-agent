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
| protocol (whatsmeow), journal logic, holds/fences, outbox, freshness, alerts | **guest** (Go → wasip1) | all of `connectors/whatsapp` except the items below; it compiles with one upstream patch |
| TLS | guest (pure Go, bundled roots) | the host never sees plaintext |
| TCP | **host**, `net` grant | exact `host:port` list; non-blocking imports (spike: 101 in ~220 ms) |
| SQLite (journal + device keys) | **host**, `storage` grant | a `database/sql` driver in the guest over host imports to a host-owned file in the component's own state dir; keeps the connector's SQL unchanged |
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

## Order of work

1. ~~**Host: service runner**~~ (built, above) — wasip1 core modules (wasmtime-wasi p1) with `wa_sock` (from the spike,
   hardened: allowlist with wildcards, per-service socket table, limits), start/stop/restart, status in
   `host.components()`.
2. **Host: `wa_sql`** — SQLite through rusqlite, one directory per service, quota.
3. **Guest: connector build tag** — `//go:build wasip1` files: dialer via `SetWebsocketHTTPClient`,
   SQL driver over `wa_sql`, STT/OCR over host capability; the native build unchanged. Upstream the
   `exhttp` patch.
4. **Pairing and cutover** on a test account, then openclaw with the same backup/rollback as today.

Open questions, unverified until built: whatsmeow's media download/upload paths under the injected
client (`SetMediaHTTPClient` should cover them), Go wasip1 memory footprint over days, and the
journal's SQL under a host-proxied driver (transactions across imports).
