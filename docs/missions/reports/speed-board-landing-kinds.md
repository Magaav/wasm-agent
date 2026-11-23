# speed-board-landing-kinds (23/11)

A speed row is judged only against its own kind, and only when three comparable points exist.
Branch `change/speed-board-landing-kinds`, base `85593e74`.

## The rules now, and the commit that implements each

1. **A verdict needs three comparable points** - `dfd43c75` (`scripts/lib/speed-stats.lua`,
   `M.MIN_COMPARABLE = 3`). Below the floor a row is `no_baseline` with the count and no verdict at
   all: `no_baseline: 2 of 3 comparable points`. A hole (unavailable/guarded/unknown) and a number taken
   at another load are still not points, so they do not count toward the three either.
2. **A landing is judged within its own kind** - `dfd43c75` (`M.LANDING_KINDS` is the allow-list:
   `scripts`, `lua`, `rust`, `held`) and `9708b449` (`scripts/speed-board.sh` reads `.kind` from
   the landing record). The kinds are what land-quick DID, not what the branch looks like from a diff:
   - `scripts` - nothing the node runs changed (`lua/ rust/ ui/ web/ assets/`): checkout fast-forwarded, no deploy;
   - `lua` - a deploy of a branch that touched no `rust/`;
   - `rust` - a deploy of a branch that changed `rust/` (the install had to build the binary);
   - `held` - `LQ_NO_INSTALL=1`: main moved, nothing installed.
3. **Old lines are not comparable, and they are shown as such** - `dfd43c75`. The 20 lines in
   `~/Work/missions/speed-history.jsonl` today carry **zero** kinds (measured: 19 with an ok landing,
   0 with a kind; landing ms spread 2000 -> 580000). They are never a baseline, and the table says so:
   `no_baseline: 0 of 3 comparable points (landing kind lua); 19 line(s) in the window carry no kind and
   are not comparable`. A landing ROW recorded without a kind (an old-format record) prints its number and
   `no_baseline: the landing record carries no kind (written before kinds, 23/11)`.
4. **The machine's verdict line shows the kind** - `9708b449`: `landing=42000ms@1.1/lua`, and
   `/nokind` when the record has none.
5. **Nothing the model reads changed.** No tool description, capability text, prompt or `docs/HOST.md`
   text is in the diff (`git diff 85593e74..HEAD -- lua/ rust/ docs/HOST.md` is empty); the speed table and
   the main-health line are operator-facing.

## main-health: which binary the live rows run, and the 4b314af5 hour

`992fc457` (`scripts/main-health.sh`). The speed block runs at the END of a health run that takes ~20
minutes, and it used to resolve the binary by running `fast_binary_plan` again, then fall back to
`installed.txt`.

**What 3655948d is, and why installed.txt named it.** `3655948d` is "land-quick: merge
change/esc-stops-now", a landing on main (git: 4b314af5 is an ancestor of 3655948d, `git rev-list --count
3655948d..4b314af5` = 0; 09:41 vs 09:52). Main-health started on 4b314af5 at ~09:43 and finished at
10:03; the landing of 3655948d happened while it ran, and `deploy.sh` writes `installed.txt` as the FINAL
record of a deploy - so at 10:03 the file named the landing that had just installed, not the tree being
measured. The premise in the brief ("the install lags main by landings") was backwards in this instance:
the install was AHEAD of the measured tip. That is the whole trap: `installed.txt` is a statement about
the last install that FINISHED, never about this commit's bytes.

So the binary now comes from the run's own record, in this order, and the line names the source:

1. `fast-result-<sha>.json` -> `env.bin` + `env.commit` + `env.bin_sha256` (written by `scripts/fast.sh:420`,
   assembled by `scripts/fast-result.mjs`), used only while `sha256sum "$bin"` still equals the recorded
   hash: a path whose bytes changed is another build and is refused by name, never measured as this commit;
2. `fast_binary_plan` in the tree (a stamp that is `$sha`), as before;
3. `installed.txt` naming this commit (the old rule), as before;
4. none - and then the four live rows are RED with the reason beside them.

`scripts/test-main-health.sh` case 10 is the coverage the brief asked for ("fast reused the installed
binary"): the fixture's fast result names the installed stub, the stub refuses the identity probe (the
shape 4b314af5 failed in), `installed.txt` names another commit - and the board is still handed that
binary. It fails on the base: `FAILED: the binary fast.sh ran was not handed to the board`. Its second
half appends bytes to that path and pins the old hash: the same run is then handed **no** `--bin` and says
`another build replaced it while this run measured`.

## The flake on 41d6420c (test-speed-board, "5 FAIL of 30")

`9708b449`. I could NOT reproduce the five failures: on this node the row is 2.3 s and green alone
(`speed-board ok (30 checks)`), and the fast log keeps nothing about which checks failed. What I did find,
and fixed, is the only machine-dependent input the row had:

- **It read the operator's records.** The board takes the landing record and the release journal from
  `$HOME`, and the row only pinned its own `HOME` for ONE of its cases; every other call read
  `~/Work/missions/_quick/landings.jsonl` and `~/.wasm-agent/land/release-*`. Every call now runs with
  `HOME` and `WA_SPEED_LANDINGS` pointed at the test's own scratch files, so no answer of this row depends
  on what the machine was doing.
- **A failed Lua row left no evidence at all** - this is why nobody could see the five. `failed_rows`
  is filled by `check()`, the SHELL row recorder, so a Lua row's log was never copied and
  `fast-logs-41d6420c3629/` held an empty `failures.txt`. `ce30d707` (`scripts/fast.sh`) makes
  `wa_fast_row_logs` read the runner's own table (`$work/lua.tsv`: exit, ms, script, line, kind) in
  addition to the named rows, de-duplicated; the row itself now also prints `FAIL speed-board: N of M checks
  failed` and `scratch kept for diagnosis: <dir>`, the two shapes the runner collects.
  `scripts/test-fast-skip-count.sh` has the case ("a failed Lua row that nothing named"), and it fails on
  the base (`a failed Lua row that nothing named had its log dropped`).

**Not verified:** that the five failures were caused by the operator's records. The row is now independent
of them, and the next red will name its own checks; if it goes red again the evidence exists.

## test-codemode-errors at load 27

`60f2e24e`. Time-bound, and measured: the same endless loop answers `InternalError: interrupted` with a
`timeout_ms` of 1, 10 and 50 ms, and `TimeoutError: the script was stopped while computing` from 100 ms
upward - the instruction guard stopping it after 0.06-0.17 s of COMPUTING. `timeout_ms=300` sat 3x from
that boundary, so a loaded machine could land on the other shape. The budget is 3000 ms now (a 20x margin
over the guard's own stop), which makes the sentence under test independent of the machine's wall clock.
Run green alone (10 checks) and green at an artificial load of 7.3 (24 spinners, this script's own pids,
stopped in its trap).

## Tests, and where they are wired

| row | what it pins | wired |
| --- | --- | --- |
| `scripts/test-speed-stats.lua` (50 -> 64 checks) | one or two comparable points never make RED; the count in the reason; a lua install is never compared with scripts landings (0 of 3 of that kind); a kind-less line is counted and named; deltas say "landing kind differs" | fast path, every `scripts/test-*.lua` not in `scripts/fast-path.exclude` |
| `scripts/test-speed-board.lua` (30 -> 48 checks) | the end-to-end path: 2 points are not a verdict, 3 are; the line carries `/kind`; a 288 s install is not RED against 2 s scripts landings; a record with no kind has no verdict; every call is hermetic | same |
| `scripts/test-main-health.sh` (32 -> 36 checks) | the binary comes from the run's own fast result, and a changed path is refused by name | `check main-health` in `scripts/fast.sh:1202` |
| `scripts/test-fast-skip-count.sh` | a failed Lua row's log survives the run even when nothing named it | `check fast-counters`-style shell row, `scripts/fast.sh:987` region and `scripts/test.sh` |
| `scripts/test-codemode-errors.lua` (10 checks) | the CPU-stop sentence, now at a budget the guard wins | fast path |

Each of the two Lua rows was run on the base (`git worktree add --detach <tmp> 85593e74`) with the new
test file in place, and fails there on the new assertions.

## Checks I ran (this node, avell)

- `scripts/test-speed-stats.lua`: `speed-stats ok (64 checks)`.
- `scripts/test-speed-board.lua`: `speed-board ok (48 checks)`.
- `scripts/test-main-health.sh`: `test-main-health ok (36 checks)`; on the base: fails at case 10.
- `scripts/test-fast-skip-count.sh`: ok; on the base: fails on the new Lua-row case.
- `scripts/test-codemode-errors.lua`: `{"checks":10,"ok":true}` alone and at load 7.3.
- `flock -o ~/Work/missions/.suite.lock env WA_FAST_ROWS=<the three Lua rows above> bash scripts/fast.sh`
  (the G-wave narrowed run; its result is in the session report below).

**Not run, by the G-wave rule:** the full suite, `scripts/test.sh`, `scripts/preflight.sh`,
`wa land --until gate`. main-health on main is the orchestrator's, after the landing.

## Premises from the brief that were wrong or stale

- "installed.txt records the commit in the 8 characters `wa install` writes": it wrote a 40-character
  commit (`commit=85593e7496a67d77ee2f4df03c4ac43faf5a471e` in this node's file at 18:11Z). The prefix
  comparison in `scripts/main-health.sh` is correct for both, and the comment there says so.
- "the install lags main by landings": on 4b314af5 it was AHEAD (see above).
- `~/Work/missions/speed-history.jsonl` holds 20 lines, not the "eight commits of unavailable after
  8862b600" of the earlier note (that history has since been rewritten), and none has a kind.

## What this changes for Victor's test, stated plainly

After this lands, the landing row has **no verdict** until three landings of one kind exist in the
history: the 20 old lines carry no kind and cannot be a baseline. Two landings from now the row will read
`0 of 3` or `1 of 3 comparable points (landing kind lua)` - no RED, and the reason printed. Three
install landings after this one, the row becomes a verdict; and a scripts-only landing will never be
compared with an install, so the 2000 ms against 288000 ms flap is gone by construction.

## Factory script changes (applied by the orchestrator)

`~/Work/missions/land-quick.sh` is outside this tree; the orchestrator applied the change below at 18:32Z
(backup: `land-quick.sh.bak-20261123T183123Z`). It is the producer half: only the landing knows which
install it ran.

```diff
--- land-quick.sh.bak-20261123T183123Z
+++ land-quick.sh
@@ -21,11 +21,12 @@
-record_landing() {
+record_landing() { # <kind: scripts|lua|rust|held> - what this landing DID, recorded with it.
+  local kind=${1:-none}
   local seconds=$(( $(date +%s) - started_at ))
   mkdir -p "$M/_quick" 2>/dev/null || return 0
-  printf '{"branch":"%s","sha":"%s","seconds":%s,"load":%s,"at":"%s"}\n' "$branch" "$tip" "$seconds" \
-    "$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)" "$(date -u +%FT%TZ)" >> "$M/_quick/landings.jsonl" 2>/dev/null || true
+  printf '{"branch":"%s","sha":"%s","seconds":%s,"load":%s,"kind":"%s","at":"%s"}\n' "$branch" "$tip" "$seconds" \
+    "$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)" "$kind" "$(date -u +%FT%TZ)" >> "$M/_quick/landings.jsonl" 2>/dev/null || true
 }
@@ -84,6 +88,9 @@
 if [ "${LQ_NO_INSTALL:-}" = 1 ]; then
   (cd "$R" && git merge -q --ff-only origin/main) || stop "main is $tip but the checkout could not be fast-forwarded"
+  # A HELD INSTALL IS STILL A LANDING, and its cost is main moving with nothing installed: recorded, so
+  # the board says so instead of comparing it with a deploy (kind held is never a baseline for lua).
+  record_landing held
   say "main is $tip; INSTALL HELD (LQ_NO_INSTALL=1): run install-local.sh when what it needs is published"
   exit 0
 fi
@@ -94,14 +101,16 @@
   { echo "- $name ($tip, land-quick $(date +%d/%m\ %H:%M), scripts/docs only - no deploy needed): ${how:-see docs/missions/reports/$name.md}"; echo "  state: untested"; } >> "$M/LOCAL-CHANGELOG.md"
-  record_landing
+  record_landing scripts
   say "Local is evolved to $tip (scripts/docs only: no deploy). You can now test: $name"
   exit 0
 fi
 if bash "$M/install-local.sh" "land-quick $name"; then
   { echo "- $name ($tip, land-quick $(date +%d/%m\ %H:%M)): ${how:-see docs/missions/reports/$name.md}"; echo "  state: untested"; } >> "$M/LOCAL-CHANGELOG.md"
-  record_landing
+  # install-local ran and succeeded: the kind says whether it had to build the binary ($rust is this
+  # script own count of the branch rust/ files, the same one that decided its Lua tests must wait).
+  if [ "$rust" -gt 0 ]; then record_landing rust; else record_landing lua; fi
   say "Local is evolved to $tip. You can now test: $name"
   echo "$how" | sed 's/^/    /'
 else
```

What it means, and what it does not: `scripts` is decided by the same `$runs` count that already decided
"no deploy needed", `rust` vs `lua` by the same `$rust` count that already decided the branch's Lua
tests must wait for the install, and `held` is the `LQ_NO_INSTALL=1` exit that used to record nothing.
No new measurement, no guessing from a diff. A record written before this change has no kind, and the
board treats it as uncomparable rather than assuming one.

## Texts to approve (every new or changed operator-facing string, verbatim)

speed-stats table / verdict (`scripts/lib/speed-stats.lua`):
1. `no_baseline: <N> of 3 comparable points`
2. `no_baseline: <N> of 3 comparable points (landing kind <scripts|lua|rust|held>)`
3. `no_baseline: the landing record carries no kind (written before kinds, 23/11)`
4. `ok (<N> comparable points)` / `ok (landing kind <kind>, <N> comparable points)`
5. `; <N> line(s) in the window carry no kind and are not comparable`
6. `+x.x% (landing kind differs)` beside the delta column (the existing `(load differs)` stays)

speed-board line (`scripts/speed-board.sh`):
7. `landing=<ms>ms@<load>/<kind>` and `landing=<ms>ms@<load>/nokind`

main-health (`scripts/main-health.sh`), stderr:
8. `main-health: speed binary <path> (source: the binary this run's fast path proved for <sha12> (sha256 <hash12>))`
9. `main-health: speed binary <path> (source: the tree's own binary, by its stamp (scripts/lib/fast-binary.sh))`
10. `main-health: speed binary <path> (source: the installed node, and installed.txt names this commit)`
11. `main-health: speed binary (none: no binary of <sha12> on this machine - <reason>, so the four live rows are RED)`
    with `<reason>` one of: `the binary the fast path used (<path>) was sha256 <a> and is now <b>: another build
    replaced it while this run measured`; `the fast run recorded no sha256 for <path>, so its bytes cannot be
    shown to be <sha12>`; `sha256sum is not on PATH, so the fast run's binary (<path>) cannot be shown to be
    the bytes it graded`; `the binary of the fast run (<path>) is gone, or its commit (<sha12>) is not <sha12>`

test-speed-board (a failing run):
12. `FAIL speed-board: <N> of <M> checks failed`
13. `scratch kept for diagnosis: <dir>`

## FACTORY.md - proposed, not written

Under Rule 8 ("main is always green"), after the status.sh line:

> - A speed row's verdict needs **three comparable points**: same row, same load band and - for the landing
>   row - the same landing KIND (`scripts`, `lua`, `rust`, `held`, written by land-quick itself). Fewer
>   than three is `no_baseline` with the count, never RED: one point is one sample of the machine.
> - A board row that could not measure says why, and its evidence (the failing row's own log) is kept by the
>   runner - a red whose cause is gone by the time anyone reads it costs a second full run.

## HANDOVER.md - proposed, not written

> **Speed board (23/11):** a row is judged only within its kind and only with 3 comparable points; the
> landing row carries `kind` (`scripts`/`lua`/`rust`/`held`) from land-quick's own record, and the 20
> history lines written before this carry none, so the landing row reads `no_baseline` with the count until
> three landings of one kind exist. main-health now hands the board the binary **fast.sh itself ran**
> (`env.bin` + `env.commit` + `env.bin_sha256` from the run's result), refuses a path whose bytes changed,
> and prints where the binary came from - `installed.txt` names the last install that finished, which can be
> older OR newer than the tip being measured.
