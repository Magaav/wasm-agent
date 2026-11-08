-- The model gateway's loop side: the data labels, the wire shape it hands the host, and the fact that
-- `WA_MODEL_GATEWAY` off means the native provider path is byte-for-byte what it always was.
--
-- Hermetic: a stubbed `host.http_stream` (the native path) and a stubbed `host.model_gateway` (the
-- component path), a scratch WASM_AGENT_HOME, no node, no network, no model. Run:
--   WASM_AGENT_LUA_ROOT=<checkout> WA_SCRIPT=scripts/test-model-gateway.lua wa --db /tmp/x.db
local json = dofile('lua/vendor/json.lua')

local checks = 0
local function check(value, label)
  checks = checks + 1
  if not value then error('MODEL GATEWAY CHECK FAILED: ' .. label) end
end

-- The flag is read when a module loads, so this test flips the host's answer and loads the module again:
-- the same trick `scripts/test-selfloop-component.lua` uses, and the same thing a node does at boot.
local native_getenv = host.getenv
local flag = nil
local env = {
  WASM_AGENT_LLM_API_KEY = 'fixture-model-gateway',
  WASM_AGENT_PROVIDER = 'opencode-go',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash',
  WASM_AGENT_PI_MODELS_STORE = 'missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET = '0',
}
host.getenv = function(key)
  if key == 'WA_MODEL_GATEWAY' then return flag end
  if env[key] ~= nil then return env[key] end
  return native_getenv(key)
end

-- The native path's transport: it records what the loop sent and answers a complete streamed turn.
local sent = {}
host.http = function() error('unexpected host.http in this test') end
host.http_stream = function(method, url, headers, body)
  sent[#sent + 1] = { method = method, url = url, headers = headers, body = body }
  return json.encode({
    status = 200,
    content = 'native answer',
    finish_reason = 'stop',
    model = 'deepseek-v4.1-flash',
    usage = { prompt_tokens = 10, completion_tokens = 2 },
    request_id = 'req_native',
    ttft_ms = 5,
    stream_complete = true,
    chunks = 1,
  })
end

local memory = dofile('lua/core/memory.lua')
memory.setup()
local provider = dofile('lua/core/provider.lua')
local gateway = dofile('lua/core/model_gateway.lua')

check(gateway.enabled() == false, 'the gateway is off unless WA_MODEL_GATEWAY=1')

-- ---------------------------------------------------------------------------------------- the labels

check(gateway.label_of_source({ kind = 'channel', own_chat = false }) == 'client',
  'a client message labels the session client')
check(gateway.label_of_source({ kind = 'channel', own_chat = true }) == 'internal',
  "the operator's own chat is internal, not client")
check(gateway.label_of_source({ kind = 'operator' }) == 'internal',
  'the operator typing is internal')
check(gateway.label_of_source({ kind = 'tool_result', inherited = 'client' }) == 'client',
  'a tool result inherits the label of what it read')
check(gateway.label_of_source({ kind = 'tool_result', inherited = 'none' }) == 'client',
  'an unlabelled tool result fails closed')
check(gateway.label_of_source({ kind = 'whatsapp' }) == 'client',
  'an unclassified source fails closed')
check(gateway.strictest('public', 'internal') == 'internal', 'a session label only ever gets stricter')
check(gateway.strictest('client', 'public') == 'client', 'a weaker label never lowers a session')
check(gateway.strictest(nil, 'internal') == 'internal', 'a missing label does not win')

local session = 'gateway-labels-' .. tostring(host.now())
check(gateway.session_label(session) == 'client',
  'a session nobody labelled is client: the default loses capability, never leaks')
check(gateway.note(session, { kind = 'operator' }) == 'internal', 'the operator sets internal')
check(gateway.session_label(session) == 'internal', 'the label is remembered for the session')
check(gateway.note(session, { kind = 'channel', own_chat = false }) == 'client',
  'a client message raises the session label to client')
check(gateway.session_label(session) == 'client', 'the strictest label wins for the session')
check(gateway.note(session, { kind = 'operator' }) == 'client',
  'a later internal source does not lower the session label')
gateway.forget(session)
check(gateway.session_label(session) == 'client', 'a forgotten session is back to the strict default')

-- -------------------------------------------------------------------------------------- the request

local messages = {
  { role = 'system', content = 'You are a careful agent.' },
  { role = 'user', content = 'read a.txt' },
  { role = 'assistant', content = '', tool_calls = {
    { id = 'call_1', ['function'] = { name = 'read', arguments = '{"path":"a.txt"}' } },
  } },
  { role = 'tool', content = 'contents', tool_call_id = 'call_1', name = 'read' },
}
local tools = {
  { name = 'read', description = 'read a file', schema = { type = 'object', properties = { path = { type = 'string' } } } },
}
local request = gateway.build_request('deepseek-v4.1-flash', messages, tools, {
  session_id = session,
  kind = 'step',
  breakpoint_index = 1,
  max_output_tokens = 2048,
})
check(request['class'] == 'default', 'an ordinary step is the default class')
check(request.label == 'client', "the request carries the session's label")
check(#request.messages == 4, 'every message is handed over')
check(request.messages[1].role == 'system' and request.messages[2].role == 'user'
  and request.messages[3].role == 'assistant' and request.messages[4].role == 'tool',
  'the messages keep the order the loop built them in')
check(request.messages[1].cache_breakpoint == true, 'the requested breakpoint sits where the caller put it')
for index = 2, 4 do
  check(request.messages[index].cache_breakpoint == false, 'no other message grows a breakpoint')
end
check(request.messages[2].parts[1].type == 'text' and request.messages[2].parts[1].text == 'read a.txt',
  'a text part is a typed part')
check(request.messages[3].tool_calls[1].id == 'call_1'
  and request.messages[3].tool_calls[1].name == 'read'
  and request.messages[3].tool_calls[1].arguments_json == '{"path":"a.txt"}',
  'an assistant tool call keeps its id, name and arguments verbatim')
check(request.messages[4].tool_call_id == 'call_1' and request.messages[4].name == 'read',
  'a tool result keeps the call it answers')
check(#request.tools == 1 and request.tools[1].name == 'read', 'the tool list is handed over')
check(request.max_output_tokens == 2048, 'the output cap is handed over')
check(request.model == nil, 'a bare model id is not a provider/model ref')

check(gateway.class_for({ kind = 'compact' }) == 'cheap', 'a compaction is the cheap class')
check(gateway.class_for({ kind = 'vision' }) == 'vision', 'a vision turn is the vision class')
check(gateway.class_for({ kind = 'codemode' }) == 'code', "code mode's turns are the code class")
check(gateway.class_for({ kind = 'decision', class = 'plan' }) == 'plan', 'an explicit class wins')

local ref = gateway.build_request('x', messages, tools, { session_id = session, model = 'anthropic/claude-sonnet-4-5' })
check(ref.model and ref.model.provider == 'anthropic' and ref.model.model == 'claude-sonnet-4-5',
  'a provider/model ref is split for the component')

-- ------------------------------------------------------------------ the native path, flag off

local sid = memory.start_session('', 'model-gateway-native', { user_id = 'master', node_id = '', title = 'native' })
local native = provider.complete_with('deepseek-v4.1-flash', messages, tools, true, { session_id = sid, kind = 'step' })
check(native and native.content == 'native answer', 'the native path still serves the turn')
check(#sent == 1, 'the native path still calls host.http_stream exactly once')
local body = json.decode(sent[1].body)
check(#body.messages == 4 and body.messages[2].role == 'user',
  'the native body carries the caller\'s messages in order')
check(body.messages[2].content == 'read a.txt', 'the native body is unchanged by the seam')

-- A second identical turn must send identical prefix bytes: the prompt cache depends on it, and the flag
-- being off must mean nothing at all changed.
local again = provider.complete_with('deepseek-v4.1-flash', messages, tools, true, { session_id = sid, kind = 'step' })
check(again and again.content == 'native answer', 'the second native call is served the same way')
check(sent[2].body == sent[1].body, 'two identical native turns send identical bytes')
check(sent[2].url == sent[1].url, 'and the same endpoint')

-- ------------------------------------------------------------------ the component path, flag on

flag = '1'
local calls = {}
host.model_gateway = function(text)
  calls[#calls + 1] = json.decode(text)
  return json.encode({
    ok = true,
    result = {
      content = 'gateway answer',
      reasoning = '',
      finish_reason = 'stop',
      tool_calls = {},
      model = 'claude-sonnet-4-5',
      provider = 'anthropic',
      ['class'] = 'default',
      label = 'client',
      attempts = 2,
      latency_ms = 320,
      fallback_from = 'deepseek/deepseek-v4.1-flash',
      usage = { input_tokens = 40, output_tokens = 3, cache_read_tokens = 900, cache_write_tokens = 0, reasoning_tokens = 0 },
    },
  })
end
local routed = dofile('lua/core/provider.lua')
check(routed.settings ~= nil, 'the routed module loads')
local served = routed.complete_with('deepseek-v4.1-flash', messages, tools, true, { session_id = session, kind = 'step' })
check(served and served.content == 'gateway answer', 'the flag routes the call through the component')
check(#sent == 2, 'the native transport was not used when the gateway served the turn')
check(#calls == 1, 'the component was asked exactly once')
check(calls[1].label == 'client', 'the request the component sees carries the session label')
check(calls[1]['class'] == 'default', 'the request the component sees carries the task class')
check(calls[1].messages[1].role == 'system', 'the request the component sees starts with the system turn')
check(served.gateway and served.gateway.provider == 'anthropic', 'the route that served is readable')
check(served.gateway.attempts == 2 and served.gateway.fallback_from == 'deepseek/deepseek-v4.1-flash',
  'the fallback that happened is readable')
check(served.gateway.cache_read_tokens == 900, 'the cache accounting survives the seam')
check(served.usage.input_tokens == 40, 'the usage is the provider\'s, not an estimate')

-- A refusal is an answer: the loop is told why, and does not retry into the same wall.
host.model_gateway = function()
  return json.encode({
    ok = false,
    error = { code = 'label_not_allowed', reason = 'label_not_allowed: deepseek allows public,internal' },
  })
end
local ok, problem = pcall(routed.complete_with, 'deepseek-v4.1-flash', messages, tools, true, { session_id = session })
check(ok == false, 'a refusal stops the call')
check(tostring(problem):find('model_gateway_label_not_allowed', 1, true) ~= nil,
  'the refusal name reaches the loop: ' .. tostring(problem))

-- A missing capability is a reason to run the native path with a log line, never a silent failure.
host.model_gateway = nil
local before = #sent
local fell_back = routed.complete_with('deepseek-v4.1-flash', messages, tools, true, { session_id = sid, kind = 'step' })
check(fell_back and fell_back.content == 'native answer', 'a missing capability falls back to the native path')
check(#sent == before + 1, 'the fallback really served the turn natively')

print('model gateway: ' .. checks .. ' checks passed')
