# Graph tool evolution — Phase 1 snapshot

Frozen on 2026-09-24 before the Phase 2 telemetry and audit-coverage changes.
This is a baseline, not an adoption verdict. New telemetry without an explicit
phase is classified as `phase_1`; the updated runtime writes `phase_2`.

## Navigation

- Durable ledger: 26 graph calls across 10 sessions: 23 navigation calls, two
  patch audits, and one `audit_assess` attempt.
- Navigation results: 21/23 returned at least one result. This is a tool hit
  rate, not evidence that the result was correct or useful.
- Workload: 20/23 navigation calls were synthetic benchmark calls. Only three
  were organic: one `query` followed by shell inspection and two `caps` calls
  followed by grep or shell inspection. None clearly removed a later tool round.
- Post-fix matched artifact: graph available completed 3/3 tasks; graph absent
  completed 2/3 and exhausted its token budget once. Every graph-arm run chose
  `grep` first. Completed graph runs averaged 28,465 tokens and 6 tool calls;
  completed controls averaged 29,084 tokens and 5 tool calls.
- Limits: the failed control recorded zero tokens, understating control cost;
  the artifact did not persist an independently checked `correct` field; this
  was a worker-profile experiment rather than a main-agent experiment.

The matched artifacts were captured under
`~/.wasm-agent/experiments/tool-choice-20260923-063157/` as
`graph-navigation.json` and `nograph-navigation.json`.

## Patch audit

- The trial had run for about 10.9 hours, below its 48-hour review threshold.
- Two audits covered 313 changed lines: 130 mapped (41.5%), 183 coverage gaps
  (58.5%), zero leads, zero confirmed catches, and zero false positives.
- Audit time was 29.376 seconds total (17.761 and 11.615 seconds). The graph DB
  was about 13.4 MB.
- Sampled gaps were `no_enclosing_definition`. Many were blank lines or comments
  in Lua headers; others were real top-level configuration or Rust module/test
  regions. Phase 1 did not distinguish those categories.

## Phase 2 comparison contract

The runtime tags navigation outcomes and patch-audit events with `phase_2`.
Offline token audit reports navigation under `navigation.by_phase`; the graph
audit report exposes `phases` and names `current_phase`. Patch auditing keeps
semantic top-level changes as coverage gaps, while parser-proven blank and
comment-only changed lines are counted as `ignored_lines`.

Do not compare raw hit rate alone. Compare organic use separately from synthetic
fixtures, completion and correctness, later tool rounds, tokens, tool calls,
audit leads confirmed by inspection, semantic coverage gaps, and audit time.
