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
