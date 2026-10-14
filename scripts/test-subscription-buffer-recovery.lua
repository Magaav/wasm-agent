-- Native pre-stream retry-buffer recovery. Private fixtures; no paid provider calls.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local getenv=host.getenv
local retries=2
local env={WASM_AGENT_PROVIDER='openai-sub',WASM_AGENT_LLM_MODEL='gpt-6.1-sol',
 WASM_AGENT_SUBSCRIPTION_TRANSPORT='native',WASM_AGENT_CONTEXT_BUDGET='0',
 WASM_AGENT_PROVIDER_RETRIES='0',WASM_AGENT_PROVIDER_TRANSIENT_RETRIES='0',
 WASM_AGENT_MAX_TOOL_ROUNDS='8',WASM_AGENT_SUBSCRIPTION_TIMEOUT='30',
 WASM_AGENT_OPENAI_SUB_STORE=paths.data()..'/fixture/credentials.json'}
host.getenv=function(k)if k=='WASM_AGENT_SUBSCRIPTION_TRANSPORT_RETRIES' then return tostring(retries) end;if env[k]~=nil then return env[k] end;return getenv(k)end
assert(host.write_file(env.WASM_AGENT_OPENAI_SUB_STORE,json.encode({version=1,provider='openai-codex',type='oauth',access='fixture-only',refresh='fixture-only',expires=host.now()*1000+3600000,account_id='fixture'})))
host.http=function()error('no external network permitted')end
local original=dofile
local wire=dofile('lua/core/subscription_wire.lua')
local provider=dofile('lua/core/provider.lua')
local tools=dofile('lua/core/tools.lua')
dofile=function(p)if p=='lua/core/subscription_wire.lua' then return wire elseif p=='lua/core/provider.lua' then return provider elseif p=='lua/core/tools.lua' then return tools end;return original(p)end
local memory=dofile('lua/core/memory.lua');memory.setup()
local agent=dofile('lua/core/agent.lua')
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local events={};host.stream=function(raw)events[#events+1]=json.decode(raw)end
local phrase='exceeded request buffer limit while retrying upstream'
local function send(line,event)line('data: '..json.encode(event));line('')end
local function text(line,value)
 send(line,{type='response.output_item.added',output_index=0,item={type='message',id='msg',phase='final_answer'}})
 send(line,{type='response.output_text.delta',output_index=0,delta=value})
end
local function tool(line,id,path)
 local item={type='function_call',id=id,call_id=id,name='write',arguments=json.encode({path=path,content='once'})}
 send(line,{type='response.output_item.added',output_index=1,item=item});send(line,{type='response.output_item.done',output_index=1,item=item})
end
local function complete(line)send(line,{type='response.completed',response={id='fixture-response',status='completed',usage={input_tokens=100,output_tokens=10,total_tokens=110}}})end
local function call(messages,opts)return wire.complete('gpt-6.1-sol',messages or {{role='user',content='fixture'}},{},true,opts or {},'low')end
if getenv('WA_BUFFER_PHASE')=='socket' then
 wire.ENDPOINT=assert(getenv('WA_BUFFER_PEER'))..'/'..assert(getenv('WA_BUFFER_SCOPE'))..'/recover'
 local result=call({{role='user',content=string.rep('x',3624646)}})
 check(result.content=='Socket recovered' and result.transport_failed_attempts==1,'real host HTTP507 recovers before SSE without changing body')
 wire.ENDPOINT=getenv('WA_BUFFER_PEER')..'/'..getenv('WA_BUFFER_SCOPE')..'/unknown'
 local ok,why=pcall(call)
 check(not ok and tostring(why):find('subscription_retry_suppressed:',1,true),'real host unknown507 is not regenerated')
 print(json.encode({ok=true,checks=checks,phase='socket',paid_calls=0}));return
end
local clock,cancel,sleep_hook=0,false,nil
host.monotonic_ms=function()return clock end
host.sleep=function(ms)clock=clock+ms;if sleep_hook then sleep_hook()end end
host.run_cancelled=function()return json.encode({cancelled=cancel})end
local attempts,bodies=0,{}
local function reset()clock=0;cancel=false;sleep_hook=nil;attempts=0;bodies={};events={};retries=2 end
local function transport(fn)
 host.http_sse=function(_,_,_,body,line)
  attempts=attempts+1;bodies[attempts]=body
  return json.encode(fn(line,attempts) or {status=200,termination='callback_stopped',lines=8})
 end
end
for _,body in ipairs({phrase,phrase..'.',' \r\n'..phrase..'\n '})do
 reset();transport(function(line,n)if n==1 then return {status=507,body=body,termination='http_error',lines=0}end;text(line,'Recovered');complete(line)end)
 local sid=memory.start_session('','buffer recovery',{user_id='master'})
 local result=call(nil,{session_id=sid,run_id='buffer'})
 check(attempts==2 and result.content=='Recovered' and result.transport_failed_attempts==1,'known pre-stream507 regenerates inference')
 check(bodies[1]==bodies[2],'retry preserves exact request bytes, full context and cache prefix')
 local found=false
 for _,e in ipairs(dofile('lua/core/telemetry.lua').events(sid,0,100).events)do
  if e.kind=='subscription_transport' and e.phase=='attempt' then
   local p=e.payload
   found=p.status==507 and p.retry_safe==true and p.retryable==true and p.recovery_class=='upstream_retry_buffer_overflow'
   check(p.request_bytes==#bodies[1] and p.request_sha256==host.sha256(bodies[1]),'actual serialized request size/hash retained')
   check(p.response_bytes==#body and p.response_sha256==host.sha256(body),'exact error response identity retained without payload dump')
  end
 end
 check(found,'durable diagnostics prove why the exact507 is now recoverable')
 local seen=false;for _,e in ipairs(events)do if e.state=='interrupted' then seen=e.discarded_attempt.tools_executed==0 end end
 check(seen,'interrupted attempt has no executable tool result')
end
for _,body in ipairs({'Insufficient Storage','disk full','insufficient_quota',phrase..' unknown suffix','{"error":"'..phrase..'"}',''})do
 reset();transport(function()return {status=507,body=body,termination='http_error'}end)
 local ok,why=pcall(call)
 check(not ok and attempts==1 and tostring(why):find('subscription_retry_suppressed:',1,true),'unknown507 never acquires retry authority')
end
for _,status in ipairs({400,401,403,429,501,508})do
 reset();transport(function()return {status=status,body=phrase,termination='http_error'}end)
 check(not pcall(call) and attempts==1,'same text with unapproved HTTP status stays blocked')
end
for _,kind in ipairs({'text','tool','unknown','terminal'})do
 reset();transport(function(line)
  if kind=='text' then text(line,'partial')elseif kind=='tool' then tool(line,'abandoned','never')
  elseif kind=='unknown' then send(line,{type='future_server_effect'})else complete(line)end
  return {status=507,body=phrase,termination='http_error'}
 end)
 check(not pcall(call) and attempts==1,'507 cannot regenerate a nonempty/unknown/terminal parser: '..kind)
end
reset();transport(function()return {status=507,body=phrase,error='ambiguous host failure',termination='http_error'}end)
check(not pcall(call) and attempts==1,'contradictory host error remains blocked')
reset();transport(function()return {status=507,body=phrase,termination='http_error'}end)
local ok,why=pcall(call)
check(not ok and attempts==3 and tostring(why):find('subscription_retry_exhausted:',1,true),'repeated known507 stays inside existing retry budget')
check(events[#events].state=='exhausted','exhaustion is visible, not silent success')
reset();retries=0;transport(function()return {status=507,body=phrase,termination='http_error'}end)
ok,why=pcall(call);check(not ok and attempts==1 and tostring(why):find('subscription_http_507:',1,true),'explicit disabled recovery preserved')
reset();transport(function()return {status=507,body=phrase,termination='http_error'}end);sleep_hook=function()cancel=true end
ok,why=pcall(call);check(not ok and attempts==1 and why=='run_cancelled','cancellation interrupts buffer backoff')
reset();transport(function()return {status=507,body=phrase,termination='http_error'}end)
ok,why=pcall(call,nil,{timeout_seconds=.2});check(not ok and attempts==1 and tostring(why):find('subscription_timeout:',1,true),'original deadline bounds buffer recovery')
reset();transport(function(line,n)if n==1 then return {status=507,body=phrase,termination='http_error'}end;text(line,'Large request recovered');complete(line)end)
local large=call({{role='user',content=string.rep('x',3624646)}})
check(large.content=='Large request recovered' and #bodies[1]>3624646 and bodies[1]==bodies[2],'multi-megabyte context retained across exact request regeneration')
-- Actual agent loop: completed earlier effect stays committed exactly once.
reset();local effects,seen=0,{}
tools.dispatch=function(_,name,args)
 check(name=='write' and not seen[args.path],'actual mocked effect dispatches once')
 seen[args.path]=true;effects=effects+1;return {ok=true,labelled_mock_effect=true}
end
transport(function(line,n)
 if n==1 then tool(line,'prior','prior');complete(line)
 elseif n==2 then check(effects==1,'earlier round completed before507');return {status=507,body=phrase,termination='http_error',lines=0}
 elseif n==3 then check(effects==1 and bodies[2]==bodies[3],'retry preserves prior context without tool replay');tool(line,'next','next');complete(line)
 else check(effects==2,'prior and regenerated tools remain single effects');text(line,'Finished');complete(line)end
end)
local sid=memory.start_session('','actual buffer loop',{user_id='master'})
check(agent.new(sid,function()end,'master','master',''):run('prior tool then gateway buffer failure')=='Finished','actual provider/agent loop survives507')
check(attempts==4 and effects==2 and seen.prior and seen.next,'no earlier or failed-attempt tool is replayed')
print(json.encode({ok=true,checks=checks,phase='unit',paid_calls=0}));
