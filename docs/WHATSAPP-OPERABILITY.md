# WhatsApp operator journey: source delivery and live acceptance

2026-10-17 update:** coordinator reports the existing account already authenticated,
PT/all-chats enabled and NEW eligible transcript posting activated. The working
on-demand route keeps the private profile/token on SERVER and uses the existing
approved native peer → server CLI/MCP → loopback path; no local registry/HTTPS setup
was needed. See [current coverage/handoff](WHATSAPP-COVERAGE.md). The initial setup
sequence below is reference/new-install material, NOT a request to re-pair, repeat
activation or interrupt the running service while real samples arrive.
36 historical holds remain unresolved; full audio/latency/coverage acceptance is pending.

2026-10-17 update: [operator management](WHATSAPP-OPERATOR-MANAGEMENT.md) adds a
separate explicitly provisioned prepare/approve/send/status CLI, not a responder
bypass or write grant to existing read clients. Earlier setup/live-acceptance text
below is historical source-delivery evidence, not a command to re-pair/reactivate.
Coordinator now reports generation2 authenticated at127.0.0.1:28787, PT/all-chats,
activation1792254831; new worker did not independently observe that runtime.
No recipient for Laura has been verified or message sent by this source worker.
For the reconciled first live setup failure, exact pairing/authentication/status
meanings and HUMAN-only phase-specific recovery, follow
[WHATSAPP-LIFECYCLE.md](WHATSAPP-LIFECYCLE.md). Do not replay the original setup or
remove its receipt guard. Local pair exit0 alone is not continuing readiness.

**Phase 4 (11/11) retired everything this page used to instruct.** The operator's decision
retired the Go connector: `connectors/whatsapp/`, the `scripts/` entry points that built and
installed it, its `wa-whatsapp.service` unit template and the ARM64 deployment page are gone from
the tree. So the setup sequence below is a **historical record of what was executed then**, never a
command to run now, and the "fresh preflight / install bundle / pause" steps it describes no longer
have a binary to act on. The live path is the `wa-whatsapp` service component
([SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md)), started and stopped through the node's own service
registry, and the cutover record in [WHATSAPP-CUTOVER.md](WHATSAPP-CUTOVER.md).

## Local tunnel keepalive (Windows)

The MCP binding reaches the rendezvous connector at a numeric loopback URL. On a
Windows node that is an SSH forward, and a dead forward makes every read fail with
`connector_transport_failed`. Register the keepalive once per node:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/whatsapp-tunnel-setup.ps1
```

It writes `%LOCALAPPDATA%\wasm-agent\whatsapp-tunnel.cmd`, backs up an existing
`wa-whatsapp-tunnel` task XML, creates or updates the task to run
`scripts/whatsapp-tunnel.sh`, starts it and checks `127.0.0.1:28787`. The shell
script loops `ssh -N` with `ServerAliveInterval=30`; when ssh exits it reconnects
after 5 seconds. The task is machine state, not repository state; the script and
this setup are the reproducible part. Overrides in the generated `.cmd`:
`WA_WHATSAPP_TUNNEL_HOST`, `_LOCAL_PORT`, `_REMOTE_PORT`, `_RETRY_SECONDS`.

## Architecture and worker result

One Go whatsmeow linked-device service (the `connectors/whatsapp` tree, **retired 11/11**), its
private SQLite journal/outbox, one warm offline Python faster-whisper worker, and the existing
read-only MCP/CLI boundary. This is NOT the formatter plugin, a second sender, or a WASI rewrite. No
arbitrary model replies are authorized. The worker survives that retirement
([WHATSAPP-TRANSCRIPTION.md](WHATSAPP-TRANSCRIPTION.md)); the Go service does not.

The pre-existing implementation already covered all-chat/current/future direct,
group and LID ingestion, independent durable incoming AND own synchronized outgoing
audio tasks, original-language transcription, EN default/explicit persisted PT,
activation cutoff, private-terminal pairing and held unknown sends. We retained it.
The actual missing journey seams were names, selected-chat narrowing and search:

- Additive chat-directory migration retains old journals. Authenticated adapter
  history names/display names, group join/rename metadata and direct sender push
  names are stored with provenance and local observation time. Group participant
  names and own outgoing echoes never rename a remote chat. History labels cannot
  overwrite an already observed live label. These are **untrusted protocol display
  labels attached to exact IDs**, not independently verified real-world identities,
  contact-book completeness, fresh server queries or identity-merging authority.
- `list_chats.query` searches observed titles/identifiers; duplicate titles remain
  separate exact IDs. Empty title/source/time0 explicitly means not observed yet.
  Existing populated journals need future metadata/history delivery to gain names;
  no forced full resync, hidden network lookup or fabricated name backfill exists.
- `read_snapshot.conversation_id` can only NARROW a locally approved MCP binding.
  `query` searches body OR transcript, `sent_since`/`until` are inclusive source
  timestamp bounds. Existing `since` is observation time, NOT source time.
  Search is literal substring (including `%`/`_`), SQLite ASCII-case-insensitive;
  Unicode case folding/linguistic ranking is not claimed. Query maximum256 UTF-8 bytes.
  No FTS/index rebuild or arbitrary SQL is exposed; large-journal search cost is an
  explicit production measurement item, not a fabricated performance guarantee.
- Same server-side SQL scope, account/generation,4MiB ordered page, row bounds,
  before cursor, source freshness/gaps and exact oversized-field API remain.
  Continuations must retain the SAME chat/query/time filters. This is live keyset
  pagination, not snapshot consistency. A page is newest **journal row ID** first,
  not globally sorted source chronology. CLI `chronological_inline_cursors` gives
  chronological presentation of inline messages WITHIN that bounded page; order
  by sent_at/cursor. Resolve oversized outcomes separately before claiming full context.
- CLI exposes discovery, selection and filters. The agent calls the same MCP tools
  only from code mode (`await tools.<name>(args)`). MCP now accepts a private `--profile-file`, avoiding embedded account config in
  registry arguments. `whatsapp-readiness.mjs` is one-shot/read-only and distinguishes
  connected/account/PT policy from **unverified** Whisper/service/live-delivery proof.

## Focused worker evidence (not live acceptance)

All fixture accounts/messages are synthetic; requested-on remains false in process
proof. Windows Go execution and real SQLite/HTTP/MCP stdio/CLI
were exercised. Go tests/vet, MCP scope/navigation tests, Python local/installer
and frozen-builder tests are the focused checks. Final matrix:38 top-level Go tests
plus2 mutation subtests, vet;7 Node tests;4 Python local/installer and4 frozen-builder
tests, all passed with zero skips. Settled operation `op-1792244159012944-13792-319`
ran the final Go/Node/unpaired-process/navigation-process/shipping closure checks
(exit0). Private profile MCP and honest unpaired readiness refusal are exercised too. Python's separate
settled `op-1792244017475789-13792-313` exited0. Exact final logs, source hashes,
Windows binary, Linux cross-build bundle and manifest digest are retained under the
owned checkout's `target/`; the settled worker report identifies the immutable
bundle and evidence receipt. No old mutable artifact is advertised as freshly built.

Linux cross-compilation does not certify Linux runtime/systemd. No real engine
weights, cloud execution, production service install/start/registration, real keys,
account/profile edits, pairing, QR capture, private media or live sends were used.
Self-review only; no independent reviewer or full release gate. gate_verified:false;
release_verified:false. Production E2E is **not yet complete**.

Self-review caught a narrowed owner binding's oversized descriptor validation and
stale-history title overwrite; both now fail/behave explicitly.

## What replaced the coordinator execution sequence

The seven-step sequence that stood here (verified Go SDK, frozen bundle build, source-bound
installer, `serve`/`pause` on a `wa-whatsapp` **binary**) described the Go connector's installation.
Phase 4 removed that program, so the steps are gone rather than rewritten: there is nothing to build,
nothing to install and no unit to enable. What an operator does now is the Rust path:

* **The component is installed by deploy, not by hand.** `wa-whatsapp` is pinned in `components.lock`
  and every node's deploy writes the artifact, its pin and its manifest. Installed is not enabled: a
  service runs only from an ENABLED definition in the services registry, which no deploy creates.
* **Start/stop/status is the service registry**, the same door as every other service component:
  `wa services start wa-whatsapp`, `wa services status wa-whatsapp` (or the `services` tool). The
  component's log is `<install>/components/wa-whatsapp.service.log`.
* **Reads** answer from the native index and the queue seam through the one surface,
  `mcp_whatsapp_*` (`lua/core/whatsapp.lua`): `mcp_whatsapp_contacts`, `mcp_whatsapp_search`,
  `mcp_whatsapp_read`, `mcp_whatsapp_reactions`, `mcp_whatsapp_media`, `mcp_whatsapp_download`,
  `mcp_whatsapp_backfill`, `mcp_whatsapp_send`, `mcp_whatsapp_send_status`. A read on a node that runs
  no component is asked of the node that holds the account; the dead `mcp-whatsapp` bridge is
  [WHATSAPP-MCP-QUEUE.md](WHATSAPP-MCP-QUEUE.md)
  ([WHATSAPP-MCP-QUEUE.md](WHATSAPP-MCP-QUEUE.md) records exactly what it can reach today).
* **Explicit sends** are the operator path, prepare -> approve -> send -> status
  ([WHATSAPP-OPERATOR-MANAGEMENT.md](WHATSAPP-OPERATOR-MANAGEMENT.md)), and they are dispatched by the
  component's outbox.
* **The recognizer venv** is still a human, setup-time step: its commands and pins are in
  [WHATSAPP-TRANSCRIPTION.md](WHATSAPP-TRANSCRIPTION.md) ("Provisioning the recognizer's venv") and
  `stt/`.

The preflight facts below are kept as what they are - observations made before the cutover - and the
"nonexistence is a result" rule still holds for any process you inspect.

## Practical bounded navigation after authorized setup

Run on the authorized LOCAL operator device (same approved profile/transport):

```sh
node scripts/whatsapp-readiness.mjs --profile-file "$PROFILE"
```

Then navigate with the native index tools from code mode
(`mcp_whatsapp_contacts` / `mcp_whatsapp_search` / `mcp_whatsapp_read` - one surface, and a call on a
node that runs no component is answered by the node that holds the account):
search by a name or a literal term, take the exact chat ID from the answer, and read a
bounded window with `conversation_id` plus `limit` and the time bounds. Human/operator
chooses the exact ID after inspecting duplicate labels + ID + provenance. The
`whatsapp-read.mjs` CLI these examples used went with the Node MCP bridge (10/11).

MCP calls use the same fields without loading all chats into model context. Read
only relevant named candidates and selected bounded windows. Search covers only
locally received body/transcript rows; missing/queued/unsupported audio is not a
negative semantic search result. Check source_state/coverage, byte/row truncation,
oversized outcomes and field versions. Do not infer complete WhatsApp history.

## Required retained live proof (coordinator/human; currently UNVERIFIED)

Keep a private row per step with UTC time, source commit/tree/manifest/artifact
hash, command/check exit, nonsecret status and test message IDs. No QR, credentials,
raw media/chat bodies in general reports. Distinguish tested vs worker-reported vs
unverified. Worker synthetic evidence does not change any row below to live-tested.

| step | actual acceptance |
|---|---|
| install/ownership | exact release hash/source, one owned service/sender, boot policy |
| pairing/account | human-only scan complete, lookup exact PN account/generation, PT/all-chats explicit |
| sync | supported existing direct/group/LID and a newly observed direct/group chat visible; honest partial history |
| incoming audio | fresh known PT recording → independent task → local transcript → labeled reply-linked ORIGINAL-chat post |
| own outgoing audio | send from phone/other linked device, synchronized own=true task → same local policy; no arbitrary AI reply |
| local reads | local operator MCP discover duplicate names/IDs, select exact chat, chronological bounded context, body/transcript search, source freshness |
| restart/backlog | exact service stop/start, new queued incoming/own recordings delivered upstream after cutoff, backlog resumes; no duplicate known parts; unknowns held |
| exclusions/failure | safe synthetic unsupported test; missing model/offline library reason visible, no hosted fallback; don't create real gaps to test recovery |
| latency/warmth | below measurement plus real process/Whisper/cache/systemd readback, not compile-only readiness |

Latency plan: synchronize phone/server clocks (record uncertainty). For at least
three incoming and three own outgoing short PT samples, include one cold-first
sample and warm-following samples. Record source sent_at, first local journal
observed_at, first poll with transcript present (local completion upper bound),
first poll showing accepted outbox part (another upper bound) and private human visible-post time. Use bounded selected
reads and posting_status manually at recorded times; **no model polling loop or new
watcher**. Report source→observed, observed→transcript upper bounds, accepted/visible
latency, audio duration, queue depth, CPU/model/cache, polling interval/clock error
and failures. Existing rows do not store precise compute-start/finish timestamps;
do not pretend snapshot_at is exact completion time or promise literal instant.
Missing upstream audio/history cannot be measured as successful transcription.

## Pause, stopped backup and rollback (coordinator only)

The Go connector's pause commands (`"$RELEASE/wa-whatsapp" pause --state ...`, a user unit, a journal
with two SQLite databases) went with the program. On the Rust path the equivalent is the component's
own state, and the rule that matters is unchanged: **stop first, then copy, and never run two clients
on one linked device.**

```sh
# 1. Stop the component through the service registry (the supported door), then confirm it is down.
wa services stop wa-whatsapp
wa services status wa-whatsapp          # must not report running
# 2. Only after it has settled: a private copy of the component state, keys included, 0600/0700.
umask 077
mkdir -m 700 "$FRESH_PRIVATE_BACKUP"
cp -a -- "$HOME/.wasm-agent/components/wa-whatsapp.state/." "$FRESH_PRIVATE_BACKUP/"
```

Never copy active device keys into a shared location, and never start a second component on the same
account to "keep serving" during a backup: the server sees one linked device with two connections and
the ratchets race. Preserve the original state and every historical draft/transcript; restore by
moving a copy back while the component is stopped, exactly as the cutover did
([WHATSAPP-CUTOVER.md](WHATSAPP-CUTOVER.md)). Never restore an older ready outbox over a later unknown
dispatch; retain newer unknown effects for reconciliation and keep posting OFF if compatibility or
settlement is uncertain. No blind reset, no replay.
