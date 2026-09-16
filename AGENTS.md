# AGENTS.md — working on wasm-agent

Instructions for any agent (or human) editing this repo. This file is injected
into wasm-agent's own context at runtime, so keep it short and operational.

## One repo, two trees, both push to GitHub

| Tree | Path | Role |
| --- | --- | --- |
| Cloud (authoritative runtime) | `openclaw.ohana:/local/projects/wasm-agent` | builds, runs, hosts the rendezvous + relay |
| Local clone | this checkout | editing, tests, review |

Both push to `github.com/Magaav/wasm-agent` (remote `origin`). **GitHub is the
source of truth**; neither tree is "the" copy. Before editing: `git pull`.
After editing: commit and push, then pull on the other side.

The local clone authenticates with the `github-wasm-agent` SSH host alias:
`git@github-wasm-agent:Magaav/wasm-agent.git`.

### Keep LF

`core.autocrlf` **must be `false`** in this checkout. These files are consumed by
a Linux host and by `sh`/`lua`; a CRLF checkout breaks scripts and the Lua core.
Verify with:

```bash
git config core.autocrlf        # must print false
grep -c $'\r' lua/core/agent.lua  # must print 0
```

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
bash scripts/test.sh                          # end-to-end smoke test
```

The Windows shell is cross-built from Linux (Docker + mingw):

```bash
bash scripts/build-window.sh                  # -> target/windows-x64/.../wa-window.exe
```

## Conventions

- **No Python.** Agent logic is Lua; platform capabilities are Rust `host.*`.
- Read `DESIGN.md` before UI work (spacing scale, balloons, modes) and
  `docs/` before changing memory, sessions, sync or the node fabric.
- Memory is **on demand**: never inject memory into context automatically;
  `AGENTS.md` is the only automatic injection.
- Failures must be **visible**: no silent success, no silent data loss. Surface
  the error and the step. `docs/MEMORY.md` explains the tracing model.
- Verify before claiming: run the smoke test, and prefer a real two-node check
  over a single-process one.
