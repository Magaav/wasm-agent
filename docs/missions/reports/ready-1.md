# ready-1 - target-is-what-installs (G blocker, Fable 24/11)

Branch `change/target-is-what-installs`, base `origin/main` `65e3daef` (`origin/main` has since moved to
`4bceddd5`, 11 commits; not rebased, not merged - the landing queue decides). Clean, nothing pushed, nothing
installed anywhere, no live node touched. It lands together with `change/deploy-alive-holds` as one Rust install;
none of its files are touched.

## Commits

| commit | item | implements |
| --- | --- | --- |
| `9bf1be0b` | 1 | `target_commit_at` records what a deploy would install (HEAD when deploy.sh's rule would accept it, else origin/main); the rule stated once in `docs/DEPLOY-TARGET.md`, cited by `scripts/deploy.sh` rule 2 and by the function, guarded by a test |
| `0500a2c3` | 2 | `installer_outcome` judges by the DEMANDED commit (`expected_sha`); the recorded target is advisory and cannot fail an install; records compared at the shorter length |
| `e5f8813b` | 3 | the retry hint is a command `deploy.sh` accepts; `request deploy`'s message stops claiming "origin/main now"; pause / "did not happen" / release lines covered end to end |

Diff stat (`git diff --stat 65e3daef..HEAD`): **12 files changed, 757 insertions(+), 31 deletions(-)**
(`git diff --numstat`): `docs/DEPLOY-TARGET.md` 39/0 · `deploy_protocol.rs` 98/22 · `installer_outcome.rs` 54/7 ·
`installer_outcome_tests.rs` 214/0 · `main.rs` 2/2 · `publish_loop_tests.rs` 149/0 · `scripts/deploy.sh` 5/0 ·
`scripts/fast.sh` 4/0 · `scripts/lib/deploy-target-e2e.lua` 25/0 · `scripts/test-deploy-target.sh` 148/0 ·
`scripts/test-deploy-wait.lua` 14/0 · `scripts/test.sh` 5/0.

## Rows

| suite | passed / total |
| --- | --- |
| `cargo test --offline --manifest-path rust/wa-sentinel/Cargo.toml -- --test-threads=1` (under `flock -o`) | **169 / 169** |
| `bash scripts/test-deploy-target.sh` (new, wired into `scripts/test.sh:1426` and `scripts/fast.sh:1007`) | **14 / 14** |
| `scripts/test-deploy-wait.lua` | **63 / 63** |
| `scripts/test-deploy-pause.lua` (unchanged, run to prove nothing was disturbed) | **116 / 116** |
| `scripts/test-discriminates.sh 65e3daef` | 1 discriminating, **0 blocking**, 1 unrevertable (the Lua row, because the branch changes `rust/`) |

Seven rows are RED on the base, each measured in a separate worktree at `65e3daef` (never with `git stash`):
the stale bundle main is recorded (`left: ac5f614c…, right: ddb612ad…`), the real `request deploy` door writes it,
the doc-citation row, the three verdict rows (a demanded commit judged against the advisory one; an advisory record
read as "installed" for a commit never asked for; 12 against 40 read as "not installed"), the retry hint, and
`scripts/test-deploy-target.sh` (its check 4). Two rows are green on the base **by design** and are declared so:
`a_named_main_ahead_of_origin_records_that_main` (item 4's "behaviour unchanged") and
`a_tree_that_is_on_no_named_main_records_origin_main`; the new Lua checks are green on the base because the Lua
reader was already right - the value it reads is what `9bf1be0b` fixed.

`test-discriminates.sh` lists **no row for the two Rust unit-test files**: it treats `test-*` and `tests/` as
tests, and `src/*_tests.rs` matches neither. Their red-on-base is the hand run recorded in the report
(`docs/missions/reports/target-is-what-installs.md`), not a gate verdict - a harness gap, not this branch's.

## Reported, not negotiated

* **"Can deploy.sh and the sentinel share the rule's statement in one place?"** Yes, and they do:
  `docs/DEPLOY-TARGET.md` states it once; `scripts/deploy.sh:490` and `target_commit_at`'s doc cite it; a test
  reads the document and both files, so a dropped citation fails instead of waiting for the next drift.
* Brief facts that were stale: `deploy.sh:484-503` is this rule at **490-525** on this base, and the
  `EXPECTED_SHA` block called `529-532` is at **534-538**. The rest measured as the brief said.
* Not done: the whole `scripts/test.sh` gate (release build, one-suite-at-a-time while other missions run); no
  full-node install; nothing pushed.
