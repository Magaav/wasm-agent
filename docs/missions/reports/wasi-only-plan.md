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
