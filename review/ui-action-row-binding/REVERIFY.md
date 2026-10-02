# Independent review, second half — `change/ui-action-row-binding` at `c498f935`

**Delivery:** same branch, tip `c498f935af44bda927d705dafc8b23da1b56b3d6` (tree
`1ebbf790a6f8b44c37d14713a388ea0dd3d101b4`), the fix commit `6296a07`, `c498f93` merging `origin/main`, not pushed.
The first half of this review refused `b33c781` (verdict and instrument: `VERDICT.md` beside this file,
commit `7815fc0`). This file is the **bounded re-verify of the delta** — the six findings that refusal
recorded, and nothing else.

**Reviewer:** `child:dispatch:997da2ba-fd44-40b7-ad1e-5607debcaac4`, own worktree
`C:/Users/Victor/.wasm-agent/wa-worktree-childdispatch997da2ba-fd44-40b7-ad1e-5607debcaac4`, branch
`review/ui-action-row-binding-2` cut from `c498f93`. Served copies of `ui/` only; the running window,
the installed UI and every other lane's tree untouched; no push.

**Model note:** as in the first half — `gpt-6-luna` is not servable on this node, so this ran on
`deepseek-v4.1-flash`/high, the producer's family. Independence is the lane and the instrument.

**Verdict: `passed`.** The blocker is fixed and independently reproduced; every finding I recorded is
answered in the code and now measured; one *new*, bounded coverage gap is recorded below (a one-surface
change in a property outside the audited sets still passes) and does not block landing.

## What I ran

| # | Command (my worktree) | Result |
| --- | --- | --- |
| a | `node scripts/test-gate-check.mjs` | `ALL PASS` / `gate check runner ok (19 checks, 0 skipped)` |
| b | my own parser matrix through `checkVerdict` (13 inputs) | mangled forms reject; a wrong suffix accepts (see §1) |
| c | `node scripts/gate-check.mjs run ui-browser --output …` | `check ui-browser: PASS exit=0 ms=8393.6` |
| d | `node review/ui-action-row-binding/run.mjs --ui ui --probe …/probe-controls.js --query "?review_expect=equal"` at `1280x900` and `420x700` | PASS both — 30/30, and my rule audit + cross-surface appearance |
| e | `bash review/ui-action-row-binding/mutate4.sh` — 6 mutations on this tip | 4 FAIL, 2 slip (mine) |
| f | `…/probe-viewmenu.js` with no query, `?view=orchestrator`, `?view=inspect` | PASS all three |
| g | `…/probe-inspect.js` (main window), `…/probe-inspect-view.js` (`?view=inspect`), `…/probe-plumbing.js` | PASS all three |
| h | `sed -n '402,422p;506p;611p' rust/wa-window/src/main.rs` | citations accurate (§6) |

## 1. The gate (was BLOCKING)

Independently reproduced: **`check ui-browser: PASS exit=0 ms=8393.6`** on this tip, with the verdict
line `  ok   UI structure, mid-run reload, startup recovery, the inspect window, and a view window`.
The parser is now `scripts/gate-check.mjs:22` `/^\s*ok   UI structure\b/` and
`scripts/test-gate-check.mjs` grew 17 → 19 checks (`gate check runner ok (19 checks, 0 skipped)`,
`ALL PASS`).

**The negative side, attacked with my own matrix** (`checkVerdict({verdict:'browser'}, exit, text)`):

```
ACCEPT  old wording                       "  ok   UI structure, mid-run reload, and startup recovery"
ACCEPT  longer wording (this tip)         "  ok   UI structure, mid-run reload, startup recovery, the inspect window, and a view window"
ACCEPT  wrong suffix                      "  ok   UI structure, and then something else entirely"
ACCEPT  truncated                         "  ok   UI structure"
reject  doubled space                     "  ok    UI structure, mid-run reload"
reject  no space after ok                 "  ok UI structure, mid-run reload"
reject  ok   UI structureX                "  ok   UI structureX"
reject  marker mid-line                   "earlier text  ok   UI structure, mid-run reload"
reject  another check's ok line           "  ok   Engine structure is fine"
reject  doubled marker                    two matching lines
reject  marker + FAIL                     "  ok   UI structure, a" + "FAIL evidence"
reject  exit 7 with the marker
reject  empty
```

So a mangled report, a doubled marker, a marker in the middle of a line and another check's `ok` line
all still fail — the tolerance is not a rubber stamp — **but the suffix is not checked at all**: any
line that begins `ok   UI structure` counts, including one that names something else entirely or stops
after two words. That is the deliberate trade (the sentence grows with the stages), and it is now
pinned only on the "another check's line" side. Recorded as `parser:unresolved` below, low, not
blocking.

## 2. The box: no second statement left

`ui/style.css:119` is now `wa-orchestrator button:not(.chat-control)` (and `:120` for `:disabled`), so
the rule cannot match a footer control at all rather than losing on specificity. **My own audit at this
tip** (probe-controls.js, which walks every stylesheet rule and asks each control `el.matches(...)`, now
over 35 box/paint/position properties) reports the four controls' box stated by **one** rule each:

```
main-chat Steer      height [".chat-control"]  min-width [".chat-control"]  padding-left [".chat-control"]
                     border-radius [".chat-control"]  font-size [".chat-control[data-label]"]
child-pane Steer     identical to the main chat's Steer
main-chat append     height/min-width/padding/border-radius all [".chat-control"], no label variant
child-pane append    identical
only other match on any of them: "*" (box-sizing) - a global that states no box of its own
```

`wa-orchestrator button` no longer appears for any of the four. I looked for another way in and did not
find one that survives: `!important` exists in `style.css` only as `[hidden] { display:none !important }`
(display, not the box); no inline style is set on these controls anywhere in `app.js`/`components.js`
(grep), and M9 in the first half showed that when a host sets one the suite catches it; the
`[data-label]` variant states padding/font/colour only, and it is the shared rule family the DESIGN
paragraph describes; and the two surfaces now *compute* the same appearance — my own cross-surface
comparison over 28 properties (`appearance-equal: True`, `append-equal: True` at both viewports).

## 3. My two blind spots, reproduced as fixed — and one of mine that still slips

`mutate4.sh` on this tip (each applied alone, suite run, tree restored):

| Mutation | Now |
| --- | --- |
| **M7** one control recoloured alone (`wa-orchestrator .chat-control[data-action] { border-color:#ff0000 }`) | **FAIL** — `exactly one rule may state a footer control's height, border and radius …, saw [… "child action -> .chat-control + wa-orchestrator .chat-control[data-action]"]` **and** the cross-surface check with `border-top-color=rgb(255, 0, 0)` against `rgb(35, 41, 54)` |
| **M8** the shared box stated a second time, identical values | **FAIL** — `… "main action -> .chat-control + .footer-right .chat-control[data-action]"` |
| **M5b** the higher-specificity rule that used to move the pane's control alone | **FAIL** (padTop 5px vs 0, plus the cross-surface comparison) |
| **M4** (control) the deleted `#steer`-only rule restored | **FAIL**, now caught three ways (measured box, the stating-rule audit naming `#steer`, the cross-surface comparison) |
| **M10 mine** `wa-orchestrator .chat-control[data-action] { margin-top: 4px }` — one surface alone | **GREEN — still slips** |
| **M11 mine** `wa-orchestrator .chat-control[data-action] { letter-spacing: 3px }` — one surface alone | **GREEN — still slips** |

The two that slip are outside both audited sets: `carriesBox` is height/min-width/border-radius/`border*`
and `carriesPaint` is `color`/`background*`/`font*`, and the cross-surface `appearanceProperties` list
has no `margin*`, `letter-spacing`, `transform`, `opacity`, `outline*` or `box-shadow`. So a rule can
still make the pane's row sit 4px lower, or widen one surface's labelled controls, without the suite
noticing. It cannot produce the defect that was reported (height/border/radius are pinned, and widths
are diagnostics by design), so this is a coverage gap, not a regression: recorded as
`coverage:unresolved`.

## 4. The view menu, both directions

`probe-viewmenu.js`, three loads:

```
(no query)          prevented=true   drawn=true   ["Collapse to avatar","Reload window","inspect","---","Close wasm-agent"]
?view=orchestrator  prevented=true   drawn=true   ["Collapse to avatar","Reload window","---","Close wasm-agent"]
?view=inspect       prevented=false  drawn=false  []
```

- a view that is **not** the inspector draws this app's own menu again, exactly the four items it held
  before the inspector existed — the rule I measured as changed for every view in the first half is
  restored, and I measured it in both directions;
- that view does **not** offer `inspect`, which is right, because `openInspectWindow` refuses from
  inside a view (`if (viewMode()) { setStatus(…); return false; }`) — offering a control that is always
  refused would be worse than not offering it;
- the main window offers it **immediately after `Reload window`** and last before the separator — the
  ordering claim re-measured (`probe-inspect.js`: `["Collapse to avatar","Reload window","inspect","---","Close wasm-agent"]`);
- the inspector keeps the browser's own menu (event not prevented, no app menu);
- none of the three called the shell (`shellCalls: []`).

The inspect item itself is unchanged and still passes: two invocations → two identical asks
(`view:"inspect"`, same URL), the shell's refuse-a-known-title model leaves **one** window
(`"reused": true`), and the asking window still does not reload, navigate, fetch or otherwise touch the
shell. `probe-inspect-view.js` still passes: `expanded`, the full furniture, no app menu, no shell call,
`reads 8 / posts 0`, no leftovers. `probe-plumbing.js` still passes unchanged (one `steer_session` by
id; one `steer` and one `cancel` through `chat-action` `{action, control}`, exactly once each across a
row rebuild and a pane reconnect).

## 5. The width claim is withdrawn

The busy check's condition is height-only (`Math.round(busySteerRect.height)===Math.round(busyAttachRect.height)
&& Math.round(busyAttachRect.height)===30`), and the pane check is `footerBoxes[2].h===30 &&
footerBoxes[3].h===footerBoxes[2].h`. The only `width` in the new code is inside the failure text, and it
now says so: `(w 55 - the label's own width, which follows the ambient font and is reported, not
asserted)`. A grep of the harness for width comparisons finds only the two pre-existing checks (the
two-by-two pane grid, the window drag) — no width is asserted for a footer control. Confirmed: the
harness no longer presents a width as a claim.

## 6. The reuse evidence names what it says it names

`rust/wa-window/src/main.rs`, read at this tip:

- `:404` `"open_view" if from_main => {` and the block runs to `:421` — the cited `:404-421` is the whole
  handler;
- `:406` `if state.views.iter().any(|open| open.window.title() == view) {` — the guard; the early
  `return false;` that reuses rather than stacks is at `:408`, with `note("view {view} is already open")`
  at `:407`. So ":406, the title check" is accurate and ":406, the early return" would be off by two
  lines; the delivery writes the former;
- `:506` `.with_default_context_menus(true)` in `open_view` — the view's webview;
- `:611` `.with_default_context_menus(false)` in `run()` — the main window's webview.

Both `app.js` comments and the new DESIGN.md paragraph cite these correctly.

## Findings

| class | status | finding |
| --- | --- | --- |
| `coverage` | unresolved | The new audits pin height/min-width/border-radius/`border*` (box), `color`/`background*`/`font*` (paint) and a fixed cross-surface property list. A one-surface change in a property in none of them still passes: measured green for `wa-orchestrator .chat-control[data-action] { margin-top: 4px }` (the pane's row sits 4px lower) and `{ letter-spacing: 3px }` (one surface's labelled controls widen). Cannot produce the reported height defect; a follow-up could extend the sets or compare the whole computed style minus a known-different list. |
| `parser` | unresolved | The tolerant prefix accepts the *whole suffix*: `checkVerdict` returns ok for `"  ok   UI structure, and then something else entirely"` and for the bare `"  ok   UI structure"`. Mangled forms do reject (doubled space, `structureX`, mid-line marker, doubled marker, another check's line, `FAIL`, non-zero exit), and the suite's new negative case covers the last of those — but nothing pins the sentence, so a future line that begins `ok   UI structure` and means something else would be counted as this verdict. Low: only `scripts/test-ui.ps1` prints that prefix. |
| `evidence` | resolved | The reuse half of the inspect claim is the shell's, and it is now named in the code and in DESIGN.md with the exact lines (`main.rs:404-421`, the guard at `:406`); I re-read them and they say what the delivery says. What a real window shows Chrome's `Inspect element` in remains unobserved by me (opening one is out of bounds), and is now correctly presented as the shell's property (`:506` vs `:611`) rather than as something the page proves. |
| `claim` | resolved | "The composer footer's controls are one implementation" is now scoped in DESIGN.md to the controls the shell owns, with the host's own children (`#mic`, account chip, status chip) named as outside it; and `wa-orchestrator button:not(.chat-control)` means no second rule states a footer control's box. My own rule audit finds no second statement for any of the four controls. |
| `scope` | resolved | The right-click rule is stated for every window kind in DESIGN.md §3 ("Whose context menu a window draws") and measured in both directions: views draw the app's menu again, the inspector draws the browser's, `inspect` is offered only where it can be carried out. |
| `gate` | resolved | `node scripts/gate-check.mjs run ui-browser` → `PASS exit=0` on this tip, `scripts/test-gate-check.mjs` → `19 checks, 0 skipped`, and my own matrix shows the negative cases still fail. The blocker I refused `b33c781` for is gone. |
| `measurement` | resolved | The height claim holds unchanged on this tip (30/30 at 1262×748 and 500×548, append-file 30×30, all four `.chat-control`, footer overflow 0) and the width is no longer asserted anywhere. |

## What is proven, and what is not

**Proven on this tip:** the gate check passes and its parser still rejects mangled and duplicated
reports; the four controls' box is stated by exactly one rule, with no other rule matching them that
states a box; the two blind spots I reported (a one-control recolour, a duplicated-but-identical box)
now fail; the view menu is restored for views and measured in three directions; the inspect feature and
the Steer/Cancel plumbing are unchanged and still pass; the reuse and context-menu citations match the
shell source; the width is a diagnostic.

**Not proven / not done:** no real second OS window was opened (the reuse and Chrome's menu are shell
source plus page behaviour); no full `scripts/test.sh`; the two coverage gaps above are unresolved by
design and are recorded rather than fixed; no push, no deploy, and nothing outside my own worktree was
touched.

**Should anything block landing?** No. The blocker is fixed and reproduced; the two remaining findings
are coverage notes for the next change to this test, not defects in the UI.

Agent: wasm-agent node=wasm_the_first role=reviewer session=child:dispatch:997da2ba-fd44-40b7-ad1e-5607debcaac4
