# Graph tool evolution — Phase 4 measurement contract

Phase 4 begins when the commit containing this document is deployed. Phase 1's
adoption snapshot, Phase 2's locator surface, and Phase 3's source-retrieval
surface stay frozen so later telemetry can identify which contract was active.

## New paths

1. `overview` returns bounded architectural sections with exact totals. It is
   intended to replace repeated broad orientation queries, not source inspection.
2. `impact` maps the current native or Git patch to enclosing symbols and walks
   resolved callers and dependencies. It emits call-site evidence, resolver
   strategy, confidence, test classification, hop direction, and depth. It does
   not emit a risk score.
3. Resolved edges retain their provenance. Relationship results can distinguish
   an exact import or capability from same-file, same-directory, or unique-name
   fallback resolution.
4. Symbol search uses deterministic BM25-like field weights, camelCase and
   snake_case tokenization, and an explicit score breakdown. It remains lexical;
   this phase does not add or download an embedding model.

Overview and impact responses have explicit byte budgets. Impact continuation
cursors bind the graph generation and request digest, and fail after a source
change instead of combining generations.

## Start measurement

A Windows debug end-to-end run against this worktree force-indexed 315 files,
13,473 nodes, and 41,791 edges in 21.5 seconds. The default eight-row overview
returned 5,197 bytes in 234 ms. A two-hop, both-direction impact query for a
changed `graph.lua` function found 242 reachable symbols in 95 ms and returned
the first 50 in 12,635 bytes with an explicit continuation cursor. These calls
include full source-snapshot verification. This is one local sample and measures
response shape, not task quality or a production latency distribution.

## Hypotheses

- Orientation tasks require fewer graph, grep, and broad read calls after an
  `overview`, while task correctness and needed context do not degrade.
- Patch review finds relevant callers and test files with fewer separate
  `explain` and grep calls. Dynamic dispatch and unresolved edges remain visible
  coverage limits.
- Resolution provenance reduces false confidence: low-confidence leads cause a
  source or grep check more often than exact import/capability edges.
- The ranker improves the selected symbol and follow-up source success rate for
  split identifiers without increasing absent-result fallbacks.
- Bounded responses reduce p95 graph response bytes without increasing total
  run tokens or failed tasks through extra pagination.

## Record and compare

For organic completed tasks, record action, response bytes, elapsed time,
section truncation or impact pagination, selected symbol confidence, fallback
grep/read calls, total tool rounds, provider tokens, and an independently
reviewable task outcome. For impact, also record changed-symbol mapping coverage,
resolved/unresolved edge counts, whether a lead changed the patch or test, and
whether the operator confirmed that outcome.

Compare Phase 4 orientation to broad Phase 1/2 navigation, Phase 4 retrieval to
Phase 3, and Phase 4 impact to the existing opt-in patch-audit reports. Do not
pool synthetic benchmark runs with organic runs. A smaller response is not an
improvement when the task needs additional calls or loses necessary context.

## Decision rule

Keep the actions available while evidence accumulates. Change a default only
after multiple organic tasks show the expected reduction without worse reviewed
outcomes. A single repository, one query fixture, completion alone, or token
savings alone cannot choose a default. Embedding retrieval remains a separate
experiment requiring a local model choice, corpus-level relevance fixtures,
latency and index-size measurements, and a lexical fallback before adoption.
