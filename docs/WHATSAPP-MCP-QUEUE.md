# The WhatsApp MCP on the Rust stack (measured 2026-11-10, updated 11/11)

One MCP connector is left on openclaw, and it is an **HTTP client of the loopback connector
API**, not of the `wa-whatsapp` component. The stdio Node bridge (`scripts/mcp-whatsapp.mjs`,
id `whatsapp`) was deleted on 10/11/2026 and its disabled registry entry removed with it:

| connector | transport | talks to |
| --- | --- | --- |
| `whatsapp` | ~~`stdio`, `scripts/mcp-whatsapp.mjs`~~ | **deleted 10/11** |
| `whatsapp_wasm` | `component`, `mcp-whatsapp` (WASI) | `connector_url` + `/method`, Bearer token |

`connector_url` is `http://127.0.0.1:28787`, and **nothing in this tree serves that API any more.**
It was the Go connector's (`wa-whatsapp serve --listen 127.0.0.1:28787`, measured 10/11/2026, pid
3848966, release `4777c387…-linux-arm64`); that program was retired on 11/11 and its tree removed in
Phase 4, so the endpoint is now answered by nobody. Expect
`connector_transport_failed` (the `.mjs`, gone) or `connector_response_failed`/a transport error (the
component) from every MCP tool call until the queue port below lands. The component was never a client
of that API and never will be: `mcp-whatsapp` is kept because it is the Rust component's own MCP
surface, not because its upstream still exists.

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
`transport: component`. The `.mjs` door was deleted on 10/11/2026, so the component is the
only MCP surface onto WhatsApp; it still answers over the connector API until that port lands.

Until then: MCP tools are exposed and routed correctly but answer a transport error; the
native WhatsApp tools are the working door from code mode on any master.
