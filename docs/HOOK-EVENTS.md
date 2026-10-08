# Hook/event inventory and beforeFinalAnswer evaluation

Engine gains a read-only **hooks / events** topic beside Jobs. This inventory is
not a new executor, subscription registry, trigger, watcher or approval. Existing
Jobs remain the only management surface for installed trigger/action definitions.
No hook is enabled, disabled or run by viewing its event.

## Inventory contract

Master-only `POST /jobs {action:"hooks"}` returns a versioned catalogue built from
versioned native declarations shipped with the running Lua source and the same
local job store the Engine uses. Native rows are curated, not automatic callback
reflection or a claim of exhaustive event discovery; they name their known producer,
boundary, handler and reliability limits. Event-job
rows are derived from current `trigger.kind=event` definitions, grouped by topic;
handler enabled/revision/queue/last outcome come from the job store, never from a
hard-coded list of approved jobs. Schedule/CDP/file jobs remain in Jobs.

Native callbacks, display telemetry, opt-in pre-answer checks and repository Git
hooks are labelled separately. `beforeFinalAnswer` is visibly **not implemented**;
it is evaluated, not registered or emitted. Native source availability is not
proof that a watcher is live, a delivery finished, a task is correct or an external
effect occurred. Installed/compiled source describes this node's capability;
repository Git hook paths describe declarations, not universal enforcement.

The route remains owner/master protected, spends no model call and mutates no job
revision, queue, transcript, Git ref or resource claim. Store failure is visible,
not replaced by a catalogue pretending every handler is disabled. Private event
payloads, prompts, credentials and entire transcripts are not returned. Job
handler facts expose only ids/names, action kind, enabled state, revision, queued
count and existing last delivery status/detail. UI renders all names/details as
text, not HTML. Target/epoch fencing prevents a delayed response painting another
node's inventory. Loading/error/unsupported states never claim a successful empty
catalogue. This view has no toggle or action controls.

## Reliability: what beforeFinalAnswer can mean

There is no present event by that name. `final_answer_begin` is provider-phase
**display telemetry**, not a commit/check barrier:

- Native Responses may emit explicit final phase before first text, but the
  provider can omit phase, emit it late, later select tools, or fail/cancel.
- Pi fallback exposes explicit phase only at text_end, after text deltas were
  already shown. Unknown phases resolve at harness reply.
- A candidate without tools can still be superseded by queued steering or the
  opt-in patch audit. Several candidates can occur in one run.
- A crash before the boundary emits nothing; a crash after a handler starts can
  leave its effects unknown. Notification receipt is not handler completion.

Therefore an early provider-based beforeFinalAnswer event is **not reliable for
worktree mutation, automatic commit/merge or installation**. It can never promise
that an answer will ultimately settle. A reliable narrower event is feasible at
the harness's no-tool completed-candidate boundary before final transcript commit,
after cancellation/steering/audit checks. Name it **beforeFinalCommit** or document
beforeFinalAnswer as this exact boundary. It is before commit, NOT before streamed
text unless generation is explicitly buffered behind a publication barrier.

For execution handlers, require a durable candidate id/revision and prepared
record before delivery; dispatch deterministic checks synchronously (same-session
wake would queue behind itself). Revalidate source/workspace and steering after
checks; invalidated candidates cannot settle. Unknown handler effects require
reconciliation, never replay. Read-only inconsistency checks can report exact
facts; autonomous branch repair needs separately approved ownership/effect rules,
and cannot be granted by an event name. Failure/cancelled/interrupted runs need
separate terminal events, not a fake final-answer event for universal coverage.

Exactly-once external effects across crashes are not supplied by the catalogue or
ordinary job dedupe. Event existence can be made durable per candidate; eventual
successful final answer cannot be guaranteed. Timing and correctness are separate.

## Focused evaluation

Use the actual agent/Responses loop fixtures for tools after candidate text,
steering, queued followup, unknown phase, commentary-only, cancellation and failure.
Count candidate begin versus durable final reply and their order. This proves why
the display event cannot serve as a universal before-final hook. Private catalogue
checks cover role isolation, dynamic event topics, disabled and unknown deliveries,
unsupported/malformed stores, safe text rendering and stale target replies. Run
`scripts/test-ui.ps1` and dedicated real-browser inventory probe. No paid provider,
live job enable, new event emission or full release gate is part of this task.

Observed source proof:54 catalogue assertions (27 disk/27 embedded),10 dedicated
real-browser assertions plus a failing private empty-handler mutation, and the
required UI suite pass. Actual unchanged agent/Responses loop55 assertions plus7
boundary comparisons reproduce all listed non-universal cases. Measurement packet:
[measurements/hook-events-20261008.json](measurements/hook-events-20261008.json).
These are focused source/UI checks, self-review, not live installed proof.

Reuse `node scripts/test-hook-events.cjs <absolute-built-wa> <fresh-evidence>`
and its `--post` mode for source/binary/log hash verification. The recorded
`hook-events-route-proof` spell contains that verified consecutive sequence;
replay refuses enforced worktree bindings, so retain the direct CLI without
weakening the binding until spell replay itself passes. Evaluate timing with
`scripts/evaluate-before-final.cjs`; it executes real loop logic with fake HTTP,
not provider inference.
