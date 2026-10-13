-- Deterministic native task-path replay, not an autonomous model benchmark.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local agent=dofile('lua/core/agent.lua')
local output=dofile('lua/core/tool_output.lua')
local env=host.getenv;local mode='classic'
host.getenv=function(k)if k=='WASM_AGENT_BOOTSTRAP_MODE' then return mode end;return env(k)end
local root=dofile('lua/core/paths.lua').data()..'/tasks'
local results={};local checks=0
local function check(v,label)assert(v,label);checks=checks+1 end
for _,treatment in ipairs({'classic','lean'})do
 mode=treatment
 for _,kind in ipairs({'repair','recall','remember','capture_singles','capture_group'})do
  local sid=memory.start_session('','task replay '..treatment..' '..kind,{user_id='master'})
  local ctx={session_id=sid,user_id='master'}
  local schemas=tools.envelope('master',ctx)
  local system=agent.system_prompt('master',assert(host.read_file('AGENTS.md')),'AGENTS.md',schemas,'progressive')
  local messages={{role='system',content=system},{role='user',content='Verified fixture '..kind}}
  local stats={mode=mode,task=kind,rounds=0,discovery_rounds=0,invocations=0,total_input_bytes=0,total_tool_bytes=0,peak_input_bytes=0,initial_bytes=0,outcome=false}
  local function snapshot()
   local bytes=#json.encode({messages=messages,tools=schemas});stats.rounds=stats.rounds+1
   stats.total_input_bytes=stats.total_input_bytes+bytes;stats.peak_input_bytes=math.max(stats.peak_input_bytes,bytes)
   if stats.initial_bytes==0 then stats.initial_bytes=bytes end
  end
  local function step(calls)
   snapshot();local declared={}
   for i,call in ipairs(calls)do declared[i]={id='call-'..stats.rounds..'-'..i,type='function',['function']={name=call.name,arguments=json.encode(call.arguments)}} end
   messages[#messages+1]={role='assistant',tool_calls=declared}
   local responses={}
   for i,call in ipairs(calls)do
    ctx.tool_arguments_json=declared[i]['function'].arguments
    local r=tools.dispatch(memory,call.name,call.arguments,'master',ctx);ctx.tool_arguments_json=nil
    local text=output.project(call.name,r);messages[#messages+1]={role='tool',tool_call_id=declared[i].id,content=text}
    stats.invocations=stats.invocations+1;stats.total_tool_bytes=stats.total_tool_bytes+#text
    if call.name=='tool_search' then stats.discovery_rounds=stats.discovery_rounds+1 end
    responses[i]=r
   end
   return responses
  end
  if kind=='repair' then
   local file=root..'/'..mode..'-sum.lua';local original='return function(a,b) return a-b end\n'
   assert(host.write_file(file,original));check(assert(load(original))()(2,3)~=5,'gold oracle fails starting repair')
   local read=step({{name='read',arguments={path=file}}})[1]
   check(read.content==original,'read exact repair source')
   local edit=step({{name='edit',arguments={path=file,edits={{old_text='return a-b',new_text='return a+b'}}}}})[1]
   local repaired=assert(host.read_file(file));stats.outcome=not edit.error and assert(load(repaired))()(2,3)==5
  elseif kind=='recall' then
   memory.remember('fixture codeword is ORCHID','task-fixture',{'fixture'})
   local r=step({{name='recall',arguments={query='fixture codeword',scope='task-fixture'}}})[1]
   stats.outcome=json.encode(r):find('ORCHID',1,true)~=nil
  elseif kind=='remember' then
   local name='remember';local direct=false;for _,s in ipairs(schemas)do if s['function'].name==name then direct=true end end
   if not direct then step({{name='tool_search',arguments={query='remember',limit=1}}}) end
   local r=step({{name=direct and 'remember' or 'tool_call',arguments=direct and {content='Remembered fixture '..mode,scope='remember-fixture'} or {name='remember',arguments={content='Remembered fixture '..mode,scope='remember-fixture'}}}})[1]
   stats.outcome=r.id~=nil
  else
   local paths={root..'/'..mode..'-one.json',root..'/'..mode..'-two.json'}
   for i,p in ipairs(paths)do
    local request={messages={{role='system',content=string.rep('fixture ',10000)}},tools={{name='fixture-'..i,parameters={type='object'}}}}
    assert(host.write_file(p,json.encode({requests={request}})))
   end
   step({{name='tool_search',arguments={query='capture_inspect',limit=1}}})
   local calls={};for _,p in ipairs(paths)do calls[#calls+1]={name='capture_inspect',arguments={path=p}}end
   local r
   if kind=='capture_group' then r=step({{name='tool_call',arguments={calls=calls}}})[1].results
   else local wrapped={};for _,c in ipairs(calls)do wrapped[#wrapped+1]={name='tool_call',arguments={name=c.name,arguments=c.arguments,checked=true}}end;r=step(wrapped)end
   stats.outcome=r and #r==2 and r[1].results[1].tool_count==1 and r[2].results[1].system_bytes==80000
  end
  snapshot();check(stats.outcome,'behavioral task acceptance '..mode..' '..kind)
  results[#results+1]=stats
 end
end
local by={};for _,r in ipairs(results)do by[r.mode..':'..r.task]=r end
for _,kind in ipairs({'repair','recall','remember','capture_singles','capture_group'})do
 local before,after=by['classic:'..kind],by['lean:'..kind]
 check(before.rounds==after.rounds and before.discovery_rounds==after.discovery_rounds,'common task round counts retained '..kind)
 check(after.total_input_bytes<before.total_input_bytes,'complete task context reduced '..kind)
end
check(by['lean:remember'].discovery_rounds==by['classic:remember'].discovery_rounds,'remember kept immediate after measured discovery penalty')
for _,mode in ipairs({'classic','lean'})do
 check(by[mode..':capture_group'].rounds==by[mode..':capture_singles'].rounds,'grouping existing independent calls is not a fabricated model-round saving')
 check(by[mode..':capture_group'].invocations==by[mode..':capture_singles'].invocations-1,'one fewer wrapper invocation, same real two reads')
 check(by[mode..':capture_group'].total_input_bytes<by[mode..':capture_singles'].total_input_bytes,'no duplicated prose in grouped result; total input context improves')
end
assert(host.write_file(assert(host.getenv('WA_TASK_RECEIPT')),json.encode({ok=true,checks=checks,results=results,scope='Deterministic native tool-path replay with predeclared plans/behavioral oracles. Serialized complete input/tool context, not provider tokens, billing or autonomous model quality.',provider_calls=0,app_calls=0})))
print('envelope task outcomes ok ('..checks..' checks, 0 skipped; no provider/app calls)')
