# wa-graph — a wasm-agent-native code graph

A single Rust binary that parses the repository with **tree-sitter**, stores definitions and
references in **SQLite**, and answers the navigation questions the agent currently answers with
grep → read → grep:

```
wa-graph explain <name>     # what is it, what does it use, who uses it
wa-graph path <from> <to>   # how does <from> reach <to> (direction of use)
wa-graph query <text>       # where does this name appear
wa-graph search <concept>   # ranked definitions with coverage and confidence; optional --prefer-implementations
wa-graph caps                # host.* capabilities, ranked by use
wa-graph index | stats
```

It is not a graphify clone. graphify is a general, 40-language, Python-packaged graph. This is the
**wasm-agent-native slice**: the agent's own stack (Rust + Lua + Bash + PowerShell + Markdown), the
node's own SQLite, and *capability-typed* edges (`host.*`) that graphify has no concept of. It is a
workspace member of `rust/` and ships inside the node binary.

## Why

In the 2026-09-21 watch session, roughly a third of the agent's rounds were `grep`/`sed`/`read` just
to find where something is or who calls it. Those are lookups, not reasoning. A deterministic graph
answers them in one call, with no model round trip.

## Measured — the three navigation tasks

Against the real `foundation` tree (**201 files, 7 432 definition nodes, 24 001 references, indexed
in 2.6 s**). "Grep" is `grep -rn`, which returns *candidate lines* and still needs follow-up reads;
wa-graph returns the *answer*.

| Task | grep output | wa-graph | wa-graph output |
|---|---|---|---|
| **Who calls `append_turn`** | 102 lines · 11 851 B | `explain append_turn` | callers grouped: `lua/core/agent.lua:571`, `:831`, plus the test scripts |
| **What resolves `deploy.sh`** | 45 lines · 5 250 B | `explain resolve_script` | `rust/wa-sentinel/src/main.rs:986` + its candidate list and each `Path::join` |
| **Where is a wake routed** | 10 lines · 1 045 B | `query routing_session` | 1 line: `field routing_session  rust/wa-host/src/serve.rs:1817` |

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

## How it works

- **`extract.rs`** — tree-sitter walkers per language emit definition nodes and reference edges.
  Rust: fns/methods/structs/enums/traits/impls/imports/calls/macros. Lua: module functions,
  `require`, `host.*` capabilities, table fields. Bash: functions, `source`/`.`, command calls.
  PowerShell: `function`, dot-sourcing, `Import-Module`, command calls. Markdown: a `mentions` edge
  only when a backtick span names a real definition.
- **`store.rs`** — SQLite `files`/`nodes`/`edges`/`imports` plus exact source snapshots. Incremental by content hash: a file
  whose bytes did not change is never reparsed. A resolve pass turns a referenced name into a node
  id (same file → same directory → globally unique), follows `require` aliases
  (`memory.append_turn` → `M.append_turn`), and creates a capability node for `host.*`. A whole
  index run is one `BEGIN IMMEDIATE` transaction: a reader sees the old graph or the new one, never
  a half-indexed file, and the watcher and a manual `index` cannot interleave.
- **`watch.rs`** — a `notify` watcher (debounced) refreshes the index. It registers before
  its initial scan and logs errors. Host queries independently verify all in-scope source
  bytes and rebuild or fail closed, so missed events do not silently serve old results.
- **`main.rs`** — the CLI above, with `--json` on every read verb.

## Node integration

The node exposes the graph as `host.graph_index|query|search|source|overview|impact|explain|path|caps|stats|status`; a Lua run
queries its own code. `lua/core/graph.lua` wraps them and degrades cleanly when the host is older.
The model reaches it through the **`graph` tool**. `search_symbols` ranks definitions using visible
lexical and incoming-edge evidence; `symbol_source` returns the selected syntax definition from
the exact stored snapshot, paging only when it exceeds the response budget. Relationship and audit
verbs remain available. The node keeps the graph fresh, so `index` is rarely needed.

`overview` returns bounded repository orientation with exact section totals.
`impact` maps changed lines to symbols and walks resolved callers and dependencies
with call-site and resolver evidence. Its cursor is bound to both the request and
graph generation. The output states its incomplete dynamic-call scope and does
not manufacture a risk score. Search uses deterministic BM25-like field weights,
identifier tokenization, and a visible score breakdown; it does not require an
embedding service or model download.

The database lives at `<home>/.wasm-agent/graph.db` and indexes the runtime worktree (the node's
cwd). `WA_GRAPH_ROOT` / `WA_GRAPH_DB` override both; `WA_GRAPH_WATCH=0` disables the watcher. Reads
pin a read-only graph snapshot and verify source bytes; a stale query may rebuild and take the
write lock. This is source-snapshot consistency, not an atomic freeze of concurrent external
writers or of code already loaded in a worker. See
`docs/GRAPH.md` and `docs/HOST.md`.

## Proven

`cargo test -p wa-graph` covers extraction, resolution, atomic writes, watcher startup,
and exact-byte freshness:

- extraction for Rust, Lua, JavaScript/TypeScript, Bash and PowerShell (functions, imports, calls, capabilities);
- a Lua definition is emitted **once** (the `variable_declaration` → `assignment_statement` nesting);
- `memory.append_turn` resolves through `local memory = require('core.memory')` to `M.append_turn`;
- reindex is **incremental**: unchanged bytes are not reparsed, a changed file replaces its old
  definitions, a removed file is dropped;
- the watcher indexes the root on startup;
- a reader never sees an uncommitted index write (the run is one `BEGIN IMMEDIATE` transaction);
- `path a c` goes through `b`, follows edges in the **direction of use** (never back up to a
  caller, never through a shared callee), and **ignores doc mentions** (a mention is lookup, not traversal).
- resolution provenance survives storage and is exposed with each resolved edge;
- architecture sections are bounded without losing exact totals;
- patch impact follows callers and tests transitively, pages deterministically,
  and rejects a cursor after the source generation changes.

The repository gate (`scripts/test.sh`) runs these alongside the rest, and the live node was verified
end to end: start → index, add a file → it appears, edit a file → the old definition is gone.

## Honest limitations

- **Semantics stop at names.** Trait/generic identity is not modelled, and a call through a
  differently-named module alias can resolve to a same-named test stub instead of the real
  definition. This is the multi-month part graphify spent years on; the resolver stops at
  "resolvable by name, same-file beats same-dir beats unique."
- **Doc mentions are filtered hard.** A mention is kept only when it names a real node; an
  unresolved mention is deleted, not stored.
- **Search ranking is lexical, not semantic.** Synonyms absent from names, signatures, and paths
  can miss. Low-confidence and absent results require a grep fallback.
- **A definition is not its whole context.** Source retrieval omits surrounding imports, sibling
  attributes, and module state; inspect those before editing.
