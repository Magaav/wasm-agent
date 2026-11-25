# cover-is-the-same-program

Priority 1, week 1. A cover is the same PROGRAM only if its embedded Lua is equal too.

Branch `change/cover-is-the-same-program`, base `70eb209d`, worktree
`/home/victor/Work/missions/cover-is-the-same-program/wt`.

* `aef1ec5a` - removes `scripts/publish-named-release.sh` and the shortcut behind it (job 3).
* `726215ce` - the release names the Lua it embeds, and a tree-less install refuses a cover whose Lua
  differs, by name (job 1, second branch; job 2).

The report below weighs the two branches of job 1 with numbers, says what each commit implements, and
names what is NOT done (the coordinator end of the tree-less door) and the pre-existing failures I met.

## Premises, re-measured before writing code

| the brief said | measured on the base (`70eb209d`) | verdict |
| --- | --- | --- |
| node-3589b5ca9690 was published as "named for 3589b5ca" with the bytes of node-a1857d15887c | the mechanism is in `scripts/publish-named-release.sh:69-91` (`wa_compiled_inputs_digest` equality is the only gate) and its caller `scripts/publish-node-binaries.sh:387-401` on the base, removed by `aef1ec5a` (`--named-from-cover`, gated on `--ensure` answering `covered`) | correct |
| a tree-less node runs the binary's EMBEDDED Lua | `scripts/upgrade.sh:690-692` sets `CHECK_TREE` from `$INSTALL_DIR/lua-core/manifest.txt`, which a release install has none of; `rust/wa-host/build.rs:19-50` embeds `lua/core`, `lua/vendor` and the four AGENTS documents | correct |
| `compiled_inputs` excludes the embedded Lua tree | `scripts/lib/node-binaries.sh:92-118`: `wa_compiled_input` returns 1 for every `lua/*` path | correct |
| the record of a tree-less install names the commit and the tree of the Lua it runs, today via `--build-info` | `rust/wa-host/src/build_info.rs:39-53` prints `commit=` and `tree=`; `scripts/release-install.sh` refuses an install whose `--build-info` disagrees (`GOT`, line 144 in this tree). It writes no `lua_tree=` (`build_info.rs:159-166` says so) | correct |
| `scripts/publish-named-release.sh` is unused since 25/11 | `scripts/publish-node-binaries.sh` no longer sets the flag from the cut (`ee1fda77`), and nothing else passes `--named-from-cover`; the script and its test were the only callers in this tree | correct |
| the cut is in flight, nothing lands before it | `~/Work/missions/_orch/CUT-BUILD-DONE` existed before this session built or ran anything; no cargo build was run here (the acceptance rows need no binary and SKIP without one) | - |

Nothing in the brief was wrong. Two things it did not say, both measured here and both matter:

* a tree-less node has **no tree to compute a digest from** - `wa_compiled_inputs_digest` and
  `wa_lua_tree_digest` are git questions (`scripts/lib/node-binaries.sh:122`, `scripts/lib/lua-tree.sh:39`),
  so `wa_node_release_digest_search` cannot run on the node it is for. Any design that "refuses on the
  server side by comparing digests" has to say who computes them.
* a node release carries **no scripts** (`wa_node_binary_download` fetches `node-<sha12>.manifest`,
  `SHA256SUMS`, `SHA256SUMS.sig`, `wa-*`, `wa-sentinel-*` and nothing else), so a scripts-only commit is
  installable on a tree-less node only if its Lua is the embedded Lua's - which is exactly the case where a
  cover is honest. The scripts on disk stay what the last install shipped.

## Job 1 - the decision, with numbers

Both branches were implemented as far as measurement needed; only one is in the tree.

**Number that decides it.** Over the last 250 first-parent commits of `origin/main`
(`git rev-list --first-parent -n 250 origin/main`, every changed path classified with the product's own
`wa_compiled_input`):

| landings | count | what it means |
| --- | --- | --- |
| a compiled input changed | 31 | a build is published either way |
| **Lua-only** (`lua/*` or an AGENTS document, no compiled input) | **64** | covered today; **one full cargo build each under the alternative** |
| neither (docs, scripts, tests, ui, skills) | 155 | covered under both |

So folding `lua/` into `wa_compiled_input` ("`compiled_inputs` includes the embedded Lua tree") prices
95 builds per 250 landings instead of 31 - **+206 %** - and it breaks the thing it is not aimed at: the
deploy's Lua fast path (`wa_node_binary_reuse`, `scripts/lib/node-binaries.sh:176`) would answer `binary:
needed` for every Lua deploy on a node that stages `lua-core/` from its own checkout and never reads the
embedded copy. A tree node would pay a rust build for a Lua file.

**The refusal path costs nothing on a tree node** and costs a tree-less node exactly what is true: a
Lua-changing commit is not installable there unless a build of that commit is published, because the Lua
is inside the binary. The refusal names the two digests, so the operator knows which side must move.

Verdict: **the refusal path** (`726215ce`), with the release recording the fact the refusal needs
(`lua_inputs=`). The alternative is refused in the code comment at
`scripts/publish-node-binaries.sh:128-136` and here with the numbers above.

## Job 2 - the record names the commit and the Lua it runs (`726215ce`)

* `scripts/publish-node-binaries.sh` writes `lua_inputs=<sha256>` into every node release manifest, from
the source commit's tree (`wa_lua_tree_digest`, the same file list `scripts/deploy.sh` stages). The build
path refuses without it (`lua_inputs_unavailable`, exit 2/7), and `--from` **recomputes** it: a manifest
naming another tree is refused, `lua_inputs_mismatch` exit 5 (`git show 726215ce --
scripts/publish-node-binaries.sh`). `--check` prints `lua inputs: <digest>`.
* `scripts/upgrade.sh` writes three fields into the record of an install that used a cover:
`lua_inputs=`, `cover_lua_verified=yes`, `binary_source_commit=<the bytes' commit>` (`git show 726215ce --
scripts/upgrade.sh`, the `record_install` addition). `commit=` stays the binary's own answer - the 25/11
defect was a record that claimed a commit its bytes were not built from, and nothing here repeats it.
* **Gap, stated as a gap**: no row drives `record_install` (it runs after the swap), so the three fields are
in the diff and are **not** proved written by a test. The next row is a full release install on a scratch
node, which needs a binary this session did not build.

## Job 3 - the named release is gone (`aef1ec5a`)

`scripts/publish-named-release.sh` and `scripts/test-publish-named-release.sh` are deleted;
`scripts/publish-node-binaries.sh` loses `--named-from-cover` and the branch that ran it; `scripts/test.sh`
loses that row. `scripts/test-cut-builds-own.sh:52-54` - whose row said "still exists ... removed in week
1" - is **inverted**, not dropped: it now asserts the flag is gone and the script is gone. Its row is
13 checks green after the commit.

## The refusal path, in code

`scripts/upgrade.sh` (after the signature gate, before anything is staged) reads the release's manifest and,
**only when both** `WA_UPGRADE_REQUESTED_COMMIT` (the commit the node is being moved to) is set **and** the
install has no `lua-core/manifest.txt` (so the embedded Lua runs), compares

* `WA_RELEASE_LUA_INPUTS` (the target commit's `wa_lua_tree_digest`, from the caller that has a tree) with
* the release's `lua_inputs` row (whose own bytes are checked against the signed `SHA256SUMS` first).

Four named refusals, one line each, all before staging: `release_cover_lua_unknown` (no digest given, or
not a sha256), `release_cover_lua_unrecorded` (no row), `release_cover_lua_mismatch` (different, both
named), `release_cover_lua_manifest_unverified` (the manifest is not the file the signed sums name). Equal
digests pass and the install continues, which is what makes an honest cover (docs/scripts/tests-only) work.

The gate is **inert for every path that exists today**, because nothing sets `WA_UPGRADE_REQUESTED_COMMIT`
except `scripts/release-install.sh` with `--cover-commit`. That is deliberate: it is an allow-list wall at
the one door that installs bytes, not a new default.

`scripts/release-install.sh` gains `--cover-commit <40-hex>` and `--lua-inputs <sha256>`; with a cover it
fetches that commit's verified directory, verifies the installed `--build-info` against **the bytes'
commit**, and says `covered: <target> installed the bytes of <cover>, whose embedded Lua tree is <target>`.
Without a cover it refuses with `release_cover_needed`, one line, naming what to pass and quoting the
channel's own answer.

## What Victor's test does today

`wa update <tree-less node> --release --commit C` for a **scripts-only** C: no release names C (`node-<sha12>`
is built only by the cut, `ee1fda77`), so the node answers one line:

    release_install: release_cover_needed: no release names <sha12> and this node has no tree to build it
    from; a cover (another commit's build) is only installable when its embedded Lua tree is <C>'s, so pass
    --cover-commit <40-hex> --lua-inputs <sha256> ... The release channel said: node_release_unavailable: ...

For the same C with the cover named (`--cover-commit <base> --lua-inputs <C's lua digest>`), the install
runs and the record names the bytes' commit plus the Lua tree they embed. For a **Lua-changing** C the same
invocation refuses `release_cover_lua_mismatch` with both digests - which is the second branch of the
acceptance sentence, and the whole point.

**Not done, and it is the one thing between this and `wa update peer --release` doing it by itself**: the
coordinator does not compute those two facts. `lua/core/remote_update.lua`'s `request_release` (`:449-475`)
sends only `record.target_commit`, and the peer record carries no release triple (`:203`, `:617-618` name
`install` and `tree` only), so `wa_node_release_digest_search` - which needs `<repo> <commit> <triple>
<cache>` - cannot be called for the peer without inventing that triple. The two facts are computable on the
coordinator for the commit (`wa_lua_tree_digest`) but not the triple, so wiring it is a small change to the
peer record first. I did not fake it.

## How the row proves it, and where it is wired

`scripts/test-cover-lua.sh`, wired into `scripts/test.sh:534-537` (the release gate lane, next to
`test-cut-builds-own.sh`). 24 checks, green in this tree, **15 of them failing on the base commit**
(`bash /tmp/base-cover/scripts/test-cover-lua.sh` against a worktree of `origin/main`, the same file).

* The classification rows use a **fixture git repository** with three commits, and the product's own
  `wa_compiled_inputs_digest` / `wa_lua_tree_digest`: a Lua-only commit leaves the compiled digest equal and
  changes the Lua digest; a scripts-only commit changes neither. That is the premise of the decision, so it
  is a row and not a sentence.
* The publisher rows run the real `scripts/publish-node-binaries.sh` against a fixture tree (a mission
  worktree is dirty and unpushed, both of which the publisher refuses on purpose), with
  `ALLOW_UNPUSHED_COMMIT=1`/`ALLOW_UNPUSHED_REASON` - the publisher's own name for a development artifact.
* The four refusals run through the **real** `scripts/upgrade.sh`, installed into a scratch install
  directory, against a **really signed** release (a scratch `wa-vault`, `scripts/lib/test-release-vault.sh`),
  so the order (signature first, then the Lua gate) is what is proved. Nothing reaches the real node:
  `HOME`, `WASM_AGENT_HOME`, `TMPDIR` are a scratch home created through `wa_scratch_root` and checked with
  `wa_scratch_home_guard`; the vault is scratch on its own ports; no relay, no fleet call, no gh.
* `scripts/test-node-binaries.sh` gained the `--check` plan row and the `lua-tree.sh` copy its fixture needs
  (`726215ce`). That suite cannot run past its `not_on_main` row on the base either - see below.

## Pre-existing failures I met and did not touch

Both reproduce on a worktree of `origin/main` (`/tmp/base-cover`), so neither is mine:

1. `scripts/test-node-binaries.sh` fails at "a commit that is not on origin/main is refused": the publisher
   now answers `commit_not_on_pushed_branch` (the fixture has no `origin` remote) where the row expects
   `not_on_main:`. Everything after that row (including the `--from` section) never runs.
2. `scripts/test-deploy-node-binaries.sh` fails at "the record step for a prebuilt install: expected status
   0, got 1".

## Texts to approve (verbatim)

1. `lua inputs: <digest> (the Lua tree this binary EMBEDS: a tree-less node runs it, so a cover must match it)`
2. `lua_tree_lib_missing: <path> (the digest of the Lua a binary embeds is what makes a cover checkable)`
3. `lua_inputs_unavailable: cannot digest the Lua tree the binary of <commit> embeds`
4. `lua_inputs_mismatch: <from>'s manifest records lua_inputs=<a> and <commit>'s Lua tree is <b>, so those bytes embed another program than this commit's`
5. `refused(release_cover_lua_manifest_unverified): <dir>/SHA256SUMS does not carry the hash of <manifest> (declared <a>, this file is <b>), so the Lua tree it claims cannot be trusted - and on a node with no Lua tree of its own that claim is the whole decision; nothing was staged`
6. `refused(release_cover_lua_unknown): <dir> is the build of <commit> and this install has no Lua tree, so these bytes are run through their EMBEDDED Lua - and no Lua-tree digest for <target> was given, so whether the two are the same program cannot be told; nothing was staged. The caller that has the tree passes it (scripts/release-install.sh --lua-inputs, or WA_RELEASE_LUA_INPUTS).`
7. `refused(release_cover_lua_unknown): WA_RELEASE_LUA_INPUTS=<value> is not a sha256 of a Lua tree, so <target>'s Lua cannot be compared with the Lua these bytes embed; nothing was staged`
8. `refused(release_cover_lua_unrecorded): <manifest> names no lua_inputs row (source_commit=<commit>), so the Lua these bytes embed cannot be compared with <target>'s; nothing was staged`
9. `refused(release_cover_lua_mismatch): these bytes embed Lua tree <a> and <target> has Lua tree <b>, and this install has no Lua tree of its own to put beside them - installing it would run another program's Lua under <target>'s name; nothing was staged`
10. `release_cover_lua_unknown: a cover runs its binary's embedded Lua, and this node has no tree to compute the Lua-tree digest of <commit> from - pass --lua-inputs <sha256> (wa_lua_tree_digest <tree> <commit>), or install a release named for <commit> itself`
11. `release_cover_needed: no release names <sha12> and this node has no tree to build it from; a cover (another commit's build) is only installable when its embedded Lua tree is <commit>'s, so pass --cover-commit <40-hex> --lua-inputs <sha256> (the coordinator's wa_node_release_digest_search plus wa_lua_tree_digest). The release channel said: <answer>`
12. `cover_commit_pointless: --cover-commit names <commit> itself; ask for it as the release commit`
13. `cover_commit_invalid: "<value>" is not a full 40-hex commit id`
14. `  node-<sha12> is not published: taking the cover node-<sha12> (a build of <commit>, whose Lua tree must be <target>'s)`
15. `covered: <target> installed the bytes of <cover>, whose embedded Lua tree is <target>'s (lua_inputs <digest>)`

## Rules this round kept deliberately

* Unknown is not yes: the gate refuses when a digest was not given, when the manifest has no row, when the
  manifest's bytes are not the signed ones, and when the target commit's Lua cannot be had at all. There is
  no path in which "cannot tell" installs.
* Refactor-only: no. Every row added fails on the base (15 of 24), and the two inverted rows in
  `test-cut-builds-own.sh` fail on the base because the flag is still there.
* The heavy suites were run one at a time, single files, no `flock` needed; nothing long was started in this
  session (no cargo build: `CUT-BUILD-DONE` was present, but no row here needs a binary and every row that
  does SKIPs loudly).

