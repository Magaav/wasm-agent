-- Actual agent + Lua bridge + supervised fake Pi transport; only tool effects are mocked.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local provider=dofile('lua/core/provider.lua')
local adapter=dofile('lua/core/openai_sub.lua')
local tools=dofile('lua/core/tools.lua')
local real_getenv=host.getenv
host.getenv=function(k)
  if k=='WASM_AGENT_PROVIDER' then return 'opencode-go' end
  if k=='WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
  if k=='WASM_AGENT_LLM_API_KEY' then return 'private-fixture' end
  if k=='WASM_AGENT_SUBSCRIPTION_TRANSPORT_RETRIES' then return '1' end
  return real_getenv(k)
end
local original=dofile
dofile=function(p)
  if p=='lua/core/provider.lua' then return provider end
  if p=='lua/core/tools.lua' then return tools end
  return original(p)
end
local agent=original('lua/core/agent.lua');dofile=original
local checks=0
local function check(v,label)assert(v,label);checks=checks+1 end
for _,mode in ipairs({'midstream-tool','midstream-completed-tool','midstream-commentary','midstream-final','midstream-result'}) do
  local sid=memory.start_session('','midstream-loop',{user_id='master'})
  local events,effects,calls={},0,0
  local bot=agent.new(sid,function(e)events[#events+1]=e end,'master','master','')
  host.stream=function(raw)events[#events+1]=json.decode(raw)end
  local actual_dispatch=tools.dispatch
  tools.dispatch=function(_,name,args)
    check(name=='write' and args.path=='fixture-effect' and args.content=='once','only complete regenerated call dispatched')
    effects=effects+1
    return {ok=true,labelled_mock_effect=true}
  end
  provider.complete_with=function(_,messages,tool_list,stream,opts)
    calls=calls+1
    if calls==1 then
      check(effects==0,'no effects before completed response')
      return adapter.complete('fixture',{{role='user',content=mode}},tool_list,stream,opts,{selected='low'})
    end
    check(effects==1,'prior effect occurs exactly once')
    local found=0
    for _,m in ipairs(messages)do
      for _,c in ipairs(m.tool_calls or {})do
        check(c.id~='unfinished-call','abandoned call excluded from next model context')
        if c.id=='completed-call' then found=found+1 end
      end
    end
    check(found==1,'one completed call in model context')
    return {content='continued in same run',reasoning='',tool_calls={},finish_reason='stop',stream_complete=true}
  end
  local ok,why=pcall(function()return bot:run(mode)end)
  tools.dispatch=actual_dispatch
  check(ok,'run survived midstream disconnect '..mode..': '..tostring(why))
  check(calls==2 and effects==1,'same run continues past one regenerated tool effect')
  local replies,discards,tool_events=0,0,0
  for _,e in ipairs(events)do
    if e.type=='reply' then replies=replies+1 end
    if e.type=='tool' then tool_events=tool_events+1 end
    if e.type=='retry' and e.state=='interrupted' then discards=discards+1 end
    check(e.type~='error','no terminal error on recovered socket failure')
  end
  check(replies==1 and discards==1 and tool_events==1,'one reply, retained interruption, one dispatched tool')
  local retained=false
  for _,row in ipairs(memory.session_messages(sid,{all=true}))do
    check(not (row.role=='assistant' and row.content=='interrupted progress'),'abandoned text never committed as completed assistant output')
    for _,call in ipairs(row.tool_calls or {})do check(call.id~='unfinished-call','abandoned tool never committed')end
    if row.role=='retry' then
      local e=json.decode(row.content)
      if e.discarded_attempt then
        check(e.discarded_attempt.reasoning=='interrupted thinking','full abandoned reasoning retained')
        retained=true
      end
    end
  end
  check(retained,'interrupted output survives transcript reload')
end
-- Already completed tools belong to earlier rounds, not to the retry attempt.
local sid=memory.start_session('','midstream-after-effect',{user_id='master'})
local events,effects,calls={},0,0
local bot=agent.new(sid,function(e)events[#events+1]=e end,'master','master','')
host.stream=function(raw)events[#events+1]=json.decode(raw)end
local actual_dispatch=tools.dispatch
local seen={}
tools.dispatch=function(_,name,args)
  check(name=='write' and not seen[args.path],'each dispatched effect occurs once')
  seen[args.path]=true;effects=effects+1;return {ok=true,labelled_mock_effect=true}
end
provider.complete_with=function(_,messages,tool_list,stream,opts)
  calls=calls+1
  if calls==1 then return {content='',tool_calls={{id='prior-call',type='function',
    ['function']={name='write',arguments='{"path":"prior-effect"}'}}},finish_reason='tool_calls',stream_complete=true}end
  if calls==2 then
    check(effects==1,'prior round completed before disconnect')
    return adapter.complete('fixture',{{role='user',content='midstream-tool'}},tool_list,stream,opts,{selected='low'})
  end
  check(effects==2 and seen['prior-effect'] and seen['fixture-effect'],'retry preserves earlier effects without replay')
  return {content='continued after prior effect',tool_calls={},finish_reason='stop',stream_complete=true}
end
local ok,why=pcall(function()return bot:run('prior effect then disconnect')end)
tools.dispatch=actual_dispatch
check(ok and calls==3 and effects==2,'completed tool is not replayed on later disconnect: '..tostring(why))
print('subscription midstream production loop ok ('..checks..' checks, 0 skips; fake Pi and labelled mocked tool effects, no paid calls)')
