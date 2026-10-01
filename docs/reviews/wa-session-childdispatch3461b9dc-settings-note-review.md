# Review: the settings note is derived from the node's answer

Reviewed delivery: `change/wa-session-childdispatch3461b9dc-72a1-4861-8312-27fbd687ab3e`
Reviewed tip: `0bcba8a24ecf3b07a44bef2769e4ea1f8f9eb7b0` (tree `a873568d520a1af0ac1e1ee0f3abf1d12dee9ef1`, parent `c21382b`)
Reviewed delta: `git diff c21382b 0bcba8a` — `ui/app.js` (+47/-16), `scripts/test-ui.ps1` (+32/-7)

Verdict: **narrowed**. The delta is a strict improvement over `c21382b`, and both residues it
addresses are closed on the ordinary path. Its headline claim — the note now says what the node
reports — has one reachable counterexample, below, and that is the condition of this acceptance.

Reviewer: `child:dispatch:edaa9eb0-19e5-4a83-93a9-c781acd252cf`. Reviewed in the reviewer's own
worktree; the producer's branch was fetched, never written.

## Teeth (independent rerun)

Parent `ui/app.js` (`7480926728e7ae3e748cc7b340737c0cd1c7afa6`) with this tip's test files
(`scripts/test-ui.ps1` `9c56bf0d…`, `ui/test-fixtures.js` `1578a87b…`):

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1

fails, **7 checks**, including both note-wording ones and the exact-string pins:

- `an unanswered settings change must leave the controls on the node answer, saw openai-sub / deepseek-v4.1-flash`
- `an unanswered change must be reported as unconfirmed with the node answer, never as not applied, saw: unsupported_reasoning_level`
- `and the note must say it is in effect, not deny an applied change, saw: unsupported_reasoning_level`
- `a write the node applied after the abort must show the node answer, saw openai-sub / deepseek-v4.1-flash`
- `a refused settings change must be reported in the node words with the node answer, saw opencode-go / settings_refused_by_fixture`
- `and the model list and LIMITS must be re-read from the same answer, saw 5h limit7%resets in 3h 14m`
- `a change refused during a run must leave the control on the node answer (fixture), saw openai-sub`

The same suite on `0bcba8a` unchanged (`ui/app.js` `237f4576331743b57ac668de2c42256e2cb94e61`) prints
`ok   UI structure, mid-run reload, and startup recovery`, exit 0. The tip's notes are pinned as
exact strings, so the wording itself is now a tested property.

## Counterexample (unresolved, class `note`)

`refreshMeta()` returns `true` **without merging** when the conversation changed while its read was in
flight (`ui/app.js:3222`: `if (chatSession !== target || conversationEpoch !== epoch) return true;`).
`reconcileControls()` reads that `true` as "this is the node's answer", so its sentence *"the node now
reports `<pair>`"* can be printed from a read that never arrived — and on the abort variant it denies a
change the node applied, which is the symptom this commit set out to remove.

Reproduction (reviewer harness, `scripts/test-ui-adversarial2.ps1`, spliced into a scratch copy of the
tip's suite at the marker `document.title = "stage: logging";`):

1. gate the `models` fetch so the re-read can be held open (`window.fetch` wrapper);
2. send a settings change and let it fail (refusal payload, or `settingsAbort` for the client-side abort);
3. while the re-read is in flight call the application's own thread switch
   `rememberSession("11111111-2222-3333-4444-555555555555")`;
4. release the read and read the note back.

Observed, with the node's answer in that read being `the-node-says-this / node-model`:

- refusal: `not confirmed — settings_refused_by_fixture; the node now reports opencode-go / deepseek-v4.1-flash`
  while `settings.provider` was never merged (`opencode-go`), i.e. the note names a pair the read did
  not contain;
- abort: `not confirmed — no answer within 8s (the request was aborted); the node now reports opencode-go / deepseek-v4.1-flash`
  — the change *was* applied by the node and the window's own (skipped) answer said so.

The controls stay internally consistent with the note's pair (both come from the window's last merged
payload), so no false *control state* is displayed; what is false is the assertion that the node just
reported it. Reachability: the window is one `GET /models` round trip (25–70 ms measured, 0.64 s under
load, per the producer's own commit message), and the epoch bumps on operator actions the app takes
normally — opening another thread, `resumeSession`, `newThread`, and `learnSession` adopting a session
id when the window has none. Narrow, not exotic.

Cheap fix: have `refreshMeta()` distinguish "read and merged" from "skipped" (return the payload, or a
sentinel), and treat a skipped read as *not re-read*, so the note falls back to
"the node could not be re-read, so this still shows `<pair>`".

## Second finding (unresolved, class `wording`)

When the value asked for already equals the value the node reports, a **refused** write is announced as
in effect: asking for the provider the node already reports, with the write refused, produced

    in effect — settings_refused_by_fixture; the node reports opencode-go / deepseek-v4.1-flash, which is what was asked for

The state does match the ask, so "in effect" is true of the state, and the refusal reason is printed
next to it; but the leading word reads as acceptance of a write the node refused. Reachable only if a
`change` event fires with the value already current (a real `<select>` does not fire `change` for the
same value), so this is low-reachability: recorded, not a blocker.

## Third finding (unresolved, class `hardening`)

Residue 2 of the previous review was closed only on the success path. If `renderControls()` throws
inside `reconcileControls()` — the *failure* path — `post()` still rejects, so the listeners' new
`.catch` writes `the change could not be sent: TypeError: providers is not iterable` (the write *was*
sent) and nothing is redrawn. Observed: `post=rejected: TypeError: providers is not iterable`, the note
left at its previous text, `provider-select.value` empty. The trigger is a malformed settings payload
(`providers` as an object), which this node cannot send: `lua/vendor/json.lua:68` encodes an empty Lua
table as `[]`, and `M.providers()` (`lua/core/provider.lua:41`) is a hardcoded three-entry list. Same
reachability caveat as the previous review's residue 3.

## What this delta fixed (verified)

- Round-1 residue 1 on the ordinary path: an aborted write the node applied now reads
  `in effect — no answer within 8s (the request was aborted); the node reports openai-sub / gpt-6-luna,
  which is what was asked for`, and the suite pins that exact string.
- Round-1 residue 2 on the success path: a payload that makes the render throw now leaves
  `the change was applied, but the controls could not be redrawn: TypeError: …`, with `post()` resolving
  rather than rejecting.
- The `not sent` prefix holds only when nothing was sent: with a run in flight, `postsSent=0` and the
  note began `not sent — a run is in flight, so this change applies at the next turn`.
- No path writes `not applied` any more: the only occurrence in the tip's `ui/app.js` is the prose
  of the comment at line 2542, and no `settingsError.textContent` assignment contains it (the writers
  are lines 2534, 2537, 2552, 2556 and the two listeners' catches at 3038/3040). `reconcileControls`
  has exactly two callers, both in `post()` (2495 busy, 2518 failure), so `in effect` can only be
  printed after a reconcile.

## Not tested

The live node, and any real `POST /provider` (it changes the operator's state). The live 8-second
abort: headless virtual time does not advance timers, so the abort is injected as the same
`DOMException` the fixtures raise. Visual appearance and native `<select>` popup behaviour. The full
gate was not run — the lane owns it and the tip already carries a gate receipt.

Agent: wasm-agent node=wasm_the_first role=reviewer session=child:dispatch:edaa9eb0-19e5-4a83-93a9-c781acd252cf
