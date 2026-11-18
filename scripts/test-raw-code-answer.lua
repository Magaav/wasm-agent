-- Review of 18/11, items 1 and 2: a NORMAL ANSWER must not be turned into an action, and must not fail a turn.
-- Through the real agent loop with a stubbed provider (no network, no paid call).
--
-- What was wrong on 62c3c064, and is pinned by one case below each:
--   1. `only` is the default MODE on every node, including one whose code mode is OFF. `take` re-tagged every
--      plain ```js fence as an action there, so an ordinary sample in an answer became a codemode call and
--      was refused `codemode_not_enabled`. The re-tag now asks the POLICY (`M.only(policy)`), not the mode.
--   2. `unexecuted` scanned every line of the reply, inside other blocks included, so three shapes that are
--      the model's TEXT failed a normal answer: a `js run` example inside a ````md block, a fence inside a
--      list item (valid CommonMark), and a plain ```js on a node whose code mode is off. It now decides with
--      the parser (`M.parse`) and with the list item's content column, and it asks the policy too.
--   3. the guard itself still works: a run block the parser could have seen and did not (indented 4 spaces at
--      the top level) still fails the turn by name - the fix must not be "never fail".
local json=dofile('lua/vendor/json.lua')
local real_getenv=host.getenv
local raw_mode=nil      -- unset: the default, CodeAct (`only`)
local codemode=nil      -- unset: native code mode enabled
local overrides={WASM_AGENT_PROVIDER='opencode-go',WASM_AGENT_LLM_API_KEY='answer-fixture',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_MAX_TOOL_ROUNDS='6'}
host.getenv=function(k)
  if k=='WASM_AGENT_RAW_CODE' then return raw_mode end
  if k=='WASM_AGENT_CODEMODE' then return codemode end
  if overrides[k]~=nil then return overrides[k] end
  return real_getenv(k)
end
host.http=function() error('network forbidden in the raw-code answer fixture') end
local replies,requests={},{}
host.http_stream=function(_,_,_,body)
  requests[#requests+1]=json.decode(body)
  local r=table.remove(replies,1) or {content='fixture done'}
  return json.encode({status=200,content=r.content or '',stream_complete=r.stream_complete~=false,
    finish_reason=r.finish_reason or (r.stream_complete==false and json.null or 'stop'),
    usage={prompt_tokens=100,completion_tokens=20,total_tokens=120},tool_calls=r.tool_calls or {}})
end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local original=dofile
dofile=function(p) if p=='lua/core/tools.lua' then return tools end return original(p) end
local agent=original('lua/core/agent.lua');dofile=original
local dispatched={}
local real_dispatch=tools.dispatch
tools.dispatch=function(m,name,args,role,ctx)
  if name=='codemode' then dispatched[#dispatched+1]=args.code end
  return real_dispatch(m,name,args,role,ctx)
end
local checks=0
local function check(v,label) assert(v,label);checks=checks+1 end
local TICK=string.rep(string.char(96),3)
local runs=0
local function run(script,mode,codemode_setting)
  raw_mode=mode;codemode=codemode_setting;replies=script;requests={};dispatched={};runs=runs+1
  local sid=memory.start_session('','answer-'..runs,{user_id='master',node_id='',title='answer-'..runs})
  local events={}
  local ok,reply=pcall(function()
    return agent.new(sid,function(event) events[#events+1]=event end,'master','master',''):run('compute it')
  end)
  local rows=memory.session_messages(sid,{all=true})
  local tool
  for _,row in ipairs(rows) do if row.role=='tool' then tool=row end end
  return {sid=sid,ok=ok,reply=reply,events=events,requests=requests,dispatched=dispatched,tool=tool,rows=rows}
end

-- 1. code mode OFF: a plain ```js sample in an answer is text, not an action --------------------------------
local sample=run({{content='Here is how the channel works:\n\n'..TICK..'js\nreturn await tools.bash({command:"ls"});\n'..
  TICK..'\n\nThat is all it takes.'}},'only','off')
check(sample.ok,'ITEM 1: the answer with a js sample is not a failed turn: '..tostring(sample.reply):sub(1,240))
check(#sample.dispatched==0,'ITEM 1: the sample is not dispatched as code (dispatched '..#sample.dispatched..')')
check(sample.tool==nil,'ITEM 1: nothing was executed, so there is no tool row: '..
  tostring(sample.tool and sample.tool.content):sub(1,200))
check(tostring(sample.reply):find('That is all it takes',1,true)~=nil,
  'ITEM 1: and the answer is the model\'s text, kept whole: '..tostring(sample.reply):sub(1,200))

-- 2. code mode ON, default mode: a `js run` example inside a ````md block is that block's text ---------------
local FENCE4=string.rep(string.char(96),4)
local documented=run({{content='The channel looks like this:\n\n'..FENCE4..'md\nWrite:\n\n'..TICK..'js run\n'..
  'return 6*7;\n'..TICK..'\n'..FENCE4..'\n\nNothing else to say.'}})
check(documented.ok,'ITEM 2: an example inside a md block does not fail the answer: '..tostring(documented.reply):sub(1,240))
check(#documented.dispatched==0,'ITEM 2: and it does not run (dispatched '..#documented.dispatched..')')

-- 3. code mode ON, default mode: a fence inside a LIST ITEM is valid CommonMark, so it is text too -----------
local listed=run({{content='The two steps are:\n\n- write the script:\n\n    '..TICK..'js run\n'..
  '    return 6*7;\n    '..TICK..'\n\n- read the answer.'}})
check(listed.ok,'ITEM 2: a fence inside a list item does not fail the answer: '..tostring(listed.reply):sub(1,240))
check(#listed.dispatched==0,'ITEM 2: nor does it run (dispatched '..#listed.dispatched..')')

-- 4. the guard still works: a run block the parser COULD have seen and did not ------------------------------
local missed=run({{content='Running.\n    '..TICK..'js run\n    return 6*7;\n    '..TICK}})
check(not missed.ok,'ITEM 2: a run block the parser could see and did not still fails the turn: '..tostring(missed.reply))
check(tostring(missed.reply):find('run_block_not_executed',1,true)~=nil,
  'ITEM 2: by name: '..tostring(missed.reply):sub(1,200))
check(tostring(missed.reply):find('indented 4 spaces',1,true)~=nil,
  'ITEM 2: and says why: '..tostring(missed.reply):sub(1,240))

print(json.encode({ok=true,checks=checks,paid_calls=0}))
