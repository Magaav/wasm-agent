# WhatsApp source delivery checkpoint

Historical fdc79bfc/e1361075 checkpoint, not activation acceptance. The coordinator's
subsequent reliability findings and current completion are recorded in
[WHATSAPP-REVIEW.md](WHATSAPP-REVIEW.md); original evidence below is preserved.

## Scope and readiness

Self-review, not independent review. The linked-device replacement is implemented
in `connectors/whatsapp`, existing scoped MCP/Lua read boundaries and explicit
legacy retirement fences/tombstones. Source is staged/default-off, NOT installed,
paired or live-accepted. No real WhatsApp QR, account session, media, message,
provider login, hosted inference, cloud workaround, service registration or runtime
legacy cleanup was used. The reporting/wave fix already on main is preserved;
its installation is not installation of this WhatsApp delivery.

The service has separate device-key and message/audio/outbox SQLite stores;
per-state and per-account OS ownership locks; exact account/generation/chat scope;
private-TTY-only pairing; reconnect and partial-history reporting; durable off/on,
cutover and language settings; independent audio tasks and a warm offline worker;
source-linked, marked multipart posts for incoming AND own outgoing audio;
pre-dispatch uncertainty fences and exact echo reconciliation without auto-resend.
EN is the product default; PT is an explicit account setting, never a global
Portuguese default. Recognition language is not cross-language translation.
GENERAL model sends remain refused because cross-device drafts are unsupported.

Review followed lifecycle, transport identity/events, ingestion/task transactions,
account/generation/auth scope, language propagation, worker protocol, outbox crash
windows, private pairing, packaging and retirement. A new focused test proves that
persisted PT task language reaches recognition AND both-direction posted text,
even after the account default is subsequently changed to EN. Installer review
found and fixed relative-path acceptance and redirected destination ancestors;
copy verification now refuses changed artifacts while preserving a partial release.
No production access is needed or inferred for these local changes.

## Evidence, retained artifacts and test outcomes

Original completed verification: operation `op-1792184963627919-10512-733`,
settled exit0 with complete output and compiler helpers drained. It was launched
before the 200-round guard stopped the worker; it completed afterward. Its outcome
was reconciled, not blindly replayed. That exact operation passed:

- Release native `wa-host` build; Rust `wa-jobs`: 35 passed, no ignored tests.
- Go test suite (13 tests), vet, Windows connector build and Linux/amd64 CGO-free
  cross-build. The actual pinned adapter and SQLite implementation compile.
- Real unpaired executable/HTTP/SQLite process checks: EN/PT persistence, auth,
  generation, second-owner refusal and captured/non-TTY pairing refusal.
- Native WhatsApp boundary: source + embedded (6 boundary checks and 12 scoped
  retirement negatives per mode). Native MCP: 44 checks per mode plus retained post.
- Python: 4 tests; Node MCP/retirement: 16 passed, zero skips. Import-closure positive
  and missing-module negatives; deployment-shipped checker: 119 checks.

Continuation focused proof: `op-1792185725857315-18092-4`, settled exit0:
Python4 again for the installer hardening, plus the NEW persisted-PT-to-recognition/
posting Go test (1 passed). It did not rerun the already completed whole suite.
The earlier direct-workflow instruction mutation proof passed45 with zero skips.
No full release gate, paid inference or visual/UI test was run. UI code is unchanged.
Actual Linux execution/systemd/apply, production Python dependencies/real weights,
recognition quality, private pairing and real media/posting are NOT proved.

Retained artifact manifest (local, ignored evidence, not an installed/release slot):
`target/whatsapp-retained-completion-1/manifest.json`. It records FULL original and
retained paths, SHA256s for tested Windows Go/Linux Go/native wa binaries, original
logs/operation IDs, source snapshots/patch/deletions, SDK receipt, dependency pins,
license texts and native receipts. The binaries were built from a DIRTY candidate
based on476ccb75, not a clean final release. Source hashes bind that fact honestly.
Coordinator performs the final clean canonical build before any approved install.

The private enable-guard-removal Rust negative is retained in
`target/wa-retirement-mutation/enable.stdout` and `.stderr`: removing the guard
allowed enabling the retired job, and the intended `unwrap_err` assertion FAILED.
The outer collector exited1 because it incorrectly looked for the panic text in
stdout (Rust wrote it to stderr). It is NOT a failed positive suite and NOT a
successful collector receipt. The claim-removal second case did not run; no result
is invented for it. No production state was modified by the private mutation.

Upstream pin: whatsmeow `v0.0.0-20261016130820-0b0a1cdac3e2`, full origin
`0b0a1cdac3e2a20d1436127d860bfe0c2b8ac9de`, MPL-2.0, unmodified.
Go module graph/sums are pinned and `go mod verify` passed. License/notice texts
for61 upstream modules are retained in `THIRD-PARTY-NOTICES.txt`; connector code
uses the repository MIT license. Faster-whisper1.2.1 MIT wheel metadata/hash is
recorded separately; the platform-specific Python dependency environment is not
fully locked or production-installed by this worker.

## Remaining work and exact operator path

Complete human commands, private QR precautions, PT configuration, warm-cache
provisioning, user service setup, backup and rollback:
[WHATSAPP-CONNECTOR.md](WHATSAPP-CONNECTOR.md).
Exact check/apply and retained object owners/removal conditions:
[WHATSAPP-MIGRATION.md](WHATSAPP-MIGRATION.md),
[whatsapp-retirement.json](whatsapp-retirement.json),
[source reference enumeration](whatsapp-reference-inventory.json).

The coordinator/human must freshly inventory/disable/settle the exact old jobs
(copilot, events, wake-selftest, ingest, message, source, transcribe), Windows
`wasm-agent-whatsapp-chrome` task/wrapper and any custom triggers/launchers through
supported ownership/hash-matched procedures. Old installed copies/active owners
remain unverified; this worker did not touch them. Legacy triggers with no narrow
supported retirement API are explicit blockers, not permission to edit runtime DBs.
Preserve ledgers, transcripts, drafts, browser profile and unknown sends. Unverified
identity/message-ID mapping stays read-only/quarantined, never auto-imported/reposted.

Source tombstones and the retired job template remain to overwrite/refuse old
entrypoints during cutover; coordinator removes them and their shipping reachability
only after installed references and private paired cutover are proved retired.
The scoped facade/effects and historical ledger remain for safety/evidence. The pure
Rust formatter remains source-only historical ABI compatibility, not a second stack.
Original documents/test texts remain explicit unshipped history, not executable fallback.

The worker still has no supported cloud execution context. Human authorized terminal
installation, private phone QR, exact account/chat binding, HTTPS proxy/authorized-device
credential provisioning, actual Linux runtime and real original-chat delivery proof
remain separate. No remote refusal was bypassed. The cutover receipt is a human
attestation, not a cryptographic or automatic production-retirement certificate.
`gate_verified:false`; `release_verified:false`.

## evaluation: cumulative session, including interrupted run

- **harness: used.** Managed worktree routing in Bash/operation/code mode reported
  the owned checkout. The original preflight-only stop was inadequate: missing Go
  was resolvable, and HEAD405 did not test HTTPS GET. Authorized private provisioning
  verified the official SDK hash before execution; successful extraction/version is
  `op-1792182798729860-10512-211`. Two prior Python quoting syntax failures happened
  before extraction; known outcomes were reconciled, not unverified archives executed.
  No global SDK install/PATH change or cloud execution workaround occurred.
- The 200-round guard was not changed. It interrupted reporting after launch, not
  the successful final checks. This continuation consumed settled733 evidence and
  ran only affected new proofs. Subjective improvement: use bounded checkpoints
  and earlier evidence/artifact retention rather than accumulating a 200-round run.
- Native MCP initially failed because its private fixture created only `meta`, while
  real dispatch now queries `sessions`. `memory.setup()` supplies the full PRIVATE
  schema; production workspace/scope guards were not weakened. Final MCP44+44 passed.
  A mistaken `-p wa-sentinel` workspace invocation was corrected to its separate
  Cargo manifest for a source compile check, not a live Sentinel operation.
- The shipping fixture had a stale copy-loop marker and omitted MCP/web siblings.
  Its source-derived import closure and synthetic missing-import negatives were
  updated; actual119-check shipping proof passed. Existing Rust dead-code/unused
  warnings and the effective PS1 CRLF-attribute warning remain visible; no unrelated
  files/global line-ending settings were normalized or warnings concealed.
- **graph: used.** `search_symbols(resolve_route)` helped locate the live Lua
  boundary but also returned a historical duplicate. `impact` returned zero changed
  symbols and coverage gaps for the shell-heavy patch; Go writes reported
  `not_indexable_source`. It was NOT used as complete impact/correctness proof.
  Subjective/untested improvement: clearer staged/unstaged/top-level coverage and Go
  indexing would make this task's graph review more useful. No graph fix was started.
- **code mode: used.** Native serial writes/reads supported the bounded retirement
  edits; original nested outcomes were retained. The initial aggregated doc read was
  truncated (result `fdc036444af5eddc93b96f238872f11ff9c2ff8509899762955b248031dfe6ee`);
  all four required original docs were subsequently read in complete bounded pages.
  Exact edit preflight refused ambiguous/missing selectors with effect:none; rereads
  and exact replacements avoided guessing. Some batch receipts were verbose.
  Subjective improvement: smaller content-budgeted document batches and reading
  after formatters change whitespace. No claimed token/speed/quality saving.
- The negative collector's stdout/stderr assumption is recorded above rather than
  relabelled as positive success. This continuation found a real installer issue and
  added causal language-flow coverage; Python4 + focused Go1 passed. The ancestor
  symlink test is synthetic, not a claim of Linux filesystem/apply verification.
- Continuation graph `impact(source=git)` returned changed_lines0 after the full
  104-file delivery was staged. That is explicitly NOT coverage of the staged diff;
  source inspection/tests remain the evidence. Clear staged-patch reporting is a
  concrete improvement request, not a new tool-repair task.
- Staged diff-check found one trailing space and an extra final blank in generated
  license notices. Only those whitespace defects were corrected; original bytes are
  retained and license tokens compared unchanged. The first Python text comparison
  hit Windows' default cp1252 decoder; the corrected check compares bytes, not a
  guessed locale. PS1 effective CRLF warnings remain disclosed, not bypassed.
- No billing/quality/latency metric is inferred from tool calls, and continuation
  packets are not counted as separate inference spend. Internal evaluation is not
  included in transcript bodies or any WhatsApp outward post.
