# Operator-directed WhatsApp management — 2026-10-17

## What is supported

A distinct, opt-in **operator-directed protocol text** path: prepare → approve →
send → inspect exact durable intent. New text and replies quoting an exact,
current, locally journaled plain-text message are supported. Existing bounded
find/read/search tools remain the navigation surface. No autonomous responder,
bulk send, media send, delete/block/group-membership operation, archive/mute/read
state control or cross-device draft inspection is added. Unsupported stays unsupported.

This is not a force flag for `whatsapp_send` or MCP `send_message`. Those GENERAL,
guest/child/event responder paths still refuse before reservation. Existing read
profiles, read tokens, scope ceilings, activation cutoff/PT language and transcript
outbox/unknowns are unchanged. No new native model tool or generic MCP registration
is introduced. Host remains capabilities, Lua remains the native agent-policy
boundary, Go owns this separately provisioned app protocol/journal capability.

A human's exact text/direct approval is sufficient content approval; do **not** ask
for it twice. The trusted operator/coordinator must still resolve the actual
recipient, inspecting exact IDs and provenance and disambiguating when necessary.
A sole pushname, an incoming instruction, a matching numeric PN/LID string or an
outgoing-only title is not identity proof. No Laura identifier is established here,
and nothing was sent. Her already-approved message must not be changed/prefixed.

## Separate authority, not a profile flag

The account OS owner/coordinator alone provisions this OFFLINE, after stopping and
settling only the exact owned service and retaining its stopped-state backup:

```sh
"$RELEASE/wa-whatsapp" operator-enable --state "$STATE" \
  --chats "$EXACT_VERIFIED_CHAT_JID" --approve-operator-management
```

`--chats` is a comma-separated, explicit selected set (1–256); there is no automatic
all-chat write grant. The set must fit the service's existing account scope. This
creates three NEW private files, refusing existing/partial setup rather than
rotating it: `operator-authority.json`, `operator-dispatch.token`,
`operator-approval.token`. They bind the exact account, generation and selected
IDs. Read-only `api.token` is not changed and cannot use `/operator/*`.
The API loads authority on service start. Logout/generation change invalidates it;
no auto-reprovision or generation reset. Partial setup requires owner inspection.

Approval and dispatch use different random 256-bit capabilities. Approval key can
only approve; dispatch key can only prepare/status/send. Neither annotations,
`approved:true`, caller role/scope, a profile path nor chat content creates authority.
Secrets are FILE references only, never arguments, output or logs. Only the
trusted operator/coordinator process may access approval credentials. Do not give
either key/config to a guest, child, event job or arbitrary MCP executable. They
are OS-owner bearer capabilities, not an OS sandbox or proof that a human actually
approved a sentence: provisioning delegates that responsibility to the trusted
operator process. A compromised process/OS owner holding both can send. Do not
provision where that trust is unavailable.

Create a restricted (Unix0600) private CLI config; values below are placeholders:

```json
{"kind":"whatsapp-operator-v1","account":"<exact-PN-JID>","generation":2,
 "conversations":["<exact-verified-chat-JID>"],
 "connector_url":"http://127.0.0.1:28787/",
 "dispatch_token_file":"<absolute-private-dispatch-token-file>",
 "approval_token_file":"<absolute-private-approval-token-file>"}
```

Execution-only operators omit `approval_token_file`. An approval-only process need
not receive the dispatch key. The config is not authority without its distinct
server-provisioned key and exact scope. Existing read profiles cannot be reused
as write profiles. No credentials are copied to Windows by this implementation.
Numeric loopback HTTP only; remote requires the existing approved private HTTPS/
trusted-CA transport (`ca_file` supported), never redirects, plaintext public ports,
insecure TLS, arbitrary HTTP passthrough or broader gateway rules by default.
The existing read-only proxy should continue denying `/operator/*`; adding private
write ingress is a separate coordinator decision, not necessary for server CLI use.

## Convenient supported CLI (trusted operator process only)

Use reviewed `scripts/whatsapp-operator.mjs` and its existing `mcp-whatsapp.mjs` /
`mcp-server-core.mjs` dependencies from the exact source/install script closure.
The Go ARM64 service bundle alone does NOT install Node/scripts or register a
native tool/MCP. On a server with the approved private config and native execution,
the assistant/coordinator can run this CLI there without a Windows secret copy.
Another node without that authority/transport cannot send. Coding workspaces and
lower profiles gain no remote/account grant. No shell/remote workaround is allowed
when the actual native context refuses execution.

For each action write a bounded private JSON request, then perform ONE call:

```sh
node "$SOURCE/scripts/whatsapp-operator.mjs" prepare \
  --authority-file "$PRIVATE_OPERATOR_CONFIG" --request-file "$PRIVATE_REQUEST"
# Same command with approve, send or status; never automatic retry.
```

Request shapes (no account/generation/role overrides):

* `prepare`: `{"conversation_id":"<exact-ID>","body":"<exact-approved-text>","reply_to":"<optional-exact-message-ID>"}`.
* `approve`: same recipient/body/reply plus returned `intent_id` and
  `approval_digest`. The trusted operator compares the returned exact body,
  account/generation, canonical/protocol recipients and quote with the actual
  human request before using its separate approval credential. Previously clear
  human approval need not be repeated; an unresolved recipient still needs resolution.
* `send` / `status`: `{"conversation_id":"<same-exact-ID>","intent_id":"<returned-ID>"}`.

The CLI makes one bounded HTTP call, does not retry and prints only the result.
Transport loss is not non-submission. Preserve the prepare result/ID BEFORE send;
inspect status with that ID after timeout/interruption. An unapproved send returns
its `prepared` state without sending; `ok:true` is not a `sent:true` claim.

Direct recipients require existing **reciprocal pinned-SDK PN↔LID mappings**;
missing/conflicting maps refuse, without name-based merges or hidden user lookup.
Self uses authenticated exact local SDK account/LID, not a chat title. Groups use
exact group IDs. The physical protocol destination and canonical PN identity are
frozen in preparation; dispatch checks the current mapping again. Quotes require
an exact current SAME-chat plain-text row (≤4096 bytes), sender/timestamp,
source/chat mutation proof and no later observed own reply. Media/unsupported or
unmapped/stale quotes refuse; reprepare/reapprove changed context, never silently
reuse stale approval. Ordinary reads do not mark anything read.

## Durable semantics and precise limits

* UTF-8 body maximum4096 **bytes**, no trimming, translation, prefix, clipping or
  malformed-surrogate normalization. HTTP request≤32768 bytes. Full exact text is
  retained privately. No long DB/identity/mutation lock is held through network ACK.
* Stable intent identity binds normalized account/generation, canonical recipient,
  exact body and reply reference; a preallocated SDK message ID is persisted BEFORE
  any external call. Preparation/approval additionally bind physical route,
  exact source fingerprint, mutation epoch and timestamp. Approval expires after
  ten minutes (a safety bound for NEW prepared actions, not transcript expiry).
* Dispatch is admitted under existing identity/mutation locks and persisted as
  `unknown` **before** SDK invocation. There is no reset/retry/new-id endpoint.
  The same prepared request returns its original actual status/message ID.
  Identical recipient/body/reply content is intentionally deduplicated for the
  entire generation, even after acceptance. Intentional identical repeats are
  currently unsupported, not an excuse to mutate whitespace or keys to resend.
* Any unknown operator intent holds further operator dispatches/preparations for
  that account/recipient/physical alias ACROSS generations; logout/reprovisioning
  cannot bypass uncertainty. Authenticated `/status` reports
  `operator_unknown_sends_all_generations` without exposing historical bodies.
  Old-generation detailed status stays outside new-generation API authority;
  stopped OS-owner inspection is available as
  `wa-whatsapp operator-inspect --state "$STATE" --intent-id "$EXACT_INTENT_ID"`.
  It is read-only, identifies historical/current generation and never authorizes
  replay, clears unknowns or claims live identity. Crash-before-call after intent, timeout, ACK loss,
  generic SDK errors and mismatched ACK all remain unknown. Only the owned adapter's
  typed proof of SDK non-invocation becomes terminal `not_submitted`; even that has
  no automatic retry in this initial path. A crash before intent leaves the durable
  prepared/approved action; no external call has been admitted.
* `accepted` means matching server ACK, NOT recipient delivery/read; a separate durable
  per-intent delivery/read state is recorded only from observed recipient receipts
  (see "Outbound delivery/read receipts" below) and reported by send/status, while
  absence stays explicitly unknown. `echo_confirmed`
  requires exact own ID + body + prepared chat or its independently SDK-verified
  physical route in the journal; similar text/timing is not reconciliation. No
  exactly-once/lossless protocol promise. Pinned SDK itself may retry encrypted
  frames under the same message ID; the app never starts another send for uncertainty.
  If selected ingestion excludes the physical alias, an echo may not arrive in the
  journal: status stays unknown rather than guessing. Missing upstream echoes can
  require indefinite manual reconciliation; no unsafe recovery shortcut exists.
* The adapter constructs only Conversation or ExtendedTextMessage/ContextInfo and
  calls pinned `SendMessage` with its preallocated ID. It never calls draft,
  composer, read-receipt, chat-open or app-state mutation APIs. Cross-device draft
  visibility remains **unsupported**, never absent; remote app UX/draft preservation
  has NOT been live-tested. Protocol text does not manage/certify any device composer.
  A known mutation racing AFTER final dispatch admission may already be in flight
  and cannot be retracted. The final adapter recheck narrows, not eliminates, that
  external race; no network-held lock or invented certificate is claimed.
* Existing historical transcript source/chat holds are never cleared. A NEW
  independently approved text is not a release/replay of those audio sources, so
  an existing historical hold does not alone forbid it. A NEW mutation after
  preparation invalidates approval; quoted replies still honor all holds. Global
  source-mutation epoch conservatively invalidates other prepared texts too,
  including repeated mutations whose old chat hold was already present.

## Provisioning rollback / coordinator acceptance

No worker installed, provisioned, paired, activated or used a real account. The
coordinator-reported live baseline is generation2 authenticated, private listener
127.0.0.1:28787, PT/all-chats, original activation1792254831, retained historical
holds/unknowns. This worker has not independently verified those runtime facts.
Do not rerun pairing/activation, change cutoff/STT or touch unrelated8787.

Coordinator: review exact integrated-source manifest/artifacts, stop/settle and
back up exact owned service, install through the existing reviewed immutable
installer, provision ONLY separately approved verified target IDs, restart exact
unit without activation changes, read back source/hash/account/gen/PT/cutoff and
both ordinary read and new capability-denial behavior. Perform an explicitly
approved notes-to-self test first; check visible exact text, draft preservation on
phone/linked devices, no read marking, durable ACK/echo and duplicates across a
normal restart. Do not deliberately create real unknown sends to test failures.
Then resolve Laura with real trustworthy recipient evidence, disambiguate if
needed, and use her existing exact approval. Report real acceptance separately.

To revoke: stop/settle exact service; privately quarantine the three new authority
files/config/credential copies (preserve them and every intent/unknown for
reconciliation); restart WITHOUT authority. Existing in-memory credentials remain
valid until that exact process stops. Never delete intent rows, restore old ready
state, rotate through unknowns or downgrade against a journal without checking
schema/lifecycle compatibility. No live rollback performed here.

## Focused source proof / evaluation

Synthetic Go fixtures use real SQLite and HTTP, separately provisioned test
capabilities, compiled pinned SDK, and a real Node CLI subprocess; transport sends
are fake. They exercise exact approval/Unicode/scope, malicious incoming text,
role/profile forgery, duplicate/parallel intents, crash/ACK loss, typed
non-submission, exact echo, mutation/precedence, PN/LID collisions and preservation
of historical holds. Existing transcript/lifecycle/page tests remain regressions.
Final operation IDs/logs/counts and the source-bound ARM64 bundle hashes are in the
settled worker report. Windows execution/cross-build is NOT ARM64 runtime proof.
No engine quality, real message/device behavior, production key/profile or service
change, UI publication, independent reviewer or full release gate is claimed.
`gate_verified:false`; `release_verified:false`.

Self-review found and fixed an actual first-generation single-connection deadlock:
preparation opened a transaction then read config through the DB instead of that
transaction. Timed-out generation `op-1792256217532998-16612-169` remains retained;
`op-1792256331136784-16612-175` subsequently passed54 Go top-level tests +2 mutation
subtests, zero skips. Later process fixtures/final closure are separate evidence.
Pinned SDK source inspection (`send.go191–480`) also caught PN→LID destination
rewriting: this path now freezes a reciprocal verified route before approval,
checks it before dispatch and sends directly to that exact route. No source-pin
or transcript rewrite was made.

A later retained generation (`op-1792256620603044-16612-307`) failed in a new
SDK-store fixture missing synthetic Account material (nil dereference), and the
expiry test exposed potential preparation-digest reuse under same-second/clock
churn. The fixture was completed with explicitly synthetic local SDK material
(no network/certificate/approval claim), and every reprepare now chains its prior
digest while rejecting future-dated preparation. Failed logs remain retained;
final passing generations are identified separately in the report.

Final focused closure `op-1792256785622798-16612-328` passed59 Go top-level
fixtures +2 mutation subtests, vet, fresh Windows build, real unpaired operator
and original lifecycle processes, source-root/embedded unchanged Lua boundary
(9+12 checks per mode), and all7 frozen-builder tests. The earlier Python builder
run had one explicit-WA_TEST_BASH skip; this closure supplied the admitted local
Bash path and exercised it, without relabelling that skipped generation. Separate
settled `op-1792256718584476-16612-316` passed19 Node tests,4 Python local/installer
and6 architecture tests, instructions and119 shipping checks. Logs remain under
`target/operator-*`; final manifest/source/artifact hashes are in the worker report.

Evaluation: harness used (owned worktree, exact edits, supervised operations);
graph used (ingest discovery/impact leads, not safety proof); code mode used
(two-file exact wiring edits). One code-mode edit preflight refused an accidental
ambiguous no-op (`old_text_ambiguous`), with no write; the corrected exact edit
was applied after inspection, not replayed as an unknown effect. One tools.lua
read used an out-of-range line and refused without effects; bounded grep/read
then inspected the real range. Subjective improvement: keep transactional config
reads on the supplied query handle and always inspect SDK destination rewriting,
not only method signatures. No recursive tool fixes or forced spell were started.

## Outbound delivery/read receipts — 2026-10-17 (source proof; live arrival unproved)

The pinned SDK (`v0.0.0-20261016130820-0b0a1cdac3e2`) emits `events.Receipt`
(`types.MessageSource` + `MessageIDs []types.MessageID` + `Type types.ReceiptType`;
`types/presence.go`, `receipt.go:handleReceipt`/`parseReceipt`). Only two of its
values are recipient delivery/read evidence for a message WE sent:

* `types.ReceiptTypeDelivered` (the empty string) — the recipient device received it.
* `types.ReceiptTypeRead` (`"read"`) — the recipient opened the chat and saw it.

Every other value stays explicitly unknown and is tracked only as a bounded ignored
counter: `sender` (one of OUR other devices, not the recipient), `read-self` (the
reader disabled read receipts; the official apps hide it), `inactive`, `retry`,
`played`, `server-error`, `peer_msg`, `hist_sync`. A `read` observation never by
itself becomes a recorded `delivered` observation.

`observeReceipt` matches a receipt to an existing durable intent by exact account +
generation + exact chat (or the physical route frozen at prepare time) + the stable
preallocated message ID. Body similarity, timing, display names and own echoes are
never used; an unmapped ID invents no intent; and only `accepted`/`echo_confirmed`
intents are projected, so a receipt can never settle, resurrect or replay an
`unknown`/held send and never triggers a resend.

Observed state is durable per-intent columns (`receipt_delivered`, `receipt_read`,
`receipt_basis`) plus a bounded `operator_receipts` audit table (newest 256 rows;
oldest audit rows are evicted inside the same transaction and the per-intent fact is
never evicted). `/operator/send` and `/operator/status` report
`recipient_delivery`/`recipient_read` as known AT RETURN TIME: the send deadline is
unchanged (45 s), no extra call waits for a receipt and a timeout/resend is never
invented. `wa-whatsapp status`/`/status` add the bounded `operator_recipient_receipts`
counters. A projection failure is a visible counter/event, never a sticky gap and
never a claim.

This is synthetic-fixture proof (real pinned SDK types, real SQLite/HTTP/process
boundaries). Whether a real receipt actually arrives on a real device, and how
quickly, is UNPROVED here: this worker used no real account, send or receipt.
Historical holds, unknown sends and the running service are untouched.

