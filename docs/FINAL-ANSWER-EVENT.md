# Final-answer display boundary

`final_answer_begin` is display telemetry, not a model control/tool or an additional generation stage. Pi-style tool/steering/followup decisions are unchanged.

Native Responses emits at explicit message `output_item.added.phase=final_answer`, before first text when supplied. Identity: run_id, response_id (if known), message_id (provider item or stream/block fallback), pending_id, source. Duplicate added/done items do not duplicate display. A late explicit done phase emits with timing=late. Unknown items remain provisional; response-global stopReason cannot classify another item.

Installed Pi fallback waits for explicit text_end signature; it does not promise pre-text detection. Unknown phase waits for harness reply. Begin is neither response completion, run settlement nor task correctness. A later tool/round releases the answer anchor and retains preceding candidate text as activity.

The shared renderer collapses preceding activity on explicit begin and renders streaming Markdown outside its run topic. The reading anchor starts at the first visible `delta` or provisional `pending_delta`, not only at provider begin: short output grows upward until its first line reaches the chat viewport top, then additional output grows below without chasing the tail. Provisional text remains visibly unclassified; scrolling never grants final-phase or task-completion authority. Explicit begin/reply transfers the reading anchor to the resolved answer. Commentary/tool/round transitions release it without losing text.

All visible text deltas, including provisional/late-phase streams, render through the existing safe Markdown renderer immediately; headings, emphasis, lists and open code fences do not wait for `text_end` or `reply`. Raw source bytes remain beside the presentation, provisional/incomplete labels stay intact, and phase resolution still replaces text exactly once. Risk: incomplete Markdown can reflow as delimiters arrive; the existing reading anchor and manual-release behavior remain authoritative. The browser probe checks split emphasis, open fences, safe links/literal markup and formatting before completion across explicit/provisional/unphased streams. Rendering reparses the accumulated segment, as the explicit-final path already did; this is not a constant-time incremental parser.

Delayed scroll events at the exact last programmatic pin are ignored even after the animation-frame guard clears. They must not set `answerReleased` or suppress late final-phase transfer. Reader gestures clear that expected-position marker and still release immediately; a different scrollbar position remains manual. The browser regression now covers both delayed own-scroll delivery and `reply` → `done` → real frame settlement, not only growing output.

A reader already in scrollback is never pulled to a new answer. Wheel/touch/navigation/manual scroll releases the anchor; jump-to-latest explicitly opts back into tail following. Main and child positions remain container-scoped. Existing replay/checkpoint/high-ID handling remains in place.

Risk: without an early provider phase, provisional text also uses this reading policy and can later resolve to commentary. It stays labelled provisional and preceding activity is not collapsed until the existing explicit boundary. `scripts/test-final-answer-ui.js` covers 24 asynchronous chunks per explicit/pending/unphased stream, short upward growth, long first-line/scroll-position stability, late resolution, scrollback and jump opt-out, narrow-window appearance and existing child/gesture races. `scripts/test-ui.ps1` runs this through the normal final-answer suite. `scripts/test-final-answer-reading.cjs <fresh-absolute-evidence>` then `--post` verifies source and retained screenshot/DOM hashes. This is focused self-review/browser proof, not paid-provider or release certification.

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
