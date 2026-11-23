# speed-board-gets-a-binary: main gets a number for every live row, and a row with no number is RED

change/speed-board-gets-a-binary, 23/11. Base a0bb0262. Built and tested in
`/home/victor/Work/missions/speed-board-gets-a-binary/wt`.

## What the brief asked for, re-measured first (rule 9)

| premise | measured 23/11 | verdict |
| --- | --- | --- |
| main-health calls the speed board with `--bin` when the installed binary is the tip | `git show a0bb0262:scripts/main-health.sh` line 116 is the guard `[ -n "$speed_installed" ] && [ "${sha#$speed_installed}" = "" ] && [ -x "$HOME/.local/bin/wa" ]`. `sha` is 40 characters (`git rev-parse --verify main`) and `~/.local/bin/installed.txt` carries 8 (`commit=37b64227`), so `${sha#$speed_installed}` is the remaining 32 characters and is never `""` | **WRONG - it could never fire.** Measured on this node: `installed.txt` named `37b64227` and main WAS `37b6422774e7`, and the old test still refused it. That bug alone explains every `unavailable` line written while the installed node already was the tip |
| main-health has a binary of the tip at hand after its own fast run | `scripts/fast.sh:154` (`fast_binary_plan`) and `scripts/fast.sh:179` (`fast_binary_build`) BUILD this tree's own binary, stamped with the commit, at the path `scripts/lib/fast-binary.sh` resolves. Measured in this mission's end-to-end run: `fast: binary /home/victor/wasm-agent/target/m-speed-board-gets-a-binary/release/wa (sha256 cf53b27802f0e2242b6962e071058ac53e72ff2b15a1f7950c7b90dff7b8b476)` | true, and it is the binary main-health now asks for |
| the four live rows read `unavailable` on main | `~/Work/missions/speed-history.jsonl`: 8 of its 10 lines. The four live rows are `unavailable` for 071d1ab5, 899fdd47, fe60dc0a, 3665b1b7, e9a42d20, da912828, ae3cbb37 (8862b600 and bfb06cc4 have numbers) | true |
| a board with no numbers read as fine | base `scripts/lib/speed-stats.lua:145-146`: a row that is not `ok` is printed with its state and reason and nothing more; only the `else` branch (a row with a number) can set `red`. Base `scripts/speed-board.sh:227` prints RED rows from `ms`/`delta_pct` only, and `--measure` exited 0 with all four live rows `unavailable` (the base test asserted exactly that: `check(no_bin.code == 0, ...)`) | true |
| the baseline is 8862b600's numbers | `docs/missions/reports/speed-board.md`: start 321, first_token 223-236, tool_roundtrip 116-127, remote_roundtrip 397-477 ms. 8862b600 is the OLDEST line in the history, so with the old window (the last 10 commits, holes included) the next commit would have pushed the only real numbers out of it | true, and the window had to change for the baseline to be usable (below) |

## What was built

- **a2ed5de7** - the three changes of the brief:
  - `scripts/lib/speed-stats.lua`: `M.LIVE` (the four measured rows) and, in `judge`, a live row with no
    number is `red = true, hole = true` and lands in `verdict.red` with its reason; the two record rows
    (`landing`, `release`) are not. The RED window now counts the last ten commits that HAVE the row at a
    comparable load instead of the last ten commits (`judge`). `format_table` prints `RED` for such a row
    and no load for it.
  - `scripts/speed-board.sh`: a hole is printed by name and reason
    (`speed-board: RED start: unavailable - no binary to measure (pass --bin; a scratch worktree has
    none)`) and makes the board exit 3; a probe's own `unavailable: ` prefix is no longer doubled.
  - `scripts/main-health.sh`: the binary the speed block hands the board is, in order, the tree's binary
    the fast run just built or verified (through `scripts/lib/fast-binary.sh`, accepted only when its
    stamp is `$sha`), then the installed one when `installed.txt` names this commit - with the prefix
    test repaired - and otherwise nothing at all (which the board now reports as RED). The chosen binary
    is named on main-health's stderr.
- **e0b9f640** - `scripts/test-main-health.sh` pins its own `WA_MISSIONS_ROOT` and `WA_SUITE_LOCK`:
  measured while writing this, with `WA_SUITE_LOCK` exported by the caller the fixture main-health waited
  for the lock its own parent suite holds, and the row hung until it was killed.
- **358ebffe** - `scripts/lib/speed-stats.lua` prints no load for a row with no number (`0.00` beside a
  RED row reads as a measurement), with its check in `scripts/test-speed-stats.lua`.

No file outside the repository was changed by this mission.

## The rule: a live row with no number is a RED row of the board

The four live rows are what main must have a number for. `start`, `first_token`, `tool_roundtrip` and
`remote_roundtrip` with state `unavailable`, `guarded` or `unknown` now carry `red = true` and `hole =
true`, so:

- `speed-board --measure` exits 3 and prints one line per hole, by name and reason;
- the table `status.sh` prints shows `RED` on that row;
- main-health copies those lines to its own stderr (`main-health: speed-board: RED ...`).

The two record rows stay out of it: `landing` is unknown until a landing has been recorded and `release`
until a journal exists, and a new commit is expected to have neither. Three assertions in
`scripts/test-speed-board.lua` moved from `exit 0` to `exit 3` for the guarded, refusing and no-binary
cases, and each gained a check that the RED line names the row - the coverage grew, nothing was loosened.

## The window is ten MEASURED commits

`judge` walks back from the newest commit and counts only commits that have the row at a comparable load.
A hole cannot be the floor, and it must not consume one of the ten slots: with the old rule, the eight
`unavailable` lines after 8862b600 would have hidden its 321 ms start from every later comparison, which is
exactly the baseline the brief names. Checked in `scripts/test-speed-stats.lua` (`a run of holes does not
hide the last real number`).

## Which binary, and what it measures

main-health ran the whole fast path on this commit before the speed block, so the tree's binary exists and
is stamped with this commit; the block asks the same resolver the fast path used
(`scripts/lib/fast-binary.sh`) and accepts it only when `FAST_BIN_COMMIT` is `$sha` and the verdict is
`fresh` (or `explicit`, still stamped with this sha). Measured, with `--bin` handed over in the
end-to-end run: `speed-board: e0b9f6405781 first_token=260ms@7.57 landing=unknown
release=1475000ms@7.57 remote_roundtrip=461ms@7.44 start=402ms@7.57 tool_roundtrip=173ms@7.57 (load
7.57)`. The four live rows have numbers again.

## Verified here

- **The three changed tests, run alone** (`WASM_AGENT_HOME=<scratch> WA_SCRIPT=<row> wa --db <scratch>/t.db`):
  `speed-stats ok (40 checks)`, `speed-board ok (28 checks)`, `test-main-health ok (30 checks)` - all green.
- **They fail on the base** (`WA_BIN=/home/victor/.local/bin/wa bash scripts/test-discriminates.sh a0bb0262`,
  verbatim):
  `discriminates  scripts/test-main-health.sh  test-main-health FAILED: --bin does not name the binary the fast run built: ...` /
  `discriminates  scripts/test-speed-board.lua  speed-board: 7 FAIL of 28` /
  `discriminates  scripts/test-speed-stats.lua  speed-stats: 5 FAIL of 39` /
  `3 discriminating, 0 blocking`.
- **A real board run with a real binary of this commit**: `start=402ms first_token=260ms
tool_roundtrip=173ms remote_roundtrip=461ms` (load 7.57, 16 cores), four rows numbered, `verdict.red`
  empty. The binary was built by the real resolver (`fast: building this tree's binary
  (cargo build --release --offline, target .../m-speed-board-gets-a-binary) with code-mode assets`) and
  reported `verdict=fresh commit=e0b9f640... head=e0b9f640...`.
- **A real board run with no binary** - the state main is in today: `board exit=3`, and the table
  `status.sh` prints now reads
  `RED unavailable: no binary to measure (pass --bin; a scratch worktree has none)` on all four live rows
  instead of four silent dashes.
- **The changed block, run for real** (below): main-health's own speed block printed
  `main-health: speed binary /home/victor/wasm-agent/target/m-speed-board-gets-a-binary/release/wa` and
  wrote a history line whose rows have numbers, with the one that could not be measured RED and named.

## The changed block, run for real

`scripts/main-health.sh` (this branch's script) against a scratch repository whose `main` is this branch
with one edit - a stub `scripts/fast.sh` that writes the suite's result file, because the question here is
what main-health HANDS the board, and the fast path's own build half is proven by its banner above. Every
output went to `/tmp/sb-e2e/wiring`, nothing to `~/Work/missions`. Verbatim, its stderr and the line it
wrote:

    main-health: green at 08566747ab25 (0 s, 1 checks) -> .../main-health.json
    main-health: speed binary /home/victor/wasm-agent/target/m-speed-board-gets-a-binary/release/wa
    main-health: speed-board: 08566747ab25 first_token=349ms@19.4 landing=unknown release=1475000ms@18 remote_roundtrip=818ms@20.01 start=786ms@18.56 tool_roundtrip=unavailable (load 18.00)
    main-health: speed-board: RED tool_roundtrip: unavailable - the code-mode call failed: codemode_not_enabled

The three rows that could be measured have numbers; the fourth says why it could not, in the row, and is
RED - which is the rule this mission adds, exercised by the real script on a binary it really resolved.
It found that binary through `scripts/lib/fast-binary.sh` (`bin=.../release/wa commit=08566747ab25...
head=08566747ab25...`).

WHY `tool_roundtrip` WAS `unavailable` THERE: that scratch clone carries no `.git/codemode-assets`, so
its binary was built with `WA_CODEMODE_ALLOW_EMPTY=1` and has no QuickJS. The canonical checkout on this
node has them (`~/wasm-agent/checkout/.git/codemode-assets/pi-1.2.0-quickjs-3.6.2`) and the same build
there says `with code-mode assets`, which is how the four live rows above were measured.

## The full suite on this commit

PENDING-FULL-SUITE

## Texts to approve (new or changed, verbatim)

1. `main-health: speed binary <path>`
2. `main-health: speed binary (none: no binary of <sha12> on this machine, so the four live rows are RED)`
3. `speed-board: RED start: unavailable - no binary to measure (pass --bin; a scratch worktree has none)`
4. `speed-board: RED first_token: guarded - the machine was at load 99 on 16 cores (ceiling 24.0)`
5. `speed-board: RED tool_roundtrip: unknown - the commit has no number for this row`
6. the table, in `status.sh`: `RED unavailable: no binary to measure (pass --bin; a scratch worktree has
   none)`, `RED guarded: the machine was at load <x> on <n> cores (ceiling <c>)`, and a hole row's load
   column now prints `-`
7. `the commit has no number for this row` (the reason a live row with no entry at all carries)

## What I did not verify

- **The operator's own main-health record**: the end-to-end run wrote to `/tmp/sb-e2e`, not to
  `~/Work/missions`. Nothing was installed (FACTORY rule 12), so `status.sh` still reads the line for the
  installed commit, and that line is written by the next health run after this lands.
- **A quiet-load comparison against 8862b600**: the numbers above were taken at load 7.57, and
  `speed-stats` only compares rows within 25% + 0.5 of the load, so the table says `no_baseline` for the
  four live rows - correctly, and it says why. The 321 ms floor appears in the same table as soon as a
  measurement is taken at a comparable load.
- **Other machines**: the cold-start and remote probes are Linux-specific; elsewhere the rows would be
  `guarded`/`unavailable` and now RED with the reason, rather than wrong.
