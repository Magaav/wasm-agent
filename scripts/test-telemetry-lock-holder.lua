-- The second connection: it holds the node database's WRITE lock in a transaction, on purpose, for a
-- fixed time. This is how the telemetry path is tested where it actually broke - under contention.
--
--   WA_LOCK_HOLD_MS=6000 WA_SCRIPT=scripts/test-telemetry-lock-holder.lua wa --db <db>
--
-- "holder: locked" is printed only after `BEGIN IMMEDIATE` succeeded AND a real row was written inside
-- that transaction. A BEGIN whose insert never happened would not prove the lock is held, and the whole
-- fixture would be a claim rather than a contention. The driver waits for that line before it starts
-- the subject, so the two never race.
local json = dofile("lua/vendor/json.lua")

local function exec(statement, params)
  local result = json.decode(host.sql_exec(statement, json.encode(params or {})))
  if type(result) ~= "table" or result.error then
    return nil, tostring(type(result) == "table" and result.error or "no_result_from_host")
  end
  return result
end

local hold = tonumber(host.getenv("WA_LOCK_HOLD_MS") or "6000") or 6000

local ok, problem = exec("CREATE TABLE IF NOT EXISTS telemetry_lock_probe(at REAL)")
if not ok then print("holder: failed " .. problem); os.exit(1) end
ok, problem = exec("BEGIN IMMEDIATE")
if not ok then print("holder: failed " .. problem); os.exit(1) end
ok, problem = exec("INSERT INTO telemetry_lock_probe(at) VALUES(?)", {host.now()})
if not ok then print("holder: failed " .. problem); os.exit(1) end

print("holder: locked")
-- Unbuffered, because the driver is waiting for this exact line before it starts the subject: a
-- buffered pipe would deadlock the fixture instead of failing it.
pcall(function() io.stdout:flush() end)

host.sleep(tostring(hold))
exec("ROLLBACK")
print("holder: released")
