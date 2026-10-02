# Independent review — `change/ui-subagent-chat`

> This is the review of tip **340b7c2**. The delivery moved to tip **afd0f0e** with the producer's
> response; the re-verification of that tip is in `REVERIFY-afd0f0e.md`, which is the verdict that
> applies to the current tip.

- Delivery tip **340b7c2080f755832e05a32f7821314c98d6c798**, tree `c4031a7e196e7c06f511be6667aa895eb2496cb5` (both re-derived from the tip commit, and the tree matches the delivery record).
- Reviewer session `child:dispatch:67be1595-571f-460f-9908-e0d123ceafa0`, in its own worktree
  `C:/Users/Victor/.wasm-agent/wa-worktree-childdispatch67be1595-571f-460f-9908-e0d123ceafa0`, on
  `review/ui-subagent-chat` branched from the delivery tip. Not pushed; the canonical tree and the
  running window were not touched.
- **Independence is the lane, not the model.** `gpt-6-luna` is refused by this node
  (`model_not_servable`), so this review ran on `deepseek-v4.1-flash`/high — the same model family as
  the producer. Everything below is my own reading, my own instruments and my own re-runs; no second
  model checked it.

## Verdict: `narrowed`

All five claims are proven, at structure level, on the exact tip — with falsification controls that
show my probe is sensitive to each one. Two real defects were found that the producer's own probe
does not reach (a lane's `main-only` outcome is wrong for a record shape the schema permits; the
child-page request exceeds the node's accepted page budget whenever `WASM_AGENT_TOOL_OUTPUT_BYTES`
is lowered). Neither blocks landing on the default configuration; `scripts/test-ui.ps1` was also
narrowed in what it covers (details below).

## What I ran

| # | Command | Result |
|---|---|---|
| 1 | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1` (tip, twice) | exit 0, stdout verbatim: `  ok   UI structure, mid-run reload, and startup recovery` — no skip count (see below) |
| 2 | `node review/ui-subagent-chat/observe.mjs --ui ui --probe review/ui-subagent-chat/probe-claims.js --out .../leg-small --window 1280x900 --scale 1` | **PASS, 27 checks, 0 failures**; measured layout 754x440 (dpr 1) |
| 3 | same, `--scale 0.5` (layout 1022x1040, dpr 0.5) | **PASS, 27 checks, 0 failures** |
| 4 | `... --probe review/ui-subagent-chat/probe-lane-attack.js --allow-fail` | **FAIL as designed** — the defect below |
| 5 | `node review/ui-subagent-chat/controls.mjs` | 6 one-thing-reverted mutations in a disposable copy of `ui/`: **5 caught**, 1 not (explained) |
| 6 | read `leg-small/screenshot.png` as an image | one-line headers, ellipsized titles, six panes, aligned Steer/Cancel + paperclip row, lane groups visible |

`scripts/probe-ui-subagent-chat.ps1` was treated as a claim, never as evidence: I reimplemented
`review/ui-subagent-chat/probe-claims.js` from the claims (different fixtures, different fixture
shapes, extra measurements it does not make) and ran it in the repository's own observation
discipline — a copy of `ui/` in a temp stage, `ui/test-fixtures.js` stubbing HTTP, the probe
injected last, nothing written into `ui/` or into the installed UI.

Two bugs in **my own** first probe (`getBoundingClientRect` aliases `x/y` vs `left/top`) produced a
false `controlsInside=false`; I found them by reading the screenshot and the numbers, fixed them, and
every number below is from the fixed instrument. That is why the controls and mutation runs exist.

## Claim by claim (measured, small leg 754x440 unless stated)

**1 — six simultaneously open boxes stay readable. PROVEN.** 6 cards → 6 panes; each pane box is
360px tall; transcript `clientHeight` **146px** (children 1–4, running) and **215px** (5–6, settled)
against `scrollHeight` 1004/1037, i.e. real scrollable content holding bubbles of 469.95 / 508.55 /
541.59px. Every pane's answer text is present. `document.elementFromPoint` at the middle of each
transcript (after scrolling the canvas to bring that pane into view) hits a node **inside that
transcript** for all six — a zero-height or covered box fails this. Canvas `clientHeight` 382 of
`scrollHeight` 1100: it scrolls instead of squashing panes. Long content was used deliberately
(88-char titles, six-paragraph bodies). Wide leg (1022x1040 CSS px): same result, transcripts
138/209px, all six hits inside.
*Limitation, stated by the delivery itself:* at a 440px-tall viewport panes 5–6 sit below the fold and
the canvas must be scrolled — "six open" means six drawn, not six on screen.

**2 — header capped at 44px, and the cap does not hide the content. PROVEN.** `getComputedStyle` `max-height` is `44px` on every pane; computed height and bounding-rect height are **41px** (42px at
dpr 0.5 — subpixel), `clientHeight` 40 vs `scrollHeight` 40, so **nothing is clipped vertically**.
The title is 88 characters with `clientWidth` 104.63 against `scrollWidth` 702 and computed
`text-overflow: ellipsis` — text that is present, readable and visibly truncated, not hidden. The
model line is 52.88px wide with the same ellipsis. Both header controls (30x30 `.icon-btn`) lie
entirely inside the header box.
The control run is what makes this meaningful: deleting the ellipsis rules gives
`clientHeight` 43 / `scrollHeight` 116 on every header — the clipboard-shortened title wraps and is
genuinely cut off — and my "must not clip" check fires. Reverting `flex-wrap:nowrap` alone (keeping
the ellipsis rules) produces **no** failure, because the ellipsis rules are what hold the one line;
I report that as a fact, not as a caught mutation.

**3 — the Steer/Cancel row is the height of the "append file" control. PROVEN.** Measured by selector
`.chat-actions .chat-action` (Steer and Cancel task) against `wa-chat-shell [data-part="attach"]`
(the shared shell's append-file `.icon-btn`), both `getBoundingClientRect().height` and
`offsetHeight` and computed `height`: **30 == 30** on all six panes, and `.chat-actions` itself is 30.
The mutation `height:30px → 31px` on `.chat-action` flips this check to 31 vs 30 — caught.

**4 — the child transcript is the main chat's own path, and the pane-only artifacts are gone. PROVEN
structurally, one thing not proven.** Per pane: the transcript **is** the shared wrapper
(`wa-chat-shell > .messages[data-part="content"]` — the same predicate the main chat's `#messages`
satisfies), `typeof pane.showMessages === 'undefined'` (no renderer of its own exists to call), and
`grep showMessages ui/` is empty in the source. The divergent artifacts are absent from the DOM: no
`.agent-earlier` element, no `Earlier messages` text, no `Load original message` text; a settled pane's
own notice is the empty string and a running one says `Working. Steer updates the active run; …` — no
`Ready for your next message.` anywhere. The run footer is inside the bubble
(`wa-message.assistant > .body.steps > .chat-content-run-status.finished`) and never a second row of
the transcript. The decisive measurement: for the **same ledger rows**, the child transcript's DOM
signature and the main chat's after `__repaintMessages` are **byte-identical** —
`WA-MESSAGE.msg.user[];WA-MESSAGE.assistant.msg[WA-RUN.run{BUTTON.trace-head,DIV.run-body},DIV.seg{BR.},DIV.chat-content-run-status.finished.status{SPAN.chat-content-run-label,SPAN.chat-content-run-elapsed}]`
— including the fold rule (a successful call's `.tool-output` `hidden`, a failed one forced open with
`.tool-line.err`). Re-adding the `agent-earlier` button in the mutation run flips the artifact check.
Nuance worth stating: `completed` and a duration do still appear in a child's footer (`0:06`, `0:05`),
drawn by the shared renderer from the ledger's own timestamps — that is the main chat's footer, not the
pane's old fabricated `0:13`.
*Not proven:* this is the same **function** and DOM for the same rows; it is not a claim about a live
child stream (see "not proven").

**5 — cards grouped by lane on the recorded branch/worktree, with the end-state checklist. PROVEN for
the delivered shape; one outcome is wrong for a permitted record shape.** Three lane sections keyed
`change/lane-alpha` (lane path `C:/work/wt-alpha`, 2 children), `change/lane-beta` (`C:/work/wt-beta`,
2), `main` (no path, 2) — the keys come from the children's recorded `workspace_branch`/`worktree` read
from `/sessions` (`SELECT s.*`, so those columns are really on the wire; `server.lua:732`). Each lane
carries the four outcomes in order with a `data-state`: alpha `merged=unknown retired=no
clean=unknown main-only=no`, beta `unknown/yes/unknown/no`, main `unknown/unknown/unknown/yes`, each
row also carrying its reason in `title`. `retired` is measured from the recorded checkout state.
I deliberately used the shape the node actually records for a released lane (`workspaces.lua`'s release
keeps `worktree` and sets `workspace_state='released'`; the producer's probe used `worktree:""`), and it
still keys on the branch and reports `retired=yes` — so claim 5 survives the realistic fixture.

## `scripts/test-ui.ps1` — the producer's edit to its own judge

Verdict and skips, verbatim: the run prints exactly one line,
`  ok   UI structure, mid-run reload, and startup recovery`, exit 0, reproducible. The harness builds
its verdict as a single string (`UI PASS (reload and startup recovery)` or `UI FAIL: <labels>`) and
**has no skip facility at all**: no skip counter, no skipped branch, nothing to print. So the honest
answer to "skip count" is that it is zero *and unreported* — `grep -i skip scripts/test-ui.ps1` finds
one unrelated comment. (AGENTS.md's "a skipped test is reported as skipped" belongs to the suites in
`scripts/test.sh`, which I did not run.)

Diff against `origin/main`: **8 `check(` lines removed, 10 added** (505 → 507 call sites); no assertion
was dropped without a replacement, and no threshold was loosened. What it does:

- Replaces `panes[0].showMessages(...)` with `window.__paintChildTranscript(panes[0].transcript, rows,
  {state, stateAt, active, liveTool})` — necessary, because the element's renderer is gone.
- **Strengthens:** asserts the run footer lives inside the bubble
  (`wa-message.assistant > .body.steps > .chat-content-run-status.finished`); asserts a successful
  call's payload stays folded while a failure's is forced open; pins the trace element's identity
  across a live task update so the reader's fold choice is provably preserved; makes the elapsed-footer
  check a strict `:scope >` instead of an `||` fallback; adds the node's own placeholder wording for an
  oversized row and the negative `Load original message` assertion.
- **Narrows:** (a) the check now reaches into a **test-only hook** (`window.__paintChildTranscript`,
  appended to the temp copy) instead of the element's own API, so the production seam —
  `refreshAgentPane` → `paintChildTranscript` with the right `state`/`liveTool` — is no longer covered
  by the repository's UI test at all; the old form exercised it, the new form bypasses it. (b)
  `showroom.sidebar.children.length===4` became `showroom.sidebar.querySelectorAll('.agent-card').length===4`
  — same count, but it no longer couples to the sidebar's structure, so a flat list would still pass
  it. (c) `grep -n lane scripts/test-ui.ps1` is **empty**: claim 5 has no durable check in the suite
  that judges this delivery — only in the producer's standalone probe. (d) the pane-level "retrieve the
  original" behaviour is now asserted as *absent*, which is the intent, but it means no test covers the
  node's `evidence` address ever being used from a pane.

## Findings

1. `lane-main-only` — **unresolved**. A lane whose children recorded their **own worktree but no branch
   name** is keyed on that worktree (header shows `C:/work/wt-gamma`) and simultaneously reports
   `main-only: yes` with the reason "this lane holds no branch of its own: its children work in the node
   checkout" — false for that lane. `laneChecklist` derives `main-only` from `lane.branch` while the lane
   key is `branch || worktree || 'main'`. Reproduce: `observe.mjs --probe probe-lane-attack.js`
   (fails by design; facts in `facts-lane-attack.json`). Reachability: the schema permits it
   (`sessions.workspace_branch TEXT NOT NULL DEFAULT ''`; `workspaces.lua`'s `verify_binding` tolerates
   an empty recorded branch, and its release path reads `workspace.branch~='' and … or …parked_branch`),
   but the node's own allocator always writes `change/wa-session-<id>`, so I did **not** observe such a
   row in a live ledger. Fix is one line: `main-only` should be `no` whenever the lane is keyed by a
   worktree of its own, or the key and the outcome should both come from one recorded fact.
2. `session-page-byte-limit` — **unresolved**. `paneMessages` asks the node for `byte_limit:40960`
   (newest page) and `20480` (older pages). `lua/core/session_view.lua:48` rejects
   `bytes > output.MAX_BYTES-2048`, and `MAX_BYTES` is lowered from 51200 to any value ≥4096 by
   `WASM_AGENT_TOOL_OUTPUT_BYTES` (`tool_output.lua:22-24`; the knob the benchmark and the A/B
   experiments use). With that budget below 43008 the node answers `invalid_session_byte_limit`,
   `orchestratorRequest` throws on `result.error` (`app.js:4293`), and **every** child pane reads
   `Conversation unavailable: invalid_session_byte_limit` with no transcript. Correct under the default
   51200 (verified by reading the route's accepted range), so this is not a default-config failure —
   but the UI hardcodes a budget the node declares configurable. Fix: send no `byte_limit` (the route
   defaults sanely) or ask for `min(40960, …)`.
3. `test-coverage` — **unresolved**. As detailed above: the durable UI test no longer covers the
   production render seam, and nothing in the repository's suites asserts lane grouping or the four
   outcomes. The delivery's own probe covers both, but a probe is not a test that runs later.
4. `probe-fidelity` — **resolved**. The producer's probe builds released lanes with `worktree:""`, a
   shape `workspaces.lua`'s release path never writes (it keeps the worktree and sets
   `workspace_state='released'`); re-run with the recorded shape, claim 5 still holds (`retired=yes`,
   lane keyed by branch). The standalone probe also asserts `canvas.scrollHeight > canvas.clientHeight`,
   which is a property of the viewport it happens to use, not of the fix.
5. `claim-scope` — **unresolved** (statement, not defect). `merged` and `clean` are constants
   (`unknown` plus a stated reason) for every lane: half of the promised four-outcome checklist can
   never be a measurement from this view. The delivery says so in the UI (every row's `title` carries
   the reason) and in the code comment; DESIGN.md's amended row only says "that lane's end-state
   checklist", so a reader of the claim "its end-state checklist (merged / retired / clean / main-only)"
   should know from this review that two entries are permanent unknowns.

## What is not proven

- Everything above is measured against **stubbed** node answers (the fixtures interpose on `fetch`), not
  against a live node: I did not start the node, restart it, install anything, drive the window, open
  six real children, or read the live ledger. The field names and page limits the UI depends on were
  checked against the source of the real route, not against a live response.
- Claim 4 proves the same renderer and DOM for the same rows; it says nothing about a child *streaming*
  live (the node streams to its own request), nor about `paintChildTranscript` restoring every module
  scoped value under concurrency — I read the save/restore list and the `finally`, but did not construct
  a child paint interleaved with a live main-chat run.
- Claim 1 is proven for the layout the canvas produces (2 columns, 360px rows, scrolling canvas); the
  six panes are not all on screen at once at a short viewport.
- `merged`/`clean` remain unmeasured by design.
- The lane defect's reachability on a real ledger is unproven (see finding 1).

## Should this block landing?

No. On the delivered configuration the five claims hold, with visible appearance confirmed by image.
Recommend, before the lane view is trusted: fix finding 1; fix finding 2 before any operator runs with a
lowered `WASM_AGENT_TOOL_OUTPUT_BYTES`; and leave a durable check for the production render seam and for
lane grouping (finding 3) rather than only a standalone probe.

## Evidence in this commit

`observe.mjs` (my runner: stage `--ui`, inject fixtures + probe, headless Edge/Chrome, `--window`/
`--scale`, screenshot + DOM dump), `probe-claims.js` (27 checks for the five claims),
`probe-lane-attack.js` (claim 5 attacked), `probe-viewport.js` (which layout the browser really gives),
`controls.mjs` (six one-thing-reverted mutations), `facts-small-754x440.json`,
`facts-wide-1022x1040.json`, `facts-lane-attack.json`, `leg-small/{dom.html,screenshot.png}`,
`attack-lane/dom.html`. Everything outside `review/` is untouched; the only thing this commit adds is
this directory.

harness: a headless probe can be judged before it has finished, so `probeStatus: "missing"` and
`"running"` are indistinguishable from a real verdict — `node review/ui-subagent-chat/observe.mjs
--window 1280x900` reported `innerWidth=754x440` for the whole run while the same run's
`screenshot.png` came out 1280x900, and 6 of my 7 viewport-probe runs came back `missing`/`running`
(no verdict) until the probe published progress into `pre#wa-probe[data-status=running]` first. A dump
that waits for the probe element to reach pass/fail (or a `--layout-viewport` a reviewer can pin,
instead of a `--window-size` the layout ignores) would turn those 6 runs into evidence and remove the
re-runs.
