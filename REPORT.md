# REPORT — deploy-ancestry round 2

Branch `change/deploy-ancestry` (worktree `/home/victor/Work/missions/deploy-ancestry/wt`), base `origin/main`
74d48431. **Nothing was pushed. Nothing was deployed.**

The full report is `docs/missions/reports/deploy-ancestry.md` (round 1, then round 2 appended). This file is the
short form.

## The principle, and where it now holds

UNKNOWN REFUSES (fail closed) unless `--force --reason`, on every path, with the override recorded.

| # | review item | fix | test |
|---|---|---|---|
| 1 | the guard fails open on 18/11 | `wa_ancestry_verdict`: complete history + missing running commit = **1** (refuse); shallow + missing = 2 and says how to fetch it; the RUNNING binary is asked (`--contains <target>`) first; `deploy.sh` tries one bounded `--unshallow`; a verdict of 2 now REFUSES | `test-deploy-ancestry.sh` (the exact 18/11 case, the shallow case), `test-install-record.sh` |
| 2 | an old binary was free passage | `wa_running_identity` (one answer to "what is running") in deploy/upgrade/fleet-install/bootstrap, with `wa_record_describes`; `fleet-install.sh`'s `FORCE=0` reset bug fixed | `test-install-guards.sh` (fleet path end to end) |
| 3 | a shallow build claimed complete ancestry | `build.rs`: `ANCESTORS_COMPLETE=false` when the build checkout is shallow; "not contained" from an incomplete list is unknown (2) | `test-build-info.sh`, the Rust unit test |
| 4 | `--force` without `--reason` | refused at the parser in `deploy.sh`; refused by the pin gate in `remote_update.lua`/`update.lua`; every force recorded (who, when, why, what it overrode) | `test-deploy-ancestry.sh`, `test-node-pins.sh`, `test-remote-update.lua` |
| 5 | pins blocked their own fix | release when the target CONTAINS the awaited commit (with a tree, not `''`); release written as a record; a rollback records `rolled_back_from` and defaults `await` to it; `--unpin` named in the answer | `test-node-pins.sh`, `test-remote-update.lua` |
| 6 | the pin lived only in the coordinator | the node writes its own pin on a rollback (`node_id` too); `scripts/lib/node-pins.sh` read by upgrade/fleet-install/bootstrap; `pins.active(name, node_id)` resolves aliases | `test-remote-update.lua`, `test-node-pins.sh`, `test-install-guards.sh` |
| 7 | a stale local `refs/remotes/*` counted as published | `scripts/lib/shared-commit.sh` asks the REMOTE (`git ls-remote`); used by publish-node-binaries, publish-components, deploy.sh, ship-wave.mjs, codemode-build.mjs, fast-binary.sh | `test-publish-shared-commit.sh` (real bare remote; the stale-ref case) |
| 8 | a `dirty=true` running binary was replaceable | `downgrade refused(dirty_running_binary)`, and `dirty=unknown` refuses as `ancestry_unknown` | `test-deploy-ancestry.sh`, `test-install-guards.sh` |
| 9 | backticks inside a double-quoted message | single-quoted; a check for the shape in every installer | `test-install-guards.sh` |

## Verified at the final commit

`test-install-record` 56/0, `test-deploy-ancestry` 51/0, `test-install-guards` 44/0, `test-node-pins` 56/0,
`test-publish-shared-commit` 33/0, `test-build-info` 24/0, `test-ship-wave` 14/0, `test-wave-ship` 21/0,
`check-deploy-shipped` 179 ok, `check-deploy-docs` 6 ok, `cargo test -p wa-host build_info` 4 passed,
`test-remote-update.lua` 75 ok, `test-fleetops.lua` 147/0, `test-update-all/-banner/-release/-watcher` 43/227/16/45 ok.

Numbers are "checks / failed"; a Lua row's number is its own check count.

## Pre-existing, reproduced on the base (74d48431, clean worktree)

`scripts/test-deploy-record.sh` (fails with `ROOT: unbound variable` in its extracted fixture) and
`scripts/test-deploy-preconditions.sh` (turn-guard refuses before its WSL case). Both fail identically on the base.

## Not verified

`upgrade.sh` and `linux/bootstrap.sh` were not run end to end (each installs a node); the test asserts they route
through the same functions and refusals. A deep (non-shallow) build reporting `ancestors_complete=true` was not
observed here, because this worktree is itself a shallow clone. `source_shared=` is recorded but no rule reads it
yet. Nothing was pushed, deployed or restarted.
