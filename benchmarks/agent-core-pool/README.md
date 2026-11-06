# agent-core instance pool (A2.3)

The harness behind `docs/KERNEL.md`, "A2.3 results": the pool the agent-core component runs from
(`rust/wa-capabilities/src/core_component.rs`, `CoreComponentPool`) and the numbers quoted there.

Nothing here is part of the gate's verdict except through `scripts/test.sh`'s own core-component
block, which runs the pooled path once and compares its output with a one-shot `--core-component`
run. This directory is the repeatable measurement.

## Files

| file | what it is |
| --- | --- |
| `bench.sh` | native / component / pooled, medians of `RUNS` (default 5), plus a byte comparison of the three outputs for the four gate scripts |
| `fixtures/first-statement.lua` | the measured run: its **first statement is a host call**, which is how "time to first Lua statement" is observed at the bridge instead of guessed |
| `fixtures/pool-fixture-module.lua` | a ~130-line module the fixture loads through `EMBEDDED`: the source the guest snapshots per instance |
| `fixtures/fresh-state.lua` | fails if a reused instance leaks a global from the previous run |
| `fixtures/parallel.lua` | one concurrent caller's turn; the harness, not the script, proves the leases were distinct |

The Rust side is `rust/wa-core-pool-bench` (a workspace member, not part of the shipping binary):

```
wa-core-pool-bench bench       <agent-core.wasm>            # the pool's own numbers, medians of 5
wa-core-pool-bench gate        <agent-core.wasm> <script>   # one pooled run (what test.sh greps)
wa-core-pool-bench concurrency <agent-core.wasm> <n> <script>  # n calls, n leases held at once
```

## Running it

```bash
bash scripts/build-agent-core.sh                       # needs wasi-sdk; prints the .wasm path
export WA_BIN=rust/target/release/wa WA_POOL_BIN=rust/target/release/wa-core-pool-bench
export WA_COMPONENTS_DIR=<where build-components.sh installed mcp-echo etc.>
bash benchmarks/agent-core-pool/bench.sh               # the four gate scripts, all three modes
"$WA_POOL_BIN" bench rust/components/agent-core/target/wasm32-wasip2/release/agent_core.wasm
```

`WA_CORE_CACHE=0` disables the compiled-component cache, so `bench` measures a real compile on every
iteration instead of the `cwasm` hit.

## What the harness has to get right (each of these was a wrong number first)

- **Every run gets its own home and ledger.** `test-batch-tools` asserts it *created* a file, so a
  second run in the same home fails on its own leftovers. The gate runs each block once, which is why
  one home per block is right there and wrong here.
- **The environment is fenced** to what `scripts/test.sh` gives a block. The pool's native interpreter
  is booted from scratch by `wa-core-pool-bench`, and with a managed node's variables in the
  environment the tool catalogue is bigger (peer connector tools appear) and the comparison is
  meaningless.
- **`TMPDIR` is part of the fence.** Without it `paths.temp()` falls back to the Windows directory
  itself, and an atomic write fails with "new text file creation" in all three modes.
- **The pooled runner boots the node's home** the way the binary does (`resolve_home`, `HOME`,
  `WASM_AGENT_DB`, `~/.wasm-agent/env`). Before that was fixed, a pooled fixture resolved
  `host.paths()` from the *process's* HOME and wrote into the operator's real `~/.wasm-agent` while the
  same script run natively wrote into the scratch home.

## Reading the numbers

- *native* is `wa run` in process; *component* is the same script inside the `agent-core` component
  through the one `wa:kernel/host` import; *pooled* is the same component through the pool.
- The pooled column is a *leaner process* than the component one: `wa-core-pool-bench` does not do the
  binary's boot (ripgrep provisioning, plugin registry scan, graph configuration) and, in an MSYS shell
  where `HOME` is a `/c/...` path, it does not pay the per-process `cwasm` cache miss the component
  runs pay (~0.4-0.6 s). Both are real costs of a per-process `--core-component` turn and neither is a
  cost of a pooled turn, which is the point of the pool - but they are not the *guest's* cost, so read
  the columns as "a turn, end to end" and the `bench` table as the guest's own numbers.
