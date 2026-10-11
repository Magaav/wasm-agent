# Independent batch tools

Operator tools `edit_many`, `write_many`, `grep_many`, `session_many`,
`search_messages_many`, and `symbol_source_many` take `requests` (1–8 items).
Use them only for already-known independent operations. Keep dependent discovery,
reads followed by edits, and conflicting effects sequential. Individual tools and
multiple independent calls in one model response remain available.

## Contracts

- Each request reuses its primitive's fields, bounds and authorization. Batch
  schemas derive from primitive schemas instead of maintaining duplicate contracts.
  Symbol requests contain selected path/name/line/kind and byte/cwd options only;
  they cannot index, audit or run another graph action. No implicit refresh occurs.
- All new batches are operator-only. A child needs both the batch and primitive
  in its explicit profile; built-in explore gains only search/source batches.
  Task owners gain the same safe read/write conveniences, never broader authority.
  Guest tools/account visibility and remote image restrictions do not expand.
- Read results remain in request order with separate errors, source identities,
  scope/filter semantics and continuations. Search omissions are not success at
  complete discovery. A batch is not a simultaneous filesystem/database snapshot.
- Mutations validate all item shapes, workspace paths, text/receipt versions,
  anchors/ranges, duplicate/ancestor targets and prepared snapshots before the
  first write. No-op requests do not rewrite files. Each actual application
  rechecks the source and workspace and observes the steering fence.
- `write_many` optionally accepts `version` (existing text SHA-256). Empty
  versions are not relaxed for writes/edits. Unreadable/binary/directory targets
  refuse before any mutation because a reliable text preimage is unavailable.
- Effects are serial, **not a multi-file transaction or an OS-wide CAS**. A late
  external edit, failed write or recording failure stops later items. Earlier
  applied effects remain recorded. `applied`, `failed`, `not_run`, `unknown`,
  `partial`, and ordered item outcomes distinguish them. A failed write is an
  unknown outcome; never automatically retry, rollback or manufacture settlement.
- Diff/undo uses the ordinary per-run changeset. Existing size/storage/create
  limits remain visible, not silently bypassed. Preparation writes no files or
  changeset evidence. Aggregate telemetry records batch item counts; one model
  tool invocation is still counted as one invocation, not fabricated as N calls.
- If the aggregate result exceeds the ordinary total view budget, every outcome
  slot stays visible and omitted items have exact JSON artifact pointers. Full
  originals are retained. Retrieve an omitted item before using its contents or
  continuation; large batches can cost additional retrieval rounds.
- No batch sends, deployments, restarts, cancellation, arbitrary tool dispatch,
  retries, watchers, parallel mutation workers, or new host capability.

## Performance and risk

The measurable target is less invocation/envelope overhead for the same verified
work. Batches still execute the underlying reads/writes; no I/O/corpus/result cache
or invented speedup is introduced. Existing independent calls already share a
model round, so batches do not inherently reduce inference rounds. Added schemas
increase each operator request's tool surface, and large outputs may need extra
artifact reads. This risk must be weighed against measured task latency/context,
not justified by counting calls alone. AGENTS.md remains unchanged.
`WASM_AGENT_BATCH_TOOLS=0` disables the six schemas and direct batch dispatch at
interpreter startup as an explicit rollback knob; ordinary tools remain. Enabled
by this operator-requested rollout does not force batching or change discovery
policy. No automatic fallback or per-round tool/schema shuffle.

Initial model-free eight-write exchange: 4,799 bytes in eight primitive calls
versus 3,974 bytes in one batch (825 bytes / 17.2% less); the six full schemas add
7,700 bytes. This is serialized exchange metadata, not tokenizer/provider billing
or an inference-round/latency guarantee. The fixed schema addition alone is larger
than this one exchange's saving. Real task correctness and timing need separate
measurement; do not claim that every task becomes faster.

`scripts/test-batch-tools.lua` verifies real private native filesystem/SQLite and
changeset behavior, refusal/no-effect and unknown/partial cases, primitive result
parity, ownership/profile fences, original artifact recovery and deterministic
argument/result envelope bytes. `scripts/test-batch-tools.cjs <wa> <evidence>` runs
source and standalone embedded modes plus `--post` hash checks. Evidence is
model-free, not a paid-model task-quality or guaranteed latency claim.
