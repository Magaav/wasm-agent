---
name: fast-path
description: >-
  How a change is checked before it lands: what `bash scripts/fast.sh` runs and what a SKIPPED row means,
  how a Lua test gets the components it needs (the test-component contract), and when the full
  `scripts/test.sh` gate is owed. Use before integrating a branch, when writing or repairing a
  `scripts/test-*.lua` test, when a check reports SKIP, or when someone asks for the full gate.
---

# The fast path, the test-component contract, and the full gate

AGENTS.md keeps the rules; this is the procedure behind them. Load it when you are about to run or
repair a check, not on every turn.

## 1. What runs, and what "done" means

```bash
bash scripts/fast.sh                 # minutes; the day-to-day check before integrating
bash scripts/fast.sh --jobs 2        # three or four sessions on one Windows node: lower it
```

It runs, in parallel where it can:

1. **every self-contained `scripts/test-*.lua`** that is not listed in `scripts/fast-path.exclude`,
   each in its own scratch home and ledger (no node, no network, no shared state);
2. **Rust unit tests for the crates the change touches** (against the merge base with `origin/main`
   plus the working tree; `--all-rust` for every crate). `wa-sentinel` runs single-threaded - its
   tests share process-wide environment;
3. **contract checks**: prompt docs in sync, the instruction files, the landing queue, session
   liveness, the landing baseline, the deploy's retirement rule, and the fast-environment classifier.

A pass with a `SKIP` row is reported as skipped, never as a run that tested it: the reasons are
printed under the counts. A machine-only failure (`cannot fork`, exit 125/126) is retried once,
serially, and only then reported as the machine (exit 3) - the landing queue reads that as "retry",
never as a verdict on the branch.

**A new test belongs in the fast path.** Make it self-contained (its own `mktemp` home, no shared
state, no network, no node it did not start) and leave `scripts/fast-path.exclude` alone. If it cannot
be self-contained it belongs in the nightly gate, and that is a named reason, not a silent exclude.

## 2. The test-component contract

Component-backed Lua tests (graph, mail, selfloop, ...) do not share one component directory:

- `scripts/fast.sh` builds the components **from this tree** with `scripts/build-components.sh`, pinned
  the way a deploy installs them, into a set under the worktree's own git dir (`<git-dir>/wa-fast-components/set`,
  cargo's fingerprints decide what to rebuild: 53 s cold, ~6 s for five when nothing changed);
- each row gets its **own copy** inside its own `WASM_AGENT_HOME`, and gets the component it *names*:
  a test whose text says `WA_<NAME>_COMPONENT_WASM` (the variable its skip message prints) has that
  artifact installed, pinned, and the override and switch handed to the host. `graph` is the other
  contract: those tests ask `scripts/lib/test-components.lua` to install it;
- a machine that cannot build one reports `SKIP <test>: <reason>` - it never passes a row whose
  component was absent (a test that writes into the component directory would otherwise be "tested"
  against another row's state).

So: a test names its components either by the host variable it reads or through that helper, never by
assuming a global `WA_COMPONENTS_DIR`; a missing toolchain is a SKIP with the reason, not a green row;
and the runner enforces both ends - a row that names a component and still reports it missing is a
`FAIL component-provisioning`, and `scripts/test-fast-row-environment.lua` (a real row) fails naming
any variable the node did not receive, because a variable the shell has and the node does not has cost
this fleet three separate investigations.

## 3. Which `wa` the rows run

The first line of every fast run names the binary, its build commit, this tree's commit and the verdict
(`fresh`, `stale`, `unknown`) - `bash scripts/fast.sh --binary` prints just that and exits:

```
fast: binary /home/wa/wt-x/rust/target/release/wa (build 47ece9281234, tree d735fe0d5e15, fresh: built from this tree) sha256=...
```

- The **tree's own** binary wins over `command -v wa` and `~/.local/bin/wa`. On this node
  `~/.local/bin/wa` is a symlink into the canonical checkout, and three sessions (11/11) ran green rows
  against *that* commit while their worktree's edits were never loaded - the reason the lookup order is
  now tree-first and the choice is printed.
- A missing or stale tree binary is **built** (`cargo build --release --offline`, stamped with this
  commit, with the prepared code-mode assets when `.git/codemode-assets` holds any), so the rows test
  this tree. When it cannot be built, the run stops with `stale_binary` and the exact command.
- `WA_BIN=<path>` is authoritative (a human named it), `WA_FAST_SKIP_BUILD=1` forbids building,
  `WA_FAST_ALLOW_STALE_BINARY=1` runs the stale one with the fact printed on the first line. Rows that
  need more than a working node - the code-mode ones - are named when the binary has no assets.
- The Rust rows establish `WA_CODEMODE_BUILD_ASSETS` instead of `WA_CODEMODE_ALLOW_EMPTY=1` whenever the
  assets exist: the empty switch rebuilds `target/release/wa` without code mode (72 598 376 B vs
  73 904 880 B, measured), so a test run replaced a capable node with an incapable one.

`scripts/test-fast-binary.mjs` (in the fast path) drives the resolver against fixture checkouts and stub
binaries - fresh, stale, missing, `WA_BIN`, the override - and asserts that the real script's first line
is the resolution.

## 4. The full gate is nightly, and for releases

```bash
bash scripts/test.sh                 # ~50 min; via scripts/wave-release.mjs
```

The full gate runs nightly and on an explicit release request. **Never gate a routine landing on it**
(landings report `gate_verified:false`, `release_verified:false` - `lane-policy.json`). A landing's
evidence is the fast path on the merged tree plus the readback of `origin/main`.

## 5. A Lua test only tested the tree when a Lua root is in use

Without `WASM_AGENT_LUA_ROOT`, `WA_SCRIPT` runs the modules **embedded in the binary**, not `lua/` -
so a test can pass against a binary from another commit. Set the root when the subject is the tree's
Lua, and say which one ran when it is not obvious from the command.
