-- Item 3 of the harness-fixes-2 round: a gate check's output is on gate.log WHILE it runs, and a failed
-- row keeps its own log.
--
-- MEASURED before this: lua/core/land.lua wrote evidence/gate.log only when a check FINISHED, so a check the
-- gate's timeout killed left NO output - the one thing a reader needs to see why it hung - and a failed
-- row's own log (scripts/fast.sh logs/<row>.log) died with the row's scratch directory.
--
-- This row goes through the REAL gate path (land.impl.gate, no stubbed runner) and a REAL shell command:
-- the check prints a line, then reads ITS OWN gate.log the way a reader would while it is still running,
-- then hangs until the gate's deadline kills it. The line is on disk because the check's own shell wrote it,
-- not because a buffer survived.
--
--   WA_SCRIPT=scripts/test-land-gate-log.lua wa --db <scratch>/t.db
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local json = dofile("lua/vendor/json.lua")

local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-land-gate-log")
if why_home then print("REFUSED test-land-gate-log: " .. why_home); os.exit(2) end

local checks = 0
local function ok(condition, message)
  checks = checks + 1
  if not condition then error("check failed: " .. message, 0) end
end

local land = dofile("lua/core/land.lua")
local home = host.paths().home
land.root_dir = home .. "/land"
local run_id = "gate-log-case1"
host.exec("mkdir -p '" .. land.run_dir(run_id) .. "/evidence'", "", 60)
local log_path = land.evidence_path(run_id, "gate")

-- THE CHECK. It prints, looks for its own line in the gate log from INSIDE the running check (that is what a
-- second reader - an operator, the reviewer - does), writes what it saw, then hangs until the deadline.
local marker = "GATE_STREAMED_LINE_BEFORE_THE_HANG"
local seen_file = home .. "/during-run.txt"
local script = home .. "/gate-hang-check.sh"
host.write_file(script, table.concat({
  "#!/bin/sh",
  "echo " .. marker,
  "if grep -q " .. marker .. " " .. ("'%s'"):format(log_path) .. " 2>/dev/null; then echo yes > " .. ("'%s'"):format(seen_file),
  "else echo no > " .. ("'%s'"):format(seen_file) .. "; fi",
  "sleep 600",
}, "\n") .. "\n")
pcall(host.exec, "chmod +x " .. ("'%s'"):format(script), "", 60)

local run = { id = run_id, tree = host.getenv("WASM_AGENT_LUA_ROOT") or ".",
  journal = { plan = { files = {} }, gate = {} } }
land.weight_decorator = ""
local started = os.time()
local gate_ok = land.impl.gate(run, { checks = { { name = "probe", command = "sh " .. script, timeout = 5 } } })
local elapsed = os.time() - started

-- 1. THE GATE TELLS fast.sh WHERE TO KEEP A FAILED ROW'S OWN LOG (the second half of item 3). Asserted
-- FIRST because it is this change alone: on the base the command carries no such variable, so this row is
-- red there for its own reason and not only for the build-record prefix defect fixed alongside it.
local command = land.gate_command({ name = "fast", command = "bash scripts/fast.sh" }, nil, { id = run_id })
ok(command:find("WA_FAST_KEEP_LOGS=", 1, true) ~= nil,
  "the gate tells fast.sh where to keep a failed row log (got: " .. tostring(command) .. ")")
ok(command:find("WA_FAST_ROWS= ", 1, true) == 1,
  "while WA_FAST_ROWS is still the first assignment (got: " .. tostring(command) .. ")")
local keep_dir = land.run_dir(run_id) .. "/evidence/fast-logs"
ok(command:find(keep_dir, 1, true) ~= nil,
  "and the directory it names is this run own evidence (got: " .. tostring(command) .. ")")

-- 2. THE CHECK REALLY RAN, and the gate read it as failed - a check that hangs is never green (rule 1).
ok(gate_ok == false, "a check that hangs does not pass the gate")
ok(elapsed < 300, "and the gate's own deadline ended it (" .. tostring(elapsed) .. "s)")
local logged = host.read_file(log_path) or ""
ok(logged:find("syntax error", 1, true) == nil,
  "the check was actually executed (no shell syntax error in the prefix): " .. logged:sub(1, 240))

-- 2. THE LINE WAS ON DISK WHILE THE CHECK RAN. The check itself looked, from inside its own execution, so
-- this is not "the output was printed at the end": it was readable during the run, which is exactly what a
-- killed check needs.
local seen = (host.read_file(seen_file) or ""):gsub("%s+$", "")
ok(seen == "yes", "the running check already found its own line in gate.log (it saw: " .. tostring(seen) .. ")")

-- 3. AND IT SURVIVED THE KILL. The check was killed at the deadline, and the line is still in the evidence.
ok(logged:find(marker, 1, true) ~= nil,
  "the line printed before the hang is in gate.log after the check was killed (" .. tostring(#logged) .. " bytes)")


print("land-gate-log ok (" .. checks .. " checks)")