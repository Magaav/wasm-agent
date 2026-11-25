# factory-small-items (Fable 25/11) - ready

Branch `change/factory-small-items`, base `origin/main` = 70eb209d, five items, all measured on this node
(avell, 16 cores). `wa --version` here: `wasm-agent v0.1.2 . va1857d15 . tree 70eb209d`.

| commit | what | rows |
| --- | --- | --- |
| 1dfd1d1d | item 1: the installed line names the program AND the tree; an interim record is not an identity; a bytes-only move is an install | `scripts/test-deploy-release-honest.lua` 106 checks |
| 2069e0a9 | item 4: one variable per door (`WA_SENTINEL_UNIT_SYSTEMCTL`, `WA_PORT`/`WASM_AGENT_PORT`) | `scripts/test-installer-doors.sh` 15 checks |
| fdd404be | item 1 follow-through: the deploy-target row asserts the new line (narrower, not looser) | `scripts/test-deploy-target.sh` 14 checks |
| (this commit) | item 5: the covering-release row stops what it started before it removes its scratch home | the row itself (SKIPs here, see below) |
| (no commit: outside the repository) | items 2 and 3: `~/Work/missions/_orch/row-runner14.sh` and `deliver-row-verdict4.sh` | simulations, below |

## The brief's premises, re-measured

* Item 1: `installed_text` (lua/core/deploy_pause.lua) named only the tree - confirmed, one line. `wa --version` is
  composed in rust/wa-host/src/build_info.rs (`install_label`), so `program` + `tree` is the shape a person already reads.
* Item 1's second clause: `scripts/upgrade.sh:406-419` writes `record_role=interim` while the bytes are being swapped,
  and `installed_identity` read that record as what the node runs - so a pause taken in that window recorded the
  INCOMING commit and the finished record looked unchanged. Measured on the base: `installed_identity({record={commit="ffff6666aaaa7777", record_role="interim"}})` answered `ffff6666aaaa7777/ffff6666aaaa7777`, and
  `install_moved` on two records that differ only in `sha256` answered `false`.
* Item 4, door A: `scripts/lib/service-target.sh:115-117` and `:148-150` asked a plain `systemctl` - confirmed on the
  base: with `WA_SENTINEL_UNIT_SYSTEMCTL` pointing at a scratch shim, `wa_service_exec_start` answered EMPTY and
  `wa_service_install_dir` answered `/home/victor/.local/bin`, "the node on port 8799 runs
  /home/victor/.local/bin/wa".
* Item 4, door B: `scripts/deploy.sh:113-114` read `WA_PORT`/`WA_CLIENT_PORT` only - confirmed. The row runner
  (`_orch/row-runner13.sh`) already exports BOTH spellings and copies its stub to `bin/systemctl` as a workaround;
  after this branch neither workaround is needed, and the runner's own export is the brief's "the runner exports both".
* Item 5: `cleanup` in scripts/test-deploy-covering-release.sh killed `$NODE_PID`, stopped the sentinel through the
  installed binary and then `rm -rf "$W"` with no wait - confirmed by reading it (the sentinel's own children and the
  node it started write into `$W` for a moment after `stop`).
* Premises that were WRONG and are corrected: the brief says item 2 and 3 are "the runner's" and they are; neither
  file is in the repository (`~/Work/missions/_orch/`), so neither can be a commit here - see "Where items 2 and 3 are"
  below. Rule 12 of the brief (never install into ~/.local/bin, never edit installed.txt) was obeyed: nothing installed.

## Item 1 - the install notice tells the truth (1dfd1d1d)

`git show 1dfd1d1d -- lua/core/deploy_pause.lua`:

* `installed_identity` reads four facts through the one reader of `installed.txt` (`update.installed_record`):
  `program` (`binary_commit=`, else `binary_release=`, else `commit=` for a record that is a full build's), `tree`
  (`lua_tree=`, else `commit=`), `commit`, `sha256`; and answers nil for a record whose `record_role=interim`.
* `install_moved` compares all four (`program`, `tree`, `commit`, `sha256`), so a Lua-only install, a rebuild of the
  same commit and a prebuilt install that moved only its own bytes are each an install.
* `installed_text` is now, verbatim:
  `[deploy] installed: this node now runs program <program>, tree <tree> (was program <was-program>, tree <was-tree>).`
  with the `wa --version` label rule (`display_label`: a commit label gets a `v`, a release tag is printed as it is)
  and `not recorded` for a field the pause record does not hold.
* `record_pause` writes `installed_program`/`installed_sha256`, `paused_identity` reads them back.

Row: `scripts/test-deploy-release-honest.lua` section 5, run from scripts/test.sh:1536 (the gate line already there):

* 5a a Lua-only install - `[deploy] installed: this node now runs program vcccc3333dddd, tree bbbb5555eeee (was
  program vcccc3333dddd, tree aaaa1111bbbb).` asserted with `eq`, through the real tick;
* 5b a compile install - `[deploy] installed: this node now runs program vffff6666aaaa, tree ffff6666aaaa (was program
  vdddd4444eeee, tree dddd4444eeee).` likewise;
* 5c the replay - a pause taken on an interim record names no tree and no commit, and its release says
  `[deploy] the pause ended`, never `[deploy] the update did not happen`;
* 5d the function facts (a `sha256`-only move is an install, a `program` move is an install, four equal facts are not).

`deploy release ok (106 checks)` on this branch. RED on the base (a separate worktree of 70eb209d, the new row file
copied in): `a Lua-only install says the program it kept and the tree it moved: expected [deploy] installed: this node
now runs program vcccc3333dddd, tree bbbb5555eeee (was program vcccc3333dddd, tree aaaa1111bbbb)., got [deploy]
installed: this node now runs bbbb5555eeee (was aaaa1111bbbb).`

## Item 4 - a scratch deploy cannot see the live install (2069e0a9)

`git show 2069e0a9`:

* scripts/lib/service-target.sh: `wa_service_exec_start` and `wa_service_pid` ask
  `${WA_SENTINEL_UNIT_SYSTEMCTL:-systemctl}` (the variable sentinel-unit.sh and install-isolation.sh already honour);
  `wa_node_port` (`WA_PORT`, else `WASM_AGENT_PORT`, else 8799) and `wa_node_client_port` (`WA_CLIENT_PORT`, else
  `WASM_AGENT_CLIENT_PORT`, else the node port + 1) are the one expression, and the two internal probes use them.
* scripts/deploy.sh: `PORT`/`CLIENT_PORT` come from those helpers, with the same fallbacks inline for an older
  service-target.sh beside it.

Row: `scripts/test-installer-doors.sh`, wired into scripts/test.sh immediately after the sweep row:
part A the systemctl door (ExecStart + MainPID through the given systemctl, and the scratch install it resolves),
part B the port door (both spellings, `WA_PORT` first, the client port following the node port), part C the deploy's
own refusal naming the SCRATCH install and never `:8799`, with only the node's spellings exported.
`installer doors ok (15 checks)`. RED on the base at part A: `installer-doors FAILED: scripts/lib/service-target.sh
defines no wa_node_port, so a deploy cannot honour WASM_AGENT_PORT`, and the base's own answer for the probe (measured
above) was the live install on 8799.

Not done: the row does not start a live node on 8799 and prove the deploy ignores it - the port it holds is the row's
own, and the assertion is that the deploy never names 8799. A deploy run that gets past the first precondition would
start a build and touch `~/.local/bin`, so the row stops at the refusal by design.

## Item 5 - the covering-release row removes its own scratch home

scripts/test-deploy-covering-release.sh `cleanup` now: stops the sentinel it installed, kills `$NODE_PID`, then (up to
10 rounds) TERMs every process whose environment or command line names THIS row's scratch root - never a process name
(rule: a name pattern is shared by strangers) - then removes the worktree, `chmod -R u+w`, `rm -rf` with three attempts,
and if the root still exists it SAYS so on stderr instead of leaving it silently.
What the row does now, in order: `wa-sentinel stop`, `kill $NODE_PID`, up to 10 rounds of TERM on every process whose
environment or command line names THIS row's scratch root (never a process name - rule 17), the worktree removal,
`chmod -R u+w`, `rm -rf` three times, and a named line on stderr when the root survives.

Verification, and its limit, said plainly:

* the product's own `cleanup` function, EXTRACTED from the row by its own text (`sed -n '/^cleanup() {/,/^}$/p'`) and
  sourced into a harness, with a decoy process running that carries `WA_SOMETHING=$W` in its environment: before the
  change the decoy survived and `rm -rf` reported "Directory not empty"; after it, `cleanup exit=0; W exists: no;
  decoy alive: no`;
* the row itself SKIPs on this machine - `SKIP test-deploy-covering-release: the installed sentinel will not report
  itself watching in a scratch home ...: <W>/home/install/wa-sentinel: No such file or directory`, exit 3 - so the
  end-to-end deploy -> sentinel -> teardown path was NOT measured here. The skip's own cleanup ran (root removed, no
  message, stderr empty); what was not exercised on this machine is the shape where a REAL sentinel and its node are
  still writing into `$W` at teardown. The extraction harness above is what stands in for it, and it is the same
  bytes.
* the transient-pid noise the first version printed (`/proc/<pid>/environ: No such file or directory`) is silenced by
  redirecting the group, not each command - a pid that exits between `ps` and the read makes the shell's own
  redirection fail, which `2>/dev/null` on the command does not cover (measured while writing this).

## Where items 2 and 3 are (no repository commit)

Both live in the orchestrator's own files under `~/Work/missions/_orch/`, which are outside this repository, so they
cannot be a commit and are not in the git tree. They are ADDITIONS beside the live ones, so nothing the orchestrator is
running changes until it chooses to:

* `_orch/row-runner14.sh` = row-runner13.sh + a monotonic `seq` per row (the mission's own counter under
  `rows/.seq.lock`, written to `rows/<id>/seq` and into `result.txt`), and a `--dry-run <mission>` mode.
* `_orch/deliver-row-verdict4.sh` = deliver-row-verdict3.sh rewritten around that seq: it keeps the highest delivered
  sequence in `<mission>/.verdict-seq-delivered` and forwards only verdicts above it, in ascending order, holding a
  later verdict until its predecessor has landed (a gap is waited for, never skipped past with the watermark).

Simulations, run here (`WA_ROW_RUNNER_ROOT` points them at a scratch mission root; `resume-when-idle.sh` is a stub that
records the file it was handed):

* three verdicts, seq 1, 2, 3: delivered ONCE, in that order, watermark 3, one resume;
* the same call again: nothing delivered (the 8 s bound killed it), no second verdict file, no second resume;
* 4 and 6 present, 5 still running: nothing delivered, the watermark stays 3;
* 5 lands: 4, 5, 6 delivered in order, watermark 6.

`row-runner14.sh --dry-run fsi`, five cases, nothing written into the mission root:

* no `row-request.txt` -> `dry-run: no row-request.txt for fsi (nothing would run)`, exit 3;
* a good request -> `WOULD RUN scripts/test.sh @ 70eb209d`, args, timeout, `program: /home/victor/.local/bin/wa - the
  installed wa (compiled inputs equal: 096106a3...)`, the scratch root shape, exit 0;
* a row not in the commit -> `WOULD REFUSE: scripts/test-not-a-row.sh is not in 70eb209d`, exit 2;
* a commit the checkout does not have -> `WOULD REFUSE: the checkout does not have commit 01234567...`, exit 2;
* `row=../etc/passwd` -> `WOULD REFUSE: row must be scripts/<name>.sh|.lua`, exit 2.

Moved them by hand into `_orch/` as `row-runner14.sh` and `deliver-row-verdict4.sh`; nothing renamed `row-runner13.sh`
away, because the orchestrator is running the v0.1.2 cut through it.

## Checks run

* `scripts/test-deploy-release-honest.lua` (WA_SCRIPT on the installed `wa`, scratch home): `deploy release ok (106
  checks)`. RED on the base as quoted above.
* `scripts/test-installer-doors.sh`: `installer doors ok (15 checks)`. RED on the base as quoted above.
* `scripts/test-deploy-release-node.sh` (a real scratch node, one process pair, a real turn in flight):
  `deploy-release-node ok: a real scratch node decides the release line from the INSTALLED RECORD - installed after a
  scripts-only install, did-not-happen when the marker goes and nothing was installed` (9 ok lines, including `the
  ledger row says '[deploy] installed', naming the new tree commit bbbb5555eeee`). So the new installed line still
  carries the words and the tree that row reads.
* `scripts/test-deploy-target.sh`: `deploy target ok (14 checks)` after fdd404be.
* `scripts/test-deploy-covering-release.sh`: SKIP on this machine (exit 3, reason quoted above); its first pass built a
  `node-70eb209d0c5c` stub release here and its pre-swap assertions were green before the skip.
* items 2 and 3 (operator files): the simulations quoted above, run against a scratch mission root.
* NOT run: `scripts/test.sh` whole (the landing's gate runs it), the full fast path, and any cargo build (the cut was
  building; nothing here changes rust).

## Texts to approve (every new or changed operator/model-facing string, verbatim)

1. `[deploy] installed: this node now runs program <program>, tree <tree> (was program <was-program>, tree <was-tree>).`
   - the installed line (was: `[deploy] installed: this node now runs <tree> (was <tree>).`)
2. `not recorded` - what that line prints for a field the pause record does not hold (was `unknown`).
3. `dry-run: no row-request.txt for <mission> (nothing would run)`
4. `dry-run: WOULD RUN <row> @ <commit>`, then `<two spaces>args: <args|(none)>`, `timeout: <n> s`,
   `program: <path> - <why>`, `scratch root: <root> (own HOME, install, units, tmp, bin; two free ports)`,
   `fetches: <mission>/wt <commit>; origin/main stub: <commit>`,
   `refusal before it starts if scratch-guard is NOT ISOLATED, or the build for this commit fails (build.log)`
5. `dry-run: WOULD REFUSE: <reason>` (reasons verbatim: `row must be scripts/<name>.sh|.lua (got '<row>')`,
   `no commit= in the request`, `the checkout does not have commit <sha> (fetch the branch first; the runner fetches
   from <mission>/wt)`, `<row> is not in <commit>`)
6. `dry-run: note: needs=gh but gh is not on this PATH`, `dry-run: note: origin_main=<sha> is not in the checkout`
7. `[orchestrator] runner verdict(s) since your last turn (in the order the rows ran):` (was: `... runner verdict(s)
   since your last turn:`)
8. `covering-release: the scratch root was NOT removed (<root> still holds: <names>); a process this row started still
   names it`

The unchanged ones this branch still prints: `[deploy] the update did not happen: nothing was installed ...`,
`[deploy] the pause ended: this node runs <tree>. ...`, `[deploy] installed`'s three closing lines, and `installer
refused(...)` messages (their wording is untouched).

