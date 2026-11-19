-- WASM_AGENT_RAW_CODE=first (lua/core/raw_code.lua), through the real agent loop with a stubbed provider
-- stream: no network, no paid call.
--
-- first: the request declares no `codemode` tool and carries the run-block guidance (never the codemode-call
-- or direct-call wording); a run block runs once as codemode and is STORED as today (codemode call + tool
-- row); the next request renders it as the assistant text the model wrote (thought + block, no tool_calls)
-- followed by an `Observation:` user message byte-identical to the stored result; the rendering is the same
-- in-loop and rebuilt from the rows, and cache-stable round to round; a plain answer ends the turn; a direct
-- call and a codemode call the model sends anyway keep valid pairing next to raw calls; robustness as `1`.
-- `1` and off keep today's surface (scripts/test-raw-code.lua; byte identity is checked by the runner).
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


-- The fixture's run, also returning the session id (a later turn runs in it).
local function run(mode,script)
  raw=mode;replies=script;requests={};dispatched={};runs=runs+1
  local sid=memory.start_session('','raw-first-'..runs,{user_id='master',node_id='',title='raw-first-'..runs})
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
  return {sid=sid,ok=ok,reply=reply,rows=rows,assistant=assistant,tool=tool,events=events,requests=requests,dispatched=dispatched}
end

local function turn(sid,mode,script,text)
  raw=mode;replies=script;requests={};dispatched={}
  local events={}
  local ok,reply=pcall(function()
    return agent.new(sid,function(event) events[#events+1]=event end,'master','master',''):run(text or 'again')
  end)
  return {ok=ok,reply=reply,requests=requests,dispatched=dispatched,events=events}
end
local function session_rows(sid) return memory.session_messages(sid,{all=true}) end
local function declared(request)
  local out={}
  for _,t in ipairs(request.tools or {}) do out[#out+1]=t['function'].name end
  return out
end
local function has(list,name) for _,v in ipairs(list) do if v==name then return true end end return false end
-- No message of the request is a tool call or a tool result for a raw-channel call.
local function no_raw_pairing(request)
  for _,m in ipairs(request.messages) do
    if m.role=='tool' and raw_code.is_raw(m.tool_call_id) then return false end
    for _,c in ipairs(m.tool_calls or {}) do if raw_code.is_raw(c.id) then return false end end
  end
  return true
end
-- Every tool_calls entry is answered by the tool messages right after it, and every tool message answers one.
local function valid_pairing(request)
  local msgs=request.messages
  for i,m in ipairs(msgs) do
    if m.role=='assistant' and m.tool_calls then
      local want={};for _,c in ipairs(m.tool_calls) do want[c.id]=true end
      local j=i+1
      while msgs[j] and msgs[j].role=='tool' do
        if not want[msgs[j].tool_call_id] then return false,'unexpected result '..tostring(msgs[j].tool_call_id) end
        want[msgs[j].tool_call_id]=nil;j=j+1
      end
      if next(want) then return false,'unanswered call '..tostring(next(want)) end
    elseif m.role=='tool' then
      local k=i-1
      while k>0 and msgs[k].role=='tool' do k=k-1 end
      if not (msgs[k] and msgs[k].role=='assistant' and msgs[k].tool_calls) then return false,'orphan result '..tostring(m.tool_call_id) end
    end
  end
  return true
end
local function index_of(request,pred) for i,m in ipairs(request.messages) do if pred(m) then return i end end end
local function tool_rows(sid)
  local out={};for _,row in ipairs(session_rows(sid)) do if row.role=='tool' then out[#out+1]=row end end;return out
end
local OLD_LINE1='one `codemode` call runs JavaScript'
local OLD_DIRECT='Calling a tool directly also works'
local OLD_SCRIPT='ONE codemode script'

-- 1. first: codemode is not declared, the guidance is the run-block one -------------------------------
local first=run('first',{{content='Let me compute.\n```js run\nreturn 6*7;\n```'},{content='42 it is'}})
check(first.ok and first.reply=='42 it is','first: the run finished after the run block: '..tostring(first.reply))
local system=first.requests[1].messages[1].content
check(not has(declared(first.requests[1]),'codemode'),'first: codemode is not declared to the provider ('..table.concat(declared(first.requests[1]),',')..')')
check(system:find(raw_code.FIRST_GUIDANCE,1,true),'first: the system prompt carries the run-block guidance verbatim')
check(not system:find(raw_code.GUIDANCE,1,true),'first: the optional-extra sentence of `1` is not added')
check(not system:find(OLD_LINE1,1,true) and not system:find(OLD_DIRECT,1,true) and not system:find(OLD_SCRIPT,1,true),
  'first: no sentence tells the model to make a codemode call or a direct call')
check(not system:find('also callable directly',1,true),'first: the deferred-tools line does not advertise direct calls')
check(system:find('How to work: 1) Gather',1,true) and system:find('searchTools("select:a,b")',1,true) and system:find('`vars` is your session state',1,true),
  'first: the rest of the code-mode guidance is kept')
check(first.requests[1].stop==nil,'first: no stop sequence')
check(#first.dispatched==1 and first.dispatched[1]=='return 6*7;','first: the block ran once, as codemode, with exactly its code')
local call=first.assistant and first.assistant.tool_calls[1]
check(call and raw_code.is_raw(call.id) and call['function'].name=='codemode','first: the STORED row is still a codemode call (call_raw_)')
check(first.assistant.content=='Let me compute.' and first.tool and first.tool.tool_call_id==call.id,'first: the stored rows are unchanged (thought + tool row)')
local r2=first.requests[2]
local at=index_of(r2,function(m) return m.role=='assistant' and m.content=='Let me compute.\n```js run\nreturn 6*7;\n```' end)
check(at and r2.messages[at].tool_calls==nil,'first: the next request renders the call as assistant text + run block, no tool_calls')
check(r2.messages[at+1].role=='user' and r2.messages[at+1].content==raw_code.OBSERVATION..first.tool.content,
  'first: the observation follows as a user message, byte-identical to the stored tool row')
check(r2.messages[at+1].content:sub(1,13)=='Observation:\n','first: the observation marker')
check(no_raw_pairing(r2),'first: no tool_calls / tool role for the raw call')
check(#r2.messages==at+1,'first: the observation is the last message of the request')
local emitted
for _,e in ipairs(first.events) do if e.type=='tool' and e.name=='codemode' then emitted=e end end
check(emitted and emitted.arguments.code=='return 6*7;','first: the UI still gets the codemode tool event')

-- 2. a plain answer ends the turn ---------------------------------------------------------------------
local plain=run('first',{{content='Just the answer, with an example:\n```js\nreturn 1;\n```'}})
check(plain.ok and plain.reply=='Just the answer, with an example:\n```js\nreturn 1;\n```' and #plain.dispatched==0 and #plain.requests==1,
  'first: a message without a run block is the answer; an ordinary block is text')

-- 3. several rounds: each raw call rendered, the earlier ones byte-stable (prompt cache) ------------
local multi=run('first',{{content='Read.\n```js run\nreturn 1;\n```'},{content='```js run\nreturn 2;\n```'},{content='both done'}})
check(multi.reply=='both done' and #multi.dispatched==2,'first: two run blocks in two rounds ran twice')
local a2,a3=multi.requests[2],multi.requests[3]
check(no_raw_pairing(a2) and no_raw_pairing(a3),'first: no raw pairing in either request')
local blocks=0
for _,m in ipairs(a3.messages) do if m.role=='assistant' and m.content:find('```js run',1,true) then blocks=blocks+1 end end
check(blocks==2,'first: the third request carries both rendered run blocks')
local stable=true
for i=1,#a2.messages do if json.encode(a2.messages[i])~=json.encode(a3.messages[i]) then stable=false end end
check(stable,'first: every message of request 2 is sent byte-identical in request 3 (cache-stable rendering)')
local only=index_of(a3,function(m) return m.role=='assistant' and m.content=='```js run\nreturn 2;\n```' end)
check(only and a3.messages[only].tool_calls==nil,'first: a block with no thought renders as the block alone')

-- 4. the next turn rebuilds from the stored rows: the same bytes ----------------------------------------
local sid=first.sid
local again=turn(sid,'first',{{content='still 42'}})
check(again.ok and again.reply=='still 42','first: a later turn of the same session runs')
local same=true
for i=2,#r2.messages do if json.encode(r2.messages[i])~=json.encode(again.requests[1].messages[i]) then same=false end end
check(same,'first: build_context renders the stored rows exactly like the in-loop request did')
check(no_raw_pairing(again.requests[1]),'first: the rebuilt request has no raw pairing')

-- 5. mixed: a direct call and a run block in one step; a codemode call the model makes anyway -------
local mixed=run('first',{{content='Two things.\n```js run\nreturn 3;\n```',finish_reason='tool_calls',tool_calls={{id='call_direct1',type='function',
  ['function']={name='time',arguments='{}'}}}},
  {content='Habit.',finish_reason='tool_calls',tool_calls={{id='call_native1',type='function',['function']={name='codemode',arguments=json.encode({code='return 4;'})}}}},
  {content='```js run\nreturn 5;\n```'},{content='mixed done'}})
check(mixed.ok and mixed.reply=='mixed done','first: the mixed session finished: '..tostring(mixed.reply))
local m4=mixed.requests[4]
local ok_pair,why=valid_pairing(m4)
check(ok_pair,'first: mixed request pairing is valid: '..tostring(why))
check(no_raw_pairing(m4),'first: mixed request has no raw pairing')
local step=index_of(m4,function(m) return m.role=='assistant' and m.content=='Two things.\n```js run\nreturn 3;\n```' end)
check(step and #m4.messages[step].tool_calls==1 and m4.messages[step].tool_calls[1].id=='call_direct1','first: the direct call keeps its tool_calls entry next to the rendered block')
check(m4.messages[step+1].role=='tool' and m4.messages[step+1].tool_call_id=='call_direct1','first: the direct result comes first, right after the call')
local rows=tool_rows(mixed.sid)
local raw_row
for _,row in ipairs(rows) do if raw_code.is_raw(row.tool_call_id) and not raw_row then raw_row=row end end
check(m4.messages[step+2].role=='user' and raw_row and m4.messages[step+2].content==raw_code.OBSERVATION..raw_row.content,'first: then the raw observation of that step')
local native=index_of(m4,function(m) return m.role=='assistant' and m.tool_calls and m.tool_calls[1].id=='call_native1' end)
check(native and m4.messages[native+1].role=='tool' and m4.messages[native+1].tool_call_id=='call_native1','first: a codemode call the model sends anyway still runs and renders as a tool call')
local raw_rows=0;for _,row in ipairs(rows) do if raw_code.is_raw(row.tool_call_id) then raw_rows=raw_rows+1 end end
check(#rows==4 and raw_rows==2,'first: stored rows: four results, two from the raw channel ('..#rows..','..raw_rows..')')

-- 6. robustness: unterminated refused (no codemode hint), two blocks, text after ----------------------
local cut=run('first',{{content='Writing.\n```js run\nreturn "never";'},{content='done'}})
check(#cut.dispatched==0 and cut.tool.content:find('raw_code_unterminated',1,true),'first: an unterminated block is refused and never runs')
check(not cut.tool.content:find('codemode call',1,true),'first: the refusal does not suggest a codemode call')
local cut2=cut.requests[2]
local u=index_of(cut2,function(m) return m.role=='assistant' and m.content:find('```js run',1,true) end)
check(u and cut2.messages[u].content=='Writing.\n```js run\nreturn "never";','first: an unterminated block is rendered as sent, without a closing fence')
local two=run('first',{{content='a\n```js run\nreturn 1;\n```\nb\n```js run\nreturn 2;\n```\nOutput: 2'},{content='done'}})
check(#two.dispatched==2 and two.dispatched[1]=='return 1;' and two.dispatched[2]=='return 2;'
  and two.tool.content:find('run block 2 of 2',1,true) and two.tool.content:find('dropped',1,true),
  'first: two blocks both run in order, each labelled, text after the last is dropped and said')
local empty=run('first',{{content='```js run\n\n```'},{content='done'}})
check(#empty.dispatched==0 and empty.tool.content:find('raw_code_empty',1,true),'first: an empty block is refused')

-- 7. render_history unit: pure and idempotent ------------------------------------------------------------
local msgs={{role='system',content='s'},{role='assistant',content='t',tool_calls={{id='call_raw_ab',type='function',['function']={name='codemode',arguments='{"code":"return 1;"}'}}}},
  {role='tool',tool_call_id='call_raw_ab',name='codemode',content='R'}}
local before=json.encode(msgs)
local out=raw_code.render_history(msgs)
check(json.encode(msgs)==before,'render_history does not change its input')
check(#out==3 and out[2].content=='t\n```js run\nreturn 1;\n```' and out[2].tool_calls==nil and out[3].role=='user' and out[3].content=='Observation:\nR','render_history output')
check(json.encode(raw_code.render_history(out))==json.encode(out),'render_history is idempotent')
local plain_list={{role='user',content='x'}}
check(raw_code.render_history(plain_list)==plain_list,'render_history returns a list without raw calls as is')

-- 8. `1` keeps today's surface: codemode declared, tool rendering, the optional sentence -------------------
local on=run('1',{{content='Let me compute.\n```js run\nreturn 6*7;\n```'},{content='42 it is'}})
check(has(declared(on.requests[1]),'codemode'),'1: codemode stays declared')
check(on.requests[1].messages[1].content:find(raw_code.GUIDANCE,1,true) and not on.requests[1].messages[1].content:find(raw_code.FIRST_GUIDANCE,1,true),'1: the optional sentence, not the first guidance')
check(not no_raw_pairing(on.requests[2]),'1: the raw call still goes back as a tool call/result pair')
local off=run('codemode',{{content='plain'}})
check(has(declared(off.requests[1]),'codemode') and not json.encode(off.requests[1]):find('js run',1,true),'off: codemode declared, no run-block wording')

print(json.encode({ok=true,checks=checks,paid_calls=0}))
