# Settings and transcript recovery

Read/control requests reserve one independent destination before enqueue. They
never fall back to a run slot, including after retirement/disconnection. When
the reserve is occupied, the listener returns `503 read_capacity_busy` promptly.
`WASM_AGENT_CONTROL_WORKERS` remains the capacity knob (default two). Risk:
simultaneous diagnostic requests can now receive explicit overload rather than
queueing; browser single-flight requests and bounded recovery backoff are required.
This does not bound slow provider catalogue/network work or SQLite lock waiting.

Startup reads the account and transcript before starting optional model metadata.
Transcript recovery reads `/session` before native session lookup; `/health` may
remain concurrent because it is listener-owned. This avoids self-inflicted
`read_capacity_busy` when another window occupies one of the two read slots.
Native lookup failures remain visible and must not authorize automatic continuation.
The tradeoff is one sequential local read, not extra capacity or hidden overload.
`scripts/test-ui.ps1` holds one simulated read slot in real Chromium and verifies
zero overload refusals during recovery, plus metadata ordering after history.
Other callers can still saturate both slots; that overload is not eliminated.

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
revisions, and reconciles other windows through same-origin invalidation plus
visibility/activity-aware fallback reads ([LIGHTWEIGHT-UI.md](LIGHTWEIGHT-UI.md)). An aborted write is an
unconfirmed acknowledgement, not proof of no effect. Its note names the observed
pair and updates on later reads if a delayed write becomes visible. Successful
rendering and failure rendering use the existing control/error surfaces.

A known conversation reads `/session` directly; `/sessions` discovery is reserved
for a new or deliberately blank window. Restoration is single-flight and retains
the last confirmed view on failure, with endpoint/phase diagnostics and exponential
backoff capped at 30 seconds. Retry diagnostics and known-active unfinished
notices now use independent causes in the shared top warning, not run status or
transcript rows ([MINIMAL-CHAT.md](MINIMAL-CHAT.md)). Successful recovery clears its failure state. The
follower advances only through rows actually loaded, before reconciling checkpoint
and event cursors. Reconnect never re-executes a tool; existing guarded continuation
requires a complete recorded batch and an unchanged durable sequence.
Every awaited recovery branch also rechecks node/thread/epoch identity, including
the idle-tail second read, health reconciliation and checkpoint ledger refresh.
Node selection advances the epoch and resets node-specific follower state. A
replay response also belongs to its captured run and polling owner.

A new Send/Continue in the **same conversation** advances a submission generation:
older transcript, health, native-journal and event-tail observations cannot repaint
it even if the new stream finishes before they return. Own SSE (including its
pre-admission health wait) retains renderer ownership until its existing cleanup;
idle health alone cannot free it. Its exact-run watchdog remains the recovery path
for a lost stream. Read restoration refuses while that own stream is active,
without moving loaded-row cursors or replacing the optimistic user/request bubble.
New submission seals prior text/reasoning/tool buffers before the new user boundary.
After actual stream release, ordinary durable repaint/reload remains available.
No new timer/poll/backend event, inferred effect, request replay or ledger rewrite.
Risk: history refresh waits for stream release; retained live output is authoritative
for that view in the meantime. `scripts/test-turn-ownership.cjs` holds the real
browser Send/Continue SSE and delays an older same-thread read; it fails on the
previous UI, passes with the fence, checks unchanged old answer/footer and exact
ordered request/answer bubbles, stale idle health and post-settlement stale reads.
Run its retained hash `--post`; the normal UI suite includes it.

## Focused evidence, before integration

`scripts/test-ui.ps1` passes in real headless Chromium, including real reload,
startup failure, single-flight/backoff, preserved view, loaded-row cursor, stale
settings and cross-target response checks. Against the earlier adopted UI, the
added checks fail for ambiguous wording, immediate retry and cursor advancement.
Independent delayed-response attacks then found three late-target leaks; the
added real-browser regressions fail all three on the earlier primary tip and pass
after the per-await fences. The fixture includes a newer already-loaded target
cursor, so incidental cursor bounds cannot hide the old checkpoint's leakage.

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
The audit is an omission detector, not a correctness certificate. Full combined
gate, independent exact-tip review, installed evidence and wave convergence are
separate required proofs and are not claimed by these focused results.
