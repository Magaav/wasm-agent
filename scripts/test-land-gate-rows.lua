-- `wa land` -- THE GATE'S ROWS: the WA_FAST_ROWS file the gate hands the round, the discrimination check, and a
-- fast runner whose failures are attributed row by row.
--
-- Part of the land row, split out on 22/11 (mission main-green-2, item 2) so that no part of it can
-- hang under the fast path's 120 s watchdog. The harness - the scratch wa-vault, the fixture
-- repository and its two remotes, the scripted node, the fake reviewer's door, the assertion
-- helpers - is scripts/lib/land-row.lua; what was measured, and why each check exists, is in the
-- case comments below.
--
--   WA_SCRIPT=scripts/test-land-gate-rows.lua wa --db /tmp/wa-land.db

-- The scratch-home guard every row agrees on: this row writes a repository, a journal and a vault
-- into the home it is given, so it refuses to run on the operator's.
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-land-gate-rows.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local R = dofile("scripts/lib/land-row.lua")
local json, land, repo, incoming, ok, eq, contains, must, write_file, read_file = R.json, R.land, R.repo, R.incoming, R.ok, R.eq, R.contains, R.must, R.write_file, R.read_file
local setup_fixture, observed, journal_of, step_of, SOLO_RING = R.setup_fixture, R.observed, R.journal_of, R.step_of, R.SOLO_RING

R.start_vault()

;(function()
  local function counting_row(name)
    local path = host.paths().home .. "/land-gate/until-" .. name .. ".sh"
    write_file(path, string.format([[#!/usr/bin/env bash
COUNT="%s/land-gate/until-%s.n"
echo $(( $(cat "$COUNT" 2>/dev/null || echo 0) + 1 )) > "$COUNT"
echo "%s ok"
exit 0
]], host.paths().home, name, name))
    return path
  end
  local function runs_of(name)
    return tonumber((read_file(host.paths().home .. "/land-gate/until-" .. name .. ".n") or "0"):match("%d+")) or 0
  end
  local gate_row = counting_row("gate")
  local until_checks = { { name = "fast", command = "bash " .. gate_row, timeout = 120 } }

  setup_fixture()
  observed.pushes, observed.main_pushes, observed.publish = 0, 0, 0
  local until_code = land.run({ run = "case33", ring = SOLO_RING, branches = { "change/one" },
    until_step = "gate", checks = until_checks })
  eq(until_code, 0, "--until gate exits 0 (a stop where the caller asked for one is not a failure)")
  local j33 = journal_of("case33")
  eq(j33 and j33.result, "stopped_at_until", "the journal records stopped_at_until, never done")
  eq(j33 and j33.stopped_at, "gate", "and names the step it stopped after")
  eq(step_of("case33", "gate") and step_of("case33", "gate").state, "done", "the gate really ran")
  eq(runs_of("gate"), 1, "one gate run, no retry")
  for _, name in ipairs({ "push", "main", "artifacts", "sign", "ship", "publish", "deploy" }) do
    eq(step_of("case33", name), nil, "nothing after --until gate ran: " .. name)
  end
  eq(step_of("case33", "report") and step_of("case33", "report").state, "done",
    "the report still runs: an until-stop is a result a human reads")
  eq(observed.pushes, 0, "no push to the incoming repository")
  eq(observed.main_pushes, 0, "no push to main")
  eq(j33 and j33.pushed_sha, nil, "and the journal claims no pushed sha")
  contains(read_file(land.report_path("case33")) or "", "result: **stopped_at_until**",
    "the report says what it stopped after")

  -- ------------------------------------------ case 34: the landing keeps a green gate from another run
  --
  -- The same branch on the same main merges to the same BYTES, so the second round must not pay for the
  -- same check again - and it must not pretend either: the kept row names the run it was kept from, and
  -- the identity is the check's own data plus the TREE OBJECT, because the merge commit carries its own
  -- timestamp (the two runs' commits differ; their tree shas do not). A different branch is a different
  -- tree and runs the check as it always did.
  must("sleep 1.2")   -- so the two merge commits fall in different seconds, as they do in real life
  local second = land.run({ run = "case34", ring = SOLO_RING, branches = { "change/one" },
    until_step = "gate", checks = until_checks })
  eq(second, 0, "the second round stops at the gate too")
  local j34 = journal_of("case34")
  ok(j33 and j34 and j33.tree_commit ~= j34.tree_commit,
    "the two rounds merged to DIFFERENT commits (a merge commit carries its timestamp)")
  eq(j34 and j34.tree_sha, j33 and j33.tree_sha, "and to the SAME content: one tree object")
  ok(j34 and j34.tree_sha ~= nil and tostring(j34.tree_sha):match("^%x+$") ~= nil,
    "the merge records the tree object it produced")
  eq(runs_of("gate"), 1, "the second round KEPT the check: it did not run again")
  local kept_row = j34 and j34.gate and j34.gate[1]
  eq(kept_row and kept_row.kept, true, "the journal marks the row kept")
  eq(kept_row and kept_row.kept_from, "case33", "and names the run it was kept from")
  eq(kept_row and kept_row.seconds, 0, "a kept check costs no seconds")
  contains(read_file(land.run_dir("case34") .. "/evidence/gate.log") or "", "kept - passed on tree",
    "the gate's evidence says it was kept, on which tree, and by which run")

  -- a different branch is a different tree: the check runs, exactly as before this change
  local third = land.run({ run = "case35", ring = SOLO_RING, branches = { "change/two" },
    until_step = "gate", checks = until_checks })
  eq(third, 0, "the third round stops at the gate")
  eq(runs_of("gate"), 2, "a different tree runs the check again: a kept verdict is about the bytes")
  local j35row = (journal_of("case35").gate or {})[1]
  eq(j35row and j35row.kept, nil, "and the row is not marked kept")

  -- ------------------------------------------ case 36: only the rows that failed run again alone
  --
  -- The retry after a red check exists to tell a load problem from a tree problem, and it used to answer
  -- by running the whole check a second time (468 s to classify 3 red rows, measured). The runner's own
  -- result file names the failed rows and scripts/fast.sh takes a row list through WA_FAST_ROWS, so the
  -- retry asks for those rows only. A runner that leaves no result file is not "nothing failed": the
  -- retry then runs the whole check and says why, by name.
  local fastrow = host.paths().home .. "/land-gate/fastrows.sh"
  write_file(fastrow, string.format([[#!/usr/bin/env bash
# A stand-in for scripts/fast.sh that reports its failures the way the real runner does: the rows it ran,
# the ones that failed, and a result file in the worktree's own git dir. Two modes:
#   narrow: fails beside the other rows, and passes when it is asked for the failed rows only
#   quiet:  fails and writes no result file at all (a runner nobody can attribute the failure from)
set -uo pipefail
HOME_DIR="%s"
TREE=$(pwd)
RESULT=$(git rev-parse --git-path wa-fast-result.json 2>/dev/null)
case "$RESULT" in /*) ;; *) RESULT="$TREE/$RESULT" ;; esac
MODE=$(cat "$HOME_DIR/land-gate/fastrows.state" 2>/dev/null || echo narrow)
echo "rows=${WA_FAST_ROWS:-}" >> "$HOME_DIR/land-gate/fastrows.log"
if [ -n "${WA_FAST_ROWS:-}" ] && [ "$MODE" = narrow ]; then
  echo "fast: narrowed by the landing plan ($WA_FAST_ROWS)"
  echo "fast path PASSED (2 of 2 checks)"
  exit 0
fi
if [ "$MODE" = narrow ]; then
  printf '%%s\n' '{"schema":1,"checks":[{"name":"scripts/test-a.lua","section":"lua","status":"fail","exit":1,"first_error":"a failed"},{"name":"scripts/test-b.lua","section":"lua","status":"pass","exit":0,"first_error":""},{"name":"scripts/test-c.lua","section":"lua","status":"fail","exit":1,"first_error":"c failed"},{"name":"instructions","section":"checks","status":"fail","exit":1,"first_error":"instruction checker: AGENTS.md grew"}]}' > "$RESULT"
fi
echo "FAIL lua scripts/test-a.lua (exit 1): a failed"
echo "FAIL lua scripts/test-c.lua (exit 1): c failed"
echo "FAIL instructions (exit 1): instruction checker: AGENTS.md grew"
echo "fast path FAILED (2 of 4 checks, 0 skipped, 1s)"
exit 1
]], host.paths().home))
  local function set_fastrows(mode)
    write_file(host.paths().home .. "/land-gate/fastrows.state", mode .. "\n")
  end
  local function fastrows_log()
    return read_file(host.paths().home .. "/land-gate/fastrows.log") or ""
  end
  local narrow_checks = { { name = "fast", command = "bash " .. fastrow, timeout = 120 } }

  set_fastrows("narrow")
  write_file(host.paths().home .. "/land-gate/fastrows.log", "")
  eq(land.run({ run = "case36", ring = SOLO_RING, branches = { "change/artifacts" },
    until_step = "gate", checks = narrow_checks }), 1, "a red fast check still stops the round")
  local row36 = (journal_of("case36").gate or {})[1]
  eq(row36 and row36.retry and row36.retry.ok, true, "the retry passed on the failed rows alone")
  eq(step_of("case36", "gate").state, "flaky", "so the verdict is flaky under load, as before")
  contains(step_of("case36", "gate").detail or "", "flaky under load: fast",
    "and the sentence still says flaky under load, by name")
  eq(#(row36 and row36.failed or {}), 3, "the journal names the rows that failed (two Lua rows and a contract check)")
  eq(row36.failed[1] and row36.failed[1].row, "scripts/test-a.lua", "the first failed row, by name")
  eq(row36.failed[1] and row36.failed[1].first, "a failed", "with its own first line")
  eq(row36.failed[3] and row36.failed[3].row, "instructions", "and the contract check that failed")
  eq(row36.retry and row36.retry.rows_file ~= nil, true, "the retry carried its own row list")
  local retry_rows = read_file(row36.retry.rows_file) or ""
  contains(retry_rows, "scripts/test-a.lua", "the retry asks for the row that failed")
  contains(retry_rows, "scripts/test-c.lua", "and the other one that failed")
  ok(not retry_rows:find("scripts/test-b.lua", 1, true), "and NOT for the row that passed")
  local last_line = (fastrows_log():gsub("%s+$", "")):match("([^\n]*)$") or ""
  contains(last_line, "gate-retry-rows.txt", "the runner saw WA_FAST_ROWS on the retry (the last run)")
  contains(read_file(land.run_dir("case36") .. "/evidence/gate.log") or "",
    "the retry asks for those and nothing else", "the evidence says what the retry asked for")

  -- a runner that leaves no result file: the retry is the whole check, and says so by name
  set_fastrows("quiet")
  write_file(host.paths().home .. "/land-gate/fastrows.log", "")
  eq(land.run({ run = "case37", ring = SOLO_RING, branches = { "change/artifacts" },
    until_step = "gate", checks = narrow_checks }), 1, "a red check with no result file stops the round")
  local row37 = (journal_of("case37").gate or {})[1]
  eq(row37 and row37.retry and row37.retry.ok, false, "the whole check ran again and failed again")
  eq(row37 and row37.retry and row37.retry.rows_file, nil, "the retry named no row list: there was none to name")
  contains((row37 and row37.retry and row37.retry.why) or "", "could not be read", "and it says why")
  eq(step_of("case37", "gate").state, "failed", "the verdict is failed twice, as before")
  eq(#(row37 and row37.failed or {}), 1, "the journal still names the check that failed")
  eq(row37.failed[1] and row37.failed[1].row, "fast", "by name")
  -- ------------------------------------------ case 41: a second mission does not steal the kept gate
  --
  -- review r1, item 2: M.gate_history kept only the NEWEST passing row per check name, so two missions
  -- preflighted before one landing left the first mission's gate unkept - the normal case, not the corner
  -- one. The history is keyed by the check AND the tree now, so the fourth round below (change/one, the
  -- same bytes as case 33 and 34) is kept even though case 35 asked the same check about a different tree.
  eq(land.run({ run = "case41", ring = SOLO_RING, branches = { "change/one" }, until_step = "gate",
    checks = until_checks }), 0, "a fourth round on the first branch's bytes stops green at the gate")
  eq(runs_of("gate"), 2, "and it KEPT the check: a different tree preflighted in between did not steal it")
  local row41 = (journal_of("case41").gate or {})[1]
  eq(row41 and row41.kept, true, "the journal marks it kept")
  eq(row41 and row41.tree_sha, (journal_of("case33") or {}).tree_sha, "on the tree object it was passed on")

  -- ------------------------------------------ case 38: a LOCAL PATH as the incoming repository
  --
  -- A round tested with no network and no other node names a bare repository on this machine as --incoming.
  -- A path is not a legal refname component, so the fetch refspec was refused by git, the fetch failed in
  -- SILENCE, and the branch then read as "neither on the incoming nor a local branch" (measured 21/11: the
  -- first preflight replay could not collect a branch that was sitting in the drop box). The tracking
  -- namespace is derived from the path's own name now, and a failed fetch is a refusal named after the
  -- fetch instead of a statement about the branch.
  setup_fixture()
  land.incoming_remote = incoming
  eq(land.run({ run = "case38", ring = SOLO_RING, branches = { "change/one" }, until_step = "gate",
    checks = until_checks }), 0, "a round whose incoming is a local path collects and gates")
  eq(step_of("case38", "collect") and step_of("case38", "collect").state, "done", "collect read the drop box")
  eq((journal_of("case38") or {}).incoming_tracking, "incoming",
    "the tracking namespace comes from the path's own name")
  contains(must("git -C " .. repo .. " for-each-ref " .. "'--format=%(refname)'" .. " refs/remotes/incoming/"),
    "refs/remotes/incoming/change/one", "the fetched branches are readable under that namespace")
  land.incoming_remote = incoming .. "-missing"
  eq(land.run({ run = "case39", ring = SOLO_RING, branches = { "change/one" }, until_step = "gate",
    checks = until_checks }), 1, "an incoming that cannot be fetched stops the round")
  eq(step_of("case39", "collect") and step_of("case39", "collect").error, "fetch_failed",
    "and the refusal is named after the fetch, not after the branch")
  contains(step_of("case39", "collect").observed or "", "-missing",
    "the refusal names the incoming it could not read")
  land.incoming_remote = "oc-in"

  -- ------------------------------------------ case 40: a preflight is not an unfinished landing (r1 B1)
  --
  -- A bare `wa land --resume` used to continue the newest run whose result was not done, and a preflight
  -- ends as stopped_at_until with --until deliberately NOT inherited: so the next resume pushed, fast-forwarded
  -- main, built a release and deployed, for a branch nobody decided to land.
  setup_fixture()
  observed.pushes, observed.main_pushes = 0, 0
  eq(land.run({ run = "case40", ring = SOLO_RING, branches = { "change/one" }, until_step = "gate",
    checks = until_checks }), 0, "the preflight answers green and stops at the gate")
  eq((journal_of("case40") or {}).result, "stopped_at_until", "it is recorded stopped_at_until")
  eq(land.run({ resume = true }), 1, "a bare --resume finds nothing to resume: a preflight is not unfinished")
  eq(observed.pushes, 0, "so it pushed nothing")
  eq((journal_of("case40") or {}).result, "stopped_at_until", "and the preflight journal is untouched")
  eq(land.run({ run = "case40", resume = true }), 1, "resuming it BY NAME without --until is refused")
  eq(step_of("case40", "push"), nil, "and still nothing after the gate ran")
  eq(observed.pushes, 0, "still no push")
  eq(land.run({ run = "case40", resume = true, until_step = "gate" }), 0,
    "naming the boundary again is allowed: it continues to the same boundary")
  eq(observed.pushes, 0, "and pushes nothing")

  -- ------------------------------------------ case 42: the result file must be THIS attempt's (r1 item 3)
  --
  -- scripts/fast.sh writes wa-fast-result.json at the END, so an attempt killed early leaves the previous
  -- attempt's file in the same tree (a resumed run, a retry). Reading it names rows that did not fail now;
  -- the narrowed retry runs them, they pass, and the verdict is reported as flaky under load - the wrong
  -- rows and the wrong reason.
  local stale = host.paths().home .. "/land-gate/stale-rows.sh"
  write_file(stale, string.format([[#!/usr/bin/env bash
set -uo pipefail
HOME_DIR="%s"
TREE=$(pwd)
RESULT=$(git rev-parse --git-path wa-fast-result.json 2>/dev/null)
case "$RESULT" in /*) ;; *) RESULT="$TREE/$RESULT" ;; esac
MODE=$(cat "$HOME_DIR/land-gate/stale-rows.state" 2>/dev/null || echo write)
if [ "$MODE" = silent ]; then
  # FAILS and writes nothing: exactly what an attempt killed before its end leaves behind. It PASSES when
  # it is asked for a row list, which is what a narrowed retry would do with the leftover rows.
  if [ -n "${WA_FAST_ROWS:-}" ]; then echo "fast path PASSED (2 of 2 checks)"; exit 0; fi
  echo "FAIL lua scripts/test-a.lua (exit 1): a failed"
  echo "fast path FAILED (1 of 2 checks, 0 skipped, 1s)"
  exit 1
fi
printf '%%s\n' '{"schema":1,"checks":[{"name":"scripts/test-a.lua","section":"lua","status":"fail","exit":1,"first_error":"a failed"}]}' > "$RESULT"
echo "FAIL lua scripts/test-a.lua (exit 1): a failed"
echo "fast path FAILED (1 of 2 checks, 0 skipped, 1s)"
exit 1
]], host.paths().home))
  local function set_stale(mode)
    write_file(host.paths().home .. "/land-gate/stale-rows.state", mode .. "\n")
  end
  local stale_checks = { { name = "fast", command = "bash " .. stale, timeout = 120 } }
  set_stale("write")
  eq(land.run({ run = "case42", ring = SOLO_RING, branches = { "change/one" }, until_step = "gate",
    checks = stale_checks }), 1, "a red check that wrote its result file stops the round")
  eq(step_of("case42", "gate").state, "failed", "failed twice: the retry asks for the same failing row")
  must("sleep 1.2")   -- so the leftover file is unmistakably OLDER than the next attempt
  set_stale("silent")
  eq(land.run({ run = "case42", resume = true, checks = stale_checks }), 1, "the resumed attempt is red too")
  local rows42 = journal_of("case42").gate or {}
  local row42 = rows42[#rows42]
  eq(step_of("case42", "gate").state, "failed",
    "and it stays failed: the leftover result file is not this attempt's, so nothing was narrowed")
  eq(row42 and row42.retry and row42.retry.rows_file, nil, "the retry named no row list")
  contains((row42 and row42.retry and row42.retry.why) or "", "not newer than this attempt began", "and it says why")

  -- ------------------------------------------ case 44: a preflight does not need another node awake (r1 item 4)
  --
  -- An unreachable NAMED incoming is a warning for a round that stops at or before the gate (FACTORY.md
  -- rule 1: the local loop has no network and no other node) and still a refusal for a landing, which cannot
  -- merge what it cannot read.
  setup_fixture()
  land.incoming_remote = "no-such-remote-r1"
  eq(land.run({ run = "case44", ring = SOLO_RING, branches = { "change/one" }, until_step = "gate",
    checks = until_checks }), 0, "a preflight goes on with the refs it already has when the incoming is down")
  eq(step_of("case44", "collect") and step_of("case44", "collect").state, "done", "collect finished")
  contains(read_file(land.run_dir("case44") .. "/evidence/collect.log") or "", "fetch: WARN",
    "and the evidence carries the warning, by name")
  eq(land.run({ run = "case45", ring = SOLO_RING, branches = { "change/one" }, checks = until_checks }), 1,
    "a landing refuses the same unreachable incoming")
  eq(step_of("case45", "collect") and step_of("case45", "collect").error, "fetch_failed", "by name")
  land.incoming_remote = "oc-in"

end)()

-- ---------------------------------------------------------------- cases 46-49: the RELEASE loop
--
-- FACTORY.md rule 1: a landing ends at main, and a release is its own command, cut from main's tip
-- (`wa release cut` = land.run with release = true). These cases prove the four things the owner asked:
-- it lands nothing (no branch, no push of a landing branch, main untouched), it refuses in the first second
-- when signing or publishing is not ready, it is resumable by the existing `--run <id> --resume`, and a
-- landing that stopped at `--until main` is complete without it.

R.stop_vault()
print(string.format("land ok (%d checks)", R.count()))
