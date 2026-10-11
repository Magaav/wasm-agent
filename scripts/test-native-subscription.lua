-- Native default through actual provider/agent, with Pi/Node reads and launches forbidden.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local real_getenv,read=host.getenv,host.read_file
local env={WASM_AGENT_PROVIDER='openai-sub',WASM_AGENT_LLM_MODEL='gpt-6.1-sol',
 WASM_AGENT_SUBSCRIPTION_TRANSPORT='',WASM_AGENT_SUBSCRIPTION_TIMEOUT='30',WASM_AGENT_MAX_TOOL_ROUNDS='4',
 WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_PROVIDER_RETRIES='0',WASM_AGENT_PROVIDER_TRANSIENT_RETRIES='0',
 WASM_AGENT_OPENAI_SUB_STORE=paths.data()..'/native-fixture/credentials.json'}
host.getenv=function(k)if env[k]~=nil then return env[k]end return real_getenv(k)end
assert(host.write_file(env.WASM_AGENT_OPENAI_SUB_STORE,json.encode({version=1,provider='openai-codex',type='oauth',access='private-fixture',refresh='private-fixture',expires=host.now()*1000+3600000,account_id='fixture-account'})))
host.read_file=function(p)assert(not tostring(p):gsub('\\','/'):find('/.pi/',1,true),'Pi files forbidden: '..p);return read(p)end
host.operation=function()error('Node/bridge operation forbidden')end
host.http=function(method,url)
 if url:find('/wham/usage',1,true)then return json.encode({status=200,body=json.encode({rate_limit={primary_window={used_percent=23,limit_window_seconds=18000,reset_at=2000000000}}})})end
 error('unexpected network '..url)
end
local memory=dofile('lua/core/memory.lua');memory.setup()
local provider=dofile('lua/core/provider.lua')
local adapter=dofile('lua/core/openai_sub.lua')
local original=dofile;dofile=function(p)if p=='lua/core/provider.lua'then return provider end return original(p)end
local agent=original('lua/core/agent.lua');dofile=original
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
check(adapter.transport()=='native','native default no environment flag')
check(adapter.configured(),'native credential configures without Pi')
check(provider.serves('gpt-6.1-sol')==true,'native owned catalogue serves chosen model')
check(provider.serves('missing-model')==false,'unknown native model refused loudly')
check(provider.budget('gpt-5.3-codex-spark').context==128000 and provider.budget('gpt-6.1-sol').context==272000,'owned per-model windows without Pi store')
local limits=adapter.limits();check(limits.rolling.percent==23,'native limits use native auth')
local requests,round,events={},0,{}
host.stream=function(raw)events[#events+1]=json.decode(raw)end
local function wire(item,phase,tool,incomplete)
 return function(method,url,headers,body,line)
  check(method=='POST'and url:find('/codex/responses',1,true),'native endpoint directly')
  local request=json.decode(body);requests[#requests+1]=request;local h=json.decode(headers)
  check(h['chatgpt-account-id']=='fixture-account'and h.Authorization=='Bearer private-fixture','native credential seam used')
  local function send(e)line('data: '..json.encode(e));line('')end
  send({type='response.created',response={id='fixture-response-'..round}})
  send({type='response.output_item.added',output_index=0,item={id='reasoning-'..round,type='reasoning'}})
  send({type='response.reasoning_summary_text.delta',output_index=0,delta='typed thinking'})
  send({type='response.output_item.done',output_index=0,item={id='reasoning-'..round,type='reasoning',summary={{type='summary_text',text='typed thinking'}},encrypted_content=string.rep('opaque',20000)}})
  send({type='response.output_item.added',output_index=1,item={type='message',id='text-'..round,phase=phase}})
  send({type='response.output_text.delta',output_index=1,delta=item})
  if incomplete=='truncated'then return json.encode({status=200,termination='eof',lines=8})end
  send({type='response.output_item.done',output_index=1,item={type='message',id='text-'..round,phase=phase or 'commentary',content={{type='output_text',text=item}}}})
  if tool then
   local call={type='function_call',id='fc-native',call_id='call-native',name='read',arguments=json.encode({path='DESIGN.md',limit=1})}
   send({type='response.output_item.added',output_index=2,item=call})
   if incomplete~='tool'then send({type='response.output_item.done',output_index=2,item=call})end
  end
  send({type='response.completed',response={id='fixture-response-'..round,status='completed',usage={input_tokens=1000+round*10,output_tokens=20,total_tokens=1020+round*10,input_tokens_details={cached_tokens=900}}}})
  return json.encode({status=200,termination='eof',lines=10})
 end
end
host.http_sse=function(...)
 round=round+1
 if round==1 then return wire('Checking now','commentary',true)(...)end
 return wire('Finished natively.','final_answer',false)(...)
end
local sid=memory.start_session('','native route fixture',{user_id='master'})
local bot=agent.new(sid,function(e)events[#events+1]=e end,'master','master','')
check(bot:run('Inspect the design')=='Finished natively.','actual two-round native provider/agent runs')
check(round==2,'one read tool then one final response, no bridge')
check(requests[1].store==false and requests[1].stream==true and #requests[1].tools>0,'native body contains real tools and stateless stream')
local replayed=false;for _,i in ipairs(requests[2].input)do if i.type=='reasoning'and i.encrypted_content then replayed=true end end
check(replayed,'encrypted reasoning retained across live rounds even beyond64KiB metadata observer budget')
local firstText,commentary,reasoning=0,0,0
for _,e in ipairs(events)do
 if e.type=='commentary_delta'then commentary=commentary+1;firstText=firstText==0 and 1 or firstText end
 if e.type=='pending_delta'then firstText=firstText==0 and 2 or firstText end
 if e.type=='reasoning'then reasoning=reasoning+1 end
end
check(firstText==1 and commentary==1 and reasoning>=2,'known early phase starts directly in commentary; typed thinking direct too')
local final=memory.session_messages(sid,{limit=1})[1];local counts
for _,s in ipairs(final.trace or {})do if s.kind=='run_counts'then counts=s end end
check(counts and counts.model_calls==2 and counts.tool_calls==1 and counts.context_growth.complete,'existing run telemetry preserved')
local snapshot=dofile('lua/core/telemetry.lua').events(sid,0,200)
local ownRequest=false;for _,e in ipairs(snapshot.events or {})do if e.kind=='model_call'and e.phase=='start'and e.payload.transport=='native-codex-responses'then ownRequest=true end end
check(ownRequest,'durable runtime provenance says native parser')
-- The provider can omit early phase. Unknown is provisional, never guessed.
events={};host.http_sse=wire('Late commentary',nil,false)
local late=adapter.complete('gpt-6.1-sol',{{role='user',content='fixture'}},nil,true,{},'low')
check(events[2]and #late.commentary==1,'late phase still resolves commentary')
local pending=false;for _,e in ipairs(events)do if e.type=='pending_delta'then pending=true end end
check(pending and late.phase_observation.missing_at_added==1,'missing phase measured honestly without inference')
host.http_sse=wire('partial','commentary',false,'truncated')
local ok,errorText=pcall(adapter.complete,'gpt-6.1-sol',{{role='user',content='fixture'}},nil,true,{},'low')
check(not ok and tostring(errorText):find('subscription_stream_truncated',1,true),'partial stream never returns tools or success')
host.http_sse=wire('partial','commentary',true,'tool')
ok,errorText=pcall(adapter.complete,'gpt-6.1-sol',{{role='user',content='fixture'}},nil,true,{},'low')
check(not ok and tostring(errorText):find('subscription_tool_incomplete',1,true),'terminal with unfinished tool cannot dispatch it')
local unmeasured=adapter.wire().session({})
unmeasured.event('',json.encode({type='response.completed',response={status='completed',usage={}}}))
local noUsage=unmeasured.result('gpt-6.1-sol')
check(not dofile('lua/core/telemetry.lua').normalize(noUsage.usage).known,'missing provider usage never fabricated as exact zero')
print('native subscription default ok ('..checks..' checks, 0 skipped; Pi/Node forbidden, no paid inference)')
