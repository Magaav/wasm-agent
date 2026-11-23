# piped-chat-starts-fast

Branch `change/piped-chat-starts-fast`, base `2104a4d8`, worktree
`/home/victor/Work/missions/piped-chat-starts-fast/wt`.

## 1. The row this brief came from was waiting for a line a piped chat never prints

The brief's measurement was "`printf 'hi\n' | wa chat` with stdout on a pipe produced no `memory:` header
within 4 s (twice); the same command in a pty printed it at 329-383 ms". Re-measured on the base:

* A **scripted** run draws no banner at all. `lua/core/chat.lua:261` decides
  `scripted = once or stdin_is_a_terminal() == false`, and the welcome block - the one that carries the
  `memory: <db>` row (`view:welcome`, `lua/core/chat.lua:493`) - sits inside `if not scripted then`
  (`lua/core/chat.lua:483`). That is deliberate and documented there: "A scripted run has neither: its
  stdout is a transcript a program reads, and a banner ... is noise". So a piped chat never prints a
  `memory:` header, at 4 s or at 400 s; the speed-board row timed out on a line the design does not write.
* Measured instead: `printf 'hi\n' | wa chat --once`, release build of the base `2104a4d8`, scratch home,
  first line = the echo `> hi`, **351 ms** (median of five: 331, 363, 351, 368, 329). The pty's 329-383 ms
  banner in the report is the same order of magnitude, so the two paths were never 10x apart.

What the row did find under the wrong premise is real, and it is not 4 s: a piped start read its own
binary before it printed anything (section 2).

## 2. Where a piped start's time goes (base `2104a4d8`, release, scratch home)

Timestamps along the start path, taken with a temporary `host.now()` trace in `lua/core/chat.lua`,
`lua/core/init.lua`, `lua/core/agent.lua` and `lua/core/memory.lua` (loaded through
`WASM_AGENT_LUA_ROOT`, reverted afterwards - no trace is in the branch):

| point | release | debug |
|---|---|---|
| exec -> first statement of `lua/core/init.lua` | ~147 ms | ~320 ms |
| init.lua -> session, settings and view resolved (`M.run`) | ~13 ms | ~32 ms |
| `agentlib.new` -> `memory.presence_begin` -> `memory.process_identity` | **66.5 ms** | **727 ms** |
| that call, of which: `host.runtime_info` reading and hashing the binary | **66.5 ms** | **727 ms** |
| first line out | 235 ms (child clock) | ~1.17 s (child clock) |

`lua/core/memory.lua`'s `process_identity` asked `host.runtime_info` for its `pid` and `boot` tag.
`runtime_info` cannot answer that JSON without also filling `binary_sha256`, and it fills it by
`std::fs::read(current_exe())` and a SHA-256 of the whole file
(`rust/wa-capabilities/src/host.rs`, `runtime_info`): 73.9 MiB / 66 ms for a release build on this node and
861 MB / 730 ms for a debug one. A presence row needs the pid and the boot tag, neither is in that digest,
and the row is written before a chat prints its first line - so every start paid for the whole binary first.

Measured as bytes rather than milliseconds (deterministic, build-independent): the process had read
**74.4 MiB** when its first line came out (median of five, `/proc/<pid>/io` rchar), i.e. the binary.

## 3. The fix (commit `dd2ef0f3`)

`git show --stat dd2ef0f3`: `rust/wa-capabilities/src/host.rs`, `rust/wa-capabilities/src/capabilities.rs`,
`lua/core/memory.lua`, `docs/HOST.md`.

* `host.process_identity()` answers `{process_id, boot_id}` and reads nothing (`host.rs`, commit
  `dd2ef0f3`). The digest moved into `binary_digest()`, still computed once, still in `runtime_info`'s
  answer, still paid by the callers that ask for the bytes (`lua/core/build_status.lua`, `payload.lua`, the
  turn journal).
* The boot tag has ONE source (`process_boot_id()`, commit `dd2ef0f3`): `host.process_identity` and
  `host.runtime_info` answer the same tag in one process, because `lua/core/memory.lua:754`,
  `lua/core/steering.lua:52` and `lua/core/selfloop.lua` compare a presence row's `boot` against it and a
  second mint would make a run not recognise its own row. Verified in a real run block: both calls
  answered `pid=3248483 boot=f2aeb435-f9d9-4dac-a507-b9a99cec51d5`, and `memory.process_identity()`
  matched.
* The lazy digest still answers the bytes' own name: `host.runtime_info()` on the branch reports
  `binary_sha256 = 1624da5f5e67...`, and `scripts/test-capability-inventory.mjs` independently hashes the
  same file to `1624da5f5e6736cda5f2a7afe3d035e2b3fe8304e1fbd53e4db51d2f88329c60` (commit `dd2ef0f3`).
* `lua/core/memory.lua`'s `process_identity` prefers `host.process_identity` and keeps `host.runtime_info`
  as the fallback for a binary that does not know the new call (commit `dd2ef0f3`), so an older installed
  binary behaves exactly as before.
* `docs/HOST.md` gains the capability's row (`process_identity     read-only`); the registry gained exactly
  one entry - `wa capabilities --json` counts 146 on the base and 147 here, and `wa capabilities` differs
  by that one line (measured with both binaries).

Result on the same measurement:

| | base `2104a4d8` | branch |
|---|---|---|
| bytes read before the first line (median of 5, release) | 74.4 MiB | **0.54 MiB** |
| first line, release (median of 5) | 351 ms | **274 ms** |
| first line, debug (median of 5) | not re-measured as a binary | **592 ms** |

## 4. The bound, and the test that holds it (commit `cea738c1`)

`scripts/test-piped-start.mjs` drives the real binary (`WA_BIN`, else PATH, else `~/.local/bin/wa`) with
`hi` on a pipe and kills it the moment its first line arrives - no model turn, no provider, no network. It
asserts two things, because they answer different questions:

1. **the bytes**: what the process had read when its first line came out stays under 48 MiB. This is the
   row that fails on the old code in every build: 74.4 MiB on the base against 0.54 MiB here.
2. **the time**: the median of five runs' first line is under **900 ms**, every single sample under
   2500 ms - with a load guard, exactly as `scripts/test-start-instant.lua` does it: no number is measured
   while the machine is above one load unit per core, and the row then says `SKIP piped-start: ...` with
   that reason instead of passing.

The bound is a promise, not a detector: 66 ms inside a 250 ms start cannot be seen by a wall-clock bound on
an ordinary machine, which is why row 1 carries the discrimination. Stated bound for this branch, this node,
release build: **a piped `wa chat --once` answers its first line in under 300 ms (median 274 ms), well under
Victor's "well under a second"**. `WASM_AGENT_LUA_ROOT` unset, scratch home.

Wired at `scripts/fast.sh:971` (row `piped-start`, right after `cli-scripted`, commit `cea738c1`).
`bash scripts/test-discriminates.sh HEAD~2` answers
`discriminates\tscripts/test-piped-start.mjs\tpiped-start: 1 FAIL` (1 discriminating, 0 blocking).

Isolation: a scratch root outside the operator's `~/.wasm-agent` (refused by name otherwise), a scratch HOME
and ledger, an environment built from an allow-list, and a named `SKIP` (never a pass) on a platform that
cannot answer `/proc/<pid>/io`.

## 5. What I verified, and what I did not

Verified:

* the numbers above, each by a run recorded in this session (base binary built from a separate worktree at
  `2104a4d8`, target `/home/victor/wasm-agent/target/pcsf-base-target`);
* the boot tag agreement between the two host calls, in a real run block;
* `scripts/test-session-isolation.sh` (154 checks), `scripts/test-cli-steering.lua`,
  `scripts/test-durable-steering.lua`, `scripts/test-selfloop.lua` (109 checks), `scripts/test-cli-scripted.mjs`
  (21 checks), `scripts/test-build-identity.lua` (21 checks) - all green with the branch binary;
* the capability inventory's CLI half: `wa capabilities --json` parses, 147 entries against the base's 146.

NOT verified:

* **The operator's own store.** `lua/core/secret_guard.lua` refuses any agent tool a path under
  `~/.wasm-agent` (`secret_path_denied`), so I could not copy or measure against the real 1.35 GB
  `memory.db`. Every number here is a scratch home. A bigger ledger may add its own start cost; I did not
  measure what it adds, and nothing in this change touches it.
* **The capability inventory's sandbox half** (`scripts/test-capability-inventory.mjs`): it needs the
  codemode artifact, and this branch's builds were made with `WA_CODEMODE_ALLOW_EMPTY=1`, so the sandbox
  answers "code mode unavailable" and that row failed with `the sandbox answered capabilities() 1 !== 0`.
  That is the build's configuration, not this diff - the same build on the base has the same hole - but I
  did not prove the sandbox sees the 147th entry.
* **A debug build of the base** as a binary: the 727 ms figure and the ~1.17 s first line are from the
  instrumented start-path trace on the base debug build, not from `test-piped-start.mjs` (the fixed debug
  binary answers 592 ms in the test).

## 6. Disclosures

* At the very start of this session, before I had established the scratch-home rule for measurement, five
  measurement runs of the installed `wa chat --once` (two on a pipe, three through `script -c`) ran with
the operator's own `HOME`. They created sessions in the real ledger and the piped pair ran a real turn
  against the borrowed model. Nothing else in this session wrote to the operator's home; after that point
  every run used `/tmp/scratch-home-m1` or the test's own scratch, and the guard refused path access to
  the real store.
* The `~/.local/bin` install was not touched, nothing was pushed, no node or fleet endpoint was called by
the work or by the test.

## 7. Texts to approve

1. The new capability's description, which is MODEL-VISIBLE (the capability list the codemode sandbox and
   `wa capabilities` hand the model) and operator-visible in `docs/HOST.md`:

```
process_identity     read-only       This process id and the boot tag it was given, without reading the binary to hash it
```

2. The test's own output lines (operator-facing, in the fast path's log):

```
ok   every run answered its first line as the echo of the piped one (["> hi","> hi","> hi","> hi","> hi"])
     bytes read before the first line: 0.54 MB, 0.54 MB, 0.54 MB, 0.54 MB, 0.54 MB (median 0.54 MB)
ok   the start does not read the binary it runs: median 0.54 MB read before the first line, under 48.00 MB
     first line: 267 ms, 273 ms, 274 ms, 299 ms, 303 ms
ok   every run answered within 2500 ms (slowest 303 ms)
ok   a piped chat's first line arrives in under 900 ms (median 274 ms)
piped-start ok
```

and its refusals, which are named rather than a pass:

```
SKIP piped-start: no scratch root outside /home/victor/.wasm-agent
SKIP piped-start: no wa binary (WA_BIN/WA_TEST_BIN/FAST_BIN, PATH, ~/.local/bin)
SKIP piped-start: the machine is at load N on 16 cores (ceiling 16): a timing row cannot tell code from load
SKIP piped-start: this platform does not say what a process has read (/proc/<pid>/io)
FAIL the start does not read the binary it runs: median 74.39 MB read before the first line, under 48.00 MB
FAIL a piped chat's first line arrives in under 900 ms (median N ms)
```

3. The fast path's row name `piped-start` and its comment block at `scripts/fast.sh:963`-`970`.
