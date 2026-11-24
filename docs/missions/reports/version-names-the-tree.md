# version-names-the-tree - `wa --version` and /health name the commit the node actually runs

Branch `change/version-names-the-tree`, rebased onto `origin/main` = 42507780 (started from fe108a8c, the landing
of slice 1 + A-D; the branch moved twice while this round ran). Commits after the rebase: `a7f2dd15` (the
fix, the row, the docs) and `5885ba82` (this report).

## What was measured, on this node, before any change

After the scripts-only landing of fe108a8c, `~/.local/bin/installed.txt` read:

    commit=fe108a8c
    lua_tree=fe108a8c
    lua_fast_path=1
    build_info=yes
    sha256=2c5e5c4b2a5e7fff68cde1268c07fe9d50e1990b9c83503696ad2e111d70049f

and the binary beside it answered:

    $ wa --build-info | head -2
    version=0.1.2
    commit=9a0c589adfa08b7e99cc4b8bd3bd5558de4030c0
    $ wa --version
    wasm-agent v0.1.2 · v9a0c589a

So the record names the Lua tree the install runs (`scripts/deploy.sh`'s fast path writes `commit=` as the
TREE's, 21/11 - deliberately: `wa update` compares it with origin/main) while the version line named only
the bytes, which are an older commit. `/health` composes the same label (`rust/wa-capabilities/src/serve.rs`,
`"build": crate::host::live_build_label()`), so it said `9a0c589a` too - proved in the row with the
pre-change binary, which is the green/red half of this report.

## What changed (`rust/wa-host/src/build_info.rs`, `install_label`)

The label names both facts when they differ:

    wasm-agent v0.1.2 · v9a0c589a · tree fe108a8c

and `/health`'s `build` field is the same string, because there is ONE composer.

**Keyed on `lua_tree=`, never on `commit=`.** The record's shapes decide it (`scripts/deploy.sh`): a Lua
fast-path deploy writes `commit=` = the tree and `lua_tree=` = the tree; a prebuilt deploy writes
`commit=` = the BINARY and `lua_tree=` = the tree it installed beside it; a release install (the bootstrap)
writes no `lua_tree=` at all. So "the tree is not the bytes" is exactly `lua_tree=` present and different.
An earlier cut of this change read `commit=` instead, and `scripts/test-version-prints-once.sh` caught it by
name: an ordinary release record (`commit=2104a4d8... release=v0.1.1`) grew a `tree` half it does not have.

The suffix is only added for a commit the record really carries, compared prefix-wise (7 to 40 hex are all
spellings of one commit): no record, `unknown`, a short form of the same commit, or a commit the label
already names add nothing, so an ordinary install's line does not change. A build that cannot name its own
commit still says `unknown build`, unchanged.

## The row, and that it discriminates

`scripts/test-version-names-the-tree.sh` (wired into `scripts/test.sh` beside the health-build-label row).
A copy of the tree's `wa` in a scratch install, a fast-path `installed.txt` written in the shape
`scripts/deploy.sh` writes (the record is written by hand on purpose: producing it with a real deploy would
build the tree and run the gate, and this row is about what a READER makes of it), then:

1. `wa --version` names the tree AND the bytes;
2. `/health`, from a REAL node on a free port against that scratch install, names the same tree;
3. `wa update --follow`'s final line (`installed <sha12>`) names the tree commit;
4. a record naming the binary's own commit adds no tree, and the same commit spelled short is still one
   commit;
5. an empty record still answers a name.

Measured, on the binary built from this branch:

    ok   --version names the tree this install runs: wasm-agent v0.1.2 · vfe108a8c+dirty · tree ffb5153e282f
    ok   and it still names the bytes that are executing
    ok   /health names the same tree: fe108a8c+dirty · tree ffb5153e282f
    ok   the follow's final line names the tree commit ffb5153e282f
    ok   no tree suffix when the install IS the bytes: wasm-agent v0.1.2 · vfe108a8c+dirty
    ok   and the same commit spelled short is still one commit
    ok   an empty record still answers a name: wasm-agent v0.1.2 · vfe108a8c+dirty
    version names the tree: ok (7 checks)

With the PRE-CHANGE binary (the installed `wa`, build 9a0c589a) the same row reads:

    FAIL --version does not name the tree fe108a8cac89 (it said: wasm-agent v0.1.2 · v9a0c589a)
    FAIL /health says '9a0c589a' and not the tree fe108a8cac89
    version names the tree: FAILED (7 checks, 2 failed)

which is the bug, reproduced.

Also green on the same binary: `scripts/test-version-prints-once.sh` (10 checks - the row that found the
`vv0.1.1` defect, and the one that rejected the first shape of this change),
`scripts/test-health-build-label.sh` (/health reads the record per request), and the `wa-host` unit tests
(`cargo test -p wa-host build_info`: 13 passed, including the new
`install_label_names_the_tree_when_the_bytes_are_older`).

## Checks run

Narrowed fast path (`WA_FAST_ROWS=/tmp/rows-version.txt`: `test-build-identity.lua`,
`test-cli-notice.lua`, `test-cli-view.lua`, `test-update-banner.lua`; no full suite, no suite lock),
`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-version-names-the-tree`.

The row this change adds, and the rows around it, on a binary built from this commit:

    scripts/test-version-names-the-tree.sh    version names the tree: ok (7 checks)
    scripts/test-version-prints-once.sh       version-once ok (10 checks)
    scripts/test-build-info.sh                test-build-info: 23 checks, 0 failed
    scripts/test-health-build-label.sh        health build label: ok (5 checks)
    cargo test -p wa-host build_info          13 passed, 0 failed
    scripts/test-land-plan.lua                land ok (109 checks)   <- a canary row, see below

and red on the PRE-CHANGE binary (the installed build 9a0c589a):

    FAIL --version does not name the tree fe108a8cac89 (it said: wasm-agent v0.1.2 · v9a0c589a)
    FAIL /health says '9a0c589a' and not the tree fe108a8cac89

The narrowed run reported failures in both of its passes, and **none of them was this change**. The
lesson is worth writing down, because it cost two runs:

- the FIRST pass graded a binary this session built by hand with plain `cargo build`, which leaves
  `WA_BUILD_SOURCE_COMMIT` empty. `lua/core/build_status.lua` reads that compile-time stamp
  (`host.runtime_info`), so its `relation` answered `unknown` and the land rows' canaries said
  `release-update (identity_unknown)`, while `test-build-info.sh` compared a dirty build against a clean
  commit. With the stamp the runner uses
  (`WA_BUILD_SOURCE_COMMIT=$(git rev-parse HEAD) WA_BUILD_SOURCE_TREE=$(git rev-parse HEAD^{tree})`) those
  rows are green - `test-build-info: 23 checks, 0 failed`, relation `fresh` - and
  `scripts/test-land-plan.lua` passes singly (`land ok (109 checks)`).
- the SECOND pass (a stamped binary) still shows 20 of 139 checks failing, none of them on a file this
  branch touches, and every one with an environmental cause on the evidence itself: `install-guards` fails
  with `upgrade: refused inside a turn running on the node it would replace` (this machine has live chat
  sessions), `deploy-bound` with `held 31s, past the 1s bound ... none of the 2 holder(s) ... can be hurt`,
  the pty rows (`run-live-pty`, `script-output-pty`, `bash-changes-pty`, `run-block-pty`) against the model
  provider, `release-channel`/`test-release-channel-e2e` on a real `release-linux.sh` build, and the ten
  `test-land-*` rows, which pass singly with this exact binary and time out only under the parallel run.
  `main-health` owns them, and the bill is a function of how loaded this node was, not of this diff (which
  touches one Rust function, one doc, one row and one wiring line).

The four Lua rows this change could reach - `test-build-identity`, `test-cli-notice`, `test-cli-view`,
`test-update-banner` - **pass** in both passes.

## Texts to approve

1. `wasm-agent v<product> · v<bytes 8 hex> · tree <tree 12 hex>` - the version line when the install runs a
   tree the bytes do not contain (the bytes' own half keeps its `+dirty` suffix when it applies).
2. The same string in `/health`'s `build` field (`<bytes label> · tree <tree 12 hex>`; the CLI prefixes the
   `v`, `/health` prints the label as composed - both were already true of the existing label).

No other wording changed: `unknown build`, the release tag, the `(pinned)` suffix and `/health`'s empty-record
fallback are as they were, and `scripts/test-version-prints-once.sh` holds them.

## Second request on this branch (Fable, 24/11): `--check` refreshes, and names the covering release

Fable ran `wa update --check` for real and got two things wrong:

    release list: 5 entries, read 2026-11-21 01:42Z, newest node-e4e40405d89b
    this node (fe108a8c): no published binary for fe108a8c on x86_64-unknown-linux-gnu

1. The list was three days old and `--check` decided from it. `--check` is the one place a person ASKS, so
   it now refreshes first (`update_banner.M.refresh`), bounded to `M.REFRESH_SECONDS` (10 s), and the line
   says `read just now`. A failed refresh is named with the old list's own date:

       release list: 5 entries, read 2026-11-21 01:42Z, newest node-e4e40405d89b; the refresh just now
                     failed (feed_unreachable), so this is the list as it stood

2. `no published binary for <sha>` was true by name and false in effect. `update_banner.M.covering` runs
   the INSTALLER's own lookup - the same `wa_node_release_digest_search` call from the same
   `scripts/lib/node-binaries.sh` the deploy sources, bounded in seconds, in the installer's cache root -
   and the answer names what it finds:

       no binary is published under <sha12>'s own name; the installer downloads node-<sha12>, built from
       the same inputs

   When the lookup cannot run (no tree, no target, or a node told to stay offline), the installer's own
   fallback sentence is printed instead, and a commit the list does not NAME keeps its honest "the release
   list cannot say whether ..." first half rather than being called unpublished.

Row: `scripts/test-check-listing.lua` (a Lua row, so the fast path's inventory carries it automatically),
10 checks, all green, driving the SAME `M.refresh` then `M.listing` that `wa update --check` calls, with the
functions' own seams (a fixture feed instead of a request, a `covering` answer instead of a digest walk):

    ok   the list line says 'read just now' after a refresh
    ok   refresh: a failing feed is refused by name (feed_unreachable)
    ok   the list line keeps the OLD date when the refresh failed
    ok   a covering release is NAMED: behind by (ccccccccdddd): no binary is published under
         ccccccccdddd's own name; the installer downloads node-9a0c589adfa0, built from the same inputs
    ok   a lookup that cannot run says what the installer will still do
    ok   a published commit still reads as published
    ok   a commit the list does not name keeps its honest first half and ADDS the installer's release
    ok   and it does not claim the commit is unpublished
    check listing ok (10 checks)

Red on the base (the same row, `WASM_AGENT_LUA_ROOT` at the canonical checkout):
`lua error: attempt to call a nil value (field 'refresh')` - the function does not exist there.

Narrowed fast path (rows: `test-check-listing`, `test-update-banner`, `test-build-identity`,
`test-cli-notice`, `test-cli-view`), 578 s: **all five pass**. The run reports 5 of 140 checks red -
`deploy-bound`, `esc-stops-pty`, `install-guards`, `release-channel`, `test-release-channel-e2e` -
which is the same load/live-session set this round already named, and none of them is on a file this
change touches.

`scripts/test-update-follow.sh`'s `--check` case now asserts the installer's fallback sentence (it runs with
`WA_UPDATE_CHECK=0 WA_OFFLINE=1`, so the digest walk refuses by name); the whole row is green (8 cases).

Texts to approve (this request):

3. `release list: <n> entries, read just now, newest <tag>`
4. `; the refresh just now failed (<reason>), so this is the list as it stood` (appended to that line)
5. `no binary is published under <sha12>'s own name; the installer downloads <tag>, built from the same inputs`
6. `no binary is published under <sha12>'s own name; the installer also accepts one built from the same inputs and looks for it at install time`
7. `; the installer accepts <tag>, built from the same inputs` (appended when the list does not name the commit)

## Limits

- The row proves the READER. It does not run a deploy: it writes the record shape `scripts/deploy.sh`
  produces. A real scripts-only deploy was not run on this node (nothing on a live node in this round).
- A record written by an installer older than `lua_tree=` gets no `tree` half - it cannot prove the tree is
  newer, so the line stays as it was. Unknown is not a claim.
- The follow's final line was already the tree's (`deploy-result.json`'s `commit=`); this round ASSERTS it in
  the same row rather than changing it.
