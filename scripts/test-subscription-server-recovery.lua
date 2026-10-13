-- Native streamed provider failures, including the real callback-error wrapper.
-- Private DB, fake wire and labelled mocked effects; no network or paid calls.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local real_getenv=host.getenv
local retries,clock,cancel,sleep_hook=2,0,false,nil
local env={WASM_AGENT_PROVIDER='openai-sub',WASM_AGENT_LLM_MODEL='gpt-6.1-sol',
  WASM_AGENT_SUBSCRIPTION_TRANSPORT='',WASM_AGENT_SUBSCRIPTION_TIMEOUT='30',
  WASM_AGENT_PROVIDER_RETRIES='0',WASM_AGENT_PROVIDER_TRANSIENT_RETRIES='0',
  WASM_AGENT_MAX_TOOL_ROUNDS='4',WASM_AGENT_CONTEXT_BUDGET='0',
  WASM_AGENT_OPENAI_SUB_STORE=paths.data()..'/server-fixture/credentials.json'}
host.getenv=function(k)
  if k=='WASM_AGENT_SUBSCRIPTION_TRANSPORT_RETRIES' then return tostring(retries) end
  if env[k]~=nil then return env[k] end
  return real_getenv(k)
end
assert(host.write_file(env.WASM_AGENT_OPENAI_SUB_STORE,json.encode({version=1,
  provider='openai-codex',type='oauth',access='private-fixture',refresh='private-fixture',
  expires=host.now()*1000+3600000,account_id='fixture-account'})))
host.monotonic_ms=function()return clock end
host.sleep=function(ms)clock=clock+ms;if sleep_hook then sleep_hook() end end
host.run_cancelled=function()return json.encode({cancelled=cancel})end
host.http=function()error('real network forbidden')end
local memory=dofile('lua/core/memory.lua');memory.setup()
local provider=dofile('lua/core/provider.lua')
local adapter=dofile('lua/core/openai_sub.lua')
local tools=dofile('lua/core/tools.lua')
local original=dofile
dofile=function(p)
  if p=='lua/core/provider.lua' then return provider end
  if p=='lua/core/tools.lua' then return tools end
  return original(p)
end
local agent=original('lua/core/agent.lua');dofile=original
local checks=0
local function check(v,label)assert(v,label);checks=checks+1 end
local events,attempts={},0
host.stream=function(raw)events[#events+1]=json.decode(raw)end
local function send(line,event)line('data: '..json.encode(event));line('')end
local function text(line,value)
  send(line,{type='response.output_item.added',output_index=0,
    item={type='message',id='text-'..attempts,phase='final_answer'}})
  send(line,{type='response.output_text.delta',output_index=0,delta=value})
end
local function tool(line,id,path)
  local item={type='function_call',id=id,call_id=id,name='write',
    arguments=json.encode({path=path,content='once'})}
  send(line,{type='response.output_item.added',output_index=1,item=item})
  send(line,{type='response.output_item.done',output_index=1,item=item})
end
local function complete(line)
  send(line,{type='response.completed',response={id='response-'..attempts,status='completed',
    usage={input_tokens=100,output_tokens=10,total_tokens=110}}})
end
local function failed(line,shape,code)
  if shape=='response.failed' then
    send(line,{type=shape,response={id='failed-response',error={code=code,message='fixture failure'}}})
  else
    local e={type='error',request_id='fixture-request'}
    if shape=='nested' then e.error={code=code,message='fixture failure'}
    else e.code=code;e.message='fixture failure' end
    send(line,e)
  end
end
local function transport(run)
  host.http_sse=function(_,_,_,_,line)
    attempts=attempts+1
    local ok,result=pcall(run,line,attempts)
    if not ok then return json.encode({status=200,termination='line_callback_failed',
      error='local/parser.lua:999: '..tostring(result),lines=15}) end
    return json.encode(result or {status=200,termination='eof',lines=15})
  end
end
local function reset()attempts=0;events={};clock=0;cancel=false;sleep_hook=nil;retries=2 end
local function call(opts)
  return adapter.complete('gpt-6.1-sol',{{role='user',content='fixture'}},{},true,opts or {},'low')
end
for _,shape in ipairs({'flat','nested','response.failed'}) do
  reset()
  transport(function(line,n)
    if n==1 then text(line,'abandoned');tool(line,'abandoned-call','must-not-execute');failed(line,shape,'server_error')
    else text(line,'Recovered');complete(line) end
  end)
  local sid=memory.start_session('','server recovery',{user_id='master'})
  local result=call({session_id=sid,run_id='fixture'})
  check(attempts==2 and result.content=='Recovered' and #result.tool_calls==0,'transient '..shape..' regenerates only inference')
  local discarded,recovered=false,false
  for _,e in ipairs(events) do
    if e.type=='retry' and e.state=='interrupted' then
      local d=e.discarded_attempt
      discarded=d and d.tools_executed==0 and d.uncommitted_tools[1].id:find('abandoned-call',1,true) and d.texts[1].text=='abandoned'
      check(not e.reason:find('line_callback_failed',1,true),'parser error preserved without callback wrapper')
      check(e.provider_failure.code=='server_error' and e.provider_failure.request_id==
        (shape=='response.failed' and 'failed-response' or 'fixture-request'),'structured failure identity retained')
    elseif e.type=='retry' and e.state=='recovered' then recovered=true end
  end
  check(discarded and recovered,'partial output visibly discarded and recovery settled')
  local durable=0
  for _,e in ipairs(dofile('lua/core/telemetry.lua').events(sid,0,100).events) do
    if e.kind=='subscription_transport' and e.phase=='retry' then durable=durable+1 end
  end
  check(durable==4,'retry progress durable')
end
for _,code in ipairs({'authentication_error','insufficient_quota','rate_limit_exceeded',
  'context_length_exceeded','unknown','invalid_request_error'}) do
  reset();transport(function(line)failed(line,'nested',code)end)
  local ok,why=pcall(call)
  check(not ok and attempts==1 and tostring(why):find(code,1,true),'permanent/unknown error never retried: '..code)
end
reset();transport(function(line)send(line,{type='future_server_effect'});failed(line,'flat','server_error')end)
local ok,why=pcall(call)
check(not ok and attempts==1,'unknown server effects still suppress retry')
reset();transport(function(line)failed(line,'flat','server_error')end)
ok,why=pcall(call)
check(not ok and attempts==3 and tostring(why):find('subscription_retry_exhausted:',1,true),'repeated transient failure bounded')
check(events[#events].state=='exhausted','exhausted progress settles visibly')
reset();retries=0;transport(function(line)failed(line,'flat','server_error')end)
ok,why=pcall(call)
check(not ok and attempts==1 and tostring(why):find('subscription_provider_error:',1,true),'explicit retries=0 preserved')
for _,status in ipairs({500,502,503,504,401,403,429,400}) do
  reset();transport(function(line,n)
    if n==1 then return {status=status,body='fixture HTTP failure',termination='eof'} end
    text(line,'Recovered');complete(line)
  end)
  ok,why=pcall(call)
  local transient=status>=500
  check(ok==transient and attempts==(transient and 2 or 1),'HTTP status classified: '..status)
end
-- The endpoint can finish the response and then reset its HTTP stream. Older
-- hosts/fake peers ignore callback false, so validated terminals must also win
-- over a subsequent read_failed without regenerating the committed response.
for _,kind in ipairs({'text','tool'}) do
  reset();transport(function(line)
    if kind=='text' then text(line,'Completed before disconnect')
    else tool(line,'completed-call','completed-effect') end
    complete(line)
    return {status=200,termination='read_failed',error='Peer disconnected',lines=235}
  end)
  local result=call()
  check(attempts==1 and result.transport_failed_attempts==0 and
    result.termination=='response_complete','terminal '..kind..' survives teardown without replay')
  check(kind=='text' and result.content=='Completed before disconnect' or
    kind=='tool' and #result.tool_calls==1,'validated terminal result preserved')
end
reset();transport(function(line)
  send(line,{type='response.output_item.added',output_index=1,
    item={type='function_call',id='unfinished',call_id='unfinished',name='write'}})
  complete(line)
  return {status=200,termination='read_failed',error='Peer disconnected',lines=235}
end)
ok,why=pcall(call)
check(not ok and attempts==1 and tostring(why):find('subscription_tool_incomplete',1,true),
  'a terminal with unfinished tool arguments never becomes success')
reset();transport(function(line,n)
  text(line,n==1 and 'Abandoned' or 'Regenerated')
  if n==1 then
    tool(line,'uncommitted-call','must-not-execute')
    return {status=200,termination='read_failed',error='Peer disconnected',lines=235}
  end
  complete(line)
end)
local result=call()
check(attempts==2 and result.content=='Regenerated' and #result.tool_calls==0,
  'completed tool item without response terminal still regenerates')
reset();transport(function(line)
  send(line,{type='future_server_effect'})
  return {status=200,termination='read_failed',error='Peer disconnected',lines=235}
end)
local diagnostic_sid=memory.start_session('','suppressed disconnect diagnosis',{user_id='master'})
ok,why=pcall(call,{session_id=diagnostic_sid,run_id='diagnostic'})
check(not ok and attempts==1 and tostring(why):find('subscription_retry_suppressed:',1,true),
  'unknown effects retain the no-replay boundary')
local diagnosed=false
for _,e in ipairs(dofile('lua/core/telemetry.lua').events(diagnostic_sid,0,100).events) do
  if e.kind=='subscription_transport' and e.phase=='attempt' then
    local p=e.payload
    diagnosed=p.lines==235 and p.retry_safe==false and p.retryable==true and
      p.parser.terminal==false and p.parser.blocker.event=='future_server_effect'
  end
end
check(diagnosed,'durable suppression diagnostics identify the exact blocking event')
reset();transport(function(line)failed(line,'flat','internal_server_error')end)
ok,why=pcall(call)
check(not ok and attempts==3 and tostring(why):find('subscription_retry_exhausted:',1,true),'internal server error uses bounded recovery')
reset();transport(function(line)failed(line,'flat','server_error')end)
sleep_hook=function()cancel=true end
ok,why=pcall(call)
check(not ok and why=='run_cancelled' and attempts==1,'cancellation stops backoff without new attempt')
reset();transport(function(line)failed(line,'flat','server_error')end)
ok,why=pcall(call,{timeout_seconds=0.2})
check(not ok and tostring(why):find('subscription_timeout:',1,true) and attempts==1,'original deadline bounds recovery')
-- The actual agent/provider loop: earlier committed effects survive; failed
-- response tools never dispatch; regenerated tools dispatch once.
reset();local effects,seen=0,{}
tools.dispatch=function(_,name,args)
  check(name=='write' and args.path~='must-not-execute' and not seen[args.path],'effect dispatched once')
  seen[args.path]=true;effects=effects+1
  return {ok=true,labelled_mock_effect=true}
end
transport(function(line,n)
  if n==1 then tool(line,'prior-call','prior-effect');complete(line)
  elseif n==2 then
    check(effects==1,'earlier round already committed')
    text(line,'abandoned');tool(line,'abandoned-call','must-not-execute');failed(line,'nested','server_error')
  elseif n==3 then tool(line,'regenerated-call','regenerated-effect');complete(line)
  else check(effects==2,'earlier tools preserved without replay');text(line,'Finished');complete(line) end
end)
local sid=memory.start_session('','actual server recovery loop',{user_id='master'})
local bot=agent.new(sid,function(e)events[#events+1]=e end,'master','master','')
check(bot:run('prior effect then streamed server error')=='Finished','actual agent completes after server error')
check(attempts==4 and effects==2 and seen['prior-effect'] and seen['regenerated-effect'],'no failed or earlier tool replay')
for _,row in ipairs(memory.session_messages(sid,{all=true})) do
  for _,c in ipairs(row.tool_calls or {}) do check(not c.id:find('abandoned-call',1,true),'failed call excluded from durable dialogue') end
end
-- Exhaustion through the actual agent must report failure, never an empty success.
reset();transport(function(line)failed(line,'flat','server_error')end)
local failed_sid=memory.start_session('','exhausted server loop',{user_id='master'})
local failed_bot=agent.new(failed_sid,function(e)events[#events+1]=e end,'master','master','')
ok,why=pcall(function()return failed_bot:run('repeated server failure')end)
check(not ok and attempts==3 and tostring(why):find('subscription_retry_exhausted:',1,true),'actual agent fails visibly after bounded recovery')
-- A previous tool round and a terminal-then-disconnected tool round each execute
-- exactly once; the completed final answer survives the same socket teardown.
reset();effects=0;seen={}
transport(function(line,n)
  if n==1 then tool(line,'first-call','first-effect');complete(line)
  elseif n==2 then tool(line,'second-call','second-effect');complete(line)
  else check(effects==2,'terminal disconnect caused no duplicate effect');text(line,'Finished after teardown');complete(line) end
  return {status=200,termination='read_failed',error='Peer disconnected',lines=235}
end)
local terminal_sid=memory.start_session('','terminal disconnect agent loop',{user_id='master'})
local terminal_bot=agent.new(terminal_sid,function(e)events[#events+1]=e end,'master','master','')
check(terminal_bot:run('completed response then socket reset')=='Finished after teardown',
  'actual provider/agent loop survives terminal teardown')
check(attempts==3 and effects==2 and seen['first-effect'] and seen['second-effect'],
  'terminal tool results dispatch once with no inference retry')
print('subscription server recovery ok ('..checks..' checks, 0 skipped; no network or paid calls)')
