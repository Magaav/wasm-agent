# Operations: owned external execution

An **operation** is one supervised external execution with an identity, owner,
absolute execution budget, output cursors, cancellation and a terminal outcome.
A **job** is an automation definition, never another name for an operation.
See [JOBS.md](JOBS.md) and ARCHITECTURE.md section 6.

## Windows Git shell environment

An absolute Git Bash/sh command receives that verified installation's bundled
utilities on its child PATH before admission/spawn. This applies to `bash` and
explicit background operations; detached Sentinel installers use the same helper.
No user/login profiles or global PATH edits. Missing required utilities refuse
before effects. Other shells/non-Windows behavior and CREATE_NO_WINDOW containment
remain unchanged. See [SENTINEL.md](SENTINEL.md).

## Contract and implementation

`rust/wa-operation` owns shell process lifetime and output independently of Lua.
`rust/wa-host/src/operations.rs` is the adapter; agent policy remains in Lua.
The existing `bash`/`host.exec` interface waits for the shell command, bounded by
the default budget or a per-call `timeout_seconds` (1-86400, the same range as
`operation start`); the `bash` description carries the default and the knob, so a
long command is planned rather than discovered by a kill. If the shell exits with
descendants remaining, `bash` returns the command result once both output streams
close or have been idle for 100 ms. Output activity resets that idle grace. The
operation remains supervised and retains later output; the command result does not
claim descendant work is complete. Adoption keeps the original command deadline.
Use `operation await` with `wait_for=settled` when task completion depends on the
complete process tree. An explicit `operation start` always has full settlement as
its default wait target.
Native waits use a settlement condition variable. `await` waits in one model tool
call under the operation's existing execution/cleanup budget, maintaining host
heartbeats and returning terminal evidence or an explicit overdue/unknown outcome.
It never launches/replays work or injects a synthetic conversation message. The
independent HTTP route refuses long `await`; bounded `wait` and cancellation remain
available there.
`wait` is bounded to ten seconds; a still-running result is not failure and is
never permission to launch the command again. `await` defaults to command completion
for a foreground-adopted tree and returns `command_completed`, `command_code`, and
`operation_settled=false`; use `wait_for=settled` to await full tree settlement.
`start` returns a launch receipt, not execution success. Default execution budget is 300 seconds; explicit
operations may request 1–86400 seconds. Eight operations may be active per manager.

State: accepted → running → draining → completed / failed / cancelled.
Live snapshots expose `shell_exited`, `process_exit_code`, `waiting_for`
(`command`, `descendants`, or `output_and_cleanup`), and the remaining execution
budget in `remaining_ms`. After shell exit, `output_idle_ms` reports how long both
streams have been idle; output activity resets it. Silence while the command is
running is not proof of completion.
These observations do not infer a test verdict from output. An adopted command
can exit successfully and print ALL PASS while its operation remains unsettled.
The command result and descendant settlement are separate facts; use the former
for the foreground shell outcome and the latter only when the task requires the
remaining processes. Cancel means terminate remaining owned work, never detach it.
Settled results include monotonic phase timing (`timing.schema_version=1`): exclusive
setup, accepted-record persistence, process spawn, execution, drain/cleanup and
output-sync milliseconds, plus measured/unattributed/total time. `execution_ms`
is child lifetime after spawn until command exit or deadline cleanup begins; it is
not CPU time. For an adopted tree, later descendant lifetime is included in
`drain_cleanup_ms`, separately from command execution. The
final atomic state record is explicitly excluded because its duration cannot be
written into itself. For synchronous `bash`, the agent copies this object into
aggregate telemetry and removes it from the model-facing tool result; the audit
reports the remaining wrapper time (final record, host adapter and projection)
separately. Missing/partial timing is reported, never converted to zero.

A record not attached to this runtime is `outcome_unknown`: it may have been
interrupted or may still be active in another process. External effects require
reconciliation, not automatic replay; lack of attachment is not proof of death. Metadata and captured output survive in
`<data>/operations/<operation_id>/`; they are not injected into model context.

* All process output is read with nonblocking OS primitives. No `read_to_end`,
  blocking child wait, reader join or detached output-reader thread exists here.
* Cancellation and the deadline are checked between bounded reads from both
  streams. A noisy stdout cannot starve stderr or cancellation.
* There is one absolute execution budget, including launch and normal draining.
  Launcher exit has at most a **shared 50 ms** drain allowance within that budget.
  Forced cleanup has a separately reported **1000 ms** allowance, not one per pipe.
  This is a soft real-time bound subject to OS scheduling, not a hard-real-time OS.
* stdin is closed. Interactive PTYs are not implemented by this interface.
* The starting directory is decided before the accepted record is written, and a directory that
  no longer exists is substituted rather than inherited. A caller either names one (the `bash`
  tool's `cwd`, or `operation start`'s `cwd`) or names nothing, which means the node's own
  working directory. Either can be gone while the node keeps running - a released session worktree
  is the ordinary case. Unix then does not fail at the command, it fails *before* it: the shell
  prints `shell-init: error retrieving current directory: getcwd: cannot access parent
  directories`, treats every relative path as unresolvable, and a call that would have worked
  returns an empty stdout with no reason. The operation therefore records `cwd_requested` (what the
  caller named, `""` for the node's own), keeps `cwd` as the directory actually used, and, when the
  two differ, adds `cwd_substitution` (`requested`, `used`, `reason`, `detail`) and `cwd_note` - one
  sentence naming both directories. The fallback is the agent home (then the environment's home,
  then `/`); when even that is not a directory, `used` is `null`, the caller's value is kept and the
  spawn reports its own failure instead of a destination that was invented. A directory that exists
  is unchanged: `cwd` is the one that was asked for and no substitution is claimed.
* An attached accepted operation can be observed before its supervisor creates
  stdout/stderr. `read` returns empty `pending_output:true` with an unchanged cursor
  during that pre-setup interval; it is not EOF, completion or a provider failure.
  Missing output for an unknown, running or terminal operation still fails, with
  operation/stream/path in the diagnostic; other I/O errors are never suppressed.
  This fixes the subscription bridge's accepted-output race without another launch,
  provider retry, silent data loss or replay of tools. Original cancelled evidence stays intact.
* Captured output is retained incrementally on disk, with a combined 8 MiB default
  per-operation limit (64 MiB API maximum). Crossing it terminates execution and
  reports `output_limit_exceeded`, never silent truncation. In-memory result tails
  are 24 KiB per stream; byte cursors retrieve the retained prefix/full output.
  Cursor `content` is a UTF-8 text view, not necessarily the original bytes: a
  page can split a character or contain binary output. `text_lossy=true` marks
  replacement characters and supplies `content_base64` for that page's exact
  bytes. Otherwise UTF-8 encoding `content` recovers the bytes. Advance using
  `next_offset`, never the displayed text length. Status/tail views remain lossy
  previews; use cursor pages when exact output matters.
* Tail truncation and incomplete capture are different facts. The former has
  artifact paths; the latter cannot be clean success. Disk/read failures are failures.
* Normal completion reaps the shell and terminates descendants. For an operation
  started deliberately, a shell exiting while background descendants survive is a
  failure, even if they redirected their pipes: cleanup must not masquerade as
  success. The original process exit code and already printed output are preserved.
* A foreground `bash` that leaves live descendants **adopts** them instead: the
  operation stays running under a longer deadline, the caller gets a receipt that
  names it, and the job object still owns the tree - so the process cannot outlive
  this node. Adoption is not abandonment: the same handle answers `read` and
  `cancel`, and a cancelled adopted tree is terminated like any other. What the
  runtime still refuses to do is report a *result* while a process it cannot
  account for is running.
  **The risk this takes, named:** an adopted tree has the lifetime of an `operation`,
  not of the call that started it. A run *cancel* therefore no longer reaches it the
  way it reaches a foreground command - only `operation cancel`, its own deadline, or
  the node's exit does. That is the deliberate trade for letting the idiom the model
  already uses work, and it is why `KILL_ON_JOB_CLOSE` is what makes the trade safe:
  the tree still cannot outlive the node. If a future change removes the job object,
  this becomes a leak and must be revisited.
* On Windows, once the launcher has exited and every remaining job member is
  the MSVC `VCTIP.EXE` telemetry helper under Visual Studio's `VC/Tools/MSVC`
  installation path (plus its system console host), terminate the owned job and settle the build. Compiler
  telemetry must not turn a finished build into an hour-long adopted operation.
  `auxiliary_cleanup` records the helper images and `cleanup` reports
  `compiler_helpers_terminated`. A live shell, compiler, or other background
  process prevents this cleanup. PID membership is checked on opened handles
  to avoid mistaking a recycled PID for an owned descendant.
  Risk: this deliberately ends that resident helper after actual work exits;
  unknown helper images remain supervised under the ordinary adoption deadline.
  Classification uses the full image path, not a binary signature; this is a
  completion policy inside an already-owned job, not a security boundary.
* Foreground/background is an explicit API choice. `operation start` launches
  something you intend to supervise from the beginning; `bash` adopts a tree it
  cannot wait for rather than failing the call. Neither `&` nor `nohup` is
  permission to escape ownership.
  A permanent sentinel/node service must be started by its external installer or
  operator, not backgrounded from an agent-owned shell: its supervisor must live
  outside the runtime it supervises.

## Platform guarantees and limits

On Windows the host and Sentinel select Git's real `usr/bin/bash.exe` before
its `bin/bash.exe` launcher, avoiding redundant launcher respawns. Explicit
operator shell overrides remain honored. This does not ban requested shell tools:
operations still use the same no-window/suspended/job-contained execution path.
No additional process watcher, automatic worker or recurring gate is created.

Windows uses a non-inheritable Job Object with KILL_ON_JOB_CLOSE and a 64-process
limit. The child is created suspended, assigned before it can execute, and only
then resumed. A handle allow-list prevents parallel launches inheriting one
another's pipes. Termination addresses an owned handle, never an image name.

Unix currently uses a dedicated process group and nonblocking pipes. This handles
ordinary descendants but is **not a sandbox**: deliberately escaping the group
(e.g. setsid), or host death, requires stronger cgroup/service containment. Do not
represent process groups as equivalent to Windows Job Objects: a numeric PGID is
not a stable tree handle. Successful cleanup is not re-signalled later from a
destructor after that number could be reused. Privileged shell
code can affect things outside its own process tree on either platform.

Filesystem calls, process creation and a broken OS can themselves stall. The host
wait facade reports an overdue supervisor rather than beating forever; `/health`
reports active operations and overdue state independently. This does not safely
kill arbitrary Rust threads or make an unresponsive kernel recoverable. A control
plane failure still requires the independent sentinel/service manager.

Output files are private task evidence, potentially sensitive. They currently
share the project's explicit-retention policy (no automatic cleanup); per-operation
limits are not a total disk quota. Do not log or publish raw output by default.

## Recovery and visibility

Workspace retirement reads a bounded relevant-operation index instead of every
historical state file. Admissions record actual cwd (including an omitted requested
cwd), canonical effective cwd, process/boot identity and an OS-held lease before
spawn. Existing stores require explicit import after legacy writers quiesce;
uncertain `state.json.before-reconcile-*` originals remain blockers even when a
manual rewrite claims settlement. Reconciliation records separate exact-state,
dead-owner, drain and effect evidence and preserves original outcomes. Legacy
identity uncertainty is never inferred away from age or zero output. The actions,
migration boundary, durable wave lifecycle and real fixture limits are in
[WAVE-CONVERGENCE.md](WAVE-CONVERGENCE.md).

`/health` includes operation id, owner, state, elapsed time, execution and cleanup
budgets, observed output bytes and overdue state, without command/output bodies.
Health observes every worker, not just worker zero. Output activity is not proof
of useful progress; a quiet compiler can be healthy. No model calls are made to
poll an operation.

Master-only `/operations` and `/operation` expose observation/cancellation through
an independent read/control interpreter. The model uses the same operation tool.
The HTTP endpoint cannot start work. The current interpreter pool can still
saturate; the native supervisor nevertheless enforces operation budgets without
waiting for HTTP or Lua. The UI/transport is not the cancellation clock.

Sentinel `restart` is graceful maintenance, left queued while busy. `recover` is
explicit interruption: it acts by listener PID without waiting for idle. Neither
implies safe replay of an interrupted side effect. Upgrades retain their proof,
idle and rollback gates. Never restart the desktop window to recover an operation.

## Model-free phase benchmark

Run `bash scripts/bench-operation-phases.sh`; `WA_OPERATION_BENCH_RUNS` changes the
short-case count (1–50). It launches only packaged fixtures in a scratch operation
home and reports aggregate JSON—no model, live node, user command or command text.

On the Windows development host, seven short-case samples measured:

| fixture | total p50 / p95 | execution p50 / p95 | non-execution observation |
| --- | ---: | ---: | ---: |
| direct no-op executable | 24 / 31 ms | 21 / 27 ms | about 3 ms at p50 |
| Git Bash no-op | 53 / 63 ms | 49 / 60 ms | about 4 ms at p50 |
| direct 10 ms delay | 35 / 40 ms | 32 / 37 ms | about 3 ms at p50 |
| direct 64 KiB output | 25 / 27 ms | 22 / 22 ms | about 3 ms at p50 |
| direct failure | 20 / 20 ms | 16 / 16 ms | about 4 ms at p50 |

Three timeout fixtures settled at 58 ms p50 for a 50 ms deadline; three owned
background-cleanup fixtures settled at 107 ms p50. These are individual local
measurements, not throughput or cross-platform claims. The shell/direct no-op gap
is about 29 ms here; it cannot explain the field audit's 88.2-second bash p95 or
24-minute maximum.

## Enforcement

* `cargo test --manifest-path rust/Cargo.toml -p wa-operation --offline`: real children, inherited pipes, both
  streams, deadline, cancellation, output limits, quiet work, parallel inheritance,
  cursor reads, failed launch and restart ambiguity, and the starting directory (a
  deleted one is substituted and stated; one that exists is untouched).
* `scripts/test-exec-timeout.lua`: same scenarios through the real host and Lua
  outcome projection, included in `scripts/test.sh`.
* `scripts/test-start-directory.lua`: a deleted starting directory and an existing one
  through the real host, the Lua-projected result, and `operation start`/`await`; the
  marker it reads back only resolves from the directory the shell actually started in.
* `scripts/test-jobs.cjs`: real sentinel and Chrome event delivery; no paid inference.
* `scripts/test-subagent-return-hook.cjs`: the `onSubagentReturn` job through a real sentinel - every
  child state, both deploy verdicts, the three unmeasurable cases, the uncommitted half, the dedupe key
  pinned across a re-put, the cursor converging through the store's receipt (including when the
  measurement moved after the intent), the ledger's bound, `prepare` refused at `job put`, the supersede
  marker written with the enable rather than on a tick, four manifest mutations and six installer
  mutations of the shipped-set guard, and no provider call to fire it; real git checkouts, no model.
* `scripts/check-deploy-shipped.mjs`: the shipped set the hook's verdict is read from, re-derived from
  `scripts/deploy.sh` and `scripts/upgrade.sh` (every copy-like line, in every spelling, plus what
  `scripts/ship-wave.mjs` writes); it fails when an installer copies a path `scripts/deploy-shipped.json`
  does not cover, when a copy names a path neither in the tree nor built by that installer, and when the
  derivation stops seeing a copy form it used to see. Registered as the `deployShipped` proof with a floor
  of its own 76 checks.
* `scripts/test-operation-control.cjs`: a real tool holds the run worker while
  another interpreter lists/reads/cancels it; the run then continues (local mock
  provider, zero paid inference).
* `scripts/bench-operation-phases.sh`: model-free phase distributions for direct,
  shell, output, failure, timeout and descendant-cleanup fixtures.
* `scripts/test-operation-recovery.cjs`: a busy isolated listener is recovered
  without waiting for idle, graceful maintenance is deferred, disabling a job
  cancels its running script, and Windows host death kills contained descendants.

The tests prove those boundaries, not universal freedom from hangs or safe
execution of arbitrary privileged commands.

## Opt-in provider retry policy

`WASM_AGENT_PROVIDER_RETRIES=0` is the default for the new exponential-backoff
loop; a positive integer (capped at eight) opts in. Risk: a lost inference response
may already have been billed or partially streamed. Known returned content,
commentary, reasoning or tool calls prohibit retry. These are inference retries,
never permission to replay a dispatched tool, credential refresh or unknown effect.
The existing separately bounded response-header-timeout policy is unchanged.
The Pi subscription bridge has its own visible reconnect cycles, default10 retries
via `WASM_AGENT_SUBSCRIPTION_TRANSPORT_RETRIES` (0 disables). It requires an observed
transient cause before model output, preserves one operation deadline, records
all attempts and never multiplies through this generic retry loop. After its60s
cycle it waits180s before another cycle, only while the original deadline permits.
See [OPENAI-SUB.md](OPENAI-SUB.md#stream-diagnostics-and-visible-reconnect-cycles).

## Supply chain

- Builds use `--locked`, so a build can never resolve different crates than `Cargo.lock` names.
- `WASM_AGENT_UPDATE_REQUIRE_SIGNED=1` makes `/update` refuse to fast-forward the runtime tree unless
  `git verify-commit origin/main` passes (configure `gpg.ssh.allowedSignersFile` or a GPG keyring with the
  maintainers' keys, and sign merges to main). Off by default because the history is not signed yet;
  turn it on once it is, since the node runs whatever it builds.
- `scripts/install.sh`/`install.ps1` are fetched from a moving `main`; pin a tag and its checksum when
  handing them to anyone else.

