-- Reasoning replay is a choice, not a requirement.
--
-- The model store marks this provider `requiresReasoningContentOnAssistantMessages`, so the
-- runtime re-sent every prior thought on every request: measured over 48h, reasoning was
-- 522 KB of the average 1.3 MB request. But the provider accepts an assistant message that
-- carries no reasoning_content at all - proven by calling it both ways and getting 200 back
-- for each - so the flag is conservative metadata and an operator may turn the replay off.
--
-- The gate runs this twice, with WASM_AGENT_REASONING_REPLAY=1 and =0, because the switch
-- has to reach the *request*, not only the setting: a flag nobody reads is not a lever.
local json = dofile("lua/vendor/json.lua")
local provider = dofile("lua/core/provider.lua")
local agentlib = dofile("lua/core/agent.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label) end
end

local expected = os.getenv("WASM_AGENT_REASONING_REPLAY") ~= "0"
local decision = provider.reasoning()
ok(decision.replay == expected,
  "the switch must decide replay: expected " .. tostring(expected) .. " got " .. tostring(decision.replay))

-- Drive one turn whose first step is a tool call, so the second request re-sends the
-- assistant message and its body can be inspected. Stubbing host.http_stream keeps the
-- real request-building in the path - the wiring is what is under test, not a copy of it.
local bodies = {}
local step = 0
local real_stream = host.http_stream
host.http_stream = function(_method, _url, _headers, body)
  step = step + 1
  bodies[#bodies + 1] = tostring(body or "")
  if step == 1 then
    return json.encode({ status = 200, content = "",
      reasoning = "I should look at the file before answering.",
      finish_reason = "tool_calls", tool_calls = { { id = "c1", type = "function",
        ["function"] = { name = "read", arguments = '{"path":"AGENTS.md","limit":5}' } } } })
  end
  return json.encode({ status = 200, content = "done", finish_reason = "stop", tool_calls = {} })
end

local session_id = memory.ensure_session("reasoning-replay-test", "local", "replay")
local agent = agentlib.new(session_id, function() end, "master", "reasoning-replay-test", "local")
agent.stream = true
local ran, err = pcall(agent.run, agent, "read the file and answer")
host.http_stream = real_stream
ok(ran, "the turn must run: " .. tostring(err))
ok(#bodies >= 2, "a tool call must produce a second request, got " .. #bodies)

local second = bodies[2]
local carried = second:find("reasoning_content", 1, true) ~= nil
ok(carried == expected,
  "the second request must " .. (expected and "carry" or "omit") .. " the prior reasoning")
-- The tool call itself must survive either way: dropping the thinking must not drop the route.
ok(second:find("I should look at the file", 1, true) ~= nil or not expected,
  "only the reasoning may be dropped, never the tool call that carries the route")
ok(second:find("\"read\"", 1, true) ~= nil, "the tool call must still be in the second request")

print("reasoning replay ok (" .. checks .. " checks)")
