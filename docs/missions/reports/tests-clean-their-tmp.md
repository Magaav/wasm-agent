# tests-clean-their-tmp

Priority 1, 23/11. `/tmp` on avell is a 16 G tmpfs with a per-user quota; it ran out three times in one day
and each time a verdict was lost - `main-health` red on ENOSPC (22808bc8), the row `regenerate` dead on
`fatal: unable to write loose object file: Disk quota exceeded` (2104a4d8, 07:36Z), and a tool result
failing with EDQUOT. Branch `change/tests-clean-their-tmp`, base `83772130`, worktree
`/home/victor/Work/missions/tests-clean-their-tmp/wt`. Commits:

* `f942c21c` the temp floor: `main-health`, `preflight` and the fast path refuse a machine with no room in
  `/tmp` by name (`tmp_low`), before they start anything;
* `1544404f` the rows that minted in `/tmp` take their root from the runner and remove it on exit, and
  `scripts/test-tmp-cleanliness.mjs` is the test that holds every row to it (wired into `scripts/fast.sh`
  and `scripts/test.sh`);
* `4098c6ca` a tmux server and a mission watchdog die with the process that started them (item 7);
* `164e27a8`, `041e410a`, `2bf03283` this report and the two corrections it needed (a line number that moved
  when the floor was added, and the library's own usage line after the file was renamed off the `.gitignore`
  `tmp-*` pattern).

## Premises, re-measured on this node before writing code

| brief said | measured | verdict |
| --- | --- | --- |
| /tmp is a 16 G tmpfs, /tmp held 4,721 entries at 07:35Z | `df -h /tmp` -> `tmpfs 16G`, 5.5 G used; `ls -1 /tmp | wc -l` -> **3,232** at 06:45Z (others had already removed the 4,721, and other sessions kept writing: 3,264 by 08:10Z) | correct in kind, the count had moved |
| a full /tmp turns main-health red on a product row | the mechanism is real and I reproduced its cause: one fast-path run leaves `/tmp/wa-changeset-<epoch>` **every run**, so the count only grows. `scripts/main-health.sh` writes its verdict out of the row results, so an ENOSPC inside a row is indistinguishable from a red row (`scripts/main-health.sh`, the jq that builds `failed[]` from `checks[]`) | correct |
| fast.sh already keeps a failing row's evidence (the undo-rows fix) | `scripts/fast.sh`, function `wa_fast_keep_failed_logs`: it copies each failed row's log and any directory named `kept for diagnosis: <dir>` into the evidence dir before deleting its work dir, and keeps the five newest runs | correct - and the row fixes below are built to feed it |
| fast.sh runs the suite under one parent scratch dir | `scripts/fast.sh:279` `work=$(mktemp -d "$scratch_root/wa-fast-XXXXXX")`, `:582` `export TMPDIR="$work/tmp" GATE_ROOT="$work"`, `trap 'wa_fast_keep_failed_logs; rm -rf "$work"' EXIT`. Measured on my run: the work dir was `/home/victor/Work/missions/tests-clean-their-tmp/.wa-scratch/wa-fast-SNR8Uy` - on disk, outside `/tmp`, deleted at exit | correct, already done by `ac2ebdc3`; what was missing is that rows ignored it |

The brief's facts held. What it did not say, and I measured: the leak was not the runner, it was **four
rows that never asked the runner where to write**.

## Item 1 - the map: which prefix, which code, how many per run

Measured with `/home/victor/Work/missions/tests-clean-their-tmp/measure/per-row.sh`: each row is run the way
`scripts/fast.sh` runs it (its own scratch `HOME`, `WA_SCRIPT`, `TMPDIR` and `GATE_ROOT` under a scratch
root) and the real `/tmp` is diffed by mtime afterwards. Only entries named after a family the row's own file
mints are attributed to it; other sessions on this node write to `/tmp` too.

| family left in /tmp | minted by (base `83772130`) | per run | on disk 23/11 | state |
| --- | --- | --- | --- | --- |
| `wa-changeset-<epoch>` | `scripts/test-changeset.lua:23` `(os.getenv("WASM_AGENT_TEST_DIR") or "/tmp") .. "/wa-changeset-"` | **1, every run, pass or fail** | 70 | fixed in `1544404f` |
| `wa-agent-control-e2e-*` | `scripts/test-agent-control-e2e.cjs:22` `fs.existsSync('/tmp') ? '/tmp' : os.tmpdir()` | **1, every run, even green** | 8 | fixed in `1544404f` |
| `wa-mission-amend-resume-*` | `scripts/test-mission-amend-resume.mjs:31`, same shape | 1 per **failing** run (the cleanup ran only `if (!process.exitCode)`) | 8 | fixed in `1544404f` |
| `wa-mission-amend-*` | `scripts/test-mission-amend.mjs:32`, same shape | 1 per failing run | 0 visible (removed by hand at 07:38Z) | fixed in `1544404f` |
| `wa-component-build-XXXXXX` (file, 4 K) | `scripts/build-components.sh:175` `mktemp "${TMPDIR:-/tmp}/wa-component-build-XXXXXX"` | 1 per component build, removed on pass (`:180`, `:186`) | 1 | correct as it is: kept only as a failing build's log |
| `wa-fast-build-XXXXXX` (file) | `scripts/lib/fast-binary.sh:281`, removed at `:323` | 1 per failing binary build | 1 | correct as it is (the log of a build that failed) |
| `wa-eval-review-change-fixture-*`, `wa-eval-replay-fixture-*`, `narrow*`, `fastkeep*` | **not this tree**: another live mission (`remote-roundtrip-and-roster`, `wa-eval-review`) ran on this node throughout | n/a | 116 + 59 + others | not this change's, named so the map is honest |
| 9 gate rows that mint one dir under `/tmp` and remove it in a trap | `scripts/test-{append-race,behavior,foreground-cancel,health-build-label,run-isolation,serve-concurrency,update,upgrade-idle,upgrade-ui-fonts}.sh` | 0 leaked (they remove it) | 0 | named in the test's `DEFERRED` list; TMPDIR-ising them is the remaining fix and touches nine gate rows this delivery did not run |

**Per suite run, this tree adds exactly one entry**: my first full fast-path run (627 s, 418 checks) added
`wa-changeset-1795427631.6075` and nothing else. The other 18 new entries in that window came from the two
other suites and my own per-row probes.

## Item 2 - every row removes its own scratch, pass or fail

`1544404f`. The rule applied to each row: take the scratch root from the environment the runner sets
(`WA_TEST_ROOT`, `GATE_ROOT`, `TMPDIR`, then `os.tmpdir()`), and remove what you made **on exit, pass or
fail**. A failing row's evidence is kept only where the runner will collect it - inside `GATE_ROOT`, where
`scripts/fast.sh`'s keeper copies a directory named `kept for diagnosis: <dir>` out before it deletes its own
work dir - or when the operator sets `WA_TEST_KEEP_SCRATCH=1`.

Per file:

* `scripts/test-changeset.lua` - root from `GATE_ROOT`/`TMPDIR`, `cleanup()` called by `ok()` (the file's only
  failure path) and at the end; `host.exec` does the removal because `host` has no recursive remove. Verified
  on all three paths: pass -> `TMPDIR` empty; fail with `GATE_ROOT` unset -> scratch removed (injected
  failure, real code path); fail with `GATE_ROOT` set -> `fixture kept for diagnosis: <dir>`, which is what
  the keeper copies.
* `scripts/test-agent-control-e2e.cjs` - root from `WA_TEST_ROOT`/`GATE_ROOT`/`TMPDIR`/`os.tmpdir()`, and the
  `finally` removes it (or prints the diagnosis line when the runner owns it).
* `scripts/test-mission-amend.mjs`, `scripts/test-mission-amend-resume.mjs` - same root rule, and the
  `finally` now removes on failure instead of keeping forever; the duplicate `fixture kept for diagnosis`
  line in the `catch` is gone so the line is printed exactly once, and only when it is true.
* `scripts/test-fabric-bench.mjs` - `WA_FABRIC_BENCH_TMP`, then `GATE_ROOT`, then `TMPDIR`, then
  `os.tmpdir()`.
* `scripts/test-stream-cut-recovery.lua:75` and `scripts/test-tool-call-name.lua:118` - the marker path they
  assert is **absent** now lives under `TMPDIR`: a marker another run left in `/tmp` would have made "nothing
  executed" pass for the wrong reason.

Re-measured after the fix, same harness: all seven rows `rc=0` (the resume row's `rc=1` is my isolated
harness's own `wa` discovery, see "not verified") and **zero** `/tmp` entries named after any of them.

## Item 3 - one parent scratch dir, removed at the end

Already held by `scripts/fast.sh` (commit `ac2ebdc3`, before this change), and now measured and protected:

* the run's work dir is `mktemp -d "$(wa_scratch_root wa-fast)/wa-fast-XXXXXX"` - on my run
  `/home/victor/Work/missions/tests-clean-their-tmp/.wa-scratch/wa-fast-SNR8Uy`, i.e. on disk, outside the
  operator store and outside `/tmp`;
* every row gets `TMPDIR="$work/tmp"` and `GATE_ROOT="$work"`;
* `trap 'wa_fast_keep_failed_logs; rm -rf "$work"' EXIT` removes it, evidence first.

What this change adds is the reason it now holds: a row that ignores those variables is caught by the new
test (item 5) instead of quietly writing to `/tmp`.

## Item 4 - the temp floor, refused by name before anything starts

`f942c21c`. New `scripts/lib/temp-floor.sh` with one function, `wa_tmp_floor_check`, which measures every
directory it is given (the three callers pass `/tmp` **and** `${TMPDIR:-}`, because this node's `TMPDIR` is
inside the operator store and measuring only that reports a healthy `/home` while the tmpfs is full) and
answers 0 room / 1 `tmp_low` / 2 `tmp_unknown` (an unmeasurable disk is refused, never passed). The floor is
`WA_TMP_MIN_FREE_MB`, default 2048 - the scratch one run left on this node on 23/11 cost ~3 G of a 16 G
tmpfs, and a caller that knows its own bill may name it.

Wired in three places, each before any work:

| entry point | where | what it prints |
| --- | --- | --- |
| `scripts/main-health.sh:52-66` (`:58` is the call) | before the tool checks, before the worktree, before the suite | `main-health: refused(tmp_low): tmp_low: /tmp 10281 free, need 999999999; ... Nothing was judged.` exit 2 |
| `scripts/preflight.sh:52-66` (`:58` is the call) | before the lock, before the landing, before the gate | `preflight: refused(tmp_low): ... Nothing was judged.` exit 2 |
| `scripts/fast.sh:74-95` (`:81` is the call) | immediately after the options, before the build record and before the first row | `fast: refused(tmp_low): ... Nothing was run: a red caused by a full disk is a fact about the machine and never about this tree.` exit 2 |

Exit 2 is the code both `scripts/main-health.sh` and `scripts/preflight.sh` already document as "nothing was
judged", so a full disk can no longer be written down as `ok:false` about main or about a branch.

## Item 5 - a test that fails when a row leaves a dir behind

`scripts/test-tmp-cleanliness.mjs` (`1544404f`), three halves, 0.6 s measured:

* **A, static**: every tracked `scripts/test-*` file that roots a temp family at a literal `/tmp` fails,
  unless the runner's environment is asked first on that line or the file is in `DEFERRED` with a reason
  **and** still contains the removal that bounds it (an entry that stops matching is printed `resolved`).
* **B, dynamic**: two rows this change fixed are RUN, each with `TMPDIR` pointed at a fresh directory, and
  that directory must be **empty** afterwards. No binary -> the test refuses (exit 2, named), it does not
  pass on the half it could not check.
* **C, the floor**: `main-health`, `preflight` and `fast.sh` are each run with `WA_TMP_MIN_FREE_MB` above any
  machine's free space **and a second broken prerequisite** (a missing repo, a missing interpreter, a build
  record naming an unknown key), and must answer `tmp_low` rather than the other refusal - which proves the
  floor is asked first and keeps the half cheap on a tree that has none.

Wired at `scripts/fast.sh:1096` (`WA_BIN="$bin" check tmp-cleanliness node scripts/test-tmp-cleanliness.mjs`)
and `scripts/test.sh:2536` (`WA_BIN="$BIN" gate_run node scripts/test-tmp-cleanliness.mjs`);
`scripts/test-orphan-tests.mjs` reports it wired.

**Discrimination, measured on a separate worktree of the base** (`git worktree add --detach ... 83772130`,
never `git stash`): with only this test file copied in, `node scripts/test-tmp-cleanliness.mjs` **FAILS with 6
failures** - the three rows that prefer the literal `/tmp` (`test-agent-control-e2e.cjs:22`,
`test-mission-amend-resume.mjs:31`, `test-mission-amend.mjs:32`) and the three entry points that have no floor
check. On this branch the same command passes 6 of 6. The first version of the static detector *passed* on
base (it missed `(os.getenv(...) or "/tmp") .. "/wa-x-"`); that run is why the `bare-tmp-root` shape exists.

## Item 6 - build and scratch dirs on disk, never /tmp: where the rule belongs

The measured offenders (3.3 G `/tmp/sb-e2e` for a speed board, 900 M `/tmp/gitc` for a base-target cargo
build) are not in this tree's code: `scripts/mission.sh:58` already sets `TARGET_ROOT=/home/victor/wasm-agent/target`
and `:598` writes the mission's own `TARGET=$TARGET_ROOT/m-$name`, `:635` exports it as `CARGO_TARGET_DIR`,
and `scripts/speed-board.sh:99` uses `${TMPDIR:-/tmp}`. They came from ad-hoc session commands. So the rule
belongs where a session reads its rules, and in the one script that writes every mission's prompt:

1. **`scripts/mission.sh:607-610`**, the `## Where you are` block it writes into every `prompt.md`. Proposed
   replacement for the `CARGO_TARGET_DIR` sentence (today: `CARGO_TARGET_DIR=%s is this mission's only build
   dir. Never build, test or sync code on another node.`):

   > `PATH from %s/cargo/bin, CARGO_TARGET_DIR=%s is this mission's only build dir, and it is on disk: /tmp is a 16 G tmpfs (RAM) on this node, so a cargo target or a scratch tree there is memory - measured 23/11: 3.3 G in /tmp/sb-e2e and 900 M in /tmp/gitc. Never build, test or sync code on another node.`

2. **`~/Work/missions/FACTORY.md`** (operator's file, not written by me), as a rule next to rule 12. Proposed
   text, quoted for pasting:

   > A mission's build and scratch dirs live under its own `CARGO_TARGET_DIR` / mission dir ON DISK, never
   > `/tmp`. On this laptop `/tmp` is a 16 G tmpfs: a cargo target there is RAM, and it ran out three times in
   > one day (23/11), each time losing a verdict - one of them as a red about a product row. Measured that day:
   > `/tmp/sb-e2e` (a speed-board scratch, 3.3 G) and `/tmp/gitc` (a base-target cargo build, 900 M) were both
   > cargo targets in RAM. `CARGO_TARGET_DIR` is `<missions target root>/m-<name>` (`scripts/mission.sh` sets
   > it, `run.sh` exports it); a scratch dir goes under the mission dir or `$CARGO_TARGET_DIR`; `TMPDIR` for a
   > mission is its own tree. Never `/tmp`, and never `~/.local/bin`.

3. **`~/Work/missions/HANDOVER.md`** (operator's file), in the node's facts. Proposed line:

   > `/tmp` is a 16 G tmpfs with a per-user quota: missions keep build targets and scratch under their own
   > target/mission dir, never `/tmp`. The suite refuses a machine with less than `WA_TMP_MIN_FREE_MB` (2048)
   > free there, by name (`tmp_low`), instead of reporting a red row.

4. **The briefs** Victor writes: the sentence that already says "Build and test HERE on this node" should say
   where, e.g. `cargo is on PATH, CARGO_TARGET_DIR=<...> (on disk, never /tmp - it is a tmpfs)`. Every brief I
   have read on 23/11 names `CARGO_TARGET_DIR`; none says why /tmp is not an option.

## Acceptance - the fast path twice, /tmp counted before and after

Victor's acceptance: "run the fast path twice: the count of entries in /tmp is the same before and after
(except kept failure evidence)".

| run | result | /tmp entries |
| --- | --- | --- |
| 1, full fast path on `1544404f` | **green: 419 checks, 0 failed, 0 skipped, 565 s**, and `fast: tmp-cleanliness ok (376ms)` | 3,260 -> **3,232** |
| 2, the same commit again | 419 checks, **1 failed**: `FAIL deploy-wait (exit 1): the held wakes run once the deploy ends: still 0`, 612 s | 3,232 -> 3,327 |

**The counts are not the proof, and this is why.** Both windows include the time the run spent queued for
`~/Work/missions/.suite.lock` (38 and 46 minutes: four other missions were running suites on this node all
afternoon), so they measure the machine, not the suite. `ls -1 /tmp` grew and shrank by hundreds of entries
that belong to other sessions.

**What is the proof, in order of strength:**

1. **The row takes its root from the runner, shown end to end.** Running the row through the fast path own
   exec chain (`scripts/lib/fast-row-exec.sh` -> `wa_fast_row_exec`) with `TMPDIR`/`GATE_ROOT` exported, a
   probe row prints `TMPDIR=/tmp/wa-probe-chain/tmp` and `GATE_ROOT=/tmp/wa-probe-chain` - the variables
   arrive. With `GATE_ROOT` set and the row made to FAIL, `scripts/test-changeset.lua` keeps its scratch at
   `<GATE_ROOT>/wa-changeset-1795429111.5966` and prints `fixture kept for diagnosis: <that path>`: the root
   is inside the runner work dir, not `/tmp`, and the keeper can copy it.
2. **Per row, measured with `/tmp` diffed by mtime**, each in the fast path own environment: the seven rows
   this change fixed left **zero** new `/tmp` entries and zero in their own `TMPDIR`. The same harness on the
   base commit measured `wa-changeset-<epoch>` (test-changeset), `wa-agent-control-e2e-*` (agent-control-e2e)
   and `wa-mission-amend-resume-*` (the failing resume row).
3. **Attribution of the entries that DID appear.** In run 1 window nine entries appeared and none belongs to
   this tree (`fastkeep5`, `dbgf`, `rowout`, `wa-home-ops`, `preflight.log`, `db-rb.log`, `dw-rb.log` are
   other sessions shell scratch; `wa-eval-*` are the `wa-eval-review` mission rows running at the same
   time). In run 2 window four `wa-changeset-*` and two `wa-mission-amend-resume-*` appeared: three of the
   four predate run 2 execution, and all of them are consistent with the **twenty-three** of the twenty-four mission
   worktrees on this node that still carry the unfixed line (measured: 23 of the 24 trees that have
   that row still match 'or "/tmp"'; the one that does not is this worktree), each producing
   one per run.
   **One of them (`wa-changeset-1795434665`, 11:53:45Z) falls inside run 2 window and I cannot attribute it
   by name**: it is the same shape this tree stopped producing, one second inside the window, and it is what
   the twenty-three unfixed trees emit. I am not counting it as mine and I am not claiming it is not.

**Run 2 one failure is not this change.** `deploy-wait` passed in run 1 thirty minutes earlier on the same
commit and passes standalone (`bash scripts/test-deploy-wait.sh` with the same binary: `deploy wait
ok`, exit 0, 300 s timeout). `wa_fast_watchdog`/wake timing under four concurrent suites is the shape that
fails; the diff here touches no deploy, wake or timing code.

## Item 7 (added by the orchestrator, 23/11 ~11:35Z) - a server and a sleep die with their parent

Two leaks measured on this node, both from rows that had already PASSED, so nothing in a red row or a log had
ever named them:

| what was left | how much | where it came from |
| --- | --- | --- |
| `tmux -L wa-run-live-1304985`, 41 hours after its parent died, holding a session `live` and a running `wa --db ~/.wasm-agent/tmp/wa-run-live-PNgegf/ledger.db` | 1 server, plus **1,340 `wa-*` socket FILES** in `/tmp/tmux-1000`, every one answering `no server running on ...` | `scripts/test-*-pty.mjs` (nine rows), each starting its own `tmux -L wa-<name>-<pid>` and killing it in a `finally` - which a SIGKILL never reaches |
| orphaned `sleep 21600` (parent `systemd --user`) | **108 live** when I started counting, in batches of six | `lua/core/mission.lua:197` and `:234`, the mission runner timeout watchdog |

**The tmux half** (`4098c6ca`). One helper, `scripts/lib/tmux-session.mjs`, and all nine pty rows converted to
it (two lines each: the socket name and the `tmux()` wrapper). It kills its server on every path the process
can take - `exit`, `SIGINT`, `SIGTERM`, `SIGHUP`, an uncaught exception - and, because a **SIGKILL cannot be
caught** and that is exactly what happened, it also reclaims: the socket name carries the owning pid, so
`reclaimStaleServers()` asks the kernel (`kill(pid, 0)`) and kills the server of an owner that is gone. Two
details measured while building it:

* **a zombie answers `kill(pid, 0)`**, so the first version of the reclaim skipped the server it had just been
  asked to remove (the leak probe caught it: `wa-sigkill-probe-2128012 survived a SIGKILLed owner`).
  `ownerAlive()` reads `/proc/<pid>/stat` and treats `Z` as gone;
* **a killed server leaves its socket FILE behind** (`tmux kill-server` on a socket with no server answers
  `no server running on ...` and does not unlink it) - which is what the 1,340 files were. `killServer()`
  unlinks the socket after the kill, so the count is a leak check rather than a count of history.

Measured after the change: the reclaim removed **1,340 stale socket files** on its first run; `wa-*` sockets
in `/tmp/tmux-1000` went 1,342 -> 2 (`wa-ref`, `wa-sn`, another tool's hand-named servers, left alone);
`node scripts/test-run-live-pty.mjs` **22 ok, 0 failed, 0 skipped** and left no socket and no server behind.

**The sleep half** (`4098c6ca`). `lua/core/mission.lua` started its watchdog as
`( sleep ${MISSION_TIMEOUT_SECONDS:-21600}; kill ... ) &` and then `kill "$watchdog"` - which kills the
SUBSHELL and never the `sleep` inside it, so every launch that ended normally left one behind for the rest of
the day (six per batch, one batch per launch). The deadline is now COUNTED in five-second steps: the watchdog
leaves the loop as soon as the CLI is gone, and the most a killed watchdog can leave is one step. Both
occurrences (the first turn and the deploy-wait retry loop) carry the change and the measurement in a comment.

**The leak check** (`scripts/test-tmp-cleanliness.mjs`, half D - the whole check now runs in 8.3 s measured, up from 0.6 s: the SIGKILL probe waits for a child and the watchdog probe waits out one five-second step):

* **D1 static**: every `scripts/test-*-pty.mjs` that starts a tmux server must do it through the helper - a row
  that starts its own server is the 41-hour leak again;
* **D2 dynamic, the SIGKILL path**: a child starts a server through the helper and is killed with SIGKILL
  (nothing in it can run), the shipped `reclaimStaleServers()` then runs in a third process, and the socket
  must be gone. The leak it kills is made first and asserted to exist, so the probe cannot pass by making
  nothing;
* **D3 dynamic, the watchdog**: the block is taken OUT OF `lua/core/mission.lua` and run the way the runner
  runs it (start, kill the watchdog after a second), then any `sleep` of 600 s or more that appeared is a
  FAIL naming its pid. The first version of this probe extracted the block from a `$(` inside the comment
  above it and passed on the base tree - the extraction now starts at the line that opens the block, and on
  base D3 fails with `left 1 long sleep(s) behind ... pids 2149579`. The probe also had to be told to WAIT
  out one step: killing the watchdog one second in and looking immediately reported the watchdog's own
  five-second step as a leak, and the node refused the surrounding call for leaving a background descendant.

**Discrimination, on a separate worktree of base `83772130`**: the base copy of the test FAILS **17 of 19**
checks (nine pty rows without the helper, the helper absent, the watchdog leak, plus the three rows and three
entry points from items 2 and 4); on this branch it PASSES 9 of 9.

**Not done, said plainly:** the 108 `sleep 21600` processes that were already orphaned are still running. I
did not kill them: they are PIDs I did not start, and this round stops only its own (the standing rule after
21/11). New launches no longer make them.
## Texts to approve (operator- or model-facing, verbatim)

1. `fast: refused(tmp_low): <note>. Nothing was run: a red caused by a full disk is a fact about the machine and never about this tree.`
2. `main-health: refused(tmp_low): <note>. Nothing was judged.`
3. `preflight: refused(tmp_low): <note>. Nothing was judged.`
4. the note itself: `tmp_low: /tmp 10281 free, need 2048` and, for an unmeasurable disk,
   `tmp_unknown: WA_TMP_MIN_FREE_MB=x is not a number of MiB` / `tmp_unknown: /nope: not a directory`.
5. `fixture kept for diagnosis: <dir>` (reused, unchanged wording) - now printed only when the directory
   really is kept.
5b. `the mission runner's watchdog left N long sleep(s) behind on its normal exit` and
   `a tmux server whose owner was SIGKILLed (<socket>) is reclaimed by the next session (N socket(s) removed)`,
   `<file>:<line> starts a tmux server without scripts/lib/tmux-session.mjs`.
6. the check row's name in the fast path: `tmp-cleanliness`.
7. the test's own lines: `test-tmp-cleanliness: a row cleans up after itself, never mints under a literal
   /tmp, and the suite refuses a full machine`, `  ok   - <row> removed the scratch it made under the TMPDIR
   it was given`, `  FAIL - <file>:<line> roots its scratch at a literal /tmp (<shape>)`,
   `test-tmp-cleanliness: refused(no_binary): no wa binary (WA_BIN) to run the rows with; ...`,
   `  resolved  <file> no longer roots a temp family at /tmp - delete its DEFERRED entry`.

## Not verified, and known gaps

* **The nine DEFERRED gate rows were not TMPDIR-ised.** They mint one directory under `/tmp` and remove it in
  a `trap`, so they leak nothing; moving them under the runner's parent dir is a change to nine rows that only
  the full gate runs, and I did not run it. The test names all nine on every run.
* **`scripts/test-mission-amend-resume.mjs` reports `rc=1` in my isolated per-row harness** (`mission: no wa
  to resume with: neither env nor PATH names one`) - the row needs `WA_BIN` inside the shell its own fixture
  builds, which my harness does not reproduce. It is not a regression from this change: the leak it used to
  leave and its cleanup path were measured with it, and the fast path sets the same variable (`scripts/fast.sh`,
  `check mission-amend-resume`).
* **One failure in my baseline run: `scripts/test-graph-quarantine-evidence.lua` HUNG** (the watchdog killed
  its group at 120 s) while three suites ran on 16 cores. Standalone, with the `graph` component installed in
  the row's own home, it passes in seconds (`graph quarantine evidence ok: 2 copies kept ...`). I did not
  reproduce it on base: my diff touches neither that row, the watchdog nor the runner's timing.
* **`scripts/test.sh` (the full gate) was not run.** My rows' wiring into it is one `gate_run` line, and the
  same test passes standalone with `WA_BIN` set; the gate's own exit is not claimed here.
* **Other sessions' `/tmp` traffic is not attributable to this tree** (`wa-eval-*`, `narrow*`, `fastkeep*`);
  the map says so rather than counting it as this suite's.
