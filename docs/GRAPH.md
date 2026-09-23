# The code graph

The node indexes its own source with `wa-graph` and exposes it to Lua as
`host.graph_*`. A run asks "what is `append_turn` and who calls it" in one call
instead of a grep plus a read of every candidate. The design and measurements
live in `rust/wa-graph/README.md`; this is the operator and integration view.

## What it is for

`grep` returns candidate lines; the graph returns the answer. The measured shape
on the real tree is in the crate README: "who calls `append_turn`" goes from 102
grep matches to one call, and "what resolves `deploy.sh`" from 45 matches to the
resolver plus its candidate list.

It is deliberately *not* a general code-intelligence engine. It indexes seven
grammars (Rust, Lua, JavaScript/TypeScript, Bash, PowerShell, Markdown), resolves
references by name,
and treats a `host.*` call as a typed edge to a capability — so the graph is also
a control graph, not only a map.

## Where it lives, and how fresh it is

| | |
|---|---|
| database | `<home>/.wasm-agent/graph.db` (beside the ledger) |
| indexed root | the node's cwd — the runtime worktree it runs from |
| freshness | a `notify` watcher reindexes on change, debounced |
| write path | one `BEGIN IMMEDIATE` transaction per index run — atomic, and it serializes writers |
| read path | read-only SQLite connection, never the write lock |
| overrides | `WA_GRAPH_ROOT`, `WA_GRAPH_DB`; `WA_GRAPH_WATCH=0` disables the watcher |

The watcher indexes once on startup, **off the accept path**, so a large tree
never delays the port coming up. A query before the first index finishes returns
an empty result, not an error. Reindexing is incremental by content hash, so an
event that did not change bytes costs nothing.

The whole reindex is one `BEGIN IMMEDIATE` transaction. A reader sees the old
graph or the new one, never a half-indexed file, and the watcher and a manual
`host.graph_index` cannot interleave. Readers are unaffected (WAL): they keep the
previous snapshot until the index commits.

## The capability

`host.graph_index|query|explain|path|caps|stats|status`. Each returns a JSON
string, and an error as `{"error": ...}` — the same shape as `host.sql_query`.
`graph_status` reports the resolved root/db and whether the index exists yet.

`lua/core/graph.lua` wraps them and compacts the results (a well-connected
function can have hundreds of callers; the model needs the shape and the first
few places to look). It tolerates a host that predates the capability and reports
`graph_unavailable`.

`explain` reports incoming callers at the exact call line, not the enclosing
function's definition line. Exact names and qualified-member suffixes suppress
unrelated substring definitions. `path` includes each hop's call-site line as well as its destination
definition. `query` ranks symbol-name matches before path and
detail matches and returns 12 compact rows by default, with `truncated` when
more matches exist. Pass a larger `limit` only when those rows are insufficient.
Runtime routes rank before test-only route literals.
The Lua extractor also treats a statically named first argument to `pcall` or
`xpcall` as a call edge, so a path can follow that common wrapper.
Rust literal `lua.call_string("entrypoint", ...)` calls bridge to the exported
Lua function, and literal HTTP paths are queryable as `route` nodes. An
extractor-version stamp forces unchanged files to reindex after this upgrade.
`host.*` edges always resolve to capability nodes, even when an unrelated
source function has the same final name.

## How the model reaches it

The `graph` tool is the model surface (`explain`/`query`/`path`/`caps`/`stats`/
`index`), in the `environment` tier. `skills/code-graph/SKILL.md` tells a fresh
context to use it before `grep` and how to read the result — including that a
`caller` without a `-> path:line` is an unresolved name, not a fact.

## Limits worth knowing before trusting a result

- Resolution is by name. `require` and `dofile` aliases resolve; a call through a
  differently-named module alias can land on a same-named stub. Builtins and
  externals (`print`, `dofile`, Rust `std::`) stay unresolved on purpose - they
  have no definition in the tree, so they are not a gap to close. If an expected
  caller is missing, confirm with `grep`.
- `path` is directional: it follows A's calls/imports *down* to B, never back up to
  A's callers, and it does not treat a shared callee as connecting two functions.
  "How does A reach B" and "who calls B" are different questions; the second is
  `explain`.
- Markdown contributes `mentions` edges only when a backtick span names a real
  definition; `path` traversal ignores mentions entirely.
- The graph is a map. Always read a file before editing it.
