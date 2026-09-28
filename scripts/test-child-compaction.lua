local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local provider=dofile('lua/core/provider.lua')
local original=dofile
dofile=function(p) if p=='lua/core/provider.lua' then return provider end return original(p) end
local agent=original('lua/core/agent.lua');dofile=original
local base_budget=provider.budget
provider.budget=function() return {context=32000,reserve=4000,keep=4000,output=2000} end
local function run(max_tokens)
 local sid=memory.start_session('','subagent',{user_id='master'})
 for i=1,100 do memory.append_turn(sid,{role=i%2==1 and 'user' or 'assistant',content=string.rep('work evidence ',180)}) end
 local summaries,models=0,0
 provider.complete_with=function(_,_,_,_,opts)
  if opts.kind=='summary' then summaries=summaries+1;return {content='verified checkpoint',tool_calls={},finish_reason='stop'} end
  models=models+1;return {content='continued',tool_calls={},usage={prompt_tokens=200,completion_tokens=20,total_tokens=220}}
 end
 local bot=agent.new(sid,function() end,'master','master','',{subagent={id='fixture',allowed={},allowed_tools={},limits={max_tokens=max_tokens}}})
 local ok,result=pcall(bot.run,bot,'continue')
 assert(memory.message_count(sid)>=101,'original rows retained')
 assert(not bot.reserve_summary,'accountant cleared after settlement')
 return ok,result,summaries,models,sid
end
local ok,result,summaries,models,sid=run(200000)
assert(ok and result=='continued' and summaries>0 and models==1,'child compacts then continues: '..tostring(result))
assert(memory.session(sid).summarized_until>0,'durable checkpoint')
local ok2,error2,s2,m2=run(100)
assert(not ok2 and tostring(error2):find('summary reservation',1,true) and s2==0 and m2==0,'budget refusal before any model spend')
provider.budget=base_budget
print('child compaction ok (budgeted summary, exact originals, refusal before spend)')
