-- One process in the contention fixture (`scripts/test-sqlite-busy.lua`): a writer that appends turns
-- through `memory.append_turn` - the unit a run actually died of - or a reader that answers calls
-- through `host.sql_query`. Each of these is a separate OS process with its own interpreter and its
-- own connection to the same WAL database, which is what a `serve` lane and the CLI are.
--
-- Prints exactly one machine-readable line the driver asserts on:
--   worker: ok kind=<kind> tag=<tag> ops=<n>
-- and exits nonzero on the first failure, with the error's own text.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")

local kind = host.getenv("BUSY_KIND") or "writer"
local tag = host.getenv("BUSY_TAG") or "0"
local count = tonumber(host.getenv("BUSY_N") or "12") or 12
local session = "sqlite-busy"

memory.setup()

local function fail(where, problem)
  print(string.format("worker: FAIL kind=%s tag=%s at=%s: %s", kind, tag, where, tostring(problem)))
  os.exit(1)
end

if kind == "writer" then
  for i = 1, count do
    local ok, problem = pcall(memory.append_turn, session, {
      role = "user", content = "w:" .. tag .. ":" .. i,
    })
    if not ok then fail("append:" .. i, problem) end
    ok, problem = pcall(memory.append_turn, session, {
      role = "assistant", content = "a:" .. tag .. ":" .. i,
    })
    if not ok then fail("append:" .. i, problem) end
  end
else
  for i = 1, count do
    local ok, raw = pcall(host.sql_query, "SELECT COUNT(*) AS n FROM messages WHERE session_id=?", json.encode({ session }))
    if not ok then fail("read:" .. i, raw) end
    local rows = json.decode(raw)
    if type(rows) ~= "table" or rows.error then fail("read:" .. i, rows and rows.error) end
    -- A read that answered nil here would be a read that silently lost the store.
    if not rows[1] or tonumber(rows[1].n) == nil then fail("read:" .. i, "no count") end
    local session_row = memory.session(session)
    if session_row == nil or session_row.id ~= session then fail("session:" .. i, "unreadable") end
  end
end

print(string.format("worker: ok kind=%s tag=%s ops=%d", kind, tag, count))
