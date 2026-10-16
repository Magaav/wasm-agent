# WhatsApp reliability review completion

This is the follow-up to the coordinator's seven findings against fdc79bfc/e1361075.
The older [delivery checkpoint](WHATSAPP-DELIVERY.md) and all of its artifact/log
receipts are preserved, not relabelled as activation proof. Current operating steps
are in [WHATSAPP-CONNECTOR.md](WHATSAPP-CONNECTOR.md). No live activation is claimed.

## Findings addressed

1. **Account-wide owner policy.** `init --all-chats` explicitly persists support for
   current/future supported direct/group/LID chats. Selected configs stay selected.
   Offline `scope --all-chats` pauses and establishes a new future cutover on later
   activation; existing approved queued work/unknown evidence is not reset. Newly
   observed supported chats are journaled/listed. Excluded malformed/status/broadcast/
   unapproved scopes have visible counters, without retaining their content/keys.
   Private PT setup now uses --all-chats. Native trusted-event scope is unchanged.
2. **One total page.** The operator's explicit private profile has resources containing
   BOTH account_wide and operator_account_read. Neither is a model argument. Narrow
   bindings send only their exact IDs to a server-side scoped query; there is no
   unrelated fetch/filter or per-chat network loop. Messages, discovered chats and
   posting diagnostics have bounded total pages, stable row-ID before/next_before,
   scope_kind, limit_scope:total, cursor_version1 and actual connection/gap/scoped
   observation metadata. The native event facade still asks for just its event chat,
   even when its profile contains operator-wide flags. Cursors are resource/scope/
   account/generation specific; new insertions do not reorder older row IDs.
3. **Durable callback contract.** The real adapter registers
   AddEventHandlerWithSuccessStatus. Journal/read/parse/panic failures return false,
   not the old wrapper's unconditional success. A separate fsynced sticky gap marker
   survives journal-only failures/restart. Sync/connection signals do not erase it;
   posting/activation stay held while it is unreconciled. If the marker itself cannot
   be written, a named fatal code78 stops the service and the generated unit prevents
   automatic restart for that code. No reset shortcut is exposed.
4. **Hard media payload bounds.** Runtime audio uses the pinned DownloadToFile through
   a non-embedding bounded File implementing Write/WriteAt/Seek/Truncate. Media HTTP
   separately caps declared/chunked actual response bytes and has a90-second deadline.
   Encrypted bound is20MiB+26, plaintext20MiB; plaintext allocation occurs only after
   validated file size and declared-size agreement. Temporary media is always closed/
   removed. No media keys/URLs are placed in error reasons. SDK SHA/MAC/CBC validation
   is retained, not replaced by a new protocol/crypto implementation. Limits are not
   a total process RSS or decompressed-history guarantee.
5. **Liveness/diagnosis.** Unexpected Serve termination becomes a named nonzero error;
   requested shutdown remains normal. Definite pre-dispatch refusal records retry time
   and reason, or permanent block, rather than pinning the oldest ready row. Other
   sources continue; prior multipart unknown/blocked parts still hold later parts.
   posting_status is bounded/scoped and exposes source/part/send-ID/state/reason/ack/
   retry evidence without reset/resend operations.
6. **Known source invalidation.** Authenticated exact protocol revoke/edit and SDK
   edit-ID mappings fence undispatched work; author/scope ambiguity holds only that
   chat. Owner DeleteForMe also fences a source arriving later; owner ClearChat/
   DeleteChat conservatively hold the chat, including full-sync signals. Compute
   rechecks before creating parts, dispatch rechecks under mutation serialization,
   and confirmed/unknown effects are preserved. Chat holds are visible in scoped
   chat inspection/listing. No original history or external message is deleted.
   Mutations received after dispatch cannot retract a submitted effect. Unmapped
   classes/held chats require separately approved reconciliation, not guessed IDs.
7. **Frozen build/provenance.** Explicit PYTHON3 or python3 is preflighted before
   compilation; Go executable hash/version are checked. Commit/tree are captured once.
   Git archive supplies all module/Go/STT/installer/notices/helper/license inputs.
   GOWORK is off, modules readonly and GOTOOLCHAIN local; buildvcs is false because
   manifest/source hashes carry provenance. Pre/post frozen/origin/member checks
   refuse source drift and retain partial failed output without a success manifest.
   Schema2 binds source files, artifact hashes, pinned SDK and private raw build logs.
   Installer rejects missing/inconsistent provenance, preserves safe paths/partial
   release behavior and never registers/starts a service or touches account state.

## Pinned SDK trace and limits

Inspected actual cached whatsmeow source at
`v0.0.0-20261016130820-0b0a1cdac3e2` (MPL-2.0), unchanged:

- client.go809–819 wraps AddEventHandler and returns true;995 dispatches bool handlers
  and returns handlerFailed on false. The adapter now uses the bool form directly.
- message.go1172 passes decrypted normal events to dispatch. Around459, failure
  returns BEFORE clearing buffered plaintext and before the later normal receipt.
  EnableDecryptedEventBuffer retains SDK replay material pending successful handling.
  This still depends on upstream redelivery/retention; it does not force replay.
- The automatic history loop around735 ignores callback result and then deletes
  history media. It is NOT used: ManualHistorySyncDownload and
  DisableManualHistorySyncReceipt are enabled. The owned callback downloads the
  notification, persists the entire idempotent batch, then issues its supported
  protocol receipt. It never calls DeleteMedia. Partial batch failure leaves the
  committed prefix deduplicated for replay and does not issue that success receipt.
- This is NOT universal receipt suppression or a lossless guarantee for all SDK
  classes/app-state paths. Gaps stay explicit. The restricted device/session store
  includes the SDK's replay buffer; it is not exposed as app journal/SQL access.
- download-to-file.go streams io.Copy into File, validates encrypted SHA/MAC,
  decrypts via cbcutil.DecryptFile and checks plaintext SHA. Its File wrapper is not
  os.File, preventing unbounded preallocation and ReaderFrom bypass. The HTTP cap
  also applies to oversized history media; history decompression/library/session
  allocations are not a claimed process-memory quota. Missing history/recovery
  classes produce sticky gaps, not a false caught-up state.

## Focused results and evidence

Settled operation **op-1792189057954140-18092-678**, exit0, complete output:

- Go28 top-level tests plus2 mutation subtests passed; vet and module verification
  passed. Actual pinned adapter compiled. Windows binary and Linux/amd64 cross-build
  retained under `target/whatsapp-review-final-1/artifacts/` (tested paths, not aliases).
- Node6 tests passed, zero skips. The old fdc MCP actually reproduced4 results for
  requested limit2 and2 network calls; new code returns one total scoped page.
- Python worker/installer4 and frozen-builder4 passed, zero skips. The old fdc builder
  actually emitted a mixed-source bundle in a private Git/fake-compiler fixture;
  new origin/frozen drift cases refused without a success manifest. These fixture
  artifacts are synthetic, not Linux runtime proof.
- Real unpaired executable HTTP/auth/generation/ownership/EN/PT/private-TTY checks
  passed. Native source and embedded WhatsApp9 boundary +12 scope negatives per mode
  passed, including proof that operator-wide profile flags do not widen event reads.
  MCP44 per mode and retained postcheck passed. Shipping closure and119 checks passed.
- SDK callback failure injection showed false status, one committed retry despite
  redelivery, idempotent partial history replay, sticky restart/sync gaps, preserved
  unrelated unknown effects and continuing safe ingestion. The old SDK wrapper's
  unconditional true is retained as a causal control, not claimed actual recovery.
- Private media checks cover actual HTTP chunked overflow/deadline, file-size mismatch,
  encrypted overhead, upstream integrity-error propagation, real SDK CBC File support,
  cleanup and ingestion while a download is blocked. No real account/media/QR used.

An additional operator-profile-file read assertion was added after that operation;
its separate focused result is retained with final completion evidence. Full source/
artifact hashes, original operation logs and source snapshots are in the final local
manifest; old fdc artifacts were not overwritten. A clean frozen real-source package
build/dry run, if performed, is explicitly distinguished there from the fake-compiler
causal fixture. No Linux executable/systemd/apply, cloud pairing or real post proof.

## Final admission follow-up

Post-matrix self-review narrowed the mutation lock to final source/config checking
and durable dispatch admission, not readiness or a network ACK wait. The owned
adapter also checks exact origin account/generation, source blocks and gaps just
before the SDK call. A typed proof that this live attempt did NOT invoke the SDK
can be scheduled as not-submitted; generic SDK errors, crashes and ack loss remain
unknown. There is no reset of a previously selected historical unknown. This avoids
a readiness callback deadlock and permits mutation persistence during external waits.

**op-1792189854949211-18092-715** settled exit0: Go30 top-level tests plus2 mutation
subtests passed, vet passed, new Windows/Linux cross artifacts built, real unpaired
process and native source/embedded boundary proofs passed using those retained paths
under `target/whatsapp-review-final-2/artifacts/`. The two added admission tests cover
mutation during readiness (no dispatch/no unknown) and typed no-submit retry while
an unrelated historical unknown remains unchanged. Wa's tested native artifact and
MCP44+44 proof are unchanged from final-1; no unrelated suite was rerun.

**op-1792189383424990-18092-694** settled exit0: the extra private operator-profile-file
MCP assertion and old-version fanout control passed (one focused Node test, no skips).

## Remaining boundaries / ownership

EN default/PT override and original-language task=transcribe remain unchanged.
No hosted translation/provider fallback, general AI reply, initial-history bulk post,
ten-minute expiry, draft visibility invention, browser fallback or unknown-send reset.
No agent.lua/wave_autoflush.lua or reporting-fix edits. No SSH/cloud/VM/container
workaround, service registration, real QR capture, messages, credentials copying,
Sentinel/runtime cleanup or installed UI change. The old production jobs/task/wrapper/
custom triggers, unknown sends and identity mappings retain the exact coordinator/
human cutover/removal conditions in WHATSAPP-MIGRATION.md. Source readiness is NOT
activation approval. Gaps/holds lack a blind reset path; actual reconciliation and
unsupported/live behavior remain explicit operational limitations.

## evaluation

**Harness: used. Graph: used. Code mode: used.** This supplements, not erases, the
cumulative findings in WHATSAPP-DELIVERY.md (SDK provisioning, recovered document
truncation,200-round guard reconciliation, prior fixture/formatting failures).

This run used new generations only. The first new MCP wide-read test caught an
over-escaped regex; explicit identifier/suffix checks fixed it without weakening
scope. The old-builder control initially failed because its Bash fixture used
ambiguous relative/drive paths and cleanup saw a transient directory lock. Read-only
resolution confirmed Git Bash, not WSL; explicit admitted WA_TEST_BASH and cygpath
fixed the private control. No Linux runtime claim or runtime-discovery fallback.
Original failed generations1–3 remain retained; generation4 builder tests passed.
The completion matrix above then passed. A final source-admission self-review found
and fixed the over-wide readiness/ACK lock; its two causal interleaving/proof tests
and final-2 outcomes are recorded above. A duplicate-path edit_many preflight refused
all effects and was regrouped without retrying an unknown effect.
No failure was relabelled positive.

Code mode helped replace the callback/identity sections against exact read bytes,
with original nested evidence retained. A range-edit echo exposed a duplicated
switch label left by my selection; it was corrected before successful compilation.
Read/format snapshots and complete compiler results, not receipts alone, were checked.
Graph search confirmed the live createWhatsAppAdapter definition; Go remains outside
its index and graph was not a completeness/correctness certificate. No tool repair
was attempted. Subjective improvement: keep exact-path private shell fixtures and
small test generations; no measured speed/token/quality or billing saving is claimed.
Windows/native/cross-build limits, existing Rust warnings, and missing real Whisper/
Linux/cloud proof remain candidly separate. No recursive wave/tool recovery work.
