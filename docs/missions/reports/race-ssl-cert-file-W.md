# change/race-ssl-cert-file-W - honour SSL_CERT_FILE / SSL_CERT_DIR for every HTTPS wa makes

Branch `change/race-ssl-cert-file-W`, base `origin/main` (ac7717e0), worktree
`/home/victor/Work/missions/race-ssl-cert-file-W/wt`. Built and tested on avell only.

## The problem, measured again before any code

The brief said a cloud sandbox with its own CA bundle could not reach anything over TLS until a
bridge was bolted on, while `pi` worked. Re-measured here:

| premise | what the tree actually shows |
| --- | --- |
| "wa uses a TLS client that ignores the CA environment" | true, and the reason is sharper than the brief: the client is `ureq` 3.4.0 (`rust/Cargo.lock:2062`) with `_ring` + `rustls-webpki-roots` and **no** `platform-verifier`, so `ureq::tls::TlsConfig::default()` is `RootCerts::WebPki` - a compiled-in Mozilla bundle. No code named `SSL_CERT_FILE` or `SSL_CERT_DIR` anywhere in the tree (`grep -rn SSL_CERT_FILE` before this change: 0 hits). |
| "else the system default" | the default is **not** the OS store: it is the compiled-in bundle above. That stays the default here (parity, see below); a machine that names no bundle gets byte-for-byte what it got before. |
| "wa-vault upstream" is an HTTPS path | **stale**: `rust/wa-vault` contains no HTTP client at all (`grep -rn 'ureq\|https://\|TcpStream' rust/wa-vault/src`: 0 hits). Nothing to wire. |
| "MCP HTTP" is inside wa | **half stale**: the Rust MCP guest components reach HTTP through `host.http` / `wa_http`, which are wired by this change; the live MCP connector is **Node** (`scripts/mcp-client-core.mjs`, spawned from `lua/core/mcp.lua`), and Node ignores both variables. Measured below, and named as the one gap this change does not close. |
| "release fetch" | true, and it is `rust/wa-capabilities/src/ripgrep.rs` (a GitHub release download), wired here. |
| "rendezvous/relay client" | true, three places: `wa-rendezvous/relay_client.rs` (relay poll + the answer a node posts), `wa-rendezvous/node.rs` (registration and heartbeats) and `wa-host/mesh_transport.rs` (the node's `https` relay hop injected into `wa-mesh`). All wired here. |
| "provider adapters" | true: they build URLs only (`wa-model-gateway`); the call itself is `host.http` / `host.http_sse` / the streaming completion in `rust/wa-capabilities/src/host.rs`, wired here. |
| "every outbound HTTPS path" | one path the brief did not name is also TLS: the guest websocket (`wa_ws`, `tungstenite::connect` at `wa-kernel-runtime/src/service_io.rs:260` before this change). Wired here as well. |

## The rule (rust/wa-tls, commit 052235cd)

A new leaf crate, `wa-tls`, is the single answer to "what do we trust":

* `SSL_CERT_FILE` names one PEM bundle; every certificate in it is trusted.
* `SSL_CERT_DIR` names directories, `:`-separated (`;` on Windows); every certificate in every file
  directly inside them is trusted.
* Both together are one anchor set - a union, the way OpenSSL's two variables are.
* They **replace** the compiled-in bundle when named, and a machine that names neither (or sets an
  empty value) keeps `RootCerts::WebPki`, i.e. today's behaviour exactly.
* A named source that cannot be read, or that carries no certificate, is an **error naming the
  variable, the source and the reason** - never a fall back to the compiled-in roots.
* A value that is not valid UTF-8 is an error, not "unset".
* Within a directory, a file that carries no certificate (a README, a hash link, a CRL) is skipped -
  a directory holds whatever the packager put there; a file that cannot be read, or that is PEM and
  broken, is an error.
* Read once per environment value, process-wide: a 200 KB bundle parsed on every provider call would
  be work in the way of the call. A bundle replaced in place is picked up on the next start.

Every site below takes its `ureq::tls::TlsConfig` from `wa_tls::tls_config()`; nothing else decides
what is trusted, and nothing was loosened: verification stays on, and `RootCerts::Specific` is an
allow-list of anchors, never a disable switch.

## Each path, and the commit that wired it

| path | site | commit |
| --- | --- | --- |
| provider call and stream (`host.http`, `host.http_sse`, streaming completion) | `rust/wa-capabilities/src/host.rs:396` (`build_config_with`), callers at 1861/1868/2501/2621/2947 region | 66bf6ba6 |
| release fetch (ripgrep from GitHub releases) | `rust/wa-capabilities/src/ripgrep.rs:52` | 66bf6ba6 |
| mesh relay hop (node -> `https` relay) | `rust/wa-host/src/mesh_transport.rs:37` | 13dbb97a |
| guest's own HTTP exchange (both the 0.1 poll and the 0.2 await contracts) | `rust/wa-kernel-runtime/src/service_io.rs:590` (`exchange`) | 13dbb97a |
| guest websocket (`wa_ws`) | `rust/wa-kernel-runtime/src/service_io.rs:248` (`connect_ws`) and `:298` (`ws_connector`) | 13dbb97a |
| relay poll and the relay answer a node posts | `rust/wa-rendezvous/src/relay_client.rs:79` (`agent`), used at 100 and 262 | 147c3e74 |
| registration and heartbeats | `rust/wa-rendezvous/src/node.rs:293` (`rendezvous_agent`) | 147c3e74 |
| gate rows | `scripts/test.sh:260-264` | dbbb2f4a |

The websocket takes the machine's anchors **only when it names a bundle**; otherwise
`tungstenite::connect` runs unchanged (its own bundle, its own redirect handling). That is an
allow-list switch, and it means the path every deployment uses today is untouched.

## Tests, and where they are wired

All of them hand a real `rustls` server a certificate from a **private CA** (`rust/wa-tls/fixtures/scratch-tls`,
generated once by `generate.sh`, valid until 2126 and committed) and drive the function real use takes:

| crate | filter | tests | wired in |
| --- | --- | --- | --- |
| wa-tls | (whole crate) | 16 + 1 doc: the rule (file, directory, list, union, missing/unreadable/no-certificate/non-UTF-8 all named), and the wire: refused without the variables, accepted with `SSL_CERT_FILE`, with `SSL_CERT_DIR`, and for both CAs when both are set | `scripts/test.sh:260` |
| wa-capabilities | `tls_anchor_tests` | 3: the provider agents (plain and the shutdown-aware transport) refuse a private CA and accept it when named; a broken bundle refuses with the path in the message | `scripts/test.sh:261` |
| wa-host | `tls_anchor_tests` | 4: `UreqTransport::post` (the relay hop) refuses / accepts by file / accepts by directory / refuses a broken bundle as `tls_anchors_unavailable:` | `scripts/test.sh:262` |
| wa-kernel-runtime | `tls_anchor_tests` | 5: `exchange` refuses / accepts by file / accepts by directory / refuses a broken bundle; and the websocket gets **past TLS** only when a bundle is named | `scripts/test.sh:263` |
| wa-rendezvous | `tls_anchor_tests` | 4: `respond` (the relay answer, signed by a node key the test keeps in its own directory) refuses / accepts by file / accepts by directory / refuses a broken bundle | `scripts/test.sh:264` |

The fast path also runs every touched crate's Rust tests, so these run there too.

Measured refusal, without the variables (asserted, not quoted from documentation):

```
io: invalid peer certificate: UnknownIssuer
```

The refusal is pinned to its shape - `ureq::Error::Io` of kind `InvalidData` carrying rustls's
`InvalidCertificate` - so a test cannot pass on a timeout or a DNS failure wearing the same words.

Hermetic: every test binds `127.0.0.1:0`, writes only inside a directory of its own under the system
temp dir, sets the two variables through one process-wide guard (`wa_tls::scratch::Env`) that clears
both first and restores them on drop, and never touches the live `~/.wasm-agent` (the node key in the
rendezvous test goes to that scratch directory via `WASM_AGENT_NODE_KEY`).

## Runs

| run | result |
| --- | --- |
| `cargo test -p wa-tls -p wa-rendezvous -p wa-host -p wa-kernel-runtime -p wa-capabilities` (under `flock`) | 343 + 32 + 4 + 184 + 19 + 16 passed, 0 failed |
| `bash scripts/fast.sh` (under `flock`) | see below |

## The one gap this change does not close, measured

**MCP HTTP from Node.** `scripts/mcp-client-core.mjs` reaches an MCP server with `fetch`, spawned from
`lua/core/mcp.lua`, and Node ignores both variables. Measured against the same scratch server with
node v26.13.1 (a probe that starts a TLS server presenting the fixture certificate and runs `fetch`):

| invocation | result |
| --- | --- |
| plain | `ERR fetch failed` |
| `SSL_CERT_FILE` set | `ERR fetch failed` (ignored) |
| `NODE_EXTRA_CA_CERTS=<that file>` | `OK` |
| `node --use-system-ca` with `SSL_CERT_FILE` set | `OK` |
| `node --use-system-ca` without it | `ERR fetch failed` |

So the operator's fix today is one variable in the spawn environment
(`NODE_EXTRA_CA_CERTS=$(SSL_CERT_FILE)`, additive and available since Node 7.3, so no version
gamble), and the code fix is to set it where the MCP connector is spawned - plumbing this mission did
not do, because the spawn goes through the launch request (`rust/wa-capabilities/src/operations.rs`)
and I could not both change and *verify* that path in the time left. It is named here rather than
half-done.

Also deliberately not changed, with the reason:

* **`wa-sentinel`** (`main.rs:447`, `main.rs:1341`, `jobs.rs:1095`, `sentinel_return.rs:10`): every one
  of those URLs is hard-coded `http://127.0.0.1:<port>`, so no TLS handshake happens and no trust
  anchor applies - curl and OpenSSL behave the same way for an `http://` URL. Wiring them would mean a
  broken `SSL_CERT_FILE` degrades the *supervisor's* health loop, which is a blast radius this change
  does not need.
* **`wa-telemetry-sink`**: refuses `https` outright (`ConfigError::UnsupportedScheme`, `otlp.rs:86`), so
  there is no TLS path there to trust anything.
* **Shell and Node tooling under `scripts/`** that calls `curl`/`wget`: those read the two variables
  natively through OpenSSL; nothing to wire.

## Texts to approve (verbatim, new or changed operator-facing strings)

1. `SSL_CERT_FILE {path}: cannot be read: {io error}`
2. `SSL_CERT_FILE {path}: no certificate in this file`
3. `SSL_CERT_FILE {path}: not readable as PEM: {error}`
4. `SSL_CERT_DIR {dir}: cannot be listed: {io error}`
5. `SSL_CERT_DIR {dir}: {file}: cannot be read: {io error}`
6. `SSL_CERT_DIR {dir}: {file}: not readable as PEM: {error}`
7. `SSL_CERT_DIR {list}: no certificate in any file of this directory list`
8. `SSL_CERT_FILE and SSL_CERT_DIR name no certificate`
9. `{name} {value:?}: not valid UTF-8`
10. `tls_anchors_unavailable:{message}` (the relay hop, the relay poll/answer and the rendezvous
    heartbeat prefix their failure with this, so the log line still says which layer refused)
11. `[rendezvous] {path} not sent: tls_anchors_unavailable: ...` (the heartbeat loop's stderr line)
12. `ssl_cert_anchor_invalid: {error}` (a certificate in the named source that rustls cannot use as an
    anchor)
13. `ws_handshake: the url names no host` / `ws_handshake: {io error}` / `ws_handshake: the host
    resolved to no address` / `ws_handshake: interrupted` (the websocket's own refusals on the
    anchors path)

## What I did not do

* Not pushed, not landed: local commits only, as instructed.
* Did not close the Node MCP path (above), nor change `wa-sentinel`'s loopback clients (above).
* Did not verify any machine other than avell; the Windows path separators for `SSL_CERT_DIR` are
  written (`;`) but only exercised on Linux.
* Did not change the meaning of the emptiness rules for a machine that names no bundle: the compiled-in
  bundle still wins, by design.
