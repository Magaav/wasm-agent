# prebuilt-records-the-cover (24/11)

Branch `change/prebuilt-records-the-cover` from `origin/main` 2d7ac300. Six commits.

| commit | what |
| --- | --- |
| bb8c0692 | items 1 + 2: a covering release is recorded as both facts, and nothing refuses after the swap |
| 1de2176a | two defects the row found in that fix (`post_swap_problem` defined twice with `$2`; a 12-hex id in a 40-hex field) |
| cd41f34a | the watcher failure is recorded, not an exit; the row names what a scratch home cannot start |
| 5b38b31b | ship `scripts/lib/health-wakes.sh` (the shipped verifier reads it and no deploy shipped it) + three row corrections |
| 075cff97 | the row: `wa --version` reads the record of the install `WA_INSTALL_DIR` names |
| 5b89583b | the row itself, end to end, with its cut condition; wired into `scripts/test.sh` |

## 1 + 2 - the record and the far side of the swap (bb8c0692, 1de2176a)

Root cause, as Fable read it: the prebuilt-release path set `BINARY_COMMIT="$(git rev-parse HEAD)"` even when the
plan took a COVERING release (whose real source is `BINARY_SOURCE_COMMIT`), and `record_installed` expected the
bytes to report HEAD. The bytes truthfully report the release's commit, so the deploy refused 94 s into a run
that had already swapped and restarted the node.

* `record_expected` for a prebuilt install is now `${BINARY_SOURCE_COMMIT:-${BINARY_COMMIT:-$COMMIT}}` - the
  release's source commit, which is HEAD when the release is that commit's own build.
* The record names BOTH, as the fast path does: `commit=` and `lua_tree=` the TREE this deploy installed (so
  `wa update --check` compares the install with origin/main, not with the bytes), `binary_commit=` the bytes'
  own build, `binary_release=` the tag, and `record_expected=` what was proved. A covering install whose
  `commit=` is the bytes' commit is the same defect the Lua fast path fixed on 21/11, one path over.
* The proof moved BEFORE the swap: the staged binary (`node-binary.next/wa`) is run and must report the commit
  it was taken for - `refused(build_commit_mismatch)`, now naming the staged path and the release.
* The far side no longer refuses: `SWAPPED=1` is set the moment `upgrade.sh` returns 0, and from then on
  `fail()` RECORDS (`post_swap_problem=` appended to `installed.txt`), prints, and exits 3 - "installed, with
  problems" - instead of pretending nothing was installed. The record's own disagreement is a recorded problem
  too, and the two malformed-id refusals became `*_why=` lines.

### What else could fail after the swap today (the inventory item 2 asks for), and what happens to it now

| site | before | now |
| --- | --- | --- |
| `record_installed`: bytes report another commit than expected | `fail refused(build_commit_mismatch)`, exit 2, NO record (work's interim record stayed) | BEFORE the swap it is still that refusal (a build whose bytes are not its commit is never installed - `scripts/test-install-record.sh` pins it); AFTER the swap the same disagreement is a recorded problem and the record is written |
| `record_installed`: `commit=`/`binary_source_commit=` not 40-hex | `fail`, exit 2, no record | refused BEFORE the swap where the ids are known; after it, `record_id_why=`/`binary_id_why=` + `commit=unknown` |
| listener pid is not the pid the install recorded | `fail` "two nodes, one port", exit 2 | recorded + exit 3 |
| sentinel would not start / did not start watching (`fail_installed`) | `fail_installed` printed and exited 1, taking the REST OF THE INSTALL with it - the scripts are shipped after it | recorded, `watcher_command=` written into the record, the deploy goes on and ships everything else, exit 3 |
| every `ship_file` (scripts, libs, wave files, policy) | `fail` "node installed, but could not ship X", exit 2 | recorded + exit 3 |
| the record write itself | `fail`, exit 2 | recorded where possible + exit 3 (the worst case: a record that cannot be written) |

`upgrade.sh`'s own failures happen before the swap and keep rolling back.

## 3 + 4 - the row (5b89583b), and what it measured

`scripts/test-deploy-covering-release.sh` runs the REAL `scripts/deploy.sh` end to end on a scratch node:

* the tree: a fixture clone on a release-covered base with this branch's `scripts/lua/docs` as C2 (scripts
  only, so C2's compiled-inputs digest is a published release's); its `origin/main` is a fixture remote so the
  deploy's own fetch cannot move it;
* the install: a scratch install directory under the scratch HOME holding C1's binary (from the published
  release, verified) and **work's INTERIM record** (`record_role=interim`, no `lua_tree=`, no `binary_commit=`,
  no scripts) - so item 4's repair, "the next update completes the record and ships the scripts with no manual
  step", is what the same run measures;
* `WA_DEPLOY_FULL=1` (the fast path is a different, correct path that never asks the channel - the row says so
  rather than pretending the two are one), no systemd user session, `WA_SENTINEL_SUPERVISOR=none`, its own
  `GH_CONFIG_DIR` (a scratch HOME would make gh anonymous at 60 requests an hour).

**GREEN, measured (16 checks, 0 failed):**

```
  ok   the deploy exits 0 on a covering release
  ok   and it took C1's covering release, as the resolver chose it
  ok   the install record is FINAL, not the interim one it started from
  ok   commit= is the tree this deploy installed (C2)
  ok   lua_tree= names C2 (bfdafce3)
  ok   binary_commit= is the bytes' own build (C1), not the tree
  ok   and binary_release= names the release
  ok   record_expected= keeps the commit the staged binary was proved against
  ok   the install carries scripts/lib/download-asset.sh
  ok   the install carries scripts/lib/health-wakes.sh
  ok   wa --version names the OLD binary's release (node-ebf6d2ecffed)
  ok   and the NEW tree (tree bfdafce3)
  ok   the node the deploy started is running
  ok   verify-install is green on the install the covering release produced
  ok   with no FAIL line at all
deploy covering release ok (16 checks, 0 failed)
```

**RED, measured** with main's `scripts/deploy.sh` and everything else of the branch (a worktree of the branch
with `git checkout origin/main -- scripts/deploy.sh` committed on top): the row's three cut-condition rows FAIL -
`record_expected` is not computed from `BINARY_SOURCE_COMMIT`, there is no pre-swap proof of the staged binary,
and there is no `post_swap_problem` record.

**What I could NOT show red, said plainly:** the end-to-end half against main's `deploy.sh` did not reach the
record. In that sandbox run the release resolution found nothing (`gh` answered 401/403 mid-run, the anonymous
quota) and the deploy refused `cargo_unavailable` (its build fallback, on a node with no cargo) - a refusal
before the swap, not work's `build_commit_mismatch`. Two attempts showed it. So the red I measured is the cut
condition, not the incident; the incident itself is work's log, and the green above is the proof that the path
now completes.

## One of my own changes was a loosening, and the gate caught it (the last commit)

My first cut made the bytes-vs-commit disagreement a recorded problem on EVERY path, including the build path
before the swap - which deleted a real guard (a build whose bytes are not the commit they were taken for must
never be installed). `scripts/test-install-record.sh` failed on it (96 checks, 3 failed: "a build whose bytes
report ANOTHER commit is refused"). The check is now conditional on `SWAPPED`: before the swap it refuses by
name exactly as it did, after it it records. The same test file needed one fixture line (`post_swap_problem`,
which deploy.sh defines above the block the test extracts) - its assertions are untouched, and it is 96/0.

## Also found and fixed (5b38b31b)

`scripts/verify-install.sh` looks for `scripts/lib/health-wakes.sh` BESIDE ITSELF to judge the self-wake loop,
and no deploy shipped that lib - so on every installed node that check said "scripts/lib/health-wakes.sh is
missing from this tree" and the loop was never actually judged (work's install lacks it for the same reason;
Fable saw no `health-wakes.sh` under `~/.local/bin/scripts/lib` and read it as "the scripts weren't shipped" -
both are true: the ship step never ran, AND that file was never in the ship list). One `ship_file` line.

## Texts to approve (new or changed operator-facing strings)

1. `refused(build_commit_mismatch): the staged binary at <path> reports commit <a> but this deploy took it for
   <b> (release <tag>) - the bytes are not the commit they were taken for (a stale cache entry, a mislabelled
   release, or a manifest whose source_commit is not the build's). Nothing has been replaced and nothing was
   recorded.` - now BEFORE the swap.
2. `post-swap problem: <what>` (note) and the record's `post_swap_problem_count=`, `post_swap_problem=`,
   `watcher_command=`, plus `record_expected=`, `record_id_why=`, `binary_id_why=`, `binary_source_commit=`.
3. `deploy: INSTALLED WITH <n> PROBLEM(S) - the node runs <commit> and installed.txt records each one as
   post_swap_problem=: <list>` (stderr, exit 3).
4. `deploy: installed, but <what>` + `deploy: the node is running the new build and this is recorded in
   installed.txt (post_swap_problem=); this is NOT a clean success (exit 3).`

## What this branch did not do

* Nothing published, nothing deleted; work was never touched (read-only facts only).
* The end-to-end RED against main's deploy.sh was not reproduced (see above); the cut-condition red was.
* `scripts/test-deploy-covering-release.sh` needs the network (a published covering release) and cannot start a
  sentinel in a scratch HOME on a machine whose systemd user session belongs to the operator - it says SKIP by
  name when either stops it, and never passes by absence.

# SECOND ROUND, 25/11: A SCRATCH RUN THAT IS ACTUALLY SCRATCH (`02067a0a`, `e0e62df9`, `000e49f3`, `09b7b54f`, `efa34ce4`)

The previous worker on this branch is parked for a reason that is now code: its harness reported
`deploy covering release ok (16 checks, 0 failed)` and left a `wa-sentinel` behind with `HOME=/home/victor` and no
`WASM_AGENT_PORT` (pid 635976, killed 00:38:06Z). It had also rewritten the LIVE `~/.config/systemd/user/wa-sentinel.service`
and `~/.local/bin/runtime-worktree.txt`, and run sentinels on the LIVE ledger.

## Root cause, measured (the variable that led to the live paths)

The harness replaced `HOME` and nothing else, and stripped the marker the turn guard reads:

| what the installer resolved | from | value it got |
| --- | --- | --- |
| the systemd unit file | `scripts/lib/sentinel-unit.sh:41` - `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user` | inherited `XDG_CONFIG_HOME=/home/victor/.config` -> the LIVE unit dir |
| the user manager it talked to | `XDG_RUNTIME_DIR` | inherited `/run/user/1000` -> `systemctl --user` on the LIVE manager, which restarted the LIVE sentinel |
| the ledger | `WASM_AGENT_DB` | inherited `/home/victor/.wasm-agent/memory.db` -> the sentinel it started ran on the LIVE ledger |
| the port | `WASM_AGENT_PORT` / `WA_PORT` | unset -> the live 8799 |
| the guard | `WASM_AGENT_IN_TURN` | `env -u WASM_AGENT_IN_TURN`, so the deploy never refused inside the turn |

The four variables are the ones this session inherited from its own turn (measured: `XDG_CONFIG_HOME=/home/victor/.config`,
`XDG_RUNTIME_DIR=/run/user/1000`, `WASM_AGENT_DB=/home/victor/.wasm-agent/memory.db`, no `WASM_AGENT_PORT`), so the chain
is: strip the guard -> the deploy runs -> `XDG_CONFIG_HOME` writes the LIVE unit -> `XDG_RUNTIME_DIR` lets `systemctl --user`
restart the LIVE sentinel -> that sentinel runs on the LIVE ledger. A green row, and every step invisible to it.

## What the branch now does about it

* `scripts/lib/scratch-installer.sh` (`02067a0a`, `efa34ce4`): the environment an installer gets is REBUILT from an
  allow-list (`env -i` + named variables) instead of filtered: `HOME`, `WASM_AGENT_HOME`, `WA_INSTALL_DIR`, the unit dir, a
  `systemctl` STUB written under the scratch root, `WASM_AGENT_DB`, `XDG_CONFIG_HOME`/`XDG_RUNTIME_DIR`/data/cache/state, the
  port pair - all under the caller's root, all refused when they are not; the live ports `8799/8800/8801/8810` refused by
  name; nothing created before every refusal has answered; the guard's own names carried UNCHANGED (never stripped); the
  vault URLs cannot survive `env -i`. It asks `scripts/lib/install-isolation.sh` (the reviewed six-answer guard from
  mission release-node-updates) about the environment it just built, and refuses if the two disagree. It captures the
  operator's home when it is SOURCED, because a row replaces `HOME` before it builds anything (the runner found that:
  `refused(real_node_home)` about the row's own scratch home, 14 checks failing behind it).
* `scripts/test-installer-data-isolation.sh` (`e0e62df9`, `efa34ce4`) keeps every assertion of the lint that was already here
  (landing `5606ecd3`) and adds three sections: the six dimensions on a real child of the builder plus its refusals; the
  CONCRETE case, where two replicas of what leaked must be caught by this file's checker (the harness's own child, and the
  live-HOME sentinel a unit hands a program) while the same leftover started through the builder is clean; and the rule that
  no statement running `deploy.sh`/`upgrade.sh` strips the guard or detaches an installer unless it names its own scratch
  home, install dir and port (the one fixture whose SUBJECT is the guard - `scripts/test-deploy-ancestry.sh` - is that
  shape, and its statements now name `HOME` as well). Measured: 51 checks, 0 failed. It is wired into `scripts/test.sh`
  beside `test-install-guards.sh`.
* The strips removed (`02067a0a`): `test-components-preflight.sh:147`, `test-deploy-on-main.sh:74`,
  `test-release-install-exec.sh`, `test-upgrade-idle.sh:86`, `test-upgrade-ui-fonts.sh:203`,
  `test-watchdog-upgrade.sh:73/95/160`, and this branch's own row. `test-deploy-ancestry.sh:89/241` keeps its strip and its
  `setsid --fork` (that fixture measures the guard's ancestry rule) and now names its own scratch `HOME`.

## The log line (`000e49f3`) - "deploy: command not found"

`scripts/deploy.sh:1529` on `2d7ac300` (and still `origin/main:1551`): a wrapped COMMENT block ended one line early, so
"deploy must never refuse because another session landed while it ran." sat at column 0 and bash ran `deploy` as a command.
Non-fatal, invisible, and on every deploy. Fixed, and `scripts/test-install-guards.sh` now carries the rule (a fixture of
that exact shape must be caught, then every installer is scanned; over the whole tree it matched one line - the one that
was shipped). `09b7b54f` is the follow-up that made the rule able to fail at all: awk's `line` was never assigned, so it
passed on the very file it was written for.

## Alive-first, the two rows: ALREADY ON `origin/main`, and NOT YET ALIVE-FIRST

Measured, not assumed: `origin/main` (82f57859, now 36b2d9ff) already carries `scripts/lib/deploy-alive.sh`, the write at
deploy.sh:1216, the trap that clears it, and `scripts/test-deploy-alive-hold.sh` + `scripts/test-deploy-alive.lua` (landing
"r8c", `docs/missions/reports/deploy-alive-holds.md`). This branch's base predates all of it. What the brief asks for and
main does not do is the ORDER: the write is at `:1216`, while the components preflight (`:406`), the git fetches
(`:457/:522`), the program download (`:997`) and provisioning (`:1181`) all run before it - so on a download install the
whole download still says nothing. Carrying that fix on THIS branch means bringing in main's `deploy-alive.sh` on top of a
`deploy.sh` that diverges from main's (`git diff HEAD origin/main -- scripts/deploy.sh`: 25 lines of main's, including a
`fail()` main rewrote), i.e. hand-merging someone else's reviewed feature to move one call - which is Fable's decision,
not a worker's. Reported, not done, and it is the honest answer rather than a second implementation of the same file.

## The merge onto `origin/main`: NOT clean any more, measured

`git merge-tree --write-tree origin/main 4773a0e4` (the branch before this round): **no conflicts**. The same probe with
this round's tip: **two conflicts**, `scripts/test-installer-data-isolation.sh` and `scripts/test-release-install-exec.sh`.
Both are files another mission changed on `origin/main` and this round had to change too (the state-dir lint, and the marker
cleared in that row). The resolution is not a judgement call: this branch's copy of each CONTAINS `origin/main`'s
(`git diff origin/main -- scripts/test-installer-data-isolation.sh`: 251 added, **0 deleted**), so the merge takes the
branch's side and loses nothing. The branch is also 59 commits behind `origin/main`, which moves while this is written.

## Texts to approve (operator-facing, second round)

5. `refused(installer_env_no_root): a scratch root is required; an installer is never started in the caller environment`
6. `refused(installer_env_live_port): <port> is a live port (8799/8800/8801/8810)`
7. `refused(installer_env_install_escape): --install-dir <path> is not under the scratch root <root>`
8. `refused(installer_env_set_dimension): --set <K> would move a dimension this library owns; use the option for it`
9. `refused(installer_env_guard): install-isolation.sh refuses the environment this library built: <its reasons>`
10. `refused(installer_env_operator_home): the operator home could not be resolved, so a child home cannot be proven
    distinct from it`
11. `refused(installer_env_guard_missing): scripts/lib/install-isolation.sh is not beside this library, so the
    environment it built cannot be judged by the reviewed guard`
12. `the six dimensions and the rows: <n> checks, <m> failed` (this row's own summary line)
13. `not_isolated`-style failure lines of the new sections, in the row's own words: `HOME=<x> is not under the scratch
    root <r>`, `XDG_CONFIG_HOME=<x> is not under the scratch root <r> (the unit dir follows it)`, `WASM_AGENT_DB=<x> is
    not under the scratch root <r> (this is the live ledger)`, `WASM_AGENT_PORT is unset, which is the live 8799`.

## The runner, run by run (`<mission>/rows/`)

Every installer row of this round ran through `_orch/row-runner.sh`, never from this session. Six runs, and three of
them found defects in this round's OWN code:

| run | commit | verdict |
| --- | --- | --- |
| `20261125T032147Z` | `e0e62df9` | SKIP - the fixture remote rejected C2 (non-fast-forward: `clone --bare --shared` inherits the source's `main`); fixed in `000e49f3` |
| `20261125T032433Z` | `000e49f3` | rc=1, 14 failed - all behind `refused(real_node_home)` about the row's own scratch home; fixed in `efa34ce4` |
| `20261125T032635Z` | `efa34ce4` | rc=1, 4 failed - the install itself was correct and complete; the failures were the row's own "exactly ONE watcher problem" and "verify-install with no FAIL line", neither possible in a scratch home |
| `20261125T032951Z` | `a1be430c` | rc=1, 1 failed - the new allow-list read verify-install's summary line as a failure; fixed in `308f110e` |
| `20261125T033226Z` | `308f110e` | rc=1, 14 failed - `refused(cargo_unavailable)`: the deploy's release lookup was ANONYMOUS (`env -i` handed the child no credential), so it fell back to BUILDING; fixed in `40ffd00d` |
| `20261125T033529Z` | `40ffd00d` | **rc=0, 19 checks, 0 failed, leftovers=0, canary green before and after** |

The green one, verbatim:

```
  ok   the record expects the RELEASE's source commit for a prebuilt install, not HEAD
  ok   and the staged binary is proved against that commit BEFORE the swap
  ok   and a post-swap failure is recorded (post_swap_problem=), not a refusal
  ok   the deploy exits 3, and every recorded problem is the watcher a scratch home cannot start
  ok   and it took C1's covering release, as the resolver chose it
  ok   the install record is FINAL, not the interim one it started from
  ok   commit= is the tree this deploy installed (C2)
  ok   lua_tree= names C2 (6ab125b0)
  ok   binary_commit= is the bytes' own build (C1), not the tree
  ok   and binary_release= names the release
  ok   record_expected= keeps the commit the staged binary was proved against
  ok   every recorded post-swap problem, if any, is the watcher
  ok   the install carries scripts/lib/download-asset.sh
  ok   the install carries scripts/lib/health-wakes.sh
  ok   wa --version names the OLD binary's release (node-82f5785944d6)
  ok   and the NEW tree (tree 6ab125b0)
  ok   the node the deploy started is running (pid 3404207)
  ok   verify-install's only FAIL lines are the two a scratch home forces (its verdict, and the sentinel)
  ok   and it does say the sentinel is not watching (the one thing this scratch install cannot have)
 deploy covering release ok (19 checks, 0 failed)
```

AND THIS IS THE FIRST GREEN THAT DOES NOT NEED THE LIVE NODE. The earlier "16 checks, 0 failed" included `verify-install
is green` with no FAIL line at all - which on a scratch home is impossible (the sentinel cannot start), so it could only
have passed because the deploy had talked to the operator's user manager and the operator's sentinel answered. A row
whose green depends on the live install is the defect that started this round.
