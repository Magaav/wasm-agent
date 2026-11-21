# serve must answer /health whatever its working directory

Mission: `boot-walk`. Branch `change/boot-walk`, base `bfad4f8f`. Commits: `9a5f033c` (the fix),
`8af12988` (the upgrade probe and the `test.sh` wiring), `<report>` (this file).

## What was wrong (measured, not inferred)

`wa serve` registered a RECURSIVE OS watch over its own working directory on the boot path.
`notify`'s recursive registration adds **one inotify watch per directory**, synchronously on the
calling thread, and that call sat between `[serve] core = native` and the listener:

    rust/wa-host/src/main.rs:767   graph::watch_configured()
    rust/wa-capabilities/src/graph.rs:1053  watch_configured -> Scheduler::entry
    rust/wa-capabilities/src/graph.rs       entry -> watcher.watch(&root, RecursiveMode::Recursive)
    rust/wa-host/src/main.rs:436   root defaults to std::env::current_dir()

The listener is only bound later, in `serve::run` (`rust/wa-capabilities/src/serve.rs:1928`), which is
why a hung node's log stopped just before `one run node-thread` and `UI at` and why it held DIRECTORY
fds deep inside the cwd tree - exactly what the orchestrator saw on openclaw.

Measured on this node (avell, x86_64), `scripts/bwprobe.sh`-style probe: inotify lines counted in
`/proc/<pid>/fdinfo/*` at the instant `/health` first answered.

| binary | cwd | dirs | answer | inotify watches |
|---|---|---|---|---|
| bfad4f8f | synthetic tree | 220,201 | 1,494 ms | **220,201** |
| bfad4f8f | `/tmp` | 75,370 | 1,171 ms | 76,761 |
| bfad4f8f | `WA_GRAPH_WATCH=0` | 220,201 | **257 ms** | 0 |
| 7ddbfa98 (base) | synthetic tree | 220,201 | 1,384 ms | **220,201** |
| 7ddbfa98 (base) | `/home/victor` | 713,463 | **27,643 ms** | **517,982** |
| bfad4f8f | `/home/victor` | 713,463 | **5,964 ms** | **517,982** |
| **this branch** | `/home/victor` | 713,463 | **534 ms** | **0** |

## Brief premises that were WRONG

* "**regression in node-bfad4f8fbe59**" - it is not a regression. The base `7ddbfa98` holds the same
  517,982 watches over `/home/victor` and answers in 27.6 s; bfad4f8f 6.0 s (the machine was
  busier). The walk predates both commits. What the brief's A/B saw on openclaw is machine
  noise on top of a defect both builds share.
* "**The Rust diff 7ddbfa98..bfad4f8f touches only release.rs/main.rs (trust-key) and no watcher**" -
  `git diff --name-only 7ddbfa98..bfad4f8f -- rust` is `wa-capabilities/src/serve.rs`,
  `wa-host/src/main.rs`, `wa-host/src/release.rs`: `serve.rs` also changed (font MIME types), and
  no commit in that range touches the watcher, which is why the regression reading could not hold.
* "**200k dirs is enough to fail**" - on THIS node's disk a timing-only assertion does **not**
  discriminate: the base answered 220,201 directories in 1.4-4.9 s, inside a 5 s budget. The
  discriminating assertion is the WATCH COUNT, and the row carries both (see below).

## The fix (`9a5f033c`)

`Scheduler::entry` no longer calls `watcher.watch(root, Recursive)` unbounded. `register_watch`
(`rust/wa-capabilities/src/graph.rs`) first counts the directories a recursive watch would cover,
bounded twice - by `WATCH_DIR_BUDGET` (20,000 directories) and by `WATCH_SCAN_BUDGET` (5 s) - and a
root past either bound is **left unwatched, with a named reason**:

* log line `graph_watch_skipped root=... reason=root_too_large_more_than_20000_directories; edit hints and per-call content admission keep answers exact`
* `graph_status` reports `watch_skipped` beside the existing `watch_registered`/`watch_error`.

A skip and a failure are named apart (`watch_skipped` vs `watch_error`): "I decided not to watch this
tree" and "the platform refused" must not read the same, and neither may read as "watched".

The watcher is a hint, never the source of truth: `graph.rs` opens with "Each component call admits
content first (capture -> compare -> index changes as a new revision), so an answer is never older than
the bytes on disk when the call began; a hint only makes that admission cheap later." An unwatched root
therefore answers **exactly**; it pays the admission per call. That is a performance change on trees
over 20,000 directories, not a correctness one.

`WA_GRAPH_WATCH_DIRS` overrides the budget; `WA_GRAPH_WATCH_DIRS=0` registers no OS watch (verified:
0 watches, 320 ms). Documented in `docs/GRAPH.md` (commit `8af12988`).

The registration stays SYNCHRONOUS on purpose. Making it asynchronous was tried first and reverted:
the parity test `scripts/test-graph-watch.lua` reads `watch_registered` straight after a query and
requires a real OS registration, so an asynchronous answer is a race. Bounded-and-synchronous keeps
that contract and still bounds the boot.

## The guard: `scripts/test-serve-cwd-boot.sh` (commit `9a5f033c`, wired in `8af12988`)

Builds a real 200,000-directory tree, starts `wa serve` **in it**, and asserts five things:

1. it answers `/health` at all;
2. it answers in under 5,000 ms;
3. **it holds no per-directory inotify watch for that tree** (the walk is gone);
4. the node names why that root runs unwatched (`graph_watch_skipped`);
5. the same binary still registers its watch on a SMALL root - so "zero watches" cannot be reached by
   breaking the watcher.

Wired into `scripts/test.sh` right after the concurrency fixture (commit `8af12988`); a skip is
printed by name (`SKIP test-serve-cwd-boot`), never silently a pass.

**It discriminates.** Run against a binary built from `bfad4f8f` in a separate worktree:

    fix  (9a5f033c): 5 checks, 0 failed  - serve cwd boot ok
    base (bfad4f8f): 5 checks, 2 failed
      FAIL boot holds no per-directory inotify watch for the huge cwd (200003 watch descriptors: ...)
      FAIL the node names why that root runs unwatched (no graph_watch_skipped line in the log)

The row is hermetic: its own scratch HOME through `scripts/lib/scratch-home.sh` (it refuses the
operator's store, and on this node it refuses `TMPDIR` because `TMPDIR` is `~/.wasm-agent/tmp`), its own
port, its own tree, no rendezvous, no relay, no mesh, no live fleet. Both nodes are children of the test
and are stopped by PID. The scratch base is chosen for 2 GiB of blocks AND `DIRS+5000` free inodes:
`/tmp` here is a 16 GB tmpfs whose inode table a 200k-directory tree exhausts ("no space left on
device" while almost every byte of it is small) - measured, that failure is named, not blamed on the node.

## The upgrade probe (`8af12988`)

`scripts/upgrade.sh` proved the candidate by starting it and polling `/health` - **from the caller's
cwd**. With the defect above, an operator running the upgrade from a huge directory could fail the
probe and have a good build refused, and the brief was right that a caller's cwd must not decide an
install. The probe now runs the candidate from a fixed cwd:

    ( cd "$INSTALL_DIR" 2>/dev/null || cd "${TMPDIR:-/tmp}" 2>/dev/null || cd / ; exec env ... "$NEW" serve ... ) &

`INSTALL_DIR` is fixed, small and always present (it is where the candidate is going).

**Verified by measurement, not by reading.** A wrapper candidate that records its own cwd and then
execs the real node, run through exactly the edited line from a caller 200 directories deep:

    caller cwd : /home/victor/scratch/bwup.euWDIC/big/d1/.../d200
    recorded   : /home/victor/scratch/bwup.euWDIC/install
    install    : /home/victor/scratch/bwup.euWDIC/install

so the candidate starts in `INSTALL_DIR` and the caller depth no longer reaches it.
`scripts/test-upgrade-idle.sh` still passes (it reaches `upgrade.sh`, though its own row skips the
port proof by hash cache).

**Not covered by an automated test**: no fixture in this branch reaches the port-proof block itself, so
a future edit could reintroduce a caller-relative cwd with every test still green. What IS covered is
the premise - the guard above proves a big cwd no longer delays `/health`. The gap is named here rather
than claimed closed.

## Texts to approve (new or changed operator-facing strings)

1. `graph_watch_skipped root={} reason={}; edit hints and per-call content admission keep answers exact`
   - stderr, once per root whose watch is skipped.
2. `graph_watch_register_failed root={} error={}; content admission remains authoritative`
   - existing text, unchanged wording; it now carries a reason string instead of notify's `Display`.
3. `watch_skipped` - new field in the `graph_status` JSON.
4. `WA_GRAPH_WATCH_DIRS` - new environment override (default 20,000; `0` disables the OS watch).
5. `test-serve-cwd-boot: {} checks, {} failed` / `serve cwd boot ok` / `SKIP test-serve-cwd-boot: ...`
   - test output only.

## Checks run

* `cargo test --release -p wa-capabilities graph`: **23 passed, 0 failed** (includes the scheduler
  backoff/rebuild tests).
* `scripts/test-serve-cwd-boot.sh` with the branch binary: 5 checks, 0 failed.
* The same row with a `bfad4f8f` binary: 2 of 5 fail (named above).
* Probe measurements in the table above, including the 713,463-directory `/home/victor`.

## Not done / unknown

* The full `scripts/test.sh` was NOT run end to end for this branch (it needs code-mode assets that
  are not provisioned on this node: `wa-capabilities/build.rs` refuses a release build without them,
  so the binary here was built with `WA_CODEMODE_ALLOW_EMPTY=1` and this build cannot run code mode).
  The row is wired in; it has been run on its own, and on the base, both directions.
* `scripts/test-graph-watch.lua` could not run here at all - this binary has no graph component
  (`component_not_installed:graph`), a pre-existing limitation of this build, not of the change. The
  synchronous design above exists precisely to keep its contract intact.
* The upgrade probe change has no automated test that reaches the port proof; its effect was
  verified by running the edited line with a cwd-recording wrapper candidate (see its section).
* openclaw itself was not touched: the defect was reproduced and measured locally, on `/home/victor`
  (713,463 directories, the same shape as the reported `/local`).
