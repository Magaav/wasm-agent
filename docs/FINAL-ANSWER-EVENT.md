# Final-answer display boundary

`final_answer_begin` is display telemetry, not a model control/tool or an additional generation stage. Pi-style tool/steering/followup decisions are unchanged.

Native Responses emits at explicit message `output_item.added.phase=final_answer`, before first text when supplied. Identity: run_id, response_id (if known), message_id (provider item or stream/block fallback), pending_id, source. Duplicate added/done items do not duplicate display. A late explicit done phase emits with timing=late. Unknown items remain provisional; response-global stopReason cannot classify another item.

Installed Pi fallback waits for explicit text_end signature; it does not promise pre-text detection. Unknown phase waits for harness reply. Begin is neither response completion, run settlement nor task correctness. A later tool/round releases the answer anchor and retains preceding candidate text as activity.

The shared renderer collapses preceding activity on explicit begin, renders streaming Markdown outside its run topic, anchors the answer start, and releases on reader gesture/manual scroll. It does not mark the task done. Existing replay/checkpoint/high-ID handling remains in place.

Adjacent targeted discovery: POST /subagents {action:'lookup_session',conversation_id:thread}, response {found:false} (task omitted) or {found:true,task:latest owner-scoped native summary}. Caller rejects malformed/contradictory replies and missing native identity; JSON Content-Type is explicit. No list fallback. Existing authenticated apiFetch routing applies. Backend implementation is another lane; combined wiring needs independent review.

Focused entrypoints: scripts/test-final-answer.lua (WA_SCRIPT with WASM_AGENT_LUA_ROOT set to repository root), scripts/test-final-answer-ui.js via agent-benchmark-ui-observe.mjs, scripts/test-ui.ps1.

Observed: synthetic wire causal checks pass; dedicated headless UI probe passes; test-ui.ps1 passes all four stages. Private assertion mutation failed and was restored. Screenshot inspected: collapsed run above readable Markdown, composer unaffected. Raw artifacts retained under final-answer-evidence/, final-answer-mutation/ and lookup-evidence/ in the owned worktree Git metadata (not delivery source). Targeted discovery contract checked against backend commit 84ba10e7; backend not merged or executed here.

## Source acceptance matrix

- Production `wire.complete` -> `host.http_sse` fake bytes -> `host.stream` -> actual unmodified `agent.run`: 55 checks, zero skips. Text then tools, explicit candidate followed by durable steering/queued followup, unknown/commentary, cancellation and failure are exercised. Interrupted/commentary-only results do not manufacture replies.
- Captured production events are fed to the real shared UI handler by `scripts/test-final-answer-browser.mjs`; corrected continuation text and interrupted candidate text survive.
- Shared `wa-agent-session` containers: child growth leaves main/sibling positions unchanged; child gesture releases that container. No substitute transcript element.
- Real headless browser timer turn races pending pin frame with wheel/manual scroll, then growth/reply: reader position retained. Large-answer pixel start, code/table growth, multiple candidates and source duplicate checks pass. Deterministic image decoding is not covered.
- Private scroll assertion mutation produced fail; restored probe passes. Existing test-ui.ps1 passes all four stages, including shared replay/reload/high-ID contracts.

Entrypoints: source-root WA_SCRIPT scripts/test-final-answer-loop.lua with private WASM_AGENT_HOME, --db and WA_FINAL_EVENTS; then `node scripts/test-final-answer-browser.mjs <events.json> <private-output>`. Logs/events/screenshots and mutation evidence retained in owned Git metadata loop-evidence/. No network/inference/bootstrap registry is launched.

Limitations: source fixture evidence, not paid/live provider timing, deployed integration or correctness certification. Followup here is queued continuation through existing steering/CLI seam, not a newly invented provider control. Independent exact-source review and combined backend discovery wiring remain coordinator scope. No full gate: gate_verified:false, release_verified:false.
