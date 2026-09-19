---
name: self-update
description: >-
  How to rebuild and replace the node you are running on, without breaking it. Use it whenever a
  change you made requires restarting or replacing this node - a new binary, a rebuilt wa.exe, a Lua
  or Rust change that must be live - and before trying to restart, re-exec or upgrade yourself, or
  calling your own node's HTTP routes from inside a turn.
---

# Updating the node you are running on

You are a Lua turn executing inside the process you want to replace. Several things follow from
that, and every one of them was learned by failing at them:

- **You cannot restart yourself.** The stop is the last command your turn ever executes.
- **You cannot call your own node's routes from inside a turn.** `/client`, `/spell`, `/diff`,
  `/health`'s busy state and everything else that needs the interpreter is served by the *worker you
  are occupying*. Your request queues behind the turn that made it and waits on itself. This is not
  slow - it is a deadlock, and the executor reports `HTTP=000` after a long timeout, or `worker:
  stalled`. Measured: 10 occurrences in one session, each one a turn spent learning this again.
- **Windows locks a running image.** You cannot `cp` over `wa.exe` while your own node runs it.
- **You cannot verify the result from here.** After the swap, the proof is a *different* process.

So the shape is always the same: **you write a request; something outside the node performs it.**

## The one command you want

```
spell_export(name: "self-update", binary: "rust/target/release/wa")
# -> returns a path; then, from a shell (not from your turn):
wa-sentinel request spell --file <path> --reason "..."
```

Or, if you only need the binary replaced and the spell does not exist yet:

```
wa-sentinel request upgrade --binary "<absolute path to the new wa.exe>" --reason "why"
```

Both are performed by the sentinel after your turn ends, and both settle their own effect by checking
`/health` from outside. The turn that asked dies as `unfinished` — **that is expected**, and the
request is already on disk before you die.

## Why a spell and not just `bash`

`spell_export` writes a *portable plan*: the resolved steps, with no model and no node involved.
The sentinel runs it under a whitelist (`wait-idle`, `upgrade`, `restart`, `wait-health`), so a plan
can choose *which* step, never *how* it runs. `run` — the operator's script escape hatch — is
deliberately absent: a plan that could reach it would be a shell.

The `post` conditions come with it, and the sentinel satisfies them with its own `/health` check.
That is the assertion you cannot make about yourself: it is the *outside* that can see the new binary
answering.

A spell containing a `sentinel` step **cannot be run from a turn** — `spell_run` refuses with
`needs_sentinel` rather than skipping the steps, because skipping them would report success for a
plan whose point never happened.

## The rules that keep it from breaking

1. **Never queue an upgrade while `health.current` is non-null.** `upgrade.sh` refuses to swap under a
   running turn, so the request sits in the queue - which is safe, but it means the upgrade will not
   happen until the node is genuinely idle. Do not interpret "queued" as "done".
2. **Check the idle state from *outside* the turn** (the sentinel log, a file, a wake from before).
   Asking your own node is the deadlock above.
3. **Failure is silent only if you let it be.** Read `sentinel.log` and the request record in
   `<config>/sentinel/done/` or `failed/`. The record carries `ok`, `detail` and `at`. A queued
   request that never appears in `done/` did not happen.
4. **A duplicate audit line means two runners, not two requests.** Check `<config>/sentinel/done/`:
   one file means the request was performed once. (This was a real race; requests are now claimed by
   atomic rename before they are performed.)
5. **The installed binary and your build output are often the same file** (a hard link). `cp` will say
   so; that is not an error.

## What a fresh node must have

Self-update is unavailable without both of these beside the binary, and a fresh install has been
missing them before:

| needed | why |
| --- | --- |
| `wa-sentinel.exe` | the only process that can stop or start this node |
| `scripts/upgrade.sh` | what the sentinel resolves and runs for an `upgrade` step |

If `request upgrade` is accepted and nothing changes, check those two first — the sentinel deliberately
fails loudly now, and says which paths it tried.

## Recovering when a node does not come back

The sentinel keeps `.pre-upgrade` beside the binary and swaps it back if the new one does not answer
`/health` on a scratch port. If you are reading this *because* the node is down, start the sentinel by
hand and read `sentinel.log`; do not hand-edit the database or the binary while it is holding them.

## The one way to install (added later, and it is the gate)

```
bash scripts/deploy.sh --reason "what changed and why"
```

It refuses a dirty tree, refuses a tree behind `origin/main`, proves the binary on a scratch port before it
goes near the running node, installs through `scripts/upgrade.sh`, records commit/branch/hash/time/reason in
`installed.txt`, and refuses if the pid answering is not the pid the install recorded. The refusals are paid
for: a node behind main served a diff route that answered `unknown_action:patch`; a gate that stopped one of
two listeners reported success because the *other* node answered `/health`.

**A POSIX path handed to a native Windows process is silently unusable.** An upgrade once started this node
with `--ui /c/Users/...`, so it could not read `index.html` and answered 404 for `/` - the window showed
"not found", ran no JavaScript, and looked like a dead shell for an afternoon. `upgrade.sh` converts it with
`cygpath`, and the node now warns at startup when its ui directory has no `index.html`.

## Never touch the window

The window is a client: it reconnects on its own, it reloads when the UI hash changes, and restarting it is a
human's move for a wedged page. Replacing `wa-window.exe` is a separate deploy needing the Docker cross-build.

When a window looks alive but does nothing, the node can say why: `ui_page_age_ms` in `/health` (small = the
page is running), `ui_error` / `ui_error_age_ms` (what the page reported about its own failure). A page that
neither polls nor reports is not running at all - the webview is showing an error page, and an error page has
no JavaScript. Ask the page itself rather than guessing: start the window with
`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9333` and read
`http://127.0.0.1:9333/json/list`, then `Runtime.evaluate` for `location.href`, `document.title` and
`performance.getEntriesByType("navigation")[0].responseStatus`. That one query found in seconds what three
hypotheses (a cache, a profile lock, the runtime) had not.

## The zero-downtime path, for Lua-only changes

A change to `lua/core/*` needs no process restart: the core is read from disk when `WASM_AGENT_LUA_ROOT`
points at this tree, and the read workers are hot-swappable (spawned on demand, retired when idle). Deploy the
files and the next worker spawns with them - no outage to measure, and no turn to lose. Prefer it when it
applies; Rust changes still need the binary path.
