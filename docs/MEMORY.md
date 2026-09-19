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
| `ledger_messages` / `conversations` (+FTS) | **the external inbox/ledger** (WhatsApp, mail) | `search_messages`, `conversation` |
| `messages` (+FTS) | **the agent's own dialogue** — its transcript | `sessions`, `session`, `search_turns`, `resume_session` |
| `runs` | effect/settlement record per run | (internal) |

`ledger_messages` holds other people's messages; `messages` holds the agent's transcript.
`runs` is not the conversation — it is one row per completed ask-and-answer.
Older databases used `messages` for the external ledger and `turns` for the transcript.
The shape migration renames both before applying the new schema. It also renames
`harness_events.turn_id` and `runs.turn_id` to `run_id`, preserving their rows.
Once migrated, an older binary is incompatible and must not be restarted against
that database. Back up the database and install the matching binary in one upgrade.

## Sessions are resumable threads

A session is keyed by `(user_id, node_id)`: talking to `node-b` is a different
thread from talking locally, and a guest's threads are their own. `ensure_session`
reuses the newest open session for that pair, so a restart continues the thread
instead of starting a new one.

`messages` holds `seq, role (user|assistant|tool|summary), content, tool_calls,
tool_call_id, tool_name, tokens, ms, ok, debug, trace`. **The transcript is the
context**: `agent.lua` rebuilds the provider messages from it every turn
(system + AGENTS.md + summary + turns after the watermark). There is no separate
in-memory message list, which is what makes restarts resumable.

## Unfinished sessions (recovery)

A session is unfinished when its transcript just *ends* — after a question, after a
tool result, or after a decision whose tools have no recorded result. That shape is
indistinguishable from "the answer is still coming": a process that was killed cannot
write a flag saying so (the exit path that would set one does not run), and a process
that is *alive* cannot write one either, because it has not stopped. Nothing in a row
tells the two apart.

The state was once called `interrupted`, and the word was wrong in a way that cost
credibility rather than data: a live 426-turn run was reported as interrupted on every
poll while it was demonstrably writing turns, and `wa resume` would have written a
durable "the process died" record for a thread that had not. A name that asserts an
event we cannot observe is a claim the code should not make, so the derived state is
`unfinished` and the notice says both possibilities out loud.

So the **state is derived from the ledger**, which is appended to as the turn
proceeds. The last turn is an exact record of how far the process got:

| state | last turn | meaning |
| --- | --- | --- |
| `empty` | none | nothing said yet |
| `answered` | assistant reply | the thread is settled |
| `failed` | assistant with `ok=0` | the model call errored — a **landed** outcome, not an unfinished one |
| `unfinished` | user, tool, or assistant with `tool_calls` | no answer is recorded after this turn; the process may have stopped or may still be working |

`memory.session_state(id)` returns that, plus where it stopped and which calls of the
last decision have no recorded result: "1 of 2 never reported" is a different fact
from "nothing ran", and only the decision knows which — when the process dies between
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
found by `search_turns`.

Not to be confused with the `resume_session` **tool**, which folds a past session into
the current one's context: that is a recall aid, this is crash recovery.

Verify with `scripts/test-recovery.lua` (run by `scripts/test.sh` and by
`scripts/test-windows.ps1`): it builds each shape by hand, because a killed process
leaves a specific shape in the ledger and that shape is the contract — a test that
kills a child asserts the timing of a signal instead.

To see it for real rather than in a fixture, start a turn that asks for a slow tool
call, kill the process while the tool is running, and read the thread back — the
ledger keeps the decision with no result, and `wa resume` names the call:

```sh
wa --db /tmp/kill.db chat "Run exactly this bash command with bash, then repeat its output: ping -n 8 127.0.0.1" &
sleep 7        # mid tool call, after the decision was written
kill %1
wa --db /tmp/kill.db resume
#   waiting: 1 thread
#   544e4e9c  turns=2  1 tool call(s) never reported: bash, 5s ago
#             recover   wa resume --session 544e4e9c "continue where you stopped"
```

Caveat: the notice is a `system` message placed after the first one, verified against
the provider this node uses. If an endpoint rejects a mid-conversation system
message, it should become a `user` turn instead (the runaway guard already does that):
recovery must not be the thing that breaks the request.

## Two recording modes

| | `default` | `debug` |
| --- | --- | --- |
| tool payloads | stable bounded view + retrievable original JSON artifact | same, plus debug request capture |
| retention | **100% for 7 days**, then pruned | **kept forever** |
| purpose | everyday use, small DB | reproduce a failure, build a fixture |

Flip it with `session_debug{mode}` (or the button in **engine → sessions**).
The workflow: spot a task failing → turn debug on → reproduce it → export the
fixture → fix → re-run the fixture as a regression test.

## Compaction (automatic, like pi)

When the assembled request approaches the selected model's capacity minus its
reserve (Pi's defaults: 16,384 reserved, 20,000 recent tokens kept), an older prefix is summarised into `sessions.summary` and
`summarized_until` moves forward. The summary is produced by
`WASM_AGENT_LLM_SUMMARY_MODEL` if set, otherwise by the main model.

An explicit positive `WASM_AGENT_CONTEXT_BUDGET` can trigger earlier; there is no
default 64K cap. Every unsummarized ledger row participates, without a 500-row gap.
Context estimates use the last measured request plus trailing messages when valid,
otherwise text bytes/4 and Pi's 1,200-token image estimate. Neither is a tokenizer.

The summarizer receives full user/assistant text, reasoning and tool arguments;
large tool results get explicit 2,000-byte excerpts with artifact references.
Oversized backlogs are summarized in bounded prefixes. Empty, output-limited or
tool-calling summaries cannot advance the watermark. Summary usage is billed in
the durable telemetry totals, including unsuccessful attempts.

Summaries are **lossy interpretations**, not lossless compression. The retained
original transcript is the evidence, accessible via `session`/`search_turns`;
`session` supports `before_seq` pagination. Default transcript retention remains
seven days; debug transcripts persist. Oversized tool output is kept as hashed
JSON under `data/tool-results/` and retrieved with `tool_result`. Views are created
once (2,000 lines / 50 KiB per text field), saved, and replayed unchanged. Artifacts
are node-local, not automatically replicated or pruned. Back them up with the DB.

## Prompt caching (KV reuse)

We resend the whole conversation every turn; the provider keeps the KV cache for
the identical **prefix** and only computes the new suffix. Measured on this
provider: turn 2 of a session reported `cached_tokens: 3328` of `3560` prompt
tokens — **93% of the input was reused**, and cache hits bill at roughly a tenth
of misses.

The prefix is stable by construction: `system (+AGENTS.md) → tools → transcript`,
append-only, deterministic tier order. Each llm span records a `prefix`
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

Cached tokens are accumulated and shown in the status balloon; when
`WASM_AGENT_MODEL_RATES` is set (USD per million tokens, per model) the balloon
also shows the session's cost, with cache reads priced separately.

## AGENTS.md — the only automatic injection

Read fresh every turn (so editing takes effect immediately) and appended to the
system prompt as "Project instructions". This is deliberate: project rules are
the one thing that should always be present, and everything else is retrieved
on demand.

It is **scoped by role**, because the operator instructions name internal paths
and the deploy shape, and a guest can ask the model to repeat its own context:

| role | env override | then |
| --- | --- | --- |
| `master` | `WASM_AGENT_AGENTS_MD` | `./AGENTS.md`, `~/.wasm-agent/AGENTS.md` |
| `guest` | `WASM_AGENT_AGENTS_MD_GUEST` | `./AGENTS.guest.md`, `~/.wasm-agent/AGENTS.guest.md` |

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
on the turn, so `search_turns` can find "where does this keep failing".

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
- Kinds: `turn`, `session` (last-writer-wins on `updated_at`), `memory`
  (dedupe by the unique index), `run`. Traces replicate with the turn, so the
  remote copy is as debuggable as the original.

Verified: node-b pushed 6 entries to openclaw (cursor 2→8, the host's session
went 2→6 turns, traces included); a second tick pushed `0` (idempotent).

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

## Retention

`memory.prune(7)` deletes non-debug turns older than 7 days and vacuums their FTS
rows. Debug sessions are never pruned. Summaries outlive their turns (they are
the compressed value), so a years-old session still contributes its conclusions
without carrying the raw trace.
