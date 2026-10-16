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

It is deliberately *not* a general code-intelligence engine. It indexes Rust, Lua,
Go, JavaScript/TypeScript, Bash and PowerShell syntax plus Markdown mentions,
resolves references by name,
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
| database | runtime: `<home>/.wasm-agent/graph.db`; other roots: `<configured-db-stem>.roots/<SHA256-of-canonical-root>.db` |
| indexed root | the session worktree, or explicit tool `cwd`; unbound sessions use the configured runtime root |
| freshness | native source mutations and OS events queue a shared worker; every query reconciles content and freezes its required revision |
| write path | parsing precedes one `BEGIN IMMEDIATE` transaction publishing sources, symbols, relationships and committed revision together |
| read path | bounded wait for the captured revision, then a pinned read-only SQLite snapshot; no silent stale fallback |
| overrides | `WA_GRAPH_ROOT`, `WA_GRAPH_DB`; `WA_GRAPH_WATCH=0` disables OS hints, not mutation notifications or admission reconciliation; `WA_GRAPH_PARSE_TIMEOUT_MS` bounds each syntax parse (default30,000;1–120,000) |

One process-wide deterministic worker and one OS event backend serve root-isolated
queues. No inference worker, Engine job or recurring wake is introduced. Events,
including overflow, are hints: admission and startup reconcile supported source
bytes, so additions/deletions and same-size/restored-mtime changes are detected
without relying on Git or timestamps. Roots register before capture; up to32 live
cache entries are retained, with only idle derived entries evicted. Cache DBs remain
on disk. Excluded/build directories and unrelated scratch writes do not queue work.

Successful `write`, `edit`, `write_many` and `edit_many` applications notify the
selected source root. Per-file notifications also cover partial batches; failed
preflight has no indexing effect. A75ms coalescing window replaces pending captures
with the latest root revision, without indefinitely waiting for a quiet writer.
Only changed source files are parsed. Dependency keys select affected relationships,
including unchanged callers, previous unresolved calls, import aliases and latent
doc mentions. Indexed literal name lookups and pass-local resolution memoization
avoid repository-wide suffix scans without collapsing distinct call sites.

Queries capture one required revision and do not chase later changes. They await
an atomic commit covering that revision (navigation60s, explicit index120s), then
pin it for the whole read/source batch. Later committed revisions may cover that
requirement; later filesystem edits do not retroactively invalidate the invocation.
Timeout/failure returns required/committed/workspace revisions, progress and recovery
guidance, never an empty success or stale source. A failed content capture explicitly
reports unknown required revision. An expired waiter does not cancel shared indexing.
Use bounded `read`/`grep` after refusal. Inspect/fix the cause before deliberate
`index force:true`; poisoned/unavailable workers need supported node recovery.

`graph_snapshot` reports revisions and wait/work evidence. Counters describe the
named committed publication, not invented work per warm read. Separate admission
capture progress cannot heartbeat a stuck indexing worker: wait heartbeats advance
only on actual shared indexing progress. Parsing input, AST visits, staging,
resolution and commit provide scoped progress; elapsed time alone does not.
`graph_status` and native progress logs expose queued/active/failure states.

This is a captured **supported UTF-8 source** snapshot, not an atomic freeze of
external multi-file writers or the running interpreter. Symlinks, excluded directories
and unsupported suffixes remain outside the graph; `skipped_non_utf8` explicitly
lists supported files outside the text domain. Static/dynamic resolution limits remain.
Stored exact bytes and definition ranges, relationships and revisions publish in one
transaction. Read-only WAL snapshots never see partial generations. Full rebuilds
remain explicit with `force:true`; extractor-version migration preserves that path.
Windows root-digest cache paths use SQLite's locking long-path VFS with extended
absolute filenames, including read-only/WAL semantics, not a no-lock fallback.

## The capability

`host.graph_index|query|search|source|sources|notify|overview|impact|explain|path|caps|stats|status`. Each returns a JSON
string, and an error as `{"error": ...}` — the same shape as `host.sql_query`.
`graph_status` reports the resolved root/db and whether the index exists yet.
The model tool passes the session binding through every source action. Git
`audit`/`impact` resolve `cwd` to Git's actual top-level and use that same root
for diff collection, changed-line mapping, indexing and source verification.
Relative `cwd` resolves from the bound worktree. A required binding that is
failed/missing refuses instead of falling back to canonical/runtime source.
`impact.root` exposes the indexed root; its cursor also binds that root, so even
identical-source checkouts cannot exchange cursors. Unbound navigation keeps the
configured runtime default, including `WA_GRAPH_ROOT`.

Other roots have independent on-demand caches and registrations on the shared
backend. Switching worktrees never replaces the runtime graph. Explicit host `db`
overrides remain available for isolated tests. Derived-cache eviction is not source,
worktree, history or runtime-ownership cleanup, and adds no filesystem sandbox.

`lua/core/graph.lua` wraps them and compacts the results (a well-connected
function can have hundreds of callers; the model needs the shape and the first
few places to look). It tolerates a host that predates the capability and reports
`graph_unavailable`.

`search` accepts a multi-term concept or identifier and returns source-ready
`path/name/line/kind` selectors. Its score combines explainable name, signature,
path, and incoming-edge evidence using a deterministic BM25-like lexical score;
`confidence`, `reason`, `matched_terms`, `unmatched_terms`,
`unmatched_definition_terms`, and `score_breakdown` make the heuristic visible.
`high` requires all query terms in the definition name or signature; path-only
matches are `low`. The Lua wrapper returns `partial` when the top definition
misses terms and suggests a bounded source check. For a multiword query, a
local variable matching only some words receives an explicit score penalty only
with `prefer_implementations:true`,
because retrieving its tiny definition often hides the enclosing implementation.
This penalty risks demoting a relevant data binding, so `score_breakdown` shows it
and the variable remains in the result list. The ranking preference remains
off by default: one historical UI fixture does not establish a task-performance
gain. Identifiers are split across
camelCase and snake_case boundaries. It is
lexical ranking, not embedding similarity.
`source` selects persisted exact definition ranges without reparsing. Copy optional
`source_version` (file SHA-256) from discovery/source and carry it across continuation
pages to refuse changed source. Path/name/line/optional kind remain mandatory identity;
ambiguous selectors refuse instead of silently picking a match. Old selectors remain
compatible; discovery never automatically chooses an ambiguous definition.

`graph action=symbol_source_many` and compatibility `symbol_source_many` share one
backend (1–8 selectors). Each resolved root captures once and uses one pinned snapshot;
items retain ordered failures and independent20,000-byte source pages. Each item has
`graph_snapshot_index` into top-level `graph_snapshots`, avoiding repeated status text.
Different roots never share a mutable snapshot or cache. Legacy low-level array
responses remain arrays; the Lua facade opts into snapshot envelopes. `overview` and
`impact` count bounded revision metadata inside their whole-response byte budgets.

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
All response streams share the byte budget: callers, changed symbols, gaps and
unresolved-call rows page without fixed diagnostic overhead. Follow top-level
`next_cursor` (also mirrored under `impact`) until absent, including diagnostic-only
pages. See [GRAPH-IMPACT-PAGING.md](GRAPH-IMPACT-PAGING.md).

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

## Git stages, Go and source domains — 2026-10-16

Git capture reads complete retained command output, never a truncated head/tail.
A private replay of the original 104-file staged delivery reproduced an empty
patch on the old collector: its 24 KB tail contained no usable diff headers.
Root selection was correct in that reproduction; net `diff HEAD` also independently
loses staged edits cancelled in the worktree. Capture now uses separate index and
worktree manifests, NUL path identities, per-path hunks and exact content hashes.
Index identities are checked before/after capture; inspection never changes Git.

`patch_facts` is a fifth losslessly paged impact stream, with stage (`index`,
`worktree`, `untracked`), status, paths/rename origin, added/removed counts, line
coverage and source hashes. `changed_lines` sums stage-specific anchors, including
removed-only line counts; it is NOT a net diff or unique physical-line count.
Unsupported, binary, metadata-only, deleted, redirected, large and non-indexed
changes remain explicit gaps/facts. Changed index bytes map only if byte-identical
to current worktree source; otherwise `index_source_differs_from_worktree` is a
gap, not guessed offset translation. Deleted/old rename source is not reconstructed
into current symbols. Mapping uses stored snapshot bytes and rejects differing
patch source versions. Unreadable/non-UTF-8 Git output or capture limits refuse
instead of producing clean/zero success. External multi-file writers are not frozen.

Go uses pinned official `tree-sitter-go =0.23.4`, compatible with tree-sitter0.24;
see the crate THIRD-PARTY.md and retained MIT notice. Extractor version10 migrates
unchanged sources. Functions, receiver-qualified methods, types/interfaces/aliases
and top-level var/const specifications have exact ranges. Imports and calls are
recorded; unique same-package calls and local module imports expose
`go_package_unique`/`go_local_import_unique` confidence, not type proof. Captured
`go.mod` module identity participates in freshness and invalidates Go resolution.
SDKs, external modules, vendor/build/cache directories and symlinks are not read
for semantic resolution. Workspace/replace directives, dot/blank imports, default
aliases differing from path basename, generics, interface dispatch and unknown
receivers remain unresolved. Conservative local-name scans mark possibly shadowed
calls `go_dynamic_or_shadowed`; nested scopes may over-report that uncertainty.

Discovery/source/relationship rows label `source_domain`: `active`, `historical`
(`history/`, `archive/`, `archives/` or corresponding `docs/` roots), or `evidence`
(`reviews/`, `evidence/` or corresponding `docs/` roots).
Active tests retain domain active plus role test, including Go `_test.go`. The
lexical score adds an explicit -400 source-domain penalty unless history/evidence
is queried explicitly. This is a path heuristic, not deployment identity; it
keeps sole historical matches and exact selectors available. Same-directory and
unique-name resolution prefer the caller domain without guessing between remaining
ambiguous paths. Explicit historical imports override that preference. Edges label
their destination domain and cross-domain fallback has lower confidence.
No claim is made that historical candidates always ranked first before this fix.

Focused proof: `scripts/test-graph-repair.cjs <built-wa> <fresh-evidence>`, then
`--post` with the same arguments, covers private staged/unstaged/cancelled/shifted
changes, actual linked-worktree/nested roots, native Go source/version fences and
the original staged104 delivery. Crate tests cover Go syntax/resolution/migration,
provenance and patch-fact paging alongside existing freshness/paging/audit tests.
This is static partial coverage, not a full release gate or runtime installation.

## Measured retrieval update — 2026-10-12

Private interleaved baseline/candidate/baseline evidence on the same1,201-file tree:
133,188 references,45,013 stored nodes,54,078 resolved and72,181 unresolved in both arms.
Cold index:262.6–272.6s baseline versus9.85–10.17s candidate. Eight exact selectors
(two definitions repeated) over four warm passes per arm:1.17–1.43s versus75–84ms.
Returned source hashes match. Raw reply JSON grew13,617→15,238 bytes (11.9%) for
explicit source identity/revision evidence; there is no token-billing or net-context
saving claim. Two cold runs and one lexical workload are not broad task-quality,
latency or graph-versus-grep proof. The first unoptimized candidate timed out on
this real tree; indexed dependency keys and memoization fixed that measured scan.
The benchmark is `scripts/bench-retrieval.cjs`, with private DBs and zero inference.

Focused proof:47 crate checks,4 native bridge checks, source/embedded projection and
automatic-graph suites, real external-writer OS events, intentional parse failure,
restored timestamps/event loss, full rebuild parity, root isolation, frozen/bounded
waits, no fake quiet-worker heartbeat, deep Unicode/read-only/WAL cache paths and
whole-response impact pagination. `scripts/test-retrieval-native.cjs <built-wa>
<fresh-evidence>`, then `--post`, binds logs, source closure and binary hashes.
Self-review is not independent review; these checks do not certify dynamic callers
or a full release gate.

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
