-- Item 1 of the harness-fixes-2 round: WA_SCRIPT belongs to the process the host started, never to a child.
--
-- MEASURED 20/11, twice: the variable stayed in the environment, so EVERY child `wa` a script started ran
-- the script instead of its own command. A `wa land` run forked itself recursively (hundreds of `wa`, CPU
-- at 95 C), and a test row's `wa nodes probe` child re-ran the whole test and printed "remote refusals ok"
-- where a probe answer was expected (fixed defensively in fee2b118 with a pcall; the cause is the host).
--
-- THE TEST IS SAFE TO RUN ON THE BASE, WHERE THE BUG IS LIVE. A recursion is what the bug does, so this
-- row never lets one start: the script itself refuses at HF2_WA_SCRIPT_DEPTH > 1 and exits by name. The
-- child that re-runs the script therefore stops at depth 1 - it PRINTS the marker, it does not fork. The
-- row fails because the marker is there, not because the machine fills up.
--
--   WA_SCRIPT=scripts/test-wa-script-child.lua wa --db <scratch>/t.db
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local json = dofile("lua/vendor/json.lua")

-- The scratch-home rule, first: this row starts child processes and writes a ledger.
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-wa-script-child")
if why_home then print("REFUSED test-wa-script-child: " .. why_home); os.exit(2) end

local checks = 0
local function ok(condition, message)
  checks = checks + 1
  if not condition then error("check failed: " .. message, 0) end
end

-- THE DEPTH GUARD, BEFORE ANYTHING ELSE. On the base a child `wa` re-runs this file; that child must stop
-- here and say so, in one line, instead of starting a child of its own.
local depth = tonumber(host.getenv("HF2_WA_SCRIPT_DEPTH") or "0") or 0
if depth > 0 then
  -- A child that reaches this line RE-RAN THE SCRIPT: the defect this row exists to catch. It says so and
  -- stops - it does not run a check, and it does not start another `wa`.
  print("CHILD_RE_RAN_THE_SCRIPT depth=" .. tostring(depth))
  os.exit(0)
end

local binary = tostring((json.decode(host.runtime_info()) or {}).binary_path or "")
ok(binary ~= "", "this process can name its own binary (host.runtime_info)")

-- <command> -> code, stdout+stderr. The child is given the depth counter, so even on the base its
-- re-run of this script stops at the first line.
local function run_child(command)
  local ok_exec, raw = pcall(host.exec, "HF2_WA_SCRIPT_DEPTH=1 " .. command, "", 120)
  local decoded = ok_exec and json.decode(raw) or nil
  if type(decoded) ~= "table" then return 127, tostring(raw) end
  if decoded.error ~= nil and decoded.error ~= json.null then return 127, tostring(decoded.error) end
  return tonumber(decoded.code) or 1, tostring(decoded.stdout or "") .. tostring(decoded.stderr or "")
end

-- 1. THE CHILD SEES NO WA_SCRIPT AT ALL. This is the fix itself, stated as the contract: the host takes the
-- variable for its own process, so nothing it starts can read it and believe it is a script run.
do
  local code, output = run_child('printf "WA_SCRIPT=[%s]\\n" "${WA_SCRIPT-unset}"')
  ok(code == 0, "a child command runs (" .. tostring(code) .. ": " .. output:sub(1, 200) .. ")")
  ok(output:find("WA_SCRIPT=[unset]", 1, true) ~= nil,
    "a child of a script run inherits no WA_SCRIPT (saw: " .. output:sub(1, 200) .. ")")
end

-- 2. A CHILD `wa` DOES ITS OWN JOB. `wa help` reaches the command dispatch - the branch the WA_SCRIPT
-- runner short-circuits - so on the base it never gets there: it re-runs this file instead and the marker
-- below is what comes back. That is the measured defect, end to end, across a process boundary.
do
  local code, output = run_child(binary .. " help")
  ok(output:find("CHILD_RE_RAN_THE_SCRIPT", 1, true) == nil,
    "a child `wa help` did not re-run this test script (it printed: " .. output:sub(1, 300) .. ")")
  ok(code == 0, "and the child ran its own command to completion (" .. tostring(code) .. ": " .. output:sub(1, 200) .. ")")
  ok(output:find("CHILD_RE_RAN_THE_SCRIPT", 1, true) == nil or depth > 0,
    "the marker can only appear in a child that re-ran the script, which is the defect")
end

-- 3. THE PROCESS ITSELF STILL KNOWS. The flag the variable used to carry is kept, per process, or a
-- running test would start touching the real node's housekeeping state (lua/core/server.lua asks it).
ok(host.script_run ~= nil, "the host answers whether this process is a script run (host.script_run)")
ok(host.script_run() == true, "and it says yes for this row, which IS a script run")
ok(host.getenv("WA_SCRIPT") == nil,
  "the variable itself is gone from this process's environment (host.getenv), so no reader can be misled")

print("wa-script-child ok (" .. checks .. " checks)")