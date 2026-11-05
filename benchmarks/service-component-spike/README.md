# Spike: can the WhatsApp connector run as a WASI service component?

Question (05/11): the Go connector (`connectors/whatsapp`, whatsmeow) as a long-lived wasm
component instead of a native binary. Three things decide it: does whatsmeow **compile** to WASI,
can it **reach WhatsApp** without sockets of its own, and what has to come from the **host**.

## Results

| question | answer | evidence |
| --- | --- | --- |
| whatsmeow + deps compile for `GOOS=wasip1` | **yes**, with one patch | only `go.mau.fi/util/exhttp` fails (`syscall.EHOSTDOWN` undefined on wasip1); a build-tagged constant fixes it (`guest/exhttp-hostdown*.patch`). Probe that constructs a `whatsmeow.Client` builds to 27 MB unoptimized |
| the connector as-is compiles | no: `modernc.org/sqlite` (libc) has no wasip1 build | storage must come from the host (below) |
| whatsmeow's network is injectable | **yes** | `Client.SetWebsocketHTTPClient` / `SetMediaHTTPClient`: an `http.Client` whose `DialContext` is a host socket; TLS stays pure Go inside the guest |
| a wasip1 Go guest reaches WhatsApp through host TCP | **yes** | `guest/main.go` (coder/websocket, the exact whatsmeow dial path) through `runner` (`wa_sock` imports, allowlist `web.whatsapp.com:443`): `WEBSOCKET_OPEN status=101`, 210/217/235 ms, 3 of 3 runs, certificate verified |
| root CAs inside wasip1 | bundled: `golang.org/x/crypto/x509roots/fallback` | without it: `x509: certificate signed by unknown authority`; verification is never disabled |

Measured from the sandbox container (x86_64, Wasmtime 37, Go 1.27.2), 2026-11-05.

## How the socket works

The guest has no sockets (wasip1). The host opens only allowlisted addresses (`wa_sock.connect`,
refused otherwise) as non-blocking TCP; `read`/`write` return `-11` (EAGAIN) instead of blocking,
and the guest yields with `time.Sleep(2ms)` so the Go scheduler keeps every other goroutine (keepalive,
timers, queues) running. A blocking host read would freeze the whole guest runtime.

## Reproduce

```sh
# guest (needs the exhttp patch via a replace directive, see the .patch files)
GOOS=wasip1 GOARCH=wasm go build -o spike.wasm ./guest
# runner
cargo build --release --manifest-path runner/Cargo.toml
runner/target/release/sockrunner spike.wasm   # WEBSOCKET_OPEN status=101 ...
```

Design that follows from this: [docs/SERVICE-COMPONENTS.md](../../docs/SERVICE-COMPONENTS.md).
