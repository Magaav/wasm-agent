local root=assert(host.getenv('WA_EMBEDDED_SOURCE_ROOT'))
local source=assert(host.read_file(root..'/scripts/check-embedded-runtime.lua'))
local function check() return assert(load(source,'@check-embedded-runtime.lua'))() end
local name='lua/core/orchestration_mode.lua'
local saved=assert(EMBEDDED[name])
EMBEDDED[name]=nil
local ok,err=pcall(check);assert(not ok and tostring(err):find('embedded module missing',1,true))
EMBEDDED[name]=saved..'\n-- stale'
ok,err=pcall(check);assert(not ok and tostring(err):find('stale embedded module',1,true))
EMBEDDED[name]=saved
local real_load=load
load=function(text,chunk,...) if chunk=='@'..name then return nil,'invalid Lua negative control' end return real_load(text,chunk,...) end
ok,err=pcall(check);assert(not ok and tostring(err):find('invalid Lua negative control',1,true))
load=real_load
-- The gate builds a test artifact with empty code-mode assets on purpose (test.sh: WA_CODEMODE_ALLOW_EMPTY=1).
-- It passed only where the cargo target kept assets from an earlier shipping build (29/10). An assetless
-- binary must be refused by name; a shipping one must pass the whole check.
local info=dofile('lua/vendor/json.lua').decode(host.quickjs('info','{}'))
if info.embedded_assets then check() else
  ok,err=pcall(check);assert(not ok and tostring(err):find('embedded native assets required',1,true),tostring(err))
end
print('embedded runtime regression ok (missing, stale, invalid controls)')
