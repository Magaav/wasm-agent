# WhatsApp linked-device connector (source-ready; live acceptance pending)

rrent dated coordinator-reported live activation/read bridge, bounded name refresh
and unresolved mutation-hold coverage: [WHATSAPP-COVERAGE.md](WHATSAPP-COVERAGE.md).
Authenticated transport/readiness does not certify fully named or unheld history.

2026-10-17: distinct opt-in [operator-directed text/replies](WHATSAPP-OPERATOR-MANAGEMENT.md)
add prepare/approve/send/status with separate selected-chat capabilities. Existing
GENERAL responder/MCP sends still refuse; read-only credentials gain no writes.
See that contract for current coordinator-reported live baseline and pending proof.
Current lifecycle investigation/status meanings and no-replay recovery:
[WHATSAPP-LIFECYCLE.md](WHATSAPP-LIFECYCLE.md). Local pairing is not authenticated
login; the original live failure's upstream reason remains unverified.

Current architecture-specific deployment correction: [WHATSAPP-ARM64.md](WHATSAPP-ARM64.md).
The authorized server is Linux/aarch64; the original AMD64 bundle is retained but
MUST NOT be installed or relabelled there.

Current end-to-end operator handoff, bounded name discovery/selection/search and
live acceptance checklist: [WHATSAPP-OPERABILITY.md](WHATSAPP-OPERABILITY.md).
Historical first-delivery evidence is not live acceptance.

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
- `init --all-chats` is explicit owner approval to journal/process all supported
  current AND future chats of this exact account. It discovers new direct/group/LID
  chats without a manually maintained list. `init --chats <IDs>` remains the narrow
  alternative; existing configs default to selected mode, never silently widened.
  An existing selected account can use the OFFLINE owner command `scope --all-chats`:
  it pauses posting and requires a fresh future activation cutoff, without resetting
  existing approved pending tasks, transcripts or unknown effects. No title guesses,
  other-account discovery or automatic legacy ID conversion. The app journal is separate; the restricted device/session store also contains
  the SDK's optional decrypted-event replay buffer, never exposed by the app API.
  The paired identity must match. Logout pauses posting, advances generation, clears activation
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
  Raw view-once/ephemeral media metadata is not retained. `DownloadToFile` uses the
  pinned SDK's encrypted/plaintext SHA256, MAC and streaming CBC validation, through
  a File wrapper that caps Write/WriteAt/Seek/Truncate and does NOT promote ReaderFrom.
  Media HTTP also caps Content-Length/chunked actual bytes and refuses redirects.
  Plain audio is capped at20MiB; encrypted disk/body bytes at20MiB+26 (AES padding
  and MAC). One bounded plaintext array is allocated only after validated file size;
  SDK working buffers are32KiB. These are payload bounds, not a total process/RSS
  quota (including upstream history decompression/session allocations). Network downloads have a90-second context/client deadline; local kernel/disk
  stalls are not a hard real-time guarantee. Temporary media is closed/removed on
  overflow, timeout or validation failure. Declared/actual plaintext size mismatch
  refuses. The media HTTP cap also refuses oversized history blobs as an explicit
  sticky gap rather than unbounded allocation; no complete-history guarantee.
- Transcript text is clearly labeled `🤖 _Copiloto_`, UTF-8/rune-safe,
  numbered and reply-linked to the source audio in the ORIGINAL chat; incoming and
  synchronized own outgoing audio are posted when `transcript_posting` is enabled. Text echoes never create
  audio tasks. No composer opening, read marking or general AI replies.
- Image messages are journaled with their raw protobuf and optionally OCRed by the
  local RapidOCR worker into `messages.media_text` (see [WHATSAPP-OCR.md](WHATSAPP-OCR.md)).
  View-once/ephemeral images are never downloaded; images received before this path
  have no retained payload and cannot be OCRed retroactively.
- Each account/generation/chat/source/part has a unique outbox key and preallocated
  send ID. Dispatch intent is persisted as **unknown before the external call**.
  A crash/timeout/ack loss is held, never automatically resent. Later exact own-message
  ID/chat/body echoes can reconcile it. A successful upstream send result means server
  acceptance, NOT recipient delivery/read. Unknown earlier parts hold later parts.
  There is no command that resets unknown sends or bulk-posts old history.
- Verified source revoke/edit signals are mapped only by exact authenticated
  account/chat/source ID and author. They block pending compute and undispatched
  parts, including a recheck after compute and before dispatch. Unknown/confirmed
  effects and original evidence are preserved, never reset or deleted. SDK owner
  DeleteForMe is an exact source fence even when delivered before that source;
  owner ClearChat/DeleteChat conservatively hold the chat, including full-sync signals.
  An unprovable
  mutation mapping holds that chat explicitly; no guessed ID/title merge. Final
  dispatch admission and known mutation commits are serialized. The lock is NOT held
  through readiness checks or an external ACK wait; the adapter rechecks source,
  account/generation and gaps immediately before invoking the SDK. A mutation after
  dispatch admission may already be in flight and cannot retract a submitted effect.
  Only a typed owned-adapter proof that the SDK was NOT called can schedule safe
  retry after intent; generic SDK errors, crash windows and ack loss remain unknown. This is not full edit/delete or
  receipt-state reconstruction; held chats require separately approved reconciliation.
  A reviewed hold can be released offline, with the service stopped:
  `wa-whatsapp release-hold --state <private-path> --chat <exact-jid> --reason "<review>" --confirm`.
  It removes only that `chat_holds` row and records `hold_released`; mutation
  evidence, source blocks, blocked audio and blocked outbox rows are preserved and
  nothing is replayed. New audio after the release can become pending.
- SDK callbacks return processing success/failure. Failed persistence returns false,
  retains a separate fsynced sticky gap marker and blocks posting/activation; Connected
  and OfflineSyncCompleted never erase it. Safe ingestion/retry remains possible.
  If even the gap marker cannot be persisted, the service fails with code78; the
  generated unit prevents automatic restart for that code. There is no gap/reset or
  unknown-send replay command. Manual reconciliation is required, not automatic
  certification that all lost classes were redelivered.
- Posting readiness refusals are NOT unknown sends. Retryable pre-dispatch refusal
  records a per-part reason and a one-minute retry time; permanent refusal blocks
  that part. Other sources/chats continue, while multipart order remains enforced.
  Unexpected API Serve termination is nonzero (normal requested shutdown is zero),
  so the user service's on-failure restart is meaningful.

## Human build and installation (Linux cloud operator terminal)

These are operator commands, NOT evidence they were executed in production.
Use a supported operator terminal on the cloud node; do not bypass a remote execution
refusal with SSH from a model tool. No model-provider credentials are required.

1. Obtain the exact merged source through the normal authorized source channel.
   Use Go **1.27.2**, verify its official checksum before execution, private build
   caches and `GOTOOLCHAIN=local`. From a clean committed checkout:

   ```sh
   export GO=/absolute/private/go/bin/go
   # Digest of the executable extracted from the CHECKSUM-VERIFIED official SDK,
   # recorded at provisioning; do not bootstrap trust by hashing an untrusted binary.
   export GO_SHA256='<recorded-verified-executable-SHA256>'
   export PYTHON3=/absolute/python3
   export GOTOOLCHAIN=local
   export WA_WHATSAPP_GOARCH=arm64  # authorized aarch64 server; amd64 remains supported/default
   export GOPATH="$PWD/target/gopath" GOCACHE="$PWD/target/gocache" GOMODCACHE="$PWD/target/gomodcache"
   bash scripts/build-whatsapp.sh
   ```

   The wrapper resolves explicit `PYTHON3` or `python3` and validates Python3.9+
   before compilation; there is no unconditional `python` dependency. It captures
   commit/tree once, archives all Go/module/STT/installer/notices/build-helper/license
   inputs from that immutable commit, builds with GOWORK off, readonly modules,
   GOTOOLCHAIN local and `-buildvcs=false`, and checks frozen/member/origin hashes
   again before emitting a schema3 manifest with explicit Linux target, checked ELF
   machine and exact Go build settings. Origin/frozen/member drift, missing
   interpreter, untrusted SDK hash or reused output refuses without a success manifest.
   The manifest binds artifact hashes AND complete frozen source hashes; commit/tree
   are not queried again from a possibly different HEAD. Partial failed build output
   is preserved, not advertised as a successful bundle. Linux/amd64 and Linux/arm64
   are supported, CGO disabled; target selection is explicit, never inferred from the
   build host. Output is `target/whatsapp-linux-<arch>-<tree>/manifest.json` plus its digest.
   Snapshot inputs, source/SDK/module/STT/installer/license hashes and private raw
   build logs are retained. Review logs before transferring a bundle; they are not
   model output or a place for credentials. The reviewed installer supports schema3
   (and legacy schema2 AMD64), and refuses host OS/CPU or ELF/manifest target
   disagreement even during dry-run, before copying. Use the current reviewed
   installer, not the historical AMD64 bundle's old installer.
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
   PRIVATE cache. For the authorized CPython3.12 Linux/aarch64 host, use the complete
   hash-pinned wheel closure in [WHATSAPP-ARM64.md](WHATSAPP-ARM64.md), not the
   unconstrained transitive install example below. The real PyPI metadata pin is faster-whisper1.2.1 (MIT), recorded
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

   Native transitive Python dependencies are platform-specific. The explicit
   CPython3.12 Linux/arm64 closure is now hash-locked; other platforms are NOT fully
   locked here. Review the actual environment under your normal supply-chain
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
   "$WA" init --state "$STATE" --account "$ACCOUNT_PN_JID" --all-chats --language pt
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
     --worker "$RELEASE/whatsapp-stt-local.py" --models "$HOME/.local/share/wa-stt/models" \
     --ocr-python "$HOME/.local/wa-ocr-rapid/bin/python" \
     --ocr-worker "$RELEASE/whatsapp-ocr-local.py"
   ```

   Stop that foreground instance, then activate only after the human's verified retirement receipt:

   ```sh
   "$WA" activate --state "$STATE" --approve-transcript-posting --retirement-receipt "$PRIVATE_RECEIPT"
   "$WA" posting --state "$STATE" --set enable   # separate audio reply toggle (incoming and own outgoing)
   "$WA" status --state "$STATE"
   # The node UI exposes the same policy as one checkbox. Its master-only
   # `/whatsapp/posting` route proxies the read status and the separate approval-token
   # operator control using private token files; the read-only MCP gains no send authority.
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
account + generation on EVERY operation and an explicit read scope. Owner-wide
service mode does not widen a child: the locally approved operator MCP/CLI binding
must set BOTH `account_wide:true` and `operator_account_read:true`. Model arguments
cannot set either. Native `whatsapp_read` STILL fixes one trusted-event conversation.
A selected binding sends its exact conversations as a server-side SQL scope, never
fetches unrelated chats and never loops once per chat. `read_snapshot`, `list_chats`
and `posting_status` return one total **row AND byte** bounded page:4MiB encoded
UTF-8 JSON including late metadata/LF, with encoded_bytes, byte/row truncation,
ordered inline/oversized outcomes and last-delivered next_before. Oversized fields
are not clipped: read_field retrieves exact version-checked base64 chunks up to16KiB.
See [the precise page-v2 contract](WHATSAPP-BYTE-PAGES.md), including application vs
SQLite/upstream memory limits and no-progress refusal. Cursor_version1 remains a
numeric scoped live keyset window—not a pinned snapshot, signed artifact cursor or
cryptographic scope fence. Authorization is rechecked on each request. Mutable rows
can change; higher-ID inserts do not reorder the older continuation. Discovered chat listings and posting
unknown/blocked/retry evidence are bounded/scoped too; no reset/resend endpoint.
Malformed/status/broadcast/unapproved scope exclusions are visible as counts without
retaining their content/keys. The updated MCP refuses old servers lacking total-page
metadata rather than silently reverting to unbounded per-chat aggregation.
Each selected request is limited to256
exact IDs (or one explicit owner-wide request); arbitrary arguments cannot grant scope.
No arbitrary SQL, authentication-store or media-key access.
While serving, use authenticated `/status`; offline CLI `status` cannot take the owner
lock of a running server. Offline status has no live connection observation.

Existing `mcp-whatsapp.mjs`, compatibility read/lookup CLIs and the Lua WhatsApp facade
are repointed to `backend: linked_device`. A locally approved profile binds:

```json
{"resources":{"backend":"linked_device","account":"<exact-PN-JID>","generation":1,
 "connector_url":"https://<approved-private-host>/",
 "token_file":"<absolute-private-token-file>","ca_file":"<optional-trusted-CA-file>",
 "account_wide":true,"operator_account_read":true,
 "allowed_conversations":[],"language":"pt"}}
```

For a narrower profile omit both wide flags and set `allowed_conversations` to its
exact approved IDs. No existing/delegated profile is automatically widened. Operator
on-demand account reads use `scripts/whatsapp-read.mjs --profile-file <private-file>`
(or the explicitly configured read-only MCP); this does NOT remove the native
trusted-event guard. Raw API credentials are account-owner credentials; delegated
children receive only their scoped facade, not token values or arbitrary HTTP/FS.

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
