# change/deploy-ancestry — a deploy never silently goes backwards

Branch `change/deploy-ancestry`, now based on `origin/main` **e5ba9089** (round 4 rebased it; round 1 was based on
74d48431). Committed locally on this branch; nothing was pushed, nothing was deployed, no node was restarted.
Built and tested HERE on avell (`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-deploy-ancestry`).

This is the mission report and it lives here, per the review of 18/11 (round 4, item 3). Rounds 1 and 2 are
below, then rounds 3 and 4 in full, then round 5 (the round-1b merge of change/mission-fabric into this
branch). **There is no report of this mission at the repository root.** The root `REPORT.md` on this branch
is `main`'s (`# land-gate-fix`), byte-identical to `e5ba9089` and deliberately untouched: it is another
mission's file, and a branch that changes the review's mind about a root REPORT.md deletes someone else's
work to satisfy a naming rule.

## What was measured, and what it produced

MEASURED 18/11 (the mission's premises, re-checked on the live nodes while doing this work):

| node | installed.txt claims | the bytes actually are |
|---|---|---|
| mail | `commit=842868c1`, `sha256=71094f2a` | sha256 `71094f2a` ✓, but the binary predates `--build-info` |
| nextcloud | `commit=unknown`, `sha256=38d31dd0` | sha256 `586b244c` — **the record's sha256 is not these bytes** |
| work | `commit=14963b6f`, `sha256=4248d61b` | sha256 `fc6a9d80` — **the record is not these bytes** (the codeact build) |
| **avell (this node)** | commit=14963b6f, sha256=4248d61b | sha256 fc6a9d80 - **the same bytes as work**, on the coordinator itself |

That table is the whole argument for rule 1: a record written by the installing party was wrong on two of three
nodes, and the previous guard compared the tree against that record.

## A finding while seeding: the coordinator runs the same unlanded build

`/home/victor/.local/bin/wa` on this node is sha256 `fc6a9d80` - the same bytes as `work` - and its
`installed.txt` claims `commit=14963b6f`. So the 18/11 shape was not a peer's problem: the node that decides
deploys could itself have been replaced by a deploy of main, because `14963b6f` is an ancestor of main and the old
guard believed the record. That is why the guard now checks the record against the bytes (`wa_record_describes`,
`downgrade_unprovable(record_not_this_binary)`): on this node a deploy of main would now refuse and ask for
`--force --reason` instead of quietly removing the codeact build. No pin was seeded for avell (the mission named
three nodes); the mechanism can record one with `wa update avell --pin --bytes fc6a9d80...` once the operator
decides which way the coordinator should go.

## The five rules, and where each one lives

1. **The binary answers for itself.** `rust/wa-host/build.rs` compiles in commit, tree, dirty and every ancestor;
   `rust/wa-host/src/build_info.rs` renders `wa --build-info` and `wa --contains <commit>` (exit 0/1/2), both
   dispatched in `main` before the home, env file, database, graph index or Lua tree is touched.
2. **Every install path writes installed.txt FROM the binary.** `scripts/lib/install-record.sh`:
   `wa_record_install` (one writer; drops and names a caller's `commit=`) and `wa_ancestry_verdict` (one verdict).
   Wired into `scripts/deploy.sh`, `scripts/upgrade.sh`, `scripts/fleet-install.sh`,
   `scripts/linux/bootstrap.sh`, `scripts/rollback-node.sh`; `deploy.sh` ships the lib to
   `<install>/scripts/lib/install-record.sh`. A deploy whose bytes report another commit than the one it meant to
   install refuses (`refused(build_commit_mismatch)`).
3. **The ancestry guard asks what is RUNNING.** `deploy.sh` and `upgrade.sh` ask the installed binary, fall back
   to the record only when the binary cannot answer (and say so), print the commits that would be lost, and take
   the override only from `--force --reason <text>`, recorded in `deploy.log` and `installed.txt`.
   `fleet-install.sh` and `bootstrap.sh` ask the candidate binary's embedded ancestry (no checkout on a release
   node); `upgrade.sh` takes `WA_UPGRADE_FORCE_REASON` as its recorded override.
4. **Only a shared commit may be published.** `scripts/publish-node-binaries.sh` refuses
   `commit_not_on_pushed_branch` (naming the local branches that do contain it), allows a detached HEAD only
   when a pushed branch contains the commit, and records `pushed_branches=` / `unpushed=` in the manifest.
5. **Going back is a record.** `lua/core/pins.lua` (store, writer, overdue, release-by-awaited-commit),
   `wa update <node> --rollback|--to|--pin|--unpin` in `lua/core/remote_update.lua`, the gate in
   `M.request` and in `lua/core/update.lua` (local update), and `lua/core/fleetview.lua` for the report.
   Documented in `docs/DEPLOY-ANCESTRY.md`.

## Seed pins (written through the new mechanism, on this node's store `/home/victor/.wasm-agent/pins.txt`)

Each pin names the **bytes** (sha256 read from the node itself) because none of the three binaries can name its
own commit yet — they predate `--build-info`:

- `mail` → `71094f2a…`, until "release-glibc lands"
- `nextcloud` → `586b244c…`, until "release-glibc lands"
- `work` → `fc6a9d80…` (the change/codeact build), until "the change/codeact commits land on main"

Verified live: `wa update mail --reason "an ordinary fleet deploy"` now answers
`mail node_pinned: … reason … until release-glibc lands` and names the ways out, before anything reaches the
transport.

## Verified (commands run, results read back)

| test | checks | result |
|---|---|---|
| `scripts/test-build-info.sh` | 20 | 0 failed — fields, commit/tree/dirty against git, every `--contains` exit code, works with no HOME |
| `scripts/test-install-record.sh` | 35 | 0 failed — writer, caller `commit=` dropped, dead/hanging binary, ancestry verdicts, a real `rollback-node.sh` restore, and the REAL binary's record equal to its own `--build-info` |
| `scripts/test-deploy-ancestry.sh` | 25 | 0 failed — refusal with the lost commit's subject, `--force` without reason refused, `--force --reason` recorded in deploy.log, record-as-fallback |
| `scripts/test-publish-shared-commit.sh` | 15 | 0 failed — unpushed commit, pushed branch, detached HEAD both ways, named override, manifest fields |
| `scripts/test-node-pins.sh` | 38 | 0 failed — store, supersede/history, overdue, clear-as-record, CLI `--pin`/`--unpin`, gate refusal, fleet view |
| `scripts/test-fleetops.lua` (existing) | 147 | 0 failed |
| `node scripts/check-deploy-docs.mjs` | 6 | ok |
| `cargo test -p wa-host build_info` | 4 | ok |

A bug the tests found, and fixed: `build.rs` read an empty `git status --porcelain` (a CLEAN tree) as a git
failure, so every clean build reported `dirty=unknown` - the wrong answer in the one field a deploy could use to
ask "are these bytes exactly this commit?". `test-build-info.sh` caught it on its first run against a clean tree.

Also verified by hand: the built binary reports `commit=74d48431…`, `tree=8a946b5c…`, `dirty=true` (the tree was
being edited), `ancestors=137`; `--contains` answers 0 for itself and 1 for an absent commit.

## Pre-existing failures (reproduced on the base commit, `/tmp/base-wt` at origin/main)

- `scripts/test-deploy-record.sh` — fails on base too (`ROOT: unbound variable` in the script's extracted
  fixture). It now also needs `wa_build_info`/`note` in that fixture; the base failure is the same shape and
  predates this work.
- `scripts/test-deploy-preconditions.sh` — fails on base too: run from inside a node turn, `turn-guard` refuses
  before the WSL case it asserts ("the WSL shell was not refused by name").
- `scripts/test-deploy-downgrade.sh` self-skips here (tree not on a clean main). It tested the record-based rule,
  which no longer exists; its cases now live in `test-deploy-ancestry.sh` and the file is a hand-over shim so the
  name in docs/TORUS.md and the gate measurement list keeps pointing at a real test.

## Not verified (stated, not hidden)

- `deploy.sh`/`upgrade.sh`/`bootstrap.sh` end-to-end installs were **not** run: each installs a node, and the
  mission is explicit that this is one node's live install. What is proven is the gate (tested end-to-end through
  the real `deploy.sh`) and the writer (tested through a real `rollback-node.sh`); for the other three the test
  asserts they route through the same library. So "installed.txt equals `--build-info` after each install path"
  is verified for `rollback-node.sh` and structurally (one writer, no path with an identity of its own) for the
  rest — not by an install run.
- The `ancestry_override=` line in **installed.txt** (as opposed to `deploy.log`) is implemented in
  `record_installed` but was not observed end-to-end, because that needs a completed install.
- Pins gate the coordinator's deploys (the node that runs `wa update <node>`), not a deploy started on the target
  node by other means; that case is covered by the ancestry guard instead. This is a deliberate split, written
  down in `docs/DEPLOY-ANCESTRY.md`.
- `ALLOW_UNPUSHED_COMMIT=1` was not exercised on a real cross build.

## Not done / left as it was

- Nothing was pushed; no deploy, rollout or restart was performed on any node.
- `wa-sentinel` was not rebuilt (its workspace is separate and this change does not touch it).
- The `work` build's 8 unlanded commits were not landed (not this mission's work), so its pin awaits them.

---

# deploy-ancestry — round 2: unknown refuses, everywhere

Branch `change/deploy-ancestry`, base `origin/main` 74d48431. Round 1 ended at 87aeb365 and was reviewed; this is
the answer to that review, item by item. Committed locally on this branch; **nothing was pushed**. Built and tested
on avell (`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-deploy-ancestry`).

The principle the review set, and the one this round implements: **UNKNOWN REFUSES (fail closed) unless
`--force --reason`** - on every path, in the same words, with the override recorded.

## What was wrong, in one sentence per item

| # | the review's finding | what it was, precisely |
|---|---|---|
| 1 | the guard fails open on the 18/11 scenario | `wa_ancestry_verdict` answered 2 ("cannot tell") whenever the running commit was absent from the deployer's checkout, and `deploy.sh` only noted a 2 and installed |
| 2 | an old binary was treated as free | `fleet-install.sh`/`bootstrap.sh` asked only the binary (no answer = no question), `upgrade.sh` trusted `installed.txt`'s commit without `wa_record_describes` |
| 3 | a shallow build claimed a complete ancestry | `build.rs` set `ANCESTORS_COMPLETE=true` for any list containing HEAD, so `--contains` answered "no" (a refusal) for commits below the cut |
| 4 | `--force` without `--reason` was accepted | `deploy.sh` parsed it and only some gates demanded a reason; `remote_update.lua` bypassed a pin on `force == true` alone |
| 5 | pins blocked their own fix | release required `target == await` exactly and the gate passed an empty tree, so a plain `wa update` never released; `--rollback` wrote `commit=unknown` with no await |
| 6 | the pin lived only in the coordinator | the node's own `update.lua`/`upgrade.sh`/`fleet-install.sh`/`bootstrap.sh` read nothing, and a pin written under a name was not found by a request addressed to the node id |
| 7 | a local, stale `refs/remotes/*` counted as "published" | `for-each-ref --contains ... refs/remotes/` answers with a memory of a fetch, not with what the remote has |
| 8 | a `dirty=true` running binary was replaceable for free | its bytes are a commit PLUS uncommitted edits, which no commit contains and the commit-level question cannot see |
| 9 | `bootstrap.sh:304` ran a command inside its own message | backticks between double quotes: the refusal executed `wa update <node> --rollback` |

## What was changed, and the test that fails without it

**1. A missing running commit is a refusal, and a shallow clone is not the same thing.** `scripts/lib/install-record.sh`:
the verdict now asks the RUNNING binary first (`wa --contains <target>` - if the running build already contains the
target and they differ, the target cannot contain the running build: no commit is its own ancestor), then:
a COMPLETE history that does not carry the running commit is **verdict 1** ("the running build is not in this
history"); a SHALLOW one is 2, naming `git fetch --unshallow`; and "not an ancestor" inside a shallow clone is 2 only
when the walk from the running commit actually reaches the `.git/shallow` boundary (`wa_ancestry_truncated`), so a
shallow clone is not turned into a blanket "cannot tell". `deploy.sh` tries one bounded `git fetch --unshallow`
(`wa_ancestry_fetch_missing`) before refusing, and **a verdict of 2 now refuses** (`refused(ancestry_unknown)`)
without `--force --reason`.
Test: `scripts/test-deploy-ancestry.sh` — "the exact 18/11 case" builds a commit in another repository (absent from
the deployer's history), puts `commit=<an ancestor of this tree>` in `installed.txt`, and asserts the refusal names
the running commit and says it is not in this history, with the record untouched. The same file covers the shallow
case (`refused(ancestry_unknown)`, "fetch --unshallow") and the recorded override.
Result: **51 checks, 0 failed**; `scripts/test-install-record.sh` **56 checks, 0 failed** (full/shallow/absent,
`wa_running_identity`, and the real binary's record equal to its own `--build-info`).

**2. The same record-vs-bytes question on every install path.** `wa_running_identity` (one answer to "what is running
here": binary first, the record only when its `sha256=` is the binary's, a first install kept distinct from
ignorance) is now used by `deploy.sh`, `upgrade.sh`, `fleet-install.sh` and `linux/bootstrap.sh`. Each refuses
`downgrade_unprovable(record_not_this_binary)`, `refused(ancestry_unknown)` and `downgrade refused(dirty_running_binary)`
without `--force --reason`. (`fleet-install.sh` also had a plain bug: `FORCE=0; REASON=""` after the argument loop
wiped the `--force`/`--reason` it had just parsed, so its override had never worked.)
Test: `scripts/test-install-guards.sh` drives `fleet-install.sh` end to end (a `file://` artifact, stub binaries, a
local `http.server` for `/health`, `pkill` shadowed): record-vs-bytes refused, dirty refused, an artifact that cannot
answer refused, a first install NOT refused (and it installs, and the record is the artifact's own build), and
`--force --reason` recorded in `installed.txt`. `upgrade.sh` and `bootstrap.sh` cannot be run without installing a
node, so for them the test asserts the route (same function, same refusals, no "carrying on") — see "not verified".
Result: **44 checks, 0 failed**.

**3. `ANCESTORS_COMPLETE` is false in a shallow build clone.** `rust/wa-host/build.rs` asks
`git rev-parse --is-shallow-repository` and prints a `cargo:warning` when it is true; `--contains` then answers
`unknown` (2) for a commit it does not carry instead of `no` (1).
Test: `scripts/test-build-info.sh` asserts the field and the verdict agree with the checkout the binary was built
from (this worktree IS a shallow clone, so the case is live here); the Rust unit test accepts both verdicts
according to `ANCESTORS_COMPLETE`.
Result: **24 checks, 0 failed**; `cargo test -p wa-host build_info`: **4 passed**.

**4. A force is a named, recorded act.** `deploy.sh` refuses `--force` with no (or blank) `--reason` at the parser,
before anything is resolved or built, and every force writes `force_requested reason= by= at=` plus what it
overrode (`overrode=`, `ancestry_replaced=`, `ancestry_target=`). `remote_update.lua` refuses `--force` on a pinned
node without a reason (`override_reason_required`) and records the force as a pin-history entry
(`kind=force`, "FORCED PAST: <reason> (pin <id>: <its reason>)"). `update.lua`'s local gate does the same.
Test: `test-deploy-ancestry.sh` (the parse-time refusal, the `force_requested` line, and that nothing was resolved),
`test-node-pins.sh` (`--force` alone refused by name, `--force --reason` reaches the transport, the pin history
carries "FORCED PAST"), `test-remote-update.lua` (`override_reason_required`).

**5. A pin releases by ancestry, and a rollback records what it went back from.** `pins.released` releases when the
target IS the pinned commit, IS the awaited commit, or CONTAINS it (asked of git in a tree the caller passes -
`remote_update.lua` now passes the coordinator's own runtime tree instead of `''`). A release is written as a record
(`kind=released`), so a plain `wa update <node>` that contains the awaited commit moves the node and clears the pin
in one act. A rollback pin records `rolled_back_from=` and defaults `await=` to that commit, and the answer carries
`pin_next` naming `--unpin`, a releasing target and `--force --reason` (`pins.escape_hatch`).
Test: `test-node-pins.sh` — a descendant of the awaited commit releases the pin, the awaited commit itself releases
it, no checkout is "unknown" (never "released"); `test-remote-update.lua` — a rollback's pin carries
`rolled_back_from` and `await` (it used to say `commit=unknown` with no await).

**6. The pin is on the node too, and aliases resolve before the gate.** A rollback writes the same pin into the
NODE's own `pins.txt` (and it is refreshed with the restored commit when the outcome is read);
`scripts/lib/node-pins.sh` is the shell reader; `upgrade.sh`, `fleet-install.sh` and `linux/bootstrap.sh` refuse
`node_pinned` without `--force --reason` (`WA_UPGRADE_FORCE_REASON` for `upgrade.sh`). Records carry `node_id=` and
`pins.active(name, node_id)` matches either spelling, so a request addressed to `<node_id>` finds a pin written
under the node's name and the reverse.
Test: `test-remote-update.lua` (the node's own store gets `kind=rollback`, `rolled_back_from`, `await`, `node_id`;
the coordinator writes its own), `test-node-pins.sh` (name, id, both, and a different node not matching),
`test-install-guards.sh` (the fleet path refuses a node that carries its own pin, finds one recorded under the node
id, and installs over it with a recorded `--force`).

**7. One shared-commit answer, asked of the remote.** `scripts/lib/shared-commit.sh`: `wa_commit_shared <repo> <commit>
[remote]` → 0 shared (prints the branches), 1 not shared, 2 cannot tell; it uses `git ls-remote --heads` and
containment against the heads the remote reports. Used by `publish-node-binaries.sh` (refuses on 1 AND 2, names the
local branches, manifest `pushed_branches=` now comes from that answer), `publish-components.sh` (exit 7),
`deploy.sh` (refuses `refused(commit_not_on_pushed_branch)` BEFORE it builds, then requires the same answer of the
ship step via `WA_SHIP_REQUIRE_SHARED=1`), `ship-wave.mjs`, `codemode-build.mjs` (receipt `source_shared=`; a ready
receipt only for a shared commit) and `lib/fast-binary.sh` (which records `source_shared=` in the build itself -
`wa --build-info` - instead of refusing to build an unlanded branch; see "the one place that records instead of
refusing" below).
Test: `scripts/test-publish-shared-commit.sh` now uses a real bare remote and real pushes, and asserts the exact
hole: a local `refs/remotes/origin/main` naming a commit the remote does not have is **not** an answer (verdict 1,
and the publisher still refuses), containment through a pushed head, a detached HEAD both ways, and an
unanswerable remote refusing. `test-deploy-ancestry.sh` adds the deploy path: a clone whose `origin` has no branch
containing its HEAD is refused `refused(commit_not_on_pushed_branch)` ("no branch contains it", "Nothing was built
and nothing was installed") with nothing installed, and `--force --reason` goes on and records
`commit_not_on_pushed_branch accepted with --force --reason`.

**8. A dirty running binary refuses.** `deploy.sh` and the other three paths refuse
`downgrade refused(dirty_running_binary)` when the running binary reports `dirty=true`, and
`refused(ancestry_unknown)` when it reports `dirty=unknown` (a partial answer is not a clean one).
Test: `test-deploy-ancestry.sh` (refused by name, record untouched, `--force --reason` goes on and records
`running_dirty=true`), `test-install-guards.sh` (the fleet path).

**9. No command inside a message.** `bootstrap.sh`'s refusal quoted the sentinel's command between double quotes;
it is single-quoted now, and `test-install-guards.sh` checks every installer for the shape
(`grep -E '(fail|say|die|note|printf|echo) "[^"]*``'`), with the shipped line as its fixture.

## Verified (commands run, results read back)

Run at commit c84d0498, on this node, after a clean rebuild of `wa` from that commit (the binary reports it).

| test | result |
|---|---|
| `scripts/test-install-record.sh` | 56 checks, 0 failed |
| `scripts/test-deploy-ancestry.sh` | 58 checks, 0 failed |
| `scripts/test-install-guards.sh` (new) | 44 checks, 0 failed |
| `scripts/test-node-pins.sh` | 56 checks, 0 failed |
| `scripts/test-publish-shared-commit.sh` (rewritten) | 33 checks, 0 failed |
| `scripts/test-build-info.sh` | 24 checks, 0 failed |
| `node scripts/test-ship-wave.mjs` / `test-wave-ship.mjs` | 14 / 21 checks, 0 failed |
| `node scripts/check-deploy-shipped.mjs` | 179 checks, ok |
| `node scripts/check-deploy-docs.mjs` | 6 checks, ok |
| `cargo test -p wa-host build_info` | 4 passed |
| `scripts/test-remote-update.lua` | 75 checks, ok (was 60) |
| `scripts/test-fleetops.lua` | 147 checks, 0 failed |
| `test-update-all / -banner / -release / -watcher` .lua | 43 / 227 / 16 / 45 checks, ok |
| `bash scripts/publish-components.sh --check` | refused `commit_not_on_pushed_branch` (this branch is unlanded - the check working) |
| `node scripts/ship-wave.mjs . <tmp>` | refused `commit_not_on_pushed_branch` (same) |

## Pre-existing failures (reproduced on the base, `origin/main` 74d48431, in a clean worktree at /tmp/base-r2)

- `scripts/test-deploy-record.sh` — fails on the base too (`ROOT: unbound variable` in its extracted fixture). On
  this branch it fails at the same line and additionally prints `wa_build_info: command not found` / `note: command
  not found` for that fixture, which does not source `scripts/lib/install-record.sh`; the base failure is the same
  shape and predates this work (round 1 said the same).
- `scripts/test-deploy-preconditions.sh` — fails on the base too: run from inside a node turn, `turn-guard`
  refuses before the WSL case it asserts ("the WSL shell was not refused by name").

## The one place that records instead of refusing (stated, not hidden)

`scripts/lib/fast-binary.sh` builds the DAY-TO-DAY developer binary, and this repository lands a change AFTER
building it, so refusing to build an unlanded commit there would refuse every change before it lands (and the
deploy that lands it). It asks the one shared question and RECORDS the answer in the build
(`WA_BUILD_SOURCE_SHARED` → `source_shared=yes|no|unknown` in `wa --build-info`), which is the fact an install
path would need; the paths that PUBLISH or PUT code on a node (`publish-node-binaries.sh`, `publish-components.sh`,
`deploy.sh`, `ship-wave.mjs`) refuse. `codemode-build.mjs` does the same in its receipt and refuses to write a
ready receipt for an unshared commit.

## Not verified (stated, not hidden)

- `upgrade.sh` and `linux/bootstrap.sh` were not run end to end: each installs a node, and doing that here would
  replace this machine's node. What is proven for them is (a) the shared functions they call
  (`wa_running_identity`, `wa_node_pin_gate`, `wa_ancestry_verdict`, `wa_record_describes`) behave as tested, and
  (b) that they call them and refuse by those names (structural assertions in `test-install-guards.sh`).
- `fleet-install.sh`'s install path IS exercised (a scratch directory, a stub artifact and a local `/health`), but
  its restart/recovery against a REAL systemd unit was not, and its `pkill` is shadowed in the test.
- A DEEP (non-shallow) build reporting `ancestors_complete=true` was not observed here: this worktree is a shallow
  clone, so the shallow case is the one that ran. The rule is asserted in both directions (field and verdict agree).
- `deploy.sh`'s `commit_not_on_pushed_branch` precondition was exercised in both directions on a fixture whose
  `origin` is a bare repository with no matching branch (refused, then accepted with `--force --reason`); it was
  not exercised against this project's real remote.
- `source_shared=` is only ever `unknown` in the binaries built here (nothing stamps it except
  `lib/fast-binary.sh`), so no install path refuses on it yet; no rule reads it.
- The exit-path of the release (`kind=released`) was verified by the store's own test, not by a live deploy that
  released a pin.
- `deploy.sh` now asks the REMOTE before it builds, so a checkout with no `origin` at all (or one that cannot be
  reached) refuses without `--force --reason`, where it used to deploy. That is the fail-closed rule as the review
  stated it, but it is a behaviour change on an offline machine and it is named here rather than discovered.

## Not done / left as it was

- Nothing was pushed; no deploy, rollout or restart was performed on any node.
- The three pins seeded in round 1 in this node's store are untouched.
- `wa update <node>` against a live peer was not run: the transport needs a real peer and this round changed what
  happens BEFORE it (the gate).

---

## Round 3 (already on this branch; summary)

Round 2's review asked for one thing in eight shapes: **unknown is not yes**. The eight, and what each became,
are in the round-3 item table that used to head this file's root copy, and in the commits `47e3ad01`,
`ff427897`, `8f1d202d`, `c21f1499`: a binary that cannot name its commit is `unprovable` (refuses) instead of
a first install; a rollback pin has no default `await`; `--unpin` needs a reason and reaches the node's own
store; `deploy.sh --force` carries `WA_UPGRADE_FORCE_REASON` into the installer; the pin is read before the
build; `wa_commit_shared` asks the remote (bounded fetch); the `--contains` probe is bounded and scrubbed;
`ALLOW_UNPUSHED_COMMIT` needs `ALLOW_UNPUSHED_REASON`. Round 3 also closed a set of fail-opens found while
reading (rollback-node.sh saying nothing about an unidentifiable restore, upgrade.sh's plan parser, the
sentinel's deploy door). One of those - the sentinel script-pin rule - is reverted in round 4, item 8.

## Round 4 (review of 18/11 21:40): the eight items

### Item 2 first: the rebase onto e5ba9089

43 commits behind, 26 replayed, three conflicts, all resolved by hand:

| file | conflict | resolution |
| --- | --- | --- |
| `scripts/deploy.sh` (twice) | the library `for` list | **union**: `build-status build-requirements deploy-components node-binaries glibc-floor retire-unshipped install-record node-pins runtime-binding` |
| `REPORT.md` (twice) | add/add with main's `# land-gate-fix` report | main's file kept byte-identical; this mission's report is this file (item 3) |

Where the two checks the review named now sit, on the rebased file (line numbers as of the last commit here):

| check | line | why there |
| --- | --- | --- |
| canonical runtime binding preflight | 0c, 406-427 (the empty assignment at 415) | before the build: it is a fact about THIS tree and its ~4-minute cost is paid once, not after a build. The answer is kept in `WA_RUNTIME_PREFLIGHT` and NOT exported, so step 6's install-time re-check still asks again |
| glibc floor guard | 1230-1249, the call at 1243 | after the candidate binary exists and **before it is executed** (`--capability-digest` at ~1257): a binary that needs a newer glibc dies at that line with a sentence about a broken artifact, which is true and useless |
| the ancestry gate (this mission) | 549-700 | before the build: a deploy that would go backwards refuses without compiling |
| the node's own pin gate (this mission) | 3b, ~705 | before the build, for the same reason |

So the order on a deploy is: what is running (ancestry) -> where this node was put on purpose (pin) -> may this
tree run at all (runtime binding) -> is the artifact runnable here (glibc) -> build -> prove -> install.

**The rebase broke two of main's own fixtures, and both breakages were this branch's rules surfacing.** Fixed
here, because a fixture that stops at an earlier refusal measures the wrong rule:

| fixture | what it assumed | what it does now |
| --- | --- | --- |
| `scripts/test-glibc-floor.sh` (standalone + curl shapes) | a copy of `fleet-install.sh` with no libs can install | the fixture ships `install-record.sh` and `node-pins.sh` (round 3: not optional) and withholds only `glibc-floor.sh`; **and a new case asserts the libless copy refuses `install_record_lib_missing`, exit 2** |
| `scripts/test-update-ring.sh` (the record step) | `record_installed` writes `binary_inputs=` for the caller's `COMMIT` | the fixture installs a binary that answers `--build-info` with the commit under test and sources `install-record.sh`: the digest is of the commit the RECORD names, as before, but the record's identity now comes from the bytes |
| `scripts/test-deploy-ancestry.sh` (this mission's) | the fixture clone was on whatever branch this worktree is on | first case to fail after the rebase: main's runtime-binding preflight refused all 46 ancestry assertions with `found 0 on branch refs/heads/main`. The fixture now puts its own clone on branch `main` (the shape the rule asks for) and keeps the preflight running |

### Item 1: fail-open in `wa_running_identity` (the one that installed and claimed an override)

The rule was `record is not about these bytes` -> `unprovable`. A record whose `sha256=` IS the binary's and
whose `commit=` is empty or `unknown` therefore fell through to the fallback, found nothing to claim, and left
`source=none, commit=`, which `deploy.sh` reads as a first install: it installed over the node and printed
`the override above was recorded as ancestry_unverified=yes` with **no override given**.

Fixed in two places, because the sentence and the verdict are two different lies:

- `scripts/lib/install-record.sh`, the line the review names (303; 311 now that this round's comment sits above it): the test is now `record IS NOT about these bytes **or** the record names no commit`. `source=unprovable`, with a `WA_RUNNING_WHY` that says which of the two it is: a record about these very bytes that names no `commit=` (either spelling, `unknown` is blanked by the read above), versus no record at all.
- `scripts/deploy.sh:625`: the sentence is printed **only when an override was given** (`ANCESTRY_UNVERIFIED=yes`). Any other empty running commit at that line is `refused(ancestry_override_unrecorded)` - a guard, not a path: it refuses rather than telling the operator an override was recorded.

Proved by two new cases, in two files, written before the fix:

- `test-install-record.sh`: `commit=unknown` + the binary's sha256, and `commit=` blank + the binary's sha256 -> `source=unprovable`, not a first install, and the sentence says `names no commit`.
- `test-deploy-ancestry.sh`: the same install through `deploy.sh`: refused `running_commit_unprovable`, no first-install sentence, **no override sentence**; and with `--force --reason` the override sentence appears *and* `overrode=running_commit_unprovable` is in `deploy.log`.

### Item 5: the guards test read the real home

`test-install-guards.sh` set `FLEET_HOME=` empty for the cases that needed no pin store, and empty means `pass
no WASM_AGENT_HOME` - so `fleet-install.sh` fell back to the operator's `~/.wasm-agent`: the real pin store and
the real node name. Now: a scratch `HOME` and `WASM_AGENT_HOME` are exported at the top, `FLEET_HOME` starts
from that scratch home, no case can unset it, and `scratch_home_required` runs before **every** `fleet-install.sh`
invocation and refuses `refused(test_needs_scratch_home)` if the effective home is this machine's real one.

### Item 6: `WA_ALLOW_UNVERIFIED_UPGRADE=1` was an override with no reason

It is now a two-part override, like every other one in these scripts: the switch says WHAT is waived, and
`WA_UPGRADE_FORCE_REASON` says WHY. Alone it is `refused(override_reason_required)`; together the reason reaches
`installed.txt` as `ancestry_override=` and `deploy.log` gets `force_requested rule=candidate_commit_unknown`.

### Item 7: pins already on live nodes carry `await=rolled_back_from`

No migration: the store is append-only and a new build silently rewriting it is a worse risk than a rule at the
read. On read - in **both** readers, `lua/core/pins.lua` (one `M.parse`, which every Lua reader goes through)
and `scripts/lib/node-pins.sh` (the install side) - an `await` equal to `rolled_back_from` is treated as no await,
and says so in one line: `await <12> IGNORED (...)`. A record that NAMED that commit explicitly is kept: the
writer now stamps `await_explicit=yes` when the caller passes an await, so a statement and a default are not the
same input any more (legacy records have no marker and get the rule).

### Item 8: the sentinel `shipped_wins` change, reverted

Round 3 replaced the mtime comparison in `resolve_script` with a three-valued `shipped_wins` in which
**cannot compare -> the shipped copy wins**. That is a behaviour change nobody asked for, it was outside this
mission's brief, and the article that carried it (script-pin staleness) already has a rule on this branch: the
audit line names the case whenever the comparison says the shipped copy is newer. The test it arrived with
asserted the new behaviour, which is not evidence that the behaviour was required. Reverted to main's code
verbatim (with a comment saying why); the Rust suite passes, 134 tests.

### Item 3: the report

This file. The root `REPORT.md` on this branch is main's `# land-gate-fix`, untouched and byte-identical to
`e5ba9089` - see the header. The round-2 and round-3 text that used to live at the root is folded in above.

### Item 4: the seven tests are wired

`scripts/test-orphan-tests.mjs` reported five of them as orphans before this round (the ledger doing its job:
every gate in this repository was green without running one of them). Now:

| test | full gate (`scripts/test.sh`) | fast path (`scripts/fast.sh`) | measured standalone |
| --- | --- | --- | --- |
| `test-install-record.sh` | yes, `WA_BIN=$BIN` | yes | 5 s, 84 checks |
| `test-install-guards.sh` | yes | yes | 1 s, 70 checks |
| `test-deploy-ancestry.sh` | yes | **no, and here is why** | 31 s, 89 checks |
| `test-node-pins.sh` | yes, `WA_BIN=$BIN` | yes | 3 s, 87 checks |
| `test-publish-shared-commit.sh` | yes | yes | 1 s, 43 checks |
| `test-bootstrap-gate.sh` | yes | yes | 1 s, 35 checks |
| `test-build-info.sh` | yes, `WA_BIN=$BIN` | yes | 1 s, 24 checks |

`test-deploy-ancestry.sh` is deliberately not a fast-path row: it runs a real `deploy.sh` detached (`setsid
--fork`) once per case, 31 s measured, and it is the only one of the seven whose cost is not seconds. The fast
path is the landing gate; half a minute per round for a rule the full gate already owns is the wrong trade, and the
number is here so the choice can be reviewed rather than discovered. The merge lane runs `scripts/test.sh`, so
it inherits all seven.

Three of the seven need a tool the host may not have, and now say so instead of failing inside a half-run
install: `test-deploy-ancestry.sh` needs `setsid` and `git`, `test-install-guards.sh` needs `curl` and
`python3` (the bootstrap gate already skipped for a missing C compiler).

### Failing-then-passing, measured

| case | before | after |
| --- | --- | --- |
| item 1, `test-install-record.sh` | `so the source is unprovable, not none: got none want unprovable`; `a blank commit= beside these bytes is unprovable too: got none`; and the sentence came out as `nothing is installed in ...` | 84 / 0 failed |
| item 1, `test-deploy-ancestry.sh` | the fixture runs the committed code, so the first run of the new case ran the OLD library and showed the hole exactly: no refusal, `the override above was recorded` with no override, then `refused(no_prebuilt_binary)` further down | 89 / 0 failed |
| item 7, `test-node-pins.sh` | with `HEAD~1:lua/core/pins.lua` in place: `its await is ignored, not honoured: got no want yes`, `so a target CONTAINING that commit does NOT release it: got true want false`, and three more - the pin was RELEASED by the move it exists to stop | 87 / 0 failed |
| item 5, `test-install-guards.sh` | a copy with the two exports removed, run against a fabricated real home that carries a pin store: `refused(test_needs_scratch_home) ... (rc=2)` | 70 / 0 failed, and the fabricated home is never read |
| item 6, `upgrade.sh` | `WA_ALLOW_UNVERIFIED_UPGRADE=1` alone installed the unidentifiable candidate | refused `override_reason_required`; with the reason: `force_requested rule=candidate_commit_unknown`, and the stub stops at the scratch proof with nothing installed |
| item 2, the rebase | `test-glibc-floor.sh`: two shapes stopped at `install_record_lib_missing` (exit 2), `test-update-ring.sh`: `installed.txt binary_inputs=, wanted 84a44c73...` | 112 / 0 and 26 / 0 |

### Verified (commands run here, results read back)

| suite | verdict |
| --- | --- |
| `test-install-record.sh` | 84 checks, 0 failed (three of them used to be a missing `hides` command: the run said 0 failed and the assertions never ran, found while wiring it) |
| `test-install-guards.sh` | 70 checks, 0 failed |
| `test-deploy-ancestry.sh` | 89 checks, 0 failed |
| `test-node-pins.sh` | 87 checks, 0 failed |
| `test-publish-shared-commit.sh` | 43 checks, 0 failed |
| `test-bootstrap-gate.sh` | 35 checks, 0 failed |
| `test-build-info.sh` | 24 checks, 0 failed (against a debug `wa` rebuilt from this tree; it fails against a binary built before the last commit BY DESIGN - the whole point is that the bytes name the commit they were built from) |
| `test-glibc-floor.sh` | 112 checks, 0 failed (built-artifact sweep skipped: `WA_GLIBC_ARTIFACT_DIR` unset) |
| `test-update-ring.sh` | 26 checks, 0 failed |
| `test-deploy-downgrade.sh` | 0 failed (it delegates to `test-deploy-ancestry.sh`: one rule, one test) |
| `test-fast-rows.sh` | 30 checks, ok |
| `test-orphan-tests.mjs` | 266 wired, 60 orphaned and declared with a reason (all seven wired) |
| `cargo test --manifest-path rust/wa-sentinel/Cargo.toml` | 134 passed, 0 failed (item 8 revert compiles and changes nothing else) |
| `test-remote-update.lua` (the pins Lua row) | 106 checks, ok |
| `test-update-release-updater.lua` | 22 checks, ok |
| `cargo build -p wa-host` | ok, 11 s warm |

### Pre-existing failures (reproduced on the base, worktree `/tmp/r4/base` at `e5ba9089`, no changes of mine)

| suite | on the base | on this branch |
| --- | --- | --- |
| `test-deploy-record.sh` | fails: its own fixture, `run-record.sh: line 44: ROOT: unbound variable` | same failure, unchanged |
| `test-deploy-node-binaries.sh` | fails: `the installed prebuilt supervisor is not executable` | same failure, unchanged |
| `test-deploy-service-target.sh` | fails: 15 of 33 | same failure, unchanged |
| `test-deploy-downgrade.sh` (main's own copy) | fails 11 of 20 in this environment: `deploy.sh` refuses `deploying from a CLI turn needs a sentinel supervisor` (the turn guard), so its assertions never reach the rule | this branch's file delegates to `test-deploy-ancestry.sh`, which strips `WASM_AGENT_IN_TURN` and detaches with `setsid`: 89 / 0 |

### Not verified (stated, not hidden)

- `scripts/test.sh` was not run end to end (the hour-long gate). Its seven new lines are `gate_run` calls, and each was run standalone with the same `WA_BIN` a gate run would hand it.
- The whole fast path was not re-run end to end (it builds a binary and runs ~140 Lua rows). The six new rows were run standalone (timings above), `test-fast-rows.sh` passes, and the orphan ledger is clean. The 28 s row is the one excluded, and that is a decision, not an omission.
- `test-deploy-components.sh` / `test-deploy-components-shipped.sh` were not run (they need wasi-sdk); neither is touched by this round.
- No node was deployed, restarted, upgraded or pinned in this round. Every command ran with a scratch `HOME`/`WASM_AGENT_HOME`/`WASM_AGENT_LUA_ROOT`; the tests that build a pin store build it under `mktemp -d`.
- Nothing was pushed; no remote was written to.

### Texts to approve (verbatim, the strings an operator or a log reader will see)

New, `scripts/deploy.sh`:

```
deploy: refused(ancestry_override_unrecorded): nothing here names the commit that is installed (<why>) and no override was recorded, so no ancestry question can be asked and no record could say why this deploy went on. Nothing was built and nothing was installed. This is a hole in the callers' bookkeeping, not something to work around: make the running bytes name themselves (wa --build-info, or a record whose sha256= is the binary's), or pass --force --reason <text> and the override is recorded in deploy.log and installed.txt.
```

New, `scripts/lib/install-record.sh` (the `WA_RUNNING_WHY` for this case):

```
the install record beside <binary> is about these very bytes (its sha256= is the binary's) but names no commit=, and the binary cannot name its own commit either - so nothing ties these bytes to a place in history
```

Changed, `scripts/upgrade.sh`:

```
refused(override_reason_required): WA_ALLOW_UNVERIFIED_UPGRADE=1 installs a candidate that cannot report its own build, so nothing can show whether it contains the installed commit <commit> - and an override nobody can read later is not a decision anyone can review. Say why: WA_ALLOW_UNVERIFIED_UPGRADE=1 WA_UPGRADE_FORCE_REASON=<text> (the reason is recorded in installed.txt). Nothing was installed, and the running pair is untouched. Install a build made by the current rust/wa-host/build.rs instead (wa --build-info answers on it) and no override is needed.
OVERRIDE, recorded: the candidate <name> cannot report its own build, so nothing can show whether it contains the installed commit <commit>; going on because WA_ALLOW_UNVERIFIED_UPGRADE=1 and WA_UPGRADE_FORCE_REASON say so
force_requested rule=candidate_commit_unknown reason=<text> by=<user> at=<utc>
```

...and its `refused(candidate_commit_unknown)` sentence now ends:

```
... or set WA_ALLOW_UNVERIFIED_UPGRADE=1 together with WA_UPGRADE_FORCE_REASON=<text> for an intentional operator override, and the reason is recorded in installed.txt.
```

New, the legacy-await note - `lua/core/pins.lua` (summary line) and `scripts/lib/node-pins.sh` (the install-side gate):

```
await <12 hex> IGNORED (a legacy record defaulted it to the commit the pin rolled back from, which is not a release)
node-pin: await=<12 hex> is IGNORED on this record: it is the commit the pin rolled back from, which is not a release (a legacy pin; nothing was rewritten)
```

New, the fixture fence in `scripts/test-install-guards.sh` (a test-facing refusal, not a product string):

```
refused(test_needs_scratch_home): HOME is <dir>, which is the real home of this machine. This test reads a node pin store and must never read <home>/.wasm-agent. Nothing was installed.
refused(test_needs_scratch_home): WASM_AGENT_HOME is <dir>, which is the real agent home of this machine. Set it to a scratch directory. Nothing was installed.
```


## Round 5 (round 1b merge, 18/11 22:05): `scripts/fast.sh` is the union of both row blocks

This round was one merge and nothing else: `git merge --no-ff change/mission-fabric` (62d91cf8) into this branch
(cba5415c) in the worktree. Merge commit **c5adc28c**, parents `cba5415c` + `62d91cf8`. Nothing was pushed, no
node was built on, deployed to or restarted, and no other file was changed.

### The conflict, and how it was resolved

The one conflicting file was `scripts/fast.sh`, and the conflict was one insertion point: both sides added rows
directly after `check publish-artifacts bash scripts/test-publish-artifacts.sh`. This branch added the
install/record block (6 `check` rows: `install-record`, `install-guards`, `node-pins`,
`publish-shared-commit`, `bootstrap-gate`, `build-info`); `change/mission-fabric` added one row (`mission`).

Resolved as the union, in that order: the deploy/record block first, then the `mission` row with its three
comment lines, then the `fast-rows` block that already followed both sides. Relative to the first parent the
merge adds exactly 4 lines to `scripts/fast.sh` (the mission comment's three lines and its row); nothing else in
that file moved.

### Verified (commands run, results read back)

- **The union is exact, mechanically.** Row names extracted with
  `git show <ref>:scripts/fast.sh | grep -oP 'check \K[a-z0-9-]+(?= bash )' | sort`: base `e5ba9089` 10 rows,
  this branch `cba5415c` 16 rows (+6), `change/mission-fabric` `62d91cf8` 11 rows (+1), merged `HEAD` **17 rows**.
  `diff union(mine,theirs) HEAD` is **empty** - the merged row set is exactly the union. `comm -23` both sides
  against the merged set prints nothing (no row lost from either side). `uniq -d` over the row names prints
  nothing (no duplicated row). The conflict markers are gone (`grep -n '^<<<<<<<\|^=======\|^>>>>>>>'` empty).
- **`bash -n scripts/fast.sh`: rc=0.**
- **The two suites that touch the merged area**, each in its own scratch `HOME` (`mktemp -d`) with
  `WASM_AGENT_LUA_ROOT=/home/victor/Work/missions/deploy-ancestry/wt`:
  - `scripts/test-mission.sh` (the row the other side added): **273 checks, 0 failed, rc=0**.
  - `scripts/test-deploy-ancestry.sh` (this branch's subject, whose seven files the added rows name):
    **89 checks, 0 failed, rc=0**. Every case green, including the 18/11 shape, the record-vs-bytes cases and
    the pin-before-build case.
- **The merge is clean against everything it must land with**, `git merge-tree --write-tree <ref> HEAD`, exit 0
  and a tree id, no conflict output, for each:

| ref | sha | rc | merged tree |
|---|---|---|---|
| `origin/main` | e5ba9089 | 0 | `83b7306c` |
| `change/land-gate-fix` | d7fa6d4f | 0 | `88069bff` |
| `change/architecture-rules` | 75ca3be8 | 0 | `61544cd8` |
| `change/codeact-fix` | 8384ccf5 | 0 | `a3ebacef` |
| `change/harness-next-a` | 81bef541 | 0 | `484633cd` |

The five checks were also re-run at the branch tip with the report commit on top: all five still exit 0. Their
tree ids differ from the table because that commit changes HEAD and a merged tree id is a function of all three
inputs; the ids above are the merge commit's own (c5adc28c), which is what a round-1b merge takes. A branch tip
cannot record its own tree ids without changing them, so that re-run is stated here rather than numbered.

### Not verified (stated, not hidden)

- The `origin/main` sha above is the **local** `origin/main` ref (`e5ba9089`), read without a `git fetch` in
  this round: if the remote tip moved after the last fetch, the main check is against the ref this branch was
  rebased on, not against the live tip.
- `scripts/fast.sh` was not run as a whole (it builds a binary and runs ~140 rows, and the full fast path is not
  what this round changed). What was proved is that the file parses, that the row set is the exact union, and
  that the two suites naming the merged rows pass standalone with the same `WA_BIN` a fast run would hand them.
- No other suite was run (`scripts/test.sh`, the hour-long gate, included).
- Nothing was pushed; no remote was written to.
