# Graph tool evolution — Phase 2 boundary

Phase 2 began at merge `de7426c` on 2026-09-24 and ends when source-returning
symbol retrieval is deployed. It is the locator-only comparison period:
`query` returned compact `path:line` rows, while `explain` and `path` returned
relationship leads. Agents still needed a separate grep/read call to inspect an
implementation.

This boundary is intentionally a contract snapshot rather than a performance
verdict. Phase 1 had only three organic navigation calls, so Phase 2 retained
the existing actions while adding phase-tagged navigation telemetry and more
honest patch-audit coverage. No saved-read claim is inferred from tool hit rate.

Phase 3 adds two separately measured actions:

- `search_symbols`: ranked, source-ready selectors with confidence evidence.
- `symbol_source`: exact definition text from the verified index snapshot.

Later comparisons must distinguish Phase 2 locator calls from Phase 3 retrieval
calls. The primary outcome is a correct completed task with fewer subsequent
broad reads; retrieval response bytes, total provider tokens, calls, elapsed
time, fallbacks, and low-confidence/absent results are secondary evidence.
