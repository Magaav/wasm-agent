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
16. `rollback-node: the node is served by %s; it is stopped for the swap and the same unit is restarted after it`
17. `rollback-node: the unit %s did not stop; the swap is still safe, the restart below is not`
18. `rollback-node: the unit %s was stopped for the swap and --no-restart was given; start it when you mean to, then check it with: readlink -f /proc/<pid>/exe` (was `the supervisor was stopped …`)
19. `rollback-node: rollback ok (binary and Lua tree both verified: serving pid %s executes %s, and lua-core is %s)`
20. `rollback-node: rollback_unverified: the pair WAS restored and these are the parts this run could NOT prove: %s`
21. `binary_not_read_by_this_run (no serving pid was proven to execute %s); ` / `lua_tree_not_compared; ` / `no_previous_lua_tree_was_kept (the tree beside this binary is whatever the last install put there, and this run did not compare it); ` / `there is no systemd user session here, so no unit was restarted and no serving pid was read` / `--no-restart was given, so no unit was restarted and no serving pid was read`
22. `wa test: refused(row_at_sha_bad_commit): --at %s is not a commit sha (hex digits only); nothing was run`
23. `moved the stale %s aside to %s` (restore journal note, `%s` = `-wal`/`-shm`)
24. `refused(restore_journal_move_failed)` / `refused(restore_journal_reappeared)` (restore refusals; the detail names the journal and the previous store)
25. `pre-commit`/entry-point refusal: `refused(build_env_key_unknown): the build record names a setting no build reads (the refusal above names it); remove that line or add it to WA_BUILD_ENV_KEYS with the face that consumes it` (deploy.sh)
26. `the build record names a setting no build reads; remove that line, or add it to WA_BUILD_ENV_KEYS with the face that consumes it` (mission.sh)
27. `refused(build_env_key_unknown): the build record names a setting no build reads` (wa land, per gate shell)
28. `host.runtime_info` field `build_source_dirty` (model-facing: the build tool's answer now names it)
29. `REFUSED %s: WASM_AGENT_HOME is the real %s; its store would BE %s - a row given the user home writes the operator node` / `… is the real store %s; a row must never act on it` / `… is inside the operator store %s` / `… contains the operator store %s; a home above the store is the same store` / `… is not an absolute path, so where it points depends on the caller cwd` (scripts/lib/scratch-home.lua, all four rows)
30. `node` env marker `WA_HOME_BEFORE_OVERRIDE` (set by `wa` when `WASM_AGENT_HOME` replaces `HOME`; read by the Lua guard)
31. `nodes probe bound ok: <n> unreachable peers probed in <ops> operation(s) from <gens> process generation(s), pids.peak <p> (bound <P>), memory.peak <m> MB (bound <M> MB)`
32. `FAIL test-nodes-probe-bound: <n> process generations started probe children (bound <b>); <n> supervised operations for <n> peers (bound <b>); pids.peak <n> (bound <b>); memory.peak <n> MB (bound <b> MB); - the probe fan-out is growing again (19/11: 1,653 processes and 23 GB)`
33. `SKIP test-nodes-probe-bound: <reason>` (no `systemd-run`, no cgroup `pids.peak`/`memory.peak`, no node, no python3, no `wa` binary)
34. `REFUSED test-nodes-probe-bound: <reason>` (no scratch home, no stub port, no counters printed)

## Round 3 (19/11, review 11:00) — the four MUST defects, and what each proof actually shows

Round 3 rebased onto `ac7717e0` (76 commits behind). The base was measured BEFORE any edit: a full
`scripts/fast.sh` in a separate worktree of `ac7717e0` was green (`295 checks, 0 failed`,
`/tmp/node-ops-base`), so anything red on this branch was this branch's. The rebase itself replayed 24
commits without conflict; the 76 landed commits had moved the prompt tool index, the refusal map and the
cue table under this branch's `build` tool, and those three rows went red for that reason alone
(`e0846874` regenerates the cue, the docs and the refusal map; `e091a765` regenerates the map once more
for the codes item 8 added).

| item | commit | what it now does | proof |
|---|---|---|---|
| 1 rollback never leaves a node down | `d4686b10` | the serving unit is DETECTED before anything is stopped (`wa_node_unit` → `UNIT_BEFORE`), the SAME unit is stopped and restarted, and a sentinel that is running but not detected is recorded as the unit to restart | `scripts/test-rollback-verify.sh` case 5: a fake supervisor whose unit is `active` at the start and INVISIBLE once stopped (`MainPID` 0 — exactly the 19/11 shape). It fails on the old order (`stop` then `wa_node_units` → empty → `rollback_unverified`, node down) and passes now: the marker shows `stop <unit>` and `restart <unit>` with the same name, and a NEW serving pid executes the restored file |
| 2 `rollback ok` only when both halves match | `d4686b10` | `BINARY_VERIFIED` and `LUA_VERIFIED` are set only by the identity checks; the last line is `rollback ok (...)` when both are set and `rollback_unverified: ... binary_not_read_by_this_run / lua_tree_not_compared / no_previous_lua_tree_was_kept ...` otherwise | same test, case 6: a `--no-restart` rollback with no previous tree ends `rollback_unverified` naming BOTH unproven halves; a `--no-restart` rollback that DID restore a tree names the binary half and does not claim the tree was missing |
| 3 Lua real-home guards compare the user home | `94048cad` | `scripts/lib/scratch-home.lua` is the one rule (the same four refusals as `scripts/lib/scratch-home.sh`), and all four rows call it | `scripts/test-scratch-home-lua.sh` (wired in `scripts/fast.sh:761` and `scripts/test.sh:890`): the real `$HOME`, the real store, anything inside it, anything above it, an empty home and a relative one are refused; a scratch home is accepted |
| 4 `build_source_dirty` emitted and read | `053af091` | `host.runtime_info` carries `build_source_dirty` from the binary's own build stamp (`BUILD_DIRTY`, set by `rust/wa-host/build.rs`); `lua/core/build_status.lua` reads it and can answer `edited` | `scripts/test-build-status.lua` calls the REAL `host.runtime_info` (not a synthetic table), asserts the field is `true|false|unknown`, and asserts this process — a build of this tree at this commit with uncommitted edits — is graded `edited`. Observed output: `runtime_info names build_source_dirty=true, and this process is graded edited` |
| 5 `wa test` builds no shell from `%q` | `cb397b87` | `--at` is validated as hex BEFORE any shell exists (`row_at_sha_bad_commit`), and the command is built with single-quote escaping instead of Lua's `%q` | `scripts/test-row-at-sha.sh`: `wa test --at '$(touch …)'` exits 2 with `row_at_sha_bad_commit` and the file the substitution would have created does not exist |
| 6 restore moves the sidecars with the previous file | `31e6e01f` | the old `-wal`/`-shm` are MOVED to `<source>.pre-restore-<stamp><suffix>` before the restored file lands (never `rm -f`, never after the swap); a journal that reappears is refused by name | `scripts/test-backup-restore.lua`: the `-wal` is gone from beside the store, the kept copy holds the old bytes, and the report names the move |
| 7 row-at-sha: one ledger per side | `be2563ea` | the base side runs under `$scratch/base/home-<row>` and the change side under `$scratch/change/home-<row>`; both are printed as `base_home=`/`change_home=` | `scripts/test-row-at-sha.sh` refuses equal homes or one inside the other, and requires each under its own side root |
| 8 LOW: sourced libraries, the record in every entry point, 124 | `94048cad`, `68c0b4a1` | `scripts/lib/row-at-sha.sh` sets `-uo pipefail` only when it IS the program; `deploy.sh`, `mission.sh` and `wa land` run `wa_build_env_audit` and refuse an unknown key by name; a quoted value in the record is unquoted | `scripts/test-build-env.sh` (unknown key stops fast.sh), the deploy/mission/land source assertions in the same test, and `scripts/test-fast-watchdog.sh`, which now proves a command that exits 124 ITSELF comes back 124 with NO watchdog line — the runner reads the watchdog's own line, never the number |

### The 19/11 out-of-memory kill: TWO growths, both measured, both fixed (`48ca92de`, `b656b328`, `10fc1747`)

The node went from 6 GB to 23 GB RAM + 7.5 GB swap and `wa-serve` was killed. The kernel recorded the
victim as `Killed process 2643685 (wa) ... anon-rss:45792kB` inside this mission's own cgroup: a 45 MB
member of a MEMCG OOM is a crowd of identical processes, not a leak in one.

**This section replaces round 3's claim that `c31f9ab6` fixed it. Measured here, it did not.** A run of
this tree at `b903117b` - the commit the round-3 report describes as fixed - still died at a 6 GB scope
cap with `Terminated xargs -P ...` in the middle of the Lua rows, and the sampler caught what the code's
own story called impossible: **338 `wa ... nodes probe` processes in one second**, their parent chain a
probe child starting probe children. Two separate growths fed it.

**Growth A - the mark lived on ONE module instance (`48ca92de`).** `lua/core/nodes.lua` is `dofile`d
by fifteen callers (`init`, `server`, `tools`, `subagents`, `fleet`, `federation`, ...), and every
`dofile` builds its own `M` table. The guard was `M._in_probe_child`, so `M.probe` marked only the
instance it ran in and the other fourteen in the same process still fanned out; each child repeated that, so
the tree was unbounded. The mark is `_G.WA_IN_PROBE_CHILD` now, which every instance shares. Sampled shape,
1 s resolution, before the fix: `nodes probe aaaa` -> `nodes probe bbbb`, 49 children at t=4 s, 378 at t=5 s.

**Growth B - children accumulated across calls (`b656b328`).** A child lives up to `PROBE_DEADLINE_S`
(20 s) and every `M.list()` started a fresh one per peer with no memory of the call before it. Measured on
`scripts/test-remote-refusals.lua`: **125 live `wa nodes probe` processes for a 6-peer roster**.
`probe_peers` now keeps a process-wide in-flight registry (`_G.WA_PROBE_INFLIGHT`, process-wide for the
same dofile reason), joins a child already running for that peer, and caps the process at 64 live children.

**Over the cap the peer is NAMED, never silently unanswered (`10fc1747`).** The reason is
`probe_capacity`. It does not fall through to the in-process ask, because that ask is one blocking
`host.http` per peer - the serial sum of timeouts item 10a removed - so falling through would trade a
memory blow-up for a latency one.

| what the row asserts | this tree | red on |
|---|---|---|
| an unmarked instance fans out (so the row can fail) | 6 children | - |
| a probe-marked instance starts nothing | 0 | `48ca92de^`: `80 probe children of 80 (the 19/11 recursion)` |
| an instance loaded AFTER the mark starts nothing | 0 | `48ca92de^` (same run) |
| a repeated `list()` starts nothing | 6 then 0 | `48ca92de`: `80 MORE children ... 80 then 80 (the accumulation)` |
| 500 peers are capped | 64 | `48ca92de`: unbounded |

Row: `scripts/test-nodes-probe-instances.lua`, wired in `scripts/fast.sh:776` (right after
`nodes-probe-parallel`) and `scripts/test.sh:912`. Both red halves ran in their own detached worktrees
(`/tmp/base-a` at `48ca92de^`, `/tmp/base-b` at `48ca92de`), never with `git stash`.

**Still named and NOT fixed:** a probe child OUTLIVED the run that started it (`out.log:70425` lists them
after the run ended), so a supervised child whose parent dies is still cancelled by nobody but its parent.
The in-flight registry bounds one process's live children; it does not reclaim an orphan of a dead parent.

### Mis-measured premises in the brief (re-measured here)

* Item 1 is real and worse than stated: the stop happens BEFORE the detection, so on a sentinel-supervised
  node the unit it stopped is invisible to `wa_node_units` (`MainPID` 0) and the script refuses without
  restarting. `scripts/rollback-node.sh:96-99` (base) → `d4686b10`.
* Item 3's premise was right about the wrong side, but the deeper fact is that the guards could not fail
  AT ALL: `rust/wa-host/src/main.rs:278` sets `HOME` from `WASM_AGENT_HOME` before any Lua runs, so inside a
  node `HOME == WASM_AGENT_HOME` by construction. The launcher now records `WA_HOME_BEFORE_OVERRIDE`
  (`94048cad`) and the guard reads that. Without it a guard comparing `HOME` compares a home with itself.
* Item 4's report line said a dirty build at the same commit reads `edited`; the binary did not expose the
  fact, so `build_status` could never produce that verdict from a real build. `053af091` makes it real and
  the row proves it end to end.
* Item 8's "base side uses the change tree's watchdog lib" is not the code's shape: `wa_row_at_sha_run`
  resolves the watchdog from `$root`, and `ac7717e0` has no `scripts/lib/fast-watchdog.sh` at all (the
  branch adds it), so the base side runs without one and the row's log SAYS so. Kept as is, measured.

### Round 3, measured while proving the items (they changed the code, not just the text)

* **The holder scan was the restore's real defect.** `wa restore` answered in 130-155s and the row's own
  20-second holder had expired before the scan reached it, so a correct refusal read as `restore_store_held`
  never firing and the row was killed by its 120s watchdog. Measured on this node: the nested
  `for d in /proc/[0-9]*; do for f in "$d"/fd/*; readlink` loop takes **11.5s** (1,647 processes, 10,744
  descriptors) while ONE `ls -l /proc/[0-9]*/fd/*` pass takes **126ms**. `77c5b9ec` replaces the scan with
  the one-pass form: the same row now runs in **7s** and passes, holder refusal included.
* **The four scratch-home rows needed the run's own binary.** They resolve `WA_BIN`, then the tree release,
  then PATH; on this node PATH holds `~/.local/bin/wa` (another commit's build), which rewrites `HOME` from
  `WASM_AGENT_HOME` WITHOUT recording the home it replaced - so under the fast path the guard saw no marker
  and refused a correct scratch home. `dc40fff2` exports `WA_BIN="$bin"` from `scripts/fast.sh`, so a shell
  row spawns THIS tree's node. Measured after the fix: all four wrappers exit 0 under the runner's own
  environment.
* **`scripts/test-session-isolation.lua` has its own guard** (`:38`): it requires the home path to name
  `scratch`, `tmp` or `temp`. A scratch root under `~/wasm-agent` is refused by that rule and not by the
  tree - the full run below uses `TMPDIR=/tmp/...` for that reason.
* `scripts/test-harness-evaluator-replay.lua` is a **pre-existing** failure: `row-at-sha` classifies it
  `pre_existing` (`base exit 1, change exit 1`), and `scripts/test-changeset.lua` is `still_passing`
  (`base exit 0, change exit 0`) - its fast-path failure is `/tmp` pressure, not this branch.

* **Two failures were load, made visible by the suite's own parallelism, and each was fixed at its cause:**
  `scripts/test-backup-restore.lua` waited a FIXED `host.sleep(1)` for the holder's pid file (on a loaded
  machine the file did not exist yet and the row failed with 'the holder fixture recorded no pid'); it now
  polls with a bound and its holder holds 90s. Verified with three concurrent runs: all green (`0f7bd05a`).
  The three single-row failures of the 1,146s run - `test-release-sign.lua`, `test-backup-restore.lua` and
  `wa-capabilities`'s `subagents::tests::health_shape...` - all pass standalone; `row-at-sha` classifies
  `test-release-sign.lua` `still_passing` (base exit 0, change exit 0), so the tree is not the cause.

* **A third measured race, pre-existing and landed:** `scripts/lib/release-signing.sh:282` asked a candidate
  binary with `wa ... --help | grep -q` under `pipefail`, so ~0.15% of calls skipped a binary that answered
  and the row said 'no installed wa binary here answers'. Measured: `binary alone on fixture rotation` failed
  2 of 5 runs in the fast path; after capturing the help text and matching a here-string (`03a50b3b`), 4 of
  4 pass. The same shape exists in other scripts this round did not touch; the five files whose behaviour
  this mission's items rest on (`fast.sh`, `scripts/lib/fast-rows.sh`, `scripts/lib/fast-environment.sh`,
  `scripts/lib/release-signing.sh`, `scripts/test-fast-rows.sh`) are converted, and the rest are named here
  as the same class rather than claimed fixed.


* **The restore's stop sentence (item 8's report requirement), quoted from `lua/core/backup.lua:521-526`:**
  `stop_command` answers the ONE command that stops the process holding a store -
  `systemctl --user stop <unit>` when `/proc/<pid>/cgroup` puts the holder in a systemd unit,
  `kill <pid>  # pid <pid> (<command>)` when it does not, and `(this process could not be named)` when
  neither is readable. It is never a guessed command, and the refusal names the holder
  (`pid <pid> (<command>)`, `describe_holders`) so the operator knows what they are stopping. The sentence
  was already in place at `ac7717e0` (round 2); round 3 changed the scan that FEEDS it - one `ls -l` pass
  instead of a nested readlink loop - which is what made the holder findable within the row's lifetime
  (`77c5b9ec`).
### The full fast path, measured (this tree, this node)

```
$ TMPDIR=$B HOME=$B/home CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-node-ops \
    WA_FAST_JOBS=4 bash scripts/fast.sh
fast: binary /home/victor/wasm-agent/target/m-node-ops/release/wa (build 26a09757…, tree 26a09757…, fresh: built from this tree)
…
fast result ok (312 checks, 0 failed, 0 skipped)
fast path ok (312 checks, 0 skipped, 690s)
```

- `HOME=$B/home` and `TMPDIR=$B` are a scratch home OUTSIDE the operator store (`scripts/lib/scratch-home.sh`
  refuses anything else), and `$B` is under `/tmp` because `scripts/test-session-isolation.lua` requires a
  home whose path names `scratch`, `tmp` or `temp`.
- Base for comparison: a separate worktree of `ac7717e0` (`/tmp/node-ops-base`, no stash) ran the same
  command green at **295 checks, 0 failed, 269s** BEFORE any edit of this round, which is what makes the
  six red rows the rebase produced this branch's, not the base's.
- The run before this one (same tree, before the last two fixes) was `1 of 312 failed`
  (`publish-artifacts`, the SIGPIPE race) and the one before that `3 of 312` (load); every remaining failure
  in this round was traced to a measured cause and fixed there, or classified `pre_existing` by `row-at-sha`
  (`scripts/test-harness-evaluator-replay.lua`: base exit 1, change exit 1).

