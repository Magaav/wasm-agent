# Recovery diagnosis: stopped Sentinel, held installation and failed model wait

This is original-evidence diagnosis, not a release or successful-deployment claim.
All dates below are UTC. Source/installer success, observer completion and actual
current process identity are three different facts.

## Sentinel restoration

The old skill's blanket “a stopped watcher cannot be revived from a run” was a
policy dead end, not an OS impossibility. A bounded source worktree also refused
all client tools; trying client shell/status could not reach the operator desktop.
The supported node-side shell remained usable.

The new restore-only procedure validates existing task action, limited interactive
principal and exact operator SID, no SCM competitor, native stopped lifetime
ownership, no intentional stop and current clean published main. It backs up task
XML and launcher, changes only foreground `watch` to installed supported `start`,
then starts that existing OS task. The OS task executes outside the node's operation
process tree. It does not unset the run marker, detach an arbitrary process, register
a task, elevate, copy a binary, queue a fresh deployment or clear an effect record.

Actual restoration succeeded 2026-10-08 17:18:50Z: watcher PID6804, backup generation
`sentinel/task-restoration/20261008T1718506225347Z`. The prior installation reservation
was reported unchanged. Restoring the supervisor is NOT verification of deployment.
Later preflight still proved watcher6804 running after its launching tool settled.
The last observed task exit was `0xC000013A` and output ended in `^C`; its sender is
unknown because no attributable control-event evidence was recorded. Published native
detachment fixes are not yet evidence that the restored old installed binary uses them.

## Why installation reservation 1791418603937642600-7564-00000000000000000000 is held

An installation reservation is a durable single-writer safety record, not a Git lock
and not a request queue receipt. It is written before an installer can spawn, so a
watcher restart cannot accidentally install twice. Phase `admitted` means effect
authority crossed the reservation boundary; it does not mean failed installation.

Original timeline:

| UTC | Original evidence | Fact |
| --- | --- | --- |
| Oct8 00:16:43 | `intent.json`, `ack.json` | Exact source26eddb7 requested and observed; busy node initially held it. |
| 00:17:39 | `effect.json`, `protocol-effect.json` | Reservation bound source/tree, parent/owner, script hash, node PID20816/creation and watcher20528. |
| 00:17:39 | `state.json` | Installer PID22828 spawned; not a completion receipt. |
| 00:17:55–56 | return1, `delivery-…-1.json` | An **updating** notification submitted HTTP before the installation result existed. |
| 00:18:07 | `result.json` | Installer reports `ok:true`, source26eddb7, node/sentinel hashes and watcher22948. |
| 00:42:35 | `return-status.json` | Updating notification submission crossed HTTP but terminal SSE completion remained unconfirmed; replay prohibited. |
| later | `observation-poll.json`, `sentinel.log` | Owner endpoint refused connections; no fresh final verification recorded. |

`verification.json` is absent; the active reservation still says `admitted`.
The installed record separately names26eddb7 with final clean-built provenance and
matching installer hash. This is evidence the installer progressed successfully,
not the missing observer proof. The unknown notification is a different effect
from installing code; neither should be replayed to repair the other.

Admission refuses another installation until this exact reservation is verified.
The supported `protocol reconcile <id> --reason ...` route archives the original
records, reruns the actual verifier, and settles only the matching generation;
it never invokes the installer, resets return cursors or resends the notification.
A concrete observer coupling explains why installer success did not settle: in
`sentinel_return.rs:263`, an existing return journal prevents a fresh
`observed_phase()` calculation; that is the path which normally invokes final
`verify_install()`. The pending updating notification remains slot1 after its
ambiguous HTTP submission, so repeated observations preserve the unknown instead
of examining the subsequently written successful result. This correctly prevents
notification replay, but incorrectly couples installation verification progress
to completion of a different notification effect. It needs separate verification
and notification state machines, not a weaker no-replay rule.

However the present implementation requires canonical/local/remote **main still
equal26eddb7**. Main advanced to076a08e and8b5653d while installed artifacts remained
at26eddb7. Thus its exact-source condition now refuses. Resetting main, editing the
reservation or calling installer success “verified” would manufacture evidence.
A historical installed-source reconciliation door is a separate contract change:
verify retained source/artifacts and current exact process ownership without falsely
asserting the installed old source is today's main. This task explains the blocker;
no historical reservation has been cleared. The restored watcher can observe
queues again, but installation remains held by this exact admitted generation.
Readiness and installation settlement are intentionally reported separately.

## `! Waiting for model response 20`

Original failure: native run1034, telemetry run0122c6d0-995e-4ec3-adb8-cdf33f8dbd17,
step45. Evidence is `harness_events` seq119812–119816 and native journal
`events` run1034 seq1971–1975.

- Model call started 15:42:06.5468, ended 15:42:26.7831: **20.236s**.
- Provider `openai-sub`, model `gpt-6.1-sol`, Pi Responses transport.
- HTTP200;125,996 response-body bytes observed; EOF false; cancellation false.
- Cause chain: TypeError `terminated`, SocketError `UND_ERR_SOCKET`, “other side
  closed”. This proves stream-body failure, NOT which provider/proxy/network hop
  closed it. No safe provider request ID was captured in this attempt.
- `model_output_seen:true`, retry limit10, **retry_scheduled:false**; usage/cost
  unknown. No explicit response timeout/429/quota/auth/cancellation evidence.
- Native journal's entire final step: round45, status:model, checkpoint, error, done.
  **No reasoning/text/tool-selection delta for that call reached the UI journal.**
  No new tool was dispatched by this failed step. Prior steps' tool work remains.

The published earlier recovery fix59d58c3 was already installed within26eddb7;
source fingerprints show the same embedded adapter/agent. It was not an absent
patch. Its conservative retry rule suppressed replay whenever Pi emitted ANY event
except start/error/done, or its failed result contained a content object. This
includes non-displayable startup/unknown progress. Therefore `model_output_seen`
does **not** establish visible answer text; exact startup event type was not recorded.
Pi's installed `openai-responses-shared.js:344–362` confirms that
`response.output_item.added` creates an empty thinking/text block and emits
`thinking_start`/`text_start`, which the bridge counts as model output but never
forwards to the UI. This reproduces a sufficient cause for the classification;
we cannot identify which particular startup event occurred historically because
the bridge did not retain event-type counts. The failure occurred below the UI stream. The user UI stayed at its last observed
phase `model`; error marks that phase failed (`!`), elapsed floor prints `20s`.
The screenshot text's20 is elapsed phase duration, not a timeout or retry count.

The old fix covers recognized transport failure **before** conservative progress,
10 reconnect attempts per60s cycle and180s cooldown, original deadline permitting.
It intentionally does not automatically replay partial/unknown progress. This is why
increasing retries or pretending no progress existed would not settle this incident.
Healthy recent successful calls had first-delta times around4–35s; elapsed20s alone
is not a failure detector. Original prepared input was1,689,546 bytes,338 messages,
selected reasoningxhigh and stable append-only prefix; size/reasoning can contribute
to latency, but neither is evidence of the socket failure's cause. The byte estimate
is not provider wire bytes or measured input tokens.

Hermetic confirmation: the bridge fault matrix now includes empty thinking/text
item-open followed by a real loopback body reset: conservative progress true,
no UI delta and no retry.106 assertions passed, including the existing10-attempt
cycles/cooldown, cancellation, real partial output and unknown-progress no-replay
controls. A real Chromium probe reproduces the exact failed phase/glyph/20s
rendering (9 assertions). Its screenshot was later repainted by the fixture's
normal recovery; the probe's original DOM assertions remain the reproduction,
not a screenshot of the live user's window. No production UI was instrumented.

Diagnosis conclusion: real body-stream socket interruption + overly broad progress
classification for retry safety + unhelpful phase label after failure. Not a stuck
20s watchdog or silently missing previous patch. Potential future change: distinguish
known adapter start/item-open from visible text/reasoning/tool progress, record the
exact class, and retry only with proven no externally visible/dispatchable output.
Unknown progress must stay conservative. No new paid inference, proxy substitution,
credential change, compaction default or retry-policy weakening was performed here.
