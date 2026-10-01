# Execution ownership and isolation

The definitions in [ARCHITECTURE.md section 6](../ARCHITECTURE.md#6-naming-and-execution-ownership)
are canonical. This document specifies the target contract; the release evidence in
[ORCHESTRATION_ROLLOUT.md](release/ORCHESTRATION_ROLLOUT.md) distinguishes implementation,
fixture proof and deployed proof. Never treat a design requirement as a passed test.

## Seven concepts, seven different identities

| Concept | Definition | Owns / belongs to |
| --- | --- | --- |
| Node | An identity, authority boundary and supervised runtime. | A configured installation/state home; authenticated principals, sessions and capabilities. |
| Session | An independently resumable conversation. | One node and author; ordered transcript and runs. |
| Run | One execution within a session. | One session; model/tool execution, output, cancellation and terminal evidence. |
| Subagent | A supervised child task with its own context and execution state. | A parent run or job delivery; a separate child session and bounded execution. |
| Job | A reusable automation definition that can execute deterministic steps and invoke subagents. | An owner and approved revision; trigger, actions, limits and bound resources. |
| Delivery | One durable occurrence of a job, pinned to its revision and source event. | One job revision; deduplication, admission and effect evidence. |
| Operation | Supervised external execution, such as a shell process. | An executing principal/run/delivery; process lifetime, captured output and settlement. |

A node is not a computer. A worker thread is not a node, session, or subagent. A
conversation with its own name is not necessarily a lean child task. A portable job
artifact is a definition, not authorization to execute it on another node.

An **auth-session token** (including the historical `X-WA-Session` header) is a
credential, **not a conversation identifier**. A **conversation session** owns a
transcript and runs; the chat body's `thread` names one for routing. `session_id`
in provider attribution means the conversation session id, not the header value.
Resolve the conversation's owner before admitting work; never substitute the
credential for its id. Keep `X-WA-Session` compatible rather than silently
renaming a wire key. At new internal boundaries say `auth_token` versus
`conversation_id`; where `session` is a legacy parameter, document which one it is.

### Local authentication sessions

`lua/core/users.lua` stores SHA-256 bearer-token hashes in the node-local
`auth_sessions` table, bound to node identity and user. This table is not replicated
as conversation data. Every interpreter/process resolves the same credential;
logout, account removal and expiry revoke it across workers. A nonempty unknown
credential is an error, never the default master. `users.resolve` returns the error;
legacy `users.current` raises it so a missed check cannot escalate authority.

The default lifetime is 24 hours (`WASM_AGENT_AUTH_TTL_SECONDS`, clamped to 60 seconds
through 30 days). Old interpreter-local tokens cannot be migrated; the client must
sign in again. No transcript or existing user definition is deleted by this change.

**Security scope:** the existing local account chooser is not password authentication.
An empty header still selects the configured trusted-local default. Loopback access
is consequently operator authority on a master node; a bearer token does not turn
that port into a safe public multi-tenant endpoint. Guest nodes clamp local authority
to their guest role, and remote fabric calls require their separate verified peer
identity. Do not expose an operator's local port to untrusted clients.

Mechanism proof: `node scripts/test-auth-sessions.cjs` checks independent processes,
module boundaries, revocation, expiry, node binding and malformed configuration;
it does not claim remote login security.

## Relationships

```text
computer
  node A: identity / home / credentials / permissions / supervisor
    session A1: operator conversation -> ordered runs
      run -> subagent task -> separate child session -> child run -> result
    session A2: another conversation -> independently ordered runs
    job revision -> delivery -> deterministic steps / subagent -> effect receipt
  node B: another identity / home / credentials / permissions / supervisor
    sessions and jobs under node B's authority (possibly a guest of another master)
```

Parallelism does not imply sharing state. Each node has independent identity keys,
provider/user credentials, databases, ports, supervisor records and lifecycle ownership.
Two nodes may use the same browser only through an explicit resource binding and action
coordination. These are application-level boundaries, not an OS sandbox against an
administrator or an unrestricted shell.

## Admission, execution and cancellation

* A session has one active writer. Admission reserves ownership atomically, covering
  both queued and executing requests until the last admitted request settles. An explicit
  conversational fork creates a separate session from a validated historical message boundary;
  it is not a delegated task.
* Distinct interactive sessions can execute concurrently. Background inference has
  bounded capacity and cannot occupy all interactive capacity. Queue overflow is an
  explicit refusal or retained delivery, never invisible loss.
* Read/control capacity is independent of long inference: inspecting and cancelling
  background work must not wait behind the work being inspected or cancelled.
* Output sinks, model settings, context, telemetry and cancellation belong to a run,
  never to the last socket or most recently active conversation in the process.
* A receipt proves admission, not successful inference or an external effect. Expose
  queued, executing, settled and unknown outcomes with their evidence.
* Cancellation is a request until execution acknowledges settlement. Network loss or
  a restarted observer does not prove that a task died or an external effect did not
  happen. Unknown outcomes require reconciliation before replay.

Reserved capacity promises separation from unrelated background inference, **not**
unlimited simultaneous sessions, provider quota, zero scheduling latency or freedom
from shared hardware limits. Same-session ordering is intentional.

## Session workspaces

Conversational forks and delegated sessions whose approved tool profile can write files or run
shell are marked `workspace_required` and receive a dedicated local git worktree before they are
reported as ready/admitted. Binding metadata (`worktree`, branch, base commit, source path, starting
status, allocation state/error) lives on the session and survives process restart. Allocation
starts at the source session's exact clean HEAD. A dirty source is recorded and refused; the node
does not implicitly copy, stash, or discard uncommitted work. The caller may clean/commit and retry
through `session_worktree{action:"recover"}`. A process interrupted during `git worktree add` is
reconciled from Git's worktree registry; unresolved state is `unknown` and is not blindly retried.

An owned root conversation may explicitly allocate or recover its workspace from the node's
runtime checkout. The allocator inspects that clean source before marking a legacy root as
requiring isolation; it never treats the root's own unavailable workspace as its source.
Both the HTTP and tool entry points support recovery of older failed roots with no binding.
An existing binding or uncertain allocation is never replaced by this bootstrap, and children
still require a usable source parent. Status names the recovery action for an unavailable root.

A node that did not create the source session — a placed child's destination — cannot use the path
that session recorded: `C:/Users/.../wasm_the_first` is one machine's checkout and means nothing on
another, and one path on two machines is two different repositories. There the source is the tree
*that* node runs from (`runtime-worktree.txt`, else its working directory when that is a checkout),
which is what a local child gets too. A path that names nothing on this node falls back to that
checkout; a path that is here and is not a checkout is refused. The session records which tree was
used (`source_origin`), what the incoming session named (`source_requested`) and why it was left
alone (`source_fallback`), so a reader can see the decision rather than infer it. A node with no
usable checkout of its own refuses with `workspace_destination_source_missing`, names what is
missing, and records the child's workspace as `failed` — never `pending` with an empty source, which
a retrying dispatcher reads as "not finished yet". A refusal names its own reason as the error code
(`workspace_source_dirty`, `workspace_source_unavailable`, `workspace_destination_source_missing`),
with the whole sentence in `detail`.

A retry of a request must have the effect of the attempt before it: the child session of a request
that carries an idempotency key is named by that key, so the next attempt finds the session and the
checkout its first attempt wrote rather than adding a second pair. A refusal that ends the request
retires that session; a capacity refusal keeps it, because that is the one case the coordinator asks
again.

A required but unbound/failed workspace is not equivalent to a legacy unbound session: file and
shell writes return `session_workspace_unavailable` and never fall back to the node checkout. File
writes outside the binding, explicit shell cwd escapes, and shell/client/remote/spell tools that
do not accept a verifiable session cwd are refused. Ordinary pre-existing sessions remain
unbound/compatible until they request isolation. Worktrees are node-local and share Git's object
store; this is coordination, **not** an OS sandbox against an unrestricted shell, symlink, or
administrator. Cooperative client resource claims are described in `docs/CONCURRENCY.md`.
Automatic worktree reaping and cross-home resource locking remain outside this contract.
See `docs/SESSION-FIRST.md` and `scripts/test-session-workspaces.cjs`.

### Explicit workspace release

`session_worktree{action:"release",session_id}` and the Engine's **Release clean
workspace** control remove only an allocator-owned worktree. A session claim fences
participating runs during inspection/removal. The canonical directory must match
the managed root, Git registry and recorded branch. Dirty or ignored files and
commits not at the starting base or reachable from the locally fetched `origin/main`
refuse removal. Git runs without `--force`; the branch and transcript remain.

Unsettled operations in that workspace block removal. Legacy operation records
without cwd attribution conservatively block all cleanup while unresolved; this
may require inspecting old operation evidence before a legacy node can release a
workspace. There is no destructive automatic migration of those records. New
operation receipts persist cwd. Missing/corrupt operation evidence fails visibly.

Release intent and outcome persist as `releasing`, `release_unknown`, or `released`.
A lost removal receipt is reconciled against both the directory and Git registry.
Released sessions stay required-but-unavailable for writes and cannot silently
fall back to the shared checkout or reallocate themselves. A crash may also leave
the maintenance resource claim, which requires the ordinary evidenced reconciliation.

## Subagent contract

A caller supplies a bounded task, fresh context, a result contract and a capability
profile. The default model/reasoning choice may inherit the caller's configuration;
explicit overrides must name approved models. An economical model is not necessarily
free and a configured free tier is not an unlimited budget.

A child does not inherit its parent's full transcript, automatic memory, operator
instruction file or unrestricted tool set. Mandatory authority and untrusted-input
rules still apply. Filter tool schemas **and** enforce the same restrictions at dispatch.
Requested capabilities can only narrow the caller's authorized capabilities; a profile
name cannot elevate a guest. Resource constraints include the permitted conversation,
recipient and action, not merely the name of a broad browser tool.

Limits cover active and queued tasks, nesting, elapsed time, context/output size and
provider usage. Explain what is measured versus estimated. A blocked parent waiting
for its child must not hold the only capacity that can run the child. Waiting is a
runtime operation, not repeated model calls to poll status.

Results are explicitly retrieved or awaited. Parent-child links and task outcomes are
inspectable without inserting every child's transcript into the parent's conversation.

`POST /session/fork` accepts `{session_id, before_seq}` under the authenticated principal.
It copies only non-summary transcript evidence through that exact message, rejects incomplete
tool exchanges and unauthorized source sessions, and records `fork_parent_id`/`fork_parent_seq`
separately from subagent `parent_session_id`. The new session has no inherited summary or
worktree. Copied evidence survives source transcript retention; images still reference
node-local content-addressed attachments. This is a conversation fork only: workspace contents
and external effects are not rolled back. See `scripts/test-session-fork.lua`; automatic
isolated worktree allocation remains unimplemented.

## Jobs and portable artifacts

Definitions declare triggers, actions, specialist profiles, requested resources and
budgets. Import installs a disabled definition. Local approval binds resources and
permits execution; an authority-expanding revision invalidates approval. Exported
artifacts contain no credentials or machine-specific absolute bindings.

A delivery is pinned to a revision and stable source event. Deterministic filtering
precedes inference. Subagent execution uses the same primitive as ordinary runs, not
a second privileged agent loop. Retry proven non-submission where safe; never blindly
retry an ambiguous model submission or external effect.

See [JOBS.md](JOBS.md), [OPERATIONS.md](OPERATIONS.md), and [MEMORY.md](MEMORY.md) for
existing queue, process-lifetime and transcript evidence contracts.

## Browser automation proving case

```text
WhatsApp ingest -> eligibility -> durable delivery -> scoped responder subagent
                -> validated decision -> permitted send -> verified effect
```

Eligibility uses actual IDs and adapter metadata: direct chats; groups only when the
operator is mentioned; archived/left conversations excluded. Unknown metadata must
be reported rather than guessed. A responder's description of a group is not its title.

Drafting and sending have different permissions. The send capability validates the
recipient and exact body, protects human drafts and unread state, coordinates the
shared browser resource, and retains message-level effect evidence. Concurrent
reasoning is allowed; concurrent conflicting edits of one composer are not.

The release proof must show background processing while **two** interactive sessions
make independent progress and inspect it. Live proof may send to the operator's own
notes-to-self freely - that destination is standing-authorized by the operator and
needs no separate authorization - and to any third party only once explicit
third-party authorization is established. Fixtures
and live tests must be labelled separately; an unavailable browser is a blocker, not
permission to substitute a mock and call it a live demonstration.
