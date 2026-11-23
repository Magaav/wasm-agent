-- `wa land <branch>`: A RED MAIN BLOCKS THE NEXT LANDING, AND A HEALTH ROW IS NOT A VERDICT ABOUT MAIN.
--
-- One of five parts by subject (scripts/lib/land-quick.lua says why). FACTORY.md rule 8: a red main blocks
-- the next landing UNLESS that landing is the fix (--fix-main); a verdict about an OLDER main is stale; only
-- a MEASUREMENT of main is a verdict, so the health step's own row is neither a red main nor a green one, in
-- either direction; and `wa land health-run` marks the row it writes as the measurement (green/red/refused -
-- never green by default).
local Q = dofile("scripts/lib/land-quick.lua")
Q.arm("test-land-quick-main.lua")
local R = Q.R
local land, repo, ok, eq, contains, must, write_file, read_file = Q.land, Q.repo, Q.ok, Q.eq, Q.contains, Q.must, Q.write_file, Q.read_file
local setup_fixture, journal_of, step_of, marker = Q.setup_fixture, Q.journal_of, Q.step_of, Q.marker
local json, state, ledger, trim = Q.json, Q.state, Q.ledger, Q.trim
local behaviour, observed, install_dir = Q.behaviour, Q.observed, Q.install_dir
local fixture, branch_with, main_grows, first_line_ish = Q.fixture, Q.branch_with, Q.main_grows, Q.first_line_ish
local running, said, rows_of = Q.running, Q.said, Q.rows_of
-- ---------------------------------------------------------------- case 5: a red main blocks the next landing
fixture()
local base = trim(must("git -C " .. repo .. " rev-parse main"))
ledger.record({ kind = "land", step = "main-health", result = "red", sha = base, mission = "earlier",
  detail = "test-land-plan.lua failed", data = { measured = "scripts/main-health.sh" } })
eq(running(function() return land.run({ run = "quick5", landing = true, branches = { "change/lua" } }) end), 1,
  "a landing onto a red main is refused")
contains(tostring(step_of("quick5", "merge").error), "main_red", "by name, at the merge step")
contains(step_of("quick5", "merge").observed, "test-land-plan.lua failed", "with the row that made main red")
contains(must("git -C " .. repo .. " ls-remote origin refs/heads/main"), base .. "\trefs/heads/main", "and main did not move")
eq(running(function() return land.run({ run = "quick5f", landing = true, fix_main = true, branches = { "change/lua" } }) end), 0,
  "the landing that IS the fix is allowed (--fix-main)")
-- A verdict about an OLDER main is stale and blocks nothing.
fixture()
local older = "0123456789abcdef0123456789abcdef01234567"
ledger.record({ kind = "land", step = "main-health", result = "red", sha = older, mission = "older",
  detail = "a red about a main nobody is on", data = { measured = "scripts/main-health.sh" } })
eq(running(function() return land.run({ run = "quick5s", landing = true, branches = { "change/lua" } }) end), 0,
  "a red about an older main is stale and blocks nothing")

-- 5b. A HEALTH STEP IS NOT A VERDICT ABOUT MAIN. The step writes `land.main-health` too - "started as
-- operation ..." green, or "the health run was not started" red - because a subscriber asks for the step. Read
-- as a verdict that row reds a green main: 22/11, `land main-health red detail=program_not_found` refused
-- `wa land change/search-miss-names-cli` at merge while the fast path was green on main.
fixture()
main_grows({ ["unique-5b.txt"] = "5b\n" })
local base5b = trim(must("git -C " .. repo .. " rev-parse main"))
ledger.record({ kind = "land", step = "main-health", result = "red", sha = base5b, mission = "step-only",
  detail = "program_not_found" })
eq(running(function() return land.run({ run = "quick5b", landing = true, branches = { "change/lua" } }) end), 0,
  "a health STEP that failed is not a red main: the landing runs")
eq(step_of("quick5b", "merge").state, "done", "and its merge step is green (nothing was refused)")
contains(tostring(journal_of("quick5b").base or ""), base5b:sub(1, 12),
  "and it was cut from the main whose health step had failed (the row the old rule refused)")

-- 5c. AND THE OTHER DIRECTION: a green step row is not a green verdict either, so it cannot erase a measured
-- red about the same main.
fixture()
main_grows({ ["unique-5c.txt"] = "5c\n" })
local base5c = trim(must("git -C " .. repo .. " rev-parse main"))
ledger.record({ kind = "land", step = "main-health", result = "red", sha = base5c, mission = "measured",
  detail = "test-land-plan.lua failed", data = { measured = "scripts/main-health.sh" } })
ledger.record({ kind = "land", step = "main-health", result = "green", sha = base5c, mission = "step-only",
  detail = "started as operation op-1: the verdict arrives as the event land.main-health" })
eq(running(function() return land.run({ run = "quick5c", landing = true, branches = { "change/lua" } }) end), 1,
  "a green health STEP does not un-red a measured red main")
contains(tostring(step_of("quick5c", "merge").error), "main_red", "by name, at the merge step")
contains(step_of("quick5c", "merge").observed, "test-land-plan.lua failed", "with the measured row that says so")

-- 5d. THE WRITER: `wa land health-run` marks the row it writes as a MEASUREMENT, which is what M.main_red
-- reads. Without the marker its own verdict would be skipped as a step record.
fixture()
behaviour.main_health_code = 1
local code5d, answer5d = land.health_run({ repo = repo, sha = base5c, mission = "probe", source = "test" })
behaviour.main_health_code = 0
eq(code5d, 1, "health-run reports main red when the fast path is red")
eq(answer5d and answer5d.verdict, "red", "and names the verdict it recorded")
local rows5d, why5d = ledger.read({ kinds = { "land" }, step = "main-health", limit = 1 })
local newest = type(rows5d) == "table" and rows5d[#rows5d] or nil
ok(type(newest) == "table", "the verdict is a row in the ledger (" .. tostring(why5d or "read ok") .. ")")
ok(type(newest) == "table" and tostring(newest.data or ""):find("measured", 1, true) ~= nil,
  "and it carries the measurement marker (data.measured), so the red-main rule reads it")
ok(type(newest) == "table" and tostring(newest.data or "") ~= "",
  "the marker is a value, not an empty record (got [" .. tostring(type(newest) == "table" and newest.data) .. "])")

-- ---------------------------------------------------------------- case 8: main's health, green/red/refused
fixture()
local health_code, health_answer = land.health_run({ repo = repo, sha = base, mission = "probe" })
eq(health_code, 0, "health-run answers the measurement's own exit code")
eq(health_answer.verdict, "green", "and calls a green measurement green")
eq(observed.health_runs, 1, "it ran main-health once")
local health_rows = {}
for _, row in ipairs(ledger.read({ kinds = { "land" }, step = "main-health", limit = 50 })) do health_rows[#health_rows + 1] = row end
local green_row = nil
for _, row in ipairs(health_rows) do if tostring(row.mission) == "probe" then green_row = row end end
ok(green_row ~= nil and green_row.result == "green", "the verdict is a ledger row")
behaviour.main_health_code = 1
local red_code, red_answer = land.health_run({ repo = repo, sha = base, mission = "probe-red" })
eq(red_code, 1, "a red measurement answers 1")
eq(red_answer.verdict, "red", "and is recorded red")
behaviour.main_health_code = 2
local refused_code, refused_answer = land.health_run({ repo = repo, sha = base, mission = "probe-refused" })
eq(refused_code, 2, "a run that could not judge answers 2")
eq(refused_answer.verdict, "refused", "and is NEVER recorded green")
-- and the guard reads exactly that row: main is red now, so a landing refuses.
behaviour.main_health_code = 0
ledger.record({ kind = "land", step = "main-health", result = "refused", sha = base, mission = "probe-again",
  detail = "main-health could not judge", data = { measured = "scripts/main-health.sh" } })
eq(running(function() return land.run({ run = "quick8", landing = true, branches = { "change/lua" } }) end), 0,
  "a `refused` verdict is not a red main and does not block a landing")


if R.count() > 0 and false then os.exit(1) end
print(string.format("landing ok (%d checks)", R.count()))
