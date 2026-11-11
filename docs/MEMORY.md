# Sessions, transcripts and observability

Two rules drive all of this:

1. **Memory is on demand.** The context starts empty every turn. The only thing
   injected automatically is `AGENTS.md`. Facts and history are pulled with tools
   when a task needs them — never dumped in "just in case".
2. **Debuggability is core.** If we cannot see exactly what happened and where it
   failed, we cannot evolve the agent. Every turn is recorded, and a failing task
   can be reproduced from a fixture.

## The three stores (do not conflate them)

| Store | What it is | Tool |
| --- | --- | --- |
| `memories` (+FTS) | distilled facts | `remember`, `recall` |
| `messages` (+FTS) | **the agent's own dialogue** — its transcript | `sessions`, `session`, `search_messages`, `resume_session` |
| `runs` | effect/settlement record per run | (internal) |

`messages` holds the agent's transcript.
`runs` is not the conversation — it is one row per completed ask-and-answer.
Older databases used other names for these tables (`turns` for the transcript).
The shape migration renames them before applying the new schema. It also renames
`harness_events.turn_id` and `runs.turn_id` to `run_id`, preserving their rows. <!-- naming-check: allow (a migration names what it moves) -->
Once migrated, an older binary is incompatible and must not be restarted against
that database. Back up the database and install the matching binary in one upgrade.

## Sessions are resumable threads

A session is keyed by `(user_id, node_id)`: talking to `node-b` is a different
thread from talking locally, and a guest's threads are their own. `ensure_session`
reuses the newest open session for that pair, so a restart continues the thread
instead of starting a new one.

`messages` holds `seq, role (user|assistant|tool|summary|retry), content, phase,
tool_calls, tool_call_id, tool_name, tokens, ms, ok, debug, trace`. Assistant
`phase` preserves provider message roles such as OpenAI Responses `commentary`
and `final_answer`; commentary alone is not a settled answer. **The transcript is the
context**: `agent.lua` rebuilds the provider messages from it every turn
(system + AGENTS.md + summary + messages after the watermark). There is no separate
in-memory message list, which is what makes restarts resumable.
`retry` rows are exact display-only transport recovery events: same bubble/topic
on live/repaint/child hosts, not assistant prose or tool effects. They remain in
the ledger and sync, but build_context and compaction exclude them from model
input. A retry tail is unfinished; no restored connection implies task completion.
For recognized subscription disconnects, an interrupted retry row also retains the
uncommitted attempt's text/reasoning and bounded tool previews, labelled not executed.
Only a complete regenerated result is committed as assistant output and dispatched;
prior tools are never replayed. See [OPENAI-SUB.md](OPENAI-SUB.md).

The read-only `GET /session/owner?id=<id>` returns only `{session:{id,user_id}}`
for native sentinel ownership checks. It uses the existing account resolution and
owner/master permission boundary (including invalid/revoked credential refusal
and trusted local default), not a transcript read or a derived-state lookup.
It cannot mint deployment or return authority. See [SENTINEL.md](SENTINEL.md).

## Unfinished sessions (recovery)

A session is unfinished when its transcript just *ends* — after a question, after a
tool result, or after a step whose tools have no recorded result. That shape is
indistinguishable from "the answer is still coming": a process that was killed cannot
write a flag saying so (the exit path that would set one does not run), and a process
that is *alive* cannot write one either, because it has not stopped. Nothing in a row
tells the two apart.

The state was once called `interrupted`, and the word was wrong in a way that cost
credibility rather than data: a live 426-turn run was reported as interrupted on every
poll while it was demonstrably writing messages, and `wa resume` would have written a
durable "the process died" record for a thread that had not. A name that asserts an
event we cannot observe is a claim the code should not make, so the derived state is
`unfinished` and the notice says both possibilities out loud.

So the **state is derived from the ledger**, which is appended to as the turn
proceeds. The last turn is an exact record of how far the process got:

| state | last turn | meaning |
| --- | --- | --- |
| `empty` | none | nothing said yet |
| `answered` | assistant reply | the thread is settled |
| `failed` | assistant with `ok=0` | the model call errored or the progress guard stopped the turn (a repeated call, rounds that changed nothing, or an operator's round ceiling) — a **landed** outcome, not an unfinished one |
| `unfinished` | user, tool, retry, assistant commentary, or assistant with `tool_calls` | no completed answer is recorded after this turn; the process may have stopped or may still be working |

Failed state details now use the last failed span's recorded error (UTF-8-safe
bounded excerpt, explicitly labelled if truncated), rather than generic “inspect
its error” prose. The session listing reads terminal failed traces in its existing
joined query, without N+1 history scans. Missing error evidence stays explicitly
unknown. The UI can read the last failed assistant trace on older nodes and paints
error text as text, never HTML. Original records and failed classification remain.

`memory.session_state(id)` returns that, plus where it stopped and which calls of the
last step have no recorded result: "1 of 2 never reported" is a different fact
from "nothing ran", and only the step knows which — when the process dies between
two calls of a batch, the tail is a tool turn whose *sibling* never ran.

Derivation is always current but it forgets: resume the thread and the tail is an
answer again. So the first time an unfinished tail is **observed** it is also recorded
on the session (`interrupted_at/seq/reason/count` — the columns keep their old names
to avoid a migration), one row per *point* where a thread was picked up unfinished and
never per observation. That is what makes the history survive recovery.

What is visible, and where:

```
wa sessions          a state column, and the reason on its own line for threads
                     that need attention
wa status            an `unfinished at seq N  ...  ->  wa resume` line for the
                     current thread - absent when it is settled
wa resume [--list]   the report: what stopped it, what is unfinished, the question
                     that was never answered, how many times, and the command to
                     continue
wa resume [--session <id>] <prompt>
                     continue that thread
engine -> sessions   the state travels in the payload (`sessions`, `session?id=`)
```

Recovery is **not** a repair of the ledger. `build_context` already drops a
half-written tool exchange (a provider 400s on a call with no result, and on a result
with no call); that was there already. What was missing is that the **model** was
never told: its transcript ends mid-exchange, so it assumes its last step either
succeeded or never ran — and both are wrong, because the step may have run without
its result being saved, and it may have run twice. So the first turn of a process in
an unfinished thread:

1. records the interruption (above), and
2. injects a **context-only** recovery notice — `system`, placed after the cached
   prefix, never written to the transcript — naming what was lost and telling the
   agent to re-establish the real state from the machine before continuing.

Context-only is deliberate: the transcript is what was said, and a synthetic turn in
it would be replayed to every later request as if the agent had said it, and would be
found by `search_messages`.

The UI resumes a stopped thread automatically when its last row is a tool result
and every call in that batch has a recorded result. It sends the observed tail
sequence with the continuation; the node checks the sequence and unfinished
state immediately before running it. A second window or reload therefore cannot
run the same continuation after the first has advanced the ledger. Missing tool
results remain visible for inspection because their effects may have happened
without being recorded.

Not to be confused with the `resume_session` **tool**, which folds a past session into
the current one's context: that is a recall aid, this is crash recovery.

Verify with `scripts/test-recovery.lua` (run by `scripts/test.sh` and by
`scripts/test-windows.ps1`): it builds each shape by hand, because a killed process
leaves a specific shape in the ledger and that shape is the contract — a test that
kills a child asserts the timing of a signal instead.

To see it for real rather than in a fixture, start a turn that asks for a slow tool
call, kill the process while the tool is running, and read the thread back — the
ledger keeps the step with no result, and `wa resume` names the call:

```sh
wa --db /tmp/kill.db chat "Run exactly this bash command with bash, then repeat its output: ping -n 8 127.0.0.1" &
sleep 7        # mid tool call, after the step was written
kill %1
wa --db /tmp/kill.db resume
#   waiting: 1 thread
#   544e4e9c  messages=2  1 tool call(s) never reported: bash, 5s ago
#             recover   wa resume --session 544e4e9c "continue where you stopped"
```

Caveat: the notice is a `system` message placed after the first one, verified against
the provider this node uses. If an endpoint rejects a mid-conversation system
message, it should become a `user` turn instead (a harness notice already does that):
recovery must not be the thing that breaks the request.

## Two recording modes

| | `default` | `debug` |
| --- | --- | --- |
| tool payloads | stable bounded view + retrievable original JSON artifact | same, plus first-step model/messages/tools snapshot (not a complete provider request) |
| retention | **originals preserved**; no automatic age-based deletion | **kept forever** |
| purpose | everyday use, small DB | reproduce a failure, build a fixture |

Flip it with `session_debug{mode}` (or the button in **engine → sessions**).
The workflow: spot a task failing → turn debug on → reproduce it → export the
fixture → fix → re-run the fixture as a regression test.

## Compaction (automatic, like pi)

When the assembled request approaches the selected model's capacity minus its
reserve (Pi's defaults: 16,384 reserved, 20,000 recent tokens kept), an older prefix is summarised into `sessions.summary` and
`summarized_until` moves forward. The summary is produced by
`WASM_AGENT_LLM_SUMMARY_MODEL` if set, otherwise by the main model.

After a **main run finishes**, `onStale` posts `/compact` with a 40% threshold and
summarizes the main session the `node.run_finished` event names (never a subagent,
and not merely the newest main thread). A delivered event with no valid session id
is logged and skips compaction instead of falling back; only a manual run with no
`WA_JOB_EVENT_FILE` uses the route's latest-main selection. That is a separate idle
maintenance path; the in-run trigger remains at capacity minus reserve (about
90–95%). A `WA_STALE_COMPACT=0` disables only the idle path.

An explicit positive `WASM_AGENT_CONTEXT_BUDGET` can trigger earlier; there is no
default 64K cap. Every unsummarized ledger row participates, without a 500-row gap.
Context estimates use a scope/model/schema/full-prefix-fenced provider measurement
persisted across agent turns and interpreter restarts, plus only appended rows.
Complete-history bytes/4 must not override a matching measured count: encrypted
reasoning JSON caused observed44–55% compactions against a92% configured trigger.
Missing/changed measurements fall back to text bytes/4 and Pi's1,200-token image
estimate, explicitly labelled. Neither tail nor fallback is a tokenizer.
See [CONTEXT-COMPACTION.md](CONTEXT-COMPACTION.md) for the evidence, fences and risks.

The summarizer receives full user/assistant text, reasoning and tool arguments;
large tool results get explicit 2,000-byte excerpts with artifact references.
Oversized backlogs are summarized in bounded prefixes. Empty, output-limited or
tool-calling summaries cannot advance the watermark. Summary usage is billed in
the durable telemetry totals, including unsuccessful attempts.

Summaries are **lossy interpretations**, not lossless compression. The retained
original transcript is the evidence, accessible via `session`/`search_messages`;
`session` supports `before_seq` pagination. Default transcript retention remains
preservation (`WASM_AGENT_RETENTION_DAYS` defaults to 0); debug transcripts persist.
`wa_retention`, `memory.prune` and `prune_journal` refuse deletion without evidence-aware
retirement admission. Quiet sessions, compaction, age and replication acknowledgments
cannot prove an original is no longer needed by an operation, claim or workspace. `session`/`search_messages` also offer an
explicit `view:'compact'` with omitted diagnostic fields and exact-row references;
full remains the default for `session`; history search now defaults to dialogue
snippets with exact source references. See [HISTORY-SEARCH.md](HISTORY-SEARCH.md)
for scopes, filters, grouping, centred context and batch original retrieval.
Exact `message_id` lookup checks session identity and
ownership before returning anything. Byte-paged exact row JSON is available to the
row's authorized reader, including guests, without operator artifact access. See
[TOKEN_EFFICIENCY.md](TOKEN_EFFICIENCY.md) for those bounded presentation contracts.
No projection rewrites the ledger or the active conversation.

Oversized tool output is kept as hashed
JSON under `data/tool-results/` and retrieved with `tool_result`. Views are created
once (2,000 lines / 50 KiB per text field), saved, and replayed unchanged. Artifacts
are node-local, not automatically replicated or pruned. Back them up with the DB.
Independent `read_many` batches now pack whole results into budget-sized cached
pages rather than discarding large items into artifact-only slots. Scope-fenced
SQLite cursors preserve the original snapshot and resume after interpreter restart;
this does not increase the global budget or imply current file freshness. See
[BATCH-TOOLS.md](BATCH-TOOLS.md). Other batch projections remain unchanged.

## Prompt caching (KV reuse)

We resend the whole conversation every turn; the provider keeps the KV cache for
the identical **prefix** and only computes the new suffix. Measured on this
provider: turn 2 of a session reported `cached_tokens: 3328` of `3560` prompt
tokens — **93% of the input was reused**, and cache hits bill at roughly a tenth
of misses.

The prefix is stable by construction: `system (+AGENTS.md) → tools → transcript`,
append-only, deterministic tier order. New progressive sessions keep bootstrap
schemas stable and load optional exact definitions in tool results, not by
rewriting the first message. Existing conversations retain their full surface;
see [PROGRESSIVE-ENVELOPE.md](PROGRESSIVE-ENVELOPE.md). Definitions remain in full
history and may need rediscovery after compaction; the session's hash-fenced loaded
names do not prove model awareness. Each llm span records a `prefix`
fingerprint so a cache-hostile change is visible rather than mysterious.

What invalidates it: **compaction** (rewrites the middle), **editing AGENTS.md**
(it is the first block), and **changing the tool set**. Hence:

- compaction is rare and in large chunks (`reserve` 16384 / `keep` 20000, like pi)
  rather than frequent and small — one invalidation instead of many;
- the summarisation call itself is marked `cache = false`, which omits the
  conversation routing key; it does **not** disable a provider's automatic cache;
- `prompt_cache_key` (a hash of the session id) pins a conversation to one cache
  shard; `WASM_AGENT_PROMPT_CACHE_KEY=auto|on|off` controls it, and
  `WASM_AGENT_PROMPT_CACHE_RETENTION` asks for extended retention.

Reasoning replay is **prefix-stable by design, and that is a cost rule, not a taste.**
Reasoning is ~half of an average long request, which makes it look like the first place to
cut. It is not. A thought is sent in full during its own turn; any policy that later
replaces it with an empty field changes a message that was already sent, so the provider's
longest-common-prefix ends there and every message after it is recomputed at the full input
rate. Measured with the provider's own `prefix_audit`: full replay and consistent omission
are `append_only` across turns, while emptying a sent thought is `rewritten` (diverging at
the first prior thought). Input bills at ~50x the cache-read rate and the recomputed suffix
contains the dropped reasoning, so a partial replay costs far more than the cached read it
saves. The replay decision is therefore **all-or-nothing**: `WASM_AGENT_REASONING_REPLAY=0`
omits the field on every message (also append-only, proven against this provider), and there
is deliberately no "window". The lever that does reduce reasoning without breaking the
prefix is `WASM_AGENT_REASONING` (produce less of it).

A shard can also be chosen by *header*, and then the header belongs to the
conversation exactly as the key does. OpenCode Go documents one — "Send a stable
session ID in `x-opencode-session` for each conversation so we can optimize
routing and prompt caching" — and lists clients that omit it as problematic. This
node sent the constant `wasm-agent` for every conversation, which is a header that
is present and a routing decision that is not: every conversation landed on one
shard. The rule now lives per host in `ATTRIBUTION` (`lua/core/provider.lua`),
matched on the base URL rather than the profile's name, and a provider whose host
has no entry fails `scripts/test.sh` instead of silently receiving the wrong
instruction. Each request records the rule it used (`attribution` in the llm
start payload), so a miss in the ledger can be read against the routing that
produced it.

Cached tokens are accumulated and shown in the status balloon; when
`WASM_AGENT_MODEL_RATES` is set (USD per million tokens, per model) the balloon
also shows the session's cost, with cache reads priced separately.

## AGENTS.md — the only automatic injection

Execution-role instructions are also instruction files: operators load
`AGENTS.orchestrator.md`, children load `AGENTS.subagents.md`, and guests receive
neither. They do not inject memory or grant capabilities. See
[the role-file contract](ORCHESTRATOR-WORKSPACE.md#instructions-and-envelope).

Read fresh every turn (so editing takes effect immediately) and appended to the
system prompt as "Project instructions". This is deliberate: project rules are
the one thing that should always be present, and everything else is retrieved
on demand.

It is **scoped by role**, because the operator instructions name internal paths
and the deploy shape, and a guest can ask the model to repeat its own context:

| role | env override | then |
| --- | --- | --- |
| `master` | `WASM_AGENT_AGENTS_MD` | `~/.wasm-agent/AGENTS.md` (the user's global file), then every `AGENTS.md` from `/` down to the session workdir, all injected |
| `guest` | `WASM_AGENT_AGENTS_MD_GUEST` | `./AGENTS.guest.md`, `~/.wasm-agent/AGENTS.guest.md` |

Installers do not write `~/.wasm-agent/AGENTS.md`: it is the user's own file. An older
`scripts/install.ps1` seeded it with the repo's `AGENTS.md`; the deploy and the installer retire
an unedited seed to `AGENTS.md.seeded-backup` and warn about an edited one
(`scripts/lib/seeded-agents-md.sh`). See `docs/LAYERED-PROMPT.md` for the order.

A guest deliberately does **not** fall back to `AGENTS.md`: falling back would
hand the operator instructions to exactly the role they are hidden from. A node
with no file for that role runs uninstructed, so each turn records the resolved
path on its first llm span (`agents_md`), and a configured-but-unreadable path
emits a visible warning rather than passing silently.

## Observability: the trace

Each assistant turn carries `trace`: an ordered list of spans.

```json
[{"kind":"llm","model":"deepseek-v4.1-flash","ms":2478,"tokens":{"prompt":…,"completion":…,"total":…},"ok":true},
 {"kind":"tool","name":"remember","ms":1,"ok":true, "round":1},
 {"kind":"llm","model":"…","ms":1384,…}]
```

Rendered in **engine → sessions** as `llm 2478ms → tool(remember) 1ms → llm 1384ms`,
so a slow or failing step is obvious. Failures keep `ok:false` and the error text
on the message, so `search_messages` can find "where does this keep failing".

## Replication — diff sync (implemented)

Transcripts start per node (a turn on `node-b` lives in node-b's SQLite). Sync is
a **diff, not a dump**: every local mutation appends to a `journal` (monotonic
`id`, `kind`, `origin`, JSON `payload`), and each node keeps a `sync_cursors`
cursor per peer.

- `wa_sync_tick` ships `journal_since(cursor, 200)` to each peer in
  `WASM_AGENT_SYNC_TO`, signed with the node key; on `200` the cursor advances.
  The host runs it on a timer (non-blocking accept loop in `serve::run`).
- `POST /sync/push` verifies the peer (`bad_signature`/`unknown_caller`/
  `stale_request`) and applies entries **idempotently**; an entry is never
  echoed back (its `origin` is checked).
- Kinds: `message`, `session` (last-writer-wins on `updated_at`), `memory`
  (dedupe by the unique index), `run`. Traces replicate with the message, so the
  remote copy is as debuggable as the original.

**A durable log's vocabulary changes in eras, not renames.** The journal is never rewritten, so an
entry written before the rename still says `turn` and one written after says `message`. A reader accepts
both - the old word is a *matcher for an era*, not a second vocabulary - and the migration records the
boundary in `meta` (`journal_kind`, `journal_kind_legacy`, `journal_kind_changed_at`) so a later reader
splits the log by era instead of inferring it from the commit graph. Nothing is pruned: the journal is
read only by the sync loop and never enters a prompt, so its old words cannot mislead an agent, while
the entries themselves are the record of what happened.

Verified: node-b pushed 6 entries to openclaw (cursor 2→8, the host's session
went 2→6 messages, traces included); a second tick pushed `0` (idempotent).

**Endpoint resolution is solved by the relay**: a node with no routable address
advertises no endpoints, attaches to the relay by long-poll, and is reached
through it. `nodeslib.request` tries a direct endpoint first and falls back to
the relay, so nothing above it needs to know which path was taken.

Verified with **separate databases** (the earlier test was invalid: two nodes on
one machine share `~/.wasm-agent/memory.db`, so it proved nothing). With
`--db /tmp/node-a.db` and `--db /tmp/node-b.db`: node-b's turn landed in the
host's database via the relay, traces included.

Two bugs this surfaced, both fixed:

- a 200 carrying an error body ("rejected") was treated as success and the sync
  cursor advanced anyway — **silent data loss**;
- `apply_entry` built SQL parameters as a Lua array literal containing nils
  (`parent_session_id`, `ended_at`, `session_id`), which is a *sparse* array and
  made the JSON encoder throw, rejecting the whole batch.

## The memory seam (`wa:memory`, `WA_MEMORY_COMPONENT=1`)

The store's *logic* can be served by a component; the file cannot. `memory.db` stays in the kernel
(durability, locking, backups, the retention rule), and a component gets statements instead of a file
handle: `wa:kernel/sql`, scoped by the component's manifest to named tables.

| part | where | why |
| --- | --- | --- |
| recall ranking, the two recall passes, term extraction, scope rules, transcript search, the derived session state, the retention decision | the `memory` component (`wa:memory`, `rust/components/memory`) | changes often, hot-swappable |
| the SQLite file, its transaction, the replication journal, the pin | the kernel (`rust/wa-kernel-runtime/src/sql_host.rs`, `memory_host.rs`) | must survive any component swap |

`lua/core/memory.lua` routes `remember`/`recall`/`forget`/`memories`/`search_messages`/
`list_sessions`/`prune` through `host.memory` when `WA_MEMORY_COMPONENT=1`; **without it every
function runs the code it always ran**. A component that is missing, wedged, refused or failing falls
back to that native path with one log line naming the reason (once per operation and reason — a
wedged component must be visible, and a line on every recall is not visible) and never with a silent
empty result: "the store is empty" and "the component did not answer" are different facts.

The grant is enforced by SQLite, not by reading the statement: every statement runs under an
authorizer that answers per table, column, pragma and function. A read outside the granted tables, a
write outside the writable ones, `ATTACH`/`DETACH`, every write `PRAGMA` (only read-only introspection
is allowed), DDL, `load_extension` and a second statement in one string are refused by the engine
itself, and each refusal is counted and appended to `<components>/memory.sql-audit.log` (the action
and the table, never a value from the database). A table's FTS shadow tables belong to the table the
grant names, so `memories_fts_data` and friends are reachable exactly when `memories_fts` is.

The manifest is the grant:

```json
"capabilities": { "sql": { "database": "memory",
                           "read": ["memories", "memories_fts", "messages", "messages_fts", "sessions"],
                           "write": ["memories", "memories_fts"] } }
```

Note what is *not* writable: `journal`. A journal entry's `origin` is the node's identity, and a
component never names itself (`wa:bus` says the same about a publisher). Instead the kernel writes
that row **inside the component's transaction**: `wa:kernel/sql` has a unit of work the kernel owns
(`begin-unit` ... `commit-unit`, with `rollback-unit`), the component writes its rows inside it, and
`commit-unit` appends the journal row and commits in one SQLite transaction.

```wit
begin-unit:  func() -> result<_, error>;                             // BEGIN IMMEDIATE, on this call's connection
commit-unit: func(entry: option<journal-entry>) -> result<_, error>;  // journal row, then COMMIT
rollback-unit: func() -> result<_, error>;                           // discard

record journal-entry { entity-id: string, op: string, payload: string }  // the log's verb and the peer's JSON
```

**Both or neither.** A crash can now leave the fact and its replication entry, or neither, but never
the fact alone — the gap the second transaction used to have is gone. A journal row that cannot be
written (no origin configured, an unknown verb, a payload that is not a JSON object, an oversized
one) is a refusal and the unit is rolled back, so a mutation the kernel cannot journal is not stored
instead of being stored unreplicated. `journal` stays out of every manifest's write grant: the kernel
prepares that one statement with the authorizer removed and the guard restored immediately, and a
guest statement that names `journal` is still refused (tested in `sql_host`). The entry's `origin`
comes from the node (the request's `origin`, resolved by the caller exactly as before), never from the
guest.

**The deadlines are measured, not guessed.** Every call has its own deadline (the guest's epoch, so a
wedged guest is stopped rather than waited for) and every statement has one a second above it, so a
statement cannot outlive the call that started it. The per-operation numbers are 10 × the p99 measured
**through the component** on a realistic store — 10 000 facts, 50 000 messages, FTS, 500 threads —
with a 1 s floor (`scripts/bench-memory-component.sh`, `rust/wa-memory-bench`; the runs and their
spread are in `REPORT.md`):

| operation | p99 (ms) | 10 × p99 | deadline |
| --- | --- | --- | --- |
| `remember` | 6.7 | 67 | 1 000 (floor) |
| `recall` | 120 (worst pass) | 1 200 | 1 500 |
| `forget` | 22 | 219 | 1 000 (floor) |
| `list` | 17 | 168 | 1 000 (floor) |
| `search_messages` | 455 (a common word matching every message) | 4 550 | 5 000 |
| `sessions` | 31 | 310 | 1 000 (floor) |
| `retention` | 4 | 40 | 1 000 (floor) |

The single 2 s default it replaces was wrong in both directions: `search_messages` on a store whose
transcript is full of one word measured p99 455 ms, so a 2 s call was only 4 × p99 and a loaded node
would have pushed a legitimate query to the native fallback, while a `remember` (p99 7 ms) had 300 ×
more room than it needed. The seam's own cost — instantiate, link, open the scoped connection, cross
the boundary — is 5-15 ms of each call; the rest is SQLite. `WA_MEMORY_COMPONENT_TIMEOUT_MS`
overrides the table for an unusual store; the risk that carries is named in the module, and a deadline
that fires is not data loss (the native path answers with one log line) but the same query run twice.

The measurements come from a shared machine: the same operation's p99 moved by up to 3× while other
builds ran, so the table is 10 × the quiet-run p99 and the floor covers the cheap operations. A store
much larger than 10k/50k will exceed these; re-measure rather than raising a number from intuition.

`WA_MEMORY_COMPONENT_WASM` names a built artifact directly (the same development override
`WA_AGENT_CORE_WASM` gives the agent core; it bypasses the components directory *and* its pin). A node
serves the pinned install; the override exists for a checkout that built the component itself and for
`scripts/test-memory-component.lua`.

Verified by `scripts/test-memory-component.lua` (`scripts/fast.sh`): the same inputs through both
paths must answer the same values field for field — recall (all-term, any-term, scope, exclusion,
accents, punctuation, limit, no terms, no match), the ranking order, `list`, `search_messages`, the
session states *and* their readable detail (including a failed thread's recorded error), forget in
both directions, and the retention refusal. The grant's refusals, the unit of work's atomicity and the
deadlines are tested against real wasm in `cargo test -p wa-kernel-runtime` (`sql_host`,
`memory_host`), including two crash injections: a guest killed mid-call (`memory-crash` writes its
rows, then wedges so the epoch deadline stops it) and a journal entry the kernel refuses — both must
leave **neither** the fact nor the entry.

## Retention

Original transcripts, replication mutations, telemetry, run admissions/events and resource
lease files are preserved by default. `memory.prune`/`prune_journal` return
`nil, retention_evidence_admission_required`; the quiet scheduler reports the same refusal
for a positive retention window. Summary text is not a replacement for original execution
evidence. Explicit maintenance must prove scope, dependencies and recoverable archives
before any retirement. No historical unknown is settled by upgrading this code.

`WASM_AGENT_RUN_EVENT_BATCH=1` opts into stream-event batching (64 events/250 ms,
flushed at non-delta events and reads). Risk: a crash can lose the pending raw stream
tail. Default is synchronous raw-event durability; no equivalence or fan/I/O benefit is
claimed for that opt-in.

## Backups

`lua/core/backup.lua` snapshots every SQLite store under the data/config directories plus the live
database (`VACUUM INTO`, WAL included), checks each copy with `PRAGMA integrity_check`, writes them to
`<config>/backups/<UTC stamp>-<uuid>[-label]/` and retains all recoverable snapshots.
Inventory/read/write/integrity failures are visible; failed or partial backups do not
permit deployment. This is per-store consistency, not one simultaneous multi-store snapshot. `/update` takes one (`pre-update`)
before queueing a deploy and refuses to deploy if it fails, because the new binary migrates the schema
and an older binary refuses a migrated database. By hand:
`WA_SCRIPT=tests/backup-all-stores.lua` shows the call; `dofile("lua/core/backup.lua").run("label")`.

