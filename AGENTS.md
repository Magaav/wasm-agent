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

### Which branch am I on? You never ask — you derive it

**You are a node, and a node is bound to a worktree.** The branch of that
worktree *is* your name, and git already knows it:

```sh
git symbolic-ref --short HEAD     # -> the node's name
```

That is the whole rule. Do not ask which branch to work on, do not invent a
task name, and do not create a worktree per task: work on the branch you are
already standing on, in the tree you are already in. `main` is not one of
those branches — it is where all nodes converge, so a node that finds itself
on `main` is in the wrong tree, and `main` is never a node's name.

The same derivation exists in the agent's own core:
`nodes.node_name()` (`lua/core/nodes.lua`) prefers a name someone set, then
the branch, and `nodes.rename_branch()` moves the branch *first* — locally,
then GitHub, and only then writes the name, or it fails with a reason and
changes nothing. `main`/`master` are refused there rather than renamed.

Blank state, the short version: *my branch is my name; I derive it with git; I
never commit to main.*

### If you are an agent in a node's worktree

- Your worktree is a `git worktree` of this repo, on the branch named after the
  node. Treat that branch as your deliverable: **work on it, commit to it, push it.**
  Do not rewrite `main`, and do not push to `main` — hand the branch off or open
  a PR, and let the human merge.
- The last commit on your branch is the human's review surface. Keep commits
  small and make each message say *why*, not just *what*.
- Working-directory rule still applies: `git config core.autocrlf` must be
  `false`. Worktrees inherit it from the shared git dir, so verify, don't assume.
- **The commit-msg hook enforces the branch rule.** The refusal comes from
  `.githooks/commit-msg` — a commit on `main` whose trailer is `Agent: wasm-agent ...`
  is refused, and so is a commit with no trailer at all. (The `pre-commit` hook is a
  different rule: it refuses **CRLF in the index**.) If you see the main refusal, you are
  on the wrong branch — go back to the branch that carries your node's name
  (`git symbolic-ref --short HEAD` is where you should be), rebase onto `origin/main`,
  push — and it is the hook working, not a bug to work around.
  Enable it in a checkout (once per clone; worktrees share the shared git dir):

  ```sh
  git config core.hooksPath .githooks
  ```
- **Merging cleanly is part of done.** Before you report a task finished, rebase onto
  `origin/main` and prove the branch still merges:
  `git rebase origin/main && git merge-tree --write-tree origin/main HEAD`.
  A branch that conflicts is not finished work — it is a task you have handed to
  someone else, and the longer it waits the more of main it would delete. The drift is
  time, not skill: a task that runs for hours against an old base will meet whatever
  landed while it ran.
- **Commit before you stop.** Uncommitted work is invisible work: the branch reads
  merged while the worktree reads in progress, and neither state can be reviewed.
  If you are not going to finish it, commit it as `wip(...)` and say what remains.
- `scripts/worktrees.sh` prints every worktree with its drift, its uncommitted files
  and whether it merges. Run it before you start, so you know what you are landing on.
- **Never move a tree you do not own.** If your shell's cwd is someone else's checkout -
  a `main` checkout, another agent's worktree - do not switch its branch, commit in it,
  or leave it on a branch of yours. A live run did exactly that: it committed its work
  to its own branch and left the human's checkout sitting on it, so the human's next
  `git add -A` would have landed on the agent's branch. Create your own worktree first
  (`orca worktree create`), or ask.
- **A skipped test is reported as skipped.** The suites count skips and say so in the
  verdict; skipping is something you ask for, not something inferred from a missing tool.
  A run that did not test something must not print the sentence a run that did prints.

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
turn, the UI on localhost, and that an unreachable remote node changes nothing.
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
  idle; turns route by session. `/health`'s `workers[]` says who is busy with what.
- **Skills carry procedures, not context.** A technique the agent should not
  have to be told twice belongs in `skills/<name>/SKILL.md` (the Agent Skills
  standard, shared with pi and Orca). Only the description is always in
  context; the body loads when a task matches. Write the *trigger* into the
  description. See `docs/SKILLS.md`.
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

## Stopping the node

Never stop it by image name. `Stop-Process -Name wa` — and even a filter on the
path, because an agent session runs the same binary from the same place — kills
the UI server *and* every interactive session with it, mid-turn, leaving no crash
and no trace. That has now cost two runs, the second while this very rule was
being written. `wa ui` records the server's pid; stop that, or ask the port:

```powershell
Stop-Process -Id (Get-Content "$env:LOCALAPPDATA\wasm-agent\serve.pid")
```

An unfinished session is not lost: `wa chat --continue` resumes the thread with
its transcript intact, and the window offers to continue it where it stopped.

## Commit provenance

The author *name* is the same for everything here - `wasm-agent` - because both
harnesses and both trees share one configured identity. That is deliberate, and it is
also why the name tells you nothing about who did the work.

The author *email* is the operator's own address, verified on their GitHub account.
GitHub attributes commits by email, so this is what puts the work on their
contribution graph; the name stays shared, so the graph shows the project rather than
pretending one person wrote every line. Commits made before this was set carry the old
synthetic address (`agent@wasm-agent.local`) and are not attributed - rewriting them
would mean rewriting `main`, which this file forbids.

So say who you are in the message. End every commit you make with a trailer:

```
Agent: wasm-agent node=<this node's name> session=<the session id>
Agent: pi session=<the pi session id>
```

The session id is the useful part: it maps the commit back to a transcript, and
the transcript holds the tool calls, the diffs and the reasoning. Without it a
commit is an orphan.

And never leave a tree dirty without saying so. An uncommitted working-tree edit
is invisible, unattributable and lost the moment anyone pulls — which is exactly
what happened to a UI change found sitting in the cloud tree: no author, no date,
no trace, and no way to tell whether it was even wanted.

## Restarting the node you are running on

You cannot: the stop is the last command your turn executes. Ask the sentinel - the procedure, and the
reasons, are in `skills/self-update/SKILL.md`.

## Keep your branch current with main

A node works in its own worktree on its own branch, and that branch drifts: main moves, the node does
not, and then the node cannot see the rules it is supposed to follow.

That is not hypothetical. An agent read `docs/SENTINEL.md` and got `not_found`, correctly - the file was
on main, and its branch was **21 commits behind**. It could not see the sentinel, its documentation, or
the rule telling it to ask the sentinel instead of stopping the node. A node that cannot see main cannot
see the rules, and it will keep making the mistake the rule exists to prevent.

Before starting work:

    git fetch origin && git merge origin/main

And when your work is merged into main, main is merged back into your branch, so the next thing you read
is the current thing.
