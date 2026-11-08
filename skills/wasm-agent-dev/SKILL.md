---
name: wasm-agent-dev
description: >-
  How to change wasm-agent itself and prove the change: which edits need no rebuild (Lua, UI, docs,
  skills, scripts) and how to run the tree's tests against the installed binary, when a Rust change
  needs a build and where that build is allowed to run, the fast path and what it skips, which test
  covers which area, and how to hand back a diff and a commit. Use it before the first test, build or
  commit of any change to this repository.
---

# Changing wasm-agent

Two kinds of change live here, and they are not the same job: the Lua/UI tree is *loaded from disk*,
the Rust tree is *compiled into the binary*. Getting that wrong is how a one-line UI request spent 248
steps and 40 minutes rebuilding the whole workspace inside a 2-core container (08/11).

## 1. Decide what you are changing before you run anything

`scripts/lib/node-binaries.sh`'s `wa_compiled_input` is the one definition of "compiled":

| change | rebuild? |
| --- | --- |
| `lua/`, `ui/`, `docs/`, `tests/`, `skills/`, `scripts/` (`codemode*`, `build-*`, `provision-codemode*` excepted), `jobs/`, `benchmarks/`, `fixtures/`, `vault/` | no |
| `rust/`, `wit/`, `Cargo.toml`/`Cargo.lock`, `config/`, the codemode build scripts | yes |

A deploy of a no-rebuild change is the **Lua fast path**: the installed binary keeps running and reads
the new tree (`scripts/deploy.sh`, `docs/EVOLUTION.md`). So a Lua change is never a reason to build.

## 2. Lua and UI: run the tree with the installed `wa`

**A test only tested the tree when a Lua root is in use.** Without `WASM_AGENT_LUA_ROOT`, `WA_SCRIPT`
runs the modules embedded in the binary, and a green result proves nothing about your edit.

```bash
# from the checkout root, one test, hermetic (never the real node home)
H=$(mktemp -d)
WASM_AGENT_LUA_ROOT="$(pwd)" WASM_AGENT_HOME="$H" \
WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
  WA_SCRIPT=scripts/test-cli-view.lua wa --db "$H/t.db"
```

The last line prints `… ok (N checks)` or `N failed of M`; exit status is 1 on failure. `bash
scripts/fast.sh` does exactly this for every test at once. On Windows `scripts\dev-agent.cmd` and
`cygpath -w` are the equivalents for an interactive run (`WASM_AGENT_HOME` must be a native path).

**Never** start a node against the real home, and never point a test at `~/.wasm-agent`: a smoke test
that joins the rendezvous is a node, and it took this project's own node offline once.

## 3. Rust: never compile on a weak node, and never background the build

A cold `cargo test` of this workspace is ~600 crates: 15 minutes on two cores, and it will not finish
inside a tool bound. So:

- **Do not build on a 2-core node or in a container without a toolchain.** Verify Lua with the
  installed `wa` first; if the change is Rust, hand the patch back (section 6) instead of fighting it.
- **A build is a supervised operation, not a background job.** `operation start` with the cargo
  command, then `operation read`/`operation await`/`operation cancel`. A `cargo build &` inside `bash`
  is killed when that call returns, so the build dies with it and the next call polls a log that will
  never finish. One `cargo test -p <crate>` for the crate you touched, `--offline` first, is the
  cheapest real check; `--all` / a workspace rebuild is not.
- Where a build host exists, the same command runs as an `operation` **on the build node** (the
  compute fabric's `build` job kind is the planned home for it, not available yet). `docs/COMPONENTS.md`
  and `docs/HOST.md` describe the crates and the host boundary.

## 4. Which test for which area

| you changed | run |
| --- | --- |
| a `lua/core/<name>.lua` | `scripts/test-<name or feature>.lua` (`cli-view`, `selfloop`, `memory-window`, `provider-*`, `session-*`, …) |
| prompt sections, guidance, tool list | `scripts/test-prompt-tool-names.lua`, `test-tool-cues.lua`, then `bash scripts/sync-prompt-docs.sh` (the pre-commit hook refuses stale generated blocks) |
| skills | `scripts/test-skill-content.lua`, `test-skill-discovery.lua` |
| `ui/` | `node tests/<name>.js`, plus `scripts/test-ui.ps1` for a real window (`skills/see-your-output`) |
| `rust/wa-capabilities` (`host.*`) | `cargo test -p wa-capabilities` (from `rust/`) |
| `rust/wa-term` (CLI screen) | `cargo test -p wa-term` |
| a component under `rust/components/` | `cargo test` in that crate, `bash scripts/build-components.sh` for the wasm |
| operations, jobs | `scripts/test-operation-reconcile-json.lua`, `docs/OPERATIONS.md` |

`bash scripts/fast.sh` is the day-to-day check (minutes): every self-contained `scripts/test-*.lua`,
the Rust unit tests of the crates you touched, and the contract checks. It prints what it SKIPPED —
report that as skipped, never as passed. Tests that need the gate's setup are named in
`scripts/fast-path.exclude`; a new test belongs in the fast path, so keep it self-contained. The full
gate (`scripts/test.sh`) is nightly and release-only: never gate a landing on it.

**Cheapest check first.** One failing test that names your change beats a suite that takes an hour,
and "the suite passed" is not evidence that your feature works.

## 5. Keep the diff one area and keep the trees clean

- Branch `change/<name>` cut from `origin/main`; one area per branch (a Lua fix does not carry a Rust
  build with it).
- LF only (`core.autocrlf=false`); `pre-commit` is the contract (`bash scripts/setup-hooks.sh` once).
- Do not edit what another stream owns: `rust/wa-host`, `rust/components`, `wit/kernel`,
  `scripts/deploy.sh`. A fix there is a hand-off, not a patch.
- Never restart the node you are running on, never replace the window, never push or open a PR from a
  task that was not asked to (`skills/self-update`, `skills/git-orchestrator`).

## 6. Handing back a diff

When the work needs a machine you are not on, or a reviewer, hand back a patch rather than a story:

```bash
git diff origin/main -- <paths> > /tmp/change.patch   # the change alone, no build output
git log -1 --format='%h %s%n%b'                      # the commit your patch was made on
```

State, in order: what changed and where, the branch and commit, the exact tests you ran with their
result lines, what you SKIPPED and why, and what the patch still needs (a rebuild, a deploy, a
review). Commit with the `Agent:` trailer the repository uses, plus the identity line the task asked
for:

```
<area>: <one line, imperative, why it matters>

<what changed and what proves it: the commands and their result lines>

Agent: <harness> <model> on <node>
```

An unverified claim is worse than a hand-off: say `gate_verified:false` and
`release_verified:false` and let the integrator run what you could not.
