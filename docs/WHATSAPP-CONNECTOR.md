# WhatsApp linked-device connector (staged replacement)

Canonical implementation: `connectors/whatsapp` (`wa-whatsapp`). No Chrome/CDP,
UI input, Sentinel tick, LLM login or hosted STT/translation is involved.
**Not deployed or paired by the implementation worker.** Cloud execution and a
private human terminal are required for activation. Follow [migration](WHATSAPP-MIGRATION.md)
first; do not run a second sender alongside an old installation.

This uses the unofficial whatsmeow multi-device protocol, not an official Meta API.
Account-policy/blocking risk, upstream protocol changes, incomplete initial history,
expired/unavailable media and redelivery gaps remain. Do not promise lossless history
or external exactly-once delivery. Pins, checksums and original license texts are in
`connectors/whatsapp/go.mod`, `go.sum`, `THIRD-PARTY-NOTICES.txt`.

## State, scope and safety

- One restricted state directory per account. `device-keys.db` is the upstream
  device/key store; `journal.db` separately stores account/generation/chat/message
  IDs, observations, media metadata, audio tasks, transcripts, events and outbox.
  SQLite WAL + FULL synchronization and transactional insertion deduplicate messages.
  Never expose the device database, arbitrary SQL, protocol media keys or raw events.
- An OS lock protects the state directory. A second account-keyed OS lock in the
  shared per-user owners directory fences pair/serve across different state directories.
  All instances must use the SAME owners directory and persistent volume. This is
  single-node fencing, not a distributed lease or protection against an OS owner
  deliberately copying keys/overriding the lock root. Never copy active keys.
- `init` persists explicit account PN JID and exact approved chat JIDs; no display-title
  guesses, discovery of another account or automatic legacy ID conversion. The paired
  identity must match. Logout pauses posting, advances generation, clears activation
  and reports `needs_pairing`; re-pairing needs a private human again.
- Requested on/off is separate from `connected`, `catching_up`, `reconnecting`,
  `needs_pairing` and named degraded states. Configuration changes are offline CLI
  operations: stop the owned service first, change, inspect, then start. A service
  restart never changes requested-on, language, activation or unknown sends.
- Incoming AND own outgoing audio synchronized from phone/other devices are journaled.
  Initial history is journal-only. Explicit activation records a first cutover at the
  next epoch second; only source timestamps at/after it become posting tasks. Historical
  and reconnect events after that cutoff remain eligible, even after long downtime or
  while requested-off: **there is no ten-minute transcript expiry**. Upstream must
  actually deliver those messages; no claim of recovering unavailable messages.
  Future timestamps >5 minutes ahead are visibly unsupported, not permission to post.
- Each audio has an independent durable compute task. Failures retain a reason and
  retry time; ingestion does not wait for STT. A warm Python worker loads multilingual
  `small` CPU/int8 once, beam 5, VAD. Successful transcripts/outbox parts are cached in
  SQLite before posting. Missing cache, interpreter, library or media is visible;
  there is no runtime model download/provider fallback.
- EN (`en`) is the shipped recognition default. This account must explicitly use PT
  (`pt`) as shown below; it is NOT a global default. `en`/`pt` are speech-language
  hints for **original-language transcription**, not target-language translation.
  `auto` detects the original language. Translation requests are explicitly unsupported;
  no extra backend/spend is silently selected. Queued tasks snapshot their language.
- View-once, ephemeral audio, oversize (>20 MiB), invalid audio MIME, edited audio
  and no-speech remain visible as unsupported. Other media is journaled without STT.
  Raw view-once/ephemeral media metadata is not retained. Downloads check declared
  length before fetching and received length afterward; the upstream API returns a
  byte buffer, not a guaranteed streaming memory cap. Provision disk/CPU limits.
- Transcript text is clearly labeled `🎙️ _Automated transcript_`, UTF-8/rune-safe,
  numbered and reply-linked to the source audio in the ORIGINAL chat. Text echoes
  never create audio tasks. No composer opening, read marking or general AI replies.
- Each account/generation/chat/source/part has a unique outbox key and preallocated
  send ID. Dispatch intent is persisted as **unknown before the external call**.
  A crash/timeout/ack loss is held, never automatically resent. Later exact own-message
  ID/chat/body echoes can reconcile it. A successful upstream send result means server
  acceptance, NOT recipient delivery/read. Unknown earlier parts hold later parts.
  There is no command that resets unknown sends or bulk-posts old history.
- Edit/delete/protocol/receipt events are labeled unsupported/partial; this is not a
  complete authoritative reconstruction of edited/deleted chat state or draft state.

## Human build and installation (Linux cloud operator terminal)

These are operator commands, NOT evidence they were executed in production.
Use a supported operator terminal on the cloud node; do not bypass a remote execution
refusal with SSH from a model tool. No model-provider credentials are required.

1. Obtain the exact merged source through the normal authorized source channel.
   Use Go **1.27.2**, verify its official checksum before execution, private build
   caches and `GOTOOLCHAIN=local`. From a clean committed checkout:

   ```sh
   export GO=/absolute/private/go/bin/go
   export GOTOOLCHAIN=local
   export GOPATH="$PWD/target/gopath" GOCACHE="$PWD/target/gocache" GOMODCACHE="$PWD/target/gomodcache"
   bash scripts/build-whatsapp.sh
   ```

   This verifies pinned modules, builds Linux/amd64 with CGO disabled and writes
   `target/whatsapp-linux-<tree>/manifest.json` plus the artifact manifest SHA256.
   Transfer that bundle and its independently checked manifest digest through your
   authorized channel. Do not put secrets in the bundle. The installer itself must
   come from the reviewed source; a checksum printed by an untrusted bundle is not trust.

2. Review the source-bound installer dry run, then explicitly apply as the intended
   unprivileged service user (no sudo). Use absolute paths:

   ```sh
   python3 scripts/whatsapp-install.py --bundle "$BUNDLE" --manifest-sha256 "$DIGEST" \
     --prefix "$HOME/.local/lib/wa-whatsapp" --state "$HOME/.local/state/wa-whatsapp" \
     --python "$HOME/.local/wa-stt/bin/python" --models "$HOME/.local/share/wa-stt/models"
   # Same command with --apply installs immutable release files, but registers/starts NOTHING.
   ```

   Apply is Linux-only. The installer refuses hash/member/ownership mismatches and
   existing releases; it never wipes state, changes requested policy or touches live
   credentials. It emits a systemd USER unit inside the release, not into systemd.

3. Separately provision Python 3.9+ and the multilingual `small` model into that
   PRIVATE cache. The real PyPI metadata pin is faster-whisper1.2.1 (MIT), recorded
   with its wheel hash in `connectors/whatsapp/python-stt-dependency.json`. These are
   HUMAN setup-time network commands, never message-time downloads:

   ```sh
   umask 077
   python3 -m venv "$HOME/.local/wa-stt"
   PY="$HOME/.local/wa-stt/bin/python"
   mkdir -p "$HOME/.cache/wa-stt-bootstrap" "$HOME/.local/share/wa-stt/models"
   "$PY" -m pip download --no-deps faster-whisper==1.2.1 --dest "$HOME/.cache/wa-stt-bootstrap"
   WHEEL="$HOME/.cache/wa-stt-bootstrap/faster_whisper-1.2.1-py3-none-any.whl"
   printf '79a66ad50688c0b794dd501dc340a736992a6342f7f95e5811be60b5224a26a7  %s\n' "$WHEEL" | sha256sum -c -
   "$PY" -m pip install "$WHEEL"
   export WA_WHATSAPP_STT_MODELS="$HOME/.local/share/wa-stt/models"
   "$PY" -c 'import os; from faster_whisper import WhisperModel; WhisperModel("small", device="cpu", compute_type="int8", download_root=os.environ["WA_WHATSAPP_STT_MODELS"])'
   HF_HUB_OFFLINE=1 "$PY" "$RELEASE/whatsapp-stt-local.py" --check
   ```

   Native transitive Python dependencies are platform-specific and NOT fully locked
   by this repository; freeze/review that environment under your normal supply-chain
   policy before production. Metadata/protocol fixtures are not a real engine/model
   quality or production Python installation proof. No provider login/credentials.

4. Complete the legacy check/apply/settlement and verified identity mapping in
   [WHATSAPP-MIGRATION.md](WHATSAPP-MIGRATION.md). Preserve unknowns and historical
   stores separately. Then initialize the new state **OFF**, with explicit PT for
   this operator. Replace variables privately; no real account config is committed:

   ```sh
   WA="$RELEASE/wa-whatsapp"
   STATE="$HOME/.local/state/wa-whatsapp"
   OWNERS="$HOME/.config/wa-whatsapp-owners"
   "$WA" init --state "$STATE" --account "$ACCOUNT_PN_JID" --chats "$APPROVED_CHAT_JIDS" --language pt
   "$WA" status --state "$STATE"      # language=pt, requested_on=false
   "$WA" pair --state "$STATE" --owners "$OWNERS"
   ```

   Pair ONLY at a private interactive stdin/stdout/stderr TTY, with terminal/session
   recording disabled. Scan the QR from phone → Linked devices. Never call `pair`
   through a model/tool, pipe/redirect/capture it, photograph it into evidence or put
   session keys/QR codes in logs. Captured/non-TTY pairing refuses before connection.
   The terminal is cleared afterward; clearing does NOT erase a terminal recorder.
   Pair and serve share both ownership locks; stop one before starting the other.

5. Run `serve` initially OFF to inspect connection/history state via the authenticated
   API (it can serve local status while unpaired without attempting WhatsApp pairing):

   ```sh
   "$WA" serve --state "$STATE" --owners "$OWNERS" --python "$HOME/.local/wa-stt/bin/python" \
     --worker "$RELEASE/whatsapp-stt-local.py" --models "$HOME/.local/share/wa-stt/models"
   ```

   Stop that foreground instance, then activate only after the human's verified retirement receipt:

   ```sh
   "$WA" activate --state "$STATE" --approve-transcript-posting --retirement-receipt "$PRIVATE_RECEIPT"
   "$WA" status --state "$STATE"
   # Start manually OR, after reviewing the generated unit, install it yourself:
   mkdir -p "$HOME/.config/systemd/user"
   cp "$RELEASE/wa-whatsapp.service" "$HOME/.config/systemd/user/wa-whatsapp.service"
   systemctl --user daemon-reload
   systemctl --user enable --now wa-whatsapp.service
   ```

   A headless user's manager surviving logout/boot may require administrator-approved
   user lingering; neither installer nor worker enables it. No firewall changes are
   needed for loopback. User unit start/boot behavior requires actual Linux verification.
   Pause: stop that exact unit, run `pause --state "$STATE"`, verify status, restart.
   Resume uses `activate` again and retains the ORIGINAL cutoff and queued backlog.

## Authorized devices and existing app boundary

The Go API binds numeric loopback by default, requires a private 256-bit token file,
account + generation on EVERY operation and configured chat scope. `POST /status`,
`/read_snapshot`, `/lookup_self`, `/inspect_chat` are scoped reads. Snapshot rows include
transcripts/task state and stable journal cursors; `before` reads older rows, newest first.
`truncated` is explicit. No arbitrary SQL, authentication-store or media-key access.
While serving, use authenticated `/status`; offline CLI `status` cannot take the owner
lock of a running server. Offline status has no live connection observation.

Existing `mcp-whatsapp.mjs`, compatibility read/lookup CLIs and the Lua WhatsApp facade
are repointed to `backend: linked_device`. A locally approved profile binds:

```json
{"backend":"linked_device","account":"<exact-PN-JID>","generation":1,
 "connector_url":"https://<approved-private-host>/",
 "token_file":"<absolute-private-token-file>","ca_file":"<optional-trusted-CA-file>",
 "allowed_conversations":["<exact-approved-chat-JID>"],"language":"pt"}
```

Token VALUES are never arguments/URLs. Provision authorized-device credential files
through the human's approved private channel, not model output. Remote access needs
an authenticated HTTPS reverse proxy/trusted CA (or a separately approved fabric
transport); the connector does not configure it. Plain exposed ports, insecure TLS,
credential URLs and redirects are refused by the client. Loopback HTTP is allowed only
for numeric loopback. Network proxy/install proof is an operator responsibility.

The existing generic owned-MCP-send denial, trusted event/profile scope, approval,
precedence, reservations and verification code are retained. GENERAL model sends
are refused BEFORE reservation because cross-device draft visibility is **unsupported**,
not “no draft.” This deliberately does not weaken that safety rule. Deterministic
transcripts are a separate human-activated policy, not an unrestricted model tool.
Historical ledger reads stay read-only; no new responder/wake is enabled.

## Backup, upgrade and rollback

Stop the exact owned service and confirm settlement before a consistent backup of
BOTH SQLite stores (including WAL if not checkpointed), token and private configuration.
Encrypt/restrict the backup: device keys authorize the account. Never copy a live key
store to another active owner, publish it or wipe a volume. Install a new immutable
release with a new verified manifest; inspect the unit diff, stop the old unit, change
its exact ExecStart through the operator's service procedure, then start and verify
requested state/language/identity/generation/outbox. No blind auto-enable on upgrade.
Rollback executable files only after confirming schema compatibility; otherwise restore
a consistent STOPPED backup read-only for reconciliation. Unknown sends must remain
held across rollback; never restore an old “ready” outbox over a later dispatch intent.

## Focused verification and remaining proof

`go test -v ./...` in `connectors/whatsapp` uses real SQLite, actual pinned adapter
compilation/event mappings, fake WhatsApp transport, real HTTP handlers and private
process fixtures. Set `WA_TEST_PYTHON` for the warm-process fixture; missing it is a skip.
`node --test --test-reporter=tap scripts/test-mcp.mjs scripts/test-mcp-whatsapp.mjs`,
`python scripts/test-whatsapp-local.py`, Rust wa-jobs tests and source/embedded Lua
checks cover the boundary/retirement behavior. These are deterministic fixtures, NOT
recognition-quality measurements or proof of real pairing/send/reconnect behavior.
Windows execution and Linux cross-build do NOT prove Linux runtime/systemd support.
Production install, human pairing, real identity mapping, history coverage, media
compatibility and exact original-chat transcript delivery remain explicit live proof.
