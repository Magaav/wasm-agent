-- A complete line typed during a tool call reaches the *next* model request, and
-- is durable in the session rather than a transient instruction to the model.
local json = dofile('lua/vendor/json.lua')
local native_getenv = host.getenv
host.getenv = function(key)
  if key == 'WASM_AGENT_LLM_API_KEY' then return 'test-only' end
  if key == 'WASM_AGENT_PROVIDER' then return 'opencode-go' end
  if key == 'WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
  if key == 'WASM_AGENT_PI_MODELS_STORE' then return 'missing-test-store' end
  return native_getenv(key)
end
host.http = function() error('unexpected HTTP in hermetic steering test') end
host.http_stream = host.http
local memory = dofile('lua/core/memory.lua')
memory.setup()
local original_dofile = dofile
local provider = dofile('lua/core/provider.lua')
dofile = function(path)
  if path == 'lua/core/provider.lua' then return provider end
  return original_dofile(path)
end
local agentlib = original_dofile('lua/core/agent.lua')
dofile = original_dofile
local sid = memory.start_session('', 'cli-steering', {user_id='master', node_id='', title='cli-steering'})
local bot = agentlib.new(sid, function() end, 'master', 'master', '')
local calls, drains = 0, 0
bot.steer = function()
  drains = drains + 1
  if drains == 1 then return {'please use the new requirement'} end
  return {}
end
local usage = {prompt_tokens=1000, completion_tokens=50, total_tokens=1050}
provider.complete_with = function(_, messages)
  calls = calls + 1
  if calls == 1 then
    assert(drains == 0, 'steering cannot precede the initial user prompt')
    return {content='', finish_reason='tool_calls', usage=usage,
      tool_calls={{id='call-1',type='function',['function']={name='read',
        arguments=json.encode({path='AGENTS.md', limit=2})}}}}
  end
  assert(calls == 2, 'steering does not start a separate run')
  assert(messages[#messages].role == 'user' and messages[#messages].content == 'please use the new requirement',
    'the next model call sees the note after the tool result')
  return {content='steering received',tool_calls={},finish_reason='stop',usage=usage}
end
assert(bot:run('inspect this project') == 'steering received', 'the run answered')
assert(calls == 2 and drains == 1, 'one message steered one round')
local found = false
for _, row in ipairs(memory.session_messages(sid, {limit=30})) do
  if row.role == 'user' and row.content == 'please use the new requirement' then found = true end
end
assert(found, 'steering survives in the durable transcript')
print('cli steering ok (round boundary, model context, durable transcript)')
