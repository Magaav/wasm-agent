# Roadmap — one agent, independent use and assisted automation

## North star

**Install an agent, not an infrastructure project.** It remembers on request,
does useful work, shows the consequences, and can reach authorized machines.
Its identity survives a model change; adding a device adds capabilities rather
than creating an unrelated personality.

An automation professional should be able to apply their expertise, models,
tools and tested procedures to customer tasks through explicitly connected guest
nodes. A customer should be able to receive that help without becoming a developer.

These are two entry paths into one runtime:

| Path | The person buying into the experience | Promise |
| --- | --- | --- |
| Personal | Someone running their own agent | My agent, my model, my work, continuity across sessions and authorized devices. |
| Assisted | A customer working with an automation provider | Help automate my tasks; show me who has access, what they may do, and how I stop it. |
| Operator | The automation professional serving those customers | Reuse my arsenal safely across engagements, with separate customer authority, data, evidence and costs. |

The fleet console serves these journeys. It is not the product's required first
screen, and 32 workers are not a prerequisite for helping one customer.

## Maintenance baseline — 2026-10-05

The operator-selected direct workflow in `AGENTS.md` is active: one human-requested
change, no delegated workers, honest self-review, focused checks, canonical-main
integration and remote readback. Full release gates remain an explicit user choice.
The multi-lane delivery discipline below is historical guidance, not permission
to restart parallel production.

- Source baseline `4b07274` is published and installed. Transcript recovery and
  exact-source recovery fixtures passed their focused checks; installation
  verification reported 65 checks, zero failures and zero skips. No full release
  certification is claimed.
- The original seven pending tips/two conflicts and 22 dirty worktrees were
  reconciled to zero, preserving rejected source and hash-verified draft backups.
  Sixteen integrated, dependency-free local aliases were archived before retirement.
- Operation-index import preserved historical originals. Safe execution-claim
  recovery does **not** release workspace bindings or prove task completion.
  Delivery records now carry additive source-disposition observations while
  retaining original reviews, findings, admissions and landing records. The
  scheduled WhatsApp copilot was paused via `job disable` (revision 21, queued
  zero); it must not silently restart responder delegation during direct work.
- Runtime closure remains **blocked**, not ready: 76 historical operation unknowns
  lack sufficient identity/drain proof; two newer operation records also need
  recovery. The 46 attempted workspace retirements remain held (36 operation
  refusals, ten recorded/actual branch mismatches). Legacy wave convergence and
  a stale exact-run activity claim remain unverified. Missing processes, age,
  overwritten states and clean Git cannot settle those effects.

Local evidence is retained under the cleanup session's scratch directory
(`~/.wasm-agent/session-scratch/` for session
`6cebcd88-986d-445a-bbdb-69a274cc9537`): `LIVE-INSTALL-VERIFIED.json`,
`OPERATION-INDEX-IMPORT.json`, `RETIREMENT-AFTER-INDEX.json`,
`BRANCH-BINDING-BLOCKERS-v1.json` and `DELIVERY-DISPOSITION-RESULT-v1.json`.
These are dated observations, not portable release proof or a completed wave.
Ordinary direct development may proceed under `AGENTS.md`; protected leftovers
and original unknown outcomes must remain preserved.

Follow-up, 2026-10-05: the six instruction-check failures were repaired without
raising its original 10,418-byte budget or restoring delegation. The complete
checker passes 74 checks; a private 19-check mutation suite rejects removal of the
active direct-workflow, no-replay and watcher-off rules. The two repository skills
now put the direct override before their historical parallel procedure.

Three more execution claims were reconciled after examining original live
provider/credential effects, terminal failure evidence and the exact-owned durable
results missing from one interrupted transcript; no command, refresh, login or
model request was replayed. The stale steering row was recovered through its
supported status path as **unknown**, not falsely completed. A fresh activity
observation has no unsupported activity claims and sees only the current operator
run. Three uncertain execution claims, the original operation unknowns and the
workspace retirement safety fences remain protected pending exact evidence.

2026-10-05, raw JSON recovery fix: `host.operation('reconcile', ...)` accepts an
exclusive `expected_state_json` string so Lua can pass original state bytes through
ordinary JSON encoding without dropping nulls or changing numbers/containers.
Default Lua decoding and strict state/owner/evidence checks are unchanged.
Focused proof: the regression failed against the prior binary, then passed 27
Lua/native checks in two private processes; operation unit tests passed 41 with
one explicitly ignored helper (exercised by its parent test). Self-review, not a
full release gate or permission to reconcile unrelated historical effects.

2026-10-05, sentinel observation I/O: ownership checks now use an authenticated
id/owner-only SQL/HTTP projection, not 500 transcript messages or stored summaries.
Due checks precede owner HTTP; successful pending polls recur after ten seconds and
failed observations back off 10/20/40/60 seconds. The trade-off is up to sixty
seconds before a failed observation notices repair; delivery/composition still
revalidate ownership and acknowledgement independently, with no effect retry.
Self-review and focused proof: 46 native sentinel tests, ten Lua/SQLite owner
checks, 19 acknowledgement and 23 current-check binding checks, plus 12 real-node
parent/HTTP checks passed with zero skips. The new regressions failed the old
behavior. Full release gate not run. A pre-install eight-second OS counter sample
recorded sentinel ~321 reads/s and ~1.15 MB/s; cached/network I/O is included and
fan causation is unproven. Installation and a comparable post-install observation
remain separate verification steps; historical cleanup unknowns are unchanged.

Post-install follow-up, 2026-10-05: `a0c6994` is installed from clean published
main with final `clean-built-by-deploy` provenance; installation verification
passed 65 checks and the installed private real-parent test passed 12, zero skips.
Scheduled jobs and their revisions remain unchanged/disabled; the event-only
return hook remains enabled. The post-install OS counter samples were higher,
not lower (~464–483 sentinel reads/s, ~1.75–1.82 MB/s), during the sentinel-owned
continuation stream. These are not matched idle measurements: no total I/O
improvement or fan-noise causation is claimed. Deferred transcript-fetch removal
is established by the private native regression, not those aggregate counters.

Cleanup resumed with bounded additional provenance leads, not another exhaustive
fixture scan. Four alternate retained ledgers had no exact remaining-claim run;
a fifth historical backup refused as malformed and remains untouched/unresolved.
Git reflogs explain the ten unchanged branch mismatches; four missing original
source roots now link to the canonical shared registry. Neither fact grants
branch/source relabelling or bypasses original-operation fences. Inspected
supported recovery refuses replacement of allocated bindings, and parking/release
still require the recorded branch plus relevant-operation settlement. No further
claim, operation or binding was released from these leads. The remaining boundary
is **77 historical operations** (76 preserved legacy originals, 75 unattributed;
one accepted modern admission), **three uncertain execution claims**, **46 held
workspace targets** and the legacy-unverified wave. All 76 original hashes were
rechecked unchanged. Git/install success is separate from runtime readiness.
Local dated evidence: `RECOVERY-CURRENT-RESULT-v35.json` and
`RECOVERY-NEW-LEADS-v35.json` in this cleanup session's scratch directory.
Actual original run/identity/drain/effect provenance remains necessary; do not
replay effects, overwrite unknowns, switch branches or delete evidence to clear
these counts. No full release certification is claimed.

2026-10-05, existing-node fabric binding: `/bind`, `/bind status|renew`, `/unbind`,
`/nodes pending`, `/accept`, `/promote`, `/demote` and `/revoke` now use shared
non-model CLI controllers and a versioned two-sided managed binding protocol.
Explicit 24-hour account-authority consent plus exact signed ten-minute pairing
and administrator acceptance precede outbound attachment. Network promotion is
separate from local CLI/model role and fabric administrator authority. Native
private atomic CAS, original-request observation and a per-home OS-leased outbound
capability runtime preserve identity, session, provider settings and unknown
outcomes; existing servers refuse a duplicate CLI attachment. No inbound listener,
new automation job, login service or real-device enrollment is part of the change.
Self-review/focused proof: Windows43 and Linux44 native end-to-end checks,
16 controller/recovery checks per platform, legacy managed-network40 per platform,
command-parity62 and direct-workflow19 passed, zero skips. Linux includes private
file mode0600 proof; package/bootstrap checks explicitly not run, no full release
gate. The legacy protocol1 bootstrap remains compatible. The service and each
participating CLI need updated binaries; installation is separate from source
proof. A scoped sentinel-run Linux registry installer preserves actual binary
and SQLite originals, verifies exact source/service/pins and reports crossed-but-
unverified installation as unknown. Pin trust is explicit HTTPS/human first
contact, not an OS sandbox or guaranteed cancellation of already-running effects.
Prior cleanup unknowns remain unchanged. See `docs/BINDING.md` and
`docs/RENDEZVOUS.md` for commands, verification and recovery boundaries.

2026-10-05, outstanding cloud maintenance: partial installation reached the exact
published node bytes but the legacy watcher lacked its current lifetime identity;
verified systemd PID/image/cgroup ownership permitted restarting that exact unit.
The subsequent supported installer exposed a separate polkit refusal for its
non-root system-unit restart. `WA_DEPLOY_SENTINEL_SUDO=1` is an explicit opt-in
that preflights noninteractive authority and elevates only the installed
sentinel's verified manager restart; default remains unprivileged, no automatic
sudo fallback or policy weakening. Private command tests5, deploy-policy8 and
clean-environment record34 checks pass. Self-review; original partial/failure
records remain evidence, final cloud installation is still separately verified.
A shipped read-only Windows idle-I/O measurement waits for native idle state,
checks exact process generations and retains three bounded samples rather than
calling an active sentinel continuation an idle baseline. Eight actual-predicate
checks and the98-check shipping manifest pass; no recurrent measurement job or
fan-causation claim is introduced. Fresh cleanup inventory still has77 historical
operations,3 uncertain claims,46 held bindings and the legacy-unverified wave;
all76 saved original hashes remain unchanged. Arch node86a8cbb is absent from
the live registry, so remote update/local consent cannot be fabricated.

2026-10-06, post-maintenance continuation: local binary/verdict65 checks passed,
but an explicit read found the newly added idle sampler absent. The prior installed
deployer updated itself during that run without executing its new shipping line;
existing verification did not include this asset. A red private missing-asset
regression now pins it, and17 install-verifier checks pass after adding the exact
measurement comparison. Native sentinel `run` now selects system PowerShell for
approved Windows `.ps1` scripts (same allowlist/owned-operation checks), with
explicit non-Windows refusal and no silent shell fallback. This closes the actual
measurement execution route, not a claim that a sample has already run. Historical
cleanup unknowns remain preserved; cloud final install at6f2902b is separately
verified with65 installation and44/16 binding/recovery checks, no enabled jobs.

2026-10-06, measurement collection ordering: the first one-shot sampler ended
`node_never_idle` (known failed/terminated, no samples) because a separately queued
collection wake ran concurrently. Queue order was not completion order; original
failure retained and never relabelled success. `request run --session --prompt`
now validates both fields before effect, persists the original known result,
then creates one exact request-bound continuation. Consumed/claimed wake keys
never duplicate; unknown execution holds collection and requires inspection.
This is a bounded continuation for already authorized scripts, not a recurrent
watcher or effect replay. Native regressions fail old half-continuation behavior
and pin durable-before-wake/idempotent-after-delivery boundaries.

2026-10-06, direct review of PRs #27/#28 plus #28's key-vault dependency:
combined candidate self-review repaired unsafe startup retention/lease deletion,
Windows vault storage/backup paths, concurrent first-key replacement, durable
refresh no-replay fencing, CSP CRLF hashing, background-tab streaming, bounded
HTTP reader admission, and process-tree upgrade timeout ownership. Original
transcripts, journals, leases and backups remain preserved; batching and new
provider retries are opt-in risk knobs, not unmeasured new defaults. Sync now
requires a target-signed acknowledgment before cursor advancement.
Focused Windows proof: workspace tests36/95/34/41 before repairs (one explicit
operation helper ignore); repaired host99, sentinel48, binding43, managed40,
peer-chat43, real two-node sync7, 13 private Lua suites, shipping98 and policy19
passed. Browser/UI reload/recovery/inspector and final-answer suites passed;
a staged Chrome screenshot was inspected. Vault80 passed with one explicit
Unix-mode skip on Windows. Linux ARM64 host99/sentinel48, vault81 (zero skips),
binding44, managed40, signed sync7 and reply6 passed on source d9c09bd.
Final-answer loop55 is preserved by the default retry opt-out. Window source
locked native compilation passed after updating its missing operation dependency
lock; auxiliary views now have the same origin confinement as the main view.
Window unit tests13 passed with one explicit native-notification test ignored;
that is not live WebView2 navigation proof. The existing desktop window was not
restarted/replaced. Vault page render9 and
screenshots passed using fixture data only. Final source integration and
installed-source verification remain separate steps. Package/bootstrap/full release gate not run;
`gate_verified:false`, `release_verified:false`. No real vault/credentials were
migrated, device consent fabricated or historical unknown settled. Existing77
operation unknowns,3 uncertain claims,46 held workspace targets and legacy wave
remain protected; absence of evidence is not a cleanup todo to silently erase.

2026-10-06, deployment preflight follow-up: the first cloud snapshot attempt
blocked on its exclusive run-lease database before either installer dispatched.
Exact transient-unit PID/child/cgroup and unchanged installed-source proofs
permitted stopping only that attempt; original partial backup/refusal remains.
Backup discovery now excludes both resource `.lease.sqlite` and run `-lease.sqlite`
files, with a regression. Lease files are OS ownership locks, not VACUUM snapshots.
No production node stopped or unknown historical effect was replayed.

2026-10-06, PR installation closure: runtime source `76d38c20` is installed
locally, on cloud and on the public rendezvous. Local and cloud actual installation
verification each passed66 checks with zero failures/skips, final
`clean-built-by-deploy` provenance and matching node/sentinel bytes. Administrator
pins and job revisions are unchanged; schedules remain disabled (local event-only
return hook enabled, all cloud jobs disabled). Installed private binding43/44 and
signed sync7 checks passed on Windows/Linux, without live model/provider calls.
PR27 is merged; PR28 and its vault dependency are exact ancestors of main and
PR28 is closed already-contained. Remote carries only main; owned/canonical trees
are clean. Dated private evidence: `PR-FINAL-RESULT-v97.json` in the cleanup
session scratch directory, with installed receipts and archived dependency refs.
All76 protected original files rehashed unchanged;77 historical operation
unknowns,3 uncertain claims,46 held workspace targets and the legacy wave still
require original identity/drain/effect evidence. No generic approval or successful
install settled them. Arch remains unreachable without local consent/access;
no valid idle samples or fan-causation proof. Production vault configuration and
credential migration were not performed. Companion changes are source-verified,
not installed: the supported node deploy does not ship `wa-window.exe`, and the
existing window was not replaced/restarted. Full release/package/bootstrap and
live WebView2 navigation proof were not claimed. This documentation-only closure
note does not change deployed runtime bytes or request another installation.

2026-10-06, targeted historical-backlog recovery: the legacy wave's exact
journal shows all three stages pending, zero attempts, no operation IDs and no
owner boot/PID. Added an explicit `withdraw-plan`/`withdraw` route for only this
never-admitted migrated-plan shape: exact manifest/snapshot pins, preserved
original row/steps/events, one atomic audited disposition and replay-time
validation. Withdrawal reports `not-run`, not verified convergence; land/admit
still need fresh authority. Running/unknown/history mutations refuse. No watcher,
subagent or full release gate introduced. Self-review; focused private withdrawal21,
derived55, lifecycle44, corners24, monitor16, shipping21 and policy19 checks passed.
New evidence leads were bounded: a hash-preserved copy of the damaged pre-scrub
backup exposed a truncated last page and no exact remaining claim IDs; native
process-event sources were denied(Security), absent(Sysmon) or disabled(kernel).
No original process/effect proof emerged. The77 operations,3 uncertain claims and
46 dependent workspace retirements remain held, not falsely settled or replayed.
The wave withdrawal is a distinct bookkeeping effect and does not clear them.
Actual supported withdrawal now passed exact original snapshot validation at
source3757053; the legacy plan reports `withdrawn/not-run`, its original full
SQLite snapshot and hashes remain in `WAVE-WITHDRAWN-v106.json`. Fresh retained
readback `BACKLOG-AFTER-WITHDRAWAL-v107.json` verifies77/3/46 remain held and all76
original hashes unchanged. No live owner or unknown effect was cleared.

2026-10-06, explicitly authorized quarantined-retirement alternative: added a
separate exact operator-policy/archive risk path, not historical drain or effect
settlement. Native operation reservations get additive quarantine history;
original state/output/before-reconcile bytes stay unchanged and relevant lookup
revalidates archives. Exact dead-lease claims are archived/audited before release;
archive movement blocks key reuse. Session-fenced workspace parking preserves
original binding, source bundles and refs; ordinary deletion of quarantined trees
refuses. Live owners, moved identity/archives, dirty/ignored/unmerged source and
in-turn mutation refuse. No automatic sweep/replay. Self-review and private native
quarantine20 plus in-turn2, operation42(one explicit helper ignore), host99 and
existing workspace37/13 checks passed. Build parallelism capped2. Exact production
archive preparation verified77 operations/3 claims/46 bindings; ownership has not
yet been released. Human authorization is retained from original message3106,
not an assistant-generated approval. Linux ARM64 native quarantine20+in-turn2 and operation37(helper ignore1)
passed on exact candidatedb6bf0d; native Windows quarantine20+2, operation42,
host99 and normal workspace37/13 passed. Archive generationv117 reverified411
preserved files and all77/3/46 exact pins, with no ownership released yet.
Integration/install/application remain separate, with partial effects requiring inspection. Risk accepted by the
operator: old external outcomes remain unreconstructable/unknown; availability
release does not prove those effects drained. See `docs/QUARANTINED-RETIREMENT.md`.

2026-10-06, quarantine application preflight: exact installed91a0aef passed67
installation checks, zero failures/skips. The first external application settled
failed after5 additive operation dispositions;3 claims and46 bindings unchanged.
Native `OpenProcess` denied a recycled protected service PID4880(GCUBridge.exe),
whose actual OS creation timestamp is newer than the original September21 record.
Added bounded native system-process snapshot fallback only on access denied, with
strict size/offset/truncation/status validation and current-generation equality
regression. Access denied never means absence/drain; normal adjudication unchanged.
Operation43 checks passed(one explicit helper ignore), private quarantine20+in-turn2
remain focused verification. Original attempt/evidence retained; continuation
must exclude already-disposed exact5 and inspect postconditions, never replay
whole plan. No original execution success, claim release or parking inferred.

2026-10-06, authorized historical quarantine **applied and verified**: repaired
runtime324e98b is installed with final clean-built provenance; actual verifier
passed67 checks, zero failures/skips. The first failed attempt's5 completed
operation dispositions were inspected/preserved and omitted from the exact
remainder plan. Sentinel remainder request1791329148354430000 and operation
op-1791329148521975-16620-25 settled successfully (code0, cleanupterminated)
without replaying those5 or any old external action. Native readback validates
all77 quarantined unknown operation records and zero targeted allocation blockers;
all3 scoped uncertain execution reservations are archived/released, and all46
workspaces are parked at their exact detached integrated tips with empty binding
branches. Trees, original bindings, transcripts, branch refs, source bundles,
draft backups and unknown outcomes are retained. All411 private archive files,
every live original operation file and76 original before-reconcile hashes match.
Legacy wave remains explicitly withdrawn/not-run, not verified convergence.
Dated private proof: `QUARANTINE-FINAL-VERIFIED-v135.json` and original archive
v117 in session6cebcd88 scratch. Jobs/revisions unchanged; no new schedules,
subagents or full release gate. **Targeted77/3/46 retirement is complete under
operator risk acceptance**, with original drain/effect settlement still unproved.
Other current/unrelated claims and managed bindings remain outside this scope;
no global runtime-convergence, fan, vault, Arch or companion claim is made.
This closure note is documentation only; it does not require another installation.

2026-10-06, fixed the context-mode review's clipped absolute-path discovery:
added a read-only scoped relative-path helper under `skills/code-graph/scripts/`,
explicit candidate counts, bounded complete JSON pages and snapshot-bound
continuation. The skill now rejects treating a clipped inventory as absence and
keeps exact source inspection; no blanket output compression, retrieval quota,
new runtime tool or permanent `AGENTS.md` growth. Regression35 and direct-policy19
checks passed, zero skips; fixture pagination retrieved all450 paths across11
pages and changed inventory refused. Self-review measurement at external
context-mode d064241: the same539 paths occupy91488B absolute versus17645B
relative; task-scoped25 exact Git-oracle paths fit1204B, complete. This is one
navigation measurement, not proof of better coding success/total cost/latency.
Private `DISCOVERY-MEASURE-v138.json` retains counts/limits. Recorded discovery
spell replay refused enforced worktree context; verified CLI remains preferred,
with no binding relaxation. Skill-only shipping must preserve binary install
provenance and all prior evidence; no full gate or context-mode installation.
2026-10-07, exact published e51ccba skill/helper bytes now verified in both local
skill roots:35 checks each, zero skips. Sentinel readback-only operation
op-1791331474490094-16620-867 completed/settled/terminated; partial shipping
failures retained and no copy replayed after missing-rg verification failure.
`DISCOVERY-FINAL-v145.json` pins6 shipped files; binary hashes/install record,
serve PID and job revisions unchanged. No node/window restart or cloud deployment.

2026-10-07, fixed sentinel interpreting approved `.cjs` as Bash: shared native
JavaScript dispatch for `.js`/`.mjs`/`.cjs` in request-run, job-run, pipeline-run
and wake-prepare. Resolve an absolute executable from explicit WA_SENTINEL_NODE,
absolute watcher PATH or standard Windows Node installation; missing/invalid
runtime refuses before operation admission with no shell fallback. Canonical
script allowlist still precedes dispatch; native argv handles space/Unicode and
metacharacters without command interpolation. Trusted local executable selection
is not binary signature or dependency PATH assurance. Self-review and Windows
sentinel51 tests passed, zero failures/ignored, including actual common/module/JS
requests, exit7 preservation, missing runtime/no-operation proof and all3 job
paths; original shell/PowerShell/ownership/return tests remain green. Previous
shipping failure and its partial-copy evidence retained, no historical replay.
Instruction byte delta0; no new job, watcher, agent or full release gate. Candidate
integration and actual installed-script readback remain separate proofs.
2026-10-07, native Node dispatcher **installed and verified** at97d040a:
final clean-built-by-deploy provenance, actual installer verification69 checks,
zero failures/skips; sentinel SHA2565204d70eb6a0975be6366757ee3d9274ddd589e3ccefc09773cfacd9cf848416.
Live allowlisted `.cjs`/`.mjs`/`.js` requests each ran once without wrappers,
printed exact nonce/runtime/executable/script proof and completed code0,
settled/cleanupterminated. Evidence `NODE-DISPATCH-INSTALL-v150.json` and
`NODE-DISPATCH-INSTALLED-PROBES-v150.json`; operations
op-1791332200303023-6932-17, op-1791332200443497-6932-22,
op-1791332200656358-6932-27. Job enablement/revisions unchanged; no cloud
installation, provider calls or old maintenance replay. This closure is only a
ROADMAP note after the installed source, not another binary deployment.

2026-10-07, fixed Ponytail-review collector assuming TAP while Node emitted
spec output. Added focused `parallel-evolution/scripts/node-tests.mjs` with
explicit --test-reporter=tap, native file argv and fresh evidence generations;
retains actual exit/signal, complete stdout/stderr, counts and hashes. Missing,
duplicate/incomplete summaries, failed/timed-out processes and zero tests refuse
success; skips/todos remain visible. Collector28 and direct-policy19 passed,
zero skips. Same Ponytail14 focused tests collected actual exit0, TAP14pass,
0fail/skip/todo in `PONYTAIL-TAP-TESTS-v153`; original v152 spec log/collector/
receipts preserved, never relabelled as new TAP proof. Self-review; no Ponytail
installation, provider calls, inference agents, full gate or AGENTS growth.
Recorded collector spell refused enforced worktree binding; verified CLI remains
preferred, no binding relaxation. This is a collector-only external skill repair,
not a Node/sentinel binary change or arbitrary process-tree drain certificate.
2026-10-07, external collector/skill34a40b3 installed and verified in both local
skill roots:28 checks each plus original Ponytail14 through installed TAP helper,
actual exit0 and zero skips/todos. Sentinel native `.cjs` shipping operation
op-1791333346838993-6932-490 completed/settled/terminated in one request, no wrapper
or reporter repair. `TAP-COLLECTOR-INSTALLED-v156.json` verifies6 shipped hashes;
original skill backups/spec evidence retained, binary hashes/install/PID/jobs
unchanged. No restart, cloud deployment, provider call or full release gate.

## Status vocabulary

- **Implemented:** a mechanism exists in the repository; not a release certification.
- **Release gate:** must be demonstrated against the candidate artifacts.
- **Planned:** desired behavior, not something users may rely on yet.

Current mechanisms: local CLI and Windows companion; streaming chat; explicit
memory; resumable sessions and compaction; tool evidence; tracked diffs and
conflict-aware undo; signed nodes, rendezvous and relay; master/guest roles;
skills, spells and plugins; external sentinel; on-demand workers; supervised shell
operations and managed automation jobs. Jobs (Engine, after tools) queue wakes or
allow-listed deterministic actions from event/schedule/file/explicit CDP bindings.
See [operation contract](docs/OPERATIONS.md) and [jobs contract](docs/JOBS.md) for
the precise implemented boundaries, tests and remaining platform/adapter limits.

Windows candidate packaging, a fresh installer and launcher setup/diagnostics now
exist; clean-machine usability and public distribution remain gates. Guest setup
is deliberately disconnected, not a shortcut around authorization.

Missing product boundaries: stable agent identity beyond display metadata;
customer invitations,
consent, scoped authorization, isolation and revocation; trustworthy operational
status and an operator engagement view. Existing concurrency is not yet proof
of safe overlapping conversations. See [release status](docs/release/RELEASE_STATUS.md).

## 0. Establish safe execution boundaries — blocks external use

Reuse the current host, core and UI. Close the authority and ownership gaps
before making connection to the environment easy.

- Reject missing/invalid authority on privileged HTTP routes; explicitly design
  local UI authentication, allowed origins/hosts and request limits.
- Separate authentication session, conversation, run, worker and event-stream
  ownership. Serialize by the actual conversation, including queued requests;
  do not route authority through interpreter-local login caches.
- Route stream events to their own run/subscriber, not a global socket. Prove
  overlapping direct and relayed streams cannot mix.
- Remote authorization must fail closed. Discovery and self-declared `master`
  status confer no customer access. Pin enrolled operator identities by key/id,
  not by a mutable display name alone.
- Native capabilities require an honest authority statement. A workspace picker
  cannot enforce a path boundary on an unrestricted shell. Restrict/disable the
  capability or use an OS-level boundary where confinement is promised.

**Exit evidence:** negative tests for unauthenticated and foreign-origin access,
invalid/stale/replayed peer requests, wrong customer/operator, cross-worker role
leakage, two simultaneous streams and two simultaneous writes to one conversation.
No attack tests against customers or the live operator session.

## 1. Independent Windows-first package and personal setup

Build a coherent versioned artifact from one source revision. No private SSH,
maintainer configuration, checkout or compiler is required to run it. OS/runtime
requirements such as WebView2 must be detected and explained, not assumed.

- Bundle node, shell, required loader/assets and supervision support with a file
  manifest and checksums. Build provenance and package integrity are distinct
  from publisher authenticity and behavior verification.
- Deliver neutral runtime guidance, not this repo's contributor `AGENTS.md`.
- Add thin setup and read-only diagnostics using current configuration/paths.
  Collect a friendly agent name, compatible model settings and workspace choice.
  Mask credentials; do not pass them in CLI arguments or diagnostic exports.
- Distinguish configuration saved, provider validated and first task verified.
  An offline provider must not make local memory unusable.
- Preserve identity, user configuration, memory and sessions on setup rerun.
- Fresh installation is separate from update. Existing installations continue
  through the external upgrade/sentinel boundary; never overwrite a live binary.

**Exit evidence:** clean Windows user, packaged bytes outside the checkout, no
Lua/script overrides, no private host access. Install → setup → tool-backed edit
→ inspect diff → remember a random fact → restart/new session → recall → undo.
A later conflicting edit must survive an attempted undo. Test bad credentials,
missing assets and interrupted runs. `setup`, `doctor` and `ui` are now supplied
by the packaged Windows `bin/wa.cmd` launcher, not by native `wa.exe`. The guest
entry point stages an offline profile and refuses networking; it is not enrollment.

## 2. Invited guest onboarding — first-class assisted automation

This is not an optional afterthought to personal setup. The first assisted pilot
pairs **one operator and two isolated customer environments**, so separation is
tested rather than inferred from a single successful connection.

### Customer journey

1. Download the same independently distributed runtime and choose **Get help**.
2. Accept a short-lived, single-use invitation. See and verify the operator's
   identity, the service being joined and the requested access.
3. Approve the task and access grant. Explain files/apps involved, model-provider
   data flow, remote visibility, retention and who pays. Credentials stay on the
   side that needs them; never copy the operator's provider key to the guest.
4. Connect outbound through the rendezvous/relay. No router changes, SSH account
   or public listener on the customer's computer.
5. Watch progress and review results. Show an unmistakable remote-access state,
   the responsible operator, activity history, pause and disconnect controls.
6. Revoke locally. Restart, reconnect, retries and queued requests must not
   restore revoked authority. Explain actions already performed and whether an
   in-flight native operation can actually be cancelled.

A customer needs no BYOK merely to receive assistance: the operator can reason
on their side and call authorized capabilities on the guest. Local autonomous
reasoning can remain separately configurable. Service outage means unavailable
assistance, not fallback to broader privileges.

### Authorization contract

An invitation is not a permanent permission. Enrollment binds a specific
operator identity to a specific customer/device. Grants state capability,
resource boundary, approval mode and expiry. Changes need renewed consent.

Support attended assistance first. Unattended automation is a **separate,
explicit, expiring grant** for a reviewed procedure—not a permanent administrator
switch. Arbitrary desktop/shell control must be clearly described as broad access
unless a real isolation mechanism limits it.

Guest node status does not demote the human owner: the owner controls the
relationship. Guests cannot discover other customers' private inventories,
read their histories or become transit points into the operator's environment.
Default transcript replication must not mix customer data into a shared memory.

**Exit evidence:** invited customer completes a real automation without developer
help or their own model key; declined/expired/reused invitation does nothing;
wrong operator and customer are refused; pause/revoke survive restart and queued
relay delivery; customer A cannot read or act on B. Verify direct and relay paths,
and perform a threat-model review before inviting real customers.

## 3. Turn expertise into reusable, controlled automation

The operator's arsenal is a library of capabilities and **verified procedures**,
not a growing prompt or a reason to grant every customer every tool.

- Use skills to explain procedures, spells to execute deterministic steps and
  plugins/native adapters for capabilities. Reuse these before adding a framework.
- Managed jobs now provide default-off definitions, revision invalidation, durable
  bounded delivery queues and source/action evidence. Site-specific adapters
  (including WhatsApp), replayable browser event delivery, customer unattended
  grants and immutable procedure packages remain work, not implicit guarantees.
- Promote a successful task into a versioned automation with inputs,
  preconditions, postconditions, authority requirements and failure behavior.
- Keep customer secrets and identifiers out of shared templates and fixtures.
- Preview intended effects; distinguish reversible tracked edits from irreversible
  external actions. Approval is specific to the material operation.
- Expose run history, last verified success, exceptions and operator intervention.
  Scheduled/event-triggered execution needs customer authorization, limits and
  a stop control—not merely an enabled sentinel trigger.

**Exit evidence:** use one reviewed automation for two isolated customers with
different inputs; demonstrate failure, duplicate delivery, cancellation and a
version update requiring fresh approval where permissions change.

## 4. An operator console that knows the work

The [orchestrator workspace candidate](docs/ORCHESTRATOR-WORKSPACE.md) adds a
separate tiled session window, execution-role instructions, direct child
continuations and ordered cloud-first placement with per-node task limits.
Its proofs use isolated nodes and mock inference; live deployment acceptance
remains separate. Wake-word input and transparent remote memory are later work.

Keep the avatar and compact chat for everyday use. Add an operator view when the
number of real engagements needs it, reusing the existing UI components.

The console answers: **whose task, on which device, under which grant, what
changed, what is waiting on a person, and what needs recovery?**

- Customer/engagement boundary first; node/session lanes inside it.
- Task assignment, authorization status, last meaningful progress and deadlines.
- Per-run evidence, costs (unknown where unmeasured), outcomes and exports.
- The agent can query the same authorized fleet state; the UI is not the only
  place orchestration knowledge exists.
- Fleet/task state belongs in a durable service, not solely in browser memory.
  Closing the window must not lose a job or change who owns it.
- Bounded concurrency, cancellation, backpressure and per-customer budgets before
  16–32 lanes. A heartbeat is not evidence of task progress or completion.

**Exit evidence:** two customers, multiple nodes, concurrent tasks, browser reload
and a worker interruption; status and evidence remain correctly attributed.
For coding tasks, compare/merge applies to workspace changes; non-coding tasks
need their own observable effects and success checks.

## 5. Extend the reach after the first journeys work

- More operating systems and device surfaces, including mobile pairing.
- Shared agent identity above node keys, models and workspaces, with explicit
  synchronization, privacy, export, deletion and retention policies.
- Capability installation with reviewed permissions and provenance; no marketplace
  of unrestricted code presented as safe because it has a `.wasm` extension.
- WIT/Component Model and a WASI-hosted core where they solve demonstrated
  portability or isolation needs. No migration merely to match the project name.
- Voice and local wake word after useful tasks, visible state and consent work.
- Model routing with explicit cost/privacy policy; switching intelligence must
  not silently send customer data to a newly selected provider.

## Delivery discipline

Each milestone is small integrated slices on short-lived change branches.
The node's home branch stays current; it is not a perpetual release branch.
One writer owns each shared entrypoint during a change. Merged artifacts are
verified again; independent verification is not the implementer's self-report.

Use at most two implementation lanes initially: packaging/onboarding and
execution/guest authorization, with independent verification. Do not expand
lanes just because workers exist. Do not let cosmetic renames or unrelated
features block the first external-user journey.

Measure time to first verified result, return-session success, operator
intervention/rework and verified customer outcomes. Tokens and tool-call counts
are diagnostics, not a score for useful automation.

A milestone is not complete because its demo looked alive. It is complete when
its declared journey and refusal/recovery paths pass against the same candidate.
See the [release contract](docs/release/RELEASE_CONTRACT.md) for the go/no-go gates.
