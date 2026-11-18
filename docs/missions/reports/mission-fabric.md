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


# REPORT — round 5: verification of round 4 — "unknown is not yes", on every read

Branch `change/mission-fabric`, round 4's head `c147ee48`. This round verifies that head and fixes five
places where a read that could not answer was read as a yes. Nothing was pushed.

| # | where | what round 4 did | what it does now |
| --- | --- | --- | --- |
| 1 | `scripts/mission.sh:278` (`writers_check`) | `out=$(node_presence ...) || return 1` turned the presence read's rc 2 ("cannot tell") into "no writer", so `mission_run` answered `released` and `start` launched past a `memory.db` it could not read | rc 2 is passed through; `mission_run` answers `unknown` with the reason quoted, and the fixture builds `memory.db` with the rest of the node (before the first launch) |
| 2 | `mission.sh:257` (`node_presence`) | `readlink /proc/$pid/cwd || continue` skipped a LIVE process whose cwd could not be read (another user's process, hidepid) | a `/proc/<pid>` that exists with an unreadable cwd is `unknown`: the process is there, where it works cannot be told |
| 3 | `mission.sh:574-577` (`cmd_start`) | the check-and-launch window closed after 5 s whatever the runner did, and `started` was printed even when the runner had already exited 95/98 | the window closes when the runner HAS `run.pid`; while that runner lives `start` waits; if it ends without one, `start` refuses `[launcher]` and carries that rc |
| 4 | `mission.sh:753` (`cmd_clean`) | `clean` refused only on `active`, so a `stale` row and an `unknown` read went through to `git worktree remove` | `clean` refuses every verdict but `released`, with the same reason and clear-by-hand command `start` gives |
| 5 | `docs/MISSIONS.md:28,40,44` | three citations pointed at the worktree's `REPORT.md`, which removing the worktree takes with it | they point at `docs/missions/reports/mission-fabric.md`; the verdict table gains the "memory.db unreadable" row (and a live pid with an unreadable cwd), and the `clean`/`verify` sentences say what each now refuses |

## Before and after, measured

Every "before" is a saved copy of the script run through `MISSION_UNDER_TEST`, so no red was produced by
editing this tree. Each copy is broken in exactly one way, and each is red at its own item's check:

| copy | first failure |
| --- | --- |
| the round-4 script itself (`git show c147ee48:scripts/mission.sh`) | `clean must refuse when the node cannot be asked` |
| `m1`: the presence read's rc 2 collapsed back to "no writer" | `a node with no memory.db must read unknown, got: 'released: the node answered and lists no session for this mission ...'` |
| `m2`: an unreadable cwd taken as a process that is gone | `a live pid whose cwd cannot be read must read unknown, got: 'released: ...'` |
| `m3`: the 5 s cap and "started" printed without a `run.pid` | `a runner that exits before writing run.pid must not be reported as started` |
| `m4b`: `clean` permits `stale` again | `clean must refuse a leftover (stale) run` |
| this tree | `mission fixture: 202 checks ok` (15.4 s, twice) |

The item-1 and item-2 "before" answers are the bug in one line: `released: the node answered and lists no
session for this mission` - a launch permission derived from a read that returned nothing. The mutants live
under `/tmp/m5/mut/` and are `MISSION_UNDER_TEST=<copy> bash scripts/test-mission.sh`; the round-4 script was
saved with `git show`, not edited by hand.

The new cases, and what each pins:

* **item 1** - a node home with a claim store and no `memory.db` (`unknown`, the refusal naming the file),
  the same with a `chmod 000 memory.db` (skipped as root, never here), and then the same mission with a
  readable, writer-free `memory.db` reading `released`: the refusal is the read, not the mission. The
  fixture's own early cases now build `session_presence` before the first launch, or round 5 would refuse them;
  `run_nonode` (the node with no lease store) keeps a readable `memory.db` so it still tests one read.
* **item 2** - a presence row naming pid 1: `/proc/1` exists, `/proc/1/cwd` is unreadable to a normal user
  (the shape hidepid gives every other user's process). `unknown`, the reason naming the pid; the row is
  dropped and the same mission then launches.
* **item 3** - a staged runner with `exit 95` spliced in as its first statement: `start` refuses
  `[launcher]`, prints `rc=95`, never prints `started`, leaves no `done` and no `run.pid`; and a runner
  that sleeps 6 s before writing `run.pid`: `start` waits for it and returns with the file in place (the
  5 s cap could not).
* **item 4** - a leftover row (`stale`): `clean` and `clean --force` both refuse it, the worktree stays, and
  the same `clean` removes it after the row is settled by hand. The `unknown` half is in the unreachable-node
  block: `clean` refuses there too and leaves the worktree.
* the "gone process" presence row now names a pid the kernel cannot hand out (`2147483647`), because round 5
  asks `/proc/<pid>` before answering and a re-used pid would make that row mean something else.

Two things went wrong while writing this, and both are worth the next reader's time:

* **the reason was lost in a subshell.** The first version set `NP_WHY` inside `node_presence`, which its
  caller runs in `$( )` - so the refusal read "cannot be read:  - so whether a process is writing ..." with the
  reason gone. A global set inside a command substitution never reaches the caller. The reason now travels on
  stdout as a `! cannot-tell ...` line (the shape `node_boot_lease` already uses), and `writers_check`
  lifts it back out.
* **a bash parse that fails 140 lines later.** `: "${NP_WHY:=the node's ...}"` - an apostrophe inside a
  double-quoted parameter expansion - made `bash -n` report a syntax error at line 450, in a function this
  round never touched. `bash -n` on the two scripts is now part of what I ran, and the line is a plain
  `[ -n "$NP_WHY" ] || NP_WHY="..."` instead.

## What I ran

| command | result |
| --- | --- |
| `bash -n scripts/mission.sh`, `bash -n scripts/test-mission.sh` | clean |
| `bash scripts/test-mission.sh` (five times, the last two on the final tree) | `mission fixture: 202 checks ok`, 15.4 s and 15.4 s |
| the five "before" copies above | each red, at its own item's check (table above) |
| `bash scripts/fast.sh` on this tree, twice | `13 of 253 checks` (129 s) and `14 of 253` (207 s); `fast: mission ok` in 15.6 s and 18.9 s |
| `bash scripts/fast.sh` on a base worktree at `c147ee48` (`/tmp/m5/base`, detach) | `13 of 253 checks` (252 s, cold build) |
| `scripts/mission.sh status mission-fabric` against the live node (read only: that mission has no `run.lock`) | `run active`: session `d05086c8`, pid 3595698, cwd `/home/victor/Work/missions/mission-fabric` - this session, named as the writer, which is the presence read still answering on the live node |
| every pid in the live `session_presence`, `/proc/<pid>` checked by hand | 5 gone, 7 live, every live cwd readable (`/home/victor`, six mission dirs); no live row trips the new unreadable-cwd rule today |

The fast path's reds are all pre-existing and identical on the base: `scripts/test-observability.lua`,
`test-skill-discovery.lua`, `test-orchestration-mode.lua`, `test-remote-call-shape.lua`,
`test-codemode-model-boundary.lua`, `test-prompt-cache.lua`, `test-wave-closure-reporting.lua`,
`test-host-return-docs.lua`, `test-provider-stall.lua`, `prompt-docs`, `publish-artifacts`,
`land-signing`, `fast-binary` - 13 on this tree and 13 on the base, the same names. The one red that made
run 1 report 14, `scripts/test-release-sign.lua` (`release signing: 2 of 5 checks failed`, it shells out to
`python3 scripts/test-vault-sign.py`), passed in run 2 on the same tree with no change to it: flaky, and it
touches nothing this round edits. `fast-binary` is the same row on both trees: the tree binary was built at
`c147ee48` and `WA_FAST_SKIP_BUILD=1` forbids building a fresh one, so it refuses a binary it calls stale -
named here so the next round does not read it as a green.

## Not done, and not verified

* `verify` still refuses only on `active`. I changed `clean` because the brief names it; `verify` is left
  as it was, and the asymmetry is deliberate: a `clean` removes the worktree, a `verify` only runs a command
  in it. If the next round wants "no verdict but `released`" everywhere, `verify` is the remaining place.
* **the round-4 hole is unchanged**: a session settled on the node's word and then woken by `wa serve` writes
  with a pid whose cwd is never the mission's, so no presence read in this design sees it. Round 4's report
  measured it (`6a48d01d`, pid 616163 = `wa serve`, cwd `/home/victor`); this round neither fixes it nor
  pretends to. The gate still means what round 4 said it means: no launcher alive, no *mission-cwd* process,
  and every session of this mission settled at the moment of the check.
* **the 10-minute bound** in `cmd_start` is mine, not measured: while the runner lives, `start` waits, and
  only a runner that writes no `run.pid` for 10 minutes is refused as "alive but not a launch". No fixture
  reaches that branch (it would take 10 minutes); the checked paths are the two that matter - the runner that
  exits (95/98) and the runner that is slow (6 s).
* the two "cannot construct it here" cases are skipped, not passed: the unreadable-`memory.db` case when the
  suite runs as root (`chmod 000` would still be readable) and the unreadable-cwd case when
  `/proc/1/cwd` reads. Neither skip fired on this node; both print a note when they do.
* nothing was written to the live node: the only live read is `status` on the mission directory, which has no
  `run.lock` to release, and `sqlite3 -readonly` on `memory.db` and `claims.sqlite`.


# REPORT — round 6: verification of round 5's head — two "cannot tell" paths that read as free

Branch `change/mission-fabric`, verified head `ce7d774f`; this round adds one code commit (`1e9fa29a`)
and this file. Nothing was pushed, and nothing was written to the live node: the only live command is a
read-only `scripts/mission.sh status mission-fabric` (no `run.lock`, no `launch.pid` there, so it released
nothing).

| # | where | what round 5 did | what it does now |
| --- | --- | --- | --- |
| 1 | `scripts/mission.sh:625-640` (`cmd_start`, the wait cap) | at the cap `start` closed the start lock (`exec 9>&-`) and refused. The runner it had launched was recorded NOWHERE, so the next `start` found no `run.pid`, no presence row and no session, called the mission `released` and started a **second runner** beside the live one | `start` writes `$!` to `launch.pid` before it waits; `mission_run` answers `active` (or `unknown`) while that pid is this mission's `run.sh` |
| 2 | `scripts/mission.sh:266` (`node_presence`) | `[ -n "$sid" ] && [ -n "$pid" ] || continue`: a presence row with an empty pid was skipped as "no writer", so the read answered `released` for a session the node still records | an empty pid (or a pid that is not a number) is `cannot tell`: the read returns 2, and `mission_run` answers `unknown` naming the session |
| 3 | `scripts/mission.sh:314` (`writers_check`) | a read that named a writer and then met a row it could not place answered rc 2, and rc 2 went straight to `unknown` - the writer it had already named was thrown away | the writer rows are read first: a writer is `active` whatever else the same read said, because it is the node's own word about a live process in the directory |

## Item 1 — the cap was a launch permission for the next start

`cmd_start` waits for the runner to write `run.pid` and keeps the flock meanwhile; a runner still alive at
the cap is refused as `[launcher]` ("it has written no run.pid in 600s"). That refusal is right - nothing proves
a launch happened - but the lock fd is closed and the `start` exits, so the exclusion is gone with it. What a
second `start` then reads is: `alive_launcher` (`run.pid` absent - true), `writers_check` (the
runner has not started the CLI yet, so the node has no session and no presence row - true), the session list (nothing
under this mission's title - true). Three true reads, one wrong verdict: the runner is *starting*, and it was
recorded nowhere.

`launch_alive` closes that window and nothing else:

    launch_alive() {                      # <mission dir> -> 0 ours and alive, 1 not, 2 cannot tell
      [ -s "$1/launch.pid" ] || return 1
      pid=$(cat "$1/launch.pid") || return 1
      case $pid in ''|*[!0-9]*) return 1 ;; esac
      kill -0 "$pid" || return 1
      cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
      case $cmd in *"$1/run.sh"*) return 0 ;; esac
      [ -n "$cmd" ] && return 1          # another program holds that number: the file is stale
      cwd=$(readlink "/proc/$pid/cwd"); [ "$cwd" = "$1" ] && return 0
      return 2                           # alive, cmdline and cwd both unreadable
    }

Four decisions in it, each with a reason:

* **the cmdline decides when it can be read.** `start` launches `bash <mission>/run.sh`, so a runner always
  names it. That is also what keeps a number the kernel handed out again from refusing this mission for ever -
  and it is why the cwd is only the second witness: a *readable* cmdline naming another program is a stale file
  even if that process happens to work in the mission dir (the fixture asserts exactly that).
* **rc 2, not rc 0**, when the cmdline *and* the cwd cannot be read: "cannot tell whose that pid is" is the same
  never-free answer the other reads give.
* **the branch is gated on `[ ! -s "$M/run.pid" ]`.** Once the runner has written `run.pid`, `alive_launcher`
  (the CLI whose cwd is the mission dir) and the node's word decide, exactly as before. Without that gate a
  `start` landing in the millisecond between the CLI's exit and the runner's own exit would read `active`
  for a run that has finished - a refusal with no fact behind it, and a fixture flake of its own.
* **`launch.pid` is cleared by `start` before it launches** (after the gate has read it) and by `clean`
  with the runner it names. A stale file that names a dead pid refuses nothing; the fixture checks that too.

The fixture's evidence is one count, because the exit code is no evidence either way - the second `start` hits
the same cap and refuses as well:

    mission fixture FAILED: the second start launched a runner beside the live one: 1 -> 2: ...

## Item 2 — "no pid" is not "no writer"

A `session_presence` row with no pid cannot say which process serves that session, and therefore cannot say
where it works. Round 5's `[ -n "$pid" ] || continue` dropped such a row silently, `node_presence` returned 0
("no writer"), and `mission_run` said `released` for a session the node still lists. It is now
`cannot_tell` + rc 2, and the reason names the session. The same applies to a pid that is not a number: it can
be neither looked up nor placed, and it goes into the same `! cannot-tell` line the callers already parse.

## Item 3 — a writer row outranks a row that cannot be placed

One read can hold both facts. Round 5's `writers_check` sent rc 2 to `unknown` before looking at the rows, so
a live writer the read had already named was discarded. The scan now runs first and returns `active` with that
writer; only a read with no writer row at all can still answer rc 2. 'active' is a refusal either way, so this
changes no permission - it changes which fact the refusal rests on, and the fixture asserts that the unplaceable
row is not what decides.

## Before and after, measured

Every "before" is a saved copy run through `MISSION_UNDER_TEST=`, so no red was produced by editing this tree.
The head copy is `git show ce7d774f:scripts/mission.sh` with ONE change - the same `MISSION_START_WAIT_SECONDS`
seam this round added - because the fixture cannot wait ten minutes for the cap; it arrives at the same refusal,
sooner, and decides nothing else.

| copy | first failure |
| --- | --- |
| the round-5 head (`ce7d774f`) + the cap seam | `the second start launched a runner beside the live one: 1 -> 2` |
| `m1`: this tree with the `launch.pid` record removed (item 1 reverted) | `the second start launched a runner beside the live one: 1 -> 2` |
| `m2`: `[ -n "$sid" ] && [ -n "$pid" ] || continue` restored (item 2 reverted) | `a presence row with an empty pid must read unknown, got: 'released: the node answered and lists no session for this mission ...'` |
| `m3`: rc 2 answered before the writer rows are read (item 3 reverted) | `a writer beside a row that cannot be placed must read active, got: 'unknown: ... has a session_presence row with an empty pid ...'` |
| this tree | `mission fixture: 240 checks ok` (twice on the final tree, `24s`) |

The copies live under `/tmp/mf6/{before,m1,m2,m3}/mission.sh` and are run as
`MISSION_UNDER_TEST=/tmp/mf6/<copy>/mission.sh bash scripts/test-mission.sh`.

The new cases, and what each pins (38 checks, from 202 to 240):

* **item 1** - a staged runner with `sleep 600` spliced in before it can write anything, and
  `WAIT_SECONDS=2` in place of the 600 s cap: `start` refuses `[launcher]`, prints that the runner is
  recorded in `launch.pid` and that a new start will refuse `[active]`, leaves no `done` and no
  `run.pid`; then **the count**: a second `start` must leave exactly one runner of that `run.sh` alive,
  and it does (round 5 left two); then `status` reads `active`, names `launch.pid`, says "second runner",
  and the `launcher` line carries the runner's pid. Then the file's own staleness: a dead pid refuses nothing,
  a pid that is now another program refuses nothing, and the same when that program's cwd is the mission dir; the
  hang is removed and the mission launches.
* **item 2** - a `session_presence` row with a NULL pid: `status` reads `unknown`, the reason names the
  session and says the pid is empty, `start` refuses and launches nothing (no `done`, no `launch.pid`);
  the same row with a pid the kernel cannot hand out is released, which is what makes the refusal the empty pid
  and not the row itself.
* **item 3** - a live writer whose cwd is a mission dir, plus the empty-pid row, in one read: `status` reads
  `active`, names the writer, does not name the row it could not place, and `start` refuses `[active]`.

Three things worth the next reader's time:

* **a pre-existing flake, pinned.** The round-4 presence case asserted the literal string `4000s ago` in the
  verdict. The age is the node's own arithmetic (`now - heartbeat_at`, whole seconds), so a row written and read
  across a second boundary answers `4001s ago` - it fired here on one of the four mutant runs, on a copy that
  does not touch the age at all. The assertion now accepts `4000` or `4001`; it still asserts that the age is
  *reported*, which is the round-4 rule.
* **a failing fixture leaked the runner a mutant launched.** The cap case registers the runner it finds in
  `KIDS`, which is what `cleanup` kills; on the four *failing* mutant runs (before/m1) the second runner was in
  `launch.pid` and the first one no longer was, so two `sleep 600` runners survived each run (four in total, found
  and killed by hand, and nothing in the fixture depends on them). The case now registers every runner it sees,
  right after each `start`, so a red leaves none behind - re-checked by running m1 again and counting.
* **the patched `printf` format strings** in the two new `launch.pid` cases first landed as a format with a real
  newline in it (a `\n~ eaten by the patch script). It parsed and the cases passed, which is exactly why it was
  worth fixing: `bash -n` is not a proof of what a line does.

## What I ran

| command | result |
| --- | --- |
| `bash -n scripts/mission.sh`, `bash -n scripts/test-mission.sh` | clean |
| `bash scripts/test-mission.sh` on this tree (five times, the last two on the final tree) | `mission fixture: 240 checks ok`, 23-24 s |
| the four copies above | each red at its own item's check (table above) |
| `bash scripts/fast.sh` on this tree | see below |
| `scripts/mission.sh status mission-fabric` against the live node (read only) | `run active`: session `6b65758b`, pid 234618, cwd `/home/victor/Work/missions/mission-fabric`, heartbeat 0 s ago; `launcher none recorded` (no `run.pid`, no `launch.pid` in that dir) - the presence read still answering on the live node, and `launch_alive` correctly silent |

| `bash scripts/fast.sh` on this tree twice: mid-round, and once more on the code commit `c8dc7667` - which is this round's
code apart from the fixture-cleanup hardening added after it, and the fixture reports the same 240 checks ok
on both | `fast path FAILED (13 of 253 checks, 0 skipped, 150s)` and `... 148s`; **`fast: mission ok`** in both (23.8 s and 20.7 s), and the same 13 names each time (below) |

## Not done, and not verified

* **the real 600 s cap was never waited for.** No fixture sits through ten minutes; `MISSION_START_WAIT_SECONDS`
  reaches the same branch in 2 s. The seam can only *shorten* the wait, and a shorter wait cannot permit a launch:
  it arrives sooner at the refusal, the refusal names the runner in `launch.pid`, and a runner that has ended is
  a refusal on its own rc. The 600 s default itself is unchanged and still unmeasured.
* **`launch_alive`'s rc 2 is not exercised by any fixture.** It needs a live pid whose `/proc/<pid>/cmdline`
  *and* `/proc/<pid>/cwd` are both unreadable - hidepid, or another user's process - and a fixture cannot make
  that of its own child. The two directions that are reachable (a dead pid, and a pid that is now another program,
  with and without the mission dir as its cwd) are covered. Nothing on this node reaches rc 2 today: the live
  presence pids all read.
* **`launch.pid` is left behind after a launch finishes.** It then names a dead pid (or, after a very long time,
  a re-used one, which the cmdline check rejects), so it refuses nothing; `start` and `clean` both remove it.
  I did not add a sweep that deletes it when the runner exits: the runner is the process that would have to do it,
  and a runner that dies early would then leave the record it is supposed to leave. The remaining hole is
  microseconds wide and stated rather than hidden: a `start` killed between the launch (`&`) and its
  `printf > launch.pid` leaves that runner unrecorded again.
* **the 13 fast-path reds are pre-existing and untouched by this commit.** `scripts/test-observability.lua`,
  `test-skill-discovery.lua`, `test-orchestration-mode.lua`, `test-remote-call-shape.lua`,
  `test-codemode-model-boundary.lua`, `test-prompt-cache.lua`, `test-wave-closure-reporting.lua`,
  `test-host-return-docs.lua`, `test-provider-stall.lua`, `prompt-docs`, `publish-artifacts`,
  `land-signing`, `fast-binary` - the same thirteen round 5 reproduced on a base worktree at `c147ee78`
  (this round's diff is `scripts/mission.sh`, `scripts/test-mission.sh`, `docs/MISSIONS.md` and this file:
  no Lua, no JS, no release script), and `fast: mission ok` is green in the same run.
* **unchanged by design, from round 5:** `verify` still refuses only on `active` (`clean` refuses everything
  but `released`; round 7 changed that - see its item 2), and the round-4 hole stands - a session settled on the node's word and then woken by
  `wa serve` writes with a pid whose cwd is never the mission's, so no presence read in this design sees it.
  This round neither fixes nor widens that.

---

# REPORT — round 7: the five findings of the review of `fc254d6d`, each with a check that is red before the fix

Branch `change/mission-fabric`, rebased onto `origin/main` (`e5ba9089`) from `fc254d6d`; worktree
`/home/victor/Work/missions/mission-fabric/wt`. Built and tested HERE (avell, x86_64, 16 cores). Committed
locally, **never pushed**.

The rebase needed a resolution in fifteen of the commits: every one of them touched the root `REPORT.md`, which
main now has its own copy of. Each resolution keeps **main's** root `REPORT.md` byte for byte, and this round's
report lives where main's `land-r1` round put reports: `docs/missions/reports/mission-fabric.md`. The branch's
net diff against `e5ba9089` is `docs/MISSIONS.md`, `scripts/mission.sh`, `scripts/test-mission.sh` and that
report file - it adds no root REPORT.md and deletes none.

## The fixture, on this tree

`bash scripts/test-mission.sh` -> **`mission fixture: 273 checks ok`**, rc 0, ~65 s (round 6: 240 checks).
Scratch only, as the round asks: `HOME` and `WASM_AGENT_HOME` are a fresh `mktemp -d` outside
`~/.wasm-agent` (`TMPDIR` pointed at it, so even `mktemp` inside the fixture stays out), and
`WASM_AGENT_LUA_ROOT` is this worktree. No check reads or writes the real `~/.wasm-agent`.

## 1. the EXIT sweep killed whatever a pid file named (MUST)

**Finding (test-mission.sh:29-30, round 6).** `cleanup` iterated `"$MISSIONS"/*/run.pid` and `launch.pid` and
killed the number inside, whoever held it. A killed run leaves those files behind, the kernel re-issues the
number, and the next fixture's exit sweep SIGTERMs the new holder - on this node that can be a `wa serve`.

**Change.** The sweep is now one function, `pid_sweep`, called by `cleanup`, and it kills
only a process it can prove is this run's: a pid whose own `/proc/<pid>/cmdline` names this run's scratch dir
(`"$WORK"` - a runner launched here always does), or a pid registered in `KIDS` whose forking parent is this
shell (the `sleep` children the fixture puts in mission dirs carry no path in their cmdline, and dropping them
would bring back the wedged-pipe failure round 2 fixed). A pid file naming anything else is not touched.

**The check, and it is red before the fix.** The new case plants two live processes and two pid files in a scratch
dir of its own: one whose cmdline names that dir (this fixture's runner), one that names nothing of it
(`cd /tmp && exec sleep 600`), then runs the very `cleanup` the trap calls, in a subshell with that scratch
dir as `WORK`.

* before (the same fixture file with round 6's `pid_sweep` body put back):
  `mission fixture FAILED: the EXIT sweep killed pid 1377961, which no pid file can prove is its own (a number the kernel re-used)`
* after: both directions pass - the runner it started is killed, the foreign process survives.

## 2. `verify` refused only `active`, so it ran commands beside a possible writer (MUST)

**Finding (mission.sh:890-891).** `[ "$MR_VERDICT" = active ] && die ...` - an `unknown` read (a presence row
that cannot be placed, a node that could not be asked) and a `stale` leftover went straight to
`enter "$M"` and ran the command in the worktree, competing with a writer the read could not rule out.

**Change.** The gate is the same one `start` and `clean` use: `[ "$MR_VERDICT" = released ] || refuse ...`.
It refuses by name through `refuse`, so the state, the reason and the manual command are printed as before.
A refusal runs nothing and writes no `verify.log` line.

**The check.** A staged mission, then two reads:

* before (round-6 `mission.sh`): `mission fixture FAILED: verify ran its command on an unknown read`
* after: `refusing [unknown]`, the marker file the command would have created is absent, no `verify.log`;
  the same mission without the row runs the command (released), and a `stale` leftover refuses too
  (`refusing [stale]`), while the settled row runs it again.

## 3. `node_presence` returned at the first row it could not place (MUST)

**Finding (mission.sh:276/279/289).** `cannot_tell ...; return 2` on an empty pid, a non-numeric pid, or a live
pid whose `/proc/<pid>/cwd` will not read. The scan stopped there, so a writer row further down the table was
never printed, `writers_check` found no writer, and `mission_run` answered `unknown` - the false half of the
round-6 test comment at `test-mission.sh:833` ("the same rc 2 whatever order the scan meets the rows in"), which
passed only because the writer row happened to come first.

**Change.** The unplaceable rows are collected in a reason string and the scan goes on; every row is read, writer
rows are printed as they are found, and one `! cannot-tell` line carrying all the reasons is printed at the end
with rc 2. A writer row therefore wins in either order, and the reasons are not lost.

**The check, and the comment fixed.** The mixed case now plants the empty-pid row **before** the writer row
(rowid order is the order sqlite returns), and its comment says what it measures instead of what the code did not
do.

* before (round-6 `mission.sh`, rows in that order):
  `mission fixture FAILED: a writer beside a row that cannot be placed must read active, got: 'unknown: ... session abababab-4444-5555-6666-777777777777 has a session_presence row with an empty pid, so the process serving it - and the directory it works in - cannot be told - so whether a process is writing in .../missions/mixed/wt cannot be told ...'`
* after: `active`, the verdict names the writer, and `start` refuses with it.

## 4. the directories were compared as strings, so a symlinked missions path read as "another directory" (MUST)

**Finding (mission.sh:487/294/514).** `/proc/<pid>/cwd` reports the path a directory really is. With
`MISSIONS_DIR` reached through a symlink, the compare in `node_presence`, in `alive_launcher` and in
`launch_alive` said "not this mission" for a process working in it: a writer scored as no writer, a launcher as
some other program.

**Change.** All three resolve the mission dir (and the worktree) with `cd ... && pwd -P` first.
`launch_alive` accepts both spellings in the cmdline witness too, since the cmdline names the path `start`
was handed while `/proc` reports the path it points at.

**The check.** `ln -s "$MISSIONS" "$WORK/link"`, then every call goes through the symlinked path while the writer
process is started in the real directory.

* before (round-6 `mission.sh`):
  `mission fixture FAILED: a writer in the real mission dir must read active through a symlinked MISSIONS_DIR, got: 'released: the node answered and lists no session for this mission (no run.lock, no 'wa: session' line, no title match)'`
* after: `active` through the symlink, `start` refuses `[active]`, and a launcher standing in the real dir
  (named by `run.pid`) refuses `[launcher]` with its pid.

## 5. `clean` deleted the worktree without the start lock, then deleted the lock file (MUST)

**Finding (mission.sh:902-935).** `clean` ran `mission_run` and then removed the worktree with nothing holding
`start.flock`: a `start` inside its check-and-launch had already read the files the removal took away, and it
launched into a tree being cleaned. Then `rm -f "$M/start.flock"` deleted the file the lock lives on - from
under any holder, and, for the next `start`, a different inode to lock.

**Change.** `clean` takes the same kernel lock first (`exec 9>>"$M/start.flock"`, `flock -n 9`), over the
whole check-and-remove, and refuses by name while a `start` (or another `clean`) holds it. The file is **not**
removed any more: this clean holds that lock, and deleting the file it holds leaves the next start locking a
different inode. The unchanged `demo` case in the fixture now asserts the file stays.

**The check.** A holder takes the lock and sleeps; `clean` on that mission, then:

* before (round-6 `mission.sh`): `mission fixture FAILED: clean removed the worktree while a start held the start lock`
* after: `refusing`, the refusal names `start.flock`, the worktree and `run.sh` are still there; once the
  holder exits, the clean runs, removes the worktree and leaves `start.flock` on disk.

## What I ran

| command | result |
| --- | --- |
| `bash -n scripts/mission.sh`, `bash -n scripts/test-mission.sh` | clean |
| `bash scripts/test-mission.sh` on this tree (scratch HOME/`WASM_AGENT_HOME` under `mktemp -d` outside `~/.wasm-agent`, `WASM_AGENT_LUA_ROOT` = this worktree) | **`mission fixture: 273 checks ok`**, rc 0, ~65 s |
| five probe copies of the same fixture, each with exactly the pre-fix behaviour restored (below) | each red at its own item's check; quotes above |
| `bash scripts/fast.sh` on this tree, once | `fast path FAILED (1 of 260 checks, 0 skipped, 125s)`: the one red is `scripts/test-provider-stall.lua` ("a provider call gets its own 90s first-response deadline: got \"300\", want \"90\"") - a **pre-existing** red, named in round 6's list of thirteen, and this round's diff touches no Lua and no release script; the `mission` row (which runs this fixture) is green inside that same run |

How the probes were built, so the "before" is not a claim: each is a copy of **this** fixture file with one
reversal - round-6's sweep body (item 1), or with the round-7 check that would fire earlier put back in its
round-6 form so the run reaches its own item (the `demo` assertion that clean leaves the lock file, and the
mixed case's row order), or with the earlier round-7 sections cut. Items 1-4 ran the new fixture against
`MISSION_UNDER_TEST` = `git show HEAD:scripts/mission.sh` (the round-6 script); item 5 ran the new fixture
with the round-6 sweep put back in its own `cleanup`. The probe copies were deleted before the commit
(`git status` carries only the four files).

## Not done, and not verified

* **the real 600 s start cap was not waited for** - unchanged from round 6, and this round did not touch it.
* **`launch_alive`'s rc 2 is still not exercised** by any fixture: it needs a live pid whose cmdline *and*
  cwd are unreadable, which a fixture cannot make of its own child. Unchanged from round 6.
* **`clean`'s lock covers `start` and other `clean`s of the same mission, nothing else.** A `stage`, a
  `status` or a hand edit can still touch the mission dir while a clean runs; the lock's job is the
  check-and-remove against the check-and-launch.
* **the sweep's KIDS rule is deliberately wider than "cmdline names $WORK"**: a direct child of the fixture
  shell is killed even when its cmdline names no path (the `sleep` children the fixture puts in mission dirs).
  The reviewer's rule ("kill only pids this test started, and only if `/proc/<pid>/cmdline` names $WORK") would
  have leaked those and brought back the wedged-pipe failure round 2 fixed; both conditions are checked, and the
  pid-file half - the one that could kill a reused number - is now strictly the cmdline test.
* **the doc's own wording was edited in eight places** (below); nothing else in `docs/MISSIONS.md` was touched.
* **no deploy, no push, no land** - per the round.

## Texts to approve

Operator-facing strings, verbatim (`<...>` marks a value):

1. `clean` refuses while the start lock is held (`scripts/mission.sh`, `die`):
   `mission: refusing: another 'start' or 'clean' of <name> is inside its check-and-launch right now (flock -n on <mission>/start.flock). Wait for it: 'scripts/mission.sh status <name>' shows what that run did, and the kernel releases that lock when that start exits. There is nothing to clear.`
2. `clean` with no `flock` on PATH:
   `mission: no flock on PATH (util-linux): a clean beside a start is a kernel lock, not a guess`
3. `clean` cannot open the lock file: `mission: cannot open <mission>/start.flock`
4. `verify` refuses any verdict but `released` (two lines, through `refuse`):
   `mission: refusing [<state>]: a verify runs a command in <mission>/wt, and this mission's run is not released: <reason>`
   `mission: clear it by hand: <the command that clears that state>`
5. the presence read's reason line, whose **shape** changed (one line can now carry several rows, joined with
   `;`); the three reason texts themselves are unchanged:
   `! cannot-tell session <id> has a session_presence row with an empty pid, so the process serving it - and the directory it works in - cannot be told;`
   `! cannot-tell session <id> has a session_presence row whose pid is not a number [<pid>], so the process serving it cannot be looked up at all;`
   `! cannot-tell pid <pid> (session <id>) is running and /proc/<pid>/cwd cannot be read - another user's process, or hidepid - so the directory it works in cannot be told;`

Documentation (`docs/MISSIONS.md`), changed passages verbatim:

6. fixture row: `scripts/test-mission.sh` (`KIDS` and the reaped sweep in `cleanup`; round 7: the sweep kills
   only a pid whose own cmdline names the run's scratch dir, or a process this shell forked, so a pid file left by
   a killed run cannot make it SIGTERM a number the kernel handed to something else - a `wa serve` was the
   measured candidate)
7. the second condition of `start`: `... as the answer to *where* (`writers_check`). `/proc` reports the
   path a directory really is, so both sides of that compare are resolved with `cd ... && pwd -P` first: a
   missions tree reached through a symlink is one directory with two spellings, and a bare string compare called a
   writer in it "another directory" (round 7);`
8. the writer-row verdict: `... The whole table is read before the answer is given, so a writer row decides even
   when another row of the same read cannot be placed - in either order (round 6 named the writer; round 7
   stopped the read from returning at the unplaceable row that came first)`
9. the presence row of the reads table: `... The mission dir and its worktree are resolved with `pwd -P` before
   that compare, so a symlinked missions path still matches (round 7)`
10. the clearing table's lock row: `| another `start` - or a `clean` - holds the lock | its refusal names
    `start.flock` | nothing: the kernel releases it when that `start` (or `clean`) exits. A leftover *file* is
    not a lock, and is not cleared by hand either |`
11. the status section: ``verify` and `clean` keep the same rule as `start`: both refuse every verdict but
    `released` (`clean` since round 5 - a leftover row and a read that could not be made both reached
    `git worktree remove`; `verify` since round 7 - it runs a command in `wt/`, so `unknown` and `stale` let
    it run cargo beside a possible writer). `verify` never kills a process, and `clean` takes `start.flock`
    before it removes anything and keeps the file: deleting the lock a clean holds would hand the next `start` a
    different inode to lock (round 7).`
12. section 5 (verify): `It refuses every verdict but `released` (round 7: `active` was its only refusal before,
    so an `unknown` read or a `stale` leftover ran the command beside a possible writer), so a verify never
    competes with a session for the same tree. A refusal writes nothing: no `verify.log` line, and the command is
    not run.`
13. section 9 (clean): `... takes `start.flock` before it removes anything and refuses while a `start` holds it
    (round 7: the removal used to take the worktree a start was launching into), removes only the worktree and the
    runner, prunes, and keeps the branch - its commits are the mission's result. `start.flock` stays on disk: the
    lock is the kernel's, not the file's.`

Fixture messages (developer-facing, in `scripts/test-mission.sh`), new or changed:

14. `the EXIT sweep killed pid <pid>, which no pid file can prove is its own (a number the kernel re-used)`
15. `the EXIT sweep left the runner it started (pid <pid>) alive`
16. `verify ran its command on an unknown read` / `verify ran the command beside an unknown read` /
    `a refused verify wrote its log` / `the released verify did not run its command` /
    `verify ran its command on a leftover (stale) run` / `verify ran the command beside a leftover run` /
    `the settled verify did not run its command`
17. `the verify case must read unknown first, got: '...'` / `the verify case must read stale, got: '...'`
18. `a writer in the real mission dir must read active through a symlinked MISSIONS_DIR, got: '...'` /
    `a start through a symlinked missions dir must refuse beside that writer` /
    `a launcher standing in the real mission dir must refuse a launch through a symlinked MISSIONS_DIR` /
    `the symlinked stage did not create the real mission dir`
19. `clean removed the worktree while a start held the start lock` / `the refused clean removed the worktree
    anyway` / `the refused clean deleted the mission files anyway` / `clean deleted the lock file it holds` /
    `clean deleted the start lock file it held` (replacing round 6's `clean left the start lock file`)
20. the mixed case's comment (the false one at `test-mission.sh:833`) now reads: `... The unplaceable half here
    is the empty-pid row of item 2, and it is planted BEFORE the writer row on purpose: the node returns these rows
    in the order they were written, round 6 stopped the scan at the first row it could not place (so this same
    case passed only because the writer happened to come first), and round 7 reads every row before it answers.`
