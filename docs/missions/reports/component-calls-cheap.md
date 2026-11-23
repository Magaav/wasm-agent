# component-calls-cheap: a component call costs the work, not the setup

branch `change/component-calls-cheap`, base `4b314af5` (main at the time of writing: `7865a08e`).
Measured on avell, 16 cores, 23/11. This round is **measurement**, and its result is a verdict on the
five optimisations: two of them are answered by numbers and skipped, one is already true, one could not
be measured here, and one has not started. Nothing in the call path has been changed yet: `git status`
is clean and `git log` on this branch is the base commit plus this report.

## Verdict up front

**Component setup is not where the CPU goes.** On every scenario measured, the host-side setup of a
component call - deserialize/cached-compile, `Linker` + `add_to_linker`, `instantiate` - is
**0.4 to 0.7 ms per call**, i.e. **0.1 % - 0.8 % of the CPU** of the turn or the idle node that
performs those calls. The five optimisations were expected to move a 17 %-of-a-core TUI process; a
0.4 ms-per-call setup cannot be that.

What the measurement did find, and where the CPU actually goes:

1. **A code-mode `run` tool call opens the code-mode component twice** (40 opens for 20 calls, 2 for
   1 call - measured, cause not yet located), and **each open costs 15-21 ms, of which 97 % is the
   guest's own `open()`** (booting the QuickJS runtime inside the component). That is ~44 ms of
   component work per tool call, ~0.88 s of a 7 s turn.
2. **An idle node burns 7.6 %-7.8 % of a core** (TUI and `wa serve` alike, warm component cache), and
   the busy samples are **Lua source being re-parsed and re-compiled** (69 % of the busy samples),
   plus **sha256 hashing** (20 %). **Drawing is not the big share** - it does not appear in the busy
   samples of the idle node at all (the turn itself was not symbol-sampled); the idle main thread is 48 % blocked on the pty read and 35 % on a condvar.
3. **Compiling a large component is a one-time first-call cost, not a start cost**: a cold
   component-cache `wa serve` spends **6.13 s** in one `components::prepare` (and 11.4 s of CPU over
   its first idle minute); with the cache warm the same call is **0.002 s** and the idle minute is
   4.7 s of CPU. `wa` itself starts with no component loaded (7 ms CPU, 16 MB RSS).

## Method, and what it cannot see (rule 9, rule 1)

- **No perf on this machine**: `perf` is not installed, there is no non-interactive sudo, and
  `/proc/sys/kernel/yama/ptrace_scope` is 1, so a sampler cannot attach to a sibling process. The two
  samplers used instead:
  - **exact CPU**: `/proc/<pid>/task/<tid>/stat` sampled every 100 ms plus `wait4` rusage
    (`/tmp/cc-calls/measure.py`), which gives per-thread CPU seconds and the process total;
  - **symbols**: gdb launches the inferior (so it is an ancestor and may attach) and interrupts it on
    a timer (`/tmp/cc-calls/sample.gdb`). **Its limit matters**: frames inside wasm JIT code have no
    symbol and gdb's thread enumeration is incomplete while a thread runs JIT code, so the symbol
    shares below are used only for the *non-wasm* part, and only as shares of the main thread's busy
    samples (n = 130 of 1406 in the idle TUI run).
- **Phases** come from a temporary `Instant` instrumentation patch in the three call paths
  (`selfloop_host::run_once`, `codemode_seam::open/finish`, `components::run`), printed as
  `phase <name>=<us>` when `WA_PHASE_PROFILE` is set. **The patch is reverted** - it is not part of
  this branch and no committed code changes.
- **Scratch node only**: its own `HOME` (`/tmp/cc-calls/home`), its own `WASM_AGENT_HOME`, every
  inherited `WASM_AGENT_*` dropped first. Components are copies of the node's own install
  (`~/.wasm-agent/components`, pins equal to `components.lock`: all 11 sha256 match). The model is a
  loopback stub; no fleet call, no operator home write.
- **Load**: main-health, installations and other missions were running throughout (load 6.9-16.2 on
  16 cores). Wall times are therefore pessimistic; CPU seconds are much less sensitive but not immune.
  Rows carry the load they were taken at.
- **Not measured, and not claimed**: the size distribution of what crosses the boundary (item 4) - no
  ledger of boundary bytes was collected in this round; the cancel latency of item 5; the 17 %-of-a-core
  the brief cites for a *live* TUI session - the idle TUI measured here is 7.6 %.

## The table (item 0)

Per-call setup, `wa` idle and `wa` in a turn. "setup" = everything the host does before the guest runs
(compile/cache lookup, `Linker::new`, `add_to_linker`, `Store`, `instantiate`).

| scenario (load) | wall | CPU | % of a core | component setup | the component's own work | drawing | everything else |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `wa features` (start, load 8) | 0.10 s | 0.007 s | - | 0 (`RSS 16 MB`, no component loaded) | 0 | - | process start itself |
| idle TUI, 60 s (load 6.9) | 60.0 s | **4.56 s** | **7.6 %** | 0.012 s (29 selfloop calls x 0.41 ms) = 0.3 % | 0.021 s (29 x 0.70 ms) = 0.5 % | not visible in the busy samples | 4.5 s: Lua re-parse/re-compile ~69 % of busy samples, sha256 ~20 %, sqlite prepare + TLS the rest |
| TUI, 20-`run` turn (load not captured) | 10.9 s window (UI reports 9.6 s; 3 s idle before the prompt, 0.5 s grace) | 8.56 s incl. that idle | - | same path as the headless row (the 40 opens were counted there, not in this window) | same path as the headless row | **not measured** - symbol sampling was done on the idle node only | Lua core + prompt rebuild + the headless share below |
| headless `wa chat --once`, same 20-`run` turn (load 16.2) | 5.7 s (a second, unprofiled run under load 16: 7.8 s) | 5.49 s (second run: 7.60 s) | - | 0.016 s = 0.2 % (40 x 0.40 ms, measured) | 0.88 s = 11 % (40 guest `open`, measured; 1.8 s in the second run) | - | Lua core, tool dispatch, prompt rebuild |
| `wa serve` idle 60 s, **warm** component cache (load 8) | 60.2 s | **4.66 s** | **7.8 %** | 0.005 s (5 `components::run`: prepare 16 µs + link 193 µs + instantiate 146 µs median) | 0.026 s selfloop | - | `wa` 2.32 s, `wa-placement` 1.66 s |
| `wa serve` idle 60 s, **cold** component cache (load 8) | 60.1 s | **11.44 s** | **19 %** | **6.13 s in one `components::prepare`** (first call compiles a large component) + 0.32 s selfloop prepare | 0.024 s selfloop | - | `wa-graph-schedu` 6.26 s, `wa` 2.62 s, RSS 766 MB |

### One code-mode call, opened (n = 40, 20-`run` turn)

| phase (host, µs) | median | max | share of the call |
| --- | --- | --- | --- |
| artifact read + sha256 | 261 | 786 | 1.2 % |
| `WasiCtx` + `Store` + `Linker::new` + 2 x `add_to_linker` | 216 | 419 | 1.0 % |
| `Component::instantiate` | 186 | 379 | 0.8 % |
| **guest `open`** (QuickJS runtime/context inside the component) | **20 808** | 31 218 | **95 %** |
| `finish` (close the script) | 414 | 818 | 1.9 % |

```
phase                               calls  total_ms  median_us    max_us   share
codemode.open_guest                    40     877.6      20808     31218   48.6%
codemode.instantiate_and_open          40     877.1      20792     31206   48.6%
codemode.finish                        40      17.8        414       818    1.0%
codemode.artifact_and_compile          40      11.4        261       786    0.6%
codemode.store_and_link                40       9.3        216       419    0.5%
codemode.instantiate                   40       7.8        186       379    0.4%
selfloop.invoke                         2       1.6        796       931    0.1%
selfloop.link_instantiate               2       1.0        516       797    0.1%
selfloop.prepare                        2       0.4        198       356    0.0%
```

## The five items, by the numbers (rule 6: under 5 % is reported, not built)

### 1. LINK ONCE (one Linker + one InstancePre per component per process) - **skip, 0.1 %**

Re-measured premise: `InstancePre`/`instantiate_pre` is still absent from the tree (0 files); a
`Linker` is built per call at nine sites, six of them in a per-call path:
`components.rs:489`, `hooks_host.rs:194`, `memory_host.rs:412`, `mesh_host.rs:239`,
`selfloop_host.rs:350`, `codemode_seam.rs:650` (`quickjs.rs:106`, `service_components.rs:506`,
`core_component.rs:1101/1502` are the others). The premise is true; the cost is not there:
`Linker::new` + `add_to_linker` is **216 µs median** and `instantiate` **186 µs median** per call.
A whole 20-`run` turn pays 40 x 0.40 ms = **16 ms**, 0.2 % of the turn's CPU. An idle TUI pays
**12 ms per minute** (29 calls). Under 5 % by two orders of magnitude: not built.

### 2. WARM INSTANCES - **skip, 0.5 % (and the guest state does not allow it)**

What a warm instance would remove is the `instantiate` (186 µs) - the same 0.2 % as item 1 - because
the expensive half of a code-mode call is inside the guest's own `open()` (20.8 ms), which an
`InstancePre` does not touch. Instance reuse is also refused by the components themselves: the
code-mode seam keeps one live script per session (`LIVE`, thread-local, one entry per script and
dropped on a trap - `codemode_seam.rs` `with_live`), the selfloop/hooks/memory/mesh hosts keep one
store per call and drop it so a guest transaction or sandbox cannot survive the call. Reusing them
across sessions is a **component behaviour change**, which this brief forbids (item 7). Not built.

### 3. LOAD ON FIRST USE - **already true; measured, nothing to change**

`wa` starts with no component loaded: `wa features` = 0.10 s wall, **7 ms CPU, 16 MB RSS**, and its
first command touches no component. Components load on first use and are deserialised from the
`.cwasm` cache (item 3's premise holds - the caches exist). The one number worth knowing is the
**cold** cache: the first `components::prepare` in a fresh `~/.wasm-agent/cache/components` costs
**6.13 s of compile** for a large component (graph-sized), i.e. the first caller pays it and every
later caller pays 16 µs. That is "load on first use" working as designed, not a defect; `graph` is
excluded from this brief anyway (`graph-one-store-per-root`). Nothing built.

### 4. LARGE BODIES - **not measured in this round**

No boundary-size ledger was collected, so no claim is made and nothing is built. What is known from
the code: the seam copies the catalogue and builtins as JSON on every `open` (`codemode.lua:780-796`
builds `entries`/`builtins` with a `host.sha256` per tool schema each time), and the guest-to-host
bridge copies `Vec<u8>` payloads both ways. The cost of that copy is inside the 20.8 ms measured
`open`, so item 4's saving, if any, is a fraction of it.

### 5. CANCEL INSIDE A COMPONENT - **not started**

The epoch deadline is armed on every per-call store (`store.set_epoch_deadline` in
`components.rs:483`, `selfloop_host.rs:343`, `codemode_seam.rs:648`), and the tick practice is 10 ms
(`TICK`), so a sub-300 ms cancel is structurally plausible - but this brief says to start it only on a
main that has `esc-stops-now`, and this branch does not carry that work. No number is claimed.

## Open lead (worth its own item next round)

**Two code-mode sessions per tool call, with near-identical scripts.** Measured with a temporary
`open session=... owner=... codelen=... code=...` print (reverted, not committed):

```
open session=13dc274f-... owner=4c0ef016... codelen=20232 code=var __h=(function(G){ var P=Promise; ...
open session=21a97cc0-... owner=4c0ef016... codelen=20215 code=var __h=(function(G){ var P=Promise; ...
```

Two different sessions, the same owner, the same 20 KB harness-prelude script differing by **17 bytes**,
each paying the full 15-21 ms guest `open`. The only `seam({op='open',...})` call site is
`lua/core/codemode.lua:796` and the only caller of `codemode.run` is `lua/core/tools.lua:1941`, so the
second session comes from a path this round did not trace to its line. If the second session is
avoidable, it removes **~20 ms per tool call** - about half of the 11 % the guest `open` costs a
tool-heavy turn - without changing any component's behaviour, which makes it worth more than all five
approved items together. Whether the second session also *executes* the script's effects is **not
established**: the probe for it (`tools.bash` inside code mode) did not run in this scratch node.

## Where the CPU actually goes, in one line each

- idle TUI / idle serve (warm): **~7.7 % of a core**, of which component calls are **0.8 %**; the rest
  is the Lua core re-parsing and re-compiling source every poll (69 % of busy samples) and sha256
  (20 %).
- a 20-`run` turn: **5.5-8.3 s of CPU**, of which host setup **0.2 %** and code-mode guest boot
  **11-24 %**.
- a cold component cache: **+6.1 s** once, for one compile.

## Proposed FACTORY.md / HANDOVER.md text (proposed, not written)

> **A component call costs the work, not the setup (measured 23/11).** Before optimising a component
> call path, remember the numbers: host-side setup (`Linker`, `add_to_linker`, `instantiate`, cached
> compile) is **0.4-0.7 ms per call**, 0.1 %-0.8 % of the CPU of a turn or an idle node. What costs
> is what the guest does after it is instantiated (code mode: 20.8 ms of QuickJS boot per `open`) and
> what the interpreter re-does per poll (Lua re-compilation, ~69 % of an idle node's busy samples).
> Measure with `/proc` per-thread CPU and `Wait4` rusage first; `perf` is not available on avell
> (`ptrace_scope=1`, no sudo), so a gdb-launched sampler is the symbol tool and it cannot see JIT frames
> or complete thread lists. A `InstancePre`/warm-instance refactor of the five per-call seams buys
> under 1 % and should not be undertaken for speed.

## Texts to approve (nothing new is committed by this round)

None: this round adds a report and no code, no env var, no message the operator or the model can read.

## Rule checks

- Rule 9: premises re-measured - `InstancePre` still 0 files (**true**), `wasmtime` 50.0.1 (**true**),
  per-call `Linker` in `core_component.rs`/`codemode_seam.rs` (**true, and in four more seams**),
  "component setup is where the CPU goes" (**false**), "the TUI burns ~17 % of a core idle"
  (**not reproduced: 7.6 % on a scratch node**).
- Rule 11: committed as its own commit.
- Rule 2/13: every measurement ran in a scratch HOME with the node's components copied in; nothing
  touched `~/.wasm-agent`, the fleet, or `graph.db.malformed-*`.
- No test was added or changed, so rule 16 (a test must fail on the base) does not apply to this round.
