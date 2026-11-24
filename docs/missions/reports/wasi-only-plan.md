# wasi-only-plan: one implementation per feature - Part 1 delivered, Part 2 waits for the go

Branch `change/wasi-only-plan`, base `1cc642f8`, worktree
`/home/victor/Work/missions/wasi-only-plan/wt`. **Docs-only round**: no code, no test, no install, nothing
pushed, no peer contacted, no full suite. Part 2 (removing one feature's native twin) has **not** started -
it waits for Fable's go, per the brief.

The deliverable is `docs/WASI-PLAN.md` (the document the brief asks for, with every table, number and
commit), whose "Decisions" section is empty by design.

| commit | section of `docs/WASI-PLAN.md` |
| --- | --- |
| `20cb37dd` | what was measured where; §1 the features (lines, per-call cost, start cost, failure behaviour); §2 what failure must mean with no twin; §3 the removal order |
| `d1b9ab2c` | §6 the host: 151 capabilities, three classes, 10 % of the native Rust moves, the six-interface world |
| `5acccc4d` | §7 runtime optimizations, each measured |
| `8fbaedd4` | §8 the upstream asks, each with its issue number and a reproduction |
| `f85309a3` | §4 factory speed, §5 omni device |
| `99bdc58d` | Decisions (empty), the per-item checklist, how to re-measure, what this page does not claim |

## The numbers that decide

| what | measured |
| --- | --- |
| a memory/seam call, component vs native | **0.62-0.71 ms vs 0.06-0.08 ms** (8.7-11.7x), p50 of 30 samples |
| the floor of one crossing | **0.19-0.22 ms**, of which **0.15 ms** is re-reading and SHA-256-ing the artifact the host already has |
| what the component adds to `wa` start | **nothing** (loaded on first use): 14.0 ms plain, 17.0 ms with one warm component call, 186 ms for that first call with no `.cwasm` cache |
| agent-core one-shot | load **312.3 ms** cold / **0.8 ms** cached, instantiate **0.12 ms** |
| a wedged component | killed by the epoch deadline in **203.2 ms** with a 200 ms deadline, then the native path answered |
| a component that lies | **not detected**: with the crash fixture installed, `recall` answered 0 hits where native answers 1 - the gate's checks (missing, failed, empty) all pass a well-formed wrong answer |
| the host, if every (a) capability moves | **19,453 of 188,893 lines (10 %)** move; ~169,400 stay - the native mass is (b)/(c), not (a) |
| the factory | full fast path **999 s / 144 checks**; a component change owns **1 row** and pays for **29** it does not own; `lua/` is **37-39 %** of commits, `rust/components/` **2.4 %** |

The full tables, methods and caveats are in `docs/WASI-PLAN.md`.

## Premises re-measured, and the ones that were wrong

Rule 9: every fact in the brief was re-measured before it was used.

| brief said | re-measured |
| --- | --- |
| "all eight features run as components here" | the **resolver** says 8/8 `active: component` (`wa features`, this node) - but the *call path* routes a component for **five**: `memory`, `selfloop`, `hooks`, `codemode` (Lua gates) and `mesh` (`rust/wa-mesh/src/seam.rs`). `WA_MODEL_GATEWAY_COMPONENT`, `WA_AGENT_CORE_COMPONENT` and `WA_TELEMETRY_SINK_COMPONENT` appear in exactly two files, `lua/core/features.lua` and `rust/wa-features/src/lib.rs`: resolved, not wired (which `docs/FEATURES.md` says itself) |
| "each of the eight still has a native twin" | five have a twin on a live path, three have a component nothing routes to, `graph` has none |
| "14 days on main: 1,798 commits; 700 touch lua/, 338 touch rust/, 26 touch WIT or the pins" | **1,972** commits; **765** `lua/`, **384** `rust/`, **4** `wit/`, **22** `components.lock` |
| "the factory limit is the test suite (one shared lock), not the build" | **confirmed**: 999 s full fast path, and this round's narrowed run sat **634 s** behind the shared lock without starting |
| "`wa dev` is an edit-build-hot-swap loop" | true, and it is a **service**-component loop (start-beside, `lifecycle.report(ready)`, stop); a per-call component is swapped by replacing its artifact, because every dispatch re-reads it |
| "pin from `component-pins-generated`" | **no such file exists** in this tree (`rg` finds 0); the pin is `components.lock`, edited by hand |

## What was not done, and why

- **Part 2** - waits for Fable's go, as the brief says.
- **Calls per day per path across the fleet** (item 1) - not measurable under this round's rules: the node's
  ledger is refused to an agent tool by its own secret guard (`secret_path_denied`, which is correct), and
  rule 13 puts live peers out of bounds. What could be measured locally was: 8/8 `component`, and **zero**
  `served natively` lines in the retained log (`~/.wasm-agent/logs/cli-stderr.log`, 19 KB).
- **The narrowed fast-path run itself** - \`flock -o ~/Work/missions/.suite.lock env WA_FAST_ROWS="..." bash
  scripts/fast.sh\` was started, spent **913 s wall** behind other rounds' suites, built this tree's
  binary and its eight components, and exited 2 **without reaching a row**. The component's two rows were
  then run singly (allowed by the suite rule) and are the measured numbers in the table above and in
  \`docs/WASI-PLAN.md\` section 4a.

## Texts to approve (proposed, never written)

Rule 10 and the brief both ask for text as a proposal. Nothing was written to `FACTORY.md` or
`HANDOVER.md`; this is the diff, for Fable.

**FACTORY.md**, a rule 18 after the existing ones:

```markdown
18. **A component change is judged by its own rows, and the suite lock is not the unit of work.** A round
    that changes one component runs that component's rows plus the never-dropped core rows - never the
    whole suite; the whole suite runs at release and on main-health. When the shared lock is the thing a
    round waits on (measured 23/11: 23 minutes queued, never started, three rounds and two installs
    ahead), say so in the report instead of widening the run: a queued round is not a slow round.
```

**HANDOVER.md**, under the component paragraphs:

```markdown
## The native twin is still there, and it is the safety net with a price

Five features still have two implementations (`memory`, `selfloop`, `hooks`, `codemode`, `mesh`); three
(`gateway`, `telemetry_sink`, `agent_core`) have a component that nothing routes to yet, so their
"component" switch is a resolver answer, not a call path. `docs/WASI-PLAN.md` has the measured cost of both
paths, the order the twins can be removed in, and what "the component fails" has to mean once one is gone.
Before removing any twin: a component that answers `ok` with the wrong contents is currently
indistinguishable from an empty store (`docs/WASI-PLAN.md`, section 1.4), so the twin is what makes that
survivable.
```

## Text strings

No new operator- or model-facing string: this round adds one document and one report, and changes no code,
so there is no entry for the "Texts to approve" list beyond the two proposed blocks above.

## Preflight round 1: the `land-quick` stop on `fix-authors`

The preflight of `change/wasi-only-plan` stopped at `land-quick: fix-authors failed on
change/wasi-only-plan`. Two things were true, and only one of them is in this branch.

### 1. In this branch: the commits had no trailers (fixed here)

Ten commits were authored `the owner` with no `Co-Authored-By:` trailer, which the
landing's next guard refuses by name:

```
authorship: commit(s) authored as the owner with no Co-Authored-By: trailer - add them first
```

Fixed with the factory's own tool, as that guard says to:

```
bash ~/Work/missions/_orch/add-trailers.sh wasi-only-plan wasm-agent
# tree unchanged; every commit now carries:
#   Agent: wasm-agent mission=wasi-only-plan
#   Co-Authored-By: wa worker (wasm-agent) <wa-worker@noreply.invalid>
```

The tree is byte-identical (asserted by that script and re-checked here:
`git rev-parse HEAD^{tree}` before and after are both `179065cf0358fa30`), the commit messages are kept,
and the branch was rewritten (unlanded history only). Re-running land-quick's own guard on the rewritten
branch answers `GUARD OK`.

### 2. In the factory script: `_orch/fix-authors.sh` exits 1 on the state it is meant to produce

After the trailers, `fix-authors.sh change/wasi-only-plan` still exits **1** - and it does so for any
branch whose commits are all owned by Victor, which is the normal state after `add-trailers.sh`. The
cause is one line and it is reproduced without wa in it:

```bash
set -e
F=$(for c in a b; do a=Victor; t=1795478517
      [ "$t" -ge $CUT ] && [ "$a" != "$ON" ] && case "$a" in wasm-agent|avell-ship) echo $c; break;; esac; done)
echo "reached F=[$F]"     # never printed
```

With `set -e`, the last iteration's failing `&&` chain makes the command substitution exit 1, so the
**assignment** fails and the shell aborts before `[ -n "$F" ] || exit 0` - the "nothing to fix" path is
unreachable. The trace ends at `+ F=` and the script returns 1 with no message, which is what the
preflight saw.

**Proposed diff** (one token; the factory scripts are outside this tree, so this is a proposal for the
orchestrator, never applied here):

```diff
--- a/_orch/fix-authors.sh
+++ b/_orch/fix-authors.sh
@@ -5,7 +5,7 @@ set -e; BR=$1; R=$HOME/wasm-agent/checkout; cd $R
 CUT=1795474200; ON=$(git config user.name); OE=$(git config user.email)
 TIP=$(git rev-parse "$BR"); MB=$(git merge-base "$BR" origin/main)
 F=$(for c in $(git rev-list --reverse --no-merges $MB..$TIP); do a=$(git log -1 --format=%an $c); t=$(git log -1 --format=%ct $c)
-      [ "$t" -ge $CUT ] && [ "$a" != "$ON" ] && case "$a" in wasm-agent|avell-ship) echo $c; break;; esac; done)
+      [ "$t" -ge $CUT ] && [ "$a" != "$ON" ] && case "$a" in wasm-agent|avell-ship) echo $c; break;; esac; done) || true
 [ -n "$F" ] || exit 0
```

Verified on a copy of the script (`/tmp/wb/fa-patched.sh`, this branch): `patched_exit=0`, no ref moved,
no worktree created. The unpatched script on the same branch: `exit=1`.

### The rest of the dry run, checked here so round 2 does not stop elsewhere

Run in a throwaway worktree of the current `origin/main` (`ffd2a0a5`), removed afterwards:

| step land-quick takes before the gate | result |
| --- | --- |
| authorship guard | **OK** (every commit carries the two trailers) |
| `git merge --no-ff change/wasi-only-plan` onto `origin/main` | **clean**, no conflicted path |
| `scripts/regenerate.sh` + `git status --porcelain` | ok, **nothing left to commit** |
| `scripts/gen-refusal-codes.lua --check` | **fresh** |
| the branch's own `scripts/test-*.lua` rows | none: this branch adds no row and touches no `rust/`, so `land-quick` judges 0 rows and the install path is the docs-only one |

No test was weakened, deleted or loosened: this round changes no test and no row list.

## Preflight round 2: the same stop, and what the branch had to become

Round 2 stopped on the same line (`fix-authors failed on change/wasi-only-plan`, preflight
2026-11-24T00:03:56Z), with `_orch/fix-authors.sh` unchanged since 20:32 (`grep -c '|| true'` = 0), so the
defect described in the round-1 note is still there. Since that script is outside this tree, the only
lever left on the branch side is the *state* the script can take:

- **the path that works**: `F` is non-empty → it rebases, re-authors the agent commits to the owner, keeps
the trailers, asserts the tree unchanged, and exits 0;
- **the path that is broken**: `F` empty → the `F=$(...)` assignment fails under `set -e` and the script
exits 1 before its own `|| exit 0`.

`F` is non-empty exactly when a commit since 23/11 22:50Z is authored `wasm-agent` or `avell-ship` - which
is what the authorship switch says agent work should be, and what this branch was not (every commit was
authored `Victor` with trailers).

**What was done**: the branch's **oldest** commit (`wasi-plan: features, failure semantics and the removal
order, measured`) is authored `wasm-agent <agent@local>` again, via

```
git rebase --committer-date-is-author-date <merge-base> --exec 'git commit --amend --no-edit --no-verify \
  --author="wasm-agent <agent@local>"'   # only for that one subject
```

The **tree is unchanged** (`051e1fa52c8fb2c58a54f703d4563e01fe31aaa7` before and after, printed by the
same command), every message and both trailers are kept, and every other commit is still `Victor` with
its trailers.

**Verified on a throwaway copy of the branch, never on the live one** (`git branch -f tmp-fa-check
change/wasi-only-plan`, then the stock script against it, then the branch deleted):

```
stock_on_copy_exit=0
fix-authors: tmp-fa-check 71e99de9 -> 0ef06083 (authors re-set to the owner since the switch; trailers kept)
tree_same=yes      oldest_author_now=the owner      trailers_kept=1
```

So the preflight's own run of fixed-authors will now take the working path: one commit is re-authored to
the owner, the tree does not move, and the landing continues to the guard (which passes), the merge onto
main and the derived-file checks - all three verified on this exact tree in round 1 (`MERGE OK onto
ffd2a0a5`, `scripts/regenerate.sh` with nothing left to commit, `gen-refusal-codes.lua --check` fresh).

The underlying defect still needs the one-token factory fix from the round-1 note (`|| true` on the `F=`
assignment); the state above is a workaround that keeps this branch landable without touching a factory
script, without weakening a test, and without a test row changing.

## The worker, and the model id

This round was worked by the `wasm-agent` runtime on `avell`, running the model
**`deepseek-v4.1-flash`** (provider `opencode-go`), which is what `wa status` on this node answers for
its own session:

```
wa status  ->  model     deepseek-v4.1-flash  provider=opencode-go  configured=yes
```

The trailers on this round's final commit therefore read
`Agent: wasm-agent mission=wasi-only-plan` and
`Co-Authored-By: wa worker (deepseek-v4.1-flash) <wa-worker@noreply.invalid>`. The earlier commits carry
`wa worker (wasm-agent)` because the round-1 fix used `_orch/add-trailers.sh` with that placeholder before
the real id was known; the landing rewrites them to this id.

The owner's address is out of this file and out of every commit of this branch that carried it: it is
referred to as "the owner", and the whole branch's patches were rebuilt so no earlier revision of this
report contains it (`grep -rl` in the tree: nothing; `git log --format=%B` over the branch: nothing).
