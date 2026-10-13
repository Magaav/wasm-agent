---
name: code-graph
description: Retrieve a ranked code symbol and its exact implementation, answer explicit dependency questions, or audit a patch's possible missed callers. Use for concept-to-code discovery where broad file reads would be wasteful; grep remains the fallback for absent or low-confidence results. Whenever you use graph, briefly explain in the final answer whether it helped your reasoning and why.
---

# Symbol retrieval, dependency leads and patch impact

Whenever you use graph, include a brief final-answer assessment of whether it
helped your reasoning and why, including a concrete limitation when it did not.
Do not equate static leads with correctness or measured test coverage.

Use graph for discovery and static relationships. An empty result is not proof
of absence. Inspect source before editing; investigate relevant unresolved edges.
Test leads are not test coverage. Audit/impact `unresolved_calls` separates calls
originating in changed symbols from repository totals and gives exact call-site
`read`/`grep` followups. These are unresolved/ambiguous leads, not dependencies.
Check returned/truncated counts; this initial view covers changed symbols only,
not every unresolved edge in the transitive impact scope. A gap-free result does
not exclude dynamic callers.

The `graph` tool retrieves exact definitions from a verified source snapshot and
answers relationship questions from the same index. For concept-to-code discovery,
try `search_symbols` before broad grep/file reads, then retrieve the selected
implementation with `symbol_source`. Use `grep` when results are absent or low
confidence. Read surrounding file context before editing. The opt-in patch audit
uses the graph at the end of a native `write`/`edit` run.

For an unfamiliar repository area, start with a bounded overview rather than a
chain of broad directory and symbol queries:

```
graph {action:"overview", aspects:["modules","entry_points","boundaries"], limit:8}
```

Each section reports exact `total`, `returned`, and `truncated` counts. Ask for a
specific section or a larger limit only when the clipped rows hide a needed lead.

## Scoped file discovery fallback

For an external/unindexed repository or a low-confidence graph result, choose
explicit relative roots (`src`, `docs`, a named module) and filename terms from
the task. Do not print `rg --files <absolute-root>`: repeated root prefixes can
consume the response before useful paths arrive. Run from that root and return
relative paths. A clipped inventory is not evidence of absence; do not hide it
with `head`, discard the tail, or repeat the same whole-tree request.

The read-only helper [scripts/discover-files.mjs](scripts/discover-files.mjs)
requires explicit scope, reports scanned/matched/returned counts and emits complete
JSON pages within a byte budget. Paths are not summaries. The recorded spell
`code-graph-discover-files` accepts shell-quoted `runner_arg`, `root_arg`, `scope_arg`
and `match_arg`; `scope_arg` is one relative root and `match_arg` a path regex.
Its postcondition requires a complete page, but replay currently refuses mandatory
session workspaces (`workspace_execution_context_unsupported`). The spell is not
replay-verified or preferred: use the verified direct CLI below without relaxing
the workspace binding; prefer the spell only after actual postconditions pass:

```
node <absolute-skill-dir>/scripts/discover-files.mjs --root <repo> --scope src --scope docs --match 'executor|server|security|session' --max-bytes 8192
```

If `complete:false`, keep the exact page and continue with its `next_offset`
and `snapshot` using `--offset N --snapshot SHA`; a changed inventory refuses.
Alternatively narrow an unrelated scope, never pretend omitted candidates were
examined. Scope/term selection and reading the returned source remain inference.
Read independent known source ranges together with `read_many`, keeping exact
bytes, errors and continuation addresses. No index or filter replaces necessary
source inspection. Private proof: `node <skill>/scripts/test-discover-files.mjs
<absolute-evidence-scratch>`; it checks pagination, Unicode/space paths, ignored
files, exact candidate sets, changed-snapshot refusal and visible failures.

## Retained public-repository surveys

After a collector has saved full metadata, pinned commit/tree JSON and README/source
files in session evidence scratch, do not print its complete results/excerpts or
recursive file inventory. Use [scripts/repo-survey.mjs](scripts/repo-survey.mjs):

```
node <absolute-skill-dir>/scripts/repo-survey.mjs --cache <absolute-cache> --max-bytes 8192
```

The metadata-only view retains every candidate, explicit counts/failures and relative
evidence paths. Inspect selected original files; omitted excerpts are still cached.
Continue an incomplete page with `--offset <next_offset> --snapshot <snapshot>`;
changed cache evidence refuses. Do not refetch the network just to repair display.
`repo-survey-cached-view` records this verified read-only sequence; required worktrees
use the direct CLI, not unsupported replay. Source CLI works without a node restart.
Private proof: `node <skill>/scripts/test-repo-survey.mjs <absolute-evidence-scratch>`.
See [the cache contract](../../docs/REPO-SURVEY.md); metadata is not a quality benchmark.

## Retrieve implementation source

```
graph {action:"search_symbols", name:"session routing", limit:8}
```

When seeking a component or function implementation rather than a state binding,
pass `prefer_implementations:true`. This opt-in ranking lowers partial local
variables while leaving them visible. It is useful for multiword concept search;
leave it off when variables are the subject of the task.

Results are ranked by explainable BM25-like lexical evidence plus a small
graph-centrality boost. camelCase and snake_case identifiers are tokenized.
`score`, `score_breakdown`, `confidence`, `reason`, `matched_terms`,
`unmatched_terms`, and `unmatched_definition_terms` expose why a result ranked.
`high` means every concept word appears in the definition name or signature;
`medium` means some do; `low` may be path evidence alone. A `partial` verdict
means the top definition misses words even if its path contains them. This is
lexical retrieval, not semantic proof. Retrieve a useful candidate with
`symbol_source`, then confirm missing words with a bounded `grep`/`read` before editing.

When a named component from a task is absent, try one exact-name lookup and a
bounded source search. Record the absence as a finding and inspect the nearest
verified component. Repeating broader concept queries without new evidence
does not make an absent symbol appear. There is no elapsed-time cutoff for
discovery; stop a search when its evidence is sufficient to choose the next step.

```
graph {action:"symbol_source", path:"lua/core/agent.lua", name:"choose_worker", line:123, kind:"fn"}
```

Copy the selector fields from one search result. The source is the exact syntax
definition from the graph's verified snapshot. Large definitions are paged;
continue with the returned `next_byte_offset` and `source_version`. A selector cannot read arbitrary
files. Source retrieval replaces the first broad read, but inspect imports and
nearby state before changing code.

`graph {action:"audit"}` checks the current run's recorded patch against resolved
callers not read through native `read`/`read_many`; use `source:"git"` for the
current staged-and-unstaged Git patch, including shell edits. `graph {action:"audit_report",
hours:48}` summarizes the trial. `audit_feedback` records an operator-reviewed
outcome for a run with leads; never label a catch yourself. See
`docs/GRAPH-PATCH-AUDIT.md` for the limits and decision rule.
After an audit follow-up step, use `audit_assess` to record your usefulness
grade (0-3), concrete reason and critique. This is your opinion, not a confirmed
catch; grade 3 only means the lead prompted a patch or test revision.

Every query captures content evidence, freezes a required revision and automatically
waits for a committed snapshot covering it. Native mutations (including `edit_many`)
and OS events queue shared root-isolated indexing; missed hints are reconciled by
content, never Git/mtime alone. `graph_wait_timeout` or `graph_index_failed` is an
explicit failure, not an empty result: inspect revision/progress/recovery fields and
use bounded `grep`/`read`. Do not blindly retry or heartbeat a quiet worker. Explicit
`index force:true` remains the full-rebuild/repaired-index path; unavailable/poisoned
workers need supported node recovery. Later edits do not make this query chase a
moving target. Known locations can still make grep/read cheaper than graph.

For1–8 known definitions use `graph {action:'symbol_source_many',requests:[...]}`
or compatibility `symbol_source_many`. They share one captured/pinned snapshot per
resolved root. Follow each item's `graph_snapshot_index` into `graph_snapshots` and
inspect every error/continuation. Carry returned `source_version` with continuation
selectors; ambiguous/changed definitions refuse, never auto-select.

Focused proof and retained hash check:
`node <repo>/scripts/test-retrieval-native.cjs <absolute-built-wa> <fresh-evidence>`,
then the same CLI with `--post` before its arguments. `retrieval-native-proof`
records this verified sequence. Required workspaces still use the direct CLI;
unsupported spell replay is not a reason to unbind or weaken checks. The proof uses
private source/embedded processes, no inference, and real OS hints plus causal
failure checks. See `docs/GRAPH.md` for measured limits and source-domain omissions.

## Relationship questions

```
graph {action:"impact", source:"git", direction:"both", depth:2, limit:50}
```

Use `impact` after a patch when you need the changed symbols plus resolved
callers, dependencies, and test leads in one bounded result. Every impact row
includes hop direction and the call-site edge that reached it, including the
resolver strategy and confidence. The whole byte budget pages callers, changed
symbols, gaps and unresolved rows; counts remain exact and omitted rows stay
retrievable. Continue with top-level `next_cursor` (also `impact.next_cursor`),
even after impact rows finish if diagnostics remain. A cursor fails if
the graph generation, request or root changed. Source actions use the session's
worktree by default; explicit `cwd` selects a different read-only source root.
Focused paging proof: `node <repo>/scripts/test-graph-impact-paging.cjs
<absolute-built-wa> <fresh-absolute-evidence-dir>`, then the same CLI with
`--post` before its arguments. `graph-impact-paging-check` records this verified
sequence with shell-quoted `runner_arg`, `binary_arg`, `evidence_arg`; replay
refuses enforced worktree bindings, so retain the verified direct CLI until actual
spell postconditions pass. It verifies 2/12/24 KB traversal, not dynamic completeness.
Git audit/impact use its actual Git top-level for both patch and index. Check
`impact.root` against the intended checkout; missing/failed required bindings
refuse, never silently fall back. Root-scoped caches are on-demand and do not
replace the runtime watcher index. This is factual static reachability, not a
risk estimate; dynamic calls remain invisible.

Focused repair verification: `node <repo>/scripts/test-graph-workspace.cjs
<source-built-wa> <fresh-evidence-dir>` then the same command with `--post` before
its arguments. The recorded `graph-workspace-regression` spell crystallizes
that sequence and verifies source/binary/log hashes. Replay currently refuses
enforced session worktrees (`workspace_execution_context_unsupported`), so it
is not replay-verified or preferred; keep the verified direct CLI without
relaxing workspace binding. Tests reproduce three false missing files on the
old path, and exercise explicit/default/nested/native roots and cursor isolation.
They do not install the candidate or claim dynamic-call completeness.

```
graph {action:"explain", name:"append_turn"}
```
What is it, what does it use, who calls it. `definitions` lists each match with
its `kind`, definition `path:line`, the `uses` (calls, capabilities, macros) and
the `callers` at their exact call-site `path:line`. Exact names and member
suffixes suppress unrelated substring matches. Start here when you know a symbol.

```
graph {action:"path", from:"choose_worker", to:"append_turn"}
```
How A reaches B, **in the direction of use**: a step exists when the previous
node calls, uses or imports the next one. It does not walk back up to callers,
so `path` from a callee to its caller is *not found* — ask `explain` for "who
calls this", and do not read a shared callee as connecting two functions that
merely both call it. `steps` is a chain; each step's `via` names the edge that
reached it. Mentions in prose are deliberately ignored, so a hop is a real
call/import, not a coincidence.
Each `via` includes the call-site `path:line`; the step's own `path:line` is
the destination definition. Cite the former for the hop.
For a known start and end, try `path` before broad name queries. The graph
follows literal Rust `lua.call_string("entrypoint", ...)` calls into Lua and
statically named `pcall`/`xpcall` targets.

```
graph {action:"query", name:"routing_session"}
```
Ranked, compact symbol matches. Use it when you know a word but not the symbol.
The default shows 12 results and `truncated` says whether more exist; pass
`limit` to see more. Known symbols belong in `explain`, not broad `query` calls.
Literal HTTP route patterns are indexed too: query `"/subagents"` to find the
route line, then use its enclosing handler name as the start of `path`.

```
graph {action:"caps"}
```
The `host.*` capabilities and how often each is called, most-used first. This is
the answer to "what is this code allowed to do, and who does it" — a `host.*`
call is a typed edge, not a string.

## Reading the result

- `kind` is `fn`, `method`, `struct`, `module`, `field`, `var`, `capability`,
  `doc`, and so on. `method` means it lives in an `impl`.
- A `caller`/`use` with `-> path:line` was resolved to a definition. Structured
  evidence also includes its `resolution` strategy and numeric `confidence`. One without
  it is a name the index could not pin down (an external call, or a name that is
  ambiguous across files) — treat it as a lead, not a fact.
- `host.<name>` entries are capabilities. If you need to know whether a
  capability is reachable from a run, `caps` plus `explain` answers it without
  reading the host.

## Limits — when the graph is not enough

- It indexes syntax, not semantics. A call through a differently-named module
  alias may resolve to the wrong `M.x`, and trait/generic identity is not
  modelled. If `explain` shows no caller you expected, confirm with `grep`.
- Rust, Lua, JavaScript/TypeScript, Bash, PowerShell and Markdown are indexed. Other files are not.
- Ranking is lexical. Synonyms that do not occur in a name, signature, or path can
  return `absent`; use `grep` rather than treating absence as proof.
- With `prefer_implementations:true`, local variables that match only part of a multiword concept rank lower. This
  favors an implementation-sized definition during discovery, but can miss an
  important data binding; inspect variable leads when the task concerns state.
- `symbol_source` returns the syntax node itself. Leading comments, sibling
  attributes, imports, and nearby module state may require a surrounding `read`.
