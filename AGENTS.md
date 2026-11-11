# AGENTS.md — working on wasm-agent

Rules for any agent (or human) changing this repo. This file is injected into every request
made from this checkout, so it stays short; detail lives in `docs/` and loads on demand.

## How work lands

Answer with the verified artifact or a measured impossibility — a plan, an obstacle or a question is not an answer.

The default is the operator-selected direct workflow (`AGENTS.orchestrator.md`): implement, self-review,
run `bash scripts/fast.sh`, integrate through canonical main, push and read back `origin/main`, leave both
trees clean. No subagents or external inference agents unless the operator explicitly enables
`/orchestration` (`docs/ORCHESTRATION-MODE.md`). Only the coordinator owns `/update`, UI publication and
Sentinel.

- Work on a short-lived `change/<name>` branch cut from `origin/main`; `git pull` before
  editing. Keep the `Agent:` trailer and prove `git merge-tree --write-tree origin/main HEAD`.
- **Land through the queue**, one lander at a time and in order:
  `node scripts/landing-queue.mjs land --branch change/<name> --checks "bash scripts/fast.sh"`. It refuses
  a dirty canonical tree nobody owns, retests only what the move changed, judges the result against what
  main already FAILS (never against zero), and publishes BOTH Linux binaries for the landed commit.
  `status` prints the queue and the previous landing's release verdict per target; an uncovered landed
  commit is a named `WARNING release_uncovered` row. Procedure: `skills/git-orchestrator/SKILL.md`;
  commands and state: `docs/LANDING-QUEUE.md`; baseline: `landing-queue.mjs baseline`.
- Use ordinary Git integration. Self-review is allowed;
  self-review must be labelled self-review, never independent review.
  Do not fabricate a factory receipt or disable remote protection; remote protection is the
  boundary that cannot be skipped, hooks are a convenience.
- **Day to day: the fast path.** `bash scripts/fast.sh` (minutes) must pass before you integrate;
  report what it SKIPPED. The full gate (`scripts/test.sh`) is nightly and for releases, never a landing
  gate. Test-component contract, what a SKIP means, and a new test's home: `skills/fast-path/SKILL.md`.
- **Cleanup**: back up dirty drafts, rejected code and evidence before retiring verified obsolete
  work. Unknown effects remain unresolved: never manufacture settlement or replay them. Report
  Git cleanup and runtime readiness separately.

Topology: one repository whose source of truth is `github.com/Magaav/wasm-agent` (`origin`, SSH alias
`github-wasm-agent`), checked out once per host and per lane; the cloud
(`openclaw.ohana:/local/projects/wasm-agent`) builds and hosts the rendezvous and relay, the canonical
checkout `orca/projects/wasm-agent` owns `main`, and each lane (`orca/workspaces/wasm-agent/<name>`) is a
linked worktree on its own branch that owns its tree. Lanes, the merge lane and The integration protocol:
`skills/git-orchestrator/SKILL.md`; layers and names (node-thread, subagent, run): `docs/FABRIC.md`.

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
- **Install through Sentinel; never replace yourself in-turn.** Queue `wa-sentinel request upgrade`
  (node/UI) or `request deploy` (Sentinel) with a session continuation. Restore a stopped watcher via the checked node-side `-RestoreOnly` task path,
  even with a bound workspace. Never strip run markers, elevate, hand-copy binaries or treat watcher
  readiness as a verified install (`skills/self-update/SKILL.md`).
- **Never restart or replace the window.** It is a client and reloads itself; a dead-looking
  window is a page problem (`skills/self-update/SKILL.md`). You cannot restart the node you
  run on: ask the Sentinel. Stop a node by the pid in `serve.pid`, never by image name.
- **Never hand a POSIX path to a native Windows process.** Convert `/c/...` with `cygpath -w`.
- **More than one node-thread is normal.** `/health` lists them with `role: "runs"`/`"reads"`.
- **Skills carry procedures, not context** (`docs/SKILLS.md`): the trigger goes in the description. A
  spell is deterministic, verified execution with a mandatory `post` (`docs/SPELLS.md`; load `spells`
  first).
- **Graph checks impact; it does not replace reading source** (`docs/GRAPH-PATCH-AUDIT.md`).
- **UI changes need the UI test** (`scripts/test-ui.ps1`, `skills/see-your-output/SKILL.md`).
- **Memory is on demand.** The only automatic injections are these instruction files, scoped by
  role; guests get `AGENTS.guest.md` and never this file.
- **Failures are visible**: no silent success, no silent data loss.
- **A long mission is the model's loop** (`docs/SELF-LOOP.md`): notes_write the goal and its
  done-criteria, wake yourself (an event before fast polling, a `probe` so an unchanged world spends no
  turn), re-read the notes on each `[self-wake]`, write a repeated failure down as a rule, and cancel the
  wake when the goal is done.
- **Raw over compacted**, unless evidence shows the task result does not degrade; a token
  saving alone never justifies making the model less aware.
- **Know how you are risking.** Name the risk in the patch; prefer a knob plus its measurement
  over a default picked from a weak experiment, and say when a measurement cannot settle it.
- **Verify before claiming**: run the smoke test; prefer a real two-node check.
- **A Lua test needs a Lua root** (`WASM_AGENT_LUA_ROOT`); without one it runs the binary's embedded
  modules, not `lua/` (`skills/fast-path/SKILL.md`).
- **A skipped test is reported as skipped**, never with the sentence of a run that tested it.

## Reports

Add a `harness evaluation` block only when a harness or tool limitation actually hurt reasoning
or added steps: what hurt, the proposed fix, and the step delta (`5 → 2`). Otherwise omit it.
