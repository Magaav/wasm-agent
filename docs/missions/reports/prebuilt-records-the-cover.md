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
