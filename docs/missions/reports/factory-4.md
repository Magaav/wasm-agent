# factory-4: the queue is the scheduler

Branch `change/factory-4`, on `change/factory-3` (271375e6). Written by the planning session (Fable), not by a
worker. Nothing pushed. Brief: `~/Work/missions/factory-4/brief.md`.

## What changed

`scripts/drive.sh` is rewritten around one round = answers, landings, launches.

Four defects of the factory-3 driver, found in review against this machine (its test used a stub landing):

| defect | fix |
| --- | --- |
| a real landing was called red: `wa land` pushes and never moves the checkout's `main`, and the driver read that ref | a landing is judged by the branch tip being an ancestor of `origin/main` after a fetch; the checkout is fast-forwarded when it is on main and clean (test case 12) |
| it would land missions nobody approved: every `rc=0` done with an unlanded branch, preflight run on demand | ready = `done` says `rc=0` AND (`preflight=green` OR a `LAND` file / `land` answer); `HOLD`, `RETIRED`, `PARKED` keep a mission out (cases 9, 10) |
| the landing took no suite lock while main-health ran a full suite under it | the landing runs under `flock -o <suite lock>` unless `WA_DRIVE_LAND_LOCK=0` |
| install was `deploy.sh` on a checkout nobody had brought to main | site commands come from `<missions>/drive.conf`; on this laptop `install-local.sh` (fast-forward, sentinel deploy, retry while held, checks the installed Lua is main's) |

New behaviour:

- **A release stop is not a red landing.** Main moved and the command then exited non-zero (sign, publish): the
  mission is landed, installed and announced, and `release-after-<name>` is one line in DECISIONS.md (case 13).
- **A mission's own red on a main that moved does not stop the line.** Once, it goes back to its own worker
  through the `again` hook with the rows; after that it is `PARKED` with a DECISIONS.md line. MAIN RED, a
  preflight that judged nothing, a red landing and a failed install still write ATTENTION and stop (cases 3, 7, 8).
- **DECISIONS.md is acted on.** `<mission>: land` writes `LAND`; `retire` writes `RETIRED` (directory and branch
  kept); `again: <text>` calls the hook. An unapproved finished mission gets its line after
  `WA_DRIVE_STALE_HOURS` (12).
- **The queue launches itself.** A brief in `_queue/` with a `priority: <n>` header is launched when a slot is
  free (`WA_DRIVE_MAX_WORKERS`, 3) and every `after:` mission is on main; the brief is MOVED to
  `<mission>/brief.md`. No `priority:` line = never launched by the driver (the folder holds old briefs and
  notes). `hold:` keeps one back. A brief with no `## How Victor tests it`, a name that already exists, or a
  launch that fails becomes a DECISIONS.md line (case 11).
- **A dead worker is one line.** Launched, no `done`, no unit running it for 3 minutes: `<name>: its worker is DEAD ... - recommended: again` (case 13b; 21/11 a dead worker went unseen for ten hours).
- `--loop [seconds]` is the service form; `<missions>/.drive/heartbeat` is touched every round.
- `lua/core/land.lua` `M.regenerate` stages only the paths the generators reported, not `git add -A`.

## Outside the repository (this laptop, `~/Work/missions/`)

`drive.conf`, `drive-land.sh` (the landing in the orchestrator's environment, no lock of its own),
`install-local.sh`, `again.sh` (resume the worker's session with a text, then its gate loop),
`factory-drive.service` (NOT enabled), and `status.sh` now ends with the open decisions and one `STALE:` line.

## Checks run

- `bash scripts/test-drive.sh`: `test-drive ok (69 checks)` (was 24). Cases 7-14 are new; on factory-3's
  drive.sh case 7 fails (it writes ATTENTION and stops for a mission's own red).
- `scripts/test-land.lua` with `WASM_AGENT_LUA_ROOT` = this worktree, scratch home: `land ok (574 checks)`.
- `bash scripts/test-regenerate.sh`: `test-regenerate ok (28 checks)`.
- `bash scripts/drive.sh --dry-run` against the real missions root at 22:10Z: offers deploy-luafast and
  factory-3 (both green and approved), none of the five undecided old missions, and names the one held brief.
- NOT run: the full fast path (the landing's gate does it), and NO real landing, install, launch or `again`
  through the driver. `drive-land.sh`, `install-local.sh` and `again.sh` are untested copies of the
  orchestrator's working recipes; the first real round must be watched.

## Not built

- status.sh's STALE line is in the operator's file, not in the repository, and has no test.
- `again` has no round limit of its own beyond "once automatically"; a person can answer `again` repeatedly.
- The driver does not know about a landing started by hand: enable the service only when the orchestrator has
  stopped using `_orch/chain.sh`.

## Texts to approve

`drive: <name> approved for landing (DECISIONS.md); its gate is asked before it lands`,
`drive: <name> retired (DECISIONS.md); its directory and branch are kept`,
`drive: <name>: red on the new main (<row>) - sent back to its own worker, the line goes on`,
`drive: <name>: red on the new main (<row>) - parked (<file>), the line goes on`,
`drive: launching <name> (priority <n>, after <list>)`, `drive: <name> waits for: <list>`,
`drive: <name> is ready and waits for a worker slot (<n> of <max> running)`, and the DECISIONS.md lines:
`finished <n> h ago (...), <n> commit(s) not on main, nothing approved it - recommended: ?`,
`its gate is red on the current main (<row>) - recommended: again`,
`the landing moved main and then stopped (exit <n>: <line>); nothing is wrong with the code - recommended: finish the release when one is wanted, then delete this line`.

## How Victor tests it

`bash ~/Work/missions/status.sh` ends with the decisions waiting on you and a `STALE:` line (empty = nothing late).
`bash ~/Work/missions/drive.sh --dry-run` prints what would land and launch, and changes nothing.
In `~/Work/missions/DECISIONS.md` rewrite a line as `tui-diff-view: retire`, run `bash ~/Work/missions/drive.sh
--dry-run` -> "would retire tui-diff-view". When the service is enabled, a finished mission with a green
preflight appears in LOCAL-CHANGELOG.md without anyone asking.
