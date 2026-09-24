# The code graph

The node indexes its own source with `wa-graph` and exposes it to Lua as
`host.graph_*`. A run asks "what is `append_turn` and who calls it" in one call
instead of a grep plus a read of every candidate. The design and measurements
live in `rust/wa-graph/README.md`; this is the operator and integration view.

## What it is for

`grep` returns candidate lines; `search_symbols` ranks definitions and
`symbol_source` returns the selected implementation from the verified snapshot.
Relationship actions answer callers and paths. The measured shape
on the real tree is in the crate README: "who calls `append_turn`" goes from 102
grep matches to one call, and "what resolves `deploy.sh`" from 45 matches to the
resolver plus its candidate list.

It is deliberately *not* a general code-intelligence engine. It indexes seven
grammars (Rust, Lua, JavaScript/TypeScript, Bash, PowerShell, Markdown), resolves
references by name,
and treats a `host.*` call as a typed edge to a capability — so the graph is also
a control graph, not only a map.

## Where it lives, and how fresh it is

The model has two bounded whole-repository views in addition to symbol lookup.
`overview` answers orientation questions with exact totals and clipped sections.
`impact` maps the current patch to changed symbols, then follows resolved callers
and dependencies to likely review and test locations. Impact is reachability
evidence, not a risk score or a correctness certificate.

| | |
|---|---|
| database | `<home>/.wasm-agent/graph.db` (beside the ledger) |
| indexed root | the node's cwd — the runtime worktree it runs from |
| freshness | watcher refreshes in the background; each answer checks exact source bytes before and after its read, synchronously rebuilding or failing if stale |
| write path | one `BEGIN IMMEDIATE` transaction per index run — atomic, and it serializes writers |
| read path | pinned read-only SQLite snapshot; stale queries may synchronously take the write lock to rebuild |
| overrides | `WA_GRAPH_ROOT`, `WA_GRAPH_DB`; `WA_GRAPH_WATCH=0` disables the watcher |

The watcher registers before its initial index, **off the accept path**. A query
before that index finishes builds a verified snapshot itself; it never treats an
unbuilt graph as an empty answer. Reindexing in the watcher is incremental by
content hash. Query-time verification compares the complete target area to the
exact bytes stored with the graph, so a missed event cannot silently return an
old answer. Indexing or verification failures return an error; use `read`/`grep`.

The whole reindex is one `BEGIN IMMEDIATE` transaction. A reader sees the old
graph or the new one, never a half-indexed file, and the watcher and a manual
`host.graph_index` cannot interleave. Readers are unaffected (WAL): they keep the
previous snapshot until the index commits.

This is a verified *source snapshot*, not a claim that a live filesystem or
running Lua interpreter is frozen. An uncoordinated writer can change a file
immediately after verification; absolute real-time guarantees require immutable
revisions or coordinated writes. The graph still resolves syntax by name, so
dynamic calls remain uncertain even when its source snapshot is current.

## The capability

`host.graph_index|query|search|source|overview|impact|explain|path|caps|stats|status`. Each returns a JSON
string, and an error as `{"error": ...}` — the same shape as `host.sql_query`.
`graph_status` reports the resolved root/db and whether the index exists yet.

`lua/core/graph.lua` wraps them and compacts the results (a well-connected
function can have hundreds of callers; the model needs the shape and the first
few places to look). It tolerates a host that predates the capability and reports
`graph_unavailable`.

`search` accepts a multi-term concept or identifier and returns source-ready
`path/name/line/kind` selectors. Its score combines explainable name, signature,
path, and incoming-edge evidence using a deterministic BM25-like lexical score;
`confidence`, `reason`, `matched_terms`, and `score_breakdown` make the heuristic
visible. Identifiers are split across camelCase and snake_case boundaries. It is
lexical ranking, not embedding similarity.
`source` reparses only the selected indexed file and returns the exact syntax
definition. Definitions larger than the response budget continue from a byte
offset. Both calls use the same before/after source verification as relationship
actions.

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

Every resolved edge records how it was selected and a confidence value. Exact
capabilities and import aliases rank above same-file and globally unique-name
fallbacks. `explain`, `path`, and `impact` expose that provenance so a caller can
distinguish strong evidence from a name-based lead.

`overview` accepts optional aspects and a per-section limit. Its response has a
stable graph generation, snapshot freshness, exact totals, and per-section
`total`/`returned`/`truncated` metadata. `impact` accepts a native or Git
changeset, direction, and depth. It maps changed lines to enclosing symbols and
walks resolved non-document edges, returning each hop with its call site,
resolution strategy, and confidence. Paging uses a cursor bound to the request
and graph generation; stale cursors fail instead of mixing snapshots.

## How the model reaches it

The `graph` tool is the model surface (`search_symbols`/`symbol_source`,
`overview`/`impact`, plus `explain`/`query`/`path`/`caps`/`stats`/`index`), in the
`environment` tier.
`skills/code-graph/SKILL.md` tells a fresh
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
- Ranked retrieval is lexical. A synonym absent from names, signatures and paths
  can miss; low-confidence or absent answers fall back to `grep`.
- Definition source omits surrounding imports, sibling attributes and module
  state. Inspect that context before editing.

## Adoption check (Phase 1, 2026-09-23 through 2026-09-24)

The post-fix real-model navigation artifact contains three graph-arm runs and
three controls. Graph-arm runs completed 3/3, chose `grep` first 3/3 times, and
averaged 28,465 tokens and 6 tool calls. Controls completed 2/3, averaged 29,084
tokens and 5 tool calls among the completed runs, and had one token-budget
failure whose artifact incorrectly recorded zero tokens. The artifact did not
persist an independently verified correctness field, so completion is not a
correctness result.

Durable telemetry contained 26 graph calls in ten sessions: 23 navigation, two
patch audits, and one assessment attempt. Twenty of the 23 navigation calls came
from synthetic benchmark runs; the three organic calls did not show a saved
round. This evidence does not establish a speed, token, or correctness advantage.
Keep `grep`/`read` available and compare later phases before changing the default.
The frozen baseline and its limitations are in
[`release/GRAPH_TOOL_PHASE_1.md`](release/GRAPH_TOOL_PHASE_1.md).
The locator-only Phase 2 contract is frozen in
[`release/GRAPH_TOOL_PHASE_2.md`](release/GRAPH_TOOL_PHASE_2.md); source-returning
retrieval begins Phase 3 under
[`release/GRAPH_TOOL_PHASE_3.md`](release/GRAPH_TOOL_PHASE_3.md).
Bounded orientation, patch reachability, resolver provenance, and the hybrid
lexical ranker begin Phase 4 under
[`release/GRAPH_TOOL_PHASE_4.md`](release/GRAPH_TOOL_PHASE_4.md).
