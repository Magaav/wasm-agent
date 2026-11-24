# target-is-what-installs (G blocker, Fable 24/11)

Branch `change/target-is-what-installs` from `origin/main` `65e3daef`. Three commits, local only, nothing
pushed, nothing built or installed on another node, no live node touched.

| commit | what it implements |
| --- | --- |
| `9bf1be0b` | item 1: `target_commit_at` records what a deploy would install; the rule stated once in `docs/DEPLOY-TARGET.md`, cited by `scripts/deploy.sh` rule 2 and by the function |
| `0500a2c3` | item 2: `installer_outcome` judges by the commit a request DEMANDED (`expected_sha`), the recorded target is advisory and can never fail an install |
| `e5f8813b` | item 3: the retry hint is a command `deploy.sh` accepts, the `request deploy` message stops saying "origin/main now", and the pause / "did not happen" / release lines are covered by rows |

## Premises, re-measured before writing code (the brief's facts were mostly right; two line ranges drifted)

| brief | measured on `65e3daef` | verdict |
| --- | --- | --- |
| `deploy_protocol.rs:449 target_commit_at()` | `pub(crate) fn target_commit_at` at 449, body 450-467: first readable `wa.deployRemote` main, else `origin/main` | right |
| `installer_outcome.rs:100` (the verdict) | 95-108 is `verdict(id)`; line 100 is `request.get("target_commit")…or_else(expected_sha)` - the ADVISORY target is read FIRST | right, and it is the defect |
| `lua/core/deploy_wait.lua:125` | `to = request.expected_sha or request.target_commit` at 125 | right |
| `deploy_pause` resume / "did not happen" lines | `(target commit …)` composed from `marker.to` at `lua/core/deploy_pause.lua:259` and `:289` | right |
| `deploy.sh:484-503` | the same rule is at **490-525** on this base (the `MAIN_REFS` loop at 495-510, the `ON_MAIN` check at 524). Off by six lines, nothing else differs. | line range stale |
| `deploy.sh:529-532` always refuses a stale expected SHA | the `EXPECTED_SHA` block is at 534-538 after my five-line citation (529-533 before it): `source changed from expected SHA before build` / `expected SHA is not exact origin/main` | right, line range stale |
| "It is not a downgrade (deploy.sh refuses a stale expected SHA)" | confirmed: 534-538 refuses an expected SHA that is not exactly HEAD **and** origin/main | right |

`origin/main` moved during the mission: `65e3daef` → `4bceddd5` (`land-quick: merge
change/whatsapp-acceptance`, 11 commits) while this branch was open. **Not rebased and not merged**, per "a
reviewed branch keeps its shape" and "don't rebase onto change/deploy-alive-holds"; the landing queue decides the
merge. Every measurement below is against the branch's own base `65e3daef`.

## 1. What is recorded is what a deploy installs (`9bf1be0b`)

`target_commit_at` now builds the same ref set `deploy.sh` rule 2 builds (`origin/main`, then each
`wa.deployRemote` main this checkout can resolve - no fetch, a request must not need the network to be written),
records **HEAD** when HEAD is on one of them and behind none of them, and **origin/main** otherwise. Never a named
remote's main; never a main behind `origin/main`. A question it cannot answer (unreadable ref, shallow history) is
not a yes: it falls back to `origin/main` rather than recording a commit `deploy.sh` would refuse.

**Can deploy.sh and the sentinel share the rule's statement in one place? Yes - implemented that way.**
`docs/DEPLOY-TARGET.md` holds the statement once ("## The rule"), `scripts/deploy.sh` rule 2 cites it (the comment
beginning "THE RULE IS STATED ONCE", `scripts/deploy.sh:490`) and `deploy_protocol.rs` cites it in
`target_commit_at`'s doc. `publish_loop_tests::the_target_rule_is_stated_once_and_both_halves_cite_it` reads the
document and both files at run time, so dropping a citation fails a test instead of waiting for the next drift.
The document also names the two places the halves are deliberately weaker (no fetch in the request path; with no
readable main at all `deploy.sh`'s rule does not run, and the sentinel records `origin/main` or nothing).

## 2. The verdict is judged by what was DEMANDED (`0500a2c3`)

`verdict(id)` reads `expected_sha` first and `target_commit` only when the request demanded nothing. The install
record is **positive evidence only** - it can say "installed", never "not installed"; what fails a request is the
installer's own terminal line or the absence of any evidence for it. `names()` compares a record's commit with a
request's commit on the shorter of the two lengths (the old `target.starts_with(installed)` read a 12-character
request against a 40-character record as "not installed").

## 3. The texts that carry it (`e5f8813b`)

* the retry hint in `fail_unobserved` carries `--expected-sha` only when the request DEMANDED one **and**
  `deploy_protocol::expected_sha_accepted()` says a deploy would still take it (HEAD == origin/main == that
  commit - the question `deploy.sh:534-538` asks); otherwise it asks for origin/main with no pin and says which
  absence it is. It is never a command `deploy.sh` must refuse;
* `request deploy`'s message says "what a deploy now would install" (it said "origin/main now", false for a
  checkout whose HEAD is the recorded commit), and the unreadable-tree message says what could not be read;
* the pause line, the "did not happen" line and the release line already take their commit from the request's own
  field; `scripts/test-deploy-target.sh` now proves what they print, end to end.

## Rows (passed / total), and what each is on the base

`cargo test --offline --manifest-path rust/wa-sentinel/Cargo.toml -- --test-threads=1` (under
`flock -o ~/Work/missions/.suite.lock`): **169 passed / 169**.

`bash scripts/test-deploy-target.sh`: **14 checks passed / 14**. Its own RED on the base (hand run in a separate
worktree at `65e3daef`, `base-wt`, base-built `wa-sentinel`):
`the request records the commit a deploy would install (origin/main): expected 6040f869…, got a6cb9611…` (the
bundle's main).

`scripts/test-deploy-wait.lua`: **63 checks passed / 63**. `scripts/test-deploy-pause.lua` (unchanged, run to
prove the new wait checks did not disturb it): **116 / 116**.

| row | base verdict |
| --- | --- |
| `publish_loop_tests::a_named_main_behind_origin_records_what_a_deploy_would_install` | **RED** (`left: ac5f614c…, right: ddb612ad…` - recorded the bundle's main) |
| `publish_loop_tests::a_request_written_in_that_checkout_records_what_a_deploy_would_install` | **RED** (the real `request deploy` door wrote `"target_commit":"ac5f614c…"`) |
| `publish_loop_tests::the_target_rule_is_stated_once_and_both_halves_cite_it` | **RED** (base has no `docs/DEPLOY-TARGET.md`) |
| `installer_outcome_tests::an_expected_sha_outranks_the_recorded_target` | **RED** (`Some(Uninstalled("no installer block …: the install record names 345e51be…"))` where the record names exactly what was demanded) |
| `installer_outcome_tests::a_record_naming_the_advisory_is_not_the_demanded_install` | **RED** (`Some(Installed)` for a commit the request never asked for) |
| `installer_outcome_tests::a_record_and_a_request_naming_the_same_commit_at_different_lengths_are_installed` | **RED** (12 against 40 → `Uninstalled`) |
| `installer_outcome_tests::the_retry_hint_never_offers_a_commit_deploy_sh_would_refuse` | **RED** (the hint carried the recorded target as `--expected-sha`) |
| `scripts/test-deploy-target.sh` (14 checks) | **RED** at check 4 (see its own output above) |
| `scripts/test-deploy-wait.lua` (the new checks) | **GREEN on the base by design**: the Lua reader already preferred `expected_sha`; the value it reads is what `9bf1be0b` fixed. Declared so nobody reads it as evidence of the fix. |
| `publish_loop_tests::a_named_main_ahead_of_origin_records_that_main` | **GREEN on the base by design** - the brief's item 4 row 2: behaviour unchanged for the laptop-sandbox case |
| `publish_loop_tests::a_tree_that_is_on_no_named_main_records_origin_main` | **GREEN on the base by design** (the base's fallback already answered `origin/main` here) |

`scripts/test-discriminates.sh 65e3daef`: **1 discriminating, 0 blocking, 1 unrevertable** - it judged
`scripts/test-deploy-target.sh` (discriminates) and named `scripts/test-deploy-wait.lua` unrevertable because this
branch changes `rust/` (the Lua rows would run against this tree's binary). **It listed no row for the two Rust
unit-test files**: `is_test_path` matches `test-*` or `tests/`, and `src/*_tests.rs` matches neither - a harness
gap that is not this branch's (their RED is the hand run recorded above, from the base worktree).

## Item 4's rows, as asked

* `wa.deployRemote` pointing at a bundle behind `origin/main`: recorded target = `origin/main` - Rust row 1 and
  the shell row (both RED on the base); outcome "installed" - `an_expected_sha_outranks_the_recorded_target`
  (RED on the base); the pause / "did not happen" / release lines name the installed commit - the shell row's
  checks 7-12, over the request the real sentinel wrote and the sentences the node's own Lua composes.
* the named main AHEAD of `origin`: behaviour unchanged - `a_named_main_ahead_of_origin_records_that_main`,
  green on both (declared above).

## What a test reads, and how it was checked

* The Rust rows read the sentinel's own stores, created by the product: `Fixture` sets `WASM_AGENT_HOME` and
  `WA_INSTALL_DIR` to a scratch pair, writes the request into `sentinel/done/<id>.json` in the shape
  `finish_request` writes, and writes `installed.txt` as `scripts/lib/install-record.sh` does (`commit=`), read
  back through the product's `deploy_outcome::installed_commit()`. Each fixture refuses to run when the scratch
  store is `$HOME/.wasm-agent/sentinel`.
* `a_request_written_in_that_checkout_records_what_a_deploy_would_install` does not write a request by hand: it
  calls `request(&["deploy", …])` - the door `wa-sentinel request deploy` uses - with `WA_DEPLOY_ROOT` at the
  fixture repository, and reads the file out of the box afterwards.
* `scripts/test-deploy-target.sh` runs two real processes: the real `wa-sentinel request deploy` writes the
  request into a scratch home, and `wa` (this checkout's Lua, `WASM_AGENT_LUA_ROOT=$ROOT`) reads it with
  `lua/core/deploy_wait.lua` and composes the sentences with `lua/core/deploy_pause.lua`. The one file the test
  writes is `installed.txt` in the installer's format - its only writer needs a built binary and a real swap,
  neither of which a test on a shared node may perform.
* No test calls the live fleet: no `wa` against a real home, no `tools.remote`, no node, no port, no
  rendezvous. The scratch base is `/tmp` because on this node `TMPDIR` is inside `~/.wasm-agent`, which
  `scripts/lib/scratch-home.lua` refuses (measured 24/11).

## Texts to approve

1. `no target commit recorded: the commit a deploy of the deploy tree would install could not be read`
   (`main.rs:3288`; was `no target commit recorded: origin/main of the deploy tree could not be read`)
2. `target commit {commit} recorded (what a deploy now would install; a later move of main does not change this request)`
   (`main.rs:3353`; was `… (origin/main now; a later move of main does not change this request)`)
3. `re-request with: wa-sentinel request deploy --reason '{reason}' --expected-sha {expected} (that commit is still exactly origin/main, so deploy.sh accepts it)`
4. `re-request with: wa-sentinel request deploy --reason '{reason}' (no --expected-sha: this request demanded no commit, and a commit it only recorded when it was written is not a pin deploy.sh would accept)`
5. `re-request with: wa-sentinel request deploy --reason '{reason}' (no --expected-sha: the commit it demanded is not exactly origin/main now, and deploy.sh refuses an expected SHA that is not)`
   (the old text was `re-request with: wa-sentinel request deploy --expected-sha {recorded target} --reason '{reason}'`)
6. `docs/DEPLOY-TARGET.md` - new file: the one statement of the rule, plus the two places the halves are
   deliberately weaker and the note that the recorded target is advisory.
7. `scripts/deploy.sh` rule 2 comment, new paragraph (operator-visible in the installer):
   `THE RULE IS STATED ONCE, in docs/DEPLOY-TARGET.md, and the sentinel's recorded target (rust/wa-sentinel/src/deploy_protocol.rs, target_commit_at) follows that statement: a change to it belongs in both places in one commit. Measured 24/11: the sentinel recorded a host bundle's main seven days behind because it read the named remote instead of the rule below, while this loop installed HEAD - and every text that spoke by the record named the stale commit.`
8. `SKIP test-deploy-target: no wa binary: set WA_BIN, or build rust/wa-host` / `SKIP test-deploy-target: no wa-sentinel binary: build rust/wa-sentinel` / `SKIP test-deploy-target: no writable /tmp for a scratch home outside the operator store` / `SKIP test-deploy-target: the scratch base is the operator store` / `SKIP test-deploy-target: no scratch directory under /tmp` (the row's own honest skips)
9. `deploy target ok (<n> checks)` (the row's success line, the shape its neighbours print)

## What I did not do, and what is not verified

* I did not run the whole `scripts/test.sh` gate (a release build of every crate, and the one-suite-at-a-time
  rule while other missions run); the crate suite, the two Lua rows and the new shell row are what ran here.
* I did not land, push, rebase or merge `origin/main` into the branch (it moved 11 commits ahead during the
  mission - `4bceddd5`), and I did not touch `change/deploy-alive-holds`'s files.
* The recorded target is only as good as this checkout's refs at request time: no fetch happens while a request is
  written (deliberate), so a checkout whose `origin/main` is stale records a stale `origin/main`. That is
  `deploy.sh`'s own state too, and it is revalidated there before it builds.
* Nothing here changes what `deploy.sh` installs; only what is recorded and what judges by the record.
