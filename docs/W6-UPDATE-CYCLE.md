# The fleet update cycle, measured (night wave 6)

One cycle is: land a commit on `origin/main` -> its release is published for both Linux targets ->
the node that must build (`wasm_the_first`) deploys it -> a peer that can take a prebuilt
(`work`) is updated with `wa update`. This file records what each step costs, from the records the
cycle itself writes (`landing-queue` rows, `deploy.log`/`deploy-outcome`, `upgrade-wait.log`,
`installed.txt`), so an optimization has to show a number and not an intention.

Every rehearsal in this wave lands a docs-only or comment-only commit through
`scripts/landing-queue.mjs`, so the carrier never changes behaviour.

## Baseline (before any optimization)

Measured 2026-11-11, `wasm_the_first` (Windows x86_64), deploy of `b9cf0879`:

| step | where the number comes from | time |
| --- | --- | --- |
| land (docs-only, no upstream move) | landing-queue `history` row | 29 s |
| release, both targets | landing-queue row + `publish-node-binaries.sh --ensure` | covered, seconds |
| deploy `wasm_the_first`: preflight | `deploy: [phase] preflight` | 14.7 s |
| deploy `wasm_the_first`: fetching | `deploy: [phase] fetching` | 1.2 s |
| deploy `wasm_the_first`: compiling | `deploy: [phase] compiling` | 336.2 s |
| deploy `wasm_the_first`: proving | `deploy: [phase] proving` | 2.2 s |
| deploy `wasm_the_first`: installing | `deploy: [phase] installing` | 123.7 s |
| deploy total | first to last phase line | 478 s |

Why compiling dominates: this host has no published node binary (the release publishes
`x86_64-unknown-linux-gnu` and `aarch64-unknown-linux-gnu` only), so a deploy builds the pinned tree
itself, into a **per-pin** `CARGO_TARGET_DIR` (`<tmp>/wa-deploy-pins/<sha>/rust/target`). Every deploy
therefore compiles the workspace from cold, even when the landing changed no Rust at all.

## Round 0: the first cycle, and what it found

The first full cycle (land `2199eaffe310`, then a deploy to make it live) did not reach the install.
It spent **646 s** and refused `canonical_busy`, naming a *pin*:

```
refused(canonical_busy): C:\...\Temp\wa-deploy-pins\b9cf087907a9... is not exactly origin/main
after waiting 600s (HEAD b9cf087907a9, origin/main 2199eaffe310, 0 uncommitted change(s))
```

Two defects, both found by running the cycle rather than by reading it:

1. **The deploy exports the tree it builds from, and the watcher it restarts inherits it.**
   `deploy.sh` exports `WA_DEPLOY_ROOT` for its own children; it then restarts `wa-sentinel`, which
   inherits that variable and hands it to the *next* deploy. From then on every deploy resolves its
   source tree to the previous deploy's detached build pin - a worktree no landing ever
   fast-forwards. The fix is to start the supervisor with those deploy-scoped variables removed
   (`env -u WA_DEPLOY_ROOT -u WA_DEPLOY_PIN -u WA_DEPLOY_PIN_DIR -u WA_DEPLOY_BUILD_TARGET
   -u WA_CODEMODE_TARGET_DIR`).
2. **A wait that cannot succeed is not a wait.** The quiet-canonical-tree gate now refuses at once
   (`source_pin_stale`) when its tree is detached and behind `origin/main`, instead of sleeping the
   whole `WA_DEPLOY_TREE_WAIT` (600 s) to say the same thing.

A third, separate finding belongs to the rehearsal: `wa-sentinel request deploy` written at 07:03:01Z
was spawned at 07:14:18Z, because the sentinel's **own** idle gate defers a deploy while the node is
busy and it carries no pause signal. The pause marker is written by `upgrade.sh` only after the
build, so the first gate still waits a whole turn's length. Bound 1800 s, not exceeded, no false
`deploy silent` - but the pause path was not exercised by the two long turns that were running.
