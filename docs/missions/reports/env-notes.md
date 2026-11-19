# change/env-notes - environment notes picked like AGENTS.windows.md

Branch `change/env-notes`, base `origin/main` (ac7717e0). Two commits, both local, not pushed.

## What the brief asked for, and what the code says

The brief's premise: "read how `agent.lua M.agents_md(role)` picks `AGENTS.windows.md`, and reuse that ONE
mechanism (no second loader)." **Measured, that is false.** `M.agents_md` (lua/core/agent.lua) picks by
role only - `AGENTS.guest.md` for guests, otherwise `AGENTS.md`, then `<config>/AGENTS.md` - and nothing
in `lua/`, `verify/` or `scripts/` loads `AGENTS.windows.md`. The file says so itself, under "## Status":
"This file is **not injected yet**. `agent.agents_md` was extended to append it on Windows and that change
broke the gating test ... so it was reverted." `ARCHITECTURE.md:17` states the intended scope
(`AGENTS.<platform>.md`, "only on that platform") as a rule, not as shipped behaviour.

So there was no platform mechanism to reuse. What I reused is the one thing that *is* the loader
mechanism: the candidate-list resolution order of `M.agents_md`/`M.role_instructions` - environment
override, then the working directory, then `<config>` - and the frames that `M.project_instructions`
already returns. There is no second loader and no second prompt section: the note `table.insert`s into the
existing project frames.

I did **not** implement `AGENTS.windows.md` injection (out of scope, and it is the platform item the repo
already tracks as unfinished). The Windows path is unchanged: `rg 'AGENTS.windows' lua/ scripts/ verify/`
answers **zero hits** on this branch, and it answered zero on base too (the references are in
`ARCHITECTURE.md`, `AGENTS.windows.md` itself and the benchmark fixtures, none of which load it).

## What changed

### 85048da8 - item 1: the two notes, the detector, the test, the gate

- `AGENTS.omarchy.md` (18 lines, budget 40): this is Omarchy (Arch, Hyprland, foot/alacritty); use the
  `omarchy` CLI / `omarchy-*` commands; load the `omarchy` skill before editing anything under
  `~/.config/` (found via `~/.agents/skills`, which Omarchy symlinks - measured here:
  `~/.agents/skills/omarchy -> /usr/share/omarchy/default/agents/skills/omarchy`); never hand-edit
  `/usr/share/omarchy` or `~/.local/share/omarchy`; Hyprland 0.56+ dispatchers are Lua
  (`hl.dsp.window.close()`, `hyprctl dispatch 'hl.dsp...'`) and the old words fail with "expected a
  dispatcher" (measured: `hyprctl dispatch thisisnotadispatcher` -> `error: ... hl.dsp.window.close()`,
  Hyprland 0.56.2); apply with `hyprctl reload` + `hyprctl configerrors`, restart only the `hyprsunset`
  process, never the session.
- `AGENTS.sandbox.md` (18 lines): a SANDBOXED node in a container on another machine; HOME is not the
  user's desktop; host desktop/terminal/fonts/system are out of reach; host files only where mounted
  (name `findmnt` / `/proc/mounts`); hand desktop tasks to a node that runs on the host, by name from the
  fleet roster; sandbox wins over Omarchy.
- `lua/core/agent.lua`: `M.environment_note(role, opts)` - one function, because the choice and its
  precedence are one answer. Detection is an **allow-list of two named environments**, never a scan for
  `AGENTS.*.md` (a dropped file must not become a detection path). Order: `WASM_AGENT_SANDBOX=1` or
  `/.dockerenv` -> sandbox; else `OMARCHY_PATH` set or `/usr/share/omarchy` **a directory** -> omarchy;
  else nothing. `probe` distinguishes "file", "dir", "missing" and **"unknown"**, and unknown is never
  yes (a permission error selects no note). A guest gets none. Resolution mirrors the role file:
  `WASM_AGENT_AGENTS_MD_<KIND>`, then the working directory, then `<config>`.
- Placement, which cost one iteration: the note goes **after `<config>/AGENTS.md` and before the project
  chain**. Both of those positions are already pinned by tests - "global file comes first"
  (`scripts/test-project-instructions.lua:52`) and "nearest file is last" (:26) - and I first put the note
  first, which broke the former. The documented order ("nearest, most specific last") then still lets a
  project rule contradicting the note win by being read later.
- `scripts/test-environment-notes.lua`: 31 checks, hermetic - every case injects `env` (a table),
  `read` (a reader over a table) and `config_dir` (its own scratch dir under TMPDIR), and refuses to run
  if that dir is this node's real `~/.wasm-agent`. Covers all four detection paths (`WASM_AGENT_SANDBOX`,
  `/.dockerenv`, `OMARCHY_PATH`, `/usr/share/omarchy` as a dir), sandbox-beats-Omarchy in three
  combinations, neither-matches -> no note, unknown -> no note, a plain file at `/usr/share/omarchy` not
  counting, resolution order, a missing note being nil not "", the guest exclusion, the frame placement and
  rendering, and that both files ship with the Omarchy one inside its line budget and pointing at the
  skill.
- `scripts/test.sh`: wired next to `test-project-instructions` (line 1164), same `WA_SCRIPT`/`grep`
  shape. The fast path (`scripts/fast.sh`) does not carry the prompt Lua rows at all today
  (`test-project-instructions` is not there either), so the gate is where it runs.

### 12891c26 - item 2: documentation

- `deploy/env.example`: `WASM_AGENT_SANDBOX=1` documented where the container is composed (compose
  `environment:` or image `ENV`), with the explicit "set it, do not lean on `/.dockerenv`" reason.
- `deploy/README.md`: a "A node in a container (sandbox)" section - what the variable buys and why.
- `ARCHITECTURE.md`: the scope table gains "one environment".
- `docs/LAYERED-PROMPT.md`: `<project>` now names the environment note's position in the frame order.
- `docs/MEMORY.md`: the role-scoping table gains the environment scope and its two overrides.

## Verification (what I ran, and what it said)

Against the installed node binary (`/home/victor/.local/bin/wa`) with this worktree's Lua tree via
`WA_SCRIPT`/`WASM_AGENT_LUA_ROOT`, scratch `WASM_AGENT_HOME` per run:

| test | result |
|---|---|
| `scripts/test-environment-notes.lua` | `environment notes ok (31 checks, 0 skipped)` |
| `scripts/test-project-instructions.lua` | `project instructions ok (9 checks, 0 skipped)` |
| `scripts/test-prompt-tool-names.lua` | `prompt tool names ok (286 checks, 0 skipped)` |
| gating block (master/guest files, guest exclusion) | `gating ok` |
| `bash scripts/sync-prompt-docs.sh --check` | `sync-prompt-docs: ok (4 blocks current)` |
| `luac -p lua/core/agent.lua` | ok |

**Pre-existing failures, confirmed on the base (`origin/main`, separate worktree):**
`scripts/test-prompt-layers.lua` fails at line 5 (`read is native main-loop bootstrap` - its bootstrap
schema expectation no longer matches the catalog) and `scripts/test-evaluation-feedback.lua` at line 6
(`relay boundary preserve original evidence`). Both fail identically on base, so neither is mine.
`scripts/test-prefix-stability.lua` needs `WASM_AGENT_AGENTS_MD` pointed at a scratch file (its own
header says so) and was not run; that is a harness prerequisite, not a result.

**Not verified, and saying so:** the release build of the whole node. `cargo build --release` for this
worktree refused in the `wa-capabilities` build script ("code-mode assets required: set
`WA_CODEMODE_BUILD_ASSETS` ... or `WA_CODEMODE_ALLOW_EMPTY=1`"), so the Lua was exercised through an
existing binary with the tree on disk, not through an artifact built from these commits. No desktop change
was performed (no `~/.config` file touched), so the Omarchy note's advice is sourced from measuring the
installed system's own docs and `hyprctl`, not from applying it.

## Texts to approve (verbatim, model- and operator-facing)

1. `AGENTS.omarchy.md` (new file, 18 lines) - full text:

```markdown
# Omarchy (this node runs on the user's own desktop)

This node runs directly on Omarchy - Arch Linux with Hyprland, foot or alacritty. None of it is true
of a container or a headless host, which is why it is here and not in `AGENTS.md`.

- Use the `omarchy` CLI (`omarchy theme set <name>`, `omarchy font list`, `omarchy screenshot`): it
  dispatches to the `omarchy-*` commands on PATH, which are equally callable.
- Before editing anything under `~/.config/` - `hypr/`, `foot/`, `alacritty/`, `kitty/`, `ghostty/`,
  `waybar/`, `omarchy/` - load the `omarchy` skill. It is found through `~/.agents/skills`, which
  Omarchy symlinks to its own tree, and it carries the per-area guide; this file is not a substitute.
- Never hand-edit `/usr/share/omarchy` or `~/.local/share/omarchy`: the package owns them and
  `omarchy update` overwrites them. Read them freely, and copy into `~/.config/` to change something.
- Hyprland 0.56+ takes dispatchers as Lua: a binding is `o.bind(..., hl.dsp.window.close())` and a
  script is `hyprctl dispatch 'hl.dsp...'`. The pre-0.56 dispatcher words (closewindow, workspace,
  exec) fail with "expected a dispatcher"; that error is the old syntax, not a missing feature.
- Apply and verify with `hyprctl reload` then `hyprctl configerrors`. `hyprsunset.conf` and
  `xdph.conf` are read by other processes, so those restart with `omarchy restart hyprsunset`; never
  restart the session or the compositor to make a config change take.
```

2. `AGENTS.sandbox.md` (new file, 18 lines) - full text:

```markdown
# Sandboxed node (a container on somebody else's machine)

This node is a SANDBOX: it runs in a container and its HOME is that container's, not the user's
desktop. `WASM_AGENT_SANDBOX=1` is set in the container's environment (or `/.dockerenv` exists), and
this file wins over `AGENTS.omarchy.md` when both would apply.

- The host's desktop, window manager, terminal, fonts, themes, night light and system packages are
  outside your reach. A change here is a change to the container: it is lost with it and it is not
  what the user sees. Say so plainly instead of attempting it.
- Host files are reachable only where they are mounted. List the mounts (`findmnt`, or read
  `/proc/mounts`) before claiming a path exists: an unmounted path is not "missing", it is not there.
- For work on the host's desktop - Hyprland, themes, fonts, a terminal profile, a host service - hand
  the task to a node that runs on the host: the fleet roster lists this deployment's nodes and names
  the one on the machine itself. If it lists none, tell the user which task a sandbox cannot do
  rather than half-doing it.
- Do not install system packages, touch the user's dotfiles, or restart a desktop service from here.
- Never present a sandbox result as a host result: what you verified is what you ran here, and the
  answer says which node that was.
```
3. Prompt comment in `docs/LAYERED-PROMPT.md`: "The environment note is `AGENTS.<environment>.md`, for
   what is true of this machine and not of the project: `AGENTS.sandbox.md` when `WASM_AGENT_SANDBOX=1`
   or `/.dockerenv` exists, else `AGENTS.omarchy.md` when `OMARCHY_PATH` is set or `/usr/share/omarchy`
   is a directory (`agent.environment_note`). Sandbox wins when both apply, and neither is injected when
   neither matches."
4. `deploy/env.example`: "This node runs in a container, not on the user's desktop: set it in the
   container's environment ... Set it explicitly rather than relying on /.dockerenv, which some runtimes
   (podman's default, a chroot) do not create."

## Still open

- `AGENTS.windows.md` injection remains unimplemented (unchanged by this branch); its own Status section
  is the accurate description and `ARCHITECTURE.md` now distinguishes "platform" from "environment".
- The two pre-existing failures above are untouched and not fixed here.
- Nothing pushed; both commits are local.
