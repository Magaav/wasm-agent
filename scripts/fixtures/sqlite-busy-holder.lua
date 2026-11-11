-- The second connection: it holds the node database's WRITE lock, on purpose, for a fixed time.
--
-- "holder: locked" is printed only after `BEGIN IMMEDIATE` succeeded AND a real row was written inside
-- that transaction - a BEGIN whose insert never happened would not prove the lock is held, and the
-- fixture would be a claim rather than contention. The driver waits for that line before it starts the
-- subject.
--
--   WA_HOLD_MS=6000 WA_SCRIPT=scripts/fixtures/sqlite-busy-holder.lua wa --db <db>
local json = dofile("lua/vendor/json.lua")

local function exec(statement, params)
  local result = json.decode(host.sql_exec(statement, json.encode(params or {})))
  if type(result) ~= "table" or result.error then
    return nil, tostring(type(result) == "table" and result.error or "no_result_from_host")
  end
  return result
end

local hold = tonumber(host.getenv("WA_HOLD_MS") or "6000") or 6000

local ok, problem = exec("CREATE TABLE IF NOT EXISTS busy_probe(at REAL)")
if not ok then print("holder: failed " .. problem); os.exit(1) end
ok, problem = exec("BEGIN IMMEDIATE")
if not ok then print("holder: failed " .. problem); os.exit(1) end
ok, problem = exec("INSERT INTO busy_probe(at) VALUES(?)", { host.now() })
if not ok then print("holder: failed " .. problem); os.exit(1) end

print("holder: locked")
-- Unbuffered: the driver waits for this exact line, and a buffered pipe would deadlock the fixture
-- instead of failing it.
pcall(function() io.stdout:flush() end)

host.sleep(tostring(hold))
exec("ROLLBACK")
print("holder: released")
