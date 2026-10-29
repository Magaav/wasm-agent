# WhatsApp observed names and mutation-hold coverage (2026-10-17)

## Outbound receipt observation added — 2026-10-17 (source fixtures only)

Our own outbound operator text now has a durable, honestly-caused delivery/read
state. It is observed only from the pinned SDK's `events.Receipt`, matched to an
exact durable intent by account/generation/exact chat (or frozen physical route)
and the stable preallocated message ID. Only the SDK's `delivered` and `read`
values advance it; `read-self` (recipient disabled read receipts), `sender`,
`inactive` and every other type stay explicitly unknown. No time/echo/body/display
trace is used, an unmapped receipt invents no intent, and a receipt can never
settle or replay a hold/unknown send. State is per-intent, survives restart, and
is reported by `/operator/send`, `/operator/status` and the bounded
`operator_recipient_receipts` counters in `/status`. Receipt arrival on a real
device remains unproved; historical holds/cutoff/language/scope are unchanged.

## Verified coordinator snapshot — not worker production inspection

Coordinator reports source45f34261170017e6927cd8c4ef02b9f65411d30c authenticated/
connected under exact account/generation2, positive authenticated-event status and
lookup_self, and request-bound local installation81/81. The original phone setup
failure cause is still unknown; success is NOT attributed to a particular source fix.

Metadata-only audit `op-1792254148139232-491509-97` observed901 journal chat rows in
two bounded live-keyset pages:562 LID,279 PN direct,60 group;71 observed labels and
830 unobserved labels. A positive observed-name query returned2 rows. This is NOT
whole-account/people/history completeness proof; IDs are not deduplicated by names.
36 chats held `unproven_mutation_chat_hold`;508 audio tasks were blocked_source,
380 initial-history tasks journal_only; no unknown sends or persistence gap were
reported. Missing labels do not establish a protocol failure.

Coordinator independently retrieved original posting/PT approval and activated
NEW eligible recordings with supported stop/activate/start (`op-1792254829394518-491509-103`):
cutoff1792254831, requested_on:true, generation2, PT/all-chats; user service boot
enabled, authenticated/connected, readiness exit0, all36 holds preserved. Matching
service restrictions also passed the small-model --check. These are coordinator-
reported original-source observations, not worker-executed production proof.
Actual incoming/own outgoing audio delivery, warmth/latency and full reliable
coverage remain unverified in this source report; user samples may arrive meanwhile.
Do NOT rerun pairing/activation or change that running service from a worker.

The already-proved on-demand route is approved native peer → SERVER-side Node CLI
→ stdio MCP → numeric loopback Go API on127.0.0.1:28787, with the private profile
and token FILE remaining on server. No generic LOCAL MCP registry is configured;
no exposed HTTPS port, credential copy or new anonymous peer capability was needed.

## Source finding: names were only opportunistically observed

Prior source stored history conversation labels, live direct push names and group
join/rename events. It never looked up SDK contact-cache labels or mapped PN/LID
contact metadata, nor explicitly fetched missing group metadata. Accordingly many
observed IDs can remain unnamed even when supported SDK metadata is available.
No real contact store, title, chat ID/body, media or key was read by this worker.

### Explicit bounded enrichment, not a new daemon/control plane

`list_chats` adds optional `refresh_names:true` and exact conversation_id narrowing.
The existing CLI adds `--list-chats --refresh-names` (optional `--chat`). It enriches
ONLY rows already observed in this exact account/generation and approved read scope:

- Same server-side readScope and live row-ID window; maximum32 rows per explicit
  refresh request, default32 for refresh. Query must be empty during enrichment;
  perform literal name/identifier search AFTER the bounded refresh. Ordinary
  nonrefresh listing/search retains its existing row/byte limits.
- Supported SDK Contacts.GetContact for the original exact ID. For a missing direct
  label, use SDK LIDs.GetPNForLID/GetLIDForPN and require reciprocal mapping before
  copying the counterpart contact LABEL. No display-name matching or chat merging.
  Prefer FullName, FirstName, BusinessName, then PushName when Found=true; never
  turn a redacted phone fragment into a name. title_source records the field and
  `via_sdk_lid_map` provenance. These are untrusted labels, not real-world identity.
- Only observed permitted group IDs use SDK GetGroupInfo; at most3 group requests
  per page, each context-bounded2 seconds, overall refresh context8 seconds. No
  GetAllContacts, GetJoinedGroups, member-query fanout or forced full resync. SDK
  GetGroupInfo can itself maintain its normal participant/identity caches, but
  those participants NEVER become app conversations merely because of this query.
- Authentication/local identity/generation/scope are checked before AND after each
  lookup; publication has a short identity/generation fence and optimistic chat-row
  version check. Metadata reads occur with no journal cursor/transaction or identity
  lock held, never inside SDK persistence callbacks or on ingestion/STT call paths.
  One in-flight refresh is admitted; concurrent requests return busy, not queued work.
- Existing explicit live labels win over weaker cached/query enrichment in `title`.
  A separate `metadata_title`/source/observed_at label preserves the SDK contact label
  as searchable data even when a peer's live PushName differs from the saved name.
  `names_version:1` advertises these additive fields. Query searches BOTH labels and
  exact ID without merging rows; duplicate names remain distinct IDs. The updated
  counter counts cache publications; preserved counts primary live labels or skipped
  changed rows and need not be disjoint from updated.
  A live update during a lookup cannot be overwritten. History cannot overwrite
  enriched labels. Cached contacts are not certified fresh phone address books.
- Output `name_refresh.version:1` includes checked/updated/missing/failure/preserved/
  deferred-group counts and named partial/cancelled/deadline/auth/scope/cache-error
  status. The last completed attempt is separately retained for safe aggregate
  status. There is no automatic retry, watcher, Jobs/LLM wake or account-wide loop.
  Missing metadata remains missing, not an invented label or a completeness claim.

The unchanged page_version2/cursor_version1 contract still applies:4MiB encoded
ordered page, total row limit, last-delivered before cursor and exact versioned
oversized-field recovery. Name writes update existing read_versions; stale field
reads refuse409 rather than mix names from different versions. Added report fields
fit the reserved envelope and final byte check. Older servers explicitly refuse the
new request or lack required name_refresh v1; no browser/unbounded fallback/replay.
SDK/network/contact-store allocations and SQLite internals are NOT a process RSS
quota; bounds here are request work, deadlines, persisted name size and wire bytes.
Refresh counters describe the bounded planned keyset-row window; byte truncation and
concurrent label changes can make delivered outcomes differ. Always follow the
actual ordered page/next_before, not metadata-query counts; refresh an exact selected
ID when needed. Names and refresh reports are not a pinned snapshot.

## Source findings: why future initial-sync mutations can hold too broadly

Pinned SDK `types.MessageSource` exposes SenderAlt/RecipientAlt (message.go88–184)
for PN/LID addressing. The old mapper compared raw RemoteJID and author strings.
An AD-qualified remote or authenticated alternate address could therefore fail
scope/author equality despite referring to the same exact source within its chat.
New mapping normalizes ToNonAD, uses ONLY typed SDK alternate fields with correct
DM sender-vs-recipient semantics, and retains author alias provenance privately.
Names/contact labels NEVER authorize a mutation. Separate stored chat IDs are not
collapsed or granted cross-conversation read authority.

Pinned SDK ParseWebMessage (client.go1021–1083) unwraps history edits and may replace
Info.ID/Message while SourceWebMsg still holds the original protocol key. The
mapper now unwraps that original SDK source container before projecting exact key
ID/scope. It does not guess a source by title, timestamps or edited text.

More importantly, old persistHistory ingested received items in one pass. A revoke/
edit preceding its original source could not find stored author proof, so mutate
held the WHOLE chat. A causal fixture using actual SDK ParseWebMessage reproduces
this old order and blocks unrelated audio. The new FUTURE-batch sequence is:

1. Persist only permitted original SDK author headers for that received batch.
2. Apply its mutations with exact source/author/scope proof BEFORE audio admission.
3. Journal ordinary messages/audio using existing activation/language/exclusion rules.

Headers are staged without accumulating another copy of all bodies/media and without
network reads. Conflicting headers become ambiguous, never guessed. This permits a
source-specific fence when actual same-batch original author proof exists, regardless
of received order. It does NOT trust a mutation's own asserted target author as proof.
Missing originals outside that batch, mismatched authors, unsupported mappings,
ambiguous headers and unproven scopes still hold conservatively. Group-admin revoke
permissions and cross-chat PN/LID history reconstruction are not newly inferred.
Owner DeleteForMe/ClearChat/DeleteChat protections remain; known owner chat operations
have accurate owner-scope diagnosis rather than being mislabeled unknown remote scope.

These are proved SOURCE possibilities, not an attribution of the existing36 holds.
No historical event buffer was replayed or history resync forced. No initial-history
bulk compute/post, gap/unknown reset, expiry or general AI sends were added.

## Historical holds remain unresolved; aggregate status is not a new gate

No code clears/reclassifies an existing hold or reopens blocked_source audio on its
own. Since 2026-10-27 the offline, operator-run `requeue-held-audio` (dry run by
default) can requeue audio held only by a posting-only hold; legacy-hold audio needs
an explicit flag (WHATSAPP-TRANSCRIPTION.md).
Future exact mutation evidence and fixed proof/decision enums are retained in the
private journal. New hold-origin markers are created ONLY when this code actually
inserts a new hold; later observations cannot fabricate an origin for an old hold.
Thus the existing36 reason-only holds remain unresolved even if new author/label
metadata becomes available. The508 reported blocked tasks are not reopened.

Status adds `coverage_status.version:1`: observed/named/unnamed journal-row counts,
held counts, historical reason-only hold counts, bounded refresh status and aggregate
future mutation diagnosis. inspect_chat adds only exact-chat aggregate diagnosis.
No bodies/names/IDs, raw SDK errors/nodes, keys or credential-derived hashes enter
aggregate diagnostics. Counts are processing observations, not unique mutations or
proof of historical origins. The readiness CLI reports warnings and explicitly says
transport/policy only; unnamed/held rows do NOT introduce a global audio gate.

Safe reconciliation is separate work requiring item-pinned operator approval and
original authenticated mutation evidence: exact account/generation/chat/source ID,
mutation kind/scope, original author or supported SDK alias proof, provenance/order,
and dispatch/unknown-effects inspection. Old reason-only records may lack that proof;
new contact names/current maps or a later source row cannot manufacture it. There is
NO blanket reset/reconciliation command in this delivery. A future bounded evidence
read/application surface would need its own reviewed authorization and no-repost
proof; private journal evidence retention is not an arbitrary SQL/keys API.

## Coordinator handoff after source acceptance — no worker production actions

Use the existing authorized native peer and SERVER-private profile, NOT SSH from a
worker/model tool or a new public port. After supported coordinator-only deployment/
source/readback, examples executed on server through that existing approved route:

```sh
node scripts/whatsapp-read.mjs --profile-file "$PRIVATE_SERVER_PROFILE" --list-chats --refresh-names --limit 32
# Keep scope/window consistent; use returned next_before for another explicit page.
node scripts/whatsapp-read.mjs --profile-file "$PRIVATE_SERVER_PROFILE" --list-chats --refresh-names --limit 32 --before "$NEXT_BEFORE"
# Or refresh just ONE already observed permitted exact ID, including deferred groups:
node scripts/whatsapp-read.mjs --profile-file "$PRIVATE_SERVER_PROFILE" --list-chats --chat "$EXACT_CHAT" --refresh-names --limit 1
node scripts/whatsapp-read.mjs --profile-file "$PRIVATE_SERVER_PROFILE" --list-chats --query "$UNTRUSTED_LABEL" --limit 20
node scripts/whatsapp-read.mjs --profile-file "$PRIVATE_SERVER_PROFILE" --chat "$EXACT_CHAT" --query "$LITERAL_TERM" --limit 50
node scripts/whatsapp-readiness.mjs --profile-file "$PRIVATE_SERVER_PROFILE"
```

Use CLI/MCP scripts from the SAME reviewed source commit (their hashes are in the
source evidence), not a stale installed script. The frozen service bundle binds Go/
STT/installer inputs; the reviewed Git tree separately binds these read seams.

No automatic name sweep is enabled. Choose exact IDs when labels duplicate; don't
merge PN/LID chats by title. Read only relevant bounded context/transcripts. Check
partial refresh, field versions, source freshness and per-chat holds. Preserve current
activation cutoff/PT/all-chat policy, boot/drop-in/listener ownership and all unknowns.
No re-pairing/profile widening or initial-history posting is required by this change.

Coordinator must still prove new-runtime SDK labels/map availability, selected-scope
and group-query behavior, unchanged historical holds, source/readiness coverage,
real incoming AND own outgoing local transcript posting, warm process/latency and
restart/backlog/no duplicates. Existing success is coordinator-reported for source45;
this new artifact is source/fixture/cross-build proof only. The first phone failure
cause remains unknown and no source change is claimed to have caused recovery.

## Worker proof, self-review and artifact boundary

Settled `op-1792256646407918-16612-310` passed57 Go tests plus2 mutation subtests
with -count=1, vet,10 Node tests, real private unpaired executable HTTP/CLI/MCP
checks, navigation and source/embedded native facade compatibility, plus119 shipping
checks. Zero skips. This is Windows execution, synthetic SDK/header/contact fixtures
and Linux/ARM64 cross-compilation—not new real account or Linux-runtime acceptance.
The native wa host/facade modules were not rebuilt or changed. Earlier successful
and diagnostic generations remain retained; no original receipt/bundle was relabelled.

Causal controls cover old sequential history holding unrelated audio; raw-vs-normalized
remote scope; exact-string vs typed SDK author alias; SDK-unwrapped wrapped edit lost
by the old fallback; missing/ambiguous/foreign proof remaining held; unchanged reason-
only legacy holds; saved contact labels searchable without overwriting live display;
selected scope before/after lookups; blocked lookup not holding journal/identity locks;
generation/cancellation/cache failure/privacy; row/group/byte/version bounds; and old
server refresh refusal without replay. An actual API fixture checks encoded bytes and
scoped ordered output. These fixtures do not prove real metadata availability or
upstream total mutation reconstruction. Additional header passes cost local parsing/
SQLite work; shared SDK-store/CPU contention and real voice latency remain named
runtime risks, not claimed performance improvements.

The settled report names the clean source-bound ARM64 bundle, manifest/source/member
hashes and private source/SDK/fixture evidence receipt. Source/member/SDK/ELF/host
admission guards are unchanged. No full release gate, production deployment, profile/
MCP/settings change, QR/real account/media access, engine/default change or new agent.

### Late canonical convergence

Fresh merge-tree found already-landed upstream operator-management source5ed09900
while this task was running. Its separately provisioned explicit operator authority
is NOT a grant from name refresh/read credentials or general responder/MCP sends.
The owned branch merged that canonical source without modifying its operator logic;
additive status-map and documentation conflicts retain both features. This task did
not provision/use its authority, change its settings or send anything.

Settled `op-1792257260462889-16612-595` retested the converged tree:72 Go top-level
tests plus2 subtests, vet,10 Node tests, private unpaired/navigation/native source+
embedded compatibility and119 shipping checks passed, zero skips. This includes
upstream private operator fixtures, not production operator use. The pre-convergence
name bundle/receipt remains immutable; the report identifies a FRESH clean-source
converged ARM64 bundle and separate evidence receipt. No old artifact is relabelled.
