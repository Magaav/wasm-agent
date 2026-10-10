-- Hermetic real agent/provider/SQLite context growth. No network or paid inference.
local json=dofile('lua/vendor/json.lua')
local getenv=host.getenv
local env={WASM_AGENT_LLM_API_KEY='fixture',WASM_AGENT_PROVIDER='opencode-go',WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',
 WASM_AGENT_PI_MODELS_STORE='missing-fixture-store',WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_MAX_TOOL_ROUNDS='3',
 WASM_AGENT_PROVIDER_TRANSIENT_RETRIES='0',WASM_AGENT_PROVIDER_RESPONSE_RETRIES='0'}
host.getenv=function(key)if env[key]~=nil then return env[key] end return getenv(key)end
host.http=function()error('unexpected network')end
local memory=dofile('lua/core/memory.lua');memory.setup()
local telemetry=dofile('lua/core/telemetry.lua')
local provider,native=dofile('lua/core/provider.lua'),dofile
dofile=function(path)if path=='lua/core/provider.lua'then return provider end return native(path)end
local agent=native('lua/core/agent.lua');dofile=native
local checks=0
local function check(ok,label)assert(ok,label);checks=checks+1 end
local function sid(title)return memory.start_session('',title,{user_id='master'})end
local function seed(id,prompt,output,model)
 memory.append_turn(id,{role='user',content='earlier turn'})
 telemetry.event(id,'older','older-span','model_call','end',{ok=true,model=model or 'deepseek-v4.1-flash',normalized={known=true,prompt=prompt,output=output,total=prompt+output}})
end
local function usage(prompt,output,cached)return {prompt_tokens=prompt,completion_tokens=output,total_tokens=prompt+output,prompt_tokens_details={cached_tokens=cached}}end
local function last(id)
 local value
 for _,span in ipairs(memory.session_messages(id,{limit=1})[1].trace or {})do if span.kind=='run_counts'then value=span end end
 return assert(value)
end
local main=sid('600k to850k');seed(main,599900,100)
local calls,events=0,{}
host.http_stream=function()
 calls=calls+1
 if calls==1 then return json.encode({status=200,content='',stream_complete=true,finish_reason='tool_calls',
  tool_calls={{id='read-one',type='function',['function']={name='read',arguments=json.encode({path='DESIGN.md',limit=1})}}},usage=usage(620000,1000,599900)})end
 return json.encode({status=200,content='finished',stream_complete=true,finish_reason='stop',tool_calls={},usage=usage(840000,10000,619000)})
end
local bot=agent.new(main,function(e)events[#events+1]=e end,'master','master','')
check(bot:run('add context')=='finished','two-call real run finishes')
local counts,growth=last(main),last(main).context_growth
check(counts.tokens_reported==1471000,'original billed repeated/cache accounting retained separately')
check(growth.version==1 and growth.known and growth.baseline==600000 and growth.current==850000 and growth.added==250000,'600k to850k shows250k, not1.471M nor cache misses')
check(growth.complete and not growth.partial and not growth.pending,'terminal measured growth complete')
local seenFirst,seenPending=false,false
for _,e in ipairs(events)do if e.type=='run_counts'and e.counts.context_growth then
 local g=e.counts.context_growth
 if g.current==621000 then seenFirst=true;check(g.added==21000,'first endpoint adds21k once')end
 if g.pending then seenPending=true end
end end
check(seenFirst and seenPending,'live boundary snapshots and pending state available')
local baseline,source=telemetry.last_context_boundary(main,'deepseek-v4.1-flash')
check(baseline==850000 and source=='provider_boundary','restart baseline retained in original ledger')
local fresh=agent.new(main,nil,'master','master','')
host.http_stream=function()return json.encode({status=200,content='next',stream_complete=true,finish_reason='stop',tool_calls={},usage=usage(859000,1000,840000)})end
-- Callback-free agent uses nonstreaming HTTP; pin an equivalent actual provider result.
host.http=function()return json.encode({status=200,body=json.encode({choices={{message={content='next'},finish_reason='stop'}},usage=usage(859000,1000,840000)})})end
check(fresh:run('next turn')=='next','fresh interpreter-equivalent agent next turn')
check(last(main).context_growth.added==10000 and last(main).context_growth.baseline==850000,'new run uses850k baseline rather than inheriting old growth')
local cold=sid('cold cache same baseline');seed(cold,599900,100)
host.http_stream=function()return json.encode({status=200,content='cold',stream_complete=true,finish_reason='stop',tool_calls={},usage=usage(840000,10000,0)})end
local coldBot=agent.new(cold,function()end,'master','master','');check(coldBot:run('cold')=='cold','cold cache fixture')
check(last(cold).context_growth.added==250000,'cache state never selects context delta')
local empty=sid('empty context')
check(telemetry.last_context_boundary(empty,'deepseek-v4.1-flash')==0,'genuinely empty session starts at zero')
local unknown=sid('unmeasured earlier history');memory.append_turn(unknown,{role='user',content='unmeasured history'})
check(telemetry.last_context_boundary(unknown,'deepseek-v4.1-flash')==nil,'history without usage cannot pretend zero baseline')
local unknownBot=agent.new(unknown,function()end,'master','master','');unknownBot:run('unknown')
check(not last(unknown).context_growth.known and last(unknown).context_growth.added==nil,'unknown old baseline persists unknown')
local orphan=sid('assistant-only history');memory.append_turn(orphan,{role='assistant',content='retained imported history'})
check(telemetry.last_context_boundary(orphan,'deepseek-v4.1-flash')==nil,'non-user retained history is not an empty context')
local malformed=sid('invalid prior usage');seed(malformed,599900,100)
telemetry.event(malformed,'bad','bad-span','model_call','end',{model='deepseek-v4.1-flash',normalized={known=true,prompt=599900,output=100,issue='provider_total_mismatch'}})
check(telemetry.last_context_boundary(malformed,'deepseek-v4.1-flash')==nil,'inconsistent prior usage refuses a baseline')
telemetry.event(malformed,'bad','bad-span','model_call','end',{model='deepseek-v4.1-flash',normalized={known=true,prompt=-1,output=100}})
check(telemetry.last_context_boundary(malformed,'deepseek-v4.1-flash')==nil,'negative prior usage refuses a baseline')
local changed=sid('different model');seed(changed,599900,100,'foreign-model')
local changedBot=agent.new(changed,function()end,'master','master','');changedBot:run('model switch')
check(not last(changed).context_growth.known and last(changed).context_growth.source=='model_changed','model switch is not a comparable tokenizer endpoint')
local shrunk=sid('net shrink');seed(shrunk,599900,100)
host.http_stream=function()return json.encode({status=200,content='small',stream_complete=true,finish_reason='stop',tool_calls={},usage=usage(190000,10000,0)})end
local shrinkBot=agent.new(shrunk,function()end,'master','master','');shrinkBot:run('shrink')
check(last(shrunk).context_growth.added==-400000,'net shrink remains signed, never clamped or summed')
local failed=sid('failed usage');seed(failed,599900,100)
host.http_stream=function()return json.encode({error='fixture permanent provider failure'})end
local failedBot=agent.new(failed,function()end,'master','master','')
check(not pcall(function()failedBot:run('fail')end),'real provider failure retained')
check(last(failed).context_growth.partial and last(failed).context_growth.added==0,'missing endpoint stays incomplete, not invented growth')
-- Summary usage counts original accounting but cannot change task context delta.
local capturedStart,capturedEnd,summaryEvents
summaryEvents={}
local summarySid=sid('summary isolation');seed(summarySid,599900,100)
local summaryBot
summaryBot=agent.new(summarySid,function(event)summaryEvents[#summaryEvents+1]=event;capturedStart=summaryBot.on_call_start or capturedStart;capturedEnd=summaryBot.on_call_end or capturedEnd end,'master','master','')
host.http_stream=function()return json.encode({status=200,content='summary scope',stream_complete=true,finish_reason='stop',tool_calls={},usage=usage(840000,10000,0)})end
summaryBot:run('scope')
local before,billed=json.encode(summaryBot.run_counts.context_growth),summaryBot.run_counts.tokens_reported
host.http=function()return json.encode({status=200,body=json.encode({choices={{message={content='summary'},finish_reason='stop'}},usage=usage(100000,100,0)})})end
provider.complete_with('deepseek-v4.1-flash',{{role='user',content='summary'}},nil,false,{session_id=summarySid,run_id=summaryBot.run_id,kind='summary',on_call_start=capturedStart,on_call_end=capturedEnd})
check(summaryBot.run_counts.tokens_reported==billed+100100 and json.encode(summaryBot.run_counts.context_growth)==before,'summary billing never inflates context added')
local activeSummary
for _,event in ipairs(summaryEvents)do if event.type=='run_counts' and event.counts.summary_step and event.counts.summary_step.state=='running' then activeSummary=event.counts.summary_step end end
check(activeSummary and activeSummary.model=='deepseek-v4.1-flash','actual summary boundary emits model-is-summarizing snapshot before inference')
check(activeSummary.state=='running' and summaryBot.run_counts.summary_step.state=='completed' and summaryBot.run_counts.summary_step.ms>=0,'detached summary start remains running while terminal snapshot settles')
host.http=function()return json.encode({error='summary fixture failure'})end
check(not pcall(function()provider.complete_with('deepseek-v4.1-flash',{{role='user',content='summary fails'}},nil,false,{session_id=summarySid,run_id=summaryBot.run_id,kind='summary',on_call_start=capturedStart,on_call_end=capturedEnd})end),'actual failed summary boundary')
check(summaryBot.run_counts.summary_step.state=='failed','failed summary is not completed or left running')
check(growth.current==850000 and growth.added==250000,'retained snapshots detached from later runs')
print('context growth ok ('..checks..' checks, 0 skipped; no paid inference)')
