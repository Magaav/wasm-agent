# Independent review — `change/ui-action-row-binding`

**Delivery:** branch `change/ui-action-row-binding`, tip `b33c7812bae92b1ba46343794ab7d0cea9051209`
(tree `a390d45f5b08c8d25f081d3a3e8e1c278f9e5c85`), 1 commit ahead of `origin/main` `2f02b4c`, not pushed.
**Producer:** `child:dispatch:3994f25d-a25e-4d3a-961e-e0f599fbdb3e`.
**Reviewer:** `child:dispatch:997da2ba-fd44-40b7-ad1e-5607debcaac4`, in its own session worktree
`C:/Users/Victor/.wasm-agent/wa-worktree-childdispatch997da2ba-fd44-40b7-ad1e-5607debcaac4`
(branch `review/ui-action-row-binding`, cut from the tip). Nothing was pushed, no other lane's tree or
branch was touched, the running window was never reloaded or instrumented, and the installed UI was
never written to: every observation serves a **copy** of `ui/` (the tip's, or `git archive 2f02b4c ui`
for the baseline) with the repository's own `ui/test-fixtures.js`.

**Model note (independence is the lane, not the model).** This node's provider refuses `gpt-6-luna`
(`model_not_servable`), so this review ran on `deepseek-v4.1-flash`/high — the same family as the
producer. The independence here is a separate session, a separate worktree, my own instrument, and
attacks the producer did not run; it is not model diversity, and it should not be read as such.

**Verdict: `refused`.** Every functional claim of the delivery reproduces on the tip, and the refactor
is measurably safe — but the tip **fails the repository's own gate**: `node scripts/gate-check.mjs run
ui-browser` → `FAIL` on the tip and `PASS` with `origin/main`'s `scripts/test-ui.ps1` + `ui/` in the
same tree on the same machine, because the delivery renamed the UI verdict line that
`scripts/gate-check.mjs` matches exactly. That is a landing blocker, not a style point (finding
`gate:unresolved` below). Nothing else I found blocks landing.

## 0. What I ran

| # | Command (all in my worktree) | Result |
| --- | --- | --- |
| a | `node review/ui-action-row-binding/run.mjs --ui ui --probe review/ui-action-row-binding/probe-controls.js --query "?review_expect=equal" --size 1280x900` | PASS — 30/30 measured |
| b | same, `--size 420x700` | PASS — 30/30 at the narrow viewport |
| c | same against `origin/main`'s `ui/` (`git archive 2f02b4c ui`), `?review_expect=baseline`, both sizes | PASS — 37/30 reproduced |
| d | `node scripts/agent-benchmark-ui-observe.mjs --ui ui --probe …probe-main-footer.js` and the same against `origin/main`'s `ui/` | PASS, screenshots read |
| e | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1` (pristine tip) | `ok   UI structure, mid-run reload, startup recovery, and the inspect window` (6.1 s) |
| f | `bash review/ui-action-row-binding/mutate.sh`, `mutate2.sh`, `mutate3.sh` — 10 one-thing mutations, each applied alone to this worktree's `ui/`, test run, tree restored | 7 FAIL, 2 GREEN (documented blind spots), 1 invalidated and redone |
| g | `node review/ui-action-row-binding/run.mjs --probe …probe-inspect.js` (main window) | PASS |
| h | same `--probe …probe-inspect-view.js --query "?view=inspect"` | PASS |
| i | same `--probe …probe-plumbing.js` | PASS |
| j | same `--probe …probe-viewmenu.js --query "?view=orchestrator"`, tip vs `origin/main` | behaviour change measured |
| k | `node scripts/gate-check.mjs run ui-browser --output …` (focused check, not `scripts/test.sh`) | tip **FAIL**, `origin/main` files **PASS** |
| l | `node --input-type=module -e "import {checkVerdict} …"` against both verdict lines | old line `{"ok":true}`, tip line `{"ok":false,"reason":"browser_terminal_verdict_required"}` |

Not run, deliberately: `scripts/test.sh` (the full gate), and anything that would touch the running
window, the installed UI, or another lane.

## 1. The measurement, reproduced with my own instrument

My instrument is not the producer's: `review/ui-action-row-binding/run.mjs` (my own server + Chrome
launcher, with `--size` and `--query`, which the repository's observer does not have) plus
`probe-controls.js` (measures the four controls, audits **which CSS rules state each box** by walking
`document.styleSheets`, and takes its expectation from the query string so the same instrument can be
pointed at a tree where the claim is false). The main chat's Steer is revealed by the app's own
`setBusy(true)`, with the fixture's `/health` made to report a run in flight for this conversation so
the app's own loop keeps the control up; a child pane is created through the app's own
`wa-orchestrator.pin(task)`.

**Tip `b33c781`, viewport 1262×748 (`--size 1280x900`), `expect=equal` → `pass`:**

```
main-chat Steer      30x55   button#steer.chat-control    padding 0px 10px  radius 5px  border 1px  font 12px
main-chat append-file 30x30  button#attach.chat-control   padding 0px       radius 5px  border 1px
child-pane Steer     30x55   button.chat-control          padding 0px 10px  radius 5px  border 1px  font 12px
child-pane Cancel    30x94.6 button.chat-control          padding 0px 10px  radius 5px  border 1px  font 12px
child-pane append    30x30   button.chat-control
main-chat mic        30x30   button#mic.icon-btn          (same footer row: min-width auto, padding 1px 6px)
main-chat send       45x45   button#send.send.busy
structure {"mainRow":"wa-chat-actions.chat-actions","paneRow":"wa-chat-actions.chat-actions",
  "sameConstructor":true,"registeredElement":true,"mainSteerParent":"wa-chat-actions.chat-actions",
  "paneSteerParent":"wa-chat-actions.chat-actions","mainSteerId":"steer","chatControlCount":5,
  "chatActionCount":0,"iconBtnCount":9,"controlSizeToken":"30px","rowControls":1}
footer   {"rowWidth":155,"footerWidth":980,"overflow":0}
```

**Tip, viewport 500×548 (`--size 420x700`) → `pass`:** all four at height 30 (main Steer 30×55,
append 30×30, pane Steer 30×55, pane Cancel 30×94.6), footer `overflow 0` — so the row does not wrap
or overflow in a narrow pane.

**`origin/main` `2f02b4c`, both viewports → `pass` (`expect=baseline`):**

```
main-chat Steer      37x53.9 button#steer            padding 10px   radius 10px  border 1px
main-chat append-file 30x30  button#attach.icon-btn   padding 1px 6px radius 5px
child-pane Steer     30x55   button.chat-action       padding 0px 10px radius 10px
child-pane Cancel    30x94.6 button.chat-action
structure {"mainRow":"none","paneRow":"div.chat-actions","sameConstructor":false,
  "chatControlCount":0,"chatActionCount":2,"controlSizeToken":""}
```

So **30/30 on the tip and 37/30 on `origin/main` are confirmed** by an instrument that did not exist
before this review: the 7px the owner reported is real and is gone, and the main chat's Steer is the
append-file control's box (30px) rather than its own.

**One number I did not reproduce:** the producer reports the child-pane Steer as `w 47`; my instrument
measures `w 55` at both viewports (a labelled `.chat-control` is `padding 0 10px` + a 12px label, and
the pane's ambient font differs: the pane's own append-file computes 14.5px against the main chat's
13.33px). The *height* — the claim — matches exactly, and the width is the label's own width by
design; but I am recording that I did not reproduce 47, and that a width claim from their harness is
context-dependent in a way the height is not.

**Looked at, not just measured** (see-your-output §3). `obs-tip-footer/screenshot.png`: the main chat
with a run in flight ("working — node beat 0 ms ago · this run 15s", Stop button), and `Steer` in the
footer-right sitting level with the paperclip and the mic. `obs-main-footer/screenshot.png` (the same
probe against `origin/main`'s `ui/`): the same footer, with a visibly taller, more-rounded `Steer` that
breaks the row. `obs-probe-tip/screenshot.png`: a child pane's footer, `Steer` and `Cancel task` level
with the paperclip. Structure alone would not have shown this; the two pictures side by side do.

## 2. Is the binding structural? Mutations, one thing at a time

Each mutation was applied **alone** to my worktree's `ui/`, the delivery's own `scripts/test-ui.ps1`
was run, and the tree restored (`git status` clean afterwards; scripts kept: `mutate.sh`, `mutate2.sh`,
`mutate3.sh`). Baseline on the pristine tip: green.

| Mutation (one thing) | Verdict line (excerpt) |
| --- | --- |
| M1 the actions get their own height (`.chat-control[data-action]{height:34px}`) | `FAIL UI FAIL: in a child pane the Steer control must follow the append-file control's height, saw [30,0,30,34] ;; … the main chat's Steer must compute to the append-file control's own box …, saw steer [34px / min 30px / radius 5px / border 1px] and append-file [30px / …]` |
| M2 the append-file control leaves `chatControl()` (hand-built, old `.icon-btn`) | `FAIL UI FAIL: every footer control must be the factory's own class, saw ["icon-btn","chat-control","icon-btn","chat-control"] ;; one box means one height, border, radius and vertical padding, saw ["5px/1px/1px","5px/1px/0px","5px/1px/5px","5px/1px/0px"] ;; a shell and a row built from the components alone must produce the same control, saw icon-btn 30 / chat-control 30` |
| M3b the pane builds its own row again (a `div.chat-actions` with `.chat-action` buttons, where the old code put it) | `FAIL UI FAIL: the action row must be the one shared component on both surfaces, saw main: WA-CHAT-ACTIONS true / child: none ;; the actions must be the shared row's own controls, saw WA-CHAT-ACTIONS / no child steer ;; … child steering is distinct from queued Send` |
| M4 the deleted `#steer`-only rule restored | `FAIL UI FAIL: one box means one height, border, radius and vertical padding, saw ["5px/1px/0px","10px/1px/10px","5px/1px/0px","5px/1px/0px"] ;; … saw steer [30px / min 30px / radius 10px / …] and append-file [… radius 5px …]` |
| M5b a rule that really wins over the shared box (`wa-orchestrator .chat-control[data-action]{padding:var(--space)}`) | `FAIL UI FAIL: one box means one height, border, radius and vertical padding, saw [...,"5px/1px/5px"]` |
| M6 a second, scoped `--control-size` (`.chat-actions{--control-size:40px}`) | `FAIL UI FAIL: … saw [30,0,30,40] ;; … saw steer [40px / min 40px / …] and append-file [30px / …]` |
| M9 a host sets an inline style on one control (`#steer.style.height="34px"` in `setBusy`) | `FAIL UI FAIL: the main chat's Steer must compute to the append-file control's own box while a run is active, saw steer [34px …] and append-file [30px …]` |

Seven one-thing mutations turn it red, each naming the control and the number. (The producer claims
six; the property holds for at least seven.)

**The harder question — can one control's box still move without the other?** Yes, in two senses, and
the code already contains the first:

- **A higher-specificity rule can still move one control alone** — and there is a live example:
  `wa-orchestrator button { … border-radius: var(--radius-sm); padding: var(--space); … }`
  (`ui/style.css:115`) matches every button inside a pane, including the pane's `.chat-control`s, and
  is overridden *only* by `.chat-control`'s class specificity. My rule audit (measured in the page,
  not read off the file) shows the pane's Steer box stated by **two** rules — `.chat-control` for
  height/min-width/padding/radius and `wa-orchestrator button` for padding/radius — where the main
  chat's Steer is stated by one. M5b shows that the moment such a rule wins, the pane's control moves
  alone (and the test catches it). A first attempt at M5 that did **not** win (`wa-orchestrator
  button[data-action]`, specificity 0,1,2 < `.chat-control[data-label]` 0,2,0) left the test green —
  which is itself the useful measurement of how much specificity it takes.
- **An inline style a host sets is not prevented** — but it is caught: M9.

**What is *not* enforced:** M7 (recolour one control alone, `border-color`) and M8 (state the same box
a second time with identical values) both leave the test **green**. So the checks pin the *box* (and
the class identity that produces it), not the whole appearance, and they cannot tell "stated once"
from "stated twice identically". "`style.css` states that box once" is a property of the source, which
the test does not assert — the factory/class checks are what make the two controls one thing.

**A second `--control-size` fallback:** there is none — `--control-size` is defined once
(`ui/style.css:19`), used twice (`:712`, `:729`), and no `var(--control-size, 30px)` fallback exists
anywhere (`rg 'control-size' ui/ scripts/ DESIGN.md`). A host redefining it in a subtree moves that
subtree (M6).

## 3. The producer's `+176` in `scripts/test-ui.ps1`

- **Scope of the edit:** `git diff --numstat 2f02b4c b33c781` → `173 3 scripts/test-ui.ps1` (176
  changed lines, as claimed). The only **removed** lines in the whole diff are the three verdict-branch
  lines (`if ($result -eq "UI PASS (reload and startup recovery)") {`, the old `Write-Host …`, `} else {`).
  **No `check(...)` was deleted or narrowed**; the harness change is purely additive.
- **The production seam, not a hook:** the new checks drive the app's own components
  (`document.getElementById('chat')`, the pane the app's `wa-orchestrator` builds, `#steer`/`#attach`),
  the app's own `native.openView` through the **pre-existing** fixture shell
  (`window.__setShell(window.__makeShell())`, `ui/test-fixtures.js:8`), and the app's own HTTP through
  the fixture `fetch` stub's `window.__calls`. The delivery added no new exposure line (the appended
  `window.__setBusy = setBusy; … window.__setShell = …` block at the end of the script is unchanged),
  and it added a second *page load* (`?view=inspect`) with its own verdict log, with the
  "no log in the DOM dump → exit 1" path kept.
- **Durable assertions, not source greps:** class identity on all four controls, the row's
  constructor against `customElements.get('wa-chat-actions')`, the parent/`controls` relationship, the
  radius/border/padTop equality across four measured boxes, a freshly built `wa-chat-shell` **and**
  `wa-chat-actions` compared to each other, and the busy-state computed box — plus the menu order and
  the two-invocation ask. My mutation runs show they fail for the right reason, naming the number.
- **Where the new checks are weaker than the claim:** the inspect stage proves the app *asks* twice
  with one name and one URL; it does **not** prove the window is reused, because reuse is the shell's
  (`rust/wa-window`), not the page's. I verified that half in the shell source and modelled it in my
  own probe (§4). Likewise M7/M8 above.
- **The one edit that matters:** the third removed line is the `Write-Host` whose text the gate parses.
  See §6.

## 4. The `inspect` item, attacked

**The main window** (`probe-inspect.js`, PASS):
- menu, exactly: `["Collapse to avatar","Reload window","inspect","---","Close wasm-agent"]` — `inspect`
  is **immediately after `Reload window`** and last before the separator.
- two invocations through the menu's own click path (which closes the menu and runs the item):
  `openView` asked **twice**, `view:"inspect"` both times, the same URL both times
  (`http://127.0.0.1:PORT/?view=inspect`, this node's own path).
- **reuse, counted:** my shell stub models the real one — `open_view` refuses a title it already has
  (`rust/wa-window/src/main.rs:406` `if state.views.iter().any(|open| open.window.title() == view)`)
  — and with that rule the run ends with **one** window (`"reused": true`, `openTitles.length === 1`).
  The app cannot stack by construction either: `openInspectWindow()` refuses inside a view
  (`if (viewMode()) … return false`), and the shell only honours `open_view` `if from_main`.
- **the asking window is untouched:** `shellCalls` = two `openView` and nothing else (no
  `closeView`/`setMode`/`compact`/`expand`/`quit`); the app's own menu is **closed** after each click
  (`wa-menu`'s item handler closes before running the action); no reload (a marker set before the
  clicks is still 1); no navigation (`location.href` unchanged); the transcript's first bubble is the
  same connected node and the row count is unchanged; `document.body.className` unchanged; **zero new
  fetches** after the clicks.

**The opened page** (`probe-inspect-view.js`, `?view=inspect`, PASS):
- `viewMode() === "inspect"`; `body.className === "expanded"` — not `compact` (a fresh profile boots
  compact) and not `view-only`;
- the furniture it exists to inspect is there: `chat, input, steer, attach, messages, send` all present,
  2 transcript rows drawn by the shared renderer, and the same `<wa-chat-actions>` row;
- **it keeps the browser's own menu:** the `contextmenu` event is *not* prevented
  (`defaultPrevented === false`) and the app's own menu is not drawn. The shell side is source-proven:
  a view webview is built `.with_default_context_menus(true)` (`rust/wa-window/src/main.rs:506`) while
  the main webview is built `.with_default_context_menus(false)` (`:611`), so Chrome's `Inspect
  element` is in the menu the inspector keeps and is not in the main window's;
- **it disturbs nothing:** `shellCalls` is empty — it asks for no second window and no resize (and
  `set_mode`/`open_view` are `if from_main`, so even asking would be ignored); 8 reads, **0 POSTs**
  (read-only); no `wa-window` of its own; the control surface is not mounted; exactly one mode class.
- **Nothing left behind in the page.** On disk the shell gives every view its own WebView2 profile
  (`data_dir()/views/<name>`), so the inspect window leaves that profile directory — as every view
  does, and it is why the page forces `applyMode("expanded")` in its own fresh profile rather than
  inheriting the main window's `wa-mode`.

**What I could not observe:** that a real view window actually shows Chrome's `Inspect element`. I did
not open a real window (the running window and the desktop are out of bounds for this review), so that
half is proven from the shell source and the page's measured behaviour, not seen end to end.

**A behaviour change wider than the feature** (`probe-viewmenu.js`, tip vs `origin/main`,
`?view=orchestrator`): `origin/main` — event swallowed, app menu drawn with
`["Collapse to avatar","Reload window","---","Close wasm-agent"]`; tip — event **not** swallowed, no app
menu. So the rule changed for **every** view, not only for the inspector, and DESIGN.md does not state
it. It also removes `Close wasm-agent` (whose shell handler has no `from_main` guard, so it really did
quit the whole app from a view) from view windows, and `Collapse to avatar` (which the shell ignores
from a view) — arguably a fix, but an unstated one. Non-blocking (finding `scope:unresolved`).

## 5. Steer/Cancel plumbing in child panes

`probe-plumbing.js`, PASS, driven through the app's own path (`mountOrchestrator()` → `pin(task)`, the
host handler the app wires on `agent-action`):

```
mainSteer            BUTTON#steer.chat-control
mainSteerPosts       [{"action":"steer_session","session_id":"aaaaaaaa-0000-0000-0000-000000000001",
                       "text":"MAIN-STEER-TEXT","idempotency_key":"…"}]   (and the draft was cleared)
paneControls         {"row":"WA-CHAT-ACTIONS","steer":"BUTTON.chat-control (in row)",
                      "cancel":"BUTTON.chat-control","disabled":false}
chatActionDetail     {"action":"steer","controlIsTheBuiltOne":true}
paneSteerPosts       [{"action":"steer","id":"review-child-1","text":"PANE-STEER-TEXT","idempotency_key":"…"}]
paneCancelPosts      [{"action":"cancel","id":"review-child-1"}]
afterRowReconnect    1     (the row removed and re-appended: one request, same element, no double fire)
afterPaneReconnect   {"posts":1,"chatActionEvents":1,…}   (the pane removed and re-appended in its host)
```

- the main chat still works **by id**: `#steer` survives onto the built control (`mainSteerId:"steer"`),
  and one click sends `steer_session` with the composer's own draft, then clears only the accepted
  draft;
- a child pane's Steer and Cancel reach the host **through `chat-action`** with
  `{action, control}` where `control` is the built button that was clicked, and the host's own receipts
  come back to the pane (`Steering queued…`, `Cancellation requested…`);
- **exactly one** request per click, before and after the row is rebuilt/reconnected and after the
  pane is reconnected in its host — no double fire, no lost handler, and the pane keeps the same
  control element (`WaChatActions._ensure` and `WaAgentSession.connectedCallback` are both guarded by
  a built flag).
- One honest note from my own first attempt: moving the pane **out of** its orchestrator panel stops
  the host from hearing `agent-action` — because the host listens for a bubbling event on its own tree.
  That is the design (an event, not a binding) and not a defect; the probe now reconnects the pane in
  place.

## 6. Scope, and DESIGN.md

`git diff --name-only 2f02b4c b33c781` → `DESIGN.md`, `scripts/test-ui.ps1`, `ui/app.js`,
`ui/components.js`, `ui/index.html`, `ui/style.css`. **Only `ui/**`, `scripts/test-ui.ps1` and
`DESIGN.md`** — no other lane's files, as claimed.

`DESIGN.md` states the rule: §10 gains the `<wa-chat-actions>` registry row ("One element on both
surfaces, and its controls come from the shell's own `chatControl()` factory … one class,
`.chat-control`, is the whole box in `style.css`, and a change to one moves all of them") and the
paragraph "**One footer, one control**" ("`chatControl()` … builds the append-file control the shell
ships and every button of `<wa-chat-actions>`, all of them `.chat-control`, and `style.css` states that
box once … an icon control is the square `--control-size` (30px)").

Two places where that sentence is broader than the code, neither of which touches the defect that was
reported (finding `claim:unresolved`):
- the **mic** sits in the same composer footer (`index.html:119`, `data-slot="footer-left"`) and is not
  a `.chat-control` — it is `.icon-btn` (30×30, `padding 1px 6px`, its own border/radius/background
  rules), so "the composer footer's controls are one implementation" is not literally true; what is true
  is that the *actions row* and the *append-file control* are one implementation;
- inside a pane the same controls are also matched by `wa-orchestrator button` (see §2).

## Findings

| class | status | finding |
| --- | --- | --- |
| `gate` | **unresolved (blocking)** | The tip fails the repository's own gate. `scripts/gate-check.mjs:17` matches the UI verdict line with `/^\s*ok   UI structure, mid-run reload, and startup recovery\s*$/`; the delivery renamed it to `  ok   UI structure, mid-run reload, startup recovery, and the inspect window` and did not update the parser. Measured: `node scripts/gate-check.mjs run ui-browser` → `check ui-browser: FAIL exit=0 ms=6730.4` on the tip, and `check ui-browser: PASS exit=0 ms=5676.3` with `origin/main`'s `scripts/test-ui.ps1` + `ui/` restored in the same tree. `checkVerdict({verdict:'browser'},0,…)`: old line `{"ok":true}`, tip line `{"ok":false,"reason":"browser_terminal_verdict_required"}`. Fix is one line (keep the marker, or teach the parser the new sentence) — but a delivery that fails the gate must not land. |
| `claim` | unresolved | "`style.css` states that box once" is not enforced and not literally true inside a pane: my rule audit shows the pane's Steer box stated by `.chat-control` **and** `wa-orchestrator button` (`ui/style.css:115`), the second currently losing only on specificity (M5b shows it wins and is caught once it does). "The composer footer's controls are one implementation" (DESIGN.md:184) is broader than the code: the mic is in that footer and is `.icon-btn`. |
| `test` | unresolved | The delivery's checks pin the box, not the whole appearance, and cannot see a duplicated-but-identical rule: M7 (one control recoloured alone) and M8 (the same box stated a second time with the same values) both stay green. Not a defect in the claim; a stated limit of the new checks. |
| `scope` | unresolved | The right-click rule changed for **every** view, not only the inspector (measured: `?view=orchestrator` swallows the event and draws the app menu on `origin/main`, does neither on the tip). DESIGN.md states the inspector's menu but not this; view windows also lose the app's `Close wasm-agent` item. |
| `evidence` | unresolved | The reuse half of the inspect claim is the shell's property, not the page's, and the delivery's test cannot prove it (it proves the app asks twice with one name). I verified it in `rust/wa-window/src/main.rs:404-421` and modelled it in my own probe; that a real window shows Chrome's `Inspect element` remains unobserved by me, as opening one was out of bounds. |
| `measurement` | unresolved | I reproduced the producer's heights exactly (30/30 on the tip, 37/30 on `origin/main`) but **not** their child-pane width `w 47`; my instrument measures `w 55` at both viewports, a label-width difference (12px label + `0 10px` padding) that the height does not have. |

## What is proven, and what is not

**Proven (measured, on this tip, by instruments that can fail):** the 37px/30px baseline and the
30px/30px result, at two viewports, with the same instrument; the four controls carry one class from
one factory, and a shell and a row built from the components alone produce the same control; seven
one-thing mutations each turn the delivery's own test red; the child pane's Steer and Cancel reach the
host's handler through `chat-action` with `{action, control}`, exactly once per click, across a row
rebuild and a pane reconnect; the main chat's `#steer` by id still works; `inspect` is exactly after
`Reload window`, asks for one named window twice, leaves the asking window untouched (no reload, no
navigation, no write, no other shell call, transcript intact), and the `?view=inspect` page shows the
chat, keeps the browser's own menu, opens nothing, resizes nothing and only reads; the delivery touched
only `ui/**`, `scripts/test-ui.ps1` and `DESIGN.md`; `DESIGN.md` states the one-control rule.

**Not proven / not done:** the reuse of the OS window and Chrome's `Inspect element` were not observed
in a real window (source + page behaviour only); no full `scripts/test.sh` run; no push; no deploy; the
running window and the installed UI were never touched. Two of my ten mutations are documented blind
spots rather than passes. My own instrument is new code and its first three failures were my bugs (a
probe exception, a flex-squeeze in the screenshot, and a probe that moved a pane out of its host) —
each is fixed and the fix is in the committed probe.

**Should anything block landing?** Yes: the gate finding. It is one line and it is not the reviewer's
to write — a producer should fix the tip (or the parser) and the lane should re-run
`node scripts/gate-check.mjs run ui-browser` before landing. Everything else is a note, not a blocker.

Agent: wasm-agent node=wasm_the_first role=reviewer session=child:dispatch:997da2ba-fd44-40b7-ad1e-5607debcaac4
