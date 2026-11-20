local json=dofile('lua/vendor/json.lua')
local real_getenv=host.getenv
local raw=nil
local overrides={WASM_AGENT_PROVIDER='opencode-go',WASM_AGENT_LLM_API_KEY='raw-code-fixture',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_MAX_TOOL_ROUNDS='6'}
host.getenv=function(k)
  if k=='WASM_AGENT_RAW_CODE' then return raw end
  if k=='WASM_AGENT_CODEMODE' then return nil end
  if overrides[k]~=nil then return overrides[k] end
  return real_getenv(k)
end
host.http=function() error('network forbidden in the raw-code fixture') end
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
local tool_output=dofile('lua/core/tool_output.lua')
local dispatched={}
local real_dispatch=tools.dispatch
tools.dispatch=function(m,name,args,role,ctx)
  if name=='codemode' then dispatched[#dispatched+1]=args.code end
  return real_dispatch(m,name,args,role,ctx)
end
local checks=0
local function check(v,label) assert(v,label);checks=checks+1 end

local runs=0
local function run(mode,script)
  raw=mode;replies=script;requests={};dispatched={};runs=runs+1
  local sid=memory.start_session('','raw-code-'..runs,{user_id='master',node_id='',title='raw-code-'..runs})
  local events={}
  local ok,reply=pcall(function()
    return agent.new(sid,function(event) events[#events+1]=event end,'master','master',''):run('compute it')
  end)
  local rows={}
  for _,row in ipairs(memory.session_messages(sid,{all=true})) do rows[#rows+1]=row end
  local assistant,tool
  for _,row in ipairs(rows) do
    if row.role=='assistant' and type(row.tool_calls)=='table' and #row.tool_calls>0 then assistant=row end
    if row.role=='tool' then tool=row end
  end
  return {ok=ok,reply=reply,rows=rows,assistant=assistant,tool=tool,events=events,requests=requests,dispatched=dispatched}
end
local function tool_message(request,id)
  for _,m in ipairs(request.messages) do if m.role=='tool' and m.tool_call_id==id then return m end end
end
local function keys(t) local out={} for k in pairs(t or {}) do out[#out+1]=tostring(k) end table.sort(out) return table.concat(out,',') end
-- Native call markup in the TEXT (lua/core/raw_code.lua, native_calls): the replies measured on work 17/11
-- (sessions b08de0ed, 02d9236e) ran nothing and ended the turn. Now each runs, and the loop continues.
local B='\239\189\156'
local function dsml(s) return (s:gsub('|',B)) end

-- 1. b08de0ed, byte-shape: code directly inside invoke name="js", stray closing parameter tag
local r1=dsml('I\'ll check.\n\n<|DSML| calls>\n<|DSML| invoke name="js">const [a, b] = await Promise.all([\n  1, 2\n]);\nreturn { a, b };\n</|DSML| parameter>\n</|DSML| invoke>\n</|DSML| calls>')
local s1=run('only',{{content=r1},{content='done after the script'}})
check(s1.ok and s1.reply=='done after the script','the loop continued past the markup step: '..tostring(s1.reply))
check(#s1.dispatched==1 and s1.dispatched[1]=='const [a, b] = await Promise.all([\n  1, 2\n]);\nreturn { a, b };','the js invoke ran as the script: '..json.encode(s1.dispatched[1]))
check(s1.assistant.content=="I'll check.",'the thought is kept without the markup: '..json.encode(s1.assistant.content))
check(s1.tool.content:find('DSML call markup ran as a script',1,true),'the observation says what happened')
check(s1.assistant.tool_calls[1].id:match('^call_raw_'),'it is a raw-channel call')
-- the next request renders it as a run block (history teaches the native form)
local req2=json.encode(s1.requests[2])
check(req2:find('```js run',1,true) and not req2:find('invoke name',1,true),'history shows a run block, not the markup')

-- 2. 02d9236e: a non-code tool with a string parameter -> tools.<name>(args)
local r2=dsml('\n\n<|DSML| calls>\n<|DSML| invoke name="bash">\n<|DSML| parameter name="command" string="true">ls -d /tmp</|DSML| parameter>\n</|DSML| invoke>\n</|DSML| calls>')
local s2=run('only',{{content=r2},{content='listed'}})
check(#s2.dispatched==1 and s2.dispatched[1]=='return await tools.bash({"command":"ls -d /tmp"});','bash invoke became a one-line script: '..json.encode(s2.dispatched[1]))
check(s2.reply=='listed','loop continued')

-- 3. canonical DSML with a non-string param and two invokes
local r3=dsml('<|DSML|function_calls>\n<|DSML|invoke name="recall">\n<|DSML|parameter name="limit" string="false">3</|DSML|parameter>\n</|DSML|invoke>\n<|DSML|invoke name="codemode">\n<|DSML|parameter name="code" string="true">return 1;</|DSML|parameter>\n</|DSML|invoke>\n</|DSML|function_calls>')
local s3=run('only',{{content=r3},{content='ok3'}})
check(#s3.dispatched==2 and s3.dispatched[1]=='return await tools.recall({"limit":3});' and s3.dispatched[2]=='return 1;','two invokes ran in order: '..json.encode(s3.dispatched))

-- 4. Hermes/Qwen <tool_call>
local s4=run('first',{{content='ok\n<tool_call>{"name":"js","arguments":{"code":"return 2;"}}</tool_call>'},{content='ok4'}})
check(#s4.dispatched==1 and s4.dispatched[1]=='return 2;' and s4.reply=='ok4','<tool_call> ran')

-- 5. markup that cannot be read: refused, the loop continues (not taken as the answer)
local s5=run('only',{{content=dsml('<|DSML|function_calls>\n</|DSML|function_calls>')},{content='recovered'}})
check(#s5.dispatched==0 and s5.reply=='recovered' and s5.tool and s5.tool.content:find('raw_code_markup',1,true),'unreadable markup is refused and the turn goes on: '..tostring(s5.tool and s5.tool.content))

-- 6. a run block still wins over later markup; plain prose mentioning DSML is not markup
local s6=run('only',{{content='x\n```js run\nreturn 3;\n```'},{content='ok6'}})
check(#s6.dispatched==1 and s6.dispatched[1]=='return 3;','run block path unchanged')
local s7=run('only',{{content='DSML is a format name.'}})
check(#s7.dispatched==0 and s7.reply=='DSML is a format name.','prose is an answer')

-- 7. switch off: markup is text (nothing changes for nodes without raw code)
local s8=run('codemode',{{content=r2}})
check(#s8.dispatched==0,'switch off: markup is not read')

-- CodeAct is the default (17/11): unset means `only`; `codemode` (or off/0/false/no) is the opt-out.
-- rel r1 R2: an unset switch resolves from the PROVIDER, so this row pins the mode it is
-- actually about instead of asserting a default that now belongs to another provider class.
raw='only'; check(raw_code.mode()=='only','explicit only still selects the CodeAct surface')
for _,v in ipairs({'codemode','off','0','false','no','CODEMODE',' off '}) do raw=v; check(raw_code.mode()==nil,'opt-out '..v..': codemode') end
raw='first'; check(raw_code.mode()=='first','first is still first')
raw=nil
print(json.encode({ok=true,checks=checks,paid_calls=0}))
