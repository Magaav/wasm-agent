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
-- An external override or host capability alone is not embedded asset readiness.
local info=json.decode(host.quickjs('info','{}'))
assert(info.ok and info.embedded_assets and info.backend=='rust-wasmtime-quickjs-wasi','embedded native assets required')
assert(info.wasm_sha256=='d4c9375f2b1ca4dc95f72c8aa2982a7a9951ac8011490d79c6582df732b4bbd9')
assert(info.prelude_sha256=='57c8dc8c0e812117d82167fa751bc368f249d5aaee56d321066fc5280c785281')
assert(json.decode(host.quickjs('ready','{}')).ok,'embedded native checksum readiness failed')
local owner=string.rep('c',64)
local result=json.decode(host.quickjs('start',json.encode({owner=owner,tools={},globals={},store={},code='return 6*7;',timeout_ms=5000})))
assert(result.ok,'embedded native guest initialization failed')
local closed=json.decode(host.quickjs('close',json.encode({owner=owner,id=result.id})))
assert(closed.ok,'embedded native guest close failed')
local done=false;for _,event in ipairs(result.events or {})do if event.type=='done' and event.ok and event.value=='42' then done=true end end
assert(done,'embedded native guest did not execute expected result')
print('embedded native codemode ok (rust-wasmtime-quickjs-wasi; pinned assets; no external override)')
