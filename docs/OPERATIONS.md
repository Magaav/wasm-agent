# Operations: owned external execution

An **operation** is one supervised external execution with an identity, owner,
absolute execution budget, output cursors, cancellation and a terminal outcome.
A **job** is an automation definition, never another name for an operation.
See [JOBS.md](JOBS.md) and ARCHITECTURE.md section 6.

## Contract and implementation

`rust/wa-operation` owns shell process lifetime and output independently of Lua.
`rust/wa-host/src/operations.rs` is the adapter; agent policy remains in Lua.
The existing `bash`/`host.exec` interface waits for an operation. The `operation`
tool exposes start/list/status/read/wait/cancel for explicit long-lived work.
`wait` is bounded to ten seconds; a still-running result is not failure and is
never permission to launch the command again. `start` returns a launch receipt,
not execution success. Default execution budget is 300 seconds; explicit
operations may request 1–86400 seconds. Eight operations may be active per manager.

State: accepted → running → draining → completed / failed / cancelled.
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
* `scripts/test-operation-recovery.cjs`: a busy isolated listener is recovered
  without waiting for idle, graceful maintenance is deferred, disabling a job
  cancels its running script, and Windows host death kills contained descendants.

The tests prove those boundaries, not universal freedom from hangs or safe
execution of arbitrary privileged commands.
