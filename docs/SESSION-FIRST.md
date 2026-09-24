# Session-first ownership: the node is a host, the session is the writer

This is a **proposal**, not a description of the running system. It exists so the next step of
"work in parallel sessions from one node" is a contract to build against rather than a slogan, and
so the node-scoped assumptions it removes are named where a reader can check them.

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
3. **Allocate on first write.** A session gets its own worktree the first time it stages an edit
   (or explicitly, `wa worktree new`), not on creation — most sessions never write code, and
   allocating a worktree per chat is how this becomes disk sprawl.
4. **Point the patch audit at the session.** `patch_audit.lua` audits the session's worktree and
   records which one, so a "no patch" verdict names the tree it looked at.
5. **`/merge` reads session branches.** The orchestrator still merges to `main`; the branches it
   audits are `change/<session-short>`.

## Risks, named rather than hidden

- **Worktree sprawl and git lock contention.** N worktrees share one object store; `git gc` and
  concurrent `git add` are the contention points. Prefer short-lived per-concern worktrees and reap
  them when the branch lands, the way the board already reaps merged `change/*` branches.
- **The name becomes ambiguous.** `node_name()` currently answers "which checkout am I?". With a
  session-scoped worktree, a node hosts several — the node identity and the session identity have to
  be two different answers, not one reused string.
- **The orchestrator is still a serialization point.** Session branches reduce the blast radius of a
  conflict; they do not remove the need for one integration order. Do not claim `/merge` became
  parallel.
- **A session is not a security boundary by itself.** Session-scoped worktrees must key on the
  authenticated owner, not the conversation id, or two users sharing a conversation id could share a
  tree.

## What this does not cover

- **It does not change run admission.** That is already session-first and stays in
  `serve/scheduler.rs`.
- **It does not make the accept thread non-blocking.** The node's accept loop is still serial; an
  inline admission resolve can hold it for `WASM_AGENT_ADMISSION_TIMEOUT_MS` (8s), which is the same
  number as the UI's `apiFetch` timeout. That is a separate, measured change, not part of this
  contract.
- **It does not allocate anything for non-writing sessions.** A conversation that only chats keeps
  costing exactly what it costs today.
