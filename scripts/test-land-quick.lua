-- `wa land <branch>`: THE LANDING (FACTORY.md rule 10) - no gate, its own tests, push, install, health,
-- and every step a row in the ledger.
--
-- This is the half of the night of 21-22/11 that was a set of scripts outside the product: land-quick.sh,
-- _quick/line.sh, install-local.sh, scripts/main-health.sh and two sessions messaging each other "it is green,
-- land it". Each case below is one promise that loop made, moved into `wa land`:
--
--   1. a landing runs NO gate and makes NO release: merge -> tests -> push -> main -> install -> health; the
--      release steps (artifacts, sign, ship, publish, deploy, review) do not run at all, and the counters
--      prove nothing was built, signed, shipped or published;
--   2. the install is the record, not the version: installed.txt must name the landed commit, the checkout is
--      fast-forwarded to it, and the Lua the node runs is compared with the landed tree's. A record that
--      names another commit STOPS the landing and writes a red `install-failed` row;
--   3. the branch's own tests decide: green rows pass, a red row stops the landing before anything is pushed,
--      a branch that changes Rust skips them BY NAME (a Lua row cannot judge a new binary), and a branch with
--      no test of its own says so;
--   4. a scripts/docs-only branch does not deploy (a deploy pauses every worker for bytes no node loads), and
--      the last line says exactly that instead of claiming an install;
--   5. FACTORY.md rule 8: a red main blocks the next landing UNLESS that landing is the fix (--fix-main);
--   6. --gate is the explicit request for the whole fast path on the merged tree, and a red one stops it;
--   7. main's health is a separate measurement, started as an operation after a landing that changed lua/ or
--      rust/, and its verdict is a ledger row (`wa land health-run`, green/red/refused - never green by
--      default);
--   8. every step is an EVENT with one schema, and ANOTHER PROCESS reads the same rows (`wa events`);
--   9. the resume keeps the landing's own step order and its flags (a resumed landing never becomes a release).
--
-- The harness (the fixture repository and its two remotes, the scripted network, the scratch-home guard) is
-- scripts/lib/land-row.lua; what is scripted HERE is only what cannot be real in a test: this node's sentinel
-- (the route writes the record the way a deploy does), the health run's own process, and the fast path.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_FAST_BIN=<wa binary> WA_SCRIPT=scripts/test-land-quick.lua wa --db <scratch>

local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-land-quick.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local R = dofile("scripts/lib/land-row.lua")
local land, repo, ok, eq, contains, must, write_file, read_file = R.land, R.repo, R.ok, R.eq, R.contains, R.must, R.write_file, R.read_file
local setup_fixture, journal_of, step_of, marker = R.setup_fixture, R.journal_of, R.step_of, R.marker
local real_exec, json, state = R.real_exec, R.json, R.state

local ledger = dofile("lua/core/event_ledger.lua")
ledger.setup()

-- ---------------------------------------------------------------- what is scripted, and only that
local install_dir = R.fixture .. "/node-install"
land.install_dir_override = install_dir
land.start_operation = function(spec)
  state.health_operation = spec
  return "op-health-1"
end

local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local behaviour = { install_commit = nil, sentinel_fails = false, lua_core = true, lua_differs = false,
  main_health_code = 0, gate_code = 0 }
local observed = { deploy_requests = 0, health_runs = 0, gate_runs = 0 }

local harness_exec = land.exec
land.exec = function(command, cwd, timeout, opts)
  if command:find("wa%-sentinel request deploy", 1) then
    observed.deploy_requests = observed.deploy_requests + 1
    if behaviour.sentinel_fails then
      return { code = 1, stdout = "", stderr = "wa-sentinel: the request box is unwritable" }
    end
    -- WHAT THE SENTINEL DOES, and the only thing this route owns: it installs the checkout's tip and writes the
    -- install record. Everything the step then proves (the record names the tip, the Lua matches) is read back
    -- by the code under test.
    local head = must("git -C " .. repo .. " rev-parse HEAD")
    local commit = behaviour.install_commit or head
    must("mkdir -p " .. install_dir, "create the install directory")
    write_file(install_dir .. "/installed.txt", "commit=" .. commit .. "\nvia=tree\n")
    must("rm -rf " .. install_dir .. "/lua-core", "clear the installed lua tree")
    local has_lua = harness_exec("test -d " .. repo .. "/lua/core", repo, 60)
    if behaviour.lua_core and (has_lua.code or 1) == 0 then
      must("mkdir -p " .. install_dir .. "/lua-core/lua", "create the installed lua tree")
      must("cp -a " .. repo .. "/lua/core " .. install_dir .. "/lua-core/lua/core", "copy the landed lua core")
      if behaviour.lua_differs then write_file(install_dir .. "/lua-core/lua/core/stray.lua", "-- not this landing") end
    end
    return { code = 0, stdout = "queued\n", stderr = "" }
  end
  if command:find("scripts/main%-health%.sh", 1) then
    observed.health_runs = observed.health_runs + 1
    return { code = behaviour.main_health_code, stdout = "main-health: measuring ...\n",
      stderr = behaviour.main_health_code == 0 and "" or "main-health: FAIL test-land-plan.lua\n" }
  end
  if trim(command) == "bash scripts/fast.sh" then
    observed.gate_runs = observed.gate_runs + 1
    return { code = behaviour.gate_code, stdout = behaviour.gate_code == 0 and "fast: 12 rows ok\n" or "FAIL fast: fake red\n",
      stderr = "" }
  end
  return harness_exec(command, cwd, timeout, opts)
end


-- A branch of the fixture that changes the paths the rules look at.
local function branch_with(name, files)
  must("git -C " .. repo .. " checkout -q -B " .. name .. " main", "branch " .. name)
  for path, text in pairs(files) do write_file(repo .. "/" .. path, text) end
  must("git -C " .. repo .. " add -A && git -C " .. repo .. " commit -q -m '" .. name .. "'", "commit " .. name)
  must("git -C " .. repo .. " push -q oc-in " .. name .. ":refs/heads/" .. name, "push " .. name)
  must("git -C " .. repo .. " checkout -q main", "back to main")
end

-- The fixture's own main-health: the REAL script (the step and `wa land health-run` both look for it in the
-- tree), committed to main so every branch carries it. Its command is routed above, so it never runs here.
local function fixture(name, extra)
  setup_fixture()
  must("cp -f " .. R.tree_root .. "/scripts/main-health.sh " .. repo .. "/scripts/main-health.sh", "copy main-health")
  must("git -C " .. repo .. " add -A && git -C " .. repo .. " commit -q -m 'main-health'", "commit main-health")
  must("git -C " .. repo .. " push -q origin main && git -C " .. repo .. " push -q oc-in main", "publish main-health to main")
  branch_with("change/lua", { ["lua/core/greeting.lua"] = "return { hello = 'landing' }\n" })
  branch_with("change/tests", { ["scripts/test-own.lua"] = "print('own ok')\n" })
  branch_with("change/tests-red", { ["scripts/test-own-red.lua"] = "print('own red')\nos.exit(1)\n" })
  branch_with("change/rust", { ["rust/thing.rs"] = "// a change that needs a binary\n",
    ["scripts/test-own-rust.lua"] = "print('never runs here')\n" })
  branch_with("change/docs", { ["docs/notes.txt"] = "a document\n" })
  observed.deploy_requests, observed.health_runs, observed.gate_runs = 0, 0, 0
  behaviour.install_commit, behaviour.sentinel_fails = nil, false
  behaviour.lua_core, behaviour.lua_differs = true, false
  behaviour.main_health_code, behaviour.gate_code = 0, 0
  state.health_operation = nil
  if extra then extra() end
end

-- The prints of a run, captured so the LAST LINE (the one Victor reads) can be asserted.
local captured = {}
local real_print = print
local function running(fn)
  captured = {}
  print = function(...)
    local parts = {}
    for index = 1, select("#", ...) do parts[#parts + 1] = tostring((select(index, ...))) end
    captured[#captured + 1] = table.concat(parts, " ")
  end
  local called, answer = pcall(fn)
  print = real_print
  if not called then error(answer, 0) end
  return answer
end
local function said(needle)
  for _, line in ipairs(captured) do
    if line:find(needle, 1, true) ~= nil then return true, line end
  end
  return false, nil
end

local function rows_of(mission)
  local rows = ledger.read({ kinds = { "land" }, limit = 500 })
  local mine = {}
  for _, row in ipairs(rows) do
    if tostring(row.mission) == mission then mine[#mine + 1] = row end
  end
  return mine
end

-- ---------------------------------------------------------------- case 1: the landing itself
fixture()
local code = running(function() return land.run({ run = "quick1", landing = true, branches = { "change/lua" } }) end)
eq(code, 0, "the landing is green")
local journal = journal_of("quick1")
ok(journal ~= nil, "the run has a journal")
eq(journal.landing, true, "the journal says this round is a landing")
eq(journal.result, "done", "the run is recorded done")
for _, name in ipairs({ "collect", "plan", "merge", "tests", "push", "main", "install", "health", "report" }) do
  ok(step_of("quick1", name) ~= nil, "the landing ran " .. name)
end
for _, name in ipairs({ "review", "gate", "artifacts", "sign", "ship", "publish", "deploy" }) do
  eq(step_of("quick1", name), nil, "a landing runs no " .. name .. " (the gate and the release are the release's)")
end
eq(R.observed.builds, 0, "nothing was built")
eq(R.observed.signs, 0, "nothing was signed")
eq(R.observed.ships, 0, "nothing was shipped")
eq(R.observed.publish, 0, "nothing was published")
local tip = journal.tree_commit
ok(tostring(tip):match("^%x+$") ~= nil, "the journal names the landed tip")
eq(journal.main_sha, tip, "main was moved to the landed tip")
contains(must("git -C " .. repo .. " ls-remote origin refs/heads/main"), tip, "main is the tip on the source of truth (read back)")
eq(trim(must("git -C " .. repo .. " rev-parse HEAD")), tip, "the checkout is fast-forwarded to the tip (the deploy builds it)")
eq(observed.deploy_requests, 1, "exactly one deploy was requested")
contains(read_file(install_dir .. "/installed.txt") or "", "commit=" .. tip, "the install record names the landed tip")
contains(step_of("quick1", "install").detail, "installed.txt names", "the step says what it read")
contains(step_of("quick1", "install").detail, "lua/core equals main's", "and that the installed Lua is this landing's")
-- the health step: NOT the measurement itself (that is minutes), the operation that owns it.
eq(step_of("quick1", "health").state, "done", "the health step started")
local operation = state.health_operation or {}
contains(table.concat(operation.args or {}, " "), "land health-run", "the health step starts `wa land health-run` as its own operation")
contains(table.concat(operation.args or {}, " "), "--sha " .. tip, "and names the tip it measures")
-- the ledger: one row per step, in the order they happened
local rows = rows_of("lua")
local steps = {}
for _, row in ipairs(rows) do steps[#steps + 1] = tostring(row.step) end
contains(table.concat(steps, " "), "started collected planned merged", "the first rows are the landing's start and its plan and merge")
contains(table.concat(steps, " "), "pushed main installed install-verified", "the push, main, the install and the verified record come next, in that order")
ok(table.concat(steps, " "):find("reported done$", 1) ~= nil, "and the round ends with the report and its own done row (got " .. table.concat(steps, " ") .. ")")
for _, row in ipairs(rows) do
  eq(row.kind, "land", "every row of the landing is kind=land")
  eq(row.branch, "change/lua", "every row names the branch")
end
local merged = nil
for _, row in ipairs(rows) do if row.step == "merged" then merged = row end end
ok(merged ~= nil, "the merge is a row")
eq(merged.sha, tip, "the merged row carries the landed sha")
eq(merged.result, "green", "and its verdict")
ok(merged.id ~= nil and tonumber(merged.id) > 0, "every row carries the id the feed follows")
-- THE LINE VICTOR READS, and what it does not claim.
local found, line = said("Local is evolved to " .. tip:sub(1, 12))
ok(found, "the landing ends with `Local is evolved to <sha>` (got: " .. table.concat(captured, " / "):sub(1, 300) .. ")")
contains(line, "You can now test: lua", "and says what to test (the mission's name)")
contains(line, "no brief was recorded", "and says so when nothing describes the steps instead of inventing them")
-- the report reads the landing's own steps
local report = read_file(land.report_path("quick1")) or ""
contains(report, "| tests |", "the report lists the branch's own tests step")
ok(report:find("| deploy |", 1, true) == nil, "and does not list the release's steps the landing never ran")

-- ---------------------------------------------------------------- case 2: the brief is where the "how" comes from
fixture()
local brief = R.fixture .. "/brief.md"
write_file(brief, "# a brief\n\n## How Victor tests it\n`wa land change/lua` in one terminal, and the steps appear.\n\n## Not this section\nignored\n")
local head_lua = trim(must("git -C " .. repo .. " rev-parse refs/heads/change/lua"))
ok(land.ready_mark("change/lua", head_lua, brief), "the ready line records the branch WITH its brief")
local code2 = running(function() return land.run({ run = "quick2", landing = true, ready = true }) end)
eq(code2, 0, "the landing from the ready box is green")
local found2, line2 = said("Local is evolved to")
ok(found2, "the landing still ends with its line")
contains(line2, "wa land change/lua` in one terminal", "and repeats the brief's `How Victor tests it` section")
ok(tostring(line2):find("Not this section", 1, true) == nil, "and nothing past the next heading")

-- ---------------------------------------------------------------- case 3: the branch's own tests decide
fixture()
eq(running(function() return land.run({ run = "quick3", landing = true, branches = { "change/tests" } }) end), 0,
  "a branch whose own test is green lands")
contains(step_of("quick3", "tests").detail, "1 green", "and the step counts the row it ran")

fixture()
local main_before = must("git -C " .. repo .. " ls-remote origin refs/heads/main")
eq(running(function() return land.run({ run = "quick3r", landing = true, branches = { "change/tests-red" } }) end), 1,
  "a red own test stops the landing")
eq(journal_of("quick3r").result, "stopped", "the run is recorded stopped")
eq(step_of("quick3r", "push"), nil, "nothing was pushed")
eq(must("git -C " .. repo .. " ls-remote origin refs/heads/main"), main_before,
  "and main did not move")
contains(step_of("quick3r", "tests").observed, "test-own-red.lua", "the stop names the row that failed")
local red_rows = rows_of("tests-red")
local red_tests = nil
for _, row in ipairs(red_rows) do if row.step == "tests" then red_tests = row end end
ok(red_tests ~= nil and red_tests.result == "red", "the ledger carries the red row for the tests step")
local stopped_row = nil
for _, row in ipairs(red_rows) do if row.step == "stopped" then stopped_row = row end end
ok(stopped_row ~= nil, "and one row that says the landing stopped")
ok(not said("Local is evolved to"), "a stopped landing never claims the node was evolved")

fixture()
eq(running(function() return land.run({ run = "quick3s", landing = true, branches = { "change/one" } }) end), 0,
  "a branch with no test of its own lands")
eq(step_of("quick3s", "tests").state, "skipped", "its tests step is skipped")
contains(step_of("quick3s", "tests").detail, "nothing of its own to run", "with its reason")

fixture()
eq(running(function() return land.run({ run = "quick3t", landing = true, branches = { "change/rust" } }) end), 0,
  "a branch that changes Rust lands")
eq(step_of("quick3t", "tests").state, "skipped", "and its own tests are skipped")
contains(step_of("quick3t", "tests").detail, "Rust", "by name: a Lua row cannot judge a new binary")
contains(step_of("quick3t", "tests").detail, "main-health", "and says who judges it instead")

-- ---------------------------------------------------------------- case 4: scripts/docs only, no deploy
fixture()
eq(running(function() return land.run({ run = "quick4", landing = true, branches = { "change/docs" } }) end), 0,
  "a scripts/docs-only branch lands")
eq(step_of("quick4", "install").state, "skipped", "without a deploy")
eq(observed.deploy_requests, 0, "no deploy was requested")
eq(step_of("quick4", "health").state, "skipped", "and no health run (no lua/ and no rust/)")
contains(trim(must("git -C " .. repo .. " rev-parse HEAD")), trim(journal_of("quick4").tree_commit),
  "the checkout is still fast-forwarded (that is the install for a file no node loads)")
local found4, line4 = said("Local is evolved to")
ok(found4, "the landing still ends with its line")
contains(line4, "the checkout only", "and says the install was the checkout, not a deploy")

-- ---------------------------------------------------------------- case 5: a red main blocks the next landing
fixture()
local base = trim(must("git -C " .. repo .. " rev-parse main"))
ledger.record({ kind = "land", step = "main-health", result = "red", sha = base, mission = "earlier",
  detail = "test-land-plan.lua failed" })
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
  detail = "a red about a main nobody is on" })
eq(running(function() return land.run({ run = "quick5s", landing = true, branches = { "change/lua" } }) end), 0,
  "a red about an older main is stale and blocks nothing")

-- ---------------------------------------------------------------- case 6: the install record is the proof
fixture()
behaviour.install_commit = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
local code6 = running(function()
  return land.run({ run = "quick6", landing = true, branches = { "change/lua" }, install_timeout = 1 })
end)
eq(code6, 1, "an install record that names another commit stops the landing")
contains(tostring(step_of("quick6", "install").error), "install_not_recorded", "by name")
contains(step_of("quick6", "install").observed, "deadbeef", "and quotes what the record does say")
local install_rows = rows_of("lua")
local failed_row = nil
for _, row in ipairs(install_rows) do
  if row.step == "install-failed" and row.result == "red" then failed_row = row end
end
ok(failed_row ~= nil, "the ledger carries a red install-failed row")
ok(not said("Local is evolved to"), "and nothing was announced as installed")

fixture()
behaviour.lua_differs = true
local code6b = running(function() return land.run({ run = "quick6b", landing = true, branches = { "change/lua" } }) end)
eq(code6b, 1, "an installed Lua that is not this landing's stops the landing")
contains(tostring(step_of("quick6b", "install").error), "install_lua_mismatch", "by name")

fixture()
behaviour.sentinel_fails = true
local code6c = running(function() return land.run({ run = "quick6c", landing = true, branches = { "change/lua" } }) end)
eq(code6c, 1, "a refused deploy request stops the landing")
contains(tostring(step_of("quick6c", "install").error), "deploy_not_requested", "and says which door refused")

-- ---------------------------------------------------------------- case 7: --gate is the explicit request
fixture()
eq(running(function() return land.run({ run = "quick7", landing = true, gate = true, branches = { "change/lua" } }) end), 0,
  "--gate runs the fast path and lands when it is green")
eq(observed.gate_runs, 1, "exactly one gate run")
eq(step_of("quick7", "gate").state, "done", "and the gate step is done")
contains(step_of("quick7", "gate").detail, "green on the merged tree", "with its verdict")
fixture()
behaviour.gate_code = 1
local code7 = running(function() return land.run({ run = "quick7r", landing = true, gate = true, branches = { "change/lua" } }) end)
eq(code7, 1, "a red gate stops the landing")
eq(step_of("quick7r", "gate").state, "failed", "at the gate")
eq(step_of("quick7r", "push"), nil, "before anything was pushed")

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
  detail = "main-health could not judge" })
eq(running(function() return land.run({ run = "quick8", landing = true, branches = { "change/lua" } }) end), 0,
  "a `refused` verdict is not a red main and does not block a landing")

-- ---------------------------------------------------------------- case 9: another process reads the rows
fixture()
eq(running(function() return land.run({ run = "quick9", landing = true, branches = { "change/lua" } }) end), 0,
  "a landing to read back")
local binary = host.getenv("WA_FAST_BIN") or ""
local db = host.getenv("WASM_AGENT_DB") or ""
if binary == "" then
  print("SKIP test-land-quick: no WA_FAST_BIN, so the feed cannot be read from another process here "
    .. "(that half is UNPROVEN, not passed)")
else
  local tip9 = journal_of("quick9").tree_commit
  local out = host.exec("env -u WA_SCRIPT -u WA_FAST_ROW_ENV " .. "WASM_AGENT_LUA_ROOT='" ..
    (host.getenv("WASM_AGENT_LUA_ROOT") or "") .. "' HOME='" .. host.paths().home .. "' WASM_AGENT_HOME='" ..
    (host.getenv("WASM_AGENT_HOME") or "") .. "' '" .. binary .. "' --db '" .. db ..
    "' events --kind land --json --limit 200", "")
  local answer = type(out) == "string" and json.decode(out) or out
  local text = type(answer) == "table" and (tostring(answer.stdout or "") .. tostring(answer.stderr or "")) or ""
  contains(text, "\"step\":\"install-verified\"", "another process reads the install-verified row")
  contains(text, tip9, "and the rows carry the landed sha")
end

-- ---------------------------------------------------------------- case 10: a resume keeps the landing's order
fixture()
local resume_branches = { "change/lua" }
local first = running(function()
  return land.run({ run = "quick10", landing = true, branches = resume_branches, no_health = true })
end)
eq(first, 0, "a landing with --no-health lands")
eq(step_of("quick10", "health").state, "skipped", "and records the skip")
contains(step_of("quick10", "health").detail, "--no-health", "by name: main was NOT measured for it")
local again = running(function() return land.run({ run = "quick10", resume = true }) end)
eq(again, 0, "resuming a finished landing is a no-op, not a second landing")
eq(step_of("quick10", "gate"), nil, "the resume never turns the landing into the release's pipeline")
eq(step_of("quick10", "artifacts"), nil, "nor into a release")

if R.count() > 0 and false then os.exit(1) end
print(string.format("landing ok (%d checks)", R.count()))
