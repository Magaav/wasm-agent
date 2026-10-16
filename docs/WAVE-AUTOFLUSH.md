# Automatic SELF wave closure — normal flow, no extra gate

Default OFF. This is the wasm-agent SELF deployment policy, not a scheduler,
release gate, independent-review lane or historical wave factory. It reuses the
existing native completion notification. Other eligible coding projects retain
Fast/native-code-mode behavior unchanged.

## Normal coordinator procedure after installation

1. Once per conversation, inspect `wave_autoflush {action:"status"}`, then
   `enable` with the observed revision. No live job is enabled by this action.
2. Do the ordinary review/integration workflow. Work must actually reach clean,
   published canonical main; child completion/result retrieval is not authority.
3. Use the **usual existing build command** on that final main:
   `node scripts/codemode-build.mjs build <absolute-main>`
   Existing prepared `--assets <path>` remains supported. No special wave flag,
   per-child accept, qualify call, approval checklist or extra human stage is needed.
4. Normal coordinator closure automatically consumes publication plus the actual
   matching verified build and queues one supported source-bound Sentinel request.
   It does NOT rebuild, execute another test suite, start a verifier job, or invoke
   the candidate again. Only lightweight source/receipt/physical-byte checks run.

`off` with the observed revision disables future closure, without clearing admitted
requests or unknown effects. `status` and observation-only `reconcile` remain.
Old `accept`/`qualify` actions are optional audit diagnostics, not normal-flow
requirements. Optional `--wave-generation` is diagnostic compatibility only.

## Readiness facts, not an approval ritual

The ordinary offline builder already performs its native/embedded build check.
That same check records compiled source/tree identity, actual bytes/target, raw
logs and receipt hashes. On a successful clean published-main build it atomically
indexes the ORIGINAL receipt at `<git-dir>/codemode-build-ready.json`. This index
is part of the existing build contract, not a second build registry or approval.
Native job-script builds do not publish coordinator readiness; a build fact alone
never authorizes deployment from a job/background closure.

Closure consumes that original checked receipt, source/common-repository identity,
opening/build times, current published source, physical release bytes and installed
image identity. Missing, corrupt, stale, wrong-source, earlier-wave, installed or
foreign artifacts hold; ready:true/evidence strings cannot substitute for the
builder's original record. Original receipt/log hashes are checked without rerunning
native tests. Bytes and source are checked again before the queue write. A changed
ready-receipt pointer cannot replace an already reserved candidate silently.

Source publication plus this actual ordinary matching build is the authorized
readiness transition under the operator's direct workflow. Native integration
facts and original child sessions remain the evidence; no child claim is promoted
into readiness on its own. Self-review remains self-review, not independent review.
Actual installation, idle/startup checks and fresh installation verification remain
external supported Sentinel work.

## Preserved scope and effect safety

- Only the local MASTER/root coordinator, with actual owner/node identity.
- The selected common Git repository must match the node's authoritative runtime
  repository. Names, manifests and candidate files cannot make another repo SELF.
- Native background/job/remote origins cannot create or close SELF deployment debt.
  No classification is inferred from prompt text. Guest/child/specialist and
  code-mode guest wrappers cannot gain coordinator control.
- Generations use native admission/membership snapshots, excluding settled unrelated
  history and operational jobs. Required active work still prevents closure; a
  missing enrolled record is unknown, not idle. No pending flag manufactures activity.
- Original own impact is measured against fresh integration main/merge-base BEFORE
  ff. Docs-only children syncing upstream shipped changes owe no install of their
  own. Older unmeasured merged work stays unknown. Drafts/history are retained.
- Reservation precedes queue effects. Lost response, busy/mismatch, failure and unknown
  notification hold without automatic replay. Indented real TEXT stdout is preserved;
  only its parsing view is normalized, followed by exact immutable intent readback.
- Queued/spawned/exit0 is not installed. Only exact native request-bound installation
  proof can settle that state. Notification delivery is separate. Protected failed
  installation reservations and recovery doors are untouched.

The v2 state and old v1 history are retained independently; installation does not
activate either. Privileged out-of-band filesystem modification is outside this
cooperative local boundary.

## Closure reporting and delivery

Active native workers produce `{held:true,deferred:true,state:"deferred",
reason:"active_workers"}`. Observation still runs; readiness/queue admission does
not. This expected wait is not an installation failure. All existing source,
activity, ownership, unknown-effect and binary guards remain in force.

Closure results are never appended to assistant prose. Changed actionable holds,
queue transitions and native installation verification emit a concise operator
`status` with `wave_notice_id`, and a `wave_closure` trace on the assistant row.
Full original results (including old Lua error/source decoration) are retained in
SQLite meta `wave-autoflush-report:v1:<parent-session>` as append-only events.
`wave_autoflush status` retains the native wave state and original request receipts.
Unchanged semantic state is quiet across module/process restarts; generation,
reservation, phase or blocker changes can notify again. Expected waiting and
no-impact observations have no notice. Guest, child, job and WhatsApp-route
contexts cannot produce operator notices. Reporting never calls finalize/queue.

The report is durably claimed before emission: notices are **at-most-once**, not
proof that an offline reader received them. A crash between claim and stream can
lose the live status; its original remains in the native report. Transcript
repaint reads saved content/trace; it does not rerun closure or emit a new notice.
The streaming server returns no answer body; the host emits a text-free `done`.
The one `reply` uses the same message id/content as the saved assistant row.
No marker regex strips model/user quotations or rewrites existing history.

The original raw leak was the unconditional final-answer suffix for every
non-nil closure result, including the active-child readiness assertion. A private
baseline-agent control reproduces two markers with ONE finalize when model text
already quotes a prior marker. This proves a possible echo mechanism, **not** the
cause of any particular historical double suffix. Without its original wire and
provider records, historical delivery duplication versus model echo is unresolved.
Source inspection found one suffix site, one final-row write and one reply emit;
the streaming return and `done` do not append a second body. No UI edits or visual
claims are part of this backend repair.

`node scripts/test-wave-closure-reporting.cjs <built-wa> <fresh-private-output>`
checks actual agent + mock provider, source/standalone embedded, server streaming
entrypoint, saved transcript, native report dedup/restart, quoted text and native
role/origin/WhatsApp exclusions. It retains a failing baseline regression and an
explicitly labelled possible-echo control. No paid inference or live worker probe.
The existing lifecycle suite additionally checks real active-worker deferral and
clean ordinary answers; its original installation safety assertions remain.
`WA_WAVE_OLD_BINARY` may select a measured genuine earlier physical artifact for
that private suite; its path/hash are retained rather than assuming a local cache.

## Focused source proof

`node scripts/test-wave-autoflush.cjs <absolute-built-wa> <fresh-private-output>`
uses private Git/remotes/homes/DBs and real ordinary offline builds, with fake
inference/queue effects. Source + standalone embedded + restart cover the normal
no-ceremony path, prior mandatory-ceremony failure oracle, preserved eligibility,
identity, drift, role, generation, TEXT receipt and unknown-effect cases. Closure
creates no extra native-test run. Original earlier proofs/failures and qualified
binaries remain accessible. No live activation, installation or full release gate
is part of this proof.
