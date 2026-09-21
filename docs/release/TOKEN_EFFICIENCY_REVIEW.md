# Token-efficiency release review — 2026-09-21

**Decision: not approved for rollout or an efficiency claim.** Correctness fixes
and regression gates are not a completed independent review or matched-task study.
Candidate reviewed: `9fa1ae5`; comparison base: `d32ca2f`. No deployment, restart,
production ledger writes, messaging-account access or paid fixture calls occurred.

## Read-only field evidence

The running node was healthy but busy. Its installation identifies an
`unverified-binary`, not this candidate. A read-only SQLite transaction exported
metadata only; no conversation bodies were submitted for review. Original exports
remain local, not in Git. The 2,185-event snapshot covers
2026-09-20 13:16:53.965 through 2026-09-21 13:16:21.962 UTC:

* 541 completed inference calls; 539 with usable accounting; two failures with
  missing usage and two pending calls. No summary calls in this snapshot.
* 188,609,151 observed prompt tokens, 186,522,112 cached input tokens and 475,871
  output tokens: **98.8935% cached-input share**, not tokens eliminated.
* Recorded priced subtotal **$1.158144786**; complete cost remains **unknown**.
  These are configured-rate observations, not an invoice or verified task costs.
* Mean measured prompt: 349,924 tokens. There are six binary hashes in this
  population. The currently observed binary's cohort alone has 236 completed
  calls / 235 usable observations and about 512,011 mean prompt tokens.
* 524 completed tools, 20 failed; 368 bash, 89 edit, 18 read, three read_many,
  six operation calls. Repeated arguments within a run: two. Repetition is not
  automatically waste; failures are not automatically failed tasks.
* A follow-up with the elapsed-time auditor found valid monotonic duration on all
  524 completed tool spans: 6,875,581 ms summed, of which bash contributed
  6,714,101 ms (**97.6514%**). Bash p50 was 292 ms, p95 88,211 ms and maximum
  1,450,737 ms; its 11 failed calls consumed 606,601 ms. The duration distribution
  was: 244 calls below one second / 55,571 ms; 51 at 1–10 seconds / 178,869 ms;
  44 at 10–60 seconds / 1,183,859 ms; and only 29 at least 60 seconds but
  5,295,802 ms (**78.8758%** of bash time). Two of those long calls failed and
  consumed 604,094 ms—**99.5868%** of failed bash time. All 29 long calls had
  distinct argument hashes, so exact-command repetition is not the cause visible
  in this sample. Hashes and command text remain private. These spans include
  dispatch and output projection and can overlap work in other runs; they are not
  process CPU or global wall-clock time.
* Only 17 runs in this time-bounded export had complete, internally consistent
  parent/child timing. Within that separate population, summed run time was
  8,863,196 ms: model calls 3,658,835 ms (**41.2812%**), all tools 5,118,904 ms
  (**57.7546%**), bash/shell 4,957,605 ms (**55.9347%**) and unclassified work
  85,457 ms. Per-run bash share had p50 **14.1772%** and p95 **80.4431%**. Do not
  divide the all-tool population by this complete-run subset or present summed
  concurrent runs as elapsed clock time.
* A later model-free Windows executor probe separated native phases. Seven direct
  no-op fixtures measured 24 ms total p50 (21 ms child execution after spawn),
  while seven Git Bash no-ops measured 53 ms total p50 (49 ms execution): about
  3–4 ms of measured non-execution supervisor work and a 29 ms local shell/direct
  gap. The probe does not retrofit phase data into this historical export and does
  not explain its 88.2-second bash p95 or 24-minute maximum.
* Prepared-prefix measurements are absent. No verified task outcomes or independent
  acceptance checks are attached to this historical sample.

This is **not** an A/B comparison. Different binaries, histories and tasks prohibit
attributing its ratios or timings to the candidate. High cache share coexists with
large absolute prompts; neither proves good decisions or low whole-task cost.

## Independent model review: incomplete, including its costs

The installed binary was used as a separate process with its configured
`opencode-go/deepseek-v4.1-flash`, a fresh home/database, no tools, and public
repository source only. The busy live chat was not used. Source bundle SHA-256
and request/usage receipts were retained locally. The broad source bundle was
approximately 26.7k input tokens per request; this was real code-review work,
not a paid benchmark fixture.

| Attempt | Prompt tokens | Output tokens | Final answer | Process elapsed |
| --- | ---: | ---: | --- | ---: |
| Initial review | 26,737 | 6,000 | none; output limit | 26.156 s |
| Explicit bounded continuation | 26,763 | 16,000 | none; output limit | 71.883 s |

Both responses had `finish_reason=length`; all 22,000 output tokens were reported
as reasoning. No tool calls were returned. Total observed priced usage:
**$0.021225**, including both incomplete attempts; 98.039 seconds is summed process
elapsed, not total human task time. Calls stopped after that continuation. There
is **no final independent verdict** and no basis for a general model ranking.
Partial review leads were checked independently against code and reproductions;
they were not accepted merely because the reviewer proposed them.

Local private evidence:
`%TEMP%/wa-release-review-dzIoi6/` (manifest, original metadata export, provider
responses and process receipts). Do not publish raw responses as a substitute for
findings or treat a zero process exit status as successful review completion.

## Confirmed findings and dispositions

1. **Audit rejected legitimate empty Lua payloads.** Nineteen `run:start` records
   contained `[]`, the Lua encoder's empty-table representation. The auditor
   aborted instead of reporting the sample. Normalize only an empty array to an
   empty object; nonempty arrays remain invalid. Missing model usage still means
   unknown cost, never zero. Unit tests failed before the fix and passed after;
   the unchanged original field export then audited successfully.
2. **`diagnose` accepted an impossible grep-content assertion.** `expect.contains`
   read `result.content`, which grep does not provide. It could execute earlier
   steps and then fail despite a matching line. Reject this combination during
   whole-plan structural validation, before dispatch; advertise read-only content
   assertions and grep-only count assertions. A two-step negative test reproduced
   the defect before the fix.
3. **Operation byte pages silently damaged UTF-8 text views.** Reproduced with
   `printf '\303\251'`: reading one byte at a time produced `��`, while the full
   read and retained stdout were `é`. The conversion also exists in `d32ca2f`, so
   this predates the efficiency branch. Cursor results now expose `text_lossy`;
   lossy pages additionally provide exact `content_base64`. Existing text/cursor
   fields remain compatible. Tests cover split characters, binary bytes 0–255,
   EOF, and a genuine U+FFFD character. Status/tails remain lossy previews, not
   exact-byte receipts. Raw captured files were not damaged by the original bug.

Other review leads:

* A claimed guest-to-local-remote ownership bypass is **not reachable through
  this dispatcher**: `remote` is operator-only and the role gate precedes recursion
  or node lookup. Added a guest rejection regression; no authorization weakening.
* A grep inside `diagnose` stops on ordinary `.git` exclusions or excluded file
  extensions. This is the documented conservative completeness policy, not a new
  regression. It substantially limits usefulness on normal repositories. Document
  it plainly; do not silently relax it to make workflow benchmarks look better.
* Concurrent single-file edits still lack OS-wide compare-and-swap; large reads
  still read/hash the file; Unix process groups are weaker than Windows Job
  Objects. The fixes do not erase those previously documented limits.

## Regression gate

Runtime fixes: `ddc4df2`; complete consumer lockfiles: `a996dbd`.

* Windows: offline release build, **78 checks in disk mode and 78 embedded**, **15
  operation tests**, two sentinel tests, **74 mocked observability assertions**,
  offline audit unit/CLI tests, and both independent control modes (**9 checks
  each**). Desktop shell `cargo check --offline --locked` also passed; its existing
  missing-icon-tool / unused-import warnings are not a GUI execution test.
* Linux: full `bash scripts/test.sh` on `a996dbd`, **no skips**, including both
  78-check integration modes, **14 operation tests**, jobs/sentinel, native search,
  accounting, authorization, instruction freshness, embedding, plugin/JS checks
  and both independent cancellation modes. Exit receipt `0` and full log:
  `openclaw.ohana:/tmp/wa-efficiency-proof-3AwI3l/smoke-review-complete.{exit,log}`.
* The first Linux run had **one skip**: adding the dependency dirtied the sentinel
  lockfile, so its clean-tree deployment-refusal test did not run. Fixed both
  sentinel and desktop lockfiles and repeated the full suite, rather than counting
  that run as complete. The original `smoke-review.log` is retained.
* Windows receipts include `%TEMP%/wa-observability-gate-sZxvTO`,
  `wa-operation-control-XKauuI` (await) and `wa-operation-control-sW2Jmt` (bash).
  The UTF-8 fail-before reproduction is in `wa-review-op-read-rAwyc0`.

The full Windows smoke suite, real-browser UI gate, paid behavior suite and matched
model task comparison were **not run**. These regression results do not close the
independent-review gap or grant permission to merge/deploy.

## Reproducible whole-task comparison protocol — not yet executed

Use these real maintenance tasks, rather than designing tasks solely to reward a
new tool. Both arms work against the same target source `9fa1ae5`; the harness
baseline is `d32ca2f` and the candidate is the corrected revision. Build each from
its pinned source; never substitute the unverified live installation. Create
isolated owned workspaces/homes/databases and preserve starting/final tree hashes.

| Family | Identical task for both arms | Independent acceptance |
| --- | --- | --- |
| Small fix | Make the metadata auditor accept fieldless Lua run-start payloads without accepting malformed arrays or inventing missing usage. | Serialized and decoded `[]` work; nonempty arrays fail; missing model usage keeps total cost unknown; input file unchanged. |
| Multi-file change | Make diagnostic expectation/tool combinations explicit and reject invalid plans before any step. | Invalid grep `contains` in step two dispatches nothing; normal read assertions and grep count assertions still pass; shipped and disk code agree. |
| Debugging / no-op judgment | Investigate the claimed guest `remote` → local `session` bypass. Change code only if the reproduction supports it. | Guest is rejected before lookup/recursion; ownership and row/session-substitution tests pass; unsupported security claims and unnecessary repairs count against acceptance. |
| Execution / evidence | Reproduce and repair operation byte-page fidelity without changing deadlines, cancellation or captured output. | Split UTF-8 and binary pages round-trip exactly; valid UTF-8/EOF unchanged; existing operation tests and independent cancellation gates pass. |

Do not provide either arm the patches or the other's transcript. Keep oracle tests
outside their editable scope. Existing tests alone are insufficient: the new
negative cases must fail on the uncorrected target and pass on a proposed repair.
Builds and tests must use isolated scratch ports and cached/offline dependencies;
never install over the live node. Review the final diff for scope and data loss.

Controls and accounting:

1. Pin model, provider route, reasoning/output/context limits, instructions, role,
   permissions, initial histories, tasks and execution environment. Keep the full
   authorized tool surface in both arms; no hidden tools or discovery rounds.
   Baseline/candidate schema differences are part of the treatment and must be
   recorded, not falsely described as identical schemas. Test optional compact
   history/index settings separately; defaults remain full.
2. Predeclare a provider-call/output/cost budget and stopping rule. Repeated paid
   fixture runs remain unapproved. Obtain a budget before executing this protocol;
   a real review request is not blanket authorization for a benchmark campaign.
3. Counterbalance arm order; distinguish first-use from repeated-use trials and
   record actual provider cache observations. A fresh session or `cache=false`
   does **not** prove a cold provider cache. Record build/cache environment too.
4. Track every attempt, failure, summary, retry, output token, tool call, elapsed
   interval, human correction and rework. If a run loses its outcome, mark unknown
   and reconcile effects rather than replaying it. Associate every call with the
   task; include incomplete attempts such as the reviews above.
5. Independently verify results with the same acceptance checks and retained diffs.
   Report task success separately from accounting completeness. Unknown cost is
   unknown; a completion message, passing cache metric or a retained artifact is
   not acceptance. Unfinished tasks stay in the denominator; do not compare only
   each arm's successful survivors.
6. Compare cost per verified task and end-to-end latency with uncertainty and
   failure/rework rates. Only then discuss attribution to retrieval, fewer model
   decisions, cache reuse or executor speed. Tool-call counts are not model-round
   counts. Four task families or a single pair are a pilot, not general superiority.

**Remaining gates:** completed independent review, authorized matched-task trials,
and explicit rollout approval. No smaller context/tool defaults were promoted.
