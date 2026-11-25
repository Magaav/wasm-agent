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

## Round 2 (25/11): warm the row, measure the shell honestly — and the stop's real cause

Base for this round: `change/release-rows-real` at `fb0be2a8` (its first commit `a2777c25` is on
`origin/main` as `013a1aa3`). Commits this round: `27d1c7b1` (warm-up + cold line), `3d584615` (honest
shell check), `792a4c5a` (the e2e wrapper drops every live pointer). Nothing pushed; no peer called; no
installer, sentinel or systemd unit touched.

### The scratch guard (Fable's binding decision, 25/11) — pasted, both environments

`bash ~/Work/missions/_orch/scratch-guard.sh /home/victor/Work/missions/release-rows-real`

**(1) the environment this session's bash tools run in** — NOT ISOLATED, and it is the session's own:
`HOME=/home/victor`, `WASM_AGENT_DB=/home/victor/.wasm-agent/memory.db`, `XDG_CONFIG_HOME=/home/victor/.config`,
`WASM_AGENT_VAULT_URL` set. **No child of either row of this branch ever receives this environment**:
`scripts/test-esc-stops-pty.mjs` launches the CLI with `env -i` plus an allow-list written in the file
(`environment()`), and `scripts/test-release-channel-e2e.sh` now drops every live pointer itself (`792a4c5a`).

**(2) the environment the esc-stops row hands its child** (`env -i` + that allow-list, plus the guard's
required scratch pointers):

```
  ok   HOME = /home/victor/Work/missions/release-rows-real/scratch/guard-probe/home
  ok   WASM_AGENT_HOME = .../scratch/guard-probe/home
  ok   data dir = .../scratch/guard-probe/home/.wasm-agent
  ok   install dir (WA_INSTALL_DIR) = .../scratch/guard-probe/home/.local/bin
  ok   unit dir = .../scratch/guard-probe/home/.config/systemd/user
  ok   WASM_AGENT_DB unset
  FAIL WA_SENTINEL_UNIT_SYSTEMCTL is the real systemctl (systemctl)
  FAIL WASM_AGENT_PORT unset (defaults to the live 8799/8800)
  FAIL WASM_AGENT_CLIENT_PORT unset (defaults to the live 8799/8800)
```

The three FAILs are the guard asking an **install row's** questions: this row starts no node server (its
provider is the row's own HTTP fixture on an ephemeral port) and runs no installer, so it has no ports to
move and no systemctl to stub — and it also never sets `WA_SENTINEL_*` for a child. Everything a child of
this row COULD reach is under the scratch root, and no vault URL is set.

### (1) The row warms the guest first; the cold call has its own line — `27d1c7b1`

Measured cause of the old number: the ledger's own stamps show a tool call ANNOUNCED at 598.3 ms and the
code-mode call only STARTING at 1522.7 ms — **924 ms of compile** between them
(`rust/wa-capabilities/src/quickjs.rs:37-41` writes `<home>/.wasm-agent/cache/codemode/quickjs-<sha>-<engine>.cwasm`,
`:53` is `Module::new` when it is absent) — while the nested bash call itself took 33 ms.

The row now: one cheap call (`echo warm`) → waits for the `.cwasm` the product itself writes → waits for the
warm turn's `run|end` → then types the measured line. The cold number is read from the harness's ledger
stamps (announced call → final result), printed per scenario, and judged against a LOOSE 3000 ms bound.
Unknown is never a pass.

Measured, bash leg, this tree's binary: cold **947-1177 ms**, module cache written, `ok` on all five legs
in the full row (`964, 964, 980, 983, 1022 ms`); on the published v0.1.1 the same line reads 993-1232 ms.

### (2a) v0.1.1, the warm case: the shell survives there too

Row, published asset (sha256-verified, `wasm-agent v0.1.1 · v2104a4d8`):

```
KNOWN-FAIL - bash: the shell the stop interrupted is gone 1000 ms after the prompt, measured from the prompt back
       1 process(es) still alive 1000 ms after the prompt (pids 781506; the row killed them by pid: 781506)
```

Followed from outside, by pid, for the whole life of the shell (`ESC_SETTLE_MS=3000`, so the key lands while
`sleep 30` really runs):

```
shell 557081 STARTED, pane 556398 DIED at +29581 ms, shell 557081 GONE after 30002 ms (pane already dead)
```

**v0.1.1: the shell outlives the stop AND the CLI and runs its own 30 s.**

### (2b) main, the warm case: the same, and for the full time

```
shell 548893 STARTED, pane 548031 DIED at +11467 ms, shell 548893 GONE after 29970 ms (pane already dead)
```

**main: the stop does not signal the process group at all.** Not a 1-2 s grace: the shell is alive when the
CLI itself dies and is alive when the `sleep 30` ends. Ledger for that run: interrupt 4027.4 ms,
`tool/end` 4428.7 ms, `run/stopped` 4470.3 ms — the prompt is back while the shell has 26 s to run.

### The class: NOT a regression

Survives on main **and** on v0.1.1, for the full time on both → per Fable's tree this is not a regression and
not mine to fix: it becomes week 1's first item ("Esc stops what it started": the process group, not only the
prompt). The row now says it on every run as a **named known defect** (`3d584615`), never as a pass.

### The honest check — `3d584615`

* readiness is the PROCESS, not the transcript line: the leg starts only when a `sleep` descendant of the
  pane exists (the old readiness was the "Bash(sleep 30)" line, printed up to 900 ms before the call starts —
  measured "gone 7 ms" on a leg whose shell had not started);
* the shell's pids are taken at the key from the pane's own tree and followed BY PID, so the measurement
  survives the session's own death (a tree walk from a dead pane called a live shell "gone");
* it measures from the prompt's return against a STATED bound, `SHELL_GONE_MS = 1000`; "no shell at the key"
  is `unknown` and says so;
* the row kills what it started, by pid (a known-failing run used to leak a 30 s shell);
* `KNOWN-FAIL` is its own verdict and its own count: `esc-stops pty: 21 ok, 1 failed, 1 known-fail`. When it
  starts passing, the same line says the named defect is FIXED.

### The row's output, both binaries (full row, this round)

**main (`3d584615`, load 2.4): `21 ok, 1 failed, 1 known-fail`**

| leg | usable (pty) | stop (node) | cold first call | verdict |
| --- | --- | --- | --- | --- |
| headers | 150 ms | 1 ms | 984 ms | ok |
| stream | 153 ms | 1 ms | 964 ms | ok |
| bash | **780 ms** | **638 ms** | 980 ms | **FAIL** (see below) |
| remote | 166 ms | 20 ms | 983 ms | ok |
| subagent | 190 ms | 29 ms | 1022 ms | ok |

`KNOWN-FAIL - bash: the shell the stop interrupted is gone 1000 ms after the prompt … 1 process(es) still
alive (pids 738023; the row killed them by pid: 738023)`.

**v0.1.1 (`13 ok, 9 failed, 1 known-fail`)**: bash 819 ms (stop unreadable: that build writes no stopped row);
subagent 270 ms ok; headers and remote never give the prompt back inside 20 s; stream returns at 9737 ms —
these are v0.1.1's own gaps (it predates the interrupt row and the socket shutdown), named here so nobody
reads them as this branch's work. The shell check is the same KNOWN-FAIL on v0.1.1.

### The bash leg's remaining red has a NAME: the code-mode poll slice

With the guest warm the bash stop is still 395-907 ms, and the ledger says exactly where it goes (settle 2000
run, load 3.37): interrupt at 3943.5 ms → the NESTED tool call returns at 4813.6 ms (**870 ms later**) →
`run/stopped` 884.5 ms after the key; the operation store shows that call only ever reached `accepted`.
That is the code-mode pending executor: `lua/core/codemode_pending.lua:79` (`M.SLICE_MS = 1000`) and
`operation_poll` (`:375-390`), which asks `cancelled()` only BETWEEN 1 s slices — so a stop is quantised to
the slice boundary (395 ms when the key fell just before one, 907 ms just after, 89 ms by luck). It is not
the compile (that is the warm-up's own line) and it is not this branch: v0.1.1's bash leg is 813-819 ms.

**This is why the bash leg is red on main, and it was red on main before this branch** (the brief's own
figures: 690 ms at load 1.52). Nothing in this branch touches the stop path. Fable owns the decision —
product (wake the wait on cancel, or poll in small slices) or budget — and the change to the stop path is
theirs to order, not mine.

### Texts to approve (row output, verbatim)

1. `     warm-up: the first code-mode call took <n> ms, module cache written by the product - loose bound 3000 ms`
2. `     warm-up: the first code-mode call took unknown (<why>), module cache MISSING - loose bound 3000 ms`
3. `ok - <leg>: the first code-mode call of the process is setup, not the stop (3000 ms loose bound)`
4. `FAIL - <leg>: the first code-mode call of the process is setup, not the stop (3000 ms loose bound)` + `unknown: …`
5. `KNOWN-FAIL - bash: the shell the stop interrupted is gone 1000 ms after the prompt, measured from the prompt back`
6. `       named known defect: Esc stops the prompt but not the process group (measured 25/11: …) - week 1 item "Esc stops what it started"`
7. `ok - bash: the shell the stop interrupted is gone 1000 ms after the prompt, measured from the prompt back (…) - the named known defect is FIXED: …`
8. `esc-stops pty: <n> ok, <n> failed, <n> known-fail`
9. table cell `unknown (no shell at the key)`

### Discrimination (`scripts/test-discriminates.sh ebf6d2ec`, HEAD `792a4c5a`)

```
environment        scripts/test-esc-stops-pty.mjs   the machine could not run it:        (empty reason)
unchanged-verdict  scripts/test-release-channel-e2e.lua   still passes on the base's code; not blocking
unchanged-verdict  scripts/test-release-channel-e2e.sh    still passes on the base's code; not blocking
```

Nothing blocks. The two `unchanged-verdict` rows are correct for a branch with no product change. The pty row
is `environment` — the gate could not run it on the base's code and, worse, could not say WHY: the reason
field is empty. That is a gap in the gate's own message (it is non-blocking by its own rules), and it is
recorded here rather than left to look like a pass. The pty row's own red is pre-existing and named above
(the bash stop's 1 s poll slice), and it is the same on the base.

## Rule 1 (Fable, 25/11 ~00:45Z): a correction to my own commit, and what it cost to find

**My `792a4c5a` violated it.** Its wrapper fence said "unset every `WASM_AGENT_*` and `WA_*`" — which clears
`WASM_AGENT_IN_TURN` (what makes `deploy.sh`/`upgrade.sh` refuse to run inside a turn) and
`WASM_AGENT_PROVENANCE` (`=child` is what makes `wa update` answer `update_coordinator_only`,
`lua/core/update.lua:824`). A fence that strips those hands its children exactly the power the guard takes
away. Fixed in **`28da72e0`**: the repository's own shape (`verify/slice.sh:14-22`) — a KEEP-LIST for the
guard's variables plus `WA_BIN`, and a drop of the three runtime families only
(`WASM_AGENT_*`/`WA_*`/`OPENAI_*`/`OPENCODE_*`/`ANTHROPIC_*`). The esc-stops row, which starts the CLI under
`env -i`, now carries `WASM_AGENT_IN_TURN` and `WASM_AGENT_PROVENANCE` through when the caller has them.

**Measured, not asserted:**

```
the fence against an environment carrying both kinds:
  kept:    IN_TURN=1 PROVENANCE=child SKIP_UI=1 WA_BIN=/x PATH=/usr/bin:/bin TERM=xterm-256color
  dropped: DB=gone HOME_VAR=gone VAULT=gone INSTALL=gone
bash scripts/test-release-channel-e2e.sh                        -> release-channel-e2e ok (20 checks)
the same row with WASM_AGENT_IN_TURN=1 exported                 -> release-channel-e2e ok (20 checks)
the esc row's bash leg with IN_TURN/PROVENANCE passed through   -> 4 ok, 1 failed, 1 known-fail (stop 646 ms)
```

**The mistake in between, kept on the record because it is the same failure class:** my first replacement said
"unset everything that is not the keep-list" and took `PATH` and `HOME` with it — the row died on
`git: No such file or directory`, `HOME: unbound variable`, `rm: No such file or directory`. A fence that
strips too much is the same failure it exists to prevent; it now names the three families and nothing else.

**Rule 2 — no installer row in this mission, so no `row-request.txt`.** Neither row of this branch runs
`upgrade.sh`, `deploy.sh`, `bootstrap.sh` or `wa-sentinel`: the e2e row copies `install.sh` and
`bootstrap.sh` INTO the bundle it checks and never executes them, and its sentinel is a 3-line stand-in. If
Fable wants a *release* row (`scripts/release-linux.sh` builds a bundle) under the runner as well, that is a
one-line request — say so and I will write it.

**Rule 1 in the rest of the session:** nothing I ran detached (`setsid`/`nohup`/`disown`/`&` appear nowhere in
either row or in any command I issued), and nothing cleared a guard variable by name. The one place I did
build an `env -i` was the earlier guard *probe* (a read-only environment print for `scratch-guard.sh`), not a
run of an installer; from now on the runner owns that for installer rows and I will not reproduce it.

