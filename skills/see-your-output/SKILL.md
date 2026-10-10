---
name: see-your-output
description: >-
  How to patch the wasm-agent UI and verify the result when you have no eyes: which directory the
  window actually reads, why a patch must never stop a run, how to assert structure in a headless
  browser, and how to look at the thing afterwards. Use it before claiming any change to ui/, a
  layout, a rendering or a front-end behaviour works, and before restarting anything to make a UI
  change appear.
---

# Patching the UI, and seeing what you did

You cannot see the screen, so a UI change is unverifiable by reading code. Saying
"done" after editing `ui/` is a guess. This is how to turn it into evidence — and how
to patch the UI without interrupting the person using it.

## 0. The rule that comes first: a UI patch never stops a run

The UI is a **view of a durable ledger**, not the thing that owns the work. That is the
whole reason a patch can be safe: the transcript lives in the node's database, the
run executes in the node's interpreter, and the window is a renderer that can be
replaced at any moment. So:

- **Patch by deploying files.** The node reads `ui/` per request. Copy the changed
  files into the directory the window is served from (`app.js`, `style.css`,
  `index.html` — whatever changed) and the running window picks them up. CSS is
  swapped in place; JS is deferred until the run in flight finishes, and then
  reloads itself. Both halves already work: do not invent a mechanism.
- **Never restart the node to patch the UI.** A restart kills the interpreter and
  therefore kills whatever run the person is having. That is not a side effect to
  accept; it is the failure this section exists to prevent. It has happened: a node
  was restarted to install a *binary* while somebody was mid-conversation, and their
  run died with the process.
- A restart is only required for a **Rust** change — a new route, a changed host
  function. That is a different kind of work with a different cost, so: prefer a
  path that needs no restart (Lua routes already exist; extend one if it fits),
  and when a restart is genuinely needed, say so and let the human choose the
  moment between runs.

Two consequences worth stating, because both come up:

- **Anything the window holds that the ledger does not is a bug waiting to be a lost
  run.** After a reload the transcript comes back from the ledger, but tokens still
  arriving for a run that started before the reload do not: the node streams to the
  request that opened it. "Repaint and resume" means the window reattaches to the
  run in flight and replays what it missed. Until that exists, a reload during a run
  loses its partial text — so if you must reload *while* a run is in flight, prefer waiting.
- **A patch that only adds a topic or a control changes the UI, not the node.** Ship
  it the same way.

## 1. Find out which UI the window is actually reading

This is the most common way to do everything right and see nothing:

```bash
# what the node was started with, and whether the served bytes are yours
ps -eo pid,args | grep -E "[s]erve --port"          # look for --ui <dir>
curl -s http://127.0.0.1:8799/app.js | grep -c 'the string you just added'
curl -s -m 5 http://127.0.0.1:8799/version           # changes when the files do
```

A node started with `--ui %LOCALAPPDATA%\wasm-agent\ui` serves the **installed** copy,
not your checkout. Editing the repository changes nothing that window reads. Deploy to
the served directory, then confirm with the `grep` above — and read the version to see
that the change is live. If the version does not move, the window will not reload.

## 2. Assert the DOM in a real browser, headlessly

`scripts/test-ui.ps1` is this technique, already written: it copies `ui/` to a temp
directory, stubs the HTTP layer with `ui/test-fixtures.js`, injects a probe that
replays a synthetic run, and asserts structure. Run it before and after a change:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1
```

It prints one verdict line. Add your claim as a `check(...)` beside the others.
First run the focused disposable-browser probe; only after it passes run the
required UI suite once. Do not launch the broader suite alongside a probe still
known to fail, or repeat read/discovery/graph work that already established the fix.

Rules that save time, all of them learned the hard way:

- **Prove your assertion can fail.** A check that never runs and a check that passes
  look identical. Break it on purpose once (flip the condition), watch the harness
  report `FAIL`, and put it back.
- **Run the probe synchronously.** Headless virtual time does not reliably advance, so
  anything that waits on a timer or a real async callback never completes — an
  `await` on a callback that never fires hangs the *entire* harness and the verdict
  line simply never appears. `tick()` (a resolved promise) drains microtasks; use it.
  Anything needing a real async step (image decoding) cannot be checked here.
- **No escape sequences in the injected script.** One stray `\n` inside a string is a
  syntax error that kills the block silently: the page renders normally and the probe
  never runs. Write it without escapes and check it with `node --check` first.
- **An empty result is not evidence.** If the verdict element is missing, your
  instrument is broken, not the app.
- Fixtures are matched by **path exactly** (`url.includes("me")` also matches
  `node/name`), so add a stub for any new endpoint you read.

## 3. Screenshot it, and look at the image

Inside the disposable Linux coding benchmark image, `wa-ui-observe` serves a
staged copy of `/work/ui`, injects `test-fixtures.js`, and writes `dom.html` and
`screenshot.png` from real headless Chromium. Pass `--probe /path/to/probe.js`
to run a task-specific check; the probe must write a `pre#wa-probe` with
`data-status="pass"` or `data-status="fail"`. The command fails if Chromium or
the probe fails. Use `--out /trace/ui-observation` to retain only the evidence.
`wa-ui-contracts --base HEAD` reports classes, custom elements, and custom
events removed by the patch. Review each reported removal against callers and
CSS; a clean result does not prove behavior. These commands are available to
benchmark agents without revealing the hidden oracle.

**The same command runs on this host, against *your* worktree, and you can read the
picture.** Chrome is installed here, so from your checkout:

```bash
node scripts/agent-benchmark-ui-observe.mjs --out "$TEMP/ui-look"   # ./ui by default
```

It serves a copy of your `ui/` with `test-fixtures.js` injected, never touches the
node or the installed UI directory, and exits non-zero unless the page really
rendered and the probe passed. `--ui <dir>` picks another tree, `--chrome <path>`
another browser, `--require <text>` pins a DOM marker, `--probe <file>` asserts.
**A child agent can see the screenshot**: `read screenshot.png` returns it as visual
input - a blind test (Chrome rendered a random word and number, read back exactly)
confirmed it. So "open the PNG and look" is an instruction that works.

Structure is not appearance: spacing, wrapping, contrast and overflow are only
visible. A screenshot is also the only way to catch that the window is running a
*stale* build of the UI while your assertions pass against your files.

Find the window and read it (Windows):

```bash
orca computer list-windows --app wa-window --json
orca computer get-app-state --app wa-window --window-id <id> --json   # includes a screenshot path
# then open the PNG and actually look at it
```

- The accessibility tree in the same payload gives you element names and indexes, which
  is how to open a balloon or click a control without guessing coordinates:
  `button Signed in as wasm_the_first · 30 tools`.
- A screenshot showing the desktop rather than your window means the window is
  off-screen, not that rendering failed — move it and retake before writing a word.
- Two `wa-window.exe` processes means two windows: an older one outlives the node that
  spawned it. Look at the right one, and close stale ones by **pid**.

## 3b. Seeing a terminal view

The CLI's view (`wa chat`) cannot be checked through `bash` either, and for the same
reason the default terminal read is not enough: a line rewritten in place (`\r` +
erase-to-end) comes back as stacked fragments, so a status line that looks right on
screen reads as garbage in the accumulated stream.

Run it in a real terminal and read the **rendered frame**:

```bash
orca terminal create --worktree path:/path/to/tree --title "VIEW PROBE" \
  --command "C:\\path\\to\\probe.cmd" --json          # returns a handle
orca terminal read --terminal <handle> --screen --json  # what the terminal renders
orca terminal list --json                               # the tab title, which a run sets
orca terminal close --terminal <handle> --tab --json    # leave no trace
```

- Put the environment in the launcher: a `.cmd`/`.sh` file that sets a scratch home and
database and a mock provider, then runs the command. A long `--command` string handed to
the shell loses its quoting and its backslashes.
- Read `--screen` **while the run is in flight** and again after it. A provider that
  answers slowly (a few lines of node, outside the repository) is how you get a frame of
  the middle of a run; both frames are the evidence.
- The tab title is part of the view — `orca terminal list` is how you read it.
- `--screen` and `--cursor` are mutually exclusive, and the default read is the one that
  stacks repainted lines.
- Do not pass `--focus`: the tab is yours, not the user's foreground, and close it when
  you are done.

## Choose the supported proof runner first

In an allocated required session worktree, **run the verified direct CLI first**
with its `--post` check; do not try `spell_run` merely to rediscover the known
`workspace_execution_context_unsupported` refusal. Use the binding already in
context; inspect workspace status once only if unknown. An unavailable required
worktree blocks execution, never falls back to another checkout. Keep its binding,
assertions, deadlines and retained evidence intact. The saved spell remains a
portable record, not replay-verified. See [SKILLS.md](../../docs/SKILLS.md).

## Lightweight rendering proof

For idle resource/polling or long-history changes, `lightweight-ui-proof`
crystallizes `node <repo>/scripts/test-lightweight-browser.cjs <fresh-evidence>`
plus the same command with `--post`. It verifies 13 real-Chromium checks and
retained source/screenshot hashes; no installed UI or user browser is touched.
Mandatory session workspaces currently refuse spell execution, so this spell is
recorded, not replay-verified/preferred. Use the verified direct CLI without
relaxing bindings. Also run `scripts/test-ui.ps1`. Headless rendering assertions
are not GPU/power proof: record real-window measurements separately, never call
percent utilization a temperature or a fan-speed cause. Keep the HTML title
unchanged in probes; the observer positively checks that exact title.

## Run-count footer proof

Run `node <repo>/scripts/test-run-counts.cjs <fresh-evidence>`, then the same
with `--post`, for the staged-browser test and retained hash postcheck.
`run-counts-proof` records that sequence for supported replay. This proof covers
live provider-attempt/tool totals, checkpoint/reload replay,
unknown/lower-bound historical counts, child isolation and narrow footer layout.
Run the hermetic `scripts/test-run-counts.lua` with a scratch home/DB and explicit
Lua root for the actual provider retry/refusal boundary. Mandatory worktrees
currently refuse spell replay; use this verified direct CLI, not relaxed bindings.
It is not live installation proof. Also run `scripts/test-ui.ps1` and inspect the image.

## Shared main/subagent chat proof

Run `node <repo>/scripts/test-shared-chat.cjs <fresh-evidence>` then the same
with `--post` for exact shared topic/composer/Send-Stop styles, full live status,
context/raw details, parent/child renderer clock ownership, draft/scroll/manual
commentary folds, repeated journal clocks and terminal-tail settlement. See
[SHARED-CHAT.md](../../docs/SHARED-CHAT.md). `shared-chat-proof` records the
same sequence; required workspaces use its verified CLI until replay is supported.
Also run `scripts/test-ui.ps1` (including opaque surfaces). A live observation is
read-only: never Send/Stop/steer/reload an operator page or child as a test.

## Minimal chat proof

`minimal-chat-proof` records `node <repo>/scripts/test-minimal-chat.cjs <fresh-evidence>`
plus its retained `--post` check. It covers compact reported-token/lower-bound
formatting (never char guesses), coherent measured context footer/balloon/raw
counts, model/capacity invalidation and unchanged DOM selection,
context-only hover/focus trigger, shared radius token, removed steering buttons,
commentary first-chunk/character growth/manual closure/replay, independent top
warning causes and actual recovery routes, square nameless attachment cards,
quiet successful intake (idle/active/child), refusal visibility, removal/undo and
one-token radius changes including promoted shadow panels. Required worktrees use this verified
CLI first, never a known refused spell replay. Also run `scripts/test-ui.ps1`,
hermetic run-count/Responses/Pi phase fixtures and standalone embedded checks.
Inspect the screenshot; estimates are not exact provider tokens or billing.

## Streaming-answer reading proof

Run `node <repo>/scripts/test-final-answer-reading.cjs <fresh-evidence>`, then
repeat with `--post`, for the fixture-only browser run and retained hash check.
`final-answer-reading-proof` records that same sequence for supported replay.
The normal UI suite also runs its asynchronous explicit,
provisional and unphased growth tests: short output rises to the viewport top,
then overflow grows below while manual reading/jump and child isolation survive.
Spell replay remains unsupported with enforced worktrees; keep the direct CLI
until actual replay passes, without weakening bindings. Inspect the screenshot.
No phase inference, task settlement or installed-source claim follows from scroll.

## Orchestration mode proof

Run `node <repo>/scripts/test-orchestration-ui.cjs <fresh-evidence>`, then the
same with `--post`, for command balloon ON/OFF/unknown, alias, target fencing,
single-flight and report-only worker drafts. `orchestration-mode-ui-proof`
records that sequence; use the supported CLI in required worktrees without a
known refused replay. Also run `scripts/test-ui.ps1`. Actual routing/integration
needs `test-orchestration-routing.cjs <built-wa> <evidence>` against private
Git/mock inference, never a live model or production branch as a test fixture.

## Active orchestrator proof

Run `node <repo>/scripts/test-orchestrator-active.cjs <fresh-evidence>`, then the
same with `--post`, for active-only cards/live rows, historical followup dedup,
settlement, health-confirmed recordless children and preserved open/saved drafts.
`orchestrator-active-proof` records the sequence; use the supported direct CLI
for required worktrees. The private all-history mutation must fail. Also run
`scripts/test-ui.ps1` and inspect the screenshot; filtering is not task settlement.

## Turn ownership proof

Run `node <repo>/scripts/test-turn-ownership.cjs <fresh-evidence>`, then the same
with `--post`, for Send/Continue versus delayed same-thread transcript and idle
health reads. It holds real fixture SSE, retains the request bubble, keeps output
out of the old completed answer, fences post-settlement stale responses and
checks ordered turn boundaries. `turn-ownership-proof` records that sequence;
choose the supported direct runner for required worktrees without a refused probe.
The previous UI fails the race assertion; no live request/tool is replayed.
Also run `scripts/test-ui.ps1` and inspect the screenshot.

## Failure notice proof

Run `node <repo>/scripts/test-failure-notice.cjs <fresh-evidence>`, then the same
with `--post`, to check the actual terminal model error in the yellow recovery
notice, inert text rendering and explicit Continue. `failure-notice-proof`
records the same sequence; choose the supported runner as above, never probe a
known refused binding. Also run the scratch-root `scripts/test-recovery.lua`
fixture for authoritative session details and the required UI suite.

## Chat health proof

`chat-health-proof` records `node <repo>/scripts/test-chat-health.cjs <fresh-evidence>`
and its `--post` hash check. The required UI suite includes this probe: quiet healthy
state, exact-run/connection uncertainty, fixed overlay geometry, recovery and scoped
single-flight observations. Replay remains unsupported for enforced worktrees;
use the direct CLI until its postconditions can actually replay, never relax binding.

## 4. Leave the test behind

If the thing you verified is worth keeping correct, make it a `check(...)` in
`scripts/test-ui.ps1`, or a script under `scripts/` run the way the other suites are.
A verification that happened once, in your head, is not a test — the next change to
that code will break it silently.

## What not to do

- Do not claim a UI change works because the code "looks right".
- Do not claim it fails because your probe found nothing — check the probe first.
- Do not report success on structure alone when the question was appearance.
- Do not restart the node to make a UI change appear (§0).

## Boundaries

**Never drive the user's browser.** The `cdp` action of the `client` tool is for acting
on the user's machine at the user's request — a browsing task. It is not the way to
look at the wasm-agent UI: that is a page *this node serves*, so fetch it, or open it
in a browser you launch yourself. Chrome's debug endpoint is slow to come up, so CDP
fights you with connection errors that have nothing to do with your change, and you
end up touching a browser session that is not yours.

**Deploying the real change is not the same as instrumenting the user's window.**
Copying your finished `app.js` into the served directory is how a patch ships. Copying
a *probe* into it is not: an agent that overwrote the installed `app.js` left the
user's window running its test code until it restored a backup, and the user
reasonably concluded that reloading the app changed nothing. Instrument a copy
(`scripts/test-ui.ps1` does exactly that); deploy only what you mean to ship.

**For anything beyond a trivial command, write a script file and run it.** A long
one-liner handed to the shell loses its quoting and its backslashes: a PowerShell line
of 118 characters died on a parse error, and a Windows path lost every backslash on
the way through `bash -c`, which then looked like the filesystem was broken. Write
`probe.ps1`, run it with `-File`, and pass paths with forward slashes.

**Stop things by pid, never by image name.** Another `wa.exe` on the machine may be
somebody's live session; killing every process that shares a name is how that session
dies. Find the one you mean (by port, by command line, by the pid file), and kill that.
