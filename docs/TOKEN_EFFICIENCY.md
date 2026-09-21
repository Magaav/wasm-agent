# Token efficiency: evidence before policy

The objective is less cost and time per **verified task**, not a larger cache
percentage or a smaller schema at any cost. See [OBSERVABILITY.md](OBSERVABILITY.md)
for accounting and adjudication. This work is staged; a measurement change is
not permission to change agent policy.

## Stage 1: implemented, offline only

No runtime source, provider request, tool schema, permission, memory injection,
compaction policy, or execution behavior changes in this stage. The complete
tool surface remains available. No dependency or model call is introduced.

### Audit existing exports

Use Engine's **Export session** or **Export node · 48h**, then:

```sh
node scripts/audit-tokens.cjs path/to/wasm-harness-export.json
```

This opt-in script reads one existing metadata export (maximum 64 MiB). It does
not open a database, contact the node/provider, mutate the export, or print prompt
content, tool arguments, error text, account names, or identifiers. Output is
aggregate JSON, schema `wasm-agent.token-audit/v1`. Keep the original export private.
A flat event array is also accepted. A page marked `has_more` is refused: export
all pages first. Exact duplicated events are counted once; conflicting duplicates,
ambiguous span phases, reversed/mismatched boundaries and numeric overflow fail
explicitly rather than produce optimistic totals.

The report includes:

* Completed inference **and summary** calls, failed calls, pending calls,
  unmatched ends, missing/inconsistent usage and unpriced calls.
* Observed token/cost subtotals. `recorded_calls_cost_usd` is null if inference
  accounting is incomplete. Even a non-null value describes only the observed
  export, not an invoice or guaranteed whole-task cost. Windows cut at a time
  boundary can omit earlier/later work.
* Cached-input share and request-level cache-hit share **separately**, with
  matching measured populations. Missing cache data is not a measured zero;
  reasoning is a subset of output, not an additional charge.
* Per-session comparisons of existing system/schema hashes, provider/model,
  settings, attribution metadata, runtime fingerprints and summary watermark.
  Missing metadata makes a pair unmeasured, not stable. Changes are signals,
  not automatically defects: authorization, model and instruction changes may
  legitimately require a new prefix.
* Zero-cache calls with stable **recorded components**, not a diagnosis of
  provider eviction. The ledger has no per-message hashes or exact routing-key
  values; this tool cannot prove append-only history, find the first different
  message, or guarantee a provider cache hit. It does not invent that evidence.
* Request/first-delta/run latency sample counts and p50/p95; average request
  component bytes, with reasoning/arguments labeled as source-byte subsets.
* Repeated tool argument hashes **within a run**, never labeled wasted work.
  The same read after an edit can be necessary.

`verified_task_efficiency` is deliberately null. Correctness, rework and user
acceptance require independent evidence; "answered" is not a quality verdict.
The report does not compare unrelated models/tasks or assert causal savings.

### Retire the ineffective benchmarks

The old `bench-tool-budget.sh` and `bench-tool-tail.sh` selected arms through an
unconsumed `WASM_AGENT_TOOL_BUDGET` variable. They could spend paid inference on
identical runtime policies. That comparison is retired, **not repaired by adding
a legacy truncation mode back into the agent**.

Their entry points now run honest, model-free contract probes:

```sh
cargo build --release --offline --manifest-path rust/Cargo.toml
bash scripts/bench-tool-budget.sh  # read head and retained original
bash scripts/bench-tool-tail.sh    # shell tail, failure status and retained original
# or: node scripts/bench-tool-views.cjs read|tail
```

`WA_BIN` can select a candidate binary (use a native path on Windows). The runner
uses a fresh home/database and the working tree's Lua. Positional run counts from
the obsolete interface are rejected, not ignored. Successful fixtures are cleaned;
failed fixtures retain diagnostics and print their location. No installed service
or user's source file is touched.

Each probe checks genuinely different original/projected payload hashes, bounded
valid UTF-8 output, correct head/tail evidence, explicit omission, exact original
JSON retrieval through every artifact page, and preservation of command failure.
Escaping-heavy output can legitimately use the current projector's documented JSON
excerpt; the receipt identifies that representation. A synthetic head-600 negative
control demonstrates omission only; it is **not a runtime arm or model-quality
measurement**. Reported bytes and artifact pages are not provider tokens, inference
rounds or financial savings.

Both probes run in `scripts/test.sh`. `tests/token-audit.js` tests the reporter,
including missing usage, failed/pending work, summaries, privacy, inconsistent
accounting, cross-session isolation and duplicate exports.

## Subsequent stages: not implemented by this change

1. Explicit, version-aware file paging and honest search controls/completeness.
2. Validated non-overlapping batch edits with stale-file checks and retained evidence.
3. One bounded read-only diagnostic/test workflow whose steps the model selects;
   unexpected conditions return to the model, without invented repairs or retries.
4. Event-driven operation observation and content-addressed local computation caches.
5. Separately evaluated session/search projections and shorter redundant snippets,
   preserving identifiers, failures, exact retrieval and authorization.

No tool hiding, per-round schema shuffle, aggressive compaction, reasoning removal,
mandatory repository-map injection or new compact encoding is part of this plan.
Do not replay side effects because observations were lost. Do not cache command
success as a substitute for rechecking changed external state.

Any model-visible experiment must remain opt-in until equivalent task fixtures
show acceptable correctness, evidence access, authorization and recovery, alongside
cost and latency. Use the same initial repository, task, model/settings and tool
permissions; separate warm/cold cache conditions; include failures, retries and
summaries. Assert that experimental arms really differ in the intended component.
Keep changes independently reviewable and reversible. An available artifact does
not prove omitted information was unnecessary for the model's decision.
