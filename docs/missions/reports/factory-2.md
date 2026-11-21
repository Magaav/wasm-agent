# factory-2 - the release loop as its own command

Base: `b2730ed4` (change/factory-4's tip, which contains factory-1 and factory-3). Local commits on
`change/factory-2`; nothing pushed, nothing landed, nothing released, no node touched.

The brief's section 1 (local install inside `wa land`) was already done differently (scripts/drive.sh) and its
"Proof: run for real" was cancelled by the orchestrator. **No real `wa release` has ever run.**

## The command the orchestrator runs to release main

    wa release cut --dry-run        # first: the plan and the three readiness lines; changes nothing
    wa release cut                  # the release: full gate -> artifacts -> sign -> ship -> publish -> deploy ring
    wa release cut --run <id> --resume     # after a stop (the stop prints this exact line)

from a desktop terminal (so `gh` can read the keyring), in the checkout, with the same environment a landing
uses for signing. `--no-deploy`, `--signer <node|local>`, `--account <node>`, `--ring` are `wa land`'s own flags.
`wa land --release ...` is the same door.

`wa release cut` needs a binary built from this branch: the INSTALLED binary answers `release_unknown_verb: 'cut'`
in Rust before Lua boots (rust/wa-host/src/release.rs). So: land this mission, install main on the laptop, then
release.

## What changed, per commit

| commit | what |
|---|---|
| `2e0459fc` | items 1, 2 and 3 together (see "Deviations"): `wa release cut`, the preconditions, the `--until main` result line, test-land cases 46-49 |
| `94b8abb2` | item 4b: `scripts/prune-kept-binaries.sh` + `scripts/test-prune-kept-binaries.sh`, wired into `scripts/fast.sh` as `prune-kept-binaries` (after `deploy-prune`) |
| (this commit) | `docs/LAND.md` section, case 49 also exercises the deploy step of a release run, this report |

### 1. `wa release cut` (lua/core/land.lua, lua/core/init.lua, rust/wa-host/src/release.rs)

What the code showed first:
- `wa release <verb>` is answered by the BINARY (`release.rs::run`): `verify`, `trust-key`, and every other word
  is `release_unknown_verb` exit 2; a bare `wa release` prints usage and exits 2. Only `--node` falls through to
  Lua (lua/core/release_trust.lua). So `release` needed a sub-verb, and one Rust line: `cut` returns `None`
  (not mine), and lua/core/init.lua hands `release cut` to `land.release_cli`. No second dispatcher.
- artifacts/sign/ship/publish/deploy read `run.tree` (a worktree), `journal.tree_commit`, `journal.artifacts`,
  and deploy reads `journal.main_sha or tree_commit`. None reads the landing branch. The merge step is what
  creates the worktree, so a release that skips merge needs its tree from somewhere else.

Design as built:
- `options.release` (a remembered start option, so `--run <id> --resume` knows the run is a release).
- `collect` fetches as always, takes no branch, REFUSES `release_main_not_on_origin` when the incoming main is
  ahead of origin/main (a half-finished landing), and makes a DETACHED worktree of origin/main's tip
  (`M.release_tree`): `tree_commit` = main's commit, `tree_sha` = its tree object, `journal.release = true`.
- `plan`: full path, every check, node release; `review`, `merge`, `push`, `main` are `skipped` with
  "nothing to land (a release is cut from main's tip)".
- `gate`: unchanged code. Never narrowed (`plan.full`), and factory-1's keep by tree object applies, so a check
  that already passed on this tree with the same command is kept (proved by case 46b).
  factory-3's `main-health.json` is NOT used as a kept verdict: it records the commit, not the tree object, and
  it is `scripts/fast.sh` only - it cannot stand for the gate's other checks. A release therefore pays the full
  gate once unless an earlier run of the same full gate on the same tree is in the journals.
- artifacts, sign, ship, publish, deploy, report: unchanged code.
- It pushes no landing branch and never pushes main. A stop prints
  `continue with: wa release cut --run <id> --resume   (main and every landing are untouched)`.
- Two queues: a bare `wa land --resume` skips release runs, a bare `wa release cut --resume` skips landings.
- `wa release cut --branches x` / `--ready` / `--rollback` is refused `release_takes_no_branch`.

### 2. Preconditions (`M.release_checks`, `M.release_preflight`)

Asked BEFORE the journal is written, before the fetch and the build; a resume does not ask again for a step
already settled. Each row is `{ready, why, next, error}`; `M.release_checks.<name>` is a plain field, so a test
replaces it.
- **signing**: `M.signer(options)` (the sign step's own resolver). A named node is asked for its vault URL
  (`M.probes_vault`, the same signed call the sign step makes). This node: one shell probe with the URL and
  token rule of scripts/lib/release-signing.sh (URL or 127.0.0.1:8801; `WA_VAULT_ADMIN_TOKEN` or a readable
  `WA_VAULT_ADMIN_TOKEN_FILE`), then `curl --max-time 5` to the admin listener. Neither value is printed.
- **publishing**: the publish step's own question (`command -v gh && gh auth status`), here or on `--account`.
- **ancestry** (release-ancestry mission): refuses a SHALLOW checkout (`publish-node-binaries.sh` would refuse
  `ancestry_window_unknown` only after the build), and refuses when origin/main does not contain the last
  release this machine's journals record as published.
- `--dry-run` prints the plan and one line per check, writes nothing, exits 0 even when not ready.

### 3. `--until main` is the landing

Measured: a run stopped at `--until main` already exits 0 with result `stopped_at_until`, `stopped_at = main`,
is excluded from a bare `--resume`, and refuses a by-name resume without a boundary. Added: the output line
`land: landed <sha> on main - the landing is complete ...`. Case 49 proves a later release runs on its own run
id, releases that main, and leaves the landing's journal as it was.

**Decision for the owner - should `wa land` stop after main by default?** Not changed. What would break:
- any caller of `wa land --branches X [--no-deploy]` that expects a release at the end gets none, silently
  (exit 0). scripts/drive.sh and ~/Work/missions/preflight.sh already pass `--until`, so they are unaffected;
  the orchestrator's hand recipe and notes that say "land = release" are;
- test-land.lua's cases 2, 6, 24, 26, 28, 29-32 land through to publish/deploy and would need `--through`;
- result name: today a landing that ends at main is `stopped_at_until`, not `done`. If the default flips, the
  clean form is result `done` with artifacts..deploy `skipped: local loop`, and a flag (`--release`-style
  "and release") for the old behaviour. That is a small change (the loop in `M.run`), best done as its own
  landing after `wa release cut` has run for real once.

### 4. Rollback and pruning

- **Rollback already exists**: `scripts/rollback-node.sh` (installed as `~/.local/bin/scripts/rollback-node.sh`).
  It restores the pair from `<install>/rollback/` (written by `scripts/deploy.sh`, which is what drive.sh's
  install runs), swaps `lua-core.prev` back with it, restarts, and is done only when the running pid's exe IS
  the restored file. I wrote no second one. `bash scripts/test-rollback-verify.sh` passes here (scratch install).
  Read-only look at `~/.local/bin`: `rollback/wa` + `rollback/kept.txt` (21/11 18:36) and `lua-core.prev` exist,
  so the one command is `bash ~/wasm-agent/checkout/scripts/rollback-node.sh --reason "<why>"`. NOT run.
- **Pruning**: the 22 `wa.prev-*` / `wa.prev.*` / `wa.pre-<sha>` files (16-19/11) are written and read by
  nothing in the tree (hand recipe of those days). `scripts/prune-kept-binaries.sh` keeps the newest 3 by mtime,
  DRY RUN by default, `--apply` removes. It never touches `wa`, `wa.pre-upgrade`, `rollback/`, `.prev/`,
  `lua-core*`, symlinks, or a copy that is the installed binary. NOT run against `~/.local/bin`.

## Can `wa release cut` be trusted the first time? What the fixture did NOT exercise

Honest answer: the state machine around it is proved; the first real run is still a first run. Run
`--dry-run` first, and expect to use `--resume`.
1. **The door itself.** No binary was built: `cargo check -p wa-host` passed, but `wa release cut` through the
   Rust arm and lua/core/init.lua was never executed. The tests call `land.run{release=true}`, `land.cli` and
   `land.release_cli` directly.
2. **The full gate as the plan chooses it.** Every test passes `checks = ...` (a marker script). That
   `plan.full` selects `M.DEFAULT_CHECKS` with no rows file is read from the code (`M.gate_checks`,
   `M.gate_rows_file`) and asserted only as `plan.full == true`.
3. **The real build.** `publish-node-binaries.sh` is the fixture's fake. A real one runs in a fresh detached
   worktree of main (as a landing's does in its merge worktree); both architectures, the ancestry-floor proof
   and the code-mode assets were not run.
4. **The real preconditions.** The real `signing` check ran against the scratch vault and `publishing` against
   the fake `gh` route. Not run: the operator's vault and environment, a NODE signer (`M.probes_vault` makes a
   signed call to a peer - the precheck contacts the signer node, as the sign step does), real `gh auth status`.
   `ancestry`'s two refusals (shallow clone, main not containing the previous release) have NO test; only its
   green path is asserted.
5. **Publish and deploy for real.** `gh`/`PUBLISH.sh` are routed; deploy is one scripted `tree` node (case 49).
   The real ring, waves, a `release`-mode node and `--account` routing from a release run were not exercised.
6. **Resume with a lost worktree** (`M.release_tree` on resume) is written and not tested; case 48 resumes with
   the worktree present.
7. `wa land status` without `--run` looks only at landings; a release run's status needs `--run <id>`.
8. `scripts/test-discriminates.sh` was not run; see the base run below.

## Tests run (single files, scratch HOME under ~/wasm-agent/scratch)

| command | last line |
|---|---|
| `HOME=$S WASM_AGENT_HOME=$S/wa TMPDIR=$S WASM_AGENT_LUA_ROOT=$PWD WA_SCRIPT=scripts/test-land.lua ~/.local/bin/wa --db $S/t.db` | `land ok (655 checks)` (132 s; was 45 numbered cases, now + 46, 46b, 47, 48, 49) |
| same, `WA_SCRIPT=scripts/test-refusal-contract.lua` | `refusal contract: 17003 checks passed` |
| `bash scripts/test-prune-kept-binaries.sh` | `prune-kept-binaries ok (13 checks)` |
| `bash scripts/test-rollback-verify.sh` (existing, unchanged) | `test-rollback-verify: ok (...)` |
| `bash scripts/test-fast-rows.sh` | `fast-rows ok (36 checks)` |
| `cargo check -p wa-host` (target m-factory-2) | `Finished dev profile` exit 0 (2 warnings in the crate) |
| `lua5.4 scripts/gen-refusal-codes.lua --write` | `586 codes from 103 reachable modules` - the file did not change |
| the new cases on the BASE land.lua/init.lua (scratch worktree) | FAILS at the first new check: `check failed: a release of main's tip runs to the end (got 1, want 0)` (the prune test is a new script: no base to fail on) |

## Deviations and decisions I took

- Items 1-3 are ONE commit (`2e0459fc`), not one each: they share the same functions and the same test block.
- `release` got the sub-verb `cut`, because the binary owns `wa release <verb>`.
- The worktree of a release run is made in `collect`, so `merge` can be honestly `skipped`.
- A stricter rule than asked: a release refuses when the incoming main is ahead of origin/main.
- Brief facts re-measured: "25+ `wa.prev*`" is 22 files (19 `wa.prev*`, 3 `wa.pre-<sha>`, plus the live
  `wa.pre-upgrade`); "the installer keeps `wa.pre-*`" is wrong for today's installer - it keeps `rollback/`,
  `lua-core.prev` and `wa.pre-upgrade`; the dated copies are from the hand recipe.

## Texts to approve

    release: signing: ready (<why>) | release: signing: not ready (<why>)
    release: publishing: ready (<why>) | release: publishing: not ready (<why>)
    release: ancestry: ready (<why>) | release: ancestry: not ready (<why>)
    release:   fix: <command>
    release: refused(release_signing_not_ready): <why>
    release: refused(release_publishing_not_ready): <why>
    release: refused(release_ancestry_not_ready): <why>
    release: next: <command>
    release: nothing was fetched, built, signed or published
    release: refused(release_takes_no_branch): a release is cut from main's tip and lands nothing
    release: next: wa land --branches <branch> --until main   (land it), then wa release cut
    release: refused(release_resume_of_landing): run <id> is a landing, not a release
    release: dry run - nothing is fetched, built, signed, pushed, published or deployed
    release: from origin/main <sha> as this checkout has it (the run fetches first)  repository <dir>
    release: steps: collect (main's tip) - plan - review/merge/push/main skipped (nothing to land) - gate (every check; kept where this tree already passed) - artifacts - sign - ship - publish - deploy - report
    release: done (run <id>, released main <sha>)
    land: <step>: skipped (nothing to land: a release is cut from main's tip)
    land: continue with: wa release cut --run <id> --resume   (main and every landing are untouched)
    land: landed <sha> on main - the landing is complete (local loop: no release, no node). A release is its own command: wa release cut
    why/fix texts of the three checks: lua/core/land.lua, `M.release_checks.signing|publishing|ancestry`
    step errors: release_main_not_on_origin, release_tree_failed (with observed/next)
    wa land --help: two new lines for `wa release cut`; wa release --help (binary): one new usage line
    prune-kept-binaries: keep <file> | would remove <file> (<n> MB) | removed <file> (<n> MB)
    prune-kept-binaries: dry run - kept <k>, would remove <n> (<m> MB) in <dir>; nothing was changed (--apply removes them)

## How Victor tests it

After this lands and main is installed on the laptop (the binary must be the new one):
1. `wa release cut --dry-run` in a desktop terminal, in `~/wasm-agent/checkout`. He sees
   `release: dry run - nothing is fetched...`, the steps line, the deploy waves, then three lines:
   `release: signing: ready|not ready (...)`, `release: publishing: ...`, `release: ancestry: ...`, each
   not-ready one followed by `release:   fix: <command>`. `ls ~/.wasm-agent/land | wc -l` is the same before
   and after.
2. `wa release --help` now lists `wa release cut`.
3. `bash scripts/prune-kept-binaries.sh` (dry run): one `keep` line for each of the 3 newest copies, a
   `would remove` line for the other 19, and the total in MB; `ls ~/.local/bin | wc -l` is unchanged.
   `--apply` removes them.
4. Not observable without a release: the run itself. The test that proves it is
   `scripts/test-land.lua` cases 46-49.
