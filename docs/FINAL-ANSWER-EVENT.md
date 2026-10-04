# Final-answer display boundary

`final_answer_begin` is display telemetry, not a model control/tool or an additional generation stage. Pi-style tool/steering/followup decisions are unchanged.

Native Responses emits at explicit message `output_item.added.phase=final_answer`, before first text when supplied. Identity: run_id, response_id (if known), message_id (provider item or stream/block fallback), pending_id, source. Duplicate added/done items do not duplicate display. A late explicit done phase emits with timing=late. Unknown items remain provisional; response-global stopReason cannot classify another item.

Installed Pi fallback waits for explicit text_end signature; it does not promise pre-text detection. Unknown phase waits for harness reply. Begin is neither response completion, run settlement nor task correctness. A later tool/round releases the answer anchor and retains preceding candidate text as activity.

The shared renderer collapses preceding activity on explicit begin, renders streaming Markdown outside its run topic, anchors the answer start, and releases on reader gesture/manual scroll. It does not mark the task done. Existing replay/checkpoint/high-ID handling remains in place.

Adjacent targeted discovery: POST /subagents {action:'lookup_session',conversation_id:thread}, response {task:latest owner-scoped native summary|null}. No list fallback. Existing authenticated apiFetch routing applies. Backend implementation is another lane; combined wiring needs independent review.

Focused entrypoints: scripts/test-final-answer.lua (WA_SCRIPT with WASM_AGENT_LUA_ROOT set to repository root), scripts/test-final-answer-ui.js via agent-benchmark-ui-observe.mjs, scripts/test-ui.ps1.

Observed: synthetic wire causal checks pass; dedicated headless UI probe passes; test-ui.ps1 passes all four stages. Private assertion mutation failed and was restored. Screenshot inspected: collapsed run above readable Markdown, composer unaffected. Raw artifacts retained under evidence-final-answer/ and evidence-final-answer-mutation/ in the owned tree (not delivery source).

Limitations: no paid model or live deployment; native early timing is synthetic protocol evidence, not a new measured live final-phase fixture. Dedicated cancellation/failure/steer/followup and pixel scroll-growth tests, complete shared replay causal additions, per-message multiple-final candidates, and event-contract completeness still need independent review/additional work. No full gate: gate_verified:false, release_verified:false.
