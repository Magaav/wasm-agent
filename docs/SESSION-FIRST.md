# Session-first ownership: the node is a host, the session is the writer

This is a **proposal**, not a description of the running system. It exists so the next step of
"work in parallel sessions from one node" is a contract to build against rather than a slogan, and
so the node-scoped assumptions it removes are named where a reader can check them.

**Status.** Session cwd routing and durable bindings are implemented. Conversational forks and
subagents whose approved profile has write-capable tools automatically get dedicated Git
worktrees (`lua/core/workspaces.lua`), persisted with base commit, source branch/path, initial
status and allocation state. Dirty source checkouts are refused with their status recorded;
changes are never silently copied or omitted. Required-but-failed bindings block file writes and
shell execution rather than falling back to the node cwd. Existing ordinary sessions remain
unbound for compatibility and can explicitly allocate through `session_worktree{action:'allocate'}`.
The shell/client/remote/spell capabilities that cannot honor a session cwd are refused for a
required-workspace session. See `scripts/test-session-workspaces.cjs` and
`scripts/test-subagents.cjs` for runtime fixtures.

Read [CONCURRENCY.md](CONCURRENCY.md) for what is already true. This file is only about what is
still keyed by the *node* and should be keyed by the *session*.

## The problem

The run scheduler is already session-first: a conversation is the unit of admission, ordering and
cancellation, and `run_capacity`/`interactive_reserve` already let several conversations run at
once (`rust/wa-host/src/serve/scheduler.rs`, proven by `scripts/test-run-isolation.sh`).

The **mutable workspace is not.** One node has one working directory, so it has one checkout, one
branch and one `/merge`. Three sessions on that node are three writers in one worktree: they
overwrite each other's edits, they cannot each run their own parallel-evolution loop, and the
orchestrator has one place to integrate. The parallelism stops at the transcript.

A session may now be conversationally forked at an explicit completed message boundary with
`POST /session/fork`. The fork stores `fork_parent_id`/`fork_parent_seq`, copies only selected
non-summary transcript rows, and inherits no worktree. This isolates conversation context, not
filesystem state: bind an independently writable worktree before code-writing. It is distinct from
a subagent's `parent_session_id`. See `docs/EXECUTION.md` and `scripts/test-session-fork.lua`.

The node-scoped assumptions, each with the code that holds it:

| assumption | where |
| --- | --- |
| the worktree is the node's cwd | `lua/core/nodes.lua` `M.worktree()` reads `platform.cwd()` |
| shell/spell steps run in the node's checkout | `host.exec(command, cwd, …)` callers pass the node worktree |
| the patch audit looks at the node's tree | `lua/core/patch_audit.lua` (`patch_source = "git_worktree"`) |
| one integrator for the whole repo | `lua/core/merge.lua`, `ui/app.js`, `skills/git-orchestrator/SKILL.md` |
| one node name = one checkout | `AGENTS.md`, `lua/core/nodes.lua` `M.node_name()` |

## The target contract

A **session owns its mutable workspace**. The node owns only shared infrastructure: the database,
the model credentials, the repo's git object store, the relay, the job store. Concretely:

- **conversation** — the unit of run admission and ordering (already true);
- **worktree** — one per session that writes code, `change/<session-short>`, cut from current
  `origin/main`;
- **cwd** — every shell/spell/patch-audit step resolves its directory from the session, never from
  the process cwd;
- **evolution loop** — each session runs the `parallel-evolution` loop (sync, small change, prove
  merge, gate) independently and merges on its own schedule;
- **integrate** — `/merge` stays a repo-global act, but its *inputs* are session branches, not node
  branches.

The user-visible promise: N sessions on one node are N writers, and a session that is stopped,
cancelled or still thinking never blocks another session's edit.

## Migration, in order

1. **A mapping, defaulting to today.** Add `session_worktree(session_id, path, branch, created_at)`
   to `memory.db`, plus `sessions.worktree(session_id)`. A session with no row keeps using the node
   worktree, so every existing behavior is unchanged until a session opts in. Backward compatibility
   is the point: this must not require a migration of live sessions.
2. **Resolve cwd from the session.** `host.exec`, the `shell` tool and the spell step resolve the
   directory through `sessions.worktree(session)` and fall back to the node worktree. A step that
   does not name a session keeps today's behavior.
3. **Allocate at independent-writer admission.** A conversational fork is bound before the fork
   operation reports success. A delegated task whose approved tools can write files or run shell
   receives a bound worktree before native child admission; failures are visible and the child is
   not launched. Plain existing conversations are not auto-migrated. Their owner can explicitly
   request allocation. Each source must be a clean Git checkout; uncommitted changes are recorded
   in the failed allocation state and require a clean/commit followed by explicit retry.
4. **Point the patch audit at the session.** `patch_audit.lua` audits the session's worktree and
   records which one, so a "no patch" verdict names the tree it looked at.
5. **`/merge` reads session branches.** The orchestrator still merges to `main`; allocated
   branches are `change/wa-session-<session-id>`. Merged worktree reclamation is not automatic.

## Risks, named rather than hidden

- **Worktree sprawl and git lock contention.** N worktrees share one object store; `git gc` and
  concurrent `git add` are contention points. Bindings are durable and not automatically reaped;
  operators must retain/review/remove them through Git worktree management until lifecycle cleanup
  has its own evidence. An interrupted `git worktree add` is reconciled from Git's registry when
  possible; ambiguous state is marked unknown and never blindly replayed.
- **The name becomes ambiguous.** `node_name()` currently answers "which checkout am I?". With a
  session-scoped worktree, a node hosts several — the node identity and the session identity have to
  be two different answers, not one reused string.
- **The orchestrator is still a serialization point.** Session branches reduce the blast radius of a
  conflict; they do not remove the need for one integration order. Do not claim `/merge` became
  parallel.
- **A session is not a security boundary by itself.** Allocation checks the authenticated owner
  and node linkage; it does not sandbox an unrestricted native shell, defend against symlink escapes,
  coordinate browsers/desktops, or provide cross-node filesystem portability. Explicit file paths
  outside the binding and shell/client/remote/spell execution are refused where the tool boundary can
  see them; shell commands can still deliberately address external resources.

## What this does not cover

- **It does not change run admission.** That is already session-first and stays in
  `serve/scheduler.rs`.
- **It does not make the accept thread non-blocking.** The node's accept loop is still serial; an
  inline admission resolve can hold it for `WASM_AGENT_ADMISSION_TIMEOUT_MS` (8s), which is the same
  number as the UI's `apiFetch` timeout. That is a separate, measured change, not part of this
  contract.
- **It does not transparently migrate existing ordinary sessions or allocate for read-only children.**
  Such sessions preserve today's cwd behavior unless their owner explicitly requires isolation.
