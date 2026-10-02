# Independent review: `change/on-subagent-return`

- Delivery under review: branch `change/on-subagent-return`, tip `7d731745f37239169b8afd1ad329971c9e561610`
  (1 commit ahead of `origin/main` `2f02b4c`), producer session
  `child:dispatch:1280e7bd-c677-4d26-826b-5f4879496ed7`.
- Reviewer worktree: `C:/Users/Victor/.wasm-agent/wa-worktree-childdispatchffda98e4-b412-4341-9841-e91de6e5c548`,
  review branch `review/on-subagent-return`, based on the tip. Not pushed; nothing sent to any chat; no node
  restarted; the live install untouched; the canonical tree and the producer's worktree were only read.
- Model note: this node's provider refuses `gpt-6-luna` (`model_not_servable`), so this review ran on
  `deepseek-v4.1-flash` / high - the same family as the producer. Independence here is the lane (a separate
  session, a separate worktree, my own fixtures), not the model.
- Verdict: **narrowed**. The mechanism is sound and I reproduced its central guarantees, but the shipped-set
  predicate is incomplete in the unsafe direction (two confirmed classes) and one `prepare` boundary claim is
  false for a nested step. Do not enable the hook on the live node until finding 1/2 are fixed.

## 1. The suite, and mutations that must make it red

`node scripts/test-subagent-return-hook.cjs` (real sentinel, isolated home, real git checkouts):

```
subagent return ok (90 checks; real sentinel, real git checkouts, no model)
```

90 checks, **0 skips** (`grep -c '^SKIP'` = 0), exit 0. Five mutations in fresh clones of the tip, each run
with the same command:

| # | mutation | result |
|---|---|---|
| 1 | `DEPLOY_SHIPPED_DIRECTORIES = ['ui-x/', ...]` (the path predicate) | **red**: `AssertionError: child-completed-ui: verdict "deploy required at the wave's end"` |
| 2 | the unreadable-artifacts branch returns `VERDICT.none` instead of `VERDICT.unknown` | **red**: `AssertionError: child-unknown-unreadable: verdict "cannot be computed"` |
| 3 | the event id becomes `` `${childId}-${Date.now()}` `` (the dedupe key) | **GREEN - SURVIVED** |
| 4 | `writeState` is a no-op (the cursor file is never written) | **green** - the store's own dedupe holds one wake per settle |
| 5 | mutation 3 + mutation 4 together | **red**: `every settled child woke the orchestrator exactly once (10 wakes for 5 settles)` |

Mutations 1 and 2 pin the predicate and the cannot-be-computed branch. Mutation 3 surviving means the suite
**does not pin the dedupe key**: with the cursor intact the store's dedupe branch
(`queued === 0 -> duplicates++`) is never taken, so nothing in the 90 checks would fail if the event id
stopped being the child's id. Mutation 4 shows the store dedupe does work as claimed; mutation 5 shows what
happens when neither guard is left. "One wake per settle" is therefore true by construction (two independent
guards), but only one of them is under test.

## 2. Making the verdict lie

Each case below was driven through the **real** observe pass (`--observe` against a fake `/subagents`, the
emit command being the real sentinel, an isolated `wa_jobs` store) and then through the real `--compose`
step; the payload was read back out of the store with `node:sqlite`. Driver: `probe2.cjs`
(verbatim output in `probe2.out`).

| case | exact result |
|---|---|
| no recorded branch and no worktree | `changed_paths_error=artifacts_unreadable` -> **`cannot be computed (changed_paths_unmeasured: artifacts_unreadable)`** |
| completion packet absent | `artifacts: UNREADABLE (...)` -> **`cannot be computed (artifacts_unreadable: ...)`** |
| recorded worktree no longer exists | `changed_paths_error=no_main_ref_in_child_worktree` -> **`cannot be computed`** |
| tip equals main (branch created at main, no commits) | `changed paths vs origin/main: 0` -> `no install impact` |
| tip equals main, uncommitted `ui/**` change | `changed paths vs origin/main: 0 ... dirty: 1` -> **`no install impact`** (finding 7) |
| tip not reachable from origin/main (orphan commit, no merge base) | the three-dot diff failed; the **two-dot fallback** ran: `diff --name-only refs/remotes/origin/main 316b20a...` -> `no install impact` (finding 8) |
| ONLY `scripts/whatsapp-read.mjs` | `deploy required at the wave's end` |
| then ONLY `tests/probe.cjs` | `no install impact` (flips back) |
| ONLY `scripts/wave-probe.sh` | `deploy required` |
| ONLY `scripts/lib/probe.cjs` | `deploy required` |
| ONLY `scripts/deploy.sh` | `deploy required` |
| ONLY `scripts/ship-wave.mjs` | `no install impact` - correct: `ship-wave.mjs` ships the `wave-*` closure, not itself |
| ONLY `scripts/lib/nested/probe.cjs` | `no install impact` - consistent with `deploy.sh`'s own `./lib/<name>` grep |
| **ONLY `jobs/on-subagent-return.json`** | **`no install impact`** (finding 1) |

**Finding 1 (verdict-lie, confirmed).** `scripts/deploy.sh:656` installs the job definitions:

```
for source in "$ROOT"/jobs/whatsapp-*.json "$ROOT"/jobs/on-subagent-return.json "$ROOT"/jobs/subagent-return-observe.json; do
  sed "s|PREPARED_BY_INSTALL|$INSTALL_MIXED|g" "$source" > "$INSTALL_DIR/scripts/$JOB_NAME.job.json" ... job put ...
```

The predicate has no `jobs/` class, so a child that only changes a job definition - something a deploy
installs and that changes what the node runs - is reported as having no install impact:

```
$ node scripts/subagent-return-hook.mjs --verdict --path jobs/on-subagent-return.json \
    --path jobs/subagent-return-observe.json --path jobs/whatsapp-copilot.json
{"schema":1,"verdict":"no install impact","shipped":[],"shipped_count":0,"paths":3}
```

**Finding 2 (verdict-lie, confirmed).** `scripts/upgrade.sh` installs itself
(`scripts/upgrade.sh:364-365`: `if ! cmp -s "$0" "$INSTALL_DIR/scripts/upgrade.sh"; then cp -f "$0" ...`) and
`scripts/deploy.sh:554` asserts the installed copy matches the tree. The predicate does not cover it:

```
$ node scripts/subagent-return-hook.mjs --verdict --path scripts/upgrade.sh \
    --path scripts/runtime-install-binding.mjs --path scripts/lib/full-gate-proof.mjs \
    --path scripts/lib/wave-guard.mjs --path scripts/ship-wave.mjs
"shipped":["scripts/lib/full-gate-proof.mjs","scripts/lib/wave-guard.mjs"]   # upgrade.sh is NOT shipped
```

So the two directions of the delivery's central promise hold for everything the predicate names, and fail for
two classes it does not: `jobs/**` and `scripts/upgrade.sh`. Both err toward "no install impact", which is the
direction the delivery exists to prevent.

## 3. One wake per settle

Driver `probe2.cjs`, real store, real sentinel watcher, a fake node counting the wakes it receives:

```
### d0_one_wake_per_settle
pass1: emitted=1 duplicates=0 deliveries=1 wakes=1
pass2 after the cursor file is deleted: emitted=0 duplicates=1 deliveries=1 wakes=1
after a re-put (revision 3) and a lost cursor: emitted=1 duplicates=0
store rows for child-dedupe: rev2#1:completed rev4#2:completed
wakes for one settle: 2
### d1_settles_while_the_pass_is_mid_run
pass A while it was still running: observed=1 settled=0 emitted=0
pass B after it settled: observed=2 settled=2 emitted=1 wakes=1
pass C (same children again): emitted=0 duplicates=0 wakes=1
### d2_settles_and_leaves_the_record_before_a_pass
pass A while child-gone was running: settled=1 emitted=0
pass B after it settled and left the record: observed=1 settled=1 emitted=0
wakes for child-gone: 0
```

- A lost cursor (fresh pass process, the state file deleted) does **not** produce a second wake: the store's
  `UNIQUE(job_id,revision,event_id)` answers `queued 0` and the pass records `duplicates=1`. Proven by
  construction for a fixed revision.
- **Finding 5 (dedupe, confirmed):** it is per `(job, revision, event_id)`. A `job put` that changes the
  definition - which the deploy performs whenever the job file changes (`deploy.sh` skips only an *unchanged*
  definition) - creates a new revision, and with the cursor absent the same settled child is emitted again:
  two deliveries, and the watcher submitted **two wakes for one settle** (`rev2#1`, `rev4#2`). "One wake per
  settle" is true by the conjunction of a cursor file and a revision-scoped store row, not by one invariant.
- A child that settles *during* a pass is picked up by the next pass with exactly one wake (d1) - no loss,
  a delay of at most one interval. The zero-wake path (d2) needs the child to leave the node's record: the
  node's task store is in-memory and nothing evicts a settled child while the node runs
  (`rust/wa-host/src/subagents.rs` `list`), so this is reachable only across a node restart inside the <=30 s
  window - narrow, but real, and not recoverable afterwards.
- **Finding 10 (cursor, confirmed):** `writeState` runs only when `emitted > 0`, and a deduped emit leaves the
  cursor unset, so a crash between emit and write leaves the pass re-emitting every tick forever (deduped, so
  no extra wake, but it never converges and `duplicates` grows).
- **Finding 6 (notification, confirmed, product level):** the node already wakes the child's parent session for
  every settled child - `lua/core/completions.lua` `classify` returns `true,"evaluation","delivery_ready_to_evaluate"`
  for a completed child, and `wa_completion_run` runs a `[Child completion notice]` prompt in `row.parent_session`.
  With this job enabled and bound to that conversation, one settle produces two wakes until the notification
  moves into `wake_blocks`. `docs/JOBS.md` states that move as future work, so this is a scoped claim rather
  than a false one - but it is the failure mode the commit message itself names.

## 4. `scripts/lib/proof-verdict.cjs` (2 lines changed)

The change adds exactly one entry to `prefixes`: `subagentReturn:'subagent return ok'`. Nothing else in the
validator moved (`validate` still requires process success, exactly one terminal verdict line, a count floor,
non-contradictory skip evidence and no failure evidence). It cannot make any existing proof cheaper: the kind
is chosen by the caller and no other check changed. Probed:

```
good (90 checks, floor 80)                 -> prints 0 skipped, exit 0
floor 91                                   -> proof verdict refused: check count dropped: 90 < 91
two verdict lines                          -> proof verdict refused: missing or duplicate terminal verdict
unknown kind                               -> proof verdict refused: unknown proof
2 skipped with two SKIP lines              -> prints 2, exit 0
```

No prefix collision: `subagentReturn:'subagent return ok'` cannot be satisfied by the `jobs` proof's
`subagent integration ok`. **Finding 9 (gate-floor, confirmed):** `scripts/test.sh` registers the proof with
floor **80** while the suite emits **90**, so ten checks could be deleted with the gate still green - the
"90 checks" claim is the suite's own output, not something the gate pins.

## 5. The `prepare` boundary (real sentinel, isolated home, `probe3.cjs`)

| probe | put | delivery | detail |
|---|---|---|---|
| script outside `WA_SENTINEL_SCRIPTS` | 0 | failed | `wake prepare step needs an absolute script inside WA_SENTINEL_SCRIPTS` |
| script path carrying `;exit 42`, as a **real file** inside the allow-list | 0 | completed, 1 wake | the file itself ran (`instruction in the wake=true`) and the delivery did not exit 42: the path is one argv element, not a command string - **no shell injection** |
| same metacharacter in a path that does not resolve | 0 | failed | refused at `resolve script` |
| `timeout_seconds: 999999999` | 0 | failed | `invalid_operation_budget` (`wa-operation` refuses `timeout > 86400`); a `run` action with the same value is refused at put with `sentinel: invalid_action_timeout` |
| `prepare` on a `run` action | 0 | failed | `prepare_is_only_for_a_wake_action` |
| relative `prepare.script` | 0 | failed | same allow-list refusal |
| **`prepare` inside a `pipeline` `run` step** | 0 | **completed** | the step's prepare script **never ran** (its marker file was absent; the script is valid - run by hand it creates the marker) |

**Finding 3 (prepare-boundary, confirmed).** The by-name refusal is checked on the top-level action only
(`if action["kind"].as_str() != Some("wake") && action.get("prepare").is_some()`), and `run_pipeline_step`
never reads a step's `prepare`. So `{"kind":"pipeline","steps":[{"kind":"run",...,"prepare":{...}}]}` is
accepted by `job put` and the knob is silently ignored - exactly the silent no-op the code says it refuses by
name. Refusals happen at execution, never at `job put` (put returned 0 in every row above); that is consistent
with the existing pipeline-step timeout handling, but it is not "refused" at the definition boundary.

## 6. Is `wake_blocks()` the single notification seam?

```
$ grep -rn "wake_blocks" rust/ --include=*.rs
rust/wa-sentinel/src/jobs.rs:400  (comment)
rust/wa-sentinel/src/jobs.rs:406  let blocks = wake_blocks(prepared.as_deref());
rust/wa-sentinel/src/jobs.rs:616  fn wake_blocks(prepared: Option<&str>) -> String {
```

One definition, one call site. The instruction half of a job wake is built in one place, and the wake prompt
is assembled in that same function's caller (`jobs.rs:407`), with the `[Sentinel notice]` provenance wrapper in
`rust/wa-sentinel/src/main.rs:925` and the job's own static `prompt` coming from the definition. Other wake
*text* exists - `main.rs`'s CLI wake verbs, the static prompts in `jobs/delivery-lane.json` and
`jobs/whatsapp-copilot.json`, and the Lua completion outbox - but none of them builds the instruction half of a
job wake. The seam is real for what it claims; the *notification* seam is not yet exercised, because the
outbox path is still live (finding 6).

`COORDINATOR_SESSION_ID` in `jobs/on-subagent-return.json` is an unbound placeholder, not substituted by
`deploy.sh` (it substitutes only `PREPARED_BY_INSTALL`). That follows the existing `jobs/delivery-lane.json`
convention and the definitions install disabled, so it is not a new defect - but the wake has no destination
until an operator binds it, and the delivery's own test substitutes the placeholder, so "the wake reaches the
coordinator" is proven only for a bound session.

## 7. No provider call, and `scripts/test.sh` is additive

- The hook imports only `node:fs`, `node:os`, `node:path`, `node:child_process`; its only network calls are
  `POST /subagents` (list/status) and the sentinel's own `job emit`. `--compose` reads `WA_JOB_EVENT_FILE` and
  makes no network call at all: the suite's offline compose check passed in my run, and the firing paths seen
  were exactly `/health`, `/subagents` and one `/chat` per settled child - that one message being the budgeted
  coordinator turn, not a call the hook makes to derive anything.
- `git diff -U0 2f02b4c..7d73174 -- scripts/test.sh`: **0 removed lines, 3 added** (`run_proof_fixture
  subagentReturn 80 node scripts/subagent-return-hook.cjs` plus its two comment lines). No suite dropped, and
  the registered name matches the new `proof-verdict.cjs` prefix.

## Proved

1. The observe pass reports every settled child in every state, including one whose artifacts cannot be read,
   and a child that has not settled is not reported.
2. The three unmeasurable cases (no branch/worktree, no packet, worktree gone) all read `cannot be computed`,
   never `no install impact` - end to end, through the real store and the real compose step.
3. The predicate flips on a single added/removed path, is pinned by mutations of its directory constant and of
   the unreadable branch, and matches `deploy.sh`'s own copy list for `scripts/whatsapp-*`, `scripts/lib/*`,
   `scripts/wave-*`, `scripts/subagent-return-*`, `deploy.sh`, `service-target.sh`, and `ship-wave.mjs`.
4. `prepare` is a `run` step at the process boundary: absolute + allow-listed, same shell, same 86400 s bound,
   event file, cancellation, and a wake with no instruction is refused rather than sent.
5. `wake_blocks()` is one definition and one call site.
6. `proof-verdict.cjs`'s 2-line change adds a key and weakens nothing.
7. The deterministic half costs no provider call; `scripts/test.sh` is additive.

## Unproven / not done

- The store-dedupe mechanism is unpinned by the suite (mutation 3 survived); I verified it only through my own
  mutations and fixtures.
- The double wake from the completion outbox (finding 6) was established by reading `completions.lua` and the
  job definition, not by running a live node - no live node, chat or install was touched.
- The node-restart zero-wake window (d2) was demonstrated with a fake node that drops the record; I did not
  restart a real node.
- I did not run the full gate (`scripts/test.sh`) by instruction; I ran the focused suite plus my own probes.
- Whether `git diff ... origin/main...<tip>` measures the right thing when a child's branch is behind main and
  main has moved was not exercised beyond the two-dot fallback case.

## What a reviewer should check when the notification moves into this hook

1. That the move **deletes** the outbox wake for the same settle rather than adding a block beside it - the
   test to demand is a live-path count of wakes per settled child (exactly one), not two message shapes.
2. That the moved block still carries the measured facts (state, branch, tip, worktree, diff source) rather
   than a re-derived summary, and that the untrusted event section still follows it.
3. That the child id remains the event id, and that the dedupe key is pinned by a check that fails when it
   changes (today it is not).
4. That the shipped-set predicate still matches `deploy.sh`'s copy list after the move, `jobs/**` and
   `scripts/upgrade.sh` included.
5. That the wake's session binding is explicit for the install (not the bare `COORDINATOR_SESSION_ID`
   placeholder), and that a re-`put` of a changed definition cannot re-wake a child already reported.
