-- ONE answer to "run one statement and read the host's reply" (ARCHITECTURE.md laws 17-18, 27/11).
--
-- Four modules used to spell it themselves - `agent_control.lua`, `backup.lua`, `completions.lua` and `done_gate.lua` -
-- each with its own decode, its own `error` field check and its own way of saying "no answer". A fix in one (a host that
-- returns the table instead of the JSON string, an answer that is not a table, an error that arrives lower-cased) was owed
-- to the other three, and nothing made that visible. This is the owner: it RUNS and REPORTS, and the caller keeps its
-- policy - raise with a prefix, return `nil, why`, retry, or wrap in `sqlite_busy.retry`.
local json = dofile("lua/vendor/json.lua")

local M = {}

-- `value, why`: on success the decoded answer (a table), on failure nil and the reason as a string. It never raises, so a
-- caller that wants an error says how it wants it said.
function M.run(method, statement, params)
  local ok, raw = pcall(host[method], statement, json.encode(params or {}))
  if not ok then return nil, tostring(raw) end
  local value = raw
  if type(raw) == "string" then
    local decoded_ok, decoded = pcall(json.decode, raw)
    if not decoded_ok then return nil, "unreadable answer from " .. tostring(method) .. ": " .. tostring(decoded) end
    value = decoded
  end
  if type(value) ~= "table" then return nil, "no answer from " .. tostring(method) end
  if value.error then return nil, tostring(value.error) end
  return value
end

return M
