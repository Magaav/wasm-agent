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
| `messages` / `conversations` (+FTS) | **the external inbox/ledger** (WhatsApp, mail) | `search_messages`, `conversation` |
| `turns` (+FTS) | **the agent's own dialogue** — its transcript | `sessions`, `session`, `search_turns`, `resume_session` |
| `runs` | effect/settlement record per turn | (internal) |

`messages` is *not* "what we talked about" — it is other people's messages.
`runs` is not the conversation — it is one row per completed turn.

## Sessions are resumable threads

A session is keyed by `(user_id, node_id)`: talking to `node-b` is a different
thread from talking locally, and a guest's threads are their own. `ensure_session`
reuses the newest open session for that pair, so a restart continues the thread
instead of starting a new one.

`turns` holds `seq, role (user|assistant|tool|summary), content, tool_calls,
tool_call_id, tool_name, tokens, ms, ok, debug, trace`. **The transcript is the
context**: `agent.lua` rebuilds the provider messages from it every turn
(system + AGENTS.md + summary + turns after the watermark). There is no separate
in-memory message list, which is what makes restarts resumable.

## Two recording modes

| | `default` | `debug` |
| --- | --- | --- |
| tool payloads | truncated (600 chars) | verbatim |
| retention | **100% for 7 days**, then pruned | **kept forever** |
| purpose | everyday use, small DB | reproduce a failure, build a fixture |

Flip it with `session_debug{mode}` (or the button in **engine → sessions**).
The workflow: spot a task failing → turn debug on → reproduce it → export the
fixture → fix → re-run the fixture as a regression test.

## Compaction (automatic, like pi)

When the transcript approaches the context budget (`WASM_AGENT_LLM_CONTEXT` minus
a reserve, at 70%), the older half is summarised into `sessions.summary` and
`summarized_until` moves forward. The summary is produced by
`WASM_AGENT_LLM_SUMMARY_MODEL` if set, otherwise by the main model.

The transcript keeps **everything**; only the *context* is windowed. Nothing is
silently forgotten — it moves from context into the summary, and remains readable
via `session`/`search_turns`.

## AGENTS.md — the only automatic injection

Read fresh every turn (so editing takes effect immediately), from
`$WASM_AGENT_AGENTS_MD`, then `./AGENTS.md`, then `~/.wasm-agent/AGENTS.md`. It
is appended to the system prompt as "Project instructions". This is deliberate:
project rules are the one thing that should always be present, and everything
else is retrieved on demand.

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

## Replication (planned, per node first)

Start per node (a turn on `node-b` lives in node-b's SQLite). When we need a
cluster, sync transcripts **by diff** like a message log: each node keeps a
monotonic `(stream, seq)` cursor per peer and ships new turns; resumable by
cursor, last-writer-wins per turn id. That gives backup-on-the-fly and a global
`search_turns` without a central writer. `runs`/`memories` ride the same channel.

## Retention

`memory.prune(7)` deletes non-debug turns older than 7 days and vacuums their FTS
rows. Debug sessions are never pruned. Summaries outlive their turns (they are
the compressed value), so a years-old session still contributes its conclusions
without carrying the raw trace.
