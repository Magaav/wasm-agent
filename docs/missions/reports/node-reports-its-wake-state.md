# node-reports-its-wake-state (G, Fable 24/11) - ready-2

**Ready-2.** Branch `change/node-reports-its-wake-state`, now STACKED on `change/version-names-the-tree`
(e32b6a76), which is itself on `origin/main` 42507780. Nothing pushed: the orchestrator lands it after the r8c
install. One Rust build, no second install.

| what | commit |
|---|---|
| 1. the node can say its own wake state (`selfloop.wake_facts`) | `19355ffa` |
| 2. the tick answers its facts, raise or not (`wa_orchestrator_tick`) | `33347737` |
| 3. `/health.wakes`, published by the placement tick | `a49e2f9a` |
| 4. the facts row: a real scratch node, healthy and broken | `9fdb6800` |
| 5. report (ready-1) | `a1a3568b` |
| **6. THE RULE APPLIED - verify-install.sh + upgrade.sh + the one judge** | **`eba5cc02`** |
| **7. THE RULE APPLIED - the product watchdog** | **`a238fc6f`** |
| 8. a row for each red, judged by the shipped judge | `b4c41ee6` |
| 9. canary `loopback` -> `child-node`, printed | `ee144565` |
| 10. the number: 1.08 ms/tick on 10,000 rows, every query on an index | `d220db9e` |
| 11. dates: the stall was 24/11 | `fb0666ab` |
| 12. watchdog: the status line carries the verdict (unit test) | `4c1240f1` |
| 13. adopt main's `record_tick` seam (it moved under this branch) | `2009183b` |
| 14. **merge origin/main (d452b20c)** - the landing now has nothing to resolve | `11298a25` |
| 15. judge: WAITING before the first tick, a required field per red, the lane names | `2becbd4b` |
| 16. watchdog: the same rule in Rust | `0dbb1e3e` |
| 17. rows: waiting, a missing field named, the cold start that would have been a false red | `5becfea1` |
| 18. report: 1c and 1d (what an install does with a fail) | `bf12ac35` |
| 19. **merge origin/main (345e51be)** - main's own `selfloop.lua` change, rows re-run on it | `e58617c2` |

## 1. The rule, applied (commits 6, 7, 8)

Approved as written; now shipped. Four reds BY NAME, one judge, three readers.

| red | says | bound |
|---|---|---|
| `wakes_unknown` | `/health` has no wakes object, or `known != true`, or a last tick outcome that is neither `ok` nor `selfloop_tick_failed` | - |
| `selfloop_tick_failed` | the last tick raised, with the error it raised | - |
| `wakes_not_publishing` | the facts have not been republished | `WA_WAKES_PUBLISH_SECONDS`, 30 |
| `self_wake_stalled` | a due, UNHELD row is that old with an IDLE lane (a busy lane is a wake turn running) | `WA_WAKES_STALL_SECONDS`, 120 |

* **the judge**: `scripts/lib/health-wakes.sh:75` (`wa_health_wakes_verdict`) - reads one `/health` body on
  stdin, prints one line per red (or one GREEN), returns 0 green / 1 red / 2 unjudgeable, and prints the
  UNKNOWN line too. awk + sed, no jq: these readers run on nodes whose PATH has none. It reads the wakes
  object as an OBJECT (`wa_health_json_object`, a brace matcher that honours strings at `:39`), not by
  grepping a key that exists elsewhere in the body (`/health` has one `"wakes":` key; the row asserts it).
* **the post-install check**: `scripts/verify-install.sh:281-289` - one `record fail` per red, an UNKNOWN
  recorded as a failure, a missing judge recorded as a failure. This is the reader that would have failed the
  24/11 node at install time.
* **the upgrade**: `scripts/upgrade.sh:1117` prints the same verdict in its `verifying` phase and never gates
  on it: an install must not be rolled back for a wake the node owes itself.
* **the product watchdog**: `rust/wa-watchdog/src/health.rs:83` (`wake_verdict`), the same rule and the same
  two bounds as consts at `:76`. Every probe carries it (`Probe.wakes`, `:157`), the supervisor writes the
  line into `status.json` (`state.rs:258`, `supervisor.rs:157`), and `wa-watchdog status` prints it - asserted
  in the round-trip test (`4c1240f1`).

**THE LINE THE WATCHDOG DOES NOT CROSS, and it is pinned by a test**: a wake red is NOT part of
`Probe::ready()`. `ready()` is what declares a kernel up and what a swap uses to decide it committed; a node
whose loop is dead answered `ok:true` for 2.5 hours on 24/11, and restarting it under a running turn - or
rolling back an install for a wake it owes itself - would be worse than reporting it. So `health.rs`'s
`a_wake_red_is_reported_and_never_makes_a_node_unready` asserts `ready() == true` on a body that carries a
red, and `wa-watchdog status` keeps its documented exit code (0 = the supervisor is healthy).

### A row for each red, on a real scratch node (commit 8)

`scripts/test-health-wakes-rule.cjs`: one gate row, ELEVEN named case-rows (round 3 added waiting, missing_field, lane_names, cold_start_grace and single_keys), wired at `scripts/test.sh:2842`
beside the facts row. Each red is produced by a state the node is really in, and judged by the SHIPPED judge
(and, for the install check, by `verify-install.sh --json` end to end, not by a copy of the rule):

| case | how the state is reached |
|---|---|
| `green` | a wake scheduled through the model's own `wake` tool is dispatched by the node's tick; verify-install reports the loop ok |
| `selfloop_tick_failed` | `boot` dropped from the node's own ledger through the product's sql host, after `selfloop.setup()` ran (so setup does not heal it); the red carries `no such column: boot` |
| `self_wake_stalled` | the same node judged at `WA_WAKES_STALL_SECONDS=3` with the row really due and the lane really idle - the same judge, the same body; and the shipped 120 s bound does NOT fire on the same body |
| `wakes_unknown` | `attempts` (and the index over it) dropped: `wake_facts` raises, the node says `{known:false, reason:"wake_facts_failed"}`, and verify-install names `wakes_unknown` |
| `wakes_not_publishing` | **a real body with ONE FIELD AGED**, said so in the row's own output: a working node republishes every 2 s, so a 41 s-old answer cannot be produced by a live node in a test |
| `jq_agrees` | the report's jq form and the shipped awk judge return the same verdict and exit code on every captured body, at both bounds (SKIPPED, never passed, with no jq) |

Why not a live node for `wakes_not_publishing`: the only way to make a node's answer older than 30 s is to
stop the placement thread, and the node has no switch for that (a full SIGSTOP stops `/health` too). The row
ages one field of a captured body and says so; the rule is judged on every other field.

`scripts/lib/scratch-node.cjs` is now the harness both `/health` rows share (the scratch-home refusals, the
tree's own binary, the stub provider, a real node). `scripts/test-node-wake-facts.cjs` was moved onto it with
every assertion unchanged, and re-run green (commit 8).

## 1b. MAIN MOVED WHILE THIS ROUND RAN (commits 13, 14) - the conflict this branch had, and its fix

MEASURED after ready-2 was first written: `origin/main` is now **d452b20c** (the node's own swap), not
42507780, and `e254e16a` had put the tick-outcome rule this branch rewrites into `M.record_tick(called,
failure)` (plus `M.orchestrator_tick`, exported for rows). `git merge-tree --write-tree origin/main HEAD`
**conflicted** in `lua/core/subagents.lua` - the branch could not have landed as it stood.

Fixed in two steps, both measured:

1. `2009183b` takes origin/main's version of that file verbatim and re-applies this branch's one change on
   top, so the tick's rule is main's `record_tick` and this branch only adds the facts answer. Since the base
   in my history was still 42507780, the three-way merge STILL conflicted (main changed those lines, mine
   changed them differently) - which is why the second step exists.
2. `11298a25` merges origin/main into the branch, resolving the single hunk to this branch's side (main's
   `return "ok"` replaced by the facts answer, `M.record_tick(called, failure)` left exactly as main has it).
   The branch now carries main as a parent, and **`git merge-tree --write-tree origin/main HEAD` is clean**.

Evidence after the merge: `git diff origin/main -- lua/core/subagents.lua` is exactly the facts block and
nothing else; main's own rows are now IN this tree and green against it -
`scripts/test-tick-failure-log.lua` (9 checks: logged once, silent on a repeat, cleared by a clean tick,
logged again when it returns), `scripts/test-resume-window.lua` (41 checks), and main's updated
`scripts/test-selfloop-pause.lua` (200 checks, was 198 on this branch's old base).

## 1c. THE FALSE RED AN INSTALL WOULD HAVE HIT (round 3, and it was the reviewer's point 1)

MEASURED by the review: the stall rule was TRUE of a GOOD node right after a restart. Rows that came due while
an install had the node down are minutes old, the lane is idle, the first tick has not dispatched yet - and
`verify-install.sh` runs exactly then. Three things changed, and each has a row on a REAL scratch node
(`scripts/test-node-wake-facts.cjs`, scenarios c and d):

- **The facts carry the process's own clock.** `wakes.first_tick_at`, `wakes.ticking_for_s` and
  `wakes.ticks_since_start` (`lua/core/selfloop.lua`: `M.note_tick`, set before `setup()` so a tick that dies in
  setup still counts). The age the stall may count is `min(oldest_dispatchable_age_s, ticking_for_s)`: a row is
  not older than the process that was supposed to dispatch it.
- **Before the first tick the verdict is WAITING, not green and not red** (`wakes_not_reported_yet`, the shape
  `serve.rs` already answers). `verify-install.sh` calls `wa_health_wakes_wait <port> 30` and only what it finds
  after that bound is judged; a node that never publishes is UNKNOWN, which is a failure, as before. THE BOUND IS
  30 s AGAINST A 2 s TICK: the placement thread ticks every 2 s (`sleep(Duration::from_secs(2))`,
  `rust/wa-capabilities/src/serve.rs`), so 30 s is fifteen ticks, not two - a first tick on a loaded node with a
  large ledger can take far longer than the 1.3 s measured on a scratch node, and the bound only costs time when
  something is already wrong (a publishing node answers in its first second).
- **A row the node is deliberately holding is not a stall.** `wakes.deploy_waiting` (from the tick's own result)
  is subtracted, so a landing node whose selfloop refuses new turns during a deploy is not reported as stalled.

MEASURED, scenario (c) - a ledger with one pending row 600 s old, cold start, judged from the first answer the
node gives: verdicts `[3, 0]` (waiting, then green), never a red; the row was dispatched on the first tick; the
shipped reader said `GREEN wakes: last_tick ok, 0 dispatchable (0 held for a deploy), oldest 0s, ticking 0s, lane
busy, worker alive` **1.3 s after the restart**. Scenario (d) - the same, with `boot` dropped: `[3, 1]`, and the
reader names `RED selfloop_tick_failed: no such column: boot` inside the bound.

**UNKNOWN IS NOT YES, IN THE JUDGE ITSELF (point 2).** The readers were sed one-liners whose greedy `.*` took the
LAST occurrence of a key and whose missing field silently skipped the check. Now one depth-aware awk reader takes
the FIRST top-level occurrence, and every field the rule reads is REQUIRED: a body without `published_age_ms`,
`dispatchable`, `oldest_dispatchable_age_s`, `ticks_since_start`, `ticking_for_s`, `node_state.state` or
`worker` is `RED wakes_unknown: <field> is missing from ...`, by name. The state names are a closed set -
`idle`, `busy`, `upgrading` (`rust/wa-capabilities/src/serve.rs`) - and a name the rule does not know is a red,
so a new state cannot switch the checks off. "No turn is running" is by those names (`lane != busy`) **and the
node's own `worker`**: `busy` with `worker: stalled` is a wedged lane, and a wedged lane must not hide a dead
loop. The row asserts that each key occurs exactly ONCE in its object on a real body (`wakes`, `known`,
`outcome`, `error`, and `reason` on the unknown answer).

**KNOWN GAP, WRITTEN DOWN AND NOT FIXED NOW.** The rule reads ONE `node_state`. On a node with several lanes a
busy lane reports `busy`, which suppresses the stall - so a due row that only the IDLE lanes could dispatch is
hidden while any other lane is busy. The fix is per-lane facts (the row's session, the lane that owns it), which is
a larger change to what the tick publishes and is not in this round; what the rule does bound today is the case
that cost the 2.5 hours: no lane busy and nothing dispatched.

**THE SAME RULE IN THE WATCHDOG (point 2, second half).** `rust/wa-watchdog/src/health.rs` is the product's
judge for the same bodies; it got the same three changes (a `Wakes::Waiting` verdict, the required fields, the
names and the first-tick grace), and its unit tests now carry the new body shape - 47 tests, including the
before-the-first-tick body, the missing-field bodies, the wedged lane, the deploy-held row and the 600 s row on a
3 s process.

## 1d. WHAT A FAILED `verify-install.sh` DOES ON A REAL INSTALL TODAY (point 3, one answer)

**Nothing rolls back by itself.** `verify-install.sh` is the sentinel deploy protocol's EFFECT verification
(`rust/wa-sentinel/src/deploy_protocol.rs`, `verify_install` -> `actual_verification_failed`), run after the
installer has already replaced the files: on a fail no `verification.json` is written, the wave never reaches
`verified` (`lua/core/wave_autoflush.lua`: `native_installation_verification_missing` / `_mismatch`), and the
installed build stays on disk and running - the way back is the explicit `wa update <node> --rollback`
(`scripts/rollback-node.sh`, from the pair `deploy.sh` keeps in `<install>/rollback/`). On the laptop
`scripts/deploy.sh` does not even run it (it ships it and prints the command), and `scripts/upgrade.sh` prints the
same wakes verdict without gating it - the only AUTOMATIC rollback in the install path is `upgrade.sh`'s
health/listener check, which never reads a wake. So a false wake red does not break a node: it BLOCKS A RELEASE -
which is why the bound in 1c is sized to a cold start and not to a guess.

## 2. One Rust install, not two (measured, not assumed)

The stack is real: `git log` is `... e32b6a76 (change/version-names-the-tree) <- my commits <- merge origin/main`.
**There was no `serve.rs` conflict to resolve**: the version branch changes `rust/wa-host/src/build_info.rs`,
`lua/core/init.lua` and `lua/core/update_banner.lua`, and REACHES `/health` through the `build` label's
composer (`serve.rs` mentions it in comments only - measured: `git diff origin/main..e32b6a76 --stat` lists
no `rust/wa-capabilities` file). Its `scripts/test.sh` addition is at line ~1006 and mine at ~2836, so the
rebase applied clean, five commits, no conflict markers. One release build of the stacked tree, and one
`cargo test -p wa-watchdog` run (both below).

## 3. The canary rename (commit 9)

Done, name only: every canary module that runs in a child says `mode = 'child-node'` (self-wake, chat, undo,
run-block, scheduled-jobs), `feature_canary.lua`'s header and default say it, and the verdict line prints it:

       self-wake              PASS  child-node: delivered
       broken-child           FAIL  child-node: turn: ...

`scripts/test-feature-canary.lua` asserts both new shapes (was: only that `FAIL` appears) - 64 checks, was 62.

**The REGISTRY ROW rename is NOT in this branch: first week after the cut.** Measured why it does not fit
cleanly: the row is an id in `config/features/features.json` (`name: self-wake`, `canary: self-wake`),
`scripts/check-features-registry.mjs` resolves `canary` to `lua/core/canaries/<canary>.lua` (so the module file
must be renamed with it), the row's recorded last success is keyed by the name (a rename resets it and the
feature reads stale until the next canary run), and `scripts/test-features-canary-installed.sh` asserts
`self-wake PASS` on an INSTALLED build - a test this branch cannot run here. That is a coordinated change, not
a rename in passing; the reader-facing confusion is fixed by the printed mode above.

## 4. The number (commit 10)

`scripts/bench-wake-facts.lua` seeds a synthetic ledger through the product's own sql host into the product's
own table shape, times the real `wake_facts` 300 times and prints each statement's plan. Measured on avell
(16 cores, this tree's release build):

| rows | median | mean | p95 | max |
|---|---|---|---|---|
| 0 | 0.05 ms | 0.05 ms | 0.06 ms | 0.09 ms |
| 1,000 | 0.16 ms | 0.16 ms | 0.17 ms | 0.33 ms |
| 10,000 | **1.08 ms** | 1.09 ms | 1.16 ms | 1.80 ms |

(10,000 rows: 3,333 due, 3,134 dispatchable, 3 sessions held.) Every statement uses an index - no scan:

    due            SEARCH self_wakes USING COVERING INDEX self_wakes_due_idx (status=? AND due_at>? AND due_at<?)
    dispatchable   SEARCH self_wakes USING INDEX self_wakes_due_idx (...) | USING INDEX
                   sqlite_autoindex_self_wake_pauses_1 FOR IN-OPERATOR
    held           SEARCH self_wakes USING COVERING INDEX self_wakes_session_idx (...) | USING INDEX
                   sqlite_autoindex_self_wake_pauses_1 FOR IN-OPERATOR
    last_dispatch  SEARCH self_wakes USING COVERING INDEX self_wakes_attempt_idx (attempts>?)

1.08 ms every 2 s is 0.05 % of one core, so the facts are published on EVERY tick: no every-Nth-tick
publishing, and /health keeps its 2 s resolution.

## 5. The dates (commit 11)

The stall was **24/11** (15:15Z-17:55Z; the tick-failure commit that closed it, 9c009cbb, is Tue 24 Nov
17:52Z). Six comments this branch added said 25/11, and two paragraphs already on main
(`selfloop.lua`'s UPGRADE_COLUMNS block from e254e16a, `subagents.lua`'s "tick never dies silently" from
9c009cbb) said it too - corrected in the same commit, because they are the same claim about the same
incident. NOT fixed, because it is history: the commit MESSAGES of 9c009cbb, e254e16a and 60691c09, and the
reports those rounds wrote, still say 25/11.

## What was run here, after the stack and the final build

| row | result |
|---|---|
| `node scripts/test-node-wake-facts.cjs <this tree>` | **pass** |
| `node scripts/test-health-wakes-rule.cjs <this tree>` | **pass**, 11 case-rows (green, 4 reds, waiting, a missing field named, the lane names, the cold-start grace, one key each, jq agreement), jq cross-check on 15 bodies at both bounds |
| `node scripts/test-verify-install.mjs` | **pass**, 22 checks (was 19 on the base: the fixture now serves a real `/health`, and gains three - "a healthy node passes the self-wake rule", "a dead loop fails verification by name", "and every red is its own row") |
| `bash scripts/test-feature-canary.lua` (via `WA_SCRIPT`) | **pass**, 64 checks |
| `scripts/test-selfloop.lua` / `-pause.lua` / `-no-starve.lua` | **pass**, 109 / 200 / 174 checks |
| `scripts/test-cli-wake-row.lua` / `test-handle-wake.lua` | **pass**, 30 / 21 checks |
| `scripts/test-tick-failure-log.lua` and `scripts/test-resume-window.lua` (main's, now in this tree) | **pass**, 9 / 41 checks |
| `git merge-tree --write-tree origin/main HEAD` | **clean** (was a conflict in `lua/core/subagents.lua`; see 1b) |
| `cargo test -p wa-watchdog --lib` | **pass**, 47 tests (44 on the base plus the waiting body, the missing-field bodies and the 600 s row on a 3 s process) |
| `WA_BIN=<this tree> bash scripts/test-ledger-upgrade.sh` | **pass**: the released ledger upgrades, columns equal a fresh ledger's, a wake on it is dispatched by one tick |
| `WA_SCRIPT=scripts/bench-wake-facts.lua` (0 / 1,000 / 10,000 rows) | the numbers above |
| `cargo build --release` of the stacked tree | **pass** (one build) |

**Pre-existing failures on this machine, each run on a worktree of the stack's base e32b6a76 and failing
there identically:**

* `cargo test -p wa-watchdog --test integration`: `a_crashing_kernel_is_restarted_with_a_growing_backoff`
  (`[100,100,100,100]` vs `[100,200,400,400]`) and
  `a_swapped_in_kernel_that_dies_early_is_rolled_back_to_the_previous_binary` (`"starting"` vs `"healthy"`).
* `bash scripts/test-deploy-service-target.sh`: `the fixture's own listener never held port N (node said:
  unknown command: -e )` and four rows that depend on it.

Not run: the full `scripts/test.sh` / `scripts/fast.sh` (the gate is the orchestrator's, and rule 15 puts one
heavy suite at a time behind `flock`); `scripts/test-features-canary-installed.sh` (needs an installed build).

## What this does not prove (accepted gaps)

* The component-core path is not exercised (written gap, accepted).
* `wakes_not_publishing` is judged on a real body with one field aged, not on a live stalled publisher (see
  above: no way to stop the placement thread alone).
* The watchdog's verdict is proven by unit tests on real-shaped bodies and by the rule rows on the shell
  side; a live node driving a real `wa-watchdog` supervisor through a red was not built (it needs a fake
  kernel that answers `/health`).
* The rule's two bounds are environment knobs on the shell side (`WA_WAKES_STALL_SECONDS`,
  `WA_WAKES_PUBLISH_SECONDS`); the watchdog's are constants. A node that needs different bounds would need
  the same knobs in its config - named, not done.

## Texts to approve

Every new operator- or model-facing string this branch adds, verbatim:

1. `/health` field `wakes`, with `known`, `reason`, `note`, `answer`, `error`, `published_age_ms`,
   `last_tick{at,outcome,error}`, `due`, `dispatchable`, `held_due`, `oldest_dispatchable_age_s`,
   `last_dispatch_at`, `now`; outcomes `ok` / `selfloop_tick_failed` / `unknown`; reasons `wake_facts_failed`,
   `wake_facts_unreadable`, `tick_call_failed`, `wakes_not_reported_yet`.
2. `"note": "the placement tick answered without wake facts"`; `"note": "no placement tick has published wake
   facts since this node started"`.
3. The rule's lines: `GREEN wakes: last_tick ok, <n> dispatchable, oldest <s>s, lane <lane>`;
   `RED wakes_unknown: <reason>`; `RED selfloop_tick_failed: <error>`; `RED wakes_not_publishing: <ms> ms old
   (bound <s>s)`; `RED self_wake_stalled: <n> due row(s), oldest <s>s, lane idle`; `UNKNOWN wakes: <why>`,
   including `UNKNOWN wakes: /health has no wakes object (a node older than this rule, or a body that is not
   one)` and `UNKNOWN wakes: no /health body to judge`.
4. `verify-install.sh`'s row name: `the self-wake loop`, and its refusals `scripts/lib/health-wakes.sh is
   missing from this tree` / `the node did not answer /health`.
5. `upgrade.sh`'s line: `self-wake loop: <the verdict above>`.
6. The watchdog's status field `wakes` and its `status.json` key of the same name.
7. The canary line: `  <feature>  PASS  <mode>: <stage>` and `  <feature>  FAIL  <mode>: <stage>: <detail>`,
   with mode `child-node` or `read` (was `loopback`).
8. The rows' verdict lines: `node wake facts ok (...)`, `health wakes rule ok (6 rows: ...)`, and the
   refusals `refused(real_node_home): ...` / `refused(no_wa_binary): ...`.
