-- A route that cannot serve the requested model must refuse before the first provider request.
--
-- Measured on this node: a child launched with `gpt-6-luna/max` on the opencode-go route failed in
-- 0.67s with zero tool calls on `provider_http_400 {"type":"ModelProtocolUnsupported"}`, and 26
-- recorded child runs of `deepseek-v4.1-flash` died on the subscription route's `Model is absent
-- from Pi catalog`. Both are a model/route mismatch that nothing checked. Hermetic: the HTTP
-- capability is a counter here, so a request that leaves *is* the failure under test, and the one
-- request this file does allow is answered by the stub rather than by a network.
local json = dofile('lua/vendor/json.lua')
local native_getenv = host.getenv
local overrides = {WASM_AGENT_LLM_API_KEY='test-only', WASM_AGENT_PROVIDER='opencode-go',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE='missing-test-store'}
host.getenv = function(key) if overrides[key] ~= nil then return overrides[key] end return native_getenv(key) end
local sent = {}
host.http = function(method, url, headers, body)
  sent[#sent + 1] = {method=method, url=url, body=body}
  return json.encode({status=200, body=json.encode({
    model='stub-model',
    choices={{message={role='assistant', content='stub answer'}, finish_reason='stop'}},
    usage={prompt_tokens=10, completion_tokens=2, total_tokens=12}})})
end
host.http_stream = host.http

local provider = dofile('lua/core/provider.lua')
-- The route under test is pinned in-memory rather than by a state file: the suite shares one home,
-- and which provider a previous gate step left selected must not decide what this proves.
provider.provider_override = 'opencode-go'
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function profile(id)
  for _, candidate in ipairs(provider.providers()) do
    if candidate.id == id then return candidate end
  end
end
local sub, public_api = profile('openai-sub'), profile('gpt')
check(sub ~= nil and public_api ~= nil, 'the shipped routes must be discoverable')
check(provider.active().id == 'opencode-go', 'this test drives the opencode-go route, got ' .. tostring(provider.active().id))
local messages = {{role='user', content='hi'}}

-- The predicate. A route whose catalogue is the edge's own answers nil for an id it has never
-- seen (unknown, allowed); the subscription route's declaration is its whole catalogue.
check(provider.serves('deepseek-v4.1-flash') ~= false, 'the active route is not refused its own model')
check(provider.serves('gpt-6-luna', sub) == true, 'the subscription route serves its own model')
check(provider.serves('deepseek-v4.1-flash', sub) == false,
  "the subscription route does not serve a model outside Pi's catalogue")
check(provider.serves('gpt-6-luna') == false, "opencode-go does not serve the subscription route's model")
check(provider.serves('gpt-6-luna', public_api) == false,
  'the public API route does not serve a subscription-only id')
check(provider.serves('gpt-4.1', public_api) ~= false, 'the public API route keeps its own model')

-- The refusal: before the wire, naming the route and the model, with nothing substituted.
local selected_before = provider.settings().model
local ok, problem = pcall(provider.complete_with, 'gpt-6-luna', messages, nil, false, {})
check(not ok, 'a gpt-6-luna request on the opencode-go route must be refused: ' .. tostring(problem))
problem = tostring(problem)
check(problem:find('model_not_servable', 1, true) ~= nil, 'the refusal must carry a stable code: ' .. problem)
check(problem:find('provider=opencode-go', 1, true) ~= nil, 'the refusal must name the provider id: ' .. problem)
check(problem:find('model=gpt-6-luna', 1, true) ~= nil, 'the refusal must name the model: ' .. problem)
check(problem:find('nothing substituted', 1, true) ~= nil, 'the refusal must say it substituted nothing: ' .. problem)
check(#sent == 0, 'the refusal must happen before the first provider request, got ' .. #sent .. ' request(s)')
check(provider.settings().model == selected_before,
  'a refusal must not change the selected model: ' .. tostring(selected_before) .. ' -> ' .. tostring(provider.settings().model))

-- The shape the failing child had: no explicit model, with the route's model coming from the
-- node's environment while the provider is opencode-go.
overrides.WASM_AGENT_LLM_MODEL = 'gpt-6-luna'
local env_ok, env_problem = pcall(provider.complete, messages, nil, false, {})
check(not env_ok, 'the same mismatch must be refused when the model comes from the environment')
check(tostring(env_problem):find('model=gpt-6-luna', 1, true) ~= nil, 'and name it: ' .. tostring(env_problem))
check(#sent == 0, 'still nothing on the wire')
check(provider.unservable(nil) == nil and provider.unservable('') == nil, 'no model means nothing to check')
overrides.WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash'

-- A model the route can serve still runs unchanged: same model, same route, one request.
sent = {}
local reply = provider.complete_with('deepseek-v4.1-flash', messages, nil, false, {})
check(reply.content == 'stub answer', 'the served model must still reach the provider')
check(#sent == 1, 'exactly one request, got ' .. #sent)
local request = json.decode(sent[1].body)
check(request.model == 'deepseek-v4.1-flash', 'the requested model is sent unchanged, got ' .. tostring(request.model))
check(sent[1].url == provider.active().base_url:gsub('/+$', '') .. '/chat/completions',
  'and to the active route: ' .. tostring(sent[1].url))
-- The subscription route keeps its own model past the preflight. Its transport is Pi's bridge, and
-- scripts/test-openai-sub.cjs is what exercises that; here only the preflight's answer is asserted.
check(provider.unservable('gpt-6-luna', sub) == nil, 'the subscription route keeps its own model')
check(provider.unservable('deepseek-v4.1-flash', sub) ~= nil,
  'and refuses a foreign model even when asked about another route than the active one')

print('model route servability ok ('..checks..' checks)')
