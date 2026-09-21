# AGENTS.md — working on wasm-agent

Instructions for any agent (or human) editing this repo. This file is injected
into wasm-agent's own context at runtime, so keep it short and operational.

## One repo, three trees, all pushing to GitHub

| Tree | Path | Role |
| --- | --- | --- |
| Cloud (authoritative runtime) | `openclaw.ohana:/local/projects/wasm-agent` | builds, runs, hosts the rendezvous + relay |
| Windows trunk | `orca/workspaces/wasm-agent/loggerhead/foundation` | `main`. Editing, review, merges. A node never works here |
| The node | `orca/workspaces/wasm-agent/node/foundation` | a node's own worktree, on the branch that carries its name |

All of them push to `github.com/Magaav/wasm-agent` (remote `origin`). **GitHub
is the source of truth**; none of them is "the" copy. Before editing: `git
pull`. After editing: commit and push, then pull on the other side.
Every tree authenticates with the `github-wasm-agent` SSH host alias:
`git@github-wasm-agent:Magaav/wasm-agent.git`.

### Evolving code in parallel

**Before the first edit of a code-writing turn, load the `parallel-evolution` skill.** It is the
per-turn loop (sync → small change → prove it merges → gate → end clean) and the
convergence/escalation protocol. These rules hold whether or not it is loaded:

- **Your branch is your name** (`git symbolic-ref --short HEAD`); `main` is never a node's name,
  and a commit to `main` is refused by the hook.
- **One `change/<name>` per concern**, from current `origin/main`, merged and deleted.
- **Never move a tree you do not own.**
- **End every commit with its provenance trailer** (the hook prints the form when one is missing).
- **Merging cleanly is part of done** — prove it with `git merge-tree --write-tree origin/main HEAD`.

### Never touch the old plugin

The v8 plugin is the reference, not the target. Read it; do not modify it.

### Keep LF

These files are consumed by Linux and by `sh`/`lua`; `core.autocrlf=false` stores bytes as they are.
The `pre-commit` hook enforces it - that hook is the contract, this line is the pointer.

## Build and verify

```bash
cd rust && cargo build --release --offline   # offline; crates are vendored/cached
bash scripts/test.sh                          # hermetic smoke test, no model needed
bash scripts/test-behavior.sh                 # memory/language/session policy (needs a model)
```

On a Windows node, `powershell -File scripts/test-windows.ps1` runs the local
suite: binary, identity, UUID uniqueness, config, memory, sessions, tools, a real
run, the UI on localhost, and that an unreachable remote node changes nothing.
Both extra suites are safe to re-run and never print a credential.

The smoke test is the gate for the Lua core and the WASM plugin ABI; it needs
`cargo` on `PATH`, so run it on the cloud tree if the local one lacks it.

The Windows shell is cross-built from Linux (Docker + mingw):

```bash
bash scripts/build-window.sh                  # -> target/windows-x64/.../wa-window.exe
```

## Conventions

- **The host is capabilities, not logic.** Agent logic is Lua; platform capabilities
  are Rust `host.*`. Read `docs/HOST.md` before adding a capability: a host function
  returns `nil` for missing values (never zero values), and paths come from
  `host.paths()`, never `$HOME` or a Linux-only path.
- **Install through `scripts/deploy.sh`.** It is the one gate: refuses a dirty tree,
  refuses a tree behind `origin/main`, proves the binary on a scratch port, installs
  via `upgrade.sh`, records `installed.txt`, and verifies the pid answering is its own.
  Never copy a binary over a running one by hand, and do not re-implement it.
  From *inside* a run, do not launch this gate: it cannot wait for
  itself to become idle. Build and test, then request the external sentinel to
  upgrade; `skills/self-update/SKILL.md` gives the one-request continuation path.
- **Never hand a POSIX path to a native Windows process.** `/c/...` is unusable as an
  argument: the node starts, cannot read `index.html`, and answers 404 for `/` while
  looking healthy. Convert it (`cygpath -w`).
- **Never restart or replace the window.** It is a client: it reconnects and reloads on
  its own. A window that looks alive but does nothing is a *page* problem, and the node
  can say so: `/health`'s `ui_page_age_ms` (a number = the page is polling) and
  `ui_error` (what the page reported). A page that neither polls nor reports is not
  running at all - ask it directly with
  `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9333`.
- **More than one worker is normal.** Read workers spawn on demand and retire when
  idle; runs route by session. `/health`'s `workers[]` says who is busy with what.
- **Skills carry procedures, not context.** A technique the agent should not
  have to be told twice belongs in `skills/<name>/SKILL.md` (the Agent Skills
  standard, shared with pi and Orca). Only the description is always in
  context; the body loads when a task matches. Write the *trigger* into the
  description. See `docs/SKILLS.md`.
- **UI changes need the UI test, not an opinion.** `scripts/test-ui.ps1` replays a
  synthetic run in a real headless browser and asserts the structure (one reply
  bubble per run, steps and tool topics *inside* it, pi-style tool lines, a
  failing tool opening its topic). Run it before claiming a UI change works: the
  UI is not observable through `bash`, `grep` or `read`, so without it you are
  guessing and cannot tell whether you built what was asked. It caught a crash on
  the very first run of the change that introduced it.
- Read `DESIGN.md` before UI work (spacing scale, balloons, modes) and
  `docs/` before changing memory, sessions, sync or the node fabric.
- Memory is **on demand**: never inject memory into context automatically;
  the instruction file is the only automatic injection, and it is **scoped by
  role** — operators get `AGENTS.md`, guests get `AGENTS.guest.md` and never
  fall back to the operator file (`docs/MEMORY.md`).
- Failures must be **visible**: no silent success, no silent data loss. Surface
  the error and the step. `docs/MEMORY.md` explains the tracing model.
- Verify before claiming: run the smoke test, and prefer a real two-node check
  over a single-process one.
- A **skipped test is reported as skipped**: the suites count skips and say so in the
  verdict. A run that did not test something must not print the sentence a run that did.

## Stopping the node

Never stop it by image name. `Stop-Process -Name wa` — and even a filter on the
path, because an agent session runs the same binary from the same place — kills
the UI server *and* every interactive session with it, mid-run, leaving no crash
and no trace. That has now cost two runs, the second while this very rule was
being written. `wa ui` records the server's pid; stop that, or ask the port:

```powershell
Stop-Process -Id (Get-Content "$env:LOCALAPPDATA\wasm-agent\serve.pid")
```

An unfinished session is not lost: `wa chat --continue` resumes the thread with
its transcript intact, and the window offers to continue it where it stopped.

## Restarting the node you are running on

You cannot: the stop is the last command your run executes. Ask the sentinel - the procedure, and the
reasons, are in `skills/self-update/SKILL.md`.

