-- Commentary is saved as its own assistant phase. A provider that streamed its
-- chunks must only close that live block after save, never send the text twice.
local json = dofile("lua/vendor/json.lua")
local real_getenv = host.getenv
local values = {
  WASM_AGENT_LLM_API_KEY = "fixture-only",
  WASM_AGENT_PROVIDER = "opencode-go",
  WASM_AGENT_LLM_MODEL = "deepseek-v4.1-flash",
  WASM_AGENT_PI_MODELS_STORE = "missing-test-store",
  WASM_AGENT_CONTEXT_BUDGET = "0",
}
host.getenv = function(key) return values[key] or real_getenv(key) end

local memory = dofile("lua/core/memory.lua")
memory.setup()
local telemetry = dofile("lua/core/telemetry.lua")
telemetry.setup()
local original_dofile = dofile
local provider = original_dofile("lua/core/provider.lua")
dofile = function(path)
  if path == "lua/core/provider.lua" then return provider end
  return original_dofile(path)
end
local agentlib = original_dofile("lua/core/agent.lua")
dofile = original_dofile
local real_stream = host.stream
local checks = 0
local function check(ok, label) assert(ok, label); checks = checks + 1 end
local usage = { prompt_tokens = 10, completion_tokens = 5, total_tokens = 15 }

local live_chunks = {}
host.stream = function(raw) live_chunks[#live_chunks + 1] = json.decode(raw) end
provider.complete_with = function()
  host.stream(json.encode({ type = "commentary_delta", text = "Let me check " }))
  host.stream(json.encode({ type = "commentary_delta", text = "the result." }))
  return { content = "Here is the answer.",
    commentary = "Let me check the result.", final_phase = "final_answer",
    commentary_streamed = "delta", finish_reason = "stop", tool_calls = {}, usage = usage }
end
local emitted = {}
local streamed_sid = memory.ensure_session("commentary-stream-contract", "local", "streamed")
local streamed = agentlib.new(streamed_sid, function(event) emitted[#emitted + 1] = event end,
  "master", "commentary-stream-contract", "local")
streamed.stream = true
local reply = streamed:run("answer with commentary")
host.stream = real_stream
check(reply == "Here is the answer.", "the final answer must remain the reply")
check(#live_chunks == 2 and live_chunks[1].text .. live_chunks[2].text == "Let me check the result.",
  "streamed commentary chunks must retain their exact text")
local close_count, full_commentary_count = 0, 0
for _, event in ipairs(emitted) do
  if event.type == "commentary_end" then close_count = close_count + 1 end
  if event.type == "commentary" then full_commentary_count = full_commentary_count + 1 end
end
check(close_count == 1 and full_commentary_count == 0,
  "a streamed commentary result closes by id without emitting its full text again")
local saved_commentary, saved_answer = 0, 0
for _, row in ipairs(memory.session_messages(streamed_sid, { all = true })) do
  if row.role == "assistant" and row.phase == "commentary" then
    saved_commentary = saved_commentary + 1
    check(row.content == "Let me check the result.", "the commentary phase must be saved intact")
  elseif row.role == "assistant" and row.content == "Here is the answer." then
    saved_answer = saved_answer + 1
    check(row.phase == "final_answer", "the answer phase must stay distinct")
  end
end
check(saved_commentary == 1 and saved_answer == 1, "both transcript phases must be saved exactly once")

local ordinary_events = {}
provider.complete_with = function()
  return { content = "Another answer.", commentary = "Unstreamed note.",
    finish_reason = "stop", tool_calls = {}, usage = usage }
end
local ordinary_sid = memory.ensure_session("commentary-unstreamed-contract", "local", "ordinary")
local ordinary = agentlib.new(ordinary_sid, function(event) ordinary_events[#ordinary_events + 1] = event end,
  "master", "commentary-unstreamed-contract", "local")
ordinary.stream = true
ordinary:run("answer with an unstreamed note")
local ordinary_count = 0
for _, event in ipairs(ordinary_events) do
  if event.type == "commentary" then
    ordinary_count = ordinary_count + 1
    check(event.text == "Unstreamed note.", "unstreamed commentary remains visible as a full event")
  end
end
check(ordinary_count == 1, "unstreamed commentary must be emitted once")

print("commentary stream contract ok (" .. checks .. " checks)")
