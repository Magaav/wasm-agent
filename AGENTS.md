# AGENTS.md — working on wasm-agent

Instructions for any agent (or human) editing this repo. This file is injected
into wasm-agent's own context at runtime, so keep it short and operational.

## One repo, three trees, all pushing to GitHub

| Tree | Path | Role |
| --- | --- | --- |
| Cloud (authoritative runtime) | `openclaw.ohana:/local/projects/wasm-agent` | builds, runs, hosts the rendezvous + relay |
| Windows clone | `orca/workspaces/wasm-agent/loggerhead/foundation` | editing, tests, review |
| Orca worktree | `workspaces/foundation/<task>` (one per task) | one agent per task, its own branch |

All of them push to `github.com/Magaav/wasm-agent` (remote `origin`). **GitHub
is the source of truth**; none of them is "the" copy. Before editing: `git
pull`. After editing: commit and push, then pull on the other side.

Every tree authenticates with the `github-wasm-agent` SSH host alias:
`git@github-wasm-agent:Magaav/wasm-agent.git`.

### If you are an Orca-spawned agent in a worktree

- Your worktree is a `git worktree` of this repo, branched off `origin/main`.
  Treat that branch as your deliverable: **work on it, commit to it, push it.**
  Do not rewrite `main`, and do not push to `main` — hand the branch off or open
  a PR, and let the human merge.
- The last commit on your branch is the human's review surface. Keep commits
  small and make each message say *why*, not just *what*.
- Working-directory rule still applies: `git config core.autocrlf` must be
  `false`. Worktrees inherit it from the shared git dir, so verify, don't assume.

### Never touch the old plugin

`openclaw.ohana:/local` is a **different repository**
(`github.com/Magaav/hermes-orchestrator`), and `/local/plugins/wasm-agent`
inside it is the Python v8 predecessor of this project. It is a **reference,
not a target**: read it if you must, but never edit, build, deploy or "fix" it.
The same goes for `/local/docs/context/*` and `find-run.py` — those describe the
old plugin's runs.

This repo is *also* nested on that host, at `/local/projects/wasm-agent`. That
nesting is why the two get confused: it is a separate git repo (the old one
ignores `projects/`), so `git -C /local status` says nothing about this repo.
Always name the path in full.

### Keep LF

These files are consumed by a Linux host and by `sh`/`lua`, so they must stay
LF. `core.autocrlf` **must be `false`** in every checkout, and the committed
blobs must contain no CR:

```bash
git config core.autocrlf                    # must print false
bash scripts/test.sh                        # enforces the rest; prints "line endings ok"
```

The check is in the smoke test rather than a one-liner here because it cannot be
spelled portably: it needs a literal carriage return, and the POSIX form
(`git grep --cached -I -l "$(printf '\r')"`) silently does nothing under
`cmd /C` on Windows — an agent working there reported exactly that. The test
itself reads the **stored** blobs and skips binaries, which is the invariant that
matters: a CRLF working copy on Windows is recoverable, a CRLF commit is not.

Do **not** verify this with `grep -c $'\r' <file>` — in some shells the pattern
arrives empty, so it returns the *line count* (`444` for `lua/core/agent.lua`)
and looks exactly like a repo-wide CRLF disaster.

## Layout

```
lua/core/        the agent: schema, memory, tools, provider, turn loop, server
lua/vendor/      json.lua
rust/wa-host/    the `wa` binary: host capabilities + embedded Lua 5.4
rust/wa-window/  the Windows WebView2 desktop shell (cross-built, see below)
rust/plugins/    example WASM plugin
ui/              the chat window (plain files, hot-reloaded)
scripts/         install, build, test
docs/            design documents
DESIGN.md        UI contract — read before touching ui/
```

## Build and verify

```bash
cd rust && cargo build --release --offline   # offline; crates are vendored/cached
bash scripts/test.sh                          # hermetic smoke test, no model needed
bash scripts/test-behavior.sh                 # memory/language/session policy (needs a model)
```

On a Windows node, `powershell -File scripts/test-windows.ps1` runs the local
suite: binary, identity, UUID uniqueness, config, memory, sessions, tools, a real
turn, the UI on localhost, and that an unreachable remote node changes nothing.
Both extra suites are safe to re-run and never print a credential.

The smoke test is the gate for the Lua core and the WASM plugin ABI; it needs
`cargo` on `PATH`, so run it on the cloud tree if the local one lacks it.

The Windows shell is cross-built from Linux (Docker + mingw):

```bash
bash scripts/build-window.sh                  # -> target/windows-x64/.../wa-window.exe
```

## Conventions

- **No Python.** Agent logic is Lua; platform capabilities are Rust `host.*`.
  Read `docs/HOST.md` before adding a capability: a host function returns `nil`
  for missing values (never zero values), and paths come from `host.paths()`,
  never `$HOME` or a Linux-only path.
- **UI changes need the UI test, not an opinion.** `scripts/test-ui.ps1` replays a
  synthetic turn in a real headless browser and asserts the structure (one reply
  bubble per turn, decisions and tool topics *inside* it, pi-style tool lines, a
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
