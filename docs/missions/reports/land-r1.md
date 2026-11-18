# land-r1 - one landable branch for landing round 1

Branch change/land-r1 in the worktree /home/victor/Work/missions/land-r1/wt, based on change/green-main
(37780221). Built and tested HERE (avell, x86_64, 16 cores, CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-land-r1).
Committed locally; never pushed.

## Commits this branch adds

    09381239 Merge branch 'change/release-glibc' into change/land-r1   (release-glibc d275a7ba)
    2ca9b46d Merge branch 'change/missions-docs' into change/land-r1    (missions-docs 3239f07d)
    b89c0ae1 land-r1: the land-signing fixture stages the glibc floor the publisher sources;
             mission reports live in docs/missions/reports

## 1. The merges, and the one place the two branches touched the same line

Both merges ran with --no-ff, in the mission's order. The second one (missions-docs) is documentation-only and
merged without a conflict. The first (release-glibc) had exactly two conflicts, both predicted by the land
run's evidence (~/.wasm-agent/land/land-20261118T144957Z-8cf1e439/evidence/merge.log):

  1. scripts/deploy.sh - ONE conflicting hunk, the list of libs the script sources:
     green-main added runtime-binding (its preflight/re-check helpers), release-glibc added glibc-floor (its
     wa_glibc_guard). Resolved by keeping both entries, each in its own side's relative position:

        for wa_lib_part in build-status build-requirements deploy-components node-binaries glibc-floor retire-unshipped runtime-binding; do

  2. REPORT.md - add/add (both branches add a report at the root). Resolved by the move in section 2, not by
     keeping one side's text.

Nothing else needed a hand: git auto-merged docs/COMPONENTS.md, docs/INSTALL.md, scripts/fleet-install.sh,
scripts/publish-node-binaries.sh, scripts/test-node-binaries.sh, scripts/test.sh, scripts/upgrade.sh, and the two
new libs (scripts/lib/glibc-floor.sh, scripts/lib/runtime-binding.sh) arrived whole from their own branches.

### Both behaviours are proved present, and neither was reworded

The resolved scripts/deploy.sh was read back against BOTH parents. Against the first parent (green-main) the
only differences are release-glibc's own change - the lib-list entry, the guard block, the ship_file line - and
against the second parent (release-glibc) the only differences are green-main's own change - the preflight, the
re-check, the ship_file line - plus the merged lib list. No third change was introduced.

green-main's half, unchanged:

  * step 0c, before the build (WA_RUNTIME_PREFLIGHT, line 382 onwards): the canonical runtime binding is
    resolved by scripts/runtime-install-binding.mjs BEFORE cargo runs, kept in WA_RUNTIME_PREFLIGHT and
    deliberately NOT exported as WA_RUNTIME_WORKTREE, so the install-time check cannot read it back and skip
    itself;
  * step 6, after the build: the same question asked again and compared with the preflight answer by
    wa_runtime_binding_recheck (scripts/lib/runtime-binding.sh), and a mismatch refuses the install.

release-glibc's half, unchanged, and in the position it demands:

  * NEW and NEW_SENTINEL are final before the block - lines 1004-1006 and 1014-1016 (built here), after the Lua
    fast path (615-618) and the published-binary path (691-695) have set the same variables;
  * the guard block is between its markers at lines 1044-1056 (wa-deploy-glibc-guard: begin / end);
  * the FIRST line that executes either candidate is line 1063 (the --capability-digest call on the new binary),
    nine lines after the block ends. Every other execution of the candidate is later still (--lua-tree 1105,
    the component proof 1180, the embedded proof 1212, the scratch serve 1220).

    grep -n wa-deploy-glibc-guard scripts/deploy.sh   ->  1044 begin, 1056 end
    bash -n scripts/deploy.sh                          ->  deploy.sh syntax ok

## 2. Mission reports never land at the repo root

Both root reports were moved, byte for byte (sha256 before and after), and no REPORT.md is left at the root:

    REPORT.md (green-main / harness-land, 111496 bytes) -> docs/missions/reports/harness-land.md
        sha256 e834bb273eba7fc4fd56f4abd5fa8ca223e80852748bc8baa1ab952bda2ab46f  (same both sides)
    REPORT.md (release-glibc, 24121 bytes)              -> docs/missions/reports/release-glibc.md
        sha256 e808879b4bf9f61a03028d01886de2b0aaaff77668c2a210528942ff80d5f4cc  (same both sides)

git records the first as a rename (R REPORT.md -> docs/missions/reports/harness-land.md) in the merge commit that
had to resolve the add/add; the second is the same blob under its new path. No content was edited in either.

docs/MISSIONS.md does not exist on this branch (it has not been created on any of the three merged branches), so
the line went to docs/missions/QUEUE.md, after the Rules paragraph, verbatim:

    Mission reports live in docs/missions/reports/<mission>.md, never at the repo root.

This report therefore lives at docs/missions/reports/land-r1.md. The launch brief's last section also says
"Write REPORT.md in the worktree root"; item 2 of the same mission forbids exactly that, and item 3 names this
path, so the specific rule won - a root report would contradict the rule this round is establishing.

## 3. The one place the merge was genuinely red, and what it needed

The merge is not a pure text join: release-glibc's publisher now SOURCES scripts/lib/glibc-floor.sh before it
will read a manifest's glibc_floor= back out of the artifact, and green-main's scripts/test-land-signing.sh
builds a fixture that stages every lib the publisher sources - except that one, which is in neither branch's
version of the list. Measured, in this order:

    /tmp/land1-base   (change/green-main 37780221)   ->  land signing ok (46 checks)
    /tmp/land1-glibc  (change/release-glibc d275a7ba) ->  land signing FAILED: the artifacts step accepts a
                                                          set built elsewhere: expected status 0, got 2

i.e. release-glibc was already red on this row alone; the merge inherits it. The refused run's own words, taken
by running a patched copy of the row that prints the publisher's output:

    publish-node-binaries: glibc_floor_lib_missing: .../fixture/scripts/lib/glibc-floor.sh
    (the floor a manifest claims is read back out of the artifact with it)

The fix is five lines in scripts/test-land-signing.sh and nothing else: the fixture stages
scripts/lib/glibc-floor.sh beside the other libs, with a comment saying why. No assertion, no message and no
count changed - the row reports 46 checks before and after, exactly as green-main's own run of it did. Neither
merged behaviour was touched: the publisher still refuses to publish without the lib, and the fixture now carries
it, which is what the real tree does.

## 4. The proofs, quoted

At HEAD (b89c0ae1), in /home/victor/Work/missions/land-r1/wt:

    bash scripts/test-glibc-floor.sh
      exit=0
      glibc floor ok (109 checks)
      (the row's own note: scan against the ELF: BUILT ARTIFACTS SKIPPED - WA_GLIBC_ARTIFACT_DIR is not a
       directory; the artifacts case is 100 checks when it is, and it is not needed to judge the merge)

    node scripts/test-runtime-binding-preflight.mjs
      exit=0
      {"ok":true,"checks":8}

    bash scripts/test-deploy-runtime-recheck.sh
      exit=0
      deploy runtime re-check ok (11 checks)

    bash scripts/test-land-signing.sh
      exit=0
      land signing ok (46 checks)

### The gate: bash scripts/fast.sh --jobs 16 - 262 checks, 0 failed, 0 skipped

    fast result ok (262 checks, 0 failed, 0 skipped): .../wt12/wa-fast-result.json
    fast path ok (262 checks, 0 skipped, 162s)

    env: root /home/victor/Work/missions/land-r1/wt  commit b89c0ae1  branch change/land-r1
         bin /home/victor/wasm-agent/target/m-land-r1/release/wa  sha256 25cb5af0779a6c09ae7819457d1e157953de5d82d6a7ed571de51394279eebef
         node v26.13.1 (node:sqlite yes), cargo 1.100.0, wasi-sdk 34.0, Lua 5.4.9
    lua 227/227 passed (56 excluded: scripts/fast-path.exclude); every rust crate this change touches ok
    (wa-capabilities 9s, wa-sentinel 34s, wa-mesh 0s, ...); every contract check ok.

### Two earlier gate runs, and why they are not the measurement

Both are named because a red that is dismissed without its cause is how a real one gets through.

  1. 12:02-12:07, 262 checks / 3 failed, DISCARDED AS MINE TO CAUSE: this agent's own shell exports
     WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS=300, and fast.sh clears the vault, identity and mode variables
     for a row but not that one, so test-provider-stall.lua saw a 300s deadline instead of its default 90s:
         FAIL lua scripts/test-provider-stall.lua: a provider call gets its own 90s first-response deadline:
              got 300, want 90
     The re-run with that variable cleared has the row green, and it is green in the 262/0/0 run above. This is
     the machine's ambient environment, not the tree: lua/core/provider.lua returns 90 when the variable is unset.

  2. 12:08-12:12, 262 checks / 3 failed: land-signing (the fixture gap in section 3, fixed) plus two Lua rows
     that did NOT reproduce:
         FAIL lua scripts/test-release-sign.lua: release signing: 2 of 5 checks failed
         FAIL lua scripts/test-harness-evaluator-privacy.lua: ... says it is ignored
     Each passes on its own in this tree, with the runner's own environment (the variables fast.sh sets and
     clears), and the next full run passed all 227 Lua rows:
         scripts/test-release-sign.lua              -> release signing ok (5 checks; the vault signs, every install path verifies)
         scripts/test-harness-evaluator-privacy.lua -> harness evaluator privacy ok (26 checks)
     Neither file, and nothing they read, is touched by any of the three branches. They are the parallel
     runner's flakiness under --jobs 16, seen once in three runs; they are not called pre-existing (there is no
     base to blame: green-main's own round measured 262/0/0) and they are not claimed explained - what is
     measured is that they do not reproduce, and that the 262/0/0 run above is on the committed tree.

## 5. What was not done, and what is unknown

  * Nothing was pushed, published or deployed. No node state was touched: every row ran in its own scratch
    home, and the only git writes are the commits above.
  * The gate ran on avell only. The four other nodes were not asked to build or test this branch.
  * Two temporary worktrees were used to name the base (/tmp/land1-base at change/green-main, /tmp/land1-glibc
    at change/release-glibc) and both were removed afterwards; they were never built - the row there ran shell
    and Lua only.
  * The parallel-run flakiness of the two Lua rows in 4 is unexplained beyond does-not-reproduce; the fast path
    counts the failure it saw, and no retry loop was added to hide it.

