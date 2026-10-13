-- Strict nonsemantic heartbeat envelopes; private process, no provider calls.
local wire=dofile('lua/core/subscription_wire.lua')
local checks=0
local function check(v,label)assert(v,label);checks=checks+1 end
local function session()
 local events={}
 return wire.session({stream_id='heartbeat-fixture',emit=function(e)events[#events+1]=e end}),events
end
for _,payload in ipairs({'{}','{"type":"keepalive"}','{"sequence_number":0}',
 ' {"type":"keepalive","sequence_number":36}'}) do
 local s,events=session();s.event('keepalive',payload)
 local safe,discarded,_,p=s.recovery()
 check(safe and p.last_event=='keepalive' and not p.recovery_unsafe and not p.blocker,
  'known keepalive remains inference-only and retry-safe')
 check(not s.terminal(),'heartbeat cannot settle a response')
 check(#events==0 and discarded.tools_executed==0 and #discarded.uncommitted_tools==0,
  'heartbeat emits no model output or tool effects')
end
for _,payload in ipairs({'[]','{"type":false}','{"type":"keepalive","sequence_number":-1}',
 '{"type":"keepalive","sequence_number":0.5}','{"type":"keepalive","sequence_number":"1"}',
 '{"type":"keepalive","sequence_number":1e999}',
 '{"type":"keepalive","delta":"hidden output"}',
 '{"type":"keepalive","item":{"type":"function_call"}}',
 '{"type":"keepalive","response":{"status":"completed"}}',
 '{"type":"keepalive","future_effect":true}'}) do
 local s=session();s.event('keepalive',payload)
 local safe,_,_,p=s.recovery()
 check(not safe and p.blocker.reason=='invalid_keepalive' and p.blocker.event=='keepalive',
  'invalid or semantic heartbeat payload refuses recovery')
end
local s=session();s.event('', '{"type":"future_server_effect"}');s.event('', '{"type":"keepalive"}')
local safe,_,_,p=s.recovery()
check(not safe and p.blocker.event=='future_server_effect','heartbeat never clears a previous unknown-effect blocker')
s=session();s.event('', '{"type":"keepalive"}');s.event('', '{"type":"future_server_effect"}')
check(not s.recovery(),'a later unknown effect remains unsafe')
s=session();s.line(': keepalive');s.line('')
safe,_,_,p=s.recovery();check(safe and p.events==0,'SSE comments remain nonsemantic')
s=session();s.line('event: keepalive');s.line('data: {}');s.line('')
check(s.recovery(),'named JSON heartbeat works through real SSE framing')
s=session();local ok,why=pcall(s.event,'keepalive','not-json')
check(not ok and tostring(why):find('subscription_event_unparseable',1,true),'malformed heartbeat is not swallowed')
s=session();s.event('', '{"type":"keepalive"}')
s.event('', '{"type":"response.completed","response":{"id":"finished","status":"completed"}}')
check(s.terminal() and not s.recovery(),'real response terminal still commits without retry')
local result=s.result('fixture');check(result.content=='' and #result.tool_calls==0,'heartbeat cannot become answer content')
print('subscription keepalive ok ('..checks..' checks, 0 skipped; no network or paid calls)')
