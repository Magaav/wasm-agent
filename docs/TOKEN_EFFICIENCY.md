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
  provider eviction. Older exports lack per-message comparison evidence; those
  remain unmeasured. New `prefix_audit` observations (below) are counted separately.
  Neither proves provider retention or guarantees a cache hit.
* Request/first-delta/run latency sample counts and p50/p95; average request
  component bytes, with reasoning/arguments labeled as source-byte subsets.
* Completed tool elapsed time by built-in tool name (unknown/plugin names are
  aggregated as `other`), including measured/unmeasured counts, failures,
  clock source, total/mean/p50/p95/max and share of measured tool time. Run
  decomposition reports inference, summary, tool, bash/shell and unclassified
  elapsed time only when every child span is measured and consistent. Native
  execution timing further separates setup, durable admission, spawn, child
  execution, drain/cleanup, output sync and the remaining wrapper; this detail is
  recorded in telemetry and removed from ordinary bash results before they enter
  model context. These are summed spans: concurrent runs can overlap, tool spans
  include dispatch and output projection, and neither measure is process CPU or
  global wall-clock share. Tool durations are also bucketed at 1/10/60 seconds.
  For bash calls at least 60 seconds, the report counts distinct/repeated
  argument-hash groups without emitting hashes or command text, so concentration
  is visible without making commands public.
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

Both probes run in `scripts/test.sh`. `scripts/test-token-audit.cjs` tests the reporter,
independently of the UI test toggle,
including missing usage, failed/pending work, summaries, privacy, inconsistent
accounting, cross-session isolation and duplicate exports.

## Stage 1 verification

Source `467c803`:

* Windows: offline release build, reporter unit/CLI checks and both isolated
  production-projector probes passed. Obsolete positional run counts were refused.
* Linux: complete `bash scripts/test.sh` passed with **no skips**, including the
  reporter, both projector probes and existing native/Lua/plugin/control gates.
  Isolated checkout and retained logs:
  `openclaw.ohana:/tmp/wa-efficiency-proof-3AwI3l/`;
  `smoke-final.log` ends in `smoke ok`, `smoke-final.exit` is `0`.
* Each projector fixture recovered its original exactly across 33 artifact pages.
  No paid-model calls, live deployment, service restart or production DB access.

The full Windows smoke suite and paid-model behavior suite were **not run**.
There is no measured task-quality or financial improvement claim in this stage.

## Remaining stages: implemented

### Files and deterministic computation

`read`/`read_many` return raw UTF-8 text (no synthetic line-number prefixes), a
whole-file SHA-256 `version`, actual starting/ending line, byte column, `eof`, and
`next_offset`/`next_column`. A complete whole-line page also returns an opaque
`selection` receipt bound to its path, version, source lines and exclusive byte
range. Pass both next coordinates **and version** to continue.
Long lines can span pages. CRLF, trailing newlines and UTF-8 boundaries are retained.
Pages account for JSON escaping before returning a cursor; the generic projector
must not truncate them again and silently skip bytes. An intervening edit rejects
versioned continuation. Independent ranges remain available without a prior receipt.

Each call reads fresh file bytes. Only the deterministic line index is cached by
content hash plus index-format/configuration version: at most 16 entries and an
estimated 2 MiB of index storage per module instance. Index construction also stops at that limit; oversized files
use a range-only index while counting lines without retaining all line offsets.
No file contents, file-exists
results, test outcomes or external state are substituted by this cache. This saves
re-indexing, not file I/O or hashing. The underlying read still loads the file;
bounded pages/index cache are **not** a bound on whole-file memory or filesystem time.

The model-facing `edit` has two addressing forms, and the address is evidence.

`edits` quotes the exact bytes to replace (`old_text`/`new_text`). It is the form to
reach for when the text is quotable, because it cannot hit the wrong place: the
anchor must occur exactly once, and a miss is refused with the nearest region
instead of being guessed at. Its cost is the failure mode the ledger already
measures - an anchor that was never in anything the session read.

`range_edits` copies a `selection` receipt from `read`, up to 64 of them, each with
`replacement_lines` whose elements contain no CR/LF. Use it for structure whose
newline bytes matter, or text that is not quotable: line structure is typed
separately from source text, so a multi-line replacement never re-encodes an
anchor's newlines. The read that produced the receipt also names the frame it
addresses in `edit_lines`, and optional inclusive `start_line`/`end_line` select a
whole-line subset inside it without changing the receipt's byte coordinates or
digest - so a slice is copied rather than counted. The receipt supplies its version;
there is no duplicate top-level version. Path- and version-bound, and every range is
resolved against one original snapshot: overlap or any invalid later range rejects
the whole batch before writing. The target's one EOL form and trailing-newline state
are preserved, and a mixed-EOL target is refused rather than silently normalised.

**A slice inside a receipt is in-bounds or refused, never diagnosed.** The receipt
proves the page, not the part of it the caller meant, so a wrong-but-in-bounds slice
is accepted: four in one session took unrelated lines with a replacement, left a
stray closer behind, and deleted a match arm - every one returned `ok: true`. The
result therefore names what each range actually replaced (`first_line`, `last_line`,
`lines`, `bytes`, `sha256`, and the first and last line as text), and reading that
echo is part of using the form. No refusal can catch this case; the echo is what
makes it visible in the same round.

The runtime still accepts the former object selections, duplicate top-level version
and `old_text` forms for calls already stored in active transcripts and for
mixed-version peers, and quoted anchors are advertised again beside receipts -
the form that cannot hit the wrong place. Anchors keep exact matching and never guess that a doubled escape meant a structural
newline: that miss is refused, with the nearest region named. A schema rollout can
neither strand a live session nor hide a misquote.

A second read detects intervening changes before the write. Successful changes retain
the existing changeset record. A recording failure after writing explicitly says the
edit was applied; a failed write has an unknown outcome requiring inspection. No-op
replacements do not rewrite the file.

This is a **single-file validation boundary, not an OS-wide compare-and-swap**:
arbitrary editors can still race the final check/write. It is not a multi-file
transaction. Do not claim those stronger guarantees or retry an ambiguous write.

`grep` is explicitly literal, with `ignore_case`, `limit` (1–500), `max_depth`
(0–64), and exact `extensions` filters. Unsupported options fail rather than
silently changing semantics or falling back to a different shell matcher. Traversal
is sorted and symlinks are not followed. Skipped/error categories, scan counts,
result/entry/depth limits and clipped line text remain visible; `complete=false`
also covers intentional exclusions. A search is not a filesystem-wide snapshot.

### Predetermined diagnostics, not autonomous judgment

`diagnose` accepts 1–8 explicit `read`/`grep` steps with optional literal-content
assertions (`contains`, read only) or match-count assertions (`min_matches` /
`max_matches`, grep only). Unsupported expectation/tool combinations are rejected
before any step executes. It validates the plan structure before execution, runs
steps once in order, retains ordered results and a plan hash, and stops on errors,
incomplete reads/searches or failed assertions. An explicitly requested line range
must have `range_complete`; without an explicit limit, the read must reach `eof`.
Thus byte clipping cannot pass as a complete range, and a complete requested range
does not force an unrequested whole-file read. It never invokes a shell, edits,
repairs, loops, retries, broadens scope or grants guest authority. Later steps are
explicitly counted as not run. This narrow read-only pilot is deliberately not a
new general workflow language; execution/test commands keep their existing tools.

Practical limitation: a repository-root grep normally encounters `.git`, and an
extension-filtered grep can omit other files. Both report `complete=false`, so the
workflow **stops** even if it found matches. Use a deliberately bounded evidence
scope; do not describe this pilot as a general repository-debugging accelerator.
Changing that conservative completeness policy requires a separate reviewed
contract, not silently accepting omissions to improve a benchmark.

When a task needs shell regex search or file discovery instead, the system guidance
prefers ripgrep (`rg` and `rg --files`) over recursive `grep`/`find`, with a fallback
when `rg` is unavailable. This is a search-choice default, not a runtime dependency;
the native `grep` tool remains the portable bounded literal search above.

### Event-driven operation settlement

Native operation waits now use settlement notifications rather than 5 ms status
polls. `operation {action:'await',id:...}` keeps **one** model tool call waiting for
settlement under the existing operation deadline/cleanup budget, with host heartbeats.
Cancellation stays independent, and completed/failed/cancelled/unknown states stay
distinct. It never launches or replays the command. An overdue supervisor returns
an explicit unknown outcome, not an endless model-polling loop. Short `wait` remains
available. The independent HTTP control route refuses long `await` calls so an
observer cannot occupy that route for an operation's lifetime. No new automatic
model wake, job approval or conversation injection is introduced.

### Optional evidence views; unchanged default access

`session` and `search_messages` accept `view:'compact'`. The default stays `full`.
Compact views retain content, identity, chronology, timing/outcome, concise call
identities and trace failures; they omit argument bodies, reasoning, images, diffs
and accounting details **explicitly**, with exact-row references. No stored row or
active conversation is rewritten. `session {session_id,message_id,view:'full'}`
retrieves the original row after checking both ownership and row/session identity.

Oversized rows can be paged with `byte_offset`, `byte_limit` (up to 20,000), and
`message_version`, following `next_offset` until `eof`. This exact JSON route works
for a guest's own messages without granting access to operator-only artifacts.
It rejects changed messages. Pruned messages remain unavailable, not reconstructed
or silently replaced by summaries. Oversized session previews retain these pointers.

`WASM_AGENT_TOOL_SNIPPETS=names` opts into a shorter system-prompt tool index.
Every tool name and its **full schema/description** remain available; default
snippets are unchanged. No tool-hiding profiles or discovery rounds are introduced.
Plugin schemas are sorted by name, and `capabilities` derives from the same complete
role-filtered list rather than an incomplete hard-coded list.

### Actual prepared-prefix evidence and instruction freshness

Each provider start records `prefix_audit`: canonical message hashes are compared
in memory to report append-only/identical/rewritten/shortened histories and the first
changed message index. Tools, non-message request settings (including cache routing
parameters) and known endpoint/session-header routing are compared separately.
Prompt text, authorization headers and per-message hashes are not stored in the
ledger. Baselines are worker-local: at most 16 session/kind keys, 8,192 messages
per key. A restart, eviction, oversize request or missing session is **unmeasured**.
The offline reporter includes these observations when present and tolerates older
exports without inventing them. `prefix_audit_ms` measures the audit's own runtime
cost, with sample counts/p50/p95 in the report: instrumentation is not assumed free.
Runtime fingerprints include the new Lua modules.

These describe prepared request components, **not** provider acceptance, tokenizer
prefix lengths, routing decisions, retention or guaranteed cache reuse. They do not
modify the serialized provider body. In particular, instructions are read afresh
when building context; unchanged bytes stay identical, but an actual `AGENTS.md`
change no longer waits for a process restart just to protect cache hits. Guest
instructions still never fall back to operator instructions.

## Full implementation verification

Source `a58c39d`:

* Windows: offline release build; **74 integration checks in disk mode and 74 in
  embedded mode**; **14 operation tests**; native search regression; **74 mocked
  observability assertions**; offline audit unit/CLI tests; independent HTTP control
  in both ordinary-shell and awaited-operation modes (**9 checks each**).
* Linux: complete `bash scripts/test.sh` passed with **no skips**, including both
  74-check integration modes, 13 operation tests, native search, accounting,
  instruction freshness, guest isolation, plugin ABI, existing jobs/sentinel tests
  and both independent control modes. Logs and exit receipt:
  `openclaw.ohana:/tmp/wa-efficiency-proof-3AwI3l/smoke-complete.log` and
  `smoke-complete.exit` (`0`).
* The gate caught an empty-edit validation-order regression and missing embedded
  modules. Both were fixed. The embedding check now verifies the actual embedded
  registry with negative controls, rather than accidentally loading disk files.
* Failure settlement does not notify observers ahead of its persistence attempt;
  storage failure is explicit. Native tests verify immediately reopened failure
  records and notification of multiple waiting observers.

That implementation gate used no live deployment, desktop restart, production DB
access or paid-provider inference. The subsequent read-only field audit and bounded
real code-review attempts are recorded separately in
[the release review](release/TOKEN_EFFICIENCY_REVIEW.md). The full Windows smoke suite, real-browser UI gate and paid-model behavior
suite were **not run** for this change. There is no new UI code. No controlled
real-task cost/latency or model-quality equivalence claim is made; the optional
compact views and shorter index have **not** become defaults.

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
