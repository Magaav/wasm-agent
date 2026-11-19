# node-ops — node safety and build/test plumbing (19/11, round 2)

Branch `change/node-ops`, base `e4e40405` (origin/main, rebased onto it first). **Never pushed.**
Built and tested on avell only (16 cores, `CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-node-ops`).
No `git stash` was used in this round: the base was measured in a separate worktree
(`/home/victor/Work/missions/node-ops/base-wt`, detached at `e4e40405`).

Every claim below names the commit that implements it. `git show <sha>` is the citation.

## Items, commits, tests, wiring

| item | commit | test | wired into |
|---|---|---|---|
| 1 the watchdog execs a Lua row | `f56a5ff3` | `scripts/test-fast-watchdog.sh` | `fast.sh` check row, `test.sh` |
| 2+3 a restore refuses a held store, swaps by rename, and the test reads the restored path | `2973af2c` | `scripts/test-backup-restore.{sh,lua}` | `fast.sh` check row, `test.sh` |
| 4 a real-home guard compares the user home | `7c7fe1b2` | `scripts/test-scratch-home.sh` | `fast.sh` check row, `test.sh` |
| 5 a rollback finds the unit that really serves and restarts it | `104312a2` | `scripts/test-rollback-verify.sh` | `fast.sh` check row, `test.sh` |
| 6 every audited build-env key is applied, a missing one refused by name | `55fcbcec` | `scripts/test-build-env.sh` | `fast.sh` check row, `test.sh` |
| 7 a dirty build at the same commit is `edited`, never `fresh` | `48ae2391` | `scripts/test-build-status.sh` | `fast.sh` check row, `test.sh` |
| 8a the row-at-sha script a header named, 77 at the base is `new_failure` | `a37385a2` | `scripts/test-row-at-sha.sh` | `fast.sh` check row, `test.sh` |
| 8 `wa test --at <sha> <row>` as a supervised verb | `249a7f15` | `scripts/test-row-at-sha.sh` | `fast.sh` check row, `test.sh` |
| 10a peers probed at once, through supervised children | `a1109623` | `scripts/test-nodes-probe-parallel.sh` | `fast.sh` check row, `test.sh` |
| 10b the periodic backup runs off the sync tick, one manifest | `ff9d10ba` | `scripts/test-backup-restore.sh` | `fast.sh` check row, `test.sh` |
| 10c a green row that printed SKIP is not a pass | `73ebf9b2` | `scripts/test-fast-skip-count.sh` | `fast.sh` check row, `test.sh` |
| 10d `wa build-env` quotes like a shell and reads the user home | `0266a557` | `scripts/test-build-env.sh` | `fast.sh` check row, `test.sh` |

All TEN suites run together on this branch (measured 19/11 02:33, one supervised operation, every line is that row's own verdict):

```
test-fast-watchdog.sh         ok
test-backup-restore.sh        ok (7 refusals named, a held store refused with its pid, the stale journal removed,
                                 one manifest per snapshot and due() answering without SQLite)
test-scratch-home.sh          ok (11 checks)
test-rollback-verify.sh       ok
test-build-env.sh             ok (every audited key APPLIED, the hostile home passed through)
test-build-status.sh          ok
test-row-at-sha.sh            ok (and the wa test verb run for real)
test-fast-skip-count.sh       ok (the shipped check() read out of fast.sh)
test-nodes-probe-parallel.sh  ok (3 children started before the first await)
test-nodes-capabilities.sh    ok
```

## Item 1 — a Lua row is exec-ed by the watchdog, not by `env`

**Measured before (`git show f56a5ff3^:scripts/fast.sh`):**
```
wa_fast_watchdog "\${WA_FAST_ROW_SECONDS:-120}" "$base" -- "$FAST_BIN" --db "$2/t.db"
```
`wa_fast_watchdog` is a bash FUNCTION, and `env` cannot exec a function: every Lua row exited 127.

**Fix (`f56a5ff3`):** `wa_fast_watchdog N "$base" -- env ... "$FAST_BIN" --db ...` — the watchdo\
g runs the
row itself and `env` only sets the allow-list-cleared environment. `scripts/test-fast-watchdog.sh` now
RUNS a row through that path and asserts the row's real exit code and its output; it no longer greps the
script text.

**After:** `test-fast-watchdog: ok (hung row named and its group killed, exits passed through, refusals
named, and a row really runs through the runner exec path)`

## Item 2+3 — a restore refuses a held store, swaps atomically, and the test reads the restored path

**Measured before (`2973af2c^:lua/core/backup.lua`):** the restore moved the live file aside and copied
over it with no check that a `wa serve` (or anything else) held the store, no atomic rename, and no
removal of the old `-wal`/`-shm`. A stale journal then described pages that belonged to the old file.

**Fix (`2973af2c`):**
- A holder check on POSIX reads `/proc`: a process with the store, its `-wal` or its `-shm` open is a
  holder. The restore then refuses `restore_store_held`, naming each holder's pid and argv, and prints
  the ONE command that stops it (`systemctl --user stop <unit>`, from the unit whose MainPID serves).
- The swap writes a temp file beside the store and `rename`s it into place; each move's result is
  checked and a failed move is reported, never printed as done.
- The old `-wal`/`-shm` are removed with the old DB.
- `previous kept at` is printed only when the aside file really exists.

**Item 3:** `scripts/test-backup-restore.lua` now asserts, at the STORE's own path (not the snapshot
copy), that the restored file's sha256 equals the snapshot's and that a FRESH `sqlite3` process reads the
data back. It no longer attaches the snapshot copy and calls that a restore.

**After:** `backup restore ok: manifest 3 store(s), restore put them back, 7 refusals named, a held store
refused with its pid, the stale journal removed, nothing written by any refusal`

**Honest limit:** the live connection cannot be made to read the swapped bytes — SQLite keeps its own
pages — so the restore answers `reopen_required` and the CLI prints that the node must restart. The test
proves the FILE, with a process that shares nothing with the node.

## Item 4 — a real-home guard compares the user home, not the store

**Measured before:** `WASM_AGENT_HOME` is the USER home (`rust/wa-host-support/src/paths.rs:12` makes it
override `HOME`; the store hangs off it as `.wasm-agent`). The tests compared their scratch home against
`$HOME/.wasm-agent` — the wrong side — so `WASM_AGENT_HOME=$HOME` passed the guard while the node wrote
straight into the operator's store. `scripts/test-fast-watchdog.sh` also set `WASM_AGENT_HOME` to a
store path, inconsistent with the rule.

**Fix (`7c7fe1b2`):** one shared rule, `scripts/lib/scratch-home.sh`, applied by every `test-*.sh` that
writes or probes state. It refuses (a) an empty path, (b) the real `$HOME`, (c) the real
`$HOME/.wasm-agent` and anything inside it, (d) anything that CONTAINS the real store; and it accepts a
scratch home outside all four. An unresolvable real home is a REFUSAL, not a pass.

**After:** `test-scratch-home: ok (11 checks: the operator home, its store, anything inside or above it
and a relative path are refused; a scratch home is accepted, and a scratch root is never inside the
store)`

## Item 5 — a rollback finds the unit that really serves, restarts it, and keeps the Lua tree

**Measured before (`104312a2^:scripts/rollback-node.sh`):** the last step was `systemctl start` and the
last line was `rollback ok` whatever the start did — a node running `wa-serve.service` was never the
question, and a sentinel node's serving child was invisible.

**Fix (`104312a2`):** `scripts/lib/rollback-verify.sh` classifies the process by reading `/proc`:
`serves` (`wa ... serve`) or `supervises` (`wa-sentinel` with a serving child). It compares
`/proc/<pid>/exe` of the process that SERVES with the restored binary, **restarts** (never `start`) the
unit that really serves, moves the matching `lua-core` tree with the binary and keeps the replaced tree
aside (it is not deleted), and prints `rollback ok` only when the binary AND the Lua tree really match.
Unknown is never ok: the caller refuses its success claim on it.

**After:** `test-rollback-verify: ok (a live pid is identified by inode, mismatch and unknown are never
ok, the Lua tree moves with the binary, the replaced tree is kept aside, a tree that cannot name itself
is refused, and the restart path is exercised with a fake serve and a fake supervisor)`

## Item 6 — every audited build-env key is exported and applied

**Measured before (`55fcbcec^:scripts/lib/build-requirements.sh`):** `wa_build_env_audit` read every key
in the record and refused an unread one, but `wa_build_env` exported only `PATH` — a node set
`WA_BUILD_ZIG`, `WASI_SDK_PATH`, `WA_BUILD_CARGO_TARGET` and no build ever saw them.

**Fix (`55fcbcec`):** `wa_build_env` exports/apply every key the audit reads; a missing entry is refused
by `wa_build_env_refuse` with the one-line fix (`Fix: set WA_BUILD_ZIG=...`); and `wa land`,
`scripts/mission.sh` and `scripts/deploy.sh` read the same record through the same functions.

**After:** `test-build-env: ok (absent is not a refusal, an unread key is named with its remedy and stops
fast.sh, allowed keys reach PATH, the record is data and never sourced, every audited key is APPLIED, and
a missing entry is refused by name with its fix)`

## Item 7 — a dirty build at the same commit is `edited`, never `fresh`

**Measured before (`48ae2391^:lua/core/build_status.lua`):** the relation was decided from the commit
alone, so a binary built from a dirty tree at HEAD reported `fresh`.

**Fix (`48ae2391`):** `build_status` reads `built_dirty` and `build_source_tree`. A binary that records
itself as built from a dirty tree at this commit is `edited`; a binary whose stamped source tree differs
is `edited` too. `fresh` now requires the same commit AND clean AND the same tree.

**After:** `build status ok: relation stale with its reason, the tool agrees, and the runner clears
WASM_AGENT_* by allow-list` (the new cases are asserted in `scripts/test-build-status.lua`:
`built_dirty = 'true'` and `built_dirty = true` both answer `edited`).

## Item 8 — `wa test --at <sha> <row>` is a node verb

**Measured before:** the comparison existed only as a shell script; `wa test` was not a command, and
`scripts/lib/row-at-sha.sh`'s header named `scripts/row-at-sha.sh`, which did not exist (`a37385a2` adds
it). The classifier also answered `pre_existing` for base 77 / change 1 — a base that SKIPPED never ran
the row, so the failure is new.

**Fix:** `a37385a2` adds the script the header named, fixes the 77 classification, runs each side under
the watchdog with the `WASM_AGENT_*`/`WA_MESH*` allow-list cleared, and keeps a sourced caller's EXIT
trap. `249a7f15` adds the verb in `lua/core/init.lua`, running the whole comparison through
`host.exec` as ONE supervised operation (a hung row has its group killed and named).

`249a7f15` also fixed a leak its own test found: `restore_caller_trap` removed the cleanup trap without
running it, so every completed comparison left its base worktree behind. `finish_row_at_sha` now runs the
cleanup first, then restores the caller's trap.

**After:** `test-row-at-sha: ok (four classes and the skip convention, a real comparison with no worktree
left behind, every refusal named, and the wa test verb run for real)` — the verb is run for real, prints
`class=still_passing`, `base_code=0`, `change_code=0`, answers `--json`, and every refusal
(`row_at_sha_commit_required`, `row_at_sha_row_required`, `row_at_sha_unknown_option`,
`row_at_sha_row_absent_at_base`) is exercised with exit 2.

**Honest limit:** both sides run THIS node's `wa` binary, with `WASM_AGENT_LUA_ROOT` pointing at the
tree under test. A row that needs the BINARY built at the base commit is not covered, and the answer says
`binary_not_rebuilt` rather than claiming the base was tested.

## Item 10 (LOW) — the four plumbing items

### 10a — peers are probed AT ONCE, not one deadline after another (`a1109623`)

**Measured before:** `lua/core/nodes.lua` `M.list` asked each peer's capabilities in a serial loop
(`M.peer_capabilities(peer)` inside the peer loop), so a list of four unreachable peers cost four deadlines
before anything drew. `host.http` is one blocking call, so a coroutine cannot fix it.

**Fix:** one supervised child per peer (`wa nodes probe <node_id>`, added in `lua/core/init.lua` and
`nodes.probe`), ALL started before any is awaited by `probe_peers`. Answers are matched by node_id, and a
child that does not settle inside `PROBE_DEADLINE_S` (20 s) is named `probe_timeout` — never an empty list
that reads as "accepts nothing". The cached view still asks nobody.

**After:** `nodes probe parallel ok: 3 peers started 3 children before the first await, each answer matched
by node_id, and a child that never settles is named probe_timeout instead of answering []`
The test fails on the old file (measured: `no await was issued, so no child was read back: []`).

### 10b — the periodic backup runs off the sync tick, and one snapshot carries one manifest (`ff9d10ba`)

**Measured before:** `wa_sync_tick` called `backup.tick()` inline, so a `VACUUM INTO` of a large ledger held
the node's sync loop for its whole duration; and `M.tick` called `write_manifest` a SECOND time over the
directory `M.run` had already written it to.

**Fix:** `backup.due()` answers "is a snapshot due" from one memo read and no SQLite. When it is due, the
tick starts `wa backup periodic` as a SUPERVISED OPERATION (`host.operation start`, own timeout, owner
`backup-periodic`), so the work cannot block the loop and its outcome is in the operation record. The
manifest is written once, by `M.run`; `tick` reads `result.manifest`.

**After:** `backup restore ok: ... one manifest per snapshot and due() answering without SQLite`. The new
assertions fail on the old file (measured: `attempt to call a nil value (field 'due')`).

### 10c — a green row that printed SKIP is a SKIP, not a pass (`73ebf9b2`)

**Measured before:** 52 test files print `SKIP <test>: <reason>` and exit 0. `fast.sh`'s `check()` collected
those lines into the skips table and then recorded the row `pass`, so `fast path ok (N checks, 0 skipped)`
was true of the count and false of the run.

**Fix:** `check()` reads the log it already has; a row whose log carries `^SKIP ` is recorded `skip` with that
reason and counted in `$skipped`, and its line says SKIPPED.

**After:** `test-fast-skip-count: ok (a green row that printed SKIP is recorded skip and counted, a silent
green row is still a pass, and a failure stays a failure)`. The test reads `check()` OUT OF `scripts/fast.sh`
(not a copy) and fails on the old function (measured: `the shipped check() does not look for a SKIP line`).

### 10d — `wa build-env` quotes like a shell and reads the user home (`0266a557`)

**Measured before, two bugs:** the argument was quoted with Lua's `%q`, which is Lua syntax — measured,
`("%q"):format("/tmp/a$HOME id b")` produced double quotes, so the shell EXPANDED `$HOME` and RAN the
backtick command (observed output: `uid=1000(victor) ...`); and the root came from `WA_INSTALL_DIR`, where
the binary is installed, not the home the record hangs off.

**Fix:** a real POSIX single-quote (`shell_quote`, the form `lua/core/harness_evaluator.lua` already uses)
and the home from `lua/core/paths.lua`.

**After:** `test-build-env: ok (... every audited key is APPLIED ...)` with the new case asserting a home
containing `$HOME` and a backtick is passed through, not executed. Measured on the old code: the record was
read from `/nonexistent/install/dir/.wasm-agent/build.env` and the backtick command ran.

## Texts to approve (operator/model-facing, verbatim)

1. `refused(real_node_home): %s is the operator home or inside the operator store %s; this test would act on the real node`
2. `refused(real_node_home): %s contains the operator store %s; a home above the store is the same store`
3. `refused(real_node_home): the operator home could not be resolved, so the scratch home %s cannot be proven distinct from it`
4. `%s is held by pid %s (%s)` (the restore's holder line)
5. `refused(build_env_incomplete)` with `Fix: set WA_BUILD_ZIG=<path>`
6. `refused(row_at_sha_commit_required): name the base commit -- wa test --at <sha> <row>`
7. `refused(row_at_sha_row_required): name the row -- wa test --at <sha> <row>`
8. `refused(row_at_sha_unknown_option): <arg> (usage: wa test --at <sha> <row> [--repo DIR] [--json])`
9. `refused(row_at_sha_no_verdict): the worker produced no class= line, so nothing was compared`
10. `rollback ok` (printed only when the binary AND the Lua tree really match)
11. `probe_timeout` (the capability reason for a peer whose probe child did not settle)
12. `backup: periodic snapshot started as operation <id>` / `backup: periodic snapshot could not start: <reason>`
13. `backup periodic: <n> store(s) in <dir> (<m> old removed)` / `backup periodic: interval_not_elapsed`
14. `fast: <name> SKIPPED (<ms>ms): <reason>` (was `fast: <name> ok` for the same row)
15. `wa build-env` now reads `<home>/.wasm-agent/build.env` from the user home, not `WA_INSTALL_DIR`
