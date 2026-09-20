-- The transcript is ordered by arrival, the provider demands adjacency.
--
-- Measured, not assumed. On 2026-09-20 the live node's chat session
-- 1b0b930d-e86d-46ff-9599-486c18acb231 answered every new turn with:
--
--   provider_http_400: {"error":{"message":"Upstream request failed:
--   [invalid_request_error] An assistant message with 'tool_calls' must be followed by
--   tool messages responding to each 'tool_call_id'"}}
--
-- Five exchanges in that stored transcript were out of order - a tool result recorded
-- after the next round's assistant message (a recovered or slow call), and a user message
-- written between a call and its result. Rounds 2+ of a running turn continue an in-memory
-- array and never see the misordering; only the round-1 rebuild does, so a thread works
-- for a whole turn and then fails instantly on the next one, forever.
--
-- The shapes below are those five, reduced. Each one must come out of build_context in a
-- form the provider accepts, with nothing silently dropped: what was wrong was the
-- position, and moving it is the whole repair.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local agentlib = dofile("lua/core/agent.lua")
memory.setup()

local function call(id, command)
  return { id = id, type = "function", ["function"] = { name = "bash", arguments = json.encode({ command = command }) } }
end

-- The provider's rule, as its own error states it: every id in an assistant message's
-- tool_calls is answered by the messages *immediately* following that message. Returns a
-- list of violations; empty means the request is valid on this axis.
local function adjacency_violations(messages)
  local bad = {}
  for index, message in ipairs(messages) do
    if message.role == "assistant" and type(message.tool_calls) == "table" and #message.tool_calls > 0 then
      local want = {}
      for _, c in ipairs(message.tool_calls) do want[tostring(c.id)] = true end
      local scan = index + 1
      while scan <= #messages and messages[scan].role == "tool" do
        want[tostring(messages[scan].tool_call_id)] = nil
        scan = scan + 1
      end
      for id in pairs(want) do
        bad[#bad + 1] = string.format("index %d: %s unanswered by the tool messages that follow", index, id)
      end
    end
  end
  return bad
end

local function count_role(messages, role)
  local n = 0
  for _, m in ipairs(messages) do if m.role == role then n = n + 1 end end
  return n
end

local function has_content(messages, needle)
  for _, m in ipairs(messages) do
    if type(m.content) == "string" and m.content:find(needle, 1, true) then return true end
  end
  return false
end

local function session()
  return memory.start_session("", "chat", { user_id = "master", node_id = "", title = "adjacency" })
end

-- Shape 1: a user message arrives while the tool runs, so it is written between the
-- call and its result.
local sid = session()
memory.append_turn(sid, { role = "user", content = "start" })
memory.append_turn(sid, { role = "assistant", content = "", tool_calls = { call("call_a", "sleep") } })
memory.append_turn(sid, { role = "user", content = "are you there?" })
memory.append_turn(sid, { role = "tool", content = "RESULT_A", tool_call_id = "call_a", tool_name = "bash" })
memory.append_turn(sid, { role = "assistant", content = "done" })
local bot = agentlib.new(sid, function() end, "master", "master", "")
local messages = bot:build_context()
local bad = adjacency_violations(messages)
assert(#bad == 0, "a user message between a call and its result must be repaired: " .. table.concat(bad, "; "))
assert(has_content(messages, "RESULT_A"), "the tool result must survive the repair")
assert(has_content(messages, "are you there?"), "and so must the message that arrived while it ran")
assert(bot.repaired, "the repair must be recorded, not silent")

-- Shape 2: the result arrives after a whole later exchange - the recovered-call case, and
-- the one that stays broken if the scan stops at the next assistant message.
local sid2 = session()
memory.append_turn(sid2, { role = "user", content = "start" })
memory.append_turn(sid2, { role = "assistant", content = "", tool_calls = { call("call_b", "slow") } })
memory.append_turn(sid2, { role = "assistant", content = "", tool_calls = { call("call_c", "one"), call("call_d", "two") } })
memory.append_turn(sid2, { role = "tool", content = "RESULT_C", tool_call_id = "call_c", tool_name = "bash" })
memory.append_turn(sid2, { role = "tool", content = "RESULT_D", tool_call_id = "call_d", tool_name = "bash" })
memory.append_turn(sid2, { role = "tool", content = "RESULT_B", tool_call_id = "call_b", tool_name = "bash" })
memory.append_turn(sid2, { role = "assistant", content = "done" })
local bot2 = agentlib.new(sid2, function() end, "master", "master", "")
local messages2 = bot2:build_context()
local bad2 = adjacency_violations(messages2)
assert(#bad2 == 0, "a result that arrives after a later exchange must be moved back: " .. table.concat(bad2, "; "))
for _, needle in ipairs({ "RESULT_B", "RESULT_C", "RESULT_D" }) do
  assert(has_content(messages2, needle), needle .. " must survive the repair")
end
-- The positive control: the two exchanges are still two, not merged into one.
local calls2 = 0
for _, m in ipairs(messages2) do if m.role == "assistant" and m.tool_calls then calls2 = calls2 + 1 end end
assert(calls2 == 2, "both tool exchanges must still be present, found " .. calls2)

-- Shape 3: the classic brick - a call whose result was never recorded at all. It cannot be
-- made adjacent, so it must be dropped, and said out loud. Keeping it is what bricks the
-- thread; dropping it silently is what this project forbids.
local sid3 = session()
memory.append_turn(sid3, { role = "user", content = "start" })
memory.append_turn(sid3, { role = "assistant", content = "", tool_calls = { call("call_e", "lost") } })
memory.append_turn(sid3, { role = "user", content = "never mind" })
local bot3 = agentlib.new(sid3, function() end, "master", "master", "")
local messages3 = bot3:build_context()
local bad3 = adjacency_violations(messages3)
assert(#bad3 == 0, "an unanswered call must not be sent: " .. table.concat(bad3, "; "))
assert(bot3.repaired, "dropping a call must be recorded, not silent")
local kept_calls = 0
for _, m in ipairs(messages3) do
  if m.role == "assistant" and type(m.tool_calls) == "table" then kept_calls = kept_calls + #m.tool_calls end
end
assert(kept_calls == 0, "an unanswered call has no valid form and must be dropped")
assert(count_role(messages3, "tool") == 0, "and its absent result must not appear either")

-- Shape 4: a healthy transcript is left alone. Without this, a builder that dropped every
-- call would satisfy every assertion above.
local sid4 = session()
memory.append_turn(sid4, { role = "user", content = "start" })
memory.append_turn(sid4, { role = "assistant", content = "", tool_calls = { call("call_f", "fine") } })
memory.append_turn(sid4, { role = "tool", content = "RESULT_F", tool_call_id = "call_f", tool_name = "bash" })
memory.append_turn(sid4, { role = "assistant", content = "done" })
local bot4 = agentlib.new(sid4, function() end, "master", "master", "")
local messages4 = bot4:build_context()
assert(#adjacency_violations(messages4) == 0, "a healthy transcript must stay valid")
assert(not bot4.repaired, "a healthy transcript must not be reported as repaired")
assert(has_content(messages4, "RESULT_F"), "and must keep its tool result")

print("tool adjacency ok")
