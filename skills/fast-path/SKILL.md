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
  the way a deploy installs them, into a digest-named set under the git common dir;
- each row gets its **own copy** inside its own `WASM_AGENT_HOME`, and a test asks
  `scripts/lib/test-components.lua` to install only the component it needs;
- a machine that cannot build one reports `SKIP <test>: <reason>` - it never passes a row whose
  component was absent (a test that writes into the component directory would otherwise be "tested"
  against another row's state).

So: a test names its components through that helper, never by assuming a global `WA_COMPONENTS_DIR`;
and a missing toolchain is a SKIP with the reason, not a green row.

## 3. The full gate is nightly, and for releases

```bash
bash scripts/test.sh                 # ~50 min; via scripts/wave-release.mjs
```

The full gate runs nightly and on an explicit release request. **Never gate a routine landing on it**
(landings report `gate_verified:false`, `release_verified:false` - `lane-policy.json`). A landing's
evidence is the fast path on the merged tree plus the readback of `origin/main`.

## 4. A Lua test only tested the tree when a Lua root is in use

Without `WASM_AGENT_LUA_ROOT`, `WA_SCRIPT` runs the modules **embedded in the binary**, not `lua/` -
so a test can pass against a binary from another commit. Set the root when the subject is the tree's
Lua, and say which one ran when it is not obvious from the command.
