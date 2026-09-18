# Sentinel

The process outside the node.

## Why it exists

Every failure that mattered had one shape: **the only process that could act was the one that needed
acting on.**

- A node cannot restart itself. The turn doing the restarting runs on the node it is stopping, so the
  stop is the last command it ever executes — the copy never happens, the start never happens, and the
  node stays down with nobody to bring it back. This happened twice in one day.
- A dead node cannot say why it died. Two outages left nothing in a file, which is why the cause had to
  be guessed.
- A node cannot be trusted to judge whether it should be woken: that spends money.

So the sentinel lives outside, watches, and acts on **declared requests** — a fixed verb list, never a
shell. The thing that can restart your agent must not be something your agent can talk into anything.

## Asking

```
wa-sentinel request restart  --reason "why"
wa-sentinel request upgrade  --binary /path/to/wa --reason "why"
wa-sentinel request wake     --session <id> --prompt "..." --reason "why"
wa-sentinel request run      --script /path/to/script.sh --reason "why"
```

`request` **writes a file** and returns. `watch` (or `once`) performs it. That split is the whole
point: the writer may die immediately afterwards, and the request still lands.

The box is `<config>/sentinel/requests/*.json` — `~/.wasm-agent/sentinel/requests` by default. A file
survives the death of whoever wrote it, needs no socket, and works **when the node is down**, which is
when you need it most.

## What it guarantees

- **The node is never the first thing to change.** `restart` waits for the node to be idle before
  stopping it, so it is never the reason a turn dies; `upgrade` proves the new binary answers on a
  scratch port before it goes near the running node.
- **Stop by pid, never by image name.** Another `wa` on the machine may be somebody's session.
- **Every action is logged with its reason** in `<config>/sentinel/sentinel.log`, including refusals.
  Nothing here happens silently.
- **Waking is budgeted.** `WA_SENTINEL_WAKE_BUDGET` per hour (6 by default) because it is the only verb
  that costs money. Over budget, it refuses and says so.
- **`run` is disabled** unless `WA_SENTINEL_SCRIPTS` names the directories it may execute from.
- **A kill switch:** `wa-sentinel stop`, or create `<config>/sentinel/stop`.

## Operating

```
wa-sentinel status   # the node, the watcher, the box, the wake budget, the last actions
wa-sentinel start    # start watching (detached)
wa-sentinel stop     # ask it to stop
wa-sentinel once     # handle the box once and exit - for tests and for cron
```

It is started by the installer. On a machine that runs a node for other people, run it under the
service manager alongside the node — it is the thing that has to survive the node, so it should not be
a child of it.

## What it deliberately does not do

- **No model, no Lua, no ledger.** It executes declared intents; it does not converse, decide, or write
  to the transcript. It is a supervisor, not a second agent.
- **No automatic restarts.** An auto-restart nobody asked for fights the operator every time they stop
  a node on purpose. It reports an outage and waits to be asked.
- **No shell verbs.** A verb list, not a command line.

## For an agent

If you are running inside a turn, **you cannot restart the node you are running on** — the stop kills
your turn before your next command runs. Ask instead:

```bash
wa-sentinel request restart --reason "picking up the binary I just built"
```

Your turn will die as `unfinished` when the node stops; that is expected, and the request is already on
disk. Write a `wake` request too if you want to be brought back to continue:

```bash
wa-sentinel request wake --session "$MY_SESSION" --prompt "the node restarted; carry on" --reason "self-update"
```

Both requests are durable, so the order you write them in is the order they will be performed.

## Waking the model on an event

A trigger is a rule in `<config>/sentinel/triggers.json`. The trigger decides **when**; the verbs decide
what, and they are the same fixed list as everywhere else — so a trigger can never do anything an
operator could not ask for directly.

```json
[
  { "kind": "file", "path": "C:/Users/me/Downloads", "pattern": ".png",
    "session": "<session id>",
    "prompt": "a new file appeared in the download folder: {name}. Say what it is and whether it needs anything.",
    "reason": "download watcher" },

  { "kind": "health", "when": "down", "verb": "restart", "reason": "the node fell over" },

  { "kind": "schedule", "every_seconds": 21600, "session": "<session id>",
    "prompt": "summarise what happened in the ledger since the last check",
    "reason": "six-hourly summary" }
]
```

`{name}`, `{path}` and `{event}` are substituted into the prompt, so the model is told what happened
rather than asked to guess. Every firing goes through the same wake budget as a manual request: an event
storm must not be able to spend money quietly, which is the only thing here that costs anything.

The first pass after startup only *records* state — a sentinel started while the node is down must not
decide the node just fell over, and a directory full of old files must not fire once per file.

Three kinds are implemented: `file` (a directory, optionally filtered by a substring), `health` (the node
going down or coming up), and `schedule` (every N seconds). CDP, a webhook and the rendezvous events are
the obvious next ones and take the same shape — a watcher that calls `fire()`.

## Running it as a service

`deploy/wa-sentinel.service` is the systemd unit, and the header of that file carries the Windows
scheduled-task equivalent. It must not be a child of the node: a supervisor that dies with the thing it
supervises is decoration.
