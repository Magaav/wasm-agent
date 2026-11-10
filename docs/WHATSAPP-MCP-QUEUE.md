# The WhatsApp MCP on the Rust stack (measured 2026-11-10)

Two MCP connectors exist on openclaw and both are **HTTP clients of the loopback connector
API**, not of the `wa-whatsapp` component:

| connector | transport | talks to |
| --- | --- | --- |
| `whatsapp` | `stdio`, `scripts/mcp-whatsapp.mjs` | `connector_url` + `/method`, Bearer token |
| `whatsapp_wasm` | `component`, `mcp-whatsapp` (WASI) | the same `connector_url`, same token |

`connector_url` is `http://127.0.0.1:28787`. Measured: **nothing listens on that port on
openclaw**, and the only listener on this fleet is the Windows forward tunnel
(`ssh -L 28787:127.0.0.1:28787 openclaw.ohana`), which forwards *to* openclaw. So every call
answers `connector_transport_failed` (the `.mjs`) or `connector_response_failed` (the
component, once a reverse tunnel created a loop). The API itself is the Go connector
(`connectors/whatsapp`), which is not running anywhere in this fleet.

The `wa-whatsapp` component (whatsapp-rust) does **not** serve that API. It answers the
`whatsapp.query` queue, and that is the path the native capabilities use
(`whatsapp_search/read/reactions/media`), which works today from any master through
federation (`peer_<node>__whatsapp_search`, verified with real messages).

## What "MCP on the Rust stack" requires

The MCP tool set and the queue seam do not line up yet:

| MCP tool | seam op today |
| --- | --- |
| `read_snapshot` | `search` / `read` |
| `read_newest` | `read` (limit) |
| `inspect_chat` | `read` |
| `read_field` | `search` + field chunking |
| `list_chats` | **missing** |
| `posting_status` | **missing** |
| `lookup_self` | **missing** (identity is in the component's config) |

So the port is: three seam operations in `wa-whatsapp-index` and the component
(`chats`, `posting`, `identity`), then `rust/components/mcp-whatsapp` rewritten to answer its
tools from the seam (queue) instead of TCP, and the `whatsapp_wasm` definition kept
`transport: component`. The `.mjs` connector stays as the legacy door until that lands.

Until then: MCP tools are exposed and routed correctly but answer a transport error; the
native WhatsApp tools are the working door from code mode on any master.
