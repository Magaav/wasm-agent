-- Real agent/provider boundaries with hermetic HTTP; no paid model calls.
local json=dofile('lua/vendor/json.lua')
local getenv=host.getenv
local env={WASM_AGENT_LLM_API_KEY='test-only',WASM_AGENT_PROVIDER='opencode-go',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_MAX_TOOL_ROUNDS='3',WASM_AGENT_PROVIDER_RESPONSE_RETRIES='1'}
host.getenv=function(key) if env[key]~=nil then return env[key] end return getenv(key) end
host.http=function() error('unexpected HTTP') end
local memory=dofile('lua/core/memory.lua');memory.setup()
local provider=dofile('lua/core/provider.lua')
local native_dofile=dofile
dofile=function(path) if path=='lua/core/provider.lua' then return provider end return native_dofile(path) end
local agent=native_dofile('lua/core/agent.lua');dofile=native_dofile
local checks=0
local function check(ok,label) assert(ok,label);checks=checks+1 end
local function counts(row)
  local result,n=nil,0
  for _,item in ipairs(row.trace or {}) do if item.kind=='run_counts' then result=item;n=n+1 end end
  check(n==1,'one immutable count snapshot per stored row')
  return result
end
local sid=memory.start_session('','run counts',{user_id='master'})
local events,calls={},0
host.http_stream=function()
  calls=calls+1
  if calls==1 then return json.encode({error='timeout: receive response'}) end
  if calls==2 then return json.encode({status=200,content='',stream_complete=true,finish_reason='tool_calls',
    tool_calls={{id='bad-edit',type='function',['function']={name='edit',arguments='{broken json'}}}}) end
  return json.encode({status=200,content='done',stream_complete=true,finish_reason='stop',tool_calls={}})
end
local bot=agent.new(sid,function(event) events[#events+1]=event end,'master','master','')
check(bot:run('count a failed request, retry, failed tool and final answer')=='done','real agent completes')
local rows=memory.session_messages(sid,{all=true})
local final=counts(rows[#rows])
check(final.model_calls==3 and final.tool_calls==1 and final.complete,'retries are provider attempts, failed tool is a requested call')
check(final.run_id==rows[1].id and final.started_at>0 and final.elapsed_ms>=0,'count identity and timing persist')
check(counts(rows[1]).model_calls==0,'user baseline proves a new run starts at zero')
for index,event in ipairs(events) do
  if event.type=='checkpoint' then check(events[index+1].type=='run_counts','checkpoint re-emits cumulative totals for a trimmed event tail') end
end
local maximum=0
for _,event in ipairs(events) do if event.type=='run_counts' then
  check(event.counts.model_calls>=maximum,'live snapshots are monotonic');maximum=event.counts.model_calls
end end
check(maximum==3,'live model count matches durable final')
local seen=0
host.http=function() return json.encode({status=200,body=json.encode({choices={{message={content='summary'},finish_reason='stop'}}})}) end
provider.complete_with('deepseek-v4.1-flash',{{role='user',content='summarize'}},nil,false,
  {session_id=sid,run_id=final.run_id,kind='summary',on_call_start=function(kind) seen=seen+1;check(kind=='summary','summary uses same boundary') end})
check(seen==1,'summary attempt counted once')
local unservable=provider.unservable
provider.unservable=function() return 'fixture_pre_request_refusal' end
local refused=pcall(provider.complete_with,'deepseek-v4.1-flash',{{role='user',content='refuse'}},nil,false,
  {on_call_start=function() seen=seen+1 end})
provider.unservable=unservable
check(not refused and seen==1,'pre-request model refusal never increments')
-- A fresh run must not inherit the previous run totals.
host.http_stream=function() return json.encode({status=200,content='next',stream_complete=true,finish_reason='stop',tool_calls={}}) end
check(bot:run('next turn')=='next','second run completes')
local next_counts=counts(memory.session_messages(sid,{limit=1})[1])
check(next_counts.model_calls==1 and next_counts.tool_calls==0 and next_counts.run_id~=final.run_id,'per-run reset')
print('run counts ok ('..checks..' checks, 0 skipped; no paid model calls)')
