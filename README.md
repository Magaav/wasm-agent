# wasm-agent

A portable agent with **organized memory**, written as a **Rust host + Lua core**.
No Python.

The Rust host is a thin capabilities layer (SQLite, HTTP, hashing, time, files)
and embeds the Lua agent, so `wa` is a single self-contained binary. The agent's
decisions — prompts, tools, the turn loop, memory policy — live in Lua, which is
the part designed to become a WASM component.

```
lua/                 the agent: schema, memory, tools, provider, loop, chat
  core/*.lua
  vendor/json.lua
rust/wa-host/        `wa` binary: host capabilities + embedded Lua 5.4
  build.rs           compiles vendored Lua 5.4 into the binary
  src/lua.rs         Lua C-API bindings
  src/host.rs        host.sql_*, host.http, host.sha256, host.uuid, ...
  src/main.rs        CLI, embedded Lua core, SQLite
```

## Build

```bash
cd rust
cargo build --release --offline     # Lua 5.4 is vendored; no network needed
./target/release/wa --version
```

`rust/Cargo.lock` is committed for reproducible builds.

## Working on this repo

There are two working trees — a cloud instance and a local clone — and **both
push to GitHub**, which is the source of truth. `git pull` before editing,
push after, and keep `core.autocrlf=false` (these files are consumed by Linux
and by `sh`/`lua`; a CRLF checkout breaks them). See `AGENTS.md` for the full
conventions and `docs/` for the design documents.

## Use

```bash
wa                       # interactive chat (default)
wa chat
wa remember "Laura prefers invoices on the 5th" --tag laura
wa recall "laura invoices"
wa memories
wa search "invoice"      # over the message ledger
wa conversation <id>
wa stats
```

Chat commands: `/remember`, `/recall`, `/memories`, `/search`, `/conversation`,
`/stats`, `/help`, `/exit`. Without a configured model, `wa` still works in
local mode (`/remember` and `/recall`).

Model provider (OpenAI-compatible) is read from the environment or
`~/.wasm-agent/env`:

```
WASM_AGENT_LLM_BASE_URL=...
WASM_AGENT_LLM_API_KEY=...
WASM_AGENT_LLM_MODEL=...
```

## Install (one line)

The installer puts a `wa` command on your PATH that talks to your wasm-agent
host over SSH — the host runs the Rust agent and holds the memory.

```powershell
# Windows
powershell -c "irm https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.ps1 | iex"
```

```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.sh | sh
```

Override the host with `-HostAlias <name>` (PowerShell) or `WASM_AGENT_HOST`
(shell). The default is `openclaw.ohana`.

## Plugins (WASM)

Tools are WASM modules. Drop `*.wasm` into `~/.wasm-agent/plugins/`
(`WASM_AGENT_PLUGINS` overrides the directory); the host loads each with
`wasmtime` and exposes it to the agent exactly like a built-in tool.

A plugin is a core module exporting:

```
memory                            the module's linear memory
alloc(len: i32) -> i32            guest allocates len bytes for the arguments
describe() -> i64                 packed ptr<<32 | len, JSON {name, description, parameters}
call(ptr: i32, len: i32) -> i64   packed ptr<<32 | len, JSON result
```

Build the example plugin and install it:

```bash
bash scripts/build-plugins.sh        # builds rust/plugins/* and installs to ~/.wasm-agent/plugins
```

`rust/plugins/echo` is a ~56 KB example. The Lua core merges each plugin's
declared schema into the model's tool list and routes unknown tool calls to
`host.invoke`, so a plugin is just another capability.

## Memory model

Two kinds of data, never mixed:

- **Ledger** (append-only, source of truth): observations, conversations,
  messages, sessions, runs. Written only by ingestion.
- **Memories** (explicit, editable, soft-deletable): what "remember this" writes
  and "recall" reads.
- **Derived** (rebuildable, not yet implemented): summaries, embeddings. Never
  the source of truth; always regenerable.

The model reads the ledger and writes explicit memories; it never rewrites the
ledger. See [`docs/DESIGN.md`](docs/DESIGN.md).

## Roadmap

1. Upgrade the plugin ABI from core modules to the **component model + WIT**
   (typed interfaces, capability imports) — the ABI is intentionally tiny today.
2. Compile the Lua core to `wasm32-wasip2` so the brain itself is a component.
3. Event ingestion: browser/WhatsApp events into the ledger.
4. Cross-device replication with secure, server-mediated device binding.

## License

MIT. Vendored Lua is MIT — see `rust/wa-host/vendor/lua`.
