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

## What this round did NOT verify, and one thing it could not run

* **The Rust compile (item 6) was not run.** This node has no Rust toolchain: `command -v cargo` is empty,
  `pacman -Qs '^rust'` finds no package, there is no `/usr/bin/rustc` and no `~/.cargo` - although
  `/home/victor/wasm-agent/target/m-architecture-rules` holds 3.6 GB of artifacts from when it did. So
  `cargo test --no-run` was **not** timed here and the claim "the row below reuses the compile" rests on
  the argument shape, not on a measurement: the same manifest, the same profile and the same package in both
  invocations, asserted by `scripts/test-fast-build-timing.sh`. On a node with the toolchain, the check that
  settles it is `cargo test --no-run -p <crate>` followed by the row's `cargo test` - the second must
  report nothing to compile.
* `fast.sh` itself was not run end to end (it needs the toolchain for the Rust rows, and a binary with
  code-mode assets for the rest - `REPORT.md` section 7.1 records that failure mode). What was run:
  `bash -n scripts/fast.sh`, the new static fixture, and the two clock cases (`fast_now_ms` read 53 ms
  across a 50 ms sleep, and 1758999999000 against a date that answers the BSD way).
* Nothing was pushed, and no deploy was attempted.

## The honesty line on the two judgement calls

Two changes here go beyond the literal instruction, and both are in the code comments:

1. **a merge needs two shared commits** (`CO_CHANGE_MIN_COMMITS`). The instruction was to divide by the
   commits touching either module; done literally, this tree's only pair reads 1/1 = 100%. The minimum is
   what keeps the flag meaningful, and the fixture proves both sides of it.
2. **an unknown commit count is inside the cooldown** (`since === null`). A count that cannot be read is
   not a satisfied one; with `--no-git` the flag still fires only for a decision recorded inside 30 days.
