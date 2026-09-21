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

Authentication session tokens (including the historical `X-WA-Session` header) are
credentials, **not conversation identifiers**. The chat body's `thread` identifies a
conversation. Resolve its owner before admitting work; never substitute the credential
for the conversation name. Keep the historical header compatible, but describe its
meaning explicitly wherever it crosses a boundary.

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
  both queued and executing requests until the last admitted request settles.
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
make independent progress and inspect it. Live proof may send only to the operator's
own notes-to-self unless separate third-party authorization is established. Fixtures
and live tests must be labelled separately; an unavailable browser is a blocker, not
permission to substitute a mock and call it a live demonstration.
