# release-rows-real (G, Fable 24/11) — two main-health reds, measured

Branch `change/release-rows-real`, base `origin/main` `ebf6d2ec`. Nothing pushed, nothing installed, no
live node called (no `wa call`, `tools.remote`, `nodes.list`, `land` or `deploy` against any peer; every
row here is a scratch HOME, a private tmux server and a local fixture port).

## What moved under this mission (reported, not restructured)

This session did not push anything. While it ran, the orchestrator's landing queue merged this branch at
`a2777c25` into `origin/main` as `013a1aa3` ("land-quick: merge change/release-rows-real", 2026-11-24
21:14:37 -0300) — so the A fix is already on main, and `2428320d` (this report) is the only unlanded commit
on the branch, sitting on top of it. Nothing was rebased, squashed or rewritten; the branch's shape is
`013a1aa3 + report`.

## A. release-channel and test-release-channel-e2e — the row was broken, not the release

**Reproduced, ebf6d2ec, first case of the row, twice:** `WA_E2E_KEEP=1 TMPDIR=/tmp bash
scripts/test-release-channel-e2e.sh` → `release-channel-e2e FAILED (exit 1)`,
`linux_channel_build_failed: linux-channel: build_failed: scripts/release-linux.sh --target
x86_64-unknown-linux-musl`. The kept workdir shows both defects the brief names:

* `.../journal/e2eA/release/linux-channel/out/build-x64.log` ends at
  `release-linux: node:internal/modules/esm/resolve:241`, and the fixture's `scripts/lib` holds
  `build-receipt.mjs` and `cargo-executable.mjs` and **no `main-module.mjs`**: `ce1feb5b` made
  `build-receipt.mjs` import `./main-module.mjs` and the row copied a FIXED LIST of two files
  (`scripts/test-release-channel-e2e.lua:146`, the `optional` table).
* `out/wa-host.log`: `node: line 24: cd: "/tmp/…/land-fixture/repo": No such file or directory` —
  the stand-in's receipt line ran `$(CDPATH= cd -- \"$root\" && pwd -P)` inside a double-quoted
  `printf`, and inside `$()` a `\"` is an escaped quote, so `cd` was handed the path WITH the
  quote characters (the receipt's `root` field would then have been empty).

**Fixed in the row, by rule (tests only), commit `a2777c25`:**
the fixture now copies the directory (`cp -Rf <tree>/scripts/lib/. <repo>/scripts/lib/`), so the next
import a reader grows is carried without anyone remembering a line, and an OLD tree still copies the lib
it has (no `build-receipt.mjs`), which is the defect this row exists to catch; the stand-in now runs
`$(CDPATH= cd -- "$root" && pwd -P)`.

**RED → GREEN, same command:** before `release-channel-e2e FAILED (exit 1)`; after
`release-channel-e2e ok (20 checks)`. No check was deleted or loosened (the diff is 13 insertions and 8
deletions in one test file: the copy rule, its comment, the `cd`).

Scratch-home guard note: run with the mission's `TMPDIR` the row refuses by name
(`REFUSED test-release-channel-e2e.lua: WASM_AGENT_HOME … is inside the operator store`) because the
wrapper's `mktemp` honours `TMPDIR`; `TMPDIR=/tmp` is the fix, and the guard did its job.

## A, question 2 — is the REAL release path free of the same missing import? (measured)

1. **The release tarball does not carry `main-module.mjs`, does not carry `build-receipt.mjs`, and does
   not need either.** Measured on the published asset itself (`v0.1.1`, sha256 verified,
   `197dce8a…`): `tar -tzf wa-linux-x64-musl-2104a4d88a37.tar.gz | grep '/scripts/'` lists exactly
   `install.sh`, `linux/bootstrap.sh` and the eight `M.RUNTIME` files (`mcp-client.mjs`,
   `mcp-client-core.mjs`, `mcp-server-core.mjs`, `mcp-session.mjs`, `mcp-web.mjs`, `mcp-mail.mjs`,
   `web-core.mjs`, `web-http-outcomes.mjs`); `grep -E 'main-module|build-receipt|cargo-executable'` → none.
2. **Every relative import in the shipped bundle resolves inside the bundle** (5 edges, all `ok`:
   `mcp-client→mcp-client-core`, `mcp-session→mcp-client-core`, `mcp-web→mcp-server-core`,
   `mcp-web→web-core`, `web-core→web-http-outcomes`), and all eight files load under `node`
   (`import()`): three of them answer their own entry guard (`mail_binding_required`,
   `mcp_seed_file_required`, `web_binding_required`) — that is the `isMain` guard refusing to RUN, not a
   missing import.
3. **The cut reads the checkout, where the import is present.** `scripts/release-linux.sh:153` runs
   `node "$ROOT/scripts/lib/build-receipt.mjs"` and `:176` `cargo-executable.mjs`, `$ROOT` being the git
   tree; `git ls-tree HEAD scripts/lib/` carries `main-module.mjs` beside both, and in this worktree
   `import('./scripts/lib/build-receipt.mjs')` → `readBuildReceipt`,
   `import('./scripts/lib/cargo-executable.mjs')` → `cargoExecutable` (no `ERR_MODULE_NOT_FOUND`).
   `scripts/publish-node-binaries.sh` stages no scripts at all (it prints `gh release upload` for built
   binaries); `scripts/install.sh:283-300` fetches from the pinned commit only
   `release-signing.sh`, `release_verify.py`, `install-record.sh`, `node-pins.sh` and
   `config/release-keys.txt` — no `.mjs`.
4. **What I could NOT measure:** the installed tree itself. `~/.local/bin` is a path this node's tool
   guard refuses (`secret_path_denied`, `lua/core/secret_guard.lua`), so the orchestrator's reading
   (`main-module.mjs` present, `build-receipt.mjs` absent) is taken as given; it is consistent with a
   bundle install (which ships no `scripts/lib` at all) plus files merged in by
   `scripts/linux/bootstrap.sh:439` (`cp -rn "$prefix/scripts/." "$prefix/scripts.new/"`).

**Answer: NOT the bigger defect.** The missing import exists only inside the ROW's fixture. Nothing the
release ships or the installer fetches imports `main-module.mjs` from a place that lacks it.

## B. esc-stops-pty, the bash leg — not a regression; the grace is named; nothing changed

**v0.1.1, the published asset, sha256-verified** (`wasm-agent v0.1.1 · v2104a4d8`), same row:

| run | bash leg | load |
| --- | --- | --- |
| full row | FAIL — measured **672 ms**, budget 300 ms (notice (pty) **666 ms**; `stop unknown` — that build writes no `run|stopped` row) | 2.21 |
| `ESC_ONLY=bash` ×3 | no usable reading (the scenario timed out waiting for the prompt at load 5.6-8.5) | 3.3-8.5 |

**main (this tree)**, same leg: measured 677 ms / node prompt 543 / **stop 526** (load 3.27) · 691 / 563 /
**547** (3.55) · 794 / 668 / **648** (4.1) — and the brief's 690 / 559 / **542** at load 1.52.

So v0.1.1 stops a bash call in the same ~540-670 ms window main does: **not a regression**, and per the
rule nothing in the product and no budget changed.

**The grace, measured: the COLD COMPILE OF THE QUICKJS CODE-MODE MODULE on the process's first code-mode
call** — `rust/wa-capabilities/src/quickjs.rs:37-41` (the `<home>/.wasm-agent/cache/codemode/quickjs-<sha>-<engine>.cwasm`
cache read/write) and `:53` (`Module::new(engine, bytes)`, Cranelift, when the file is not there). The
harness runs the tool call through the sandbox (`"codemode_call":1` in the ledger's `tool/end`), so a
fresh scratch home pays the compile once per process, and an interrupt raised inside that window cannot be
observed until the guest exists.

Evidence, all measured:

* **The row's own settle knob isolates it.** Same binary, same load window, only the delay before Esc
  changed: `ESC_SETTLE_MS=250` → measured 906 ms, **stop 746 ms** (load 7.33); `ESC_SETTLE_MS=3000` →
  measured 278 ms, **stop 116 ms**, settlement 10 ms (load 6.9).
* **The ledger's own stamps, settle 3000:** `tool/start` at 0 ms, a second `tool/start` (the code-mode
  call) at **1137.8 ms**, `input/interrupt` at 3148.8 ms, `tool/end` **96.9 ms** after the interrupt,
  `run/stopped` 3264.9 ms → the 116 ms stop. Once the guest exists, the stop is ~100 ms.
* **The module cache file dates the compile:** `…/cache/codemode/quickjs-d4c9375f2b1ca4dc-e89d3d489ee31ddf.cwasm`
  written **1117 ms** after `tool/start` — the second `tool/start` at 1137.8 ms is the same event.
* **In the shipped shape (settle 250) the interrupt lands inside that compile:** the ledger split is
  `input/interrupt` → `tool/end` = **639.1 ms** (a bash call that had not created an operation yet — the
  scenario's operation store holds only the two startup ops), then `run/stopped` **+8 ms**, `run/end`
  `+18 ms`, `input/prompt` `+29 ms`. Everything after the tool call is ~30 ms.
* **It scales like a compile, not like a poll:** stop 526-547 ms at load 3.3, 648 at 4.1, 746 at 7.3,
  1757 at 10. A wait-slice poll would be roughly uniform in `[0, slice]` at any load.
* The reader's own share is separate and small: key → interrupt ≈ 130 ms (the 120 ms lone-Esc lookahead,
  `rust/wa-capabilities/src/host.rs:4947` `byte_ready(120)`, so the raise happens after it). Measured as
  `usable` minus `node prompt`: 794-668 = 126, 691-563 = 128, 677-543 = 134.

**Second finding, NOT fixed and needing Fable** (it is the stop path): with `ESC_SETTLE_MS=3000` — Esc
while the `sleep 30` really is running — the prompt comes back in 116 ms **but the shell survives**:
`FAIL - bash: the shell the stop interrupted is gone … NOT GONE (1 alive)`. At the shipped settle
(250 ms) that check passes only because the shell had not started yet (the compile was still running), so
the row's "shell gone" check is vacuous in its default timing. This is the defect the check exists for, and
it is currently invisible.

## Rows run (what this report claims)

| row | result |
| --- | --- |
| `TMPDIR=/tmp WA_BIN=<this tree's build> bash scripts/test-release-channel-e2e.sh` | RED before (`FAILED exit 1`, `build_failed`), **GREEN after** (`release-channel-e2e ok (20 checks)`) |
| `WA_BIN=<v0.1.1 published asset> node scripts/test-esc-stops-pty.mjs` | 672 ms bash / 666 ms pty notice at load 2.21 |
| `WA_BIN=<main> ESC_ONLY=bash node scripts/test-esc-stops-pty.mjs` ×5 (settle 250) | 677-794 ms, stop 526-648 ms, load 3.3-4.1 |
| the same with `ESC_SETTLE_MS=250` vs `=3000` | stop 746 ms vs **116 ms**; the 3000 run fails "shell gone" |
| `bash scripts/test-discriminates.sh ebf6d2ec` (under `flock -o ~/Work/missions/.suite.lock`) | see "Discrimination" below |

The binary used for every main run is this worktree's own build
(`cargo build --release --offline --manifest-path rust/Cargo.toml` with
`WA_CODEMODE_BUILD_ASSETS=<the node's prepared assets>` and
`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-release-rows-real`), at `ebf6d2ec` + the test commit.

## Discrimination — does the fixed row still catch the defect it exists for?

`bash scripts/test-discriminates.sh ebf6d2ec` (under `flock -o ~/Work/missions/.suite.lock`): one row,
**`unchanged-verdict`**, 0 blocking, 0 discriminating — "a modified test that still passes proves nothing
about the fix, and does not block". That is the correct verdict for this branch and not a hole in the row:
the branch changes no product code, so the base's non-test code IS the branch's code, and the fixed row is
green on it.

Two things were measured to say what the row still catches:

* **The row still catches the product defect it was written for.** In a scratch worktree at `a2777c25`
  (removed afterwards) the ONE product line was put back to its pre-`3ef96341` shape —
  `wa_bin="$ROOT/rust/target/x86_64-unknown-linux-musl/release/wa"`, the guessed directory — and nothing
  else: the fixed row goes RED, and says why:
  `release-linux: build_receipt_binary_absent: the receipt names …/rust/target/x86_64-unknown-linux-musl/release/wa,
  which is not an executable file` → `release-channel-e2e FAILED (exit 1)`.
* **A tree old enough to predate the receipt readers cannot run this row any more**, so the row's
  "an old tree is caught" claim is not exercisable: a worktree at `3ef96341^` (`85593e74`) dies first on
  `fixture: the fake GitHub failed` — `scripts/lib/fake-gh.sh` (and the wrapper) do not exist there,
  because the row's own stand-ins postdate the tree. That is a limit of the fixture, not of the assertions;
  the mutation above is the honest test of "the row still discriminates".

## Texts to approve

None. The one commit changes comments, one `must()` line and two characters of a shell snippet inside a
test; no operator- or model-facing string is added or changed (the new `must()` label,
"copy scripts/lib by rule - the directory every import in the chain resolves against", is a test-failure
label, printed only when the fixture copy fails).

## Lessons (for the next session)

* A row that copies a file LIST from the tree under test is a timer: the next import the copied file grows
  breaks it, and it breaks as "the fixture is incomplete", which reads like the product. Copy the directory.
* A `cd \"$var\"` written inside a double-quoted string is a path with quotes in it. Test the snippet on
  its own (`printf '%s\n' "{\"root\":\"$(CDPATH= cd -- "$root" && pwd -P)\"}"`).
* `TMPDIR` inside the operator store makes every scratch-home guard refuse — by name, which is the guard
  working; `TMPDIR=/tmp` for the arm's rows.
* A cold-process timing row measures the process's first-use costs (here: a Cranelift compile of the
  code-mode module) unless the interrupt is placed after them. `ESC_SETTLE_MS` is the knob that separates
  "the stop is slow" from "the stop waited for first-use setup", and it should be the first thing run.
