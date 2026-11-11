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
