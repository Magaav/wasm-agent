# MCP extensions and Jobs

MCP connects app capabilities; Jobs owns automation. We adopt Pi's extension
pattern (explicit discovery/registration/lifecycle), not its packages, runtime or
auth. Reference: MCP 2025-11-25; negotiated versions also include 2025-06-18 and
2024-11-05. This is tools interoperability, not a claim of greater task speed.

## Transport and authority

`scripts/mcp-client-core.mjs` supports newline JSON-RPC stdio and Streamable HTTP
JSON/SSE replies: initialize → initialized → paginated tools/list → optional
single tools/call. HTTP uses negotiated session/version headers, HTTPS or explicit
loopback HTTP, refuses redirects and ends sessions (405 means DELETE unsupported).
No legacy HTTP+SSE, OAuth login, sampling, elicitation, prompts, autonomous tasks,
background event subscription or automatic tool replay. See
[the progressive envelope contract](PROGRESSIVE-ENVELOPE.md).

The native Lua manager uses existing supervised `host.operation` program/argv
execution. Approved reads reuse caller/session/credential-bound connections,
with an idle close and native operation deadline; initialization/list are not
repeated for each call. Catalogue-change notifications invalidate cached discovery;
silent unannounced changes require explicit re-probe. Generic writes, probes and
WhatsApp stay request-scoped with full-tree settlement. Persistent read replies
prove an exact retained call, not that their live session has settled. Unknown
submission/confirmation stays held durably and is never retried. Ordinary model
replies omit repeated catalogues while keeping exact protocol/effect evidence.

Bounds: 1 MiB request file; 32 MiB protocol exchange; 24 MiB stdio line; 32 tool
pages / 1,000 discovered tools; 128 KiB selected schema/description budget before
enabling; 80 MiB retained reply envelope. Crossing a bound fails visibly, never
silently truncates or advances a job cursor. Results retain exact JSON object,
array and null shapes via `result_json`; schemas use validated explicit raw JSON.
Images/resources remain raw evidence with unsupported-delivery labels, not visual
inspection or automatic URI loading. Retention is explicit, not a total disk quota.

Server code is **operator-trusted executable code, not an OS sandbox**. Probe runs
its startup/handshake but calls no app tool; protocol success does not prove a live
account/page. Server annotations/instructions grant no authority. Approved tool
descriptions are untrusted catalogue data. Credentials in env/header configuration
are variable references; never put secrets in command arguments or URLs. Header
credentials, recognizable credential env names and explicit `secret_env` tags
are redacted before results are stored/exposed. Metadata containing those values
refuses before a tool call. Nonstandard credential env keys must be tagged.

## Registry and Engine

`lua/core/mcp.lua` stores `mcp.extensions.v1` in SQLite meta. Updates use a single
native atomic expected-value CAS, not a Lua-spanning transaction on a shared DB.
`GET /mcp` reads inventory only. Master-only `POST /mcp` accepts list/put/probe/
enable/disable/remove; changes require `expected_revision` from the current inventory.
Removal refuses an enabled connector (disable it first) and leaves a revision bump, so a
stale editor cannot recreate or clobber another entry.
New/edited definitions and every successful or failed probe stay disabled until
explicit enabling. Failed probes are durable. Changed tool input schemas refuse
before dispatch and invalidate approval. No live PID/continuous health is invented.

A **call never reverses the operator's decision**. A refusal that says the
connector's catalogue changed (`mcp_tool_schemas_changed`, `mcp_catalogue_changing`)
is answered before dispatch - nothing is issued against a schema nobody approved - but
it no longer sets `enabled=false` or discards the cached probe: it records
`probe_stale` in the registry, the connector stays on with its approved tools in the
catalogue, and `/mcp` reports `stale - re-probe` instead of `disabled`. A passing
call, a probe and an enable each clear the note. Before 10/11 a call did disable the
connector and drop its probe, which is how a connector the operator had enabled came
back disabled after a deploy, with its tools gone from the catalogue
(`scripts/test-mcp-registry-state.lua`).

A read session reserves uncertainty in `meta` *before* submitting, so a read that may
have been issued is never replayed. The reservation is released by an answer: a
verified result, a refusal the server itself returned (`mcp_rpc_error:`), or a
submission that was never issued. A marker left behind by a process that died is
reconciled from the evidence on disk - the request written before submission and the
retained answer beside it - and only when that evidence is definite in the same sense;
a complete result whose sha256 the lost reply would have confirmed keeps the marker,
and a new call is issued only after the old reservation is released
(`lua/core/mcp_session.lua`, `scripts/test-mcp-session-settlement.lua`, and
`scripts/test-mcp-recovery.lua` for the no-replay line).

Definitions have id/name, transport, program/args or url, optional absolute cwd,
`env`/`headers` reference maps, optional `secret_env` target-env-key array,
`timeout_seconds`, and `tools` mapping exact names to locally approved read/write.
Namespaced tools are `mcp_<id>_<sanitized-name>_<hash8>`. Guests gain nothing;
children need exact approved names within the caller ceiling and an explicitly
operator-authorized profile. Generic writes and probes refuse required coding
workspaces because their filesystem scope cannot be proved. Existing narrow app
facades retain their own scope/effect rules.

Engine's MCP topic precedes Jobs. Reads coalesce per node/account, don't wait for
main/child inference, retain data and editor drafts on errors, and offer explicit
Refresh. Controls are single flight, revision fenced and never automatically
replayed. Stale/foreign reads cannot repaint a new scope or overwrite a mutation.
An uncertain control requires inspection and a new explicit decision.

## Federation: every master uses every peer's connectors

A connector belongs to the machine that holds it (a linked WhatsApp device, a mail credential file, a
loopback service), so a copied definition cannot run elsewhere. `lua/core/federation.lua` leaves each
connector where it is: a master lists each online peer's enabled connector tools (its MCP tools and, where
an operator profile is installed, `whatsapp_operator`) as `peer_<peer>__<tool>` and a call runs ON that peer through the signed node call, under
that peer's own guards - its write gates, approvals and refusals still decide. Nothing secret moves and no
node is configured by hand. The catalog refreshes when a node is bound (the binding tick that reaches
`accepted`), when a peer is promoted to master, and when it is older than ten minutes; listing tools reads
the cache and never waits on the network. A peer on an older build (no `federation` capability) is kept in
the catalog with its reason and no tools. Guests neither list nor call. Proof: `scripts/test-federation.lua`.

## WhatsApp first

2026-10-17: [operator-directed management](WHATSAPP-OPERATOR-MANAGEMENT.md) is a
separate provisioned CLI/API capability, NOT generic MCP `send_message` or a
permission widening of this read boundary. GENERAL responder sends remain refused.

The Node MCP bridge (`scripts/mcp-whatsapp.mjs`, `scripts/whatsapp-mcp-client.mjs`) was deleted
on 10/11/2026: WhatsApp reads answer from the native index (`whatsapp_native`) and the
`wa-whatsapp` component, so no Node server is registered for WhatsApp on any node. The connector
HTTP client the bridge also carried survives as `scripts/whatsapp-connector-http.mjs`, imported by
the operator send path and the readiness check. A binding still uses ONLY explicit linked-device account,
generation, exact chat scope, connector URL and credential FILE references.
Explicit operator-wide bindings can read a service account approved with --all-chats;
child/event reads stay narrow and model arguments cannot grant account scope. One
server-side scoped query produces a globally capped page and stable before cursor,
including source freshness/sticky gaps. Per-item posting diagnosis is read-only.
Read_snapshot/lookup_self/inspect_chat access the durable journal without read
marking or chat opening. Remote access requires authenticated trusted-CA HTTPS;
numeric loopback HTTP is allowed locally. Redirects, insecure TLS and credential
URLs refuse. Protocol probing does not prove app identity or authorize effects.

### One surface, since 11/11 (#118)

WhatsApp has exactly one model-facing surface on every node, nine tools with exact
names and no namespace hash or peer prefix:

`mcp_whatsapp_contacts`, `mcp_whatsapp_search`, `mcp_whatsapp_read`,
`mcp_whatsapp_reactions`, `mcp_whatsapp_media`, `mcp_whatsapp_download`,
`mcp_whatsapp_backfill`, `mcp_whatsapp_send`, `mcp_whatsapp_send_status`.

`lua/core/whatsapp.lua` owns them: the schema the model reads and the call that runs live
in one file, so they cannot drift apart. They are called from code mode like every other
connector (`await tools.mcp_whatsapp_read({chat: "Laura"})`).

The account lives on exactly one node, so a call on a node that runs no `wa-whatsapp`
component does not queue a job nothing can settle (#99). It is **routed**, or **refused**
with the owner named, and the split is about effects, not names:

| tools | on a node without the component |
| --- | --- |
| `contacts`, `search`, `read`, `reactions`, `media` (reads) | asked of the node that holds the account, under the same name, and the answer says `served_by` / `asked_owner` |
| `download` (writes a file), `backfill` (asks the phone), `send` / `send_status` (effects on the account) | refused with `mcp_whatsapp_<verb>_on_the_account_node` and the owner named - never forwarded, because the effect would land on a machine the caller cannot see |

The owner is the node the deploy declared (`WASM_AGENT_WHATSAPP_OWNER`) or, when that is
unset, the one node whose federation catalog says it runs the component
(`federation.connectors`, `whatsapp_account: true`). Zero or two such nodes is an honest
refusal, not a guess.

**What was retired, and why.** The same questions used to exist under three spellings:
`whatsapp_*` (the local tools), `peer_<node>__whatsapp_*` (the same four tools federated) and
`mcp_whatsapp_native_*_<hash8>` / its peer-prefixed form (the same questions again, through an
MCP connector and its namespace hash). A session asked to "send a nice message to Laura" spent
six calls guessing those spellings and then guessed a phone number (session 570a0da0, 11/11).
Since then:

* `federation.exported()` exports no WhatsApp tool: the account node answers the surface's own
  capability instead (`lua/core/server.lua`, the five reads);
* `mcp.schemas()` publishes no tool of a connector in the WhatsApp family (`whatsapp`,
  `whatsapp_*`); such a connector stays in the registry, is still probed and toggled, and `/mcp`
  reports it as `superseded_by_mcp_whatsapp`;
* a call to a retired name answers `whatsapp_tool_renamed` with the `use:` field naming the tool
  to call, so a session that remembers the old spelling recovers in one step;
* `scripts/test-whatsapp-one.lua` fails if any of those spellings reappears in the catalogue the
  model is offered, the tools this node exports, or the rows `/mcp` shows.

The nine read/refusal tool names of the **MCP component** (`rust/components/mcp-whatsapp`,
which answers the old Go connector's loopback API) are still read_snapshot, read_newest,
list_chats, posting_status, read_field, lookup_self, inspect_chat, download_audio and
send_message - but that component is the dead bridge the cutover retires
(`docs/WHATSAPP-MCP-QUEUE.md`), and its tools are no longer offered to the model. Page-v2
responses have an incremental4MiB JSON budget and explicit ordered oversized
references, not silent text clipping. Exact field reads are16KiB base64 chunks with
optimistic versions; cursors are live scoped keyset windows, not pinned snapshots
or cryptographic scope tokens. See [byte contract](WHATSAPP-BYTE-PAGES.md).
Download_audio and
send_message explicitly refuse: media belongs to the private deterministic worker,
and GENERAL model sends cannot prove cross-device draft safety. No invented draft
absence, raw/backend fallback or generic owned-MCP send registration.

The bounded optional `list_chats.refresh_names:true` enrichment (unfiltered max32
observed rows/max3 group queries), SDK PN/LID label provenance and safe aggregate
hold/name coverage are specified in [WHATSAPP-COVERAGE.md](WHATSAPP-COVERAGE.md).
No new registered tool or profile grant is implied. The verified operator route may
execute this same CLI/MCP on server through an already authorized native peer;
credentials remain server-local. A local generic registry or exposed HTTPS port is
not required by that route. Versioned refresh reports refuse old unsupported servers.

The read adapter also supports observed-name/identifier `list_chats.query`,
`read_snapshot.conversation_id` narrowing, body/transcript `query` and inclusive
source-time `sent_since`/`until`. Exact ID disambiguation, partial coverage and
same-filter cursor continuation are required. Names are observed protocol labels,
not real-world identity verification. Private `--profile-file` stdio registration,
local CLI examples and coordinator-only live acceptance are in
[WHATSAPP-OPERABILITY.md](WHATSAPP-OPERABILITY.md).

Deterministic original-chat transcripts for BOTH incoming and own synchronized
outgoing audio use the separate explicitly activated connector policy, not model
send authority. Product recognition default is EN; configure this operator PT per
account. No initial-history posting, hosted fallback or fake translation. Jobs
does not run this connector/STT or enable a responder.

See [the service component](SERVICE-COMPONENTS.md) and
[WHATSAPP-MCP-QUEUE.md](WHATSAPP-MCP-QUEUE.md) for what the MCP can reach today. Production
pairing and real posting are separate unperformed operator proofs.


## Web research

`web_search`/`web_read` are fixed read-only MCP-backed native facades, discovered
through the stable envelope. The live default is anonymous DuckDuckGo HTML;
public HTTPS static source reading/cache refs are supported, not Firecrawl rendering,
PDF or browser actions. Queries leave the machine; no account/paid key is configured.
Private targets/credentials/challenges refuse. See [PROGRESSIVE-ENVELOPE.md](PROGRESSIVE-ENVELOPE.md)
for exact cache, permission, paging and shadow-benchmark limits.

## Focused proof

- `node --test --test-reporter=tap scripts/test-mcp.mjs scripts/test-mcp-session.mjs scripts/test-web.mjs`
  uses private stdio/HTTP peers, credentials, malformed output, schema change and
  timeout/no replay. The operator send path's negatives are covered by
  `scripts/test-whatsapp-operator.lua` (the state machine, `lua/core/whatsapp_operator.lua`); the Go
  connector's own process test went with that connector in Phase 4 (11/11). No real WhatsApp messages
  or paid model.
- `node scripts/test-mcp-native.cjs <built-wa> <fresh-evidence>` and `--post`
  verify private native SQL/operation source plus standalone embedded paths.
- `node scripts/test-mcp-ui.cjs <fresh-evidence>` and `--post` verify real Chromium
  inventory, controls, retained drafts/errors and scope/child isolation. A private
  guard-removal mutation must fail. Also run `scripts/test-ui.ps1`.
- WhatsApp connector, batch-tool, profile and
  instruction checks remain focused regressions. Verify embedded module freshness
  and actual installed script closure separately. Self-review, ordinary canonical
  main merge and remote readback; gate_verified:false / release_verified:false.

Read-only live identity proof is separate from fixtures and never authorizes a
third-party send. Routine code proof is not installation proof; Sentinel installs
one exact merged source generation while idle and records its actual verification.
