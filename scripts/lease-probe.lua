-- Process B of the cross-process lease proof (review r2, item 3). Run by
-- scripts/test-run-lease-order.lua through host.exec, in its OWN process, at the instant process A
-- releases its run lease and before A announces the failure.
--
-- It answers two facts, and the second is what discriminates:
--   ok            did the claim store ADMIT this session (the lease is free)
--   failure_rows  how many durable run_failed rows the session already has (0 => the failure has not
--                 been announced yet)
local json = dofile("lua/vendor/json.lua")
local resources = dofile("lua/core/resources.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()

local session = tostring(host.getenv("LEASE_PROBE_SESSION") or "")
local user = tostring(host.getenv("LEASE_PROBE_USER") or "")
local out = tostring(host.getenv("LEASE_PROBE_OUT") or "")

local rows = 0
local listed = memory.session_messages(session, { limit = 200 })
if type(listed) == "table" then
  for _, row in ipairs(listed) do
    if type(row) == "table" then
      local text = tostring(row.content or "")
      local failed_row = row.ok == false or row.ok == 0 or row.ok == "false"
      if failed_row and text:find("run_failed:", 1, true) ~= nil then rows = rows + 1 end
    end
  end
end

local ctx = { session_id = session, user_id = user, run_id = host.uuid() }
local claimed = resources.begin(ctx)
if claimed.ok then resources.finish(ctx) end
local answer = { ok = claimed.ok == true, error = claimed.error, failure_rows = rows }
if out ~= "" then pcall(host.write_file, out, json.encode(answer)) end
print("probe: " .. json.encode(answer))
