# idle-costs-nothing — the idle node compiles modules it already holds

Branch `change/idle-costs-nothing`, worktree `wt-idle`, base `84532d12a` (origin/main at the time).
Measured on this machine, 16 threads, 28/11. Method: per-thread CPU from `/proc/<pid>/task/*/stat` over 60 s
of wall clock, the same method as `component-calls-cheap` (`docs/missions/reports/component-calls-cheap.md`).

## Verdict up front

One thread, one call, one cause. **`wa-placement`** (`rust/wa-capabilities/src/serve.rs`) calls the Lua
`wa_orchestrator_tick` every two seconds, and that tick `dofile`s three modules — `orchestrator.lua`,
`handle_wake.lua`, `selfloop.lua`. The boot's `dofile` **read the file, SHA-256'd it, parsed it and compiled
it on every call**. So an idle node paid three full Lua compiles every two seconds for code that had not
changed.

| scenario (60 s idle) | before | after |
|---|---|---|
| `wa serve`, whole process | **5.07 %** of a core | **0.43 %** |
| `wa serve`, `wa-placement` thread | 4.52 % | 0.27 % |
| `wa serve`, every other thread | 0.42 % + 0.07 % | 0.08 % + 0.05 % |
| `wa chat` (TUI) in tmux | 0.03 % | 0.03 % |

11.8× less CPU on an idle node, and the tick by name is `wa_orchestrator_tick` on `wa-placement`.

Both sides are the same build configuration (`WA_CODEMODE_ALLOW_EMPTY=1`, no prepared code-mode assets — see
(b)), the same scratch home, the same ports, the same binary path shape, `before` built from `9d8d29a5` and
`after` from this branch.

**The TUI does not run this tick** in a headless tmux session: 0.03 % both sides, 20 ms of CPU in a minute.
The 7.6 %-7.8 % the 23/11 report measured for "an idle TUI" does not reproduce here with no reader attached,
and the number I can stand behind for it is 0.03 %. The idle cost that the brief is about is the serve
placement tick, and that is measured above.

## (a) What the fix is

`dofile` now caches the compiled chunk, **keyed by the module's own text**:

- embedded sources (the shipping build) cannot change inside a process, so the read, the hash and the compile
  happen once and never again;
- a `WASM_AGENT_LUA_ROOT` file that was edited differs in its bytes, which is a different key, so it
  recompiles — **hot reload is untouched**, and that is proven, not asserted (see the row below);
- the chunk is still **called** on every `dofile`, so a module body that runs per call behaves exactly as
  before. Only the parse and the compile are skipped.

Both boots carry the change, because the tick runs in whichever one the node was built with:
`rust/wa-capabilities/src/core_component.rs` (pool and component boot) and `rust/wa-host/src/main.rs` (the
binary's boot).

The row, `a_dofile_compiles_once_until_the_module_changes` (`core_component.rs`): three `dofile` calls
compile **once**, hash **once**, and run the body three times; editing the module's text compiles it again and
runs the new body. That is the brief's test for (a), and it fails on main by construction — there is no cache
there and `DOFILE_COMPILES` does not exist.

## (b) The double open on a `run` call - MEASURED, cause narrowed to the caller

One `run` call for a trivial script (`return 1+1`), with a code-mode artifact installed in a scratch home and an
env-gated trace at the seam (`WA_CODEMODE_TRACE_OPENS`), opened the component **twice**:

    open A, advance A, open B, advance B, finish B, advance A, finish A

Two DIFFERENT sessions (`2b4795d8…` and `884d2a69…`), so this is not one loop retrying - two loops ran,
interleaved. That reproduces the 23/11 count of two opens per call, and it is measured, not inferred.

WHERE IT COMES FROM. A traceback at the loop entry (`debug.traceback` in `component_run`) shows both
invocations arriving from the same place: `lua/core/codemode.lua:1478`, the `pcall(component_run, ...)` inside
`run_script`, called from `run_script` (`:1363`) which `M.run` calls once (`:1500`). The loop has a single call
site, and so does `run_script`. So the second loop is not the loop and not its parent: the TOOL CALL is
dispatched twice. That is one level above where the 23/11 report stopped looking.

AND ONE SUSPECT IS OUT: `sandbox_host::available()` - what the router asks before routing - hashes the artifact
and does not instantiate, so the availability probe is not the second open.

NOT FIXED, deliberately. Which of the two dispatches is redundant decides what to delete, and that is a
behaviour question about the agent loop (a preview pass? a re-dispatch after a yielded `advance`?), not a
performance one; getting it wrong drops a tool call. The next probe is a traceback at `M.run` and at
tools.lua's
`run`/`codemode` branch - the traces this change adds (`WA_CODEMODE_TRACE_OPENS`) name the caller in one run.

THE BUILD, for whoever runs it: the prepared asset directory is the checkout's
`.git/codemode-assets/pi-1.2.0-quickjs-3.6.2/`, and `node scripts/codemode-build.mjs build <tree>` resolves it
from Git metadata (here `~/.wasm-agent/build/target/wt-idle-<hash>/release/wa`). A plain `cargo build` refuses
without assets; `WA_CODEMODE_ALLOW_EMPTY=1` is for artifacts not meant to run code mode. The component itself
goes into the scratch home with `WA_COMPONENTS_DIR=<scratch>/home/.wasm-agent/components bash
scripts/build-components.sh codemode` - without it the node falls back to the native loop and nothing opens.
## (c) A warm QuickJS instance or snapshot — skipped, with the reason

Skipped deliberately. Code mode runs **model-authored code**, and the surface in front of it is exactly the
one where a kept-warm runtime is unsafe: guest-visible state would survive from one run to the next, and
there is no principal boundary inside the component to stop one session's globals being visible to another.
A warm instance is only safe if the guest is reset between runs, and the reset is the boot. The node already
pools what *is* safe to pool — the core interpreters (`CoreComponentPool`, one SQLite connection and one
`Lua` per slot, no guest code) — and code mode is a different component with a different trust model.

## (d) Precompile at install — where the artifact lives and how it is invalidated

Already true in the tree, and worth stating because the brief assumed it was open: `components::disk_cached`
(`rust/wa-kernel-runtime/src/components.rs`) keeps the compiled `cwasm` at
`~/.wasm-agent/cache/components/<sha256 of the bytes>-<engine compatibility hash>.cwasm`. The key **is** the
content hash plus the engine's own compatibility hash, so:

- a changed component has a different pin and therefore a different file — a stale artifact cannot be used;
- a wasmtime upgrade changes the compatibility hash and therefore the file name;
- `WA_COMPONENT_CACHE=0` disables it, which is what a fully isolated scratch run does.

So the 6.13 s `components::prepare` is paid once per artifact per engine, not once per first call. What it is
*not* is per-node-file: the directory comes from `HOME`, not from `WASM_AGENT_HOME`.

## perf

`perf` is installed here (`/usr/bin/perf`) but cannot open a single event: `kernel.perf_event_paranoid=2`.
The one line that would let a profiler settle the remaining questions (including (b)) is:

    sudo sysctl kernel.perf_event_paranoid=1

I did not run it, and I did not install anything. Everything above was measured from `/proc` (per-thread CPU),
which needs no privileges — and it was enough to name the thread and the tick, which is what (a) asked for.

## What the model reads

Nothing. The change is inside `dofile`; no tool answer, prompt, capability row or Lua API is different. The
before/after script in `component-calls-cheap` was not re-run because the probe base and tip are the same
binary behaviour by construction — the same module text, the same functions, the same answers.

## Factory text for FACTORY.md / HANDOVER.md (proposed, not written)

> **A tick that compiles is a tick that costs.** `dofile` caches the compiled chunk keyed by the module's text,
> so a node pays for a module once per process and again only when the file's bytes change. An idle node's
> placement tick costs 0.43 % of a core instead of 5.07 %. When adding a periodic tick, measure the thread by
> name (`/proc/<pid>/task/*/stat`) before and after: it needs no profiler and it names the offender.
