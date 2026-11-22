# land-builtin - landing is a wa command with events, not a set of shell scripts

Mission: Victor, 22/11 - "i like to start to make the landing built in ... so not need scripts, just you
subscribing to the events". The night of 21-22/11 landed branches with five things outside the product and two
sessions telling each other "it is green, land it". This round moves the loop into `wa` and makes every step
a fact on one ledger.

Base: 8082b42e (origin/main). Branch `change/land-builtin`.

## What shipped, by item (each row cites the commit that implements it)

| item | commit | what it does |
|---|---|---|
| the ledger and its feed | 98b13447 | `lua/core/event_ledger.lua` (new, 428 lines): one table `ledger_events`, one schema (`kind, at, mission, branch, sha, step, result, detail, source, session, data`), `record`/`read`/`newest`/`follow`, and `wa events [--kind land,mission] [--step] [--since <id>] [--limit] [--backlog] [--json] [--follow] [--poll] [--seconds]` plus `wa events record ...`. Kinds are an allow-list (`land`, `mission`); an unknown kind, an empty verdict and a non-slug step are refused by name and write nothing. Each row is published as the bus topic `<kind>.<step>` and only when a wake is subscribed (`self_wakes.on_topics`), which is the wake mechanism that already existed. |
| the landing | b7b654b0 | `wa land <branch>...` = `M.LANDING_STEPS` (`collect, plan, merge, tests, push, main, install, health, report`): no gate, no artifacts, no signature, no publish, no ring. New steps `tests` (`impl.tests`), `install` (`impl.install`), `health` (`impl.health`); `impl.gate` gained the `--gate` branch (the whole fast path on the merged tree); `M.main_red` + the guard in `impl.merge` (FACTORY.md rule 8); one ledger row per settled step (`M.emit` in `run_step`, in the plan-skip and `--no-deploy` branches, and in the stopped/refused paths); `M.landed_line`/`M.how_to_test` print `Local is evolved to <sha>. You can now test: ...` from the brief recorded on the ready line. CLI: positional branches, `--gate`, `--fix-main`, `--no-health`, `--install-timeout`; the start options travel with a resume (`START_KEYS`). |
| the mission's own producers | 05215ca4 | `wa land ready` writes kind `mission`, step `finished`; `wa mission preflight` writes kind `mission`, step `preflight` with `green`/`red`/`refused` and the rows that made it red. |
| the dry run | ab244fbd | `wa land <branch> --dry-run` prints the landing's own plan ("gate: none - a landing runs no gate"), the landing's own step table and its own command list, and returns before any release command. |
| docs + never-dropped rows | adad142d | `docs/EVENTS.md` (new), the `A landing: wa land <branch>` section in `docs/LAND.md`, and both new rows added to `wa_fast_core_rows` (`scripts/lib/fast-rows.sh`) so a narrowed run cannot drop them. |

## Which script each part replaces

| the script of 21-22/11 | now |
|---|---|
| `~/Work/missions/land-quick.sh` (94 lines: merge onto main, regenerate, the branch's own tests, push, install, changelog) | `wa land change/x` - the same order as `M.LANDING_STEPS`, one journal, one lock |
| `~/Work/missions/_quick/line.sh` (12 lines: several branches in order) | `wa land change/a change/b` - one run per branch, each refused by name |
| `~/Work/missions/install-local.sh` (44 lines: checkout fast-forward, `wa-sentinel request deploy`, wait, `/health`, diff of `lua-core`) | the `install` step: fast-forward, `wa-sentinel request deploy`, `installed.txt` read back until it names the landed commit, `diff -rq` of the installed `lua/core` |
| `scripts/main-health.sh` (115 lines, already in the repo) invoked in the background | the `health` step starts `wa land health-run` as a supervised operation (`host.operation`); that command runs the same script and writes the verdict as the row `land.main-health` (green / red / refused) |
| two sessions messaging "it is green, land it" | `wa events --follow --kind land` (a JSON line per step for any outside agent) and a session woken by `wake {on = ["land.*"]}` |

## Premises re-measured before writing code (rule: the brief's facts may be stale)

- `~/Work/missions/land-quick.sh` 94 lines, `_quick/line.sh` 12, `install-local.sh` 44, `scripts/main-health.sh`
  115 - all present and doing what the brief says.
- `FACTORY.md` with rule 10 is at `~/Work/missions/FACTORY.md`, NOT in the repository - so the rules it
  states cannot be cited by a commit here; the code cites the rule by number instead.
- `wa events` did not exist (no verb, no table); the wake ROWS did: `self_wakes.on_topics` plus
  `selfloop.publish`, whose `entry_matches` already accepts `land.*` as a prefix and `land.installed` exactly.
  Nothing new was built for waking - the ledger is a producer for it.
- `host.operation("start", ...)` exists and is what starts long work (`lua/core/server.lua`), so the health
  step starts a supervised operation rather than blocking a landing for the fast path's ~10 minutes.
- The node's install is ASYNCHRONOUS: `wa-sentinel status` at session start showed `requests: 1 waiting,
  44 done, 6 failed` with a deploy of 8082b42e held (`node busy`). That is why `install` polls the RECORD
  (`installed.txt`) instead of trusting the request, and why its default bound is 2400 s.
- `lua/core/land.lua` was 4448 lines; it is 5124 now (the landing's steps, the emitted events, the dry run).
  `M.STEPS` is unchanged, so the release's pipeline is the one it was.

## Tests, and where they are wired

| row | checks | where it runs |
|---|---|---|
| `scripts/test-event-ledger.lua` (new, 263 lines) | 68 | every run of `scripts/fast.sh` (a plain `scripts/test-*.lua`) and the gate; also `wa_fast_core_rows`, so a narrowed round cannot drop it |
| `scripts/test-land-quick.lua` (new, 402 lines) | 140 | the same, and `wa_fast_core_rows` - it uses `scripts/lib/land-row.lua`, which `scripts/test-fast-rows.sh` now proves (it failed until the row was listed: "uses the land harness but is not a never-dropped row") |

Both FAIL on the base 8082b42e, verified by running them with `WASM_AGENT_LUA_ROOT=<base worktree>`: each
stops at `lua_root_unreadable: <base>/lua/core/event_ledger.lua`, and their assertions are about code the base
does not have (no `landing` option, no `install`/`tests`/`health` step).

What the two rows prove, in one line each: the schema and its refusals; the cursor (`--since` is exact, a page
is oldest-first); the wake is the existing table (`land.*` fires on a land row and not on a mission one,
`land.installed` not on `land.merged`); the CLI's exit codes; a follower in ANOTHER PROCESS printing rows this
process wrote; and, for the landing: no gate and no release (the build/sign/ship/publish counters stay 0),
main read back from the remote, the checkout fast-forwarded, `installed.txt` naming the tip, the branch's own
tests green / red / skipped-by-name, scripts-only changes not deploying, a red main refused (and `--fix-main`
allowed), a stale red not blocking, an install record naming another commit stopping the round with a red
`install-failed` row, `--gate` green and red, `health-run` green/red/refused, the ledger's rows in order with
one sha, the last line's wording, and a resume that keeps the landing's order.

Rows I ran green on this tree (each in its own scratch `HOME`/ledger): `test-event-ledger` 68, `test-land-quick`
140, `test-land-plan` 105, `test-land-until` 81, `test-land-marks` 27, `test-fast-rows` 37. Also green:
`scripts/sync-prompt-docs.sh --check` (4 blocks current) and `scripts/check-instructions.mjs` (79 checks).

## What is NOT verified, and what this round did not do

- The real sentinel path was NOT exercised: rule 13 forbids calling the live fleet from a test, so `install`'s
  `wa-sentinel request deploy` and its wait are proven against a scripted route that writes `installed.txt` the
  way a deploy does. What is proven is the READ-BACK (the record names the tip, the installed Lua matches);
  what is not is that this node's sentinel accepts the request in production.
- A real `scripts/main-health.sh` run (~10 minutes) was NOT done: its verdict mapping (0 green, 1 red, anything
  else `refused`) is proven with a scripted exit code, and the operation start is proven with a seam
  (`land.start_operation`), not with the node's operation manager.
- Neither row was run through the FAST PATH runner itself (`scripts/fast.sh`), only through `wa --db <scratch>`
  the way the runner invokes a row; the full fast path and the gate were not run in this session.
- No landing was pushed to any remote by this round: `impl.push`/`impl.main` are exercised only on the fixture
  repository and its two bare remotes under a scratch home.
- `wa mission preflight` now writes a row through the ledger; the shell script `scripts/preflight.sh` is
  untouched, and its own file (`preflight.json`) remains the record the verb reads.

## Texts to approve (verbatim, operator- or model-facing)

1. `Local is evolved to <sha>. You can now test: <mission> - <the brief's How Victor tests it section>`
2. `Local is evolved to <sha>. You can now test: <mission> (no brief was recorded for this branch, so nothing describes the steps: record one with `wa land ready <branch> <sha> --brief <file>`)`
3. `Local is evolved to <sha> (the checkout only: scripts/docs only (no lua/, rust/, ui/, web/ or assets/ path): the checkout is at <sha12> and no deploy was asked for). You can now test: ...`
4. `wa land: nothing named. Use `wa land <branch>...` (a landing: merge, the branch's own tests, push, install this node, then main's health), or --ready (the ready box), --branches a,b, --resume, or --rollback.`
5. `land: gate: none - a landing runs no gate (the gate belongs to `wa release cut`; --gate asks anyway)`
6. `land: main is red, so this landing waits for the fix (FACTORY.md rule 8)` - the rule-8 refusal at the merge step, with `next: land the fix on its own with `wa land <the fix branch> --fix-main`, or measure main again: bash scripts/main-health.sh --repo <checkout>`
7. `wa events [--kind land,mission] [--step <name>] [--since <id>] [--limit N] [--backlog N] [--json]` / `[--follow] [--poll S] [--seconds N]   read the ledger; --follow prints new rows as they land`
8. `wa events record --kind <land|mission> --step <name> --result <verdict> [--mission m] [--branch b] [--sha s] [--detail text] [--source who]   write one fact (a script's own step)`
9. `wa events: refused(kind_unknown): <kind> - the kinds are land, mission`
10. `land: the ledger refused the row for <step>: <reason>` and `land: the ledger row for <step> could not be written: <error>`
11. `wa land health-run: main is <green|red|refused> (event <id>)` and `land: health-run: refused(<error>): <observed>`
12. `land: install: skipped - scripts/docs only (no lua/, rust/, ui/, web/ or assets/ path): the checkout is at <sha12> and no deploy was asked for`
13. `land: tests: skipped - the branch changes Rust (<n> file(s)): its tests need the new binary, so they are judged by main-health after the install, not here`

## Self-review (not an independent review)

- The default `mission` field of a row is the branch (the ledger), and `wa land` always passes the mission name
  (the branch without `change/`); a row written by `wa events record` with no `--mission` therefore shows its
  branch - noted, not a bug.
- `M.emit` failures print and continue (a landing must not stop because its feed hiccuped); the step's own
  journal row is what the state machine reads, so a lost ledger row is visible as a printed line, not silence.
- The install step does not verify `/health` (install-local.sh did): installing restarts the node, so a health
  probe from inside the process that is being restarted would read its own restart. It is named here rather
  than silently dropped, and it is the obvious next item if Victor misses it.
