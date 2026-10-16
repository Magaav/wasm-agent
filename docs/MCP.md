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
enable/disable; changes require `expected_revision` from the current inventory.
New/edited definitions and every successful or failed probe stay disabled until
explicit enabling. Failed probes are durable. Changed tool input schemas refuse
before dispatch and invalidate approval. No live PID/continuous health is invented.

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

## WhatsApp first

The built-in `mcp-whatsapp.mjs` now uses ONLY explicit linked-device account,
generation, exact chat scope, connector URL and credential FILE references.
Explicit operator-wide bindings can read a service account approved with --all-chats;
child/event reads stay narrow and model arguments cannot grant account scope. One
server-side scoped query produces a globally capped page and stable before cursor,
including source freshness/sticky gaps. Per-item posting diagnosis is read-only.
Read_snapshot/lookup_self/inspect_chat access the durable journal without read
marking or chat opening. Remote access requires authenticated trusted-CA HTTPS;
numeric loopback HTTP is allowed locally. Redirects, insecure TLS and credential
URLs refuse. Protocol probing does not prove app identity or authorize effects.

The seven existing/added read/refusal tool names are recognizable: read_snapshot,
list_chats, posting_status, lookup_self, inspect_chat, download_audio and send_message.
Download_audio and
send_message explicitly refuse: media belongs to the private deterministic worker,
and GENERAL model sends cannot prove cross-device draft safety. No invented draft
absence, browser/raw/backend fallback or generic owned-MCP send registration.
Trusted event/profile scope, approvals, precedence, reservations and verification
remain in the existing Lua boundary. Read-only profiles ship disabled/unapproved.

Deterministic original-chat transcripts for BOTH incoming and own synchronized
outgoing audio use the separate explicitly activated connector policy, not model
send authority. Product recognition default is EN; configure this operator PT per
account. No initial-history posting, hosted fallback or fake translation. Jobs
does not run this connector/STT or enable a responder. Old WhatsApp owners are
retired, not source-health repair targets. Generic Jobs/CDP features are unchanged.

See [connector/setup](WHATSAPP-CONNECTOR.md), [migration](WHATSAPP-MIGRATION.md)
and the named retained artifacts/removal conditions. Production pairing/retirement
and real posting are separate unperformed operator proofs.


## Web research

`web_search`/`web_read` are fixed read-only MCP-backed native facades, discovered
through the stable envelope. The live default is anonymous DuckDuckGo HTML;
public HTTPS static source reading/cache refs are supported, not Firecrawl rendering,
PDF or browser actions. Queries leave the machine; no account/paid key is configured.
Private targets/credentials/challenges refuse. See [PROGRESSIVE-ENVELOPE.md](PROGRESSIVE-ENVELOPE.md)
for exact cache, permission, paging and shadow-benchmark limits.

## Focused proof

- `node --test --test-reporter=tap scripts/test-mcp.mjs scripts/test-mcp-whatsapp.mjs`
  uses private stdio/HTTP peers, credentials, malformed output, schema change,
  timeout/no replay, linked-device scope/auth and explicit browser/model-send retirement.
  Go connector fixtures separately cover fake transport/STT/posting against real SQLite.
  No real WhatsApp messages or paid model.
- `node scripts/test-mcp-native.cjs <built-wa> <fresh-evidence>` and `--post`
  verify private native SQL/operation source plus standalone embedded paths.
- `node scripts/test-mcp-ui.cjs <fresh-evidence>` and `--post` verify real Chromium
  inventory, controls, retained drafts/errors and scope/child isolation. A private
  guard-removal mutation must fail. Also run `scripts/test-ui.ps1`.
- WhatsApp connector/retirement/durable-effects, batch-tool, profile and
  instruction checks remain focused regressions. Verify embedded module freshness
  and actual installed script closure separately. Self-review, ordinary canonical
  main merge and remote readback; gate_verified:false / release_verified:false.

Read-only live identity proof is separate from fixtures and never authorizes a
third-party send. Routine code proof is not installation proof; Sentinel installs
one exact merged source generation while idle and records its actual verification.
