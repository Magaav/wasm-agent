# release-ancestry

A release installs over its predecessor with no override, and an operator's override reaches `upgrade.sh`.

Base: `bfad4f8f`. All work is local commits on `change/release-ancestry`; nothing was pushed and no live
node was touched.

## The two measured defects

**1. A release binary could not answer for a commit it carried.** `~/.local/bin/wa` (built at `bfad4f8f`)
reported `ancestors=877 ancestors_complete=false` and answered
`contains=unknown reason=no_ancestry_embedded` for `7ddbfa98` — a commit **inside its own embedded list**,
42 commits down. The reader (`rust/wa-host/src/build_info.rs`) refused to search the list at all once
`ancestors_complete` was false, which any build from a shallow clone reports. Every rollout that day
needed `WA_UPGRADE_FORCE_REASON`.

**2. The override never crossed into the installer.** `wa update <node> --release --force --reason <text>`
wrote a wrapper that ran `scripts/release-install.sh <commit>` with no override in the environment, so
`upgrade.sh` — the process that actually swaps the pair and asks the ancestry question again — refused with
`ancestry_unknown` and the operator's reason reached no record. Two further breaks on the same path: the
CLI dropped `--force` entirely when the node carried **no** pin (`force_note` was only set inside the pin
branch), and `WA_UPGRADE_VIA` was written as a bare `var=value` line, which a shell runs as a command.

## What the diff does

| # | change | commit |
|---|---|---|
| 1 | `contains_in` searches the embedded list whatever `ancestors_complete` says: a hit is `Yes`, a miss is `No` only from a complete window, else `Unknown("below_ancestry_window")` | `4545ae83` |
| 1 | `build.rs` records `ancestors_floor` — the boundary commit; `--build-info` carries it and `--contains` prints it for a below-window miss | `4545ae83` |
| 1 | `wa_ancestry_window_floor` / `wa_ancestry_deepen` in `scripts/lib/node-binaries.sh`: a shallow clone answers `shallow_window_unknown` rather than calling the cut a root | `4545ae83` |
| 1 | `publish-node-binaries.sh` deepens once and refuses by name (`ancestry_window_unknown`), then proves the artifact contains the floor (`ancestry_window_short`, exit 5) | `4545ae83` |
| 1b | `test-build-info.sh` asserts the oldest carried commit answers yes — reads `$?` into a variable, because a `$(...)` in the label resets it | `b11bb61b` |
| 2 | `request_release` exports `WA_UPGRADE_FORCE_REASON` (the operator's own `override_reason`) and `WA_UPGRADE_VIA`, empty when the request was not forced, so a stale reason cannot be inherited | `212005d2`, `cf3cd977` |
| 2 | the CLI sends `force_note` for `--force` with no pin in force, and refuses `--force` without `--reason` there too | `212005d2` |
| 2b | the test **runs** the wrapper against a probe script and reads its environment, so the claim is proved across the process boundary | `cf3cd977` |

## Tests, and where they are wired

- `scripts/test-ancestry-window.sh` (new, 13 checks) — wired into `scripts/test.sh` beside `test-build-info.sh`
  and into `scripts/fast.sh` as `ancestry-window`. It builds its own scratch git history under a scratch
  `HOME`, and refuses to run when `HOME` is a real node home unless the caller passes
  `WA_TEST_SCRATCH_HOME=1` (both suites do, on the case's own line).
- `scripts/test-build-info.sh` — one new check ("the OLDEST commit this build carries answers yes").
- `scripts/test-remote-update.lua` — five new checks in §7h: the wrapper exports the override, carries the
  reason, clears it for an unforced request, and two that run the wrapper for real.

**They fail on base.** Verified in a separate worktree of `bfad4f8f` (never `git stash`):
`test-ancestry-window.sh` fails 4 checks (the library functions do not exist); `test-build-info.sh` fails
"the OLDEST commit this build carries answers yes: got '2' want '0'" against a `wa` built from base's
Rust; `test-remote-update.lua` fails at "the wrapper exports WA_UPGRADE_FORCE_REASON".

Both Lua and shell runs must set `WASM_AGENT_LUA_ROOT`, otherwise `wa` uses its **embedded** Lua and a
test of an edit under `lua/` runs green while loading nothing from the tree (the binary warns once:
"lua root unset: using embedded modules"). This cost one wrong "passes on base" reading during the work.

## Item 3: which hand steps retire

- **`WA_UPGRADE_FORCE_REASON` over SSH** — retires for the ancestry case. A release built after this branch
  answers `yes` for the previous release (the producer deepens and proves it; the consumer searches what it
  carries). Until such a release exists, a binary carrying an incomplete window **and** built before
  `4545ae83` still answers unknown for a commit below its cut, and the override is still the operator's way
  through — but it now reaches `upgrade.sh` from `wa update --release --force --reason` (item 2), so it no
  longer needs a hand-run shell on the node.
- **`chmod` on the candidate** — already retired before this branch: `scripts/lib/node-binaries.sh`
  chmods after signature and pin verification (line 652, 716).
- **scripts overlay** — **remains**. `scripts/release-linux.sh` ships `scripts/install.sh` and
  `scripts/linux/bootstrap.sh` only; `upgrade.sh`, `release-install.sh` and `scripts/lib/node-binaries.sh`
  are shipped by `scripts/deploy.sh` (a tree deploy), not by the bundle. A node installed purely from a
  bundle reaches `--release` only through `deploy.sh`'s `release-install.sh`, so laying those scripts over
  `$INSTALL/scripts` by hand is still needed where no tree deploy has ever run. Making the bundle carry them
  is a separate change and is not in this diff.

## Not verified

- No release was built and published here (`publish-node-binaries.sh` needs `cargo-zigbuild` and zig), so
  "a release built in CI's shape answers yes for the previous release commit" is proved by the library and
  publisher rules plus the artifact-side test, not by publishing a bundle.
- The full gate (`scripts/test.sh`) was not run end to end; the three changed tests were run individually
  and the Rust unit tests (`cargo test -p wa-host --bin wa build_info`, 11 passed) were run.
