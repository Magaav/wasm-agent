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

## Capabilities: declared by the manifest, granted by the caller

Nothing is ambient: no filesystem, no network, no inherited environment. The manifest **declares**
what the component may ever need; the registry definition **grants** a subset; the host refuses a
grant the manifest did not declare (`component_capability_not_declared:<field>:<key>`) before the
component is instantiated.

| capability | grant shape | what the component sees |
| --- | --- | --- |
| `env` | `{KEY: "HOST_ENV_NAME"}` | `KEY` = value of the host variable (a reference, never a literal) |
| `file_env` | `{KEY: "HOST_ENV_NAME"}` | the host variable names a file; the **host** reads it and the component sees its trimmed contents as `KEY`. Secrets stay file references; the component has no filesystem |
| `net` | `["127.0.0.1:28787"]` | TCP connect to exactly these socket addresses. A manifest may declare `host:*` (any port on that host) |
| `config` | `{...}` (registry `config`) | non-secret JSON in `WA_COMPONENT_CONFIG`. Data, not a capability |

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
3. Register it (`mcp put` with `transport:"component"`), `probe`, `enable`.

Rust's std works on `wasm32-wasip2`, including `std::net::TcpStream` for granted addresses.
Other languages work if they emit a WASI preview 2 command component.

## Components so far

| component | what | notes |
| --- | --- | --- |
| `mcp-whatsapp` | WhatsApp linked-device read tools (port of `scripts/mcp-whatsapp.mjs`) | loopback connector only (no TLS inside); send stays on the operator route |
| `mcp-echo` | test fixture | proves grants, sandbox, deadline (`scripts/test-mcp-component.lua`) |

## Next: service components

MCP components are one request per run. The WhatsApp connector itself (`connectors/whatsapp`) needs
a **long-lived** component: a persistent socket, scoped storage, timers, and a host-provided
speech-to-text capability (native faster-whisper stays outside wasm: the Candle-in-wasm `small`
model measured ~17x slower, `benchmarks/whisper-wasm`). That is the next host class on this same
manifest/grant model; it is not built yet.
