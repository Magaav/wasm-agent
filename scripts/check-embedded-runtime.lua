-- Run without WASM_AGENT_LUA_ROOT before installation. No inference or full gate.
assert(not host.getenv('WASM_AGENT_LUA_ROOT') or host.getenv('WASM_AGENT_LUA_ROOT')=='', 'disk Lua must be disabled')
local json=dofile('lua/vendor/json.lua')
local root=assert(host.getenv('WA_EMBEDDED_SOURCE_ROOT'), 'source root required')
local count=0
local function check(dir)
  local listing=json.decode(assert(host.list_dir(root..'/'..dir)))
  for _,entry in ipairs(listing.entries or {}) do
    local name=dir..'/'..entry.name
    if entry.kind=='dir' then check(name)
    elseif entry.kind=='file' and (name:match('%.lua$') or name:match('%.sql$')) then
      local source=assert(EMBEDDED[name], 'embedded module missing: '..name)
      assert(source==host.read_file(root..'/'..name), 'stale embedded module: '..name)
      if name:match('%.lua$') then assert(load(source,'@'..name));count=count+1 end
    end
  end
end
check('lua/core');check('lua/vendor')
assert(count>10, 'empty module scan')
assert(type(dofile('lua/core/orchestration_mode.lua').route)=='function')
print('embedded runtime ok ('..count..' Lua modules)')
