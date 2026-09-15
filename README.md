# wasm-agent

A portable, local-first agent foundation. This repository starts with the thing
every useful agent needs first: **organized memory** — explicit facts the agent
is told to remember, plus an append-only ledger of what actually happened.

Plain **SQLite** (WAL), **standard library only**, one file per machine. No
cloud, no service, no lock-in. The schema is designed so a change-log
replication layer can be added later without a migration.

## Install

```bash
# from a checkout
python3 -m pip install -e .

# or run without installing
PYTHONPATH=src python3 -m wasm_agent --help
```

Requires Python 3.10+ and SQLite with FTS5 (bundled with CPython).

## Use

```bash
wasm-agent init
wasm-agent remember "Laura prefers invoices on the 5th" --tag laura --tag billing
wasm-agent recall "laura invoices"
wasm-agent memories
wasm-agent search "invoice"          # search the message ledger
wasm-agent conversation 15551234567@c.us
wasm-agent stats --json
```

Every command takes `--db PATH` (or `$WASM_AGENT_DB`, default
`~/.wasm-agent/memory.db`) and `--json` for machine output.

## The design rule

Memory is **two kinds of data, never mixed**:

| | Ledger | Memories |
|---|---|---|
| what | observations, messages, sessions, runs | explicit facts a user/agent asked to remember |
| writes | ingestion helpers only | user/agent, editable, soft-deletable |
| truth | append-only, immutable | editable, but always owned by the user |
| search | FTS5 over message bodies | FTS5 over facts |

Anything *model-derived* — summaries, embeddings, client profiles — is
**rebuildable** and must live in separate tables that can be dropped and
regenerated. The model never rewrites the ledger. That is what keeps memory
organized instead of an accumulating pile of notes.

## Library

```python
from wasm_agent import Memory

with Memory() as memory:
    memory.remember("Laura prefers invoices on the 5th", tags=["laura"])
    memory.recall("laura")
    memory.record_message(conversation_id="c1", message_id="m1", body="hello")
    memory.search_messages("hello")
```

The same object exposes session/run history (`start_session`, `record_run`,
`link_run`, `session`) so old agent sessions are queryable next to the world data
they touched.

## Status

`0.1.0` — memory foundation. Ingestion from WhatsApp/browser events, replication
across devices, and the agent loop itself come next. See
[`docs/DESIGN.md`](docs/DESIGN.md).

## License

MIT.
