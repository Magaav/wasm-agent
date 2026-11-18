# change/land-1b-fix - the merged round-1b tree, green again

Branch `change/land-1b-fix`, worktree `/home/victor/Work/missions/land-1b-fix/wt`, based on `land58/final`
**8cd6507c** (`origin/main` e5ba9089 plus the merges of land-gate-fix, mission-fabric, architecture-rules,
codeact-fix, deploy-ancestry and harness-next-a). Committed locally on this branch; nothing was pushed,
nothing was deployed, no node was restarted. Built and tested HERE on avell
(`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-land-1b-fix`).

This is the mission report and it lives here, per the brief. **There is no root REPORT.md**: the root
REPORT.md on this branch belongs to another mission and was not touched.

## The verdict

BEFORE - the land gate of 18/11 22:18 (`~/.wasm-agent/land/land-20261118T221849Z-82cb301b/evidence/gate.log`):
**294 checks, 8 failed**.

AFTER - this tree, committed (the run below is on c7ee2ac7, and the only difference between it and this
commit is this report file, docs-only), a scratch HOME, `WASM_AGENT_LUA_ROOT` = this worktree, and
`WASI_SDK=/home/victor/wasi-sdk-34` so that the seven component rows RUN from this tree instead of skipping
(with a scratch HOME the automatic probe under `$HOME/wasi-sdk*` finds nothing, and the gate that failed had
them built). Its last lines:

```
fast: binary /home/victor/wasm-agent/target/m-land-1b-fix/release/wa (build c7ee2ac78ab9, tree c7ee2ac78ab9, fresh: built from this tree) sha256=eae6e38647d3
fast: env contract: every row gets its own scratch WASM_AGENT_HOME, WA_COMPONENTS_DIR inside it, WASM_AGENT_LUA_ROOT=/home/victor/Work/missions/land-1b-fix/wt, no rendezvous or relay, WASM_AGENT_MANAGED=0
fast: components graph hooks memory selfloop mesh codemode svc-echo built from this tree and pinned in /home/victor/wasm-agent/checkout/.git/worktrees/wt20/wa-fast-components/set
fast: lua 244/244 passed (56 excluded: scripts/fast-path.exclude)
fast result ok (294 checks, 0 failed, 0 skipped): /home/victor/wasm-agent/checkout/.git/worktrees/wt20/wa-fast-result.json
fast path ok (294 checks, 0 skipped, 218s)
```

294 of 294, **0 failed, 0 skipped**, in 218 s - run twice on this code (260 s before the report was committed,
218 s on the commit above). The gate's run also recorded 0 skipped; an earlier run of mine that skipped the
component rows reported 43 named skips inside passing rows, and neither run quoted here has one.

## What each failure was, and where the fix went

| # | row | what actually happened | fix |
|---|---|---|---|
| 1 | `lua scripts/test-land.lua` | deploy-ancestry's record and pin rules vs the fixtures | fixture |
| 2 | `lua scripts/test-release-sign.lua` | deploy-ancestry's shared-commit rule vs a fixture that publishes the checkout's HEAD | fixture |
| 3 | `lua scripts/test-refusal-contract.lua` | the generated map was stale (11 codes from the merged branches) | the generated file, regenerated |
| 4 | `lua scripts/test-cli-wake-row.lua` | codeact-fix changed the status-bar glyphs and left the snapshot | the snapshot |
| 5 | `install-front-door` | a REAL bug in `scripts/install.sh`, plus two fixture gaps | code + fixture |
| 6 | `publish-artifacts` | the shared-commit rule vs a fixture that publishes HEAD | fixture |
| 7 | `install-guards` | the row's own scratch-home guard misread its own fixture | fixture |
| 8 | `land-signing` | a new lib dependency, and the fake remote the 18/11 rule stopped trusting | fixture |

Seven of the eight are interactions between branches: each fixture was written against the other branch's
OLDER behaviour and its branch was green alone because alone it never ran the other's new rule. One (#5) is a
real production bug that the merge created and nothing else could have caught. One (#4) is not main's failure
and not an interaction either - see its section. **No two branches' rules contradict each other**, so nothing
was escalated: every new rule is kept, and where a fixture tripped over one, the fixture now follows the path
that rule names.

### 1. `scripts/test-land.lua` - the rollback writes the record from the binary, and a rollback pins the node

Two separate interactions with change/deploy-ancestry, both after case 7:

* **case 8, the rollback script.** The fixture's kept pair were stubs that answered only `--version`.
  `scripts/rollback-node.sh` now writes `installed.txt` from the RESTORED BINARY'S OWN `--build-info`
  (`wa_record_install`, scripts/lib/install-record.sh), so the record said `commit=unknown` and the assertion
  "the record names the commit that was restored" failed. The fixture now writes a pair that ANSWERS
  `--build-info` with the commit it holds (`stub_binary`, one helper, four calls). The assertion is unchanged
  and is now stronger in what it means: the commit is the binary's answer, not a carried-over claim - the exact
  18/11 failure this rule exists against.
* **case 9 onwards, the pin.** `wa land --rollback` now PINS every node it rolls back
  (lua/core/remote_update.lua, kind=rollback), and an ordinary deploy of a pinned node is refused by name
  (`node_pinned`), released by `wa update <node> --unpin --reason <text>`. Case 7 rolls the whole ring back,
  so case 9 - a normal landing - was refused. The fixture now does what an operator does between the two: it
  asserts the pin exists for each of the ring's four nodes and releases it with a reason (three checks per
  node, twelve new checks, none removed).

Verified: `land ok (325 checks)`.

### 2 and 6 and 8. `test-release-sign`, `publish-artifacts`, `land-signing` - a fixture is not a published release

All three run the REAL publisher (`scripts/publish-node-binaries.sh`, through the transport
`scripts/publish-artifacts-branch.sh`), and change/deploy-ancestry made it ask the REMOTE whether the commit it
is being asked to publish is on a branch anybody else can see (`scripts/lib/shared-commit.sh`, the 18/11 rule).
Two of the three fixtures publish the CHECKOUT'S OWN HEAD, and in a landing gate that commit is by definition
not pushed yet - the gate runs BEFORE the push:

* `scripts/test-release-signing.sh`: refuses `commit_not_on_pushed_branch` (its "ship unsigned" case never
  reached the publisher's signing step). Fixed with the exception the refusal itself names for a set that is
  installed nowhere: `ALLOW_UNPUSHED_COMMIT=1` **with** `ALLOW_UNPUSHED_REASON`, which the manifest records as
  `unpushed=yes` beside it. Nothing else in the row changed.
* `scripts/test-publish-artifacts.sh`: the same, for the same reason (it too publishes `git rev-parse HEAD`).
* `scripts/test-land-signing.sh`: two real gaps, both in the fixture.
  (a) it copies the publisher's libraries into a fixture tree BY NAME, and the publisher had grown a new one: it
  refused `shared_commit_lib_missing` before doing anything, which read as "the artifacts step" failing.
  (b) its only "remote" was `refs/remotes/origin/main` made with `git update-ref` - exactly the memory of a
  fetch that the new rule stopped trusting. It now has a real bare origin in `$WORK` with `main` pushed to it,
  so the remote question is answered by a remote, hermetically and offline.

Where a fixture uses the override, the refusal it bypasses is proved against a real remote by
`scripts/test-publish-shared-commit.sh` and `scripts/test-deploy-ancestry.sh`, both green here.

Verified: `release signing ok (5 checks)` (the Lua row), `publish artifacts: ok (55 checks)`, `land signing ok (46
checks)`.

### 3. `scripts/test-refusal-contract.lua` - the generated map

`lua/core/refusal_codes.lua` was stale: the merged branches added eleven codes reachable from the tool surface
(`node_not_pinned`, `node_pin_not_released`, `node_pinned`, `override_reason_required`, `pin_node_required`,
`pin_not_clearable`, `pin_not_written`, `pin_reason_required`, `pin_release_not_recorded`,
`release_state_unknown`, `unpin_reason_required`). Regenerated with the generator, never by hand:
`lua5.4 scripts/gen-refusal-codes.lua --write` -> "543 codes from 93 reachable modules"; `--check` is clean.

### 4. `scripts/test-cli-wake-row.lua` - a snapshot older than the glyphs

The stored `tests/snapshots/balloon/wakes-80x24.txt` said `↻0 ⚒️0 ↑0 ↓0` while the row draws the Material
glyphs codeact-fix round 4 chose for Victor's font (`󰑐0 Σ↑0 ↓0`). That branch's report recorded the failure
and left the snapshot alone on purpose.

**Was it main's?** No, and here is the check: a worktree at **e5ba9089** with its OWN files
(`WASM_AGENT_LUA_ROOT` = that worktree, the same binary) passes the row, 30 of 30 - the base draws the old
glyphs and stores the old glyphs. It was made red by the glyph change, not inherited. The snapshot is
regenerated from what the row draws now; the assertion (the stored file equals the drawn rows, byte for byte)
is untouched.

Verified: `cli wake row ok (30 checks)`.

### 5. `install-front-door` - a real bug in the front door, and two fixture gaps behind it

18 of 56 failed, and behind the first failure there were two more:

* **THE BUG (code).** `scripts/install.sh` downloads the libs the Linux core sources beside itself, and the
  list still named `release-signing.sh` and `release_verify.py`. change/deploy-ancestry made
  `scripts/linux/bootstrap.sh` ALSO source `install-record.sh` (the record written from the binary, and the
  ancestry verdict) and `node-pins.sh` (this node's own pin, which a rollback writes). A real install from a
  release would have died at `bootstrap: install_record_lib_missing` on every Linux machine - the fixture was
  the only thing that noticed. The list now names all four, and the refusal is `core_lib_unreachable` naming
  the file that could not be fetched and why the core needs it.
* **The fixture (a superset would have hidden it).** `scripts/test-install.sh`'s `mkbase` copied its own
  hardcoded pair into the fake base, so it would have passed with a front door that fetched the wrong files.
  It now reads the list OUT OF `scripts/install.sh` itself, so a third copy cannot drift and the row tests the
  base a real install is actually served.
* **The fixture (a payload that cannot name itself).** The bundle's binary was `/bin/true`. bootstrap.sh now
  refuses a release whose binary cannot report its own commit (`candidate_names_no_commit`), and checks the
  ELF machine byte and `wa --contains` before that. The fixture compiles a stub (cc) that answers `--version`,
  `--build-info` and `--contains` - the same shape, and the same price, as `scripts/test-bootstrap-gate.sh`.
  A host with no C compiler reports the real chain as SKIP by name, never as passed.

Verified: `install front door ok (56 checks)`.

### 7. `install-guards` - the guard refused the fixture it had just made

The row creates its own scratch HOME and refuses to run on the operator's. The rule was "refuse any path
under the real `~/.wasm-agent`", and on a landing gate `TMPDIR` IS the node's `~/.wasm-agent/tmp`, so the
scratch home it had just made (`mktemp -d` + `/scratch-home`) matched the refusal:

```
refused(test_needs_scratch_home): HOME is /home/victor/.wasm-agent/tmp/tmp.XXXX/scratch-home, which is the real home
```

Reproduced with the pre-fix file in the same environment (exit 2, forty lines of assertions never ran). The rule
is now the right one - **a scratch home is one this test made** (inside its own `mktemp -d`) - while the
operator's `$HOME` and the real `~/.wasm-agent` itself still refuse, and that is now CHECKED by the row instead
of assumed: two probes run the guard in a subshell against the real home and against `~/.wasm-agent` and fail
the row if either is accepted. The carve-out cannot widen silently.

Verified: `test-install-guards: 72 checks, 0 failed` (70 before; the two new probes are the additions), in the
gate's own environment (`HOME=/home/victor`, `TMPDIR=~/.wasm-agent/tmp`).

## How each fix was verified

Each row was run FIRST on its own, from this tree, with the binary this tree built
(`WA_SCRIPT=<row>` through the fast path's own row environment, scratch `WASM_AGENT_HOME`), before the whole
path was run:

| row | before | after |
|---|---|---|
| `test-land.lua` | check failed (the restored commit) | `land ok (325 checks)` |
| `test-release-sign.lua` | `release signing: 2 of 5 checks failed` | `release signing ok (5 checks)` |
| `test-refusal-contract.lua` | stale map | `--check` clean |
| `test-cli-wake-row.lua` | 1 of 30 failed | `cli wake row ok (30 checks)` |
| `test-install.sh` | 18 of 56 failed | `install front door ok (56 checks)` |
| `test-publish-artifacts.sh` | expected 0, got 8 | `publish artifacts: ok (55 checks)` |
| `test-install-guards.sh` | exit 2 on line 1 | `72 checks, 0 failed` |
| `test-land-signing.sh` | expected 0, got 2 | `land signing ok (46 checks)` |

then `bash scripts/fast.sh` on the whole tree: **294 checks, 0 failed, 0 skipped** (quoted above).

## Not verified, and not done

* Nothing was pushed, deployed or installed; no node was touched; the canonical checkout was not modified.
* `scripts/test.sh` (the nightly full gate) was NOT run - the fast path is the landing requirement.
* The land gate itself was not re-run (that is the orchestrator's step); the evidence quoted is the fast path
  on this tree.
* FLAKE, named: in my first full run of the fast path `session-liveness` failed once ("the refusal reports the
  presence age: owner_stale ... 4001s"); it passes alone (14 checks) and did not recur in the run quoted above.
  It is a `node scripts/test-session-liveness.mjs` row I did not change, and the gate of 18/11 did not have it.
* A host with no C compiler reports the real install chain in `scripts/test-install.sh` as SKIP by name
  (`cc` builds the fixture payload, which must be an ELF of this machine that names its own build). That is a
  named hole, counted as a skip, never as a pass.
* The component seam rows need `WASI_SDK` when `HOME` is a scratch directory: `scripts/fast.sh` probes
  `$HOME/wasi-sdk*` (and `WASI_SDK_PATH`), so a scratch HOME without that variable skips the seven component
  rows. Both full runs of mine that skipped them, and the one quoted above that did not, are on the same code.
