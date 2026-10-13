-- Real host.http_sse against a private localhost peer; no model or tool effects.
local json=dofile('lua/vendor/json.lua')
local wire=dofile('lua/core/subscription_wire.lua')
local base=assert(host.getenv('WA_TEST_SSE_URL'))
wire.credential_provider=function()return {access='private-fixture',account_id='fixture'}end
local checks=0
local function check(v,label)assert(v,label);checks=checks+1 end
for _,mode in ipairs({'nil','true','false','zero','error'}) do
  local seen=0
  local r=json.decode(host.http_sse('POST',base..'/direct','{}','',function()
    seen=seen+1
    if mode=='error' then error('fixture_callback_failure',0) end
    if mode=='nil' then return nil end
    if mode=='zero' then return 0 end
    return mode=='true'
  end,2))
  if mode=='error' then
    check(r.termination=='line_callback_failed' and seen==1,'callback errors stay errors')
  elseif mode=='false' then
    check(r.termination=='callback_stopped' and r.lines==1 and seen==1,'explicit false stops successfully')
  else
    check(r.termination=='eof' and r.lines==4 and seen==4,'legacy callback continues: '..mode)
  end
end
for _,tail in ipairs({'reset','held'}) do
  wire.ENDPOINT=base..'/'..tail
  local started=host.monotonic_ms()
  local result=wire.complete('gpt-6.1-sol',{{role='user',content='fixture'}},{},false,{timeout_seconds=2},'low')
  check(result.content=='Finished' and result.stream_complete==true and
    result.termination=='callback_stopped','terminal response survives '..tail)
  check(result.transport_failed_attempts==0,'no inference replay on '..tail)
  check(host.monotonic_ms()-started<1500,'no wait for HTTP teardown on '..tail)
end
wire.ENDPOINT=base..'/retry'
local regenerated=wire.complete('gpt-6.1-sol',{{role='user',content='preserve this input'}},{},false,{timeout_seconds=2},'low')
check(regenerated.content=='Finished' and regenerated.transport_failed_attempts==1,
  'real pre-terminal reset regenerates inference')
check(#regenerated.tool_calls==0,'failed socket attempt never returns its completed tool item')
print('subscription terminal socket ok ('..checks..' checks, 0 skipped; private localhost peer, no paid calls)')
