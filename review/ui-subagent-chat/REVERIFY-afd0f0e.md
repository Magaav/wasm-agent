# Re-verification on `afd0f0e` — the producer's response to the review of `340b7c2`

- Tip **afd0f0e2f3cf7df6365b1a395da70c5ea4515a73**, tree `ccb782d62c98233de2edcffee84a3357bba12439`
  (re-derived), one commit on top of the reviewed tip, +288/−60 over `DESIGN.md`,
  `scripts/probe-ui-subagent-chat.ps1`, `scripts/test-ui.ps1`, `ui/app.js`.
- Same reviewer lane: session `child:dispatch:67be1595-571f-460f-9908-e0d123ceafa0`, worktree
  `C:/Users/Victor/.wasm-agent/wa-worktree-childdispatch67be1595-571f-460f-9908-e0d123ceafa0`, review
  branch `review/ui-subagent-chat` rebased onto this tip. Not pushed; canonical tree and window untouched.
- Verification is this lane's own reading, instruments and re-runs (the previous review's instruments
  still apply); the model family is unchanged, so no second model checked this either.

## Verdict on this tip: `narrowed`

The delta fixes all four findings of the first review, and I reproduced each fix with my own
instruments — including a **node-level** measurement of the page-size rule, not the producer's JS
fixture. Two claims are still narrower than stated: the page-budget adaptation is not paid "once for
the window" (it is paid once per *concurrent* first read), and the new durable lane block does not pin
the row's reason, which is where the original lie lived — a mutation that keeps the state right and
restores the lie **survives `scripts/test-ui.ps1`**. Neither should block landing.

## What I ran on this tip

| Run | Result |
|---|---|
| `powershell -File scripts/test-ui.ps1` | **exit 0**, `  ok   UI structure, mid-run reload, and startup recovery` — matches the producer's claim |
| my `probe-claims.js` (the five claims, 27 checks) | **PASS 27/0** — no regression from the delta |
| my `probe-lane-attack.js` (the original attack) | **PASS 3/0** — was FAIL on `340b7c2`; the producer's claim is confirmed |
| my `probe-lane-shapes.js` (new: four recorded shapes, the reason text, a lane with no session row, the sentinel key) | **PASS 7/0** |
| my `probe-page-budget.js` (new: visible, bounded, failure not swallowed) | **PASS 7/0** |
| `WA_SCRIPT=probe-page-budget.lua wa.exe --db <scratch>` at four budgets | the node's own rule, see below |
| `controls-suite.mjs` — 8 one-thing-reverted mutations of the delivery's own `test-ui.ps1`, in a copied tree | 6 RED, 2 GREEN (one intended) |
| my original `controls.mjs` — 6 mutations on this tip | 5 caught, same as on `340b7c2` |

### The node-level measurement (`page-budget-node-measurements.txt`)
`lua/core/session_view.lua` + `tool_output.lua` from **this tip**, run inside `wa.exe` against a scratch
home and database (never the live node):

| `WASM_AGENT_TOOL_OUTPUT_BYTES` | `MAX_BYTES` | `byte_limit=40960` | `byte_limit=20480` | unsized |
|---|---|---|---|---|
| unset | 51200 | **accepted**, 12 rows | accepted | accepted |
| 8192 | 8192 | **refused** `invalid_session_byte_limit` | refused | **accepted**, 12 rows |
| 4096 | 4096 | **refused** | refused | **accepted**, 5 rows |
| 1024 | 51200 (guard ignores <4096) | accepted | accepted | accepted |

This reproduces the producer's claim (40960 accepted at the default, refused at 8192/4096, unsized
still accepted) and adds the two things it did not say: the guard keeps `MAX_BYTES ≥ 4096`, so the
unsized fallback is *always* inside the accepted range (`≥1024`), and a lowered budget costs rows
(12 → 5), not the transcript.

## Findings from the first review — each re-checked

1. **`lane-main-only` — resolved.** `laneChecklist` now derives the outcome from
   `lane.branch || lane.worktree`, the same facts the key uses, and names the checkout it holds. My
   attack probe passes. My lane-shapes probe passes for the four recorded shapes (branch lane,
   released lane keeping its worktree, worktree-keyed lane with no branch, node's own checkout), for a
   child with **no session row** (its own `no recorded checkout` lane, four `unknown` outcomes), and it
   also asserts the **reason** names the checkout the lane holds. Mutating the derivation back to
   `lane.branch ? 'no':'yes'` turns the durable suite red (s1).
2. **`session-page-byte-limit` — resolved.** `panePage` asks for the big page, and on
   `invalid_session_byte_limit` re-reads with no `byte_limit`, remembering the answer per window. My
   probe: all three panes paint their transcript, every pane's notice reads
   `page 40 KiB refused (invalid_session_byte_limit): reading the page size the node chooses`, the row's
   `title` carries `WASM_AGENT_TOOL_OUTPUT_BYTES`, and **when the unsized read fails too the pane shows
   `Conversation unavailable: fixture_page_unavailable`** — the real failure is not hidden by the note.
   Removing the adaptation turns the durable suite red (s2).
3. **`test-coverage` — resolved.** The child-pane checks now drive the production seam: a stubbed
   `action:'session'` route the app really calls through `refreshAgentPane` → `panePage` →
   `paintChildTranscript`; the sidebar check names the card it keeps; the lane block exists with four
   lane shapes, per-lane outcomes, the lane paths and a pinned pane painted by the app's own refresh.
   Making the production refresh stop painting turns it red (s7); emptying the checklist (s4), fixing
   the lane key (s3) and hiding the lane path (s6) each turn it red. No test-only renderer hook is used
   for the pane assertions any more.
4. **`claim-scope` — resolved.** `DESIGN.md` now states that `merged` and `clean` are git facts this
   view is never given and read `unknown` for every lane, rather than measurements it withholds.

## What is still narrower than claimed

5. **`page-budget-once-per-window` — unresolved.** Measured request log for three panes: six *refused
   sized* requests (`child-a`, `child-a`, `child-b`, `child-a`, `child-b`, `child-c`) before the first
   unsized read, then 31 unsized and **no further sized attempt**. The memo is per window and it
   converges, but the refusal is paid once per *read already in flight*, because `pin()`
   (`components.js:2163`) dispatches an `orchestrator-action` `layout` event and the handler
   (`app.js:4594`) fires `refreshAgentPane(pane)` for every pane **without awaiting**. Bounded
   (≤ in-flight reads), self-correcting, no loop — but "once for the window, not per pane" is not what
   happens, and a plan that pays one round trip per pane on the first poll would be a small waste
   rather than a bug.
6. **`test-coverage-reason` — unresolved.** The durable lane block pins `data-state` and the lane path,
   never the row's `title` reason. A mutation that leaves every state correct and restores the old
   lying reason (`this lane holds no branch of its own: its children work in the node checkout` on a
   lane that holds a worktree) **passes `scripts/test-ui.ps1` unchanged** (s5 GREEN). My
   `probe-lane-shapes.js` fails it, so the behaviour is checkable — it is just not in the suite. Half of
   the original finding lived in that string.
7. **`lane-key-sentinel` — unresolved (hazard, reachability unproven).** `MAIN_LANE = 'main'` is a
   sentinel filled with a *branch name*: I demonstrated in the DOM (lane-shapes probe records it, not
   asserts it) that a session whose recorded branch is literally `main` merges into the node-checkout
   lane, so that lane then holds a child with no checkout at all and reports `main-only: no` with the
   reason `this lane holds a checkout of its own (C:/work/wt-sentinel)` beside a child that has none.
   The allocator always writes `change/wa-session-<id>` (`workspaces.lua:340`), and I found no path that
   records `workspace_branch='main'`, so I could not show such a row exists.

## What is not proven

- Everything UI-side is measured against stubbed node answers; the node-level page-size measurement is
  real (scratch node, this tip's Lua) but it exercises `session_view.get` directly, not a live
  dispatcher with a real child.
- The five product claims were re-measured on this tip at one layout (754x440, dpr 1) plus the
  durable suite; the previous review's 1280x900/screenshot leg was not repeated.
- The lane-key hazard's reachability, as above.
- I did not run the full repository gate, did not push, did not merge, and did not touch the canonical
  tree, the installed UI or the running window.

## Should this block landing?

No. The four findings are fixed and independently reproduced, including the node-level rule behind the
page-budget fix. Recommend, as follow-ups rather than blockers: pin the lane row's reason in the
durable block (or accept that only the state is durable) and, if the extra round trip matters, learn the
page budget once before fanning out (`panePageBytes` known before `allPanes()`), or await the `layout`
refresh that `pin()` fires per pane.

## Evidence added by this re-verification

`probe-lane-shapes.js`, `probe-page-budget.js`, `probe-page-budget.lua`, `controls-suite.mjs`,
`page-budget-node-measurements.txt`, `suite-mutations-afd0f0e.txt`, `facts-tip-claims.json`,
`facts-tip-lane-attack.json`, `facts-tip-lane-shapes.json`, `facts-tip-page-budget.json`. `VERDICT.md`
remains the review of `340b7c2`.
