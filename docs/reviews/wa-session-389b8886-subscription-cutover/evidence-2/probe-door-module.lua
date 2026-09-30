-- Reviewer probe (v2): the door module's branches that need no network, in the *no-root* shape.
-- v1 called run({}) with no arguments, which - correctly - starts a real device-code request and
-- waits; this version does not make that call.
local function say(k, v) print(k .. ': ' .. tostring(v)) end
say('lua root (getenv)', tostring(host.getenv('WASM_AGENT_LUA_ROOT')))

local ok, module = pcall(dofile, 'lua/core/openai_sub_login.lua')
say('openai_sub_login.lua loads', ok)
say('  run is function', ok and type(module.run) or 'n/a')
say('  main is function', ok and type(module.main) or 'n/a')
say('  source sha256 (LOADED_SOURCES)', tostring(LOADED_SOURCES['lua/core/openai_sub_login.lua']))
say('  dep lua/core/openai_sub_auth.lua sha256', tostring(LOADED_SOURCES['lua/core/openai_sub_auth.lua']))
say('  dep lua/vendor/json.lua sha256', tostring(LOADED_SOURCES['lua/vendor/json.lua']))

-- 1. --browser: builds the authorize URL locally, no network.  Must answer a NUMBER and 0.
local code = module.run({ '--browser' })
say('run({--browser}) returned', tostring(code) .. ' (type ' .. type(code) .. ')')

-- 2. --code with NO pending flow: must fail, not claim success, and must not touch the network.
local code2 = module.run({ '--code', 'http://localhost:1455/auth/callback?code=REJECT-0&state=deadbeef' })
say('run({--code ...}) with no pending flow returned',
  tostring(code2) .. ' (type ' .. type(code2) .. ')')

-- 3. a store that cannot be read must not look like success either
say('store in force', tostring(host.getenv('WASM_AGENT_OPENAI_SUB_STORE')))
os.exit(0)
