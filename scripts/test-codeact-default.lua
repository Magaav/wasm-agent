-- Items 1 and 2 of the harness-fixes mission (18/11), through the real agent loop with a stubbed provider:
-- no network, no paid call.
--
-- 1. THE DEFAULT MODE ACTS. With WASM_AGENT_RAW_CODE unset the node is in CodeAct mode (only), and a run
--    block in the model's message must always run - whatever fence the model wrote (CommonMark allows
--    tildes as well as backticks) - and a node whose code mode is not available must keep its ordinary
--    tools instead of declaring nothing and refusing the turn (no_dispatchable_tools), with the block
--    answered by name (codemode_not_enabled) rather than left in the text as the answer.
-- 2. AN ACTION THAT NEVER RAN IS A FAILURE. A turn that ends with a run block the harness never turned
--    into a call fails with run_block_not_executed and a reason, so a scripted `wa chat --once` exits
--    non-zero instead of reporting a silent '0 tools'.
local json=dofile('lua/vendor/json.lua')
local real_getenv=host.getenv
local raw_mode=nil      -- the default: CodeAct
local codemode=nil      -- the default: native code mode
local overrides={WASM_AGENT_PROVIDER='opencode-go',WASM_AGENT_LLM_API_KEY='codeact-fixture',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_MAX_TOOL_ROUNDS='6'}
host.getenv=function(k)
  if k=='WASM_AGENT_RAW_CODE' then return raw_mode end
  if k=='WASM_AGENT_CODEMODE' then return codemode end
  if overrides[k]~=nil then return overrides[k] end
  return real_getenv(k)
end
host.http=function() error('network forbidden in the codeact-default fixture') end
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
local raw_code=dofile('lua/core/raw_code.lua')
local dispatched={}
local real_dispatch=tools.dispatch
tools.dispatch=function(m,name,args,role,ctx)
  if name=='codemode' then dispatched[#dispatched+1]=args.code end
  return real_dispatch(m,name,args,role,ctx)
end
local checks=0
local function check(v,label) assert(v,label);checks=checks+1 end
local TICK=string.rep(string.char(96),3)
local TILDE=string.rep('~',3)
local runs=0
local function run(script,mode,codemode_setting)
  raw_mode=mode;codemode=codemode_setting;replies=script;requests={};dispatched={};runs=runs+1
  local sid=memory.start_session('','codeact-'..runs,{user_id='master',node_id='',title='codeact-'..runs})
  local events={}
  local ok,reply=pcall(function()
    return agent.new(sid,function(event) events[#events+1]=event end,'master','master',''):run('compute it')
  end)
  local tool
  for _,row in ipairs(memory.session_messages(sid,{all=true})) do if row.role=='tool' then tool=row end end
  local names={}
  for _,item in ipairs((requests[1] or {}).tools or {}) do names[item['function'].name]=true end
  return {sid=sid,ok=ok,reply=reply,events=events,requests=requests,dispatched=dispatched,tool=tool,names=names}
end

-- 1a. the default mode runs a plain backtick run block (the shape that already worked) ---------------
local plain=run({{content='Running.\n'..TICK..'js run\nreturn 6*7;\n'..TICK},{content='42 it is'}})
check(plain.ok and plain.reply=='42 it is','default mode: the turn finished after its run block: '..tostring(plain.reply))
check(#plain.dispatched==1 and plain.dispatched[1]=='return 6*7;','default mode: the run block ran once as codemode')

-- 1b. THE FIX: a tilde fence is a fence (CommonMark), so the block runs instead of becoming the answer --
local tilde=run({{content='Running.\n'..TILDE..'js run\nreturn 6*7;\n'..TILDE},{content='42 it is'}})
check(#tilde.dispatched==1 and tilde.dispatched[1]=='return 6*7;',
  'ITEM 1: a run block written with a tilde fence runs (ran '..#tilde.dispatched..' script(s), reply '..
  tostring(tilde.reply):sub(1,80)..')')
check(tilde.ok and tilde.reply=='42 it is','ITEM 1: the turn continued after the tilde-fenced block ran')

-- 1c. THE FIX: with code mode unavailable the node keeps its tools, and the block is refused by name ---
local inactive=run({{content='Running.\n'..TICK..'js run\nreturn 6*7;\n'..TICK},{content='done'}},'only','off')
check(inactive.ok,'ITEM 1: a run with code mode off is not refused before it starts: '..tostring(inactive.reply):sub(1,200))
check(inactive.names.bash and inactive.names.read,
  'ITEM 1: with code mode off the ordinary tools stay declared instead of nothing')
check(#((inactive.requests[1] or {}).tools or {})>0,'ITEM 1: the request declares a surface (declared '..
  #((inactive.requests[1] or {}).tools or {})..' tools)')
check(inactive.tool and tostring(inactive.tool.content):find('codemode_not_enabled',1,true)~=nil,
  'ITEM 1: the block is answered by name, not taken as the answer: '..tostring(inactive.tool and inactive.tool.content):sub(1,200))

-- 2. THE FIX: a run block the parser cannot see fails the turn, by name ------------------------------
local missed=run({{content='Running.\n    '..TICK..'js run\n    return 6*7;\n    '..TICK}})
check(not missed.ok,'ITEM 2: a turn whose run block never ran is a failed turn, not an answer: '..tostring(missed.reply))
check(tostring(missed.reply):find('run_block_not_executed',1,true)~=nil,
  'ITEM 2: the failure is named: '..tostring(missed.reply):sub(1,200))
check(tostring(missed.reply):find('indented 4 spaces',1,true)~=nil,
  'ITEM 2: the reason says why the block did not run: '..tostring(missed.reply):sub(1,240))

-- 2b. the same turn through the CLI: the exit status a script reads ---------------------------------
local chat=dofile('lua/core/chat.lua')
replies={{content='Running.\n    '..TICK..'js run\n    return 6*7;\n    '..TICK}}
requests={};dispatched={}
local status=chat.run({'wa','--once','compute it'})
check(status~=0,'ITEM 2: wa chat --once exits non-zero for a turn whose action never ran (exit '..tostring(status)..')')

print(json.encode({ok=true,checks=checks,paid_calls=0}))