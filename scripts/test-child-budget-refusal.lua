-- What a child's emitted token budget says when it refuses a call.
--
-- The refusal is arithmetic with two origins: `remaining_tokens` is the profile's
-- declared `max_tokens` minus what THIS child's own provider calls have already
-- been billed (every round re-sends the whole context, so a long child spends its
-- cap many times over), and `estimated_prompt_tokens` is this child's own next
-- request - its system prompt, tool schemas and its own transcript. A refusal that
-- reports only the two bare numbers reads as a mis-sized limit: a delegated 1.8 KB
-- task against a "170k-token prompt estimate" is exactly how one such record was
-- reported, while the ledger for it showed 20 provider calls already made. This
-- fixture pins both numbers and their provenance, and that the refusal itself
-- costs no provider call.
local memory=dofile('lua/core/memory.lua');memory.setup()
local provider=dofile('lua/core/provider.lua')
local original=dofile
dofile=function(p) if p=='lua/core/provider.lua' then return provider end return original(p) end
local agent=original('lua/core/agent.lua');dofile=original
local base_budget=provider.budget
provider.budget=function() return {context=400000,reserve=4000,keep=8000,output=4000} end

local checks=0
local function check(ok,why) checks=checks+1;assert(ok,why) end
local function number(text,key)
  return tonumber(tostring(text):match(key.."=(%d+)"))
end

-- A child session that already holds its own transcript: the estimate the refusal
-- reports is this child's next request, never the parent's prompt.
local function child_session(chars)
  local sid=memory.start_session('','subagent',{user_id='master',title='subagent:fixture'})
  memory.append_turn(sid,{role='user',content=string.rep('transcript evidence ',math.floor(chars/20))})
  return sid
end

local function child_for(sid,max_tokens)
  return agent.new(sid,function() end,'master','master','',
    {subagent={id='fixture',run_id='fixture-run',allowed={ls=true},allowed_tools={'ls'},
      instructions='fixture',limits={max_tokens=max_tokens}}})
end

-- One `ls` call per round keeps the loop going, so the budget is spent across
-- rounds exactly as a real child spends it; the last round answers, so a child
-- with no budget still settles.
local function round_stub(usage_per_call,rounds)
  local calls=0
  provider.complete_with=function()
    calls=calls+1
    if calls>rounds then return {content='done',tool_calls={},finish_reason='stop'} end
    return {content='working',finish_reason='tool_calls',
      tool_calls={{id='call_'..calls,type='function',
        ['function']={name='ls',arguments='{"path":"."}'}}},
      usage=usage_per_call}
  end
  return function() return calls end
end

-- 1. The recorded case, reproduced: a 200000 declared budget spent by the child's
-- own eight calls (8 x 23929 = 191432 billed, the same arithmetic the ledger shows
-- for a recorded refusal: 200000 - 191428 = 8572) leaves the child's own next
-- request (~22k tokens of its own transcript) unable to fit.
local used=23929*8
local SID=child_session(90000)
local calls=round_stub({prompt_tokens=23928,completion_tokens=1,total_tokens=23929},8)
local bot=child_for(SID,200000)
local ok,result=pcall(bot.run,bot,'the delegated task is short')
check(not ok,'a child whose next request cannot fit its remaining budget is refused')
local message=tostring(result)
check(message:find('subagent_token_budget: the prompt exceeds the remaining budget',1,true)~=nil,
  'the refusal names its budget: '..message)
check(number(message,'estimated_prompt_tokens')~=nil and number(message,'remaining_tokens')==200000-used,
  'both recorded numbers are reported, and remaining is the cap minus the usage: '..message)
check(number(message,'estimated_prompt_tokens')>=20000,
  "the estimate is the child's own grown context, not the short delegated prompt: "..message)
check(number(message,'max_tokens')==200000 and
  message:find(', used_tokens='..used.." (this child's own calls)",1,true)~=nil,
  'the cap and the usage it was spent from are named, so 200000-191428 is checkable: '..message)
check(message:find(', estimate_source=',1,true)~=nil and message:find(', round=',1,true)~=nil and
  message:find(', model=',1,true)~=nil,
  'the estimate source, the round and the model travel with the numbers: '..message)
check(calls()==8,'the refusal costs no further provider call (8 paid calls, then refused, got '..calls()..')')

-- 2. Nothing left at all: the next call is refused, with the same provenance.
local SID2=child_session(90000)
local calls2=round_stub({prompt_tokens=199999,completion_tokens=1,total_tokens=200000},2)
local bot2=child_for(SID2,200000)
local ok2,result2=pcall(bot2.run,bot2,'the delegated task is short')
check(not ok2 and tostring(result2):find('subagent_token_budget: exhausted before the call',1,true)~=nil,
  'an exhausted budget refuses the next call: '..tostring(result2))
check(number(result2,'used_tokens')==200000 and number(result2,'max_tokens')==200000,
  'the exhausted refusal names the cap and the usage that spent it: '..tostring(result2))

-- 3. The launch-decidable case: a cap that cannot hold the child's FIRST request
-- is refused before any provider call, and used_tokens=0 leaves one number to
-- explain - which is why this case can be refused at launch.
local SID3=child_session(90000)
local calls3=round_stub({prompt_tokens=10,completion_tokens=1,total_tokens=11},1)
local bot3=child_for(SID3,1000)
local ok3,result3=pcall(bot3.run,bot3,'the delegated task is short')
check(not ok3 and number(result3,'remaining_tokens')==1000 and number(result3,'used_tokens')==0,
  'a budget smaller than the first request is refused with used_tokens=0: '..tostring(result3))
check(calls3()==0,'that refusal is made before any provider call was paid for')

-- 4. No cap is added: a child that declares no max_tokens still reaches the
-- provider and settles.
local SID4=child_session(2000)
local calls4=round_stub({prompt_tokens=100,completion_tokens=1,total_tokens=101},1)
local bot4=child_for(SID4,nil)
local ok4,result4=pcall(bot4.run,bot4,'the delegated task is short')
check(ok4,'a child with no declared token budget is not refused: '..tostring(result4))
check(calls4()==2,'and it reaches the provider: '..calls4()..' calls')

provider.budget=base_budget
print('child budget refusal ok ('..checks..' checks)')
