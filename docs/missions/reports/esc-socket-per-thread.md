# esc-socket-per-thread: Esc shuts down only the run's own sockets

Fable's review of `change/esc-stops-now` (23/11 ~13:00Z), priority 2. Branch `change/esc-socket-per-thread`,
base `7865a08e`. Code and tests: **04e9b720** (this report is the commit that carries it).

## 0. The brief's premise, re-measured

The review is right about the defect and slightly off about its shape:

* at `7865a08e` the slot is ONE PROCESS-WIDE **Vec** (`rust/wa-capabilities/src/subagents.rs:106`,
  `static FOREGROUND_SOCKETS: Mutex<Vec<TcpStream>>`) holding every non-task call's sockets - not one
  slot per call and not one socket; `clear_active_socket()` (`:124`) emptied the whole Vec, and
  `shutdown_foreground_sockets()` (`:114`) shut down every socket in it. Both halves of the review's
  finding hold against that code.
* **"a CLI with a relay poll or parallel remote calls" does not exist in a `wa chat` process.** Measured,
  not argued (below): a chat process has exactly ONE Lua thread that makes `host.http`/`host.http_stream`
  calls, and it never has two of them in flight at once. The CLI's only other concurrency is a supervised
  child (own task slot) and a child *process* (own address space), and `lua/core/idle_reads.lua` says in its
  own header why the idle prefetch cannot ride along in-process. So item 3 of the brief, as a **pty** case,
  cannot be built: see §3.

## 1. What Esc shuts down today (item 1), measured

Instrumented binary (a temporary `socket_trace` line in `register_active_socket`, `clear_active_socket`
and `shutdown_foreground_sockets`, reverted before the commit), driven through the REAL pty fixture
`scripts/test-esc-stops-pty.mjs` (all five scenarios, real tmux pty, real binary). Every line below is a
measurement:

| scenario | registrations (thread) | at Esc: sockets in the slot | what Esc shut down |
|---|---|---|---|
| headers | 1 per call, all `ThreadId(1)` | 1 | 1 socket (the run's) |
| stream  | 1 per call, all `ThreadId(1)`; last call clears twice (1 then 0) | 1 | 1 socket (the run's) |
| bash    | 1 per call, all `ThreadId(1)` | 0 | nothing (no HTTP call in flight) |
| remote  | 1 per call, all `ThreadId(1)` | 1 | 1 socket (the run's) |
| subagent| 1 per call, all `ThreadId(1)`; the child's own call is never in the slot | 0 | nothing |

`ThreadId(1)` is the interpreter (the thread that runs the submitted line); the reader that raises the
interrupt is `ThreadId(2)`. In every scenario the slot holds **at most one** socket, it belongs to the run,
and Esc shuts down exactly that one - so **in the CLI today the defect has no observable effect**: it is
latent there, and reachable where a process really has several non-task callers (`wa serve`: one node thread
per session, plus its control lane at `rust/wa-capabilities/src/serve.rs:384`, whose `/provider`, `/model`
and `/reasoning` probes take `Normal`/`Control` routes on another thread and register in the same slot).
Nothing in `wa serve` raises the CLI interrupt today, which is exactly why a shared slot could survive this
long; the next stop path to use it would have shut down another session's request.

## 2. What changed (item 2): the slot is per thread, the interrupt is per run

`commit 04e9b720`:

* **`register_active_socket`** (`subagents.rs`): a task's call still goes to its task's slot; a call with no
  task goes to **the calling thread's own slot** (`foreground_slot()`, made on first use, registered in
  `FOREGROUND_SLOTS` keyed by `std::thread::ThreadId`).
* **`clear_active_socket`**: a task clears its task slot and returns; a foreground call clears **only its own
  thread's** slot and drops that thread's registry entry. Another thread's in-flight socket is not in reach,
  so one call finishing can no longer unregister the model stream's.
* **`set_foreground_run_thread()`** records the thread that runs the foreground run, called from
  `host.input_start` and from `host.input_take` when it hands back a line (`host.rs`). The reader is a
  different thread, so this record is the only thing that tells the two which sockets are the run's.
* **`shutdown_foreground_sockets()`** shuts down **that thread's slot and nothing else**; with no run thread
  recorded it shuts nothing down (an interrupt nobody's run is waiting on must not become a process-wide
  socket sweep).

No model-facing text, tool description, prompt, body or wire format changed: the whole diff is the two Rust
files above (`git show --stat 04e9b720`: `host.rs` +9, `subagents.rs` +165/-22, of which 96 lines are the
two tests).

## 3. Tests (item 3), and why there is no pty case

**Two tests through the production seam, with real loopback sockets** (`subagents.rs`, `mod tests`):

* `a_finished_call_on_another_thread_keeps_the_runs_socket_registered` - the run registers its socket, a
  second call on another thread registers and **clears** its own, and the interrupt must still wake the run's
  read.
* `an_interrupt_does_not_tear_down_a_second_call_in_flight` - a second call is blocked in its read when the
  interrupt fires: its read must still time out, **and** the run's own read must wake (so the first assertion
  cannot pass by the interrupt doing nothing).

Both were run against the base code in a separate worktree of `7865a08e` (`git worktree add`, never
`git stash`), with the same bodies minus the `set_foreground_run_thread()` call the base has no symbol for:

```
BASE 7865a08e: base_discriminates_a_finished_call_keeps_the_runs_socket ... FAILED
  the run's read must wake on the interrupt, not time out: Err(Os { code: 11, kind: WouldBlock, ... })
BASE 7865a08e: base_discriminates_an_interrupt_does_not_tear_down_a_second_call ... FAILED
  the other call was torn down by the interrupt: Ok(0)
BRANCH 04e9b720: subagents::tests::a_finished_call_on_another_thread_keeps_the_runs_socket_registered ... ok
BRANCH 04e9b720: subagents::tests::an_interrupt_does_not_tear_down_a_second_call_in_flight ... ok
```

Both live in the crate the fast path already runs for this tree (`scripts/fast.sh`, the `rust wa-capabilities`
row: `cargo test --release -p wa-capabilities`, split by `--skip http_transport::streaming_timeout_tests`), so
they need no new row. They take a `FOREGROUND_TEST_LOCK` for their whole body: the slot is per thread but
WHICH thread runs the run is one fact per process, and two of these tests must not judge each other's thread.

**Why there is no pty case for "Esc while a second HTTP call is in flight".** The fixture can only put a
second call in flight if the process under it has a second thread making `host.http` calls; §1 measures that
a `wa chat` process has exactly one. A pty case written today would therefore assert a property that holds on
both binaries (`the other call is NOT torn down` passes on the base too, because nothing in the CLI reaches
the second call), which is exactly the "a test that cannot fail cannot catch anything" shape
`scripts/test-discriminates.sh` blocks. The two halves are pinned where each is real instead:

* "the run's socket IS shut down" - the existing pty row `esc-stops-pty` discriminates for this and is
  strict about it: a plain `host.http` call (the `remote` scenario) has no cancellation poll, so on a build
  where the keypress shuts nothing down that row goes from ~180 ms to "never" (the base `5956ae15`
  measurement in `docs/missions/reports/esc-stops-now.md`);
* "another call is NOT torn down" - the two tests above, where a second caller is real (two threads, two
  live sockets).

If Fable wants the pty case anyway, the honest prerequisite is a second in-process HTTP caller in the CLI;
the brief's two candidates (a relay poll, parallel remote calls) do not exist there today (measured in §1 and
read in `lua/core/idle_reads.lua`, which uses a child PROCESS precisely because `host.http` blocks the whole
CLI).

## 4. Checks run

* `cargo test --release -p wa-capabilities -- a_finished_call_on_another_thread` and
  `-- an_interrupt_does_not_tear_down` - both green (repeated).
* The narrowed fast path for the files touched:
  `flock -o ~/Work/missions/.suite.lock env WA_BIN=<this tree>/release/wa WA_CODEMODE_BUILD_ASSETS=<prepared>
  WA_FAST_ROWS=/tmp/esc-rows.txt bash scripts/fast.sh` (`/tmp/esc-rows.txt`: `test-cli-interrupt.lua`,
  `test-cancel-not-retry.lua`, `test-cli-view.lua`). Result: **115 of 119 checks pass, 0 skipped, 727 s**.
  Green in it: `scripts/test-cli-interrupt.lua`, `scripts/test-cancel-not-retry.lua`,
  `scripts/test-cli-view.lua`, `run-live-pty`, `run-block-pty`, `chat-start-pty`, `diff-card-pty`,
  `fence-card-pty`, `reflow-blocks-pty`, `tui-chrome-pty`, `undo-pty`, `undo-remote-pty`,
  `wheel-lines-pty`, and `esc-stops-pty` in 4 of its 5 scenarios (headers 164 ms, stream 168 ms,
  remote 190 ms, subagent 212 ms).
* The 4 red checks in that run, none of them this branch's (each measured, not assumed):
  * `esc-stops-pty` - the **bash** scenario only: 694 ms in that run. Measured directly afterwards:
    branch binary 570 and 689 ms, **base `7865a08e` binary 661 and 716 ms** (same fixture, same
    scenarios, load 8.25), so the branch is not the cause, and this is the red the orchestrator already
    recorded on main (`HANDOVER.md` 14:01Z: "esc-stops-pty (bash 1041 ms at load 10)").
  * `rust wa-capabilities` - one test, `host::tls_anchor_tests::a_provider_call_refuses_a_private_ca_that_no_bundle_names`,
    and it fails **identically on the base worktree** (`7865a08e`, same test, `host.rs:7861` there /
    `:7870` here). With a scratch HOME the crate is 389 passed / 1 failed (that test); the streaming split
    the row also runs is 5/5 green. (Without a scratch HOME two more `operations::*` tests *refuse to run*
    by their own guard - that is the guard working, not a failure.)
  * `tmp-cleanliness` - its two known failures: `test-esc-stops-pty.mjs` and `test-diff-card-pty.mjs`
    start a tmux server without `scripts/lib/tmux-session.mjs`. Recorded on main at 14:01Z as red-r1 for
    those two fixtures; this branch does not touch either file.
  * `install-guards` - 6 checks, all the in-turn deploy guard: `scripts/upgrade.sh:42` answers
    "refused inside a turn running on the node it would replace" because the row itself runs inside a live
    node turn (`WASM_AGENT_IN_TURN`). Documented as pre-existing and environmental in
    `docs/missions/reports/deploy-never-starved.md` and `docs/missions/reports/compact-not-while-pending.md`.
* A first run of the same rows built the binary without code-mode assets by accident
  (`WA_CODEMODE_ALLOW_EMPTY=1`), which reddened `run-live-pty`, `run-block-pty` and
  `mission-amend-resume` with "code mode unavailable"; with the prepared assets on the build all three pass.
  Nothing in this branch is involved - it is the build's asset provisioning.
* No full suite, no gate, no release, no fleet, no install (FACTORY rule 12): every binary used here is this
  tree's own target dir.

## 5. Premises in the brief that were wrong or stale

* "FOREGROUND_SOCKETS is ONE process-wide slot": it is one process-wide **Vec** (`subagents.rs:106` at
  `7865a08e`), so the review's mechanism is exact but the "one socket" reading is not: several sockets could
  be in it at once (`serve`), and `clear` emptied all of them.
* "a CLI with a relay poll or parallel remote calls": neither exists in a `wa chat` process (§1). The defect
  is real in `wa serve` and latent in the CLI.
* item 3 (a pty case that fails on main) is not constructible against today's CLI, for the reason measured in
  §1 and argued in §3.

## 6. Texts to approve

None: no model-facing or operator-facing string was added or changed (no new tool, no new message, no new
row). The only operator-visible change is that a keypress can no longer end a request it did not stop.

## 7. FACTORY.md / HANDOVER.md text, proposed (not written)

For `FACTORY.md`, after Rule 15 (a worker never edits these files):

> ## Rule 16 (proposed by esc-socket-per-thread, 23/11): a stop is scoped to the run, never to the process
> A cancellation that reaches a blocked socket hands its target with it: the registry is per thread (or per
> run), registering and clearing touch only the caller's own socket, and an interrupt with no recorded run
> shuts NOTHING down. Never a process-wide sweep "to be safe" - it ends work the operator did not stop.
> The test that proves "the other call survives" needs two threads and two real sockets; a pty cannot show
> it, because a chat process has one Lua thread making HTTP calls (measured, esc-socket-per-thread §1).

For `HANDOVER.md`:

> 23/11 esc-socket-per-thread (base 7865a08e, code 04e9b720): the foreground socket slot is per THREAD
> (`FOREGROUND_SLOTS`, keyed by ThreadId) and the interrupt targets exactly the thread recorded by
> `host.input_start`/`host.input_take` (`set_foreground_run_thread`). An interrupt with no recorded run
> thread shuts down nothing. Measured in the chat CLI: the slot never holds more than the run's own socket
> and Esc shuts down exactly one, so the review's "Esc shuts down sockets that aren't the run's" was latent
> in the CLI and real for `wa serve` (node threads + control lane share the process). A pty case for it is
> not constructible; the discriminating tests are two Rust tests with real loopback sockets (both fail on
> 7865a08e). `esc-stops-pty` and `tmp-cleanliness` are RED on main 7865a08e per HANDOVER 14:01Z and are NOT
> this branch's (its rows were run here: §4).
