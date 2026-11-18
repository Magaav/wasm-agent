# REPORT — round 2: liveness is the node's run, not the launcher's pid

Branch `change/mission-fabric`, base `origin/main`, worktree `/home/victor/Work/missions/mission-fabric/wt`.
Round 1 head was `84a195c0`; this round adds one commit (`f619e127`) and this file.

## What changed

| file | what it is |
| --- | --- |
| `scripts/mission.sh` | `start` now refuses on the **node's** word: the session list (`wa sessions`), the run lease (`wa steer <id> --status --json`) and the boot lease (`resources/claims.sqlite` + a `BEGIN EXCLUSIVE` probe on `resources/<boot>.lease.sqlite`), matched to the mission by the title its prompt gives it. `run.lock` is owned by that run, taken before the CLI asks for a session and released when the node says the run settled; `status` reports `run: active/stale/released/unknown` from the node and prints the CLI pid as `launcher` **saying it is not liveness**; `verify`/`clean` refuse on `active`; `--force` never kills and never cancels. A fourth read - the node's `session_presence` row and the cwd of the process it names - catches the writer the mission never recorded (below). |
| `scripts/test-mission.sh` | the fixture, rebuilt around a stub `wa` whose **CLI exits rc=1 while the node keeps the run**, plus a synthetic claim store with one held and one free boot: **98 checks**. |
| `docs/MISSIONS.md` | the file table (`run.lock`, `lease.log`, `run.pid` as evidence only), the launch rule with the three reads and the order they combine in, the `status` rule, and two rows in the measurements table. |

Nothing else was touched: no Rust, no Lua, no daemon, no `README.md`, no `AGENTS*.md`. `scripts/fast.sh` is changed by ONE line that round 1 added - `check mission bash scripts/test-mission.sh` - and nothing else.

## The rule, and the measurement behind each part

`start` refuses while a session this mission owns is **unfinished and recently active**, and it names the
session id. Four measured facts decide how:

1. **The CLI's exit is not the run's end.** Session 830fa92f printed `provider_stalled` and its CLI exited
   rc=1 while the node-side run kept writing; the relaunch from that rc made two writers. So no decision
   is taken from `run.pid`. `run.pid` survives as evidence and as the one narrow thing it can prove: a
   launcher that has not yet named its session (the few hundred ms after a launch).
2. **The run lease says whether a run is in flight.** `wa steer <sid> --status --json` answers
   `target.state = active|settled|failed|cancelled|unknown` with a `run_id`. Measured active on this
   session (984e43d4) and settled on 830fa92f, same shape, rc 0 for both.
3. **`updated_at` is the run's START, not recency** (measured by the other session on this mission,
   18/11: `state=active`, `updated_at` 1533 s before now, on a run 25 minutes in; a settled session
   answered 1315 s old). So an age window may never be what *releases* a run. My first implementation did
   exactly that and called my own live run `stale` after 969 s; the live tree is what caught it
   (`status` on the real mission-fabric dir).
4. **The boot lease says whether the owner still exists.** `claims.sqlite` maps `session:<id>` -> boot,
   and the process serving a boot holds `BEGIN EXCLUSIVE` on `resources/<boot>.lease.sqlite` for its whole
   life (`rust/wa-capabilities/src/resources.rs`, `lease_released`: "a claim is only reclaimed when the
   owner is provably gone"). A lock the probe can take is an owner that exited; a locked one is an owner
   that has not. The probe is a read: `BEGIN EXCLUSIVE; ROLLBACK;` writes nothing.

Combined, in `mission_run()`:

| run lease | boot lease | verdict |
| --- | --- | --- |
| active | held | **active** — refuse, at any age |
| active | taken (owner exited) | **stale** — refuse; `--force` may pass a leftover row |
| active | cannot tell | **active** — refuse: nothing can show the owner is gone |
| settled / failed / cancelled / unknown | any | **released** |
| no row | — | the session list: unfinished within `MISSION_ACTIVE_SECONDS` (300) refuses; unfinished and quieter is reported, not obeyed |

**A writer the mission never recorded.** The brief says "matched by mission name and worktree", and the
worktree half cannot come from a title: a session the harness started (not `stage`/`start`) has the brief as
its title, no `run.lock` and no log line. The node does name the process: `session_presence` in
`~/.wasm-agent/memory.db` holds `session_id, pid, boot, heartbeat_at`, and `/proc/<pid>/cwd` is the directory
that process works in - the runner cds to the mission dir before it starts the CLI, so a session working for
this mission has the mission dir or its worktree as its cwd. So whenever the **recorded** session has settled,
`mission_run` also asks who else is working here. Measured on this node, 18/11, minutes apart, same mission:

    # before this read (the recorded session was the only one asked about)
    run        released: the node says run 9e7e5f04-... is failed (1588s ago, session 1321429d-...): no writer is left

    # after it - the same facts, plus this session, which was writing in that very directory
    run        active: session 6cdf7ddf-...: the node records pid 1758185 serving it, that process's cwd is
               /home/victor/Work/missions/mission-fabric - this mission's own directory - and its last
               heartbeat was 0s ago, so a launch now is a second writer in .../mission-fabric/wt
    writer     6cdf7ddf-... (the session the node shows working in this mission's directory)

`wa sessions 12` agreed (6cdf7ddf: `unfinished`, 0s ago). `start` refuses on that verdict, which is the whole
point: the mission dir recorded 1321429d as *failed*, and before this read a relaunch would have gone ahead
next to a live writer - the 18/11 failure again, from the other direction. A row whose pid is gone is not a
writer (measured: pid 1753301, `readlink /proc/1753301/cwd` empty), and a process that is up but quiet for
longer than the window reads `stale`, so `--force` may pass it.

**Matching the session to the mission** is the second half of the brief. `stage` now writes
`mission <name> in <wt>` as the **first line of `prompt.md`**, and the node shows a session's first line as
its title (`lua/core/memory.lua` `title_from`: furniture stripped, 60 chars, then an ellipsis). So a
session is found by the title the node prints, with no launcher and no log: the fixture proves it with an
`orphan` mission that has no `env`, no lock and no log line. The second way is the id in `run.lock`, then
in `err.log`.

**`--force`**: there is no `wa` verb that cancels a run (`wa help` lists none, and `lua/core/steering.lua`
has no CLI door for `finish`), so force cannot mean "cancel and go". It skips the local launcher check and
a lease the node itself reports as a leftover, and it **refuses** in the face of a run the node reports
active — with a message that says exactly that, instead of pretending to cancel something.

## Verified — what I ran

| command | result |
| --- | --- |
| `bash -n scripts/mission.sh scripts/test-mission.sh` | syntax ok |
| `bash scripts/test-mission.sh` | **`mission fixture: 98 checks ok`** (exit 0) |
| `bash scripts/mission.sh status mission-fabric` (the real node, read-only) | `run active: session 984e43d4… the node's run a2159868… is in flight and held boot ec7281c1… is serving the session now (last boundary 1090s ago)` — the case a pid or an age window gets wrong |
| `bash scripts/mission.sh status mission-fabric` **before** the presence read (live node, read-only) | `run released: the node says run 9e7e5f04-... is failed (1588s ago, session 1321429d-...)` - correct about that session, blind to the second writer |
| `bash scripts/mission.sh status mission-fabric` **after** it (live node, read-only) | `run active: session 6cdf7ddf-...: the node records pid 1758185 serving it ... its last heartbeat was 0s ago` + a `writer` line - `start` now refuses |
| `node scripts/check-deploy-docs.mjs` | `deploy docs check ok (6 checks)` |
| `node scripts/check-instructions.mjs` | `PASS (79 checks, 232 files)` |
| `bash scripts/fast.sh` (this tree, binary built from it) | **253 checks, 12 failed, 0 skipped, 117 s**; `fast: mission ok (2560ms)` |
| `bash scripts/fast.sh` (base worktree `/tmp/mf-base` at `origin/main` `74d48431`, its own binary) | **252 checks, 13 failed, 0 skipped, 216 s** - the same 12 reds, plus `landing-queue` |

The fixture's cases, each one an assertion that fails if the mechanism goes away:

1. `stage` writes the marker as the prompt's first line, the runner takes `run.lock` and logs to
   `lease.log`, nothing uses `pkill -f`/`pgrep -f` (comments stripped first, as in round 1);
2. a launch the node settles: `done` carries rc=0, the id is read from **stderr**, `lease.log` has
   `take`/`bind`/`cli-exit`, `status` says `released` and **releases the lock itself** (`by=status`);
3. **the required case** — the CLI exits rc=1 while the node keeps the run (its steer row active, its boot
   claim held): `done` keeps rc=1, `status` says `active` and names the session, the lock stays, `launcher`
   says in the line that it is not liveness, a second `start` **refuses with the session id in the
   message**, `--force` refuses too, and `verify`/`clean` refuse;
4. the node settles: `status` says `released`, the lock is gone, `lease.log` has `by=status`, and a launch
   is allowed again (announced as a new session, not a resume);
5. a steer row left active by a process that exited (claim points at a boot whose lease is takeable):
   `stale`; `start` refuses, `--force` passes it and `lease.log` says what it stepped past;
6. a node whose claim store cannot be read, with `updated_at` 1533 s old: **`active`**, not `stale` — the
   regression test for the `updated_at` measurement;
7. a legacy mission (`out.log` line, no `env`, no lock) and an `orphan` mission matched **only by the
   node's title**;
8. **the writer nobody recorded** (added after the live read above): a process whose cwd is the mission dir
   and whose presence row has a fresh heartbeat makes `status` say `active` and name that session, makes
   `start` and `start --force` refuse, and is printed as `writer` beside the session the mission records; the
   same pid quiet for 4000 s reads `stale` and refuses without `--force`; the same row with a dead pid refuses
   nothing and a launch goes ahead. 14 of the 98 checks.
9. commits/dirty/verify/report/clean, and the dirty-worktree refusal, kept from round 1.

## The fast path — once on this tree, once on the base

Same command, same node, one after the other (never at once), and in both cases the tree's **own** binary,
built by `fast.sh` itself (`cargo build --release --offline`, code-mode assets included):

| tree | head | banner | result |
| --- | --- | --- | --- |
| `…/mission-fabric/wt` | `f619e127` (`change/mission-fabric`) | `build f619e127c73b, tree f619e127c73b, fresh: built from this tree`, sha256 `890f3694` | **253 checks, 12 failed, 0 skipped, 117 s** |
| `/tmp/mf-base` (a `git worktree add --detach` of `origin/main`) | `74d48431` | `build 74d4843190c4, tree 74d4843190c4, fresh`, sha256 `aa9cc109` | **252 checks, 13 failed, 0 skipped, 216 s** |

Round 1 never got past `stale_binary` here (the installed `wa` is build `2e6fab41`, not this tree) and ran
with `WA_FAST_ALLOW_STALE_BINARY=1` instead. This round built the tree's binary, so no row graded another
commit, and the base run did the same for `origin/main` - a base worktree with its own
`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-mission-fabric-base`, so neither run could overwrite the
other's binary.

**The row this change adds is green: `fast: mission ok (2560ms)`** (253 checks on this tree against 252 on
the base: `landing-queue` stops at its first failing check on the base, see below).

Both runs above were made at `f619e127`, before this round's second commit (`66b47044`, the presence read).
That commit changes `scripts/mission.sh`, `scripts/test-mission.sh` and `docs/MISSIONS.md` only, and the row
those files feed is re-run below it directly: `bash scripts/test-mission.sh` -> **98 checks ok**, plus
`node scripts/check-instructions.mjs` -> `PASS (79 checks, 232 files, 10 deferred, 0 allowed)` and
`node scripts/test-orphan-tests.mjs` -> `orphan-tests ok (195 wired, 47 orphaned and declared with a reason)`.
The full 253-check run is not repeated for it: no row outside `mission` reads those files.

### Every red, classified against the base

| row | this tree `f619e127` | base `74d48431` | why it is not this branch's |
| --- | --- | --- | --- |
| 8 Lua rows: `test-observability`, `test-remote-call-shape`, `test-skill-discovery`, `test-orchestration-mode`, `test-prompt-cache`, `test-codemode-model-boundary`, `test-wave-closure-reporting`, `test-host-return-docs` | FAIL | FAIL, same 8 rows | prompt/tool-surface drift that already sits on `origin/main` on this node. This branch changes no Lua: `git diff --stat origin/main...HEAD` is two shell scripts, one doc, one `fast.sh` row and `REPORT.md`. The `change/green-main` mission exists for exactly these rows. |
| `prompt-docs` | FAIL | FAIL, identical text | `docs/ENVELOPE.md: tool-catalogue` is stale; the fix is `scripts/sync-prompt-docs.sh --write`, a generated-doc regeneration this branch does not touch. |
| `fast-binary` | FAIL, the same three assertions | FAIL, byte-identical shape | `- the installed binary is found, got source=tree` and `a fresh tree binary is used, got action=refuse (… WA_FAST_SKIP_BUILD=1 forbids building one)`: the row expects the *installed* `~/.local/bin/wa` to be the fallback, and the mission's own `CARGO_TARGET_DIR` puts a tree binary in the build root instead. Same input, same verdict on both trees. |
| `publish-artifacts` | FAIL | FAIL, same cause | `the commit holds 'node-<sha>.manifest PUBLISH.sh SHA256SUMS …', expected exactly 'PUBLISH.sh SHA256SUMS …'` - a sort-order/locale difference in the fixture, with the commit hash substituted on each tree. |
| `land-signing` | FAIL | FAIL, same text | `WA_RELEASE_SIGN_DEFER=1` and no release-key vault on this node: `…/fixture/scripts/lib/build-target.sh: No such file or directory`. Environment, named in round 1 and in the `change/green-main` measurements. |
| `landing-queue` | **pass (6355 ms)** | **FAIL** - `git rev-parse --verify -q HEAD~5^{tree} failed in /tmp/mf-base` | the base's red only, and it is a shallow-clone artefact: this repository is **shallow** (`git rev-parse --is-shallow-repository` = true, `.git/shallow` holds graft points) and `74d48431` is 5 commits from a graft boundary, so its `HEAD~5` does not exist. The branch has 9 commits and the row passes. Nothing in this branch makes it pass - history does. |

So: **12 reds on this tree, all 12 red on the base in the same row, none of them on a file this branch
touches, and the one row this branch adds is green.** The base's thirteenth red is the shallow clone, not
the code, and the branch passes that row anyway.

## Not verified, and not done

- **No mission was launched through `mission.sh` against the real `wa` in this round.** The six verbs and
  the new refusal ran end to end against the stub node in the fixture; `status` was run against the real
  node read-only, which is where the `updated_at` hole was found. What is unproven: that the real CLI
  prints `wa: session <id> ok` early enough for the runner's bounded wait (30 s) on a slow start —
  the fixtures and the mission dirs' own `err.log` show the line and its position, not its timing.
- **The `held`/taken probe and the presence read WERE exercised against the live node in this round**
  (`status mission-fabric`: `boot free no claim is recorded for this session` for the exited 1321429d, and
  `active ... pid 1758185 ... cwd .../mission-fabric` for the live 6cdf7ddf). What was the other session's,
  and is quoted, is the eight-claim census (five held / three free). The old note said: The measurement it
  rests on (five held / four held out of seven claims, and the free ones exactly the long-unfinished
  sessions) is the other session's, quoted above with its command; the fixture reproduces the mechanism
  with a real exclusive lock held by `sqlite3` on a fifo.
- **`--force` does not cancel a run, because no `wa` verb does.** If a node-side run is wedged and never
  settles, this script leaves it alone and says so: it will refuse until the node reports the run settled.
  Whether a cancel door should exist is a harness decision, not a mission-script one.
- **No push, no deploy, no update.** The brief forbids pushing; the commit is local.

## Provenance — this round reproduced the failure it fixes

Two sessions ran this mission in this worktree at once, and one overwrote the other's file. Measured:

- `984e43d4` (this session) wrote `scripts/mission.sh` at 13:05:02Z; `1321429d` had edited it at
  13:00-13:04Z and lost those edits — its steering note at 13:06Z says so, and I did not merge them, I
  restarted from my own version after six `provider_stalled` runs;
- `wa sessions` listed **both** as `unfinished` under this branch's title;
- `wa steer 984e43d4 --status --json` answered `state=active` for a run that a `run.pid` rule would have
  called finished hours earlier.

The division that ended it: this session owns `scripts/mission.sh`, `scripts/test-mission.sh`,
`docs/MISSIONS.md`, `REPORT.md`; the other session keeps `scripts/mission-lease.sh` (untracked, its probe)
and runs read-only checks against the commit. `f619e127` contains only my four paths — `mission-lease.sh`
was never `git add`-ed, so it is not in the commit.

Its measurement corrected my rule, which is the point of writing it down: my first version would have
answered `released` for a live run 25 minutes in (fact 3 above), and the fixture's case 6 is that
correction as a test.

## Round 2, continued: the second writer came back, and a fixture wedged two shells

I took this worktree at `f619e127` (14:07:50Z) with `REPORT.md`, `docs/MISSIONS.md`, `scripts/mission.sh`
and `scripts/test-mission.sh` modified and `scripts/mission-lease.sh` untracked. Session `6cdf7ddf` was
live on **this same mission** (its own title, 160 messages, `wa steer --status` `state=active`), committed
`66b47044`, `eaedce61` and `dc3f9698` between 14:07 and 14:10, and settled at 14:10:57Z. This session
added `70e8f910` (the fixture must exit) and `85bd759d` (the doc's fourth read and this incident) on top.

### Measured: the tree was held from a session that had already stopped writing

- two `bash -c` shells of `6cdf7ddf` (pids 1958498 and 1963342, started 14:03:28Z and 14:04:13Z) were
  still alive five to six minutes later, each with a child `tail -3` / `tail -2` blocked on a pipe;
- the first one's command line ends with `cp /tmp/mission.bak scripts/mission.sh`. `scripts/mission.sh`
  carries mtime 14:08:32Z and its md5 equals `/tmp/mission.bak`'s;
- at 14:07:50Z `git diff --stat` read `REPORT.md 235`, `docs/MISSIONS.md 12`, `scripts/mission.sh 66`,
  `scripts/test-mission.sh 44` changed lines. At 14:10:20Z `git status` listed **only** the untracked
  `scripts/mission-lease.sh`. Those 66 + 44 lines are gone: `git fsck --lost-found` holds three dangling
  blobs (all `wa-vault` sources) and no shell script, so nothing was staged and nothing is recoverable.
- they were wedged because the fixture's presence case leaves `( cd demo && exec sleep 600 )` holding the
  caller's stdout: the fixture prints `FAILED` and exits, and the pipe stays open until that sleep ends.

So the round-2 failure reproduced itself one level up: not two launchers of the mission, but a settled
session's leftover shells writing into the tree eight minutes after the node said its run was over. The
lock in `mission.sh` covers the mission's own launches; nothing covers a harness shell that outlives the
turn that started it. The lesson is the one `AGENTS.md` already states and this round paid for: long work
goes into a supervised operation, and a busy tree belongs to one session at a time.

### Fix (`70e8f910`): a fixture that fails must exit

`scripts/test-mission.sh`: the presence child no longer inherits the caller's stdio, and `cleanup` kills
every child it started (`KIDS`) and every `run.pid` a launch left behind.

| measurement | before | after |
| --- | --- | --- |
| piped run of a **mutated** fixture (`node_presence` forced to `return 2`) | `rc=124` at a 20 s cap, after printing `FAILED` | ends in **2 s**, `FAILED` is the last line |
| piped clean run, `bash scripts/test-mission.sh \| cat` | n/a | **98 checks ok in 7 s** |
| `bash scripts/test-mission.sh` | 98 checks ok | 98 checks ok |

The mutation also proves the fixture bites: with the presence read gone it fails at
`a live process with the mission dir as its cwd must read active, got: 'released ...'`.

### `scripts/fast.sh`, once per head, and the base

| tree | head | result |
| --- | --- | --- |
| this worktree | `dc3f9698` (binary `sha256 05221837`) | **253 checks, 12 failed, 0 skipped, 168 s**; `fast: mission ok (3867ms)` |
| this worktree, after the fixture fix | `85bd759d` (binary `sha256 56a97ac2`) | **253 checks, 12 failed, 0 skipped, 124 s**; `fast: mission ok (3819ms)`, `landing-queue ok (7352ms)`, `orphan-tests ok`, `instructions ok` |
| `/tmp/mf-base` at `origin/main` `74d48431` (previous run, its own target dir) | `74d48431` | **252 checks, 13 failed, 0 skipped, 216 s** |

The 12 reds of the final run are the base's 12, row for row: the 8 Lua rows (`test-observability`,
`test-remote-call-shape`, `test-skill-discovery`, `test-orchestration-mode`, `test-wave-closure-reporting`,
`test-codemode-model-boundary`, `test-prompt-cache`, `test-host-return-docs`), `prompt-docs`, `fast-binary`,
`publish-artifacts` and `land-signing`. The base's thirteenth is `landing-queue`, which passes here (7352 ms)
and fails there on a shallow-clone artefact (`git rev-parse --verify -q HEAD~5^{tree} failed`). The
classifications in the table above are unchanged: nothing this branch touches is in that list.

### This round's live reads against the node (read-only)

| command | result |
| --- | --- |
| `scripts/mission.sh status mission-fabric` at `dc3f9698` | `run active: session f40a50b8-...: the node records pid 1976318 serving it, that process's cwd is /home/victor/Work/missions/mission-fabric - this mission's own directory - and its last heartbeat was 1s ago, so a launch now is a second writer in .../wt`, plus `writer f40a50b8-...` and `boot free no claim is recorded for this session` |
| `scripts/mission.sh start mission-fabric` and `--force` | `rc=1`, `mission: not staged: /home/victor/Work/missions/mission-fabric/env missing` - see the gap below |
| `wa steer 6cdf7ddf --status --json` | `state=active` at 14:08Z, `state=settled` at 14:10:57Z - the same session, its run ending while its shells kept writing |

**The gap this exposes, unchanged this round:** every mission on this node was staged by the old
hand-written `run.sh`, so none has an `env` file, and `start` refuses them on that **before** it asks the
node anything. `status` reads such a mission fine (it derives worktree, branch and base from `wt/`), so the
liveness verdict above is real - but `start` does not name the session for a legacy mission, and it cannot
launch one either: the legacy `run.sh` predates the lock protocol, so refusing is correct and re-staging is
the fix. Folding the verdict into that refusal message is a two-line change for the next round.

### Not done

- **No real launch.** I did not run `start` against a staged mission, so the launch path is still proven
  only against the stub node (98 checks). I deliberately did not run `start` on the real mission either:
  it stops at the missing `env` (above), and a *probe* mission dir would lose the cwd match that makes the
  verdict `active` and would then launch a real second writer into this worktree. Refusing to take that
  risk is the whole point of the mission.
- **`--force` was not exercised against the live node**, only in the fixture (a stale lease passes it, a
  live writer does not).
- **The lost edits are not reconstructed.** The 66 + 44 uncommitted lines reverted at 14:08:32Z are gone;
  what landed instead is the peer's own commits plus this session's two.
- **`scripts/mission-lease.sh` stays untracked and unused.** `mission.sh` carries the whole lease
  implementation (session list, run lease, boot lease, presence row); this file duplicates it under
  different function names and nothing sources it. It is left in place as the other session's evidence.
- **Four empty directories from an experiment** sit in the mission dir (not the repo) since 10:02:
  `== lease file:`, `MISSION=demo`, `RUNNER=999999necho`, `WORKTREE=`. Left for the operator to remove.
- **No push, no deploy, no update**, as the brief requires.
---

# REPORT — round 3: land after fixes: "cannot tell" is never free, and two starts make one launch

Review of round 2. Same worktree (`/home/victor/Work/missions/mission-fabric/wt`), branch
`change/mission-fabric`, head `d25e64a2`. This round touches `scripts/mission.sh`,
`scripts/test-mission.sh`, `docs/MISSIONS.md` and deletes one untracked file. Code only here, on
this node; no push, no deploy.

## The six items

| # | what was wrong (review round 3) | the fix | the fixture check that bites |
| --- | --- | --- | --- |
| 1 | `wa sessions` printing nothing leaves `mission_run` at `unknown`; the `*)` branch of `start` did nothing without `--force`, and step 2 only refuses while the launcher pid lives - which, for the measured launch, it did not | `unknown` REFUSES and names the recorded session; `--force` passes it only when `MR_SESSION='-'` (no session was ever recorded, so there is nothing to duplicate). The other half of "cannot tell" needed a new fact: a node that ANSWERED and lists nothing for this mission (`NODE_ANSWER`) is `released`, which is why a fresh mission's first launch still launches | `start must refuse when the node cannot be asked`, and the `--force` twin (mutant `m1`) |
| 2 | unfinished + quiet > 300 s + a boot lease still HELD read `stale`, and `--force` released it - the comment in the tree already recorded a live run quiet 969 s | a held boot lease is `active` at ANY age, in both places that read one - the session list (`mission_run`) and the presence row (`writers_check`) - and `stale` only when the probe can TAKE the lease, which is the owner saying it exited | `a quiet presence row whose boot lease is held must read active` and `a quiet session whose boot lease is held must read active` (head `d25e64a2` and mutant `m2`) |
| 3 | `node_boot_lease` answering `unknown` (no `sqlite3`, no store, an unreadable one) ended `released` in the session list's unfinished branch | every `unknown*` maps to `active` - the same refusal `mission_run` already spelled out for the run lease | `an unfinished session with no age and an unprobeable lease must read active` and its quiet twin (mutant `m3`) |
| 4 | no lock around check+launch; `run.lock` was written with `>` by each launcher | `mkdir $M/start.lock` is atomic and is held until the launch has a `run.pid`; it is removed then and by a trap, and the loser refuses naming the holder's pid. `--force` does not step past it either: the launch it would race is already in that window | `two starts 100 ms apart must make ONE launch`, plus a planted lock refused with and without `--force` (mutant `m4`: "made 2") |
| 5 | `scripts/mission-lease.sh` untracked, unused, its header claiming `mission.sh` sources it, and 1800 s where this script uses 300 s | deleted. It was never referenced by anything (`rg -n mission-lease` finds only REPORT.md), and its second copy of the lease logic is the one that would drift. The file is kept OUTSIDE the repo, so it is still recoverable: `/home/victor/Work/missions/mission-fabric/round2-mission-lease.sh.txt`, 249 lines, `sha256 9f143ecbda43ebaf738d921dc40b19dc25c353ed4d55e035af464366d7f86549` | the tree no longer carries it (`git status`) |
| 6 | the session id read out of the log went into SQL | `session_id_ok`: 36 characters of `[0-9a-f-]` and nothing else. It is enforced where the id becomes SQL (`node_boot_lease`) and at both read points (`recorded_session`, and the runner before it writes the id into `run.lock`) | `the reason is the id: it never becomes part of a query` (mutant `m6`) |

## Before and after, measured

The fixture takes `MISSION_UNDER_TEST` so a saved script runs the same 146 checks. Each mutant reverts exactly
one rule of the new script; the head is the round-2 script.

| script under test | first failing check | verdict |
| --- | --- | --- |
| head `d25e64a2` | `a quiet presence row whose boot lease is held must read active, got: 'stale: session aaaaaaaa-...: pid ... still has .../missions/demo as its cwd but its last heartbeat was 4000s ago (> 300s)` | item 2 |
| `m1` - `unknown` no longer refuses | `start must refuse when the node cannot be asked` | item 1 |
| `m2` - held lease back to `stale` | `a quiet presence row whose boot lease is held must read active, got: 'stale: ... and held boot boot-held'` | item 2 |
| `m3` - `unknown*` back to `released` | `an unfinished session with no age and an unprobeable lease must read active, got: 'released: ... and unknown no readable ...'` | item 3 |
| `m4` - no start lock | `two starts 100 ms apart must make ONE launch, made 2` (and the loser's own `start.lock/pid: No such file or directory` - there was no lock to name) | item 4 |
| `m6` - no id validation | `and the reason is the id: it never becomes part of a query: 'not a session id' not in: active: ... unknown the claim store could not be read` - the injected id reached SQL and broke the query instead of being refused | item 6 |
| `scripts/mission.sh` (this round) | - | `mission fixture: 146 checks ok` in 7.0 s (98 before this round) |

The same hole measured outside the fixture: two starts launched in the same breath, ten times, against a stub
node (scratch repo, scratch node home, `wa` stub that answers `sessions` with a note line and a `chat` that
prints its id and exits). Round 2's script: `both launched: 10/10`. This round's: `both launched: 0/10`,
and the pair printed in one sample says which lock stopped the loser (`another 'start' of p1 is in this moment
checking the node and launching (pid ... holds .../missions/p1/start.lock)`).

Two things the fix needed that the review did not name, both found by running it:

* **the empty-pid instant.** Between `mkdir start.lock` and the holder writing its pid there is a window in
  which the directory exists and `pid` is empty. The first version read that as "no holder alive", removed
  the winner's lock and took it - two launches again, by a narrower road. The loser now waits up to 1 s for the
  pid before it calls the directory a leftover.
* **a run lease that answers `unknown` is also "cannot tell".** It sat in the `settled|failed|cancelled|unknown`
  branch, i.e. released, which is item 3's mistake one read over. It now goes to the same place every other
  unreadable answer goes: the boot lease decides, held = refuse.

## `scripts/fast.sh`, once

| tree | head | result |
| --- | --- | --- |
| this worktree | `d25e64a2` + this round's three files, binary `sha256 56a97ac2` (build `85bd759d3de4`, named with `WA_BIN`) | `253 checks, 13 failed, 0 skipped, 115 s`; `fast: mission ok (5742ms)`, `landing-queue ok (5792ms)`, `instructions ok`, `orphan-tests ok`, `direct-workflow ok` |

The binary could not be built here: `rustup` has no default toolchain ("rustup could not choose a version of
cargo to run"), so `fast.sh` stopped with `stale_binary` instead of grading another commit. I named the
binary explicitly rather than pretending it is fresh, and checked what that costs: between its build commit
`85bd759d` and this head `d25e64a2` the ONLY changed path is `REPORT.md` - `git diff --name-only
85bd759d d25e64a2 -- rust lua modules` is empty. The banner says `explicit: named by WA_BIN (build
85bd759d3de4)` on every run, and the `fast-binary` row is red for its own reasons (below).

### Every red, classified

The 12 reds that are not new are the ones round 2 measured on the base `origin/main 74d48431` (its run: 252
checks, 13 failed), and none of them reads a shell script:

* 8 Lua rows - `test-observability`, `test-remote-call-shape`, `test-skill-discovery`, `test-orchestration-mode`,
  `test-prompt-cache`, `test-codemode-model-boundary`, `test-wave-closure-reporting`, `test-host-return-docs`
  - all prompt/instruction assertions of the harness, untouched by this branch;
* `prompt-docs` (stale generated blocks: `sync-prompt-docs.sh --write` would rewrite docs this round does not own);
* `fast-binary` - the row tests the stale-binary refusal itself, and with no buildable cargo it fails on its own
  fixture (`build 85bd759d3de4 is not this tree (7b3492f12a72); WA_FAST_SKIP_BUILD=1 forbids building one`);
* `publish-artifacts` (manifest entry order in the signed artifact) and `land-signing` (`WA_RELEASE_SIGN_DEFER=1`,
  no signature on this host).

`landing-queue` is red on round 2's base and `ok` here (5792 ms).

`onebuild` is the thirteenth and it is NEW to this list, so I did not take it on trust: it fails with
`onebuild: assert failed - tree A builds through the resolver ... build-target.sh: line 434: cargo: command not found`,
and I reproduced it on a fresh detached worktree of `origin/main 74d48431` (`git worktree add --detach
/tmp/mf-r3-base origin/main`): the same assert fails with the same `cargo: command not found`. It is this machine's
missing toolchain, not this branch. (The row should probably be a SKIP when cargo is absent - it is not, and
that is where a failure and an environment limit get confused.)

## Not done, and not verified

* **No real launch.** `start` is still only exercised against the stub node (146 checks). Every mission on
  this node was staged by the old hand-written `run.sh` and has no `env` file, so `start` refuses them
  before it asks the node anything; a probe mission dir would lose the cwd match that makes the verdict
  `active` and would then launch a real second writer into this worktree. Refusing to take that risk is what
  the mission is for.
* **The start lock's window is measured, not bounded.** `start` holds it from `mkdir` until the launch has a
  `run.pid`; on this idle machine that is under 100 ms (two starts 100 ms apart did not overlap), which is why
  the fixture slows the generated runner by 300 ms to make the exclusion deterministic - the same window a
  loaded machine produces. A pair launched in the SAME breath was the real measurement: 10/10 double launches
  before, 0/10 after.
* **`--force` against the live node** was not exercised; only in the fixture (a stale lease passes it, a held
  lease, a live writer, a start in flight and an unanswerable node with a recorded session do not).
* **The four empty directories** left in the mission dir by a round-2 experiment are still there (not the
  repo): `== lease file:`, `MISSION=demo`, `RUNNER=999999necho`, `WORKTREE=`.
* **No push, no deploy, no update**, as the brief requires.
# REPORT — round 4: simplify — one answer, one lock, and a refusal that names the command

Branch `change/mission-fabric`, base `origin/main`, worktree `/home/victor/Work/missions/mission-fabric/wt`.
Round 3 head was `3a256a6f`; this round is one commit on top of it. The round 2 and 3 reports moved here
from `REPORT.md` in the worktree root (`git mv REPORT.md docs/missions/reports/mission-fabric.md`): the
repo now keeps a branch's mission report beside the other reports, and `mission.sh status` reads either
path.

## What changed

| file | what it is |
| --- | --- |
| `scripts/mission.sh` | `start` has NO `--force` and ONE permitting answer. It launches only when no launcher is alive, no process the node records works in the mission directory, and the node says every session of this mission is settled; every other state refuses with `mission: refusing [<state>]: <reason>` and `mission: clear it by hand: <command>`. One start at a time is `flock -n` on `$M/start.flock`, held until the launch has a `run.pid`. `writers_check` asks one question (does that pid still have this directory as its cwd) and `mission_run` has one decision (a run lease of `settled`/`failed`/`cancelled`, or nothing settled). The `MISSION_ACTIVE_SECONDS` window is deleted. |
| `scripts/test-mission.sh` | the four states the round-3 review found, each as a check that must refuse, plus a clean mission that must launch and two starts 100 ms apart that must make one launch: **158 checks** (round 3: 98). Every fixture that only exercised `--force` is gone; two now assert that the flag does not exist. |
| `docs/MISSIONS.md` | the launch rule rewritten as one answer with a verdict table, the reads table without the age window, and a new section **Clearing a stuck mission by hand** (state, what to look at, the exact command). |
| this file | moved from `REPORT.md`, and this section added. |

Nothing else was touched: no Rust, no Lua, no daemon, no `scripts/fast.sh`, no `AGENTS*.md`.

## The rule now (item 1)

`start`, under the lock, in this order:

1. `alive_launcher` - `run.pid` names a live pid whose `/proc/<pid>/cwd` is the mission dir. Refuses as
   `[launcher]`, naming the pid and `rm <mission>/run.pid` as the clear command.
2. `mission_run` - and only `released` passes:

| what the node says | verdict | launch? |
| --- | --- | --- |
| every session of this mission has a run lease of `settled`, `failed` or `cancelled` | `released` | yes |
| the node answered and lists no session for this mission | `released` | yes |
| `session_presence` names a live pid whose cwd is the mission dir or its worktree | `active` | no |
| a run in flight and its boot lease is **held** | `active` | no |
| a run in flight and its boot lease can be **taken** | `stale` | no |
| a run in flight and the boot lease cannot be probed | `unknown` | no |
| `wa steer` answers `none` (no run row) for a session that exists | `unknown` | no |
| `wa sessions` prints nothing | `unknown` | no |

Three simplifications did the work, and each removes a state rather than adding a branch:

* **`stale` refuses.** Round 3 let `--force` pass a leftover. It is a refusal now, with the operator
  command (finish that one session by hand, or `update steering_runs` on that session id, then
  `rm run.lock`).
* **`unknown` refuses, always.** Round 3 kept one exception (`--force` with no session ever recorded).
  Gone: an answer the script cannot get is an answer it cannot act on.
* **the heartbeat age is not asked.** A presence row is a live process with this directory as its cwd, or it
  is not a row at all (`readlink` fails on a dead pid). The age is printed in the reason; it decides
  nothing. `MISSION_ACTIVE_SECONDS` is deleted with it, so there is one fewer tunable to get wrong.

Every refusal goes through one function, so the shape cannot drift:

    refuse() { # <state> <reason> <command that clears it by hand>
      printf 'mission: refusing [%s]: %s\n' "$1" "$2" >&2
      printf 'mission: clear it by hand: %s\n' "$3" >&2
      exit 1
    }

## The lock (item 2)

`flock -n 9` on `$M/start.flock`, `exec 9>>` opened at the top of `start`, closed with
`exec 9>&-` once the launch has a `run.pid`. The launcher is started with `9>&-` so it does not
inherit the lock (otherwise the lock would live as long as the run). The kernel drops the lock when the
holder exits - which is why the `mkdir start.lock` plus dead-owner `rm -rf` and its whole race class
are gone: there is no dead lock to detect, and no clearer to race the taker. A leftover *file* on disk locks
nothing, and the fixture proves that too.

## The four review scenarios, and the two the brief adds (item 3)

Each is a check in `scripts/test-mission.sh` that fails when the mechanism is removed (mutants below):

| scenario | what the fixture does | what it asserts |
| --- | --- | --- |
| a live launcher whose new session is not yet named | plants `run.pid` = a live `sleep 600` whose cwd is the mission dir, `run.lock` with `SESSION=''` | `refusing [launcher]`, the pid in the message, `rm <mission>/run.pid` as the clear command, and no `done` file |
| two starts clearing a dead lock | writes a leftover `start.flock` with nobody holding it, then two starts 100 ms apart | exactly one `started race`; the launch is not blocked by that file |
| unknown with a harness-started writer | `STUB_SESSIONS_FAIL=yes` **and** a `session_presence` row whose pid has the mission dir as its cwd | `refusing [active]` naming that session and directory - the writer, not the silence |
| a starting session with no claim row | a session listed `unfinished`, no steer row, no claim, no lease file | `unknown`, the reason says `STARTING`, and the clear command is `wa steer <id> --status` |
| a clean mission starts | a staged mission, node answering, nothing recorded | `started`, and the `done` marker with its rc |
| two starts 100 ms apart | the runner slowed by 300 ms so the window is deterministic | exactly one launch; the loser names `start.flock` and says there is nothing to clear |

Deleted, because they only exercised `--force`: the two "force passes a stale lease" checks, the "force
passes an unanswerable node with nothing recorded" check, the "force refuses next to a live writer" check, and
the planted-pid `start.lock` pair. Two replacements assert the flag is gone (`start says in as many words
that it has no --force`, and `start takes no flag, not even with a writer in the directory`).

## What I ran

| command | result |
| --- | --- |
| `bash -n scripts/mission.sh`, `bash -n scripts/test-mission.sh` | clean |
| `bash scripts/test-mission.sh` (twice) | `mission fixture: 158 checks ok` in 7 s and 8 s |
| five mutants against the fixture | each caught, with the check that caught it (below) |
| `bash scripts/fast.sh` (toolchain on `PATH`) | `fast path FAILED (11 of 253 checks, 0 skipped, 186s)`; this round's row `fast: mission ok`; all 11 reds reproduced on the base |

Mutants, each a saved copy run through `MISSION_UNDER_TEST`:

| mutant | the check that caught it |
| --- | --- |
| `m5` - no `flock -n` (the exclusivity removed) | `two starts 100 ms apart must make ONE launch, made 2` |
| `m6` - a run row of `none` counted as settled | `an unfinished session with no age and an unprobeable lease must refuse, got: 'released: ...'` |
| `m7` - the `writers_check` read never consulted | `a live process with the mission dir as its cwd must read active, got: 'released: ...'` |
| `m8` - `alive_launcher` never seen | `a live launcher that has not named its session must refuse a launch` |
| `m9` - the `--force` argument accepted again | `start says in as many words that it has no --force: 'no --force' not in: mission: refusing [active]: ...` |

The fast path, with the toolchain on `PATH` (`PATH=$HOME/wasm-agent/toolchain/cargo/bin:$PATH`; the plain
shell on this node has no `cargo`), built this tree's binary and ran the whole path:

    fast path FAILED (11 of 253 checks, 0 skipped, 186s)
    fast: mission ok (7965ms)          <- this round's row
    fast: rust - no crate touched      <- nothing in rust/ changed

All 11 reds are in rows this round does not touch, and each was reproduced on the base: a second worktree
at `3a256a6f` (`/tmp/m4/base`, no round-4 files), the same command, the same `PATH`:

| red | on this tree | on the base (`3a256a6f`) |
| --- | --- | --- |
| `scripts/test-observability.lua`, `test-skill-discovery.lua`, `test-orchestration-mode.lua`, `test-remote-call-shape.lua`, `test-codemode-model-boundary.lua`, `test-prompt-cache.lua`, `test-wave-closure-reporting.lua`, `test-host-return-docs.lua` | fail | fail (identical) |
| `prompt-docs` (`docs/ENVELOPE.md: tool-catalogue` is a stale generated block) | fail | fail (`bash scripts/sync-prompt-docs.sh --check` run alone in the base worktree) |
| `publish-artifacts` (the artifact list's order in the commit) | fail | fail (identical) |
| `land-signing` (`WA_RELEASE_SIGN_DEFER=1`, nothing to publish) | fail | fail (identical) |
| `session-liveness` | **ok** (125 ms) | fail (`owner_stale: ... presence heartbeat is 4001s old`) |

The base reports 12 of 253 and this tree 11 of 253: the one row that failed only on the base,
`scripts/test-session-liveness.mjs`, is untouched by this round (no JS, no Lua changed), so it is flaky on
this machine and not something this round fixed. Everything else is pre-existing and named here so the next
round does not have to rediscover it.

## Not done, and not verified

* `verify` and `clean` still refuse only on `active`. `stale`/`unknown` are refused for a *launch*,
  not for a cleanup: `clean` is how a leftover mission is retired, so making it refuse a leftover would
  leave no way out. That asymmetry is deliberate, and it is the one place where a state does not refuse
  everything.
* The `update steering_runs` recipe is the last resort and is named as such in the docs. I did not run it
  against the live node; this round wrote nothing to `~/.wasm-agent`.
* The presence read has a hole the other session on this mission measured live while the round was open (its
  section below, and the row it added to the measurements table): a turn served by the node's own process
  (`wa serve`, pid 616163) writes in this worktree while `session_presence` names a pid whose cwd is never
  the mission's, so `writers_check` reports no writer while one is writing. My fixtures model the CLI's exit,
  not the server's own turn, and this round does not fix it. What the gate still guarantees is narrower than
  "no second writer": no launcher alive, no *mission-cwd* process, and every session of this mission settled
  on the node's word at the moment of the check.
* `mission.sh status` reads `REPORT.md` in the worktree root first, then
  `docs/missions/reports/<name>.md` (the second path is new, and the fixture's demo mission checks it).
  `report` still quotes only `REPORT.md`.


## Independent verification (session a8fcaf0d), and a second writer measured live

Everything below was run on this worktree on 18/11 between 13:19 and 13:46 against the committed tree
`fd751adb`, by a session other than the one that wrote the section above; nothing is copied from it.

| check | how | result |
| --- | --- | --- |
| the fixture passes, and still exits through a pipe | `bash scripts/test-mission.sh 2>&1 | tail -5` | `mission fixture: 158 checks ok`, returned at once |
| `start` takes no option | `scripts/mission.sh start <name> --force` | `mission: start takes a name and nothing else: there is no --force ...` |
| the lock is what excludes | `/tmp` copy with the `flock -n 9` line removed | FAILED: `two starts 100 ms apart must make ONE launch, made 2` |
| the launcher window is gated | `/tmp` copy with the `alive_launcher` gate skipped | FAILED: `a live launcher that has not named its session must refuse a launch` |
| one gate, not several | `/tmp` copy where every verdict but `released` is permitted | FAILED: `a second start must refuse while the node still runs that session` |
| a session with no run row | `/tmp` copy where the no-run-row branch answers `released` | FAILED: `an unfinished session with no age and an unprobeable lease must refuse` |
| the writer the harness started | `/tmp` copy with the presence read skipped | FAILED: `a live process with the mission dir as its cwd must read active` |

Each mutation is a copy under `/tmp/mf-r4/mut/`, run as `MISSION_UNDER_TEST=<copy> bash scripts/test-mission.sh`:
no file in the tree was edited to produce a red.

### The round's own collision: two writers again, and why the presence read cannot see the second

This worktree had two live sessions at once while the round was implemented, from 13:17 to 13:38:

- the session that wrote the section above (`6a48d01d`). Its CLI printed `wa: session 6a48d01d-... failed`
  into `err.log` at 13:11:46 - the line sits immediately before this session's first stderr output - and its
  node-side run kept writing afterwards: a header splice at 13:17, `run_failed: provider_stalled` at
  13:20:26, a `[self-wake ...]` line at 13:21:28, the `test-mission.sh` splice at 13:22, the docs edit at
  13:32, the commit at 13:38;
- this session (`a8fcaf0d`, CLI pid 3117832, parent `run.sh` 3117825, started 13:11:46).

The fact the fourth read cannot see: `session_presence` names pid `616163` for `6a48d01d` (3 s old when
read at 13:23), and 13 sessions share that pid. `/proc/616163` is neither a launcher nor a mission runner:
it is `wa serve --port 8799 --client-port 8800 --ui ...`, cwd `/home/victor`. So a turn run inside the
node's own process writes into this worktree while `writers_check` - which asks the node for the pid it
recorded for the session and reads *that* pid's cwd - finds no writer: the pid's cwd is the server's, never
the mission's.

What that means for `start`, as narrowly as the evidence allows: "the node says every session of this
mission is settled" is a statement about *now*. A wake can begin a new run of the same session minutes after
a launch was lawfully allowed (`failed` at 13:11:46, writing again by 13:17), and the presence read does not
catch a run served by `wa serve`. That is the 18/11 shape arriving through a door the four reads do not
cover, and this round's fixtures cannot reproduce it: they model the CLI's exit, not the server's own turn.

What I did **not** verify: which gate let *this* session's launch through at 13:11:46. This mission
directory holds no `lease.log` and no `run.lock` for it, so there is no record to read, and I do not claim
`start` was wrong. What I did verify is that the recorded state was damaged before the round began: at 10:02
the directory gained four stray directories - `== lease file:`, `MISSION=demo`, `RUNNER=999999necho`,
`WORKTREE=` - the lines of a `run.lock`/`lease.log` turned into directory names by something that wrote into
the real mission dir instead of a fixture's own `mktemp -d` root. Follow-up, not done here: `stage` and
`test-mission.sh` should refuse a `MISSIONS_DIR` that is not under the fixture's own work root.

The tree was clean at `fd751adb` from 13:38 on; while the other run was active this session wrote only under
`/tmp/mf-r4/`, and this section plus one measurements row in `docs/MISSIONS.md` are its only edits.
