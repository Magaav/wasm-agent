-- The subject of "a lock that cannot be had ends with a name, not with a crash": one `append_turn`
-- in a fresh process, against a database whose write lock another process is holding. Its retry
-- budget is set low by the driver so the fixture fails fast and deterministically.
--
-- The schema call and the append are both inside the pcall: the first interpreter to touch a store
-- applies the migration, and that is a WRITE under the same lock, so it is the same failure and it
-- must be reported the same way rather than escaping as an uncaught `lua error:`.
--
-- Exit code is 0 either way: the ANSWER is the assertion. The driver checks that it is
-- `database_busy: ... (retryable)` and that the process reported it instead of dying.
local memory = dofile("lua/core/memory.lua")

local ok, problem = pcall(function()
  memory.setup()
  return memory.append_turn("sqlite-busy-subject", {
    role = "user", content = "subject:" .. tostring(host.now()),
  })
end)
if ok then
  print("subject: stored")
else
  print("subject: error " .. tostring(problem))
end
