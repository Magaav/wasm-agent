# `wa land`: the landing pipeline as one resumable machine

One command takes `READY <branch> <sha>` lines to installed nodes. It is a state machine with a journal,
not a script: each step names its command, runs it under the cpu/io weight a landing deserves, keeps the
output as evidence, and writes what it did before it moves on.

```bash
wa land --ready                     # every branch with a READY line in the ready box
wa land --branches change/a,change/b
wa land --dry-run                   # the plan and every command; changes nothing
wa land --no-deploy                 # land and publish, deploy nothing
wa land --signer <node>|local       # where the release is signed (default: the node whose
                                    # WA_VAULT_ADMIN_URL is set - the vault's listener is loopback)
wa land --resume                    # continue the newest unfinished run at its failed step
wa land --run <id> --resume
wa land --rollback                  # put every node's kept pair back (reverse ring order)
wa land status [--run <id>]         # the journal, read-only
wa land ready change/x <sha>        # record an agent's READY line
```

Code: `lua/core/land.lua` (the machine), `lua/core/remote_update.lua` (the per-node verb it calls),
`scripts/sign-release.sh` (the one command that signs a release). Test: `scripts/test-land.lua` (145 checks,
~40 s, real git, a real scratch wa-vault, scripted nodes).

## The steps, in order

| step | what it does | refuses by name when |
| --- | --- | --- |
| `collect` | fetch the incoming repository, resolve each branch and its tip, record the base | `no_repository`, `no_main`, `branch_unknown`, `ready_sha_moved`, `ready_empty` |
| `review` | run `scripts/review-branch.mjs` on each branch **before** the merge; findings are reported, never blocking | `skipped` + a TODO when the reviewer is not on main |
| `merge` | a fresh worktree (`land<N>/final`) from the base, `merge-tree --write-tree` first, then one `--no-ff` merge per branch | `merge_conflict`, `merge_failed`, `worktree_failed` |
| `gate` | the weighted checks, one run each, a failing check re-run **once alone** | `gate_failed`, `gate_vacuous`, `flaky_under_load` (stops, never green) |
| `push` | the landed tip to the incoming repository, read back | `push_failed`, `push_not_readback` |
| `main` | fast-forward the source of truth onto the landed tip, read back | `main_not_fast_forward`, `main_push_needs_credentials`, `main_not_readback` |
| `artifacts` | build the release set (`publish-node-binaries.sh` with `WA_RELEASE_SIGN_DEFER=1`) and verify every payload against the manifest's pins | `artifacts_failed`, `artifacts_not_pinned`, `artifacts_wrong_commit` |
| `sign` | `scripts/sign-release.sh` on the host that can reach wa-vault, the signature handed back, then verified against the trusted keys of the landed tree | `signer_unknown`, `release_not_signed`, `release_key_not_trusted` |
| `ship` | `scripts/publish-artifacts-branch.sh` from the built set, then hold the shipped ref to every file its `PUBLISH.sh` names, signature included | `ship_unsigned`, `ship_incomplete`, `ship_wrong_commit` |
| `publish` | the release itself, from the shipped ref | `publish_unsigned`, `publish_needs_credentials`, `publish_failed` |
| `deploy` | the ring, in order, stopping at the first node that is not installed | `deploy_refused`, `deploy_failed` |
| `report` | one summary written to a file and printed; runs even when the machine stopped | - |

`report` is the only step that always runs: a stop without a summary is what this module exists to end.

## Resumable, and what it refuses to repeat

The journal is `<config>/land/<run>/journal.json`; each step's evidence is
`<config>/land/<run>/evidence/<step>.log`. `wa land --resume` starts at the first step that is not `done`.

A push, a main fast-forward and a publish recorded done are **never repeated**. Each is also read back
before it is trusted: a remote that already has the sha, or a release tag that already exists, is recorded
done without doing it again - so a crash between the effect and the journal line is not a second push.

A `running` step whose process died is run again from the start. The steps are ordered so that is safe:
the merge recreates a missing worktree from the base, the gate is a measurement, and the effects that are
not idempotent carry their own guard (above).

## The gate, and `flaky under load`

The checks are data (`M.DEFAULT_CHECKS`): `scripts/fast.sh`, the code-mode component seam
(`scripts/test-codemode-component.sh`), the code-mode Rust tests (`cargo test -p wa-capabilities
codemode`), the WhatsApp component's own crate (`cargo test --lib` in `rust/components/wa-whatsapp`) and
`scripts/sync-prompt-docs.sh --check`. A row may declare `min_tests`: a `cargo test` whose filter matches
nothing exits 0 and proves nothing, and that is refused as `gate_vacuous`.

**Weight.** Concurrent agents are what made checks flaky - a fork that fails under load reads as a red
check. The gate therefore runs under the highest weight this machine actually grants, probed rather than
assumed because `nice -n -19` needs a privilege an ordinary user does not have:```
systemd-run --user --scope --quiet -p CPUWeight=10000 -p IOWeight=10000 -- bash -lc <check>
nice -n -19 ionice -c 1 -n 0 bash -lc <check>
nice -n -19 bash -lc <check>
ionice -c 1 -n 0 bash -lc <check>
<check>                                    # nothing applied, and the journal says so
```

The decorator that was used is recorded (`gate_weight`), because "weighted" that silently fell back to
nothing is not a measurement.

`fast.sh` builds the binary of the tree it is run in, and build output is one island per worktree
(`docs/ONEROOT.md`), so the FIRST landing of a run pays a cold build there and `--resume` - which reuses
the same worktree - is incremental. That is the same cost the hand-run pipeline paid with its
`target-land`, `target-land2`, ... directories; naming one `CARGO_TARGET_DIR` for every landing would be
cheaper and is deliberately not done (a shared target dir made cargo reuse another tree's library,
measured 12/11).

**A failing check is re-run once, alone.** If it passes alone the landing still STOPS and the journal
records `flaky under load: <name>`; a human decides. Nothing here turns a flaky check green.

## The deploy ring

| node | mode | why |
| --- | --- | --- |
| `work` | tree | the working node: its own Sentinel deploys its tree |
| `mail` | tree | a tree install over its own session, with no SSH hand steps |
| `nextcloud` | **binary** | aarch64 with no toolchain: the published release, never a build |
| `openclaw` | tree | **last**: it holds the WhatsApp account and the relay |

Default order and modes live in `lua/core/land.lua` (`M.RING`); an override is
`<config>/land/ring.json` (`{"nodes":[{"node":"work","mode":"tree"}]}`) or `--ring
work:tree,nextcloud:binary`.

Each node is asked to update **itself** (`wa update <node>`, `lua/core/remote_update.lua`): this machine
only asks and reads back. `queued` is never reported as installed; a node counts only when its own record
says `installed` with the requested commit, and the first node that is not installed stops the ring.

The mode is not decoration. `binary` deploys the published release through the node's own `deploy.sh` with
`WA_DEPLOY_PREBUILT_ONLY=1`, which refuses with `refused(no_prebuilt_binary)` instead of starting a build
that node can never finish - the hand-run "upnode" procedure, folded into the verb.

## Rollback

Every tree install keeps the pair it replaces in `<install>/rollback/` (`scripts/deploy.sh`), and a release
install keeps the same pair in `<install>/.prev` (`scripts/linux/bootstrap.sh`). `wa update <node>
--rollback` runs `scripts/rollback-node.sh` through that node's own Sentinel, out of a run:

```
bash scripts/rollback-node.sh [--install DIR] [--from DIR] [--reason TEXT] [--no-restart]
```

It restores the two binaries by rename, proves `wa --version` runs, rewrites `installed.txt` with
`rolled_back_utc=` and `rollback_of=`, and restarts the supervisor. It needs no tree, no network and no
release feed, because the node it is about may be the reason it is needed. `wa land --rollback` walks the
whole ring in reverse.

## Signing, and where it runs

A release is signed or it is not published. `change/sign` is on main: the publisher signs `SHA256SUMS` with
wa-vault's `release-signing` key (ed25519, the key never leaves the vault), every node verifies the signature
before it installs, and `scripts/publish-artifacts-branch.sh` refuses a set without `SHA256SUMS` **and**
`SHA256SUMS.sig` (`release_not_signed`, exit 6) and refuses one whose signature does not verify
(`release_signature_invalid`).

The constraint the three steps exist for: **the vault's admin listener answers only where the vault runs** -
measured 13/11, `127.0.0.1:8801` on the operator's laptop, loopback. So the host that builds a release is not
always the host that can sign it:

1. `artifacts` builds with `WA_RELEASE_SIGN_DEFER=1`. The publisher writes the payloads, the manifest and
   `SHA256SUMS`, does **not** sign, refuses `--publish`, and says so in a line; if a signature is already
   there it verifies it instead.
2. `sign` runs `scripts/sign-release.sh <SHA256SUMS>` where the vault is reachable and hands the signature
   back over the fabric (the sums travel as base64, the signature comes back the same way; the admin token is
   read on the signing host and never travels). The receiver then verifies it - `. scripts/lib/release-signing.sh;
   wa_release_verify_sums <dir>` - against `config/release-keys.txt` of the landed tree. A key this project
   does not trust is refused (`release_key_not_trusted`), and the answer names the file to add it to.
3. `ship` refuses to build a commit without the two signed-sums files, and re-verifies them.

Which host signs, in order (nothing guesses):

| choice | how |
| --- | --- |
| explicit | `wa land --signer <node>` (or `--signer local`) |
| recorded | `<config>/land/signer.json`, `{"node":"laptop"}` or `{"local":true}` |
| default | the node that sets `WA_VAULT_ADMIN_URL` / `WASM_AGENT_VAULT_OPERATOR_URL` - this node if it is the one, else the first peer the fabric lists whose `printenv` of those two names answers |
| none | `signer_unknown`, naming both knobs and the vault's admin page |

A signing node needs `scripts/sign-release.sh` beside its binary (shipped by `deploy.sh`); a node without it
answers `signer_script_missing` rather than an unsigned release. The vault's own routes and the key's
rotation are in [VAULT.md](VAULT.md) and [INSTALL.md](INSTALL.md), "Signed releases".

## The reviewer channel

`change/reviewer` is not on main, so it is detected, never assumed: `scripts/review-branch.mjs` at the base
commit (it reviews a branch BEFORE that branch is merged, so a reviewer that arrived with the branch could
never have looked at it). Absent: the step is `skipped` with a TODO naming the file and the test that turns
it on. Its findings are recorded in the report and never block a landing.

## What this node can and cannot do

`wa land` stops, by name, at the step this machine cannot perform. On a node with no GitHub credential
that is `main` (`main_push_needs_credentials`), and the answer carries the exact command for the node that
holds one; on a node with no `gh` it is `publish` (`publish_needs_credentials`). Neither is reported as
done, and neither is worked around by granting this node a token it should not have.
