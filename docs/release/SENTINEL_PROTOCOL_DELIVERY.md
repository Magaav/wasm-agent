# Bounded sentinel protocol delivery — independent review required

Producer: child:dispatch:40f63603-1bc4-4a48-9812-12a1055151be, same recorded branch/worktree.
Prior immutable checkpoint: 4bc53f57ca6287c279835b0881dd3d1f6beacf55, delivery record created with actual producer in sentinel/deliveries. Original evidence JSON retained. Independent review 0b846632aca394f378c9a1ca5b7f6f97dcc23a72 NARROWED its claims; this delivery incorporates the limits, not a bootstrap-success claim.

## Implemented (not installed)

New deploy CLI option `--expected-sha <full SHA>` creates persistent intent/id/queued_at; strict known-option parsing. Watcher writes immutable ack before busy/capacity holds, with persistent accepted/held/rejected/state evidence; detached success is phase spawned, never verified. Legacy no-SHA deploy retains its old path/continuation. Protocol deploy deliberately omits legacy session/prompt when launching the installer so the new hook is the sole return path: no double legacy wake + hook wake.

Protocol dispatch selects canonical PRIMARY main from the configured runtime-worktree's shared Git, not request-supplied path or stale executable-adjacent script. Requires clean main, exact HEAD=origin/main=expected SHA and `git ls-remote origin refs/heads/main` match. No arbitrary shell/path capability or allowlist widening. Installer uses its canonical parent for protocol requests, rechecks exact SHA before build and before upgrade, and writes per-request result with id/SHA, preserving global verdict compatibility. A modified source/ref is refused before installation. This is not an immutable filesystem snapshot: coordinator must still reserve source during deploy; a write after the final check remains a source race needing stronger staging in future.

Named disabled Engine jobs `onSentinelReturn` and `sentinel-return-observe` ship via the existing deploy loop; same wake prepare/block construction seam as onSubagentReturn. The bounded observer classifies CLI queued vs watcher accepted vs updating vs verified/failed/unknown, rejects missing timestamps/unrelated result/SHA/provenance, runs actual read-only canonical verify-install after successful attributed result, retains raw verifier stdout/stderr, requires zero verifier skips. Hook itself calls no provider; normal Engine wake starts inference only through existing budget/admission. Parent session is taken from persistent event for this named hook only. Stable event keys + immutable event payload + existing Engine/wake dedupe preserve repeated observations; disabled hook queue-zero is not marked sent.

Updating gets one persistent check slot due ten seconds after observation; one due check event, then no additional timed follow-up wakes. At ten minutes without attributable result, unknown is reported for reconciliation, never effect replay. Five/ten-second values are policy boundaries, not production latency guarantees. Schedule definition ticks once per second but jobs remain disabled until coordinated install/approval.

## Bootstrap blocker and corrected alternatives

Current installed watcher lacks this selector. Existing CLI environment cannot alter watcher environment. Existing run uses canonicalized WA_SENTINEL_SCRIPTS and supervised 302-second execution; exported spell ALLOWED_STEPS DOES include run (contrary to stale skill/docs prose), same allowlist. Installed launcher metadata names only install/scripts allowlist; no already-approved canonical outside-placement launcher was established. Do not run direct deploy under run/spell and assume survival when it replaces parent watcher. No new launcher, allowlist edit, watcher restart or hand copy was performed. Chicken-and-egg: new selector needs a sanctioned outside-run bootstrap by coordinator or an independently verified existing outside launcher; no safe request-only live bridge was proved.

Original report omitted resolve_script cwd-parent fallback: full order is explicit override, executable-adjacent scripts, cwd/scripts, cwd parent/scripts. WA_DEPLOY_ROOT remains build tree only for legacy deploy.

## Fixture safety and observed checks

Original Python fixture is now disabled with a visible refusal: once can exit before detached child settles; marker polling does not prove exit7 or process-tree cleanup. Historical raw proof is selection-only. Environment allowlist added for any future reconstruction. No arbitrary override/malicious child run was attempted. New selector tests never spawn deploy; private busy CLI integration never dispatches deploy and retains artifacts under own Git metadata `sentinel-protocol-proof` rather than deleting them. A replacement detached fixture with OS-owned tree wait/drain remains NOT implemented; no broader confinement claim.

Observed commands:
- `cargo test --offline --manifest-path rust/wa-sentinel/Cargo.toml -- --test-threads=1`: 39 passed, 0 failed/ignored; includes exact remote-main/private source-refusal and ack persistence.
- `node scripts/test-sentinel-return.mjs`: pass, three deliberate decision mutations red, skips=0, provider calls=0. Covers no-ack boundary, accepted-not-complete, stale id/wrong SHA/missing at/partial provenance/failure, cursor replacement/duplicates and one ten-second check.
- Private Python CLI integration against own freshly built sentinel: pass; actual declared job put/list disabled visibility and busy ack/held under five seconds, second once preserves ack, pending intent remains, no detached script spawned.
- `node scripts/check-deploy-shipped.mjs`: 82 checks pass, including new declared installer glob; shell syntax and diff whitespace checks pass.

Remaining coverage: actual complete deploy+verification path, actual busy Engine parent wake execution/terminal delivery, watcher replacement mid-swap, atomic job-delivery+wake boundary and OS-owned detached cleanup are not end-to-end proved. Existing Engine wake ledger has a submission-to-ledger crash window and bounded retention; this patch does NOT claim exactly-once external wake beyond existing guarantee. No Lua edit/test; Lua root issue inapplicable. Full repository gate not yet run. Independent reviewer must assess admission; do not call this live completion.

No live deploy/restart, installed file edit, marker stripping, live job enabling, remote push, provider/config/credential change. Only authorized delivery record written outside checkout. Production jobs left disabled. Original failed logs/receipts untouched.
