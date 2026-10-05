## Operator-selected direct workflow (2026-10-05)

The operator has disabled delegation for this repository. Work directly and serially
on each human-requested task: implement, self-review, run appropriate focused checks,
merge in the canonical main checkout, push and read back origin/main, and leave the
owned and canonical worktrees clean. Do not start subagents or external inference agents.
Do not create new orchestration, watchers or gates to complete ordinary work. Full
release gates run only when the human explicitly requests them.

The coordinator may review and merge its own changes; an independent reviewer is
not required in this mode. This operator-selected rule overrides conflicting
independent-review, mandatory-delegation and parallel-lane procedures in this file,
AGENTS.orchestrator.md and repository skills/docs. Existing evidence remains evidence;
self-review must be labelled self-review, never independent review. For direct work,
use ordinary Git integration rather than a factory admission route that requires an
independent reviewer. Do not fabricate a factory receipt or disable remote protection.

For the authorized backlog cleanup, preserve recoverable backups of dirty drafts,
rejected code and historical evidence before retiring verified obsolete work. Use
supported runtime recovery for ownership/binding release. Unknown effects remain
explicitly unresolved: do not manufacture settlement or replay them. Report Git
cleanup and runtime readiness separately; an unresolved historical record does not
prevent completing unrelated requested code changes. If a runtime boundary refuses
cleanup, report its exact remaining scope and complete the other authorized work.

This direct workflow remains active until the operator explicitly changes it.

# AGENTS.md — working on wasm-agent

Instructions for any agent (or human) editing this repo. This file is injected
into wasm-agent's own context at runtime, so keep it short and operational.

## One repo, a primary checkout and linked worktrees

| Tree | Path | Role |
| --- | --- | --- |
| Cloud (authoritative runtime) | `openclaw.ohana:/local/projects/wasm-agent` | builds, runs, hosts the rendezvous + relay |
| Canonical checkout | `orca/projects/wasm-agent` | the primary worktree, on `main` - the merge lane's sanctioned tree |
| The node | `orca/workspaces/wasm-agent/wasm_the_first` | the node's own worktree, on the branch that carries its name (`wasm_the_first`) |
| Agent lanes | `orca/workspaces/wasm-agent/<name>` | `astra`, `codex`, `generalson` - each an actor's own worktree on a branch of the same name |

Every row above is a **linked worktree of one repo**, whose git dir is
`orca/projects/wasm-agent/.git`; all push to `github.com/Magaav/wasm-agent` (`origin`), which is
the source of truth. Before editing: `git pull`; after: commit, push, then pull on the other
side. Auth is the `github-wasm-agent` SSH host alias. Work happens on a short-lived
`change/<name>` branch cut from `origin/main` and merged when done; the node's own branch is its
name.

**A lane owns its tree; only the merge lane moves `main`.** Direct work uses the
operator-selected workflow above. The historical parallel procedure is in
`skills/git-orchestrator/SKILL.md` ("The integration protocol"), subject to that
override; `docs/CONCURRENCY.md` owns lane reservations. Hooks are convenience;
remote protection is the boundary that cannot be skipped.

### The per-turn loop

Before editing code, load `parallel-evolution`, sync with `origin/main`, keep the
patch scoped, self-review and run focused checks. Preserve the `Agent:` trailer
and prove `git merge-tree --write-tree origin/main HEAD`. Integrate through the
canonical main checkout and verify the remote ref; leave both trees clean.
Only the user selects full pre-release gating. Routine work reports
`gate_verified:false` and `release_verified:false` (`lane-policy.json`).

### Never touch the old plugin

The v8 plugin is reference only. Read it; never modify it.

### Keep LF

These files are consumed by Linux and by `sh`/`lua`; `core.autocrlf=false` stores bytes as they are.
The `pre-commit` hook enforces it - that hook is the contract, this line is the pointer.

## Conventions

- **The host is capabilities, not logic.** Agent logic is Lua; platform capabilities
  are Rust `host.*`. Read `docs/HOST.md` before adding a capability: a host function
  returns `nil` for missing values (never zero values), and paths come from
  `host.paths()`, never `$HOME` or a Linux-only path.
- **The Rust workspace manifest is `rust/Cargo.toml`; the repo root has none.** Pass
  `--manifest-path rust/Cargo.toml` to Cargo, or run it from `rust/`.
- **Use the graph to check impact, not to replace source inspection.** Use grep/read
  for navigation. The opt-in patch audit (`WA_GRAPH_PATCH_AUDIT=1`) prompts before
  a standard `git commit` for unread resolved callers. It is a review lead, not a
  correctness certificate; see `docs/GRAPH-PATCH-AUDIT.md`.
- **A spell is deterministic, verified execution**, not a "macro". A step is a shell
  command or script, a client action, a wait, an assertion, or a supervisor verb, and
  every spell declares a `post` that settles the effect. The model surface is
  `spell_save`/`spell_run`; the contract is `docs/SPELLS.md`. A spell chooses *which*
  step, never *how* it runs.
- **Install only through the gate, and never run it from inside a run.** `scripts/deploy.sh` cannot
  become idle while the turn that asked waits, so from inside a run you *queue* it:
  `wa-sentinel request upgrade` for the node and UI, `wa-sentinel request deploy` when the change is in
  the sentinel itself, each with `--session`/`--prompt` to be woken after. Its refusals and the sentinel
  path are in `skills/self-update/SKILL.md`; never copy a binary over a running one by hand.
- **Never hand a POSIX path to a native Windows process.** `/c/...` is unusable as an
  argument: the node starts, cannot read `index.html`, and answers 404 for `/` while
  looking healthy. Convert it (`cygpath -w`).
- **Never restart or replace the window.** It is a client and reloads on its own; a window that
  looks dead is a *page* problem, and the node can say why. The diagnostics are in
  `skills/self-update/SKILL.md`.
- **More than one node-thread is normal.** Read node-threads spawn on demand and retire once
  idle; runs route by session. `/health` lists them by `role: "runs"` or `"reads"` (the
  `workers[]` field is that array's pre-rename name), so "who is busy with what" is a field, not a
  guess. The layers and their real names are `docs/FABRIC.md` ("Topology").
- **Skills carry procedures, not context.** A technique the agent should not
  have to be told twice belongs in `skills/<name>/SKILL.md` (the Agent Skills
  standard, shared with pi and Orca). Only the description is always in
  context; the body loads when a task matches. Write the *trigger* into the
  description. See `docs/SKILLS.md`.
- **Evolve skills while using them:** crystallize deterministic sequences into verified spells,
  compose repeatable adjacent spells, and refactor the skill to use them. Failure diagnosis,
  repair/retirement decisions and effect reconciliation default to inference; see `docs/SKILLS.md`.
- **UI changes need the UI test, not an opinion.** Run `scripts/test-ui.ps1` before claiming a UI
  change works; the UI is not observable through `bash`, `grep` or `read`. The technique and the
  headless harness are in `skills/see-your-output/SKILL.md`.
- Read `DESIGN.md` before UI work (spacing scale, balloons, modes) and
  `docs/` before changing memory, sessions, sync or the node fabric.
- Memory is **on demand**: never inject memory into context automatically;
  the instruction file is the only automatic injection, and it is **scoped by
  role** — operators get `AGENTS.md`, guests get `AGENTS.guest.md` and never
  fall back to the operator file (`docs/MEMORY.md`).
- Failures must be **visible**: no silent success, no silent data loss. Surface
  the error and the step. `docs/MEMORY.md` explains the tracing model.
- **Raw over compacted, unless the loss is proven harmless.** Context is the agent's
  awareness, so a step that is cheaper and makes the model less aware is a bad trade even
  when the tokens fall. Compaction, truncation, elision and "summarise it instead" are
  justified by evidence that the *task result* does not degrade - never by a token saving
  alone - and the provider getting cheaper is the trend to bet on. Models are getting
  cheaper faster than a smaller context saves.
- **Know how you are risking.** Taking risks is how breakthroughs happen, so take them -
  but name the risk in the patch, and prefer a knob plus the measurement that justifies
  using it over a new default chosen from a small experiment. A risky change that does not
  say what it is risking is one nobody can revisit. When a measurement is too weak to
  settle a question (too few samples, one fixture, high variance), say so and do not let it
  pick a default.
- **The gate's build/test parallelism is a knob you own.** `WA_GATE_JOBS=<n>` caps
  `CARGO_BUILD_JOBS` and `RUST_TEST_THREADS`; unset uses Cargo's default. The gate prints
  its setting. Read `docs/EVOLUTION.md` ("Gate parallelism") for measurements and
  `docs/CONCURRENCY.md` ("Lane reservations and the serial gate") for ownership.
- Verify before claiming: run the smoke test, and prefer a real two-node check
  over a single-process one.
- **A Lua test has only tested the tree when a Lua root is in use.** A `WA_SCRIPT` run with no
  `WASM_AGENT_LUA_ROOT` resolves its modules from the copy compiled into the binary, so an edit
  under `lua/` is not in the run at all; stderr now says so once (`lua root unset: using embedded
  modules; edits under lua/ are NOT under test`), and a root that is set but unusable fails loudly
  instead of falling back.
- A **skipped test is reported as skipped**: the suites count skips and say so in the
  verdict. A run that did not test something must not print the sentence a run that did.

## Stopping the node

Never stop it by image name; stop the pid in `serve.pid`. The reason, the command and the
recovery are in `skills/self-update/SKILL.md`.

## Restarting the node you are running on

You cannot: the stop is the last command your run executes; ask the sentinel.
`skills/self-update/SKILL.md` has the procedure.
