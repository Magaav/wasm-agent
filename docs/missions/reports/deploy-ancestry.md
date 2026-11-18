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

That table is the whole argument for rule 1: a record written by the installing party was wrong on two of three
nodes, and the previous guard compared the tree against that record.

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
| `scripts/test-install-record.sh` | 31 | 0 failed — writer, caller `commit=` dropped, dead/hanging binary, ancestry verdicts, a real `rollback-node.sh` restore |
| `scripts/test-deploy-ancestry.sh` | 19 | 0 failed — refusal with the lost commit's subject, `--force` without reason refused, `--force --reason` recorded in deploy.log, record-as-fallback |
| `scripts/test-publish-shared-commit.sh` | 15 | 0 failed — unpushed commit, pushed branch, detached HEAD both ways, named override, manifest fields |
| `scripts/test-node-pins.sh` | 38 | 0 failed — store, supersede/history, overdue, clear-as-record, CLI `--pin`/`--unpin`, gate refusal, fleet view |
| `scripts/test-fleetops.lua` (existing) | 147 | 0 failed |
| `node scripts/check-deploy-docs.mjs` | 6 | ok |
| `cargo test -p wa-host build_info` | 4 | ok |

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
