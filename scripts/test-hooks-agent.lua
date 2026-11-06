-- Hook points inside the agent loop (docs/HOOKS.md): SessionStart and UserPromptSubmit context,
-- a refused prompt, Stop asking the run to continue, Stop stopping it, and a tool call refused at the
-- boundary. Model-free: the provider is the same fake HTTP fixture the other loop tests use, so no
-- inference, no network and no paid call is involved.
local json = dofile('lua/vendor/json.lua')
local real_getenv = host.getenv
local overrides = { WASM_AGENT_PROVIDER = 'opencode-go', WASM_AGENT_LLM_API_KEY = 'fixture-only',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE = 'missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET = '0', WASM_AGENT_MAX_TOOL_ROUNDS = '6' }
host.getenv = function(key) if overrides[key] ~= nil then return overrides[key] end return real_getenv(key) end
host.http = function() error('unexpected network in the hook fixture') end

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print('FAIL ' .. label); failed = failed + 1 end
end

local paths = dofile('lua/core/paths.lua')
local config, home = paths.config(), paths.home()
local function sh(command)
  local result = json.decode(host.exec(command, '', 30))
  assert(result and result.code == 0, command .. ' -> ' .. json.encode(result))
end
local function write(path, text) assert(host.write_file(path, text), 'write ' .. path) end
local function answer(name, text)
  local path = config .. '/' .. name .. '.sh'
  write(path, '#!/usr/bin/env bash\nprintf ' .. "'%s' " .. string.format('%q', text) .. '\n')
  sh("chmod +x '" .. path .. "'")
  return "bash '" .. path .. "'"
end
-- A hook that blocks only the first time it runs: the marker file is what makes the second answer
-- different, so "the run continued and then stopped" is observable.
local function blocking_once(name, reason)
  local path = config .. '/' .. name .. '.sh'
  local marker = home .. '/' .. name .. '.marker'
  write(path, '#!/usr/bin/env bash\nif [ ! -f ' .. string.format('%q', marker) .. ' ]; then touch '
    .. string.format('%q', marker) .. '\nprintf ' .. string.format('%q',
      json.encode({ decision = 'block', reason = reason })) .. '\nfi\n')
  sh("chmod +x '" .. path .. "'")
  os.remove(marker)
  return "bash '" .. path .. "'"
end
sh("mkdir -p '" .. config .. "'")

local memory = dofile('lua/core/memory.lua'); memory.setup()
local telemetry = dofile('lua/core/telemetry.lua')
local hooks = dofile('lua/core/hooks.lua')
local agent = dofile('lua/core/agent.lua')

-- The fake provider: every request body is captured, and the answers come from a script.
local requests, answers = {}, {}
host.http_stream = function(_, _, _, body)
  requests[#requests + 1] = type(body) == 'string' and body or json.encode(body)
  local next_answer = table.remove(answers, 1)
  if not next_answer then error('the fixture was asked for more calls than it scripted') end
  return json.encode(next_answer)
end
local usage = { prompt_tokens = 100, completion_tokens = 10, total_tokens = 110 }
local function final(text)
  return { status = 200, content = text, stream_complete = true, finish_reason = 'stop',
    usage = usage, tool_calls = {} }
end
local function called_tool(calls)
  return { status = 200, content = '', stream_complete = true, finish_reason = 'tool_calls',
    usage = usage, tool_calls = calls }
end
local function run(text)
  requests = {}
  local sid = memory.start_session('', 'hooks-agent', { user_id = 'master', node_id = '', title = 'hooks-agent' })
  local emitted = {}
  local bot = agent.new(sid, function(event) emitted[#emitted + 1] = event end, 'master', 'master', '')
  local reply = bot:run(text)
  return reply, requests, emitted, sid
end
local function last_request_has(requests, needle)
  local body = requests[#requests] or ''
  return body:find(needle, 1, true) ~= nil
end

-- ---- 1. SessionStart adds context to the first request -------------------------------------------
local marker = answer('sessionstart', json.encode({ hookSpecificOutput = {
  hookEventName = 'SessionStart', additionalContext = 'SESSION-HOOK-CONTEXT' } }))
write(config .. '/hooks.json', json.encode({ hooks = { SessionStart = { { name = 'start', command = marker } } } }))
hooks.reset()
answers = { final('first answer') }
local reply, seen = run('hello')
ok(reply == 'first answer', 'the run answered')
ok(#seen == 1, 'one model request was made')
ok(last_request_has(seen, 'SESSION-HOOK-CONTEXT'), 'SessionStart additionalContext reached the request')
ok(last_request_has(seen, 'hook context'), 'and it is labelled as hook context, not as the user')

-- ---- 2. UserPromptSubmit adds context, and can refuse the prompt ---------------------------------
local prompt_context = answer('promptcontext', json.encode({ hookSpecificOutput = {
  hookEventName = 'UserPromptSubmit', additionalContext = 'PROMPT-HOOK-CONTEXT' } }))
write(config .. '/hooks.json', json.encode({ hooks = { UserPromptSubmit = {
  { name = 'context', command = prompt_context } } } }))
hooks.reset()
answers = { final('answered with context') }
local reply2, seen2 = run('hello again')
ok(reply2 == 'answered with context', 'the run answered')
ok(last_request_has(seen2, 'PROMPT-HOOK-CONTEXT'), 'UserPromptSubmit additionalContext reached the request')

local refusal = answer('promptrefuse', json.encode({ decision = 'block', reason = 'this prompt is not allowed' }))
write(config .. '/hooks.json', json.encode({ hooks = { UserPromptSubmit = {
  { name = 'refuse', command = refusal } } } }))
hooks.reset()
answers = {}
local refused, refused_requests, refused_events, refused_session = run('do the forbidden thing')
ok(refused == 'this prompt is not allowed', 'a refused prompt answers with the hook\'s reason')
ok(#refused_requests == 0, 'and no model call was made')
local rows = memory.session_messages(refused_session, { all = true })
local saw_user, saw_answer = false, false
for _, row in ipairs(rows) do
  if row.role == 'user' and tostring(row.content):find('do the forbidden thing', 1, true) then saw_user = true end
  if row.role == 'assistant' and tostring(row.content):find('not allowed', 1, true) then saw_answer = true end
end
ok(saw_user and saw_answer, 'the refused turn is recorded, so the transcript does not show a question that was never asked')
local saw_status = false
for _, event in ipairs(refused_events) do
  if event.type == 'status' and tostring(event.text):find('refused by hook', 1, true) then saw_status = true end
end
ok(saw_status, 'the reader is told a hook refused the prompt, and by which hook')

-- ---- 3. Stop: a hook can ask the run to continue, once ------------------------------------------
local stop_once = blocking_once('stoponce', 'the tests have not run yet - run them, then answer')
write(config .. '/hooks.json', json.encode({ hooks = { Stop = { { name = 'continue-once', command = stop_once } } } }))
hooks.reset()
answers = { final('first candidate'), final('second candidate, tests run') }
local stopped, stop_requests = run('answer the question')
ok(stopped == 'second candidate, tests run', 'a Stop hook asking to continue produces another turn: ' .. tostring(stopped))
ok(#stop_requests == 2, 'exactly one extra model call was made')
ok(last_request_has(stop_requests, 'the tests have not run yet'), 'the reason reached the continued turn')
ok(last_request_has(stop_requests, 'not a new user request'), 'and it is labelled as a hook, not as the user')

-- ---- 4. Stop: continue:false keeps the answer ------------------------------------------------
write(config .. '/hooks.json', json.encode({ hooks = { Stop = { { name = 'stop-now',
  command = answer('stopnow', json.encode({ continue = false, stopReason = 'the operator said stop' })) } } } }))
hooks.reset()
answers = { final('the first and only answer') }
local kept, kept_requests = run('answer once')
ok(kept == 'the first and only answer', 'continue:false keeps the answer')
ok(#kept_requests == 1, 'and makes no further model call')

-- ---- 5. the bound on continues ------------------------------------------------------------------
-- A hook that always says "keep going" cannot turn a run into an unbounded loop.
local always = answer('alwayscontinue', json.encode({ decision = 'block', reason = 'more work please' }))
write(config .. '/hooks.json', json.encode({ hooks = { Stop = { { name = 'always', command = always } } } }))
hooks.reset()
answers = { final('a'), final('b'), final('c'), final('d') }
local bounded = run('loop')
ok(bounded == 'd', 'the run stops after the documented number of continues (' .. tostring(bounded) .. ')')
ok(#requests == 4, 'the continue bound is enforced, not just described (' .. #requests .. ' calls)')

-- ---- 6. PreToolUse denies a tool call inside a real run ------------------------------------------
write(config .. '/hooks.json', json.encode({ hooks = { PreToolUse = {
  { name = 'no-bash', matcher = 'bash', command = answer('nobash', json.encode({ hookSpecificOutput = {
    hookEventName = 'PreToolUse', permissionDecision = 'deny',
    permissionDecisionReason = 'shell access is off in this fixture' } })) } } } }))
hooks.reset()
answers = {
  called_tool({ { id = 'call-1', type = 'function', ['function'] = { name = 'bash',
    arguments = json.encode({ command = 'echo SHOULD-NOT-RUN' }) } } }),
  final('the tool was refused, here is the answer'),
}
local denied_reply, denied_requests, denied_events, denied_session = run('run a shell command')
ok(denied_reply == 'the tool was refused, here is the answer', 'the run continued after the refusal')
ok(#denied_requests == 2, 'the model was asked again with the refusal as the tool result')
local tool_rows = {}
for _, row in ipairs(memory.session_messages(denied_session, { all = true })) do
  if row.role == 'tool' then tool_rows[#tool_rows + 1] = row end
end
ok(#tool_rows == 1, 'one tool result was recorded')
ok(tostring(tool_rows[1].content):find('hook_denied', 1, true) ~= nil, 'and it is the hook refusal')
ok(tostring(tool_rows[1].content):find('SHOULD-NOT-RUN', 1, true) == nil, 'the refused command never ran')

if failed > 0 then
  print(string.format('hooks agent: %d failed of %d checks', failed, checks))
  os.exit(1)
end
print(string.format('hooks agent ok (%d checks)', checks))
