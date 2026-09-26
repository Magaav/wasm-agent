# wasm-agent architecture

How the system is put together: what is scoped to what, what a capability tier means, and where a
concern belongs. The *UI* rules - components, spacing, balloons, what a view may do - are in
[`DESIGN.md`](DESIGN.md), and they are enforced the same way. Both are contracts: when a change
conflicts with a rule here, change the change, or amend the file first with a reason.

## 1. Scope an instruction to where it is true

The agent's instructions are assembled per turn from files, and every line of them is
paid for on every turn. So an instruction lives where it is true, and nowhere else:

| Scope | Where it lives | Injected |
|---|---|---|
| every turn, every node | `AGENTS.md` | always |
| one role | `AGENTS.guest.md` | guests only |
| one platform | `AGENTS.<platform>.md` (`AGENTS.windows.md`) | only on that platform |
| a technique, on demand | `skills/<name>/SKILL.md` | only when the model asks |
| a fact about a subsystem | `docs/*.md` | only when read |

**And prefer a mechanism to a sentence.** If the machine can enforce it - a path that
gets converted, a route that refuses, a startup warning, a test - then it belongs in
code, because code costs no context and cannot be forgotten. Prose is for what neither a
role, a platform, a skill, nor the code can carry.

The test for a rule is not "is it important" but "is it true here, and is it cheap". A
rule about Windows in the global file is neither: it spends tokens on Linux turns and
it teaches a node to distrust rules it cannot check.

1. Search `ui/components.js` and `ui/style.css` first.
2. If something is close but not a fit, **extend the existing component** (add a
   property, a slot, a variant) instead of forking it.
3. Only add a brand-new component when nothing existing can carry the behaviour.
   When you do, you must:
   - implement it as a custom element in `ui/components.js`;
   - style it with the shared tokens in `:root`;
   - document it in the "Component registry" below in the same change.

Duplicated markup that should have been a component is a defect.


## 2. Memory is on demand

Memory is a feature the agent uses when a task calls for it, not a dashboard.
The UI must not foreground memory: no memory counters in the status balloon, the
header, or the empty state. Surface memory only inside a turn (a `recall` tool
chip) or when the user explicitly asks for it.


## 3. Capability tiers

Tools are grouped by the role that may call them (§ see `lua/core/tools.lua`):

Roles are `master` (full) and `guest` (on demand memory); `admin` is a legacy
alias for `master`. Binding between nodes is `master:master` or `master:guest`.

| Tier | Tools | Roles |
| --- | --- | --- |
| memory | `remember`, `recall` | everyone |
| capabilities | `capabilities` (list what this role may call) | everyone |
| environment (pi) | `bash`, `read`, `write`, `edit`, `ls`, `grep` | master |
| shell | `shell` (shell on the client host, also the UI terminal) | master |
| ledger | `search_messages`, `conversation`, `list_conversations` | master |
| client | `client` (screenshot, frame, mouse, keyboard, shell, CDP) | master |
| nodes | `nodes`, `remote` | master |
| spells | `spell_save`, `spell_run`, `spell_list`, `spell_get`, `spell_forget` (crystallized macros) | master |
| plugins | every WASM plugin | master |

Never expose a master tier to a non-master turn; filter schemas *and* re-check in
`dispatch`, because the model can ask for a tool it was not offered.
The `client` and `shell` tools drive a real machine — the highest-risk tiers.

A **node** has a role as well, and it answers a different question from the role
of a turn. A *guest node* exists so that a master can have something done on the
machine it runs on: it owns no worktree and no branch, so it is never named
after a directory and a rename never moves a branch on its behalf, and its own
capabilities are read-only. When a master calls it (`/node/call`, signed), the
work runs **as that master** — the session and every tool call are filed under
the master's name, never the guest's. There is one answer to "who did this?"
whether the edit happened here or on a guest. `verify_peer` refuses a caller
whose node is not a master, so a guest cannot command another node, and
`nodes.author_of` is the single gate that turns a caller into an author.

## 4. If it can be deterministic, make it so

This is the first rule of this file, and it outranks the others: **anything the machine can check should
not be prose.** A sentence costs context on every turn, is forgotten under pressure, and is argued about
when two people read it differently. A mechanism costs nothing per turn, cannot be forgotten, and settles
the argument by running.

So before writing a rule, ask in this order:

1. **Can the code make it impossible?** A path converted at the boundary, a route that refuses, a startup
   warning, a write that is atomic. Best: no one has to know the rule.
2. **Can a hook enforce it?** LF, a commit trailer, "main only takes merges". Checked at the moment of the
   mistake, in the only place that can stop it.
3. **Can a test catch it?** Then it is a fact, not a preference - and it must be provably able to fail, or it
   is not a test.
4. **Can a trigger do it on a schedule or an event?** Currency with `main`, a restart, a wake.
5. **Only then: prose** - in `AGENTS.md` if it is needed on every turn, in `docs/` if it is needed on demand,
   in a skill if it is a technique.

The test for whether something belongs in prose: *would a mechanism have caught the failure that made me
write this?* Tonight's three failures all answer yes - a context-budget policy stated in code and re-litigated
three times, scratch files with no ignore rule, and a branch shape where the roadmap said one thing and
`AGENTS.md` said the opposite. Every one was a sentence where a mechanism belonged.

**And prefer a spell over a sequence.** A procedure that works - a build, a deploy, a recovery - should be
crystallised into a spell, so it runs the same way every time, costs no model tokens to re-derive, and cannot
be half-remembered. Spells are the deterministic form of a procedure; this section is the deterministic form
of a rule.

## 5. Branch shape

Two rules that must not be confused, because they apply to different things:

- **A node's branch is its home.** It is named after the worktree, it is where the node lives, and its job is
  to stay current with `main` - a node that cannot see `main` cannot see the rules. It is not a delivery
  vehicle, and it should not accumulate work.
- **A change is a short-lived branch.** `change/<name>`, born from current `main`, one change, merged and
  deleted. A branch that lives a day cannot fall 21 commits behind, and merging it is cheap because it is
  small and recent.

The failure this prevents: the roadmap described short-lived branches while `AGENTS.md` told every agent to
treat its node branch as the deliverable - so the code followed one rule and the docs described another, and
the node's branch accumulated six commits ahead of `main` that were mostly merge bookkeeping. When two rules
describe the same branch, one of them is wrong.

## 6. Naming and execution ownership

The canonical execution concepts are:

| Concept | Definition |
| --- | --- |
| **Node** | An identity, authority boundary and supervised runtime. |
| **Session** | An independently resumable conversation. |
| **Fork** | A new conversation rooted at one exact historical message boundary. |
| **Run** | One execution within a session. |
| **Subagent** | A supervised child task with its own context and execution state. |
| **Job** | A reusable automation definition that can execute deterministic steps and invoke subagents. |
| **Delivery** | One durable occurrence of a job, pinned to its revision and source event. |
| **Operation** | Supervised external execution, such as a shell process. |

A computer can host multiple nodes; a node can serve multiple sessions concurrently;
a session orders its own runs; a run or job delivery can own subagent tasks. A subagent
has a separate session and executes runs; it is not another node. A job definition is
not an execution, and an operation is not a job. A received submission is not a
completed run or delivery.

[docs/EXECUTION.md](docs/EXECUTION.md) defines these ownership and isolation contracts. `POST /session/fork` implements exact transcript ancestry separately from delegated child linkage; see [the foundation plan and evidence ledger](docs/EXECUTION-FOUNDATION-PLAN.md). The rollout evidence is recorded separately: terminology or a contract does not claim an implementation has passed its integration test.

Three different things shared two words, and it cost a real question: `session_turns()` returns *messages*,
`turn_id` identifies a *run*, and the UI says "this turn 99s" meaning the run. Settled here, once, and chosen
to match what the words already mean everywhere else rather than what was convenient:

| Word | Means | Was called |
|---|---|---|
| **run** | one execution within a session, from accepted input to a terminal outcome (including failure/cancellation) | `turn_id`, `turn_span`, "turn" in the UI and `/health` |
| **turn** | one speaker's contribution within the run (the user's ask; the assistant's answer) | `turn_id` |
| **step** | one model call plus the tool calls it caused — the decision cycle | the `turn` span, "decision" in the UI |
| **model call** | one provider request and response | `llm` span |
| **tool call** | one tool execution | `tool` span |
| **message** | one stored transcript row (user, assistant, tool, summary) | the `turns` table, `session_turns()` |
| **operation** | one supervised external execution, with identity, owner, output, cancellation and settlement | formerly the blocking internals of `host.exec`; never called a job |
| **job** | a reusable, enabled/disabled automation definition: trigger plus declared deterministic or subagent actions | new managed automation; legacy sentinel triggers are not silently migrated |
| **trigger** | the job's event/schedule matching rule; it does not execute the action | legacy `triggers.json` combined rule/action fields |
| **delivery** | one durable queued occurrence of a job, pinned to revision and source event id | new; not a run, message, or operation |

A job can queue a wake (which starts a run and can apply a skill) or deterministic execution
(which may use operations without any model inference). A tool call may await an operation or return
its explicit launch receipt. A receipt is not completion. These contracts and their enforcement are in
[docs/OPERATIONS.md](docs/OPERATIONS.md) and [docs/JOBS.md](docs/JOBS.md).

An ordinary completed conversational run has one input user turn, an assistant response, and one or more
steps. A failed or cancelled run need not reach a final assistant answer. Each step has exactly one model
call and zero or more tool calls. A step is **not** a model call: it contains one, and the tools that call asked for run between
it and the next step — which is why a ledger of 178 model calls held 151 tool executions.

Two choices worth recording, because both were the other way round in the first draft of this section:

- **"turn" keeps its meaning from every other harness and from conversation itself** — a speaker's
  contribution. Using it for the decision cycle would have renamed everything and kept the same ambiguity,
  with "turn" meaning a third thing.
- **"call" is never used alone.** There are model calls and tool calls, and one word covering both is the bug
  this section exists to end.

The renames, mechanical and in this order:

- schema: `harness_events.turn_id` → `run_id`; span kinds `llm` → `model_call`, `turn` → `step`, `turn_span` →
  `run`; the `turns` table → `messages`
- code: `session_turns()` → `session_messages()`; `memory.session_state`'s "the last turn failed" → "the last
  run failed"
- UI: "14 decisions · 19 tool calls" → "14 steps · 19 tool calls"
- docs and skills: every use of "turn" that means a run, every use that means a message, and every use of
  "decision" that means a step

This is a mechanism, not a style preference: a reader debugging a session should not have to know which file
they are in to know what a word means.

**It is enforced, and the enforcement says what it does not cover.** `scripts/check-naming.sh`, run by
`scripts/test.sh`, greps the tracked tree for the old *names* and fails if any remain. It never greps for the
word "turn", so prose is a reader's job and not the check's: `naming ok` means no old name survived, not that
every sentence was re-read.

## 7. What a contract owes the reader

Section 4 says make it a mechanism. These are the four things that make a mechanism a *contract*, each paid
for in this repository, most of them tonight.

**A contract names its mechanism.** "Deterministic" is not enough: the contract says which mechanism, by name,
so a reader can find it and a checker cannot be forgotten. The pairs in force today:

| contract | mechanism |
| --- | --- |
| branch shape (§5) | `.githooks/commit-msg` |
| never replace a better install | `scripts/deploy.sh`, step 3 |
| a tool result follows its call | `scripts/test-tool-adjacency.lua` |
| the names in §6 | `scripts/check-naming.sh`, wired into `scripts/test.sh` |
| a skipped test is reported | the suites' verdict lines |
| concurrent runs: one writer per conversation, lanes | `rust/wa-host/src/serve/scheduler.rs` + `scripts/test-run-isolation.sh` |

A contract whose mechanism is unnamed is a contract a reader cannot check.

**A mechanism states its blind spot.** `naming ok (200 files, no old names)` is true, and it is *not* "the docs
are renamed": the check greps old names and deliberately never the word "turn", because §6 keeps that word for
one speaker's contribution. A verdict read for more than it says is worse than no verdict at all, so the
contract says what its check does not cover and the reader knows which half is theirs.

**An exception carries its reason where the exception is.** A `naming-check: allow` marker, a `note:` line in
`deploy.log`, `WASM_AGENT_ALLOW_MAIN=1`: each is permitted, and each states why, in the file, on the line. An
exception without a reason is a hole.

**How a word is added.** §6's table grows by one row per concept: the word, what it means, and what it
replaced. Never borrow an existing word for a new thing - that is how three things came to share two words. A
word that crosses a boundary (a wire key, an env var, a column, a tool name the model reads) moves in one
change with both sides, and its old form survives only as a migration matcher. Renaming an *interface* - the
journal's kinds, the model-facing tool list - is a different decision from renaming an internal word, and is
recorded as one.

**An asymmetry is written down.** Foreground shell operations have an execution deadline
(`WASM_AGENT_EXEC_TIMEOUT_SECONDS`, 300s by default, or a per-call `timeout_seconds`) plus an explicitly reported 1000ms forced-cleanup
budget; a run has no wall-clock deadline. Other tools do not inherit the shell's deadline merely
because they are tool calls. `docs/OPERATIONS.md` names the actual mechanisms and their limits. Measured, not assumed: a single `bash` of 993 seconds in the ledger, and a run of 47
steps that lasted 56 minutes. Neither number appears in `docs/` today, so the next reader learns it by watching
it happen - which is the expensive way.
