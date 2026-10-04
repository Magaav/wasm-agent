-- Actual agent loop plus production Responses complete/host.stream seam; no network.
local json=dofile('lua/vendor/json.lua')
local getenv=host.getenv
host.getenv=function(k)
  if k=='WASM_AGENT_LLM_API_KEY' then return 'fixture' end
  if k=='WASM_AGENT_PROVIDER' then return 'opencode-go' end
  if k=='WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
  if k=='WASM_AGENT_PI_MODELS_STORE' then return 'missing' end
  return getenv(k)
end
host.http=function() error('network forbidden') end
host.http_stream=host.http
local memory=dofile('lua/core/memory.lua');memory.setup()
local provider=dofile('lua/core/provider.lua')
local steering=dofile('lua/core/steering.lua')
local wire=dofile('lua/core/subscription_wire.lua')
wire.credential_provider=function() return {access='fixture',account_id='fixture'} end
local original=dofile
dofile=function(p) if p=='lua/core/provider.lua' then return provider end return original(p) end
local agent=original('lua/core/agent.lua');dofile=original
local checks=0
local function check(v,label) assert(v,label);checks=checks+1 end
local all={}
for _,scenario in ipairs({'tool','steer','followup','cancel','failure','unknown','commentary'}) do
  local events={}
  local sid=memory.start_session('',scenario,{user_id='master'})
  local bot=agent.new(sid,function(e) events[#events+1]=e end,'master','master','')
  host.stream=function(bytes) events[#events+1]=json.decode(bytes) end
  local calls=0
  local drains=0
  bot.steer=function()
    drains=drains+1
    if scenario=='followup' and drains==1 then return {'followup after tools'} end
    return {}
  end
  provider.complete_with=function(_,messages,tools,stream,opts)
    calls=calls+1
    if calls==1 and (scenario=='steer' or scenario=='followup') then
      local receipt=steering.control({session_id=sid,text='continue with correction',idempotency_key=scenario},{user_id='master'})
      check(receipt.state=='queued','durable continuation queued')
    end
    host.http_sse=function(_,_,_,_,line)
      local function send(e) line('data: '..json.encode(e));line('') end
      local phase='final_answer'
      if scenario=='unknown' then phase=nil elseif scenario=='commentary' then phase='commentary' end
      send({type='response.created',response={id='response-'..scenario..calls}})
      send({type='response.output_item.added',output_index=0,item={type='message',id='message-'..scenario..calls,phase=phase}})
      send({type='response.output_text.delta',output_index=0,delta=calls==1 and 'Candidate '..scenario or 'Settled '..scenario})
      if scenario=='cancel' or scenario=='failure' then error(scenario=='cancel' and 'run_cancelled' or 'fixture_provider_failure',0) end
      send({type='response.output_item.done',output_index=0,item={type='message',id='message-'..scenario..calls,phase=phase,content={{type='output_text',text=calls==1 and 'Candidate '..scenario or 'Settled '..scenario}}}})
      if scenario=='tool' and calls==1 then
        local item={type='function_call',id='fc',call_id='call',name='read',arguments='{"path":"AGENTS.md","limit":1}'}
        send({type='response.output_item.added',output_index=1,item=item})
        send({type='response.output_item.done',output_index=1,item=item})
      end
      send({type='response.completed',response={id='response-'..scenario..calls,status='completed',usage={input_tokens=10,output_tokens=10,total_tokens=20}}})
      return json.encode({status=200,termination='completed',lines=10})
    end
    local result=wire.complete('gpt-6.1-sol',messages,tools,stream,opts,'low')
    if calls==2 and (scenario=='steer' or scenario=='followup') then
      local found=false
      for _,m in ipairs(messages) do if m.content=='continue with correction' then found=true end end
      check(found,'continuation is in actual next request')
    end
    return result
  end
  local ok,value=pcall(function() return bot:run('fixture') end)
  if scenario=='cancel' or scenario=='failure' or scenario=='commentary' then
    check(not ok,'provider failure propagates')
    for _,e in ipairs(events) do check(e.type~='reply','no manufactured reply') end
  else
    check(ok,'loop succeeds '..scenario..': '..tostring(value))
    check(calls==((scenario=='tool' or scenario=='steer' or scenario=='followup') and 2 or 1),'unchanged continuation count '..scenario)
  end
  local begins=0
  for i,e in ipairs(events) do
    if e.type=='final_answer_begin' then
      begins=begins+1
      check(events[i+1].type=='delta','production start precedes delta')
      check(e.run_id==bot.run_id and e.message_id~=nil,'production identity survives')
    end
  end
  if scenario=='unknown' or scenario=='commentary' then check(begins==0,'unknown/commentary never early') end
  all[#all+1]={scenario=scenario,events=events}
end
local out=assert(host.getenv('WA_FINAL_EVENTS'),'WA_FINAL_EVENTS required')
assert(host.write_file(out,json.encode(all)),'save production events')
print('final-answer production loop ok ('..checks..' checks, 0 skips; fake HTTP, no inference)')
