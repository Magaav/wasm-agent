# node-ops — node safety and build/test plumbing (19/11)

Branch `change/node-ops`, base `44229140`. Seven items, one commit each, **never pushed**.
Built and tested on avell only (16 cores, `CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-node-ops`).

Every new test was run against the branch (passes) and against a detached worktree of `44229140`
(`/tmp/wt-base7`, fails) — no `git stash` was used anywhere in this round.

| item | commit | test | wired into |
|---|---|---|---|
| 6 (#49) per-row watchdog | `5ff03298` | `scripts/test-fast-watchdog.sh` | `fast.sh` check row, `test.sh` |
| 1 (#23) backup/restore | `c804e0ff` | `scripts/test-backup-restore.{sh,lua}` | `fast.sh` check row, `test.sh` |
| 7 (#50) peer capabilities | `829d4e84` | `scripts/test-nodes-capabilities.{sh,lua}` | `fast.sh` check row, `test.sh` |
| 2 (#20/#35) rollback verification | `2dac88ab` | `scripts/test-rollback-verify.sh` | `fast.sh` check row, `test.sh` |
| 3 (#17) build-environment record | `289acef6` | `scripts/test-build-env.sh` | `fast.sh` check row, `test.sh` |
| 4 (#45) build vs HEAD + allow-list env | `2f86ffa6` | `scripts/test-build-status.{sh,lua}` | `fast.sh` check row, `test.sh` |
| 5 (#46) row at base and at change | `c3db726f`, `e7392f2c` | `scripts/test-row-at-sha.sh` | `fast.sh` check row, `test.sh` |

All seven pass together:

```
test-fast-watchdog.sh            PASS
test-backup-restore.sh           PASS
test-nodes-capabilities.sh       PASS
test-rollback-verify.sh          PASS
test-build-env.sh                PASS
test-build-status.sh             PASS
test-row-at-sha.sh               PASS
```

## Item 6 (#49) — a hung row is named and killed with its children

**Measured before:** `scripts/fast.sh` ran each Lua row under a bare `timeout 120`. `timeout` signals only
the process it was given, so a fixture's `sleep 600` child survived the row and held files, pipes and locks
for the rest of the run.

**Fix:** `scripts/lib/fast-watchdog.sh` puts the row in its OWN PROCESS GROUP with `set -m` (pure bash, no
`setsid`), and on the deadline sends TERM then KILL to the whole group, printing one line that names the
row, the seconds and the group. `fast.sh` uses it in place of `timeout`, classifies a row as `hung` only
when that line is present, and counts hung rows apart from both passes and environment failures.

**Before (base):** `test-fast-watchdog: scripts/fast.sh still runs a Lua row under a bare timeout, so a hung row leaves its children behind`

**After (branch):** `test-fast-watchdog: ok (hung row named and its group killed, exits passed through, refusals named)`

The child leak is asserted for real: the test forks `sleep 600` inside the row, and after the watchdog
returns it requires `kill -0 <child>` to fail.

## Item 1 (#23) — a retained snapshot restorable by one command

**Measured before:** `lua/core/backup.lua` snapshotted every store with `VACUUM INTO` and checked each
copy, but wrote no manifest (a directory of files named `3-memory.db` with nothing saying which store each
belonged to) and nothing put a snapshot back. `wa restore` did not exist.

**Fix:**
- `backup.run` now writes `manifest.json` per snapshot: each store's source path, its copy, and the
  sha256 of the copy.
- `backup.restore(dir)` re-checks the manifest, every copy's hash and `integrity_check`, and that every
  destination is inside this node's own data/config (or the live ledger) BEFORE writing anything; then it
  stages, keeps the replaced file as `.pre-restore-<stamp>`, and renames into place.
- `wa backup` / `wa backup list` / `wa restore --from DIR` (`lua/core/backup_cli.lua`, dispatched in
  `lua/core/init.lua`).
- `backup.tick` takes at most one `periodic` snapshot per `WA_BACKUP_INTERVAL_S` (default 24 h), keeps the
  newest `WA_BACKUP_KEEP` (default 7) of them and removes older ones — never a pre-update snapshot, whose
  retention stays with the reclaim pass as `M.prune` already states.
- Wired into the node's existing housekeeping tick (`lua/core/server.lua`, guarded by `WA_SCRIPT`).

**Before (base):** `lua error: [string "bootstrap"]:1: lua_root_unreadable: /tmp/wt-base7/lua/core/backup_cli.lua` — the verb does not exist.

**After (branch):** `backup restore ok: manifest 3 store(s), restore put them back, 5 refusals named, nothing written by any of them`

Five refusals are asserted, each writing nothing: no manifest, a copy whose bytes changed, a manifest naming
a path outside the node, and the CLI's own `restore_from_required`.

**Honest limit, reported not hidden:** a store this process has open cannot be made to read the bytes just
restored — SQLite keeps its own pages. The restore therefore reports `reopen_required` (and the CLI prints
that the node must be restarted), and the test asserts the restored ledger FILE holds the snapshot's rows.
It does not claim the live connection changed.

## Item 2 (#20/#35) — a rollback is done when the node runs the restored binary

**Measured before:** `scripts/rollback-node.sh` printed `rollback ok` after asking systemd to start,
whatever the start did (19/11: the service was dead and the operator read a success line), and it restored
the binary pair only — `lua-core` stayed at the new tree, which is the "installed tree ignored" report.

**Fix:**
- `scripts/lib/rollback-verify.sh` (`wa_running_binary_verdict`): compares `/proc/<pid>/exe` with the
  restored file by **device and inode**, treats a `(deleted)` link as a mismatch, and answers `unknown`
  (never ok) when there is no pid, no `/proc` or an unreadable link.
- `rollback-node.sh` restores `lua-core` from `$FROM/lua-core` or `$INSTALL/lua-core.prev` in the same act,
  names which tree it installed, and NAMES the case where no previous tree was kept.
- Its restart step now refuses its success claim: `rollback_not_effective` (5) on a mismatch,
  `rollback_unverified` (5) on `unknown`.

**Before (base):** `test-rollback-verify: scripts/rollback-node.sh no longer contains rollback_not_effective:`

**After (branch):** `test-rollback-verify: ok (a live pid is identified by inode, mismatch and unknown are never ok, the Lua tree moves with the binary)`

The inode comparison is proven against a **real process**: the test copies `sleep`, starts it, and requires
`ok` for that file, `mismatch` for a byte-identical copy (different inode), and `mismatch` after the
running file is replaced on disk. A fixture install with `lua-core.prev` must get that tree back; one
without must say so by name.

## Item 3 (#17) — the node owns one build-environment record

**Measured:** `scripts/lib/build-requirements.sh` already read `build.env`, but only `deploy.sh` and
`install.sh` sourced it; `fast.sh` never did, so a fast run graded the ambient environment. The allow-list
covered four keys and named no zig, wasi-sdk or target-dir policy, and an unread key was silently ignored.

**Fix:**
- `WA_BUILD_ENV_KEYS` — the allow-list as data: `WA_BUILD_PATH`, `WA_BUILD_PROVISION`, `WA_BUILD_ZIG`,
  `WASI_SDK_PATH`, `WA_BUILD_CARGO_TARGET`, the `CARGO_*` knobs, `WA_UPGRADE_IDLE_POLL`.
- `wa_build_env_audit` — one line per entry; an unknown key is a refusal (`build_env_key_unknown:<KEY>`)
  printed as a `problem` line so a caller reading through a command substitution still gets the code.
- `wa_build_env_help` — each key's meaning and the ONE line that fixes it.
- `scripts/fast.sh` reads the record through this lib, refuses before running a single row (and before
  `--binary` can return early), and prints what the record set.
- `wa build-env` verb; `build-requirements.sh record|help` subcommands.

**Before (base):** `test-build-env: scripts/fast.sh with an unknown record key exited 0, not 2`

**After (branch):** `test-build-env: ok (absent is not a refusal, an unread key is named with its remedy and stops fast.sh, allowed keys reach PATH, the record is data and never sourced)`

The record is DATA, never sourced, and the test proves it: a line containing `$(touch …)` must not run.

## Item 4 (#45) — a build is graded against the bytes it embeds; rows inherit only by allow-list

**Measured before:** no tool a model could call reported whether the running binary was this tree's build,
and `fast.sh` cleared `WASM_AGENT_*` by an explicit block-list that had grown one leak at a time.

**Fix:**
- `lua/core/build_status.lua` + a `build` tool: the binary (path, sha256, build commit), the tree (HEAD,
  branch, whether `lua/` and `rust/` are unmodified), and the relation — `fresh`, `stale`, `edited` or
  `unknown`. `M.relation` is a pure function so all four are testable as data.
- `fast.sh` computes the cleared set: every `WASM_AGENT_*` and `WA_MESH*` in the process goes except the
  five the runner sets for the row — an allow-list, checked by exact match.

**Before (base):** `lua error: [string "bootstrap"]:1: lua_root_unreadable: /tmp/wt-base7/lua/core/build_status.lua`

**After (branch):** `build status ok: relation stale with its reason, the tool agrees, and the runner clears WASM_AGENT_* by allow-list`

All four relations are asserted as data, including that `unknown` is never `ok`.

## Item 5 (#46) — one row at a base and at the change, as one comparison

**Measured before:** no `wa test` verb existed; establishing "fails before, passes after" meant editing the
tree, running, un-editing and running again — the shape that also produced the 19/11 cross-worktree stash.

**Fix:** `scripts/lib/row-at-sha.sh`. `wa_row_at_sha <sha> <row>` checks out the base commit in a detached
worktree **beside** the repo, runs the row there and here (each with its own scratch home,
`WASM_AGENT_LUA_ROOT` pointing at the tree under test), and classifies: `still_passing`, `pre_existing`,
`new_failure`, `fixed`, or `skipped` (77 is a skip and is never a pass). Exit 0 = a verdict was produced,
1 = the change broke the row, 2 = refused. Cleanup runs on every exit path.

**Before (base):** `scripts/test-row-at-sha.sh: line 29: wa_row_at_sha_classify: command not found`

**After (branch):** `test-row-at-sha: ok (four classes and the skip convention, a real comparison with no worktree left behind, every refusal named)`

The real comparison is run against this repo, and the test asserts the worktree count is unchanged and the
row is untouched inside the tree under test.

**Honest limit, stated in the tool:** the binary that runs both rows is this node's `wa`, not a build of the
base commit. Lua is exercised from the commit under test; a row that needs the BINARY built at the base is
not covered, and the answer names the binary it used.

## Item 7 (#50) — a peer answers its accepted capabilities

**Measured before:** the rendezvous `nodes` table has no capabilities column, and `nodeslib.list` passed
its rows through unchanged — so `tools.nodes()` reported `capabilities = []` for every peer, including one
that accepts `bash`.

**Fix:**
- A `capabilities` capability in `lua/core/server.lua` (`wa_node_capabilities`), derived from the node's
  OWN gate for the asking role: the tool catalogue plus, for a master only, the peer surface. A guest is
  NOT told `bash` is accepted, because `author_of` refuses every peer call from a guest — over-promising
  would be the same defect in the other direction.
- `nodeslib.peer_capabilities` asks a peer live (cached 120 s on success, 60 s on failure), and
  `nodeslib.list` sets `capabilities` plus `capabilities_reason`, so an empty answer always carries the
  reason it is empty. A cached view (`opts.cached`) asks nobody and says `not_asked_cached_view`.

**Before (base):** `lua error: [string "scripts/test-nodes-capabilities.lua"]:46: the peer surface has no capabilities verb, so no peer can answer this question`

**After (branch):** `nodes capabilities ok: the peer surface admits bash and answers it, an unreachable peer gives a named reason, the cache is used, a cached view asks nobody`

A master's answer contains `bash` and `capabilities`; a guest's does not contain `bash`; an unreachable
peer answers no capabilities AND a non-empty reason.

## Things that were wrong in the brief, or not done

- **The brief's item numbers do not appear in this repo.** `#17/#20/#23/#35/#45/#46/#49/#50` match no
  entry in `docs/missions/QUEUE.md` or `docs/EXECUTION-FOUNDATION-PLAN.md`; each item was implemented from
  the text quoted in the brief. If those numbers are a tracker elsewhere, they are not linked from here.
- **`wa test --at <sha>` (item 5) is not a `wa` verb.** It is `scripts/lib/row-at-sha.sh`, which is what
  runs and is wired into both harnesses. A `wa` subcommand would need the base worktree management inside
  the node process; that is a design change I did not make without asking.
- **The periodic backup is a housekeeping-tick call**, verified at the `backup.tick` level (interval skip,
  retention, no re-snapshot inside the window). I did not observe a live node taking one on its 24 h
  boundary — that needs a day.
- **`origin/main` moved during this round** (from `44229140` to `e4e40405`). `git diff --stat 44229140..HEAD`
  shows only additions; the files that appear "deleted" against `origin/main` (e.g.
  `scripts/test-thinking-block.lua`) were added upstream after this base and are not deletions I made.

## Texts to approve

New or changed model-/operator-facing strings, verbatim:

1. `fast: refused(build_env_key_unknown:<KEY>): the build record names a setting no build reads, so a machine could spend a day believing it set a toolchain directory nothing looked at. Remove that line, or add it to WA_BUILD_ENV_KEYS with the face that consumes it. Nothing was run.`
2. `fast: <N> row(s) HUNG and were killed with their whole process group: the line names the row, the seconds and the group (see scripts/lib/fast-watchdog.sh)`
3. `FAIL lua <row> (hung): <watchdog line>`
4. `wa restore: refused(restore_from_required): name the snapshot -- wa restore --from <dir> (wa backup list prints them). Nothing was changed.`
5. `restore: the ledger this command opened (<paths>) was restored on disk and an OPEN process keeps its old view: restart the node before it reads these bytes`
6. `rollback_not_effective: the pair was restored and the node was started, but the running process is NOT the restored binary (<detail>). This is not a rollback: the node is still executing the bytes this script meant to replace. Stop it and install a matching pair, or start the restored binary by hand: <install>/wa`
7. `rollback_unverified: the pair was restored and a start was asked for, but this script cannot prove which binary is running (<detail>). Unknown is not yes: check it yourself with 'systemctl --user show wa-sentinel.service -p MainPID --value' and read /proc/<pid>/exe before believing this node is rolled back.`
8. `warning: no previous Lua tree was kept (<paths> are both absent), so the tree beside this binary is whatever the last install put there - a binary older than its tree is not a rollback, and a fresh install is the only way to make the pair match`
9. The `build` tool description (schema text, quoted in `lua/core/tools.lua`).
10. `refused(<code>): <what>. Fix: <the one line>` (the `wa_build_env_refuse` shape).
11. The `capabilities` peer answer's `note`: `Accepted, not guaranteed: each call is admitted again when it arrives, against the binding, the roster and the policy in force then.`
12. `row_at_sha: <class>: base exit <n>, change exit <n> - <meaning>`
