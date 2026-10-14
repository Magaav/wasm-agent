-- These are host availability checks, not code-mode guest ambient capabilities.
local json=dofile('lua/vendor/json.lua')
local info=json.decode(host.quickjs('info','{}'))
assert(info.ok and info.embedded_assets==false,'default build honestly reports assets not embedded')
local raw=json.decode(host.quickjs('start',json.encode({owner=string.rep('a',64),code='return 1;',tools={},globals={},store={}})))
assert(raw.ok==false and raw.error:find('assets unavailable',1,true),'unprepared build refuses, never Node fallback')
print(json.encode({ok=true,checks=2,paid_calls=0}))
