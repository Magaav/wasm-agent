-- A model-less node (docs/MODEL-LESS.md): the declaration, its precedence, the refusal it produces,
-- and the fact that makes it a refusal - a real turn on a declared node reaches neither the provider
-- nor the `local_run` fallback, which would otherwise answer from memory and look exactly like a
-- served turn. The failure this replaces: openclaw, 4-11 Nov, three turns in seven days, all empty
-- because the provider answered 401 while `provider.configured()` was still true.
--
-- Hermetic: a stubbed `host.getenv` with the real one behind it, no HTTP, no node, no network, no
-- model. Run:
--   WASM_AGENT_LUA_ROOT=<checkout> WA_SCRIPT=scripts/test-model-less.lua wa --db /tmp/x.db
local checks = 0
local function check(value, label)
  checks = checks + 1
  if not value then error('MODEL-LESS CHECK FAILED: ' .. label) end
end

-- Load every module BEFORE stubbing: the bootstrap `dofile` resolves WASM_AGENT_LUA_ROOT through the
-- same `host.getenv`, so a stub installed first sends it to the binary's embedded copy - which loads a
-- provider without this feature and reports `model_less` as nil rather than as a wrong answer.
local provider = dofile('lua/core/provider.lua')
local memory = dofile('lua/core/memory.lua')
memory.setup()
local agentlib = dofile('lua/core/agent.lua')

-- `provider.lua` reads the environment on every call, so the stub is enough. Anything the test does
-- not name stays real, so WASM_AGENT_HOME and the runner's own variables are untouched.
local native_getenv = host.getenv
local env = {}
host.getenv = function(key)
  if env[key] ~= nil then return env[key] end
  return native_getenv(key)
end
host.http = function() error('unexpected HTTP in a hermetic test') end
host.http_stream = host.http

-- 1. A node that says nothing is not model-less. The default must never be "no model": that would
--    turn every unconfigured node into one that refuses instead of falling back.
local less, source = provider.model_less()
check(less == false, 'an undeclared node is not model-less')
check(source == 'default', 'an undeclared node reports the default source, got ' .. tostring(source))

-- 2. The environment can force it, and only an explicit value counts.
env.WASM_AGENT_MODEL_LESS = '1'
less, source = provider.model_less()
check(less == true and source == 'env', 'WASM_AGENT_MODEL_LESS=1 declares it through env')
env.WASM_AGENT_MODEL_LESS = '0'
less = provider.model_less()
check(less == false, 'WASM_AGENT_MODEL_LESS=0 is an explicit no')
env.WASM_AGENT_MODEL_LESS = 'maybe'
less, source = provider.model_less()
check(less == false and source == 'default', 'a value that is neither yes nor no is not a declaration')

-- 3. The persisted declaration is the operator's decision and wins over an inherited environment -
--    a unit file left over from before the decision must not overrule the file written after it.
local set = provider.set_model_less(true)
check(set and set.ok, 'declaring model-less succeeds')
check(set.model_less == true, 'the declaration reports itself')
env.WASM_AGENT_MODEL_LESS = '0'
less, source = provider.model_less()
check(less == true, 'the persisted declaration wins over env=0')
check(source == 'state', 'the source is the state file, got ' .. tostring(source))

-- 4. The refusal is one named shape, so the transcript, the caller and /health agree.
local refusal = provider.model_less_refusal()
check(refusal.error == 'node_model_less', 'the refusal carries a named reason')
check(type(refusal.reason) == 'string' and refusal.reason ~= '', 'the refusal says why, in words')
check(refusal.detail:lower():find('no agent turn can run', 1, true) ~= nil,
  'the refusal says what cannot happen: ' .. tostring(refusal.detail))

-- 5. The refusal end to end. A real turn on a declared node must not call the provider, and must not
--    return the memory answer `local_run` produces - that answer is shaped like a model reply, which
--    is why a wake on a model-less node looked handled.
local sid = memory.start_session('', 'model-less-turn',
  { user_id = 'master', node_id = '', title = 'model-less-turn' })
local sent = 0
local native_complete = provider.complete_with
provider.complete_with = function() sent = sent + 1; error('provider called on a model-less node') end
local emitted = {}
local bot = agentlib.new(sid, function(event) emitted[#emitted + 1] = event end, 'master', 'master', '')
local reply = bot:run('does this node have a model?')
provider.complete_with = native_complete
check(sent == 0, 'the provider is never called')
check(type(reply) == 'string' and reply ~= '', 'the turn returns something, not an empty reply')
check(reply:find('model%-less') ~= nil, 'the reply names the reason, got: ' .. tostring(reply))
check(reply:find('No provider is configured', 1, true) == nil,
  'the memory fallback is not the answer, got: ' .. tostring(reply))
local saw_reply, saw_status = false, false
for _, event in ipairs(emitted) do
  if event.type == 'reply' then saw_reply = true end
  if event.type == 'status' and tostring(event.text):find('refused', 1, true) then saw_status = true end
end
check(saw_reply, 'the refusal is emitted as a reply')
check(saw_status, 'the refusal is emitted as a status')
local stored = memory.session_messages(sid, { limit = 20 })
local last = stored[#stored]
check(last and last.role == 'assistant' and tostring(last.content):find('model%-less') ~= nil,
  'the refusal is recorded in the transcript')

-- 6. Clearing is a decision too, and the node goes back to its ordinary path.
local cleared = provider.set_model_less(false)
check(cleared and cleared.ok, 'clearing succeeds')
env.WASM_AGENT_MODEL_LESS = nil
less, source = provider.model_less()
check(less == false, 'a cleared declaration is not model-less')
check(source == 'state', 'a cleared declaration is still a stated fact, got ' .. tostring(source))

host.getenv = native_getenv
print('model-less: ' .. checks .. ' checks passed')
