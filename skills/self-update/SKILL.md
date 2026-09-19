---
name: self-update
description: >-
  How to rebuild and replace the node you are running on, without breaking it. Use it whenever a change
  you made requires restarting or replacing this node - a new binary, a rebuilt wa.exe, a Lua or Rust
  change that must be live - and before trying to restart, re-exec or upgrade yourself, or calling your own
  node's HTTP routes from inside a turn.
---

# Updating the node you are running on

You are a Lua turn executing inside the process you want to replace. Several things follow from that, and
every one of them was learned by failing at them:

- **You cannot restart yourself.** The stop is the last command your turn ever executes.
- **You cannot call your own node's routes from inside a turn.** `/client`, `/spell`, `/diff`, `/health`'s
  busy state and everything else that needs the interpreter is served by the *worker you are occupying*.
  Your request queues behind the turn that made it and waits on itself. This is not slow - it is a
  deadlock, and the executor reports `HTTP=000` after a long timeout, or `worker: stalled`.
- **Windows locks a running image.** You cannot `cp` over `wa.exe` while your own node runs it.
- **You cannot verify the result from here.** After the swap, the proof is a *different* process.

So the shape is always the same: **you write a request; something outside the node performs it.**

## The one way to install

```
bash scripts/deploy.sh --reason "what changed and why"
```

That is the gate, and it is the only way a build should become the installed one. It refuses a dirty tree,
refuses a tree behind `origin/main`, proves the new binary answers `/health` on a scratch port before it
goes near the running node, installs through `scripts/upgrade.sh` (which waits for idle, stops by pid,
verifies and rolls back), records commit/branch/hash/time/reason in `<install>/installed.txt`, and refuses
if the pid answering is not the pid the install recorded.

The refusals are the point, and each one is paid for:

- **Dirty** - an install from a half-edited tree is a build nobody can reproduce.
- **Behind main** - a node that cannot see main cannot see its own fixes. One served a diff route that
  answered `unknown_action:patch` for a route that existed in main.
- **Two nodes, one port** - the first version of this gate stopped one of two listeners, failed to bind,
  and then reported success because the *other* node answered `/health`. It was reading someone else's
  outcome. Confirm the action happened before reading its outcome.
- **Do not build and copy by hand.** Two parties installing over each other is how a bug was diagnosed
  twice from a binary that did not contain the instrumentation meant to find it.

## Never touch the window

The window is a **client**. It reconnects on its own, it reloads when the UI changes (`/version` is the UI
hash), and restarting it is a human's move for a wedged page - not part of an update. Replacing
`wa-window.exe` is a separate deploy that needs the Docker cross-build (`scripts/build-window.sh`), and it
is never something a turn does.

If a window looks alive but does nothing, the node can now tell you why:

- `ui_page_age_ms` in `/health` - milliseconds since the page last polled. Small means the page is running.
- `ui_error` / `ui_error_age_ms` - what the page reported about its own failure, and when.

A page that **never polls and never reports** is not running at all, which means the window could not reach
the node: it is showing an error page, and an error page has no JavaScript, so clicks and reloads do
nothing. That is a window-side network or proxy fault, not a node fault - do not restart the node for it.

## The zero-downtime path, for Lua-only changes

A change to `lua/core/*` does not need a process restart, and should not take one:

1. The Lua core is read from disk when `WASM_AGENT_LUA_ROOT` points at this tree.
2. The node's read workers are hot-swappable: they are spawned on demand and retire when idle.
3. So deploying the Lua files and letting the next worker spawn is the whole update - the host keeps
   serving, `/health` never goes away, and there is no outage to measure.

Rust changes still need the binary path above. Prefer this one when it applies: it is faster, it cannot
lose a turn, and it cannot leave the node down.

## When you do need the sentinel

For anything the gate cannot do from a turn - a restart you are not allowed to perform, a wake on an event,
a scripted sequence with post-conditions:

```
wa-sentinel request upgrade --binary "<absolute path to the new wa.exe>" --reason "why"
wa-sentinel request spell --file <path> --reason "..."
```

Both are performed by the sentinel after your turn ends, and both settle their own effect by checking
`/health` from outside. The sentinel runs a fixed verb list (`wait-idle`, `upgrade`, `restart`,
`wait-health`), so a request can never do something an operator could not ask for directly.

## How to verify, from outside the turn

- `<install>/installed.txt` - what is installed: commit, branch, hash, time, reason.
- `/health` - `ok`, `worker`, `stalled_ms`, `current`, `workers[]`, `ui_page_age_ms`, `ui_error`.
- `sentinel.log`, and the request record in `<config>/sentinel/done/` or `failed/`.
- **Failure is silent only if you let it be.** A queued request that never ran is a duplicate audit line or
  a record in `failed/`, not a mystery.
