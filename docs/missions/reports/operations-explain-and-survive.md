# operations-explain-and-survive (23/11)

Branch `change/operations-explain-and-survive`, base `c1337903`, worktree
`/home/victor/Work/missions/operations-explain-and-survive/wt`. Everything here was built and measured on this
node (avell). No release, no fleet call, no peer beyond scratch; `~/.wasm-agent/graph.db.malformed-20261122T144358Z`
untouched.

Commits, one per finished piece, in this order (the last two are this report itself):

| commit | item | what it does |
| --- | --- | --- |
| `ae894ef2` | 1 | an operation waiting on a file lock names the lock, the holder and how long it has been held (`rust/wa-operation/src/blocked.rs` + state) |
| `e03bad40` | 1 | the code-mode pending answer carries those facts to the model (`lua/core/codemode_pending.lua` + row) |
| `886a5c5d` | 1 | a suite runner waiting for the lock writes the holder into its own log (`scripts/lib/lock-wait.sh`, preflight, main-health, row) |
| `6ca3670a` | 2 | a handle whose owner is gone names its output, its exit code and its last state, and cancels at once |
| `3104ab34` | 4 | a promotion says so in the same result, with the seconds and the id to await |

## Re-measurement first (rule 9): which premises held

Measured before any code was written.

* **(a) bare `pending` behind the suite lock — CONFIRMED.** The ledger has it in the workers' own words
  (`search_messages "suite.lock pending operation"`: *"my suite attempts burned ~45 minutes without a single row"*,
  *"an await on a queued suite should report the lock holder (pid, command, elapsed) instead of a bare pending"*),
  and the live node confirmed the mechanism: a process parked in `flock(2)` sleeps in `locks_lock_inode_wait`
  (`/proc/<pid>/wchan`, readable without root), `/proc/locks` lists the wait as a row for that pid marked `->`
  under the lock id of the row that owns it, and the waiter's own open descriptor names the file. Measured
  rows on this node, verbatim:
  `21: FLOCK ADVISORY WRITE 2519447 00:38:7671677 0 EOF` and `21: -> FLOCK ADVISORY WRITE 2519662 00:38:7671677 0 EOF`.
* **(b) a detached owner loses the answer — CONFIRMED, twice.** Ledger rows show `operation_owner_not_attached`
  with `output_bytes: 0`. And this session hit it for real: the narrowed fast path it had started was killed by
  the 23/11 node swap, and the handle then answered
  `{"state":"outcome_unknown","error":"operation_owner_not_attached; ...","output_bytes":0}` — on the BASE
  binary, with no path to the output the disk holds.
* **(c) wakes re-offer a dead handle — STALE, no code changed.** The dedupe already exists and is pinned:
  `lua/core/codemode_pending.lua:1394` sets `record.woke_at` only after the wake exists, and
  `lua/core/selfloop.lua:477-484` inserts the wake under the id `handle:<op>` with `INSERT OR IGNORE`. The row
  `scripts/test-handle-wake.lua:80-92` already asserts "Exactly once: the same sweep again, a fresh module (a
  restart), and the next script's announcement"; it runs green here (`handle wake: 17 checks`). A test added now
  could not fail on base, so none was added (rule 16).
* **(d) silent promotion / shapes / empty read — MOSTLY STALE.** Measured live: a `bash` that leaves a live
  descendant is REFUSED by name (`background_descendants: use an explicit operation and keep its shell waiting`),
  not silently promoted; a promotion through the foreground path already carried `promoted: true` and the full
  output, but no sentence saying the work had moved (fixed in `3104ab34`); `read` of a running operation returns
  the bytes already written (measured: `available_bytes: 12`, `content: "early-bytes\n"` while the operation was
  still running), so note 61 could not be reproduced on this base. `start` answers
  `{cwd, cwd_requested, cwd_source, effective_cwd, note, operation_id, settled, state, status, timeout_ms,
  timeout_source}` and `status`/`await` answer the full state record; both carry `operation_id`, so "the id is not
  where the script looks" did not reproduce either. What is still open is named under "Not done" below.

## Item 1 — a blocked operation says on what

`rust/wa-operation/src/blocked.rs` (new, `ae894ef2`) reads the wait from the kernel and the operation's state now
carries `blocked_on` (kind, `lock_path`, `lock_mode`, `waiting_pid`, `waiting_command`, `holder_pid`,
`holder_command`, `holder_started_ms`, `queue_position`) and `blocked_note`. It is computed at `snapshot` time for
an unsettled operation and cached for one second (`BLOCKED_SCAN`), so a 25 ms wait loop does not scan `/proc`
forty times a second; work that is merely computing carries neither field.

Two honesty points, both measured:

* how long the lock has been HELD is not published by the kernel. The only related fact is when the holder process
  started, which is an upper bound; it is reported as `holder_started_ms` and the sentence says "that process
  started N ago, so the lock has been held at most that long".
* the device is deliberately NOT used to match the lock file: a file under `~/.wasm-agent` reports `st_dev` 0x36
  while `/proc/locks` prints the same file's device as `00:1e` (btrfs subvolume), so a device comparison refused
  to name a lock it had already found. The inode is the key (it is the same number in both places), and the
  candidates are only that process's own open files.

The model-facing half (`e03bad40`) puts `blocked` + `blocked_note` into the bounded `progress` a code-mode pending
answer carries, and deliberately keeps them OUT of `M.PROGRESS_FIELDS`: the sentence carries a duration that
changes every second, so fingerprinting it would read a parked wait as progress and the whole-budget bound
(`M.PENDING_ANSWER_LIMIT`) would never count it.

The runner half (`886a5c5d`): `scripts/lib/lock-wait.sh` prints the same sentence from `/proc` in a shell runner,
and `scripts/preflight.sh` and `scripts/main-health.sh` write it into their own log before they block (they ask
with `flock -n` first, so the line appears only when there is a queue). Answer codes: 0 = held and named,
1 = nobody holds it (nothing printed), 2 = cannot tell on this host — a runner that cannot name the holder is not
a runner that may claim there is none.

Tests (all fail on `c1337903`, where `blocked.rs` does not exist — `git show c1337903:rust/wa-operation/src/blocked.rs`
exits 128 — and where `scripts/lib/lock-wait.sh` does not exist — same check, exit 128):

* `rust/wa-operation/src/tests.rs::a_wait_on_a_file_lock_names_the_lock_the_holder_and_how_long_it_is_held` — a REAL
  `flock(2)` holder and a real waiter inside a real operation; asserts the path, holder pid and command, the
  duration, the sentence, and the control (a computing command carries no cause).
* `rust/wa-operation/src/tests.rs::a_lock_row_names_the_owner_and_the_queue_position` — the `/proc/locks` parse on a
  fixture body, including an unnamed holder that must stay `null`.
* `scripts/test-operation-blocked-on.lua` (new row) — the pending-answer shape and the fingerprint rule. Measured
  on a base worktree (`/tmp/base-ops`, `git worktree add /tmp/base-ops c1337903`):
  `lua error: ...:21: the pending answer names WHAT it waits on: nil`, exit 1; on this branch `operation blocked-on ok
  (13 checks)`.
* `scripts/test-lock-wait.sh` (new row) — a real holder, a real lock file, the free case, the missing-file case.
  Green: `lock wait ok`.

Wiring (rule 3): the Rust tests run in the existing `cargo test -p wa-operation` gate row (`scripts/test.sh:269`);
the two new Lua/shell rows are discovered by the fast path (`scripts/fast.sh:10` runs every `scripts/test-*.lua`
not in `scripts/fast-path.exclude`) and `scripts/test-lock-wait.sh` is added by name as `check lock-wait bash
scripts/test-lock-wait.sh` (`886a5c5d`, next to `check fast-rows`).

## Item 2 — a handle survives its owner

The reattach half already existed (live owner -> `reattached`; settled record -> its own result). What was missing
is the dead-owner half: the answer said `outcome_unknown` and nothing else, so the output on disk was reachable
only by hand. `6ca3670a` keeps everything the record had (`last_recorded_state`, `process_exit_code` if the record
carried one, timing) and adds what the disk holds: `stdout_path`, `stderr_path`, `stdout_bytes`, `stderr_bytes`,
`output_bytes`, `output_readable: true` and an `owner_gone_note` that says where to read it and that nothing was
replayed. The unknown half is unchanged — `state: outcome_unknown`, `ok: false`, `cleanup: unknown` — so no
success is invented; the existing test `an_owner_that_exits_mid_work_leaves_a_named_unknown` still passes
untouched (no assertion loosened).

Test: `rust/wa-operation/src/tests.rs::a_handle_whose_owner_is_gone_names_its_output_and_cancels_at_once` — a
dead-owner record with real output files; asserts the unknown half, the kept exit code and last state, the paths
and the real byte counts, that `read` by id returns those bytes, and that `cancel` of that handle answers in
under two seconds with the same facts. It fails on base (those fields do not exist: `git show
c1337903:rust/wa-operation/src/lib.rs` and the `else` branch of the dead-owner case carries only `state`,
`settled`, `ok`, `error`, `cleanup`).

Not done: the same enrichment for the `outcome_unknown` a RESTARTED node writes is only as good as the record the
old owner left; if it died before writing `state.json` there is nothing to read and the answer stays the bare
unknown. That case is named, not fixed.

## Item 3 — a wake names each handle once

No code changed: re-measured as already satisfied (see above). Cited rather than claimed: the marking is
`lua/core/codemode_pending.lua:1394`, the once-only insert is `lua/core/selfloop.lua:477-484`, and the row that
holds it is `scripts/test-handle-wake.lua:80-92`, green here.

## Item 4 — a promotion says so; one shape; read returns bytes

`3104ab34` adds to the promoted result `moved_to_background: true`, `moved_to_background_after_ms` (measured from
the operation's own clock) and `moved_to_background_note`. Every existing field and the old `note` are kept
(parity, rule 14). Test:
`rust/wa-capabilities/src/operations.rs::promotion_says_so::a_promoted_shell_says_in_the_same_result_that_it_moved_to_the_background`
— drives the REAL foreground path with a shell that exits leaving a live descendant, asserts `promoted: true` (so
the fixture really promotes), the sentence, the id inside it, the measured milliseconds, the output so far, and
cancels the adopted tree so nothing of the test is left running. It fails on base (`moved_to_background_note` does
not exist).

How it was run, stated exactly: in this mission's target dir, which has no code-mode assets,
`WA_CODEMODE_ALLOW_EMPTY=1 cargo test -p wa-capabilities -- promotion_says_so` — so nothing about code mode was
exercised by that run; the gate and main-health build real assets. The two rows beside it that my `command_result`
change touches, `adoption_survives_the_relay_deadline` and `await_returns_at_its_own_wait`, both pass under the same
condition.

Still open in this item, named:

* "One documented shape for start/status/await" is NOT unified. `start` answers a receipt
  (`state: accepted`, no `elapsed_ms`/`timing`), `status`/`await` answer the state record. Both carry
  `operation_id` and both are documented, but they are two shapes and the diff does not change that; doing it would
  reshape a model-facing result and is a separate, reviewed change.
* the `background_descendants` refusal replaces a call's result: measured while writing this report, an operation
  that left a descendant answered `error: background_descendants ...` as a hard tool error while its stdout (1669
  bytes) was on disk. That is item 4's "the result is a bare id" in another form and is not fixed here.

## Verification run

* `cargo test -p wa-operation`: **59 passed, 0 failed, 3 ignored** (the whole package, `--test-threads=4`).
* `cargo test -p wa-capabilities -- promotion_says_so`, `-- adoption_survives_the_relay_deadline
  await_returns_at_its_own_wait`: pass (see the asset note above).
* `bash scripts/test-preflight.sh` → `preflight ok (38 checks)`, `bash scripts/test-main-health.sh` →
  `test-main-health ok (30 checks)`, `bash -n` clean on the three runners touched.
* `bash scripts/test-lock-wait.sh` → `lock wait ok`; `scripts/test-operation-blocked-on.lua` → `operation
  blocked-on ok (13 checks)`; `scripts/test-handle-wake.lua` → `handle wake: 17 checks`.
* Narrowed fast path (`flock -o ~/Work/missions/.suite.lock env WA_BIN=~/.local/bin/wa WA_FAST_ROWS=/tmp/ops-rows.txt
  bash scripts/fast.sh`), rows: `test-operation-blocked-on.lua`, `test-codemode-wait-shape.lua`,
  `test-codemode-pending.lua`, `test-codemode-wait-bound.lua`, `test-handle-wake.lua`. Log: `/tmp/ops-fast2.log`.
  The first attempt was killed by the node swap before it reached the front of the queue (its handle then answered
  `operation_owner_not_attached`, which is premise (b) reproduced for real); the second ran on the new boot:
  **123 checks, 3 failed, 877 s**, narrowed to 32 of 345 Lua rows (`fast: lua 32/32 passed`), including
  `check lock-wait`, which is the row this branch adds. Evidence directory:
  `/home/victor/wasm-agent/checkout/.git/worktrees/wt35/wa-fast-evidence/20261123T144233Z-3426431/`.

### The 3 failures are pre-existing (rule: prove it on the base, never on a hunch)

Both offending rows are untouched by this branch, and both reproduce on a base worktree of `c1337903`
(`git worktree add /tmp/base-ops c1337903`):

* `check-install-guards`: 6 of 72 checks fail with
  `upgrade: refused inside a turn running on the node it would replace; request the external sentinel instead`.
  On the base worktree the same row gives `base-install-guards=1`, 6 FAIL — an environment effect of the 23/11
  node install, not of this diff.
* `check-esc-stops-pty`: `FAIL - bash: Esc brings the prompt back at once (300 ms idle, 120 ms per unit of load,
  never over 2000)`. On the base worktree: `esc-stops: FAILED - timed out waiting for the prompt`, `-1 ok, 1 failed`.
  Same failure without this branch, and a load-sensitive timing row besides.

## What was NOT done (named, not hidden)

* item 3 needed no code (premise stale, pinned by an existing row).
* one documented shape for `start`/`status`/`await` is not unified (see item 4).
* the `background_descendants` refusal still replaces a call's result, so that output is reachable only by id.
* the dead-owner enrichment reads the record the old owner left; an owner that died before writing `state.json`
  still answers a bare unknown (nothing to read, and nothing is invented).

## Texts to approve (Fable; every model- or operator-facing string added or changed)

1. `blocked_note`, Rust (`blocked.rs::lock_wait_note`) and the shell runner line, same wording:
   `waiting on a file lock: {file} ({FLOCK WRITE}) is held by pid {pid} ({command}); that process started {dur} ago, so the lock has been held at most that long`
   with `{dur}` as `8m 12s` / `1h 4m` / `900ms`, plus ` (this waiter is {n} in the queue)` when it is not first.
2. The unnamed-holder variant: `waiting on a file lock: {file} ({mode}) is held by a process this node cannot name`
   — in Rust: `... is held by a process this node cannot name`; in the shell runner the parenthetical is
   `(no owning row for it in /proc/locks)`.
3. `owner_gone_note`, Rust: `the process that started this operation is gone and the operation never reported an
   outcome: its state above is the last one that process recorded. The output it wrote is on disk at
   stdout_path/stderr_path and is readable by id (operation read); the exit code is only known if the record
   carries one. Nothing was replayed and no success is claimed.`
4. `moved_to_background_note`, Rust: `moved to the background after {N.N}s: operation {id}, await it. The shell
   itself exited with code {code} and its descendants are still supervised under the original timeout;
   stdout/stderr below are what they had written when this answer was taken, and more may follow.`
5. The pending-answer field `blocked` in `lua/core/codemode_pending.lua`: `{kind, lock, holder_pid}` plus
   `blocked_note` — the same sentence as (1), carried only while the operation is parked.

Cache cost, said plainly: a pending answer grows by ~40 tokens only while an operation is parked on a lock (it is
absent otherwise); an operation's state grows by ~15 tokens (`blocked_on`) plus the sentence (~40 tokens) for the
same time; the promotion sentence adds ~60 tokens once, to the one result that promoted. No tool DESCRIPTION
changed, so the tool-definition cache is untouched; only tool RESULTS grew, and only in the cases this mission
exists to explain.

## Proposed FACTORY.md / HANDOVER.md text (proposed, never written)

> **An operation that waits says what on.** A wait is not a state, it is a fact: when an operation's process tree
> is parked on a file lock, the state carries `blocked_on` and a sentence naming the file, the holder's pid and
> command and how long it has been held (bounded by the holder's own age — the kernel does not publish the lock
> instant, so the sentence says "at most that long"). A suite runner that queues writes the same line into its own
> log (`scripts/lib/lock-wait.sh`). A cause this node cannot read is `holder_pid: null` with a sentence that says
> so, never a guess.

> **A handle outlives its owner.** A handle whose owner process is gone answers `outcome_unknown` AND everything
> the record and the disk still hold: `last_recorded_state`, its exit code if recorded, `stdout_path`,
> `stderr_path` and their real byte counts, and `owner_gone_note`. Reading it by id returns those bytes. Nothing is
> replayed and no success is claimed; `cancel` of a dead handle answers at once.

> **A promotion is announced.** A foreground call whose shell exits leaving live descendants answers
> `moved_to_background: true`, the measured milliseconds and the sentence `moved to the background after N s:
> operation <id>, await it`, with the output so far — never a silently different kind of result.


---

# Addendum (23/11, P1 defect found by Fable): the answer was raised, not returned

Reported: on a build containing this mission's work, `tools.operation({action:"status", id})` RAISED after an
install detached the owner — five times in one worker's log
(`missions/tool-args-honest-and-same-on-peers/out.log` ~45686-45693) — and that worker re-ran its rows four times
because "what did that run print before it died" had no answer. Reproduced here first, on this node, against the
handle my own narrowed fast run left behind when the node was swapped:
`status` -> raised, `await` -> raised, `read` -> answered.

## What actually raised (measured, not guessed)

`lua/core/codemode.lua`, `settle_call`: the code-mode delivery marks a call failed when its ANSWER carries
`error` or `ok:false` (`value=result; success=... (not value.error and value.ok~=false)`), and the sandbox
rejects a delivered payload that carries those keys. A dead handle's record is exactly that shape, so the record
was raised at the script instead of being handed over. Two measurements pinned it:

* `tools.operation({action:"read", id, stream})` on a dead handle answered (its payload carries no `error`/`ok`),
  while `read` on a MISSING operation raised (`No such file or directory (os error 2)`) — so the key, not the
action, was the trigger;
* `tools.bash({command:"exit 3"})` answers `ok:true, code:3` — a failed command is a value, which is why this was
never seen on `bash`.

## The fix (`2526ac03`)

`settle_call` now treats the five READ-ONLY operation actions (`status`, `read`, `await`, `wait`, `list`) as what
they are: a call that successfully READ a record. An allow-list, not a "not an effect" guess — `start` and
`cancel` keep the strict rule, so a refused start still raises inside a script (pinned by the new row).

For those actions the record travels with the OPERATION's own failure under `operation_error` and the same
sentence under `reason`, and with `operation_ok=false` instead of `ok=false`; no `error` key, which is the key the
sandbox rejects. Nothing about the operation is softened: `state: "outcome_unknown"`, the last recorded state, the
exit code, `stdout_path`/`stderr_path` and their byte counts all still travel, and `read` still returns the bytes.

## Test that fails on main

`scripts/test-operation-answer-not-a-raise.lua` (new row, discovered by the fast path like every `scripts/test-*.lua`).
It writes a REAL dead-owner record into its own scratch home and runs the REAL code-mode sandbox:

* measured on a base worktree of `c1337903` (`git worktree add /tmp/base-ops2 c1337903`, same installed binary,
  `WASM_AGENT_LUA_ROOT=/tmp/base-ops2`): exit 1,
  `a status/read/await on a dead handle ANSWERS, it does not raise (the measured defect): Error: {"cleanup":"unknown",... "error":"operation_owner_not_attached; ..."}`;
* on this branch: `operation answer not a raise ok (9 checks)`, exit 0.

It pins four things: status answers `outcome_unknown`; `read` hands over the bytes the record already wrote;
`await` answers the same record; `operation_ok == false` and `reason` carry the fact `ok`/`error` used to; and a
REFUSED `start` still raises, so the strict half did not move.

## The refusal that must stay a refusal (`c3e9a89d`)

A record is not the only thing these actions answer. `operation <id> is not your operation` is a refusal of the
READ, and it carries `not_your_operation: true`, `effect: "none"` and no `state`
(`rust/wa-capabilities/src/operations.rs`, `Caller::refusal`). The rename therefore only applies when the answer IS
a record (`state` present, not a not-yours refusal); an ownership refusal still raises, so no session can read
another session's output by catching an answer instead of an error. Pinned by the neighbouring row
`scripts/test-operation-survives-turn.lua`, which asserts `awaited.error ~= "operation_not_yours"` for its own
handle: green, `16 checks, 0 failed`.

## Item 1 verified on the installed node, in passing

While this addendum was being written, the narrowed run below sat behind the suite lock for ten minutes, and a
`tools.operation({action:"status"})` on it answered (verbatim, from the installed build):

    waiting on a file lock: /home/victor/Work/missions/.suite.lock (FLOCK WRITE) is held by pid 2749211
    (flock -o /home/victor/Work/missions/.suite.lock nice -n 19 bash -c cd
    '/home/victor/.wasm-agent/main-health/wt-51b63d9af8f5-2749017' && bash scripts/fast.sh); that process started
    12m 46s ago, so the lock has been held at most that long

with `queue_position: 1` and `waiting_pid` naming this mission's own waiter — which is exactly what ledger notes
0, 1, 3, 189, 244, 264 and 269 asked for, measured on the real node rather than in a fixture.

## One thing this fix does NOT claim

The fix is in the code-mode delivery (`settle_call`), which is the path the reported log shows
(`tools.operation({action:"status", id})` inside a run block). After this session's third install, a wake arrived
replaying a handle that had been recorded with `tier: "message"`, `input: "outcome_unknown"` and the message
`{tool} raised instead of answering: operation_owner_not_attached ...` — the SAME failure, recorded on the model
path rather than in a script. I did not chase that second surface to a line: the pending layer stored that
handle's outcome before this fix existed, so it may be a replay of the old failure rather than a live raise, and
this report will not call it either way without a measurement. Named here so the next reader measures it instead
of assuming coverage.

## Texts, spelled (Fable, then this commit)

* `owner_gone_note` now says the read is `tools.operation({action:"read", id})` (was the prose "(operation read)").
* `moved_to_background_note` now says `operation {id}, wait("{id}")` (was "operation {id}, await it").

The assertions that quote them moved with them and were strengthened, not loosened: the wa-operation test now
asserts the literal call text `tools.operation({action:"read", id})`, and the wa-capabilities test asserts
`operation {id}, wait("{id}")` — the spelled call, not the prose.

## Narrowed run for the addendum (the rows this fix touches)

`flock -o ~/Work/missions/.suite.lock env WA_BIN=~/.local/bin/wa WA_FAST_ROWS=/tmp/ops-rows3.txt bash
scripts/fast.sh` (8 rows: the new one, `test-operation-blocked-on`, `test-operation-survives-turn`, four
`test-codemode-*`, `test-handle-wake`), log `/tmp/ops-fast5.out`, evidence
`/home/victor/wasm-agent/checkout/.git/worktrees/wt35/wa-fast-evidence/20261123T180952Z-3712179/`:

* `fast: lua 35/35 passed` (35 of 346 rows selected; the never-dropped core rows included) — every row this
  change can move is green, including the new one and `test-operation-survives-turn`;
* 33 contract checks `ok`, among them `discrimination`, `fast-binary`, `landing-queue`, `deploy-pin-prune`;
* TWO failures, both proven pre-existing on a base worktree of `c1337903`:
  * `check-esc-stops-pty` — the load-sensitive timing row already named in the main report
    (`esc-stops: FAILED - timed out waiting for the prompt` on base);
  * `rust wa-capabilities` — `host::tls_anchor_tests::a_provider_call_refuses_a_private_ca_that_no_bundle_names`
    panics at `wa-capabilities/src/host.rs:8025` (`expect_err` on a request that should refuse a private CA and
    did not). Run from a base worktree into this mission's warm target dir:
    `test result: FAILED. 0 passed; 1 failed; ... finished in 20.28s` — the same failure without a line of this
    branch, and this diff touches no TLS file (`git diff c1337903 --stat` = `operations.rs`, `wa-operation`,
    `lua/core/codemode.lua`, `scripts/`). It is a trust-store fact of the reinstalled node.
* The run never printed its own summary line: the third node install of the night killed it during cleanup, so
the verdict above is read from its per-check lines and its evidence directory rather than from its result file.
A first attempt at this run was killed the same way before it reached the front of the queue; a second one
(exactly this one, then re-started) had to be re-run after the edits that followed it. That is the environment,
not the diff: three installs landed inside this session.

## Verification of the addendum

* `cargo test -p wa-operation`: **59 passed, 0 failed, 3 ignored**.
* `cargo test -p wa-capabilities -- promotion_says_so`: pass (run with `WA_CODEMODE_ALLOW_EMPTY=1`, as before).
* `scripts/test-operation-answer-not-a-raise.lua`: 9 checks on the branch, fails on base (above).
* Note for the next reader: the node reinstall reset `rustup`'s default toolchain for shells whose HOME is a
  scratch directory; every cargo call above ran with `RUSTUP_HOME=/home/victor/.rustup CARGO_HOME=/home/victor/.cargo`
  explicitly. That is an environment fact of the swap, not of this diff.

## Texts to approve (added by this addendum)

6. The delivery fields in `lua/core/codemode.lua` for a read-only operation answer: `operation_ok` (in place of
   `ok` when the operation did not succeed), `operation_error` (in place of `error`) and `reason` (the same
   sentence). A script that reads `r.operation_ok === false` and `r.reason` gets the fact; a script that expected a
   raise for a dead handle no longer gets one — that is the defect being fixed.
7. `owner_gone_note`, final text: `the process that started this operation is gone and the operation never
   reported an outcome: its state above is the last one that process recorded. The output it wrote is on disk at
   stdout_path/stderr_path and is readable by id: tools.operation({action:"read", id}). The exit code is only known
   if the record carries one. Nothing was replayed and no success is claimed.`
8. `moved_to_background_note`, final text: `moved to the background after {N.N}s: operation {id}, wait("{id}").
   The shell itself exited with code {code} and its descendants are still supervised under the original timeout;
   stdout/stderr below are what they had written when this answer was taken, and more may follow.`

Cache cost of the addendum: nothing added to tool descriptions. A read-only operation answer inside a run block
changes two key NAMES (`ok`->`operation_ok`, `error`->`operation_error` plus `reason`) — same bytes in, same bytes
out, no growth. The two sentences are the same length as before (the spelled call replaces prose of the same size).
