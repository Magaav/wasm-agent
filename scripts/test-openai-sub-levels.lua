-- Which thinking levels a child may ask for on the subscription route - and which are still
-- refused, by name.
--
-- Measured, before this fixture existed: a `task-worker` child carrying `gpt-6.1-sol` was refused
-- on the destination with `reasoning_not_supported:{high,low,off}` and `not_started:true`, and the
-- conclusion drawn was "the level set for this id is empty, and a child always carries a level,
-- so nothing is acceptable". The set is not empty on this route - it is not even empty for this
-- id - and the two properties this file pins are the ones that matter:
--
--   * a level the catalogue *and* the route's shipped table both accept is admitted, so a child
--     can be placed at all: `gpt-6.1-sol` publishes `minimal` on top of the five levels every id
--     on this route has, and the gate lets a child carry them;
--   * an explicit level a route cannot honour is refused BY NAME - never silently replaced by a
--     default - and a route that genuinely has no levels for an id still refuses every level a
--     child can be given. The empty set is a *statement*, and this change must not soften it.
--
-- Hermetic: no HTTP, no credentials, no model. The catalogue is a fixture written where the real
-- one lives (`WASM_AGENT_PI_MODELS_STORE`), carrying the entry pi.dev publishes for this id
-- verbatim - including `"off":null`, which is the id saying it does not honour `off`.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')

-- One override point, because the fixture has to move the catalogue and the route under test and
-- a shared home is not this file's to change.
local native_getenv = host.getenv
local overrides = {WASM_AGENT_PROVIDER='openai-sub'}
host.getenv = function(key)
  if overrides[key] ~= nil then return overrides[key] end
  return native_getenv(key)
end

-- Written as text, not encoded from a table: lua/vendor/json.lua decodes `null` to nil
-- (`literal_map`), so a table round-trip would silently drop the `"off":null` that makes this
-- entry different from gpt-6-luna's.
local CATALOGUE = [[{"openai-codex":{"models":[
{"id":"gpt-6.1-sol","provider":"openai-codex","api":"openai-codex-responses","reasoning":true,
 "thinkingLevelMap":{"off":null,"minimal":"low","low":"low","medium":"medium","high":"high",
 "xhigh":"xhigh","max":"max"},"maxTokens":128000,
 "compat":{"supportsOpenAIGrammarTools":true,"supportsAdditionalTools":true}}
]}}
]]
local store = paths.temp() .. '/wa-openai-sub-levels-store.json'
local absent = paths.temp() .. '/wa-openai-sub-levels-absent.json'
assert(host.write_file(store, CATALOGUE), 'the catalogue fixture must be written')
overrides.WASM_AGENT_PI_MODELS_STORE = store

-- A profile with a budget of one token: it is a *later* gate than the reasoning gate, so "the
-- reasoning gate admitted this" is observable as that named refusal instead of a started child.
local profile_dir = paths.config() .. '/subagent-profiles'
assert(host.write_file(profile_dir .. '/probe.json', json.encode({schema_version=1, id='probe',
  description='fixture: stops on the gate after the reasoning gate',
  instructions='nothing', allowed_tools={}, limits={max_tokens=1, max_depth=0}})),
  'the profile fixture must be written at ' .. profile_dir)

local provider = dofile('lua/core/provider.lua')
local subagents = dofile('lua/core/subagents.lua')
-- The route is chosen through the environment, not through `provider.provider_override`: every
-- `dofile` of provider.lua is its own instance here, so a field set on this file's instance would
-- leave the child gate asking a different route than the assertions below.
overrides.WASM_AGENT_PROVIDER = 'openai-sub'

local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function placed(model, reasoning)
  return subagents.start({profile='probe', prompt='probe', model=model, reasoning=reasoning},
    {user_id='master', role='master', model=model, session_id='', placement=true})
end
local function levels_of(model)
  local set = {}
  for _, level in ipairs(provider.reasoning(model).levels or {}) do set[level] = true end
  return provider.reasoning(model), set
end

-- ---- the subscription route ---------------------------------------------------------------
local info, set = levels_of('gpt-6.1-sol')
check(info.supported == true, 'the subscription route must offer this id a level, not none')
check(info.source == 'pi-openai-codex-store',
  'the declaration must say the catalogue answered, got ' .. tostring(info.source))
check(set.minimal == true, 'the level the catalogue publishes for this id must be selectable')
check(set.low and set.medium and set.high and set.xhigh and set.max,
  'the levels this route already accepted must stay accepted')
check(info.selected == 'high', 'with six levels, a default of high: got ' .. tostring(info.selected))
check(set.off == true,
  "the shipped floor still answers for `off`: the catalogue's `off:null` cannot be told apart " ..
  'from an absent level through this decoder, so the route keeps the level it accepted before')

-- A child carries a level, and one of them has to be admitted, or no child can be placed at all.
local high = placed('gpt-6.1-sol', 'high')
check(tostring(high.error or ''):find('reasoning_', 1, true) == nil,
  'a child at high must pass the reasoning gate, got ' .. tostring(high.error))
check(tostring(high.error or ''):find('subagent_token_budget', 1, true) ~= nil,
  'and must be stopped by the gate *after* it, which is what proves it passed: ' ..
  tostring(high.error))
local minimal = placed('gpt-6.1-sol', 'minimal')
check(tostring(minimal.error or ''):find('reasoning_', 1, true) == nil,
  'the level the catalogue adds must be admissible too, got ' .. tostring(minimal.error))

-- Falsification: a level no source names is refused by name, not defaulted.
local unknown = placed('gpt-6.1-sol', 'ultra')
check(unknown.error == 'reasoning_not_approved:ultra',
  'an unlisted level is refused by name, got ' .. tostring(unknown.error))

-- ---- a route that genuinely has no levels for the id --------------------------------------
-- This is the measured case: the destination was on opencode-go (its own state file) and had no
-- pi store at all, so the protocol gate stayed silent on the id and the reasoning gate spoke.
overrides.WASM_AGENT_PI_MODELS_STORE = absent
overrides.WASM_AGENT_PROVIDER = 'opencode-go'
local silent, silent_set = levels_of('gpt-6.1-sol')
check(silent.supported == false and next(silent_set) == nil,
  'a route that cannot describe this id has no level to offer: ' .. tostring(silent.source))
for _, level in ipairs({'off','low','medium','high','xhigh','max'}) do
  local refused = placed('gpt-6.1-sol', level)
  check(refused.error == 'reasoning_not_supported:' .. level,
    'every explicit level is still refused by name on that route, got ' .. tostring(refused.error) ..
    ' for ' .. level)
end
local nothing_carried = placed('gpt-6.1-sol', 'provider')
check(tostring(nothing_carried.error or ''):find('reasoning_not_supported', 1, true) == nil,
  'a request that carries no level is not refused for one: ' .. tostring(nothing_carried.error))

-- ---- a silent catalogue is not a route with no levels -------------------------------------
-- The cloud node has no model store; a node like it must keep the route's shipped declaration
-- rather than reporting a model with no reasoning.
overrides.WASM_AGENT_PROVIDER = 'openai-sub'
local unsaid, unsaid_set = levels_of('gpt-6.1-sol')
check(unsaid.supported == true and unsaid.source == 'pi-openai-codex',
  'a machine with no clue still answers from the route, got ' .. tostring(unsaid.source))
check(unsaid_set.high == true and unsaid_set.minimal == nil,
  'and answers with the shipped set, not an invented one')

print('openai-sub levels ok (' .. checks .. ' checks)')
