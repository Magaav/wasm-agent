# Operations: owned external execution

An **operation** is one supervised external execution with an identity, owner,
absolute execution budget, output cursors, cancellation and a terminal outcome.
A **job** is an automation definition, never another name for an operation.
See [JOBS.md](JOBS.md) and ARCHITECTURE.md section 6.

## Contract and implementation

`rust/wa-operation` owns shell process lifetime and output independently of Lua.
`rust/wa-host/src/operations.rs` is the adapter; agent policy remains in Lua.
The existing `bash`/`host.exec` interface waits for an operation, bounded by the
default budget; the `bash` description carries that number and names `operation
start` as the route for work that would outlive it, so a long command is planned
rather than discovered by a kill. The `operation` tool exposes
start/list/status/read/wait/await/cancel for explicit long-lived work.
Native waits use a settlement condition variable. `await` waits in one model tool
call under the operation's existing execution/cleanup budget, maintaining host
heartbeats and returning terminal evidence or an explicit overdue/unknown outcome.
It never launches/replays work or injects a synthetic conversation message. The
independent HTTP route refuses long `await`; bounded `wait` and cancellation remain
available there.
`wait` is bounded to ten seconds; a still-running result is not failure and is
never permission to launch the command again. `start` returns a launch receipt,
not execution success. Default execution budget is 300 seconds; explicit
operations may request 1–86400 seconds. Eight operations may be active per manager.

State: accepted → running → draining → completed / failed / cancelled.
Settled results include monotonic phase timing (`timing.schema_version=1`): exclusive
setup, accepted-record persistence, process spawn, execution, drain/cleanup and
output-sync milliseconds, plus measured/unattributed/total time. `execution_ms`
is child lifetime after spawn until settlement begins; it is not CPU time. The
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
* Normal completion reaps the shell and terminates descendants. A shell exiting
  while background descendants survive is a failure, even if they redirected their
  pipes: cleanup must not masquerade as success. The original process exit code and
  already printed output are preserved.
* Foreground/background is an explicit API choice. To keep a server running, use
  `operation start` and leave the server foreground in that shell (or use `wait`).
  `&`, `nohup`, or closing a pipe is not permission to escape ownership.
  A permanent sentinel/node service must be started by its external installer or
  operator, not backgrounded from an agent-owned shell: its supervisor must live
  outside the runtime it supervises.

## Platform guarantees and limits

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

* `cargo test -p wa-operation --offline`: real children, inherited pipes, both
  streams, deadline, cancellation, output limits, quiet work, parallel inheritance,
  cursor reads, failed launch and restart ambiguity.
* `scripts/test-exec-timeout.lua`: same scenarios through the real host and Lua
  outcome projection, included in `scripts/test.sh`.
* `scripts/test-jobs.cjs`: real sentinel and Chrome event delivery; no paid inference.
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
