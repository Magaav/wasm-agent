# AGENTS.md — working on wasm-agent

Rules for any agent (or human) changing this repo. This file is injected into every request
made from this checkout, so it stays short; detail lives in `docs/` and loads on demand.

## How work lands

Answer with the verified artifact or a measured impossibility — a plan, an obstacle or a question is not an answer.

The default is the operator-selected direct workflow (`AGENTS.orchestrator.md`): implement,
self-review, run the fast path (`bash scripts/fast.sh`), integrate through canonical main, push and read back
`origin/main`, and leave both trees clean.
Do not start subagents or external inference agents unless the operator explicitly enables
`/orchestration` (`docs/ORCHESTRATION-MODE.md`). Only the coordinator owns `/update`, UI
publication and Sentinel.

- Work on a short-lived `change/<name>` branch cut from `origin/main`; `git pull` before
  editing. Keep the `Agent:` trailer and prove `git merge-tree --write-tree origin/main HEAD`.
- Use ordinary Git integration. Self-review is allowed;
  self-review must be labelled self-review, never independent review.
  Do not fabricate a factory receipt or disable remote protection; remote protection is the
  boundary that cannot be skipped, hooks are a convenience.
- **Day to day: the fast path.** `bash scripts/fast.sh` (minutes) must pass before you integrate;
  report what it SKIPPED. It runs every self-contained `scripts/test-*.lua`, the Rust unit tests of
  the crates you touched and the contract checks. A new Lua test belongs in it: make it
  self-contained, don't add it to `scripts/fast-path.exclude`.
- **The full gate is nightly, and for releases.** `scripts/test.sh` (via `scripts/wave-release.mjs`,
  ~50 min) runs as the nightly job and when a human asks for a release. Never gate a landing or wait
  for it before merging; landings report `gate_verified:false` and `release_verified:false`
  (`lane-policy.json`).
- Cleanup: back up dirty drafts, rejected code and evidence before retiring verified obsolete
  work. Unknown effects remain unresolved: never manufacture settlement or replay them. Report
  Git cleanup and runtime readiness separately.

Topology: every tree is a linked worktree of one repo whose source of truth is
`github.com/Magaav/wasm-agent` (`origin`, SSH alias `github-wasm-agent`). The cloud
(`openclaw.ohana:/local/projects/wasm-agent`) builds and hosts the rendezvous and relay; the
canonical checkout `orca/projects/wasm-agent` is on `main`; the node's own worktree and each
lane (`orca/workspaces/wasm-agent/<name>`) are on a branch of that name. A lane owns its tree.
Lanes, the merge lane and The integration protocol: `skills/git-orchestrator/SKILL.md`;
layers and names (node-thread, subagent, run): `docs/FABRIC.md`.

## Rules

- **Never touch the old plugin.** The v8 plugin is reference only.
- **Keep LF.** `core.autocrlf=false`; the `pre-commit` hook is the contract. Hooks are armed by
  `bash scripts/setup-hooks.sh` (deploy runs it); run it once in a fresh clone.
- **Read before changing behaviour.** Read the relevant section of `docs/` and follow its
  cross-references; `DESIGN.md` before UI work; `docs/MEMORY.md` before memory or sessions.
- **The host is capabilities, not logic.** Agent logic is Lua; platform capabilities are Rust
  `host.*` (`docs/HOST.md`): return `nil` for missing values, take paths from `host.paths()`.
  The Cargo manifest is `rust/Cargo.toml` (pass `--manifest-path` or run from `rust/`).
- **Prompt docs are generated.** After changing the tool catalogue, bootstrap set or prompt
  layers, run `scripts/sync-prompt-docs.lua`; the pre-commit hook refuses stale blocks.
- **Install through Sentinel; never replace yourself in-turn.** Queue
  `wa-sentinel request upgrade` (node/UI) or `request deploy` (Sentinel) with a session
  continuation. Restore a stopped watcher via the checked node-side `-RestoreOnly` task path,
  even with a bound workspace. Never strip run markers, elevate, hand-copy binaries or treat
  watcher readiness as a verified install. Procedure: `skills/self-update/SKILL.md`.
- **Never restart or replace the window.** It is a client and reloads itself; a dead-looking
  window is a page problem (`skills/self-update/SKILL.md`). You cannot restart the node you
  run on: ask the Sentinel. Stop a node by the pid in `serve.pid`, never by image name.
- **Never hand a POSIX path to a native Windows process.** Convert `/c/...` with `cygpath -w`.
- **More than one node-thread is normal.** `/health` lists them with `role: "runs"`/`"reads"`.
- **Skills carry procedures, not context** (`docs/SKILLS.md`): write the trigger into the
  description. A spell is deterministic, verified execution with a mandatory `post`
  (`docs/SPELLS.md`); load the `spells` skill before saving or repairing one.
- **Graph checks impact; it does not replace reading source** (`docs/GRAPH-PATCH-AUDIT.md`).
- **UI changes need the UI test** (`scripts/test-ui.ps1`, `skills/see-your-output/SKILL.md`).
- **Memory is on demand.** The only automatic injections are these instruction files, scoped by
  role; guests get `AGENTS.guest.md` and never this file.
- **Failures are visible**: no silent success, no silent data loss.
- **A long mission is the model's loop** (`docs/SELF-LOOP.md`): the tools are optional, not a schema.
  Write the goal and done-criteria with `notes_write`; schedule your own next turn with `wake`, event
  wakes before fast polling; attach a `probe` so an unchanged world does not spend a turn; re-read the
  notes on each `[self-wake]`; turn repeated failures into written rules; notify only on events; and
  cancel the wake when the goal is done.
- **Raw over compacted**, unless evidence shows the task result does not degrade; a token
  saving alone never justifies making the model less aware.
- **Know how you are risking.** Name the risk in the patch; prefer a knob plus its measurement
  over a default picked from a weak experiment, and say when a measurement cannot settle it.
- **Verify before claiming**: run the smoke test; prefer a real two-node check.
- **A Lua test has only tested the tree when a Lua root is in use.** Without
  `WASM_AGENT_LUA_ROOT`, `WA_SCRIPT` runs the modules embedded in the binary, not `lua/`.
- **A skipped test is reported as skipped**, never with the sentence of a run that tested it.

## Reports

Add a `harness evaluation` block only when a harness or tool limitation actually hurt reasoning
or added steps: what hurt, the proposed fix, and the step delta (`5 → 2`). Otherwise omit it.
