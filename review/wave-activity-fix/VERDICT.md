# Independent RE-VERIFY: `change/wave-activity-fix` (tip `6b30ca7244be013b3e078b203c4dc2cf760cae2c`)

Second half of ONE review. Reviewer lane `child:dispatch:8077a6cf-8e1d-42dd-b32f-75e4178fd598`,
worktree `C:/Users/Victor/.wasm-agent/wa-worktree-childdispatch8077a6cf-…`, branch
`review/wave-activity-fix` (based on `6b30ca7`). Producer `child:dispatch:eae7f780-…`.
Reviewed predecessor: `6a61338` (my verdict `review/wave-activity-lifecycle`, commit `d4bd808`,
now merged into main as `7bdddf6`). The fix commit touches exactly 10 files; nothing else in the
`6a61338..6b30ca7` range is in scope here (that range also carries other lanes' merges).

**Model note (unchanged, as before).** This node refuses `gpt-6-luna` (`model_not_servable`), so
this review ran on `deepseek-v4.1-flash`/high — same family as the producer. Independence is the
lane: different session, own worktree, own fixtures, and every claim re-measured on the new tree.

**VERDICT: `narrowed`.** All seven claims are verified true, measured, and mutation-pinned; the
live lane is not fenced. Two safety corners remain open, one of which is the symmetric half of the
false-ON the fix closed only for `child_completions`. **Nothing here should block landing.**

## 1. The live lane (non-regression) — `produce`/`allocate` answer ok

Store read = **copies** of the live store; activity source = the real one
(`{kind:"node-runtime",repo:"C:/…/wasm-agent",data:"C:/Users/Victor/.wasm-agent",process_probe:true}`).

```
live activity: {"activity":"on","agents":2,"claims":["activity_claim_without_a_registered_worktree"],"corroborated":[true,true]}
  live produce   ok
  live allocate  ok
  live land      REFUSED: wave_convergence_unverified:wave-2026-10-02-subagent-chat-and-enforcement:pending:legacy r…
  live admit     REFUSED: wave_convergence_unverified:wave-2026-10-02-subagent-chat-and-enforcement:pending:legacy r…
  live observe   ok
```

Full matrix on copies (reviewed code vs fix), the live lane ON throughout:

| copy | phase | reviewed `6a61338` | fix `6b30ca7` |
| --- | --- | --- | --- |
| **live store as it is** (coordinator already migrated it) | produce / allocate | ok / ok | **ok / ok** |
| | land / admit | ok / ok | **refused `wave_convergence_unverified:<id>:pending:<reason>`** |
| **migration reverted on the copy** (pre-migration shape) | all four | ok | **all four ok** (convergence `open` is not "unverified") |
| **migration freshly applied on the copy** | produce / allocate | ok / ok | **ok / ok** |
| | land / admit | ok / ok | **refused by name** |

**External fact I observed, not mine:** the LIVE store has been migrated by
`orchestrator-master-0450d317` (`legacy` set at `1790974817135`, `migration.json` present,
`active_repo` gone, one row, three steps still pending). Consequence, measured: **the live
repository's `land`/`admit` are now refused by name** and stay refused until that migration is
reverted (`wave-migrate.mjs revert` → convergence `open` → admitted again) or the row's convergence
is verified. That is the intended tightening; it is a policy state the coordinator should hold
consciously. The live repo also carries one unresolved claim right now
(`activity_claim_without_a_registered_worktree`, session `33b4e818-…`), which does not fence
producing but would refuse `create()` by name if nothing were in flight.
I never wrote to the live store: `sha256(waves.sqlite)` is `f65b11dc…` in both the live store and
my copy.

## 2. `land`/`admit` are keyed on the convergence and hold whatever the activity is

Both corners of my first review are closed, and the guard now sits **before** the activity
short-circuit (which no longer exists):

```
blocked + activity ON   : land/admit => refused  wave_convergence_unverified:<id>:blocked:<reason>
migrated legacy + idle  : land/admit => refused  wave_convergence_unverified:<id>:pending:<legacy reason>
both cases              : produce/allocate => ok
```

Mutations `R-G` (drop the refusal) and `N-2` (`unverified = null`) both go RED in
`test-wave-activity-fix.mjs` (+ `public` for R-G/N-2), so the refusal is pinned, not incidental.

## 3. The activity answer is three-valued; a non-positive claim is never OFF

Four independent shapes, each a private Git repo + private node store, run by
`review/wave-activity-fix/r34-claims.mjs` (27 checks, all passed):

```
"worktree missing on disk and in Git"      activity=unverifiable on=false off=false claim=activity_claim_without_a_registered_worktree
"tree exists but is NOT registered with Git" activity=unverifiable on=false off=false claim=activity_claim_without_a_registered_worktree
"binding mid-release"                      activity=unverifiable on=false off=false claim=activity_claim_during_binding_transition_releasing
"claim on a RESOLVED binding"              activity=unverifiable on=false off=false claim=activity_claim_on_a_resolved_binding_parked
```

For every shape: `create()` refuses
`previous_wave_activity_unverifiable:<id>:unresolved_activity_claims:<claim>:<session>` — by that
name, never admitting the next wave — while `produce` stays `ok:true` and the admission answer
carries `activity:"unverifiable"` (not `idle`). Mutation `N-1` (ignore the unobservable answer)
goes RED.

## 4. The false ON is named, has a named way out, and cannot be borrowed

```
stale completion            : activity=unverifiable claim=child_completion_claim_without_a_live_turn_or_process corroborated=null
create()                    : refused previous_wave_activity_unverifiable:…child_completion_claim_without_a_live_turn_or_process:stale
observe                     : names exactly one claim, with its session and child_id
resolve (wrong identity)    : refused claim_identity_required
resolve (no evidence)       : refused observed_resolution_evidence_required
resolve (right identity)    : ok, activity_after=off, durable in <store>/activity-resolutions.json
create() after resolution   : ADMITTED
a LATER claim (new child_id): unverifiable again, create() refuses again  ← an old resolution is not borrowed
a REAL process appears      : activity=on, corroborated=true, create() refuses previous_wave_active
```

So a stale completion no longer blocks `create()` for ever, a later claim cannot borrow the old
resolution, and a process that appears makes the claim positive again — all three measured.
Mutation `N-3` (match a resolution by session alone) goes RED.

**Open corner (finding).** The same staleness in `steering_runs` is *not* named and has no way out:

```
stale turn row, no process, no child, tree registered:
  activity=on agents=1 claims=0 corroborated=false
  create() => previous_wave_active:stale-turn
  observe  => unresolved_activity_claims=0 agents=1 activity=on
  resolve() => REFUSED: claim_is_not_unresolved:stale-turn:activity_is_positively_on
```

A node that dies mid-turn leaves `steering_runs.state='active'`; with a registered tree that reads
positively ON, the named way out refuses it, and the probe is designed never to veto — so the wave
is ON and the next wave is refused with no observation that can clear it. The predicate is explicit
about the asymmetry: the child branch requires `corroborated === true`, the turn branch requires
nothing.

## 5. Migration: idempotent, one record per wave, refusal before the transaction

```
first apply  : record=migration-q5.json
second apply : ok, already_migrated=true, same record          ← idempotent, not an error after commit
second wave  : record=migration-q5-second.json                 ← one record per wave, both kept
legacy name  : with only migration.json present, apply => already_migrated=true record=migration.json
leftover     : apply on a NEVER-migrated wave with a record present => refused migration_record_without_migration
               row and event journal byte-identical afterwards  ← nothing was written
```

The old single-file `migration.json` is still read for its own wave (and `revert` removed the live
one on my copy, reporting `removed_records:["migration.json"]`). Mutation `N-5` (drop the early
refusal) goes RED.

## 6. Two unfinished waves — no silent orphan, but one fence remains

Measured (`r567.mjs`, 21 checks passed before the fence check):

```
older blocked + newer pending : produce ok, land/admit refused by name (the OLDER row)
list()                        : both unfinished rows
inspect(newer)                : reports the other unfinished row
checkAdmission(observe)       : unfinished = both
monitor()                     : drives the OLDEST (wave_id=older), reports the whole set
newest COMPLETE + older       : list/inspect/monitor still report the older unfinished row
```

**The fence I found.** In that last state, `checkAdmission` refuses **all four** phases with
`next_wave_requires_fresh_public_start` — including `produce` and `allocate`:

```
3. NEWEST COMPLETE, older blocked (fix)          : {produce, allocate, land, admit} => next_wave_requires_fresh_public_start
3b. the same state on the REVIEWED code 6a61338  : identical
```

So the fix's "every unfinished row is read" covers reporting, `create`, `monitor`, `inspect`,
`list` and the `land`/`admit` gate, but **not** the `complete` gate, which still reads only
`rows[0]` and refuses everything. Reachability: `create()` admits a new wave beside a merely
blocked older row (measured, step 1→2), and completing the newer wave is the normal path — so the
state is reachable through the public API, though it needs two rows and the live store has one.
It is **not** a regression (identical at `6a61338`) and it errs on the refusing side. My attempt to
demonstrate the recovery (`create()` in that state) was refused by my fixture's missing remote
(`git_failed:ls-remote …`), so the way out is **unproven here**; the state is at least recoverable
by a fresh `create()` whose `verify()` of the completed wave passes.

## 7. The index reversal is reported as transient, and the statement matches the measurement

```
plan()   : one_row_per_repository_index_transient includes "drops active_repo again"
revert() : {restored:true, transient:true, note:"wave-lifecycle open() drops active_repo again on the next
            create/advance/reconcile/resume…"}   and the index IS present afterwards
next read-write wave operation : the index is gone again
```

Statement and measurement agree. (Also measured: the first `apply` reports
`one_row_per_repository_index_dropped:false` when `create()` already dropped it — consistent.)

## Suites and mutations

Delivered suites on the delivered tree, all green: **`test-wave-activity-fix` 62**, derived-state 55,
no-orca 47, lifecycle 44, proof 33, public 23, restart 14, monitor-budget 16, retire 20 = **314 checks**.
(`test-wave-public.mjs` run with the repository's own release build `rust/target/release/wa.exe`,
sha256 `69686dff…` = the installed binary; the live install was not touched.)

Mutation battery in a pristine `git archive 6b30ca7` copy — the seven mutations that pinned the
reviewed tree, re-applied to the new code, plus five of my own aimed at the fix's new claims.
**12/12 CAUGHT:**

```
activity-fix=green derived-state=RED public=green   R-A ON/OFF from the durable row again
activity-fix=RED   derived-state=RED public=green   R-B the process probe VETOES
activity-fix=RED   derived-state=RED public=green   R-C the legacy convergence is no longer named
activity-fix=RED   derived-state=RED public=green   R-D create() refuses ANY previous row
activity-fix=RED   derived-state=green public=RED   R-E an IDLE wave refuses produce/allocate
activity-fix=RED   derived-state=RED public=green   R-F the migration rewrites the durable state
activity-fix=RED   derived-state=green public=RED   R-G a blocked/idle wave stops refusing land/admit
activity-fix=RED   derived-state=green public=green N-1 create() admits while activity is UNOBSERVABLE
activity-fix=RED   derived-state=green public=RED   N-2 land/admit through with an unverified convergence
activity-fix=RED   derived-state=green public=green N-3 a resolution matched by session alone
activity-fix=RED   derived-state=green public=RED   N-4 checkAdmission reads only the newest row
activity-fix=RED   derived-state=green public=green N-5 the migration no longer refuses a record without its migration
```

The new suite carries 11 of the 12; `public` carries the two admission-facing ones. I could not
find a mutation that survives both `activity-fix` and `public` in the directions the brief named
(`create()` admitting while unobservable = N-1 RED; `land`/`admit` through an unverified
convergence = N-2 RED).

## Proven vs unproven

**Proven:** all seven claims; the live lane's `produce`/`allocate` before and after everything;
`land`/`admit` refused by name in both corners and independent of activity; four non-positive claim
shapes read `unverifiable` and refuse `create()` by name; the stale completion is named, resolvable,
not borrowable, and made positive again by a real process; the migration is idempotent, one record
per wave, reads the legacy name, and refuses a record-without-migration before writing anything;
every unfinished row is read by create/checkAdmission/monitor/inspect/list; the transient index
statement matches the measurement; 314 delivered checks; 12/12 mutations.

**Unproven / not measured:** the recovery out of the newest-complete + older-unfinished fence (my
fixture has no real remote, so `verify()` refused); whether a stale `steering_runs` row arises in
practice (constructed by me); a real concurrent `create` race; the full gate (`scripts/test.sh`,
out of scope) and the deployment/install proofs.

**Should anything block landing?** No. The delta does what it claims and the live lane is not
fenced. Two follow-ups, neither introduced by this fix: name the `steering_runs` staleness (or let
the probe veto a turn the inventory can otherwise disprove) so a false ON always has a way out; and
read every unfinished row in the `complete` gate too, so a completed newer wave beside an older
unfinished one cannot refuse `produce`/`allocate`.

Agent: wasm-agent node=wasm_the_first role=reviewer session=child:dispatch:8077a6cf-8e1d-42dd-b32f-75e4178fd598
