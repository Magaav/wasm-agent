# Evolving wasm-agent with wasm-agent

The agent can work on its own repository: it has `bash`, `read`, `write`, `edit`
and `grep`, the repo's `AGENTS.md` is injected every turn, and its instruction
files describe the two-tree workflow. This document is the plumbing around that.

## The loop

```
1. create a worktree of the wasm-agent repo (its own branch)
2. launch the agent there           -> wa chat   (or --agent wasm, see below)
3. give it the brief
4. it edits, tests, commits, pushes the branch
5. a human reviews the branch and merges
```

Step 1 and 2 through Orca:

```powershell
# one worktree per task, branched from origin/main
orca worktree create --repo id:<wasm-agent-repo-id> --name <task> --no-parent --json
# the agent in the first terminal of that worktree
orca terminal create --worktree <worktree-id> --title wasm-agent --command "<worktree>\scripts\dev-agent.cmd" --json
orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 60000 --json
orca terminal send --terminal <handle> --text "<brief>" --enter --json
orca terminal read --terminal <handle> --json      # watch it work
```

With the registration script applied (see *Picker entry* below) this collapses
to one command, the same shape as any other Orca agent:

```powershell
orca worktree create --repo id:<wasm-agent-repo-id> --name <task> --agent wasm --prompt "<brief>" --json
```

## What the agent can and cannot verify on this machine

| | Windows node | cloud host |
| --- | --- | --- |
| Lua core changes | yes, live (see below) | yes |
| `bash scripts/test.sh` | **no** (no Rust toolchain) | yes |
| `bash scripts/test-behavior.sh` | yes | yes |
| Rust host changes | no | yes |

`scripts/test.sh` builds the Rust binary first, so on a node without `cargo` the
suite stops there. The divide follows the languages: Lua and UI work is fully
verifiable on Windows, Rust work is not.

## Editing the Lua core without a rebuild

The Lua core is compiled into `wa` with `include_str!`, so normally a Lua change
needs `cargo build`. Set `WASM_AGENT_LUA_ROOT` to a checkout and `dofile` prefers
the files on disk, falling back to the embedded copy:

```powershell
$env:WASM_AGENT_LUA_ROOT = "C:\Users\Victor\orca\workspaces\foundation\self-evolve"
wa paths                     # runs the edited Lua
```

Or just use the launcher, which sets it for you:

```powershell
scripts\dev-agent.cmd        # `wa chat` with this checkout's Lua core
```

That is what makes self-evolution possible at all on a machine with no toolchain:
the agent edits `lua/`, runs the installed binary, and sees the change
immediately.

Two consequences worth knowing:

- Edits take effect on the **next** `dofile`, which happens per turn — so a
  broken module breaks the agent's own runtime mid-session.
- Recovery is trivial and always available: unset the variable and the embedded
  copy is used again, or `git checkout -- lua/`. The agent cannot brick itself
  permanently.

## Running the full suite from a Windows worktree

Push the branch, then use the cloud tree, which has the toolchain:

```bash
git push -u origin self-evolve
ssh openclaw.ohana 'cd /local/projects/wasm-agent && git fetch origin self-evolve && git checkout FETCH_HEAD && bash scripts/test.sh'
```

`wa-remote` runs the same commands on the cloud node if the local one is busy.

## Picker entry: registering `wasm` as an Orca agent

Orca's TUI agent list is hardcoded and unknown ids are dropped by its settings
normalizer, so there is no supported way to add one. `scripts/orca-wasm-agent.ps1`
registers it by editing the two *unpacked* files that define the registry and the
display names, with a backup, a syntax check and a `-Revert`:

```powershell
powershell -File scripts/orca-wasm-agent.ps1            # register
powershell -File scripts/orca-wasm-agent.ps1 -Revert    # undo
```

Then restart Orca. Notes:

- An Orca update replaces those files, so re-run the script after updating.
- Nothing else in Orca is touched; `wa chat` is drivable through a plain terminal
  with or without this.

## Briefs that work

The agent follows `AGENTS.md`, so the useful briefs state the goal, the
constraint, and how to prove it:

> Add a `wa paths` command that prints what `host.paths()` reports and which
> config file would be read. Wire it into `wa help`, add an assertion to
> `scripts/test.sh`, and show me the command output. You have no Rust toolchain
> here: verify with `WASM_AGENT_LUA_ROOT` set, and run the full suite on the
> cloud if you push.

Bad briefs are the ones that leave verification out, because then the agent
either guesses or claims success it cannot show.

## Running a candidate node beside the stable one

A patched build can be tested without disturbing the installed node. A candidate
is just a second agent with its own state, and the isolation boundary is
`WASM_AGENT_HOME`:

- `<home>/.wasm-agent/env` — its own environment file
- its own `memory.db`
- its own `node.key`
- its own plugins

Everything the node writes hangs off that directory, so the candidate never
touches the stable node's data. It does still need its own network identity:

- a distinct `--port`
- a distinct `--client-port`
- `WASM_AGENT_ENDPOINT` pointing at **its own** endpoint. Without it the registry
  advertises the stable node's address, and direct calls to the candidate are
  misrouted to the stable node.

To test a patched branch:

```bash
git checkout <branch>
cd rust && cargo build --release && cd ..
cp rust/target/release/wa /tmp/wa-candidate
git checkout main

WASM_AGENT_HOME=/tmp/wa-candidate-home \
WASM_AGENT_ENDPOINT=<candidate-endpoint> \
/tmp/wa-candidate serve --port <port> --client-port <client-port>
```

Promotion is a human step: fast-forward `main`, rebuild, and reinstall the binary
on each machine. The candidate promotes nothing by itself.
