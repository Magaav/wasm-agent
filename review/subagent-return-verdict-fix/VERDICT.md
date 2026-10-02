# Independent re-verification: `change/subagent-return-verdict-fix`

- Delivery: branch `change/subagent-return-verdict-fix`, tip `216ed3e4205978c100c65218d6fe55ec764403d9`
  (on top of `7bdddf6`, which contains the reviewed `7d73174`), producer session
  `child:dispatch:1280e7bd-c677-4d26-826b-5f4879496ed7`. This is the second half of ONE review: my verdict
  on `7d73174` was **narrowed** (review commit `5104e91`, 10 findings); this verifies the delta that answers
  them and records on the new delivery record.
- Reviewer worktree: `C:/Users/Victor/.wasm-agent/wa-worktree-childdispatchffda98e4-b412-4341-9841-e91de6e5c548`,
  branch `review/subagent-return-verdict-fix`, based on the tip. Not pushed; no node restarted; nothing sent
  to any chat; the live install untouched; `job enable` was never run outside isolated homes.
- Model note: this node's provider refuses `gpt-6-luna` (`model_not_servable`), so this ran on
  `deepseek-v4.1-flash`/high - the producer's family. Independence is the lane, not the model.
- Verdict: **narrowed**. All seven findings I raised are answered and I reproduced the answers. Three claims
  in the response are narrower than stated, and the residues are recorded below.

## What I ran (and the binary)

`rust/wa-sentinel/target/release/wa-sentinel.exe` from the producer's worktree (17:59, copied into mine; the
commit is dated 18:06). Behaviour-verified rather than assumed: it carries `already_woken:`,
`completion-wake-superseded`, `wake-dedupe-`, `_prepare_is_only_for_a_wake_action`,
`dedupe_key_is_only_for_a_wake_action`, `dedupe_key_must_name_an_event_field`, and every new behaviour below
was exercised through it. `scripts/test-completion-wake.cjs` was run with the canonical tree's `wa.exe`
(no `wa.exe` exists in either worktree) plus this tree's `lua/` via `WASM_AGENT_LUA_ROOT`, which is where the
supersede consumer lives.

```
subagent return ok (168 checks; real sentinel, real git checkouts, no model)          # exit 0
deploy shipped ok (51 checks; 7 rules from the installers, 6 examples, 26 from ship-wave.mjs)
completion wake ok (real scheduler, mock inference, deduplication, one failed-child notice, no recursive
  child, the hook supersedes the notice while its marker is present)
```

Note: the commit message says `check-deploy-shipped.mjs` has 49 checks; it prints **51**.

## My findings, re-tested

### 1+2 `verdict-lie` - FIXED (content and predicate)
```
jobs/on-subagent-return.json -> deploy required at the wave's end
jobs/subagent-return-observe.json -> deploy required at the wave's end
jobs/whatsapp-copilot.json -> deploy required at the wave's end
scripts/upgrade.sh -> deploy required at the wave's end
docs/JOBS.md -> no install impact   tests/x.cjs -> no install impact
```
An unreadable or malformed manifest is `cannot be computed` (`shipped_manifest_unreadable` /
`shipped_manifest_malformed`), never "nothing is shipped". End to end through the real observe pass, a child
whose only change was `jobs/on-subagent-return.json` now reads `deploy required`.

The guard itself, mutation-tested in clones (`mutations.out`):
- add `cp -f "$ROOT/docs/JOBS.md" ...` to deploy.sh (an existing path the manifest does not cover) -> **RED**
  `FAIL the predicate covers docs/JOBS.md (rule docs/JOBS.md)`
- drop `scripts/upgrade.sh` from the manifest -> **RED** `FAIL the predicate covers scripts/upgrade.sh`
- manifest covering nothing -> **RED** (first rule)
- drop the wave closure -> **RED** `FAIL the predicate covers scripts/delivery-admission.mjs (written by ship-wave.mjs)`
- drop all globs -> **RED** `FAIL the predicate covers scripts/wave-adapter.mjs (written by ship-wave.mjs)`

### 3 `dedupe` - FIXED and now pinned
Mutating `eventIdFor` to `` `${childId}-${Date.now()}` `` makes the suite **red**:
`AssertionError: a lost cursor emits nothing and reports the duplicates ({"emitted":10,"duplicates":0,"reconciled":0})`.
Against the real store, real watcher, fake node:
```
pass1: emitted=1 duplicates=0 deliveries=1 wakes=1 revision=2
ledger: {"keys":{"child-dedupe":{"at":1790976776,"delivery":1}},"schema":1}
re-put revision=4 pass2: emitted=1 duplicates=0
deliveries: rev2#1:completed:2 events, done=true | rev4#2:completed:already_woken:child-dedupe; no second message for this child
wakes for one settle: 1
```
A re-put (revision 2 -> 4) plus a lost cursor creates a second *delivery*, which completes
`already_woken:<child>` and sends **no second wake**. A pending intent whose payload still matches the store's
reconciles (`emitted=0 reconciled=1`) and converges; the next pass is quiet.

### 4 `prepare-boundary` - FIXED at the definition boundary
```
wake + prepare                   -> accepted
run + prepare                    -> REFUSED: sentinel: prepare_is_only_for_a_wake_action
run + dedupe_key                 -> REFUSED: sentinel: dedupe_key_is_only_for_a_wake_action
pipeline run step + prepare      -> REFUSED: sentinel: step_1_prepare_is_only_for_a_wake_action
pipeline foreach inner + prepare -> REFUSED: sentinel: step_2_prepare_is_only_for_a_wake_action
pipeline step + dedupe_key       -> REFUSED: sentinel: step_1_dedupe_key_is_only_for_a_wake_action
wake + bad dedupe_key name       -> REFUSED: sentinel: dedupe_key_must_name_an_event_field
```
The case that was accepted and silently ignored is now refused by `job put`.

### 5 `notification` - FIXED, both halves verified separately
Writer (my own isolated store and watcher; the producer's suite hand-writes the marker, so this half needed
its own evidence):
```
right after enable, before any tick: marker exists=false
after a watcher tick: {"at":1790976810,"by":["onSubagentReturn"],"schema":1}
after disable: marker exists=false
```
So the marker is derived from the store's own enabled state on a runner tick, not hand-set. Consumer (the
producer's `test-completion-wake.cjs`, real node + mock provider, this tree's Lua): with the marker present
the outbox row records `state='superseded'` and no wake is sent; with it removed the outbox wake resumes.
And while the marker is present the hook must still wake - verified: `marker before the pass: {"by":
["onSubagentReturn"]...}` -> `observe: emitted=1` -> `wakes while the marker is present: 1` carrying
`DEPLOY VERDICT: deploy required at the wave's end`.
The block carries the notice facts (`notification:` line, from a packet shaped like `evaluation_packet`):
`model: served-model  provider: some-provider  reasoning: high  profile: task-worker  child_error: runaway_guard  duration_s: 12.5  usage: {"available":true,"prompt":100,"completion":20,"total":120,"cost_usd":0.004}  outbox_review: {...}`.
Only the outbox notice's raw `row.detail` string is not reproduced; its content (state, error) is.

### 6 `gate-floor` - FIXED
`scripts/test.sh` registers `run_proof_fixture subagentReturn 168`; the suite emits 168; 167 is refused
(`proof verdict refused: check count dropped: 167 < 168`).

### 7 both definitions install DISABLED - CONFIRMED
`job put` installs `enabled: false` (live, isolated store: `on-subagent-return` put status=0 `enabled=false
revision=1`, `subagent-return-observe` the same), and the suite asserts
`hook.enabled === false && source.enabled === false` after installing both shipped definitions.

### 8+9 `verdict-scope` - FIXED
```
tip with no merge base against origin/main -> cannot be computed (changed_paths_unmeasured: no_merge_base_with_origin_main)
tip equals main + uncommitted ui/app.js   -> changed_paths=["ui/app.js"] -> deploy required at the wave's end
record says dirty=1, checkout is clean    -> cannot be computed (uncommitted_work_reported_but_not_measurable: recorded dirty+untracked=1)
```

### 10 `cursor` - FIXED for a frozen measurement, still open when the measurement moved
Pending intent, same payload: `pass A: emitted=0 reconciled=1`, `pass B: emitted=0`, cursor
`reported=[child-dedupe] pending=[]` - it converges. Pending intent whose payload no longer matches what the
pass would emit now (the child's checkout gained an untracked file after the emit):
`pass A: duplicates=1 reconciled=0 errors=[]`, `pass B: duplicates=1`, cursor `reported=[] pending=[child-dedupe]`
- it re-emits on every tick for ever. No extra wake (the store dedupes), but the convergence claim holds only
while the measurement is unchanged.

## Residues I leave (new findings, all unresolved)

- **R1 shipped-set-guard (narrowed).** The re-derivation is narrower than the response states. The parser
  derives only: deploy.sh -> {the plugin wasm path, `scripts/deploy.sh`, `scripts/lib/service-target.sh`};
  upgrade.sh -> {`rust/`, `ui/`, `skills/`, `scripts/upgrade.sh`} (from a hard-coded variable table plus two
  `includes()` assertions, not from the copies); plus the 26 files `ship-wave.mjs` writes. It cannot see
  `"$ROOT"/x`-style sources (deploy.sh's dominant style: jobs/**, scripts/whatsapp-*, scripts/lib/*,
  scripts/wave-*, scripts/subagent-return-*, scripts/deploy-shipped.json) nor a `cp` without `-f`/`-R`.
  Evidence: dropping `jobs/` from the manifest -> **green** (M6); dropping `scripts/whatsapp-*` and
  `scripts/subagent-return-*` -> **green** (M9c); an unflagged `cp "$ROOT/docs/JOBS.md"` -> **green** (M5,
  7 rules instead of 8). So the classes that caused my original finding 1 are covered by the manifest's
  *content*, not by the check, and a future installer change in that style would drift silently.
- **R2 shipped-set-guard (unresolved).** A derived rule with no example in the tree is skipped with a note:
  `note: rule rust/plugins/.../wa_plugin_whatsapp_transcript.wasm has no example in this tree (nothing to
  check)` - 2 of 8 rules in my mutated trees. Fail-open for a copy of something that does not exist in the tree.
- **R3 cursor (unresolved).** `effectExists` is called with the *recomputed* event, so `payload_match` decides
  convergence; passing `pending.payload` would make the intent itself the receipt's subject.
- **R4 gate-floor (unresolved).** `check-deploy-shipped.mjs` runs under `gate_run`, not `run_proof_fixture`,
  so its 51 checks have no floor: internal checks could be deleted with the gate green.
- **R5 wake-ledger (unresolved).** `wake-dedupe-<job>.json` gains one entry per child ever woken and is never
  pruned (bounded by child count, ~60 B each).
- **R6 supersede-ordering (unresolved, inherent).** The marker appears only on a runner tick, so a settle
  landing between `job enable` and the first tick can still produce two wakes; while the marker is absent the
  outbox wakes, and while it is present the hook must.
- **R7 doc-number (unresolved, trivial).** The commit message says 49 checks for `check-deploy-shipped.mjs`;
  it prints 51.

## Not verified

- `cargo test` for `rust/wa-sentinel` ("the sentinel's own 37 tests") - it would need a build I did not do.
- The full gate (`scripts/test.sh`) - by instruction.
- The consumer half was run with the canonical tree's `wa.exe` (no `wa.exe` is built in either worktree) plus
  this tree's Lua; the producer's own CI-style run would use a freshly built binary.
- A live node was never touched, so the outbox/hook interaction is verified as a pair of halves (Lua consumer
  under a real serve process; marker writer under a real watcher), not as one live end-to-end turn.

## What a reviewer should check when the notification moves into this hook

Unchanged from my first verdict, plus: that the manifest's hand-written classes (`jobs/**`,
`scripts/whatsapp-*`, `scripts/subagent-return-*`) are either re-derived or the drift guard's coverage is
documented; that the guard fails on a `"$ROOT"/x`-style copy and on a rule with no example; and that the
pending-intent reconciliation is pinned by a check that fails when the payload moves.
