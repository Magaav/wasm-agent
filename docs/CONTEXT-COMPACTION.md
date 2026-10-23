# Measured-prefix context compaction

The operator requested compaction at90–95% instead of observed50–60%, unless an earlier policy has evidence of better outcomes. No such outcome evidence supports the old behavior.

## Idle maintenance (40%)

`onStale` is triggered once by `node.run_finished` after a **main** run settles; it is not
a 30-second schedule. The event is `{"session","run_id","at"}`: onStale reads the top-level
`session` from the retained event JSON (`WA_JOB_EVENT_FILE`) and posts `/compact` with
`min_percent:40` **and that `session_id`**, so idle compaction targets the main session whose
run just finished. With several main threads, "the newest main session on this node" is a
different thread often enough that a session-less request compacted the wrong one. The id is
validated against a strict character set (`A-Za-z0-9._:-`) before it is put into the JSON body;
event text is data and is never interpolated as shell. The route atomically reserves an idle
node against the next run and returns `node_busy` if another main run is still queued or running.
Subagents are out of scope: they neither trigger nor block this path, and are never summarized
here. The ordinary in-run trigger stays at capacity minus reserve (about 90–95%). This is an
additional idle path, not a lower in-run default. `WA_STALE_COMPACT=0` disables it.

Two non-event cases are distinct. If a delivered event has **no valid top-level session id**
(missing, empty, or outside the safe set), onStale logs a `MALFORMED EVENT` line naming that
event file and skips the idle compaction: it does not fall back to `/compact`'s newest-session
selection, and the unrelated staleness/deploy observation still proceeds. If
`WA_JOB_EVENT_FILE` is **absent** (a manual or direct run), onStale keeps the route's
documented behavior and posts `{"min_percent":40}` with no `session_id`, whose selection is
the route's latest-main fallback; the log says so. That fallback is not event-targeted and is
not the installed job's path.

`POST /compact` is admitted by the listener before any run or control lane: if the
scheduler has a queued/running main run, it returns
`200 {"ok":false,"error":"node_busy"}` without selecting a session or calling a
model. Subagents are excluded: they do not block and are never summarized. The
route reserves the idle gate before calling `wa_compact`; a run admitted while it
executes waits for the reservation. Master authorization and the 40% threshold
remain in Lua.

## Observed defect

Eight recent applied compactions in the same native subscription session compared the complete request's bytes/4 estimate against a1050000-token configured window. The configured reply reserve is84000, so its trigger is966000 (92%). The latest compaction recorded966734 estimated tokens while its preceding successful task request reported567352 input +492 output (567844 total,54.1% of the configured window). Other paired boundaries were464138–573650 (44.2–54.6%). These are task-provider counts, not the separate summary's usage or cumulative spend.

`agent:context_tokens` previously chose the **maximum** of provider-plus-tail and complete request JSON bytes/4. The latest retained span carried roughly2.06million characters of encrypted reasoning JSON. Ciphertext byte length is not token occupancy. New agent objects also lost their measured baseline. Full reasoning and original records must remain; deleting them is not the fix.

Exact native ledger event pairs and private installed envelope captures are retained in the authorized session's `compact-pairs-1` and `envelope-live-2` evidence generations. Eight observational samples diagnose this estimator defect; they do not rank autonomous model quality or prove a provider's undocumented upper limit.

## Policy and fences

`context_usage.lua` stores only the latest request's known, consistent provider input count, full message-prefix hash/count, exact schema hash, model, provider/endpoint/transport hash and session/user/role scope in local derived `meta`. No prompt or ciphertext is stored there. A new agent/interpreter can reuse it only when **every measured prefix message and schema is unchanged**, including system/project instructions, summary, images, phases and reasoning. Only appended messages are estimated. A matching provider measurement is not overridden by bytes/4 of already measured history.

Model/schema/scope drift, prefix rewrites or shortening, malformed metadata, missing/inconsistent usage and unavailable stores cannot fabricate a measurement. They fall back to the explicitly labelled conservative bytes/4 plus image estimate. Optional persistence failures log visibly; current-instance evidence may still be used. Compaction changes the prefix, so an old high measured count is not a floor on the new small context. No original transcript, summary generation or transport error is rewritten.

The existing per-model trigger/reserve, explicit `WASM_AGENT_CONTEXT_BUDGET` override,20k recent-token retention and one provider-overflow compaction/retry remain unchanged. The threshold decision sits inside `compact_now` itself, not in `maybe_compact`: `maybe_compact` measures and passes `trigger` but never compares it, so the wrapper is the only place that can refuse to summarise a context at or below the trigger, and a caller that reached it with a small context used to rewrite the prefix (a cold provider cache) for nothing; `force` is the overflow-recovery path and compacts regardless of the measured size. For the current1050000/84000 configuration the ordinary measured trigger remains92%; normal large-window policy is90%. Exactly92% retains the existing `<=` boundary; appended work exceeding it triggers. Cold/changed contexts are estimates, not promises of exactly90–95% provider occupancy. Explicit lower budgets or a real context-overflow refusal are justified exceptions; do not claim all providers/windows have the same verified ceiling.

Risk: this trusts a consistent provider count for an unchanged request and estimates an unmeasured tail; tail tokenization and server limits can differ. The unchanged overflow recovery is the last safety boundary, not a reason to restore the inflated maximum. No paid near-limit provider probe was run. Prompt formatting, tool availability, output-view budgets, reasoning replay and permissions are unchanged.

## The chat counter is not this estimator

The bubble's `◈` is a different, provider-derived arithmetic metric: latest task input+output minus the pre-turn task input+output baseline. An observed168494 input +1563 output −42864 baseline =127193 (127.2k). It is not168.5k current input and does not use bytes/4. Its `~` currently marks pending/incomplete observation, not estimated tokenization; current in-flight usage remains unknown until reported. Exact endpoints live in the tooltip/checkpoint evidence. See [MINIMAL-CHAT.md](MINIMAL-CHAT.md). No counter/UI behavior was changed for this estimator fix.

## Visible in the chat

A compaction is a conversation fact, not invisible maintenance: `compact_now` stores the summary row
with its `compact` trace and emits the same facts (`through`, `tokens_before`, `tokens_after`,
`messages`, `summary_model`, `created_at`) as a live `compact` event. `wa-compaction` (ui/components.js)
draws it open in the run bubble while a run streams, and `repaintMessages` rebuilds the same topic from
a stored `role="summary"` row — the idle `/compact` route and a reload both arrive that way — as a
standalone notice when no run bubble is current. It prints the stored numbers, the row's `created_at`
in the reader's local time, and says `unknown` for a value the trace does not carry. Nothing sent to
the model changes.

## Verification

Run `node scripts/test-context-usage.cjs <built-wa> <fresh-evidence>`, then the same arguments with `--post` first. It runs the source/embedded seed/restart and focused regressions, retains original logs/hashes and requires a causal old-policy failure. This sequence is recorded as the on-demand `context-usage-proof` spell; required workspaces use the verified direct CLI, not unsupported spell replay.

`scripts/test-context-usage.lua` exercises the actual agent estimator and `maybe_compact`, encrypted/raw evidence preservation,92% configured boundary, suffix-only estimates, role/user/model/schema/middle-rewrite/shortening fences, invalid usage and real transcript rebuilding. Run seed then restart with the same private DB and a fresh process, under source Lua and a standalone embedded candidate. A private old-policy mutation must fail the same oracle. Also run observability, native/legacy overflow recovery, run-counts and explicit-budget focused tests. Keep source/embedded proof distinct from exact-source Sentinel installation.
