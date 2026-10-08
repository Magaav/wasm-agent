# Evidence-first history search

History is retrieved on demand; no memory injection, model call, background indexer,
vector store or transcript rewrite is introduced. `messages` remains canonical and
its existing SQLite FTS5 index supplies lexical candidates. Distilled facts and the
external inbox remain separate (`MEMORY.md`).

## Search contract

`search_messages` defaults to `scope:dialogue`, `view:snippets`. Dialogue means
user and assistant prose, excluding `[Sentinel notice]` automated user records.
`scope:evidence` searches tool results except native retrieval echoes; `scope:all`
preserves unrestricted historical investigation, including summaries and retrieval
results. Roles, exact session/tool names and inclusive Unix-second dates filter
BEFORE top-k selection. Filters never expand the caller's existing account authority.

Queries remain safe AND-of-quoted-terms lexical searches; `match:phrase` explicitly
requests one quoted FTS phrase. Case and diacritics follow SQLite unicode61, not a
new English stemmer or guessed synonym list. `sort:newest` is explicit; relevance
uses BM25 with deterministic date/id ties. Scores are lexical evidence, not truth,
authorization or calibrated semantic confidence.

By default a session contributes at most two hits, so long runs cannot monopolize
results. `group_by:message` disables this presentation diversity. No rows are
merged or deleted. Every hit retains its exact session/message/sequence identity.
Native retrieval tool names are excluded only in the evidence scope; `all` can
inspect them. This prevents feedback from copied search results without stripping
user quotations or guessing that two independent occurrences are duplicates.

Snippet views quote a contiguous original passage around a lexical match, with
Unicode-character coordinates, original byte size, explicit omission, and an exact
`session` reference. Short bodies remain complete. The encoded response is bounded
before the generic tool projector, and reports a continuation instead of dropping
whole hits. A 16 KB encoded page and 1,000-byte per-hit excerpt are discovery
presentation bounds, not transcript retention or agent reasoning caps; `byte_limit`,
`limit`, pagination and exact retrieval control further inspection. `view:full` and `view:compact` remain available explicitly. They may
return oversized-message references rather than silently cutting a row. Full exact
row JSON and associated original tool artifacts remain retrievable as before.

`has_more` is established by an extra selected hit; `next_offset` continues live
ranking. Pages are not a frozen corpus: newly appended/replicated history may
change ranks. This is explicit rather than a false completeness or snapshot claim.
A response's `returned` is not the corpus match count. No query result cache can
hide an appended correction.

## Follow the source

`session` accepts `around_seq`, with `before`/`after` neighbour counts, to show a
chronological window centred on a hit, including nonmatching corrections and
outcomes. Existing exact-row and before-sequence pagination remain intact.
`message_ids` fetches a same-session batch of selected originals in one call.
Every referenced row is checked against the authorized session; a mixed batch
with a missing/foreign row refuses atomically. Oversized bodies retain exact-row
references. Inspect originals before treating excerpts as execution settlement.

## Performance and risk

The SQL candidate phase selects identities/ranks, not `t.*`; snippet/body loading
occurs only for selected page rows. Grouping still ranks matching metadata across
the query's authorized corpus: broad common-word searches can cost more than a
narrow query. No instant-latency guarantee is made. Measure cold and warm latency,
returned bytes, known-source recall and actual evidence access together.

Changing the model-facing default risks missing tool-only evidence or context just
outside an excerpt. Mitigations are explicit scopes, full access, source references,
centred context and regression cases for corrections, no-match queries, Unicode,
large tools, echo recursion and guest ownership. No claim of paid-model task-quality
or token-cost equivalence follows from deterministic retrieval tests.

## Focused verification

`node scripts/test-history-search.cjs <wa-binary> <fresh-evidence-directory>` runs
private native Lua/SQLite checks, retains exact logs and a receipt, and performs
an embedding freshness check when the binary was built from this source. Its
`--post` mode verifies the retained hashes without rerunning effects. The optional
`--history-db <path>` takes a read-only SQLite backup into private evidence for a
model-free historical replay; it never mutates the live database or prints message
bodies. Keep that snapshot private. No full release gate is implied.

Observed evaluation: [measurements/history-search-20261008.json](measurements/history-search-20261008.json).
740 native deterministic checks passed (0 skipped), including disk/embedded modes
and a 64,776-message private snapshot. Warm 12-sample interleaved `benchmark Pi`
median: old 23.90 ms / 238,499 returned bytes (17/20 hits tools), new 11.43 ms /
10,353 bytes (12 dialogue hits, all source-exact). Broad `benchmark` median was
slightly slower, 25.09 -> 26.70 ms. This is source retrieval, not model-answer
quality or tokenizer/cost proof; process-cold is not OS-cache-cold. Five unchanged
session/window/ownership/recovery/efficiency suites also passed. Self-review only.

Ideas inspected at pinned GitHub revisions: CASS `62adb75e` (preview/source split),
deja-vu `32f4dbb2` (retrieval echo contamination and role policy), QMD `93d211f9`
(match-centred excerpts), claude-mem `71ddd117` (timeline/batch drill-down), and
obra/episodic-memory `7e065193` (exchange-level retrieval). These are design leads,
not adopted dependencies, copied ranking constants or performance evidence.
