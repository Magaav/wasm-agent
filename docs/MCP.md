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
background event subscription, reconnect or automatic tool replay.

The native Lua manager uses existing supervised `host.operation` program/argv
execution. Sessions are **request-scoped**, not persistent daemons. Startup and
handshake overhead are an explicit trade-off. Native full-tree settlement is
required; a response plus uncertain cleanup is not clean success. EOF/timeout
following submission is unknown. Exact request/result artifacts and operation
receipts remain evidence; an ambiguous send never gains a retry.

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

The built-in `mcp-whatsapp.mjs` exposes read_snapshot, lookup_self, inspect_chat,
download_audio and send_message. Snapshot/media reads prove the bound app account;
only the explicitly bound loopback page is used. A protocol probe touches no app.
The Engine lists the profile-managed built-in adapter separately from configured
generic connectors and supplies a disabled read-only template (including media).
Generic registration of the owned send tool is refused: use the scoped facade.

The responder retains trusted-event conversation scope, operator precedence,
profile approval, body marker/limits, budget, **reserve before send**, verified
recipient/body/from-me/server acknowledgement and durable confirmation. It calls
MCP only after those checks. Transport/cleanup uncertainty never releases or
replays a reservation. The existing store action is unchanged: no chat opening,
read marking, draft overwrite, simulated input or send retry.

Compatibility read/audio/store-send CLIs route through MCP; explicit raw/backend
modes serve the owned adapter and avoid recursion. CLI callers still own approval
and reservations; they are not a new untrusted sending surface. Jobs pass profile
paths derived from host.paths(), not guessed home/account bindings. Missing binding
fails closed. Existing app drivers and pure expression tests remain supported.

Jobs retain triggers, schedules, controls, eligibility/window/hold rules, ledger
cursors/deduplication/handoffs, local deterministic STT, delivery history/ownership
and wakes. Their app operations use MCP; source-service/wake plumbing remains Jobs.
No existing job is enabled or new unattended wake created by this migration.

## Focused proof

- `node --test --test-reporter=tap scripts/test-mcp.mjs scripts/test-mcp-whatsapp.mjs`
  uses private real stdio/HTTP/CDP peers, including credentials, malformed output,
  schema change, timeout/no replay, media, draft/unread safety and one verified
  fake app-store send. No real WhatsApp messages or paid model.
- `node scripts/test-mcp-native.cjs <built-wa> <fresh-evidence>` and `--post`
  verify private native SQL/operation source plus standalone embedded paths.
- `node scripts/test-mcp-ui.cjs <fresh-evidence>` and `--post` verify real Chromium
  inventory, controls, retained drafts/errors and scope/child isolation. A private
  guard-removal mutation must fail. Also run `scripts/test-ui.ps1`.
- Existing WhatsApp cursor/transcription/durable-effects, batch-tool, profile and
  instruction checks remain focused regressions. Verify embedded module freshness
  and actual installed script closure separately. Self-review, ordinary canonical
  main merge and remote readback; gate_verified:false / release_verified:false.

Read-only live identity proof is separate from fixtures and never authorizes a
third-party send. Routine code proof is not installation proof; Sentinel installs
one exact merged source generation while idle and records its actual verification.
