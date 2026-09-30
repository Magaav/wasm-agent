-- Reviewer probe: byte identity of the registry the no-root binary serves for the door and the seam.
-- No network.  Prints shas only.
local function say(k, v) print(k .. ': ' .. tostring(v)) end
say('lua root (getenv)', tostring(host.getenv('WASM_AGENT_LUA_ROOT')))
local wire = dofile('lua/core/subscription_wire.lua')
say('wire.CREDENTIAL_MODULE', tostring(wire.CREDENTIAL_MODULE))
pcall(dofile, wire.CREDENTIAL_MODULE)
pcall(dofile, 'lua/core/openai_sub_login.lua')
for _, name in ipairs({ 'lua/core/subscription_wire.lua', 'lua/core/openai_sub_auth.lua',
                        'lua/core/openai_sub_catalogue.lua', 'lua/core/openai_sub_login.lua' }) do
  say('LOADED_SOURCES ' .. name, tostring(LOADED_SOURCES[name]))
end
os.exit(0)
