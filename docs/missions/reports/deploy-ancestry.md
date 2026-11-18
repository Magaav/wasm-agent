# change/deploy-ancestry — a deploy never silently goes backwards

Branch `change/deploy-ancestry`, base `origin/main` 74d48431. Committed locally on this branch; nothing was
pushed. Built and tested on avell (`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-deploy-ancestry`).

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
unanswerable remote refusing.

**8. A dirty running binary refuses.** `deploy.sh` and the other three paths refuse
`downgrade refused(dirty_running_binary)` when the running binary reports `dirty=true`, and
`refused(ancestry_unknown)` when it reports `dirty=unknown` (a partial answer is not a clean one).
Test: `test-deploy-ancestry.sh` (refused by name, record untouched, `--force --reason` goes on and records
`running_dirty=true`), `test-install-guards.sh` (the fleet path).

**9. No command inside a message.** `bootstrap.sh`'s refusal quoted the sentinel's command between double quotes;
it is single-quoted now, and `test-install-guards.sh` checks every installer for the shape
(`grep -E '(fail|say|die|note|printf|echo) "[^"]*``'`), with the shipped line as its fixture.

## Verified (commands run, results read back)

| test | result |
|---|---|
| `scripts/test-install-record.sh` | 56 checks, 0 failed |
| `scripts/test-deploy-ancestry.sh` | 51 checks, 0 failed |
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
- `deploy.sh`'s new `commit_not_on_pushed_branch` precondition was exercised on unlanded trees (it refuses) and by
  the deploy test's fixtures (whose `origin` is this worktree, so their commit IS shared there); it was not run
  against a real push in this round.
- `source_shared=` is only ever `unknown` in the binaries built here (nothing stamps it except
  `lib/fast-binary.sh`), so no install path refuses on it yet; no rule reads it.
- The exit-path of the release (`kind=released`) was verified by the store's own test, not by a live deploy that
  released a pin.

## Not done / left as it was

- Nothing was pushed; no deploy, rollout or restart was performed on any node.
- The three pins seeded in round 1 in this node's store are untouched.
- `wa update <node>` against a live peer was not run: the transport needs a real peer and this round changed what
  happens BEFORE it (the gate).
