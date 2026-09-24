-- Reasoning replay is prefix-stable, and that is the property this test protects.
--
-- A thought is sent in full during its own turn. If a later turn replaced it with an empty
-- field, the provider's longest-common-prefix would end at that message and every message
-- after it would be recomputed at the full input rate. Measured with the provider's own
-- prefix_audit: full replay and consistent omission are `append_only` across turns, while
-- emptying a sent thought is `rewritten`. Input bills at ~50x the cache-read rate and the
-- recomputed suffix contains the dropped reasoning, so a partial replay is a net loss.
--
-- This drives two turns and asserts every request after the first extends the previous one,
-- so a future "window" fails here rather than in a bill. The gate runs it with replay on and
-- replay off: the switch must reach the request, and neither setting may rewrite the prefix.
local json = dofile("lua/vendor/json.lua")
local provider = dofile("lua/core/provider.lua")
local agentlib = dofile("lua/core/agent.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local telemetry = dofile("lua/core/telemetry.lua")
telemetry.setup()

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label) end
end

local expected = os.getenv("WASM_AGENT_REASONING_REPLAY") ~= "0"
local decision = provider.reasoning()
ok(decision.replay == expected,
  "the switch must decide replay: expected " .. tostring(expected) .. " got " .. tostring(decision.replay))
ok(decision.replay_window == nil,
  "there must be no replay window: replay is all-or-nothing (see provider.reasoning)")

-- Two turns, each with a tool call, so the second turn's first request is built from a
-- transcript that already holds prior thoughts. Stubbing host.http_stream keeps the real
-- request-building and the real prefix_audit in the path - the wiring is what is under test.
local bodies = {}
local current_turn, step = 1, 0
local function tool_call(thought, id)
  return json.encode({ status = 200, content = "", reasoning = thought,
    finish_reason = "tool_calls", tool_calls = { { id = id, type = "function",
      ["function"] = { name = "read", arguments = '{"path":"AGENTS.md","limit":5}' } } } })
end
local real_stream = host.http_stream
host.http_stream = function(_method, _url, _headers, body)
  bodies[#bodies + 1] = tostring(body or "")
  if current_turn == 1 then
    step = step + 1
    if step == 1 then return tool_call("FIRSTTHOUGHT about the file", "c1") end
    if step == 2 then return tool_call("SECONDTHOUGHT after the read", "c2") end
  end
  return json.encode({ status = 200, content = "done", finish_reason = "stop", tool_calls = {} })
end

local session_id = memory.ensure_session("reasoning-replay-test", "local", "replay")
local agent = agentlib.new(session_id, function() end, "master", "reasoning-replay-test", "local")
agent.stream = true
local ran, err = pcall(agent.run, agent, "read the file and answer")
ok(ran, "the first turn must run: " .. tostring(err))
local first_turn_requests = #bodies
current_turn = 2
local ran_second, err_second = pcall(agent.run, agent, "and again")
host.http_stream = real_stream
ok(ran_second, "the second turn must run: " .. tostring(err_second))

-- The recorded relation is the property: every request after the first must extend the one
-- before it. This is exactly what a partial replay would break.
local starts = {}
for _, event in ipairs(telemetry.events(session_id, 0, 500).events) do
  if event.kind == "model_call" and event.phase == "start" then starts[#starts + 1] = event end
end
ok(#starts >= 4, "two turns with tool calls must produce several requests, got " .. #starts)
for index, event in ipairs(starts) do
  local relation = event.payload.prefix_audit and event.payload.prefix_audit.relation
  if index == 1 then
    ok(relation == "unmeasured", "the first request has no baseline, got " .. tostring(relation))
  else
    ok(relation == "append_only",
      "request " .. index .. " must extend the previous prefix, got " .. tostring(relation))
  end
end

-- The field follows the switch, and the tool calls survive either way: dropping the thinking
-- must never drop the route the model took.
local second_turn_first = bodies[first_turn_requests + 1]
local has_field = second_turn_first:find('"reasoning_content"', 1, true) ~= nil
ok(has_field == expected,
  "the second turn must " .. (expected and "carry" or "omit") .. " the prior reasoning")
if expected then
  ok(second_turn_first:find("FIRSTTHOUGHT", 1, true) ~= nil, "full replay must carry the prior thought")
end
ok(second_turn_first:find('"read"', 1, true) ~= nil, "the tool calls must still be in the request")

print("reasoning replay ok (" .. checks .. " checks)")
