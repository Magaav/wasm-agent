# change/env-notes - environment notes (`AGENTS.omarchy.md`, `AGENTS.sandbox.md`)

Branch `change/env-notes`, base `origin/main` (ac7717e0). Local commits, not pushed.

## The brief's premise was stale, and I measured it before writing code

The brief: "read how `agent.lua M.agents_md(role)` picks `AGENTS.windows.md`, and reuse that ONE
mechanism (no second loader)." **That mechanism does not exist.** `M.agents_md` picks by *role* only -
`AGENTS.guest.md` for guests, else `AGENTS.md`, then `<config>/AGENTS.md` - and
`rg 'AGENTS.windows' lua/ scripts/ verify/` answers **zero hits** on this branch and on base.
`AGENTS.windows.md` says so itself under "## Status": it was reverted when it broke the gating test.

What I reused is the loader that does exist: the candidate order of `M.agents_md`/`M.role_instructions`
(override -> working directory -> `<config>`) and the frames `M.project_instructions` returns. One
loader, no second prompt section. `AGENTS.windows.md` remains unimplemented and unchanged.

## Commits

| commit | item |
|---|---|
| `85048da8` | item 1: the two notes, `M.environment_note`, hermetic test, gate wiring |
| `12891c26` | item 2: `WASM_AGENT_SANDBOX` in `deploy/env.example`/`deploy/README.md`; scope in ARCHITECTURE, LAYERED-PROMPT, MEMORY |
| `2e315203` | item 3: this report (first version) |
| `70ab6cb2` | r1 MUST 1: delivery - embed, stage, dev-sync pack, `EMBEDDED` runtime fallback |
| `ea17f6b9` | r1 MUST 2: an empty read is a file (docker's 0-byte `/.dockerenv`) |
| `5e97d0d5` | r1 SHOULD: titles, podman marker, roster clause, xdph wording |
| `bb73e1ee` | r1 MUST 3: this report, and LAYERED-PROMPT naming podman's marker |
| `232f3e6d` | r2 item 1: the test asserts the binary embeds both notes; nowhere-on-disk is strict |
| `a439eff9` | r2 item 2: this table names every commit, and the 48-check run |
| `393b5108` | r2 follow-up: the land-signing fixture creates both notes, so the record stops exiting 5 |
| `864810f3` | r2 item 2 (cont.): the report's commit table names `a439eff9` and `393b5108` |
| `c7a8d5a9` | r2 item 2 fix: the table had carried a hash an amend invalidated |
| `a16249af` | r2: the fast-path run and the two rows it caught are recorded |
| the commit that last edits this table | a commit cannot contain its own hash; `git log --oneline` names it, and every earlier commit on the branch is listed above |

## Review r1 items, and what each fix does

**MUST 1 - the notes never reached a deployed node.** Confirmed: `rust/wa-host/build.rs:22` embedded only
`AGENTS.orchestrator.md` and `AGENTS.subagents.md`, `scripts/lib/lua-tree.sh:30` staged only those two, and
no installer seeds `<config>`. Fixed in three places, because a note reaches a node by any of them:

- `rust/wa-host/build.rs` embeds both notes, so a binary carries them (the same path the role files use).
- `scripts/lib/lua-tree.sh` stages both, so a Lua-only deploy ships them in `lua-core/`; `scripts/test.sh`
  now asks `wa_lua_tree_files` itself (not a copy of its list) whether both are in that set.
- `scripts/dev-sync.sh` packs both for a dev node.
- `agent.environment_note` falls back to `EMBEDDED[name]` when neither the working directory nor
  `<config>` has the file, and reports the path as `embedded:AGENTS.<kind>.md`.

**Proven with a real binary, not inferred.** `cargo build --release` for this worktree succeeded with
`WA_CODEMODE_ALLOW_EMPTY=1` (a gate build; the prepared asset directory in the canonical checkout is
incomplete - `quickjs.wasm` is missing - so `WA_CODEMODE_BUILD_ASSETS` refuses). Run from `/tmp`, where no
note exists on disk, with a scratch home:

```
cwd	/tmp
embedded_omarchy	true
embedded_sandbox	true
note	embedded:AGENTS.omarchy.md
1	embedded:AGENTS.omarchy.md	1604
```

That is the delivery the review said was missing: the note arrives from the binary, in a directory that
has none of it.

**MUST 2 - the `/.dockerenv` fallback was dead.** Confirmed: `read_text_file` returns `Ok("")` for a 0-byte
file, my probe treated `text == ""` as "unknown", and docker creates `/.dockerenv` empty. `probe` now
answers "file" for any non-nil read (`if text ~= nil`), and the test's fixture is `""` as docker actually
writes it - the old fixture used `"x"`, which is exactly why the bug was invisible. Podman writes
`/run/.containerenv` instead, so that is a second probe; both are accepted, and the test covers each and
their absence.

**MUST 3 - report.** This file. The commit count above is complete, and the verification section covers
delivery to a node.

**SHOULD, all three texts.**

- Sandbox title is now "# Sandboxed node (inside a container, not on the host desktop)" - the work
  container is on Victor's own machine, so "somebody else's machine" was wrong.
- The fleet-roster clause is **dropped, not proven**: `tools.nodes()` on this node returns
  `name`, `role`, `capabilities`, `online`, binding fields - no field says which machine a node sits on.
  The note now says the roster gives names, roles and capabilities, not placement, and asks the user
  which node runs on the host. The test asserts the clause is absent.
- The `xdph.conf` line no longer claims `omarchy restart hyprsunset` restarts it: `hyprsunset.conf`
  applies on `omarchy restart hyprsunset`, and `xdph.conf` only when the screen-sharing portal restarts
  (next login). The same line was wrong in the other direction too and is now split.
- The sandbox note names both markers only because the detector now accepts both (MUST 2).

## Verification (what I ran, and what it said)

Real binary built from these commits (`/home/victor/wasm-agent/target/m-env-notes/release/wa`) and the
installed one with this worktree's tree, scratch `WASM_AGENT_HOME` per run:

| check | result |
|---|---|
| `scripts/test-environment-notes.lua` (45 checks at r1) | `environment notes ok (45 checks, 0 skipped)` |
| `scripts/test-environment-notes.lua` (48 checks after r2 item 1, run against the worktree's own binary) | `environment notes ok (48 checks, 0 skipped)` |
| `scripts/test-project-instructions.lua` | `project instructions ok (9 checks, 0 skipped)` |
| `scripts/test-prompt-tool-names.lua` | `prompt tool names ok (286 checks, 0 skipped)` |
| `bash scripts/sync-prompt-docs.sh --check` | `sync-prompt-docs: ok (4 blocks current)` |
| `scripts/fast.sh`, narrowed to these rows (`WA_FAST_ROWS`, 5 of 250 Lua rows) | `fast path ok (52 checks, 0 skipped, 184s)`, rc 0 - `pass` for `environment-notes`, `project-instructions`, `prompt-tool-names`, `land-signing`, `build-info` |
| `scripts/test-build-info.sh`, binary re-stamped at `79fbc2a2` | `test-build-info: 24 checks, 0 failed` |
| `scripts/test-land-signing.sh` | `land signing ok (46 checks)` |
| `cargo build --release` (`WA_CODEMODE_ALLOW_EMPTY=1`) | `Finished release profile`, rc 0 |
| embedded delivery from `/tmp` | `note embedded:AGENTS.omarchy.md`, both keys present |
| `wa_lua_tree_files` includes both notes | yes (staged set printed) |
| `luac -p lua/core/agent.lua` | ok |

**Pre-existing failures, confirmed on base in a separate worktree:** `scripts/test-prompt-layers.lua:5`
(`read is native main-loop bootstrap`) and `scripts/test-evaluation-feedback.lua:6` (`relay boundary
preserve original evidence`). Neither is mine.

**What the fast path caught, and why it is in this branch.** The first narrowed run (before the fixture fix)
failed two rows, neither in a Lua file this mission edited:

- `land-signing` - `the Lua tree record is written: expected status 0, got 5`. That one *was* mine:
  `scripts/lib/lua-tree.sh` now lists the two notes, and the land-signing fixture created only
  `AGENTS.orchestrator.md`/`AGENTS.subagents.md`, so the record step refused a shipped path that was
  missing. Fixed by creating both notes in the fixture (`393b5108`), which is the fixture mirroring the
  tree it exists to describe.
- `build-info` - `commit is this checkout's HEAD`. Not a code failure: the binary had been built before
  the later commits, and this row compares the binary's recorded commit with HEAD. Rebuilt at the tip;
  `24 checks, 0 failed`.

Both are why the fast path was run rather than only the Lua test: the Lua test passed on a binary that
`build-info` would have refused, and the staging change broke a row that never mentions this feature.

**A pre-existing bug this run exposed, not fixed here.** `rust/wa-host/build.rs` re-runs on
`.git/HEAD`, `.git/index` and the ref file under `<root>/.git/`. In a **worktree** `.git` is a *file*
(`gitdir: /home/victor/wasm-agent/checkout/.git/worktrees/wt34`), so those paths do not exist, cargo
never re-runs the script, and a rebuilt binary kept reporting `c7a8d5a9` after HEAD had moved - which made
`build-info` fail on a correct tree. It is not this mission's to change; I worked around it by touching
`rust/wa-host/build.rs` (mtime only, tree stayed clean) and the identity re-stamped to `79fbc2a2`. Worth
a separate fix: resolve the real git dir (or read `git rev-parse --git-path HEAD`) instead of assuming
`.git/` is a directory. The consequence for this table: `build-info` passes on the binary re-stamped at
`79fbc2a2`, and any commit after it - including this report's own - moves HEAD past that binary. That is
the bug, not a result, so the row is claimed at `79fbc2a2` and nowhere later.

**One run failed for an environment reason, said plainly.** An early attempt printed `lua error: disk I/O
error`; `/tmp` was at 80% (13G of 16G, held by other missions' scratch, which I did not delete). Re-run
after clearing only my own scratch: `environment notes ok (48 checks, 0 skipped)`. The remaining `/tmp`
pressure is not mine to reclaim.

**Not verified:** no desktop file was touched, so the Omarchy note's advice is sourced from the installed
system's own skill and `hyprctl` (0.56.2), not from applying it; and `test-prefix-stability.lua` needs
`WASM_AGENT_AGENTS_MD` pointed at a scratch file (its own header says so), so it was not run.

## Texts to approve (verbatim, model- and operator-facing)

1. `AGENTS.omarchy.md` (new file, 19 lines):

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
- Apply and verify with `hyprctl reload` then `hyprctl configerrors`. The two `.conf` files are read
  by other processes, so `hyprctl` neither applies nor validates them: `hyprsunset.conf` takes effect
  on `omarchy restart hyprsunset`, and `xdph.conf` only when the screen-sharing portal restarts (at
  the next login). Never restart the session or the compositor to make a config change take.
```

2. `AGENTS.sandbox.md` (new file, 19 lines):

```markdown
# Sandboxed node (inside a container, not on the host desktop)

This node is a SANDBOX: it runs in a container and its HOME is that container's, not the user's
desktop. `WASM_AGENT_SANDBOX=1` is set in the container's environment (or the container's own marker,
`/.dockerenv` or `/run/.containerenv`, exists), and this file wins over `AGENTS.omarchy.md` when both
would apply.

- The host's desktop, window manager, terminal, fonts, themes, night light and system packages are
  outside your reach. A change here is a change to the container: it is lost with it and it is not
  what the user sees. Say so plainly instead of attempting it.
- Host files are reachable only where they are mounted. List the mounts (`findmnt`, or read
  `/proc/mounts`) before claiming a path exists: an unmounted path is not "missing", it is not there.
- For work on the host's desktop - Hyprland, themes, fonts, a terminal profile, a host service - say
  that a sandbox cannot do it and ask which node runs on the host (the fleet roster gives names, roles
  and capabilities, not which machine a node sits on). Hand it there if the user names one; never
  present a container change as a host change.
- Do not install system packages, touch the user's dotfiles, or restart a desktop service from here.
- Never present a sandbox result as a host result: what you verified is what you ran here, and the
  answer says which node that was.
```

3. `docs/LAYERED-PROMPT.md`, the `<project>` paragraph (corrected with MUST 2, since it named only
   `/.dockerenv` while the detector also accepts podman's marker): "The environment note is
   `AGENTS.<environment>.md`, for what is true of this machine and not of the project:
   `AGENTS.sandbox.md` when `WASM_AGENT_SANDBOX=1` or a container marker exists (`/.dockerenv`,
   docker's, or `/run/.containerenv`, podman's), else `AGENTS.omarchy.md` when `OMARCHY_PATH` is set or
   `/usr/share/omarchy` is a directory (`agent.environment_note`). Sandbox wins when both apply..."

4. `deploy/env.example`: "This node runs in a container, not on the user's desktop: set it in the
   container's environment ... Set it explicitly rather than relying on /.dockerenv, which some runtimes
   (podman's default, a chroot) do not create."

## Still open

- `AGENTS.windows.md` injection is still unimplemented (unchanged by this branch).
- The two pre-existing test failures are untouched.
- Nothing pushed.
