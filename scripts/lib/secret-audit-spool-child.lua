-- The child process scripts/test-secret-audit.lua starts and then KILLS, to prove that a refused audit
-- record is kept where a kill cannot lose it.
--
-- It arms ONE refusal - the host's own answer when another connection holds the ledger's write lock -
-- writes its record through `telemetry.audit`, prints what happened, and then holds the process open until
-- the parent's `timeout -s KILL` ends it. Nothing in this process ever flushes the spool: that is the point.
local json = dofile("lua/vendor/json.lua")
local real_getenv = host.getenv
host.getenv = function(key)
  if key == "WASM_AGENT_SQLITE_RETRY_ATTEMPTS" then return "1" end
  if key == "WASM_AGENT_TELEMETRY_WRITE_ATTEMPTS" then return "1" end
  return real_getenv(key)
end
local real_sql_exec = host.sql_exec
host.sql_exec = function(statement, params)
  local text = tostring(statement or "")
  local kind = nil
  if text:find("INSERT INTO harness_events", 1, true) then
    local ok, decoded = pcall(json.decode, tostring(params or "[]"))
    if ok and type(decoded) == "table" then kind = decoded[5] end
  end
  if kind == "secret_redacted" then return json.encode({ error = "database is locked" }) end
  return real_sql_exec(statement, params)
end
local memory = dofile("lua/core/memory.lua")
local telemetry = dofile("lua/core/telemetry.lua")
memory.setup()
telemetry.setup()
local sid = memory.ensure_session("spool-child", "local", "child")
local recorded, why = telemetry.audit(sid, "child-run", "child-span", "secret_redacted", "redacted",
  { tool = "bash", names = { WASM_AGENT_LLM_API_KEY = 1 } })
print(string.format("CHILD recorded=%s owed=%d why=%s", tostring(recorded), telemetry.owed(), tostring(why)))
-- A live process, not one that exited politely: a process that ended by itself never had to survive a kill.
local deadline = host.monotonic_ms() + 60000
while host.monotonic_ms() < deadline do host.sleep(50) end
