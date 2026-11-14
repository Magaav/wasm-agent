# `wa land`: the landing pipeline as one resumable machine

One command takes `READY <branch> <sha>` lines to installed nodes. It is a state machine with a journal,
not a script: each step names its command, runs it under the cpu/io weight a landing deserves, keeps the
output as evidence, and writes what it did before it moves on.

```bash
wa land --ready                     # every branch with a READY line in the ready box
wa land --branches change/a,change/b
wa land --dry-run                   # the plan (path, steps run or skipped, expected cost) and every command
wa land --full                      # ignore the plan: run every step, even the ones this round does not need
wa land --canary <node> --account <node>   # which node goes first (default work) and last (default openclaw)
wa land --no-deploy                 # land and publish, deploy nothing
wa land --signer <node>|local       # where the release is signed (default: the node whose
                                    # WA_VAULT_ADMIN_URL is set - the vault's listener is loopback)
wa land --resume                    # continue the newest unfinished run at its failed step
wa land --run <id> --resume
wa land --rollback                  # put every node's kept pair back (reverse ring order)
wa land status [--run <id>]         # the journal, read-only
wa land ready change/x <sha>        # record an agent's READY line
```

Code: `lua/core/land.lua` (the machine, the plan and the ring's waves), `lua/core/remote_update.lua` (the
per-node verb it calls), `scripts/sign-release.sh` (the one command that signs a release),
`scripts/lib/land-classify.sh` (which kind of change a path is - the one definition, over `wa_compiled_input`),
`scripts/lib/fast-rows.sh` (which Lua rows a narrowed run may execute), `scripts/publish-lua-tree.sh` (the
record a Lua-only round signs). Tests: `scripts/test-land.lua` (197 checks, real git, a real scratch wa-vault,
scripted nodes - including the four paths, the gate's narrowing, the deploy's waves and the cost report),
`scripts/test-land-signing.sh` (build -> sign -> re-run the publisher -> publish, without a hand-frozen build)
and `scripts/test-fast-rows.sh` (the narrowing's three rules).

## The steps, in order

| step | what it does | refuses by name when |
| --- | --- | --- |
| `collect` | fetch the incoming repository, resolve each branch and its tip, record the base | `no_repository`, `no_main`, `branch_unknown`, `ready_sha_moved`, `ready_empty` |
| `plan` | classify what changed and decide the round's path: which steps run, which steps are skipped **and why**, what the gate will check, and what the round should cost (the journal's own medians) | `plan_no_changes` (nothing to land) |
| `review` | run the landing reviewer (`wa eval reviewer`, lua/core/harness_evaluator_reviewer.lua) on each branch **before** the merge: one background process per branch, joined by `report`; findings are reported, never blocking | `skipped` with `review unavailable: <reason>` when the reviewer cannot run (never a silent skip) |
| `merge` | a fresh worktree (`land<N>/final`) from the base, `merge-tree --write-tree` first, then one `--no-ff` merge per branch | `merge_conflict`, `merge_failed`, `worktree_failed` |
| `gate` | the weighted checks, one run each, a failing check re-run **once alone** | `gate_failed`, `gate_vacuous`, `flaky_under_load` (stops, never green) |
| `push` | the landed tip to the incoming repository, read back | `push_failed`, `push_not_readback` |
| `main` | fast-forward the source of truth onto the landed tip, read back | `main_not_fast_forward`, `main_push_needs_credentials`, `main_not_readback` |
| `artifacts` | by path: a **Lua-tree record** (`publish-lua-tree.sh`), the **components bundle** (`publish-components.sh`), or the node release (`publish-node-binaries.sh` with `WA_RELEASE_SIGN_DEFER=1`, every payload verified against the manifest's pins) | `artifacts_failed`, `artifacts_not_pinned`, `artifacts_wrong_commit` |
| `sign` | `scripts/sign-release.sh` on the host that can reach wa-vault, the signature handed back, then verified against the trusted keys of the landed tree | `signer_unknown`, `release_not_signed`, `release_key_not_trusted` |
| `ship` | `scripts/publish-artifacts-branch.sh` from the built set, then hold the shipped ref to every file its `PUBLISH.sh` names, signature included | `ship_unsigned`, `ship_incomplete`, `ship_wrong_commit` |
| `publish` | the release itself, from the shipped ref | `publish_unsigned`, `publish_needs_credentials`, `publish_failed` |
| `deploy` | the ring in **waves**: the canary alone, then the other non-account nodes together, then the account node last; stops at the first node that is not installed | `deploy_refused`, `deploy_failed` |
| `report` | one summary written to a file and printed, with the path, the per-step time, the total and the journal's average; runs even when the machine stopped | - |

`report` is the only step that always runs: a stop without a summary is what this module exists to end.

## The plan: the cheapest safe path, decided from what changed

Operator, 13/11: *"it should automatically know best compile time and take best path"*. A round cost ~40
minutes every time (measured by hand: merge + code-mode build 3-5 min, gate 4-6, a cross-build of both Linux
targets 7-9 **even when no compiled input had changed**, sign+publish 2-5, four deploys in series 15-20), and
most of that day's branches were Lua-only. So the first thing a round does after `collect` is `plan`: it
classifies every path the branches introduce and takes the cheapest path that is SAFE for them.

```
land: plan: 7 path(s) changed -> lua-scripts-only
land:   compiled 0, component 0, lua 5, docs 2 (classified by land-classify.sh)
land:   gate: fast prompt-docs over 18 Lua row(s) of the suite
land:   collect   run  runs on every path
land:   plan      run  runs on every path
land:   artifacts run  Lua tree record (manifest + SHA256SUMS over the shipped Lua tree): no cross-build, no node release
land:   sign      run  signs the Lua-tree record's SHA256SUMS (the vault's host, as always)
land:   ship      skip a Lua-only round ships no node release: each node installs the tree with its own deploy, which keeps the installed binary
land:   publish   skip a Lua-only round publishes no node release; the signed record is the round's evidence and the deploy is the transport
land:   deploy    run  the ring, in order: the nodes take the Lua tree and keep their binary (the deploy's Lua fast path)
land:   expected 18m20s (median of 4 finished run(s) on this path)
```

| path | artifacts | sign | ship | publish | deploy |
| --- | --- | --- | --- | --- | --- |
| `docs-only` | skipped | skip | skip | skip | skip (a document is not loaded at runtime) |
| `lua-scripts-only` | Lua-tree record | run | skip | skip | the tree, binary kept (the deploy's Lua fast path) |
| `components` | components bundle + repin check | skip | skip | skip | the repinned components |
| `compiled` | node release | run | run | run | run |

Three properties, deliberately:

- **The classification is not spelled here.** `scripts/lib/land-classify.sh` calls `wa_compiled_input`
  (`scripts/lib/node-binaries.sh`), the same function the deploy's Lua fast path, the release's digest fallback
  and the publisher use - so "this round needs no build" and "that release is this commit's binary" cannot
  disagree about the same file. It adds only the two categories the planner needs on top: `component`
  (`rust/components/**`, `components.lock`) and `docs` (markdown, skills, reviews). A shared crate a component
  uses but the node also compiles stays `compiled`.
- **A skipped step is recorded as `skipped` with its reason**, in the journal and in the report. Nothing is
  silently omitted, and nothing is reported done. `--full` is the explicit escape hatch that runs every step.
- **A tree without the classifier takes the full path** (`classifier: missing`), because a plan that guessed
  would be a plan that skips work nobody proved unnecessary.

### The gate runs what the change touches - never less than the core

The gate is narrowed by the same plan: `fast` and `prompt-docs` always run; the code-mode checks are added
when a code-mode path changed, the WhatsApp crate's tests when its crate changed; and `scripts/fast.sh` gets a
`WA_FAST_ROWS` list of the Lua rows the changed modules touch (a row whose own text mentions the module,
proved by `grep` in the tree, not guessed from a name). A change no row maps to runs the whole suite.

`scripts/lib/fast-rows.sh` is where a narrowing is stopped from meaning less than a full run: the always-on
core rows are added whatever the request says (the row-environment probe, and `scripts/test-land.lua`), the
contract checks inside `scripts/fast.sh` are not narrowable at all, an unknown row is a refusal by name, and an
empty request is refused (a plan that maps nothing asks for the whole suite, never for silence).

**A failing row is still re-run once alone** under the machine's highest weight, and a row that passes alone
is reported `flaky under load: <name>` and **still stops the landing** - narrowing changes what runs, never
what a failure means.

### Signing: the identity is produced once per round

`built_utc`/`build_seconds` are recorded in `$OUT/build-stamp.txt` for a (commit, target set) and reused, and
`SHA256SUMS` is reused byte-for-byte when it already names the set's files; `--from` takes the stamp from the
incoming manifest and leaves the manifest untouched when it already carries the commit's `compiled_inputs`.
That is the 13/11 fix: the ship step re-runs the publisher after the vault host signed, and before this the
re-run rewrote the manifest (a new `built_utc`), which rewrote `SHA256SUMS`, which left the signature about
other bytes - the operator had to freeze the build by hand and publish with `--from`. Now a re-run after
signing is byte-identical, and a set whose payloads moved after it was signed is refused `signature_stale`
(every `scripts/publish-node-binaries.sh` re-run, and by `scripts/publish-lua-tree.sh` too).

### The deploy ring goes in waves

The canary (default `work`) is deployed first and **alone**; then the other non-account nodes go **together**;
then the account node (`openclaw`, which holds the WhatsApp account and the relay) goes **last**. The first
node that is not `installed` stops the round: nodes in later waves are recorded `not_attempted` with the reason,
and the nodes already asked in the failing wave keep their own recorded outcome (a parallel wave cannot un-ask
a request, and pretending otherwise would be a lie in the journal). `--canary <node>` and `--account <node>`
move the two ends; a ring that names neither still gets them (the first non-account node becomes the canary, and
the plan says it defaulted).

### What a round cost

The report ends with a `## cost` table: the path taken, every step's seconds, the total, what the plan
expected, and the average of the finished runs in the journal. A number nobody compares is a number nobody can
improve; the point of the plan is that "~40 minutes every round" became a measurement per round, per path.

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

## The reviewer

`wa land` runs the reviewer that landed - `wa eval reviewer` (lua/core/harness_evaluator_reviewer.lua) - on
every branch of the round, BEFORE that branch is merged, through that door and no other. There is no second
reviewer and no wrapper script: the step starts `<the landing's own binary> eval reviewer <branch> --repo
<repo> --base <base> [--brief <file>] --json <file>` as a process of its own, one per branch, and joins them
in `report`.

- **Before the merge, beside the gate.** Each review is a child process started in the `review` step and
  joined at the end, so a branch's review runs while the merge, the gate, the release and the deploy run. The
  landing does not pay the review's minutes; it pays the join at the report, bounded by `M.REVIEW_WAIT`
  (900 s), and says "still running" by name if a review outlives that.
- **The answer is a file, not a sentence.** `--json <file>` is written by the reviewer for both outcomes -
  `ok` with the findings, or `ok: false` with the reason - so a landing never has to parse prose, and a review
  that answered about another commit is not mistaken for one of this branch's.
- **Never blocking.** Findings go into the journal (`journal.review`), the report (`## review`, with each
  review's own answer and its id, so a finding can be marked later with `wa eval reviewer mark <id>#<n>`) and
  the console. Nothing in the step, the join or the report can stop a landing.
- **One opt-out.** `reviewer = off` in the node's config file (or `WA_REVIEWER=off`) is read through the
  reviewer's own module; the step is then `skipped` with the switch and its value, and no review starts.
- **A failure is a row.** A reviewer that cannot start, exits non-zero, answers about another commit or never
  answers is recorded as `review unavailable: <reason>` in the journal, the step and the report - never as a
  silent skip and never as "no findings".
- **The brief travels.** `wa land ready <branch> <sha> [--brief <file>]` puts the operator's brief on the
  ready line (`READY <branch> <sha> brief=<file>`), `collect` reads it, and `review` hands it to the reviewer,
  so a branch is reviewed against what it was for and not only against its diff.

## What this node can and cannot do

`wa land` stops, by name, at the step this machine cannot perform. On a node with no GitHub credential
that is `main` (`main_push_needs_credentials`), and the answer carries the exact command for the node that
holds one; on a node with no `gh` it is `publish` (`publish_needs_credentials`). Neither is reported as
done, and neither is worked around by granting this node a token it should not have.
