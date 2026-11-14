# WhatsApp operator route — RETIRED 14/11

`whatsapp_operator` is gone. It was a SECOND WhatsApp send path: `prepare -> approve -> send ->
status` over an installed operator profile (`<config>/wa-whatsapp/operator-management-<profile>.json`
with separately provisioned approval/dispatch token FILES), reachable from a master as
`peer_<node>__whatsapp_operator`, carried by a Lua state machine (`lua/core/whatsapp_operator.lua`,
`WA_WHATSAPP_OPERATOR_BACKEND=native`) and a Node client (`scripts/whatsapp-operator.mjs`) that posted
to the Go connector's `/operator/*` HTTP API.

It duplicated the one surface, so it was retired:

* **The one surface is `mcp_whatsapp_send`** (`lua/core/whatsapp.lua`), answered by the node that holds
  the account, on every node - see [MCP.md](MCP.md) ("WhatsApp first").
* **The gate is `/approve`** - [APPROVE.md](APPROVE.md). With it on, an outgoing message waits as a
  draft the operator sends, edits or rejects by hand (`wa approve list|send|edit|reject`, `/approve` in
  `wa chat`); a draft the operator rejects is never sent.

What the old name answers now, on every route (a local call, a script, or a peer spelling):

```
{ ok = false, error = "whatsapp_tool_retired", use = "mcp_whatsapp_send", effect = "none",
  note = "retired: use mcp_whatsapp_send; turn on /approve to review drafts first" }
```

There is no alias and no backend behind it: `whatsapp.retired_name` (`lua/core/whatsapp.lua`) is the
one definition, and the dispatcher, the federation export, `federation.resolve` and `/mcp` all read it
through `whatsapp.surface`, so the name cannot come back through another door.
`scripts/test-whatsapp-one-surface.lua` fails if it - or any other retired WhatsApp spelling - appears
in any peer's export again.

## What it left on disk (reported, not deleted)

Retiring the route did not touch any state an older build kept. None of it is read by this build, and
nothing in it is deleted automatically:

* `<config>/wa-whatsapp/operator-management-<profile>.json` - the authority configs. They name token
  FILES and a chat scope; they grant nothing now. Move or delete them by hand if you want them gone.
* `<config>/wa-whatsapp/requests/*.json` - request files a federated call wrote before it ran.
* the `whatsapp_operator_intents` table in the node's database - written only by the retired native
  backend on a node that had `WA_WHATSAPP_OPERATOR_BACKEND=native`. A prepared intent in it is data,
  not a queued send: no worker reads it, and no job id is pending for it.

They ARE **not** drafts: the approve queue is the account node's own outbox (`lua/core/approve.lua`),
and an old intent was never migrated into it, because the two do not share a state machine and a
migrated intent could be sent by a build that never bound its approval digest. An intent that was
prepared but never sent is, and stays, unsent.

## The one thing that used the client besides the tool

`scripts/whatsapp-transcript-watchdog.mjs` delivered its alert through the operator client, which is
the Go connector's API - removed 11/11. Its detection is unchanged and still runs; its delivery is
reported in the job's own evidence instead of a second send path (see the header of that file).
