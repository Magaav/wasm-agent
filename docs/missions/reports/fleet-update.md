# fleet-update: the five hand fixes from the node-7ddbfa98036a rollout

Mission: rolling out node-7ddbfa98036a on 21/11 needed five hand fixes on the fleet; each one is a code bug,
fixed here with a test that fails on the base, all verified on this node with scratch HOMEs and never against
the live fleet. Commits are local; nothing was pushed.

Base: `7ddbfa98` (branch `change/fleet-update`).

## The five fixes, each with its commit

| # | The hand fix | Commit | Test (fails on base) |
| --- | --- | --- | --- |
| 1 | deploy.sh step 0c ran a bare `node`, which the service PATH does not carry, so a remote `wa update <node> --binary` refused with "line 436: node: command not found" | `44606926` | `scripts/test-node-runtime.sh` (16 checks; 6 fail on base) |
| 2 | nothing in wa wrote a trusted-keys file, so a hand-written one without the header refused every release as `release_unsigned_or_forged` | `0b8c684d` | `scripts/test-release-trust.sh` (30 checks) + 5 Rust cases; 6 fail on base |
| 3 | a verified release asset kept its 0644 mode, so upgrade.sh refused it ("no new binary to install") and the tree-less install path never worked end to end | `1223790f` | `scripts/test-release-install-exec.sh` (15 checks; 8 fail on base) |
| 4 | `wa update <node> --binary` answered `no_runtime_tree`, and `--check` named neither the stale record nor the release path | `9cb08c3c` | `scripts/test-update-treeless.lua` (10 checks; 8 fail on base) |
| 5 | `wa land` as a systemd user unit stopped at publish for ever, and `--resume` stopped at the same check even when the release existed | `cb1c7027` | `scripts/test-land.lua` (case 27 re-aimed + new case 27b; land ok, 476 checks) |

## Where each test is wired

- `scripts/test-node-runtime.sh` - `scripts/test.sh`, beside `test-deploy-runtime-recheck.sh`
- `scripts/test-release-trust.sh` - `scripts/test.sh`, beside `test-release.lua`
- `scripts/test-release-install-exec.sh` - `scripts/test.sh`, beside `test-deploy-node-binaries.sh`
- `scripts/test-update-treeless.lua` - `scripts/test.sh`, beside `test-update-release.lua`
- item 5's cases live in the existing `scripts/test-land.lua` row

## Base discrimination (rule 16)

Each shell/Lua test was run against a separate worktree of `7ddbfa98` at `/tmp/fu/base` (never
`git stash`): 1 six failures, 2 six, 3 eight, 4 eight, 5 the old order fails for the new case. The Rust
trust-key cases are `#[test]` bodies inside `release.rs`; they cannot exist on the base (no
`fn trust_key`), which `scripts/test-discriminates.sh` classifies as `new-symbol`.

## Premises measured, and one that was stale

- Confirmed: `deploy.sh:436` bare `node`; `upgrade.sh:113` "no new binary to install";
  `node-binaries.sh` had no `chmod`; `remote_update.lua:539` `no_runtime_tree`;
  `update.lua:706` "no tree or release record"; `land.lua` `publish_needs_credentials`.
- **Stale**: the brief says the resolver is used by "every deploy.sh/upgrade.sh call of node".
  `scripts/upgrade.sh` makes **no** node call at all (measured: not one `node <path>` invocation). The
  resolver is wired into `deploy.sh` and the remote-update wrapper; the test asserts upgrade.sh has no
  bare node call, so a future one cannot bypass the resolver.

## A defect found on the way (outside the five)

`scripts/lib/turn-guard.sh` matched the substring " serve " in an ancestor's whole command line, so a
`wa chat` whose mission text said "serve operation" was read as a node turn and every deploy from it
refused with "cannot deploy from a turn running on the node it would replace". Fixed in `44606926` by
parsing the first non-option token; covered by `scripts/test-node-runtime.sh`.

## Texts to approve

1. `deploy: refused(node_runtime_missing): no node (or nodejs) was found, so a step that runs node cannot run. Looked on PATH (<PATH>), then in: <dirs>. Install Node 18 or newer, or name one with WA_NODE_BIN=<path>`
2. `WA_NODE_BIN names <path>, which is not an executable file, and a named node is never replaced by a search`
3. `deploy: refused(node_runtime_lib_missing): scripts/lib/node-runtime.sh is not beside this deploy, ... Nothing was built and nothing was installed.`
4. `release trust-key: trusted <id> in <path> (<n> key(s), read back through the same parser a release verification uses)`
5. `release trust-key: retired <id> in <path> (<n> key(s), read back through the same parser a release verification uses)`
6. `release_trust_refused: <path> is not a trust file this node can read: <why>` (and `release_trust_conflict`, `release_trust_unknown_key`, `release_trust_bad_key`, `release_trust_not_applied`)
7. `wa release trust-key: <node> refused (<code>): <why>` / `<node>: <the peer own sentence>`
8. `node_not_executable: <file> could not be made executable`
9. `this node has no tree to compare with origin/main, and its install record is not one the release updater recognises (via=linux-bootstrap would be). installed.txt says <fields>; the file was last written <stamp>.`
10. `move it with the release path, which needs no tree: wa update --release <commit> ... or wa update <this-node> --release from a master ...`
11. `next: this node is installed from a release: ask for it with mode="release" (wa update <node> --release) ...`
12. `release <tag> exists on GitHub with no assets, so it is not the release a node installs` (`publish_release_incomplete`)
13. `this is the keyring cause: gh auth status reads a token from the desktop keyring, and a systemd user unit has no session bus to unlock it ... Publish as an operator: git fetch ... PUBLISH.sh ... - or give the unit a token it can read (GH_TOKEN in its environment), then wa land --resume`
14. `this node has no tree, so a binary install IS the release install (the published release, fetched and proved as a neighbour process)`

## What was verified, and what was not

Verified on this node (avell): the three shell tests pass on the branch and fail on the base; the Rust release
module's 19 tests pass; `test-land.lua` reports `land ok (476 checks)`; item 4's row passes exactly as
`test.sh` runs it. Not verified: a full `scripts/test.sh` run (it needs a `flock -o` slot and
hours), a real release publish, and any fleet node - by rule 13 nothing here touched a live node.
