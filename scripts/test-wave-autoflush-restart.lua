-- New process, same private DB: retained unknown queue must not be replayed.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local fixture=json.decode(assert(host.read_file(host.getenv('WA_WAVE_RESTART'))))
host.subagent=function(action)assert(action=='list');return json.encode({subagents=fixture.views}) end
local native=dofile;local calls=0
dofile=function(p)
 if p=='lua/core/update.lua' then local u=native(p);u.request_bound=function()calls=calls+1;error('forbidden replay')end;return u end
 return native(p)
end
local ctx={session_id=fixture.parent,user_id=fixture.user_id,role=fixture.role,run_id='restart-fixture'}
local wave=native('lua/core/wave_autoflush.lua')
local result=wave.finalize(ctx)
assert(result and result.held and calls==0,'new process cannot replay ambiguous queue')
local s=wave.control({action='status'},ctx)
assert(s.ok and s.wave.inflight and s.wave.requests[1].state=='reserved','original reservation survives process restart')
print(json.encode({ok=true,checks=2,queue_calls=0,live_installation=false}))
