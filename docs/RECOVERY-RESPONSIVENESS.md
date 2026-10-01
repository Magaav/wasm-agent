# Settings and transcript recovery

Read/control requests reserve one independent destination before enqueue. They
never fall back to a run slot, including after retirement/disconnection. When
the reserve is occupied, the listener returns `503 read_capacity_busy` promptly.
`WASM_AGENT_CONTROL_WORKERS` remains the capacity knob (default two). Risk:
simultaneous diagnostic requests can now receive explicit overload rather than
queueing; browser single-flight requests and bounded recovery backoff are required.
This does not bound slow provider catalogue/network work or SQLite lock waiting.

Provider/model/reasoning selection is one node-local SQLite document with a
monotonic revision. Validation and mutation share `BEGIN IMMEDIATE`; JSON settings
requests carry `{value,revision}` and stale writes return `settings_conflict`.
Legacy plain-text callers remain compatible. Existing state files supply fallback
values until a key is explicitly selected; new selections are authoritative in
`node_selection`, without storing credentials or replicating selection with the
transcript. Old and new selection writers must not coexist across an installation.
Status construction and run pinning read one snapshot; a running run retains it,
and other interpreters read the new selection for the next run.

The UI fences settings responses by node, thread and epoch, rejects lower
revisions, and periodically reconciles other windows. An aborted write is an
unconfirmed acknowledgement, not proof of no effect. Its note names the observed
pair and updates on later reads if a delayed write becomes visible. Successful
rendering and failure rendering use the existing control/error surfaces.

A known conversation reads `/session` directly; `/sessions` discovery is reserved
for a new or deliberately blank window. Restoration is single-flight and retains
the last confirmed view on failure, with endpoint/phase diagnostics and exponential
backoff capped at 30 seconds. Successful recovery clears its failure state. The
follower advances only through rows actually loaded, before reconciling checkpoint
and event cursors. Reconnect never re-executes a tool; existing guarded continuation
requires a complete recorded batch and an unchanged durable sequence.

## Focused evidence, before integration

`scripts/test-ui.ps1` passes in real headless Chromium, including real reload,
startup failure, single-flight/backoff, preserved view, loaded-row cursor, stale
settings and cross-target response checks. Against the earlier adopted UI, the
added checks fail for ambiguous wording, immediate retry and cursor advancement.

`scripts/test-selection-state.cjs <wa>` runs real concurrent processes and SQLite
connections with an explicit tree Lua root. It verifies persisted state, a held
run snapshot, reasoning selection and one winner/one refused racing CAS. The
existing model-route suite passes 81 checks against the tree Lua root.

`scripts/test-bg-responsiveness.cjs <wa> --compiled-serve-sha256 <hash>` verifies
reserved routing, bounded saturation, resolver queue/deadline recovery and actual
idle-thread retirement/respawn. The aligned earlier full-gated UI binary fails
the new reserved-read assertion; the candidate passes all four phases with no
skips in 3.703 seconds (one controlled sample). Held-reader burst replies were
200 or explicit 503 in 1–2 ms, not parked behind inference. This is a barrier
fixture, not a production throughput or timeout-setting measurement.

`scripts/test-recovery-two-window.cjs <wa>` launches two isolated real Chromium
contexts against the real node/Lua/SQLite, owned local mock inference and a private
reverse proxy delaying one already-applied settings acknowledgement. Thirteen
checks pass with no skips: two long runs, transcript reads during those runs,
mid-run reload/live-tail recovery, draft preservation, delayed acknowledgement,
cross-window selection, stale write refusal, a durable mid-run failure while the
other run remains active, ordered rows, exactly one tool effect, pinned in-flight
models and the next run's changed model. Reports retain owned PID exit evidence.
The proxy forwards coherent upstream Host/Origin headers; production origin
protection stays enabled. It never instruments or reloads the user's windows.

Three read-only live `/models` samples while idle took 923/31/29 ms. They do not
settle congested latency; the existing eight-second browser deadline is unchanged.
The two-window scratch transcript samples were 3–4 ms in the recorded run. Small
fixture samples establish the repaired paths, not freedom from every overload.

Graph impact initially found 28 resolved caller leads. After reading agent pinning,
spell state and model-route callers, the follow-up found zero unread resolved
leads, with 217 coverage gaps and 476 relevant unresolved calls (truncated).
the audit is an omission detector, not a correctness certificate. Full combined
gate, independent exact-tip review, installed evidence and wave convergence are
separate required proofs and are not claimed by these focused results.
