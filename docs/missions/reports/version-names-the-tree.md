# version-names-the-tree - `wa --version` and /health name the commit the node actually runs

Branch `change/version-names-the-tree`, base `origin/main` = fe108a8c (the landing of slice 1 + A-D).

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

## Texts to approve

1. `wasm-agent v<product> · v<bytes 8 hex> · tree <tree 12 hex>` - the version line when the install runs a
   tree the bytes do not contain (the bytes' own half keeps its `+dirty` suffix when it applies).
2. The same string in `/health`'s `build` field (`<bytes label> · tree <tree 12 hex>`; the CLI prefixes the
   `v`, `/health` prints the label as composed - both were already true of the existing label).

No other wording changed: `unknown build`, the release tag, the `(pinned)` suffix and `/health`'s empty-record
fallback are as they were, and `scripts/test-version-prints-once.sh` holds them.

## Limits

- The row proves the READER. It does not run a deploy: it writes the record shape `scripts/deploy.sh`
  produces. A real scripts-only deploy was not run on this node (nothing on a live node in this round).
- A record written by an installer older than `lua_tree=` gets no `tree` half - it cannot prove the tree is
  newer, so the line stays as it was. Unknown is not a claim.
- The follow's final line was already the tree's (`deploy-result.json`'s `commit=`); this round ASSERTS it in
  the same row rather than changing it.
