# The front of the merge lane: the record, the rule, the trigger

`scripts/merge-lane.mjs` is the spine: it builds a candidate, gates the merged tree in a disposable
clone, and prints one JSON verdict. **This is not a second spine.** It is the three things that were
missing in front of it - what a delivery *is* on disk, when it may enter the lane, and what notices that
it may.

The concern it answers, in one line: nothing connected "a delivery settled" to "an independent review
exists" to "this may land", so a person did that step by hand, one branch at a time.

Files: `scripts/delivery-record.mjs` (the record), `scripts/delivery-admission.mjs` (the rule),
`scripts/delivery-trigger.mjs` + `scripts/delivery-trigger.sh` (the trigger),
`scripts/lib/delivery-store.mjs` (the store), `jobs/delivery-admission.json` and `jobs/delivery-lane.json`
(the two job definitions), `scripts/test-delivery-admission.mjs` (47 checks) and
`scripts/delivery-admission-fixtures.json` (the recorded fixtures).

## 1. The store: the sentinel's own, and why not the other two candidates

One JSON file per delivery, at `<WASM_AGENT_HOME>/.wasm-agent/sentinel/deliveries/<branch>.json`
(`scripts/lib/delivery-store.mjs`). `WA_DELIVERY_STORE` overrides the directory, so a rehearsal or a test
runs the whole rule against a scratch store and touches nothing live.

**Why this store.** It already exists, and it already holds exactly this class of object. `jobs.db` holds
the job definitions and the durable queue; `claimed/`, `done/`, `failed/` and `operations/` hold what
each delivery did. A delivery record is durable state about one occurrence, owned by nothing in git and
read by an operator at a prompt - the same kind of thing, in the same place, with the same lifetime.

**Why not the two others.**

- **Not `jobs.db`.** Its schema, its immediate-transaction semantics and its revision checks belong to
  `rust/wa-jobs`. A second writer with a hand-written INSERT would be a second owner of those invariants,
  and a schema change there would break this silently.
- **Not a tracked file next to the branch.** A record that is part of the branch cannot record the
  branch's landing, and a landed-and-deleted branch would take its record with it - which is exactly what
  happened to tonight's nine branches. The point of the record is to outlive that.

## 2. The record

`scripts/delivery-record.mjs` - one file per delivery, keyed by the delivery's own id (its branch name),
rewritten atomically (temp + rename), updated in place by the lane that owns each field:

| field | written by | what it is |
| --- | --- | --- |
| `delivery`, `branch`, `repository` | the producer | the id, and the clone whose refs this record is read against |
| `tip`, `tree` | the producer (`tree` is derived, never typed) | the reviewed commit and its tree |
| `producer` | the producer | the session that produced it |
| `review.{reviewer,commit,tip,tree,verdict,findings}` | the reviewer | the verdict, the session, and the published commit it is |
| `admission.{state,condition,refusal,by,tip,tree,caveats,event}` | the rule / the trigger | the decision, who made it, and the event it produced |
| `lane.{verdict,exit,tree,report}` | the merge lane | `scripts/merge-lane.mjs`'s own outcome for this delivery |
| `landing.sha` | the merge lane | the landing commit |

```bash
node scripts/delivery-record.mjs create <branch> --repo <path> --tip <sha> --producer <session>
node scripts/delivery-record.mjs review <branch> --reviewer <session> --commit <review-sha> --tip <sha> \
                                          [--verdict passed|narrowed|refused] [--finding <class>:<status>:<text>]...
node scripts/delivery-record.mjs lane   <branch> --verdict <name> [--exit <n>] [--report <path>]
node scripts/delivery-record.mjs land   <branch> --sha <sha>
node scripts/delivery-record.mjs get <branch> | list
```

The tree is never typed by hand: every verb that needs one derives it from the commit it names. A record
cannot hold a tree the repository does not have.

## 3. The admission rule

`node scripts/delivery-admission.mjs check <delivery>` - exit 0 admitted, 2 refused, 4 usage/repository.
`admit <delivery> --by <session>` is the same rule plus the act, and writes the decision into the record.

**A delivery may enter only when** its branch is pushed (the tip the record names is the tip `origin`
holds); an independent review exists and names the **same tree** as that tip; and no finding of the class
`summary_exceeds_code` - "the summary claims more than the code" - is unresolved. **A producer cannot
admit its own work** (`self_admission_refused`, and the `admit` verb refuses it before writing).

"Independent" is not the record's sentence about itself: the review must be a **published commit** in this
repository whose `Agent:` trailer names the reviewer the record names. The trailer is the convention the
commit guard already requires on every commit here, so the identity check reuses a store that exists
rather than adding a new one.

Every failure is a named refusal with a reason and a remedy. The conditions, in the order they are
evaluated (each `condition` below is what the refusal prints; `ok` in the JSON means the failure was not
found):

| condition | it fails when |
| --- | --- |
| `record_missing` | there is no record for the delivery |
| `branch_not_pushed` | `refs/remotes/origin/<branch>` does not exist |
| `tip_moved_since_record` | the pushed tip is not the recorded tip (the branch moved after the record) |
| `review_missing` | the record carries no review |
| `review_not_independent` | the reviewer is absent, or is the producer |
| `review_not_in_repository` | the review commit is not in the repository |
| `review_not_published` | the review commit is in no pushed ref (a local claim, not an artifact) |
| `review_anchor_names_another_session` | the commit's `Agent:` session is not the reviewer the record names |
| `review_names_a_different_tree` | the review's tree is not the tip's tree |
| `finding_unresolved:summary_exceeds_code` | the review recorded that class and nobody resolved it |
| `self_admission_refused` | the admission on the record was written by the producer |

**Three outcomes, not two.** `admitted`; `admitted_with_caveat` - every condition held and the review left
named caveats (an unverifiable claim, a boundary gap, a claim it narrowed), which are what the merger
carries into the landing; `refused`. A caveat is not a refusal: refusing on an honest "I could not verify
X" would mean deliveries never land. Only the class the operator named blocks.

Two things are recorded as evidence and deliberately **not** conditions: whether the review commit even
contains the reviewed tip (`observed.review_commit_contains_tip`), and whether the review is of a
different commit with the same tree (`review_tip_is_the_tip`, non-blocking). A review of a different
commit with the same tree is a review of the same content - that is what binding to a tree means.

### Tonight's real case: the placement delivery `ee15da23`

The record would hold tip `ee15da23`, tree `9de61108`, producer `e6bfc741-…`, review by
`7db14e40-0209-4938-a36d-cea73bb8c6d1` at commit `f6284aa` (published in `origin/main`, trailer names that
session), verdict `narrowed`, findings from the review's own check 8.

**The rule REFUSES it, naming `finding_unresolved:summary_exceeds_code`** - and that is the correct
answer, not a gap in the rule. The review names the same tree, the reviewer is independent and anchored,
and the review's verdict *did* narrow a claim - but the artifact it reviewed still carries the sentences
its own check 8 called wider than the code ("all-full work stays durably queued **(asserted by the
two-node fixture)**", "a request still in flight there is waited for rather than raced"), nothing narrowed
them (`git log ee15da23..origin/main -- docs/ORCHESTRATOR-WORKSPACE.md` is empty), and the delivery
landed with them. A rule that admitted this would be admitting exactly the class it exists to catch.

**Replayed, both outcomes are one edit apart.** With those two findings recorded as *resolved by
narrowing* and the peer-hop finding left as the one open caveat:

```
change/wa-session-e6bfc741-…: admitted_with_caveat with 3 named caveat(s)
  summary_exceeds_code / resolved   - narrowed to: all-full work stays durably queued (single-node fixture)
  summary_exceeds_code / resolved   - narrowed to: resolve is serialized with an admission inside the runtime
  unverifiable_claim  / unresolved  - the peer hop is reasoned, not measured
```

So: **refuses as tonight's artifacts stand; admits-with-a-named-caveat once the writer narrows the claims
the review named.** The refusal is the useful one - it names the two sentences, so the fix is a two-sentence
commit, not an argument. (Rehearsal, not a fixture: a scratch record built from the real review, read
against this repository with the branch read from its local ref via the `--tip-ref` seam, which the output
records verbatim as `observed.source: "seam:…"`.)

## 4. The trigger

**Two jobs, because a pipeline cannot carry a `wake`** (the store's own validation: a `foreach` step must
be an inference action and a `wake` is a top-level action). That is also the shape
`skills/automation-jobs/SKILL.md` prescribes: a deterministic script does the reading and the diffing and
emits one event per genuinely new item, and a job turns that event into one wake.

| job | trigger | action |
| --- | --- | --- |
| `delivery-admission` | `schedule` every 60 s | `run` `<install>/scripts/delivery-trigger.sh` |
| `delivery-lane` | `event` topic `delivery.admitted` | `wake` (the coordinator's conversation, skill `git-orchestrator`) |

- The deterministic pass reads every record, applies the rule, writes the decision **into the record**
  (a refusal is written, never skipped), and emits **one** event per newly-admitted delivery onto
  `delivery.admitted` with the stable id `<delivery>@<tree>`. The record's `emitted_events` is the cursor
  and the sentinel's `UNIQUE(job_id, revision, event_id)` is the second, durable dedupe, so a re-run emits
  nothing new and a missed pass is recovered by the next one.
- The wake is the only part that costs a model turn and the only part that is budgeted (the sentinel's
  `WA_SENTINEL_WAKE_BUDGET`, 6/hour by default). Nothing above it spends a token: reading, diffing,
  comparing two trees and admitting are decidable, and decidable work must not cost a turn. The judgement
  the wake carries is the one `docs/FACTORY.md` reserves for a merger - the merge order, an ambiguous
  conflict, a conflicting contract, a failed merged-tree gate - and the payload hands it the exact lane
  command for that tip rather than making it re-derive one.
- A refusal is an answer: the pass exits 0 with its counts even when every delivery was refused, so the
  job's history means something.

`scripts/test.sh` does **not** discover `scripts/test-delivery-admission.mjs` by convention (the same
status `scripts/test-merge-lane.mjs` has), so the gate does not run it yet; adding the one line is a
change in a file this delivery does not own.

## 5. Evidence

- **Fixtures** (`node scripts/test-delivery-admission.mjs`, 47 checks, ~6 s, no network, no build; the
  fixture shas are deterministic because the fixture commits carry fixed dates, so the recorded JSON is
  reproducible): **admitted**; **refused for no review** (`review_missing`); **refused because the review
  names a different tree**; **admitted with a named caveat**; **refused for an unresolved
  `summary_exceeds_code` finding**; **refused for a producer admitting its own work**. Recorded in
  `scripts/delivery-admission-fixtures.json`.
- **The refusal text for the wrong tree**, verbatim:
  `change/fixture-wrong-tree: refused - review_names_a_different_tree. the review names tree
  8130ca0d45d9eb187a38995eec91b9d81f53ac43, refs/remotes/origin/change/fixture-wrong-tree is tree
  73a59a7446420894147e1c2974785b526fb45d46. a review of a different tree is not a review of this delivery -
  re-review the pushed tip, or push the tip that was reviewed.`
- **The falsification**: the test copies `delivery-admission.mjs`, removes the three lines that compare
  the reviewed tree with the tip's tree (asserting the splice really changed the copy), runs the copy
  against the same wrong-tree delivery, and asserts it is then **wrongly admitted** while the two trees
  still disagree in the same output - so the check, and nothing else, was doing the refusing. The original
  file is never edited (asserted byte-identical afterwards) and the wrong-tree delivery is refused again.
- **The job as installed**: `wa-sentinel job list` shows `"id": "delivery-admission", "enabled": false,
  "revision": 1, "queued": 0`, action `run <install>/scripts/delivery-trigger.sh`. Installed with
  `wa-sentinel job put`; nothing enabled it, and enabling is the coordinator's call.
- **The synthetic emit**: `wa-sentinel job emit delivery.admitted synthetic-admission-proof@9de61108
  <payload>.json` → `{"queued": 0}` (exit 0). The store accepted the event and nothing consumed it: the
  consumer is `delivery-lane`, whose session id is the coordinator's to name and which is therefore not
  installed, and the deterministic job is disabled. No model turn, no effect.
- **The pass, run for real** (the job's own run step, `bash scripts/delivery-trigger.sh`, against a
  scratch store): `5 record(s), 2 admitted, 3 refused, 2 emitted, 0 skipped`; the two emissions carry
  `"queued": 0, "exit": 0`; the three refusals are in the JSON with their exact `condition`; a second pass
  emits nothing new.

## 6. What the coordinator has to place, and what is left undone

**Documentation to place (this file is the only home of it for now):**

- `docs/FACTORY.md`, in "The landing procedure" or "The merge lane": *"A delivery enters the lane through
  its record: one JSON file per delivery in the sentinel's `deliveries` store, holding the branch, tip,
  tree, producer, the reviewer's verdict on that exact tree, the admission decision, the lane's outcome
  and the landing sha. `node scripts/delivery-admission.mjs check <delivery>` answers whether it may
  enter - branch pushed, an independent review naming the same tree, no unresolved `summary_exceeds_code`
  finding - and refuses by naming the failed condition. `delivery-admission` (schedule, deterministic)
  emits one `delivery.admitted` event per newly-admitted delivery; `delivery-lane` wakes on that event.
  See `scripts/delivery-admission.md`."*
- `skills/git-orchestrator/SKILL.md`, in "What a landing must carry": *"A landing starts from the
  delivery's record (`scripts/delivery-record.mjs`), and the admission rule
  (`scripts/delivery-admission.mjs check`) is what says a delivery may enter the lane; the lane writes
  its own outcome and the landing sha back into that record."*

**Left to the coordinator, with the exact reason:**

1. **Enabling the job.** `delivery-admission` is installed **disabled**. `docs/JOBS.md` is explicit that a
   job is enabled deliberately after approval; the brief says this one is the coordinator's call.
2. **The script path in the installed definition** is
   `C:/Users/Victor/AppData/Local/wasm-agent/scripts/delivery-trigger.sh` - the install directory, which
   is what `WA_SENTINEL_SCRIPTS` allows (`scripts/install-sentinel-task.ps1` sets it to `$Install\scripts`)
   and where the other installed jobs point. **That file appears when the change is deployed**, which is
   another reason the job cannot be enabled before then.
3. **`scripts/deploy.sh` ships only `jobs/whatsapp-*.json`** (line 557: `for source in "$ROOT"/jobs/whatsapp-*.json`).
   `jobs/delivery-admission.json` therefore will not reach the install directory until that glob is
   widened (`jobs/*.json`, or a second loop). This is a one-line change in a file out of this delivery's
   scope; without it the job never gets a definition from a deploy.
4. **`jobs/delivery-lane.json` is not installed**: its `wake` needs the coordinator's conversation id
   (`"session": "COORDINATOR_SESSION_ID"` is a placeholder). Nothing about it was exercised, so nothing
   about it is claimed.
5. **Wiring the test into the gate** - one line in `scripts/test.sh`, which this delivery does not own.
6. **Whether the wake should instead be a `subagent` action with a reserved child capacity** rather than a
   wake into the operator's conversation. Both are budgeted; the wake is what the brief asked for.

## 7. What I did not verify

- **No real delivery was admitted and no real branch was landed by any of this.** The fixtures are
  synthetic; the placement case is a rehearsal against the real repository with a scratch record, and its
  branch is read through the `--tip-ref` seam because the real branch is no longer on `origin` (tonight's
  landing deleted it). Nothing was pushed to `main`, no branch was merged or deleted, no worktree was
  pruned, no live node state was touched, and no job was enabled.
- **No gate was run on a merged candidate** - that is `scripts/merge-lane.mjs`, already merged, and out of
  scope here.
- **The wake path was never executed**: `delivery-lane` is not installed, so no wake happened, and the
  budget was therefore not exercised. The synthetic emit proves the event path up to the store (0
  consumers, as expected), not a delivered wake.
- **The `--tip-ref` seam** exists for tests and rehearsals; a real run records `observed.source: "pushed"`.
  I did not verify behaviour against a remote that is not named `origin`, or against a branch pushed to
  another remote. `refs/remotes/origin/<branch>` is the only pushed ref the rule reads.
- **Stale remote-tracking refs**: the pass does not `fetch` (`observed.fetched: false`). If `origin/<branch>`
  is stale in the named clone, "pushed" is judged from that stale ref; the merge lane's own discovery
  fetches, and the trigger deliberately does not add a network effect to a 60-second schedule.
- **`WA_DELIVERY_STORE` and `--store`** were exercised only against scratch directories.
