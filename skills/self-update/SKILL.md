---
name: self-update
description: >-
  How to rebuild and replace the node you are running on - and, when the change is in the supervisor
  itself, how to deploy a new wa-sentinel - without breaking it. Use it whenever a change you made
  requires restarting or replacing this node: a new binary, a rebuilt wa.exe, a Lua or Rust change
  that must be live, a sentinel fix, a self-update, or before you try to restart, re-exec, upgrade or
  deploy yourself (`wa-sentinel request upgrade` / `request deploy`), or call your own node's HTTP
  routes from inside a run.
---

# Updating the node you are running on

You are Lua executing inside a run, in the process you want to replace. Several things follow from
that, and every one of them was learned by failing at them:

- **You cannot restart yourself.** The stop is the last command your run ever executes.
- **You cannot call your own node's routes from inside a run.** `/client`, `/spell`, `/diff`,
  `/health`'s busy state and everything else that needs the interpreter is served by the *worker you
  are occupying*. Your request queues behind the run that made it and waits on itself. This is not
  slow - it is a deadlock, and the executor reports `HTTP=000` after a long timeout, or `worker:
  stalled`. Measured: 10 occurrences in one session, each one a run spent learning this again.
- **Windows locks a running image.** You cannot `cp` over `wa.exe` while your own node runs it.
- **You cannot verify the result from here.** After the swap, the proof is a *different* process.

So the shape is always the same: **you write a request; something outside the node performs it.**

## From inside a run

Build and test the candidate, then write one durable request. Use an absolute
binary path. If the current session id is known, include it and a continuation
prompt; the sentinel wakes that session only after a successful upgrade:

```
wa-sentinel request upgrade --binary "<absolute path to wa.exe>" \
  --session "<current session id>" --prompt "The upgrade finished; verify it and continue." \
  --reason "why"
```

**When the change is in the sentinel, `upgrade` cannot carry it** — `upgrade.sh` installs the node and
the UI and never copies `wa-sentinel.exe`. Use `deploy` for that, and it is the same shape:

```
wa-sentinel request deploy \
  --session "<current session id>" --prompt "The deploy finished; verify it and continue." \
  --reason "why"
```

`deploy` runs the full gate (`scripts/deploy.sh`), waits until no turn is running before it starts, and
runs **detached** — the process it replaces is the one that would otherwise be its parent. It installs
the node, the UI and the sentinel, proves the new node on a scratch port, rolls back on its own if that
proof fails, and queues your continuation once the new node answers `/health`. Read the outcome from
`installed.txt` and `deploy.log`, not from the request: the request says "started detached", which is a
launch receipt, not a result.

The copy that `request deploy` runs sits beside the supervisor, so it cannot find a worktree by looking
at its own parent. It resolves the tree to build from as `WA_DEPLOY_ROOT`, else its `..` when that is a
git work tree, else the runtime worktree recorded in `<install>/runtime-worktree.txt` — pass
`WA_DEPLOY_ROOT` when you want a deploy from somewhere else. A requested deploy that *fails* also wakes
you, naming the refusal: the request being `done` only means it was spawned, and a deploy that refuses
before the swap leaves the node untouched and would otherwise tell nobody. A deploy run by hand passes no
session and wakes nobody.

Two limits worth knowing before you rely on this:

- **A stopped watcher cannot be revived from a run.** Nothing running can hear a request, so use
  `deploy`/`upgrade` while the watcher is up, and keep the supervisor in a service or logon task so it
  comes back by itself (`deploy/wa-sentinel.service` is the systemd unit).
- **The first sentinel that understands `deploy` has to get there by hand once.** A watcher running an
  older build answers `unknown verb "deploy"`, so that one step is a shell command: build, then
  `bash scripts/deploy.sh --reason "…"` from outside the run.

Omit `--session` and `--prompt` together if no continuation is wanted. The
request command only queues work; the record in `sentinel/done` or `failed` and
`installed.txt` report what actually happened. A separate wake request could
race the upgrade. The exact installed binary hash is recorded; when the
sentinel receives an independently built binary, its source commit is only a
hint, not verified provenance.

`deploy.sh` and `upgrade.sh` refuse immediately when launched by a tool inside
a running run. Detaching either command does not make it safe: the child
inherits the run marker and would otherwise wait for its parent to go idle.

For a declared spell, `spell_export` and `request spell` remain available when
the plan needs more than a binary upgrade. The outside-the-run boundary still
applies.

The sentinel checks `/health` from outside after the run ends. The request is
on disk before the process changes. A candidate whose checkout does not
contain the installed commit is refused, avoiding a silent downgrade; bring
that checkout forward and rebuild first.

## Why a spell and not just `bash`

`spell_export` writes a *portable plan*: the resolved steps, with no model and no node involved.
The sentinel runs it under a whitelist (`wait-idle`, `upgrade`, `restart`, `wait-health`), so a plan
can choose *which* step, never *how* it runs. `run` — the operator's script escape hatch — is
deliberately absent: a plan that could reach it would be a shell.

The `post` conditions come with it, and the sentinel satisfies them with its own `/health` check.
That is the assertion you cannot make about yourself: it is the *outside* that can see the new binary
answering.

A spell containing a `sentinel` step **cannot be run from a run** — `spell_run` refuses with
`needs_sentinel` rather than skipping the steps, because skipping them would report success for a
plan whose point never happened.

## The rules that keep it from breaking

1. **Queueing while this run is running is expected.** The sentinel waits for idle
   before swapping. Do not interpret "queued" as "done".
2. **Check the idle state from *outside* the run** (the sentinel log, a file, a wake from before).
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

Self-update is unavailable without these beside the binary, and a fresh install has been missing them
before:

| needed | why |
| --- | --- |
| `wa-sentinel.exe` | the only process that can stop or start this node |
| `scripts/upgrade.sh` | what the sentinel resolves and runs for an `upgrade` step |
| `scripts/deploy.sh` | what the sentinel resolves and runs for a `deploy` step - the one that installs a sentinel; `deploy.sh` ships it, so a node that has only ever had `upgrade` may lack it |

If `request upgrade` is accepted and nothing changes, check those first — the sentinel deliberately
fails loudly now, and says which paths it tried.

## Recovering when a node does not come back

The sentinel keeps `.pre-upgrade` beside the binary and swaps it back if the new one does not answer
`/health` on a scratch port. If you are reading this *because* the node is down, start the sentinel by
hand and read `sentinel.log`; do not hand-edit the database or the binary while it is holding them.

## The one way to install (added later, and it is the gate)

```
bash scripts/deploy.sh --reason "what changed and why"
```

Run this from outside the node's run. It refuses a dirty tree, refuses a tree behind `origin/main`, proves the binary on a scratch port before it
goes near the running node, installs through `scripts/upgrade.sh`, records commit/branch/hash/time/reason in
`installed.txt`, and refuses if the pid answering is not the pid the install recorded. The refusals are paid
for: a node behind main served a diff route that answered `unknown_action:patch`; a gate that stopped one of
two listeners reported success because the *other* node answered `/health`.

**A POSIX path handed to a native Windows process is silently unusable.** An upgrade once started this node
with `--ui /c/Users/...`, so it could not read `index.html` and answered 404 for `/` - the window showed
"not found", ran no JavaScript, and looked like a dead shell for an afternoon. `upgrade.sh` converts it with
`cygpath`, and the node now warns at startup when its ui directory has no `index.html`.

## Stopping the node safely

Never stop it by image name. `Stop-Process -Name wa` — and even a filter on the path, because an
agent session runs the same binary from the same place — kills the UI server *and* every
interactive session with it, mid-run, leaving no crash and no trace. `wa ui` records the server's
pid; stop that, or ask the port:

```powershell
Stop-Process -Id (Get-Content "$env:LOCALAPPDATA\wasm-agent\serve.pid")
```

An unfinished session is not lost: `wa chat --continue` resumes the thread with its transcript
intact, and the window offers to continue it where it stopped.

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

Only development nodes explicitly started with `WASM_AGENT_LUA_ROOT` read Lua
from disk. Production normally uses Lua embedded in `wa.exe`; changing
`lua/core/*` there requires building and upgrading the binary. Do not claim a
disk edit is live just because a worker retired and respawned.
