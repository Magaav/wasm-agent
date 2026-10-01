-- A route must refuse, before the first provider request, a model it cannot serve - and only
-- that. Two failures motivated this file. A child with `gpt-6-luna` on the opencode-go route died
-- in 0.67s with zero tool calls on the edge's `Model does not support this protocol`, and 26
-- child runs of `deepseek-v4.1-flash` died on the subscription route's `Model is absent from Pi
-- catalog`. The first version of the check then refused five ids the subscription route *does*
-- serve, because it decided from a hardcoded picker list. So the catalogue here is a fixture of
-- pi's own store (same keys, same `api` per id), the deciding fact is the protocol, and an id the
-- catalogue does not mention must stay unknown and allowed. Hermetic: HTTP is a counter, so a
-- request that leaves is the failure under test, and the one permitted request is stub-answered.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local native_getenv = host.getenv
local overrides = {WASM_AGENT_LLM_API_KEY='test-only', WASM_AGENT_PROVIDER='opencode-go',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash'}
host.getenv = function(key) if overrides[key] ~= nil then return overrides[key] end return native_getenv(key) end
local sent = {}
host.http = function(method, url, headers, body)
  sent[#sent + 1] = {method=method, url=url, body=body}
  if method == 'GET' and url:match('/models$') then
    return json.encode({status=200, body=json.encode({data={
      {id='gpt-6-sol'}, {id='gpt-6-luna'}, {id='minimax-m3'},
      {id='deepseek-v4.1-flash'}, {id='new-uncatalogued-model'}}})})
  end
  return json.encode({status=200, body=json.encode({
    model='stub-model',
    choices={{message={role='assistant', content='stub answer'}, finish_reason='stop'}},
    usage={prompt_tokens=10, completion_tokens=2, total_tokens=12}})})
end
host.http_stream = host.http

-- The catalogue: pi's local model store, keyed by pi's provider id, each entry carrying the `api`
-- that id is served over. These are the ids the verifier executed against the live store.
local store_path = paths.temp() .. '/wa-route-servability-store.json'
local function entry(id, api)
  local e = {id=id, api=api, provider='fixture', reasoning=true, maxTokens=128000}
  if id == 'deepseek-v4.1-flash' then
    e.compat = {thinkingFormat='deepseek', maxTokensField='max_tokens'}
    e.thinkingLevelMap = {low='low', high='high', max='max'}
  end
  return e
end
local codex = {'gpt-5.3-codex-spark', 'gpt-5.5', 'gpt-5.6-luna', 'gpt-5.6-sol', 'gpt-5.6-terra',
  'gpt-6-astra', 'gpt-6-luna', 'gpt-6-sol', 'gpt-6.1-sol'}
local function catalogue()
  local models = {{'opencode-go', 'deepseek-v4.1-flash', 'openai-completions'},
    {'opencode-go', 'glm-5.3', 'openai-completions'}, {'opencode-go', 'gpt-6-luna', 'openai-responses'},
    {'opencode-go', 'gpt-5.6-luna', 'openai-responses'}, {'opencode-go', 'minimax-m3', 'anthropic-messages'}}
  for _, id in ipairs(codex) do models[#models + 1] = {'openai-codex', id, 'openai-codex-responses'} end
  local store = {}
  for _, row in ipairs(models) do
    store[row[1]] = store[row[1]] or {models = {}}
    local list = store[row[1]].models
    list[#list + 1] = entry(row[2], row[3])
  end
  return store
end
local written = host.write_file(store_path, json.encode(catalogue()))
assert(written, 'the catalogue fixture must be written')
overrides.WASM_AGENT_PI_MODELS_STORE = store_path

local original_dofile = dofile
local subscription = original_dofile('lua/core/openai_sub.lua')
local bridge_calls = 0
subscription.complete = function(model)
  bridge_calls = bridge_calls + 1
  return {content='bridge answer', tool_calls={}, finish_reason='stop', model=model}
end
dofile = function(path)
  if path == 'lua/core/openai_sub.lua' then return subscription end
  return original_dofile(path)
end
local provider = dofile('lua/core/provider.lua')
dofile = original_dofile
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

-- The catalogue decides by protocol. Every id the subscription route serves is served here, even
-- the five a hardcoded picker list used to refuse; and an id the store does not mention is not a
-- refusal at all.
for _, id in ipairs(codex) do
  check(provider.serves(id, sub) == true, 'the subscription route serves ' .. id)
end
check(provider.serves('deepseek-v4.1-flash', sub) == false,
  "the subscription route does not serve a chat-completions id")
check(provider.serves('deepseek-v4.1-flash') == true, 'opencode-go serves its own chat-completions model')
check(provider.serves('gpt-6-luna') == false, 'opencode-go does not serve a responses-only id')
check(provider.serves('gpt-5.6-luna') == false, 'and refuses the whole family, not one name in it')
check(provider.serves('minimax-m3') == false, 'nor an id the edge serves over anthropic-messages')
check(provider.serves('no-such-model-anywhere') == nil, 'an id the catalogue is silent about is unknown')
check(provider.serves('gpt-4.1', public_api) == nil, 'an id no catalogue mentions is unknown on any route')
check(provider.serves('deepseek-v4.1-flash', public_api) == nil,
  "an id only another route lists is unknown here, not claimed and not refused")

-- The refusal: before the wire, naming route, model and the true reason.
local selected_before = provider.settings().model
local ok, problem = pcall(provider.complete_with, 'gpt-6-luna', messages, nil, false, {})
check(not ok, 'a gpt-6-luna request on the opencode-go route must be refused: ' .. tostring(problem))
problem = tostring(problem)
check(problem:find('model_not_servable', 1, true) ~= nil, 'the refusal carries a stable code: ' .. problem)
check(problem:find('provider=opencode-go', 1, true) ~= nil, 'it names the provider id: ' .. problem)
check(problem:find('model=gpt-6-luna', 1, true) ~= nil, 'it names the model: ' .. problem)
check(problem:find('serves this id over ', 1, true) ~= nil, 'it states the protocol the catalogue serves the id over, not a false ownership claim: ' .. problem)
check(problem:find('openai-responses (this route)', 1, true) ~= nil,
  "and names this route's own entry for the id: " .. problem)
check(problem:find('this route speaks openai-completions', 1, true) ~= nil,
  'and the protocol this route speaks: ' .. problem)
check(problem:find('POST /chat/completions', 1, true) ~= nil, 'and what that is on the wire: ' .. problem)
check(problem:find('nothing substituted', 1, true) ~= nil, 'the refusal says it substituted nothing: ' .. problem)
check(#sent == 0, 'the refusal must happen before the first provider request, got ' .. #sent .. ' request(s)')
check(provider.settings().model == selected_before,
  'a refusal must not change the selected model: ' .. tostring(selected_before) .. ' -> ' .. tostring(provider.settings().model))

-- The same pair from the node's environment, which is the shape the failing child had.
overrides.WASM_AGENT_LLM_MODEL = 'gpt-6-luna'
local env_ok, env_problem = pcall(provider.complete, messages, nil, false, {})
check(not env_ok, 'the mismatch must be refused when the model comes from the environment')
check(tostring(env_problem):find('model=gpt-6-luna', 1, true) ~= nil, 'and name it: ' .. tostring(env_problem))
check(#sent == 0, 'still nothing on the wire')
check(provider.unservable(nil) == nil and provider.unservable('') == nil, 'no model means nothing to check')
overrides.WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash'

-- The subscription route and its own ids: the request path must let them through rather than
-- refuse them. Pi's bridge is stood in for above.
sent = {}
provider.provider_override = 'openai-sub'
local bridge_ok, bridge_result = pcall(provider.complete_with, 'gpt-5.6-terra', messages, nil, false, {})
check(bridge_ok, 'gpt-5.6-terra must not be refused on the subscription route: ' .. tostring(bridge_result))
check(bridge_result and bridge_result.content == 'bridge answer',
  'and the subscription route must reach its transport: ' .. json.encode(bridge_result or {}))
check(bridge_calls == 1, 'the subscription route serves the id, got ' .. bridge_calls .. ' transport call(s)')
check(provider.unservable('gpt-5.5', sub) == nil and provider.unservable('gpt-6-sol', sub) == nil,
  'every id in the route catalogue passes the preflight')

-- "sol 6.1" is the owner's name for `gpt-6.1-sol`, the id the catalogue publishes: the name and
-- the id are not the same string, and only the id routes. Serving it takes both halves - the
-- route must *offer* it (the picker, this repository's file) and the catalogue must publish it
-- over this route's protocol (pi's store, the live config). Either half alone is a model that
-- looks configured and fails: a picked id nothing catalogs, or a catalogued id nothing offers.
local offered = false
for _, id in ipairs(subscription.models or {}) do if id == 'gpt-6.1-sol' then offered = true end end
check(offered, 'the subscription picker must offer gpt-6.1-sol: ' ..
  table.concat(subscription.models or {}, ','))
check(provider.serves('gpt-6.1-sol', sub) == true and provider.unservable('gpt-6.1-sol', sub) == nil,
  'and this route must serve it: ' .. tostring(provider.unservable('gpt-6.1-sol', sub)))
check(provider.serves('sol 6.1', sub) == nil and provider.unservable('sol 6.1', sub) == nil,
  'the spoken name is not the id: an id the catalogue never mentions stays undecided, not mapped')

-- The wrong route still refuses it, and still for the true reason: opencode-go posts
-- /chat/completions and this id is served over openai-codex-responses. An id that is reachable
-- on the right route must not become reachable everywhere.
provider.provider_override = 'opencode-go'
local wrong_route = provider.unservable('gpt-6.1-sol')
check(wrong_route ~= nil and wrong_route:find('model_not_servable', 1, true) ~= nil and
  wrong_route:find('provider=opencode-go', 1, true) ~= nil and
  wrong_route:find('model=gpt-6.1-sol', 1, true) ~= nil and
  wrong_route:find('openai-codex-responses', 1, true) ~= nil,
  'gpt-6.1-sol must stay refused on the opencode-go route: ' .. tostring(wrong_route))
check(#sent == 0, 'and that refusal costs no request')
check(provider.serves('gpt-6.1-sol', public_api) == false,
  'the public-API route cannot serve a subscription id either, and says so')

-- A model the route can serve still runs unchanged: same model, same route, one request.
sent = {}
local reply = provider.complete_with('deepseek-v4.1-flash', messages, nil, false, {})
check(reply.content == 'stub answer', 'the served model must still reach the provider')
check(#sent == 1, 'exactly one request, got ' .. #sent)
local request = json.decode(sent[1].body)
check(request.model == 'deepseek-v4.1-flash', 'the requested model is sent unchanged, got ' .. tostring(request.model))
check(sent[1].url == provider.active().base_url:gsub('/+$', '') .. '/chat/completions',
  'and to the active route: ' .. tostring(sent[1].url))

-- An id nobody catalogued stays allowed, and the floor is the same when the store is missing: a
-- stale or absent store must never refuse a run. That floor is what the picker-list version broke.
overrides.WASM_AGENT_LLM_MODEL = 'no-such-model-anywhere'
sent = {}
local unknown_ok = pcall(provider.complete, messages, nil, false, {})
check(unknown_ok and #sent == 1, 'an id the catalogue never mentions is sent, not refused')
overrides.WASM_AGENT_PI_MODELS_STORE = store_path .. '.absent'
check(provider.serves('gpt-6-luna') == nil, 'with no store there is nothing to decide from')
check(provider.unservable('gpt-6-luna') == nil, 'so nothing is refused')
overrides.WASM_AGENT_PI_MODELS_STORE = store_path
overrides.WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash'

-- The launch gate. A child must not be given a session, a workspace and a thread for a pair that
-- cannot run: `task-worker`'s own `gpt-6-luna` on this route is that pair.
local memory = dofile('lua/core/memory.lua')
memory.setup()
local subagents = dofile('lua/core/subagents.lua')
local function write_profile(name, body)
  assert(host.write_file(paths.config() .. '/subagent-profiles/' .. name .. '.json', json.encode(body)),
    'write profile ' .. name)
end
write_profile('route-probe-refused', {schema_version=1, id='route-probe-refused', allowed_tools={'read'},
  model='gpt-6-luna', approved_models={'gpt-6-luna'}, limits={max_depth=0, timeout_seconds=30}})
write_profile('route-probe-served', {schema_version=1, id='route-probe-served', allowed_tools={'read'},
  model='deepseek-v4.1-flash', approved_models={'deepseek-v4.1-flash'},
  limits={max_depth=0, timeout_seconds=30, max_tokens=1}})
local parent = memory.start_session('', 'chat', {user_id='master', node_id='', title='route parent'})
local ctx = {user_id='master', role='master', session_id=parent, run_id='route-run', node_id='',
  depth=0, model='deepseek-v4.1-flash'}
local latest_before = memory.latest_session('master', '')
local launched = subagents.start({prompt='do the thing', profile='route-probe-refused'}, ctx)
local launch_error = tostring(launched and launched.error)
check(launched and not launched.session_id, 'a refused launch must not return a session')
check(launch_error:find('model_not_servable', 1, true) ~= nil,
  'the launch must be refused by the same predicate: ' .. launch_error)
check(launch_error:find('provider=opencode-go', 1, true) ~= nil and
  launch_error:find('model=gpt-6-luna', 1, true) ~= nil,
  'and name the route and the model: ' .. launch_error)
check(launch_error:find('serves this id over ', 1, true) ~= nil,
  'and give the true reason: ' .. launch_error)
-- The mirror: a chat-completions id on the subscription route names both protocols too.
local mirror_error = tostring(provider.unservable('deepseek-v4.1-flash', sub))
check(mirror_error:find('openai-completions (route opencode-go)', 1, true) ~= nil and
  mirror_error:find('this route speaks openai-codex-responses', 1, true) ~= nil,
  'the mirror refusal names the protocol both ways: ' .. mirror_error)
local latest_after = memory.latest_session('master', '')
check(latest_after and latest_before and latest_after.id == latest_before.id,
  'no child session may be created for a pair that cannot run')
-- The control: a served model gets past the same gate (the refusal here is the pre-existing
-- token-budget check, which fires after it and before any session).
local control = subagents.start({prompt='do the thing', profile='route-probe-served'}, ctx)
local control_error = tostring(control and control.error)
check(control_error:find('model_not_servable', 1, true) == nil,
  'a served model must not be refused at launch: ' .. control_error)
check(control_error:find('subagent_token_budget', 1, true) ~= nil,
  'and it must reach the next real check: ' .. control_error)

-- Picker/setter recovery: the provider can be selected with an old invalid
-- saved model, but it must not silently substitute or accept a new mismatch.
local state = dofile('lua/core/state.lua')
-- This home is shared with every other gate step, so whatever selection it had is
-- restored before this file ends. A suite that leaves `provider` changed makes a later
-- suite's route depend on gate step order: this section's first version wrote
-- `provider=opencode-go` and broke `scripts/test-openai-sub-levels.lua`, which resolves
-- its route from this file before its own env override.
local prior_provider, prior_go_model = state.read('provider'), state.read('model.opencode-go')
provider.provider_override = 'opencode-go'
provider.overrides = nil
state.write('model.opencode-go', 'gpt-6-sol')
check(provider.set_provider('opencode-go') == true, 'allow entering a stale route to repair its model')
check(provider.settings().model == 'gpt-6-sol', 'provider switch must not silently replace the saved model')
local offered_go = provider.list_models('opencode-go')
check(table.concat(offered_go, ',') == 'deepseek-v4.1-flash,new-uncatalogued-model',
  'picker filters only known mismatches: ' .. table.concat(offered_go, ','))
local changed, selection_error = provider.set_model('gpt-6-luna')
check(not changed and selection_error:find('model_not_servable', 1, true), 'reject mismatched selection')
check(provider.settings().model == 'gpt-6-sol' and state.read('model.opencode-go') == 'gpt-6-sol',
  'rejected selection leaves memory and persisted selection untouched')
check(provider.set_model('deepseek-v4.1-flash') == true, 'explicit supported selection repairs stale state')
check(state.read('model.opencode-go') == 'deepseek-v4.1-flash', 'persist the explicit repair')
check(provider.reasoning().supported and table.concat(provider.reasoning().levels, ',') == 'low,high,max',
  'the repaired Go model exposes its catalogue reasoning levels')
check(provider.set_reasoning('low') == true and provider.reasoning().selected == 'low', 'reasoning selection roundtrip')
local fields = provider.request_options('deepseek-v4.1-flash', messages, {})
check(fields.thinking.type == 'enabled' and fields.reasoning_effort == 'low', 'send chosen DeepSeek reasoning')
provider.overrides = nil
check(provider.settings().model == 'deepseek-v4.1-flash' and provider.reasoning().selected == 'low',
  'model/reasoning survive an in-memory settings reset')
local refused_reasoning = provider.set_reasoning('medium')
check(not refused_reasoning and provider.reasoning().selected == 'low', 'unsupported reasoning does not change state')
check(not provider.set_model('') and not provider.set_provider('bogus-provider'), 'empty/unknown settings refuse')
check(provider.set_model('new-uncatalogued-model') == true, 'unknown catalogue entries still allow explicit selection')
provider.set_model('deepseek-v4.1-flash')

-- Exercise the actual server routes, not only the setters. Keep HTTP stubbed
-- and return the same provider module so state and in-memory observations agree.
dofile = function(path)
  if path == 'lua/core/provider.lua' then return provider end
  return original_dofile(path)
end
original_dofile('lua/core/server.lua')
dofile = original_dofile
local rejected_route = json.decode(wa_set_model('gpt-6-sol', '', ''))
check(rejected_route.error and rejected_route.error:find('model_not_servable', 1, true),
  'the local model route surfaces rejection instead of reporting success')
check(state.read('model.opencode-go') == 'deepseek-v4.1-flash', 'route rejection does not persist the bad model')
check(json.decode(wa_set_provider('bogus-provider', '', '')).error == 'unknown_provider',
  'the provider route surfaces unknown providers')
local repaired_route = json.decode(wa_set_model('deepseek-v4.1-flash', '', ''))
check(not repaired_route.error and not repaired_route.model_error and repaired_route.reasoning.supported,
  'the real route returns usable model/reasoning after repair')
local reasoning_route = json.decode(wa_set_reasoning('high', '', ''))
check(not reasoning_route.error and reasoning_route.reasoning.selected == 'high', 'actual reasoning route roundtrip')
state.write('model.opencode-go', 'gpt-6-sol')
provider.overrides = nil
local stale_route = json.decode(wa_model('', ''))
check(stale_route.model == 'gpt-6-sol' and stale_route.model_error:find('model_not_servable', 1, true),
  'actual status payload discloses a stale persisted model without replacing it')
provider.set_model('deepseek-v4.1-flash')

-- Leave the shared home exactly as it was found (an empty value reads as absent).
state.write('provider', prior_provider or '')
state.write('model.opencode-go', prior_go_model or '')
check(state.read('provider') == prior_provider and state.read('model.opencode-go') == prior_go_model,
  'the shared home selection must be restored, got ' .. tostring(state.read('provider')) .. '/' ..
  tostring(state.read('model.opencode-go')))

print('model route servability ok ('..checks..' checks)')
