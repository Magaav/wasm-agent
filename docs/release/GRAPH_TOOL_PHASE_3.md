# Graph tool evolution — Phase 3 measurement contract

Phase 3 begins when `change/codex-symbol-retrieval` is deployed. It changes the
graph from a locator-only surface into a retrieval surface while preserving the
Phase 2 actions for comparison.

## New path

1. `search_symbols` ranks definitions for a multi-term name or concept. Each
   result contains `path`, `name`, `line`, and `kind`, plus the lexical score,
   confidence, reason, matched terms, language, and signature when available.
2. `symbol_source` reparses the selected file from the graph's exact stored
   source snapshot and returns that definition. A large definition continues at
   `next_byte_offset`; paging preserves UTF-8 boundaries and does not summarize.

Ranking is lexical with a bounded incoming-edge boost. It is deliberately not
called semantic search. An absent or low-confidence result falls back to grep,
and source retrieval does not remove the need to inspect surrounding imports or
state before editing.

## Start measurement

A model-free Windows debug run on this worktree indexed 311 files and 13,381
nodes. For the query `session routing`, ranked search took 168 ms and selected
`routing_session`; retrieving that definition took 184 ms. This is one local
sample, includes full snapshot verification in each call, and cannot choose a
default or establish an end-to-end improvement.

## What would count as improvement

Compare organic Phase 3 retrieval chains with Phase 2 locator chains and with
grep plus range reads. Record:

- whether the selected source was sufficient and correct for the task;
- subsequent grep/read fallbacks and total tool rounds;
- total provider tokens and elapsed time for completed tasks;
- retrieval response bytes as a secondary, scoped metric;
- absent and low-confidence searches separately from successful retrievals.

The hypothesis succeeds when correct completed tasks avoid broad reads without
increasing fallback rounds or total context cost. A high search hit rate alone
does not satisfy it.
