# download-says-why - a release asset that survives a slow minute, and says why it failed

Branch `change/download-says-why`, cut from `origin/main` at **345e51be** (origin/main has since moved to
39e862d6 - this node was deployed to it during the mission; nothing here was rebased, nothing pushed).

## 1. What was wrong, measured

The brief's premise reproduces exactly, on the base commit, with a local stub server and no network
(`/tmp/base-dsw`, a separate worktree at 345e51be, `scripts/lib/node-binaries.sh` as it was):

```
== OLD PATH, 404
rc=8
out=[node_release_unreachable: http://127.0.0.1:39173/rel55/no-such-asset]
== OLD PATH, 55 MB at 300 kB/s (183 s of transfer)
rc=8 took 120s
out=[node_release_unreachable: http://127.0.0.1:39173/rel55/wa-x86_64-unknown-linux-gnu-111111111111]
(then: a 0-byte file in the destination directory)
```

Two facts, both from that one run: `-m 120` is a cap on the WHOLE transfer, so a 55 MB body that needs
183 s is refused at 120 s - the 24/11 failure; and `2>/dev/null || node_release_unreachable` threw away
the only thing that differed between a slow line, a 404 and a dropped connection, while printing the URL
(which on the ordinary channel carries no secret, but a `WA_NODE_BINARIES_URL` base can).

The brief's `scripts/lib/node-binaries.sh:531` was correct at 345e51be (`curl -fsSL -m 120 ...`). The
"attempt B 145.1 s = 8.4 s preflight + the 120 s cap" arithmetic is from the work node's log and was not
re-derived here; what was measured here is that the cap alone produces exactly that shape.

## 2. What changed

| commit | what |
| --- | --- |
| **8652daf1** | `scripts/lib/download-asset.sh` (new): the one transfer. `scripts/lib/node-binaries.sh` uses it for every asset; `scripts/lib/deploy-components.sh` uses it for the component bundle; `scripts/deploy.sh` ships it beside the installed deploy (line 2259); `lua/core/icons.lua`'s font line gets the same rules; `scripts/test-node-download.sh` (new) + `scripts/lib/http-stub.py` (new) + the wiring in `scripts/test.sh:606`. |
| **d20f960b** | progress: `wa_download_asset` writes `downloading <label>: N of M MB` into the phase file `lua/core/update_follow.lua` already reads, at most one line per 3 s; row f of the same test. |
| **34d3d43e** | the stub server moves from `tests/fixtures/http-stub/server.py` to `scripts/lib/http-stub.py`: `scripts/test-discriminates.sh` calls anything under `tests/` with a runner extension a TEST and would run it with no arguments (see section 6). |
| this report | `docs/missions/reports/download-says-why.md` |

The transfer, in `scripts/lib/download-asset.sh` (commit 8652daf1):

- **no total-time cap.** `--connect-timeout 15`, and a stall window instead: `--speed-limit 51200
  --speed-time 30`. A transfer may take as long as it takes.
- **resume.** Up to `WA_DOWNLOAD_ATTEMPTS` (3) attempts, each continuing `<dest>.part` with `-C -`, 2 s
  between. A 4xx other than 408/429 is not retried; `33` (the server cannot resume) deletes the part and
  starts that asset again from zero.
- **the refusal says why**, and carries no URL.
- **verification is unchanged and still the caller's gate**: signed `SHA256SUMS` first
  (`wa_node_verify_signature`), then the manifest's sha256, size and ELF machine (`wa_node_verify_dir`,
  node-binaries.sh). A resumed file that does not match is refused by name and the directory it is in is
  removed - there is no second, weaker check in the downloader.

## 3. The rows (scripts/test-node-download.sh, wired at scripts/test.sh:606)

All of them against `scripts/lib/http-stub.py` on 127.0.0.1 (the port is written to a file and read back;
the base URL is checked to be loopback), through the real functions - `wa_node_fetch_asset`,
`wa_node_binary_download` (signature + manifest + verify) and `wa_component_fetch_assets`. The fixture is
a signed release per commit (`scripts/lib/release-fixture-sign.py`, the TEST key in
`tests/fixtures/release-sign/keys.txt`); behaviour is chosen by sidecar files (`<asset>.drop`, `.stall`,
`.rate`, `.corrupt`), so one base URL serves every row and nothing about the row is expressed in the URL.

| row | what it asserts |
| --- | --- |
| a | 55 MB at 300 kB/s: rc 0, elapsed > 120 s (the row took 183 s of transfer), the file is 55000000 bytes and `.complete` exists (written only after every pin passed) |
| b | the connection dropped at 40% once: rc 0, the cache entry verifies, and the stub's request log shows a second request carrying a Range header |
| c | a 404: rc 8, `HTTP 404` in the line, `1 of 3 attempts`, exactly one request for that asset, and no `http://` in the line |
| d | a stall (`after=65536`): rc non-zero, `stalled`, `curl exit 28`, `2 of 2 attempts`, and the row lasted >= 30 s (`WA_DOWNLOAD_ATTEMPTS=2` bounds it to ~66 s) |
| e | a resumed body with one wrong byte: rc 5, `node_hash_mismatch: wa-<triple>-<sha12>` names the file, and no payload or `.part` is left anywhere in the cache |
| f | the 55 MB row's phase file: >= 3 distinct `downloading wa-x86_64-unknown-linux-gnu: N of 55 MB` lines, and no more than one per 3 s of elapsed transfer (elapsed/3 + 3 allowed) |
| - | a component bundle over the same transfer: rc 0 with all three files, and a bundle missing `graph.wasm` refuses `component_release_unreachable: graph.wasm: HTTP 404` with no URL |

Green: **36 checks**, three runs today (34 at 8652daf1 before the progress row, 36 at d20f960b, 36 after
34d3d43e). ~270 s per run, because row a is a real 183 s transfer.

The store rule: the test creates `$WORK/home` and refuses it with `wa_scratch_home_guard`
(`scripts/lib/scratch-home.sh`) when it is the operator home - measured: the first version put `$WORK`
under `TMPDIR`, which on this node is `~/.wasm-agent/tmp`, and the guard refused it
(`refused(real_node_home)`), so the scratch tree is `/tmp`. The phase file it reads is written by the
product's own `wa_status` after `wa_status_begin`, the same call `scripts/deploy.sh:414` makes.

## 4. Discrimination (what the tests catch)

`bash scripts/test-discriminates.sh 345e51be --timeout 600` on this branch:

```
skipped            scripts/test-component-pins.sh   (this scratch environment has no pinned agent-core bytes)
environment        scripts/test-icons.lua            (this tree has no wa binary, so a Lua row cannot run)
unchanged-verdict  scripts/test-land-signing.sh      (still passes; not evidence, does not block)
discriminates      scripts/test-node-binaries.sh     (PRE-EXISTING red - see section 7, not this change)
discriminates      scripts/test-node-download.sh     (base has no stub server and no downloader: it fails a check)
rows: discriminates=2 environment=1 skipped=1 unchanged-verdict=1
2 discriminating, 0 blocking
```

The row that speaks for the downloader is `test-node-download.sh`, but its base verdict comes from a
check that fails early (the base has neither the fixture nor the lib). The direct evidence is the probe in
section 1: the base's own `wa_node_fetch_asset` on the same stub prints a URL and nothing else for a 404,
and refuses a 183 s transfer at exactly 120 s; rows c, d and a of the test assert the opposite about the
new code. The other `discriminates` row is a pre-existing failure of the base, not this change.

## 5. Call sites

**Fixed - every release asset of the node channel goes through `wa_download_asset`:**

| call site | asset |
| --- | --- |
| `scripts/lib/node-binaries.sh:585` | `SHA256SUMS` |
| `scripts/lib/node-binaries.sh:590` | `SHA256SUMS.sig` |
| `scripts/lib/node-binaries.sh:598` | `TRUSTED-KEYS`, `TRUSTED-KEYS.sig` |
| `scripts/lib/node-binaries.sh:720` | `node-<sha12>.manifest` (exact/release path) |
| `scripts/lib/node-binaries.sh:742` | `wa-<triple>-<sha12>`, `wa-sentinel-<triple>-<sha12>` |
| `scripts/lib/node-binaries.sh:854` | `node-<sha12>.manifest` (digest fallback) |
| `scripts/lib/node-binaries.sh:887` | the two binaries (digest fallback) |
| `scripts/lib/deploy-components.sh:284, 311` | the component bundle (`<name>.wasm`, `<name>.json`, `components.lock`) |
| `lua/core/icons.lua:330` | the icon font (same rules, as a shell one-liner: bounded connect, stall window, `-C -`, `--retry`, no cap) |

All seven node-binaries call sites were already funnelled through `wa_node_fetch_asset`, which is why the
fix is one function plus its two callers.

**Left, with the reason:**

| call site | why not here |
| --- | --- |
| `scripts/install.sh:211`, `scripts/linux/bootstrap.sh:180`, `scripts/provision-publish-toolchain.sh:176` | the FIRST fetch on a machine that has no node yet (`curl -fsSL ... \| sh` path). They already bound only the connect and retry; they have no release tag, no manifest and no phase file, and a machine that cannot download the installer at all cannot run this lib. |
| `scripts/fleet-install.sh:250` | already `--retry 4 --retry-all-errors --connect-timeout 20`, with its own `DOWNLOAD_TIMEOUT` knob. |
| `scripts/termux/release-lib.sh:835` | the Android/Termux fetcher keeps a `--max-time` on purpose (a phone on a metered link should stop); it has its own bound and is not the node-release path. |
| `scripts/web/install.sh:43` | the browser-facing install snippet: a few small files over the public base, no tag, no verification of its own. |
| `lua/core/land.lua:3507` | not an asset: one API read with a 20 s cap, where a cap is the right bound. |
| `scripts/lib/node-binaries.sh:474` | the release LIST (`api.github.com/repos/<repo>/releases`), whose budget is `WA_NODE_RELEASE_LIST_SECONDS` and is a different question (how long a search may take), not a body transfer. |

## 6. Why the stub server lives in scripts/lib

`scripts/test-discriminates.sh` treats every changed path under `tests/` whose extension a runner can
execute as a TEST, and gives it a row. A fixture run with no arguments fails with no marker and the gate
reports it `unclassified`, which BLOCKS a landing - over a fact about the harness. `scripts/lib/`
already holds the same kind of file (`release-fixture-sign.py`), and the stub's own docstring says what it
is and why it is there (commit 34d3d43e).

## 7. Not verified here, and pre-existing failures

- **`scripts/test-icons.lua` was not run**: a Lua row needs this tree's built `wa` binary, and this
  mission builds no Rust. Its three new assertions were checked by executing the real module under
  `lua 5.4`: `icons.fetch_line("node-0123456789ab", {fonts=true})` prints
  `curl -fsSL --connect-timeout 15 --speed-limit 51200 --speed-time 30 --retry 3 --retry-delay 2 -C -
  https://github.com/Magaav/wasm-agent/releases/download/node-0123456789ab/waIcons-Regular.ttf -o
  ~/.local/share/fonts/waIcons-Regular.ttf && fc-cache -f ~/.local/share/fonts`, in which
  `--connect-timeout`, `--speed-time`, `--speed-limit` are present and `--max-time` and ` -m ` are not.
- **`scripts/update_follow.lua` was not changed.** The progress line is written into the phase file it
  already reads; the follower therefore prints it inside its existing `building <n>/<total>` sentence
  when a build counter exists. Changing the follower's rendering would need a Lua row and a built binary
  (above), so it is left as a named follow-up rather than an unverified change.
- **Pre-existing red, measured on origin/main 39e862d6 in a separate worktree** (`/tmp/base-dsw`), and
  identical on this branch:
  - `scripts/test-deploy-node-binaries.sh`: `the record step for a prebuilt install: expected status 0,
    got 3`;
  - `scripts/test-node-binaries.sh`: `the main refusal is named: 'not_on_main:' not in: ...
    scripts/lib/build-target.sh: No such file or directory` (the fixture does not copy
    `build-target.sh`).
- Green here, for the record: `scripts/test-deploy-components.sh` (74 checks) and
  `scripts/test-component-pins.sh` (11 of 11 pinned components verified, all 8 ops answered) - both
  exercise the component lib I changed.

## 8. Texts to approve (new or changed, verbatim)

Refusals of the transfer (`scripts/lib/download-asset.sh`):

```
node_release_unreachable: <label>: <HTTP status>|<no HTTP status>, <got> of <want> bytes|<got> bytes received in <s>s, <n> of <m> attempts: curl exit <rc> (<meaning>)
node_release_unreachable: <label>: no curl on this host, so nothing can be fetched
```

curl's exit codes in words (`wa_download_curl_reason`):

```
1 unsupported protocol / 2 curl failed to initialise / 3 the URL is malformed / 5 the proxy could not be resolved /
6 the host could not be resolved (DNS) / 7 the connection was refused or the host did not answer /
9 this account is not allowed to read that URL / 16 the HTTP/2 layer failed /
18 the connection was dropped before the whole body arrived / 22 the server answered with an HTTP error code /
23 the body could not be written to disk / 26 the file could not be read / 27 out of memory /
28 the transfer timed out or ran too slow for too long / 33 the server cannot resume this file at the offset asked /
35 the TLS handshake failed / 36 the download could not be resumed / 47 too many redirects /
52 the server sent an empty reply / 55 the request could not be sent / 56 the connection failed while receiving /
60 the TLS certificate is not trusted / 61 the TLS certificate could not be checked /
63 the body was larger than allowed / 92 the HTTP/2 stream failed /
and: curl reported failure (an exit code this lib does not name)
```

A stalled transfer replaces that meaning with:

```
the transfer stalled: under <speed_limit> bytes/s for <speed_time>s (a stall, not a slow line)
```

Progress, into the phase file the follower reads:

```
downloading <label>: <N> of <M> MB
downloading <label>: <N> MB
```

Node path (`scripts/lib/node-binaries.sh`):

```
node_download_lib_missing: scripts/lib/download-asset.sh is not beside this tree, so <asset> cannot be fetched
node_release_gh_failed: gh could not download <tag>/<asset> (exit <rc>: <gh's last line>); trying the public asset URL
node_release_unreachable: <tag>/<asset>: no curl and no gh on this host, so nothing can be fetched
```

Component path (`scripts/lib/deploy-components.sh`):

```
component_release_unreachable: <the transfer's own reason, without the node_ prefix>
component_download_lib_missing: scripts/lib/download-asset.sh is not beside this tree, so the <name> bundle cannot be fetched
component_release_gh_failed: gh could not download <tag> from <repo> (exit <rc>: <gh's last line>); trying the public asset URL
component_release_unreachable: <name>: no curl and no gh on this host, so nothing can be fetched
```

The font line a person is shown (`lua/core/icons.lua`):

```
curl -fsSL --connect-timeout 15 --speed-limit 51200 --speed-time 30 --retry 3 --retry-delay 2 -C - https://github.com/<repo>/releases/download/<tag>/waIcons-Regular.ttf -o ~/.local/share/fonts/waIcons-Regular.ttf && fc-cache -f ~/.local/share/fonts
```

## 9. How to reproduce

```
bash scripts/test-node-download.sh          # 36 checks, ~270 s, no network, no fleet
bash scripts/test-discriminates.sh 345e51be --timeout 600
```

The stub server can be driven by hand: `python3 scripts/lib/http-stub.py <root> <port-file>`, then
`GET /<path>` for whatever file the root holds, with `<path>.rate`, `<path>.drop`, `<path>.stall`,
`<path>.corrupt` deciding how it is served.
