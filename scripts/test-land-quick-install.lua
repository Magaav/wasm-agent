-- `wa land <branch>`: THE INSTALL RECORD IS THE PROOF, --gate, ANOTHER PROCESS, AND A RESUME.
--
-- One of five parts by subject (scripts/lib/land-quick.lua says why). The install is the RECORD, not the
-- version: installed.txt must name the landed commit and the installed Lua must be the landed tree's, or the
-- landing stops and writes a red install-failed row. --gate is the explicit request for the whole fast path on
-- the merged tree. Every step is an EVENT with one schema and ANOTHER PROCESS reads the same rows. And a
-- resume keeps the landing's own order and flags - never the release's pipeline.
local Q = dofile("scripts/lib/land-quick.lua")
Q.arm("test-land-quick-install.lua")
local R = Q.R
local land, repo, ok, eq, contains, must, write_file, read_file = Q.land, Q.repo, Q.ok, Q.eq, Q.contains, Q.must, Q.write_file, Q.read_file
local setup_fixture, journal_of, step_of, marker = Q.setup_fixture, Q.journal_of, Q.step_of, Q.marker
local json, state, ledger, trim = Q.json, Q.state, Q.ledger, Q.trim
local behaviour, observed, install_dir = Q.behaviour, Q.observed, Q.install_dir
local fixture, branch_with, main_grows, first_line_ish = Q.fixture, Q.branch_with, Q.main_grows, Q.first_line_ish
local running, said, rows_of = Q.running, Q.said, Q.rows_of
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
