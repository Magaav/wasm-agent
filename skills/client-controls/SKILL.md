---
name: client-controls
description: How to act on the user's own machine (screenshot, mouse, keyboard, a shell) and how to browse a web page in Chrome. Use when asked to open/read/click something on their desktop or in a browser, and read this first when a `client` or `shell` action has failed or timed out.
---

# Controlling the client machine

The `client` tool reaches the machine that runs the desktop window. The node is
the server; the window dials out to it, so nothing here needs inbound access.

## Check execution support before a client action

Permission is not executability. In a required bound workspace, discover
`client` with `tool_search` (or inspect `capabilities.execution.client`). A
blocked/unknown result is not loaded: do not invoke it or retry `status`.
Provide an existing artifact link or report the limitation. Never clear the
binding or use another executor/session to bypass it. Metadata covers only
workspace policy; actual permissions/arguments/effects are still checked.
See `<repo>/docs/BINDING-DISCOVERY.md` for the discovery contract.

## Start with the cheap question

```
client {action: "status"}
```

It costs one probe and answers: is the window polling, what did it last do, is a
Chrome running for it, on which port, and which pages are open. The `nodes` tool
shows the same thing as a `client` row (`online`, `bridge.health`, `busy`,
`browser`) without a round trip. Do this *after a runtime client failure*, not
before every call. A `workspace_execution_context_unsupported` or missing
required binding is a pre-execution refusal, not a runtime client failure:
there is no client effect to diagnose, and `client status` is blocked too.

## Browsing: use `browser`, not `cdp`

```
browser {target: "open", url: "https://example.com"}   -> {page:{id,url,title,ready}, chrome:{port,...}}
browser {target: "read"}                               -> {text, truncated, page:{...}}
browser {target: "eval", script: "document.title"}     -> {value}
browser {target: "list"}                               -> pages only, no browser furniture
browser {target: "activate"|"close", id: "<page id>"}
browser {target: "quit"}                               -> closes the browser it opened
```

- `open` **reuses** a tab already on that URL (`reuse: false` forces a new one),
  so repeating it is safe and cheap. That is what makes retries sane.
- `read` returns page text, capped (`max_chars`, default 2000). Read, do not
  scrape the whole DOM.
- Every result carries `chrome.port` and `chrome.browser` — **the port is
  reported, never passed**. Only give `port` when you know an endpoint exists
  (someone started their own Chrome with remote debugging); the usual mistake is
  passing 9222 and colliding with whatever else holds it.
- `addressed` means the target id you acted on is in the result. Act on it
  explicitly next time (`id:`) instead of hoping which tab is "first".

`cdp` is the escape hatch for protocol work (`launch`, `list`, `navigate`,
`evaluate`); its result is the raw shape. Prefer `browser` unless you need it.

## The desktop itself

`screenshot` (whole virtual desktop, with `origin_x/origin_y` + `monitors`),
`frame` (delta tiles for the control view), `click`, `move`, `type`, `key`,
`shell` (cmd or powershell). A click is in *screen* coordinates: add the frame's
origin before clicking.

## When it fails

Read the error: it carries `observed` (what was seen) and `next` (what to do).
Three different failures exist and they are not the same:

| What you see | What it means | What to do |
| --- | --- | --- |
| `bridge.health: "wedged"` | the node's own bridge stopped answering | nothing: it recovers by itself. **Never restart the window or the node.** |
| `connected: false`, bridge `ok` | the window is closed or its executor stopped | ask the human to open the window (`wa ui`); meanwhile use `bash` on the node |
| `chrome_handed_off` | that Chrome profile is already open elsewhere | use the port that Chrome is on, or another `profile` |
| `chrome_start_timeout` | Chrome did not come up in the budget | raise `timeout_ms`; the result carries Chrome's own log lines |

A `client_timeout` means the client did not answer in the budget it was given -
and because the same number bounds the client's own work, the action *stopped*.
The result is still kept: `client {action: "result", id: "<the id in the error>"}`
collects it, even if the window has since gone.

Never: stop the node to fix the controls, start a second window, guess a CDP
port, or replace the window binary. Evidence lives in `/health` (the `client`
block), `%LOCALAPPDATA%\wasm-agent\wa-window.log` and `chrome-launch.log`.

## Verified discovery contract

The on-demand `binding-discovery-proof` spell records
`node <repo>/scripts/test-binding-discovery.cjs <built-wa> <fresh-evidence>`
and its retained-hash `--post`. Required workspaces use this verified direct
CLI, not unsupported replay. It proves the metadata/unchanged native refusal,
not real desktop/browser execution. Keep blocked client/status at zero attempts.

## Making it repeatable

Once a sequence works (open a page, click through, assert something), save it
with `spell_save` including a `post` assertion. Spells are parameterised and
verified, so the next run — on this node or a brand-new one — does not have to
rediscover the clicks or the ports.
