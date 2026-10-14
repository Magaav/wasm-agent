-- Hermetic measured-prefix compaction proof. Scratch DB/home only; no provider calls.
local json=dofile('lua/vendor/json.lua')
local getenv=host.getenv
host.getenv=function(k)
  if k=='WASM_AGENT_PROVIDER' then return 'opencode-go' end
  if k=='WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
  if k=='WASM_AGENT_LLM_API_KEY' then return 'hermetic-fixture' end
  if k=='WASM_AGENT_CONTEXT_BUDGET' then return '0' end
  if k=='WASM_AGENT_MODEL_LIMITS' then return '{"deepseek-v4.1-flash":{"context":1050000,"reserve":84000}}' end
  return getenv(k)
end
host.http=function() error('no network permitted') end;host.http_stream=host.http
local memory=dofile('lua/core/memory.lua');memory.setup()
local agent=dofile('lua/core/agent.lua')
local meter=dofile('lua/core/context_usage.lua')
local telemetry=dofile('lua/core/telemetry.lua')
local provider=dofile('lua/core/provider.lua')
local route=meter.route(provider)
local remember=meter.remember
meter.remember=function(b,m,t,u) return remember(b,m,t,u,route) end
local checks=0
local function check(ok,name)assert(ok,name);checks=checks+1 end
local sid='measured-context-proof';if not memory.session(sid) then memory.start_session('','proof',{id=sid,user_id='master'}) end
local bot=agent.new(sid,function()end,'master','master','');bot.model='deepseek-v4.1-flash'
local messages={{role='system',content='stable rules'},{role='user',content='keep all raw evidence'},
  {role='assistant',content='prior work',reasoning_items={{type='reasoning',encrypted_content=string.rep('x',3900000)}}}}
local tools={{type='function',['function']={name='read_many',parameters={type='object'}}}}
bot.tool_list=tools
local usage={known=true,prompt=567352,output=492}
local raw=telemetry.estimate_messages(messages)+math.ceil(#json.encode(tools)/4)
check(raw>966000,'ciphertext fixture crosses old raw-byte threshold')
local phase=getenv('WA_CONTEXT_PHASE') or 'seed'
-- Restart must find prior metadata; never seed it again in that process.
if phase=='seed' then check(meter.remember(bot,messages,tools,usage),'actual scoped metadata written') end
local measured,source=bot:context_tokens(messages)
check(measured==567352 and source=='provider-plus-tail-estimate','provider count wins over inflated whole-history bytes')
check(messages[3].reasoning_items[1].encrypted_content==string.rep('x',3900000),'opaque reasoning remains complete')
local fresh=agent.new(sid,function()end,'master','master','');fresh.model=bot.model;fresh.tool_list=tools
check(fresh:context_tokens(messages)==567352,'fresh agent restores exact-prefix calibration')
messages[#messages+1]={role='assistant',content='last reply',reasoning_items={{encrypted_content=string.rep('y',1000)}}}
local suffix=telemetry.estimate_messages({messages[4]})
check(fresh:context_tokens(messages)==567352+suffix,'only unmeasured suffix is estimated, including ciphertext conservatively')
fresh.role='guest';check(fresh:context_tokens(messages)>966000 and fresh.context_measurement_reason=='measurement_scope_changed','warm cached count stays scope fenced')
fresh.role='master'
check(not fresh:maybe_compact(messages),'no summary around54% despite inflated raw JSON')
local limits=provider.budget(bot.model)
check(limits.trigger==966000 and limits.trigger/limits.context==.92,'existing actual provider policy remains92%')
local high=agent.new(sid,function()end,'master','high','');high.model=bot.model;high.tool_list=tools
check(meter.remember(high,{messages[1]},tools,{known=true,prompt=966000,output=0}),'high-water measurement')
check(high:context_tokens({messages[1]})==966000 and not high:maybe_compact({messages[1]}),'threshold equality retains original policy')
local above={messages[1],{role='user',content=string.rep('z',400)}}
check(high:context_tokens(above)>966000,'tail crosses92% threshold')
-- Missing rows mean nothing to summarize; prove the predicate without spending inference.
local fallback=agent.new(sid,function()end,'master','other','');fallback.model=bot.model;fallback.tool_list=tools
check(fallback:context_tokens(messages)>966000 and fallback.context_measurement_reason=='measurement_missing','another user cannot reuse calibration')
fallback.role='guest';check(fallback:context_tokens(messages)>966000,'another role cannot reuse calibration')
local changed=json.decode(json.encode(messages));changed[2].content='edited old request'
local changed_bot=agent.new(sid,function()end,'master','master','');changed_bot.model=bot.model;changed_bot.tool_list=tools
check(changed_bot:context_tokens(changed)>966000 and changed_bot.context_measurement_reason=='measurement_prefix_changed','middle rewrite invalidates count')
changed_bot.tool_list={};check(changed_bot:context_tokens(messages)>966000 and changed_bot.context_measurement_reason=='measurement_tools_changed','schemas fence count')
changed_bot.tool_list=tools;changed_bot.model='other-model'
check(changed_bot:context_tokens(messages)>966000 and changed_bot.context_measurement_reason=='measurement_model_changed','model fences count')
changed_bot.model=bot.model
check(changed_bot:context_tokens({messages[1]})<1000 and changed_bot.context_measurement_reason=='measurement_prefix_changed','shortening/compaction cannot retain stale measured floor')
local count=changed_bot:context_tokens(messages)
check(not meter.remember(changed_bot,messages,tools,{known=false,prompt=0,output=0}),'missing usage never creates false zero')
check(not meter.remember(changed_bot,messages,tools,{known=true,prompt=1,output=1,issue='provider_total_mismatch'}),'inconsistent usage refuses measurement')
check(not meter.remember(changed_bot,messages,tools,{known=true,prompt=math.huge,output=0}),'nonfinite usage refuses measurement')
check(changed_bot:context_tokens(messages)==count,'bad usage leaves known evidence untouched')
check(select(2,meter.estimate(changed_bot,messages,tools,'another-provider'))=='measurement_provider_changed','provider/endpoint/transport fence count')
-- Real build_context prefix and new instance, including complete role/project/schema boundary.
local real_sid=memory.start_session('','real-builder',{user_id='master'})
memory.append_turn(real_sid,{role='user',content='inspect exact files'})
local real=agent.new(real_sid,function()end,'master','master','');local context=real:build_context()
check(meter.remember(real,context,real.tool_list,{known=true,prompt=200,output=0}),'real builder anchor')
memory.append_turn(real_sid,{role='assistant',content='done'})
local rebuilt=agent.new(real_sid,function()end,'master','master','');local rebuilt_context=rebuilt:build_context()
check(rebuilt:context_tokens(rebuilt_context)==200+telemetry.estimate_messages({rebuilt_context[#rebuilt_context]}),'real transcript rebuild restores append-only count')
local meta_key='context-usage.v1:'..host.sha256(json.encode({sid,'master','master'}))
local anchor=json.decode(memory.meta_get(meta_key))
check(#memory.meta_get(meta_key)<512 and anchor.prefix and not anchor.content and not anchor.reasoning_items,'metadata holds counts/hashes, never prompt/ciphertext')
-- Actual provider serializer + agent loop must record the request, not rely on a seeded helper.
local requests=0
host.http_stream=function()
  requests=requests+1
  return json.encode({status=200,content='verified fixture reply',stream_complete=true,finish_reason='stop',tool_calls={},
    usage={prompt_tokens=9000,completion_tokens=20,total_tokens=9020}})
end
local run_sid=memory.start_session('','actual-task-loop',{user_id='master'})
local running=agent.new(run_sid,function()end,'master','master','')
check(running:run('exercise real measurement storage')=='verified fixture reply' and requests==1,'one actual mocked provider request settles')
local continued=agent.new(run_sid,function()end,'master','master','');local next_context=continued:build_context()
local next_tokens,next_source=continued:context_tokens(next_context)
check(next_source=='provider-plus-tail-estimate' and next_tokens==9000+telemetry.estimate_messages({next_context[#next_context]}),'real loop writes durable measurement for next agent turn')
-- Actual compaction at the configured threshold, including a freshly rebuilt agent.
local threshold_sid=memory.start_session('','threshold-summary',{user_id='master'})
for i=1,12 do memory.append_turn(threshold_sid,{role=i%2==1 and 'user' or 'assistant',content=string.rep('old evidence ',7000)}) end
local threshold=agent.new(threshold_sid,function()end,'master','master','')
local threshold_context=threshold:build_context()
check(meter.remember(threshold,threshold_context,threshold.tool_list,{known=true,prompt=966000,output=0}),'actual transcript calibrated at92%')
check(not threshold:maybe_compact(threshold_context),'no actual summary at threshold equality')
memory.append_turn(threshold_sid,{role='user',content='new tail crosses the trigger'})
local summary_calls=0
host.http=function(_,_,_,body)
  summary_calls=summary_calls+1
  return json.encode({status=200,body=json.encode({choices={{message={content='checkpoint preserves task',tool_calls={}},finish_reason='stop'}},
    usage={prompt_tokens=10000,completion_tokens=20,total_tokens=10020}})})
end
local at_boundary=agent.new(threshold_sid,function()end,'master','master','')
local boundary_context=at_boundary:build_context()
check(at_boundary:maybe_compact(boundary_context) and summary_calls==1,'actual agent summarizes once above92%')
local summaries=memory.session_messages(threshold_sid,{all=true});local compact
for _,row in ipairs(summaries) do if row.role=='summary' then for _,span in ipairs(row.trace) do if span.kind=='compact' then compact=span end end end end
check(compact and compact.trigger==966000 and compact.capacity==1050000 and compact.estimate_source=='provider-plus-tail-estimate' and compact.forced==false,'summary evidence records the real threshold and source')
check(at_boundary:context_tokens()<100000,'compaction cannot reuse a stale high measured floor')
local invalid=agent.new(sid,function()end,'master','invalid-meta','');invalid.tool_list=tools
memory.meta_set('context-usage.v1:'..host.sha256(json.encode({sid,'invalid-meta','master'})),'{malformed')
check(invalid:context_tokens(messages)>966000 and invalid.context_measurement_reason=='measurement_invalid','malformed persisted measurement falls back visibly')
print(json.encode({ok=true,phase=phase,checks=checks,provider_calls=0,mocked_requests=requests,mocked_summaries=summary_calls,old_raw_estimate=raw,measured=measured,trigger=limits.trigger}))
