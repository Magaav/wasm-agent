# Engineering from everyday runs

Ordinary telemetry is not a leaderboard or automatic agent-quality score.
Use wasm-agent and Pi normally, then review the next day or two of actual work.
The separately opt-in matched-task experiment is [AGENT-BENCHMARK.md](AGENT-BENCHMARK.md);
its preparation is not a completed coding comparison.

## What is measured

`harness_events` is an append-only, node-local SQLite ledger. Model-call
attempts (including summary calls), tool calls and runs persist start/end evidence.
A decision step may contain multiple model-call attempts when a timeout or context
overflow is retried; `round` identifies the step, while `attempt` distinguishes
response-timeout replays. Overflow recovery may rebuild the envelope even within
that step. An unmatched start means running or interrupted—not zero cost. Request
events link to the actual user row through `run_id`; final outcome events link
to the assistant row. Failed requests with no provider usage remain unmeasured.

Each model end stores the raw usage, normalized usage, provider/model, request ID,
finish reason and elapsed time. Streaming also records first nonempty delta time.
Starts record sent settings, prepared-request hash/bytes, system/schema hashes,
component estimates, context watermark and Lua/native fingerprints. The subscription
bridge records a hash of its input; Pi assembles the wire request separately, so
this is not a hash of provider wire bytes. Prompt text, authorization headers
and tool arguments are not copied into this ledger. Error
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
The model picker filters known protocol mismatches, and selecting one directly is refused
before the model is saved. A remembered model the active route cannot serve is reported and
not used: the route answers with its own default (`deepseek-v4.1-flash` on OpenCode Go) and
`model_error` names the value that was refused, so a provider switch cannot leave a
subscription id and its reasoning levels standing under an OpenCode Go route. The persisted
value is left for the operator to repair, never rewritten behind them.
`WASM_AGENT_LLM_MODEL` is excluded from that fallback on purpose: it is an operator pin, and
a pin that cannot run stays a loud pre-request refusal. Unknown catalogue entries remain
undecided/allowed; a stale catalogue can still hide a newly supported protocol until it is
refreshed.
Prices are not inferred from a subscription or copied as zero from a catalogue.
Pi bridge `subscription_transport` events retain observed stage/cause/HTTP identity
and retry decisions without payloads or credentials. Recovered model ends carry
`transport_failed_attempts`; live/offline aggregate cost stays unknown if any
lost attempt has unknown usage, even when the winning attempt has priced usage.
This count is separate from ordinary model-call counts and is not omitted work.

Status aggregation is append-aware with mutation/import invalidation, exact
percentile samples and no historical payload scan on an unchanged read. Context
coverage and dropped writes remain fresh. Storage inventory is separately sampled
with an explicit timestamp. See [LIGHTWEIGHT-UI.md](LIGHTWEIGHT-UI.md).

## Compact chat phases and debug history

Ordinary chat shows the compact strip in the existing sticky footer:
`✦ 6s|◈ ~13000|✧ 26|⚒ 82|◷ 2:24`. The left clock measures the current
phase (description in tooltip/debug); the last clock is total turn duration.
Token estimate/reporting and compact context occupancy are defined in
[MINIMAL-CHAT.md](MINIMAL-CHAT.md). The phase replaces the
redundant `thinking…`/`responding…` label. Debug output labels omit `Receiving` (`Model
output`, `Progress update`); other surfaces retain spaces around `·`. `Reasoning` is the requested
UI name for model wait/reasoning, not proof of provider-internal reasoning activity.
Selecting/executing tools and output replace that phase, never stack completed rows.
Live status uses normal whitespace rather than inheriting transcript pre-wrap;
its 15px glyph slot keeps the phase and total timer still. A deterministic
`· • ✧ ✦ ✶ ✳ ✺ ✳ ✶ ✦ ✧ •` cycle grows from 7px to 13px then shrinks back;
the next frame returns to the dot. The existing once-per-second status clock advances it;
there is no CSS rotation/pulse, new timer, blur or full-window effect. Hidden
surfaces do not tick it; settlement removes it.
Settlement hides the current phase and preserves totals in the footer:
`completed                 ✧ 5 · ⚒ 8 · ◷ 1:08`. `✧` counts provider-call
attempts at the prepared-request boundary (including failed/retried requests and
summaries), not decision rounds, billed inferences or internal transport reconnects.
Pre-request refusals do not count. `⚒` counts requested tool dispatches, including
failed/fenced calls; it is not successful effects or ranges inside `read_many`.
Cumulative versioned `run_counts` snapshots live in existing message traces,
never model context, and are re-emitted after checkpoints so reconnects can
recover the count. Snapshot replay replaces totals; it never sums repeated rows.
Older runs lacking snapshots show `?`; unfinished recorded snapshots show `≥`
as a lower bound. Abrupt stops can lose the last live increment, never fabricate
complete totals. Child totals remain isolated from the main chat. No new poll,
clock, schema, historical rewrite or scan of the telemetry ledger is needed.
Errors, recovery/queue notices, tool evidence and reasoning content remain visible.
Healthy heartbeat milliseconds are no longer printed in the turn. A shared
`wa-chat-warning` stays hidden normally and overlays the chat viewport top only
for sustained exact-run worker/connection uncertainty, using seconds and explicitly
unconfirmed wording. It never declares failed effects, stops a run, steals scroll
or occupies a transcript row. See [LIGHTWEIGHT-UI.md](LIGHTWEIGHT-UI.md) for shared
health polling and evidence thresholds.

Detailed `wa-step` history is visible only for a session whose existing recording
mode is `debug` (Engine → Sessions). `/session` mode is applied after target/epoch
validation; an acknowledged mode toggle updates the current container. Session/node
switches reset to quiet until mode is read. Child containers do not borrow main debug
state. Hidden phase rows remain available for debug without counting as visible run
steps; ordinary ticks update only the compact clock, not hidden step clocks. This
changes presentation, not retention, execution events or logging authority.

Risk: debug changes made from another surface appear on the next authoritative
session read; there is no new polling or watcher. `scripts/test-coordinator-steps.cjs`
now runs within `scripts/test-ui.ps1`, covering quiet/debug modes, phase/total clocks,
checkpoint continuity, settlement, child isolation and narrow-footer overflow.

## Proven non-execution versus failures

A steering fence with exact `error:superseded_by_steering`, `executed:false`,
`effect:none` is shown neutrally as `not executed · superseded`, not red and not
a successful effect. Missing/contradictory proof and actual failures stay red.
The original JSON, `ok:false` ledger row and unknown effects are preserved. New
telemetry records `cancelled_before_execution` separately from `tool_failures`;
legacy statistics retain their recorded verdict rather than rewriting history.
Replay can classify exact old fenced payloads without treating arbitrary error
prose as a cancellation. Storage failures cannot earn the neutral state.

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
each result uses the same read path and reports its own failure.
Tool starts/ends also identify the response group (`tool_group_id`, size/index)
and `batching_guidance` treatment; starts count `read_many_ranges` separately.
The offline audit exposes only aggregate complete/incomplete groups and counts,
never group IDs. Historical missing group metadata stays unmeasured. This measures
requested grouping, not proof of independence/parallel execution or saved model calls. Large combined
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
scripts. Those offline tools do not change runtime policy. The opt-in paid-model edit-workflow
experiment is documented separately in [EDIT-WORKFLOW-BENCHMARK.md](EDIT-WORKFLOW-BENCHMARK.md):
it uses isolated checkouts, equal tool surfaces, external verification and fresh read-only
shadows, and one fixture cannot choose a default. Subsequent runtime work adds
prepared-prefix comparison metadata without changing the provider body:
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

It also writes a **model/messages/tools snapshot** to
`data/efficiency/<session>-prefix.{json,md}` (historical filenames retained for
saved links) and prints `file://` links. The `.md` shows the system prompt, tools
ranked by schema size and a transcript outline; `.json` holds that snapshot.
In debug mode it uses the most recent available **first-step** trace capture,
which may not be the last model call. Otherwise `build_context()` reconstructs
the context at report time; it is not a promise of the next request. Neither
source includes per-call options or subscription wire bytes. The report labels
which source it used. Inspect these files as sensitive prompt material.

The footer gathers the other surfaces (harness events, the graph/patch-audit
trial report, the offline token audit, the runtime fingerprint, the docs) so one
command is enough to start an efficiency investigation. The reasoning row is
marked **stable**: reasoning replay is prefix-stable, so the report names it as a
fact and never as a reduction target - emptying a sent thought rewrites the
prefix and costs more than the cached read it saves (`docs/MEMORY.md`, and the
`provider.reasoning` comment). The signals it prints are
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
