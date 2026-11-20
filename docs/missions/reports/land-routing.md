# Mission change/land-routing — wa land end to end, no hand steps

Base: origin/main ac7717e0. Branch `change/land-routing` (rebased onto ac7717e0). Committed locally, never pushed.
Review r1 findings are fixed in dedicated commits; every claim below cites the commit that implements it,
checked with `git show origin/main:<file> | grep -c <symbol>` against the head.

## Items 24–29 and #18 (committed earlier, `a48a55a9`)

| item | symbol | base | head | witness |
| --- | --- | --- | --- | --- |
| 24 bare `--resume` finds the run | `newest_unfinished` glob | base: (quoted glob) | a48a55a9 | `case 24`, test-land.lua |
| 25 land branch never reuses a remote ref | next free from ls-remote | — | a48a55a9 | `case 25` |
| 26 `--account <node>` pushes main and publishes there | `main_account` | base=0 | a48a55a9 | `case 26` |
| 27 `wa land mark <step> --evidence` re-verifies | `M.mark` | base=0 | a48a55a9 | `case 27` |
| 28 start options stored; a pinned node never moved by a ring | `start` in journal | `no_deploy` base=2 | a48a55a9 | `case 28`/`28b` |
| 28 a compiled round moving components.lock builds the bundle in `artifacts` | `also_components` | base=0 | **9d2d4817** (case 30 is the witness, not a48a55a9) | `case 30` |
| 28 a node release / component bundle never takes GitHub's "Latest" | `--latest=false` | base=0 | **70bc5241** | `test-publish-artifacts.sh` (witness), `test-deploy-components.sh` |
| 28 a release-installed node gets `release` mode | `scripts/release-install.sh` | base=absent | **4532be19** | `test-remote-update.lua` §7h |
| 18 one row inventory | `row_inventory` | **base=3** (already on base — only the test is new) | — | `case 18` |
| 29 ancestry from the signed manifest / a shallow fetch | `upgrade.sh` manifest branch | base=absent | a48a55a9 | `test-install-record.sh` |

## Review r1 fixes (this round)

| review item | commit | what it does | test |
| --- | --- | --- | --- |
| MUST 1 (#61): a Lua-only round skipped ship/publish without looking at the ring | **002f1c17** | `build_plan` takes the ring; a `release`-mode entry forces a node-release plan and names the node | `case 31` (test-land.lua); `land ok (429 checks)` |
| MUST 3: no case drove a `release` ring entry / coordinator signer | **c8373793** | `case 32`: mixed ring, signer=laptop; an unknown ring mode is refused by name before any node is asked | `case 32`/`32b` |
| MUST 4: the report credited a48a55a9 with everything | this commit | this table; each row re-measured against origin/main | — |
| MUST 5: the full fast path | run below | — | see the run log |

## MUST 2 (#60) — measured stale, no code needed

The review asks for a release binary able to answer `--contains` with embedded ancestry. **It already does:**
`rust/wa-host/build.rs` embeds `rev-list HEAD` as sorted `ancestors=`, refuses to claim completeness from a
shallow clone, and `rust/wa-host/src/build_info.rs` `contains()` answers 0/1/2 from it (commit **483729d4**,
`deploy: a binary reports its own build`). `grep -c ancestors` on `origin/main:rust/wa-host/src/build_info.rs`
= 4. `scripts/lib/install-record.sh` `wa_contains` already asks the running and candidate binaries, and
`test-install-record.sh` proves the "running contains target" and "target cannot answer" paths. No new
commit was made for #60 because the premise is met by 483729d4, which predates this branch.

## MUST 5 — the full fast path, and the suite that is red on the base

**`scripts/test-node-binaries.sh` is red on origin/main**, proven in a base worktree
(`git worktree add ../basenb origin/main`, log `basenb/…`):
```
node binaries (publish) FAILED: the main refusal is named: 'not_on_main:' not in: … line 179:
  …/fixture/scripts/lib/build-target.sh: No such file or directory
publish-node-binaries: commit_not_on_pushed_branch: could not ask the remote …
```
Two pre-existing causes: the fixture copies no `scripts/lib/build-target.sh`, and it has no real `origin`,
so the shared-commit guard answers "cannot tell" before `not_on_main:` is reached. Because that suite cannot
reach the `--from` rows, the `--latest=false` witness lives in `scripts/test-publish-artifacts.sh` (fast
path, line 757 of fast.sh), which asserts the command that **runs** on the account node; it is red on the
base (the flag is absent) and green here.

Full fast path on this branch: **ok (295 checks, 0 failed, 0 skipped, 208s)** - `fast-head2.log`, exit 0.
Full fast path on a base worktree (`git worktree add ../basenb origin/main`): **ok (295 checks, 0 failed,
0 skipped, 246s)** - `fast-base.log`, exit 0. Both with a scratch HOME.

A first head run reported 2 failures (`test-release-sign.lua`, `test-codemode-queue-timeout.lua`). Both are
timing-sensitive rows, both **passed standalone on head and on the base**, and neither is a file this
branch changed (`git diff --name-only origin/main..HEAD`). That run overlapped another mission running its
own `scripts/fast.sh` on this machine; the clean re-run above is 295/295. The failures are recorded rather
than hidden, and they did not reproduce.

`scripts/test-node-binaries.sh` is a separate, pre-existing red - proven on a base worktree - and it is not
a fast-path row (it is a `test.sh` gate row).

## SHOULD items — not done, with the reason

- `upgrade.sh` manifest lookup by 12-hex filename guess: the "candidate has no source checkout" case is
  `test-install-record.sh`'s shallow/absent cases; adding the mail-18/11 install shape needs a fixture with
  a manifest and no checkout, which is a larger test than this round allowed. Not claimed as done.
- Brief item 1, naming land branches by run id: item 25 landed next-free-from-ls-remote (a48a55a9), which
  still races with two simultaneous lands. Not changed this round.

## Texts to approve (verbatim)

1. `--release  a node installed FROM a release (no tree): fetch the published release and install it as a neighbour process` (4532be19)
2. `the ring names node <n> with mode <m>, and this coordinator sends only binary, release, tree` (c8373793)
3. `node release: the ring includes <n> in release mode, a node with no checkout, so this round builds the node release the tree travels in` (002f1c17)
4. `release_install: installed_but_unproven: pid <pid> runs <exe>, and this install is <expected>; the node is serving bytes this install does not hold` (4532be19)
5. `release_install: installed_but_unproven: the installed build names commit=<got>, this release is <commit>` (4532be19)
