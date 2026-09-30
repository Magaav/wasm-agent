-- Reviewer probe 2: the route's own chain, with WASM_AGENT_LUA_ROOT *unset*.
-- Offline, no network, no spend: the store is pointed at a path that does not exist.
local function say(k, v) print(k .. ': ' .. tostring(v)) end
say('lua root (getenv)', tostring(host.getenv('WASM_AGENT_LUA_ROOT')))

local ok, sub = pcall(dofile, 'lua/core/openai_sub.lua')
say('openai_sub.lua dofile ok', ok)
if not ok then say('error', tostring(sub)) os.exit(1) end
for _, name in ipairs({ 'lua/core/openai_sub.lua', 'lua/core/subscription_wire.lua',
                        'lua/core/openai_sub_auth.lua', 'lua/core/openai_sub_catalogue.lua',
                        'lua/core/provider.lua', 'lua/vendor/json.lua' }) do
  say('  embedded sha256 ' .. name, tostring(LOADED_SOURCES[name]))
end
say('transport', tostring(sub.transport()))
say('configured() with no credential', tostring(sub.configured()))
say('limits() with no credential', tostring(next(sub.limits() or {})))
local ok2, err = pcall(sub.complete, 'gpt-6-luna', {}, nil, false, {})
say('complete() with no credential ok', ok2)
say('complete() with no credential error', tostring(err))

local ok3, provider = pcall(dofile, 'lua/core/provider.lua')
say('provider.lua dofile ok', ok3)
say('provider active id', ok3 and tostring(provider.active() and provider.active().id) or 'n/a')
os.exit(0)
