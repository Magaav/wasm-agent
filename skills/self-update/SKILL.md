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
