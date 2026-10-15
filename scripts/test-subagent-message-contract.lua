-- Isolated model-free fixture: actual facade and steering store, mocked native continuation.
local original_dofile = dofile
local json = original_dofile('lua/vendor/json.lua')
local memory = original_dofile('lua/core/memory.lua')
local tools = original_dofile('lua/core/tools.lua')
memory.setup()
local checks = 0
local function check(ok, label) assert(ok, label); checks = checks + 1 end
local definition
for _, tool in ipairs(tools.catalog('master')) do
  if tool['function'].name == 'subagent' then definition = tool['function'] end
end
check(definition ~= nil, 'subagent_schema_present')
check(definition.description:find('`message`, `steer` and `steer_session` require a non-empty `idempotency_key`', 1, true), 'message_requires_key_in_tool_help')
local parameters = definition.parameters
check(parameters.properties.idempotency_key.description:find('Required, non-empty for message, steer and steer_session', 1, true), 'conditional_key_property_help')
check(parameters.properties.idempotency_key.description:find('optional for start', 1, true), 'start_key_remains_optional')
check(parameters.properties.idempotency_key.description:find('No key is needed for read-only actions', 1, true), 'reads_need_no_key')
check(#parameters.required == 1 and parameters.required[1] == 'action', 'no_global_key_requirement')
check(not parameters.allOf and not parameters.oneOf and not parameters['if'], 'no_provider_dependent_conditional_keywords')
for _, role in ipairs({'master', 'guest'}) do
  local offered = tools.all_for({subagent = true}, role)
  check(#offered == 1 and offered[1]['function'].parameters.properties.idempotency_key.description == parameters.properties.idempotency_key.description, 'profile_help_parity_' .. role)
end
local wire = original_dofile('lua/core/subscription_wire.lua').body('gpt-6.1-sol',
  {{role = 'user', content = 'model-free serializer check'}},
  {{type = 'function', ['function'] = definition}}, {}, nil, {})
check(wire.tools[1].description == definition.description, 'responses_preserves_tool_help')
check(wire.tools[1].parameters.properties.idempotency_key.description == parameters.properties.idempotency_key.description, 'responses_preserves_property_help')

-- The real native engine owns durable continuation deduplication. This mock proves
-- facade key forwarding and pre-dispatch refusals without admitting paid children.
local real_native = host.subagent
local native_calls, continuation_calls, mock_admissions = 0, 0, 0
local forwarded, admitted = {}, {}
local owner = 'message-contract-owner'
local child_sid = memory.start_session('', 'subagent', {user_id = owner})
local main_sid = memory.start_session('', 'chat', {user_id = owner})
local receipt = {subagent_id = 'fixture-child', session_id = child_sid, profile = 'explore',
  parent_session_id = 'fixture-parent', state = 'running', settled = false}
host.subagent = function(action, raw)
  native_calls = native_calls + 1
  local args = json.decode(raw)
  if action == 'status' or action == 'result' then return json.encode(receipt) end
  if action == 'lookup_session' then return json.encode({found = false}) end
  if action == 'list' then return json.encode({subagents = {receipt}}) end
  if action == 'continue' then
    continuation_calls = continuation_calls + 1
    forwarded[#forwarded + 1] = args
    check(args.owner_user == owner and args.id == receipt.subagent_id, 'continuation_owner_and_target_preserved')
    if admitted[args.idempotency_key] then
      local copy = {}; for key, value in pairs(admitted[args.idempotency_key]) do copy[key] = value end
      copy.deduplicated = true; return json.encode(copy)
    end
    mock_admissions = mock_admissions + 1
    local value = {subagent_id = 'mock-followup-' .. mock_admissions, session_id = child_sid, state = 'accepted', settled = false}
    admitted[args.idempotency_key] = value; return json.encode(value)
  end
  error('unexpected native action: ' .. tostring(action))
end
dofile = function(name)
  if name == 'lua/core/orchestrator.lua' then return {control = function() return false end, enabled = function() return false end} end
  if name == 'lua/core/completions.lua' then return {watch = function() end, status = function() return {} end} end
  return original_dofile(name)
end
local api = original_dofile('lua/core/subagents.lua')
local ctx = {user_id = owner, role = 'master', session_id = 'fixture-parent', run_id = 'fixture-parent-run'}
for _, args in ipairs({{action = 'message', id = receipt.subagent_id, text = 'continue'},
  {action = 'message', id = receipt.subagent_id, text = 'continue', idempotency_key = ''}}) do
  check(api.control(args, ctx).error == 'idempotency_key_required', 'missing_message_key_refuses')
  check(continuation_calls == 0 and mock_admissions == 0, 'missing_message_key_dispatches_nothing')
end
local first = api.control({action = 'message', id = receipt.subagent_id, text = 'continue', idempotency_key = 'same-message'}, ctx)
local second = api.control({action = 'message', id = receipt.subagent_id, text = 'continue', idempotency_key = 'same-message'}, ctx)
check(first.subagent_id == second.subagent_id and second.deduplicated == true, 'mock_continuation_dedup_receipt_preserved')
check(continuation_calls == 2 and mock_admissions == 1, 'facade_passes_key_to_native_dedup_boundary')
check(forwarded[1].idempotency_key == 'same-message' and forwarded[2].idempotency_key == 'same-message', 'key_never_regenerated')
for _, action in ipairs({'status', 'result', 'list', 'session'}) do
  check(not api.control({action = action, id = receipt.subagent_id, limit = 1}, ctx).error, 'read_without_key_' .. action)
end
check(api.control({action = 'start', profile = 'missing-contract-fixture', prompt = 'not admitted'}, ctx).error ~= 'idempotency_key_required', 'start_without_key_not_globally_rejected')

-- Actual SQLite steering admission and deduplication; no mock inbox or live worker.
local steering = original_dofile('lua/core/steering.lua')
steering.begin(owner, child_sid, 'child-run')
steering.begin(owner, main_sid, 'main-run')
local function inbox_count()
  return json.decode(host.sql_query('SELECT COUNT(*) AS n FROM steering_inbox', '{}'))[1].n
end
for _, spec in ipairs({{action = 'steer', id = receipt.subagent_id}, {action = 'steer_session', session_id = main_sid}}) do
  local before = inbox_count()
  check(api.control(spec, ctx).error == 'idempotency_key_required', 'missing_steering_key_refuses_' .. spec.action)
  spec.idempotency_key = ''
  check(api.control(spec, ctx).error == 'idempotency_key_required', 'empty_steering_key_refuses_' .. spec.action)
  check(inbox_count() == before, 'missing_steering_key_enqueues_nothing_' .. spec.action)
  spec.idempotency_key, spec.text = 'key-' .. spec.action, 'same steering request'
  local accepted = api.control(spec, ctx)
  local repeated = api.control(spec, ctx)
  check(accepted.id ~= nil and accepted.state == 'queued', 'keyed_steering_accepted_' .. spec.action)
  check(repeated.id == accepted.id and repeated.deduplicated == true, 'real_steering_dedup_' .. spec.action)
  check(inbox_count() == before + 1, 'one_real_inbox_effect_' .. spec.action)
  spec.text = 'different request under same key'
  check(api.control(spec, ctx).error == 'idempotency_conflict', 'conflicting_steering_key_refused_' .. spec.action)
end
check(not api.control({action = 'steering_status', id = receipt.subagent_id}, ctx).error, 'steering_status_without_key')
local foreign = {user_id = 'foreign', role = 'master', session_id = 'foreign-parent'}
check(api.control({action = 'steer_session', session_id = main_sid, text = 'not allowed', idempotency_key = 'foreign'}, foreign).error == 'forbidden_steering_session', 'steering_owner_check_unchanged')
local before = native_calls
check(api.control({action = 'message', id = receipt.subagent_id, idempotency_key = 'nested', text = 'no'},
  {user_id = owner, role = 'master', subagent = {depth = 1}}).error == 'subagent_recursion_forbidden', 'child_recursion_check_unchanged')
check(native_calls == before, 'recursion_refusal_precedes_native_lookup')
host.subagent, dofile = real_native, original_dofile
print(string.format('subagent message contract ok (%d checks, 0 skipped)', checks))
