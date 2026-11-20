# test-discipline - tests that can fail, fakes that tell the truth

Branch `change/test-discipline`, base `origin/main` 39bbf2b6. Every claim below cites the commit that
implements it (`git log -S` / `git show`).

## What the brief got wrong (re-measured, rule 9)

| Brief said | Measured 20/11 |
|---|---|
| "test-nodes-probe-instances.lua" is a lying stub to migrate | **no such file** in the tree; `rg --files -g '*nodes-probe*'` finds only mission docs |
| "the harness-fixes-1 guard tests" are lying stubs here | no `harness-fixes*` test file exists; the lying-stub set is the five `host = {` stubs in `scripts/test-{keybindings,backup-live,tool-schema-fidelity,remote-update,update-watcher}.lua` |
| item 1: run tests "on a scratch worktree of the merge base" | superseded by the 20/11 revision (1'); implemented as 1' |
| item 6: cargo-mutants "verify it exists and runs offline" | **absent**, and not installable offline: `cargo search --offline` refuses the HTTP request and no `*mutant*` crate is in the vendored registry |
| item 2: "operations" in the shared fake | the test-side seam is the Lua `host` table (142 capabilities). A fake of the `operations` API is a different seam; not done here |

## Item 1' - `scripts/test-discriminates.sh` (25c8eb23, 288d4f71, 7bcd461f)

Puts the **base's non-test code under the branch's new and changed tests**: a scratch worktree
(`git worktree add`, never `git stash`) at the merge base, the branch's test files checked out over it,
only non-test changes reverted. One line per test:

```
discriminates   the test ran and an assertion failed
does-not        it passed on the reverted code, or died on a missing symbol/file (proves nothing)
unclassified    it failed and no assertion marker matched: blocks, naming the failure
not-applicable  its platform is not this one, the branch deletes it, or it is a spec for a file the branch adds
environment     the machine could not run it: refused, never a pass
```

Exit: 0 nothing blocks, 1 named blockers, 3 the machine could not run something, 76 unanswerable.

Three rules that only came out of measuring:

* **A load error is not discrimination.** A test that dies on `No such file`/`attempt to call a nil value`
  before reaching an assertion proves nothing; it is `does-not`. 7bcd461f widened the markers after the
  tool's own test was wrongly called discriminating for a *missing subject*.
* **A spec for new code cannot discriminate.** The base has no behaviour to tell apart, so even a perfect
  test dies there. The branch's added files are collected, and a test that NAMES one is `not-applicable`
  with the subject named (7bcd461f) - never silently passed.
* **A file another changed test names is code, not a test** (7bcd461f). `scripts/test-discriminates.sh` is
  both a tool and a test-file name; without this rule the tool judged itself against itself.

**Refactors.** A `Refactor-only: <reason>` line the branch adds under `docs/missions/reports/` exempts it
from discriminating; every test it touches must instead stay GREEN (288d4f71). The two modes agree on the
exit code and disagree on what a raw outcome means, which is what a refactor requires.

### Its own test, and where it runs (7f9c5aff, 2e9defe2)

`scripts/test-discriminates-test.mjs` builds a fixture repository with one good test, one vacuous test, one
that dies on a missing symbol, a refactor-only branch, a spec for an added file and a branch with no test,
and asserts every verdict plus the exit code, the JSON line and that the scratch worktree is removed.
23 checks. Hermetic: scratch home, scratch Git, no binary, no network.

Wired:
* `scripts/fast.sh` contract row `discrimination` (2e9defe2) - so the day-to-day path runs it;
* `scripts/gate-checks.mjs` catalog row (2e9defe2);
* `lua/core/land.lua`: `discrimination` is added to `M.DEFAULT_CHECKS` **and to `M.GATE_ALWAYS`**
  (2e9defe2). It is always-on, not trigger-gated: a plan written before the check existed must still run
  it, so `M.gate_checks` unions `GATE_ALWAYS` into the plan's set. `scripts/test-land.lua` answers it in
  the gate stub and asserts the gate runs it.

**A non-discriminating test blocks the land by name**: the check exits 1 and the gate fails the round.

## Item 2' - the one contract fake (996e7314)

`scripts/lib/contract-host.lua`. Shapes are the **measured** answers of the real binary
(`wa --db <scratch>` + a probe, 20/11):

| capability | real answer |
|---|---|
| `paths()` | 1 value, table: home/config/data/cache/temp - and **temp is NOT under home** |
| `getenv(unset)` | 1 value, nil |
| `sleep(ms)` | **0 values**, really sleeps |
| `list_dir(bad)` | 1 value, JSON text carrying `{"error":...}` |
| `read_file(bad)` | 2 values: nil, `read_file_missing:<path>` |
| `sql_query`/`sql_exec` | JSON **text**, never a Lua table |

The fake refuses: an unknown capability (`nil`, like the host), a path outside its scratch roots (the one
place it is deliberately STRICTER), and an unscripted SQL statement (an error, like the host).

`scripts/test-contract-host.lua` runs **the same suite against the fake and against the real host inside
the node** and fails on any difference in arity, type **or redacted shape**. 40 checks. Two defects it
found in the fake itself while being written:

* the fake derived `temp` from `home`; the host does not, so the shape comparison failed;
* redaction must be longest-path-first, or the parent token eats the child and the comparison reports a
  difference in the redaction instead of in the answer.

It has teeth: mutating the fake's `read_file_missing` reason to drop its path fails the contract (verified,
then restored).

**Not done:** migrating the five existing stubs onto it. They are `host = {` tables inside Lua tests, and
in every case the stub is the point (a vacuum returning `busy` three times is not a contract question).
They are named above so the next round has the list.

## Item 3 - launcher rule 16

Added to `/home/victor/Work/missions/launch.sh` (backup `launch.sh.bak-test-discipline-<ts>`), appended to
rule 15 inside the generated prompt: every new test must fail on the code before the change; the land gate
checks it with `scripts/test-discriminates.sh`; a refactor-only branch says so and stays green; stubs come
only from the shared contract fake; a cross-process bug needs a cross-process test.

Not a repository change - it is operator-owned and lives in the mission directory, per the brief.

## Item 6 - mutation check: NOT AVAILABLE

`cargo-mutants` is not installed, `cargo search cargo-mutants --offline` fails (it wants HTTP) and no
`*mutant*` crate is in `/home/victor/wasm-agent/toolchain/cargo/registry/src`. Per the brief's own
fallback, item 1' carries the load for both Lua and Rust this round.

## Item 5' - the batching clause: NOT SHIPPED, deliberately

The brief scopes it as an experiment measured on the NEXT missions ("keep it only if test-MUST findings per
review drop WITHOUT steps per mission rising more than ~10%"). Shipping it now would make the experiment's
own baseline unmeasurable. Nothing was changed in the batching guidance.

## Item 4 - shared fleet harness

Explicitly LATER (after fabric-transport phase 1). Not started.

## Verification run

`flock ~/Work/missions/.suite.lock bash scripts/fast.sh --jobs 6` on HEAD f286367e, under rule 15 (it
queued behind another mission's suite and a full gate before it ran): **304 checks, 1 failed, 0 skipped.**

* `fast: discrimination ok (512ms)` - the new contract row for item 1' passes;
* `scripts/test-contract-host.lua` is in the fast path inventory
  (`wa_fast_row_candidates | grep contract-host`) and is not in `scripts/fast-path.exclude`, so it ran
  among the 256/257 Lua rows;
* the one failure is **pre-existing and not mine**: `scripts/test-refusal-contract.lua` says
  `lua/core/refusal_codes.lua is stale`. My diff touches no `refusal` path (`git diff --name-only
  origin/main..HEAD | grep -i refusal` is empty), and the same failure reproduces on a detached worktree
  of `origin/main` itself.

`node scripts/test-orphan-tests.mjs` - ok, 276 wired; `node scripts/test-gate-check.mjs` - ALL PASS (the
HTTP stage skips on Linux, as designed); `node scripts/check-instructions.mjs` - PASS, 79 checks.

## Review r1 (FIX) - what changed, one item per commit

r1 found the tool wrong in BOTH directions and, since it is wired into `wa land`, a false positive blocks
every landing. Every MUST is implemented and has a fixture in `scripts/test-discriminates-test.mjs`
(30 checks; e36fd3b8), and the replay the review named now passes.

| r1 item | fix | commit |
|---|---|---|
| 1a missing symbol = non-blocking row | `new-symbol` replaces `does-not` for a missing module/symbol; `does-not` now means only "an ADDED test passed on the old code" | e36fd3b8 |
| 1b assertions before missing-code | `ASSERT_RE` is consulted first, so `FAIL: the new value is missing` discriminates; the missing-code list also dropped the nil INDEX/COMPARE symptoms it was eating | e36fd3b8 |
| 1c a modified test whose verdict did not change | `unchanged-verdict`, non-blocking: a test-only fix passes without a Refactor-only line | e36fd3b8 |
| 1d SKIP | `skipped` row; exit 3 only when NOTHING could be judged | e36fd3b8 |
| 2 false negatives | the substring `new_subject_of` is gone; a pass on the base is never new-code. A test's own path is no longer a subject | e36fd3b8, e1edf5b1 |
| 3 changed tests vanished | the subject skip is GONE: every changed test gets exactly one row (test-a/test-b -> 2 rows) | e36fd3b8 |
| 4 rust/ not reverted | a `rust/` diff makes the Lua rows a named, non-blocking `unrevertable`; the runtime is resolved from the tree's own build only, never a PATH `wa` | e36fd3b8 |
| 5 refactor leaks across a round | `--branches a,b` + a Refactor-only line REFUSES by name (exit 76); `wa land` is the only enforcer and the report says so | e36fd3b8 |

SHOULDs taken:

* the scratch worktree moved under `~/.wasm-agent/tmp` (docs/ONEROOT.md); `INT TERM` now cleans AND exits;
* the contract test compares `list_dir`, `now` and `monotonic_ms` against the real host and no longer
  hard-codes the operator's home (5da0c0df: 52 checks, 11 capabilities);
* the land gate sizes the discrimination check's timeout by the tests the round touches, so a round that
  touches twenty of them does not time out on the twenty-first (f9a0a59a);
* the summary names skipped, timed-out and unrevertable rows separately instead of folding them into one
  `not judged` count (e1edf5b1).

SHOULD not taken, and why:

* **migrating a real stub onto the contract fake.** Rule 16's stub clause is what overstated the work: the
  fake covers the host's general capabilities (paths, files, SQL, clock, sleep), while the five hand stubs
  exist to script a SEQUENCE the real host cannot be asked for (a vacuum returning busy three times, a
  git command answered with fixture text). Migrating one would have meant widening the fake with a
  scenario language, which is a different tool. Rule 16 was reworded to say exactly that (in
  `~/Work/missions/launch.sh`, backup `launch.sh.bak-r1-<ts>`), and the five stubs are named in this
  report for the next round instead.
* **wiring `landing-queue.mjs land` separately.** It is not needed: `land`'s default check command is
  `bash scripts/fast.sh`, and the fast path runs the discrimination row, which the land gate also carries
  as an always-on check (2e9defe2). The report now says `wa land` and the queue's own `land` both reach
  it through the fast path.

### The replay the review named

`test-discriminates.sh --repo <worktree of 05ef1ccb> 05ef1ccb^` -> **exit 0**, 3 rows, `discriminates=3`,
`0 blocking`: `test-batching-guidance.lua`, `test-done-gate.lua` and `test-turnfeed.lua` all fail ON AN
ASSERTION on the old code - their own `error(...)` messages, whose text says `lua error: [string ...]` because that is how the native runtime prefixes a raised error. The two false positives of the first submission (`does-not ... attempt to call a
nil value`) are gone.

### What a conversion looks like when it CANNOT discriminate

A file that is both a tool and a `test-*` name (`scripts/test-discriminates.sh` itself) is judged like any
other changed test: run from another tree it judges that tree and exits 0 with "nothing to discriminate",
which is a `skipped` row, not a pass (the tool now recognises its own message).

## Review r2 (FIX) - the gate integration

| r2 item | fix | commit |
|---|---|---|
| 1 exit 3 blocked landings | every row a named non-judgment now exits **0**: `nothing was judged on this machine; every row above says why, and none of them is a pass`. A rust/-only-Lua round and a delete-only test change no longer block | 84026811 |
| 2 MUST 5 never ran from the gate | `M.gate_command` hands the discrimination check the round's `journal.branches` as `--branches`, so one Refactor-only line in a multi-branch round is refused by name (verified end to end: a vacuous test no longer goes green) | a8b32b7d |
| 3 wrong base | the same call site appends the round's `journal.base`, the main this round actually merged into | a8b32b7d |

SHOULDs taken: bash/node rows get `WA_BIN`/`WA_FAST_BIN` so a test that needs the binary does not skip; the retry uses
the sized budget, not `check.timeout`; the `\u0024{TEST_TIMEOUT}` literal is a plain sentence; the dead `looks_executed_by`/
`subjects.list` code is gone (f177efae).

SHOULD partly taken: the report's claim that `landing-queue.mjs land` reaches the check is **false** and now says so -
`land` runs `scripts/fast.sh`, whose `discrimination` row proves the TOOL (its own fixture), not this branch's
tests. Only `wa land` judges the branch, through the gate's always-on check.

SHOULD, corrected by the orchestrator after review r3: the claim that had stood here ("the 05ef1ccb rows are real
assertions; classification is by the error body") is FALSE. In the replay, test-done-gate.lua and test-turnfeed.lua
fail with `attempt to call a nil value (field 'note_turn'/'gate_stats')` - a missing symbol - but `ASSERT_RE` matches
the `lua error:` wrapper first, so they are classified `discriminates` instead of `new-symbol`. Neither verdict
blocks, so this cannot cause a false positive; making Lua rows reach new-symbol (drop `lua error:` from ASSERT_RE and
match the body) is a follow-up, not done here.

### Replays (all must exit 0)

`05ef1ccb`, `29072fa0`, `90327c06`, `ee55b6ec` - each replayed on a scratch worktree of `commit^`:

```
05ef1ccb EXIT=0
29072fa0 EXIT=0
90327c06 EXIT=0
ee55b6ec EXIT=0
```

`node scripts/test-discriminates-test.mjs` - 34 checks; `lua scripts/test-land.lua` - 435 checks.

## Texts to approve (2)

1. Rule 16 in `~/Work/missions/launch.sh` (reworded in r1; backup `launch.sh.bak-r1-<ts>`):

> (16) every new test must fail on the code before your change - the land gate checks it with scripts/test-discriminates.sh, which runs the tests you add or change against the base with only your non-test changes reverted and names any that still pass there (a test that cannot fail cannot catch anything); a branch that only refactors says so with a "Refactor-only: <reason>" line in its report and must instead keep every test green; a host stub comes from the shared contract fake (scripts/lib/contract-host.lua), which is judged against the real host by scripts/test-contract-host.lua; a stub written by hand only where the fake does not cover the capability, and then it says which capability and why in its own comment - never a stub that accepts what the real host refuses; and a bug that crosses processes needs a test that crosses processes;

2. The tool's verdict vocabulary, one row per changed test - `discriminates`, `does-not`,
   `unchanged-verdict`, `new-symbol`, `unclassified`, `not-applicable`, `skipped`, `timeout`,
   `unrevertable`, `environment`, `green` - plus its summary lines, now:

> N discriminating, M blocking, K not judged by this machine (S skipped, T timed out, U unrevertable, E environment)

> BLOCKED: N test(s) do not discriminate - named above

> refused: a round of N branches carries a Refactor-only line: one declaration cannot speak for several changes - land the refactor alone, or drop the line

3. The land check's operator-facing detail: "every test the branch adds or changes fails on the code
   before the change".
