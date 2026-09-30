-- Reviewer probe (v3): bisect where a no-root WA_SCRIPT run reaches.
local function mark(n) print('MARK ' .. n); end
mark(1)
mark(2 .. ' root=' .. tostring(host.getenv('WASM_AGENT_LUA_ROOT')))
local ok, module = pcall(dofile, 'lua/core/openai_sub_login.lua')
mark(3 .. ' dofile ok=' .. tostring(ok) .. ' type=' .. type(module))
mark(4 .. ' sha=' .. tostring(LOADED_SOURCES['lua/core/openai_sub_login.lua']))
if ok then
  mark(5 .. ' run type=' .. type(module.run))
  local code = module.run({ '--browser' })
  mark(6 .. ' run(--browser)=' .. tostring(code) .. ' type=' .. type(code))
  local code2 = module.run({ '--code', 'http://localhost:1455/auth/callback?code=REJECT-0&state=deadbeef' })
  mark(7 .. ' run(--code, no pending flow)=' .. tostring(code2) .. ' type=' .. type(code2))
end
mark(8)
os.exit(0)
