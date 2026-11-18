# architecture-rules - the review round on daf92db0

Branch `change/architecture-rules`, worktree `/home/victor/Work/missions/architecture-rules/wt`, base `origin/main`
(74d48431), reviewed head `daf92db0`. **Nothing pushed.** Two commits on top of daf92db0:

| commit | what it lands |
| --- | --- |
| `74749aa8` | `scripts/wit-lint.sh`, its baseline and its fixtures: items 1, 2, 3, 4, 5 and the ok-line counts of item 8 |
| `7073a24b` | `scripts/module-report.mjs`, `scripts/fast.sh`, `docs/MODULES.md` and their fixtures: items 6, 7, 8 |

`ARCHITECTURE.md` is untouched (`git diff daf92db0 -- ARCHITECTURE.md` is empty): the approved text is
not this round's to edit, including the sentence "co-change in >70% of the last 50 commits", which the
report now *measures* differently while the rule it states stays as written.

## The eight items, and what each one is proved by

| # | what was wrong | what it does now | the fixture that fails without the fix |
| --- | --- | --- | --- |
| 1 | a func split as `status:` / `func(id: operation-id)` was not a func at all, and a `%status` name matched nothing | a declaration is joined up to its `;` / `,` before it is matched, and the `%` of a keyword-escaped name is stripped | `shapes.wit`: the split `status` and the `%poll` are both in the 6 violations |
| 2 | `start: func() -> job` beside `resource job { poll }` escaped: the two funcs are not siblings in the text | a start-ish func at interface level is a sibling of the funcs inside the resource it hands out | `interface jobs` in `shapes.wit`: "beside start handing out resource:job" |
| 3 | `record r { args: string }` hid its fields and left the block open (later declarations misattributed); `a: string, b: u32,` was skipped | every line is cut on `{`, `}` and the `,`/`;` that end a declaration, at depth 0 of a `<...>`/`(...)`, before anything is parsed | `record one-line` is in the `--list` map; `record:later` is not attributed to it; the comma-separated `schema` fails |
| 4 | a parameter's baseline key was the bare name, so a new `reload(config: string)` in the same interface passed | the key is `func.param` (`run.config`) | a baseline naming `run.config` accepts `run` and still fails `reload.config`; a key naming `config` fails both |
| 5 | "e.g. application/json" and "never JSON" failed a field; `status: func() -> health` beside `self-id: func() -> node-id` failed | MIME types are stripped, a negated clause is skipped, and a `-id` return is a handle only when the poll func takes that id | `media` and `interface node-info` in `shapes.wit` produce no violation; `interface ops` (poll taking the id) still does |
| 6 | fast.sh ran a `--release cargo build` per touched crate, a second compile the tests never consumed | it times `cargo test --no-run` in the tests' own profile - the compile the row below reuses | `scripts/test-fast-build-timing.sh`: the two invocations must name the same manifest and profile, and no `cargo build` row may remain |
| 7 | co-change was divided by all 50 commits (the top pair read 1/50); a merge was flagged on a module that records a win; `since === null` read as "past the cooldown" | the share is of the commits touching EITHER module, a merge needs no win on either and at least two shared commits, and an unknown commit count counts as inside | `crate:a + crate:b (4/4 ... 100%)`, the same pair dropped once `a` records a win, and a decision with no commit in its record is flagged |
| 8 | `date +%s%N` is a GNU extension; the ok line mixed 2 polling + 3 JSON-name entries; a nested crate was counted under its parent and double-counted in size | one portable `fast_now_ms` (with a BSD fallback), both baseline counts printed, and a nested module counted once - as itself | `fast-build-timing` exercises the fallback; `wit-lint-selftest` asserts "5 baselined (3 json-name, 2 poll-without-future)"; the report's own fixture asserts the parent's size excludes the nested crate's lines |

## What was run, and what it printed

```
$ bash scripts/wit-lint.sh
wit-lint ok (25 wit files, 463 string field(s)/parameter(s), 18 named *-json, 6 polling func(s): 5 baselined (3 json-name, 2 poll-without-future), 0 new)

$ bash scripts/test-wit-lint.sh
wit-lint-selftest ok (45 checks, 0 skipped)          # was 27 before this round

$ bash scripts/test-module-report.sh
module-report-selftest ok (36 checks, 0 skipped)     # was 27 before this round

$ bash scripts/test-fast-build-timing.sh
fast-build-timing: cargo is not on PATH, so the compile these rows describe was NOT run here
fast-build-timing ok (13 checks, 1 skipped)

$ node scripts/test-orphan-tests.mjs
orphan-tests ok (195 wired, 47 orphaned and declared with a reason)
```

All three selftests passed on the base commit too (`daf92db0`, before any edit in this round), so none of
the fixtures it adds is covering a pre-existing failure, and no pre-existing failure is being called a fix.

**One pre-existing failure, named:** `bash scripts/sync-prompt-docs.sh --check` fails on
`docs/ENVELOPE.md: tool-catalogue`, and it fails the same way on `daf92db0` (run in a throwaway worktree of
the base). The block is generated from this node's live tool catalogue, which changed today, so the doc is
stale about the machine rather than about this branch; nothing in this round touches it.


### The reader, measured against the tree instead of argued about

The old reader and the new one were both run with `--list --every string field` (a temporary
`strings.filter((s) => s.carries)` -> `strings` edit, not committed) and the two lists diffed. The counts are
identical - **463** string fields/parameters, **6** polling funcs - and the diff is four lines:

* `model/model.wit configure` moves from context `` (nothing: it was attributed to no block at all) to
  `interface:chat` - a misattribution the old reader made and the new one does not;
* `%list` in `memory/memory.wit` is a func for the first time (`parameter of list scope`), because a
  `%`-escaped name matched nothing before;
* `bus/bus.wit pattern` disappears as a *field*: the old reader read a func's parameter line, on its own, as
  a record field. It is still there as `parameter of subscribe pattern` - the same parameter, counted once.

Two things the rewrite had to get right and did not, on the way (both caught by that diff, both fixed before
the commit): `use types.{error};` is a use LIST whose braces were closing the enclosing interface, and
`subscribe: func(` with its parameters one per line needed the paren depth to carry across lines.

### The module map on this tree

```
module-report: 76 modules = 50 crate(s), 25 component(s), 1 feature(s)
module-report: co-change 0 pair(s) over 70% of the commits touching either module, in at least 2 of them, neither recording a win (50 commit(s) read)
module-report:   hottest: crate:wa-mesh + crate:wa-rendezvous 1/1; crate:wa-capabilities + crate:wa-term 1/4
```

The same tree before the change printed one merge candidate, `crate:wa-mesh + crate:wa-rendezvous (1/50)`.
Under the new denominator that pair is **1/1 = 100%**, which is why the report needs a second shared commit
before it flags a merge: one commit that moved two modules is not a pattern, and the honest thing to print is
the share next to the count. Fifty commits of this tree contain no pair that moved together twice over 70%,
and the report now says exactly that instead of dividing by a window.

Nested crates, measured: `rust/wa-fake-kernel` read **2383** lines and now reads **2207**;
`rust/wa-fake-kernel/fixture` keeps its own row at 176. The tree's whole size total moved by exactly that:
206674 -> 206498 (-176), so no other module's size changed.

## What this round did NOT verify, and the one thing it left unmeasured

* **The Rust compile (item 6) was not run in this round.** The claim "the row below reuses the compile"
  rested on the argument shape and on nothing else: the same manifest, the same profile and the same package
  in both invocations, asserted by `scripts/test-fast-build-timing.sh`. That is all a static check can
  say, and it was measured afterwards - in section 5 of the fix round below, and again on a later head
  (734 ms -> 68 ms, `wa-fleetview`). The check that settles it is `cargo test --no-run -p <crate>`
  followed by the row's own `cargo test`: the second must report nothing to compile. (This bullet used
  to assert that this node has no Rust toolchain at all. It does today - `command -v cargo` answers
  `/home/victor/wasm-agent/toolchain/cargo/bin/cargo`, cargo 1.100.0 - so the sentence was not true of
  the node any more, and it contradicted section 5 twelve lines below. I cannot tell from here when it
  stopped being true, only that the second review of this file was right to call the pair of statements a
  contradiction.)
* `fast.sh` itself was not run end to end in this round (it needs the toolchain for the Rust rows, and a
  binary with code-mode assets for the rest - `REPORT.md` section 7.1 records that failure mode). What
  was run: `bash -n scripts/fast.sh`, the new static fixture, and the two clock cases
  (`fast_now_ms` read 53 ms across a 50 ms sleep, and 1758999999000 against a date that answers the BSD
  way).
* Nothing was pushed, and no deploy was attempted.

## The honesty line on the two judgement calls

Two changes here go beyond the literal instruction, and both are in the code comments:

1. **a merge needs two shared commits** (`CO_CHANGE_MIN_COMMITS`). The instruction was to divide by the
   commits touching either module; done literally, this tree's only pair reads 1/1 = 100%. The minimum is
   what keeps the flag meaningful, and the fixture proves both sides of it.
2. **an unknown commit count is inside the cooldown** (`since === null`). A count that cannot be read is
   not a satisfied one; with `--no-git` the flag still fires only for a decision recorded inside 30 days.


---

# The fix round on fdc2e763 - five items, and the compile this node could finally run

Reviewed head `fdc2e763`, branch `change/architecture-rules`, worktree
`/home/victor/Work/missions/architecture-rules/wt`, base `origin/main` (74d48431). **Nothing pushed.** One
commit on top of `fdc2e763`. `ARCHITECTURE.md` is untouched: the approved text is not this round's to edit
(`git diff --stat fdc2e763 -- ARCHITECTURE.md` is empty).

Four of the five items were holes in the checks this mission added, and one was a run that had never
happened. Each is proved by the fixture that fails without it, and the fixture was run against the old
reader/report first, so "it is fixed" rests on a red line that went green - not on a reading of the diff.

| # | what was wrong | what it does now | the fixture that fails without it |
| --- | --- | --- | --- |
| 1 | a bodyless resource (`resource terminal-input;`, `wit/kernel-v2/deps/cli.wit:126` and `:138`) was pushed on the context stack and never popped, so every later declaration in that file got a nested context (baseline keys, the start/resource pairing) | `declare()` takes the punctuation that ended the declaration and pushes only for `{`; the resource name is still recorded | `bodyless.wit`: the interfaces after it are read where they are, and in the real tree exactly three lines change |
| 2 | `start: func() -> own<job>` beside `resource job { poll }` escaped: `unwrap` stopped at `option`/`result`, so the handle was a type called `own<job>` | `unwrap` strips `own<...>` and `borrow<...>` too | `wrapped.wit`: three start/poll pairs (bare, `own`, `borrow` inside a `result`) - the old reader found one |
| 3 | "not empty, JSON text" was read as a denial, so a JSON-carrying field passed | the negation has to govern the mention: no comma or bracket between the negator and "json" | `negation.wit`: that clause fails, the four denials and the MIME type beside it stay clean |
| 4 | a decision with no date was never "too soon" - an age of `null` made every comparison false, so a record nobody could date read as one that had cleared the cooldown | `days === null` is UNVERIFIED: flagged by name, counted on the decision line, and never read as inside or outside | `test-module-report.sh` 5b: the dateless record is flagged, and exactly one decision is still "too soon" |
| 5 | the fast path, the module map and the row timings had never been run on a node with a toolchain | `bash scripts/fast.sh --all-rust` ran end to end: 277 checks, 622 s, 28 builds timed | the run itself, quoted below |

## 1. the bodyless resource - the blocker, and what it actually did to the tree

`resource terminal-input;` has no body: it names a resource and its declaration is over. The reader pushed
`resource:terminal-input` on the context stack and nothing ever popped it, so the `}` that closed the
interface popped the resource instead, and each interface after it was read one level too deep.

The fixture (`bodyless.wit`) proves both halves: the context a declaration after a bodyless resource is
read in, and that the resource is still recorded (a bodyless resource is still what a start func hands
out). Measured on it, old reader and new:

```
                             OLD (fdc2e763)                                NEW
body:   [interface:handles/interface:later]                     [interface:later]
poll:   [interface:handles/interface:jobs/resource:job]          [interface:jobs]
name:   [interface:handles/interface:jobs/interface:braces/...]  [interface:braces/record:split]
```

Note what the violation COUNT did: it was three before and three after. A count would have called this
file fine; the context is the thing that was wrong, and the fixture asserts the context, not the count.

**On the real tree** the same dump (every func of every `.wit`, with its context) differs in exactly three
lines, all in `wit/kernel-v2/deps/cli.wit` - the funcs after the two bodyless resources recover the
interface they are actually in:

```
< DUMP  kernel-v2/deps/cli.wit  [interface:terminal-input/interface:terminal-output/interface:terminal-stdin]   get-terminal-stdin
< DUMP  kernel-v2/deps/cli.wit  [interface:terminal-input/interface:terminal-output/interface:terminal-stdout]  get-terminal-stdout
< DUMP  kernel-v2/deps/cli.wit  [interface:terminal-input/interface:terminal-output/interface:terminal-stderr]  get-terminal-stderr
> DUMP  kernel-v2/deps/cli.wit  [interface:terminal-stdin]   get-terminal-stdin
> DUMP  kernel-v2/deps/cli.wit  [interface:terminal-stdout]  get-terminal-stdout
> DUMP  kernel-v2/deps/cli.wit  [interface:terminal-stderr]  get-terminal-stderr
```

735 dump lines either way, and the verdict on the tree is unchanged:
`wit-lint ok (25 wit files, 463 string field(s)/parameter(s), 18 named *-json, 6 polling func(s): 5
baselined (3 json-name, 2 poll-without-future), 0 new)`. That is the point of the blocker: it put the
baseline keys and the start/resource pairing of one vendor file on the wrong path while the totals looked
right.

One more shape came with the fix and is proved by the same fixture: a brace alone on its line still opens
the block named above it (`record split` then `{`), which the old reader got right by accident and the
narrow "push only for `{`" rule would otherwise have lost.

## 2. `own<job>` and `borrow<job>` are the resource inside them

`handleOf` had one unwrap that stopped at `option` and `result`, so `start: func() -> own<job>` returned a
string called `own<job>`, which matches no resource. The wrapper set is now
`(?:option|result|own|borrow)`. Measured on `wrapped.wit`, which holds the same pair three times:

```
OLD: FAIL ... [interface:plain-jobs/resource:job] poll: poll sits beside start handing out resource:job     (1 new violation)
NEW: FAIL ... [interface:own-jobs/resource:job]      poll ...
     FAIL ... [interface:borrowed-jobs/resource:job] poll ...
     FAIL ... [interface:plain-jobs/resource:job]    poll ...                                              (3 new violations)
```

## 3. a negation has to govern what it denies

"never JSON" denies JSON. "not empty, JSON text" does not - it says the value IS JSON text, and it was
read as a denial because the negator was anywhere within forty characters of the word. The gap between
them may now hold no comma and no bracket, which is the shortest honest statement of "governs":

```
OLD: wit-lint ok (1 wit files, 5 string field(s)/parameter(s), ... 0 new)      # nothing flagged at all
NEW: FAIL wit-lint: negation.wit:6 [interface:calls/record:args] args: the doc comment says it is JSON...
     wit-lint: 1 new violation(s)
```

and the four denials in the same record keep passing: "never JSON", "The framing is never JSON: a framed
byte stream", "e.g. application/json", "Carries no JSON: the bytes are framed".

## 4. a decision with no date is unverified, not clear

`days === null` made `days < COOLDOWN_DAYS` false, so a record with no `date` read as one that had cleared
both ends of the cooldown. It is now a flag of its own, counted on the decision line; and the same line had
a formatting hole found while proving it - a dateless record printed `split on ?)`, an unmatched bracket
that read as "0 days ago". Measured before and after on the fixture's dateless record:

```
OLD: module-report:   crate:a: split on ?, 8 commit(s) ago) - no date on this one
NEW: module-report: decision  3 recorded; ... ; 1 with no date, flagged unverified
     module-report:   crate:a: split on ? - no date on this one   [FLAG unverified: no date in the record, so its cooldown cannot be read]
```

The record's commit count IS readable there (8 commits), so this is the date alone: 8 < 100 does not make
an undated decision "almost inside" - it makes it unreadable, and the report says so by name.

## 5. the run that had never happened

Cargo is on PATH on this node now (cargo 1.100.0, rustc 1.100.0, wasi-sdk 34.0, node v26.13.1). One run,
`bash scripts/fast.sh --all-rust` (no crate is touched by this branch's diff, so the flag is what makes the
crate rows exist at all), 622 s, 277 checks, 0 skipped.

**The crate build-time rows, as the run printed them** (its own `build-times.tsv` ledger, 28 builds,
slowest first - a crate's number is its `cargo test --no-run` in the tests' own profile):

```
fast:   crate     wa-host                           142.5s  245 unit(s) compiled
fast:   crate     wa-kernel-runtime                 101.0s  9 unit(s) compiled
fast:   crate     wa-mesh                            57.0s  2 unit(s) compiled
fast:   crate     wa-sqlite                          39.3s  19 unit(s) compiled
fast:   crate     wa-capabilities                    23.2s  3 unit(s) compiled
fast:   crate     wa-graph                           13.8s  19 unit(s) compiled
fast:   crate     wa-rendezvous                      11.2s  20 unit(s) compiled
fast:   crate     wa-host-support                    10.9s  4 unit(s) compiled
fast:   crate     wa-sentinel                         9.4s  59 unit(s) compiled
fast:   crate     wa-governance                       5.7s  15 unit(s) compiled
fast:   crate     wa-model-gateway                    5.4s  1 unit(s) compiled
fast:   crate     wa-stt-remote                       3.1s  2 unit(s) compiled
fast:   crate     wa-term                             3.1s  2 unit(s) compiled
fast:   crate     wa-operation                        2.9s  1 unit(s) compiled
fast:   crate     wa-keystore                         2.3s  16 unit(s) compiled
fast:   crate     wa-jobs                             2.2s  1 unit(s) compiled
fast:   crate     wa-whatsapp-outbox                  1.6s  7 unit(s) compiled
fast:   crate     wa-whatsapp-index                   1.3s  1 unit(s) compiled
fast:   crate     wa-fleetview                        0.6s  1 unit(s) compiled
fast:   crate     wa-tool-progress                    0.6s  1 unit(s) compiled
fast:   crate     wa-model-router                     0.5s  1 unit(s) compiled
fast:   component codemode                            0.2s  warm, nothing to compile
fast:   component graph                               0.2s  warm, nothing to compile
... (mesh, svc-echo, memory, hooks, selfloop: 0.1s / 0.0s, all "warm")
```

**The row after `--no-run` compiles nothing** - the claim item 6 of the last round could only argue, now
measured twice. First the pair by hand, in the run's own build root, on wa-sentinel (whose manifest is its
own workspace, its own lock file, and is the reason its test build is in another profile):

```
$ CARGO_TARGET_DIR=<the run's build root> cargo test --no-run --offline --manifest-path rust/wa-sentinel/Cargo.toml
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.05s
  Executable unittests src/main.rs (.../debug/build/wa-sentinel/2a9d6037161d2a7b/out/wa_sentinel-2a9d6037161d2a7b)
  # 75 ms wall, 0 lines starting with "   Compiling"

$ CARGO_TARGET_DIR=<the same> cargo test --offline --manifest-path rust/wa-sentinel/Cargo.toml -- --test-threads=1
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.04s
     Running unittests src/main.rs (...same executable...)
test result: FAILED. 110 passed; 5 failed; 0 ignored; 0 measured; 0 filtered out; finished in 27.35s
  # 27.4 s wall, 0 lines starting with "   Compiling"
```

The same sequence inside the run: `cargo test --no-run` recorded 9.4 s / 59 units for `wa-sentinel` in the
ledger above, and the row that follows it did not compile again. So the build number the module claim
rests on is the test build paid once, and the `wa-sentinel` manifest builds and runs on its own: 110 of
its 115 tests pass, and the 5 that fail are pre-existing (below).

**And the five rows this round owns, as that run reported them:**

```
fast: wit-lint ok (60ms)
fast: wit-lint-selftest ok (613ms)          # 61 checks (was 45)
fast: module-report-selftest ok (485ms)     # 42 checks (was 36)
fast: fast-build-timing ok (78ms)           # 13 checks, 0 skipped (was 1 skipped - it needs cargo)
fast: instructions ok (497ms)
fast: landing-queue ok (6397ms)
```

## The 16 red rows: none of them is this round's, and here is the proof

The run ended `fast path FAILED (16 of 277 checks, 0 skipped, 622s)`. Every one of the 16 is a failure of
the BASE tree, not of this round, and the proof does not rest on an argument this time:

* `git diff --name-only 74d48431 -- rust lua` is **empty**. The code and the tests those rows judge are
  byte-identical to the base commit; this branch changes `scripts/*.sh`, `scripts/*.mjs` and `docs/`.
* Run on the base itself (`git stash push -- scripts docs REPORT.md`, then the same rows, then
  `git stash pop` - pop confirmed, 4 modified files back):
  - `cargo test -p wa-mesh`: `test result: FAILED. 73 passed; 2 failed` - the same two `tests_relay` cases;
  - `cargo test --manifest-path rust/wa-sentinel/Cargo.toml node_script_tests`: the same two
    `node_script` cases fail;
  - one Lua row through the runner (`WA_FAST_ROWS=scripts/test-provider-stall.lua`):
    `FAIL lua scripts/test-provider-stall.lua: a provider call gets its own 90s first-response deadline:
    got "300", want "90"` - identical on the base;
  - and `prompt-docs`, `fast-binary`, `publish-artifacts`, `land-signing` fail on the base too.

The 16, named: 9 Lua rows (`test-observability`, `test-remote-call-shape`, `test-orchestration-mode`,
`test-skill-discovery`, `test-prompt-cache`, `test-provider-stall`, `test-wave-closure-reporting`,
`test-codemode-model-boundary`, `test-host-return-docs`); 3 crates (`wa-capabilities` 1 test -
`registered but undocumented in docs/HOST.md: ["transcript_expand"]`, `wa-sentinel` 5,
`wa-mesh` 2); and 4 contract rows (`prompt-docs` on `docs/ENVELOPE.md: tool-catalogue`,
`fast-binary`, `publish-artifacts` on the manifest/asset ordering, `land-signing` on
`WA_RELEASE_SIGN_DEFER=1` signing a temporary SUM).

Five of the nine Lua rows are prompt/catalogue rows, and the `wa-capabilities` one is a doc that names a
capability the live registry does not - the same family of "the machine changed under the docs" that the
previous round named for `sync-prompt-docs --check`. None of them is in this round's five items, and none
was fixed here: they are reported, attributed and left where they are.

## What this round did not do

* Nothing pushed, no deploy, no landing-queue run: `scripts/landing-queue.mjs` is not part of this round.
* The 16 pre-existing failures were NOT fixed - only proved pre-existing. Four of them (`prompt-docs`,
  `fast-binary`, `publish-artifacts`, `land-signing`) are about this node's release/publish state, and
  they were red before this round's first edit.
* `scripts/test-orphan-tests.mjs` was run (no test file was added by this round): `orphan-tests ok (195
  wired, 47 orphaned and declared with a reason)`.


---

# The second review round on a0926dcd - six items, rebased onto main

Reviewed head `a0926dcd`, branch `change/architecture-rules`, worktree
`/home/victor/Work/missions/architecture-rules/wt`, this node's build root
`/home/victor/wasm-agent/target/m-architecture-rules`. **Rebased onto `origin/main`
(`e5ba9089`) first**: 11 commits replayed, and the root `REPORT.md` add/add conflict resolved by
dropping this branch's copy - the tree carries main's `REPORT.md` and nothing of ours
(`git diff origin/main --stat -- REPORT.md` is empty). This file is the round's only report.
`ARCHITECTURE.md` is byte-identical to what the branch carried before the rebase:
`git diff origin/main -- ARCHITECTURE.md` shows the approved addition itself (10 lines) and no other
change. **Nothing pushed.**

| # | what was wrong | what it does now | the fixture that fails without it |
| --- | --- | --- | --- |
| 1 | the root `REPORT.md` was an add/add conflict with the one main already has | dropped at the rebase, in all six commits that add it | `git diff origin/main --stat -- REPORT.md` (empty) |
| 2 | `cargo test --no-run ... \|\| true`, then the note read cargo's log, so a build that FAILED printed "warm, nothing to compile" | the exit code is kept (`\|\| build_rc=$?`) and `wa_build_time_note` is told it: "build failed (exit N)" | `scripts/test-fast-build-timing.sh` section 3, and the three notes quoted below |
| 3 | a `date` that is there and does not parse was flagged "no date in the record" | "the record's date does not parse: 18/11/2026" | `scripts/test-module-report.sh` section 5c, and the pair quoted below |
| 4 | the round-1 section asserted the compile was never timed, twelve lines above the section that times it | it says what THAT round could not do and points at the measurement; the pair is measured again here | quoted below, and `command -v cargo` on this node |
| 5 | every line starting with `export`/`import` went into the use-statement accumulator: world-level funcs were never funcs, and an inline `import x: interface {` pushed nothing while its own `}` popped the world | the keyword is stripped and the func under it is judged; a named block is pushed and popped by its own brace | `scripts/test-wit-lint.sh`: `world.wit` (4 holes, with their contexts) and `world-clean.wit` (0) |
| 6 | a comment described what an earlier commit of this branch used to do | it says what the row does | `rg 'build --release' scripts/fast.sh` (no match) |

Each item below is quoted from a run on this node. The suites were run with a scratch home (`HOME`,
`TMPDIR` and `WASM_AGENT_HOME` under one `mktemp -d`, `WASM_AGENT_LUA_ROOT` the
worktree); none of them writes under the real `~/.wasm-agent` and none reads `paths.data()`.

## 2. a build that failed is not a warm row

The note that used to lose the exit code, on a log that ends in a compile error
(`scripts/lib/build-times.sh`, called with an exit code the old row never had):

```
old note, exit 1, failed log: warm, nothing to compile
new note, exit 1, failed log: build failed (exit 1)
new note, exit 0, same warm log: warm, nothing to compile
```

The test that fails without it (`scripts/test-fast-build-timing.sh` section 3), against the old files:

```
fast-build-timing FAILED: the build row must keep cargo's exit code (|| build_rc=$?), not swallow it with '|| true'
```

and the note itself is exercised for 0 units, 2 units, exit 1, exit 101 and exit 2 on a two-unit log, where
the exit code outranks the unit count: a failed build's units are not a measurement.

## 3. the reason a decision is unverified

One module, `"date": "18/11/2026"` - a value that is there, and unreadable - old report then new:

```
old: module-report:   crate:x: split on 18/11/2026 - a date nobody can read   [FLAG unverified: no date in the record, so its cooldown cannot be read]
new: module-report:   crate:x: split on 18/11/2026 - a date nobody can read   [FLAG unverified: the record's date does not parse: 18/11/2026, so its cooldown cannot be read]
```

and the decision line, which counted it as a MISSING date:

```
old: ... ; 1 with no date, flagged unverified
new: ... ; 1 with no readable date, flagged unverified
```

`no date in the record` is still what a record with no `date` field says - both are unverified,
and neither is ever read as "cleared"; only the sentence a reader acts on differs. The fixture
(`scripts/test-module-report.sh` section 5c) asserts all four halves: the value printed where the date
would be, the reason with the value in it, the absence of the missing-field sentence, and that an
unparseable date is never ALSO reported as inside the cooldown.

## 4. the sentence that contradicted itself

The first section of this file said the compile "was **not** timed here ... this node has no Rust
toolchain", and the fix round 130 lines below ran it and quoted `0 lines starting with "   Compiling"`
on the second invocation. Both statements cannot stand in one file. The first section now says what that
round could not do, that the claim rested on the argument shape, and where it was measured.

Measured again in this round, with the very invocations `scripts/fast.sh` runs (same manifest, same
profile, same build root), after `touch rust/wa-fleetview/src/lib.rs` so the crate itself had to be
built:

```
$ CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-architecture-rules cargo test --no-run --offline --release --manifest-path rust/Cargo.toml -p wa-fleetview
   Compiling wa-fleetview v0.1.0 (/home/victor/Work/missions/architecture-rules/wt/rust/wa-fleetview)
    Finished `release` profile [optimized] target(s) in 0.72s
  # 734 ms wall, 1 line starting with "   Compiling"

$ CARGO_TARGET_DIR=<the same> cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-fleetview
    Finished `release` profile [optimized] target(s) in 0.03s
     Running unittests src/lib.rs (...the same executable...)
  # 68 ms wall, 0 lines starting with "   Compiling"
```

The same pair on `wa-keystore`: 494 ms and 1 unit compiled, then 427 ms and 0 units, 13 tests passing.
So the number the build-time row records is the compile the row below it reuses, and it is paid once.

## 5. world-level funcs are funcs, and an inline interface is a block

`wit/kernel/host.wit:84`, `:92` and `:97` are `export run: func(...)`,
`export call: func(...)` and `export reset: func()` inside `world core-component`. The reader
sent every line beginning with `export`/`import` into the use-statement accumulator, so those
three were never funcs: rule 1 never read `entry: string` or `name: string`, and rule 2 never
saw them beside one another. The same accumulator swallowed an inline `import x: interface { ... }`:
its brace pushed nothing, so its own `}` popped the WORLD, and every declaration after it was read
outside the world it sits in. One fixture, the old reader then the new one:

```
=== BEFORE (HEAD's reader):
FAIL wit-lint: world.wit:22 [world:core-component] open.config: the doc comment says it is JSON, and config: string does not carry -json in the name
wit-lint: 1 new violation(s), 0 stale baseline line(s), 0 baselined
exit=1

=== AFTER (this round's reader):
FAIL wit-lint: world.wit:11 [world:core-component] run.args: the doc comment says it is JSON, and args: string does not carry -json in the name
FAIL wit-lint: world.wit:22 [world:core-component/interface:handles] open.config: the doc comment says it is JSON, and config: string does not carry -json in the name
FAIL wit-lint: world.wit:26 [world:core-component] last.payload: the doc comment says it is JSON, and payload: string does not carry -json in the name
FAIL wit-lint: world.wit:16 [world:core-component] status: status sits beside submit handing out operation-id: return a future/stream instead, or mark the doc "legacy wrapper over <future-func>"
wit-lint: 4 new violation(s), 0 stale baseline line(s), 0 baselined
exit=1
```

Four facts, each one an assertion in `scripts/test-wit-lint.sh`: the exported func is a func (its
parameter is judged); a world-level `status` is the polling func the rule exists for, beside the
`submit` that hands out the operation id; the inline interface's funcs are read INSIDE it
(`world:core-component/interface:handles`); and `last`, declared AFTER that inline interface,
still has the world's context - the world was not popped. A second fixture, `world-clean.wit`, is a
world of references only (`import types; export service; include other-world;`) and reports 0 new:
naming an interface is not a violation, so the fix widens what is read without widening what fails.

On the tree, `bash scripts/wit-lint.sh` before and after this reader, `0 new` in both:

```
old reader: wit-lint ok (25 wit files, 463 string field(s)/parameter(s), 18 named *-json, 6 polling func(s): 5 baselined (...), 0 new)
new reader: wit-lint ok (25 wit files, 465 string field(s)/parameter(s), 18 named *-json, 6 polling func(s): 5 baselined (...), 0 new)
```

- the two new names are `host.wit`'s `run.entry` and `call.name`, the world-level string
  parameters rule 1 can now see. Neither carries JSON, so neither is a violation and the baseline does not
  grow.

## 6. the comment about an earlier commit

`scripts/fast.sh`'s build row said "This used to run 'cargo build --release -p <crate>' and then the
row below ran 'cargo test' in the profile it needs: for wa-sentinel that is two profiles and two compiles of
the same source...". The history of a branch is not the explanation of a row: the comment now says what the
row does and why, and `rg 'build --release' scripts/fast.sh` finds nothing.

## What this round ran, and what it did not

* `scripts/test-wit-lint.sh`: **71 checks, 0 skipped** (61 before this round's fixture).
* `scripts/test-module-report.sh`: **47 checks, 0 skipped** (42 before).
* `scripts/test-fast-build-timing.sh`: **20 checks, 0 skipped** (13 before).
* `bash scripts/wit-lint.sh`: ok, 465 strings, 5 baselined, 0 new;
  `node scripts/module-report.mjs` on this tree: 76 modules, 43 with a build time from the recorded
  baseline.
* The compile pair above, twice, on this node.
* **NOT run:** `bash scripts/fast.sh` end to end. It takes ~620 s and this round's change touches three
  rows, all of them run directly and quoted here. The 16 rows that the earlier run recorded as failing are
  the ones the section above already attributed to the base tree; this round's diff is 13 files
  (`git diff --stat origin/main`): `ARCHITECTURE.md`, three under `docs/` (none of them a prompt
  doc), and nine under `scripts/`, while those rows read `lua/`, `rust/` and the prompt docs.
* Nothing pushed; no deploy; no landing-queue run.

## Texts to approve

Every new or changed model- or operator-facing string, verbatim:

1. `build failed (exit %s)` - new, `scripts/lib/build-times.sh`, printed in the fast path's
   build-time summary where a failed build used to print the warm sentence. In place:
   `fast:   crate     wa-x                                 0.7s  build failed (exit 101)`
2. `the record's date does not parse: <value>` - new reason inside the existing flag, so the whole
   line now reads `[FLAG unverified: the record's date does not parse: 18/11/2026, so its cooldown cannot
   be read]` (`scripts/module-report.mjs`). The unchanged sibling for a missing field is
   `[FLAG unverified: no date in the record, so its cooldown cannot be read]`.
3. `N with no readable date, flagged unverified` - replaces `N with no date, flagged
   unverified` on the report's decision line (`scripts/module-report.mjs`), because a date that does
   not parse is not an absent one.

Nothing else a model or an operator reads changed: the wit-lint's own messages are unchanged
(`wit-lint ok (...)`, the `FAIL wit-lint: ...` lines, the `--list` format), and
`scripts/fast.sh`'s other lines are untouched.
