# `wa land`: the landing pipeline as one resumable machine

One command takes `READY <branch> <sha>` lines to installed nodes. It is a state machine with a journal,
not a script: each step names its command, runs it under the cpu/io weight a landing deserves, keeps the
output as evidence, and writes what it did before it moves on.

```bash
wa land --ready                     # every branch with a READY line in the ready box
wa land --branches change/a,change/b
wa land --dry-run                   # the plan and every command; changes nothing
wa land --no-deploy                 # land and publish, deploy nothing
wa land --resume                    # continue the newest unfinished run at its failed step
wa land --run <id> --resume
wa land --rollback                  # put every node's kept pair back (reverse ring order)
wa land status [--run <id>]         # the journal, read-only
wa land ready change/x <sha>        # record an agent's READY line
```

Code: `lua/core/land.lua` (the machine), `lua/core/remote_update.lua` (the per-node verb it calls).
Test: `scripts/test-land.lua` (119 checks, ~75 s, real git, scripted nodes).

## The steps, in order

| step | what it does | refuses by name when |
| --- | --- | --- |
| `collect` | fetch the incoming repository, resolve each branch and its tip, record the base | `no_repository`, `no_main`, `branch_unknown`, `ready_sha_moved`, `ready_empty` |
| `review` | run `scripts/review-branch.mjs` on each branch **before** the merge; findings are reported, never blocking | `skipped` + a TODO when the reviewer is not on main |
| `merge` | a fresh worktree (`land<N>/final`) from the base, `merge-tree --write-tree` first, then one `--no-ff` merge per branch | `merge_conflict`, `merge_failed`, `worktree_failed` |
| `gate` | the weighted checks, one run each, a failing check re-run **once alone** | `gate_failed`, `gate_vacuous`, `flaky_under_load` (stops, never green) |
| `push` | the landed tip to the incoming repository, read back | `push_failed`, `push_not_readback` |
| `main` | fast-forward the source of truth onto the landed tip, read back | `main_not_fast_forward`, `main_push_needs_credentials`, `main_not_readback` |
| `artifacts` | `scripts/publish-artifacts-branch.sh`, then hold the shipped ref to every file its `PUBLISH.sh` names | `artifacts_failed`, `artifacts_incomplete`, `artifacts_wrong_commit` |
| `publish` | sign (when the signer is on main), then the release | `publish_needs_credentials`, `publish_failed`, `signing_failed` |
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
assumed because `nice -n -19` needs a privilege an ordinary user does not have:

```
systemd-run --user --scope --quiet -p CPUWeight=10000 -p IOWeight=10000 -- bash -lc <check>
nice -n -19 ionice -c 1 -n 0 bash -lc <check>
nice -n -19 bash -lc <check>
ionice -c 1 -n 0 bash -lc <check>
<check>                                    # nothing applied, and the journal says so
```

The decorator that was used is recorded (`gate_weight`), because "weighted" that silently fell back to
nothing is not a measurement.

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

## The two conditional channels

Neither `change/sign` nor `change/reviewer` is on main, so both are detected, never assumed:

* **sign** - `scripts/publish-sign.sh` in the landed tree. Absent: the release is recorded
  `signed=false` and the journal carries a TODO naming the file and `scripts/test-land.lua`'s signing case,
  which stands a fixture signer in a tree and asserts the publish step runs it.
* **reviewer** - `scripts/review-branch.mjs` at the base commit; it reviews a branch before that branch is
  merged, so a reviewer that arrived with the branch could never have looked at it. Absent: the step is
  `skipped` with a TODO naming the same test.

## What this node can and cannot do

`wa land` stops, by name, at the step this machine cannot perform. On a node with no GitHub credential
that is `main` (`main_push_needs_credentials`), and the answer carries the exact command for the node that
holds one; on a node with no `gh` it is `publish` (`publish_needs_credentials`). Neither is reported as
done, and neither is worked around by granting this node a token it should not have.
