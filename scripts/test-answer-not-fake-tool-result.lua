-- A message that imitates a tool result is NOT an answer (18/11, session 100c54ab).
--
-- Three times in one session - 12:48, 13:40, 14:16 - the last assistant message of a turn was markup
-- the model wrote itself: "<result>\n<name>bash</name>\n<output>...". The harness recorded it as the
-- answer and the turn ended there, mid-task, with fabricated output as its reply and no call ever
-- dispatched. This row pins the rule (Victor, 18/11) on the three shapes from that session:
--
--   * the markup is stripped from the recorded content and the run keeps going (the model's next step);
--   * the event is recorded (a status line, a trace span, a telemetry event, a durable row whose phase
--     is fake_tool_result);
--   * a model that repeats it three times in a row fails the turn BY NAME - never as "answered".
--
-- Hermetic: the provider is replaced before the agent runs, so no paid call is made.
local native_getenv=host.getenv
local overrides={WASM_AGENT_LLM_API_KEY='test-only',WASM_AGENT_PROVIDER='opencode-go',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_PROVIDER_RETRIES='0',
  -- A retryable failure schedules one self-wake (lua/core/run_failure.lua) 60 s out; this row is about
  -- the answer boundary, not the wake, so the wake is off here instead of racing the row's own timeout.
  WASM_AGENT_RUN_FAILURE_WAKE_SECONDS='0'}
host.getenv=function(key) if overrides[key]~=nil then return overrides[key] end return native_getenv(key) end
host.http=function() error('unexpected HTTP in hermetic test') end
host.http_stream=host.http

local memory=dofile('lua/core/memory.lua'); memory.setup()
local original_dofile=dofile
local provider=dofile('lua/core/provider.lua')
dofile=function(path) if path=='lua/core/provider.lua' then return provider end return original_dofile(path) end
local agentlib=original_dofile('lua/core/agent.lua')
local run_failure=original_dofile('lua/core/run_failure.lua')
dofile=original_dofile
local fake_answer=original_dofile('lua/core/fake_answer.lua')

local checks=0
local function check(ok,message) assert(ok,message); checks=checks+1 end
local function session(title) return memory.start_session('',title,{user_id='master',node_id='',title=title}) end
local usage={prompt_tokens=1000,completion_tokens=20,total_tokens=1020}

-- ------------------------------------------------------------------ the three shapes from that session
-- 1. the measured one: the wrapper, a name element and the output element.
local SHAPE_RESULT = "<result>\n<name>bash</name>\n<output>\n" ..
  "$ ls -la\nREADME.md\n</output>\n</result>"
-- 2. the same shape with the wrapper left off: a name answered by an output.
local SHAPE_NAME_OUTPUT = "<name>bash</name>\n<output>{\"ok\":true,\"code\":0,\"stdout\":\"done\"}</output>"
-- 3. the call-side sibling: a tool call written as markup instead of requested.
local SHAPE_TOOL_CALL = "<tool_call>\n{\"name\":\"bash\",\"arguments\":{\"command\":\"ls\"}}\n</tool_call>"
local SHAPES = { { name = "result", text = SHAPE_RESULT }, { name = "name+output", text = SHAPE_NAME_OUTPUT },
  { name = "tool_call", text = SHAPE_TOOL_CALL } }

for _, shape in ipairs(SHAPES) do
  local scan = fake_answer.scan(shape.text)
  check(scan ~= nil, "the " .. shape.name .. " shape must be recognised as fabricated markup")
  check(scan and #scan.tags >= 1, "the scan names the markup it found: " .. shape.name)
  check(scan and scan.stripped == "",
    "nothing of the fabricated block survives into the answer text (" .. shape.name .. "): ["
      .. tostring(scan and scan.stripped) .. "]")
  check(scan and scan.excerpt ~= "", "the excerpt carries what the model wrote, for the notice")
end
-- What must NOT be caught: documenting the markup, quoting it, or naming a tag in prose.
check(fake_answer.scan("The build passed and the tests are green.") == nil, "an ordinary answer is not markup")
check(fake_answer.scan("~~~\n<result>\n<name>bash</name>\n<output>x</output>\n</result>\n~~~") == nil,
  "markup inside a fenced block is documentation, not an imitation")
check(fake_answer.scan("The <output> element carries stdout.") == nil, "a tag mentioned in prose is prose")

-- ------------------------------------------------------------------ a fake step does not end the turn
overrides.WASM_AGENT_PROVIDER_RETRIES='0'
local sid=session('answer-not-fake')
local events={}
local bot=agentlib.new(sid,function(event) events[#events+1]=event end,'master','master','')
local replies={ SHAPE_RESULT, "The listing is in; here is what I found." }
local calls_seen=0
provider.complete_with=function(_,messages)
  calls_seen=calls_seen+1
  local next_reply=replies[calls_seen]
  if not next_reply then error('unexpected provider call '..calls_seen) end
  return {content=next_reply,tool_calls={},finish_reason='stop',usage=usage}
end
local reply=bot:run('list the directory')
check(reply=="The listing is in; here is what I found.",
  "the turn answers with the model's NEXT step, never with the fabricated block: "..tostring(reply))
check(calls_seen==2,"one fabricated step costs one more model call, not the turn: "..tostring(calls_seen))
local rows=memory.session_messages(sid) or {}
local fabricated_rows,noticed=0,0
for _,row in ipairs(rows) do
  if row.phase=="fake_tool_result" and row.role=="assistant" then
    fabricated_rows=fabricated_rows+1
    check(row.role=="assistant","the fabricated step is recorded as an assistant row")
    check((row.content or "")=="","the fabricated block is stripped from the recorded content: ["
      ..tostring(row.content).."]")
  end
  if row.role=="user" and row.phase=="fake_tool_result" and tostring(row.content):find("[Harness notice]",1,true)
      and tostring(row.content):find("was NOT an answer",1,true) then
    noticed=noticed+1
  end
end
check(fabricated_rows==1,"the fabricated step is one recorded row with its own phase: "..fabricated_rows)
check(noticed==1,"the model was handed the notice that says the markup was not an answer")
local said=false
for _,event in ipairs(events) do
  if event.type=="status" and tostring(event.text):find("wrote a tool result instead of calling one",1,true) then
    said=true
  end
end
check(said,"the run says it happened, in its own stream")
local last=rows[#rows]
check(last and last.role=="assistant" and last.ok~=false,"the run ended with a real answer, not a failure row")
check(tostring(last and last.content):find("<result>",1,true)==nil,"no fabricated markup reaches the answer row")

-- ------------------------------------------------------------------ three in a row fail BY NAME
local streak=session('answer-not-fake-streak')
local streak_bot=agentlib.new(streak,function() end,'master','master','')
local streak_calls=0
provider.complete_with=function()
  streak_calls=streak_calls+1
  -- ONE shape, repeated (18/11 round 2, finding 2): a real tool call now ends the streak, and one of
  -- the three shapes (the <tool_call> one) is turned into a real codemode call by the raw-code channel,
  -- so cycling through them no longer measures "a model that only imitates". The reset itself - run
  -- start and after every real tool call - is pinned in scripts/test-fake-answer-repeat-reset.lua.
  return {content=SHAPES[1].text,tool_calls={},finish_reason='stop',usage=usage}
end
local ok,problem=pcall(streak_bot.run,streak_bot,'keep going')
check(not ok,"a model that only imitates tool results cannot end the turn as answered")
check(tostring(problem):find("fake_tool_result",1,true)~=nil,
  "the run fails by name: "..tostring(problem))
-- The bound is the repeat count; a retryable failure may also schedule one wake that re-drives the
-- thread (run_failure), which is a call of its own - so the count is a floor here, not an equality.
check(streak_calls>=fake_answer.MAX_REPEATS,
  "the model got exactly the named repeat count before the turn failed: "..tostring(streak_calls))
local streak_rows=memory.session_messages(streak) or {}
local streak_last=streak_rows[#streak_rows]
check(streak_last and streak_last.role=="assistant","the failed run leaves its own row")
check(tostring(streak_last and streak_last.content):find("fake_tool_result",1,true)~=nil,
  "and that row names the failure: "..tostring(streak_last and streak_last.content))
check(tostring(streak_last and streak_last.content):find("<result>",1,true)==nil,
  "the fabricated block is never the failure row's content either")
local classified=run_failure.classify(tostring(streak_last and streak_last.content))
check(classified.code=="fake_tool_result","the row classifies as fake_tool_result, not provider/answer: "
  ..tostring(classified.code))

print(string.format("ok answer-not-fake-tool-result: %d checks",checks))

-- The failure layer knows the name too, so a turn that ends this way is classified with its own code
-- instead of falling through to provider_error (checked last: the turn-level checks above are the ones
-- that matter when the rule is missing).
check(run_failure.classify("fake_tool_result: the model imitated a tool result").code == "fake_tool_result",
  "the failure layer knows the name")
