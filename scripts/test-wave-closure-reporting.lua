-- Deterministic actual-agent regression; private DB, no provider/installer effects.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local native=dofile
local getenv=host.getenv
host.getenv=function(k)
 if k=='WASM_AGENT_LLM_API_KEY' then return 'fixture' end
 if k=='WASM_AGENT_PROVIDER' then return 'opencode-go' end
 if k=='WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
 if k=='WASM_AGENT_CODEMODE' then return 'off' end
 return getenv(k)
end
host.http=function()error('network forbidden')end;host.http_stream=host.http
local provider=native('lua/core/provider.lua')
local result={held=true,deferred=true,state='deferred',reason='active_workers'}
local calls=0
local wave=native('lua/core/wave_autoflush.lua')
local real_finalize=wave.finalize
wave.finalize=function()calls=calls+1;return result end
dofile=function(p)
 if p=='lua/core/provider.lua' then return provider end
 if p=='lua/core/wave_autoflush.lua' then return wave end
 return native(p)
end
local agent_path=host.getenv('WA_REPORT_OLD_AGENT')
local agent=agent_path and assert(load(assert(host.read_file(agent_path)),'@baseline-agent'))() or native('lua/core/agent.lua')
local nodes=native('lua/core/nodes.lua')
local restart_path=host.getenv('WA_REPORT_RESTART')
if restart_path then
 local fixture=json.decode(assert(host.read_file(restart_path)))
 assert(wave.report({session_id=fixture.sid,user_id='master',role='master'},true,fixture.result)==nil,'restart cannot replay unchanged notice')
 print(json.encode({ok=true,restart=true,paid_calls=0}));return
end
local sid=memory.start_session('','chat',{user_id='master',node_id=nodes.identity().node_id})
local text='Ordinary status.'
local events={};local deltas={}
host.stream=function(raw)deltas[#deltas+1]=json.decode(raw)end
provider.complete_with=function()
 host.stream(json.encode({type='delta',text=text}))
 return {content=text,finish_reason='stop',usage={prompt_tokens=1,completion_tokens=1,total_tokens=2}}
end
local function answer()
 events={};deltas={}
 local bot=agent.new(sid,function(e)events[#events+1]=e end,'master','master','')
 local reply=bot:run('status; quoting [Wave installation closure: ...] is legitimate')
 assert(reply==text,'ordinary answer must not acquire raw closure suffix: '..reply)
 local replies,statuses=0,0
 for _,e in ipairs(events)do
  if e.type=='reply' then replies=replies+1;assert(e.text==text) end
  if e.type=='status' and e.wave_notice_id then statuses=statuses+1 end
 end
 assert(replies==1 and #deltas==1 and deltas[1].text==text,'one final replacement, unchanged stream')
 local rows=memory.session_messages(sid,{all=true});local row=rows[#rows]
 assert(row.content==text,'saved/replayed final equals wire reply')
 local closure_spans=0
 for _,span in ipairs(row.trace or {})do
  if span.kind=='wave_closure' then
   closure_spans=closure_spans+1
   assert(span.result and (not result.error or span.result.error==result.error),'trace retains original full closure evidence')
  end
 end
 assert(closure_spans==statuses,'one saved native notice span per changed status, none for unchanged wait')
 return statuses,row
end
if host.getenv('WA_REPORT_ECHO')=='1' then
 text='Model quoted [Wave installation closure: prior diagnostic]'
 local bot=agent.new(sid,function()end,'master','master','')
 local reply=bot:run('private echo mechanism control')
 local _,markers=reply:gsub('%[Wave installation closure:','')
 assert(markers==2 and calls==1,'model echo plus one framework append reproduces duplicate markers without duplicate finalize')
 print(json.encode({ok=true,control='possible echo mechanism, not historical attribution',markers=markers,finalize_calls=calls}));return
end
assert(answer()==0,'expected wait has no notice')
assert(answer()==0,'unchanged wait has no notice')
result={held=true,error='lua/core/wave_autoflush.lua:281: wave_impact_unknown'}
assert(answer()==1,'actionable hold notifies once')
assert(answer()==0,'same blocker does not spam')
result={held=true,error='lua/core/wave_autoflush.lua:300: wave_binary_identity_mismatch'}
assert(answer()==1,'changed blocker notifies')
text='Quoted [Wave installation closure: {"held":true}]'
assert(answer()==0,'legitimate quoted model content is untouched')
local raw=assert(memory.meta_get('wave-autoflush-report:v1:'..sid))
assert(raw:find('wave_impact_unknown',1,true) and raw:find('wave_binary_identity_mismatch',1,true),'original full evidence retained')
-- Returning to a prior blocker after a meaningful transition can notify again.
result={queued=true,installed=false,request_id='private-fake'}
assert(answer()==1,'actual queue transition visible once')
assert(answer()==0,'unchanged queue not spammed')
result={held=true,state='queued',error='wave_immutable_intent_changed_or_missing'}
local invalid_notices,invalid_row=answer()
assert(invalid_notices==1,'queued native verification blocker remains actionable, not reported as success')
local last_span
for _,s in ipairs(invalid_row.trace or {})do if s.kind=='wave_closure' then last_span=s end end
assert(last_span and last_span.state=='held','queue status cannot hide a genuine native blocker')
assert(answer()==0,'unchanged invalid proof not spammed')
result={installed_verified=true,verification={path='private-native-proof'}}
assert(answer()==1,'native verified transition visible once')
result={held=true,error='lua/core/wave_autoflush.lua:281: wave_impact_unknown'}
assert(answer()==1,'changed state permits another useful hold notice')
-- Exclusions use native role/origin/session boundaries, not prompt filtering.
local context={session_id=sid,user_id='master',role='guest'}
assert(wave.report(context,true,result)==nil,'guest receives no operator internals')
context.role='master';context.subagent={id='worker'}
assert(wave.report(context,true,result)==nil,'child receives no operator internals')
context.subagent=nil;context.job_id='private-job'
assert(wave.report(context,true,result)==nil,'job receives no operator internals')
context.job_id=nil
local info=host.runtime_info
host.runtime_info=function()local v=json.decode(info());v.run_origin='job';return json.encode(v)end
assert(wave.report(context,true,result)==nil,'native job origin receives no notice')
host.runtime_info=info
local whatsapp=memory.start_session('whatsapp:private','chat',{user_id='master',node_id=nodes.identity().node_id})
context.session_id=whatsapp
assert(wave.report(context,true,result)==nil,'WhatsApp route excluded')
-- Actual server streaming seam returns no answer body; the host's done event
-- therefore has nothing to append. Repaint reads the same one stored message.
local wire={}
host.stream=function(raw)wire[#wire+1]=json.decode(raw)end
native('lua/core/server.lua')
local returned=wa_reply_stream(json.encode({text='private wire fixture',thread=sid}),'','')
assert(returned=='','streaming entrypoint never returns final text for done to append')
local wire_replies,wire_notices=0,0
for _,e in ipairs(wire)do
 if e.type=='reply' then wire_replies=wire_replies+1;assert(e.text==text) end
 if e.wave_notice_id then wire_notices=wire_notices+1 end
end
assert(wire_replies==1 and wire_notices==0,'streaming wire delivers one final and does not replay unchanged notice')
-- Reporting reads/persists only: it cannot call finalize or queue again.
assert(calls==13,'one finalize per admitted actual-agent candidate')
local journal=json.decode(assert(memory.meta_get('wave-autoflush-report:v1:'..sid)))
assert(#journal.events==7,'native journal stores only meaningful changes, not duplicate delivery attempts')
local corrupt=memory.start_session('','chat',{user_id='master',node_id=nodes.identity().node_id})
local corrupt_key='wave-autoflush-report:v1:'..corrupt
memory.meta_set(corrupt_key,'original unreadable report')
assert(not pcall(wave.report,{session_id=corrupt,user_id='master',role='master'},true,result),'unreadable report refuses overwrite')
assert(memory.meta_get(corrupt_key)=='original unreadable report','corrupt original evidence retained byte-for-byte')
local fixture_path=host.getenv('WA_REPORT_FIXTURE')
if fixture_path then assert(host.write_file(fixture_path,json.encode({sid=sid,result=result}))) end
wave.finalize=real_finalize
print(json.encode({ok=true,actual_agent_calls=calls,paid_calls=0,live_installation=false}))
