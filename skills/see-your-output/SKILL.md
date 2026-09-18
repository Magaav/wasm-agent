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
turn runs in the node's interpreter, and the window is a renderer that can be
replaced at any moment. So:

- **Patch by deploying files.** The node reads `ui/` per request. Copy the changed
  files into the directory the window is served from (`app.js`, `style.css`,
  `index.html` — whatever changed) and the running window picks them up. CSS is
  swapped in place; JS is deferred until the turn in flight finishes, and then
  reloads itself. Both halves already work: do not invent a mechanism.
- **Never restart the node to patch the UI.** A restart kills the interpreter and
  therefore kills whatever turn the person is having. That is not a side effect to
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
  arriving for a turn that started before the reload do not: the node streams to the
  request that opened it. "Repaint and resume" means the window reattaches to the
  running turn and replays what it missed. Until that exists, a reload during a turn
  loses its partial text — so if you must reload *while* a turn runs, prefer waiting.
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
replays a synthetic turn, and asserts structure. Run it before and after a change:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1
```

It prints one verdict line. Add your claim as a `check(...)` beside the others.

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
