# WhatsApp browser retirement and linked-device cutover

This is a REPLACEMENT, not an enabled parallel stack. Owner: coordinator + human
cloud/operator terminal. The implementation worker does not inspect/change production
jobs, tasks, services, keys or accounts. No Sentinel causation is asserted: why the
installed copilot was disabled has not been established.

Machine-readable inventory: [whatsapp-retirement.json](whatsapp-retirement.json).
Complete source reference enumeration (including harmless generic/test/evidence references):
[whatsapp-reference-inventory.json](whatsapp-reference-inventory.json), regenerated with
`node scripts/whatsapp-inventory.mjs --out docs/whatsapp-reference-inventory.json`.
It is source-only, NOT a substituted production inventory.
Canonical setup/limits: [WHATSAPP-CONNECTOR.md](WHATSAPP-CONNECTOR.md).
Original browser-era setup, failures and proof claims are preserved byte-for-byte
in `docs/history/whatsapp-browser/` and Git; they are HISTORICAL, not current commands.
Other review/evidence/verify archives are evidence, not deployment entrypoints.

## What changes in source, and what does NOT prove runtime retirement

- Removed browser transport implementation modules: hook, identity expression,
  read/reply/store expressions, browser send lock and browser eligibility helper.
  Removed their active browser-only tests; exact former test text is archived.
- Existing read/lookup CLIs and owned MCP point ONLY at explicit linked-device
  configuration. Old raw/backend/page flags refuse. Media/store-send/source/trigger/
  preflight/install entrypoints are explicit no-effect retirement tombstones.
  There is no hidden environment switch, Chrome/CDP discovery or UI fallback.
- `whatsapp-copilot.json` is a disabled-on-put retirement tombstone with NO responder
  or transcription pipeline. Profiles ship read-only, EN, linked-device; imports do
  not approve or enable them. Deterministic transcripts do not spawn a model.
- Updated Jobs code refuses re-enabling/enqueueing the exact retired owners, skips
  their schedules/claims, and updated Sentinel source observation skips them.
  Existing rows, historical decisions and uncertain records are retained, not reset.
  This source fence only exists in the NEW binary; an OLD binary/task still needs
  explicit retirement. It does not claim to fence arbitrary renamed custom code.
- Node deploy ships the tombstones/read boundary, not the legacy transcript WASM.
  The cloud connector is a separate source/hash-bound HUMAN installer path, NOT an
  automatic node deployment. `scripts/deploy-shipped.json` classifies it explicitly.

## Exact check/apply procedure (coordinator/operator ONLY)

1. Freeze WhatsApp automation changes. Export current job definitions, revisions,
   enabled states and delivery history via supported `wa-sentinel job list`,
   `job export <exact-id>` and `job history` APIs. Save private original evidence.
   Include ALL known IDs: `whatsapp-copilot`, `whatsapp-events`,
   `whatsapp-wake-selftest`, `whatsapp-ingest`, `whatsapp-message`,
   `whatsapp-source`, `whatsapp-transcribe`. Absence must be observed, not assumed.
   Inspect active deliveries separately: list exposes queued/last, not complete
   process settlement. Pending/unknown sends are not permission to replay.
2. Inventory exact Windows task `wasm-agent-whatsapp-chrome`, its exported XML,
   principal SID, executable/arguments and `<install>/whatsapp-chrome.cmd` hash.
   Inventory legacy `triggers.json` and any custom jobs/spells/service launchers,
   browser keepers, user logon tasks and copied installed scripts/profiles. Match
   actual ownership/content hashes and exact paths, not titles, broad names or port
   9222. Unknown ownership or mappings BLOCK cutover. Never kill by image name.
3. Create a PRIVATE job manifest for the observed snapshot (example shape, not a
   real account configuration):

   ```json
   {"schema":1,"owner":"wasm-agent-whatsapp","account":"<exact-verified-PN-JID>",
    "jobs":[{"id":"whatsapp-copilot","revision":21,"definition_sha256":"<hash>"}],
    "files":[{"owner":"wasm-agent-whatsapp","path":"<absolute-owned-file>","sha256":"<hash>"}],
    "blockers":["task_process_trigger_identity_verification_pending"]}
   ```

   Hash the canonical definition with exported `definition(row)` / `hash()` from
   `scripts/whatsapp-retire.mjs`; exclude only its explicit derived display fields.
   ALL present known owners must be in the manifest. Revision21/13 are supplied
   prior observations, not freshly verified production facts. Manifest mismatch,
   extra/unmapped known owner, symlink or ownership/hash drift refuses.

   ```sh
   node scripts/whatsapp-retire.mjs --manifest "$PRIVATE_MANIFEST" --sentinel "$ABSOLUTE_SENTINEL"
   # After reviewing the dry run, same command with --apply --out "$FRESH_PRIVATE_RESULT"
   ```

   Apply only calls supported `job disable` for exact matched enabled owners, with
   fresh inventory before each call and disabled readback. It never forgets rows,
   edits SQLite, enables jobs, resets cursors or touches unrelated jobs. There is
   no atomic revision-CAS disable API: maintain the operator freeze; a change between
   read and disable is a residual API race. Interrupted/uncertain apply requires
   inspection/new manifest, not replay. The result ALWAYS says activation unauthorized;
   it cannot establish task/trigger/process/identity settlement.
4. For the Windows task, use `scripts/whatsapp-retire-task.ps1` from the HUMAN's
   terminal. Its PRIVATE manifest includes schema1, owner `wasm-agent-whatsapp`,
   exact task_name, exported UTF-8 XML SHA256, principal_sid, command, arguments,
   absolute wrapper_path and wrapper_sha256. It validates exact XML/owner/action/
   non-reparse wrapper hash; default is dry-run. `-Apply` only disables that exact
   task and verifies it. `-FixtureXml` is read-only test input and CANNOT apply.
   It neither unregisters tasks nor kills Chrome; task disable is NOT proof a prior
   browser/script/delivery has settled. Confirm those exact owned instances through
   their supported owner/task APIs. If safe ownership/settlement is unavailable,
   preserve the records and keep the connector OFF.
5. Legacy `triggers.json` has no implemented narrow retirement API in this delivery.
   A matching legacy WhatsApp trigger/custom launcher is an explicit blocker, not
   permission to hand-edit runtime DBs/cursors, broadly delete the trigger file,
   disable unrelated CDP features or restart Sentinel from a worker. Coordinator
   must use an approved supported configuration procedure and retain readback.
6. Coordinator installs the exact merged source generation through its normal
   supported publication procedure. Verify the updated binaries and installed
   tombstone hashes, no remaining old imports/callers, old definitions disabled,
   no active owned delivery/task/browser keeper, and no scheduler/custom-spell
   route that can restart it. Do NOT re-enable the copilot as a source-health check.
7. Pair on the human's private cloud terminal and verify exact account PN identity
   against the old binding using actual identifiers. Old serialized Web IDs and new
   protocol IDs are NOT interchangeable. Keep historical ledger/transcripts/drafts/
   browser profile/unknown sends in their original stores. Unverified mapping is
   read-only/quarantined; this delivery deliberately has NO legacy replay/import or
   historical backfill-posting command. A future importer needs explicit verified
   identity/message mapping and independent no-repost proof.
8. Only after all preceding evidence exists, the operator creates a restricted
   local cutover attestation (not a cryptographic certificate):

   ```json
   {"schema":1,"account":"<exact-verified-PN-JID>","legacy_disabled":true,
    "unknowns_preserved":true,"identity_verified":true}
   ```

   `activate --approve-transcript-posting --retirement-receipt <private-file>` requires
   that attestation plus a matching persisted paired identity. It does NOT prove the
   assertions itself. Keep the job/task/API evidence beside it privately. Default
   OFF until then. No history flood; activation stores a fresh first cutoff.

## Named retained pieces / removal conditions

| retained piece | owner / reason | removal condition |
|---|---|---|
| Installed old jobs/triggers/task/wrapper/scripts and possible already-running owner | coordinator / production not accessible to worker; MUST NOT be called safe just because Git changed | supported exact-match disable/settlement/readback and paired cutover proof, then exact hash-owned artifact retirement; preserve histories |
| Source retirement tombstones (`scripts/whatsapp-{source-ensure,preflight,transcribe,ingest,ingest-emit,copilot-read}.*`, adapter/trigger/audio/store-send CLIs, old task installer) | coordinator / overwrite old entrypoints safely and give named refusals during transition | after all installed references/imports/launchers are proved retired; remove files + shipping glob reachability in one reviewed follow-up |
| Retired `whatsapp-copilot` job template | coordinator / put disables changed old definition; new runtime refuses enable | after every installed owner/export/import path is verified retired; retain job history, never `forget` unknown records |
| Lua scoped facade, effects/reservation/verification and historical ledger access | app-boundary owner / preserve approval/event/profile safety and old evidence; GENERAL sends refuse | no timed deletion; future GENERAL send support needs real draft/precedence safety, separate approval and proof, not transcript authority |
| Pure Rust transcript-formatting plugin source | connector maintainer / ABI/format historical compatibility, no active shipping/caller | after dependent plugin tests/ABI consumers explicitly retired; NOT a second connector |
| `docs/history/whatsapp-browser`, review/evidence/verify snapshots and original stores | evidence owner / original failures and unknowns must stay available | retention only through separately approved evidence policy; no automatic deletion |

These are named staged residues, not an eternal unnamed dual stack. Production
retirement/private pairing proof is the explicit removal condition, currently blocked
by the worker's cloud execution boundary. No live retirement or activation is claimed.
