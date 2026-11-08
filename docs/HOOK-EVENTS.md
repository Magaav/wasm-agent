# Hook/event inventory and beforeFinalAnswer evaluation

> **This file is the inventory.** The hook *engine* - the config files, the Claude Code compatible
> protocol, the mods surface and the pass/fail rules - is [HOOKS.md](HOOKS.md) and
> [MODS.md](MODS.md). The engine can also run as the `wa:hooks` component, off by default: see
> [The engine as a component](#the-engine-as-a-component-wahooks-off-by-default) at the end of this
> file. The catalogue below describes what exists as events and event jobs; `/hooks`
> shows which hook points are actually configured on this node, and what the last one did.

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

## onFinalAnswer: the identified answer, once per run

`onFinalAnswer` is the one lifecycle event that says a run's answer has been identified. It is a
native run event, produced at the boundary `lua/core/agent.lua` already owns: the durable assistant
row for the answer is written and the run is about to emit `reply`, so a later step cannot un-answer
it. It is emitted through the same host stream (`self.emit` -> `host.stream`) every other lifecycle
event uses; it calls no model, adds no endpoint and blocks no render.

Payload is ids and lengths only - never the answer text:

```json
{"type":"final_answer","session_id":"...","run_id":"...","message_id":"...",
 "answer_id":"<run_id>:answer","text_len":1234,"at":1792500000000}
```

`answer_id` is derived from the run and stable across a replay of the same run; `at` is epoch
milliseconds. The producer emits at most once per run (`final_answer_emitted` is set before the
emission), and a run that produced no answer (cancel, failure, commentary-only) emits nothing. The
window's consumer (`ui/app.js`) applies the same rule: a repeated event for the same
`run_id`/`message_id` is refused before any handler runs, so a replayed run/message cannot fire it
twice. Handlers are called synchronously and a throwing handler is recorded (`finalAnswerHookError`)
rather than allowed to lose the answer; the page also dispatches a `wa-final-answer` `CustomEvent`
with the same payload. This is notification, not task correctness, and it grants no authority.

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

## The engine beside this inventory

The catalogue above is a curated list with claims about boundaries. The engine
(`lua/core/hooks.lua`) is the executable half: the same boundaries, named as hook
events an operator can attach a command to. The differences that matter when
reading both:

* `Stop` is the identified-answer boundary this file calls `onFinalAnswer`: a
  completed no-tool candidate, before final commit, after cancellation and
  steering checks. The engine fires it there and its payload is ids and lengths
  only (`message_id`, `text_len`) - never the answer text. A `decision:"block"`
  asks the run to continue (bounded), `continue:false` keeps the answer.
* `PreCompact`/`PostCompact` exist as hooks; the inventory has no row for them
  because no job reads them. A `PreCompact` refusal is visible and can leave a
  caller with its own `context_overflow` - that is the operator's choice.
* `Notification` is produced where the agent already tells the reader something
  that is not the answer (a wave-closure notice, a failed closure report).
* `PreDeploy`/`PostDeploy` are `/update`'s request boundary. `PostDeploy` means
  the sentinel named a durable request (`queued=true`, `installed=false`); it is
  never an install.
* `ComponentInstall`/`ComponentSwap` are the service registry's install and
  switch boundaries (`lua/core/services.lua`).
* `SelfWake` is the self-loop's turn boundary (`lua/core/selfloop.lua`), and it
  may veto a wake, with an optional `reschedule_seconds`.
* Any bus topic is a hook source (`bus:<topic>`, `bus:*`) through
  `selfloop.publish`. A hook is told the fact and cannot veto it.

`beforeFinalAnswer` is still not implemented, and the engine does not pretend
otherwise: the reliable boundary remains `Stop`, and it is still before commit
and after the checks, not before streamed text.

## The engine as a component (`wa:hooks`, off by default)

Status: **landed behind `WA_HOOKS_COMPONENT=1`**, with the native engine in `lua/core/hooks.lua`
untouched and parity asserted (`scripts/test-hooks-component.lua`, 33 comparisons; the four native
suites - engine 136, tools, agent, mods - run on both paths through
`scripts/test-hooks-component.sh`). Without the variable, every line of this document describes code
that has not moved.

The split is **the rules move, the hands stay**. `wit/hooks/hooks.wit` exports `wa:hooks`, served by
`rust/components/hooks` and `rust/wa-kernel-runtime/src/hooks_host.rs`; the component:

* reads the four config sources *as text the node hands over* and merges them (both shapes: this
  node's `hooks.json`, Claude Code's `matcher` → `hooks[]` wrapper with `timeout` in seconds);
* evaluates a matcher (a **Lua pattern** against the lowered name, a plain word as a case-insensitive
  substring - `bash|shell` is a literal, because Lua patterns have no alternation, and that is the
  behaviour both paths keep);
* orders an event's entries, clamps a per-hook timeout (default 5 s, cap 60 s, floor 0.1 s) and names
  an unknown event in the errors list instead of dropping it;
* interprets one hook's answer - exit 2, `permissionDecision` allow/deny/ask, `updatedInput` merged
  over the arguments, `additionalContext`, `continue:false`, `decision:block/approve`,
  `systemMessage`, `reschedule_seconds` - into the same verdict the callers already read, with the
  documented bounds (8 KiB stdout, 2 KiB stderr, 4000-byte context, four 500-byte messages);
* answers the catalogue, the footer segments (`statusline`) and the merged view `/hooks` renders.

Four things stay in the node, each because a guest cannot do them or must not own them:

| stays native | why |
| --- | --- |
| reading `hooks.json` / `.claude/settings.json` | a component has no path to the operator's config directory and no grant to it; the text crosses, the parse does not |
| **running a hook** | a command hook is a process with the node's grants (`host.exec`, its own deadline, its capped output); a Lua plugin hook is a function in this interpreter |
| building the payload envelope | `session_id`/`run_id`/`cwd`/`node_id`/`role` are the host's identity, and `session_id` is not the component's to mint |
| the outcome log, redaction and rendering | a hook's words pass through `lua/core/redact.lua` and `host.log`, and `/hooks`' text lines are rendered from the facts the component returns (so the text is identical on both paths by construction) |

What the component **cannot** do is the grant, and that is the point: its manifest declares no
`capabilities` and its world imports nothing, so `host.hooks` can read no file, open no socket, run no
process and read no secret. `cargo test -p wa-kernel-runtime hooks_host` asserts the manifest and walks
the artifact's imports (tier A WASI only, nothing from `wa:kernel/`). A **mod** registered through the
engine is therefore still a command the operator wrote, run by the node under the node's grants - the
component decides *whether* it runs, never *with what*; and a mod that wants a capability the node
does not grant cannot obtain one through `wa:hooks`.

The seam is deliberately two calls, not one: `configure` (cached per config generation) + `entries`
(cached per event and tool) say what runs, and one `decide` per hook answer says what it means. The
verdict has to be consulted between hooks because a refusal ends the event - running hook N+1 after
hook N denied is a side effect the native path never had. Cost, crossings and RSS:
`docs/CORE-SPLIT.md`, "Cost".

Deliberate differences, both visible rather than silent:

* a **clip** counts bytes and appends `…` (native `#value`), but here the cut backs off to a character
  boundary: a byte slice that is not UTF-8 cannot cross the seam, so a hook that prints a multi-byte
  character exactly at byte 8192 is clipped one character earlier. For ASCII (every config, every test)
  the two are identical;
* a payload a hook rewrote is re-encoded by the component (key order preserved), so a later hook in the
  same chain sees the same bytes but not necessarily the same whitespace as the native path's
  `json.encode`.

Not done here, and needing the integration step that lands this: `docs/HOOKS.md` still says "Not built,
on purpose: hooks as WASI components" and carries the sketch this component implements; that section
and the `components.lock` pin (the component is currently only reachable through
`WA_HOOKS_COMPONENT_WASM`, the development override) belong to the lane that ships the artifact.
