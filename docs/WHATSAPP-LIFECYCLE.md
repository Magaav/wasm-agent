# WhatsApp lifecycle: local pairing, authentication and reconciled recovery

This is a source reliability follow-up, NOT a diagnosis of the first live phone
error and NOT live acceptance. Coordinator reports original pair-command exit0,
then OFF-service HTTP200 followed by exact HTTP403 `scope_mismatch`; supported
stopped offline status independently established generation2, PT/all-chats,
requested_on:false, activation0, unknown_sends0 and no persistence gap. The owned
service is stopped/inactive. Original receipt/backup remain preserved. The first
private terminal stdout was intentionally not recorded; human confirmation of the
scan and initial nonsecret failure is pending. No historical reason can be invented.
The repeated `existing_setup_attempt_tell_agent_to_reconcile_do_not_replay` refusal
is a recovery guard, not the root of the original failure. Its implementation and
receipt were NOT changed by this worker. Do not delete it or repeat task retirement.

## What the actual pinned SDK establishes

Inspected `go.mau.fi/whatsmeow v0.0.0-20261016130820-0b0a1cdac3e2`, verified via
private module cache/go.sum (original files retained/hash-bound in new evidence):

- `pair.go132–159`: PairSuccess dispatch follows successful `handlePair`.
  `handlePair` verifies HMAC/signatures, sets device identity, calls Store.Save,
  stores main-device identity, marks expected disconnect/paired, then sends the
  pair-device-sign confirmation. `pair.go260–266` deletes local state on confirmation
  send failure and returns an error; success returns only after that send completed.
  This is NOT a server authenticated-login acknowledgement.
- `qrchan.go189–208`: PairSuccess becomes QR-channel `success`; PairError becomes
  an `error` item; the QR channel closes. `types/events/events.go49–51` explicitly
  says pairing handshake completion generally precedes a websocket reconnection;
  wait for Connected before sending. QR success does not mean continuing login.
- `client.go690–739`: Disconnect stops the socket/response waiters, not Logout or
  Device.Delete; manual disconnect emits no Disconnected callback. It is not itself
  the SDK operation that unlinks/deletes a saved device. A new fixture actually
  saves a SYNTHETIC SDK device, calls the owned Close/real pinned Disconnect,
  reopens its SQLite store and retains its local ID, while IsLoggedIn remains false.
  This tests local persistence, not a real cryptographic handshake or phone policy.
- `connectionevents.go27–39` handles post-pair code515 by explicitly disconnecting
  and reconnecting (unless DisableLoginAutoReconnect is set; ours does not set it).
  `client.go642–665` ordinary autoreconnect cancels on expected disconnect/context
  cancellation. Thus immediate owned Close can end the pair process BEFORE its
  first authenticated reconnection. It does not prove an erased local pairing;
  later OFF serve is a separate login attempt. Whether that interruption caused
  this account's later rejection is unproved, not a basis for a guessed delay.
- `connectionevents.go158–205`: authenticated success sets IsLoggedIn and then
  asynchronously performs prekey/passive setup before Connected dispatch.
  `client.go679–680`: IsConnected means websocket connectivity, NOT authentication.
- `connectionevents.go102–154`: typed on-connect failure codes401/403/406 dispatch
  LoggedOut **in a goroutine before Store.Delete completes**. A failed Delete
  retains the ID (`store/store.go286–299`). Stream device_removed also dispatches
  LoggedOut with OnConnect:false before deletion (`connectionevents.go40–47`).
  SDK code labels do not independently prove human unlink, ban or the phone's intent.

**Conclusion:** closing after QR success is not shown to erase a completed local
pairing. The source/fixture do NOT establish that early Close caused the live
rejection, nor prove it harmless to every server-side onboarding sequence. No
speculative sleep, new timeout/default or wait-for-Connected pairing-success
condition was added. Pair still returns at verified local SDK pairing completion,
with privateTTY and ownership locks unchanged. Production cause remains unknown.

## Proven defect and essential safe diagnostics

Old `LoggedOut` already called setState(needs_pairing), which immediately cleared
`verified`. The lead that it simply forgot to clear that bit was NOT correct.
However old identity() could subsequently set it true again using the retained SDK
ID during the asynchronous deletion/failure window. The causal fixture deliberately
retains that ID: the old local-ID-only rule would accept it, while the new code
refuses lookup and late Connected/OfflineSyncCompleted callbacks.

New behavior:

- Logout atomically persists paused policy, advanced generation, zero activation,
  `pairing_required:true` and typed logout evidence. A serialized in-memory latch
  also refuses revalidation if that transaction fails; failure retains a sticky gap.
  Unknown sends/old journal/audio/transcripts remain unchanged. No keys are deleted
  or restored by this new code and no generation is reset.
- identity() and lookup_self cannot resurrect a logged-out session. lookup_self
  rechecks exact generation under the same identity lock. Only the existing
  HUMAN-privateTTY QR success path can clear the latch, after exact SDK local ID,
  nondeleted-store and unchanged pairing-generation checks. There is no reset API.
  A delayed old-generation pairing completion cannot clear a newer logout.
  Do not downgrade to pre-fence releases against a newer journal: old binaries
  ignore pairing_required and cannot enforce this rejection latch. Preserve stopped
  state/unknowns for reconciliation instead of restoring older keys or ready rows.
- `status` (CLI and authenticated API) adds `session_observation`. It stores only
  three bounded projections: last_event, last_logout and last_pair_success, each
  with fixed event enum, local timestamp, generation, allowlisted SDK reason code/
  classification and on_connect. Unknown reason values collapse to code0 and
  `unknown_or_not_applicable`; no arbitrary raw integer/string is echoed.
  SDK errors, Raw nodes, message/header/body text, business names, IDs, QR, keys,
  credentials or key-derived hashes are never copied into these diagnostics.
  Failure transaction rollback/non-disclosure are tested with synthetic sentinels.
- Fixed event names: pair_success_local, connected, disconnected, logged_out,
  connect_failure, client_outdated, temporary_ban, stream_replaced. OnConnect is
  meaningful for logout/connect failure; other events use false. Known reason
  classes are SDK classifications, NOT an established human/root-cause explanation.
- Terminal-only pairing errors/cancellation now have named fixed refusals. SDK
  QR-channel Error content is never printed/logged by these paths. Clearing the
  terminal/TTY restrictions remain; no real QR was generated by worker fixtures.

## Exact status meanings (do not conflate them)

- `runtime:offline_cli`: local_identity and authentication are `unobserved`.
  Offline status does NOT open/read device keys to certify a stored pairing, and
  `connection:disconnected` is not proof that pairing is absent or that login failed.
- `runtime:live_adapter`, local_identity:`matched_local_sdk_store`: exact account
  matched the local SDK ID under the current generation/fence. This is not live
  authentication. `lookup_self.identity_basis` says that explicitly.
- authentication:`authenticated_event_observed`: this process observed Connected;
  disconnect/logout/connect failure/replacement/close invalidate that observation.
  It is not a promise of continuing future connectivity. `not_authenticated` means
  no currently retained positive live event, not a guess about a phone's account.
- last_pair_success is a historical local completion record, not present key-store
  inspection. last_logout survives restart; last_event can be replaced by a later
  lifecycle event. Timestamps are local processing observations, not exact upstream
  causality/latency. Record generations distinguish historical events from current.
- `pairing_required:false` is NOT positive stored-pairing or authenticated proof.
  Older releases did not record this latch/typed metadata. Missing historical
  lifecycle rows remain null; no old reason is backfilled or inferred from generation.
- Authentication, OfflineSyncCompleted and `connection:connected` still do NOT
  certify total history/media coverage. Coverage remains partial, gaps are sticky,
  and requested_on/activation/PT policy/unknown sends are independently checked.
  The one-shot readiness CLI now additionally requires explicit authenticated-event
  observation; old servers without it are not silently certified ready. Whisper
  and real delivery remain separately unverified by that CLI.

## Coordinator/human handoff — no worker production effects

1. Retain the original human attempt, exact disabled-task readback, stopped backup,
   service reconcile receipt and all unknowns. Coordinator's original reconciliation:
   `/home/ubuntu/.wasm-agent/session-scratch/66393336386465352d303934312d343835342d613762352d643736346234633738343663/whatsapp-live/service-reconcile-1/receipt.json`,
   operation `op-1792248217347082-491509-70` (coordinator-reported, NOT worker-run).
   Await the human's nonsecret first-error/scan clarification; do not infer unlink.
2. Coordinator alone may deploy/read back the reviewed source-bound ARM64 artifact
   after supported reconciliation. Preserve the reviewed unit/drop-in selecting
   127.0.0.1:28787 and its exact owner. Port8787 belongs to unrelated space-serve:
   neither change global defaults nor touch that owner. No worker deployed anything.
3. Keep posting OFF. Read supported stopped status and current generation; no key
   inspection. Preserve latest state, never restore old keys or a ready outbox,
   reset generation, clear unknowns or fabricate a successful pairing attestation.
4. Coordinator prepares a **phase-specific, HUMAN-ONLY private pair resume**, ONLY
   if current supported state and human clarification actually require it. Reference
   the original receipt/reconciliation instead of deleting the first-attempt guard
   or rerunning already-completed task/browser retirement. No model/tool may run pair,
   synthesize a TTY, relay/capture a QR or inspect session keys. An already_paired/
   generation-changed refusal requires reconciliation, not forced deletion/replay.
5. A human pair exit0 means local SDK pairing completion only. Coordinator then
   observes normal OFF serve using the exact verified process/listener before any
   credential use, exact current account/generation, authenticated event, lifecycle
   records, policy and gaps. Preserve exact HTTP code AND error: HTTP403
   scope_mismatch alone is not proof of a particular upstream logout reason.
6. If logout recurs under the new source, retain its typed reason/on-connect/time/
   generation without verbose SDK/network logging. Keep service/posting paused as
   appropriate and reconcile; do not automatically pair again. No policy bypass.
7. Existing native Linux/STT passes reported by coordinator remain evidence for
   their original source, not proof this new artifact ran there or onboarding works.
   Incoming/own-outgoing audio, selected reads/search, restart/backlog/no-duplicates,
   process/model readiness and latency still need actual human/transport acceptance
   under [operability](WHATSAPP-OPERABILITY.md). No E2E success is claimed here.

## Focused source proof (self-review, not production acceptance)

Settled `op-1792249050145977-4420-88` passed44 Go tests plus2 mutation subtests
with `-count=1`, vet, a fresh Windows executable, real unpaired HTTP/process checks,
CLI/MCP navigation. The native wa host was not rebuilt. Six new Go tests cover retained-ID resurrection, durable restart fence,
actual SDK Disconnect/local persistence without authentication, raw-content/unknown-
enum non-disclosure, exact/nondeleted pair identity and atomic failure/gap handling.

Settled `op-1792248939630001-4420-82` separately passed8 Node tests (including the
new authenticated-readiness positive/negative fixture), zero skips, and119 shipping
checks. Earlier test generations remain retained. Logs are under the owned checkout's
`target/lifecycle-*`; the final source-bound ARM64 manifest/evidence receipt and
source hashes are identified in the settled report. No real pairing, network login,
production keys/messages, service deployment, provider/STT change, UI work or full
release gate. Root-cause uncertainty and the missing original private error remain.
