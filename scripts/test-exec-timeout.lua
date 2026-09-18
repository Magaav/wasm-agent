-- A command must not be able to hold the interpreter forever.
--
-- It happened: an agent curled *this node's own* HTTP port from inside a turn. The request queued
-- behind the very turn that made it, so it could never be served, and `curl` has no timeout - the
-- worker waited on itself for six minutes until somebody killed the curl. The node reported the stall
-- honestly (`ok:false`, `worker:stalled`, the age of the silence), which is how it was found, but
-- reporting a deadlock is not the same as not having one.
--
-- Run from the repo root with a short deadline:
--   WASM_AGENT_EXEC_TIMEOUT_SECONDS=2 WA_SCRIPT=scripts/test-exec-timeout.lua wa --db /tmp/x.db
local json = dofile("lua/vendor/json.lua")

local checks = 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then error(label .. (detail and (" - " .. tostring(detail)) or "")) end
end

-- 1. A command that never finishes is killed, and says so.
local started = host.now()
local stuck = json.decode(host.exec("sleep 30"))
local took = host.now() - started
ok(took < 10, "a hanging command must be killed at the deadline, not waited on", string.format("%.1fs", took))
ok(stuck.code == -1, "and reported as a failure", tostring(stuck.code))
ok(tostring(stuck.stderr):find("did not finish", 1, true) ~= nil,
  "with a reason, not a silence", tostring(stuck.stderr):sub(1, 80))
-- The reason has to be usable by whoever reads it: naming the likely cause is the difference between
-- a dead end and the next step.
ok(tostring(stuck.stderr):find("this node", 1, true) ~= nil,
  "and one that names the self-call that causes it", tostring(stuck.stderr):sub(1, 120))

-- 2. Normal commands are unaffected - the same path, no deadline trouble.
local hello = json.decode(host.exec("echo hello"))
ok(hello.code == 0, "a normal command still succeeds", tostring(hello.code))
ok(tostring(hello.stdout):find("hello", 1, true) ~= nil, "with its output", tostring(hello.stdout))
local slow = json.decode(host.exec("sleep 1; echo done"))
ok(slow.code == 0 and tostring(slow.stdout):find("done", 1, true) ~= nil,
  "and one that takes a second finishes normally")

-- 3. Output is not truncated for a command that fills the pipe: the readers drain it while the child
-- runs, which is the other way this deadlocks if written the obvious way.
local big = json.decode(host.exec("seq 1 20000 | wc -l"))
ok(big.code == 0 and tostring(big.stdout):find("20000", 1, true) ~= nil,
  "and a command with a lot of output is drained, not deadlocked", tostring(big.stdout):sub(1, 40))

print("exec timeout ok (" .. checks .. " checks)")
