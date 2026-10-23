# WhatsApp operator journey: source delivery and live acceptance

2026-10-17 update:** coordinator reports the existing account already authenticated,
PT/all-chats enabled and NEW eligible transcript posting activated. The working
on-demand route keeps the private profile/token on SERVER and uses the existing
approved native peer → server CLI/MCP → loopback path; no local registry/HTTPS setup
was needed. See [current coverage/handoff](WHATSAPP-COVERAGE.md). The initial setup
sequence below is reference/new-install material, NOT a request to re-pair, repeat
retirement/activation or interrupt the running service while real samples arrive.
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

**Architecture correction:** the authorized target is Linux/aarch64, not AMD64.
Use [WHATSAPP-ARM64.md](WHATSAPP-ARM64.md) and its NEW ARM64 bundle/schema3/locked
Python provisioning before the sequence below. The original AMD64 bundle and its
Windows dry-run receipt remain historical, unchanged—not ARM64 readiness.

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

One Go whatsmeow linked-device service (`connectors/whatsapp`), its private SQLite
journal/outbox, one warm offline Python faster-whisper worker, and the existing
read-only MCP/CLI/Lua boundary. This is NOT the old formatter plugin, Chrome/CDP,
a second sender, or a WASI rewrite. No arbitrary model replies are authorized.

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
- CLI exposes discovery, selection and filters. Native event Lua exposes query/time
  filters but stays fixed to its trusted-event chat; historical-ledger filters refuse.
  MCP now accepts a private `--profile-file`, avoiding embedded account config in
  registry arguments. `whatsapp-readiness.mjs` is one-shot/read-only and distinguishes
  connected/account/PT policy from **unverified** Whisper/service/live-delivery proof.

## Focused worker evidence (not live acceptance)

All fixture accounts/messages are synthetic; requested-on remains false in process
proof. Windows Go execution, real SQLite/HTTP/MCP stdio/CLI and source-root native
Lua were exercised. Go tests/vet, MCP scope/navigation tests, Python local/installer
and frozen-builder tests are the focused checks. Final matrix:38 top-level Go tests
plus2 mutation subtests, vet;7 Node tests;4 Python local/installer and4 frozen-builder
tests, all passed with zero skips. Settled operation `op-1792244159012944-13792-319`
ran the final Go/Node/unpaired-process/navigation-process/shipping closure checks
(exit0). Source-root native navigation includes3 causal assertions; private profile
MCP and honest unpaired readiness refusal are exercised too. Python's separate
settled `op-1792244017475789-13792-313` exited0. Exact final logs, source hashes,
Windows binary, Linux cross-build bundle and manifest digest are retained under the
owned checkout's `target/`; the settled worker report identifies the immutable
bundle and evidence receipt. No old mutable artifact is advertised as freshly built.

Source-root Lua execution does not certify a newly built embedded wa binary.
Linux cross-compilation does not certify Linux runtime/systemd. No real engine
weights, cloud execution, production service install/start/registration, real keys,
account/profile edits, pairing, QR capture, private media or live sends were used.
Self-review only; no independent reviewer or full release gate. gate_verified:false;
release_verified:false. Production E2E is **not yet complete**.

First synthetic process generation exposed a Lua reserved-word error (`until`);
quoted table keys fixed it before the passing generation. The failed generation is
retained, not relabelled success. Self-review also caught a narrowed owner binding's
oversized descriptor validation, stale-history title overwrite, and historical
ledger filters silently ignoring unsupported arguments; all now fail/behave explicitly.

## Coordinator execution sequence (source is owned/delivered by worker)

Remote execution is NOT categorically blocked: coordinator's fresh native peer
preflight succeeded on openclaw at `/local/projects/wasm-agent` (observed then-clean
7b8be4a601fc428af0f3c8c04d8d1e7a44f586df). That is an earlier observation, not current
installed-source or service health. Worker has no remote authority. Coordinator owns
all following production effects; do not ask another worker to finish this source.

1. **Fresh read-only host preflight.** Via the authorized native peer, inspect Git
   status/HEAD/origin; fetch and fast-forward only if clean to the delivered revision.
   Do not touch the unrelated research worker. Record `uname -sm`, `python3 --version`,
   `go version` if Go will be used, `systemctl --user status wa-whatsapp.service`,
   `systemctl --user show wa-whatsapp.service -p FragmentPath -p MainPID -p ExecStart`,
   `systemctl --user is-enabled wa-whatsapp.service`, `loginctl show-user "$USER" -p Linger`.
   Nonexistence is a result, not a reason for broad process termination. Inspect exact
   owned process/service metadata, NOT keys, raw media or chat databases via shell.
2. **Freeze/inventory/retire old owner safely.** Follow every exact-match supported
   job/task/custom-trigger/process/identity/unknown-send checkpoint in
   [migration](WHATSAPP-MIGRATION.md). Preserve original inventories/hashes and
   histories. Disable is not settlement. An unsupported custom trigger or unknown
   ownership is a real activation blocker, NOT permission to edit runtime DBs or
   broadly kill/delete. Do not run the old copilot to test source health.
3. **Install immutable bundle, still OFF.** Independently check the delivered manifest
   digest and reviewed installer against the recorded source. Transfer only the
   synthetic-free Linux release bundle, not `target` caches/evidence/state. Existing
   [frozen build and installer commands](WHATSAPP-CONNECTOR.md#human-build-and-installation-linux-cloud-operator-terminal)
   are authoritative; default dry run then explicit coordinator `--apply`. Do NOT
   run Windows executable on Linux. `sha256sum "$BUNDLE/wa-whatsapp"` and
   `"$BUNDLE/wa-whatsapp" --help` (CLI may return nonzero for help) establish executable
   readback separately from service readiness. Installer registers/starts nothing.
   Record `"$GO" version -m "$BUNDLE/wa-whatsapp"` when a verified Go toolchain exists.
   The manifest's source_files binds Go/module closure, worker, notices and installer.
4. **Provision offline STT.** Follow the pinned Python wheel/cache setup in connector
   docs in a private virtualenv; audit/freeze platform-specific transitive packages.
   Setup-time model download is explicit; runtime remains offline. Record package
   versions, model inventory/hashes and host CPU/RAM. Run:
   ```sh
   HF_HUB_OFFLINE=1 WA_WHATSAPP_STT_MODELS="$MODELS" "$PY" "$RELEASE/whatsapp-stt-local.py" --check
   ```
   `--check` actually loads the local model, but does not prove service worker warmth,
   language accuracy or audio transport. Missing model/library must remain a refusal.
5. **Explicit account policy and PRIVATE human pairing.** Initialize OFF with the
   exact operator PN JID, `--all-chats --language pt` as documented. For existing state,
   stop only its exact service; inspect config; use supported offline scope/language
   commands, never re-init/wipe or reset unknowns. State/owners directories must exist
   privately before systemd ReadWritePaths admission. Only the human opens an ordinary
   private local terminal to the server (for example human-run `ssh -t openclaw`, not
   a model SSH tool). Turn OFF terminal/session recording and do not share the window.
   INSIDE THAT HUMAN TERMINAL ONLY, set nonsecret release/state paths and run:
   ```sh
   "$RELEASE/wa-whatsapp" pair --state "$STATE" --owners "$OWNERS"
   ```
   **Human-only scan checkpoint:** phone → Linked devices → scan terminal QR. Never
   relay QR/session data through model/tool stdout, logs, screenshots, artifacts, MCP,
   public endpoints or a synthesized TTY. Coordinator must not execute/capture pair.
   Stop pair before serve; both share the same state/account locks. Confirm paired
   account via supported read-only lookup, not key-store inspection.
6. **Observe OFF, then activate/start once.** Serve OFF and inspect partial history,
   account/generation/PT, sticky gaps and exclusions. After legacy settlement and
   exact identity mapping, create the private retirement attestation (migration docs),
   stop foreground serve, activate with explicit transcript-posting approval, inspect
   cutoff, then register/start only the reviewed exact systemd user unit. No initial
   history flood, ten-minute expiry or historical unknown-send reset. Read back unit,
   MainPID/ExecStart/artifact hashes, config and authenticated status. Verify lingering
   if boot persistence is required; neither worker nor installer changes it.
7. **Expose only approved authenticated reads.** Keep Go listening on127.0.0.1:8787.
   Use the existing authorized private HTTPS gateway/trusted CA; do not expose8787
   or disable TLS checks. A dedicated approved Caddy host template is:
   ```caddy
   whatsapp.<approved-private-domain> {
       @reads {
           method POST
           path /status /lookup_self /inspect_chat /read_snapshot /list_chats /posting_status /read_field
       }
       handle @reads {
           request_body {
               max_size 128KB
           }
           reverse_proxy 127.0.0.1:8787
       }
       handle {
           respond 404
       }
   }
   ```
   This is a TEMPLATE, not an applied/tested host configuration or permission to make
   a public host. Coordinator must constrain ingress to approved devices/private
   network, validate DNS/certificate/config and apply through the supported gateway
   owner. Preserve Authorization header for Go's mandatory token check; disable body/
   credential logging. No token-bearing URL/header value appears in tool arguments.
   Provision the private token/CA files to the authorized local device via the human's
   approved private secret channel, never chat output. No credential-free native peer
   integration is claimed by this worker. Without gateway/credentials, local on-demand
   reads are genuinely pending, not satisfied by a hidden cloud journal.
8. **Approve local operator read binding, no delegated widening.** Use the private
   profile shape in connector docs with exact account/generation, BOTH owner-read
   flags, HTTPS URL and token/CA FILE paths. Do not modify shipped narrow profiles.
   For local conversation tool access, coordinator can explicitly put/probe/enable
   a read-only stdio MCP definition through Engine's existing revision-fenced UI:
   ```json
   {"id":"whatsapp","name":"WhatsApp operator reads","transport":"stdio",
    "program":"<absolute-node-executable>",
    "args":["<absolute-reviewed-source>/scripts/mcp-whatsapp.mjs","--profile-file","<absolute-private-operator-profile>"],
    "cwd":"<absolute-reviewed-source>","timeout_seconds":120,
    "tools":{"read_snapshot":"read","list_chats":"read","posting_status":"read",
             "read_field":"read","lookup_self":"read","inspect_chat":"read"}}
   ```
   Retain current revision, put/probe readback and explicitly enable only those six
   reads. A probe is not account health/permission to send. No generic send/media
   registration. Discovery namespaced tools then support this operator conversation;
   native event child facade remains narrow. Registry changes belong to coordinator.

## Practical bounded navigation after authorized setup

Run on the authorized LOCAL operator device (same approved profile/transport):

```sh
node scripts/whatsapp-readiness.mjs --profile-file "$PROFILE"
node scripts/whatsapp-read.mjs --profile-file "$PROFILE" --list-chats --query 'Ana' --limit 20
# Human/operator chooses exact ID after inspecting duplicate labels + ID + provenance.
node scripts/whatsapp-read.mjs --profile-file "$PROFILE" --chat "$CHAT" --limit 100 --sent-since "$START_EPOCH" --until "$END_EPOCH"
node scripts/whatsapp-read.mjs --profile-file "$PROFILE" --chat "$CHAT" --query 'orçamento' --limit 50
# Retain SAME filters and pass returned next_before if truncated. Recover referenced fields:
node scripts/whatsapp-read.mjs --profile-file "$PROFILE" --resource read_snapshot --row "$ROW" --field transcript --version "$VERSION" --offset 0 --length 16384
```

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
| install/ownership | exact release hash/source, one owned service/sender, legacy settlement, boot policy |
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

```sh
systemctl --user stop wa-whatsapp.service
systemctl --user is-active wa-whatsapp.service   # must be inactive; inspect exact MainPID settlement
"$RELEASE/wa-whatsapp" pause --state "$STATE"
# After stopped settlement ONLY, private encrypted/restricted backup of entire state
# (both SQLite DBs plus WAL/SHM, config/token/gap evidence), no model/media/key relay:
umask 077
mkdir -m 700 "$FRESH_PRIVATE_BACKUP"
cp -a -- "$STATE/." "$FRESH_PRIVATE_BACKUP/"
"$RELEASE/wa-whatsapp" status --state "$STATE"
```

Never copy active device keys or start a backup as a second owner. Preserve the
original volume and historical drafts/ledgers/transcripts. Repoint only the exact
reviewed unit to a compatible immutable older executable after a stopped-state
backup and unit diff. This directory migration is additive, not permission to drop
columns. **Pre-directory connector releases use positional INSERTs into chats and
are NOT compatible with this migrated journal. Do not roll those executables back
against it.** Retain the newer stopped state read-only and deploy a compatible fixed
release; never swap in an old ready-outbox backup to bypass this incompatibility.
Never restore an older ready outbox over a later unknown dispatch; retain
newer unknown effects for reconciliation and keep posting OFF if compatibility or
settlement is uncertain. No blind reset/replay or fabricated retirement attestation.
