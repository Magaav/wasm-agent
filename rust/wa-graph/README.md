# wa-graph — a wasm-agent-native code graph (spike)

A single Rust binary that parses the repository with **tree-sitter**, stores definitions and
references in **SQLite**, and answers three questions the agent currently answers with
grep → read → grep:

```
wa-graph explain <name>     # what is it, what does it use, who uses it
wa-graph path <from> <to>   # how are these two connected
wa-graph query <text>       # where does this name appear
```

It is not a graphify clone. graphify is a general, 40-language, Python-packaged graph. This is the
**wasm-agent-native slice**: the agent's own stack (Rust + Lua + Markdown today; Bash + PowerShell
next), the node's own SQLite, and *capability-typed* edges (`host.*`) that graphify has no concept of.

## Why

In the 2026-09-21 watch session, roughly a third of the agent's rounds were `grep`/`sed`/`read` just
to find where something is or who calls it. Those are lookups, not reasoning. A deterministic graph
answers them in one call, with no model round trip.

## Usage

```sh
cargo build --release            # own workspace, so wasmtime never enters this build
wa-graph index  --root /path/to/foundation
wa-graph explain append_turn
wa-graph path   choose_worker append_turn
wa-graph query  routing_session
wa-graph caps                    # host.* capabilities, ranked by use
wa-graph stats
```

`--db FILE` or `WA_GRAPH_DB` select the database (default `<root>/.wa-graph/graph.db`).
`--json` is available on every read verb, for a future `host.graph_*` tool result.

## Measured — the three navigation tasks

Against the real `foundation` tree (~150 files, ~5.6k definition nodes, ~20k references, indexed in
**1.3 s**). "Grep" is `grep -rn`, which returns *candidate lines*, so it still needs follow-up reads;
wa-graph returns the *answer*.

| Task | grep output | wa-graph | wa-graph output |
|---|---|---|---|
| **Who calls `append_turn`** | 102 matches · 11 851 B | `explain append_turn` | 1 call, callers grouped: `lua/core/agent.lua:571`, `:831`, `scripts/test-append-race-worker.lua` |
| **What resolves `deploy.sh`** | 41 matches · 4 815 B | `explain resolve_script` | 1 call: `rust/wa-sentinel/src/main.rs:986`, with the candidate list and each `Path::join` |
| **Where is a wake routed** | 8 matches · 815 B | `query routing_session` | 1 line: `field routing_session  rust/wa-host/src/serve.rs:1817` |

The second row is the point: `explain resolve_script` reproduces finding **F1** from
`WATCH-FINDINGS-2026-09-21.md` — the candidate list that silently fails on a service install —
without a read of `main.rs` at all.

## Capabilities are edges, not strings

`wa-graph caps` on `foundation`, ranked by call sites:

```
51  host.getenv        20  host.uuid        8  host.exec       6  host.sql_exec
42  host.sha256        11  host.write_file  8  host.http       6  host.sql_query
```

A `host.<ident>` call in Lua becomes an edge to a `capability` node. A Rust local named `host`
(`host.db.lock().map_err`) is **not** a capability — `is_capability` rejects anything that is not a
clean `host.<ident>`, and the Rust path never emits a capability edge. That makes the graph a
*control* graph: "what am I allowed to call, and who calls it" is a query, not a grep.

## What is proven

`cargo test` — 7 tests:

- extraction finds Rust structs/methods/fns, Lua module functions, `require` imports, capabilities;
- a Lua definition is emitted **once** (the `variable_declaration` → `assignment_statement` nesting);
- `memory.append_turn` resolves through `local memory = require('core.memory')` to `M.append_turn`;
- reindex is **incremental**: unchanged bytes are not reparsed, a changed file replaces its old
  definitions, a removed file is dropped;
- `path a c` goes through `b` and **ignores doc mentions** (a mention is lookup, not traversal).

## Honest limitations

- **Semantics stop at names.** Method identity through traits/generics and Lua `M` vs. a
  differently-named module alias are only partly resolved. This is the multi-month part graphify
  spent years on; the spike deliberately stops at "resolvable by name, same-file beats same-dir
  beats unique."
- **Rust + Lua + Markdown only.** Bash and PowerShell grammars are pinned and compile; their
  extractors are not written yet.
- **Doc mentions are filtered hard.** A mention is kept only when it names a real node; an
  unresolved mention is deleted, not stored.
- **No watcher yet.** Reindex is incremental but on demand; `notify` for live freshness is the next
  step, not done.
- **Not wired into the node.** `host.graph_*` does not exist yet. This crate is the measurement that
  justifies building it.

## Integration (next)

1. `host.graph_query | graph_explain | graph_path` in `wa-host`, opening the DB read-only — the
   capability surface, so a Lua run can query its own code.
2. Index at deploy (or on first use) into `<node-home>/.wa-graph/graph.db`, beside the ledger.
3. A `notify`-driven reindex so the graph is always fresh.
4. Bash + PowerShell extractors.
