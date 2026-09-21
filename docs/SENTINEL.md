# Sentinel

The process outside the node.

## Why it exists

Every failure that mattered had one shape: **the only process that could act was the one that needed
acting on.**

- A node cannot restart itself. The run doing the restarting runs on the node it is stopping, so the
  stop is the last command it ever executes — the copy never happens, the start never happens, and the
  node stays down with nobody to bring it back. This happened twice in one day.
- A dead node cannot say why it died. Two outages left nothing in a file, which is why the cause had to
  be guessed.
- A node cannot be trusted to judge whether it should be woken: that spends money.

So the sentinel lives outside, watches, and acts on **declared requests** — a fixed verb list, never a
shell. The thing that can restart your agent must not be something your agent can talk into anything.

## Asking

```
wa-sentinel request restart  --reason "why"    # graceful; stays queued while busy
wa-sentinel request recover  --reason "why"    # explicit interruption; never waits for idle
wa-sentinel request upgrade  --binary /path/to/wa --reason "why"
wa-sentinel request upgrade  --binary /path/to/wa --session <id> --prompt "continue after upgrade" --reason "why"
wa-sentinel request deploy   [--session <id> --prompt "continue after deploy"] --reason "why"
wa-sentinel request spell    --file /path/to/plan.json --reason "why"
wa-sentinel request wake     --session <id> --prompt "..." --reason "why"
wa-sentinel request run      --script /path/to/script.sh --reason "why"
```

### `deploy` is not `upgrade`, and the difference matters

`upgrade` installs the node and the UI. It **cannot** install a *sentinel*: `upgrade.sh` copies the node
binary, the UI, itself and the self-update skill, and only ever *reads* the sentinel's hash. So a fix in
the sentinel — the process that supervises everything else — had no path from inside a run, and needed a
human at a shell running `deploy.sh`.

`deploy` closes that: it runs `scripts/deploy.sh` (the gate: clean tree, not behind `main`, the binary
proved on a scratch port, install, rollback if the new node does not answer), which installs the node,
the UI **and** the sentinel. Two properties make it work, and both are deliberate:

- **it waits for idle before it starts.** `deploy` is in the same group as `restart`/`upgrade`/`spell`:
  the watcher holds the request until no turn is running. Without that, the script's own idle wait would
  be waiting for the very turn that asked for it, and the supervised child's 302 s deadline would turn
  that deadlock into a kill — which is exactly how the first attempt failed.
- **it runs detached.** Every other verb is a supervised child whose output is evidence; this one must
  outlive its parent, because the parent is the process being replaced, and on Windows only a *different*
  process can overwrite the image of a running one. Nothing is lost by that: `deploy.sh` proves the new
  node before it goes near the live one, records `installed.txt` and `deploy.log`, and rolls back on its
  own. The completion signal is the continuation wake, queued by the script once the new node answers
  `/health` and performed by the **new** watcher.

A stopped watcher can still only be restarted from outside a turn: nothing that is running can hear a
request. That is why the supervisor belongs in a service or a logon task (`deploy/wa-sentinel.service`
is the systemd unit). This verb removes the human step for *updating*; the one for *reviving* remains.

`request` **writes a file** and returns. `watch` (or `once`) performs it. That split is the whole
point: the writer may die immediately afterwards, and the request still lands.
An upgrade with both `--session` and `--prompt` wakes that session only after a
successful upgrade, avoiding a race between separately queued upgrade and wake
requests. `installed.txt` records the exact hash even for sentinel upgrades;
their source commit remains explicitly unverified unless built by the clean
deployment gate. The detailed upgrade transcript is in `sentinel/upgrade.log`.

### `/update`: the node asking, on a human's behalf

The same request can be written from inside the node — `/update` in the composer, or in `wa chat` —
because the operator should not have to leave the window to say "install the build in your own
tree". It is the same box and the same verb:

```
/update          # the window (POST /update) and the CLI both run lua/core/update.lua
```

That module asks three questions and answers them honestly: is there a runtime tree
(`runtime-worktree.txt`), is anything built in it (`rust/target/release/wa`), and is that build
newer than what is installed (tree commit against `installed.txt`). Then it writes one request
through this binary and reports **queued** — never "updated", because the record that settles it is
in `sentinel/done/` or `failed/`. A refusal is also an answer: `nothing_built` names the build
command, `no_runtime_tree` names what it looked for, `no_sentinel` says which path is missing, and a
tree with uncommitted files installs but warns that `deploy.sh` would have refused it. The node never
installs anything itself, and the request it writes is the same one a human would type.

The box is `<config>/sentinel/requests/*.json` — `~/.wasm-agent/sentinel/requests` by default. A file
survives the death of whoever wrote it, needs no socket, and works **when the node is down**, which is
when you need it most.

## What it guarantees

- **Maintenance and recovery are distinct.** `restart` remains queued while the node is busy,
  without blocking the watcher. `recover` interrupts by the listener PID without asking Lua to go
  idle; use it only for deliberate recovery. Direct `wa-sentinel recover "reason"` is the independent
  escape path even if legacy maintenance is occupying the request processor. `upgrade` proves the new binary answers on a
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

If you are running inside a run, **you cannot restart the node you are running on** — the stop kills
your run before your next command runs. Ask instead:

```bash
wa-sentinel request restart --reason "picking up the binary I just built"
```

Your run will die as `unfinished` when the node stops; that is expected, and the request is already on
disk. Write a `wake` request too if you want to be brought back to continue:

```bash
wa-sentinel request wake --session "$MY_SESSION" --prompt "the node restarted; carry on" --reason "self-update"
```

Both requests are durable, so the order you write them in is the order they will be performed.

## Managed jobs

For new automations use [JOBS.md](JOBS.md): durable definitions, default-off approval,
revision-pinned queues, enabled/disabled Engine controls after tools, file/schedule/event/CDP
sources, and either a skill-backed wake or deterministic allow-listed execution.
External process executions are **operations**, never jobs ([OPERATIONS.md](OPERATIONS.md)).
The runner holds an exclusive OS lock; interrupted deliveries are unknown and not replayed.

## Waking the model on an event (legacy triggers)

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

## Self-update — the `spell` verb

A plan the agent wrote, executed here because the node cannot execute it. `spells.lua` exports a
spell as portable JSON (`spell_export`, or `POST /spell/export`), and this verb runs it while the
node is being replaced — the one moment the node is the least able to act.

```
spell_export(name: "self-update", binary: "...")     # -> a path
wa-sentinel request spell --file <path> --reason "..."
```

A plan is **untrusted input**: the agent writes it, and this process is the thing that can restart
the node. So a step names a verb from a fixed list — `wait-idle | upgrade | restart | wait-health` —
and everything else is refused before a single step runs:

* an unknown verb, or **`run`** (the operator's script escape hatch);
* a `kind` other than `sentinel` (a client action belongs to the node; dropping it silently would
  make the plan do less than it says);
* an empty `steps`, an empty `post`, a missing `binary` on `upgrade`, a `binary` on a verb that
  takes none, or a `binary` path that does not exist.

`post` is required here for the same reason it is required in `spells.lua`: a plan that cannot state
its success condition cannot be settled, and "reported success while doing nothing" is the failure
mode both exist to prevent. The sentinel settles it with its own `/health` check — the assertion an
in-run agent cannot make about itself.

A refused plan is refused **whole**: nothing runs, so a half-executed plan is impossible.

### What the agent cannot do

An agent inside a run cannot restart the node it is running on, and cannot run a spell about that
node (`spell_run` returns `needs_sentinel`). It cannot read the result either: `/client`, `/spell`,
`/health`'s busy state and everything else that needs the interpreter queues behind the run
holding the worker, so a call the agent makes to its own node waits on itself. The route out is
always the same: **write a request and let this process do it.**

`run` is disabled unless `WA_SENTINEL_SCRIPTS` names the directories it may execute from — and note
that `spell` deliberately does not go through `run`, so enabling `run` does not widen what a plan
can do.

### How fast it is

Measured on this machine, not estimated. The numbers matter because "seamless" is a claim about
seconds, so it should be a claim about *measured* seconds:

| what | cost |
| --- | --- |
| cold start (spawn → `/health` ok) | ~55 ms |
| kill → process gone | ~150 ms |
| `/health` round trip | ~0.6 ms |
| **whole cached upgrade command** | **~750 ms** |
| **node unreachable during it** | **~235 ms** |

The whole `upgrade.sh` run is ~750ms once the binary is known-good, and the *outage* — the window in
which the node answers nothing — is about a quarter of a second. That is what the window's version
poll (once a second, reconnecting by itself) turns into an unbroken transcript rather than a dead
page.

Four things were removed to get there, each found by timing the phase rather than guessing:

1. **A fixed `sleep 2` after the kill.** The process is gone in ~150 ms, so ~1.8 s per upgrade was
   spent asleep for nothing. It now polls the port until it is free, which also cannot be too short
   on a loaded machine.
2. **Polling with PowerShell.** `Get-NetTCPConnection` costs ~600 ms to start; `netstat -ano` costs
   ~40 ms for the same answer. Every port question — the free-port scan, the port-free wait — now
   goes through `netstat`, except the two that genuinely need Windows APIs (stop and start).
3. **A fixed 5 s idle tick.** Fine while a long run is in flight, ruinous at the moment it ends, because the
   swap cannot begin until a poll notices. It polls at 5 s while the node is known-busy, then at
   0.5 s.
4. **Re-proving the same binary every time.** A build that answered once answers forever — the same
   bytes cannot un-start. The verdict is cached by SHA-256 in `<install>/.upgrade-proof` (last 20
   hashes), which removes the ~20 s worst-case scratch-port proof from every upgrade after the
   first. Only *positive* verdicts are cached: a build that failed to answer is retried, because the
   failure may have been a busy machine rather than the binary.

What is left is two `powershell.exe` calls — one to stop by pid, one to start — because there is no
shell equivalent, and each carries a fixed ~600 ms of process start. That is the floor for this
approach, and it is why the outage is ~235 ms rather than ~55 ms: the start is fast, the *way we
start* is not.
