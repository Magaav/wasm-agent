-- Item 3 of the harness-fixes-2 round: a gate check's output is on disk WHILE it runs, and a failed row
-- keeps its own log.
--
-- MEASURED before this: lua/core/land.lua wrote evidence/gate.log only when a check FINISHED, so a check the
-- gate's timeout killed left NO output - the one thing a reader needs to see why it hung - and a failed
-- row's own log (scripts/fast.sh logs/<row>.log) was deleted with the row's scratch directory.
--
-- What is REAL here: the streaming runner (land.exec_streamed) against the REAL host.exec, a real shell
-- command that prints and then hangs, and a real `timeout` that kills it. Nothing is stubbed.
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
local log_path = home .. "/gate.log"
pcall(host.exec, "mkdir -p " .. ("'%s'"):format(home), "", 60)
pcall(host.exec, "rm -f " .. ("'%s'"):format(log_path), "", 60)

-- THE CHECK: print one line, then hang. `timeout 2` is the gate deadline in miniature; the runner wraps the
-- command, so the kill is the shell's own - exactly the shape the gate uses.
local marker = "GATE_STREAMED_LINE_BEFORE_THE_HANG"
local command = string.format("printf '%s\\n'; sleep 600", marker)
local started = os.time()
local result = land.exec_streamed("timeout 2 sh -c " .. ("'%s'"):format(command:gsub("'", "'\\''")), "", 30,
  log_path)
local elapsed = os.time() - started

-- 1. THE CHECK WAS KILLED, not passed: an unknown exit is never a yes (rule 1).
ok(type(result) == "table", "the streamed runner answers a result table")
ok(result.code ~= 0, "a check that hangs is not green (code " .. tostring(result.code) .. ")")
ok(elapsed < 30, "and the deadline ended it (" .. tostring(elapsed) .. "s), it did not wait 10 minutes")

-- 2. WHAT IT PRINTED IS ON DISK, and it was written by the CHECK as it printed - not by a buffer that
-- needed the call to return. That is the whole fix: the file is readable while the check runs.
local logged = host.read_file(log_path) or ""
ok(logged:find(marker, 1, true) ~= nil,
  "the printed line is in the gate log after the check was killed (log: " .. tostring(logged):sub(1, 300) .. ")")

-- 3. THE CALLER GETS ONLY ITS OWN CHECK'S OUTPUT. `result.stdout` is measured from the byte offset the log
-- had when this check started, so a previous check's lines are not counted twice (the tests count depends on
-- it).
ok(tostring(result.stdout or ""):find(marker, 1, true) ~= nil,
  "the result carries the check's own output (got: " .. tostring(result.stdout):sub(1, 200) .. ")")
local second = land.exec_streamed("printf 'SECOND_CHECK_ONLY\\n'", "", 30, log_path)
ok(tostring(second.stdout or ""):find("SECOND_CHECK_ONLY", 1, true) ~= nil, "a second check reports its own line")
ok(tostring(second.stdout or ""):find(marker, 1, true) == nil,
  "and NOT the first check's line: the offset is measured, not assumed")

-- 4. NO LOG PATH IS THE HONEST FALLBACK: the plain runner, same shape, nothing invented.
local plain = land.exec_streamed("printf 'PLAIN_PATH\\n'", "", 30, "")
ok(plain.code == 0, "a check with no log to stream into still runs (code " .. tostring(plain.code) .. ")")
ok(tostring(plain.stdout or ""):find("PLAIN_PATH", 1, true) ~= nil, "and still reports its output")

print("land-gate-log ok (" .. checks .. " checks)")