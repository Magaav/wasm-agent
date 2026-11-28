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

## (b) The double open on a `run` call - not measured, but the ground is cleared

I did not get a measurement, so I am not claiming a fix. What I did get is the build and one ruled-out cause.

THE SUPPORTED BUILD WORKS HERE, and that was the blocker: the prepared, verified asset directory is the
checkout's `.git/codemode-assets/pi-1.2.0-quickjs-3.6.2/`, and `node scripts/codemode-build.mjs build <tree>`
resolves it from Git metadata and builds a binary that carries code mode (here
`~/.wasm-agent/build/target/wt-idle-<hash>/release/wa`, sha256 `80385dae...`, with the embedded VM checker run).
My first attempts failed because they bypassed that script with a bare `cargo build`, which has no assets and
refuses; `WA_CODEMODE_ALLOW_EMPTY=1` is only for artifacts not meant to run code mode.

ONE CANDIDATE CAUSE IS OUT. `wa_kernel_runtime::sandbox_host::available()` is what the router asks before it
routes a script, and it hashes the artifact and returns - it does not instantiate. So the second open per call
is not the availability probe. The run surface then goes through `dispatch("open"|"advance"|"finish")`
(`sandbox_host.rs`) and the Lua policy around it (`lua/core/agent.lua`, `codemode_policy.lua`).

AND THE LAYERS UNDER IT OPEN ONCE. `lua/core/codemode.lua:973` is the loop's single
`seam({op='open',...})` per script, and `sandbox_host::dispatch` opens once per open op. So the 23/11 count of
two opens per run call comes from neither of those layers opening twice: it comes from the CALLER. That is the
narrowing this report can offer - "who calls the loop twice" - and it is a question a driven turn answers and a
code read cannot.
WHAT COUNTING OPENS STILL NEEDS: a real turn with a provider, because the `run` tool is driven by the agent
loop and a scratch node has no model. The seam reports every open itself (`{"op":"open","elapsed_ms":…}`), so
the count is one hook away once a turn can run - the binary to run it with now exists.
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
