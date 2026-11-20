-- Review r2, item 1: a served session REUSES one agent for its whole life, so a failure record that
-- is only written when `self.failure==nil` silences every failure after the first. Two failed turns on
-- ONE agent must leave TWO durable failure rows - otherwise the session fails silently from then on,
-- which is the class of stop this whole mission exists to remove.
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
local function eq(got, want, label)
  checks = checks + 1
  if got ~= want then
    failed = failed + 1
    print(string.format("FAIL two-failures: %s (got %s, want %s)", label, tostring(got), tostring(want)))
  end
end
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL two-failures: " .. label)
  end
end

memory.setup()
local user = "two-failures"
local session = "two-failures-session"
if not memory.session(session) then
  memory.start_session("", "two failures", { id = session, user_id = user, node_id = "" })
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

-- The durable failure rows this session has written.
local function failure_rows()
  local rows = memory.session_messages(session, { limit = 200 })
  if type(rows) ~= "table" then return 0 end
  local count = 0
  for _, row in ipairs(rows) do
    if type(row) == "table" then
      local text = tostring(row.content or "")
      local failed_row = row.ok == false or row.ok == 0 or row.ok == "false"
      if failed_row and text:find("run_failed:", 1, true) ~= nil then count = count + 1 end
    end
  end
  return count
end

-- ONE agent, reused for both turns - exactly how lua/core/server.lua keeps a served session.
host.http_stream = function()
  return json.encode({ error = "timeout: receive response (provider_stalled: no response within 90s)" })
end
local agent = agentlib.new(session, function() end, "master", user, "local")
agent.stream = true

local first_ran = pcall(agent.run, agent, "the first turn the provider will not answer")
local after_first = failure_rows()
ok(not first_ran, "the first turn fails")
-- EXACT counts (review r3, B1): one failed turn is ONE row. `>= 1` would pass a run that wrote
-- three, which is a different defect.
eq(after_first, 1, "the first failed turn wrote exactly one durable failure row")

local second_ran = pcall(agent.run, agent, "the second turn the provider will not answer")
local after_second = failure_rows()
ok(not second_ran, "the second turn fails too")
eq(after_second, 2,
  "the SAME agent's second failed turn left TWO rows, not one: a reused served session must never go silent")

host.sleep = real_sleep
host.getenv = real_getenv

print(string.format("ok two-failures: %d checks, %d failed", checks, failed))
if failed > 0 then os.exit(1) end
