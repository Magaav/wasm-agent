# wasm-agent

A portable, local-first agent foundation. This repository starts with the thing
every useful agent needs first: **organized memory** — explicit facts the agent
is told to remember, plus an append-only ledger of what actually happened.

Plain **SQLite** (WAL), **standard library only**, one file per machine. No
cloud, no service, no lock-in. The schema is designed so a change-log
replication layer can be added later without a migration.

## Install

One-liner (installs a `wa` command that talks to your wasm-agent host over SSH;
no Python needed on the client):

```powershell
# Windows
powershell -c "irm https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.ps1 | iex"
```

```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.sh | sh
```

Or install the package itself:

```bash
python3 -m pip install -e .          # from a checkout
PYTHONPATH=src python3 -m wasm_agent --help   # without installing
```

Requires Python 3.10+ and SQLite with FTS5 (bundled with CPython).

## Chat

```bash
wa                    # interactive agent chat (default)
wasm-agent chat       # same
```

The agent uses an OpenAI-compatible model (configured via
`WASM_AGENT_LLM_BASE_URL` / `WASM_AGENT_LLM_API_KEY` / `WASM_AGENT_LLM_MODEL`,
falling back to `OPENCODE_GO_API_KEY` / `OPENAI_API_KEY`) and the memory tools
`remember`, `recall`, `search_messages`, `conversation`, `list_conversations`.
Without a model it still runs: `/remember`, `/recall`, `/search` work locally.

Chat commands: `/remember <text>`, `/recall <query>`, `/memories`, `/search
<query>`, `/conversation <id>`, `/stats`, `/help`, `/exit`.

## Use

```bash
wasm-agent init
wasm-agent remember "Laura prefers invoices on the 5th" --tag laura --tag billing
wasm-agent recall "laura invoices"
wasm-agent memories
wasm-agent search "invoice"          # search the message ledger
wasm-agent conversation CONVERSATION_ID
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
