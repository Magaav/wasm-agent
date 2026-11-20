# change/race-ssl-cert-file-W - honour SSL_CERT_FILE / SSL_CERT_DIR for every HTTPS wa makes

Branch `change/race-ssl-cert-file-W`, **rebased onto `origin/main` 39bbf2b6** (review r1), worktree
`/home/victor/Work/missions/race-ssl-cert-file-W/wt`. Built and tested on avell only.

## The problem, measured again before any code

The brief said a cloud sandbox with its own CA bundle could not reach anything over TLS until a
bridge was bolted on, while `pi` worked. Re-measured here:

| premise | what the tree actually shows |
| --- | --- |
| "wa uses a TLS client that ignores the CA environment" | true, and the reason is sharper than the brief: the client is `ureq` 3.4.0 (`rust/Cargo.lock:2062`) with `_ring` + `rustls-webpki-roots` and **no** `platform-verifier`, so `ureq::tls::TlsConfig::default()` is `RootCerts::WebPki` - a compiled-in Mozilla bundle. No code named `SSL_CERT_FILE` or `SSL_CERT_DIR` anywhere in the tree (`grep -rn SSL_CERT_FILE` before this change: 0 hits). |
| "else the system default" | the wording was wrong and the code is not: ureq's default is **compiled-in Mozilla roots**, not the OS store (review r1, SHOULD 2 - the report and `wa-tls` now say so). That set stays the default here (parity, see below); a machine that names no bundle gets byte-for-byte what it got before. |
| "wa-vault upstream" is an HTTPS path | **right, and my first pass measured the wrong half**. `rust/wa-vault` is the Rust key store and has no HTTP client (0 hits) - but the upstream is the **Python** vault, `vault/wa_vault.py`, which reaches providers with `http.client.HTTPSConnection` (`http_request` at line 530, and the proxy handler at 710). Python honours `SSL_CERT_FILE`/`SSL_CERT_DIR` through OpenSSL's default verify paths, so the anchors themselves already worked; what did not is that **OpenSSL silently skips a file it cannot read**, so a misnamed bundle surfaced as `vault_upstream_unreachable` - a verify failure dressed as a network failure. Fixed in review r1 item 2, with a gate row. |
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
| **the Python vault's https upstream** | `vault/wa_vault.py` (`trust_anchors`, called by `http_request` and the proxy handler) | review r1 item 2 |
| **every child wa starts, for the child's own Node TLS (the MCP connector)** | `rust/wa-operation/src/shell_env.rs` (`inherit_ca_bundle`, from `configure_spec`) | review r1 item 1 |

The websocket takes the machine's anchors **only when it names a bundle**; otherwise
`tungstenite::connect` runs unchanged (its own bundle, its own redirect handling). That is an
allow-list switch, and it means the path every deployment uses today is untouched. On the anchors
path the socket is dialled here (10 s connect, every resolved address tried) and tungstenite still
performs the TLS wrap and the upgrade (`client_tls_with_config`). It follows a redirect too - three
hops, the count `tungstenite::connect` uses - so a machine that names a bundle does not lose a hop it
had without one (review r1, SHOULD 1); the one deliberate difference is that a redirect which would
leave TLS for a plain `ws://` URL is refused rather than followed, and there is a test for each.

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

All heavy runs under `flock -w ... /tmp/wa-suite.lock`, one at a time.

| run | result |
| --- | --- |
| `cargo test -p wa-tls -p wa-rendezvous -p wa-host -p wa-kernel-runtime -p wa-capabilities` | 343 (wa-capabilities) + 32 (wa-rendezvous) + 4 (wa-host) + 184 (wa-kernel-runtime) + 19 (wa-tls) passed, **0 failed** |
| `bash scripts/fast.sh` (before the review, base ac7717e0) | **ok: 307 checks, 0 failed, 0 skipped, 184s** |
| `bash scripts/fast.sh` (after review r1, on origin/main 39bbf2b6) | 315 checks, **2 failed** - both pre-existing on 39bbf2b6, see "The two rows that are red on origin/main" |
| `bash scripts/fast.sh` on the first attempt | 1 of 307 failed: `rust wa-graph` - **pre-existing and environmental**, see below |

### The one failure, and why it is not this change

`wa-graph`'s `coordinator::tests::deep_unicode_cache_paths_preserve_sqlite_locking_and_read_only_snapshots`
failed with `SqliteFailure(CannotOpen, extended 14)` on a path under this session's `TMPDIR`
(`/home/victor/Work/missions/race-ssl-cert-file-W/home/.wasm-agent/tmp/...`). Measured on the **base commit**
in its own worktree (`git worktree add /tmp/wa-base-race-W ac7717e0`, never a stash):

| tree | TMPDIR | result |
| --- | --- | --- |
| base ac7717e0 | this session's (deep) | **fails**, same panic, same path |
| base ac7717e0 | `/tmp/wa-shallow-tmp` | **passes** |
| this branch | `/tmp/wa-shallow-tmp` | **passes** |

So the row is about the depth of the runner's temp directory, not about TLS; it is named here and the
rest of the fast path is green with a shallow `TMPDIR`. Nothing in `wa-graph` was touched by this
branch (`git diff --stat ac7717e0..HEAD -- rust/wa-graph` is empty).

## The Node MCP path: closed in review r1 item 1

A child wa starts is now given the machine's bundle under `NODE_EXTRA_CA_CERTS` (the name Node reads,
additive, available since Node 7.3) when `SSL_CERT_FILE` names one and the caller has not set it. It is
decided once, in `wa-operation`'s `configure_spec`, which every operation child goes through - the MCP
connector (`scripts/mcp-client.mjs`, started from `lua/core/mcp.lua`) included. `SSL_CERT_DIR` is
deliberately not forwarded: Node has no directory form, and guessing at a flag older Node builds reject
would break the connector on exactly the machines that set it. The test spawns a real node 26 child
against the scratch CA: it reaches the private CA with the forwarded variable and fails without it.

## What is left: measured, not closed

**Node's own TLS is only reached through the child environment.** A Node process started by hand (not
by wa) still ignores both variables; that is Node's behaviour, not wa's, and `NODE_EXTRA_CA_CERTS` is
its answer. What wa controls - the children it starts - is covered above. Measured on node v26.13.1
against the same scratch server:

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
14. `vault_ca_unreadable`: `SSL_CERT_FILE {path} cannot be read ({reason}); no https upstream can be verified`
15. `vault_ca_unreadable`: `SSL_CERT_DIR {dir} cannot be listed ({reason})`
16. `vault_ca_without_certificate`: `SSL_CERT_FILE {path} carries no PEM certificate`
17. `NODE_EXTRA_CA_CERTS` is set for a child from `SSL_CERT_FILE` (no new text; the variable and the
    caller's own value are what an operator sees in the child's environment)

## Self-review (this is self-review, not an independent review)

Read back before reporting: the loader refuses (never defaults) on every unreadable or
certificate-free source and on a non-UTF-8 value; no path disables verification or widens
`fs`/`net` grants; `agent()` in `wa-capabilities` remembers only a built agent, so a broken
environment cannot be cached as a permanent failure; the anchor cache in `wa-tls` is keyed by both
variables, so a test that changes them cannot read another test's answer; every new test drives the
function real use takes (`UreqTransport::post`, `exchange`, `WsConn::open`, `respond`,
`build_config_with`/`agent_for_stream`) and none of them asserts on a mock; `bash -n scripts/test.sh`
parses; the tree is clean and every item is its own commit.

## Review r1 (independent review, verdict FIX): what each item changed

| item | commit | test that fails before it |
| --- | --- | --- |
| 1. Node MCP: `NODE_EXTRA_CA_CERTS` from `SSL_CERT_FILE` where wa starts children | 1595b002 | `wa-operation` `ca_bundle_tests` (four, including a real node child that reaches the scratch CA only with the forwarded variable) |
| 2. the Python vault checks both variables and names what it cannot read | this commit | `scripts/test-vault.py`: with the base vault 5 of the new checks fail (`vault_ca_unreadable` / `vault_ca_without_certificate`); with it, 116 checks, 0 failed |
| 3. the websocket test completes a real RFC 6455 upgrade and echoes a frame | 5c7b3051 | `a_websocket_upgrades_and_echoes_when_the_machine_names_the_ca`: the previous test asserted an *error*, so it fails against this one by construction |
| 4. the CA test seam installs anchors, never `set_var` | e2c2a46b | `installing_anchors_for_a_test_writes_no_process_environment` |
| 5. `wa-tls` in the fast path's crate list | see the commit | the fast path's own `rust wa-tls` row (absent before: a change to `wa-tls` ran no rust row) |
| 6. no CA private keys in the repository | see the commit | `the_repository_holds_no_ca_private_key` |
| 7. trust gated on the scheme | ca3760c7 | `a_broken_bundle_does_not_refuse_a_plain_http_request` and its siblings in wa-host, wa-kernel-runtime (http and ws) and wa-rendezvous, plus `a_plain_url_is_answered_without_reading_the_bundle` in wa-tls |
| SHOULD 1. the websocket keeps its redirect behaviour on the anchors path | 44304239 | `a_websocket_follows_a_redirect_and_echoes_on_the_anchors_path` (two scratch servers: the 302 and its target) and `a_websocket_refuses_a_redirect_off_tls` |
| SHOULD 2. say compiled-in Mozilla roots, not "system default" | this commit | no test: a wording correction, measured in the premises table above |

## The rebase, and the two rows that are red on origin/main

Rebased 18 commits onto `origin/main` 39bbf2b6 (review r1). One conflict, in `scripts/test.sh` where
origin/main had added its own rows at the same line: both sides kept, upstream first, no assertion
touched, `bash -n` clean. The rest applied without conflict; `git diff <pre-rebase> HEAD` shows only
origin/main's own changes.

After the rebase, `scripts/fast.sh` is 315 checks with **2 failed**, and neither is this branch's:

| row | measurement |
| --- | --- |
| `lua scripts/test-refusal-contract.lua` | fails identically on **origin/main in its own worktree**: `lua/core/refusal_codes.lua is stale: run lua5.4 scripts/gen-refusal-codes.lua --write` (`scripts/test-refusal-contract.lua:24`) |
| `rust wa-capabilities` - `adoption_survives_the_relay_deadline` and `await_returns_at_its_own_wait` | both **refuse** on origin/main in its own worktree, with the ambient HOME: `refusing to run: this test starts real operations, so HOME must be a scratch or temp directory ... scripts/test.sh runs it with HOME=$GATE_HOME`. The gate rows use `HOME="$GATE_HOME"`; the fast path's rust row does not, so the fast path runs them with the session home and they refuse - correctly. With `HOME` set to a scratch directory they pass (measured: 1 passed each). |

Everything this branch touches is green in that same run: `wa-tls`, `wa-operation`, `wa-host`,
`wa-kernel-runtime`, `wa-rendezvous`, `wa-capabilities` (342 of 344 - the two above), and
`python scripts/test-vault.py` at 116 checks, 0 failed.

## What I did not do

* Not pushed, not landed: local commits only, as instructed.
* Did not close the Node MCP path (above), nor change `wa-sentinel`'s loopback clients (above).
* Did not verify any machine other than avell; the Windows path separators for `SSL_CERT_DIR` are
  written (`;`) but only exercised on Linux.
* Did not change the meaning of the emptiness rules for a machine that names no bundle: the compiled-in
  bundle still wins, by design.
