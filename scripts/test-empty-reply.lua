-- An empty assistant message is not an answer.
--
-- A reasoning model that spends its whole output budget thinking returns content
-- "", a reasoning field of some length, and finish_reason=length. Kimi, DeepSeek-R1
-- and friends all do it. The loop used to record that as a finished turn, so the
-- model looked like it had nothing to say rather than like it had failed - and with
-- no max_tokens sent at all, nothing bounded how far the reasoning could run.
--
-- The dangerous half is the opposite case: a tool call with no prose is completely
-- normal and must keep working. That is the positive control at the end, and it is
-- the assertion that protects the tool loop from this fix.
--
-- Two levels, because they fail differently:
--   * the pure helpers in provider.lua (no host, no model, no network)
--   * the loop itself, driven through host.http_stream - the same entry point the
--     real provider uses, so the wiring is what is under test and not a copy of it
--
-- Run from the repo root:  WA_SCRIPT=scripts/test-empty-reply.lua wa --db /tmp/x.db
-- This suite stubs the transport and must not depend on an operator API key.
local real_getenv=host.getenv
host.getenv=function(key)
  if key=='WASM_AGENT_LLM_API_KEY' then return 'test-only' end
  return real_getenv(key)
end
local provider = dofile("lua/core/provider.lua")
local json = dofile("lua/vendor/json.lua")

local checks = 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    error(string.format("%s: got %q, want %q", what, tostring(got), tostring(want)))
  end
end
local function has(haystack, needle, what)
  checks = checks + 1
  if not string.find(haystack, needle, 1, true) then
    error(string.format("%s: %q does not contain %q", what, haystack, needle))
  end
end

-- ---------------------------------------------------------------- the helpers

-- The reasoning field has three spellings in the wild, and pi reads all three.
eq(provider.reasoning_of({ reasoning_content = "a" }), "a", "reasoning_content")
eq(provider.reasoning_of({ reasoning = "b" }), "b", "reasoning")
eq(provider.reasoning_of({ reasoning_text = "c" }), "c", "reasoning_text")
eq(provider.reasoning_of({ reasoning_content = "", reasoning = "d" }), "d",
  "an empty field does not shadow a populated one")
eq(provider.reasoning_of({ content = "x" }), "", "no reasoning field at all")
eq(provider.reasoning_of(nil), "", "a missing message is not an error")

-- What a reader would see: reasoning is not an answer.
eq(provider.visible_text("hello"), "hello", "plain text is visible")
eq(provider.visible_text("   \n\t "), "", "whitespace alone is not an answer")
eq(provider.visible_text("<think>a\nb</think>"), "",
  "a think block inside content is not an answer")
eq(provider.visible_text("<think>a</think>the answer"), "the answer",
  "the text after a think block is the answer")
eq(provider.visible_text("<think>never closed"), "",
  "an unclosed think block swallows the rest")

-- The reason has to be actionable: name the stop reason and the knob.
local spent = provider.empty_reply_reason({ reasoning = string.rep("x", 40), finish_reason = "length" })
has(spent, "finish_reason=length", "the reason names the stop")
has(spent, "40 chars", "the reason quantifies the reasoning")
has(spent, "WASM_AGENT_LLM_MAX_OUTPUT", "the reason names the knob that sets the cap")
has(provider.empty_reply_reason({}), "no finish_reason", "an unknown stop is said out loud")

-- -------------------------------------------------------------------- the loop
--
-- dofile() has no module cache, so every file that loads provider.lua gets its own
-- copy of it: patching provider.complete_with from here would patch a table the
-- agent never looks at. host.* is the one table everybody shares, so the stub goes
-- there - and that keeps the real request-building and response-parsing in the path.
local agentlib = dofile("lua/core/agent.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()

local real_stream = host.http_stream
local answer = nil
host.http_stream = function() return json.encode(answer) end

local function turn(title)
  local session_id = memory.ensure_session("empty-reply-test", "local", title)
  local agent = agentlib.new(session_id, function() end, "master", "empty-reply-test", "local")
  agent.stream = true   -- the path chat and the UI take
  return agent, session_id
end

-- 1. Reasoning ate the budget: the turn must fail and say so.
answer = { status = 200, content = "", reasoning = string.rep("t", 500),
  finish_reason = "length", tool_calls = {} }
local agent, session_id = turn("spent its budget")
local ok, err = pcall(agent.run, agent, "write an essay")
checks = checks + 1
if ok then error("an empty answer must fail the turn, not finish it") end
has(tostring(err), "finish_reason=length", "the failure names the stop reason")
has(tostring(err), "500 chars", "the failure quantifies the reasoning")
has(tostring(err), "WASM_AGENT_LLM_MAX_OUTPUT", "the failure names the knob")

-- And the durable record must show a failed turn carrying the reason, which is
-- what anyone reading the ledger later will actually see.
-- session_state returns a table, and comparing a table to a string is always false -
-- which is how the first version of this assertion passed while checking nothing.
local state = (memory.session_state(session_id) or {}).state
checks = checks + 1
if state ~= "failed" then
  error("a turn that produced nothing must be recorded as failed, got state=" .. tostring(state))
end
local messages = memory.session_messages(session_id)
local last = messages and messages[#messages] or nil
checks = checks + 1
if not last or last.ok ~= 0 then
  error("the failed turn must be recorded with ok=false, got: " .. json.encode(last or {}))
end
local trace = json.encode(last.trace or {})
has(trace, "reasoning", "the trace keeps what happened to the budget")
has(trace, "finish_reason", "the trace keeps the stop reason")

-- 2. POSITIVE CONTROL: a decision with a tool call and no prose is normal. The stub
--    answers the first call with a read, then with real text, and the turn succeeds.
local step = 0
host.http_stream = function()
  step = step + 1
  if step == 1 then
    return json.encode({ status = 200, content = "", finish_reason = "tool_calls",
      tool_calls = { { id = "c1", type = "function",
        ["function"] = { name = "read", arguments = '{"path":"AGENTS.md","limit":5}' } } } })
  end
  return json.encode({ status = 200, content = "read it, here is the answer",
    finish_reason = "stop", tool_calls = {} })
end
local agent2 = turn("tool call with no prose")
local ok2, reply2 = pcall(agent2.run, agent2, "what is in AGENTS.md?")
checks = checks + 1
if not ok2 then error("a tool call with no prose must not fail the turn: " .. tostring(reply2)) end
has(tostring(reply2), "here is the answer", "the answer after the tool round comes back")
checks = checks + 1
if step < 2 then error("the tool round must have happened, the provider ran " .. step .. " time(s)") end

-- ------------------------------------------------------- the empty stop retry
--
-- The case this suite exists for now: `finish_reason=stop`, no text, no tool call. Measured in
-- session 8497eecc-6084-4ffe-a65f-d04c550522bb - the run died on the first such reply with
-- `empty_reply` and never asked the provider again, because the retry rode the OPT-IN transient
-- budget (`WASM_AGENT_PROVIDER_RETRIES`), which defaults to 0. An empty stop returned nothing, so
-- asking again cannot duplicate a tool call or swallow visible text: it gets its own bounded,
-- default-on budget.
eq(provider.empty_reply_retries(), 2, "two empty-stop retries by default")
eq(provider.empty_reply_delay_ms(), 500, "a short first backoff")
checks = checks + 1
local backoff = provider.empty_reply_backoff_ms(1)
if backoff < 375 or backoff > 625 then
  error("the first empty-stop backoff must stay near 500ms with jitter, got " .. tostring(backoff))
end
checks = checks + 1
if provider.empty_reply_backoff_ms(2) < provider.empty_reply_backoff_ms(1) * 0.9 then
  error("the empty-stop backoff must grow with the attempt")
end
-- The predicate is the shared decision, so assert it directly rather than only through the loop.
eq(provider.is_empty_reply({ finish_reason = "stop", content = "", tool_calls = {} }), true,
  "an empty stop is an empty reply")
eq(provider.is_empty_reply({ finish_reason = "stop", content = "  \n " }), true,
  "whitespace is not content")
eq(provider.is_empty_reply({ finish_reason = "tool_calls", content = "",
  tool_calls = { { id = "c" } } }), false, "a tool call is not empty")
eq(provider.is_empty_reply({ finish_reason = "length", content = "" }), false,
  "an output-limit stop keeps its own handling")
eq(provider.is_empty_reply({ finish_reason = "stop", content = "", stream_complete = false }), false,
  "an interrupted stream keeps its own handling")
eq(provider.is_empty_reply({ finish_reason = "stop", content = "", reasoning = "thinking" }), false,
  "reasoning-only replies are diagnosed differently")
eq(provider.is_empty_reply({ finish_reason = "stop", commentary = { { content = "said something" } } }), false,
  "commentary items are not stringified into content")

-- 1. The empty stop is retried and the turn recovers on a later attempt.
local real_sleep = host.sleep
local slept = 0
host.sleep = function(ms) slept = slept + math.max(0, tonumber(ms) or 0) end
local stops = 0
host.http_stream = function()
  stops = stops + 1
  if stops <= 2 then
    return json.encode({ status = 200, content = "", finish_reason = "stop", tool_calls = {},
      usage = { prompt_tokens = 10, completion_tokens = 1, total_tokens = 11 } })
  end
  return json.encode({ status = 200, content = "recovered after the empty stop",
    finish_reason = "stop", tool_calls = {},
    usage = { prompt_tokens = 10, completion_tokens = 5, total_tokens = 15 } })
end
local agent3 = turn("empty stop retried")
local ok3, reply3 = pcall(agent3.run, agent3, "say something")
checks = checks + 1
if not ok3 then error("an empty stop must be retried, not failed outright: " .. tostring(reply3)) end
has(tostring(reply3), "recovered after the empty stop", "the retry's answer is the answer")
eq(stops, 3, "two empty stops cost two retries and the third attempt answers")
checks = checks + 1
if slept <= 0 then error("the empty-stop retry must back off instead of hammering the provider") end

-- 2. The budget is bounded: three empty stops in a row fail the turn with an explicit reason.
local exhausted = 0
host.http_stream = function()
  exhausted = exhausted + 1
  return json.encode({ status = 200, content = "", finish_reason = "stop", tool_calls = {},
    usage = { prompt_tokens = 10, completion_tokens = 1, total_tokens = 11 } })
end
local session4
local agent4, sid4 = turn("empty stop exhausts")
session4 = sid4
local ok4, err4 = pcall(agent4.run, agent4, "say something")
checks = checks + 1
if ok4 then error("an unbroken run of empty stops must fail the turn, not finish it empty") end
eq(exhausted, 3, "two retries then the failure - three attempts, never more")
has(tostring(err4), "empty message", "the failure keeps the actionable sentence")
has(tostring(err4), "finish_reason=stop", "the failure names the stop reason")
has(tostring(err4), "2 retries", "the failure says how many times the turn was re-asked")
checks = checks + 1
if (memory.session_state(session4) or {}).state ~= "failed" then
  error("an exhausted empty stop must be recorded as a failed turn")
end
-- No silent data loss: the provider's own usage for every attempt is still on the record.
local messages4 = memory.session_messages(session4) or {}
local failed = messages4[#messages4]
checks = checks + 1
if not failed or failed.ok ~= 0 then
  error("the exhausted turn must be recorded with ok=false, got: " .. json.encode(failed or {}))
end
has(json.encode(failed.trace or {}), "finish_reason", "the trace keeps the stop reason")

-- 3. The off-switch still works, and it is the documented one.
host.getenv = function(key)
  if key == 'WASM_AGENT_LLM_API_KEY' then return 'test-only' end
  if key == 'WASM_AGENT_PROVIDER_RETRIES' then return '0' end
  return real_getenv(key)
end
local off_retries = provider.empty_reply_retries()
checks = checks + 1
if off_retries ~= 0 then error("WASM_AGENT_PROVIDER_RETRIES=0 must disable the empty-stop retry, got " .. tostring(off_retries)) end
host.getenv = function(key)
  if key == 'WASM_AGENT_LLM_API_KEY' then return 'test-only' end
  return real_getenv(key)
end
eq(provider.empty_reply_retries(), 2, "the off-switch is not sticky")

host.sleep = real_sleep
host.http_stream = real_stream
host.getenv=real_getenv

print(string.format("empty reply ok (%d checks)", checks))
