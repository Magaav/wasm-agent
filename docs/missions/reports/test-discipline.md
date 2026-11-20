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

Placed in the mission report when the fast path finishes; see "Fast path" below.

## Texts to approve (1)

1. Rule 16, added to `~/Work/missions/launch.sh`, appended to rule 15:

> (16) every new test must fail on the code before your change - the land gate checks it with scripts/test-discriminates.sh, which runs the tests you add or change against the base with only your non-test changes reverted and names any that still pass there (a test that cannot fail cannot catch anything); a branch that only refactors says so with a "Refactor-only: <reason>" line in its report and must instead keep every test green; stubs come only from the shared contract fake, never a hand-written one that accepts what the real host refuses; and a bug that crosses processes needs a test that crosses processes;

2. `scripts/test-discriminates.sh --help` and its one line per test (verdict, path, reason) - the strings
   above: `discriminates`, `does-not`, `unclassified`, `not-applicable`, `environment`, and
   `BLOCKED: N test(s) do not discriminate - named above`.

3. The land check's operator-facing detail: "every test the branch adds or changes fails on the code
   before the change".
