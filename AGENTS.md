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

**A lane owns its tree; only the merge lane moves `main`.** Work happens in a worktree on the
branch that carries its name, and a producer's branch is its deliverable - the mistake this
replaced was an agent committing to `main` from the wrong tree (`docs/ORCHESTRATION.md`).
Integration is a lane of its own and runs without a human step: a delivery an independent reviewer
verified, whose own tree passed the gate, is merged and pushed by the merge lane, which is
authorised to land deliveries without asking each time. Who may move `main`, what a landing must
carry, the lifecycle (produce -> verify -> accept -> land -> deploy), the lanes and their
reservations are one rule set in `skills/git-orchestrator/SKILL.md`
("The integration protocol"); `docs/CONCURRENCY.md` holds the lane reservations. The
`.githooks/pre-commit` guard is convenience; the boundary that cannot be skipped is remote-side.

### Evolving code in parallel

**Before the first edit of a code-writing turn, load the `parallel-evolution` skill** - the
per-turn loop (sync → small change → prove it merges → gate → end clean), the branch rules and the
convergence/escalation protocol. In one line: one `change/<name>` per delivery from current
`origin/main` (adjacent work steers the warm session and may share the branch), never move a tree
you do not own, end every commit with its provenance trailer, and prove the merge with
`git merge-tree --write-tree origin/main HEAD`. Your branch is your deliverable; the merge lane
lands it.

### Never touch the old plugin

The v8 plugin is the reference, not the target. Read it; do not modify it.

### Keep LF

These files are consumed by Linux and by `sh`/`lua`; `core.autocrlf=false` stores bytes as they are.
The `pre-commit` hook enforces it - that hook is the contract, this line is the pointer.

## Conventions

- **The host is capabilities, not logic.** Agent logic is Lua; platform capabilities
  are Rust `host.*`. Read `docs/HOST.md` before adding a capability: a host function
  returns `nil` for missing values (never zero values), and paths come from
  `host.paths()`, never `$HOME` or a Linux-only path.
- **The Rust workspace manifest is `rust/Cargo.toml`; the repo root has none.** A bare
  `cargo test -p wa-host` at the root fails with "could not find `Cargo.toml`", which reads like a
  broken checkout and is not. Pass `--manifest-path rust/Cargo.toml` (what `scripts/test.sh`,
  `scripts/deploy.sh` and `scripts/build-*.sh` do), or run the command from `rust/`.
- **Use the graph to check impact, not to replace source inspection.** Grep/read are
  normal navigation. Before finishing a code patch, the opt-in graph impact audit
  (`WA_GRAPH_PATCH_AUDIT=1`) flags resolved callers not read in this run; a
  standard `git commit` through `bash` gets a one-time review prompt first. It is a
  review lead, never a correctness certificate; see `docs/GRAPH-PATCH-AUDIT.md`.
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
  `CARGO_BUILD_JOBS` and `RUST_TEST_THREADS` for `scripts/test.sh`; unset means cargo's own
  default, one job per logical core, which two concurrent gate runs then fight over. The gate
  prints what it ran with. `docs/EVOLUTION.md` ("Gate parallelism") has the measurement;
  `docs/CONCURRENCY.md` ("Lane reservations and the serial gate") says how many gates may run at
  once and why the gate is a reserved serial resource.
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
