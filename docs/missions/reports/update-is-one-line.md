# update-is-one-line - `wa update` is ONE line that moves, and ONE last line that says what happened

Branch `change/update-is-one-line` (worktree `/home/victor/Work/missions/update-is-one-line/wt`), base
`origin/main` = `70eb209d`. Week 1 after v0.1.2, Victor's complaint: "wa update still far from mise upgrade
claude ux which is just like 1 line seeker showing progress and eventually error. wa update is thousands of
lines and many errors".

**Status: steps 1-4 and 6 are in the branch; steps 7-8 are measured; step 5 is answered below; step 9 (every
wait on an event) is NOT done and is listed as open with the exact list of sleeps. The remote case (d) is NOT
measured yet.**

| commit | what |
| --- | --- |
| `20722a12` | the screen (`lua/core/update_screen.lua`), one last line, one log per update, `--verbose`, the release-queue fix, the rewritten row |
| `2b0cb3ca` | `update.up_to_date`: "already up to date" without a deploy, a fetch or the sentinel |

## What was measured, and how

`measure/update-output/update-lines.sh` builds a scratch node (own `HOME`, own `WASM_AGENT_DATA`, own install
directory, stub sentinel, stub deploy) and drives the REAL `wa update` through it, once on a pipe with every
line timestamped on arrival and once on a pty. The stub deploy writes the shapes a real deploy writes
(`build-status.json`, `sentinel/queue/<id>.json`, `deploy-result.json`, `installed.txt`) and a `deploy.out` of
**7001 lines, 411 of them matching error|warn|refused|fail** - the shape Fable measured on `work` (7571 lines,
225 alarming) on 25/11. `BEFORE.txt` and `NOW.txt` in that directory hold the two runs verbatim.

### Step 1 - the measurement (the whole point of doing it first)

| case | BEFORE: lines printed | of them alarming | first line | last line | exit | NOW: lines | first line | last line | exit |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| (a) tree install, download (published) | 6 | 1 | 1.55 s | 3.74 s | 0 | 4 | 0.22 s | 2.80 s | 0 |
| (b) tree install, compile | 9 | 1 | 1.52 s | 6.84 s | 0 | 7 | 0.29 s | 5.93 s | 0 |
| (c) release-installed, already current | 5 | 2 | 0.63 s | **never** (1800 s bound) | **1** | 2 | 0.34 s | 0.50 s | 0 |
| (c') release-installed, newer bundle queued | 6 | 2 | 0.37 s | **never** (1800 s bound) | **1** | 3 | 0.24 s | 0.46 s | 0 |
| (e) fails before the swap | 18 | 4 | 1.43 s | 6.95 s | 1 | 7 | 0.24 s | 6.00 s | 1 |
| (f) installs with a problem | 18 | 3 | 1.21 s | 6.87 s | 1 | 7 | 0.27 s | 6.05 s | 1 |
| tree node already at the installed commit | 6 (**queued a full deploy**) | 1 | 0.62 s | 2.69 s | 0 | **2** | 0.30 s | **0.36 s** | 0 |

**The brief's first premise was wrong, and it changes the job.** "225 of those lines match error/..." - TRUE
of `sentinel/deploy.out`, and **none of them reached the terminal**: the old follower printed at most the
installer's last EIGHT lines, and only on a failure. The 7571 lines Victor calls "thousands of lines" never
reached his screen; what he read was 6-18 short lines per command, and what made it feel like a wall was
that every one of them was a sentence of advice (`next:`, `following: Ctrl-C stops...`, `queued:`, the plan
line), printed anew on every run, none of them the answer to "did it work?".

Three defects the measurement found that nobody had named:

1. **A tree node at the installed commit queued a full deploy** - build, the whole test suite, the swap -
   after a `git fetch`, a sentinel `preflight` and a store backup. `verdict()` compares nothing; there was no
   "already current" answer anywhere on the path.
2. **A release node followed a sentinel request that a release update never writes.** `wa update` printed
   "this node already runs the newest published bundle; nothing to do", then followed, then said
   "stopped following after 1800 s: the sentinel has not started this request" and **exited 1**. On a
   release node every `wa update` ended in an invented failure half an hour later.
3. **`installed_with_problems` printed `next: this node still runs <the commit it had just installed>`** and
   exited 1 without saying what the problem was.

### Step 2-4 - the screen (what is in the branch)

`lua/core/update_screen.lua` owns what the person sees, and it decides nothing:

* **a terminal** (`host.isatty("stdout")`): one line, rewritten in place with `\r` + erase-to-end-of-line.
  Measured on a pty: 9 carriage returns and 7 escape bytes for the compile case, and the run leaves **2
  lines** behind (what happened, and the log).
* **a pipe, a mission, a chat turn**: no rewriting - one line per phase CHANGE (a change of body, never a
  change of clock) and the last line. Measured: 7 lines for a compile install, 4 for a download.
* the installer's own words go to ONE log file per update (`<config>/update-log/<request id>.log`, written
  from the deploy's own section of `deploy.out`), named in the last line; `--verbose` streams them live and
  prints the notes the quiet screen drops.

### Step 5 - every alarming line during a SUCCESSFUL install, with a verdict

Measured on the compile and download cases, old path and new:

| line (old path) | where it came from | verdict |
| --- | --- | --- |
| `no published binary is named for <sha> here: the installer looks for one built from the same inputs, and builds from source only if there is none (minutes)` | the plan line (`update_follow.plan`) | **noise**: true, but it reads as a failure and is not needed before the install talks. Removed from the screen (a `--verbose` note). |
| `next: ... lands in <config>/sentinel/done/ or failed/, and installed.txt records the commit it installed.` | the queue sentence's advice | **noise**: matched the alarm filter on the word `failed/` in a path. Removed from the screen (`--verbose`). |
| `following: Ctrl-C stops following; the install continues (wa update --follow re-attaches)` | the follower | **noise**: advice on every run. Removed from the screen (`--verbose`). |
| `failed: ... ` + the installer's last 8 lines (6 of them `Compiling crate-N`) | the failure path | **a real problem**, correctly shown - and now shown as ONE line with the reason, with the 8 lines in the named log. |
| `installed <sha>, with 1 problem(s): <detail>` followed by `next: this node still runs <sha>` | the follower | **a real problem badly worded**: the detail was there but buried after `problem(s)`, and "still runs <the commit just installed>" was false. Now: `installed <sha>, with 1 problem: <detail>` and no `next:` line. |

On a successful install the NEW path prints **0** alarming lines (measured: 0 in the compile and download
cases).

### Step 6 - the rows

`scripts/test-update-follow.sh` (already wired at `scripts/test.sh:1102`) was rewritten to the new output.
**No assertion was dropped**: each old assertion's FACT is still asserted, in the new words.

* case 1b (new): already up to date - **two** lines, exit 0, the sentinel is called **not at all** (the stub
  now records every call), no `git fetch`, and the row fails past 2000 ms. Measured: **390 ms**.
* case 2: first line is the work starting; one line per phase; the build declared once with its n/m and its
  clock; the last line names the commit and the time; the last line names an existing log that holds the
  deploy block and the installer's own last lines; **no** installer line and **no** advice on the screen.
* case 2b (new): a terminal gets `\r` + erase and is left with **2** lines; a pipe gets neither.
* case 3: the published path says `installing the published binary (no build)`, no bar, no build claim.
* case 4: a failure is ONE line (`not updated: <reason>. Nothing was changed.`) naming a log that holds the
  installer's own refusal (`refused(no_built_binary)`).
* case 5: an unstarted request ends on one line saying it is still queued, exit 1.
* case 6: `--detach` returns in 0-1 s and names the command that re-attaches.
* case 7: `--follow` attaches and prints the last line.
* case 8 (new): `--verbose` prints the notes (`queued: the sentinel will deploy`, `following: Ctrl-C ...`).

Run: `TMPDIR=/tmp WA_BIN=<wa> bash scripts/test-update-follow.sh` -> `update follow ok`, all cases green on
this node (AVell, 25/11). NOT run on the base: the base has no `update.up_to_date` and no screen, so cases 1b,
2, 2b, 3, 4, 5, 7 and 8 all fail there by construction - the land gate's `scripts/test-discriminates.sh` is
what should confirm it, and it has not been run.

### Step 7-8 - the time, and the budgets

| budget | measured | met? |
| --- | --- | --- |
| first line on the screen under 100 ms | **220-300 ms**, and all of it is the CLI boot (the binary plus the Lua interpreter loading `lua/core/init.lua` and its modules); the screen is opened before any read, fetch or sentinel call | **NO** - see open item 1 |
| "already up to date": under 1 s, ONE request, no git fetch, no sentinel round trip | **362-390 ms** end to end, ONE `git ls-remote`, **0** `git fetch`, **0** sentinel calls, no backup | **YES** |
| a download update, files local: under 3 s to the last line | 2.80 s on the fixture, of which 1.2 s is the fixture's own pause between phases; a real install's own 48.5 s (measured on `work`) is the rest | **YES on the fixture / the install itself is the rest** - and with version folders the rest becomes the pointer switch (1.7 ms) plus the node start (0.8 s), both measured elsewhere |
| what runs before the first line | BEFORE: 9-10 git calls including `git fetch --quiet origin`, one sentinel `preflight`, the pre-update backup of every store, then the request. NOW: nothing - the line is printed above the first read | measured |

### Step 9 - every sleep and poll interval on the path

**NOT done: no wait on this path is event-driven yet.** The list, as the brief asks:

* `lua/core/update_follow.lua`: `M.POLL = 1` s - the follower re-reads the deploy's files once a second
  (`host.sleep`); `M.HEARTBEAT = 30` s - an unchanged phase is repeated at that interval and only then;
  `M.UNPERFORMED_BOUND = 1800` s (the installer's own idle bound, `WA_DEPLOY_IDLE_BOUND`) - how long a
  request the sentinel never starts is followed.
* the release path: no wait at all (it queues a `systemd-run` unit and returns).
* the fast path: `timeout 5` on the one `git ls-remote` (a bound, not a sleep).
* `lua/core/update.lua` `check`: `CHECK_COMPONENTS_SECONDS = 10` on the components question, and the release
  list's own refresh bound (`update_banner.REFRESH_SECONDS`).

The replacement is an `inotifywait` on the sentinel's directory and on `build-status.json` (inotify-tools is
installed here: `inotifywait 4.26.270`), with the 1 s poll kept only where inotify is absent, and said so.

## Texts to approve (every one is a line a person reads)

1. `checking for updates  0:00` - the first line, on the screen before any work.
2. `building 48/456 compiling wa-host (from source, on this machine)  0:04` - a compile phase (n/m, its
   source, the clock).
3. `installing the published binary (no build)  0:02` - the download phase.
4. `installer started: deploy started detached  0:01` - the sentinel spawned the installer and said nothing
   more yet.
5. `updated to v0.1.2 (8f755686) in 0:05` - the install finished (the version the installed commit declares;
   when the tree cannot answer, `updated to 8f755686 in 0:05`).
6. `already up to date (81c8c6cc)` - nothing to do, and no deploy was started.
7. `installed ff82cbf4, with 1 problem: the sentinel could not be restarted after the swap` - it installed and
   something else did not.
8. `not updated: compiling: no built binary at <path>. Nothing was changed.` - it did not install, one
   sentence, and the promise.
9. `not updated: this deploy is still queued: the sentinel has not started it (<what it last said>)` +
   `. Nothing was changed.` - the bound ended the follow and the request is still in the box.
10. `not updated: the install is queued as wa-release-update-1795638837 and had not reported when this command
    ended. Nothing was changed.` - a release install, which this command cannot watch.
11. `log: <path>` - the last line, always.
12. `detached: the install continues without this terminal; wa update --follow re-attaches` - `--detach`.
13. `--verbose` only: the old notes, unchanged (`no published binary is named for <sha> here: ...`, `queued:
    the sentinel will deploy ...`, `next: ...`, `following: Ctrl-C stops following; ...`).

The ONE spelling of the version line (Fable's 25/11 addition): `v0.1.2 · 1857d15` - the version, then EIGHT
characters of the commit, whether the install came from a release (`node-1857d15887c`) or was compiled
(`va1857d15`); `update_screen.identity` strips either prefix. It is used by the update line in parentheses
(`updated to v0.1.2 (1857d158)`) and is what `wa --version` should print.

## Open items (named, not hidden)

1. **First line at 220-300 ms, not 100 ms.** The cost is the CLI's own boot (`wa` + the Lua interpreter +
   `lua/core/init.lua`'s modules). Nothing of the update runs before the line. To get under 100 ms the binary
   would have to print it from Rust before the interpreter boots (`rust/wa-host`), which needs its own review:
   it must not print for `--check`, `--all`, `--follow`, `<node>` or a child shell that will refuse anyway.
2. **Step 9 (event-driven waits) is not implemented** - see the list above; `inotifywait` is the plan.
3. **Case (d) `wa update <node>` from another node is NOT measured.** Its row is
   `scripts/test-tree-peer-remote-update.sh`, which builds a release binary from its own checkout: it belongs
   to the orchestrator's row runner (installer rows go through it) and was not run in this session.
4. **`installed_with_problems` still exits 1.** The line now says the install happened; the exit code says
   "not a clean 0". Fable decides which one a script should see.
5. **`wa --version` is untouched.** It still prints `wasm-agent v0.1.2 · va1857d15 · tree 70eb209d`, which
   names the running build and the tree it runs from - but the release-install spelling of the same fact
   (`node-1857d15887c`) is a different string, and the mission's added item 2 asks for one spelling plus the
   install record's identity when they differ.
6. **`<config>/update-log/` has no retention.** One file per update (a few KB now that the section is copied
   from `deploy.out`; 448 KB for a 7001-line build). A prune (the newest N) is a follow-up, or the sentinel's
   own retention rules should own the directory.
7. **A fast install can lose the last line** (found by the first fixture run, before the screen): if the
   installer's `declared` line and its terminal state are seen in the same 1 s round, the old follower printed
   the declaration and returned without the final line. The screen path does not have that shape (the terminal
   snapshot draws nothing and the caller prints the last line), so it is fixed for `wa update`, not for a raw
   `update_follow.follow` caller.
8. **Test isolation**: the row writes only scratch homes (guarded by `scripts/lib/scratch-home.sh`) and its
   pty case runs `script -qec`; nothing in it reaches a fleet node. `TMPDIR` must be outside
   `~/.wasm-agent` - the guard refuses otherwise, which cost one run here.
9. **Pre-existing failures**: none found; the row was green on this branch, and its base behaviour was
   recorded (BEFORE.txt) rather than re-run.
