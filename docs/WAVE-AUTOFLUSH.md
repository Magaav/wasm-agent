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

## Focused source proof

`node scripts/test-wave-autoflush.cjs <absolute-built-wa> <fresh-private-output>`
uses private Git/remotes/homes/DBs and real ordinary offline builds, with fake
inference/queue effects. Source + standalone embedded + restart cover the normal
no-ceremony path, prior mandatory-ceremony failure oracle, preserved eligibility,
identity, drift, role, generation, TEXT receipt and unknown-effect cases. Closure
creates no extra native-test run. Original earlier proofs/failures and qualified
binaries remain accessible. No live activation, installation or full release gate
is part of this proof.
