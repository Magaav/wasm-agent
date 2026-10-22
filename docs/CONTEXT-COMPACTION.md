# Measured-prefix context compaction

The operator requested compaction at90–95% instead of observed50–60%, unless an earlier policy has evidence of better outcomes. No such outcome evidence supports the old behavior.

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

## Verification

Run `node scripts/test-context-usage.cjs <built-wa> <fresh-evidence>`, then the same arguments with `--post` first. It runs the source/embedded seed/restart and focused regressions, retains original logs/hashes and requires a causal old-policy failure. This sequence is recorded as the on-demand `context-usage-proof` spell; required workspaces use the verified direct CLI, not unsupported spell replay.

`scripts/test-context-usage.lua` exercises the actual agent estimator and `maybe_compact`, encrypted/raw evidence preservation,92% configured boundary, suffix-only estimates, role/user/model/schema/middle-rewrite/shortening fences, invalid usage and real transcript rebuilding. Run seed then restart with the same private DB and a fresh process, under source Lua and a standalone embedded candidate. A private old-policy mutation must fail the same oracle. Also run observability, native/legacy overflow recovery, run-counts and explicit-budget focused tests. Keep source/embedded proof distinct from exact-source Sentinel installation.
