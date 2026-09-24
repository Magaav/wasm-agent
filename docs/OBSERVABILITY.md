# Engineering from everyday runs

No task benchmark, leaderboard or automatic agent-quality score is introduced.
Use wasm-agent and Pi normally, then review the next day or two of actual work.

## What is measured

`harness_events` is an append-only, node-local SQLite ledger. Request, summary,
tool and whole-turn spans persist a start before the operation and an end after
it. An unmatched start means running or interrupted—not zero cost. Request
events link to the actual user row through `run_id`; final outcome events link
to the assistant row. Failed requests with no provider usage remain unmeasured.

Each model end stores the raw usage, normalized usage, provider/model, request ID,
finish reason and elapsed time. Streaming also records first nonempty delta time.
Starts record sent settings, exact request hash/bytes, system/schema hashes,
component estimates, context watermark and Lua/native fingerprints. Prompt text,
authorization headers and tool arguments are not copied into this ledger. Error
excerpts are redacted heuristically and may still contain task-sensitive text.

Pi 0.85.1's local source is the behavioral reference:

- `pi-ai/dist/api/openai-completions.js`: compatibility-driven DeepSeek thinking,
  reasoning replay and disjoint token categories;
- `pi-ai/dist/api/simple-options.js`: model output ceiling and context headroom;
- `pi-coding-agent/dist/core/compaction/compaction.js` and `utils.js`: measured
  usage plus estimated tail, image estimates, complete instructions/arguments,
  bounded tool excerpts and file-operation records;
- `pi-coding-agent/dist/core/tools/truncate.js`: 2,000 lines / 50 KiB, head for
  reads and tail for shell output with access to the original;
- `pi-coding-agent/dist/core/provider-attribution.js`: an edge is told which
  conversation it is serving, per request and only on requests that belong to one
  — the session header `ATTRIBUTION` in `lua/core/provider.lua` implements.

This implementation is not represented as identical to Pi. Unknown model
compatibility is explicit; only supported reasoning levels are offered. The
selected provider/model/reasoning are pinned for one user turn and refreshed at
the next one, including on other workers. DeepSeek's supported default is high.
Prices are not inferred from a subscription or copied as zero from a catalogue.

## Accounting invariants

For reported OpenAI-compatible usage:

```
all_input = uncached_input + cache_read + cache_write
total = all_input + output
reasoning <= output                 # already inside output; never add twice
USD = (uncached*input_rate + cache_read*read_rate
       + cache_write*write_rate + output*output_rate) / 1_000_000
```

Pi calls uncached input `usage.input`. Comparing that field directly with
wasm-agent `prompt_tokens` is invalid. Include failed attempts and summaries in
cost and token totals. Missing usage, inconsistent counts or missing prices must
remain visible. A high cache-hit percentage alone is not efficiency: unnecessary
cached context can still waste money, time and attention.

Each request start also records JSON byte counts by message role, plus the
source bytes of assistant reasoning and tool arguments. These are diagnostic
subsets, not token allocations: JSON escaping and provider tokenization differ.
They help identify growth without copying prompt text into the event ledger.
`read_many` can request up to eight independent file ranges in one step;
each result uses the same read path and reports its own failure. Large combined
results keep the full JSON in an output artifact for exact retrieval.
The 50 KiB tool-result limit applies to the entire model-facing JSON view,
including nested session pages, not just a top-level `content` or `stdout`
field. A large session page retains its newest complete messages and a cursor for
earlier messages; its exact original remains available through `tool_result`.
Older oversized rows are projected when rebuilding a prompt, without changing
their stored transcript bytes. This also bounds a resumed session that predates
the output rule.

## What to bring back in a day or two

In the status balloon, **Export session** exports the observed thread;
**Export node · 48h** exports every recorded event on this node in that period,
including failures and abandoned work. Exports paginate by sequence number.
For remote nodes, export directly from the originating node. Pi's normal session
JSONL remains its source of usage and task evidence; this change does not modify Pi.

Also retain the relevant transcripts, original tool-result artifacts, repository
revisions/diffs and verification results. The metadata export alone cannot prove
task quality. Default transcript retention is seven days; use debug mode or save
a session fixture if review will be later. Diagnostic events and output artifacts
currently have no automatic retention cleanup and are not journal-replicated.

During review, group by task type and difficulty, provider/model/reasoning,
available tools, starting revision, cache warmth, interruptions and human help.
Count all attempted tasks, not just successes. Judge correctness from tests and
actual effects, with user acceptance where tests cannot decide. Track rework,
human intervention and unintended changes separately from “answered.”

Only after that adjudication calculate cost and time per verified completion:
sum the resource use of **all** attempts in the cohort, divided by verified
completions. If the denominator is zero or the numerator incomplete, do not
print a finite efficiency score. Report completion quality and uncertainty beside
cost, latency and tokens. Natural runs identify engineering hypotheses, not a
causal claim that one harness wins. Investigate repeated identical tool arguments,
cache misses, large views, compaction frequency and failed tools as signals—not
as automatic evidence of waste. The offline audit attributes completed tool-span
elapsed time by built-in tool name and decomposes complete, consistently measured
runs into model, tool and unclassified time. Tool time includes dispatch and output
projection, not process CPU; summed runs can overlap, so it is not global wall-clock
share. Unknown/plugin names are aggregated as `other` rather than disclosed.
For newly recorded synchronous bash calls, monotonic native phase timing separates
executor setup/admission/spawn/execution/drain/output-sync from the final-record /
host-adapter / projection wrapper. The detail enters telemetry but is removed from
the model-facing bash result; incomplete or internally inconsistent phases are
reported separately rather than used in an overhead ratio. Duration buckets show
whether time is concentrated in long calls; bash calls of at least 60 seconds are
grouped by existing argument hashes, but only aggregate distinct/repeated counts
are emitted—never hashes or command text.

## Offline efficiency audit

[Token efficiency](TOKEN_EFFICIENCY.md) documents the opt-in metadata-export
reporter and the model-free replacements for the ineffective tool-budget A/B
scripts. Those offline tools do not change runtime policy. Subsequent runtime
work adds prepared-prefix comparison metadata without changing the provider body:
worker-local message hashes locate the first changed message, and tools/settings/
known routing are compared separately. Missing baselines remain unmeasured; no
prompt text or per-message hashes enter the ledger. This is not proof of provider
acceptance or cache retention. Byte reduction, cache share and retained originals
alone do not prove equal task quality.

## Live efficiency report

`/efficiency_report` in `wa chat` is the live counterpart to the offline audit.
It is deterministic: it reads the durable ledger and the transcript, spends no
model call, and writes nothing to the thread. It reports, for the last call and
the session, the byte domination of the request (tools, system, user, assistant,
reasoning, tool results, as a percentage of the whole request), the provider's own
disjoint cache categories (uncached input, cache read, cache write), the cache hit
rate, and the call cost at the configured rates with the cache share of that cost.
It names the part that did **not** hit the cache: the appended suffix, or the
prefix break (`rewritten`/`shortened`, a changed tool set, model or routing).

It also writes the exact prefix to `data/efficiency/<session>-prefix.{json,md}`
and prints `file://` links. The `.md` is the readable one - system prompt whole,
tools ranked by schema size, transcript as a byte-sized outline; the `.json` is
the bytes. When the session ran in debug mode the artifact is the last call's
request; otherwise it is `build_context()`, the deterministic assembly the next
call will send, and the report says which.

The footer gathers the other surfaces (harness events, the graph/patch-audit
trial report, the offline token audit, the runtime fingerprint, the docs) so one
command is enough to start an efficiency investigation. The signals it prints are
facts, not verdicts: "worthy", "waste" and "at the limit" are the reader's
conclusions, not the report's. `scripts/test-efficiency-report.lua` proves the
arithmetic, the prefix-break naming and the unmeasured-stays-unmeasured rule
without a model.

## Verification

`scripts/test-observability.lua` runs through the actual Lua agent/provider with
stubbed HTTP and a scratch DB/home; it spends no model calls. The smoke suite
includes it. Rust tests exercise actual local SSE transport. `scripts/test-ui.ps1`
checks the status balloon in a real headless browser. The concurrency suite uses
a delayed localhost provider for its routing checks, not a live model.
`scripts/test-observability-restart.ps1` verifies durable HTTP accounting and
reasoning settings across a real process replacement, plus the binary/UI
recovery backups in a scratch installation. It retains its temporary evidence
directory and never touches the live installation.

## Deployment and recovery

Deploy through `scripts/deploy.sh` from the clean reviewed delivery branch.
`WA_RUNTIME_WORKTREE` preserves the existing node working directory without
switching, merging or editing that checkout. The installed `runtime-worktree.txt`
also applies to later `serve` launches. Binary and the five UI assets are upgraded
together; `.pre-upgrade` copies remain available for recovery. The server PID is
recorded from the actual launched process and checked against the listener.

Before a migration, `scripts/backup-db.lua` can create a consistent SQLite
snapshot with `WA_BACKUP_PATH` pointing to a new absolute file and `--db` to the
source. It does not initialize or migrate the source schema. Keep that backup
private: it contains the transcript. Restoring it would discard newer work, so
recovery must explicitly account for any runs since deployment.

The preserved node checkout is not automatically advanced to this delivery
branch. Merge the reviewed changes before rebuilding from that checkout;
otherwise a later deployment from old sources can revert these improvements.
