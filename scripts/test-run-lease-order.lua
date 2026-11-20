-- Item 2 (review 19/11): the run lease is released BEFORE the failure is signalled.
--
-- Measured on avell (which runs the BASE binary): the guard stopped the turn at 22:53:0xZ, the
-- `--resume` at 22:53:18Z was refused `run_resource_refused resource_busy`, and a launch at 22:54:33Z
-- passed. The release was unconditional already, but it sat AFTER run_failure.handle - which records
-- the failure, publishes it and schedules a wake, real work that took over a minute there. For that
-- whole window the session was still claimed by a run that had already ended.
--
-- HOW THIS PROVES THE ORDER. `dofile` in this node returns a FRESH table every time (measured:
-- rawequal(dofile(x), dofile(x)) == false), so hooking a module never reaches the copy the agent
-- loaded. host.resource is process-wide and cannot be shadowed that way. When the agent releases the
-- lease we are inside that hook, and the durable failure row is either written yet or not:
--   * release-first -> at `finish`, NO "run_failed:" row exists yet;
--   * release-last  -> at `finish`, that row is already there.
-- scripts/test-run-lease-order.sh reverts the order and requires this file to fail.
--
-- Scratch node only. Refuses the real ~/.wasm-agent.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local agentlib = dofile("lua/core/agent.lua")

do
  local home = tostring(host.getenv("WASM_AGENT_HOME") or "")
  local trimmed = home:gsub("[/\\]+$", "")
  local scratch = trimmed:find("scratch", 1, true) ~= nil or trimmed:find("tmp", 1, true) ~= nil
    or trimmed:find("temp", 1, true) ~= nil or trimmed:find("TMP", 1, true) ~= nil
    or trimmed:match("^/var/folders/") ~= nil
  local real_node = trimmed:match("[/\\]%.wasm%-agent$") ~= nil
  if home == "" or not scratch or real_node then
    print("refusing to run: WASM_AGENT_HOME must be a scratch or temp directory, and never the node's own ~/.wasm-agent (got "
      .. tostring(home) .. ")")
    os.exit(2)
  end
end

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL lease-order: " .. label)
  end
end

memory.setup()
local user = "lease-order"
local session = "lease-order-session"
if not memory.session(session) then
  memory.start_session("", "lease order", { id = session, user_id = user, node_id = "" })
end

local real_getenv = host.getenv
host.getenv = function(key)
  if key == "WASM_AGENT_LLM_API_KEY" then return "test-only" end
  if key == "WASM_AGENT_PROVIDER_RETRIES" then return "0" end
  if key == "WASM_AGENT_PROVIDER_RESPONSE_TIMEOUT_RETRIES" then return "0" end
  return real_getenv(key)
end
local real_sleep = host.sleep
host.sleep = function() end

-- The durable failure rows for this session, as they stand at the instant asked.
local function failure_rows()
  local rows = memory.session_messages(session, { limit = 120 })
  if type(rows) ~= "table" then return nil end
  local count = 0
  for _, row in ipairs(rows) do
    if type(row) == "table" then
      local text = tostring(row.content or "")
      local failed = row.ok == false or row.ok == 0 or row.ok == "false"
      if failed and text:find("run_failed:", 1, true) ~= nil then count = count + 1 end
    end
  end
  return count
end

-- THE HOOK: process-wide, so it sees the agent's own claim-store calls.
local release_seen, rows_at_release = false, nil
local real_resource = host.resource
host.resource = function(action, args_json)
  if action == "finish" and not release_seen then
    release_seen = true
    rows_at_release = failure_rows()
  end
  return real_resource(action, args_json)
end

local agent = agentlib.new(session, function() end, "master", user, "local")
agent.stream = true
host.http_stream = function()
  return json.encode({ error = "timeout: receive response (provider_stalled: no response within 90s)" })
end
local ran = pcall(agent.run, agent, "a turn the provider will not answer")
host.resource = real_resource
host.sleep = real_sleep
host.getenv = real_getenv

ok(not ran, "the turn fails on the stalled provider")
ok(release_seen, "the run released its lease")
if rows_at_release == nil then
  -- Unknown is not yes: without the rows at that instant the order is unproven, so refuse.
  ok(false, "the failure rows could not be read at release time, so the order is unproven")
else
  ok(rows_at_release == 0,
    "the lease was released BEFORE the failure was recorded and announced (failure rows at release: "
      .. tostring(rows_at_release) .. ")")
end
-- And the failure IS recorded afterwards - otherwise "zero rows" would prove nothing.
local after = failure_rows()
ok(after ~= nil and after >= 1, "the failed run still wrote its named failure row (" .. tostring(after) .. ")")

print(string.format("ok lease-order: %d checks, %d failed", checks, failed))
if failed > 0 then os.exit(1) end
