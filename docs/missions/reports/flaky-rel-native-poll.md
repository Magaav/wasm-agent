# flaky-rel-native-poll: the hot-loop exemption read the host's clock, not the wait's

Branch `change/flaky-rel-native-poll`, base `975d4612`. Two commits:

- `070c4298` progress-guard: the hot-loop exemption reads what the wait asked and reports, not host wall clock
- `937b5866` rel-native-poll: hand every poll back 15 s late on the host clock, so the loaded-host shape runs on an idle machine

## What actually moved (measured, not guessed)

I instrumented a copy of the row outside the repo (a `dofile` wrapper on
`lua/core/progress_guard.lua` that logs `obs.signature`, `obs.say`, `obs.results_stable`,
`obs.wait_spent_ms`, `obs.wait_budget_ms`, `obs.waiting`, `obs.effects` and `state.repeats` per
`observe()` call) and ran it under 64 busy loops on this node. Six failing runs, verbatim trace
(`round=N sig= say= stable= wait_spent= budget= waiting= effects= changes= reps=A->B`):

    round=1 say=e3ab5ad6 wait_spent=7756 budget=0 waiting=true reps=0->1
    round=2 say=e3ab5ad6 wait_spent=1603 budget=0 waiting=true reps=1->1
    round=3 say=e3ab5ad6 wait_spent=1382 budget=0 waiting=true reps=1->1
    ...
    round=17 say=d37f8ed2 wait_spent=0   waiting=false reps=1->2
    round=18 say=d37f8ed2 wait_spent=0   waiting=false reps=2->3  -> guard_repeated_calls

- `obs.say` is IDENTICAL in every round of a run (the call learned nothing: same op, no output
  bytes), and `obs.results_stable` moves only through clock fields. `said_more` never fired.
- The one input that moves is `obs.wait_spent_ms`: the host's wall clock around the call,
  `host.now() - tool_started` (`lua/core/agent.lua`, the `round_wait_spent_ms` line before `070c4298`).
  Under load one `wait_s:0` poll took 0.4 s to 17 s, and `lua/core/progress_guard.lua`'s
  `local budget = math.max(1000, obs.wait_budget_ms or 0)` turned a poll that asked for NOTHING into
  a one-second budget. Every round that took >= 1 s therefore reset `state.repeats` to 1, and the
  loop only stopped when three consecutive rounds happened to come back in under a second (or when
  the `sleep 45` operation settled, `waiting=false`). That is exactly the measured spread: ran 4, 7,
  9, 13, 18, 19.

So the GUARD was load-sensitive, not only the test. The brief's `1 run in 6` was an underestimate on
this box under my harness (5 of 8, then 4 of 4); the mechanism is the same one.

## The fix

`lua/core/progress_guard.lua` (`070c4298`) gains `M.asked`, `M.waited` and `M.wait_cost`:

- `asked_ms` - what the call asked to wait for, from its own `wait_s`/`wait_ms` arguments or answer
  (0 when it names none);
- `spent_ms` - what the wait itself REPORTS it spent (`waited_s`/`waited_ms` in the answer, evidence
  pointers followed exactly as `M.said` does), and otherwise the host clock CAPPED AT `asked_ms`.

`lua/core/agent.lua` feeds those two numbers to `observe()` instead of the raw wall clock. A
`wait_s:0` poll now reports `waited_s: 0` (`lua/core/codemode_pending.lua:898-912`, the handle every
pending answer is built from) or, when its answer is silent, is capped at the zero it asked for - so
no amount of host delay can exempt it. A real 900 s await still spends its 900 s and keeps its
exemption, which is the case `r3/B6` was opened for.

## The proof

- 20 consecutive runs of `scripts/test-rel-native-poll.lua` on this commit under the brief's 64 busy
  loops, all green, every one at round 3 (two batches of 10; an earlier batch of 11 on the previous
  revision of the test was green too and was cut by the node, not by a failure).
- The assertion still discriminates: with `M.REPEAT_LIMIT_DEFAULT = 4` the row fails with `ran 4`,
  twice, then the constant was restored (working tree clean).
- `scripts/test-rel-native-poll.lua` (`937b5866`) now simulates the loaded host deterministically -
  every dispatch hands the call back 15 s later on the host clock, which is the measured shape on an
  idle machine. On the base (`/tmp/base-975d`, `975d4612`) that same file fails with `ran 31` and
  `ended with: the build finished`; on this branch it is green at round 3. Load is no longer needed to
  see the bug, and the row is no longer flaky either way.
- `scripts/test-no-silent-stops.lua` (`070c4298`) pins the derivation itself: a `wait_s:0` poll handed
  back after 17000 ms of wall clock spends 0 and is stopped at round 3; a 900 s await whose answer is
  silent spends its 900 s (capped at the ask) and keeps its exemption; a nested answer that reports
  `waited_s: 900` and one behind an evidence pointer that reports `waited_s: 0` are both read. On the
  base those checks die on the missing `wait_cost` symbol, which is why the end-to-end row above is
  the behavioural evidence and this one is the rule's statement.

Both rows are existing `scripts/test-*.lua` files, so they are wired into the fast path by
`scripts/fast.sh`'s row inventory (`scripts/lib/fast-rows.sh`) with no new wiring.

## The fast path (run, queued on the suite lock)

    flock -w 3600 -o ~/Work/missions/.suite.lock bash scripts/fast.sh

347 checks, **1 failed** (`fast result FAILED (347 checks, 1 failed, 0 skipped)`), on a binary BUILT
FROM THIS TREE (`/home/victor/wasm-agent/target/m-flaky-rel-native-poll/release/wa`, build
`a6a3905fee14`, `fresh: built from this tree`). All 283 Lua rows passed except `scripts/test-font-setup.lua`
in an earlier, heavily loaded run of the same suite - and that row fails identically on the base
(`180 checks, 6 failed` on `/tmp/base-975d` at `975d4612`), so it is the machine's fonts, not this change.
The one failure is `install-guards` (`bash scripts/test-install-guards.sh`: `72 checks, 6 failed`),
which fails with the same 6 on the base worktree - pre-existing, and untouched by this diff.

An earlier fast run of this branch used the installed binary (`WA_FAST_ALLOW_STALE_BINARY=1`, 282/283
Lua rows) and failed its own `fast-binary` contract check, which judges exactly that override; that
failure belonged to the invocation, not the tree. The installed `wa` moved from `a5d8c616` to
`2e20aa7` mid-mission (another session's deploy); every row here runs this tree's Lua through
`WASM_AGENT_LUA_ROOT`, and the final run uses this tree's own binary.

## What I could not verify

- `scripts/test-discriminates.sh` itself was not run: it queues behind the same suite lock, which was
  held by other sessions for most of the window. The base comparison above is its one-row judgement
  done by hand against a `975d4612` worktree (`/tmp/base-975d`), which is the same pair of trees it
  would build.

## Observed, not fixed (pre-existing)

- `M.stable` still moves every round on this answer shape (the `progress` object and the `timing`
  block are not fully clock-stripped), so `changed` is true every round and the `idle` counter never
  reaches its limit here. It does not affect the repeat counter, and no assertion depends on it, so it
  is left as it is rather than widened in this mission.

## Texts to approve

1. No new model- or operator-facing string. The guard's reason text is unchanged, and the new
   functions are internal to the guard module.
