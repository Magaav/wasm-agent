# wasm-agent

**A coding agent you can hold to account.** One binary, its own memory, a desktop
window, and a way to prove what it did.

Most agents are a loop around an API call: they talk, they edit your files, and when
something goes wrong you have a transcript and no evidence. wasm-agent keeps the
evidence. Every turn is a record you can read, every file change is a diff you can
actually undo, every claim it makes was run before it was made, and the node it runs
on reports its own health to anything that asks — including you.

```
                    ┌──────────────────────────┐
   your machine     │  wa-window (WebView2)    │   round avatar → chat → full screen
                    │  the same UI in a panel  │
                    └────────────┬─────────────┘
                                 │  SSE, one turn at a time
                    ┌────────────▼─────────────┐
                    │  wa serve    (Rust host) │   /health /version /chat /diff /nodes …
                    │  ───────────────────────  │
                    │  Lua core: loop, tools,  │   the agent's decisions live here,
                    │  memory, sessions, skills│   and this is the part that will be WASM
                    └────────────┬─────────────┘
                                 │
              SQLite ledger (append-only) · content-addressed blobs · WASM plugins
                                 │
                    ┌────────────▼─────────────┐
                    │  the fabric: other nodes │   ed25519 identity, rendezvous,
                    │  masters and guests      │   relay, diff replication
                    └──────────────────────────┘
```

## What it does for you

- **Remembers on purpose.** An append-only ledger of everything that happened, and
  explicit memories you can edit. The model reads history; it never rewrites it.
- **Shows its work.** A live token stream, a trace per turn, tool results kept whole,
  and a diff topic per turn showing `+N −M` per file.
- **Undoes for real.** The changed files are stored as content-addressed blobs, so
  *undo* puts the files back — and refuses when the file moved on since, naming the
  file rather than clobbering your newer work.
- **Says what is true about itself.** `/health` is answered without the interpreter,
  so a node inside a ten-minute build still answers. A busy node is never reported as
  a dead one.
- **Can be more than one.** Every node has an ed25519 identity and a name that is its
  worktree. Nodes find each other through a rendezvous, replicate by diff, and can
  call each other; a *guest* node owns no worktree and is read-only until a trusted
  master asks.
- **Can be restarted by something that is not itself.** `wa-sentinel` is a separate
  process with a fixed verb list, a drop-box, an audit log and a wake budget — because
  an agent that can restart the node it is running on will eventually do it mid-turn.
- **Can improve itself.** Self-evolution has been done and written down, with the
  measurements: see [`docs/EVOLUTION.md`](docs/EVOLUTION.md).
- **Is honest about failure.** A failing tool opens its own topic; a skipped test is
  reported as skipped; a refusal says why. "Done" means proven — there is a handoff
  gate in `scripts/handoff.sh` that fails when a claim outruns its evidence.

## Quick start

```powershell
# Windows — installs `wa` on your PATH
powershell -c "irm https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.ps1 | iex"
```

```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.sh | sh
```

Then:

```bash
wa ui                      # the node + the desktop window (or your browser at :8799)
wa chat                    # a turn in the terminal
wa status                  # node, model, context budget, tools
```

Bring your own model — any OpenAI-compatible endpoint:

```
WASM_AGENT_LLM_BASE_URL=https://…
WASM_AGENT_LLM_API_KEY=…
WASM_AGENT_LLM_MODEL=…
```

Without a model configured, `wa` still runs: memory, recall, sessions and the
ledger all work locally.

## How it is built

Two halves, deliberately split by *what changes*:

| | |
|---|---|
| **Rust host** (`rust/wa-host`) | one binary: HTTP + SSE, SQLite, files, hashing, process execution with deadlines, WASM plugins via `wasmtime`, the node fabric, and the embedded Lua 5.4 interpreter. Capabilities only — no agent logic. |
| **Lua core** (`lua/core`) | the agent: the turn loop, prompt assembly, tools, memory policy, sessions, compaction, skills, spells, the node's role rules. This is the part intended to become a WASM component, so it is written to be portable and to ask the host for everything it needs. |
| **UI** (`ui/`) | the chat and control surfaces: web components, a wasm markdown renderer, and a documented design contract in [`DESIGN.md`](DESIGN.md). |
| **Shell** (`rust/wa-window`) | the Windows WebView2 companion: translucent, always-on-top, collapses to a round avatar. It loads the same UI the browser does. |

```bash
cd rust && cargo build --release --offline     # Lua 5.4 is vendored; no network needed
```

## The parts worth reading

- [`DESIGN.md`](DESIGN.md) — the enforced UI contract (reuse before you create, the
  balloon close rule, the 5px scale, where a mode switch lives, capability tiers).
- [`AGENTS.md`](AGENTS.md) — how to work in this repo, including commit provenance and
  the rule that an agent's branch must stay current with `main`.
- [`docs/MEMORY.md`](docs/MEMORY.md) — the ledger, explicit memories, and why they are
  never mixed.
- [`docs/ORCHESTRATION.md`](docs/ORCHESTRATION.md) — what was learned running multiple
  agents against each other, including the failures.
- [`docs/SENTINEL.md`](docs/SENTINEL.md) — the process that owns restarts, and why.
- [`docs/RENDEZVOUS.md`](docs/RENDEZVOUS.md) — how nodes find each other and what a
  guest is allowed to be.
- [`docs/EVOLUTION.md`](docs/EVOLUTION.md) — self-improvement, with the numbers.
- [`ROADMAP.md`](ROADMAP.md) — where this goes: many agents in one window, and a UI
  that orchestrates a fleet.

## Honest limits

This is a working system, not a finished one, and the interesting part of a README is
what it admits:

- **One turn at a time per node.** A single interpreter serves the agent, so a second
  request queues behind the first. That is the current design, and lifting it is the
  first item on the roadmap.
- **The desktop shell is Windows-first.** The node runs anywhere Rust does; the
  WebView2 shell is the part that is Windows-specific today.
- **The window is a rectangle.** A balloon cannot paint outside it. Two containers are
  supported — an in-page balloon (instant, closes on a press outside) and a real view
  window (resizable, movable, survives the chat being collapsed) — and the UI picks.
- **The plugin ABI is a tiny core-module ABI**, not the component model. Typed
  interfaces and WIT are on the roadmap.
- **The Lua core is not yet `wasm32-wasip2`.** That is the portability goal, and the
  reason the split between host capabilities and agent logic is where it is.
- **You supply the model.** Quality, cost and latency are your provider's.

## Working on it

```bash
bash scripts/test.sh          # the gate: every suite, including the ones that must fail
bash scripts/test-ui.ps1      # the UI harness (headless Edge, one line per run)
bash scripts/handoff.sh       # "done" means proven, and this is what checks it
```

Contributions are welcome; `AGENTS.md` is the contract, and the gate is the referee.

## License

MIT. Vendored Lua is MIT — see `rust/wa-host/vendor/lua`.
