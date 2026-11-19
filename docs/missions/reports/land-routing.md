# Mission change/land-routing — wa land end to end, no hand steps

Base: origin/main ac7717e0. Branch `change/land-routing`, rebased onto ac7717e0. Committed locally, never pushed.

## Items 24–29 (committed earlier, `a48a55a9` → rebased `9d2d4817`)

| item | commit | witness in `scripts/test-land.lua` |
| --- | --- | --- |
| 24 bare `--resume` finds the run | a48a55a9 | `case 24` (line 1446) |
| 25 land branch never reuses a remote ref | a48a55a9 | `case 25` (line 1465) |
| 26 `--account <node>` pushes main and publishes there; `gh auth status` gates it | a48a55a9 | `case 26` (line 1474) |
| 27 `wa land mark <step> --evidence` re-verifies | a48a55a9 | `case 27` (line 1509) |
| 28 start options stored, a pinned node never moved by a ring | a48a55a9 | `case 28` / `28b` (line 1553, 1574) |
| 18 one row inventory | a48a55a9 | `case 18` (line 1590) |
| 29 ancestry from the signed manifest / a shallow fetch | a48a55a9 | `scripts/test-install-record.sh` (diff in that commit) |

## Done this session

| what | commit | test |
| --- | --- | --- |
| A compiled round that also moves `components.lock` builds the bundle in `artifacts` (item 28) | 9d2d4817 | `case 30` in `scripts/test-land.lua`; `land ok (407 checks)` |
| A node release and a component bundle never take GitHub's "Latest" (item 28) | 70bc5241 | `scripts/test-publish-artifacts.sh` (fast path) — red on the base, green here (56 checks); `scripts/test-deploy-components.sh` (74 checks) |
| A release-installed node gets `release` mode (item 28) | 4532be19 | `scripts/test-remote-update.lua` section 7h — `remote update ok (120 checks)`; `scripts/check-deploy-shipped.mjs` (185 checks, 61 rules) |

## What was NOT finished (honest list)

- The **full fast suite / full gate was not run** in this session. Each touched row was run individually and is green.
- `scripts/test-node-binaries.sh` is **red on the base** (`commit_not_on_pushed_branch` / a fixture that copies no `build-target.sh`) — pre-existing, named here, not fixed. My `--latest=false` witness for that file was therefore **withdrawn** and placed in `test-publish-artifacts.sh`, which proves the command that actually runs on the account node.
- `land`'s ring passes `mode` through verbatim, so `node:release` reaches the new mode, but **no `case` in `test-land.lua` drives a ring entry in release mode end to end**.

## Texts to approve (verbatim)

1. `--release  a node installed FROM a release (no tree): fetch the published release and install it as a neighbour process`
2. `wa update <node> [--commit <sha>] [--binary|--tree|--release] [--rendezvous] [--reason <text>] [--session <id>] [--json]`
3. `release_install: release_target_unknown: this host is not one of the published targets (...) `
4. `release_install: installed_but_unproven: pid <pid> runs <exe>, and this install is <expected>; the node is serving bytes this install does not hold`
5. `release_install: installed_but_unproven: the installed build names commit=<got>, this release is <commit>`
