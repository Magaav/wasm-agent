-- Actual native parser/provider/agent with deterministic disconnects; only effects mocked.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local getenv=host.getenv
local env={WASM_AGENT_PROVIDER='openai-sub',WASM_AGENT_LLM_MODEL='gpt-6.1-sol',
  WASM_AGENT_SUBSCRIPTION_TRANSPORT='native',WASM_AGENT_CONTEXT_BUDGET='0',
  WASM_AGENT_PROVIDER_RETRIES='0',WASM_AGENT_SUBSCRIPTION_TRANSPORT_RETRIES='2',
  WASM_AGENT_OPENAI_SUB_STORE=paths.data()..'/disconnect-fixture/credentials.json'}
host.getenv=function(k) if env[k]~=nil then return env[k] end return getenv(k) end
assert(host.write_file(env.WASM_AGENT_OPENAI_SUB_STORE,json.encode({version=1,provider='openai-codex',
  type='oauth',access='fixture',refresh='fixture',expires=host.now()*1000+3600000,account_id='fixture'})))
host.http=function() error('unexpected network') end
host.operation=function() error('unexpected process/effect') end
local clock=0
host.monotonic_ms=function() return clock end
host.sleep=function(ms) clock=clock+ms end
host.run_cancelled=function() return json.encode({cancelled=false}) end
local memory=dofile('lua/core/memory.lua');memory.setup()
local provider=dofile('lua/core/provider.lua')
local tools=dofile('lua/core/tools.lua')
local original=dofile
dofile=function(p)
  if p=='lua/core/provider.lua' then return provider end
  if p=='lua/core/tools.lua' then return tools end
  return original(p)
end
local agent=original('lua/core/agent.lua');dofile=original
local wire=dofile('lua/core/subscription_wire.lua')
local checks=0;local function check(v,label) assert(v,label);checks=checks+1 end
local function sender(line) return function(e) line('data: '..json.encode(e));line('') end end
local function finish(send)
  send({type='response.completed',response={id='response',status='completed',
    usage={input_tokens=1000,output_tokens=20,total_tokens=1020}}})
end
local function text(send,value,phase)
  local item={type='message',id='msg',phase=phase or 'final_answer'}
  send({type='response.output_item.added',output_index=0,item=item})
  send({type='response.output_text.delta',output_index=0,delta=value})
  item.content={{type='output_text',text=value}}
  send({type='response.output_item.done',output_index=0,item=item})
end
local function partial(send,mode)
  send({type='response.created',response={id='interrupted'}})
  if mode=='reasoning' then
    send({type='response.output_item.added',output_index=0,item={type='reasoning',id='rs'}})
    send({type='response.reasoning_summary_text.delta',output_index=0,delta='discarded thinking'})
  elseif mode=='commentary' or mode=='final' then
    text(send,'discarded text',mode=='final' and 'final_answer' or 'commentary')
  elseif mode=='tool' or mode=='completed-tool' then
    local item={type='function_call',id='fc-abandoned',call_id='abandoned',name='write',arguments='{"path":"abandoned","content":"never"}'}
    send({type='response.output_item.added',output_index=0,item=item})
    if mode=='tool' then
      send({type='response.function_call_arguments.delta',output_index=0,delta='{"path":'})
    else send({type='response.output_item.done',output_index=0,item=item}) end
  elseif mode=='unknown' then send({type='response.unknown_effect',value='not replayable'}) end
end
for _,mode in ipairs({'initial','reasoning','commentary','final','tool','completed-tool','eof'}) do
  local sid=memory.start_session('','disconnect '..mode,{user_id='master'})
  local events,calls,effects={},0,0
  host.stream=function(raw) events[#events+1]=json.decode(raw) end
  tools.dispatch=function(_,name,args)
    check(name=='write' and args.path=='prior','only prior committed effect dispatched')
    effects=effects+1;return {ok=true,labelled_mock_effect=true}
  end
  host.http_sse=function(_,_,_,body,line,deadline)
    calls=calls+1;local send=sender(line);local request=json.decode(body)
    if calls==1 then
      local item={type='function_call',id='fc-prior',call_id='prior',name='write',arguments='{"path":"prior","content":"once"}'}
      send({type='response.output_item.added',output_index=0,item=item})
      send({type='response.output_item.done',output_index=0,item=item});finish(send)
    elseif calls==2 then
      partial(send,mode)
      return json.encode(mode=='eof' and {status=200,termination='eof',lines=9} or
        {status=200,termination='read_failed',error='Peer disconnected',lines=9})
    else
      check(effects==1,'reconnect preserves earlier effect exactly once')
      local prior=0
      for _,item in ipairs(request.input) do
        if item.type=='function_call' then check(item.name=='write' and item.call_id=='prior','abandoned tool not in regenerated request');prior=prior+1 end
      end
      check(prior==1,'same completed prior context retained')
      check(deadline<=3600,'retry retains original deadline')
      text(send,'Recovered without replay.');finish(send)
    end
    return json.encode({status=200,termination='eof',lines=12})
  end
  local bot=agent.new(sid,function(e)events[#events+1]=e end,'master','master','')
  check(bot:run('complete the task')=='Recovered without replay.','native agent recovered '..mode)
  check(calls==3 and effects==1,'one reconnect and no duplicate effect '..mode)
  local interrupted,recovered=0,0
  for _,e in ipairs(events) do
    if e.type=='retry' and e.state=='interrupted' then interrupted=interrupted+1 end
    if e.type=='retry' and e.state=='recovered' then recovered=recovered+1 end
    check(e.type~='error','no terminal error after successful recovery')
  end
  check(interrupted==1 and recovered==1,'visible recovery lifecycle')
  local retained=false
  for _,row in ipairs(memory.session_messages(sid,{all=true})) do
    if row.role=='retry' then
      local e=json.decode(row.content)
      if e.discarded_attempt then retained=true;check(e.discarded_attempt.tools_executed==0,'uncommitted attempt never executed tools') end
    end
    for _,call in ipairs(row.tool_calls or {}) do check(call.id~='abandoned|fc-abandoned','abandoned tool never committed') end
  end
  check(retained,'abandoned attempt durably retained')
end
-- Negative boundaries: bounded outages, explicit opt-out, unknown/malformed/provider errors,
-- cancellation and the original deadline. None can authorize a tool replay.
for _,mode in ipairs({'exhausted','disabled','unknown','malformed','provider','cancel','deadline'}) do
  local sid=memory.start_session('','negative '..mode,{user_id='master'})
  local calls=0;env.WASM_AGENT_SUBSCRIPTION_TRANSPORT_RETRIES=mode=='disabled' and '0' or '2'
  host.run_cancelled=function() return json.encode({cancelled=mode=='cancel' and calls>0}) end
  host.http_sse=function(_,_,_,_,line)
    calls=calls+1;local send=sender(line)
    if mode=='unknown' then partial(send,mode)
    elseif mode=='malformed' then line('data: not JSON');line('')
    elseif mode=='provider' then send({type='error',error={code='invalid_api_key',message='rejected'}}) end
    return json.encode({status=200,termination='read_failed',error='Peer disconnected',lines=9})
  end
  local ok,problem=pcall(wire.complete,'gpt-6.1-sol',{{role='user',content='fixture'}},{},true,
    {session_id=sid,timeout_seconds=mode=='deadline' and 1 or 30},'low')
  check(not ok,'negative boundary fails visibly '..mode)
  check(calls==(mode=='exhausted' and 3 or mode=='deadline' and 2 or 1),'bounded attempt count '..mode)
  if mode=='exhausted' then check(tostring(problem):find('subscription_retry_exhausted',1,true),'exhaustion prevents outer replay') end
  if mode=='cancel' then check(tostring(problem)=='run_cancelled','cancellation stops reconnect') end
  if mode=='deadline' then check(tostring(problem):find('subscription_timeout:',1,true),'original deadline bounds recovery') end
end
print('native disconnect recovery ok ('..checks..' checks)')
