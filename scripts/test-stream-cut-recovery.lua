-- A run is not lost to a provider cut or a killed process (29/10).
--
-- Measured: session 2f458650, 16:10:53Z - deepseek-v4.1-flash via opencode-go cut its stream 72 bytes
-- into a visible reply; agent.lua raised `provider_incomplete_stream` and the run died with no retry.
-- Two levels, both through host.http_stream (the real request/parse path):
--   * the in-run re-drive: a cut after visible text or a partial tool call continues the run, never
--     executes the partial call, is bounded, and can be turned off;
--   * the CLI's automatic recovery policy (lua/core/run_recovery.lua): which tails are re-driven.
-- Run from the repo root:  WA_SCRIPT=scripts/test-stream-cut-recovery.lua wa --db /tmp/x.db
local env = {}
local real_getenv = host.getenv
host.getenv = function(key)
  if key == "WASM_AGENT_LLM_API_KEY" then return "test-only" end
  if env[key] ~= nil then return env[key] end
  return real_getenv(key)
end
host.sleep = function() end -- backoff is asserted by value, not waited out

local json = dofile("lua/vendor/json.lua")
local provider = dofile("lua/core/provider.lua")
local agentlib = dofile("lua/core/agent.lua")
local memory = dofile("lua/core/memory.lua")
local recovery = dofile("lua/core/run_recovery.lua")
memory.setup()

local checks = 0
local function check(cond, what) checks = checks + 1; if not cond then error(what, 2) end end

-- ------------------------------------------------------------------ helpers
check(provider.stream_cut_retries() == 3, "stream cut re-drive is default-on (3)")
env.WASM_AGENT_PROVIDER_STREAM_CUT_RETRIES = "0"
check(provider.stream_cut_retries() == 0, "0 turns it off")
env.WASM_AGENT_PROVIDER_STREAM_CUT_RETRIES = nil
check(provider.stream_cut_backoff_ms(1) == 1000 and provider.stream_cut_backoff_ms(3) == 4000
  and provider.stream_cut_backoff_ms(9) == 8000, "backoff 1,2,4 then capped at 8 s")

-- ------------------------------------------------------------------ the loop
local bodies, script = {}, {}
host.http_stream = function(...)
  local args = { ... }
  local text = {}
  for _, value in ipairs(args) do if type(value) == "string" then text[#text + 1] = value end end
  bodies[#bodies + 1] = table.concat(text, "\n")
  local answer = table.remove(script, 1) or { status = 200, content = "fallback", finish_reason = "stop", tool_calls = {} }
  return json.encode(answer)
end
local function new_turn(title)
  local session_id = memory.ensure_session("cut-test", "local", title)
  local agent = agentlib.new(session_id, function() end, "master", "cut-test", "local")
  agent.stream = true
  return agent, session_id
end
local function rows(session_id) return memory.session_messages(session_id, { all = true }) or {} end

-- 1. The measured case: visible text, then the cut. The run continues and answers.
bodies, script = {}, {
  { status = 200, content = "Limpo. Última checagem", stream_complete = false, tool_calls = {} },
  { status = 200, content = "produção de pé", finish_reason = "stop", stream_complete = true, tool_calls = {} },
}
local agent, sid = new_turn("cut after text")
local ok, reply = pcall(agent.run, agent, "make it clean")
check(ok, "a cut stream must not end the run: " .. tostring(reply))
check(tostring(reply):find("produção de pé", 1, true), "the continued answer is the reply")
check(#bodies == 2, "exactly one re-drive, got " .. #bodies .. " request(s)")
check(bodies[2]:find("Limpo. Última checagem", 1, true), "the partial text is handed back to the model")
check(bodies[2]:find("cut off by the provider", 1, true), "the model is told the reply was cut")
local transcript = rows(sid)
local partial, final = transcript[#transcript - 1], transcript[#transcript]
check(partial.role == "assistant" and partial.ok == 0 and partial.content:find("Limpo", 1, true),
  "the partial stays in the transcript as failed evidence")
check(final.role == "assistant" and final.ok == 1, "the answer is recorded ok")
check((memory.session_state(sid) or {}).state == "answered", "the thread is settled")

-- 2. A cut while a tool call was forming: the call is never executed, the notice says so.
local marker = "/tmp/wa-stream-cut-marker-" .. tostring(math.random(1e9))
bodies, script = {
}, {
  { status = 200, content = "", stream_complete = false, tool_calls = { { id = "c1", type = "function",
    ["function"] = { name = "write", arguments = json.encode({ path = marker, content = "x" }) } } } },
  { status = 200, content = "done without it", finish_reason = "stop", stream_complete = true, tool_calls = {} },
}
agent = new_turn("cut mid tool call")
ok, reply = pcall(agent.run, agent, "write it")
check(ok, "a cut tool call re-drives: " .. tostring(reply))
check(host.read_file(marker) == nil, "the partial tool call was NOT executed")
check(bodies[2]:find("NOT executed", 1, true), "the notice says the partial call did not run")

-- 3. Bounded: a provider that always cuts fails after 1 + N requests, with the old error.
env.WASM_AGENT_PROVIDER_STREAM_CUT_RETRIES = "2"
bodies, script = {}, {}
for _ = 1, 10 do script[#script + 1] = { status = 200, content = "partial", stream_complete = false, tool_calls = {} } end
agent = new_turn("always cut")
ok, reply = pcall(agent.run, agent, "go")
check(not ok and tostring(reply):find("provider_incomplete_stream", 1, true), "exhausted budget fails as before")
check(#bodies == 3, "1 request + 2 re-drives, got " .. #bodies)

-- 4. Off switch: fail-fast exactly as before 29/10.
env.WASM_AGENT_PROVIDER_STREAM_CUT_RETRIES = "0"
bodies, script = {}, { { status = 200, content = "partial", stream_complete = false, tool_calls = {} } }
agent = new_turn("cut, retries off")
ok = pcall(agent.run, agent, "go")
check(not ok and #bodies == 1, "with 0 the first cut ends the run")
env.WASM_AGENT_PROVIDER_STREAM_CUT_RETRIES = nil

-- ------------------------------------------------------------------ recovery policy
local now = 1000000
local function st(state, detail, at) return { state = state, detail = detail or "", at = at or now - 10 } end
check(recovery.decide(st("unfinished", "an unanswered question"), nil, now), "a killed run is re-driven")
check(recovery.decide(st("failed", "provider_incomplete_stream: partial response preserved"), nil, now),
  "a run whose cuts outlasted the budget is re-driven on restart")
check(not recovery.decide(st("failed", "finish_reason=length"), nil, now), "a landed failure is not")
check(not recovery.decide(st("answered"), nil, now), "a settled thread is not")
check(not recovery.decide(st("unfinished", "x", now - 7 * 3600), nil, now), "an old abandoned tail is not")
check(not recovery.decide(st("unfinished", "x"), { content = recovery.MARK .. " ..." }, now),
  "one automatic attempt per interruption")
check(not recovery.decide(st("unfinished", "x"), nil, now, { enabled = false }), "WASM_AGENT_AUTO_RECOVER=0")
check(recovery.prompt("r"):find("never repeat an outward action", 1, true), "the prompt forbids blind replay")

-- The CLI entry against a real transcript: a process killed right after the question.
local killed = memory.ensure_session("cut-test", "local", "killed mid run")
local killed_agent = agentlib.new(killed, function() end, "master", "cut-test", "local")
memory.append_turn(killed, { role = "user", content = "deploy the fix" })
local due = recovery.due(killed)
check(due and due.prompt:sub(1, #recovery.MARK) == recovery.MARK, "due() re-drives a killed run")
bodies, script = {}, { { status = 200, content = "re-checked; deployed already", finish_reason = "stop", tool_calls = {} } }
killed_agent.stream = true
ok, reply = pcall(killed_agent.run, killed_agent, due.prompt)
check(ok, "the recovery run answers: " .. tostring(reply))
check(bodies[1]:find("Recovery notice", 1, true), "the recovery run carries note_interruption's notice")
check(recovery.due(killed) == nil, "once answered, nothing is due")

print("stream-cut-recovery ok: " .. checks .. " assertions")
