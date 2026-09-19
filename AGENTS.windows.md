# Windows-only rules

Injected only when this node is running on Windows (see `agent.agents_md`). Nothing here belongs in
`AGENTS.md`: a rule that is only true on one platform costs context on every turn of every other platform,
and it teaches a node to distrust rules it cannot check.

- **Never hand a POSIX path to a native Windows process.** `/c/...` is unusable as an argument: a process
  starts, cannot find its files, and reports a normal-looking failure. The node did exactly this with
  `--ui`, served 404 for `/` while `/health` said it was fine, and the window showed "not found" for an
  afternoon. Convert at the boundary (`cygpath -w`), and prefer the Windows path in the first place.
- **Never restart or replace the window.** It is a client: it reconnects and reloads on its own. Replacing
  `wa-window.exe` is a separate deploy that needs the Docker cross-build.
- **A window that looks alive but does nothing is a *page* problem, and the node can say so.** Check
  `/health`: `ui_page_age_ms` (a number = the page is polling the node) and `ui_error` / `ui_error_age_ms`
  (what the page reported about its own failure). A page that neither polls nor reports is not running at
  all - the webview is showing an error page, and an error page runs no JavaScript, which is why clicks and
  reloads do nothing.
- **Ask the page instead of guessing.** Start the window with
  `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9333`, then read
  `http://127.0.0.1:9333/json/list` and `Runtime.evaluate` for `location.href`, `document.title` and
  `performance.getEntriesByType("navigation")[0].responseStatus`. One query found in seconds what three
  hypotheses - a cache, a profile lock, the WebView2 runtime - did not.

## Status

This file is **not injected yet**. `agent.agents_md` was extended to append it on Windows and that change
broke the gating test (`master must read AGENTS.md`), so it was reverted rather than left in a red gate. The
mechanism is the small remaining piece: resolve the base role file as before, then append
`AGENTS.<platform>.md` from the same directories when `host.platform()` matches, and assert both halves in
`scripts/test.sh` - the global file naming no platform mechanism, and the platform file arriving on the
platform it is for. Until then the Windows rules live in `AGENTS.md` as well, and `DESIGN.md` 1a is the
direction.
