# harness-fixes-1 — six items, measured at base, each with the commit that answers it

Base: `ac7717e0` (origin/main). Branch `change/harness-fixes-1`, five commits, never pushed.
Verified on this node (avell) only. Fast path green in this tree: `fast path ok (51 checks, 0 skipped, 356s)`,
result ledger `/home/victor/wasm-agent/checkout/.git/worktrees/wt48/wa-fast-result.json` (env root
`…/harness-fixes-1/wt`, commit `ad2ee462`), with both new/changed Lua rows recorded `pass`:
`scripts/test-operation-survives-turn.lua` 5721 ms and `scripts/test-no-silent-stops.lua` 2089 ms.

## Items and commits

### Item 6 — `scripts/test-sentinel-service-deploy.cjs` red on main — `35029ffe`

Reproduced first: `EXIT=1`, `actual ['stop']`, `expected ['stop','copy','start']`.

Measured cause (which side changed): `936880f9` introduced the supervisor's one byte source,
`SENTINEL_SOURCE="${SENTINEL_SOURCE:-${NEW_SENTINEL:-}}"` (`scripts/deploy.sh:1652`). The fixture slices only
the swap block and sets `NEW_SENTINEL` alone, so under the wrapper's `set -eu` the copy line died on the
unset variable before `cp` ran. **The deploy script is right; the test was stale.** Not a code bug.

Fix (`35029ffe`): the fixture reads deploy.sh's own resolution line out of the source and runs it ahead of
the block, and asserts that line still exists — so it pins the script instead of drifting from it.
17 checks, exit 0.

### Item 1 — the progress guard stopped a legitimate wait — `de50a838`

Cause (`de50a838`, `lua/core/progress_guard.lua`): `observe()` counted repeats by call fingerprint and
returned `guard_repeated_calls` at `repeat_limit` whatever the round had learned. An await's answer IS a
new observation while the work runs (`elapsed_ms`, state, queue depth move).

Fix (`de50a838`): new `progress_guard.waiting(name, args, answer)` — true only for the `operation` tool,
only for `action` `await`/`wait`, only when the answer is a table with `settled ~= true` and a live state
(`accepted`, `queued`, `running`, `draining`). An answer with no `state` field is **unknown, not yes**, so it
is judged like any other repeat. `observe()` clears the repeat streak and idle count on such a round.
`lua/core/agent.lua` computes `round_waiting` from the call's own answer and passes it in.

A **settled** operation awaited three times is still `guard_repeated_calls` — unchanged.

Tests (`de50a838`): `scripts/test-no-silent-stops.lua` gains 19 checks (10 awaits of a running operation not
stopped; a settled one stops at three; `status` not exempt; a non-operation tool not exempt; an answer
without `state` not exempt). 103 checks pass. Row is in the fast path by default (not in
`scripts/fast-path.exclude`).

### Item 5 — the timeout notice must be impossible to miss — `e3844211`

Cause (`e3844211`, `rust/wa-capabilities/src/operations.rs`): `start` read only the keys it knew and
ignored everything else. A caller passing `timeout_ms` got no complaint, `requested_seconds` stayed `None`,
the kind default applied, and a long job died on a 300 s deadline nobody chose — the `timeout_notice` was
present and unread because the caller had no reason to doubt its own field.

Fix (`e3844211`): `start_fields_refused(args)` — an **allow-list** of the fields `start` reads (never a
block-list). Any other key refuses the launch before anything is admitted; several unknown fields are all
named, sorted. Called first in `control("start")`. `docs/OPERATIONS.md` states it beside the
`timeout_notice` rule it protects.

Tests (`e3844211`): `operations::start_field_tests` (3) — the measured `timeout_ms` case refused by name,
every field real callers send accepted (command, program, args, cwd, timeout_seconds, background,
`_launch_cwd`, owner, session, node_scope, tool, scope, wait_for, output, max_bytes), and every unknown
field named in a stable order. `cargo test -p wa-capabilities`: **343 passed, 0 failed**.

### Item 4 — `wa land` `worktree_failed` with EMPTY detail — `ab9eab4c`

Two causes, both in `lua/core/land.lua` (`ab9eab4c`):
1. `M.exec` read only `code`/`stdout`/`stderr` from the host's JSON. When `host.exec` refuses a launch it
   answers `{error: …}` with **no streams at all**, so a refusal became a failure with no message.
2. The detail was `first_line(stderr or stdout)`: a failure with neither stream reported `""`, and git's
   progress line (`Preparing worktree (new branch …)`) pre-empted its verdict line on stdout.

Fix (`ab9eab4c`): a stream-less `{error}` becomes `host_error: <text>`; the raw answer is kept when the host
did not answer the expected JSON; the detail is one durable sentence — `last_line(git's words)` +
`exit <code>` + `command: git worktree add …`, plus the raw host answer when there was one. `last_line`
replaces `first_line` for that field because git writes progress first and the reason last — **my own case
12b caught this while being written**, and it is why the helper exists.

Tests (`ab9eab4c`): `scripts/test-land.lua` case 12b (13 checks) drives five shapes through `land.run` —
git's stderr with exit 128, a host refusal with no streams, an unreadable host answer, git's stdout with
empty stderr, and a failure with **neither** stream — each asserting a non-empty `observed` naming the
verdict, the code and the command. The row passes in the fast path (`25866 ms`).

### Items 2 and 3 — already released at base — `ad2ee462`

**Both premises were stale; re-measured at base in a separate worktree (`/tmp/base-hf1` at `ac7717e0`), never
`git stash`:**

* Item 2 (a failed turn keeps the session lease → `resource_busy` on resume): **already fixed at base**.
  `lua/core/agent.lua:1820` releases the run claim on every exit path (the 18/11 item-5 fix). An operation
  the turn started keeps running and does **not** hold the lease: the lease is the run's admission
  (`session:<id>` released by `finish`), not the operation's.
* Item 3 (result lost when the starting session detaches): the **loss** does not happen while the node
  process lives — the registry is process-global, so after a resume the same session lists the operation,
  awaits it by id and reads its stdout. `operation_owner_not_attached` is reserved for the genuinely
  unknowable case (a fresh `Manager` reading `state.json` for work whose owner process is gone) and
  correctly says unknown rather than inventing a result. `rust/wa-operation/src/tests.rs:613`
  (`cursor_read_and_restart_do_not_reexecute`) pins that shape: a fresh `Manager` reading a
  `{"state":"running","settled":false}` row answers `outcome_unknown`. Note the error STRING itself
  (`operation_owner_not_attached`, `rust/wa-operation/src/lib.rs:934`) has **no direct assertion** at base —
  only the `outcome_unknown` state is pinned. I did not add one; that is a real gap, named rather than hidden.
  This change does not touch that path.

What `ad2ee462` adds is the missing end-to-end proof: `scripts/test-operation-survives-turn.lua`, 16 checks
through the real host and the real operation manager (never a fake) — run 1 claims the lease and starts a
supervised operation that outlives it; the turn ends while it still runs; the next run of the same session
is admitted (no `resource_busy`); the operation records the **session**; the resumed run lists it, awaits
it by id and reads its own stdout marker; another session is still refused `operation_not_yours`; and the
measured shape itself — a turn that **fails on a stalled provider** after starting a long operation leaves
the session free.

Honest limit: **this test passes at base too**, so it is a regression guard, not a fix. It fails if either
the release or the ownership regresses. Reported as measured, not as work done.

## Brief premises that were wrong

| Brief said | Measured |
| --- | --- |
| item 6 is a code bug in the deploy swap | the code is right; the **test fixture** was stale after `936880f9` |
| items 2 and 3 are open defects | both already fixed at base; only the end-to-end proof was missing |
| `test-no-silent-stops.lua` is a gated row | it is a fast-path row by default; **not** referenced in `scripts/test.sh` |

## Pre-existing failures (not mine)

* `scripts/test-land.lua` case 9 (`the journal names the node that signed`) fails **identically at
  `ac7717e0`** in a base worktree: it needs a scratch vault admin listener this machine does not have. My
  case 12b was therefore inserted **before** case 9 so it actually executes; the suite still stops at case 9
  for that environmental reason, exactly as at base.

## Texts to approve (new or changed operator/model-facing strings, verbatim)

1. `operation_unknown_field: <fields> - start reads none of these, so nothing was launched. The deadline is timeout_seconds (1-86400); an unknown field is refused rather than silently given the default.` (`e3844211`)
2. `guard_repeated_calls: the same call was made N rounds in a row with no new observation (<label>); the turn stopped where a continuation can pick it up` — **unchanged wording**, now no longer fires on a live wait (`de50a838`)
3. `(git answered with no output)` — the worktree failure detail when git wrote nothing (`ab9eab4c`)
4. `; exit <code>; command: git worktree add -b <branch> <tree> <base>` — appended facts in that same detail (`ab9eab4c`)
5. `raw host answer: <answer>` — appended when the host did not answer the expected JSON (`ab9eab4c`)
6. `host_error: <text>` — a stream-less host refusal, formerly an empty stderr (`ab9eab4c`)
7. `An unknown field on start is refused BY NAME (operation_unknown_field: <fields>) instead of being ignored: …` — new docs/OPERATIONS.md paragraph (`e3844211`)

## What I did not do / did not verify

* Did not push (per instructions) and did not run the full nightly gate `scripts/test.sh` — the focused rows
  plus the fast path are what I ran; `scripts/test.sh` is ~50 min and is not the landing requirement here.
* `wa land` against a live fleet was **not** run (node rule 13); item 4 is proved by the fixture cases.
* Items 2/3 are not code changes: I could not make a defect appear that the base does not have.