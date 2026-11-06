# WASI components — installable plugins outside the core build

A **component** is a `wasm32-wasip2` program the host runs inside wasmtime with exactly the
capabilities it is granted. It is installed as files, not compiled into `wa`, so:

- adding or changing a component never rebuilds or redeploys the core;
- the same `.wasm` runs on every node (Linux, Windows, arm64, x86_64): one artifact, omni-device;
- a bug or crash stays inside its sandbox (memory cap, deadline, no ambient authority).

The first use is **MCP servers**: a component speaking MCP over stdio is a registry transport like
`stdio` and `http`, so its tools get the same approval, schemas, dispatch and **code mode** routing
as every other connector (`mcp_*` names are connector tools, callable inside scripts).

## Install layout

`WA_COMPONENTS_DIR` (default `~/.wasm-agent/components`):

| file | role |
| --- | --- |
| `<name>.wasm` | the component (`wasi:cli/run`) |
| `<name>.wasm.sha256` | its pin. **Required**: an unpinned or mismatched component is refused by name |
| `<name>.json` | its manifest: name, kind, description, declared `capabilities` |

`bash scripts/build-components.sh [name...]` builds `rust/components/*` for `wasm32-wasip2` and
installs all three atomically (pin last). `host.components()` lists what is installed and whether
each pin verifies.

## Distributing components: build once, install everywhere

Wasm is portable: the same `.wasm` runs on Linux, Windows, x86_64 and arm64. A component with C
inside (the graph: tree-sitter + SQLite) needs wasi-sdk, and a build is **not** byte-reproducible
across checkout paths (three panic-location paths are embedded - measured 05/11: two checkouts of the
same tree gave 8,185,719 and 8,185,720 bytes). So the build happens once, and every other node installs
the pinned bytes instead of rebuilding them - including openclaw (arm64) and the laptop sandbox, which
have no wasi-sdk at all. A deploy on such a node is one command, with no manual step.

**Build machine** (the one with wasi-sdk):

```
WASI_SDK=<dir> bash scripts/publish-components.sh      # build, verify, bundle, print the gh command
```

It builds from the names `components.lock` pins, verifies each artifact's sha256 (and size) against
its pin - refusing a bundle whose bytes are not the pinned ones, printing the `components.lock` line
that would pin what it measured - and assembles the bundle directory (`graph.wasm`, `graph.json`, and
the `components.lock` the bundle satisfies; `build/components-release` by default). It never publishes
anything: it prints the exact `gh release create` command, so publishing stays a reviewed action.

**Release identity is the lock.** The tag is `components-<first 12 hex of sha256(components.lock)>`.
A node therefore names the exact bundle its pins describe using nothing but its own lock, and a tree
whose lock changed asks for a different tag - it can never install a release from another lock.

**A node** (scripts/deploy.sh stage 3e) resolves the bytes in this order, and every candidate is
verified against `components.lock` (sha256 **and** size) before it is used:

1. the component directory the core reads, when it already holds the pinned bytes (repeat deploy);
2. this node's cache, `<install>/components-cache/<lock sha256>` (a previous deploy's download);
3. the release: `gh release download components-<short> -R <owner/repo>` when `gh` is available, else
   `curl -L` of `https://github.com/<owner/repo>/releases/download/components-<short>/<asset>`.
   What lands is verified first and cached under the lock's sha (the `.complete` marker is written
   last), so a repeated deploy does not refetch and an interrupted fetch leaves nothing usable;
4. nothing reachable: this tree builds the component, which needs wasi-sdk, and the deploy must say
   `WA_DEPLOY_COMPONENT_REPIN=1` (a local build is not the pinned build).

| knob | effect |
| --- | --- |
| `WA_DEPLOY_COMPONENT_SOURCE=<dir>` | use these artifacts (built elsewhere) instead of resolving |
| `WA_DEPLOY_COMPONENT_REPIN=1` | accept a local build whose bytes are not the pinned ones (development) |
| `WA_COMPONENT_RELEASE_REPO=<owner/repo>` | read the release from another repository (fork, mirror); default: origin's GitHub slug, else `Magaav/wasm-agent` |
| `WA_COMPONENT_RELEASE_URL=<dir>` / `file://<dir>` | read the bundle from a directory instead of the network (a hand-copied bundle; what the test uses) |
| `WA_COMPONENT_RELEASE_URL=https://...` | base URL of the assets instead of GitHub's |
| `WA_COMPONENTS_CACHE=<dir>` | cache location; default `<install>/components-cache` |
| `WA_DEPLOY_COMPONENTS_DRY_RUN=1` | resolve, fetch and prove everything, install nothing |

A refusal is never a fallback: `component_hash_mismatch`, `component_size_mismatch` and
`component_release_lock_mismatch` mean the bytes that claim to be pinned are not, and the deploy stops
with nothing installed. Only `component_release_unavailable` (nothing cached, nothing reachable) falls
through to the local-build path.

`bash scripts/test-deploy-components.sh` proves this with no network, no wasi-sdk and no node: the pin
and size checks, the install/rollback, and the distribution paths with a local artifact directory and
a local release bundle (dry run, cache hit, `file://`, a tampered bundle, a foreign lock, an
unreachable release, and the publish script's verification).

### The node binary itself

A component is portable; `wa` is not. So the same idea needs one row per target triple and a release
per commit, because a deploy installs *the commit it holds* - "the latest binary" is another commit's
build and is refused.

```
release tag   node-<first 12 hex of the source commit>
pins          node-<sha12>.manifest
                schema=wasm-agent-node-binaries/1, source_commit=<40 hex>, source_tree=, rustc_version=,
                zig_version=, glibc_floor=2.31, codemode=embedded|empty, built_utc=
                <triple> <wa sha256> <wa bytes> <wa-sentinel sha256> <wa-sentinel bytes>
payload       wa-<triple>-<sha12>, wa-sentinel-<triple>-<sha12>
```

**Why.** `deploy.sh` ends in `cargo build` of `wa` and `wa-sentinel`. That is fine on a 16-thread
machine with a warm cache. openclaw (Ubuntu arm64, 2 cores, disk 99% full) needed the wasmtime 50
upgrade, which is a full rebuild of ~600 crates it can neither fit nor afford - so it installs the
bytes a machine with the toolchain built, and its deploy runs the same prove/install/rollback gate.

**Build machine** (any host with cargo; a Linux binary from Windows or macOS is a cross build):

```
pip install ziglang                      # or unpack a zig tarball; zig is the C compiler and the linker
cargo install cargo-zigbuild
bash scripts/publish-node-binaries.sh    # build both Linux targets, verify, print the gh command
bash scripts/publish-node-binaries.sh --from <dir>   # verify artifacts a CI built, pin them
bash scripts/publish-node-binaries.sh --check        # the plan; build nothing
```

The build is `cargo zigbuild --release --offline --locked -p wa-host --target
<triple>.2.31` (and the same for `wa-sentinel`). `.2.31` is zig's glibc floor: it links against no
symbol newer than glibc 2.31, so the binary runs on Ubuntu 20.04 and everything newer - and the script
reads the floor back out of the bytes (`GLIBC_2.x` symbol versions) and refuses a binary that needs
more than the manifest claims. Every member is verified before anything is printed for upload: sha256,
size, ELF machine (`b7` aarch64, `3e` x86_64). The candidate is executed when the host can run it
(natively, or through `--runner 'wsl -d Ubuntu --'`); when it cannot, the line says `run: SKIPPED`, and
the deploy proves the binary on the node before installing it.

Measured on wasm_the_first (Windows x86_64, 16 threads, rustc 1.98.1, zig 0.17.1, cargo-zigbuild
0.24.1), from a warm cargo cache of the crates and no cross artifacts:

| target | wa | wa-sentinel | built in | executable here |
| --- | --- | --- | --- | --- |
| `aarch64-unknown-linux-gnu.2.31` | 28,676,528 B | 5,292,696 B | ~7 min | no (no qemu/binfmt) -> SKIPPED |
| `x86_64-unknown-linux-gnu.2.31` | 33,895,504 B | 5,853,008 B | 4m44s (`CARGO_BUILD_JOBS=6`) | yes, through WSL Ubuntu 22.04 |

Both link with `GLIBC_2.30` as their newest symbol version (floor 2.31 accepted, openclaw's 2.35 fine).
`ring`, bundled SQLite, `zstd` and the vendored Lua all compile through `zig cc`; nothing needed a
patch. Two things are Windows-specific and measured: at the default 16 jobs cc-rs dies with
`Not enough quota is available to process this command. (os error 1816)` (desktop heap, not disk), so
the script caps `CARGO_BUILD_JOBS=6` on a Windows host; and `strip --strip-all` removed 16 bytes, so
the binaries are what they are (a release profile keeps no symbols worth stripping).

**A cross build does not embed the code-mode assets by default** - `rust/wa-host/build.rs` exempts a
cross build from the `WA_CODEMODE_BUILD_ASSETS` rule, because a cross build is not the *build host's*
artifact. It is the node's, though, and a node without them starts every run with
`codemode_not_ready`. So `publish-node-binaries.sh` sets `WA_CODEMODE_BUILD_ASSETS` itself when the
prepared, pinned assets are present, records `codemode=embedded` in the manifest, and refuses by name
when they are not (`--allow-empty-codemode` is the deliberate development escape). The deploy refuses a
manifest that records `codemode=empty` unless the operator says `WA_DEPLOY_ALLOW_EMPTY_CODEMODE=1`.

**A node** (`scripts/lib/node-binaries.sh`, `deploy.sh` step 3d) resolves the bytes in this order, and
every candidate is verified against the manifest (sha256 **and** size, plus the ELF machine):

1. `WA_DEPLOY_BINARY_SOURCE=<dir>` when an operator says so (`wa`, `wa-sentinel`, and a
   `node-<sha12>.manifest` if one is there - when it is, its pins are enforced);
2. this node's cache, `<install>/node-binaries/<sha12>/<triple>` (a previous deploy's download; the
   `.complete` marker is written last, so an interrupted fetch leaves nothing usable);
3. the release: `gh release download node-<sha12> -R <owner/repo>` when `gh` is present, else the
   public asset URL. The manifest is fetched first, because it is the release's identity.

| knob | effect |
| --- | --- |
| `WA_DEPLOY_BINARY_SOURCE=<dir>` | install binaries another machine built (the supported path for a node with no toolchain at all) |
| `WA_DEPLOY_BUILD_ONLY=1` | build this tree, never install a published binary |
| `WA_DEPLOY_ALLOW_EMPTY_CODEMODE=1` | accept a published binary whose manifest records `codemode=empty` |
| `WA_NODE_RELEASE_REPO=<owner/repo>` | read the release from another repository; default: origin's GitHub slug, else `Magaav/wasm-agent` |
| `WA_NODE_BINARIES_URL=<dir>` / `file://<dir>` / `https://...` | read the assets from there instead of GitHub (a hand-copied release; what the tests use) |
| `WA_NODE_BINARIES_CACHE=<dir>` | cache location; default `<install>/node-binaries` |
| `WA_NODE_TARGET=<triple>` | name the triple instead of detecting it |
| `WA_NODE_DISK_FLOOR_BYTES=<n>` | the floor the fallback-to-build is measured against |

A refusal is never a fallback. `node_hash_mismatch`, `node_size_mismatch`, `node_machine_mismatch`,
`node_manifest_commit_mismatch`, `node_binary_missing` (a manifest that pins a target the release does
not carry) and `node_codemode_empty` stop the deploy. Only "nothing is published for this commit and
this target" (`node_release_unavailable`, `node_target_unpublished`) falls through to the build - and
only when the disk can pay for one: below the floor the deploy refuses with
`refused(no_prebuilt_binary_and_disk_floor)` and names both paths (`scripts/check-disk-floor.sh`).

What the deploy still does with a published binary: it stages the Lua tree against it, checks its
capability digest, proves a graph call through the staged component, proves the embedded runtime, and
answers `/health` on a scratch port - then `upgrade.sh` installs it and rolls back if the restart fails.
`installed.txt` keeps `source_provenance=clean-built-by-deploy` (the bytes are a clean build of exactly
this commit and this deploy verified them) and adds `binary_source=prebuilt-release|
prebuilt-source`, `binary_release=node-<sha12>` and `binary_commit=<40 hex>`, so "where did this node's
binary come from" is a record and not a guess. Its `commit=` is the release's **40-hex** commit id (the
id the manifest's `source_commit` was checked against), not the short id a build records.

The supervisor is part of the same install, and a prebuilt deploy installs the prebuilt one. The release
carries `wa-sentinel-<triple>-<sha12>` beside `wa-<triple>-<sha12>`; the sentinel install step takes it
from the verified directory `wa_node_binaries_prepare` names (its `binary_verified:` line), re-reads the
manifest's pinned sha256 for that sentinel at that moment, and installs nothing when the file is not
those bytes (`refused(prebuilt_sentinel_mismatch)`, and `refused(prebuilt_sentinel_missing)` when the
directory holds no supervisor). Two reasons this is not read from the staging directory the fetch wrote:
`deploy.sh` removes that staging directory as soon as the proved node has been copied to its hash-named
candidate, and the cache-hit path only re-checks the *node's* sha256 (`.complete`) - a cached supervisor
can be swapped under a deploy that would otherwise install it. The build path is unchanged: with no
prebuilt step, the step installs `rust/wa-sentinel/target/release/wa-sentinel` exactly as before.
`scripts/lib/node-binaries.sh` is shipped beside the installed `deploy.sh` (as the component lib already
is), because `request deploy` runs that installed copy: without it the copy notes "no node-binaries
helper" and builds, which is the one thing the node this path exists for cannot do.

`bash scripts/test-deploy-node-binaries.sh` and `bash scripts/test-node-binaries.sh` prove both halves
with no network, no cargo, no zig, no node and no `gh` (a shim records any call): the plan, the cache,
the cache hit with the release gone, every refusal, the disk-conditioned fallback, the publisher's
`--check`/`--from` and every way a manifest can be wrong, the order of the calls inside `deploy.sh` (a
prebuilt install must never reach the toolchain check or the build), and two blocks read out of
`deploy.sh` by their own markers and executed against fixtures: the prebuilt branch (which resolves the
bytes and hands the sentinel step the verified supervisor) and the sentinel install step itself
(prebuilt supervisor installed with the staging directory already removed, the build path's own artifact
installed unchanged, the unpinned operator directory, a swapped cached supervisor refused by name) -
plus the install record step for a prebuilt install. So a change there cannot pass by never running.


**Does this node run a newer release?** `lua/core/update_banner.lua` answers with the same release
identity the deploy installs: `installed.txt`'s `commit=` (and `binary_release=` for a prebuilt
install) against the newest `node-<sha12>` release, then shows
`Update available (<sha12>): run wa update or /update` in the CLI footer, once at session start, and
as a dismissible toast plus a topbar badge in the window. It is not the deploy and it changes nothing:
no fetch, no merge, one cached feed read per fifteen minutes in `<state>/update-check.json`, and the
verdict is recomputed from the current install record so the indicator disappears after the swap
without waiting for a request. `git` is consulted only for local ancestry (`merge-base
--is-ancestor`), which is what tells a tree ahead of the feed (no banner) from one behind a published
release (banner). Details and knobs: `docs/RELEASE-UPDATE.md`.

## Capabilities: declared by the manifest, granted by the caller

Nothing is ambient: no filesystem, no network, no inherited environment. The manifest **declares**
what the component may ever need; the registry definition **grants** a subset; the host refuses a
grant the manifest did not declare (`component_capability_not_declared:<field>:<key>`) before the
component is instantiated.

| capability | grant shape | what the component sees |
| --- | --- | --- |
| `env` | `{KEY: "HOST_ENV_NAME"}` | `KEY` = value of the host variable (a reference, never a literal) |
| `file_env` | `{KEY: "HOST_ENV_NAME"}` or `{KEY: "/abs/path"}` | the **host** reads that file (named by a host variable, or directly: a path is a location, not a secret) and the component sees its trimmed contents as `KEY`. Secrets stay file references; the component has no filesystem |
| `net` | `["127.0.0.1:28787"]` | TCP connect to exactly these socket addresses. A manifest may declare `host:*` (any port on that host) |
| `config` | `{...}` (registry `config`) | non-secret JSON in `WA_COMPONENT_CONFIG`. Data, not a capability |
| `dirs` | `[{"host":"/abs","guest":"/graph/root","write":false}]` | the host directory preopened at the guest path, read-only unless `write`. The manifest declares the guest paths (`"dirs":["/graph/root"]`); the caller chooses the host directories. Used by the kernel for the `graph` component (root read-only, a private database directory writable) |

Limits per run: 256 MiB memory, stdin ≤ 4 MiB, stdout ≤ 16 MiB, stderr tail 64 KiB, deadline =
the definition's `timeout_seconds` (epoch interruption, ≤ 600 s). A run that hits the deadline after
a `tools/call` was sent reports `outcome: unknown`, never ok.

## MCP over a component

Registry definition (`mcp` tool, `put`):

```json
{"id":"whatsapp","name":"WhatsApp","transport":"component","component":"mcp-whatsapp",
 "env":{"WA_MCP_WHATSAPP_ACCOUNT":"WA_WHATSAPP_ACCOUNT","WA_MCP_WHATSAPP_GENERATION":"WA_WHATSAPP_GENERATION","WA_MCP_WHATSAPP_URL":"WA_WHATSAPP_CONNECTOR_URL"},
 "file_env":{"WA_MCP_WHATSAPP_TOKEN":"WA_WHATSAPP_TOKEN_FILE"},
 "net":["127.0.0.1:28787"],
 "config":{"allowed_conversations":["<exact chat id>"]},
 "timeout_seconds":60,"tools":{"read_newest":"read","read_snapshot":"read","list_chats":"read","lookup_self":"read","inspect_chat":"read"}}
```

Then `probe` → `enable`, exactly as for a stdio server. Per request the host runs the component
once with `initialize`, `notifications/initialized`, `tools/list` and (for a call) `tools/call` on
stdin, parses the JSON-RPC answers with serde (schemas stay byte-exact: `{}` is never `[]`), and
returns the same answer shape as `scripts/mcp-client-core.mjs`.

**Schema hash = the component's pinned sha256.** The same bytes answer with the same tools, so a
changed component is refused before anything is sent (`mcp_tool_schemas_changed`) and must be
probed and enabled again: an upgrade is an explicit approval, as for any MCP server.

## Add a component

1. `rust/components/<name>/` with its own `Cargo.toml` (`[workspace]` empty: never a member of the
   core workspace), `manifest.json`, `src/main.rs` reading stdin / writing stdout.
2. `bash scripts/build-components.sh <name>` — builds and installs it.
3. `bash scripts/publish-components.sh` on the build machine, then run the `gh release create` line it
   prints — that is what lets a node without wasi-sdk deploy it.
4. Register it (`mcp put` with `transport:"component"`), `probe`, `enable`.

Rust's std works on `wasm32-wasip2`, including `std::net::TcpStream` for granted addresses.
Other languages work if they emit a WASI preview 2 command component.

## Test a component without a node

`rust/wa-fake-kernel` serves `wa:kernel@0.2` in memory, so a service component's tests run under
`cargo test` against the real `.wasm`: the same runner the node uses, with kv, http, websocket,
speech, secrets, log and health scripted. An exchange no rule names is refused by name (never an
empty 200), an ungranted capability is refused as the node refuses it, and a secret's value never
enters a record. `kernel.record()` / `kernel.save_replay()` / `kernel.replay_from()` are the
`wa-bounded` record/replay hooks, and `wa dev <component-dir>` runs the edit-build-hot-swap loop
(new instance healthy, then the old one stops). Design, the refusal rules and the timings are in
[SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md), "Iterating on a component".

## Components so far

| component | what | notes |
| --- | --- | --- |
| `mcp-whatsapp` | WhatsApp linked-device read tools (port of `scripts/mcp-whatsapp.mjs`) | loopback connector only (no TLS inside); send stays on the operator route; `scripts/test-component-whatsapp-parity.mjs` proves identical answers to the Node server |
| `mcp-echo` | test fixture | proves grants, sandbox, deadline (`scripts/test-mcp-component.lua`) |

## Next: service components

MCP components are one request per run. The WhatsApp connector itself (`connectors/whatsapp`) needs
a **long-lived** component: a persistent socket, scoped storage, timers, and a host-provided
speech-to-text capability (native faster-whisper stays outside wasm: the Candle-in-wasm `small`
model measured ~17x slower, `benchmarks/whisper-wasm`). That is the next host class on this same
manifest/grant model; it is not built yet. Design and the feasibility spike (whatsmeow compiles to
wasip1; a guest reached WhatsApp's websocket through host TCP): [SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md).
