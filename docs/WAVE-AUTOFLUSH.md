# Durable ordinary-worker wave closure

This is a coordinator control plane, **not** the historical wave factory, a job,
a generic beforeFinalAnswer hook, or an installer. Default is OFF. It uses the
existing native child completion notification, with no second inference wake.
The disabled legacy `onSubagentReturn` placeholder/polling jobs are not its producer
and should remain disabled. Engine's native child-completion inventory names the
actual producer. Inventory does not activate anything.

## Coordinator activation after installation

Only the local MASTER root coordinator for the selected repository/node uses the
ordinary `wave_autoflush` tool (also discoverable by `tool_search`). It is excluded
from child profiles and code-mode guest wrappers. No settings, jobs, provider,
model, reasoning, costs, services or installed assets are changed by activation.

1. `wave_autoflush {action:"status"}`: inspect scope, source, native children,
   measured facts, original evidence, revision and any blocker.
2. `wave_autoflush {action:"enable",revision:<observed revision>}`.
3. After a report, inspect the original child transcript/diff/focused check logs.
   `completed`, fetching a result, integration and self-review are **not** acceptance.
   For each required child call `accept` with the observed `revision`, `child_id`,
   original own `tip`, settlement `digest`, current published full `sha`, `tree`,
   and `evidence` naming the original records and coordinator judgement. Self-review
   remains self-review, not independent review. Dirty/unreadable/unintegrated drafts
   remain held and recoverable.
4. `qualify` with the latest revision, exact published full sha/tree and original
   evidence for the combined source. This explicitly authorizes closure queueing,
   not installation success. Every required child must have settled and been accepted.
   Newly admitted work or changed source invalidates old readiness.
5. The **normal completed coordinator candidate** closes deterministically after
   steering/audit decisions. It reserves durably before backup/queue and writes one
   supported `request deploy --expected-sha ... --owner ... --session ...` request.
   It retains the full structured operation/plaintext CLI receipt and immutable
   request readback. No legacy prompt/branch-switching update route is used.
   This is not a pre-stream timing guarantee. Ordinary status/questions without
   explicit enabled+accepted+qualified owed work do not queue an installation.

`wave_autoflush {action:"off",revision:<observed revision>}` disables future
closure. It never cancels an admitted request or clears unknown installation
reservations. `status` remains available. Enabling alone accepts nothing.

## Evidence and crash boundaries

Versioned parent/owner/node/repository state lives in native memory `meta` under
`wave-autoflush:v1:<parent>`. Original impact and settlement facts are separate
append-only digest-addressed records. Integration measures the native workspace
admission base -> original own tip **before** its fast-forward. Current main equality
is not evidence of zero impact. Installer-shipped rules are read from the retained
base's manifest; missing rules/base/checkout are unknown, never zero. This can
conservatively over-include upstream work; it cannot erase integrated own work.

Working/idle is derived from the actual owner-scoped, unpaginated native child list,
not from pending wave bookkeeping. A missing previously observed native record is
held. Same-database admission and reservation transactions fence new ordinary child
starts/continuations during an admitted closure. Backup is followed by fresh
native activity/source checks before the queue write. Native Sentinel still checks
actual idle, immutable source/owner/node/hook and its global installation reservation.
Privileged out-of-band filesystem/Git writers are outside this cooperative boundary.

Crash before queue, lost response, busy/source mismatch, failed install and unknown
notification all hold; none earns an automatic second effect. Original receipts,
logs, reservations and native journals are never deleted/reset. An existing failed
admitted native installation reservation blocks the strict queue path; this workflow
cannot retire it or replay its installer. Reconciliation belongs to the existing
external native protocol doors documented in SENTINEL.md.

If a queue response was lost, after inspecting originals the coordinator may call
`reconcile` with current revision, exact `request_id` and original `evidence`.
This is read-only observation of an exact immutable intent carrying this wave's
unique reservation marker; it never queues or clears a global reservation. The
original ambiguous receipt is retained separately. Wrong parent/owner/source/wave
ids refuse. An unqueued reservation with no attributable native intent stays held.

Queued/spawned/exit0/failure/generic green objects are **not installed**. Only a
request-bound native `verification.json`, matching immutable intent/binding/effect,
verified native global effect generation, successful actual installer result, exact
source/tree/owner/parent/artifact identities and retained raw verifier logs can mark
`installed_verified`. This is consumption of native historical verification evidence,
not a new fresh verifier run by Lua. Only children in that exact request's snapshot
are covered. Notification delivery and installation evidence remain distinct.
A later wave can proceed after status observes that proof. No positive live install
is claimed by the private fake-queue fixture.

## Focused proof

`node scripts/test-wave-autoflush.cjs <absolute-built-wa> <fresh-private-output>`
runs actual Lua/SQLite/Git integration and the actual coordinator agent loop with
fake inference and an explicitly FAKE queue, source and standalone embedded.
It compares the old agent's owed+qualified/no-request closure against the new normal
closure, tests duplicate/module/process restart and before/after queue ambiguity,
all return states, authority fences, active/new work, source changes, dirty drafts,
docs-only/unmeasured impact and exact TEXT receipt readback. It preserves inherited
child provenance; no real forbidden Sentinel effect is coerced. Positive actual
installation verification remains coordinator/external-Sentinel-only.
