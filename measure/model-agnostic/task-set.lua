-- MODEL-AGNOSTIC TASK SET (mission tools-tell-the-truth, item 2's evidence).
--
-- WHAT THIS IS. A fixed set of eight tasks run by a SCRIPTED model: the same call bytes, in the same order,
-- on two trees (a base build and a branch build). No paid call, no model judgement, no network. For each
-- task it reports what the model would READ and what it would SEND:
--
--   rounds              model calls the harness made (a property of the SCRIPT, so equal by construction)
--   convo_sha           sha256 of the request messages WITHOUT the system prompt: the user turn and the
--                       tool round trip. Equal on a healthy task = "the healthy request bytes are identical"
--   system_bytes        the system prompt, which carries the tool catalogue - where a schema or description
--                       change shows up, and the only place a healthy task may differ by design
--   tool_result_bytes   bytes of tool/function messages in the last request: what the model reads back
--   tool_result_tokens  ceil(bytes/4), the product's own token estimate (lua/core/agent.lua estimate_tokens)
--   tokens_est          the same estimate over the whole last request (system prompt included)
--   wall_ms             the turn, measured on host.now()
--   refusals            occurrences of 'unknown_argument' in the request text (a refusal appears twice on the
--                       wire: in the tool result and in the next request's copy of it)
--
-- HOW TO RUN IT ON TWO TREES: measure/model-agnostic/run.sh <base-tree> <base-bin> <branch-tree> <branch-bin>
--
-- The scripted model is identical on both sides, so this measures the NODE's answers, not a model's
-- reaction: a real model would spend one extra round on a typo task (refusal, then the corrected call)
-- where the script simply makes both calls. That limit is the point of the set - it is model-agnostic.
local json = dofile('lua/vendor/json.lua')
local real_getenv = host.getenv
local overrides = { WASM_AGENT_PROVIDER='opencode-go', WASM_AGENT_LLM_API_KEY='fixture-key',
  WASM_AGENT_LLM_MODEL='fixture-model', WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0', WASM_AGENT_MAX_TOOL_ROUNDS='6', WASM_AGENT_ENVELOPE_MODE='full' }
host.getenv = function(k) if overrides[k] ~= nil then return overrides[k] end return real_getenv(k) end

local requests, answers = {}, {}
local function usage() return { prompt_tokens = 100, completion_tokens = 10, total_tokens = 110 } end
local function final(text)
  return { status = 200, content = text, stream_complete = true, finish_reason = 'stop', usage = usage(), tool_calls = {} }
end
local function calls(list)
  local out = {}
  for index, item in ipairs(list) do
    out[index] = { id = 'call_' .. index, type = 'function',
      ['function'] = { name = item[1], arguments = item[2] } }   -- the argument TEXT, byte for byte
  end
  return { status = 200, content = '', stream_complete = true, finish_reason = 'tool_calls', usage = usage(), tool_calls = out }
end
-- An EMPTY body is a probe (the provider seam asks once with nothing); it is not a model round and must not
-- consume a scripted answer.
host.http_stream = function(_, _, _, body)
  local encoded = type(body) == 'string' and body or json.encode(body)
  if encoded == '' then return json.encode({ status = 200, content = '', stream_complete = true,
    finish_reason = 'stop', usage = usage(), tool_calls = {} }) end
  requests[#requests + 1] = encoded
  local next_answer = table.remove(answers, 1)
  if not next_answer then error('fixture exhausted at call ' .. #requests) end
  return json.encode(next_answer)
end
host.http = function(_, _, _, body)
  local encoded = type(body) == 'string' and body or json.encode(body)
  if encoded == '' then return json.encode({ status = 200, body = json.encode({ choices = {}, usage = usage() }) }) end
  requests[#requests + 1] = encoded
  local next_answer = table.remove(answers, 1)
  if not next_answer then error('fixture exhausted at call ' .. #requests) end
  local payload = { id = 'fixture', model = 'fixture',
    choices = { { index = 0, finish_reason = next_answer.finish_reason or 'stop',
      message = { role = 'assistant', content = next_answer.content or '' } } }, usage = next_answer.usage }
  return json.encode({ status = 200, body = json.encode(payload) })
end

local memory = dofile('lua/core/memory.lua'); memory.setup()
local agent = dofile('lua/core/agent.lua')
-- A fixed path, so the argument text of a call is the same on both trees.
local fixture = '/tmp/wa-model-agnostic-fixture.txt'
host.write_file(fixture, 'alpha aa one\nalpha aa two\nalpha aa three\n')

local function measure(task, script, question)
  requests, answers = {}, script
  local sid = memory.start_session('', 'model-agnostic ' .. task, { user_id = 'master' })
  local bot = agent.new(sid, function() end, 'master', 'master', '')
  local wall0 = tonumber(host.now()) or 0
  pcall(function() return bot:run(question or 'do the task') end)
  local wall = (tonumber(host.now()) or 0) - wall0
  local first = json.decode(requests[1] or '{}')
  local last = json.decode(requests[#requests] or '{}')
  local refusals = 0
  for _, request in ipairs(requests) do
    if request:find('unknown_argument', 1, true) then refusals = refusals + 1 end
  end
  local tool_result_bytes, last_result = 0, ''
  for _, message in ipairs((last and last.messages) or {}) do
    if message.role == 'tool' or message.role == 'function' then
      local text = tostring(message.content or '')
      tool_result_bytes = tool_result_bytes + #text
      last_result = text
      local _, n = text:gsub('unknown_argument', '')
      refusals = refusals + n
    end
  end
  local msgs = (first and first.messages) or {}
  local convo = {}
  for i = 2, #msgs do convo[#convo + 1] = msgs[i] end
  return { task = task, rounds = #requests,
    convo_sha = host.sha256(json.encode(convo)), convo_bytes = #json.encode(convo),
    system_bytes = #tostring((msgs[1] or {}).content or ''),
    tool_result_bytes = tool_result_bytes, tool_result_tokens = math.ceil(tool_result_bytes / 4),
    tokens_est = math.ceil(#tostring(requests[#requests] or '') / 4),
    refusals = refusals, wall_ms = wall, last_result = last_result:sub(1, 400) }
end

local set = {
  { 'healthy_time', function() return {
      calls({ { 'time', '{}' } }), final('done') } end, 'what time is it' },
  { 'healthy_read', function() return {
      calls({ { 'read', json.encode({ path = fixture, limit = 5 }) } }), final('done') } end, 'read the fixture' },
  { 'healthy_bash', function() return {
      calls({ { 'bash', json.encode({ command = 'echo model-agnostic' }) } }), final('done') } end, 'run a command' },
  { 'typo_read', function() return {
      calls({ { 'read', json.encode({ path = fixture, ofset = 1 }) } }),
      calls({ { 'read', json.encode({ path = fixture, offset = 1 }) } }), final('done') } end, 'read the fixture (typo first)' },
  { 'typo_grep', function() return {
      calls({ { 'grep', json.encode({ pattern = 'aa', regex = true }) } }),
      calls({ { 'grep', json.encode({ pattern = 'aa' }) } }), final('done') } end, 'search (unsupported option first)' },
  { 'capabilities_one', function() return {
      calls({ { 'capabilities', json.encode({ names = { 'read' } }) } }), final('done') } end, 'what does read take' },
  { 'forward_remote', function() return {
      calls({ { 'remote', json.encode({ node = 'no-such-peer-here', capability = 'read', path = fixture }) } }), final('done') } end, 'read it on the peer' },
  { 'codemode_healthy', function() return {
      calls({ { 'run', json.encode({ code = 'const t = await tools.time({}); return typeof t.epoch;' }) } }), final('done') } end, 'run a script' },
}
local out = {}
for _, task in ipairs(set) do
  out[#out + 1] = measure(task[1], task[2](), task[3])
end
print(json.encode({ tasks = out }))
