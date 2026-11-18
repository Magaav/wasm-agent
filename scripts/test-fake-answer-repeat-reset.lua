-- The imitation streak starts at zero on every run and after every real tool call (18/11 round 2,
-- finding 2).
--
-- Round 1 counted fabricated steps in a field nothing ever reset, so the bound was reached on evidence
-- from another turn: a model that imitated twice, then called a tool and got its answer, then imitated
-- once more failed the turn by name - for a streak the harness had already answered for. The counter is
-- now per run (a run is one turn) and a real tool call ends the streak, because a call is exactly what
-- the notice asked for.
--
-- Hermetic: the provider is replaced before the agent runs, so no paid call is made.
local native_getenv = host.getenv
local overrides = { WASM_AGENT_LLM_API_KEY = 'test-only', WASM_AGENT_PROVIDER = 'opencode-go',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE = 'missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET = '0', WASM_AGENT_PROVIDER_RETRIES = '0', WASM_AGENT_RUN_FAILURE_WAKE_SECONDS = '0' }
host.getenv = function(key) if overrides[key] ~= nil then return overrides[key] end return native_getenv(key) end
host.http = function() error('unexpected HTTP in hermetic test') end
host.http_stream = host.http

local memory = dofile('lua/core/memory.lua'); memory.setup()
local original_dofile = dofile
local provider = dofile('lua/core/provider.lua')
dofile = function(path) if path == 'lua/core/provider.lua' then return provider end return original_dofile(path) end
local agentlib = original_dofile('lua/core/agent.lua')
local telemetry = original_dofile('lua/core/telemetry.lua')
dofile = original_dofile
local fake_answer = original_dofile('lua/core/fake_answer.lua')

local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function session(title) return memory.start_session('', title, { user_id = 'master', node_id = '', title = title }) end
local usage = { prompt_tokens = 1000, completion_tokens = 20, total_tokens = 1020 }
local SHAPE = "<result>\n<name>bash</name>\n<output>\n$ ls\nREADME.md\n</output>\n</result>"
local TOOL_CALL = { id = 'call-1', ["function"] = { name = 'bash', arguments = '{"command":"echo hi"}' } }

local function script(replies)
  local seen = 0
  return function(_, messages)
    seen = seen + 1
    local reply = replies[seen]
    if not reply then error('unexpected provider call ' .. seen) end
    return reply
  end
end
local function fake() return { content = SHAPE, tool_calls = {}, finish_reason = 'stop', usage = usage } end
local function tools_call() return { content = '', tool_calls = { TOOL_CALL }, finish_reason = 'tool_calls', usage = usage } end
local function answer(text) return { content = text, tool_calls = {}, finish_reason = 'stop', usage = usage } end

local function streak_rows(sid)
  local rows = {}
  for _, event in ipairs((telemetry.events(sid, 0, 500) or {}).events or {}) do
    if event.kind == 'fake_tool_result' and event.phase == 'step' then
      rows[#rows + 1] = { repeats = tonumber(event.payload and event.payload.repeats), run = event.run_id }
    end
  end
  return rows
end

-- ------------------------------------------------- a real tool call ends the streak it interrupted
local sid = session('fake-repeat-tool')
local bot = agentlib.new(sid, function() end, 'master', 'master', '')
provider.complete_with = script({ fake(), tools_call(), fake(), tools_call(), fake(), answer('all done.') })
local ok, reply = pcall(bot.run, bot, 'do the thing')
check(ok, 'three imitations with a real tool call between them are not three in a row: ' .. tostring(reply))
check(reply == 'all done.', 'the turn answers, in the model own next step: ' .. tostring(reply))
local streak = streak_rows(sid)
check(#streak == 3, 'three fabricated steps are recorded, one row each: ' .. tostring(#streak))
for index, row in ipairs(streak) do
  check(row.repeats == 1, string.format(
    'each imitation interrupts a streak that a real tool call had already ended (step %d counted %s)',
    index, tostring(row.repeats)))
end

-- ------------------------------------------------- the streak does not survive its own run
local sid2 = session('fake-repeat-runs')
local bot2 = agentlib.new(sid2, function() end, 'master', 'master', '')
provider.complete_with = script({ fake(), fake(), answer('first turn done.') })
local ok2, reply2 = pcall(bot2.run, bot2, 'first turn')
check(ok2 and reply2 == 'first turn done.', 'two imitations inside one turn are below the bound: ' .. tostring(reply2))
-- The same agent object runs the next turn of the same session, as the CLI and the server do.
provider.complete_with = script({ fake(), answer('second turn done.') })
local ok3, reply3 = pcall(bot2.run, bot2, 'second turn')
check(ok3, 'the next turn starts its own streak: a third imitation in a row across the two turns is '
  .. 'not a failure: ' .. tostring(reply3))
check(reply3 == 'second turn done.', 'and the second turn answers: ' .. tostring(reply3))
local second_run = memory.session_messages(sid2) or {}
local last = second_run[#second_run]
check(last and last.role == 'assistant' and last.ok ~= false, 'the run ends with a real answer row')
local run2 = streak_rows(sid2)
local last_run_id = last and last.trace and nil
-- The second turn's own fabricated step says repeats = 1: the counter was reset at the run start.
local per_run = {}
for _, row in ipairs(run2) do per_run[row.run] = per_run[row.run] or {}; table.insert(per_run[row.run], row.repeats) end
local runs = 0
for _, repeats in pairs(per_run) do
  runs = runs + 1
  check(repeats[#repeats] == 1 or #repeats == 2, 'a run never carries a streak from the run before it: '
    .. table.concat(repeats, ','))
end
check(runs == 2, 'both turns recorded their own fabricated steps: ' .. tostring(runs))

print(string.format("ok fake-answer-repeat-reset: %d checks", checks))
