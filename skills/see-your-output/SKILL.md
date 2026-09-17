---
name: see-your-output
description: How to verify work whose result is visual or interactive - a UI, a rendered page, a window - when you have no eyes. Use it before claiming any change to ui/, a layout, a rendering or a front-end behaviour works.
---

# Seeing your own output

You cannot see the screen, so a UI change is unverifiable by reading code. Saying
"done" after editing `ui/` is a guess. This skill is how to turn it into evidence.

Two techniques, in order. Use both: the first proves *structure*, the second shows
*appearance*.

## 1. Assert the DOM in a real browser, headlessly

You need: the app served over HTTP, a headless browser, and a synthetic run that
puts the app into the state you want to inspect. No clicking, no timing, no
screenshots to squint at — the browser prints the DOM and you assert against it.

```bash
# 1. serve the app on a free port (the UI reads its files fresh per request)
wa serve --port 8899 --client-port 8801 --ui /path/to/ui &

# 2. copy the UI somewhere writable, inject a probe, and expose what you need
cp -r ui /tmp/ui-probe
#    - append to app.js:   window.handleEvent = handleEvent;
#    - append to index.html, before </body>, a <script> that:
#        * replays the events you care about, e.g.
#          [{type:"round",n:1},{type:"delta",text:"..."},{type:"tool",name:"read",arguments:{...}},
#           {type:"tool_result",result:{...}},{type:"reply",text:"..."},{type:"done"}]
#        * then inspects document.querySelector(...) and writes its verdict into
#          a <pre id="probe"> element
# 3. print the DOM and read the verdict
"/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" \
  --headless=new --disable-gpu --dump-dom http://127.0.0.1:8899/
```

Rules that save time:

- **Run the probe synchronously**, not in a `setTimeout`: headless virtual time
  does not reliably advance, and a timer that never fires looks exactly like a
  broken app.
- **No backslash escapes inside the injected script.** One stray `\n` inside a
  string is a syntax error that kills the whole block silently — the page then
  renders normally and your probe simply never runs. Write the probe without
  escapes (`out.join(' ~ ')` instead of a newline join) and check it with
  `node --check` before trusting a null result.
- **Check the probe ran at all** before concluding anything: if the verdict
  element is missing from the dump, your instrument is broken, not the app.
- An empty result is not evidence. `grep` for a marker you know must be present
  first.

## 2. Screenshot it, and look at the image

Structure is not appearance: spacing, wrapping, contrast and overflow are only
visible. Take a screenshot and actually read it.

```bash
"/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" \
  --headless=new --disable-gpu --hide-scrollbars \
  --window-size=430,700 --screenshot=/tmp/shot.png http://127.0.0.1:8899/
```

Then open the PNG and look. A screenshot that shows the desktop instead of your
window means the window is off-screen, not that rendering failed — move it
(`SetWindowPos`) and retake it before writing a word about the result.

## 3. Leave the test behind

If the thing you verified is worth keeping correct, add it as a script under
`scripts/` and run it the way the other suites are run. A verification that only
happened once, in your head, is not a test — the next change to that code will
break it silently.

## What not to do

- Do not claim a UI change works because the code "looks right".
- Do not claim it fails because your probe found nothing — check the probe first.
- Do not report success on structure alone when the question was appearance.

## Boundaries

Two things this skill is not a licence for, both learned from an agent that spent 28
tool calls on them:

**Never drive the user's browser.** The `cdp` action of the `client` tool is for
acting on the user's machine at the user's request - a browsing task. It is not the
way to look at the wasm-agent UI: that is a page *this node serves*, so fetch it, or
load it in a headless browser you launch yourself. Chrome's debug endpoint is slow to
come up, so CDP fights you with connection errors that have nothing to do with your
change, and you end up touching a browser session that is not yours.

**Never write into the installed UI to instrument it.** `%LOCALAPPDATA%\wasm-agent\ui`
(and the equivalent on the node) is what the user's window is running. Copy it
somewhere, instrument the copy, and serve that - which is what `scripts/test-ui.ps1`
does. An agent that overwrote the installed `app.js` left the user's window running
its probe until it restored a backup, and the user reasonably concluded that
reloading the app changed nothing.

**And for anything beyond a trivial command, write a script file and run it.** A long
one-liner handed to the shell loses its quoting and its backslashes: a PowerShell
line of 118 characters died on a parse error, and a Windows path lost every
backslash on the way through `bash -c`, which then looked like the filesystem was
broken. Write `probe.ps1`, run it with `-File`, and pass paths with forward slashes.
