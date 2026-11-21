# release-fix: the ship step's --from half names the ancestry floor

Mission 21/11, branch `change/release-fix`, base `34a552d0`. Committed locally; never pushed.

## The defect, re-measured

`git show ed693a0b:scripts/publish-node-binaries.sh | sed -n 624p` is exactly

    if "$file" --contains "$WINDOW_FLOOR" >/dev/null 2>&1; then

and that commit assigns `WINDOW_FLOOR` only in its build half (lines 550-557). `--from` skips that
half and shares its verify loop, so land250's ship died there **after** verifying every artifact:
`~/.wasm-agent/land/land-20261121T171314Z-1686339d/evidence/ship.log` shows the two aarch64
`cannot be executed on this host` lines and `verified wa-x86_64-...-ed693a0bcefc` immediately above
`line 624: WINDOW_FLOOR: unbound variable`. land250, land251 and land253 therefore put their code on
main and made no signed release.

## The fix (34a552d0, the base of this mission: verified, not rewritten)

Both halves now set the ONE variable the shared loop reads, `ANCESTRY_FLOOR`:

- the `--from` half (522-524) computes it with `wa_ancestry_window_floor` and refuses by name
  (exit 2) when this checkout cannot answer, rather than publishing a set whose window nobody named;
- the build half (562) sets `ANCESTRY_FLOOR="$WINDOW_FLOOR"`, so its behaviour is unchanged;
- the loop (632-636) asks every runnable artifact about `ANCESTRY_FLOOR`.

Every path was run under `set -uo pipefail` (below) and no other variable is read unset.

## What this branch adds

- **7fb6b40a** removes a stray `b2` gitlink that 34a552d0 had swept into the tree: a submodule entry
  pointing at ed693a0b with no `.gitmodules` and no content. `git ls-files -s | grep 160000` is now
  empty. `git worktree list` names where the entry came from: `/home/victor/Work/missions/release-ancestry/wt/b2`, a linked worktree of this repository sitting at that path, which a `git add -A` swept into the tree.
- **82545e5a** rewrites `scripts/test-publish-from-ancestry.sh` and wires it into `scripts/test.sh`
  right after the ancestry-window row. The previous version needed a real `wa` built from HEAD, so on
  the base it printed SKIP - a row that cannot fail catches nothing. The new one compiles a stand-in
  artifact that answers exactly the two subcommands the publisher asks of an artifact (`--build-info`,
  `--contains`) plus `--version`, and it runs the publisher with `--local` so `git ls-remote origin`
  (this repository's origin is a LIVE peer) is never called by a test. It also covers what the old one
  did not: the floor must equal what `wa_ancestry_window_floor` names for this commit, and an artifact
  that answers `--contains` with a failure must be refused with exit 5, so the floor is asked and not
  merely printed.

## Verification, on avell (what was run)

| path | how | result |
| --- | --- | --- |
| parse | `bash -n` on publish-node-binaries.sh and the test | ok |
| `--from`, cross arch + runnable arch | `WA_TEST_SCRATCH_HOME=1 bash scripts/test-publish-from-ancestry.sh` | 11 checks, 0 failed, exit 0 |
| `--from`, short window | same file, 5th case (`WA_STUB_CONTAINS_RC=1`) | refused, exit 5 |
| fresh build | ad hoc stub-toolchain run of the build half (not committed: it passes on the base too, so it could not discriminate), on HEAD **and** on ed693a0b | 6 checks, 0 failed, both |
| `--check` | `bash scripts/publish-node-binaries.sh --check --local` | exit 0, prints the set |

The build-half harness stubs `cargo`/`cargo-zigbuild`/`rustc`/`zig` and the artifact bytes: the
compiler is not the subject of this change, and a real cross build is 259 s per triple. It runs in a
scratch worktree with its own HOME, `--local`, `WA_RELEASE_SIGN_DEFER=1`, and nothing published.

## Discrimination (required check)

    bash scripts/test-discriminates.sh 675253ecd3b5a41952ef107eb1e13f26119a71b3
    discriminates  scripts/test-publish-from-ancestry.sh
    test-discriminates: 1 discriminating, 0 blocking, 0 not judged

Against the base script (ed693a0b, the merge base) the row fails on the unbound variable; here it passes.

## Premises of the brief, re-measured

- `line 624` and `WINDOW_FLOOR: unbound variable`: exact (above).
- "after `verified wa-x86_64-...`", on a host that cannot run aarch64: exact, from ship.log.
- base of the mission = 34a552d0: exact.
- **correction 1**: 34a552d0 also added a `b2` gitlink to the tree; removed in 7fb6b40a.
- **correction 2**: the test 34a552d0 added could not fail on the base (it needed a release build and
  SKIPped), and it was not wired into `scripts/test.sh`; both fixed in 82545e5a.

## Texts to approve

New or changed operator/model-facing lines, verbatim (numbering continues in the report):

1. `publish-node-binaries: ancestry window floor: <floor> (the oldest commit these artifacts must be able to contain)`
2. `publish-node-binaries: ancestry_window_unknown: this checkout cannot name the release below <commit>, so the artifacts in <from> cannot be shown to contain it` (exit 2)
3. `test-publish-from-ancestry: 11 checks, 0 failed` (the row's verdict; printed as `<n> checks, <m> failed`)
4. `  ok   <assertion>` and `  FAIL <assertion>` (the row's per-assertion lines)
5. `SKIP test-publish-from-ancestry: HOME (<home>) is a real node home; run it through scripts/test.sh`
6. `test-publish-from-ancestry: no C compiler (cc) to build the runnable stand-in artifact; this row cannot be judged here` (exit 2)
7. `test-publish-from-ancestry: this checkout cannot name the ancestry floor for <sha12> (a shallow clone cannot), so there is nothing to compare against` (exit 2)

Lines 3-7 are the new test's own; nothing a node reads changed. The two `ancestry window` messages the
loop prints keep their wording from the base - only the variable behind them changed.

## Not done, and unknown

- The ship step itself was not re-run here (it runs at the next landing); no release was published and
  nothing was pushed.
- The real aarch64 artifact was never executed (this host cannot), so its window remains "not proved
  here" by design, as the publisher says.
- No full `scripts/test.sh` run: the change is a test file, one runner line and a shell variable; the
  gate runs it on landing.
